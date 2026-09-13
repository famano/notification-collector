# AppConfig.Tests.ps1
# 配布設定と、API キーをどこから取るか。
#
# 見たいのは3つ。
#   1. 配布設定が無くても、壊れていても、起動を止めないこと
#      (止めると「画面から入力すれば動く」状態にすら辿り着けない)
#   2. 取得元の優先順位が固定であること
#      環境変数 → 保管庫 (画面から入れたもの) → 配布設定 (配る人が入れたもの)
#   3. 取り込みが既存の値を壊さないこと
#      画面から入れ直した値が、次の起動で配布時の値に戻るのが一番分かりにくい

. "$RepoRoot\lib\ApiKey.ps1"

# --- 保管庫を一時ファイルに差し替える ---
# 実データの secrets.dat には触らない。DPAPI も使わない (見たいのは筋であって暗号化ではない)。
$script:CfgTestStore = Join-Path (New-TestTempDir) 'secrets.dat'
function Get-SecretStorePath { param([string] $Path) if ($Path) { return $Path } return $script:CfgTestStore }
function Protect-Text   { param([string] $Text)   return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
function Unprotect-Text { param([string] $Base64) return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64)) }

$script:CfgDir     = New-TestTempDir
$script:SavedKeyEnv = $env:ANTHROPIC_API_KEY
$script:SavedCfgEnv = $env:NOTIFICATION_COLLECTOR_CONFIG
$env:ANTHROPIC_API_KEY = $null

function Set-TestConfig {
    <#  配布設定を1件書いて、そこを見るようにする。#>
    param([string] $Json)
    $p = Join-Path $script:CfgDir ('cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    [IO.File]::WriteAllText($p, $Json, (New-Object Text.UTF8Encoding $false))
    $env:NOTIFICATION_COLLECTOR_CONFIG = $p
    return $p
}

try {

Describe '配布設定の読み込み' {

    It 'ファイルが無ければ空として扱う (起動は止めない)' {
        $env:NOTIFICATION_COLLECTOR_CONFIG = Join-Path $script:CfgDir 'no-such-file.json'
        Assert-Null (Get-AppConfigValue -Path 'anthropic.apiKey')
    }

    It '壊れていても落ちない (警告して空として扱う)' {
        [void] (Set-TestConfig '{ これは JSON ではない')
        Assert-Null (Get-AppConfigValue -Path 'anthropic.apiKey')
    }

    It 'ドット区切りで取り出せる' {
        [void] (Set-TestConfig '{ "google": { "clientId": "cid.apps.googleusercontent.com" } }')
        Assert-Equal 'cid.apps.googleusercontent.com' (Get-AppConfigValue -Path 'google.clientId')
    }

    It '空欄は「無い」と同じ扱い (見本をそのまま配っても未設定になる)' {
        [void] (Set-TestConfig '{ "anthropic": { "apiKey": "   " } }')
        Assert-Null (Get-AppConfigValue -Path 'anthropic.apiKey')
    }

    It '無い枝を辿っても落ちない' {
        [void] (Set-TestConfig '{ "anthropic": { "apiKey": "sk-ant-x" } }')
        Assert-Null (Get-AppConfigValue -Path 'slack.botToken')
        Assert-Null (Get-AppConfigValue -Path 'a.b.c.d')
    }

    It '数と真偽は既定値つきで読める' {
        [void] (Set-TestConfig '{ "startup": { "port": 9100, "openBrowser": false } }')
        Assert-Equal 9100 (Get-AppConfigInt -Path 'startup.port' -Default 8787)
        Assert-False (Get-AppConfigBool -Path 'startup.openBrowser' -Default $true)
        Assert-Equal 8787 (Get-AppConfigInt -Path 'startup.nosuch' -Default 8787)
        Assert-True (Get-AppConfigBool -Path 'startup.nosuch' -Default $true)
    }
}

Describe '配布設定から保管庫への取り込み' {

    It '書かれているものだけ取り込む' {
        $store = Join-Path (New-TestTempDir) 'secrets.dat'
        [void] (Set-TestConfig '{ "anthropic": { "apiKey": "sk-ant-from-config" }, "google": { "clientId": "cid", "clientSecret": "" } }')
        $names = @(Import-AppConfigSecrets -Path $store)
        Assert-True ($names -contains 'anthropic.apiKey')
        Assert-True ($names -contains 'gmail.clientId')
        Assert-False ($names -contains 'gmail.clientSecret') '空欄まで取り込んでいます'
        Assert-Equal 'sk-ant-from-config' (Get-Secret -Name 'anthropic.apiKey' -Path $store)
    }

    It '既にある値は上書きしない (画面から入れ直した値が起動で戻らない)' {
        $store = Join-Path (New-TestTempDir) 'secrets.dat'
        Set-Secret -Name 'anthropic.apiKey' -Value 'sk-ant-from-screen' -Path $store
        [void] (Set-TestConfig '{ "anthropic": { "apiKey": "sk-ant-from-config" } }')
        $names = @(Import-AppConfigSecrets -Path $store)
        Assert-Equal 0 $names.Count
        Assert-Equal 'sk-ant-from-screen' (Get-Secret -Name 'anthropic.apiKey' -Path $store)
    }

    It '知らない項目は取り込まない (書き間違いで保管庫が汚れない)' {
        $store = Join-Path (New-TestTempDir) 'secrets.dat'
        [void] (Set-TestConfig '{ "zoom": { "token": "x" }, "anthropic": { "nope": "y" } }')
        Assert-Equal 0 (@(Import-AppConfigSecrets -Path $store)).Count
        Assert-Equal 0 (@(Get-SecretNames -Path $store)).Count
    }
}

Describe 'API キーの取得元' {

    It '環境変数が最優先 (開発機の従来どおりの動きを変えない)' {
        $store = Join-Path (New-TestTempDir) 'secrets.dat'
        Set-Secret -Name 'anthropic.apiKey' -Value 'sk-ant-store' -Path $store
        [void] (Set-TestConfig '{ "anthropic": { "apiKey": "sk-ant-config" } }')
        $env:ANTHROPIC_API_KEY = 'sk-ant-env'
        try { Assert-Equal 'sk-ant-env' (Get-AnthropicApiKey -SecretPath $store) }
        finally { $env:ANTHROPIC_API_KEY = $null }
    }

    It '環境変数が無ければ、画面から入れた値を使う' {
        $store = Join-Path (New-TestTempDir) 'secrets.dat'
        Set-Secret -Name 'anthropic.apiKey' -Value 'sk-ant-store' -Path $store
        [void] (Set-TestConfig '{ "anthropic": { "apiKey": "sk-ant-config" } }')
        Assert-Equal 'sk-ant-store' (Get-AnthropicApiKey -SecretPath $store)
    }

    It 'どちらも無ければ配布設定を使う (利用者は何も入力しなくてよい)' {
        $store = Join-Path (New-TestTempDir) 'secrets.dat'
        [void] (Set-TestConfig '{ "anthropic": { "apiKey": "sk-ant-config" } }')
        Assert-Equal 'sk-ant-config' (Get-AnthropicApiKey -SecretPath $store)
        Assert-True (Test-AnthropicConfigured -SecretPath $store)
    }

    It 'どこにも無ければ未設定 (例外にはしない)' {
        $store = Join-Path (New-TestTempDir) 'secrets.dat'
        [void] (Set-TestConfig '{ }')
        Assert-Null (Get-AnthropicApiKey -SecretPath $store)
        Assert-False (Test-AnthropicConfigured -SecretPath $store)
    }

    It '未設定の案内は端末ではなく画面を指す (配った先に端末は無い)' {
        Assert-Match '接続' (Get-AnthropicMissingMessage)
        Assert-True ((Get-AnthropicMissingMessage) -notmatch 'ANTHROPIC_API_KEY') `
            '環境変数を設定せよ、という案内が残っています'
    }
}

}
finally {
    # 差し替えを戻す。後続のケースが本物の保管庫を使えるように。
    $env:ANTHROPIC_API_KEY = $script:SavedKeyEnv
    $env:NOTIFICATION_COLLECTOR_CONFIG = $script:SavedCfgEnv
    . "$RepoRoot\phase5\lib\SecretStore.ps1"
}
