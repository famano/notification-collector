# HumanStep.Tests.ps1
# 「あなたにしかできない1手」が、カードだけでなく報告と自己検証にも届くこと。
#
# ここが壊れていたときの症状は分かりにくい。カードには赤枠が出ているので
# 動いているように見えるのに、報告の先頭には何も出ず、自己検証も
# 「人間送りが妥当か」を見られないまま通る。
#
# 原因はクロージャの中の代入が外に伝わらないことだった。変数で持ち回るのをやめ、
# DB に書いたものを読み直す形にしてある。その経路をここで固定する。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase4\lib\WorkTools.ps1"

Describe '報告の先頭に置く1手の組み立て' {

    It '1手そのものが先頭に出る' {
        $hs = [pscustomobject]@{ blocker = 'physical_presence'; step = '本人確認リンクを開く' }
        $t = Get-HumanStepHeadline -HumanStep $hs
        Assert-Match '^【あなたの操作が必要です】' $t
        Assert-Match '本人確認リンクを開く' $t
    }

    It '入口の URL と期限があれば出す' {
        $hs = [pscustomobject]@{ step = 'やる'; url = 'https://example.com/verify'; deadline = '30分以内' }
        $t = Get-HumanStepHeadline -HumanStep $hs
        Assert-Match 'https://example\.com/verify' $t
        Assert-Match '30分以内' $t
    }

    It '権限不足なら「あなたの作業ではない」と分かるように設定カードを案内する' {
        $hs = [pscustomobject]@{ blocker = 'credential_missing'; step = 'トークンを入れる'; setup_task_id = 12 }
        $t = Get-HumanStepHeadline -HumanStep $hs
        Assert-Match '設定カード #12' $t
        Assert-Match 'まとめて進みます' $t
    }

    It '設定カードが無ければその案内は出さない' {
        $hs = [pscustomobject]@{ blocker = 'no_api'; step = '電話する' }
        Assert-True ((Get-HumanStepHeadline -HumanStep $hs) -notmatch '設定カード')
    }

    It '証跡を必ず一緒に出す (サボったのかを確かめるために元通知を見に行かせない)' {
        $hs = [pscustomobject]@{ step = 'やる' }
        $t = Get-HumanStepHeadline -HumanStep $hs -Tried "○ open_source gmail 3000 文字を取得`n× http_request GET https://api.github.com/x 404"
        Assert-Match '試したこと' $t
        Assert-Match '404' $t
    }
}

if (-not (Test-SqliteAvailable)) {
    Describe 'カードからの読み直し' { Skip-It 'すべて' 'winsqlite3.dll が使えません' }
    return
}

Describe 'カードからの読み直し' {
    $conn = New-TestStore
    $id = [int] (New-Task -Conn $conn -Title '1手のカード')

    It '何も無ければ null' {
        Assert-Null (Get-TaskHumanStep -Conn $conn -TaskId $id)
    }

    It 'ワーカーが書いたものをそのまま読み戻せる' {
        $hs = [pscustomobject]@{ blocker = 'credential_missing'; step = 'トークン'; setup_task_id = 3 }
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ human_step = ($hs | ConvertTo-Json -Compress) })
        $back = Get-TaskHumanStep -Conn $conn -TaskId $id
        Assert-Equal 'credential_missing' $back.blocker
        Assert-Equal 'トークン' $back.step
        Assert-Equal 3 $back.setup_task_id
    }

    It '再実行の前に消せる (前回の結論を今回のカードに残さない)' {
        Assert-True (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ human_step = $null })
        Assert-Null (Get-TaskHumanStep -Conn $conn -TaskId $id)
    }

    It '壊れた JSON が入っていても落ちない' {
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ human_step = '{壊れている' })
        Assert-Null (Get-TaskHumanStep -Conn $conn -TaskId $id)
    }

    It '無いカードを聞かれても落ちない' {
        Assert-Null (Get-TaskHumanStep -Conn $conn -TaskId 999999)
    }

    Close-TestStore $conn
}
