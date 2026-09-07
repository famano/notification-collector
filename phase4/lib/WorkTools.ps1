# WorkTools.ps1
# ワーカーが実際に実行できる作業ツール。
#
# 安全方針:
#  - 出力はカードごとの作業フォルダ配下に限定する。絶対パスと .. は拒否。
#  - 拡張子はテキスト系のみ許可。実行可能ファイルは作らせない。
#  - シェル実行やネットワークアクセスのツールは意図的に持たせていない。
#    ツールの入力は通知本文（第三者が書いた文字列）の影響を受けうるため、
#    任意コード実行を与えると注入がそのまま実行になる。
#  - 送信・投稿は行わない。メールは .eml ファイルとして作るだけで、
#    送信操作は人間がメールクライアントで行う。

$script:AllowedExtensions = @('.txt', '.md', '.eml', '.csv', '.json', '.html', '.log', '.yml', '.yaml')
$script:MaxContentBytes   = 1048576   # 1MB

function Get-TaskWorkspace {
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] [int] $TaskId)
    $dir = Join-Path $Root ("task-{0:D4}" -f $TaskId)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Resolve-Path $dir).Path
}

# 作業フォルダの外に出ようとする指定を弾く
function Resolve-SafePath {
    param([Parameter(Mandatory)] [string] $Workspace, [Parameter(Mandatory)] [string] $Relative)

    if ([string]::IsNullOrWhiteSpace($Relative)) { throw 'ファイル名が空です' }
    if ([IO.Path]::IsPathRooted($Relative))      { throw "絶対パスは指定できません: $Relative" }
    if ($Relative -match '\.\.')                 { throw "上位フォルダへの参照は指定できません: $Relative" }
    if ($Relative -match '[:*?"<>|]')            { throw "使用できない文字が含まれています: $Relative" }

    $ext = [IO.Path]::GetExtension($Relative).ToLower()
    if ($script:AllowedExtensions -notcontains $ext) {
        throw ("この拡張子は作成できません: {0} (許可: {1})" -f $ext, ($script:AllowedExtensions -join ', '))
    }

    $full = [IO.Path]::GetFullPath((Join-Path $Workspace $Relative))
    if (-not $full.StartsWith($Workspace, [StringComparison]::OrdinalIgnoreCase)) {
        throw "作業フォルダの外には書き込めません: $Relative"
    }
    return $full
}

# 非 ASCII のヘッダは RFC2047 で符号化しないとメールクライアントが化ける
function ConvertTo-MimeHeader {
    param([string] $Value)
    if (-not $Value) { return '' }
    $isAscii = $true
    foreach ($ch in $Value.ToCharArray()) { if ([int]$ch -gt 127) { $isAscii = $false; break } }
    if ($isAscii) { return $Value }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    # ${b64} と括ること。"$b64?=" は ? まで変数名に取り込まれて空になる。
    return "=?UTF-8?B?${b64}?="
}

# ---------------------------------------------------------------- ツール定義

$script:WorkTools = @(
    @{
        name        = 'write_file'
        description = 'カードの作業フォルダにテキストファイルを作成する。報告書・メモ・一覧などの成果物はこれで実際に作る。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                path    = @{ type = 'string'; description = 'ファイル名 (例: report.md)。作業フォルダからの相対パス。' }
                content = @{ type = 'string'; description = 'ファイルの中身。' }
                purpose = @{ type = 'string'; description = 'このファイルが何のためのものかの一文。' }
            }
            required = @('path', 'content', 'purpose')
        }
    },
    @{
        name        = 'create_email_draft'
        description = 'メールの下書きを .eml ファイルとして作成する。メールクライアントで開くと下書きとして編集・送信できる。送信そのものは行わない。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                to      = @{ type = 'string'; description = '宛先。不明なら空文字にして notes で確認を促す。' }
                cc      = @{ type = 'string'; description = 'CC。無ければ空文字。' }
                subject = @{ type = 'string'; description = '件名。' }
                body    = @{ type = 'string'; description = '本文。' }
                path    = @{ type = 'string'; description = 'ファイル名 (例: reply.eml)。省略時は draft.eml。' }
            }
            required = @('subject', 'body')
        }
    },
    @{
        name        = 'read_file'
        description = 'このカードの作業フォルダにある自分が作ったファイルを読み返す。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{ path = @{ type = 'string' } }
            required   = @('path')
        }
    },
    @{
        name        = 'list_files'
        description = 'このカードの作業フォルダにあるファイルの一覧を得る。'
        input_schema = @{ type = 'object'; properties = [ordered]@{} }
    }
)

function Get-WorkTools { return $script:WorkTools }

# ---------------------------------------------------------------- 実行

function Invoke-WorkTool {
    <#
      .SYNOPSIS
        ツール1件を実行する。
      .OUTPUTS
        [pscustomobject] text (モデルに返す結果) / artifact (作成物のパス、無ければ $null) / isError
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $ToolInput,
        [Parameter(Mandatory)] [string] $Workspace
    )

    try {
        switch ($Name) {
            'write_file' {
                $full = Resolve-SafePath -Workspace $Workspace -Relative $ToolInput.path
                $content = [string] $ToolInput.content
                $bytes = [Text.Encoding]::UTF8.GetBytes($content)
                if ($bytes.Length -gt $script:MaxContentBytes) { throw 'ファイルが大きすぎます (上限 1MB)' }
                $dir = Split-Path -Parent $full
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [IO.File]::WriteAllText($full, $content, (New-Object Text.UTF8Encoding($false)))
                return [pscustomobject]@{
                    text     = ("作成しました: {0} ({1} バイト)" -f $ToolInput.path, $bytes.Length)
                    artifact = $full
                    isError  = $false
                }
            }

            'create_email_draft' {
                $rel = if ($ToolInput.path) { [string] $ToolInput.path } else { 'draft.eml' }
                if ([IO.Path]::GetExtension($rel).ToLower() -ne '.eml') { $rel = $rel + '.eml' }
                $full = Resolve-SafePath -Workspace $Workspace -Relative $rel

                $sb = New-Object Text.StringBuilder
                [void] $sb.AppendLine("To: " + (ConvertTo-MimeHeader ([string] $ToolInput.to)))
                if ($ToolInput.cc) { [void] $sb.AppendLine("Cc: " + (ConvertTo-MimeHeader ([string] $ToolInput.cc))) }
                [void] $sb.AppendLine("Subject: " + (ConvertTo-MimeHeader ([string] $ToolInput.subject)))
                [void] $sb.AppendLine("Date: " + (Get-Date).ToString('r'))
                [void] $sb.AppendLine("MIME-Version: 1.0")
                [void] $sb.AppendLine("Content-Type: text/plain; charset=UTF-8")
                [void] $sb.AppendLine("Content-Transfer-Encoding: 8bit")
                # Outlook はこれを見て「未送信の下書き」として開く
                [void] $sb.AppendLine("X-Unsent: 1")
                [void] $sb.AppendLine()
                [void] $sb.Append([string] $ToolInput.body)

                [IO.File]::WriteAllText($full, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
                $to = if ($ToolInput.to) { $ToolInput.to } else { '(宛先未定)' }
                return [pscustomobject]@{
                    text     = ("メールの下書きを作成しました: {0} / 宛先 {1} / 件名 {2}" -f $rel, $to, $ToolInput.subject)
                    artifact = $full
                    isError  = $false
                }
            }

            'read_file' {
                $full = Resolve-SafePath -Workspace $Workspace -Relative $ToolInput.path
                if (-not (Test-Path -LiteralPath $full)) { throw "ファイルがありません: $($ToolInput.path)" }
                return [pscustomobject]@{
                    text     = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
                    artifact = $null
                    isError  = $false
                }
            }

            'list_files' {
                $files = @(Get-ChildItem -LiteralPath $Workspace -File -Recurse -ErrorAction SilentlyContinue)
                $text = if ($files.Count -eq 0) { '(まだファイルはありません)' }
                        else { ($files | ForEach-Object { "{0} ({1} バイト)" -f $_.Name, $_.Length }) -join "`n" }
                return [pscustomobject]@{ text = $text; artifact = $null; isError = $false }
            }

            default { throw "未知のツールです: $Name" }
        }
    }
    catch {
        # 失敗もモデルに返す。握り潰すと同じ誤りを繰り返す。
        return [pscustomobject]@{ text = ("エラー: " + $_.Exception.Message); artifact = $null; isError = $true }
    }
}
