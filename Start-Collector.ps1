<#
.SYNOPSIS
    収集パイプライン (通知の取得 → 実データの同期 → トリアージ) を回し続ける常駐スクリプト。

.DESCRIPTION
    カードを作るのはこのスクリプトで、ワーカー (phase4) は「できたカードを処理する」側でしかない。
    これを起動していないと、メールが届いてもカンバンには何も現れない。

    3つを別々の間隔で回す。速さの要求が違うため。

    1. 通知の取得 (phase1) — 既定 5 秒ごと。
       Windows は wpndatabase を十数件しか保持せず、すぐ消す。ここだけは短く回す必要がある。

    2. 実データの同期 (phase5) — 既定 180 秒ごと。**起動直後に必ず一度走る。**
       watermark で「前回どこまで取ったか」を持っているので、電源を落としていた間の
       メールや Slack はここで埋まる。起動時に一度走ることが穴埋めの本体。

    3. トリアージ (phase2) — 同期の直後。未判定のイベントをカードにする。

    どの段が失敗しても次の周回は回す。落とすと「動いているのに何も起きない」状態になり、
    それが一番気付きにくいため。死活は settings の collector.* に書き、カンバンが読む。

.PARAMETER Once
    1周だけ実行して終了する (動作確認用)。

.PARAMETER NoTriage
    カード化を行わない。ANTHROPIC_API_KEY を使わずに取り込みだけ試すとき用。

.EXAMPLE
    .\Start-Collector.ps1
    .\Start-Collector.ps1 -Once -NoTriage
    .\Start-Collector.ps1 -SyncIntervalSeconds 600
#>
[CmdletBinding()]
param(
    [string] $DbPath,
    # 通知ポーリングの間隔。長くすると Windows 側で消える前に拾えない。
    [int]    $NotifyIntervalSeconds = 5,
    # Slack / Gmail を叩く間隔。API のレート制限があるので通知ほど短くできない。
    [int]    $SyncIntervalSeconds = 180,
    [switch] $NoNotifications,
    [switch] $NoSync,
    [switch] $NoTriage,
    [switch] $Once
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\phase2\lib\TaskStore.ps1"

$NotifyScript = Join-Path $PSScriptRoot 'phase1\Get-Notifications.ps1'
$SyncScript   = Join-Path $PSScriptRoot 'phase5\Sync-Sources.ps1'
$TriageScript = Join-Path $PSScriptRoot 'phase2\Invoke-Triage.ps1'

$dbArgs = @{}
if ($DbPath) { $dbArgs['DbPath'] = $DbPath }

$conn = Open-TaskStore -Path $DbPath

# 死活。カンバンはこれを見て「取り込みが止まっています」を出す。
# ワーカーの worker_state と役割は同じだが、こちらは1行テーブルを増やさず settings に置く。
function Write-Heartbeat {
    param([string] $State, [string] $Message)
    try {
        Set-Setting -Conn $conn -Key 'collector.heartbeat' -Value ((Get-Date).ToString('o'))
        Set-Setting -Conn $conn -Key 'collector.state'     -Value $State
        Set-Setting -Conn $conn -Key 'collector.message'   -Value $Message
    }
    catch {
        # 死活が書けないだけで収集を止める理由はない
        Write-Host ("死活の記録に失敗: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
    }
}

# 段ごとに最後の失敗を覚える。段の成功でその段の分だけ消す。
# ひとまとめの「直近の失敗」にすると、5秒ごとに成功する通知ポーリングが
# 同期の失敗を即座に塗り潰してしまい、画面には何も残らない。
$script:Failures = @{}

# 各段は必ずここを通す。1段の失敗で常駐が落ちると、
# 「起動したのに何も起きない」に戻ってしまう。
function Invoke-Step {
    param([string] $Name, [scriptblock] $Body)
    try {
        & $Body
        $script:Failures.Remove($Name)
        return $true
    }
    catch {
        Write-Host ("[{0}] {1} で失敗しました: {2}" -f (Get-Date).ToString('HH:mm:ss'), $Name, $_.Exception.Message) -ForegroundColor Red
        $script:Failures[$Name] = ("{0}: {1}" -f $Name, $_.Exception.Message)
        return $false
    }
}

# 周回の終わりに書く死活。失敗を抱えたままなら idle と言わない。
# 動いてはいるが取り込めていない状態を「待機中」と表示すると、静かに漏れ続ける。
function Write-CycleHeartbeat {
    param([string] $IdleMessage)
    if ($script:Failures.Count -gt 0) {
        Write-Heartbeat 'error' (($script:Failures.Values | Sort-Object) -join ' / ')
    }
    else {
        Write-Heartbeat 'idle' $IdleMessage
    }
}

function Invoke-NotifyStep {
    [void] (Invoke-Step '通知の取得' {
        # -Json は新着が無ければ何も出さない。5秒ごとの常駐なので静かにしておく。
        $lines = @(& $NotifyScript -Json)
        if ($lines.Count -gt 0) {
            Write-Host ("[{0}] 通知 {1} 件" -f (Get-Date).ToString('HH:mm:ss'), $lines.Count) -ForegroundColor Green
        }
    })
}

function Invoke-SyncStep {
    Write-Heartbeat 'syncing' '外部サービスと同期しています'
    Write-Host ("[{0}] 同期" -f (Get-Date).ToString('HH:mm:ss')) -ForegroundColor Cyan
    [void] (Invoke-Step '同期' { & $SyncScript @dbArgs })
}

function Invoke-TriageStep {
    Write-Heartbeat 'triaging' '対応要否を判定しています'
    Write-Host ("[{0}] トリアージ" -f (Get-Date).ToString('HH:mm:ss')) -ForegroundColor Cyan
    [void] (Invoke-Step 'トリアージ' { & $TriageScript @dbArgs })
}

if (-not $env:ANTHROPIC_API_KEY -and -not $NoTriage) {
    # 取り込みまでは動くが、カードにはならない。黙って進むと原因が分からなくなる。
    Write-Host 'ANTHROPIC_API_KEY が設定されていません。取り込みは行いますが、カードは作られません。' -ForegroundColor Yellow
}

Write-Host ("収集を開始します (通知 {0}秒 / 同期 {1}秒) — Ctrl+C で停止" -f $NotifyIntervalSeconds, $SyncIntervalSeconds) -ForegroundColor Yellow

try {
    # 起動直後に一度回す。電源を落としていた間の穴はここで埋まる。
    $nextSync = Get-Date

    while ($true) {
        if (-not $NoNotifications) { Invoke-NotifyStep }

        if ((Get-Date) -ge $nextSync) {
            if (-not $NoSync)   { Invoke-SyncStep }
            if (-not $NoTriage) { Invoke-TriageStep }
            $nextSync = (Get-Date).AddSeconds($SyncIntervalSeconds)
        }

        Write-CycleHeartbeat ('次の同期: ' + $nextSync.ToString('HH:mm:ss'))
        if ($Once) { break }
        Start-Sleep -Seconds $NotifyIntervalSeconds
    }
}
finally {
    Write-Heartbeat 'stopped' '収集は停止しています'
    $conn.Dispose()
}
