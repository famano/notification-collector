# Slack.Tests.ps1
# Slack のトークンは本人のもの1本であること。
#
# ここで留めたいのは名義である。**返信は本人の名義で出なければならない。**
# Bot トークンを併存させていた頃は、読み取りだけがユーザートークンを使い、
# 投稿は Bot を優先していた ―― 結果として、返事だけが「誰かのアプリの発言」として
# 相手に届いていた。相手はスレッドの相手に返事をしているつもりなので、
# これは設定の好みではなく、会話が成立するかどうかの問題になる。
#
# ネットワークには出ない。Invoke-WebRequest を差し替えて、
# 「どのトークンを載せて出ていくか」だけを見る。

. "$RepoRoot\phase5\lib\SlackConnector.ps1"
. "$RepoRoot\phase4\lib\HttpAction.ps1"

# --- 資格情報ストアを一時ファイルに差し替える (実データの secrets.dat は触らない) ---
$script:SlackTestStore = Join-Path (New-TestTempDir) 'secrets.dat'
function Get-SecretStorePath { param([string] $Path) return $script:SlackTestStore }
function Protect-Text   { param([string] $Text)   return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
function Unprotect-Text { param([string] $Base64) return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64)) }

# 外に出る代わりに、行き先とヘッダを控える。
$script:SlackCalls = @()
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $ContentType, $Body, [switch] $UseBasicParsing, $TimeoutSec)
    $script:SlackCalls += [pscustomobject]@{
        uri    = [string] $Uri
        method = [string] $Method
        auth   = [string] $Headers['Authorization']
        body   = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) } else { [string] $Body }
    }
    $json = '{"ok":true,"ts":"1700000000.000200","channel":"C1","permalink":"https://x.slack.com/p/1"}'
    return [pscustomobject]@{ RawContentStream = (New-Object IO.MemoryStream (,[Text.Encoding]::UTF8.GetBytes($json))) }
}

Describe 'Slack のトークンは本人のもの1本' {

    It '本人のトークンがあれば設定済み' {
        Set-Secret -Name 'slack.userToken' -Value 'xoxp-me'
        Assert-True (Test-SlackConfigured)
        Assert-Equal 'xoxp-me' (Get-SlackToken)
    }

    It 'Bot トークンしか無ければ未設定 (もう読まない)' {
        [void] (Remove-Secret -Name 'slack.userToken')
        Set-Secret -Name 'slack.botToken' -Value 'xoxb-legacy'
        Assert-False (Test-SlackConfigured) 'Bot トークンで設定済みになっています'
        Assert-Null (Get-SlackToken)
    }

    It '保管庫に残った Bot トークンは捨てる (読まない鍵を残さない)' {
        Set-Secret -Name 'slack.userToken' -Value 'xoxp-me'
        Assert-True (Remove-SlackBotToken)
        Assert-Null (Get-Secret -Name 'slack.botToken')
        Assert-False (Remove-SlackBotToken) '2回目も消したと言っています'
        # 本人のトークンは触らない
        Assert-Equal 'xoxp-me' (Get-SlackToken)
    }
}

Describe '投稿は本人の名義で出る' {

    It '投稿に載るのは本人のトークン' {
        Set-Secret -Name 'slack.userToken' -Value 'xoxp-me'
        $script:SlackCalls = @()
        $r = Send-SlackMessage -Channel 'C1' -Text 'お世話になっております' -ThreadTs '1700000000.000100'
        $post = @($script:SlackCalls | Where-Object { $_.uri -like '*chat.postMessage*' })
        Assert-Equal 1 $post.Count '投稿が1回ではありません'
        Assert-Equal 'Bearer xoxp-me' $post[0].auth
        Assert-Match 'お世話になっております' $post[0].body
        Assert-Match '1700000000\.000100' $post[0].body   # 元スレッドへの返信になっている
        Assert-Equal '1700000000.000200' $r.ts
    }

    It '古い Bot トークンが残っていても、投稿は本人のトークンで出る' {
        # 併存していた頃の壊れ方: 読み取りは本人、投稿だけ Bot 名義になっていた。
        Set-Secret -Name 'slack.userToken' -Value 'xoxp-me'
        Set-Secret -Name 'slack.botToken'  -Value 'xoxb-legacy'
        $script:SlackCalls = @()
        [void] (Send-SlackMessage -Channel 'C1' -Text 'x')
        foreach ($c in $script:SlackCalls) {
            Assert-True ($c.auth -notmatch 'xoxb') ("Bot トークンで出ています: " + $c.uri)
            Assert-Equal 'Bearer xoxp-me' $c.auth
        }
        [void] (Remove-Secret -Name 'slack.botToken')
    }

    It '読み取りも同じトークン (見える範囲と名義がずれない)' {
        Set-Secret -Name 'slack.userToken' -Value 'xoxp-me'
        $script:SlackCalls = @()
        [void] (Invoke-SlackApi -Method 'auth.test')
        Assert-Equal 1 $script:SlackCalls.Count
        Assert-Equal 'Bearer xoxp-me' $script:SlackCalls[0].auth
    }

    It '汎用 HTTP に載る Slack の資格情報も本人のトークン' {
        # 資格情報はホストから決まる。ここが別の関数を指したままだと、
        # 名前を変えた瞬間に「設定済みなのに未設定」に化ける。
        Set-Secret -Name 'slack.userToken' -Value 'xoxp-me'
        $c = Get-RequestCredential -Url 'https://slack.com/api/conversations.history'
        Assert-NotNull $c 'Slack の資格情報が付いていません'
        Assert-Equal 'Bearer xoxp-me' $c.value
    }
}

# 差し替えたものは戻す (後続のケースに持ち込まない)
Remove-Item -Path Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
[void] (Remove-Secret -Name 'slack.userToken')
