# WorkSession.ps1
# カードごとの会話を、続きから始めるか・記録から引き継ぐか・新しく始めるかを決める。
#
# ワーカーは以前、やり直しのたびに会話を捨てていた。差し戻すと最初から調べ直し、
# 自分が前回何をしたか (何を書き込んだか) を知らないまま作業する。#295 では
# 「テストファイルを空にしたのはきみか」と聞かれて「GET しか出していない」と答えた。
# 会話そのものは task_sessions に残り、ここはそれをどう使うかだけを決める。
#
# 要る部品 (ConvertFrom-SessionJson など) は phase2\lib\ClaudeClient.ps1、
# ストアは phase2\lib\TaskStore.ps1 にある。読み込むのは呼び出し側。

function Get-TextHash {
    param([string] $Text)
    if (-not $Text) { return '' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        return (-join ($h[0..11] | ForEach-Object { $_.ToString('x2') }))
    }
    finally { $sha.Dispose() }
}

# 前回の作業の点検で解消しなかった指摘。ワーカーがコメントに残したもの。
# $Since を渡すと、それより後に書かれたものだけ (= その会話の後の点検) を見る。
function Get-OpenIssuesText {
    param([Parameter(Mandatory)] $Conn, [int] $TaskId, [string] $Since)
    $rows = @($Conn.Query(
        "SELECT body, created_at FROM task_comments WHERE task_id = ? AND author = 'agent' ORDER BY id DESC LIMIT 1",
        [object[]] @($TaskId)))
    if ($rows.Count -eq 0) { return '' }
    if ($Since -and [string]::CompareOrdinal([string] $rows[0]['created_at'], $Since) -lt 0) { return '' }
    return [string] $rows[0]['body']
}

function Get-SessionPlan {
    <#
      .SYNOPSIS
        このカードの会話を、続きから始めるか・記録から引き継ぐか・新しく始めるかを決める。
      .OUTPUTS
        [pscustomobject] mode ('new' / 'resume' / 'handoff') / messages (ArrayList) /
        reason / since / state / changedSource / openIssues
      .DESCRIPTION
        続きからにできないのは次のとき。どれも会話を捨て、記録 (試行・前回の報告・
        残った指摘) から組み立てた経過を新しい会話に渡す。
          - 同じ件の新しい発生 (次の CI の失敗など)。別の出来事なので会話を分ける
          - 会話が長すぎる
          - 前回呼んだツールが今の一覧に無い (コードの更新・連携の解除)。
            宙に浮いた呼び出しを抱えた会話は API に弾かれる
          - 会話を保存する前からあるカード (以前の版で作業したもの)
    #>
    param(
        [Parameter(Mandatory)] $Conn,
        [int] $TaskId, $Task, [int] $Occurrence, $Tools, [string] $SourceText,
        [int] $MaxSessionChars = 2000000
    )

    $plan = [pscustomobject]@{
        mode = 'new'; messages = [System.Collections.ArrayList]::new(); reason = ''
        since = ''; state = ''; changedSource = ''; openIssues = ''
    }
    $s = Get-TaskSession -Conn $Conn -TaskId $TaskId
    $hasHistory = [bool] $Task['agent_output'] -or (@(Get-TaskAttempts -Conn $Conn -TaskId $TaskId).Count -gt 0)

    if (-not $s) {
        if ($hasHistory) {
            $plan.mode = 'handoff'; $plan.reason = '以前の作業の会話は残っていません'
            $plan.openIssues = Get-OpenIssuesText -Conn $Conn -TaskId $TaskId
        }
        return $plan
    }

    $reason = ''
    $restored = $null
    $json = [string] $s['messages']
    if ([int] $s['occurrence'] -ne $Occurrence) { $reason = '同じ件の新しい発生です' }
    elseif ($json.Length -gt $MaxSessionChars) { $reason = '前回の会話が長くなりすぎました' }
    else {
        try { $restored = ConvertFrom-SessionJson -Json $json }
        catch { $reason = '前回の会話を読み込めませんでした' }
        if (-not $reason) {
            $have = @($Tools | ForEach-Object { [string] $_.name })
            $gone = @(Get-SessionToolNames -Messages $restored | Where-Object { $have -notcontains $_ })
            if ($gone.Count -gt 0) { $reason = '前回使ったツールが今はありません: ' + ($gone -join ', ') }
        }
    }

    if ($reason) {
        [void] (Clear-TaskSession -Conn $Conn -TaskId $TaskId)
        $plan.mode = 'handoff'; $plan.reason = $reason
        $plan.openIssues = Get-OpenIssuesText -Conn $Conn -TaskId $TaskId
        return $plan
    }

    $plan.mode = 'resume'
    $plan.messages = $restored
    $plan.since = [string] $s['updated_at']
    $plan.state = [string] $s['state']
    $plan.openIssues = Get-OpenIssuesText -Conn $Conn -TaskId $TaskId -Since $plan.since
    if ($SourceText -and (Get-TextHash $SourceText) -ne [string] $s['source_hash']) {
        $plan.changedSource = $SourceText
    }
    return $plan
}
