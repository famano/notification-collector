# Policy.Tests.ps1
# トリアージ方針 (policy.json) の読み書き。
#
# 気にしているのは2つ。
#   1. 書き戻しで壊さないこと。ここが壊れるとトリアージが起動しなくなり、
#      「動いているのにカードが増えない」という一番分かりにくい形になる
#   2. 「すべてに一致する条件」を受け付けないこと。* だけの条件を1つ入れると、
#      以後すべての通知が黙って捨てられる

. "$RepoRoot\phase2\lib\Policy.ps1"

function New-TestPolicyFile {
    $dir = New-TestTempDir
    $p = Join-Path $dir 'policy.json'
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'phase2\config\policy.json') -Destination $p
    return $p
}

Describe '読み書き' {
    $path = New-TestPolicyFile

    It '既定の policy.json を読める' {
        $pol = Read-Policy -Path $path
        Assert-NotNull $pol.llm.model
        Assert-True ((@(Get-IgnoreList -Policy $pol -Kind 'appId')).Count -gt 0) '既定のふるいが空です'
    }

    It '書き戻しても読み直せる (トリアージが起動しなくなるのが一番困る)' {
        $pol = Read-Policy -Path $path
        Save-Policy -Policy $pol -Path $path
        $again = Read-Policy -Path $path
        Assert-Equal $pol.llm.model $again.llm.model
        Assert-Equal (@(Get-IgnoreList -Policy $pol -Kind 'appId')) (@(Get-IgnoreList -Policy $again -Kind 'appId'))
    }

    It '読む人向けの説明 (_comment) は消さない' {
        $pol = Read-Policy -Path $path
        [void] (Add-IgnorePattern -Policy $pol -Kind 'appId' -Pattern 'Example.App')
        Save-Policy -Policy $pol -Path $path
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        Assert-Match '_comment' $raw
    }

    It 'BOM は付けない' {
        $b = [IO.File]::ReadAllBytes($path)
        Assert-False (($b[0] -eq 0xEF) -and ($b[1] -eq 0xBB) -and ($b[2] -eq 0xBF))
    }

    It 'LLM の設定には触らない' {
        $pol = Read-Policy -Path $path
        Assert-Equal 'claude-opus-5' $pol.llm.model
        Assert-NotNull $pol.llm.effort
    }
}

Describe 'ふるい分けの追加' {
    $path = New-TestPolicyFile
    $pol = Read-Policy -Path $path

    It '足したものが一覧に出る' {
        Assert-True (Add-IgnorePattern -Policy $pol -Kind 'appId' -Pattern 'Example.Noisy.App').ok
        Assert-True ((Get-IgnoreList -Policy $pol -Kind 'appId') -contains 'Example.Noisy.App')
    }

    It '同じものは二重に入らない' {
        $r = Add-IgnorePattern -Policy $pol -Kind 'appId' -Pattern 'Example.Noisy.App'
        Assert-False $r.ok
        Assert-Equal 1 (@(Get-IgnoreList -Policy $pol -Kind 'appId' | Where-Object { $_ -eq 'Example.Noisy.App' })).Count
    }

    It '空の条件は入れない' {
        Assert-False (Add-IgnorePattern -Policy $pol -Kind 'appId' -Pattern '   ').ok
    }

    It 'すべてに一致する条件は入れない (黙って全部捨てる事故になる)' {
        Assert-False (Add-IgnorePattern -Policy $pol -Kind 'appId' -Pattern '*').ok
        Assert-False (Add-IgnorePattern -Policy $pol -Kind 'title' -Pattern '***').ok
    }

    It '件名の条件はアプリの条件と混ざらない' {
        Assert-True (Add-IgnorePattern -Policy $pol -Kind 'title' -Pattern '*をタスク バーに*').ok
        Assert-False ((Get-IgnoreList -Policy $pol -Kind 'appId') -contains '*をタスク バーに*')
    }

    It '消せる' {
        Assert-True (Remove-IgnorePattern -Policy $pol -Kind 'appId' -Pattern 'Example.Noisy.App').ok
        Assert-False ((Get-IgnoreList -Policy $pol -Kind 'appId') -contains 'Example.Noisy.App')
    }

    It '無いものは消せない' {
        Assert-False (Remove-IgnorePattern -Policy $pol -Kind 'appId' -Pattern 'Not.There').ok
    }

    It '追加と削除を繰り返しても配列のまま (1件になっても壊れない)' {
        $p2 = New-TestPolicyFile
        $pol2 = Read-Policy -Path $p2
        Set-IgnoreList -Policy $pol2 -Kind 'title' -Patterns @()
        [void] (Add-IgnorePattern -Policy $pol2 -Kind 'title' -Pattern 'A')
        Save-Policy -Policy $pol2 -Path $p2
        $back = Read-Policy -Path $p2
        Assert-Equal 1 (@(Get-IgnoreList -Policy $back -Kind 'title')).Count
        [void] (Add-IgnorePattern -Policy $back -Kind 'title' -Pattern 'B')
        Assert-Equal 2 (@(Get-IgnoreList -Policy $back -Kind 'title')).Count
    }
}

Describe '背景情報' {
    $path = New-TestPolicyFile
    $pol = Read-Policy -Path $path

    It '保存して読み直せる' {
        Set-PolicyContext -Policy $pol -UserName '天野' -Role '受託開発のエンジニア' `
            -Priorities @('請求と支払いの期限', '本番障害')
        Save-Policy -Policy $pol -Path $path
        $back = Read-Policy -Path $path
        Assert-Equal '天野' $back.context.userName
        Assert-Equal 2 (@($back.context.priorities)).Count
    }

    It '空白は落とす' {
        Set-PolicyContext -Policy $pol -UserName '  天野  ' -Role '' -Priorities @('a', '   ', 'b')
        Assert-Equal '天野' $pol.context.userName
        Assert-Equal 2 (@($pol.context.priorities)).Count
    }

    It '長すぎる入力は切る' {
        Set-PolicyContext -Policy $pol -UserName ('あ' * 500) -Role '' -Priorities @()
        Assert-Equal 200 $pol.context.userName.Length
    }

    It '優先事項は数に上限がある' {
        Set-PolicyContext -Policy $pol -UserName '' -Role '' -Priorities (1..50 | ForEach-Object { "p$_" })
        Assert-Equal 20 (@($pol.context.priorities)).Count
    }
}

Describe '画面に渡す形' {
    $pol = Read-Policy -Path (New-TestPolicyFile)

    It '説明書きは画面に渡さない' {
        $v = Get-PolicyView -Policy $pol
        $json = $v | ConvertTo-Json -Depth 6
        Assert-True ($json -notmatch '_comment')
    }

    It '一覧は配列で返る (1件でも0件でも)' {
        Set-IgnoreList -Policy $pol -Kind 'title' -Patterns @('ひとつ')
        $v = Get-PolicyView -Policy $pol
        Assert-Equal 1 (@($v.ignore.titlePatterns)).Count
    }
}

# ふるいの判定そのもの (Invoke-Triage の Test-AnyPattern と同じ -like) が
# 期待通りに効くことも見ておく。条件を足せても当たらなければ意味がない。
Describe 'ふるいの当たり方' {

    It 'ワイルドカードが効く' {
        Assert-True  ('Windows.SystemToast.Calendar' -like 'Windows.SystemToast.*')
        Assert-False ('Slack.Slack' -like 'Windows.SystemToast.*')
    }

    It 'カードから足した条件は、そのアプリだけに当たる' {
        $appId = 'Microsoft.SkyDrive.Desktop'
        Assert-True  ($appId -like $appId)
        Assert-False ('Slack.Slack' -like $appId)
    }
}

Describe '日本語を \uXXXX に逃がさない' {

    # Windows PowerShell 5.1 の ConvertTo-Json は非 ASCII を必ず逃がす。
    # JSON としては正しいが、policy.json は人が読んで直すファイルなので、
    # 書き戻すたびに _comment もふるいの条件も読めない文字列に変わっていく。
    $in = '{"note":"\u30c8\u30fc\u30af\u30f3","tab":"a\tb","q":"a\"b","bs":"a\\b"}'

    It '逃がされた日本語を戻す' {
        Assert-Match 'トークン' (ConvertFrom-JsonUnicodeEscape $in)
    }

    It '戻したあとも JSON として読める' {
        $o = (ConvertFrom-JsonUnicodeEscape $in) | ConvertFrom-Json
        Assert-Equal 'トークン' $o.note
    }

    It 'タブ・引用符・バックスラッシュのエスケープには触らない (戻すと壊れる)' {
        $o = (ConvertFrom-JsonUnicodeEscape $in) | ConvertFrom-Json
        Assert-Equal 3 $o.tab.Length
        Assert-Equal 'a"b' $o.q
        Assert-Equal 'a\b' $o.bs
    }

    It '書き戻したファイルに日本語がそのまま残る' {
        $path = New-TestPolicyFile
        $pol = Read-Policy -Path $path
        [void] (Add-IgnorePattern -Policy $pol -Kind 'title' -Pattern '*請求書*')
        Save-Policy -Policy $pol -Path $path
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        Assert-Match '請求書' $raw
        Assert-Match 'トリアージ方針' $raw
        Assert-True ($raw -notmatch '\\u[0-9a-fA-F]{4}') '日本語が \uXXXX に逃げています'
    }
}
