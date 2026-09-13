# ApiKey.ps1
# Claude の API キーをどこから取るか、の一点だけを決める層。
#
# なぜ要るか:
#   これまでキーは環境変数 ANTHROPIC_API_KEY からしか読んでいなかった。
#   開発機ではそれでよいが、配った先では**そこが行き止まりになる。**
#   利用者にとって「環境変数を設定する」は、シェルを開いて呪文を打つ作業か、
#   システムのプロパティを辿る作業でしかなく、しかも設定し忘れると
#   起動そのものが拒否されていた ―― 画面すら出ないので、直し方も画面に出せない。
#
#   そこで取得元を3つにする。上から順に見て、最初に見つかったものを使う。
#
#     1. 環境変数 ANTHROPIC_API_KEY … 開発機。従来どおり最優先
#     2. 資格情報ストア (DPAPI)      … カンバンの「接続」から入れたもの
#     3. 配布設定 (app-config.json)  … 配る人が同梱したもの
#
#   2 があるので、**利用者は画面だけでキーを入れられる。**
#   3 があるので、**配る人が入れておけば利用者は何もしなくてよい。**

. "$PSScriptRoot\AppConfig.ps1"
. "$PSScriptRoot\..\phase5\lib\SecretStore.ps1"

function Get-AnthropicApiKey {
    <#
      .SYNOPSIS
        使える API キーを返す。無ければ $null (例外にはしない)。
    #>
    param([string] $SecretPath)
    if ($env:ANTHROPIC_API_KEY) { return [string] $env:ANTHROPIC_API_KEY }
    try {
        $v = Get-Secret -Name 'anthropic.apiKey' -Path $SecretPath
        if ($v) { return [string] $v }
    }
    catch {
        # 保管庫が読めないだけで、配布設定のキーまで諦める理由はない
    }
    $c = Get-AppConfigValue -Path 'anthropic.apiKey'
    if ($c) { return [string] $c }
    return $null
}

function Get-AnthropicKeySource {
    <#
      .SYNOPSIS
        どこから来たキーかを日本語で返す。設定の食い違いを説明するためだけに使う。
    #>
    param([string] $SecretPath)
    if ($env:ANTHROPIC_API_KEY) { return '環境変数 ANTHROPIC_API_KEY' }
    try { if (Get-Secret -Name 'anthropic.apiKey' -Path $SecretPath) { return 'カンバンの「接続」から設定' } } catch { }
    if (Get-AppConfigValue -Path 'anthropic.apiKey') { return '配布設定 (config\app-config.json)' }
    return ''
}

function Test-AnthropicConfigured {
    param([string] $SecretPath)
    return [bool] (Get-AnthropicApiKey -SecretPath $SecretPath)
}

# 未設定のときに出す文言。端末でも画面でも同じ言い方をする。
# 「環境変数を設定してください」と言い切らないこと ―― 配った先ではそれが最後の壁になる。
function Get-AnthropicMissingMessage {
    return 'Claude の API キーが設定されていません。カンバンのヘッダの「接続」から入力してください。'
}
