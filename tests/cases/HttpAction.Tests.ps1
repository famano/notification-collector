# HttpAction.Tests.ps1
# 汎用 HTTP ツールの「束縛」。
#
# このアプリは宛先を URL ではなく資格情報で縛っている。つまり
#   - 資格情報はホストからしか決まらない (モデルの入力は効かない)
#   - 人に届く送信の口だけは汎用ツールから叩けない
# の2点が崩れると、通知本文に紛れた指示で宛先がすり替わる道ができる。

. "$RepoRoot\phase4\lib\HttpAction.ps1"

# --- 資格情報ストアを一時ファイルに差し替える ---
# 実データの secrets.dat には触らない。DPAPI も使わない (見たいのは筋であって暗号化ではない)。
$script:HttpTestStore = Join-Path (New-TestTempDir) 'secrets.dat'
function Get-SecretStorePath { param([string] $Path) if ($Path) { return $Path } return $script:HttpTestStore }
function Protect-Text   { param([string] $Text)   return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
function Unprotect-Text { param([string] $Base64) return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64)) }

# 配布設定と環境変数は見に行かせない (開発機に置いてあると結果が変わる)
$script:SavedHttpCfgEnv = $env:NOTIFICATION_COLLECTOR_CONFIG
$script:SavedHttpKeyEnv = $env:ANTHROPIC_API_KEY
$env:NOTIFICATION_COLLECTOR_CONFIG = Join-Path (New-TestTempDir) 'no-app-config.json'
$env:ANTHROPIC_API_KEY = $null

Set-Secret -Name 'anthropic.apiKey'         -Value 'sk-ant-api03-0123456789abcdefghij'
Set-Secret -Name 'anthropic.organizationId' -Value '11111111-2222-3333-4444-555555555555'
Set-Secret -Name 'backlog.space'            -Value 'example.backlog.jp'

try {

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

Describe '漏洩検査は「秘密」だけを見る' {

    It 'トークンが混ざっていれば止める (名前を返す)' {
        Assert-Equal 'anthropic.apiKey' (Test-SecretLeak 'Authorization: sk-ant-api03-0123456789abcdefghij')
    }

    It '組織 ID は止めない (秘密ではないし、URL に載って当たり前の値)' {
        Assert-Null (Test-SecretLeak 'https://api.anthropic.com/v1/organizations/11111111-2222-3333-4444-555555555555/usage_report/claude_code')
    }

    It 'Backlog のスペース名も止めない (ホスト名そのものなので、止めると全部通らない)' {
        Assert-Null (Test-SecretLeak 'https://example.backlog.jp/api/v2/issues')
    }

    It '知らない名前は秘密として扱う (緩める側は必ず明示で書く)' {
        Assert-True  (Test-SecretConfidential -Name 'github.token')
        Assert-True  (Test-SecretConfidential -Name 'newservice.token')
        Assert-False (Test-SecretConfidential -Name 'anthropic.organizationId')
    }
}

Describe 'Claude の API' {

    It '通常の口には通常のキーを付ける' {
        $spec = Get-HostCredentialSpec -Url 'https://api.anthropic.com/v1/models?limit=1'
        Assert-Equal 'anthropic' $spec.service
        Assert-Equal 'Get-AnthropicApiKey' $spec.dynamic
        Assert-Equal 'x-api-key' $spec.header
    }

    It '組織の口 (/v1/organizations/...) は管理 API キーに切り替える' {
        # 同じホストでも道によって鍵が変わる。通常のキーでは通らない口なので、
        # ここを取り違えると「設定済みなのに 401」という一番読めない形になる。
        $spec = Get-HostCredentialSpec -Url 'https://api.anthropic.com/v1/organizations/abc/usage_report/claude_code'
        Assert-Equal 'Get-AnthropicAdminApiKey' $spec.dynamic
    }

    It '設定カードの名前は1つに寄る (通常の口も組織の口も anthropic)' {
        Assert-Equal 'anthropic' (Get-ServiceKey -Url 'https://api.anthropic.com/v1/messages')
        Assert-Equal 'anthropic' (Get-ServiceKey -Url 'https://api.anthropic.com/v1/organizations/abc/usage_report/claude_code')
    }
}

Describe 'URL の差し込み口はワーカーが埋める' {

    It '{organizationId} を実際の値に置き換える' {
        $r = Expand-RequestUrl -Url 'https://api.anthropic.com/v1/organizations/{organizationId}/usage_report/claude_code'
        Assert-Equal '' $r.error
        Assert-Equal 'https://api.anthropic.com/v1/organizations/11111111-2222-3333-4444-555555555555/usage_report/claude_code' $r.url
    }

    It '書き方が違っても埋める (モデルの表記ゆれで詰まらせない)' {
        Assert-Equal 'https://api.anthropic.com/v1/organizations/11111111-2222-3333-4444-555555555555/x' `
            (Expand-RequestUrl -Url 'https://api.anthropic.com/v1/organizations/{org_id}/x').url
    }

    It '差し込み口が無ければ何もしない' {
        $u = 'https://api.github.com/user/repository_invitations/1'
        Assert-Equal $u (Expand-RequestUrl -Url $u).url
    }

    It '値が無ければ、送る前に理由を返す (推測で叩かせない)' {
        [void] (Remove-Secret -Name 'anthropic.organizationId')
        try {
            $r = Expand-RequestUrl -Url 'https://api.anthropic.com/v1/organizations/{organizationId}/x'
            Assert-Match '組織 ID' $r.error
            Assert-Match 'credential_missing' $r.error
        }
        finally {
            Set-Secret -Name 'anthropic.organizationId' -Value '11111111-2222-3333-4444-555555555555'
        }
    }

    It 'URL の形を壊す値は埋めない (別の道に飛ばさない)' {
        Set-Secret -Name 'anthropic.organizationId' -Value 'abc/../../v1/messages'
        try {
            $r = Expand-RequestUrl -Url 'https://api.anthropic.com/v1/organizations/{organizationId}/x'
            Assert-NotEqual '' $r.error
        }
        finally {
            Set-Secret -Name 'anthropic.organizationId' -Value '11111111-2222-3333-4444-555555555555'
        }
    }
}

}
finally {
    $env:NOTIFICATION_COLLECTOR_CONFIG = $script:SavedHttpCfgEnv
    $env:ANTHROPIC_API_KEY = $script:SavedHttpKeyEnv
}
