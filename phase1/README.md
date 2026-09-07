# Phase 1 — 通知コレクタ

Windows の通知データベース (`wpndatabase.db`) をポーリングして通知を取得する。
**Phase 1 の目的は「通知だけでどこまで分かるのか」を実データで見極めること。**

## 実行環境の前提

このPCには Python / Node / .NET SDK がいずれも入っていない（`python` はストアのスタブ）。
そのため **Windows 同梱の `winsqlite3.dll` (3.51.1) を P/Invoke する PowerShell 実装**にした。
追加インストールもネットワークも不要で動く。

| ファイル | 役割 |
|---|---|
| `lib/WinSqlite.ps1` | `winsqlite3.dll` の P/Invoke ラッパ + DBスナップショット取得 |
| `Get-Notifications.ps1` | 本体。差分取得・XML解析・JSONL出力 |
| `dump-schema.ps1` | 調査用。スキーマと生ペイロードを表示 |
| `data/notifications.jsonl` | 取得結果（1行1通知） |
| `data/state.json` | 最終取得位置と重複排除キー |

> `.ps1` は **UTF-8 BOM 付き**で保存すること。PowerShell 5.1 は BOM 無し UTF-8 を ANSI と誤読し、
> 日本語コメントが構文エラーを起こす（実際に一度踏んだ）。

## 使い方

```powershell
# DBに現存する通知をすべて出す（初回の動作確認用）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-Notifications.ps1 -Backfill
```

```powershell
# 5秒間隔で常時監視（Ctrl+C で停止）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-Notifications.ps1 -Watch
```

主なオプション: `-IntervalSeconds <n>` / `-IncludeAllTypes`（tile・badge も含む） / `-Json`（JSON行で標準出力）

## 動作確認の結果

`-Backfill` で 6 件の toast を取得。2 回目の実行は 0 件（差分検出と重複排除が機能）。

取れた通知の例:

| アプリ | 取れた内容 |
|---|---|
| Slack | ワークスペース名、チャンネル名、送信者名＋本文全文、`slack://` ディープリンク |
| Claude | タイトル・本文 |
| OneDrive / Windows | システム通知 |

## Phase 1 で分かったこと（Phase 2 の設計判断に直結）

**1. 通知の保持件数が極端に少ない。**
`Notification` テーブルは全 14 行（toast は 6 件）しかなかった。Windows は既読・期限切れの通知を
すぐ削除する。**ポーリング間隔は 5〜10 秒が上限**で、それ以上空けると取りこぼす。
常駐前提の設計が必須で、「1時間おきにまとめて取る」という運用は成立しない。

**2. Slack のディープリンクが決定的に有用。**
```
slack://channel?id=<channel_id>&message=<message_ts>
              &team=<team_id>&thread_ts=<thread_ts>
```
`team` / `channel id` / `message ts` / `thread_ts` がすべて入っている。
**これは Slack API の主キーそのもの**なので、通知をトリガーにして
`conversations.replies` でスレッド全文を取りに行ける。
→ 「通知は起点、実データは正規API」という方針が実データで裏付けられた。

**3. 一方、通知単体では判断材料が足りない。**
取れるのは表示用テキストのみ。スレッドの経緯、過去のやり取り、送信者のメールアドレス、
自分がメンションされた文脈などは一切含まれない。返信手段も持たない。
**通知だけで「対応の要否」を判断させるのは無理**で、Phase 2 で正規 API を繋ぐ必要がある。

**4. アプリ名が取れないことがある。**
`HandlerAssets.DisplayName` が空のハンドラがあり、Slack も AUMID (`com.squirrel.slack.slack`)
でしか識別できなかった。**AUMID を正とし、表示名は付加情報**として扱うのが正しい。

**5. メール通知はサンプルに含まれなかった。**
メールクライアントが通知を出していないためと思われる。メールは最初から Gmail API /
Microsoft Graph で取る前提にしたほうがよい（通知経路に依存しない）。

**6. 「ブロック」は応答不可（DND）で実現する。**
アプリ側の通知をオフにするとトースト自体が発行されず、DBにも入らないため取得できなくなる。
**応答不可を ON にすればポップアップだけ抑止され、DB には残る**ので本コレクタは動き続ける。

## 次のステップ（Phase 2）

1. Slack Socket Mode を繋ぎ、`thread_ts` からスレッド全文を取得する
2. Gmail API または Microsoft Graph でメールを直接取得する（通知経路に依存しない）
3. 取得したイベントを Claude API に投げ、対応要否を構造化出力で判定する
4. 判定結果を SQLite のタスクテーブルに投入する
