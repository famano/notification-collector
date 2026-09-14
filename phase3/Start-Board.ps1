<#
.SYNOPSIS
    Phase 3: カンバンボードのローカル Web サーバ。

.DESCRIPTION
    .NET の HttpListener を使うので追加インストールは不要。管理者権限も要らない
    (localhost へのバインドは URL 予約なしで通ることを確認済み)。

    127.0.0.1 にのみバインドし、Host ヘッダも検証する。ボードには業務上の
    メッセージ内容が載るため、外部に露出させない。

.PARAMETER Port
    待ち受けポート (既定 8787)。

.PARAMETER NoBrowser
    起動時にブラウザを開かない。

.PARAMETER OutputRoot
    ワーカーの作業フォルダの親 (既定 phase4\output)。成果物のあるカードから
    エクスプローラーで開くために要る。

.EXAMPLE
    .\Start-Board.ps1
#>
[CmdletBinding()]
param(
    [int]    $Port = 8787,
    [string] $DbPath,
    # トリアージ方針。既定は phase2\config\policy.json (Invoke-Triage と同じもの)。
    [string] $PolicyPath,
    [string] $OutputRoot,
    [switch] $NoBrowser
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\phase2\lib\TaskStore.ps1"
# 要求を通すかどうかの判定 (Host / Origin)。壊れても画面には何も出ない場所なので、
# ボードを起動せずに確かめられる形にしてある。
. "$PSScriptRoot\lib\RequestGuard.ps1"
# トリアージ方針。カンバンから直せるようにする (気付いた場所で直せないと直されない)。
. "$PSScriptRoot\..\phase2\lib\Policy.ps1"
$script:PolicyPath = $PolicyPath

# 送信経路。カンバンだけで仕事を終わらせるには、最後の一手 (送る) もここに要る。
# Phase 5 が無い・未設定でもボード自体は動くように、読み込みは任意扱いにする。
$script:Connectors = $false
try {
    . "$PSScriptRoot\..\phase5\lib\SlackConnector.ps1"
    . "$PSScriptRoot\..\phase5\lib\GmailConnector.ps1"
    . "$PSScriptRoot\..\phase5\lib\GraphConnector.ps1"
    . "$PSScriptRoot\..\phase5\lib\ChatworkConnector.ps1"
    . "$PSScriptRoot\..\phase5\lib\BacklogConnector.ps1"
    # 資格情報の設定をカンバンから行うための層。設定カードの出口はここ。
    . "$PSScriptRoot\..\phase5\lib\ServiceSetup.ps1"
    . "$PSScriptRoot\lib\SetupFlow.ps1"
    . "$PSScriptRoot\..\phase2\lib\Dossier.ps1"
    $script:Connectors = $true
}
catch {
    Write-Host ("外部サービス連携を読み込めませんでした (送信は使えません): {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
}

$WebRoot = Join-Path $PSScriptRoot 'wwwroot'

# ワーカーの作業フォルダ。成果物を直すときはファイルを1つずつ覗くより
# フォルダごと開くほうが早い (phase4\Start-Worker.ps1 の -OutputRoot と同じ既定)。
if (-not $OutputRoot) { $OutputRoot = Join-Path $PSScriptRoot '..\phase4\output' }
$script:OutputRoot = [IO.Path]::GetFullPath($OutputRoot)

$Columns = @(
    @{ key = 'inbox';     label = '未分類' },
    @{ key = 'todo';      label = '要対応' },
    @{ key = 'doing';     label = '実行中' },
    @{ key = 'review';    label = 'レビュー待ち' },
    @{ key = 'done';      label = '完了' },
    @{ key = 'dismissed'; label = '対応不要' }
)
$ColumnKeys = $Columns | ForEach-Object { $_.key }

# ---------------------------------------------------------------- helpers

function ConvertTo-PlainObject {
    # WinSqlite が返す Dictionary を ConvertTo-Json が素直に扱える形に直す
    param($Row)
    if ($null -eq $Row) { return $null }
    $o = [ordered]@{}
    foreach ($k in $Row.Keys) { $o[$k] = $Row[$k] }
    return [pscustomobject] $o
}

function Write-JsonResponse {
    param($Context, $Object, [int] $StatusCode = 200)
    $json  = $Object | ConvertTo-Json -Depth 10
    if ($null -eq $json) { $json = 'null' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode  = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    # ローカル専用。キャッシュされると更新が見えなくなる。
    $Context.Response.Headers.Add('Cache-Control', 'no-store')
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-JsonBody {
    param($Context)
    $reader = New-Object IO.StreamReader($Context.Request.InputStream, [Text.Encoding]::UTF8)
    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if (-not $raw) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

function Write-StaticFile {
    param($Context, [string] $RelPath)
    if (-not $RelPath -or $RelPath -eq '/') { $RelPath = 'index.html' }
    $RelPath = $RelPath.TrimStart('/')

    $full = [IO.Path]::GetFullPath((Join-Path $WebRoot $RelPath))
    # ディレクトリトラバーサル防止。
    # 単なる前方一致だと wwwroot の隣にある wwwroot2 のようなフォルダが通ってしまう。
    # いまは隣に何も無いので実害は無いが、置いた瞬間に穴になる種類の判定なので、
    # 区切り文字まで見る。
    $webRootFull = [IO.Path]::GetFullPath($WebRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $full.StartsWith($webRootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        $Context.Response.StatusCode = 403; return
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $Context.Response.StatusCode = 404; return
    }

    $type = switch ([IO.Path]::GetExtension($full).ToLower()) {
        '.html' { 'text/html; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        default { 'application/octet-stream' }
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    $Context.Response.ContentType = $type
    $Context.Response.Headers.Add('Cache-Control', 'no-store')
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

# 同意画面から戻ってきたブラウザに見せる1枚。
# ここに来るのは「別タブ」なので、結果はこの場で読み切れる形にする。
# タブを閉じたあとカンバンに戻ると、設定カードは既に完了に移っている。
function Write-OAuthResultPage {
    param($Context, $Result, [int] $Resumed = 0)

    # error には Google が返した文字列がそのまま入る。第三者の文字列を
    # HTML に差し込む形になるので、必ず逃がしてから出す。
    $esc = {
        param([string] $t)
        if (-not $t) { return '' }
        return ($t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
    }

    if ($Result.ok) {
        $body = "<h1>接続できました</h1><p>{0} として接続しました。</p>" -f (& $esc ([string] $Result.account))
        if ($Result.note) { $body += "<p class='note'>{0}</p>" -f (& $esc ([string] $Result.note)) }
        if ($Resumed -gt 0) {
            $body += "<p>設定を待って止まっていたカード {0} 枚を「要対応」に戻しました。</p>" -f $Resumed
        }
        $body += "<p class='note'>このタブは閉じてかまいません。カンバンに戻ってください。</p>"
    }
    else {
        $body = "<h1>接続できませんでした</h1><p>{0}</p>" -f (& $esc ([string] $Result.error))
        $body += "<p class='note'>カンバンの「接続」からやり直せます。</p>"
    }

    $html = @"
<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>接続の結果</title>
<style>
  body { font: 14px/1.7 "Segoe UI","Yu Gothic UI",system-ui,sans-serif; margin: 48px auto; max-width: 34em;
         color: #14181d; background: #f4f6f8; padding: 0 16px; }
  h1 { font-size: 18px; }
  .note { color: #6b7480; font-size: 13px; }
  @media (prefers-color-scheme: dark) { body { color: #e8eaed; background: #121519; } .note { color: #9aa3ad; } }
</style></head><body>$body</body></html>
"@
    $bytes = [Text.Encoding]::UTF8.GetBytes($html)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = 'text/html; charset=utf-8'
    $Context.Response.Headers.Add('Cache-Control', 'no-store')
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Get-ArtifactCounts {
    param($Conn)
    $map = @{}
    foreach ($r in $Conn.Query('SELECT task_id, COUNT(*) AS n FROM task_artifacts GROUP BY task_id')) {
        $map[[string] $r['task_id']] = [int] $r['n']
    }
    return $map
}

# ---------------------------------------------------------------- 元のメッセージへのリンク
#
# カードから元の会話へ 1 クリックで戻れるようにする。踏ませる以上、
# スキームは許可制にする。link は通知の launch 属性、つまり第三者が
# 決めた文字列なので、javascript: や data: をそのまま href に入れると
# 通知の送り主がボード上でスクリプトを実行できてしまう。
# 表示するラベルとリンク先の文字列は分けて持ち、ラベルは常に自前で決める
# (「ここをクリック」の中身が別の URL、という細工を成立させないため)。
$script:OpenableSchemes = @('https', 'http', 'mailto', 'slack', 'msteams')

function Get-SafeOpenLink {
    param([string] $Url)
    if (-not $Url) { return $null }
    $u = $Url.Trim()
    # 制御文字・空白が混ざったものは弾く。改行を挟んでスキーム判定を
    # すり抜ける細工があるため、判定前ではなく判定と同時に落とす。
    if ($u -match '[\x00-\x1f\x7f\s]') { return $null }
    $i = $u.IndexOf(':')
    if ($i -le 0) { return $null }
    if ($script:OpenableSchemes -notcontains $u.Substring(0, $i).ToLowerInvariant()) { return $null }
    return $u
}

function Get-OpenLinkLabel {
    param([string] $Url, [string] $App)
    if ($Url -match '^https?://[^/]*slack\.com/' -or $Url -match '^slack:') { return 'Slack で開く' }
    if ($Url -match '^https?://mail\.google\.com/')                          { return 'Gmail で開く' }
    if ($Url -match '^https?://outlook\.(office|office365|live)\.com/')      { return 'Outlook で開く' }
    if ($Url -match '^https?://teams\.microsoft\.com/')                      { return 'Teams で開く' }
    if ($Url -match '^https?://(www\.)?chatwork\.com/')                      { return 'Chatwork で開く' }
    if ($Url -match '^https?://[^/]+\.(backlog\.(jp|com)|backlogtool\.com)/') { return 'Backlog で開く' }
    if ($Url -match '^msteams:')                                             { return 'Teams で開く' }
    if ($Url -match '^mailto:')                                              { return 'メールを書く' }
    if ($App) { return "$App で開く" }
    return '元のメッセージを開く'
}

# タスク id → リンク。カード一覧は tasks しか読まないので、ここで一括して引く。
function Get-EventLinkMap {
    param($Conn)
    $map = @{}
    foreach ($r in $Conn.Query(
        'SELECT t.id AS task_id, e.app, e.link, e.permalink
           FROM tasks t JOIN events e ON e.id = t.event_id')) {
        # permalink (正規 API で取り直した https) を優先し、無ければ通知のリンク
        $url = Get-SafeOpenLink ([string] $r['permalink'])
        if (-not $url) { $url = Get-SafeOpenLink ([string] $r['link']) }
        if ($url) {
            $map[[string] $r['task_id']] = [pscustomobject]@{
                url = $url; label = (Get-OpenLinkLabel $url ([string] $r['app']))
            }
        }
    }
    return $map
}

# ---------------------------------------------------------------- カードの出口
#
# カードは「何をもって完了とするか」で2種類しかない。
#   送る   … 返信・投稿で終わるもの。宛先がカードの元イベントから束縛できる
#   実施   … 自分が手を動かして終わるもの。送り先が無い (PC の内部通知など)
# どちらも最後に残るのは1つのテキストで、違うのは押すボタンだけ。
#
# 宛先はここで決める。**リクエストからは受け取らない。** 受け取れる作りにすると、
# ボードに流し込まれた第三者の文面から宛先を差し替える道ができてしまう。
function Get-TaskOutlet {
    param($Event)

    $none = [pscustomobject]@{ kind = 'none'; label = ''; to = ''; subject = '' }
    if (-not $Event -or -not $script:Connectors) { return $none }

    if (([string] $Event['source']) -eq 'gmail' -and (Test-GmailConfigured)) {
        $raw = $null
        try { $raw = [string] $Event['raw_json'] | ConvertFrom-Json } catch { }
        if (-not $raw -or -not $raw.from) { return $none }
        $subject = [string] $raw.subject
        if ($subject -notmatch '^\s*Re:') { $subject = "Re: $subject" }
        return [pscustomobject]@{
            kind    = 'gmail'
            label   = ("{0} へメールを返信" -f $raw.from)
            to      = [string] $raw.from
            subject = $subject
        }
    }

    if (([string] $Event['source']) -eq 'outlook' -and (Test-GraphConfigured)) {
        $raw = $null
        try { $raw = [string] $Event['raw_json'] | ConvertFrom-Json } catch { }
        if (-not $raw -or -not $raw.from) { return $none }
        $subject = [string] $raw.subject
        if ($subject -notmatch '^\s*Re:') { $subject = "Re: $subject" }
        return [pscustomobject]@{
            kind    = 'outlook'
            label   = ("{0} へメールを返信" -f $raw.from)
            to      = [string] $raw.from
            subject = $subject
        }
    }

    if (([string] $Event['link']) -like 'slack://*' -and (Test-SlackConfigured)) {
        try {
            $tg = Get-SlackTarget -Link ([string] $Event['link'])
            if ($tg) {
                return [pscustomobject]@{
                    kind    = 'slack'
                    label   = ("{0} のスレッドへ投稿" -f $tg.channelName)
                    to      = $tg.channelName
                    subject = ''
                }
            }
        }
        catch { }   # 投稿先を引けないだけ。カードは「実施」として扱えばよい
    }

    if (([string] $Event['source']) -eq 'chatwork' -and (Test-ChatworkConfigured)) {
        try {
            $tg = Get-ChatworkTarget -Link ([string] $Event['link'])
            if ($tg) {
                return [pscustomobject]@{
                    kind    = 'chatwork'
                    label   = ("{0} へ投稿" -f $tg.roomName)
                    to      = $tg.roomName
                    subject = ''
                }
            }
        }
        catch { }
    }

    if (([string] $Event['source']) -eq 'backlog' -and (Test-BacklogConfigured)) {
        $key = ''
        try { $key = [string] ([string] $Event['raw_json'] | ConvertFrom-Json).issueKey } catch { }
        if (-not $key) {
            $ref = ConvertFrom-BacklogLink ([string] $Event['link'])
            if ($ref) { $key = $ref.issueKey }
        }
        if ($key) {
            return [pscustomobject]@{
                kind    = 'backlog'
                label   = ("課題 {0} へコメント" -f $key)
                to      = $key
                subject = ''
            }
        }
    }

    if (([string] $Event['link']) -like 'msteams://*' -and (Test-GraphConfigured)) {
        try {
            $tg = Get-TeamsTarget -Link ([string] $Event['link'])
            if ($tg) {
                return [pscustomobject]@{
                    kind    = 'teams'
                    label   = ("{0} のチャットへ投稿" -f $tg.chatName)
                    to      = $tg.chatName
                    subject = ''
                }
            }
        }
        catch { }
    }
    return $none
}

# ---------------------------------------------------------------- 返信先の内容
#
# 送る前にいちばん要るのは「相手が何と言ってきたか」である。トーンは文脈でしか
# 決まらないので、これが読めないと文面に自信が持てず、結局は元のメールを開き直す
# ことになる ―― カンバンだけで終わらせるという前提がそこで崩れる。
#
# events.body は経路ごとに決まった形で積んである (Phase 5)。
#   Gmail … 「差出人:／宛先:／Cc:／日時:」の見出しに続けて本文
#   Slack … 通知本文のあとに「--- スレッド全文 (N 件) ---」、
#           各発言が「--- 誰 / いつ」で始まる
# 画面で文字列を切り分けると、形を知っている場所が2つに増える。ここで割ってから渡す。
function Get-EventConversation {
    param($Event)
    if (-not $Event) { return @() }
    $body = [string] $Event['body']
    if (-not $body -or -not $body.Trim()) { return @() }

    $lines = $body -split "`r?`n"
    $i = 0
    $head = @{}
    while ($i -lt $lines.Count -and $lines[$i] -match '^(差出人|宛先|Cc|日時)\s*[:：]\s*(.*)$') {
        $head[$Matches[1]] = $Matches[2].Trim()
        $i++
    }
    while ($i -lt $lines.Count -and -not $lines[$i].Trim()) { $i++ }

    $msgs = [System.Collections.ArrayList]::new()
    $cur  = @{ from = ''; at = ''; text = [Text.StringBuilder]::new() }
    if ($head.Count -gt 0) {
        if ($head.ContainsKey('差出人')) { $cur.from = $head['差出人'] }
        if ($head.ContainsKey('日時'))   { $cur.at   = $head['日時'] }
    }
    else {
        $cur.from = [string] $Event['title']
        $cur.at   = [string] $Event['occurred_at']
    }

    for (; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        # 「--- スレッド全文 (3 件) ---」のような区切りは見出しであって発言ではない
        if ($ln -match '^\s*---\s*スレッド全文') { continue }
        if ($ln -match '^\s*---\s+(.+?)\s+/\s+(.+?)\s*$') {
            if ($cur.text.ToString().Trim()) { [void] $msgs.Add($cur) }
            $cur = @{ from = $Matches[1].Trim(); at = $Matches[2].Trim(); text = [Text.StringBuilder]::new() }
            continue
        }
        [void] $cur.text.AppendLine($ln)
    }
    if ($cur.text.ToString().Trim()) { [void] $msgs.Add($cur) }

    $out = @()
    $first = $true
    foreach ($m in $msgs) {
        $o = [ordered]@{ from = $m.from; at = $m.at; text = $m.text.ToString().Trim() }
        # 宛先と Cc は最初の1通にだけ添える (返信の宛名を決めるのに要る)
        if ($first) {
            if ($head.ContainsKey('宛先')) { $o['to'] = $head['宛先'] }
            if ($head.ContainsKey('Cc'))   { $o['cc'] = $head['Cc'] }
            $first = $false
        }
        $out += [pscustomobject] $o
    }
    return @($out)
}

# ---------------------------------------------------------------- 作業フォルダ
#
# 成果物が要るカードは、中身を眺めて終わりではなくファイルを触ることになる。
# 1つずつ「中身を見る」で開くのでは足りないので、フォルダごと開けるようにする。
#
# パスは DB の記録か OutputRoot からのみ組み立てる。クライアントから受けた
# パスは一切使わない (成果物の中身を返す口と同じ扱い)。
function Get-TaskWorkspaceDir {
    param($Conn, [int] $TaskId)
    foreach ($r in @(Get-TaskArtifacts -Conn $Conn -TaskId $TaskId)) {
        $p = [string] $r['path']
        if (-not $p) { continue }
        $dir = Split-Path -Parent $p
        if ($dir -and (Test-Path -LiteralPath $dir)) { return (Resolve-Path -LiteralPath $dir).Path }
    }
    # 成果物がまだ無くても、ワーカーが作ったフォルダがあれば開ける
    $guess = Join-Path $script:OutputRoot ("task-{0:D4}" -f $TaskId)
    if (Test-Path -LiteralPath $guess) { return (Resolve-Path -LiteralPath $guess).Path }
    return $null
}

function ConvertTo-CardObject {
    param($Row, $Counts, $Links)
    $o = ConvertTo-PlainObject $Row
    $n = 0
    $key = [string] $Row['id']
    if ($Counts.ContainsKey($key)) { $n = $Counts[$key] }
    Add-Member -InputObject $o -NotePropertyName 'artifact_count' -NotePropertyValue $n -Force
    $link = $null
    if ($Links -and $Links.ContainsKey($key)) { $link = $Links[$key] }
    Add-Member -InputObject $o -NotePropertyName 'open_link' -NotePropertyValue $link -Force

    Add-HumanStepObject -Row $Row -Object $o
    # カンバンで設定できる設定カードか。カード側の文言を「開けば設定できる」に
    # 差し替えるために使う (端末に戻る指示を表に出さない)。
    Add-Member -InputObject $o -NotePropertyName 'setup_ready' `
        -NotePropertyValue ([bool] (Get-CardSetupService $Row)) -Force
    return $o
}

# 「あなたにしかできない1手」は画面で組み立てるのでオブジェクトにして渡す。
# 文字列のまま渡すと、クライアント側で JSON を二重に解く羽目になる。
#
# 一覧と詳細の両方で必要。カードに赤枠が出ているのに開くと消えるのでは、
# 見落としたのかと思わせてしまう。片方だけに足すと必ずそうなるので、
# 変換はここに1つだけ置いて両方から呼ぶ。
function Add-HumanStepObject {
    param($Row, $Object)
    $hs = $null
    if ($Row -and $Row['human_step']) {
        try { $hs = [string] $Row['human_step'] | ConvertFrom-Json } catch { $hs = $null }
    }
    Add-Member -InputObject $Object -NotePropertyName 'human_step_obj' -NotePropertyValue $hs -Force
}

# このカードが「設定カード」なら、そのサービスの入力欄一式を返す。
#
# カードの出口は画面の上にある、という原則をここにも通す。設定カードの出口は
# 「端末でコマンドを打つ」ではなく「この欄に貼って押す」であるべきで、
# そのためには画面がどの欄を出せばよいかを知っている必要がある。
function Get-CardSetupService {
    # $Conn は「未接続を知らせるか」の判定用。一覧で有無だけ見るときは要らない。
    param($Row, $Conn)
    if (-not $script:Connectors -or -not $Row) { return $null }
    $key = [string] $Row['subject_key']
    if (-not $key -or -not $key.StartsWith('setup:')) { return $null }
    $svc = Get-SetupService $key
    if (-not $svc) { return $null }
    return @(Get-SetupStatusList -Conn $Conn | Where-Object { $_.key -eq $svc.key })[0]
}

function Get-BoardPayload {
    param($Conn, [switch] $Archived)

    $counts = Get-ArtifactCounts $Conn
    $links  = Get-EventLinkMap $Conn

    if ($Archived) {
        $rows = @(Get-Tasks -Conn $Conn -IncludeArchived | Where-Object { $_['archived_at'] })
        return [pscustomobject]@{
            rev     = (Get-BoardRevision -Conn $Conn)
            columns = @([pscustomobject]@{
                key   = 'archived'; label = 'アーカイブ済み'
                tasks = @($rows | ForEach-Object { ConvertTo-CardObject $_ $counts $links })
            })
            worker  = (Get-WorkerPayload $Conn)
            collector = (Get-CollectorPayload $Conn)
        }
    }

    $all = @(Get-Tasks -Conn $Conn)
    $cols = foreach ($c in $Columns) {
        $items = @($all | Where-Object { $_['board_column'] -eq $c.key } | ForEach-Object { ConvertTo-CardObject $_ $counts $links })
        [pscustomobject]@{ key = $c.key; label = $c.label; tasks = $items }
    }
    return [pscustomobject]@{
        rev     = (Get-BoardRevision -Conn $Conn)
        columns = @($cols)
        worker  = (Get-WorkerPayload $Conn)
        collector = (Get-CollectorPayload $Conn)
    }
}

# 収集の死活。ワーカーが動いていてもここが止まっていればカードは1枚も増えず、
# 画面上は「要対応が無い」と見分けが付かない。だから別に出す。
function Get-CollectorPayload {
    param($Conn)
    $hb = Get-Setting -Conn $Conn -Key 'collector.heartbeat'
    if (-not $hb) {
        return [pscustomobject]@{ state = 'never'; message = '収集は一度も起動していません'; staleSeconds = $null }
    }
    $age = $null
    try { $age = [int] ((Get-Date) - [DateTime] $hb).TotalSeconds } catch { }
    return [pscustomobject]@{
        state        = (Get-Setting -Conn $Conn -Key 'collector.state' -Default 'unknown')
        message      = (Get-Setting -Conn $Conn -Key 'collector.message')
        staleSeconds = $age
    }
}

function Get-WorkerPayload {
    param($Conn)
    $w = Get-WorkerState -Conn $Conn
    if (-not $w) {
        return [pscustomobject]@{ state = 'unknown'; message = 'ワーカーは一度も起動していません'; currentTaskId = $null; staleSeconds = $null }
    }
    $age = $null
    try { $age = [int] ((Get-Date) - [DateTime] $w['updated_at']).TotalSeconds } catch { }
    return [pscustomobject]@{
        state         = $w['state']
        message       = $w['message']
        currentTaskId = $w['current_task_id']
        staleSeconds  = $age
    }
}

# ---------------------------------------------------------------- routing

function Invoke-Route {
    param($Context, $Conn)

    $req    = $Context.Request
    $path   = $req.Url.AbsolutePath
    $method = $req.HttpMethod

    # ---------------------------------------------------------------- 外部サービスの設定
    #
    # 設定カードの出口。トークンを貼る / 同意画面を通る、のどちらもここで完結する。
    # 値は返さない。返すのは「設定済みか」と「どのアカウントとして繋がったか」だけ。

    if ($path -eq '/api/setup' -and $method -eq 'GET') {
        if (-not $script:Connectors) {
            Write-JsonResponse $Context ([pscustomobject]@{ available = $false; services = @() })
            return
        }
        Write-JsonResponse $Context ([pscustomobject]@{
            available = $true
            # Conn を渡すと、通知の有無と「使う / 警告しない」の選択まで見て warn を決める。
            services  = @(Get-SetupStatusList -Conn $Conn)
        })
        return
    }

    # 未接続を知らせるかどうかの選択。Claude 以外は「使っていないだけ」がありうるので、
    # 「使う」(未接続なら知らせる) と「警告しない」(あえて繋がない) を利用者が決める。
    # 値は資格情報ではないので保管庫ではなく DB の settings に置く。
    if ($path -match '^/api/setup/([a-z0-9.\-]+)/attention$' -and $method -eq 'POST') {
        if (-not $script:Connectors) { Write-JsonResponse $Context @{ ok = $false; error = '連携を読み込めていません' } 500; return }
        $svc = Get-SetupService $Matches[1]
        if (-not $svc) { Write-JsonResponse $Context @{ ok = $false; error = '知らないサービスです' } 400; return }

        $b = Read-JsonBody $Context
        $wanted = $null
        $muted = $null
        if ($b -and $b.PSObject.Properties['wanted'] -and $null -ne $b.wanted) { $wanted = [bool] $b.wanted }
        if ($b -and $b.PSObject.Properties['muted'] -and $null -ne $b.muted) { $muted = [bool] $b.muted }
        if ($null -eq $wanted -and $null -eq $muted) {
            Write-JsonResponse $Context @{ ok = $false; error = 'wanted か muted を指定してください' } 400
            return
        }
        try { Set-SetupAttention -Conn $Conn -Key $svc.key -Wanted $wanted -Muted $muted }
        catch { Write-JsonResponse $Context @{ ok = $false; error = $_.Exception.Message } 400; return }

        Write-JsonResponse $Context ([pscustomobject]@{
            ok = $true
            service = @(Get-SetupStatusList -Conn $Conn | Where-Object { $_.key -eq $svc.key })[0]
        })
        return
    }

    # 貼るだけのサービス (GitHub / Slack)。保存して疎通を確認し、
    # 止まっていたカードを要対応に戻すところまでを1回で行う。
    if ($path -match '^/api/setup/([a-z0-9.\-]+)$' -and $method -eq 'POST') {
        if (-not $script:Connectors) { Write-JsonResponse $Context @{ ok = $false; error = '連携を読み込めていません' } 500; return }
        $svcKey = $Matches[1]
        $svc = Get-SetupService $svcKey
        if (-not $svc) { Write-JsonResponse $Context @{ ok = $false; error = '知らないサービスです' } 400; return }

        $b = Read-JsonBody $Context
        $values = @{}
        if ($b -and $b.values) {
            foreach ($f in $svc.fields) { $values[$f.name] = [string] $b.values.($f.name) }
        }

        $r = Save-SetupCredential -Key $svc.key -Values $values
        if (-not $r.ok) { Write-JsonResponse $Context @{ ok = $false; error = $r.error } 400; return }

        $done = Invoke-SetupCompletion -Conn $Conn -Service $svc.key -Account $r.account
        Write-JsonResponse $Context ([pscustomobject]@{
            ok = $true; account = $r.account; note = $r.note
            resumed = $done.resumed; setupTaskId = $done.setupTaskId
        })
        return
    }

    # Google だけはブラウザの同意が要る。ここでは URL を組み立てて返すだけで、
    # 待たない。カンバンは1本のループで要求を捌いているので、ここで
    # 同意を待つと画面ごと固まる。戻り先を下の /oauth/google/callback にして、
    # ただの1リクエストとして流す。
    if ($path -eq '/api/setup/google/authorize' -and $method -eq 'POST') {
        if (-not $script:Connectors) { Write-JsonResponse $Context @{ ok = $false; error = '連携を読み込めていません' } 500; return }
        $b = Read-JsonBody $Context
        # 入力が空でも、配る人が用意したクライアントがあればそれで進む。
        # 「Google Cloud でプロジェクトを作ってください」は、配った先では行き止まりになる。
        $given = Get-GoogleClientCredential -ClientId $(if ($b) { [string] $b.clientId } else { '' }) `
                                            -ClientSecret $(if ($b) { [string] $b.clientSecret } else { '' })
        $cid = [string] $given.clientId
        $sec = [string] $given.clientSecret
        if (-not $cid.Trim() -or -not $sec.Trim()) {
            Write-JsonResponse $Context @{ ok = $false; error = 'クライアント ID とシークレットを入力してください' } 400
            return
        }
        # 戻り先は「いま開いているカンバン」。127.0.0.1 で組み立てる
        # (Google のデスクトップ クライアントはループバックを任意のポートで許す)。
        $redirect = "http://127.0.0.1:$script:BoardPort/oauth/google/callback"
        $req = Get-GoogleAuthRequest -ClientId $cid -ClientSecret $sec -RedirectUri $redirect
        Write-JsonResponse $Context ([pscustomobject]@{ ok = $true; url = $req.url; redirectUri = $redirect })
        return
    }

    # Slack も同意が要るが、Google と違って**戻り先に HTTPS を要求する。**
    # 127.0.0.1 を直接登録できないので、戻り先は転送しかしない中継ページにして、
    # そこから下の /oauth/slack/callback に戻してもらう。
    # ポート番号は中継ページが知らないので state に埋めて渡す。
    if ($path -eq '/api/setup/slack/authorize' -and $method -eq 'POST') {
        if (-not $script:Connectors) { Write-JsonResponse $Context @{ ok = $false; error = '連携を読み込めていません' } 500; return }
        $b = Read-JsonBody $Context
        $given = Get-SlackClientCredential -ClientId $(if ($b) { [string] $b.clientId } else { '' }) `
                                           -ClientSecret $(if ($b) { [string] $b.clientSecret } else { '' })
        if (-not ([string] $given.clientId).Trim() -or -not ([string] $given.clientSecret).Trim()) {
            Write-JsonResponse $Context @{ ok = $false; error = 'クライアント ID とシークレットを入力してください' } 400
            return
        }
        if (-not ([string] $given.redirectUri).Trim()) {
            # ここが無いと同意画面まで行けない。配る人の作業なので、そう言う。
            Write-JsonResponse $Context @{
                ok = $false
                error = '中継ページの URL が設定されていません (config\app-config.json の slack.redirectUrl)。配布元に確認してください。'
            } 400
            return
        }
        try {
            $r = Get-SlackAuthRequest -ClientId $given.clientId -ClientSecret $given.clientSecret `
                    -RedirectUri $given.redirectUri -BoardPort $script:BoardPort
        }
        catch {
            Write-JsonResponse $Context @{ ok = $false; error = $_.Exception.Message } 400
            return
        }
        Write-JsonResponse $Context ([pscustomobject]@{ ok = $true; url = $r.url; redirectUri = $r.redirectUri })
        return
    }

    if ($path -eq '/oauth/slack/callback' -and $method -eq 'GET') {
        $q = @{}
        foreach ($pair in (([string] $req.Url.Query).TrimStart('?') -split '&')) {
            $kv = $pair -split '=', 2
            if ($kv.Count -eq 2) { $q[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) }
        }
        $result = if (-not $script:Connectors) {
            [pscustomobject]@{ ok = $false; error = '連携を読み込めていません' }
        } else {
            Complete-SlackAuth -Code $q['code'] -State $q['state'] -OAuthError $q['error']
        }

        $resumed = 0
        if ($result.ok) {
            $done = Invoke-SetupCompletion -Conn $Conn -Service 'slack' -Account $result.account
            $resumed = $done.resumed
        }
        Write-OAuthResultPage -Context $Context -Result $result -Resumed $resumed
        return
    }

    # 同意画面からの戻り。ブラウザが直接来るので HTML を返す。
    if ($path -eq '/oauth/google/callback' -and $method -eq 'GET') {
        $q = @{}
        foreach ($pair in (([string] $req.Url.Query).TrimStart('?') -split '&')) {
            $kv = $pair -split '=', 2
            if ($kv.Count -eq 2) { $q[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) }
        }
        $result = if (-not $script:Connectors) {
            [pscustomobject]@{ ok = $false; error = '連携を読み込めていません' }
        } elseif ($q['error']) {
            [pscustomobject]@{ ok = $false; error = ("Google 側で中断されました: {0}" -f $q['error']) }
        } else {
            Complete-GoogleAuth -Code $q['code'] -State $q['state']
        }

        $resumed = 0
        if ($result.ok) {
            $done = Invoke-SetupCompletion -Conn $Conn -Service 'google' -Account $result.account
            $resumed = $done.resumed
        }
        Write-OAuthResultPage -Context $Context -Result $result -Resumed $resumed
        return
    }

    # デバイスコードで繋ぐサービス (Microsoft)。
    #
    # Google のようにリダイレクトで戻ってこない代わりに、画面にコードを出して
    # 「済んだか」を聞きに来てもらう。**サーバ側では待たない** ―― カンバンは
    # 1本のループで要求を捌いているので、ここで同意を待つと画面ごと固まる。
    if ($path -match '^/api/setup/([a-z0-9.\-]+)/devicecode$' -and $method -eq 'POST') {
        if (-not $script:Connectors) { Write-JsonResponse $Context @{ ok = $false; error = '連携を読み込めていません' } 500; return }
        $svc = Get-SetupService $Matches[1]
        if (-not $svc) { Write-JsonResponse $Context @{ ok = $false; error = '知らないサービスです' } 400; return }

        $b = Read-JsonBody $Context
        $values = @{}
        if ($b -and $b.values) {
            foreach ($f in $svc.fields) { $values[$f.name] = [string] $b.values.($f.name) }
        }
        $r = Start-SetupDeviceCode -Key $svc.key -Values $values
        if (-not $r.ok) { Write-JsonResponse $Context @{ ok = $false; error = $r.error } 400; return }
        Write-JsonResponse $Context ([pscustomobject]@{
            ok = $true; userCode = $r.userCode; verificationUri = $r.verificationUri
            interval = $r.interval; expiresInSec = $r.expiresInSec
        })
        return
    }

    # 同意が済んだかを1回だけ見る。画面がこれを数秒おきに叩く。
    if ($path -match '^/api/setup/([a-z0-9.\-]+)/poll$' -and $method -eq 'POST') {
        if (-not $script:Connectors) { Write-JsonResponse $Context @{ ok = $false; error = '連携を読み込めていません' } 500; return }
        $svc = Get-SetupService $Matches[1]
        if (-not $svc) { Write-JsonResponse $Context @{ ok = $false; error = '知らないサービスです' } 400; return }

        $r = Test-SetupDeviceCode -Key $svc.key
        if ($r.state -eq 'pending') { Write-JsonResponse $Context ([pscustomobject]@{ ok = $true; state = 'pending' }); return }
        if ($r.state -ne 'ok') {
            Write-JsonResponse $Context ([pscustomobject]@{ ok = $false; state = 'error'; error = $r.error }) 400
            return
        }
        # 入ったら、止まっていたカードをここで動かす (貼るだけのサービスと同じ後始末)。
        $done = Invoke-SetupCompletion -Conn $Conn -Service $svc.key -Account $r.account
        Write-JsonResponse $Context ([pscustomobject]@{
            ok = $true; state = 'ok'; account = $r.account; note = $r.note
            resumed = $done.resumed; setupTaskId = $done.setupTaskId
        })
        return
    }

    # 承認待ち一覧と、いま効いている「まとめて許可」
    if ($path -eq '/api/approvals' -and $method -eq 'GET') {
        Write-JsonResponse $Context ([pscustomobject]@{
            pending = @(Get-PendingToolRequests -Conn $Conn | ForEach-Object {
                [pscustomobject]@{
                    id = $_['id']; task_id = $_['task_id']; tool = $_['tool']
                    summary = $_['summary']; detail = $_['detail']; created_at = $_['created_at']
                }
            })
            grants = @(Get-ToolGrants -Conn $Conn | ForEach-Object {
                [pscustomobject]@{ id = $_['id']; scope = $_['scope']; scope_id = $_['scope_id']; tool = $_['tool'] }
            })
            yolo = (Test-YoloMode -Conn $Conn)
        })
        return
    }

    if ($path -match '^/api/approvals/(\d+)/decide$' -and $method -eq 'POST') {
        $reqId = [int] $Matches[1]
        $b = Read-JsonBody $Context
        $decision = if ($b -and $b.decision -eq 'approved') { 'approved' } else { 'denied' }

        $r = Get-ToolRequest -Conn $Conn -RequestId $reqId
        if (-not $r) { Write-JsonResponse $Context @{ error = 'not found' } 404; return }

        # 「まとめて許可」は許可のときだけ作る
        if ($decision -eq 'approved' -and $b -and $b.grant) {
            if ($b.grant -eq 'task')   { Add-ToolGrant -Conn $Conn -Scope 'task' -ScopeId ([int] $r['task_id']) -Tool ([string] $r['tool']) }
            if ($b.grant -eq 'global') { Add-ToolGrant -Conn $Conn -Scope 'global' -ScopeId $null -Tool ([string] $r['tool']) }
        }
        $ok = Set-ToolRequestStatus -Conn $Conn -RequestId $reqId -Status $decision
        if (-not $ok) { Write-JsonResponse $Context @{ ok = $false; error = 'すでに処理済みです' } 409; return }

        $msg = if ($decision -eq 'approved') { '利用者が実行を許可しました' } else { '利用者が実行を拒否しました' }
        Add-TaskActivity -Conn $Conn -TaskId ([int] $r['task_id']) -Kind 'user' -Message $msg
        Write-JsonResponse $Context @{ ok = $true; decision = $decision }
        return
    }

    if ($path -match '^/api/grants/(\d+)$' -and $method -eq 'DELETE') {
        [void] (Remove-ToolGrant -Conn $Conn -GrantId ([int] $Matches[1]))
        Write-JsonResponse $Context @{ ok = $true }
        return
    }

    if ($path -eq '/api/settings/yolo' -and $method -eq 'POST') {
        $b = Read-JsonBody $Context
        $on = if ($b -and $b.on) { '1' } else { '0' }
        Set-Setting -Conn $Conn -Key 'yolo' -Value $on
        Write-JsonResponse $Context @{ ok = $true; yolo = ($on -eq '1') }
        return
    }

    # ---------------------------------------------------------------- トリアージ方針
    #
    # 「この通知は今後要らない」と分かるのはカードを見た瞬間で、
    # そのとき開いているのはカンバンである。直せる場所が別のアプリだと直されない。

    if ($path -eq '/api/policy' -and $method -eq 'GET') {
        try { Write-JsonResponse $Context (Get-PolicyView (Read-Policy -Path $script:PolicyPath)) }
        catch { Write-JsonResponse $Context @{ error = $_.Exception.Message } 500 }
        return
    }

    if ($path -eq '/api/policy/ignore' -and ($method -eq 'POST' -or $method -eq 'DELETE')) {
        $b = Read-JsonBody $Context
        $kind = if ($b -and $b.kind -eq 'title') { 'title' } else { 'appId' }
        $pattern = if ($b) { [string] $b.pattern } else { '' }
        try {
            $policy = Read-Policy -Path $script:PolicyPath
            $r = if ($method -eq 'POST') {
                Add-IgnorePattern -Policy $policy -Kind $kind -Pattern $pattern
            } else {
                Remove-IgnorePattern -Policy $policy -Kind $kind -Pattern $pattern
            }
            if (-not $r.ok) { Write-JsonResponse $Context @{ ok = $false; error = $r.error } 400; return }
            Save-Policy -Policy $policy -Path $script:PolicyPath
            Write-JsonResponse $Context ([pscustomobject]@{ ok = $true; policy = (Get-PolicyView $policy) })
        }
        catch { Write-JsonResponse $Context @{ ok = $false; error = $_.Exception.Message } 500 }
        return
    }

    if ($path -eq '/api/policy/context' -and $method -eq 'POST') {
        $b = Read-JsonBody $Context
        if (-not $b) { Write-JsonResponse $Context @{ error = 'body required' } 400; return }
        try {
            $policy = Read-Policy -Path $script:PolicyPath
            Set-PolicyContext -Policy $policy -UserName ([string] $b.userName) -Role ([string] $b.role) `
                -Priorities (@($b.priorities | ForEach-Object { [string] $_ }))
            Save-Policy -Policy $policy -Path $script:PolicyPath
            Write-JsonResponse $Context ([pscustomobject]@{ ok = $true; policy = (Get-PolicyView $policy) })
        }
        catch { Write-JsonResponse $Context @{ ok = $false; error = $_.Exception.Message } 500 }
        return
    }

    if ($path -eq '/api/rev' -and $method -eq 'GET') {
        # ワーカーの死活もここで返す。版はハートビートで変わらないので、
        # これが無いと「止まったこと」が画面に伝わらない。
        Write-JsonResponse $Context ([pscustomobject]@{
            rev     = (Get-BoardRevision -Conn $Conn)
            worker  = (Get-WorkerPayload $Conn)
            collector = (Get-CollectorPayload $Conn)
            # 承認待ちは待たせるほど作業が止まるので、毎回のポーリングで返す
            pending = @(Get-PendingToolRequests -Conn $Conn).Count
        })
        return
    }

    if ($path -eq '/api/board' -and $method -eq 'GET') {
        $arch = ($req.Url.Query -match 'archived=1')
        Write-JsonResponse $Context (Get-BoardPayload $Conn -Archived:$arch)
        return
    }

    if ($path -eq '/api/tasks' -and $method -eq 'POST') {
        $b = Read-JsonBody $Context
        if (-not $b -or -not $b.title) { Write-JsonResponse $Context @{ error = 'title is required' } 400; return }
        $id = New-UserTask -Conn $Conn -Title $b.title -Summary $b.summary
        Write-JsonResponse $Context ([pscustomobject]@{ ok = $true; id = $id })
        return
    }

    # 列ごとのまとめて削除。
    # 対象は画面が見ていた id をそのまま受け取らず、いまその列にあるものだけに絞る。
    # ボードは 1.5 秒ごとに更新されるので、押した瞬間に別の列へ移っていたカードを
    # 巻き込みうる。消してから気付いても戻せない操作なので、ここで落とす。
    if ($path -eq '/api/tasks/bulk-delete' -and $method -eq 'POST') {
        $b = Read-JsonBody $Context
        if (-not $b -or -not $b.column) { Write-JsonResponse $Context @{ error = 'column is required' } 400; return }
        $col = [string] $b.column

        if ($col -eq 'archived') {
            $current = @(Get-Tasks -Conn $Conn -IncludeArchived | Where-Object { $_['archived_at'] })
        }
        elseif ($ColumnKeys -contains $col) {
            $current = @(Get-Tasks -Conn $Conn -Column $col)
        }
        else {
            Write-JsonResponse $Context @{ error = 'unknown column' } 400; return
        }

        $requested = @()
        if ($null -ne $b.ids) { $requested = @($b.ids | ForEach-Object { [int] $_ }) }

        $inColumn = @{}
        foreach ($r in $current) { $inColumn[[int] $r['id']] = $true }
        $targets = @($requested | Where-Object { $inColumn.ContainsKey($_) })

        $deleted = 0
        if ($targets.Count -gt 0) {
            try { $deleted = Remove-Tasks -Conn $Conn -TaskIds $targets }
            catch {
                Write-JsonResponse $Context @{ ok = $false; error = $_.Exception.Message } 500
                return
            }
        }
        Write-JsonResponse $Context @{
            ok = $true; deleted = $deleted; skipped = ($requested.Count - $targets.Count)
        }
        return
    }

    # /api/tasks/{id} と /api/tasks/{id}/{action}
    if ($path -match '^/api/tasks/(\d+)(?:/(\w+))?$') {
        $taskId = [int] $Matches[1]
        $action = $Matches[2]

        if ($method -eq 'GET' -and -not $action) {
            $d = Get-TaskDetail -Conn $Conn -TaskId $taskId
            if (-not $d) { Write-JsonResponse $Context @{ error = 'not found' } 404; return }
            $openLink = $null
            if ($d.event) {
                $u = Get-SafeOpenLink ([string] $d.event['permalink'])
                if (-not $u) { $u = Get-SafeOpenLink ([string] $d.event['link']) }
                if ($u) { $openLink = [pscustomobject]@{ url = $u; label = (Get-OpenLinkLabel $u ([string] $d.event['app'])) } }
            }
            # 一覧と同じく human_step_obj を足す。詳細だけ素の行を返すと、
            # カードに出ていた1手が開いた瞬間に消える。
            $taskObj = ConvertTo-PlainObject $d.task
            Add-HumanStepObject -Row $d.task -Object $taskObj
            Write-JsonResponse $Context ([pscustomobject]@{
                task     = $taskObj
                # 設定カードなら入力欄一式。画面はこれを見て設定フォームを出す。
                setup    = (Get-CardSetupService -Row $d.task -Conn $Conn)
                comments = @($d.comments | ForEach-Object { ConvertTo-PlainObject $_ })
                event    = (ConvertTo-PlainObject $d.event)
                openLink = $openLink
                outlet   = (Get-TaskOutlet $d.event)
                # 返信先の内容。送る前にトーンを決めるのに要るので、
                # 「元の通知」の折りたたみとは別に、割った形でも渡す。
                conversation = @(Get-EventConversation $d.event)
                # 成果物を触るためのフォルダ。無ければ null (画面はボタンを出さない)。
                workspace = (Get-TaskWorkspaceDir -Conn $Conn -TaskId $taskId)
                activity = @(Get-TaskActivity -Conn $Conn -TaskId $taskId | ForEach-Object { ConvertTo-PlainObject $_ })
                # 実際に何を叩いて何が返ったか。「手を尽くしたのか」を
                # 報告の書きぶりではなくここで確かめられるようにする。
                attempts = @(Get-TaskAttempts -Conn $Conn -TaskId $taskId | ForEach-Object { ConvertTo-PlainObject $_ })
                artifacts = @(Get-TaskArtifacts -Conn $Conn -TaskId $taskId | ForEach-Object {
                    [pscustomobject]@{ id = $_['id']; name = $_['name']; bytes = $_['bytes']; created_at = $_['created_at'] }
                })
            })
            return
        }

        # 成果物の中身を返す。パスは DB 側の記録からのみ引き、
        # クライアントから受けたパスは一切使わない。
        if ($method -eq 'GET' -and $action -eq 'artifact') {
            $aid = 0
            if ($req.Url.Query -match 'id=(\d+)') { $aid = [int] $Matches[1] }
            $row = @(Get-TaskArtifacts -Conn $Conn -TaskId $taskId | Where-Object { [int] $_['id'] -eq $aid })
            if ($row.Count -eq 0) { Write-JsonResponse $Context @{ error = 'not found' } 404; return }
            $p = [string] $row[0]['path']
            if (-not (Test-Path -LiteralPath $p)) {
                Write-JsonResponse $Context @{ error = 'ファイルが見つかりません'; name = $row[0]['name'] } 404; return
            }
            Write-JsonResponse $Context ([pscustomobject]@{
                name    = $row[0]['name']
                path    = $p
                content = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
            })
            return
        }

        if ($method -eq 'DELETE' -and -not $action) {
            try { $ok = Remove-Task -Conn $Conn -TaskId $taskId }
            catch {
                Write-JsonResponse $Context @{ ok = $false; error = $_.Exception.Message } 500
                return
            }
            if (-not $ok) { Write-JsonResponse $Context @{ ok = $false; error = 'not found' } 404; return }
            Write-JsonResponse $Context @{ ok = $true }
            return
        }

        $b = Read-JsonBody $Context
        $expected = if ($b -and $null -ne $b.version) { [int] $b.version } else { -1 }

        switch ($action) {
            'move' {
                if (-not $b -or $ColumnKeys -notcontains $b.column) {
                    Write-JsonResponse $Context @{ error = 'unknown column' } 400; return
                }
                $ok = Set-TaskColumn -Conn $Conn -TaskId $taskId -Column $b.column -ExpectedVersion $expected
                # 実行中から動かしたら中止要求とみなす。ユーザーの割り込みはここで拾う。
                if ($ok -and $b.from -eq 'doing' -and $b.column -ne 'doing') {
                    [void] (Set-TaskCancel -Conn $Conn -TaskId $taskId -Requested $true)
                    Add-TaskActivity -Conn $Conn -TaskId $taskId -Kind 'user' -Message '実行中から移動したため中止を要求しました'
                }
                # 要対応に戻すのは「もう一度やって」の意思表示。中止フラグが
                # 残っているとワーカーが永久に無視するので、ここで解除する。
                if ($ok -and $b.column -eq 'todo') {
                    [void] (Set-TaskCancel -Conn $Conn -TaskId $taskId -Requested $false)
                }
                if (-not $ok) { Write-JsonResponse $Context @{ ok = $false; conflict = $true } 409; return }
                Write-JsonResponse $Context @{ ok = $true }
                return
            }
            'comment' {
                if (-not $b -or -not $b.body) { Write-JsonResponse $Context @{ error = 'body is required' } 400; return }
                [void] (Add-TaskComment -Conn $Conn -TaskId $taskId -Author 'user' -Body $b.body)
                # 指示を書く = やり直してほしい。要対応に戻してワーカーに拾わせる。
                $col = Request-TaskRework -Conn $Conn -TaskId $taskId
                Write-JsonResponse $Context @{ ok = $true; column = $col }
                return
            }
            # このカードの出どころを、以後ふるいで落とす。
            #
            # 条件はモデルにも画面にも決めさせず、サーバがカードの元イベントから取る。
            # 画面から任意の文字列を受け取れる作りにすると、ボードに載った
            # 第三者の文面から「全部無視」に近い条件を仕込む道ができる。
            'ignore' {
                $d = Get-TaskDetail -Conn $Conn -TaskId $taskId
                if (-not $d -or -not $d.event) {
                    Write-JsonResponse $Context @{ ok = $false; error = 'このカードには元の通知がありません' } 400
                    return
                }
                $appId = [string] $d.event['app_id']
                if (-not $appId) {
                    Write-JsonResponse $Context @{ ok = $false; error = 'このカードにはアプリの識別子がありません' } 400
                    return
                }
                try {
                    $policy = Read-Policy -Path $script:PolicyPath
                    $r = Add-IgnorePattern -Policy $policy -Kind 'appId' -Pattern $appId
                    if ($r.ok) { Save-Policy -Policy $policy -Path $script:PolicyPath }
                    elseif ($r.error -ne 'すでに入っています。') {
                        Write-JsonResponse $Context @{ ok = $false; error = $r.error } 400; return
                    }
                }
                catch { Write-JsonResponse $Context @{ ok = $false; error = $_.Exception.Message } 500; return }

                [void] (Set-TaskColumn -Conn $Conn -TaskId $taskId -Column 'dismissed')
                Add-TaskActivity -Conn $Conn -TaskId $taskId -Kind 'user' `
                    -Message ("以後 {0} の通知はカードにしません (ふるいに追加)" -f $appId)
                Write-JsonResponse $Context @{ ok = $true; pattern = $appId }
                return
            }
            'cancel' {
                $on = if ($b -and $null -ne $b.cancel) { [bool] $b.cancel } else { $true }
                [void] (Set-TaskCancel -Conn $Conn -TaskId $taskId -Requested $on)
                $m = if ($on) { '利用者が中止を要求しました' } else { '利用者が中止要求を取り消しました' }
                Add-TaskActivity -Conn $Conn -TaskId $taskId -Kind 'user' -Message $m
                Write-JsonResponse $Context @{ ok = $true; cancel = $on }
                return
            }
            'archive' {
                $on = if ($b -and $null -ne $b.archived) { [bool] $b.archived } else { $true }
                [void] (Set-TaskArchived -Conn $Conn -TaskId $taskId -Archived $on)
                Write-JsonResponse $Context @{ ok = $true; archived = $on }
                return
            }
            # 「実施」で終わるカードの出口。宛先が無いカードでも、書いた内容が
            # カードを閉じる操作に直結する ―― 保存しても何も起きない欄にしない。
            # 中身は空でもよい。書けば「なぜ完了にしたか」の記録として残る。
            'done' {
                if (-not $b) { Write-JsonResponse $Context @{ error = 'body required' } 400; return }
                $text = [string] $b.text
                # 空で押されたときに user_edited を空で上書きしない。
                # 送る文面と対応の記録は同じ列に入るので、「送らずに完了」を
                # 選んだだけで書きかけの文面が消えると取り返しがつかない。
                if ($text.Trim()) {
                    $ok = Update-TaskFields -Conn $Conn -TaskId $taskId `
                            -Fields @{ user_edited = $text } -ExpectedVersion $expected
                    if (-not $ok) { Write-JsonResponse $Context @{ ok = $false; conflict = $true } 409; return }
                    [void] (Set-TaskColumn -Conn $Conn -TaskId $taskId -Column 'done')
                    Add-TaskActivity -Conn $Conn -TaskId $taskId -Kind 'done' `
                        -Message '利用者が対応の記録を残して完了にしました'
                }
                else {
                    $ok = Set-TaskColumn -Conn $Conn -TaskId $taskId -Column 'done' -ExpectedVersion $expected
                    if (-not $ok) { Write-JsonResponse $Context @{ ok = $false; conflict = $true } 409; return }
                    Add-TaskActivity -Conn $Conn -TaskId $taskId -Kind 'done' -Message '利用者が完了にしました'
                }
                Write-JsonResponse $Context @{ ok = $true }
                return
            }
            # レビューで最も読まれるのはワーカーの報告で、多くはその内容で了として閉じる。
            # 「対応の記録」を書き写させずに、承認したという事実だけを残して完了にする。
            # 自分で手を動かして終わらせた場合 (done) とは意味が違うので、別の口にしている。
            'approve' {
                $note = ''
                if ($b -and $null -ne $b.note) { $note = [string] $b.note }
                if ($note.Trim()) {
                    $ok = Update-TaskFields -Conn $Conn -TaskId $taskId `
                            -Fields @{ user_edited = $note } -ExpectedVersion $expected
                    if (-not $ok) { Write-JsonResponse $Context @{ ok = $false; conflict = $true } 409; return }
                    [void] (Set-TaskColumn -Conn $Conn -TaskId $taskId -Column 'done')
                }
                else {
                    $ok = Set-TaskColumn -Conn $Conn -TaskId $taskId -Column 'done' -ExpectedVersion $expected
                    if (-not $ok) { Write-JsonResponse $Context @{ ok = $false; conflict = $true } 409; return }
                }
                $m = '利用者がワーカーの報告を承認して完了にしました'
                if ($note.Trim()) { $m = '利用者がワーカーの報告を承認しました: ' + $note }
                Add-TaskActivity -Conn $Conn -TaskId $taskId -Kind 'done' -Message $m
                Write-JsonResponse $Context @{ ok = $true }
                return
            }
            # 成果物のあるカードは、中身を眺めて終わりではなくファイルを触ることになる。
            # フォルダはサーバが DB の記録から決める。クライアントからパスは受け取らない。
            'folder' {
                $dir = Get-TaskWorkspaceDir -Conn $Conn -TaskId $taskId
                if (-not $dir) {
                    Write-JsonResponse $Context @{ ok = $false; error = 'このカードには作業フォルダがありません' } 404
                    return
                }
                if ($env:OS -ne 'Windows_NT') {
                    Write-JsonResponse $Context @{ ok = $false; error = 'この環境ではフォルダを開けません'; path = $dir } 500
                    return
                }
                try { [void] (Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir)) }
                catch {
                    Write-JsonResponse $Context @{ ok = $false; error = $_.Exception.Message; path = $dir } 500
                    return
                }
                Write-JsonResponse $Context @{ ok = $true; path = $dir }
                return
            }
            # 「送る」で終わるカードの出口。取り消せないので、ここだけは条件を厚くする:
            #   - 宛先はサーバが元イベントから決める。リクエストの宛先は受け取らない
            #   - confirm が無いと送らない (UI の確認ダイアログを通った印)
            #   - 送る文面は先に user_edited へ保存する。送ったものと残るものを一致させる
            #   - version 照合。画面が古いまま押した場合は 409 で止める
            #
            # 送信は終わりとは限らない。「承知しました、対応します」と返してから
            # 実際の作業が始まる用件があり、そこで完了に落とすとカードが行方不明になる。
            # finish=false なら送ったうえで要対応に戻し、続きをワーカーに拾わせる。
            'send' {
                if (-not $b -or -not $b.confirm) {
                    Write-JsonResponse $Context @{ error = '確認が必要です' } 400; return
                }
                $text = [string] $b.text
                if (-not $text.Trim()) { Write-JsonResponse $Context @{ error = '本文が空です' } 400; return }

                $d = Get-TaskDetail -Conn $Conn -TaskId $taskId
                if (-not $d) { Write-JsonResponse $Context @{ error = 'not found' } 404; return }
                $outlet = Get-TaskOutlet $d.event
                if ($outlet.kind -eq 'none') {
                    Write-JsonResponse $Context @{ error = 'このカードには送り先がありません' } 400; return
                }

                $ok = Update-TaskFields -Conn $Conn -TaskId $taskId `
                        -Fields @{ user_edited = $text } -ExpectedVersion $expected
                if (-not $ok) { Write-JsonResponse $Context @{ ok = $false; conflict = $true } 409; return }

                try {
                    if ($outlet.kind -eq 'gmail') {
                        $raw = [string] $d.event['raw_json'] | ConvertFrom-Json
                        [void] (Send-GmailMessage -To $outlet.to -Subject $outlet.subject -Body $text `
                                -ThreadId ([string] $raw.threadId) -InReplyTo ([string] $raw.messageId))
                        $sentTo = $outlet.to
                        $permalink = ''
                    }
                    elseif ($outlet.kind -eq 'outlook') {
                        $raw = [string] $d.event['raw_json'] | ConvertFrom-Json
                        [void] (Send-OutlookMail -To $outlet.to -Subject $outlet.subject -Body $text `
                                -ReplyToMessageId ([string] $raw.id))
                        $sentTo = $outlet.to
                        $permalink = ''
                    }
                    elseif ($outlet.kind -eq 'chatwork') {
                        $tg = Get-ChatworkTarget -Link ([string] $d.event['link'])
                        $acct = ''
                        try { $acct = [string] ([string] $d.event['raw_json'] | ConvertFrom-Json).accountId } catch { }
                        $r = Send-ChatworkMessage -RoomId $tg.roomId -Text $text `
                                -ReplyToAccountId $acct -ReplyToMessageId $tg.messageId
                        $sentTo = $tg.roomName
                        $permalink = $r.permalink
                    }
                    elseif ($outlet.kind -eq 'backlog') {
                        $r = Add-BacklogComment -IssueKey $outlet.to -Content $text
                        $sentTo = ("課題 {0}" -f $outlet.to)
                        $permalink = $r.permalink
                    }
                    elseif ($outlet.kind -eq 'teams') {
                        $tg = Get-TeamsTarget -Link ([string] $d.event['link'])
                        $r = Send-TeamsMessage -ChatId $tg.chatId -Text $text
                        $sentTo = $tg.chatName
                        $permalink = $r.permalink
                    }
                    else {
                        $tg = Get-SlackTarget -Link ([string] $d.event['link'])
                        $r = Send-SlackMessage -Channel $tg.channel -Text $text -ThreadTs $tg.threadTs
                        $sentTo = $tg.channelName
                        $permalink = $r.permalink
                    }
                }
                catch {
                    $msg = $_.Exception.Message
                    Add-TaskActivity -Conn $Conn -TaskId $taskId -Kind 'error' -Message ("送信に失敗しました: " + $msg)
                    Write-JsonResponse $Context @{ ok = $false; error = $msg } 500
                    return
                }

                Add-TaskActivity -Conn $Conn -TaskId $taskId -Kind 'sent' `
                    -Message ("利用者がカンバンから送信しました: {0}" -f $sentTo)

                # 既定は「送って完了」。用件が残っているときだけ finish=false で戻す。
                $finish = $true
                if ($null -ne $b.finish) { $finish = [bool] $b.finish }
                if ($finish) {
                    [void] (Set-TaskColumn -Conn $Conn -TaskId $taskId -Column 'done')
                    $column = 'done'
                }
                else {
                    $column = Request-TaskRework -Conn $Conn -TaskId $taskId `
                                -Note '返信は送りましたが用件が残っているため、要対応に戻しました'
                }
                Write-JsonResponse $Context @{ ok = $true; to = $sentTo; permalink = $permalink; column = $column }
                return
            }
            default {
                if ($method -eq 'PATCH' -or $method -eq 'POST') {
                    if (-not $b) { Write-JsonResponse $Context @{ error = 'body required' } 400; return }
                    $fields = @{}
                    foreach ($k in @('title', 'summary', 'urgency', 'user_edited')) {
                        if ($null -ne $b.$k) { $fields[$k] = $b.$k }
                    }
                    $ok = Update-TaskFields -Conn $Conn -TaskId $taskId -Fields $fields -ExpectedVersion $expected
                    if (-not $ok) { Write-JsonResponse $Context @{ ok = $false; conflict = $true } 409; return }
                    Write-JsonResponse $Context @{ ok = $true }
                    return
                }
            }
        }
        Write-JsonResponse $Context @{ error = 'bad request' } 400
        return
    }

    if ($method -eq 'GET') { Write-StaticFile $Context $path; return }
    $Context.Response.StatusCode = 404
}

# ---------------------------------------------------------------- main

$conn     = Open-TaskStore -Path $DbPath

# ポートが埋まっていたら、隣を試す。
#
# 既定の 8787 が別のアプリに使われている PC は珍しくない。そこで諦めると、
# 監視役が延々と起動し直すだけになり、画面は最後まで開かない ――
# 配った先では「アイコンを押しても何も起きない」としか見えず、直しようがない。
# 戻り先 (OAuth) は実際に開いたポートで組み立てるので、ずれても同意は通る。
$listener = $null
foreach ($p in $Port..($Port + 9)) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://127.0.0.1:$p/")
    $l.Prefixes.Add("http://localhost:$p/")
    try {
        $l.Start()
        if ($p -ne $Port) {
            Write-Host ("ポート {0} は使われていたので {1} で開きました" -f $Port, $p) -ForegroundColor Yellow
        }
        $Port = $p
        $listener = $l
        break
    }
    catch { try { $l.Close() } catch { } }
}
if (-not $listener) {
    Write-Host ("ポート {0} から {1} まで、どれも開けませんでした。" -f $Port, ($Port + 9)) -ForegroundColor Red
    Write-Host '  config\app-config.json の startup.port を空いている番号に変えてください。' -ForegroundColor DarkGray
    $conn.Dispose()
    return
}

# OAuth の戻り先を組み立てるのに要る。戻り先は「いま開いているカンバン」。
$script:BoardPort = $Port

$url = "http://localhost:$Port/"
# 実際に開いたポートを残す。監視役 (Start.ps1) はこれを読んで、
# ずれていれば本当の URL を出す ―― 案内した番号が違うと、
# 「開かない」と言われたときに見に行く先まで間違える。
try { Set-Setting -Conn $conn -Key 'board.url' -Value $url } catch { }
Write-Host "カンバンボード: $url" -ForegroundColor Green
Write-Host "停止するには Ctrl+C" -ForegroundColor DarkGray
if (-not $NoBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            # 通すかどうかの判定は lib\RequestGuard.ps1 にある
            # (ボードを起動しないと確かめられない場所に置くと、確かめられない)。
            if (-not (Test-AllowedHost -HostHeader $ctx.Request.Headers['Host'])) {
                $ctx.Response.StatusCode = 400
            }
            elseif (-not (Test-AllowedOrigin -Method $ctx.Request.HttpMethod `
                            -Origin $ctx.Request.Headers['Origin'] -Port $Port)) {
                $ctx.Response.StatusCode = 403
            }
            else {
                Invoke-Route $ctx $conn
            }
        }
        catch {
            Write-Host ("request error: {0}" -f $_.Exception.Message) -ForegroundColor Red
            try {
                $ctx.Response.StatusCode = 500
                $msg = [Text.Encoding]::UTF8.GetBytes('{"error":"internal"}')
                $ctx.Response.OutputStream.Write($msg, 0, $msg.Length)
            } catch { }
        }
        finally {
            try { $ctx.Response.OutputStream.Close() } catch { }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    $conn.Dispose()
    Write-Host 'stopped.' -ForegroundColor Yellow
}
