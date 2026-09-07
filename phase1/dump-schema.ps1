# dump-schema.ps1 — 実機の wpndatabase.db のスキーマと生データを確認する調査用スクリプト。
# Phase 1 の最初の目的「何が取れるのか見極める」ためのもの。
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\lib\WinSqlite.ps1"

$db = New-WpnSnapshot
try {
    "=== TABLES ==="
    [WinSqlite.Db]::Query($db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") |
        ForEach-Object { "  " + $_['name'] }

    foreach ($t in @('Notification', 'NotificationHandler', 'HandlerAssets')) {
        "`n=== $t columns ==="
        [WinSqlite.Db]::Query($db, "PRAGMA table_info([$t])") |
            ForEach-Object { "  {0,-2} {1,-20} {2}" -f $_['cid'], $_['name'], $_['type'] }
    }

    "`n=== counts ==="
    $c = [WinSqlite.Db]::Query($db, "SELECT (SELECT COUNT(*) FROM Notification) AS n, (SELECT COUNT(*) FROM NotificationHandler) AS h")[0]
    "  Notification={0}  NotificationHandler={1}" -f $c['n'], $c['h']

    "`n=== notification types present ==="
    [WinSqlite.Db]::Query($db, "SELECT Type, COUNT(*) AS c FROM Notification GROUP BY Type") |
        ForEach-Object { "  {0} = {1}" -f $_['Type'], $_['c'] }

    "`n=== newest 3 rows (raw) ==="
    foreach ($r in [WinSqlite.Db]::Query($db, "SELECT * FROM Notification ORDER BY [Order] DESC LIMIT 3")) {
        "  -----"
        foreach ($k in $r.Keys) {
            $v = $r[$k]
            if ($v -is [byte[]]) {
                $head = $v[0..([Math]::Min(300, $v.Length) - 1)]
                $v = "<blob {0}B> {1}" -f $v.Length, ([Text.Encoding]::UTF8.GetString($head) -replace '[\r\n]+', ' ')
            }
            "    {0,-14} = {1}" -f $k, $v
        }
    }
}
finally { Remove-WpnSnapshot $db }
