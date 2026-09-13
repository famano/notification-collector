<#
.SYNOPSIS
    配った先で最初に一度だけ実行する。ショートカットを作り、ダブルクリックで
    起動できる状態にする。(Install.cmd をダブルクリックすればこれが動く)

.DESCRIPTION
    配布先の利用者に「PowerShell を開いて、実行ポリシーを緩めて、スクリプトを
    フルパスで叩いてください」と頼むことはできない。頼めば、たいてい動かないまま
    放置される。そこでこのスクリプトが、その手順を全部肩代わりする。

      1. ZIP で受け取ったファイルのブロックを外す
         (インターネット経由のファイルは「ブロックされています」で実行を拒まれる。
          非エンジニアには最も気付きにくい失敗で、症状は「何も起きない」)
      2. デスクトップにショートカットを作る
      3. 必要ならサインイン時に自動起動させる
      4. 足りない設定を数え、次に何をすればよいかだけを出す

    管理者権限は要らない。書き込む先は自分のデスクトップとスタートアップだけ。

.PARAMETER AtLogon
    サインイン時の自動起動を登録する (聞かずに実行する)。

.PARAMETER NoAtLogon
    自動起動を登録しない (聞かずに実行する)。

.PARAMETER Uninstall
    作ったショートカットを消す。データや資格情報には触らない。

.EXAMPLE
    .\Install.ps1
    .\Install.ps1 -AtLogon
    .\Install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch] $AtLogon,
    [switch] $NoAtLogon,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$AppName      = '通知コレクター'
$Root         = $PSScriptRoot
$StartCmd     = Join-Path $Root 'Start.cmd'
$DesktopDir   = [Environment]::GetFolderPath('Desktop')
$StartupDir   = [Environment]::GetFolderPath('Startup')
$DesktopLink  = Join-Path $DesktopDir ($AppName + '.lnk')
$StartupLink  = Join-Path $StartupDir ($AppName + '.lnk')

function Write-Step { param([string] $Text) Write-Host ("  " + $Text) -ForegroundColor Green }
function Write-Note { param([string] $Text) Write-Host ("  " + $Text) -ForegroundColor DarkGray }

Write-Host ''
Write-Host ("{0} のセットアップ" -f $AppName) -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- 削除

function Remove-Link {
    param([string] $Path, [string] $Label)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        Write-Step ("{0} のショートカットを削除しました" -f $Label)
    }
    else { Write-Note ("{0} のショートカットはありません" -f $Label) }
}

if ($Uninstall) {
    Remove-Link -Path $DesktopLink -Label 'デスクトップ'
    Remove-Link -Path $StartupLink -Label '自動起動'
    Write-Host ''
    Write-Note 'カードと資格情報は消していません。'
    Write-Note ("完全に消すにはフォルダごと削除してください: {0}" -f $Root)
    Write-Host ''
    return
}

# ---------------------------------------------------------------- 前提の確認

$psv = $PSVersionTable.PSVersion
Write-Note ("PowerShell {0}" -f $psv)
if ($psv.Major -lt 5) {
    Write-Host '  PowerShell 5.1 以上が要ります。Windows Update を当ててから実行してください。' -ForegroundColor Red
    Write-Host ''
    return
}

# 通知の取得は Windows 同梱の winsqlite3.dll を使う。無い環境 (Windows 10 より前) では
# 収集が動かない。ここで言わないと「カードが増えない」としてしか現れない。
$sqlite = Join-Path $env:SystemRoot 'System32\winsqlite3.dll'
if (-not (Test-Path $sqlite)) {
    Write-Host '  winsqlite3.dll が見つかりません。Windows 10 以降が必要です。' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- ブロックの解除

# ZIP で配ると、展開したファイルに「別のコンピューターから来た」印 (Zone.Identifier) が付く。
# 付いたままだと実行が拒まれるのに、画面には何も出ないことがある。
$unblocked = 0
if (Get-Command Unblock-File -ErrorAction SilentlyContinue) {
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.ps1', '*.cmd', '*.bat', '*.html' -ErrorAction SilentlyContinue)) {
        try {
            if (Get-Item -LiteralPath $f.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) {
                Unblock-File -LiteralPath $f.FullName -ErrorAction SilentlyContinue
                $unblocked++
            }
        }
        catch { }
    }
}
if ($unblocked -gt 0) { Write-Step ("ファイルのブロックを解除しました ({0} 件)" -f $unblocked) }

# ---------------------------------------------------------------- ショートカット

function New-AppShortcut {
    param([Parameter(Mandatory)] [string] $Path, [string] $Description)
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($Path)
    $lnk.TargetPath       = $StartCmd
    $lnk.WorkingDirectory = $Root
    $lnk.Description      = $Description
    # 最小化で開く。窓を消してしまうと「動いているのか」も「止め方」も分からなくなり、
    # かといって前面に出し続けると邪魔なので閉じられる (閉じると止まる)。
    $lnk.WindowStyle      = 7
    $lnk.Save()
}

if (-not (Test-Path -LiteralPath $StartCmd)) {
    Write-Host ("  Start.cmd が見つかりません: {0}" -f $StartCmd) -ForegroundColor Red
    Write-Host '  フォルダを丸ごと展開できているか確認してください。' -ForegroundColor Red
    Write-Host ''
    return
}

New-AppShortcut -Path $DesktopLink -Description ("{0} を起動する" -f $AppName)
Write-Step ("デスクトップに「{0}」を作りました" -f $AppName)

# ---------------------------------------------------------------- 自動起動

$wantLogon = $false
if ($AtLogon)        { $wantLogon = $true }
elseif ($NoAtLogon)  { $wantLogon = $false }
else {
    Write-Host ''
    Write-Host '  サインインしたときに自動で起動しますか?' -ForegroundColor Cyan
    Write-Host '  (通知は数十件しか保持されないため、起動していない間のものは' -ForegroundColor DarkGray
    Write-Host '   メールと Slack から後で拾い直します。自動起動にしておくと取りこぼしが減ります)' -ForegroundColor DarkGray
    $ans = Read-Host '  [Y] はい / [N] いいえ'
    $wantLogon = ($ans -match '^(y|Y|はい)')
}

if ($wantLogon) {
    New-AppShortcut -Path $StartupLink -Description ("{0} をサインイン時に起動する" -f $AppName)
    Write-Step 'サインイン時に自動で起動します'
}
else {
    if (Test-Path -LiteralPath $StartupLink) { Remove-Item -LiteralPath $StartupLink -Force -ErrorAction SilentlyContinue }
    Write-Note '自動起動は登録しませんでした (あとで Install.cmd を実行すれば変えられます)'
}

# ---------------------------------------------------------------- 残りの設定

. "$Root\lib\ApiKey.ps1"

Write-Host ''
$imported = @()
try { $imported = @(Import-AppConfigSecrets) } catch { }
if ($imported.Count -gt 0) {
    Write-Step ("配布設定から {0} 件の資格情報を取り込みました" -f $imported.Count)
    Write-Note '(値は暗号化して保存しました。config\app-config.json からは消してかまいません)'
}

$keyOk = $false
try { $keyOk = Test-AnthropicConfigured } catch { }

Write-Host ''
Write-Host '次にすること' -ForegroundColor Cyan
if ($keyOk) {
    Write-Host ("  デスクトップの「{0}」をダブルクリックすると始まります。" -f $AppName)
    Write-Host '  ブラウザでカンバンが開きます。' -ForegroundColor DarkGray
}
else {
    Write-Host ("  1. デスクトップの「{0}」をダブルクリックする" -f $AppName)
    Write-Host '  2. 開いたカンバンの右上「接続」から Claude の API キーを入れる'
    Write-Host '     (キーが入るまでカードは作られません。取り込みだけが動きます)' -ForegroundColor DarkGray
    Write-Host '  3. 同じ画面から Slack / Gmail / GitHub も繋げます (任意)' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host ("止めるとき: Stop.cmd をダブルクリック、または窓を閉じる") -ForegroundColor DarkGray
Write-Host ''
