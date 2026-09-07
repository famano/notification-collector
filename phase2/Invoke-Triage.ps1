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
    [int]    $Limit = 100
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\TaskStore.ps1"
. "$PSScriptRoot\lib\ClaudeClient.ps1"

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
                -Title $n.title -Body $n.body -Link $n.launch -RawJson $line
        if ($r.isNew) { $added++ }
    }
    return $added
}

# ---------------------------------------------------------------- main

$conn = Open-TaskStore -Path $DbPath
try {
    $added = Import-Notifications $conn $JsonlPath
    Write-Host ("取り込み: 新規 {0} 件" -f $added) -ForegroundColor Cyan

    $events = @(Get-UntriagedEvents -Conn $conn -Limit $Limit)
    Write-Host ("未判定: {0} 件" -f $events.Count) -ForegroundColor Cyan

    $stats = @{ ignored = 0; llm = 0; tasks = 0; failed = 0 }

    foreach ($e in $events) {
        $rule = Get-IgnoreRule $e $policy
        $label = "{0} / {1}" -f $e['app_id'], $e['title']

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
            $id = New-Task -Conn $conn -EventId $e['id'] -Title $t.title -Summary $t.summary `
                    -NeedsAction $t.needs_action -Urgency $t.urgency -Category $t.category `
                    -Reason $t.reason -ProposedActions ($t.proposed_actions | ConvertTo-Json -Depth 6 -Compress) `
                    -Column $column
            if ($id) { $stats.tasks++ }

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
        Write-Host ("DryRun: ルールで除外 {0} 件 / LLM に回る {1} 件 (書き込みなし)" -f $stats.ignored, $stats.llm) -ForegroundColor Yellow
    } else {
        Write-Host ("除外 {0} / 判定 {1} / タスク作成 {2} / 失敗 {3}" -f $stats.ignored, $stats.llm, $stats.tasks, $stats.failed) -ForegroundColor Yellow
    }
}
finally { $conn.Dispose() }
