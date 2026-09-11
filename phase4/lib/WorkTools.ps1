# WorkTools.ps1
# ワーカーが実行できる作業ツール。
#
# 方針:
#   能力は制限しない。制限する代わりに、危険なものは実行前に利用者の承認を取る。
#   ここでは「何が危険か」を分類するだけで、承認そのものはワーカーが行う。
#
#   分類の基準は「取り返しがつくか」と「作業フォルダの外に影響するか」。
#     安全  … カードの作業フォルダ内のテキスト読み書き
#     要承認 … コマンド実行、フォルダ外への書き込み、ネットワークアクセス、
#              そして外向きの送信 (Slack への投稿、メールの送信)
#
#   送信は他のツールと同じ承認の仕組みに乗せてあるが、取り消しがきかない点だけは違う。
#   宛先と本文は承認画面に省略せず全文出す。投稿先・返信先はモデルに決めさせず、
#   カードの元通知からワーカーが束縛して渡す (Slack のチャンネル、Gmail のスレッド)。
#
#   要承認のものは、承認画面に実行内容を省略せず出す。通知本文（第三者が書いた文字列）が
#   入力に混ざりうるため、この画面が注入と実行のあいだに立つ唯一の壁になる。

#   ツールの構成は「カードの出口」で分けている。
#     見る   … open_source / fetch_attachment / recall。承認不要。
#              カードの出自をワーカー実行時に取り直す。本文が足りないまま
#              「元のメールを開いてご確認ください」と報告して終わるのを無くすため。
#     効かせる … http_request。承認必須。資格情報はホストから決まり、
#              モデルには渡らない (詳細は HttpAction.ps1)。
#     閉じる … propose_reply / send_* / require_human_step。
#
#   write_file は既定の出口ではない。完了カードを洗うと、22枚が27個のメモを
#   作業フォルダに吐いていたが、それらは何も閉じていなかった。メモは
#   「他に出口が無かった」ときの副産物であって、成果ではない。

. "$PSScriptRoot\SourceAccess.ps1"
. "$PSScriptRoot\HttpAction.ps1"

$script:SafeExtensions  = @('.txt', '.md', '.eml', '.csv', '.json', '.html', '.log', '.yml', '.yaml')
$script:MaxContentBytes = 1048576   # 1MB
$script:MaxOutputChars  = 8000      # モデルに返す出力の上限

# 人間にしかできない理由。自由記述を許さず、この集合から選ばせる。
#
#   自由記述だと「できませんでした」で何でも閉じられてしまい、
#   実際そうなっていた。理由を型で持たせると、理由ごとに違う扱いができる ――
#   とくに credential_missing は人間の1手ではなく、一度直せば同種がまとめて通る
#   設定の問題なので、カードを閉じずに設定カードへ変換する。
$script:HumanStepBlockers = @{
    'credential_missing' = '権限・資格情報が足りない (設定カードに変換される)'
    'physical_presence'  = '本人の身体が要る (生体認証、本人確認リンク、来訪など)'
    'payment_or_legal'   = '支払い・契約・本人の意思決定そのもの'
    'no_api'             = '相手側に操作する手段が存在しない'
}

function Get-TaskWorkspace {
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] [int] $TaskId)
    $dir = Join-Path $Root ("task-{0:D4}" -f $TaskId)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Resolve-Path $dir).Path
}

# 相対パスは作業フォルダ基準、絶対パスはそのまま。禁止はせず、後で危険度を判定する。
function Resolve-TargetPath {
    param([Parameter(Mandatory)] [string] $Workspace, [Parameter(Mandatory)] [string] $Relative)
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw 'ファイル名が空です' }
    if ([IO.Path]::IsPathRooted($Relative)) { return [IO.Path]::GetFullPath($Relative) }
    return [IO.Path]::GetFullPath((Join-Path $Workspace $Relative))
}

function Test-InWorkspace {
    param([string] $Workspace, [string] $FullPath)
    return $FullPath.StartsWith($Workspace, [StringComparison]::OrdinalIgnoreCase)
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

function Limit-Text {
    param([string] $Text)
    if (-not $Text) { return '' }
    if ($Text.Length -le $script:MaxOutputChars) { return $Text }
    return $Text.Substring(0, $script:MaxOutputChars) + "`n…(出力が長いため省略)"
}

# ---------------------------------------------------------------- ツール定義

$script:WorkTools = @(
    @{
        name        = 'write_file'
        description = 'テキストファイルを作成する。カードの作業フォルダ内なら即座に実行される。作業フォルダ外や実行可能な拡張子の場合は利用者の承認を求める。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                path    = @{ type = 'string'; description = 'ファイル名。相対パスなら作業フォルダ基準。絶対パスも指定できる（要承認）。' }
                content = @{ type = 'string'; description = 'ファイルの中身。' }
                purpose = @{ type = 'string'; description = 'このファイルが何のためのものかの一文。' }
            }
            required = @('path', 'content', 'purpose')
        }
    },
    @{
        name        = 'create_email_draft'
        description = 'メールの下書きを .eml として作成する。メールクライアントで開くと下書きとして編集・送信できる。送信そのものは行わない。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                to      = @{ type = 'string'; description = '宛先。不明なら空文字にして最後の説明で確認を促す。' }
                cc      = @{ type = 'string' }
                subject = @{ type = 'string' }
                body    = @{ type = 'string' }
                path    = @{ type = 'string'; description = 'ファイル名 (省略時 draft.eml)' }
            }
            required = @('subject', 'body')
        }
    },
    @{
        name        = 'read_file'
        description = 'ファイルを読む。作業フォルダ内なら即座に、外なら承認のうえ実行する。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{ path = @{ type = 'string' } }
            required   = @('path')
        }
    },
    @{
        name        = 'list_files'
        description = 'フォルダ内のファイル一覧を得る。省略時はこのカードの作業フォルダ。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{ path = @{ type = 'string'; description = '省略可。' } }
        }
    },
    @{
        name        = 'run_command'
        description = 'PowerShell コマンドを実行する。必ず利用者の承認を求めてから実行される。ファイル変換、集計、既存ファイルの調査など、他のツールでできないことに使う。'
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                command = @{ type = 'string'; description = '実行する PowerShell コマンド。1行で完結させる。' }
                purpose = @{ type = 'string'; description = '何のために実行するのかの一文。承認画面に出る。' }
            }
            required = @('command', 'purpose')
        }
    },
    @{
        name        = 'http_request'
        description = @'
HTTP リクエストを送る。外部サービスの API を叩いて、実際に状態を変えるための道具。
GET で調べるだけでなく、POST/PATCH/PUT/DELETE で操作できる。
例: GitHub の招待を承諾する、カレンダーの出欠を返す、Issue を立てる。

認証は指定しない。ワーカーが宛先ホストを見て自動で付ける (GitHub / Google / Slack)。
Authorization ヘッダを自分で書いても捨てられる。トークンを URL や本文に入れてはいけない。

GET 以外は必ず利用者の承認を求める。承認画面には実際に飛ぶリクエストが全文出る。
人に届くメッセージの送信 (Slack への投稿、メールの送信) はこのツールでは行えない。
宛先がカードから束縛される専用ツールを使うこと。
'@
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                method  = @{ type = 'string'; description = 'GET / POST / PATCH / PUT / DELETE。省略時 GET。' }
                url     = @{ type = 'string' }
                headers = @{ type = 'object'; description = '追加ヘッダ。認証は不要 (自動で付く)。Accept など。' }
                body    = @{ type = 'string'; description = 'リクエストボディ。JSON なら文字列化して渡す。' }
                purpose = @{ type = 'string'; description = '何のために叩くのかの一文。承認画面に出る。' }
            }
            required = @('url', 'purpose')
        }
    },
    @{
        name        = 'open_source'
        description = @'
このカードの元になったメール / Slack スレッド / Claude セッションを、いま取り直して全文を読む。
カードに載っている本文は取り込んだ時点のもので、途中で切れていたり、
HTML メールの本文が抜けていたり、スレッドの経緯が入っていないことがある。

**作業を始める前にまずこれを呼ぶこと。** 本文が足りないまま進めて
「元のメールを開いてご確認ください」と報告するのは、このシステムの目的に反する。
添付の一覧と、次に叩ける URL・識別子 (スレッドID、チャンネル、招待URL など) も返る。
'@
        input_schema = @{ type = 'object'; properties = [ordered]@{} }
    },
    @{
        name        = 'fetch_attachment'
        description = @'
添付ファイルを1件取り込む。open_source が返した添付の id を指定する。
本文に「添付をご確認ください」とあって中身が要るときに使う。
テキスト系なら中身も返る。それ以外は作業フォルダに落ちる。
'@
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                attachment_id = @{ type = 'string'; description = 'open_source が返した attachments[].id' }
                name          = @{ type = 'string'; description = '保存するファイル名。省略時は元の名前。' }
            }
            required = @('attachment_id')
        }
    },
    @{
        name        = 'recall'
        description = @'
同じ件について前回までに分かったことを読む。
繰り返し届く通知 (同じ CI の失敗、同じ相手との往復) では、
前回どこまで調べて何で詰まったかがここに残っている。
**調査を始める前に呼ぶこと。** 同じ壁に何度もぶつかり直さないため。
'@
        input_schema = @{ type = 'object'; properties = [ordered]@{} }
    },
    @{
        name        = 'record_finding'
        description = @'
この件について分かったことを台帳に残す。次に同じ件が来たときに recall で読まれる。
「非公開リポジトリなので未認証では読めない」「担当は誰々」のような、
次回も同じように効く事実だけを短く書く。今回限りの経過は書かない。
'@
        input_schema = @{
            type       = 'object'
            properties = [ordered]@{
                note = @{ type = 'string'; description = '次回の自分に効く一文。' }
            }
            required = @('note')
        }
    }
)

# 送信ツール。外に出たら取り消せないので、他のツールと違って
# 「使える状態か」だけでなく「返す先が分かっているか」でも出し分ける。
$script:SlackSendTool = @{
    name        = 'send_slack_message'
    description = '元の Slack スレッドに返信を投稿する。実行前に必ず利用者の承認を求める。投稿先はこのカードの元通知から決まっており、指定はできない。一度投稿すると取り消せないので、利用者が送信を求めている場合にだけ使う。求められていなければ文面を報告に載せるだけにする。'
    input_schema = @{
        type       = 'object'
        properties = [ordered]@{
            text            = @{ type = 'string'; description = '投稿する本文。そのまま投稿される。' }
            reply_in_thread = @{ type = 'boolean'; description = '既定 true。false にすると元スレッドではなくチャンネルへの新規投稿になる。' }
        }
        required = @('text')
    }
}

# 返信先があるカードの既定の出口。
# 送信ツールと違って外に出ないので承認は要らない。カンバンの「送る文面」欄に載り、
# 利用者が読んで直して、そこから送る。文面をチャットの中だけで返して終わりにすると
# 利用者は結局それを手で貼り直すことになるので、必ずこれを呼ばせる。
$script:ProposeReplyTool = @{
    name        = 'propose_reply'
    description = 'このカードの返信文面をカンバンの「送る文面」欄に載せる。送信はしない。返信先があるカードで、利用者が送信を指示していないときはこれを使う。利用者はこの欄で内容を直し、そのまま送信できる。何度呼んでも上書きされるが、利用者が既に手を入れた内容は消えない。'
    input_schema = @{
        type       = 'object'
        properties = [ordered]@{
            text = @{ type = 'string'; description = 'そのまま送れる状態の本文。前置きや説明を混ぜない。' }
        }
        required = @('text')
    }
}

$script:GmailSendTool = @{
    name        = 'send_gmail'
    description = 'メールを実際に送信する。実行前に必ず利用者の承認を求める。Gmail から来たカードへの返信なら元のスレッドにぶら下がる。一度送ると取り消せないので、利用者が送信を求めている場合にだけ使う。求められていなければ create_gmail_draft か create_email_draft で下書きに留める。'
    input_schema = @{
        type       = 'object'
        properties = [ordered]@{
            to      = @{ type = 'string'; description = '宛先。返信なら元の差出人。空欄では送信できない。' }
            cc      = @{ type = 'string' }
            subject = @{ type = 'string' }
            body    = @{ type = 'string' }
        }
        required = @('to', 'subject', 'body')
    }
}

$script:GmailDraftTool = @{
    name        = 'create_gmail_draft'
    description = 'Gmail に本物の下書きを作成する。Gmail から来たカードへの返信ならスレッドにぶら下がる。送信は行わない。ローカルの .eml ではなく実際のメールボックスに作る場合はこちらを使う。'
    input_schema = @{
        type       = 'object'
        properties = [ordered]@{
            to      = @{ type = 'string'; description = '宛先。返信なら元の差出人。' }
            cc      = @{ type = 'string' }
            subject = @{ type = 'string' }
            body    = @{ type = 'string' }
        }
        required = @('subject', 'body')
    }
}

# 人間にしかできない1手でカードを閉じる。
#
# これは「失敗」ではなく正式な出口。ホテルの本人確認リンク、Windows Hello での
# パスキー登録、支払い ―― ソフトウェアには原理的に出来ないことは実在する。
# 従来そういうカードは800字のメモで終わっていたが、利用者が欲しいのは
# 「自分がやるべき1手」と、その入口へのリンクだけである。
#
# ただし安易に逃げられては意味がない。だから:
#   - 理由は閉じた集合から選ばせる (自由記述を許さない)
#   - 何を試したかの証跡をワーカーが照合し、試していなければ差し戻す
#   - credential_missing はこのカードを閉じず、設定カードに変換する
$script:HumanStepTool = @{
    name        = 'require_human_step'
    description = @'
利用者本人にしかできない1手を提示してカードを閉じる。

**先にやること。** このツールを呼ぶ前に、open_source で出自を全部読み、
http_request で実際に操作を試みること。試さずにこれを呼ぶと差し戻される。
「自分にはできない」と判断する前に、API で state を変えられないか必ず調べる。

blocker は次から選ぶ:
  credential_missing … 権限・資格情報が足りないだけ。設定カードに変換され、
                       このカードは設定待ちになる。「あなたがやってください」にはならない。
  physical_presence  … 生体認証・本人確認リンク・来訪など、本人の身体が要る
  payment_or_legal   … 支払い・契約・本人の意思決定そのもの
  no_api             … 相手側に操作する手段が存在しない (試したうえで)
'@
    input_schema = @{
        type       = 'object'
        properties = [ordered]@{
            blocker = @{
                type = 'string'
                enum = @('credential_missing', 'physical_presence', 'payment_or_legal', 'no_api')
                description = 'なぜ人間でなければならないか。'
            }
            step    = @{ type = 'string'; description = '利用者がやる1手。一文で、具体的に。' }
            url     = @{ type = 'string'; description = 'その1手の入口となる URL。あれば必ず入れる。' }
            deadline = @{ type = 'string'; description = '期限があれば。例「30分以内」「9/18まで」' }
            what_is_missing = @{ type = 'string'; description = 'blocker=credential_missing のとき、何の権限が要るか。' }
            tried   = @{ type = 'string'; description = '何を試して何が返ったか。証跡として画面に出る。' }
        }
        required = @('blocker', 'step')
    }
}

# 連携が設定されているときだけ、そのサービスのツールを見せる。
# 使えないツールを提示すると、モデルが存在しない手段を前提に計画を立ててしまう。
#
# Slack の投稿は返信先が要る。カードの元通知が Slack でなければ投稿先が無いので、
# 設定済みでも出さない (呼び出し側が -HasSlackTarget で伝える)。
function Get-WorkTools {
    param(
        [switch] $HasSlackTarget,
        [switch] $HasOutlet
    )
    $tools = @($script:WorkTools)
    # 返信先があるカードでだけ出す。送り先の無いカードに「返信文面を載せる」道具を
    # 見せると、モデルが宛先の無い返信を書き始める。
    if ($HasOutlet) { $tools += $script:ProposeReplyTool }
    if ((Get-Command Test-GmailConfigured -ErrorAction SilentlyContinue) -and (Test-GmailConfigured)) {
        $tools += $script:GmailDraftTool
        $tools += $script:GmailSendTool
    }
    if ($HasSlackTarget -and (Get-Command Test-SlackConfigured -ErrorAction SilentlyContinue) -and (Test-SlackConfigured)) {
        $tools += $script:SlackSendTool
    }
    # 人間送りの出口は常に見せる。ただし呼べるかどうかは別で、
    # 実際に手を動かした証跡が無ければワーカーが呼び出し時に差し戻す
    # (Test-HumanStepAllowed)。ツール一覧から隠す方式も試せるが、
    # 一覧はラウンド単位でしか変えられないので、同じラウンド内で
    # 「調べ尽くしたので諦める」が表現できなくなる。
    # 呼ばせたうえで理由とともに突き返すほうが、モデルに何が足りないかが伝わる。
    $tools += $script:HumanStepTool
    return $tools
}

function Test-HumanStepAllowed {
    <#
      .SYNOPSIS
        「人間にしかできない」と言ってよい状態か。
      .DESCRIPTION
        出自を読んでいない / 一度も外に働きかけていないのに諦めるのを止める。
        完了カードを洗うと、まさにこれが起きていた ―― API を持っているのに
        叩かないまま「ご自身でリンクから」と書いて終わるカードが並んでいた。
      .OUTPUTS
        [pscustomobject] ok / reason
    #>
    param(
        [Parameter(Mandatory)] $Attempts,
        [Parameter(Mandatory)] [string] $Blocker,
        # 出自の取り直しができないカード (手起票・取り直す API が無い通知) では
        # open_source を求めても意味がない。
        [switch] $SourceUnavailable
    )
    $tools = @($Attempts | ForEach-Object { [string] $_['tool'] })

    if (-not $SourceUnavailable -and ($tools -notcontains 'open_source')) {
        return [pscustomobject]@{
            ok = $false
            reason = 'まだ open_source を呼んでいません。カードに載っている本文は途中までのことがあります。' +
                     '元のやり取りを全部読んでから判断してください。'
        }
    }

    # 権限不足は「叩いて断られた」ことが根拠になる。叩かずに権限不足を主張させない。
    if ($Blocker -eq 'credential_missing' -and ($tools -notcontains 'http_request')) {
        return [pscustomobject]@{
            ok = $false
            reason = '権限が足りないと判断するには、実際に API を叩いて断られた結果が要ります。' +
                     'http_request で試してから、その応答を tried に書いてください。'
        }
    }

    # 「相手に手段が無い」も同じ。調べずに宣言させない。
    if ($Blocker -eq 'no_api' -and ($tools -notcontains 'http_request')) {
        return [pscustomobject]@{
            ok = $false
            reason = '操作する手段が無いと判断するには、実際に試した結果が要ります。' +
                     '相手のサービスに API が無いか、http_request で確かめてください。'
        }
    }

    # physical_presence と payment_or_legal は、性質上いくら叩いても解決しない
    # (生体認証や支払いの意思決定)。出自を読んでいれば通す。
    return [pscustomobject]@{ ok = $true; reason = '' }
}

# 実行すると外に出て、取り消せないツール。
# 承認の要否とは別の軸。承認が要るだけのツール (コマンド実行など) は失敗しても
# やり直せるが、こちらは送ったあとに何をしても戻らないので、
# 呼び出し側は「もう一度やらせる」判断の前にこれを見る。
function Test-IrreversibleTool {
    param([Parameter(Mandatory)] [string] $Name, $ToolInput)
    if (@('send_gmail', 'send_slack_message') -contains $Name) { return $true }
    # 書き込みメソッドの http_request も戻せない。承諾した招待は取り消せないし、
    # 送った出欠は相手に見えている。修正ラウンドで同じ POST をもう一度
    # 投げないよう、送信と同じ扱いにする。
    if ($Name -eq 'http_request' -and $ToolInput) {
        $m = if ($ToolInput.method) { [string] $ToolInput.method } else { 'GET' }
        return (Test-WriteMethod -Method $m)
    }
    return $false
}

# ---------------------------------------------------------------- 危険度の判定

function Get-ToolRisk {
    <#
      .OUTPUTS
        [pscustomobject] risky (承認が必要か) / summary (一行) / detail (承認画面に出す全文)
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $ToolInput,
        [Parameter(Mandatory)] [string] $Workspace,
        # 送信先はモデルの入力ではなくワーカーが束縛したものを出す。
        # 承認画面に「モデルが言った宛先」を出しては壁にならない。
        [string] $SlackChannelName,
        [string] $GmailThreadLabel
    )

    switch ($Name) {
        'send_slack_message' {
            # 投稿は取り消せない。全文をそのまま出す。
            $where = if ($SlackChannelName) { $SlackChannelName } else { '(元の通知のチャンネル)' }
            $inThread = ($null -eq $ToolInput.reply_in_thread) -or ([bool] $ToolInput.reply_in_thread)
            $how = if ($inThread) { '元のスレッドへの返信として' } else { 'チャンネルへの新規投稿として' }
            return [pscustomobject]@{
                risky   = $true
                summary = "Slack に投稿します: $where"
                detail  = "投稿先: $where`n形式: $how`n`n--- 本文 ---`n$([string] $ToolInput.text)`n`n※投稿すると取り消せません。相手に届きます。"
            }
        }
        'send_gmail' {
            $to = if ($ToolInput.to) { $ToolInput.to } else { '(宛先未指定)' }
            $how = if ($GmailThreadLabel) { $GmailThreadLabel } else { '新規メールとして送信' }
            return [pscustomobject]@{
                risky   = $true
                summary = "メールを送信します: $($ToolInput.subject)"
                detail  = "宛先: $to`nCc: $($ToolInput.cc)`n件名: $($ToolInput.subject)`n形式: $how`n`n--- 本文 ---`n$([string] $ToolInput.body)`n`n※送信すると取り消せません。相手に届きます。"
            }
        }
        'run_command' {
            return [pscustomobject]@{
                risky   = $true
                summary = 'コマンドを実行します'
                detail  = "目的: $($ToolInput.purpose)`n実行場所: $Workspace`n`n$($ToolInput.command)"
            }
        }
        'http_request' {
            # 危険度はツール名ではなく「メソッド × ホスト」で決まる。
            #   読むだけ (GET/HEAD) で、認証が付く既知のホスト
            #     → 自動。同期が普段やっている読み取りと変わらない。
            #   読むだけだが、認証の付かない外部ホスト
            #     → 承認。URL 自体に情報が載ることがある。
            #   書き込み (POST/PATCH/PUT/DELETE)
            #     → 常に承認。相手側の状態が変わり、取り消せないことが多い。
            $method = if ($ToolInput.method) { ([string] $ToolInput.method).ToUpper() } else { 'GET' }
            $url    = [string] $ToolInput.url
            $cred   = Get-RequestCredential -Url $url
            $credLabel = if ($cred) { $cred.label } else { '(認証なし)' }
            $isWrite = Test-WriteMethod -Method $method

            if (-not $isWrite -and $cred) {
                return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
            }

            $body = [string] $ToolInput.body
            if ($body.Length -gt 2000) { $body = $body.Substring(0, 2000) + "`n…(以下省略)" }
            $warn = if ($isWrite) {
                "`n`n※これは相手側の状態を変える操作です。取り消せない場合があります。"
            } else {
                "`n`n※URL に情報が含まれていないか確認してください。"
            }
            $detail = "目的: $($ToolInput.purpose)`n" +
                      "メソッド: $method`n" +
                      "URL: $url`n" +
                      "認証: $credLabel (ワーカーが付与。モデルはトークンを保持していません)"
            if ($body) { $detail += "`n`n--- 本文 ---`n$body" }
            $detail += $warn

            return [pscustomobject]@{
                risky   = $true
                summary = ("{0} {1}" -f $method, $url)
                detail  = $detail
            }
        }
        'require_human_step' {
            # 外には出ないので承認は不要。妥当性の判定はワーカーが証跡で行う。
            return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
        }
        'open_source' { return [pscustomobject]@{ risky = $false; summary = ''; detail = '' } }
        'fetch_attachment' {
            # 元のメール/スレッドに付いていたものを取り込むだけ。
            # 出自はカードから束縛されていて、モデルは任意の場所を指定できない。
            return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
        }
        'recall'         { return [pscustomobject]@{ risky = $false; summary = ''; detail = '' } }
        'record_finding' { return [pscustomobject]@{ risky = $false; summary = ''; detail = '' } }
        'create_gmail_draft' {
            # 送信はしないが、利用者本人のメールボックスに物が残る。
            # ローカルのファイル作成とは影響範囲が違うので承認を取る。
            $to = if ($ToolInput.to) { $ToolInput.to } else { '(宛先未指定)' }
            $preview = [string] $ToolInput.body
            if ($preview.Length -gt 2000) { $preview = $preview.Substring(0, 2000) + "`n…(以下省略)" }
            return [pscustomobject]@{
                risky   = $true
                summary = "Gmail に下書きを作成します: $($ToolInput.subject)"
                detail  = "宛先: $to`nCc: $($ToolInput.cc)`n件名: $($ToolInput.subject)`n`n--- 本文 ---`n$preview`n`n※作成されるのは下書きだけで、送信はされません。"
            }
        }
        'write_file' {
            $full = Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path)
            $inWs = Test-InWorkspace $Workspace $full
            $ext  = [IO.Path]::GetExtension($full).ToLower()
            $safeExt = ($script:SafeExtensions -contains $ext)
            if ($inWs -and $safeExt) {
                return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
            }
            $why = if (-not $inWs) { '作業フォルダの外です' } else { "実行される可能性のある拡張子です ($ext)" }
            $preview = [string] $ToolInput.content
            if ($preview.Length -gt 2000) { $preview = $preview.Substring(0, 2000) + "`n…(以下省略)" }
            return [pscustomobject]@{
                risky   = $true
                summary = "ファイルを書き込みます: $full"
                detail  = "理由: $why`n目的: $($ToolInput.purpose)`n書き込み先: $full`n`n--- 内容 ---`n$preview"
            }
        }
        'read_file' {
            $full = Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path)
            if (Test-InWorkspace $Workspace $full) {
                return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
            }
            return [pscustomobject]@{
                risky   = $true
                summary = "作業フォルダ外のファイルを読みます: $full"
                detail  = "読み取り先: $full"
            }
        }
        'list_files' {
            if (-not $ToolInput.path) { return [pscustomobject]@{ risky = $false; summary = ''; detail = '' } }
            $full = Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path)
            if (Test-InWorkspace $Workspace $full) {
                return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
            }
            return [pscustomobject]@{
                risky = $true; summary = "作業フォルダ外の一覧を取得します: $full"; detail = "対象: $full"
            }
        }
        default {
            return [pscustomobject]@{ risky = $false; summary = ''; detail = '' }
        }
    }
}

# ---------------------------------------------------------------- 実行

function Invoke-WorkTool {
    <#
      .SYNOPSIS
        ツール1件を実行する。承認の判断は呼び出し側 (ワーカー) が済ませている前提。
      .OUTPUTS
        [pscustomobject] text / artifact / isError
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $ToolInput,
        [Parameter(Mandatory)] [string] $Workspace,
        [int] $CommandTimeoutSec = 120,
        # Gmail から来たカードの場合、返信をスレッドにぶら下げるための識別子。
        # モデルに持ち回らせず、ワーカーが束縛して渡す。
        [string] $GmailThreadId,
        [string] $GmailInReplyTo,
        # Slack から来たカードの場合の投稿先。同じ理由でワーカーが束縛する。
        [string] $SlackChannel,
        [string] $SlackThreadTs,
        # open_source が取り直す対象。モデルは「どのカードの出自か」を
        # 指定できない。指定できるようにすると、別のカードの中身を
        # 読ませる指示が通ってしまう。
        $SourceEvent,
        # recall が返す、この件の台帳。
        [string] $DossierText
    )

    try {
        switch ($Name) {
            'send_slack_message' {
                if (-not (Get-Command Send-SlackMessage -ErrorAction SilentlyContinue)) {
                    throw 'Slack 連携が設定されていません。'
                }
                if (-not $SlackChannel) { throw 'このカードには Slack の投稿先がありません。' }
                $inThread = ($null -eq $ToolInput.reply_in_thread) -or ([bool] $ToolInput.reply_in_thread)
                $ts = if ($inThread) { $SlackThreadTs } else { '' }
                $r = Send-SlackMessage -Channel $SlackChannel -Text ([string] $ToolInput.text) -ThreadTs $ts
                $where = if ($inThread) { 'スレッドへの返信として' } else { 'チャンネルへの新規投稿として' }
                $link = if ($r.permalink) { " {0}" -f $r.permalink } else { '' }
                return [pscustomobject]@{
                    text     = ("Slack に投稿しました ({0})。取り消しはできません。{1}" -f $where, $link)
                    artifact = $null
                    isError  = $false
                }
            }
            'send_gmail' {
                if (-not (Get-Command Send-GmailMessage -ErrorAction SilentlyContinue)) {
                    throw 'Gmail 連携が設定されていません。'
                }
                [void] (Send-GmailMessage -To ([string] $ToolInput.to) -Cc ([string] $ToolInput.cc) `
                        -Subject ([string] $ToolInput.subject) -Body ([string] $ToolInput.body) `
                        -ThreadId $GmailThreadId -InReplyTo $GmailInReplyTo)
                $where = if ($GmailThreadId) { '元のスレッドへの返信として' } else { '新規メールとして' }
                return [pscustomobject]@{
                    text     = ("メールを送信しました ({0})。取り消しはできません。宛先: {1}" -f $where, $ToolInput.to)
                    artifact = $null
                    isError  = $false
                }
            }
            'create_gmail_draft' {
                if (-not (Get-Command New-GmailDraft -ErrorAction SilentlyContinue)) {
                    throw 'Gmail 連携が設定されていません。'
                }
                $d = New-GmailDraft -To ([string] $ToolInput.to) -Cc ([string] $ToolInput.cc) `
                        -Subject ([string] $ToolInput.subject) -Body ([string] $ToolInput.body) `
                        -ThreadId $GmailThreadId -InReplyTo $GmailInReplyTo
                $where = if ($GmailThreadId) { '元のスレッドへの返信として' } else { '新規メールとして' }
                return [pscustomobject]@{
                    text     = ("Gmail に下書きを作成しました ({0})。下書きID: {1}" -f $where, $d.id)
                    artifact = $null
                    isError  = $false
                }
            }
            'write_file' {
                $full = Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path)
                $content = [string] $ToolInput.content
                $bytes = [Text.Encoding]::UTF8.GetBytes($content)
                if ($bytes.Length -gt $script:MaxContentBytes) { throw 'ファイルが大きすぎます (上限 1MB)' }
                $dir = Split-Path -Parent $full
                if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [IO.File]::WriteAllText($full, $content, (New-Object Text.UTF8Encoding($false)))
                return [pscustomobject]@{
                    text     = ("作成しました: {0} ({1} バイト)" -f $full, $bytes.Length)
                    artifact = $full
                    isError  = $false
                }
            }

            'create_email_draft' {
                $rel = if ($ToolInput.path) { [string] $ToolInput.path } else { 'draft.eml' }
                if ([IO.Path]::GetExtension($rel).ToLower() -ne '.eml') { $rel = $rel + '.eml' }
                $full = Resolve-TargetPath -Workspace $Workspace -Relative $rel

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
                $full = Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path)
                if (-not (Test-Path -LiteralPath $full)) { throw "ファイルがありません: $full" }
                return [pscustomobject]@{
                    text     = Limit-Text ([IO.File]::ReadAllText($full, [Text.Encoding]::UTF8))
                    artifact = $null
                    isError  = $false
                }
            }

            'list_files' {
                $target = if ($ToolInput.path) { Resolve-TargetPath -Workspace $Workspace -Relative ([string] $ToolInput.path) } else { $Workspace }
                if (-not (Test-Path -LiteralPath $target)) { throw "フォルダがありません: $target" }
                $files = @(Get-ChildItem -LiteralPath $target -File -ErrorAction SilentlyContinue)
                $text = if ($files.Count -eq 0) { '(ファイルはありません)' }
                        else { ($files | ForEach-Object { "{0} ({1} バイト)" -f $_.Name, $_.Length }) -join "`n" }
                return [pscustomobject]@{ text = Limit-Text $text; artifact = $null; isError = $false }
            }

            'run_command' {
                $cmd = [string] $ToolInput.command
                $job = Start-Job -ScriptBlock {
                    param($c, $wd)
                    Set-Location -LiteralPath $wd
                    & powershell -NoProfile -NonInteractive -Command $c 2>&1 | Out-String
                } -ArgumentList $cmd, $Workspace
                try {
                    if (Wait-Job $job -Timeout $CommandTimeoutSec) {
                        $out = (Receive-Job $job) -join "`n"
                        $text = if ($out.Trim()) { $out } else { '(出力なし。コマンドは完了しました)' }
                        return [pscustomobject]@{ text = Limit-Text $text; artifact = $null; isError = $false }
                    }
                    Stop-Job $job
                    return [pscustomobject]@{
                        text = "タイムアウトしました ($CommandTimeoutSec 秒)。処理は中断されました。"
                        artifact = $null; isError = $true
                    }
                }
                finally { Remove-Job $job -Force -ErrorAction SilentlyContinue }
            }

            'http_request' {
                $method = if ($ToolInput.method) { [string] $ToolInput.method } else { 'GET' }
                $r = Invoke-HttpAction -Method $method -Url ([string] $ToolInput.url) `
                        -Headers $ToolInput.headers -Body ([string] $ToolInput.body)
                return [pscustomobject]@{ text = $r.text; artifact = $null; isError = $r.isError }
            }

            'open_source' {
                if (-not $SourceEvent) {
                    return [pscustomobject]@{
                        text = 'このカードには元の通知がありません (手で起票されたカードです)。'
                        artifact = $null; isError = $true
                    }
                }
                $c = Get-SourceContext -Evt $SourceEvent
                $sb = New-Object Text.StringBuilder
                [void] $sb.AppendLine("種別: $($c.kind)")
                if ($c.identifiers -and $c.identifiers.Count -gt 0) {
                    [void] $sb.AppendLine('識別子 (http_request で使えます):')
                    foreach ($k in $c.identifiers.Keys) {
                        if ($c.identifiers[$k]) { [void] $sb.AppendLine("  $k = $($c.identifiers[$k])") }
                    }
                }
                if ($c.attachments.Count -gt 0) {
                    [void] $sb.AppendLine('添付 (fetch_attachment で取り込めます):')
                    foreach ($a in $c.attachments) {
                        [void] $sb.AppendLine("  id=$($a.id)  $($a.name)  $($a.mimeType)  $($a.size) バイト")
                    }
                }
                if ($c.links.Count -gt 0) {
                    [void] $sb.AppendLine('本文中のリンク:')
                    foreach ($l in $c.links) { [void] $sb.AppendLine("  $l") }
                }
                if ($c.note) { [void] $sb.AppendLine("注: $($c.note)") }
                [void] $sb.AppendLine()
                [void] $sb.AppendLine('--- 本文 ---')
                [void] $sb.AppendLine($c.text)
                return [pscustomobject]@{
                    text = $sb.ToString(); artifact = $null; isError = (-not $c.ok)
                }
            }

            'fetch_attachment' {
                $a = Get-SourceAttachment -AttachmentId ([string] $ToolInput.attachment_id) `
                        -Workspace $Workspace -Name ([string] $ToolInput.name)
                $text = "取り込みました: $($a.name) ($($a.bytes) バイト)"
                if ($a.text) { $text += "`n`n--- 中身 ---`n" + $a.text }
                else { $text += "`nテキストとして読める形式ではありません。作業フォルダに置きました。" }
                return [pscustomobject]@{ text = $text; artifact = $a.path; isError = $false }
            }

            'recall' {
                if (-not $DossierText) {
                    return [pscustomobject]@{
                        text = 'この件について過去に記録された事実はありません (初回です)。'
                        artifact = $null; isError = $false
                    }
                }
                return [pscustomobject]@{
                    text = "この件について前回までに分かっていること:`n" + $DossierText
                    artifact = $null; isError = $false
                }
            }

            default { throw "未知のツールです: $Name" }
        }
    }
    catch {
        # 失敗もモデルに返す。握り潰すと同じ誤りを繰り返す。
        return [pscustomobject]@{ text = ("エラー: " + $_.Exception.Message); artifact = $null; isError = $true }
    }
}
