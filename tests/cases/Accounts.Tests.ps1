# Accounts.Tests.ps1
# 一つの連携先に複数のアカウントを繋いだときの分離。
#
# ここで留めたいのは「混ざらないこと」である。混ざったときの症状は、
# どれも気付くのが遅い形をしている ――
#   ・2つ目を繋いだのにカードが1枚も増えない (1つ目のトークンで読んでいる)
#   ・別のワークスペースのチャンネル名が付いたカードが立つ (控えの持ち越し)
#   ・返信が別の名義で出る (カードの出自とトークンの取り違え)
#   ・繋いだ瞬間に既存のイベントが消える (主キーの衝突)
# どれも画面の上では成功に見えるので、試験でしか捕まえられない。
#
# ネットワークには出ない。保管庫を一時ファイルに寄せて、名前空間だけを見る。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase5\lib\AccountStore.ps1"
. "$RepoRoot\phase5\lib\SlackConnector.ps1"
. "$RepoRoot\phase5\lib\ServiceSetup.ps1"
. "$RepoRoot\phase4\lib\SourceAccess.ps1"

# --- 資格情報ストアを一時ファイルに差し替える (実データの secrets.dat は触らない) ---
$script:AcctStore = Join-Path (New-TestTempDir) 'secrets.dat'
function Get-SecretStorePath { param([string] $Path) if ($Path) { return $Path } return $script:AcctStore }
function Protect-Text   { param([string] $Text)   return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
function Unprotect-Text { param([string] $Base64) return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64)) }

# 配布設定は見に行かせない (開発機に置いてあると結果が変わる)。
$script:SavedAcctCfgEnv = $env:NOTIFICATION_COLLECTOR_CONFIG
$env:NOTIFICATION_COLLECTOR_CONFIG = Join-Path (New-TestTempDir) 'no-app-config.json'

Describe '名簿' {

    It '名簿が無ければ「1人目だけがいる」(いまの構成がそのまま動く)' {
        $a = @(Get-ServiceAccounts -Service 'slack')
        Assert-Equal 1 $a.Count
        Assert-Equal '1' $a[0].id
    }

    It '1人目の秘密には接尾辞が付かない (既存の保管庫をそのまま読める)' {
        Assert-Equal 'slack.userToken' (Resolve-SecretName -Name 'slack.userToken' -AccountId '1')
        Assert-Equal 'slack.userToken' (Resolve-SecretName -Name 'slack.userToken')
    }

    It '2人目からは名前空間が分かれる' {
        Assert-Equal 'slack.userToken#2' (Resolve-SecretName -Name 'slack.userToken' -AccountId '2')
        Assert-Equal 'gmail.refreshToken#3' (Resolve-SecretName -Name 'gmail.refreshToken' -AccountId '3')
    }

    It '足すと番号が増える。消した番号は使い回さない' {
        $two = Add-ServiceAccount -Service 'slack' -Label '個人'
        Assert-Equal '2' $two.id
        $three = Add-ServiceAccount -Service 'slack'
        Assert-Equal '3' $three.id
        # 2 を消しても、次は 4 になる。番号を使い回すと、消し損ねた秘密や
        # そのアカウントで取り込んだイベントが「別人のもの」として蘇る。
        [void] (Remove-ServiceAccount -Service 'slack' -Id '2' -SecretNames @('slack.userToken'))
        $next = Add-ServiceAccount -Service 'slack'
        Assert-Equal '4' $next.id
        [void] (Remove-ServiceAccount -Service 'slack' -Id '3' -SecretNames @())
        [void] (Remove-ServiceAccount -Service 'slack' -Id '4' -SecretNames @())
    }

    It '呼び名を付け替えられる' {
        $a = Add-ServiceAccount -Service 'chatwork' -Label '旧'
        Assert-True (Set-ServiceAccountLabel -Service 'chatwork' -Id $a.id -Label '新')
        Assert-Equal '新' (Get-ServiceAccount -Service 'chatwork' -Id $a.id).label
        [void] (Remove-ServiceAccount -Service 'chatwork' -Id $a.id -SecretNames @())
    }
}

Describe '資格情報の分離' {

    It '切り替えると別のトークンになる' {
        Set-Secret -Name 'slack.userToken' -Value 'xoxp-one'
        [void] (Add-ServiceAccount -Service 'slack' -Label '個人')   # id 2 ではなく続き番号
        $second = @(Get-ServiceAccounts -Service 'slack') | Select-Object -Last 1

        [void] (Use-ServiceAccount -Service 'slack' -Id $second.id)
        Assert-Null (Get-Secret -Name 'slack.userToken')
        Set-Secret -Name 'slack.userToken' -Value 'xoxp-two'
        Assert-Equal 'xoxp-two' (Get-SlackToken)

        [void] (Use-ServiceAccount -Service 'slack' -Id '1')
        Assert-Equal 'xoxp-one' (Get-SlackToken)
        # 名指しすれば、切り替えずに相手の分も読める (設定画面が一覧を出すのに要る)
        Assert-Equal 'xoxp-two' (Get-Secret -Name 'slack.userToken' -AccountId $second.id)
    }

    It 'アプリ登録はアカウントで分かれない (配る人が用意した1組を使い回す)' {
        # ここを分けると、2つ目を繋ぐときに「配布時に設定済み」が効かなくなり、
        # 利用者の手では取れない値を空欄として出すことになる。
        Set-Secret -Name 'slack.clientId' -Value 'APP-1'
        $second = @(Get-ServiceAccounts -Service 'slack') | Select-Object -Last 1
        [void] (Use-ServiceAccount -Service 'slack' -Id $second.id)
        Assert-Equal 'APP-1' (Get-Secret -Name 'slack.clientId')
        [void] (Use-ServiceAccount -Service 'slack' -Id '1')
    }

    It 'テナントとスペースはアカウントで分かれる (アカウントごとに違う値なので)' {
        Assert-Equal 'ms.tenantId#2'   (Resolve-SecretName -Name 'ms.tenantId' -AccountId '2')
        Assert-Equal 'backlog.space#2' (Resolve-SecretName -Name 'backlog.space' -AccountId '2')
        Assert-Equal 'ms.clientId'     (Resolve-SecretName -Name 'ms.clientId' -AccountId '2')
    }

    It '切り替えるとコネクタの控えが落ちる (別ワークスペースの名前を持ち越さない)' {
        $script:SlackSelfId = 'U-OLD'
        $script:SlackChannelCache = @{ C1 = '#前のワークスペースの部屋' }
        $second = @(Get-ServiceAccounts -Service 'slack') | Select-Object -Last 1
        [void] (Use-ServiceAccount -Service 'slack' -Id $second.id)
        Assert-Null $script:SlackSelfId
        Assert-Equal 0 $script:SlackChannelCache.Count
        [void] (Use-ServiceAccount -Service 'slack' -Id '1')
    }

    It '枠を消すとそのアカウントの秘密も消える (使わない鍵を残さない)' {
        $second = @(Get-ServiceAccounts -Service 'slack') | Select-Object -Last 1
        Set-Secret -Name 'slack.selfUserId' -Value 'U2' -AccountId $second.id
        Assert-True ((Get-SecretNames) -contains ('slack.userToken#' + $second.id))
        [void] (Remove-ServiceAccount -Service 'slack' -Id $second.id `
                    -SecretNames @('slack.userToken', 'slack.selfUserId'))
        Assert-False ((Get-SecretNames) -contains ('slack.userToken#' + $second.id))
        Assert-False ((Get-SecretNames) -contains ('slack.selfUserId#' + $second.id))
        # 1人目と共有の値は残る
        Assert-Equal 'xoxp-one' (Get-Secret -Name 'slack.userToken')
        Assert-Equal 'APP-1' (Get-Secret -Name 'slack.clientId')
    }

    It '消したアカウントが選ばれたままにならない' {
        $x = Add-ServiceAccount -Service 'backlog'
        [void] (Use-ServiceAccount -Service 'backlog' -Id $x.id)
        [void] (Remove-ServiceAccount -Service 'backlog' -Id $x.id -SecretNames @())
        Assert-Equal '1' (Get-CurrentAccountId 'backlog')
    }
}

Describe 'watermark とイベントの主キー' {

    It 'watermark は1人目だけ今までのキーのまま (巻き戻して取り直さない)' {
        Assert-Equal 'sync.slack.lastTs'   (Get-AccountScopedKey -Key 'sync.slack.lastTs' -AccountId '1')
        Assert-Equal 'sync.slack.lastTs'   (Get-AccountScopedKey -Key 'sync.slack.lastTs')
        Assert-Equal 'sync.slack.lastTs#2' (Get-AccountScopedKey -Key 'sync.slack.lastTs' -AccountId '2')
    }

    It 'イベントの主キーも1人目はそのまま、2人目からアカウントが付く' {
        # Backlog のお知らせ ID はスペース内の連番なので、付けないと
        # 二つ目のスペースを繋いだ瞬間に UNIQUE(source, source_key) で弾かれ、
        # 「繋いだのに何も入らない」になる。
        Assert-Equal '1234'   (ConvertTo-AccountSourceKey -SourceKey '1234' -AccountId '1')
        Assert-Equal '1234'   (ConvertTo-AccountSourceKey -SourceKey '1234')
        Assert-Equal '2|1234' (ConvertTo-AccountSourceKey -SourceKey '1234' -AccountId '2')
    }

    It 'イベントのアカウントは、空なら1人目' {
        Assert-Equal '1' (Get-EventAccountId @{ source = 'backlog' })
        Assert-Equal '1' (Get-EventAccountId @{ source = 'backlog'; account_id = '' })
        Assert-Equal '3' (Get-EventAccountId @{ source = 'backlog'; account_id = '3' })
        Assert-Equal '1' (Get-EventAccountId $null)
    }
}

Describe 'カードの出自に束縛する' {

    It 'source から連携先が決まる (Teams と Outlook は同じアプリ登録なので microsoft)' {
        Assert-Equal 'google'    (Get-AccountServiceForSource 'gmail')
        Assert-Equal 'microsoft' (Get-AccountServiceForSource 'outlook')
        Assert-Equal 'microsoft' (Get-AccountServiceForSource 'teams')
        Assert-Equal 'slack'     (Get-AccountServiceForSource 'slack')
        # トーストはどのアカウント宛かを決められない。持たせない。
        Assert-Equal '' (Get-AccountServiceForSource 'notification')
        Assert-Equal '' (Get-AccountServiceForSource '')
    }

    It 'カードのアカウントで以降の呼び出しが固定される' {
        $second = Add-ServiceAccount -Service 'google'
        Set-Secret -Name 'gmail.refreshToken' -Value 'rt-one'
        Set-Secret -Name 'gmail.refreshToken' -Value 'rt-two' -AccountId $second.id

        $bound = Use-EventAccount -Evt @{ source = 'gmail'; link = ''; account_id = $second.id }
        Assert-Equal 'google' $bound
        Assert-Equal 'rt-two' (Get-Secret -Name 'gmail.refreshToken')

        [void] (Use-EventAccount -Evt @{ source = 'gmail'; link = ''; account_id = '' })
        Assert-Equal 'rt-one' (Get-Secret -Name 'gmail.refreshToken')
        [void] (Remove-ServiceAccount -Service 'google' -Id $second.id -SecretNames @('gmail.refreshToken'))
    }

    It 'アカウントを持たない経路では何も切り替えない' {
        Assert-Equal '' (Use-EventAccount -Evt @{ source = 'notification'; link = '' })
        Assert-Equal '' (Use-EventAccount -Evt $null)
    }

    It 'source が無くてもリンクから決まる (この列より前に入ったイベント)' {
        Assert-Equal 'slack'     (Use-EventAccount -Evt @{ source = ''; link = 'slack://channel?id=C1' })
        Assert-Equal 'microsoft' (Use-EventAccount -Evt @{ source = ''; link = 'msteams://chat?id=19:x' })
    }
}

Describe '呼び名と持ち越し' {

    It '1つしか繋いでいなければ名乗らない (意味の無い装飾を出さない)' {
        Assert-Equal '' (Get-AccountDisplayName -Service 'microsoft' -Id '1')
    }

    It '2つ以上あれば、呼び名 → 繋がった相手 → 通し番号 の順で名乗る' {
        $b = Add-ServiceAccount -Service 'microsoft' -Label '取引先テナント'
        Assert-Equal '取引先テナント' (Get-AccountDisplayName -Service 'microsoft' -Id $b.id)
        # 呼び名が無ければ、繋がった相手の名前
        Set-Secret -Name 'account.microsoft' -Value 'me@example.com' -AccountId '1'
        Assert-Equal 'me@example.com' (Get-AccountDisplayName -Service 'microsoft' -Id '1')
        # どちらも無ければ通し番号
        $c = Add-ServiceAccount -Service 'microsoft'
        Assert-Equal ('アカウント ' + $c.id) (Get-AccountDisplayName -Service 'microsoft' -Id $c.id)
        [void] (Remove-ServiceAccount -Service 'microsoft' -Id $c.id -SecretNames @())
        [void] (Remove-ServiceAccount -Service 'microsoft' -Id $b.id -SecretNames @())
    }

    It '名義はカードのアカウント1つ、本人の判定は全アカウント' {
        # 名義を取り違えると他人の名前で返信する。全アカウントを見落とすと、
        # 別のアカウント宛に届いた本人宛のメールを「宛先は他人」と読む。
        # 片方だけでは足りないので、単数と複数の両方を持っている。
        $b = Add-ServiceAccount -Service 'google' -Label '個人用'
        Set-Secret -Name 'account.google' -Value 'work@example.com' -AccountId '1'
        Set-Secret -Name 'account.google' -Value 'me@personal.example' -AccountId $b.id

        Assert-Equal 'work@example.com'    (Get-SelfAccountName -Service 'google' -Id '1')
        Assert-Equal 'me@personal.example' (Get-SelfAccountName -Service 'google' -Id $b.id)

        $all = @(Get-SelfAccountNames -Service 'google')
        Assert-Equal 2 $all.Count
        Assert-True ($all -contains 'work@example.com')
        Assert-True ($all -contains 'me@personal.example')

        [void] (Remove-ServiceAccount -Service 'google' -Id $b.id -SecretNames @())
    }

    It '疎通確認より前のアカウントは名前が無い。並べるときは飛ばす' {
        $b = Add-ServiceAccount -Service 'backlog'
        Set-Secret -Name 'account.backlog' -Value 'example / 私' -AccountId '1'
        $all = @(Get-SelfAccountNames -Service 'backlog')
        Assert-Equal 1 $all.Count
        Assert-Equal 'example / 私' $all[0]
        [void] (Remove-ServiceAccount -Service 'backlog' -Id $b.id -SecretNames @())
    }

    It '選択を1人目に戻せる (要求をまたぐカンバンで、前のカードの相手を持ち越さない)' {
        $b = Add-ServiceAccount -Service 'chatwork'
        [void] (Use-ServiceAccount -Service 'chatwork' -Id $b.id)
        [void] (Use-ServiceAccount -Service 'slack' -Id '1')
        Assert-Equal $b.id (Get-CurrentAccountId 'chatwork')
        Reset-AccountSelection
        Assert-Equal '1' (Get-CurrentAccountId 'chatwork')
        Assert-Equal '1' (Get-CurrentAccountId 'slack')
        [void] (Remove-ServiceAccount -Service 'chatwork' -Id $b.id -SecretNames @())
    }
}

Describe '設定画面から見たアカウント' {

    It '複数を繋げる連携先と、繋げない連携先がある' {
        Assert-True  (Test-SetupMultiAccount 'slack')
        Assert-True  (Test-SetupMultiAccount 'google')
        Assert-True  (Test-SetupMultiAccount 'microsoft')
        Assert-True  (Test-SetupMultiAccount 'chatwork')
        Assert-True  (Test-SetupMultiAccount 'backlog')
        # Claude はエンジンで、複数繋いでもさばける通知は増えない。
        Assert-False (Test-SetupMultiAccount 'anthropic')
        # GitHub はカードの出自にならないので、どちらのアカウントか決められない。
        Assert-False (Test-SetupMultiAccount 'github')
    }

    It '繋げない連携先にアカウントは足せない' {
        Assert-Throws { Add-SetupAccount -Key 'anthropic' }
        Assert-Throws { Add-SetupAccount -Key 'github' }
    }

    It '繋げない連携先でも一覧は1件返る (画面の経路を1本にしておく)' {
        $a = @(Get-SetupAccounts -Key 'anthropic')
        Assert-Equal 1 $a.Count
        Assert-Equal '1' $a[0].id
    }

    It '1つでも繋がっていれば「接続済み」。名指しすればその枠だけを見る' {
        $second = Add-SetupAccount -Key 'chatwork' -Label '別会社'
        Set-Secret -Name 'chatwork.token' -Value 'tok-one'
        Assert-True  (Test-SetupConfigured -Key 'chatwork')
        Assert-True  (Test-SetupConfigured -Key 'chatwork' -AccountId '1')
        Assert-False (Test-SetupConfigured -Key 'chatwork' -AccountId $second.id)

        Set-Secret -Name 'chatwork.token' -Value 'tok-two' -AccountId $second.id
        Assert-True (Test-SetupConfigured -Key 'chatwork' -AccountId $second.id)
    }

    It '状態一覧はアカウントごとに出る。トークンそのものは出さない' {
        $s = @(Get-SetupStatusList | Where-Object { $_.key -eq 'chatwork' })[0]
        Assert-True $s.multi
        Assert-Equal 2 @($s.accounts).Count
        Assert-True $s.accounts[0].configured
        Assert-True $s.accounts[1].configured
        $json = $s | ConvertTo-Json -Depth 8
        Assert-True ($json -notmatch 'tok-one') 'トークンが画面に出ています'
        Assert-True ($json -notmatch 'tok-two') 'トークンが画面に出ています'
    }

    It '切断は資格情報だけ消す (枠は残るので繋ぎ直せる)' {
        $second = @(Get-SetupAccounts -Key 'chatwork') | Select-Object -Last 1
        [void] (Clear-SetupCredential -Key 'chatwork' -AccountId $second.id)
        Assert-False (Test-SetupConfigured -Key 'chatwork' -AccountId $second.id)
        Assert-Equal 2 @(Get-SetupAccounts -Key 'chatwork').Count
        # 1人目は無事
        Assert-True (Test-SetupConfigured -Key 'chatwork' -AccountId '1')
    }

    It '最後の1つは枠ごと外せない (繋ぎ直す入口が無くなるため)' {
        $second = @(Get-SetupAccounts -Key 'chatwork') | Select-Object -Last 1
        Assert-True (Remove-SetupAccount -Key 'chatwork' -AccountId $second.id)
        Assert-Equal 1 @(Get-SetupAccounts -Key 'chatwork').Count
        Assert-Throws { Remove-SetupAccount -Key 'chatwork' -AccountId '1' }
    }

    It 'すでに繋いである相手にもう一度繋ぐと知らせる' {
        # 同意画面はブラウザのセッションをそのまま使うので、2つ目を繋いだつもりで
        # 1つ目をもう一度繋げてしまう。画面上は成功するのにカードは増えない。
        $second = Add-SetupAccount -Key 'backlog' -Label '二つ目'
        Set-SetupAccount -Key 'backlog' -Account 'example.backlog.jp / 私' -AccountId '1'
        $note = Get-SetupDuplicateNote -Key 'backlog' -AccountId $second.id -Account 'example.backlog.jp / 私'
        Assert-Match 'すでに繋いである' $note
        # 違う相手なら黙っている
        Assert-Equal '' (Get-SetupDuplicateNote -Key 'backlog' -AccountId $second.id -Account 'other.backlog.jp / 私')
        [void] (Remove-SetupAccount -Key 'backlog' -AccountId $second.id)
    }

    It 'Google の同意画面はアカウントを選び直させる (2つ目を繋ぐのに要る)' {
        $r = Get-GoogleAuthRequest -ClientId 'cid' -ClientSecret 'sec' `
                -RedirectUri 'http://127.0.0.1:8787/oauth/google/callback' -AccountId '2'
        Assert-Match 'select_account' $r.url
        Assert-Match 'prompt=consent' ([Uri]::UnescapeDataString($r.url))
    }
}

# 選択とストアの差し替えを次のケースに持ち越さない。
foreach ($k in @('slack', 'google', 'microsoft', 'chatwork', 'backlog', 'github')) {
    [void] (Use-ServiceAccount -Service $k -Id (Get-PrimaryAccountId))
}
$env:NOTIFICATION_COLLECTOR_CONFIG = $script:SavedAcctCfgEnv
