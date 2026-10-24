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
	connected_peers.clear()
	_quick_match_queue.clear()

	if _mp:
		_mp.multiplayer_peer = null
	if _peer:
		_peer.close()
		_peer = null
	_is_running = false


func is_running() -> bool:
	return _is_running


func _process(_delta: float) -> void:
	if _is_running and _mp and _mp.has_multiplayer_peer():
		_mp.poll()


func send_to_peer(peer_id: int, msg: Dictionary, reliable: bool = true) -> void:
	if not _is_running or not _mp or not connected_peers.has(peer_id):
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

	var human_peers: Array[int] = []
	for p in participants:
		var pid := int(p.get("peer_id", 0))
		if pid > 0:
			if not connected_peers.has(pid):
				connected_peers[pid] = {
					"peer_id": pid,
					"name": str(p.get("name", "PLAYER_%d" % pid)),
					"session_id": session_id,
					"room_code": room_code
				}
			else:
				connected_peers[pid]["session_id"] = session_id
			human_peers.append(pid)

	active_sessions[session_id] = {
		"session": session,
		"container": container,
		"peer_ids": human_peers,
		"room_code": room_code
	}

	session.snapshot_generated.connect(_on_session_snapshot_generated)
	session.reliable_event_generated.connect(_on_session_reliable_event_generated)
	session.session_match_ended.connect(_on_session_match_ended)

	session.start_authoritative_match(participants)
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
		var peer_ids: Array = active_sessions[session_id]["peer_ids"]
		for pid in peer_ids:
			_send_stats_to_peer(int(pid))

		var r_code: String = str(active_sessions[session_id].get("room_code", ""))
		if not r_code.is_empty() and rooms.has(r_code):
			var room: Dictionary = rooms[r_code]
			room["in_match"] = false
			room["session_id"] = ""
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
		"session_id": "",
		"room_code": ""
	}
	send_to_peer(peer_id, {
		"type": NetProtocol.S2C_WELCOME,
		"peer_id": peer_id,
		"assigned_name": default_name
	}, true)
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

	client_disconnected.emit(peer_id)


func _on_peer_packet(peer_id: int, packet: PackedByteArray) -> void:
	if not connected_peers.has(peer_id):
		return
	var decoded: Variant = bytes_to_var(packet)
	if typeof(decoded) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = decoded
	var msg_type: String = str(msg.get("type", ""))

	match msg_type:
		NetProtocol.C2S_HELLO:
			var req_name := str(msg.get("name", "P_%d" % peer_id))
			var raw_token := str(msg.get("token", "token_%d" % peer_id))
			var profile := persistence.authenticate_or_register_player(req_name, raw_token, peer_id) if persistence else {"username": NetProtocol.sanitize_player_name(req_name, "P_%d" % peer_id)}
			var clean_name := str(profile.get("username", "P_%d" % peer_id))
			connected_peers[peer_id]["name"] = clean_name
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
						int(msg.get("seq", 0))
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
				"client_time": msg.get("client_time", 0)
			}, false)

		_:
			if msg_type.find("stat") != -1 or msg_type.find("win") != -1 or msg_type.find("score") != -1:
				send_error_to_peer(
					peer_id,
					"ERR_FORBIDDEN_CLIENT_STATS",
					"Statistics are server-authoritative and cannot be modified by clients"
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
	for _attempt in range(128):
		var code := ""
		for _i in range(ROOM_CODE_LENGTH):
			var idx := _rng.randi_range(0, ROOM_CODE_ALPHABET.length() - 1)
			code += ROOM_CODE_ALPHABET[idx]
		if not rooms.has(code):
			return code
	return "RM%d" % (_rng.randi_range(100, 999))


func _handle_create_room(peer_id: int, msg: Dictionary) -> void:
	if msg.has("name"):
		connected_peers[peer_id]["name"] = NetProtocol.sanitize_player_name(msg.get("name"), connected_peers[peer_id]["name"])

	# Leave any existing queue or room first
	_quick_match_queue.erase(peer_id)
	var old_room: String = str(connected_peers[peer_id].get("room_code", ""))
	if not old_room.is_empty():
		_remove_peer_from_room(peer_id, old_room, false)

	var requested_code := str(msg.get("custom_code", "")).strip_edges().to_upper()
	if not requested_code.is_empty() and rooms.has(requested_code):
		send_error_to_peer(peer_id, "ERR_DUPLICATE_ROOM_CODE", "Room code '%s' is already in use" % requested_code)
		return

	var code := requested_code if not requested_code.is_empty() else _generate_unique_room_code()
	var target_humans := clampi(int(msg.get("target_humans", 2)), 1, NetProtocol.MAX_PLAYERS_PER_MATCH)
	var fill_ai := bool(msg.get("fill_ai", false))
	var max_ai := NetProtocol.MAX_PLAYERS_PER_MATCH - target_humans
	var default_ai := max_ai if fill_ai else 0
	var ai_count := clampi(int(msg.get("ai_count", default_ai)), 0, max_ai) if fill_ai else 0

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
	if msg.has("name"):
		connected_peers[peer_id]["name"] = NetProtocol.sanitize_player_name(msg.get("name"), connected_peers[peer_id]["name"])

	var code := str(msg.get("room_code", "")).strip_edges().to_upper()
	if code.is_empty() or not rooms.has(code):
		send_error_to_peer(peer_id, "ERR_INVALID_ROOM_CODE", "Room '%s' was not found" % code)
		return

	var room: Dictionary = rooms[code]
	if bool(room["in_match"]):
		send_error_to_peer(peer_id, "ERR_ROOM_IN_MATCH", "Room '%s' match is already in progress" % code)
		return

	var members: Array = room["members"]
	# Check if already in this room
	for m in members:
		if int(m["peer_id"]) == peer_id:
			_broadcast_room_state(code)
			return

	var max_humans := int(room["target_humans"])
	if members.size() >= NetProtocol.MAX_PLAYERS_PER_MATCH or members.size() >= max_humans:
		send_error_to_peer(peer_id, "ERR_ROOM_FULL", "Room '%s' is full (%d/%d players)" % [code, members.size(), max_humans])
		return

	# Leave any previous room or queue
	_quick_match_queue.erase(peer_id)
	var old_room: String = str(connected_peers[peer_id].get("room_code", ""))
	if not old_room.is_empty() and old_room != code:
		_remove_peer_from_room(peer_id, old_room, false)

	members.append({
		"peer_id": peer_id,
		"name": connected_peers[peer_id]["name"],
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

	if members.is_empty():
		rooms.erase(code)
		room_removed.emit(code)
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
	var ready_val := bool(msg.get("ready", true))
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
	var req_humans := int(msg.get("target_humans", room["target_humans"]))
	var target_humans := clampi(req_humans, maxi(1, current_humans), NetProtocol.MAX_PLAYERS_PER_MATCH)
	var fill_ai := bool(msg.get("fill_ai", room["fill_ai"]))
	var max_ai := NetProtocol.MAX_PLAYERS_PER_MATCH - target_humans

	var ai_count := 0
	if fill_ai:
		var req_ai := int(msg.get("ai_count", max_ai))
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

func _broadcast_queue_status(req_humans: int) -> void:
	for q_pid in _quick_match_queue:
		send_to_peer(q_pid, {
			"type": NetProtocol.S2C_QUEUE_STATUS,
			"in_queue": true,
			"queued_count": _quick_match_queue.size(),
			"required_count": req_humans
		}, true)


func _handle_quick_join_request(peer_id: int, msg: Dictionary) -> void:
	if msg.has("name"):
		connected_peers[peer_id]["name"] = NetProtocol.sanitize_player_name(msg.get("name"), "P_%d" % peer_id)

	# Leave any private room before entering public matchmaking
	var old_room: String = str(connected_peers[peer_id].get("room_code", ""))
	if not old_room.is_empty():
		_remove_peer_from_room(peer_id, old_room, false)

	var req_humans := clampi(int(msg.get("required_humans", quick_match_required_players)), 1, NetProtocol.MAX_PLAYERS_PER_MATCH)
	var fill_ai := bool(msg.get("fill_ai", quick_match_fill_with_ai))

	if not _quick_match_queue.has(peer_id):
		_quick_match_queue.append(peer_id)

	_broadcast_queue_status(req_humans)

	if _quick_match_queue.size() >= req_humans:
		var batch_peers: Array[int] = []
		var count := mini(NetProtocol.MAX_PLAYERS_PER_MATCH, _quick_match_queue.size())
		for _i in range(count):
			batch_peers.append(_quick_match_queue.pop_front())

		_broadcast_queue_status(req_humans)

		var participants: Array[Dictionary] = []
		for pid in batch_peers:
			if connected_peers.has(pid):
				participants.append({
					"peer_id": pid,
					"name": connected_peers[pid]["name"],
					"is_ai": false
				})

		if fill_ai:
			var b_idx := 0
			while participants.size() < NetProtocol.MAX_PLAYERS_PER_MATCH:
				participants.append({
					"peer_id": 0,
					"name": BOT_NAMES[b_idx % BOT_NAMES.size()],
					"is_ai": true
				})
				b_idx += 1

		if participants.size() >= 2:
			create_match_session(participants)
