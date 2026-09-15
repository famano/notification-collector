# Memory.Tests.ps1
# 利用者について覚えておくこと。件をまたいで効く「その人の事情」。
#
# ここが壊れたときの症状は二通りある。どちらも静かに効く。
#   覚えない / 引き当てない … 同じことを毎回言い直すことになる (元の状態に戻るだけ)
#   覚えすぎ / 何にでも当たる … どの件にも同じ記憶が渡り、判断の材料が薄まる。
#                              しかも積もるほど費用が増える
# 後者のほうが気付きにくいので、上限と絞り込みが効いていることを固定する。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase2\lib\Memory.ps1"

Describe '突き合わせのかけら' {

    It '日本語は2文字ずつに割る (形態素解析を持ち込まない)' {
        $t = Get-MemoryTokens '請求書'
        Assert-True $t.ContainsKey('請求')
        Assert-True $t.ContainsKey('求書')
    }

    It '英数字は語のまま残す' {
        Assert-True (Get-MemoryTokens 'GitHub の招待').ContainsKey('github')
    }

    It '記号と大文字小文字はならす' {
        Assert-True (Get-MemoryTokens 'GitHub, Inc.').ContainsKey('github')
    }

    It '空なら空' {
        Assert-Equal 0 (Get-MemoryTokens '').Count
    }
}

Describe '関連度' {

    It '同じ話題なら重なる' {
        $a = Get-MemoryTokens '請求書'
        $b = Get-MemoryTokens '9月分の請求書のご送付'
        Assert-True ((Get-TokenOverlap -A $a -B $b) -gt 0.5)
    }

    It '無関係なら重ならない' {
        $a = Get-MemoryTokens '請求書'
        $b = Get-MemoryTokens '歓迎会の日程調整'
        Assert-Equal 0 (Get-TokenOverlap -A $a -B $b)
    }

    It '空どうしは 0 (何にでも当たる記憶を作らない)' {
        Assert-Equal 0 (Get-TokenOverlap -A @{} -B (Get-MemoryTokens '何か'))
    }
}

if (-not (Test-SqliteAvailable)) {
    Describe '覚えていることの読み書き' { Skip-It 'すべて' 'winsqlite3.dll が使えません' }
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
        $r = Add-MemoryNote -Conn $conn -Kind 'その他' -Topic 'x' -Note 'y'
        Assert-False $r.ok
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
        $m = @(Get-Memories -Conn $conn -Kind 'profile')[0]
        Assert-Equal '受託開発の エンジニア' ([string] $m['note'])
    }

    It '言い換えただけの記憶は増やさず差し替える' {
        $c2 = New-TestStore
        [void] (Add-MemoryNote -Conn $c2 -Kind 'preference' -Topic '請求書' -Note '請求書は送らずに下書きまででよい')
        $r = Add-MemoryNote -Conn $c2 -Kind 'preference' -Topic '請求書' -Note '請求書は送らずに下書きまででよいです'
        Assert-Equal 'updated' $r.reason
        Assert-Equal 1 (@(Get-Memories -Conn $c2)).Count
        Close-TestStore $c2
    }

    It '別の話題なら別の記憶として増える' {
        $c2 = New-TestStore
        [void] (Add-MemoryNote -Conn $c2 -Kind 'preference' -Topic '請求書' -Note '請求書は下書きまででよい')
        [void] (Add-MemoryNote -Conn $c2 -Kind 'preference' -Topic '歓迎会' -Note '歓迎会の誘いは断ってよい')
        Assert-Equal 2 (@(Get-Memories -Conn $c2)).Count
        Close-TestStore $c2
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

Describe '渡すのは関連するものだけ' {
    $conn = New-TestStore
    [void] (Add-MemoryNote -Conn $conn -Kind 'profile'    -Topic '役割' -Note '受託開発のエンジニア。見積と障害対応を持つ')
    [void] (Add-MemoryNote -Conn $conn -Kind 'preference' -Topic '請求書' -Note '請求書の返信は送らずに下書きまででよい')
    [void] (Add-MemoryNote -Conn $conn -Kind 'how'        -Topic 'GitHub の招待' -Note '招待は http_request で承諾できた')

    It '話題が合うものが渡る' {
        $t = Get-MemoryText -Conn $conn -Query '9月分の請求書のご送付'
        Assert-Match '請求書' $t
        Assert-True ($t -notmatch 'GitHub')
    }

    It '本人についてはどの件でも渡る (誰かは常に効く)' {
        Assert-Match '受託開発' (Get-MemoryText -Conn $conn -Query '歓迎会の日程調整')
    }

    It '関係しない希望や前例は渡さない' {
        $t = Get-MemoryText -Conn $conn -Query '歓迎会の日程調整'
        Assert-True ($t -notmatch '請求書')
        Assert-True ($t -notmatch 'GitHub')
    }

    It '合計の長さに上限がある (増えるほど邪魔にならないように)' {
        Assert-True ((Get-MemoryText -Conn $conn -Query '請求書 GitHub' -MaxChars 40).Length -le 40)
    }

    It '渡したものには「使った」印が付く (落とす順を決めるのに使う)' {
        [void] (Get-MemoryText -Conn $conn -Query '請求書')
        $m = @(Get-Memories -Conn $conn -Kind 'preference')[0]
        Assert-True ([int] $m['hits'] -ge 1)
        Assert-NotNull $m['last_used_at']
    }

    It '重複の確認のために引くときは印を付けない' {
        $before = [int] (@(Get-Memories -Conn $conn -Kind 'how')[0])['hits']
        [void] (Get-MemoryText -Conn $conn -Query 'GitHub の招待' -NoTouch)
        Assert-Equal $before ([int] (@(Get-Memories -Conn $conn -Kind 'how')[0])['hits'])
    }

    Close-TestStore $conn
}

Describe '上限を超えたら落とす' {
    $conn = New-TestStore

    It '本人についての記憶は別枠で絞る (常に渡るため)' {
        for ($i = 1; $i -le 25; $i++) {
            [void] (Add-MemoryNote -Conn $conn -Kind 'profile' -Topic ("話題$i") -Note ("これは $i 番目の事情です"))
        }
        Assert-True ((@(Get-Memories -Conn $conn -Kind 'profile')).Count -le 20)
    }

    It '使われたものは残る' {
        $c2 = New-TestStore
        $keep = (Add-MemoryNote -Conn $c2 -Kind 'profile' -Topic '残るもの' -Note 'これは使われている事情です').id
        Set-MemoryUsed -Conn $c2 -Ids @($keep)
        for ($i = 1; $i -le 25; $i++) {
            [void] (Add-MemoryNote -Conn $c2 -Kind 'profile' -Topic ("話題$i") -Note ("これは $i 番目の事情です"))
        }
        Assert-Equal 1 (@(Get-Memories -Conn $c2 | Where-Object { [int] $_['id'] -eq $keep })).Count
        Close-TestStore $c2
    }

    Close-TestStore $conn
}

Describe '覚える材料' {
    $conn = New-TestStore

    It '利用者が何も書かなかったカードは材料にならない' {
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
