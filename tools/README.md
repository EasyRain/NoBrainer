# nobrainer/tools

这个目录里的东西不是 mod 的一部分，是维护 NoBrainer 用的工具。2026-09-24 实测跑通后，
两个"进游戏用"的 mod 已经**从游戏里移出**（备份在 `D:\DshWorkSpace\Darktide\.dtsrc\game-mods-removed\`），
仓库里这份是源头。

## 离线：改 balance / 相关逻辑前后先跑这个

```
luajit tools/smoke_balance.lua                     # 用桩在游戏外跑 balance 模块，14 条断言
luajit tools/smoke_balance.lua <另一份模块路径>      # 对比另一份（例如 git show <基线>:... 导出的）
```

`luajit` **不在 PATH 上**，本机装在 `D:\Tools\Lua\luajit\src\luajit.exe`（同目录还有 `lua55.exe`、`luac55.exe`）。
实际跑法：

```powershell
cd D:\DshWorkSpace\Darktide\repos\nobrainer
& D:\Tools\Lua\luajit\src\luajit.exe tools\smoke_balance.lua
```

它钉住三件事：样本时间没前进时**保留**速度估计（而不是清零）、真正断档仍然重置、
命令环在乱序 `apply_time` 下**覆盖环头**且不回退。对基线（`5b2528c`）跑会有 6 条失败。

## 进游戏：两个测试 mod（需要时再装回去）

装法（两者都要先重启游戏才生效）：

```powershell
$mods = 'D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods'
foreach ($name in 'MinigameProbe','MinigamePractice') {
    Copy-Item "tools\$name" "$mods\$name" -Recurse -Force
}
# 再把 MinigameProbe / MinigamePractice 各作为一行加进 mods\mod_load_order.txt
# （UTF-8 无 BOM；用 [IO.File]::WriteAllText(..., UTF8Encoding($false))）
```

* **MinigameProbe**（只读诊断）
  - `/mg_probe`：dump `MinigameSettings` 全部数值/类型、`_G` 里 12 个 `Minigame*` 类及其方法、
    extension manager 的 systems 列表、候选模块路径能否 `require`、当前 CSM 状态与相关视图是否开启。
  - `/mg_sig`：用 `debug.getinfo/getlocal` 把目标函数的**参数名与来源文件**打出来，
    并 `pcall` 试构造 `MinigameBalance`（只看它报什么错）。
  - `/mg_obj`：如果你正好在一个小游戏里，dump 那个对象。
* **MinigamePractice**（无头练习台，用**真逻辑类**驱动，所以 NoBrainer 的钩子会真的跑）
  - `/mg_practice [type]`：默认 `balance`，也可 `decode_symbols / decode_search / drill / frequency`。
    做法：`class.new(unit, true, 1)` → `setup_game()` → `start(player, false)`，然后每帧
    `mg:update(dt,t)` + 每 0.5 s `on_axis_set(t,x,y)` + 把位置 `set_position(x,y)` 喂回去
    （= 真机里服务器 RPC 那条路，正是 NoBrainer 取样处）；每 2 秒注入两种在真机上会自然发生的
    条件（`estimate_time` 前移造成"样本时间没前进"；`tick_interval` 变化造成乱序 `apply_time`）。
  - `/mg_practice stop` / `inject`（开关注入）。
  - 每 10 秒一行：`frames/samples/state | NB active/pending/ready | skewed/reset/stale | injected`。

## 已知结论（2026-09-24 实测，别再重复踩）

* `setup_game` 在枢纽里会因 `RPC rpc_minigame_sync_game_state direction violation` 失败 —— 无害，
  `start` 成功、状态 `gameplay`，而且走的正是"网络样本"那条路。
* 练手台曾经两个 bug 都出在"取错返回值"上：读错了 mod 表（应 `get_mod("NoBrainer")._bal`）、
  以及 `select(1, pcall(...))` 拿到的是成功标志而不是结果 → `set_position` 一次没发。
  现在开局会打印类身份与 NoBrainer 的武装状态做自检。
* 实测数据（60 秒、5400 帧、`samples==frames`）：`skewed` 63 → 659 持续增长、`reset=0`、`stale=0`
  —— 即"样本时间没前进"在真实网络抖动下**确有其事**，而真正断档没有发生。
  练习台的注入（33 次）只占极少数，说明**绝大多数是同一次真实 ping 抖动自然产生的**。
* 真机"基线版 A/B"**不值得做**：基线没有计数器，加计数器也只能得到同样的 `skewed` 数字
  （同一事件），差异在"速度是否被清零"这种连续量上，靠计数看不出来；这个差异已由
  `smoke_balance.lua` 确定性证明。要更强的真机验证，下一步是**打开真正的
  `scanner_display_view`**，让 NoBrainer 的输入路径（`stale`）也进入测试范围。
