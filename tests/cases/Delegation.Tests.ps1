# Delegation.Tests.ps1
# 道具が足りない作業 (リポジトリのコード修正) を Claude Code に渡すこと。
#
# 実際に claude を走らせるテストは書かない (費用がかかり、利用者の環境に依存する)。
# 見ているのは、渡す枠が固定されていること ―― 新しいブランチ・push させない・
# 第三者の文面を指示として扱わせない・画面から受け取ったパスをそのまま信じない。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase4\lib\Delegation.ps1"

Describe '渡す文面' {

    $p = New-DelegationPrompt -Title 'CI 失敗' -Step 'PromptCache.Tests.ps1 の期待値2行を新しい文言に合わせる' `
            -Tried 'annotations: 期待 [読んだ分] / 実際 [キャッシュヒット]' -Repo 'famano/notification-collector' -Branch 'nc/task-0295'

    It '直すことは <handoff> の中に入れ、指示として扱わせない' {
        Assert-Match '(?s)<handoff>.*期待値2行.*</handoff>' $p
        Assert-Match '作業の範囲を広げないでください' $p
    }

    It '新しいブランチで作業し、push はさせない' {
        Assert-Match 'nc/task-0295' $p
        Assert-Match 'push はしないでください' $p
    }

    It 'ファイルを丸ごと書き換えさせない。テストで確かめさせる' {
        Assert-Match '丸ごと書き換えないでください' $p
        Assert-Match 'テスト' $p
    }

    It 'ブランチ名はカード番号から決める' {
        Assert-Equal 'nc/task-0007' (Get-DelegationBranch -TaskId 7)
    }
}

Describe 'Claude Code に渡す引数' {

    $args_ = Get-DelegationArguments -SettingsPath 'C:\tmp\s.json' -MaxBudgetUsd 3

    It '非対話・JSON で受け取り、費用に上限を付ける' {
        Assert-True ($args_ -contains '-p')
        Assert-Equal 'json' $args_[([array]::IndexOf($args_, '--output-format') + 1)]
        Assert-Equal '3' $args_[([array]::IndexOf($args_, '--max-budget-usd') + 1)]
    }

    It 'push・gh・Web を止める (引数と設定の両方で)' {
        $dis = $args_[([array]::IndexOf($args_, '--disallowedTools') + 1)]
        Assert-Match 'Bash\(git push \*\)' $dis
        Assert-Match 'Bash\(gh \*\)' $dis
        Assert-Match 'WebFetch' $dis
        $deny = @((Get-DelegationSettings).permissions.deny)
        Assert-True ($deny -contains 'Bash(git push *)')
        Assert-True ($deny -contains 'Bash(git checkout *)')
        Assert-True ($deny -contains 'WebSearch')
    }

    It 'コマンドラインの引用 (空白と引用符)' {
        Assert-Equal 'plain' (ConvertTo-CommandLineArgument 'plain')
        Assert-Equal '"a b"' (ConvertTo-CommandLineArgument 'a b')
        Assert-Equal '"say \"hi\""' (ConvertTo-CommandLineArgument 'say "hi"')
        Assert-Equal '"C:\dir x\\"' (ConvertTo-CommandLineArgument 'C:\dir x\')
    }
}

Describe '結果の読み方' {

    It 'result / total_cost_usd の形を読む' {
        $r = ConvertFrom-DelegationOutput '{"type":"result","subtype":"success","is_error":false,"result":"直しました","session_id":"s1","total_cost_usd":0.42}'
        Assert-Equal '直しました' $r.text
        Assert-False $r.isError
        Assert-Equal 0.42 $r.cost
    }

    It 'text / cost の形も読む (版の違い)' {
        $r = ConvertFrom-DelegationOutput '{"text":"ok","cost":1,"sessionId":"s","is_error":false}'
        Assert-Equal 'ok' $r.text
        Assert-Equal 's' $r.sessionId
    }

    It '前に余計な行があっても最後の JSON を読む' {
        $r = ConvertFrom-DelegationOutput ("warning: something`n" + '{"result":"x","is_error":false}')
        Assert-Equal 'x' $r.text
    }

    It 'JSON でなければ失敗として出力をそのまま返す' {
        $r = ConvertFrom-DelegationOutput 'Error: not logged in'
        Assert-True $r.isError
        Assert-Match 'not logged in' $r.text
    }
}

Describe '手元の clone を確かめる' {

    It 'origin がそのリポジトリを指すフォルダだけを通す' {
        $url = ''
        try { $url = [string] (& git -C $RepoRoot remote get-url origin 2>$null) } catch { }
        if ($url -notmatch '(?i)github\.com[:/](?<r>[^/]+/[^/]+?)(\.git)?$') { Skip-It 'origin' 'GitHub の clone ではありません'; return }
        $repo = $Matches['r']
        Assert-True (Test-RepoMatchesRemote -Path $RepoRoot -Repo $repo)
        Assert-False (Test-RepoMatchesRemote -Path $RepoRoot -Repo 'someone/else')
    }

    It 'git の作業ツリーでないフォルダは通さない' {
        Assert-False (Test-RepoMatchesRemote -Path (New-TestTempDir) -Repo 'famano/notification-collector')
    }

    It 'owner/name の形でなければ通さない' {
        Assert-False (Test-RepoName '../x')
        Assert-False (Test-RepoName 'a/b/c')
        Assert-True (Test-RepoName 'famano/notification-collector')
    }
}

Describe '渡せるカードか' {

    if (-not (Test-SqliteAvailable)) { Skip-It 'カード' 'winsqlite3 が使えません'; return }
    $conn = New-TestStore

    It 'リポジトリの引き渡しでないカードは渡せない' {
        $id = [int] (New-Task -Conn $conn -Title 'x' -Column 'review')
        $i = Get-DelegationInfo -Conn $conn -TaskId $id
        Assert-False $i.eligible
        $hs = @{ blocker = 'physical_presence'; step = '本人確認'; repo = 'a/b' } | ConvertTo-Json -Compress
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ human_step = $hs })
        Assert-False (Get-DelegationInfo -Conn $conn -TaskId $id).eligible
    }

    It 'beyond_tools でリポジトリが書かれていれば、渡す文面を出す' {
        $id = [int] (New-Task -Conn $conn -Title 'CI 失敗' -Column 'review')
        $hs = @{ blocker = 'beyond_tools'; step = '期待値を直す'; repo = 'famano/notification-collector' } | ConvertTo-Json -Compress
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ human_step = $hs; shape = 'human' })
        Set-Setting -Conn $conn -Key 'delegate.repo.famano/notification-collector' -Value 'C:\src\nc'
        $i = Get-DelegationInfo -Conn $conn -TaskId $id
        Assert-True $i.eligible
        Assert-Equal 'famano/notification-collector' $i.repo
        Assert-Equal 'C:\src\nc' $i.path
        Assert-Match '期待値を直す' $i.prompt
        Assert-False $i.running
    }

    Close-TestStore $conn
}
