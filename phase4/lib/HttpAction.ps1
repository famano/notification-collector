# HttpAction.ps1
# 汎用 HTTP ツールの実体。カードを閉じるための「効かせる」側。
#
# 設計の要点 ―― 束縛を URL から資格情報に移す。
#
#   このアプリの原則は「宛先はモデルに決めさせない」だった。送信ツールは
#   カードの元通知から投稿先を束縛していて、モデルは宛先を指定できない。
#   だが API を叩く操作にその形は使えない。叩き先は事前に列挙できないし、
#   用途ごとに専用ツールを生やすと、カレンダーの出欠、GitHub の招待、と
#   際限なく増えていく割に、少し形の違う依頼が来たとたん何も出来なくなる。
#
#   そこで束縛する対象を変える。URL はモデルが自由に決めてよい。代わりに
#   **資格情報はモデルに一切渡さない**。ワーカーがホストを見て、そのホスト用の
#   資格情報だけをサーバ側で注入する。結果として:
#     - モデルはトークンを見られないので、どこかへ書き出すことができない
#     - Google のトークンは googleapis.com にしか付かない。未知のホストには
#       何も付かないので、資格情報を持ち出す経路が原理的に存在しない
#     - 承認画面には実際に飛ぶリクエストが出る。認証行だけは伏せ字にする
#
#   これで「狭すぎる専用ツール」と「何でもできてしまう生の HTTP」の間を取れる。

. "$PSScriptRoot\..\..\phase5\lib\SecretStore.ps1"

# ホスト → 資格情報。サフィックス一致で引く。
# ここに無いホストには認証情報を付けない (公開 API と素の Web ページは
# それで問題なく読める)。
$script:CredentialHosts = @(
    @{
        service  = 'github'
        match    = @('api.github.com', 'github.com', 'raw.githubusercontent.com', 'uploads.github.com')
        label    = 'GitHub トークン'
        secret   = 'github.token'
        scheme   = 'Bearer'
        setupHint = 'カンバンの「接続」から設定できます (端末なら .\phase5\Connect-Service.ps1 -Service github)'
    },
    @{
        service  = 'google'
        match    = @('googleapis.com', 'www.googleapis.com', 'gmail.googleapis.com')
        label    = 'Google トークン'
        dynamic  = 'Get-GmailAccessToken'
        scheme   = 'Bearer'
        setupHint = 'カンバンの「接続」から設定できます (端末なら .\phase5\Connect-Service.ps1 -Service gmail)'
    },
    @{
        service  = 'slack'
        match    = @('slack.com', 'api.slack.com', 'files.slack.com')
        label    = 'Slack トークン'
        dynamic  = 'Get-SlackReadToken'
        scheme   = 'Bearer'
        setupHint = 'カンバンの「接続」から設定できます (端末なら .\phase5\Connect-Service.ps1 -Service slack)'
    }
)

function Get-ServiceKey {
    <#
      .SYNOPSIS
        URL から、設定カードと台帳を束ねるための正規化されたサービス名。
      .DESCRIPTION
        「何の権限が足りないか」をモデルの文章で束ねてはいけない。
        同じ GitHub の権限不足でも、カードごとに違う言い回しになるため、
        設定カードが何枚も立ち、台帳も引き継がれなくなる。
        ホストから決まる短い識別子で束ねる。
    #>
    param([string] $Url)
    if (-not $Url) { return '' }
    $spec = Get-HostCredentialSpec -Url $Url
    if ($spec) { return [string] $spec.service }
    $h = Get-UrlHost $Url
    if (-not $h) { return '' }
    # 知らないホストはホスト名そのものを識別子にする
    return $h
}

# 「人に届くもの」を出す口。ここは汎用ツールから叩かせない。
#
# 理由: このアプリは投稿先・返信先をカードから束縛することで、通知本文に
# 紛れた指示で宛先がすり替わるのを防いでいる。汎用 HTTP で chat.postMessage を
# 直接叩けるなら、その壁は素通りできてしまい、土台が無効になる。
# 資格情報を注入しないことで塞ぐ (認証エラーで落ちる)。
$script:BoundOnlyEndpoints = @(
    'slack\.com/api/chat\.postMessage',
    'slack\.com/api/chat\.postEphemeral',
    'slack\.com/api/chat\.scheduleMessage',
    'slack\.com/api/chat\.update',
    'slack\.com/api/files\.upload',
    'slack\.com/api/files\.completeUploadExternal',
    'googleapis\.com/gmail/v1/users/[^/]+/messages/send',
    'googleapis\.com/gmail/v1/users/[^/]+/drafts/send',
    'googleapis\.com/upload/gmail/v1/users/[^/]+/messages/send'
)

function Test-BoundOnlyEndpoint {
    param([Parameter(Mandatory)] [string] $Url)
    foreach ($p in $script:BoundOnlyEndpoints) {
        if ($Url -match $p) { return $true }
    }
    return $false
}

function Get-UrlHost {
    param([Parameter(Mandatory)] [string] $Url)
    try { return ([Uri] $Url).Host.ToLower() } catch { return '' }
}

function Get-HostCredentialSpec {
    param([Parameter(Mandatory)] [string] $Url)
    $h = Get-UrlHost $Url
    if (-not $h) { return $null }
    foreach ($spec in $script:CredentialHosts) {
        foreach ($m in $spec.match) {
            if ($h -eq $m -or $h.EndsWith('.' + $m)) { return $spec }
        }
    }
    return $null
}

function Get-RequestCredential {
    <#
      .SYNOPSIS
        この URL に付ける資格情報。無ければ $null。
      .OUTPUTS
        @{ value; label } — value は実際のヘッダ値、label は画面に出す名前
    #>
    param([Parameter(Mandatory)] [string] $Url)
    $spec = Get-HostCredentialSpec -Url $Url
    if (-not $spec) { return $null }

    $token = ''
    if ($spec.dynamic) {
        if (-not (Get-Command $spec.dynamic -ErrorAction SilentlyContinue)) { return $null }
        try { $token = & $spec.dynamic } catch { return $null }
    }
    else {
        $token = Get-Secret -Name $spec.secret
    }
    if (-not $token) { return $null }
    return [pscustomobject]@{
        value = ("{0} {1}" -f $spec.scheme, $token)
        label = $spec.label
        setupHint = $spec.setupHint
    }
}

function Get-MissingCredentialHint {
    <#
      .SYNOPSIS
        資格情報が要りそうなのに無いホストについて、何を設定すればよいかを返す。
        require_human_step(credential_missing) から設定カードを作るのに使う。
    #>
    param([Parameter(Mandatory)] [string] $Url)
    $spec = Get-HostCredentialSpec -Url $Url
    if (-not $spec) { return $null }
    if (Get-RequestCredential -Url $Url) { return $null }
    return [pscustomobject]@{ label = $spec.label; setupHint = $spec.setupHint; host = (Get-UrlHost $Url) }
}

# 保管しているシークレットが、モデルの組み立てたリクエストに混ざっていないか。
#
# モデルは資格情報を渡されないが、作業中に読んだファイルやコマンド出力から
# トークンらしき文字列を拾うことはあり得る。それを外部へ送る形になっていたら、
# 承認画面に出す前に止める。利用者に判断させてよい種類の操作ではない。
function Test-SecretLeak {
    param([string] $Text)
    if (-not $Text) { return $null }
    foreach ($name in @(Get-SecretNames)) {
        $v = Get-Secret -Name $name
        # 短い値は誤検知する (空文字や 'true' など)。鍵として意味のある長さだけ見る。
        if (-not $v -or $v.Length -lt 16) { continue }
        if ($Text.Contains($v)) { return $name }
    }
    return $null
}

$script:ReadOnlyMethods = @('GET', 'HEAD', 'OPTIONS')

function Test-WriteMethod {
    param([Parameter(Mandatory)] [string] $Method)
    return ($script:ReadOnlyMethods -notcontains $Method.ToUpper())
}

function Invoke-HttpAction {
    <#
      .SYNOPSIS
        HTTP リクエストを1件実行する。承認の判断は呼び出し側が済ませている前提。
      .DESCRIPTION
        資格情報はここで注入する。呼び出し側 (= モデル) は Authorization を
        指定できない。指定されていても捨てる。
      .OUTPUTS
        [pscustomobject] text / isError
    #>
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Url,
        $Headers,
        [string] $Body,
        [int] $TimeoutSec = 45,
        [int] $MaxChars = 20000
    )

    if (Test-BoundOnlyEndpoint -Url $Url) {
        return [pscustomobject]@{
            isError = $true
            text = 'この宛先は汎用の http_request からは叩けません。人に届くメッセージの送信は、' +
                   '宛先がカードから束縛される専用ツール (send_gmail / send_slack_message) を使ってください。'
        }
    }

    $leak = Test-SecretLeak ($Url + "`n" + $Body)
    if ($leak) {
        return [pscustomobject]@{
            isError = $true
            text = ("リクエストに保管中の資格情報 ({0}) が含まれていたため、送信せずに中止しました。" -f $leak) +
                   '認証はワーカーが自動で付けます。トークンを本文や URL に入れないでください。'
        }
    }

    # モデルが付けた認証ヘッダは捨てる。認証はホストから決まる。
    $send = @{}
    if ($Headers) {
        foreach ($k in @($Headers.PSObject.Properties.Name)) {
            if ($k -imatch '^(authorization|cookie|proxy-authorization)$') { continue }
            $send[$k] = [string] $Headers.$k
        }
    }
    $cred = Get-RequestCredential -Url $Url
    if ($cred) { $send['Authorization'] = $cred.value }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = @{
        Uri = $Url; Method = $Method.ToUpper(); UseBasicParsing = $true
        TimeoutSec = $TimeoutSec; Headers = $send
    }
    if ($Body) {
        $req['Body'] = [Text.Encoding]::UTF8.GetBytes($Body)
        if (-not ($send.Keys | Where-Object { $_ -ieq 'Content-Type' })) {
            $req['ContentType'] = 'application/json; charset=utf-8'
        }
    }

    try {
        $resp = Invoke-WebRequest @req
        $text = ''
        try { $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) } catch { $text = [string] $resp.Content }
        if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + "`n…(応答が長いため省略)" }
        return [pscustomobject]@{
            isError = $false
            text = ("HTTP {0}`n`n{1}" -f [int] $resp.StatusCode, $text)
        }
    }
    catch {
        # 4xx/5xx は例外になるが、本文にこそ原因が書いてある (GitHub の
        # "Not Found" と権限不足の区別など)。握り潰すと同じ壁に何度もぶつかる。
        $status = ''
        $detail = ''
        $r = $_.Exception.Response
        if ($r) {
            try { $status = [int] $r.StatusCode } catch { }
            try {
                $sr = New-Object IO.StreamReader($r.GetResponseStream())
                $detail = $sr.ReadToEnd()
                $sr.Close()
            } catch { }
        }
        if ($detail.Length -gt 4000) { $detail = $detail.Substring(0, 4000) + '…' }

        $hint = ''
        if ($status -eq 401 -or $status -eq 403 -or $status -eq 404) {
            $miss = Get-MissingCredentialHint -Url $Url
            if ($miss) {
                $hint = "`n`n※このホスト ({0}) 用の{1}が設定されていません。権限不足が原因の可能性が高いです。" -f $miss.host, $miss.label
                $hint += "`n設定されていない権限が原因なら、推測で調べ続けずに require_human_step を blocker='credential_missing' で呼んでください。"
            }
        }
        return [pscustomobject]@{
            isError = $true
            text = ("HTTP {0} {1}`n{2}{3}" -f $status, $_.Exception.Message, $detail, $hint)
        }
    }
}
