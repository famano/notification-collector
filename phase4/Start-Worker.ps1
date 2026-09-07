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
    # 同じカードで連続して失敗した回数がこれに達したら棚上げする
    [int]    $MaxFailures = 3,
    [int]    $ErrorBackoffSeconds = 30,
    # 1カードあたりのツール実行ターン上限
    [int]    $MaxTurns = 12,
    # 成果物の出力先。カードごとにサブフォルダを切る。
    [string] $OutputRoot,
    [switch] $Once
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\phase2\lib\TaskStore.ps1"
. "$PSScriptRoot\..\phase2\lib\ClaudeClient.ps1"
. "$PSScriptRoot\lib\WorkTools.ps1"

if (-not $OutputRoot) { $OutputRoot = Join-Path $PSScriptRoot 'output' }
if (-not (Test-Path $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
$OutputRoot = (Resolve-Path $OutputRoot).Path

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

    $workspace = Get-TaskWorkspace -Root $OutputRoot -TaskId $id
    Write-Step $id 'llm' '対応内容を検討しています…'

    # ツール実行のたびに作業ログへ残し、その直前に中止要求を見る。
    # これで「いま何をしているか」が画面に出て、途中で割り込める。
    $onProgress = {
        param($toolName, $toolInput)
        if (Test-TaskCancelled -Conn $conn -TaskId $id) { return $false }
        $what = switch ($toolName) {
            'write_file'         { "ファイルを作成しています: $($toolInput.path)" }
            'create_email_draft' { "メールの下書きを作成しています: $($toolInput.subject)" }
            'read_file'          { "ファイルを読んでいます: $($toolInput.path)" }
            'list_files'         { 'これまでの成果物を確認しています' }
            default              { "実行中: $toolName" }
        }
        Write-Step $id 'tool' $what 'DarkCyan'
        return $true
    }.GetNewClosure()

    $onTool = {
        param($toolName, $toolInput)
        $r = Invoke-WorkTool -Name $toolName -ToolInput $toolInput -Workspace $workspace
        if ($r.artifact) {
            Add-TaskArtifact -Conn $conn -TaskId $id -Path $r.artifact
            Write-Step $id 'file' ("成果物: " + (Split-Path -Leaf $r.artifact)) 'Green'
        }
        if ($r.isError) { Write-Step $id 'step' ("ツールが失敗: " + $r.text) 'Yellow' }
        return $r
    }.GetNewClosure()

    $res = Invoke-ClaudeWork -Task $Task -Evt $evt -Policy $policy -Instructions $instructions `
        -Tools (Get-WorkTools) -OnTool $onTool -OnProgress $onProgress -MaxTurns $MaxTurns

    if ($res.aborted) { Stop-IfCancelled $id | Out-Null; return }
    # 生成中にユーザーが中止した場合、結果は捨てる
    if (Stop-IfCancelled $id) { return }

    $files = @(Get-TaskArtifacts -Conn $conn -TaskId $id)
    $summary = $res.text
    if ($files.Count -gt 0) {
        $summary += "`n`n作成したファイル:`n" + (($files | ForEach-Object { '- ' + $_['name'] }) -join "`n")
    }
    [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ agent_output = $summary })
    Set-CommentsConsumed -Conn $conn -TaskId $id

    [void] $conn.NonQuery('UPDATE tasks SET agent_lease_until = NULL WHERE id = ?', [object[]] @($id))
    [void] (Set-TaskColumn -Conn $conn -TaskId $id -Column 'review')

    $msg = if ($files.Count -gt 0) {
        "{0} 件のファイルを作成しました。レビュー待ちに移動します。" -f $files.Count
    } else {
        'ファイルの作成はありませんでした。レビュー待ちに移動します。'
    }
    Write-Step $id 'done' $msg 'Green'
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

                # 残高不足やキー不正のような恒久的な失敗では、戻して拾い直すのを
                # 延々と繰り返してしまう。一定回数で棚上げし、原因を書いて手を止める。
                $fails = Get-ConsecutiveFailures -Conn $conn -TaskId $tid
                if ($fails -ge $MaxFailures) {
                    [void] (Set-TaskCancel -Conn $conn -TaskId $tid -Requested $true)
                    Add-TaskActivity -Conn $conn -TaskId $tid -Kind 'error' -Message (
                        "{0}回続けて失敗したため、このカードは一旦見送ります。原因を直したあと『中止を解除して要対応へ』で再開できます。" -f $fails)
                    Write-Host ("  [#{0}] {1}回連続失敗のため棚上げしました" -f $tid, $fails) -ForegroundColor Yellow
                }
            }
            Set-WorkerState -Conn $conn -State 'error' -CurrentTaskId $null -Message $msg
            # 失敗直後は間を置く。API 側の問題を叩き続けないため。
            if (-not $Once) { Start-Sleep -Seconds $ErrorBackoffSeconds }
        }
        if ($Once) { break }
    }
}
finally {
    Set-WorkerState -Conn $conn -State 'stopped' -CurrentTaskId $null -Message '停止しました'
    $conn.Dispose()
    Write-Host 'worker stopped.' -ForegroundColor Yellow
}
