# WorkTools.ps1
# ワーカーが実行できる作業ツール。
#
# 方針:
#   能力は制限しない。制限する代わりに、危険なものは実行前に利用者の承認を取る。
#   ここでは「何が危険か」を分類するだけで、承認そのものはワーカーが行う。
#
#   分類の基準は「取り返しがつくか」と「作業フォルダの外に影響するか」。
#     安全  … カードの作業フォルダ内のテキスト読み書き
#     要承認 … コマンド実行、フォルダ外への書き込み、ネットワークアクセス、
#              そして外向きの送信 (Slack への投稿、メールの送信)
#
#   送信は他のツールと同じ承認の仕組みに乗せてあるが、取り消しがきかない点だけは違う。
#   宛先と本文は承認画面に省略せず全文出す。投稿先・返信先はモデルに決めさせず、
#   カードの元通知からワーカーが束縛して渡す (Slack のチャンネル、Gmail のスレッド)。
#
#   要承認のものは、承認画面に実行内容を省略せず出す。通知本文（第三者が書いた文字列）が
#   入力に混ざりうるため、この画面が注入と実行のあいだに立つ唯一の壁になる。

$script:SafeExtensions  = @('.txt', '.md', '.eml', '.csv', '.json', '.html', '.log', '.yml', '.yaml')
$script:MaxContentBytes = 1048576   # 1MB
$script:MaxOutputChars  = 8000      # モデルに返す出力の上限

function Get-TaskWorkspace {
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] [int] $TaskId)
    $dir = Join-Path $Root ("task-{0:D4}" -f $TaskId)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Resolve-Path $dir).Path
}

# 相対パスは作業フォルダ基準、絶対パスはそのまま。禁止はせず、後で危険度を判定する。
function Resolve-TargetPath {
    param([Parameter(Mandatory)] [string] $Workspace, [Parameter(Mandatory)] [string] $Relative)
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw 'ファイル名が空です' }
    if ([IO.Path]::IsPathRooted($Relative)) { return [IO.Path]::GetFullPath($Relative) }
    return [IO.Path]::GetFullPath((Join-Path $Workspace $Relative))
}

function Test-InWorkspace {
    param([string] $Workspace, [string] $FullPath)
    return $FullPath.StartsWith($Workspace, [StringComparison]::OrdinalIgnoreCase)
}

# 非 ASCII のヘッダは RFC2047 で符号化しないとメールクライアントが化ける
function ConvertTo-MimeHeader {
    param([string] $Value)
    if (-not $Value) { return '' }
    $isAscii = $true
    foreach ($ch in $Value.ToCharArray()) { if ([int]$ch -gt 127) { $isAscii = $false; break } }
    if ($isAscii) { return $Value }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    # ${b64} と括ること。"$b64?=" は ? まで変数名に取り込まれて空になる。
    return "=?UTF-8?B?${b64}?="
}

function Limit-Text {
    param([string] $Text)
    if (-not $Text) { return '' }
    if ($Text.Length -le $script:MaxOutputChars) { return $Text }
    return $Text.Substring(0, $script:MaxOutputChars) + "`n…(出力が長いため省略)"
}

# ---------------------------------------------------------------- ツール定義

$script:WorkTools = @(
    @{
        name        = 'write_file'
        description = 'テキストファイルを作成する。カードの作業フォルダ内なら即座に実行される。作業フォルダ外や実行可能な拡張子の場合は利用者の承認を求める。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                path    = @{ type = 'string'; description = 'ファイル名。相対パスなら作業フォルダ基準。絶対パスも指定できる（要承認）。' }
                content = @{ type = 'string'; description = 'ファイルの中身。' }
                purpose = @{ type = 'string'; description = 'このファイルが何のためのものかの一文。' }
            }
            required = @('path', 'content', 'purpose')
        }
    },
    @{
        name        = 'create_email_draft'
        description = 'メールの下書きを .eml として作成する。メールクライアントで開くと下書きとして編集・送信できる。送信そのものは行わない。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                to      = @{ type = 'string'; description = '宛先。不明なら空文字にして最後の説明で確認を促す。' }
                cc      = @{ type = 'string' }
                subject = @{ type = 'string' }
                body    = @{ type = 'string' }
                path    = @{ type = 'string'; description = 'ファイル名 (省略時 draft.eml)' }
            }
            required = @('subject', 'body')
        }
    },
    @{
        name        = 'read_file'
        description = 'ファイルを読む。作業フォルダ内なら即座に、外なら承認のうえ実行する。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{ path = @{ type = 'string' } }
            required   = @('path')
        }
    },
    @{
        name        = 'list_files'
        description = 'フォルダ内のファイル一覧を得る。省略時はこのカードの作業フォルダ。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{ path = @{ type = 'string'; description = '省略可。' } }
        }
    },
    @{
        name        = 'run_command'
        description = 'PowerShell コマンドを実行する。必ず利用者の承認を求めてから実行される。ファイル変換、集計、既存ファイルの調査など、他のツールでできないことに使う。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                command = @{ type = 'string'; description = '実行する PowerShell コマンド。1行で完結させる。' }
                purpose = @{ type = 'string'; description = '何のために実行するのかの一文。承認画面に出る。' }
            }
            required = @('command', 'purpose')
        }
    },
    @{
        name        = 'http_fetch'
        description = 'URL の内容を取得する (GET のみ)。必ず利用者の承認を求めてから実行される。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                url     = @{ type = 'string' }
                purpose = @{ type = 'string'; description = '何のために取得するのかの一文。承認画面に出る。' }
            }
            required = @('url', 'purpose')
        }
    }
)

# 送信ツール。外に出たら取り消せないので、他のツールと違って
# 「使える状態か」だけでなく「返す先が分かっているか」でも出し分ける。
$script:SlackSendTool = @{
    name        = 'send_slack_message'
    description = '元の Slack スレッドに返信を投稿する。実行前に必ず利用者の承認を求める。投稿先はこのカードの元通知から決まっており、指定はできない。一度投稿すると取り消せないので、利用者が送信を求めている場合にだけ使う。求められていなければ文面を報告に載せるだけにする。'
    input_schema = @{
        type       = 'object'
        properties = [ordered]@{
            text            = @{ type = 'string'; description = '投稿する本文。そのまま投稿される。' }
            reply_in_thread = @{ type = 'boolean'; description = '既定 true。false にすると元スレッドではなくチャンネルへの新規投稿になる。' }
        }
        required = @('text')
    }
}

$script:GmailSendTool = @{
    name        = 'send_gmail'
    description = 'メールを実際に送信する。実行前に必ず利用者の承認を求める。Gmail から来たカードへの返信なら元のスレッドにぶら下がる。一度送ると取り消せないので、利用者が送信を求めている場合にだけ使う。求められていなければ create_gmail_draft か create_email_draft で下書きに留める。'
    input_schema = @{
        type       = 'object'
        properties = [ordered]@{
            to      = @{ type = 'string'; description = '宛先。返信なら元の差出人。空欄では送信できない。' }
            cc      = @{ type = 'string' }
            subject = @{ type = 'string' }
            body    = @{ type = 'string' }
        }
        required = @('to', 'subject', 'body')
    }
}

$script:GmailDraftTool = @{
    name        = 'create_gmail_draft'
    description = 'Gmail に本物の下書きを作成する。Gmail から来たカードへの返信ならスレッドにぶら下がる。送信は行わない。ローカルの .eml ではなく実際のメールボックスに作る場合はこちらを使う。'
    input_schema = @{
        type       = 'object'
        properties = [ordered]@{
            to      = @{ type = 'string'; description = '宛先。返信なら元の差出人。' }
            cc      = @{ type = 'string' }
            subject = @{ type = 'string' }
            body    = @{ type = 'string' }
        }
        required = @('subject', 'body')
    }
}

# 連携が設定されているときだけ、そのサービスのツールを見せる。
# 使えないツールを提示すると、モデルが存在しない手段を前提に計画を立ててしまう。
#
# Slack の投稿は返信先が要る。カードの元通知が Slack でなければ投稿先が無いので、
# 設定済みでも出さない (呼び出し側が -HasSlackTarget で伝える)。
function Get-WorkTools {
    param([switch] $HasSlackTarget)
    $tools = @($script:WorkTools)
    if ((Get-Command Test-GmailConfigured -ErrorAction SilentlyContinue) -and (Test-GmailConfigured)) {
        $tools += $script:GmailDraftTool
        $tools += $script:GmailSendTool
    }
    if ($HasSlackTarget -and (Get-Command Test-SlackConfigured -ErrorAction SilentlyContinue) -and (Test-SlackConfigured)) {
        $tools += $script:SlackSendTool
    }
    return $tools
}

# 実行すると外に出て、取り消せないツール。
# 承認の要否とは別の軸。承認が要るだけのツール (コマンド実行など) は失敗しても
# やり直せるが、こちらは送ったあとに何をしても戻らないので、
# 呼び出し側は「もう一度やらせる」判断の前にこれを見る。
function Test-IrreversibleTool {
    param([Parameter(Mandatory)] [string] $Name)
    return @('send_gmail', 'send_slack_message') -contains $Name
}

# ---------------------------------------------------------------- 危険度の判定

function Get-ToolRisk {
    <#
      .OUTPUTS
        [pscustomobject] risky (承認が必要か) / summary (一行) / detail (承認画面に出す全文)
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $ToolInput,
        [Parameter(Mandatory)] [string] $Workspace,
        # 送信先はモデルの入力ではなくワーカーが束縛したものを出す。
        # 承認画面に「モデルが言った宛先」を出しては壁にならない。
        [string] $SlackChannelName,
        [string] $GmailThreadLabel
    )

    switch ($Name) {
        'send_slack_message' {
            # 投稿は取り消せない。全文をそのまま出す。
            $where = if ($SlackChannelName) { $SlackChannelName } else { '(元の通知のチャンネル)' }
            $inThread = ($null -eq $ToolInput.reply_in_thread) -or ([bool] $ToolInput.reply_in_thread)
            $how = if ($inThread) { '元のスレッドへの返信として' } else { 'チャンネルへの新規投稿として' }
            return [pscustomobject]@{
                risky   = $true
                summary = "Slack に投稿します: $where"
                detail  = "投稿先: $where`n形式: $how`n`n--- 本文 ---`n$([string] $ToolInput.text)`n`n※投稿すると取り消せません。相手に届きます。"
            }
        }
        'send_gmail' {
            $to = if ($ToolInput.to) { $ToolInput.to } else { '(宛先未指定)' }
            $how = if ($GmailThreadLabel) { $GmailThreadLabel } else { '新規メールとして送信' }
            return [pscustomobject]@{
                risky   = $true
                summary = "メールを送信します: $($ToolInput.subject)"
                detail  = "宛先: $to`nCc: $($ToolInput.cc)`n件名: $($ToolInput.subject)`n形式: $how`n`n--- 本文 ---`n$([string] $ToolInput.body)`n`n※送信すると取り消せません。相手に届きます。"
            }
        }
        'run_command' {
            return [pscustomobject]@{
                risky   = $true
                summary = 'コマンドを実行します'
                detail  = "目的: $($ToolInput.purpose)`n実行場所: $Workspace`n`n$($ToolInput.command)"
            }
        }
        'http_fetch' {
            return [pscustomobject]@{
                risky   = $true
                summary = "外部へ通信します: $($ToolInput.url)"
                detail  = "目的: $($ToolInput.purpose)`nURL: $($ToolInput.url)`n`n※URL に情報が含まれていないか確認してください。"
            }
        }
        'create_gmail_draft' {
            # 送信はしないが、利用者本人のメールボックスに物が残る。
            # ローカルのファイル作成とは影響範囲が違うので承認を取る。
            $to = if ($ToolInput.to) { $ToolInput.to } else { '(宛先未指定)' }
            $preview = [string] $ToolInput.body
            if ($preview.Length -gt 2000) { $preview = $preview.Substring(0, 2000) + "`n…(以下省略)" }
            return [pscustomobject]@{
                risky   = $true
                summary = "Gmail に下書きを作成します: $($ToolInput.subject)"
                detail  = "宛先: $to`nCc: $($ToolInput.cc)`n件名: $($ToolInput.subject)`n`n--- 本文 ---`n$preview`n`n※作成されるのは下書きだけで、送信はされません。"
            }
        }
        'write_file' {
            $full = Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path)
            $inWs = Test-InWorkspace $Workspace $full
            $ext  = [IO.Path]::GetExtension($full).ToLower()
            $safeExt = ($script:SafeExtensions -contains $ext)
            if ($inWs -and $safeExt) {
                return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
            }
            $why = if (-not $inWs) { '作業フォルダの外です' } else { "実行される可能性のある拡張子です ($ext)" }
            $preview = [string] $ToolInput.content
            if ($preview.Length -gt 2000) { $preview = $preview.Substring(0, 2000) + "`n…(以下省略)" }
            return [pscustomobject]@{
                risky   = $true
                summary = "ファイルを書き込みます: $full"
                detail  = "理由: $why`n目的: $($ToolInput.purpose)`n書き込み先: $full`n`n--- 内容 ---`n$preview"
            }
        }
        'read_file' {
            $full = Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path)
            if (Test-InWorkspace $Workspace $full) {
                return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
            }
            return [pscustomobject]@{
                risky   = $true
                summary = "作業フォルダ外のファイルを読みます: $full"
                detail  = "読み取り先: $full"
            }
        }
        'list_files' {
            if (-not $ToolInput.path) { return [pscustomobject]@{ risky = $false; summary = ''; detail = '' } }
            $full = Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path)
            if (Test-InWorkspace $Workspace $full) {
                return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
            }
            return [pscustomobject]@{
                risky = $true; summary = "作業フォルダ外の一覧を取得します: $full"; detail = "対象: $full"
            }
        }
        default {
            return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
        }
    }
}

# ---------------------------------------------------------------- 実行

function Invoke-WorkTool {
    <#
      .SYNOPSIS
        ツール1件を実行する。承認の判断は呼び出し側 (ワーカー) が済ませている前提。
      .OUTPUTS
        [pscustomobject] text / artifact / isError
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $ToolInput,
        [Parameter(Mandatory)] [string] $Workspace,
        [int] $CommandTimeoutSec = 120,
        # Gmail から来たカードの場合、返信をスレッドにぶら下げるための識別子。
        # モデルに持ち回らせず、ワーカーが束縛して渡す。
        [string] $GmailThreadId,
        [string] $GmailInReplyTo,
        # Slack から来たカードの場合の投稿先。同じ理由でワーカーが束縛する。
        [string] $SlackChannel,
        [string] $SlackThreadTs
    )

    try {
        switch ($Name) {
            'send_slack_message' {
                if (-not (Get-Command Send-SlackMessage -ErrorAction SilentlyContinue)) {
                    throw 'Slack 連携が設定されていません。'
                }
                if (-not $SlackChannel) { throw 'このカードには Slack の投稿先がありません。' }
                $inThread = ($null -eq $ToolInput.reply_in_thread) -or ([bool] $ToolInput.reply_in_thread)
                $ts = if ($inThread) { $SlackThreadTs } else { '' }
                $r = Send-SlackMessage -Channel $SlackChannel -Text ([string] $ToolInput.text) -ThreadTs $ts
                $where = if ($inThread) { 'スレッドへの返信として' } else { 'チャンネルへの新規投稿として' }
                $link = if ($r.permalink) { " {0}" -f $r.permalink } else { '' }
                return [pscustomobject]@{
                    text     = ("Slack に投稿しました ({0})。取り消しはできません。{1}" -f $where, $link)
                    artifact = $null
                    isError  = $false
                }
            }
            'send_gmail' {
                if (-not (Get-Command Send-GmailMessage -ErrorAction SilentlyContinue)) {
                    throw 'Gmail 連携が設定されていません。'
                }
                [void] (Send-GmailMessage -To ([string] $ToolInput.to) -Cc ([string] $ToolInput.cc) `
                        -Subject ([string] $ToolInput.subject) -Body ([string] $ToolInput.body) `
                        -ThreadId $GmailThreadId -InReplyTo $GmailInReplyTo)
                $where = if ($GmailThreadId) { '元のスレッドへの返信として' } else { '新規メールとして' }
                return [pscustomobject]@{
                    text     = ("メールを送信しました ({0})。取り消しはできません。宛先: {1}" -f $where, $ToolInput.to)
                    artifact = $null
                    isError  = $false
                }
            }
            'create_gmail_draft' {
                if (-not (Get-Command New-GmailDraft -ErrorAction SilentlyContinue)) {
                    throw 'Gmail 連携が設定されていません。'
                }
                $d = New-GmailDraft -To ([string] $ToolInput.to) -Cc ([string] $ToolInput.cc) `
                        -Subject ([string] $ToolInput.subject) -Body ([string] $ToolInput.body) `
                        -ThreadId $GmailThreadId -InReplyTo $GmailInReplyTo
                $where = if ($GmailThreadId) { '元のスレッドへの返信として' } else { '新規メールとして' }
                return [pscustomobject]@{
                    text     = ("Gmail に下書きを作成しました ({0})。下書きID: {1}" -f $where, $d.id)
                    artifact = $null
                    isError  = $false
                }
            }
            'write_file' {
                $full = Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path)
                $content = [string] $ToolInput.content
                $bytes = [Text.Encoding]::UTF8.GetBytes($content)
                if ($bytes.Length -gt $script:MaxContentBytes) { throw 'ファイルが大きすぎます (上限 1MB)' }
                $dir = Split-Path -Parent $full
                if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [IO.File]::WriteAllText($full, $content, (New-Object Text.UTF8Encoding($false)))
                return [pscustomobject]@{
                    text     = ("作成しました: {0} ({1} バイト)" -f $full, $bytes.Length)
                    artifact = $full
                    isError  = $false
                }
            }

            'create_email_draft' {
                $rel = if ($ToolInput.path) { [string] $ToolInput.path } else { 'draft.eml' }
                if ([IO.Path]::GetExtension($rel).ToLower() -ne '.eml') { $rel = $rel + '.eml' }
                $full = Resolve-TargetPath -Workspace $Workspace -Relative $rel

                $sb = New-Object Text.StringBuilder
                [void] $sb.AppendLine("To: " + (ConvertTo-MimeHeader ([string] $ToolInput.to)))
                if ($ToolInput.cc) { [void] $sb.AppendLine("Cc: " + (ConvertTo-MimeHeader ([string] $ToolInput.cc))) }
                [void] $sb.AppendLine("Subject: " + (ConvertTo-MimeHeader ([string] $ToolInput.subject)))
                [void] $sb.AppendLine("Date: " + (Get-Date).ToString('r'))
                [void] $sb.AppendLine("MIME-Version: 1.0")
                [void] $sb.AppendLine("Content-Type: text/plain; charset=UTF-8")
                [void] $sb.AppendLine("Content-Transfer-Encoding: 8bit")
                # Outlook はこれを見て「未送信の下書き」として開く
                [void] $sb.AppendLine("X-Unsent: 1")
                [void] $sb.AppendLine()
                [void] $sb.Append([string] $ToolInput.body)

                [IO.File]::WriteAllText($full, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
                $to = if ($ToolInput.to) { $ToolInput.to } else { '(宛先未定)' }
                return [pscustomobject]@{
                    text     = ("メールの下書きを作成しました: {0} / 宛先 {1} / 件名 {2}" -f $rel, $to, $ToolInput.subject)
                    artifact = $full
                    isError  = $false
                }
            }

            'read_file' {
                $full = Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path)
                if (-not (Test-Path -LiteralPath $full)) { throw "ファイルがありません: $full" }
                return [pscustomobject]@{
                    text     = Limit-Text ([IO.File]::ReadAllText($full, [Text.Encoding]::UTF8))
                    artifact = $null
                    isError  = $false
                }
            }

            'list_files' {
                $target = if ($ToolInput.path) { Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path) } else { $Workspace }
                if (-not (Test-Path -LiteralPath $target)) { throw "フォルダがありません: $target" }
                $files = @(Get-ChildItem -LiteralPath $target -File -ErrorAction SilentlyContinue)
                $text = if ($files.Count -eq 0) { '(ファイルはありません)' }
                        else { ($files | ForEach-Object { "{0} ({1} バイト)" -f $_.Name, $_.Length }) -join "`n" }
                return [pscustomobject]@{ text = Limit-Text $text; artifact = $null; isError = $false }
            }

            'run_command' {
                $cmd = [string] $ToolInput.command
                $job = Start-Job -ScriptBlock {
                    param($c, $wd)
                    Set-Location -LiteralPath $wd
                    & powershell -NoProfile -NonInteractive -Command $c 2>&1 | Out-String
                } -ArgumentList $cmd, $Workspace
                try {
                    if (Wait-Job $job -Timeout $CommandTimeoutSec) {
                        $out = (Receive-Job $job) -join "`n"
                        $text = if ($out.Trim()) { $out } else { '(出力なし。コマンドは完了しました)' }
                        return [pscustomobject]@{ text = Limit-Text $text; artifact = $null; isError = $false }
                    }
                    Stop-Job $job
                    return [pscustomobject]@{
                        text = "タイムアウトしました ($CommandTimeoutSec 秒)。処理は中断されました。"
                        artifact = $null; isError = $true
                    }
                }
                finally { Remove-Job $job -Force -ErrorAction SilentlyContinue }
            }

            'http_fetch' {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $resp = Invoke-WebRequest -Uri ([string] $ToolInput.url) -Method Get -UseBasicParsing -TimeoutSec 30
                $body = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
                return [pscustomobject]@{
                    text     = Limit-Text ("HTTP {0}`n`n{1}" -f $resp.StatusCode, $body)
                    artifact = $null
                    isError  = $false
                }
            }

            default { throw "未知のツールです: $Name" }
        }
    }
    catch {
        # 失敗もモデルに返す。握り潰すと同じ誤りを繰り返す。
        return [pscustomobject]@{ text = ("エラー: " + $_.Exception.Message); artifact = $null; isError = $true }
    }
}
