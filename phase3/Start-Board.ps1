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

function Get-BoardPayload {
    param($Conn, [switch] $Archived)

    if ($Archived) {
        $rows = @(Get-Tasks -Conn $Conn -IncludeArchived | Where-Object { $_['archived_at'] })
        return [pscustomobject]@{
            rev     = (Get-BoardRevision -Conn $Conn)
            columns = @([pscustomobject]@{
                key   = 'archived'; label = 'アーカイブ済み'
                tasks = @($rows | ForEach-Object { ConvertTo-PlainObject $_ })
            })
            worker  = (Get-WorkerPayload $Conn)
        }
    }

    $all = @(Get-Tasks -Conn $Conn)
    $cols = foreach ($c in $Columns) {
        $items = @($all | Where-Object { $_['board_column'] -eq $c.key } | ForEach-Object { ConvertTo-PlainObject $_ })
        [pscustomobject]@{ key = $c.key; label = $c.label; tasks = $items }
    }
    return [pscustomobject]@{
        rev     = (Get-BoardRevision -Conn $Conn)
        columns = @($cols)
        worker  = (Get-WorkerPayload $Conn)
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

    if ($path -eq '/api/rev' -and $method -eq 'GET') {
        Write-JsonResponse $Context ([pscustomobject]@{ rev = (Get-BoardRevision -Conn $Conn) })
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

    # /api/tasks/{id} と /api/tasks/{id}/{action}
    if ($path -match '^/api/tasks/(\d+)(?:/(\w+))?$') {
        $taskId = [int] $Matches[1]
        $action = $Matches[2]

        if ($method -eq 'GET' -and -not $action) {
            $d = Get-TaskDetail -Conn $Conn -TaskId $taskId
            if (-not $d) { Write-JsonResponse $Context @{ error = 'not found' } 404; return }
            Write-JsonResponse $Context ([pscustomobject]@{
                task     = (ConvertTo-PlainObject $d.task)
                comments = @($d.comments | ForEach-Object { ConvertTo-PlainObject $_ })
                event    = (ConvertTo-PlainObject $d.event)
                activity = @(Get-TaskActivity -Conn $Conn -TaskId $taskId | ForEach-Object { ConvertTo-PlainObject $_ })
            })
            return
        }

        if ($method -eq 'DELETE' -and -not $action) {
            $ok = Remove-Task -Conn $Conn -TaskId $taskId
            if (-not $ok) { Write-JsonResponse $Context @{ error = 'not found' } 404; return }
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
                [void] (Set-TaskCancel -Conn $Conn -TaskId $taskId -Requested $true)
                Add-TaskActivity -Conn $Conn -TaskId $taskId -Kind 'user' -Message '利用者が中止を要求しました'
                Write-JsonResponse $Context @{ ok = $true }
                return
            }
            'archive' {
                $on = if ($b -and $null -ne $b.archived) { [bool] $b.archived } else { $true }
                [void] (Set-TaskArchived -Conn $Conn -TaskId $taskId -Archived $on)
                Write-JsonResponse $Context @{ ok = $true; archived = $on }
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
            if ($hostHeader -and $hostHeader -notmatch '^(localhost|127\.0\.0\.1)(:\d+)?$') {
                $ctx.Response.StatusCode = 400
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
