<#
.SYNOPSIS
    Phase 5: 正規 API から実データを取り込み、通知だけでは足りない文脈を補う。

.DESCRIPTION
    通知は「速いが穴が開く」経路でしかない。PC が落ちていればトーストは配信されず、
    起動していても wpndatabase は十数件しか保持しないので、Phase 1 を止めていた間は
    そのまま消える。だから通知は起点 (低遅延のトリガ) と割り切り、
    **取りこぼしの無さはこちらの watermark 同期で担保する。**

    やることは3つ。順番に意味がある。

    1. Slack の掃き寄せ — 前回の続き (settings の sync.slack.lastTs) から
       conversations.history を読み、自分に関係のあるものだけをイベントにする。
       通知が来ていなくても拾える。

    2. Slack の補完 — slack:// リンクを持つイベントについて conversations.replies で
       スレッド全文と permalink を取る。1 が作ったイベントもここで中身が埋まるので、
       掃き寄せは先に走らせる。

    3. Gmail の取り込み — 前回の続き (sync.gmail.lastInternalDate) から after: で引く。
       何日 PC を落としていても、次に動かしたときに穴が埋まる。

    すべて冪等。同じものを何度取り込んでも events の UNIQUE 制約で弾かれる。
    watermark は「取り切れた」ときだけ進める。途中で失敗したら次回もう一度読み直す。

.PARAMETER GmailQuery
    Gmail の検索式を明示する。指定した場合は手動の掘り起こしとみなし、watermark は動かさない。

.PARAMETER Since
    watermark を無視して、この日時以降を取り直す。取りこぼしに気付いたときの復旧用。

.EXAMPLE
    .\Sync-Sources.ps1
    .\Sync-Sources.ps1 -Since (Get-Date).AddDays(-3)
    .\Sync-Sources.ps1 -GmailQuery 'in:inbox newer_than:7d' -SkipSlack
#>
[CmdletBinding()]
param(
    [string]   $DbPath,
    [string]   $GmailQuery,
    [DateTime] $Since,
    [int]      $GmailMax = 200,
    [int]      $SlackMax = 30,
    [switch]   $SkipSlack,
    [switch]   $SkipGmail
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\phase2\lib\TaskStore.ps1"
. "$PSScriptRoot\lib\SlackConnector.ps1"
. "$PSScriptRoot\lib\GmailConnector.ps1"

# 初回や watermark が無いときにどこまで遡るか。
# 長くすると初回に大量のカードが立つので、既定は控えめにする。
$BootstrapHours = 24

function Get-StartPoint {
    param($Conn, [string] $Key)
    if ($Since) { return $Since }
    $saved = Get-Setting -Conn $Conn -Key $Key
    if ($saved) {
        try { return [DateTime] $saved } catch { }
    }
    return (Get-Date).AddHours(-$BootstrapHours)
}

$conn = Open-TaskStore -Path $DbPath
try {
    # ---------------- Slack: 前回の続きから拾う ----------------
    if (-not $SkipSlack) {
        if (-not (Test-SlackConfigured)) {
            Write-Host 'Slack: 未設定のため飛ばします' -ForegroundColor DarkGray
        }
        else {
            $from = Get-StartPoint $conn 'sync.slack.lastTs'
            $self = Get-SlackSelfUserId
            if (-not $self) {
                # メンション判定ができないと、拾えるのは DM と既知スレッドの続きだけになる
                Write-Host '  注意: 自分の Slack ユーザーIDが不明です。メンションを拾えません。' -ForegroundColor Yellow
                Write-Host '        Connect-Service.ps1 -Service slack で設定できます。' -ForegroundColor DarkGray
            }
            Write-Host ("Slack: {0} 以降を掃き寄せ" -f $from.ToString('MM/dd HH:mm')) -ForegroundColor Cyan

            # すでにカードがあるスレッドは「会話の続き」として拾う対象にする
            $knownKeys = @()
            foreach ($r in $conn.Query("SELECT link FROM events WHERE link LIKE 'slack://%'")) {
                $ref = ConvertFrom-SlackLink ([string] $r['link'])
                if ($ref) { $knownKeys += (ConvertTo-SlackThreadKey $ref.channel $ref.threadTs) }
            }

            $sweepStart = Get-Date
            try {
                $sinceTs = [string] ([DateTimeOffset] $from).ToUnixTimeSeconds()
                $sweep = Get-SlackUpdates -SinceTs $sinceTs -KnownThreadKeys $knownKeys
                $new = 0
                foreach ($m in $sweep.messages) {
                    $when = $null
                    try { $when = [DateTimeOffset]::FromUnixTimeSeconds([long][double] $m.ts).LocalDateTime } catch { $when = Get-Date }
                    $who = Resolve-SlackUser $m.user
                    $ch  = Resolve-SlackChannel $m.channel
                    # 本文はここでは通知相当の短いものにしておく。
                    # スレッド全文は次の補完段で足す (同じ経路を二度書かないため)。
                    $r = Add-Event -Conn $conn -Source 'slack' -SourceKey ("{0}|{1}" -f $m.channel, $m.ts) `
                            -App 'Slack' -AppId 'slack' -OccurredAt $when.ToString('o') `
                            -Title ("{0} / {1}" -f $ch, $who) `
                            -Body (Expand-SlackText $m.text) `
                            -Link (New-SlackLink -Channel $m.channel -Ts $m.ts -ThreadTs $m.threadTs) `
                            -RawJson ($m | ConvertTo-Json -Depth 6 -Compress) `
                            -DedupKey (New-EventIdentity -Kind 'slack' -Parts @($m.channel, $m.ts))
                    if ($r.isNew) {
                        $new++
                        Write-Host ("  新規[{0}]: {1} / {2}" -f $m.reason, $ch, $who) -ForegroundColor Green
                    }
                }
                Write-Host ("Slack: {0} 件該当 / {1} 件が新規" -f $sweep.messages.Count, $new) -ForegroundColor Yellow

                $retryable = @($sweep.errors | Where-Object { -not $_.permanent })
                foreach ($e in $sweep.errors) {
                    # 権限やチャンネル構成の問題は毎回同じものが出るので淡く、
                    # 直せば読めるようになるもの (レート制限・通信断) は目立たせる
                    $color = if ($e.permanent) { 'DarkGray' } else { 'Yellow' }
                    Write-Host ("  読めない会話: {0} ({1})" -f $e.channel, $e.message) -ForegroundColor $color
                }
                if ($retryable.Count -gt 0) {
                    # 一時的な失敗のまま watermark を進めると、その範囲が取りこぼしになる。
                    # 逆に権限不足で止め続けると、読める会話の分まで永久に入らない。
                    Write-Host ("  {0} 件を一時的な理由で読めなかったため、次回も同じ範囲を読み直します" -f $retryable.Count) -ForegroundColor Yellow
                }
                elseif (-not $Since) {
                    # 掃き寄せ中に届いたものを落とさないよう、開始時刻から少し戻す。
                    # 重複しても UNIQUE で弾かれるので、戻しすぎる分には害がない。
                    Set-Setting -Conn $conn -Key 'sync.slack.lastTs' -Value $sweepStart.AddMinutes(-2).ToString('o')
                }
            }
            catch {
                Write-Host ("Slack: 掃き寄せに失敗しました: {0}" -f $_.Exception.Message) -ForegroundColor Red
            }
        }
    }

    # ---------------- Slack: イベントにスレッド全文を足す ----------------
    if (-not $SkipSlack -and (Test-SlackConfigured)) {
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
                # permalink はカンバンから元の会話へ飛ぶために残す。
                # slack:// と違いブラウザからそのまま開ける。
                [void] $conn.NonQuery(
                    'UPDATE events SET body = ?, permalink = ?, context_fetched = ? WHERE id = ?',
                    [object[]] @($newBody, $t.permalink, (Get-Date).ToString('o'), $id))
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

    # ---------------- Gmail: メールをイベントにする ----------------
    if (-not $SkipGmail) {
        if (-not (Test-GmailConfigured)) {
            Write-Host 'Gmail: 未設定のため飛ばします' -ForegroundColor DarkGray
        }
        else {
            # 既定は watermark から。is:unread では絞らない ―― スマホで先に読んだメールは
            # 既読になってしまい、二度と取り込まれないため。
            $manual = [bool] $GmailQuery
            $q = $GmailQuery
            if (-not $q) {
                $from = Get-StartPoint $conn 'sync.gmail.lastInternalDate'
                $q = "in:inbox after:{0}" -f ([DateTimeOffset] $from).ToUnixTimeSeconds()
            }
            Write-Host ("Gmail: 検索 '{0}'" -f $q) -ForegroundColor Cyan

            $fetchStart = Get-Date
            $msgs = @(Get-GmailRecent -Query $q -Max $GmailMax)
            $new = 0
            $maxInternal = 0
            foreach ($m in $msgs) {
                $body = "差出人: $($m.from)`n宛先: $($m.to)"
                if ($m.cc) { $body += "`nCc: $($m.cc)" }
                $body += "`n日時: $($m.date)`n`n$($m.body)"

                # occurred_at は受信時刻 (internalDate)。取り込み時刻を入れると、
                # 何日ぶんかまとめて取ったときに全部「いま」になって並びが壊れる。
                $occurred = if ($m.receivedAt) { $m.receivedAt.ToString('o') } else { (Get-Date).ToString('o') }

                $r = Add-Event -Conn $conn -Source 'gmail' -SourceKey $m.id `
                        -App 'Gmail' -AppId 'gmail' -OccurredAt $occurred `
                        -Title $m.subject -Body $body -Link "https://mail.google.com/mail/u/0/#inbox/$($m.threadId)" `
                        -RawJson ($m | ConvertTo-Json -Depth 6 -Compress) `
                        -DedupKey (New-EventIdentity -Kind 'mail' -Parts @($m.subject, (Get-MailDisplayName $m.from)))
                if ($r.isNew) {
                    $new++
                    # 返信を作るときにスレッドへぶら下げるための識別子を残す
                    [void] $conn.NonQuery('UPDATE events SET context_fetched = ? WHERE id = ?',
                        [object[]] @((Get-Date).ToString('o'), $r.id))
                    Write-Host ("  新規: {0}" -f $m.subject) -ForegroundColor Green
                }
                if ($m.internalDate -gt $maxInternal) { $maxInternal = [long] $m.internalDate }
            }
            Write-Host ("Gmail: {0} 件中 {1} 件が新規" -f $msgs.Count, $new) -ForegroundColor Yellow

            if ($msgs.Count -ge $GmailMax) {
                # 上限で切れている。watermark を進めると残りが飛ぶので進めない。
                Write-Host ("  上限 {0} 件に達しました。-GmailMax を上げてもう一度実行してください" -f $GmailMax) -ForegroundColor Yellow
            }
            elseif (-not $manual -and -not $Since) {
                # 取り切れたので watermark を進める。
                # 新着が 0 件でも必ず書く ―― ここを「1件でも取れたとき」に限ると、
                # 静かな日が続くかぎり watermark が生まれず、既定の 24 時間だけを
                # 見続けることになる。それだと丸一日以上 PC を落とした穴は
                # 二度と埋まらない (これが「落としている間のメールを拾わない」原因)。
                #
                # 検索は開始時刻までを上限なしで見ているので、それより前は取り切れている。
                # 取得中に届いたものを落とさないよう少し戻す。重複は UNIQUE で弾かれる。
                $mark = $fetchStart.AddMinutes(-2)
                if ($maxInternal -gt 0) {
                    $last = [DateTimeOffset]::FromUnixTimeMilliseconds($maxInternal).LocalDateTime
                    if ($last -gt $mark) { $mark = $last }
                }
                Set-Setting -Conn $conn -Key 'sync.gmail.lastInternalDate' -Value $mark.ToString('o')
            }
        }
    }
}
finally { $conn.Dispose() }
