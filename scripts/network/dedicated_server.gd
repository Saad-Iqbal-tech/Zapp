class_name DedicatedServer
extends Node3D
## Authoritative headless Godot multiplayer server using ENetMultiplayerPeer + SceneMultiplayer.
## Manages connected clients, private rooms (room codes, host controls, ready states, AI fill),
## honest public matchmaking queue, match sessions, input validation, and state broadcasting.

signal client_connected(peer_id: int)
signal client_disconnected(peer_id: int)
signal room_created(room_code: String, host_peer_id: int)
signal room_updated(room_code: String, room_state: Dictionary)
signal room_removed(room_code: String)
signal match_session_started(session_id: String, session: ServerMatchSession)
signal match_session_ended(session_id: String, summary: Dictionary)

const ROOM_CODE_ALPHABET: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const ROOM_CODE_LENGTH: int = 5
const BOT_NAMES: Array[String] = ["VEX", "NOVA", "SOL", "NYX", "ZED"]

var listen_port: int = NetProtocol.DEFAULT_PORT
var bind_address: String = "0.0.0.0"
var persistence_save_path: String = ServerPersistence.DEFAULT_SAVE_PATH
var persistence: ServerPersistence

var _peer: ENetMultiplayerPeer
var _mp: SceneMultiplayer
var _is_running: bool = false
var _rng := RandomNumberGenerator.new()
var _crypto := Crypto.new()

# peer_id (int) -> { "peer_id": int, "name": String, "session_id": String, "room_code": String }
var connected_peers: Dictionary = {}

# session_id (String) -> { "session": ServerMatchSession, "container": Node, "peer_ids": Array[int], "room_code": String }
var active_sessions: Dictionary = {}
var _next_session_num: int = 1

# room_code (String) -> {
#   "room_code": String,
#   "host_peer_id": int,
#   "target_humans": int,
#   "fill_ai": bool,
#   "ai_count": int,
#   "in_match": bool,
#   "session_id": String,
#   "members": Array[Dictionary] # { "peer_id": int, "name": String, "ready": bool, "is_host": bool }
# }
var rooms: Dictionary = {}

# Honest server-side public matchmaking queue (peer_ids waiting for public match)
var _quick_match_queue: Array[int] = []
var quick_match_required_players: int = 2
var quick_match_fill_with_ai: bool = false
var default_preparation_duration: float = 5.0
var default_shrink_interval: float = 11.0


func _ready() -> void:
	_rng.randomize()
	if persistence == null:
		persistence = ServerPersistence.new(persistence_save_path)
	_mp = SceneMultiplayer.new()
	_mp.server_relay = false
	_mp.root_path = get_path()
	_mp.peer_connected.connect(_on_peer_connected)
	_mp.peer_disconnected.connect(_on_peer_disconnected)
	_mp.peer_packet.connect(_on_peer_packet)


func start_server(
	port: int = NetProtocol.DEFAULT_PORT,
	bind_ip: String = "0.0.0.0",
	max_clients: int = NetProtocol.MAX_CLIENTS
) -> Error:
	if _is_running:
		stop_server()

	listen_port = port
	bind_address = bind_ip
	_peer = ENetMultiplayerPeer.new()
	if not bind_ip.is_empty() and bind_ip != "*":
		_peer.set_bind_ip(bind_ip)

	var err := _peer.create_server(port, max_clients, 2)
	if err != OK:
		push_error("[DedicatedServer] Failed to start ENet server on %s:%d (err=%d)" % [bind_ip, port, err])
		return err

	_mp.multiplayer_peer = _peer
	_is_running = true
	print("[DedicatedServer] Listening on UDP %s:%d (max_clients=%d)" % [bind_ip, port, max_clients])
	return OK


func stop_server() -> void:
	for sid in active_sessions.keys():
		_cleanup_session(sid)
	active_sessions.clear()
	rooms.clear()

	if _peer and _is_running:
		for pid in connected_peers.keys():
			_peer.disconnect_peer(int(pid), true)
		if _mp and _mp.has_multiplayer_peer():
			_mp.poll()

	connected_peers.clear()
	_quick_match_queue.clear()

	if _mp:
		_mp.multiplayer_peer = null
	if _peer:
		_peer.close()
		_peer = null
	_is_running = false


func _exit_tree() -> void:
	stop_server()
	if _mp:
		_mp.clear()
		_mp = null


func is_running() -> bool:
	return _is_running


func _process(_delta: float) -> void:
	if _is_running and _mp and _mp.has_multiplayer_peer():
		_mp.poll()
		_reap_finished_sessions()


func _reap_finished_sessions() -> void:
	if active_sessions.is_empty():
		return
	var now_ms := Time.get_ticks_msec()
	var to_clean: Array[String] = []
	for sid in active_sessions.keys():
		var info: Dictionary = active_sessions[sid]
		var fin_ms := int(info.get("finished_at_ms", 0))
		if fin_ms > 0 and (now_ms - fin_ms) >= 1500:
			to_clean.append(str(sid))
	for sid in to_clean:
		_cleanup_session(sid)


static func _safe_int(val: Variant, fallback: int = 0) -> int:
	if typeof(val) == TYPE_INT:
		return val
	if typeof(val) == TYPE_FLOAT:
		if is_nan(val) or is_inf(val):
			return fallback
		return int(val)
	if typeof(val) == TYPE_BOOL:
		return 1 if val else 0
	if typeof(val) == TYPE_STRING and (val as String).strip_edges().is_valid_int():
		return int((val as String).strip_edges())
	return fallback


static func _safe_bool(val: Variant, fallback: bool = false) -> bool:
	if typeof(val) == TYPE_BOOL:
		return val
	if typeof(val) == TYPE_INT:
		return val != 0
	return fallback


static func _safe_str(val: Variant, fallback: String = "") -> String:
	if typeof(val) == TYPE_STRING:
		return val
	if typeof(val) == TYPE_STRING_NAME:
		return String(val)
	return fallback


func _is_peer_in_active_match(peer_id: int) -> bool:
	if not connected_peers.has(peer_id):
		return false
	var sid := str(connected_peers[peer_id].get("session_id", ""))
	if sid.is_empty():
		return false
	if not active_sessions.has(sid):
		connected_peers[peer_id]["session_id"] = ""
		return false
	var s: ServerMatchSession = active_sessions[sid].get("session", null)
	if not is_instance_valid(s) or s.current_phase == ServerMatchSession.MatchPhase.MATCH_OVER:
		connected_peers[peer_id]["session_id"] = ""
		return false
	return true


func _evict_duplicate_peer(old_peer_id: int, reason: String) -> void:
	if not connected_peers.has(old_peer_id):
		return
	send_error_to_peer(old_peer_id, "ERR_DUPLICATE_IDENTITY", reason)
	_on_peer_disconnected(old_peer_id)


func _update_authenticated_peer_name(peer_id: int, requested_name_var: Variant) -> String:
	if not connected_peers.has(peer_id):
		return "PLAYER_%d" % peer_id
	var cur_name := str(connected_peers[peer_id].get("name", "PLAYER_%d" % peer_id))
	var req_str := _safe_str(requested_name_var, "").strip_edges()
	if req_str.is_empty():
		return cur_name
	var raw_tok := str(connected_peers[peer_id].get("raw_token", ""))
	if persistence != null and not raw_tok.is_empty():
		var prof := persistence.authenticate_or_register_player(req_str, raw_tok, peer_id)
		var resolved := str(prof.get("username", cur_name))
		connected_peers[peer_id]["name"] = resolved
		return resolved
	var sanitized := NetProtocol.sanitize_player_name(req_str, cur_name)
	connected_peers[peer_id]["name"] = sanitized
	return sanitized


func send_to_peer(peer_id: int, msg: Dictionary, reliable: bool = true) -> void:
	if not _is_running or not _mp or not _mp.has_multiplayer_peer() or not connected_peers.has(peer_id):
		return
	if _peer:
		var pkt_peer := _peer.get_peer(peer_id)
		if pkt_peer == null or pkt_peer.get_state() != ENetPacketPeer.STATE_CONNECTED:
			return
	var mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
	var channel := NetProtocol.CHANNEL_RELIABLE if reliable else NetProtocol.CHANNEL_UNRELIABLE_STATE
	var raw := var_to_bytes(msg)
	_mp.send_bytes(raw, peer_id, mode, channel)


func send_error_to_peer(peer_id: int, code: String, message: String) -> void:
	send_to_peer(peer_id, {
		"type": NetProtocol.S2C_ERROR,
		"code": code,
		"message": message
	}, true)


func broadcast_to_peers(peer_ids: Array, msg: Dictionary, reliable: bool = true) -> void:
	for pid in peer_ids:
		send_to_peer(int(pid), msg, reliable)


func create_match_session(
	participants: Array[Dictionary],
	custom_config: Dictionary = {}
) -> ServerMatchSession:
	# Clean up any previously finished sessions before creating a new one
	var finished_sids: Array[String] = []
	for existing_sid in active_sessions.keys():
		var ex_info: Dictionary = active_sessions[existing_sid]
		var ex_sess: ServerMatchSession = ex_info.get("session", null)
		if int(ex_info.get("finished_at_ms", 0)) > 0 or (is_instance_valid(ex_sess) and ex_sess.current_phase == ServerMatchSession.MatchPhase.MATCH_OVER):
			finished_sids.append(str(existing_sid))
	for f_sid in finished_sids:
		_cleanup_session(f_sid)

	var session_id := "session_%d" % _next_session_num
	_next_session_num += 1
	var room_code := str(custom_config.get("room_code", ""))

	var container: Node = self
	# If another session is already active, isolate the new session in its own 3D World SubViewport
	if not active_sessions.is_empty():
		var vp := SubViewport.new()
		vp.name = "Viewport_%s" % session_id
		vp.own_world_3d = true
		vp.world_3d = World3D.new()
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		PhysicsServer3D.space_set_active(vp.find_world_3d().space, true)
		container = vp

	var session := ServerMatchSession.new()
	session.name = "Match_%s" % session_id
	session.session_id = session_id
	session.room_code = room_code
	session.preparation_duration = float(custom_config.get("preparation_duration", default_preparation_duration))
	session.shrink_stage_interval = float(custom_config.get("shrink_stage_interval", default_shrink_interval))
	session.shrink_warning_duration = float(custom_config.get("shrink_warning_duration", 4.0))
	session.max_attack_range = float(custom_config.get("max_attack_range", 14.0))
	container.add_child(session)

	# Deduplicate human participants and cap total participants at MAX_PLAYERS_PER_MATCH (5)
	var clean_participants: Array[Dictionary] = []
	var human_peers: Array[int] = []
	var seen_human_names: Dictionary = {}
	for p in participants:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		if clean_participants.size() >= NetProtocol.MAX_PLAYERS_PER_MATCH:
			break
		var pid := _safe_int(p.get("peer_id", 0), 0)
		var is_ai_flag := _safe_bool(p.get("is_ai", pid <= 0), pid <= 0)
		if not is_ai_flag and pid > 0:
			if human_peers.has(pid):
				continue
			var resolved_name := str(p.get("name", "PLAYER_%d" % pid))
			if connected_peers.has(pid):
				resolved_name = str(connected_peers[pid].get("name", resolved_name))
			if seen_human_names.has(resolved_name):
				continue
			seen_human_names[resolved_name] = true
			_quick_match_queue.erase(pid)
			if not connected_peers.has(pid):
				connected_peers[pid] = {
					"peer_id": pid,
					"name": resolved_name,
					"authenticated": true,
					"raw_token": "session_peer_%d" % pid,
					"token_hash": ("session_peer_%d" % pid).sha256_text(),
					"session_id": session_id,
					"room_code": room_code,
					"window_start_ms": Time.get_ticks_msec(),
					"packet_count_in_window": 0,
					"control_count_in_window": 0,
					"failed_join_attempts": 0,
					"join_lockout_until_ms": 0
				}
			else:
				connected_peers[pid]["session_id"] = session_id
			human_peers.append(pid)
			clean_participants.append({
				"peer_id": pid,
				"name": resolved_name,
				"is_ai": false
			})
		else:
			clean_participants.append({
				"peer_id": 0,
				"name": str(p.get("name", "BOT")),
				"is_ai": true
			})

	active_sessions[session_id] = {
		"session": session,
		"container": container,
		"peer_ids": human_peers,
		"room_code": room_code,
		"finished_at_ms": 0
	}

	session.snapshot_generated.connect(_on_session_snapshot_generated)
	session.reliable_event_generated.connect(_on_session_reliable_event_generated)
	session.session_match_ended.connect(_on_session_match_ended)

	session.start_authoritative_match(clean_participants)
	match_session_started.emit(session_id, session)
	return session


func get_session(session_id: String) -> ServerMatchSession:
	if active_sessions.has(session_id):
		return active_sessions[session_id]["session"] as ServerMatchSession
	return null


func _on_session_snapshot_generated(session_id: String, snapshot_msg: Dictionary) -> void:
	if not active_sessions.has(session_id):
		return
	var peer_ids: Array = active_sessions[session_id]["peer_ids"]
	broadcast_to_peers(peer_ids, snapshot_msg, false)


func _on_session_reliable_event_generated(session_id: String, event_msg: Dictionary) -> void:
	if not active_sessions.has(session_id):
		return
	var peer_ids: Array = active_sessions[session_id]["peer_ids"]
	broadcast_to_peers(peer_ids, event_msg, true)


func _on_session_match_ended(session_id: String, summary: Dictionary) -> void:
	if persistence != null:
		persistence.record_authoritative_match(summary)

	if active_sessions.has(session_id):
		active_sessions[session_id]["finished_at_ms"] = Time.get_ticks_msec()
		var peer_ids: Array = active_sessions[session_id]["peer_ids"]
		for pid in peer_ids:
			var p_int := int(pid)
			if connected_peers.has(p_int) and connected_peers[p_int]["session_id"] == session_id:
				connected_peers[p_int]["session_id"] = ""
			_send_stats_to_peer(p_int)

		var r_code: String = str(active_sessions[session_id].get("room_code", ""))
		if not r_code.is_empty() and rooms.has(r_code):
			var room: Dictionary = rooms[r_code]
			room["in_match"] = false
			room["session_id"] = ""
			_prune_disconnected_room_members(r_code)
			if rooms.has(r_code):
				# Reset non-host ready flags so players can ready up for a rematch or return to room lobby
				for m in room["members"]:
					m["ready"] = bool(m["is_host"])
				_broadcast_room_state(r_code)
	match_session_ended.emit(session_id, summary)


func _cleanup_session(session_id: String) -> void:
	if not active_sessions.has(session_id):
		return
	var info: Dictionary = active_sessions[session_id]
	var peer_ids: Array = info["peer_ids"]
	for pid in peer_ids:
		if connected_peers.has(pid) and connected_peers[pid]["session_id"] == session_id:
			connected_peers[pid]["session_id"] = ""

	var r_code: String = str(info.get("room_code", ""))
	if not r_code.is_empty() and rooms.has(r_code):
		rooms[r_code]["in_match"] = false
		rooms[r_code]["session_id"] = ""

	var session: ServerMatchSession = info["session"]
	var container: Node = info["container"]
	active_sessions.erase(session_id)

	if container != self and is_instance_valid(container):
		container.queue_free()
	elif is_instance_valid(session):
		session.queue_free()


func _on_peer_connected(peer_id: int) -> void:
	var default_name := "PLAYER_%d" % peer_id
	connected_peers[peer_id] = {
		"peer_id": peer_id,
		"name": default_name,
		"authenticated": false,
		"raw_token": "",
		"token_hash": "",
		"session_id": "",
		"room_code": "",
		"window_start_ms": Time.get_ticks_msec(),
		"packet_count_in_window": 0,
		"control_count_in_window": 0,
		"failed_join_attempts": 0,
		"join_lockout_until_ms": 0
	}
	if _peer:
		var pkt_peer := _peer.get_peer(peer_id)
		if pkt_peer:
			pkt_peer.set_timeout(1000, 2000, 3500)
	client_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if _quick_match_queue.has(peer_id):
		_quick_match_queue.erase(peer_id)
		_broadcast_queue_status(quick_match_required_players)

	if connected_peers.has(peer_id):
		var info: Dictionary = connected_peers[peer_id]
		var r_code: String = str(info.get("room_code", ""))
		if not r_code.is_empty():
			_remove_peer_from_room(peer_id, r_code, false)

		var sid: String = str(info.get("session_id", ""))
		if not sid.is_empty() and active_sessions.has(sid):
			var s_info: Dictionary = active_sessions[sid]
			s_info["peer_ids"].erase(peer_id)
			var session: ServerMatchSession = s_info["session"]
			if is_instance_valid(session):
				session.handle_peer_disconnected(peer_id)
			if s_info["peer_ids"].is_empty():
				_cleanup_session(sid)
		connected_peers.erase(peer_id)

	# Also sweep any rooms that might still reference peer_id
	for code_key in rooms.keys():
		_prune_disconnected_room_members(str(code_key))

	client_disconnected.emit(peer_id)


func _on_peer_packet(peer_id: int, packet: PackedByteArray) -> void:
	if not connected_peers.has(peer_id):
		return

	if packet.size() <= 0 or packet.size() > NetProtocol.MAX_CLIENT_PACKET_BYTES:
		send_error_to_peer(
			peer_id,
			"ERR_PACKET_TOO_LARGE",
			"Packet size (%d bytes) exceeds maximum allowed (%d bytes)" % [packet.size(), NetProtocol.MAX_CLIENT_PACKET_BYTES]
		)
		return

	var peer_info: Dictionary = connected_peers[peer_id]
	var now_ms := Time.get_ticks_msec()
	var win_start := int(peer_info.get("window_start_ms", now_ms))
	if (now_ms - win_start) >= 1000:
		peer_info["window_start_ms"] = now_ms
		peer_info["packet_count_in_window"] = 0
		peer_info["control_count_in_window"] = 0

	var pkt_count := int(peer_info.get("packet_count_in_window", 0)) + 1
	peer_info["packet_count_in_window"] = pkt_count
	if pkt_count > NetProtocol.MAX_PACKETS_PER_SEC:
		if pkt_count == NetProtocol.MAX_PACKETS_PER_SEC + 1:
			send_error_to_peer(peer_id, "ERR_RATE_LIMITED", "Packet rate limit exceeded")
		return

	var decoded: Variant = bytes_to_var(packet)
	if typeof(decoded) != TYPE_DICTIONARY:
		send_error_to_peer(peer_id, "ERR_MALFORMED_PACKET", "Payload must be a Dictionary")
		return

	var msg: Dictionary = decoded
	var msg_type: String = _safe_str(msg.get("type", ""), "")
	if msg_type.is_empty():
		send_error_to_peer(peer_id, "ERR_MALFORMED_PACKET", "Missing message type")
		return

	if msg_type != NetProtocol.C2S_PLAYER_INPUT and msg_type != NetProtocol.C2S_PING:
		var ctrl_count := int(peer_info.get("control_count_in_window", 0)) + 1
		peer_info["control_count_in_window"] = ctrl_count
		if ctrl_count > NetProtocol.MAX_CONTROL_MSGS_PER_SEC:
			if ctrl_count == NetProtocol.MAX_CONTROL_MSGS_PER_SEC + 1:
				send_error_to_peer(peer_id, "ERR_RATE_LIMITED", "Control message rate limit exceeded")
			return

	# Enforce C2S_HELLO authentication before allowing any room, queue, stats, or gameplay actions
	if msg_type != NetProtocol.C2S_HELLO and msg_type != NetProtocol.C2S_PING:
		if not bool(peer_info.get("authenticated", false)):
			send_error_to_peer(
				peer_id,
				"ERR_UNAUTHENTICATED",
				"Client must authenticate via C2S_HELLO before performing this action"
			)
			return

	match msg_type:
		NetProtocol.C2S_HELLO:
			var raw_token_var: Variant = msg.get("token", null)
			if not NetProtocol.is_valid_token(raw_token_var):
				send_error_to_peer(peer_id, "ERR_INVALID_TOKEN", "Authentication failed: invalid or missing token")
				return

			if bool(peer_info.get("authenticated", false)) and _is_peer_in_active_match(peer_id):
				send_error_to_peer(peer_id, "ERR_ALREADY_IN_MATCH", "Cannot re-authenticate or change identity during an active match")
				return

			var raw_token := (raw_token_var as String).strip_edges()
			var token_hash := raw_token.sha256_text()

			# Evict any other connected peer already authenticated with the exact same token_hash
			var duplicate_peers: Array[int] = []
			for other_pid in connected_peers.keys():
				var o_id := int(other_pid)
				if o_id != peer_id and bool(connected_peers[o_id].get("authenticated", false)):
					if str(connected_peers[o_id].get("token_hash", "")) == token_hash:
						duplicate_peers.append(o_id)
			for dup_id in duplicate_peers:
				_evict_duplicate_peer(dup_id, "Account connected from another session")

			var req_name := _safe_str(msg.get("name", "P_%d" % peer_id), "P_%d" % peer_id)
			var profile := persistence.authenticate_or_register_player(req_name, raw_token, peer_id) if persistence else {"username": NetProtocol.sanitize_player_name(req_name, "P_%d" % peer_id)}
			var clean_name := str(profile.get("username", "P_%d" % peer_id))
			connected_peers[peer_id]["name"] = clean_name
			connected_peers[peer_id]["authenticated"] = true
			connected_peers[peer_id]["raw_token"] = raw_token
			connected_peers[peer_id]["token_hash"] = token_hash

			# Also update name in active room if present
			var r_code: String = str(connected_peers[peer_id].get("room_code", ""))
			if not r_code.is_empty() and rooms.has(r_code):
				for m in rooms[r_code]["members"]:
					if int(m["peer_id"]) == peer_id:
						m["name"] = clean_name
				_broadcast_room_state(r_code)
			send_to_peer(peer_id, {
				"type": NetProtocol.S2C_WELCOME,
				"peer_id": peer_id,
				"assigned_name": clean_name,
				"profile": profile
			}, true)
			_send_stats_to_peer(peer_id)

		NetProtocol.C2S_PLAYER_INPUT:
			var sid: String = str(connected_peers[peer_id].get("session_id", ""))
			if not sid.is_empty() and active_sessions.has(sid):
				var session: ServerMatchSession = active_sessions[sid]["session"]
				if is_instance_valid(session):
					session.apply_client_input(
						peer_id,
						msg.get("move", Vector2.ZERO),
						msg.get("aim", Vector2(0.0, 1.0)),
						_safe_int(msg.get("seq", 0), 0)
					)

		NetProtocol.C2S_QUICK_JOIN:
			_handle_quick_join_request(peer_id, msg)

		NetProtocol.C2S_CANCEL_QUEUE:
			_quick_match_queue.erase(peer_id)
			send_to_peer(peer_id, {
				"type": NetProtocol.S2C_QUEUE_STATUS,
				"in_queue": false,
				"queued_count": _quick_match_queue.size(),
				"required_count": quick_match_required_players
			}, true)
			_broadcast_queue_status(quick_match_required_players)

		NetProtocol.C2S_CREATE_ROOM:
			_handle_create_room(peer_id, msg)

		NetProtocol.C2S_JOIN_ROOM:
			_handle_join_room(peer_id, msg)

		NetProtocol.C2S_LEAVE_ROOM:
			var r_code: String = str(connected_peers[peer_id].get("room_code", ""))
			if not r_code.is_empty():
				_remove_peer_from_room(peer_id, r_code, true)

		NetProtocol.C2S_SET_READY:
			_handle_set_ready(peer_id, msg)

		NetProtocol.C2S_CONFIGURE_ROOM:
			_handle_configure_room(peer_id, msg)

		NetProtocol.C2S_START_ROOM_MATCH:
			_handle_start_room_match(peer_id)

		NetProtocol.C2S_REQUEST_REMATCH:
			_handle_request_rematch(peer_id)

		NetProtocol.C2S_GET_STATS:
			_send_stats_to_peer(peer_id)

		NetProtocol.C2S_PING:
			send_to_peer(peer_id, {
				"type": NetProtocol.S2C_PONG,
				"client_time": _safe_int(msg.get("client_time", 0), 0)
			}, false)

		_:
			var lower_type := msg_type.to_lower()
			if lower_type.find("stat") != -1 or lower_type.find("win") != -1 or lower_type.find("score") != -1:
				send_error_to_peer(
					peer_id,
					"ERR_FORBIDDEN_CLIENT_STATS",
					"Statistics are server-authoritative and cannot be modified by clients"
				)
			elif (
				lower_type.begins_with("s2c_")
				or lower_type.find("elim") != -1
				or lower_type.find("kill") != -1
				or lower_type.find("pos") != -1
				or lower_type.find("teleport") != -1
				or lower_type.find("shrink") != -1
				or lower_type.find("timer") != -1
				or lower_type.find("round") != -1
				or lower_type.find("laser") != -1
				or lower_type.find("attack") != -1
				or lower_type.find("match") != -1
			):
				send_error_to_peer(
					peer_id,
					"ERR_FORBIDDEN_CLIENT_AUTHORITY",
					"Gameplay state, positions, attacks, timers, and match outcomes are server-authoritative"
				)
			else:
				send_error_to_peer(
					peer_id,
					"ERR_UNKNOWN_MESSAGE_TYPE",
					"Unrecognized client message type"
				)


func _send_stats_to_peer(peer_id: int) -> void:
	if not connected_peers.has(peer_id) or persistence == null:
		return
	var uname: String = str(connected_peers[peer_id].get("name", "P_%d" % peer_id))
	send_to_peer(peer_id, {
		"type": NetProtocol.S2C_STATS_RESPONSE,
		"profile": persistence.get_public_profile(uname),
		"leaderboard": persistence.get_leaderboard(20),
		"global_match_history": persistence.global_match_history.slice(0, 15)
	}, true)


# ============================================================================
# PHASE 2: PRIVATE ROOMS, HOST CONTROLS, READY STATES & AI FILL
# ============================================================================

func _generate_unique_room_code() -> String:
	var alpha_len := ROOM_CODE_ALPHABET.length()
	for _attempt in range(128):
		var rand_bytes := _crypto.generate_random_bytes(ROOM_CODE_LENGTH)
		var code := ""
		for i in range(ROOM_CODE_LENGTH):
			var idx := int(rand_bytes[i]) % alpha_len
			code += ROOM_CODE_ALPHABET[idx]
		if not rooms.has(code):
			return code
	return "RM%d" % (_rng.randi_range(100, 999))


static func _is_valid_room_code_format(code: String) -> bool:
	if code.length() < 4 or code.length() > 8:
		return false
	for i in range(code.length()):
		var ch := code[i]
		var u := ch.unicode_at(0)
		var is_upper_alpha := (u >= 65 and u <= 90)
		var is_digit := (u >= 48 and u <= 57)
		if not is_upper_alpha and not is_digit:
			return false
	return true


func _prune_disconnected_room_members(code: String) -> void:
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	var members: Array = room.get("members", [])
	for i in range(members.size() - 1, -1, -1):
		var m_pid := int(members[i].get("peer_id", -1))
		if not connected_peers.has(m_pid):
			members.remove_at(i)
	if members.is_empty():
		rooms.erase(code)
		room_removed.emit(code)
		return
	var cur_host := int(room.get("host_peer_id", -1))
	var host_present := false
	for m in members:
		if int(m.get("peer_id", -1)) == cur_host:
			host_present = true
			break
	if not host_present:
		var new_host_peer := int(members[0]["peer_id"])
		room["host_peer_id"] = new_host_peer
		members[0]["is_host"] = true
		members[0]["ready"] = true


func _handle_create_room(peer_id: int, msg: Dictionary) -> void:
	if _is_peer_in_active_match(peer_id):
		send_error_to_peer(peer_id, "ERR_ALREADY_IN_MATCH", "Cannot create a room while in an active match")
		return

	if msg.has("name"):
		_update_authenticated_peer_name(peer_id, msg.get("name"))

	# Leave any existing queue or room first
	if _quick_match_queue.has(peer_id):
		_quick_match_queue.erase(peer_id)
		_broadcast_queue_status(quick_match_required_players)
	var old_room: String = str(connected_peers[peer_id].get("room_code", ""))
	if not old_room.is_empty():
		_remove_peer_from_room(peer_id, old_room, false)

	var requested_code := _safe_str(msg.get("custom_code", ""), "").strip_edges().to_upper()
	if not requested_code.is_empty():
		if not _is_valid_room_code_format(requested_code):
			send_error_to_peer(peer_id, "ERR_INVALID_ROOM_CODE", "Custom room code '%s' has invalid format" % requested_code)
			return
		if rooms.has(requested_code):
			send_error_to_peer(peer_id, "ERR_DUPLICATE_ROOM_CODE", "Room code '%s' is already in use" % requested_code)
			return

	var code := requested_code if not requested_code.is_empty() else _generate_unique_room_code()
	var target_humans := clampi(_safe_int(msg.get("target_humans", 2), 2), 1, NetProtocol.MAX_PLAYERS_PER_MATCH)
	var fill_ai := _safe_bool(msg.get("fill_ai", false), false)
	var max_ai := NetProtocol.MAX_PLAYERS_PER_MATCH - target_humans
	var default_ai := max_ai if fill_ai else 0
	var ai_count := clampi(_safe_int(msg.get("ai_count", default_ai), default_ai), 0, max_ai) if fill_ai else 0

	var p_name: String = connected_peers[peer_id]["name"]
	var room_data := {
		"room_code": code,
		"host_peer_id": peer_id,
		"target_humans": target_humans,
		"fill_ai": fill_ai,
		"ai_count": ai_count,
		"in_match": false,
		"session_id": "",
		"members": [
			{
				"peer_id": peer_id,
				"name": p_name,
				"ready": true,
				"is_host": true
			}
		]
	}
	rooms[code] = room_data
	connected_peers[peer_id]["room_code"] = code

	room_created.emit(code, peer_id)
	_broadcast_room_state(code)


func _handle_join_room(peer_id: int, msg: Dictionary) -> void:
	if _is_peer_in_active_match(peer_id):
		send_error_to_peer(peer_id, "ERR_ALREADY_IN_MATCH", "Cannot join a room while in an active match")
		return

	var now_ms := Time.get_ticks_msec()
	var lockout_until := int(connected_peers[peer_id].get("join_lockout_until_ms", 0))
	if now_ms < lockout_until:
		send_error_to_peer(
			peer_id,
			"ERR_RATE_LIMITED",
			"Too many invalid room code attempts. Please wait before trying again."
		)
		return

	if msg.has("name"):
		_update_authenticated_peer_name(peer_id, msg.get("name"))

	var code := _safe_str(msg.get("room_code", ""), "").strip_edges().to_upper()
	if code.is_empty() or not _is_valid_room_code_format(code) or not rooms.has(code):
		var fails := int(connected_peers[peer_id].get("failed_join_attempts", 0)) + 1
		connected_peers[peer_id]["failed_join_attempts"] = fails
		if fails >= NetProtocol.MAX_FAILED_JOIN_ATTEMPTS:
			connected_peers[peer_id]["join_lockout_until_ms"] = now_ms + NetProtocol.JOIN_LOCKOUT_MS
			send_error_to_peer(
				peer_id,
				"ERR_RATE_LIMITED",
				"Too many invalid room code attempts. Please wait before trying again."
			)
			return
		send_error_to_peer(peer_id, "ERR_INVALID_ROOM_CODE", "Room '%s' was not found" % code)
		return

	connected_peers[peer_id]["failed_join_attempts"] = 0
	_prune_disconnected_room_members(code)
	if not rooms.has(code):
		send_error_to_peer(peer_id, "ERR_INVALID_ROOM_CODE", "Room '%s' was not found" % code)
		return

	var room: Dictionary = rooms[code]
	if bool(room["in_match"]):
		send_error_to_peer(peer_id, "ERR_ROOM_IN_MATCH", "Room '%s' match is already in progress" % code)
		return

	var members: Array = room["members"]
	var peer_name: String = str(connected_peers[peer_id]["name"])
	# Check if already in this room (by peer_id or authenticated username)
	for m in members:
		if int(m["peer_id"]) == peer_id:
			_broadcast_room_state(code)
			return
		if str(m.get("name", "")) == peer_name:
			send_error_to_peer(peer_id, "ERR_DUPLICATE_IDENTITY", "Player '%s' is already in room '%s'" % [peer_name, code])
			return

	var max_humans := clampi(int(room["target_humans"]), 1, NetProtocol.MAX_PLAYERS_PER_MATCH)
	if members.size() >= NetProtocol.MAX_PLAYERS_PER_MATCH or members.size() >= max_humans:
		send_error_to_peer(peer_id, "ERR_ROOM_FULL", "Room '%s' is full (%d/%d players)" % [code, members.size(), max_humans])
		return

	# Leave any previous room or queue
	if _quick_match_queue.has(peer_id):
		_quick_match_queue.erase(peer_id)
		_broadcast_queue_status(quick_match_required_players)
	var old_room: String = str(connected_peers[peer_id].get("room_code", ""))
	if not old_room.is_empty() and old_room != code:
		_remove_peer_from_room(peer_id, old_room, false)

	members.append({
		"peer_id": peer_id,
		"name": peer_name,
		"ready": false,
		"is_host": false
	})
	connected_peers[peer_id]["room_code"] = code
	_broadcast_room_state(code)


func _remove_peer_from_room(peer_id: int, code: String, notify_leaver: bool) -> void:
	if connected_peers.has(peer_id) and connected_peers[peer_id]["room_code"] == code:
		connected_peers[peer_id]["room_code"] = ""

	if notify_leaver and connected_peers.has(peer_id):
		send_to_peer(peer_id, {
			"type": NetProtocol.S2C_ROOM_CLOSED,
			"room_code": code,
			"reason": "Left room"
		}, true)

	if not rooms.has(code):
		return

	var room: Dictionary = rooms[code]
	var members: Array = room["members"]
	for i in range(members.size() - 1, -1, -1):
		if int(members[i]["peer_id"]) == peer_id:
			members.remove_at(i)

	_prune_disconnected_room_members(code)
	if not rooms.has(code):
		return

	# If the host left or disconnected, reassign host to the next connected member
	if int(room["host_peer_id"]) == peer_id:
		var new_host_peer := int(members[0]["peer_id"])
		room["host_peer_id"] = new_host_peer
		members[0]["is_host"] = true
		members[0]["ready"] = true

	_broadcast_room_state(code)


func _handle_set_ready(peer_id: int, msg: Dictionary) -> void:
	var code: String = str(connected_peers[peer_id].get("room_code", ""))
	if code.is_empty() or not rooms.has(code):
		send_error_to_peer(peer_id, "ERR_NOT_IN_ROOM", "You are not in a room")
		return

	var room: Dictionary = rooms[code]
	var ready_val := _safe_bool(msg.get("ready", true), true)
	for m in room["members"]:
		if int(m["peer_id"]) == peer_id:
			m["ready"] = ready_val
			break
	_broadcast_room_state(code)


func _handle_configure_room(peer_id: int, msg: Dictionary) -> void:
	var code: String = str(connected_peers[peer_id].get("room_code", ""))
	if code.is_empty() or not rooms.has(code):
		send_error_to_peer(peer_id, "ERR_NOT_IN_ROOM", "You are not in a room")
		return

	var room: Dictionary = rooms[code]
	if int(room["host_peer_id"]) != peer_id:
		send_error_to_peer(peer_id, "ERR_NOT_HOST", "Only the room host can configure match settings")
		return

	if bool(room["in_match"]):
		send_error_to_peer(peer_id, "ERR_ROOM_IN_MATCH", "Cannot configure room while match is running")
		return

	var current_humans: int = (room["members"] as Array).size()
	var req_humans := _safe_int(msg.get("target_humans", room["target_humans"]), int(room["target_humans"]))
	var target_humans := clampi(req_humans, maxi(1, current_humans), NetProtocol.MAX_PLAYERS_PER_MATCH)
	var fill_ai := _safe_bool(msg.get("fill_ai", room["fill_ai"]), bool(room["fill_ai"]))
	var max_ai := NetProtocol.MAX_PLAYERS_PER_MATCH - target_humans

	var ai_count := 0
	if fill_ai:
		var req_ai := _safe_int(msg.get("ai_count", max_ai), max_ai)
		ai_count = clampi(req_ai, 0, max_ai)
		if target_humans == 1 and ai_count < 1:
			ai_count = 1

	room["target_humans"] = target_humans
	room["fill_ai"] = fill_ai and ai_count > 0
	room["ai_count"] = ai_count if fill_ai else 0
	_broadcast_room_state(code)


func _handle_start_room_match(peer_id: int) -> void:
	var code: String = str(connected_peers[peer_id].get("room_code", ""))
	if code.is_empty() or not rooms.has(code):
		send_error_to_peer(peer_id, "ERR_NOT_IN_ROOM", "You are not in a room")
		return

	_prune_disconnected_room_members(code)
	if not rooms.has(code):
		send_error_to_peer(peer_id, "ERR_NOT_IN_ROOM", "Room no longer exists")
		return

	var room: Dictionary = rooms[code]
	if int(room["host_peer_id"]) != peer_id:
		send_error_to_peer(peer_id, "ERR_NOT_HOST", "Only the room host can start the match")
		return

	if bool(room["in_match"]):
		send_error_to_peer(peer_id, "ERR_ROOM_IN_MATCH", "Match is already running")
		return

	var members: Array = room["members"]
	var human_count := members.size()
	var target_humans := int(room["target_humans"])
	var fill_ai := bool(room["fill_ai"])
	var ai_count := int(room["ai_count"]) if fill_ai else 0
	var total_participants := human_count + ai_count

	if human_count != target_humans:
		send_error_to_peer(
			peer_id,
			"ERR_WAITING_FOR_PLAYERS",
			"Room requires %d human players (%d currently joined)" % [target_humans, human_count]
		)
		return

	if total_participants < 2 or total_participants > NetProtocol.MAX_PLAYERS_PER_MATCH:
		send_error_to_peer(
			peer_id,
			"ERR_INVALID_PARTICIPANT_COUNT",
			"Match requires between 2 and 5 total participants (currently %d)" % total_participants
		)
		return

	for m in members:
		var m_pid := int(m["peer_id"])
		if _is_peer_in_active_match(m_pid):
			send_error_to_peer(
				peer_id,
				"ERR_ALREADY_IN_MATCH",
				"Player '%s' is already in an active match" % str(m["name"])
			)
			return
		if not bool(m["ready"]):
			send_error_to_peer(
				peer_id,
				"ERR_PLAYERS_NOT_READY",
				"Player '%s' is not READY" % str(m["name"])
			)
			return

	var participants: Array[Dictionary] = []
	for m in members:
		participants.append({
			"peer_id": int(m["peer_id"]),
			"name": str(m["name"]),
			"is_ai": false
		})

	if fill_ai and ai_count > 0:
		for b_idx in range(ai_count):
			if participants.size() >= NetProtocol.MAX_PLAYERS_PER_MATCH:
				break
			var b_name: String = BOT_NAMES[b_idx % BOT_NAMES.size()]
			participants.append({
				"peer_id": 0,
				"name": b_name,
				"is_ai": true
			})

	room["in_match"] = true
	var session := create_match_session(participants, {"room_code": code})
	room["session_id"] = session.session_id
	_broadcast_room_state(code)


func _handle_request_rematch(peer_id: int) -> void:
	var code: String = str(connected_peers[peer_id].get("room_code", ""))
	if code.is_empty() or not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	# Mark requesting player ready and broadcast updated room lobby state
	for m in room["members"]:
		if int(m["peer_id"]) == peer_id:
			m["ready"] = true
			break
	_broadcast_room_state(code)


func is_room_startable(room: Dictionary) -> bool:
	if bool(room.get("in_match", false)):
		return false
	var members: Array = room.get("members", [])
	var human_count := members.size()
	var target_humans := int(room.get("target_humans", 2))
	var fill_ai := bool(room.get("fill_ai", false))
	var ai_count := int(room.get("ai_count", 0)) if fill_ai else 0
	var total := human_count + ai_count
	if human_count != target_humans or total < 2 or total > NetProtocol.MAX_PLAYERS_PER_MATCH:
		return false
	for m in members:
		if not bool(m.get("ready", false)):
			return false
	return true


func _broadcast_room_state(code: String) -> void:
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	var members: Array = room["members"]
	var msg := {
		"type": NetProtocol.S2C_ROOM_STATE,
		"room_code": code,
		"host_peer_id": int(room["host_peer_id"]),
		"target_humans": int(room["target_humans"]),
		"fill_ai": bool(room["fill_ai"]),
		"ai_count": int(room["ai_count"]) if bool(room["fill_ai"]) else 0,
		"in_match": bool(room["in_match"]),
		"can_start": is_room_startable(room),
		"members": members.duplicate(true)
	}
	room_updated.emit(code, msg)
	for m in members:
		send_to_peer(int(m["peer_id"]), msg, true)


# ============================================================================
# PUBLIC MATCHMAKING QUEUE
# ============================================================================

func _prune_quick_match_queue() -> void:
	for i in range(_quick_match_queue.size() - 1, -1, -1):
		var q_pid := _quick_match_queue[i]
		if not connected_peers.has(q_pid) or not bool(connected_peers[q_pid].get("authenticated", false)) or _is_peer_in_active_match(q_pid):
			_quick_match_queue.remove_at(i)


func _broadcast_queue_status(req_humans: int) -> void:
	_prune_quick_match_queue()
	for q_pid in _quick_match_queue:
		send_to_peer(q_pid, {
			"type": NetProtocol.S2C_QUEUE_STATUS,
			"in_queue": true,
			"queued_count": _quick_match_queue.size(),
			"required_count": req_humans
		}, true)


func _handle_quick_join_request(peer_id: int, msg: Dictionary) -> void:
	if _is_peer_in_active_match(peer_id):
		send_error_to_peer(peer_id, "ERR_ALREADY_IN_MATCH", "Cannot enter matchmaking while in an active match")
		return

	if msg.has("name"):
		_update_authenticated_peer_name(peer_id, msg.get("name"))

	# Leave any private room before entering public matchmaking
	var old_room: String = str(connected_peers[peer_id].get("room_code", ""))
	if not old_room.is_empty():
		_remove_peer_from_room(peer_id, old_room, false)

	_prune_quick_match_queue()

	var fill_ai := _safe_bool(msg.get("fill_ai", quick_match_fill_with_ai), quick_match_fill_with_ai)
	var min_humans := 1 if fill_ai else 2
	var req_humans := clampi(
		_safe_int(msg.get("required_humans", quick_match_required_players), quick_match_required_players),
		min_humans,
		NetProtocol.MAX_PLAYERS_PER_MATCH
	)

	if not _quick_match_queue.has(peer_id):
		_quick_match_queue.append(peer_id)

	_broadcast_queue_status(req_humans)

	while _quick_match_queue.size() >= req_humans:
		var participants: Array[Dictionary] = []
		var popped_peers: Array[int] = []
		var seen_names: Dictionary = {}

		while not _quick_match_queue.is_empty() and participants.size() < NetProtocol.MAX_PLAYERS_PER_MATCH and participants.size() < req_humans:
			var cand_pid: int = _quick_match_queue.pop_front()
			if not connected_peers.has(cand_pid) or _is_peer_in_active_match(cand_pid):
				continue
			var cand_name: String = str(connected_peers[cand_pid]["name"])
			if seen_names.has(cand_name):
				continue
			seen_names[cand_name] = true
			popped_peers.append(cand_pid)
			participants.append({
				"peer_id": cand_pid,
				"name": cand_name,
				"is_ai": false
			})

		if participants.size() < min_humans:
			# Not enough distinct valid human players to form a match; return popped peers to front of queue
			for idx in range(popped_peers.size() - 1, -1, -1):
				var p_back := popped_peers[idx]
				if not _quick_match_queue.has(p_back):
					_quick_match_queue.push_front(p_back)
			_broadcast_queue_status(req_humans)
			break

		_broadcast_queue_status(req_humans)

		if fill_ai:
			var b_idx := 0
			while participants.size() < NetProtocol.MAX_PLAYERS_PER_MATCH:
				participants.append({
					"peer_id": 0,
					"name": BOT_NAMES[b_idx % BOT_NAMES.size()],
					"is_ai": true
				})
				b_idx += 1

		if participants.size() >= 2 and participants.size() <= NetProtocol.MAX_PLAYERS_PER_MATCH:
			create_match_session(participants)
