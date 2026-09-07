# TaskStore.ps1
# イベントとタスクを保持する SQLite ストア。
#
# 設計方針:
#  - events はイベントソース。同じ通知を何度取り込んでも UNIQUE で弾く (冪等)。
#  - tasks はカンバンの1枚のカード。1イベント1タスク。
#  - version / cancel_requested / agent_lease_until は Phase 3 の割り込み制御用。
#    エージェントが書き戻すときに version を照合し、ユーザー編集を踏み潰さないため。
#  - agent_output と user_edited を分けているのも同じ理由。エージェントが再生成しても
#    ユーザーが直した内容は残る。

. "$PSScriptRoot\..\..\lib\WinSqlite.ps1"

$script:Schema = @'
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS events (
  id           TEXT PRIMARY KEY,
  source       TEXT NOT NULL,
  source_key   TEXT NOT NULL,
  app          TEXT,
  app_id       TEXT,
  occurred_at  TEXT,
  ingested_at  TEXT NOT NULL,
  title        TEXT,
  body         TEXT,
  link         TEXT,
  raw_json     TEXT,
  UNIQUE(source, source_key)
);
CREATE INDEX IF NOT EXISTS idx_events_occurred ON events(occurred_at);

CREATE TABLE IF NOT EXISTS tasks (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id          TEXT,
  board_column      TEXT NOT NULL DEFAULT 'inbox',
  title             TEXT NOT NULL,
  summary           TEXT,
  needs_action      INTEGER,
  urgency           TEXT,
  category          TEXT,
  reason            TEXT,
  proposed_actions  TEXT,
  agent_output      TEXT,
  user_edited       TEXT,
  version           INTEGER NOT NULL DEFAULT 1,
  cancel_requested  INTEGER NOT NULL DEFAULT 0,
  agent_lease_until TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL,
  FOREIGN KEY(event_id) REFERENCES events(id)
);
-- 1イベントにつきカードは1枚。取り込みを繰り返しても増殖しない。
CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_event ON tasks(event_id);
CREATE INDEX IF NOT EXISTS idx_tasks_column ON tasks(board_column);

CREATE TABLE IF NOT EXISTS task_comments (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id     INTEGER NOT NULL,
  author      TEXT NOT NULL,
  body        TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  consumed_at TEXT,
  FOREIGN KEY(task_id) REFERENCES tasks(id)
);

-- 判定の履歴。ルールで捨てたものも含めて残し、方針調整の材料にする。
CREATE TABLE IF NOT EXISTS triage_log (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id     TEXT NOT NULL,
  decided_by   TEXT NOT NULL,
  rule_name    TEXT,
  model        TEXT,
  needs_action INTEGER,
  raw_response TEXT,
  created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_triage_event ON triage_log(event_id);

-- ワーカーが「いま何をしているか」を残す。カードごとの作業ログ。
CREATE TABLE IF NOT EXISTS task_activity (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id    INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  kind       TEXT NOT NULL,
  message    TEXT NOT NULL,
  FOREIGN KEY(task_id) REFERENCES tasks(id)
);
CREATE INDEX IF NOT EXISTS idx_activity_task ON task_activity(task_id, id);

-- ワーカーが実際に作ったファイル。
CREATE TABLE IF NOT EXISTS task_artifacts (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id    INTEGER NOT NULL,
  path       TEXT NOT NULL,
  name       TEXT NOT NULL,
  bytes      INTEGER,
  created_at TEXT NOT NULL,
  UNIQUE(task_id, path),
  FOREIGN KEY(task_id) REFERENCES tasks(id)
);

-- ツール実行の承認要求。ワーカーが止まって利用者の判断を待つ。
CREATE TABLE IF NOT EXISTS tool_requests (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id    INTEGER NOT NULL,
  tool       TEXT NOT NULL,
  summary    TEXT NOT NULL,
  detail     TEXT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'pending',
  decided_at TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY(task_id) REFERENCES tasks(id)
);
CREATE INDEX IF NOT EXISTS idx_toolreq_status ON tool_requests(status, id);

-- まとめて許可。scope は 'task' か 'global'。
CREATE TABLE IF NOT EXISTS tool_grants (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  scope      TEXT NOT NULL,
  scope_id   INTEGER,
  tool       TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(scope, scope_id, tool)
);

CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- ワーカーの生存確認と現在の作業。1行だけ持つ。
CREATE TABLE IF NOT EXISTS worker_state (
  id              INTEGER PRIMARY KEY CHECK (id = 1),
  state           TEXT NOT NULL,
  current_task_id INTEGER,
  message         TEXT,
  updated_at      TEXT NOT NULL
);
'@

# 既存 DB にも後から列を足せるようにする。CREATE TABLE IF NOT EXISTS では
# 列追加が反映されないため、PRAGMA で確認して ALTER する。
function Invoke-SchemaMigration {
    param([Parameter(Mandatory)] $Conn)
    $cols = @($Conn.Query('PRAGMA table_info(tasks)')) | ForEach-Object { $_['name'] }
    if ($cols -notcontains 'archived_at') {
        $Conn.Exec('ALTER TABLE tasks ADD COLUMN archived_at TEXT')
    }
    # 正規 API で本文を取り直したかの印 (Phase 5)
    $ecols = @($Conn.Query('PRAGMA table_info(events)')) | ForEach-Object { $_['name'] }
    if ($ecols -notcontains 'context_fetched') {
        $Conn.Exec('ALTER TABLE events ADD COLUMN context_fetched TEXT')
    }
}

function Get-Now { return (Get-Date).ToString('o') }

function Open-TaskStore {
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path $PSScriptRoot '..\data\tasks.db' }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $conn = New-Object WinSqlite.Conn ([IO.Path]::GetFullPath($Path))
    $conn.Exec($script:Schema)
    Invoke-SchemaMigration -Conn $conn
    return $conn
}

# 通知1件を events に入れる。既に入っていれば何もしない。
# 戻り値: @{ id; isNew }
function Add-Event {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $SourceKey,
        [string] $App, [string] $AppId, [string] $OccurredAt,
        [string] $Title, [string] $Body, [string] $Link, [string] $RawJson
    )
    $id = "$Source|$SourceKey"
    $changed = $Conn.NonQuery(
        'INSERT OR IGNORE INTO events (id, source, source_key, app, app_id, occurred_at, ingested_at, title, body, link, raw_json)
         VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        [object[]] @($id, $Source, $SourceKey, $App, $AppId, $OccurredAt, (Get-Now), $Title, $Body, $Link, $RawJson))
    return [pscustomobject]@{ id = $id; isNew = ($changed -gt 0) }
}

# まだ判定していないイベント (triage_log に記録が無いもの)
function Get-UntriagedEvents {
    param([Parameter(Mandatory)] $Conn, [int] $Limit = 100)
    return $Conn.Query(
        'SELECT e.* FROM events e
          WHERE NOT EXISTS (SELECT 1 FROM triage_log t WHERE t.event_id = e.id)
          ORDER BY e.occurred_at ASC
          LIMIT ?', [object[]] @($Limit))
}

function Add-TriageLog {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [string] $EventId,
        [Parameter(Mandatory)] [string] $DecidedBy,
        [string] $RuleName, [string] $Model, $NeedsAction, [string] $RawResponse
    )
    $na = if ($null -eq $NeedsAction) { $null } else { [int][bool] $NeedsAction }
    [void] $Conn.NonQuery(
        'INSERT INTO triage_log (event_id, decided_by, rule_name, model, needs_action, raw_response, created_at)
         VALUES (?,?,?,?,?,?,?)',
        [object[]] @($EventId, $DecidedBy, $RuleName, $Model, $na, $RawResponse, (Get-Now)))
}

function New-Task {
    param(
        [Parameter(Mandatory)] $Conn,
        [string] $EventId,
        [Parameter(Mandatory)] [string] $Title,
        [string] $Summary, $NeedsAction, [string] $Urgency, [string] $Category,
        [string] $Reason, [string] $ProposedActions, [string] $Column = 'inbox'
    )
    $now = Get-Now
    $na  = if ($null -eq $NeedsAction) { $null } else { [int][bool] $NeedsAction }
    $changed = $Conn.NonQuery(
        'INSERT OR IGNORE INTO tasks
           (event_id, board_column, title, summary, needs_action, urgency, category, reason, proposed_actions, created_at, updated_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        [object[]] @($EventId, $Column, $Title, $Summary, $na, $Urgency, $Category, $Reason, $ProposedActions, $now, $now))
    if ($changed -gt 0) { return $Conn.LastRowId }
    return $null
}

function Get-Tasks {
    param([Parameter(Mandatory)] $Conn, [string] $Column, [switch] $IncludeArchived)
    $where = if ($IncludeArchived) { '1=1' } else { 'archived_at IS NULL' }
    if ($Column) {
        return $Conn.Query("SELECT * FROM tasks WHERE $where AND board_column = ? ORDER BY updated_at DESC",
                           [object[]] @($Column))
    }
    return $Conn.Query("SELECT * FROM tasks WHERE $where ORDER BY board_column, updated_at DESC")
}

# 楽観ロック付きの列移動。ユーザーの操作とエージェントの書き戻しが衝突したら false を返す。
function Set-TaskColumn {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [int] $TaskId,
        [Parameter(Mandatory)] [string] $Column,
        [int] $ExpectedVersion = -1
    )
    if ($ExpectedVersion -ge 0) {
        $n = $Conn.NonQuery(
            'UPDATE tasks SET board_column = ?, version = version + 1, updated_at = ?
              WHERE id = ? AND version = ?',
            [object[]] @($Column, (Get-Now), $TaskId, $ExpectedVersion))
    } else {
        $n = $Conn.NonQuery(
            'UPDATE tasks SET board_column = ?, version = version + 1, updated_at = ? WHERE id = ?',
            [object[]] @($Column, (Get-Now), $TaskId))
    }
    return ($n -gt 0)
}

function Add-TaskComment {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [int] $TaskId,
        [Parameter(Mandatory)] [string] $Author,
        [Parameter(Mandatory)] [string] $Body
    )
    [void] $Conn.NonQuery(
        'INSERT INTO task_comments (task_id, author, body, created_at) VALUES (?,?,?,?)',
        [object[]] @($TaskId, $Author, $Body, (Get-Now)))
    return $Conn.LastRowId
}

# ---------------------------------------------------------------- UI (Phase 3) 用

# ボードが変化したかを安く判定するための版番号。UI はこれをポーリングし、
# 変わったときだけボード全体を取り直す。
function Get-BoardRevision {
    param([Parameter(Mandatory)] $Conn)
    $r = @($Conn.Query("SELECT COUNT(*) AS n, COALESCE(MAX(updated_at),'') AS m FROM tasks"))[0]
    $c = @($Conn.Query("SELECT COUNT(*) AS n FROM task_comments"))[0]
    # ワーカーの動きでも UI が更新されるよう、作業ログと死活も版に含める。
    # ただし死活の updated_at は含めない。待機中のハートビートが 5 秒ごとに
    # 版を変え、ボード全体の再取得が延々と走ってしまうため。
    $a = @($Conn.Query("SELECT COUNT(*) AS n FROM task_activity"))[0]
    $f = @($Conn.Query("SELECT COUNT(*) AS n FROM task_artifacts"))[0]
    # 承認待ちは即座に画面へ出したいので版に含める
    $q = @($Conn.Query("SELECT COUNT(*) AS n FROM tool_requests WHERE status='pending'"))[0]
    $w = @($Conn.Query("SELECT COALESCE(state,'') || '/' || COALESCE(current_task_id,'') AS s FROM worker_state WHERE id=1"))
    $ws = if ($w.Count -gt 0) { $w[0]['s'] } else { '' }
    return ("{0}-{1}-{2}-{3}-{4}-{5}-{6}" -f $r['n'], $r['m'], $c['n'], $a['n'], $f['n'], $q['n'], $ws)
}

# ---------------------------------------------------------------- 作業ログ / ワーカー死活

function Add-TaskActivity {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [int] $TaskId,
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [string] $Message
    )
    [void] $Conn.NonQuery(
        'INSERT INTO task_activity (task_id, created_at, kind, message) VALUES (?,?,?,?)',
        [object[]] @($TaskId, (Get-Now), $Kind, $Message))
}

function Get-TaskActivity {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId, [int] $Limit = 50)
    return $Conn.Query(
        'SELECT * FROM (SELECT * FROM task_activity WHERE task_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id ASC',
        [object[]] @($TaskId, $Limit))
}

# ---------------------------------------------------------------- 権限 (ツール実行の承認)

function Get-Setting {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [string] $Key, [string] $Default)
    $r = @($Conn.Query('SELECT value FROM settings WHERE key = ?', [object[]] @($Key)))
    if ($r.Count -eq 0) { return $Default }
    return [string] $r[0]['value']
}

function Set-Setting {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [string] $Key, [Parameter(Mandatory)] [string] $Value)
    [void] $Conn.NonQuery(
        'INSERT INTO settings (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [object[]] @($Key, $Value))
}

# YOLO: すべてのツール実行を承認なしで通す
function Test-YoloMode {
    param([Parameter(Mandatory)] $Conn)
    return ((Get-Setting -Conn $Conn -Key 'yolo' -Default '0') -eq '1')
}

function Test-ToolGranted {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId, [Parameter(Mandatory)] [string] $Tool)
    $r = @($Conn.Query(
        "SELECT 1 AS x FROM tool_grants
          WHERE tool = ? AND (scope = 'global' OR (scope = 'task' AND scope_id = ?)) LIMIT 1",
        [object[]] @($Tool, $TaskId)))
    return ($r.Count -gt 0)
}

function Add-ToolGrant {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [ValidateSet('task', 'global')] [string] $Scope,
        $ScopeId,
        [Parameter(Mandatory)] [string] $Tool
    )
    [void] $Conn.NonQuery(
        'INSERT OR IGNORE INTO tool_grants (scope, scope_id, tool, created_at) VALUES (?,?,?,?)',
        [object[]] @($Scope, $ScopeId, $Tool, (Get-Now)))
}

function Get-ToolGrants {
    param([Parameter(Mandatory)] $Conn)
    return $Conn.Query('SELECT * FROM tool_grants ORDER BY id ASC')
}

function Remove-ToolGrant {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $GrantId)
    return ($Conn.NonQuery('DELETE FROM tool_grants WHERE id = ?', [object[]] @($GrantId)) -gt 0)
}

function New-ToolRequest {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [int] $TaskId,
        [Parameter(Mandatory)] [string] $Tool,
        [Parameter(Mandatory)] [string] $Summary,
        [Parameter(Mandatory)] [string] $Detail
    )
    [void] $Conn.NonQuery(
        'INSERT INTO tool_requests (task_id, tool, summary, detail, status, created_at) VALUES (?,?,?,?,?,?)',
        [object[]] @($TaskId, $Tool, $Summary, $Detail, 'pending', (Get-Now)))
    return $Conn.LastRowId
}

function Get-ToolRequest {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $RequestId)
    $r = @($Conn.Query('SELECT * FROM tool_requests WHERE id = ?', [object[]] @($RequestId)))
    if ($r.Count -eq 0) { return $null }
    return $r[0]
}

function Get-PendingToolRequests {
    param([Parameter(Mandatory)] $Conn)
    return $Conn.Query("SELECT * FROM tool_requests WHERE status = 'pending' ORDER BY id ASC")
}

function Set-ToolRequestStatus {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [int] $RequestId,
        [Parameter(Mandatory)] [ValidateSet('approved', 'denied', 'expired')] [string] $Status
    )
    return ($Conn.NonQuery(
        "UPDATE tool_requests SET status = ?, decided_at = ? WHERE id = ? AND status = 'pending'",
        [object[]] @($Status, (Get-Now), $RequestId)) -gt 0)
}

function Add-TaskArtifact {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [int] $TaskId,
        [Parameter(Mandatory)] [string] $Path
    )
    $name = Split-Path -Leaf $Path
    $len = 0
    try { $len = (Get-Item -LiteralPath $Path).Length } catch { }
    # 上書き生成もあるので、同じパスなら差し替える
    [void] $Conn.NonQuery(
        'INSERT INTO task_artifacts (task_id, path, name, bytes, created_at) VALUES (?,?,?,?,?)
         ON CONFLICT(task_id, path) DO UPDATE SET bytes=excluded.bytes, created_at=excluded.created_at',
        [object[]] @($TaskId, $Path, $name, $len, (Get-Now)))
}

function Get-TaskArtifacts {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId)
    return $Conn.Query('SELECT * FROM task_artifacts WHERE task_id = ? ORDER BY id ASC', [object[]] @($TaskId))
}

# 直近で連続して失敗した回数。成功 (done) が出たらそこで打ち切る。
# 恒久的な失敗 (残高不足・キー不正など) でカードを拾い続けないための判断材料。
function Get-ConsecutiveFailures {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId)
    $rows = @($Conn.Query(
        'SELECT kind FROM task_activity WHERE task_id = ? ORDER BY id DESC LIMIT 30', [object[]] @($TaskId)))
    $n = 0
    foreach ($r in $rows) {
        if ($r['kind'] -eq 'error') { $n++ }
        elseif ($r['kind'] -eq 'done') { break }
    }
    return $n
}

function Set-WorkerState {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [string] $State,
        $CurrentTaskId, [string] $Message
    )
    [void] $Conn.NonQuery(
        'INSERT INTO worker_state (id, state, current_task_id, message, updated_at) VALUES (1,?,?,?,?)
         ON CONFLICT(id) DO UPDATE SET state=excluded.state, current_task_id=excluded.current_task_id,
                                       message=excluded.message, updated_at=excluded.updated_at',
        [object[]] @($State, $CurrentTaskId, $Message, (Get-Now)))
}

function Get-WorkerState {
    param([Parameter(Mandatory)] $Conn)
    $r = @($Conn.Query('SELECT * FROM worker_state WHERE id = 1'))
    if ($r.Count -eq 0) { return $null }
    return $r[0]
}

# ---------------------------------------------------------------- アーカイブ / 削除

function Set-TaskArchived {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId, [bool] $Archived = $true)
    $val = if ($Archived) { Get-Now } else { $null }
    return ($Conn.NonQuery(
        'UPDATE tasks SET archived_at = ?, version = version + 1, updated_at = ? WHERE id = ?',
        [object[]] @($val, (Get-Now), $TaskId)) -gt 0)
}

# 完全削除。カードを参照している行をすべて先に消す。
# 外部キーを張っているテーブルを1つでも取りこぼすと FOREIGN KEY constraint failed で
# 削除自体が失敗する。テーブルを増やしたらここにも足すこと。
# 作業フォルダのファイルは消さない (取り戻せなくなるため)。
# events も残す (再取り込みで復活させないための冪等キーとして必要)。
function Remove-Task {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId)
    $Conn.Begin()
    try {
        [void] $Conn.NonQuery('DELETE FROM task_activity WHERE task_id = ?',  [object[]] @($TaskId))
        [void] $Conn.NonQuery('DELETE FROM task_comments WHERE task_id = ?',  [object[]] @($TaskId))
        [void] $Conn.NonQuery('DELETE FROM task_artifacts WHERE task_id = ?', [object[]] @($TaskId))
        [void] $Conn.NonQuery('DELETE FROM tool_requests WHERE task_id = ?',  [object[]] @($TaskId))
        # 外部キーではないが、残すと消えたカード向けの許可が居座る
        [void] $Conn.NonQuery("DELETE FROM tool_grants WHERE scope = 'task' AND scope_id = ?", [object[]] @($TaskId))
        $n = $Conn.NonQuery('DELETE FROM tasks WHERE id = ?', [object[]] @($TaskId))
        $Conn.Commit()
        return ($n -gt 0)
    }
    catch { $Conn.Rollback(); throw }
}

# ---------------------------------------------------------------- ワーカー用

# ユーザーが書いたまだ読んでいない指示。ワーカーは各実行の前にこれを読む。
function Get-UnconsumedComments {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId)
    return $Conn.Query(
        "SELECT * FROM task_comments WHERE task_id = ? AND author = 'user' AND consumed_at IS NULL ORDER BY id ASC",
        [object[]] @($TaskId))
}

function Set-CommentsConsumed {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId)
    [void] $Conn.NonQuery(
        'UPDATE task_comments SET consumed_at = ? WHERE task_id = ? AND consumed_at IS NULL',
        [object[]] @((Get-Now), $TaskId))
}

# 中止要求が立っているか (ワーカーが各ステップの前に確認する)
function Test-TaskCancelled {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId)
    $r = @($Conn.Query('SELECT cancel_requested FROM tasks WHERE id = ?', [object[]] @($TaskId)))
    if ($r.Count -eq 0) { return $true }
    return ([int] $r[0]['cancel_requested'] -ne 0)
}

# 未処理のカードを1枚取り、リースを張って doing に移す。
# 戻り値: 取れたカード、なければ $null。
function Get-NextWorkItem {
    param([Parameter(Mandatory)] $Conn, [int] $LeaseMinutes = 10)
    $now = Get-Now
    $Conn.Begin()
    try {
        # リース切れの doing も回収対象に含める (ワーカーが落ちた場合の復旧)
        $rows = @($Conn.Query(
            "SELECT * FROM tasks
              WHERE archived_at IS NULL AND cancel_requested = 0
                AND (board_column = 'todo'
                     OR (board_column = 'doing' AND (agent_lease_until IS NULL OR agent_lease_until < ?)))
              ORDER BY CASE urgency WHEN 'high' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END, id ASC
              LIMIT 1", [object[]] @($now)))
        if ($rows.Count -eq 0) { $Conn.Commit(); return $null }

        $t = $rows[0]
        $lease = (Get-Date).AddMinutes($LeaseMinutes).ToString('o')
        $n = $Conn.NonQuery(
            "UPDATE tasks SET board_column='doing', agent_lease_until=?, version=version+1, updated_at=?
              WHERE id = ? AND version = ?",
            [object[]] @($lease, $now, $t['id'], $t['version']))
        $Conn.Commit()
        if ($n -eq 0) { return $null }   # 直前にユーザーが動かした
        return $t
    }
    catch { $Conn.Rollback(); throw }
}

function Get-TaskDetail {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId)
    $rows = @($Conn.Query('SELECT * FROM tasks WHERE id = ?', [object[]] @($TaskId)))
    if ($rows.Count -eq 0) { return $null }
    $task = $rows[0]

    $comments = @($Conn.Query(
        'SELECT * FROM task_comments WHERE task_id = ? ORDER BY created_at ASC', [object[]] @($TaskId)))

    $ev = $null
    if ($task['event_id']) {
        $er = @($Conn.Query('SELECT * FROM events WHERE id = ?', [object[]] @($task['event_id'])))
        if ($er.Count -gt 0) { $ev = $er[0] }
    }
    return [pscustomobject]@{ task = $task; comments = $comments; event = $ev }
}

# 更新できるカラムはホワイトリストで固定する。キーを SQL に埋めるため、
# 呼び出し側の入力をそのまま通してはいけない。
$script:UpdatableFields = @('title', 'summary', 'urgency', 'category', 'user_edited', 'agent_output')

function Update-TaskFields {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [int] $TaskId,
        [Parameter(Mandatory)] [hashtable] $Fields,
        [int] $ExpectedVersion = -1
    )
    $sets = @()
    $vals = @()
    foreach ($k in $Fields.Keys) {
        if ($script:UpdatableFields -notcontains $k) { continue }
        $sets += "$k = ?"
        $vals += $Fields[$k]
    }
    if ($sets.Count -eq 0) { return $false }

    $sets += 'version = version + 1'
    $sets += 'updated_at = ?'
    $vals += (Get-Now)
    $vals += $TaskId

    $sql = 'UPDATE tasks SET ' + ($sets -join ', ') + ' WHERE id = ?'
    if ($ExpectedVersion -ge 0) {
        $sql += ' AND version = ?'
        $vals += $ExpectedVersion
    }
    return ($Conn.NonQuery($sql, [object[]] $vals) -gt 0)
}

# ユーザーがカードを doing から動かした / 中止を押したときに立てる。
# 実際の停止は Phase 4 のワーカーがこのフラグを見て行う。
function Set-TaskCancel {
    param([Parameter(Mandatory)] $Conn, [Parameter(Mandatory)] [int] $TaskId, [bool] $Requested = $true)
    return ($Conn.NonQuery(
        'UPDATE tasks SET cancel_requested = ?, version = version + 1, updated_at = ? WHERE id = ?',
        [object[]] @([int] $Requested, (Get-Now), $TaskId)) -gt 0)
}

# ユーザーが手で起票したカード (通知に紐づかない)
function New-UserTask {
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [string] $Title,
        [string] $Summary, [string] $Column = 'todo', [string] $Urgency = 'normal'
    )
    $now = Get-Now
    [void] $Conn.NonQuery(
        'INSERT INTO tasks (event_id, board_column, title, summary, needs_action, urgency, category, created_at, updated_at)
         VALUES (NULL,?,?,?,1,?,?,?,?)',
        [object[]] @($Column, $Title, $Summary, $Urgency, 'user', $now, $now))
    return $Conn.LastRowId
}
