# AppConfig.ps1
# 配布設定 (config\app-config.json) の読み込み。
#
# なぜ要るか:
#   このアプリが要求する資格情報のうち、いくつかは**利用者の手では取れない**。
#   Google の OAuth クライアントは Google Cloud でプロジェクトを作ってAPIを有効化して
#   初めて出てくるし、Slack のトークンはアプリを作ってワークスペースに導入する権限が要る。
#   Anthropic の API キーも同じで、課金の紐づいた組織のコンソールに入れる人しか作れない。
#
#   つまりこれらは「配る側が一度だけ用意するもの」であって、
#   配られた側の画面に空欄として出しても、そこは永久に埋まらない。
#
#   そこで、配る人が用意した値をフォルダに同梱できるようにする。
#   同梱されていれば、利用者は**画面のボタンを押すだけ**で接続が終わる。
#   同梱されていなければ従来どおり画面から入力する (自分で取れる人はそれでよい)。
#
# 扱わないもの:
#   このファイルは平文の JSON である。暗号化された保管庫 (SecretStore) の代わりでは
#   なく、その入口でしかない。Import-AppConfigSecrets が起動時に DPAPI の保管庫へ
#   取り込むので、**取り込んだあとは配布設定から資格情報を消してよい。**
#
# 何から守れないか (ここを誤解すると配り方を間違える):
#   - **同じ Windows ユーザーで動くプロセスからは守れない。** 平文 JSON も DPAPI の
#     保管庫も、そのユーザーとして動くものには等しく読める。DPAPI の境界は
#     「ユーザーとマシン」であって「アプリケーション」ではない。
#   - **渡した相手からは守れない。** 同梱したキーは、受け取った人が読んで
#     他のアプリに貼れる。ここに書いてよいのは「その人達と共有してよいキー」だけで、
#     嫌なら空のまま配り、各自に画面から入れてもらう。
#   守れるのは、別アカウント・別 PC への持ち出しと、置き場所の事故だけ。

$script:AppConfigCache     = $null
$script:AppConfigCacheTime = [DateTime]::MinValue
$script:AppConfigCachePath = $null
$script:AppConfigWarned    = $false

function Get-AppConfigPath {
    <#
      .SYNOPSIS
        配布設定のパス。環境変数で差し替えられる (テストと、複数構成を切り替えたいとき用)。
    #>
    if ($env:NOTIFICATION_COLLECTOR_CONFIG) { return $env:NOTIFICATION_COLLECTOR_CONFIG }
    $root = Split-Path -Parent $PSScriptRoot
    return (Join-Path $root 'config\app-config.json')
}

function Get-AppConfig {
    <#
      .SYNOPSIS
        配布設定を読む。無ければ空を返す (配布設定は任意であって、必須ではない)。
      .DESCRIPTION
        壊れていても例外にしない。起動そのものを止めてしまうと、
        「画面から入力すれば動く」状態にすら辿り着けなくなる。
        代わりに一度だけ警告を出して、空として扱う。
    #>
    $p = Get-AppConfigPath
    if (-not (Test-Path $p)) { return [pscustomobject]@{} }

    $stamp = (Get-Item -LiteralPath $p).LastWriteTimeUtc
    if ($script:AppConfigCache -and $script:AppConfigCachePath -eq $p -and $script:AppConfigCacheTime -eq $stamp) {
        return $script:AppConfigCache
    }
    try {
        $obj = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $obj) { $obj = [pscustomobject]@{} }
        $script:AppConfigCache     = $obj
        $script:AppConfigCacheTime = $stamp
        $script:AppConfigCachePath = $p
        $script:AppConfigWarned    = $false
        return $obj
    }
    catch {
        if (-not $script:AppConfigWarned) {
            Write-Host ("配布設定を読めませんでした (無視して続けます): {0}" -f $p) -ForegroundColor Yellow
            Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
            $script:AppConfigWarned = $true
        }
        return [pscustomobject]@{}
    }
}

function Get-AppConfigValue {
    <#
      .SYNOPSIS
        'anthropic.apiKey' のようなドット区切りで1件取り出す。無ければ $null。
    #>
    param([Parameter(Mandatory)] [string] $Path)
    $cur = Get-AppConfig
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $cur) { return $null }
        $prop = $cur.PSObject.Properties[$seg]
        if (-not $prop) { return $null }
        $cur = $prop.Value
    }
    if ($null -eq $cur) { return $null }
    if ($cur -is [string]) {
        $t = $cur.Trim()
        # 見本ファイルをそのまま配ると空欄が残る。空欄は「無い」と同じ扱いにする。
        if (-not $t) { return $null }
        return $t
    }
    return $cur
}

function Get-AppConfigInt {
    param([Parameter(Mandatory)] [string] $Path, [int] $Default = 0)
    $v = Get-AppConfigValue -Path $Path
    if ($null -eq $v) { return $Default }
    $n = 0
    if ([int]::TryParse([string] $v, [ref] $n)) { return $n }
    return $Default
}

function Get-AppConfigBool {
    param([Parameter(Mandatory)] [string] $Path, [bool] $Default = $false)
    $v = Get-AppConfigValue -Path $Path
    if ($null -eq $v) { return $Default }
    if ($v -is [bool]) { return [bool] $v }
    switch (([string] $v).ToLowerInvariant()) {
        'true'  { return $true }
        '1'     { return $true }
        'false' { return $false }
        '0'     { return $false }
    }
    return $Default
}

# 配布設定の「資格情報」欄 → 保管庫の名前。
# ここに無いものは取り込まない (設定ファイルの書き間違いで変な名前が保管庫に増えない)。
# slack.redirectUrl はここに入れない。秘密ではないうえ、Slack アプリ側に
# 登録済みの URL と一字一句合っている必要があるので、配布設定だけを見る
# (保管庫に写して古い値が残ると、合わなくなった理由が分からなくなる)。
$script:AppConfigSecretMap = [ordered]@{
    'anthropic.apiKey'    = 'anthropic.apiKey'
    # 組織 ID はここに無い。どの組織かはキーが決めるので、配っても使い道が無い
    # (書いてあっても取り込まない。理由は lib\ApiKey.ps1)。
    'google.clientId'     = 'gmail.clientId'
    'google.clientSecret' = 'gmail.clientSecret'
    'slack.clientId'      = 'slack.clientId'
    'slack.clientSecret'  = 'slack.clientSecret'
    # 貼る方式で配っていた頃の名残。同意画面を通せない事情があるときの逃げ道。
    # Bot トークン (slack.botToken) はここに無い ―― もう読まないので、
    # 書いてあっても取り込まれない。
    'slack.userToken'     = 'slack.userToken'
    'github.token'        = 'github.token'
    # Microsoft 365 のアプリ登録。Google / Slack と同じく、利用者の権限では作れないことが多い。
    # clientSecret は任意 ―― 「パブリック クライアント フローを許可する」を
    # 「はい」にできない (テナントの方針で機密クライアントしか置けない) 登録で使う。
    'microsoft.clientId'     = 'ms.clientId'
    'microsoft.tenantId'     = 'ms.tenantId'
    'microsoft.clientSecret' = 'ms.clientSecret'
}

# 取り込みはするが、秘密ではない識別子。平文で残っていても「消してよい」とは言わない
# (消すと、保管庫の値を失ったときに配布時の値へ戻れなくなるだけで、隠す意味が無い)。
$script:AppConfigNonSecret = @('microsoft.tenantId')

function Import-AppConfigSecrets {
    <#
      .SYNOPSIS
        配布設定に書かれた資格情報を DPAPI の保管庫へ取り込む。起動時に一度呼ぶ。
      .DESCRIPTION
        **すでに保管庫に入っている項目は上書きしない。** 画面から入れ直した値が
        次の起動で配布時の値に戻る、という一番分かりにくい壊れ方を避けるため。
        利用者が自分の値に切り替えたなら、それが最後に勝つ。
      .OUTPUTS
        [string[]] 取り込んだ保管庫上の名前 (値は返さない)
    #>
    param([string] $Path)
    $imported = @()
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) { return $imported }

    foreach ($cfgName in $script:AppConfigSecretMap.Keys) {
        $v = Get-AppConfigValue -Path $cfgName
        if (-not $v -or -not ($v -is [string])) { continue }
        $secretName = $script:AppConfigSecretMap[$cfgName]
        try {
            if (Get-Secret -Name $secretName -Path $Path) { continue }
            Set-Secret -Name $secretName -Value ([string] $v) -Path $Path
            $imported += $secretName
        }
        catch {
            # 保管庫が読めない (別PC・別ユーザーで作られた) 場合。
            # ここで止めると起動できなくなるので、呼び出し側に任せる。
            break
        }
    }
    return $imported
}

function Test-AppConfigHasPlainSecrets {
    <#
      .SYNOPSIS
        配布設定に平文の資格情報がまだ残っているか。
      .DESCRIPTION
        取り込みが済んだあとも、このファイルには平文のキーが残り続ける。
        フォルダごとコピーされれば一緒に運ばれ、バックアップにも同期フォルダにも残る。
        「もう消してよい」ことは言わないと伝わらないので、起動時に一度出す。
    #>
    foreach ($cfgName in $script:AppConfigSecretMap.Keys) {
        if ($script:AppConfigNonSecret -contains $cfgName) { continue }
        if (Get-AppConfigValue -Path $cfgName) { return $true }
    }
    return $false
}

function Protect-AppConfigFile {
    <#
      .SYNOPSIS
        配布設定を、このユーザーだけが読める状態にする。
      .DESCRIPTION
        平文で置く以上、せめて他のアカウントからは見えないようにする。
        暗号化の代わりにはならない (同じユーザーのプロセスには読める)。
    #>
    $p = Get-AppConfigPath
    if (-not (Test-Path $p)) { return $false }
    if (-not (Get-Command Set-PrivateFileAcl -ErrorAction SilentlyContinue)) { return $false }
    return (Set-PrivateFileAcl -Path $p)
}
