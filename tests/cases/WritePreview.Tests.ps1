# WritePreview.Tests.ps1
# 書き込みの前に「何が起きるか」を見せ、書いたあとに読み直すこと。
#
# #295 の PUT をそのまま再現して、止まることを確かめる。規則は特定のサービスの知識を
# 使っていない (GitHub の contents API を名指ししない) ので、同じ形の別の API でも効く。

. "$RepoRoot\phase4\lib\WritePreview.ps1"

function ConvertTo-B64 { param([string] $s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }

# GitHub の GET contents の応答と同じ形。content は 60 字ごとに改行が入った base64。
$script:Original = (1..220 | ForEach-Object { "It 'テスト $_' { Assert-Equal 'キャッシュヒット 900' `$line }" }) -join "`n"
$b64 = ConvertTo-B64 $script:Original
$wrapped = ($b64 -split '(.{60})' | Where-Object { $_ }) -join "`n"
$script:CurrentFile = [pscustomobject]@{
    status = 200
    text = (@{ name = 'PromptCache.Tests.ps1'; sha = '7eb245b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6'; size = 10361
               content = $wrapped; encoding = 'base64'; url = 'https://api.github.com/x' } | ConvertTo-Json -Compress)
}

Describe '操作の種類と許可の鍵' {

    It 'GET は読む、POST は足す、PUT/PATCH/DELETE は上書き・消す' {
        Assert-Equal 'read' (Get-HttpOpKind 'GET')
        Assert-Equal 'read' (Get-HttpOpKind '')
        Assert-Equal 'add' (Get-HttpOpKind 'post')
        Assert-Equal 'change' (Get-HttpOpKind 'PUT')
        Assert-Equal 'change' (Get-HttpOpKind 'PATCH')
        Assert-Equal 'change' (Get-HttpOpKind 'DELETE')
    }

    It 'http_request の許可は「種類 × ホスト」で束ねる (GET の許可で PUT を通さない)' {
        $get = Get-GrantKey 'http_request' ([pscustomobject]@{ method = 'GET'; url = 'https://raw.githubusercontent.com/a/b' })
        $put = Get-GrantKey 'http_request' ([pscustomobject]@{ method = 'PUT'; url = 'https://api.github.com/repos/a/b/contents/x' })
        $post = Get-GrantKey 'http_request' ([pscustomobject]@{ method = 'POST'; url = 'https://api.github.com/repos/a/b/issues/1/comments' })
        Assert-Equal 'http_request:read:raw.githubusercontent.com' $get
        Assert-Equal 'http_request:change:api.github.com' $put
        Assert-Equal 'http_request:add:api.github.com' $post
    }

    It 'ほかのツールはツール名のまま' {
        Assert-Equal 'run_command' (Get-GrantKey 'run_command' ([pscustomobject]@{ command = 'dir' }))
    }

    It '許可の鍵を人が読める形にする' {
        Assert-Equal 'api.github.com への追加 (POST)' (Get-GrantKeyLabel 'http_request:add:api.github.com')
        Assert-Match 'すべてのホスト' (Get-GrantKeyLabel 'http_request:read:*')
    }
}

Describe 'base64 は手で書かせない' {

    It '平文で受け取ったフィールドをワーカーが符号化する' {
        $r = ConvertTo-EncodedBody -Body '{"message":"fix","content":"日本語の本文","sha":"abc"}' -Encode @{ content = 'base64' }
        Assert-Equal '' $r.error
        $o = $r.body | ConvertFrom-Json
        Assert-Equal '日本語の本文' ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($o.content)))
        Assert-Equal 'fix' $o.message
    }

    It 'base64url も選べる (パディング無し・URL で安全な文字)' {
        $r = ConvertTo-EncodedBody -Body '{"raw":"??>>"}' -Encode ([pscustomobject]@{ raw = 'base64url' })
        $o = $r.body | ConvertFrom-Json
        Assert-False ($o.raw -match '[+/=]')
    }

    It '本文に無いフィールドを指定したら断る' {
        Assert-Match '本文にありません' (ConvertTo-EncodedBody -Body '{"a":"x"}' -Encode @{ b = 'base64' }).error
    }

    It '手で書いた長い base64 を見つける' {
        $body = @{ message = 'x'; content = ('QUJD' * 600) } | ConvertTo-Json -Compress
        Assert-Equal 'content' (Find-HandWrittenBase64 -Body $body)
    }

    It 'ワーカーが符号化したフィールドは数えない' {
        $body = @{ content = ('QUJD' * 600) } | ConvertTo-Json -Compress
        Assert-Equal '' (Find-HandWrittenBase64 -Body $body -Except @('content'))
    }

    It '短い値や普通の文章は base64 と見なさない' {
        $body = @{ message = 'test: 期待値を追従'; sha = '7eb245b' } | ConvertTo-Json -Compress
        Assert-Equal '' (Find-HandWrittenBase64 -Body $body)
    }
}

Describe '書く前の突き合わせ (#295 の PUT を止める)' {

    It '先頭1行で全体を置き換える PUT は「大きく減る」になる' {
        $body = @{ message = 'test: 期待値を追従'; sha = '7eb245b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6'
                   content = (ConvertTo-B64 '# PromptCache.Tests.ps1') } | ConvertTo-Json -Compress
        $p = Get-WritePreview -Method 'PUT' -Body $body -Current $script:CurrentFile
        Assert-Equal 'compared' $p.level
        Assert-True $p.largeLoss
        Assert-Match 'content' $p.summary
        $line = @($p.lines | Where-Object { $_ -match '^content' })[0]
        Assert-Match 'バイト \(デコード後\)' $line
        Assert-Match '% 減ります' $line
    }

    It '全文を取り直して2行だけ直した PUT は通る' {
        $fixed = $script:Original.Replace("'テスト 1'", "'テスト 1 改'")
        $body = @{ message = 'x'; sha = '7eb245b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6'; content = (ConvertTo-B64 $fixed) } |
                ConvertTo-Json -Compress
        $p = Get-WritePreview -Method 'PUT' -Body $body -Current $script:CurrentFile
        Assert-Equal 'compared' $p.level
        Assert-False $p.largeLoss
    }

    It '変わらないフィールドは「変わりません」' {
        $body = @{ sha = '7eb245b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6' } | ConvertTo-Json -Compress
        $p = Get-WritePreview -Method 'PATCH' -Body $body -Current $script:CurrentFile
        Assert-Match '変わりません' ($p.lines -join "`n")
    }

    It 'PUT で送らないフィールドがあれば、消えうることを書く' {
        $body = @{ content = (ConvertTo-B64 $script:Original) } | ConvertTo-Json -Compress
        $p = Get-WritePreview -Method 'PUT' -Body $body -Current $script:CurrentFile
        Assert-Match '送らないフィールド' ($p.lines -join "`n")
        Assert-False $p.largeLoss
    }

    It '普通の文字列の短縮も数える (長い説明を1行にする PATCH)' {
        $cur = [pscustomobject]@{ status = 200; text = (@{ description = ('説明' * 300) } | ConvertTo-Json -Compress) }
        $p = Get-WritePreview -Method 'PATCH' -Body '{"description":"短い"}' -Current $cur
        Assert-True $p.largeLoss
    }

    It 'DELETE は常に大きく消える扱い' {
        $p = Get-WritePreview -Method 'DELETE' -Body '' -Current $script:CurrentFile
        Assert-True $p.largeLoss
    }

    It 'いまは無いもの (GET が 404) を作る PUT は新規作成' {
        $p = Get-WritePreview -Method 'PUT' -Body '{"content":"x"}' -Current ([pscustomobject]@{ status = 404; text = '{}' })
        Assert-Equal 'new' $p.level
        Assert-False $p.largeLoss
    }

    It '読めなかったら「影響を事前に確認できません」' {
        $p = Get-WritePreview -Method 'PUT' -Body '{"a":1}' -Current $null
        Assert-Equal 'unavailable' $p.level
        Assert-Match '事前に確認できません' ($p.lines -join '')
    }

    It '形が違って突き合わせられなければ、いまの状態だけ見せる' {
        $p = Get-WritePreview -Method 'PUT' -Body '{"other":1}' -Current $script:CurrentFile
        Assert-Equal 'shown' $p.level
    }
}

Describe '書いたあとに読み直す' {

    It '送った値と一致していれば一致と返す (base64 は改行の違いを無視して比べる)' {
        $body = @{ content = (ConvertTo-B64 $script:Original) } | ConvertTo-Json -Compress
        $t = Get-ReadbackCheck -Body $body -After $script:CurrentFile
        Assert-Match 'content: 送った値と一致' $t
    }

    It '違っていれば違うと返す' {
        $body = @{ content = (ConvertTo-B64 'ちがう') } | ConvertTo-Json -Compress
        Assert-Match '送った値と違います' (Get-ReadbackCheck -Body $body -After $script:CurrentFile)
    }
}

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase4\lib\WorkTools.ps1"

Describe '承認画面と、まとめて許可の可否' {

    $ws = New-TestTempDir
    $bigLoss = [pscustomobject]@{ level = 'compared'; largeLoss = $true; lines = @('content: 10,361 → 24 バイト (デコード後)  ※ 100% 減ります'); summary = 'x' }
    $small = [pscustomobject]@{ level = 'compared'; largeLoss = $false; lines = @('content: 10,361 → 10,365 バイト (デコード後)'); summary = 'x' }
    $unk = [pscustomobject]@{ level = 'unavailable'; largeLoss = $false; lines = @('影響を事前に確認できません'); summary = 'x' }
    $put = [pscustomobject]@{ method = 'PUT'; url = 'https://api.github.com/repos/a/b/contents/x'; purpose = 'p'
                              body = '{"content":"本文の全体","sha":"abc"}'; encode = [pscustomobject]@{ content = 'base64' } }

    It '大きく減る上書きは、許可でも自動承認でも通さない' {
        $r = Get-ToolRisk -Name 'http_request' -ToolInput $put -Workspace $ws -Preview $bigLoss
        Assert-True $r.mustAsk
        Assert-False $r.grantable
    }

    It '突き合わせて小さな変更なら、まとめて許可できる' {
        $r = Get-ToolRisk -Name 'http_request' -ToolInput $put -Workspace $ws -Preview $small
        Assert-False $r.mustAsk
        Assert-True $r.grantable
        Assert-Equal 'http_request:change:api.github.com' $r.grantKey
    }

    It '影響を事前に確かめられない上書きは、まとめて許可できない' {
        $r = Get-ToolRisk -Name 'http_request' -ToolInput $put -Workspace $ws -Preview $unk
        Assert-False $r.grantable
        Assert-False $r.mustAsk
    }

    It 'POST (追加) は突き合わせなくても、まとめて許可できる' {
        $post = [pscustomobject]@{ method = 'POST'; url = 'https://api.github.com/repos/a/b/issues/1/comments'; purpose = 'p'; body = '{"body":"x"}' }
        $r = Get-ToolRisk -Name 'http_request' -ToolInput $post -Workspace $ws
        Assert-True $r.grantable
        Assert-Equal 'http_request:add:api.github.com' $r.grantKey
    }

    It '承認画面に突き合わせの結果を出し、符号化するフィールドは平文で見せる' {
        $r = Get-ToolRisk -Name 'http_request' -ToolInput $put -Workspace $ws -Preview $bigLoss
        Assert-Match '書く前の突き合わせ' $r.detail
        Assert-Match '100% 減ります' $r.detail
        Assert-Match '本文の全体' $r.detail
        Assert-Match 'content は送る前に符号化します' $r.detail
    }

    It '書き込みの本文は切らない (取り消せない操作の唯一の事前確認)' {
        $long = [pscustomobject]@{ method = 'POST'; url = 'https://api.github.com/x'; purpose = 'p'; body = ('あ' * 5000) }
        $r = Get-ToolRisk -Name 'http_request' -ToolInput $long -Workspace $ws
        Assert-False ($r.detail -match '以下省略')
    }
}

Describe 'まとめて許可の鍵 (ストア)' {

    if (-not (Test-SqliteAvailable)) { Skip-It '鍵' 'winsqlite3 が使えません'; return }

    It '以前の「http_request を今後すべて許可」は、読み取りだけの許可に置き換わる' {
        $dir = New-TestTempDir
        $db = Join-Path $dir 'tasks.db'
        $c = Open-TaskStore -Path $db
        Add-ToolGrant -Conn $c -Scope 'global' -Tool 'http_request'
        $c.Dispose()
        $c = Open-TaskStore -Path $db   # 開き直すと移行が走る
        try {
            $keys = @(Get-ToolGrants -Conn $c | ForEach-Object { [string] $_['tool'] })
            Assert-Equal @('http_request:read:*') $keys
            Assert-True (Test-ToolGranted -Conn $c -TaskId 1 -Tool 'http_request:read:example.com')
            Assert-False (Test-ToolGranted -Conn $c -TaskId 1 -Tool 'http_request:change:api.github.com')
            Assert-False (Test-ToolGranted -Conn $c -TaskId 1 -Tool 'http_request:add:api.github.com')
        }
        finally { $c.Dispose() }
    }

    It '許可は種類とホストが一致したときだけ効く' {
        $c = New-TestStore
        try {
            Add-ToolGrant -Conn $c -Scope 'global' -Tool 'http_request:add:api.github.com'
            Assert-True (Test-ToolGranted -Conn $c -TaskId 1 -Tool 'http_request:add:api.github.com')
            Assert-False (Test-ToolGranted -Conn $c -TaskId 1 -Tool 'http_request:change:api.github.com')
            Assert-False (Test-ToolGranted -Conn $c -TaskId 1 -Tool 'http_request:add:evil.example.com')
        }
        finally { Close-TestStore $c }
    }

    It '承認要求に、束ねる鍵と束ねてよいかを残す' {
        $c = New-TestStore
        try {
            $tid = [int] (New-Task -Conn $c -Title 't' -Column 'doing')
            $rid = New-ToolRequest -Conn $c -TaskId $tid -Tool 'http_request' -Summary 's' -Detail 'd' `
                        -GrantKey 'http_request:change:api.github.com' -Grantable $false
            $r = Get-ToolRequest -Conn $c -RequestId $rid
            Assert-Equal 'http_request:change:api.github.com' $r['grant_key']
            Assert-Equal 0 ([int] $r['grantable'])
        }
        finally { Close-TestStore $c }
    }

    It '書き込みは本文と突き合わせの結果まで残し、引き継ぎに出す' {
        $c = New-TestStore
        try {
            $tid = [int] (New-Task -Conn $c -Title 't' -Column 'doing')
            Add-TaskAttempt -Conn $c -TaskId $tid -Tool 'http_request' -Target 'PUT https://api.github.com/x' `
                -Outcome 'held' -Detail '大きく減るため実行せずに差し戻しました' -Request '{"content":"# 1行"}' `
                -Preview 'content: 10,361 → 24 バイト'
            $a = @(Get-TaskAttempts -Conn $c -TaskId $tid)[0]
            Assert-Equal '{"content":"# 1行"}' $a['request']
            $s = Get-AttemptSummary -Conn $c -TaskId $tid
            Assert-Match '△' $s
            Assert-Match '10,361 → 24' $s
        }
        finally { Close-TestStore $c }
    }
}
