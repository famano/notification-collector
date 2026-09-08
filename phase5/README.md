# Phase 5 — 外部サービス接続

通知本文だけでは判断材料が足りない、という Phase 1 の結論への対応。
**通知は起点として使い、実データは正規 API から取り直す。**

| ファイル | 役割 |
|---|---|
| `lib/SecretStore.ps1` | 資格情報を DPAPI で暗号化して保存 |
| `lib/SlackConnector.ps1` | 通知のリンクからスレッド全文を取得、スレッドへの投稿 |
| `lib/GmailConnector.ps1` | OAuth、本文取得、本物の下書き作成、送信 |
| `Connect-Service.ps1` | 設定ウィザード |
| `Sync-Sources.ps1` | Slack の補完と Gmail の取り込み |
| `Reset-SlackContext.ps1` | 補完に失敗した印を消して再試行させる |

## 使い方

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase5\Connect-Service.ps1 -Service slack
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase5\Connect-Service.ps1 -Service gmail
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase5\Connect-Service.ps1 -Test
```

設定後、判定の前に流す:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase5\Sync-Sources.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase2\Invoke-Triage.ps1
```

## Slack

通知の `launch` に入っている `slack://channel?id=…&message=…&thread_ts=…` を分解し、
`conversations.replies` でスレッド全文を取得して `events.body` に足す。
`<@U123>` はユーザー名に、`<url|text>` は読める形に均す。

**Socket Mode は使っていない。** 通知リスナーが既にトリガーとして機能しているので、
常時接続を足す理由がない。読み書きとも Web API で足りる。

投稿もできる。ワーカーに `send_slack_message` ツールが増え、`chat.postMessage` で
**元のスレッドへの返信として**投稿する。チャンネルと `thread_ts` は通知のリンクから
ワーカーが束縛して渡すので、モデルは投稿先を指定できない。実行前に必ずカンバンで
承認を取る。投稿名義は利用者本人ではなくこの Bot になる。

必要な Bot Token Scopes は `Connect-Service.ps1 -Service slack` が案内する。
投稿には `chat:write` が要る。**後から足した場合は再インストールしてトークンを
取り直すこと。**古いトークンのままだと `missing_scope` で失敗する。
**Bot は招待されたチャンネルしか読めない。** 通知は来るのに本文が取れない場合、
たいていアプリがそのチャンネルに入っていない。

## Gmail

OAuth 2.0 のループバック方式。`HttpListener` で受け口を立て、ブラウザで同意を取り、
リフレッシュトークンを DPAPI で保存する。

- 取り込み — `Sync-Sources.ps1` が受信トレイを検索してイベント化する。
  通知経路に依存しないので、メールクライアントが通知を出していなくても拾える。
- 下書き — ワーカーに `create_gmail_draft` ツールが増える（Gmail 未設定なら出ない）。
  Gmail 由来のカードなら、`threadId` と `In-Reply-To` を自動で付けて
  **元のスレッドへの返信として**下書きが作られる。識別子はワーカーが束縛して渡すので、
  モデルが持ち回る必要はない。
- 送信 — `send_gmail` ツール。下書きと同じ経路で組み立てて `users.messages.send` に出す。
  実行前に必ずカンバンで承認を取り、宛先・件名・本文が全文表示される。

**スコープの注意:** `gmail.compose` は下書きと送信の両方を許す。Google には
「下書きだけ」のスコープが無いので、送信を止めたい場合はスコープではなく
承認画面で拒否する。既存のトークンのまま送信できるので、Gmail は再認証不要。

## 資格情報の扱い

DPAPI (CurrentUser) で暗号化して `phase5/data/secrets.dat` に保存する。
同じ Windows ユーザーでログオンしていないと復号できず、ファイルを別マシンに
コピーしても使えない。`.gitignore` 済み。画面に値を出す経路は用意していない
(`-Status` は項目名だけ表示する)。

## 他のサービスについての見立て

依頼のあった4つを調べた結果。**2つは技術的に不可能**なので実装していない。

### Microsoft Teams / Outlook — 可能。未実装

Microsoft Graph で両方取れる。`Chat.Read` でチャット、`Mail.ReadWrite` でメールと下書き。
認証はデバイスコードフローが使えるのでリダイレクト URI も要らない。

**必要なもの:** Entra ID (Azure AD) でのアプリ登録。テナントによっては
管理者の同意が要る。事務所のテナントで自由に登録できるかは確認が必要。

構造は Gmail コネクタとほぼ同じなので、登録さえ通れば追加は難しくない。

### LINE WORKS — 部分的に可能

Service Account の JWT 認証と Bot API がある。ただし取れるのは
**Bot が参加しているトークルームのメッセージだけ**で、自分宛のメッセージ全体を
読むような使い方はできない。Bot を業務のトークルームに入れてよいかは運用判断になる。

### Discord — 不可

- **Bot は他人の DM を読めない。** サーバー内のチャンネルなら読めるが、
  個人宛のメッセージには到達できない。
- **ユーザートークンを使う方法（セルフボット）は利用規約違反**で、
  アカウント停止の対象になる。

自分のサーバーの特定チャンネルを監視するだけなら Bot で可能だが、
「Discord の通知に対応する」という当初の目的には届かない。

### Messenger (Facebook) — 不可

Meta の Messenger Platform は **Facebook ページ宛のメッセージ専用**で、
個人アカウントの DM を読む API は公開されていない。回避手段は規約違反になる。

このため、Discord と Messenger については**通知リスナー（Phase 1）で
表示テキストを拾うところまでが上限**になる。文脈の補完はできない。

## 検証済みの範囲

資格情報なしで確認できるところまで:

- DPAPI の往復。保存ファイルに平文のトークンが現れないことを確認
- Slack リンクの解析を Phase 1 で実際に取れた通知リンクで確認。
  `thread_ts` が無い通知では `message` を起点にフォールバックすることも確認
- Gmail の base64url 往復（`+ / =` が残らないこと）と RFC2047 件名の往復
- `events.context_fetched` のスキーマ移行
- Gmail 未設定時に `create_gmail_draft` がツール一覧に出ないこと
- 未設定のまま `Sync-Sources.ps1` を流しても落ちず、飛ばして終わること

**未検証: 実際の API 呼び出し。** トークンと OAuth クライアントが要るため、
`conversations.replies` や `drafts.create` は実データで動かせていない。
`Connect-Service.ps1 -Test` が最初の疎通確認になる。
