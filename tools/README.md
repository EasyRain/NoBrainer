# nobrainer/tools

这个目录里的东西不是 mod 的一部分，是维护 NoBrainer 用的工具。两个"进游戏用"的探针
（`MinigameProbe` / `MinigamePractice`）实测跑通后平时**不装在游戏里**，仓库里这份就是源头，
需要时按下面的步骤装回去。

## GitHub

- 上游：`Vansinnet/NoBrainer`（作者公开源码，1 个 commit；**内容和我们基线 `5b2528c` 完全相同**）
- 我们的 fork：`EasyRain/NoBrainer` —— `main` = 上游原样（别推），`maintained` = 我们的完整提交历史
- 推送：`git push`（`origin` 已配好，本地 `master` 跟踪 `origin/maintained`；凭据走 `gh auth setup-git`）

> Windows 上 git 默认的 TLS 后端 **schannel 可能卡死**（`ls-remote` 挂二十多秒报连不上，
> 而 curl / gh 正常）。换成 OpenSSL 后端即可：`git config --global http.sslBackend openssl`。
>
> 所在网络直连 GitHub 不稳（`Recv failure: Connection was reset`）时，给 git 配一个 HTTP 代理再推：
> `git config http.proxy http://<代理地址>:<端口>`（只对本仓库生效；删掉即恢复直连）。

## 一把跑完（改完代码 / 游戏更新后）

```powershell
powershell -File tools\run_checks.ps1
```

它会依次跑：① balance 的离线冒烟测试；② 钩子体检（对最新日志）。任何一项不过就以非 0 退出。

> Windows PowerShell 5.1 会把**没有 BOM 的 UTF-8 当 ANSI 读**：中文变乱码，甚至报错。
> 仓库里的 `.ps1` 都带 UTF-8 BOM；用编辑器改过之后若 BOM 丢了，按下面补回来：
> ```powershell
> $p='tools\run_checks.ps1'; $t=[IO.File]::ReadAllText($p,(New-Object Text.UTF8Encoding($false)))
> [IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding($true)))
> ```

## 离线：改 balance / 相关逻辑前后先跑这个

```
luajit tools/smoke_balance.lua                     # 用桩在游戏外跑 balance 模块，14 条断言
luajit tools/smoke_balance.lua <另一份模块路径>      # 对比另一份（例如 git show <基线>:... 导出的）
```

`luajit` 不一定在 PATH 上；不在的话用完整路径调用即可（`tools\run_checks.ps1` 顶部留了一个
可改的默认路径，找不到会退回 PATH）：

```powershell
cd <本仓库根目录>
<luajit 所在目录>\luajit.exe tools\smoke_balance.lua
```

它钉住三件事：样本时间没前进时**保留**速度估计（而不是清零）、真正断档仍然重置、
命令环在乱序 `apply_time` 下**覆盖环头**且不回退。对基线（`5b2528c`）跑会有 6 条失败。

## 进游戏：两个测试 mod（需要时再装回去）

装法（两者都要先重启游戏才生效）：

```powershell
$mods = '<Darktide 安装目录>\mods'
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
    （= 真机里服务器同步那条路，正是 NoBrainer 取样处）；每 2 秒注入两种在真机上会自然发生的
    条件（`estimate_time` 前移造成"样本时间没前进"；`tick_interval` 变化造成乱序 `apply_time`）。
  - `/mg_practice stop` / `inject`（开关注入）。
  - 每 10 秒一行：`frames/samples/state | NoBrainer active/pending/ready | skewed/reset/stale | injected`。

## 已知结论（2026-09-24 实测，别再重复踩）

* `setup_game` 在枢纽里会因 `RPC rpc_minigame_sync_game_state direction violation` 失败 —— 无害，
  `start` 成功、状态 `gameplay`，而且走的正是"网络样本"那条路。
* 练手台曾经两个 bug 都出在"取错返回值"上：读错了 mod 表（应 `get_mod("NoBrainer")._bal`）、
  以及 `select(1, pcall(...))` 拿到的是成功标志而不是结果 → `set_position` 一次没发。
  现在开局会打印类身份与 NoBrainer 的武装状态做自检。
* 实测数据（60 秒、5400 帧、`samples==frames`）：`skewed` 63 → 659 持续增长、`reset=0`、`stale=0`。
  ⚠️ **这条结论后来被真机数据推翻了**：练习台在**枢纽**里跑，枢纽的 `mod._time("gameplay")`
  是**量化**的（约 10 Hz），而练习台每帧都塞一个样本 → 九成样本时间戳没前进 → 那 659 次
  `skewed` 是**假象**，不是"真实 ping 抖动"。练习台其实复现的是**房主/本地开服**那条样本路
  （`_is_server=true` + 每帧本地取样），不是普通客户端。
* **真机实测（3 把，2026-09-24）**：普通客户端（`_is_server=false`，样本只来自 `set_position`）
  1545 个样本 `skewed=0 reset=0 stale=0`；单人本地开服（`_is_server=true`，样本来自 `_update_cursor`）
  1697 个样本里**每轮恰好 1 次 skewed，就是第 1 个样本**（`is_server=true` 时 `st.rtt=0`，
  `_initialize_balance_tracking` 把 `estimate_time` 设成未偏移的 `mod._time("gameplay")`，
  首样本落在同一帧）—— 那一帧速度本来就是 0，**没有可观测差异**。命令环守卫（`apply_time` 倒退）
  在两种场景下都是 0 次。
  → 即：从 BetterBrainer 移植的两处改动在真机上**不改变行为**，留着当防御；`smoke_balance.lua`
  才是唯一能确定性证明其行为差异的地方。
* 真机"基线版 A/B"**不值得做**：基线没有计数器，加计数器也只能得到同样的 `skewed` 数字
  （同一事件），差异在"速度是否被清零"这种连续量上，靠计数看不出来；这个差异已由
  `smoke_balance.lua` 确定性证明。
* 真机探针已在 commit `2ca9d6b` **全部拆除**（连 `DIAGNOSTICS` 一起），balance 模块现在没有任何输出；
  只剩两个纯计数器 `diag_skewed/diag_reset`，因为 `smoke_balance.lua` 要靠它们断言。
* 以后还想量真机数据，最小配方：① 在 `_process_predictive_sample` 里加一个 `diag_samples` 计数；
  ② 在两个取样点（视图的 `_update_cursor` 和 `set_position`）各加一个计数，区分本地路与网络路；
  ③ 用 `mod:echo` 打周期行（Darktide Mod Framework 默认 echo = 日志 + 聊天框）；
  ④ 收尾在 `_balance_cleanup` 里打一行，并**先判 `balance_active`** —— 否则 `round_end` / `unload`
  反复调用会重复重报同一批旧数字。量完记得全部拆掉。

## 钩子体检（`check_hooks.py`）

```powershell
python tools\check_hooks.py                 # 用最新日志，mod 名默认 NoBrainer
python tools\check_hooks.py <log 路径>
```

它把**仓库源码里注册的每个钩子**（类名式 `mod:hook_safe("X","m")` + 路径式 `hook_require` 里面的）
和**真机日志**对着核，逐个给出：

| 状态 | 含义 |
|---|---|
| `OK` | 日志里有 `Hooking 'm' from [X]`，挂上了；如果这个类是游戏中途才构造的，日志里还能看到它先被延迟、之后补挂 |
| `DEAD` | 一直停在 "needs to be delayed"，类始终没出现 → **基本就是游戏更新改了类名** |
| `ERROR` | Darktide Mod Framework 报了 "trying to hook … that doesn't exist" → 方法被改名了 |
| `MISSING` | 日志里完全没出现（这份日志没跑到那一段，或钩子压根没注册） |

退出码：全 OK = 0，否则 1。2026-09-24 两份真机日志都是 **39/39 OK**（其中 7 个是延迟后挂上的：
`MinigameSystem`、`MinigameBalanceView`、`AuspexScanningEffects`）。

**为什么不用 hook_require 全面替换类名式钩子（O6 的结论）**：读 Darktide Mod Framework（`modules/core/hooks.lua`）后确认，
类名式钩子并不是"查全局变量"，而是 `rawget(_G, name)` → `rawget(_G.CLASS, name)`（游戏的类登记表），
查不到就记成延迟钩子，等 `class()` 造出来、第一次 `new` 时补挂 —— 而且**每一步都会写日志**。
`mod:hook_require(path, cb)` 则是**只看路径**：路径写错时它一声不响，什么都不挂（函数体里从不
`require` 那个路径）。也就是说换过去等于**把一个会留痕的机制换成一个静默的机制**，风险不对等。
真正要防"游戏更新后静默失效"，用上面这个体检脚本更直接。

**顺便：所有模块路径都已实测确认**（`MinigameProbe` 的 `/mg_probe` 在当前 build 里逐个 `require` 过，
日志 `04:50:14` / `04:55:44`）：

```
scripts/extension_systems/minigame/minigame_system
scripts/extension_systems/minigame/minigame_extension
scripts/extension_systems/minigame/minigames/minigame_{balance,decode_search,decode_symbols,drill,frequency}
scripts/ui/views/scanner_display_view/minigame_{balance,decode_search,decode_symbols,drill,frequency}_view
scripts/extension_systems/weapon/actions/action_scan_confirm
scripts/extension_systems/input/player_unit_input_extension
scripts/extension_systems/character_state_machine/character_states/player_character_state_minigame
scripts/extension_systems/visual_loadout/wieldable_slot_scripts/auspex_scanning_effects   ← 来自 BetterBrainer，未单独 require 过
scripts/settings/minigame/minigame_settings
```

（`minigame_servo_skull` / `minigame_manager` **不存在**，别照名字猜。）
