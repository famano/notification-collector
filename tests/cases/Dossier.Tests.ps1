# Dossier.Tests.ps1
# 「同じ件か」を決める subject_key と、件をまたぐ台帳。
#
# ここが崩れると症状が二通りに出る。束ね損ねればカードが増殖し (CI の失敗が5枚)、
# 束ねすぎれば無関係な用事が1枚に潰れて片方が消える。後者は取り返しがつかないので、
# 「迷ったらキーを付けない」が守られていることも一緒に見ておく。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase2\lib\Dossier.ps1"

function New-TestEvent {
    param([string] $Source = 'notification', [string] $App, [string] $Link, [string] $Title, [string] $Body)
    return @{ source = $Source; app = $App; link = $Link; title = $Title; body = $Body }
}

Describe 'ConvertTo-SubjectStem (件名から回ごとに変わる部分を落とす)' {

    It 'コミットハッシュ違いは同じ幹になる' {
        $a = ConvertTo-SubjectStem 'Run failed: Security - main (c5857b6)'
        $b = ConvertTo-SubjectStem 'Run failed: Security - main (515c237)'
        Assert-Equal $a $b
        Assert-NotNull $a
    }

    It 'Re: と Fwd: の重なりを落とす' {
        Assert-Equal (ConvertTo-SubjectStem '見積の件') (ConvertTo-SubjectStem 'Re: Fwd: Re: 見積の件')
    }

    It '番号だけ違う件名は同じ幹になる' {
        Assert-Equal (ConvertTo-SubjectStem 'Issue #12 が更新されました') (ConvertTo-SubjectStem 'Issue #4567 が更新されました')
    }

    It '数字と記号だけの件名は空になる (束ねる材料が無い)' {
        Assert-Equal '' (ConvertTo-SubjectStem '2026/09/12 10:30')
    }

    It '別の用事は別の幹になる' {
        Assert-NotEqual (ConvertTo-SubjectStem '請求書の送付') (ConvertTo-SubjectStem '歓迎会の日程')
    }
}

Describe 'Get-SubjectKey (件の同一性)' {

    It 'Claude のセッションはセッション名で束ねる' {
        $e = New-TestEvent -App 'Claude' -Title 'notification-collector の改修'
        Assert-Match '^claude-session:' (Get-SubjectKey -Evt $e)
    }

    It '同じセッションの入力待ちは何度来ても同じ件' {
        $a = Get-SubjectKey -Evt (New-TestEvent -App 'Claude' -Title 'repo の改修')
        $b = Get-SubjectKey -Evt (New-TestEvent -App 'Claude' -Title 'repo の改修')
        Assert-Equal $a $b
    }

    It 'Slack はリンクを解けないときキーを付けない (チャンネル全体を1件に潰さない)' {
        # ConvertFrom-SlackLink を読み込んでいない状態 = 解けない状態
        $e = New-TestEvent -Link 'slack://channel?id=C123&message=1700000000.000100' -Title '#tech-sales'
        Assert-Equal '' (Get-SubjectKey -Evt $e)
    }

    It 'メールは差出人と件名の幹で束ねる' {
        $e = New-TestEvent -Source 'gmail' -Title 'Run failed: Security - main (c5857b6)' `
                -Body "差出人: GitHub <notifications@github.com>`n本文"
        $k = Get-SubjectKey -Evt $e
        Assert-Match '^mail:notifications@github\.com:' $k
    }

    It '同じ件名でも差出人が違えば別の件' {
        $a = Get-SubjectKey -Evt (New-TestEvent -Source 'gmail' -Title '請求書' -Body '差出人: A <a@example.com>')
        $b = Get-SubjectKey -Evt (New-TestEvent -Source 'gmail' -Title '請求書' -Body '差出人: B <b@example.com>')
        Assert-NotEqual $a $b
    }

    It '件名が無い通知にはキーを付けない' {
        Assert-Equal '' (Get-SubjectKey -Evt (New-TestEvent -App 'Chrome' -Title ''))
    }
}

Describe '台帳 (件をまたいで持ち越す)' {

    if (-not (Test-SqliteAvailable)) {
        Skip-It '台帳の読み書き' 'winsqlite3.dll が使えません'
    }
    else {
        $conn = New-TestStore

        It '書いたものが読み出せる' {
            [void] (Add-DossierNote -Conn $conn -SubjectKey 'mail:a:b' -Note '非公開リポジトリなので未認証では読めない')
            Assert-Match '非公開リポジトリ' (Get-DossierText -Conn $conn -SubjectKey 'mail:a:b')
        }

        It '別の件の記録は混ざらない' {
            Assert-Equal '' (Get-DossierText -Conn $conn -SubjectKey 'mail:x:y')
        }

        It '空白だけの記録は書かない' {
            Assert-False (Add-DossierNote -Conn $conn -SubjectKey 'mail:blank' -Note '   ')
            Assert-Equal '' (Get-DossierText -Conn $conn -SubjectKey 'mail:blank')
        }

        It 'サービス単位の記録はサービス名で出る' {
            [void] (Add-DossierNote -Conn $conn -SubjectKey 'svc:github' -Kind 'credential' -Note 'トークン未設定')
            $t = Get-ServiceDossierText -Conn $conn
            Assert-Match 'github' $t
            Assert-Match 'トークン未設定' $t
            # 件単位の記録まで混ぜない
            Assert-True ($t -notmatch '非公開リポジトリ') '件単位の記録が混ざっています'
        }

        It '同じ件で開いているカードを見つける' {
            $id = New-Task -Conn $conn -Title '同じ件' -SubjectKey 'mail:a:b' -Column 'todo'
            $open = Get-OpenTaskBySubject -Conn $conn -SubjectKey 'mail:a:b'
            Assert-NotNull $open
            Assert-Equal $id $open['id']
        }

        It '閉じたカードは「開いている」に数えない (再発は新しいカード)' {
            $id = New-Task -Conn $conn -Title '閉じた件' -SubjectKey 'mail:closed' -Column 'done'
            Assert-Null (Get-OpenTaskBySubject -Conn $conn -SubjectKey 'mail:closed')
        }

        It '同じ件が届いたらカードを増やさず回数を足す' {
            $id = [int] (New-Task -Conn $conn -Title '積む件' -SubjectKey 'mail:stack' -Column 'todo')
            Assert-Equal 2 (Add-TaskOccurrence -Conn $conn -TaskId $id)
            Assert-Equal 3 (Add-TaskOccurrence -Conn $conn -TaskId $id)
            Assert-Equal 1 (@(Get-Tasks -Conn $conn | Where-Object { $_['subject_key'] -eq 'mail:stack' }).Count)
        }

        Close-TestStore $conn
    }
}
