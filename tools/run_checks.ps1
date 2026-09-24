# 一把跑完 NoBrainer 仓库里的离线检查。
#
#   powershell -File tools\run_checks.ps1
#   （本机只有 Windows PowerShell 5.1、没有 pwsh；这个 .ps1 带 UTF-8 BOM，
#     不然 5.1 会把中文读成乱码并报"缺少引号"）
#
# 1) balance 模块的离线冒烟测试（LuaJIT + 游戏 API 桩，14 条断言）—— 改 balance 前后必跑
# 2) 钩子体检 —— 对着最新的游戏日志核对仓库里注册的每个钩子到底挂上了没有
#    （游戏更新后跑一次，DEAD/ERROR/MISSING 就是需要修的地方）

$ErrorActionPreference = 'Continue'
$tools = $PSScriptRoot
$repo = Split-Path -Parent $tools

$luajit = 'D:\Tools\Lua\luajit\src\luajit.exe'
if (-not (Test-Path $luajit)) {
    $cmd = Get-Command luajit -ErrorAction SilentlyContinue
    if ($cmd) { $luajit = $cmd.Source } else { $luajit = $null }
}

$failed = 0

Write-Host '== 1) 离线冒烟测试 (balance) ==' -ForegroundColor Cyan
if ($luajit) {
    & $luajit (Join-Path $tools 'smoke_balance.lua')
    if ($LASTEXITCODE -ne 0) { $failed++ }
} else {
    Write-Host '找不到 luajit（本机在 D:\Tools\Lua\luajit\src\luajit.exe）' -ForegroundColor Yellow
    $failed++
}

Write-Host ''
Write-Host '== 2) 钩子体检（对最新日志） ==' -ForegroundColor Cyan
python (Join-Path $tools 'check_hooks.py')
if ($LASTEXITCODE -ne 0) { $failed++ }

Write-Host ''
if ($failed -eq 0) {
    Write-Host '全部通过' -ForegroundColor Green
} else {
    Write-Host "$failed 项检查没过" -ForegroundColor Red
}
exit $failed
