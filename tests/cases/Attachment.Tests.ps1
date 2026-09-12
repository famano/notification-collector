# Attachment.Tests.ps1
# 添付の取り込み。名前と MIME 型の引き当て。
#
# 「添付をご確認ください」で終わるメールを閉じるための道具なので、
# 名前を省いた瞬間に中身が読めなくなるのでは意味がない。
# ネットワークには出ないので、取得そのものは差し替えて経路だけ見る。

. "$RepoRoot\phase4\lib\WorkTools.ps1"

# Gmail からの取得を差し替える。中身は CSV。
$script:FakeBytes = [Text.Encoding]::UTF8.GetBytes("氏名,所属`n天野,開発")
function Get-GmailAttachmentBytes {
    param([string] $MessageId, [string] $AttachmentId)
    return $script:FakeBytes
}

$ws = New-TestTempDir
$atts = @(
    [pscustomobject]@{ id = 'gmail:m1:a1'; name = '参加者一覧.csv'; mimeType = 'text/csv'; size = 40 },
    [pscustomobject]@{ id = 'gmail:m2:a2'; name = ''; mimeType = 'text/plain'; size = 12 }
)

Describe '添付の取り込み' {

    It '名前を省いても、元の名前で保存される' {
        $r = Invoke-WorkTool -Name 'fetch_attachment' -Workspace $ws -SourceAttachments $atts `
                -ToolInput ([pscustomobject]@{ attachment_id = 'gmail:m1:a1' })
        Assert-False $r.isError
        Assert-Match '参加者一覧\.csv' $r.text
    }

    It '名前が戻れば拡張子も戻るので、中身がモデルに渡る' {
        $r = Invoke-WorkTool -Name 'fetch_attachment' -Workspace $ws -SourceAttachments $atts `
                -ToolInput ([pscustomobject]@{ attachment_id = 'gmail:m1:a1' })
        Assert-Match '氏名,所属' $r.text
        Assert-True ($r.text -notmatch 'テキストとして読める形式ではありません') `
            'テキストの添付が読めないまま返っています'
    }

    It '名前を指定すればそれが優先される' {
        $r = Invoke-WorkTool -Name 'fetch_attachment' -Workspace $ws -SourceAttachments $atts `
                -ToolInput ([pscustomobject]@{ attachment_id = 'gmail:m1:a1'; name = 'meibo.csv' })
        Assert-Match 'meibo\.csv' $r.text
    }

    It '名前がどこにも無くても、MIME 型がテキストなら中身を返す' {
        $r = Invoke-WorkTool -Name 'fetch_attachment' -Workspace $ws -SourceAttachments $atts `
                -ToolInput ([pscustomobject]@{ attachment_id = 'gmail:m2:a2' })
        Assert-False $r.isError
        Assert-Match '氏名,所属' $r.text
    }

    It '一覧に無い添付でも落ちない' {
        $r = Invoke-WorkTool -Name 'fetch_attachment' -Workspace $ws -SourceAttachments $atts `
                -ToolInput ([pscustomobject]@{ attachment_id = 'gmail:m9:a9'; name = 'x.txt' })
        Assert-False $r.isError
    }

    It 'パス区切りを含む名前でも作業フォルダの外に出さない' {
        $sep = [IO.Path]::DirectorySeparatorChar
        $outside = [IO.Path]::GetFullPath((Join-Path $ws ('..' + $sep + 'evil.txt')))
        $r = Invoke-WorkTool -Name 'fetch_attachment' -Workspace $ws -SourceAttachments $atts `
                -ToolInput ([pscustomobject]@{ attachment_id = 'gmail:m1:a1'; name = ('..' + $sep + 'evil.txt') })
        Assert-False $r.isError
        Assert-True  (Test-Path -LiteralPath (Join-Path $ws 'evil.txt')) '作業フォルダに置かれていません'
        Assert-False (Test-Path -LiteralPath $outside) '作業フォルダの外にファイルが出ました'
    }

    It '知らない出どころの添付は取りに行かない' {
        $r = Invoke-WorkTool -Name 'fetch_attachment' -Workspace $ws -SourceAttachments $atts `
                -ToolInput ([pscustomobject]@{ attachment_id = 'http://example.com/x' })
        Assert-True $r.isError
    }
}
