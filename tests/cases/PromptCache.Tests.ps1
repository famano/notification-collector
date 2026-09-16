# PromptCache.Tests.ps1
# プロンプトキャッシュの置き方。
#
# キャッシュが効かなくなっても、エラーは出ない。請求額が上がるだけで、
# 動きは何も変わらない ―― だから壊れても気付けない。気にしているのは3つ。
#   1. 区切り (cache_control) が「毎回変わらない部分の最後」にあること
#   2. 毎回変わるもの (通知本文・日時) が区切りより後ろにあること
#   3. 同じ内容が同じバイト列になること (並びが揺れると一度も当たらない)

. "$RepoRoot\phase2\lib\ClaudeClient.ps1"

function New-TestLlmPolicy {
    param([string] $CacheTtl = '5m')
    return ([pscustomobject]@{
        llm = [pscustomobject]@{
            model = 'claude-opus-5'; effort = 'low'; maxOutputTokens = 1024; cacheTtl = $CacheTtl
        }
        context = $null
    })
}

Describe '区切りの置き場所 (単発の呼び出し)' {

    It 'system の末尾に置く (手前の tools ごと載る)' {
        $p = New-BasePayload (New-TestLlmPolicy) 'システムプロンプト' $script:TriageTool '通知の本文'
        $blocks = @($p.system)
        Assert-Equal 1 $blocks.Count
        Assert-Equal 'ephemeral' $blocks[-1].cache_control.type
    }

    It '毎回変わる本文には置かない (置くと毎回書き込みになって損をする)' {
        $p = New-BasePayload (New-TestLlmPolicy) 'システムプロンプト' $script:TriageTool '通知の本文'
        $json = ConvertTo-Json -InputObject (ConvertTo-StableOrder $p) -Depth 20 -Compress
        Assert-Equal 1 ([regex]::Matches($json, 'cache_control')).Count
    }

    It '通知が変わっても system 側のバイト列は変わらない' {
        $a = New-BasePayload (New-TestLlmPolicy) 'システムプロンプト' $script:TriageTool '通知A'
        $b = New-BasePayload (New-TestLlmPolicy) 'システムプロンプト' $script:TriageTool '通知B'
        $sa = ConvertTo-Json -InputObject (ConvertTo-StableOrder @($a.system)) -Depth 20 -Compress
        $sb = ConvertTo-Json -InputObject (ConvertTo-StableOrder @($b.system)) -Depth 20 -Compress
        Assert-Equal $sa $sb
    }

    It '送る JSON では system / tools / messages が配列のまま' {
        # 1要素の配列は、関数の戻り値で展開されるとオブジェクトになる。
        # そうなっても手元では気付けず、API に投げた瞬間に 400 で落ちる。
        $p = New-BasePayload (New-TestLlmPolicy) 'システムプロンプト' $script:TriageTool '本文'
        $j = ConvertTo-Json -InputObject (ConvertTo-StableOrder $p) -Depth 20 -Compress
        Assert-Match '"system":\[' $j
        Assert-Match '"tools":\[' $j
        Assert-Match '"messages":\[' $j
    }

    It '1h を指定すると ttl が付く' {
        $p = New-BasePayload (New-TestLlmPolicy '1h') 'システムプロンプト' $script:TriageTool '本文'
        Assert-Equal '1h' (@($p.system))[-1].cache_control.ttl
    }

    It 'off で切れる (切ったときに壊れないこと)' {
        $p = New-BasePayload (New-TestLlmPolicy 'off') 'システムプロンプト' $script:TriageTool '本文'
        $json = ConvertTo-Json -InputObject (ConvertTo-StableOrder $p) -Depth 20 -Compress
        Assert-Equal 0 ([regex]::Matches($json, 'cache_control')).Count
        Assert-Equal 'システムプロンプト' (@($p.system))[0].text
    }

    It '設定の無い古い policy.json でも既定 (5分) で動く' {
        $old = [pscustomobject]@{ llm = [pscustomobject]@{ model = 'claude-opus-5'; maxOutputTokens = 1024 } }
        $p = New-BasePayload $old 'システムプロンプト' $script:TriageTool '本文'
        Assert-Equal 'ephemeral' (@($p.system))[-1].cache_control.type
        Assert-Null (@($p.system))[-1].cache_control.ttl
    }
}

Describe '並びの固定 (同じ内容は同じバイト列にする)' {

    It '書いた順が違っても同じ JSON になる' {
        $a = @{ b = 1; a = 2; c = @{ y = 1; x = 2 } }
        $b = @{ c = @{ x = 2; y = 1 }; a = 2; b = 1 }
        $ja = ConvertTo-Json -InputObject (ConvertTo-StableOrder $a) -Depth 10 -Compress
        $jb = ConvertTo-Json -InputObject (ConvertTo-StableOrder $b) -Depth 10 -Compress
        Assert-Equal $ja $jb
        Assert-Equal '{"a":2,"b":1,"c":{"x":2,"y":1}}' $ja
    }

    It '[ordered] の並びは崩さない (引数をモデルに見せる順に意味がある)' {
        $v = ConvertTo-StableOrder ([ordered]@{ z = 1; a = 2; m = 3 })
        Assert-Equal @('z', 'a', 'm') @($v.Keys)
    }

    It '配列と文字列はそのまま通す' {
        $v = ConvertTo-StableOrder @{ list = @('b', 'a'); text = 'abc' }
        Assert-Equal @('b', 'a') @($v.list)
        Assert-Equal 'abc' $v.text
    }

    It 'ツール定義も毎回同じバイト列になる' {
        $j1 = ConvertTo-Json -InputObject (ConvertTo-StableOrder $script:TriageTool) -Depth 20 -Compress
        $j2 = ConvertTo-Json -InputObject (ConvertTo-StableOrder $script:TriageTool) -Depth 20 -Compress
        Assert-Equal $j1 $j2
        # 引数の並びは [ordered] のまま (辞書順に並べ替えていないこと)
        Assert-True ($j1.IndexOf('needs_action') -lt $j1.IndexOf('urgency'))
    }
}

Describe 'トークン数の記録 (効いているかを見る唯一の手段)' {

    It '1度も呼んでいなければ何も出さない' {
        Reset-ClaudeUsage
        Assert-Null (Get-ClaudeUsageLine)
    }

    It '複数回ぶんを足して1行にする' {
        Reset-ClaudeUsage
        Add-ClaudeUsage ([pscustomobject]@{ input_tokens = 100; cache_creation_input_tokens = 900
                                            cache_read_input_tokens = 0;  output_tokens = 50 })
        Add-ClaudeUsage ([pscustomobject]@{ input_tokens = 100; cache_creation_input_tokens = 0
                                            cache_read_input_tokens = 900; output_tokens = 50 })
        $line = Get-ClaudeUsageLine
        Assert-Match '2回' $line
        Assert-Match '入力 2,000' $line          # (100+900) + (100+900)
        Assert-Match 'キャッシュヒット 900' $line        # 2回目がキャッシュから読めている
        Assert-Match 'キャッシング 900' $line
        Assert-Match '出力 100' $line
    }

    It '数え直せる (ワーカーは常駐なのでカードごとに戻す)' {
        Reset-ClaudeUsage
        Add-ClaudeUsage ([pscustomobject]@{ input_tokens = 1; cache_creation_input_tokens = 2
                                            cache_read_input_tokens = 3; output_tokens = 4 })
        Reset-ClaudeUsage
        Assert-Null (Get-ClaudeUsageLine)
    }

    It 'usage の無い応答では数えない' {
        Reset-ClaudeUsage
        Add-ClaudeUsage $null
        Assert-Null (Get-ClaudeUsageLine)
    }
}

Describe '区切りの置き場所 (エージェントループ)' {

    # Send-ClaudeRequest を差し替えて、送った payload をその場で JSON に固める。
    # 区切りはターンごとに動かすので、あとから見ると結果が変わってしまう。
    $script:AgentSent = @()
    $script:AgentTurn = 0
    function Send-ClaudeRequest {
        param([Parameter(Mandatory)] [hashtable] $Payload, [int] $MaxRetries = 2)
        $script:AgentSent += ,(ConvertTo-Json -InputObject (ConvertTo-StableOrder $Payload) -Depth 25 -Compress)
        $script:AgentTurn++
        if ($script:AgentTurn -lt 3) {
            return ([pscustomobject]@{
                stop_reason = 'tool_use'; model = 'claude-opus-5'
                content = @([pscustomobject]@{ type = 'tool_use'; id = ('tu_' + $script:AgentTurn); name = 'noop'; input = [pscustomobject]@{} })
            })
        }
        return ([pscustomobject]@{
            stop_reason = 'end_turn'; model = 'claude-opus-5'
            content = @([pscustomobject]@{ type = 'text'; text = '終わりました' })
        })
    }

    $res = Invoke-ClaudeAgent -Policy (New-TestLlmPolicy) -System '作業のシステムプロンプト' `
              -Tools @($script:TriageTool) -UserText 'カードを閉じてください' `
              -OnTool { param($n, $i) return @{ text = 'ok'; isError = $false } }
    $sent = @($script:AgentSent | ForEach-Object { $_ | ConvertFrom-Json })

    It '3ターン回って終わる' {
        Assert-Equal 3 $sent.Count
        Assert-Equal '終わりました' $res.text
    }

    It '送る JSON では system / tools / messages が配列のまま' {
        foreach ($j in $script:AgentSent) {
            Assert-Match '"system":\[' $j
            Assert-Match '"tools":\[' $j
            Assert-Match '"messages":\[' $j
        }
    }

    It 'system の区切りは毎ターン同じ場所にある' {
        foreach ($p in $sent) { Assert-Equal 'ephemeral' (@($p.system))[-1].cache_control.type }
    }

    It 'system のバイト列はターンをまたいで変わらない' {
        $first = ConvertTo-Json -InputObject $sent[0].system -Depth 20 -Compress
        foreach ($p in $sent) {
            Assert-Equal $first (ConvertTo-Json -InputObject $p.system -Depth 20 -Compress)
        }
    }

    It '会話側の区切りは毎ターン末尾へ移る' {
        foreach ($p in $sent) {
            $last = @($p.messages)[-1]
            Assert-Equal 'user' $last.role
            Assert-Equal 'ephemeral' (@($last.content))[-1].cache_control.type
        }
    }

    It '区切りは増やさず移す (1リクエスト4つまでの制限を超えない)' {
        foreach ($j in $script:AgentSent) {
            Assert-True (([regex]::Matches($j, 'cache_control')).Count -le 4) '区切りが増えています'
        }
        # 会話側は常に1つだけ (もう1つは system 側)
        Assert-Equal 2 ([regex]::Matches($script:AgentSent[-1], 'cache_control')).Count
    }

    It '前のターンに置いた区切りは外れている' {
        $p = $sent[-1]
        $first = @($p.messages)[0]
        Assert-Null (@($first.content))[-1].cache_control
    }

    It 'モデルが返した assistant の中身は書き換えない' {
        $p = $sent[-1]
        foreach ($m in @($p.messages)) {
            if ($m.role -ne 'assistant') { continue }
            foreach ($b in @($m.content)) { Assert-Null $b.cache_control }
        }
    }
}
