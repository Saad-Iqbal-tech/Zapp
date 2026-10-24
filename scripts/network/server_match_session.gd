class_name ServerMatchSession
extends Node3D
## Authoritative server-side match session for up to 5 participants (human clients + optional server AI).
## Reuses ArenaGenerator, CharacterController, AimLine, and AIController so online gameplay rules
## match local gameplay rules 100%.

signal snapshot_generated(session_id: String, snapshot_msg: Dictionary)
signal reliable_event_generated(session_id: String, event_msg: Dictionary)
signal session_match_ended(session_id: String, result_summary: Dictionary)

enum MatchPhase {
	WAITING,
	PREPARATION,
	RESOLUTION_FREEZE,
	MATCH_OVER
}

const PALETTES: Array[Dictionary] = [
	{"primary": Color(0.0, 0.86, 1.0), "accent": Color(0.55, 0.98, 1.0), "bot_name": "BOT_CYAN"},
	{"primary": Color(1.0, 0.20, 0.34), "accent": Color(1.0, 0.58, 0.66), "bot_name": "VEX"},
	{"primary": Color(0.10, 0.92, 0.46), "accent": Color(0.58, 1.0, 0.76), "bot_name": "NOVA"},
	{"primary": Color(1.0, 0.80, 0.12), "accent": Color(1.0, 0.94, 0.55), "bot_name": "SOL"},
	{"primary": Color(0.82, 0.22, 1.0), "accent": Color(0.94, 0.62, 1.0), "bot_name": "NYX"}
]

var session_id: String = "match_1"
var room_code: String = ""

var preparation_duration: float = 5.0
var resolution_freeze_duration: float = 0.85
var max_attack_range: float = 14.0
var shrink_stage_interval: float = 11.0
var shrink_warning_duration: float = 4.0

var arena: ArenaGenerator
var characters: Array[CharacterController] = []
var ai_controllers: Array[AIController] = []

# Slot metadata: { slot_id, peer_id, name, is_human, is_ai, active, connected, eliminations }
var slot_configs: Array[Dictionary] = []
var peer_to_slot: Dictionary = {} # peer_id (int) -> slot_id (int)
var last_input_seq: Dictionary = {} # peer_id (int) -> int

var current_phase: MatchPhase = MatchPhase.WAITING
var current_round: int = 1
var phase_timer: float = 5.0
var shrink_timer: float = 11.0

var _snapshot_accum: float = 0.0
var _snapshot_seq: int = 0
var _is_resolving_simultaneous_batch: bool = false

var _chars_root: Node3D
var _ai_root: Node


func _ready() -> void:
	_setup_nodes()


func _setup_nodes() -> void:
	var arena_scene := load("res://scenes/arena.tscn") as PackedScene
	arena = (arena_scene.instantiate() as ArenaGenerator) if arena_scene else ArenaGenerator.new()
	arena.name = "ArenaGenerator"
	arena.shrink_warning_started.connect(_on_arena_shrink_warning_started)
	arena.stage_shrunk.connect(_on_arena_stage_shrunk)
	add_child(arena)

	_chars_root = Node3D.new()
	_chars_root.name = "Characters"
	add_child(_chars_root)

	_ai_root = Node.new()
	_ai_root.name = "AIControllers"
	add_child(_ai_root)

	var char_scene := load("res://scenes/character.tscn") as PackedScene
	for i in range(NetProtocol.MAX_PLAYERS_PER_MATCH):
		var c := (char_scene.instantiate() as CharacterController) if char_scene else CharacterController.new()
		c.name = "ServerCharacter_%d" % i
		c.is_network_controlled = false # Server runs full authoritative physics & fall checks
		_chars_root.add_child(c)
		var pal: Dictionary = PALETTES[i % PALETTES.size()]
		c.configure_character(i, pal["bot_name"], false, pal["primary"], pal["accent"], max_attack_range)
		c.character_eliminated.connect(_on_character_eliminated)
		characters.append(c)


## Starts an authoritative match with the given participant list.
## Each entry in participants: { "peer_id": int (0 for AI), "name": String, "is_ai": bool }
func start_authoritative_match(participants: Array[Dictionary]) -> void:
	slot_configs.clear()
	peer_to_slot.clear()
	last_input_seq.clear()

	for child in _ai_root.get_children():
		_ai_root.remove_child(child)
		child.free()
	ai_controllers.clear()

	arena.generate_arena()
	var spawn_points := arena.get_spawn_positions()
	var obs_aabbs := arena.get_active_obstacle_aabbs()

	for i in range(NetProtocol.MAX_PLAYERS_PER_MATCH):
		var c := characters[i]
		var pal: Dictionary = PALETTES[i % PALETTES.size()]
		var sp := spawn_points[i % spawn_points.size()]
		var inward_dir := Vector3(-sp.x, 0.0, -sp.z).normalized()
		c.max_attack_range = max_attack_range
		c.set_obstacle_aabbs(obs_aabbs)

		if i < participants.size():
			var p_info: Dictionary = participants[i]
			var peer_id: int = int(p_info.get("peer_id", 0))
			var is_ai: bool = bool(p_info.get("is_ai", peer_id <= 0))
			var p_name: String = str(p_info.get("name", pal["bot_name"]))
			var is_human := not is_ai and peer_id > 0

			c.configure_character(i, p_name, is_human, pal["primary"], pal["accent"], max_attack_range)
			c.spawn_at(sp, inward_dir)
			c.set_preparation_status(true, 0.0)
			c.set_stealth_hidden(not is_human)

			var slot_dict := {
				"slot_id": i,
				"peer_id": peer_id,
				"name": p_name,
				"is_human": is_human,
				"is_ai": is_ai,
				"active": true,
				"connected": is_human,
				"eliminations": 0
			}
			slot_configs.append(slot_dict)

			if is_human:
				peer_to_slot[peer_id] = i
				last_input_seq[peer_id] = 0
			elif is_ai:
				var ai := AIController.new()
				ai.name = "ServerAI_%d" % i
				_ai_root.add_child(ai)
				ai.setup_ai(c, arena, characters, i + 1)
				ai_controllers.append(ai)
		else:
			# Unused slot when match has fewer than 5 total participants and AI fill is off
			c.configure_character(i, "EMPTY", false, pal["primary"], pal["accent"], max_attack_range)
			c.spawn_at(Vector3(0.0, -50.0, 0.0), Vector3.BACK)
			c.set_controls_frozen(true)
			c.set_character_state(CharacterController.State.ELIMINATED)
			if c._collision_shape:
				c._collision_shape.disabled = true
			c.visible = false
			slot_configs.append({
				"slot_id": i,
				"peer_id": -1,
				"name": "EMPTY",
				"is_human": false,
				"is_ai": false,
				"active": false,
				"connected": false,
				"eliminations": 0
			})

	current_round = 1
	current_phase = MatchPhase.PREPARATION
	phase_timer = preparation_duration
	shrink_timer = shrink_stage_interval
	_snapshot_seq = 0
	_snapshot_accum = 0.0

	var match_start_msg := {
		"type": NetProtocol.S2C_MATCH_STARTED,
		"session_id": session_id,
		"room_code": room_code,
		"round": current_round,
		"preparation_duration": preparation_duration,
		"resolution_freeze_duration": resolution_freeze_duration,
		"shrink_stage_interval": shrink_stage_interval,
		"shrink_warning_duration": shrink_warning_duration,
		"slots": slot_configs.duplicate(true),
		"initial_snapshot": build_state_snapshot()
	}
	reliable_event_generated.emit(session_id, match_start_msg)


func apply_client_input(peer_id: int, raw_move: Variant, raw_aim: Variant, seq: int = 0) -> bool:
	if not peer_to_slot.has(peer_id):
		return false
	if current_phase != MatchPhase.PREPARATION:
		return false

	var last_seq: int = int(last_input_seq.get(peer_id, -1))
	if seq > 0 and seq < last_seq:
		# Ignore stale out-of-order input packet
		return false
	if seq > 0:
		last_input_seq[peer_id] = seq

	var slot_id: int = peer_to_slot[peer_id]
	if slot_id < 0 or slot_id >= characters.size():
		return false

	var c := characters[slot_id]
	if not c.is_alive() or c.controls_frozen:
		return false

	var current_aim_2d := Vector2(c.aim_direction.x, c.aim_direction.z)
	var clean_move := NetProtocol.sanitize_move_vector(raw_move)
	var clean_aim := NetProtocol.sanitize_aim_vector(raw_aim, current_aim_2d)

	c.set_move_vector(clean_move)
	c.set_aim_vector(clean_aim)
	return true


func handle_peer_disconnected(peer_id: int) -> void:
	if not peer_to_slot.has(peer_id):
		return
	var slot_id: int = peer_to_slot[peer_id]
	peer_to_slot.erase(peer_id)

	if slot_id >= 0 and slot_id < slot_configs.size():
		slot_configs[slot_id]["connected"] = false

	if slot_id >= 0 and slot_id < characters.size():
		var c := characters[slot_id]
		var was_alive := c.is_alive()
		if was_alive and current_phase != MatchPhase.MATCH_OVER:
			c.eliminate("DISCONNECTED")
		reliable_event_generated.emit(session_id, {
			"type": NetProtocol.S2C_PLAYER_DISCONNECTED,
			"session_id": session_id,
			"slot_id": slot_id,
			"peer_id": peer_id,
			"name": c.display_name,
			"was_alive": was_alive
		})
		if current_phase != MatchPhase.MATCH_OVER:
			_check_post_elimination_states()


func _process(delta: float) -> void:
	if current_phase == MatchPhase.WAITING or current_phase == MatchPhase.MATCH_OVER:
		return

	var obs_aabbs := arena.get_active_obstacle_aabbs()
	for i in range(characters.size()):
		if slot_configs[i]["active"]:
			characters[i].set_obstacle_aabbs(obs_aabbs)

	_update_arena_shrinking(delta)
	_update_round_cycle(delta)

	_snapshot_accum += delta
	var snap_interval := 1.0 / NetProtocol.SERVER_TICK_RATE_HZ
	if _snapshot_accum >= snap_interval:
		_snapshot_accum = fmod(_snapshot_accum, snap_interval)
		snapshot_generated.emit(session_id, build_state_snapshot())


func _update_round_cycle(delta: float) -> void:
	phase_timer -= delta

	if current_phase == MatchPhase.PREPARATION:
		var urgency := clampf(1.0 - (phase_timer / maxf(0.01, preparation_duration)), 0.0, 1.0)
		for i in range(characters.size()):
			if slot_configs[i]["active"] and characters[i].is_alive():
				characters[i].set_preparation_status(true, urgency)

		if phase_timer <= 0.0:
			_trigger_simultaneous_resolution()

	elif current_phase == MatchPhase.RESOLUTION_FREEZE:
		if phase_timer <= 0.0:
			_begin_next_preparation_round()


func _trigger_simultaneous_resolution() -> void:
	current_phase = MatchPhase.RESOLUTION_FREEZE
	phase_timer = resolution_freeze_duration

	var living := get_living_players()
	var obs_aabbs := arena.get_active_obstacle_aabbs()

	# 1. Freeze movement & aiming and take an atomic snapshot of all living players
	var snapshots: Dictionary = {}
	var beam_records: Array[Dictionary] = []

	for c in living:
		c.set_preparation_status(false, 1.0)
		c.set_controls_frozen(true)
		c.set_firing_burst(true)
		var seg := c.get_attack_segment_snapshot(obs_aabbs)
		snapshots[c.player_id] = {
			"character": c,
			"position": c.global_position,
			"hit_radius": c.hit_radius,
			"segment": seg
		}
		beam_records.append({
			"slot_id": c.player_id,
			"origin": seg["origin"],
			"end": seg["end"],
			"direction": seg["direction"],
			"blocked": seg["blocked"]
		})

	# 2. Evaluate every living player's unobstructed line against all other living players simultaneously
	var eliminated_set: Dictionary = {} # slot_id -> CharacterController
	var killer_credits: Dictionary = {} # target_slot_id -> Array[int] (attacker_slot_ids)
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
				if not killer_credits.has(target_id):
					killer_credits[target_id] = []
				killer_credits[target_id].append(attacker_id)

	# Award elimination stats to attackers
	for target_id in killer_credits.keys():
		var attackers: Array = killer_credits[target_id]
		for att_id in attackers:
			if att_id >= 0 and att_id < slot_configs.size():
				slot_configs[att_id]["eliminations"] = int(slot_configs[att_id]["eliminations"]) + 1

	# 3. Apply simultaneous eliminations atomically before checking winner/draw
	_is_resolving_simultaneous_batch = true
	var eliminated_slots: Array[int] = []
	var eliminated_names: Array[String] = []
	for target_id in eliminated_set.keys():
		var victim: CharacterController = eliminated_set[target_id]
		victim.eliminate("LASER")
		eliminated_slots.append(int(target_id))
		eliminated_names.append(victim.display_name)
	_is_resolving_simultaneous_batch = false

	reliable_event_generated.emit(session_id, {
		"type": NetProtocol.S2C_LASER_RESOLUTION,
		"session_id": session_id,
		"round": current_round,
		"beams": beam_records,
		"eliminated_slots": eliminated_slots,
		"eliminated_names": eliminated_names,
		"snapshot": build_state_snapshot()
	})

	_check_post_elimination_states()


func _begin_next_preparation_round() -> void:
	if current_phase == MatchPhase.MATCH_OVER:
		return

	current_round += 1
	current_phase = MatchPhase.PREPARATION
	phase_timer = preparation_duration

	for i in range(characters.size()):
		if not slot_configs[i]["active"]:
			continue
		var c := characters[i]
		if c.is_alive():
			c.set_controls_frozen(false)
			c.set_firing_burst(false)
			c.set_preparation_status(true, 0.0)
			c.set_stealth_hidden(not bool(slot_configs[i]["is_human"]))

	reliable_event_generated.emit(session_id, {
		"type": NetProtocol.S2C_ROUND_STARTED,
		"session_id": session_id,
		"round": current_round,
		"preparation_duration": preparation_duration,
		"snapshot": build_state_snapshot()
	})


func _update_arena_shrinking(delta: float) -> void:
	if current_phase == MatchPhase.MATCH_OVER:
		return
	if arena.current_stage >= 4:
		return

	shrink_timer -= delta
	var next_stage := arena.current_stage + 1

	if not arena.is_warning_active and shrink_timer <= shrink_warning_duration:
		arena.start_shrink_warning(next_stage, shrink_warning_duration)

	if shrink_timer <= 0.0:
		arena.execute_shrink_to_stage(next_stage)
		shrink_timer = shrink_stage_interval


func _on_arena_shrink_warning_started(target_stage: int, next_ratio: float, duration: float) -> void:
	reliable_event_generated.emit(session_id, {
		"type": NetProtocol.S2C_ARENA_SHRINK_EVENT,
		"session_id": session_id,
		"event": "warning_started",
		"target_stage": target_stage,
		"width_ratio": next_ratio,
		"duration": duration,
		"shrink_timer": shrink_timer
	})


func _on_arena_stage_shrunk(new_stage: int, safe_ratio: float, safe_half_w: float) -> void:
	reliable_event_generated.emit(session_id, {
		"type": NetProtocol.S2C_ARENA_SHRINK_EVENT,
		"session_id": session_id,
		"event": "stage_shrunk",
		"new_stage": new_stage,
		"width_ratio": safe_ratio,
		"safe_half_width": safe_half_w,
		"shrink_timer": shrink_timer
	})


func _on_character_eliminated(character: CharacterController, reason: String) -> void:
	if current_phase == MatchPhase.MATCH_OVER:
		return
	if slot_configs.size() > character.player_id and not slot_configs[character.player_id]["active"]:
		return

	if reason == "FALL":
		reliable_event_generated.emit(session_id, {
			"type": NetProtocol.S2C_PLAYER_ELIMINATED,
			"session_id": session_id,
			"slot_id": character.player_id,
			"name": character.display_name,
			"reason": "FALL"
		})

	if not _is_resolving_simultaneous_batch:
		_check_post_elimination_states()


func _check_post_elimination_states() -> void:
	if current_phase == MatchPhase.MATCH_OVER:
		return

	var living := get_living_players()
	if living.size() == 1:
		_finish_match(false, living[0])
	elif living.size() == 0:
		_finish_match(true, null)


func _finish_match(is_draw: bool, winner: CharacterController) -> void:
	if current_phase == MatchPhase.MATCH_OVER:
		return
	current_phase = MatchPhase.MATCH_OVER
	arena.stop_all_shrinking()

	var winner_slot := -1
	var winner_name := ""
	if winner != null:
		winner.enter_winner_state()
		winner_slot = winner.player_id
		winner_name = winner.display_name

	var summary := {
		"type": NetProtocol.S2C_MATCH_ENDED,
		"session_id": session_id,
		"room_code": room_code,
		"is_draw": is_draw,
		"winner_slot_id": winner_slot,
		"winner_name": winner_name,
		"rounds_completed": current_round,
		"final_stage": arena.current_stage,
		"slots": slot_configs.duplicate(true),
		"snapshot": build_state_snapshot()
	}
	reliable_event_generated.emit(session_id, summary)
	session_match_ended.emit(session_id, summary)


func get_living_players() -> Array[CharacterController]:
	var alive: Array[CharacterController] = []
	for i in range(characters.size()):
		if i < slot_configs.size() and not slot_configs[i]["active"]:
			continue
		if characters[i].is_alive():
			alive.append(characters[i])
	return alive


func build_state_snapshot() -> Dictionary:
	_snapshot_seq += 1
	var players_arr: Array[Dictionary] = []
	for i in range(characters.size()):
		if i < slot_configs.size() and not slot_configs[i]["active"]:
			continue
		var c := characters[i]
		players_arr.append({
			"slot_id": i,
			"pos": c.global_position,
			"vel": c.velocity,
			"aim_dir": c.aim_direction,
			"state": int(c.current_state),
			"invincible": c.is_invincible,
			"frozen": c.controls_frozen
		})

	return {
		"type": NetProtocol.S2C_STATE_SNAPSHOT,
		"session_id": session_id,
		"seq": _snapshot_seq,
		"phase": int(current_phase),
		"round": current_round,
		"phase_timer": phase_timer,
		"shrink_timer": shrink_timer,
		"arena_stage": arena.current_stage if arena else 1,
		"warning_active": arena.is_warning_active if arena else false,
		"warning_target_stage": arena.warning_target_stage if arena else 2,
		"players": players_arr
	}
