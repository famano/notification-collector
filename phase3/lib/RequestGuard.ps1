# RequestGuard.ps1
# カンバンに届いた要求を通すかどうかの判定。
#
# なぜ切り出すか:
#   ここはボードの中で唯一、壊れても画面に何も出ない場所である。緩めた瞬間から
#   「普通に動いているように見えるが、外から操作できる」状態になり、
#   気付く手がかりが無い。要求ループの中に直接書いてあると、
#   ボードを起動しないと確かめられず、結局確かめられない。
#
# 何を防げるか:
#   - DNS リバインディング … 127.0.0.1 に解決される名前でスクリプトを走らせ、
#     同一オリジンとして localhost を叩く手口。Host ヘッダを見て弾く
#   - CSRF … 外のページから状態を変える要求を出させる手口。Origin を見て弾く。
#     応答は同一オリジンポリシーで読めないが、**起こす方は読めなくても成立する**
#
# 何を防げないか (ここを誤解しないこと):
#   **同じ PC で動くネイティブなプロセスは素通りする。** Origin はブラウザが
#   付けるヘッダであって、curl 相当のものは付けないし、好きに詐称もできる。
#   この層はブラウザ経由の攻撃だけを見ている。ローカルのプロセスに対しては
#   「資格情報そのものを API から返さない」ことで被害を抑えている。

function Test-AllowedHost {
    <#
      .SYNOPSIS
        Host ヘッダがこの PC 自身を指しているか。
      .DESCRIPTION
        HttpListener は 127.0.0.1 / localhost のプレフィックスしか持たないので
        実際には二重になっているが、束ね方を変えたときに黙って開くのを防ぐ。
    #>
    param([string] $HostHeader)
    # Host が無いのは HTTP/1.0 など。ブラウザは必ず付ける。
    if (-not $HostHeader) { return $true }
    return ($HostHeader -match '^(localhost|127\.0\.0\.1)(:\d+)?$')
}

function Test-AllowedOrigin {
    <#
      .SYNOPSIS
        状態を変える要求の出どころが、このカンバン自身か。
      .DESCRIPTION
        許すのは**自分自身のポートだけ**。以前は localhost ならポートを問わず
        通していたが、それでは同じ PC の別のローカルサーバ (開発サーバ、
        他のアプリのローカル UI) が出したページから、削除や送信を起こせてしまう ――
        Origin が http://localhost:3000 でも「localhost だから」で通っていた。

        Origin が無い要求は通す。ブラウザは状態を変える要求に必ず付けるので、
        付いていないのはブラウザ以外 ―― そこはこの層では弾けない
        (弾いても Origin を詐称されるだけで、防御にならない)。
    #>
    param([string] $Method, [string] $Origin, [int] $Port)
    if ($Method -eq 'GET') { return $true }
    if (-not $Origin) { return $true }
    $self = @(("http://127.0.0.1:{0}" -f $Port), ("http://localhost:{0}" -f $Port))
    return ($self -contains $Origin.TrimEnd('/'))
}
