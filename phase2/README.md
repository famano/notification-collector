# Phase 2 — 判断層とタスクストア

Phase 1 が集めた通知を取り込み、**対応要否を判定してカンバンのカードに変換する**層。

```
notifications.jsonl → events → ルール前段フィルタ → Claude 判定 → tasks
                                     ↓ (捨てる)
                                 triage_log
```

| ファイル | 役割 |
|---|---|
| `lib/TaskStore.ps1` | SQLite のスキーマと CRUD。events / tasks / task_comments / triage_log |
| `lib/ClaudeClient.ps1` | Claude API 呼び出し。tool use で構造化出力を強制 |
| `config/policy.json` | 判定方針。コードを触らず調整する場所 |
| `Invoke-Triage.ps1` | パイプライン本体 |
| `Show-Board.ps1` | 暫定のカンバン表示（Phase 3 の Web UI までのつなぎ） |

## 使い方

まず配線確認（**APIキー不要・書き込みなし**）:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase2\Invoke-Triage.ps1 -DryRun
```

実際に判定してタスク化する:

```powershell
$env:ANTHROPIC_API_KEY = 'sk-ant-...'
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase2\Invoke-Triage.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase2\Show-Board.ps1
```

APIキーはファイルに置かず環境変数から読む。恒久化するなら
`[Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY','sk-ant-...','User')`。

## 設計上の判断

**ルール前段フィルタを LLM の前に置く。**
全通知を LLM に投げるとコストが無駄になる。`policy.json` の `ignore` に一致した通知は
API を消費せずに捨て、`triage_log` にだけ記録が残る。実測では 8 件中 2 件（OneDrive の
同期通知、タスクバーのピン留め確認）がここで落ちた。

**対応不要でもカードは作る。**
`needs_action=false` のものは `dismissed` 列に置く。判定を後から見直せるようにするため、
また「見たうえで不要と判断した」ことを可視化するため。

**エージェントの生成物とユーザーの編集を分離する。**
`tasks.agent_output` と `tasks.user_edited` は別カラム。エージェントが下書きを再生成しても
ユーザーが直した内容は消えない。

**楽観ロック。**
`tasks.version` を照合して更新する。ユーザーがカードを動かした直後にエージェントが
古い内容を書き戻す事故を防ぐ。`cancel_requested` と `agent_lease_until` も Phase 3 の
割り込み制御のために先に用意してある。

**プロンプトインジェクション対策。**
通知本文は第三者が書いた文字列なので、`<notification>` タグで囲み、その内側は
指示ではなくデータであることをシステムプロンプトで明示している。
外向きの送信は Phase 3 以降も人間の承認を必須にする。

**モデルの既定は `claude-sonnet-5`。**
全通知を通す分類器なので費用対効果を優先した。判断精度を上げたい場合は
`policy.json` の `llm.model` を `claude-opus-5` に変更する。

## 検証済みの範囲

`-DryRun` で 8 イベント（ルール除外 2 / LLM 対象 6）を確認。JSONL の重複行は
`events` の UNIQUE 制約で 1 件に集約された。

タスクストアは自己テストで以下を確認:

- 同一キーの再取り込みが弾かれる（冪等）
- 1 イベントにつきカードが 1 枚しか作られない
- 日本語・引用符・山括弧がパラメータバインドで正しく往復する（SQL インジェクション耐性）
- 楽観ロックが古い version の更新を拒否する

**未検証: Claude API の実呼び出し。** `ANTHROPIC_API_KEY` が未設定のため
`Invoke-ClaudeTriage` は動作確認できていない。

## 次のステップ（Phase 3 に向けて）

1. `ANTHROPIC_API_KEY` を設定して判定層を実データで確認する
2. Slack Socket Mode を繋ぎ、`thread_ts` からスレッド全文を取得して `events.body` を差し替える
   （通知本文だけでは判断材料が足りないという Phase 1 の結論への対応）
3. Gmail API / Microsoft Graph でメールを直接取得する
4. カンバンの Web UI（SSE + ドラッグ&ドロップ）と、割り込み・キャンセルの実装
