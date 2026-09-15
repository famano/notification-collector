# SourceAccess.ps1
# カードの出自を「ワーカーの実行時に」取り直す。
#
# なぜ要るか:
#   これまで本文は同期した時点のものが全てで、ワーカーは足りなくても取り直せなかった。
#   実際の完了カードを洗うと、その結果はほぼ全部これになっていた ——
#   「Gmail でスレッドを開いてご確認ください」「そのセッションを開いてください」。
#   元通知を見ずに済ませるというこのアプリの前提と、正面から反する出力である。
#
#   取り直しは同期の仕事ではない。同期は「何が来たか」を落とさないための経路で、
#   1件を深く掘るのには向かない (全件に対して常時やるには重すぎる)。
#   必要になった1枚についてだけ深く取る口が別に要る。それがここ。

# 一つの連携先に複数のアカウントが繋がっていることがある。どのトークンで取り直し、
# どの名義で返すかは、カードの元イベントに残っている account_id が決める。
. "$PSScriptRoot\..\..\phase5\lib\AccountStore.ps1"
# 「このカードで、あなたは誰か」。名義を本文から推測させないための束縛。
. "$PSScriptRoot\Viewer.ps1"

$script:MaxSourceChars = 20000

# メールを持つ連携先。「本人のアドレス」を集める範囲。
#
# 立場 (宛先か Cc か) を見るときは、カードが届いたアカウントだけでは足りない。
# 仕事用の Gmail と Outlook を両方繋いでいれば、Outlook 宛のメールが Gmail にも
# 届く (両方が宛先、転送、メーリングリスト)。片方しか見ないと、本人宛のメールを
# 「宛先は他人」と読んで、横で見ているだけの扱いにしてしまう。
$script:MailAccountServices = @('google', 'microsoft')

function Get-SelfMailNames {
    <#
      .SYNOPSIS
        繋いである全アカウントの名前 (メールを持つ連携先のぶん)。
      .DESCRIPTION
        名義には使わない。名義はカードが届いたアカウント1つで、返信もそこから出る。
        ここで集めるのは「そのアドレスは本人か」を見るためだけのもの。
      .OUTPUTS
        [string[]]
    #>
    $out = @()
    if (-not (Get-Command Get-SelfAccountNames -ErrorAction SilentlyContinue)) { return @() }
    foreach ($svc in $script:MailAccountServices) {
        foreach ($n in @(Get-SelfAccountNames -Service $svc)) {
            if ($n -and ($out -notcontains $n)) { $out += $n }
        }
    }
    return @($out)
}

function Limit-SourceText {
    param([string] $Text, [int] $Max = 0)
    if ($Max -le 0) { $Max = $script:MaxSourceChars }
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "`n…(長いため以降を省略)"
}

# 本文に出てくる https リンク。
# これがモデルにとっての「次に叩く先」になる。GitHub の招待 URL、
# 確認リンク、ドキュメントの場所などは本文の中にしか無い。
function Get-LinksFromText {
    param([string] $Text, [int] $Max = 20)
    if (-not $Text) { return @() }
    $seen = [System.Collections.Specialized.OrderedDictionary]::new()
    foreach ($m in [regex]::Matches($Text, 'https?://[^\s<>"''\)\]]+')) {
        $u = $m.Value.TrimEnd('.', ',', '。', '、', '>')
        if (-not $seen.Contains($u)) { [void] $seen.Add($u, $true) }
        if ($seen.Count -ge $Max) { break }
    }
    return @($seen.Keys)
}

# ---------------------------------------------------------------- Claude セッション
#
# 完了カードの最大勢力が「Claude のセッションが入力待ちです」という通知だった。
# 本文は 20 文字 (「Claudeが続行するには入力が必要です」) しかなく、
# 肝心の「何を訊かれているか」がカードに入っていない。何を足しても閉じられない。
#
# ただしトーストの title はセッション名で、デスクトップ版が持つセッション一覧
# (local_*.json) の title と一致する。そこから cliSessionId が引け、
# 会話の実体は ~/.claude/projects/<cwd>/<cliSessionId>.jsonl にある。
# つまり「待機中の問いかけ」はローカルで読める。

function Get-ClaudeSessionIndex {
    <#
      .OUTPUTS
        @{ title; cliSessionId; cwd; lastActivityAt } の配列 (新しい順)
    #>
    $root = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
    if (-not (Test-Path $root)) { return @() }
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'local_*.json' -ErrorAction SilentlyContinue)) {
        try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $j.cliSessionId) { continue }
        $out += [pscustomobject]@{
            title          = [string] $j.title
            cliSessionId   = [string] $j.cliSessionId
            cwd            = [string] $j.cwd
            lastActivityAt = [long] $(if ($j.lastActivityAt) { $j.lastActivityAt } else { 0 })
        }
    }
    return @($out | Sort-Object lastActivityAt -Descending)
}

function Find-ClaudeTranscript {
    param([Parameter(Mandatory)] [string] $CliSessionId)
    $root = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path $root)) { return '' }
    $hit = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter ($CliSessionId + '.jsonl') -ErrorAction SilentlyContinue)
    if ($hit.Count -eq 0) { return '' }
    return $hit[0].FullName
}

function Get-ClaudeSessionTail {
    <#
      .SYNOPSIS
        会話の末尾から「待機中の問いかけ」と直近のやり取りを取り出す。
      .DESCRIPTION
        末尾の assistant 発話が、そのセッションが利用者に返している問いかけそのもの。
        これがカードに載れば、利用者はセッションを開かずに何を訊かれているか分かる。
    #>
    param(
        [Parameter(Mandatory)] [string] $TranscriptPath,
        [int] $TurnsBack = 6
    )
    $lines = @(Get-Content -LiteralPath $TranscriptPath -Encoding UTF8 -ErrorAction Stop)
    $turns = @()
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $o = $null
        try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($o.type -ne 'assistant' -and $o.type -ne 'user') { continue }
        $text = ''
        $c = $o.message.content
        if ($c -is [string]) { $text = $c }
        else { $text = (@($c | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string] $_.text }) -join "`n") }
        if (-not $text.Trim()) { continue }
        # ツール結果の差し戻しや system-reminder は会話ではないので落とす
        if ($text -match '^\s*<(system-reminder|command-name|local-command)') { continue }
        $turns = , [pscustomobject]@{ role = $o.type; text = $text.Trim() } + $turns
        if ($turns.Count -ge $TurnsBack) { break }
    }
    if ($turns.Count -eq 0) { return $null }

    $pending = ''
    for ($i = $turns.Count - 1; $i -ge 0; $i--) {
        if ($turns[$i].role -eq 'assistant') { $pending = $turns[$i].text; break }
    }
    $convo = ($turns | ForEach-Object {
        $who = if ($_.role -eq 'assistant') { 'Claude' } else { '利用者' }
        "[$who]`n$($_.text)"
    }) -join "`n`n"

    return [pscustomobject]@{ pending = $pending; conversation = $convo; turns = $turns.Count }
}

function Get-ClaudeSessionContext {
    <#
      .SYNOPSIS
        「Claude が入力待ち」通知から、待機中の問いかけを引く。
    #>
    param([Parameter(Mandatory)] [string] $SessionTitle)

    $idx = @(Get-ClaudeSessionIndex)
    if ($idx.Count -eq 0) {
        return [pscustomobject]@{
            ok = $false
            note = 'このPCにデスクトップ版 Claude のセッション一覧が見つかりませんでした。'
        }
    }
    $hit = @($idx | Where-Object { $_.title -eq $SessionTitle })
    if ($hit.Count -eq 0) {
        # 完全一致しないときだけ前方一致に落とす。別セッションを誤って読むほうが害が大きい。
        $hit = @($idx | Where-Object { $_.title -and ($SessionTitle.StartsWith($_.title) -or $_.title.StartsWith($SessionTitle)) })
    }
    if ($hit.Count -eq 0) {
        $known = (@($idx | Select-Object -First 8 | ForEach-Object { '「' + $_.title + '」' }) -join '、')
        return [pscustomobject]@{
            ok = $false
            note = ("「{0}」に一致するローカルのセッションがありません。このPCで見えているのは {1} です。" -f $SessionTitle, $known) +
                   'クラウド側 (Cowork) のセッションはローカルに会話が残らないため、ここからは読めません。'
        }
    }

    $s = $hit[0]
    $path = Find-ClaudeTranscript -CliSessionId $s.cliSessionId
    if (-not $path) {
        return [pscustomobject]@{
            ok = $false
            note = ("セッション「{0}」は見つかりましたが、会話の記録が見つかりませんでした。" -f $s.title)
        }
    }
    $tail = Get-ClaudeSessionTail -TranscriptPath $path
    if (-not $tail) {
        return [pscustomobject]@{ ok = $false; note = '会話の記録が空でした。' }
    }
    return [pscustomobject]@{
        ok           = $true
        title        = $s.title
        cwd          = $s.cwd
        cliSessionId = $s.cliSessionId
        pending      = $tail.pending
        conversation = $tail.conversation
        path         = $path
    }
}

# ---------------------------------------------------------------- 統合入口

function Get-SourceContext {
    <#
      .SYNOPSIS
        カードの元イベントから、いま取れる限りの出自を取り直す。
      .OUTPUTS
        [pscustomobject]
          ok / kind / text / attachments / identifiers / links / note / viewer
        attachments: @{ id; name; mimeType; size } — fetch_attachment の id になる
        identifiers: モデルが http_request で叩くときに使う主キー類
        viewer:      このカードでの「あなた」(名義と立場)。Viewer.ps1 を参照
    #>
    # AllowNull が無いと、すぐ下の「元の通知がありません」の枝に到達できない。
    # Mandatory だけでは $null が束縛エラーになるためで、書いてあるのに効かない
    # ガードになっていた。いまは呼び出し側が全部 $null を弾いているので表には
    # 出ていないが、その前提が崩れたときに例外で止まるのは割に合わない。
    param([Parameter(Mandatory)] [AllowNull()] $Evt)

    $empty = [pscustomobject]@{
        ok = $false; kind = 'none'; text = ''; attachments = @(); identifiers = @{}; links = @(); note = ''
        viewer = $null
    }
    if (-not $Evt) {
        $empty.note = 'このカードには元の通知がありません (手で起票されたカードです)。'
        return $empty
    }
    # 取り直しは必ずそのカードのアカウントで行う。呼び出し側が忘れても
    # ここで束縛されるようにしておく (忘れた場合の症状が「別の人のメールが載る」)。
    $boundService = Use-EventAccount -Evt $Evt

    # そのアカウントで「自分は誰か」。ここで一度だけ決めて、下の各経路が
    # 立場 (宛先か Cc か) を足す。本文から名義を推測させないための材料で、
    # 取り直せたかどうかとは無関係に必要になる。
    $selfWho = ''
    $selfLabel = ''
    # 立場の判定に使うぶん。名義 (selfWho) とは別で、繋いである全アカウントを見る。
    $selfNames = @()
    if ($boundService) {
        $acctId = [string] $Evt['account_id']
        $selfWho = Get-SelfAccountName -Service $boundService -Id $acctId
        $acct = Get-ServiceAccount -Service $boundService -Id $acctId
        if ($acct) { $selfLabel = [string] $acct.label }
        if ($script:MailAccountServices -contains $boundService) { $selfNames = @(Get-SelfMailNames) }
    }
    # アカウントを持たない経路 (トースト通知・手起票) では名義の話にならないので $null。
    $memberViewer = $null
    if ($boundService) {
        $memberViewer = New-Viewer -Who $selfWho -Label $selfLabel -Role 'member' -Service $boundService
    }
    $empty.viewer = $memberViewer

    $source = [string] $Evt['source']
    $app    = [string] $Evt['app']
    $link   = [string] $Evt['link']
    $raw    = $null
    if ($Evt['raw_json']) { try { $raw = [string] $Evt['raw_json'] | ConvertFrom-Json } catch { } }

    # ---- Gmail
    if ($source -eq 'gmail') {
        if (-not ((Get-Command Test-GmailConfigured -ErrorAction SilentlyContinue) -and (Test-GmailConfigured))) {
            $empty.kind = 'gmail'
            $empty.note = 'Gmail 連携が未設定のため取り直せません。'
            return $empty
        }
        $msgId = if ($raw) { [string] $raw.id } else { '' }
        $thrId = if ($raw) { [string] $raw.threadId } else { '' }
        if (-not $msgId -and -not $thrId) {
            $empty.kind = 'gmail'
            $empty.note = 'このカードにメールの識別子が残っていません。'
            return $empty
        }
        $text = ''
        $atts = @()
        $ids  = @{}
        if ($thrId) {
            $t = Get-GmailThread -ThreadId $thrId
            $text = $t.text
            $atts = @($t.attachments | ForEach-Object {
                [pscustomobject]@{
                    id = ('gmail:' + $_.messageId + ':' + $_.attachmentId)
                    name = $_.filename; mimeType = $_.mimeType; size = $_.size
                }
            })
            $ids['threadId'] = $thrId
            $ids['subject']  = $t.subject
        }
        if ($msgId) {
            $m = Get-GmailMessage -MessageId $msgId
            $ids['messageId']   = $m.id
            $ids['rfcMessageId'] = $m.messageId
            $ids['from'] = $m.from; $ids['to'] = $m.to; $ids['cc'] = $m.cc
            if (-not $text) {
                $text = $m.body
                $atts = @($m.attachments | ForEach-Object {
                    [pscustomobject]@{
                        id = ('gmail:' + $m.id + ':' + $_.attachmentId)
                        name = $_.filename; mimeType = $_.mimeType; size = $_.size
                    }
                })
            }
        }
        # 名義。どのメールボックスで見ているかに加えて、**このメールでの立場**を決める。
        # ヘッダが引けなかったとき (スレッドだけ取れた等) は立場を付けない ――
        # 「Cc のはず」と当て推量するくらいなら、分からないと言うほうが害が小さい。
        $viewer = $memberViewer
        if ($ids.ContainsKey('to') -or $ids.ContainsKey('cc')) {
            $viewer = New-MailViewer -Who $selfWho -Label $selfLabel -Service $boundService `
                        -From ([string] $ids['from']) -To ([string] $ids['to']) -Cc ([string] $ids['cc']) `
                        -SelfNames $selfNames
        }
        return [pscustomobject]@{
            ok = [bool] $text.Trim(); kind = 'gmail'
            text = Limit-SourceText $text
            attachments = $atts
            identifiers = $ids
            links = Get-LinksFromText $text
            viewer = $viewer
            note = $(if ($text.Trim()) { '' } else { 'スレッドは取得できましたが本文が空でした。' })
        }
    }

    # ---- Outlook
    if ($source -eq 'outlook') {
        if (-not ((Get-Command Test-GraphConfigured -ErrorAction SilentlyContinue) -and (Test-GraphConfigured))) {
            $empty.kind = 'outlook'
            $empty.note = 'Microsoft 365 連携が未設定のため取り直せません。'
            return $empty
        }
        $msgId = if ($raw) { [string] $raw.id } else { '' }
        $convId = if ($raw) { [string] $raw.conversationId } else { '' }
        if (-not $msgId -and -not $convId) {
            $empty.kind = 'outlook'
            $empty.note = 'このカードにメールの識別子が残っていません。'
            return $empty
        }
        $text = ''
        $atts = @()
        $ids  = @{}
        if ($convId) {
            $t = Get-OutlookThread -ConversationId $convId
            $text = $t.text
            $atts = @($t.attachments | ForEach-Object {
                [pscustomobject]@{
                    id = ('outlook:' + $_.messageId + ':' + $_.attachmentId)
                    name = $_.filename; mimeType = $_.mimeType; size = $_.size
                }
            })
            $ids['conversationId'] = $convId
            $ids['subject'] = $t.subject
        }
        if ($msgId) {
            $m = Get-OutlookMessage -MessageId $msgId
            $ids['messageId'] = $m.id
            $ids['rfcMessageId'] = $m.messageId
            $ids['from'] = $m.from; $ids['to'] = $m.to; $ids['cc'] = $m.cc
            if (-not $text) {
                $text = $m.body
                $atts = @()
                if ($m.hasAttachments) {
                    $atts = @(Get-OutlookAttachmentList -MessageId $m.id | ForEach-Object {
                        [pscustomobject]@{
                            id = ('outlook:' + $m.id + ':' + $_.attachmentId)
                            name = $_.filename; mimeType = $_.mimeType; size = $_.size
                        }
                    })
                }
            }
        }
        # Gmail と同じ。名義と立場は経路で変わらないので、同じ形で渡す。
        $viewer = $memberViewer
        if ($ids.ContainsKey('to') -or $ids.ContainsKey('cc')) {
            $viewer = New-MailViewer -Who $selfWho -Label $selfLabel -Service $boundService `
                        -From ([string] $ids['from']) -To ([string] $ids['to']) -Cc ([string] $ids['cc']) `
                        -SelfNames $selfNames
        }
        return [pscustomobject]@{
            ok = [bool] $text.Trim(); kind = 'outlook'
            text = Limit-SourceText $text
            attachments = $atts
            identifiers = $ids
            links = Get-LinksFromText $text
            viewer = $viewer
            note = $(if ($text.Trim()) { '' } else { 'スレッドは取得できましたが本文が空でした。' })
        }
    }

    # ---- Teams
    if ($link -like 'msteams://*') {
        if (-not ((Get-Command Test-GraphConfigured -ErrorAction SilentlyContinue) -and (Test-GraphConfigured))) {
            $empty.kind = 'teams'
            $empty.note = 'Microsoft 365 連携が未設定のため取り直せません。'
            return $empty
        }
        $t = Get-TeamsThread -Link $link
        if (-not $t) {
            $empty.kind = 'teams'
            $empty.note = 'このリンクから Teams のチャットを特定できませんでした。'
            return $empty
        }
        $ref = ConvertFrom-TeamsLink $link
        # チャットの添付は本体ではなく SharePoint / OneDrive 上のファイルへの参照で、
        # 別の権限 (Files.Read) が要る。ここでは一覧に出さず、本文中のリンクとして渡す。
        return [pscustomobject]@{
            ok = $true; kind = 'teams'
            text = Limit-SourceText $t.text
            attachments = @()
            identifiers = @{
                chatId    = $ref.chatId
                messageId = $ref.messageId
                permalink = $t.permalink
            }
            links = Get-LinksFromText $t.text
            viewer = $memberViewer
            note = ''
        }
    }

    # ---- Chatwork
    if ($source -eq 'chatwork') {
        if (-not ((Get-Command Test-ChatworkConfigured -ErrorAction SilentlyContinue) -and (Test-ChatworkConfigured))) {
            $empty.kind = 'chatwork'
            $empty.note = 'Chatwork 連携が未設定のため取り直せません。'
            return $empty
        }
        $t = Get-ChatworkThread -Link $link
        if (-not $t) {
            $empty.kind = 'chatwork'
            $empty.note = 'このリンクから Chatwork の部屋を特定できませんでした。'
            return $empty
        }
        $ref = ConvertFrom-ChatworkLink $link
        $ids = @{ roomId = $ref.roomId; messageId = $ref.messageId; permalink = $t.permalink }
        if ($raw -and $raw.accountId) { $ids['senderAccountId'] = [string] $raw.accountId }
        return [pscustomobject]@{
            ok = $true; kind = 'chatwork'
            text = Limit-SourceText $t.text
            attachments = @()
            identifiers = $ids
            links = Get-LinksFromText $t.text
            viewer = $memberViewer
            note = ''
        }
    }

    # ---- Backlog
    if ($source -eq 'backlog') {
        if (-not ((Get-Command Test-BacklogConfigured -ErrorAction SilentlyContinue) -and (Test-BacklogConfigured))) {
            $empty.kind = 'backlog'
            $empty.note = 'Backlog 連携が未設定のため取り直せません。'
            return $empty
        }
        $key = ''
        if ($raw -and $raw.issueKey) { $key = [string] $raw.issueKey }
        if (-not $key) {
            $ref = ConvertFrom-BacklogLink $link
            if ($ref) { $key = $ref.issueKey }
        }
        if (-not $key) {
            $empty.kind = 'backlog'
            $empty.note = 'このカードに課題の識別子が残っていません。'
            return $empty
        }
        $c = Get-BacklogIssueContext -IssueKey $key
        return [pscustomobject]@{
            ok = [bool] $c.text.Trim(); kind = 'backlog'
            text = Limit-SourceText $c.text
            attachments = @()
            identifiers = @{ issueKey = $c.issueKey; summary = $c.summary; permalink = $c.permalink }
            links = Get-LinksFromText $c.text
            viewer = $memberViewer
            note = ''
        }
    }

    # ---- Slack
    if ($link -like 'slack://*') {
        if (-not ((Get-Command Test-SlackConfigured -ErrorAction SilentlyContinue) -and (Test-SlackConfigured))) {
            $empty.kind = 'slack'
            $empty.note = 'Slack 連携が未設定のため取り直せません。'
            return $empty
        }
        $t = Get-SlackThread -Link $link
        if (-not $t) {
            $empty.kind = 'slack'
            $empty.note = 'このリンクから Slack のスレッドを特定できませんでした。'
            return $empty
        }
        $ref = ConvertFrom-SlackLink $link
        $atts = @()
        if (Get-Command Get-SlackThreadFiles -ErrorAction SilentlyContinue) {
            $atts = @(Get-SlackThreadFiles -Link $link | ForEach-Object {
                [pscustomobject]@{
                    id = ('slack:' + $_.id); name = $_.name; mimeType = $_.mimetype; size = $_.size
                }
            })
        }
        return [pscustomobject]@{
            ok = $true; kind = 'slack'
            text = Limit-SourceText $t.text
            attachments = $atts
            identifiers = @{
                channel   = $ref.channel
                threadTs  = $ref.threadTs
                messageTs = $ref.messageTs
                permalink = $t.permalink
            }
            links = Get-LinksFromText $t.text
            viewer = $memberViewer
            note = ''
        }
    }

    # ---- Claude セッションの入力待ち
    if ($app -like 'Claude*') {
        $title = if ($raw -and $raw.title) { [string] $raw.title } else { [string] $Evt['title'] }
        $c = Get-ClaudeSessionContext -SessionTitle $title
        if (-not $c.ok) {
            $empty.kind = 'claude-session'
            $empty.note = $c.note
            return $empty
        }
        $text = "セッション「$($c.title)」($($c.cwd))`n`n" +
                "=== 待機中の問いかけ ===`n$($c.pending)`n`n" +
                "=== 直近のやり取り ===`n$($c.conversation)"
        return [pscustomobject]@{
            ok = $true; kind = 'claude-session'
            text = Limit-SourceText $text
            attachments = @()
            identifiers = @{ cwd = $c.cwd; cliSessionId = $c.cliSessionId; transcript = $c.path }
            links = @()
            viewer = $memberViewer
            note = 'この問いかけへの答えは、カードの「対応の記録」に書いても相手のセッションには届きません。セッションを開いて貼る必要があります。'
        }
    }

    # ---- それ以外の通知 (Chrome, OneDrive, システムトースト等)
    $empty.kind = 'notification'
    $empty.text = [string] $Evt['body']
    $empty.links = Get-LinksFromText ([string] $Evt['body'])
    $empty.ok = [bool] $empty.text
    $empty.note = 'この通知の発信元には取り直せる API がありません。通知に入っていた内容が全てです。'
    return $empty
}

# ---------------------------------------------------------------- 添付の取得

function Get-SourceAttachment {
    <#
      .SYNOPSIS
        添付1件を作業フォルダに落とし、テキストなら中身も返す。
      .PARAMETER AttachmentId
        Get-SourceContext が返した attachments[].id
    #>
    param(
        [Parameter(Mandatory)] [string] $AttachmentId,
        [Parameter(Mandatory)] [string] $Workspace,
        [string] $Name,
        # 元の MIME 型。拡張子が無い添付でも、テキストなら中身を返せるようにする。
        [string] $MimeType
    )
    $parts = $AttachmentId -split ':', 3
    $kind = $parts[0]

    if ($kind -eq 'gmail') {
        if ($parts.Count -lt 3) { throw "添付の指定が不正です: $AttachmentId" }
        $bytes = Get-GmailAttachmentBytes -MessageId $parts[1] -AttachmentId $parts[2]
    }
    elseif ($kind -eq 'outlook') {
        if ($parts.Count -lt 3) { throw "添付の指定が不正です: $AttachmentId" }
        if (-not (Get-Command Get-OutlookAttachmentBytes -ErrorAction SilentlyContinue)) { throw 'Microsoft 365 連携が未設定です。' }
        $bytes = Get-OutlookAttachmentBytes -MessageId $parts[1] -AttachmentId $parts[2]
    }
    elseif ($kind -eq 'slack') {
        if (-not (Get-Command Get-SlackFileBytes -ErrorAction SilentlyContinue)) { throw 'Slack 連携が未設定です。' }
        $bytes = Get-SlackFileBytes -FileId $parts[1]
    }
    else { throw "未知の添付です: $AttachmentId" }

    if (-not $Name) { $Name = 'attachment.bin' }
    # パス区切りを含む名前を渡されても作業フォルダの外に出さない
    $safe = [IO.Path]::GetFileName($Name)
    if (-not $safe) { $safe = 'attachment.bin' }
    $full = Join-Path $Workspace $safe
    [IO.File]::WriteAllBytes($full, $bytes)

    $text = ''
    $ext = [IO.Path]::GetExtension($safe).ToLower()
    # 拡張子で見て、無ければ MIME 型で見る。添付の名前は付いていないことがある。
    $isText = (@('.txt', '.md', '.csv', '.json', '.xml', '.ics', '.html', '.htm', '.log') -contains $ext) -or
              ($MimeType -and ($MimeType -like 'text/*' -or $MimeType -like '*json*' -or $MimeType -like '*xml*'))
    if ($isText) {
        try { $text = [Text.Encoding]::UTF8.GetString($bytes) } catch { }
        if ($ext -eq '.html' -or $ext -eq '.htm' -or $MimeType -like 'text/html*') {
            if (Get-Command ConvertFrom-HtmlToText -ErrorAction SilentlyContinue) { $text = ConvertFrom-HtmlToText $text }
        }
    }
    return [pscustomobject]@{ path = $full; name = $safe; bytes = $bytes.Length; text = Limit-SourceText $text 8000 }
}
