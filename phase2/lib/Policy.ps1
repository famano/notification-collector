# Policy.ps1
# トリアージ方針 (policy.json) の読み書き。
#
# なぜ要るか:
#   policy.json には2種類のことが書いてある。
#     ignore  … LLM に渡さず捨てる通知。前段でコストを落とすためのふるい
#     context … 利用者の名前・役割・優先事項。判定の精度そのもの
#   どちらも**使っているうちに育つ**性質のものである。「この通知は要らなかった」
#   「これは急ぎだった」は、カードを見て初めて分かる。
#
#   ところがこれを直す手段はテキストエディタしか無かった。カンバンを見ながら
#   「これは今後要らない」と思った時点で、別のアプリを開いて JSON を編集し、
#   保存して、次の周回を待つことになる。気付いた場所と直せる場所が離れていると、
#   たいてい直されないまま同じ通知が毎回 LLM に流れ続ける。
#
#   カードを閉じる操作と同じ場所に置けるように、読み書きを関数にする。
#
# 方針:
#   - コメント (_comment) は残す。読む人向けの説明なので、書き換えで消さない
#   - 書き込みは全体の読み直し → 差し替え → 書き戻し。部分更新はしない
#   - 規則は増える一方なので上限を設ける。際限なく積むと前段が遅くなる

$script:MaxIgnorePatterns = 200
$script:MaxPatternLength  = 200

function Get-PolicyPath {
    param([string] $Path)
    if ($Path) { return $Path }
    return (Join-Path $PSScriptRoot '..\config\policy.json')
}

function Read-Policy {
    param([string] $Path)
    $p = Get-PolicyPath $Path
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# PowerShell 5.1 の ConvertTo-Json は非 ASCII を \uXXXX に逃がす。
# JSON としては正しいが、policy.json は**人が読んで直すファイル**である。
# 書き戻すたびに _comment もふるいの条件も見えない文字列に変わっていくのでは、
# カンバンから直せるようにした意味が薄れる。
# (7.x は既定で逃がさないので、この関数は何もしないまま通る)
function ConvertFrom-JsonUnicodeEscape {
    param([string] $Json)
    if (-not $Json) { return '' }
    return [regex]::Replace($Json, '\\u([0-9a-fA-F]{4})', {
        param($m)
        $code = [Convert]::ToInt32($m.Groups[1].Value, 16)
        # 制御文字と、JSON で別途エスケープが要る文字はそのままにしておく。
        # 戻すと壊れた JSON になる。
        if ($code -lt 0x20 -or $code -eq 0x22 -or $code -eq 0x5C -or $code -eq 0x7F) {
            return $m.Value
        }
        return [string][char] $code
    })
}

function Save-Policy {
    <#
      .SYNOPSIS
        policy.json を書き戻す。
      .DESCRIPTION
        BOM は付けない。.ps1 と違って JSON は BOM を嫌う読み手がいるうえ、
        PowerShell の ConvertFrom-Json は BOM 無しでも問題なく読める。
    #>
    param([Parameter(Mandatory)] $Policy, [string] $Path)
    $p = [IO.Path]::GetFullPath((Get-PolicyPath $Path))
    $json = ConvertFrom-JsonUnicodeEscape ($Policy | ConvertTo-Json -Depth 10)
    [IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding($false)))
}

# 配列を PowerShell 5.1 でも素直に扱える形にそろえる。
# ConvertFrom-Json は要素1個の配列をスカラーにするため、
# そのまま += すると型が壊れる。
function ConvertTo-PatternArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value | Where-Object { $_ -ne $null -and [string] $_ -ne '' } | ForEach-Object { [string] $_ })
}

function Get-IgnoreList {
    param([Parameter(Mandatory)] $Policy, [Parameter(Mandatory)] [ValidateSet('appId', 'title')] [string] $Kind)
    if (-not $Policy.ignore) { return @() }
    $name = if ($Kind -eq 'appId') { 'appIdPatterns' } else { 'titlePatterns' }
    return (ConvertTo-PatternArray $Policy.ignore.$name)
}

function Set-IgnoreList {
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [ValidateSet('appId', 'title')] [string] $Kind,
        [string[]] $Patterns
    )
    $name = if ($Kind -eq 'appId') { 'appIdPatterns' } else { 'titlePatterns' }
    if (-not $Policy.ignore) {
        Add-Member -InputObject $Policy -NotePropertyName 'ignore' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    Add-Member -InputObject $Policy.ignore -NotePropertyName $name -NotePropertyValue ([string[]] $Patterns) -Force
}

function Add-IgnorePattern {
    <#
      .SYNOPSIS
        ふるいに1件足す。
      .OUTPUTS
        [pscustomobject] ok / error / policy
    #>
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [ValidateSet('appId', 'title')] [string] $Kind,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Pattern
    )
    $v = ([string] $Pattern).Trim()
    if (-not $v) { return [pscustomobject]@{ ok = $false; error = '空の条件は追加できません。' } }
    if ($v.Length -gt $script:MaxPatternLength) {
        return [pscustomobject]@{ ok = $false; error = '条件が長すぎます。' }
    }
    # 「*」だけの条件はすべてを捨てる。事故なので受け付けない。
    if ($v -replace '\*', '' -eq '') {
        return [pscustomobject]@{ ok = $false; error = 'すべてに一致する条件は追加できません。' }
    }
    $list = @(Get-IgnoreList -Policy $Policy -Kind $Kind)
    if ($list -contains $v) { return [pscustomobject]@{ ok = $false; error = 'すでに入っています。' } }
    if ($list.Count -ge $script:MaxIgnorePatterns) {
        return [pscustomobject]@{ ok = $false; error = '条件が多すぎます。使わないものを消してください。' }
    }
    Set-IgnoreList -Policy $Policy -Kind $Kind -Patterns (@($list) + $v)
    return [pscustomobject]@{ ok = $true; error = '' }
}

function Remove-IgnorePattern {
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [ValidateSet('appId', 'title')] [string] $Kind,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Pattern
    )
    $list = @(Get-IgnoreList -Policy $Policy -Kind $Kind)
    if ($list -notcontains $Pattern) { return [pscustomobject]@{ ok = $false; error = '見つかりません。' } }
    Set-IgnoreList -Policy $Policy -Kind $Kind -Patterns (@($list | Where-Object { $_ -ne $Pattern }))
    return [pscustomobject]@{ ok = $true; error = '' }
}

# 判断の背景。ここが埋まっているほど判定が当たる。
function Set-PolicyContext {
    param(
        [Parameter(Mandatory)] $Policy,
        [AllowEmptyString()] [string] $UserName,
        [AllowEmptyString()] [string] $Role,
        [string[]] $Priorities
    )
    if (-not $Policy.context) {
        Add-Member -InputObject $Policy -NotePropertyName 'context' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $limit = { param([string] $t) if ($t.Length -gt 200) { return $t.Substring(0, 200) } else { return $t } }
    Add-Member -InputObject $Policy.context -NotePropertyName 'userName' -NotePropertyValue (& $limit ([string] $UserName).Trim()) -Force
    Add-Member -InputObject $Policy.context -NotePropertyName 'role'     -NotePropertyValue (& $limit ([string] $Role).Trim()) -Force
    $ps = @(ConvertTo-PatternArray $Priorities | ForEach-Object { (& $limit $_.Trim()) } | Where-Object { $_ } | Select-Object -First 20)
    Add-Member -InputObject $Policy.context -NotePropertyName 'priorities' -NotePropertyValue ([string[]] $ps) -Force
}

# 画面に渡す形。_comment のような読む人向けの記述は落とす。
function Get-PolicyView {
    param([Parameter(Mandatory)] $Policy)
    return [pscustomobject]@{
        ignore = [pscustomobject]@{
            appIdPatterns = @(Get-IgnoreList -Policy $Policy -Kind 'appId')
            titlePatterns = @(Get-IgnoreList -Policy $Policy -Kind 'title')
        }
        context = [pscustomobject]@{
            userName   = [string] $Policy.context.userName
            role       = [string] $Policy.context.role
            priorities = @(ConvertTo-PatternArray $Policy.context.priorities)
        }
    }
}
