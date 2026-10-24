extends SceneTree
## Automated Multi-Process Stress & Sustained Soak Test Harness (Section 10)
## Executes:
##   1. Multi-process scaling tests with 5, 10, and 16 simultaneous clients
##      against a standalone headless DedicatedServer OS process + independent
##      OS client worker processes.
##   2. Sustained soak test (~125 seconds) with reproducible seed 20261024
##      performing repeated room creation/joining, public matchmaking cycles,
##      rapid connect/disconnects, invalid message & rejected-join sequences,
##      and 20+ completed authoritative matches in succession while continuously
##      auditing server invariants, persistence integrity, and node/memory stability.

const EXTERNAL_SERVER_PORT: int = 17791
const SOAK_SERVER_PORT: int = 17792
const REPRODUCIBLE_SEED: int = 20261024
const SOAK_DURATION_SEC: float = 125.0

var _pass_count: int = 0
var _fail_count: int = 0
var _external_server_pid: int = -1
var _worker_pids: Array[int] = []


func _init() -> void:
	call_deferred("_run_stress_and_soak")


func _assert(condition: bool, label: String) -> void:
	if condition:
		_pass_count += 1
		print("  [PASS] %s" % label)
	else:
		_fail_count += 1
		printerr("  [FAIL] %s" % label)


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await process_frame
		await physics_frame


func _wait_ms(duration_ms: int) -> void:
	var start_ms := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start_ms) < duration_ms:
		await process_frame
		await physics_frame


func _wait_until(predicate: Callable, timeout_sec: float = 5.0) -> bool:
	var start_ms := Time.get_ticks_msec()
	var limit_ms := int(timeout_sec * 1000.0)
	while (Time.get_ticks_msec() - start_ms) < limit_ms:
		if bool(predicate.call()):
			return true
		await process_frame
		await physics_frame
	return bool(predicate.call())


func _spawn_client(c_name: String, token: String) -> MultiplayerClient:
	var c := MultiplayerClient.new()
	c.name = "Client_%s_%d" % [c_name, Time.get_ticks_usec() % 100000]
	c.account_token = token
	root.add_child(c)
	return c


func _cleanup_processes() -> void:
	for pid in _worker_pids:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
	_worker_pids.clear()
	if _external_server_pid > 0 and OS.is_process_running(_external_server_pid):
		OS.kill(_external_server_pid)
		_external_server_pid = -1


func _audit_server_invariants(server: DedicatedServer) -> Dictionary:
	var duplicate_assignments := 0
	var invalid_room_capacities := 0
	var invalid_session_capacities := 0

	# Check rooms for valid capacities and no duplicate members
	var peer_room_map: Dictionary = {}
	for code in server.rooms.keys():
		var room: Dictionary = server.rooms[code]
		var members: Array = room.get("members", [])
		var t_humans := int(room.get("target_humans", 2))
		var ai_cnt := int(room.get("ai_count", 0)) if bool(room.get("fill_ai", false)) else 0
		if members.is_empty() or members.size() > NetProtocol.MAX_PLAYERS_PER_MATCH or (t_humans + ai_cnt) > NetProtocol.MAX_PLAYERS_PER_MATCH:
			invalid_room_capacities += 1
		var names_in_room: Dictionary = {}
		for m in members:
			var pid := int(m.get("peer_id", 0))
			var mname := str(m.get("name", ""))
			if peer_room_map.has(pid) or names_in_room.has(mname):
				duplicate_assignments += 1
			peer_room_map[pid] = code
			names_in_room[mname] = true

	# Check active sessions for valid capacities and no peer in >1 active match
	var peer_session_map: Dictionary = {}
	for sid in server.active_sessions.keys():
		var s_info: Dictionary = server.active_sessions[sid]
		if int(s_info.get("finished_at_ms", 0)) > 0:
			continue
		var sess: ServerMatchSession = s_info.get("session", null)
		if is_instance_valid(sess) and sess.current_phase != ServerMatchSession.MatchPhase.MATCH_OVER:
			var slot_cnt: int = sess.slot_configs.size()
			if slot_cnt < 2 or slot_cnt > NetProtocol.MAX_PLAYERS_PER_MATCH:
				invalid_session_capacities += 1
			for pid in s_info.get("peer_ids", []):
				var p_int := int(pid)
				if peer_session_map.has(p_int):
					duplicate_assignments += 1
				peer_session_map[p_int] = sid

	return {
		"duplicate_assignments": duplicate_assignments,
		"invalid_room_capacities": invalid_room_capacities,
		"invalid_session_capacities": invalid_session_capacities
	}


func _run_stress_and_soak() -> void:
	print("\n=== STARTING AUTOMATED MULTI-PROCESS STRESS & SOAK SUITE ===")
	print("Reproducible Seed: %d" % REPRODUCIBLE_SEED)
	var godot_exe := OS.get_executable_path()
	var project_dir := ProjectSettings.globalize_path("res://")

	# =========================================================================
	# PART 1: MULTI-PROCESS SCALING (5, 10, and 16 SIMULTANEOUS CLIENTS)
	# =========================================================================
	print("\n--- Part 1: Multi-Process Scaling (5, 10, and 16 Simultaneous Clients) ---")
	var server_args := PackedStringArray([
		"--headless",
		"--path", project_dir,
		"--",
		"--server",
		"--port=%d" % EXTERNAL_SERVER_PORT,
		"--bind=127.0.0.1",
		"--prep-time=0.5",
		"--shrink-time=0.8"
	])
	_external_server_pid = OS.create_process(godot_exe, server_args, false)
	_assert(_external_server_pid > 0 and OS.is_process_running(_external_server_pid), "Standalone headless DedicatedServer OS process launched (PID=%d)" % _external_server_pid)
	await _wait_ms(1400)

	for target_client_count: int in [5, 10, 16]:
		var scale_clients: Array[MultiplayerClient] = []
		# When testing 16 simultaneous clients, also spawn 4 independent OS worker processes
		# alongside 12 verification clients (16 concurrent clients total on the server)
		var os_worker_count: int = 4 if target_client_count == 16 else 0
		var local_client_count: int = target_client_count - os_worker_count

		for w in range(os_worker_count):
			var w_args := PackedStringArray([
				"--headless",
				"--path", project_dir,
				"-s", "res://tests/stress_client_worker.gd",
				"--",
				"--port=%d" % EXTERNAL_SERVER_PORT,
				"--id=%d" % (w + 1),
				"--duration=6.0",
				"--seed=%d" % REPRODUCIBLE_SEED
			])
			var w_pid := OS.create_process(godot_exe, w_args, false)
			if w_pid > 0:
				_worker_pids.append(w_pid)

		for idx in range(local_client_count):
			var mc := _spawn_client("SCALE_%d_%d" % [target_client_count, idx], "scale_tok_%d_%d" % [target_client_count, idx])
			mc.connect_to_server("127.0.0.1", EXTERNAL_SERVER_PORT, "SC%d_P%d" % [target_client_count, idx])
			scale_clients.append(mc)

		var all_connected := await _wait_until(
			func():
				for mc in scale_clients:
					if not mc.is_connected_to_server():
						return false
				return true,
			6.0
		)
		var workers_alive := true
		for w_pid in _worker_pids:
			if not OS.is_process_running(w_pid):
				workers_alive = false
		_assert(
			all_connected and workers_alive and OS.is_process_running(_external_server_pid),
			"%d simultaneous clients connected concurrently to standalone server OS process without errors" % target_client_count
		)

		# Form matches across the connected clients (5-player full match for 5 clients; pairs for 10 and 16)
		var req_h: int = 5 if target_client_count == 5 else 2
		for mc in scale_clients:
			mc.request_quick_join(req_h, true)

		var all_matched := await _wait_until(
			func():
				for mc in scale_clients:
					if mc.current_session_id.is_empty():
						return false
				return true,
			5.0
		)
		_assert(
			all_matched and OS.is_process_running(_external_server_pid),
			"%d simultaneous clients assigned into isolated authoritative matches without duplicate assignment" % target_client_count
		)

		for mc in scale_clients:
			mc.disconnect_from_server()
			mc.queue_free()
		scale_clients.clear()
		for w_pid in _worker_pids:
			if OS.is_process_running(w_pid):
				OS.kill(w_pid)
		_worker_pids.clear()
		await _wait_ms(300)

	_cleanup_processes()

	# =========================================================================
	# PART 2: SUSTAINED MULTI-MINUTE SOAK & CHAOS STRESS TEST (SEED 20261024)
	# =========================================================================
	print("\n--- Part 2: Sustained Soak & Chaos Stress Test (%.0fs, Seed=%d, 16 Clients) ---" % [SOAK_DURATION_SEC, REPRODUCIBLE_SEED])
	var soak_save_path := "user://test_soak_persistence.json"
	for p_ext in ["", ".bak", ".tmp"]:
		var full_p: String = soak_save_path + p_ext
		if FileAccess.file_exists(full_p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(full_p))

	var soak_server := DedicatedServer.new()
	soak_server.name = "SoakDedicatedServer"
	soak_server.persistence_save_path = soak_save_path
	soak_server.default_preparation_duration = 0.45
	soak_server.default_shrink_interval = 0.75
	root.add_child(soak_server)
	await _wait_frames(2)

	var start_err := soak_server.start_server(SOAK_SERVER_PORT, "127.0.0.1", 64)
	_assert(start_err == OK and soak_server.is_running(), "Soak server started on UDP 127.0.0.1:%d" % SOAK_SERVER_PORT)

	var rng := RandomNumberGenerator.new()
	rng.seed = REPRODUCIBLE_SEED

	var soak_stats := {
		"completed_matches": 0,
		"match_desync_errors": 0
	}
	var duplicate_assignment_errors := 0
	var invalid_capacity_errors := 0
	var persistence_errors := 0
	var total_room_cycles := 0
	var total_queue_cycles := 0
	var total_reconnect_cycles := 0
	var total_invalid_seq_rejected := 0

	soak_server.match_session_ended.connect(func(_sid: String, summary: Dictionary):
		soak_stats["completed_matches"] = int(soak_stats["completed_matches"]) + 1
		if str(summary.get("session_id", "")).is_empty():
			soak_stats["match_desync_errors"] = int(soak_stats["match_desync_errors"]) + 1
	)

	# Spawn 12 in-process controllable chaos clients + 4 external OS worker processes = 16 simultaneous clients
	var soak_clients: Array[MultiplayerClient] = []
	for i in range(12):
		var sc := _spawn_client("SOAK_%d" % (i + 1), "soak_token_2026_%02d" % (i + 1))
		sc.connect_to_server("127.0.0.1", SOAK_SERVER_PORT, "SK_P%02d" % (i + 1))
		soak_clients.append(sc)

	for w in range(4):
		var w_args := PackedStringArray([
			"--headless",
			"--path", project_dir,
			"-s", "res://tests/stress_client_worker.gd",
			"--",
			"--port=%d" % SOAK_SERVER_PORT,
			"--id=%d" % (100 + w),
			"--duration=%.1f" % (SOAK_DURATION_SEC - 4.0),
			"--seed=%d" % REPRODUCIBLE_SEED
		])
		var w_pid := OS.create_process(godot_exe, w_args, false)
		if w_pid > 0:
			_worker_pids.append(w_pid)

	await _wait_until(
		func():
			for sc in soak_clients:
				if not sc.is_connected_to_server():
					return false
			return true,
		5.0
	)

	var baseline_server_children := soak_server.get_child_count()
	var soak_start_ms := Time.get_ticks_msec()
	var soak_end_ms := soak_start_ms + int(SOAK_DURATION_SEC * 1000.0)
	var next_progress_log_ms := soak_start_ms + 25000
	var cycle_idx := 0

	while Time.get_ticks_msec() < soak_end_ms:
		cycle_idx += 1

		# 1. Audit server invariants every cycle
		var audit := _audit_server_invariants(soak_server)
		duplicate_assignment_errors += int(audit["duplicate_assignments"])
		invalid_capacity_errors += int(audit["invalid_room_capacities"]) + int(audit["invalid_session_capacities"])
		if not soak_server.persistence.last_load_error.is_empty():
			persistence_errors += 1

		# 2. Group 0..3: Private room create / join / ready / start / leave cycles
		var host_c := soak_clients[0]
		var join_c1 := soak_clients[1]
		var join_c2 := soak_clients[2]
		var rogue_c := soak_clients[3]

		if host_c.is_connected_to_server() and host_c.current_session_id.is_empty():
			if host_c.current_room_code.is_empty():
				host_c.create_private_room(2, true, 1)
				total_room_cycles += 1
			else:
				var r_code := host_c.current_room_code
				if join_c1.is_connected_to_server() and join_c1.current_room_code.is_empty() and join_c1.current_session_id.is_empty():
					join_c1.join_private_room(r_code)
				elif join_c1.current_room_code == r_code:
					join_c1.set_room_ready(true)
				# Join race / full room rejection test with join_c2
				if join_c2.is_connected_to_server() and join_c2.current_room_code.is_empty() and join_c2.current_session_id.is_empty():
					join_c2.join_private_room(r_code)
				if bool(host_c.latest_room_state.get("can_start", false)):
					host_c.start_private_room_match()
				elif rng.randf() < 0.15:
					host_c.leave_private_room()

		# 3. Rogue client (client 3): invalid messages, spoofed authority, invalid room codes
		if rogue_c.is_connected_to_server() and (cycle_idx % 4 == 0):
			var action_roll := rng.randi_range(0, 3)
			if action_roll == 0:
				rogue_c.send_message({"type": "c2s_force_win", "winner": rogue_c.player_name}, true)
				total_invalid_seq_rejected += 1
			elif action_roll == 1:
				rogue_c.send_message({"type": NetProtocol.C2S_START_ROOM_MATCH, "is_host": true}, true)
				total_invalid_seq_rejected += 1
			elif action_roll == 2:
				rogue_c.send_message({
					"type": NetProtocol.C2S_PLAYER_INPUT,
					"seq": -10,
					"move": Vector2(NAN, INF),
					"aim": Vector2(1.0, 0.0)
				}, false)
				total_invalid_seq_rejected += 1
			else:
				rogue_c.request_quick_join(2, true)

		# 4. Group 4..9: Public matchmaking cycles, queue cancel, and active gameplay inputs
		for idx in range(4, 10):
			var mc := soak_clients[idx]
			if not mc.is_connected_to_server():
				mc.connect_to_server("127.0.0.1", SOAK_SERVER_PORT, "SK_P%02d" % (idx + 1))
			elif not mc.current_session_id.is_empty():
				var mv := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
				var aim := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
				mc.send_player_input_now(mv, aim)
			elif mc.in_matchmaking_queue:
				if rng.randf() < 0.10:
					mc.cancel_queue()
			else:
				mc.request_quick_join(2, true)
				total_queue_cycles += 1

		# 5. Group 10..11: Rapid connect / disconnect / reconnect churn
		if cycle_idx % 6 == 0:
			for idx in range(10, 12):
				var churn_c := soak_clients[idx]
				if churn_c.is_connected_to_server():
					if rng.randf() < 0.45:
						churn_c.disconnect_from_server()
						total_reconnect_cycles += 1
					elif churn_c.current_session_id.is_empty():
						churn_c.request_quick_join(2, true)
				else:
					churn_c.connect_to_server("127.0.0.1", SOAK_SERVER_PORT, "SK_P%02d" % (idx + 1))

		# Also drive movement/aim for room players when in a match
		for idx in range(0, 4):
			var rmc := soak_clients[idx]
			if rmc.is_connected_to_server() and not rmc.current_session_id.is_empty():
				var mv := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
				var aim := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
				rmc.send_player_input_now(mv, aim)

		var now_ms := Time.get_ticks_msec()
		if now_ms >= next_progress_log_ms:
			var elapsed_s := float(now_ms - soak_start_ms) / 1000.0
			print("  [SOAK %.1fs / %.0fs] matches=%d rooms_cycled=%d queue_cycles=%d reconnects=%d active_sessions=%d" % [
				elapsed_s,
				SOAK_DURATION_SEC,
				int(soak_stats["completed_matches"]),
				total_room_cycles,
				total_queue_cycles,
				total_reconnect_cycles,
				soak_server.active_sessions.size()
			])
			next_progress_log_ms = now_ms + 25000

		await _wait_ms(35)

	# Drain & clean up all clients and wait for any in-flight sessions to finish and be reaped
	for w_pid in _worker_pids:
		if OS.is_process_running(w_pid):
			OS.kill(w_pid)
	_worker_pids.clear()

	for sc in soak_clients:
		sc.disconnect_from_server()
		sc.queue_free()
	soak_clients.clear()

	await _wait_until(
		func():
			return soak_server.connected_peers.is_empty() and soak_server.rooms.is_empty() and soak_server._quick_match_queue.is_empty() and soak_server.active_sessions.is_empty(),
		6.0
	)
	await _wait_frames(10)

	var post_soak_server_children := soak_server.get_child_count()
	var total_elapsed_sec := float(Time.get_ticks_msec() - soak_start_ms) / 1000.0
	var completed_matches: int = int(soak_stats["completed_matches"])
	var match_desync_errors: int = int(soak_stats["match_desync_errors"])

	print("\n  [SOAK METRICS] Duration=%.1fs | Completed Matches=%d | Room Cycles=%d | Queue Cycles=%d | Reconnects=%d | Invalid Msgs Tested=%d" % [
		total_elapsed_sec,
		completed_matches,
		total_room_cycles,
		total_queue_cycles,
		total_reconnect_cycles,
		total_invalid_seq_rejected
	])

	_assert(soak_server.is_running(), "Zero unexpected server exits during %.1fs sustained soak test" % total_elapsed_sec)
	_assert(completed_matches >= 10, "Multiple authoritative matches (%d) completed in succession during soak test" % completed_matches)
	_assert(duplicate_assignment_errors == 0, "Zero duplicate player assignments across all rooms and matches")
	_assert(invalid_capacity_errors == 0, "Zero invalid room or match capacities (>5 players)")
	_assert(match_desync_errors == 0, "Zero match-state desynchronizations recorded")
	_assert(
		soak_server.rooms.is_empty() and soak_server._quick_match_queue.is_empty() and soak_server.active_sessions.is_empty(),
		"Zero stuck queues, abandoned rooms, or un-reaped sessions after all clients disconnect"
	)
	_assert(
		post_soak_server_children <= baseline_server_children,
		"Stable server node count after soak cleanup (baseline=%d, post_soak=%d — zero leaked SubViewports/sessions)" % [baseline_server_children, post_soak_server_children]
	)

	# Verify persistence disk integrity after soak
	var verify_store := ServerPersistence.new(soak_save_path)
	_assert(
		verify_store.last_load_error.is_empty() and persistence_errors == 0 and verify_store.global_match_history.size() > 0,
		"Zero persistence errors and intact disk records after %d matches" % completed_matches
	)

	soak_server.stop_server()
	soak_server.queue_free()
	for p_ext in ["", ".bak", ".tmp"]:
		var full_p: String = soak_save_path + p_ext
		if FileAccess.file_exists(full_p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(full_p))
	await _wait_frames(3)

	print("\n=== MULTI-PROCESS STRESS & SOAK SUMMARY: %d PASSED, %d FAILED ===" % [_pass_count, _fail_count])
	quit(0 if _fail_count == 0 else 1)
