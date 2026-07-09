# 需要以管理员权限运行
# 功能：为有线网卡添加临时内网路由，退出时自动删除
# 改进版：输入校验 / 多网卡选择 / try-finally 异常清理 / 直接调用 route 避免 Invoke-Expression

# 检查管理员权限
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "请以管理员身份运行此脚本！" -ForegroundColor Red
    exit 1
}

# ============================================================
# 辅助函数
# ============================================================

# 验证 IPv4 地址格式和范围
function Test-IPv4Address {
    param([string]$Address)
    if ($Address -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') {
        return $false
    }
    return [int]$Matches[1] -le 255 -and
           [int]$Matches[2] -le 255 -and
           [int]$Matches[3] -le 255 -and
           [int]$Matches[4] -le 255
}

# 检查是否为有效的子网掩码（连续 1 + 连续 0）
function Test-SubnetMask {
    param([string]$Mask)
    if (-not (Test-IPv4Address $Mask)) { return $false }
    $parts = $Mask -split '\.'
    $bin = [long]0
    foreach ($p in $parts) { $bin = ($bin -shl 8) -bor [int]$p }

    # 255.255.255.255 和 0.0.0.0 不是有效子网掩码
    if ($bin -eq 0xFFFFFFFF -or $bin -eq 0) { return $false }

    # 取反后加 1，如果是 2 的幂则是有效掩码
    $inverted = (-bnot $bin) -band 0xFFFFFFFF
    return ($inverted + 1 -band $inverted) -eq 0
}

# ============================================================
# 1. 自动检测 / 手动选择有线网卡的默认网关
# ============================================================

$defaultRoutes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" | Where-Object {
    $_.NextHop -ne "0.0.0.0" -and $_.InterfaceAlias -notlike "*Loopback*"
}

if ($defaultRoutes.Count -eq 0) {
    Write-Host "未找到任何活跃的默认路由（请检查网络连接）。" -ForegroundColor Red
    exit 1
}

$gateway    = $null
$ifIndex    = $null
$ifAlias    = $null

# 优先自动匹配有线网卡
$ethRoute = $defaultRoutes | Where-Object {
    $_.InterfaceAlias -like "*以太网*" -or
    $_.InterfaceAlias -like "*Ethernet*" -or
    $_.InterfaceAlias -like "*有线*" -or
    $_.InterfaceAlias -like "*LAN*"
} | Select-Object -First 1

if ($ethRoute) {
    $gateway = $ethRoute.NextHop
    $ifIndex = $ethRoute.InterfaceIndex
    $ifAlias = $ethRoute.InterfaceAlias
    Write-Host "已检测到有线网卡：" -ForegroundColor Green
    Write-Host "  [$ifAlias]  网关：$gateway  （接口索引：$ifIndex）" -ForegroundColor Green
} else {
    Write-Host "未自动检测到有线网卡。当前所有默认路由：" -ForegroundColor Yellow
    for ($i = 0; $i -lt $defaultRoutes.Count; $i++) {
        Write-Host "  [$i]  $($defaultRoutes[$i].InterfaceAlias)    → 网关 $($defaultRoutes[$i].NextHop)" -ForegroundColor Gray
    }
    Write-Host ""
    $userInput = Read-Host "请选择序号（直接回车默认 0）"
    if ([string]::IsNullOrWhiteSpace($userInput)) { $userInput = "0" }

    # 兼容 PS5（无三元运算符）和 PS7
    $parsed = 0
    [int]::TryParse($userInput, [ref]$parsed) | Out-Null

    if ($parsed -ge 0 -and $parsed -lt $defaultRoutes.Count) {
        $selected = $defaultRoutes[$parsed]
        $gateway  = $selected.NextHop
        $ifIndex  = $selected.InterfaceIndex
        $ifAlias  = $selected.InterfaceAlias
        Write-Host "已选择：[$ifAlias]  网关：$gateway" -ForegroundColor Green
    } else {
        Write-Host "序号无效，将手动输入网关。" -ForegroundColor Yellow
        $gateway = Read-Host "请输入有线网卡的网关 IP"
    }
}

# ============================================================
# 2. 输入目标内网网段
# ============================================================

$net = ""
while ($true) {
    $net = Read-Host "`n请输入要访问的内网目标网段（例如 10.99.0.0）"
    if (Test-IPv4Address $net) { break }
    Write-Host "格式错误，请输入合法的 IPv4 地址（0~255 的四组数字，以点分隔）。" -ForegroundColor Red
}

# ============================================================
# 3. 输入子网掩码
# ============================================================

$mask = Read-Host "请输入子网掩码（直接回车则使用 255.255.255.0）"
if ([string]::IsNullOrWhiteSpace($mask)) {
    $mask = "255.255.255.0"
} elseif (-not (Test-SubnetMask $mask)) {
    Write-Host "子网掩码格式不合法，将使用默认值 255.255.255.0。" -ForegroundColor Yellow
    $mask = "255.255.255.0"
}

# ============================================================
# 4. 确认
# ============================================================

Write-Host ""
Write-Host "==========  路由信息确认  ==========" -ForegroundColor Cyan
Write-Host "  目标网段：  $net / $mask"
Write-Host "  网关：      $gateway"
if ($ifAlias) { Write-Host "  出口网卡：  $ifAlias  （索引 $ifIndex）" }
Write-Host "====================================" -ForegroundColor Cyan

$confirm = Read-Host "`n确认添加？（直接回车确认 / 输入 n 取消）"
if ($confirm -match '^(n|no|N|NO)$') {
    Write-Host "已取消操作。" -ForegroundColor Yellow
    exit 0
}

# ============================================================
# 5. 添加路由 + try-finally 确保退出时清理
# ============================================================

try {
    # 构造命令并执行
    if ($ifIndex) {
        route add $net mask $mask $gateway IF $ifIndex
    } else {
        route add $net mask $mask $gateway
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "路由添加失败（exit code: $LASTEXITCODE），请检查输入是否正确。" -ForegroundColor Red
        Write-Host "常见原因：目标网段与现有路由冲突、网关不可达、掩码格式不正确。" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "`n路由添加成功！" -ForegroundColor Green
    Write-Host "内网目标流量将走有线网卡，其余流量走 WiFi。" -ForegroundColor Green
    Write-Host ""
    Write-Host "临时路由已生效，关闭此窗口或按任意键将自动删除路由。" -ForegroundColor Yellow
    Write-Host "按 Ctrl+C 也会自动清理路由（不残留）。" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "按任意键删除路由并退出..." -ForegroundColor Yellow

    # 等待用户按键
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

}
finally {
    # 无论正常退出还是 Ctrl+C，都会执行到这里
    Write-Host ""
    Write-Host "正在清理路由..." -ForegroundColor Cyan
    route delete $net

    if ($LASTEXITCODE -eq 0) {
        Write-Host "路由已删除，脚本退出。" -ForegroundColor Green
    } else {
        Write-Host "路由可能已被删除或不存在，无需担心。" -ForegroundColor Yellow
    }
}
