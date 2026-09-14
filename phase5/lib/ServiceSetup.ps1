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
#              'device' は画面にコードを出し、別のタブでサインインしてもらう
#              (リダイレクト URI の登録が要らないぶん、事務所のテナントで通りやすい)。
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

組織 ID は任意です。動かすのには要りません。入れておくと、接続の確認のときに
「貼ったキーがその組織のものか」を突き合わせ、違えば知らせます
(個人の組織で作ったキーを貼ってしまい、請求先が違う、を見つけるためのものです)。
console.anthropic.com の Settings → Organization で確認できます。
'@
        secrets = @('anthropic.apiKey', 'anthropic.organizationId')
        fields  = @(
            @{ name = 'apiKey'; label = 'API キー'; secret = $true; required = $true
               placeholder = 'sk-ant-...' },
            @{ name = 'organizationId'; label = '組織 ID'; secret = $false; required = $false
               placeholder = '00000000-0000-0000-0000-000000000000'
               hint = '空欄でも動きます。入れると、キーがこの組織のものかを確認します' }
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
        # Google と同じく同意画面を通す。以前は xoxb- / xoxp- を貼る方式だったが、
        # **その画面に入れるのはアプリを作れる人だけ**で、配った先では永久に埋まらない
        # 空欄になっていた。ここを同意画面に変えると、配る人が用意するのは
        # アプリ (client id / secret) だけで済み、トークンは各自が自分の分を取る。
        flow  = 'oauth'
        why   = '自分に届いたメンションと DM の取得、元スレッドへの返信。'
        docUrl = 'https://api.slack.com/apps'
        help  = @'
配る人が Slack アプリを1つ作り、クライアント ID とシークレットを控えます。
OAuth & Permissions の User Token Scopes に以下を足してください
(Bot Token Scopes は要りません)。
  channels:history groups:history im:history mpim:history
  channels:read    groups:read    im:read    mpim:read
  users:read  files:read  chat:write

Redirect URLs には中継ページの URL を登録します (Slack は HTTPS しか受け付けず、
127.0.0.1 を直接登録できないため)。ページは docs\slack-oauth-redirect.html を
そのまま公開したもので、転送以外は何もしません。

「Slack に接続する」を押すと同意画面が開き、許可すると戻ってきます。
読み書きはどちらも自分の権限で行われ、**返信は自分の名義で投稿されます。**
Bot は増えないので、チャンネルへの招待も要りません。
'@
        secrets = @('slack.clientId', 'slack.clientSecret', 'slack.userToken', 'slack.selfUserId')
        fields  = @(
            @{ name = 'clientId';     label = 'クライアント ID'; secret = $false; required = $true
               placeholder = '1234567890.1234567890123' },
            @{ name = 'clientSecret'; label = 'クライアント シークレット'; secret = $true; required = $true }
        )
    },
    @{
        key   = 'chatwork'
        label = 'Chatwork'
        flow  = 'token'
        why   = 'ダイレクトチャットと自分宛メンションの取得、同じ部屋への投稿。'
        docUrl = 'https://www.chatwork.com/service/packages/chatwork/subpackages/api/token.php'
        help  = @'
Chatwork の個人設定から API トークンを発行して貼るだけです。

  1. 右上のアカウント名 →「サービス連携」→「API Token」
  2. パスワードを入れて表示されたトークンを控える

読むのも書くのも同じトークンです。拾うのは
  ・ダイレクトチャットに来たもの
  ・[To:自分] や返信で名指しされたもの
の2つだけで、グループの流量そのものはカードにしません ([toall] も拾いません)。

注意: Chatwork 側のメール通知を併用していると、同じ用件でメールのカードと
Chatwork のカードが2枚立ちます。繋いだらメール通知は切るのが早いです。
'@
        secrets = @('chatwork.token', 'chatwork.selfAccountId')
        fields  = @(
            @{ name = 'token'; label = 'API トークン'; secret = $true; required = $true }
        )
    },
    @{
        key   = 'backlog'
        label = 'Backlog'
        flow  = 'token'
        why   = '自分宛のお知らせ (担当に設定・コメント) の取得と、課題へのコメント投稿。'
        docUrl = 'https://support-ja.backlog.com/hc/ja/articles/360035641754'
        help  = @'
個人設定から API キーを発行し、スペースのアドレスと一緒に入れてください。

  1. 右上のアイコン →「個人設定」→「API」→「登録」で API キーを発行
  2. スペースのアドレス (example.backlog.jp) を控える
     https:// やその後ろのパスは付いていてもかまいません

Backlog には「自分宛のお知らせ」の API があるので、掃き寄せも選別も要りません。
**既読にはしません** ―― 同期が利用者の画面からお知らせを消すべきではないため、
「どこまで取ったか」はこちら側で持ちます。

注意: Backlog のメール通知を併用していると、同じ用件でメールのカードと
Backlog のカードが2枚立ちます。繋いだらメール通知は切るのが早いです。
'@
        secrets = @('backlog.apiKey', 'backlog.space')
        fields  = @(
            @{ name = 'space';  label = 'スペースのアドレス'; secret = $false; required = $true
               placeholder = 'example.backlog.jp' },
            @{ name = 'apiKey'; label = 'API キー'; secret = $true; required = $true }
        )
    },
    @{
        key   = 'microsoft'
        label = 'Microsoft 365 (Outlook / Teams)'
        flow  = 'device'
        why   = 'Outlook のメールと Teams のチャットの取得、下書き・送信・投稿。'
        docUrl = 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade'
        help  = @'
Microsoft Entra ID (Azure AD) でアプリを1つ登録し、その「アプリケーション (クライアント) ID」を入れます。
配る人が config\app-config.json の microsoft 欄に入れておけば、利用者は押すだけで済みます。

  1. アプリの登録 → 新規登録。名前は何でもよい
     サポートされるアカウントの種類は「この組織ディレクトリのみ」で足ります
  2. 「認証」→ 詳細設定 → **パブリック クライアント フローを許可する: はい**
     ここが「いいえ」のままだと AADSTS7000218 で失敗します
     テナントの方針で「はい」にできない場合は、代わりに「証明書とシークレット」で
     クライアント シークレットを発行し、シークレットの欄に入れてください
  3. 「API のアクセス許可」→ Microsoft Graph → 委任されたアクセス許可に以下を追加
       offline_access  User.Read
       Mail.ReadWrite  Mail.Send        (Outlook のメールと下書き・送信)
       Chat.Read       ChatMessage.Send (Teams のチャットと投稿)
     テナントの設定によっては管理者の同意が要ります
  4. 「概要」のアプリケーション (クライアント) ID をここに貼る

テナント ID は空欄でかまいません (職場・学校アカウントとして organizations に繋ぎます)。
複数のテナントに所属していて繋ぎ先を固定したいときだけ、ディレクトリ ID を入れてください。

注意: Teams のチャットは職場・学校アカウント専用です。個人の Microsoft アカウントには
API がありません (Outlook のメールは個人アカウントでも読めます)。
'@
        secrets = @('ms.clientId', 'ms.tenantId', 'ms.clientSecret', 'ms.refreshToken', 'ms.selfUserId')
        fields  = @(
            @{ name = 'clientId'; label = 'アプリケーション (クライアント) ID'; secret = $false; required = $true
               placeholder = '00000000-0000-0000-0000-000000000000' },
            @{ name = 'tenantId'; label = 'テナント ID'; secret = $false; required = $false
               placeholder = 'organizations'; hint = '空欄なら職場・学校アカウント (organizations) として繋ぎます' },
            @{ name = 'clientSecret'; label = 'クライアント シークレット'; secret = $true; required = $false
               hint = 'パブリック クライアント フローを許可していない登録のときだけ入れます' }
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
$script:SetupAliases = @{
    gmail = 'google'; googleapis = 'google'; 'github.com' = 'github'
    # Outlook も Teams も入口は同じアプリ登録なので、設定カードは1枚に束ねる。
    outlook = 'microsoft'; teams = 'microsoft'; ms = 'microsoft'
    'graph.microsoft.com' = 'microsoft'; 'login.microsoftonline.com' = 'microsoft'
    'api.chatwork.com' = 'chatwork'; 'chatwork.com' = 'chatwork'
    'backlog.jp' = 'backlog'; 'backlog.com' = 'backlog'; 'backlogtool.com' = 'backlog'
}

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
        'slack'  { return [bool] (Get-Secret -Name 'slack.userToken') }
        'google' { return [bool] ((Get-Secret -Name 'gmail.refreshToken') -and (Get-Secret -Name 'gmail.clientId')) }
        'microsoft' { return [bool] ((Get-Secret -Name 'ms.refreshToken') -and (Get-Secret -Name 'ms.clientId')) }
        'chatwork'  { return [bool] (Get-Secret -Name 'chatwork.token') }
        'backlog'   { return [bool] ((Get-Secret -Name 'backlog.apiKey') -and (Get-Secret -Name 'backlog.space')) }
    }
    return $false
}

# 画面に渡す一覧。**トークンは含めない。**
#
# -Conn を渡すと「未接続を警告すべきか」まで判定する (カードの DB を見るため)。
# 渡さなければ、警告するのは無いと動かないもの (Claude) だけになる。
function Get-SetupStatusList {
    param($Conn)
    $apps = @(Get-SetupNotificationApps -Conn $Conn)
    $out = @()
    foreach ($s in $script:SetupServices) {
        $configured = (Test-SetupConfigured -Key $s.key)
        $att = Get-SetupAttention -Conn $Conn -Key $s.key -Configured $configured `
                    -Required ([bool] $s.required) -NotificationApps $apps
        $out += [pscustomobject]@{
            key        = $s.key
            label      = $s.label
            flow       = $s.flow
            why        = $s.why
            help       = $s.help
            docUrl     = $s.docUrl
            configured = $configured
            account    = (Get-SetupAccount -Key $s.key)
            # これが無いとアプリが成立しないもの。画面はこれを先頭に出す。
            required   = [bool] $s.required
            # 未接続を知らせるべきか。warn だけを見ればよい。
            # 残りは画面が「なぜ知らせているか」「どう黙らせるか」を出すための材料。
            warn       = $att.warn
            wanted     = $att.wanted
            muted      = $att.muted
            seen       = $att.seen
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

# ---------------------------------------------------------------- 未接続を知らせるか
#
# 以前は未接続のサービスを全部数えてヘッダに出していた。だが Claude 以外は
# **使っていないだけ**のことが多い ―― Backlog を使わない職場で「Backlog が未接続」と
# 出し続けると、警告そのものが読まれなくなり、本当に要る警告まで埋もれる。
#
# そこで、未接続を知らせるのは次のどれかに当たるときだけにする。
#   required     … 無いと動かないもの (Claude)。黙らせることもできない
#   wanted       … 利用者が「使う」と選んだ (一度繋いだものも含む)
#   seen         … 実際にそのサービスから通知が来ている / 設定カードが立っている
# ただし muted (「このサービスは警告しない」) が立っていれば、required 以外は黙る。
# **あえて繋がない**ことはありうる (会社の方針、個人アカウントに繋ぎたくない等)。

# 通知 (トースト) の送り主から、どのサービスかを当てる。AUMID と表示名の両方を見る
# (Slack のように表示名が空で AUMID でしか分からないアプリがある)。
$script:SetupNotificationApps = @{
    slack     = @('*slack*')
    microsoft = @('*teams*', '*outlook*')
    chatwork  = @('*chatwork*')
    backlog   = @('*backlog*')
    github    = @('*github*')
    google    = @('*gmail*')
}

# 「通知が来ている」と見なす期間。昔一度だけ来た通知で、ずっと警告し続けない。
$script:SetupEvidenceDays = 30

function Get-SetupNotificationApps {
    <#
      .SYNOPSIS
        最近通知を出したアプリ (AUMID と表示名) を小文字で返す。DB が無ければ空。
      .DESCRIPTION
        見るのは source = 'notification' だけ。API で掃き寄せたイベントは
        繋がっていないと入ってこないので、未接続の根拠にならない。
    #>
    param($Conn)
    if (-not $Conn) { return @() }
    try {
        $since = (Get-Date).AddDays(-$script:SetupEvidenceDays).ToString('o')
        $rows = @($Conn.Query(
            "SELECT DISTINCT lower(COALESCE(app_id, '')) AS a, lower(COALESCE(app, '')) AS b
               FROM events WHERE source = 'notification' AND ingested_at >= ?", [object[]] @($since)))
    }
    catch { return @() }
    $out = @()
    foreach ($r in $rows) {
        foreach ($v in @([string] $r['a'], [string] $r['b'])) { if ($v) { $out += $v } }
    }
    return $out
}

function Get-SetupAttention {
    <#
      .OUTPUTS
        [pscustomobject] warn / wanted / muted / seen ('' | 'notification' | 'card')
    #>
    param(
        $Conn,
        [Parameter(Mandatory)] [string] $Key,
        [bool] $Configured,
        [bool] $Required,
        [string[]] $NotificationApps = @()
    )
    $wanted = $false; $muted = $false; $seen = ''
    if ($Conn -and (Get-Command Get-Setting -ErrorAction SilentlyContinue)) {
        try {
            $wanted = ((Get-Setting -Conn $Conn -Key ("setup.attention.{0}.wanted" -f $Key) -Default '0') -eq '1')
            $muted  = ((Get-Setting -Conn $Conn -Key ("setup.attention.{0}.muted"  -f $Key) -Default '0') -eq '1')
        } catch { }
    }
    # 無いと動かないものは黙らせない。黙らせた結果「カードが1枚も増えない静かな日」に見える。
    if ($Required) { $muted = $false }

    if (-not $Configured -and -not $Required) {
        # 設定カードが立っている = ワーカーが実際にそのサービスの権限不足で止まった
        if ($Conn -and (Get-Command Get-OpenSetupTask -ErrorAction SilentlyContinue)) {
            try { if (Get-OpenSetupTask -Conn $Conn -Service $Key) { $seen = 'card' } } catch { }
        }
        if (-not $seen -and $script:SetupNotificationApps.ContainsKey($Key)) {
            foreach ($app in $NotificationApps) {
                foreach ($pat in $script:SetupNotificationApps[$Key]) {
                    if ($app -like $pat) { $seen = 'notification'; break }
                }
                if ($seen) { break }
            }
        }
    }

    $warn = (-not $Configured) -and ($Required -or ((-not $muted) -and ($wanted -or [bool] $seen)))
    return [pscustomobject]@{ warn = [bool] $warn; wanted = $wanted; muted = $muted; seen = $seen }
}

function Set-SetupAttention {
    <#
      .SYNOPSIS
        「使う」「警告しない」を保存する。渡したものだけを変える。
    #>
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [string] $Key,
        [Nullable[bool]] $Wanted,
        [Nullable[bool]] $Muted
    )
    $svc = Get-SetupService $Key
    if (-not $svc) { throw ("知らないサービスです: {0}" -f $Key) }
    if ($null -ne $Wanted) {
        Set-Setting -Conn $Conn -Key ("setup.attention.{0}.wanted" -f $svc.key) -Value $(if ($Wanted) { '1' } else { '0' })
    }
    if ($null -ne $Muted) {
        if ($Muted -and $svc.required) { throw ("{0} は無いと動かないため、警告を止められません。" -f $svc.label) }
        Set-Setting -Conn $Conn -Key ("setup.attention.{0}.muted" -f $svc.key) -Value $(if ($Muted) { '1' } else { '0' })
    }
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
        'slack' {
            # Slack は中継ページも要る。3つ揃って初めて「押すだけ」になる。
            $c = Get-SlackClientCredential
            return [bool] ($c.clientId -and $c.clientSecret -and $c.redirectUri)
        }
        'microsoft' {
            # デバイスコードはシークレット無しでも通る。クライアント ID があれば押すだけにできる。
            return [bool] (Get-MicrosoftClientCredential).clientId
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
        'slack'  { return '接続に使う情報は配布時に設定されています。ボタンを押して Slack の画面で許可してください。' }
        'microsoft' { return '接続に使う情報は配布時に設定されています。ボタンを押し、表示されたコードで Microsoft にサインインしてください。' }
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

# 貼るだけのサービス (GitHub / Chatwork / Backlog など) の保存と疎通確認。
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
        $how = if ($svc.flow -eq 'device') { 'サインイン画面にコードを入れる必要があります' } else { 'ブラウザでの同意が要ります' }
        return [pscustomobject]@{ ok = $false; error = ("{0} は貼るだけでは設定できません。{1}。" -f $svc.label, $how) }
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
            'anthropic' {
                Set-Secret -Name 'anthropic.apiKey' -Value ([string] $Values['apiKey']).Trim()
                # 空欄のときは触らない。キーだけ差し替えた人の組織 ID (配布時の値) を消さない。
                $org = ([string] $Values['organizationId']).Trim()
                if ($org) { Set-Secret -Name 'anthropic.organizationId' -Value $org }
            }
            'github' { Set-Secret -Name 'github.token' -Value ([string] $Values['token']).Trim() }
            'chatwork' { Set-Secret -Name 'chatwork.token' -Value ([string] $Values['token']).Trim() }
            'backlog' {
                # スペースは https:// やパスが付いたまま貼られがち。保存の時点で均す
                # (毎回の呼び出しで直すと、直し漏れた1箇所が 404 になる)。
                # 均す側はコネクタが持っている。読み込まれていないなら保存しない ――
                # 生のまま保存すると「設定済みなのに全部 404」になる。
                if (-not (Get-Command Get-BacklogSpace -ErrorAction SilentlyContinue)) {
                    throw 'Backlog 連携が読み込まれていません。'
                }
                Set-Secret -Name 'backlog.space'  -Value (Get-BacklogSpace ([string] $Values['space']))
                Set-Secret -Name 'backlog.apiKey' -Value ([string] $Values['apiKey']).Trim()
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
                    $resp = Invoke-WebRequest -Uri 'https://api.anthropic.com/v1/models?limit=1' -TimeoutSec 20 `
                        -UseBasicParsing -Headers @{ 'x-api-key' = $key; 'anthropic-version' = '2023-06-01' }
                }
                catch {
                    return [pscustomobject]@{ ok = $false; error = (Get-AnthropicErrorMessage $_) }
                }
                # アカウント名は API から取れないが、応答ヘッダにキーの組織が載る。
                # 載っていなければ突き合わせない (確かめられないことを食い違いとは言わない)。
                $actualOrg = ''
                try { $actualOrg = [string] $resp.Headers['anthropic-organization-id'] } catch { }
                $expectedOrg = Get-AnthropicOrganizationId
                $account = if ($actualOrg) { "組織 $actualOrg" } else { '' }
                # キーそのものは決して画面に返さない。
                return [pscustomobject]@{
                    ok = $true; account = $account
                    note = (Get-AnthropicOrganizationNote -Expected $expectedOrg -Actual $actualOrg)
                }
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
                # 掃き寄せのメンション判定に使う「自分」。本人のトークンなので
                # auth.test がそのまま本人を返す ―― 別途聞く必要はない。
                if ($r.user_id) { Set-Secret -Name 'slack.selfUserId' -Value ([string] $r.user_id) }
                return [pscustomobject]@{ ok = $true; account = ("{0} / {1}" -f $r.team, $r.user); note = '' }
            }
            'google' {
                if (-not (Get-Command Invoke-GmailApi -ErrorAction SilentlyContinue)) {
                    return [pscustomobject]@{ ok = $false; error = 'Gmail 連携が読み込まれていません。' }
                }
                $m = Invoke-GmailApi -Path '/users/me/profile'
                return [pscustomobject]@{ ok = $true; account = [string] $m.emailAddress; note = '' }
            }
            'chatwork' {
                if (-not (Get-Command Get-ChatworkMe -ErrorAction SilentlyContinue)) {
                    return [pscustomobject]@{ ok = $false; error = 'Chatwork 連携が読み込まれていません。' }
                }
                $me = Get-ChatworkMe
                # 掃き寄せで「自分の発言」とメンションを見分けるのに要る。ここで分かるので聞かない。
                if ($me.id) { Set-Secret -Name 'chatwork.selfAccountId' -Value $me.id }
                return [pscustomobject]@{ ok = $true; account = $me.name; note = '' }
            }
            'backlog' {
                if (-not (Get-Command Get-BacklogMe -ErrorAction SilentlyContinue)) {
                    return [pscustomobject]@{ ok = $false; error = 'Backlog 連携が読み込まれていません。' }
                }
                $me = Get-BacklogMe
                return [pscustomobject]@{ ok = $true; account = ("{0} / {1}" -f (Get-BacklogSpace), $me.name); note = '' }
            }
            'microsoft' {
                if (-not (Get-Command Get-GraphMe -ErrorAction SilentlyContinue)) {
                    return [pscustomobject]@{ ok = $false; error = 'Microsoft 連携が読み込まれていません。' }
                }
                $me = Get-GraphMe
                # 掃き寄せで「自分の発言」とメンションを見分けるのに要る。
                # ここで分かるので、利用者に聞かない。
                if ($me.id) { Set-Secret -Name 'ms.selfUserId' -Value $me.id }
                $note = ''
                if ((Get-Command Test-GraphScope -ErrorAction SilentlyContinue) -and
                    -not (Test-GraphScope 'Chat.Read')) {
                    $note = 'Teams のチャットは読めません (同意画面で Chat.Read が付きませんでした)。Outlook のメールだけを取り込みます。'
                }
                return [pscustomobject]@{ ok = $true; account = $me.account; note = $note }
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

function Get-SlackClientCredential {
    <#
      .SYNOPSIS
        Slack の同意画面に使うアプリと戻り先を決める。画面の入力 → 保管庫 → 配布設定 の順。
      .DESCRIPTION
        戻り先 (中継ページ) だけは配布設定にしか置かない。**利用者が決める値ではない**
        ―― Slack アプリ側に登録済みの URL と一字一句合っている必要があり、
        画面から変えられるようにすると合わなくなるだけである。
      .OUTPUTS
        [pscustomobject] clientId / clientSecret / redirectUri
    #>
    param([string] $ClientId, [string] $ClientSecret)
    $cid = ([string] $ClientId).Trim()
    $sec = ([string] $ClientSecret).Trim()
    if (-not $cid) { $cid = [string] (Get-Secret -Name 'slack.clientId') }
    if (-not $sec) { $sec = [string] (Get-Secret -Name 'slack.clientSecret') }
    if (-not $cid) { $cid = [string] (Get-AppConfigValue -Path 'slack.clientId') }
    if (-not $sec) { $sec = [string] (Get-AppConfigValue -Path 'slack.clientSecret') }
    $redirect = [string] (Get-AppConfigValue -Path 'slack.redirectUrl')
    return [pscustomobject]@{ clientId = $cid; clientSecret = $sec; redirectUri = $redirect }
}

$script:PendingSlackAuth = $null

function Get-SlackAuthRequest {
    <#
      .SYNOPSIS
        Slack の同意画面の URL を組み立て、戻ってきたときに照合する state を控える。
      .DESCRIPTION
        Slack は戻り先に HTTPS を要求するので、Google のように 127.0.0.1 を
        直接登録できない。そこで戻り先は**転送しかしない静的な中継ページ**にして、
        そこから http://127.0.0.1:<ポート>/oauth/slack/callback に戻してもらう。

        中継ページはポート番号を知らないので、**state に埋めて渡す。**
        形は "<ポート>.<乱数>"。乱数の側は戻ってきたときの照合に使う (CSRF 対策)
        ので、ポートを載せたぶんだけ弱くならないよう乱数はそのまま持たせる。

        **認可コードは中継ページを通るが、それだけでは何もできない。**
        引き換えには client secret が要り、それは手元にしか無い。
      .OUTPUTS
        [pscustomobject] url / state / redirectUri
    #>
    param(
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $ClientSecret,
        [Parameter(Mandatory)] [string] $RedirectUri,
        [Parameter(Mandatory)] [int] $BoardPort
    )
    if ($RedirectUri -notmatch '^https://') {
        throw 'Slack の戻り先は https:// でなければなりません (中継ページの URL を設定してください)。'
    }
    if ($BoardPort -le 0 -or $BoardPort -gt 65535) { throw 'ポート番号が不正です。' }

    $scopes = if ($script:SlackUserScopes) { $script:SlackUserScopes -join ',' } else {
        'channels:history,groups:history,im:history,mpim:history,channels:read,groups:read,im:read,mpim:read,users:read,files:read,chat:write'
    }
    $authUrl = if ($script:SlackAuth) { $script:SlackAuth } else { 'https://slack.com/oauth/v2/authorize' }

    $nonce = [guid]::NewGuid().ToString('N')
    $state = "{0}.{1}" -f $BoardPort, $nonce
    # シークレットはここでは保存しない。同意が返ってくるまでメモリに置く。
    $script:PendingSlackAuth = @{
        state = $state; clientId = $ClientId.Trim(); clientSecret = $ClientSecret.Trim()
        redirectUri = $RedirectUri; createdAt = (Get-Date)
    }
    # user_scope だけを求める。scope (Bot 用) は空のままにする ――
    # 空にしておけば、ワークスペースに Bot が増えない。
    $url = "$authUrl" +
        "?client_id=$([Uri]::EscapeDataString($ClientId.Trim()))" +
        "&user_scope=$([Uri]::EscapeDataString($scopes))" +
        "&redirect_uri=$([Uri]::EscapeDataString($RedirectUri))" +
        "&state=$state"
    return [pscustomobject]@{ url = $url; state = $state; redirectUri = $RedirectUri }
}

function Complete-SlackAuth {
    <#
      .SYNOPSIS
        中継ページ経由で戻ってきた認可コードを引き換えて保存する。
      .OUTPUTS
        [pscustomobject] ok / account / error
    #>
    param([string] $Code, [string] $State, [string] $OAuthError)

    $p = $script:PendingSlackAuth
    if (-not $p) { return [pscustomobject]@{ ok = $false; error = '設定の途中経過が見つかりません。もう一度やり直してください。' } }
    if (((Get-Date) - $p.createdAt).TotalMinutes -gt 10) {
        $script:PendingSlackAuth = $null
        return [pscustomobject]@{ ok = $false; error = '時間切れです。もう一度やり直してください。' }
    }
    if (-not $State -or $State -ne $p.state) {
        return [pscustomobject]@{ ok = $false; error = 'state が一致しません。中断しました。' }
    }
    if ($OAuthError) {
        $script:PendingSlackAuth = $null
        return [pscustomobject]@{ ok = $false; error = ("Slack 側で中断されました: {0}" -f $OAuthError) }
    }
    if (-not $Code) { return [pscustomobject]@{ ok = $false; error = '認可コードを受け取れませんでした。' } }

    $tokenUrl = if ($script:SlackToken) { $script:SlackToken } else { 'https://slack.com/api/oauth.v2.access' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-RestMethod -Uri $tokenUrl -Method Post -TimeoutSec 30 -Body @{
            code = $Code; client_id = $p.clientId; client_secret = $p.clientSecret
            redirect_uri = $p.redirectUri
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; error = ("トークンの取得に失敗しました: {0}" -f $_.Exception.Message) }
    }
    # Slack は HTTP 200 で ok:false を返す。握り潰すと「繋がったのに何も取れない」になる。
    if (-not $resp.ok) {
        return [pscustomobject]@{ ok = $false; error = ("Slack が受け付けませんでした: {0}" -f $resp.error) }
    }
    $userToken = [string] $resp.authed_user.access_token
    if (-not $userToken) {
        return [pscustomobject]@{
            ok = $false
            error = 'ユーザートークンが返りませんでした。アプリの User Token Scopes が空になっていないか確認してください。'
        }
    }

    Set-Secret -Name 'slack.clientId'     -Value $p.clientId
    Set-Secret -Name 'slack.clientSecret' -Value $p.clientSecret
    Set-Secret -Name 'slack.userToken'    -Value $userToken
    # 掃き寄せのメンション判定に使う「自分」。同意した本人なので、ここで確定する。
    if ($resp.authed_user.id) { Set-Secret -Name 'slack.selfUserId' -Value ([string] $resp.authed_user.id) }
    $script:PendingSlackAuth = $null
    $script:SlackSelfId = $null

    $check = Test-SetupConnection -Key 'slack'
    if (-not $check.ok) { return [pscustomobject]@{ ok = $false; error = $check.error } }
    Set-SetupAccount -Key 'slack' -Account $check.account
    return [pscustomobject]@{ ok = $true; account = $check.account; note = $check.note }
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

# ---------------------------------------------------------------- デバイスコード (Microsoft)
#
# Google の同意画面と違い、戻り先 (リダイレクト URI) を1つも登録しなくてよい。
# そのかわり「画面にコードを出して、済んだか聞きに行く」形になる。
# カンバンは1本のループで要求を捌くので、**待つのはブラウザ側の仕事**にする。
# サーバ側で待つと画面ごと固まる。

function Start-SetupDeviceCode {
    <#
      .SYNOPSIS
        コードを発行して画面に返す。ここではまだ何も保存しない。
      .OUTPUTS
        [pscustomobject] ok / userCode / verificationUri / interval / error
    #>
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [hashtable] $Values
    )
    $svc = Get-SetupService $Key
    if (-not $svc -or $svc.flow -ne 'device') {
        return [pscustomobject]@{ ok = $false; error = 'このサービスはコードによる接続に対応していません。' }
    }
    if (-not (Get-Command Start-GraphDeviceCode -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ ok = $false; error = 'Microsoft 連携が読み込まれていません。' }
    }
    # 入力が空でも、配る人が用意したアプリ登録があればそれで進む。
    $c = Get-MicrosoftClientCredential -ClientId ([string] $Values['clientId']) `
            -TenantId ([string] $Values['tenantId']) -ClientSecret ([string] $Values['clientSecret'])
    if (-not $c.clientId) { return [pscustomobject]@{ ok = $false; error = 'アプリケーション (クライアント) ID を入力してください。' } }
    return Start-GraphDeviceCode -ClientId $c.clientId -TenantId $c.tenantId -ClientSecret $c.clientSecret
}

function Get-MicrosoftClientCredential {
    <#
      .SYNOPSIS
        デバイスコードに使うアプリ登録を決める。画面の入力 → 保管庫 → 配布設定 の順。
      .DESCRIPTION
        クライアント ID を入力した場合は、テナントとシークレットも**その入力だけ**から取る。
        別のアプリ登録に切り替えた人に、配布時のシークレットを混ぜて送ると
        AADSTS7000215 (シークレットが違う) で落ち、原因が画面から見えない。
      .OUTPUTS
        [pscustomobject] clientId / tenantId / clientSecret
    #>
    param([string] $ClientId, [string] $TenantId, [string] $ClientSecret)
    $cid = ([string] $ClientId).Trim()
    $ten = ([string] $TenantId).Trim()
    $sec = ([string] $ClientSecret).Trim()
    if ($cid) {
        return [pscustomobject]@{ clientId = $cid; tenantId = $ten; clientSecret = $sec }
    }
    $cid = [string] (Get-Secret -Name 'ms.clientId')
    if ($cid) {
        if (-not $ten) { $ten = [string] (Get-Secret -Name 'ms.tenantId') }
        if (-not $sec) { $sec = [string] (Get-Secret -Name 'ms.clientSecret') }
    }
    else {
        $cid = [string] (Get-AppConfigValue -Path 'microsoft.clientId')
        if (-not $ten) { $ten = [string] (Get-AppConfigValue -Path 'microsoft.tenantId') }
        if (-not $sec) { $sec = [string] (Get-AppConfigValue -Path 'microsoft.clientSecret') }
    }
    return [pscustomobject]@{ clientId = $cid; tenantId = $ten; clientSecret = $sec }
}

function Test-SetupDeviceCode {
    <#
      .SYNOPSIS
        同意が済んだかを1回だけ見る。済んでいれば保存まで終わっている。
      .OUTPUTS
        [pscustomobject] state ('pending' | 'ok' | 'error') / account / note / error
    #>
    param([Parameter(Mandatory)] [string] $Key)
    $svc = Get-SetupService $Key
    if (-not $svc -or $svc.flow -ne 'device') {
        return [pscustomobject]@{ state = 'error'; error = 'このサービスはコードによる接続に対応していません。'; account = ''; note = '' }
    }
    if (-not (Get-Command Test-GraphDeviceCode -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ state = 'error'; error = 'Microsoft 連携が読み込まれていません。'; account = ''; note = '' }
    }

    $r = Test-GraphDeviceCode
    if ($r.state -ne 'ok') {
        return [pscustomobject]@{ state = $r.state; error = [string] $r.error; account = ''; note = '' }
    }

    # 保存できていても、実際に叩けるとは限らない (スコープが付かなかった等)。
    # 貼るだけのサービスと同じく、ここで一度確かめてから「接続済み」と言う。
    $check = Test-SetupConnection -Key $svc.key
    if (-not $check.ok) {
        return [pscustomobject]@{ state = 'error'; error = $check.error; account = ''; note = '' }
    }
    Set-SetupAccount -Key $svc.key -Account $check.account
    return [pscustomobject]@{ state = 'ok'; error = ''; account = $check.account; note = [string] $check.note }
}
