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

.EXAMPLE
    .\Start-Board.ps1
#>
[CmdletBinding()]
param(
    [int]    $Port = 8787,
    [string] $DbPath,
    [switch] $NoBrowser
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\phase2\lib\TaskStore.ps1"

# 送信経路。カンバンだけで仕事を終わらせるには、最後の一手 (送る) もここに要る。
# Phase 5 が無い・未設定でもボード自体は動くように、読み込みは任意扱いにする。
$script:Connectors = $false
try {
    . "$PSScriptRoot\..\phase5\lib\SlackConnector.ps1"
    . "$PSScriptRoot\..\phase5\lib\GmailConnector.ps1"
    $script:Connectors = $true
}
catch {
    Write-Host ("外部サービス連携を読み込めませんでした (送信は使えません): {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
}

$WebRoot = Join-Path $PSScriptRoot 'wwwroot'

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
    # ディレクトリトラバーサル防止
    if (-not $full.StartsWith([IO.Path]::GetFullPath($WebRoot), [StringComparison]::OrdinalIgnoreCase)) {
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
    return $none
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
                comments = @($d.comments | ForEach-Object { ConvertTo-PlainObject $_ })
                event    = (ConvertTo-PlainObject $d.event)
                openLink = $openLink
                outlet   = (Get-TaskOutlet $d.event)
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
                Write-JsonResponse $Context @{ ok = $true }
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
                $ok = Update-TaskFields -Conn $Conn -TaskId $taskId `
                        -Fields @{ user_edited = $text } -ExpectedVersion $expected
                if (-not $ok) { Write-JsonResponse $Context @{ ok = $false; conflict = $true } 409; return }
                [void] (Set-TaskColumn -Conn $Conn -TaskId $taskId -Column 'done')
                $note = if ($text.Trim()) { '利用者が対応の記録を残して完了にしました' } else { '利用者が完了にしました' }
                Add-TaskActivity -Conn $Conn -TaskId $taskId -Kind 'done' -Message $note
                Write-JsonResponse $Context @{ ok = $true }
                return
            }
            # 「送る」で終わるカードの出口。取り消せないので、ここだけは条件を厚くする:
            #   - 宛先はサーバが元イベントから決める。リクエストの宛先は受け取らない
            #   - confirm が無いと送らない (UI の確認ダイアログを通った印)
            #   - 送る文面は先に user_edited へ保存する。送ったものと残るものを一致させる
            #   - version 照合。画面が古いまま押した場合は 409 で止める
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
                [void] (Set-TaskColumn -Conn $Conn -TaskId $taskId -Column 'done')
                Write-JsonResponse $Context @{ ok = $true; to = $sentTo; permalink = $permalink }
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
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Prefixes.Add("http://localhost:$Port/")

try {
    $listener.Start()
}
catch {
    Write-Host "ポート $Port を開けませんでした: $($_.Exception.Message)" -ForegroundColor Red
    $conn.Dispose()
    return
}

$url = "http://localhost:$Port/"
Write-Host "カンバンボード: $url" -ForegroundColor Green
Write-Host "停止するには Ctrl+C" -ForegroundColor DarkGray
if (-not $NoBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            # DNS リバインディング対策。127.0.0.1 バインドでも Host は検証しておく。
            $hostHeader = $ctx.Request.Headers['Host']
            # 状態を変える要求は Origin も見る。ブラウザは別サイトからの POST に
            # 必ず Origin を付けるので、外のページが localhost を叩いて
            # 削除や送信を起こす経路をここで塞ぐ。同一オリジンからは付かないか、
            # 自分自身の Origin が付く。
            $origin = $ctx.Request.Headers['Origin']
            $badOrigin = ($ctx.Request.HttpMethod -ne 'GET' -and $origin -and
                          $origin -notmatch "^https?://(localhost|127\.0\.0\.1)(:\d+)?$")
            if ($hostHeader -and $hostHeader -notmatch '^(localhost|127\.0\.0\.1)(:\d+)?$') {
                $ctx.Response.StatusCode = 400
            }
            elseif ($badOrigin) {
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
