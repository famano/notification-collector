# SetupFlow.ps1
# 「資格情報が入った」あとの後始末。
#
# 設定カードの狙いは「1枚直せば同種がまとめて通る」だった。
# 入力できるようになっただけでは半分しか叶わない ―― 止まっているカードを
# 1枚ずつ手で要対応に戻すのでは、8枚分の手数がそのまま残る。
#
# ここでやること:
#   1. その設定を待って止まっていたカードを要対応に戻す
#   2. 設定カードそのものを完了にする
#   3. 台帳の「このサービスは未設定」を打ち消す
#
# 3 が要るのは、台帳がワーカーに毎回渡されるため。
# 「GitHub のトークンが無いので操作できません」が残ったままだと、
# 設定したあともワーカーがそれを前提に計画を立てる。
#
# 呼び出し側 (カンバン) が TaskStore / Dossier / ServiceSetup を読み込んでいる前提。

function Invoke-SetupCompletion {
    <#
      .SYNOPSIS
        資格情報が入った直後に呼ぶ。止まっていたカードを動かす。
      .OUTPUTS
        [pscustomobject] resumed (再開したカード数) / setupTaskId / titles
    #>
    param(
        [Parameter(Mandatory)] $Conn,
        [Parameter(Mandatory)] [string] $Service,
        [string] $Account
    )

    $setup = Get-OpenSetupTask -Conn $Conn -Service $Service
    $setupId = if ($setup) { [int] $setup['id'] } else { 0 }

    $waiting = @(Get-TasksWaitingForSetup -Conn $Conn -Service $Service -SetupTaskId $setupId)
    $titles = @()
    foreach ($t in $waiting) {
        [void] (Resume-Task -Conn $Conn -TaskId ([int] $t['id']) `
                    -Reason ("{0} の設定が入ったので、要対応に戻しました。" -f $Service))
        $titles += [string] $t['title']
    }

    if ($setup) {
        $note = if ($Account) {
            ("カンバンから設定しました ({0} として接続)。" -f $Account)
        } else { 'カンバンから設定しました。' }
        if ($waiting.Count -gt 0) {
            $note += ("`n待っていたカード {0} 枚を要対応に戻しました。" -f $waiting.Count)
            foreach ($x in $titles) { $note += "`n- " + $x }
        }
        [void] (Update-TaskFields -Conn $Conn -TaskId $setupId -Fields @{ user_edited = $note; human_step = $null })
        Add-TaskActivity -Conn $Conn -TaskId $setupId -Kind 'done' -Message $note
        [void] (Set-TaskColumn -Conn $Conn -TaskId $setupId -Column 'done')
    }

    # 台帳の打ち消し。件をまたいで効く事実なので、サービス単位で残す。
    if (Get-Command Add-DossierNote -ErrorAction SilentlyContinue) {
        [void] (Add-DossierNote -Conn $Conn -SubjectKey ('svc:' + $Service) -Kind 'credential' `
            -Note ("{0} の資格情報は設定済みです{1}。以前の「未設定」の記録は無効です。" -f `
                    $Service, $(if ($Account) { " ($Account)" } else { '' })))
    }

    return [pscustomobject]@{
        resumed = $waiting.Count
        setupTaskId = $setupId
        titles = $titles
    }
}
