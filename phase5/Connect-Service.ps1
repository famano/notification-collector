<#
.SYNOPSIS
    Phase 5: 外部サービスの資格情報を設定する。対話的に一度だけ実行する。

.DESCRIPTION
    入力した値は DPAPI (CurrentUser) で暗号化して phase5/data/secrets.dat に保存する。
    平文では残らず、別ユーザー・別PCでは復号できない。

.EXAMPLE
    .\Connect-Service.ps1 -Service slack
    .\Connect-Service.ps1 -Service gmail
    .\Connect-Service.ps1 -Status
#>
[CmdletBinding()]
param(
    [ValidateSet('slack', 'gmail')] [string] $Service,
    [switch] $Status,
    [switch] $Test
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\SecretStore.ps1"
. "$PSScriptRoot\lib\SlackConnector.ps1"
. "$PSScriptRoot\lib\GmailConnector.ps1"

function Show-Status {
    Write-Host ''
    Write-Host '設定状況' -ForegroundColor Cyan
    Write-Host ("  Slack : {0}" -f $(if (Test-SlackConfigured) { '設定済み' } else { '未設定' }))
    Write-Host ("  Gmail : {0}" -f $(if (Test-GmailConfigured) { '設定済み' } else { '未設定' }))
    $names = @(Get-SecretNames)
    if ($names.Count -gt 0) {
        Write-Host ''
        Write-Host '  保存されている項目 (値は表示しません):' -ForegroundColor DarkGray
        foreach ($n in $names) { Write-Host "    - $n" -ForegroundColor DarkGray }
    }
    Write-Host ''
}

function Connect-Slack {
    Write-Host ''
    Write-Host 'Slack の設定' -ForegroundColor Cyan
    Write-Host @'
  事前に Slack アプリを作り、Bot Token を取得してください。

  1. https://api.slack.com/apps で「Create New App」→「From scratch」
  2. OAuth & Permissions → Bot Token Scopes に以下を追加
       channels:history  groups:history  im:history  mpim:history
       channels:read     groups:read     im:read     mpim:read
       users:read
       chat:write        ← 投稿する場合のみ。読むだけなら不要
  3. 「Install to Workspace」で導入 (管理者の承認が要る場合があります)
  4. 表示される Bot User OAuth Token (xoxb- で始まる) を控える
  5. 読みたいチャンネルにこのアプリを招待する (/invite @アプリ名)

  注意: Bot は招待されたチャンネルしか読めません。DM を読ませたい場合は
        im:history が必要で、それでも Bot 自身宛の DM に限られます。

  投稿について: chat:write を後から足した場合は、再インストールしてトークンを
        取り直さないと有効になりません (missing_scope で失敗します)。
        投稿はワーカーの送信ツールからのみ行い、実行前にカンバンで承認を求めます。
        投稿名義は自分ではなくこの Bot になります。

'@ -ForegroundColor DarkGray

    $sec = Read-Host '  Bot User OAuth Token (xoxb-...)' -AsSecureString
    $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if (-not $token) { Write-Host '  入力がありません。中止します。' -ForegroundColor Yellow; return }

    Set-Secret -Name 'slack.botToken' -Value $token
    Write-Host '  保存しました。接続を確認します…' -ForegroundColor DarkGray
    try {
        $r = Invoke-SlackApi -Method 'auth.test'
        Write-Host ("  OK: {0} / {1} として接続できました" -f $r.team, $r.user) -ForegroundColor Green
    }
    catch {
        Write-Host ("  接続できませんでした: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Connect-Gmail {
    Write-Host ''
    Write-Host 'Gmail の設定' -ForegroundColor Cyan
    Write-Host @'
  事前に Google Cloud で OAuth クライアントを作ってください。

  1. https://console.cloud.google.com/ でプロジェクトを作る
  2. 「APIとサービス」→「ライブラリ」→ Gmail API を有効化
  3. 「OAuth 同意画面」を設定 (User Type は内部または外部/テスト)
     テストの場合は自分のアドレスをテストユーザーに追加する
  4. 「認証情報」→「OAuth クライアント ID」→ アプリの種類は「デスクトップ アプリ」
  5. クライアント ID とクライアント シークレットを控える

  要求するスコープ:
    gmail.readonly … 本文の取得
    gmail.compose  … 下書きの作成と送信
  注意: Google には「下書きだけ」のスコープがありません。compose は送信も許します。
        送信はワーカーの送信ツールからのみ行い、実行前にカンバンで承認を求めます。
        送らせたくない場合はスコープではなく、承認画面で拒否してください。

'@ -ForegroundColor DarkGray

    $cid = Read-Host '  クライアント ID'
    if (-not $cid) { Write-Host '  入力がありません。中止します。' -ForegroundColor Yellow; return }
    $sec = Read-Host '  クライアント シークレット' -AsSecureString
    $csec = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if (-not $csec) { Write-Host '  入力がありません。中止します。' -ForegroundColor Yellow; return }

    Start-GmailAuth -ClientId $cid -ClientSecret $csec
    try {
        $me = Invoke-GmailApi -Path '/users/me/profile'
        Write-Host ("  OK: {0} ({1} 通) として接続できました" -f $me.emailAddress, $me.messagesTotal) -ForegroundColor Green
    }
    catch {
        Write-Host ("  接続確認に失敗しました: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Test-Connections {
    Write-Host ''
    if (Test-SlackConfigured) {
        try { $r = Invoke-SlackApi -Method 'auth.test'; Write-Host ("Slack OK: {0} / {1}" -f $r.team, $r.user) -ForegroundColor Green }
        catch { Write-Host ("Slack NG: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    } else { Write-Host 'Slack: 未設定' -ForegroundColor DarkGray }

    if (Test-GmailConfigured) {
        try { $m = Invoke-GmailApi -Path '/users/me/profile'; Write-Host ("Gmail OK: {0}" -f $m.emailAddress) -ForegroundColor Green }
        catch { Write-Host ("Gmail NG: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    } else { Write-Host 'Gmail: 未設定' -ForegroundColor DarkGray }
    Write-Host ''
}

if ($Status) { Show-Status; return }
if ($Test)   { Test-Connections; return }

switch ($Service) {
    'slack' { Connect-Slack }
    'gmail' { Connect-Gmail }
    default {
        Show-Status
        Write-Host '使い方:' -ForegroundColor Cyan
        Write-Host '  .\Connect-Service.ps1 -Service slack'
        Write-Host '  .\Connect-Service.ps1 -Service gmail'
        Write-Host '  .\Connect-Service.ps1 -Test     接続確認'
        Write-Host ''
    }
}
