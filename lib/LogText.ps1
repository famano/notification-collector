# LogText.ps1
# ログの文字コードを1か所に集める。
#
# 何が起きていたか:
#   子プロセス (収集・ワーカー・カンバン) の出力は Start.ps1 が logs\ にリダイレクト
#   している。そのとき何の文字コードで書かれるかを決めるのは、子プロセス側の
#   [Console]::OutputEncoding で、既定は OS のコンソールの文字コード ――
#   日本語 Windows なら CP932 になる。
#   ところがこのリポジトリはスクリプトも JSON も DB もすべて UTF-8 で、
#   親も Get-Content -Encoding UTF8 で読んでいた。書き手と読み手が食い違うので、
#   -Follow の画面だけが文字化けする。
#
#   しかも気付きにくい。logs\ を直接 Get-Content すると、既定の文字コードで
#   読まれるので化けない ―― 「ログは読めるのに -Follow だけ化ける」という、
#   原因がログ側にあると思いにくい出方になる。
#
# 直し方:
#   書く側を UTF-8 に寄せる。リポジトリの他のすべてと同じになり、読み手は
#   すでに UTF-8 なので揃う。溜まっている古いログは CP932 のままなので、
#   読み直せる逃げ道を読み手に残す。

function Set-Utf8Output {
    <#
      .SYNOPSIS
        このプロセスの標準出力・標準エラーを UTF-8 で書くようにする。
      .DESCRIPTION
        リダイレクトされているとき (= Start.ps1 の子として起動され、logs\ に
        書いているとき) だけ効かせる。画面に直接出しているときは触らない ――
        コンソールの文字コードを変えると、そのウィンドウの他の表示にも影響する。

        BOM は付けない。ログは末尾を継ぎ足して読むものなので、先頭の印は邪魔になる。
    #>
    if (-not [Console]::IsOutputRedirected) { return }
    # 失敗しても本題 (収集・作業・画面) は続けるべきなので、握り潰す。
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
}

function Get-LogTail {
    <#
      .SYNOPSIS
        ログの末尾を読む。UTF-8 で読み、読めなければ古い文字コードで読み直す。
      .PARAMETER Legacy
        UTF-8 として読めなかったときに使う文字コード。既定の Oem は、この修正より
        前に書かれたログ (日本語 Windows なら CP932) を読むためのもの。
      .DESCRIPTION
        UTF-8 として解釈できないバイトは U+FFFD に潰れる。それが出たときだけ
        読み直す ―― 溜まったログを、直した日を境に読めなくしないため。
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $Tail = 2,
        [string] $Legacy = 'Oem'
    )
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Tail -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 0 -and (($lines -join '') -match "�")) {
        $lines = @(Get-Content -LiteralPath $Path -Encoding $Legacy -Tail $Tail -ErrorAction SilentlyContinue)
    }
    # ここは展開させてよい (呼び出し側が @() で受ける)。カンマを付けると
    # 配列そのものが1個の要素として渡り、行数が数えられなくなる。
    return $lines
}
