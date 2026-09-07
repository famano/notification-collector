# SecretStore.ps1
# 資格情報を DPAPI (CurrentUser) で暗号化して保存する。
#
# 平文の JSON に置かないこと。トークンはメールボックスや Slack の全履歴への
# 鍵そのもので、リポジトリや同期フォルダに紛れ込むと影響が大きい。
# DPAPI CurrentUser なら、同じ Windows ユーザーでログオンしていないと復号できず、
# ファイルを別マシンにコピーしても使えない。

Add-Type -AssemblyName System.Security

function Get-SecretStorePath {
    param([string] $Path)
    if ($Path) { return $Path }
    $dir = Join-Path $PSScriptRoot '..\data'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path ([IO.Path]::GetFullPath($dir)) 'secrets.dat')
}

function Protect-Text {
    param([string] $Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($enc)
}

function Unprotect-Text {
    param([string] $Base64)
    $enc = [Convert]::FromBase64String($Base64)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Read-SecretStore {
    param([string] $Path)
    $p = Get-SecretStorePath $Path
    if (-not (Test-Path $p)) { return @{} }
    try {
        $json = Unprotect-Text ([IO.File]::ReadAllText($p, [Text.Encoding]::ASCII))
        $obj = $json | ConvertFrom-Json
        $h = @{}
        foreach ($k in $obj.PSObject.Properties.Name) { $h[$k] = $obj.$k }
        return $h
    }
    catch {
        throw "資格情報ストアを復号できません。別のユーザーまたは別のPCで作られたものの可能性があります: $p"
    }
}

function Write-SecretStore {
    param([hashtable] $Store, [string] $Path)
    $p = Get-SecretStorePath $Path
    $json = ($Store | ConvertTo-Json -Depth 8 -Compress)
    [IO.File]::WriteAllText($p, (Protect-Text $json), [Text.Encoding]::ASCII)
}

# 1件取り出す。$Name は 'slack.botToken' のようなドット区切り。
function Get-Secret {
    param([Parameter(Mandatory)] [string] $Name, [string] $Path)
    $s = Read-SecretStore -Path $Path
    if ($s.ContainsKey($Name)) { return [string] $s[$Name] }
    return $null
}

function Set-Secret {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Value, [string] $Path)
    $s = Read-SecretStore -Path $Path
    $s[$Name] = $Value
    Write-SecretStore -Store $s -Path $Path
}

function Remove-Secret {
    param([Parameter(Mandatory)] [string] $Name, [string] $Path)
    $s = Read-SecretStore -Path $Path
    if ($s.ContainsKey($Name)) { $s.Remove($Name); Write-SecretStore -Store $s -Path $Path; return $true }
    return $false
}

# 画面に出す用。トークンそのものは絶対に出さない。
function Get-SecretNames {
    param([string] $Path)
    return @((Read-SecretStore -Path $Path).Keys | Sort-Object)
}
