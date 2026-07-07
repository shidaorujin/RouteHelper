# 需要以管理员权限运行
# 功能：为有线网卡添加临时内网路由，退出时自动删除

# 检查是否管理员
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "请以管理员身份运行此脚本！" -ForegroundColor Red
    exit 1
}

# 1. 获取有线网卡（以太网）的默认网关
$adapter = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" | Where-Object { $_.InterfaceAlias -like "*以太网*" -or $_.InterfaceAlias -like "*Ethernet*" } | Select-Object -First 1

if (-not $adapter) {
    Write-Host "未找到有线网卡的默认网关，请手动输入网关地址：" -ForegroundColor Yellow
    $gateway = Read-Host "网关 IP"
} else {
    $gateway = $adapter.NextHop
    Write-Host "检测到有线网关：$gateway" -ForegroundColor Green
}

# 2. 输入目标内网网段和掩码
$net = Read-Host "请输入要访问的内网目标网段（例如 10.99.0.0）"
$mask = Read-Host "请输入子网掩码（直接回车则使用 255.255.255.0）"
if ([string]::IsNullOrWhiteSpace($mask)) { $mask = "255.255.255.0" }

# 3. 添加路由（不持久化，方便删除）
$routeCmd = "route add $net mask $mask $gateway"
Write-Host "执行命令：$routeCmd" -ForegroundColor Cyan
Invoke-Expression $routeCmd

if ($LASTEXITCODE -ne 0) {
    Write-Host "路由添加失败，请检查输入是否正确。" -ForegroundColor Red
    exit 1
}

Write-Host "路由添加成功！此时内网流量会走有线网卡。" -ForegroundColor Green
Write-Host "按任意键将删除该路由并退出脚本..." -ForegroundColor Yellow

# 等待用户按键
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

# 4. 删除路由
$deleteCmd = "route delete $net"
Write-Host "执行命令：$deleteCmd" -ForegroundColor Cyan
Invoke-Expression $deleteCmd

Write-Host "路由已删除，脚本退出。" -ForegroundColor Green