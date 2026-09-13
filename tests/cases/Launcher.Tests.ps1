# Launcher.Tests.ps1
# ダブルクリックで起動できる形が壊れていないこと。
#
# ここで見ているのは配った先の一番手前の一歩で、失敗すると症状が
# 「アイコンを押したけど何も起きない」になる ―― 利用者からは原因が何も見えず、
# こちらからも再現しにくい。だから静かに壊れうるところだけを固定する。
#
#   - バッチは CRLF でないと cmd が読み違える (LF だと行がずれて落ちる)
#   - バッチに日本語を入れるとコードページ次第で文字化けする。案内は PowerShell 側に置く
#   - 実行ポリシーを跨がないと、既定の Windows では .ps1 が動かない
#   - フォルダ名に空白が入る (デスクトップに置かれる) ので、パスは必ず引用する

$script:Launchers = @(
    @{ file = 'Start.cmd';   calls = 'Start.ps1' },
    @{ file = 'Stop.cmd';    calls = 'Start.ps1' },
    @{ file = 'Install.cmd'; calls = 'Install.ps1' }
)

Describe 'ダブルクリックで起動する入口' {

    foreach ($l in $script:Launchers) {
        $path = Join-Path $RepoRoot $l.file

        It ($l.file + ' がある') {
            Assert-True (Test-Path -LiteralPath $path) ("{0} がありません" -f $l.file)
        }

        It ($l.file + ' は CRLF (cmd が読める改行)') {
            $bytes = [IO.File]::ReadAllBytes($path)
            $lf = 0; $crlf = 0
            for ($i = 0; $i -lt $bytes.Length; $i++) {
                if ($bytes[$i] -ne 0x0A) { continue }
                $lf++
                if ($i -gt 0 -and $bytes[$i - 1] -eq 0x0D) { $crlf++ }
            }
            Assert-True ($lf -gt 0) '改行がありません'
            Assert-Equal $lf $crlf 'CRLF でない行があります'
        }

        It ($l.file + ' は ASCII のみ (コードページに左右されない)') {
            $bytes = [IO.File]::ReadAllBytes($path)
            $bad = @($bytes | Where-Object { $_ -gt 0x7F })
            Assert-Equal 0 $bad.Count '日本語やBOMが入っています。案内は PowerShell 側に書いてください'
        }

        It ($l.file + ' は実行ポリシーを跨いで PowerShell を呼ぶ') {
            $text = [IO.File]::ReadAllText($path)
            Assert-Match 'ExecutionPolicy Bypass' $text
            Assert-Match 'NoProfile' $text
            Assert-Match ([regex]::Escape($l.calls)) $text
        }

        It ($l.file + ' はパスを引用している (空白を含むフォルダに置かれる)') {
            $text = [IO.File]::ReadAllText($path)
            Assert-Match '"%~dp0' $text
            Assert-True ($text -notmatch '(?m)-File\s+%~dp0') 'パスが引用されていません'
        }
    }

    It 'Stop.cmd は止めるだけ (起動しない)' {
        $text = [IO.File]::ReadAllText((Join-Path $RepoRoot 'Stop.cmd'))
        Assert-Match '\-Stop' $text
    }

    It '窓がすぐ閉じない (エラーが読めないまま消えるのを防ぐ)' {
        foreach ($l in $script:Launchers) {
            $text = [IO.File]::ReadAllText((Join-Path $RepoRoot $l.file))
            Assert-Match 'pause' $text
        }
    }

    It '改行が checkout で LF に戻らないよう .gitattributes で固定している' {
        $ga = Join-Path $RepoRoot '.gitattributes'
        Assert-True (Test-Path -LiteralPath $ga) '.gitattributes がありません'
        Assert-Match '\*\.cmd\s+text\s+eol=crlf' ([IO.File]::ReadAllText($ga))
    }
}

Describe '初回セットアップ' {

    $install = Join-Path $RepoRoot 'Install.ps1'

    It 'Install.ps1 がある' {
        Assert-True (Test-Path -LiteralPath $install)
    }

    It '管理者権限を要求しない (配った先で止まる)' {
        $text = [IO.File]::ReadAllText($install)
        Assert-True ($text -notmatch 'RunAs') '昇格を求めています'
        Assert-True ($text -notmatch '#Requires -RunAsAdministrator') '昇格を求めています'
    }

    It 'デスクトップとスタートアップにショートカットを作り、取り消せる' {
        $text = [IO.File]::ReadAllText($install)
        Assert-Match 'WScript\.Shell' $text
        Assert-Match "GetFolderPath\('Desktop'\)" $text
        Assert-Match "GetFolderPath\('Startup'\)" $text
        Assert-Match 'Uninstall' $text
    }

    It 'ZIP 経由のブロックを外す (「何も起きない」の典型)' {
        Assert-Match 'Unblock-File' ([IO.File]::ReadAllText($install))
    }
}
