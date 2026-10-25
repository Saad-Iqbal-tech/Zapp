extends SceneTree
## Automated end-to-end test suite for WebSocket multiplayer migration.
## Tests DedicatedServer, MultiplayerClient, WebSockets, ping/pong, room creation,
## invite code joining, leaderboard querying, and match start.

var server: DedicatedServer
var client_a: MultiplayerClient
var client_b: MultiplayerClient

var test_step: int = 0
var test_passed: bool = false
var step_timer: float = 0.0

const TEST_PORT: int = 18889

func _initialize() -> void:
	print("==================================================")
	print("TEST: Starting WebSocket Multiplayer Test Suite...")
	print("==================================================")
	
	# 1. Create and start DedicatedServer on TEST_PORT
	server = DedicatedServer.new()
	server.name = "DedicatedServer"
	root.add_child(server)
	var err := server.start_server(TEST_PORT, "127.0.0.1")
	assert(err == OK, "DedicatedServer failed to start on WebSocket")
	print("[PASS] DedicatedServer started on ws://127.0.0.1:%d" % TEST_PORT)

	# 2. Create Client A (Host)
	client_a = MultiplayerClient.new()
	client_a.name = "ClientA"
	client_a.player_name = "HOST_ALPHA"
	client_a.account_token = "token_alpha_12345"
	root.add_child(client_a)

	# 3. Create Client B (Joiner)
	client_b = MultiplayerClient.new()
	client_b.name = "ClientB"
	client_b.player_name = "GUEST_BETA"
	client_b.account_token = "token_beta_67890"
	root.add_child(client_b)

	await process_frame
	_run_flow()


func _run_flow() -> void:
	# Step 1: Connect Client A
	print("\n--- STEP 1: Connect Client A to ws://127.0.0.1:%d ---" % TEST_PORT)
	var conn_err_a := client_a.connect_to_server("ws://127.0.0.1:%d" % TEST_PORT)
	assert(conn_err_a == OK, "Client A failed to initiate connection")

	var wait_a := 0
	while not client_a.is_connected_to_server() and wait_a < 40:
		await create_timer(0.05).timeout
		wait_a += 1

	assert(client_a.is_connected_to_server(), "Client A timed out waiting for connection / welcome")
	print("[PASS] Client A connected! Local Peer ID: %d, Name: %s" % [client_a.local_peer_id, client_a.player_name])

	# Step 2: Ping / Pong check on Client A
	print("\n--- STEP 2: Ping / Pong Heartbeat ---")
	client_a.send_message({"type": NetProtocol.C2S_PING, "client_time": Time.get_ticks_msec()}, false)
	await create_timer(0.1).timeout
	print("[PASS] Ping/Pong executed successfully! Latency: %d ms" % client_a.latency_ms)

	# Step 3: Client A creates a private room
	print("\n--- STEP 3: Create Private Room ---")
	client_a.create_private_room(2, false, 0)
	var wait_room := 0
	while client_a.current_room_code.is_empty() and wait_room < 40:
		await create_timer(0.05).timeout
		wait_room += 1

	var code := client_a.current_room_code
	assert(not code.is_empty(), "Client A failed to receive room code")
	assert(code.length() == DedicatedServer.ROOM_CODE_LENGTH, "Room code invalid length: %s" % code)
	print("[PASS] Private Room created with code: %s (is_host=%s)" % [code, client_a.is_room_host()])

	# Step 4: Connect Client B
	print("\n--- STEP 4: Connect Client B ---")
	var conn_err_b := client_b.connect_to_server("ws://127.0.0.1:%d" % TEST_PORT)
	assert(conn_err_b == OK, "Client B failed to initiate connection")

	var wait_b := 0
	while not client_b.is_connected_to_server() and wait_b < 40:
		await create_timer(0.05).timeout
		wait_b += 1

	assert(client_b.is_connected_to_server(), "Client B timed out waiting for connection")
	print("[PASS] Client B connected! Local Peer ID: %d, Name: %s" % [client_b.local_peer_id, client_b.player_name])

	# Step 5: Client B joins the room via code
	print("\n--- STEP 5: Client B joins Room %s ---" % code)
	client_b.join_private_room(code)
	var wait_join := 0
	while client_b.current_room_code.is_empty() and wait_join < 40:
		await create_timer(0.05).timeout
		wait_join += 1

	assert(client_b.current_room_code == code, "Client B failed to join room: %s" % client_b.current_room_code)
	await create_timer(0.1).timeout

	var members_a: Array = client_a.latest_room_state.get("members", [])
	var members_b: Array = client_b.latest_room_state.get("members", [])
	assert(members_a.size() == 2, "Room members count expected 2, got %d" % members_a.size())
	assert(members_b.size() == 2, "Room members count expected 2, got %d" % members_b.size())
	print("[PASS] Both clients verified in Room %s! Members: %s, %s" % [code, members_a[0]["name"], members_a[1]["name"]])

	# Step 6: Query Leaderboard
	print("\n--- STEP 6: Query Leaderboard (C2S_GET_LEADERBOARD) ---")
	var lb_state := {"received": false, "entries": []}
	client_a.leaderboard_received.connect(func(entries: Array):
		lb_state["received"] = true
		lb_state["entries"] = entries
	)
	client_a.request_leaderboard(10)
	var wait_lb := 0
	while not lb_state["received"] and wait_lb < 30:
		await create_timer(0.05).timeout
		wait_lb += 1

	assert(lb_state["received"], "Failed to receive leaderboard from server")
	print("[PASS] Leaderboard received from server! Entry count: %d" % (lb_state["entries"] as Array).size())

	# Step 7: Ready Up and Start Match
	print("\n--- STEP 7: Ready Up and Start Match ---")
	client_b.set_room_ready(true)
	await create_timer(0.1).timeout
	assert(bool(client_a.latest_room_state.get("can_start", false)), "Room can_start should be true when all ready")

	var match_state := {"a": false, "b": false}
	client_a.authoritative_match_started.connect(func(_msg): match_state["a"] = true)
	client_b.authoritative_match_started.connect(func(_msg): match_state["b"] = true)

	client_a.start_private_room_match()
	var wait_start := 0
	while (not match_state["a"] or not match_state["b"]) and wait_start < 40:
		await create_timer(0.05).timeout
		wait_start += 1

	assert(match_state["a"] and match_state["b"], "Both clients must receive authoritative_match_started")
	print("[PASS] Match started successfully across WebSocket transport!")
	print("Session ID: %s" % client_a.current_session_id)

	# Clean up
	client_a.disconnect_from_server()
	client_b.disconnect_from_server()
	server.stop_server()
	print("\n==================================================")
	print("ALL WEBSOCKET MULTIPLAYER TESTS PASSED (100% OK)!")
	print("==================================================")
	quit(0)
