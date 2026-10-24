class_name DedicatedServer
extends Node3D
## Authoritative headless Godot multiplayer server using ENetMultiplayerPeer + SceneMultiplayer.
## Manages connected clients, match sessions, input validation, and state broadcasting.

signal client_connected(peer_id: int)
signal client_disconnected(peer_id: int)
signal match_session_started(session_id: String, session: ServerMatchSession)
signal match_session_ended(session_id: String, summary: Dictionary)

var listen_port: int = NetProtocol.DEFAULT_PORT
var bind_address: String = "0.0.0.0"

var _peer: ENetMultiplayerPeer
var _mp: SceneMultiplayer
var _is_running: bool = false

# peer_id (int) -> { "peer_id": int, "name": String, "session_id": String, "room_code": String }
var connected_peers: Dictionary = {}

# session_id (String) -> { "session": ServerMatchSession, "container": Node, "peer_ids": Array[int] }
var active_sessions: Dictionary = {}
var _next_session_num: int = 1

# Phase 1 Quick-Match staging queue (peer_ids waiting for quick match)
var _quick_match_queue: Array[int] = []
var quick_match_required_players: int = 2
var quick_match_fill_with_ai: bool = false
var default_preparation_duration: float = 5.0
var default_shrink_interval: float = 11.0


func _ready() -> void:
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


func broadcast_to_peers(peer_ids: Array, msg: Dictionary, reliable: bool = true) -> void:
	for pid in peer_ids:
		send_to_peer(int(pid), msg, reliable)


func create_match_session(
	participants: Array[Dictionary],
	custom_config: Dictionary = {}
) -> ServerMatchSession:
	var session_id := "session_%d" % _next_session_num
	_next_session_num += 1

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
	session.room_code = str(custom_config.get("room_code", ""))
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
					"room_code": ""
				}
			else:
				connected_peers[pid]["session_id"] = session_id
			human_peers.append(pid)

	active_sessions[session_id] = {
		"session": session,
		"container": container,
		"peer_ids": human_peers
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
	match_session_ended.emit(session_id, summary)


func _cleanup_session(session_id: String) -> void:
	if not active_sessions.has(session_id):
		return
	var info: Dictionary = active_sessions[session_id]
	var peer_ids: Array = info["peer_ids"]
	for pid in peer_ids:
		if connected_peers.has(pid) and connected_peers[pid]["session_id"] == session_id:
			connected_peers[pid]["session_id"] = ""

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
	_quick_match_queue.erase(peer_id)

	if connected_peers.has(peer_id):
		var info: Dictionary = connected_peers[peer_id]
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
			var clean_name := NetProtocol.sanitize_player_name(msg.get("name", ""), "P_%d" % peer_id)
			connected_peers[peer_id]["name"] = clean_name
			send_to_peer(peer_id, {
				"type": NetProtocol.S2C_WELCOME,
				"peer_id": peer_id,
				"assigned_name": clean_name
			}, true)

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

		NetProtocol.C2S_PING:
			send_to_peer(peer_id, {
				"type": NetProtocol.S2C_PONG,
				"client_time": msg.get("client_time", 0)
			}, false)


func _handle_quick_join_request(peer_id: int, msg: Dictionary) -> void:
	if msg.has("name"):
		connected_peers[peer_id]["name"] = NetProtocol.sanitize_player_name(msg.get("name"), "P_%d" % peer_id)

	var req_humans := clampi(int(msg.get("required_humans", quick_match_required_players)), 1, NetProtocol.MAX_PLAYERS_PER_MATCH)
	var fill_ai := bool(msg.get("fill_ai", quick_match_fill_with_ai))

	if not _quick_match_queue.has(peer_id):
		_quick_match_queue.append(peer_id)

	# Notify queued players of honest queue status
	for q_pid in _quick_match_queue:
		send_to_peer(q_pid, {
			"type": NetProtocol.S2C_QUEUE_STATUS,
			"in_queue": true,
			"queued_count": _quick_match_queue.size(),
			"required_count": req_humans
		}, true)

	if _quick_match_queue.size() >= req_humans:
		var batch_peers: Array[int] = []
		var count := mini(NetProtocol.MAX_PLAYERS_PER_MATCH, _quick_match_queue.size())
		for _i in range(count):
			batch_peers.append(_quick_match_queue.pop_front())

		var participants: Array[Dictionary] = []
		for pid in batch_peers:
			if connected_peers.has(pid):
				participants.append({
					"peer_id": pid,
					"name": connected_peers[pid]["name"],
					"is_ai": false
				})

		if fill_ai:
			var bot_names: Array[String] = ["VEX", "NOVA", "SOL", "NYX", "ZED"]
			while participants.size() < NetProtocol.MAX_PLAYERS_PER_MATCH:
				var idx := participants.size()
				participants.append({
					"peer_id": 0,
					"name": bot_names[idx % bot_names.size()],
					"is_ai": true
				})

		if participants.size() >= 1:
			create_match_session(participants)
