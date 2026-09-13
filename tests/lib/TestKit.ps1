# TestKit.ps1
# 依存ゼロの最小テストキット。
#
# Pester を使わない理由: PowerShell 5.1 に同梱されているのは Pester 3 で、
# 新しい構文で書くと利用者の環境によって動いたり動かなかったりする。
# 「追加インストールは不要」がこのリポジトリの前提なので、テストも同じ前提で動かす。
#
# 使い方は tests\Run-Tests.ps1 を実行するだけ。書き方は tests\cases\*.Tests.ps1 を参照。

$script:Suite   = ''
$script:Passed  = 0
$script:Failed  = 0
$script:Skipped = 0
$script:Failures = @()
$script:TempPaths = @()

function Describe {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [scriptblock] $Body)
    $script:Suite = $Name
    Write-Host ''
    Write-Host $Name -ForegroundColor Cyan
    & $Body
    $script:Suite = ''
}

function It {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [scriptblock] $Body)
    try {
        & $Body
        $script:Passed++
        Write-Host ("  ok   " + $Name) -ForegroundColor DarkGray
    }
    catch {
        $script:Failed++
        $where = "{0} / {1}" -f $script:Suite, $Name
        $script:Failures += [pscustomobject]@{ where = $where; message = $_.Exception.Message }
        Write-Host ("  FAIL " + $Name) -ForegroundColor Red
        Write-Host ("       " + $_.Exception.Message) -ForegroundColor Red
    }
}

# 環境が足りずに実行できないものは、失敗ではなく飛ばす。
# (winsqlite3.dll の無い環境など。黙って通すと「通った」と誤解されるので必ず出す)
function Skip-It {
    param([Parameter(Mandatory)] [string] $Name, [string] $Reason)
    $script:Skipped++
    Write-Host ("  skip " + $Name + " (" + $Reason + ")") -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 検査

function Assert-True {
    param($Value, [string] $Message = '真であることを期待しました')
    if (-not $Value) { throw $Message }
}

function Assert-False {
    param($Value, [string] $Message = '偽であることを期待しました')
    if ($Value) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    # $null どうしの比較は -eq で落ちないのでここで先に見る
    if ($null -eq $Expected -and $null -eq $Actual) { return }
    if ($Expected -is [array] -or $Actual -is [array]) {
        $e = @($Expected) -join '|'
        $a = @($Actual) -join '|'
        if ($e -ne $a) { throw ("{0}期待 [{1}] / 実際 [{2}]" -f $(if ($Message) { $Message + ': ' } else { '' }), $e, $a) }
        return
    }
    if ($Expected -ne $Actual) {
        throw ("{0}期待 [{1}] / 実際 [{2}]" -f $(if ($Message) { $Message + ': ' } else { '' }), $Expected, $Actual)
    }
}

function Assert-NotEqual {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -eq $Actual) {
        throw ("{0}[{1}] と異なる値を期待しました" -f $(if ($Message) { $Message + ': ' } else { '' }), $Expected)
    }
}

function Assert-Null {
    param($Value, [string] $Message = 'null を期待しました')
    if ($null -ne $Value -and $Value -ne '') { throw ("{0} (実際 [{1}])" -f $Message, $Value) }
}

function Assert-NotNull {
    param($Value, [string] $Message = 'null でない値を期待しました')
    if ($null -eq $Value -or $Value -eq '') { throw $Message }
}

function Assert-Match {
    param([string] $Pattern, [string] $Value, [string] $Message)
    if ($Value -notmatch $Pattern) {
        throw ("{0}[{1}] が /{2}/ に一致しません" -f $(if ($Message) { $Message + ': ' } else { '' }), $Value, $Pattern)
    }
}

function Assert-Throws {
    param([Parameter(Mandatory)] [scriptblock] $Body, [string] $Message = '例外を期待しました')
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

# ---------------------------------------------------------------- 一時ファイル

function New-TestTempDir {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('nc-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    $script:TempPaths += $p
    return $p
}

# テスト用のタスクストア。使い終わりは Close-TestStore で閉じる。
function New-TestStore {
    $dir = New-TestTempDir
    return (Open-TaskStore -Path (Join-Path $dir 'tasks.db'))
}

function Close-TestStore {
    param($Conn)
    if ($Conn) { $Conn.Dispose() }
}

function Clear-TestTemp {
    foreach ($p in $script:TempPaths) {
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:TempPaths = @()
}

# 通知DB (winsqlite3.dll) が使える環境か。無い環境ではストアを使うテストを飛ばす。
function Test-SqliteAvailable {
    if ($null -ne $script:SqliteOk) { return $script:SqliteOk }
    $script:SqliteOk = $false
    try {
        $c = New-TestStore
        Close-TestStore $c
        $script:SqliteOk = $true
    }
    catch { }
    return $script:SqliteOk
}

function Get-TestSummary {
    return [pscustomobject]@{
        passed = $script:Passed; failed = $script:Failed; skipped = $script:Skipped
        failures = $script:Failures
    }
}
