<#
.SYNOPSIS
    通知と同期の両方から入って2枚になったカードを、同期側に寄せて1枚にする。

.DESCRIPTION
    突き合わせ (events.dedup_key) を入れる前に立ったカードは、同じメールや同じ
    Slack メッセージについて通知由来と同期由来の2枚が並んでいる。これを遡って畳む。

    やることは2つ。

    1. 既存イベントの同一性を計算し直す。取り込み時に付けるのと同じ規則
       (Get-EventIdentityFromRow) を保存済みの raw_json に当てるだけ。

    2. 経路をまたいだ組を見つけて、**同期側を正にする。**
       - 両方にカードがある     … 同期側を残し、通知側のカードをアーカイブする
       - 通知側にだけカードがある … カードの土台を同期側のイベントに差し替える
       - カードがまだ無い       … 通知側を「カードにしない」印だけ付ける

    カードは消さない。アーカイブなのでカンバンの「アーカイブ済み」から見返せる。
    何を畳んだかは両方の作業ログに残る。

    突き合わせは Find-EventCounterpart (SQL) ではなくメモリ上で行う。
    保存前の鍵でも同じ結果を出せないと、-DryRun が「0 件」と嘘をつくため。

.PARAMETER DryRun
    何も書かずに、何が起きるかだけ表示する。

.PARAMETER WindowMinutes
    通知と同期を同じものとみなす時刻の差。既定 15 分。

.EXAMPLE
    .\Merge-Duplicates.ps1 -DryRun
    .\Merge-Duplicates.ps1
#>
[CmdletBinding()]
param(
    [string] $DbPath,
    [switch] $DryRun,
    [int]    $WindowMinutes = 15
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\TaskStore.ps1"

$conn = Open-TaskStore -Path $DbPath
try {
    # ---------------- 1. 同一性をそろえる ----------------
    # 既に鍵を持つ行はそのまま。無い行は raw_json から計算し直す。
    $rows = @($conn.Query('SELECT id, source, occurred_at, dedup_key, superseded_by, raw_json FROM events'))
    $keyed = @()
    $filled = 0
    foreach ($r in $rows) {
        if ($r['superseded_by']) { continue }   # 既に畳んである
        $key = [string] $r['dedup_key']
        if (-not $key) {
            $key = Get-EventIdentityFromRow -Row $r
            if ($key) {
                $filled++
                if (-not $DryRun) { Set-EventIdentity -Conn $conn -EventId ([string] $r['id']) -Key $key }
            }
        }
        if (-not $key) { continue }
        $when = $null
        try { $when = [DateTime] $r['occurred_at'] } catch { continue }
        $keyed += [pscustomobject]@{
            id = [string] $r['id']; source = [string] $r['source']; key = $key; when = $when
        }
    }
    Write-Host ("同一性: {0} 件に鍵あり (うち {1} 件を新たに計算)" -f $keyed.Count, $filled) -ForegroundColor Cyan

    # ---------------- 2. 経路をまたいだ組を作る ----------------
    # 通知1件と同期1件の1対1。同じ経路どうしは決して束ねない ――
    # 件名も差出人も同じメールが続けて2通来ることは普通にあり、
    # 経路内で束ねると片方が消える。
    $window = $WindowMinutes * 60
    $pairs = @()
    $takenSync = @{}
    foreach ($g in ($keyed | Group-Object key)) {
        $notes = @($g.Group | Where-Object { $_.source -eq 'notification' } | Sort-Object when)
        $syncs = @($g.Group | Where-Object { $_.source -ne 'notification' } | Sort-Object when)
        if ($notes.Count -eq 0 -or $syncs.Count -eq 0) { continue }

        foreach ($n in $notes) {
            $best = $null; $bestGap = $null
            foreach ($s in $syncs) {
                if ($takenSync[$s.id]) { continue }
                $gap = [Math]::Abs(($s.when - $n.when).TotalSeconds)
                if ($gap -gt $window) { continue }
                if ($null -eq $bestGap -or $gap -lt $bestGap) { $best = $s; $bestGap = $gap }
            }
            if ($best) {
                $takenSync[$best.id] = $true
                $pairs += [pscustomobject]@{ note = $n.id; sync = $best.id; gap = [int] $bestGap }
            }
        }
    }

    # ---------------- 3. 同期側に寄せる ----------------
    $stats = @{ archived = 0; moved = 0; marked = 0 }

    foreach ($p in $pairs) {
        $nTask = Get-TaskIdByEvent -Conn $conn -EventId $p.note
        $cTask = Get-TaskIdByEvent -Conn $conn -EventId $p.sync
        $label = "{0} (差 {1} 秒)" -f $p.sync, $p.gap

        if ($nTask -and $cTask) {
            # 2枚ある。同期側を残し、通知側を畳む。
            Write-Host ("  #{0}(通知) を #{1}(同期) に統合: {2}" -f $nTask, $cTask, $label) -ForegroundColor Magenta
            if (-not $DryRun) {
                [void] (Set-TaskArchived -Conn $conn -TaskId $nTask -Archived $true)
                Add-TaskActivity -Conn $conn -TaskId $nTask -Kind 'step' `
                    -Message ("同じ内容が同期から取れているため、カード #{0} に統合してアーカイブしました" -f $cTask)
                Add-TaskActivity -Conn $conn -TaskId $cTask -Kind 'step' `
                    -Message ("同じ内容の通知から立っていたカード #{0} をここに統合しました" -f $nTask)
                Set-EventSuperseded -Conn $conn -EventId $p.note -CanonicalId $p.sync
            }
            $stats.archived++
        }
        elseif ($nTask) {
            # 通知側にだけカードがある。土台を同期側に差し替える。
            Write-Host ("  #{0} の元を同期に差し替え: {1}" -f $nTask, $label) -ForegroundColor Green
            if (-not $DryRun) {
                Move-TaskEvent -Conn $conn -TaskId $nTask -EventId $p.sync
                Add-TaskActivity -Conn $conn -TaskId $nTask -Kind 'step' `
                    -Message '同期で本文が取れたので、このカードの元を通知から同期に差し替えました'
                Set-EventSuperseded -Conn $conn -EventId $p.note -CanonicalId $p.sync
                if (-not (Test-EventTriaged -Conn $conn -EventId $p.sync)) {
                    Add-TriageLog -Conn $conn -EventId $p.sync -DecidedBy 'dedup' -RuleName 'dedup.promoted' -NeedsAction $null
                }
            }
            $stats.moved++
        }
        else {
            # 通知側はカードになっていない。カードにしない印だけ付ける。
            Write-Host ("  通知をカード対象から外す: {0}" -f $label) -ForegroundColor DarkGray
            if (-not $DryRun) {
                Set-EventSuperseded -Conn $conn -EventId $p.note -CanonicalId $p.sync
                if (-not (Test-EventTriaged -Conn $conn -EventId $p.note)) {
                    Add-TriageLog -Conn $conn -EventId $p.note -DecidedBy 'dedup' -RuleName 'dedup.superseded' -NeedsAction $null
                }
            }
            $stats.marked++
        }
    }

    Write-Host ''
    Write-Host ("アーカイブ {0} / 差し替え {1} / 対象外 {2}{3}" -f `
        $stats.archived, $stats.moved, $stats.marked, $(if ($DryRun) { ' (DryRun: 書き込みなし)' } else { '' })) -ForegroundColor Yellow
}
finally { $conn.Dispose() }
