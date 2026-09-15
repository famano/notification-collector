# Viewer.ps1
# 「このカードで、あなたは誰か」を決める。
#
# なぜ要るか:
#   To: 他人 / Cc: 自分 で届いたメールのカードで、ワーカーが**その他人の名義で**
#   返信を下書きしていた。読み手から見れば、頼んでもいない人が本人を名乗って
#   返事をしてきたことになる ―― 送る前に承認画面で止まるとはいえ、
#   カードに載る文面としては最初から間違っている。
#
#   原因は単純で、モデルに渡していたのはスレッド全文だけだったこと。
#   「誰の代わりに書いているのか」はどこにも書いておらず、本文の中で
#   一番はっきり「返事をする人」に見えるのは To: の人である。
#   何も言われなければそちらに寄るのが自然な読み方になってしまう。
#
#   このアプリは他の箇所でも、守らせたい性質は指示ではなく構造で担保している
#   (投稿先を束縛する、出自を先に取り直す)。名義も同じにする ――
#   本人が誰かは**繋いだアカウントから決まる**ので、モデルに推測させない。
#
# 名義は1つだが、本人は1人:
#   名義 (誰の名前で書くか) はカードが届いたアカウントで決まる。返信もそこから出る。
#   一方「そのメールの宛先が本人か」は、**繋いである全アカウント**で見る必要がある ――
#   仕事用と個人用の Gmail を両方繋いでいると、片方宛のメールがもう片方の受信箱にも
#   届く (両方が宛先、転送、メーリングリスト)。カードのアカウントのアドレスだけで
#   見ると、本人宛なのに「宛先は他人」と読み、横で見ているだけの扱いにしてしまう。
#
# 立場 (role) で既定の振る舞いが変わる:
#   to    … 宛先は自分。返信は自分の名義で書く (これまでどおり)
#   cc    … 返事を求められているのは自分ではない。既定は眺めるだけ。
#           必要なら**自分の名義で**横から入る (他人の名義で書くことは無い)
#   from  … 自分が出したメールの続き。相手の返答を待っている側
#   other … 宛先に自分が出てこない (メーリングリスト等)。cc と同じ扱いにする
#
# ここにはネットワークも資格情報も出てこない。ヘッダの文字列と、
# 繋いだアカウントの名前だけで決まるようにしてある (試験しやすさのため)。

# ---------------------------------------------------------------- アドレス

function Get-MailAddresses {
    <#
      .SYNOPSIS
        To / Cc / From ヘッダからメールアドレスだけを取り出す (小文字)。
      .DESCRIPTION
        「山田 <a@example.com>, b@example.com」のような並びを崩さずに分ける。
        表示名にカンマが入ることがある ("Yamada, Taro" <a@example.com>) ので、
        単純な Split(',') はしない。引用符の外側だけで区切る。
    #>
    param([string] $Header)
    if (-not $Header) { return @() }

    $parts = New-Object System.Collections.ArrayList
    $buf = ''
    $inQuote = $false
    foreach ($ch in $Header.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote; $buf += $ch; continue }
        if ($ch -eq ',' -and -not $inQuote) { [void] $parts.Add($buf); $buf = ''; continue }
        $buf += $ch
    }
    [void] $parts.Add($buf)

    $out = New-Object System.Collections.ArrayList
    foreach ($p in $parts) {
        $v = [string] $p
        if ($v -match '<([^>]+)>') { $v = $Matches[1] }
        $v = $v.Trim().Trim('"', "'", '<', '>').ToLowerInvariant()
        # 表示名だけの断片 (アドレスが無い) は捨てる。
        if ($v -notmatch '^[^@\s]+@[^@\s]+$') { continue }
        if (-not $out.Contains($v)) { [void] $out.Add($v) }
    }
    return @($out)
}

function Get-MatchedSelfAddress {
    <#
      .SYNOPSIS
        そのヘッダに入っている本人のアドレス。無ければ空。
      .PARAMETER Self
        本人のアドレス (複数可)。エイリアスも、**繋いである別のアカウント**も入る。
      .DESCRIPTION
        どれで当たったかまで返す。当たったのがこのカードのアカウント以外だった場合、
        「本人宛ではあるが、返信は別のアドレスから出る」という状態になるので、
        それを後段で伝えられるようにしておく。
    #>
    param([string] $Header, [string[]] $Self)
    if (-not $Self -or @($Self).Count -eq 0) { return '' }
    $list = @(Get-MailAddresses $Header)
    if ($list.Count -eq 0) { return '' }
    foreach ($s in @($Self)) {
        $v = ([string] $s).Trim().ToLowerInvariant()
        if (-not $v) { continue }
        if ($list -contains $v) { return $v }
    }
    return ''
}

function Test-SelfAddress {
    <#
      .SYNOPSIS
        そのヘッダに本人のアドレスが入っているか。
    #>
    param([string] $Header, [string[]] $Self)
    return [bool] (Get-MatchedSelfAddress -Header $Header -Self $Self)
}

function Get-MailViewerRole {
    <#
      .SYNOPSIS
        そのメールでの本人の立場。
      .OUTPUTS
        'from' / 'to' / 'cc' / 'other' / 'unknown' (本人のアドレスが分からないとき)
    #>
    param([string] $From, [string] $To, [string] $Cc, [string[]] $Self)
    if (-not $Self -or @($Self | Where-Object { $_ }).Count -eq 0) { return 'unknown' }
    if (Test-SelfAddress -Header $From -Self $Self) { return 'from' }
    if (Test-SelfAddress -Header $To -Self $Self) { return 'to' }
    if (Test-SelfAddress -Header $Cc -Self $Self) { return 'cc' }
    return 'other'
}

# ---------------------------------------------------------------- 本人

function New-Viewer {
    <#
      .SYNOPSIS
        モデルに渡す「あなたは誰か」。
      .PARAMETER Who
        繋いだアカウントの名前 (メールならアドレス、Slack なら「チーム / 表示名」)。
      .PARAMETER Role
        Get-MailViewerRole の結果。メール以外は 'member' (会話の参加者)。
      .PARAMETER Primary
        主たる宛先。Cc のときに「返事を求められているのは誰か」を出すために持つ。
    #>
    param(
        [string] $Who,
        [string] $Label,
        [string] $Role = 'unknown',
        [string] $Primary = '',
        [string] $Service = '',
        # 立場が、名義とは**別のアカウント**のアドレスで決まった場合にそのアドレス。
        # 本人宛ではあるが、返信はこのカードのアカウントから出る、という状態。
        [string] $ViaAccount = ''
    )
    return [pscustomobject]@{
        who        = [string] $Who
        label      = [string] $Label
        role       = [string] $Role
        primary    = [string] $Primary
        service    = [string] $Service
        viaAccount = [string] $ViaAccount
    }
}

function New-MailViewer {
    <#
      .PARAMETER Who
        このカードのアカウントの名前。**名義はこれ**で、返信もここから出る。
      .PARAMETER SelfNames
        繋いである全アカウントの名前。名義は1つでも**本人は1人**なので、
        立場 (宛先か Cc か) の判定にはこちらも混ぜる。

        混ぜないと、仕事用と個人用の両方を繋いでいる人が損をする ――
        個人用宛のメールが仕事用の受信箱にも届いたとき、「宛先は他人」と読んで
        横で見ているだけの扱いにしてしまう。**本人宛なのに返さなくなる。**
    #>
    param(
        [string] $Who,
        [string] $Label,
        [string] $From,
        [string] $To,
        [string] $Cc,
        [string] $Service = '',
        [string[]] $SelfNames
    )
    # 名義のアドレス (このカードのアカウント)
    $own = @()
    if ($Who) { $own = @(Get-MailAddresses $Who) }

    # 立場の判定に使うアドレス。名義のぶん + 繋いである他のアカウントのぶん。
    $self = @($own)
    foreach ($n in @($SelfNames)) {
        foreach ($a in @(Get-MailAddresses $n)) {
            if ($self -notcontains $a) { $self += $a }
        }
    }

    # アカウント名がアドレスの形をしていないとき (表示名だけ) は立場を決められない。
    $role = Get-MailViewerRole -From $From -To $To -Cc $Cc -Self $self
    $primary = ''
    if ($role -eq 'cc' -or $role -eq 'other') { $primary = [string] $To }

    # どのアドレスで当たったか。名義以外で当たったのなら、そう言えるようにしておく。
    $header = switch ($role) {
        'from' { $From }
        'to'   { $To }
        'cc'   { $Cc }
        default { '' }
    }
    $via = ''
    if ($header) {
        $matched = Get-MatchedSelfAddress -Header $header -Self $self
        if ($matched -and ($own -notcontains $matched)) { $via = $matched }
    }
    return New-Viewer -Who $Who -Label $Label -Role $role -Primary $primary `
                      -Service $Service -ViaAccount $via
}

# ---------------------------------------------------------------- プロンプトに載せる形

function Get-ViewerLine {
    <#
      .SYNOPSIS
        画面とログに出す一行。「いま誰として扱っているか」。
    #>
    param($Viewer)
    if (-not $Viewer -or -not $Viewer.who) { return '' }
    $name = [string] $Viewer.who
    if ($Viewer.label) { $name += ' (' + [string] $Viewer.label + ')' }
    $role = switch ([string] $Viewer.role) {
        'to'    { '宛先' }
        'cc'    { 'Cc (横で見ている人)' }
        'from'  { '送信者' }
        'other' { '宛先に名前が無い' }
        'member' { '参加者' }
        default { '' }
    }
    if ($role) { return ("{0} / {1}" -f $name, $role) }
    return $name
}

function Get-ViewerBlock {
    <#
      .SYNOPSIS
        作業プロンプトに入れる「名義」の束縛。
      .DESCRIPTION
        <thread> の外に置く。中は第三者が書いたデータで、そこに本人の情報を
        混ぜると「本文に書いてあること」と区別が付かなくなる。
    #>
    param($Viewer)
    if (-not $Viewer) { return '' }
    $who = [string] $Viewer.who

    $lines = @('あなたが代わりに手を動かしている本人 (名義):')
    if ($who) {
        $label = if ($Viewer.label) { ' / ' + [string] $Viewer.label } else { '' }
        $lines += ("  本人: {0}{1}" -f $who, $label)
    }
    else {
        # 名前が取れないことはある (疎通確認より前に繋いだアカウント)。
        # それでも「他人の名義で書かない」は変わらないので、束縛自体は出す。
        $lines += '  本人: (この連携先の接続に使っているアカウント本人)'
    }

    switch ([string] $Viewer.role) {
        'to' {
            $lines += '  このメールの宛先 (To) は本人です。返事を求められているのは本人なので、本人の名義で返信してください。'
        }
        'cc' {
            $lines += '  本人は Cc です。**返事を求められている相手は本人ではありません。**'
            if ($Viewer.primary) { $lines += ('  主たる宛先 (To): ' + [string] $Viewer.primary) }
            $lines += '  既定は「返信しない」。何が起きているかを報告に書いて閉じてください。'
            $lines += '  本人として伝えるべきことがあるときだけ、**本人の名義で**横から短く差し込みます。'
        }
        'from' {
            $lines += '  この会話の送信者は本人です。返信を待っている側なので、必要なら本人の名義で追いかけてください。'
        }
        'other' {
            $lines += '  宛先にも Cc にも本人の名前がありません (メーリングリストや転送の可能性があります)。'
            $lines += '  既定は「返信しない」。何が起きているかを報告に書いて閉じてください。'
        }
        'member' {
            $lines += '  この会話に本人として参加しています。発言はすべて本人の名義で出ます。'
        }
        default {
            $lines += '  本人の立場 (宛先か Cc か) はこのカードからは確定できません。断定せずに書いてください。'
        }
    }

    if ($Viewer.viaAccount) {
        # 本人宛ではあるが、当たったのは別のアカウントのアドレス。
        # 返信はこのカードのアカウントから出るので、相手には別のアドレスで届く。
        $lines += ('  この立場は、本人が繋いでいる**別のアカウント** ({0}) のアドレスで判定しました。' -f [string] $Viewer.viaAccount)
        $lines += '  本人宛であることは変わりませんが、返信はこのカードのアカウントから出ます'
        $lines += '  (相手には上の「本人」のアドレスで届きます)。'
    }

    $lines += '**本人以外の名義で文面を書いてはいけません。** 宛先や Cc に出てくる別の人になりきって'
    $lines += '返事をする、その人の代わりに回答する、その人として名乗る ―― どれも行わないでください。'
    $lines += '送信も投稿も本人のアカウントから出るので、他人の名義で書いた文面は、相手からは'
    $lines += '「本人が他人のふりをして返信してきた」ように見えます。'
    return ($lines -join "`n")
}
