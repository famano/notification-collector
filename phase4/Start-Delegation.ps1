<#
.SYNOPSIS
    引き渡されたカードの作業を Claude Code に任せる (カンバンの「Claude Code に渡す」から起動される)。

.DESCRIPTION
    ワーカーが require_human_step (blocker=beyond_tools) で引き渡したカードのうち、
    GitHub のリポジトリのコード修正を、ローカルの Claude Code (claude -p) で行う。

      1. 手元の clone から新しいブランチ (nc/task-NNNN) の worktree を切る
         利用者の作業ツリーにも既存のブランチにも触らない
      2. その中で claude -p を走らせる。push・gh・Web は止めてある
      3. コミットがあれば、このスクリプトが新しいブランチだけを push し、下書きの PR にする
      4. 結果をカードのやりとりに報告として残し、レビュー待ちに置く

    マージは人が決める。壊れるとしても PR の中まで。
    詳しくは phase4\README.md の「Claude Code への引き渡し」。

.EXAMPLE
    .\Start-Delegation.ps1 -TaskId 295
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $TaskId,
    [string] $DbPath,
    [string] $PolicyPath,
    # worktree を置く場所。既定は %LOCALAPPDATA%\notification-collector\worktrees
    [string] $WorktreeRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\lib\LogText.ps1"
Set-Utf8Output
. "$PSScriptRoot\..\phase2\lib\TaskStore.ps1"
. "$PSScriptRoot\lib\WorkTools.ps1"
. "$PSScriptRoot\lib\Delegation.ps1"

if (-not $PolicyPath) { $PolicyPath = Join-Path $PSScriptRoot '..\phase2\config\policy.json' }
$policy = $null
try { $policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
$d = if ($policy) { $policy.delegation } else { $null }
$maxBudget = if ($d -and $d.maxBudgetUsd) { [double] $d.maxBudgetUsd } else { 5 }
$timeoutMin = if ($d -and $d.timeoutMinutes) { [int] $d.timeoutMinutes } else { 30 }
if (-not $WorktreeRoot) { $WorktreeRoot = Join-Path $env:LOCALAPPDATA 'notification-collector\worktrees' }

$conn = Open-TaskStore -Path $DbPath

function Write-Step {
    param([string] $Kind, [string] $Message)
    Add-TaskActivity -Conn $conn -TaskId $TaskId -Kind $Kind -Message $Message
    Write-Host ("  [#{0}] {1}" -f $TaskId, $Message)
}

function Invoke-Git {
    param([Parameter(Mandatory)] [string] $Dir, [Parameter(Mandatory)] [string[]] $GitArgs)
    $out = & git -C $Dir @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("git {0} が失敗しました: {1}" -f ($GitArgs -join ' '), (($out | Out-String).Trim())) }
    return (($out | Out-String).Trim())
}

function Invoke-ClaudeCode {
    <#
      .SYNOPSIS
        claude -p を1回走らせ、標準出力を返す。プロンプトは標準入力で UTF-8 のまま渡す。
      .DESCRIPTION
        PowerShell 5.1 でパイプから渡すと $OutputEncoding (既定 ASCII) で日本語が潰れる。
        プロセスを直に立て、標準入力にバイト列で書く。
    #>
    param([string] $Exe, [string[]] $Arguments, [string] $Prompt, [string] $WorkDir, [int] $TimeoutMinutes)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Prompt)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        try { $p.Kill() } catch { }
        throw ("Claude Code が {0} 分で終わらなかったため止めました。" -f $TimeoutMinutes)
    }
    return [pscustomobject]@{ exitCode = $p.ExitCode; stdout = $outTask.Result; stderr = $errTask.Result }
}

$task = @($conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($TaskId)))[0]
if (-not $task) { throw "カード #$TaskId がありません。" }
$hs = Get-TaskHumanStep -Conn $conn -TaskId $TaskId

try {
    if (-not $hs -or [string] $hs.blocker -ne 'beyond_tools' -or -not (Test-RepoName ([string] $hs.repo))) {
        throw 'このカードは Claude Code に渡せる形になっていません (リポジトリの引き渡しではありません)。'
    }
    $repo = [string] $hs.repo
    $repoPath = Get-Setting -Conn $conn -Key ('delegate.repo.' + $repo.ToLower())
    if (-not $repoPath -or -not (Test-RepoMatchesRemote -Path $repoPath -Repo $repo)) {
        throw "リポジトリ $repo の手元の clone が設定されていないか、origin が一致しません。"
    }
    $claude = Get-ClaudeCodePath
    if (-not $claude) { throw 'Claude Code (claude) が見つかりません。' }

    # --- 新しいブランチの worktree ---
    $branch = Get-DelegationBranch -TaskId $TaskId
    Write-Step 'step' "Claude Code に渡します: $repo ($branch)"
    [void] (Invoke-Git $repoPath @('fetch', 'origin'))
    $baseRef = Invoke-Git $repoPath @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')   # origin/main
    $base = $baseRef -replace '^origin/', ''
    if (-not (Test-Path -LiteralPath $WorktreeRoot)) { New-Item -ItemType Directory -Path $WorktreeRoot -Force | Out-Null }
    $wt = Join-Path $WorktreeRoot ('task-{0:D4}' -f $TaskId)
    if (Test-Path -LiteralPath $wt) {
        # 前回渡したときの worktree。同じブランチの続きとして使う。
        Write-Step 'step' "前回の作業ツリーを使います: $wt"
    }
    else {
        $exists = $false
        try { [void] (Invoke-Git $repoPath @('rev-parse', '--verify', '--quiet', "refs/heads/$branch")); $exists = $true } catch { }
        if ($exists) { [void] (Invoke-Git $repoPath @('worktree', 'add', $wt, $branch)) }
        else { [void] (Invoke-Git $repoPath @('worktree', 'add', '-b', $branch, $wt, $baseRef)) }
    }

    # --- Claude Code ---
    $prompt = New-DelegationPrompt -Title ([string] $task['title']) -Step ([string] $hs.step) `
                -Tried ([string] $hs.tried) -Repo $repo -Branch $branch
    # 設定ファイルは作業ツリーの外に置く (コミットに混ざらないように)
    $settingsDir = Join-Path $env:TEMP ('nc-delegation-' + $TaskId)
    if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }
    $settingsPath = Join-Path $settingsDir 'settings.json'
    [IO.File]::WriteAllText($settingsPath, ((Get-DelegationSettings) | ConvertTo-Json -Depth 5),
                            (New-Object Text.UTF8Encoding($false)))
    Write-Step 'tool' ("Claude Code が作業しています (上限 {0} ドル・{1} 分)" -f $maxBudget, $timeoutMin)
    $run = Invoke-ClaudeCode -Exe $claude -Arguments (Get-DelegationArguments -SettingsPath $settingsPath -MaxBudgetUsd $maxBudget) `
              -Prompt $prompt -WorkDir $wt -TimeoutMinutes $timeoutMin
    $res = ConvertFrom-DelegationOutput $run.stdout
    if (-not $res.text -and $run.stderr) { $res.text = $run.stderr.Trim() }
    Add-TaskAttempt -Conn $conn -TaskId $TaskId -Tool 'claude_code' -Target "$repo $branch" `
        -Outcome $(if ($res.isError -or $run.exitCode -ne 0) { 'failed' } else { 'ok' }) `
        -Detail $(if ($null -ne $res.cost) { "費用 {0} ドル" -f $res.cost } else { '' }) -Request $prompt

    # --- コミットがあれば、新しいブランチだけを push して下書きの PR にする ---
    $total = [int] (Invoke-Git $wt @('rev-list', '--count', "$baseRef..HEAD"))
    $prUrl = ''
    $pushNote = ''
    if ($total -gt 0) {
        if ((Invoke-Git $wt @('rev-parse', '--abbrev-ref', 'HEAD')) -ne $branch) {
            throw "作業ツリーのブランチが $branch ではなくなっています。push しません。"
        }
        [void] (Invoke-Git $wt @('push', '-u', 'origin', "${branch}:${branch}"))
        Write-Step 'sent' "push しました: $branch (コミット $total 件)"
        Add-TaskAttempt -Conn $conn -TaskId $TaskId -Tool 'git_push' -Target "$repo $branch" -Outcome 'ok' -Detail "コミット $total 件"
        # 既に PR があれば作らない
        $existing = Invoke-HttpAction -Method 'GET' -Url ("https://api.github.com/repos/{0}/pulls?head={1}:{2}&state=open" -f $repo, $repo.Split('/')[0], $branch)
        if (-not $existing.isError -and $existing.text -match '"html_url"\s*:\s*"(https://github\.com/[^"]+/pull/\d+)"') {
            $prUrl = $Matches[1]
        }
        else {
            $body = @{
                title = ('[#{0}] {1}' -f $TaskId, [string] $task['title'])
                head = $branch; base = $base; draft = $true
                body = ("通知コレクターのカード #{0} から、Claude Code に引き渡して作った変更です。`n`n{1}`n`n🤖 Generated with [Claude Code](https://claude.com/claude-code)" -f $TaskId, $res.text)
            } | ConvertTo-Json -Compress
            $pr = Invoke-HttpAction -Method 'POST' -Url ("https://api.github.com/repos/{0}/pulls" -f $repo) -Body $body
            if (-not $pr.isError -and $pr.text -match '"html_url"\s*:\s*"(https://github\.com/[^"]+/pull/\d+)"') {
                $prUrl = $Matches[1]
                Write-Step 'sent' "下書きの PR を作りました: $prUrl"
                Add-TaskAttempt -Conn $conn -TaskId $TaskId -Tool 'http_request' -Target ("POST https://api.github.com/repos/{0}/pulls" -f $repo) `
                    -Outcome 'ok' -Detail $prUrl -Request $body
            }
            else {
                $pushNote = "PR は作れませんでした (GitHub トークンが無いか、権限が足りません)。ブランチは push 済みです: https://github.com/$repo/compare/$base...$branch"
                Write-Step 'step' $pushNote
            }
        }
    }

    # --- 報告 ---
    $sb = New-Object Text.StringBuilder
    [void] $sb.AppendLine('## Claude Code に引き渡した結果')
    [void] $sb.AppendLine()
    if ($prUrl) { [void] $sb.AppendLine("下書きの PR: $prUrl (マージするかはあなたが決めてください)") }
    elseif ($pushNote) { [void] $sb.AppendLine($pushNote) }
    elseif ($total -eq 0) { [void] $sb.AppendLine('コミットはありませんでした (Claude Code は変更を加えていません)。') }
    [void] $sb.AppendLine("作業ツリー: $wt")
    [void] $sb.AppendLine()
    [void] $sb.AppendLine($res.text)
    $report = $sb.ToString()
    [void] (Update-TaskFields -Conn $conn -TaskId $TaskId -Fields @{ agent_output = $report; shape = ''; human_step = $null })
    [void] (Add-TaskComment -Conn $conn -TaskId $TaskId -Author 'agent' -Kind 'report' -Body $report)
    Write-Step 'done' $(if ($prUrl) { 'Claude Code の作業が終わりました。PR を確認してください' } else { 'Claude Code の作業が終わりました' })
}
catch {
    $msg = $_.Exception.Message
    Write-Step 'error' ('Claude Code への引き渡しに失敗しました: ' + $msg)
    # 引き渡しの形は残す (直してからもう一度押せるように)
    [void] (Update-TaskFields -Conn $conn -TaskId $TaskId -Fields @{ shape = 'human' })
    [void] (Add-TaskComment -Conn $conn -TaskId $TaskId -Author 'agent' -Kind 'report' -Body ("Claude Code への引き渡しに失敗しました: " + $msg))
    exit 1
}
finally {
    $conn.Dispose()
}
