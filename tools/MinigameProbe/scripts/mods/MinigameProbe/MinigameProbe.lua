-- MinigameProbe — 只读诊断 mod：把 Darktide 小游戏相关的 API dump 到日志。
--
-- 目的：NoBrainer/BetterBrainer 之后要靠自己维护，需要在"任何地方"复现小游戏来测试。
-- 本 mod 不修改任何游戏状态，只回答三个问题：
--   1. 小游戏设置表（MinigameSettings）里有什么、类型名是什么；
--   2. 引擎里有哪些 Minigame* 类/全局，它们有哪些方法；
--   3. extension manager 里有没有 minigame 系统，以及哪些候选模块路径能被 require 到。
-- 有了这些就能写"随便在哪儿开一个小游戏"的测试 mod（第二步）。
--
-- 用法：进游戏（枢纽/任务里都行）→ 聊天框输入  /mg_probe
--      如果你正好在一个小游戏里，再输  /mg_obj  把当前对象也 dump 出来。
--      然后把 console log（%APPDATA%\Fatshark\Darktide\console_logs 里最新那个）发出来。
local mod = get_mod("MinigameProbe")

local LIMIT = 60          -- 每个表最多列多少个键
local MAX_DEPTH = 2       -- 递归深度

local CANDIDATE_PATHS = {
    "scripts/settings/minigame/minigame_settings",
    "scripts/extension_systems/minigame/minigame_extension",
    "scripts/extension_systems/minigame/minigame_system",
    "scripts/extension_systems/minigame/minigame_manager",
    "scripts/extension_systems/minigame/minigames/minigame_balance",
    "scripts/extension_systems/minigame/minigames/minigame_decode_symbols",
    "scripts/extension_systems/minigame/minigames/minigame_decode_search",
    "scripts/extension_systems/minigame/minigames/minigame_drill",
    "scripts/extension_systems/minigame/minigames/minigame_frequency",
    "scripts/extension_systems/minigame/minigames/minigame_servo_skull",
    "scripts/ui/views/scanner_display_view/scanner_display_view",
    "scripts/ui/views/scanner_display_view/minigame_balance_view",
    -- AuspexHelper（757，NoBrainer 的前身）在 2026-03 使用的路径：用它来确认这些入口在当前版本还在不在
    "scripts/ui/views/scanner_display_view/minigame_decode_search_view",
    "scripts/ui/views/scanner_display_view/minigame_decode_symbols_view",
    "scripts/ui/views/scanner_display_view/minigame_drill_view",
    "scripts/ui/views/scanner_display_view/minigame_expedition_map_view",
    "scripts/ui/views/scanner_display_view/minigame_frequency_view",
    "scripts/ui/views/scanner_display_view/minigame_none_view",
    "scripts/ui/views/scanner_display_view/scanner_display_view_definitions",
    "scripts/ui/views/scanner_display_view/scanner_display_view_balance_settings",
    "scripts/ui/views/scanner_display_view/scanner_display_view_decode_search_settings",
    "scripts/ui/views/scanner_display_view/scanner_display_view_decode_symbols_settings",
    "scripts/ui/views/scanner_display_view/scanner_display_view_drill_settings",
    "scripts/ui/views/scanner_display_view/scanner_display_view_frequency_settings",
    "scripts/utilities/scanning",
    "scripts/settings/equipment/weapon_templates/devices/scanner_equip",
}

local function describe(value)
    local kind = type(value)
    if kind == "table" then
        local mt = getmetatable(value)
        if type(mt) == "table" and type(mt.__index) == "table" then
            return "table(class)"
        end
    end
    return kind
end

local function dump_table(label, tbl, depth, seen)
    if type(tbl) ~= "table" then
        mod:info("%s = %s (%s)", label, tostring(tbl), type(tbl))
        return
    end
    seen = seen or {}
    if seen[tbl] then
        mod:info("%s = <cycle>", label)
        return
    end
    seen[tbl] = true

    local keys = {}
    for key in pairs(tbl) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local parts, shown = {}, 0
    for _, key in ipairs(keys) do
        local value = tbl[key]
        if type(value) == "table" and (depth or 0) < MAX_DEPTH then
            local inner = {}
            local n = 0
            for ik, iv in pairs(value) do
                n = n + 1
                if n <= 12 then inner[#inner + 1] = tostring(ik) .. "=" .. tostring(iv) end
            end
            table.sort(inner)
            parts[#parts + 1] = string.format("%s{%s%s}", tostring(key), table.concat(inner, ","),
                n > 12 and ",..." or "")
        else
            parts[#parts + 1] = string.format("%s=%s", tostring(key), tostring(value))
        end
        shown = shown + 1
        if shown >= LIMIT then break end
    end
    mod:info("%s: %d key(s): %s", label, #keys, table.concat(parts, " | "))
end

local function probe_settings()
    local ok, settings = pcall(require, "scripts/settings/minigame/minigame_settings")
    if not ok or type(settings) ~= "table" then
        mod:info("[probe] MinigameSettings NOT loadable: %s", tostring(settings))
        return
    end
    mod:info("[probe] MinigameSettings loaded (%d keys)", (function()
        local n = 0
        for _ in pairs(settings) do n = n + 1 end
        return n
    end)())
    for _, key in ipairs({ "types", "game_states", "difficulty", "settings", "minigames" }) do
        if settings[key] ~= nil then
            dump_table("[probe] MinigameSettings." .. key, settings[key], 0)
        end
    end
    dump_table("[probe] MinigameSettings (top level)", settings, 0)
end

local function probe_globals()
    local names = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and name:find("Minigame") then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    mod:info("[probe] globals matching 'Minigame': %d -> %s", #names, table.concat(names, ", "))
    for _, name in ipairs(names) do
        local value = _G[name]
        local kind = describe(value)
        if type(value) == "table" then
            local methods = {}
            for key, member in pairs(value) do
                if type(member) == "function" then methods[#methods + 1] = tostring(key) end
            end
            local mt = getmetatable(value)
            if type(mt) == "table" and type(mt.__index) == "table" then
                for key, member in pairs(mt.__index) do
                    if type(member) == "function" then methods[#methods + 1] = "mt." .. tostring(key) end
                end
            end
            table.sort(methods)
            mod:info("[probe]   %s (%s) methods: %s", name, kind, table.concat(methods, ", "))
        else
            mod:info("[probe]   %s (%s)", name, kind)
        end
    end
end

local function probe_extension_manager()
    local manager = Managers.state and Managers.state.extension
    if not manager then
        mod:info("[probe] no Managers.state.extension")
        return
    end
    local methods = {}
    for key, value in pairs(manager) do
        if type(value) == "function" then methods[#methods + 1] = tostring(key) end
    end
    local mt = getmetatable(manager)
    if type(mt) == "table" and type(mt.__index) == "table" then
        for key, value in pairs(mt.__index) do
            if type(value) == "function" then methods[#methods + 1] = "mt." .. tostring(key) end
        end
    end
    table.sort(methods)
    mod:info("[probe] extension manager methods: %s", table.concat(methods, ", "))

    for _, field in ipairs({ "_systems", "systems", "_extensions", "extensions" }) do
        local value = manager[field]
        if type(value) == "table" then
            local names = {}
            for key in pairs(value) do names[#names + 1] = tostring(key) end
            table.sort(names)
            mod:info("[probe] extension manager.%s: %d -> %s", field, #names,
                table.concat(names, ", "):sub(1, 1500))
        end
    end

    if type(manager.has_system) == "function" then
        for _, name in ipairs({ "minigame_system", "minigame_extension", "minigame",
            "mission_objective_zone_system", "character_state_machine_system" }) do
            local ok, present = pcall(manager.has_system, manager, name)
            mod:info("[probe] has_system(%s) = %s", name, tostring(ok and present or ("err:" .. tostring(present))))
        end
    end
end

local function probe_paths()
    for _, path in ipairs(CANDIDATE_PATHS) do
        local ok, value = pcall(require, path)
        if ok and value ~= nil then
            local kind = describe(value)
            local methods = {}
            if type(value) == "table" then
                for key, member in pairs(value) do
                    if type(member) == "function" then methods[#methods + 1] = tostring(key) end
                end
                local mt = getmetatable(value)
                if type(mt) == "table" and type(mt.__index) == "table" then
                    for key, member in pairs(mt.__index) do
                        if type(member) == "function" then methods[#methods + 1] = "mt." .. tostring(key) end
                    end
                end
            end
            table.sort(methods)
            mod:info("[probe] require %-72s OK (%s) %s", path, kind, table.concat(methods, ", "):sub(1, 900))
        else
            mod:info("[probe] require %-72s FAIL (%s)", path, tostring(value))
        end
    end
end

-- ---- 反射：目标函数的参数名与来源（写 spawner 之前把"要传什么"问出来）-------------------------
local SIGNATURE_TARGETS = {
    { "MinigameBalance", { "new", "init", "setup_game", "start", "stop", "set_position", "position",
        "set_state", "complete", "update", "unit", "on_axis_set", "handle_state" } },
    { "MinigameExtension", { "new", "init", "setup_minigame", "set_active", "is_active", "minigame",
        "minigame_type", "on_add_extension", "on_game_object_created", "setup_from_component", "update" } },
    { "MinigameSystem", { "new", "init", "set_unit_local", "on_add_extension", "rpc_minigame_extension_sync_active",
        "rpc_minigame_sync_start", "rpc_minigame_sync_stop", "rpc_minigame_sync_balance_set_position",
        "rpc_minigame_sync_game_state", "unit_server_correction_occurred" } },
    { "PlayerCharacterStateMinigame", { "new", "init", "on_enter", "on_exit", "minigame",
        "_check_initialize_minigame_from_unit", "_check_initialize_minigame_from_gamemode",
        "_queue_minigame_initialization", "_deinitialize_minigame", "_is_minigame_active",
        "_is_wielding_minigame_device", "_update_input" } },
    { "MinigameBase", { "new", "init", "setup_game", "start", "stop", "set_state", "send_rpc" } },
}

local function signature(label, fn)
    if type(fn) ~= "function" then
        mod:info("[probe]   %-52s not a function (%s)", label, type(fn))
        return
    end
    local ok, info = pcall(debug.getinfo, fn, "Sun")
    if not ok or type(info) ~= "table" then
        mod:info("[probe]   %-52s (no debug info)", label)
        return
    end
    local names = {}
    for index = 1, (info.nparams or 0) do
        local name_ok, name = pcall(debug.getlocal, fn, index)
        names[#names + 1] = tostring(name_ok and name or ("arg" .. index))
    end
    local varargs = info.isvararg and "..." or ""
    mod:info("[probe]   %-46s (%s%s)   [%s]", label, table.concat(names, ", "), varargs,
        tostring(info.source):gsub("^@", ""))
end

local function probe_signatures()
    for _, entry in ipairs(SIGNATURE_TARGETS) do
        local class_name, methods = entry[1], entry[2]
        local class = rawget(_G, class_name)
        mod:info("[probe] signature %s: %s", class_name, type(class))
        if type(class) == "table" then
            for _, method in ipairs(methods) do
                signature(class_name .. "." .. method, class[method])
            end
        end
    end
end

local function probe_unit_extensions()
    local players = Managers.player
    local player = players and players:local_player_safe(1)
    local unit = player and player.player_unit
    if not unit or not Unit.alive(unit) then
        mod:info("[probe] unit section: no unit")
        return
    end
    for _, name in ipairs({ "minigame_system", "character_state_machine_system", "unit_data_system" }) do
        local ok, extension = pcall(ScriptUnit.has_extension, unit, name)
        mod:info("[probe] ScriptUnit.has_extension(%s) = %s", name, tostring(ok and extension or ("err:" .. tostring(extension))))
        if ok and type(extension) == "table" and name == "minigame_system" then
            dump_table("[probe]   minigame extension", extension, 0)
            for _, method in ipairs({ "minigame", "minigame_type", "is_active", "set_active", "setup_minigame" }) do
                signature("player.minigame_system:" .. method, extension[method])
            end
        end
        if ok and type(extension) == "table" and name == "character_state_machine_system" then
            local methods = {}
            local mt = getmetatable(extension)
            if type(mt) == "table" and type(mt.__index) == "table" then
                for key, value in pairs(mt.__index) do
                    if type(value) == "function" then methods[#methods + 1] = tostring(key) end
                end
            end
            table.sort(methods)
            mod:info("[probe]   CSM methods: %s", table.concat(methods, ", "):sub(1, 1200))
        end
    end
end

local function probe_system_instance()
    local manager = Managers.state and Managers.state.extension
    if not (manager and type(manager.system) == "function") then
        return
    end
    local ok, system = pcall(manager.system, manager, "minigame_system")
    mod:info("[probe] extension manager:system('minigame_system') = %s", tostring(ok and system or ("err:" .. tostring(system))))
    if ok and type(system) == "table" then
        for key, value in pairs(system) do
            if type(value) ~= "function" then
                mod:info("[probe]   system.%s = %s (%s)", tostring(key), tostring(value), type(value))
            end
        end
        signature("MinigameSystem:set_unit_local", system.set_unit_local)
        signature("MinigameSystem:default_minigame_type", system.default_minigame_type)
    end
end

-- 唯一会"动手"的一段：用空 context 试着构造 MinigameBalance，只看它报什么错（pcall，不留状态）。
local function probe_construct()
    local class = rawget(_G, "MinigameBalance")
    if type(class) ~= "table" or type(class.new) ~= "function" then
        mod:info("[probe] MinigameBalance:new not available")
        return
    end
    local ok, result = pcall(class.new, class, {})
    mod:info("[probe] MinigameBalance:new({}) -> ok=%s result=%s", tostring(ok), tostring(result))
    if ok and type(result) == "table" then
        dump_table("[probe]   constructed instance", result, 0)
    end
    local players = Managers.player
    local player = players and players:local_player_safe(1)
    local ok2, result2 = pcall(class.new, class, { player = player, is_server = false })
    mod:info("[probe] MinigameBalance:new({player=..., is_server=false}) -> ok=%s result=%s", tostring(ok2), tostring(result2))
end

local function probe_current_state()
    local players = Managers.player
    local player = players and players:local_player_safe(1)
    local unit = player and player.player_unit
    if not unit or not Unit.alive(unit) then
        mod:info("[probe] no local player unit (hub/main menu?)")
        return
    end
    local csm = ScriptUnit.has_extension(unit, "character_state_machine_system")
    if not csm then
        mod:info("[probe] no character_state_machine_system")
        return
    end
    local state = csm:current_state()
    mod:info("[probe] current CSM state: %s", tostring(state))
    dump_table("[probe] current state", state, 0)

    local ui = Managers.ui
    if ui and type(ui.view_active) == "function" then
        for _, view in ipairs({ "scanner_display_view", "minigame_balance_view", "minigame_view" }) do
            mod:info("[probe] view_active(%s) = %s", view, tostring(ui:view_active(view)))
        end
    end
end

mod:command("mg_probe", "dump the minigame API to the log (read-only)", function()
    mod:info("======== MinigameProbe dump ========")
    local ok, err = pcall(probe_settings)
    if not ok then mod:info("[probe] settings section failed: %s", tostring(err)) end
    ok, err = pcall(probe_globals)
    if not ok then mod:info("[probe] globals section failed: %s", tostring(err)) end
    ok, err = pcall(probe_extension_manager)
    if not ok then mod:info("[probe] extension section failed: %s", tostring(err)) end
    ok, err = pcall(probe_paths)
    if not ok then mod:info("[probe] require section failed: %s", tostring(err)) end
    ok, err = pcall(probe_current_state)
    if not ok then mod:info("[probe] state section failed: %s", tostring(err)) end
    mod:info("======== MinigameProbe dump end ========")
    mod:echo("MinigameProbe: dumped to the log (see console_logs)")
end)

-- /mg_sig —— 写 spawner 之前把"要传什么参数"问出来（反射，外加一次 pcall 构造尝试）。
-- 与 /mg_probe 分开：这一段会调用一次 MinigameBalance:new({})（pcall 包着，只为读错误信息），
-- 所以不放进只读的那条命令里。
mod:command("mg_sig", "dump target function signatures and try constructing a minigame (read-only except one pcall)", function()
    mod:info("======== MinigameProbe signatures ========")
    local ok, err = pcall(probe_signatures)
    if not ok then mod:info("[probe] signature section failed: %s", tostring(err)) end
    ok, err = pcall(probe_unit_extensions)
    if not ok then mod:info("[probe] unit extension section failed: %s", tostring(err)) end
    ok, err = pcall(probe_system_instance)
    if not ok then mod:info("[probe] system section failed: %s", tostring(err)) end
    ok, err = pcall(probe_construct)
    if not ok then mod:info("[probe] construct section failed: %s", tostring(err)) end
    mod:info("======== MinigameProbe signatures end ========")
    mod:echo("MinigameProbe: signature dump written to the log")
end)

mod:command("mg_obj", "dump the running minigame object, if any (read-only)", function()
    local players = Managers.player
    local player = players and players:local_player_safe(1)
    local unit = player and player.player_unit
    local csm = unit and Unit.alive(unit) and ScriptUnit.has_extension(unit, "character_state_machine_system")
    local state = csm and csm:current_state()
    local mg = state and state._minigame
    if not mg then
        mod:info("[probe] no minigame on the current state")
        mod:echo("MinigameProbe: no minigame right now")
        return
    end
    mod:info("[probe] minigame object: %s", tostring(mg))
    dump_table("[probe] minigame", mg, 0)
    local extension = mg._minigame_extension
    if extension then
        dump_table("[probe] minigame extension", extension, 0)
    end
    mod:echo("MinigameProbe: minigame dumped")
end)

mod:info("MinigameProbe loaded: use /mg_probe (and /mg_obj inside a minigame)")
