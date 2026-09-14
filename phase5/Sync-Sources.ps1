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

    4. Microsoft 365 — Teams のチャットを掃き寄せて補完し、Outlook の受信トレイを
       取り込む。Slack / Gmail と同じ形 (掃き寄せ → 補完 → メール) にしてあるので、
       後段 (判定・カード・ワーカー) は経路ごとの分岐を持たない。

    5. Chatwork — ダイレクトチャットと自分宛メンションを掃き寄せる。

    6. Backlog — 自分宛のお知らせを取り込む。ここだけ掃き寄せが要らない
       (どれが自分宛かをサーバ側が決めてくれる唯一の経路)。

    どの経路も、繋がっているアカウントの数だけ回る。一つの連携先に複数の
    アカウントがあることがある (仕事用と個人用の Gmail、二つのワークスペースの
    Slack、二つの Backlog スペース) ―― 片方だけ見たのでは、もう片方に届いたものは
    このアプリを使っていないのと同じところに戻る。
    watermark も、イベントの主キーも、掃き寄せの対象もアカウント単位で分かれる。

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
    .\Sync-Sources.ps1 -SkipMicrosoft
#>
[CmdletBinding()]
param(
    [string]   $DbPath,
    [string]   $GmailQuery,
    [DateTime] $Since,
    [int]      $GmailMax = 200,
    [int]      $SlackMax = 30,
    [int]      $OutlookMax = 200,
    [int]      $TeamsMax = 30,
    [int]      $ChatworkMax = 30,
    [int]      $BacklogMax = 100,
    [switch]   $SkipSlack,
    [switch]   $SkipGmail,
    [switch]   $SkipMicrosoft,
    [switch]   $SkipChatwork,
    [switch]   $SkipBacklog
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\phase2\lib\TaskStore.ps1"
# 一つの連携先に複数のアカウントが繋がっている場合の名簿。
# 掃き寄せはこれを回して、全部のアカウントを同じ扱いで見る。
. "$PSScriptRoot\lib\AccountStore.ps1"
. "$PSScriptRoot\lib\SlackConnector.ps1"
. "$PSScriptRoot\lib\GmailConnector.ps1"
. "$PSScriptRoot\lib\GraphConnector.ps1"
. "$PSScriptRoot\lib\ChatworkConnector.ps1"
. "$PSScriptRoot\lib\BacklogConnector.ps1"

# 初回や watermark が無いときにどこまで遡るか。
# 長くすると初回に大量のカードが立つので、既定は控えめにする。
$BootstrapHours = 24

# watermark はアカウントごとに持つ。1人目だけは今までと同じキーを使うので、
# すでに動いている環境は続きから読まれる ―― ここが変わると、次の同期が
# 既定の 24 時間まで巻き戻って大量のカードを立てる。
function Get-StartPoint {
    param($Conn, [string] $Key, [string] $AccountId)
    if ($Since) { return $Since }
    $saved = Get-Setting -Conn $Conn -Key (Get-AccountScopedKey -Key $Key -AccountId $AccountId)
    if ($saved) {
        try { return [DateTime] $saved } catch { }
    }
    return (Get-Date).AddHours(-$BootstrapHours)
}

function Set-SyncPoint {
    param($Conn, [string] $Key, [string] $AccountId, [DateTime] $Value)
    Set-Setting -Conn $Conn -Key (Get-AccountScopedKey -Key $Key -AccountId $AccountId) `
        -Value $Value.ToString('o')
}

# 画面に出す「どのアカウントか」。1つしか繋いでいなければ空を返す ――
# 「Slack[1]」は、複数繋いでいない人にとっては意味の無い装飾でしかない。
function Get-SyncAccountTag {
    param([string] $Service, [string] $Id)
    $n = Get-AccountDisplayName -Service $Service -Id $Id
    if (-not $n) { return '' }
    return ("[{0}]" -f $n)
}

$conn = Open-TaskStore -Path $DbPath
try {
    # ---------------- Slack: 前回の続きから拾い、スレッド全文を足す ----------------
    #
    # アカウントごとに丸ごと1回ずつ回す。掃き寄せと補完を同じ回に入れてあるのは、
    # 補完が**そのアカウントのトークンでしか読めない**ため ―― 別のアカウントに
    # 切り替わったあとで前のワークスペースのスレッドを取りに行っても読めない。
    if (-not $SkipSlack) {
        foreach ($acct in @(Get-ServiceAccounts -Service 'slack')) {
            [void] (Use-ServiceAccount -Service 'slack' -Id $acct.id)
            $tag = Get-SyncAccountTag -Service 'slack' -Id $acct.id
            if (-not (Test-SlackConfigured)) {
                Write-Host ("Slack{0}: 未設定のため飛ばします" -f $tag) -ForegroundColor DarkGray
                continue
            }
            $from = Get-StartPoint $conn 'sync.slack.lastTs' $acct.id
            $self = Get-SlackSelfUserId
            if (-not $self) {
                # メンション判定ができないと、拾えるのは DM と既知スレッドの続きだけになる
                Write-Host '  注意: 自分の Slack ユーザーIDが不明です。メンションを拾えません。' -ForegroundColor Yellow
                Write-Host '        カンバンのヘッダの「接続」から設定できます。' -ForegroundColor DarkGray
            }
            Write-Host ("Slack{0}: {1} 以降を掃き寄せ" -f $tag, $from.ToString('MM/dd HH:mm')) -ForegroundColor Cyan

            # すでにカードがあるスレッドは「会話の続き」として拾う対象にする。
            # **このアカウントで取り込んだものだけ**を見ること ―― 別のワークスペースの
            # チャンネル ID を混ぜると、読めない会話を毎回叩きに行くだけになる。
            $knownKeys = @()
            foreach ($r in $conn.Query(
                "SELECT link FROM events WHERE link LIKE 'slack://%' AND COALESCE(account_id, '1') = ?",
                [object[]] @($acct.id))) {
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
                            -DedupKey (New-EventIdentity -Kind 'slack' -Parts @($m.channel, $m.ts)) `
                            -AccountId $acct.id
                    if ($r.isNew) {
                        $new++
                        Write-Host ("  新規[{0}]: {1} / {2}" -f $m.reason, $ch, $who) -ForegroundColor Green
                    }
                }
                Write-Host ("Slack{0}: {1} 件該当 / {2} 件が新規" -f $tag, $sweep.messages.Count, $new) -ForegroundColor Yellow

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
                    Set-SyncPoint -Conn $conn -Key 'sync.slack.lastTs' -AccountId $acct.id -Value $sweepStart.AddMinutes(-2)
                }
            }
            catch {
                Write-Host ("Slack{0}: 掃き寄せに失敗しました: {1}" -f $tag, $_.Exception.Message) -ForegroundColor Red
            }

            # ---- ここから、このアカウントのイベントにスレッド全文を足す ----
            $rows = @($conn.Query(
                "SELECT id, link, body FROM events
                  WHERE link LIKE 'slack://%' AND context_fetched IS NULL AND COALESCE(account_id, '1') = ?
                  ORDER BY occurred_at DESC LIMIT ?", [object[]] @($acct.id, $SlackMax)))
            Write-Host ("Slack{0}: 補完対象 {1} 件" -f $tag, $rows.Count) -ForegroundColor Cyan

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
    }

    # ---------------- Gmail: メールをイベントにする ----------------
    if (-not $SkipGmail) {
        foreach ($acct in @(Get-ServiceAccounts -Service 'google')) {
            [void] (Use-ServiceAccount -Service 'google' -Id $acct.id)
            $tag = Get-SyncAccountTag -Service 'google' -Id $acct.id
            if (-not (Test-GmailConfigured)) {
                Write-Host ("Gmail{0}: 未設定のため飛ばします" -f $tag) -ForegroundColor DarkGray
                continue
            }
            # 既定は watermark から。is:unread では絞らない ―― スマホで先に読んだメールは
            # 既読になってしまい、二度と取り込まれないため。
            $manual = [bool] $GmailQuery
            $q = $GmailQuery
            if (-not $q) {
                $from = Get-StartPoint $conn 'sync.gmail.lastInternalDate' $acct.id
                $q = "in:inbox after:{0}" -f ([DateTimeOffset] $from).ToUnixTimeSeconds()
            }
            Write-Host ("Gmail{0}: 検索 '{1}'" -f $tag, $q) -ForegroundColor Cyan

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
                        -DedupKey (New-EventIdentity -Kind 'mail' -Parts @($m.subject, (Get-MailDisplayName $m.from))) `
                        -AccountId $acct.id
                if ($r.isNew) {
                    $new++
                    # 返信を作るときにスレッドへぶら下げるための識別子を残す
                    [void] $conn.NonQuery('UPDATE events SET context_fetched = ? WHERE id = ?',
                        [object[]] @((Get-Date).ToString('o'), $r.id))
                    Write-Host ("  新規: {0}" -f $m.subject) -ForegroundColor Green
                }
                if ($m.internalDate -gt $maxInternal) { $maxInternal = [long] $m.internalDate }
            }
            Write-Host ("Gmail{0}: {1} 件中 {2} 件が新規" -f $tag, $msgs.Count, $new) -ForegroundColor Yellow

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
                Set-SyncPoint -Conn $conn -Key 'sync.gmail.lastInternalDate' -AccountId $acct.id -Value $mark
            }

        }
    }

    # ---------------- Microsoft 365: Teams と Outlook ----------------
    #
    # 入口のアプリ登録が同じなので、アカウントも一つで数える。
    # 1アカウントぶんを Teams 掃き寄せ → Teams 補完 → Outlook の順に通し切ってから
    # 次のアカウントへ移る (途中で切り替えると、補完が別テナントのトークンで走る)。
    if (-not $SkipMicrosoft) {
        foreach ($acct in @(Get-ServiceAccounts -Service 'microsoft')) {
            [void] (Use-ServiceAccount -Service 'microsoft' -Id $acct.id)
            $tag = Get-SyncAccountTag -Service 'microsoft' -Id $acct.id
            if (-not (Test-GraphConfigured)) {
                Write-Host ("Microsoft 365{0}: 未設定のため飛ばします" -f $tag) -ForegroundColor DarkGray
                continue
            }
            $from = Get-StartPoint $conn 'sync.teams.lastTs' $acct.id
            Write-Host ("Teams{0}: {1} 以降を掃き寄せ" -f $tag, $from.ToString('MM/dd HH:mm')) -ForegroundColor Cyan
            $sweepStart = Get-Date
            try {
                $sweep = Get-TeamsUpdates -Since $from -MaxChats $TeamsMax
                $new = 0
                foreach ($m in $sweep.messages) {
                    # 本文はここでは通知相当のものにしておく。会話の前後は次の補完段で足す
                    # (同じ経路を二度書かないため)。
                    $r = Add-Event -Conn $conn -Source 'teams' -SourceKey ("{0}|{1}" -f $m.chatId, $m.messageId) `
                            -App 'Microsoft Teams' -AppId 'teams' -OccurredAt $m.createdAt.ToString('o') `
                            -Title ("{0} / {1}" -f $m.chatName, $m.sender) `
                            -Body $m.text `
                            -Link (New-TeamsLink -ChatId $m.chatId -MessageId $m.messageId) `
                            -RawJson ($m | ConvertTo-Json -Depth 6 -Compress) `
                            -DedupKey (New-EventIdentity -Kind 'teams' -Parts @($m.sender, $m.text)) `
                            -AccountId $acct.id
                    if ($r.isNew) {
                        $new++
                        # カンバンの「元を開く」はここを使う。msteams:// と違い
                        # ブラウザからそのまま開ける (返らないことがあるので、その時は据え置く)。
                        if ($m.webUrl) {
                            [void] $conn.NonQuery('UPDATE events SET permalink = ? WHERE id = ?',
                                [object[]] @([string] $m.webUrl, $r.id))
                        }
                        Write-Host ("  新規[{0}]: {1} / {2}" -f $m.reason, $m.chatName, $m.sender) -ForegroundColor Green
                    }
                }
                Write-Host ("Teams{0}: {1} 件該当 / {2} 件が新規" -f $tag, $sweep.messages.Count, $new) -ForegroundColor Yellow

                $retryable = @($sweep.errors | Where-Object { -not $_.permanent })
                foreach ($e in $sweep.errors) {
                    $color = if ($e.permanent) { 'DarkGray' } else { 'Yellow' }
                    Write-Host ("  読めない会話: {0} ({1})" -f $e.chat, $e.message) -ForegroundColor $color
                }
                if ($retryable.Count -gt 0) {
                    # Slack 側と同じ判断。一時的な失敗のまま watermark を進めると
                    # その範囲が取りこぼしになり、恒久的な失敗で止め続けると
                    # 読める会話の分まで永久に入らない。
                    Write-Host ("  {0} 件を一時的な理由で読めなかったため、次回も同じ範囲を読み直します" -f $retryable.Count) -ForegroundColor Yellow
                }
                elseif (-not $Since) {
                    Set-SyncPoint -Conn $conn -Key 'sync.teams.lastTs' -AccountId $acct.id -Value $sweepStart.AddMinutes(-2)
                }
            }
            catch {
                Write-Host ("Teams{0}: 掃き寄せに失敗しました: {1}" -f $tag, $_.Exception.Message) -ForegroundColor Red
            }

            # ---- このアカウントのイベントに会話の前後を足す ----
            $rows = @($conn.Query(
                "SELECT id, link, body FROM events
                  WHERE link LIKE 'msteams://%' AND context_fetched IS NULL AND COALESCE(account_id, '1') = ?
                  ORDER BY occurred_at DESC LIMIT ?", [object[]] @($acct.id, $TeamsMax)))
            Write-Host ("Teams{0}: 補完対象 {1} 件" -f $tag, $rows.Count) -ForegroundColor Cyan

            foreach ($r in $rows) {
                $id = [string] $r['id']
                try {
                    $t = Get-TeamsThread -Link ([string] $r['link'])
                    if (-not $t) {
                        [void] $conn.NonQuery('UPDATE events SET context_fetched = ? WHERE id = ?',
                            [object[]] @('unsupported', $id))
                        continue
                    }
                    $newBody = ("{0}`n`n--- 会話 ({1} 件) ---`n{2}" -f $r['body'], $t.messageCount, $t.text)
                    # permalink が取れなかったときに既存の値を消さない
                    # (掃き寄せの時点で入っていることがある)。
                    if ($t.permalink) {
                        [void] $conn.NonQuery(
                            'UPDATE events SET body = ?, permalink = ?, context_fetched = ? WHERE id = ?',
                            [object[]] @($newBody, $t.permalink, (Get-Date).ToString('o'), $id))
                    }
                    else {
                        [void] $conn.NonQuery(
                            'UPDATE events SET body = ?, context_fetched = ? WHERE id = ?',
                            [object[]] @($newBody, (Get-Date).ToString('o'), $id))
                    }
                    Write-Host ("  補完: {0} ({1} 件のメッセージ)" -f $t.chat, $t.messageCount) -ForegroundColor Green
                }
                catch {
                    Write-Host ("  失敗: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                    [void] $conn.NonQuery('UPDATE events SET context_fetched = ? WHERE id = ?',
                        [object[]] @('error', $id))
                }
            }

            # ---- このアカウントの受信トレイ ----
            $from = Get-StartPoint $conn 'sync.outlook.lastReceived' $acct.id
            Write-Host ("Outlook{0}: {1} 以降の受信トレイ" -f $tag, $from.ToString('MM/dd HH:mm')) -ForegroundColor Cyan

            $fetchStart = Get-Date
            $msgs = @()
            $failed = $false
            try { $msgs = @(Get-OutlookRecent -Since $from -Max $OutlookMax) }
            catch {
                $failed = $true
                Write-Host ("Outlook{0}: 取り込みに失敗しました: {1}" -f $tag, $_.Exception.Message) -ForegroundColor Red
            }

            if (-not $failed) {
                $new = 0
                $maxReceived = $null
                foreach ($m in $msgs) {
                    # 本文の先頭は Gmail 側と同じ形にする。件のキー (Get-MailSender) が
                    # 「差出人:」の行を読むので、ここが揃っていないと同じ件がまとまらない。
                    $body = "差出人: $($m.from)`n宛先: $($m.to)"
                    if ($m.cc) { $body += "`nCc: $($m.cc)" }
                    $when = if ($m.receivedAt) { $m.receivedAt } else { Get-Date }
                    $body += "`n日時: $($when.ToString('yyyy-MM-dd HH:mm'))`n`n$($m.body)"

                    $link = $m.webLink
                    $r = Add-Event -Conn $conn -Source 'outlook' -SourceKey $m.id `
                            -App 'Outlook' -AppId 'outlook' -OccurredAt $when.ToString('o') `
                            -Title $m.subject -Body $body -Link $link `
                            -RawJson ($m | ConvertTo-Json -Depth 6 -Compress) `
                            -DedupKey (New-EventIdentity -Kind 'outlook' -Parts @($m.subject, (Get-MailDisplayName $m.from))) `
                            -AccountId $acct.id
                    if ($r.isNew) {
                        $new++
                        # 返信をスレッドにぶら下げる識別子は raw_json に入っている。
                        # 取り直しは要らないので、補完済みとして印を付ける。
                        [void] $conn.NonQuery('UPDATE events SET context_fetched = ?, permalink = ? WHERE id = ?',
                            [object[]] @((Get-Date).ToString('o'), $link, $r.id))
                        Write-Host ("  新規: {0}" -f $m.subject) -ForegroundColor Green
                    }
                    if (-not $maxReceived -or $when -gt $maxReceived) { $maxReceived = $when }
                }
                Write-Host ("Outlook{0}: {1} 件中 {2} 件が新規" -f $tag, $msgs.Count, $new) -ForegroundColor Yellow

                if ($msgs.Count -ge $OutlookMax) {
                    # 上限で切れている。進めると残りが飛ぶ。
                    Write-Host ("  上限 {0} 件に達しました。-OutlookMax を上げてもう一度実行してください" -f $OutlookMax) -ForegroundColor Yellow
                }
                elseif (-not $Since) {
                    # 取り切れたので watermark を進める。新着 0 件でも必ず書く
                    # (Gmail 側と同じ理由 ―― 静かな日が続くと watermark が生まれず、
                    #  丸一日以上 PC を落とした穴が二度と埋まらなくなる)。
                    $mark = $fetchStart.AddMinutes(-2)
                    if ($maxReceived -and $maxReceived -gt $mark) { $mark = $maxReceived }
                    Set-SyncPoint -Conn $conn -Key 'sync.outlook.lastReceived' -AccountId $acct.id -Value $mark
                }
            }
        }
    }

    # ---------------- Chatwork: 前回の続きから拾い、部屋の流れを足す ----------------
    if (-not $SkipChatwork) {
        foreach ($acct in @(Get-ServiceAccounts -Service 'chatwork')) {
            [void] (Use-ServiceAccount -Service 'chatwork' -Id $acct.id)
            $tag = Get-SyncAccountTag -Service 'chatwork' -Id $acct.id
            if (-not (Test-ChatworkConfigured)) {
                Write-Host ("Chatwork{0}: 未設定のため飛ばします" -f $tag) -ForegroundColor DarkGray
                continue
            }
            $from = Get-StartPoint $conn 'sync.chatwork.lastTs' $acct.id
            Write-Host ("Chatwork{0}: {1} 以降を掃き寄せ" -f $tag, $from.ToString('MM/dd HH:mm')) -ForegroundColor Cyan
            $sweepStart = Get-Date
            try {
                if (-not (Get-ChatworkSelfId)) {
                    # 自分が分からないとメンションを判定できず、拾えるのは DM だけになる
                    Write-Host '  注意: 自分のアカウント ID が不明です。メンションを拾えません。' -ForegroundColor Yellow
                }
                $sweep = Get-ChatworkUpdates -Since $from -MaxRooms $ChatworkMax
                $new = 0
                foreach ($m in $sweep.messages) {
                    $link = New-ChatworkLink -RoomId $m.roomId -MessageId $m.messageId
                    $r = Add-Event -Conn $conn -Source 'chatwork' -SourceKey ("{0}|{1}" -f $m.roomId, $m.messageId) `
                            -App 'Chatwork' -AppId 'chatwork' -OccurredAt $m.createdAt.ToString('o') `
                            -Title ("{0} / {1}" -f $m.roomName, $m.sender) `
                            -Body $m.text -Link $link `
                            -RawJson ($m | ConvertTo-Json -Depth 6 -Compress) `
                            -DedupKey (New-EventIdentity -Kind 'chatwork' -Parts @($m.sender, $m.text)) `
                            -AccountId $acct.id
                    if ($r.isNew) {
                        $new++
                        # link がそのままブラウザで開ける https なので permalink も同じもの。
                        [void] $conn.NonQuery('UPDATE events SET permalink = ? WHERE id = ?',
                            [object[]] @($link, $r.id))
                        Write-Host ("  新規[{0}]: {1} / {2}" -f $m.reason, $m.roomName, $m.sender) -ForegroundColor Green
                    }
                }
                Write-Host ("Chatwork{0}: {1} 件該当 / {2} 件が新規" -f $tag, $sweep.messages.Count, $new) -ForegroundColor Yellow

                $retryable = @($sweep.errors | Where-Object { -not $_.permanent })
                foreach ($e in $sweep.errors) {
                    $color = if ($e.permanent) { 'DarkGray' } else { 'Yellow' }
                    Write-Host ("  読めない部屋: {0} ({1})" -f $e.room, $e.message) -ForegroundColor $color
                }
                if ($sweep.truncated) {
                    # 1部屋 100 件の上限で切れている。進めると間が飛ぶ。
                    Write-Host '  100 件の上限で切れた部屋があります。次回も同じ範囲を読み直します' -ForegroundColor Yellow
                }
                elseif ($retryable.Count -gt 0) {
                    Write-Host ("  {0} 件を一時的な理由で読めなかったため、次回も同じ範囲を読み直します" -f $retryable.Count) -ForegroundColor Yellow
                }
                elseif (-not $Since) {
                    Set-SyncPoint -Conn $conn -Key 'sync.chatwork.lastTs' -AccountId $acct.id -Value $sweepStart.AddMinutes(-2)
                }
            }
            catch {
                Write-Host ("Chatwork{0}: 掃き寄せに失敗しました: {1}" -f $tag, $_.Exception.Message) -ForegroundColor Red
            }

            # ---- このアカウントのイベントに部屋の流れを足す ----
            $rows = @($conn.Query(
                "SELECT id, link, body FROM events
                  WHERE source = 'chatwork' AND context_fetched IS NULL AND COALESCE(account_id, '1') = ?
                  ORDER BY occurred_at DESC LIMIT ?", [object[]] @($acct.id, $ChatworkMax)))
            Write-Host ("Chatwork{0}: 補完対象 {1} 件" -f $tag, $rows.Count) -ForegroundColor Cyan

            foreach ($r in $rows) {
                $id = [string] $r['id']
                try {
                    $t = Get-ChatworkThread -Link ([string] $r['link'])
                    if (-not $t) {
                        [void] $conn.NonQuery('UPDATE events SET context_fetched = ? WHERE id = ?',
                            [object[]] @('unsupported', $id))
                        continue
                    }
                    $newBody = ("{0}`n`n--- 直近のやり取り ({1} 件) ---`n{2}" -f $r['body'], $t.messageCount, $t.text)
                    [void] $conn.NonQuery('UPDATE events SET body = ?, context_fetched = ? WHERE id = ?',
                        [object[]] @($newBody, (Get-Date).ToString('o'), $id))
                    Write-Host ("  補完: {0} ({1} 件のメッセージ)" -f $t.room, $t.messageCount) -ForegroundColor Green
                }
                catch {
                    Write-Host ("  失敗: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                    [void] $conn.NonQuery('UPDATE events SET context_fetched = ? WHERE id = ?',
                        [object[]] @('error', $id))
                }
            }
        }
    }

    # ---------------- Backlog: 自分宛のお知らせを取り込む ----------------
    if (-not $SkipBacklog) {
        foreach ($acct in @(Get-ServiceAccounts -Service 'backlog')) {
            [void] (Use-ServiceAccount -Service 'backlog' -Id $acct.id)
            $tag = Get-SyncAccountTag -Service 'backlog' -Id $acct.id
            if (-not (Test-BacklogConfigured)) {
                Write-Host ("Backlog{0}: 未設定のため飛ばします" -f $tag) -ForegroundColor DarkGray
                continue
            }
            $from = Get-StartPoint $conn 'sync.backlog.lastCreated' $acct.id
            Write-Host ("Backlog{0}: {1} 以降のお知らせ" -f $tag, $from.ToString('MM/dd HH:mm')) -ForegroundColor Cyan
            $fetchStart = Get-Date
            try {
                $res = Get-BacklogNotifications -Since $from -Max $BacklogMax
                $new = 0
                $maxCreated = $null
                foreach ($n in $res.items) {
                    # 本文は「何が起きたか」+ コメント + 課題の説明。
                    # 課題の全文と経緯は、必要になった1枚だけワーカーが取り直す。
                    $body = ("{0}: [{1}] {2}" -f $n.reason, $n.issueKey, $n.summary)
                    if ($n.sender)  { $body += "`n実行者: $($n.sender)" }
                    if ($n.comment) { $body += "`n`n--- コメント ---`n$($n.comment)" }
                    elseif ($n.description) { $body += "`n`n--- 課題の説明 ---`n$($n.description)" }

                    $r = Add-Event -Conn $conn -Source 'backlog' -SourceKey $n.id `
                            -App 'Backlog' -AppId 'backlog' -OccurredAt $n.createdAt.ToString('o') `
                            -Title ("[{0}] {1}" -f $n.issueKey, $n.summary) `
                            -Body $body -Link $n.link `
                            -RawJson ($n | ConvertTo-Json -Depth 6 -Compress) `
                            -AccountId $acct.id
                    if ($r.isNew) {
                        $new++
                        [void] $conn.NonQuery('UPDATE events SET permalink = ? WHERE id = ?',
                            [object[]] @($n.link, $r.id))
                        Write-Host ("  新規: [{0}] {1}" -f $n.issueKey, $n.reason) -ForegroundColor Green
                    }
                    if (-not $maxCreated -or $n.createdAt -gt $maxCreated) { $maxCreated = $n.createdAt }
                }
                Write-Host ("Backlog{0}: {1} 件中 {2} 件が新規" -f $tag, $res.items.Count, $new) -ForegroundColor Yellow

                if ($res.truncated) {
                    Write-Host ("  1ページ ({0} 件) に収まりませんでした。-BacklogMax を上げてもう一度実行してください" -f $BacklogMax) -ForegroundColor Yellow
                }
                elseif (-not $Since) {
                    # 取り切れたので進める。新着 0 件でも書く (他の経路と同じ理由)。
                    $mark = $fetchStart.AddMinutes(-2)
                    if ($maxCreated -and $maxCreated -gt $mark) { $mark = $maxCreated }
                    Set-SyncPoint -Conn $conn -Key 'sync.backlog.lastCreated' -AccountId $acct.id -Value $mark
                }
            }
            catch {
                Write-Host ("Backlog{0}: 取り込みに失敗しました: {1}" -f $tag, $_.Exception.Message) -ForegroundColor Red
            }

        }
    }
}
finally { $conn.Dispose() }
