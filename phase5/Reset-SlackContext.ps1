<#
.SYNOPSIS
    Slack の補完に失敗した印を消し、次回の Sync-Sources で再試行させる。

.DESCRIPTION
    Sync-Sources.ps1 は conversations.replies が失敗したイベントに
    context_fetched = 'error' を立てる。権限不足を延々と叩き直さないための印なので、
    普段はこれで正しい。

    ただし not_in_channel は後から直せる。チャンネルにアプリを招待すれば読めるようになる。
    その場合この印が邪魔になり、招待したのに二度と取りに行かない状態になるので、
    ここで消して再試行できるようにする。

    'unsupported' (リンクを解釈できなかったもの) は消さない。招待しても変わらないため。

.EXAMPLE
    .\Reset-SlackContext.ps1
#>
[CmdletBinding()]
param([string] $DbPath)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\phase2\lib\TaskStore.ps1"

$conn = Open-TaskStore -Path $DbPath
try {
    $n = $conn.NonQuery(
        "UPDATE events SET context_fetched = NULL
          WHERE link LIKE 'slack://%' AND context_fetched = 'error'")
    Write-Host ("再試行の対象に戻しました: {0} 件" -f $n) -ForegroundColor Green
    if ($n -gt 0) {
        Write-Host '  Sync-Sources.ps1 を実行すると取り直します。' -ForegroundColor DarkGray
    }
}
finally { $conn.Dispose() }
