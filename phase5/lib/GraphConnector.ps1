# GraphConnector.ps1
# Microsoft Graph。Outlook のメールと Teams のチャットを、通知経路に依存せずに取り直す。
#
# Slack / Gmail と同じ立て付けにしてある ―― 通知は低遅延のトリガに徹し、
# 取りこぼしの無さは watermark 同期で担保する。Outlook も Teams も、
# PC を落としていた間のトーストは配信されないので、そこは API 側から埋める。
#
# 認証はデバイスコードフロー。理由は「登録の手間が一番軽いから」である:
#   - リダイレクト URI を1つも登録しなくてよい (公開クライアントとして許可するだけ)
#   - クライアント シークレットが要らない。つまり保存すべき秘密がひとつ減る
#   - カンバン (1本のループで要求を捌く) を止めずに進められる。画面はコードを出し、
#     ブラウザ側が数秒おきに聞きに来る。サーバ側で待ち続ける必要がない
# テナントによってはデバイスコードフローを条件付きアクセスで塞いでいることがある。
# そのときは管理者に許可を求めるしかない (回避する手段は用意しない)。
#
# 注意: Microsoft のリフレッシュトークンは**使うたびに新しいものに入れ替わる**。
# Google と違い、引き換えた新しい値を保存し直さないと、いずれ使えなくなる。

. "$PSScriptRoot\SecretStore.ps1"
# Outlook の本文も Teams の本文も HTML で返る。落とし方は Gmail と共通にする。
. "$PSScriptRoot\HtmlText.ps1"

$script:GraphApi = 'https://graph.microsoft.com/v1.0'

# 要求するスコープ。
#   User.Read       … 「誰として繋がったか」と、自分のユーザーID (メンション判定に使う)
#   Mail.ReadWrite  … 受信メールの取得と、本物の下書きの作成
#   Mail.Send       … 送信。Gmail と違い読み書きと送信のスコープが分かれている
#   Chat.Read       … 自分が参加しているチャット (1:1 / グループ / 会議) の閲覧
#   ChatMessage.Send… そのチャットへの投稿
#   offline_access  … リフレッシュトークン。これが無いと1時間で切れて終わり
#
# チャネル (チーム内の投稿) は入れていない。ChannelMessage.Read.All は
# 管理者の同意が要るうえアプリケーション権限寄りで、「自分に来たもの」より
# 広い範囲が読めてしまう。自分宛の会話はチャットに来るので、そこで足りる。
$script:GraphScopes = @(
    'offline_access',
    'User.Read',
    'Mail.ReadWrite',
    'Mail.Send',
    'Chat.Read',
    'ChatMessage.Send'
) -join ' '

function Get-GraphTenant {
    $t = Get-Secret -Name 'ms.tenantId'
    if ($t) { return $t }
    # 既定は organizations (職場・学校アカウント)。
    # 個人の Microsoft アカウントでも Outlook は読めるが、Teams のチャットは
    # 個人アカウントでは API が提供されていない (delegated 非対応)。
    return 'organizations'
}

function Test-GraphConfigured {
    return [bool] ((Get-Secret -Name 'ms.refreshToken') -and (Get-Secret -Name 'ms.clientId'))
}

function Get-GraphTokenEndpoint {
    param([string] $Tenant)
    if (-not $Tenant) { $Tenant = Get-GraphTenant }
    return "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
}

# ---------------------------------------------------------------- 認証 (デバイスコード)

# 同意待ちの途中経過。端末からもカンバンからも同じものを使う。
# 秘密はここでは保存しない ―― 同意が返ってくるまではメモリに置く。
$script:PendingGraphDevice = $null

function Start-GraphDeviceCode {
    <#
      .SYNOPSIS
        デバイスコードを発行する。画面に出すのは userCode と verificationUri。
      .OUTPUTS
        [pscustomobject] ok / userCode / verificationUri / message / interval / expiresInSec / error
    #>
    param(
        [Parameter(Mandatory)] [string] $ClientId,
        [string] $TenantId,
        # 任意。パブリック クライアント フローを許可していない (機密クライアントの) 登録用。
        # コードの発行には要らず、トークンへの引き換えにだけ使う。
        [string] $ClientSecret
    )
    $tenant = $TenantId
    if (-not $tenant) { $tenant = 'organizations' }
    $tenant = $tenant.Trim()
    $cid = $ClientId.Trim()

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $resp = Invoke-RestMethod -Method Post -TimeoutSec 30 `
            -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/devicecode" `
            -Body @{ client_id = $cid; scope = $script:GraphScopes }
    }
    catch {
        return [pscustomobject]@{ ok = $false; error = (Get-GraphTokenErrorMessage $_) }
    }

    $interval = 5
    if ($resp.interval) { $interval = [int] $resp.interval }
    $expires = 900
    if ($resp.expires_in) { $expires = [int] $resp.expires_in }

    $script:PendingGraphDevice = @{
        clientId   = $cid
        tenantId   = $tenant
        clientSecret = ([string] $ClientSecret).Trim()
        deviceCode = [string] $resp.device_code
        interval   = $interval
        expiresAt  = (Get-Date).AddSeconds($expires)
    }
    return [pscustomobject]@{
        ok              = $true
        userCode        = [string] $resp.user_code
        verificationUri = [string] $resp.verification_uri
        message         = [string] $resp.message
        interval        = $interval
        expiresInSec    = $expires
        error           = ''
    }
}

function Test-GraphDeviceCode {
    <#
      .SYNOPSIS
        同意が済んだかを**1回だけ**問い合わせる。待たない。
      .DESCRIPTION
        待たないのは呼び出し側の都合による。カンバンは1本のループで要求を捌くので、
        ここで同意を待つと画面ごと固まる。ブラウザ側から数秒おきに呼んでもらう。
      .OUTPUTS
        [pscustomobject] state = 'pending' | 'ok' | 'error'、account / error
    #>
    $p = $script:PendingGraphDevice
    if (-not $p) {
        return [pscustomobject]@{ state = 'error'; error = '設定の途中経過が見つかりません。もう一度やり直してください。'; account = '' }
    }
    if ((Get-Date) -gt $p.expiresAt) {
        $script:PendingGraphDevice = $null
        return [pscustomobject]@{ state = 'error'; error = '時間切れです。もう一度やり直してください。'; account = '' }
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = @{
        grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
        client_id   = $p.clientId
        device_code = $p.deviceCode
    }
    if ($p.clientSecret) { $body['client_secret'] = $p.clientSecret }
    try {
        $resp = Invoke-RestMethod -Method Post -TimeoutSec 30 `
            -Uri (Get-GraphTokenEndpoint $p.tenantId) -Body $body
    }
    catch {
        $code = Get-GraphOAuthErrorCode $_
        # ポーリング中の既定の応答。エラーではない。
        if ($code -eq 'authorization_pending') {
            return [pscustomobject]@{ state = 'pending'; error = ''; account = '' }
        }
        if ($code -eq 'slow_down') {
            # 間隔を広げろという指示。次回からゆっくり聞く。
            $script:PendingGraphDevice.interval = [int] $script:PendingGraphDevice.interval + 5
            return [pscustomobject]@{ state = 'pending'; error = ''; account = '' }
        }
        $script:PendingGraphDevice = $null
        return [pscustomobject]@{ state = 'error'; error = (Get-GraphTokenErrorMessage $_); account = '' }
    }

    if (-not $resp.refresh_token) {
        $script:PendingGraphDevice = $null
        return [pscustomobject]@{
            state = 'error'; account = ''
            error = 'リフレッシュトークンが返りませんでした。アプリ登録の API のアクセス許可に offline_access を足してください。'
        }
    }

    Set-Secret -Name 'ms.clientId'     -Value $p.clientId
    Set-Secret -Name 'ms.tenantId'     -Value $p.tenantId
    Set-Secret -Name 'ms.refreshToken' -Value ([string] $resp.refresh_token)
    # シークレット無しで繋いだなら、前のアプリ登録のシークレットを残さない。
    # 残すと更新のたびに別の登録のシークレットが送られ、invalid_client で止まる。
    if ($p.clientSecret) { Set-Secret -Name 'ms.clientSecret' -Value $p.clientSecret }
    else { [void] (Remove-Secret -Name 'ms.clientSecret') }
    $script:PendingGraphDevice = $null

    # 取り立てのアクセストークンをそのまま使う。ここで捨てて取り直す理由がない。
    $script:GraphToken = [string] $resp.access_token
    $script:GraphTokenSource = [string] $resp.refresh_token
    $script:GraphTokenExpiry = (Get-Date).AddSeconds([int] $resp.expires_in - 60)
    if ($resp.scope) { $script:GraphGrantedScopes = @(([string] $resp.scope) -split '\s+') }

    $account = ''
    try {
        $me = Get-GraphMe
        $account = $me.account
    } catch { }
    return [pscustomobject]@{ state = 'ok'; error = ''; account = $account }
}

function Wait-GraphDeviceCode {
    <#
      .SYNOPSIS
        端末から使うときの待ち受け。Test-GraphDeviceCode を間隔をあけて呼び続ける。
    #>
    param([int] $TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Test-GraphDeviceCode
        if ($r.state -ne 'pending') { return $r }
        $wait = 5
        if ($script:PendingGraphDevice) { $wait = [int] $script:PendingGraphDevice.interval }
        Start-Sleep -Seconds $wait
    }
    return [pscustomobject]@{ state = 'error'; error = '時間内に同意が確認できませんでした。'; account = '' }
}

# ---------------------------------------------------------------- アクセストークン

$script:GraphToken = $null
$script:GraphTokenExpiry = [DateTime]::MinValue
# いまのアクセストークンを、どのリフレッシュトークンから引き換えたか。
$script:GraphTokenSource = $null
$script:GraphGrantedScopes = @()

function Clear-GraphAccessToken {
    $script:GraphToken = $null
    $script:GraphTokenExpiry = [DateTime]::MinValue
    $script:GraphTokenSource = $null
}

function Get-GraphAccessToken {
    # キャッシュの条件は Gmail と同じ ――「保存されているリフレッシュトークンが、
    # 引き換えたときと同じ」あいだだけ使う。期限だけで判断すると、
    # カンバンで繋ぎ直してもワーカー (別プロセス) が最大1時間、古いトークンを使い続ける。
    $ref = Get-Secret -Name 'ms.refreshToken'
    if (-not $ref) {
        Clear-GraphAccessToken
        throw 'Microsoft 365 が未設定です。カンバンの「接続」から繋いでください (端末なら .\phase5\Connect-Service.ps1 -Service microsoft)。'
    }
    if ($script:GraphToken -and $script:GraphTokenSource -eq $ref -and (Get-Date) -lt $script:GraphTokenExpiry) {
        return $script:GraphToken
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = @{
        client_id = (Get-Secret -Name 'ms.clientId')
        refresh_token = $ref
        grant_type = 'refresh_token'
        scope = $script:GraphScopes
    }
    # 機密クライアントとして繋いだ場合は、更新にもシークレットが要る。
    $sec = Get-Secret -Name 'ms.clientSecret'
    if ($sec) { $body['client_secret'] = $sec }
    try {
        $resp = Invoke-RestMethod -Method Post -TimeoutSec 30 -Uri (Get-GraphTokenEndpoint) -Body $body
    }
    catch {
        Clear-GraphAccessToken
        throw (Get-GraphTokenErrorMessage $_)
    }

    $script:GraphToken = [string] $resp.access_token
    $script:GraphTokenExpiry = (Get-Date).AddSeconds([int] $resp.expires_in - 60)
    if ($resp.scope) { $script:GraphGrantedScopes = @(([string] $resp.scope) -split '\s+') }

    # **入れ替わったリフレッシュトークンを保存し直す。**
    # Microsoft は更新のたびに新しいものを返し、古いものはいずれ使えなくなる。
    # 保存を怠ると「しばらく動いていたのに、ある日から invalid_grant」になり、
    # 原因が設定時から遠く離れるので一番たちが悪い。
    $newRef = [string] $resp.refresh_token
    if ($newRef -and $newRef -ne $ref) {
        Set-Secret -Name 'ms.refreshToken' -Value $newRef
        $script:GraphTokenSource = $newRef
    }
    else {
        $script:GraphTokenSource = $ref
    }
    return $script:GraphToken
}

function Test-GraphScope {
    <#
      .SYNOPSIS
        いま持っているトークンに指定のスコープが入っているか。
      .DESCRIPTION
        入っていなければ叩く前に諦めてよい。403 を食ってから報告するより、
        「権限が足りない」と名指しできるほうが設定カードに変換できる。
        あとからスコープを足しても、既存のリフレッシュトークンには入っていない。
    #>
    param([Parameter(Mandatory)] [string] $Scope)
    if (-not (Test-GraphConfigured)) { return $false }
    try { [void] (Get-GraphAccessToken) } catch { return $false }
    # 付与されたスコープは URI 形式 (https://graph.microsoft.com/Mail.Send) で返る。
    # 短い名前で聞かれても答えられるように、末尾で見る。
    foreach ($s in @($script:GraphGrantedScopes)) {
        if ($s -eq $Scope) { return $true }
        if ($s -like ('*/' + $Scope)) { return $true }
    }
    return $false
}

# OAuth のエラー本文から error コードだけを取り出す。
# 例外の文言は「(400) 不正な要求」しか持っておらず、理由は本文にしかない。
function Get-GraphOAuthErrorBody {
    param($ErrorRecord)
    $raw = ''
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $raw = [string] $ErrorRecord.ErrorDetails.Message }
    $r = $ErrorRecord.Exception.Response
    if (-not $raw -and $r) {
        try {
            $sr = New-Object IO.StreamReader($r.GetResponseStream())
            try { $raw = $sr.ReadToEnd() } finally { $sr.Dispose() }
        } catch { }
    }
    return $raw
}

function Get-GraphOAuthErrorCode {
    param($ErrorRecord)
    $raw = Get-GraphOAuthErrorBody $ErrorRecord
    if (-not $raw) { return '' }
    try { return [string] ($raw | ConvertFrom-Json).error } catch { return '' }
}

function Get-GraphTokenErrorMessage {
    param($ErrorRecord)
    $raw = Get-GraphOAuthErrorBody $ErrorRecord
    $code = ''; $desc = ''
    try {
        $j = $raw | ConvertFrom-Json
        $code = [string] $j.error
        $desc = [string] $j.error_description
    } catch { }

    $why = if ($code -and $desc) { "{0} ({1})" -f $code, $desc }
           elseif ($code) { $code }
           elseif ($raw) { $raw }
           else { $ErrorRecord.Exception.Message }

    # AADSTS の番号は、設定のどこを直せばよいかとほぼ1対1で対応する。
    # 番号のまま返しても利用者には読めないので、ここで日本語に落とす。
    $advice = ''
    if ($why -match 'AADSTS7000218') {
        $advice = 'アプリ登録で「パブリック クライアント フローを許可する」を「はい」にしてください。' +
                  '「はい」にできない場合は、クライアント シークレットを発行して入れてください。'
    }
    elseif ($why -match 'AADSTS7000215' -or $why -match 'AADSTS7000222') {
        $advice = 'クライアント シークレットが正しくないか、期限切れです。アプリ登録の「証明書とシークレット」で発行し直してください。'
    }
    elseif ($why -match 'AADSTS700016' -or $code -eq 'unauthorized_client') {
        $advice = 'クライアント ID かテナントが正しくありません。アプリ登録の「アプリケーション (クライアント) ID」を確認してください。'
    }
    elseif ($why -match 'AADSTS65001' -or $why -match 'AADSTS90094' -or $code -eq 'consent_required') {
        $advice = '同意が済んでいません。テナントによっては管理者の同意が要ります。'
    }
    elseif ($why -match 'AADSTS50059' -or $why -match 'AADSTS50020') {
        $advice = 'テナントの指定を見直してください (職場アカウントなら organizations、個人アカウントなら consumers)。'
    }
    elseif ($code -eq 'invalid_grant') {
        $advice = '許可が取り消されたか、リフレッシュトークンが失効しています。接続し直してください。'
    }
    elseif ($code -eq 'authorization_declined') {
        $advice = 'サインイン画面で拒否されました。'
    }
    elseif ($code -eq 'expired_token') {
        $advice = 'コードの有効期限が切れました。もう一度やり直してください。'
    }

    $msg = "Microsoft のトークンを取得できませんでした: $why"
    if ($advice) { $msg += "`n$advice" }
    return $msg
}

# ---------------------------------------------------------------- API 呼び出し

function Invoke-GraphApi {
    <#
      .SYNOPSIS
        Graph を1回叩く。失敗したときは**理由を本文から起こして**投げる。
      .PARAMETER Prefer
        Prefer ヘッダ。本文を平文で受け取るときに使う。
      .PARAMETER Path
        /me/messages のような v1.0 からの相対パス。完全な URL を渡してもよい
        (@odata.nextLink をそのまま辿れるようにするため)。
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'Get',
        $Body,
        [string] $Prefer,
        [switch] $Raw
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $uri = if ($Path -like 'http*') { $Path } else { "$script:GraphApi$Path" }

    $headers = @{ Authorization = "Bearer $(Get-GraphAccessToken)" }
    if ($Prefer) { $headers['Prefer'] = $Prefer }

    $req = @{
        Uri = $uri; Method = $Method; Headers = $headers
        UseBasicParsing = $true; TimeoutSec = 60
    }
    if ($null -ne $Body) {
        $req['ContentType'] = 'application/json; charset=utf-8'
        $req['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress))
    }

    try {
        $resp = Invoke-WebRequest @req
    }
    catch [Net.WebException] {
        $status = 0
        $detail = ''
        $r = $_.Exception.Response
        if ($r) {
            try { $status = [int] $r.StatusCode } catch { }
            # 401 は手元のトークンがもう効いていない。持ったままだと期限まで
            # 同じ 401 を返し続けるので、ここで捨てて次回取り直させる。
            if ($status -eq 401) { Clear-GraphAccessToken }
            try {
                $sr = New-Object IO.StreamReader($r.GetResponseStream())
                try { $rawBody = $sr.ReadToEnd() } finally { $sr.Dispose() }
                $parsed = $null
                try { $parsed = $rawBody | ConvertFrom-Json } catch { }
                $detail = if ($parsed -and $parsed.error) {
                    "{0} ({1})" -f $parsed.error.message, $parsed.error.code
                } else { $rawBody }
            } catch { }
        }
        # 末尾の (HTTP nnn) は飾りではない。呼び出し側が
        # 「次回もう一度読むべき失敗か」を判定するのに使う (Test-GraphPermanentError)。
        throw ("Microsoft Graph {0} が失敗しました: {1} / {2} (HTTP {3})" -f $Path, $_.Exception.Message, $detail, $status)
    }

    if ($Raw) { return $resp.RawContentStream.ToArray() }
    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

function Test-GraphPermanentError {
    <#
      .SYNOPSIS
        何度読み直しても結果が変わらない失敗か。
      .DESCRIPTION
        Slack の掃き寄せと同じ判断がここでも要る。権限不足やチャットの消滅で
        watermark を止めると、読める会話の分まで永久に入らなくなる。
        逆にレート制限や通信断で進めてしまうと、その範囲が取りこぼしになる。
    #>
    param([string] $Message)
    if (-not $Message) { return $false }
    if ($Message -notmatch 'HTTP (\d+)') { return $false }
    $code = [int] $Matches[1]
    # 400 不正な要求 / 403 権限不足 / 404 消えた・見えない / 405 その種類では叩けない
    return (@(400, 403, 404, 405) -contains $code)
}

function Get-GraphMe {
    <#
      .OUTPUTS
        [pscustomobject] id / account / displayName
    #>
    $me = Invoke-GraphApi -Path '/me?$select=id,displayName,mail,userPrincipalName'
    $account = [string] $me.mail
    if (-not $account) { $account = [string] $me.userPrincipalName }
    return [pscustomobject]@{
        id = [string] $me.id; account = $account; displayName = [string] $me.displayName
    }
}

# 自分のユーザーID。メンション判定と「自分の発言は拾わない」に使う。
# 毎回 /me を叩かないよう、確認できた時点で保存しておく。
$script:GraphSelfId = $null
function Get-GraphSelfId {
    if ($script:GraphSelfId) { return $script:GraphSelfId }
    $stored = Get-Secret -Name 'ms.selfUserId'
    if ($stored) { $script:GraphSelfId = $stored; return $stored }
    try {
        $me = Get-GraphMe
        if ($me.id) {
            Set-Secret -Name 'ms.selfUserId' -Value $me.id
            $script:GraphSelfId = $me.id
        }
    } catch { }
    return $script:GraphSelfId
}

# Graph の $filter に入れる日時。UTC の ISO8601 で、引用符は付けない。
#
# 書式指定の ':' は「その文化圏の時刻区切り」に置き換わる。既定の文化圏に任せると、
# 区切りが ':' でない環境で $filter が壊れる (症状は「なぜか新着が 0 件」)。
# 通信に載せる文字列なので固定の文化圏で組む。
function ConvertTo-GraphTime {
    param([Parameter(Mandatory)] [DateTime] $Value)
    return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)
}

# ---------------------------------------------------------------- Outlook (メール)

function Get-GraphAddress {
    param($EmailAddress)
    if (-not $EmailAddress) { return '' }
    $name = [string] $EmailAddress.name
    $addr = [string] $EmailAddress.address
    if ($name -and $addr -and ($name -ne $addr)) { return ('{0} <{1}>' -f $name, $addr) }
    if ($addr) { return $addr }
    return $name
}

function Get-GraphAddressList {
    param($Recipients)
    $out = @()
    foreach ($r in @($Recipients)) {
        $v = Get-GraphAddress $r.emailAddress
        if ($v) { $out += $v }
    }
    return ($out -join ', ')
}

function ConvertFrom-GraphMessage {
    <#
      .SYNOPSIS
        Graph の message を、このアプリが扱う形にそろえる。
      .DESCRIPTION
        Gmail 側の Get-GmailMessage と同じ列にしてある。後段 (イベント化・カード・
        ワーカー) を経路ごとに分岐させないため。
    #>
    param([Parameter(Mandatory)] $M)

    $body = ''
    if ($M.body -and $M.body.content) {
        $body = [string] $M.body.content
        # Prefer で平文を頼んでも、送信元によっては HTML が返る。
        if (([string] $M.body.contentType) -ieq 'html') { $body = ConvertFrom-HtmlToText $body }
    }
    if (-not $body) { $body = [string] $M.bodyPreview }

    $received = $null
    if ($M.receivedDateTime) {
        try { $received = ([DateTimeOffset] $M.receivedDateTime).LocalDateTime } catch { }
    }

    return [pscustomobject]@{
        id             = [string] $M.id
        conversationId = [string] $M.conversationId
        receivedAt     = $received
        receivedRaw    = [string] $M.receivedDateTime
        subject        = [string] $M.subject
        from           = (Get-GraphAddress $M.from.emailAddress)
        to             = (Get-GraphAddressList $M.toRecipients)
        cc             = (Get-GraphAddressList $M.ccRecipients)
        messageId      = [string] $M.internetMessageId
        snippet        = [string] $M.bodyPreview
        body           = $body
        webLink        = [string] $M.webLink
        hasAttachments = [bool] $M.hasAttachments
    }
}

# 取得する列。全部取ると本文の HTML でページが膨らむ割に、使わない列が多い。
$script:GraphMailSelect = 'id,conversationId,subject,from,toRecipients,ccRecipients,receivedDateTime,bodyPreview,body,hasAttachments,internetMessageId,webLink'

function Get-OutlookRecent {
    <#
      .SYNOPSIS
        受信トレイの新着を、本文まで取って古い順に返す。
      .DESCRIPTION
        既読・未読で絞らない。スマホで先に読んだメールは既読になってしまい、
        それで絞ると二度と取り込まれない (Gmail 側と同じ判断)。
        @odata.nextLink を辿るので1ページを超えても取り切る。
      .PARAMETER Since
        この時刻より後に受信したものを見る。
    #>
    param(
        [Parameter(Mandatory)] [DateTime] $Since,
        [int] $Max = 100
    )
    $filter = "receivedDateTime gt {0}" -f (ConvertTo-GraphTime $Since)
    # $filter と $orderby は同じプロパティにそろえること。
    # 揃っていないと Graph は InefficientFilter で断る。
    $path = "/me/mailFolders/inbox/messages?`$filter={0}&`$orderby=receivedDateTime&`$top={1}&`$select={2}" -f `
                [Uri]::EscapeDataString($filter), [Math]::Min(50, $Max), $script:GraphMailSelect

    $out = @()
    while ($path -and $out.Count -lt $Max) {
        # 本文は平文で頼む。HTML から落とすより、送信元が用意した平文のほうが読みやすい。
        $page = Invoke-GraphApi -Path $path -Prefer 'outlook.body-content-type="text"'
        foreach ($m in @($page.value)) {
            if (-not $m) { continue }
            $out += ConvertFrom-GraphMessage $m
            if ($out.Count -ge $Max) { break }
        }
        $path = [string] $page.'@odata.nextLink'
    }
    return @($out | Sort-Object receivedRaw)
}

function Get-OutlookMessage {
    param([Parameter(Mandatory)] [string] $MessageId)
    $m = Invoke-GraphApi -Path ("/me/messages/{0}?`$select={1}" -f [Uri]::EscapeDataString($MessageId), $script:GraphMailSelect) `
            -Prefer 'outlook.body-content-type="text"'
    return ConvertFrom-GraphMessage $m
}

function Get-OutlookThread {
    <#
      .SYNOPSIS
        同じ会話 (conversationId) のメールをまとめて読める形にする。
      .DESCRIPTION
        カード化のときに取れているのは1通だけで、経緯は入っていない。
        「元を見ずに済ませる」には前後のやり取りまで要る。

        orderby は付けない。conversationId で絞ったうえで受信日時で並べ替えると
        Graph が InefficientFilter で断るため、並べ替えは手元で行う。
    #>
    param([Parameter(Mandatory)] [string] $ConversationId, [int] $Limit = 30)
    $filter = "conversationId eq '{0}'" -f ($ConversationId -replace "'", "''")
    $path = "/me/messages?`$filter={0}&`$top={1}&`$select={2}" -f `
                [Uri]::EscapeDataString($filter), [Math]::Min(50, $Limit), $script:GraphMailSelect
    $page = Invoke-GraphApi -Path $path -Prefer 'outlook.body-content-type="text"'

    $msgs = @()
    foreach ($m in @($page.value)) { if ($m) { $msgs += ConvertFrom-GraphMessage $m } }
    $msgs = @($msgs | Sort-Object receivedRaw)
    if ($msgs.Count -gt $Limit) { $msgs = $msgs[($msgs.Count - $Limit)..($msgs.Count - 1)] }

    $lines = @()
    $attachments = [System.Collections.ArrayList]::new()
    foreach ($m in $msgs) {
        $when = if ($m.receivedAt) { $m.receivedAt.ToString('MM/dd HH:mm') } else { $m.receivedRaw }
        $lines += ("--- {0} / {1}`n{2}" -f $m.from, $when, $m.body)
        if ($m.hasAttachments) {
            foreach ($a in @(Get-OutlookAttachmentList -MessageId $m.id)) {
                [void] $attachments.Add([pscustomobject]@{
                    messageId = $m.id; filename = $a.filename; mimeType = $a.mimeType
                    size = $a.size; attachmentId = $a.attachmentId
                })
            }
        }
    }

    $subject = ''
    $link = ''
    if ($msgs.Count -gt 0) { $subject = $msgs[0].subject; $link = $msgs[$msgs.Count - 1].webLink }
    return [pscustomobject]@{
        conversationId = $ConversationId
        subject      = $subject
        messageCount = $msgs.Count
        text         = ($lines -join "`n`n")
        attachments  = @($attachments)
        permalink    = $link
    }
}

function Get-OutlookAttachmentList {
    <#
      .SYNOPSIS
        添付の一覧。本文に出ない資料がここにしか無いことがある。
      .DESCRIPTION
        contentBytes は取らない。一覧で中身まで返させると、数 MB の添付が
        全件ぶん流れてくる。実際に要るものだけ Get-OutlookAttachmentBytes で取る。
    #>
    param([Parameter(Mandatory)] [string] $MessageId)
    $r = Invoke-GraphApi -Path ("/me/messages/{0}/attachments?`$select=id,name,contentType,size,isInline" -f [Uri]::EscapeDataString($MessageId))
    $out = @()
    foreach ($a in @($r.value)) {
        if (-not $a) { continue }
        # 本文に埋め込まれた画像は資料ではない。一覧に出すと添付だらけに見える。
        if ($a.isInline) { continue }
        $out += [pscustomobject]@{
            filename     = [string] $a.name
            mimeType     = [string] $a.contentType
            size         = [int] $a.size
            attachmentId = [string] $a.id
        }
    }
    return $out
}

function Get-OutlookAttachmentBytes {
    param(
        [Parameter(Mandatory)] [string] $MessageId,
        [Parameter(Mandatory)] [string] $AttachmentId
    )
    return Invoke-GraphApi -Raw -Path ("/me/messages/{0}/attachments/{1}/`$value" -f `
        [Uri]::EscapeDataString($MessageId), [Uri]::EscapeDataString($AttachmentId))
}

function New-GraphRecipientList {
    param([string] $Addresses)
    $out = @()
    foreach ($a in (($Addresses -split '[;,]') | ForEach-Object { $_.Trim() })) {
        if (-not $a) { continue }
        # "表示名 <アドレス>" で来ることがある。Graph が要るのはアドレスだけ。
        $addr = $a
        if ($a -match '<([^>]+)>') { $addr = $Matches[1].Trim() }
        $out += @{ emailAddress = @{ address = $addr } }
    }
    return $out
}

function New-OutlookDraft {
    <#
      .SYNOPSIS
        Outlook に本物の下書きを作る。送信は行わない。
      .PARAMETER ReplyToMessageId
        返信にする場合に指定する。createReply で作るので、元のスレッドにぶら下がる。
    #>
    param(
        [string] $To, [string] $Cc,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $Body,
        [string] $ReplyToMessageId
    )
    if ($ReplyToMessageId) {
        # createReply が作るのは「引用付きの空の下書き」。本文と宛先はそのあとで入れる。
        # 件名と conversationId は Graph が付けるので、こちらでは触らない
        # (触れないのが正しい ―― 手で組み立てるとスレッドから外れる)。
        $draft = Invoke-GraphApi -Method 'Post' -Path ("/me/messages/{0}/createReply" -f [Uri]::EscapeDataString($ReplyToMessageId))
        $patch = @{ body = @{ contentType = 'Text'; content = $Body } }
        if ($To) { $patch['toRecipients'] = @(New-GraphRecipientList $To) }
        if ($Cc) { $patch['ccRecipients'] = @(New-GraphRecipientList $Cc) }
        $d = Invoke-GraphApi -Method 'Patch' -Path ("/me/messages/{0}" -f [Uri]::EscapeDataString([string] $draft.id)) -Body $patch
        return [pscustomobject]@{ id = [string] $d.id; conversationId = [string] $d.conversationId; webLink = [string] $d.webLink }
    }

    $payload = @{
        subject = $Subject
        body = @{ contentType = 'Text'; content = $Body }
        toRecipients = @(New-GraphRecipientList $To)
    }
    if ($Cc) { $payload['ccRecipients'] = @(New-GraphRecipientList $Cc) }
    $d = Invoke-GraphApi -Method 'Post' -Path '/me/messages' -Body $payload
    return [pscustomobject]@{ id = [string] $d.id; conversationId = [string] $d.conversationId; webLink = [string] $d.webLink }
}

function Send-OutlookMail {
    <#
      .SYNOPSIS
        メールを送信する。取り消せないので、呼び出し側は必ず承認を取ってから呼ぶこと。
      .DESCRIPTION
        返信のときは「下書きを作って本文を入れて送る」の3手で出す。
        reply に本文を渡す1手の方法もあるが、それだと宛先を確認できないまま送ることになる。
    #>
    param(
        [Parameter(Mandatory)] [string] $To, [string] $Cc,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $Body,
        [string] $ReplyToMessageId
    )
    if (-not $To.Trim()) { throw '宛先が空です。' }

    if ($ReplyToMessageId) {
        $d = New-OutlookDraft -To $To -Cc $Cc -Subject $Subject -Body $Body -ReplyToMessageId $ReplyToMessageId
        [void] (Invoke-GraphApi -Method 'Post' -Path ("/me/messages/{0}/send" -f [Uri]::EscapeDataString($d.id)))
        return [pscustomobject]@{ id = $d.id; conversationId = $d.conversationId }
    }

    $message = @{
        subject = $Subject
        body = @{ contentType = 'Text'; content = $Body }
        toRecipients = @(New-GraphRecipientList $To)
    }
    if ($Cc) { $message['ccRecipients'] = @(New-GraphRecipientList $Cc) }
    [void] (Invoke-GraphApi -Method 'Post' -Path '/me/sendMail' -Body @{ message = $message; saveToSentItems = $true })
    return [pscustomobject]@{ id = ''; conversationId = '' }
}

# ---------------------------------------------------------------- Teams (チャット)

# 掃き寄せたメッセージにも、通知から来たものと同じ形のリンクを持たせる。
# Slack の slack:// と同じ役割 ―― これを分解して本文も投稿先も引く。
function New-TeamsLink {
    param([Parameter(Mandatory)] [string] $ChatId, [Parameter(Mandatory)] [string] $MessageId)
    return "msteams://chat?id={0}&message={1}" -f [Uri]::EscapeDataString($ChatId), [Uri]::EscapeDataString($MessageId)
}

function ConvertFrom-TeamsLink {
    param([string] $Link)
    if (-not $Link -or $Link -notlike 'msteams://*') { return $null }
    $i = $Link.IndexOf('?')
    if ($i -lt 0) { return $null }
    $h = @{}
    foreach ($pair in ($Link.Substring($i + 1) -split '&')) {
        $kv = $pair -split '=', 2
        if ($kv.Count -eq 2) { $h[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) }
    }
    if (-not $h['id']) { return $null }
    return [pscustomobject]@{ chatId = [string] $h['id']; messageId = [string] $h['message'] }
}

# チャットの表示名は毎回 API を叩かずに使い回す。
# カードを開くたびに問い合わせると、ドロワーの表示が API 待ちになる。
$script:TeamsChatCache = @{}

function Get-TeamsChatName {
    <#
      .SYNOPSIS
        チャットの表示名。1:1 は相手の名前、グループは topic か参加者の並び。
    #>
    param([Parameter(Mandatory)] $Chat)
    if ($Chat.topic) { return [string] $Chat.topic }
    $self = Get-GraphSelfId
    $names = @()
    foreach ($m in @($Chat.members)) {
        if (-not $m) { continue }
        if ($self -and ([string] $m.userId) -eq $self) { continue }
        $n = [string] $m.displayName
        if ($n) { $names += $n }
    }
    if ($names.Count -eq 0) { return 'チャット' }
    if ($names.Count -le 3) { return ($names -join ', ') }
    return ("{0} ほか {1} 名" -f ($names[0..2] -join ', '), ($names.Count - 3))
}

function Resolve-TeamsChat {
    param([Parameter(Mandatory)] [string] $ChatId)
    if ($script:TeamsChatCache.ContainsKey($ChatId)) { return $script:TeamsChatCache[$ChatId] }
    try {
        $c = Invoke-GraphApi -Path ("/me/chats/{0}?`$expand=members" -f [Uri]::EscapeDataString($ChatId))
        $name = Get-TeamsChatName -Chat $c
    }
    catch { return $ChatId }   # 失敗は覚えない。権限が付けば次は引ける
    $script:TeamsChatCache[$ChatId] = $name
    return $name
}

function Get-TeamsMessageText {
    <#
      .SYNOPSIS
        チャットメッセージの本文を平文にする。
      .DESCRIPTION
        Teams の本文は既定で HTML。添付やカードだけの投稿は本文が空になるので、
        そのときは何が付いていたかを一行で残す (空のカードが立つのを防ぐ)。
    #>
    param([Parameter(Mandatory)] $Message)
    $text = ''
    if ($Message.body -and $Message.body.content) {
        $text = [string] $Message.body.content
        if (([string] $Message.body.contentType) -ieq 'html') { $text = ConvertFrom-HtmlToText $text }
    }
    $extras = @()
    foreach ($a in @($Message.attachments)) {
        if (-not $a) { continue }
        $n = [string] $a.name
        if (-not $n) { $n = [string] $a.contentType }
        if ($n) { $extras += ("(添付: {0})" -f $n) }
    }
    if ($extras.Count -gt 0) {
        if ($text) { $text += "`n" }
        $text += ($extras -join "`n")
    }
    return $text.Trim()
}

function Get-TeamsMessageSender {
    param([Parameter(Mandatory)] $Message)
    if ($Message.from -and $Message.from.user -and $Message.from.user.displayName) {
        return [string] $Message.from.user.displayName
    }
    if ($Message.from -and $Message.from.application -and $Message.from.application.displayName) {
        return [string] $Message.from.application.displayName
    }
    return '(不明)'
}

function Get-TeamsChats {
    <#
      .SYNOPSIS
        自分が参加しているチャットの一覧 (新しい順)。
    #>
    param([int] $Max = 50)
    $out = @()
    $path = "/me/chats?`$expand=members&`$top={0}" -f [Math]::Min(50, $Max)
    while ($path -and $out.Count -lt $Max) {
        $page = Invoke-GraphApi -Path $path
        foreach ($c in @($page.value)) {
            if (-not $c) { continue }
            $out += $c
            if ($out.Count -ge $Max) { break }
        }
        $path = [string] $page.'@odata.nextLink'
    }
    return $out
}

function Get-TeamsUpdates {
    <#
      .SYNOPSIS
        前回の続きから、自分に関係のある新着チャットだけを拾う。
      .DESCRIPTION
        Slack と違って絞り込みはほとんど要らない ―― /me/chats に出てくるのは
        1:1・グループ・会議チャットだけで、チャネル (公開の投稿) は含まれない。
        つまり出てくる時点で「自分が参加している会話」であり、Slack の DM に近い。
        自分の発言と、参加・退出などのシステムメッセージだけを落とす。
      .OUTPUTS
        [pscustomobject] messages / errors
    #>
    param(
        [Parameter(Mandatory)] [DateTime] $Since,
        [int] $MaxChats = 30,
        [int] $MaxPerChat = 50
    )
    $self = Get-GraphSelfId
    $sinceText = ConvertTo-GraphTime $Since

    $hits = @()
    $errors = @()
    $chats = @()
    try { $chats = @(Get-TeamsChats -Max $MaxChats) }
    catch {
        $errors += [pscustomobject]@{
            chat = '(一覧)'; message = $_.Exception.Message
            permanent = (Test-GraphPermanentError $_.Exception.Message)
        }
        return [pscustomobject]@{ messages = @(); errors = @($errors) }
    }

    foreach ($c in $chats) {
        $chatId = [string] $c.id
        if (-not $chatId) { continue }
        # 最終更新が watermark より古いチャットは開かない。
        # 会話の数だけリクエストが増えるので、ここで落とせる分は落とす。
        if ($c.lastUpdatedDateTime) {
            try {
                if (([DateTimeOffset] $c.lastUpdatedDateTime).UtcDateTime -le $Since.ToUniversalTime()) { continue }
            } catch { }
        }
        $name = Get-TeamsChatName -Chat $c
        $script:TeamsChatCache[$chatId] = $name

        # $filter と $orderby は同じプロパティにそろえる (そろっていないと $filter が無視される)。
        $filter = "lastModifiedDateTime gt $sinceText"
        $path = "/chats/{0}/messages?`$orderby=lastModifiedDateTime desc&`$filter={1}&`$top={2}" -f `
                    [Uri]::EscapeDataString($chatId), [Uri]::EscapeDataString($filter), [Math]::Min(50, $MaxPerChat)
        try { $page = Invoke-GraphApi -Path $path }
        catch {
            # チャット単位の失敗で全体を止めない。呼び出し側が
            # 「次回もう一度読むべきか」を判断できるよう、恒久かどうかを添える。
            $msg = $_.Exception.Message
            $errors += [pscustomobject]@{
                chat = $name; message = $msg; permanent = (Test-GraphPermanentError $msg)
            }
            continue
        }

        foreach ($m in @($page.value)) {
            if (-not $m) { continue }
            # 参加・退出などのイベントは会話ではない
            if (([string] $m.messageType) -ne 'message') { continue }
            # 削除済みは本文が空で返る
            if ($m.deletedDateTime) { continue }
            if ($self -and $m.from -and $m.from.user -and ([string] $m.from.user.id) -eq $self) { continue }

            $text = Get-TeamsMessageText -Message $m
            if (-not $text) { continue }

            $mentioned = $false
            foreach ($mn in @($m.mentions)) {
                if ($mn -and $mn.mentioned -and $mn.mentioned.user -and ([string] $mn.mentioned.user.id) -eq $self) {
                    $mentioned = $true
                }
            }

            $when = $null
            try { $when = ([DateTimeOffset] $m.createdDateTime).LocalDateTime } catch { $when = Get-Date }

            $hits += [pscustomobject]@{
                chatId    = $chatId
                chatName  = $name
                messageId = [string] $m.id
                createdAt = $when
                createdRaw = [string] $m.createdDateTime
                sender    = (Get-TeamsMessageSender -Message $m)
                text      = $text
                webUrl    = [string] $m.webUrl
                reason    = $(if ($mentioned) { 'mention' } else { 'chat' })
            }
        }
    }

    return [pscustomobject]@{
        messages = @($hits | Sort-Object createdRaw)
        errors   = @($errors)
    }
}

function Get-TeamsThread {
    <#
      .SYNOPSIS
        リンクからチャットの直近のやり取りを取得し、読める形にして返す。
      .OUTPUTS
        [pscustomobject] text / chat / messageCount / permalink (解釈できなければ $null)
    #>
    param([Parameter(Mandatory)] [string] $Link, [int] $Limit = 30)
    $ref = ConvertFrom-TeamsLink $Link
    if (-not $ref) { return $null }

    $chatName = Resolve-TeamsChat $ref.chatId
    $page = Invoke-GraphApi -Path ("/chats/{0}/messages?`$top={1}" -f `
                [Uri]::EscapeDataString($ref.chatId), [Math]::Min(50, $Limit))

    $msgs = @()
    foreach ($m in @($page.value)) {
        if (-not $m) { continue }
        if (([string] $m.messageType) -ne 'message') { continue }
        if ($m.deletedDateTime) { continue }
        $msgs += $m
    }
    # 既定は新しい順で返る。読むのは古い順のほうが自然。
    $msgs = @($msgs | Sort-Object { [string] $_.createdDateTime })

    $lines = @()
    $permalink = ''
    foreach ($m in $msgs) {
        $when = ''
        try { $when = ([DateTimeOffset] $m.createdDateTime).LocalDateTime.ToString('MM/dd HH:mm') } catch { }
        $mark = if (([string] $m.id) -eq $ref.messageId) { ' ← この通知の対象' } else { '' }
        $lines += ("[{0}] {1}{2}`n{3}" -f $when, (Get-TeamsMessageSender -Message $m), $mark, (Get-TeamsMessageText -Message $m))
        if (([string] $m.id) -eq $ref.messageId -and $m.webUrl) { $permalink = [string] $m.webUrl }
    }
    if (-not $permalink -and $msgs.Count -gt 0) { $permalink = [string] $msgs[$msgs.Count - 1].webUrl }

    return [pscustomobject]@{
        text         = ("チャット: $chatName`n`n" + ($lines -join "`n`n"))
        chat         = $chatName
        messageCount = $msgs.Count
        permalink    = $permalink
    }
}

function Get-TeamsTarget {
    <#
      .SYNOPSIS
        通知のリンクから「どこに返すか」を決める。表示用の名前も一緒に返す。
    #>
    param([Parameter(Mandatory)] [string] $Link)
    $ref = ConvertFrom-TeamsLink $Link
    if (-not $ref) { return $null }
    return [pscustomobject]@{ chatId = $ref.chatId; chatName = (Resolve-TeamsChat $ref.chatId) }
}

function Send-TeamsMessage {
    <#
      .SYNOPSIS
        Teams のチャットに投稿する。取り消せないので、呼び出し側は必ず承認を取ってから呼ぶこと。
      .DESCRIPTION
        投稿先はカードの元通知から束縛して渡す。モデルは指定できない。
        チャットにはスレッドが無い (スレッドはチャネルの機能) ので、
        会話への投稿はそのまま相手に届く。
      .OUTPUTS
        [pscustomobject] id / permalink
    #>
    param(
        [Parameter(Mandatory)] [string] $ChatId,
        [Parameter(Mandatory)] [string] $Text
    )
    if (-not $Text.Trim()) { throw '本文が空です。' }
    $r = Invoke-GraphApi -Method 'Post' -Path ("/chats/{0}/messages" -f [Uri]::EscapeDataString($ChatId)) `
            -Body @{ body = @{ contentType = 'text'; content = $Text } }
    return [pscustomobject]@{ id = [string] $r.id; permalink = [string] $r.webUrl }
}


# ---------------------------------------------------------------- アカウントの切り替え
#
# チャット名の控えはテナントごとに別物で、持ち越すと別テナントの名前が出る。
# 発行途中のデバイスコードも捨てる ―― あれは「いま繋ごうとしている1人」のもので、
# 相手が変わったら無効である。
function Reset-GraphCache {
    Clear-GraphAccessToken
    $script:GraphGrantedScopes = @()
    $script:GraphSelfId        = $null
    $script:TeamsChatCache     = @{}
    $script:PendingGraphDevice = $null
}
Register-AccountReset -Service 'microsoft' -Handler { Reset-GraphCache }
