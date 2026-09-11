<#
.SYNOPSIS
    Phase 2: Phase 1 が集めた通知を取り込み、対応要否を判定してタスク化する。

.DESCRIPTION
    パイプライン: notifications.jsonl → events → (ルール前段フィルタ) → Claude 判定 → tasks

    ルール前段フィルタを先に通すのは、全通知を LLM に投げるとコストが無駄になるため。
    システム通知の類は policy.json の ignore に書いておけば API を消費しない。

.PARAMETER DryRun
    LLM を呼ばず、ルール判定の結果だけを表示する。書き込みも行わない。
    ANTHROPIC_API_KEY が無くても配線を確認できる。

.EXAMPLE
    .\Invoke-Triage.ps1 -DryRun
    $env:ANTHROPIC_API_KEY = '...'; .\Invoke-Triage.ps1
#>
[CmdletBinding()]
param(
    [string] $JsonlPath,
    [string] $PolicyPath,
    [string] $DbPath,
    [switch] $DryRun,
    [int]    $Limit = 100,
    # 同期が拾う経路の通知を、同期版の到着を待って判定する猶予 (分)。
    # 0 にすると待たず、通知で先にカードを立てて後から差し替える動きになる。
    [int]    $DeferMinutes = 5
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\TaskStore.ps1"
. "$PSScriptRoot\lib\ClaudeClient.ps1"
. "$PSScriptRoot\lib\Dossier.ps1"
# Slack のリンクから件のキーを作るのに使う (未設定なら無くても動く)
$slackLibPath = Join-Path $PSScriptRoot '..\phase5\lib\SlackConnector.ps1'
if (Test-Path $slackLibPath) { . $slackLibPath }

if (-not $JsonlPath)  { $JsonlPath  = Join-Path $PSScriptRoot '..\phase1\data\notifications.jsonl' }
if (-not $PolicyPath) { $PolicyPath = Join-Path $PSScriptRoot 'config\policy.json' }

$policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------------------------------------------------------------- ルール前段フィルタ

function Test-AnyPattern {
    param([string] $Value, $Patterns)
    if (-not $Value -or -not $Patterns) { return $false }
    foreach ($p in $Patterns) {
        if ($p -and $Value -like $p) { return $true }
    }
    return $false
}

# 戻り値: $null なら LLM に回す。文字列ならルール名 (= 捨てる理由)。
function Get-IgnoreRule {
    param($Evt, $Policy)
    if (Test-AnyPattern ([string] $Evt['app_id']) $Policy.ignore.appIdPatterns) { return 'ignore.appId' }
    if (Test-AnyPattern ([string] $Evt['title'])  $Policy.ignore.titlePatterns) { return 'ignore.title' }
    if ($Policy.watch.appIdPatterns -and $Policy.watch.appIdPatterns.Count -gt 0) {
        if (-not (Test-AnyPattern ([string] $Evt['app_id']) $Policy.watch.appIdPatterns)) { return 'not-watched' }
    }
    return $null
}

# ---------------------------------------------------------------- 取り込み

function Import-Notifications {
    param($Conn, [string] $Path)
    if (-not (Test-Path $Path)) {
        Write-Host "notifications.jsonl が見つかりません: $Path" -ForegroundColor Yellow
        Write-Host "先に phase1\Get-Notifications.ps1 を実行してください。" -ForegroundColor Yellow
        return 0
    }
    $added = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        try { $n = $line | ConvertFrom-Json } catch { continue }
        $r = Add-Event -Conn $Conn -Source 'notification' -SourceKey $n.key `
                -App $n.app -AppId $n.aumid -OccurredAt $n.arrivedAt `
                -Title $n.title -Body $n.body -Link $n.launch -RawJson $line `
                -DedupKey (Get-NotificationIdentity $n)
        if ($r.isNew) { $added++ }
    }
    return $added
}

# ---------------------------------------------------------------- main

$conn = Open-TaskStore -Path $DbPath

# ---------------------------------------------------------------- 通知と同期の突き合わせ

# 同期が拾う経路かどうか。watermark があれば、その経路は同期が回っているとみなす。
$Covered = @()
if (Get-Setting -Conn $conn -Key 'sync.slack.lastTs')          { $Covered += 'slack:' }
if (Get-Setting -Conn $conn -Key 'sync.gmail.lastInternalDate') { $Covered += 'mail:' }

# 同期が拾うはずの通知は、同期版が来るまで少し待つ。
# 先に通知でカードを立てると、表示用テキストだけで判定したカードができ、
# あとから同期版に差し替えることになる。数分待てば最初から本文で判定できる。
# 相手が来ないまま待ち時間を過ぎたら、通知だけでカードにする (待ち続けて落とさない)。
function Test-WaitForSync {
    param($Evt)
    if ([string] $Evt['source'] -ne 'notification') { return $false }
    $key = [string] $Evt['dedup_key']
    if (-not $key) { return $false }
    if (-not @($Covered | Where-Object { $key.StartsWith($_) })) { return $false }
    if (Find-EventCounterpart -Conn $conn -Evt $Evt) { return $false }
    try { return (((Get-Date) - [DateTime] $Evt['ingested_at']).TotalMinutes -lt $DeferMinutes) }
    catch { return $false }
}

# 反対側の経路に同じものが居たときの後始末。
# 戻り値: $null なら普通に判定してよい。文字列ならこのイベントはカードにしない。
function Resolve-Duplicate {
    param($Evt)
    $c = Find-EventCounterpart -Conn $conn -Evt $Evt
    if (-not $c) { return $null }

    $cid   = [string] $c['id']
    $eid   = [string] $Evt['id']
    $mine  = Get-EventRank ([string] $Evt['source'])
    $their = Get-EventRank ([string] $c['source'])
    $taskId = Get-TaskIdByEvent -Conn $conn -EventId $cid

    if ($mine -gt $their) {
        # こちらが正 (同期側)。相手の通知はカードにしない。
        if (-not $DryRun) { Set-EventSuperseded -Conn $conn -EventId $cid -CanonicalId $eid }

        if ($taskId) {
            # 通知で立ったカードがもうある。増やさず、土台だけ同期に差し替える。
            # 列もコメントも利用者の編集もそのまま残り、中身の出どころだけ変わる。
            if (-not $DryRun) {
                Move-TaskEvent -Conn $conn -TaskId $taskId -EventId $eid
                Add-TaskActivity -Conn $conn -TaskId $taskId -Kind 'step' `
                    -Message '同期で本文が取れたので、このカードの元を通知から同期に差し替えました'
                Add-TriageLog -Conn $conn -EventId $eid -DecidedBy 'dedup' -RuleName 'dedup.promoted' -NeedsAction $null
            }
            return ("差し替え #{0}" -f $taskId)
        }

        # 相手はまだカードになっていない。相手だけ止めて、こちらは普通に判定する。
        if (-not $DryRun) {
            Add-TriageLog -Conn $conn -EventId $cid -DecidedBy 'dedup' -RuleName 'dedup.superseded' -NeedsAction $null
        }
        return $null
    }

    # 相手 (同期側) が正。こちらはカードにしない。
    if (-not $DryRun) {
        Set-EventSuperseded -Conn $conn -EventId $eid -CanonicalId $cid
        Add-TriageLog -Conn $conn -EventId $eid -DecidedBy 'dedup' -RuleName 'dedup.superseded' -NeedsAction $null
    }
    return ("同期版に統合 {0}" -f $cid)
}

try {
    $added = Import-Notifications $conn $JsonlPath
    Write-Host ("取り込み: 新規 {0} 件" -f $added) -ForegroundColor Cyan

    $events = @(Get-UntriagedEvents -Conn $conn -Limit $Limit)
    Write-Host ("未判定: {0} 件" -f $events.Count) -ForegroundColor Cyan

    $stats = @{ ignored = 0; llm = 0; tasks = 0; failed = 0; deferred = 0; merged = 0; stacked = 0 }

    foreach ($e in $events) {
        $label = "{0} / {1}" -f $e['app_id'], $e['title']

        # 同じ周回の前のイベントに相手として片付けられていることがある
        if (-not $DryRun -and (Test-EventSuperseded -Conn $conn -EventId ([string] $e['id']))) { continue }

        if (Test-WaitForSync $e) {
            $stats.deferred++
            Write-Host ("  [同期待ち] {0}" -f $label) -ForegroundColor DarkCyan
            continue
        }

        $merge = Resolve-Duplicate $e
        if ($merge) {
            $stats.merged++
            Write-Host ("  [{0}] {1}" -f $merge, $label) -ForegroundColor Magenta
            continue
        }

        $rule = Get-IgnoreRule $e $policy

        if ($rule) {
            $stats.ignored++
            Write-Host ("  [skip:{0}] {1}" -f $rule, $label) -ForegroundColor DarkGray
            if (-not $DryRun) {
                Add-TriageLog -Conn $conn -EventId $e['id'] -DecidedBy 'rule' -RuleName $rule -NeedsAction $false
            }
            continue
        }

        if ($DryRun) {
            Write-Host ("  [llm予定] {0}" -f $label) -ForegroundColor Yellow
            $stats.llm++
            continue
        }

        try {
            $res = Invoke-ClaudeTriage -Evt $e -Policy $policy
            $t   = $res.result
            $stats.llm++

            Add-TriageLog -Conn $conn -EventId $e['id'] -DecidedBy 'llm' -Model $res.model `
                -NeedsAction $t.needs_action -RawResponse $res.raw

            # 対応不要でもカードは作る。「見たうえで不要と判断した」履歴を board に残すため。
            $column = if ($t.needs_action) { 'todo' } else { 'dismissed' }

            # 同じ「件」で開いているカードがあれば、増やさずにそこへ積む。
            #
            # dedup_key は「同じメッセージか」を見るので、CI の失敗通知のように
            # 実行ごとに別メールが届くものは弾けない。実際それで、同じ
            # ワークフローの失敗が5枚のカードになり、5回とも同じ調査をやり直し、
            # 5回とも同じ権限の壁にぶつかっていた。
            $skey = Get-SubjectKey -Evt $e
            $open = if ($skey -and $t.needs_action) { Get-OpenTaskBySubject -Conn $conn -SubjectKey $skey } else { $null }
            if ($open) {
                $n = Add-TaskOccurrence -Conn $conn -TaskId ([int] $open['id']) -EventId ([string] $e['id'])
                [void] (Add-TaskComment -Conn $conn -TaskId ([int] $open['id']) -Author 'agent' `
                    -Body ("同じ件がもう一度届きました ({0} 回目): {1}" -f $n, $t.title))
                $stats.stacked++
                Write-Host ("  [積む  ] #{0} に {1} 回目として追加 — {2}" -f $open['id'], $n, $t.title) -ForegroundColor DarkCyan
                continue
            }

            $id = New-Task -Conn $conn -EventId $e['id'] -Title $t.title -Summary $t.summary `
                    -NeedsAction $t.needs_action -Urgency $t.urgency -Category $t.category `
                    -Reason $t.reason -ProposedActions ($t.proposed_actions | ConvertTo-Json -Depth 6 -Compress) `
                    -Column $column -SubjectKey $skey
            if ($id) { $stats.tasks++ }

            # 過去に同じ件で分かったことがあれば、最初から持たせる。
            if ($id -and $skey) {
                $prior = Get-DossierText -Conn $conn -SubjectKey $skey
                if ($prior) {
                    Write-Host ("          (この件は過去にも扱っています。前回の記録を引き継ぎます)") -ForegroundColor DarkGray
                }
            }

            $mark = if ($t.needs_action) { '要対応' } else { '不要  ' }
            $color = if ($t.needs_action) { 'Green' } else { 'DarkGray' }
            Write-Host ("  [{0}] {1} ({2}) — {3}" -f $mark, $t.title, $t.urgency, $t.summary) -ForegroundColor $color
        }
        catch {
            $stats.failed++
            Write-Host ("  [error] {0}: {1}" -f $label, $_.Exception.Message) -ForegroundColor Red
        }
    }

    Write-Host ''
    if ($DryRun) {
        Write-Host ("DryRun: ルールで除外 {0} 件 / 同期待ち {1} 件 / 統合 {2} 件 / LLM に回る {3} 件 (書き込みなし)" -f `
            $stats.ignored, $stats.deferred, $stats.merged, $stats.llm) -ForegroundColor Yellow
    } else {
        Write-Host ("除外 {0} / 同期待ち {1} / 統合 {2} / 判定 {3} / タスク作成 {4} / 既存に集約 {5} / 失敗 {6}" -f `
            $stats.ignored, $stats.deferred, $stats.merged, $stats.llm, $stats.tasks, $stats.stacked, $stats.failed) -ForegroundColor Yellow
    }
}
finally { $conn.Dispose() }
