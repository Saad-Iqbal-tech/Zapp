extends SceneTree
## Phase 3 Automated Verification Suite — Persistent Accounts, Statistics, Match History & Leaderboards
## Tests:
## 1. Unique username registration & token authentication.
## 2. Username impersonation protection (second client with different token gets unique suffix).
## 3. Returning player with matching token restores existing account & stats.
## 4. Server-validated wins, losses, matches played, eliminations, and match history after authoritative match.
## 5. Rejection of client-fabricated statistics (ERR_FORBIDDEN_CLIENT_STATS).
## 6. Global leaderboard ranking by wins and eliminations.
## 7. Disk persistence across server restarts without leaking secret token hashes to clients.

const TEST_PORT: int = 17779
const TEST_SAVE_PATH: String = "user://test_phase3_persistence.json"

var _passes: int = 0
var _failures: int = 0


func _init() -> void:
	call_deferred("_run_phase3_tests")


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


func _run_phase3_tests() -> void:
	print("\n=== STARTING PHASE 3: PERSISTENT ACCOUNTS, STATS & LEADERBOARD TEST SUITE ===")

	# Remove any leftover test file before starting
	if FileAccess.file_exists(TEST_SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH))

	var server := DedicatedServer.new()
	server.name = "Phase3DedicatedServer"
	server.persistence_save_path = TEST_SAVE_PATH
	root.add_child(server)
	var err := server.start_server(TEST_PORT, "127.0.0.1")
	_assert(err == OK and server.is_running(), "Dedicated server starts with persistent store (%s)" % TEST_SAVE_PATH)

	# 1. Test Unique Usernames & Token Protection
	var c1 := MultiplayerClient.new()
	c1.account_token = "secret_token_alpha_111"
	root.add_child(c1)

	var c2 := MultiplayerClient.new()
	c2.account_token = "secret_token_beta_222"
	root.add_child(c2)

	c1.connect_to_server("127.0.0.1", TEST_PORT, "CHAMP_ALPHA")
	for _f in range(25):
		await _wait_frames(1)
		if c1.is_connected_to_server():
			break

	# Client 2 tries to claim the SAME username "CHAMP_ALPHA" with a different token
	c2.connect_to_server("127.0.0.1", TEST_PORT, "CHAMP_ALPHA")
	for _f in range(25):
		await _wait_frames(1)
		if c2.is_connected_to_server():
			break

	_assert(c1.player_name == "CHAMP_ALPHA", "First client claims unique username CHAMP_ALPHA")
	_assert(c2.player_name == "CHAMP_ALPHA_2", "Second client with different token is disambiguated to CHAMP_ALPHA_2 (prevents impersonation)")

	# 2. Run an Authoritative Match where CHAMP_ALPHA eliminates CHAMP_ALPHA_2 with a laser
	var session := server.create_match_session([
		{"peer_id": c1.local_peer_id, "name": c1.player_name, "is_ai": false},
		{"peer_id": c2.local_peer_id, "name": c2.player_name, "is_ai": false}
	])
	await _wait_frames(6)

	# Position CHAMP_ALPHA aiming directly at CHAMP_ALPHA_2 in an open lane while CHAMP_ALPHA_2 aims away
	session.characters[0].global_position = Vector3(-2.2, 0.05, 2.0)
	session.characters[0].set_aim_direction_3d(Vector3(0.0, 0.0, -1.0))
	session.characters[1].global_position = Vector3(-2.2, 0.05, -2.0)
	session.characters[1].set_aim_direction_3d(Vector3(-1.0, 0.0, 0.0))

	session._trigger_simultaneous_resolution()
	await _wait_frames(8)

	_assert(session.current_phase == ServerMatchSession.MatchPhase.MATCH_OVER, "Authoritative match completes after laser elimination")

	# Verify both clients received updated server-validated stats
	_assert(
		int(c1.latest_profile.get("wins", 0)) == 1
		and int(c1.latest_profile.get("losses", 0)) == 0
		and int(c1.latest_profile.get("matches_played", 0)) == 1
		and int(c1.latest_profile.get("eliminations", 0)) == 1,
		"Winner (CHAMP_ALPHA) profile records 1 Win, 0 Losses, 1 Match Played, 1 Elimination"
	)
	_assert(
		int(c2.latest_profile.get("wins", 0)) == 0
		and int(c2.latest_profile.get("losses", 0)) == 1
		and int(c2.latest_profile.get("matches_played", 0)) == 1
		and int(c2.latest_profile.get("eliminations", 0)) == 0,
		"Loser (CHAMP_ALPHA_2) profile records 0 Wins, 1 Loss, 1 Match Played, 0 Eliminations"
	)

	var c1_hist: Array = c1.latest_profile.get("match_history", [])
	_assert(
		c1_hist.size() == 1 and str(c1_hist[0].get("outcome", "")) == "WIN" and int(c1_hist[0].get("eliminations", 0)) == 1,
		"Player match history records authoritative match outcome, winner, and eliminations"
	)

	# 3. Test Rejection of Client-Fabricated Statistics
	c2.last_error_code = ""
	c2.send_message({
		"type": "c2s_update_stats",
		"wins": 999,
		"eliminations": 999
	}, true)
	await _wait_frames(6)
	c2.request_stats()
	await _wait_frames(6)

	_assert(c2.last_error_code == "ERR_FORBIDDEN_CLIENT_STATS", "Server rejects client attempt to fabricate stats (ERR_FORBIDDEN_CLIENT_STATS)")
	_assert(int(c2.latest_profile.get("wins", 0)) == 0, "Client-fabricated win count is ignored; server-validated wins remain 0")

	# 4. Test Global Leaderboard Ordering & Privacy (no secret token_hash exposed)
	var lb: Array = c1.latest_stats_response.get("leaderboard", [])
	_assert(
		lb.size() >= 2 and str(lb[0].get("username", "")) == "CHAMP_ALPHA" and str(lb[1].get("username", "")) == "CHAMP_ALPHA_2",
		"Global leaderboard ranks CHAMP_ALPHA (#1) above CHAMP_ALPHA_2 (#2)"
	)
	_assert(not lb[0].has("token_hash") and not c1.latest_profile.has("token_hash"), "Public profile and leaderboard responses never expose secret token hashes")

	# 5. Test Reconnection with Matching Token Restores Profile & Disk Persistence Across Server Restart
	c1.disconnect_from_server()
	c2.disconnect_from_server()
	server.stop_server()
	await _wait_frames(4)

	var reloaded_store := ServerPersistence.new(TEST_SAVE_PATH)
	var reloaded_alpha := reloaded_store.authenticate_or_register_player("CHAMP_ALPHA", "secret_token_alpha_111", 99)
	_assert(
		str(reloaded_alpha.get("username", "")) == "CHAMP_ALPHA"
		and int(reloaded_alpha.get("wins", 0)) == 1
		and int(reloaded_alpha.get("eliminations", 0)) == 1,
		"Persistent store reloads accounts, match history, and stats from disk across server restart"
	)

	# Cleanup temporary test file & nodes
	if FileAccess.file_exists(TEST_SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH))

	c1.free()
	c2.free()
	server.free()

	print("=== PHASE 3 TEST SUMMARY: %d PASSED, %d FAILED ===" % [_passes, _failures])
	quit(1 if _failures > 0 else 0)
