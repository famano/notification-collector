<#
.SYNOPSIS
    Phase 1: Windows の通知データベース (wpndatabase.db) をポーリングして通知を取得する。

.DESCRIPTION
    追加インストールは一切不要。Windows 同梱の winsqlite3.dll を P/Invoke して読む。
    原本はサービスが掴んでいるので db/-wal/-shm を一時コピーしてから読み取る。

    このスクリプトの目的は「通知だけでどこまで分かるのか」を見極めること。
    取得した内容は data/notifications.jsonl に追記され、Phase 2 以降の入力になる。

.PARAMETER Watch
    継続監視する。省略時は 1 回だけ実行して終了。

.PARAMETER IntervalSeconds
    Watch 時のポーリング間隔 (既定 5 秒)。Windows は通知を短時間で消すため、
    長くしすぎると取りこぼす。

.PARAMETER Backfill
    保存済みの状態を無視し、DB に現存する通知をすべて出力する。

.PARAMETER IncludeAllTypes
    toast だけでなく tile / badge も対象にする (既定は toast のみ)。

.PARAMETER Json
    整形表示ではなく JSON 1 行/件で標準出力に出す。

.EXAMPLE
    .\Get-Notifications.ps1 -Backfill
    .\Get-Notifications.ps1 -Watch
#>
[CmdletBinding()]
param(
    [switch] $Watch,
    [int]    $IntervalSeconds = 5,
    [switch] $Backfill,
    [switch] $IncludeAllTypes,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\WinSqlite.ps1"

$DataDir   = Join-Path $PSScriptRoot 'data'
$StatePath = Join-Path $DataDir 'state.json'
$OutPath   = Join-Path $DataDir 'notifications.jsonl'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

# ---------------------------------------------------------------- state

function Read-State {
    if (Test-Path $StatePath) {
        try { return Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ LastOrder = 0; SeenKeys = @() }
}

function Write-State($state) {
    # SeenKeys は無制限に伸ばさない。DB 自体が十数件しか保持しないので直近分で十分。
    $state.SeenKeys = @($state.SeenKeys | Select-Object -Last 500)
    $json = $state | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($StatePath, $json, (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- payload 解析

function ConvertFrom-PayloadBlob {
    param([byte[]] $Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    # BOM 無しでも 2 バイト目が 0x00 なら UTF-16LE とみなす
    if ($Bytes.Length -ge 4 -and $Bytes[1] -eq 0x00 -and $Bytes[3] -eq 0x00) {
        return [Text.Encoding]::Unicode.GetString($Bytes)
    }
    return [Text.Encoding]::UTF8.GetString($Bytes)
}

function ConvertFrom-ToastXml {
    param([string] $Xml)

    $result = [ordered]@{ title = ''; body = ''; lines = @(); header = ''; launch = ''; attribution = '' }
    if ([string]::IsNullOrWhiteSpace($Xml)) { return $result }

    try { $doc = [xml] $Xml } catch { $result.title = '<XML parse failed>'; return $result }

    $texts = @()
    foreach ($n in $doc.SelectNodes('//text')) {
        $t = ($n.InnerText -replace '\s+', ' ').Trim()
        if ($t) {
            # placement="attribution" は送信元表記なので本文と分けておく
            $placement = $null
            if ($n.Attributes -and $n.Attributes['placement']) { $placement = $n.Attributes['placement'].Value }
            if ($placement -eq 'attribution') { $result.attribution = $t } else { $texts += $t }
        }
    }

    $result.lines = $texts
    if ($texts.Count -gt 0) { $result.title = $texts[0] }
    if ($texts.Count -gt 1) { $result.body  = ($texts[1..($texts.Count - 1)] -join ' / ') }

    $hdr = $doc.SelectSingleNode('//header')
    if ($hdr -and $hdr.Attributes['title']) { $result.header = $hdr.Attributes['title'].Value }

    $root = $doc.SelectSingleNode('/toast')
    if ($root -and $root.Attributes['launch']) { $result.launch = $root.Attributes['launch'].Value }

    return $result
}

function ConvertFrom-FileTime {
    param([long] $Value)
    if ($Value -le 0) { return $null }
    try { return [DateTime]::FromFileTimeUtc($Value).ToLocalTime() } catch { return $null }
}

# ---------------------------------------------------------------- 取得

function Get-WpnNotifications {
    param([long] $SinceOrder = 0, [switch] $AllTypes)

    $db = New-WpnSnapshot
    try {
        $typeFilter = if ($AllTypes) { '' } else { "AND n.Type = 'toast'" }
        $sql = @"
SELECT n.[Order] AS Ord, n.Id, n.HandlerId, n.Type, n.Payload, n.PayloadType,
       n.Tag, n.[Group] AS Grp, n.ArrivalTime, n.ExpiryTime,
       h.PrimaryId AS Aumid,
       (SELECT a.AssetValue FROM HandlerAssets a
         WHERE a.HandlerId = n.HandlerId AND a.AssetKey = 'DisplayName' LIMIT 1) AS DisplayName
  FROM Notification n
  LEFT JOIN NotificationHandler h ON h.RecordId = n.HandlerId
 WHERE n.[Order] > $SinceOrder $typeFilter
 ORDER BY n.[Order] ASC
"@
        $rows = [WinSqlite.Db]::Query($db, $sql)
    }
    finally { Remove-WpnSnapshot $db }

    foreach ($r in $rows) {
        $xml   = ConvertFrom-PayloadBlob $r['Payload']
        $toast = ConvertFrom-ToastXml $xml
        $app   = if ($r['DisplayName']) { $r['DisplayName'] } else { $r['Aumid'] }

        # 重複排除キー: 同一通知が再挿入されても同じ値になるように組む
        $key = '{0}|{1}|{2}|{3}' -f $r['HandlerId'], $r['Tag'], $r['Grp'], $r['ArrivalTime']

        [pscustomobject]@{
            key         = $key
            order       = [long] $r['Ord']
            id          = [long] $r['Id']
            type        = $r['Type']
            app         = $app
            aumid       = $r['Aumid']
            arrivedAt   = (ConvertFrom-FileTime ([long] $r['ArrivalTime']))
            expiresAt   = (ConvertFrom-FileTime ([long] $r['ExpiryTime']))
            header      = $toast.header
            title       = $toast.title
            body        = $toast.body
            lines       = $toast.lines
            attribution = $toast.attribution
            launch      = $toast.launch
            tag         = $r['Tag']
            group       = $r['Grp']
            payloadXml  = $xml
        }
    }
}

# ---------------------------------------------------------------- 出力

function Show-Notification {
    param($n)
    $ts  = if ($n.arrivedAt) { $n.arrivedAt.ToString('yyyy-MM-dd HH:mm:ss') } else { '(no time)' }
    $hdr = if ($n.header) { " [$($n.header)]" } else { '' }
    Write-Host ''
    Write-Host ("[{0}] {1}{2}" -f $ts, $n.app, $hdr) -ForegroundColor Cyan
    Write-Host ("  title : {0}" -f $n.title)
    if ($n.body)        { Write-Host ("  body  : {0}" -f $n.body) }
    if ($n.attribution) { Write-Host ("  attr  : {0}" -f $n.attribution) -ForegroundColor DarkGray }
    if ($n.launch)      { Write-Host ("  launch: {0}" -f $n.launch) -ForegroundColor DarkGray }
    Write-Host ("  key   : {0}" -f $n.key) -ForegroundColor DarkGray
}

function Save-Notification {
    param($n)
    $line = $n | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::AppendAllText($OutPath, $line + "`n", (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- main

function Invoke-Poll {
    param($state)

    $since = if ($Backfill) { 0 } else { [long] $state.LastOrder }
    $items = @(Get-WpnNotifications -SinceOrder $since -AllTypes:$IncludeAllTypes)

    $seen = @{}
    foreach ($k in $state.SeenKeys) { $seen[$k] = $true }

    $new = 0
    foreach ($n in $items) {
        if ($seen.ContainsKey($n.key)) { continue }
        $seen[$n.key] = $true
        $state.SeenKeys += $n.key

        if ($Json) { $n | ConvertTo-Json -Depth 6 -Compress } else { Show-Notification $n }
        Save-Notification $n
        $new++

        if ($n.order -gt $state.LastOrder) { $state.LastOrder = $n.order }
    }
    return $new
}

$state = Read-State

if ($Watch) {
    Write-Host "watching wpndatabase.db (interval ${IntervalSeconds}s) — Ctrl+C to stop" -ForegroundColor Yellow
    Write-Host "output -> $OutPath" -ForegroundColor DarkGray
    try {
        while ($true) {
            try { [void](Invoke-Poll $state); Write-State $state }
            catch { Write-Host ("poll error: {0}" -f $_.Exception.Message) -ForegroundColor Red }
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    finally { Write-State $state }
}
else {
    $n = Invoke-Poll $state
    Write-State $state
    if (-not $Json) {
        Write-Host ''
        Write-Host ("{0} new notification(s). total log -> {1}" -f $n, $OutPath) -ForegroundColor Yellow
    }
}
