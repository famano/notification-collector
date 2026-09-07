<#
.SYNOPSIS
    Phase 4: 要対応カードを拾って下書きを作るワーカー。

.DESCRIPTION
    todo のカードを1枚ずつ doing に移し、Claude に下書きを生成させて review に置く。
    各ステップの前に中止要求とユーザーの未読コメントを確認するので、
    カンバン側からの割り込みが効く。

    進捗は task_activity に、死活は worker_state に書く。カンバンはこれを読んで
    「いま何をしているか」を表示する。

    送信・投稿は一切行わない。生成物は agent_output に入れて人間の確認に回す。

.PARAMETER Once
    1周だけ実行して終了する (動作確認用)。

.EXAMPLE
    .\Start-Worker.ps1
    .\Start-Worker.ps1 -Once
#>
[CmdletBinding()]
param(
    [string] $DbPath,
    [string] $PolicyPath,
    [int]    $IdleSeconds = 5,
    [int]    $LeaseMinutes = 10,
    [switch] $Once
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\phase2\lib\TaskStore.ps1"
. "$PSScriptRoot\..\phase2\lib\ClaudeClient.ps1"

if (-not $PolicyPath) { $PolicyPath = Join-Path $PSScriptRoot '..\phase2\config\policy.json' }
$policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json

$conn = Open-TaskStore -Path $DbPath

function Write-Step {
    param([int] $TaskId, [string] $Kind, [string] $Message, [string] $Color = 'Gray')
    Add-TaskActivity -Conn $conn -TaskId $TaskId -Kind $Kind -Message $Message
    Set-WorkerState -Conn $conn -State 'working' -CurrentTaskId $TaskId -Message $Message
    Write-Host ("  [#{0}] {1}" -f $TaskId, $Message) -ForegroundColor $Color
}

# 中止要求が立っていたら後始末して $true を返す
function Stop-IfCancelled {
    param([int] $TaskId)
    if (-not (Test-TaskCancelled -Conn $conn -TaskId $TaskId)) { return $false }
    Write-Step $TaskId 'cancelled' '利用者の指示により中止しました' 'Yellow'
    # 列はユーザーが動かした先のままにする。フラグとリースだけ解除して再開可能にする。
    [void] (Update-TaskFields -Conn $conn -TaskId $TaskId -Fields @{})
    [void] $conn.NonQuery('UPDATE tasks SET cancel_requested = 0, agent_lease_until = NULL WHERE id = ?',
                          [object[]] @($TaskId))
    return $true
}

function Invoke-WorkItem {
    param($Task)
    $id = [int] $Task['id']

    Write-Step $id 'start' ('作業を開始しました: ' + $Task['title']) 'Cyan'
    if (Stop-IfCancelled $id) { return }

    # 割り込み指示の取り込み
    $comments = @(Get-UnconsumedComments -Conn $conn -TaskId $id)
    $instructions = @($comments | ForEach-Object { [string] $_['body'] })
    if ($instructions.Count -gt 0) {
        Write-Step $id 'step' ("利用者の指示を {0} 件読み込みました" -f $instructions.Count) 'Magenta'
    }

    # 元の通知
    $detail = Get-TaskDetail -Conn $conn -TaskId $id
    $evt = if ($detail) { $detail.event } else { $null }

    if (Stop-IfCancelled $id) { return }

    Write-Step $id 'llm' 'Claude に下書きを生成させています…'
    $res = Invoke-ClaudeDraft -Task $Task -Evt $evt -Policy $policy -Instructions $instructions

    # 生成中にユーザーが中止した場合、結果は捨てる
    if (Stop-IfCancelled $id) { return }

    $d = $res.result
    [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ agent_output = $d.draft })
    Set-CommentsConsumed -Conn $conn -TaskId $id

    if ($d.notes) {
        [void] (Add-TaskComment -Conn $conn -TaskId $id -Author 'agent' -Body ("確認してください: " + $d.notes))
    }

    [void] $conn.NonQuery('UPDATE tasks SET agent_lease_until = NULL WHERE id = ?', [object[]] @($id))
    [void] (Set-TaskColumn -Conn $conn -TaskId $id -Column 'review')
    Write-Step $id 'done' '下書きを作成しました。レビュー待ちに移動します。' 'Green'
}

Write-Host 'ワーカーを開始しました。停止するには Ctrl+C' -ForegroundColor Green
Write-Host '(送信・投稿は行いません。生成物はレビュー待ちに置かれます)' -ForegroundColor DarkGray

try {
    while ($true) {
        try {
            $task = Get-NextWorkItem -Conn $conn -LeaseMinutes $LeaseMinutes
            if ($null -eq $task) {
                Set-WorkerState -Conn $conn -State 'idle' -CurrentTaskId $null -Message '待機中'
                if ($Once) { break }
                Start-Sleep -Seconds $IdleSeconds
                continue
            }
            Invoke-WorkItem $task
        }
        catch {
            $msg = $_.Exception.Message
            Write-Host ("worker error: {0}" -f $msg) -ForegroundColor Red
            if ($task) {
                $tid = [int] $task['id']
                Add-TaskActivity -Conn $conn -TaskId $tid -Kind 'error' -Message ("失敗しました: " + $msg)
                # リースを外して次のワーカーが拾えるようにする
                [void] $conn.NonQuery('UPDATE tasks SET agent_lease_until = NULL WHERE id = ?', [object[]] @($tid))
                [void] (Set-TaskColumn -Conn $conn -TaskId $tid -Column 'todo')
            }
            Set-WorkerState -Conn $conn -State 'error' -CurrentTaskId $null -Message $msg
            if (-not $Once) { Start-Sleep -Seconds $IdleSeconds }
        }
        if ($Once) { break }
    }
}
finally {
    Set-WorkerState -Conn $conn -State 'stopped' -CurrentTaskId $null -Message '停止しました'
    $conn.Dispose()
    Write-Host 'worker stopped.' -ForegroundColor Yellow
}
