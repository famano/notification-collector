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

function Get-AnthropicAdminApiKey {
    <#
      .SYNOPSIS
        組織の管理 API (/v1/organizations/...) 用のキー。無ければ $null。
      .DESCRIPTION
        通常のキー (sk-ant-api...) とは別物で、/v1/organizations/... はこちらでないと通らない。
        どの組織を見るかは**このキー自身が決める** (URL にも本文にも組織 ID は要らない)。
        判定にもワーカーの通常の作業にも要らないので、入っていなくても何も困らない。

        **配布設定 (app-config.json) からは読まない。** これは組織の管理権限そのもので、
        平文で同梱してよい種類のものではない。入れるなら各自が画面から入れる
        (開発機のために環境変数だけは見る)。
    #>
    param([string] $SecretPath)
    if ($env:ANTHROPIC_ADMIN_KEY) { return [string] $env:ANTHROPIC_ADMIN_KEY }
    try {
        $v = Get-Secret -Name 'anthropic.adminApiKey' -Path $SecretPath
        if ($v) { return [string] $v }
    }
    catch { }
    return $null
}

function Test-AnthropicAdminConfigured {
    param([string] $SecretPath)
    return [bool] (Get-AnthropicAdminApiKey -SecretPath $SecretPath)
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

# 組織 ID は持たない。
#
# 以前は「接続の確認でキーの組織と突き合わせる」ために任意項目として入力・保存していたが、
# 公式ドキュメントを当たると、**組織 ID を URL に載せる口は1つも無い。**
#   - 管理 API     … /v1/organizations/users, /v1/organizations/cost_report など
#   - 利用状況     … /v1/organizations/usage_report/messages
#   - Claude Code  … /v1/organizations/usage_report/claude_code
#   - セッション   … /v1/compliance/apps/sessions/local|remote/{session_id}
# どれも「organizations」は固定の語で、**どの組織かはキーが決める。** 組織 ID を
# 入れてもらう理由が残らないので、欄ごと畳んだ。欲しくなったら応答 (x-api-key に
# 紐づく組織) から取れる。
# 未設定のときに出す文言。端末でも画面でも同じ言い方をする。
# 「環境変数を設定してください」と言い切らないこと ―― 配った先ではそれが最後の壁になる。
function Get-AnthropicMissingMessage {
    return 'Claude の API キーが設定されていません。カンバンのヘッダの「接続」から入力してください。'
}
