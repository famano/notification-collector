# BoardApi.Tests.ps1
# カンバンの HTTP API を、実際にサーバを立てて叩く。
#
# ここはこのアプリで一番テストしにくく、一番危ないところでもある。
#   - ブラウザから来る操作が全部ここを通る (削除・送信・承認)
#   - ボードには第三者が書いた文面が載っている
#   - 127.0.0.1 で開いているので、他のページから叩かれうる
# 関数だけを見ていても分からないので、プロセスとして起動して外から叩く。
#
# 外に出るのは 127.0.0.1 だけ。DB は一時フォルダに作って捨てる。
# ポートを開けない環境では、黙って通さずに skip と出して飛ばす。

. "$RepoRoot\phase2\lib\TaskStore.ps1"
. "$RepoRoot\phase2\lib\Memory.ps1"

# ---------------------------------------------------------------- 起動

function Get-FreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = $l.LocalEndpoint.Port
    $l.Stop()
    return $p
}

function Start-TestBoard {
    <#
      .OUTPUTS
        @{ process; port; base; db } / 起動できなければ $null
    #>
    param([string] $DbPath, [string] $OutputRoot)
    $port = Get-FreePort
    # いま動いている処理系でそのまま起動する (Windows なら powershell.exe)
    $exe = (Get-Process -Id $PID).Path
    # 作業フォルダも一時フォルダに向ける。既定 (phase4\output) のままだと、
    # 開発機に残っているフォルダの有無でテストの結果が変わる。
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $RepoRoot 'phase3\Start-Board.ps1'),
                '-Port', $port, '-NoBrowser', '-DbPath', $DbPath,
                '-OutputRoot', $OutputRoot)
    $start = @{ FilePath = $exe; ArgumentList = $psArgs; PassThru = $true }
    # -WindowStyle は Windows 以外の PowerShell では受け付けられない
    if ($env:OS -eq 'Windows_NT') { $start['WindowStyle'] = 'Hidden' }
    $p = Start-Process @start
    $base = "http://127.0.0.1:$port"

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ($p.HasExited) { return $null }
        try {
            [void] (Invoke-WebRequest -Uri "$base/api/rev" -UseBasicParsing -TimeoutSec 3)
            return [pscustomobject]@{ process = $p; port = $port; base = $base; db = $DbPath }
        }
        catch { Start-Sleep -Milliseconds 400 }
    }
    try { $p.Kill() } catch { }
    return $null
}

# Host ヘッダを自分で決めた要求を投げる。
# Invoke-WebRequest は Host を自分で書き換えるので、この検査だけは生のソケットで行う。
function Invoke-RawRequest {
    param([Parameter(Mandatory)] $Board, [Parameter(Mandatory)] [string] $HostHeader, [string] $Path = '/api/board')
    $client = New-Object Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Board.port)
        $req = "GET $Path HTTP/1.1`r`nHost: $HostHeader`r`nConnection: close`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($req)
        $ns = $client.GetStream()
        $ns.Write($bytes, 0, $bytes.Length)
        $ns.Flush()
        $sr = New-Object IO.StreamReader($ns)
        $line = $sr.ReadLine()
        $sr.Dispose()
        if ($line -match '^HTTP/1\.\d (\d{3})') { return [int] $Matches[1] }
        return 0
    }
    finally { $client.Close() }
}

function Stop-TestBoard {
    param($Board)
    if ($Board -and $Board.process -and -not $Board.process.HasExited) {
        try { $Board.process.Kill() } catch { }
    }
}

# 4xx/5xx でも例外にせず、状態コードと本文を返す。
function Invoke-Board {
    param(
        [Parameter(Mandatory)] $Board,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'GET',
        $Body,
        [hashtable] $Headers
    )
    $h = @{}
    if ($Headers) { foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] } }
    $req = @{
        Uri = ($Board.base + $Path); Method = $Method; UseBasicParsing = $true; TimeoutSec = 20
        Headers = $h
    }
    if ($null -ne $Body) {
        $req['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress))
        $req['ContentType'] = 'application/json; charset=utf-8'
    }
    try {
        $r = Invoke-WebRequest @req
        $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        $obj = $null
        try { $obj = $text | ConvertFrom-Json } catch { }
        return [pscustomobject]@{ status = [int] $r.StatusCode; body = $obj; text = $text }
    }
    catch {
        $status = 0
        if ($_.Exception.Response) { try { $status = [int] $_.Exception.Response.StatusCode } catch { } }
        # 本文の取り出し方が版で違う。7.x は ErrorDetails に入れ、5.1 は応答の
        # ストリームから読む。どちらでも読めるように両方見る。
        $text = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $text = [string] $_.ErrorDetails.Message }
        if (-not $text -and $_.Exception.Response) {
            try {
                $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                $text = $sr.ReadToEnd(); $sr.Dispose()
            } catch { }
        }
        $obj = $null
        try { $obj = $text | ConvertFrom-Json } catch { }
        return [pscustomobject]@{ status = $status; body = $obj; text = $text }
    }
}

# ---------------------------------------------------------------- 準備

if (-not (Test-SqliteAvailable)) {
    Describe 'カンバンの API' { Skip-It 'すべて' 'winsqlite3.dll が使えません' }
    return
}

$dbDir = New-TestTempDir
$dbPath = Join-Path $dbDir 'tasks.db'
$seed = Open-TaskStore -Path $dbPath
$todoId    = [int] (New-Task -Conn $seed -Title '要対応のカード' -Column 'todo')
$reviewId  = [int] (New-Task -Conn $seed -Title 'レビュー待ちのカード' -Column 'review')
$doneId    = [int] (New-Task -Conn $seed -Title '完了のカード' -Column 'done')
$reworkId  = [int] (New-Task -Conn $seed -Title '指示でやり直すカード' -Column 'review')
$doingId   = [int] (New-Task -Conn $seed -Title '実行中のカード' -Column 'doing')
$approveId = [int] (New-Task -Conn $seed -Title '報告を承認するカード' -Column 'review')
$keepId    = [int] (New-Task -Conn $seed -Title '記録を消さないカード' -Column 'review')
[void] (Update-TaskFields -Conn $seed -TaskId $keepId -Fields @{ user_edited = '書きかけの文面' })

# 返信先の内容を割って返せるか。Phase 5 が積む形をそのまま入れる。
$mailEv = Add-Event -Conn $seed -Source 'gmail' -SourceKey 'm1' -App 'Gmail' -AppId 'gmail' `
            -OccurredAt '2026-09-12T10:00:00' -Title '請求書の件' `
            -Body "差出人: 田中 <tanaka@example.com>`n宛先: me@example.com`nCc: keiri@example.com`n日時: Fri, 12 Sep 2026 10:00:00 +0900`n`nお世話になっております。`n請求書をお送りします。"
$mailId = [int] (New-Task -Conn $seed -EventId $mailEv.id -Title '請求書の件' -Column 'review')

$slackEv = Add-Event -Conn $seed -Source 'slack' -SourceKey 's1' -App 'Slack' -AppId 'slack' `
            -OccurredAt '2026-09-12T11:00:00' -Title '#general / 佐藤' `
            -Body "見てもらえますか`n`n--- スレッド全文 (2 件) ---`n--- 佐藤 / 11:00`nこれ確認できますか`n`n--- 鈴木 / 11:05`n私も気になっていました"
$slackId = [int] (New-Task -Conn $seed -EventId $slackEv.id -Title '#general / 佐藤' -Column 'review')
$seed.Dispose()

# 成果物のあるカード。フォルダの場所は DB の記録から引けること。
$artDir = Join-Path $dbDir 'task-0099'
[void] (New-Item -ItemType Directory -Path $artDir -Force)
$artFile = Join-Path $artDir '成果物.md'
Set-Content -LiteralPath $artFile -Value '# 出力' -Encoding UTF8
$seed2 = Open-TaskStore -Path $dbPath
$artId = [int] (New-Task -Conn $seed2 -Title '成果物のあるカード' -Column 'review')
Add-TaskArtifact -Conn $seed2 -TaskId $artId -Path $artFile
$seed2.Dispose()

$board = Start-TestBoard -DbPath $dbPath -OutputRoot (Join-Path $dbDir 'output')
if (-not $board) {
    Describe 'カンバンの API' { Skip-It 'すべて' 'ボードを起動できませんでした (ポートを開けない環境)' }
    return
}

try {

Describe 'ボードの読み出し' {

    It '列ごとにカードが返る' {
        $r = Invoke-Board $board '/api/board'
        Assert-Equal 200 $r.status
        $cols = @($r.body.columns | ForEach-Object { $_.key })
        Assert-True ($cols -contains 'todo')
        Assert-True ($cols -contains 'review')
        $todo = @($r.body.columns | Where-Object { $_.key -eq 'todo' })[0]
        Assert-Equal 1 (@($todo.tasks)).Count
    }

    It '版だけを安く取れる (画面はこれを 1.5 秒ごとに叩く)' {
        $r = Invoke-Board $board '/api/rev'
        Assert-Equal 200 $r.status
        Assert-NotNull $r.body.rev
        Assert-NotNull $r.body.worker
        Assert-NotNull $r.body.collector
    }

    It 'カードの詳細が返る' {
        $r = Invoke-Board $board ("/api/tasks/$todoId")
        Assert-Equal 200 $r.status
        Assert-Equal '要対応のカード' $r.body.task.title
    }

    It '無いカードは 404' {
        Assert-Equal 404 (Invoke-Board $board '/api/tasks/999999').status
    }
}

Describe 'カードを動かす' {

    It '版が合っていれば動く' {
        $t = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$todoId/move") 'POST' @{ column = 'doing'; version = $t.version; from = 'todo' }
        Assert-Equal 200 $r.status
        Assert-Equal 'doing' (Invoke-Board $board ("/api/tasks/$todoId")).body.task.board_column
    }

    It '古い版で押したら 409 (画面が古いまま押した場合)' {
        $r = Invoke-Board $board ("/api/tasks/$todoId/move") 'POST' @{ column = 'done'; version = 1; from = 'doing' }
        Assert-Equal 409 $r.status
    }

    It '知らない列には動かせない' {
        $t = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$todoId/move") 'POST' @{ column = 'どこか'; version = $t.version }
        Assert-Equal 400 $r.status
    }

    It '実行中から動かすと中止要求になる (これが割り込みの信号)' {
        $t = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        [void] (Invoke-Board $board ("/api/tasks/$todoId/move") 'POST' @{ column = 'review'; version = $t.version; from = 'doing' })
        Assert-Equal 1 (Invoke-Board $board ("/api/tasks/$todoId")).body.task.cancel_requested
    }

    It '要対応に戻すと中止要求が解ける (もう一度やって、の意思表示)' {
        $t = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        [void] (Invoke-Board $board ("/api/tasks/$todoId/move") 'POST' @{ column = 'todo'; version = $t.version; from = 'review' })
        Assert-Equal 0 (Invoke-Board $board ("/api/tasks/$todoId")).body.task.cancel_requested
    }
}

Describe 'カードの出口' {

    It '「これで完了にする」で、書いた内容が残って完了に移る' {
        $t = (Invoke-Board $board ("/api/tasks/$reviewId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$reviewId/done") 'POST' @{ text = '電話で確認して対応済み'; version = $t.version }
        Assert-Equal 200 $r.status
        $after = (Invoke-Board $board ("/api/tasks/$reviewId")).body.task
        Assert-Equal 'done' $after.board_column
        Assert-Equal '電話で確認して対応済み' $after.user_record
    }

    It '送り先の無いカードは送信できない' {
        $t = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$todoId/send") 'POST' @{ text = '本文'; version = $t.version; confirm = $true }
        Assert-Equal 400 $r.status
    }

    It '確認を通さない送信は受け付けない' {
        $t = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$todoId/send") 'POST' @{ text = '本文'; version = $t.version }
        Assert-Equal 400 $r.status
    }

    It '宛先はリクエストから受け取らない (第三者の文面から差し替えさせない)' {
        # to / channel を添えても、送り先の無いカードは送れないまま。
        # 宛先はサーバがカードの元イベントから決めるので、ここに何を書いても効かない。
        $t = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$todoId/send") 'POST' `
                @{ text = '本文'; version = $t.version; confirm = $true; to = 'attacker@example.com'; channel = 'C999' }
        Assert-Equal 400 $r.status
        Assert-Match '送り先がありません' ([string] $r.body.error)
    }
}

Describe '報告を承認して閉じる' {

    # レビューで一番読まれるのはワーカーの報告で、多くはその内容で了として閉じる。
    # 「対応の記録」を書き写させずに閉じられること。
    It '承認すると完了に移り、承認したことが作業ログに残る' {
        $t = (Invoke-Board $board ("/api/tasks/$approveId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$approveId/approve") 'POST' @{ version = $t.version }
        Assert-Equal 200 $r.status
        $d = (Invoke-Board $board ("/api/tasks/$approveId")).body
        Assert-Equal 'done' $d.task.board_column
        Assert-Match '承認' ([string] (@($d.activity)[-1].message))
    }

    It '古い版で押したら 409 (画面が古いまま押した場合)' {
        Assert-Equal 409 (Invoke-Board $board ("/api/tasks/$approveId/approve") 'POST' @{ version = 1 }).status
    }

    It 'ひとことを残せば、それが記録として残る' {
        $t = (Invoke-Board $board ("/api/tasks/$doneId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$doneId/approve") 'POST' @{ note = '妥当と判断'; version = $t.version }
        Assert-Equal 200 $r.status
        Assert-Equal '妥当と判断' (Invoke-Board $board ("/api/tasks/$doneId")).body.task.user_record
    }

    # 「送らずに完了」を選んだだけで書きかけの文面が消えると取り返しがつかない。
    It '空のまま完了にしても、書きかけの文面は消えない' {
        $t = (Invoke-Board $board ("/api/tasks/$keepId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$keepId/done") 'POST' @{ text = ''; version = $t.version }
        Assert-Equal 200 $r.status
        $after = (Invoke-Board $board ("/api/tasks/$keepId")).body.task
        Assert-Equal 'done' $after.board_column
        Assert-Equal '書きかけの文面' $after.user_edited
    }

    # 以前は記録も user_edited に入れていたため、返信先のあるカードで
    # 記録を残すと送る欄に出て、記録の欄からは消えて見えた。
    It '対応の記録は送る文面とは別に残る (送る欄に出ない)' {
        $t = (Invoke-Board $board ("/api/tasks/$mailId")).body.task
        [void] (Invoke-Board $board ("/api/tasks/$mailId") 'PATCH' @{ user_edited = '返信の下書き'; version = $t.version })
        $t = (Invoke-Board $board ("/api/tasks/$mailId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$mailId/done") 'POST' @{ text = '電話で伝えたので返信は不要'; version = $t.version }
        Assert-Equal 200 $r.status
        $after = (Invoke-Board $board ("/api/tasks/$mailId")).body.task
        Assert-Equal '電話で伝えたので返信は不要' $after.user_record
        Assert-Equal '返信の下書き' $after.user_edited
    }
}

Describe '返信先の内容' {

    # 送る前にいちばん要るのは「相手が何と言ってきたか」。文字列のまま画面に
    # 渡すと、形を知っている場所がサーバと画面の2つに増える。ここで割る。
    It 'メールは差出人・宛先・日時と本文に割れる' {
        $c = @((Invoke-Board $board ("/api/tasks/$mailId")).body.conversation)
        Assert-Equal 1 $c.Count
        Assert-Match 'tanaka@example.com' ([string] $c[0].from)
        Assert-Equal 'me@example.com' ([string] $c[0].to)
        Assert-Equal 'keiri@example.com' ([string] $c[0].cc)
        Assert-Match '請求書をお送りします' ([string] $c[0].text)
        # 見出しは本文に混ぜない
        Assert-True (([string] $c[0].text) -notmatch '差出人:')
    }

    It 'Slack はスレッドの発言ごとに割れる' {
        $c = @((Invoke-Board $board ("/api/tasks/$slackId")).body.conversation)
        Assert-Equal 3 $c.Count
        Assert-Equal '佐藤' ([string] $c[1].from)
        Assert-Equal '鈴木' ([string] $c[2].from)
        # 「--- スレッド全文 (2 件) ---」は見出しであって発言ではない
        Assert-True (([string] $c[0].text) -notmatch 'スレッド全文')
    }

    It '元の通知が無いカードは空になる' {
        Assert-Equal 0 @((Invoke-Board $board ("/api/tasks/$todoId")).body.conversation).Count
    }
}

Describe '作業フォルダ' {

    # 成果物が要るカードはファイルを触ることになる。開く先はサーバが
    # DB の記録から決める (画面からパスは受け取らない)。
    It '成果物のあるカードはフォルダの場所が返る' {
        $d = (Invoke-Board $board ("/api/tasks/$artId")).body
        Assert-NotNull $d.workspace
        Assert-Match 'task-0099' ([string] $d.workspace)
    }

    It '作業フォルダの無いカードは場所も返らず、開けない (404)' {
        Assert-Null (Invoke-Board $board ("/api/tasks/$todoId")).body.workspace
        Assert-Equal 404 (Invoke-Board $board ("/api/tasks/$todoId/folder") 'POST' @{}).status
    }
}

Describe '編集' {

    It '編集欄を保存できる' {
        $t = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$todoId") 'PATCH' @{ user_edited = 'あとで書き足す'; version = $t.version }
        Assert-Equal 200 $r.status
        Assert-Equal 'あとで書き足す' (Invoke-Board $board ("/api/tasks/$todoId")).body.task.user_edited
    }

    It '対応の記録だけを保存しても、送る文面は変わらない' {
        $t = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        $r = Invoke-Board $board ("/api/tasks/$todoId") 'PATCH' @{ user_record = '途中までやった'; version = $t.version }
        Assert-Equal 200 $r.status
        $after = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        Assert-Equal '途中までやった' $after.user_record
        Assert-Equal 'あとで書き足す' $after.user_edited
    }

    It '触れる列は決まっている (列の移動は move の仕事)' {
        $t = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        [void] (Invoke-Board $board ("/api/tasks/$todoId") 'PATCH' @{ board_column = 'done'; agent_output = '偽の報告'; version = $t.version })
        $after = (Invoke-Board $board ("/api/tasks/$todoId")).body.task
        Assert-Equal 'todo' $after.board_column
        Assert-Null $after.agent_output
    }

    It 'コメントを足せる (ワーカーへの指示になる)' {
        $r = Invoke-Board $board ("/api/tasks/$todoId/comment") 'POST' @{ body = '丁寧めの文面で' }
        Assert-Equal 200 $r.status
        $c = @((Invoke-Board $board ("/api/tasks/$todoId")).body.comments)
        Assert-Equal 1 $c.Count
        Assert-Equal 'user' $c[0].author
    }

    It '空のコメントは受け付けない' {
        Assert-Equal 400 (Invoke-Board $board ("/api/tasks/$todoId/comment") 'POST' @{ body = '' }).status
    }

    It '指示を送るとレビュー待ちのカードは要対応に戻る (やり直してほしい、の意思表示)' {
        $r = Invoke-Board $board ("/api/tasks/$reworkId/comment") 'POST' @{ body = '宛名を直してやり直して' }
        Assert-Equal 200 $r.status
        Assert-Equal 'todo' $r.body.column
        Assert-Equal 'todo' (Invoke-Board $board ("/api/tasks/$reworkId")).body.task.board_column
    }

    It '実行中のカードに指示を送っても列は動かさない (終わってからワーカーが戻す)' {
        $r = Invoke-Board $board ("/api/tasks/$doingId/comment") 'POST' @{ body = '途中で追加の指示' }
        Assert-Equal 200 $r.status
        Assert-Equal 'doing' $r.body.column
        $t = (Invoke-Board $board ("/api/tasks/$doingId")).body.task
        Assert-Equal 'doing' $t.board_column
        Assert-Equal 0 ([int] $t.cancel_requested)
    }

    It '差し戻しは既定で会話を残す (ワーカーは続きから直す)' {
        $c = Open-TaskStore -Path $dbPath
        try { Save-TaskSession -Conn $c -TaskId $slackId -MessagesJson '{"messages":[]}' } finally { $c.Dispose() }
        Assert-Equal 200 (Invoke-Board $board ("/api/tasks/$slackId/comment") 'POST' @{ body = '直して' }).status
        $c = Open-TaskStore -Path $dbPath
        try { Assert-NotNull (Get-TaskSession -Conn $c -TaskId $slackId) } finally { $c.Dispose() }
    }

    It '「最初からやり直す」を選ぶと会話を捨てる' {
        $c = Open-TaskStore -Path $dbPath
        try { Save-TaskSession -Conn $c -TaskId $mailId -MessagesJson '{"messages":[]}' } finally { $c.Dispose() }
        $r = Invoke-Board $board ("/api/tasks/$mailId/comment") 'POST' @{ body = '前提が違う。やり直して'; restart = $true }
        Assert-Equal 200 $r.status
        Assert-Equal 'todo' $r.body.column
        $c = Open-TaskStore -Path $dbPath
        try { Assert-Null (Get-TaskSession -Conn $c -TaskId $mailId) } finally { $c.Dispose() }
    }

    It 'カードを手で起票できる' {
        $r = Invoke-Board $board '/api/tasks' 'POST' @{ title = '手で作ったカード' }
        Assert-Equal 200 $r.status
        Assert-NotNull $r.body.id
    }

    It '題の無いカードは作れない' {
        Assert-Equal 400 (Invoke-Board $board '/api/tasks' 'POST' @{ summary = '題が無い' }).status
    }
}

Describe 'まとめて削除' {

    It 'いまその列にあるカードだけを消す' {
        # 完了に1枚 (doneId) と、さっき完了にした reviewId がある。
        # todo のカードの id を混ぜても巻き込まれないこと。
        $r = Invoke-Board $board '/api/tasks/bulk-delete' 'POST' @{ column = 'done'; ids = @($doneId, $todoId) }
        Assert-Equal 200 $r.status
        Assert-Equal 1 $r.body.deleted
        Assert-Equal 1 $r.body.skipped
        Assert-Equal 200 (Invoke-Board $board ("/api/tasks/$todoId")).status
    }

    It '知らない列は受け付けない' {
        Assert-Equal 400 (Invoke-Board $board '/api/tasks/bulk-delete' 'POST' @{ column = 'どこか'; ids = @(1) }).status
    }
}

Describe '外から叩かれたとき' {

    It '別サイトからの POST は Origin で弾く' {
        $r = Invoke-Board $board ("/api/tasks/$todoId/comment") 'POST' @{ body = '外から' } `
                @{ Origin = 'https://evil.example' }
        Assert-Equal 403 $r.status
    }

    It '同じ PC の別のローカルサーバからの POST も弾く' {
        # 「localhost なら通す」にすると、開発サーバや他のアプリのローカル UI が
        # 出したページから、この画面の操作を起こせてしまう。
        $r = Invoke-Board $board ("/api/tasks/$todoId/comment") 'POST' @{ body = '隣のポートから' } `
                @{ Origin = ('http://localhost:' + ($board.port + 1)) }
        Assert-Equal 403 $r.status
    }

    It '自分自身からの POST は通る' {
        $r = Invoke-Board $board ("/api/tasks/$todoId/comment") 'POST' @{ body = '画面から' } `
                @{ Origin = $board.base }
        Assert-Equal 200 $r.status
    }

    It '別名で来た要求は弾く (DNS リバインディング対策)' {
        # 実際には二重になっている。HttpListener は 127.0.0.1 / localhost の
        # プレフィックスしか持たないので、知らない Host はそこで 404 になる。
        # ボード側の Host 検査は、それを通り抜けたときのための二枚目。
        # どちらで弾かれたかは問わず、「通らないこと」を見る。
        $code = Invoke-RawRequest $board 'evil.example'
        Assert-True (@(400, 404) -contains $code) ("状態コードが {0} でした" -f $code)
    }

    It '自分自身の名前なら通る (弾き方が雑になっていないか)' {
        Assert-Equal 200 (Invoke-RawRequest $board ('127.0.0.1:' + $board.port))
        Assert-Equal 200 (Invoke-RawRequest $board ('localhost:' + $board.port))
    }

    It '静的ファイルは wwwroot の外に出られない' {
        $r = Invoke-Board $board '/../../phase5/data/secrets.dat'
        Assert-True (@(403, 404) -contains $r.status) ("状態コードが {0} でした" -f $r.status)
    }

    It '画面そのものは返る' {
        $r = Invoke-Board $board '/'
        Assert-Equal 200 $r.status
        Assert-Match '通知カンバン' $r.text
    }
}

Describe '覚えていること' {

    # 覚えたことは指示が無くても次から効く。間違って覚えたものを画面から
    # 消せなければ、一度の言い間違いが延々と渡り続ける。

    It '一覧が返る' {
        $c = Open-TaskStore -Path $board.db
        [void] (Add-MemoryNote -Conn $c -Kind 'preference' -Topic '請求書' -Note '請求書は送らずに下書きまででよい')
        $c.Dispose()
        $r = Invoke-Board $board '/api/memory'
        Assert-Equal 200 $r.status
        $hit = @($r.body.memories | Where-Object { $_.topic -eq '請求書' })
        Assert-Equal 1 $hit.Count
        Assert-Match '下書き' $hit[0].note
        Assert-NotNull $hit[0].label
    }

    It '消せる' {
        $r = Invoke-Board $board '/api/memory'
        $id = @($r.body.memories | Where-Object { $_.topic -eq '請求書' })[0].id
        Assert-Equal 200 (Invoke-Board $board ("/api/memory/{0}" -f $id) 'DELETE').status
        $after = Invoke-Board $board '/api/memory'
        Assert-Equal 0 (@($after.body.memories | Where-Object { $_.topic -eq '請求書' })).Count
    }

    It '無い記憶を消そうとしたら 404' {
        Assert-Equal 404 (Invoke-Board $board '/api/memory/999999' 'DELETE').status
    }
}

Describe '承認' {

    It '承認待ちの一覧が返る' {
        $r = Invoke-Board $board '/api/approvals'
        Assert-Equal 200 $r.status
        Assert-Equal 0 (@($r.body.pending)).Count
        Assert-False $r.body.yolo
    }

    It '無い承認を決着させようとしたら 404' {
        Assert-Equal 404 (Invoke-Board $board '/api/approvals/999/decide' 'POST' @{ decision = 'approved' }).status
    }

    It '同じ承認は二度決着しない' {
        $c = Open-TaskStore -Path $board.db
        $reqId = [int] (New-ToolRequest -Conn $c -TaskId $todoId -Tool 'run_command' -Summary 'テスト' -Detail '詳細')
        $c.Dispose()
        Assert-Equal 200 (Invoke-Board $board "/api/approvals/$reqId/decide" 'POST' @{ decision = 'denied' }).status
        Assert-Equal 409 (Invoke-Board $board "/api/approvals/$reqId/decide" 'POST' @{ decision = 'approved' }).status
    }

    It 'YOLO は切り替えられる (既定は OFF)' {
        Assert-True (Invoke-Board $board '/api/settings/yolo' 'POST' @{ on = $true }).body.yolo
        Assert-False (Invoke-Board $board '/api/settings/yolo' 'POST' @{ on = $false }).body.yolo
    }
}

}
finally { Stop-TestBoard $board }
