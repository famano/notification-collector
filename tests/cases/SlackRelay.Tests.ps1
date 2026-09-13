# SlackRelay.Tests.ps1
# Slack の同意画面から戻ってくるための中継ページ。
#
# なぜ固定するか:
#   このページだけは**公開の場所に置かれる**。配布物の中で唯一、
#   誰でも URL を叩ける。持たせてよいものと、決してやってはいけないことが
#   はっきりしているので、そこを試験で留める。
#
#   - 認可コードはここを通るが、引き換えには client secret が要り、それは手元にしかない
#   - 転送先は 127.0.0.1 に固定する。クエリで受け取った URL へ飛ばしてはいけない
#     (公開ページが任意の宛先への踏み台になる)
#   - 外部リソースを読まない。コードの載った URL をリファラで第三者に渡さない

. "$RepoRoot\phase5\lib\ServiceSetup.ps1"

# ServiceSetup を読むと本物の SecretStore も一緒に入る。実データの secrets.dat を
# 触らないよう、保存先は読み込んだ直後に一時ファイルへ寄せる
# (このケース自体は保管庫を読まないが、後続のケースまで巻き込まないため)。
$script:RelayTestStore = Join-Path (New-TestTempDir) 'secrets.dat'
function Get-SecretStorePath { param([string] $Path) if ($Path) { return $Path } return $script:RelayTestStore }

$script:RelayPath = Join-Path $RepoRoot 'docs\slack-oauth-redirect.html'

Describe 'Slack の中継ページ' {

    It 'ある' {
        Assert-True (Test-Path -LiteralPath $script:RelayPath) '中継ページがありません'
    }

    $html = if (Test-Path -LiteralPath $script:RelayPath) { [IO.File]::ReadAllText($script:RelayPath) } else { '' }

    It '転送先は 127.0.0.1 に固定されている' {
        Assert-Match "http://127\.0\.0\.1:' \+ port" $html
    }

    It 'クエリから受け取った URL へは飛ばさない' {
        # location.replace に渡すのは、自分で組み立てた target だけ。
        $calls = @([regex]::Matches($html, 'location\.replace\(([^)]*)\)') | ForEach-Object { $_.Groups[1].Value.Trim() })
        Assert-Equal 1 $calls.Count '転送が複数あります'
        Assert-Equal 'target' $calls[0] 'organize されていない値を転送先にしています'
        Assert-True ($html -notmatch 'location\.href\s*=') '別の経路で遷移しています'
    }

    It 'ポートは state から取り、範囲を確かめてから使う' {
        Assert-Match '\^\(\[0-9\]\{1,5\}\)\\\.' $html
        Assert-Match 'port >= 1 && port <= 65535' $html
    }

    It '外部リソースを読まない (コードの載った URL を第三者に渡さない)' {
        Assert-True ($html -notmatch '<script[^>]+src=') '外部スクリプトを読んでいます'
        Assert-True ($html -notmatch '<link[^>]+href=') '外部スタイルを読んでいます'
        Assert-True ($html -notmatch '<img') '画像を読んでいます'
        Assert-Match 'name="referrer" content="no-referrer"' $html
    }

    It '秘密も交換も持たない (引き換えは手元でしか行わない)' {
        Assert-True ($html -notmatch 'client_secret') 'シークレットに触れています'
        Assert-True ($html -notmatch 'oauth\.v2\.access') 'ページ上でトークンを引き換えようとしています'
        Assert-True ($html -notmatch 'localStorage|sessionStorage|document\.cookie') '何かを保存しています'
        Assert-True ($html -notmatch 'fetch\(|XMLHttpRequest') '外に送信しています'
    }
}

Describe '中継ページと設定の対応' {

    It '配布設定の見本に戻り先の欄がある (配る人が最初に詰まる所)' {
        $sample = [IO.File]::ReadAllText((Join-Path $RepoRoot 'config\app-config.sample.json'))
        Assert-Match '"redirectUrl"' $sample
        Assert-Match '"clientId"' $sample
    }

    It 'Slack は画面から同意画面に行ける形になっている' {
        $svc = Get-SetupService 'slack'
        Assert-Equal 'oauth' $svc.flow
        # 貼る欄ではなく、アプリの ID と秘密を受ける形
        Assert-Equal @('clientId', 'clientSecret') @($svc.fields | ForEach-Object { $_.name })
    }
}
