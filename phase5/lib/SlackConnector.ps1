# SlackConnector.ps1
# 通知のディープリンクを手がかりに、Slack Web API からスレッド全文を取得する。
#
# Phase 1 の結論への対応:
#   通知本文には表示用テキストしか入っておらず、スレッドの経緯が分からない。
#   一方で通知の launch URI には team / channel / message ts / thread_ts が
#   すべて入っている。これは Slack API の主キーそのものなので、通知を起点に
#   正規 API で本文を取り直せる。
#
# Socket Mode は使わない。通知リスナーが既にトリガーとして機能しているので、
# 常時接続を足す必要がない。
#
# 投稿 (chat.postMessage) も持つ。読み取りと違い取り消しがきかないので、
# 呼ぶ前に必ずカンバンで承認を取る (判定は phase4/lib/WorkTools.ps1)。
# 投稿先はモデルに決めさせず、カードの元通知のリンクから束縛して渡す。

. "$PSScriptRoot\SecretStore.ps1"

$script:SlackApi = 'https://slack.com/api'

function Test-SlackConfigured {
    return [bool] ((Get-Secret -Name 'slack.botToken') -or (Get-Secret -Name 'slack.userToken'))
}

# 読み取りはユーザートークン (xoxp) があればそちらを優先する。
# Bot トークンは招待されたチャンネルしか見えず、DM は Bot 自身宛のものに限られる。
# 「寝ているあいだに来た DM」まで拾えるかどうかは、ここで決まる。
function Get-SlackReadToken {
    $t = Get-Secret -Name 'slack.userToken'
    if ($t) { return $t }
    return Get-Secret -Name 'slack.botToken'
}

# 投稿は Bot 名義を既定にする。ユーザートークンしか無い場合だけ自分名義になる。
function Get-SlackWriteToken {
    $t = Get-Secret -Name 'slack.botToken'
    if ($t) { return $t }
    return Get-Secret -Name 'slack.userToken'
}

# slack://channel?id=C123&message=169...&team=T123&thread_ts=169...
function ConvertFrom-SlackLink {
    param([string] $Link)
    if (-not $Link -or $Link -notlike 'slack://*') { return $null }
    $q = ''
    $i = $Link.IndexOf('?')
    if ($i -ge 0) { $q = $Link.Substring($i + 1) }
    if (-not $q) { return $null }

    $h = @{}
    foreach ($pair in ($q -split '&')) {
        $kv = $pair -split '=', 2
        if ($kv.Count -eq 2) { $h[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) }
    }
    if (-not $h['id']) { return $null }
    return [pscustomobject]@{
        team      = $h['team']
        channel   = $h['id']
        messageTs = $h['message']
        # スレッド返信でなければ thread_ts は無い。その場合は message を起点にする。
        threadTs  = if ($h['thread_ts']) { $h['thread_ts'] } else { $h['message'] }
    }
}

function Invoke-SlackApi {
    param([Parameter(Mandatory)] [string] $Method, [hashtable] $Query)
    $token = Get-SlackReadToken
    if (-not $token) { throw 'Slack のトークンが設定されていません。Connect-Service.ps1 -Service slack を実行してください。' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $url = "$script:SlackApi/$Method"
    if ($Query -and $Query.Count -gt 0) {
        $parts = foreach ($k in $Query.Keys) { "{0}={1}" -f $k, [Uri]::EscapeDataString([string] $Query[$k]) }
        $url += '?' + ($parts -join '&')
    }
    $resp = Invoke-WebRequest -Uri $url -Method Get -Headers @{ Authorization = "Bearer $token" } `
                -UseBasicParsing -TimeoutSec 30
    $obj = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    if (-not $obj.ok) {
        # Slack は HTTP 200 で ok:false を返す。握り潰すと原因が分からなくなる。
        throw ("Slack API {0} が失敗しました: {1}" -f $Method, $obj.error)
    }
    return $obj
}

# 書き込み系。GET と違い引数は JSON ボディで送る。
function Invoke-SlackApiPost {
    param([Parameter(Mandatory)] [string] $Method, [Parameter(Mandatory)] [hashtable] $Body)
    $token = Get-SlackWriteToken
    if (-not $token) { throw 'Slack のトークンが設定されていません。Connect-Service.ps1 -Service slack を実行してください。' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $json = $Body | ConvertTo-Json -Depth 10 -Compress
    $resp = Invoke-WebRequest -Uri "$script:SlackApi/$Method" -Method Post `
                -Headers @{ Authorization = "Bearer $token" } `
                -ContentType 'application/json; charset=utf-8' `
                -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
                -UseBasicParsing -TimeoutSec 30
    $obj = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    if (-not $obj.ok) {
        # missing_scope や not_in_channel はここで名前が出ないと原因が分からない
        throw ("Slack API {0} が失敗しました: {1}" -f $Method, $obj.error)
    }
    return $obj
}

# ユーザーIDは何度も出てくるので引いた結果を使い回す
$script:SlackUserCache = @{}
function Resolve-SlackUser {
    param([string] $UserId)
    if (-not $UserId) { return '(不明)' }
    if ($script:SlackUserCache.ContainsKey($UserId)) { return $script:SlackUserCache[$UserId] }
    try {
        $u = Invoke-SlackApi -Method 'users.info' -Query @{ user = $UserId }
        $name = if ($u.user.profile.real_name) { $u.user.profile.real_name }
                elseif ($u.user.profile.display_name) { $u.user.profile.display_name }
                else { $u.user.name }
    }
    catch { $name = $UserId }
    $script:SlackUserCache[$UserId] = $name
    return $name
}

# チャンネル名も引いた結果を使い回す。カードを開くたびに conversations.info を
# 叩くと、ドロワーの表示が API 待ちになる。
$script:SlackChannelCache = @{}
function Resolve-SlackChannel {
    param([string] $ChannelId)
    if (-not $ChannelId) { return '(不明)' }
    if ($script:SlackChannelCache.ContainsKey($ChannelId)) { return $script:SlackChannelCache[$ChannelId] }
    try {
        $c = Invoke-SlackApi -Method 'conversations.info' -Query @{ channel = $ChannelId }
        $name = if ($c.channel.is_im) { 'ダイレクトメッセージ' } else { '#' + $c.channel.name }
    }
    catch { return $ChannelId }   # 失敗は覚えない。権限が付いたら次は引けるはず
    $script:SlackChannelCache[$ChannelId] = $name
    return $name
}

# 本文中の <@U123> をユーザー名に、<http://x|y> を y に均す
function Expand-SlackText {
    param([string] $Text)
    if (-not $Text) { return '' }
    $out = [regex]::Replace($Text, '<@([A-Z0-9]+)(\|[^>]*)?>', {
        param($m) '@' + (Resolve-SlackUser $m.Groups[1].Value)
    })
    $out = [regex]::Replace($out, '<(https?://[^|>]+)\|([^>]*)>', '$2 ($1)')
    $out = [regex]::Replace($out, '<(https?://[^>]+)>', '$1')
    $out = $out -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>'
    return $out
}

function Get-SlackThread {
    <#
      .SYNOPSIS
        通知のリンクからスレッド全文を取得し、読める形のテキストにして返す。
      .OUTPUTS
        [pscustomobject] text / channel / messageCount / permalink  (取得できなければ $null)
    #>
    param([Parameter(Mandatory)] [string] $Link, [int] $Limit = 50)

    $ref = ConvertFrom-SlackLink $Link
    if (-not $ref) { return $null }

    $channelName = Resolve-SlackChannel $ref.channel
    $r = Invoke-SlackApi -Method 'conversations.replies' -Query @{
        channel = $ref.channel; ts = $ref.threadTs; limit = $Limit
    }

    $lines = @()
    foreach ($m in @($r.messages)) {
        if (-not $m) { continue }
        $who = Resolve-SlackUser $m.user
        $when = ''
        try { $when = [DateTimeOffset]::FromUnixTimeSeconds([long][double] $m.ts).LocalDateTime.ToString('MM/dd HH:mm') } catch { }
        $body = Expand-SlackText $m.text
        $mark = if ($m.ts -eq $ref.messageTs) { ' ← この通知の対象' } else { '' }
        $lines += "[$when] $who$mark`n$body"
        # 添付・ファイルは本文に出ないことがあるので名前だけ拾う
        foreach ($f in @($m.files)) { $lines += "  (添付: $($f.name))" }
    }

    $permalink = ''
    try {
        $p = Invoke-SlackApi -Method 'chat.getPermalink' -Query @{ channel = $ref.channel; message_ts = $ref.messageTs }
        $permalink = $p.permalink
    } catch { }

    return [pscustomobject]@{
        text         = ("チャンネル: $channelName`n`n" + ($lines -join "`n`n"))
        channel      = $channelName
        messageCount = @($r.messages).Count
        permalink    = $permalink
    }
}

# ---------------------------------------------------------------- 掃き寄せ (通知に依存しない取得)
#
# 通知はトーストが出た瞬間にしか手に入らない。PC が落ちていれば配信自体が無く、
# 起動していても wpndatabase は十数件しか保持しない。つまり通知は「速いが穴が開く」経路で、
# 取りこぼしの無さは API 側で担保するしかない。ここは前回の続き (watermark) から
# 読み直すことでその穴を埋める。

$script:SlackSelfId = $null

function Get-SlackSelfUserId {
    <#
      .SYNOPSIS
        「自分」の Slack ユーザーID。メンション判定に使う。
      .DESCRIPTION
        ユーザートークンなら auth.test の user_id が本人なので自動で分かる。
        Bot トークンだと auth.test は Bot 自身を返すため、設定済みの値が要る。
    #>
    if ($script:SlackSelfId) { return $script:SlackSelfId }
    $stored = Get-Secret -Name 'slack.selfUserId'
    if ($stored) { $script:SlackSelfId = $stored; return $stored }
    if (Get-Secret -Name 'slack.userToken') {
        try { $script:SlackSelfId = [string] (Invoke-SlackApi -Method 'auth.test').user_id } catch { }
    }
    return $script:SlackSelfId
}

$script:SlackTeamId = $null
function Get-SlackTeamId {
    if (-not $script:SlackTeamId) {
        try { $script:SlackTeamId = [string] (Invoke-SlackApi -Method 'auth.test').team_id } catch { }
    }
    return $script:SlackTeamId
}

# 掃き寄せで拾ったメッセージも、通知から来たものと同じ形のリンクにする。
# ここを揃えておけば、スレッド全文の補完も permalink の取得も既存の経路がそのまま動く。
function New-SlackLink {
    param([Parameter(Mandatory)] [string] $Channel, [Parameter(Mandatory)] [string] $Ts, [string] $ThreadTs)
    $team = Get-SlackTeamId
    $link = "slack://channel?id=$Channel&message=$Ts"
    if ($team) { $link += "&team=$team" }
    if ($ThreadTs -and $ThreadTs -ne $Ts) { $link += "&thread_ts=$ThreadTs" }
    return $link
}

function ConvertTo-SlackThreadKey {
    param([string] $Channel, [string] $ThreadTs)
    return "slack:${Channel}:${ThreadTs}"
}

function Find-SlackUserId {
    <#
      .SYNOPSIS
        メールアドレスか表示名からユーザーIDを引く。設定時に「自分」を特定するために使う。
      .OUTPUTS
        [pscustomobject[]] id / name / realName / email。見つからなければ空。
    #>
    param([Parameter(Mandatory)] [string] $Query)

    if ($Query -match '^[^@\s]+@[^@\s]+$') {
        # users:read.email があればこれが一番確実
        try {
            $u = (Invoke-SlackApi -Method 'users.lookupByEmail' -Query @{ email = $Query }).user
            return @([pscustomobject]@{ id = $u.id; name = $u.name; realName = $u.profile.real_name; email = $u.profile.email })
        } catch { }
    }

    $hits = @()
    $cursor = ''
    do {
        $q = @{ limit = 200 }
        if ($cursor) { $q['cursor'] = $cursor }
        $r = Invoke-SlackApi -Method 'users.list' -Query $q
        foreach ($u in @($r.members)) {
            if ($u.deleted -or $u.is_bot) { continue }
            $fields = @($u.name, $u.real_name, $u.profile.display_name, $u.profile.real_name, $u.profile.email)
            foreach ($f in $fields) {
                if ($f -and ([string] $f) -like "*$Query*") {
                    $hits += [pscustomobject]@{ id = $u.id; name = $u.name; realName = $u.profile.real_name; email = $u.profile.email }
                    break
                }
            }
        }
        $cursor = ''
        if ($r.response_metadata -and $r.response_metadata.next_cursor) { $cursor = [string] $r.response_metadata.next_cursor }
    } while ($cursor)
    return $hits
}

# 何度読み直しても結果が変わらない失敗かどうか。
# 権限やチャンネル構成の問題は待っても直らないので、これで watermark を止めると
# 「読める会話の分まで永久に取り込まれない」状態になる。逆に一時的な失敗
# (レート制限・通信断) で進めてしまうと、その範囲が取りこぼしになる。
$script:SlackPermanentErrors = @(
    'channel_not_found', 'not_in_channel', 'missing_scope', 'is_archived',
    'restricted_action', 'no_permission', 'access_denied', 'method_not_supported_for_channel_type'
)
function Test-SlackPermanentError {
    param([string] $Code)
    return ($Code -and $script:SlackPermanentErrors -contains $Code)
}

function Get-SlackConversations {
    <#
      .SYNOPSIS
        トークンの持ち主が入っている会話の一覧。
        Bot トークンなら「Bot が招待されたチャンネル」、ユーザートークンなら自分の全会話。
    #>
    param([int] $Max = 200)
    $out = @()
    $cursor = ''
    while ($out.Count -lt $Max) {
        $q = @{
            types            = 'public_channel,private_channel,mpim,im'
            exclude_archived = 'true'
            limit            = [Math]::Min(200, $Max - $out.Count)
        }
        if ($cursor) { $q['cursor'] = $cursor }
        $r = Invoke-SlackApi -Method 'users.conversations' -Query $q
        # 0 件のとき channels は返らない。@($null) を回すと $null が1件混ざり、
        # 後段が id の無い会話を読みに行って毎回エラーになる。
        if (-not $r.channels) { break }
        foreach ($c in @($r.channels)) { $out += $c }
        $cursor = ''
        if ($r.response_metadata -and $r.response_metadata.next_cursor) { $cursor = [string] $r.response_metadata.next_cursor }
        if (-not $cursor) { break }
    }
    return $out
}

function Get-SlackUpdates {
    <#
      .SYNOPSIS
        前回の続きから、自分に関係のある新着メッセージだけを拾う。
      .DESCRIPTION
        会話に流れる全部をカード化するとトリアージのコストが跳ねるので、
        入り口で「自分に関係がある」と言い切れるものだけに絞る:

          dm      … DM / グループ DM に来たもの
          mention … 自分が名指しされたもの
          thread  … すでにカードがあるスレッドへの新しい返信 (会話の続き)

        絞りきれなかったものは捨てる。ここを緩めると Phase 2 が全部 LLM に回す。
      .PARAMETER SinceTs
        Slack の ts (epoch 秒)。これより新しいものだけを見る。
      .PARAMETER KnownThreadKeys
        すでにカードがあるスレッドの鍵 (ConvertTo-SlackThreadKey の値)。
      .OUTPUTS
        [pscustomobject[]] 拾ったメッセージ。errors には読めなかった会話が入る。
    #>
    param(
        [Parameter(Mandatory)] [string] $SinceTs,
        [string[]] $KnownThreadKeys,
        [int] $MaxChannels = 60,
        [int] $MaxPerChannel = 100
    )

    $self  = Get-SlackSelfUserId
    $known = @{}
    foreach ($k in @($KnownThreadKeys)) { if ($k) { $known[$k] = $true } }

    $hits   = @()
    $errors = @()
    foreach ($c in @(Get-SlackConversations -Max $MaxChannels)) {
        $isDm = ([bool] $c.is_im) -or ([bool] $c.is_mpim)
        try {
            $r = Invoke-SlackApi -Method 'conversations.history' -Query @{
                channel = $c.id; oldest = $SinceTs; limit = $MaxPerChannel; inclusive = 'false'
            }
        }
        catch {
            # not_in_channel / missing_scope は会話ごとに出る。1つで全体を止めない。
            # 呼び出し側が「次回もう一度読むべきか」を判断できるよう、Slack のコードを添える。
            $msg = $_.Exception.Message
            $code = ''
            if ($msg -match ':\s*([a-z_]+)\s*$') { $code = $Matches[1] }
            $errors += [pscustomobject]@{
                channel   = [string] $c.id
                code      = $code
                message   = $msg
                permanent = (Test-SlackPermanentError $code)
            }
            continue
        }

        foreach ($m in @($r.messages)) {
            # 静かなチャンネルでは messages が返らない。@($null) 由来の空要素を
            # そのまま通すと、ts も本文も無いイベントが DM に立つ。
            if (-not $m) { continue }
            # 参加・退出などの雑音と、自分自身の発言は見ない
            if ($m.subtype -and $m.subtype -ne 'thread_broadcast') { continue }
            if ($self -and [string] $m.user -eq $self) { continue }

            $threadTs = if ($m.thread_ts) { [string] $m.thread_ts } else { [string] $m.ts }
            $reason = $null
            if ($isDm) { $reason = 'dm' }
            # <@U123> と <@U123|name> の両方。前方一致で見ると別人の
            # <@U1234> まで拾ってしまうので、閉じ括弧か | まで見る。
            elseif ($self -and ([string] $m.text) -match ('<@' + [regex]::Escape($self) + '[>|]')) { $reason = 'mention' }
            elseif ($known.ContainsKey((ConvertTo-SlackThreadKey $c.id $threadTs))) { $reason = 'thread' }
            if (-not $reason) { continue }

            $hits += [pscustomobject]@{
                channel   = [string] $c.id
                isDm      = $isDm
                ts        = [string] $m.ts
                threadTs  = $threadTs
                user      = [string] $m.user
                text      = [string] $m.text
                reason    = $reason
            }
        }
    }

    return [pscustomobject]@{
        messages = @($hits | Sort-Object { [double] $_.ts })
        errors   = @($errors)
    }
}

# ---------------------------------------------------------------- 投稿

function Get-SlackTarget {
    <#
      .SYNOPSIS
        通知のリンクから「どこに返すか」を決める。表示用の名前も一緒に返す。
      .OUTPUTS
        [pscustomobject] channel / channelName / threadTs  (解釈できなければ $null)
    #>
    param([Parameter(Mandatory)] [string] $Link)
    $ref = ConvertFrom-SlackLink $Link
    if (-not $ref) { return $null }
    return [pscustomobject]@{
        channel     = $ref.channel
        channelName = (Resolve-SlackChannel $ref.channel)
        threadTs    = $ref.threadTs
    }
}

function Send-SlackMessage {
    <#
      .SYNOPSIS
        Slack に投稿する。取り消せないので、呼び出し側は必ず承認を取ってから呼ぶこと。
      .PARAMETER ThreadTs
        指定するとスレッドへの返信になる。省略するとチャンネルへの新規投稿。
      .OUTPUTS
        [pscustomobject] ts / channel / permalink
    #>
    param(
        [Parameter(Mandatory)] [string] $Channel,
        [Parameter(Mandatory)] [string] $Text,
        [string] $ThreadTs
    )
    if (-not $Text.Trim()) { throw '本文が空です。' }

    $body = @{ channel = $Channel; text = $Text }
    if ($ThreadTs) { $body['thread_ts'] = $ThreadTs }
    $r = Invoke-SlackApiPost -Method 'chat.postMessage' -Body $body

    $permalink = ''
    try {
        $p = Invoke-SlackApi -Method 'chat.getPermalink' -Query @{ channel = $r.channel; message_ts = $r.ts }
        $permalink = $p.permalink
    } catch { }
    return [pscustomobject]@{ ts = $r.ts; channel = $r.channel; permalink = $permalink }
}
