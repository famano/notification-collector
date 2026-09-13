# ChatworkConnector.ps1
# Chatwork API v2。自分宛のメッセージを取り直し、同じ部屋に返す。
#
# Slack / Teams と同じ立て付け ―― 通知は低遅延のトリガに徹し、
# 取りこぼしの無さは watermark 同期で担保する。
#
# 認証は API トークン1本 (個人設定から発行する)。ヘッダ名が Authorization ではなく
# X-ChatWorkToken なので、汎用 HTTP への注入もヘッダ名を指定できる形にしてある。
#
# 注意している仕様が3つある:
#   1. `force=0` は「前回の続き」をサーバ側が覚えている。**使わない。**
#      二度目が空で返るので、こちらの watermark と二重管理になり、
#      同期が失敗した回のぶんが誰にも拾われないまま消える。
#      force=1 で直近を取り、send_time で自分で切る。
#   2. 1回で取れるのは **100 件まで。**取り切れないときは watermark を進めない。
#   3. レート制限がある (応答の x-ratelimit-* ヘッダ)。部屋の数だけ叩くので、
#      最終更新が watermark より古い部屋は開かない。

. "$PSScriptRoot\SecretStore.ps1"

$script:ChatworkApi = 'https://api.chatwork.com/v2'

function Test-ChatworkConfigured {
    return [bool] (Get-Secret -Name 'chatwork.token')
}

function Invoke-ChatworkApi {
    <#
      .SYNOPSIS
        Chatwork を1回叩く。204 (中身なし) は $null を返す。
      .DESCRIPTION
        204 を返す口があるのがこの API の特徴。メッセージが1件も無い部屋は
        200 + 空配列ではなく 204 で返ってくるので、本文を JSON として
        読もうとすると落ちる。静かな部屋では毎回ここを通る。
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'Get',
        [hashtable] $Form
    )
    $token = Get-Secret -Name 'chatwork.token'
    if (-not $token) { throw 'Chatwork のトークンが設定されていません。カンバンの「接続」から設定してください。' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = @{
        Uri = "$script:ChatworkApi$Path"; Method = $Method
        Headers = @{ 'X-ChatWorkToken' = $token }
        UseBasicParsing = $true; TimeoutSec = 30
    }
    if ($Form) {
        # 書き込みは JSON ではなく application/x-www-form-urlencoded。
        $pairs = foreach ($k in $Form.Keys) { "{0}={1}" -f $k, [Uri]::EscapeDataString([string] $Form[$k]) }
        $req['ContentType'] = 'application/x-www-form-urlencoded'
        $req['Body'] = [Text.Encoding]::UTF8.GetBytes(($pairs -join '&'))
    }

    try { $resp = Invoke-WebRequest @req }
    catch [Net.WebException] {
        $status = 0
        $detail = ''
        $r = $_.Exception.Response
        if ($r) {
            try { $status = [int] $r.StatusCode } catch { }
            try {
                $sr = New-Object IO.StreamReader($r.GetResponseStream())
                try { $detail = $sr.ReadToEnd() } finally { $sr.Dispose() }
            } catch { }
        }
        # 末尾の (HTTP nnn) は呼び出し側が「次回もう一度読むべきか」を見るのに使う。
        throw ("Chatwork API {0} が失敗しました: {1} / {2} (HTTP {3})" -f $Path, $_.Exception.Message, $detail, $status)
    }

    if ([int] $resp.StatusCode -eq 204) { return $null }
    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

function Test-ChatworkPermanentError {
    <#
      .SYNOPSIS
        何度読み直しても結果が変わらない失敗か。
      .DESCRIPTION
        Slack / Teams と同じ判断。恒久的な失敗 (退出した部屋・権限不足) で
        watermark を止めると、読める部屋の分まで永久に入らない。逆にレート制限で
        進めてしまうと、その範囲が取りこぼしになる。429 は必ず一時扱いにすること。
    #>
    param([string] $Message)
    if (-not $Message) { return $false }
    if ($Message -notmatch 'HTTP (\d+)') { return $false }
    return (@(400, 401, 403, 404) -contains [int] $Matches[1])
}

function Get-ChatworkMe {
    <#
      .OUTPUTS
        [pscustomobject] id / account / name
    #>
    $me = Invoke-ChatworkApi -Path '/me'
    return [pscustomobject]@{
        id      = [string] $me.account_id
        name    = [string] $me.name
        account = $(if ($me.login_mail) { [string] $me.login_mail } else { [string] $me.name })
    }
}

# 自分のアカウント ID。メンション判定と「自分の発言は拾わない」に使う。
$script:ChatworkSelfId = $null
function Get-ChatworkSelfId {
    if ($script:ChatworkSelfId) { return $script:ChatworkSelfId }
    $stored = Get-Secret -Name 'chatwork.selfAccountId'
    if ($stored) { $script:ChatworkSelfId = $stored; return $stored }
    try {
        $me = Get-ChatworkMe
        if ($me.id) {
            Set-Secret -Name 'chatwork.selfAccountId' -Value $me.id
            $script:ChatworkSelfId = $me.id
        }
    } catch { }
    return $script:ChatworkSelfId
}

# ---------------------------------------------------------------- 本文の整形

function Expand-ChatworkText {
    <#
      .SYNOPSIS
        Chatwork 記法を読める平文にする。
      .DESCRIPTION
        そのまま載せると [To:123] や [qtmeta ...] がカードを埋める。
        落とすのではなく**読める形に均す**のが肝心で、引用や情報ブロックの
        中身は判断材料そのものなので残す。
    #>
    param([string] $Text)
    if (-not $Text) { return '' }
    $t = $Text

    # [To:12345] 山田さん / [rp aid=12345 to=...] 山田さん → @山田さん
    $t = [regex]::Replace($t, '\[(?:To|to):\d+\]\s*([^\r\n\[]*)', { param($m) '@' + $m.Groups[1].Value.Trim() + ' ' })
    $t = [regex]::Replace($t, '\[rp\s+aid=\d+\s+to=[\d\-]+\]\s*([^\r\n\[]*)', { param($m) '@' + $m.Groups[1].Value.Trim() + ' ' })
    $t = $t -replace '\[toall\]', '@全員 '
    # 引用は誰の発言かだけ残す
    $t = $t -replace '\[qtmeta\s+aid=(\d+)\s+time=\d+\]', ''
    $t = $t -replace '\[qt\]', "（引用ここから）`n" -replace '\[/qt\]', "`n（引用ここまで）"
    # 情報ブロックと見出し
    $t = $t -replace '\[info\]', '' -replace '\[/info\]', ''
    $t = $t -replace '\[title\]', '■ ' -replace '\[/title\]', ''
    $t = $t -replace '\[hr\]', '---'
    $t = $t -replace '\[picon:\d+\]', ''
    # [dtext:...] は絵文字などの置き換え記法。名前だけ残す
    $t = $t -replace '\[dtext:([^\]]+)\]', '$1'
    # ファイル・タスクの参照は消さずに印を残す (実体が添付にしかないことがある)
    $t = $t -replace '\[download:(\d+)\]', '(ファイル $1) ' -replace '\[/download\]', ''
    $t = $t -replace '\[preview\s+id=(\d+)[^\]]*\]', '(ファイル $1) '
    return ($t -replace '[ \t]+\n', "`n" -replace '(\r?\n){3,}', "`n`n").Trim()
}

# ---------------------------------------------------------------- リンク
#
# Chatwork の permalink は https でそのまま開ける。Slack の slack:// と違い
# 別スキームを作る必要がないので、events.link にこれをそのまま入れる。

function New-ChatworkLink {
    param([Parameter(Mandatory)] [string] $RoomId, [string] $MessageId)
    if ($MessageId) { return "https://www.chatwork.com/#!rid{0}-{1}" -f $RoomId, $MessageId }
    return "https://www.chatwork.com/#!rid{0}" -f $RoomId
}

function ConvertFrom-ChatworkLink {
    param([string] $Link)
    if (-not $Link) { return $null }
    if ($Link -notmatch '#!rid(\d+)(?:-(\d+))?') { return $null }
    return [pscustomobject]@{ roomId = $Matches[1]; messageId = [string] $Matches[2] }
}

# 部屋の名前は何度も出てくるので引いた結果を使い回す
$script:ChatworkRoomCache = @{}
function Resolve-ChatworkRoom {
    param([Parameter(Mandatory)] [string] $RoomId)
    if ($script:ChatworkRoomCache.ContainsKey($RoomId)) { return $script:ChatworkRoomCache[$RoomId] }
    try {
        $r = Invoke-ChatworkApi -Path ("/rooms/{0}" -f $RoomId)
        $name = [string] $r.name
    }
    catch { return $RoomId }   # 失敗は覚えない。権限が付けば次は引ける
    if (-not $name) { return $RoomId }
    $script:ChatworkRoomCache[$RoomId] = $name
    return $name
}

# ---------------------------------------------------------------- 掃き寄せ

function Get-ChatworkRooms {
    param([int] $Max = 200)
    $rooms = @(Invoke-ChatworkApi -Path '/rooms')
    if (-not $rooms) { return @() }
    # 最終更新の新しい順。上限で切っても「最近動いた部屋」から見られる。
    $sorted = @($rooms | Sort-Object { [long] $_.last_update_time } -Descending)
    if ($sorted.Count -gt $Max) { $sorted = $sorted[0..($Max - 1)] }
    return $sorted
}

function Get-ChatworkUpdates {
    <#
      .SYNOPSIS
        前回の続きから、自分に関係のあるメッセージだけを拾う。
      .DESCRIPTION
        部屋に流れる全部をカードにするとトリアージのコストが跳ねるので、
        入り口で「自分に関係がある」と言い切れるものだけに絞る (Slack と同じ):

          dm      … ダイレクトチャットに来たもの
          mention … [To:自分] または [rp aid=自分 …] が付いているもの

        [toall] は拾わない。全員宛の連絡は「自分に用がある」とは限らず、
        グループの数だけカードが増える。必要なら通知 (Phase 1) 側で拾える。
      .OUTPUTS
        [pscustomobject] messages / errors / truncated
    #>
    param(
        [Parameter(Mandatory)] [DateTime] $Since,
        [int] $MaxRooms = 30,
        [int] $MaxPerRoom = 100
    )
    $self = Get-ChatworkSelfId
    $sinceEpoch = [DateTimeOffset] $Since
    $sinceUnix = $sinceEpoch.ToUnixTimeSeconds()

    $hits = @()
    $errors = @()
    $truncated = $false

    $rooms = @()
    try { $rooms = @(Get-ChatworkRooms -Max $MaxRooms) }
    catch {
        $msg = $_.Exception.Message
        $errors += [pscustomobject]@{
            room = '(一覧)'; message = $msg; permanent = (Test-ChatworkPermanentError $msg)
        }
        return [pscustomobject]@{ messages = @(); errors = @($errors); truncated = $false }
    }

    foreach ($room in $rooms) {
        $roomId = [string] $room.room_id
        if (-not $roomId) { continue }
        # 最終更新が watermark より古い部屋は開かない。部屋の数だけ叩くので、
        # ここで落とせる分は落とす (レート制限は 5 分あたりで決まっている)。
        if ($room.last_update_time -and ([long] $room.last_update_time) -le $sinceUnix) { continue }

        $name = [string] $room.name
        if ($name) { $script:ChatworkRoomCache[$roomId] = $name }
        $isDm = (([string] $room.type) -eq 'direct')

        try {
            # force=1 で直近を取る。force=0 (未取得ぶん) はサーバ側が既読位置を
            # 覚えてしまい、こちらの watermark と二重管理になる。
            $msgs = Invoke-ChatworkApi -Path ("/rooms/{0}/messages?force=1" -f $roomId)
        }
        catch {
            # 部屋単位の失敗で全体を止めない。恒久かどうかを添えて呼び出し側に返す。
            $msg = $_.Exception.Message
            $errors += [pscustomobject]@{
                room = $(if ($name) { $name } else { $roomId })
                message = $msg; permanent = (Test-ChatworkPermanentError $msg)
            }
            continue
        }
        if (-not $msgs) { continue }   # 204 = この部屋にメッセージが無い

        $msgs = @($msgs)
        # 100 件で切れている可能性がある。取り切れていないので watermark を進めない。
        if ($msgs.Count -ge $MaxPerRoom) {
            $oldest = [long] $msgs[0].send_time
            if ($oldest -gt $sinceUnix) { $truncated = $true }
        }

        foreach ($m in $msgs) {
            if (-not $m) { continue }
            if (([long] $m.send_time) -le $sinceUnix) { continue }
            $from = [string] $m.account.account_id
            if ($self -and $from -eq $self) { continue }
            # 入退室などのシステムメッセージ。本文ではないので拾わない。
            $body = [string] $m.body
            if ($body -match '^\[rtchat|^\[info\]\[title\]Chatwork') { continue }

            $reason = $null
            if ($isDm) { $reason = 'dm' }
            elseif ($self -and ($body -match ('\[To:' + [regex]::Escape($self) + '\]') -or
                                $body -match ('\[rp\s+aid=' + [regex]::Escape($self) + '\s'))) { $reason = 'mention' }
            if (-not $reason) { continue }

            $when = Get-Date
            try { $when = [DateTimeOffset]::FromUnixTimeSeconds([long] $m.send_time).LocalDateTime } catch { }

            $hits += [pscustomobject]@{
                roomId    = $roomId
                roomName  = $(if ($name) { $name } else { $roomId })
                messageId = [string] $m.message_id
                accountId = $from
                sender    = [string] $m.account.name
                sendTime  = [long] $m.send_time
                createdAt = $when
                text      = Expand-ChatworkText $body
                raw       = $body
                reason    = $reason
            }
        }
    }

    return [pscustomobject]@{
        messages  = @($hits | Sort-Object sendTime)
        errors    = @($errors)
        truncated = $truncated
    }
}

function Get-ChatworkThread {
    <#
      .SYNOPSIS
        リンクから部屋の直近のやり取りを取得し、読める形にして返す。
      .DESCRIPTION
        Chatwork にスレッドは無い。判断材料になるのは「その部屋の直前の流れ」なので、
        同じ部屋の直近を前後の文脈として付ける。
      .OUTPUTS
        [pscustomobject] text / room / messageCount / permalink (解釈できなければ $null)
    #>
    param([Parameter(Mandatory)] [string] $Link, [int] $Limit = 30)
    $ref = ConvertFrom-ChatworkLink $Link
    if (-not $ref) { return $null }

    $roomName = Resolve-ChatworkRoom $ref.roomId
    $msgs = @(Invoke-ChatworkApi -Path ("/rooms/{0}/messages?force=1" -f $ref.roomId))
    if (-not $msgs -or $msgs.Count -eq 0) {
        return [pscustomobject]@{
            text = "部屋: $roomName`n`n(直近のメッセージを取得できませんでした)"
            room = $roomName; messageCount = 0; permalink = (New-ChatworkLink -RoomId $ref.roomId -MessageId $ref.messageId)
        }
    }
    $msgs = @($msgs | Sort-Object { [long] $_.send_time })
    if ($msgs.Count -gt $Limit) { $msgs = $msgs[($msgs.Count - $Limit)..($msgs.Count - 1)] }

    $lines = @()
    foreach ($m in $msgs) {
        $when = ''
        try { $when = [DateTimeOffset]::FromUnixTimeSeconds([long] $m.send_time).LocalDateTime.ToString('MM/dd HH:mm') } catch { }
        $mark = if (([string] $m.message_id) -eq $ref.messageId) { ' ← この通知の対象' } else { '' }
        $lines += ("[{0}] {1}{2}`n{3}" -f $when, [string] $m.account.name, $mark, (Expand-ChatworkText ([string] $m.body)))
    }

    return [pscustomobject]@{
        text         = ("部屋: $roomName`n`n" + ($lines -join "`n`n"))
        room         = $roomName
        messageCount = $msgs.Count
        permalink    = (New-ChatworkLink -RoomId $ref.roomId -MessageId $ref.messageId)
    }
}

function Get-ChatworkTarget {
    <#
      .SYNOPSIS
        カードのリンクから「どこに返すか」を決める。表示用の名前も一緒に返す。
    #>
    param([Parameter(Mandatory)] [string] $Link)
    $ref = ConvertFrom-ChatworkLink $Link
    if (-not $ref) { return $null }
    return [pscustomobject]@{
        roomId    = $ref.roomId
        roomName  = (Resolve-ChatworkRoom $ref.roomId)
        messageId = $ref.messageId
    }
}

function Send-ChatworkMessage {
    <#
      .SYNOPSIS
        Chatwork の部屋に投稿する。取り消せないので、呼び出し側は必ず承認を取ってから呼ぶこと。
      .PARAMETER ReplyToAccountId / ReplyToMessageId
        指定すると返信記法 ([rp ...]) を付ける。相手の画面で元の発言に紐づく。
      .OUTPUTS
        [pscustomobject] messageId / permalink
    #>
    param(
        [Parameter(Mandatory)] [string] $RoomId,
        [Parameter(Mandatory)] [string] $Text,
        [string] $ReplyToAccountId,
        [string] $ReplyToMessageId
    )
    if (-not $Text.Trim()) { throw '本文が空です。' }

    $body = $Text
    if ($ReplyToAccountId -and $ReplyToMessageId) {
        $body = ("[rp aid={0} to={1}-{2}]`n{3}" -f $ReplyToAccountId, $RoomId, $ReplyToMessageId, $Text)
    }
    $r = Invoke-ChatworkApi -Path ("/rooms/{0}/messages" -f $RoomId) -Method 'Post' -Form @{ body = $body }
    $id = [string] $r.message_id
    return [pscustomobject]@{ messageId = $id; permalink = (New-ChatworkLink -RoomId $RoomId -MessageId $id) }
}
