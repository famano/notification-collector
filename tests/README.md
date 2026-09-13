# tests

追加インストール不要のテスト。Pester は使わない (PowerShell 5.1 同梱版では
新しい書き方が動かず、「追加インストールは不要」という前提が崩れるため)。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
.\tests\Run-Tests.ps1 -Filter TaskStore   # ファイル名で絞る
```

- **外部サービスも API キーも要らない。** ネットワークには一切出ない。
- DB は一時フォルダに作って捨てる。`phase2\data\tasks.db` には触らない。
- 失敗があれば終了コード 1。

## 何を見ているか

| ケース | 見ているもの |
|---|---|
| `Syntax.Tests.ps1` | 全 `.ps1` が構文として通り、UTF-8 BOM 付きで保存されていること |
| `Dossier.Tests.ps1` | 「同じ件か」を決める `subject_key` と、件をまたぐ台帳 |
| `TaskStore.Tests.ps1` | 通知と同期の突き合わせ、楽観ロック、ワーカーへの受け渡し、削除、承認 |
| `WorkTools.Tests.ps1` | 危険度の判定 (承認の要否) と人間送りのゲート |
| `HttpAction.Tests.ps1` | 資格情報をホストから決めること、送信の口を汎用ツールから塞ぐこと |
| `SourceAccess.Tests.ps1` | 本文からのリンク抽出と切り詰め |

選び方の基準は「壊れても静かなところ」。承認の要否や宛先の束縛は、
壊れていても画面上は普通に動いて見えるのに、外に出るものが変わる。

## 書き足す

`tests\cases\<名前>.Tests.ps1` を置けば自動で拾われる。

```powershell
. "$RepoRoot\phase2\lib\Dossier.ps1"      # $RepoRoot は実行側が渡す

Describe 'まとまりの名前' {
    It '何が成り立つべきか' {
        Assert-Equal '期待' (何かの呼び出し)
    }
}
```

使える検査: `Assert-True` / `Assert-False` / `Assert-Equal` / `Assert-NotEqual` /
`Assert-Null` / `Assert-NotNull` / `Assert-Match` / `Assert-Throws`。
DB が要るときは `New-TestStore` と `Close-TestStore`、環境が足りないときは
`Skip-It`。環境の有無は `Test-SqliteAvailable` で判定できる。

## 注意

- ネットワークに出るテストは書かないこと。トークンの要るテストは、
  利用者の実データを踏むので `Skip-It` で飛ばす。
- テストファイルも **UTF-8 BOM 付き**で保存すること (`Syntax.Tests.ps1` が見ている)。
