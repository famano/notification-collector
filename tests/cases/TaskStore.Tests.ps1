# TaskStore.Tests.ps1
# イベントとカードのストア。
#
# 特に見ているのは「通知と同期の突き合わせ」。同じメッセージが2つの経路から来るのに
# カードは1枚でなければならず、正は必ず同期側 (本文と返信先を持っているのは同期だけ)。
# ここを間違えるとカードが二重に立つか、逆に本物のメールが1枚消える。

. "$RepoRoot\phase2\lib\TaskStore.ps1"

if (-not (Test-SqliteAvailable)) {
    Describe 'タスクストア' { Skip-It 'すべて' 'winsqlite3.dll が使えません' }
    return
}

Describe 'イベントの取り込み (冪等)' {
    $conn = New-TestStore

    It '同じ通知を2回入れてもイベントは1件' {
        $a = Add-Event -Conn $conn -Source 'notification' -SourceKey 'k1' -Title 'x' -OccurredAt '2026-09-12T10:00:00'
        $b = Add-Event -Conn $conn -Source 'notification' -SourceKey 'k1' -Title 'x' -OccurredAt '2026-09-12T10:00:00'
        Assert-True $a.isNew
        Assert-False $b.isNew
        Assert-Equal $a.id $b.id
    }

    It '後から同一性 (dedup_key) を付け直せる' {
        [void] (Add-Event -Conn $conn -Source 'notification' -SourceKey 'k2' -Title 'x' -OccurredAt '2026-09-12T10:00:00')
        [void] (Add-Event -Conn $conn -Source 'notification' -SourceKey 'k2' -Title 'x' -OccurredAt '2026-09-12T10:00:00' -DedupKey 'mail:a|b')
        $row = @($conn.Query('SELECT dedup_key FROM events WHERE id = ?', [object[]] @('notification|k2')))[0]
        Assert-Equal 'mail:a|b' $row['dedup_key']
    }

    Close-TestStore $conn
}

Describe '同一性の組み立て' {

    It '通知と同期が同じ鍵を作る (Slack)' {
        $fromNotification = New-EventIdentity -Kind 'slack' -Parts @('C123', '1700000000.000100')
        $fromSync         = New-EventIdentity -Kind 'slack' -Parts @('c123', ' 1700000000.000100 ')
        Assert-Equal $fromNotification $fromSync
    }

    It '材料が欠けていたら鍵を作らない (空どうしが一致してしまうため)' {
        Assert-Null (New-EventIdentity -Kind 'mail' -Parts @('件名', ''))
        Assert-Null (New-EventIdentity -Kind 'mail' -Parts @())
        Assert-Null (New-EventIdentity -Kind 'mail' -Parts $null)
    }

    It 'From ヘッダから表示名だけを取り出す' {
        Assert-Equal 'F.Amano' (Get-MailDisplayName '"F.Amano" <notifications@github.com>')
        Assert-Equal 'notifications@github.com' (Get-MailDisplayName '<notifications@github.com>')
        Assert-Equal 'plain@example.com' (Get-MailDisplayName 'plain@example.com')
    }

    It 'Slack 通知の launch から鍵を作る' {
        $n = [pscustomobject]@{ launch = 'slack://channel?id=C0AB&message=1700000000.000100' }
        Assert-Equal (New-EventIdentity -Kind 'slack' -Parts @('C0AB', '1700000000.000100')) (Get-NotificationIdentity $n)
    }

    It 'Slack 通知でも主キーが無ければ鍵を作らない' {
        Assert-Null (Get-NotificationIdentity ([pscustomobject]@{ launch = 'slack://open' }))
    }

    It 'Gmail の Web 通知は差出人と件名で鍵を作る' {
        $n = [pscustomobject]@{ attribution = 'mail.google.com'; title = 'GitHub'; body = 'Run failed' }
        Assert-Equal (New-EventIdentity -Kind 'mail' -Parts @('Run failed', 'GitHub')) (Get-NotificationIdentity $n)
    }

    It '同期側の行からも同じ鍵が計算できる' {
        $row = @{
            source = 'gmail'
            raw_json = (@{ subject = 'Run failed'; from = '"GitHub" <notifications@github.com>' } | ConvertTo-Json -Compress)
        }
        Assert-Equal (New-EventIdentity -Kind 'mail' -Parts @('Run failed', 'GitHub')) (Get-EventIdentityFromRow -Row $row)
    }
}

Describe '通知と同期の突き合わせ' {
    $conn = New-TestStore
    $key = 'mail:run failed|github'
    $now = (Get-Date).ToString('o')

    [void] (Add-Event -Conn $conn -Source 'notification' -SourceKey 'n1' -Title 'GitHub' -Body 'Run failed' `
                -OccurredAt $now -DedupKey $key)
    [void] (Add-Event -Conn $conn -Source 'gmail' -SourceKey 'g1' -Title 'Run failed' -Body '本文' `
                -OccurredAt $now -DedupKey $key)

    It '経路をまたいだ相手が見つかる' {
        $evt = @($conn.Query("SELECT * FROM events WHERE id = 'gmail|g1'"))[0]
        $c = Find-EventCounterpart -Conn $conn -Evt $evt
        Assert-NotNull $c
        Assert-Equal 'notification|n1' $c['id']
    }

    It '同じ経路どうしは束ねない (同じ件名のメールが2通来ても消えない)' {
        [void] (Add-Event -Conn $conn -Source 'gmail' -SourceKey 'g2' -Title 'Run failed' -Body '本文2' `
                    -OccurredAt $now -DedupKey $key)
        $evt = @($conn.Query("SELECT * FROM events WHERE id = 'gmail|g2'"))[0]
        $c = Find-EventCounterpart -Conn $conn -Evt $evt
        Assert-Equal 'notification|n1' $c['id']
    }

    It '同期が通知に勝つ' {
        Assert-True ((Get-EventRank 'gmail') -gt (Get-EventRank 'notification'))
        Assert-True ((Get-EventRank 'slack') -gt (Get-EventRank 'notification'))
    }

    It '時刻が離れていれば束ねない' {
        $old = (Get-Date).AddHours(-5).ToString('o')
        [void] (Add-Event -Conn $conn -Source 'notification' -SourceKey 'n9' -Title 'GitHub' `
                    -OccurredAt $old -DedupKey 'mail:別件|github')
        [void] (Add-Event -Conn $conn -Source 'gmail' -SourceKey 'g9' -Title '別件' `
                    -OccurredAt $now -DedupKey 'mail:別件|github')
        $evt = @($conn.Query("SELECT * FROM events WHERE id = 'gmail|g9'"))[0]
        Assert-Null (Find-EventCounterpart -Conn $conn -Evt $evt)
    }

    It '通知で立ったカードは増やさず土台だけ差し替える' {
        $taskId = New-Task -Conn $conn -EventId 'notification|n1' -Title '通知から立ったカード'
        Assert-NotNull $taskId
        Move-TaskEvent -Conn $conn -TaskId ([int] $taskId) -EventId 'gmail|g1'
        $t = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($taskId)))[0]
        Assert-Equal 'gmail|g1' $t['event_id']
        # 差し替えは内容を書き換えたわけではないので版は上げない
        Assert-Equal 1 $t['version']
    }

    It '片付けたイベントは未判定の一覧に出てこない' {
        Set-EventSuperseded -Conn $conn -EventId 'notification|n1' -CanonicalId 'gmail|g1'
        $ids = @(Get-UntriagedEvents -Conn $conn | ForEach-Object { [string] $_['id'] })
        Assert-False ($ids -contains 'notification|n1')
    }

    Close-TestStore $conn
}

Describe 'カードの更新と楽観ロック' {
    $conn = New-TestStore
    $id = [int] (New-Task -Conn $conn -Title 'カード' -Column 'todo')

    It '版が合っていれば移動できる' {
        Assert-True (Set-TaskColumn -Conn $conn -TaskId $id -Column 'doing' -ExpectedVersion 1)
    }

    It '古い版では移動できない (画面が古いまま押した場合)' {
        Assert-False (Set-TaskColumn -Conn $conn -TaskId $id -Column 'done' -ExpectedVersion 1)
    }

    It '更新できる列はホワイトリストで固定されている' {
        Assert-True (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ user_edited = '書いた' })
        # board_column は Update-TaskFields からは触れない (移動は Set-TaskColumn の仕事)
        Assert-False (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ board_column = 'done' })
        $t = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($id)))[0]
        Assert-Equal '書いた' $t['user_edited']
        Assert-Equal 'doing' $t['board_column']
    }

    It 'エージェントの再生成は利用者の編集を踏まない' {
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ draft_text = 'ワーカーの案' })
        $t = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($id)))[0]
        Assert-Equal '書いた' $t['user_edited']
        Assert-Equal 'ワーカーの案' $t['draft_text']
    }

    Close-TestStore $conn
}

Describe 'ワーカーへの受け渡し' {
    $conn = New-TestStore

    It '要対応のカードを1枚取り、実行中に移してリースを張る' {
        $id = [int] (New-Task -Conn $conn -Title '拾われるカード' -Column 'todo')
        $t = Get-NextWorkItem -Conn $conn
        Assert-NotNull $t
        Assert-Equal $id $t['id']
        $row = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($id)))[0]
        Assert-Equal 'doing' $row['board_column']
        Assert-NotNull $row['agent_lease_until']
    }

    It 'リースが生きているカードは二重に拾わない' {
        Assert-Null (Get-NextWorkItem -Conn $conn)
    }

    It '緊急度の高いカードを先に拾う' {
        [void] (New-Task -Conn $conn -Title '普通' -Column 'todo' -Urgency 'normal')
        $high = [int] (New-Task -Conn $conn -Title '急ぎ' -Column 'todo' -Urgency 'high')
        $t = Get-NextWorkItem -Conn $conn
        Assert-Equal $high $t['id']
    }

    It '設定カードはワーカーが拾わない (人間が資格情報を入れるまで進まないため)' {
        $conn2 = New-TestStore
        $sid = New-SetupTask -Conn $conn2 -What 'GitHub トークン' -HowTo '設定してください' -ServiceKey 'github'
        # 設定カードは review に立つので、todo に動かしてもなお拾われないことを見る
        [void] (Set-TaskColumn -Conn $conn2 -TaskId ([int] $sid) -Column 'todo')
        Assert-Null (Get-NextWorkItem -Conn $conn2)
        Close-TestStore $conn2
    }

    It '中止要求のあるカードは拾わない' {
        $conn3 = New-TestStore
        $id = [int] (New-Task -Conn $conn3 -Title '中止' -Column 'todo')
        [void] (Set-TaskCancel -Conn $conn3 -TaskId $id -Requested $true)
        Assert-Null (Get-NextWorkItem -Conn $conn3)
        Close-TestStore $conn3
    }

    Close-TestStore $conn
}

Describe '設定カード' {
    $conn = New-TestStore

    It 'サービス単位で1枚にまとまる (言い回しが違っても増えない)' {
        $a = New-SetupTask -Conn $conn -What 'GitHub のトークン' -HowTo 'A' -ServiceKey 'github' -BlockedTaskId 1
        $b = New-SetupTask -Conn $conn -What 'GitHub の個人アクセストークン' -HowTo 'B' -ServiceKey 'github' -BlockedTaskId 2
        Assert-Equal $a $b
        Assert-Equal 1 (@(Get-Tasks -Conn $conn | Where-Object { $_['subject_key'] -eq 'setup:github' }).Count)
    }

    It '待っているカードの数が回数として積まれる' {
        $t = @($conn.Query("SELECT * FROM tasks WHERE subject_key = 'setup:github'"))[0]
        Assert-Equal 2 $t['occurrence_count']
    }

    It 'カンバンが読む human_step を必ず持つ' {
        $t = @($conn.Query("SELECT * FROM tasks WHERE subject_key = 'setup:github'"))[0]
        $hs = [string] $t['human_step'] | ConvertFrom-Json
        Assert-Equal 'credential_missing' $hs.blocker
        Assert-NotNull $hs.step
    }

    It '別のサービスは別のカードになる' {
        $g = New-SetupTask -Conn $conn -What 'Google の権限' -HowTo 'C' -ServiceKey 'google'
        Assert-Equal 2 (@(Get-Tasks -Conn $conn | Where-Object { ([string] $_['subject_key']).StartsWith('setup:') }).Count)
    }

    Close-TestStore $conn
}

Describe 'カードの削除' {
    $conn = New-TestStore

    It 'カードを参照している行ごと消える (外部キーで失敗しない)' {
        $id = [int] (New-Task -Conn $conn -Title '消すカード' -Column 'done')
        [void] (Add-TaskComment -Conn $conn -TaskId $id -Author 'user' -Body 'コメント')
        Add-TaskActivity -Conn $conn -TaskId $id -Kind 'step' -Message '作業'
        [void] (New-ToolRequest -Conn $conn -TaskId $id -Tool 'run_command' -Summary 's' -Detail 'd')
        Add-ToolGrant -Conn $conn -Scope 'task' -ScopeId $id -Tool 'run_command'
        Add-TaskAttempt -Conn $conn -TaskId $id -Tool 'http_request' -Outcome 'failed'

        Assert-True (Remove-Task -Conn $conn -TaskId $id)
        Assert-Equal 0 (@($conn.Query('SELECT * FROM task_comments WHERE task_id = ?', [object[]] @($id))).Count)
        Assert-Equal 0 (@($conn.Query('SELECT * FROM task_activity WHERE task_id = ?', [object[]] @($id))).Count)
        Assert-Equal 0 (@($conn.Query('SELECT * FROM tool_requests WHERE task_id = ?', [object[]] @($id))).Count)
        Assert-Equal 0 (@($conn.Query("SELECT * FROM tool_grants WHERE scope = 'task' AND scope_id = ?", [object[]] @($id))).Count)
    }

    It 'まとめて削除は途中で失敗しても半端に消さない' {
        $a = [int] (New-Task -Conn $conn -Title 'a' -Column 'done')
        $b = [int] (New-Task -Conn $conn -Title 'b' -Column 'done')
        Assert-Equal 2 (Remove-Tasks -Conn $conn -TaskIds @($a, $b))
        Assert-Equal 0 (@(Get-Tasks -Conn $conn -Column 'done').Count)
    }

    Close-TestStore $conn
}

Describe '承認と権限' {
    $conn = New-TestStore
    $id = [int] (New-Task -Conn $conn -Title '承認のカード')

    It '許可していないツールは許可済みにならない' {
        Assert-False (Test-ToolGranted -Conn $conn -TaskId $id -Tool 'run_command')
    }

    It 'カード単位の許可は他のカードに効かない' {
        Add-ToolGrant -Conn $conn -Scope 'task' -ScopeId $id -Tool 'run_command'
        Assert-True  (Test-ToolGranted -Conn $conn -TaskId $id -Tool 'run_command')
        Assert-False (Test-ToolGranted -Conn $conn -TaskId ($id + 999) -Tool 'run_command')
    }

    It '全体の許可はどのカードにも効く' {
        Add-ToolGrant -Conn $conn -Scope 'global' -ScopeId $null -Tool 'http_request'
        Assert-True (Test-ToolGranted -Conn $conn -TaskId ($id + 999) -Tool 'http_request')
    }

    It '承認の決着は一度だけ (二重承認を弾く)' {
        $r = [int] (New-ToolRequest -Conn $conn -TaskId $id -Tool 'send_gmail' -Summary 's' -Detail 'd')
        Assert-True  (Set-ToolRequestStatus -Conn $conn -RequestId $r -Status 'approved')
        Assert-False (Set-ToolRequestStatus -Conn $conn -RequestId $r -Status 'denied')
    }

    It 'YOLO は既定で無効' {
        Assert-False (Test-YoloMode -Conn $conn)
    }

    Close-TestStore $conn
}

Describe '連続失敗の数え方 (棚上げの判断材料)' {
    $conn = New-TestStore
    $id = [int] (New-Task -Conn $conn -Title '失敗するカード')

    It '成功が出たらそこで数え直す' {
        Add-TaskActivity -Conn $conn -TaskId $id -Kind 'error' -Message '1'
        Add-TaskActivity -Conn $conn -TaskId $id -Kind 'done'  -Message 'ok'
        Add-TaskActivity -Conn $conn -TaskId $id -Kind 'error' -Message '2'
        Add-TaskActivity -Conn $conn -TaskId $id -Kind 'error' -Message '3'
        Assert-Equal 2 (Get-ConsecutiveFailures -Conn $conn -TaskId $id)
    }

    Close-TestStore $conn
}
