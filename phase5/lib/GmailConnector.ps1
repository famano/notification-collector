# GmailConnector.ps1
# Gmail API。通知経路に依存せず、メール本文を直接取得し、下書きの作成と送信を行う。
#
# 認証は OAuth 2.0 のループバック方式（デスクトップアプリ）。
# 既に HttpListener を持っているので、リダイレクト受けを自前で立てられる。
# リフレッシュトークンは DPAPI で暗号化して保存する。

. "$PSScriptRoot\SecretStore.ps1"

$script:GmailApi   = 'https://gmail.googleapis.com/gmail/v1'
$script:GoogleAuth = 'https://accounts.google.com/o/oauth2/v2/auth'
$script:GoogleToken = 'https://oauth2.googleapis.com/token'

# readonly は本文取得、compose は下書き作成と送信に必要。
# 注意: Google には「下書きだけ」のスコープが無く、compose は送信も許す。
# 送信は Send-GmailMessage からのみ行い、そこに至るには必ずカンバンでの承認を通る
# (判定は phase4/lib/WorkTools.ps1)。既存のトークンのままで送信できてしまうので、
# 送らせたくない場合はスコープではなく承認側で止めること。
$script:GmailScopes = @(
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/gmail.compose'
) -join ' '

function Test-GmailConfigured {
    return [bool] ((Get-Secret -Name 'gmail.refreshToken') -and (Get-Secret -Name 'gmail.clientId'))
}

function ConvertTo-Base64Url {
    param([byte[]] $Bytes)
    return ([Convert]::ToBase64String($Bytes)) -replace '\+', '-' -replace '/', '_' -replace '=', ''
}

function ConvertFrom-Base64Url {
    param([string] $Text)
    if (-not $Text) { return [byte[]] @() }
    $s = $Text -replace '-', '+' -replace '_', '/'
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } 1 { $s += '===' } }
    return [Convert]::FromBase64String($s)
}

# ---------------------------------------------------------------- 認証

function Start-GmailAuth {
    <#
      .SYNOPSIS
        ブラウザで同意を取り、リフレッシュトークンを保存する。対話的に一度だけ実行する。
    #>
    param(
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $ClientSecret,
        [int] $Port = 0
    )

    # 空きポートを取ってループバックの受け口にする
    if ($Port -le 0) {
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $l.Start(); $Port = $l.LocalEndpoint.Port; $l.Stop()
    }
    $redirect = "http://127.0.0.1:$Port/"

    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add($redirect)
    $listener.Start()

    $state = [guid]::NewGuid().ToString('N')
    $url = "$script:GoogleAuth" +
        "?client_id=$([Uri]::EscapeDataString($ClientId))" +
        "&redirect_uri=$([Uri]::EscapeDataString($redirect))" +
        "&response_type=code" +
        "&scope=$([Uri]::EscapeDataString($script:GmailScopes))" +
        "&access_type=offline&prompt=consent&state=$state"

    Write-Host 'ブラウザで Google の同意画面を開きます。' -ForegroundColor Cyan
    Write-Host '同意すると自動的にこのウィンドウに戻ります。' -ForegroundColor DarkGray
    Start-Process $url

    try {
        $ctx = $listener.GetContext()
        $q = $ctx.Request.Url.Query
        $code = $null; $gotState = $null
        foreach ($pair in ($q.TrimStart('?') -split '&')) {
            $kv = $pair -split '=', 2
            if ($kv.Count -eq 2) {
                if ($kv[0] -eq 'code')  { $code = [Uri]::UnescapeDataString($kv[1]) }
                if ($kv[0] -eq 'state') { $gotState = $kv[1] }
            }
        }
        $msg = if ($code) { '認証できました。このタブは閉じてかまいません。' } else { '認証に失敗しました。' }
        $bytes = [Text.Encoding]::UTF8.GetBytes("<html><meta charset='utf-8'><body style='font-family:sans-serif'>$msg</body></html>")
        $ctx.Response.ContentType = 'text/html; charset=utf-8'
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.OutputStream.Close()

        if (-not $code) { throw '認可コードを受け取れませんでした。' }
        if ($gotState -ne $state) { throw 'state が一致しません。中断します。' }
    }
    finally { $listener.Stop(); $listener.Close() }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = @{
        code = $code; client_id = $ClientId; client_secret = $ClientSecret
        redirect_uri = $redirect; grant_type = 'authorization_code'
    }
    $resp = Invoke-RestMethod -Uri $script:GoogleToken -Method Post -Body $body -TimeoutSec 30
    if (-not $resp.refresh_token) {
        throw 'リフレッシュトークンが返りませんでした。Google 側でこのアプリの許可を一度取り消してから再実行してください。'
    }

    Set-Secret -Name 'gmail.clientId'     -Value $ClientId
    Set-Secret -Name 'gmail.clientSecret' -Value $ClientSecret
    Set-Secret -Name 'gmail.refreshToken' -Value $resp.refresh_token
    Write-Host 'Gmail の資格情報を保存しました。' -ForegroundColor Green
}

$script:GmailToken = $null
$script:GmailTokenExpiry = [DateTime]::MinValue

function Get-GmailAccessToken {
    if ($script:GmailToken -and (Get-Date) -lt $script:GmailTokenExpiry) { return $script:GmailToken }

    $cid = Get-Secret -Name 'gmail.clientId'
    $sec = Get-Secret -Name 'gmail.clientSecret'
    $ref = Get-Secret -Name 'gmail.refreshToken'
    if (-not $ref) { throw 'Gmail が未設定です。Connect-Service.ps1 -Service gmail を実行してください。' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $resp = Invoke-RestMethod -Uri $script:GoogleToken -Method Post -TimeoutSec 30 -Body @{
        client_id = $cid; client_secret = $sec; refresh_token = $ref; grant_type = 'refresh_token'
    }
    $script:GmailToken = $resp.access_token
    # 期限ぎりぎりで使わないよう少し早めに切る
    $script:GmailTokenExpiry = (Get-Date).AddSeconds([int] $resp.expires_in - 60)
    return $script:GmailToken
}

function Invoke-GmailApi {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'Get',
        $Body
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ Authorization = "Bearer $(Get-GmailAccessToken)" }
    # $args は自動変数なので避ける。splat 先で取り違えると原因が追えなくなる。
    $req = @{
        Uri = "$script:GmailApi$Path"; Method = $Method; Headers = $headers
        UseBasicParsing = $true; TimeoutSec = 60
    }
    if ($Body) {
        $req['ContentType'] = 'application/json'
        $req['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress))
    }
    try {
        $resp = Invoke-WebRequest @req
    }
    catch [Net.WebException] {
        # Google は失敗理由を本文の JSON に入れてくる。
        # Slack 側で ok:false を握り潰さないのと同じ理由で、ここでも本文まで出す。
        $detail = ''
        $r = $_.Exception.Response
        if ($r) {
            $sr = New-Object IO.StreamReader($r.GetResponseStream())
            try { $raw = $sr.ReadToEnd() } finally { $sr.Dispose() }
            $parsed = $null
            try { $parsed = $raw | ConvertFrom-Json } catch { }
            $detail = if ($parsed -and $parsed.error) {
                "{0} ({1})" -f $parsed.error.message, $parsed.error.status
            } else { $raw }
        }
        throw ("Gmail API {0} が失敗しました: {1} / {2}" -f $Path, $_.Exception.Message, $detail)
    }
    return ([Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json)
}

# ---------------------------------------------------------------- 読み取り

function Get-GmailHeader {
    param($Payload, [string] $Name)
    foreach ($h in @($Payload.headers)) { if ($h.name -ieq $Name) { return [string] $h.value } }
    return ''
}

# text/plain を優先し、無ければ HTML からタグを落とす
function Get-GmailBodyText {
    param($Part)
    if (-not $Part) { return '' }
    if ($Part.mimeType -eq 'text/plain' -and $Part.body.data) {
        return [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $Part.body.data))
    }
    foreach ($p in @($Part.parts)) {
        $t = Get-GmailBodyText $p
        if ($t) { return $t }
    }
    if ($Part.mimeType -eq 'text/html' -and $Part.body.data) {
        $html = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $Part.body.data))
        $txt = $html -replace '(?s)<(script|style).*?</\1>', ''
        $txt = $txt -replace '<br\s*/?>', "`n" -replace '</p>', "`n"
        $txt = $txt -replace '<[^>]+>', ''
        return ($txt -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>').Trim()
    }
    return ''
}

function Get-GmailMessage {
    param([Parameter(Mandatory)] [string] $MessageId)
    # ${MessageId} と括ること。"$MessageId?format" は ? まで変数名に取り込まれて空になる。
    $m = Invoke-GmailApi -Path "/users/me/messages/${MessageId}?format=full"
    $body = Get-GmailBodyText $m.payload
    return [pscustomobject]@{
        id        = $m.id
        threadId  = $m.threadId
        subject   = Get-GmailHeader $m.payload 'Subject'
        from      = Get-GmailHeader $m.payload 'From'
        to        = Get-GmailHeader $m.payload 'To'
        cc        = Get-GmailHeader $m.payload 'Cc'
        date      = Get-GmailHeader $m.payload 'Date'
        messageId = Get-GmailHeader $m.payload 'Message-ID'
        snippet   = $m.snippet
        body      = $body
        labelIds  = @($m.labelIds)
    }
}

function Get-GmailRecent {
    <#
      .SYNOPSIS
        条件に合うメールの一覧を取り、本文まで取得して返す。
      .PARAMETER Query
        Gmail の検索構文。既定は「受信トレイの未読、1日以内」。
    #>
    param([string] $Query = 'in:inbox is:unread newer_than:1d', [int] $Max = 20)
    $list = Invoke-GmailApi -Path ("/users/me/messages?q={0}&maxResults={1}" -f [Uri]::EscapeDataString($Query), $Max)
    $out = @()
    foreach ($m in @($list.messages)) { $out += Get-GmailMessage -MessageId $m.id }
    return $out
}

# ---------------------------------------------------------------- 下書き作成

# 下書きと送信で同じ本文を使う。片方だけ整形を直して食い違うのを避ける。
function New-GmailRawMessage {
    param(
        [string] $To, [string] $Cc,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $Body,
        [string] $InReplyTo
    )
    $sb = New-Object Text.StringBuilder
    if ($To) { [void] $sb.AppendLine("To: $To") }
    if ($Cc) { [void] $sb.AppendLine("Cc: $Cc") }
    [void] $sb.AppendLine("Subject: " + (ConvertTo-RfcHeader $Subject))
    if ($InReplyTo) {
        [void] $sb.AppendLine("In-Reply-To: $InReplyTo")
        [void] $sb.AppendLine("References: $InReplyTo")
    }
    [void] $sb.AppendLine('MIME-Version: 1.0')
    [void] $sb.AppendLine('Content-Type: text/plain; charset=UTF-8')
    [void] $sb.AppendLine('Content-Transfer-Encoding: base64')
    [void] $sb.AppendLine()
    # 本文も base64 にする。生の UTF-8 を 8bit で流すと環境により壊れる。
    [void] $sb.AppendLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Body)))

    return ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($sb.ToString()))
}

function New-GmailDraft {
    <#
      .SYNOPSIS
        Gmail に本物の下書きを作る。送信は行わない。
      .PARAMETER ThreadId / InReplyTo
        返信にする場合に指定する。スレッドにぶら下がる。
    #>
    param(
        [string] $To, [string] $Cc,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $Body,
        [string] $ThreadId, [string] $InReplyTo
    )
    $raw = New-GmailRawMessage -To $To -Cc $Cc -Subject $Subject -Body $Body -InReplyTo $InReplyTo
    $payload = @{ message = @{ raw = $raw } }
    if ($ThreadId) { $payload.message['threadId'] = $ThreadId }

    $d = Invoke-GmailApi -Path '/users/me/drafts' -Method 'Post' -Body $payload
    return [pscustomobject]@{ id = $d.id; messageId = $d.message.id; threadId = $d.message.threadId }
}

function Send-GmailMessage {
    <#
      .SYNOPSIS
        メールを送信する。取り消せないので、呼び出し側は必ず承認を取ってから呼ぶこと。
      .PARAMETER ThreadId / InReplyTo
        返信にする場合に指定する。元のスレッドにぶら下がる。
    #>
    param(
        [Parameter(Mandatory)] [string] $To, [string] $Cc,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $Body,
        [string] $ThreadId, [string] $InReplyTo
    )
    # 宛先の無い送信は Gmail 側でも弾かれるが、その前に止める。
    # 空欄のまま出して「送ったつもり」になるのが一番まずい。
    if (-not $To.Trim()) { throw '宛先が空です。' }

    $raw = New-GmailRawMessage -To $To -Cc $Cc -Subject $Subject -Body $Body -InReplyTo $InReplyTo
    $payload = @{ raw = $raw }
    if ($ThreadId) { $payload['threadId'] = $ThreadId }

    $m = Invoke-GmailApi -Path '/users/me/messages/send' -Method 'Post' -Body $payload
    return [pscustomobject]@{ id = $m.id; threadId = $m.threadId }
}

function ConvertTo-RfcHeader {
    param([string] $Value)
    if (-not $Value) { return '' }
    $isAscii = $true
    foreach ($ch in $Value.ToCharArray()) { if ([int]$ch -gt 127) { $isAscii = $false; break } }
    if ($isAscii) { return $Value }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    # ${b64} と括ること。"$b64?=" は ? まで変数名に取り込まれて空になる。
    return "=?UTF-8?B?${b64}?="
}
