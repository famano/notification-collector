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

$script:MaxSourceChars = 20000

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
          ok / kind / text / attachments / identifiers / links / note
        attachments: @{ id; name; mimeType; size } — fetch_attachment の id になる
        identifiers: モデルが http_request で叩くときに使う主キー類
    #>
    # AllowNull が無いと、すぐ下の「元の通知がありません」の枝に到達できない。
    # Mandatory だけでは $null が束縛エラーになるためで、書いてあるのに効かない
    # ガードになっていた。いまは呼び出し側が全部 $null を弾いているので表には
    # 出ていないが、その前提が崩れたときに例外で止まるのは割に合わない。
    param([Parameter(Mandatory)] [AllowNull()] $Evt)

    $empty = [pscustomobject]@{
        ok = $false; kind = 'none'; text = ''; attachments = @(); identifiers = @{}; links = @(); note = ''
    }
    if (-not $Evt) {
        $empty.note = 'このカードには元の通知がありません (手で起票されたカードです)。'
        return $empty
    }

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
        return [pscustomobject]@{
            ok = [bool] $text.Trim(); kind = 'gmail'
            text = Limit-SourceText $text
            attachments = $atts
            identifiers = $ids
            links = Get-LinksFromText $text
            note = $(if ($text.Trim()) { '' } else { 'スレッドは取得できましたが本文が空でした。' })
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
        [string] $Name
    )
    $parts = $AttachmentId -split ':', 3
    $kind = $parts[0]

    if ($kind -eq 'gmail') {
        if ($parts.Count -lt 3) { throw "添付の指定が不正です: $AttachmentId" }
        $bytes = Get-GmailAttachmentBytes -MessageId $parts[1] -AttachmentId $parts[2]
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
    if (@('.txt', '.md', '.csv', '.json', '.xml', '.ics', '.html', '.htm', '.log') -contains $ext) {
        try { $text = [Text.Encoding]::UTF8.GetString($bytes) } catch { }
        if ($ext -eq '.html' -or $ext -eq '.htm') {
            if (Get-Command ConvertFrom-HtmlToText -ErrorAction SilentlyContinue) { $text = ConvertFrom-HtmlToText $text }
        }
    }
    return [pscustomobject]@{ path = $full; name = $safe; bytes = $bytes.Length; text = Limit-SourceText $text 8000 }
}
