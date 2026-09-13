# SourceAccess.Tests.ps1
# 出自の取り直し。ネットワークを使わない部分だけを見る。
#
# 本文から拾うリンクは、モデルにとって「次に叩ける先」になる。
# 招待 URL や確認リンクは本文の中にしか無いので、ここで取りこぼすと
# 「リンクを開いてください」と書いて終わるカードに戻る。

. "$RepoRoot\phase4\lib\SourceAccess.ps1"

Describe '本文からリンクを拾う' {

    It 'http/https を拾う' {
        $links = @(Get-LinksFromText 'くわしくは https://github.com/a/b/invitations を見てください')
        Assert-Equal 1 $links.Count
        Assert-Equal 'https://github.com/a/b/invitations' $links[0]
    }

    It '文末の句読点や括弧は落とす' {
        Assert-Equal 'https://example.com/x' (@(Get-LinksFromText 'ここ https://example.com/x。'))[0]
        Assert-Equal 'https://example.com/y' (@(Get-LinksFromText '(https://example.com/y)'))[0]
    }

    It '同じリンクは1つにまとめる' {
        $links = @(Get-LinksFromText "https://example.com/a`nhttps://example.com/a`nhttps://example.com/b")
        Assert-Equal 2 $links.Count
    }

    It '拾いすぎない (上限がある)' {
        $text = (1..50 | ForEach-Object { "https://example.com/$_" }) -join ' '
        Assert-Equal 20 (@(Get-LinksFromText $text)).Count
    }

    It 'リンクの無い本文では空' {
        Assert-Equal 0 (@(Get-LinksFromText 'リンクはありません')).Count
        Assert-Equal 0 (@(Get-LinksFromText '')).Count
    }
}

Describe '長すぎる本文の切り詰め' {

    It '上限を超えたら切って、切ったことを書く' {
        $t = Limit-SourceText ('あ' * 100) 10
        Assert-Equal 10 $t.Split("`n")[0].Length
        Assert-Match '省略' $t
    }

    It '上限内ならそのまま' {
        Assert-Equal 'みじかい' (Limit-SourceText 'みじかい' 100)
    }
}

Describe '元の通知が無いカード' {

    It '取り直す API を持たない通知は、通知の本文をそのまま返す' {
        $evt = @{ source = 'notification'; app = 'Chrome'; link = ''; body = '本文 https://example.com/a'; raw_json = '' }
        $c = Get-SourceContext -Evt $evt
        Assert-True $c.ok
        Assert-Equal 'notification' $c.kind
        Assert-Match '本文' $c.text
        Assert-Equal 1 (@($c.links)).Count
        Assert-Match '取り直せる API がありません' $c.note
    }
}
