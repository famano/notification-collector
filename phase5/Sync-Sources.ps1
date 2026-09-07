<#
.SYNOPSIS
    Phase 5: 正規 API から実データを取り込み、通知だけでは足りない文脈を補う。

.DESCRIPTION
    2つのことをする。

    1. Slack の補完 — 通知から作られたイベントのうち、slack:// リンクを持つものについて
       conversations.replies でスレッド全文を取得し、events.body を差し替える。
       Phase 1 で「通知本文だけでは判断材料が足りない」と分かった件への対応。

    2. Gmail の取り込み — 通知経路に依存せず、メールを直接イベントにする。
       メールクライアントが通知を出していなくても拾える。

    どちらも冪等。同じものを何度取り込んでも events の UNIQUE 制約で弾かれ、
    補完済みのイベントは context_fetched を見て飛ばす。

.EXAMPLE
    .\Sync-Sources.ps1
    .\Sync-Sources.ps1 -GmailQuery 'in:inbox newer_than:2d'
#>
[CmdletBinding()]
param(
    [string] $DbPath,
    [string] $GmailQuery = 'in:inbox is:unread newer_than:1d',
    [int]    $GmailMax = 20,
    [int]    $SlackMax = 30,
    [switch] $SkipSlack,
    [switch] $SkipGmail
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\phase2\lib\TaskStore.ps1"
. "$PSScriptRoot\lib\SlackConnector.ps1"
. "$PSScriptRoot\lib\GmailConnector.ps1"

$conn = Open-TaskStore -Path $DbPath
try {
    # ---------------- Slack: 通知イベントにスレッド全文を足す ----------------
    if (-not $SkipSlack) {
        if (-not (Test-SlackConfigured)) {
            Write-Host 'Slack: 未設定のため飛ばします' -ForegroundColor DarkGray
        }
        else {
            $rows = @($conn.Query(
                "SELECT id, link, body FROM events
                  WHERE link LIKE 'slack://%' AND context_fetched IS NULL
                  ORDER BY occurred_at DESC LIMIT ?", [object[]] @($SlackMax)))
            Write-Host ("Slack: 補完対象 {0} 件" -f $rows.Count) -ForegroundColor Cyan

            foreach ($r in $rows) {
                $id = [string] $r['id']
                try {
                    $t = Get-SlackThread -Link ([string] $r['link'])
                    if (-not $t) {
                        # リンクを解釈できないものは二度と試さない
                        [void] $conn.NonQuery('UPDATE events SET context_fetched = ? WHERE id = ?',
                            [object[]] @('unsupported', $id))
                        continue
                    }
                    # 通知の表示テキストは残しつつ、判断材料になる全文を足す
                    $newBody = ("{0}`n`n--- スレッド全文 ({1} 件) ---`n{2}" -f $r['body'], $t.messageCount, $t.text)
                    [void] $conn.NonQuery(
                        'UPDATE events SET body = ?, context_fetched = ? WHERE id = ?',
                        [object[]] @($newBody, (Get-Date).ToString('o'), $id))
                    Write-Host ("  補完: {0} ({1} 件のメッセージ)" -f $t.channel, $t.messageCount) -ForegroundColor Green
                }
                catch {
                    Write-Host ("  失敗: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                    # 権限不足などは繰り返しても同じなので印だけ付ける
                    [void] $conn.NonQuery('UPDATE events SET context_fetched = ? WHERE id = ?',
                        [object[]] @('error', $id))
                }
            }
        }
    }

    # ---------------- Gmail: メールをイベントにする ----------------
    if (-not $SkipGmail) {
        if (-not (Test-GmailConfigured)) {
            Write-Host 'Gmail: 未設定のため飛ばします' -ForegroundColor DarkGray
        }
        else {
            Write-Host ("Gmail: 検索 '{0}'" -f $GmailQuery) -ForegroundColor Cyan
            $msgs = @(Get-GmailRecent -Query $GmailQuery -Max $GmailMax)
            $new = 0
            foreach ($m in $msgs) {
                $body = "差出人: $($m.from)`n宛先: $($m.to)"
                if ($m.cc) { $body += "`nCc: $($m.cc)" }
                $body += "`n日時: $($m.date)`n`n$($m.body)"

                $r = Add-Event -Conn $conn -Source 'gmail' -SourceKey $m.id `
                        -App 'Gmail' -AppId 'gmail' -OccurredAt ((Get-Date).ToString('o')) `
                        -Title $m.subject -Body $body -Link "https://mail.google.com/mail/u/0/#inbox/$($m.threadId)" `
                        -RawJson ($m | ConvertTo-Json -Depth 6 -Compress)
                if ($r.isNew) {
                    $new++
                    # 返信を作るときにスレッドへぶら下げるための識別子を残す
                    [void] $conn.NonQuery('UPDATE events SET context_fetched = ? WHERE id = ?',
                        [object[]] @((Get-Date).ToString('o'), $r.id))
                    Write-Host ("  新規: {0}" -f $m.subject) -ForegroundColor Green
                }
            }
            Write-Host ("Gmail: {0} 件中 {1} 件が新規" -f $msgs.Count, $new) -ForegroundColor Yellow
        }
    }
}
finally { $conn.Dispose() }
