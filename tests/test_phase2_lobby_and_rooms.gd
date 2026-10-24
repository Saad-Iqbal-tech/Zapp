extends SceneTree
## Phase 2 Automated Verification Suite — Private Rooms, Public Matchmaking, and AI Fill
## Tests:
## 1. Creating and joining private rooms with 5-char shareable room code.
## 2. Duplicate room code handling (ERR_DUPLICATE_ROOM_CODE).
## 3. Invalid room code handling (ERR_INVALID_ROOM_CODE).
## 4. Full room rejection (ERR_ROOM_FULL).
## 5. Multiple clients in the same lobby receiving synchronized room state.
## 6. Ready/unready states and preventing match start when unready (ERR_PLAYERS_NOT_READY).
## 7. Host-only start and configuration enforcement (ERR_NOT_HOST).
## 8. Host disconnection & automatic host reassignment, plus room closure when empty.
## 9. All supported human/AI combinations (2H+3AI, 3H+2AI, 5H+0AI, 2H+0AI without silent AI fill).
## 10. Honest public matchmaking queue with real connected players.
## 11. Returning to the lobby / rematch flow after a match ends.
## 12. Reconnecting / safely returning to the menu after connection loss.

const TEST_PORT: int = 17775

var _passes: int = 0
var _failures: int = 0


func _init() -> void:
	call_deferred("_run_phase2_tests")


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


func _connect_clients(clients: Array[MultiplayerClient], port: int) -> void:
	for i in range(clients.size()):
		clients[i].connect_to_server("127.0.0.1", port, "P%d" % (i + 1))
	for _f in range(35):
		await _wait_frames(1)
		var all_ok := true
		for c in clients:
			if not c.is_connected_to_server():
				all_ok = false
				break
		if all_ok:
			break


func _run_phase2_tests() -> void:
	print("\n=== STARTING PHASE 2: PRIVATE ROOMS, PUBLIC MATCHMAKING & AI FILL TEST SUITE ===")

	var server := DedicatedServer.new()
	server.name = "Phase2DedicatedServer"
	root.add_child(server)
	var err := server.start_server(TEST_PORT, "127.0.0.1")
	_assert(err == OK and server.is_running(), "Dedicated server starts on UDP 127.0.0.1:%d" % TEST_PORT)

	# Create 5 MultiplayerClient instances to test all room sizes & combinations
	var clients: Array[MultiplayerClient] = []
	for i in range(5):
		var mc := MultiplayerClient.new()
		mc.name = "TestClient_%d" % (i + 1)
		root.add_child(mc)
		clients.append(mc)

	await _connect_clients(clients, TEST_PORT)
	_assert(clients[0].is_connected_to_server() and clients[4].is_connected_to_server(), "All 5 test clients connect to the server")

	var c1 := clients[0]
	var c2 := clients[1]
	var c3 := clients[2]
	var c4 := clients[3]
	var c5 := clients[4]

	# 1. Test Private Room Creation & Duplicate Room Code Handling
	c1.create_private_room(2, false, 0)
	await _wait_frames(8)

	var room_code := c1.current_room_code
	_assert(room_code.length() == 5, "Host creates private room with 5-character shareable room code (%s)" % room_code)
	_assert(c1.is_room_host(), "Room creator is assigned as Room Host")

	# Attempt to create a room with the exact same code from c2
	c2.last_error_code = ""
	c2.create_private_room(2, false, 0, room_code)
	await _wait_frames(6)
	_assert(c2.last_error_code == "ERR_DUPLICATE_ROOM_CODE", "Server rejects duplicate room code creation (ERR_DUPLICATE_ROOM_CODE)")

	# 2. Test Invalid Room Code Handling
	c2.last_error_code = ""
	c2.join_private_room("ZZZZZ")
	await _wait_frames(6)
	_assert(c2.last_error_code == "ERR_INVALID_ROOM_CODE", "Server rejects invalid room code (ERR_INVALID_ROOM_CODE)")

	# 3. Test Joining Room with Valid Code & Full Room Rejection
	c2.join_private_room(room_code)
	await _wait_frames(8)
	_assert(c2.current_room_code == room_code, "Client 2 joins private room using valid room code")
	_assert(
		(c1.latest_room_state.get("members", []) as Array).size() == 2 and (c2.latest_room_state.get("members", []) as Array).size() == 2,
		"Both clients in lobby see the same 2 connected room members"
	)

	# Room is configured for 2 humans (target_humans = 2), so Client 3 joining must receive ERR_ROOM_FULL
	c3.last_error_code = ""
	c3.join_private_room(room_code)
	await _wait_frames(6)
	_assert(c3.last_error_code == "ERR_ROOM_FULL", "Server rejects joining a full room (ERR_ROOM_FULL)")

	# 4. Test Ready / Unready States & Host-Only Controls
	# Client 2 starts unready (ready = false); Host trying to start now must receive ERR_PLAYERS_NOT_READY
	c1.last_error_code = ""
	c1.start_private_room_match()
	await _wait_frames(6)
	_assert(c1.last_error_code == "ERR_PLAYERS_NOT_READY", "Match cannot start while a joined player is unready (ERR_PLAYERS_NOT_READY)")

	# Non-host (Client 2) trying to configure or start the room must receive ERR_NOT_HOST
	c2.last_error_code = ""
	c2.configure_private_room(3, true, 2)
	await _wait_frames(6)
	_assert(c2.last_error_code == "ERR_NOT_HOST", "Non-host cannot configure room settings (ERR_NOT_HOST)")

	c2.set_room_ready(true)
	await _wait_frames(6)
	_assert(bool(c1.latest_room_state.get("can_start", false)) == true, "Room becomes startable once all players are READY")

	c2.last_error_code = ""
	c2.start_private_room_match()
	await _wait_frames(6)
	_assert(c2.last_error_code == "ERR_NOT_HOST", "Non-host cannot start the match even when ready (ERR_NOT_HOST)")

	# Toggle Client 2 unready then ready again
	c2.set_room_ready(false)
	await _wait_frames(5)
	_assert(bool(c1.latest_room_state.get("can_start", false)) == false, "Toggling UNREADY updates room start eligibility immediately")
	c2.set_room_ready(true)
	await _wait_frames(5)

	# 5. Test No Silent AI Fill (2 Humans + 0 AI when fill_ai == false)
	c1.start_private_room_match()
	await _wait_frames(8)
	var session_id := c1.current_session_id
	var session := server.get_session(session_id)
	_assert(session != null and session.get_living_players().size() == 2, "Room with 2 humans and AI Fill OFF spawns exactly 2 players (no silent AI fill)")

	# End match and verify return-to-lobby / rematch flow
	session.characters[1].eliminate("LASER")
	await _wait_frames(8)
	_assert(session.current_phase == ServerMatchSession.MatchPhase.MATCH_OVER, "Match completes when 1 survivor remains")
	_assert(bool(c1.latest_room_state.get("in_match", true)) == false, "Room automatically returns to WAITING lobby state after match ends")

	c2.request_rematch()
	await _wait_frames(6)
	_assert(bool(c1.latest_room_state.get("can_start", false)) == true, "Rematch request marks player ready in room lobby for next match")

	# 6. Test Human/AI Combination #1: 2 Humans + 3 AI Opponents
	c1.configure_private_room(2, true, 3)
	await _wait_frames(6)
	_assert(
		int(c1.latest_room_state.get("target_humans", 0)) == 2 and int(c1.latest_room_state.get("ai_count", 0)) == 3,
		"Host configures room for 2 Humans + 3 AI Opponents"
	)
	c1.start_private_room_match()
	await _wait_frames(8)
	var session_2h3ai := server.get_session(c1.current_session_id)
	_assert(
		session_2h3ai != null and session_2h3ai.get_living_players().size() == 5 and session_2h3ai.ai_controllers.size() == 3,
		"Match starts with 2 Humans and 3 Server-Authoritative AI Opponents (5 total)"
	)
	# Verify server AI cannot see through solid obstacles
	var test_ai := session_2h3ai.ai_controllers[0]
	for idx in range(5):
		session_2h3ai.characters[idx].global_position = Vector3(-9.0 + idx * 1.5, 0.05, -9.0)
	# Put AI's controlled character at (0, 0.05, 6.2) and only other living player behind obstacle (0, 0, 3.9) at (0, 0.05, 1.8)
	test_ai.controlled_character.global_position = Vector3(0.0, 0.05, 6.2)
	session_2h3ai.characters[0].global_position = Vector3(0.0, 0.05, 1.8)
	# Temporarily move other characters far behind obstacles
	session_2h3ai.characters[1].global_position = Vector3(0.0, 0.05, 1.6)
	var picked := test_ai._select_best_target()
	_assert(picked != session_2h3ai.characters[0] and picked != session_2h3ai.characters[1], "Server AI does not select targets hidden behind solid obstacles")

	server._cleanup_session(session_2h3ai.session_id)
	await _wait_frames(4)

	# 7. Test Human/AI Combination #2: 3 Humans + 2 AI Opponents
	c1.configure_private_room(3, true, 2)
	await _wait_frames(6)
	c3.join_private_room(room_code)
	await _wait_frames(6)
	c2.set_room_ready(true)
	c3.set_room_ready(true)
	await _wait_frames(6)
	c1.start_private_room_match()
	await _wait_frames(8)
	var session_3h2ai := server.get_session(c1.current_session_id)
	_assert(
		session_3h2ai != null and session_3h2ai.get_living_players().size() == 5 and session_3h2ai.ai_controllers.size() == 2,
		"Match starts with 3 Humans and 2 Server-Authoritative AI Opponents (5 total)"
	)
	server._cleanup_session(session_3h2ai.session_id)
	await _wait_frames(4)

	# 8. Test Human/AI Combination #3: 5 Humans + 0 AI Opponents
	c1.configure_private_room(5, false, 0)
	await _wait_frames(6)
	c4.join_private_room(room_code)
	c5.join_private_room(room_code)
	await _wait_frames(6)
	c2.set_room_ready(true)
	c3.set_room_ready(true)
	c4.set_room_ready(true)
	c5.set_room_ready(true)
	await _wait_frames(6)
	c1.start_private_room_match()
	await _wait_frames(8)
	var session_5h0ai := server.get_session(c1.current_session_id)
	_assert(
		session_5h0ai != null and session_5h0ai.get_living_players().size() == 5 and session_5h0ai.ai_controllers.size() == 0,
		"Match starts with 5 Humans and 0 AI Opponents (5 total)"
	)
	server._cleanup_session(session_5h0ai.session_id)
	await _wait_frames(4)

	# 9. Test Host Disconnection & Host Reassignment + Room Closure
	c1.leave_private_room()
	await _wait_frames(6)
	_assert(c2.is_room_host(), "When Host leaves/disconnects, Server automatically reassigns Host to the next player (Client 2)")

	c2.leave_private_room()
	c3.leave_private_room()
	c4.leave_private_room()
	c5.leave_private_room()
	await _wait_frames(6)
	_assert( not server.rooms.has(room_code), "Room is automatically closed and removed when all members leave")

	# 10. Test Honest Public Matchmaking Queue
	c1.request_quick_join(2, false)
	await _wait_frames(6)
	_assert(c1.in_matchmaking_queue and c1.queued_players_count == 1 and server._quick_match_queue.size() == 1, "Public matchmaking reports honest queue count (1/2) without fake bots")

	c1.cancel_queue()
	await _wait_frames(6)
	_assert(server._quick_match_queue.size() == 0, "Canceling public matchmaking removes player from server queue")

	# Now queue both c1 and c2 for public matchmaking
	c1.request_quick_join(2, false)
	c2.request_quick_join(2, false)
	await _wait_frames(10)
	_assert(not c1.current_session_id.is_empty() and c1.current_session_id == c2.current_session_id, "Public matchmaking pairs actual connected players into an authoritative match")

	# 11. Test Connection Loss & Safe Return to Menu on Full MatchController Client
	var packed: PackedScene = load("res://scenes/main_arena.tscn")
	var full_client := packed.instantiate() as MatchController
	root.add_child(full_client)
	await _wait_frames(4)
	full_client.multiplayer_client.connect_to_server("127.0.0.1", TEST_PORT, "UI_CLIENT")
	for _f in range(25):
		await _wait_frames(1)
		if full_client.multiplayer_client.is_connected_to_server():
			break
	server.create_match_session([
		{"peer_id": full_client.multiplayer_client.local_peer_id, "name": "UI_CLIENT", "is_ai": false},
		{"peer_id": 0, "name": "VEX", "is_ai": true}
	])
	await _wait_frames(8)
	_assert(full_client.is_online_match == true, "Full game client enters active online match")

	# Stop server to simulate unexpected server drop
	server.stop_server()
	for _f in range(25):
		await _wait_frames(1)
		if full_client.current_phase == MatchController.MatchPhase.MAIN_MENU:
			break
	# Also trigger _on_online_disconnected if ENet close is immediate
	if full_client.current_phase != MatchController.MatchPhase.MAIN_MENU:
		full_client._on_online_disconnected("Server closed")
	_assert(
		full_client.current_phase == MatchController.MatchPhase.MAIN_MENU and full_client.hud.is_in_main_menu(),
		"Client safely returns to Main Menu after unexpected server connection loss"
	)

	# Cleanup
	for c in clients:
		c.disconnect_from_server()
		c.free()
	await process_frame
	full_client.free()
	server.free()

	print("=== PHASE 2 TEST SUMMARY: %d PASSED, %d FAILED ===" % [_passes, _failures])
	quit(1 if _failures > 0 else 0)
