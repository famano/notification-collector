# HttpAction.Tests.ps1
# 汎用 HTTP ツールの「束縛」。
#
# このアプリは宛先を URL ではなく資格情報で縛っている。つまり
#   - 資格情報はホストからしか決まらない (モデルの入力は効かない)
#   - 人に届く送信の口だけは汎用ツールから叩けない
# の2点が崩れると、通知本文に紛れた指示で宛先がすり替わる道ができる。

. "$RepoRoot\phase4\lib\HttpAction.ps1"

Describe 'ホストから資格情報を決める' {

    It '既知のホストとそのサブドメインを見分ける' {
        Assert-Equal 'github' (Get-HostCredentialSpec -Url 'https://api.github.com/user').service
        Assert-Equal 'github' (Get-HostCredentialSpec -Url 'https://raw.githubusercontent.com/a/b').service
        Assert-Equal 'google' (Get-HostCredentialSpec -Url 'https://gmail.googleapis.com/gmail/v1/users/me/profile').service
        Assert-Equal 'slack'  (Get-HostCredentialSpec -Url 'https://api.slack.com/x').service
        Assert-Equal 'microsoft' (Get-HostCredentialSpec -Url 'https://graph.microsoft.com/v1.0/me').service
    }

    It '似た名前の別ホストには何も付けない' {
        # 末尾一致は「.」を挟んだサブドメインだけ。github.com.evil.example は別物
        Assert-Null (Get-HostCredentialSpec -Url 'https://api.github.com.evil.example/user')
        Assert-Null (Get-HostCredentialSpec -Url 'https://notgithub.com/user')
        Assert-Null (Get-HostCredentialSpec -Url 'https://example.com/')
    }

    It 'URL として読めないものは弾く' {
        Assert-Equal '' (Get-UrlHost 'not a url')
        Assert-Null (Get-HostCredentialSpec -Url 'not a url')
    }

    It 'サービス名は正規化される (設定カードを言い回しで増やさないため)' {
        Assert-Equal 'github' (Get-ServiceKey -Url 'https://api.github.com/repos/x/y/invitations')
        Assert-Equal 'google' (Get-ServiceKey -Url 'https://www.googleapis.com/calendar/v3/x')
        # Outlook も Teams も設定カードは1枚。サービス名はアプリ名ではなく microsoft
        Assert-Equal 'microsoft' (Get-ServiceKey -Url 'https://graph.microsoft.com/v1.0/me/messages')
        # 知らないホストはホスト名そのもの。それでも件ごとにぶれない
        Assert-Equal 'zoom.us' (Get-ServiceKey -Url 'https://zoom.us/j/123')
        Assert-Equal '' (Get-ServiceKey -Url '')
    }
}

Describe '人に届く送信の口は汎用ツールから叩けない' {

    It 'Slack の投稿系は塞ぐ' {
        Assert-True (Test-BoundOnlyEndpoint -Url 'https://slack.com/api/chat.postMessage')
        Assert-True (Test-BoundOnlyEndpoint -Url 'https://slack.com/api/chat.postEphemeral')
        Assert-True (Test-BoundOnlyEndpoint -Url 'https://slack.com/api/chat.scheduleMessage?channel=C1')
    }

    It 'Gmail の送信系は塞ぐ' {
        Assert-True (Test-BoundOnlyEndpoint -Url 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send')
        Assert-True (Test-BoundOnlyEndpoint -Url 'https://www.googleapis.com/gmail/v1/users/me/drafts/send')
    }

    It 'Outlook の送信系は塞ぐ' {
        Assert-True (Test-BoundOnlyEndpoint -Url 'https://graph.microsoft.com/v1.0/me/sendMail' -Method 'POST')
        Assert-True (Test-BoundOnlyEndpoint -Url 'https://graph.microsoft.com/v1.0/me/messages/AAMk123/send' -Method 'POST')
        Assert-True (Test-BoundOnlyEndpoint -Url 'https://graph.microsoft.com/v1.0/me/messages/AAMk123/reply' -Method 'POST')
    }

    It 'Teams の投稿は塞ぐが、同じ URL の読み取りは通す' {
        # Graph は「読むのも投稿するのも同じ URL」。メソッドを見ないと、
        # 塞いだ瞬間にチャットの本文が取れなくなる。
        Assert-True  (Test-BoundOnlyEndpoint -Url 'https://graph.microsoft.com/v1.0/chats/19:abc@thread.v2/messages' -Method 'POST')
        Assert-False (Test-BoundOnlyEndpoint -Url 'https://graph.microsoft.com/v1.0/chats/19:abc@thread.v2/messages' -Method 'GET')
    }

    It 'メソッドが分からないときは塞ぐ側に倒す (ここは壁なので)' {
        Assert-True (Test-BoundOnlyEndpoint -Url 'https://graph.microsoft.com/v1.0/chats/19:abc@thread.v2/messages')
    }

    It '読み取りや他の操作は塞がない (できることは削らない)' {
        Assert-False (Test-BoundOnlyEndpoint -Url 'https://slack.com/api/conversations.history?channel=C1')
        Assert-False (Test-BoundOnlyEndpoint -Url 'https://gmail.googleapis.com/gmail/v1/users/me/messages/123')
        Assert-False (Test-BoundOnlyEndpoint -Url 'https://api.github.com/user/repository_invitations/1')
        # 下書きの作成は外に出ない。宛先は利用者が下書きの上で直せる
        Assert-False (Test-BoundOnlyEndpoint -Url 'https://graph.microsoft.com/v1.0/me/messages' -Method 'POST')
        Assert-False (Test-BoundOnlyEndpoint -Url 'https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages' -Method 'GET')
    }
}

Describe 'メソッドの分類' {

    It '読むだけのメソッドを見分ける' {
        Assert-False (Test-WriteMethod -Method 'GET')
        Assert-False (Test-WriteMethod -Method 'get')
        Assert-False (Test-WriteMethod -Method 'HEAD')
        Assert-False (Test-WriteMethod -Method 'OPTIONS')
    }

    It '状態を変えるメソッドを見分ける' {
        foreach ($m in @('POST', 'PATCH', 'PUT', 'DELETE', 'patch')) {
            Assert-True (Test-WriteMethod -Method $m) ("{0} が読み取り扱いになっています" -f $m)
        }
    }
}
