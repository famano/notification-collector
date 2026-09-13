# ServiceSetup.ps1
# 外部サービスの資格情報を「カンバンから」設定するための層。
#
# なぜ要るか:
#   完了カードを洗うと、29枚中8枚が「権限が無くて進めない」で止まっていた。
#   それに対する答えが設定カードで、1枚直せば同種がまとめて通るところまでは
#   できている。ところがその設定カードに書いてあるのは
#   「.\phase5\Connect-Service.ps1 -Service github を実行してください」――
#   **カンバンの外に出ろ、という指示**である。
#
#   このアプリは「カードはカンバンの上で閉じられる」を原則にしている。
#   送信も、実施も、人間の1手も、画面の上で終わる。設定だけが端末に戻される。
#   しかも戻された先で待っているのは対話プロンプトで、常駐しているワーカーとは
#   別のシェルを開く必要がある。止まっているカードが8枚あるときに、
#   一番やりたくない形をしている。
#
#   そこで、対話プロンプトに依存しない形で「入力 → 保存 → 疎通確認」を関数にする。
#   Connect-Service.ps1 (端末から) とカンバン (画面から) の両方がここを呼ぶ。
#
# 扱わないもの:
#   値を読み出す口はここに作らない。保存と確認だけを提供する。
#   画面に返すのは「設定済みか」と「どのアカウントとして繋がったか」だけで、
#   トークンそのものは決して返さない。

. "$PSScriptRoot\SecretStore.ps1"
# API キーの取得元 (環境変数 / 保管庫 / 配布設定) の判定はここに集約してある。
. "$PSScriptRoot\..\..\lib\ApiKey.ps1"

# サービスの定義。画面はこれを読んで入力欄を組み立てる。
#
#   key      … Get-ServiceKey (ホストから決まる正規名) と揃えること。
#              設定カードの subject_key が 'setup:<key>' になる。
#   fields   … 画面に出す入力欄。secret=$true は伏せ字で受け取り、値は返さない。
#   flow     … 'token' は貼るだけ。'oauth' はブラウザの同意画面を通る。
$script:SetupServices = @(
    @{
        key   = 'anthropic'
        label = 'Claude'
        flow  = 'token'
        # これだけは「あると便利」ではない。無ければカードが1枚も作られない。
        # 以前は起動時に環境変数が無いと起動そのものを拒んでいたが、それだと
        # 配った先では画面すら出ず、直し方を出す場所が無かった。ここに入口を作る。
        required = $true
        why   = '通知の判定とワーカーの作業に使います。これが無いとカードは作られません。'
        docUrl = 'https://console.anthropic.com/settings/keys'
        help  = @'
console.anthropic.com にサインインし、Settings → API keys で
「Create Key」を押すと sk-ant- で始まる文字列が出ます。これを貼ってください。
キーは一度しか表示されません。控えを無くしたら作り直せます。

このアプリは支払いの設定された組織のキーを使います。
会社で配られている場合は、配った人に聞いてください
(配る人が config\app-config.json に入れておけば、この欄は空のままで繋がります)。
'@
        secrets = @('anthropic.apiKey')
        fields  = @(
            @{ name = 'apiKey'; label = 'API キー'; secret = $true; required = $true
               placeholder = 'sk-ant-...' }
        )
    },
    @{
        key   = 'github'
        label = 'GitHub'
        flow  = 'token'
        why   = '非公開リポジトリの調査、CI の失敗内容の取得、招待の承諾。'
        docUrl = 'https://github.com/settings/tokens'
        help  = @'
Fine-grained token を作り、対象リポジトリに対して
  Actions: Read-only / Contents: Read-only / Metadata: Read-only
招待の承諾も任せるなら、アカウント権限の
  Repository invitations: Read and write
classic token なら repo スコープでまとめて足ります。
'@
        secrets = @('github.token')
        fields  = @(
            @{ name = 'token'; label = 'トークン'; secret = $true; required = $true
               placeholder = 'github_pat_... / ghp_...' }
        )
    },
    @{
        key   = 'slack'
        label = 'Slack'
        flow  = 'token'
        why   = 'メンションと DM の取得、元スレッドへの投稿。'
        docUrl = 'https://api.slack.com/apps'
        help  = @'
アプリを作り、OAuth & Permissions で以下を足してインストールします。
  Bot Token Scopes : channels:history groups:history im:history mpim:history
                     channels:read groups:read im:read mpim:read users:read
                     chat:write (投稿する場合)
Bot は招待されたチャンネルしか読めません。夜のあいだの DM まで拾いたい場合は、
同じ範囲を User Token Scopes にも足して xoxp- のトークンを入れてください
(読み取りにだけ使います。投稿は Bot 名義のままです)。
'@
        secrets = @('slack.botToken', 'slack.userToken', 'slack.selfUserId')
        fields  = @(
            @{ name = 'botToken';  label = 'Bot User OAuth Token'; secret = $true; required = $false
               placeholder = 'xoxb-...' },
            @{ name = 'userToken'; label = 'User OAuth Token'; secret = $true; required = $false
               placeholder = 'xoxp-...'; hint = '入れると、Bot が居ないチャンネルや DM も読めます' }
        )
    },
    @{
        key   = 'google'
        label = 'Gmail / カレンダー'
        flow  = 'oauth'
        why   = 'メール本文の取得、下書きの作成と送信、カレンダーの出欠。'
        docUrl = 'https://console.cloud.google.com/'
        help  = @'
Google Cloud で Gmail API と Calendar API を有効にし、
OAuth クライアント (種類: デスクトップ アプリ) を作って ID とシークレットを控えます。
「保存して Google の同意画面へ」を押すとブラウザが開き、同意すると戻ってきます。

注意: Google には「下書きだけ」のスコープがありません。gmail.compose は送信も許します。
送信はワーカーの送信ツールからのみ行い、実行前にカンバンで承認を求めます。
'@
        secrets = @('gmail.clientId', 'gmail.clientSecret', 'gmail.refreshToken')
        fields  = @(
            @{ name = 'clientId';     label = 'クライアント ID'; secret = $false; required = $true
               placeholder = '...apps.googleusercontent.com' },
            @{ name = 'clientSecret'; label = 'クライアント シークレット'; secret = $true; required = $true }
        )
    }
)

# 'gmail' と書かれても google に寄せる。設定カードの key は Get-ServiceKey が
# 決める (= google) が、人間が書く名前は gmail のことが多い。
$script:SetupAliases = @{ gmail = 'google'; googleapis = 'google'; 'github.com' = 'github' }

function Get-SetupService {
    param([string] $Key)
    if (-not $Key) { return $null }
    $k = $Key.ToLowerInvariant()
    if ($k.StartsWith('setup:')) { $k = $k.Substring(6) }
    if ($script:SetupAliases.ContainsKey($k)) { $k = $script:SetupAliases[$k] }
    foreach ($s in $script:SetupServices) { if ($s.key -eq $k) { return $s } }
    return $null
}

function Test-SetupConfigured {
    param([Parameter(Mandatory)] [string] $Key)
    switch ((Get-SetupService $Key).key) {
        # キーは保管庫以外 (環境変数・配布設定) にも居られるので、置き場所ごと判定する。
        'anthropic' { return [bool] (Test-AnthropicConfigured) }
        'github' { return [bool] (Get-Secret -Name 'github.token') }
        'slack'  { return [bool] ((Get-Secret -Name 'slack.botToken') -or (Get-Secret -Name 'slack.userToken')) }
        'google' { return [bool] ((Get-Secret -Name 'gmail.refreshToken') -and (Get-Secret -Name 'gmail.clientId')) }
    }
    return $false
}

# 画面に渡す一覧。**トークンは含めない。**
function Get-SetupStatusList {
    $out = @()
    foreach ($s in $script:SetupServices) {
        $out += [pscustomobject]@{
            key        = $s.key
            label      = $s.label
            flow       = $s.flow
            why        = $s.why
            help       = $s.help
            docUrl     = $s.docUrl
            configured = (Test-SetupConfigured -Key $s.key)
            account    = (Get-SetupAccount -Key $s.key)
            # これが無いとアプリが成立しないもの。画面はこれを先頭に出す。
            required   = [bool] $s.required
            # 配る人が用意済みで、利用者は押すだけでよいもの。
            # 入力欄を出すと「自分で取ってこい」に見えるので、画面から隠す判断に使う。
            preset     = (Test-SetupPreset -Key $s.key)
            managed    = (Get-SetupManagedNote -Key $s.key)
            fields     = @($s.fields | ForEach-Object {
                [pscustomobject]@{
                    name = $_.name; label = $_.label; secret = [bool] $_.secret
                    required = [bool] $_.required
                    placeholder = [string] $_.placeholder; hint = [string] $_.hint
                }
            })
        }
    }
    return $out
}

# 配る人が用意した値が既にあるか。
#
# Google の OAuth クライアントも Slack のアプリも、**利用者の権限では作れない**ことが多い。
# それを空欄として画面に出すと、そこは永久に埋まらないまま「未接続」が残る。
# 用意済みなら入力欄を出さず、押すだけの形にする。
function Test-SetupPreset {
    param([Parameter(Mandatory)] [string] $Key)
    $svc = Get-SetupService $Key
    if (-not $svc) { return $false }
    switch ($svc.key) {
        'anthropic' {
            # 環境変数と配布設定は利用者が触れない場所。そこに既にあるなら入力は要らない。
            if ($env:ANTHROPIC_API_KEY) { return $true }
            return [bool] (Get-AppConfigValue -Path 'anthropic.apiKey')
        }
        'google' {
            # 同意そのものは本人が押す。ここで言う「用意済み」はクライアントの ID と秘密。
            if ((Get-Secret -Name 'gmail.clientId') -and (Get-Secret -Name 'gmail.clientSecret')) { return $true }
            return [bool] ((Get-AppConfigValue -Path 'google.clientId') -and (Get-AppConfigValue -Path 'google.clientSecret'))
        }
    }
    return $false
}

# 用意済みのときに画面へ出す一言。「入力欄が無い」理由が分からないと不安になる。
function Get-SetupManagedNote {
    param([Parameter(Mandatory)] [string] $Key)
    if (-not (Test-SetupPreset -Key $Key)) { return '' }
    $svc = Get-SetupService $Key
    switch ($svc.key) {
        'anthropic' {
            if ($env:ANTHROPIC_API_KEY) { return 'この PC の環境変数に設定されています。' }
            return '配布時に設定されています。入力は要りません。'
        }
        'google' { return '接続に使う情報は配布時に設定されています。ボタンを押して Google の画面で許可してください。' }
    }
    return ''
}

# 「どのアカウントとして繋がっているか」。ネットワークには出ない
# (画面を開くたびに外を叩かない)。確認できた時点の表示名を保存しておき、それを返す。
function Get-SetupAccount {
    param([string] $Key)
    return [string] (Get-Secret -Name ("account.$Key"))
}

function Set-SetupAccount {
    param([Parameter(Mandatory)] [string] $Key, [string] $Account)
    if ($Account) { Set-Secret -Name ("account.$Key") -Value $Account }
}

# ---------------------------------------------------------------- 保存

# 貼るだけのサービス (GitHub / Slack) の保存と疎通確認。
#
# 確認に失敗したら**元の値に戻す**。貼り間違えたトークンをそのまま残すと、
# 「設定済みなのに全部 401」という一番分かりにくい状態になる。
function Save-SetupCredential {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [hashtable] $Values
    )
    $svc = Get-SetupService $Key
    if (-not $svc) { return [pscustomobject]@{ ok = $false; error = ("知らないサービスです: {0}" -f $Key) } }
    if ($svc.flow -ne 'token') {
        return [pscustomobject]@{ ok = $false; error = ("{0} はブラウザでの同意が要ります。" -f $svc.label) }
    }

    # 入力が全部空なら何もしない (押し間違いで設定を消さない)
    $given = @($svc.fields | Where-Object { [string] $Values[$_.name] })
    if ($given.Count -eq 0) {
        return [pscustomobject]@{ ok = $false; error = '入力が空です。' }
    }
    foreach ($f in $svc.fields) {
        if ($f.required -and -not [string] $Values[$f.name]) {
            return [pscustomobject]@{ ok = $false; error = ("{0} を入力してください。" -f $f.label) }
        }
    }

    $backup = @{}
    foreach ($n in $svc.secrets) { $backup[$n] = Get-Secret -Name $n }

    try {
        switch ($svc.key) {
            'anthropic' { Set-Secret -Name 'anthropic.apiKey' -Value ([string] $Values['apiKey']).Trim() }
            'github' { Set-Secret -Name 'github.token' -Value ([string] $Values['token']).Trim() }
            'slack'  {
                foreach ($pair in @(@('botToken', 'slack.botToken'), @('userToken', 'slack.userToken'))) {
                    $v = ([string] $Values[$pair[0]]).Trim()
                    if ($v) { Set-Secret -Name $pair[1] -Value $v }
                }
            }
        }
        $check = Test-SetupConnection -Key $svc.key
        if (-not $check.ok) { throw $check.error }
        Set-SetupAccount -Key $svc.key -Account $check.account
        return [pscustomobject]@{ ok = $true; account = $check.account; note = $check.note }
    }
    catch {
        # 元に戻す。$null は「元から無かった」なので消す。
        foreach ($n in $svc.secrets) {
            if ($backup[$n]) { Set-Secret -Name $n -Value $backup[$n] }
            else { [void] (Remove-Secret -Name $n) }
        }
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
}

# 実際に1回叩いて確かめる。貼り間違いを後のカードで気づくのは高くつく。
function Test-SetupConnection {
    param([Parameter(Mandatory)] [string] $Key)
    $svc = Get-SetupService $Key
    if (-not $svc) { return [pscustomobject]@{ ok = $false; error = '知らないサービスです。' } }

    try {
        switch ($svc.key) {
            'anthropic' {
                # 一番安いエンドポイントで1回だけ叩く。貼り間違いをここで捕まえないと、
                # 次に気付くのは「取り込みは動いているのにカードが増えない」という形になる。
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $key = Get-AnthropicApiKey
                if (-not $key) { return [pscustomobject]@{ ok = $false; error = '未設定です。' } }
                try {
                    [void] (Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/models?limit=1' -TimeoutSec 20 `
                        -Headers @{ 'x-api-key' = $key; 'anthropic-version' = '2023-06-01' })
                }
                catch {
                    return [pscustomobject]@{ ok = $false; error = (Get-AnthropicErrorMessage $_) }
                }
                # アカウント名は API から取れない。キーそのものは決して画面に返さない。
                return [pscustomobject]@{ ok = $true; account = ''; note = '' }
            }
            'github' {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $tok = Get-Secret -Name 'github.token'
                if (-not $tok) { return [pscustomobject]@{ ok = $false; error = '未設定です。' } }
                $r = Invoke-RestMethod -Uri 'https://api.github.com/user' -TimeoutSec 20 `
                        -Headers @{ Authorization = "Bearer $tok"; 'User-Agent' = 'notification-collector' }
                return [pscustomobject]@{ ok = $true; account = [string] $r.login; note = '' }
            }
            'slack' {
                if (-not (Get-Command Invoke-SlackApi -ErrorAction SilentlyContinue)) {
                    return [pscustomobject]@{ ok = $false; error = 'Slack 連携が読み込まれていません。' }
                }
                $r = Invoke-SlackApi -Method 'auth.test'
                $note = ''
                # 掃き寄せのメンション判定に使う「自分」。User Token があれば本人が確定する。
                if ((Get-Secret -Name 'slack.userToken') -and $r.user_id) {
                    Set-Secret -Name 'slack.selfUserId' -Value ([string] $r.user_id)
                }
                elseif (-not (Get-Secret -Name 'slack.selfUserId')) {
                    $note = 'メンションを拾うには自分のユーザーIDが要ります。User Token を入れるか、' +
                            '.\phase5\Connect-Service.ps1 -Service slack で設定してください。'
                }
                return [pscustomobject]@{ ok = $true; account = ("{0} / {1}" -f $r.team, $r.user); note = $note }
            }
            'google' {
                if (-not (Get-Command Invoke-GmailApi -ErrorAction SilentlyContinue)) {
                    return [pscustomobject]@{ ok = $false; error = 'Gmail 連携が読み込まれていません。' }
                }
                $m = Invoke-GmailApi -Path '/users/me/profile'
                return [pscustomobject]@{ ok = $true; account = [string] $m.emailAddress; note = '' }
            }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
    return [pscustomobject]@{ ok = $false; error = '確認できませんでした。' }
}

# キーの確認に失敗したときの文言。
#
# 例外の文言は「(401) 権限がありません」だけで、理由は応答の本文にしかない。
# 配った先で一番多いのは「貼り損ね」と「残高切れ」で、どちらも直し方が違う。
# 「失敗しました」だけ出しても、受け取った人には次の一手が無い。
function Get-AnthropicErrorMessage {
    param($ErrorRecord)
    $status = $null
    if ($ErrorRecord.Exception.Response) {
        try { $status = [int] $ErrorRecord.Exception.Response.StatusCode } catch { }
    }
    $detail = ''
    $raw = ''
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $raw = [string] $ErrorRecord.ErrorDetails.Message }
    if (-not $raw -and $ErrorRecord.Exception.Response) {
        try {
            $sr = New-Object IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream(), [Text.Encoding]::UTF8)
            try { $raw = $sr.ReadToEnd() } finally { $sr.Dispose() }
        } catch { }
    }
    if ($raw) {
        try { $detail = [string] ($raw | ConvertFrom-Json).error.message } catch { $detail = '' }
    }

    switch ($status) {
        401 { return ('キーが受け付けられませんでした。貼り間違いか、無効にされたキーです。' + $(if ($detail) { " ($detail)" } else { '' })) }
        403 { return ('このキーでは使えませんでした。' + $(if ($detail) { " ($detail)" } else { '' })) }
        429 { return '短時間に送りすぎています。少し待ってからもう一度試してください。' }
    }
    if ($detail -match 'credit|balance') { return ('残高が足りないようです。' + $detail) }
    if ($detail) { return $detail }
    return $ErrorRecord.Exception.Message
}

# ---------------------------------------------------------------- OAuth (Google)
#
# 同意画面からの戻り先は**カンバン自身**にする。
# Connect-Service.ps1 は専用の HttpListener を立てて GetContext() で待つが、
# カンバンは1本のループで要求を捌いているので、そこで待つと画面ごと固まる。
# 戻り先をカンバンのパスにすれば、ただの1リクエストとして流れる。
#
# Google の「デスクトップ アプリ」クライアントはループバックへのリダイレクトを
# 任意のポートで許すので、カンバンのポートがそのまま使える。

$script:PendingGoogleAuth = $null

function Get-GoogleClientCredential {
    <#
      .SYNOPSIS
        同意画面に使うクライアントを決める。画面の入力 → 保管庫 → 配布設定 の順。
      .DESCRIPTION
        Google Cloud でプロジェクトを作れる人は限られている。配る人が用意してあるなら、
        利用者に ID と秘密を貼らせる理由は無い ―― 押すだけで同意画面まで行けるようにする。
    #>
    param([string] $ClientId, [string] $ClientSecret)
    $cid = ([string] $ClientId).Trim()
    $sec = ([string] $ClientSecret).Trim()
    if (-not $cid) { $cid = [string] (Get-Secret -Name 'gmail.clientId') }
    if (-not $sec) { $sec = [string] (Get-Secret -Name 'gmail.clientSecret') }
    if (-not $cid) { $cid = [string] (Get-AppConfigValue -Path 'google.clientId') }
    if (-not $sec) { $sec = [string] (Get-AppConfigValue -Path 'google.clientSecret') }
    return [pscustomobject]@{ clientId = $cid; clientSecret = $sec }
}

function Get-GoogleAuthRequest {
    <#
      .SYNOPSIS
        同意画面の URL を組み立て、戻ってきたときに照合する state を控える。
    #>
    param(
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $ClientSecret,
        [Parameter(Mandatory)] [string] $RedirectUri
    )
    $scopes = if ($script:GmailScopes) { $script:GmailScopes } else {
        'https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.compose https://www.googleapis.com/auth/calendar.events'
    }
    $authUrl = if ($script:GoogleAuth) { $script:GoogleAuth } else { 'https://accounts.google.com/o/oauth2/v2/auth' }

    $state = [guid]::NewGuid().ToString('N')
    # シークレットはここでは保存しない。同意が返ってくるまでメモリに置く。
    $script:PendingGoogleAuth = @{
        state = $state; clientId = $ClientId.Trim(); clientSecret = $ClientSecret.Trim()
        redirectUri = $RedirectUri; createdAt = (Get-Date)
    }
    $url = "$authUrl" +
        "?client_id=$([Uri]::EscapeDataString($ClientId.Trim()))" +
        "&redirect_uri=$([Uri]::EscapeDataString($RedirectUri))" +
        "&response_type=code" +
        "&scope=$([Uri]::EscapeDataString($scopes))" +
        "&access_type=offline&prompt=consent&state=$state"
    return [pscustomobject]@{ url = $url; state = $state }
}

function Complete-GoogleAuth {
    <#
      .SYNOPSIS
        同意画面から戻ってきた認可コードを引き換えて保存する。
      .OUTPUTS
        [pscustomobject] ok / account / error
    #>
    param([string] $Code, [string] $State)

    $p = $script:PendingGoogleAuth
    if (-not $p) { return [pscustomobject]@{ ok = $false; error = '設定の途中経過が見つかりません。もう一度やり直してください。' } }
    if (((Get-Date) - $p.createdAt).TotalMinutes -gt 10) {
        $script:PendingGoogleAuth = $null
        return [pscustomobject]@{ ok = $false; error = '時間切れです。もう一度やり直してください。' }
    }
    if (-not $State -or $State -ne $p.state) {
        return [pscustomobject]@{ ok = $false; error = 'state が一致しません。中断しました。' }
    }
    if (-not $Code) { return [pscustomobject]@{ ok = $false; error = '認可コードを受け取れませんでした。' } }

    $tokenUrl = if ($script:GoogleToken) { $script:GoogleToken } else { 'https://oauth2.googleapis.com/token' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-RestMethod -Uri $tokenUrl -Method Post -TimeoutSec 30 -Body @{
            code = $Code; client_id = $p.clientId; client_secret = $p.clientSecret
            redirect_uri = $p.redirectUri; grant_type = 'authorization_code'
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; error = ("トークンの取得に失敗しました: {0}" -f $_.Exception.Message) }
    }
    if (-not $resp.refresh_token) {
        return [pscustomobject]@{
            ok = $false
            error = 'リフレッシュトークンが返りませんでした。Google 側でこのアプリの許可を一度取り消してから、もう一度実行してください。'
        }
    }

    Set-Secret -Name 'gmail.clientId'     -Value $p.clientId
    Set-Secret -Name 'gmail.clientSecret' -Value $p.clientSecret
    Set-Secret -Name 'gmail.refreshToken' -Value ([string] $resp.refresh_token)
    $script:PendingGoogleAuth = $null

    # 取り直したので、前のアクセストークンの残りは捨てる。
    # これが効くのはこのプロセス (カンバン) だけ。ワーカーや収集は別プロセスなので、
    # Get-GmailAccessToken が保存済みのリフレッシュトークンの変化を見て取り直す。
    $script:GmailToken = $null
    $script:GmailTokenExpiry = [DateTime]::MinValue
    if ($resp.scope) { $script:GoogleGrantedScopes = @(([string] $resp.scope) -split '\s+') }

    $check = Test-SetupConnection -Key 'google'
    if (-not $check.ok) { return [pscustomobject]@{ ok = $false; error = $check.error } }
    Set-SetupAccount -Key 'google' -Account $check.account

    $note = ''
    if ($script:GoogleGrantedScopes -and
        ($script:GoogleGrantedScopes -notcontains 'https://www.googleapis.com/auth/calendar.events')) {
        $note = 'カレンダーの出欠は返せません (同意画面でカレンダーの権限が付きませんでした)。'
    }
    return [pscustomobject]@{ ok = $true; account = $check.account; note = $note }
}
