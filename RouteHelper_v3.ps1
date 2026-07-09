# 需要以管理员权限运行
# 功能：内网/特殊路由管理工具 —— 添加路由 + 查看路由 + 删除路由

# ============================================================
# 辅助函数
# ============================================================

function Test-Admin {
    $identity = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
}

function Test-IPv4Address {
    param([string]$Address)
    if ($Address -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    return [int]$Matches[1] -le 255 -and
           [int]$Matches[2] -le 255 -and
           [int]$Matches[3] -le 255 -and
           [int]$Matches[4] -le 255
}

function Test-SubnetMask {
    param([string]$Mask)
    if (-not (Test-IPv4Address $Mask)) { return $false }
    $parts = $Mask -split '\.'
    $bin = [long]0
    foreach ($p in $parts) { $bin = ($bin -shl 8) -bor [int]$p }
    if ($bin -eq 0xFFFFFFFF -or $bin -eq 0) { return $false }
    $inverted = (-bnot $bin) -band 0xFFFFFFFF
    return ($inverted + 1 -band $inverted) -eq 0
}

function Show-Menu {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "        RouteHelper — 路由管理工具" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1.   添加路由" -ForegroundColor White
    Write-Host "        （为指定网卡添加临时路由，退出自动清理）"
    Write-Host ""
    Write-Host "  2.   查看路由" -ForegroundColor White
    Write-Host "        （按条件筛选当前 IPv4 路由表）"
    Write-Host ""
    Write-Host "  3.   删除路由" -ForegroundColor White
    Write-Host "        （手动删除一条路由）"
    Write-Host ""
    Write-Host "  4.   清理脚本添加的临时路由" -ForegroundColor White
    Write-Host "        （删除本次运行中通过此脚本添加的所有路由）"
    Write-Host ""
    Write-Host "  5.   退出" -ForegroundColor White
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
}

# ============================================================
# 功能 1：添加路由
# ============================================================

$script:addedRoutes = @()   # 记录本次脚本添加的路由，用于清理

function Add-RouteInteractively {
    # ---------- 检测可用网关 ----------
    $defaultRoutes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" | Where-Object {
        $_.NextHop -ne "0.0.0.0" -and $_.InterfaceAlias -notlike "*Loopback*"
    }

    if ($defaultRoutes.Count -eq 0) {
        Write-Host "未找到任何活跃的默认路由，请检查网络连接。" -ForegroundColor Red
        pause
        return
    }

    # 列出所有可用的出口网卡
    Write-Host "`n检测到以下可用的默认路由（出口网卡）：" -ForegroundColor Cyan
    Write-Host "  ----------------------------------------------" -ForegroundColor Gray
    for ($i = 0; $i -lt $defaultRoutes.Count; $i++) {
        $r = $defaultRoutes[$i]
        Write-Host "  [$i]  $($r.InterfaceAlias)" -ForegroundColor White
        Write-Host "       网关：$($r.NextHop)    接口索引：$($r.InterfaceIndex)" -ForegroundColor Gray
        Write-Host "       接口描述：$( (Get-NetAdapter -InterfaceIndex $r.InterfaceIndex).InterfaceDescription )" -ForegroundColor DarkGray
        Write-Host "  ----------------------------------------------" -ForegroundColor Gray
    }

    $selStr = Read-Host "`n请选择出口网卡（序号，直接回车默认 0）"
    if ([string]::IsNullOrWhiteSpace($selStr)) { $selStr = "0" }
    $sel = 0
    [int]::TryParse($selStr, [ref]$sel) | Out-Null

    if ($sel -lt 0 -or $sel -ge $defaultRoutes.Count) {
        Write-Host "序号无效。" -ForegroundColor Red
        pause
        return
    }

    $selected    = $defaultRoutes[$sel]
    $gateway     = $selected.NextHop
    $ifIndex     = $selected.InterfaceIndex
    $ifAlias     = $selected.InterfaceAlias

    Write-Host "`n已选择：$ifAlias  （网关 $gateway）" -ForegroundColor Green

    # ---------- 输入目标网段 ----------
    Write-Host ""
    Write-Host "请输入要访问的" -NoNewline; Write-Host "目标网络" -ForegroundColor Yellow -NoNewline
    Write-Host "（例如 10.99.0.0，或输入 0.0.0.0 表示将所有流量改走此网卡）"
    $net = ""
    while ($true) {
        $net = Read-Host "目标网络"
        if (Test-IPv4Address $net) { break }
        Write-Host "格式错误，请输入合法的 IPv4 地址。" -ForegroundColor Red
    }

    # ---------- 输入子网掩码 ----------
    $mask = Read-Host "`n子网掩码（直接回车则使用 255.255.255.0）"
    if ([string]::IsNullOrWhiteSpace($mask)) {
        $mask = "255.255.255.0"
    } elseif (-not (Test-SubnetMask $mask)) {
        Write-Host "子网掩码格式不合法，将使用默认值 255.255.255.0。" -ForegroundColor Yellow
        $mask = "255.255.255.0"
    }

    # ---------- 可选 metric ----------
    $metricStr = Read-Host "`n跃点数 Metric（留空自动，数值越小优先级越高）"
    $metric = $null
    if (-not [string]::IsNullOrWhiteSpace($metricStr)) {
        $parsed = 0
        if ([int]::TryParse($metricStr, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 9999) {
            $metric = $parsed
        } else {
            Write-Host "跃点数无效（须为 1~9999 整数），将使用默认值。" -ForegroundColor Yellow
        }
    }

    # ---------- 可选描述备注 ----------
    $note = Read-Host "`n备注（可选，仅用于本次会话显示，如：公司内网 / 测试环境）"

    # ---------- 确认 ----------
    Write-Host ""
    Write-Host "=========  确认路由信息  =========" -ForegroundColor Cyan
    Write-Host "  目标网络：    $net / $mask"
    if ($metric) { Write-Host "  跃点数：      $metric" }
    Write-Host "  出口网卡：    $ifAlias  （索引 $ifIndex）"
    Write-Host "  网关：        $gateway"
    if ($note) { Write-Host "  备注：        $note" }
    Write-Host "==================================" -ForegroundColor Cyan

    $confirm = Read-Host "`n确认添加？（直接回车确认 / 输入 n 取消）"
    if ($confirm -match '^(n|no|N|NO)$') {
        Write-Host "已取消。" -ForegroundColor Yellow
        pause
        return
    }

    # ---------- 执行添加 ----------
    if ($metric) {
        route add $net mask $mask $gateway IF $ifIndex metric $metric
    } else {
        route add $net mask $mask $gateway IF $ifIndex
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n路由添加失败（exit code: $LASTEXITCODE）。" -ForegroundColor Red
        Write-Host "常见原因：目标网段与现有路由冲突、网关不可达。" -ForegroundColor Yellow
    } else {
        Write-Host "`n? 路由添加成功！" -ForegroundColor Green
        $entry = @{ Net = $net; Mask = $mask; Gateway = $gateway; Interface = $ifAlias }
        $script:addedRoutes += $entry
        Write-Host "已记录以便退出时清理。当前待清理路由数：$($script:addedRoutes.Count)" -ForegroundColor Yellow
    }

    pause
}

# ============================================================
# 功能 2：查看路由
# ============================================================

function Show-RoutesInteractively {
    Clear-Host
    Write-Host "=====  查看路由表  =====" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "选择筛选条件："
    Write-Host "  [0]  显示所有 IPv4 路由"
    Write-Host "  [1]  仅显示默认路由（0.0.0.0/0）"
    Write-Host "  [2]  仅显示指定网卡的路由"
    Write-Host "  [3]  仅显示指定目标网段的路由"
    Write-Host "  [4]  仅显示非默认路由（非 0.0.0.0/0）"
    Write-Host ""

    $opt = Read-Host "请选择（直接回车默认 0）"
    if ([string]::IsNullOrWhiteSpace($opt)) { $opt = "0" }

    $routes = $null

    switch ($opt) {
        "0" {
            $routes = Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.NextHop -ne "0.0.0.0" -or $_.DestinationPrefix -eq "0.0.0.0/0" }
            $title = "所有 IPv4 路由"
        }
        "1" {
            $routes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0"
            $title = "默认路由（0.0.0.0/0）"
        }
        "2" {
            $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceAlias -notlike "*Loopback*" }
            Write-Host "`n当前活跃的网卡：" -ForegroundColor Cyan
            for ($i = 0; $i -lt $adapters.Count; $i++) {
                Write-Host "  [$i]  $($adapters[$i].InterfaceAlias)  ($($adapters[$i].InterfaceDescription))" -ForegroundColor White
            }
            $s = Read-Host "`n请选择网卡序号"
            $idx = 0
            [int]::TryParse($s, [ref]$idx) | Out-Null
            if ($idx -ge 0 -and $idx -lt $adapters.Count) {
                $ifIdx = $adapters[$idx].InterfaceIndex
                $routes = Get-NetRoute -AddressFamily IPv4 -InterfaceIndex $ifIdx | Where-Object { $_.NextHop -ne "0.0.0.0" -or $_.DestinationPrefix -eq "0.0.0.0/0" }
                $title = "路由 — $($adapters[$idx].InterfaceAlias)"
            } else {
                Write-Host "序号无效。" -ForegroundColor Red
                pause
                return
            }
        }
        "3" {
            $dest = Read-Host "请输入目标网段（例如 10.99.0.0/16 或 10.99.0.0）"
            $routes = Get-NetRoute -AddressFamily IPv4 | Where-Object {
                ($_.NextHop -ne "0.0.0.0" -or $_.DestinationPrefix -eq "0.0.0.0/0") -and
                $_.DestinationPrefix -like "$dest*"
            }
            if ($routes.Count -eq 0) {
                # 精确匹配试试
                $routes = Get-NetRoute -AddressFamily IPv4 | Where-Object {
                    ($_.NextHop -ne "0.0.0.0" -or $_.DestinationPrefix -eq "0.0.0.0/0") -and
                    $_.DestinationPrefix -like "$dest*"
                }
            }
            $title = "匹配「$dest」的路由"
        }
        "4" {
            $routes = Get-NetRoute -AddressFamily IPv4 | Where-Object {
                $_.DestinationPrefix -ne "0.0.0.0/0" -and $_.NextHop -ne "0.0.0.0"
            }
            $title = "非默认 IPv4 路由"
        }
        default {
            $routes = Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.NextHop -ne "0.0.0.0" -or $_.DestinationPrefix -eq "0.0.0.0/0" }
            $title = "所有 IPv4 路由"
        }
    }

    if (-not $routes -or $routes.Count -eq 0) {
        Write-Host "`n未找到匹配的路由。" -ForegroundColor Yellow
        pause
        return
    }

    Write-Host "`n=====  $title  =====（共 $($routes.Count) 条）" -ForegroundColor Cyan

    # 格式化输出
    $routes | Select-Object @{N="目标网络";E={$_.DestinationPrefix}},
                             @{N="网关";E={$_.NextHop}},
                             @{N="接口索引";E={$_.InterfaceIndex}},
                             @{N="接口名称";E={$_.InterfaceAlias}},
                             @{N="跃点数";E={$_.RouteMetric}},
                             @{N="协议";E={$_.Protocol}},
                             @{N="存储类型";E={$_.Store}} |
              Format-Table -AutoSize -Wrap

    Write-Host "按任意键返回主菜单..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ============================================================
# 功能 3：删除路由
# ============================================================

function Remove-RouteInteractively {
    Write-Host "`n=====  删除路由  =====" -ForegroundColor Cyan

    # 先显示当前非默认路由供参考
    $currentRoutes = Get-NetRoute -AddressFamily IPv4 | Where-Object {
        $_.DestinationPrefix -ne "0.0.0.0/0" -and
        $_.NextHop -ne "0.0.0.0"
    }

    if ($currentRoutes.Count -gt 0) {
        Write-Host "`n当前非默认路由：" -ForegroundColor Cyan
        $currentRoutes | Select-Object @{N="目标网络";E={$_.DestinationPrefix}},
                                        @{N="网关";E={$_.NextHop}},
                                        @{N="接口";E={$_.InterfaceAlias}},
                                        @{N="跃点数";E={$_.RouteMetric}} |
                       Format-Table -AutoSize
    }

    Write-Host "`n输入要删除的目标网段（支持 CIDR 格式，如 10.99.0.0/16 或 10.99.0.0）：" -ForegroundColor Yellow
    $dest = Read-Host "目标网段"

    if ([string]::IsNullOrWhiteSpace($dest)) {
        Write-Host "已取消。" -ForegroundColor Yellow
        pause
        return
    }

    # 处理 CIDR 格式，route delete 需要去掉掩码位
    $deleteTarget = $dest -replace '/.*$', ''

    Write-Host "执行：route delete $deleteTarget" -ForegroundColor Gray
    route delete $deleteTarget

    if ($LASTEXITCODE -eq 0) {
        Write-Host "? 路由已删除。" -ForegroundColor Green
    } else {
        Write-Host "删除失败，目标路由可能不存在或权限不足。" -ForegroundColor Yellow
    }

    pause
}

# ============================================================
# 功能 4：清理脚本添加的所有路由
# ============================================================

function Clear-AddedRoutes {
    if ($script:addedRoutes.Count -eq 0) {
        Write-Host "`n本次脚本运行中未添加过路由，无需清理。" -ForegroundColor Yellow
        pause
        return
    }

    Write-Host "`n=====  清理临时路由  =====" -ForegroundColor Cyan
    Write-Host "以下路由将被删除："
    $script:addedRoutes | ForEach-Object {
        Write-Host "  $($_.Net) / $($_.Mask)  →  $($_.Interface)  (网关 $($_.Gateway))" -ForegroundColor Gray
    }

    $confirm = Read-Host "`n确认删除以上所有路由？（直接回车确认 / 输入 n 取消）"
    if ($confirm -match '^(n|no|N|NO)$') {
        Write-Host "已取消。" -ForegroundColor Yellow
        pause
        return
    }

    $deletedCount = 0
    $failCount = 0
    foreach ($r in $script:addedRoutes) {
        route delete $r.Net
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ?  $($r.Net)" -ForegroundColor Green
            $deletedCount++
        } else {
            Write-Host "  ?  $($r.Net) （可能已被手动删除）" -ForegroundColor Yellow
            $failCount++
        }
    }

    Write-Host "`n清理完成：成功 $deletedCount 条" -ForegroundColor Green
    if ($failCount -gt 0) { Write-Host "            失败/不存在 $failCount 条" -ForegroundColor Yellow }

    $script:addedRoutes = @()
    pause
}

# ============================================================
# 主体：菜单循环 + 退出时清理
# ============================================================

# 检查管理员权限
if (-not (Test-Admin)) {
    Write-Host "请以管理员身份运行此脚本！" -ForegroundColor Red
    Write-Host "右键点击 → 使用 PowerShell 运行 或以管理员身份启动 PowerShell 后执行。" -ForegroundColor Yellow
    exit 1
}

$exitRequested = $false

while (-not $exitRequested) {
    Show-Menu
    $choice = Read-Host "`n请输入选项（1~5）"

    switch ($choice) {
        "1" { Add-RouteInteractively }
        "2" { Show-RoutesInteractively }
        "3" { Remove-RouteInteractively }
        "4" { Clear-AddedRoutes }
        "5" {
            $exitRequested = $true
            if ($script:addedRoutes.Count -gt 0) {
                Write-Host "`n退出前是否清理脚本添加的 $($script:addedRoutes.Count) 条临时路由？" -ForegroundColor Yellow
                $cleanConfirm = Read-Host "直接回车清理 / 输入 n 保留"
                if ($cleanConfirm -notmatch '^(n|no|N|NO)$') {
                    foreach ($r in $script:addedRoutes) {
                        route delete $r.Net | Out-Null
                    }
                    Write-Host "已清理 $($script:addedRoutes.Count) 条路由。" -ForegroundColor Green
                } else {
                    Write-Host "路由已保留，可通过菜单选项 4 或手动 route delete 清理。" -ForegroundColor Yellow
                }
            }
            Write-Host "`n脚本已退出。" -ForegroundColor Green
        }
        default {
            Write-Host "无效选项，请输入 1~5。" -ForegroundColor Red
            pause
        }
    }
}
