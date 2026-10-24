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
