# LogText.Tests.ps1
# ログの文字コード。
#
# 気にしているのは「書き手と読み手が揃っていること」の一点。
# ここがずれても例外は出ない ―― 画面に化けた字が出るだけで、しかも
# logs\ を直接開くと読めてしまうので、ログ側が原因だと思い当たりにくい。

. "$RepoRoot\lib\LogText.ps1"

Describe 'ログの末尾を読む' {
    $dir = New-TestTempDir
    $utf8 = New-Object Text.UTF8Encoding($false)

    It 'UTF-8 の日本語をそのまま読める' {
        $p = Join-Path $dir 'utf8.log'
        [IO.File]::WriteAllText($p, "一行目`n収集を開始します`n判定 3 件`n", $utf8)
        $t = @(Get-LogTail -Path $p -Tail 2)
        Assert-Equal 2 $t.Count
        Assert-Equal '収集を開始します' $t[0]
        Assert-Equal '判定 3 件' $t[1]
    }

    It '無いファイルでも落ちない (起動直後はまだ何も書かれていない)' {
        Assert-Equal 0 (@(Get-LogTail -Path (Join-Path $dir 'no-such.log') -Tail 3)).Count
    }

    It 'UTF-8 として読めないログは読み直す (直した日より前のログ)' {
        # 実際の逃げ道は CP932 (Oem) だが、それを読めるのは日本語 Windows だけなので、
        # ここでは同じ枝を別の文字コードで通す。
        # 0x82 0xA0 は UTF-8 としては壊れていて、BigEndianUnicode としては U+82A0。
        # 続く 0x00 0x0A は、その文字コードでの改行。
        $p = Join-Path $dir 'legacy.log'
        [IO.File]::WriteAllBytes($p, [byte[]] @(0x82, 0xA0, 0x00, 0x0A))
        $t = @(Get-LogTail -Path $p -Tail 1 -Legacy 'BigEndianUnicode')
        Assert-Equal ([string] [char] 0x82A0) $t[0]
    }

    It '読めているものは読み直さない' {
        $p = Join-Path $dir 'ok.log'
        [IO.File]::WriteAllText($p, "収集を開始します`n", $utf8)
        # 読み直しが走れば、この文字コードでは別物になる
        $t = @(Get-LogTail -Path $p -Tail 1 -Legacy 'BigEndianUnicode')
        Assert-Equal '収集を開始します' $t[0]
    }
}

Describe '子プロセスの出力' {

    if ([Console]::IsOutputRedirected) {
        It 'リダイレクト先には UTF-8 (BOM 無し) で書く' {
            # テスト自身の出力先を変えたままにしないよう、戻してから抜ける
            $saved = [Console]::OutputEncoding
            try {
                Set-Utf8Output
                Assert-Equal 'utf-8' ([Console]::OutputEncoding.WebName)
                Assert-Equal 0 (@([Console]::OutputEncoding.GetPreamble())).Count '先頭に BOM を付けない'
            }
            finally { [Console]::OutputEncoding = $saved }
        }
    }
    else {
        Skip-It 'リダイレクト先には UTF-8 (BOM 無し) で書く' '画面に直接出しているため'
    }
}
