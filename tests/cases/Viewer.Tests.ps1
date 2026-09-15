# Viewer.Tests.ps1
# 「このカードで、あなたは誰か」。名義の束縛。
#
# ここが崩れたときの症状は、カードの上では正常に見える ――
# 文面はきれいに書けていて、宛先も正しい。**名乗っているのが別人**なだけである。
# To: 他人 / Cc: 自分 のメールで実際にそれが起きていた (他人名義の返信を下書きしていた)。
# 送る前に承認画面で止まるとはいえ、そこで気付けるかどうかに賭ける話にはしない。

. "$RepoRoot\phase4\lib\Viewer.ps1"
. "$RepoRoot\phase4\lib\WorkTools.ps1"

Describe 'ヘッダからアドレスを取り出す' {

    It '表示名付きのアドレスからアドレスだけを取る' {
        Assert-Equal 'a@example.com' (@(Get-MailAddresses '山田 太郎 <a@example.com>'))[0]
    }

    It '複数の宛先を分ける' {
        $a = @(Get-MailAddresses 'a@example.com, 佐藤 <b@example.com>')
        Assert-Equal 2 $a.Count
        Assert-Equal 'a@example.com|b@example.com' ($a -join '|')
    }

    It '表示名に入ったカンマで分けない (引用符の中は区切りではない)' {
        $a = @(Get-MailAddresses '"Yamada, Taro" <a@example.com>, b@example.com')
        Assert-Equal 2 $a.Count
        Assert-Equal 'a@example.com' $a[0]
    }

    It '大文字小文字は揃える (突き合わせに使うため)' {
        Assert-Equal 'me@example.com' (@(Get-MailAddresses 'ME@Example.COM'))[0]
    }

    It 'アドレスの無い断片は落とす' {
        Assert-Equal 0 (@(Get-MailAddresses '(宛先未設定)')).Count
        Assert-Equal 0 (@(Get-MailAddresses '')).Count
    }
}

Describe 'このメールでの立場' {

    It '宛先が自分なら to' {
        Assert-Equal 'to' (Get-MailViewerRole -From 'x@e.com' -To 'me@e.com' -Cc '' -Self @('me@e.com'))
    }

    It 'Cc だけが自分なら cc (返事を求められているのは自分ではない)' {
        Assert-Equal 'cc' (Get-MailViewerRole -From 'x@e.com' -To '佐藤 <sato@e.com>' -Cc 'me@e.com' -Self @('me@e.com'))
    }

    It '宛先と Cc の両方に入っていれば to を優先する' {
        Assert-Equal 'to' (Get-MailViewerRole -From 'x@e.com' -To 'me@e.com' -Cc 'me@e.com' -Self @('me@e.com'))
    }

    It '自分が出したメールなら from' {
        Assert-Equal 'from' (Get-MailViewerRole -From 'Me <me@e.com>' -To 'x@e.com' -Cc '' -Self @('me@e.com'))
    }

    It 'どこにも自分が出てこなければ other (メーリングリスト等)' {
        Assert-Equal 'other' (Get-MailViewerRole -From 'x@e.com' -To 'list@e.com' -Cc '' -Self @('me@e.com'))
    }

    It '自分のアドレスが分からなければ unknown (当て推量で立場を決めない)' {
        Assert-Equal 'unknown' (Get-MailViewerRole -From 'x@e.com' -To 'a@e.com' -Cc 'b@e.com' -Self @())
        Assert-Equal 'unknown' (Get-MailViewerRole -From 'x@e.com' -To 'a@e.com' -Cc 'b@e.com' -Self @(''))
    }

    It 'エイリアスを繋いでいてもどれか一つ当たれば自分' {
        Assert-Equal 'to' (Get-MailViewerRole -From 'x@e.com' -To 'alias@e.com' -Cc '' -Self @('me@e.com', 'alias@e.com'))
    }
}

Describe '本人は1人 (繋いである全アカウントで見る)' {

    # 名義は1つに決まるが、本人は1人である。仕事用と個人用を両方繋いでいると、
    # 片方宛のメールがもう片方の受信箱にも届く。カードのアカウントだけで見ると
    # 「宛先は他人」と読み、**本人宛のメールに返さなくなる。**

    It '別のアカウント宛なら、それも本人の宛先として扱う' {
        $v = New-MailViewer -Who 'work@e.com' -From 'x@y.com' -To 'me@personal.com' -Cc '' `
                -SelfNames @('work@e.com', 'me@personal.com')
        Assert-Equal 'to' $v.role
    }

    It 'カードのアカウントだけで見ると取り違える (これを直した)' {
        $v = New-MailViewer -Who 'work@e.com' -From 'x@y.com' -To 'me@personal.com' -Cc ''
        Assert-Equal 'other' $v.role
    }

    It '別のアカウントが差出人なら、本人が出したメール' {
        $v = New-MailViewer -Who 'work@e.com' -From 'me@personal.com' -To 'x@y.com' -Cc '' `
                -SelfNames @('work@e.com', 'me@personal.com')
        Assert-Equal 'from' $v.role
    }

    It '他人宛のままなら立場は変わらない (広げすぎない)' {
        $v = New-MailViewer -Who 'work@e.com' -From 'x@y.com' -To 'sato@e.com' -Cc 'work@e.com' `
                -SelfNames @('work@e.com', 'me@personal.com')
        Assert-Equal 'cc' $v.role
    }

    It '名義はカードのアカウントのまま (返信はそこから出る)' {
        $v = New-MailViewer -Who 'work@e.com' -From 'x@y.com' -To 'me@personal.com' -Cc '' `
                -SelfNames @('work@e.com', 'me@personal.com')
        Assert-Equal 'work@e.com' $v.who
        Assert-Equal 'me@personal.com' $v.viaAccount
    }

    It '名義のアドレスで当たったときは、別アカウントの断りを入れない' {
        $v = New-MailViewer -Who 'work@e.com' -From 'x@y.com' -To 'work@e.com' -Cc '' `
                -SelfNames @('work@e.com', 'me@personal.com')
        Assert-Equal '' $v.viaAccount
    }

    It '別のアカウントで当たったことをプロンプトに書く (返信は別のアドレスから出る)' {
        $v = New-MailViewer -Who 'work@e.com' -From 'x@y.com' -To 'me@personal.com' -Cc '' `
                -SelfNames @('work@e.com', 'me@personal.com')
        $b = Get-ViewerBlock $v
        Assert-Match 'me@personal\.com' $b
        Assert-Match '別のアカウント' $b
    }
}

Describe 'モデルに渡す名義' {

    It '本人の名前が入る' {
        $v = New-MailViewer -Who 'me@e.com' -Label '仕事用' -From 'x@e.com' -To 'me@e.com' -Cc ''
        Assert-Match 'me@e\.com' (Get-ViewerBlock $v)
        Assert-Match '仕事用' (Get-ViewerBlock $v)
    }

    It '他人の名義で書くなと必ず書いてある' {
        foreach ($role in @('to', 'cc', 'from', 'other', 'member', 'unknown')) {
            $b = Get-ViewerBlock (New-Viewer -Who 'me@e.com' -Role $role)
            Assert-Match '本人以外の名義' $b ("role=" + $role)
        }
    }

    It 'Cc のときは「返事を求められているのは本人ではない」と主たる宛先を出す' {
        $v = New-MailViewer -Who 'me@e.com' -From 'x@e.com' -To '佐藤 <sato@e.com>' -Cc 'me@e.com'
        $b = Get-ViewerBlock $v
        Assert-Match 'Cc' $b
        Assert-Match '返事を求められている相手は本人ではありません' $b
        Assert-Match 'sato@e\.com' $b
        Assert-Match '既定は「返信しない」' $b
    }

    It '宛先が本人なら返信してよいと書いてある' {
        $v = New-MailViewer -Who 'me@e.com' -From 'x@e.com' -To 'me@e.com' -Cc ''
        $b = Get-ViewerBlock $v
        Assert-Match '本人の名義で返信' $b
        # 宛先なのに「返信しない」を既定にしてしまうと、今度は返すべきものを返さなくなる
        Assert-True ($b -notmatch '既定は「返信しない」')
    }

    It '本人の名前が取れなくても束縛は出す (名義の話は無くならない)' {
        $b = Get-ViewerBlock (New-Viewer -Who '' -Role 'unknown')
        Assert-NotNull $b
        Assert-Match '本人以外の名義' $b
    }

    It '本人が分からなければ空 (アカウントを持たない経路)' {
        Assert-Equal '' (Get-ViewerBlock $null)
    }
}

Describe '作業ログに出す一行' {

    It '名前と立場が出る' {
        $v = New-MailViewer -Who 'me@e.com' -Label '仕事用' -From 'x@e.com' -To 'sato@e.com' -Cc 'me@e.com'
        Assert-Match 'me@e\.com' (Get-ViewerLine $v)
        Assert-Match 'Cc' (Get-ViewerLine $v)
    }

    It '本人が分からなければ空' {
        Assert-Equal '' (Get-ViewerLine $null)
    }
}

Describe '承認画面に出る差出人' {

    It 'メールの送信には差出人が出る (誰の名義で出るかをそこで確かめられる)' {
        $r = Get-ToolRisk -Name 'send_gmail' -Workspace 'C:\w' -SelfName 'me@e.com' `
                -ToolInput ([pscustomobject]@{ to = 'x@e.com'; subject = '件名'; body = '本文' })
        Assert-True $r.risky
        Assert-Match '差出人' $r.detail
        Assert-Match 'me@e\.com' $r.detail
    }

    It 'Slack の投稿にも名義が出る' {
        $r = Get-ToolRisk -Name 'send_slack_message' -Workspace 'C:\w' -SelfName 'team / 私' `
                -ToolInput ([pscustomobject]@{ text = '本文' })
        Assert-Match '名義' $r.detail
        Assert-Match '私' $r.detail
    }

    It '名前が取れていなくても承認画面は壊れない' {
        $r = Get-ToolRisk -Name 'send_gmail' -Workspace 'C:\w' `
                -ToolInput ([pscustomobject]@{ to = 'x@e.com'; subject = '件名'; body = '本文' })
        Assert-Match '差出人: あなた' $r.detail
    }
}
