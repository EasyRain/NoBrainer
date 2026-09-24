# 一把跑完 NoBrainer 仓库里的离线检查。
#
#   powershell -File tools\run_checks.ps1
#   （Windows PowerShell 5.1 需要这个 .ps1 带 UTF-8 BOM，否则会把中文读成乱码并报"缺少引号"）
#
# 1) balance 模块的离线冒烟测试（LuaJIT + 游戏 API 桩，14 条断言）—— 改 balance 前后必跑
# 2) 钩子体检 —— 对着最新的游戏日志核对仓库里注册的每个钩子到底挂上了没有
#    （游戏更新后跑一次，DEAD/ERROR/MISSING 就是需要修的地方）

$ErrorActionPreference = 'Continue'
$tools = $PSScriptRoot
$repo = Split-Path -Parent $tools

# luajit：先用 PATH 上的；没有再用下面这个本机默认路径（换机器请改这里，或删掉）
$luajit = $null
$cmd = Get-Command luajit -ErrorAction SilentlyContinue
if ($cmd) {
    $luajit = $cmd.Source
} else {
    $fallback = 'D:\Tools\Lua\luajit\src\luajit.exe'
    if (Test-Path $fallback) { $luajit = $fallback }
}

$failed = 0

Write-Host '== 1) 离线冒烟测试 (balance) ==' -ForegroundColor Cyan
if ($luajit) {
    & $luajit (Join-Path $tools 'smoke_balance.lua')
    if ($LASTEXITCODE -ne 0) { $failed++ }
} else {
    Write-Host '找不到 luajit：装一个放进 PATH，或改本脚本顶部的 $luajit 路径' -ForegroundColor Yellow
    $failed++
}

Write-Host ''
Write-Host '== 2) 钩子体检（对最新日志） ==' -ForegroundColor Cyan
python (Join-Path $tools 'check_hooks.py')
if ($LASTEXITCODE -ne 0) { $failed++ }

Write-Host ''
Write-Host '== 3) 设置项体检（设置项 / 本地化键对得上吗） ==' -ForegroundColor Cyan
python (Join-Path $tools 'check_settings.py')
if ($LASTEXITCODE -ne 0) { $failed++ }

Write-Host ''
if ($failed -eq 0) {
    Write-Host '全部通过' -ForegroundColor Green
} else {
    Write-Host "$failed 项检查没过" -ForegroundColor Red
}
exit $failed
