# BacklogConnector.ps1
# Backlog API v2。**「自分宛のお知らせ」がそのまま API になっている**数少ないサービス。
#
# 他の連携は「会話を掃き寄せて、自分に関係があるものを選ぶ」という組み立てが要るが、
# Backlog には `/notifications` があり、担当に設定された・コメントが付いた、といった
# 自分宛の出来事だけが新しい順に返る。選別はサーバ側で済んでいる。
#
# 認証は API キー1本 (個人設定から発行する)。
# **キーはクエリ文字列にしか載せられない** (Backlog の API キー認証は Authorization
# ヘッダを受け付けない)。そのため汎用 HTTP ツールには資格情報を注入しない ――
# 注入するとモデルに見せる URL にキーが載り、「トークンを URL に入れない」という
# 全体の約束を破ることになる。Backlog を叩くのはこのコネクタ経由だけにする。
#
# 既読にはしない。`/notifications/{id}/markAsRead` はあるが、押すと利用者の
# Backlog の画面からお知らせが消える。同期が利用者の画面を書き換えてよい理由はない。
# 「どこまで取ったか」はこちらの watermark で持つ。

. "$PSScriptRoot\SecretStore.ps1"

function Test-BacklogConfigured {
    return [bool] ((Get-Secret -Name 'backlog.apiKey') -and (Get-Secret -Name 'backlog.space'))
}

function Get-BacklogSpace {
    <#
      .SYNOPSIS
        スペースのホスト名 (example.backlog.jp)。入力の揺れをここで吸収する。
    #>
    param([string] $Value)
    $v = $Value
    if (-not $v) { $v = Get-Secret -Name 'backlog.space' }
    if (-not $v) { return '' }
    $v = $v.Trim()
    # https://example.backlog.jp/dashboard のように貼られても受ける
    $v = $v -replace '^https?://', ''
    $v = ($v -split '/')[0]
    return $v.Trim().TrimEnd('.')
}

function Invoke-BacklogApi {
    <#
      .SYNOPSIS
        Backlog を1回叩く。API キーはここでだけ URL に載せる。
      .PARAMETER Query
        クエリ文字列 (apiKey は含めない)。
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'Get',
        [string] $Query,
        [hashtable] $Form
    )
    $key = Get-Secret -Name 'backlog.apiKey'
    $space = Get-BacklogSpace
    if (-not $key -or -not $space) {
        throw 'Backlog が未設定です。カンバンの「接続」から設定してください。'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $url = "https://{0}/api/v2{1}?apiKey={2}" -f $space, $Path, [Uri]::EscapeDataString($key)
    if ($Query) { $url += '&' + $Query }

    $req = @{ Uri = $url; Method = $Method; UseBasicParsing = $true; TimeoutSec = 30 }
    if ($Form) {
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
                try { $raw = $sr.ReadToEnd() } finally { $sr.Dispose() }
                $parsed = $null
                try { $parsed = $raw | ConvertFrom-Json } catch { }
                if ($parsed -and $parsed.errors) {
                    $detail = (@($parsed.errors | ForEach-Object { [string] $_.message }) -join ' / ')
                } else { $detail = $raw }
            } catch { }
        }
        # 文言に API キーを混ぜないこと。URL にキーが載っているので、
        # 例外の文字列をそのまま出すと作業ログと承認画面に残る。
        throw ("Backlog API {0} が失敗しました: {1} (HTTP {2})" -f $Path, $detail, $status)
    }

    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

function Get-BacklogMe {
    $me = Invoke-BacklogApi -Path '/users/myself'
    return [pscustomobject]@{
        id      = [string] $me.id
        name    = [string] $me.name
        account = $(if ($me.mailAddress) { [string] $me.mailAddress } else { [string] $me.userId })
    }
}

# お知らせの理由。数字のままカードに出しても利用者には読めない。
$script:BacklogReasons = @{
    1  = '課題の担当者に設定されました'
    2  = '課題にコメントが付きました'
    3  = '課題が追加されました'
    4  = '課題が更新されました'
    5  = 'ファイルが追加されました'
    6  = 'プロジェクトに追加されました'
    9  = 'お知らせ'
    10 = 'プルリクエストの担当者に設定されました'
    11 = 'プルリクエストにコメントが付きました'
    12 = 'プルリクエストが追加されました'
    13 = 'プルリクエストが更新されました'
}

function Get-BacklogReasonText {
    param($Reason)
    $n = 0
    try { $n = [int] $Reason } catch { }
    if ($script:BacklogReasons.ContainsKey($n)) { return $script:BacklogReasons[$n] }
    return 'お知らせ'
}

function New-BacklogLink {
    param([Parameter(Mandatory)] [string] $IssueKey, [string] $CommentId, [string] $Space)
    $s = Get-BacklogSpace $Space
    $url = "https://{0}/view/{1}" -f $s, $IssueKey
    if ($CommentId) { $url += "#comment-$CommentId" }
    return $url
}

function ConvertFrom-BacklogLink {
    param([string] $Link)
    if (-not $Link) { return $null }
    if ($Link -notmatch '^https?://([^/]+)/view/([A-Za-z0-9_]+-\d+)') { return $null }
    # $Matches は次の -match で丸ごと入れ替わる。先に取り出しておくこと
    # (ここを油断すると issueKey が空になり、コメントの投稿先が消える)。
    $space = $Matches[1]
    $issueKey = $Matches[2]
    $comment = ''
    if ($Link -match '#comment-(\d+)') { $comment = $Matches[1] }
    return [pscustomobject]@{ space = $space; issueKey = $issueKey; commentId = $comment }
}

function ConvertFrom-BacklogNotification {
    <#
      .SYNOPSIS
        お知らせ1件を、このアプリが扱う形にそろえる。
      .DESCRIPTION
        課題のお知らせだけを対象にする。プルリクエストのお知らせは GitHub 側の
        経路と役割が重なるうえ、issueKey が無いので同じ形に落とせない。
        対象外のものは $null を返し、呼び出し側が飛ばす。
    #>
    param([Parameter(Mandatory)] $N)
    $issue = $N.issue
    if (-not $issue -or -not $issue.issueKey) { return $null }

    $when = $null
    try { $when = ([DateTimeOffset] $N.created).LocalDateTime } catch { $when = Get-Date }

    $sender = ''
    if ($N.sender) { $sender = [string] $N.sender.name }
    $comment = ''
    $commentId = ''
    if ($N.comment) {
        $comment = [string] $N.comment.content
        $commentId = [string] $N.comment.id
    }

    return [pscustomobject]@{
        id          = [string] $N.id
        reason      = (Get-BacklogReasonText $N.reason)
        issueKey    = [string] $issue.issueKey
        summary     = [string] $issue.summary
        description = [string] $issue.description
        project     = $(if ($N.project) { [string] $N.project.projectKey } else { '' })
        sender      = $sender
        comment     = $comment
        commentId   = $commentId
        created     = [string] $N.created
        createdAt   = $when
        link        = (New-BacklogLink -IssueKey ([string] $issue.issueKey) -CommentId $commentId)
    }
}

function Get-BacklogNotifications {
    <#
      .SYNOPSIS
        自分宛のお知らせを、前回の続きから古い順に返す。
      .DESCRIPTION
        `/notifications` は新しい順に返る。ここで古い順に並べ替えるのは、
        カードが届いた順に並ぶほうが読みやすく、途中で失敗しても
        「そこまでは取り切った」と言えるため (他の経路と同じ扱い)。
      .OUTPUTS
        [pscustomobject] items / truncated
    #>
    param(
        [Parameter(Mandatory)] [DateTime] $Since,
        [int] $Max = 100
    )
    $count = [Math]::Min(100, $Max)
    $all = @(Invoke-BacklogApi -Path '/notifications' -Query ("count={0}" -f $count))
    $items = @()
    $oldestSeen = $null
    foreach ($n in $all) {
        if (-not $n) { continue }
        $item = ConvertFrom-BacklogNotification $n
        if (-not $item) { continue }
        if (-not $oldestSeen -or $item.createdAt -lt $oldestSeen) { $oldestSeen = $item.createdAt }
        if ($item.createdAt -le $Since) { continue }
        $items += $item
    }

    # 1ページに収まらなかった可能性がある。取り切れていないので
    # 呼び出し側は watermark を進めない (進めると間が飛ぶ)。
    $truncated = ($all.Count -ge $count) -and $oldestSeen -and ($oldestSeen -gt $Since)

    return [pscustomobject]@{
        items     = @($items | Sort-Object created)
        truncated = $truncated
    }
}

function Get-BacklogIssueContext {
    <#
      .SYNOPSIS
        課題の本文と直近のコメントを、読める形にして返す。
      .OUTPUTS
        [pscustomobject] text / issueKey / summary / commentCount / permalink
    #>
    param([Parameter(Mandatory)] [string] $IssueKey, [int] $Limit = 20)

    $issue = Invoke-BacklogApi -Path ("/issues/{0}" -f [Uri]::EscapeDataString($IssueKey))
    $comments = @()
    try {
        # order=asc で古い順。経緯として読むならこちらが自然。
        $comments = @(Invoke-BacklogApi -Path ("/issues/{0}/comments" -f [Uri]::EscapeDataString($IssueKey)) `
                        -Query ("count={0}&order=asc" -f [Math]::Min(100, $Limit)))
    } catch { }

    $head = @()
    $head += ("課題: [{0}] {1}" -f [string] $issue.issueKey, [string] $issue.summary)
    if ($issue.status)   { $head += ("状態: {0}" -f [string] $issue.status.name) }
    if ($issue.assignee) { $head += ("担当: {0}" -f [string] $issue.assignee.name) }
    if ($issue.dueDate)  { $head += ("期限: {0}" -f ([string] $issue.dueDate).Substring(0, 10)) }
    if ($issue.description) { $head += ("`n" + [string] $issue.description) }

    $lines = @()
    foreach ($c in $comments) {
        if (-not $c -or -not $c.content) { continue }   # 状態変更だけのコメントは本文が空
        $when = ''
        try { $when = ([DateTimeOffset] $c.created).LocalDateTime.ToString('MM/dd HH:mm') } catch { }
        $lines += ("[{0}] {1}`n{2}" -f $when, [string] $c.createdUser.name, [string] $c.content)
    }

    $text = ($head -join "`n")
    if ($lines.Count -gt 0) { $text += ("`n`n--- コメント ({0} 件) ---`n" -f $lines.Count) + ($lines -join "`n`n") }

    return [pscustomobject]@{
        text         = $text
        issueKey     = [string] $issue.issueKey
        summary      = [string] $issue.summary
        commentCount = $lines.Count
        permalink    = (New-BacklogLink -IssueKey ([string] $issue.issueKey))
    }
}

function Get-BacklogTarget {
    <#
      .SYNOPSIS
        カードのリンクから「どこに返すか」を決める。
    #>
    param([Parameter(Mandatory)] [string] $Link)
    $ref = ConvertFrom-BacklogLink $Link
    if (-not $ref) { return $null }
    return [pscustomobject]@{ issueKey = $ref.issueKey; commentId = $ref.commentId }
}

function Add-BacklogComment {
    <#
      .SYNOPSIS
        課題にコメントを投稿する。取り消せないので、呼び出し側は必ず承認を取ってから呼ぶこと。
      .DESCRIPTION
        notifiedUserId (投稿を誰に通知するか) は渡さない。渡せる形にすると、
        カードの文面から宛先を作ることになり、「宛先はカードの出自から束縛する」
        という原則を崩す。既定の通知先 (課題の関係者) にだけ届く。
      .OUTPUTS
        [pscustomobject] id / permalink
    #>
    param(
        [Parameter(Mandatory)] [string] $IssueKey,
        [Parameter(Mandatory)] [string] $Content
    )
    if (-not $Content.Trim()) { throw '本文が空です。' }
    $r = Invoke-BacklogApi -Path ("/issues/{0}/comments" -f [Uri]::EscapeDataString($IssueKey)) `
            -Method 'Post' -Form @{ content = $Content }
    $id = [string] $r.id
    return [pscustomobject]@{ id = $id; permalink = (New-BacklogLink -IssueKey $IssueKey -CommentId $id) }
}
