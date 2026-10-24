extends SceneTree
## Phase 1 Automated Verification Suite — Authoritative Godot Multiplayer
## Tests:
## 1. Dedicated headless server startup on local UDP port.
## 2. Two (and three) clients connecting to one local headless server and receiving unique IDs.
## 3. Both clients seeing the same players, positions, and synchronized round countdown.
## 4. Movement and aiming inputs from both clients reaching the server (plus input validation).
## 5. Obstacle blocking during server-authoritative laser resolution.
## 6. Mutual simultaneous eliminations resolved atomically without order bias.
## 7. Match continuing after an elimination and last surviving player winning.
## 8. Unexpected client disconnection handled safely without crashing the match.

const TEST_PORT: int = 17771

var _passes: int = 0
var _failures: int = 0


func _init() -> void:
	call_deferred("_run_phase1_tests")


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


func _run_phase1_tests() -> void:
	print("\n=== STARTING PHASE 1: AUTHORITATIVE MULTIPLAYER TEST SUITE ===")

	# 1. Start Dedicated Headless Server
	var server := DedicatedServer.new()
	server.name = "TestDedicatedServer"
	root.add_child(server)
	var err := server.start_server(TEST_PORT, "127.0.0.1")
	_assert(err == OK and server.is_running(), "Dedicated headless server starts on UDP 127.0.0.1:%d" % TEST_PORT)

	# 2. Connect two full game clients (MatchController instances) to the server
	var main_scene: PackedScene = load("res://scenes/main_arena.tscn")
	var client1_arena := main_scene.instantiate() as MatchController
	client1_arena.name = "Client1Arena"
	root.add_child(client1_arena)

	var client2_arena := main_scene.instantiate() as MatchController
	client2_arena.name = "Client2Arena"
	root.add_child(client2_arena)

	await _wait_frames(3)

	var c1 := client1_arena.multiplayer_client
	var c2 := client2_arena.multiplayer_client

	c1.connect_to_server("127.0.0.1", TEST_PORT, "ALICE")
	c2.connect_to_server("127.0.0.1", TEST_PORT, "BOB")

	# Wait for ENet handshake and S2C_WELCOME
	for _i in range(30):
		await _wait_frames(1)
		if c1.is_connected_to_server() and c2.is_connected_to_server() and c1.local_peer_id > 1 and c2.local_peer_id > 1:
			break

	_assert(c1.is_connected_to_server() and c2.is_connected_to_server(), "Two clients connect to one local headless server")
	_assert(c1.local_peer_id != c2.local_peer_id and c1.local_peer_id > 1 and c2.local_peer_id > 1, "Server assigns a unique peer ID to every connected participant")

	# 3. Start an authoritative match with both clients + 1 server-controlled participant (so we can test 1 elimination continuing the match)
	server.quick_match_required_players = 2
	server.quick_match_fill_with_ai = false
	var participants: Array[Dictionary] = [
		{"peer_id": c1.local_peer_id, "name": "ALICE", "is_ai": false},
		{"peer_id": c2.local_peer_id, "name": "BOB", "is_ai": false},
		{"peer_id": 0, "name": "BOT_3", "is_ai": false} # Passive dummy 3rd slot so match continues after 1 elimination
	]
	var session := server.create_match_session(participants, {"preparation_duration": 5.0})
	_assert(session != null, "Server creates authoritative match session")

	await _wait_frames(8)

	_assert(client1_arena.is_online_match and client2_arena.is_online_match, "Both clients transition into online match mode")
	_assert(c1.local_slot_id == 0 and c2.local_slot_id == 1, "Clients receive their assigned slot IDs (0 and 1)")
	_assert(client1_arena.get_living_players().size() == 3 and client2_arena.get_living_players().size() == 3, "Both clients see the same 3 active players")
	_assert(absf(client1_arena.phase_timer - client2_arena.phase_timer) < 0.35, "Both clients see synchronized round countdown")

	# 4. Test Client Inputs Reaching Server & Server Validation
	var s_char0 := session.characters[0]
	var s_char1 := session.characters[1]
	var start_pos0 := s_char0.global_position
	var start_pos1 := s_char1.global_position

	# Send oversized move vector (length 50) to verify server clamps it to <= 1.0, and custom aim vectors
	c1.send_player_input_now(Vector2(50.0, 0.0), Vector2(0.0, -1.0))
	c2.send_player_input_now(Vector2(-1.0, 0.0), Vector2(1.0, 0.0))

	await _wait_frames(10)

	_assert(s_char0.move_input.length() <= 1.001, "Server validates and clamps oversized client movement input")
	_assert(s_char0.global_position.x > start_pos0.x + 0.1, "Client 1 movement input reaches server and moves authoritative character")
	_assert(s_char1.global_position.x < start_pos1.x - 0.1, "Client 2 movement input reaches server and moves authoritative character")
	_assert(s_char0.aim_direction.distance_to(Vector3(0.0, 0.0, -1.0)) < 0.05, "Client 1 aim input updates server attack direction")
	_assert(s_char1.aim_direction.distance_to(Vector3(1.0, 0.0, 0.0)) < 0.05, "Client 2 aim input updates server attack direction")

	# Stop moving
	c1.send_player_input_now(Vector2.ZERO, Vector2(0.0, -1.0))
	c2.send_player_input_now(Vector2.ZERO, Vector2(1.0, 0.0))
	await _wait_frames(6)

	# Verify remote player interpolation on clients
	_assert(
		client1_arena.characters[1].global_position.distance_to(s_char1.global_position) < 0.6,
		"Client 1 smoothly interpolates remote Client 2 position from authoritative snapshots"
	)

	# 5. Test Obstacle Blocking on Server-Authoritative Resolution
	# Place ALICE at (0, 0.05, 6.2) aiming -Z across obstacle at (0, 0, 3.9) toward BOB at (0, 0.05, 1.8)
	# Place BOT_3 safely out of the way at (-8.5, 0.05, -8.5) aiming -Z
	s_char0.global_position = Vector3(0.0, 0.05, 6.2)
	s_char0.set_aim_direction_3d(Vector3(0.0, 0.0, -1.0))
	s_char1.global_position = Vector3(0.0, 0.05, 1.8)
	s_char1.set_aim_direction_3d(Vector3(1.0, 0.0, 0.0)) # Aiming +X away from ALICE
	session.characters[2].global_position = Vector3(-8.5, 0.05, -8.5)
	session.characters[2].set_aim_direction_3d(Vector3(0.0, 0.0, -1.0))

	session._trigger_simultaneous_resolution()
	await _wait_frames(6)

	_assert(s_char1.is_alive() and client2_arena.characters[1].is_alive(), "Solid obstacle at (0, 0, 3.9) blocks attack line on authoritative server")

	# Advance server into Round 2 Preparation
	session._begin_next_preparation_round()
	await _wait_frames(6)
	_assert(client1_arena.current_round == 2 and client2_arena.current_round == 2, "Both clients advance to Round 2 Preparation")

	# 6. Test Mutual Simultaneous Elimination on Server
	# Place ALICE and BOB in an open lane (x = -2.2) aiming directly at each other; BOT_3 stays safe at (-8.5, 0.05, -8.5)
	s_char0.global_position = Vector3(-2.2, 0.05, 2.5)
	s_char0.set_aim_direction_3d(Vector3(0.0, 0.0, -1.0))
	s_char1.global_position = Vector3(-2.2, 0.05, -2.5)
	s_char1.set_aim_direction_3d(Vector3(0.0, 0.0, 1.0))
	session.characters[2].global_position = Vector3(-8.5, 0.05, -8.5)
	session.characters[2].set_aim_direction_3d(Vector3(-1.0, 0.0, 0.0))

	session._trigger_simultaneous_resolution()
	await _wait_frames(8)

	_assert(not s_char0.is_alive() and not s_char1.is_alive(), "Mutual attacks in the same round eliminate BOTH players simultaneously on server")
	_assert(
		not client1_arena.characters[0].is_alive() and not client2_arena.characters[1].is_alive(),
		"Both clients receive simultaneous mutual elimination update"
	)
	_assert(session.characters[2].current_state == CharacterController.State.WINNER, "Last surviving player (BOT_3) wins the match")
	_assert(
		client1_arena.current_phase == MatchController.MatchPhase.MATCH_OVER and client2_arena.current_phase == MatchController.MatchPhase.MATCH_OVER,
		"Both clients display authoritative match over & winner state"
	)

	# 7. Test Match Continuation After 1 Elimination & Disconnection Handling in a Fresh Match
	var session2 := server.create_match_session(participants, {"preparation_duration": 5.0})
	await _wait_frames(8)
	_assert(client1_arena.current_round == 1 and client1_arena.get_living_players().size() == 3, "Fresh online match session resets all 3 participants to ALIVE")

	# ALICE eliminates BOT_3 only in Round 1; match must continue with ALICE and BOB alive
	session2.characters[0].global_position = Vector3(-2.2, 0.05, 2.0)
	session2.characters[0].set_aim_direction_3d(Vector3(0.0, 0.0, -1.0))
	session2.characters[2].global_position = Vector3(-2.2, 0.05, -2.0)
	session2.characters[2].set_aim_direction_3d(Vector3(-1.0, 0.0, 0.0)) # Aiming away
	session2.characters[1].global_position = Vector3(6.0, 0.05, 6.0)
	session2.characters[1].set_aim_direction_3d(Vector3(1.0, 0.0, 0.0))

	session2._trigger_simultaneous_resolution()
	await _wait_frames(6)
	session2._begin_next_preparation_round()
	await _wait_frames(6)

	_assert(session2.get_living_players().size() == 2 and session2.current_phase == ServerMatchSession.MatchPhase.PREPARATION, "Game continues into Round 2 after 1 player is eliminated (2 survivors remain)")

	# Now simulate Client 2 (BOB) disconnecting unexpectedly mid-match
	c2.disconnect_from_server()
	for _i in range(25):
		await _wait_frames(1)
		if session2.current_phase == ServerMatchSession.MatchPhase.MATCH_OVER:
			break

	_assert(not session2.characters[1].is_alive(), "Disconnected client is safely eliminated by the server")
	_assert(session2.characters[0].current_state == CharacterController.State.WINNER, "Remaining connected survivor (ALICE) is crowned WINNER when last opponent disconnects")
	_assert(client1_arena.current_phase == MatchController.MatchPhase.MATCH_OVER, "Remaining client receives authoritative WINNER state after opponent disconnects")

	# 8. Test Separate Headless Dedicated Server OS Process (--server CLI flag)
	var ext_port := 17772
	var srv_pid := OS.create_process(
		OS.get_executable_path(),
		["--headless", "--path", ProjectSettings.globalize_path("res://"), "--", "--server", "--port=%d" % ext_port]
	)
	_assert(srv_pid > 0, "Spawned standalone headless server OS process (--server --port=%d)" % ext_port)

	var ext_client := MultiplayerClient.new()
	root.add_child(ext_client)
	var ext_connected := false
	for _attempt in range(8):
		ext_client.connect_to_server("127.0.0.1", ext_port, "EXT_TESTER")
		for _f in range(25):
			await _wait_frames(1)
			if ext_client.is_connected_to_server():
				ext_connected = true
				break
		if ext_connected:
			break
	_assert(ext_connected and ext_client.local_peer_id > 1, "Client connects over UDP to standalone headless server OS process")

	ext_client.disconnect_from_server()
	ext_client.free()
	if srv_pid > 0:
		OS.kill(srv_pid)

	# Cleanup
	c1.disconnect_from_server()
	server.stop_server()
	await process_frame
	client1_arena.free()
	client2_arena.free()
	server.free()

	print("=== PHASE 1 TEST SUMMARY: %d PASSED, %d FAILED ===" % [_passes, _failures])
	quit(1 if _failures > 0 else 0)
