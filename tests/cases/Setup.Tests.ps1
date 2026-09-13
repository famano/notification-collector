# Setup.Tests.ps1
# 資格情報をカンバンから設定する経路。
#
# 見たいのは2つ。
#   1. 値が漏れないこと (画面に返るのは「設定済みか」と「誰として繋がったか」だけ)
#   2. 設定が入ったら、待っていたカードが自動で動き出すこと
#
# 2 が無いと設定カードは半分しか機能しない。止まっている8枚を1枚ずつ手で
# 要対応に戻すのでは、結局8枚ぶんの手数が残る。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase2\lib\Dossier.ps1"
. "$RepoRoot\phase5\lib\ServiceSetup.ps1"
. "$RepoRoot\phase3\lib\SetupFlow.ps1"

# --- 資格情報ストアを一時ファイルに差し替える ---
# 実データの secrets.dat は絶対に触らない。DPAPI も使わない
# (テストの目的は保存経路の筋であって、暗号化そのものではない)。
$script:TestSecretPath = Join-Path (New-TestTempDir) 'secrets.dat'
function Get-SecretStorePath { param([string] $Path) return $script:TestSecretPath }
function Protect-Text   { param([string] $Text)   return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
function Unprotect-Text { param([string] $Base64) return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64)) }

# 疎通確認は外に出るので、テストでは差し替える。
$script:FakeConnection = [pscustomobject]@{ ok = $true; account = 'octocat'; note = '' }
function Test-SetupConnection { param([string] $Key) return $script:FakeConnection }

Describe 'サービスの名寄せ' {

    It 'キーで引ける' {
        Assert-Equal 'github' (Get-SetupService 'github').key
        Assert-Equal 'slack'  (Get-SetupService 'slack').key
        Assert-Equal 'google' (Get-SetupService 'google').key
    }

    It '設定カードの subject_key をそのまま渡しても引ける' {
        Assert-Equal 'github' (Get-SetupService 'setup:github').key
    }

    It 'gmail と書かれても google に寄せる (ホストから決まる名前は google)' {
        Assert-Equal 'google' (Get-SetupService 'gmail').key
    }

    It '知らないサービスは null' {
        Assert-Null (Get-SetupService 'zoom.us')
        Assert-Null (Get-SetupService '')
    }
}

Describe '画面に返す一覧' {

    It '入力欄の定義は返すが、値は返さない' {
        Set-Secret -Name 'github.token' -Value 'ghp_dummy_token_value_1234567890'
        $list = @(Get-SetupStatusList)
        $json = $list | ConvertTo-Json -Depth 6
        Assert-True ($json -notmatch 'ghp_dummy') 'トークンが一覧に含まれています'
        $gh = @($list | Where-Object { $_.key -eq 'github' })[0]
        Assert-True $gh.configured
        Assert-Equal 1 (@($gh.fields)).Count
        Assert-True $gh.fields[0].secret
    }

    It '未設定のサービスは未設定と分かる' {
        $sl = @(Get-SetupStatusList | Where-Object { $_.key -eq 'slack' })[0]
        Assert-False $sl.configured
    }

    It '取り方の案内と入口の URL を持っている (画面から出さずに済ませるため)' {
        foreach ($s in @(Get-SetupStatusList)) {
            Assert-NotNull $s.help  ("{0} に案内がありません" -f $s.key)
            Assert-Match '^https://' $s.docUrl
        }
    }
}

Describe '保存' {
    [void] (Remove-Secret -Name 'github.token')

    It '入力が空なら何もしない (押し間違いで設定を消さない)' {
        $r = Save-SetupCredential -Key 'github' -Values @{ token = '' }
        Assert-False $r.ok
        Assert-Null (Get-Secret -Name 'github.token')
    }

    It '疎通できたら保存し、アカウント名を返す' {
        $script:FakeConnection = [pscustomobject]@{ ok = $true; account = 'octocat'; note = '' }
        $r = Save-SetupCredential -Key 'github' -Values @{ token = 'ghp_good' }
        Assert-True $r.ok
        Assert-Equal 'octocat' $r.account
        Assert-Equal 'ghp_good' (Get-Secret -Name 'github.token')
    }

    It '疎通できなければ元に戻す (貼り間違いを「設定済み」にしない)' {
        $script:FakeConnection = [pscustomobject]@{ ok = $false; error = 'Bad credentials' }
        $r = Save-SetupCredential -Key 'github' -Values @{ token = 'ghp_bad' }
        Assert-False $r.ok
        Assert-Match 'Bad credentials' $r.error
        Assert-Equal 'ghp_good' (Get-Secret -Name 'github.token')
    }

    It 'Slack は Bot と User のどちらかがあればよい' {
        $script:FakeConnection = [pscustomobject]@{ ok = $true; account = 'team / bot'; note = '' }
        $r = Save-SetupCredential -Key 'slack' -Values @{ botToken = ''; userToken = 'xoxp-1' }
        Assert-True $r.ok
        Assert-Equal 'xoxp-1' (Get-Secret -Name 'slack.userToken')
    }

    It 'ブラウザの同意が要るサービスは、貼るだけでは受け付けない' {
        $r = Save-SetupCredential -Key 'google' -Values @{ clientId = 'x'; clientSecret = 'y' }
        Assert-False $r.ok
        Assert-Match '同意' $r.error
    }
}

Describe '同意画面の URL' {

    It '戻り先をカンバン自身にして組み立てる' {
        $r = Get-GoogleAuthRequest -ClientId 'cid.apps.googleusercontent.com' -ClientSecret 'sec' `
                -RedirectUri 'http://127.0.0.1:8787/oauth/google/callback'
        Assert-Match 'accounts\.google\.com' $r.url
        Assert-Match 'redirect_uri=http%3A%2F%2F127\.0\.0\.1%3A8787%2Foauth%2Fgoogle%2Fcallback' $r.url
        Assert-Match 'access_type=offline' $r.url
        Assert-NotNull $r.state
    }

    It 'state が合わなければ引き換えない' {
        [void] (Get-GoogleAuthRequest -ClientId 'cid' -ClientSecret 'sec' -RedirectUri 'http://127.0.0.1:8787/x')
        $r = Complete-GoogleAuth -Code 'abc' -State 'まちがい'
        Assert-False $r.ok
        Assert-Match 'state' $r.error
    }

    It 'コードが無ければ引き換えない' {
        [void] (Get-GoogleAuthRequest -ClientId 'cid' -ClientSecret 'sec' -RedirectUri 'http://127.0.0.1:8787/x')
        $st = $script:PendingGoogleAuth.state
        $r = Complete-GoogleAuth -Code '' -State $st
        Assert-False $r.ok
    }
}

if (-not (Test-SqliteAvailable)) {
    Describe '設定が入ったあとの後始末' { Skip-It 'すべて' 'winsqlite3.dll が使えません' }
    return
}

Describe '設定が入ったあとの後始末' {
    $conn = New-TestStore

    # 権限不足で止まったカードを2枚と、そこから生まれた設定カードを1枚作る
    $setupId = [int] (New-SetupTask -Conn $conn -What 'GitHub トークン' -HowTo '入れてください' -ServiceKey 'github')
    $blocked = @()
    foreach ($t in @('CI の失敗を調べる', '招待を承諾する')) {
        $id = [int] (New-Task -Conn $conn -Title $t -Column 'review')
        [void] (Update-TaskFields -Conn $conn -TaskId $id -Fields @{
            shape = 'blocked'
            human_step = (@{ blocker = 'credential_missing'; step = '設定してください'; setup_task_id = $setupId } | ConvertTo-Json -Compress)
        })
        $blocked += $id
    }
    # 関係ないカードも1枚
    $other = [int] (New-Task -Conn $conn -Title '無関係なカード' -Column 'review')

    It '待っているカードを見つける' {
        $w = @(Get-TasksWaitingForSetup -Conn $conn -Service 'github' -SetupTaskId $setupId)
        Assert-Equal 2 $w.Count
    }

    $result = Invoke-SetupCompletion -Conn $conn -Service 'github' -Account 'octocat'

    It '待っていたカードを要対応に戻す' {
        Assert-Equal 2 $result.resumed
        foreach ($id in $blocked) {
            $t = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($id)))[0]
            Assert-Equal 'todo' $t['board_column']
            Assert-Equal 0 $t['cancel_requested']
            Assert-Null $t['human_step']
        }
    }

    It '戻したカードはワーカーが拾える状態になっている' {
        $t = Get-NextWorkItem -Conn $conn
        Assert-NotNull $t
        Assert-True ($blocked -contains [int] $t['id'])
    }

    It '関係ないカードは動かさない' {
        $t = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($other)))[0]
        Assert-Equal 'review' $t['board_column']
    }

    It '設定カード自体は完了に移る' {
        $t = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($setupId)))[0]
        Assert-Equal 'done' $t['board_column']
        Assert-Match 'octocat' ([string] $t['user_edited'])
        Assert-Match '2 枚' ([string] $t['user_edited'])
    }

    It '台帳の「未設定」を打ち消す (ワーカーに渡り続けるため)' {
        $t = Get-ServiceDossierText -Conn $conn
        Assert-Match 'github' $t
        Assert-Match '設定済み' $t
    }

    It '設定カードが無くても落ちない (カードが立つ前に繋いだ場合)' {
        $r = Invoke-SetupCompletion -Conn $conn -Service 'slack' -Account 'team / bot'
        Assert-Equal 0 $r.resumed
        Assert-Equal 0 $r.setupTaskId
    }

    Close-TestStore $conn
}
