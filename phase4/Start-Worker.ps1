<#
.SYNOPSIS
    Phase 4: 要対応カードを拾って下書きを作るワーカー。

.DESCRIPTION
    todo のカードを1枚ずつ doing に移し、Claude に下書きを生成させて review に置く。
    各ステップの前に中止要求とユーザーの未読コメントを確認するので、
    カンバン側からの割り込みが効く。

    進捗は task_activity に、死活は worker_state に書く。カンバンはこれを読んで
    「いま何をしているか」を表示する。

    Slack への投稿とメールの送信もできるが、実行前に必ずカンバンで承認を取る。
    利用者が送信を求めていないかぎり下書きまでで止め、生成物は agent_output に
    入れて人間の確認に回す。

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
. "$PSScriptRoot\..\phase2\lib\Dossier.ps1"
. "$PSScriptRoot\lib\WorkTools.ps1"
# 外部サービス連携があればツールが増える (未設定なら黙って無効)
$gmailLib = Join-Path $PSScriptRoot '..\phase5\lib\GmailConnector.ps1'
if (Test-Path $gmailLib) { . $gmailLib }
$slackLib = Join-Path $PSScriptRoot '..\phase5\lib\SlackConnector.ps1'
if (Test-Path $slackLib) { . $slackLib }

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

    # Slack 由来なら、返信の投稿先を取り出しておく。
    # チャンネルをモデルに決めさせない。取り違えると無関係な相手に届く。
    $slackChannel = ''
    $slackChannelName = ''
    $slackThreadTs = ''
    if ($evt -and ([string] $evt['link']) -like 'slack://*' -and
        (Get-Command Test-SlackConfigured -ErrorAction SilentlyContinue) -and (Test-SlackConfigured)) {
        try {
            $tg = Get-SlackTarget -Link ([string] $evt['link'])
            if ($tg) {
                $slackChannel     = $tg.channel
                $slackChannelName = $tg.channelName
                $slackThreadTs    = $tg.threadTs
            }
        }
        catch {
            # 投稿先が引けなくても作業自体は続けられる。投稿ツールが出ないだけ。
            Write-Step $id 'step' ("Slack の投稿先を確認できませんでした: " + $_.Exception.Message) 'Yellow'
        }
    }
    $gmailThreadLabel = if ($gmailThreadId) { '元のスレッドへの返信として送信' } else { '新規メールとして送信' }

    # このカードに「返信先」があるか。あるなら出口は送信、無いなら自分で実施して終わる。
    # 送り先の無いカードに返信ツールを見せると、宛先の無い返信を書き始める。
    $hasOutlet = [bool] $slackChannel -or ($evt -and ([string] $evt['source']) -eq 'gmail')

    # この件の台帳。同じ件の前回までの知見を recall で引けるようにする。
    $subjectKey = [string] $Task['subject_key']
    if (-not $subjectKey -and $evt) {
        # 移行期のカード (subject_key を持たずに起票されたもの) はここで補う。
        $subjectKey = Get-SubjectKey -Evt $evt
        if ($subjectKey) {
            [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ subject_key = $subjectKey })
        }
    }
    $dossierText = ''
    if ($subjectKey) { $dossierText = Get-DossierText -Conn $conn -SubjectKey $subjectKey }
    # サービス単位の事実 (権限が無い等) も混ぜる。件が変わっても効くため。
    $svcText = Get-ServiceDossierText -Conn $conn
    if ($svcText) {
        if ($dossierText) { $dossierText += "`n" }
        $dossierText += "外部サービスについて分かっていること:`n" + $svcText
    }
    if ($dossierText) {
        Write-Step $id 'step' 'この件の前回までの記録を読み込みました' 'DarkCyan'
    }

    # 何度目の発生か。2回目以降は、前回と同じ調査を繰り返さないよう明示する。
    $occurrence = [int] $(if ($Task['occurrence_count']) { $Task['occurrence_count'] } else { 1 })

    # 出自を取り直せるカードかどうか。取り直せないカード (手起票、
    # 取得 API を持たない通知) に open_source を強制しても意味がない。
    $sourceUnavailable = $true
    if ($evt) {
        $src = [string] $evt['source']
        $ap  = [string] $evt['app']
        $sourceUnavailable = -not ($src -eq 'gmail' -or ([string] $evt['link']) -like 'slack://*' -or $ap -like 'Claude*')
    }

    # 人間送りの結論は DB の human_step 列から読む。
    #
    # 以前はここで $humanStep という変数を持ち、ツール実行のクロージャから
    # 代入していた。**代入は外に伝わらない。** PowerShell のスクリプトブロック内の
    # 代入はそのブロックのローカル変数を作るだけで、GetNewClosure() は変数を
    # 複製するのでなおさら届かない。結果として $humanStep は最後まで $null のままで、
    #   - 報告の先頭に出るはずの「【あなたの操作が必要です】」が一度も出ない
    #   - 自己検証に human_step が渡らず、人間送りの妥当性を見られない
    # という状態になっていた (カード自体には出るので、気付きにくい)。
    #
    # クロージャは human_step を DB に書いている。ならばそれを読めばよい。
    # 変数で持ち回るのをやめ、DB を唯一の出どころにする。
    #
    # 再実行のたびに前回の結論を消すのは、それが「前回の」結論だから。
    # 残したままだと、今回うまく閉じられたカードにも古い赤枠が出続ける。
    [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ human_step = $null })

    # --- 出自の取り直しは、モデルに頼まず先にワーカーがやる ---
    #
    # 「まず open_source を呼べ」とプロンプトで指示する形も試したが、
    # 守られなかった。カードに載っている見出しだけで十分だと判断して
    # write_file に直行し、結果として本文の後半を読まないまま報告が出る。
    #
    # このアプリは他の箇所でも、守らせたい性質は指示ではなく構造で担保している
    # (投稿先を束縛する、資格情報を注入する)。ここも同じにする。
    # 先に取ってから渡せば「読んでいない」という状態が存在しなくなる。
    $sourceText = ''
    $sourceNote = ''
    if (-not $sourceUnavailable) {
        Write-Step $id 'tool' '元のやり取りを取り直しています' 'DarkCyan'
        try {
            $sc = Get-SourceContext -Evt $evt
            $sourceNote = [string] $sc.note
            if ($sc.ok) {
                $parts = @()
                if ($sc.identifiers -and $sc.identifiers.Count -gt 0) {
                    $idLines = foreach ($k in $sc.identifiers.Keys) {
                        if ($sc.identifiers[$k]) { "  $k = $($sc.identifiers[$k])" }
                    }
                    $parts += "識別子 (http_request で使えます):`n" + ($idLines -join "`n")
                }
                if ($sc.attachments.Count -gt 0) {
                    $atLines = foreach ($a in $sc.attachments) {
                        "  id=$($a.id)  $($a.name)  $($a.mimeType)  $($a.size) バイト"
                    }
                    $parts += "添付 (fetch_attachment で中身を読めます):`n" + ($atLines -join "`n")
                }
                if ($sc.links.Count -gt 0) {
                    $parts += "本文中のリンク:`n" + (($sc.links | ForEach-Object { "  $_" }) -join "`n")
                }
                $parts += "本文:`n" + $sc.text
                $sourceText = ($parts -join "`n`n")
                Write-Step $id 'step' ("元のやり取りを取得しました ({0} 文字)" -f $sc.text.Length) 'Green'
            }
            else {
                Write-Step $id 'step' ('元のやり取りは取り直せませんでした: ' + $sc.note) 'Yellow'
            }
            # 先に取ったぶんも証跡に残す。これを残さないと、
            # 人間送りのゲートが「まだ読んでいない」と誤判定する。
            Add-TaskAttempt -Conn $conn -TaskId $id -Tool 'open_source' `
                -Target ([string] $sc.kind) -Outcome $(if ($sc.ok) { 'ok' } else { 'failed' }) `
                -Detail $(if ($sc.ok) { "{0} 文字を取得" -f $sc.text.Length } else { $sc.note })
        }
        catch {
            $sourceNote = $_.Exception.Message
            Write-Step $id 'step' ('元のやり取りの取得に失敗しました: ' + $sourceNote) 'Yellow'
            Add-TaskAttempt -Conn $conn -TaskId $id -Tool 'open_source' -Target 'error' `
                -Outcome 'failed' -Detail $sourceNote
        }
    }

    if (Stop-IfCancelled $id) { return }

    $workspace = Get-TaskWorkspace -Root $OutputRoot -TaskId $id

    # このカードで実際に外へ出したもの。送信はファイルとして残らないので、
    # 検証と報告のために別に控える。GetNewClosure() は変数を複製するが、
    # 参照型なら中身は共有されるので、クロージャからの追記が外にも見える。
    $sentItems = [System.Collections.ArrayList]::new()

    Write-Step $id 'llm' '対応内容を検討しています…'

    # ツール実行のたびに作業ログへ残し、その直前に中止要求を見る。
    $onProgress = {
        param($toolName, $toolInput)
        if (Test-TaskCancelled -Conn $conn -TaskId $id) { return $false }
        $what = switch ($toolName) {
            'write_file'         { "ファイルを作成しています: $($toolInput.path)" }
            'create_email_draft' { "メールの下書きを作成しています: $($toolInput.subject)" }
            'create_gmail_draft' { "Gmail に下書きを作成しています: $($toolInput.subject)" }
            'read_file'          { "ファイルを読んでいます: $($toolInput.path)" }
            'list_files'         { 'ファイル一覧を確認しています' }
            'run_command'        { "コマンドを実行しようとしています: $($toolInput.purpose)" }
            'http_request'       {
                $m = if ($toolInput.method) { ([string] $toolInput.method).ToUpper() } else { 'GET' }
                "$m $($toolInput.url)"
            }
            'open_source'        { '元のやり取りを取り直しています' }
            'fetch_attachment'   { "添付を取り込んでいます: $($toolInput.name)" }
            'recall'             { 'この件の過去の記録を確認しています' }
            'record_finding'     { '分かったことを台帳に残しています' }
            'require_human_step' { '利用者本人の操作が要るか判断しています' }
            'send_slack_message' { "Slack に投稿しようとしています: $slackChannelName" }
            'send_gmail'         { "メールを送信しようとしています: $($toolInput.to)" }
            'propose_reply'      { '返信案をカードに載せています' }
            default              { "実行中: $toolName" }
        }
        Write-Step $id 'tool' $what 'DarkCyan'
        return $true
    }.GetNewClosure()

    $onTool = {
        param($toolName, $toolInput)

        # 返信文面はカードの「送る文面」欄に載せる。外へは出ないので承認は要らない。
        # draft_text に入れるのは、user_edited (利用者が確定させた版) を踏まないため。
        # 何度作り直しても、利用者が手を入れた内容は消えない。
        if ($toolName -eq 'propose_reply') {
            $text = [string] $toolInput.text
            if (-not $text.Trim()) {
                return [pscustomobject]@{ text = '本文が空です。'; artifact = $null; isError = $true }
            }
            [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ draft_text = $text })
            Write-Step $id 'file' 'カンバンの「送る文面」に返信案を載せました' 'Green'
            return [pscustomobject]@{
                text     = 'カンバンの「送る文面」欄に載せました。利用者が確認し、必要なら直してから送信します。'
                artifact = $null
                isError  = $false
            }
        }

        # 件の台帳に残す。カードをまたいで効く事実だけをここに入れる。
        if ($toolName -eq 'record_finding') {
            $note = [string] $toolInput.note
            if (-not $subjectKey) {
                return [pscustomobject]@{
                    text = 'このカードには件を束ねるキーがないため、台帳に残せません。報告に書いてください。'
                    artifact = $null; isError = $true
                }
            }
            [void] (Add-DossierNote -Conn $conn -SubjectKey $subjectKey -Note $note -TaskId $id)
            Write-Step $id 'file' ('台帳に記録: ' + $note) 'Green'
            return [pscustomobject]@{
                text = '台帳に残しました。次に同じ件が来たときに読まれます。'
                artifact = $null; isError = $false
            }
        }

        # 人間にしかできない1手としてカードを閉じる。
        # ここが「安易な逃げ」になっていないかを、証跡で判定する。
        if ($toolName -eq 'require_human_step') {
            $blocker = [string] $toolInput.blocker
            $attempts = @(Get-TaskAttempts -Conn $conn -TaskId $id)
            $allowed = Test-HumanStepAllowed -Attempts $attempts -Blocker $blocker `
                            -SourceUnavailable:$sourceUnavailable
            if (-not $allowed.ok) {
                Write-Step $id 'step' ('人間送りを差し戻しました: ' + $allowed.reason) 'Yellow'
                return [pscustomobject]@{
                    text = $allowed.reason + ' まだ手はあります。'
                    artifact = $null; isError = $true
                }
            }

            # 権限不足は、この人に投げ返す問題ではない。一度設定すれば
            # 同じ壁で止まっている他のカードもまとめて通るようになる。
            if ($blocker -eq 'credential_missing') {
                $what = [string] $toolInput.what_is_missing
                if (-not $what) { $what = '外部サービスの権限' }

                # どのサービスの権限かは、モデルの文章ではなく
                # 実際に失敗したリクエストのホストから決める。
                # そうしないと言い回しの違いで設定カードが増殖する。
                $svc = ''
                foreach ($a in @($attempts)) {
                    if ([string] $a['tool'] -ne 'http_request') { continue }
                    if ([string] $a['outcome'] -eq 'ok') { continue }
                    $t = [string] $a['target']
                    if ($t -match 'https?://\S+') { $svc = Get-ServiceKey -Url $Matches[0] }
                }

                $setupId = New-SetupTask -Conn $conn -What $what `
                    -HowTo ([string] $toolInput.step) `
                    -Why ([string] $toolInput.tried) -BlockedTaskId $id -ServiceKey $svc
                Write-Step $id 'step' ("設定カード #{0} を作りました ({1})" -f $setupId, $what) 'Cyan'
                $script:PendingSetupId = $setupId

                # 権限の不足はこの件だけの事実ではない。同じサービスを使う
                # 別の件でも同じ壁に当たるので、サービス単位の台帳にも残す。
                if ($svc) {
                    [void] (Add-DossierNote -Conn $conn -SubjectKey ('svc:' + $svc) -TaskId $id -Kind 'credential' `
                        -Note ("{0} が未設定のため操作できません。{1}" -f $what, [string] $toolInput.tried))
                }
            }

            # ここで作るのはクロージャの中だけの値。外の関数には渡らないので、
            # 呼び出し側は DB に書いたものを読み直す (Get-TaskHumanStep)。
            $hs = [pscustomobject]@{
                blocker  = $blocker
                step     = [string] $toolInput.step
                url      = [string] $toolInput.url
                deadline = [string] $toolInput.deadline
                what_is_missing = [string] $toolInput.what_is_missing
                tried    = [string] $toolInput.tried
                setup_task_id = $(if ($blocker -eq 'credential_missing') { $script:PendingSetupId } else { $null })
            }
            # 'setup' は New-SetupTask が作るカード専用の印。権限待ちで止まった
            # 元のカードは 'blocked' にする。ここを 'setup' にすると、
            # ワーカーの取得対象から外れて (設定カードは拾わない仕様のため)、
            # 資格情報を入れたあとも二度と再開されなくなる。
            [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{
                human_step = ($hs | ConvertTo-Json -Depth 5 -Compress)
                shape = $(if ($blocker -eq 'credential_missing') { 'blocked' } else { 'human' })
            })
            Write-Step $id 'file' ('本人の操作が要ります: ' + $hs.step) 'Yellow'
            return [pscustomobject]@{
                text = 'カードに「あなたにしかできない1手」として載せました。報告にも同じことを短く書いてください。'
                artifact = $null; isError = $false
            }
        }

        # 危険なツールは承認を取ってから実行する。
        # 拒否は例外にせずモデルに返す。理由が伝われば別の手を考えられる。
        $risk = Get-ToolRisk -Name $toolName -ToolInput $toolInput -Workspace $workspace `
                    -SlackChannelName $slackChannelName -GmailThreadLabel $gmailThreadLabel
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
                # 不許可も試行の一部。「試したが利用者が止めた」と
                # 「そもそも試していない」は別物なので、証跡に残す。
                Add-TaskAttempt -Conn $conn -TaskId $id -Tool $toolName `
                    -Target ([string] $toolInput.url) -Outcome 'denied' -Detail $why
                return [pscustomobject]@{
                    text = "$why 別の手段を検討するか、必要であればその旨を報告してください。"
                    artifact = $null; isError = $true
                }
            }
        }

        $r = Invoke-WorkTool -Name $toolName -ToolInput $toolInput -Workspace $workspace `
                -CommandTimeoutSec $CommandTimeoutSec `
                -GmailThreadId $gmailThreadId -GmailInReplyTo $gmailInReplyTo `
                -SlackChannel $slackChannel -SlackThreadTs $slackThreadTs `
                -SourceEvent $evt -DossierText $dossierText

        # 「実際に何を叩いて何が返ったか」を残す。require_human_step の妥当性は
        # 報告の書きぶりではなくこれで判定する。
        if (@('http_request', 'open_source', 'fetch_attachment', 'run_command') -contains $toolName) {
            $target = if ($toolInput.url) {
                $m = if ($toolInput.method) { ([string] $toolInput.method).ToUpper() } else { 'GET' }
                "$m $($toolInput.url)"
            } else { '' }
            $head = ($r.text -split "`n")[0]
            if ($head.Length -gt 200) { $head = $head.Substring(0, 200) }
            Add-TaskAttempt -Conn $conn -TaskId $id -Tool $toolName -Target $target `
                -Outcome $(if ($r.isError) { 'failed' } else { 'ok' }) -Detail $head
        }

        if ($r.artifact) {
            Add-TaskArtifact -Conn $conn -TaskId $id -Path $r.artifact
            Write-Step $id 'file' ("成果物: " + (Split-Path -Leaf $r.artifact)) 'Green'
        }
        # 送信は取り消せない。何を出したかを作業ログに独立した種別で残し、
        # 検証にも回せるよう控えておく。
        if (-not $r.isError -and (Test-IrreversibleTool -Name $toolName -ToolInput $toolInput)) {
            [void] $sentItems.Add($risk.detail)
            Write-Step $id 'sent' $risk.summary 'Green'
        }
        if ($r.isError) { Write-Step $id 'step' ("ツールが失敗: " + $r.text) 'Yellow' }
        return $r
    }.GetNewClosure()

    $issues = $null
    $verdict = $null
    $round = 0

    while ($true) {
        $res = Invoke-ClaudeWork -Task $Task -Evt $evt -Policy $policy -Instructions $instructions `
            -Tools (Get-WorkTools -HasSlackTarget:([bool] $slackChannel) -HasOutlet:$hasOutlet) `
            -OnTool $onTool -OnProgress $onProgress -MaxTurns $MaxTurns `
            -RepairIssues $issues -Occurrence $occurrence -Dossier $dossierText `
            -SourceText $sourceText -SourceNote $sourceNote

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
        $humanStep = Get-TaskHumanStep -Conn $conn -TaskId $id
        $humanStepJson = ''
        if ($humanStep) { $humanStepJson = ($humanStep | ConvertTo-Json -Depth 5) }
        $v = (Invoke-ClaudeVerify -Task $Task -Policy $policy -Artifacts $arts -Report $res.text `
                -Instructions $instructions -Sent ([string[]] $sentItems.ToArray()) `
                -Attempts (Get-AttemptSummary -Conn $conn -TaskId $id) -HumanStep $humanStepJson).result
        $verdict = $v

        $high = @($v.issues | Where-Object { $_.severity -eq 'high' })
        if ($v.verdict -eq 'ok' -and $v.completed) {
            Write-Step $id 'verify' ('検証: 問題なし — ' + $v.summary) 'Green'
            break
        }

        Write-Step $id 'verify' ("検証: 要修正 {0} 件 — {1}" -f $high.Count, $v.summary) 'Yellow'
        foreach ($i in $high) { Write-Step $id 'issue' ("[{0}] {1}: {2}" -f $i.severity, $i.where, $i.problem) 'Yellow' }

        # 送信済みのカードは直しに回さない。送ったものは取り消せず、もう一度
        # モデルを走らせると同じ相手に二通目が出かねない。指摘は人間に渡す。
        if ($sentItems.Count -gt 0) {
            Write-Step $id 'verify' '送信済みのため修正は行いません。指摘は人間の確認に回します。' 'Yellow'
            break
        }

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

    # 本人の1手は報告の先頭に置く。これがこのカードの結論なので、
    # 経過の下に埋めると読まれない。
    $humanStep = Get-TaskHumanStep -Conn $conn -TaskId $id
    if ($humanStep) {
        $summary = (Get-HumanStepHeadline -HumanStep $humanStep `
                        -Tried (Get-AttemptSummary -Conn $conn -TaskId $id)) + "`n`n---`n`n" + $summary
    }

    if ($files.Count -gt 0) {
        $summary += "`n`n作成したファイル:`n" + (($files | ForEach-Object { '- ' + $_['name'] }) -join "`n")
    }
    # 送信はファイルに残らない。報告の先頭近くに出して見落とさないようにする。
    if ($sentItems.Count -gt 0) {
        $summary += "`n`n送信済み ({0} 件):`n" -f $sentItems.Count
        foreach ($x in $sentItems) { $summary += ('- ' + (($x -split "`n")[0]) + "`n") }
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

    $msg = if ($sentItems.Count -gt 0) {
        "{0} 件を送信しました。レビュー待ちに移動します。" -f $sentItems.Count
    } elseif ($files.Count -gt 0) {
        "{0} 件のファイルを作成しました。レビュー待ちに移動します。" -f $files.Count
    } else {
        'ファイルの作成はありませんでした。レビュー待ちに移動します。'
    }
    Write-Step $id 'done' $msg 'Green'
}

Write-Host 'ワーカーを開始しました。停止するには Ctrl+C' -ForegroundColor Green
Write-Host '(送信・投稿は承認を取ってから行います。生成物はレビュー待ちに置かれます)' -ForegroundColor DarkGray

# どのツールが使える状態で起動したかを最初に出す。
# ライブラリは起動時にしか読み込まない。コードを更新したのに動きが変わらないときは、
# まずこの行を見れば、更新前のプロセスが動いたままかどうかが分かる。
function Test-Connected { param([string] $Fn) return ((Get-Command $Fn -ErrorAction SilentlyContinue) -and (& $Fn)) }
$gmailOn = Test-Connected 'Test-GmailConfigured'
$slackOn = Test-Connected 'Test-SlackConfigured'
Write-Host ('連携: Gmail={0} / Slack={1}' -f
    $(if ($gmailOn) { '有効 (下書き・送信)' } else { '無効' }),
    $(if ($slackOn) { '有効 (Slack 由来のカードに投稿)' } else { '無効' })) -ForegroundColor DarkGray

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
