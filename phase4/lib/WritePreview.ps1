# WritePreview.ps1
# 書き込みの前に「何が起きるか」を見せ、書いたあとに読み直す。
#
# #295 では、テストの期待値2行を直すつもりで PUT contents を打ち、ファイル全体
# (10,361 バイト) を先頭の1行 (24 バイト) で置き換えた。PUT は仕様上「全体の置き換え」で、
# 送らなかった部分は消える。承認画面には base64 の本文が 2000 字で切られて出ていたが、
# 人が読んで「中身が 1/400 になる」と気付ける形ではなかった (しかも許可済みで画面は出なかった)。
#
# ここにあるのは特定のサービスの知識ではなく、HTTP の意味に沿った一般的な規則:
#   - 操作の種類を「読む / 足す / 上書き・消す」に分ける。許可はこの種類とホストの組で持つ
#   - 上書き・消すの前には、同じ URL を GET して、送る本文とフィールドごとに突き合わせる
#     (base64 の値はデコードしてから比べる)。大きく消えるなら許可があっても止める
#   - 突き合わせられないもの (GET できない・形が違う) は、許可では通さず承認に回す
#   - 書いたあとは読み直し、送った値と一致しているかを返す
#   - base64 はモデルに手で書かせない。平文で受け取り、ワーカーが符号化する

# ---------------------------------------------------------------- 操作の種類

function Get-HttpOpKind {
    <#
      .OUTPUTS
        read   … GET / HEAD / OPTIONS
        add    … POST。相手に新しいものを足す (コメント・予定・下書き)
        change … PUT / PATCH / DELETE。いまあるものを上書きする・消す
      .DESCRIPTION
        POST でも状態を変える API はある (マージ、承諾) が、足す操作の多くは
        取り消しても害が小さく、一度許可したら続けて通したい (コメントなど)。
        上書き・消すは、送らなかった部分が消える・前の状態が戻らない、という意味で別に扱う。
    #>
    param([string] $Method)
    $m = if ($Method) { $Method.ToUpper() } else { 'GET' }
    if (@('GET', 'HEAD', 'OPTIONS') -contains $m) { return 'read' }
    if ($m -eq 'POST') { return 'add' }
    return 'change'
}

function Get-HttpOpLabel {
    param([string] $Kind)
    switch ($Kind) {
        'read'   { return '読み取り' }
        'add'    { return '追加 (POST)' }
        'change' { return '上書き・削除 (PUT/PATCH/DELETE)' }
        default  { return $Kind }
    }
}

function Get-GrantKey {
    <#
      .SYNOPSIS
        「まとめて許可」を束ねる鍵。http_request はツール名ではなく「種類 × ホスト」。
      .DESCRIPTION
        以前はツール名で束ねていたので、GET を通すために押した「今後すべて許可」が、
        GitHub への PUT まで無承認にしていた (#295)。
    #>
    param([Parameter(Mandatory)] [string] $Name, $ToolInput)
    if ($Name -ne 'http_request' -or -not $ToolInput) { return $Name }
    $host_ = ''
    try { $host_ = ([Uri] [string] $ToolInput.url).Host.ToLower() } catch { }
    return ('http_request:{0}:{1}' -f (Get-HttpOpKind ([string] $ToolInput.method)), $host_)
}

function Get-GrantKeyLabel {
    <#
      .SYNOPSIS
        許可の鍵を人が読める形にする (承認画面・許可済みの一覧)。
    #>
    param([Parameter(Mandatory)] [string] $Key)
    if ($Key -match '^http_request:(\w+):(.*)$') {
        $h = if ($Matches[2] -eq '*') { 'すべてのホストへの' } else { $Matches[2] + ' への' }
        return ($h + (Get-HttpOpLabel $Matches[1]))
    }
    return $Key
}

# ---------------------------------------------------------------- base64 は手で書かせない

function ConvertTo-EncodedBody {
    <#
      .SYNOPSIS
        本文 (JSON) のうち、指定されたフィールドを base64 / base64url に符号化する。
      .DESCRIPTION
        ファイルを丸ごと送る API (GitHub の contents、Gmail の raw) は値を base64 で求める。
        それをモデルに手で書かせると、長さの分だけ出力を食い、1文字でも誤れば中身が壊れる
        (1万字のファイルは base64 で 1.4万字になり、4096 トークンの上限では最初から書き切れない)。
        モデルは平文で書き、どのフィールドを符号化するかだけを指定する。
      .PARAMETER Encode
        @{ フィールド名 = 'base64' | 'base64url' }。トップレベルのフィールドだけ。
      .OUTPUTS
        [pscustomobject] body (符号化後の JSON 文字列) / error
    #>
    param([string] $Body, $Encode)
    $out = [pscustomobject]@{ body = $Body; error = '' }
    if (-not $Encode) { return $out }
    $names = @()
    if ($Encode -is [hashtable]) { $names = @($Encode.Keys) } else { $names = @($Encode.PSObject.Properties.Name) }
    if ($names.Count -eq 0) { return $out }
    $obj = $null
    try { $obj = $Body | ConvertFrom-Json } catch { }
    if (-not $obj -or $obj -is [array] -or $obj -is [string]) {
        $out.error = 'encode を使うときは、本文をトップレベルが JSON オブジェクトの形で書いてください。'
        return $out
    }
    foreach ($n in $names) {
        $how = if ($Encode -is [hashtable]) { [string] $Encode[$n] } else { [string] $Encode.$n }
        if (-not ($obj.PSObject.Properties.Name -contains $n)) {
            $out.error = "encode に指定したフィールド '$n' が本文にありません。"
            return $out
        }
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string] $obj.$n))
        if ($how -eq 'base64url') { $b64 = $b64.TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        elseif ($how -ne 'base64') {
            $out.error = "encode の値は 'base64' か 'base64url' です ('$how' が指定されました)。"
            return $out
        }
        $obj.$n = $b64
    }
    $out.body = ($obj | ConvertTo-Json -Depth 20 -Compress)
    return $out
}

function Test-LooksBase64 {
    param([string] $Text, [int] $MinLength = 16)
    if (-not $Text -or $Text.Length -lt $MinLength) { return $false }
    $t = $Text -replace '\s', ''
    if ($t.Length -lt $MinLength) { return $false }
    return ($t -match '^[A-Za-z0-9+/_-]+={0,2}$')
}

function ConvertFrom-Base64Loose {
    <#
      .SYNOPSIS
        base64 / base64url (改行・パディング欠けも許す) をバイト列に戻す。戻せなければ $null。
    #>
    param([string] $Text)
    if (-not (Test-LooksBase64 $Text -MinLength 4)) { return $null }
    $t = ($Text -replace '\s', '').Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } 1 { return $null } }
    # 先頭のカンマが要る。付けないとバイト列が1つずつ展開されて返る。
    try { return ,([Convert]::FromBase64String($t)) } catch { return $null }
}

function Find-HandWrittenBase64 {
    <#
      .SYNOPSIS
        モデルが手で書いた長い base64 を探す。見つかったらフィールド名を返す。
      .DESCRIPTION
        encode で符号化したフィールドは除く (それはワーカーが作ったもの)。
    #>
    param([string] $Body, [string[]] $Except = @(), [int] $Threshold = 2000)
    if (-not $Body) { return '' }
    $obj = $null
    try { $obj = $Body | ConvertFrom-Json } catch { return '' }
    if (-not $obj -or $obj -is [array] -or $obj -is [string]) { return '' }
    foreach ($p in $obj.PSObject.Properties) {
        if ($Except -contains $p.Name) { continue }
        if ($p.Value -is [string] -and $p.Value.Length -ge $Threshold -and (Test-LooksBase64 $p.Value)) {
            return $p.Name
        }
    }
    return ''
}

# ---------------------------------------------------------------- 書く前の突き合わせ

function Get-CurrentState {
    <#
      .SYNOPSIS
        書き込み先の URL を GET して、いまの状態を取る。読まないホストなら $null。
      .DESCRIPTION
        資格情報を付ける既知のホストだけを読む。知らないホストへの GET は、
        URL に載った情報を承認の前に外へ出すことになる (GET でも承認を取っている理由と同じ)。
      .OUTPUTS
        [pscustomobject] status / text
    #>
    param([Parameter(Mandatory)] [string] $Url)
    if (-not (Get-HostCredentialSpec -Url $Url)) { return $null }
    # 比べるのに全文が要るので、応答を切り詰めない。
    $r = Invoke-HttpAction -Method 'GET' -Url $Url -MaxChars 5000000
    $status = 0
    if ([string] $r.text -match '^HTTP (\d+)') { $status = [int] $Matches[1] }
    $body = ([string] $r.text) -replace '^HTTP [^\r\n]*\r?\n(\r?\n)?', ''
    return [pscustomobject]@{ status = $status; text = $body }
}

function Get-ComparableValue {
    <#
      .SYNOPSIS
        比べるための値。base64 らしければデコードした中身 (テキストならその文字列)、
        そうでなければ文字列そのもの。長さの単位も返す。
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string]) {
        $s = ($Value | ConvertTo-Json -Depth 20 -Compress)
        return [pscustomobject]@{ text = $s; length = $s.Length; unit = '字'; decoded = $false }
    }
    $bytes = $null
    if (Test-LooksBase64 $Value -MinLength 16) { $bytes = ConvertFrom-Base64Loose $Value }
    if ($bytes) {
        $bytes = [byte[]] $bytes
        # テキストでなければ、比べる値は正規化した base64 にする (null 同士を「同じ」と見ないため)
        $txt = [Convert]::ToBase64String($bytes)
        try { $txt = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { }
        return [pscustomobject]@{ text = $txt; length = $bytes.Length; unit = 'バイト'; decoded = $true }
    }
    return [pscustomobject]@{ text = $Value; length = $Value.Length; unit = '字'; decoded = $false }
}

function Get-WritePreview {
    <#
      .SYNOPSIS
        上書き・削除の前に、いまの状態と送る本文を突き合わせる。
      .PARAMETER Current
        同じ URL を GET した結果。@{ status = 200; text = '...' }。取れなかったら $null。
      .OUTPUTS
        [pscustomobject]
          level     … compared (フィールドごとに突き合わせた) / new (まだ無いものを作る) /
                      shown (いまの状態は読めたが突き合わせられない) / unavailable (読めなかった)
          largeLoss … 大きく消える。許可があっても止める
          lines     … 承認画面とモデルに出す説明
          summary   … 1行の要約 (作業ログ・試行記録用)
      .DESCRIPTION
        比べるのは「送る本文」と「いまの状態」の両方にあるフィールドだけ。
        GET の応答には送らないメタ情報 (sha・url・更新日時) が並ぶのが普通で、
        それを「消える」と数えると毎回騒ぐことになる。
        DELETE は、いまあるものが丸ごと無くなる操作なので、常に大きく消える扱いにする。
    #>
    param(
        [Parameter(Mandatory)] [string] $Method,
        [string] $Body,
        $Current,
        [double] $LossRatio = 0.5,
        [int] $MinSize = 200
    )
    $m = $Method.ToUpper()
    $p = [pscustomobject]@{ level = 'unavailable'; largeLoss = $false; lines = @(); summary = '' }

    if (-not $Current) {
        $p.lines = @('いまの状態を読めませんでした (このホストには事前の読み取りをしていません)。影響を事前に確認できません。')
        $p.summary = '影響を事前に確認できません'
        return $p
    }
    $st = [int] $Current.status
    if ($st -eq 404 -and $m -ne 'DELETE') {
        $p.level = 'new'
        $p.lines = @('いまは存在しません (GET が 404)。新しく作る操作です。')
        $p.summary = '新規作成'
        return $p
    }
    if ($st -lt 200 -or $st -ge 300) {
        $p.lines = @("いまの状態を読めませんでした (GET が HTTP $st)。影響を事前に確認できません。")
        $p.summary = '影響を事前に確認できません'
        return $p
    }

    $cur = $null
    try { $cur = [string] $Current.text | ConvertFrom-Json } catch { }

    if ($m -eq 'DELETE') {
        $p.level = 'compared'
        $p.largeLoss = $true
        $size = ([string] $Current.text).Length
        $p.lines = @("いま存在するもの ($size 字の応答) を削除します。削除したものは戻せません。")
        $p.summary = '削除'
        return $p
    }

    $sent = $null
    try { $sent = $Body | ConvertFrom-Json } catch { }
    $isObj = { param($o) ($null -ne $o) -and ($o -isnot [array]) -and ($o -isnot [string]) -and ($o -isnot [ValueType]) }
    if (-not (& $isObj $cur) -or -not (& $isObj $sent)) {
        $p.level = 'shown'
        $t = [string] $Current.text
        if ($t.Length -gt 1500) { $t = $t.Substring(0, 1500) + '…' }
        $p.lines = @('いまの状態は読めましたが、送る本文と形が違うため突き合わせられません。', 'いまの状態:', $t)
        $p.summary = '突き合わせられません'
        return $p
    }

    $common = @($sent.PSObject.Properties.Name | Where-Object { $cur.PSObject.Properties.Name -contains $_ })
    if ($common.Count -eq 0) {
        $p.level = 'shown'
        $p.lines = @('送る本文のフィールドが、いまの状態に1つもありません。突き合わせられません。')
        $p.summary = '突き合わせられません'
        return $p
    }

    $p.level = 'compared'
    $lines = @()
    $losses = @()
    foreach ($n in $common) {
        $a = Get-ComparableValue $cur.$n
        $b = Get-ComparableValue $sent.$n
        if ($null -eq $a -or $null -eq $b) { continue }
        if ($a.text -ceq $b.text) { $lines += ("{0}: 変わりません" -f $n); continue }
        $unit = if ($a.decoded -or $b.decoded) { 'バイト (デコード後)' } else { '字' }
        $line = "{0}: {1:N0} → {2:N0} {3}" -f $n, $a.length, $b.length, $unit
        if ($a.length -ge $MinSize -and $b.length -lt $a.length * $LossRatio) {
            $pct = [int] [Math]::Round((1 - $b.length / [double] $a.length) * 100)
            $line += "  ※ {0}% 減ります" -f $pct
            $losses += $n
        }
        $lines += $line
    }
    $only = @($cur.PSObject.Properties.Name | Where-Object { $sent.PSObject.Properties.Name -notcontains $_ })
    if ($m -eq 'PUT' -and $only.Count -gt 0) {
        $lines += ('送らないフィールド (PUT は全体の置き換えなので、API によっては消えます): ' + (($only | Select-Object -First 12) -join ', '))
    }
    $p.lines = $lines
    if ($losses.Count -gt 0) {
        $p.largeLoss = $true
        $p.summary = '大きく減ります: ' + ($losses -join ', ')
    } else {
        $p.summary = '変更: ' + ($common -join ', ')
    }
    return $p
}

function Get-ReadbackCheck {
    <#
      .SYNOPSIS
        書いたあとに読み直した結果と、送った本文を突き合わせる。
      .OUTPUTS
        モデルに返す説明文。読めなければ空。
    #>
    param([string] $Body, $After)
    if (-not $After) { return '' }
    $st = [int] $After.status
    if ($st -lt 200 -or $st -ge 300) { return "書いたあとに読み直そうとしましたが、GET が HTTP $st でした。" }
    $cur = $null; $sent = $null
    try { $cur = [string] $After.text | ConvertFrom-Json } catch { }
    try { $sent = $Body | ConvertFrom-Json } catch { }
    if (-not $cur -or -not $sent -or $cur -is [array] -or $sent -is [array]) {
        return '書いたあとに読み直しました (形が違うため、送った値との突き合わせはしていません)。'
    }
    $out = @()
    foreach ($n in @($sent.PSObject.Properties.Name)) {
        if (-not ($cur.PSObject.Properties.Name -contains $n)) { continue }
        $a = Get-ComparableValue $cur.$n
        $b = Get-ComparableValue $sent.$n
        if ($null -eq $a -or $null -eq $b) { continue }
        if ($a.text -ceq $b.text) { $out += ("{0}: 送った値と一致 ({1:N0} {2})" -f $n, $a.length, $a.unit) }
        else { $out += ("{0}: 送った値と違います (いま {1:N0} {2})" -f $n, $a.length, $a.unit) }
    }
    if ($out.Count -eq 0) { return '書いたあとに読み直しました (送ったフィールドは応答に含まれていません)。' }
    return ("書いたあとに読み直しました:`n" + ($out -join "`n"))
}
