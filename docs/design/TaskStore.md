# TaskStore — イベントとカードの保管庫

`phase2/lib/TaskStore.ps1` (約 1,470 行)

常駐する3つのプロセス (収集・ワーカー・カンバン) が**唯一共有している状態**がここにある。
phase の README が「なぜそうするか」を書くのに対し、この文書は
**「どう出来ていて、触るときに何を壊しうるか」**を書く。

---

## 1. 役割と境界

| | |
|---|---|
| 担う | スキーマの定義と移行 / events・tasks とその周辺テーブルの読み書き / 同時実行の裁定 (楽観ロック・リース) / 通知と同期の同一性の計算 |
| 担わない | 判定 (`Policy.ps1` / `ClaudeClient.ps1`) / 出自の取り直し (`phase4/lib/SourceAccess.ps1`) / 承認の可否 (`phase4/lib/WorkTools.ps1`・`HttpAction.ps1`) / 画面と HTTP (`phase3/Start-Board.ps1`) |

**ここには業務判断を置かない。**「要対応か」「送ってよいか」は上の層が決め、
ストアは記録と競合の裁定だけをする。ただし例外が2つあり、どちらも理由がある。

- **同一性の計算** (`New-EventIdentity` 〜 `Get-EventIdentityFromRow`)
  通知側と同期側が**同じ文字列を作れなければ機能しない**。どちらかの経路に置くと、
  もう一方が別の作り方をした瞬間に静かに結ばれなくなる。両方が読む場所に集約している。
- **設定カードの生成** (`New-SetupTask`)
  「同じサービスの設定カードは1枚」を守るのは `subject_key` の一意性の問題であり、
  束ね直しは SQL で閉じている。呼ぶ側 (ワーカー) に任せると言い回しで増殖する。

依存は `lib/WinSqlite.ps1` **だけ**。上位の phase を一切知らない。

**依存元** (`. TaskStore.ps1` しているもの):

```
Start.ps1 / Start-Collector.ps1        起動・死活の表示
phase2/Invoke-Triage.ps1               取り込みと判定
phase2/Merge-Duplicates.ps1            遡っての重複畳み込み
phase3/Start-Board.ps1                 カンバンの API すべて
phase4/Start-Worker.ps1                ワーカー本体
phase4/Start-Delegation.ps1            Claude Code への引き渡し
phase5/Sync-Sources.ps1                同期側の取り込み
phase5/Reset-SlackContext.ps1          取り直しのやり直し
phase2/Show-Board.ps1                  暫定の端末表示
tests/cases/*.Tests.ps1 (11 本)
```

上位が全部ここを通るので、**このファイルの後方互換は上位の後方互換**になる。
列を消す・意味を変える変更は、上の 10 ファイルを同時に直すことを意味する。

---

## 2. データモデル

### 全体

```
events ─1:1─ tasks ─┬─ task_comments    やりとり (利用者の指示 / 報告 / 検証の指摘)
  │                 ├─ task_activity    作業ログ (step / done / error / cancelled / user / alert)
  │                 ├─ task_artifacts   作った成果物のファイル
  │                 ├─ task_attempts    実際に叩いたことの証跡 (request / preview 付き)
  │                 ├─ tool_requests    承認待ち
  │                 └─ task_sessions    モデルとの会話 (カード1枚に1本)
  └─ triage_log     判定の履歴 (捨てたものも残す)

subject_key ──→ dossier      件についての記録 (カードをまたぐ)
(カードに依らず) memories     人についての記録 (件をまたぐ)
tool_grants     まとめて許可 (scope = task | global)
settings        YOLO などの設定
worker_state    ワーカーの死活。1行だけ
```

### events — イベントソース

取り込んだ生の出来事。**同じものを何度入れても増えない** (`UNIQUE(source, source_key)` + `INSERT OR IGNORE`)。

| 列 | 役割 |
|---|---|
| `id` | `"{source}|{source_key}"`。外から決まる決定的な値で、AUTOINCREMENT ではない |
| `source` / `source_key` | 経路と、その経路での主キー (通知は Windows の tag、同期は API の ID) |
| `dedup_key` | **何を指しているか**。経路をまたいで突き合わせるための同一性 |
| `superseded_by` | 「これは別のイベントに統合された」印。入っている側はカードにしない |
| `account_id` | どのアカウントで取り込んだか。空は1人目 (`$script:PrimaryEventAccountId = '1'`) |
| `context_fetched` / `permalink` | 同期で本文を取り直した印と、ブラウザから踏める URL |

`source_key` の**一意性が効く範囲は経路によって違う**。Backlog のお知らせ ID は
スペース内の連番なので、二つ目のスペースを繋ぐと既存イベントと衝突し、UNIQUE に弾かれて
「繋いだのに何も入らない」になる。`ConvertTo-AccountSourceKey` が
2人目以降に `{account_id}|` を付けて避ける。**1人目に付けないのは移行を避けるため** ――
既存の `tasks.event_id` と `triage_log.event_id` を書き換えずに済む。

### tasks — カンバンのカード1枚

1イベント1枚 (`idx_tasks_event` が UNIQUE)。元通知を持たないカード (手起票・設定カード) は
`event_id IS NULL`。

**文面の箱が4つある。役割が違うので分けてある。**

| 列 | 誰が書く | 上書きしてよいか | 何に使う |
|---|---|---|---|
| `agent_output` | ワーカー | 再実行で上書き | 人が読む報告 |
| `draft_text` | ワーカー | 再実行で上書き | 外に出る文面の**案** |
| `user_edited` | 利用者 | **しない** | 実際に送られる文面 |
| `user_record` | 利用者 | しない | なぜ完了にしたかの記録 |

`user_record` を後から足したのは、記録を `user_edited` に入れていたころ、
返信先のあるカードで記録を保存すると**それが送信欄に現れ、記録欄からは消えて見えた**ため。

**状態を持つ列**:

| 列 | 値 | 意味 |
|---|---|---|
| `board_column` | `inbox` / `todo` / `doing` / `review` / `done` / `dismissed` | カンバンの列。`archived_at` が入ると一覧から外れる |
| `shape` | `reply` / `action` / `human` / `setup` / `blocked` / `info` | カードの**出口の形**。UI の出しかたとワーカーの拾いかたが変わる |
| `version` | 整数 | 楽観ロック。内容を変えるたびに +1 |
| `cancel_requested` | 0/1 | 中止要求。実際に止めるのはワーカー |
| `agent_lease_until` | ISO 時刻 | ワーカーがこのカードを握っている期限 |
| `subject_key` / `occurrence_count` | | 「同じ件」の識別と、その件が来た回数 |
| `alert` | | 書き込み後の点検が問題を見つけた印。押されるまで赤い |
| `memory_at` | | `memories` に取り込み済みの印 (毎周回読み直して費用だけかかるのを防ぐ) |

### 周辺テーブルで注意の要るもの

- **`task_comments.kind`** … `NULL`/`author='user'` は利用者の指示、`report` はワーカーの報告、
  `verify` は自己検証で解消しなかった指摘。報告を `agent_output` に上書きしていたころは、
  差し戻すたびに前回の報告が読めなくなっていた。
- **`task_comments.consumed_at`** … ワーカーが読んだ印。`Set-CommentsConsumed` に
  **読んだ id までを渡すこと** ―― 全部を既読にすると、作業中に届いた指示が
  一度も読まれないまま消える。
- **`task_attempts`** … 何を叩いて何が返ったか。`request` は符号化前の平文、`preview` は
  書く前の突き合わせと書いた後の読み直し。`require_human_step` を「試さずに呼ぶ」のを
  弾く判定材料であり、記憶の材料でもある。
- **`task_sessions`** … カード1枚につき会話1本。`occurrence` は会話を始めたときの
  `occurrence_count` (同じ件の新しい発生は別の出来事なので会話を分ける)、
  `source_hash` は渡した出自の指紋 (再開時に差分だけ渡す)、`state` は
  `running` / `done` / `partial`。
- **`tool_grants.tool`** … `http_request` は**ツール名ではなく「種類 × ホスト」**で持つ
  (`http_request:add:api.github.com`)。

---

## 3. 不変条件

破れても例外が飛ばず、**症状だけが出る**ものを並べる。触るときはここを壊していないかを見る。

| # | 守っていること | 担保 | 破れたときの症状 |
|---|---|---|---|
| 1 | 同じ通知を何度取り込んでもイベントは1件 | `UNIQUE(source, source_key)` + `INSERT OR IGNORE` | 再取り込みでカードが増殖する |
| 2 | 1イベントにつきカードは1枚 | `idx_tasks_event` UNIQUE + `New-Task` は `INSERT OR IGNORE` | 同上 |
| 3 | 通知と同期が同じ `dedup_key` を作る | `New-EventIdentity` に組み立てを集約 | カードが2枚立つ (症状は「重複」) |
| 4 | 束ねるのは**経路をまたぐ**1対1だけ | `Find-EventCounterpart` の `e.source <> ?` | 同じ件名のメールが続けて来ると**本物が1通消える** |
| 5 | 正は必ず同期側 | `Get-EventRank`。通知=1 / それ以外=2 | 表示用テキストだけのカードが残り、返信先を失う |
| 6 | カードの内容変更は `version` で直列化 | `Set-TaskColumn` / `Update-TaskFields` / `Set-TaskCancel` が `version+1` | 利用者の編集がワーカーの書き戻しに踏み潰される |
| 7 | `doing` のカードを握るのは1人 | `Get-NextWorkItem` のトランザクション + リース | 2つのワーカーが同じカードで外向きの操作を二重に出す |
| 8 | 更新できる列はホワイトリスト | `$script:UpdatableFields` | 列名が SQL に埋まるので任意列の書き換え口になる |
| 9 | 設定カードはサービスごとに1枚 | `subject_key = 'setup:{service}'` で既存を探す | 同じ権限の設定カードが言い回しの数だけ立つ |
| 10 | カードを消すと参照行も全部消える | `Remove-TaskRows` | `FOREIGN KEY constraint failed` で**削除そのものが失敗** |

**4 と 5 は対になっている。**「同期どうしを突き合わせない」のも同じ理由で、
Gmail と Outlook の両方に届いた同じメールを束ねると、**どちらが正かを決める材料が
こちら側に無い**まま片方が消える。だから `mail` と `outlook` は別種の鍵にしてある。

---

## 4. 主要な流れ

### (a) 取り込み → 突き合わせ → カード

呼ぶのは `phase2/Invoke-Triage.ps1`。ストア側は部品を出しているだけで、
**順序と判断は呼ぶ側にある。**

```
Add-Event (冪等)
  └ 既存行にも dedup_key を書き直す ← 列が増える前に入った行にも同一性を付けるため
Get-UntriagedEvents          triage_log に記録が無く、superseded でないもの
  ├ Test-WaitForSync         同期が拾うはずの通知は数分待つ (Invoke-Triage.ps1)
  └ Find-EventCounterpart    反対側の経路に同じものが居るか
       ├ 自分が正 (同期側)
       │    ├ 相手がもうカードなら  Move-TaskEvent   ← 土台だけ差し替え。列・編集・コメントは残る
       │    └ まだカードでないなら  Set-EventSuperseded で相手を止め、自分は普通に判定
       └ 相手が正 (同期側)        Set-EventSuperseded で自分を止める。カードにしない
New-Task                     判定結果を1枚のカードに
```

`Move-TaskEvent` が **`version` を上げない**のは意図的。
カードの内容を書き換えたわけではないので、作業中のワーカーの書き戻しを弾く理由が無い。

### (b) ワーカーの取り出し

```
Get-NextWorkItem -LeaseMinutes 10
  BEGIN
    SELECT … WHERE archived_at IS NULL AND cancel_requested = 0
                AND (shape IS NULL OR shape <> 'setup')   ← 設定カードは人間待ちなので拾わない
                AND (board_column = 'todo'
                     OR (board_column = 'doing' AND リース切れ))   ← 落ちたワーカーの回収
             ORDER BY urgency (high→normal→other), id ASC
             LIMIT 1
    UPDATE … SET doing, lease, version+1 WHERE id = ? AND version = ?   ← 0 行なら直前に人が動かした
  COMMIT
```

`SELECT` と `UPDATE` の間に利用者が動かしうるので、**`version` の照合まで含めて1件取得**になっている。
0 行なら `$null` を返して次の周回に回す (取らない、が正しい)。

### (c) 割り込み

| 操作 | 関数 | 効き方 |
|---|---|---|
| 指示を書いて差し戻す | `Request-TaskRework` | `todo` に戻す。ただし `doing` は動かさない (中止要求と区別が付かないため)、`setup` と アーカイブ済みも動かさない |
| 中止 | `Set-TaskCancel` | フラグを立てるだけ。実際に止めるのはワーカーが各ステップ前に見る `Test-TaskCancelled` |
| 資格情報が入った | `Get-TasksWaitingForSetup` → `Resume-Task` | 止まっていたカードを**まとめて** `todo` に戻す。`human_step` と `shape` は消す (もう事実ではない) |

`Request-TaskRework` と `Resume-Task` はどちらも **`cancel_requested` を解き、
`agent_lease_until` を NULL にしてから**戻す。どちらか片方でも残すと、
要対応に見えるのに永久に拾われないカードができる。

---

## 5. 同時実行と一貫性

書き手は常時3プロセス (収集・ワーカー・カンバン)、加えて引き渡し中は `Start-Delegation.ps1`。
いずれも同じ `tasks.db` を開く。

- **WAL + `busy_timeout` 5 秒** (`lib/WinSqlite.ps1`)。読みが書きを止めない。
- **明示的なトランザクションは2か所だけ** ―― `Get-NextWorkItem` と `Remove-Tasks`/`Remove-Task`。
  ほかは単文で足り、`version` の照合が入っているものは単文のまま原子的になる。
- **一括削除は全件で1つのトランザクション**。途中で外部キーに引っかかっても
  「何枚かだけ消えた」にはならず、押す前に戻る。
- **UI のポーリングは `Get-BoardRevision`**。カード・コメント・作業ログ・成果物・
  承認待ちの件数と最終更新をまとめた安い1行で、変わったときだけボード全体を取り直す。
  **ワーカーの死活の `updated_at` は含めない** ―― 5 秒ごとのハートビートが版を変え、
  ボード全体の再取得が延々と走るため。含めるのは `state` と `current_task_id` だけ。

---

## 6. スキーマ移行の作法

役割が2つに分かれている。

| | |
|---|---|
| `$script:Schema` | **新規 DB の初期形**。`CREATE TABLE IF NOT EXISTS` の塊 |
| `Invoke-SchemaMigration` | **既存 DB への追随**。`PRAGMA table_info` で見て `ALTER TABLE` |

`Open-TaskStore` が毎回両方を流す。移行は冪等で、起動のたびに走ってよい。

> **`CREATE TABLE IF NOT EXISTS` はテーブルが別の形で既にあると何もしない。**
> 開発途中の版 (`state` が無く `model` がある) で作られた `task_sessions` を持つ DB が実際にあり、
> 全カードの作業が `table task_sessions has no column named state` で落ちた。
> **テーブルを足すときも、列は `PRAGMA` で見て足すこと。**

### 列を足すときの手順

1. `Invoke-SchemaMigration` に `PRAGMA table_info` の確認 + `ALTER TABLE` を足す。
   **`$script:Schema` 側にも足す** (新規 DB のため)。
2. 索引が要るなら `CREATE INDEX IF NOT EXISTS` を同じ場所に。
3. 画面や API から書き換えるなら `$script:UpdatableFields` に足す。
   足さないと**黙って無視される** (`Update-TaskFields` は知らない列を捨てる)。
4. **既存行に値が要るなら、移行ではなく取り込みのたびに書き直す**。
   `dedup_key` がこの形 ―― 計算が決定的なので、次の取り込みで後から付く。
5. 既定値のある `NOT NULL` 以外は `NULL` が入ることを前提に読む側を書く。

### テーブルを足すときの手順

1. `Invoke-SchemaMigration` の中で `CREATE TABLE IF NOT EXISTS` + 列の `PRAGMA` 確認。
2. `task_id` を持つなら **`Remove-TaskRows` に `DELETE` を足す**。
   取りこぼすと外部キーでカードの削除自体が落ちる。
3. 画面の更新契機に関わるなら `Get-BoardRevision` に件数を足す。

---

## 7. 過去に踏んだもの

| 症状 | 原因 | いまの担保 |
|---|---|---|
| 同じメンション・メールでカードが2枚 | `source_key` が経路ごとに別物で UNIQUE が効かない | `dedup_key` と `Find-EventCounterpart` (§4a) |
| 二つ目の Backlog を繋いだら何も入らない | お知らせ ID がスペース内連番で既存と衝突 | `ConvertTo-AccountSourceKey` |
| 全カードが `no column named state` で落ちる | 古い形の `task_sessions` に `CREATE IF NOT EXISTS` が効かない | テーブルにも `PRAGMA` 確認 |
| GET のつもりで押した「今後すべて許可」が PUT まで通した (#295) | 許可の単位がツール名だった | `http_request:{種類}:{ホスト}`。移行で旧 `http_request` の許可は読み取りに落として削除 |
| 差し戻すと前回の報告が読めない | 報告を `agent_output` に上書きしていた | `task_comments.kind = 'report'` に積む |
| 記録を保存すると送信欄に現れる | `user_edited` が送る文面と記録を兼ねていた | `user_record` を分離 |
| 送信後に点検が問題を見つけても他と同じ見た目 (#295) | 印が無かった | `tasks.alert`。利用者が確認するまで赤い |
| 設定カードが何枚も立つ | 束ねる鍵がモデルの自由記述だった | `subject_key = 'setup:{service}'` |

---

## 8. テスト

`tests/Run-Tests.ps1`。`winsqlite3.dll` が無い環境では `Skip-It` でまとめて飛ぶ。

| ファイル | 見ているもの |
|---|---|
| `tests/cases/TaskStore.Tests.ps1` | 取り込みの冪等、同一性の組み立て (通知側と同期側が同じ鍵を作るか)、突き合わせ、差し替え |
| `tests/cases/Setup.Tests.ps1` | 設定カードの束ね、`Get-TasksWaitingForSetup` → `Resume-Task` |
| `tests/cases/WorkerSession.Tests.ps1` | 会話の保存・再開・`occurrence` での区切り |
| `tests/cases/Guards.Tests.ps1` | 承認の要否と許可の単位 |
| `tests/cases/Accounts.Tests.ps1` | アカウントを分けたときの `source_key` |
| `tests/cases/Dossier.Tests.ps1` / `Memory.Tests.ps1` | 件の台帳と人の記憶 |
| `tests/cases/BoardApi.Tests.ps1` / `HumanStep.Tests.ps1` / `Delegation.Tests.ps1` | ストアを土台に上位を見るもの |

**新しい不変条件を足したら §3 の表とテストの両方に足す。**
ここで守っているものは壊れても静かなので、テストが無いと次に気づくのは症状が出たときになる。

---

## 9. いま抱えている歪み

- **`Invoke-SchemaMigration` が 200 行の一本道**。冪等で順序に依存しないので
  実害は出ていないが、読むのに一番時間がかかるのはここ。版番号を持たせて分割する余地がある。
- **`Get-BoardRevision` は毎回 `COUNT(*)` を5本** 走らせる。カードが数千枚になったら効く。
  いまは WAL のおかげで書き手を止めないので、実測で困るまで触らない判断。
- **`tool_grants` に `scope='task'` の行が残りうる**。`Remove-TaskRows` では消しているが、
  アーカイブでは残る (カードが戻る可能性があるため意図的)。
- **`memories` と `dossier` のテーブル定義だけがここにあり、読み書きは `Memory.ps1` / `Dossier.ps1`**。
  スキーマの置き場を一箇所にした結果で、構成要素の切れ目とファイルの切れ目がずれている。
