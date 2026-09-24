# NoBrainer — 维护分支（`maintained`）

> **This branch is maintenance-only.** `main` is upstream
> [Vansinnet/NoBrainer](https://github.com/Vansinnet/NoBrainer) untouched; everything
> this project changed lives on `maintained`. We do not add features — we fix bugs and
> port improvements back from the author's rewrite,
> [BetterBrainer](https://www.nexusmods.com/warhammer40kdarktide/mods/1282) (Nexus 1282).

NoBrainer 是一个 Darktide Mod Framework 小游戏辅助 mod。它已被 Nexus 下架（管理员认为功能过强），
原作者停更并转而维护阉割版 BetterBrainer，所以这里接手继续维护。

## 两条规矩

1. **只维护**：不加新功能、不加新设置项、不扩大功能面。只做修 bug、健壮性、性能。
   功能面一旦被扩大，只会加速它被再次下架。
2. **改进从 BetterBrainer 移植**：BetterBrainer 是作者对 NoBrainer 的**重写**（把上下文对象传给每个模块 + 模块返回
   `{observe,input,reset,settings_changed}`），它发布的修复/优化如果对 NoBrainer 成立，就搬回来，
   并在下面记账标出来源。搬运时保留原理注释，方便以后对照。

## 基线

- `5b2528c` = **已发布版原样**（从游戏目录里的安装副本建立，13 个文件）。
- 上游 GitHub（`Vansinnet/NoBrainer`，单个 commit `4175912` "Initial public source"）的
  12 个 Lua + `NoBrainer.mod` 与本基线**逐个文件哈希完全一致** —— 上游没有比这里更新的代码。

## 已移植 / 已改动

| 改动 | 来源 | 说明 |
|---|---|---|
| 样本时间守卫 | **BetterBrainer 1.0.1**（`balance.lua:132`） | `_process_predictive_sample`：样本时间没前进（重复/乱序的网络收据，或往返延迟下降把 `estimate_time` 往回平移）就**丢弃该样本、保留速度估计**，不再清零速度。真正断档（`dt > SAMPLE_TIMEOUT`）仍然重置。 |
| 命令环单调钳制 | **BetterBrainer**（`balance.lua:59`，`record()` 里的 `math.max`） | `_record_command`：晚到/重复的 `apply_time` **覆盖环头**而不是追加 —— `_command_at` 从 head 往回扫、假定时间递减，非单调会取到过期指令。 |
| 会话键用对象身份 | 本项目（BetterBrainer 仍用 `tostring`） | 五个模块共 41 处 `tostring(mg)` / `tostring(self)` → 引用比较。这些 `_is_active_*` 是从**每帧钩子**里调的，原来每帧都在新建字符串；顺带避免对象回收后地址复用导致"两个不同小游戏看起来相等"。 |
| 两个计数器 | 本项目 | `diag_skewed` / `diag_reset` 纯计数、**运行时不打印**，只给离线冒烟测试断言用。 |
| 调试日志开关 | 本项目（把上游遗留的**死设置** `enable_debug_messages` 接上） | DMF 选项里新增 **Debug → Write Debug Log**，**默认关闭**。打开后每局小游戏的关键事件写一行到**游戏日志文件**（不上屏、不改变行为），固定前缀 `NoBrainer debug:`：每种小游戏各报 开始 / 结束 / 提交，Train Balance 另外报累计 `skewed` / `reset`。反馈问题或维护排查时打开，量完关掉。 |

## 真机实测结论（别再重复劳动）

三把实机数据（普通客户端 1545 个样本 / 单人本地开服 1697 个样本）说明：

- **客户端**（`_is_server=false`，样本只来自服务器的 `set_position`）：`skewed=0 reset=0 stale=0`。
- **单人本地开服**（`_is_server=true`，样本来自 `_update_cursor` 的每帧本地取样）：**每轮恰好 1 次
  `skewed`，而且就是第 1 个样本** —— 那一帧速度估计本来就是 0，`reset` 分支和 `skewed` 分支的结果
  没有可观测差异。命令环守卫在两把里都是 **0 次**触发。

也就是说：**两处守卫在真机上是空操作**，留着当防御（对"同一时间戳的重复样本"这类异常更稳）；
它们的行为差异由 `tools/smoke_balance.lua` 确定性证明（对基线跑会有 6 条断言失败）。
如果哪天想再量，最小探针配方写在 [`tools/README.md`](tools/README.md) 里。

## 工具（`tools/`）

| 文件 | 作用 |
|---|---|
| `tools/run_checks.ps1` | 一把跑完：离线冒烟测试 + 钩子体检 |
| `tools/smoke_balance.lua` | 用 LuaJIT + 游戏 API 桩在游戏外跑 balance 模块，14 条断言 |
| `tools/check_hooks.py` | 把仓库里注册的每个钩子跟真机日志核对（`OK / DEAD / ERROR / MISSING`），游戏更新后跑一次就知道哪块废了 |
| `tools/README.md` | 上面这些的用法、已验证的游戏 API/模块路径、已知结论与坑 |
| `tools/MinigameProbe`、`tools/MinigamePractice` | 进游戏用的探针 / 无头练习台（平时**不装**，需要时再装回去） |

## 安装

1. 装好 Darktide Mod Framework。
2. 把本仓库的 `NoBrainer.mod` 与 `scripts/mods/NoBrainer/` 放进游戏的 `mods\NoBrainer\`。
3. 在 `mods\mod_load_order.txt` 里加一行 `NoBrainer`（**必须是 UTF-8 无 BOM**，否则游戏读不了）。
4. 启动游戏，在 Darktide Mod Framework 选项里配置。
5. **不要**和 BetterBrainer 或其它自动解同一小游戏的 mod 同时开。

## 许可证

上游的 MIT 许可证原样保留在 [`LICENSE`](LICENSE)（Copyright (c) 2026 Vansinnet），
本分支的改动同样按 MIT 提供。
