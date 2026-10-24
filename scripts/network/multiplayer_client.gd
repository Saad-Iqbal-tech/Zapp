class_name MultiplayerClient
extends Node
## Multiplayer client using ENetMultiplayerPeer + SceneMultiplayer.
## Connects to DedicatedServer, transmits touch movement/aiming inputs,
## and receives authoritative match state, round timers, laser resolutions, and lobby updates.

signal connected_to_game_server(peer_id: int, assigned_name: String)
signal connection_error(reason: String)
signal disconnected_from_game_server(reason: String)
signal queue_status_updated(in_queue: bool, queued_count: int, required_count: int)
signal room_state_updated(room_msg: Dictionary)
signal room_closed(reason: String)
signal server_error_received(code: String, message: String)
signal authoritative_match_started(start_msg: Dictionary)
signal authoritative_snapshot_received(snapshot_msg: Dictionary)
signal authoritative_round_started(round_msg: Dictionary)
signal authoritative_laser_resolution(res_msg: Dictionary)
signal authoritative_player_eliminated(elim_msg: Dictionary)
signal authoritative_arena_shrink_event(shrink_msg: Dictionary)
signal authoritative_player_disconnected(disc_msg: Dictionary)
signal authoritative_match_ended(end_msg: Dictionary)
signal stats_response_received(stats_msg: Dictionary)

enum ConnState {
	DISCONNECTED,
	CONNECTING,
	CONNECTED
}

var server_host: String = NetProtocol.DEFAULT_HOST
var server_port: int = NetProtocol.DEFAULT_PORT
var player_name: String = "STRIKER_01"
var account_token: String = ""
var connect_timeout_sec: float = 6.0

var conn_state: ConnState = ConnState.DISCONNECTED
var has_welcome: bool = false
var local_peer_id: int = 0
var local_slot_id: int = -1
var current_session_id: String = ""
var current_room_code: String = ""
var latest_room_state: Dictionary = {}
var latest_profile: Dictionary = {}
var latest_stats_response: Dictionary = {}
var in_matchmaking_queue: bool = false
var queued_players_count: int = 0
var last_error_code: String = ""
var last_error_message: String = ""

var _peer: ENetMultiplayerPeer
var _mp: SceneMultiplayer
var _connect_elapsed: float = 0.0
var _input_send_accum: float = 0.0
var _input_seq: int = 0
var _pending_move_input: Vector2 = Vector2.ZERO
var _pending_aim_input: Vector2 = Vector2(0.0, 1.0)
var _in_active_match: bool = false


func _ready() -> void:
	if account_token.is_empty():
		account_token = _load_or_generate_account_token()
	_mp = SceneMultiplayer.new()
	_mp.root_path = get_path()
	_mp.connected_to_server.connect(_on_connected_to_server)
	_mp.connection_failed.connect(_on_connection_failed)
	_mp.server_disconnected.connect(_on_server_disconnected)
	_mp.peer_packet.connect(_on_peer_packet)


func _load_or_generate_account_token() -> String:
	var cfg_path := "user://client_account.cfg"
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) == OK:
		var saved_tok := str(cfg.get_value("account", "token", ""))
		var saved_name := str(cfg.get_value("account", "username", ""))
		if not saved_name.is_empty():
			player_name = NetProtocol.sanitize_player_name(saved_name, player_name)
		if not saved_tok.is_empty():
			return saved_tok

	var crypto := Crypto.new()
	var new_tok := crypto.generate_random_bytes(16).hex_encode()
	cfg.set_value("account", "token", new_tok)
	cfg.set_value("account", "username", player_name)
	cfg.save(cfg_path)
	return new_tok


func connect_to_server(
	host: String = NetProtocol.DEFAULT_HOST,
	port: int = NetProtocol.DEFAULT_PORT,
	requested_name: String = ""
) -> Error:
	disconnect_from_server()

	server_host = host.strip_edges() if not host.strip_edges().is_empty() else NetProtocol.DEFAULT_HOST
	server_port = port if port > 0 else NetProtocol.DEFAULT_PORT
	if not requested_name.strip_edges().is_empty():
		player_name = NetProtocol.sanitize_player_name(requested_name, player_name)

	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(server_host, server_port, 2)
	if err != OK:
		conn_state = ConnState.DISCONNECTED
		connection_error.emit("Could not create client for %s:%d (error %d)" % [server_host, server_port, err])
		return err

	_mp.multiplayer_peer = _peer
	conn_state = ConnState.CONNECTING
	_connect_elapsed = 0.0
	return OK


func disconnect_from_server() -> void:
	_in_active_match = false
	has_welcome = false
	in_matchmaking_queue = false
	queued_players_count = 0
	local_peer_id = 0
	local_slot_id = -1
	current_session_id = ""
	current_room_code = ""
	latest_room_state.clear()
	conn_state = ConnState.DISCONNECTED
	if _mp:
		_mp.multiplayer_peer = null
	if _peer:
		_peer.close()
		_peer = null


func is_connected_to_server() -> bool:
	return conn_state == ConnState.CONNECTED and has_welcome


func set_local_input(move_vec: Vector2, aim_vec: Vector2) -> void:
	_pending_move_input = NetProtocol.sanitize_move_vector(move_vec)
	_pending_aim_input = NetProtocol.sanitize_aim_vector(aim_vec, _pending_aim_input)


func send_player_input_now(move_vec: Vector2, aim_vec: Vector2) -> void:
	set_local_input(move_vec, aim_vec)
	_transmit_current_input()


func request_quick_join(required_humans: int = 2, fill_ai: bool = false) -> void:
	send_message({
		"type": NetProtocol.C2S_QUICK_JOIN,
		"name": player_name,
		"required_humans": required_humans,
		"fill_ai": fill_ai
	}, true)


func cancel_queue() -> void:
	send_message({"type": NetProtocol.C2S_CANCEL_QUEUE}, true)


func create_private_room(
	target_humans: int = 2,
	fill_ai: bool = false,
	ai_count: int = 0,
	custom_code: String = ""
) -> void:
	var msg := {
		"type": NetProtocol.C2S_CREATE_ROOM,
		"name": player_name,
		"target_humans": target_humans,
		"fill_ai": fill_ai,
		"ai_count": ai_count
	}
	if not custom_code.is_empty():
		msg["custom_code"] = custom_code
	send_message(msg, true)


func join_private_room(room_code: String) -> void:
	send_message({
		"type": NetProtocol.C2S_JOIN_ROOM,
		"name": player_name,
		"room_code": room_code.strip_edges().to_upper()
	}, true)


func leave_private_room() -> void:
	send_message({"type": NetProtocol.C2S_LEAVE_ROOM}, true)
	current_room_code = ""
	latest_room_state.clear()


func set_room_ready(ready_flag: bool) -> void:
	send_message({
		"type": NetProtocol.C2S_SET_READY,
		"ready": ready_flag
	}, true)


func configure_private_room(target_humans: int, fill_ai: bool, ai_count: int) -> void:
	send_message({
		"type": NetProtocol.C2S_CONFIGURE_ROOM,
		"target_humans": target_humans,
		"fill_ai": fill_ai,
		"ai_count": ai_count
	}, true)


func start_private_room_match() -> void:
	send_message({"type": NetProtocol.C2S_START_ROOM_MATCH}, true)


func request_rematch() -> void:
	send_message({"type": NetProtocol.C2S_REQUEST_REMATCH}, true)


func request_stats() -> void:
	send_message({"type": NetProtocol.C2S_GET_STATS}, true)


func is_room_host() -> bool:
	return not current_room_code.is_empty() and int(latest_room_state.get("host_peer_id", -1)) == local_peer_id


func send_message(msg: Dictionary, reliable: bool = true) -> void:
	if conn_state != ConnState.CONNECTED or not _mp or not _mp.has_multiplayer_peer():
		return
	var mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
	var channel := NetProtocol.CHANNEL_RELIABLE if reliable else NetProtocol.CHANNEL_UNRELIABLE_STATE
	var raw := var_to_bytes(msg)
	_mp.send_bytes(raw, 1, mode, channel)


func _process(delta: float) -> void:
	if conn_state == ConnState.DISCONNECTED or not _mp:
		return

	if _mp.has_multiplayer_peer():
		_mp.poll()

	if conn_state == ConnState.CONNECTING:
		_connect_elapsed += delta
		if _connect_elapsed >= connect_timeout_sec:
			disconnect_from_server()
			connection_error.emit("Connection timed out (%s:%d)" % [server_host, server_port])
		return

	if conn_state == ConnState.CONNECTED and _in_active_match:
		_input_send_accum += delta
		var interval := 1.0 / NetProtocol.CLIENT_INPUT_RATE_HZ
		if _input_send_accum >= interval:
			_input_send_accum = fmod(_input_send_accum, interval)
			_transmit_current_input()


func _transmit_current_input() -> void:
	if conn_state != ConnState.CONNECTED:
		return
	_input_seq += 1
	send_message({
		"type": NetProtocol.C2S_PLAYER_INPUT,
		"seq": _input_seq,
		"move": _pending_move_input,
		"aim": _pending_aim_input
	}, false)


func _on_connected_to_server() -> void:
	conn_state = ConnState.CONNECTED
	local_peer_id = _mp.get_unique_id()
	send_message({
		"type": NetProtocol.C2S_HELLO,
		"name": player_name,
		"token": account_token
	}, true)


func _on_connection_failed() -> void:
	disconnect_from_server()
	connection_error.emit("Failed to connect to server %s:%d" % [server_host, server_port])


func _on_server_disconnected() -> void:
	disconnect_from_server()
	disconnected_from_game_server.emit("Disconnected from server")


func _on_peer_packet(peer_id: int, packet: PackedByteArray) -> void:
	if peer_id != 1:
		# Ignore packets not coming from the authoritative server (peer 1)
		return
	var decoded: Variant = bytes_to_var(packet)
	if typeof(decoded) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = decoded
	var msg_type: String = str(msg.get("type", ""))

	match msg_type:
		NetProtocol.S2C_WELCOME:
			has_welcome = true
			local_peer_id = int(msg.get("peer_id", local_peer_id))
			var assigned_name := str(msg.get("assigned_name", player_name))
			player_name = assigned_name
			if msg.has("profile") and typeof(msg["profile"]) == TYPE_DICTIONARY:
				latest_profile = msg["profile"]
			connected_to_game_server.emit(local_peer_id, assigned_name)

		NetProtocol.S2C_ERROR:
			last_error_code = str(msg.get("code", "ERR"))
			last_error_message = str(msg.get("message", "Server error"))
			server_error_received.emit(last_error_code, last_error_message)

		NetProtocol.S2C_QUEUE_STATUS:
			in_matchmaking_queue = bool(msg.get("in_queue", false))
			queued_players_count = int(msg.get("queued_count", 0))
			queue_status_updated.emit(
				in_matchmaking_queue,
				queued_players_count,
				int(msg.get("required_count", 2))
			)

		NetProtocol.S2C_ROOM_STATE:
			current_room_code = str(msg.get("room_code", current_room_code))
			latest_room_state = msg.duplicate(true)
			room_state_updated.emit(msg)

		NetProtocol.S2C_ROOM_CLOSED:
			current_room_code = ""
			latest_room_state.clear()
			room_closed.emit(str(msg.get("reason", "Room closed")))

		NetProtocol.S2C_MATCH_STARTED:
			_in_active_match = true
			_input_seq = 0
			current_session_id = str(msg.get("session_id", ""))
			local_slot_id = -1
			var slots: Array = msg.get("slots", [])
			for s in slots:
				if int(s.get("peer_id", -1)) == local_peer_id:
					local_slot_id = int(s.get("slot_id", -1))
					break
			authoritative_match_started.emit(msg)

		NetProtocol.S2C_STATE_SNAPSHOT:
			authoritative_snapshot_received.emit(msg)

		NetProtocol.S2C_ROUND_STARTED:
			authoritative_round_started.emit(msg)

		NetProtocol.S2C_LASER_RESOLUTION:
			authoritative_laser_resolution.emit(msg)

		NetProtocol.S2C_PLAYER_ELIMINATED:
			authoritative_player_eliminated.emit(msg)

		NetProtocol.S2C_ARENA_SHRINK_EVENT:
			authoritative_arena_shrink_event.emit(msg)

		NetProtocol.S2C_PLAYER_DISCONNECTED:
			authoritative_player_disconnected.emit(msg)

		NetProtocol.S2C_MATCH_ENDED:
			_in_active_match = false
			authoritative_match_ended.emit(msg)

		NetProtocol.S2C_STATS_RESPONSE:
			latest_stats_response = msg.duplicate(true)
			if msg.has("profile") and typeof(msg["profile"]) == TYPE_DICTIONARY:
				latest_profile = msg["profile"]
			stats_response_received.emit(msg)
