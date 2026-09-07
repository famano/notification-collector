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
    # 危険なツールの承認を待つ秒数。過ぎたら実行しない。
    [int]    $ApprovalTimeoutSec = 600,
    [int]    $CommandTimeoutSec = 120,
    # 自己検証で指摘が出たときに直しを試みる回数
    [int]    $MaxRepairs = 1,
    # 自己検証を行わない場合に指定
    [switch] $NoVerify,
    # 成果物の出力先。カードごとにサブフォルダを切る。
    [string] $OutputRoot,
    [switch] $Once
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\phase2\lib\TaskStore.ps1"
. "$PSScriptRoot\..\phase2\lib\ClaudeClient.ps1"
. "$PSScriptRoot\lib\WorkTools.ps1"
# Gmail 連携があれば下書きツールが使えるようになる (未設定なら黙って無効)
$gmailLib = Join-Path $PSScriptRoot '..\phase5\lib\GmailConnector.ps1'
if (Test-Path $gmailLib) { . $gmailLib }

$VerifyResults = (-not $NoVerify)

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

# 危険なツールの実行許可を利用者から取る。
# 戻り値: 'approved' / 'denied' / 'expired' / 'cancelled'
function Wait-ToolApproval {
    param([int] $TaskId, [string] $Tool, $Risk)

    if (Test-YoloMode -Conn $conn) {
        Write-Step $TaskId 'tool' ("YOLOのため承認なしで実行: " + $Risk.summary) 'DarkYellow'
        return 'approved'
    }
    if (Test-ToolGranted -Conn $conn -TaskId $TaskId -Tool $Tool) {
        Write-Step $TaskId 'tool' ("許可済みのため実行: " + $Risk.summary) 'DarkCyan'
        return 'approved'
    }

    $reqId = New-ToolRequest -Conn $conn -TaskId $TaskId -Tool $Tool -Summary $Risk.summary -Detail $Risk.detail
    Write-Step $TaskId 'approve' ("承認待ち: " + $Risk.summary) 'Yellow'
    Set-WorkerState -Conn $conn -State 'waiting' -CurrentTaskId $TaskId -Message ('承認待ち: ' + $Risk.summary)

    $deadline = (Get-Date).AddSeconds($ApprovalTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-TaskCancelled -Conn $conn -TaskId $TaskId) {
            [void] (Set-ToolRequestStatus -Conn $conn -RequestId $reqId -Status 'expired')
            return 'cancelled'
        }
        $r = Get-ToolRequest -Conn $conn -RequestId $reqId
        if ($r -and [string] $r['status'] -ne 'pending') {
            Set-WorkerState -Conn $conn -State 'working' -CurrentTaskId $TaskId -Message '作業を再開しました'
            return [string] $r['status']
        }
        # 待っているあいだも死活を更新する。止めておくと画面上は
        # 「応答なし」に見えてしまう。
        Set-WorkerState -Conn $conn -State 'waiting' -CurrentTaskId $TaskId -Message ('承認待ち: ' + $Risk.summary)
        Start-Sleep -Seconds 2
    }
    [void] (Set-ToolRequestStatus -Conn $conn -RequestId $reqId -Status 'expired')
    return 'expired'
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

    # Gmail 由来なら、返信をスレッドにぶら下げるための識別子を取り出しておく
    $gmailThreadId = ''
    $gmailInReplyTo = ''
    if ($evt -and [string] $evt['source'] -eq 'gmail' -and $evt['raw_json']) {
        try {
            $raw = [string] $evt['raw_json'] | ConvertFrom-Json
            $gmailThreadId  = [string] $raw.threadId
            $gmailInReplyTo = [string] $raw.messageId
        } catch { }
    }

    if (Stop-IfCancelled $id) { return }

    $workspace = Get-TaskWorkspace -Root $OutputRoot -TaskId $id
    Write-Step $id 'llm' '対応内容を検討しています…'

    # ツール実行のたびに作業ログへ残し、その直前に中止要求を見る。
    $onProgress = {
        param($toolName, $toolInput)
        if (Test-TaskCancelled -Conn $conn -TaskId $id) { return $false }
        $what = switch ($toolName) {
            'write_file'         { "ファイルを作成しています: $($toolInput.path)" }
            'create_email_draft' { "メールの下書きを作成しています: $($toolInput.subject)" }
            'read_file'          { "ファイルを読んでいます: $($toolInput.path)" }
            'list_files'         { 'ファイル一覧を確認しています' }
            'run_command'        { "コマンドを実行しようとしています: $($toolInput.purpose)" }
            'http_fetch'         { "外部から取得しようとしています: $($toolInput.url)" }
            default              { "実行中: $toolName" }
        }
        Write-Step $id 'tool' $what 'DarkCyan'
        return $true
    }.GetNewClosure()

    $onTool = {
        param($toolName, $toolInput)

        # 危険なツールは承認を取ってから実行する。
        # 拒否は例外にせずモデルに返す。理由が伝われば別の手を考えられる。
        $risk = Get-ToolRisk -Name $toolName -ToolInput $toolInput -Workspace $workspace
        if ($risk.risky) {
            $decision = Wait-ToolApproval -TaskId $id -Tool $toolName -Risk $risk
            if ($decision -ne 'approved') {
                $why = switch ($decision) {
                    'denied'    { '利用者がこの操作を許可しませんでした。' }
                    'expired'   { "利用者の応答が {0} 秒以内に得られませんでした。" -f $ApprovalTimeoutSec }
                    'cancelled' { '利用者が作業を中止しました。' }
                    default     { '承認されませんでした。' }
                }
                Write-Step $id 'deny' ("実行しませんでした: " + $risk.summary) 'Yellow'
                return [pscustomobject]@{
                    text = "$why 別の手段を検討するか、必要であればその旨を報告してください。"
                    artifact = $null; isError = $true
                }
            }
        }

        $r = Invoke-WorkTool -Name $toolName -ToolInput $toolInput -Workspace $workspace `
                -CommandTimeoutSec $CommandTimeoutSec `
                -GmailThreadId $gmailThreadId -GmailInReplyTo $gmailInReplyTo
        if ($r.artifact) {
            Add-TaskArtifact -Conn $conn -TaskId $id -Path $r.artifact
            Write-Step $id 'file' ("成果物: " + (Split-Path -Leaf $r.artifact)) 'Green'
        }
        if ($r.isError) { Write-Step $id 'step' ("ツールが失敗: " + $r.text) 'Yellow' }
        return $r
    }.GetNewClosure()

    $issues = $null
    $verdict = $null
    $round = 0

    while ($true) {
        $res = Invoke-ClaudeWork -Task $Task -Evt $evt -Policy $policy -Instructions $instructions `
            -Tools (Get-WorkTools) -OnTool $onTool -OnProgress $onProgress -MaxTurns $MaxTurns `
            -RepairIssues $issues

        if ($res.aborted) { Stop-IfCancelled $id | Out-Null; return }
        if (Stop-IfCancelled $id) { return }

        if (-not $VerifyResults) { $verdict = $null; break }

        # --- 自己検証 (作成時とは別の会話で行う) ---
        Write-Step $id 'verify' '成果物を検証しています…' 'Magenta'
        $arts = @()
        foreach ($a in @(Get-TaskArtifacts -Conn $conn -TaskId $id)) {
            $c = ''
            try { $c = [IO.File]::ReadAllText([string] $a['path'], [Text.Encoding]::UTF8) } catch { $c = '(読み取れませんでした)' }
            $arts += [pscustomobject]@{ name = $a['name']; content = $c }
        }
        $v = (Invoke-ClaudeVerify -Task $Task -Policy $policy -Artifacts $arts -Report $res.text -Instructions $instructions).result
        $verdict = $v

        $high = @($v.issues | Where-Object { $_.severity -eq 'high' })
        if ($v.verdict -eq 'ok' -and $v.completed) {
            Write-Step $id 'verify' ('検証: 問題なし — ' + $v.summary) 'Green'
            break
        }

        Write-Step $id 'verify' ("検証: 要修正 {0} 件 — {1}" -f $high.Count, $v.summary) 'Yellow'
        foreach ($i in $high) { Write-Step $id 'issue' ("[{0}] {1}: {2}" -f $i.severity, $i.where, $i.problem) 'Yellow' }

        $round++
        if ($round -gt $MaxRepairs) {
            Write-Step $id 'verify' ("修正を {0} 回試みましたが解消しませんでした。人間の確認が必要です。" -f $MaxRepairs) 'Yellow'
            break
        }
        if (Stop-IfCancelled $id) { return }
        Write-Step $id 'repair' ("指摘に基づいて修正します（{0} 回目）" -f $round) 'Cyan'
        $issues = $high
    }

    $files = @(Get-TaskArtifacts -Conn $conn -TaskId $id)
    $summary = $res.text
    if ($files.Count -gt 0) {
        $summary += "`n`n作成したファイル:`n" + (($files | ForEach-Object { '- ' + $_['name'] }) -join "`n")
    }
    if ($verdict) {
        $mark = if ($verdict.verdict -eq 'ok' -and $verdict.completed) { '問題なし' } else { '要確認' }
        $summary += "`n`n[自己検証: $mark] " + $verdict.summary
    }
    [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ agent_output = $summary })
    Set-CommentsConsumed -Conn $conn -TaskId $id

    # 解消しなかった指摘はコメントに残す。レビューする人がまずここを見る。
    if ($verdict -and @($verdict.issues | Where-Object { $_.severity -eq 'high' }).Count -gt 0) {
        $body = "検証で残った指摘:`n"
        foreach ($i in @($verdict.issues | Where-Object { $_.severity -eq 'high' })) {
            $body += "- $($i.where): $($i.problem)`n  → $($i.fix)`n"
        }
        [void] (Add-TaskComment -Conn $conn -TaskId $id -Author 'agent' -Body $body)
    }

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
