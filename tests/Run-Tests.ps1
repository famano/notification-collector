<#
.SYNOPSIS
    テストを実行する。追加インストールは不要。

.DESCRIPTION
    tests\cases\*.Tests.ps1 を順に読み込んで実行し、結果をまとめて出す。
    Pester は使わない (PowerShell 5.1 同梱版では新しい書き方が動かないため)。

    外部サービスも API キーも要らない。DB を使うテストは一時フォルダに
    作って捨てる。実際の tasks.db には触らない。

.PARAMETER Filter
    ファイル名の一部。指定するとその名前を含むケースだけ実行する。

.EXAMPLE
    .\tests\Run-Tests.ps1
    .\tests\Run-Tests.ps1 -Filter Dossier
#>
[CmdletBinding()]
param([string] $Filter)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\TestKit.ps1"

$RepoRoot = Split-Path -Parent $PSScriptRoot

$files = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'cases') -Filter '*.Tests.ps1' -File |
           Sort-Object Name)
if ($Filter) { $files = @($files | Where-Object { $_.Name -like ("*" + $Filter + "*") }) }

if ($files.Count -eq 0) {
    Write-Host '実行するテストがありません。' -ForegroundColor Yellow
    exit 1
}

foreach ($f in $files) {
    try { . $f.FullName }
    catch {
        Write-Host ''
        Write-Host ("読み込みに失敗: {0}" -f $f.Name) -ForegroundColor Red
        Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor Red
        # 読み込めなかったこと自体を失敗として数える。黙って 0 件成功にしない。
        It ($f.Name + ' の読み込み') { throw $_.Exception.Message }
    }
}

Clear-TestTemp

$s = Get-TestSummary
Write-Host ''
if ($s.failed -gt 0) {
    Write-Host '失敗したテスト:' -ForegroundColor Red
    foreach ($x in $s.failures) {
        Write-Host ("  - {0}" -f $x.where) -ForegroundColor Red
        Write-Host ("      {0}" -f $x.message) -ForegroundColor DarkRed
    }
    Write-Host ''
}
$color = if ($s.failed -gt 0) { 'Red' } else { 'Green' }
Write-Host ("成功 {0} / 失敗 {1} / 飛ばし {2}" -f $s.passed, $s.failed, $s.skipped) -ForegroundColor $color

exit $(if ($s.failed -gt 0) { 1 } else { 0 })
