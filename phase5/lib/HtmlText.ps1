# HtmlText.ps1
# HTML を読める平文にする。
#
# ここに切り出してあるのは、同じものが2箇所で要るため。
# メールの本文は HTML にしか無いことがあり (Gmail / Outlook のどちらも)、
# Teams のチャットに至っては本文が常に HTML で返る。
# 落とし方が経路ごとに違うと、同じ文面がカードによって別の見え方になる。

function ConvertFrom-HtmlToText {
    param([string] $Html)
    if (-not $Html) { return '' }
    $txt = $Html -replace '(?s)<(script|style).*?</\1>', ''
    $txt = $txt -replace '<br\s*/?>', "`n" -replace '</p>', "`n" -replace '</tr>', "`n" -replace '</div>', "`n"
    $txt = $txt -replace '<[^>]+>', ''
    $txt = $txt -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"
    # タグを落とすと空行が大量に残る。3行以上の連続は2行に畳む。
    return ($txt -replace '[ \t]+\n', "`n" -replace '(\r?\n){3,}', "`n`n").Trim()
}
