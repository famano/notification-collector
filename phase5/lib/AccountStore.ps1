# AccountStore.ps1
# 「一つの連携先に複数のアカウントがある」を扱う層。
#
# なぜ要るか:
#   仕事用と個人用の Gmail、二つのワークスペースの Slack、二つの Backlog スペース。
#   どれも「片方だけ繋ぐ」では用が足りない ―― さばききれなかった通知は、
#   このアプリを使っていない状態と同じところに戻る。
#
#   資格情報そのものの分離は SecretStore.ps1 が名前空間でやる。ここが持つのは
#   **「そもそも何人いるか」という名簿**である。同期はこれを回して全アカウントを
#   掃き寄せ、設定画面はこれを並べ、カードはこれで出自を名乗る。
#
# 1人目 (ID '1') は特別扱いする:
#   既存の保管庫は接尾辞の無い名前で1人分の資格情報を持っている。それをそのまま
#   1人目として読めるようにしてあるので、**入れ替え作業が一度も要らない。**
#   名簿が無いときは「1人目だけがいる」と見なす。これが今まで動いていた形である。
#
# 扱わないもの:
#   資格情報の読み書きはここではしない (SecretStore の仕事)。
#   ここが返すのは ID とラベルだけで、トークンには触れない。

. "$PSScriptRoot\SecretStore.ps1"

# 名簿の置き場。保管庫に JSON 配列で入れる。
#   accounts.slack = [ {"id":"1","label":"仕事"}, {"id":"2","label":"個人"} ]
# 資格情報ではないが、資格情報と同じ寿命で消えてほしいので同じ箱に置く
# (保管庫を消したのに名簿だけ残ると、中身の無いアカウントが画面に並ぶ)。
function Get-AccountRegistryName {
    param([Parameter(Mandatory)] [string] $Service)
    return ("accounts.{0}" -f $Service)
}

function ConvertTo-AccountEntry {
    param($Raw, [Parameter(Mandatory)] [string] $Id)
    $label = ''
    if ($Raw -and $Raw.PSObject.Properties['label']) { $label = [string] $Raw.label }
    return [pscustomobject]@{ id = [string] $Id; label = $label }
}

function Get-ServiceAccounts {
    <#
      .SYNOPSIS
        その連携先に登録されているアカウント。必ず順序が安定する。
      .DESCRIPTION
        名簿が無ければ「1人目だけがいる」を返す。**ここが空配列を返すと同期が
        一度も回らない**ので、「まだ誰も追加していない」と「全部消した」は区別する。
        前者は名簿そのものが無い状態で、後者は空の名簿が保存されている状態。
      .OUTPUTS
        [pscustomobject[]] id / label
    #>
    param([Parameter(Mandatory)] [string] $Service, [string] $Path)
    $raw = Get-Secret -Name (Get-AccountRegistryName $Service) -Path $Path
    if (-not $raw) {
        return @([pscustomobject]@{ id = (Get-PrimaryAccountId); label = '' })
    }
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
    if ($null -eq $parsed) {
        # 壊れていても名簿ごと失わない。1人目に戻したほうが、空にするより実害が小さい。
        return @([pscustomobject]@{ id = (Get-PrimaryAccountId); label = '' })
    }
    $out = @()
    foreach ($e in @($parsed)) {
        if (-not $e) { continue }
        $id = ''
        if ($e.PSObject.Properties['id']) { $id = [string] $e.id }
        if (-not $id) { continue }
        $out += (ConvertTo-AccountEntry -Raw $e -Id $id)
    }
    return @($out)
}

function Write-ServiceAccounts {
    param([Parameter(Mandatory)] [string] $Service, [Parameter(Mandatory)] [AllowEmptyCollection()] [array] $Accounts, [string] $Path)
    $items = @($Accounts | ForEach-Object { [pscustomobject]@{ id = [string] $_.id; label = [string] $_.label } })
    # PowerShell 5.1 の ConvertTo-Json は 1件の配列をオブジェクトとして出す。
    # 読む側は @() で均すのでどちらでも通るが、名簿が配列であることは
    # 保存された中身を見ただけで分かるようにしておく。
    $json = switch ($items.Count) {
        0       { '[]' }
        1       { '[' + (ConvertTo-Json -InputObject $items[0] -Depth 4 -Compress) + ']' }
        default { ConvertTo-Json -InputObject $items -Depth 4 -Compress }
    }
    Set-Secret -Name (Get-AccountRegistryName $Service) -Value $json -Path $Path
}

function Get-ServiceAccount {
    param([Parameter(Mandatory)] [string] $Service, [string] $Id, [string] $Path)
    if (-not $Id) { $Id = Get-PrimaryAccountId }
    foreach ($a in (Get-ServiceAccounts -Service $Service -Path $Path)) {
        if ($a.id -eq [string] $Id) { return $a }
    }
    return $null
}

function Test-ServiceAccountId {
    param([Parameter(Mandatory)] [string] $Service, [string] $Id, [string] $Path)
    return [bool] (Get-ServiceAccount -Service $Service -Id $Id -Path $Path)
}

function Add-ServiceAccount {
    <#
      .SYNOPSIS
        空のアカウントを1つ足す。資格情報はこのあと設定画面が入れる。
      .DESCRIPTION
        ID は使い回さない。消したアカウントの番号を次の人に与えると、
        消し損ねた秘密や、そのアカウントで取り込んだイベントが**別人のものとして**
        蘇る。番号は常に「今までで一番大きい数 + 1」にする。
      .OUTPUTS
        [pscustomobject] id / label
    #>
    param([Parameter(Mandatory)] [string] $Service, [string] $Label, [string] $Path)
    $cur = @(Get-ServiceAccounts -Service $Service -Path $Path)
    $max = 0
    foreach ($a in $cur) {
        $n = 0
        if ([int]::TryParse([string] $a.id, [ref] $n) -and $n -gt $max) { $max = $n }
    }
    $new = [pscustomobject]@{ id = [string] ($max + 1); label = [string] $Label }
    Write-ServiceAccounts -Service $Service -Accounts @($cur + $new) -Path $Path
    return $new
}

function Set-ServiceAccountLabel {
    param(
        [Parameter(Mandatory)] [string] $Service,
        [Parameter(Mandatory)] [string] $Id,
        [string] $Label,
        [string] $Path
    )
    $cur = @(Get-ServiceAccounts -Service $Service -Path $Path)
    $hit = $false
    $out = @($cur | ForEach-Object {
        if ($_.id -eq $Id) { $hit = $true; [pscustomobject]@{ id = $_.id; label = [string] $Label } }
        else { $_ }
    })
    if (-not $hit) { return $false }
    Write-ServiceAccounts -Service $Service -Accounts $out -Path $Path
    return $true
}

function Remove-ServiceAccount {
    <#
      .SYNOPSIS
        名簿から1人消し、そのアカウントの秘密も消す。
      .PARAMETER SecretNames
        そのサービスが使う秘密の名前 (接尾辞の無い形)。呼び出し側 (ServiceSetup) が
        何を使っているかを知っているので、ここでは渡してもらう。
      .DESCRIPTION
        名簿だけ消すと、秘密は保管庫に残り続ける。**トークンはメールボックスや
        会話の全履歴への鍵そのもの**なので、使わなくなった時点で消す。
    #>
    param(
        [Parameter(Mandatory)] [string] $Service,
        [Parameter(Mandatory)] [string] $Id,
        [string[]] $SecretNames = @(),
        [string] $Path
    )
    $cur = @(Get-ServiceAccounts -Service $Service -Path $Path)
    $rest = @($cur | Where-Object { $_.id -ne $Id })
    if ($rest.Count -eq $cur.Count) { return $false }

    foreach ($n in $SecretNames) {
        [void] (Remove-Secret -Name $n -AccountId $Id -Path $Path)
    }
    # 「どのアカウントとして繋がったか」の表示名も一緒に消す。
    [void] (Remove-Secret -Name ("account.{0}" -f $Service) -AccountId $Id -Path $Path)

    Write-ServiceAccounts -Service $Service -Accounts $rest -Path $Path
    # 消した相手が選ばれたままだと、次の Get-Secret が存在しない名前空間を読む。
    if ((Get-CurrentAccountId $Service) -eq $Id) {
        $fallback = if ($rest.Count -gt 0) { $rest[0].id } else { Get-PrimaryAccountId }
        [void] (Use-ServiceAccount -Service $Service -Id $fallback)
    }
    return $true
}

# ---------------------------------------------------------------- 名前

function Get-AccountDisplayName {
    <#
      .SYNOPSIS
        画面とログに出す名前。利用者が付けたラベル → 繋がったアカウント名 → 通し番号。
      .DESCRIPTION
        1人しかいないときは空を返す。「Slack[1]」のような表示は、
        複数繋いでいない人にとっては意味の無い装飾でしかない。
    #>
    param([Parameter(Mandatory)] [string] $Service, [string] $Id, [string] $Path)
    if (-not $Id) { $Id = Get-PrimaryAccountId }
    if ((@(Get-ServiceAccounts -Service $Service -Path $Path)).Count -le 1) { return '' }
    $a = Get-ServiceAccount -Service $Service -Id $Id -Path $Path
    if ($a -and $a.label) { return [string] $a.label }
    $who = Get-Secret -Name ("account.{0}" -f $Service) -AccountId $Id -Path $Path
    if ($who) { return [string] $who }
    return ("アカウント {0}" -f $Id)
}

function Get-SelfAccountName {
    <#
      .SYNOPSIS
        そのアカウントで「自分が誰として繋がっているか」。メールならアドレスが入る。
      .DESCRIPTION
        疎通確認が通ったときに保存した名前 (account.<連携先>) をそのまま返す。
        ここでネットワークには出ない ―― カード1枚ごとに /me を叩くのは重すぎるし、
        繋がっていない時間に「自分が誰か」を見失うのは困る。

        これが要るのは**名義**のため。To: 他人 / Cc: 自分 で来たメールで、
        ワーカーがその他人の名義で返信を書いてしまうことがあった。本人が誰かを
        モデルに推測させず、繋いだアカウントから決めて渡すために使う
        (組み立ては phase4\lib\Viewer.ps1)。
        返すのは**このアカウント1つ**の名前で、それが名義になる。
        「本人かどうか」の判定には足りない ―― 本人は複数のアカウントを
        繋いでいることがあるので、そちらは Get-SelfAccountNames (複数) を使う。
      .OUTPUTS
        [string] 空のことがある (疎通確認より前に繋いだアカウント)
    #>
    param([Parameter(Mandatory)] [string] $Service, [string] $Id, [string] $Path)
    if (-not $Id) { $Id = Get-CurrentAccountId $Service }
    return [string] (Get-Secret -Name ("account.{0}" -f $Service) -AccountId $Id -Path $Path)
}

function Get-SelfAccountNames {
    <#
      .SYNOPSIS
        その連携先に繋いである**全アカウント**の名前。メールならアドレスが並ぶ。
      .DESCRIPTION
        名義は1つに決まるが (カードが届いたアカウント)、**本人は1人**である。
        仕事用と個人用の Gmail を両方繋いでいると、片方宛のメールがもう片方の
        受信箱にも届く (両方が宛先、転送、メーリングリスト)。そのときに
        このカードのアカウントのアドレスだけで「自分かどうか」を見ると、
        **本人宛なのに「宛先は他人」と読む** ―― 症状は「自分宛のメールなのに
        横で見ているだけの扱いになり、返さなくなる」で、静かに効く。

        立場 (宛先か Cc か) の判定にはこちらを使う。名義そのものは
        Get-SelfAccountName (単数) が返すカードのアカウントのままにする。
      .OUTPUTS
        [string[]] 空のことがある (疎通確認より前に繋いだアカウントだけの場合)
    #>
    param([Parameter(Mandatory)] [string] $Service, [string] $Path)
    $out = @()
    foreach ($a in @(Get-ServiceAccounts -Service $Service -Path $Path)) {
        $n = [string] (Get-Secret -Name ("account.{0}" -f $Service) -AccountId ([string] $a.id) -Path $Path)
        if ($n -and ($out -notcontains $n)) { $out += $n }
    }
    return @($out)
}

# ---------------------------------------------------------------- 経路との対応

# イベントの source → どの連携先のアカウントで取り直すか。
# Teams と Outlook は同じアプリ登録なので、同じ 'microsoft' に寄せる。
$script:AccountServiceOfSource = @{
    gmail = 'google'; outlook = 'microsoft'; teams = 'microsoft'
    slack = 'slack';  chatwork = 'chatwork'; backlog = 'backlog'
}

function Get-AccountServiceForSource {
    <#
      .SYNOPSIS
        イベントの source から連携先を決める。アカウントを持たない経路なら空。
      .DESCRIPTION
        'notification' (Windows のトースト) はここに入らない。どのアカウント宛かを
        通知からは決められないためで、そういうものは 1人目の資格情報で扱う。
    #>
    param([string] $Source)
    if (-not $Source) { return '' }
    $k = $Source.ToLowerInvariant()
    if ($script:AccountServiceOfSource.ContainsKey($k)) { return $script:AccountServiceOfSource[$k] }
    return ''
}

# ---------------------------------------------------------------- どのアカウントで取り直すか
#
# source と link だけでは、**どのアカウントの資格情報で叩くか**が決まらない。
# 仕事用と個人用の Gmail を両方繋いでいれば、同じ 'gmail' でもメールボックスは別で、
# 取り違えれば「あるはずのメールが無い」か、最悪、別のメールボックスの本文を
# カードに載せることになる。ワーカーは1枚のカードを処理する前にここで束縛する。

function Use-EventAccount {
    <#
      .SYNOPSIS
        以降の連携先呼び出しを、このカードの出自のアカウントに固定する。
      .OUTPUTS
        [string] 束縛した連携先 (アカウントを持たない経路なら空)
    #>
    param([Parameter(Mandatory)] [AllowNull()] $Evt)
    if (-not $Evt) { return '' }

    $svc = Get-AccountServiceForSource ([string] $Evt['source'])
    if (-not $svc) {
        # source が付く前に入ったイベントは link だけが手がかりになる。
        $link = [string] $Evt['link']
        if ($link -like 'slack://*')        { $svc = 'slack' }
        elseif ($link -like 'msteams://*')  { $svc = 'microsoft' }
    }
    # 通知 (トースト) や手で起票したカードはここに来る。どのアカウント宛かを
    # 決める手がかりが無いので、1人目のまま扱う。
    if (-not $svc) { return '' }

    $id = [string] $Evt['account_id']
    if (-not $id) { $id = Get-PrimaryAccountId }
    [void] (Use-ServiceAccount -Service $svc -Id $id)
    return $svc
}

function Reset-AccountSelection {
    <#
      .SYNOPSIS
        選んであるアカウントを全部1人目に戻す。
      .DESCRIPTION
        カンバンのように**要求をまたいで生き続けるプロセス**で要る。
        1枚のカードを見るために切り替えた選択がそのまま残ると、次に来た
        無関係な要求がその相手の資格情報で動く。1件ごとに独立させる。
        ワーカーと同期は「1枚 / 1アカウントを通し切る」形なので、こちらは呼ばない。
    #>
    foreach ($k in @($script:CurrentAccountId.Keys)) {
        [void] (Use-ServiceAccount -Service $k -Id (Get-PrimaryAccountId))
    }
}

function Get-AccountScopedKey {
    <#
      .SYNOPSIS
        アカウントごとに分けたい設定キー (watermark) の名前。
      .DESCRIPTION
        秘密の名前と同じ付け方にする ('sync.slack.lastTs#2')。1人目はそのままなので、
        いま動いている環境の watermark が続きから読まれる ―― ここが変わると、
        次の同期が既定の 24 時間まで巻き戻って大量のカードを立てる。
    #>
    param([Parameter(Mandatory)] [string] $Key, [string] $AccountId)
    if (-not $AccountId -or $AccountId -eq (Get-PrimaryAccountId)) { return $Key }
    return ("{0}#{1}" -f $Key, $AccountId)
}
