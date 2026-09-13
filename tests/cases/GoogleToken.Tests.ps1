# GoogleToken.Tests.ps1
# Google のアクセストークンのキャッシュ。
#
# 再認可はカンバンのプロセスで起き、ワーカーや収集は別プロセスで動いている。
# キャッシュを期限だけで判断していた頃は、カンバンで Calendar を足して取り直しても
# ワーカーは最大 1 時間古いトークンを使い続け、Calendar が 403 / 401 のままだった。
# 画面上は「設定したのに直らない」にしか見えない、壊れても静かな箇所。
#
# ネットワークには出ない。Get-Secret と Invoke-RestMethod を差し替える。
# ケースは同じスコープで読み込まれるので、差し替えは最後に必ず元に戻す。

# HttpAction も SecretStore を読み込むので、差し替えより先に読む
. "$RepoRoot\phase4\lib\HttpAction.ps1"
. "$RepoRoot\phase4\lib\WorkTools.ps1"
. "$RepoRoot\phase5\lib\GmailConnector.ps1"

$script:FakeSecrets = @{}
$script:FakeRefreshSeen = @()
$script:FakeScope = ''
# 入れると、トークンの引き換えがこの本文で失敗する (Google の 400 応答を模す)
$script:FakeTokenError = ''
$script:FakeWebCalls = 0

function Get-Secret {
    param([string] $Name, [string] $Path)
    if ($script:FakeSecrets.ContainsKey($Name)) { return [string] $script:FakeSecrets[$Name] }
    return $null
}

# 漏洩検査が本物の secrets.dat を読みに行かないように
function Get-SecretNames { param([string] $Path) return @() }

function Invoke-WebRequest {
    $script:FakeWebCalls++
    throw '送信されてはいけないリクエストが送られました'
}

function Invoke-RestMethod {
    param($Uri, $Method, $TimeoutSec, $Body)
    $script:FakeRefreshSeen += [string] $Body.refresh_token
    if ($script:FakeTokenError) {
        $er = New-Object Management.Automation.ErrorRecord(
            (New-Object Exception 'リモート サーバーがエラーを返しました: (400) 不正な要求'),
            'WebCmdletWebResponseException', 'InvalidOperation', $null)
        $er.ErrorDetails = New-Object Management.Automation.ErrorDetails $script:FakeTokenError
        throw $er
    }
    return [pscustomobject]@{
        access_token = ('at-for-' + $Body.refresh_token)
        expires_in   = 3600
        scope        = $script:FakeScope
    }
}

try {

Describe 'Google のアクセストークンのキャッシュ' {

    It '期限内で同じリフレッシュトークンなら取り直さない' {
        Clear-GmailAccessToken
        $script:FakeSecrets = @{ 'gmail.clientId' = 'cid'; 'gmail.clientSecret' = 'sec'; 'gmail.refreshToken' = 'rt-old' }
        $script:FakeRefreshSeen = @()
        Assert-Equal 'at-for-rt-old' (Get-GmailAccessToken)
        Assert-Equal 'at-for-rt-old' (Get-GmailAccessToken)
        Assert-Equal 1 $script:FakeRefreshSeen.Count
    }

    It '別プロセスで再認可されたら、期限内でも新しいリフレッシュトークンで取り直す' {
        # カンバンが secrets.dat を書き換えた状態。このプロセスのキャッシュはまだ期限内。
        $script:FakeSecrets['gmail.refreshToken'] = 'rt-new'
        Assert-Equal 'at-for-rt-new' (Get-GmailAccessToken)
        Assert-Equal 'rt-new' $script:FakeRefreshSeen[-1]
    }

    It '付与スコープも新しいトークンのものに更新される' {
        Clear-GmailAccessToken
        $script:FakeSecrets['gmail.refreshToken'] = 'rt-a'
        $script:FakeScope = 'https://www.googleapis.com/auth/gmail.readonly'
        Assert-False (Test-GoogleScope 'https://www.googleapis.com/auth/calendar.events')

        $script:FakeSecrets['gmail.refreshToken'] = 'rt-b'
        $script:FakeScope = 'https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.events'
        Assert-True (Test-GoogleScope 'https://www.googleapis.com/auth/calendar.events')
    }

    It 'キャッシュを捨てたら次は取り直す (401 を受けたとき)' {
        [void] (Get-GmailAccessToken)
        $n = $script:FakeRefreshSeen.Count
        Clear-GmailAccessToken
        [void] (Get-GmailAccessToken)
        Assert-Equal ($n + 1) $script:FakeRefreshSeen.Count
    }

    It '設定が消えたら古いトークンを返さない' {
        [void] (Get-GmailAccessToken)
        $script:FakeSecrets.Remove('gmail.refreshToken')
        $threw = $false
        try { [void] (Get-GmailAccessToken) } catch { $threw = $true }
        Assert-True $threw
    }
}

Describe 'トークンを取れなかったときは本当の理由を返す' {
    $calUrl = 'https://www.googleapis.com/calendar/v3/calendars/primary/events'

    It '引き換えの失敗は、応答本文の理由 (invalid_grant) まで名指しする' {
        Clear-GmailAccessToken
        $script:FakeSecrets = @{ 'gmail.clientId' = 'cid'; 'gmail.clientSecret' = 'sec'; 'gmail.refreshToken' = 'rt-revoked' }
        $script:FakeTokenError = '{"error":"invalid_grant","error_description":"Token has been expired or revoked."}'
        $msg = ''
        try { [void] (Get-GmailAccessToken) } catch { $msg = $_.Exception.Message }
        Assert-Match 'invalid_grant' $msg
        Assert-Match 'Token has been expired or revoked' $msg
        Assert-Match '接続し直して' $msg
    }

    It '未設定と「設定済みだが取れない」を区別する' {
        Assert-Equal 'failed' (Get-CredentialStatus -Url $calUrl).state
        Assert-Match 'invalid_grant' (Get-CredentialStatus -Url $calUrl).error
        Assert-Null (Get-MissingCredentialHint -Url $calUrl)

        $saved = $script:FakeSecrets
        $script:FakeSecrets = @{}
        Assert-Equal 'unconfigured' (Get-CredentialStatus -Url $calUrl).state
        Assert-NotNull (Get-MissingCredentialHint -Url $calUrl)
        $script:FakeSecrets = $saved

        Assert-Equal 'none' (Get-CredentialStatus -Url 'https://example.com/').state
    }

    It '取れなかったら認証なしで送らず、理由を返す (送ると 401 で「未設定」に見える)' {
        $script:FakeWebCalls = 0
        $r = Invoke-HttpAction -Method 'GET' -Url $calUrl
        Assert-True $r.isError
        Assert-Match 'invalid_grant' $r.text
        Assert-Match 'credential_missing' $r.text
        Assert-Equal 0 $script:FakeWebCalls
    }

    It '取れなかった読み取りは承認に回さない (承認しても送られないため)' {
        Assert-False (Get-ToolRisk -Name 'http_request' -ToolInput ([pscustomobject]@{ method = 'GET'; url = $calUrl }) -Workspace '.').risky
    }

    It '書き込みは取れなかったときも承認に回す' {
        Assert-True (Get-ToolRisk -Name 'http_request' -ToolInput ([pscustomobject]@{ method = 'PATCH'; url = $calUrl }) -Workspace '.').risky
    }

    $script:FakeTokenError = ''
}

}
finally {
    # 差し替えを戻す。後続のケースが本物の Get-Secret / Invoke-RestMethod を使えるように。
    Remove-Item -Path Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    $script:FakeTokenError = ''
    . "$RepoRoot\phase5\lib\SecretStore.ps1"
    Clear-GmailAccessToken
    $script:GoogleGrantedScopes = @()
}
