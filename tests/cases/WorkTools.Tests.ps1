# WorkTools.Tests.ps1
# ワーカーのツールの「危険度の判定」と「人間送りのゲート」。
#
# この2つはこのアプリの安全側の要。危険度が甘いと承認画面を通らずに外へ出てしまい、
# ゲートが甘いと「調べずに諦めたカード」が人間に投げ返される。
# どちらも壊れても静かなので、ここで固定する。

. "$RepoRoot\phase4\lib\WorkTools.ps1"

function New-ToolInput { param([hashtable] $H) return [pscustomobject] $H }

Describe '危険度の判定 (承認が要るか)' {
    $ws = if ($env:TEMP) { Join-Path $env:TEMP 'nc-ws' } else { '/tmp/nc-ws' }
    $ws = [IO.Path]::GetFullPath($ws)

    It '作業フォルダ内のテキスト作成は承認不要' {
        $r = Get-ToolRisk -Name 'write_file' -Workspace $ws -ToolInput (New-ToolInput @{ path = 'memo.md'; content = 'x'; purpose = 'p' })
        Assert-False $r.risky
    }

    It '作業フォルダの外への書き込みは承認が要る' {
        $outside = [IO.Path]::GetFullPath((Join-Path $ws '..\..\elsewhere.txt'))
        $r = Get-ToolRisk -Name 'write_file' -Workspace $ws -ToolInput (New-ToolInput @{ path = $outside; content = 'x'; purpose = 'p' })
        Assert-True $r.risky
        Assert-Match '作業フォルダの外' $r.detail
    }

    It '実行される可能性のある拡張子は作業フォルダ内でも承認が要る' {
        $r = Get-ToolRisk -Name 'write_file' -Workspace $ws -ToolInput (New-ToolInput @{ path = 'run.ps1'; content = 'x'; purpose = 'p' })
        Assert-True $r.risky
    }

    It 'コマンド実行は常に承認が要り、実行内容が全文出る' {
        $r = Get-ToolRisk -Name 'run_command' -Workspace $ws -ToolInput (New-ToolInput @{ command = 'Get-Process'; purpose = '確認' })
        Assert-True $r.risky
        Assert-Match 'Get-Process' $r.detail
    }

    It '書き込み系の HTTP は常に承認が要る' {
        foreach ($m in @('POST', 'PATCH', 'PUT', 'DELETE', 'post')) {
            $r = Get-ToolRisk -Name 'http_request' -Workspace $ws -ToolInput (New-ToolInput @{ method = $m; url = 'https://api.github.com/x'; purpose = 'p' })
            Assert-True $r.risky ("{0} が承認なしになっています" -f $m)
        }
    }

    It '認証の付く既知ホストの GET は承認不要 (同期の読み取りと変わらない)' {
        # 資格情報が設定されている環境でだけ成り立つ判定なので、
        # 設定が無い環境では「承認が要る」ほうに倒れていることを確かめる
        $r = Get-ToolRisk -Name 'http_request' -Workspace $ws -ToolInput (New-ToolInput @{ method = 'GET'; url = 'https://api.github.com/user'; purpose = 'p' })
        if (Get-RequestCredential -Url 'https://api.github.com/user') { Assert-False $r.risky }
        else { Assert-True $r.risky }
    }

    It '知らないホストへの GET は承認が要る (URL 自体に情報が載ることがある)' {
        $r = Get-ToolRisk -Name 'http_request' -Workspace $ws -ToolInput (New-ToolInput @{ method = 'GET'; url = 'https://example.com/?q=secret'; purpose = 'p' })
        Assert-True $r.risky
    }

    It '承認画面にはモデルが書いた宛先ではなく、束縛された投稿先を出す' {
        $r = Get-ToolRisk -Name 'send_slack_message' -Workspace $ws -SlackChannelName '#general' `
                -ToolInput (New-ToolInput @{ text = 'こんにちは'; channel = '#secret-channel' })
        Assert-True $r.risky
        Assert-Match '#general' $r.detail
        Assert-True ($r.detail -notmatch '#secret-channel') 'モデルの指定した宛先が承認画面に出ています'
        Assert-Match 'こんにちは' $r.detail
    }

    It 'メール送信は宛先と本文を全文出す' {
        $r = Get-ToolRisk -Name 'send_gmail' -Workspace $ws -GmailThreadLabel '元のスレッドへの返信として送信' `
                -ToolInput (New-ToolInput @{ to = 'a@example.com'; subject = '件名'; body = '本文です' })
        Assert-True $r.risky
        Assert-Match 'a@example\.com' $r.detail
        Assert-Match '本文です' $r.detail
    }

    It 'Gmail の下書き作成も承認が要る (利用者のメールボックスに物が残る)' {
        $r = Get-ToolRisk -Name 'create_gmail_draft' -Workspace $ws -ToolInput (New-ToolInput @{ subject = 's'; body = 'b' })
        Assert-True $r.risky
    }

    It '見るだけのツールは承認不要' {
        foreach ($n in @('open_source', 'fetch_attachment', 'recall', 'record_finding', 'require_human_step')) {
            $r = Get-ToolRisk -Name $n -Workspace $ws -ToolInput (New-ToolInput @{})
            Assert-False $r.risky ("{0} が承認を求めています" -f $n)
        }
    }
}

Describe '取り消せないツール' {

    It '送信は取り消せない' {
        Assert-True (Test-IrreversibleTool -Name 'send_gmail' -ToolInput (New-ToolInput @{}))
        Assert-True (Test-IrreversibleTool -Name 'send_slack_message' -ToolInput (New-ToolInput @{}))
    }

    It '書き込み系の HTTP も取り消せない扱い (承諾した招待は戻せない)' {
        Assert-True  (Test-IrreversibleTool -Name 'http_request' -ToolInput (New-ToolInput @{ method = 'POST' }))
        Assert-False (Test-IrreversibleTool -Name 'http_request' -ToolInput (New-ToolInput @{ method = 'GET' }))
        Assert-False (Test-IrreversibleTool -Name 'http_request' -ToolInput (New-ToolInput @{}))
    }

    It '下書きとファイル作成は取り消せる' {
        Assert-False (Test-IrreversibleTool -Name 'create_gmail_draft' -ToolInput (New-ToolInput @{}))
        Assert-False (Test-IrreversibleTool -Name 'write_file' -ToolInput (New-ToolInput @{}))
    }
}

Describe '人間送りのゲート' {

    It '出自を読んでいなければ差し戻す' {
        $r = Test-HumanStepAllowed -Attempts @() -Blocker 'physical_presence'
        Assert-False $r.ok
        Assert-Match 'open_source' $r.reason
    }

    It '出自を取り直せないカードでは open_source を求めない' {
        $r = Test-HumanStepAllowed -Attempts @() -Blocker 'physical_presence' -SourceUnavailable
        Assert-True $r.ok
    }

    It '権限不足は、実際に叩いて断られた記録が無ければ差し戻す' {
        $attempts = @(@{ tool = 'open_source'; outcome = 'ok' })
        $r = Test-HumanStepAllowed -Attempts $attempts -Blocker 'credential_missing'
        Assert-False $r.ok
        Assert-Match 'http_request' $r.reason
    }

    It '叩いた記録があれば権限不足を認める' {
        $attempts = @(@{ tool = 'open_source'; outcome = 'ok' }, @{ tool = 'http_request'; outcome = 'failed' })
        Assert-True (Test-HumanStepAllowed -Attempts $attempts -Blocker 'credential_missing').ok
    }

    It '「手段が無い」も調べずには宣言させない' {
        $attempts = @(@{ tool = 'open_source'; outcome = 'ok' })
        Assert-False (Test-HumanStepAllowed -Attempts $attempts -Blocker 'no_api').ok
    }

    It '生体認証や支払いは、出自を読んでいれば通す (叩いても解決しないため)' {
        $attempts = @(@{ tool = 'open_source'; outcome = 'ok' })
        Assert-True (Test-HumanStepAllowed -Attempts $attempts -Blocker 'physical_presence').ok
        Assert-True (Test-HumanStepAllowed -Attempts $attempts -Blocker 'payment_or_legal').ok
    }
}

Describe 'ツール一覧の出し分け' {

    It '返信先の無いカードには返信文面のツールを見せない' {
        $names = @((Get-WorkTools) | ForEach-Object { $_.name })
        Assert-False ($names -contains 'propose_reply')
    }

    It '返信先があるカードには見せる' {
        $names = @((Get-WorkTools -HasOutlet) | ForEach-Object { $_.name })
        Assert-True ($names -contains 'propose_reply')
    }

    It '人間送りの出口は常に見せる' {
        $names = @((Get-WorkTools) | ForEach-Object { $_.name })
        Assert-True ($names -contains 'require_human_step')
    }

    It 'Slack の投稿先が無ければ投稿ツールは出さない' {
        $names = @((Get-WorkTools) | ForEach-Object { $_.name })
        Assert-False ($names -contains 'send_slack_message')
    }

    It '人間送りの理由は閉じた集合から選ばせる' {
        $tool = @((Get-WorkTools) | Where-Object { $_.name -eq 'require_human_step' })[0]
        $enum = @($tool.input_schema.properties.blocker.enum)
        Assert-Equal 4 $enum.Count
        Assert-True ($enum -contains 'credential_missing')
    }
}

Describe 'メールヘッダの符号化' {

    It 'ASCII はそのまま' {
        Assert-Equal 'Hello' (ConvertTo-MimeHeader 'Hello')
    }

    It '日本語は RFC2047 で符号化する' {
        $v = ConvertTo-MimeHeader '件名です'
        Assert-Match '^=\?UTF-8\?B\?.+\?=$' $v
        $b64 = $v -replace '^=\?UTF-8\?B\?', '' -replace '\?=$', ''
        Assert-Equal '件名です' ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)))
    }
}

Describe 'パスの解決' {
    $ws = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'nc-ws'))

    It '相対パスは作業フォルダ基準' {
        $p = Resolve-TargetPath -Workspace $ws -Relative 'a.txt'
        Assert-Equal ([IO.Path]::GetFullPath((Join-Path $ws 'a.txt'))) $p
    }

    It '空のファイル名は拒否する' {
        Assert-Throws { Resolve-TargetPath -Workspace $ws -Relative '  ' }
    }

    It '作業フォルダ内かどうかを見分ける' {
        Assert-True  (Test-InWorkspace $ws (Join-Path $ws 'a.txt'))
        Assert-False (Test-InWorkspace $ws ([IO.Path]::GetFullPath((Join-Path $ws '..\other\a.txt'))))
    }
}
