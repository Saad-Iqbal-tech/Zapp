class_name NetProtocol
extends RefCounted
## Shared networking protocol constants, message types, and server-side input validation helpers.
## Used by both DedicatedServer and MultiplayerClient.

const DEFAULT_PORT: int = 7777
const DEFAULT_HOST: String = "127.0.0.1"
const MAX_CLIENTS: int = 64
const MAX_PLAYERS_PER_MATCH: int = 5
const SERVER_TICK_RATE_HZ: float = 20.0
const CLIENT_INPUT_RATE_HZ: float = 25.0

const CHANNEL_RELIABLE: int = 0
const CHANNEL_UNRELIABLE_STATE: int = 1

const MAX_CLIENT_PACKET_BYTES: int = 4096
const MAX_PACKETS_PER_SEC: int = 120
const MAX_CONTROL_MSGS_PER_SEC: int = 30
const MAX_FAILED_JOIN_ATTEMPTS: int = 5
const JOIN_LOCKOUT_MS: int = 3000

# Client -> Server message types
const C2S_HELLO: String = "c2s_hello"
const C2S_QUICK_JOIN: String = "c2s_quick_join" # Phase 1 direct match / Phase 2 public matchmaking
const C2S_CANCEL_QUEUE: String = "c2s_cancel_queue"
const C2S_CREATE_ROOM: String = "c2s_create_room"
const C2S_JOIN_ROOM: String = "c2s_join_room"
const C2S_LEAVE_ROOM: String = "c2s_leave_room"
const C2S_SET_READY: String = "c2s_set_ready"
const C2S_CONFIGURE_ROOM: String = "c2s_configure_room"
const C2S_START_ROOM_MATCH: String = "c2s_start_room_match"
const C2S_PLAYER_INPUT: String = "c2s_player_input"
const C2S_REQUEST_REMATCH: String = "c2s_request_rematch"
const C2S_GET_STATS: String = "c2s_get_stats"
const C2S_PING: String = "c2s_ping"

# Server -> Client message types
const S2C_WELCOME: String = "s2c_welcome"
const S2C_ERROR: String = "s2c_error"
const S2C_QUEUE_STATUS: String = "s2c_queue_status"
const S2C_ROOM_STATE: String = "s2c_room_state"
const S2C_ROOM_CLOSED: String = "s2c_room_closed"
const S2C_MATCH_STARTED: String = "s2c_match_started"
const S2C_STATE_SNAPSHOT: String = "s2c_state_snapshot"
const S2C_ROUND_STARTED: String = "s2c_round_started"
const S2C_LASER_RESOLUTION: String = "s2c_laser_resolution"
const S2C_PLAYER_ELIMINATED: String = "s2c_player_eliminated"
const S2C_ARENA_SHRINK_EVENT: String = "s2c_arena_shrink_event"
const S2C_PLAYER_DISCONNECTED: String = "s2c_player_disconnected"
const S2C_MATCH_ENDED: String = "s2c_match_ended"
const S2C_STATS_RESPONSE: String = "s2c_stats_response"
const S2C_PONG: String = "s2c_pong"


static func sanitize_move_vector(raw_val: Variant) -> Vector2:
	if typeof(raw_val) != TYPE_VECTOR2:
		return Vector2.ZERO
	var v: Vector2 = raw_val
	if is_nan(v.x) or is_nan(v.y) or is_inf(v.x) or is_inf(v.y):
		return Vector2.ZERO
	if v.length_squared() > 1.0:
		return v.normalized()
	return v


static func sanitize_aim_vector(raw_val: Variant, fallback: Vector2 = Vector2(0.0, 1.0)) -> Vector2:
	if typeof(raw_val) != TYPE_VECTOR2:
		return fallback
	var v: Vector2 = raw_val
	if is_nan(v.x) or is_nan(v.y) or is_inf(v.x) or is_inf(v.y):
		return fallback
	if v.length_squared() < 0.0004:
		return fallback
	return v.normalized()


static func sanitize_player_name(raw_name: Variant, fallback: String = "PLAYER") -> String:
	if typeof(raw_name) != TYPE_STRING:
		return fallback
	var cleaned := (raw_name as String).strip_edges()
	var out := ""
	for i in range(mini(cleaned.length(), 16)):
		var ch := cleaned[i]
		var code := ch.unicode_at(0)
		if (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or ch == "_" or ch == "-":
			out += ch
	if out.is_empty():
		return fallback
	return out.to_upper()


static func is_valid_port(port: int) -> bool:
	return port >= 1 and port <= 65535


static func is_valid_token(raw_token: Variant) -> bool:
	if typeof(raw_token) != TYPE_STRING:
		return false
	var t := (raw_token as String).strip_edges()
	if t.length() < 4 or t.length() > 128:
		return false
	for i in range(t.length()):
		var code := t[i].unicode_at(0)
		# Reject control characters or non-printable bytes
		if code < 33 or code > 126:
			return false
	return true


static func is_valid_host_or_ip(raw_host: String) -> bool:
	var h := raw_host.strip_edges()
	if h.is_empty() or h.length() > 253:
		return false
	if h == "localhost":
		return true
	if h.is_valid_ip_address():
		return true

	# Check if it looks like a malformed numeric IPv4 (all digits and dots, e.g. "999.999.999.999" or "127.0.0.1.5")
	var all_digits_or_dots := true
	for i in range(h.length()):
		var ch := h[i]
		var code := ch.unicode_at(0)
		var is_digit := (code >= 48 and code <= 57)
		if not is_digit and ch != ".":
			all_digits_or_dots = false
		var is_alpha := (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		if not is_digit and not is_alpha and ch != "." and ch != "-":
			return false
	if all_digits_or_dots:
		return false
	if h.begins_with(".") or h.ends_with(".") or h.begins_with("-") or h.ends_with("-") or h.find("..") != -1:
		return false
	return true


static func detect_lan_ipv4() -> String:
	var addresses := IP.get_local_addresses()
	var fallback_ipv4 := ""
	for addr in addresses:
		var a := str(addr).strip_edges()
		if not a.is_valid_ip_address() or a.find(":") != -1:
			continue
		if a == "127.0.0.1" or a.begins_with("169.254."):
			continue
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return a
		if fallback_ipv4.is_empty():
			fallback_ipv4 = a
	return fallback_ipv4 if not fallback_ipv4.is_empty() else DEFAULT_HOST
