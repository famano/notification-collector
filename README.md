# notification-collector

Windows の通知とメールを起点に、対応の要否を判断し、実際の作業まで行い、
その進捗をカンバンで見ながら人間が割り込めるようにするシステム。

```
[収集]              [判断]           [実行]              [操作]
通知DB (Phase 1) ─┐
Slack API ────────┼→ トリアージ ──→ ワーカー ──────→ カンバン
Gmail API ────────┘   (Phase 2)      (Phase 4)         (Phase 3)
                                         ↑                 │
                                         └── 承認・指示・割り込み ─┘
```

追加インストールは不要。Windows 同梱の `winsqlite3.dll` と `HttpListener` を使う
PowerShell 実装で、Python も Node も .NET SDK も要らない。

## 構成

| | 内容 |
|---|---|
| [phase1](phase1/README.md) | 通知の取得。`wpndatabase.db` をポーリングして JSONL に出す |
| [phase2](phase2/README.md) | 判断層とタスクストア。ルールで足切りしてから Claude で判定 |
| [phase3](phase3/README.md) | カンバン UI。承認・割り込み・修正・アーカイブ |
| [phase4](phase4/README.md) | ワーカー。ツールで実際に成果物を作り、自己検証する |
| [phase5](phase5/README.md) | 外部サービス接続。Slack スレッド補完と Gmail |

## 動かす

```powershell
# 1. 通知を集める (常駐)
.\phase1\Get-Notifications.ps1 -Watch

# 2. 外部サービスから実データを補う (任意)
.\phase5\Connect-Service.ps1 -Service slack
.\phase5\Sync-Sources.ps1

# 3. 対応要否を判定してカード化
$env:ANTHROPIC_API_KEY = 'sk-ant-...'
.\phase2\Invoke-Triage.ps1

# 4. カードを処理するワーカー (常駐)
.\phase4\Start-Worker.ps1

# 5. カンバンを開く
.\phase3\Start-Board.ps1
```

いずれも `powershell -NoProfile -ExecutionPolicy Bypass -File <script>` で実行する。

## 設計の要点

**通知は起点、実データは正規 API。**
通知には表示用テキストしか入っておらず、スレッドの経緯も返信手段も無い。
一方で Slack 通知のディープリンクには API の主キーが揃っているので、
通知をトリガーにして本文を取り直せる。

**「ブロック」は応答不可 (DND) で行う。**
アプリ側の通知をオフにするとトースト自体が発行されず、DB にも入らないため
取得できなくなる。応答不可ならポップアップだけ抑止され、DB には残る。

**能力は削らず、承認で門を作る。**
コマンド実行も外部通信も可能。ただし危険なものは実行前に止まり、
カンバンに実行内容が全文出る。まとめて許可と YOLO も選べる。

**エージェントの生成物とユーザーの編集は分離する。**
`agent_output` と `user_edited` は別カラム。再生成しても手を入れた内容は消えない。
列の移動は `version` で楽観ロックする。

**外向きの送信はしない。**
メールは下書きを作るところまで。送信可否は必ず人間が決める。

## 注意

- `.ps1` は **UTF-8 BOM 付き**で保存すること。PowerShell 5.1 は BOM 無し UTF-8 を
  ANSI と誤読し、日本語コメントが構文エラーになる。
- 取得した通知の実データ、成果物、資格情報は `.gitignore` 済み。
  業務上のメッセージ本文が入るのでコミットしない。
