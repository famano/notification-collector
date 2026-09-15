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
# 長さの扱い ―― 絞り込まず、全体を短く保つ:
#   最初は「カードの文面と突き合わせて関連するものだけ渡す」形にしていた。
#   日本語を語で切れないので2文字ずつ (バイグラム) で見ていたが、実際に
#   例文の組で測ると、外し方が二通りとも出た。
#     誤って一致 … 「振り替える」と「池のかえる」が「える」で一致する
#     取りこぼし … 日本語で覚えた記憶は、英語の通知
#                  (GitHub の招待、CI の失敗) と一文字も重ならない
#   後者のほうが重い。**覚えているのに渡らない**のは、症状が「同じ間違いを
#   繰り返す」であって、記憶が無いときと見分けが付かない。しかも経路ごとに
#   言語が違うのは直しようがない (語の切り方を変えても解決しない)。
#
#   そこで絞り込みをやめ、**全体を短く保って全部渡す**。人についての記憶は
#   もともと増え続けるものではない。上限は二つで担保する。
#     ・1件を短く … 200 字で切る。種類ごとに件数の上限を置き、古いものから落とす
#     ・渡す量の上限 … 合計の文字数で切る。超える分は渡さない
#   絞り込みが無ければ「関連度の判定を外す」という失敗の形そのものが無くなる。
#   どれが効くかは、渡した先のモデルが文面を見て判断する。
#
# 種類は閉じた集合にする。自由記述にすると「何にでも当てはまる一般論」が
# 積もって、渡す枠を食い潰す。
#   profile    … 利用者そのもの。名前・役割・関心事・持ち物
#   preference … こう扱ってほしい。「請求書は送らずに下書きまで」
#   how        … 似た件をこう処理した。「この種の招待は API で承諾できた」

$script:MemoryKinds       = @('profile', 'preference', 'how')
$script:MaxMemoryNote     = 200     # 1件の長さ
$script:MaxMemoryTopic    = 40
# 種類ごとの件数。全部渡すので、ここが渡す量そのものになる。
$script:MaxMemoriesByKind = @{ profile = 10; preference = 12; how = 15 }
# 渡す合計の上限。**上の件数から決まる最大量より大きく取ってある。**
#   (10 + 12 + 15) 件 × 1件あたり最大 250 字弱 ≒ 9,000 字
# ここで切れるのは非常時の歯止めで、普段は全部が入る ―― 絞り込みをやめた意味が、
# 上限で静かに落ちて消えてしまわないようにするため。
# 短くしたいときは、この数ではなく件数の上限を下げる (落ちたことが画面に出る)。
$script:MemoryPromptChars = 10000

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

function Get-MemoryKindLimit {
    param([string] $Kind)
    if ($script:MaxMemoriesByKind.ContainsKey($Kind)) { return [int] $script:MaxMemoriesByKind[$Kind] }
    return 20
}

function Add-MemoryNote {
    <#
      .SYNOPSIS
        覚える。同じことを二度書かない。
      .DESCRIPTION
        重なりの判定は二つだけにしてある。どちらも見れば分かる規則で、
        外れ方が説明できる形にしたいため。
          ・同じ文面 … 中身は変えずに日付だけ新しくする
          ・同じ種類で同じ見出し … 見出しは「記憶の枠」なので、中身を差し替える
        言い換えただけのものを潰すのは、ここではなく記憶係 (モデル) の仕事。
        いま覚えていることは全部渡してあるので、そちらのほうが当たる。
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

    foreach ($m in @(Get-Memories -Conn $Conn -Kind $Kind)) {
        $sameNote  = ([string] $m['note']) -eq $note
        $sameTopic = ([string] $m['topic']) -eq $topic
        if (-not $sameNote -and -not $sameTopic) { continue }
        [void] $Conn.NonQuery(
            'UPDATE memories SET topic = ?, note = ?, source_task_id = ?, updated_at = ? WHERE id = ?',
            [object[]] @($topic, $note, $(if ($TaskId) { $TaskId } else { $null }), $now, [int] $m['id']))
        return [pscustomobject]@{ ok = $true; id = [int] $m['id']; reason = 'updated' }
    }

    [void] $Conn.NonQuery(
        'INSERT INTO memories (kind, topic, note, source_task_id, created_at, updated_at) VALUES (?,?,?,?,?,?)',
        [object[]] @($Kind, $topic, $note, $(if ($TaskId) { $TaskId } else { $null }), $now, $now))
    $row = @($Conn.Query('SELECT MAX(id) AS id FROM memories'))
    $id = if ($row.Count -gt 0) { [int] $row[0]['id'] } else { 0 }

    Invoke-MemoryEviction -Conn $Conn -Kind $Kind
    return [pscustomobject]@{ ok = $true; id = $id; reason = 'added' }
}

function Invoke-MemoryEviction {
    <#
      .SYNOPSIS
        種類ごとの上限を超えたら、古いものから落とす。
      .DESCRIPTION
        全部渡す以上、件数の上限がそのまま「毎回渡る量」になる。
        落とす順は最後に書き換えられたのが古い順 ―― 使われた回数では見ない。
        全部渡しているので、どれが効いたかはこちら側からは分からない。
    #>
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [string] $Kind)
    $max = Get-MemoryKindLimit $Kind
    $n = [int] (@($Conn.Query('SELECT COUNT(*) AS c FROM memories WHERE kind = ?', [object[]] @($Kind)))[0]['c'])
    if ($n -le $max) { return }
    [void] $Conn.NonQuery(
        'DELETE FROM memories WHERE id IN (
           SELECT id FROM memories WHERE kind = ?
            ORDER BY updated_at ASC, id ASC LIMIT ?)',
        # 引き算は括ること。カンマのほうが優先されるので、括らないと
        # 「($Kind, $n) から $max を引く」と解釈されて配列の引き算になる。
        [object[]] @($Kind, ($n - $max)))
}

function Remove-Memory {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $Id)
    return ([int] $Conn.NonQuery('DELETE FROM memories WHERE id = ?', [object[]] @($Id)) -gt 0)
}

function Get-Memories {
    <#
      .SYNOPSIS
        覚えていること。新しいものが先。
    #>
    param([Parameter(Mandatory)] $Conn, [string] $Kind, [int] $Limit = 500)
    if ($Kind) {
        return @($Conn.Query('SELECT * FROM memories WHERE kind = ? ORDER BY updated_at DESC, id DESC LIMIT ?',
                             [object[]] @($Kind, $Limit)))
    }
    return @($Conn.Query('SELECT * FROM memories ORDER BY updated_at DESC, id DESC LIMIT ?', [object[]] @($Limit)))
}

# ---------------------------------------------------------------- 渡す

function Get-MemoryKindLabel {
    param([string] $Kind)
    switch ($Kind) {
        'profile'    { return '本人' }
        'preference' { return '希望' }
        'how'        { return '前例' }
        default      { return $Kind }
    }
}

function Get-MemoryText {
    <#
      .SYNOPSIS
        プロンプトに載せる形。全部を、合計の上限まで。
      .DESCRIPTION
        カードの文面とは突き合わせない (このファイルの冒頭を参照)。
        並べる順は profile → preference → how、それぞれ新しいものが先。
        上限に当たったら入り切らないものが落ちるので、**落ちてよいものほど後ろ**に置く。
      .PARAMETER Kinds
        渡す種類。判定 (トリアージ) は profile と preference だけを取る ――
        how は「どう操作したか」で、通知を分類する側では使い道が無い。
      .OUTPUTS
        [string] 空のことがある (まだ何も覚えていない)
    #>
    param(
        [Parameter(Mandatory)] $Conn,
        [string[]] $Kinds,
        [int] $MaxChars = 0
    )
    if ($MaxChars -le 0) { $MaxChars = $script:MemoryPromptChars }
    if (-not $Kinds -or @($Kinds).Count -eq 0) { $Kinds = $script:MemoryKinds }

    $lines = @()
    $total = 0
    foreach ($kind in @($script:MemoryKinds)) {
        if (@($Kinds) -notcontains $kind) { continue }
        foreach ($m in @(Get-Memories -Conn $Conn -Kind $kind)) {
            $line = "- [{0}] {1}: {2}" -f (Get-MemoryKindLabel $kind), [string] $m['topic'], [string] $m['note']
            if ($total + $line.Length -gt $MaxChars) { continue }
            $total += $line.Length
            $lines += $line
        }
    }
    if ($lines.Count -eq 0) { return '' }
    return ($lines -join "`n")
}

# ---------------------------------------------------------------- 覚える材料

function Get-MemorySource {
    <#
      .SYNOPSIS
        1枚のカードから「覚える材料」を取り出す。
      .DESCRIPTION
        材料は二種類あり、扱いが違う。
          利用者が書いたもの (指示・完了メモ)
            … そのまま材料。何を望んでいるかは本人しか書けない。
          エージェント側の記録 (試したことの一覧・報告)
            … **事実だけ**材料になる。何を叩いて何が返ったかは、
               次に似た件が来たときにそのまま効く (前例)。
               ただし報告はエージェント自身の言い分でもあるので、
               取るのは事実に限る、と記憶係のプロンプト側で縛る。
               試したことの一覧 (task_attempts) はツールの実行記録そのもので、
               言い分の混ざりようが無いぶん、こちらが主の材料になる。
      .OUTPUTS
        [pscustomobject] hasMaterial / title / summary / instructions / record / attempts / report
    #>
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId)
    $rows = @($Conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($TaskId)))
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{
            hasMaterial = $false; title = ''; summary = ''
            instructions = @(); record = ''; attempts = ''; report = ''
        }
    }
    $t = $rows[0]
    $comments = @($Conn.Query(
        "SELECT body FROM task_comments WHERE task_id = ? AND author = 'user' ORDER BY id", [object[]] @($TaskId)))
    $instructions = @($comments | ForEach-Object { [string] $_['body'] } | Where-Object { $_.Trim() })
    $record = ([string] $t['user_record']).Trim()
    # 試したことの一覧は TaskStore が持つ。読み込まれていない環境 (単体の試験など)
    # でも材料の取り出し自体は通るようにしておく。
    $attempts = ''
    if (Get-Command Get-AttemptSummary -ErrorAction SilentlyContinue) {
        $attempts = [string] (Get-AttemptSummary -Conn $Conn -TaskId $TaskId)
    }
    return [pscustomobject]@{
        # 利用者が何も書かず、エージェントも何も試していないカードには
        # 覚えるものが無い。そこに1回分の費用を払わない。
        hasMaterial  = ([bool] $record -or $instructions.Count -gt 0 -or [bool] $attempts)
        title        = [string] $t['title']
        summary      = [string] $t['summary']
        instructions = $instructions
        record       = $record
        attempts     = $attempts
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
                 OR EXISTS (SELECT 1 FROM task_comments c WHERE c.task_id = tasks.id AND c.author = 'user')
                 OR EXISTS (SELECT 1 FROM task_attempts a WHERE a.task_id = tasks.id))
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
