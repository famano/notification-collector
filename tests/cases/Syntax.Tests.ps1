# Syntax.Tests.ps1
# すべての .ps1 が構文として通り、UTF-8 BOM 付きで保存されていること。
#
# BOM を見るのは飾りではない。PowerShell 5.1 は BOM 無し UTF-8 を ANSI と誤読するので、
# 日本語コメントの入ったファイルが「実行した瞬間に構文エラー」になる。
# 書いた本人の環境では動くことがあるぶん、気付くのが遅れる類の事故。

Describe 'リポジトリ内の PowerShell スクリプト' {

    $files = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter '*.ps1' -File |
               Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.FullName -notmatch '/\.git/' } |
               Sort-Object FullName)

    It '1つ以上見つかる' {
        Assert-True ($files.Count -gt 0) 'スクリプトが1つも見つかりませんでした'
    }

    foreach ($f in $files) {
        $rel = $f.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')

        It ("構文が通る: " + $rel) {
            $errors = $null
            [void] [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref] $null, [ref] $errors)
            if ($errors -and $errors.Count -gt 0) {
                throw ("{0} 行目: {1}" -f $errors[0].Extent.StartLineNumber, $errors[0].Message)
            }
        }

        It ("UTF-8 BOM 付きで保存されている: " + $rel) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            Assert-True ($b.Length -ge 3) '空のファイルです'
            Assert-True (($b[0] -eq 0xEF) -and ($b[1] -eq 0xBB) -and ($b[2] -eq 0xBF)) `
                'BOM がありません。PowerShell 5.1 が日本語コメントを誤読します'
        }
    }
}
