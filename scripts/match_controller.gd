class_name MatchController
extends Node3D
## Central match and round-state controller.
## Orchestrates the 5-second preparation phase, simultaneous line-of-sight attack resolution,
## staged arena shrinking (100% -> 72% -> 45% -> 22%), spectator mode, and winner/draw states.

enum MatchPhase {
	MAIN_MENU,
	PREPARATION,
	RESOLUTION_FREEZE,
	MATCH_OVER
}

signal round_started(round_number: int)
signal simultaneous_resolution_completed(eliminated_players: Array[CharacterController])
signal match_ended(is_draw: bool, winner: CharacterController)
signal return_to_lobby_requested()

const CHARACTER_CONFIGS: Array[Dictionary] = [
	{
		"id": 0,
		"name": "YOU",
		"human": true,
		"primary": Color(0.0, 0.86, 1.0),
		"accent": Color(0.55, 0.98, 1.0)
	},
	{
		"id": 1,
		"name": "VEX",
		"human": false,
		"primary": Color(1.0, 0.20, 0.34),
		"accent": Color(1.0, 0.58, 0.66)
	},
	{
		"id": 2,
		"name": "NOVA",
		"human": false,
		"primary": Color(0.10, 0.92, 0.46),
		"accent": Color(0.58, 1.0, 0.76)
	},
	{
		"id": 3,
		"name": "SOL",
		"human": false,
		"primary": Color(1.0, 0.80, 0.12),
		"accent": Color(1.0, 0.94, 0.55)
	},
	{
		"id": 4,
		"name": "NYX",
		"human": false,
		"primary": Color(0.82, 0.22, 1.0),
		"accent": Color(0.94, 0.62, 1.0)
	}
]

@export var preparation_duration: float = 5.0
@export var resolution_freeze_duration: float = 0.85
@export var max_attack_range: float = 14.0
@export var shrink_stage_interval: float = 11.0
@export var shrink_warning_duration: float = 4.0
@export var start_on_main_menu: bool = true
@export_file("*.tscn") var lobby_scene_path: String = ""

var arena: ArenaGenerator
var camera_rig: CameraRig
var hud: HUDController
var audio_manager: AudioManager
var multiplayer_client: MultiplayerClient
var dedicated_server: DedicatedServer
var ad_manager: AdMobManager

var characters: Array[CharacterController] = []
var ai_controllers: Array[AIController] = []
var human_character: CharacterController = null

var is_online_match: bool = false
var _online_active_slots: Array[bool] = [true, true, true, true, true]
var _ai_root: Node

var current_phase: MatchPhase = MatchPhase.PREPARATION
var current_round: int = 1
var phase_timer: float = 5.0

var shrink_timer: float = 11.0
var _spectated_index: int = 0
var _is_spectating: bool = false
var _is_resolving_simultaneous_batch: bool = false
var _last_tick_second: int = -1


func _ready() -> void:
	if _check_and_run_dedicated_server_cli():
		return
	_setup_environment_and_lighting()
	_setup_subsystems()
	_apply_client_cli_overrides()
	if start_on_main_menu:
		enter_main_menu()
	else:
		start_new_match()


func _apply_client_cli_overrides() -> void:
	if not multiplayer_client:
		return
	var all_args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for arg in all_args:
		if arg.begins_with("--server-url="):
			var url := arg.trim_prefix("--server-url=").strip_edges()
			multiplayer_client.server_url = url
			multiplayer_client.server_host = url
		elif arg.begins_with("--host="):
			multiplayer_client.server_host = arg.trim_prefix("--host=").strip_edges()
		elif arg.begins_with("--port="):
			multiplayer_client.server_port = int(arg.trim_prefix("--port="))
		elif arg.begins_with("--name="):
			multiplayer_client.player_name = NetProtocol.sanitize_player_name(arg.trim_prefix("--name="), multiplayer_client.player_name)
		elif arg.begins_with("--token="):
			multiplayer_client.account_token = arg.trim_prefix("--token=").strip_edges()
	if hud and hud.main_menu and hud.main_menu.online_modal:
		var modal := hud.main_menu.online_modal
		if modal.host_input:
			modal.host_input.text = multiplayer_client.server_host
		if modal.port_input:
			modal.port_input.text = str(multiplayer_client.server_port)
		if modal.name_input:
			modal.name_input.text = multiplayer_client.player_name


func _check_and_run_dedicated_server_cli() -> bool:
	var all_args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var run_as_server := false
	var port := NetProtocol.DEFAULT_PORT
	var bind_ip := "0.0.0.0"

	# Check environment variable PORT (standard on Render and container platforms)
	var env_port := OS.get_environment("PORT").strip_edges()
	if not env_port.is_empty() and env_port.is_valid_int():
		port = int(env_port)

	for arg in all_args:
		if arg == "--server" or arg == "--dedicated-server":
			run_as_server = true
		elif arg.begins_with("--port="):
			port = int(arg.trim_prefix("--port="))
		elif arg.begins_with("--bind="):
			bind_ip = arg.trim_prefix("--bind=")

	if not run_as_server:
		return false

	dedicated_server = DedicatedServer.new()
	dedicated_server.name = "DedicatedServer"
	add_child(dedicated_server)
	dedicated_server.start_server(port, bind_ip)
	set_process(false)
	return true


func enter_main_menu() -> void:
	is_online_match = false
	_online_active_slots = [true, true, true, true, true]
	current_phase = MatchPhase.MAIN_MENU
	_is_spectating = false
	_spectated_index = 0
	_last_tick_second = -1
	_set_local_ai_enabled(true)
	human_character = characters[0] if not characters.is_empty() else null

	if audio_manager:
		audio_manager.set_music_ducked(false)
		audio_manager.start_background_music()

	arena.generate_arena()
	var spawn_points := arena.get_spawn_positions()
	var obs_aabbs := arena.get_active_obstacle_aabbs()

	for i in range(characters.size()):
		var c := characters[i]
		var cfg := CHARACTER_CONFIGS[i % CHARACTER_CONFIGS.size()]
		c.is_network_controlled = false
		c.is_local_online_player = false
		c.visible = true
		c.configure_character(cfg["id"], cfg["name"], cfg["human"], cfg["primary"], cfg["accent"], max_attack_range)
		var sp := spawn_points[i % spawn_points.size()]
		var inward_dir := Vector3(-sp.x, 0.0, -sp.z).normalized()
		c.max_attack_range = max_attack_range
		c.set_obstacle_aabbs(obs_aabbs)
		if c == human_character:
			# Place featured hero on open arena floor facing the lobby camera
			c.spawn_at(Vector3(0.0, 0.0, 6.1), Vector3(0.0, 0.0, 1.0))
			c.set_controls_frozen(true)
			c.set_stealth_hidden(false)
			if c.visuals:
				c.visuals.is_lobby_showcase = true
				c.visuals.rotation.y = 0.0
				c.visuals.set_invincible_visual(false, 0.0)
			if c.aim_line:
				c.aim_line.visible = false
			if c._name_label:
				c._name_label.visible = false
		else:
			c.spawn_at(sp, inward_dir)
			c.set_controls_frozen(true)
			c.set_stealth_hidden(true)

	if camera_rig and human_character:
		camera_rig.set_lobby_mode(true, human_character, true)

	if hud:
		hud.setup_player_badges(characters)
		hud.show_main_menu_lobby()


func start_new_match() -> void:
	is_online_match = false
	_online_active_slots = [true, true, true, true, true]
	_set_local_ai_enabled(true)
	human_character = characters[0] if not characters.is_empty() else null

	current_round = 1
	current_phase = MatchPhase.PREPARATION
	phase_timer = preparation_duration
	shrink_timer = shrink_stage_interval
	_is_spectating = false
	_spectated_index = 0
	_last_tick_second = -1

	if audio_manager:
		audio_manager.set_music_ducked(false)
		audio_manager.start_background_music()

	arena.generate_arena()
	var spawn_points := arena.get_spawn_positions()
	var obs_aabbs := arena.get_active_obstacle_aabbs()

	for i in range(characters.size()):
		var c := characters[i]
		var cfg := CHARACTER_CONFIGS[i % CHARACTER_CONFIGS.size()]
		c.is_network_controlled = false
		c.is_local_online_player = false
		c.visible = true
		c.configure_character(cfg["id"], cfg["name"], cfg["human"], cfg["primary"], cfg["accent"], max_attack_range)
		if c.visuals:
			c.visuals.is_lobby_showcase = false
		var sp := spawn_points[i % spawn_points.size()]
		var inward_dir := Vector3(-sp.x, 0.0, -sp.z).normalized()
		c.max_attack_range = max_attack_range
		c.set_obstacle_aabbs(obs_aabbs)
		c.spawn_at(sp, inward_dir)

	_update_stealth_visibility()

	if camera_rig and human_character:
		camera_rig.set_lobby_mode(false, human_character, true)
		camera_rig.set_follow_target(human_character, false, true)

	if hud:
		hud.show_in_game_hud()
		hud.setup_player_badges(characters)
		hud.update_player_badges(characters, get_living_players().size())
		hud.show_toast("ROUND 1 — 5s STEALTH PREP (OPPONENTS HIDDEN)", 2.2)

	if human_character and hud and hud.mobile_controls:
		hud.mobile_controls.set_controls_active(true)
		hud.mobile_controls.reset_inputs()
		hud.mobile_controls.set_initial_aim(human_character.aim_direction)

	round_started.emit(current_round)


func _process(delta: float) -> void:
	if current_phase == MatchPhase.MAIN_MENU or current_phase == MatchPhase.MATCH_OVER:
		return

	# Keep obstacle AABB cache updated on characters
	var obs_aabbs := arena.get_active_obstacle_aabbs()
	for c in characters:
		c.set_obstacle_aabbs(obs_aabbs)

	if _is_spectating:
		var followed := camera_rig.target_node as CharacterController if camera_rig else null
		if followed == null or not is_instance_valid(followed) or not followed.is_alive():
			_refresh_spectator_target()

	if is_online_match:
		_update_online_client_timers(delta)
		_update_hud_display()
		return

	_update_arena_shrinking(delta)
	_update_round_cycle(delta)
	_update_hud_display()


func _update_round_cycle(delta: float) -> void:
	phase_timer -= delta

	if current_phase == MatchPhase.PREPARATION:
		var urgency := clampf(1.0 - (phase_timer / preparation_duration), 0.0, 1.0)
		for c in characters:
			if c.is_alive():
				c.set_preparation_status(true, urgency)

		# Countdown tick SFX in final 3 seconds before laser fires
		var sec_ceil := int(ceil(maxf(0.0, phase_timer)))
		if sec_ceil >= 1 and sec_ceil <= 3 and sec_ceil != _last_tick_second:
			_last_tick_second = sec_ceil
			if audio_manager:
				audio_manager.play_countdown_tick(sec_ceil == 1)

		if phase_timer <= 0.0:
			_trigger_simultaneous_resolution()

	elif current_phase == MatchPhase.RESOLUTION_FREEZE:
		if phase_timer <= 0.0:
			_begin_next_preparation_round()


func _trigger_simultaneous_resolution() -> void:
	current_phase = MatchPhase.RESOLUTION_FREEZE
	phase_timer = resolution_freeze_duration
	_last_tick_second = -1

	if audio_manager:
		audio_manager.play_laser_shoot()

	var living := get_living_players()
	var obs_aabbs := arena.get_active_obstacle_aabbs()

	# Reveal all players & their laser lines when the laser is shot!
	_update_stealth_visibility()

	# 1. Freeze movement & aiming and take a simultaneous snapshot of all living players
	var snapshots: Dictionary = {}
	for c in living:
		c.set_preparation_status(false, 1.0)
		c.set_controls_frozen(true)
		c.set_firing_burst(true)
		snapshots[c.player_id] = {
			"character": c,
			"position": c.global_position,
			"hit_radius": c.hit_radius,
			"segment": c.get_attack_segment_snapshot(obs_aabbs)
		}

	if camera_rig:
		camera_rig.trigger_screen_shake(0.26)

	# 2. Evaluate every living player's unobstructed line against all other living players simultaneously
	var eliminated_set: Dictionary = {} # player_id -> CharacterController
	for attacker_id in snapshots.keys():
		var attacker_data: Dictionary = snapshots[attacker_id]
		var seg: Dictionary = attacker_data["segment"]
		var seg_origin: Vector3 = seg["origin"]
		var seg_end: Vector3 = seg["end"]

		for target_id in snapshots.keys():
			if attacker_id == target_id:
				continue
			var target_data: Dictionary = snapshots[target_id]
			var target_pos: Vector3 = target_data["position"]
			var target_radius: float = target_data["hit_radius"]

			if AimLine.does_segment_hit_target(seg_origin, seg_end, target_pos, target_radius):
				eliminated_set[target_id] = target_data["character"]

	# 3. Apply simultaneous eliminations as an atomic batch before checking winner/draw
	_is_resolving_simultaneous_batch = true
	var newly_eliminated: Array[CharacterController] = []
	for target_id in eliminated_set.keys():
		var victim: CharacterController = eliminated_set[target_id]
		victim.eliminate("LASER")
		newly_eliminated.append(victim)
	_is_resolving_simultaneous_batch = false

	if not newly_eliminated.is_empty():
		if audio_manager:
			audio_manager.play_elimination_sfx()
		var names := PackedStringArray()
		for v in newly_eliminated:
			names.append(v.display_name)
		if hud:
			hud.show_toast("%s ELIMINATED!" % ", ".join(names), 2.3)
	else:
		if hud:
			hud.show_toast("ALL SHOTS MISSED OR BLOCKED!", 1.4)

	simultaneous_resolution_completed.emit(newly_eliminated)
	_check_post_elimination_states()


func _begin_next_preparation_round() -> void:
	if current_phase == MatchPhase.MATCH_OVER:
		return

	current_round += 1
	current_phase = MatchPhase.PREPARATION
	phase_timer = preparation_duration
	_last_tick_second = -1

	for c in characters:
		if c.is_alive():
			c.set_controls_frozen(false)
			c.set_firing_burst(false)
			c.set_preparation_status(true, 0.0)

	# Hide opponents and their aiming lines from each other during the 5s preparation phase
	_update_stealth_visibility()

	if human_character and human_character.is_alive() and hud and hud.mobile_controls:
		c_reapply_current_input()

	round_started.emit(current_round)


func _update_stealth_visibility() -> void:
	# Reveal everyone when the laser fires, when the match is over, OR once the human player is spectating
	var human_alive := human_character != null and human_character.is_alive()
	if current_phase != MatchPhase.PREPARATION or _is_spectating or not human_alive:
		for c in characters:
			c.set_stealth_hidden(false)
		return

	# While the human player is ALIVE during the 5s preparation phase, hide opponents and their lines
	for c in characters:
		if c.is_alive():
			c.set_stealth_hidden(c != human_character)


func c_reapply_current_input() -> void:
	if human_character and human_character.is_alive() and hud and hud.mobile_controls:
		human_character.set_move_vector(hud.mobile_controls.current_move_vector)
		human_character.set_aim_vector(hud.mobile_controls.current_aim_vector)


func _update_arena_shrinking(delta: float) -> void:
	if current_phase == MatchPhase.MATCH_OVER:
		return
	if arena.current_stage >= 4:
		return

	shrink_timer -= delta
	var next_stage := arena.current_stage + 1

	if not arena.is_warning_active and shrink_timer <= shrink_warning_duration:
		arena.start_shrink_warning(next_stage, shrink_warning_duration)
		var pct := int(round(arena.get_stage_width_ratio(next_stage) * 100.0))
		if hud:
			hud.show_toast("WARNING! PLATFORM SHRINKING TO %d%%!" % pct, 2.5)

	if shrink_timer <= 0.0:
		arena.execute_shrink_to_stage(next_stage)
		if camera_rig:
			camera_rig.trigger_screen_shake(0.32)
		shrink_timer = shrink_stage_interval


func get_living_players() -> Array[CharacterController]:
	var alive: Array[CharacterController] = []
	for i in range(characters.size()):
		if is_online_match and i < _online_active_slots.size() and not _online_active_slots[i]:
			continue
		if characters[i].is_alive():
			alive.append(characters[i])
	return alive


func _set_local_ai_enabled(enabled: bool) -> void:
	for ai in ai_controllers:
		if is_instance_valid(ai):
			ai.set_physics_process(enabled)


func _update_online_client_timers(delta: float) -> void:
	phase_timer = maxf(0.0, phase_timer - delta)
	if arena.current_stage < 4 and current_phase != MatchPhase.MATCH_OVER:
		shrink_timer = maxf(0.0, shrink_timer - delta)

	if current_phase == MatchPhase.PREPARATION:
		var urgency := clampf(1.0 - (phase_timer / maxf(0.01, preparation_duration)), 0.0, 1.0)
		for i in range(characters.size()):
			if i < _online_active_slots.size() and not _online_active_slots[i]:
				continue
			if characters[i].is_alive():
				characters[i].set_preparation_status(true, urgency)

		var sec_ceil := int(ceil(maxf(0.0, phase_timer)))
		if sec_ceil >= 1 and sec_ceil <= 3 and sec_ceil != _last_tick_second:
			_last_tick_second = sec_ceil
			if audio_manager:
				audio_manager.play_countdown_tick(sec_ceil == 1)


func _on_online_match_started(start_msg: Dictionary) -> void:
	is_online_match = true
	_set_local_ai_enabled(false)

	current_round = int(start_msg.get("round", 1))
	preparation_duration = float(start_msg.get("preparation_duration", preparation_duration))
	resolution_freeze_duration = float(start_msg.get("resolution_freeze_duration", resolution_freeze_duration))
	shrink_stage_interval = float(start_msg.get("shrink_stage_interval", shrink_stage_interval))
	shrink_warning_duration = float(start_msg.get("shrink_warning_duration", shrink_warning_duration))

	current_phase = MatchPhase.PREPARATION
	phase_timer = preparation_duration
	shrink_timer = shrink_stage_interval
	_is_spectating = false
	_spectated_index = 0
	_last_tick_second = -1

	if audio_manager:
		audio_manager.set_music_ducked(false)
		audio_manager.start_background_music()

	arena.generate_arena()
	var spawn_points := arena.get_spawn_positions()
	var obs_aabbs := arena.get_active_obstacle_aabbs()

	var slots: Array = start_msg.get("slots", [])
	var local_peer := multiplayer_client.local_peer_id if multiplayer_client else 0
	human_character = null
	_online_active_slots.clear()

	for i in range(characters.size()):
		var c := characters[i]
		var pal := CHARACTER_CONFIGS[i % CHARACTER_CONFIGS.size()]
		var sp := spawn_points[i % spawn_points.size()]
		var inward_dir := Vector3(-sp.x, 0.0, -sp.z).normalized()

		if c.visuals:
			c.visuals.is_lobby_showcase = false

		var s_info: Dictionary = slots[i] if i < slots.size() else {"active": false}
		var active := bool(s_info.get("active", false))
		_online_active_slots.append(active)

		if active:
			var peer_id := int(s_info.get("peer_id", 0))
			var p_name := str(s_info.get("name", pal["name"]))
			var is_local := (peer_id > 0 and peer_id == local_peer)
			c.visible = true
			c.is_network_controlled = true
			c.is_local_online_player = is_local
			c.configure_character(i, p_name, is_local, pal["primary"], pal["accent"], max_attack_range)
			c.set_obstacle_aabbs(obs_aabbs)
			c.spawn_at(sp, inward_dir)
			if is_local:
				human_character = c
		else:
			c.is_network_controlled = true
			c.is_local_online_player = false
			c.spawn_at(Vector3(0.0, -50.0, 0.0), Vector3.BACK)
			c.set_controls_frozen(true)
			c.set_character_state(CharacterController.State.ELIMINATED)
			if c._collision_shape:
				c._collision_shape.disabled = true
			c.visible = false

	if human_character == null and not characters.is_empty():
		human_character = characters[0]

	if start_msg.has("initial_snapshot") and typeof(start_msg["initial_snapshot"]) == TYPE_DICTIONARY:
		_apply_online_snapshot_dict(start_msg["initial_snapshot"], true)

	_update_stealth_visibility()

	if camera_rig and human_character:
		camera_rig.set_lobby_mode(false, human_character, true)
		camera_rig.set_follow_target(human_character, false, true)

	if hud:
		hud.show_in_game_hud()
		hud.setup_player_badges(characters)
		hud.update_player_badges(characters, get_living_players().size())
		hud.show_toast("ONLINE MATCH STARTED — ROUND 1", 2.2)

	if human_character and hud and hud.mobile_controls:
		hud.mobile_controls.set_controls_active(true)
		hud.mobile_controls.reset_inputs()
		hud.mobile_controls.set_initial_aim(human_character.aim_direction)

	round_started.emit(current_round)


func _on_online_snapshot_received(snap_msg: Dictionary) -> void:
	if not is_online_match:
		return
	_apply_online_snapshot_dict(snap_msg, false)


func _apply_online_snapshot_dict(snap_msg: Dictionary, snap_positions: bool) -> void:
	current_round = int(snap_msg.get("round", current_round))
	phase_timer = float(snap_msg.get("phase_timer", phase_timer))
	shrink_timer = float(snap_msg.get("shrink_timer", shrink_timer))

	var players_arr: Array = snap_msg.get("players", [])
	for p_data in players_arr:
		if typeof(p_data) != TYPE_DICTIONARY:
			continue
		var slot_id := int(p_data.get("slot_id", -1))
		if slot_id < 0 or slot_id >= characters.size():
			continue
		if slot_id < _online_active_slots.size() and not _online_active_slots[slot_id]:
			continue

		var c := characters[slot_id]
		var net_pos: Vector3 = p_data.get("pos", c.global_position)
		var net_vel: Vector3 = p_data.get("vel", Vector3.ZERO)
		var net_aim: Vector3 = p_data.get("aim_dir", c.aim_direction)
		var net_state: int = int(p_data.get("state", int(c.current_state)))

		if net_state == int(CharacterController.State.ELIMINATED) and c.is_alive():
			c.eliminate("SERVER")
		elif c.is_alive():
			c.controls_frozen = bool(p_data.get("frozen", c.controls_frozen))
			c.apply_network_snapshot(net_pos, net_vel, net_aim, snap_positions)


func _on_online_round_started(round_msg: Dictionary) -> void:
	if not is_online_match or current_phase == MatchPhase.MATCH_OVER:
		return
	current_round = int(round_msg.get("round", current_round + 1))
	current_phase = MatchPhase.PREPARATION
	phase_timer = float(round_msg.get("preparation_duration", preparation_duration))
	_last_tick_second = -1

	if round_msg.has("snapshot") and typeof(round_msg["snapshot"]) == TYPE_DICTIONARY:
		_apply_online_snapshot_dict(round_msg["snapshot"], false)

	for i in range(characters.size()):
		if i < _online_active_slots.size() and not _online_active_slots[i]:
			continue
		var c := characters[i]
		if c.is_alive():
			c.set_controls_frozen(false)
			c.set_firing_burst(false)
			c.set_preparation_status(true, 0.0)

	_update_stealth_visibility()
	if human_character and human_character.is_alive() and hud and hud.mobile_controls:
		c_reapply_current_input()
	round_started.emit(current_round)


func _on_online_laser_resolution(res_msg: Dictionary) -> void:
	if not is_online_match:
		return
	current_phase = MatchPhase.RESOLUTION_FREEZE
	phase_timer = resolution_freeze_duration
	_last_tick_second = -1

	if audio_manager:
		audio_manager.play_laser_shoot()

	if res_msg.has("snapshot") and typeof(res_msg["snapshot"]) == TYPE_DICTIONARY:
		_apply_online_snapshot_dict(res_msg["snapshot"], true)

	_update_stealth_visibility()

	for c in get_living_players():
		c.set_preparation_status(false, 1.0)
		c.set_controls_frozen(true)
		c.set_firing_burst(true)

	if camera_rig:
		camera_rig.trigger_screen_shake(0.26)

	var elim_slots: Array = res_msg.get("eliminated_slots", [])
	_is_resolving_simultaneous_batch = true
	var newly_eliminated: Array[CharacterController] = []
	for s_id in elim_slots:
		var idx := int(s_id)
		if idx >= 0 and idx < characters.size():
			var victim := characters[idx]
			if victim.is_alive():
				victim.eliminate("LASER")
			newly_eliminated.append(victim)
	_is_resolving_simultaneous_batch = false

	if not newly_eliminated.is_empty():
		if audio_manager:
			audio_manager.play_elimination_sfx()
		var names := PackedStringArray()
		for v in newly_eliminated:
			names.append(v.display_name)
		if hud:
			hud.show_toast("%s ELIMINATED!" % ", ".join(names), 2.3)
	else:
		if hud:
			hud.show_toast("ALL SHOTS MISSED OR BLOCKED!", 1.4)

	simultaneous_resolution_completed.emit(newly_eliminated)
	_update_online_spectator_and_badges()


func _on_online_player_eliminated(elim_msg: Dictionary) -> void:
	if not is_online_match:
		return
	var slot_id := int(elim_msg.get("slot_id", -1))
	var reason := str(elim_msg.get("reason", "FALL"))
	if slot_id >= 0 and slot_id < characters.size():
		var c := characters[slot_id]
		if c.is_alive():
			c.eliminate(reason)
		if reason == "FALL":
			if audio_manager:
				audio_manager.play_platform_drop()
			if hud:
				hud.show_toast("%s FELL OFF THE ARENA!" % c.display_name, 2.2)
			if camera_rig:
				camera_rig.trigger_screen_shake(0.22)
	_update_online_spectator_and_badges()


func _on_online_arena_shrink_event(shrink_msg: Dictionary) -> void:
	if not is_online_match:
		return
	var ev := str(shrink_msg.get("event", ""))
	shrink_timer = float(shrink_msg.get("shrink_timer", shrink_timer))
	if ev == "warning_started":
		var target_stage := int(shrink_msg.get("target_stage", arena.current_stage + 1))
		var dur := float(shrink_msg.get("duration", shrink_warning_duration))
		arena.start_shrink_warning(target_stage, dur)
		var pct := int(round(arena.get_stage_width_ratio(target_stage) * 100.0))
		if hud:
			hud.show_toast("WARNING! PLATFORM SHRINKING TO %d%%!" % pct, 2.5)
	elif ev == "stage_shrunk":
		var new_stage := int(shrink_msg.get("new_stage", arena.current_stage + 1))
		arena.execute_shrink_to_stage(new_stage)
		if camera_rig:
			camera_rig.trigger_screen_shake(0.32)


func _on_online_player_disconnected(disc_msg: Dictionary) -> void:
	if not is_online_match:
		return
	var slot_id := int(disc_msg.get("slot_id", -1))
	var p_name := str(disc_msg.get("name", "PLAYER"))
	if slot_id >= 0 and slot_id < characters.size():
		var c := characters[slot_id]
		if c.is_alive():
			c.eliminate("DISCONNECTED")
	if hud:
		hud.show_toast("%s DISCONNECTED" % p_name, 2.0)
	_update_online_spectator_and_badges()


func _on_online_match_ended(end_msg: Dictionary) -> void:
	if not is_online_match:
		return
	if end_msg.has("snapshot") and typeof(end_msg["snapshot"]) == TYPE_DICTIONARY:
		_apply_online_snapshot_dict(end_msg["snapshot"], true)

	var is_draw := bool(end_msg.get("is_draw", false))
	var winner_slot := int(end_msg.get("winner_slot_id", -1))
	var winner_char: CharacterController = null
	if not is_draw and winner_slot >= 0 and winner_slot < characters.size():
		winner_char = characters[winner_slot]
	_finish_match(is_draw, winner_char)


func _on_online_disconnected(reason: String) -> void:
	if is_online_match and current_phase != MatchPhase.MATCH_OVER and current_phase != MatchPhase.MAIN_MENU:
		enter_main_menu()
		if hud:
			hud.show_toast("CONNECTION LOST: %s" % reason.to_upper(), 3.2)


func _update_online_spectator_and_badges() -> void:
	var living := get_living_players()
	if human_character and not human_character.is_alive() and living.size() > 0:
		if human_character.current_state != CharacterController.State.SPECTATING:
			human_character.enter_spectating_state()
		if not _is_spectating:
			_is_spectating = true
			_spectated_index = 0
		_refresh_spectator_target()
	if hud:
		hud.update_player_badges(characters, living.size())


func _on_character_eliminated(character: CharacterController, reason: String) -> void:
	if current_phase == MatchPhase.MATCH_OVER or is_online_match:
		return

	if reason == "FALL":
		if audio_manager:
			audio_manager.play_platform_drop()
		if hud:
			hud.show_toast("%s FELL OFF THE ARENA!" % character.display_name, 2.2)
		if camera_rig:
			camera_rig.trigger_screen_shake(0.22)

	if not _is_resolving_simultaneous_batch:
		_check_post_elimination_states()


func _check_post_elimination_states() -> void:
	if current_phase == MatchPhase.MATCH_OVER:
		return

	var living := get_living_players()

	# Check if match has ended (1 survivor = WINNER, 0 survivors = DRAW)
	if living.size() == 1:
		_finish_match(false, living[0])
		return
	elif living.size() == 0:
		_finish_match(true, null)
		return

	# If human player was eliminated and match continues, switch human to SPECTATING state
	if human_character and not human_character.is_alive():
		if human_character.current_state != CharacterController.State.SPECTATING:
			human_character.enter_spectating_state()
		if not _is_spectating:
			_is_spectating = true
			_spectated_index = 0
		_refresh_spectator_target()

	if hud:
		hud.update_player_badges(characters, living.size())


func _finish_match(is_draw: bool, winner: CharacterController) -> void:
	current_phase = MatchPhase.MATCH_OVER
	arena.stop_all_shrinking()
	_update_stealth_visibility()

	if audio_manager:
		audio_manager.set_music_ducked(true)

	if winner != null:
		winner.enter_winner_state()
		if camera_rig:
			camera_rig.set_follow_target(winner, true, false)

	if hud:
		hud.update_player_badges(characters, get_living_players().size())
		hud.show_match_result(is_draw, winner, current_round, arena.current_stage)

	match_ended.emit(is_draw, winner)


func cycle_spectator_target(step: int) -> void:
	var living := get_living_players()
	if living.is_empty():
		return
	_spectated_index = posmod(_spectated_index + step, living.size())
	_refresh_spectator_target()


func _refresh_spectator_target() -> void:
	var living := get_living_players()
	if living.is_empty():
		return
	_spectated_index = posmod(_spectated_index, living.size())
	var target := living[_spectated_index]
	_update_stealth_visibility()
	if camera_rig:
		camera_rig.set_follow_target(target, true, false)
	if hud:
		hud.set_spectator_mode_ui(true, target.display_name)


func _update_hud_display() -> void:
	if not hud:
		return

	var is_firing := (current_phase == MatchPhase.RESOLUTION_FREEZE)
	var phase_str := "LASER DISCHARGE!" if is_firing else "STEALTH PREP (HIDDEN)"
	var max_t := resolution_freeze_duration if is_firing else preparation_duration
	hud.update_round_timer(current_round, phase_str, phase_timer, max_t, is_firing)

	var cur_stage := arena.current_stage
	var cur_ratio := arena.get_stage_width_ratio(cur_stage)
	var next_stage: int = mini(4, cur_stage + 1)
	var next_ratio := arena.get_stage_width_ratio(next_stage)
	hud.update_arena_stage_info(
		cur_stage,
		cur_ratio,
		arena.is_warning_active,
		next_stage,
		next_ratio,
		shrink_timer
	)


func _on_replay_requested() -> void:
	if is_online_match and multiplayer_client and multiplayer_client.is_connected_to_server():
		var in_room := not multiplayer_client.current_room_code.is_empty()
		if in_room:
			multiplayer_client.request_rematch()
		enter_main_menu()
		if hud and hud.main_menu:
			hud.main_menu.set_online_lobby_open(true)
		if not in_room:
			multiplayer_client.request_quick_join(2, false)
		return
	_run_after_post_match_ad(start_new_match)


## Returns true while the player is in active gameplay (countdown, aiming, shooting, laser resolution).
func is_in_active_gameplay() -> bool:
	return current_phase == MatchPhase.PREPARATION or current_phase == MatchPhase.RESOLUTION_FREEZE


## Returns true while any online session / matchmaking / lobby / room operation is active.
## Interstitials are never shown in these states (an Android interstitial pauses the main loop,
## which would stall ENet polling and get the player timed out by the server).
func is_online_or_lobby_busy() -> bool:
	if is_online_match:
		return true
	if multiplayer_client == null:
		return false
	return (
		multiplayer_client.is_connecting()
		or multiplayer_client.in_matchmaking_queue
		or multiplayer_client.is_room_request_in_flight()
		or not multiplayer_client.current_room_code.is_empty()
		or not multiplayer_client.current_session_id.is_empty()
	)


## Shows an interstitial at a safe post-match break (if one is loaded and allowed), then continues.
## The continuation always runs, whether the ad shows, fails, is skipped, or AdMob is unavailable.
func _run_after_post_match_ad(continuation: Callable) -> void:
	if ad_manager == null:
		continuation.call()
		return
	if ad_manager.is_showing_interstitial:
		return # Ignore repeated taps while an ad is on screen
	ad_manager.show_post_match_interstitial_then(
		int(current_phase),
		is_in_active_gameplay(),
		is_online_or_lobby_busy(),
		continuation
	)


func return_to_lobby() -> void:
	var was_online_room := is_online_match and multiplayer_client != null and multiplayer_client.is_connected_to_server() and not multiplayer_client.current_room_code.is_empty()
	if current_phase == MatchPhase.MATCH_OVER and not was_online_room and not is_online_match:
		_run_after_post_match_ad(func(): _do_return_to_lobby(false))
		return
	_do_return_to_lobby(was_online_room)


func _do_return_to_lobby(was_online_room: bool) -> void:
	return_to_lobby_requested.emit()
	if not lobby_scene_path.is_empty() and ResourceLoader.exists(lobby_scene_path):
		get_tree().change_scene_to_file(lobby_scene_path)
		return
	enter_main_menu()
	if was_online_room and hud and hud.main_menu:
		hud.main_menu.set_online_lobby_open(true)


func _setup_subsystems() -> void:
	audio_manager = AudioManager.new()
	audio_manager.name = "AudioManager"
	add_child(audio_manager)

	ad_manager = AdMobManager.new()
	ad_manager.name = "AdMobManager"
	add_child(ad_manager)

	multiplayer_client = MultiplayerClient.new()
	multiplayer_client.name = "MultiplayerClient"
	add_child(multiplayer_client)
	multiplayer_client.authoritative_match_started.connect(_on_online_match_started)
	multiplayer_client.authoritative_snapshot_received.connect(_on_online_snapshot_received)
	multiplayer_client.authoritative_round_started.connect(_on_online_round_started)
	multiplayer_client.authoritative_laser_resolution.connect(_on_online_laser_resolution)
	multiplayer_client.authoritative_player_eliminated.connect(_on_online_player_eliminated)
	multiplayer_client.authoritative_arena_shrink_event.connect(_on_online_arena_shrink_event)
	multiplayer_client.authoritative_player_disconnected.connect(_on_online_player_disconnected)
	multiplayer_client.authoritative_match_ended.connect(_on_online_match_ended)
	multiplayer_client.disconnected_from_game_server.connect(_on_online_disconnected)

	var arena_scene := load("res://scenes/arena.tscn") as PackedScene
	arena = (arena_scene.instantiate() as ArenaGenerator) if arena_scene else ArenaGenerator.new()
	arena.name = "ArenaGenerator"
	arena.shrink_warning_started.connect(func(_target_stage: int, _ratio: float, _dur: float):
		if audio_manager:
			audio_manager.play_shrink_warning()
	)
	arena.stage_shrunk.connect(func(_new_stage: int, _ratio: float, _half_w: float):
		shrink_timer = shrink_stage_interval
		if audio_manager:
			audio_manager.play_platform_drop()
	)
	add_child(arena)

	camera_rig = CameraRig.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)

	var hud_scene := load("res://ui/hud.tscn") as PackedScene
	hud = (hud_scene.instantiate() as HUDController) if hud_scene else HUDController.new()
	hud.name = "HUDController"
	add_child(hud)
	if hud.main_menu and hud.main_menu.online_modal:
		hud.main_menu.online_modal.bind_client(multiplayer_client)

	hud.play_match_requested.connect(start_new_match)
	hud.spectator_prev_requested.connect(func(): cycle_spectator_target(-1))
	hud.spectator_next_requested.connect(func(): cycle_spectator_target(1))
	hud.replay_requested.connect(_on_replay_requested)
	hud.return_to_lobby_requested.connect(return_to_lobby)
	hud.master_volume_changed.connect(func(v: float):
		if audio_manager:
			audio_manager.set_master_volume(v)
	)
	hud.music_volume_changed.connect(func(v: float):
		if audio_manager:
			audio_manager.set_music_volume(v)
	)
	hud.sfx_volume_changed.connect(func(v: float):
		if audio_manager:
			audio_manager.set_sfx_volume(v)
	)
	hud.camera_sensitivity_changed.connect(func(mult: float):
		if camera_rig:
			camera_rig.set_camera_sensitivity(mult)
	)
	hud.sound_mute_toggled.connect(func(muted: bool):
		if audio_manager:
			audio_manager.set_sound_muted(muted)
	)

	# Create the 5 characters (1 Human + 4 AI Opponents)
	var chars_root := Node3D.new()
	chars_root.name = "Characters"
	add_child(chars_root)

	var ai_root := Node.new()
	ai_root.name = "AIControllers"
	add_child(ai_root)

	var char_scene := load("res://scenes/character.tscn") as PackedScene
	for cfg in CHARACTER_CONFIGS:
		var c := (char_scene.instantiate() as CharacterController) if char_scene else CharacterController.new()
		c.name = "Character_%s" % cfg["name"]
		chars_root.add_child(c)
		c.configure_character(
			cfg["id"],
			cfg["name"],
			cfg["human"],
			cfg["primary"],
			cfg["accent"],
			max_attack_range
		)
		c.character_eliminated.connect(_on_character_eliminated)
		characters.append(c)

		if cfg["human"]:
			human_character = c
		else:
			var ai := AIController.new()
			ai.name = "AI_%s" % cfg["name"]
			ai_root.add_child(ai)
			ai_controllers.append(ai)

	# Wire AI controllers to their characters and roster
	for i in range(ai_controllers.size()):
		ai_controllers[i].setup_ai(characters[i + 1], arena, characters, i + 1)

	# Wire mobile touch controls to the human character & online client
	if hud.mobile_controls:
		hud.mobile_controls.move_input_changed.connect(func(v: Vector2):
			if human_character:
				human_character.set_move_vector(v)
			if is_online_match and multiplayer_client:
				multiplayer_client.set_local_input(v, hud.mobile_controls.current_aim_vector)
		)
		hud.mobile_controls.aim_input_changed.connect(func(v: Vector2):
			if human_character:
				human_character.set_aim_vector(v)
			if is_online_match and multiplayer_client:
				multiplayer_client.set_local_input(hud.mobile_controls.current_move_vector, v)
		)


func _setup_environment_and_lighting() -> void:
	# WorldEnvironment with deep cosmic-slate backdrop & glow
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.08, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.65, 0.80)
	env.ambient_light_energy = 1.45
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.08
	world_env.environment = env
	add_child(world_env)

	# Primary Directional Sun Light with shadows
	var sun := DirectionalLight3D.new()
	sun.name = "DirectionalSunLight"
	sun.rotation_degrees = Vector3(-60.0, 32.0, 0.0)
	sun.light_color = Color(1.0, 0.98, 0.94)
	sun.light_energy = 1.65
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 65.0
	add_child(sun)

	# Subtle cool rim/fill light from opposite angle
	var fill := DirectionalLight3D.new()
	fill.name = "DirectionalFillLight"
	fill.rotation_degrees = Vector3(-42.0, -145.0, 0.0)
	fill.light_color = Color(0.35, 0.65, 1.0)
	fill.light_energy = 0.45
	fill.shadow_enabled = false
	add_child(fill)

	# Decorative abyss grid far below the floating platform to accentuate height & falling
	var abyss_ring := MeshInstance3D.new()
	abyss_ring.name = "AbyssBackdrop"
	var torus := TorusMesh.new()
	torus.inner_radius = 18.0
	torus.outer_radius = 19.2
	torus.rings = 32
	torus.ring_segments = 8
	abyss_ring.mesh = torus
	abyss_ring.position = Vector3(0.0, -14.0, 0.0)
	var abyss_mat := StandardMaterial3D.new()
	abyss_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	abyss_mat.albedo_color = Color(0.08, 0.22, 0.36, 0.5)
	abyss_ring.material_override = abyss_mat
	add_child(abyss_ring)
