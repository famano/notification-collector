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
'@

function Get-Now { return (Get-Date).ToString('o') }

function Open-TaskStore {
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path $PSScriptRoot '..\data\tasks.db' }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $conn = New-Object WinSqlite.Conn ([IO.Path]::GetFullPath($Path))
    $conn.Exec($script:Schema)
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
    param([Parameter(Mandatory)] $Conn, [string] $Column)
    if ($Column) {
        return $Conn.Query('SELECT * FROM tasks WHERE board_column = ? ORDER BY updated_at DESC', [object[]] @($Column))
    }
    return $Conn.Query('SELECT * FROM tasks ORDER BY board_column, updated_at DESC')
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
    return ("{0}-{1}-{2}" -f $r['n'], $r['m'], $c['n'])
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
