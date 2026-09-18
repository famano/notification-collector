# WorkerSession.Tests.ps1
# ワーカーの会話を残し、やり直しを続きから行うこと。
#
# #295 で起きたことの半分はここにある。
#   - ツールの回数 (12) を使い切ると例外になり、最初からやり直していた。
#     その間に出したもの (PR へのコメント) だけが残り、2回目は急いで PUT を打った
#   - 差し戻しのたびに会話を捨てていたので、3回目は自分が PUT したことを知らず、
#     「GET しか出していない」と答えた
# どちらも壊れていても画面上は普通に動いて見える。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase2\lib\ClaudeClient.ps1"

function New-SessionTestPolicy {
    param([switch] $NoClear)
    $w = [pscustomobject]@{ maxTurns = 40; maxOutputTokens = 16000; clearToolResults = (-not $NoClear) }
    return ([pscustomobject]@{
        llm = [pscustomobject]@{ model = 'claude-opus-5'; effort = 'low'; maxOutputTokens = 1024; cacheTtl = '5m' }
        worker = $w
        context = $null
    })
}

# Send-ClaudeRequest を差し替える。$script:Replies を順に返し、送った payload を JSON で控える。
function Set-FakeClaude {
    param([object[]] $Replies)
    $script:FakeReplies = [System.Collections.ArrayList]::new()
    foreach ($r in $Replies) { [void] $script:FakeReplies.Add($r) }
    $script:FakeSent = @()
}
function Send-ClaudeRequest {
    param([Parameter(Mandatory)] [hashtable] $Payload, [int] $MaxRetries = 2, [int] $TimeoutSec = 600)
    $script:FakeSent += ,(ConvertTo-Json -InputObject (ConvertTo-StableOrder $Payload) -Depth 30 -Compress)
    if ($script:FakeReject -and $Payload.ContainsKey('context_management')) {
        throw 'Claude API エラー (400): context_management: unknown field'
    }
    if ($script:FakeReplies.Count -eq 0) { throw 'テスト側の応答が足りません' }
    $r = $script:FakeReplies[0]
    $script:FakeReplies.RemoveAt(0)
    return $r
}
function New-ToolUseReply {
    param([string] $Id, [string] $Name = 'noop', [string] $Stop = 'tool_use')
    return ([pscustomobject]@{
        stop_reason = $Stop; model = 'claude-opus-5'
        content = @(
            [pscustomobject]@{ type = 'thinking'; thinking = ''; signature = ('sig-' + $Id) },
            [pscustomobject]@{ type = 'tool_use'; id = $Id; name = $Name; input = [pscustomobject]@{ url = 'https://example.com/x' } }
        )
    })
}
function New-TextReply {
    param([string] $Text)
    return ([pscustomobject]@{
        stop_reason = 'end_turn'; model = 'claude-opus-5'
        content = @([pscustomobject]@{ type = 'text'; text = $Text })
    })
}
$script:NoopTool = @{ name = 'noop'; description = 'x'; input_schema = @{ type = 'object'; properties = @{} } }

Describe '会話の保存 (JSON との行き来)' {

    It '読み戻しても中身が変わらない (thinking の署名も)' {
        $m = [System.Collections.ArrayList]::new()
        [void] $m.Add(@{ role = 'user'; content = @(@{ type = 'text'; text = '依頼' }) })
        [void] $m.Add(@{ role = 'assistant'; content = @((New-ToolUseReply 'tu_1').content) })
        $j = ConvertTo-SessionJson -Messages $m
        $back = ConvertFrom-SessionJson -Json $j
        Assert-Equal 2 $back.Count
        Assert-True ($back -is [System.Collections.ArrayList]) 'ArrayList のまま戻ること'
        Assert-Equal 'sig-tu_1' (@($back[1].content) | Where-Object { $_.type -eq 'thinking' }).signature
        Assert-Equal 'https://example.com/x' (@($back[1].content) | Where-Object { $_.type -eq 'tool_use' }).input.url
    }

    It '1件だけの会話も配列のまま戻る' {
        $m = [System.Collections.ArrayList]::new()
        [void] $m.Add(@{ role = 'user'; content = @(@{ type = 'text'; text = '依頼' }) })
        $back = ConvertFrom-SessionJson -Json (ConvertTo-SessionJson -Messages $m)
        Assert-Equal 1 $back.Count
        Assert-Equal 'user' $back[0].role
    }

    It 'キャッシュの区切りは保存しない (再開のたびに増えて上限の4つを超えるため)' {
        $blk = @{ type = 'text'; text = '依頼'; cache_control = @{ type = 'ephemeral' } }
        $m = [System.Collections.ArrayList]::new()
        [void] $m.Add(@{ role = 'user'; content = @($blk) })
        $j = ConvertTo-SessionJson -Messages $m -Mark $blk
        Assert-False ($j -match 'cache_control')
        # 送る側の区切りは外したままにしない
        Assert-Equal 'ephemeral' $blk['cache_control'].type
    }
}

Describe '続きを足す' {

    It '最終応答で終わっていれば、利用者の発言を1つ足す' {
        $m = [System.Collections.ArrayList]::new()
        [void] $m.Add(@{ role = 'user'; content = @(@{ type = 'text'; text = '依頼' }) })
        [void] $m.Add(@{ role = 'assistant'; content = @((New-TextReply '報告').content) })
        Add-ConversationText -Messages $m -Text '直して'
        Assert-Equal 3 $m.Count
        Assert-Equal 'user' $m[2].role
        Assert-Equal '直して' (@($m[2].content))[-1].text
    }

    It 'ツールの結果で終わっていれば、同じ発言の後ろに足す (user を2つ続けない)' {
        $m = [System.Collections.ArrayList]::new()
        [void] $m.Add(@{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'tu_1'; content = 'ok' }) })
        Add-ConversationText -Messages $m -Text '上限です'
        Assert-Equal 1 $m.Count
        $c = @($m[0].content)
        Assert-Equal 'tool_result' $c[0].type
        Assert-Equal '上限です' $c[-1].text
    }

    It '結果の無いツール呼び出し (途中で落ちた跡) は、再実行せず「分からない」と返す' {
        $m = [System.Collections.ArrayList]::new()
        [void] $m.Add(@{ role = 'user'; content = @(@{ type = 'text'; text = '依頼' }) })
        [void] $m.Add(@{ role = 'assistant'; content = @((New-ToolUseReply 'tu_9' 'http_request').content) })
        Add-ConversationText -Messages $m -Text '再開します'
        $c = @($m[2].content)
        Assert-Equal 'tool_result' $c[0].type
        Assert-Equal 'tu_9' $c[0].tool_use_id
        Assert-True ([bool] $c[0].is_error)
        Assert-Match '実行されたかどうかは分かりません' $c[0].content
        Assert-Equal '再開します' $c[-1].text
    }

    It '会話で呼んだツールの名前を拾える (今の一覧に無いものがあれば続けられない)' {
        $m = [System.Collections.ArrayList]::new()
        [void] $m.Add(@{ role = 'assistant'; content = @((New-ToolUseReply 'a' 'http_request').content) })
        [void] $m.Add(@{ role = 'assistant'; content = @((New-ToolUseReply 'b' 'send_gmail').content) })
        [void] $m.Add(@{ role = 'assistant'; content = @((New-ToolUseReply 'c' 'http_request').content) })
        Assert-Equal @('http_request', 'send_gmail') (Get-SessionToolNames -Messages $m)
    }
}

Describe 'ツールの回数の上限 (例外にしない)' {

    Set-FakeClaude @((New-ToolUseReply 'tu_1'), (New-ToolUseReply 'tu_2'), (New-TextReply 'ここまでの報告'))
    $ran = [System.Collections.ArrayList]::new()
    $res = Invoke-ClaudeAgent -Policy (New-SessionTestPolicy) -System 'sys' -Tools @($script:NoopTool) `
              -UserText '依頼' -MaxTurns 2 -OnTool { param($n, $i) [void] $ran.Add($n); @{ text = 'ok'; isError = $false } }.GetNewClosure()

    It '上限に達しても例外にならず、途中の報告が返る' {
        Assert-True $res.partial
        Assert-Equal 'ここまでの報告' $res.text
        Assert-Equal 2 $ran.Count
    }

    It '最後の1回はツールを使わせない (tool_choice none) で報告を書かせる' {
        $last = $script:FakeSent[-1] | ConvertFrom-Json
        Assert-Equal 'none' $last.tool_choice.type
        $tail = @(@($last.messages)[-1].content)
        Assert-Match '上限' $tail[-1].text
    }

    It '上限の前の回には tool_choice を付けない' {
        Assert-Null ($script:FakeSent[0] | ConvertFrom-Json).tool_choice
    }
}

Describe '出力の上限で切れた呼び出しは実行しない' {

    Set-FakeClaude @((New-ToolUseReply 'tu_1' 'noop' 'max_tokens'), (New-TextReply '終わり'))
    $ran = [System.Collections.ArrayList]::new()
    $res = Invoke-ClaudeAgent -Policy (New-SessionTestPolicy) -System 'sys' -Tools @($script:NoopTool) `
              -UserText '依頼' -OnTool { param($n, $i) [void] $ran.Add($n); @{ text = 'ok'; isError = $false } }.GetNewClosure()

    It 'ツールは呼ばれない' {
        Assert-Equal 0 $ran.Count
    }

    It '切れたことをモデルに返す (結果が無いと会話が宙に浮く)' {
        $sent = $script:FakeSent[1] | ConvertFrom-Json
        $r = @(@($sent.messages)[-1].content)[0]
        Assert-Equal 'tool_result' $r.type
        Assert-True ([bool] $r.is_error)
        Assert-Match '上限' $r.content
    }
}

Describe '中止されたとき' {

    $two = [pscustomobject]@{
        stop_reason = 'tool_use'; model = 'claude-opus-5'
        content = @(
            [pscustomobject]@{ type = 'tool_use'; id = 'a'; name = 'noop'; input = [pscustomobject]@{} },
            [pscustomobject]@{ type = 'tool_use'; id = 'b'; name = 'noop'; input = [pscustomobject]@{} }
        )
    }
    Set-FakeClaude @($two)
    $script:Progress = 0
    $res = Invoke-ClaudeAgent -Policy (New-SessionTestPolicy) -System 'sys' -Tools @($script:NoopTool) `
              -UserText '依頼' -OnTool { param($n, $i) @{ text = 'ok'; isError = $false } } `
              -OnProgress { param($n, $i) $script:Progress++; return ($script:Progress -lt 2) }

    It '中止として返る' {
        Assert-True $res.aborted
    }

    It '実行しなかった呼び出しにも結果を付けて残す (再開時に「分からない」扱いにしない)' {
        $tail = @($res.messages[$res.messages.Count - 1].content)
        Assert-Equal 2 $tail.Count
        Assert-Equal 'ok' $tail[0].content
        Assert-Match '中止' $tail[1].content
    }
}

Describe '続きからの再開' {

    $saved = [System.Collections.ArrayList]::new()
    $onSave = { param($j) [void] $saved.Add($j) }.GetNewClosure()

    Set-FakeClaude @((New-ToolUseReply 'tu_1' 'http_request'), (New-TextReply '1回目の報告'))
    $first = Invoke-ClaudeAgent -Policy (New-SessionTestPolicy) -System 'sys' -Tools @($script:NoopTool) `
                -UserText '最初の依頼' -OnTool { param($n, $i) @{ text = 'HTTP 200'; isError = $false } } -OnSave $onSave

    It '会話が伸びるたびに保存する (途中で落ちても続きから始めるため)' {
        Assert-True ($saved.Count -ge 4) ("保存が {0} 回しかありません" -f $saved.Count)
    }

    $restored = ConvertFrom-SessionJson -Json $saved[$saved.Count - 1]
    Set-FakeClaude @((New-TextReply '2回目の報告'))
    $second = Invoke-ClaudeAgent -Policy (New-SessionTestPolicy) -System 'sys' -Tools @($script:NoopTool) `
                -UserText '差し戻しの指示' -Messages $restored -OnTool { param($n, $i) @{ text = 'x'; isError = $false } }
    $sent = $script:FakeSent[0] | ConvertFrom-Json
    $msgs = @($sent.messages)

    It '前回の会話を頭から全部送る (自分が何をしたかを知っている)' {
        Assert-Equal '最初の依頼' (@($msgs[0].content))[0].text
        $tu = @($msgs[1].content) | Where-Object { $_.type -eq 'tool_use' }
        Assert-Equal 'tu_1' $tu.id
        Assert-Equal 'sig-tu_1' (@($msgs[1].content) | Where-Object { $_.type -eq 'thinking' }).signature
    }

    It '新しい指示は末尾に足す (過去の発言は書き換えない)' {
        Assert-Equal 5 $msgs.Count
        Assert-Equal '1回目の報告' (@($msgs[3].content))[0].text
        Assert-Equal '差し戻しの指示' (@($msgs[4].content))[-1].text
        Assert-Equal '2回目の報告' $second.text
    }

    It '区切りは会話側に1つだけ (再開しても増えない)' {
        Assert-Equal 2 ([regex]::Matches($script:FakeSent[0], 'cache_control')).Count
    }
}

Describe '古いツール結果を消す (context editing)' {

    It '既定で付ける。要約ではなく消去' {
        Set-FakeClaude @((New-TextReply 'ok'))
        [void] (Invoke-ClaudeAgent -Policy (New-SessionTestPolicy) -System 's' -Tools @($script:NoopTool) `
                    -UserText 'x' -OnTool { @{ text = 'ok' } })
        $p = $script:FakeSent[0] | ConvertFrom-Json
        Assert-Equal 'clear_tool_uses_20250919' (@($p.context_management.edits))[0].type
        Assert-Equal 'input_tokens' (@($p.context_management.edits))[0].clear_at_least.type
    }

    It '設定で切れる' {
        Set-FakeClaude @((New-TextReply 'ok'))
        [void] (Invoke-ClaudeAgent -Policy (New-SessionTestPolicy -NoClear) -System 's' -Tools @($script:NoopTool) `
                    -UserText 'x' -OnTool { @{ text = 'ok' } })
        Assert-Null ($script:FakeSent[0] | ConvertFrom-Json).context_management
    }

    It 'API に断られたら外して送り直す (付けられないことで作業全体を止めない)' {
        $script:ContextEditingRejected = $false
        $script:FakeReject = $true
        try {
            Set-FakeClaude @((New-TextReply '通った'))
            $r = Invoke-ClaudeAgent -Policy (New-SessionTestPolicy) -System 's' -Tools @($script:NoopTool) `
                    -UserText 'x' -OnTool { @{ text = 'ok' } }
            Assert-Equal '通った' $r.text
            Assert-True $script:ContextEditingRejected
        }
        finally { $script:FakeReject = $false; $script:ContextEditingRejected = $false }
    }

    It 'ワーカーの出力の上限は判定とは別に持つ' {
        Set-FakeClaude @((New-TextReply 'ok'))
        [void] (Invoke-ClaudeAgent -Policy (New-SessionTestPolicy) -System 's' -Tools @($script:NoopTool) `
                    -UserText 'x' -OnTool { @{ text = 'ok' } } -MaxOutputTokens 16000)
        Assert-Equal 16000 ($script:FakeSent[0] | ConvertFrom-Json).max_tokens
    }
}

Describe '直しの回は同じ会話の続きで、報告の宛先を明示する' {

    $m = [System.Collections.ArrayList]::new()
    Set-FakeClaude @((New-TextReply '最初の報告'), (New-TextReply '直した報告'))
    $task = @{ title = 'カード'; summary = '要約'; proposed_actions = $null; user_edited = $null }
    [void] (Invoke-ClaudeWork -Task $task -Policy (New-SessionTestPolicy) -Tools @($script:NoopTool) `
                -OnTool { @{ text = 'ok' } } -Messages $m)
    $issues = @([pscustomobject]@{ severity = 'high'; where = '報告'; problem = '途中で切れている'; fix = '最後まで書く' })
    [void] (Invoke-ClaudeWork -Task $task -Policy (New-SessionTestPolicy) -Tools @($script:NoopTool) `
                -OnTool { @{ text = 'ok' } } -Messages $m -RepairIssues $issues)
    $sent = $script:FakeSent[1] | ConvertFrom-Json
    $msgs = @($sent.messages)

    It '最初の依頼を組み立て直さず、続きとして指摘を渡す' {
        Assert-Equal 3 $msgs.Count
        Assert-Equal '最初の報告' (@($msgs[1].content))[0].text
        Assert-Match '途中で切れている' (@($msgs[2].content))[-1].text
    }

    It '最後の文章は利用者宛てで、点検役への返事にしないよう伝える' {
        $t = (@($msgs[2].content))[-1].text
        Assert-Match '利用者に向けた報告' $t
        Assert-Match '利用者にはこの指摘は見えていません' $t
    }
}

Describe '再開と引き継ぎの文面' {

    It '再開では、書く前に今の状態を確かめさせる' {
        $t = Get-ResumeText -Instructions @('やっぱり書き込まないで') -Since ((Get-Date).AddHours(-30).ToString('o'))
        Assert-Match '確かめて' $t
        Assert-Match '1 日|2 日' $t
        Assert-Match 'やっぱり書き込まないで' $t
    }

    It '途中で落ちた作業と、上限で止めた作業を言い分ける' {
        Assert-Match 'ワーカーが停止' (Get-ResumeText -Interrupted)
        Assert-Match '上限' (Get-ResumeText -Partial)
        Assert-False ((Get-ResumeText) -match 'ワーカーが停止')
    }

    It '出自が変わっていれば、いまの全文を <thread> の中で渡す' {
        $t = Get-ResumeText -ChangedSource '新しい返信が来ました'
        Assert-Match '(?s)<thread>.*新しい返信が来ました.*</thread>' $t
    }

    It '引き継ぎは記録から組み立てる (モデルの書いた要約に頼らない)' {
        $t = Get-HandoffText -Attempts '○ http_request PUT https://api.github.com/x HTTP 200' `
                -LastReport 'GET しか出していません' -OpenIssues '- PUT で中身を消している'
        Assert-Match 'PUT https://api.github.com/x' $t
        Assert-Match 'すでに相手に届いています' $t
        Assert-Match 'PUT で中身を消している' $t
    }

    It '何も無ければ空' {
        Assert-Equal '' (Get-HandoffText)
    }
}

Describe '会話のストア' {

    if (-not (Test-SqliteAvailable)) { Skip-It 'ストア' 'winsqlite3 が使えません'; return }
    $conn = New-TestStore
    $id = [int] (New-Task -Conn $conn -Title 'カード' -Column 'todo')

    It '保存して読める' {
        Save-TaskSession -Conn $conn -TaskId $id -MessagesJson '{"messages":[]}' -Occurrence 2 -SourceHash 'abc'
        $s = Get-TaskSession -Conn $conn -TaskId $id
        Assert-Equal 2 ([int] $s['occurrence'])
        Assert-Equal 'running' $s['state']
        Assert-Equal 'abc' $s['source_hash']
    }

    It '終わり方だけを書き換えられる' {
        Set-TaskSessionState -Conn $conn -TaskId $id -State 'partial'
        Assert-Equal 'partial' (Get-TaskSession -Conn $conn -TaskId $id)['state']
    }

    It '捨てられる (最初からやり直す)' {
        Assert-True (Clear-TaskSession -Conn $conn -TaskId $id)
        Assert-Null (Get-TaskSession -Conn $conn -TaskId $id)
    }

    It 'カードを消すと会話も消える (メールの本文が入っているため)' {
        Save-TaskSession -Conn $conn -TaskId $id -MessagesJson '{"messages":[]}'
        [void] (Remove-Task -Conn $conn -TaskId $id)
        Assert-Null (Get-TaskSession -Conn $conn -TaskId $id)
    }

    Close-TestStore $conn
}

. "$RepoRoot\phase4\lib\WorkSession.ps1"

Describe '続きから / 記録から引き継ぐ / 新しく の決め方' {

    if (-not (Test-SqliteAvailable)) { Skip-It '決め方' 'winsqlite3 が使えません'; return }
    $conn = New-TestStore
    $tools = @(@{ name = 'http_request' }, @{ name = 'noop' })
    function Get-Row { param([int] $Id) return @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($Id)))[0] }
    function Save-Conversation {
        param([int] $Id, [string] $ToolName = 'http_request', [int] $Occ = 1, [string] $Src = '本文')
        $m = [System.Collections.ArrayList]::new()
        [void] $m.Add(@{ role = 'user'; content = @(@{ type = 'text'; text = '依頼' }) })
        [void] $m.Add(@{ role = 'assistant'; content = @((New-ToolUseReply 'tu_1' $ToolName).content) })
        [void] $m.Add(@{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'tu_1'; content = 'ok' }) })
        [void] $m.Add(@{ role = 'assistant'; content = @((New-TextReply '報告').content) })
        Save-TaskSession -Conn $conn -TaskId $Id -MessagesJson (ConvertTo-SessionJson -Messages $m) `
            -Occurrence $Occ -SourceHash (Get-TextHash $Src) -State 'done'
    }

    It '初めてのカードは新しく始める' {
        $id = [int] (New-Task -Conn $conn -Title 'a' -Column 'todo')
        $p = Get-SessionPlan -Conn $conn -TaskId $id -Task (Get-Row $id) -Occurrence 1 -Tools $tools
        Assert-Equal 'new' $p.mode
        Assert-Equal 0 $p.messages.Count
    }

    It '会話が残っていれば続きから' {
        $id = [int] (New-Task -Conn $conn -Title 'b' -Column 'todo')
        Save-Conversation $id
        $p = Get-SessionPlan -Conn $conn -TaskId $id -Task (Get-Row $id) -Occurrence 1 -Tools $tools -SourceText '本文'
        Assert-Equal 'resume' $p.mode
        Assert-Equal 4 $p.messages.Count
        Assert-Equal 'done' $p.state
        Assert-Equal '' $p.changedSource
    }

    It '元のやり取りが変わっていれば、それを渡す' {
        $id = [int] (New-Task -Conn $conn -Title 'c' -Column 'todo')
        Save-Conversation $id
        $p = Get-SessionPlan -Conn $conn -TaskId $id -Task (Get-Row $id) -Occurrence 1 -Tools $tools -SourceText '本文と新しい返信'
        Assert-Equal '本文と新しい返信' $p.changedSource
    }

    It '同じ件の新しい発生なら会話を分け、記録から引き継ぐ' {
        $id = [int] (New-Task -Conn $conn -Title 'd' -Column 'todo')
        Save-Conversation $id
        $p = Get-SessionPlan -Conn $conn -TaskId $id -Task (Get-Row $id) -Occurrence 2 -Tools $tools
        Assert-Equal 'handoff' $p.mode
        Assert-Null (Get-TaskSession -Conn $conn -TaskId $id)
    }

    It '前回呼んだツールが今は無ければ、続きからにしない (宙に浮いた呼び出しは API に弾かれる)' {
        $id = [int] (New-Task -Conn $conn -Title 'e' -Column 'todo')
        Save-Conversation $id 'send_slack_message'
        $p = Get-SessionPlan -Conn $conn -TaskId $id -Task (Get-Row $id) -Occurrence 1 -Tools $tools
        Assert-Equal 'handoff' $p.mode
        Assert-Match 'send_slack_message' $p.reason
    }

    It '会話が長すぎれば、続きからにしない' {
        $id = [int] (New-Task -Conn $conn -Title 'f' -Column 'todo')
        Save-Conversation $id
        $p = Get-SessionPlan -Conn $conn -TaskId $id -Task (Get-Row $id) -Occurrence 1 -Tools $tools -MaxSessionChars 10
        Assert-Equal 'handoff' $p.mode
    }

    It '会話を残す前に作業したカードは、記録から引き継ぐ (以前の版で作業したもの)' {
        $id = [int] (New-Task -Conn $conn -Title 'g' -Column 'todo')
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{ agent_output = '前回の報告' })
        [void] (Add-TaskComment -Conn $conn -TaskId $id -Author 'agent' -Body '検証で残った指摘: PUT で消した')
        $p = Get-SessionPlan -Conn $conn -TaskId $id -Task (Get-Row $id) -Occurrence 1 -Tools $tools
        Assert-Equal 'handoff' $p.mode
        Assert-Match 'PUT で消した' $p.openIssues
    }

    It '再開で渡す残った指摘は、その会話より後の点検のものだけ' {
        $id = [int] (New-Task -Conn $conn -Title 'h' -Column 'todo')
        [void] (Add-TaskComment -Conn $conn -TaskId $id -Author 'agent' -Body '古い指摘')
        Start-Sleep -Milliseconds 20
        Save-Conversation $id
        $p = Get-SessionPlan -Conn $conn -TaskId $id -Task (Get-Row $id) -Occurrence 1 -Tools $tools
        Assert-Equal '' $p.openIssues
        Start-Sleep -Milliseconds 20
        [void] (Add-TaskComment -Conn $conn -TaskId $id -Author 'agent' -Body '新しい指摘')
        $p = Get-SessionPlan -Conn $conn -TaskId $id -Task (Get-Row $id) -Occurrence 1 -Tools $tools
        Assert-Equal '新しい指摘' $p.openIssues
    }

    Close-TestStore $conn
}
