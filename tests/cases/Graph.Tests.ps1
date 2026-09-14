# Graph.Tests.ps1
# Microsoft 365 (Outlook / Teams) 連携。
#
# ネットワークには出ない。Get-Secret と Invoke-RestMethod を差し替える。
# ケースは同じスコープで読み込まれるので、差し替えは最後に必ず元に戻す。
#
# ここで見ているのは「壊れても静かなところ」:
#   - リフレッシュトークンの入れ替わりを保存し損ねると、しばらく動いたあと
#     ある日 invalid_grant になる。原因が設定時から遠すぎて追えない
#   - 恒久的な失敗と一時的な失敗の区別を誤ると、watermark が止まって
#     取りこぼすか、逆に読める会話が永久に入らなくなる
#   - 投稿先の束縛と、承認の要否

. "$RepoRoot\phase4\lib\HttpAction.ps1"
. "$RepoRoot\phase4\lib\WorkTools.ps1"
. "$RepoRoot\phase5\lib\GraphConnector.ps1"

$script:FakeSecrets = @{}
$script:FakeTokenCalls = 0
$script:FakeDeviceCalls = 0
# 'pending' | 'ok' | 'declined' を入れると、デバイスコードの応答が変わる
$script:FakeDeviceState = 'pending'
# トークン更新で返すリフレッシュトークン。空なら返さない (入れ替えなし)
$script:FakeRotatedRefresh = ''
$script:FakeTokenError = ''
$script:FakeGrantedScope = 'openid profile offline_access User.Read Mail.ReadWrite Mail.Send Chat.Read ChatMessage.Send'

function Get-Secret {
    param([string] $Name, [string] $Path)
    if ($script:FakeSecrets.ContainsKey($Name)) { return [string] $script:FakeSecrets[$Name] }
    return $null
}
function Set-Secret {
    param([string] $Name, [string] $Value, [string] $Path)
    $script:FakeSecrets[$Name] = $Value
}
function Remove-Secret { param([string] $Name, [string] $Path) [void] $script:FakeSecrets.Remove($Name); return $true }
# 漏洩検査が本物の secrets.dat を読みに行かないように
function Get-SecretNames { param([string] $Path) return @() }

function Invoke-WebRequest {
    throw '送信されてはいけないリクエストが送られました'
}

function New-FakeOAuthError {
    param([string] $Body)
    $er = New-Object Management.Automation.ErrorRecord(
        (New-Object Exception 'リモート サーバーがエラーを返しました: (400) 不正な要求'),
        'WebCmdletWebResponseException', 'InvalidOperation', $null)
    $er.ErrorDetails = New-Object Management.Automation.ErrorDetails $Body
    return $er
}

function Invoke-RestMethod {
    param($Uri, $Method, $TimeoutSec, $Body)

    if ([string] $Uri -like '*/devicecode') {
        $script:FakeDeviceCalls++
        return [pscustomobject]@{
            device_code = 'DEV-CODE'; user_code = 'ABCD-EFGH'
            verification_uri = 'https://microsoft.com/devicelogin'
            message = 'コードを入れてください'; interval = 5; expires_in = 900
        }
    }

    $script:FakeTokenCalls++
    # 何を送ったか (シークレットを付けたか) を後から見る
    $script:LastTokenBody = $Body
    if ($script:FakeTokenError) { throw (New-FakeOAuthError $script:FakeTokenError) }

    if ([string] $Body.grant_type -eq 'urn:ietf:params:oauth:grant-type:device_code') {
        if ($script:FakeDeviceState -eq 'pending') {
            throw (New-FakeOAuthError '{"error":"authorization_pending","error_description":"待機中"}')
        }
        if ($script:FakeDeviceState -eq 'declined') {
            throw (New-FakeOAuthError '{"error":"authorization_declined","error_description":"拒否されました"}')
        }
        return [pscustomobject]@{
            access_token = 'at-device'; refresh_token = 'rt-1'; expires_in = 3600
            scope = $script:FakeGrantedScope
        }
    }

    # refresh_token での更新
    $out = @{
        access_token = ('at-for-' + [string] $Body.refresh_token)
        expires_in = 3600; scope = $script:FakeGrantedScope
    }
    if ($script:FakeRotatedRefresh) { $out['refresh_token'] = $script:FakeRotatedRefresh }
    return [pscustomobject] $out
}

try {

Describe 'Teams のリンク' {

    It '組み立てたリンクをそのまま読み戻せる' {
        $link = New-TeamsLink -ChatId '19:abc_def@thread.v2' -MessageId '1757600000000'
        $ref = ConvertFrom-TeamsLink $link
        Assert-Equal '19:abc_def@thread.v2' $ref.chatId
        Assert-Equal '1757600000000' $ref.messageId
    }

    It '解釈できないものは null (カードは立つが投稿先は付かない)' {
        Assert-Null (ConvertFrom-TeamsLink 'msteams://')
        Assert-Null (ConvertFrom-TeamsLink 'slack://channel?id=C1&message=1')
        Assert-Null (ConvertFrom-TeamsLink '')
    }
}

Describe '読み直すべき失敗かどうか' {

    It '権限不足や消えたチャットは何度読んでも同じ (watermark を止めない)' {
        Assert-True (Test-GraphPermanentError 'Microsoft Graph /chats/x/messages が失敗しました: ... (HTTP 403)')
        Assert-True (Test-GraphPermanentError '... (HTTP 404)')
    }

    It 'レート制限や一時的な障害は据え置く (進めると取りこぼす)' {
        Assert-False (Test-GraphPermanentError '... (HTTP 429)')
        Assert-False (Test-GraphPermanentError '... (HTTP 503)')
        Assert-False (Test-GraphPermanentError 'ネットワークに到達できません')
        Assert-False (Test-GraphPermanentError '')
    }
}

Describe 'Graph に渡す日時' {

    It 'UTC の ISO8601 で、引用符を付けない ($filter にそのまま入る)' {
        $t = ConvertTo-GraphTime ([DateTime]::SpecifyKind([DateTime] '2026-09-13T10:20:30', 'Utc'))
        Assert-Equal '2026-09-13T10:20:30Z' $t
    }
}

Describe 'Outlook のメールを共通の形にそろえる' {

    $msg = [pscustomobject]@{
        id = 'AAMk-1'; conversationId = 'CONV-1'
        subject = '見積の件'
        from = [pscustomobject]@{ emailAddress = [pscustomobject]@{ name = '山田 太郎'; address = 'taro@example.com' } }
        toRecipients = @([pscustomobject]@{ emailAddress = [pscustomobject]@{ name = '自分'; address = 'me@example.com' } })
        ccRecipients = @()
        receivedDateTime = '2026-09-13T01:00:00Z'
        bodyPreview = 'プレビュー'
        body = [pscustomobject]@{ contentType = 'html'; content = '<div>お世話になります。<br>ご確認ください。</div>' }
        hasAttachments = $false
        internetMessageId = '<abc@example.com>'
        webLink = 'https://outlook.office.com/mail/id/AAMk-1'
    }

    It 'HTML の本文は平文に落とす (そのまま出すとカードがタグだらけになる)' {
        $m = ConvertFrom-GraphMessage $msg
        Assert-Match 'お世話になります' $m.body
        Assert-False ($m.body -match '<div>')
    }

    It '差出人は「表示名 <アドレス>」。件のキーがこの形を読む' {
        Assert-Equal '山田 太郎 <taro@example.com>' (ConvertFrom-GraphMessage $msg).from
    }

    It '受信時刻を持つ (取り込み時刻を使うと並びが壊れる)' {
        $m = ConvertFrom-GraphMessage $msg
        Assert-NotNull $m.receivedAt
        Assert-Equal 'CONV-1' $m.conversationId
    }

    It '本文が空なら preview で埋める (空のカードを立てない)' {
        $empty = [pscustomobject]@{
            id = 'x'; subject = 's'; bodyPreview = 'プレビューだけ'
            body = [pscustomobject]@{ contentType = 'text'; content = '' }
        }
        Assert-Equal 'プレビューだけ' (ConvertFrom-GraphMessage $empty).body
    }
}

Describe '宛先の組み立て' {

    It '「表示名 <アドレス>」からアドレスだけを取る' {
        $r = @(New-GraphRecipientList '山田 太郎 <taro@example.com>')
        Assert-Equal 1 $r.Count
        Assert-Equal 'taro@example.com' $r[0].emailAddress.address
    }

    It 'カンマとセミコロンで複数に分ける。空は落とす' {
        $r = @(New-GraphRecipientList 'a@example.com; b@example.com,')
        Assert-Equal 2 $r.Count
        Assert-Equal 'b@example.com' $r[1].emailAddress.address
    }
}

Describe 'Teams のメッセージ' {

    It '本文は平文にし、添付は名前を残す (実体が添付にしか無いことがある)' {
        $m = [pscustomobject]@{
            body = [pscustomobject]@{ contentType = 'html'; content = '<p>明日の資料です</p>' }
            attachments = @([pscustomobject]@{ name = '議事録.docx'; contentType = 'reference' })
        }
        $t = Get-TeamsMessageText -Message $m
        Assert-Match '明日の資料です' $t
        Assert-Match '議事録.docx' $t
    }

    It '送信者は人でもアプリでも名前が取れる' {
        Assert-Equal '鈴木 花子' (Get-TeamsMessageSender -Message ([pscustomobject]@{
            from = [pscustomobject]@{ user = [pscustomobject]@{ displayName = '鈴木 花子' } } }))
        Assert-Equal 'Approvals' (Get-TeamsMessageSender -Message ([pscustomobject]@{
            from = [pscustomobject]@{ application = [pscustomobject]@{ displayName = 'Approvals' } } }))
        Assert-Equal '(不明)' (Get-TeamsMessageSender -Message ([pscustomobject]@{ from = $null }))
    }
}

Describe 'チャットの表示名' {

    $script:FakeSecrets['ms.selfUserId'] = 'me-1'
    $script:GraphSelfId = 'me-1'

    It 'topic があればそれを使う' {
        Assert-Equal '案件A' (Get-TeamsChatName -Chat ([pscustomobject]@{ topic = '案件A' }))
    }

    It '1:1 は相手の名前 (自分は外す)' {
        $chat = [pscustomobject]@{ topic = ''; members = @(
            [pscustomobject]@{ userId = 'me-1'; displayName = '自分' },
            [pscustomobject]@{ userId = 'u-2'; displayName = '鈴木 花子' }) }
        Assert-Equal '鈴木 花子' (Get-TeamsChatName -Chat $chat)
    }

    It '大人数は「ほか N 名」に畳む (カードの見出しが崩れないように)' {
        $chat = [pscustomobject]@{ topic = ''; members = @(
            [pscustomobject]@{ userId = 'me-1'; displayName = '自分' },
            [pscustomobject]@{ userId = 'u-2'; displayName = 'A' },
            [pscustomobject]@{ userId = 'u-3'; displayName = 'B' },
            [pscustomobject]@{ userId = 'u-4'; displayName = 'C' },
            [pscustomobject]@{ userId = 'u-5'; displayName = 'D' },
            [pscustomobject]@{ userId = 'u-6'; displayName = 'E' }) }
        Assert-Equal 'A, B, C ほか 2 名' (Get-TeamsChatName -Chat $chat)
    }
}

Describe 'アクセストークン' {

    It '未設定なら叩きに行かず、設定の仕方を返す' {
        $script:FakeSecrets = @{}
        Clear-GraphAccessToken
        Assert-False (Test-GraphConfigured)
        Assert-Throws { Get-GraphAccessToken }
    }

    It '期限内で同じリフレッシュトークンなら取り直さない' {
        $script:FakeSecrets = @{ 'ms.clientId' = 'cid'; 'ms.tenantId' = 'organizations'; 'ms.refreshToken' = 'rt-1' }
        $script:FakeRotatedRefresh = ''
        Clear-GraphAccessToken
        $script:FakeTokenCalls = 0
        Assert-Equal 'at-for-rt-1' (Get-GraphAccessToken)
        Assert-Equal 'at-for-rt-1' (Get-GraphAccessToken)
        Assert-Equal 1 $script:FakeTokenCalls
    }

    It '入れ替わったリフレッシュトークンを保存し直す (Microsoft は毎回入れ替える)' {
        # 保存を怠ると、しばらく動いたあとある日 invalid_grant になる。
        # そのとき原因は設定時から遠く離れていて、まず辿り着けない。
        $script:FakeSecrets = @{ 'ms.clientId' = 'cid'; 'ms.refreshToken' = 'rt-1' }
        $script:FakeRotatedRefresh = 'rt-2'
        Clear-GraphAccessToken
        [void] (Get-GraphAccessToken)
        Assert-Equal 'rt-2' $script:FakeSecrets['ms.refreshToken']
    }

    It '入れ替えた直後もキャッシュが効く (毎回取り直さない)' {
        $script:FakeTokenCalls = 0
        [void] (Get-GraphAccessToken)
        Assert-Equal 0 $script:FakeTokenCalls
    }

    It '別プロセスが繋ぎ直したら、期限を待たずに取り直す' {
        # 繋ぎ直すのはカンバン。ワーカーと収集は別プロセスで動いている。
        # 期限だけで判断していると、最大1時間「設定したのに直らない」が続く。
        $script:FakeRotatedRefresh = ''
        $script:FakeSecrets['ms.refreshToken'] = 'rt-new'
        $script:FakeTokenCalls = 0
        Assert-Equal 'at-for-rt-new' (Get-GraphAccessToken)
        Assert-Equal 1 $script:FakeTokenCalls
    }

    It '失敗の理由を名指しする (AADSTS の番号のままでは直せない)' {
        $script:FakeTokenError = '{"error":"invalid_client","error_description":"AADSTS7000218: The request body must contain client_assertion or client_secret"}'
        Clear-GraphAccessToken
        $msg = ''
        try { [void] (Get-GraphAccessToken) } catch { $msg = $_.Exception.Message }
        Assert-Match 'パブリック クライアント フロー' $msg
        $script:FakeTokenError = ''
    }

    It '付与されたスコープを見て、叩く前に諦められる' {
        $script:FakeSecrets = @{ 'ms.clientId' = 'cid'; 'ms.refreshToken' = 'rt-1' }
        Clear-GraphAccessToken
        Assert-True (Test-GraphScope 'Chat.Read')
        $script:FakeGrantedScope = 'openid offline_access User.Read Mail.ReadWrite'
        Clear-GraphAccessToken
        Assert-False (Test-GraphScope 'Chat.Read')
        $script:FakeGrantedScope = 'openid profile offline_access User.Read Mail.ReadWrite Mail.Send Chat.Read ChatMessage.Send'
    }
}

Describe 'デバイスコード' {

    It 'コードを出す。ここではまだ何も保存しない' {
        $script:FakeSecrets = @{}
        $r = Start-GraphDeviceCode -ClientId 'cid' -TenantId ''
        Assert-True $r.ok
        Assert-Equal 'ABCD-EFGH' $r.userCode
        Assert-Equal 'https://microsoft.com/devicelogin' $r.verificationUri
        Assert-Null $script:FakeSecrets['ms.clientId']
    }

    It 'サインイン前は pending。エラーにしない (画面が聞きに来る前提)' {
        $script:FakeDeviceState = 'pending'
        Assert-Equal 'pending' (Test-GraphDeviceCode).state
    }

    It 'サインインが済んだら資格情報を保存する' {
        $script:FakeDeviceState = 'ok'
        $r = Test-GraphDeviceCode
        Assert-Equal 'ok' $r.state
        Assert-Equal 'cid' $script:FakeSecrets['ms.clientId']
        Assert-Equal 'rt-1' $script:FakeSecrets['ms.refreshToken']
        # テナントを空欄で出したら organizations (職場・学校アカウント)
        Assert-Equal 'organizations' $script:FakeSecrets['ms.tenantId']
    }

    It '拒否されたら理由を返し、途中経過を捨てる' {
        $script:FakeSecrets = @{}
        [void] (Start-GraphDeviceCode -ClientId 'cid2' -TenantId '')
        $script:FakeDeviceState = 'declined'
        $r = Test-GraphDeviceCode
        Assert-Equal 'error' $r.state
        Assert-Match '拒否' $r.error
        Assert-Null $script:FakeSecrets['ms.refreshToken']
        # 捨てたあとにもう一度聞かれても、途中経過が無いことを返す
        Assert-Equal 'error' (Test-GraphDeviceCode).state
        $script:FakeDeviceState = 'pending'
    }

    It 'シークレットを渡したら、引き換えにも更新にも付けて送る (機密クライアントの登録)' {
        $script:FakeSecrets = @{}
        [void] (Start-GraphDeviceCode -ClientId 'cid' -TenantId '' -ClientSecret 's3cret')
        $script:FakeDeviceState = 'ok'
        Assert-Equal 'ok' (Test-GraphDeviceCode).state
        Assert-Equal 's3cret' ([string] $script:LastTokenBody['client_secret'])
        Assert-Equal 's3cret' $script:FakeSecrets['ms.clientSecret']

        Clear-GraphAccessToken
        [void] (Get-GraphAccessToken)
        Assert-Equal 'refresh_token' ([string] $script:LastTokenBody['grant_type'])
        Assert-Equal 's3cret' ([string] $script:LastTokenBody['client_secret'])
        $script:FakeDeviceState = 'pending'
    }

    It 'シークレット無しで繋ぎ直したら、前のシークレットを消して送らない' {
        # 残すと、別のアプリ登録にシークレットを送り続けて invalid_client で止まる
        [void] (Start-GraphDeviceCode -ClientId 'public-cid' -TenantId '')
        $script:FakeDeviceState = 'ok'
        Assert-Equal 'ok' (Test-GraphDeviceCode).state
        Assert-False $script:LastTokenBody.ContainsKey('client_secret')
        Assert-Null $script:FakeSecrets['ms.clientSecret']

        Clear-GraphAccessToken
        [void] (Get-GraphAccessToken)
        Assert-False $script:LastTokenBody.ContainsKey('client_secret')
        $script:FakeDeviceState = 'pending'
    }
}

# ---------------------------------------------------------------- 掃き寄せ
#
# ここは Invoke-GraphApi を差し替えて、応答の形だけを与える。
# 見たいのは「何を拾い、何を捨て、失敗をどう扱うか」で、HTTP の往復ではない。

Describe 'Teams の掃き寄せ' {

    $script:FakeSecrets = @{ 'ms.clientId' = 'cid'; 'ms.refreshToken' = 'rt-1'; 'ms.selfUserId' = 'me-1' }
    $script:GraphSelfId = 'me-1'
    $script:FakeGraphPaths = @()
    $script:FakeChatErrors = @{}

    function Invoke-GraphApi {
        param([string] $Path, [string] $Method = 'Get', $Body, [string] $Prefer, [switch] $Raw)
        $script:FakeGraphPaths += $Path
        if ($Path -like '/me/chats?*') {
            return [pscustomobject]@{ value = @(
                [pscustomobject]@{ id = '19:new@thread.v2'; topic = '案件A'; lastUpdatedDateTime = '2026-09-13T09:00:00Z'
                                   members = @([pscustomobject]@{ userId = 'u-2'; displayName = '鈴木 花子' }) },
                [pscustomobject]@{ id = '19:old@thread.v2'; topic = '去年の件'; lastUpdatedDateTime = '2026-09-01T00:00:00Z'
                                   members = @() },
                [pscustomobject]@{ id = '19:denied@thread.v2'; topic = '読めない'; lastUpdatedDateTime = '2026-09-13T09:30:00Z'
                                   members = @() }
            ) }
        }
        if ($Path -like '/chats/19%3Adenied*') {
            throw $script:FakeChatErrors['denied']
        }
        if ($Path -like '/chats/*') {
            return [pscustomobject]@{ value = @(
                # 自分の発言は拾わない
                [pscustomobject]@{ id = 'm1'; messageType = 'message'; createdDateTime = '2026-09-13T09:10:00Z'
                                   from = [pscustomobject]@{ user = [pscustomobject]@{ id = 'me-1'; displayName = '自分' } }
                                   body = [pscustomobject]@{ contentType = 'html'; content = '<p>こちらの発言</p>' } },
                # 参加・退出などのシステムメッセージは会話ではない
                [pscustomobject]@{ id = 'm2'; messageType = 'systemEventMessage'; createdDateTime = '2026-09-13T09:11:00Z'
                                   from = $null; body = [pscustomobject]@{ contentType = 'html'; content = '' } },
                # 削除済みは本文が空で返る
                [pscustomobject]@{ id = 'm3'; messageType = 'message'; createdDateTime = '2026-09-13T09:12:00Z'
                                   deletedDateTime = '2026-09-13T09:13:00Z'
                                   from = [pscustomobject]@{ user = [pscustomobject]@{ id = 'u-2'; displayName = '鈴木 花子' } }
                                   body = [pscustomobject]@{ contentType = 'html'; content = '' } },
                # これが拾われる。しかも自分宛のメンション
                [pscustomobject]@{ id = 'm4'; messageType = 'message'; createdDateTime = '2026-09-13T09:20:00Z'
                                   webUrl = 'https://teams.microsoft.com/l/message/19%3Anew/1757'
                                   from = [pscustomobject]@{ user = [pscustomobject]@{ id = 'u-2'; displayName = '鈴木 花子' } }
                                   mentions = @([pscustomobject]@{ mentioned = [pscustomobject]@{ user = [pscustomobject]@{ id = 'me-1' } } })
                                   body = [pscustomobject]@{ contentType = 'html'; content = '<p>ご確認ください</p>' } }
            ) }
        }
        throw ("想定外の呼び出し: " + $Path)
    }

    It '自分の発言・システムメッセージ・削除済みは拾わない' {
        $script:FakeChatErrors['denied'] = '... (HTTP 403)'
        $script:FakeGraphPaths = @()
        $sweep = Get-TeamsUpdates -Since ([DateTime] '2026-09-13T08:00:00Z')
        Assert-Equal 1 @($sweep.messages).Count
        Assert-Equal 'm4' $sweep.messages[0].messageId
        Assert-Equal 'mention' $sweep.messages[0].reason
        Assert-Equal '案件A' $sweep.messages[0].chatName
    }

    It 'watermark より古いチャットは開かない (会話の数だけ叩かない)' {
        $opened = @($script:FakeGraphPaths | Where-Object { $_ -like '/chats/*' })
        Assert-Equal 2 $opened.Count   # new と denied のみ。old は開かない
    }

    It '読めない会話が1つあっても、他の会話は拾う' {
        $sweep = Get-TeamsUpdates -Since ([DateTime] '2026-09-13T08:00:00Z')
        Assert-Equal 1 @($sweep.messages).Count
        Assert-Equal 1 @($sweep.errors).Count
        Assert-Equal '読めない' $sweep.errors[0].chat
    }

    It '権限不足は恒久的な失敗として扱う (watermark を止めない)' {
        $script:FakeChatErrors['denied'] = '... (HTTP 403)'
        $sweep = Get-TeamsUpdates -Since ([DateTime] '2026-09-13T08:00:00Z')
        Assert-True $sweep.errors[0].permanent
    }

    It 'レート制限は据え置きの理由にする (進めると取りこぼす)' {
        $script:FakeChatErrors['denied'] = '... (HTTP 429)'
        $sweep = Get-TeamsUpdates -Since ([DateTime] '2026-09-13T08:00:00Z')
        Assert-False $sweep.errors[0].permanent
    }

    Remove-Item -Path Function:\Invoke-GraphApi -ErrorAction SilentlyContinue
}

Describe 'Outlook の取り込み' {

    $script:FakeSecrets = @{ 'ms.clientId' = 'cid'; 'ms.refreshToken' = 'rt-1' }
    $script:FakeMailPages = 0

    function New-FakeMail {
        param([string] $Id, [string] $When)
        return [pscustomobject]@{
            id = $Id; conversationId = ('c-' + $Id); subject = ('件名 ' + $Id)
            from = [pscustomobject]@{ emailAddress = [pscustomobject]@{ name = '山田'; address = 'taro@example.com' } }
            toRecipients = @(); ccRecipients = @()
            receivedDateTime = $When; bodyPreview = 'p'
            body = [pscustomobject]@{ contentType = 'text'; content = '本文' }
            hasAttachments = $false; internetMessageId = ('<' + $Id + '>')
            webLink = ('https://outlook.office.com/mail/id/' + $Id)
        }
    }

    function Invoke-GraphApi {
        param([string] $Path, [string] $Method = 'Get', $Body, [string] $Prefer, [switch] $Raw)
        $script:FakeMailPages++
        if ($Path -like 'https://graph.microsoft.com/next*') {
            return [pscustomobject]@{ value = @((New-FakeMail 'm1' '2026-09-13T01:00:00Z')) }
        }
        return [pscustomobject]@{
            value = @((New-FakeMail 'm3' '2026-09-13T03:00:00Z'), (New-FakeMail 'm2' '2026-09-13T02:00:00Z'))
            '@odata.nextLink' = 'https://graph.microsoft.com/next'
        }
    }

    It '次のページを辿る (1ページで打ち切ると静かに取りこぼす)' {
        $script:FakeMailPages = 0
        $msgs = @(Get-OutlookRecent -Since ([DateTime] '2026-09-13T00:00:00Z'))
        Assert-Equal 3 $msgs.Count
        Assert-Equal 2 $script:FakeMailPages
    }

    It '古い順に返す (カードは届いた順に並ぶほうが読みやすい)' {
        $msgs = @(Get-OutlookRecent -Since ([DateTime] '2026-09-13T00:00:00Z'))
        Assert-Equal 'm1' $msgs[0].id
        Assert-Equal 'm3' $msgs[2].id
    }

    It '上限で切る (暴走の安全弁。呼び出し側は watermark を進めない)' {
        Assert-Equal 2 @(Get-OutlookRecent -Since ([DateTime] '2026-09-13T00:00:00Z') -Max 2).Count
    }

    Remove-Item -Path Function:\Invoke-GraphApi -ErrorAction SilentlyContinue
}

Describe 'ツールの出し分け (Microsoft)' {

    It '未設定なら Outlook のツールを見せない (無い手段で計画を立てさせない)' {
        $script:FakeSecrets = @{}
        $names = @(Get-WorkTools | ForEach-Object { $_.name })
        Assert-False ($names -contains 'create_outlook_draft')
        Assert-False ($names -contains 'send_outlook_mail')
        Assert-False ($names -contains 'send_teams_message')
    }

    It '設定済みなら下書きと送信が出る' {
        $script:FakeSecrets = @{ 'ms.clientId' = 'cid'; 'ms.refreshToken' = 'rt-1' }
        $names = @(Get-WorkTools | ForEach-Object { $_.name })
        Assert-True ($names -contains 'create_outlook_draft')
        Assert-True ($names -contains 'send_outlook_mail')
    }

    It 'Teams の投稿は投稿先があるカードにだけ出す' {
        $script:FakeSecrets = @{ 'ms.clientId' = 'cid'; 'ms.refreshToken' = 'rt-1' }
        Assert-False (@(Get-WorkTools | ForEach-Object { $_.name }) -contains 'send_teams_message')
        Assert-True  (@(Get-WorkTools -HasTeamsTarget | ForEach-Object { $_.name }) -contains 'send_teams_message')
    }
}

Describe '承認の要否 (Microsoft)' {

    It 'Teams の投稿は承認が要り、束縛された投稿先が画面に出る' {
        $r = Get-ToolRisk -Name 'send_teams_message' -Workspace '.' `
                -ToolInput ([pscustomobject]@{ text = '承知しました' }) `
                -TeamsChatName '鈴木 花子'
        Assert-True $r.risky
        Assert-Match '鈴木 花子' $r.detail
        Assert-Match '承知しました' $r.detail
    }

    It 'Outlook の送信は宛先と本文が全文出る' {
        $r = Get-ToolRisk -Name 'send_outlook_mail' -Workspace '.' `
                -ToolInput ([pscustomobject]@{ to = 'taro@example.com'; subject = '見積の件'; body = '添付します' }) `
                -OutlookThreadLabel '元のスレッドへの返信として送信'
        Assert-True $r.risky
        Assert-Match 'taro@example.com' $r.detail
        Assert-Match '元のスレッドへの返信' $r.detail
    }

    It 'Outlook の下書きも承認が要る (利用者のメールボックスに物が残る)' {
        Assert-True (Get-ToolRisk -Name 'create_outlook_draft' -Workspace '.' `
            -ToolInput ([pscustomobject]@{ subject = 'x'; body = 'y' })).risky
    }

    It '送信と投稿は取り消せない扱い (修正ラウンドで二度送らない)' {
        Assert-True (Test-IrreversibleTool -Name 'send_outlook_mail')
        Assert-True (Test-IrreversibleTool -Name 'send_teams_message')
        Assert-False (Test-IrreversibleTool -Name 'create_outlook_draft')
    }
}

Describe '投稿先の束縛' {

    It '投稿先の無いカードでは Teams に投稿できない' {
        $r = Invoke-WorkTool -Name 'send_teams_message' -Workspace '.' `
                -ToolInput ([pscustomobject]@{ text = 'x' })
        Assert-True $r.isError
        Assert-Match '投稿先' $r.text
    }
}

}
finally {
    # 差し替えを戻す。後続のケースが本物の Get-Secret / Invoke-RestMethod を使えるように。
    Remove-Item -Path Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Invoke-GraphApi -ErrorAction SilentlyContinue
    . "$RepoRoot\phase5\lib\GraphConnector.ps1"
    $script:FakeTokenError = ''
    $script:FakeDeviceState = 'pending'
    $script:GraphSelfId = $null
    . "$RepoRoot\phase5\lib\SecretStore.ps1"
    Clear-GraphAccessToken
    $script:GraphGrantedScopes = @()
}
