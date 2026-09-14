# ChatworkBacklog.Tests.ps1
# Chatwork と Backlog の連携。
#
# ネットワークには出ない。Get-Secret と、各コネクタの API 呼び出しを差し替える。
# ケースは同じスコープで読み込まれるので、差し替えは最後に必ず元に戻す。
#
# ここで見ているのは「壊れても静かなところ」:
#   - 掃き寄せの取捨 (自分の発言を拾う、メンションを取りこぼす、は画面上で気付けない)
#   - watermark を進めてよい場面かどうか (進めすぎると穴が開き、止めると永久に入らない)
#   - 投稿先の束縛と、承認の要否
#   - Backlog の API キーが URL にしか載せられないこと (汎用 HTTP に渡さない)

. "$RepoRoot\phase4\lib\HttpAction.ps1"
. "$RepoRoot\phase4\lib\WorkTools.ps1"
. "$RepoRoot\phase5\lib\ChatworkConnector.ps1"
. "$RepoRoot\phase5\lib\BacklogConnector.ps1"

$script:FakeSecrets = @{}

function Get-Secret {
    param([string] $Name, [string] $Path)
    if ($script:FakeSecrets.ContainsKey($Name)) { return [string] $script:FakeSecrets[$Name] }
    return $null
}
function Set-Secret {
    param([string] $Name, [string] $Value, [string] $Path)
    $script:FakeSecrets[$Name] = $Value
}
function Get-SecretNames { param([string] $Path) return @() }
function Invoke-WebRequest { throw '送信されてはいけないリクエストが送られました' }

try {

Describe 'Chatwork の本文を読める形に均す' {

    It '[To:123] は宛先の名前だけ残す' {
        $t = Expand-ChatworkText '[To:1234567] 山田 太郎
明日の件です'
        Assert-Match '^@山田 太郎' $t
        Assert-Match '明日の件です' $t
        Assert-False ($t -match '\[To:')
    }

    It '返信記法も同じ形にする' {
        $t = Expand-ChatworkText '[rp aid=1234567 to=98765-4321] 鈴木 花子
承知しました'
        Assert-Match '@鈴木 花子' $t
        Assert-Match '承知しました' $t
    }

    It '引用は「誰かの引用」と分かる形にして中身を残す (判断材料そのものなので消さない)' {
        $t = Expand-ChatworkText '[qt][qtmeta aid=111 time=1757000000]元の発言[/qt]了解です'
        Assert-Match '引用ここから' $t
        Assert-Match '元の発言' $t
        Assert-Match '了解です' $t
        Assert-False ($t -match 'qtmeta')
    }

    It '情報ブロックと見出しはタグを落として中身を残す' {
        $t = Expand-ChatworkText '[info][title]月次報告[/title]添付をご確認ください[/info]'
        Assert-Match '月次報告' $t
        Assert-Match '添付をご確認ください' $t
        Assert-False ($t -match '\[info\]')
    }

    It 'ファイルの参照は印を残す (実体が添付にしかないことがある)' {
        Assert-Match 'ファイル 999' (Expand-ChatworkText '[download:999]資料.xlsx[/download]')
    }
}

Describe 'Chatwork のリンク' {

    It '組み立てたリンクをそのまま読み戻せる' {
        $link = New-ChatworkLink -RoomId '12345' -MessageId '67890'
        Assert-Equal 'https://www.chatwork.com/#!rid12345-67890' $link
        $ref = ConvertFrom-ChatworkLink $link
        Assert-Equal '12345' $ref.roomId
        Assert-Equal '67890' $ref.messageId
    }

    It '部屋だけのリンクも読める' {
        Assert-Equal '12345' (ConvertFrom-ChatworkLink 'https://www.chatwork.com/#!rid12345').roomId
    }

    It '関係のないリンクは null' {
        Assert-Null (ConvertFrom-ChatworkLink 'https://example.com/')
        Assert-Null (ConvertFrom-ChatworkLink '')
    }
}

Describe 'Chatwork の掃き寄せ' {

    $script:FakeSecrets = @{ 'chatwork.token' = 'tok'; 'chatwork.selfAccountId' = '100' }
    $script:ChatworkSelfId = '100'
    $script:FakeCwPaths = @()
    $script:FakeCwRoomError = ''
    $script:FakeCwMessageCount = 3
    $script:FakeCwForm = $null

    function Invoke-ChatworkApi {
        param([string] $Path, [string] $Method = 'Get', [hashtable] $Form)
        $script:FakeCwPaths += $Path
        if ($Method -eq 'Post') { $script:FakeCwForm = $Form; return [pscustomobject]@{ message_id = '555' } }
        if ($Path -eq '/rooms') {
            return @(
                [pscustomobject]@{ room_id = 11; name = '山田 太郎'; type = 'direct'; last_update_time = 2600 },
                [pscustomobject]@{ room_id = 22; name = '全社連絡'; type = 'group';  last_update_time = 2800 },
                # watermark と同じ時刻の部屋は「前回で読み切った」とみなして開かない
                [pscustomobject]@{ room_id = 33; name = '去年の部屋'; type = 'group'; last_update_time = 2000 },
                [pscustomobject]@{ room_id = 44; name = '読めない部屋'; type = 'group'; last_update_time = 2900 }
            )
        }
        if ($Path -like '/rooms/44/*') { throw $script:FakeCwRoomError }
        if ($Path -like '/rooms/11/*') {
            return @(
                [pscustomobject]@{ message_id = 'm1'; send_time = 1500
                                   account = [pscustomobject]@{ account_id = 200; name = '山田 太郎' }; body = '古い発言' },
                [pscustomobject]@{ message_id = 'm2'; send_time = 2500
                                   account = [pscustomobject]@{ account_id = 100; name = '自分' }; body = 'こちらの発言' },
                [pscustomobject]@{ message_id = 'm3'; send_time = 2600
                                   account = [pscustomobject]@{ account_id = 200; name = '山田 太郎' }; body = 'ご確認ください' }
            )
        }
        if ($Path -like '/rooms/22/*') {
            $msgs = @(
                [pscustomobject]@{ message_id = 'g1'; send_time = 2600
                                   account = [pscustomobject]@{ account_id = 300; name = '鈴木 花子' }; body = '雑談です' },
                [pscustomobject]@{ message_id = 'g2'; send_time = 2700
                                   account = [pscustomobject]@{ account_id = 300; name = '鈴木 花子' }; body = '[To:100] 自分
確認をお願いします' },
                [pscustomobject]@{ message_id = 'g3'; send_time = 2800
                                   account = [pscustomobject]@{ account_id = 300; name = '鈴木 花子' }; body = '[toall] 全員にお知らせ' }
            )
            if ($script:FakeCwMessageCount -ge 100) {
                # 100 件の上限に当たった状況。いちばん古いものが watermark より新しい
                $filler = @(1..100 | ForEach-Object {
                    [pscustomobject]@{ message_id = ("f$_"); send_time = 2900
                                       account = [pscustomobject]@{ account_id = 300; name = '鈴木 花子' }; body = '[To:100] 埋め草' }
                })
                return $filler
            }
            return $msgs
        }
        if ($Path -like '/rooms/33/*') { return $null }   # 204 (メッセージ無し)
        return $null
    }

    It 'DM は拾い、自分の発言と watermark より古いものは拾わない' {
        $script:FakeCwRoomError = 'Chatwork API /rooms/44/messages が失敗しました: forbidden (HTTP 403)'
        $sweep = Get-ChatworkUpdates -Since ([DateTimeOffset]::FromUnixTimeSeconds(2000).LocalDateTime)
        $dm = @($sweep.messages | Where-Object { $_.roomId -eq '11' })
        Assert-Equal 1 $dm.Count
        Assert-Equal 'm3' $dm[0].messageId
        Assert-Equal 'dm' $dm[0].reason
    }

    It 'グループは名指しされたものだけ拾う ([toall] と雑談は拾わない)' {
        $sweep = Get-ChatworkUpdates -Since ([DateTimeOffset]::FromUnixTimeSeconds(2000).LocalDateTime)
        $g = @($sweep.messages | Where-Object { $_.roomId -eq '22' })
        Assert-Equal 1 $g.Count
        Assert-Equal 'g2' $g[0].messageId
        Assert-Equal 'mention' $g[0].reason
    }

    It '最終更新が watermark より古い部屋は開かない (レート制限があるので)' {
        $script:FakeCwPaths = @()
        [void] (Get-ChatworkUpdates -Since ([DateTimeOffset]::FromUnixTimeSeconds(2000).LocalDateTime))
        Assert-False (@($script:FakeCwPaths) -contains '/rooms/33/messages?force=1')
    }

    It '読めない部屋が1つあっても他は拾う。権限不足は恒久的な失敗' {
        $sweep = Get-ChatworkUpdates -Since ([DateTimeOffset]::FromUnixTimeSeconds(2000).LocalDateTime)
        Assert-Equal 1 @($sweep.errors).Count
        Assert-Equal '読めない部屋' $sweep.errors[0].room
        Assert-True $sweep.errors[0].permanent
    }

    It 'レート制限は据え置きの理由にする (進めると取りこぼす)' {
        $script:FakeCwRoomError = 'Chatwork API /rooms/44/messages が失敗しました: too many requests (HTTP 429)'
        $sweep = Get-ChatworkUpdates -Since ([DateTimeOffset]::FromUnixTimeSeconds(2000).LocalDateTime)
        Assert-False $sweep.errors[0].permanent
    }

    It '100 件の上限に当たったら「取り切れていない」と伝える' {
        # ここで watermark を進めると、100 件からあふれた分が永久に入らない
        $script:FakeCwMessageCount = 100
        $sweep = Get-ChatworkUpdates -Since ([DateTimeOffset]::FromUnixTimeSeconds(2000).LocalDateTime)
        Assert-True $sweep.truncated
        $script:FakeCwMessageCount = 3
    }

    It '取り切れたときは truncated を立てない' {
        Assert-False (Get-ChatworkUpdates -Since ([DateTimeOffset]::FromUnixTimeSeconds(2000).LocalDateTime)).truncated
    }

    It '投稿は元の発言への返信として組み立てる' {
        $script:FakeCwForm = $null
        $r = Send-ChatworkMessage -RoomId '11' -Text '承知しました' -ReplyToAccountId '200' -ReplyToMessageId 'm3'
        Assert-Match '^\[rp aid=200 to=11-m3\]' ([string] $script:FakeCwForm['body'])
        Assert-Match '承知しました' ([string] $script:FakeCwForm['body'])
        Assert-Equal 'https://www.chatwork.com/#!rid11-555' $r.permalink
    }

    It '空の本文は投稿しない' {
        Assert-Throws { Send-ChatworkMessage -RoomId '11' -Text '   ' }
    }

    Remove-Item -Path Function:\Invoke-ChatworkApi -ErrorAction SilentlyContinue
}

Describe 'Backlog のスペース指定' {

    It 'https:// やパスが付いていても受ける (貼り方で 404 にしない)' {
        Assert-Equal 'example.backlog.jp' (Get-BacklogSpace 'https://example.backlog.jp/dashboard')
        Assert-Equal 'example.backlog.jp' (Get-BacklogSpace '  example.backlog.jp  ')
        Assert-Equal 'example.backlog.com' (Get-BacklogSpace 'http://example.backlog.com/')
    }
}

Describe 'Backlog のリンクとお知らせ' {

    It '課題のリンクを組み立てて読み戻せる' {
        $script:FakeSecrets['backlog.space'] = 'example.backlog.jp'
        $link = New-BacklogLink -IssueKey 'PROJ-12' -CommentId '345'
        Assert-Equal 'https://example.backlog.jp/view/PROJ-12#comment-345' $link
        $ref = ConvertFrom-BacklogLink $link
        Assert-Equal 'PROJ-12' $ref.issueKey
        Assert-Equal '345' $ref.commentId
    }

    It 'お知らせの理由を日本語にする (数字のままでは読めない)' {
        Assert-Equal '課題の担当者に設定されました' (Get-BacklogReasonText 1)
        Assert-Equal '課題にコメントが付きました' (Get-BacklogReasonText 2)
        Assert-Equal 'お知らせ' (Get-BacklogReasonText 99)
    }

    It '課題を伴わないお知らせ (プルリクエスト) は飛ばす' {
        $n = [pscustomobject]@{ id = 1; reason = 11; created = '2026-09-13T01:00:00Z'; issue = $null }
        Assert-Null (ConvertFrom-BacklogNotification $n)
    }

    It 'コメントと課題をカードの材料にそろえる' {
        $n = [pscustomobject]@{
            id = 7; reason = 2; created = '2026-09-13T01:00:00Z'
            sender = [pscustomobject]@{ name = '鈴木 花子' }
            issue = [pscustomobject]@{ issueKey = 'PROJ-12'; summary = '見積の確認'; description = '本文' }
            comment = [pscustomobject]@{ id = 345; content = 'ご確認お願いします' }
        }
        $item = ConvertFrom-BacklogNotification $n
        Assert-Equal 'PROJ-12' $item.issueKey
        Assert-Equal '課題にコメントが付きました' $item.reason
        Assert-Equal 'ご確認お願いします' $item.comment
        Assert-Match '/view/PROJ-12#comment-345' $item.link
    }
}

Describe 'Backlog の取り込み' {

    $script:FakeSecrets['backlog.apiKey'] = 'key'
    $script:FakeSecrets['backlog.space'] = 'example.backlog.jp'
    $script:FakeBlCount = 3
    $script:FakeBlForm = $null

    function New-FakeNotification {
        param([int] $Id, [string] $Created)
        return [pscustomobject]@{
            id = $Id; reason = 2; created = $Created
            sender = [pscustomobject]@{ name = '鈴木 花子' }
            issue = [pscustomobject]@{ issueKey = ('PROJ-' + $Id); summary = ('件名' + $Id); description = '' }
            comment = [pscustomobject]@{ id = (100 + $Id); content = 'コメント' }
        }
    }

    function Invoke-BacklogApi {
        param([string] $Path, [string] $Method = 'Get', [string] $Query, [hashtable] $Form)
        if ($Method -eq 'Post') { $script:FakeBlForm = $Form; return [pscustomobject]@{ id = 999 } }
        if ($Path -eq '/notifications') {
            # 実物と同じ「新しい順」で返す
            if ($script:FakeBlCount -ge 100) {
                return @(1..100 | ForEach-Object { New-FakeNotification -Id $_ -Created '2026-09-13T05:00:00Z' })
            }
            return @(
                (New-FakeNotification -Id 3 -Created '2026-09-13T03:00:00Z'),
                (New-FakeNotification -Id 2 -Created '2026-09-13T02:00:00Z'),
                (New-FakeNotification -Id 1 -Created '2026-09-12T23:00:00Z')
            )
        }
        throw ("想定外の呼び出し: " + $Path)
    }

    It 'watermark より新しいものだけを、古い順に返す' {
        $r = Get-BacklogNotifications -Since ([DateTime] '2026-09-13T01:00:00Z')
        Assert-Equal 2 @($r.items).Count
        Assert-Equal 'PROJ-2' $r.items[0].issueKey
        Assert-Equal 'PROJ-3' $r.items[1].issueKey
    }

    It '取り切れていれば truncated を立てない' {
        Assert-False (Get-BacklogNotifications -Since ([DateTime] '2026-09-13T01:00:00Z')).truncated
    }

    It '1ページに収まらなかったら伝える (進めると間が飛ぶ)' {
        $script:FakeBlCount = 100
        Assert-True (Get-BacklogNotifications -Since ([DateTime] '2026-09-13T01:00:00Z')).truncated
        $script:FakeBlCount = 3
    }

    It 'コメントは本文だけを送る (通知先を文面から作らない)' {
        $script:FakeBlForm = $null
        $r = Add-BacklogComment -IssueKey 'PROJ-12' -Content '確認しました'
        Assert-Equal '確認しました' ([string] $script:FakeBlForm['content'])
        Assert-False ($script:FakeBlForm.ContainsKey('notifiedUserId'))
        Assert-Match '#comment-999' $r.permalink
    }

    It '空のコメントは投稿しない' {
        Assert-Throws { Add-BacklogComment -IssueKey 'PROJ-12' -Content ' ' }
    }

    Remove-Item -Path Function:\Invoke-BacklogApi -ErrorAction SilentlyContinue
}

Describe '資格情報の載せ方' {

    It 'Chatwork は Authorization ではなく専用ヘッダに載せる' {
        $script:FakeSecrets = @{ 'chatwork.token' = 'cw-token' }
        $c = (Get-CredentialStatus -Url 'https://api.chatwork.com/v2/rooms').credential
        Assert-Equal 'X-ChatWorkToken' $c.header
        # scheme が無いサービスなので "Bearer " のような接頭辞は付けない
        Assert-Equal 'cw-token' $c.value
    }

    It 'Backlog には資格情報を渡さない (キーが URL にしか載せられないため)' {
        # 注入すると承認画面と作業ログに API キーが残る。
        # Backlog を叩くのは専用のコネクタ経由だけにする。
        Assert-Null (Get-HostCredentialSpec -Url 'https://example.backlog.jp/api/v2/issues')
        Assert-Equal 'none' (Get-CredentialStatus -Url 'https://example.backlog.jp/api/v2/issues').state
    }
}

Describe 'ツールの出し分けと承認 (Chatwork / Backlog)' {

    It '未設定なら投稿ツールを見せない' {
        $script:FakeSecrets = @{}
        $names = @(Get-WorkTools -HasChatworkTarget -HasBacklogTarget | ForEach-Object { $_.name })
        Assert-False ($names -contains 'send_chatwork_message')
        Assert-False ($names -contains 'add_backlog_comment')
    }

    It '投稿先があるカードにだけ出す' {
        $script:FakeSecrets = @{ 'chatwork.token' = 'tok'; 'backlog.apiKey' = 'key'; 'backlog.space' = 'example.backlog.jp' }
        $none = @(Get-WorkTools | ForEach-Object { $_.name })
        Assert-False ($none -contains 'send_chatwork_message')
        Assert-False ($none -contains 'add_backlog_comment')
        Assert-True (@(Get-WorkTools -HasChatworkTarget | ForEach-Object { $_.name }) -contains 'send_chatwork_message')
        Assert-True (@(Get-WorkTools -HasBacklogTarget | ForEach-Object { $_.name }) -contains 'add_backlog_comment')
    }

    It '投稿は承認が要り、束縛された投稿先が画面に出る' {
        $r = Get-ToolRisk -Name 'send_chatwork_message' -Workspace '.' `
                -ToolInput ([pscustomobject]@{ text = '承知しました' }) -ChatworkRoomName '山田 太郎'
        Assert-True $r.risky
        Assert-Match '山田 太郎' $r.detail

        $b = Get-ToolRisk -Name 'add_backlog_comment' -Workspace '.' `
                -ToolInput ([pscustomobject]@{ text = '確認しました' }) -BacklogIssueKey 'PROJ-12'
        Assert-True $b.risky
        Assert-Match 'PROJ-12' $b.detail
    }

    It '投稿とコメントは取り消せない扱い' {
        Assert-True (Test-IrreversibleTool -Name 'send_chatwork_message')
        Assert-True (Test-IrreversibleTool -Name 'add_backlog_comment')
    }

    It '投稿先の無いカードでは投稿できない' {
        $r = Invoke-WorkTool -Name 'send_chatwork_message' -Workspace '.' -ToolInput ([pscustomobject]@{ text = 'x' })
        Assert-True $r.isError
        Assert-Match '投稿先' $r.text

        $b = Invoke-WorkTool -Name 'add_backlog_comment' -Workspace '.' -ToolInput ([pscustomobject]@{ text = 'x' })
        Assert-True $b.isError
        Assert-Match '課題' $b.text
    }
}

}
finally {
    # 差し替えを戻す。後続のケースが本物の Get-Secret を使えるように。
    Remove-Item -Path Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Invoke-ChatworkApi -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Invoke-BacklogApi -ErrorAction SilentlyContinue
    $script:ChatworkSelfId = $null
    . "$RepoRoot\phase5\lib\SecretStore.ps1"
    . "$RepoRoot\phase5\lib\ChatworkConnector.ps1"
    . "$RepoRoot\phase5\lib\BacklogConnector.ps1"
}
