# Memory.ps1
# 利用者について覚えておくこと。件をまたいで効く「その人の事情」。
#
# なぜ要るか:
#   通知をさばくのは、1枚で終わる作業ではない。似た件が何度も来る。
#   そこで同じ間違いを連発されるのが、この仕組みの一番の実害になる ――
#   一度「請求書はいつも下書きまででいい」と言ったのに、次の請求書でも送ろうとする。
#   一度「このプロジェクトは自分の担当ではない」と書いたのに、次も同じ調査をする。
#
#   台帳 (Dossier) は**件**についての記録で、件が変われば引かれない。
#   ここが持つのは**人**についての記録である。誰で、何に関心があり、
#   似た件を前回どう処理したか。件をまたいでも効く。
#
# 長さの扱い:
#   全部を毎回読み込むと、増えるほど邪魔になる (判定の材料が薄まり、費用も増える)。
#   そこで二段で抑える。
#     ・1件を短く保つ  … 200 字で切る。全体の件数にも上限を置き、
#                        使われないものから落とす (profile は別枠で保護する)
#     ・関連するものだけ渡す … カードの文面と突き合わせて、当たったものだけ渡す。
#                        ただし profile (その人が誰か) は常に渡す ―― どの件にも効くため。
#
# 種類は閉じた集合にする。自由記述にすると「何にでも当てはまる一般論」が
# 積もって、関連度で絞れなくなる。
#   profile    … 利用者そのもの。名前・役割・関心事・持ち物。**常に渡す**
#   preference … こう扱ってほしい。「請求書は送らずに下書きまで」
#   how        … 似た件をこう処理した。「この種の招待は API で承諾できた」

$script:MemoryKinds       = @('profile', 'preference', 'how')
$script:MaxMemoryNote     = 200     # 1件の長さ
$script:MaxMemoryTopic    = 40
$script:MaxMemories       = 120     # profile 以外の総数
$script:MaxProfileMemories = 20     # profile の総数 (常に渡るので別枠で絞る)
$script:MemoryPromptChars = 1200    # プロンプトに載せる合計の上限

function Get-MemoryNow { return (Get-Date).ToString('o') }

# ---------------------------------------------------------------- 書く

function Limit-MemoryText {
    param([string] $Text, [int] $Max)
    $t = ([string] $Text).Trim()
    # 改行は潰す。1件1行にしておくと、渡すときも画面に出すときも扱いが揃う。
    $t = $t -replace '\s+', ' '
    if ($t.Length -le $Max) { return $t }
    return $t.Substring(0, $Max)
}

function Test-MemoryKind {
    param([string] $Kind)
    return ($script:MemoryKinds -contains [string] $Kind)
}

function Add-MemoryNote {
    <#
      .SYNOPSIS
        覚える。同じことを二度書かない (重なったら上書きする)。
      .OUTPUTS
        [pscustomobject] ok / id / reason
    #>
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Kind,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Topic,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Note,
        [int] $TaskId = 0
    )
    if (-not (Test-MemoryKind $Kind)) {
        return [pscustomobject]@{ ok = $false; id = 0; reason = ('知らない種類です: ' + $Kind) }
    }
    $note = Limit-MemoryText $Note $script:MaxMemoryNote
    if (-not $note) { return [pscustomobject]@{ ok = $false; id = 0; reason = '中身が空です。' } }
    $topic = Limit-MemoryText $Topic $script:MaxMemoryTopic
    if (-not $topic) { $topic = $note.Substring(0, [Math]::Min(20, $note.Length)) }

    $now = Get-MemoryNow

    # 同じ種類で言っていることが重なるものは、増やさずに差し替える。
    # 積むほど「関連するものだけ渡す」が効かなくなるので、増やさないほうを既定にする。
    $existing = @(Get-Memories -Conn $Conn -Kind $Kind)
    $newTokens = Get-MemoryTokens ($topic + ' ' + $note)
    foreach ($m in $existing) {
        $old = Get-MemoryTokens (([string] $m['topic']) + ' ' + ([string] $m['note']))
        if ((Get-TokenOverlap -A $newTokens -B $old) -lt 0.7) { continue }
        [void] $Conn.NonQuery(
            'UPDATE memories SET topic = ?, note = ?, source_task_id = ?, updated_at = ? WHERE id = ?',
            [object[]] @($topic, $note, $(if ($TaskId) { $TaskId } else { $null }), $now, [int] $m['id']))
        return [pscustomobject]@{ ok = $true; id = [int] $m['id']; reason = 'updated' }
    }

    [void] $Conn.NonQuery(
        'INSERT INTO memories (kind, topic, note, source_task_id, hits, created_at, updated_at) VALUES (?,?,?,?,0,?,?)',
        [object[]] @($Kind, $topic, $note, $(if ($TaskId) { $TaskId } else { $null }), $now, $now))
    $row = @($Conn.Query('SELECT MAX(id) AS id FROM memories'))
    $id = if ($row.Count -gt 0) { [int] $row[0]['id'] } else { 0 }

    Invoke-MemoryEviction -Conn $Conn
    return [pscustomobject]@{ ok = $true; id = $id; reason = 'added' }
}

function Invoke-MemoryEviction {
    <#
      .SYNOPSIS
        上限を超えたら、使われていないものから落とす。
      .DESCRIPTION
        際限なく積むと、渡す側で絞っても「絞る対象」が増え続ける。
        落とす順は「最後に使われたのが古い順」。一度も使われていないものは
        作られた日時で見る。profile は常に渡るぶん影響が大きいので別枠で絞る。
    #>
    param([Parameter(Mandatory)] $Conn)
    foreach ($pair in @(@{ where = "kind = 'profile'"; max = $script:MaxProfileMemories },
                        @{ where = "kind <> 'profile'"; max = $script:MaxMemories })) {
        $n = [int] (@($Conn.Query("SELECT COUNT(*) AS c FROM memories WHERE $($pair.where)"))[0]['c'])
        if ($n -le $pair.max) { continue }
        [void] $Conn.NonQuery(
            "DELETE FROM memories WHERE id IN (
               SELECT id FROM memories WHERE $($pair.where)
                ORDER BY COALESCE(last_used_at, created_at) ASC, hits ASC, id ASC LIMIT ?)",
            [object[]] @($n - $pair.max))
    }
}

function Remove-Memory {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $Id)
    return ([int] $Conn.NonQuery('DELETE FROM memories WHERE id = ?', [object[]] @($Id)) -gt 0)
}

function Get-Memories {
    param([Parameter(Mandatory)] $Conn, [string] $Kind, [int] $Limit = 500)
    if ($Kind) {
        return @($Conn.Query('SELECT * FROM memories WHERE kind = ? ORDER BY id DESC LIMIT ?',
                             [object[]] @($Kind, $Limit)))
    }
    return @($Conn.Query('SELECT * FROM memories ORDER BY kind, id DESC LIMIT ?', [object[]] @($Limit)))
}

function Set-MemoryUsed {
    <#
      .SYNOPSIS
        渡したものに「使った」印を付ける。落とす順を決めるのに使う。
    #>
    param([Parameter(Mandatory)] $Conn, [int[]] $Ids)
    if (-not $Ids -or @($Ids).Count -eq 0) { return }
    $now = Get-MemoryNow
    foreach ($id in @($Ids)) {
        [void] $Conn.NonQuery('UPDATE memories SET hits = hits + 1, last_used_at = ? WHERE id = ?',
                              [object[]] @($now, [int] $id))
    }
}

# ---------------------------------------------------------------- 引き当て

function Get-MemoryTokens {
    <#
      .SYNOPSIS
        突き合わせ用のかけら。日本語は2文字ずつ、英数字は語のまま。
      .DESCRIPTION
        形態素解析は使えない (追加インストールを増やさない)。日本語を語で切れない以上、
        2文字の並びで見るのが、依存を増やさずに「同じ話題か」を当てられる下限になる。
      .OUTPUTS
        [hashtable] かけら → $true
    #>
    param([string] $Text)
    $set = @{}
    if (-not $Text) { return $set }
    $t = ([string] $Text).ToLowerInvariant()
    $t = $t -replace '[\s\p{P}\p{S}]+', ' '
    foreach ($w in ($t -split ' ')) {
        if (-not $w) { continue }
        if ($w -match '^[a-z0-9]+$') {
            if ($w.Length -ge 2) { $set[$w] = $true }
            continue
        }
        if ($w.Length -eq 1) { $set[$w] = $true; continue }
        for ($i = 0; $i -lt $w.Length - 1; $i++) { $set[$w.Substring($i, 2)] = $true }
    }
    return $set
}

function Get-TokenOverlap {
    <#
      .SYNOPSIS
        A のかけらのうち、B にも出てくる割合 (0〜1)。
    #>
    param([hashtable] $A, [hashtable] $B)
    if (-not $A -or $A.Count -eq 0) { return 0.0 }
    if (-not $B -or $B.Count -eq 0) { return 0.0 }
    $hit = 0
    foreach ($k in $A.Keys) { if ($B.ContainsKey($k)) { $hit++ } }
    return ([double] $hit / [double] $A.Count)
}

function Get-MemoryScore {
    <#
      .SYNOPSIS
        そのカードにどれくらい関係するか。見出しの一致を重く見る。
      .DESCRIPTION
        見出し (topic) は「何についての記憶か」を短く書いたもので、
        本文より当たり外れがはっきりする。本文だけで見ると、長い記憶ほど
        どの件にも薄く当たってしまう。
    #>
    param([Parameter(Mandatory)] $Memory, [hashtable] $QueryTokens)
    $topic = Get-MemoryTokens ([string] $Memory['topic'])
    $note  = Get-MemoryTokens ([string] $Memory['note'])
    return ((Get-TokenOverlap -A $topic -B $QueryTokens) * 2.0) + (Get-TokenOverlap -A $note -B $QueryTokens)
}

function Get-RelevantMemories {
    <#
      .SYNOPSIS
        このカードに関係する記憶。profile は常に付ける。
      .PARAMETER Query
        カードの文面 (件名・要約・本文など)。
      .OUTPUTS
        [array] memories の行
    #>
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Query,
        [int] $Max = 8,
        [double] $MinScore = 0.5
    )
    $all = @(Get-Memories -Conn $Conn)
    if ($all.Count -eq 0) { return @() }

    # profile は「その人が誰か」なので、どの件にも効く。関連度で落とさない。
    $always = @($all | Where-Object { [string] $_['kind'] -eq 'profile' })
    $rest   = @($all | Where-Object { [string] $_['kind'] -ne 'profile' })

    $q = Get-MemoryTokens $Query
    $scored = @()
    foreach ($m in $rest) {
        $s = Get-MemoryScore -Memory $m -QueryTokens $q
        if ($s -lt $MinScore) { continue }
        $scored += [pscustomobject]@{ row = $m; score = $s }
    }
    $picked = @($scored | Sort-Object -Property @{ Expression = 'score'; Descending = $true } |
                Select-Object -First $Max | ForEach-Object { $_.row })
    return @($always + $picked)
}

function Get-MemoryText {
    <#
      .SYNOPSIS
        プロンプトに載せる形。関連するものだけを、合計の上限まで。
      .DESCRIPTION
        渡したものには「使った」印を付ける ―― 上限に当たったときに、
        実際に役立っているものを残すため。
      .OUTPUTS
        [string] 空のことがある (覚えていることが無い / どれも関係しない)
    #>
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Query,
        [int] $Max = 8,
        [int] $MaxChars = 0,
        [switch] $NoTouch
    )
    if ($MaxChars -le 0) { $MaxChars = $script:MemoryPromptChars }
    $rows = @(Get-RelevantMemories -Conn $Conn -Query $Query -Max $Max)
    if ($rows.Count -eq 0) { return '' }

    $lines = @()
    $used = @()
    $total = 0
    foreach ($m in $rows) {
        $line = "- [{0}] {1}: {2}" -f (Get-MemoryKindLabel ([string] $m['kind'])), [string] $m['topic'], [string] $m['note']
        if ($total + $line.Length -gt $MaxChars) { break }
        $total += $line.Length
        $lines += $line
        $used += [int] $m['id']
    }
    if ($lines.Count -eq 0) { return '' }
    if (-not $NoTouch) { Set-MemoryUsed -Conn $Conn -Ids $used }
    return ($lines -join "`n")
}

function Get-MemoryKindLabel {
    param([string] $Kind)
    switch ($Kind) {
        'profile'    { return '本人' }
        'preference' { return '希望' }
        'how'        { return '前例' }
        default      { return $Kind }
    }
}

# ---------------------------------------------------------------- 覚える材料

function Get-MemorySource {
    <#
      .SYNOPSIS
        1枚のカードから「覚える材料」を取り出す。
      .DESCRIPTION
        材料は利用者が書いたものに限る ―― 指示 (差し戻しのコメント) と
        完了メモ (対応の記録)。エージェント自身の報告から覚えると、
        自分の書いたことを事実として覚え直す輪になる。
        報告は「何の件だったか」を添えるためだけに使う。
      .OUTPUTS
        [pscustomobject] hasMaterial / title / summary / instructions / record / report
    #>
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId)
    $rows = @($Conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($TaskId)))
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{ hasMaterial = $false; title = ''; summary = ''; instructions = @(); record = ''; report = '' }
    }
    $t = $rows[0]
    $comments = @($Conn.Query(
        "SELECT body FROM task_comments WHERE task_id = ? AND author = 'user' ORDER BY id", [object[]] @($TaskId)))
    $instructions = @($comments | ForEach-Object { [string] $_['body'] } | Where-Object { $_.Trim() })
    $record = ([string] $t['user_record']).Trim()
    return [pscustomobject]@{
        hasMaterial  = ([bool] $record -or $instructions.Count -gt 0)
        title        = [string] $t['title']
        summary      = [string] $t['summary']
        instructions = $instructions
        record       = $record
        report       = [string] $t['agent_output']
    }
}

function Get-NextMemoryTask {
    <#
      .SYNOPSIS
        まだ覚えていない、閉じたカードを1枚。
      .DESCRIPTION
        閉じたあとにする理由は、**完了メモが閉じるときに書かれる**から。
        作業の直後に覚えると、利用者が最後に書いた一番はっきりした材料
        (「次からはこうして」) を取りこぼす。

        古いカードまで遡り続けないよう、日数で足を切る。入れた直後に
        過去全部を読み直すと、覚える価値の薄いものに費用を払うことになる。
      .OUTPUTS
        カードの行。無ければ $null
    #>
    param([Parameter(Mandatory)] $Conn, [int] $LookbackDays = 30)
    $since = (Get-Date).AddDays(-[Math]::Abs($LookbackDays)).ToString('o')
    $rows = @($Conn.Query(
        "SELECT * FROM tasks
          WHERE memory_at IS NULL
            AND board_column IN ('done', 'dismissed')
            AND updated_at >= ?
            AND (COALESCE(user_record, '') <> ''
                 OR EXISTS (SELECT 1 FROM task_comments c WHERE c.task_id = tasks.id AND c.author = 'user'))
          ORDER BY id DESC LIMIT 1", [object[]] @($since)))
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

function Set-TaskMemoryDone {
    <#
      .SYNOPSIS
        そのカードは覚え終わったと印を付ける。
      .DESCRIPTION
        覚えることが無かった場合も印を付ける。付けないと、同じカードを
        毎周回読み直して費用だけがかかる。
    #>
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId)
    [void] $Conn.NonQuery('UPDATE tasks SET memory_at = ? WHERE id = ?',
                          [object[]] @((Get-MemoryNow), $TaskId))
}
