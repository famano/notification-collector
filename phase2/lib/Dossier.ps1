# Dossier.ps1
# 「同じ件」をまとめ、その件について分かったことを持ち越す。
#
# なぜ要るか:
#   完了カードを洗うと、llm-dd の CI 失敗が5枚立っていた。5枚とも別々に
#   ゼロから調査を始め、5枚とも同じ 404 (非公開リポジトリで権限が無い) に
#   ぶつかり、5枚とも別々のメモを書いて終わっていた。4枚は件名まで完全に同じで、
#   残る1枚もコミットハッシュが違うだけ。
#
#   イベント単位の dedup_key は「同じメッセージか」を見るので、これは弾けない。
#   別々のメールであることは事実だからである。必要なのは一段上の
#   「同じ件か」という軸 ―― それが subject_key。
#
#   そして件ごとに「前回こう分かった」を残す。これが無いと、権限が無いという
#   同じ結論に毎回コストを払って再到達することになる。

# 件名から、回ごとに変わる部分を落とす。
# 「Run failed: Security - main (c5857b6)」と「… (515c237)」を同じ件として扱いたい。
function ConvertTo-SubjectStem {
    param([string] $Text)
    if (-not $Text) { return '' }
    $t = $Text.ToLower()
    # 返信・転送の接頭辞
    $t = $t -replace '^\s*((re|fwd|fw)\s*:\s*)+', ''
    # 括弧つきの短いハッシュ (コミット等)
    $t = $t -replace '\([0-9a-f]{6,40}\)', ''
    # 素のハッシュ・ID らしき英数字の連なり
    $t = $t -replace '\b[0-9a-f]{7,40}\b', ''
    # 日付・時刻・連番
    $t = $t -replace '\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?', ''
    $t = $t -replace '\d{1,2}:\d{2}(:\d{2})?', ''
    $t = $t -replace '#\d+', ''
    $t = $t -replace '\d+', ''
    # 記号と空白を潰す
    $t = $t -replace '[\s\p{P}\p{S}]+', ' '
    return $t.Trim()
}

function Get-MailSender {
    param([string] $Body)
    if ($Body -match '(?m)^差出人:\s*(.+)$') {
        $line = $Matches[1]
        if ($line -match '<([^>]+)>') { return $Matches[1].ToLower() }
        return $line.Trim().ToLower()
    }
    return ''
}

function Get-SubjectKey {
    <#
      .SYNOPSIS
        「同じ件」を表すキー。イベントではなく案件の同一性。
      .DESCRIPTION
        同じキーのカードが既に開いていれば、新しいカードを立てずに
        回数を足す。閉じたあとに再発したら、前回の知見を引き継いで立て直す。
    #>
    param([Parameter(Mandatory)] $Evt)
    if (-not $Evt) { return '' }

    $source = [string] $Evt['source']
    $app    = [string] $Evt['app']
    $link   = [string] $Evt['link']
    $title  = [string] $Evt['title']
    $body   = [string] $Evt['body']

    # Claude のセッション入力待ち: セッション名が件。
    # 同じセッションが何度入力待ちになっても、利用者にとっては1件の用事。
    if ($app -like 'Claude*') {
        return 'claude-session:' + (ConvertTo-SubjectStem $title)
    }

    # Slack: スレッドが件。
    #
    # 解決できなければキーを付けない。Slack 通知の title はチャンネル名なので、
    # それを件名代わりに使うと #tech-salesforce の全メッセージが1件に
    # まとまってしまう。束ね損ねるのは1枚余計に立つだけだが、
    # 束ねすぎると無関係な用事が1枚に潰れて取り返しがつかない。
    if ($link -like 'slack://*') {
        if (Get-Command ConvertFrom-SlackLink -ErrorAction SilentlyContinue) {
            $ref = ConvertFrom-SlackLink $link
            if ($ref) { return ('slack-thread:{0}:{1}' -f $ref.channel, $ref.threadTs) }
        }
        return ''
    }

    if ($source -eq 'gmail') {
        $from = Get-MailSender $body
        $stem = ConvertTo-SubjectStem $title
        if (-not $stem) { return '' }
        # 差出人を混ぜる。同じ件名でも別の相手なら別の件。
        return ('mail:{0}:{1}' -f $from, $stem)
    }

    # 通知は「アプリ名 + 件名」。件名が無い、あるいは正規化で消えてしまう
    # (数字と記号だけ) 場合はキーを付けない。同じアプリというだけで
    # 束ねると、無関係な通知が1枚に潰れる。
    $stem = ConvertTo-SubjectStem $title
    if (-not $stem) { return '' }
    return ('notice:{0}:{1}' -f $app, $stem)
}

# ---------------------------------------------------------------- 台帳

function Add-DossierNote {
    <#
      .SYNOPSIS
        この件について分かったことを残す。次に同じ件が来たときに読まれる。
    #>
    param(
        [Parameter(Mandatory)] $Conn,
        # 件のキーは付かないことがある (Slack のリンクが解けない、件名が無い等)。
        # AllowEmptyString が無いと、下の「キーが無ければ書かない」に到達する前に
        # 束縛エラーで落ちる。いまは呼び出し側が全部 if で弾いているので表には
        # 出ていないが、弾き忘れた1箇所でワーカーが例外で止まることになる。
        # 「空なら何もしない」をここで1回守るほうが漏れない。
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $SubjectKey,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Note,
        [int] $TaskId = 0,
        [string] $Kind = 'finding'
    )
    if (-not $SubjectKey -or -not $Note.Trim()) { return $false }
    [void] $Conn.NonQuery(
        'INSERT INTO dossier (subject_key, task_id, kind, note, created_at) VALUES (?, ?, ?, ?, ?)',
        [object[]] @($SubjectKey, $(if ($TaskId) { $TaskId } else { $null }), $Kind, $Note, (Get-Date).ToString('o')))
    return $true
}

function Get-DossierNotes {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $SubjectKey,
        [int] $Limit = 20
    )
    if (-not $SubjectKey) { return @() }
    return @($Conn.Query(
        'SELECT * FROM dossier WHERE subject_key = ? ORDER BY id DESC LIMIT ?',
        [object[]] @($SubjectKey, $Limit)))
}

function Get-DossierText {
    <#
      .SYNOPSIS
        台帳をワーカーに渡せる形の文章にする。
    #>
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [AllowEmptyString()] [string] $SubjectKey)
    $notes = @(Get-DossierNotes -Conn $Conn -SubjectKey $SubjectKey)
    if ($notes.Count -eq 0) { return '' }
    $lines = @()
    foreach ($n in $notes) {
        $when = ''
        try { $when = ([DateTime] $n['created_at']).ToString('MM/dd HH:mm') } catch { }
        $lines += ("- [{0}] {1}" -f $when, [string] $n['note'])
    }
    return ($lines -join "`n")
}

function Get-ServiceDossierText {
    <#
      .SYNOPSIS
        サービス単位で分かっていること (主に権限の不足)。
      .DESCRIPTION
        「GitHub のトークンが無い」は特定の件の事実ではなく、そのサービスを
        使う全ての件に効く。件単位の台帳だけに残すと、次に別のリポジトリの
        招待が来たときにまた同じ 401 を踏みに行くことになる。
    #>
    param([Parameter(Mandatory)] $Conn, [int] $Limit = 10)
    $rows = @($Conn.Query(
        "SELECT subject_key, note, MAX(id) AS mid FROM dossier
          WHERE subject_key LIKE 'svc:%'
          GROUP BY subject_key ORDER BY mid DESC LIMIT ?", [object[]] @($Limit)))
    if ($rows.Count -eq 0) { return '' }
    return (($rows | ForEach-Object {
        "- [{0}] {1}" -f (([string] $_['subject_key']) -replace '^svc:', ''), [string] $_['note']
    }) -join "`n")
}

function Get-OpenTaskBySubject {
    <#
      .SYNOPSIS
        同じ件で、まだ閉じていないカード。あればそこに積む。
      .DESCRIPTION
        done / dismissed / アーカイブ済みは対象外。終わった件が再発したなら、
        それは新しいカードとして立てるのが正しい (ただし台帳は引き継ぐ)。
    #>
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [AllowEmptyString()] [string] $SubjectKey)
    if (-not $SubjectKey) { return $null }
    $rows = @($Conn.Query(
        "SELECT * FROM tasks
          WHERE subject_key = ? AND archived_at IS NULL
            AND board_column NOT IN ('done', 'dismissed')
          ORDER BY id DESC LIMIT 1",
        [object[]] @($SubjectKey)))
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

function Add-TaskOccurrence {
    <#
      .SYNOPSIS
        既存のカードに「もう一度来た」を記録する。
      .DESCRIPTION
        カードを増やさない。増やすと、同じ用事が列に何枚も並び、
        利用者はどれを見ればいいのか分からなくなる。
    #>
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [int] $TaskId,
        [string] $EventId
    )
    [void] $Conn.NonQuery(
        'UPDATE tasks SET occurrence_count = COALESCE(occurrence_count, 1) + 1, last_occurred_at = ?, updated_at = ? WHERE id = ?',
        [object[]] @((Get-Date).ToString('o'), (Get-Date).ToString('o'), $TaskId))
    $n = @($Conn.Query('SELECT occurrence_count FROM tasks WHERE id = ?', [object[]] @($TaskId)))
    $count = if ($n.Count -gt 0) { [int] $n[0]['occurrence_count'] } else { 0 }
    return $count
}
