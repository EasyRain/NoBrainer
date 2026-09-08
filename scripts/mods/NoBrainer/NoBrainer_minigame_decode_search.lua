local mod = get_mod("NoBrainer")
local S = mod._S

local MinigameSettings, SearchViewSettings, UIWidget
local BW, BH, CW, CH
local function _deps()
	if not MinigameSettings then
		MinigameSettings = require("scripts/settings/minigame/minigame_settings")
		SearchViewSettings = require("scripts/ui/views/scanner_display_view/scanner_display_view_decode_search_settings")
		UIWidget = require("scripts/managers/ui/ui_widget")
		BW = MinigameSettings.decode_search_board_width or 6
		BH = MinigameSettings.decode_search_board_height or 4
		CW = MinigameSettings.decode_search_cursor_width or 2
		CH = MinigameSettings.decode_search_cursor_height or 2
	end
end

local HIGHLIGHT = { 110, 255, 165, 0 }
local SEARCH_MOVE_SYNC_LOCK = 0.35
local SEARCH_MOVE_PENDING_TIMEOUT = 0.8
local SEARCH_MAX_MOVE_DELAY = 1.054
local SEARCH_MAX_STAGE_DELAY = 1.632
local SEARCH_MAX_SUBMIT_SETTLE = 0.646
local SEARCH_MAX_AFTER_MOVE_DELAY = 0.510
local SEARCH_STARTUP_DELAY = 0.20
local SEARCH_RESTART_RECOVERY_TIMEOUT = 1.2
local _find_target
local search_active = false
local active_search_key = nil
local search_completed = false
local search_restart_key = nil
local search_restart_until = 0

mod._exp.session_active = false

local function _game_time()
	return mod._time("gameplay")
end

local function _n(v, fallback)
    local t = type(v)
    if t == "number" then return math.floor(v + 0.5) end
    if t == "string" then
        local n = tonumber(v)
        return n and math.floor(n + 0.5) or fallback
    end

    if t == "table" then
        for _, x in ipairs(v) do
            local r = _n(x, nil)

            if r then
                return r
            end
        end

        for k, x in pairs(v) do
            if k ~= "id" and k ~= "value" then
                local r = _n(x, nil)

                if r then
                    return r
                end
            end
        end

        return v.symbol or v.symbol_id or v.id or v.value or fallback
    end
    return fallback
end

local function _flat4(grid)
    if type(grid) ~= "table" then return nil end
    local flat = {}
    if #grid == CW * CH and type(grid[1]) == "number" then
        for i = 1, CW * CH do
            flat[i] = _n(grid[i], 1) or 1
        end

        return flat
    end
    if type(grid[1]) == "table" then
        for y = 1, CH do
            for x = 1, CW do
                flat[#flat + 1] = _n(grid[y] and grid[y][x], 1) or 1
            end
        end

        return flat
    end
    if #grid >= BW then
        return nil
    end
    return nil
end

local function _mg(view)
	local ext = view and view._minigame_extension
	if not ext or not ext.minigame then return nil end

	return ext:minigame(MinigameSettings.types.decode_search)
end

local function _exp_move_delay()
	return mod._speed_pacing("expedition_solve_speed") * SEARCH_MAX_MOVE_DELAY
end

local function _arm_move_cooldown()
	mod._exp_move_cooldown = math.max(mod._exp_move_cooldown or 0, _exp_move_delay(), SEARCH_MOVE_SYNC_LOCK)
end

local function _arm_acknowledged_move_cooldown()
	mod._exp_move_cooldown = _exp_move_delay()
end

local function _is_gameplay(mg)
	_deps()
	local state = mg and mg.state and mg:state()
	return not state or state == MinigameSettings.game_states.gameplay
end

local function _scanner_view_active()
	local ui = Managers.ui
	return ui and ui:view_active("scanner_display_view")
end

local function _reset_submit_settle()
	mod._exp_on_target_since = 0
	mod._exp_on_target_stage = nil
	mod._exp_on_target_cursor_x = nil
	mod._exp_on_target_cursor_y = nil
	mod._exp_on_target_target_x = nil
	mod._exp_on_target_target_y = nil
end

local function _clear_pending_move()
	mod._exp_pending_move = nil
end

local function _pending_move_active(now)
	local pending = mod._exp_pending_move

	if not pending then return false end

	now = now or _game_time() or 0

	if now >= (pending.until_t or 0) then
		_clear_pending_move()
		_reset_submit_settle()
		return false
	end

	return true
end

local function _stage(mg)
	return mg and mg.current_stage and mg:current_stage() or mg and mg._current_stage
end

local function _reset_snapshot()
	local exp = mod._exp
	exp.timer = 0
	exp.active = false
	exp.gameplay = false
	exp.completed = false
	exp.cursor_x = nil
	exp.cursor_y = nil
	exp.target_x = nil
	exp.target_y = nil
	exp.dir_x = 0
	exp.dir_y = 0
	exp.on_target = false
	exp.stage = nil
	exp.key = nil
end

local function _snapshot_fresh()
	local exp = mod._exp
	return exp and exp.session_active and exp.active and exp.timer > 0 and exp.gameplay and not exp.completed
end

local function _is_active_search_mg(mg)
	return search_active and mg ~= nil and active_search_key == tostring(mg)
end

local function _sample_search(mg)
	local exp = mod._exp
	if not exp then return end
	local key = mg and tostring(mg) or nil

	if key and exp.key and exp.key ~= key then
		_clear_pending_move()
		_reset_submit_settle()
		mod._exp_press_until = 0
		mod._exp_release_until = 0
		mod._exp_move_cooldown = 0
		mod._exp_submitted_stage = nil
		mod._exp_submitted_until = 0
		mod._exp_prev_cursor = nil
		mod._exp_last_move_at = 0
	end

	if not S("enable_expedition_auto_solve") or not mg or not mg.cursor_position then
		_reset_snapshot()
		return
	end

	_deps()
	local completed = mg.is_completed and mg:is_completed() == true or false
	local gameplay = not completed and _is_gameplay(mg)
	local cursor = gameplay and mg:cursor_position() or nil
	local target = cursor and _find_target(mg, cursor) or nil
	local stage = _stage(mg)

	exp.timer = 0.075
	exp.active = true
	exp.gameplay = gameplay
	exp.completed = completed
	exp.stage = stage
	exp.key = key
	exp.cursor_x = cursor and cursor.x or nil
	exp.cursor_y = cursor and cursor.y or nil
	exp.target_x = target and target.x or nil
	exp.target_y = target and target.y or nil
	exp.on_target = cursor and target and cursor.x == target.x and cursor.y == target.y or false

	if cursor and target then
		local dx = target.x - cursor.x
		local dy = target.y - cursor.y
		exp.dir_x = dx == 0 and 0 or dx > 0 and 1 or -1
		exp.dir_y = dy == 0 and 0 or dy > 0 and -1 or 1
	else
		exp.dir_x = 0
		exp.dir_y = 0
	end

end

local function _cursor_target()
	local exp = mod._exp
	if not _snapshot_fresh() then return nil, nil, nil, nil, exp and exp.stage end
	return exp.cursor_x, exp.cursor_y, exp.target_x, exp.target_y, exp.stage
end

_find_target = function(mg, cursor)
	_deps()
	if not mg or not mg.get_symbols_for_target then return nil end
	local stage = mg.current_stage and mg:current_stage() or mg._current_stage
	if not stage then return nil end

	local cache = mg._nb_mtc
	if cache and cache._stage == stage then return cache end

	local target = mg._decode_targets and mg._decode_targets[stage]
	if not target then
		if mg.decode_targets then
			local tgs = mg.decode_targets(mg)
			target = tgs and tgs[stage]
		end
	end
	if not target then return nil end

	local tx, ty
	if type(target) == "table" then
		if target.x then tx, ty = target.x, target.y
		elseif target.target_x then tx, ty = target.target_x, target.target_y
		elseif #target == 2 and type(target[1]) == "number" then tx, ty = target[1], target[2]
		end
	end

	if tx ~= nil then
		local mx = math.max(BW - CW + 1, 1)
        local my = math.max(BH - CH + 1, 1)

		if tx >= 0 and tx <= mx - 1 then tx = tx + 1 end
		if ty >= 0 and ty <= my - 1 then ty = ty + 1 end
		tx = math.clamp(math.floor(tx + 0.5), 1, mx)
		ty = math.clamp(math.floor(ty + 0.5), 1, my)
		cache = { x = tx, y = ty, _stage = stage }
		mg._nb_mtc = cache
		return cache
	end

	local tflat = _flat4(target)
	if not tflat then return nil end

	if not mg.get_symbols_for_target then return nil end
	local mx = math.max(BW - CW + 1, 1)
    local my = math.max(BH - CH + 1, 1)
	if not cursor and mg.cursor_position then
		cursor = mg:cursor_position()
	end
	local best
	local best_steps = math.huge
	local best_distance = math.huge

	for y = 1, my do
        for x = 1, mx do
			local grid = mg.get_symbols_for_target(mg, x, y)
			if grid then
				local gflat = _flat4(grid)
				if gflat then
					local match = true

					for i = 1, CW * CH do
                        if gflat[i] ~= tflat[i] then
                            match = false
                            break
                        end
					end

					if match then
						local dx = cursor and math.abs(x - cursor.x) or 0
						local dy = cursor and math.abs(y - cursor.y) or 0
						local steps = math.max(dx, dy)
						local distance = dx + dy

						if not best or steps < best_steps or steps == best_steps and distance < best_distance then
							best = { x = x, y = y }
							best_steps = steps
							best_distance = distance
						end
					end
				end
			end
		end
    end

	if best then
		cache = { x = best.x, y = best.y, _stage = stage }
		mg._nb_mtc = cache
		return cache
	end

	return nil
end

local function _widgets(view, n)
	if n <= 0 then
        view._nb_mw = nil
        return nil
    end

	local w = view._nb_mw
	if w and #w == n then return w end
	_deps()
	w = {}
	for i = 1, n do
		local def = UIWidget.create_definition({{
			pass_type = "texture", style_id = "highlight",
			value = "content/ui/materials/backgrounds/scanner/scanner_decode_symbol_highlight",
			style = { hdr = true, color = HIGHLIGHT },
		}}, "center_pivot", nil, SearchViewSettings.symbol_widget_size)
		w[i] = UIWidget.init("nb_mw_" .. i, def)
	end
	view._nb_mw = w
	return w
end

mod:hook_require("scripts/ui/views/scanner_display_view/minigame_decode_search_view", function(View)
	mod:hook_safe(View, "draw_widgets", function(self, _, __, ___, ui_renderer)
		_deps()
		local mg = _mg(self)
		_sample_search(mg)
		if not S("enable_matching") or not ui_renderer then
			return
		end
		if not mg or not mg.symbols or not mg.current_stage then
			return
		end

        if self._nb_mm ~= mg then
            self._nb_mm = mg
            self._nb_mw = nil

            if mg then
                mg._nb_mtc = nil
            end
        end

		local pos = _find_target(mg)
		if not pos then
			return
		end

		local w = _widgets(self, CW * CH)
		if not w then return end

		local ws = SearchViewSettings.symbol_widget_size
		local sp = SearchViewSettings.symbol_spacing or 0
		local ox = SearchViewSettings.symbol_starting_offset_x or 0
		local oy = SearchViewSettings.symbol_starting_offset_y or 0

		local i = 0
		for y = 0, CH - 1 do
			for x = 0, CW - 1 do
				i = i + 1
				local wi = w[i]
				local sx = pos.x + x
				local sy = pos.y + y

				wi.style.highlight.color = HIGHLIGHT
				wi.offset[1] = ox + (ws[1] + sp) * (sx - 1)
				wi.offset[2] = oy + (ws[2] + sp) * (sy - 1)
				wi.offset[3] = 6
				UIWidget.draw(wi, ui_renderer)
			end
		end
	end)
end)

mod._exp_find_target = _find_target

local function _clear_match_cache(mg)
	if mg then
		mg._nb_mtc = nil
	end

	_clear_pending_move()
	_reset_submit_settle()
end

local function _mark_move_sent(cursor_x, cursor_y, dir, now)
	_arm_move_cooldown()
	mod._exp_last_move_at = now
	mod._exp_pending_move = {
		cursor_x = cursor_x,
		cursor_y = cursor_y,
		dir_x = dir and dir.x,
		dir_y = dir and dir.y,
		until_t = now + SEARCH_MOVE_PENDING_TIMEOUT,
	}
	_reset_submit_settle()
end

function mod._exp_find_move_dir()
	local exp = mod._exp
	if not exp or not exp.session_active or exp.timer <= 0 or not exp.active then return nil end
	if not exp.gameplay then
		return nil
    end

	if not exp.cursor_x or not exp.cursor_y then
		return nil
    end

	if not exp.target_x or not exp.target_y then
		return nil
    end

	local dx = exp.target_x - exp.cursor_x
	local dy = exp.target_y - exp.cursor_y

	if dx == 0 and dy == 0 then return nil end

	local x = dx == 0 and 0 or dx > 0 and 1 or -1
	local y = dy == 0 and 0 or dy > 0 and -1 or 1

	return Vector3(x, y, 0)
end

function mod._exp_move_blocked(now)
	return _pending_move_active(now) or (mod._exp_move_cooldown or 0) > 0
end

function mod._exp_take_move_dir(now)
	now = now or _game_time()
	if not now then return nil end

	if _pending_move_active(now) then
		return nil
	end

	if (mod._exp_move_cooldown or 0) > 0 then
		return nil
	end

	local cursor_x, cursor_y = _cursor_target()
	local dir = mod._exp_find_move_dir()

	if dir then
		_mark_move_sent(cursor_x, cursor_y, dir, now)
	end

	return dir
end

function mod._exp_is_on_target()
	local exp = mod._exp
	return exp and exp.timer > 0 and exp.on_target == true
end

function mod._exp_ready_to_submit(now)
	now = now or _game_time()
	local exp = mod._exp
	if not exp or not exp.session_active or not now or exp.timer <= 0 or not exp.active then return false end
	if not exp.gameplay then
		_reset_submit_settle()
        return false
    end

	local cursor_x, cursor_y, target_x, target_y, stage = _cursor_target()

	if cursor_x == nil or cursor_y == nil or target_x == nil or target_y == nil or not exp.on_target then
		_reset_submit_settle()
		return false
	end

	local pacing = mod._speed_pacing("expedition_solve_speed")
	local fast_submit = pacing <= 0

	if fast_submit then
		if _pending_move_active(now) then
			return false
		end
	else
		local last_move_at = mod._exp_last_move_at or 0
		local since_move = now - last_move_at

		if since_move < SEARCH_MAX_AFTER_MOVE_DELAY * pacing then
			return false
		end
	end

	local changed = mod._exp_on_target_stage ~= stage
		or mod._exp_on_target_cursor_x ~= cursor_x
		or mod._exp_on_target_cursor_y ~= cursor_y
		or mod._exp_on_target_target_x ~= target_x
		or mod._exp_on_target_target_y ~= target_y

	if changed then
		mod._exp_on_target_since = now
		mod._exp_on_target_stage = stage
		mod._exp_on_target_cursor_x = cursor_x
		mod._exp_on_target_cursor_y = cursor_y
		mod._exp_on_target_target_x = target_x
		mod._exp_on_target_target_y = target_y
		return false
	end

	local elapsed = now - (mod._exp_on_target_since or now)

	if fast_submit and elapsed <= 0 then
		return false
	elseif not fast_submit and elapsed < SEARCH_MAX_SUBMIT_SETTLE * pacing then
		return false
	end

	return true
end

function mod._exp_handle_stage_changed(_old_stage, _new_stage)
	_clear_pending_move()
	_reset_submit_settle()
	mod._exp_move_cooldown = mod._speed_pacing("expedition_solve_speed") * SEARCH_MAX_STAGE_DELAY
	mod._exp_submitted_stage = nil
	mod._exp_submitted_until = 0
end

local function _exp_cleanup(reason)
	search_active = false
	active_search_key = nil
	search_completed = reason == "complete"
	search_restart_key = nil
	search_restart_until = 0
	mod._exp.session_active = false
	_reset_snapshot()
	mod._exp_press_until = 0
	mod._exp_release_until = 0
	mod._exp_move_cooldown = 0
	mod._exp_startup_delay = 0
	mod._exp_submitted_stage = nil
	mod._exp_submitted_until = 0
	mod._exp_prev_cursor = nil
	mod._exp_last_move_at = 0
	_clear_pending_move()
	_reset_submit_settle()
end

local function _arm_search_session(mg, restart_until)
	local now = _game_time()

	_reset_snapshot()
	mod._exp.session_active = true
	mod._exp_press_until = 0
	mod._exp_release_until = 0
	mod._exp_move_cooldown = 0
	mod._exp_startup_delay = SEARCH_STARTUP_DELAY
	mod._exp_submitted_stage = nil
	mod._exp_submitted_until = 0
	mod._exp_prev_cursor = nil
	mod._exp_last_move_at = 0
	search_active = true
	active_search_key = tostring(mg)
	search_completed = false
	search_restart_key = nil
	search_restart_until = restart_until or (now and now + SEARCH_RESTART_RECOVERY_TIMEOUT or 0)
	_sample_search(mg)
end

local function _is_teardown_stop_error(err)
	local text = tostring(err)

	return text:find("destroyed object of type MinigameExtension", 1, true) ~= nil
		or text:find("UnitReference is not valid", 1, true) ~= nil
end

mod:hook_safe("MinigameDecodeSearch", "start", function(self, player)
	if not mod._is_local_minigame_player(player) then
		if search_active and _is_active_search_mg(self)
			or search_restart_key and search_restart_key == tostring(self)
		then
			_exp_cleanup("ownership_transferred")
		end
		return
	end
	_clear_match_cache(self)

	if S("enable_expedition_auto_solve") then
		_arm_search_session(self)
	end
end)
mod:hook("MinigameDecodeSearch", "stop", function(func, self, ...)
	local unit = self and self._minigame_unit
	local active = _is_active_search_mg(self)
	local cleanup_reason = active and not search_completed and "stop" or nil
	local now = _game_time()
	local restart_until = search_restart_until
	local recoverable_restart = active
		and select(1, ...) == nil
		and not search_completed
		and now ~= nil
		and now <= restart_until

	if unit and Unit.alive(unit) then
		local ok, result = pcall(func, self, ...)
		if not ok then
			if _is_teardown_stop_error(result) then
				if active then _exp_cleanup(cleanup_reason or "stop_teardown_race") end
				return nil
			end

			error(result)
		end

		if active then
			_exp_cleanup(cleanup_reason)

			if recoverable_restart then
				search_restart_key = tostring(self)
				search_restart_until = restart_until
			end
		end
		return result
	end

	if active then
		_exp_cleanup(search_active and not search_completed and "stop_invalid_unit" or nil)
	end
end)
mod:hook_safe("MinigameDecodeSearch", "complete", function(self)
	if _is_active_search_mg(self) or search_restart_key == tostring(self) then
		_exp_cleanup("complete")
	end
end)
mod:hook_safe("MinigameDecodeSearch", "generate_board", _clear_match_cache)
mod:hook_safe("MinigameDecodeSearch", "set_symbols", _clear_match_cache)

function mod._exp_rearm_from_state(state, t)
	if not search_restart_key then return end

	local now = t or _game_time()
	if not now or now > search_restart_until then
		search_restart_key = nil
		search_restart_until = 0
		return
	end
	if search_active or not S("enable_expedition_auto_solve") then return end

	local mg = state and state._minigame
	local player = state and state._player
	if not mg or tostring(mg) ~= search_restart_key then return end
	if not mod._is_local_minigame_player(player) or not _scanner_view_active() then return end
	if mg.is_completed and mg:is_completed() or not _is_gameplay(mg) then return end

	local restart_until = search_restart_until
	_clear_match_cache(mg)
	_arm_search_session(mg, restart_until)
end

mod:hook("MinigameDecodeSearch", "on_axis_set", function(func, self, t, x, y)
	if S("enable_expedition_auto_solve") then
		local pos = self._cursor_position
		local cx, cy = pos and pos.x, pos and pos.y

		func(self, t, x, y)

		local np = self._cursor_position
		if np and (np.x ~= cx or np.y ~= cy) then
			_clear_pending_move()
			_reset_submit_settle()
			mod._exp_last_move_at = t or _game_time() or 0
			_arm_acknowledged_move_cooldown()
		end

		return
	end
	return func(self, t, x, y)
end)

local function on_round_end_move() _exp_cleanup(search_active and "round_end" or nil) end
mod._reg("round_end", on_round_end_move)

local function on_setting(id)
	if id == "enable_expedition_auto_solve" then
		_exp_cleanup(search_active and "setting_changed" or nil)
	end
end
mod._reg("setting_changed", on_setting)

local function on_update_exp(dt)
	local exp = mod._exp
	if exp and exp.timer > 0 then exp.timer = math.max(exp.timer - dt, 0) end
	if mod._exp_startup_delay > 0 then
		mod._exp_startup_delay = math.max(mod._exp_startup_delay - dt, 0)
	end
	if mod._exp_move_cooldown > 0 then mod._exp_move_cooldown = math.max(mod._exp_move_cooldown - dt, 0) end

	if not S("enable_expedition_auto_solve") or not exp or not exp.session_active or exp.timer <= 0 or not exp.active then return end

	local prev = mod._exp_prev_cursor
	if exp.cursor_x and exp.cursor_y and prev and (exp.cursor_x ~= prev.x or exp.cursor_y ~= prev.y) then
		local pending = mod._exp_pending_move
		local expected_x = pending and pending.cursor_x and pending.dir_x and pending.cursor_x + pending.dir_x
		local expected_y = pending and pending.cursor_y and pending.dir_y and pending.cursor_y - pending.dir_y
		local sync_complete = not pending or exp.cursor_x == expected_x and exp.cursor_y == expected_y

		if sync_complete then
			_clear_pending_move()
			_reset_submit_settle()
			mod._exp_last_move_at = _game_time() or mod._exp_last_move_at or 0
			_arm_acknowledged_move_cooldown()
		end
	end
	if exp.cursor_x and exp.cursor_y then
		if prev then
			prev.x = exp.cursor_x
			prev.y = exp.cursor_y
		else
			mod._exp_prev_cursor = { x = exp.cursor_x, y = exp.cursor_y }
		end
	else
		mod._exp_prev_cursor = nil
	end

	if mod._exp_startup_delay > 0 then return end

	local stage = exp.stage
	if mod._exp_submitted_stage and stage and mod._exp_submitted_stage ~= stage then
		mod._exp_handle_stage_changed(mod._exp_submitted_stage, stage)
	elseif (mod._exp_submitted_until or 0) > 0 then
		local now = mod._time("gameplay")
		if now and now >= mod._exp_submitted_until then
			mod._exp_submitted_stage = nil
			mod._exp_submitted_until = 0
		end
	end
end
mod._reg("update", on_update_exp)

return true
