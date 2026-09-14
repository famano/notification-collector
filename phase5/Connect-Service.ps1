<#
.SYNOPSIS
    Phase 5: 外部サービスの資格情報を設定する。対話的に一度だけ実行する。

.DESCRIPTION
    入力した値は DPAPI (CurrentUser) で暗号化して phase5/data/secrets.dat に保存する。
    平文では残らず、別ユーザー・別PCでは復号できない。

.EXAMPLE
    .\Connect-Service.ps1 -Service slack
    .\Connect-Service.ps1 -Service gmail
    .\Connect-Service.ps1 -Service microsoft
    .\Connect-Service.ps1 -Status
#>
[CmdletBinding()]
param(
    [ValidateSet('slack', 'gmail', 'github', 'anthropic', 'microsoft', 'chatwork', 'backlog')] [string] $Service,
    [switch] $Status,
    [switch] $Test
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\SecretStore.ps1"
. "$PSScriptRoot\lib\SlackConnector.ps1"
. "$PSScriptRoot\lib\GmailConnector.ps1"
. "$PSScriptRoot\lib\GraphConnector.ps1"
. "$PSScriptRoot\lib\ChatworkConnector.ps1"
. "$PSScriptRoot\lib\BacklogConnector.ps1"
# 画面と同じ保存・確認の経路を使う (端末と画面で挙動が割れると原因が読めなくなる)
. "$PSScriptRoot\lib\ServiceSetup.ps1"

function Show-Status {
    Write-Host ''
    Write-Host '設定状況' -ForegroundColor Cyan
    $src = Get-AnthropicKeySource
    Write-Host ("  Claude: {0}{1}" -f `
        $(if (Test-AnthropicConfigured) { '設定済み' } else { '未設定' }),
        $(if ($src) { " ($src)" } else { '' }))
    Write-Host ("  Slack : {0}" -f $(if (Test-SlackConfigured) { '設定済み' } else { '未設定' }))
    Write-Host ("  Gmail : {0}" -f $(if (Test-GmailConfigured) { '設定済み' } else { '未設定' }))
    Write-Host ("  GitHub: {0}" -f $(if (Get-Secret -Name 'github.token') { '設定済み' } else { '未設定' }))
    Write-Host ("  Microsoft 365 (Outlook / Teams): {0}" -f $(if (Test-GraphConfigured) { '設定済み' } else { '未設定' }))
    Write-Host ("  Chatwork: {0}" -f $(if (Test-ChatworkConfigured) { '設定済み' } else { '未設定' }))
    Write-Host ("  Backlog : {0}" -f $(if (Test-BacklogConfigured) { ('設定済み (' + (Get-BacklogSpace) + ')') } else { '未設定' }))
    if (Test-GmailConfigured) {
        # Calendar は後から足したスコープなので、古いトークンには入っていない。
        # 「Gmail は設定済みなのに出欠が返せない」理由がここで分かるようにする。
        $cal = $false
        try { $cal = Test-GoogleScope 'https://www.googleapis.com/auth/calendar.events' } catch { }
        Write-Host ("    └ カレンダー操作: {0}" -f $(if ($cal) { '可' } else { '不可 (gmail を設定し直すと有効になります)' })) `
            -ForegroundColor $(if ($cal) { 'DarkGray' } else { 'Yellow' })
    }
    $names = @(Get-SecretNames)
    if ($names.Count -gt 0) {
        Write-Host ''
        Write-Host '  保存されている項目 (値は表示しません):' -ForegroundColor DarkGray
        foreach ($n in $names) { Write-Host "    - $n" -ForegroundColor DarkGray }
    }
    Write-Host ''
}

function Connect-Slack {
    Write-Host ''
    Write-Host 'Slack の設定 (Bot トークン / 任意)' -ForegroundColor Cyan
    Write-Host @'
  通常はここではなく、カンバンのヘッダの「接続」から繋いでください。
  同意画面を通って自分のユーザートークンが入り、招待も貼り付けも要りません。

  ここで入れるのは「投稿を Bot 名義にしたい」場合の Bot トークンです。
  読み取りはユーザートークンが優先されます。

  1. https://api.slack.com/apps で「Create New App」→「From scratch」
  2. OAuth & Permissions → Bot Token Scopes に以下を追加
       channels:history  groups:history  im:history  mpim:history
       channels:read     groups:read     im:read     mpim:read
       users:read
       chat:write        ← 投稿する場合のみ。読むだけなら不要
  3. 「Install to Workspace」で導入 (管理者の承認が要る場合があります)
  4. 表示される Bot User OAuth Token (xoxb- で始まる) を控える
  5. 読みたいチャンネルにこのアプリを招待する (/invite @アプリ名)

  注意: Bot は招待されたチャンネルしか読めません。DM を読ませたい場合は
        im:history が必要で、それでも Bot 自身宛の DM に限られます。
        自分宛の DM まで拾いたい場合は、次に聞く User Token を入れてください。

  投稿について: chat:write を後から足した場合は、再インストールしてトークンを
        取り直さないと有効になりません (missing_scope で失敗します)。
        投稿はワーカーの送信ツールからのみ行い、実行前にカンバンで承認を求めます。
        投稿名義は自分ではなくこの Bot になります。

'@ -ForegroundColor DarkGray

    $sec = Read-Host '  Bot User OAuth Token (xoxb-... / 空欄でスキップ)' -AsSecureString
    $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if ($token) { Set-Secret -Name 'slack.botToken' -Value $token }

    # ---- ユーザートークン (任意) ----
    Write-Host ''
    Write-Host @'
  User Token (任意)

  Bot トークンだけだと、拾えるのは「Bot を招待したチャンネル」に限られます。
  夜のあいだに来た DM や、Bot が居ないチャンネルのメンションは取りこぼします。
  User Token (xoxp-) を入れると、読み取りは自分が見えている範囲すべてになります。

  取り方: 同じアプリの OAuth & Permissions → User Token Scopes に
      channels:history  groups:history  im:history  mpim:history
      channels:read     groups:read     im:read     mpim:read     users:read
  を足して再インストールすると xoxp- のトークンが出ます。

  読み取りだけに使います。投稿は Bot トークンがある限り Bot 名義のままです。

'@ -ForegroundColor DarkGray

    $sec2 = Read-Host '  User OAuth Token (xoxp-... / 空欄でスキップ)' -AsSecureString
    $utoken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec2))
    if ($utoken) { Set-Secret -Name 'slack.userToken' -Value $utoken }

    if (-not (Test-SlackConfigured)) {
        Write-Host '  トークンが入力されませんでした。中止します。' -ForegroundColor Yellow; return
    }

    Write-Host '  保存しました。接続を確認します…' -ForegroundColor DarkGray
    try {
        $r = Invoke-SlackApi -Method 'auth.test'
        Write-Host ("  OK: {0} / {1} として接続できました" -f $r.team, $r.user) -ForegroundColor Green
    }
    catch {
        Write-Host ("  接続できませんでした: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    Set-SlackSelfUserId
}

# 掃き寄せのメンション判定に使う「自分」を決める。
# ユーザートークンなら auth.test がそのまま本人を返すので聞かない。
function Set-SlackSelfUserId {
    if (Get-Secret -Name 'slack.userToken') {
        try {
            $id = [string] (Invoke-SlackApi -Method 'auth.test').user_id
            Set-Secret -Name 'slack.selfUserId' -Value $id
            Write-Host ("  自分のユーザーID: {0} (User Token から判定)" -f $id) -ForegroundColor Green
            return
        } catch { }
    }

    Write-Host ''
    Write-Host '  自分の Slack ユーザーID' -ForegroundColor Cyan
    Write-Host '  メンションされた投稿を拾うのに要ります。メールアドレスか表示名で探します。' -ForegroundColor DarkGray
    $q = Read-Host '  自分のメールアドレスか表示名 (空欄でスキップ)'
    if (-not $q) {
        Write-Host '  スキップしました。メンションは拾えません (DM と既知スレッドの続きのみ)。' -ForegroundColor Yellow
        return
    }
    try { $hits = @(Find-SlackUserId -Query $q) }
    catch { Write-Host ("  検索できませんでした: {0}" -f $_.Exception.Message) -ForegroundColor Red; return }

    if ($hits.Count -eq 0) { Write-Host '  見つかりませんでした。' -ForegroundColor Yellow; return }
    if ($hits.Count -gt 1) {
        Write-Host '  候補が複数あります:' -ForegroundColor Yellow
        for ($i = 0; $i -lt $hits.Count -and $i -lt 10; $i++) {
            Write-Host ("    [{0}] {1}  {2}  {3}" -f $i, $hits[$i].id, $hits[$i].realName, $hits[$i].email)
        }
        $n = Read-Host '  番号を選んでください (空欄で中止)'
        if ($n -eq '' -or -not ($n -match '^\d+$') -or [int] $n -ge $hits.Count) { return }
        $hits = @($hits[[int] $n])
    }
    Set-Secret -Name 'slack.selfUserId' -Value $hits[0].id
    Write-Host ("  自分のユーザーID: {0} ({1})" -f $hits[0].id, $hits[0].realName) -ForegroundColor Green
}

function Connect-Gmail {
    Write-Host ''
    Write-Host 'Gmail の設定' -ForegroundColor Cyan
    Write-Host @'
  事前に Google Cloud で OAuth クライアントを作ってください。

  1. https://console.cloud.google.com/ でプロジェクトを作る
  2. 「APIとサービス」→「ライブラリ」→ Gmail API を有効化
  3. 「OAuth 同意画面」を設定 (User Type は内部または外部/テスト)
     テストの場合は自分のアドレスをテストユーザーに追加する
  4. 「認証情報」→「OAuth クライアント ID」→ アプリの種類は「デスクトップ アプリ」
  5. クライアント ID とクライアント シークレットを控える

  要求するスコープ:
    gmail.readonly … 本文の取得
    gmail.compose  … 下書きの作成と送信
  注意: Google には「下書きだけ」のスコープがありません。compose は送信も許します。
        送信はワーカーの送信ツールからのみ行い、実行前にカンバンで承認を求めます。
        送らせたくない場合はスコープではなく、承認画面で拒否してください。

'@ -ForegroundColor DarkGray

    $cid = Read-Host '  クライアント ID'
    if (-not $cid) { Write-Host '  入力がありません。中止します。' -ForegroundColor Yellow; return }
    $sec = Read-Host '  クライアント シークレット' -AsSecureString
    $csec = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if (-not $csec) { Write-Host '  入力がありません。中止します。' -ForegroundColor Yellow; return }

    Start-GmailAuth -ClientId $cid -ClientSecret $csec
    try {
        $me = Invoke-GmailApi -Path '/users/me/profile'
        Write-Host ("  OK: {0} ({1} 通) として接続できました" -f $me.emailAddress, $me.messagesTotal) -ForegroundColor Green
    }
    catch {
        Write-Host ("  接続確認に失敗しました: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Connect-Microsoft {
    <#
      .DESCRIPTION
        デバイスコードフロー。リダイレクト URI もクライアント シークレットも要らない。
        必要なのはアプリ登録の「アプリケーション (クライアント) ID」1つだけで、
        そのぶん事務所のテナントでも通しやすい。
    #>
    Write-Host ''
    Write-Host 'Microsoft 365 (Outlook / Teams) の設定' -ForegroundColor Cyan
    Write-Host @'
  事前に Microsoft Entra ID (Azure AD) でアプリを1つ登録してください。
  配布設定 (config\app-config.json の microsoft) に入っていれば、ID は空欄のままで進めます。

  1. https://entra.microsoft.com/ → アプリの登録 → 新規登録
  2. 「認証」→ 詳細設定 → パブリック クライアント フローを許可する: はい
     ← ここが「いいえ」だと AADSTS7000218 で失敗します
     「はい」にできないテナントでは、「証明書とシークレット」でシークレットを発行して使います
  3. 「API のアクセス許可」→ Microsoft Graph → 委任されたアクセス許可
       offline_access  User.Read
       Mail.ReadWrite  Mail.Send        (Outlook のメールと下書き・送信)
       Chat.Read       ChatMessage.Send (Teams のチャットと投稿)
     テナントによっては管理者の同意が要ります
  4. 「概要」のアプリケーション (クライアント) ID を控える

  注意: Teams のチャットは職場・学校アカウント専用です。個人の Microsoft
        アカウントには API がありません (Outlook のメールは読めます)。

'@ -ForegroundColor DarkGray

    $cid = Read-Host '  アプリケーション (クライアント) ID (配布時に設定済みなら空欄)'
    $tenant = ''
    $secret = ''
    if ($cid) {
        $tenant = Read-Host '  テナント ID (空欄なら organizations)'
        $sec = Read-Host '  クライアント シークレット (パブリック クライアント フローを許可していれば空欄)' -AsSecureString
        $secret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }
    # 入力が空なら、保管庫 → 配布設定 の順で補う。
    $c = Get-MicrosoftClientCredential -ClientId $cid -TenantId $tenant -ClientSecret $secret
    if (-not $c.clientId) { Write-Host '  入力がありません。中止します。' -ForegroundColor Yellow; return }
    if (-not $cid) { Write-Host ("  用意済みのアプリ登録を使います ({0})" -f $c.clientId) -ForegroundColor DarkGray }

    $start = Start-GraphDeviceCode -ClientId $c.clientId -TenantId $c.tenantId -ClientSecret $c.clientSecret
    if (-not $start.ok) { Write-Host ("  {0}" -f $start.error) -ForegroundColor Red; return }

    Write-Host ''
    Write-Host ("  {0} を開き、次のコードを入力してサインインしてください:" -f $start.verificationUri) -ForegroundColor Cyan
    Write-Host ("      {0}" -f $start.userCode) -ForegroundColor Green
    Write-Host ''
    try { Start-Process $start.verificationUri } catch { }
    Write-Host '  サインインの完了を待っています…' -ForegroundColor DarkGray

    $r = Wait-GraphDeviceCode -TimeoutSec $start.expiresInSec
    if ($r.state -ne 'ok') { Write-Host ("  {0}" -f $r.error) -ForegroundColor Red; return }
    Write-Host ("  OK: {0} として接続できました" -f $r.account) -ForegroundColor Green

    # 掃き寄せで「自分の発言」とメンションを見分けるのに要る。ここで確定させておく。
    try {
        $me = Get-GraphMe
        if ($me.id) { Set-Secret -Name 'ms.selfUserId' -Value $me.id }
    } catch { }

    if (-not (Test-GraphScope 'Chat.Read')) {
        Write-Host '  注意: Chat.Read が付いていないため、Teams のチャットは取り込めません。' -ForegroundColor Yellow
        Write-Host '        アプリ登録のアクセス許可を確認して、もう一度接続してください。' -ForegroundColor DarkGray
    }
}

function Connect-Chatwork {
    Write-Host ''
    Write-Host 'Chatwork の設定' -ForegroundColor Cyan
    Write-Host @'
  個人設定から API トークンを発行して貼るだけです。

  1. 右上のアカウント名 →「サービス連携」→「API Token」
  2. パスワードを入れて表示されたトークンを控える

  拾うのは「ダイレクトチャット」と「[To:自分] などで名指しされたもの」の2つだけです。
  グループの流量そのものはカードにしません ([toall] も拾いません)。

  注意: Chatwork のメール通知を併用していると、同じ用件でメールのカードと
        Chatwork のカードが2枚立ちます。繋いだらメール通知は切るのが早いです。

'@ -ForegroundColor DarkGray

    $sec = Read-Host '  API トークン' -AsSecureString
    $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if (-not $tok) { Write-Host '  入力がありませんでした。' -ForegroundColor Yellow; return }

    $backup = Get-Secret -Name 'chatwork.token'
    Set-Secret -Name 'chatwork.token' -Value $tok.Trim()
    try {
        $me = Get-ChatworkMe
        if ($me.id) { Set-Secret -Name 'chatwork.selfAccountId' -Value $me.id }
        Write-Host ("  OK: {0} として接続できました" -f $me.name) -ForegroundColor Green
    }
    catch {
        # 貼り間違いを残すと「設定済みなのに全部 401」という一番分かりにくい状態になる
        if ($backup) { Set-Secret -Name 'chatwork.token' -Value $backup }
        else { [void] (Remove-Secret -Name 'chatwork.token') }
        Write-Host ("  接続できませんでした: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Connect-Backlog {
    Write-Host ''
    Write-Host 'Backlog の設定' -ForegroundColor Cyan
    Write-Host @'
  個人設定から API キーを発行し、スペースのアドレスと一緒に入れてください。

  1. 右上のアイコン →「個人設定」→「API」→「登録」で API キーを発行
  2. スペースのアドレス (example.backlog.jp) を控える

  「自分宛のお知らせ」の API があるので、掃き寄せも選別も要りません。
  既読にはしません (同期が利用者の画面からお知らせを消すべきではないため)。

  注意: Backlog のメール通知を併用していると、同じ用件でメールのカードと
        Backlog のカードが2枚立ちます。繋いだらメール通知は切るのが早いです。

'@ -ForegroundColor DarkGray

    $space = Read-Host '  スペースのアドレス (example.backlog.jp)'
    if (-not $space) { Write-Host '  入力がありません。中止します。' -ForegroundColor Yellow; return }
    $sec = Read-Host '  API キー' -AsSecureString
    $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if (-not $key) { Write-Host '  入力がありません。中止します。' -ForegroundColor Yellow; return }

    $backupSpace = Get-Secret -Name 'backlog.space'
    $backupKey   = Get-Secret -Name 'backlog.apiKey'
    Set-Secret -Name 'backlog.space'  -Value (Get-BacklogSpace $space)
    Set-Secret -Name 'backlog.apiKey' -Value $key.Trim()
    try {
        $me = Get-BacklogMe
        Write-Host ("  OK: {0} / {1} として接続できました" -f (Get-BacklogSpace), $me.name) -ForegroundColor Green
    }
    catch {
        if ($backupSpace) { Set-Secret -Name 'backlog.space' -Value $backupSpace } else { [void] (Remove-Secret -Name 'backlog.space') }
        if ($backupKey)   { Set-Secret -Name 'backlog.apiKey' -Value $backupKey }  else { [void] (Remove-Secret -Name 'backlog.apiKey') }
        Write-Host ("  接続できませんでした: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Connect-GitHub {
    <#
      .DESCRIPTION
        GitHub は OAuth アプリを用意しなくても、個人アクセストークン (PAT) を
        貼るだけで済む。ワーカーはこれを使って、非公開リポジトリの CI ログを読み、
        コラボレーター招待を承諾する。

        完了カードを洗った結果、29枚中8枚が「権限が無くて進めない」で
        止まっていた。うち7枚はこのトークンがあれば閉じられたもの。
    #>
    Write-Host ''
    Write-Host 'GitHub の個人アクセストークン (PAT) を設定します。' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  取り方: https://github.com/settings/tokens' -ForegroundColor DarkGray
    Write-Host '    Fine-grained token を作り、対象リポジトリに対して以下を許可:' -ForegroundColor DarkGray
    Write-Host '      - Actions: Read-only        (CI の失敗内容を読む)' -ForegroundColor DarkGray
    Write-Host '      - Contents: Read-only       (README など)' -ForegroundColor DarkGray
    Write-Host '      - Metadata: Read-only' -ForegroundColor DarkGray
    Write-Host '    招待の承諾も任せる場合は、アカウント権限の' -ForegroundColor DarkGray
    Write-Host '      - Repository invitations: Read and write' -ForegroundColor DarkGray
    Write-Host '    classic token なら repo スコープでまとめて足ります。' -ForegroundColor DarkGray
    Write-Host ''
    $sec = Read-Host 'GitHub トークン' -AsSecureString
    $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if (-not $tok) { Write-Host '入力がありませんでした。' -ForegroundColor Yellow; return }

    Set-Secret -Name 'github.token' -Value $tok
    Write-Host 'GitHub の資格情報を保存しました。' -ForegroundColor Green

    # 保存したら必ず疎通を見る。貼り間違いを後のカードで気づくのは高くつく。
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri 'https://api.github.com/user' -TimeoutSec 20 `
                -Headers @{ Authorization = "Bearer $tok"; 'User-Agent' = 'notification-collector' }
        Write-Host ("GitHub OK: {0}" -f $r.login) -ForegroundColor Green
    }
    catch {
        Write-Host ("GitHub NG: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host 'トークンを確認してもう一度実行してください。' -ForegroundColor Yellow
    }
}

function Connect-Anthropic {
    Write-Host ''
    Write-Host 'Claude (API キー) の設定' -ForegroundColor Cyan
    Write-Host @'
  https://console.anthropic.com/settings/keys で「Create Key」を押すと
  sk-ant- で始まる文字列が出ます。これを貼ってください。

  通常はこの端末に来る必要はありません。カンバンのヘッダの「接続」からも
  同じことができます (配る側が config\app-config.json に入れておけば、
  利用者はどちらも開かずに済みます)。

'@ -ForegroundColor DarkGray

    $sec = Read-Host '  API キー (sk-ant-... / 空欄で中止)' -AsSecureString
    $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if (-not $key) { Write-Host '  中止しました。' -ForegroundColor Yellow; return }

    Write-Host '  保存して確認します…' -ForegroundColor DarkGray
    $r = Save-SetupCredential -Key 'anthropic' -Values @{ apiKey = $key }
    if ($r.ok) { Write-Host '  OK: キーは有効です' -ForegroundColor Green }
    else       { Write-Host ("  NG: {0}" -f $r.error) -ForegroundColor Red }
}

function Test-GitHubConfigured {
    return [bool] (Get-Secret -Name 'github.token')
}

function Test-Connections {
    Write-Host ''
    if (Test-AnthropicConfigured) {
        $r = Test-SetupConnection -Key 'anthropic'
        if ($r.ok) { Write-Host 'Claude OK: キーは有効です' -ForegroundColor Green }
        else       { Write-Host ("Claude NG: {0}" -f $r.error) -ForegroundColor Red }
    } else { Write-Host 'Claude: 未設定' -ForegroundColor DarkGray }

    if (Test-GitHubConfigured) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $r = Invoke-RestMethod -Uri 'https://api.github.com/user' -TimeoutSec 20 `
                    -Headers @{ Authorization = "Bearer $(Get-Secret -Name 'github.token')"; 'User-Agent' = 'notification-collector' }
            Write-Host ("GitHub OK: {0}" -f $r.login) -ForegroundColor Green
        }
        catch { Write-Host ("GitHub NG: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    } else { Write-Host 'GitHub: 未設定' -ForegroundColor DarkGray }

    if (Test-SlackConfigured) {
        try { $r = Invoke-SlackApi -Method 'auth.test'; Write-Host ("Slack OK: {0} / {1}" -f $r.team, $r.user) -ForegroundColor Green }
        catch { Write-Host ("Slack NG: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    } else { Write-Host 'Slack: 未設定' -ForegroundColor DarkGray }

    if (Test-GmailConfigured) {
        try { $m = Invoke-GmailApi -Path '/users/me/profile'; Write-Host ("Gmail OK: {0}" -f $m.emailAddress) -ForegroundColor Green }
        catch { Write-Host ("Gmail NG: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    } else { Write-Host 'Gmail: 未設定' -ForegroundColor DarkGray }

    if (Test-ChatworkConfigured) {
        try { $me = Get-ChatworkMe; Write-Host ("Chatwork OK: {0}" -f $me.name) -ForegroundColor Green }
        catch { Write-Host ("Chatwork NG: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    } else { Write-Host 'Chatwork: 未設定' -ForegroundColor DarkGray }

    if (Test-BacklogConfigured) {
        try { $me = Get-BacklogMe; Write-Host ("Backlog OK: {0} / {1}" -f (Get-BacklogSpace), $me.name) -ForegroundColor Green }
        catch { Write-Host ("Backlog NG: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    } else { Write-Host 'Backlog: 未設定' -ForegroundColor DarkGray }

    if (Test-GraphConfigured) {
        try {
            $me = Get-GraphMe
            $chat = if (Test-GraphScope 'Chat.Read') { 'Teams 可' } else { 'Teams 不可 (Chat.Read が無い)' }
            Write-Host ("Microsoft OK: {0} / {1}" -f $me.account, $chat) -ForegroundColor Green
        }
        catch { Write-Host ("Microsoft NG: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    } else { Write-Host 'Microsoft: 未設定' -ForegroundColor DarkGray }
    Write-Host ''
}

if ($Status) { Show-Status; return }
if ($Test)   { Test-Connections; return }

switch ($Service) {
    'slack'     { Connect-Slack }
    'gmail'     { Connect-Gmail }
    'github'    { Connect-GitHub }
    'anthropic' { Connect-Anthropic }
    'microsoft' { Connect-Microsoft }
    'chatwork'  { Connect-Chatwork }
    'backlog'   { Connect-Backlog }
    default {
        Show-Status
        Write-Host '使い方:' -ForegroundColor Cyan
        Write-Host '  .\Connect-Service.ps1 -Service anthropic'
        Write-Host '  .\Connect-Service.ps1 -Service slack'
        Write-Host '  .\Connect-Service.ps1 -Service gmail'
        Write-Host '  .\Connect-Service.ps1 -Service microsoft'
        Write-Host '  .\Connect-Service.ps1 -Service chatwork'
        Write-Host '  .\Connect-Service.ps1 -Service backlog'
        Write-Host '  .\Connect-Service.ps1 -Test     接続確認'
        Write-Host ''
        Write-Host '  同じことはカンバンのヘッダの「接続」からもできます。' -ForegroundColor DarkGray
        Write-Host ''
    }
}
