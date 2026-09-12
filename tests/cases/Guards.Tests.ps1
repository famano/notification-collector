# Guards.Tests.ps1
# 「書いてあるのに効かないガード」がちゃんと効くこと。
#
# どれも本文中に分岐として書かれているのに、パラメータの束縛で先に落ちるか、
# 判定が緩くて素通りするため、いままで一度も働いていなかったもの。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase2\lib\Dossier.ps1"
. "$RepoRoot\phase4\lib\WorkTools.ps1"

Describe '作業フォルダの境界' {
    $sep = [IO.Path]::DirectorySeparatorChar
    $ws  = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'out') + $sep + 'task-0001')

    It '中のファイルは中' {
        Assert-True (Test-InWorkspace $ws ($ws + $sep + 'memo.md'))
        Assert-True (Test-InWorkspace $ws ($ws + $sep + 'sub' + $sep + 'memo.md'))
    }

    It '作業フォルダそのものは中' {
        Assert-True (Test-InWorkspace $ws $ws)
    }

    It '名前が前方一致する隣のフォルダは外 (承認をすり抜けさせない)' {
        Assert-False (Test-InWorkspace $ws ($ws + '-x' + $sep + 'memo.md'))
        Assert-False (Test-InWorkspace $ws ($ws + '2' + $sep + 'memo.md'))
    }

    It '別のカードの作業フォルダは外' {
        $other = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'out') + $sep + 'task-0002')
        Assert-False (Test-InWorkspace $ws ($other + $sep + 'memo.md'))
    }

    It '空の入力は外' {
        Assert-False (Test-InWorkspace $ws '')
        Assert-False (Test-InWorkspace '' 'x')
    }

    It '隣のフォルダへの書き込みは承認を求める' {
        $r = Get-ToolRisk -Name 'write_file' -Workspace $ws `
                -ToolInput ([pscustomobject]@{ path = ($ws + '-x' + $sep + 'memo.md'); content = 'x'; purpose = 'p' })
        Assert-True $r.risky
    }
}

Describe '件のキーが無いときの台帳' {

    if (-not (Test-SqliteAvailable)) {
        Skip-It 'すべて' 'winsqlite3.dll が使えません'
    }
    else {
        $conn = New-TestStore

        It 'キーが空でも例外にせず、何も書かない' {
            Assert-False (Add-DossierNote -Conn $conn -SubjectKey '' -Note '分かったこと')
            Assert-Equal 0 (@($conn.Query('SELECT * FROM dossier')).Count)
        }

        It 'キーが空の読み出しは空を返す' {
            Assert-Equal '' (Get-DossierText -Conn $conn -SubjectKey '')
            Assert-Equal 0 (@(Get-DossierNotes -Conn $conn -SubjectKey '')).Count
            Assert-Null (Get-OpenTaskBySubject -Conn $conn -SubjectKey '')
        }

        It '本文が空でも例外にしない' {
            Assert-False (Add-DossierNote -Conn $conn -SubjectKey 'mail:a' -Note '')
        }

        Close-TestStore $conn
    }
}

Describe '元の通知が無いカードの出自' {
    . "$RepoRoot\phase4\lib\SourceAccess.ps1"

    It '手で起票したカードは、例外ではなく「取り直せない」と分かる形で返る' {
        $c = Get-SourceContext -Evt $null
        Assert-False $c.ok
        Assert-Equal 'none' $c.kind
        Assert-Match '手で起票' $c.note
    }
}
