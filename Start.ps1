<#
.SYNOPSIS
    収集・ワーカー・カンバンをまとめて起動して面倒を見る。通常はこれだけを実行する。

.DESCRIPTION
    3つとも常駐が要るのに、これまでは別々に起動する必要があった。
    そして「片方だけ起動する」は実際に起きる事故で、しかも症状が分かりにくい ――
    ワーカーとカンバンだけを立ち上げると、画面は正常に見えるのにカードが1枚も増えない。
    「要対応が無い」のか「取り込みが止まっている」のかが見分けられない。

    このスクリプトは3つを子プロセスとして起動し、

      - どれかが落ちたら間隔を空けて起動し直す
      - 死活と現在の作業を1行にまとめて出し続ける
      - Ctrl+C で3つともまとめて止める

    各プロセスの出力は logs\ に残る。画面に3本混ぜると読めなくなるため、
    こちらは要約だけを出す。詳しく見たいときは -Follow か logs\ を直接見る。

.PARAMETER Port
    カンバンのポート。既定 8787。

.PARAMETER NoTriage
    カード化を行わない。ANTHROPIC_API_KEY を使わずに取り込みだけ試すとき用。
    ワーカーも起動しない (処理するカードが増えないため)。

.PARAMETER NoWorker
    ワーカーを起動しない。カードは増えるが処理されない。

.PARAMETER Follow
    要約ではなく、3つの出力をそのまま流し続ける。

.PARAMETER Stop
    起動しているこのリポジトリのプロセスを止めるだけ。
    親を強制終了して子が残ってしまったときの後始末用。

.EXAMPLE
    .\Start.ps1
    .\Start.ps1 -Port 9000
    .\Start.ps1 -NoTriage        # 取り込みの確認だけ
    .\Start.ps1 -Stop
#>
[CmdletBinding()]
param(
    [int]    $Port = 8787,
    [string] $DbPath,
    [int]    $NotifyIntervalSeconds = 5,
    [int]    $SyncIntervalSeconds = 180,
    [switch] $NoTriage,
    [switch] $NoWorker,
    [switch] $NoBrowser,
    [switch] $Follow,
    [switch] $Stop
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\phase2\lib\TaskStore.ps1"

$LogDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# ---------------------------------------------------------------- 後始末

# 親が強制終了されると子が残る。次に起動したとき二重に動くと、
# 同じカードを2つのワーカーが取り合うので、起動前に必ず掃除する。
$RunFile = Join-Path $LogDir 'running.json'

# 誰を止めるかは、コマンドラインを見て推測するのではなく、起動したときに
# 自分で書き留めておいたものだけにする。
#
# 最初はコマンドラインに 'Start.ps1' を含むプロセスを探す実装にしていたが、
# **これは自分を起動した親シェルまで巻き込む。** `.\Start.ps1 -Stop` と打った
# シェルのコマンドラインにも 'Start.ps1' は入っているためで、実際に
# 呼び出し元が巻き添えで死んだ。推測で人のプロセスを殺してはいけない。
function Save-RunState {
    param($Children)
    $state = [pscustomobject]@{
        supervisor = $PID
        startedAt  = (Get-Date).ToString('o')
        children   = @($Children | ForEach-Object {
            [pscustomobject]@{ name = $_.name; pid = $_.process.Id }
        })
    }
    $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $RunFile -Encoding utf8
}

function Clear-RunState {
    if (Test-Path $RunFile) { Remove-Item -LiteralPath $RunFile -Force -ErrorAction SilentlyContinue }
}

# pid は使い回される。記録した番号が今も「このリポジトリの PowerShell」か
# 確かめてから止める。確かめずに殺すと、無関係なプロセスを落としうる。
function Test-OurProcess {
    param([int] $ProcessId)
    if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return $false }
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if ($p.ProcessName -notin @('powershell', 'pwsh')) { return $false }
    $cl = ''
    try { $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).CommandLine } catch { return $false }
    return ($cl -like "*$PSScriptRoot*")
}

function Stop-Running {
    param([switch] $Quiet)
    if (-not (Test-Path $RunFile)) {
        if (-not $Quiet) { Write-Host '  起動記録がありません (動いていないはずです)' -ForegroundColor DarkGray }
        return 0
    }
    $state = $null
    try { $state = Get-Content -LiteralPath $RunFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not $state) { Clear-RunState; return 0 }

    $killed = 0
    # 監視役を先に。子を先に落とすと、落とした端から起動し直される。
    if (Test-OurProcess ([int] $state.supervisor)) {
        if (-not $Quiet) { Write-Host ("  停止: 監視役 (pid {0})" -f $state.supervisor) -ForegroundColor DarkGray }
        try { Stop-Process -Id ([int] $state.supervisor) -Force -ErrorAction Stop; $killed++ } catch { }
        # 監視役の終了処理が子を片付けるのを少し待つ
        Start-Sleep -Milliseconds 1200
    }
    foreach ($c in @($state.children)) {
        if (-not (Test-OurProcess ([int] $c.pid))) { continue }
        if (-not $Quiet) { Write-Host ("  停止: {0} (pid {1})" -f $c.name, $c.pid) -ForegroundColor DarkGray }
        try { Stop-Process -Id ([int] $c.pid) -Force -ErrorAction Stop; $killed++ } catch { }
    }
    Clear-RunState
    return $killed
}

if ($Stop) {
    Write-Host '起動中のプロセスを停止します' -ForegroundColor Cyan
    $n = Stop-Running
    Write-Host ("{0} 件停止しました" -f $n) -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------- 起動前の確認

Write-Host ''
Write-Host 'notification-collector' -ForegroundColor Cyan
Write-Host ''

if (-not $NoTriage -and -not $env:ANTHROPIC_API_KEY) {
    # ここで止める。3つ起動してから個別に失敗されると、
    # 「動いているのにカードが増えない」という一番分かりにくい形になる。
    Write-Host 'ANTHROPIC_API_KEY が設定されていません。' -ForegroundColor Red
    Write-Host '判断とワーカーはこのキーを使います。設定して再実行してください:' -ForegroundColor Yellow
    Write-Host '  $env:ANTHROPIC_API_KEY = ''sk-ant-...''' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'キー無しで取り込みだけ試すなら -NoTriage を付けてください。' -ForegroundColor DarkGray
    Write-Host ''
    return
}

# 連携の状況を先に見せる。未設定でも動くが、何ができない状態なのかは
# 起動時に分かっていないと、後でカードの中身を見て初めて気付くことになる。
try {
    . "$PSScriptRoot\phase5\lib\SecretStore.ps1"
    . "$PSScriptRoot\phase5\lib\SlackConnector.ps1"
    . "$PSScriptRoot\phase5\lib\GmailConnector.ps1"
    $slackOn  = Test-SlackConfigured
    $gmailOn  = Test-GmailConfigured
    $githubOn = [bool] (Get-Secret -Name 'github.token')
    Write-Host ("連携: Slack={0} / Gmail={1} / GitHub={2}" -f `
        $(if ($slackOn) { '有効' } else { '未設定' }),
        $(if ($gmailOn) { '有効' } else { '未設定' }),
        $(if ($githubOn) { '有効' } else { '未設定' })) -ForegroundColor DarkGray
    if (-not $githubOn) {
        Write-Host '  GitHub 未設定: 招待の承諾や非公開リポの調査は本人操作になります' -ForegroundColor DarkGray
        Write-Host '  設定する: .\phase5\Connect-Service.ps1 -Service github' -ForegroundColor DarkGray
    }
}
catch {
    Write-Host ("連携の確認に失敗しました: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
}

$n = Stop-Running -Quiet
if ($n -gt 0) { Write-Host ("前回のプロセスが残っていたため {0} 件停止しました" -f $n) -ForegroundColor DarkYellow }

# ---------------------------------------------------------------- 子プロセス

$Children = @()

function Start-Child {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Script,
        [string[]] $Arguments = @()
    )
    $log = Join-Path $LogDir ($Name + '.log')
    $err = Join-Path $LogDir ($Name + '.err.log')
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
    $p = Start-Process -FilePath 'powershell' -ArgumentList $psArgs -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $log -RedirectStandardError $err
    return [pscustomobject]@{
        name = $Name; script = $Script; arguments = $Arguments
        process = $p; log = $log; errlog = $err
        starts = 1; lastStart = (Get-Date)
    }
}

function Restart-Child {
    param($Child)
    $fresh = Start-Child -Name $Child.name -Script $Child.script -Arguments $Child.arguments
    $Child.process   = $fresh.process
    $Child.starts    = $Child.starts + 1
    $Child.lastStart = Get-Date
}

$dbArgs = @()
if ($DbPath) { $dbArgs = @('-DbPath', $DbPath) }

$collectorArgs = $dbArgs + @('-NotifyIntervalSeconds', $NotifyIntervalSeconds, '-SyncIntervalSeconds', $SyncIntervalSeconds)
if ($NoTriage) { $collectorArgs += '-NoTriage' }

$boardArgs = $dbArgs + @('-Port', $Port)
if ($NoBrowser) { $boardArgs += '-NoBrowser' }

Write-Host ''
$Children += Start-Child -Name 'collector' -Script (Join-Path $PSScriptRoot 'Start-Collector.ps1') -Arguments $collectorArgs
Write-Host '  収集を起動しました' -ForegroundColor Green

if (-not $NoWorker -and -not $NoTriage) {
    $Children += Start-Child -Name 'worker' -Script (Join-Path $PSScriptRoot 'phase4\Start-Worker.ps1') -Arguments $dbArgs
    Write-Host '  ワーカーを起動しました' -ForegroundColor Green
}
else {
    Write-Host '  ワーカーは起動しません' -ForegroundColor DarkGray
}

$Children += Start-Child -Name 'board' -Script (Join-Path $PSScriptRoot 'phase3\Start-Board.ps1') -Arguments $boardArgs
Write-Host ("  カンバンを起動しました: http://127.0.0.1:{0}/" -f $Port) -ForegroundColor Green

# 誰を動かしたかを残す。別のシェルから -Stop で止めるとき、
# ここに書いた pid だけを対象にする。
Save-RunState -Children $Children
Write-Host ''
Write-Host ("ログ: {0}" -f $LogDir) -ForegroundColor DarkGray
Write-Host '停止するには Ctrl+C' -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------- 監視

function Get-StatusLine {
    param($Conn)
    $parts = @()

    $hb = Get-Setting -Conn $Conn -Key 'collector.heartbeat'
    if (-not $hb) { $parts += '収集=未開始' }
    else {
        $age = 999
        try { $age = [int] ((Get-Date) - [DateTime] $hb).TotalSeconds } catch { }
        $st = Get-Setting -Conn $Conn -Key 'collector.state' -Default '?'
        $parts += if ($age -gt 120) { "収集=応答なし({0}秒)" -f $age } else { "収集={0}" -f $st }
    }

    $w = Get-WorkerState -Conn $Conn
    if (-not $w) { $parts += 'ワーカー=未開始' }
    else {
        $msg = [string] $w['message']
        if ($msg.Length -gt 40) { $msg = $msg.Substring(0, 40) + '…' }
        $cur = if ($w['current_task_id']) { ' #' + $w['current_task_id'] } else { '' }
        $parts += ("ワーカー={0}{1} {2}" -f $w['state'], $cur, $msg).Trim()
    }

    $counts = @{}
    foreach ($r in @($Conn.Query("SELECT board_column, COUNT(*) n FROM tasks WHERE archived_at IS NULL GROUP BY board_column"))) {
        $counts[[string] $r['board_column']] = [int] $r['n']
    }
    $pending = @($Conn.Query("SELECT COUNT(*) n FROM tool_requests WHERE status='pending'"))[0]['n']
    $parts += ("要対応={0} 作業中={1} 確認待ち={2}" -f
        [int] $counts['todo'], [int] $counts['doing'], [int] $counts['review'])
    if ([int] $pending -gt 0) { $parts += ("承認待ち={0}" -f $pending) }

    return ($parts -join ' | ')
}

$conn = $null
try {
    $conn = Open-TaskStore -Path $DbPath
    $lastLine = ''
    # 落ちた直後に叩き直さない。恒久的な失敗 (キー不正など) だと
    # 再起動を繰り返してログが埋まり、原因が読めなくなる。
    $restartBackoffSec = 10

    while ($true) {
        foreach ($c in $Children) {
            if (-not $c.process.HasExited) { continue }
            $since = ((Get-Date) - $c.lastStart).TotalSeconds
            if ($since -lt $restartBackoffSec) { continue }
            # 強制終了された場合 ExitCode は取れない。空欄のまま出すと
            # 「0 で正常終了した」と読み違える。
            $code = '不明'
            try { if ($null -ne $c.process.ExitCode) { $code = [string] $c.process.ExitCode } } catch { }
            Write-Host ''
            Write-Host ("[{0}] {1} が終了しました (exit {2})。起動し直します ({3} 回目)" -f `
                (Get-Date -Format 'HH:mm:ss'), $c.name, $code, ($c.starts + 1)) -ForegroundColor Yellow
            $tail = @(Get-Content -LiteralPath $c.errlog -Encoding UTF8 -Tail 3 -ErrorAction SilentlyContinue)
            foreach ($t in $tail) { if ($t.Trim()) { Write-Host ("      " + $t) -ForegroundColor DarkRed } }
            Restart-Child -Child $c
            # pid が変わったので記録も更新する。古い pid のままだと
            # -Stop が起動し直したあとの子を取り逃がす。
            Save-RunState -Children $Children
        }

        if ($Follow) {
            foreach ($c in $Children) {
                $tail = @(Get-Content -LiteralPath $c.log -Encoding UTF8 -Tail 2 -ErrorAction SilentlyContinue)
                foreach ($t in $tail) { if ($t.Trim()) { Write-Host ("[{0}] {1}" -f $c.name, $t) -ForegroundColor DarkGray } }
            }
            Start-Sleep -Seconds 3
            continue
        }

        # 同じ内容を出し続けない。変わったときだけ1行出す。
        # 秒ごとに同じ行が流れると、本当に変わった瞬間が埋もれる。
        $line = Get-StatusLine $conn
        if ($line -ne $lastLine) {
            Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $line)
            $lastLine = $line
        }
        Start-Sleep -Seconds 2
    }
}
finally {
    Write-Host ''
    Write-Host '停止しています…' -ForegroundColor Yellow
    foreach ($c in $Children) {
        if ($c.process -and -not $c.process.HasExited) {
            try { Stop-Process -Id $c.process.Id -Force -ErrorAction Stop } catch { }
        }
    }
    # 子が孫を作っている場合 (Start-Worker が呼ぶ powershell など) に備えて、
    # 名前でも掃除しておく。取りこぼすと次回起動時に二重に動く。
    Clear-RunState
    if ($conn) { $conn.Dispose() }
    Write-Host '停止しました' -ForegroundColor Yellow
}
