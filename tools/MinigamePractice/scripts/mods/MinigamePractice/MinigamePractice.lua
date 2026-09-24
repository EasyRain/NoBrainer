-- MinigamePractice — 让 NoBrainer 可以在任何地方被测试的练习台（真·逻辑类，不是模拟类）。
--
-- 为什么需要它：NoBrainer 的小游戏逻辑只在任务里跑，进局测试很慢；AuspexHelper 那类练习模式用的是
-- 它自己的 Preview* 模拟类，驱动不了 NoBrainer（NB 钩的是游戏的真逻辑类）。
--
-- 做法（全部 pcall 包住，任何一个环节失败都只会写日志，不会把游戏搞崩）：
--   1. 用真类建一个实例：MinigameBalance:new(unit, is_server, seed)（签名来自 MinigameProbe 的反射：
--      init(self, unit, is_server, seed)）；
--   2. 我们扮演服务器：每帧 mg:update(dt, t) 步进游戏自己的物理，然后把位置 set_position 回去
--      —— 这正是真机里"服务器 RPC 把位置发给你"的那条路，NoBrainer 的 set_position 钩子就在这里；
--   3. 每 0.5 秒喂一次 on_axis_set(t, x, y)（相当于你推摇杆），让位置真的在动；
--   4. 可选注入：定时把 NB 的 estimate_time 往前推一点，制造"样本时间没前进"的收据（修复①的对象）；
--      以及直接调用 NB 暴露的 mod._bal_predictive_correction(true) 来压命令环（O2 的对象）。
--
-- 命令：
--   /mg_practice            用 balance 开一局练习（默认）
--   /mg_practice <type>     指定类型：balance / decode_symbols / decode_search / drill / frequency
--   /mg_practice stop       停掉并清理
--   /mg_practice inject     开/关两种注入（默认开）
--
-- 注意：它不会打开游戏的小游戏界面（无头练习）——目的是驱动 NoBrainer 的代码路径与它的诊断计数，
-- 而不是给你玩。界面那一步（scanner_display_view）留到以后需要时再说。
local mod = get_mod("MinigamePractice")

local PATHS = {
    balance = "scripts/extension_systems/minigame/minigames/minigame_balance",
    decode_symbols = "scripts/extension_systems/minigame/minigames/minigame_decode_symbols",
    decode_search = "scripts/extension_systems/minigame/minigames/minigame_decode_search",
    drill = "scripts/extension_systems/minigame/minigames/minigame_drill",
    frequency = "scripts/extension_systems/minigame/minigames/minigame_frequency",
}

local session = nil
local inject = true
local injected_skew, injected_ring = 0, 0
local last_inject_at, last_axis_at = 0, 0

local function log(fmt, ...)
    mod:info("MinigamePractice: " .. fmt, ...)
end

local function gameplay_time()
    local time = Managers.time
    return time and time:has_timer("gameplay") and time:time("gameplay") or nil
end

local function nobrainer()
    -- 注意：NoBrainer 的状态在它自己的表上（get_mod("NoBrainer")._bal），不是本 mod 的 _bal。
    -- 第一版做成练习台时读错了表，于是 diag 永远是 nil —— 这一句是那个 bug 的修复。
    return get_mod("NoBrainer")
end

local function local_player()
    local players = Managers.player
    return players and players:local_player_safe(1) or nil
end

local function stop_practice(reason)
    if not session then
        log("no practice session running")
        return
    end
    local mg = session.mg
    pcall(mg.stop, mg, true)
    log("stopped %s practice (%s); injected skew=%d ring=%d", session.type, tostring(reason),
        injected_skew, injected_ring)
    session = nil
end

local function start_practice(type_name)
    type_name = type_name or "balance"
    if session then
        log("already running '%s'; use /mg_practice stop first", session.type)
        return
    end
    local path = PATHS[type_name]
    if not path then
        log("unknown type '%s' (known: balance, decode_symbols, decode_search, drill, frequency)", tostring(type_name))
        return
    end
    local player = local_player()
    local unit = player and player.player_unit
    if not unit or not Unit.alive(unit) then
        log("no local player unit")
        return
    end

    local ok, class = pcall(require, path)
    if not ok or type(class) ~= "table" or type(class.new) ~= "function" then
        log("cannot load %s (%s)", path, tostring(class))
        return
    end

    -- init(self, unit, is_server, seed)；我们当服务器，这样游戏自己的物理会跑起来
    local created, mg = pcall(class.new, class, unit, true, 1)
    if not created or type(mg) ~= "table" then
        log("new(%s) failed: %s", type_name, tostring(mg))
        return
    end

    local setup_ok, setup_err = pcall(mg.setup_game, mg)
    local start_ok, start_err = pcall(mg.start, mg, player, false)
    log("created %s: setup_game=%s (%s) start=%s (%s)", type_name,
        tostring(setup_ok), tostring(setup_err), tostring(start_ok), tostring(start_err))

    local state_ok, state = pcall(mg.state, mg)
    log("  initial state=%s, position=%s, unit=%s", tostring(state_ok and state or "?"),
        tostring(select(1, pcall(mg.position, mg))), tostring(unit))

    local nb = nobrainer()
    local balance_state = nb and nb._bal
    -- 关键自检之一：我们 require 到的类表，是否就是全局 MinigameBalance（NoBrainer 钩的就是它）。
    -- 如果两者不是同一个表，我们调的 set_position 就绕过 NB 的钩子，样本永远不会入队。
    local required_class = select(1, pcall(require, path))
    local global_class = rawget(_G, type_name == "balance" and "MinigameBalance" or "")
    log("  class identity: required==global ? %s (required=%s global=%s)",
        tostring(required_class == global_class), tostring(required_class), tostring(global_class))
    log("  NoBrainer: mod=%s enable_balance=%s balance_active=%s observer_ready=%s",
        tostring(nb ~= nil), tostring(nb and nb:get("enable_balance")),
        tostring(balance_state and balance_state.active),
        tostring(balance_state and balance_state.observer_ready))

    session = { type = type_name, mg = mg, frames = 0, started_at = gameplay_time(), samples = 0 }
    last_inject_at, last_axis_at = 0, 0
    injected_skew, injected_ring = 0, 0
    log("practice running: %s. NoBrainer's balance hooks should be armed now (watch its diag line)",
        type_name)
end

mod.update = function(dt)
    if not session then
        return
    end
    local t = gameplay_time()
    if not t then
        return
    end
    local mg = session.mg
    local session_type = session.type
    session.frames = session.frames + 1

    -- 0) 会话还活着吗？平衡小游戏会被"玩结束"（随机摇杆把它晃翻），一结束 NB 的 complete 钩子就会
    --    _balance_cleanup → 之后所有 set_position 都被丢弃。上一轮 13,200 帧计数全 0 很可能就是它。
    --    所以每帧先看状态，结束就地重开一局。
    local state_ok, state = pcall(mg.state, mg)
    local completed_ok, completed = pcall(mg.is_completed, mg)
    if (state_ok and state ~= "gameplay") or (completed_ok and completed) then
        log("session ended (state=%s completed=%s) after %d frames / %d samples - restarting",
            tostring(state), tostring(completed), session.frames, session.samples)
        stop_practice("minigame_ended")
        start_practice(session_type or "balance")   -- 立刻再开一局，保持采样连续
        return
    end

    -- 1) 我们自己当服务器：步进游戏自己的物理
    pcall(mg.update, mg, dt, t)

    -- 2) 摇杆输入，让位置动起来（幅度小一点，别把自己晃翻）
    if t >= last_axis_at + 0.5 then
        last_axis_at = t
        local x = (math.random() * 2 - 1) * 0.25
        local y = (math.random() * 2 - 1) * 0.25
        pcall(mg.on_axis_set, mg, t, x, y)
    end

    -- 3) 位置当作"服务器发来的收据"喂回去（NoBrainer 的 set_position 钩子在这里取样）
    local position = select(1, pcall(mg.position, mg))
    if type(position) == "table" and type(position.x) == "number" then
        pcall(mg.set_position, mg, position.x, position.y)
        session.samples = session.samples + 1
    end

    -- 4) 注入：把 NoBrainer 的 estimate_time 往前推 → 下一条收据的"测量时间"落在它之前，
    --    即真实世界里 RTT 变化造成的"样本时间没前进"。修复①就是为这种情况准备的。
    local nb = nobrainer()
    local balance = nb and nb._bal
    if inject and balance then
        if t >= last_inject_at + 2.0 then
            last_inject_at = t
            if type(balance.estimate_time) == "number" then
                balance.estimate_time = balance.estimate_time + 0.25
                injected_skew = injected_skew + 1
            end
            -- 命令环：先给一个大 tick 记一条"未来"的命令，再缩小 tick 并立刻提交一条更早的
            if type(balance.tick_interval) == "number" and nb._bal_predictive_correction then
                balance.tick_interval = 0.1
                pcall(nb._bal_predictive_correction, true)
                balance.tick_interval = 1 / 52
                pcall(nb._bal_predictive_correction, false)
                pcall(nb._bal_predictive_correction, true)
                injected_ring = injected_ring + 1
            end
        end
    end

    -- 状态每 ~10 秒报一次：同时把"NB 那一侧"的关键开关打全，这样一次运行就能判断样本
    -- 到底卡在哪一步：active=false → NB 已放手（本轮就是它）；pending=true 但计数不动 →
    -- 入队了但 on_update 没处理；samples 不涨 → 连 set_position 都没发出去。
    if session.frames % 600 == 0 then
        log("frames=%d samples=%d state=%s | NB active=%s pending=%s ready=%s | skewed=%s reset=%s stale=%s | injected(skew=%d ring=%d)",
            session.frames, session.samples, tostring(state),
            tostring(balance and balance.active), tostring(balance and balance.pending_sample),
            tostring(balance and balance.observer_ready), tostring(balance and balance.diag_skewed),
            tostring(balance and balance.diag_reset), tostring(balance and balance.diag_stale),
            injected_skew, injected_ring)
    end
end

mod:command("mg_practice", "start/stop a headless minigame practice session for NoBrainer testing", function(...)
    -- DMF 可能把参数拆成多个值给过来，也可能给一整串，两种都接住
    local parts = { ... }
    local argument = table.concat(parts, " "):lower():match("^%s*(.-)%s*$")
    if argument == "stop" then
        stop_practice("command")
    elseif argument == "inject" then
        inject = not inject
        log("injection is now %s", tostring(inject))
    else
        start_practice(argument ~= "" and argument or nil)
    end
end)

mod.on_unload = function()
    stop_practice("unload")
end

mod.on_game_state_changed = function(status, name)
    if status == "exit" and name == "StateGameplay" then
        stop_practice("gameplay_exit")
    end
end

log("loaded: /mg_practice [type|stop|inject]")
