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

# ---------------------------------------------------------------- アカウントの名前空間
#
# 一つの連携先に複数のアカウントがあることがある (仕事用と個人用の Gmail、
# 二つのワークスペースの Slack、二つの Backlog スペース)。全部の通知をさばくには、
# 資格情報を「連携先につき1組」ではなく「アカウントにつき1組」で持つ必要がある。
#
# やり方は名前空間を分けるだけにする。呼ぶ側 (コネクタ) は今までどおり
# Get-Secret -Name 'slack.userToken' と書き、**いま選ばれているアカウント**に応じて
# ここが 'slack.userToken#2' に読み替える。コネクタ側に一行も足さずに済み、
# 「切り替えたつもりで前のトークンを使っていた」という失敗の形が生まれない。
#
# 1人目だけは接尾辞を付けない。既存の保管庫がそのまま1人目として読めるので、
# 移行が要らない ―― 移行の要る変更は、配った先で一番高くつく。

$script:PrimaryAccountId = '1'

# 秘密の名前 → どの連携先のものか。名前の頭で決まる。
# 'account.<連携先>' (どのアカウントとして繋がったかの表示名) だけは後ろが連携先。
$script:SecretServiceOfPrefix = @{
    slack = 'slack'; gmail = 'google'; ms = 'microsoft'
    chatwork = 'chatwork'; backlog = 'backlog'; github = 'github'
}

# アカウントをまたいで共有される値。
#
# 同意画面に使うアプリ登録 (クライアント ID と秘密) は**配る人が1つ用意するもの**で、
# 繋ぐ先のアカウントが増えても同じものを使う。ここまでアカウント単位にすると、
# 2つ目を繋ぐときに「配布時に設定済み」が効かなくなり、利用者の手では取れない値を
# 空欄として出すことになる (それは永久に埋まらない欄になる)。
#
# ms.tenantId と backlog.space はここに入れない。**アカウントごとに違う**
# (別テナントの職場アカウント、別スペースの Backlog) ためである。
$script:SharedSecretNames = @(
    'slack.clientId', 'slack.clientSecret',
    'gmail.clientId', 'gmail.clientSecret',
    'ms.clientId',    'ms.clientSecret'
)

# 二重に読み込まれても選択とハンドラを失わないようにする。
# コネクタは各自このファイルを読み込むので、初期化は何度も走る。
if (-not (Get-Variable -Name 'CurrentAccountId' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CurrentAccountId = @{}
}
if (-not (Get-Variable -Name 'AccountResetHandlers' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AccountResetHandlers = @{}
}

function Get-PrimaryAccountId { return $script:PrimaryAccountId }

function Get-SecretService {
    <#
      .SYNOPSIS
        秘密の名前から、どの連携先のものかを返す。分からなければ空 (= アカウントで分けない)。
    #>
    param([string] $Name)
    if (-not $Name) { return '' }
    $parts = $Name -split '\.', 2
    if ($parts[0] -eq 'account' -and $parts.Count -eq 2) { return $parts[1] }
    if ($script:SecretServiceOfPrefix.ContainsKey($parts[0])) { return $script:SecretServiceOfPrefix[$parts[0]] }
    return ''
}

function Get-CurrentAccountId {
    param([string] $Service)
    if ($Service -and $script:CurrentAccountId.ContainsKey($Service)) {
        return [string] $script:CurrentAccountId[$Service]
    }
    return $script:PrimaryAccountId
}

function Resolve-SecretName {
    <#
      .SYNOPSIS
        保管庫に実際に置く名前。1人目はそのまま、2人目以降は '#<id>' が付く。
    #>
    param([Parameter(Mandatory)] [string] $Name, [string] $AccountId)
    if ($script:SharedSecretNames -contains $Name) { return $Name }
    $svc = Get-SecretService $Name
    if (-not $svc) { return $Name }
    $id = if ($AccountId) { [string] $AccountId } else { Get-CurrentAccountId $svc }
    if (-not $id -or $id -eq $script:PrimaryAccountId) { return $Name }
    return ("{0}#{1}" -f $Name, $id)
}

function Register-AccountReset {
    <#
      .SYNOPSIS
        アカウントが切り替わったときに落とすキャッシュを登録する。
      .DESCRIPTION
        コネクタはアクセストークン・自分のユーザーID・部屋名をモジュール変数に溜めている。
        別のアカウントに切り替えたあとそれが残っていると、**別のワークスペースの名前で
        別のワークスペースのメッセージを読む**ことになる。落とすのは持ち主であるコネクタの仕事。
    #>
    param([Parameter(Mandatory)] [string] $Service, [Parameter(Mandatory)] [scriptblock] $Handler)
    if (-not $script:AccountResetHandlers.ContainsKey($Service)) { $script:AccountResetHandlers[$Service] = @() }
    # コネクタは複数の入口から読み込まれる。同じものを何度も積むと、
    # 切り替えのたびに同じキャッシュを何度も落とすだけの手数になる。
    $text = $Handler.ToString()
    foreach ($h in $script:AccountResetHandlers[$Service]) { if ($h.ToString() -eq $text) { return } }
    $script:AccountResetHandlers[$Service] += $Handler
}

function Reset-ServiceAccountCache {
    param([Parameter(Mandatory)] [string] $Service)
    if (-not $script:AccountResetHandlers.ContainsKey($Service)) { return }
    # 1つが投げても残りは落とす。落とし損ねたキャッシュのほうが害が大きい。
    foreach ($h in $script:AccountResetHandlers[$Service]) { try { & $h } catch { } }
}

function Use-ServiceAccount {
    <#
      .SYNOPSIS
        以降の Get-Secret / Set-Secret を、この連携先のこのアカウントのものにする。
      .OUTPUTS
        [string] 実際に選ばれたアカウント ID
    #>
    param([Parameter(Mandatory)] [string] $Service, [string] $Id)
    if (-not $Id) { $Id = $script:PrimaryAccountId }
    $wanted = [string] $Id
    $prev = Get-CurrentAccountId $Service
    $script:CurrentAccountId[$Service] = $wanted
    if ($prev -ne $wanted) { Reset-ServiceAccountCache -Service $Service }
    return $wanted
}

# 1件取り出す。$Name は 'slack.userToken' のようなドット区切り。
function Get-Secret {
    # -AccountId を渡すと、いま選ばれているアカウントではなく、そのアカウントのものを読む
    # (設定画面が全アカウントの状態を一度に並べるのに要る)。
    param([Parameter(Mandatory)] [string] $Name, [string] $Path, [string] $AccountId)
    $key = Resolve-SecretName -Name $Name -AccountId $AccountId
    $s = Read-SecretStore -Path $Path
    if ($s.ContainsKey($key)) { return [string] $s[$key] }
    return $null
}

function Set-Secret {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Value, [string] $Path, [string] $AccountId)
    $key = Resolve-SecretName -Name $Name -AccountId $AccountId
    $s = Read-SecretStore -Path $Path
    $s[$key] = $Value
    Write-SecretStore -Store $s -Path $Path
}

function Remove-Secret {
    param([Parameter(Mandatory)] [string] $Name, [string] $Path, [string] $AccountId)
    $key = Resolve-SecretName -Name $Name -AccountId $AccountId
    $s = Read-SecretStore -Path $Path
    if ($s.ContainsKey($key)) { $s.Remove($key); Write-SecretStore -Store $s -Path $Path; return $true }
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
