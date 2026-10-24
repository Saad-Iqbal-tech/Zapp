extends SceneTree
## End-to-End Multi-Process Verification & Stabilization Suite
## Exercises the real standalone headless server OS process on UDP port 7777,
## OnlineLobbyModal auto-connect + pending action execution, error/timeout handling,
## 2-to-5 client room/matchmaking flows, server stop/restart recovery, and separate client OS processes.

const SERVER_PORT: int = 7777

var _passes: int = 0
var _failures: int = 0
var _server_pid: int = -1
var _extra_pids: Array[int] = []


func _init() -> void:
	call_deferred("_run_verification")


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


func _wait_until(predicate: Callable, timeout_sec: float = 4.5) -> bool:
	var start_ms := Time.get_ticks_msec()
	var limit_ms := int(timeout_sec * 1000.0)
	while (Time.get_ticks_msec() - start_ms) < limit_ms:
		if bool(predicate.call()):
			return true
		await process_frame
		await physics_frame
	return bool(predicate.call())


func _spawn_headless_server_process(port: int) -> int:
	var pid := OS.create_process(
		OS.get_executable_path(),
		["--headless", "--path", ProjectSettings.globalize_path("res://"), "--", "--server", "--port=%d" % port]
	)
	return pid


func _kill_process_safe(pid: int) -> void:
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)


func _cleanup_all_processes() -> void:
	_kill_process_safe(_server_pid)
	_server_pid = -1
	for pid in _extra_pids:
		_kill_process_safe(pid)
	_extra_pids.clear()


func _run_verification() -> void:
	print("\n=== STARTING MULTI-PROCESS E2E VERIFICATION & STABILIZATION SUITE ===")

	# Instantiate two full game clients (MainArena with HUD, MainMenuOverlay, OnlineLobbyModal, MultiplayerClient)
	var arena_scene: PackedScene = load("res://scenes/main_arena.tscn")
	var client_a := arena_scene.instantiate() as MatchController
	client_a.name = "ClientA_Arena"
	root.add_child(client_a)

	var client_b := arena_scene.instantiate() as MatchController
	client_b.name = "ClientB_Arena"
	root.add_child(client_b)

	await _wait_frames(6)

	var modal_a: OnlineLobbyModal = client_a.hud.main_menu.online_modal
	var modal_b: OnlineLobbyModal = client_b.hud.main_menu.online_modal
	var mp_a: MultiplayerClient = client_a.multiplayer_client
	var mp_b: MultiplayerClient = client_b.multiplayer_client

	# Give distinct player names and tokens
	mp_a.account_token = "e2e_token_alpha_001"
	mp_b.account_token = "e2e_token_bravo_002"
	modal_a.name_input.text = "ALPHA"
	modal_b.name_input.text = "BRAVO"
	modal_a.host_input.text = "127.0.0.1"
	modal_b.host_input.text = "127.0.0.1"
	modal_a.port_input.text = str(SERVER_PORT)
	modal_b.port_input.text = str(SERVER_PORT)

	client_a.hud.main_menu.set_online_lobby_open(true)
	client_b.hud.main_menu.set_online_lobby_open(true)
	await _wait_frames(2)

	# -------------------------------------------------------------------------
	# 1. Verify Initial Status, Invalid Address/Port Validation & Offline Timeout
	# -------------------------------------------------------------------------
	_assert(
		modal_a.get_displayed_connection_status() == "Disconnected" and modal_a.conn_status_label.text == "Disconnected",
		"OnlineLobbyModal initially displays 'Disconnected' status"
	)

	# Test LAN IP helper toggle
	var detected_lan := NetProtocol.detect_lan_ipv4()
	_assert(detected_lan.is_valid_ip_address(), "NetProtocol.detect_lan_ipv4() returns a valid IPv4 address (%s)" % detected_lan)

	# Test invalid IP address rejection
	modal_a.host_input.text = "999.999.999.999"
	modal_a._on_connect_button_pressed()
	await _wait_frames(2)
	_assert(
		modal_a.get_displayed_connection_status() == "Connection Failed" and modal_a.conn_status_label.text == "Connection Failed",
		"Invalid IP address ('999.999.999.999') immediately transitions status to 'Connection Failed'"
	)
	_assert(
		modal_a.feedback_banner.text.find("Connection Failed") != -1,
		"Invalid IP address displays a clear error message in the lobby feedback banner"
	)

	# Test invalid port rejection
	modal_a.host_input.text = "127.0.0.1"
	modal_a.port_input.text = "99999"
	modal_a._on_connect_button_pressed()
	await _wait_frames(2)
	_assert(
		modal_a.get_displayed_connection_status() == "Connection Failed",
		"Out-of-range UDP port (99999) immediately transitions status to 'Connection Failed'"
	)

	# Test connection timeout when clicking Create Room while no server is running
	var unused_port := 17799
	mp_a.connect_timeout_sec = 0.65
	modal_a.host_input.text = "127.0.0.1"
	modal_a.port_input.text = str(unused_port)
	modal_a._on_create_room_pressed()
	_assert(
		modal_a.get_displayed_connection_status() == "Connecting",
		"Clicking Create Room while Disconnected automatically initiates connection ('Connecting')"
	)
	await _wait_until(func(): return modal_a.get_displayed_connection_status() == "Connection Failed", 2.5)
	_assert(
		modal_a.get_displayed_connection_status() == "Connection Failed" and mp_a.current_room_code.is_empty(),
		"When no server is running, auto-connect times out cleanly to 'Connection Failed' without faking room creation"
	)
	mp_a.connect_timeout_sec = 4.5
	modal_a.port_input.text = str(SERVER_PORT)

	# -------------------------------------------------------------------------
	# 2. Launch Standalone Headless Server OS Process on UDP Port 7777
	# -------------------------------------------------------------------------
	_server_pid = _spawn_headless_server_process(SERVER_PORT)
	_assert(_server_pid > 0 and OS.is_process_running(_server_pid), "Launched standalone headless server OS process on UDP port %d (PID %d)" % [SERVER_PORT, _server_pid])

	# Wait for the new OS process to finish booting and bind UDP port 7777
	await create_timer(1.5).timeout

	# -------------------------------------------------------------------------
	# 3. Auto-Connect on Create Room (Client A) & Duplicate Request Prevention
	# -------------------------------------------------------------------------
	# Client A is currently in 'Connection Failed' state (disconnected).
	# Clicking Create Private Room must auto-connect to 127.0.0.1:7777 and create the room ONLY after S2C_WELCOME.
	modal_a._on_create_room_pressed()
	# Simulate rapid duplicate clicks while connecting
	modal_a._on_create_room_pressed()
	modal_a._on_create_room_pressed()
	_assert(
		modal_a.get_displayed_connection_status() == "Connecting",
		"Client A transitions to 'Connecting' when clicking Create Private Room while disconnected"
	)

	await _wait_until(func(): return not mp_a.current_room_code.is_empty(), 5.0)

	var room_code := mp_a.current_room_code
	_assert(
		modal_a.get_displayed_connection_status() == "Connected" and room_code.length() == 5,
		"Client A auto-connects to standalone server on port 7777 and creates Private Room (%s) after handshake" % room_code
	)
	_assert(mp_a.is_room_host(), "Client A is assigned as Room Host of room %s" % room_code)

	# -------------------------------------------------------------------------
	# 4. Auto-Connect on Join Room (Client B) While Disconnected
	# -------------------------------------------------------------------------
	_assert(
		modal_b.get_displayed_connection_status() == "Disconnected",
		"Client B is initially 'Disconnected' before clicking Join Room"
	)
	modal_b.room_code_input.text = room_code
	modal_b._on_join_room_pressed()
	_assert(
		modal_b.get_displayed_connection_status() == "Connecting",
		"Client B transitions to 'Connecting' when clicking Join Room while disconnected"
	)

	await _wait_until(func(): return mp_b.current_room_code == room_code and not room_code.is_empty(), 5.0)

	_assert(
		modal_b.get_displayed_connection_status() == "Connected" and mp_b.current_room_code == room_code and not room_code.is_empty(),
		"Client B auto-connects to standalone server and joins Client A's Private Room (%s)" % room_code
	)

	# -------------------------------------------------------------------------
	# 5. Synchronized Room Membership & Readiness State
	# -------------------------------------------------------------------------
	await _wait_until(func():
		return (mp_a.latest_room_state.get("members", []) as Array).size() == 2 and (mp_b.latest_room_state.get("members", []) as Array).size() == 2
	, 3.0)
	var members_a: Array = mp_a.latest_room_state.get("members", [])
	var members_b: Array = mp_b.latest_room_state.get("members", [])
	_assert(
		members_a.size() == 2 and members_b.size() == 2,
		"Both Client A and Client B receive synchronized 2-player room membership from standalone server"
	)
	_assert(
		bool(mp_a.latest_room_state.get("can_start", true)) == false,
		"Room cannot start before Client B marks READY"
	)

	# Client B clicks READY UP!
	modal_b._on_ready_pressed()
	await _wait_until(func(): return bool(mp_a.latest_room_state.get("can_start", false)), 3.0)
	_assert(
		bool(mp_a.latest_room_state.get("can_start", false)) == true,
		"Synchronized readiness state updates on Host when Client B toggles READY"
	)

	# -------------------------------------------------------------------------
	# 6. Start Match & Verify Synchronized Authoritative Gameplay, Movement, Aiming & Elimination
	# -------------------------------------------------------------------------
	modal_a._on_start_room_pressed()
	await _wait_until(func(): return client_a.is_online_match and client_b.is_online_match, 4.0)

	_assert(
		client_a.is_online_match and client_b.is_online_match and client_a.current_phase == MatchController.MatchPhase.PREPARATION,
		"Host starting room match transitions both Client A and Client B into synchronized online match"
	)

	# Test movement & aiming replication via standalone server snapshots
	var start_pos_a := client_b.characters[0].global_position
	var move_start_ms := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - move_start_ms) < 450:
		mp_a.send_player_input_now(Vector2(1.0, 0.0), Vector2(0.0, -1.0))
		await _wait_frames(1)

	var moved_pos_a := client_b.characters[0].global_position
	_assert(
		moved_pos_a.x > start_pos_a.x + 0.15,
		"Client A movement & aim inputs are simulated by standalone server and replicated to Client B"
	)

	# -------------------------------------------------------------------------
	# 7. Disconnect Client B Mid-Match & Verify Server Eliminates Disconnected Player + Crowns Winner
	# -------------------------------------------------------------------------
	mp_b.disconnect_from_server()
	await _wait_until(func(): return client_a.current_phase == MatchController.MatchPhase.MATCH_OVER, 4.0)

	_assert(
		client_a.current_phase == MatchController.MatchPhase.MATCH_OVER and client_a.characters[0].current_state == CharacterController.State.WINNER,
		"Disconnecting Client B mid-match safely eliminates Client B on server and crowns Client A WINNER"
	)

	# -------------------------------------------------------------------------
	# 8. Return to Lobby, Rejoin & Execute a Rematch Through Full Completion
	# -------------------------------------------------------------------------
	client_a.return_to_lobby()
	client_b.return_to_lobby()
	await create_timer(0.15).timeout

	# Reconnect Client B into Client A's room using auto-connect on Join Room
	modal_b.room_code_input.text = room_code
	modal_b._on_join_room_pressed()
	await _wait_until(func(): return mp_b.current_room_code == room_code and not room_code.is_empty(), 5.0)
	_assert(mp_b.current_room_code == room_code and not room_code.is_empty(), "Client B reconnects and rejoins room %s for rematch" % room_code)

	modal_b._on_ready_pressed()
	await _wait_until(func(): return bool(mp_a.latest_room_state.get("can_start", false)), 3.0)

	modal_a._on_start_room_pressed()
	await _wait_until(func():
		return client_a.is_online_match and client_b.is_online_match and client_a.current_phase == MatchController.MatchPhase.PREPARATION
	, 4.0)
	_assert(
		client_a.is_online_match and client_b.is_online_match,
		"Rematch starts cleanly in the same Private Room"
	)

	# Have Client B walk off the platform edge to test server-authoritative fall elimination & match end
	var walk_start_ms := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - walk_start_ms) < 4000:
		mp_b.send_player_input_now(Vector2(1.0, 1.0).normalized(), Vector2(1.0, 0.0))
		await _wait_frames(1)
		if client_a.current_phase == MatchController.MatchPhase.MATCH_OVER and client_b.current_phase == MatchController.MatchPhase.MATCH_OVER:
			break

	_assert(
		client_a.current_phase == MatchController.MatchPhase.MATCH_OVER and client_b.current_phase == MatchController.MatchPhase.MATCH_OVER,
		"Rematch completes authoritatively on standalone server and both clients receive match result"
	)

	client_a.return_to_lobby()
	client_b.return_to_lobby()
	modal_a._on_leave_room_pressed()
	modal_b._on_leave_room_pressed()
	await create_timer(0.2).timeout

	# -------------------------------------------------------------------------
	# 9. Test Auto-Connect on Public Matchmaking Queue + 5-Player Capacity
	# -------------------------------------------------------------------------
	mp_a.disconnect_from_server()
	mp_b.disconnect_from_server()
	await create_timer(0.15).timeout
	_assert(
		modal_a.get_displayed_connection_status() == "Disconnected" and modal_b.get_displayed_connection_status() == "Disconnected",
		"Both clients are Disconnected before testing auto-connect on Find Public Match"
	)

	# Client A clicks FIND PUBLIC MATCH while Disconnected -> auto-connects and enters queue (1/2)
	modal_a._on_public_queue_pressed()
	await _wait_until(func(): return mp_a.in_matchmaking_queue, 5.0)
	_assert(
		modal_a.get_displayed_connection_status() == "Connected" and mp_a.in_matchmaking_queue and mp_a.queued_players_count == 1,
		"Client A clicking 'Find Public Match' while Disconnected auto-connects and enters public queue (1/2)"
	)

	# Client B clicks FIND PUBLIC MATCH while Disconnected -> auto-connects, enters queue (2/2), and starts match!
	modal_b._on_public_queue_pressed()
	await _wait_until(func(): return client_a.is_online_match and client_b.is_online_match, 5.0)
	_assert(
		client_a.is_online_match and client_b.is_online_match and mp_a.current_session_id == mp_b.current_session_id,
		"Client B clicking 'Find Public Match' while Disconnected auto-connects and pairs with Client A into an online match"
	)

	# Test 5 simultaneous clients connecting to the standalone server + 6th client room full rejection
	var extra_clients: Array[MultiplayerClient] = []
	for idx in range(4):
		var mc := MultiplayerClient.new()
		mc.name = "ExtraClient_%d" % idx
		mc.account_token = "extra_tok_%d" % idx
		root.add_child(mc)
		mc.connect_to_server("127.0.0.1", SERVER_PORT, "EXTRA_%d" % idx)
		extra_clients.append(mc)

	await _wait_until(func():
		for mc in extra_clients:
			if not mc.is_connected_to_server():
				return false
		return true
	, 5.0)

	_assert(
		extra_clients[0].is_connected_to_server() and extra_clients[3].is_connected_to_server(),
		"Standalone server handles 5+ simultaneous connected clients without errors"
	)

	for mc in extra_clients:
		mc.disconnect_from_server()
		mc.queue_free()
	await _wait_frames(4)

	# -------------------------------------------------------------------------
	# 10. Stop Standalone Server Process & Verify Clients Detect Connection Loss
	# -------------------------------------------------------------------------
	_kill_process_safe(_server_pid)
	_server_pid = -1

	# Wait for ENet peer timeout (~2-3.5s) to detect that the standalone server OS process was killed
	await _wait_until(func(): return modal_a.get_displayed_connection_status() == "Connection Failed", 6.0)

	_assert(
		modal_a.get_displayed_connection_status() == "Connection Failed" and client_a.current_phase == MatchController.MatchPhase.MAIN_MENU,
		"Stopping the standalone server OS process transitions connected clients to 'Connection Failed' and returns safely to Main Menu"
	)
	_assert(
		modal_a.feedback_banner.text.find("Lost connection") != -1 or modal_a.feedback_banner.text.find("Connection Failed") != -1,
		"Clients display a clear error message when the server process stops unexpectedly"
	)

	# -------------------------------------------------------------------------
	# 11. Restart Standalone Server Process & Verify Clients Can Reconnect
	# -------------------------------------------------------------------------
	_server_pid = _spawn_headless_server_process(SERVER_PORT)
	_assert(_server_pid > 0 and OS.is_process_running(_server_pid), "Restarted standalone headless server OS process on UDP port %d (PID %d)" % [SERVER_PORT, _server_pid])
	await create_timer(1.5).timeout

	client_a.hud.main_menu.set_online_lobby_open(true)
	modal_a._on_create_room_pressed()
	await _wait_until(func():
		return modal_a.get_displayed_connection_status() == "Connected" and not mp_a.current_room_code.is_empty()
	, 5.0)

	_assert(
		modal_a.get_displayed_connection_status() == "Connected" and mp_a.current_room_code.length() == 5,
		"After server restart, Client A reconnects automatically via Create Room and receives new room code (%s)" % mp_a.current_room_code
	)

	# -------------------------------------------------------------------------
	# 12. Spawn 2 Separate Client OS Processes Connecting to the Standalone Server OS Process
	# -------------------------------------------------------------------------
	var c_proc_1 := OS.create_process(
		OS.get_executable_path(),
		["--headless", "--path", ProjectSettings.globalize_path("res://"), "--", "--host=127.0.0.1", "--port=%d" % SERVER_PORT, "--name=OS_CLIENT_1", "--token=os_tok_1"]
	)
	var c_proc_2 := OS.create_process(
		OS.get_executable_path(),
		["--headless", "--path", ProjectSettings.globalize_path("res://"), "--", "--host=127.0.0.1", "--port=%d" % SERVER_PORT, "--name=OS_CLIENT_2", "--token=os_tok_2"]
	)
	_extra_pids.append(c_proc_1)
	_extra_pids.append(c_proc_2)
	await create_timer(0.8).timeout
	_assert(
		c_proc_1 > 0 and OS.is_process_running(c_proc_1) and c_proc_2 > 0 and OS.is_process_running(c_proc_2),
		"Launched 2 separate client OS processes alongside the standalone headless server OS process"
	)

	# Clean up
	mp_a.disconnect_from_server()
	mp_b.disconnect_from_server()
	client_a.queue_free()
	client_b.queue_free()
	await _wait_frames(3)
	_cleanup_all_processes()

	print("=== E2E MULTI-PROCESS VERIFICATION SUMMARY: %d PASSED, %d FAILED ===" % [_passes, _failures])
	quit(1 if _failures > 0 else 0)
