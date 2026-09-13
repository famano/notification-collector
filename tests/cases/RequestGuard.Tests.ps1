# RequestGuard.Tests.ps1
# カンバンに届いた要求を通すかどうか。
#
# ここはボードの中で唯一、壊れても画面に何も出ない場所である。
# 緩めた瞬間から「普通に動いて見えるのに外から操作できる」状態になり、
# 気付く手がかりが無い。だからボードを起動せずに確かめられる形にしてある
# (起動が要る形だと、winsqlite3 の無い環境では丸ごと飛ばされてしまう)。

. "$RepoRoot\phase3\lib\RequestGuard.ps1"

$script:P = 8787

Describe 'Host の検査 (DNS リバインディング対策)' {

    It '自分自身の名前なら通す' {
        Assert-True (Test-AllowedHost '127.0.0.1:8787')
        Assert-True (Test-AllowedHost 'localhost:8787')
        Assert-True (Test-AllowedHost 'localhost')
    }

    It '知らない名前は弾く' {
        Assert-False (Test-AllowedHost 'evil.example')
        Assert-False (Test-AllowedHost 'evil.example:8787')
        # 127.0.0.1 に解決される名前を使う手口。名前そのものを見て弾く。
        Assert-False (Test-AllowedHost 'localtest.me')
    }

    It '前方一致で緩めない' {
        Assert-False (Test-AllowedHost 'localhost.evil.example')
        Assert-False (Test-AllowedHost '127.0.0.1.evil.example')
    }
}

Describe 'Origin の検査 (CSRF 対策)' {

    It '読むだけの要求は見ない (応答は同一オリジンポリシーで読めない)' {
        Assert-True (Test-AllowedOrigin -Method 'GET' -Origin 'https://evil.example' -Port $script:P)
    }

    It '自分自身のページからは通す' {
        Assert-True (Test-AllowedOrigin -Method 'POST' -Origin 'http://127.0.0.1:8787' -Port $script:P)
        Assert-True (Test-AllowedOrigin -Method 'POST' -Origin 'http://localhost:8787' -Port $script:P)
    }

    It '外のページからは弾く' {
        Assert-False (Test-AllowedOrigin -Method 'POST' -Origin 'https://evil.example' -Port $script:P)
        Assert-False (Test-AllowedOrigin -Method 'DELETE' -Origin 'https://evil.example' -Port $script:P)
    }

    It '同じ PC の別のローカルサーバからも弾く' {
        # 「localhost なら通す」にしていた頃はここが通っていた。開発サーバや
        # 他のアプリのローカル UI が出したページから、削除や送信を起こせてしまう。
        Assert-False (Test-AllowedOrigin -Method 'POST' -Origin 'http://localhost:3000' -Port $script:P)
        Assert-False (Test-AllowedOrigin -Method 'POST' -Origin 'http://127.0.0.1:3000' -Port $script:P)
    }

    It 'ポートが変わっても、そのときのポートだけを許す' {
        Assert-True  (Test-AllowedOrigin -Method 'POST' -Origin 'http://localhost:8790' -Port 8790)
        Assert-False (Test-AllowedOrigin -Method 'POST' -Origin 'http://localhost:8787' -Port 8790)
    }

    It 'Origin の無い要求は通る (ここでは弾けない、という事実を固定する)' {
        # ブラウザは状態を変える要求に必ず Origin を付ける。付いていないのは
        # ブラウザ以外 ―― 同じ PC のネイティブなプロセスは、この層では止められない
        # (弾いても詐称されるだけで防御にならない)。守っているのは
        # 「資格情報そのものを API から返さない」という別の作りのほう。
        Assert-True (Test-AllowedOrigin -Method 'POST' -Origin '' -Port $script:P)
        Assert-True (Test-AllowedOrigin -Method 'POST' -Origin $null -Port $script:P)
    }
}
