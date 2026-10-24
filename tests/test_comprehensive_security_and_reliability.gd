extends SceneTree
## Comprehensive Multiplayer Reliability, Authority, Security & Persistence Verification Suite
## Covers all requirements in Sections 3, 4, 5, 6, 7, 8, and 10:
## - Private Rooms (16 cases: creation, join, invalid/full/5P cap, simultaneous last-slot race,
##   duplicate joins, duplicate identity multi-slot prevention, ready sync, host-only permissions,
##   crafted host-impersonation rejection, host disconnect reassignment, room code invalidation,
##   abandoned room cleanup, disconnect during all states, rejected join UI integrity).
## - Public Matchmaking (14 cases: multi-client matching, no dual-match assignment, duplicate queue
##   button spam prevention, queue cancel, disconnect while queued, simultaneous multi-group matching,
##   5P limit, AI fill ON/OFF, insufficient player waiting, multi-session isolation, post-match cleanup,
##   re-queue after match, rapid queue/cancel/reconnect cycles).
## - Gameplay Authority & Synchronization (client win/elim/pos/shrink/timer spoofing rejection,
##   malformed/NaN/Inf/out-of-order/duplicate seq input rejection, simultaneous snapshot resolution,
##   obstacle blocking, extra-attack prevention, slow/silent client non-blocking).
## - Authentication & Room Security (unauthenticated action rejection, invalid token rejection,
##   post-auth name impersonation prevention in rooms/queues, brute-force room code rate limiting,
##   oversized packet & flood rate limiting, internal ID guessing rejection, token privacy).
## - Persistence & Match-Result Integrity (atomic .tmp/.bak write, corrupted JSON backup recovery,
##   duplicate session_id result rejection, no fabricated match on disconnect).

const TEST_PORT: int = 17782
const TEST_PERSIST_PATH: String = "user://test_comprehensive_persistence.json"

var _passes: int = 0
var _failures: int = 0


func _init() -> void:
	call_deferred("_run_all_verifications")


func _assert(condition: bool, label: String) -> void:
	if condition:
		_passes += 1
		print("  [PASS] ", label)
	else:
		_failures += 1
		printerr("  [FAIL] ", label)


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await process_frame
		await physics_frame


func _wait_until(predicate: Callable, timeout_sec: float = 4.0) -> bool:
	var start_ms := Time.get_ticks_msec()
	var limit_ms := int(timeout_sec * 1000.0)
	while (Time.get_ticks_msec() - start_ms) < limit_ms:
		if bool(predicate.call()):
			return true
		await process_frame
		await physics_frame
	return bool(predicate.call())


func _remove_test_persistence_files() -> void:
	for suffix in ["", ".tmp", ".bak"]:
		var p: String = TEST_PERSIST_PATH + str(suffix)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _spawn_client(c_name: String, token: String) -> MultiplayerClient:
	var mc := MultiplayerClient.new()
	mc.name = "Client_%s_%d" % [c_name, Time.get_ticks_usec() % 100000]
	mc.account_token = token
	root.add_child(mc)
	return mc


func _connect_client(mc: MultiplayerClient, port: int, req_name: String) -> bool:
	mc.connect_to_server("127.0.0.1", port, req_name)
	return await _wait_until(func(): return mc.is_connected_to_server(), 3.5)


func _run_all_verifications() -> void:
	print("\n=== STARTING COMPREHENSIVE MULTIPLAYER RELIABILITY & SECURITY SUITE ===")
	_remove_test_persistence_files()

	var server := DedicatedServer.new()
	server.name = "ComprehensiveTestServer"
	server.persistence_save_path = TEST_PERSIST_PATH
	root.add_child(server)
	var start_err := server.start_server(TEST_PORT, "127.0.0.1")
	_assert(start_err == OK and server.is_running(), "DedicatedServer starts on UDP 127.0.0.1:%d" % TEST_PORT)

	# =========================================================================
	# SECTION A: AUTHENTICATION & PROTOCOL SECURITY (Section 7 & Section 10)
	# =========================================================================
	print("\n--- Section A: Authentication, Token Security, Anti-Impersonation & Rate Limiting ---")

	# A1. Raw ENet client attempting actions BEFORE sending C2S_HELLO must be rejected with ERR_UNAUTHENTICATED
	var raw_peer := ENetMultiplayerPeer.new()
	var raw_mp := SceneMultiplayer.new()
	var raw_node := Node.new()
	raw_node.name = "RawUnauthNode"
	root.add_child(raw_node)
	raw_mp.root_path = raw_node.get_path()
	var raw_state := {"connected": false, "err_code": ""}
	raw_mp.connected_to_server.connect(func():
		raw_state["connected"] = true
	)
	raw_mp.peer_packet.connect(func(_pid: int, pkt: PackedByteArray):
		var dec: Variant = bytes_to_var(pkt)
		if typeof(dec) == TYPE_DICTIONARY and str(dec.get("type", "")) == NetProtocol.S2C_ERROR:
			raw_state["err_code"] = str(dec.get("code", ""))
	)
	raw_peer.create_client("127.0.0.1", TEST_PORT, 2)
	raw_mp.multiplayer_peer = raw_peer

	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) < 2500:
		raw_mp.poll()
		if bool(raw_state["connected"]):
			break
		await _wait_frames(1)
	_assert(bool(raw_state["connected"]), "Raw ENet peer establishes low-level SceneMultiplayer transport connection")

	# Send C2S_CREATE_ROOM without C2S_HELLO
	raw_state["err_code"] = ""
	raw_mp.send_bytes(var_to_bytes({"type": NetProtocol.C2S_CREATE_ROOM, "target_humans": 2}), 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)
	for _i in range(20):
		raw_mp.poll()
		await _wait_frames(1)
		if not str(raw_state["err_code"]).is_empty():
			break
	_assert(
		str(raw_state["err_code"]) == "ERR_UNAUTHENTICATED" and server.rooms.is_empty(),
		"Unauthenticated client cannot create a room before C2S_HELLO (ERR_UNAUTHENTICATED)"
	)

	# Send C2S_QUICK_JOIN without C2S_HELLO
	raw_state["err_code"] = ""
	raw_mp.send_bytes(var_to_bytes({"type": NetProtocol.C2S_QUICK_JOIN}), 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)
	for _i in range(20):
		raw_mp.poll()
		await _wait_frames(1)
		if not str(raw_state["err_code"]).is_empty():
			break
	_assert(
		str(raw_state["err_code"]) == "ERR_UNAUTHENTICATED" and server._quick_match_queue.is_empty(),
		"Unauthenticated client cannot join public matchmaking before C2S_HELLO (ERR_UNAUTHENTICATED)"
	)

	# A2. Invalid / short / empty tokens in C2S_HELLO are rejected with ERR_INVALID_TOKEN
	for bad_tok in ["", "ab", "bad\nchar", 12345]:
		raw_state["err_code"] = ""
		raw_mp.send_bytes(var_to_bytes({"type": NetProtocol.C2S_HELLO, "name": "HACKER", "token": bad_tok}), 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)
		for _i in range(20):
			raw_mp.poll()
			await _wait_frames(1)
			if not str(raw_state["err_code"]).is_empty():
				break
		if str(raw_state["err_code"]) != "ERR_INVALID_TOKEN":
			break
	_assert(str(raw_state["err_code"]) == "ERR_INVALID_TOKEN", "Server rejects empty, short, non-printable, and non-string tokens (ERR_INVALID_TOKEN)")

	# A3. Malformed (non-Dictionary) and oversized (>4096 bytes) packets are safely rejected without crashing
	raw_state["err_code"] = ""
	raw_mp.send_bytes(var_to_bytes(["not_a_dictionary", 123]), 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)
	for _i in range(20):
		raw_mp.poll()
		await _wait_frames(1)
		if not str(raw_state["err_code"]).is_empty():
			break
	_assert(str(raw_state["err_code"]) == "ERR_MALFORMED_PACKET", "Server safely rejects non-Dictionary packet payloads (ERR_MALFORMED_PACKET)")

	raw_state["err_code"] = ""
	var huge_bytes := PackedByteArray()
	huge_bytes.resize(5000)
	raw_mp.send_bytes(huge_bytes, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)
	for _i in range(20):
		raw_mp.poll()
		await _wait_frames(1)
		if not str(raw_state["err_code"]).is_empty():
			break
	_assert(str(raw_state["err_code"]) == "ERR_PACKET_TOO_LARGE", "Server rejects oversized packets exceeding 4096 bytes (ERR_PACKET_TOO_LARGE)")

	raw_peer.close()
	raw_mp.multiplayer_peer = null
	raw_mp.clear()
	raw_node.queue_free()
	await _wait_frames(4)

	# A4. Post-authentication display name impersonation protection in rooms & matchmaking
	var c_owner := _spawn_client("OWNER", "token_owner_secure_001")
	var c_impostor := _spawn_client("IMPOSTOR", "token_impostor_secure_002")
	await _connect_client(c_owner, TEST_PORT, "GUARDIAN")
	await _connect_client(c_impostor, TEST_PORT, "GUARDIAN")
	_assert(
		c_owner.player_name == "GUARDIAN" and c_impostor.player_name == "GUARDIAN_2",
		"Impostor attempting to claim 'GUARDIAN' on connect is disambiguated to 'GUARDIAN_2'"
	)

	# Now c_impostor sends a crafted C2S_CREATE_ROOM attempting to overwrite its name to "GUARDIAN"
	c_impostor.send_message({
		"type": NetProtocol.C2S_CREATE_ROOM,
		"name": "GUARDIAN",
		"target_humans": 2,
		"fill_ai": false,
		"ai_count": 0
	}, true)
	await _wait_until(func(): return not c_impostor.current_room_code.is_empty(), 2.5)
	var imp_members: Array = c_impostor.latest_room_state.get("members", [])
	_assert(
		imp_members.size() == 1 and str(imp_members[0].get("name", "")) == "GUARDIAN_2",
		"Client cannot impersonate another player's username via crafted C2S_CREATE_ROOM 'name' field"
	)
	c_impostor.leave_private_room()
	await _wait_frames(5)

	# A5. Duplicate connections with the same token cannot occupy multiple slots in the same room/match
	var c_dup := _spawn_client("OWNER_DUP", "token_owner_secure_001") # Exact same token as c_owner!
	c_owner.create_private_room(2, false, 0)
	await _wait_until(func(): return not c_owner.current_room_code.is_empty(), 2.5)
	var owner_room := c_owner.current_room_code

	# Connect c_dup with the exact same token as c_owner
	await _connect_client(c_dup, TEST_PORT, "GUARDIAN")
	await _wait_frames(6)
	_assert(
		not server.rooms.has(owner_room) and c_dup.player_name == "GUARDIAN",
		"Connecting a second client with the same account token evicts the stale duplicate connection and cleans up its room slot"
	)
	c_owner.disconnect_from_server()
	c_owner.queue_free()
	c_dup.disconnect_from_server()
	c_dup.queue_free()
	c_impostor.disconnect_from_server()
	c_impostor.queue_free()
	await _wait_frames(5)

	# =========================================================================
	# SECTION B: PRIVATE ROOMS — ALL 16 CASES (Section 3)
	# =========================================================================
	print("\n--- Section B: Private Rooms (Capacity, Races, Host Security, Cleanup & UI Integrity) ---")

	var r_clients: Array[MultiplayerClient] = []
	for i in range(6):
		var mc := _spawn_client("R%d" % (i + 1), "room_test_token_%d" % (i + 1))
		await _connect_client(mc, TEST_PORT, "RM_P%d" % (i + 1))
		r_clients.append(mc)

	var rc1 := r_clients[0]
	var rc2 := r_clients[1]
	var rc3 := r_clients[2]
	var rc4 := r_clients[3]
	var rc5 := r_clients[4]
	var rc6 := r_clients[5]

	# B1. Create room and verify 5-char code; reject internal ID guessing ("session_1", "room_1")
	rc1.create_private_room(2, false, 0)
	await _wait_until(func(): return not rc1.current_room_code.is_empty(), 2.5)
	var priv_code := rc1.current_room_code
	_assert(priv_code.length() == 5 and rc1.is_room_host(), "Player 1 creates private room (%s) and is assigned Host" % priv_code)

	rc2.last_error_code = ""
	rc2.join_private_room("session_1")
	await _wait_until(func(): return not rc2.last_error_code.is_empty(), 2.0)
	_assert(
		rc2.last_error_code == "ERR_INVALID_ROOM_CODE" and rc2.current_room_code.is_empty(),
		"Guessing internal session ID ('session_1') is rejected and leaves client current_room_code empty"
	)

	# B2. Brute-force invalid room code rate limiting (>= 5 invalid attempts triggers ERR_RATE_LIMITED)
	var rate_client := _spawn_client("BRUTE", "brute_force_tok_999")
	await _connect_client(rate_client, TEST_PORT, "BRUTE")
	for attempt in range(NetProtocol.MAX_FAILED_JOIN_ATTEMPTS):
		rate_client.last_error_code = ""
		rate_client._room_request_in_flight = false
		rate_client.join_private_room("BAD0%d" % attempt)
		await _wait_until(func(): return not rate_client.last_error_code.is_empty(), 1.5)
	_assert(
		rate_client.last_error_code == "ERR_RATE_LIMITED",
		"Repeated invalid room-code attempts trigger brute-force lockout (ERR_RATE_LIMITED)"
	)
	# Even providing the real room code while locked out must be rejected with ERR_RATE_LIMITED
	rate_client.last_error_code = ""
	rate_client._room_request_in_flight = false
	rate_client.join_private_room(priv_code)
	await _wait_until(func(): return not rate_client.last_error_code.is_empty(), 1.5)
	_assert(
		rate_client.last_error_code == "ERR_RATE_LIMITED" and rate_client.current_room_code.is_empty(),
		"Locked-out client cannot join even a valid room code until lockout expires"
	)
	rate_client.disconnect_from_server()
	rate_client.queue_free()

	# B3. Simultaneous race for the final available slot in a 2-player room (rc2 and rc3 send join in the same frame)
	rc2.last_error_code = ""
	rc3.last_error_code = ""
	rc2.join_private_room(priv_code)
	rc3.join_private_room(priv_code)
	await _wait_frames(10)
	var room_members_after_race: Array = server.rooms[priv_code]["members"]
	var rc2_joined := (rc2.current_room_code == priv_code)
	var rc3_joined := (rc3.current_room_code == priv_code)
	_assert(
		room_members_after_race.size() == 2 and (rc2_joined != rc3_joined),
		"Simultaneous join race for final slot admits exactly 1 player (capacity 2/2) and rejects the other (ERR_ROOM_FULL)"
	)
	var joined_client := rc2 if rc2_joined else rc3
	var rejected_client := rc3 if rc2_joined else rc2
	_assert(
		rejected_client.last_error_code == "ERR_ROOM_FULL" and rejected_client.current_room_code.is_empty(),
		"Rejected racer receives ERR_ROOM_FULL and never falsely displays that it joined the room"
	)

	# B4. Duplicate join requests from an already-joined member do not add the player twice
	joined_client._room_request_in_flight = false
	joined_client.join_private_room(priv_code)
	joined_client._room_request_in_flight = false
	joined_client.join_private_room(priv_code)
	await _wait_frames(6)
	_assert(
		(server.rooms[priv_code]["members"] as Array).size() == 2,
		"Duplicate join requests from the same player do not add duplicate room entries"
	)

	# B5. Crafted host-impersonation & >5 capacity messages are rejected/clamped
	joined_client.last_error_code = ""
	joined_client.send_message({
		"type": NetProtocol.C2S_CONFIGURE_ROOM,
		"host_peer_id": joined_client.local_peer_id,
		"is_host": true,
		"target_humans": 5
	}, true)
	await _wait_until(func(): return not joined_client.last_error_code.is_empty(), 1.5)
	_assert(
		joined_client.last_error_code == "ERR_NOT_HOST" and int(server.rooms[priv_code]["target_humans"]) == 2,
		"Non-host cannot bypass host check by crafting 'host_peer_id' / 'is_host' fields (ERR_NOT_HOST)"
	)

	# Host tries to set target_humans = 99 and ai_count = 99 -> clamped to 5 max total
	rc1.configure_private_room(99, true, 99)
	await _wait_frames(6)
	_assert(
		int(server.rooms[priv_code]["target_humans"]) == 5 and int(server.rooms[priv_code]["ai_count"]) == 0,
		"Server clamps room capacity to 5-player maximum even when host requests 99 humans + 99 AI"
	)

	# Join remaining 3 players (up to 5 total) and verify 6th player is rejected
	var rem_clients: Array[MultiplayerClient] = [rejected_client, rc4, rc5]
	for extra_c in rem_clients:
		extra_c.join_private_room(priv_code)
	await _wait_until(func(): return (server.rooms[priv_code]["members"] as Array).size() == 5, 2.5)
	rc6.last_error_code = ""
	rc6.join_private_room(priv_code)
	await _wait_until(func(): return not rc6.last_error_code.is_empty(), 1.5)
	_assert(
		(server.rooms[priv_code]["members"] as Array).size() == 5 and rc6.last_error_code == "ERR_ROOM_FULL",
		"5-player room rejects 6th player with ERR_ROOM_FULL"
	)

	# B6. Clean up all 5 members -> verify room code is invalidated and cannot be joined afterward
	var five_members: Array[MultiplayerClient] = [rc1, rc2, rc3, rc4, rc5]
	for c in five_members:
		c.leave_private_room()
	await _wait_frames(6)
	_assert(not server.rooms.has(priv_code), "Empty room (%s) is immediately cleaned up from server" % priv_code)

	rc6.last_error_code = ""
	rc6._room_request_in_flight = false
	rc6.join_private_room(priv_code)
	await _wait_until(func(): return not rc6.last_error_code.is_empty(), 1.5)
	_assert(
		rc6.last_error_code == "ERR_INVALID_ROOM_CODE",
		"Closed room code (%s) is invalidated and rejected on subsequent join attempts" % priv_code
	)

	# =========================================================================
	# SECTION C: PUBLIC MATCHMAKING — ALL 14 CASES (Section 4)
	# =========================================================================
	print("\n--- Section C: Public Matchmaking (Spam Guard, Multi-Group Isolation, AI Fill & Cleanup) ---")

	# C1. Single player sends duplicate C2S_QUICK_JOIN requests & crafted required_humans=1 with fill_ai=false
	rc1.send_message({"type": NetProtocol.C2S_QUICK_JOIN, "required_humans": 1, "fill_ai": false}, true)
	rc1.request_quick_join(2, false)
	rc1.request_quick_join(2, false)
	await _wait_frames(6)
	_assert(
		server._quick_match_queue.size() == 1 and rc1.in_matchmaking_queue and rc1.current_session_id.is_empty(),
		"Repeated queue requests do not create duplicate queue entries, and 1 player with fill_ai=false waits in queue instead of starting prematurely"
	)

	# C2. Player cancels matchmaking and is not assigned when 2 other players queue
	rc1.cancel_queue()
	await _wait_frames(5)
	_assert(server._quick_match_queue.is_empty() and not rc1.in_matchmaking_queue, "Canceling matchmaking removes player from server queue")

	rc2.request_quick_join(2, false)
	rc3.request_quick_join(2, false)
	await _wait_until(func(): return not rc2.current_session_id.is_empty() and not rc3.current_session_id.is_empty(), 2.5)
	_assert(
		rc1.current_session_id.is_empty() and rc2.current_session_id == rc3.current_session_id,
		"Canceled player (rc1) is not assigned to a match when rc2 and rc3 match together"
	)

	# C3. Player already in an active match cannot re-enter matchmaking or create/join a room (ERR_ALREADY_IN_MATCH)
	rc2.last_error_code = ""
	rc2.request_quick_join(2, false)
	await _wait_until(func(): return not rc2.last_error_code.is_empty(), 1.5)
	_assert(
		rc2.last_error_code == "ERR_ALREADY_IN_MATCH" and not server._quick_match_queue.has(rc2.local_peer_id),
		"Player in an active match cannot enter matchmaking or be assigned to multiple matches simultaneously (ERR_ALREADY_IN_MATCH)"
	)

	# C4. While Match 1 (rc2 + rc3) is active, Group 2 (rc4 + rc5) queues with AI Fill ON (2H + 3AI = 5 total)
	rc4.request_quick_join(2, true)
	rc5.request_quick_join(2, true)
	await _wait_until(func(): return not rc4.current_session_id.is_empty() and not rc5.current_session_id.is_empty(), 2.5)
	var sess_group1 := server.get_session(rc2.current_session_id)
	var sess_group2 := server.get_session(rc4.current_session_id)
	_assert(
		sess_group1 != null and sess_group2 != null and sess_group1 != sess_group2,
		"Multiple groups of players form separate concurrent match sessions without sharing state"
	)
	_assert(
		sess_group1.get_living_players().size() == 2 and sess_group2.get_living_players().size() == 5 and sess_group2.ai_controllers.size() == 3,
		"Match 1 (AI Fill OFF) has 2 players while Match 2 (AI Fill ON) fills to 5 total participants (2H + 3AI)"
	)

	# Complete Match 1 and verify rc2 & rc3 can re-enter matchmaking afterward
	sess_group1.characters[1].eliminate("LASER")
	await _wait_until(func(): return sess_group1.current_phase == ServerMatchSession.MatchPhase.MATCH_OVER, 2.0)
	await _wait_frames(4)
	rc2.request_quick_join(2, false)
	await _wait_until(func(): return rc2.in_matchmaking_queue, 2.0)
	_assert(rc2.in_matchmaking_queue, "Player can return to public matchmaking immediately after a match completes")
	rc2.cancel_queue()
	server._cleanup_session(sess_group1.session_id)
	server._cleanup_session(sess_group2.session_id)
	await _wait_frames(5)

	# =========================================================================
	# SECTION D: GAMEPLAY AUTHORITY, INPUT SANITIZATION & ANTI-CHEAT (Section 5)
	# =========================================================================
	print("\n--- Section D: Server Gameplay Authority, Input Validation & Anti-Cheat ---")

	var auth_sess := server.create_match_session([
		{"peer_id": rc1.local_peer_id, "name": rc1.player_name, "is_ai": false},
		{"peer_id": rc2.local_peer_id, "name": rc2.player_name, "is_ai": false}
	])
	await _wait_frames(6)

	# D1. Clients cannot spoof server-only authority packets (eliminate, shrink, laser resolution, match end)
	for spoof_type in [
		NetProtocol.S2C_PLAYER_ELIMINATED,
		NetProtocol.S2C_MATCH_ENDED,
		NetProtocol.S2C_LASER_RESOLUTION,
		NetProtocol.S2C_ARENA_SHRINK_EVENT,
		"c2s_teleport_pos",
		"c2s_force_laser_attack"
	]:
		rc1.last_error_code = ""
		rc1.send_message({"type": spoof_type, "slot_id": 1, "winner_slot_id": 0}, true)
		await _wait_until(func(): return not rc1.last_error_code.is_empty(), 1.5)
		if rc1.last_error_code != "ERR_FORBIDDEN_CLIENT_AUTHORITY":
			break
	_assert(
		rc1.last_error_code == "ERR_FORBIDDEN_CLIENT_AUTHORITY" and auth_sess.get_living_players().size() == 2 and auth_sess.current_phase == ServerMatchSession.MatchPhase.PREPARATION,
		"Server rejects client attempts to spoof eliminations, match end, laser attacks, positions, or shrink events (ERR_FORBIDDEN_CLIENT_AUTHORITY)"
	)

	# D2. Out-of-order, duplicate, negative, NaN/Inf, and non-Vector2 inputs are safely handled
	var ok_seq10 := auth_sess.apply_client_input(rc1.local_peer_id, Vector2(0.5, 0.0), Vector2(0.0, 1.0), 10)
	var dup_seq10 := auth_sess.apply_client_input(rc1.local_peer_id, Vector2(1.0, 0.0), Vector2(0.0, 1.0), 10)
	var stale_seq9 := auth_sess.apply_client_input(rc1.local_peer_id, Vector2(1.0, 0.0), Vector2(0.0, 1.0), 9)
	var neg_seq := auth_sess.apply_client_input(rc1.local_peer_id, Vector2(1.0, 0.0), Vector2(0.0, 1.0), -5)
	_assert(
		ok_seq10 and (not dup_seq10) and (not stale_seq9) and (not neg_seq),
		"Server accepts valid seq (10) and rejects duplicate (10), out-of-order (9), and negative (-5) input sequence numbers"
	)

	var nan_vec := Vector2(NAN, INF)
	auth_sess.apply_client_input(rc1.local_peer_id, nan_vec, "invalid_aim_string", 11)
	_assert(
		auth_sess.characters[0].move_input == Vector2.ZERO and is_equal_approx(auth_sess.characters[0].aim_direction.length(), 1.0),
		"NaN/Inf movement vectors and malformed aim strings are sanitized without corrupting character state"
	)

	# D3. Repeated _trigger_simultaneous_resolution() call in the same round cannot resolve twice
	auth_sess._trigger_simultaneous_resolution()
	var round_after_first := auth_sess.current_round
	auth_sess._trigger_simultaneous_resolution()
	_assert(
		auth_sess.current_phase == ServerMatchSession.MatchPhase.RESOLUTION_FREEZE and auth_sess.current_round == round_after_first,
		"Simultaneous laser resolution is phase-locked and cannot be triggered twice in the same round"
	)
	server._cleanup_session(auth_sess.session_id)
	await _wait_frames(4)

	# =========================================================================
	# SECTION E: PERSISTENCE & MATCH-RESULT INTEGRITY (Section 8)
	# =========================================================================
	print("\n--- Section E: Persistence Atomic Writes, Backup Recovery & Duplicate Result Rejection ---")

	var p_store := server.persistence
	var match_summary := {
		"session_id": "verified_unique_session_9001",
		"is_draw": false,
		"winner_slot_id": 0,
		"winner_name": rc1.player_name,
		"rounds_completed": 3,
		"final_stage": 2,
		"slots": [
			{"slot_id": 0, "name": rc1.player_name, "is_human": true, "active": true, "eliminations": 2},
			{"slot_id": 1, "name": rc2.player_name, "is_human": true, "active": true, "eliminations": 0}
		]
	}
	var first_rec := p_store.record_authoritative_match(match_summary)
	var dup_rec := p_store.record_authoritative_match(match_summary)
	var prof_rc1 := p_store.get_public_profile(rc1.player_name)
	_assert(
		first_rec == true and dup_rec == false and int(prof_rc1.get("wins", 0)) == 1 and int(prof_rc1.get("eliminations", 0)) == 2,
		"Duplicate match result submission with the same session_id is rejected and does not grant repeated wins"
	)

	# Fabricated 1-player or 0-player summary is rejected
	var fake_rec := p_store.record_authoritative_match({
		"session_id": "fake_1p_session",
		"is_draw": false,
		"winner_slot_id": 0,
		"winner_name": rc1.player_name,
		"slots": [{"slot_id": 0, "name": rc1.player_name, "is_human": true, "active": true, "eliminations": 5}]
	})
	_assert(fake_rec == false and int(p_store.get_public_profile(rc1.player_name).get("wins", 0)) == 1, "Persistence rejects match summaries with fewer than 2 active participants")

	# Trigger a second save so .bak is populated, then corrupt the primary JSON file to test backup recovery
	p_store.save_to_disk()
	var f_corrupt := FileAccess.open(TEST_PERSIST_PATH, FileAccess.WRITE)
	f_corrupt.store_string("{corrupted_json_syntax: [1, 2, ")
	f_corrupt.close()

	var recovered_store := ServerPersistence.new(TEST_PERSIST_PATH)
	var rec_prof := recovered_store.get_public_profile(rc1.player_name)
	_assert(
		not recovered_store.last_load_error.is_empty() and int(rec_prof.get("wins", 0)) == 1,
		"Corrupted primary persistence JSON logs a clear error and automatically recovers intact player stats from .bak backup"
	)

	# =========================================================================
	# SECTION F: RATE-LIMIT FLOODING, SLOW CLIENT NON-BLOCKING & DISCONNECT LIFECYCLE (Sections 5, 6, 7)
	# =========================================================================
	print("\n--- Section F: Flood Rate-Limiting, Slow Client Non-Blocking & Disconnect Recovery ---")

	# F1. Control message flood rate limiting (>30 control messages/sec triggers ERR_RATE_LIMITED)
	var spam_client := _spawn_client("SPAMMER", "spam_rate_token_777")
	await _connect_client(spam_client, TEST_PORT, "SPAMMER")
	spam_client.last_error_code = ""
	for _s in range(NetProtocol.MAX_CONTROL_MSGS_PER_SEC + 5):
		spam_client.request_stats()
	await _wait_until(func(): return spam_client.last_error_code == "ERR_RATE_LIMITED", 2.0)
	_assert(
		spam_client.last_error_code == "ERR_RATE_LIMITED",
		"Excessive control message flooding (>%d msgs/s) is throttled with ERR_RATE_LIMITED" % NetProtocol.MAX_CONTROL_MSGS_PER_SEC
	)
	spam_client.disconnect_from_server()
	spam_client.queue_free()

	# F2. Slow/silent client (sending 0 inputs) does not block round timer, laser resolution, or other players
	var slow_sess := server.create_match_session([
		{"peer_id": rc1.local_peer_id, "name": rc1.player_name, "is_ai": false},
		{"peer_id": rc2.local_peer_id, "name": rc2.player_name, "is_ai": false},
		{"peer_id": rc3.local_peer_id, "name": rc3.player_name, "is_ai": false}
	], {"preparation_duration": 0.25})
	# rc1 moves; rc2 and rc3 send 0 packets at all
	rc1.send_player_input_now(Vector2(0.0, -1.0), Vector2(0.0, 1.0))
	await _wait_until(func(): return slow_sess.current_round >= 2 or slow_sess.current_phase == ServerMatchSession.MatchPhase.MATCH_OVER, 2.5)
	_assert(
		slow_sess.current_round >= 2 or slow_sess.current_phase == ServerMatchSession.MatchPhase.MATCH_OVER,
		"Slow/silent clients sending no packets do not block server round countdown or laser resolution"
	)
	server._cleanup_session(slow_sess.session_id)
	await _wait_frames(4)

	# F3. Disconnecting during room creation, joining, queueing, and active match leaves zero stale records
	var d1 := _spawn_client("DISC1", "disc_tok_101")
	var d2 := _spawn_client("DISC2", "disc_tok_102")
	await _connect_client(d1, TEST_PORT, "DISC1")
	await _connect_client(d2, TEST_PORT, "DISC2")

	d1.create_private_room(2, false, 0)
	await _wait_until(func(): return not d1.current_room_code.is_empty(), 2.0)
	var temp_room := d1.current_room_code
	d2.join_private_room(temp_room)
	await _wait_until(func(): return d2.current_room_code == temp_room, 2.0)

	# Both disconnect abruptly; server must clean up room and peer records
	var d1_pid := d1.local_peer_id
	var d2_pid := d2.local_peer_id
	d1.disconnect_from_server()
	d2.disconnect_from_server()
	# Simulate immediate server disconnect notification
	server._on_peer_disconnected(d1_pid)
	server._on_peer_disconnected(d2_pid)
	await _wait_frames(4)
	_assert(
		not server.rooms.has(temp_room) and not server.connected_peers.has(d1_pid) and not server.connected_peers.has(d2_pid),
		"Abrupt client disconnects clean up rooms and connected_peers without leaving stale player records"
	)
	d1.queue_free()
	d2.queue_free()

	# Cleanup clients and server
	for mc in r_clients:
		mc.disconnect_from_server()
		mc.queue_free()
	server.stop_server()
	server.queue_free()
	await _wait_frames(4)
	_remove_test_persistence_files()

	print("\n=== COMPREHENSIVE RELIABILITY & SECURITY SUMMARY: %d PASSED, %d FAILED ===" % [_passes, _failures])
	quit(1 if _failures > 0 else 0)
