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
| `lib/GraphConnector.ps1` | Microsoft Graph。Outlook のメールと Teams のチャット |
| `lib/HtmlText.ps1` | HTML を平文に落とす (メールも Teams も本文が HTML で来る) |
| `Connect-Service.ps1` | 設定ウィザード |
| `Sync-Sources.ps1` | Slack / Teams の掃き寄せ・補完と、Gmail / Outlook の取り込み |
| `Reset-SlackContext.ps1` | 補完に失敗した印を消して再試行させる |

## watermark 同期

`settings` テーブルに「前回どこまで取ったか」を持つ。

| キー | 意味 |
|---|---|
| `sync.slack.lastTs` | ここまでの Slack は読んだ |
| `sync.gmail.lastInternalDate` | ここまでの Gmail は取り込んだ |
| `sync.teams.lastTs` | ここまでの Teams は読んだ |
| `sync.outlook.lastReceived` | ここまでの Outlook は取り込んだ |

- **初回や記録が無いときは直近 24 時間**まで遡る。長くすると初回に大量のカードが立つ。
- **取り切れたときだけ進める。** 一時的な理由 (レート制限・通信断) で読めなかった会話が
  あれば据え置き、次回もう一度同じ範囲を読む。権限不足やチャンネル未参加のような
  **何度読んでも同じ失敗は据え置きの理由にしない** ―― それで止めると、読める会話の分まで
  永久に入らなくなる。
- Gmail と Outlook は上限件数に達したら進めない。残りが飛ぶため。
  `-GmailMax` / `-OutlookMax` を上げて流し直す。
- **新規 0 件でも進める。** 「1 件でも取れたときだけ記録する」にすると、静かな日が続く
  かぎり watermark が生まれず、いつまでも「直近 24 時間」だけを見ることになる。
  そうなると丸一日以上 PC を落とした穴は二度と埋まらない。検索は開始時刻までを
  上限なしで見ているので、そこまでは取り切れたと言い切ってよい。
- 重複しても `events` の UNIQUE で弾かれるので、**戻しすぎる分には害がない。**
  Slack は掃き寄せ中に届いたものを落とさないよう、開始時刻から 2 分戻して記録する。
- 取りこぼしに気付いたときは `-Since (Get-Date).AddDays(-3)` で遡って読み直せる
  (このときは watermark を動かさない)。

## 使い方

**カンバンのヘッダの「接続」から設定できる。** 権限不足でカードが止まっているときは、
その設定カードを開けばその場で入力できる（保存・疎通確認・止まっていたカードの再開まで）。
仕組みは `lib/ServiceSetup.ps1` にあり、画面と端末の両方がここを呼ぶ。

端末から設定したい場合は従来どおり:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase5\Connect-Service.ps1 -Service slack
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase5\Connect-Service.ps1 -Service gmail
powershell -NoProfile -ExecutionPolicy Bypass -File .\phase5\Connect-Service.ps1 -Service microsoft
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

## Microsoft 365 (Outlook / Teams)

Microsoft Graph を1本通して、**Outlook のメールと Teams のチャットの両方**を扱う。
入口 (アプリ登録) が同じなので、設定カードも接続の画面も1枚にまとめてある。

### 認証はデバイスコードフロー

画面にコードが出るので、別のタブでサインインして貼る。理由は登録の手間が一番軽いから:

- **リダイレクト URI を1つも登録しなくてよい。** 公開クライアントとして許可するだけ
- **クライアント シークレットが要らない。** 保存すべき秘密がひとつ減る
- カンバンを止めずに進められる。サーバは待たず、ブラウザ側が数秒おきに聞きに来る

必要なのは Entra ID (Azure AD) のアプリ登録1つと、そのクライアント ID だけ。

| 設定 | 値 |
|---|---|
| 認証 → パブリック クライアント フローを許可する | **はい** (ここが「いいえ」だと `AADSTS7000218`) |
| API のアクセス許可 (委任) | `offline_access` `User.Read` `Mail.ReadWrite` `Mail.Send` `Chat.Read` `ChatMessage.Send` |
| テナント | 空欄なら `organizations` (職場・学校アカウント) |

テナントによっては管理者の同意が要る。条件付きアクセスでデバイスコードフローを
塞いでいる場合もある (その場合は管理者に許可を求めるほかない。回避手段は用意しない)。

**リフレッシュトークンは使うたびに入れ替わる。** Google と違ってここを保存し直さないと、
しばらく動いたあとある日 `invalid_grant` で止まる ―― 原因が設定時から遠すぎて追えない
類の事故なので、更新のたびに保存し直している (テストで固定してある)。

### Outlook

- 取り込み — `/me/mailFolders/inbox/messages` を watermark 以降で読む。
  `Prefer: outlook.body-content-type="text"` で平文の本文をもらい、HTML しか無いものは
  こちらで落とす。`@odata.nextLink` を辿るので1ページを超えても取り切る。
  `occurred_at` には受信時刻 (`receivedDateTime`) を入れる。
  **既読・未読では絞らない** ―― スマホで先に読んだメールが二度と入らなくなるため (Gmail と同じ)。
- 取り直し — カードの `conversationId` で会話をまとめて読む。添付は一覧だけ先に取り、
  中身は `fetch_attachment` で要求されたものだけ落とす。
- 下書き — `create_outlook_draft`。返信なら `createReply` で作ってから本文を入れるので、
  **件名もスレッドも Graph 側が繋いでくれる** (手で組み立てるとスレッドから外れる)。
- 送信 — `send_outlook_mail`。下書きと同じ経路で作ってから送る。
  実行前に必ずカンバンで承認を取り、宛先・件名・本文が全文表示される。

### Teams

- 掃き寄せ — `/me/chats` を並べ、watermark 以降に動いたチャットだけ
  `/chats/{id}/messages` を読む。**チャネル (チーム内の公開投稿) は見ていない。**
  自分宛の会話はチャットに来るし、チャネルを読むには
  `ChannelMessage.Read.All` (管理者同意・範囲が広い) が要るため。
  `chats/getAllMessages` は一見ちょうどよく見えるが、**課金対象 (metered) の API** なので使わない。
- 絞り込みは Slack ほど要らない。`/me/chats` に出てくるのは 1:1・グループ・会議チャットで、
  出てくる時点で「自分が参加している会話」だから。自分の発言、参加・退出などの
  システムメッセージ、削除済みだけを落とす。自分が名指しされたものには `mention` の印を付ける。
- 補完 — `msteams://chat?id=…&message=…` を分解して直近のやり取りを足す。
  `webUrl` が取れれば `events.permalink` に残す (カンバンの「元を開く」がここを使う)。
- 投稿 — `send_teams_message`。投稿先はカードの元通知から束縛され、モデルは指定できない。
  チャットにスレッドは無い (スレッドはチャネルの機能) ので、投稿はそのまま会話に並ぶ。

### 通知との突き合わせ

Slack は通知のディープリンクに API の主キーが入っているので確実に結べるが、
**Teams と Outlook のトーストには主キーが載っていない。**そこで内容で突き合わせる。

| 経路 | 鍵 |
|---|---|
| Outlook | 件名 + 差出人の表示名。トーストは `[差出人, 件名, 本文の頭]` の順なので、件名は2行目から取る |
| Teams | 送信者 + 本文の頭 24 文字。トーストは長い文面を切って出すので、頭だけを見る |

Gmail と Outlook は**別の種類の鍵**にしてある。束ねてよいのは「通知1件と同期1件」で、
同期どうし (Gmail と Outlook) を突き合わせると、両方の受信箱に届いた同じメールが
片方だけ消える ―― どちらが正かを決める材料がこちらに無い。

### 分かっている限界

- **Teams のチャットは職場・学校アカウント専用。** 個人の Microsoft アカウントには
  delegated の API が無い (Outlook のメールは個人アカウントでも読める)
- チャネルの投稿は取っていない (上記の理由)
- チャットの添付は SharePoint / OneDrive 上のファイルへの参照で、開くには別の権限
  (`Files.Read`) が要る。いまは本文中のリンクとして渡すところまで

## 資格情報の扱い

DPAPI (CurrentUser) で暗号化して `phase5/data/secrets.dat` に保存する。
同じ Windows ユーザーでログオンしていないと復号できず、ファイルを別マシンに
コピーしても使えない。`.gitignore` 済み。画面に値を出す経路は用意していない
(`-Status` は項目名だけ表示する。カンバンの `/api/setup` も「設定済みか」と
「どのアカウントとして繋がったか」しか返さない)。

疎通確認に失敗したときは**保存前の値に戻す**。貼り間違えたトークンが残ると
「設定済みなのに全部 401」という一番分かりにくい状態になるため。

## 他のサービスの調査

通知元になりうる主要なサービスについて、**「自分宛のものを API で取り直せるか」**を
公開ドキュメントで確認した結果。判定の基準はこのアプリの目的に揃えてある ――
チャネルやページ単位で読めても、**自分宛の会話に届かないなら「部分的」**とする。

| サービス | 判定 | 要点 |
|---|---|---|
| Slack | 実装済み | 掃き寄せ・スレッド全文・投稿 |
| Gmail / Google カレンダー | 実装済み | 取り込み・下書き・送信・出欠 |
| GitHub | 実装済み | 調査・招待の承諾 (汎用 HTTP に資格情報を注入) |
| **Microsoft 365 (Outlook / Teams)** | **実装した** | 上の節のとおり |
| Chatwork | 可能。未実装 | API トークン1本で読み書きできる。次に足すならここ |
| Backlog | 可能。未実装 | API キー1本。「自分宛のお知らせ」の API がある |
| Google Chat | 可能。未実装 | 既存の Google クライアントにスコープを足すだけで済む |
| LINE WORKS | 部分的 | Bot が入っているトークルームだけ |
| Jira / Confluence (Atlassian) | 部分的 | 課題とコメントは読めるが、通知の受信箱そのものは無い |
| Notion | 部分的 | コメントは読めるが、通知 (受信トレイ) の API が無い |
| Zoom | 要確認 | チーム チャットのスコープはあるが、プランと承認の条件が読み切れない |
| Discord | 不可 | Bot は他人の DM を読めない。ユーザートークンは規約違反 |
| Messenger (Facebook) | 不可 | ページ宛のメッセージ専用。個人の DM を読む API は無い |
| LINE (個人) | 不可 | Messaging API は公式アカウント宛のみ。個人のトークは読めない |
| Telegram | 実質不可 | Bot は他人の DM を読めない。ユーザー API は MTProto のライブラリが要る |
| X (旧 Twitter) | 実質不可 | DM の読み取りは有料階層。費用が用途に見合わない |
| WhatsApp | 不可 | Business Platform は事業者番号宛のみ |

### 次に足すならこの3つ

いずれも「自分宛が読める」「投稿できる」「追加インストールが要らない」を満たす。
**Chatwork と Backlog は貼るだけのトークン**なので、設定の画面も既存の
`flow = 'token'` がそのまま使える。

**Chatwork** — `https://api.chatwork.com/v2`。個人設定で API トークンを発行し、
`X-ChatWorkToken` ヘッダに入れる。`GET /rooms` で部屋を並べ、
`GET /rooms/{room_id}/messages?force=1` で直近 100 件、`POST` で投稿できる。
注意が2つ: **1リクエストで 100 件が上限**なので watermark と相性を見ること
(`force=0` は「未取得ぶん」を返し、二度目は空になる ―― 同期の取りこぼしを作りやすいので
`force=1` と `message_id` での突き合わせのほうが安全)。もう1つはレート制限
(応答の `x-ratelimit-*` ヘッダ。300 回 / 5 分)。

**Backlog** — `https://<スペース>.backlog.jp/api/v2`。個人設定で API キーを発行する。
`GET /notifications` が**そのまま「自分宛のお知らせ」**を返すので、
掃き寄せの組み立てが要らない。コメントの投稿は
`POST /issues/{key}/comments` (`notifiedUserId` で通知先も指定できる)。

**Google Chat** — 既存の Google の OAuth クライアントに `chat.messages.readonly`
(と投稿するなら `chat.messages`) を足すだけ。スペースの一覧には
`chat.spaces.readonly` が要る。**Google Workspace 専用**で、個人の Google アカウントでは使えない。
スコープを足したら**リフレッシュトークンを取り直す**こと (既存のトークンには入っていない ――
カレンダーのときと同じ落とし穴)。

### 「部分的」と判定したもの

**LINE WORKS** — Service Account の JWT 認証と Bot API がある。ただし取れるのは
Bot が参加しているトークルームのメッセージだけで、自分宛のメッセージ全体は読めない。
Bot を業務のトークルームに入れてよいかは運用判断になる。

**Jira / Confluence** — API トークン (Basic 認証) で課題・コメントは読める。
ただし**「自分宛の通知」に相当する API が無い**ので、JQL
(`assignee = currentUser() AND updated > …`) で掃き寄せを自前で組むことになる。
メンションを漏れなく拾うのは難しい。

**Notion** — インテグレーションを作ればページとコメントは読めるが、
**受信トレイ (通知) の API が公開されていない。**「自分がメンションされた」を
起点にできないので、通知への対応という目的には届かない。

**Zoom** — チーム チャットのスコープ自体は存在する。ただし 2024 年の粒度スコープ移行で
名前が変わっており、どのアプリ種別・どのプランで自分のチャットを読めるかが
公開ドキュメントからは読み切れなかった。**アカウントを手元に用意して確かめる必要がある。**
会議の招待はカレンダー経由で拾えるので、そこは既に Google カレンダー側で足りている。

### 「不可」と判定したもの

判定の理由は**技術ではなく規約**であることが多い。回避手段は用意しない。

- **Discord** — Bot は他人の DM に到達できない。ユーザートークンを使うセルフボットは
  利用規約違反でアカウント停止の対象。自分のサーバーの特定チャンネルの監視だけなら Bot で可能
- **Messenger / WhatsApp** — Meta の API はページ・事業者番号宛の受信専用。個人の DM は対象外
- **LINE (個人)** — Messaging API は公式アカウント宛のみ。個人のトークを読む API は無い
- **Telegram** — Bot API では他人の DM を読めない。ユーザー API (MTProto) は規約上は使えるが、
  PowerShell から叩ける代物ではなく「追加インストール不要」という前提を壊す
- **X (旧 Twitter)** — DM の読み取りは有料階層に移った。用途に対して費用が見合わない

これらについては、**通知リスナー (Phase 1) で表示テキストを拾うところまでが上限**になる。
文脈の補完も、返信もできない ―― カードは立つが、閉じるのは人間の仕事になる。

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

Microsoft 365 について確認したこと（`tests\cases\Graph.Tests.ps1`。ネットワークには出ない）:

- デバイスコードの流れ — コードを出す時点では何も保存せず、サインインが済んで初めて保存する。
  待っているあいだは `authorization_pending` をエラーにしない。拒否されたら途中経過を捨てる
- **入れ替わったリフレッシュトークンを保存し直すこと。** ここが抜けると、しばらく動いたあと
  ある日 `invalid_grant` で止まる
- 別プロセス（カンバン）が繋ぎ直したら、期限を待たずに取り直すこと
- `AADSTS7000218` を「パブリック クライアント フローを許可する」への案内に翻訳すること
- 掃き寄せが、自分の発言・システムメッセージ・削除済みを落とすこと。
  watermark より古いチャットを開かないこと
- 読めない会話が 403 / 404 なら watermark を進め、429 / 5xx なら据え置くこと
- Outlook が `@odata.nextLink` を辿り、古い順に返し、上限で切れること
- 承認の要否と、投稿先・宛先が**カードから束縛されている**こと
  （投稿先の無いカードでは `send_teams_message` が呼べない）
- `POST /chats/{id}/messages` は汎用 HTTP から塞ぎ、**同じ URL の GET は通す**こと。
  ここをメソッドごとに見ないと、塞いだ瞬間にチャットの本文が取れなくなる

**未検証:** Slack の `drafts.create` と `chat.postMessage` は実データで動かせていない。
Slack の掃き寄せも、現在の Bot Token では Bot が入っているチャンネルが無いため
**0 件でしか確認できていない**（メンション判定に使う自分のユーザーIDも未設定）。
`Connect-Service.ps1 -Service slack` をもう一度流すのが最初の一歩になる。

**Microsoft 365 も実アカウントでは未検証。** 手元にテナントが無いため、
上に挙げたのはすべて応答の形を与えたうえでの確認で、実際のアプリ登録・同意・
メールの取り込み・投稿は通していない。最初の一歩は
`Connect-Service.ps1 -Service microsoft`（またはカンバンの「接続」）で、
そこで `AADSTS` 番号が出たら、その番号がそのまま直すべき設定を指している。
