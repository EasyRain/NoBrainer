local mod = get_mod("NoBrainer")
local S = mod._S

local MinigameSettings = require("scripts/settings/minigame/minigame_settings")
local drill_active = false
local active_drill_key = nil
local drill_completed = false
local _drill_cleanup
local DRILL_MOVE_PENDING_TIMEOUT = 0.8
local DRILL_INTERMEDIATE_MOVE_PENDING_TIMEOUT = 0.2
local DRILL_SUBMIT_TIMEOUT = 1.2
local DRILL_CURSOR_SYNC_TOLERANCE = 1 / 128
local DRILL_MAX_STARTUP_DELAY = 0.35
local DRILL_MAX_MOVE_DELAY = 1.50
local DRILL_MAX_STAGE_DELAY = 1.50
local DRILL_MAX_SUBMIT_SETTLE = 1.65
local DRILL_RESTART_RECOVERY_TIMEOUT = 1.2
local drill_stopped_key = nil
local drill_stopped_until = 0
local drill_restart_key = nil
local drill_restart_until = 0

mod._drill.session_active = false
mod._drill.session_ready = false
mod._drill_pending_move = nil
mod._drill_submitted_stage = nil
mod._drill_submitted_until = 0
mod._drill_submit_timeout = DRILL_SUBMIT_TIMEOUT

local function _reset_snapshot()
	local drill = mod._drill
	drill.timer = 0
	drill.active = false
	drill.gameplay = false
	drill.searching = false
	drill.cursor_x = nil
	drill.cursor_y = nil
	drill.target_x = nil
	drill.target_y = nil
	drill.dir_x = 0
	drill.dir_y = 0
	drill.search = 0
	drill.on_target = false
	drill.stage = nil
	drill.target_index = nil
	drill.selected_index = nil
	drill.key = nil
end

local function _snapshot_fresh()
	local drill = mod._drill
	return drill and drill.session_active and drill.session_ready and drill.active and drill.timer > 0 and drill.gameplay
end

local function _is_active_drill_mg(mg)
	return mg ~= nil and active_drill_key == tostring(mg)
end

mod:hook_require("scripts/ui/views/scanner_display_view/minigame_drill_view", function(View)
	mod:hook_safe(View, "_update_target", function(self, _, minigame, _)
		if S("enable_drill_auto") then
			mod._drill_sample(minigame, true)
		end
		if not S("enable_drill") then
			return
		end
		local stage = minigame:current_stage()
		if not stage then
			return
		end
		if not self._target_widgets then
			return
		end
		if stage > #self._target_widgets then
			return
		end
		local tw = self._target_widgets[stage]
		if not tw then
			return
		end

		local correct = minigame:correct_targets()
		if not correct or not correct[stage] then
			return
		end
		local w = correct and correct[stage] and tw[correct[stage]]
		if w and w.style and w.style.highlight then
			local color = w.style.highlight.color
			if color then
				color[1], color[2], color[3], color[4] = 255, 255, 255, 255
			else
				w.style.highlight.color = { 255, 255, 255, 255 }
			end
		end
	end)
end)

local function _drill_move_delay()
	return mod._speed_pacing("drill_solve_speed") * DRILL_MAX_MOVE_DELAY
end

local function _clear_pending_move()
	mod._drill_pending_move = nil
end

local function _pending_move_active(now)
	local pending = mod._drill_pending_move
	if not pending then return false end

	now = now or mod._time("gameplay") or 0
	if now >= (pending.until_t or 0) then
		_clear_pending_move()
		return false
	end

	return true
end

local function _is_gameplay(mg)
	local state = mg and mg.state and mg:state()
	return not state or state == MinigameSettings.game_states.gameplay
end

local function _scanner_view_active()
	local ui = Managers.ui
	return ui and ui:view_active("scanner_display_view")
end

local function _arm_drill_session(mg, restart_until)
	_reset_snapshot()
	mod._drill.session_active = true
	mod._drill.session_ready = false
	mod._drill_cooldown = 0
	mod._drill_press_until = 0
	mod._drill_release_until = 0
	mod._drill_move_cooldown = 0
	mod._drill_startup_delay = mod._speed_pacing("drill_solve_speed") * DRILL_MAX_STARTUP_DELAY
	mod._drill_prev_cursor = nil
	mod._drill_submit_ready_since = nil
	_clear_pending_move()
	mod._drill_submitted_stage = nil
	mod._drill_submitted_until = 0
	drill_active = true
	active_drill_key = tostring(mg)
	drill_completed = false
	drill_stopped_key = nil
	drill_stopped_until = 0
	drill_restart_key = nil
	drill_restart_until = restart_until or 0
	mod._drill_sample(mg, false)
end

mod:hook_safe("MinigameDrill", "start", function(self, player)
	if not mod._is_local_minigame_player(player) then
		if drill_active and _is_active_drill_mg(self)
			or drill_restart_key and drill_restart_key == tostring(self)
			or drill_stopped_key and drill_stopped_key == tostring(self)
		then
			_drill_cleanup("ownership_transferred")
		end
		return
	end

	if not S("enable_drill_auto") then
		return
	end

	local now = mod._time("gameplay")
	local quick_restart = self._is_server ~= true
		and now ~= nil
		and drill_stopped_key == tostring(self)
		and now <= drill_stopped_until
	local restart_until = quick_restart and now + DRILL_RESTART_RECOVERY_TIMEOUT or 0

	_arm_drill_session(self, restart_until)
end)

mod:hook("MinigameDrill", "on_axis_set", function(func, self, t, x, y)
	if S("enable_drill_auto") then
		local pos = self._cursor_position
		local cx, cy = pos and pos.x, pos and pos.y

		func(self, t, x, y)

		local np = self._cursor_position
		if np and (np.x ~= cx or np.y ~= cy) then
			local delay = _drill_move_delay()
			if delay > 0 then
				mod._drill_move_cooldown = delay
			else
				mod._drill_move_cooldown = 0
			end
		end

		return
	end
	return func(self, t, x, y)
end)

mod:hook_safe("MinigameDrill", "set_searching", function(self, search_time)
	if not search_time and drill_active and _is_active_drill_mg(self)
		and mod._drill.session_active and not mod._drill.session_ready then
		mod._drill_sample(self, false)
	end
end)

_drill_cleanup = function(reason)
	drill_active = false
	active_drill_key = nil
	drill_completed = reason == "complete"
	drill_stopped_key = nil
	drill_stopped_until = 0
	drill_restart_key = nil
	drill_restart_until = 0
	mod._drill.session_active = false
	mod._drill.session_ready = false
	_clear_pending_move()
	_reset_snapshot()
	mod._drill_cooldown = 0
	mod._drill_press_until = 0
	mod._drill_release_until = 0
	mod._drill_move_cooldown = 0
	mod._drill_startup_delay = 0
	mod._drill_prev_cursor = nil
	mod._drill_submit_ready_since = nil
	mod._drill_submitted_stage = nil
	mod._drill_submitted_until = 0
end

mod:hook_safe("MinigameDrill", "stop", function(self, ...)
	local key = tostring(self)
	local active = _is_active_drill_mg(self)
	local player = select(1, ...)
	local arg_count = select("#", ...)
	local now = mod._time("gameplay")
	local local_stop = arg_count > 0 and mod._is_local_minigame_player(player)
	local stale_stop_before_restart = arg_count == 0
		and not active
		and self._is_server ~= true
		and drill_stopped_key == key
	local recoverable_restart = active
		and arg_count == 0
		and self._is_server ~= true
		and not drill_completed
		and now ~= nil
		and now <= drill_restart_until
	local restart_until = drill_restart_until

	if active or drill_restart_key == key then
		_drill_cleanup(not drill_completed and "stop" or nil)
	end

	if local_stop and self._is_server ~= true and now then
		drill_stopped_key = key
		drill_stopped_until = now + DRILL_RESTART_RECOVERY_TIMEOUT
	elseif stale_stop_before_restart then
		drill_stopped_key = nil
		drill_stopped_until = 0
	elseif recoverable_restart then
		drill_restart_key = key
		drill_restart_until = restart_until
	end
end)
mod:hook_safe("MinigameDrill", "complete", function(self)
	if _is_active_drill_mg(self) or drill_restart_key == tostring(self) then
		_drill_cleanup("complete")
	end
end)

local function _recovery_state_ready(drill, mg)
	local stage = drill.stage
	if type(stage) ~= "number" or stage < 1 or stage > MinigameSettings.drill_stage_amount then return false end
	if not drill.cursor_x or not drill.cursor_y or not drill.target_index or not drill.target_x or not drill.target_y then return false end

	if not drill.searching then
		return drill.selected_index == nil
			and math.abs(drill.cursor_x) <= 0.001
			and math.abs(drill.cursor_y) <= 0.001
	end

	local targets = mg and mg.targets and mg:targets()
	local selected = drill.selected_index and targets and targets[stage] and targets[stage][drill.selected_index]

	return selected ~= nil
		and math.abs(drill.cursor_x - selected.x) <= DRILL_CURSOR_SYNC_TOLERANCE
		and math.abs(drill.cursor_y - selected.y) <= DRILL_CURSOR_SYNC_TOLERANCE
end

function mod._drill_rearm_from_state(state, t)
	if not drill_restart_key then return end

	local now = t or mod._time("gameplay")
	if not now or now > drill_restart_until then
		drill_restart_key = nil
		drill_restart_until = 0
		return
	end
	if drill_active or not S("enable_drill_auto") then return end

	local mg = state and state._minigame
	local player = state and state._player
	if not mg or tostring(mg) ~= drill_restart_key then return end
	if mg._is_server == true or not mod._is_local_minigame_player(player) or not _scanner_view_active() then return end
	if mg.is_completed and mg:is_completed() or not _is_gameplay(mg) then return end
	local unit = mg._minigame_unit
	if not unit or not Unit.alive(unit) then return end

	mod._drill_sample(mg, false)
	if not _recovery_state_ready(mod._drill, mg) then return end

	local restart_until = drill_restart_until
	_arm_drill_session(mg, restart_until)
	mod._drill.session_ready = _recovery_state_ready(mod._drill, mg)
end

local function _target_for(mg)
	if not mg then return nil end

	local stage = mg:current_stage()
	local correct = stage and mg:correct_targets()
	local idx = correct and correct[stage]
	local targets = stage and mg:targets()

	return stage, idx, idx and targets and targets[stage] and targets[stage][idx]
end

local function _initial_state_ready(drill)
	return drill.stage == 1
		and drill.cursor_x ~= nil and math.abs(drill.cursor_x) <= 0.001
		and drill.cursor_y ~= nil and math.abs(drill.cursor_y) <= 0.001
		and not drill.searching
		and drill.target_index ~= nil
		and drill.target_x ~= nil and drill.target_y ~= nil
end

function mod._drill_sample(mg, allow_server_fallback)
	local drill = mod._drill
	if not drill then return end
	local key = mg and tostring(mg) or nil

	if key and drill.key and drill.key ~= key then
		mod._drill_cooldown = 0
		mod._drill_press_until = 0
		mod._drill_release_until = 0
		mod._drill_move_cooldown = 0
		mod._drill_prev_cursor = nil
		mod._drill_submit_ready_since = nil
		_clear_pending_move()
		mod._drill_submitted_stage = nil
		mod._drill_submitted_until = 0
	end

	if not mg or not _is_gameplay(mg) then
		_reset_snapshot()
		return
	end

	local cursor = mg:cursor_position()
	local stage, target_index, target = _target_for(mg)
	local searching = mg.is_searching and mg:is_searching() == true or false
	local selected_index = mg.selected_index and mg:selected_index() or mg._selected_index
	local now = mod._time("gameplay")
	local search = now and searching and mg.search_percentage and mg:search_percentage(now) or 0
	local on_target = mg.is_on_target and mg:is_on_target() == true or false
	local previous_stage = drill.stage

	drill.timer = 0.075
	drill.active = true
	drill.gameplay = true
	drill.searching = searching
	drill.cursor_x = cursor and cursor.x or nil
	drill.cursor_y = cursor and cursor.y or nil
	drill.target_x = target and target.x or nil
	drill.target_y = target and target.y or nil
	drill.search = search or 0
	drill.on_target = on_target
	drill.stage = stage
	drill.target_index = target_index
	drill.selected_index = selected_index
	drill.key = key

	if drill.session_active and previous_stage and stage and previous_stage ~= stage then
		mod._drill_submit_ready_since = nil
		mod._drill_startup_delay = mod._speed_pacing("drill_solve_speed") * DRILL_MAX_STAGE_DELAY
	end

	if drill.session_active and not drill.session_ready then
		if _initial_state_ready(drill) then
			drill.session_ready = true
		end
	end

	if cursor and target then
		local dx = target.x - cursor.x
		local dy = -(target.y - cursor.y)
		local len = math.sqrt(dx * dx + dy * dy)
		if len > 0.01 then
			drill.dir_x = dx / len
			drill.dir_y = dy / len
		else
			drill.dir_x = 0
			drill.dir_y = 0
		end
	else
		drill.dir_x = 0
		drill.dir_y = 0
	end

	if allow_server_fallback and drill.session_active and drill.session_ready and now and mg._is_server and mod._drill_cooldown <= 0
		and mod._drill_should_submit and mod._drill_should_submit() then
		mod._drill_cooldown = 0.15
		mg:on_action_pressed(now)
	end
end

function mod._drill_move_vec()
	local drill = mod._drill
	if not drill or not drill.session_active or not drill.session_ready or drill.timer <= 0 or not drill.active then return nil end
	if not drill.gameplay then
		return nil
	end
	if not drill.cursor_x or not drill.cursor_y then
		return nil
	end
	if not drill.target_x or not drill.target_y then
		return nil
	end

	if drill.dir_x == 0 and drill.dir_y == 0 then return nil end
	return Vector3(drill.dir_x, drill.dir_y, 0)
end

function mod._drill_move_blocked(now)
	local submit_pending = now ~= nil and mod._drill_submitted_stage == mod._drill.stage
		and now < (mod._drill_submitted_until or 0)

	return submit_pending or _pending_move_active(now) or (mod._drill_move_cooldown or 0) > 0
end

function mod._drill_take_move_vec(now)
	now = now or mod._time("gameplay")
	if not now or mod._drill_move_blocked(now) then return nil end

	local dir = mod._drill_move_vec()
	local drill = mod._drill
	if not dir or not drill.target_x or not drill.target_y or not drill.target_index then return dir end
	local pending_timeout = drill.searching and drill.selected_index and drill.selected_index ~= drill.target_index
		and DRILL_INTERMEDIATE_MOVE_PENDING_TIMEOUT or DRILL_MOVE_PENDING_TIMEOUT

	mod._drill_pending_move = {
		stage = drill.stage,
		target_index = drill.target_index,
		target_x = drill.target_x,
		target_y = drill.target_y,
		until_t = now + pending_timeout,
	}

	return dir
end

function mod._drill_should_submit(now)
	local drill = mod._drill
	if not _snapshot_fresh() then
		mod._drill_submit_ready_since = nil
		return false
	end
	if not drill.searching then
		mod._drill_submit_ready_since = nil
		return false
	end

	if (drill.search or 0) < 1 then
		mod._drill_submit_ready_since = nil
		return false
	end

	if not drill.on_target then
		mod._drill_submit_ready_since = nil
		return false
    end

	local pacing = mod._speed_pacing("drill_solve_speed")
	if pacing <= 0 then return true end

	now = now or mod._time("gameplay")
	if not now then return false end

	if not mod._drill_submit_ready_since then
		mod._drill_submit_ready_since = now
		return false
	end

	return now - mod._drill_submit_ready_since >= DRILL_MAX_SUBMIT_SETTLE * pacing
end

local function on_update(dt)
	local drill = mod._drill
	if drill and drill.timer > 0 then drill.timer = math.max(drill.timer - dt, 0) end
	if mod._drill_startup_delay > 0 then mod._drill_startup_delay = math.max(mod._drill_startup_delay - dt, 0) end
	if mod._drill_cooldown > 0 then mod._drill_cooldown = math.max(mod._drill_cooldown - dt, 0) end
	if mod._drill_move_cooldown > 0 then mod._drill_move_cooldown = math.max(mod._drill_move_cooldown - dt, 0) end

	if drill and drill.session_active and drill.session_ready and drill.timer > 0 then
		local prev = mod._drill_prev_cursor
		local cursor_changed = drill.cursor_x and drill.cursor_y and prev and (drill.cursor_x ~= prev.x or drill.cursor_y ~= prev.y)
		local pending = mod._drill_pending_move
		local pending_synced = pending
			and drill.stage == pending.stage
			and drill.selected_index == pending.target_index
			and drill.cursor_x and math.abs(drill.cursor_x - pending.target_x) <= DRILL_CURSOR_SYNC_TOLERANCE
			and drill.cursor_y and math.abs(drill.cursor_y - pending.target_y) <= DRILL_CURSOR_SYNC_TOLERANCE

		if pending_synced then
			_clear_pending_move()
			local delay = _drill_move_delay()
			if delay > 0 then
				mod._drill_move_cooldown = delay
			else
				mod._drill_move_cooldown = 0
			end
		elseif cursor_changed then
			local intermediate_move = pending and drill.stage == pending.stage
				and drill.selected_index ~= nil and drill.selected_index ~= pending.target_index
			_clear_pending_move()
			if intermediate_move then
				mod._drill_move_cooldown = 0
			else
				local delay = _drill_move_delay()
				if delay > 0 then
					mod._drill_move_cooldown = delay
				else
					mod._drill_move_cooldown = 0
				end
			end
		end
		if drill.cursor_x and drill.cursor_y then
			if prev then
				prev.x = drill.cursor_x
				prev.y = drill.cursor_y
			else
				mod._drill_prev_cursor = { x = drill.cursor_x, y = drill.cursor_y }
			end
		else
			mod._drill_prev_cursor = nil
		end

		if mod._drill_submitted_stage and drill.stage and mod._drill_submitted_stage ~= drill.stage then
			mod._drill_submitted_stage = nil
			mod._drill_submitted_until = 0
			mod._drill_submit_ready_since = nil
		elseif (mod._drill_submitted_until or 0) > 0 then
			local now = mod._time("gameplay")
			if now and now >= mod._drill_submitted_until then
				mod._drill_submitted_stage = nil
				mod._drill_submitted_until = 0
			end
		end
	end
end

local function on_setting(id)
	if id == "enable_drill_auto" then
		_drill_cleanup(drill_active and "setting_changed" or nil)
	end
end

local function on_round_end() _drill_cleanup(drill_active and "round_end" or nil) end

mod._reg("update", on_update)
mod._reg("setting_changed", on_setting)
mod._reg("round_end", on_round_end)

return true
