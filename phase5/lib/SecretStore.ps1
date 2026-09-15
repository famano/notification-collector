# SecretStore.ps1
# 資格情報を DPAPI (CurrentUser) で暗号化して保存する。
#
# 平文の JSON に置かないこと。トークンはメールボックスや Slack の全履歴への
# 鍵そのもので、リポジトリや同期フォルダに紛れ込むと影響が大きい。
# DPAPI CurrentUser なら、同じ Windows ユーザーでログオンしていないと復号できず、
# ファイルを別マシンにコピーしても使えない。

Add-Type -AssemblyName System.Security

function Set-PrivateFileAcl {
    <#
      .SYNOPSIS
        そのファイルを「このユーザーだけが読める」状態にする。
      .DESCRIPTION
        DPAPI は中身を守るが、**ファイルの見え方までは変えない。** 既定では
        Users グループに読み取りが継承されていることがあり、同じ PC の別アカウントに
        暗号文ごとコピーされうる (復号はできないが、持ち出しの一歩にはなる)。
        平文で置かざるを得ない配布設定では、もっと直接的に効く。

        守れる範囲は限られる ―― **同じユーザーで動くプロセスからは守れない。**
        管理者は所有権を取れる。ここで消せるのは「同居している別アカウント」と
        「うっかり共有フォルダに置いた」場合の露出だけで、それ以上ではない。
      .OUTPUTS
        [bool] 絞れたかどうか (Windows 以外や失敗時は $false)
    #>
    param([Parameter(Mandatory)] [string] $Path)
    # PowerShell 7 以降は $IsWindows がある。5.1 には無いので $null を Windows と見なす。
    if ($null -ne $IsWindows -and -not $IsWindows) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $me  = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = New-Object Security.AccessControl.FileSecurity
        # 継承を切ってから自分だけを足す。足すだけでは既存の継承が残る。
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $me, 'FullControl', 'Allow')))
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

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
    [void] (Set-PrivateFileAcl -Path $p)
}

# 1件取り出す。$Name は 'slack.userToken' のようなドット区切り。
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

# 保管しているもののうち、**秘密ではない識別子。**
#
# ここに挙げるのは、隠しても何も守れない値である ―― OAuth のクライアント ID、
# テナント ID、Backlog のスペース名。どれも URL やリクエストに載って当たり前のもので、
# 相手に渡らなければ API が呼べない。保管庫に入っているのは
# 「利用者に一度だけ入力させて覚えておく」ためであって、秘匿のためではない。
#
# 何のために区別するか:
#   漏洩検査 (Test-SecretLeak) は「保管中の値がリクエストに混ざっていたら送らない」。
#   識別子まで同じ扱いにすると、**何も間違っていない呼び出しが止まる。** 実際、
#   Backlog のスペース名 (example.backlog.jp) はホスト名そのものなので、
#   Backlog へのリクエストは全部「資格情報が含まれていた」として中止されていた。
#   検査から外すのはここに挙げたものだけで、**知らない名前は秘密として扱う。**
$script:NonSecretNames = @(
    # もう保存しない値だが、以前の保管庫に残っていることがある (組織 ID)。
    # 残っていても止める理由は無いので、外したままにしておく。
    'anthropic.organizationId',
    'gmail.clientId',
    'slack.clientId', 'slack.selfUserId',
    'ms.clientId', 'ms.tenantId', 'ms.selfUserId',
    'chatwork.selfAccountId',
    'backlog.space'
)

function Test-SecretConfidential {
    <#
      .SYNOPSIS
        その名前で保管している値を、秘密として扱うべきか。
      .DESCRIPTION
        知らない名前は $true (秘密) を返す。新しい資格情報を足したときに
        黙って検査の外に出ないようにするため、緩める側は必ず明示で書く。
    #>
    param([Parameter(Mandatory)] [string] $Name)
    return (-not ($script:NonSecretNames -contains $Name))
}

function Get-NonSecretNames {
    return @($script:NonSecretNames)
}
