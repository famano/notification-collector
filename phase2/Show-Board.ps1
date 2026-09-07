<#
.SYNOPSIS
    タスクストアの中身をカンバン風に表示する (Phase 3 の Web UI までの暫定ビュー)。
#>
[CmdletBinding()]
param([string] $DbPath)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\TaskStore.ps1"

$Columns = @(
    @{ key = 'inbox';     label = '未分類' },
    @{ key = 'todo';      label = '要対応' },
    @{ key = 'doing';     label = '実行中' },
    @{ key = 'review';    label = 'レビュー待ち' },
    @{ key = 'done';      label = '完了' },
    @{ key = 'dismissed'; label = '対応不要' }
)

$conn = Open-TaskStore -Path $DbPath
try {
    $all = @(Get-Tasks -Conn $conn)
    if ($all.Count -eq 0) {
        Write-Host 'タスクがありません。先に Invoke-Triage.ps1 を実行してください。' -ForegroundColor Yellow
        return
    }

    foreach ($c in $Columns) {
        $items = @($all | Where-Object { $_['board_column'] -eq $c.key })
        $color = switch ($c.key) {
            'todo'      { 'Green' }
            'doing'     { 'Cyan' }
            'review'    { 'Magenta' }
            'dismissed' { 'DarkGray' }
            default     { 'Gray' }
        }
        Write-Host ''
        Write-Host ("== {0} ({1}) ==" -f $c.label, $items.Count) -ForegroundColor $color
        foreach ($t in $items) {
            $urg = if ($t['urgency']) { "[$($t['urgency'])]" } else { '' }
            Write-Host ("  #{0} {1} {2}" -f $t['id'], $urg, $t['title'])
            if ($t['summary']) { Write-Host ("      {0}" -f $t['summary']) -ForegroundColor DarkGray }
        }
    }

    $orphan = @($all | Where-Object { $c = $_['board_column']; -not ($Columns.key -contains $c) })
    if ($orphan.Count -gt 0) {
        Write-Host ''
        Write-Host ("== 未知の列 ({0}) ==" -f $orphan.Count) -ForegroundColor Red
        foreach ($t in $orphan) { Write-Host ("  #{0} [{1}] {2}" -f $t['id'], $t['board_column'], $t['title']) }
    }
    Write-Host ''
}
finally { $conn.Dispose() }
