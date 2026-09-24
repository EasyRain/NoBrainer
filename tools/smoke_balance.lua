-- smoke_balance.lua -- 在游戏外用 LuaJIT 跑 NoBrainer 的 balance 模块，钉住三处改动。
--
-- 为什么这么做：真正的 balance 小游戏只在任务里出现（进局测试很慢），而 AuspexHelper 的
-- 练习模式用的是它自己的 Preview* 模拟类、不是游戏逻辑类 MinigameBalance，所以它驱动不了
-- NoBrainer。这三处改动本质上是状态机与数值，用桩把模块跑起来就能精确验证。
--
--   luajit tools/smoke_balance.lua                       # 跑仓库里的模块
--   luajit tools/smoke_balance.lua path/to/old_copy.lua   # 跑另一份（用来证明测试抓得住 bug）
local script = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local default_path = script .. "/../scripts/mods/NoBrainer/NoBrainer_minigame_balance.lua"
local module_path = arg[1] or default_path

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then failures = failures + 1 end
    print(string.format("%-4s %-56s got %-14s want %s", pass and "ok" or "FAIL", label,
        tostring(actual), tostring(expected)))
end
local function check_true(label, value) check(label, value and true or false, true) end
local function near(a, b, eps)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 1e-9)
end

-- ---- Lua/LuaJIT 里游戏补的那几个函数 ---------------------------------------------------------
if not math.clamp then
    function math.clamp(v, lo, hi) return math.max(lo, math.min(v, hi)) end
end
if not table.clear then
    function table.clear(t) for k in pairs(t) do t[k] = nil end end
end

-- ---- 游戏 API 的桩 ---------------------------------------------------------------------------
local NOW = 0                     -- mod._time("gameplay") 返回它
local PING = 0                    -- Network.ping 的返回值
local hook_safe_cb, hook_require_cb, events = {}, {}, {}
local messages = {}

local mod = {}
mod._time = function() return NOW end
mod._S = function(key) return true end
mod.info = function(_, fmt, ...) messages[#messages + 1] = string.format(tostring(fmt), ...) end
mod.echo = function(_, fmt, ...) messages[#messages + 1] = string.format(tostring(fmt), ...) end
mod.warning = mod.info
mod.is_enabled = function() return true end
mod.hook_safe = function(_, class, name, fn)
    hook_safe_cb[class] = hook_safe_cb[class] or {}
    hook_safe_cb[class][name] = fn
end
mod.hook = function(_, class, name, fn) mod.hook_safe(_, class, name, fn) end
mod.hook_require = function(_, path, fn) hook_require_cb[path] = fn end
mod._reg = function(event, fn)
    events[event] = events[event] or {}
    events[event][#events[event] + 1] = fn
end
mod._is_local_minigame_player = function(player) return player == "local_player" end

_G.get_mod = function(name) return mod end
_G.Managers = {
    time = { has_timer = function() return true end, time = function() return NOW end },
    connection = {
        tick_rate = function() return 52 end,
        is_client = function() return false end,
        is_host = function() return true end,
        host = function() return "host" end,
    },
    player = { local_player_safe = function() return "local_player" end },
    ui = { view_active = function() return true end },
    state = { extension = { has_system = function() return false end } },
}
_G.Network = { ping = function() return PING end }
_G.Unit = { alive = function() return true end }
_G.ScriptUnit = { has_extension = function() return nil end }

local settings_stub = {
    types = { balance = "balance", none = "none" },
    game_states = { gameplay = "gameplay", completed = "completed" },
    balance_move_ratio = 5.0,
    balance_push_ratio = 2.0,
    balance_max_speed = 1.5,
    balance_disrupt_power = 0.5,
}
local real_require = require
_G.require = function(path)
    if path == "scripts/settings/minigame/minigame_settings" then return settings_stub end
    return real_require(path)
end

-- ---- 载入被测模块 ----------------------------------------------------------------------------
local chunk, err = loadfile(module_path)
if not chunk then
    io.stderr:write("could not load the module: ", tostring(err), "\n")
    os.exit(1)
end
local ok, load_err = pcall(chunk)
if not ok then
    io.stderr:write("the module failed to load: ", tostring(load_err), "\n")
    os.exit(1)
end
_G.require = real_require

-- 模块通过 hook_require 拿 minigame 逻辑类；这里把回调执行一次，拿到它注册的 set_position 等钩子
for _, fn in pairs(hook_require_cb) do pcall(fn, {}) end

local balance = mod._bal
if type(balance) ~= "table" then
    io.stderr:write("mod._bal was not created\n")
    os.exit(1)
end
local start_hook = hook_safe_cb.MinigameBalance and hook_safe_cb.MinigameBalance.start
local set_position_hook = hook_safe_cb.MinigameBalance and hook_safe_cb.MinigameBalance.set_position
if not (start_hook and set_position_hook) then
    io.stderr:write("MinigameBalance hooks were not registered\n")
    os.exit(1)
end
local update = events.update and events.update[1]
if not update then
    io.stderr:write("no update event registered\n")
    os.exit(1)
end

-- ---- 假的小游戏对象 --------------------------------------------------------------------------
local POSITION = { x = 0.0, y = 0.0 }
local function make_minigame()
    return {
        _is_server = false,
        _minigame_unit = "unit",
        state = function() return "gameplay" end,
        is_completed = function() return false end,
        position = function() return POSITION end,
        player_session_id = function() return 1 end,
    }
end

local function feed_sample(mg, t, x, y, dt)
    NOW = t
    POSITION.x, POSITION.y = x, y
    set_position_hook(mg, x, y)
    update(dt or 0.02)
end

-- ---- 1) 开局：会话建立、正向样本让估计动起来 ---------------------------------------------------
local mg = make_minigame()
NOW = 1.0
start_hook(mg, "local_player")
check_true("a session starts", balance.active)

feed_sample(mg, 1.10, 0.10, 0.00)
check_true("observer ready after the first sample", balance.observer_ready)
local first_velocity = balance.estimate_vx + balance.estimate_vy
feed_sample(mg, 1.20, 0.22, 0.02)
local moving_velocity = balance.estimate_vx + balance.estimate_vy
check_true("a second forward sample changes the estimate", moving_velocity ~= first_velocity)
check("no skewed samples yet", balance.diag_skewed or 0, 0)

-- ---- 2) 修复①：时间没有前进的样本要丢弃，不能把速度清零 --------------------------------------
local before_vx, before_vy = balance.estimate_vx, balance.estimate_vy
feed_sample(mg, 1.20, 0.40, 0.05)          -- 同一个 gameplay 时间再来一帧
check("a sample whose time did not advance is counted", balance.diag_skewed or 0, 1)
check("and the velocity estimate is kept (this is the fix)",
    near(balance.estimate_vx, before_vx) and near(balance.estimate_vy, before_vy), true)

-- ---- 3) 修复①不能把"真的断了很久"也一起放过 --------------------------------------------------
local before_reset = balance.diag_reset or 0
feed_sample(mg, 3.00, 0.50, 0.10)          -- 1.8 秒的空档：仍然应该重置估计
check_true("a real gap still resets the estimate", (balance.diag_reset or 0) > before_reset)
check("and that reset zeroes the velocity", balance.estimate_vx, 0)

-- ---- 4) O2：命令环保持单调（晚到的 apply_time 覆盖而不追加） -----------------------------------
-- 构造方式与真实场景一致：apply_time = now + rtt/2 + tick_interval，而 tick_interval 会被
-- _update_network_timing 按服务器 tick rate 重新采样。先按大 tick 记一条 head，再把 tick 调小、
-- 时间只前进一点点 —— 下一条的 apply_time 就落在 head 之前了（晚到的命令）。
feed_sample(mg, 3.10, 0.52, 0.10)
feed_sample(mg, 3.20, 0.54, 0.11)
local correction_fn = mod._bal_predictive_correction
check_true("the module exposes its correction function", type(correction_fn) == "function")
if type(correction_fn) == "function" then
    balance.tick_interval = 0.1                 -- 大 tick：head 的 apply_time 落在未来 0.1 秒
    NOW = 4.00
    correction_fn(true)
    local count_before = balance.command_count
    local head_before = balance.command_times[balance.command_head]

    balance.tick_interval = 1 / 52              -- tick 变小
    NOW = 4.05
    correction_fn(false)                        -- 只算不记：缓存一个更早的 apply_time
    local cached_apply = balance.correction_apply_time
    check_true("the cached apply time is behind the head", cached_apply < head_before)
    correction_fn(true)                         -- 用它提交：必须覆盖 head，不能追加
    check("an out-of-order apply time overwrites the head", balance.command_count, count_before)
    check_true("and the ring head does not move backwards",
        balance.command_times[balance.command_head] >= head_before)

    balance.tick_interval = 1 / 52
    NOW = 4.60
    correction_fn(true)
    check_true("a later apply time does append", balance.command_count > count_before)
end

-- ---- 5) O1：会话键是表身份，不是 tostring -----------------------------------------------------
local other = make_minigame()
NOW = 3.50
set_position_hook(other, 0.9, 0.9)              -- 另一个对象，同一个会话不该被它喂样本
check("another minigame object cannot feed this session", balance.diag_skewed or 0, 1)

print("")
if failures > 0 then
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
print("smoke_balance: all checks passed")
