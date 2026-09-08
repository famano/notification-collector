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
    return [bool] (Get-Secret -Name 'slack.botToken')
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
    $token = Get-Secret -Name 'slack.botToken'
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
    $token = Get-Secret -Name 'slack.botToken'
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

function Resolve-SlackChannel {
    param([string] $ChannelId)
    try {
        $c = Invoke-SlackApi -Method 'conversations.info' -Query @{ channel = $ChannelId }
        if ($c.channel.is_im) { return 'ダイレクトメッセージ' }
        return '#' + $c.channel.name
    }
    catch { return $ChannelId }
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
