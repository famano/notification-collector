# WinSqlite — Windows 同梱の SQLite を P/Invoke する

`lib/WinSqlite.ps1` (295 行)

このアプリが**追加インストールを一切要求しない**ことの土台。
Windows 10 1803 以降に同梱されている `winsqlite3.dll` を直接叩く。

> Python も Node も .NET SDK も、SQLite の NuGet パッケージも要らない。
> **配った先の PC で `Start.cmd` をダブルクリックすれば動く**という前提は、
> ここと `HttpListener` (phase3) の2つで成り立っている。

---

## 1. 役割と境界

| | |
|---|---|
| 担う | `winsqlite3.dll` の P/Invoke 宣言 / 接続 / パラメータバインド / 行の取り出し / トランザクション / 通知 DB のスナップショット |
| 担わない | スキーマ (`TaskStore`) / 業務の意味 / 接続の使い回し方 |

依存は無い。**このファイルは誰も知らない。**

**依存元**: `TaskStore.ps1` (経由でほぼ全プロセス) と `phase1/Get-Notifications.ps1`。

---

## 2. 作り

```
WinSqlite.Native   DllImport の宣言だけ。sqlite3_* の薄い写し
WinSqlite.Conn     接続1本。IDisposable
WinSqlite.Db       使い捨ての単発クエリ (phase1 の読み取り用)
```

C# のソースを `Add-Type` でその場でコンパイルする。
**二重定義を避けるため `if (-not ('WinSqlite.Conn' -as [type]))` で囲ってある** ――
このファイルは複数の場所から `.` で読み込まれ、PowerShell のセッションでは
同じ型を二度足せない。

### `Conn` が提供するもの

| | |
|---|---|
| `Exec(sql)` | **複文をまとめて流す** (スキーマ定義)。パラメータは使えない |
| `Query(sql[, ps])` | `List<Dictionary<string, object>>` を返す |
| `NonQuery(sql[, ps])` | 変更された行数を返す |
| `LastRowId` | `sqlite3_last_insert_rowid` |
| `Begin()` / `Commit()` / `Rollback()` | `BEGIN IMMEDIATE` で始める |

`Begin()` が `BEGIN IMMEDIATE` なのは、**書くつもりの取引を最初から書き手として始める**ため。
遅延で始めると、後から書き込もうとした時点でロックが取れず、
`SQLITE_BUSY` が取引の途中で出る。

### 型の対応

| PowerShell / .NET | SQLite |
|---|---|
| `byte[]` | BLOB |
| `bool` / `int` / `long` / `short` | INTEGER |
| `double` / `float` / `decimal` | REAL |
| `DateTime` | **`"o"` 書式の文字列** |
| `null` / `DBNull` | NULL |
| その他 | `ToString()` した文字列 |

`DateTime` を文字列にするのは、DB の中で**全部の時刻を同じ形にする**ため
(`TaskStore` の `Get-Now` も `.ToString('o')`)。
SQLite に日時型は無いので、揃えないと比較 (`julianday` や文字列比較) が壊れる。

読む側は `sqlite3_column_type` を見て `long` / `double` / `string` / `byte[]` / `null` に振り分ける。
**型は列の宣言ではなく値ごとに決まる** (SQLite の型親和性) ので、
呼ぶ側は `[int]` `[string]` で明示的にキャストしている。

---

## 3. 同時に触ることへの備え

```
Native.busy_timeout(db, 5000);   // UI と worker が同時に触るので待たせる
```

このアプリは常時3プロセス (収集・ワーカー・カンバン) が同じ `tasks.db` を開く。
**5秒待つ**のは、その間にたいていの単文は終わるから。
超えると `SQLITE_BUSY` が例外になり、呼ぶ側 (ワーカーの主ループ) が
作業ログに残して次の周回に回す。

WAL は `TaskStore` 側の `PRAGMA journal_mode=WAL` で入れている
(**読みが書きを止めない**ので、カンバンのポーリングがワーカーを妨げない)。

---

## 4. 通知 DB のスナップショット

```
New-WpnSnapshot     wpndatabase.db / -wal / -shm を一時フォルダにコピーして、そのパスを返す
Remove-WpnSnapshot  後始末 (呼ぶ側の責任)
```

**原本はサービスが掴んでいる**ので直接は開けない。
`-wal` と `-shm` も一緒にコピーするのが要点 ―― `.db` だけコピーすると、
**まだ WAL にしかない最新の通知が落ちる** (つまり一番読みたいものが無い)。

読み取り専用で開く口 (`Conn(path, readOnly)` / `Db.Query`) はこのために残してある。

---

## 5. 不変条件

| # | 守っていること | 担保 | 破れたときの症状 |
|---|---|---|---|
| 1 | 型を二度足さない | `-as [type]` のガード | 読み込むたびに `Add-Type` が落ちる |
| 2 | ステートメントは必ず解放する | `finally { finalize(stmt) }` | ハンドルが漏れ、最後は DB を閉じられない |
| 3 | バインドに失敗しても解放する | `Prepare` の `catch` で `finalize` | 同上 |
| 4 | 値のコピーは SQLite に任せる | `SQLITE_TRANSIENT` | `byte[]` の寿命次第で**中身が化ける** |
| 5 | 時刻は `"o"` 書式の文字列 | `Bind` の `DateTime` 分岐 | 比較と並べ替えが壊れる |
| 6 | 書く取引は `BEGIN IMMEDIATE` | `Begin()` | 取引の途中で `SQLITE_BUSY` |
| 7 | 通知 DB は `-wal` ごとコピーする | `New-WpnSnapshot` | **最新の通知が読めない** |
| 8 | 文字列は UTF-8 で往復する | `Utf8Z` / `FromUtf8` | 日本語が化ける |

4 は P/Invoke 特有で、**症状が出るのが遅い。**
`SQLITE_TRANSIENT` を渡すと SQLite 側が値をコピーするので、
マネージド側の `byte[]` が GC されても安全になる。

---

## 6. テスト

このファイル単体のテストは無い。`winsqlite3.dll` が要るので、
**Linux や DLL の無い環境では `Test-SqliteAvailable` がこけて、
DB を使うテストがまとめて `Skip-It` で飛ぶ** (`tests/lib/TestKit.ps1`)。

実質的には `tests/cases/TaskStore.Tests.ps1` をはじめとする DB 系のテストが、
ここを通して動作を確かめていることになる。

---

## 7. いま抱えている歪み

- **DLL の有無が、テストの通り方を静かに変える。** 飛んだテストは「成功」ではないが、
  まとめて飛ぶので合計だけを見ていると気付きにくい。
- **接続の使い回し方を規定していない。** 各プロセスが `Open-TaskStore` で1本ずつ持つ、
  という運用は `TaskStore` 側の慣習で、ここには何も書いていない。
- **例外がすべて `Exception`。** 呼ぶ側は `SQLITE_BUSY` と構文エラーを
  メッセージの文字列でしか見分けられない (いまは見分けていない)。
- **`Exec` はパラメータを取れない。** スキーマ定義専用として使っているので問題は
  出ていないが、うっかり値を埋め込む道が開いている。
