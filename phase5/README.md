# Phase 5 — 外部サービス接続

通知本文だけでは判断材料が足りない、という Phase 1 の結論への対応。
**通知は起点として使い、実データは正規 API から取り直す。**

さらに、通知は「速いが穴が開く」経路でしかない ―― PC が落ちていればトーストは
配信されず、起動していても `wpndatabase` は十数件しか保持しないので Phase 1 を
止めていた間の分は消える。そこで **取りこぼしの無さは、この層の watermark 同期で
担保する。**通知は低遅延のトリガに徹し、抜けはあとから API で埋める。

| ファイル | 役割 |
|---|---|
| `lib/SecretStore.ps1` | 資格情報を DPAPI で暗号化して保存 |
| `lib/SlackConnector.ps1` | 掃き寄せ、スレッド全文の取得、スレッドへの投稿 |
| `lib/GmailConnector.ps1` | OAuth、本文取得、本物の下書き作成、送信 |
| `Connect-Service.ps1` | 設定ウィザード |
| `Sync-Sources.ps1` | Slack の掃き寄せ・補完と Gmail の取り込み |
| `Reset-SlackContext.ps1` | 補完に失敗した印を消して再試行させる |

## watermark 同期

`settings` テーブルに「前回どこまで取ったか」を持つ。

| キー | 意味 |
|---|---|
| `sync.slack.lastTs` | ここまでの Slack は読んだ |
| `sync.gmail.lastInternalDate` | ここまでのメールは取り込んだ |

- **初回や記録が無いときは直近 24 時間**まで遡る。長くすると初回に大量のカードが立つ。
- **取り切れたときだけ進める。** 一時的な理由 (レート制限・通信断) で読めなかった会話が
  あれば据え置き、次回もう一度同じ範囲を読む。権限不足やチャンネル未参加のような
  **何度読んでも同じ失敗は据え置きの理由にしない** ―― それで止めると、読める会話の分まで
  永久に入らなくなる。
- Gmail は上限件数に達したら進めない。残りが飛ぶため。`-GmailMax` を上げて流し直す。
- **新規 0 件でも進める。** 「1 件でも取れたときだけ記録する」にすると、静かな日が続く
  かぎり watermark が生まれず、いつまでも「直近 24 時間」だけを見ることになる。
  そうなると丸一日以上 PC を落とした穴は二度と埋まらない。検索は開始時刻までを
  上限なしで見ているので、そこまでは取り切れたと言い切ってよい。
- 重複しても `events` の UNIQUE で弾かれるので、**戻しすぎる分には害がない。**
  Slack は掃き寄せ中に届いたものを落とさないよう、開始時刻から 2 分戻して記録する。
- 取りこぼしに気付いたときは `-Since (Get-Date).AddDays(-3)` で遡って読み直せる
  (このときは watermark を動かさない)。

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

常用ではこの2つを手で叩かず、`Start-Collector.ps1` に回させる。
起動直後に一度同期するので、**電源を落としていた間の穴はそこで埋まる。**

## Slack

### 掃き寄せ（通知に依存しない取得）

`users.conversations` で会話を並べ、`conversations.history` を watermark 以降で読む。
トーストが出ていなくても拾えるので、**寝ているあいだに来たものが翌朝カードになる。**

流れる全部をカードにするとトリアージのコストが跳ねるので、入り口で
「自分に関係がある」と言い切れるものだけに絞る。絞りきれなかったものは捨てる。

| 理由 | 拾うもの |
|---|---|
| `dm` | DM / グループ DM に来たもの |
| `mention` | 自分が名指しされたもの (`<@自分>`) |
| `thread` | **すでにカードがあるスレッドへの新しい返信** ＝ 会話の続き |

`mention` の判定には自分のユーザーIDが要る。`Connect-Service.ps1 -Service slack` が
メールアドレスか表示名から引いて保存する。User Token を入れた場合は `auth.test` で
自動的に分かるので聞かない。

掃き寄せたメッセージは通知から来たものと同じ形の `slack://` リンクを持たせてある。
そのため次の補完段がそのまま動き、スレッド全文も permalink も同じ経路で埋まる。

### Bot Token と User Token

**読み取りは User Token (`xoxp-`) があればそちらを優先する。** 理由は見える範囲が違うため:

| | Bot Token (`xoxb-`) | User Token (`xoxp-`) |
|---|---|---|
| チャンネル | **招待されたところだけ** | 自分が入っている全部 |
| DM | Bot 自身宛のものだけ | **自分の DM が読める** |

つまり Bot Token だけの構成では、**夜のあいだに来た DM は取りこぼしたままになる。**
そこを埋めたい場合は User Token を入れる。投稿は Bot Token がある限り Bot 名義のまま。

### 補完

通知や掃き寄せが作った `slack://channel?id=…&message=…&thread_ts=…` を分解し、
`conversations.replies` でスレッド全文を取得して `events.body` に足す。
`<@U123>` はユーザー名に、`<url|text>` は読める形に均す。
このとき `chat.getPermalink` の結果を `events.permalink` に残す ――
カンバンの「元を開く」がここを使う。`slack://` と違いブラウザからそのまま開ける。

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
  既定の検索式は watermark から組み立てた `in:inbox after:<epoch>`。
  **`is:unread` では絞らない** ―― スマホで先に読んだメールは既読になってしまい、
  それで絞ると二度と取り込まれないため。`nextPageToken` を辿るので 1 ページを
  超えても取り切る。`occurred_at` には `internalDate` (受信時刻) を入れる。
  取り込み時刻にすると、何日ぶんかまとめて取ったときに全部「いま」になって並びが壊れる。
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

実データで確認したこと（使い捨ての DB に対して実行）:

- Gmail の watermark 同期 — 初回は直近 24 時間、2 回目は `after:<前回>` になり新規 0 件。
  `occurred_at` が受信時刻（前日夜〜当日朝がそのまま並ぶ）になることも確認
- 上限件数に達したとき watermark を進めないこと
- 未読でないメールも取り込まれること（`is:unread` を外した効果）
- Slack の掃き寄せが `users.conversations` → `conversations.history` を辿ること
- 読めない会話が `channel_not_found` のような恒久的な失敗なら watermark を進め、
  一時的な失敗なら据え置くこと

**未検証:** `drafts.create` と `chat.postMessage` は実データで動かせていない。
Slack の掃き寄せも、現在の Bot Token では Bot が入っているチャンネルが無いため
**0 件でしか確認できていない**（メンション判定に使う自分のユーザーIDも未設定）。
`Connect-Service.ps1 -Service slack` をもう一度流すのが最初の一歩になる。
