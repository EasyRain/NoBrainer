local mod = get_mod("NoBrainer")
local S = mod._S

local MinigameSettings, DecodeSymbolsViewSettings, UIWidget
local function _deps()
	if not MinigameSettings then
		MinigameSettings = require("scripts/settings/minigame/minigame_settings")
		DecodeSymbolsViewSettings = require("scripts/ui/views/scanner_display_view/scanner_display_view_decode_symbols_settings")
		UIWidget = require("scripts/managers/ui/ui_widget")
	end
end

local PREVIEW_DECODE_MAX_GRID_HEIGHT = 920

local _cached_layout_mg = nil
local _cached_layout = nil
local function _decode_layout(minigame)
	if _cached_layout_mg == minigame and _cached_layout then return _cached_layout end
	_deps()
	local bw = DecodeSymbolsViewSettings.decode_symbol_widget_size
	local bs = DecodeSymbolsViewSettings.decode_symbol_spacing
	local sa = minigame and minigame._stage_amount or MinigameSettings.decode_symbols_stage_amount
	local ips = MinigameSettings.decode_symbols_items_per_stage
	local th = bw[2] * sa + bs * (sa - 1)
	local scale = th > PREVIEW_DECODE_MAX_GRID_HEIGHT and PREVIEW_DECODE_MAX_GRID_HEIGHT / th or 1
	local ws = { bw[1] * scale, bw[2] * scale }
	local sp = bs * scale

	_cached_layout = {
		stage_amount      = sa,
		widget_size       = ws,
		spacing           = sp,
		starting_offset_x = -(ws[1] * ips + sp * (ips - 1)) * 0.5,
		starting_offset_y = -(ws[2] * sa + sp * (sa - 1)) * 0.5,
	}
	_cached_layout_mg = minigame
	return _cached_layout
end

local HIGHLIGHT = { 100, 255, 255, 165 }

local function _ensure_highlight_widgets(view, count, widget_size)
	if count <= 0 then
		view._nb_dh = nil; view._nb_dh_size = nil
		return nil
	end

	local w = view._nb_dh
	local prev_sz = view._nb_dh_size

	if w and #w == count and prev_sz
		and prev_sz[1] == widget_size[1] and prev_sz[2] == widget_size[2]
	then
		return w
	end

	_deps()
	w = {}
	for i = 1, count do
		local def = UIWidget.create_definition({{
			pass_type = "texture", style_id = "highlight",
			value     = "content/ui/materials/backgrounds/scanner/scanner_decode_symbol_highlight",
			style     = { hdr = true, color = HIGHLIGHT },
		}}, "center_pivot", nil, widget_size)
		w[i] = UIWidget.init("nb_dh_" .. i, def)
	end
	view._nb_dh = w
	view._nb_dh_size = { widget_size[1], widget_size[2] }
	return w
end

mod:hook_require("scripts/ui/views/scanner_display_view/minigame_decode_symbols_view", function(View)
	mod:hook_safe(View, "draw_widgets", function(self, dt, t, input_service, ui_renderer)
		if not S("enable_decode_highlight") then
			return
		end
			_deps()
			local ext = self._minigame_extension
			if not ext then
				return
			end

			local mg = ext:minigame(MinigameSettings.types.decode_symbols)
			if not mg then
				return
			end

			local targets = mg._decode_targets
		if not targets or #targets == 0 then
			return
		end

		local stage = mg:current_stage()
		if not stage then
			return
		end
		local limit = math.min(#targets, stage + 3)
			local count = limit - stage
			if count <= 0 then
				self._nb_dh = nil
                self._nb_dh_size = nil
				return
			end

		local layout = _decode_layout(mg)
		local ws = layout.widget_size

		local w = _ensure_highlight_widgets(self, count, ws)
		if not w then return end

		for i = stage + 1, limit do
			local wi = w[i - stage]
			wi.offset[1] = layout.starting_offset_x + (ws[1] + layout.spacing) * (targets[i] - 1)
			wi.offset[2] = layout.starting_offset_y + (ws[2] + layout.spacing) * (i - 1)
			wi.offset[3] = 5
			wi.style.highlight.color = HIGHLIGHT
			UIWidget.draw(wi, ui_renderer)
		end
	end)
end)

local PRESS_DURATION = 0.08
local RELEASE_DURATION = 0.12
local PRESS_LEAD = 0.095
local PRESS_GRACE = 0.060
local SUBMIT_TIMEOUT = 1.2
local SYNC_STABILITY_DURATION = 0.12
local SYNC_TARGET_EDGE_MARGIN = 0.03
local MIN_STAGE_READY_DELAY = PRESS_DURATION + RELEASE_DURATION
local STAGE_ACK_ALPHA = 0.3
local PRIMARY_HOLD_ACTIONS = {
	action_one_hold = true,
	interact_hold = true,
	interact_primary_hold = true,
	jump_held = true,
}

mod._ds_submitted_stage = nil
mod._ds_submitted_until = 0
mod._ds_press_until = 0
mod._ds_release_until = 0
mod._ds_submit_time = nil
mod._ds_stage_ack_cost = MIN_STAGE_READY_DELAY
mod._ds_stage_ack_samples = 0
mod._ds_last_stage_ack = nil
local decode_active = false
local active_decode_key = nil
local decode_completed = false
local decode_previous_start_time = nil
local decode_waiting_for_sync = false
local decode_sync_candidate_key = nil
local decode_sync_candidate_start_time = nil
local decode_sync_candidate_target = nil
local decode_sync_candidate_since = nil
local decode_synced_key = nil
local decode_synced_start_time = nil
local decode_synced_target = nil
local decode_sync_ready_at = nil
local looks_like_decode_symbols

function mod._ds_network_rtt()
	local connection = Managers.connection
	local network = rawget(_G, "Network")
	if not connection or not connection.host or not network or not network.ping then
		return nil
	end

	local host_ok, host = pcall(connection.host, connection)
	if not host_ok or not host then
		return nil
	end

	local ping_ok, rtt = pcall(network.ping, host)

	return ping_ok and type(rtt) == "number" and rtt >= 0 and rtt or nil
end

function mod._ds_stage_ready_delay(server)
	if server then
		return MIN_STAGE_READY_DELAY
	end

	return math.max(MIN_STAGE_READY_DELAY, mod._ds_stage_ack_cost or 0, mod._ds_network_rtt() or 0)
end

local function observe_stage_ack(now)
	local submitted_at = mod._ds_submit_time
	local observed = submitted_at and now - submitted_at
	if not observed or observed <= 0 or observed >= SUBMIT_TIMEOUT then
		return
	end

	local current = mod._ds_stage_ack_cost or MIN_STAGE_READY_DELAY
	mod._ds_last_stage_ack = observed
	mod._ds_stage_ack_cost = observed > current
		and observed
		or current + (observed - current) * STAGE_ACK_ALPHA
	mod._ds_stage_ack_samples = (mod._ds_stage_ack_samples or 0) + 1
end

local function clear_sync_tracking()
	decode_sync_candidate_key = nil
	decode_sync_candidate_start_time = nil
	decode_sync_candidate_target = nil
	decode_sync_candidate_since = nil
	decode_synced_key = nil
	decode_synced_start_time = nil
	decode_synced_target = nil
	decode_sync_ready_at = nil
end

local function reset_snapshot()
	local ds = mod._ds
	ds.timer = 0
	ds.active = false
	ds.completed = false
	ds.server = false
	ds.stage = nil
	ds.start_time = nil
	ds.target = nil
	ds.items_per_stage = nil
	ds.sweep_duration = nil
	ds.key = nil
end

local function sample_decode_symbols(minigame)
	local ds = mod._ds
	if not ds then return end
	local key = minigame and tostring(minigame) or nil

	if key and ds.key and ds.key ~= key then
		mod._ds_submitted_stage = nil
		mod._ds_submitted_until = 0
		mod._ds_press_until = 0
		mod._ds_release_until = 0
		mod._ds_submit_time = nil
	end

	if not looks_like_decode_symbols(minigame) then
		reset_snapshot()
		return
	end

	local stage = minigame.current_stage and minigame:current_stage() or minigame._current_stage
	local targets = minigame._decode_targets
	ds.timer = 0.075
	ds.active = true
	ds.completed = minigame.is_completed and minigame:is_completed() == true or false
	ds.server = minigame._is_server == true
	ds.stage = stage
	ds.start_time = minigame.start_time and minigame:start_time() or minigame._decode_start_time
	ds.target = targets and stage and targets[stage] or nil
	ds.items_per_stage = minigame._decode_symbols_items_per_stage
	ds.sweep_duration = minigame._decode_symbols_sweep_duration
	ds.key = key

	if decode_active and not ds.server and not decode_waiting_for_sync and stage == 1
		and decode_synced_key ~= nil
		and (key ~= decode_synced_key or ds.start_time ~= decode_synced_start_time or ds.target ~= decode_synced_target)
	then
		decode_waiting_for_sync = true
		clear_sync_tracking()
		mod._ds_submitted_stage = nil
		mod._ds_submitted_until = 0
		mod._ds_press_until = 0
		mod._ds_release_until = 0
		mod._ds_submit_time = nil
	end

end

local function is_active_decode_symbols(minigame)
	return decode_active and minigame ~= nil and active_decode_key == tostring(minigame)
end

local function ds_reset(reason)
	local keep_waiting_for_sync = reason == "stop" and decode_waiting_for_sync

	if mod._ds and mod._ds.start_time then
		decode_previous_start_time = mod._ds.start_time
	end

	decode_active = false
	active_decode_key = nil
	decode_completed = reason == "complete"
	decode_waiting_for_sync = keep_waiting_for_sync
	clear_sync_tracking()
	reset_snapshot()
	mod._ds_submitted_stage = nil
	mod._ds_submitted_until = 0
	mod._ds_press_until = 0
	mod._ds_release_until = 0
	mod._ds_submit_time = nil
end

local function game_time()
	return mod._time("gameplay")
end

local function scanner_view_active()
	local ui = Managers.ui
	return ui and ui:view_active("scanner_display_view")
end

local function next_center_delta(sweep_duration, now, start_time, target, margin)
	if not sweep_duration or sweep_duration <= 0 then return nil end

	local period = sweep_duration * 2
	local center = (target - 1) * margin
	local mirror = period - center
	local phase = (now - start_time) % period
	local delta_a = center - phase
	local delta_b = mirror - phase

	if delta_a < -PRESS_GRACE then delta_a = delta_a + period end
	if delta_b < -PRESS_GRACE then delta_b = delta_b + period end

	return math.abs(delta_a) < math.abs(delta_b) and delta_a or delta_b
end

local function decode_sync_ready(now, minigame)
	if not decode_waiting_for_sync then
		return true
	end

	local ds = mod._ds
	local stage = ds and ds.stage
	local start_time = ds and ds.start_time
	local target = ds and ds.target
	local start_time_changed = decode_previous_start_time == nil or start_time ~= decode_previous_start_time

    if stage ~= 1 or not start_time_changed then
		decode_sync_candidate_key = nil
		decode_sync_candidate_start_time = nil
		decode_sync_candidate_target = nil
		decode_sync_candidate_since = nil
        return false
    end

    if minigame and mod._ds_reroll_predicted_sync_ready
        and mod._ds_reroll_predicted_sync_ready(minigame, decode_previous_start_time)
    then
        decode_waiting_for_sync = false
        decode_synced_key = ds.key
        decode_synced_start_time = start_time
        decode_synced_target = target
        decode_sync_ready_at = now
        return true
    end

	if decode_sync_candidate_key ~= ds.key
		or decode_sync_candidate_start_time ~= start_time
		or decode_sync_candidate_target ~= target
	then
		decode_sync_candidate_key = ds.key
		decode_sync_candidate_start_time = start_time
		decode_sync_candidate_target = target
		decode_sync_candidate_since = now
		return false
	end

	local stable_for = now - decode_sync_candidate_since
	if stable_for < SYNC_STABILITY_DURATION then
		return false
	end

	decode_waiting_for_sync = false
	decode_synced_key = ds.key
	decode_synced_start_time = start_time
	decode_synced_target = target
	decode_sync_ready_at = now

	return true
end

local function should_press_decode(now)
	local ds = mod._ds
	if not ds or ds.timer <= 0 or not ds.active then
		return false
	end
	if ds.completed then
		return false
	end

	local stage = ds.stage
	local start_time = ds.start_time
	local target = ds.target
	local items_per_stage = ds.items_per_stage
	local sweep_duration = ds.sweep_duration

	if not stage or not start_time or not target
		or not items_per_stage or items_per_stage <= 1
		or not sweep_duration or sweep_duration <= 0 then
		return false
	end

	local was_waiting_for_sync = decode_waiting_for_sync
	if not decode_sync_ready(now) then return false end
	local sync_ready_now = was_waiting_for_sync
		or decode_sync_ready_at ~= nil and now - decode_sync_ready_at <= SYNC_STABILITY_DURATION

	if mod._ds_reroll_blocks_solver and mod._ds_reroll_blocks_solver() then
		return false
	end

	if mod._ds_submitted_stage ~= stage then
		if mod._ds_submitted_stage ~= nil then
			observe_stage_ack(now)
		end
		mod._ds_submitted_stage = nil
		mod._ds_submitted_until = 0
		mod._ds_submit_time = nil
	elseif now < mod._ds_submitted_until then
		return false
	end

	local margin = sweep_duration / (items_per_stage - 1)
	local delta = next_center_delta(sweep_duration, now, start_time, target, margin)
	local target_half_width = margin * 0.5
	local edge_margin = delta and target_half_width - math.abs(delta) or nil
	local in_trigger_window = delta and delta <= PRESS_LEAD and delta >= -PRESS_GRACE
	local in_safe_startup_target = sync_ready_now and edge_margin and edge_margin >= SYNC_TARGET_EDGE_MARGIN

	if not in_trigger_window and not in_safe_startup_target then
		return false
	end
	return true
end

local function submit_decode(now)
	local stage = mod._ds and mod._ds.stage
	mod._ds_submitted_stage = stage
	mod._ds_submitted_until = now + SUBMIT_TIMEOUT
	mod._ds_press_until = now + PRESS_DURATION
	mod._ds_release_until = mod._ds_press_until + RELEASE_DURATION
	mod._ds_submit_time = now
end

looks_like_decode_symbols = function(minigame)
	return minigame
		and minigame._decode_symbols_sweep_duration ~= nil
		and minigame._decode_symbols_items_per_stage ~= nil
		and minigame._decode_targets ~= nil
end

function mod._ds_input(action, result, source)
	if not S("enable_decode_auto") then return result end
	local ds = mod._ds
	if not ds or ds.timer <= 0 or not ds.active then return result end
	if not PRIMARY_HOLD_ACTIONS[action] then return result end

	local now = game_time()
	if not now then return result end

	if mod._ds_press_until > now then
		return true
	end
	if mod._ds_release_until > now then
		return false
	end
	if result then return result end
	if source ~= "input_service" then return result end
	if not should_press_decode(now) then return result end

	submit_decode(now)
	return true
end

mod:hook_safe("MinigameDecodeSymbols", "start", function(self, player)
	if not mod._is_local_minigame_player(player) then
		if mod._ds_reroll_abort then
			mod._ds_reroll_abort(self)
		end
		if decode_active and is_active_decode_symbols(self) then
			ds_reset("ownership_transferred")
		end
		return
	end

	if S("enable_decode_auto") then
		if mod._ds and mod._ds.start_time then
			decode_previous_start_time = mod._ds.start_time
		end
		reset_snapshot()
		clear_sync_tracking()
		mod._ds_submitted_stage = nil
		mod._ds_submitted_until = 0
		mod._ds_press_until = 0
		mod._ds_release_until = 0
		mod._ds_submit_time = nil
		decode_active = true
		active_decode_key = tostring(self)
		decode_completed = false
		decode_waiting_for_sync = self._is_server ~= true
	end

	if mod._ds_reroll_start then
		mod._ds_reroll_start(self)
	end
end)
mod:hook_safe("MinigameDecodeSymbols", "stop", function(self, stop_arg)
	if mod._ds_reroll_stop then
		mod._ds_reroll_stop(self, stop_arg)
	end
    if S("enable_decode_auto") and is_active_decode_symbols(self) then
        ds_reset(not decode_completed and "stop" or nil)
    end
end)

mod:hook_safe("MinigameDecodeSymbols", "complete", function(self)
	if mod._ds_reroll_complete then
		mod._ds_reroll_complete(self)
	end
    if S("enable_decode_auto") and is_active_decode_symbols(self) then
        ds_reset("complete")
    end
end)

local function on_update(dt)
	local ds = mod._ds
	if ds and ds.timer > 0 then ds.timer = math.max(ds.timer - dt, 0) end
	if mod._ds_submitted_until <= 0 then return end

	local now = game_time()

	if now and mod._ds_submitted_until > 0 and now >= mod._ds_submitted_until then
		mod._ds_submitted_stage = nil
		mod._ds_submitted_until = 0
		mod._ds_submit_time = nil
	end
end
local function on_round_end()
	ds_reset(decode_active and "round_end" or nil)
	mod._ds_stage_ack_cost = MIN_STAGE_READY_DELAY
	mod._ds_stage_ack_samples = 0
	mod._ds_last_stage_ack = nil
end
local function on_setting(id) if id == "enable_decode_auto" then ds_reset(decode_active and "setting_changed" or nil) end end

mod._reg("update", on_update)
mod._reg("round_end", on_round_end)
mod._reg("setting_changed", on_setting)

local function hook_decode_state_input(PlayerCharacterStateMinigame)
	if mod._ds_state_input_hooked then
		return
	end

	mod._ds_state_input_hooked = true

	mod:hook(PlayerCharacterStateMinigame, "_update_input", function(func, self, t, fixed_frame, input_extension)
		if mod._exp_rearm_from_state then
			mod._exp_rearm_from_state(self, t)
		end
		if mod._drill_rearm_from_state then
			mod._drill_rearm_from_state(self, t)
		end
		if mod._bal_rearm_from_state then
			mod._bal_rearm_from_state(self, t)
		end
		if mod._freq_rearm_from_state then
			mod._freq_rearm_from_state(self, t)
		end

		if not S("enable_decode_auto") then
			return func(self, t, fixed_frame, input_extension)
		end

		local minigame = self and self._minigame
		local player = self and self._player

		if not mod._is_local_minigame_player(player) then
			return func(self, t, fixed_frame, input_extension)
		end

		if not scanner_view_active() then
			return func(self, t, fixed_frame, input_extension)
		end

		if not looks_like_decode_symbols(minigame) then
			return func(self, t, fixed_frame, input_extension)
		end

		if active_decode_key ~= tostring(minigame) then
			if not decode_active then
				active_decode_key = tostring(minigame)
			else
				return func(self, t, fixed_frame, input_extension)
			end
		end

		decode_active = true
		decode_completed = false
		sample_decode_symbols(minigame)
		local reroll_blocks = false
		if mod._ds_reroll_active and mod._ds_reroll_active() then
            local sync_ready = decode_sync_ready(t, minigame)
			mod._ds_reroll_evaluate(minigame, t, sync_ready)
		end
		reroll_blocks = mod._ds_reroll_blocks_solver and mod._ds_reroll_blocks_solver() or false

		local action_one_hold = input_extension:get("action_one_hold")
		local interact_hold = input_extension:get("interact_hold")
		local jump_held = input_extension:get("jump_held")

		if action_one_hold ~= self._previous_action_one_hold then
			self._previous_action_one_hold = action_one_hold
			self._previous_input = action_one_hold
		elseif interact_hold ~= self._previous_interact_hold then
			self._previous_interact_hold = interact_hold
			self._previous_input = interact_hold
		elseif jump_held ~= self._previous_jump_held then
			self._previous_jump_held = jump_held
			self._previous_input = jump_held
		end

		local primary_input = self._previous_input or false
		local action_two_pressed = input_extension:get("action_two_pressed")
		local cancel = action_two_pressed
		local block_weapon_actions = false

		if not self:_is_wielding_minigame_device() then
			return true
		end

		if reroll_blocks then
			primary_input = false
		elseif mod._ds_press_until > t then
			primary_input = true
		elseif mod._ds_release_until > t then
			primary_input = false
		elseif minigame._is_server and should_press_decode(t) then
			submit_decode(t)
			primary_input = true
		end

		if minigame:uses_action() and minigame:action(primary_input, t) then
			local animation_extension = self._animation_extension

			if animation_extension then
				animation_extension:anim_event_1p("button_press")

				if minigame:is_completed() then
					animation_extension:anim_event_1p("scan_end")
				end
			end
		end

		if minigame:uses_joystick() then
			local move_input = input_extension:get("move") or Vector3.zero()

			minigame:on_axis_set(t, move_input.x or 0, move_input.y or 0)
		end

		cancel = minigame:escape_action(action_two_pressed)
		block_weapon_actions = minigame:blocks_weapon_actions()

		if not cancel and not block_weapon_actions then
			local weapon_extension = self._weapon_extension

			if weapon_extension then
				weapon_extension:update_weapon_actions(fixed_frame)
			end
		end

		return cancel
	end)
end

hook_decode_state_input("PlayerCharacterStateMinigame")

mod:hook_require("scripts/extension_systems/character_state_machine/character_states/player_character_state_minigame", function(PlayerCharacterStateMinigame)
	hook_decode_state_input(PlayerCharacterStateMinigame)
end)

return true
