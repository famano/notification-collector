# Setup.Tests.ps1
# 資格情報をカンバンから設定する経路。
#
# 見たいのは2つ。
#   1. 値が漏れないこと (画面に返るのは「設定済みか」と「誰として繋がったか」だけ)
#   2. 設定が入ったら、待っていたカードが自動で動き出すこと
#
# 2 が無いと設定カードは半分しか機能しない。止まっている8枚を1枚ずつ手で
# 要対応に戻すのでは、結局8枚ぶんの手数が残る。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase2\lib\Dossier.ps1"
. "$RepoRoot\phase5\lib\ServiceSetup.ps1"
. "$RepoRoot\phase3\lib\SetupFlow.ps1"

# --- 資格情報ストアを一時ファイルに差し替える ---
# 実データの secrets.dat は絶対に触らない。DPAPI も使わない
# (テストの目的は保存経路の筋であって、暗号化そのものではない)。
$script:TestSecretPath = Join-Path (New-TestTempDir) 'secrets.dat'
function Get-SecretStorePath { param([string] $Path) return $script:TestSecretPath }
function Protect-Text   { param([string] $Text)   return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
function Unprotect-Text { param([string] $Base64) return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64)) }

# 疎通確認は外に出るので、テストでは差し替える。
$script:FakeConnection = [pscustomobject]@{ ok = $true; account = 'octocat'; note = '' }
function Test-SetupConnection { param([string] $Key) return $script:FakeConnection }

# 配布設定は見に行かせない (開発機に置いてあると結果が変わる)。
$script:SavedSetupCfgEnv = $env:NOTIFICATION_COLLECTOR_CONFIG
$env:NOTIFICATION_COLLECTOR_CONFIG = Join-Path (New-TestTempDir) 'no-app-config.json'
$script:SavedSetupKeyEnv = $env:ANTHROPIC_API_KEY
$env:ANTHROPIC_API_KEY = $null

Describe 'サービスの名寄せ' {

    It 'キーで引ける' {
        Assert-Equal 'github' (Get-SetupService 'github').key
        Assert-Equal 'slack'  (Get-SetupService 'slack').key
        Assert-Equal 'google' (Get-SetupService 'google').key
        Assert-Equal 'anthropic' (Get-SetupService 'anthropic').key
    }

    It '設定カードの subject_key をそのまま渡しても引ける' {
        Assert-Equal 'github' (Get-SetupService 'setup:github').key
    }

    It 'gmail と書かれても google に寄せる (ホストから決まる名前は google)' {
        Assert-Equal 'google' (Get-SetupService 'gmail').key
    }

    It 'Outlook と Teams は同じ1枚に寄せる (入口は同じアプリ登録なので)' {
        Assert-Equal 'microsoft' (Get-SetupService 'outlook').key
        Assert-Equal 'microsoft' (Get-SetupService 'teams').key
        Assert-Equal 'microsoft' (Get-SetupService 'graph.microsoft.com').key
        Assert-Equal 'microsoft' (Get-SetupService 'setup:microsoft').key
    }

    It '知らないサービスは null' {
        Assert-Null (Get-SetupService 'zoom.us')
        Assert-Null (Get-SetupService '')
    }
}

Describe '画面に返す一覧' {

    It '入力欄の定義は返すが、値は返さない' {
        Set-Secret -Name 'github.token' -Value 'ghp_dummy_token_value_1234567890'
        $list = @(Get-SetupStatusList)
        $json = $list | ConvertTo-Json -Depth 6
        Assert-True ($json -notmatch 'ghp_dummy') 'トークンが一覧に含まれています'
        $gh = @($list | Where-Object { $_.key -eq 'github' })[0]
        Assert-True $gh.configured
        Assert-Equal 1 (@($gh.fields)).Count
        Assert-True $gh.fields[0].secret
    }

    It '未設定のサービスは未設定と分かる' {
        $sl = @(Get-SetupStatusList | Where-Object { $_.key -eq 'slack' })[0]
        Assert-False $sl.configured
    }

    It 'Claude は「無いと動かない」として出る (他の連携と同じ重みで並べない)' {
        $an = @(Get-SetupStatusList | Where-Object { $_.key -eq 'anthropic' })[0]
        Assert-NotNull $an 'Claude が一覧にありません'
        Assert-True $an.required
        foreach ($k in @('github', 'slack', 'google')) {
            Assert-False (@(Get-SetupStatusList | Where-Object { $_.key -eq $k })[0].required) `
                ("{0} まで必須になっています" -f $k)
        }
    }

    It 'DB が無ければ、未接続を知らせるのは Claude だけ (使っていないだけかもしれない)' {
        foreach ($s in @(Get-SetupStatusList)) {
            if ($s.configured) { Assert-False $s.warn ("{0} は接続済みなのに警告しています" -f $s.key); continue }
            if ($s.required) { Assert-True $s.warn ("{0} は必須なのに警告していません" -f $s.key) }
            else { Assert-False $s.warn ("{0} を使うとは言っていないのに警告しています" -f $s.key) }
        }
    }

    It '取り方の案内と入口の URL を持っている (画面から出さずに済ませるため)' {
        foreach ($s in @(Get-SetupStatusList)) {
            Assert-NotNull $s.help  ("{0} に案内がありません" -f $s.key)
            Assert-Match '^https://' $s.docUrl
        }
    }
}

Describe '保存' {
    [void] (Remove-Secret -Name 'github.token')

    It '入力が空なら何もしない (押し間違いで設定を消さない)' {
        $r = Save-SetupCredential -Key 'github' -Values @{ token = '' }
        Assert-False $r.ok
        Assert-Null (Get-Secret -Name 'github.token')
    }

    It '疎通できたら保存し、アカウント名を返す' {
        $script:FakeConnection = [pscustomobject]@{ ok = $true; account = 'octocat'; note = '' }
        $r = Save-SetupCredential -Key 'github' -Values @{ token = 'ghp_good' }
        Assert-True $r.ok
        Assert-Equal 'octocat' $r.account
        Assert-Equal 'ghp_good' (Get-Secret -Name 'github.token')
    }

    It '疎通できなければ元に戻す (貼り間違いを「設定済み」にしない)' {
        $script:FakeConnection = [pscustomobject]@{ ok = $false; error = 'Bad credentials' }
        $r = Save-SetupCredential -Key 'github' -Values @{ token = 'ghp_bad' }
        Assert-False $r.ok
        Assert-Match 'Bad credentials' $r.error
        Assert-Equal 'ghp_good' (Get-Secret -Name 'github.token')
    }

    It 'ブラウザの同意が要るサービスは、貼るだけでは受け付けない' {
        foreach ($k in @('google', 'slack')) {
            $r = Save-SetupCredential -Key $k -Values @{ clientId = 'x'; clientSecret = 'y' }
            Assert-False $r.ok ("{0} が貼るだけで通っています" -f $k)
            Assert-Match '同意' $r.error
        }
    }
}

Describe 'Claude の API キー' {

    It '画面から保存でき、疎通できたときだけ設定済みになる' {
        $script:FakeConnection = [pscustomobject]@{ ok = $true; account = ''; note = '' }
        $r = Save-SetupCredential -Key 'anthropic' -Values @{ apiKey = 'sk-ant-good' }
        Assert-True $r.ok
        Assert-Equal 'sk-ant-good' (Get-Secret -Name 'anthropic.apiKey')
        Assert-True (Test-SetupConfigured -Key 'anthropic')
    }

    It '貼り間違いは元に戻す (「設定済みなのに全部失敗」を作らない)' {
        $script:FakeConnection = [pscustomobject]@{ ok = $false; error = 'キーが受け付けられませんでした' }
        $r = Save-SetupCredential -Key 'anthropic' -Values @{ apiKey = 'sk-ant-bad' }
        Assert-False $r.ok
        Assert-Equal 'sk-ant-good' (Get-Secret -Name 'anthropic.apiKey')
    }

    It 'コードでサインインするサービスも、貼るだけでは受け付けない' {
        # ここで保存できてしまうと「クライアント ID だけ入った未接続の状態」が
        # 設定済みに見える。何が足りないのかを画面に出すほうが早い。
        $r = Save-SetupCredential -Key 'microsoft' -Values @{ clientId = 'cid' }
        Assert-False $r.ok
        Assert-Match 'コード' $r.error
        Assert-Null (Get-Secret -Name 'ms.clientId')
    }
    It '値は画面に返らない' {
        $json = @(Get-SetupStatusList) | ConvertTo-Json -Depth 6
        Assert-True ($json -notmatch 'sk-ant-good') 'API キーが一覧に含まれています'
    }

    It '組織 ID は任意の欄として出る (必須にすると配った先で埋まらない)' {
        $an = @(Get-SetupStatusList | Where-Object { $_.key -eq 'anthropic' })[0]
        $org = @($an.fields | Where-Object { $_.name -eq 'organizationId' })[0]
        Assert-NotNull $org '組織 ID の欄がありません'
        Assert-False $org.required
        Assert-False $org.secret
    }

    It '組織 ID を入れれば保存し、空欄なら前の値を消さない' {
        $script:FakeConnection = [pscustomobject]@{ ok = $true; account = ''; note = '' }
        $r = Save-SetupCredential -Key 'anthropic' -Values @{ apiKey = 'sk-ant-good'; organizationId = ' org-1 ' }
        Assert-True $r.ok
        Assert-Equal 'org-1' (Get-Secret -Name 'anthropic.organizationId')
        $r = Save-SetupCredential -Key 'anthropic' -Values @{ apiKey = 'sk-ant-good2'; organizationId = '' }
        Assert-True $r.ok
        Assert-Equal 'org-1' (Get-Secret -Name 'anthropic.organizationId')
        Assert-Equal 'org-1' (Get-AnthropicOrganizationId)
    }

    It '組織が違っても失敗にはしない。言葉で知らせるだけ (動かすのに要らない値なので)' {
        Assert-Equal '' (Get-AnthropicOrganizationNote -Expected 'org-1' -Actual 'org-1')
        Assert-Equal '' (Get-AnthropicOrganizationNote -Expected '' -Actual 'org-1')
        # 応答に組織が載っていなければ、確かめられないだけで食い違いではない
        Assert-Equal '' (Get-AnthropicOrganizationNote -Expected 'org-1' -Actual '')
        $n = Get-AnthropicOrganizationNote -Expected 'org-1' -Actual 'org-2'
        Assert-Match 'org-2' $n
        Assert-Match 'org-1' $n
    }

    [void] (Remove-Secret -Name 'anthropic.apiKey')
    [void] (Remove-Secret -Name 'anthropic.organizationId')
}

Describe '配る人が用意済みのもの' {

    It '何も無ければ「用意済み」とは言わない' {
        Assert-False (Test-SetupPreset -Key 'anthropic')
        Assert-False (Test-SetupPreset -Key 'google')
        Assert-Equal '' (Get-SetupManagedNote -Key 'google')
    }

    It 'Google のクライアントが入っていれば、利用者に貼らせない' {
        Set-Secret -Name 'gmail.clientId'     -Value 'cid.apps.googleusercontent.com'
        Set-Secret -Name 'gmail.clientSecret' -Value 'sec'
        Assert-True (Test-SetupPreset -Key 'google')
        Assert-Match '許可' (Get-SetupManagedNote -Key 'google')
        # 同意はまだなので「接続済み」にはしない
        Assert-False (Test-SetupConfigured -Key 'google')
    }

    It '同意画面のクライアントは、入力が空でも保管庫から補う' {
        $c = Get-GoogleClientCredential -ClientId '' -ClientSecret ''
        Assert-Equal 'cid.apps.googleusercontent.com' $c.clientId
        Assert-Equal 'sec' $c.clientSecret
    }

    It '入力があればそちらを使う (自分のクライアントに差し替えられる)' {
        $c = Get-GoogleClientCredential -ClientId 'mine' -ClientSecret 'mysec'
        Assert-Equal 'mine' $c.clientId
        Assert-Equal 'mysec' $c.clientSecret
    }

    It '環境変数にキーがあれば、Claude の入力欄は要らない' {
        $env:ANTHROPIC_API_KEY = 'sk-ant-env'
        try {
            Assert-True (Test-SetupPreset -Key 'anthropic')
            Assert-Match '環境変数' (Get-SetupManagedNote -Key 'anthropic')
        }
        finally { $env:ANTHROPIC_API_KEY = $null }
    }

    [void] (Remove-Secret -Name 'gmail.clientId')
    [void] (Remove-Secret -Name 'gmail.clientSecret')

    It 'Microsoft 365 は何も無ければ入力を求める' {
        Assert-False (Test-SetupPreset -Key 'microsoft')
        $r = Start-SetupDeviceCode -Key 'microsoft' -Values @{ clientId = ''; tenantId = ''; clientSecret = '' }
        Assert-False $r.ok
    }

    It 'Microsoft 365 のアプリ登録が配布設定にあれば、押すだけにする (シークレットも使う)' {
        $cfg = Join-Path (New-TestTempDir) 'app-config.json'
        [IO.File]::WriteAllText($cfg,
            '{ "microsoft": { "clientId": "ms-cid", "tenantId": "contoso", "clientSecret": "ms-sec" } }',
            (New-Object Text.UTF8Encoding $false))
        $saved = $env:NOTIFICATION_COLLECTOR_CONFIG
        $env:NOTIFICATION_COLLECTOR_CONFIG = $cfg
        try {
            Assert-True (Test-SetupPreset -Key 'microsoft')
            Assert-Match 'コード' (Get-SetupManagedNote -Key 'microsoft')
            $c = Get-MicrosoftClientCredential
            Assert-Equal 'ms-cid' $c.clientId
            Assert-Equal 'contoso' $c.tenantId
            Assert-Equal 'ms-sec' $c.clientSecret

            # 自分のアプリ登録を入れたら、配布時のシークレットを混ぜない
            # (混ぜると別の登録にシークレットを送って invalid_client になる)
            $mine = Get-MicrosoftClientCredential -ClientId 'my-cid'
            Assert-Equal 'my-cid' $mine.clientId
            Assert-Equal '' $mine.clientSecret
            Assert-Equal '' $mine.tenantId

            # 保管庫にあれば (以前に繋いだ / 取り込み済み)、そちらを使う
            Set-Secret -Name 'ms.clientId' -Value 'stored-cid'
            $st = Get-MicrosoftClientCredential
            Assert-Equal 'stored-cid' $st.clientId
            Assert-Equal '' $st.clientSecret '保管庫の登録に配布設定のシークレットを混ぜています'
        }
        finally {
            $env:NOTIFICATION_COLLECTOR_CONFIG = $saved
            [void] (Remove-Secret -Name 'ms.clientId')
        }
    }
}

Describe 'Slack の同意画面 (中継ページ経由)' {

    # Slack は戻り先に HTTPS を要求するので、Google のように 127.0.0.1 を
    # 直接登録できない。転送しかしない中継ページを挟み、ポートは state で渡す。
    $script:Relay = 'https://example.github.io/nc/slack-oauth-redirect.html'

    It '求めるのはユーザー権限だけ (Bot はワークスペースに増やさない)' {
        $r = Get-SlackAuthRequest -ClientId 'cid' -ClientSecret 'sec' `
                -RedirectUri $script:Relay -BoardPort 8787
        Assert-Match 'slack\.com/oauth/v2/authorize' $r.url
        Assert-Match 'user_scope=' $r.url
        Assert-True ($r.url -notmatch '[?&]scope=') 'Bot 用の scope を求めています'
        foreach ($need in @('im%3Ahistory', 'channels%3Ahistory', 'users%3Aread', 'chat%3Awrite', 'files%3Aread')) {
            Assert-Match $need $r.url
        }
    }

    It '戻り先は中継ページ。ポートは state に埋める' {
        $r = Get-SlackAuthRequest -ClientId 'cid' -ClientSecret 'sec' `
                -RedirectUri $script:Relay -BoardPort 9001
        Assert-Match 'redirect_uri=https%3A%2F%2Fexample\.github\.io' $r.url
        Assert-Match '^9001\.[0-9a-f]{32}$' $r.state
    }

    It 'https でない戻り先は組み立てない (Slack が受け付けないため)' {
        Assert-Throws { Get-SlackAuthRequest -ClientId 'c' -ClientSecret 's' `
            -RedirectUri 'http://127.0.0.1:8787/oauth/slack/callback' -BoardPort 8787 }
    }

    It 'state が合わなければ引き換えない' {
        [void] (Get-SlackAuthRequest -ClientId 'c' -ClientSecret 's' -RedirectUri $script:Relay -BoardPort 8787)
        $r = Complete-SlackAuth -Code 'abc' -State '8787.まちがい'
        Assert-False $r.ok
        Assert-Match 'state' $r.error
    }

    It '同意画面で断られたら、その理由を返す' {
        $req = Get-SlackAuthRequest -ClientId 'c' -ClientSecret 's' -RedirectUri $script:Relay -BoardPort 8787
        $r = Complete-SlackAuth -Code '' -State $req.state -OAuthError 'access_denied'
        Assert-False $r.ok
        Assert-Match 'access_denied' $r.error
    }

    It 'コードが無ければ引き換えない' {
        $req = Get-SlackAuthRequest -ClientId 'c' -ClientSecret 's' -RedirectUri $script:Relay -BoardPort 8787
        $r = Complete-SlackAuth -Code '' -State $req.state
        Assert-False $r.ok
    }

    It 'ユーザートークンと本人のIDを保存する (メンション判定がそのまま動く)' {
        $req = Get-SlackAuthRequest -ClientId 'cid' -ClientSecret 'sec' -RedirectUri $script:Relay -BoardPort 8787
        function Invoke-RestMethod {
            param($Uri, $Method, $Body, $TimeoutSec, $Headers, $ContentType)
            return [pscustomobject]@{
                ok = $true
                authed_user = [pscustomobject]@{ id = 'U123'; access_token = 'xoxp-granted'; scope = 'im:history' }
                team = [pscustomobject]@{ id = 'T1'; name = 'team' }
            }
        }
        try {
            $script:FakeConnection = [pscustomobject]@{ ok = $true; account = 'team / me'; note = '' }
            $r = Complete-SlackAuth -Code 'abc' -State $req.state
            Assert-True $r.ok $r.error
            Assert-Equal 'xoxp-granted' (Get-Secret -Name 'slack.userToken')
            Assert-Equal 'U123' (Get-Secret -Name 'slack.selfUserId')
            Assert-Equal 'cid' (Get-Secret -Name 'slack.clientId')
            # Bot トークンは使わない (求めていないので返ってこない)
            Assert-Null (Get-Secret -Name 'slack.botToken')
        }
        finally { Remove-Item -Path Function:\Invoke-RestMethod -ErrorAction SilentlyContinue }
    }

    It 'Slack が ok:false を返したら保存しない (HTTP 200 で失敗が返る)' {
        [void] (Remove-Secret -Name 'slack.userToken')
        $req = Get-SlackAuthRequest -ClientId 'cid' -ClientSecret 'sec' -RedirectUri $script:Relay -BoardPort 8787
        function Invoke-RestMethod {
            param($Uri, $Method, $Body, $TimeoutSec, $Headers, $ContentType)
            return [pscustomobject]@{ ok = $false; error = 'invalid_code' }
        }
        try {
            $r = Complete-SlackAuth -Code 'abc' -State $req.state
            Assert-False $r.ok
            Assert-Match 'invalid_code' $r.error
            Assert-Null (Get-Secret -Name 'slack.userToken')
        }
        finally { Remove-Item -Path Function:\Invoke-RestMethod -ErrorAction SilentlyContinue }
    }

    It 'ユーザートークンが返ってこなければ失敗として扱う' {
        $req = Get-SlackAuthRequest -ClientId 'cid' -ClientSecret 'sec' -RedirectUri $script:Relay -BoardPort 8787
        function Invoke-RestMethod {
            param($Uri, $Method, $Body, $TimeoutSec, $Headers, $ContentType)
            return [pscustomobject]@{ ok = $true; authed_user = [pscustomobject]@{ id = 'U1' } }
        }
        try {
            $r = Complete-SlackAuth -Code 'abc' -State $req.state
            Assert-False $r.ok
            Assert-Match 'User Token Scopes' $r.error
        }
        finally { Remove-Item -Path Function:\Invoke-RestMethod -ErrorAction SilentlyContinue }
    }

    [void] (Remove-Secret -Name 'slack.userToken')
    [void] (Remove-Secret -Name 'slack.selfUserId')
    [void] (Remove-Secret -Name 'slack.clientId')
    [void] (Remove-Secret -Name 'slack.clientSecret')
    [void] (Remove-Secret -Name 'account.slack')
}

Describe '同意画面の URL' {

    It '戻り先をカンバン自身にして組み立てる' {
        $r = Get-GoogleAuthRequest -ClientId 'cid.apps.googleusercontent.com' -ClientSecret 'sec' `
                -RedirectUri 'http://127.0.0.1:8787/oauth/google/callback'
        Assert-Match 'accounts\.google\.com' $r.url
        Assert-Match 'redirect_uri=http%3A%2F%2F127\.0\.0\.1%3A8787%2Foauth%2Fgoogle%2Fcallback' $r.url
        Assert-Match 'access_type=offline' $r.url
        Assert-NotNull $r.state
    }

    It 'state が合わなければ引き換えない' {
        [void] (Get-GoogleAuthRequest -ClientId 'cid' -ClientSecret 'sec' -RedirectUri 'http://127.0.0.1:8787/x')
        $r = Complete-GoogleAuth -Code 'abc' -State 'まちがい'
        Assert-False $r.ok
        Assert-Match 'state' $r.error
    }

    It 'コードが無ければ引き換えない' {
        [void] (Get-GoogleAuthRequest -ClientId 'cid' -ClientSecret 'sec' -RedirectUri 'http://127.0.0.1:8787/x')
        $st = $script:PendingGoogleAuth.state
        $r = Complete-GoogleAuth -Code '' -State $st
        Assert-False $r.ok
    }
}

if (-not (Test-SqliteAvailable)) {
    Describe '設定が入ったあとの後始末' { Skip-It 'すべて' 'winsqlite3.dll が使えません' }
    return
}

Describe '設定が入ったあとの後始末' {
    $conn = New-TestStore

    # 権限不足で止まったカードを2枚と、そこから生まれた設定カードを1枚作る
    $setupId = [int] (New-SetupTask -Conn $conn -What 'GitHub トークン' -HowTo '入れてください' -ServiceKey 'github')
    $blocked = @()
    foreach ($t in @('CI の失敗を調べる', '招待を承諾する')) {
        $id = [int] (New-Task -Conn $conn -Title $t -Column 'review')
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{
            shape = 'blocked'
            human_step = (@{ blocker = 'credential_missing'; step = '設定してください'; setup_task_id = $setupId } | ConvertTo-Json -Compress)
        })
        $blocked += $id
    }
    # 関係ないカードも1枚
    $other = [int] (New-Task -Conn $conn -Title '無関係なカード' -Column 'review')

    It '待っているカードを見つける' {
        $w = @(Get-TasksWaitingForSetup -Conn $conn -Service 'github' -SetupTaskId $setupId)
        Assert-Equal 2 $w.Count
    }

    $result = Invoke-SetupCompletion -Conn $conn -Service 'github' -Account 'octocat'

    It '待っていたカードを要対応に戻す' {
        Assert-Equal 2 $result.resumed
        foreach ($id in $blocked) {
            $t = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($id)))[0]
            Assert-Equal 'todo' $t['board_column']
            Assert-Equal 0 $t['cancel_requested']
            Assert-Null $t['human_step']
        }
    }

    It '戻したカードはワーカーが拾える状態になっている' {
        $t = Get-NextWorkItem -Conn $conn
        Assert-NotNull $t
        Assert-True ($blocked -contains [int] $t['id'])
    }

    It '関係ないカードは動かさない' {
        $t = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($other)))[0]
        Assert-Equal 'review' $t['board_column']
    }

    It '設定カード自体は完了に移る' {
        $t = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($setupId)))[0]
        Assert-Equal 'done' $t['board_column']
        Assert-Match 'octocat' ([string] $t['user_record'])
        Assert-Match '2 枚' ([string] $t['user_record'])
    }

    It '台帳の「未設定」を打ち消す (ワーカーに渡り続けるため)' {
        $t = Get-ServiceDossierText -Conn $conn
        Assert-Match 'github' $t
        Assert-Match '設定済み' $t
    }

    It '設定カードが無くても落ちない (カードが立つ前に繋いだ場合)' {
        $r = Invoke-SetupCompletion -Conn $conn -Service 'slack' -Account 'team / bot'
        Assert-Equal 0 $r.resumed
        Assert-Equal 0 $r.setupTaskId
    }

    Close-TestStore $conn
}

Describe '未接続を知らせるか' {
    # Claude 以外は「使っていないだけ」がありうる。知らせるのは、使うと選んだとき・
    # 実際に通知が来ているとき・設定カードが立っているときだけ。黙らせることもできる。
    $conn = New-TestStore
    function Get-Att { param([string] $Key) return @(Get-SetupStatusList -Conn $conn | Where-Object { $_.key -eq $Key })[0] }

    It '何も無ければ、Claude 以外は知らせない' {
        Assert-True (Get-Att 'anthropic').warn
        foreach ($k in @('slack', 'microsoft', 'chatwork', 'backlog', 'google')) {
            Assert-False (Get-Att $k).warn ("{0} を知らせています" -f $k)
        }
    }

    It 'そのアプリから通知が来ていれば知らせる (AUMID でしか分からないアプリも)' {
        [void] (Add-Event -Conn $conn -Source 'notification' -SourceKey 'n1' -App '' -AppId 'com.squirrel.slack.slack' -Title 'x')
        $s = Get-Att 'slack'
        Assert-True $s.warn
        Assert-Equal 'notification' $s.seen
    }

    It 'API で取り込んだイベントは根拠にしない (繋がっていないと入ってこない)' {
        [void] (Add-Event -Conn $conn -Source 'outlook' -SourceKey 'm1' -App 'Outlook' -AppId 'outlook' -Title 'x')
        Assert-False (Get-Att 'microsoft').warn
    }

    It '昔の通知だけなら知らせない (一度来ただけで、ずっと警告しない)' {
        $r = Add-Event -Conn $conn -Source 'notification' -SourceKey 'n-old' -App 'Microsoft Teams' -AppId 'MSTeams_8wekyb3d8bbwe!MSTeams' -Title 'x'
        [void] $conn.NonQuery('UPDATE events SET ingested_at = ? WHERE id = ?',
            [object[]] @((Get-Date).AddDays(-60).ToString('o'), $r.id))
        Assert-False (Get-Att 'microsoft').warn
    }

    It '設定カードが立っていれば知らせる' {
        [void] (New-SetupTask -Conn $conn -What 'Chatwork トークン' -HowTo '入れてください' -ServiceKey 'chatwork')
        $s = Get-Att 'chatwork'
        Assert-True $s.warn
        Assert-Equal 'card' $s.seen
    }

    It '「使う」を選べば、通知が無くても知らせる' {
        Set-SetupAttention -Conn $conn -Key 'backlog' -Wanted $true
        Assert-True (Get-Att 'backlog').warn
        Set-SetupAttention -Conn $conn -Key 'backlog' -Wanted $false
        Assert-False (Get-Att 'backlog').warn
    }

    It '「警告しない」を選べば、通知が来ていても黙る (あえて繋がないことはある)' {
        Set-SetupAttention -Conn $conn -Key 'slack' -Muted $true
        $s = Get-Att 'slack'
        Assert-False $s.warn
        Assert-True $s.muted
        # 渡さなかった方は変えない
        Set-SetupAttention -Conn $conn -Key 'slack' -Wanted $true
        Assert-True (Get-Att 'slack').muted
        Set-SetupAttention -Conn $conn -Key 'slack' -Muted $false
        Assert-True (Get-Att 'slack').warn
    }

    It 'Claude は黙らせられない (黙らせると「静かな日」と見分けが付かない)' {
        Assert-Throws { Set-SetupAttention -Conn $conn -Key 'anthropic' -Muted $true }
        Assert-True (Get-Att 'anthropic').warn
    }

    It '接続済みなら、どの条件でも知らせない' {
        # github.token は「保存」のケースで入ったまま
        Set-SetupAttention -Conn $conn -Key 'github' -Wanted $true
        Assert-False (Get-Att 'github').warn
    }

    It '自分で繋いだら「使う」になり、以前の「警告しない」は解ける' {
        Set-SetupAttention -Conn $conn -Key 'google' -Muted $true
        [void] (Invoke-SetupCompletion -Conn $conn -Service 'google' -Account 'me@example.com')
        $g = Get-Att 'google'
        Assert-True $g.wanted
        Assert-False $g.muted
    }

    It '知らないサービスは受け付けない' {
        Assert-Throws { Set-SetupAttention -Conn $conn -Key 'zoom' -Wanted $true }
    }

    Close-TestStore $conn
}

# 環境変数の差し替えを戻す
$env:NOTIFICATION_COLLECTOR_CONFIG = $script:SavedSetupCfgEnv
$env:ANTHROPIC_API_KEY = $script:SavedSetupKeyEnv
