# Memory.Tests.ps1
# 利用者について覚えておくこと。件をまたいで効く「その人の事情」。
#
# ここが壊れたときの症状は二通りある。どちらも静かに効く。
#   渡らない … 覚えているのに効かない。症状は「同じ間違いを繰り返す」で、
#              記憶が無いときと見分けが付かない。**こちらのほうが重い**
#   増えすぎ … どの件にも同じものが大量に渡り、判断の材料が薄まって費用も増える
#
# 最初は「カードの文面と突き合わせて関連するものだけ渡す」形にしていた。
# 日本語を語で切れないので2文字ずつ (バイグラム) で見ていたが、例文の組で測ると
# 外し方が両方向に出た ――「振り替える」と「池のかえる」が「える」で一致し、
# 逆に日本語で覚えた記憶は英語の通知 (GitHub の招待・CI の失敗) と一文字も重ならない。
# いまは絞り込みをやめ、全体を短く保って全部渡している。
# 下の「どんな文面のカードでも渡る」は、そのときの外れ方をそのまま回帰試験にしたもの。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase2\lib\Memory.ps1"

if (-not (Test-SqliteAvailable)) {
    Describe '覚えていること' { Skip-It 'すべて' 'winsqlite3.dll が使えません' }
    return
}

Describe '覚えていることの読み書き' {
    $conn = New-TestStore

    It '書いたものが読み出せる' {
        $r = Add-MemoryNote -Conn $conn -Kind 'preference' -Topic '請求書' -Note '請求書の返信は送らずに下書きまででよい'
        Assert-True $r.ok
        Assert-Equal 1 (@(Get-Memories -Conn $conn -Kind 'preference')).Count
    }

    It '知らない種類は受け付けない (何にでも当たる記憶を作らせない)' {
        Assert-False (Add-MemoryNote -Conn $conn -Kind 'その他' -Topic 'x' -Note 'y').ok
    }

    It '空の中身は書かない' {
        Assert-False (Add-MemoryNote -Conn $conn -Kind 'how' -Topic 'x' -Note '   ').ok
    }

    It '長すぎる記憶は切る (毎回渡るものなので短く保つ)' {
        [void] (Add-MemoryNote -Conn $conn -Kind 'how' -Topic ('あ' * 100) -Note ('い' * 500))
        $m = @(Get-Memories -Conn $conn -Kind 'how')[0]
        Assert-True (([string] $m['note']).Length -le 200)
        Assert-True (([string] $m['topic']).Length -le 40)
    }

    It '改行は潰す (1件1行で渡すため)' {
        [void] (Add-MemoryNote -Conn $conn -Kind 'profile' -Topic '役割' -Note "受託開発の`nエンジニア")
        Assert-Equal '受託開発の エンジニア' ([string] (@(Get-Memories -Conn $conn -Kind 'profile')[0])['note'])
    }

    It '消せる' {
        $c2 = New-TestStore
        $id = (Add-MemoryNote -Conn $c2 -Kind 'how' -Topic 'x' -Note 'これは消す').id
        Assert-True (Remove-Memory -Conn $c2 -Id $id)
        Assert-Equal 0 (@(Get-Memories -Conn $c2)).Count
        Assert-False (Remove-Memory -Conn $c2 -Id $id)
        Close-TestStore $c2
    }

    Close-TestStore $conn
}

Describe '同じことを二度書かない' {

    # 重なりの判定は「同じ文面」と「同じ見出し」の二つだけ。どちらも見れば分かる規則で、
    # 外れたときに理由が説明できる。言い換えを潰すのは記憶係 (モデル) の仕事で、
    # そちらにはいま覚えていることを全部渡してある。

    It '同じ文面は増やさない' {
        $c = New-TestStore
        [void] (Add-MemoryNote -Conn $c -Kind 'preference' -Topic '請求書' -Note '請求書は下書きまででよい')
        $r = Add-MemoryNote -Conn $c -Kind 'preference' -Topic '請求書' -Note '請求書は下書きまででよい'
        Assert-Equal 'updated' $r.reason
        Assert-Equal 1 (@(Get-Memories -Conn $c)).Count
        Close-TestStore $c
    }

    It '同じ見出しなら中身を差し替える (覚え直しはこれで行う)' {
        $c = New-TestStore
        [void] (Add-MemoryNote -Conn $c -Kind 'preference' -Topic '請求書' -Note '請求書は下書きまででよい')
        [void] (Add-MemoryNote -Conn $c -Kind 'preference' -Topic '請求書' -Note '請求書はそのまま送ってよい')
        $all = @(Get-Memories -Conn $c)
        Assert-Equal 1 $all.Count
        Assert-Equal '請求書はそのまま送ってよい' ([string] $all[0]['note'])
        Close-TestStore $c
    }

    It '種類が違えば別の記憶 (見出しが同じでも混ぜない)' {
        $c = New-TestStore
        [void] (Add-MemoryNote -Conn $c -Kind 'preference' -Topic '請求書' -Note '請求書は下書きまででよい')
        [void] (Add-MemoryNote -Conn $c -Kind 'how' -Topic '請求書' -Note '請求書は添付を開かないと金額が分からない')
        Assert-Equal 2 (@(Get-Memories -Conn $c)).Count
        Close-TestStore $c
    }

    It '別の話題なら増える' {
        $c = New-TestStore
        [void] (Add-MemoryNote -Conn $c -Kind 'preference' -Topic '請求書' -Note '請求書は下書きまででよい')
        [void] (Add-MemoryNote -Conn $c -Kind 'preference' -Topic '歓迎会' -Note '歓迎会の誘いは断ってよい')
        Assert-Equal 2 (@(Get-Memories -Conn $c)).Count
        Close-TestStore $c
    }
}

Describe 'どんな文面のカードでも渡る' {

    # 絞り込みをやめた理由そのものを固定する。
    # 下のカードはどれも、以前の「2文字ずつの突き合わせ」では
    # 当たったり外れたりしていた (英語の通知は一文字も重ならないので必ず外れた)。

    $conn = New-TestStore
    [void] (Add-MemoryNote -Conn $conn -Kind 'profile'    -Topic '役割'   -Note '受託開発のエンジニア。見積と障害対応を持つ')
    [void] (Add-MemoryNote -Conn $conn -Kind 'preference' -Topic '請求書' -Note '請求書の返信は送らずに下書きまででよい')
    [void] (Add-MemoryNote -Conn $conn -Kind 'how'        -Topic 'GitHub の招待' -Note '招待は http_request で承諾できた')

    $cards = @(
        '9月分の請求書のご送付について',
        'Re: ご請求書の件（8月分）',
        'You have been invited to collaborate on famano/notification-collector',
        'Run failed: Security - main (c5857b6)',
        '10月の歓迎会の日程調整のお願い',
        '池のかえるの写真を共有します',
        '【緊急】本番環境で障害が発生しています',
        ''
    )

    It '件名が日本語でも英語でも、覚えていることは全部渡る' {
        $t = Get-MemoryText -Conn $conn
        foreach ($c in $cards) {
            # カードの文面は渡す内容を変えない (選り分けていないため)。
            Assert-Match '請求書' $t ("カード: " + $c)
            Assert-Match 'GitHub' $t ("カード: " + $c)
            Assert-Match '受託開発' $t ("カード: " + $c)
        }
    }

    It '本人 → 希望 → 前例 の順に並ぶ (上限で落ちるのは後ろから)' {
        $lines = (Get-MemoryText -Conn $conn) -split "`n"
        Assert-Match '^- \[本人\]' $lines[0]
        Assert-Match '^- \[希望\]' $lines[1]
        Assert-Match '^- \[前例\]' $lines[2]
    }

    It '判定に渡すのは本人と希望だけ (前例は分類に効かない)' {
        $t = Get-MemoryText -Conn $conn -Kinds @('profile', 'preference')
        Assert-Match '受託開発' $t
        Assert-Match '請求書' $t
        Assert-True ($t -notmatch 'http_request')
    }

    It '合計の長さでも切れる (判定はこれで量を抑える)' {
        Assert-True ((Get-MemoryText -Conn $conn -MaxChars 40).Length -le 40)
    }

    It '既定の上限では、上限まで覚えていても切れない (静かに落ちない)' {
        $c2 = New-TestStore
        foreach ($kind in @('profile', 'preference', 'how')) {
            for ($i = 1; $i -le 30; $i++) {
                [void] (Add-MemoryNote -Conn $c2 -Kind $kind -Topic ('あ' * 40) -Note ('い' * 200))
            }
        }
        $all = @(Get-Memories -Conn $c2)
        $lines = @((Get-MemoryText -Conn $c2) -split "`n")
        Assert-Equal $all.Count $lines.Count '覚えている件数と渡る行数が合いません'
        Close-TestStore $c2
    }

    It '何も覚えていなければ空' {
        $c2 = New-TestStore
        Assert-Equal '' (Get-MemoryText -Conn $c2)
        Close-TestStore $c2
    }

    Close-TestStore $conn
}

Describe '上限を超えたら落とす' {

    It '種類ごとに件数の上限がある (毎回渡る量そのものになる)' {
        $c = New-TestStore
        for ($i = 1; $i -le 25; $i++) {
            [void] (Add-MemoryNote -Conn $c -Kind 'profile' -Topic ("話題$i") -Note ("これは $i 番目の事情です"))
        }
        Assert-True ((@(Get-Memories -Conn $c -Kind 'profile')).Count -le 10)
        Close-TestStore $c
    }

    It '落ちるのは古いものから (最後に書き換えたものが残る)' {
        $c = New-TestStore
        for ($i = 1; $i -le 25; $i++) {
            [void] (Add-MemoryNote -Conn $c -Kind 'profile' -Topic ("話題$i") -Note ("これは $i 番目の事情です"))
        }
        $left = @(Get-Memories -Conn $c -Kind 'profile' | ForEach-Object { [string] $_['topic'] })
        Assert-True ($left -contains '話題25')
        Assert-False ($left -contains '話題1')
        Close-TestStore $c
    }

    It '種類ごとに別枠 (前例が増えても本人についての記憶は落ちない)' {
        $c = New-TestStore
        [void] (Add-MemoryNote -Conn $c -Kind 'profile' -Topic '役割' -Note '受託開発のエンジニア')
        for ($i = 1; $i -le 30; $i++) {
            [void] (Add-MemoryNote -Conn $c -Kind 'how' -Topic ("手順$i") -Note ("これは $i 番目の前例です"))
        }
        Assert-Equal 1 (@(Get-Memories -Conn $c -Kind 'profile')).Count
        Close-TestStore $c
    }
}

Describe '覚える材料' {
    $conn = New-TestStore

    It '利用者も書かず、何も試していないカードは材料にならない' {
        $id = [int] (New-Task -Conn $conn -Title '黙って閉じたカード' -Column 'done')
        Assert-False (Get-MemorySource -Conn $conn -TaskId $id).hasMaterial
    }

    It '完了の記録は材料になる' {
        $id = [int] (New-Task -Conn $conn -Title '記録のあるカード' -Column 'done')
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ user_record = '今回は自分で電話した' })
        $s = Get-MemorySource -Conn $conn -TaskId $id
        Assert-True $s.hasMaterial
        Assert-Match '電話' $s.record
    }

    It '利用者の指示は材料になる。エージェントのコメントはならない' {
        $id = [int] (New-Task -Conn $conn -Title '指示のあるカード' -Column 'done')
        [void] (Add-TaskComment -Conn $conn -TaskId $id -Author 'agent' -Body '検証で残った指摘')
        [void] (Add-TaskComment -Conn $conn -TaskId $id -Author 'user'  -Body '次からは送らずに下書きまでにして')
        $s = Get-MemorySource -Conn $conn -TaskId $id
        Assert-True $s.hasMaterial
        Assert-Equal 1 (@($s.instructions)).Count
        Assert-Match '下書き' $s.instructions[0]
    }

    It '実際に試したことは材料になる (何を叩いて何が返ったかは事実)' {
        $id = [int] (New-Task -Conn $conn -Title '試したカード' -Column 'done')
        Add-TaskAttempt -Conn $conn -TaskId $id -Tool 'http_request' `
            -Target 'POST https://api.github.com/user/repository_invitations/1' -Outcome 'ok' -Detail '204'
        $s = Get-MemorySource -Conn $conn -TaskId $id
        Assert-True $s.hasMaterial
        Assert-Match 'repository_invitations' $s.attempts
    }

    It '報告も材料として渡す (取るのは事実だけ、という縛りはプロンプト側)' {
        $id = [int] (New-Task -Conn $conn -Title '報告のあるカード' -Column 'done')
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ agent_output = '招待を承諾しました' })
        Assert-Match '承諾' (Get-MemorySource -Conn $conn -TaskId $id).report
    }

    Close-TestStore $conn
}

Describe '覚える対象のカードを拾う' {
    $conn = New-TestStore

    It '開いているカードは拾わない (完了メモは閉じるときに書かれる)' {
        $id = [int] (New-Task -Conn $conn -Title '作業中' -Column 'review')
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ user_record = 'まだ途中' })
        Assert-Null (Get-NextMemoryTask -Conn $conn)
    }

    It '閉じていて材料があるカードを拾う' {
        $id = [int] (New-Task -Conn $conn -Title '閉じたカード' -Column 'done')
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ user_record = '次からは断ってよい' })
        $t = Get-NextMemoryTask -Conn $conn
        Assert-NotNull $t
        Assert-Equal $id ([int] $t['id'])
    }

    It '一度覚えたカードは二度拾わない' {
        $t = Get-NextMemoryTask -Conn $conn
        Set-TaskMemoryDone -Conn $conn -TaskId ([int] $t['id'])
        Assert-Null (Get-NextMemoryTask -Conn $conn)
    }

    It '利用者が何も書かなくても、試した記録があれば拾う' {
        $id = [int] (New-Task -Conn $conn -Title '黙って終わったカード' -Column 'done')
        Add-TaskAttempt -Conn $conn -TaskId $id -Tool 'http_request' -Target 'GET https://api.github.com/repos/x/y' `
            -Outcome 'failed' -Detail '404'
        $t = Get-NextMemoryTask -Conn $conn
        Assert-NotNull $t
        Assert-Equal $id ([int] $t['id'])
        Set-TaskMemoryDone -Conn $conn -TaskId $id
    }

    It '古すぎるカードは遡らない' {
        $id = [int] (New-Task -Conn $conn -Title '古いカード' -Column 'done')
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ user_record = '昔の話' })
        [void] $conn.NonQuery('UPDATE tasks SET updated_at = ? WHERE id = ?',
                              [object[]] @((Get-Date).AddDays(-90).ToString('o'), $id))
        Assert-Null (Get-NextMemoryTask -Conn $conn -LookbackDays 30)
        Assert-NotNull (Get-NextMemoryTask -Conn $conn -LookbackDays 365)
    }

    Close-TestStore $conn
}
