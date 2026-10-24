extends SceneTree
## Automated verification test suite for 5-Player Line-of-Sight Survival Arena.
## Run via: Godot_v4.7.2-stable_win64_console.exe --headless --path . -s res://tests/test_survival_arena.gd

var _failures: int = 0
var _passes: int = 0


func _initialize() -> void:
	print("=== STARTING 5-PLAYER LINE-OF-SIGHT SURVIVAL ARENA TEST SUITE ===")
	call_deferred("_run_all_tests")


func _assert(condition: bool, message: String) -> void:
	if condition:
		_passes += 1
		print("  [PASS] %s" % message)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % message)


func _run_all_tests() -> void:
	var main_scene_res := load("res://scenes/main_arena.tscn") as PackedScene
	_assert(main_scene_res != null, "Main scene res://scenes/main_arena.tscn loads cleanly")

	var match_ctrl := main_scene_res.instantiate() as MatchController
	root.add_child(match_ctrl)
	await process_frame
	await physics_frame

	# 0. Verify Main Menu Lobby, How to Play, Matchmaking & Cancel, and Transition into Match
	_assert(match_ctrl.current_phase == MatchController.MatchPhase.MAIN_MENU, "Game launches into Main Menu Lobby")
	_assert(match_ctrl.hud.is_in_main_menu() == true, "MainMenuOverlay is visible on launch")
	_assert(match_ctrl.camera_rig.is_lobby_mode == true, "CameraRig is in 3D Hero Showcase Lobby mode")
	_assert(match_ctrl.human_character.visuals.is_lobby_showcase == true, "Featured 3D character plays lobby hero idle animation")

	# Test How to Play modal
	match_ctrl.hud.main_menu.set_how_to_play_open(true)
	_assert(match_ctrl.hud.main_menu._how_to_modal.visible == true, "How to Play modal opens from Main Menu")
	match_ctrl.hud.main_menu.set_how_to_play_open(false)

	# Test Matchmaking start & Cancel button
	match_ctrl.hud.main_menu.start_matchmaking()
	_assert(match_ctrl.hud.main_menu.is_matchmaking_active() == true, "Tapping PLAY opens Offline AI Matchmaking screen")
	match_ctrl.hud.main_menu.cancel_matchmaking()
	_assert(match_ctrl.hud.main_menu.is_matchmaking_active() == false, "Cancel button aborts matchmaking and returns to Main Menu")

	# Complete Matchmaking transition into Arena Match
	match_ctrl.hud.main_menu.start_matchmaking()
	match_ctrl.hud.main_menu._process(2.0) # Advance matchmaking timer to completion
	_assert(match_ctrl.current_phase == MatchController.MatchPhase.PREPARATION, "Matchmaking smoothly transitions into Round 1 Preparation phase")
	_assert(match_ctrl.hud.is_in_main_menu() == false, "Main Menu hides when Arena Match starts")

	# 1. Verify initial setup, 5 characters, camera angle, and Stage 1 (100%)
	_assert(match_ctrl.characters.size() == 5, "5 characters spawned (1 human + 4 AI)")
	_assert(match_ctrl.human_character != null and match_ctrl.human_character.is_human, "Human character initialized")
	_assert(match_ctrl.ai_controllers.size() == 4, "4 AI controllers active")
	_assert(is_equal_approx(match_ctrl.camera_rig.camera.global_rotation_degrees.x, -75.0), "Camera looks down at 75 degrees")
	_assert(match_ctrl.arena.current_stage == 1, "Arena starts at Stage 1")
	_assert(is_equal_approx(match_ctrl.arena.get_stage_width_ratio(1), 1.00), "Stage 1 width is 100%")
	_assert(is_equal_approx(match_ctrl.arena.get_stage_width_ratio(2), 0.72), "Stage 2 width is 72%")
	_assert(is_equal_approx(match_ctrl.arena.get_stage_width_ratio(3), 0.45), "Stage 3 width is 45%")
	_assert(is_equal_approx(match_ctrl.arena.get_stage_width_ratio(4), 0.22), "Stage 4 width is 22%")

	var all_alive_and_invincible := true
	for c in match_ctrl.characters:
		if c.current_state != CharacterController.State.ALIVE or not c.is_invincible:
			all_alive_and_invincible = false
	_assert(all_alive_and_invincible, "All 5 players start ALIVE and INVINCIBLE during 5s preparation phase")

	# 1b. Verify Stealth Invisibility during 5s Preparation Phase & Audio System
	_assert(
		match_ctrl.human_character.visuals.visible and match_ctrl.human_character.aim_line.visible,
		"Human player and own aiming line are visible during 5s preparation phase"
	)
	var opponents_hidden_in_prep := true
	for i in range(1, match_ctrl.characters.size()):
		var opp := match_ctrl.characters[i]
		if not opp.is_stealth_hidden or opp.visuals.visible or opp.aim_line.visible:
			opponents_hidden_in_prep = false
	_assert(
		opponents_hidden_in_prep,
		"Other players and their aiming lines are completely invisible during the 5s preparation phase"
	)

	_assert(match_ctrl.audio_manager != null, "AudioManager is initialized")
	_assert(match_ctrl.audio_manager._bgm_player.playing, "Background music is actively playing during the round")
	_assert(
		match_ctrl.audio_manager._laser_stream != null and match_ctrl.audio_manager._laser_stream.data.size() > 1000,
		"Laser shooting sound effect stream is generated and ready"
	)
	_assert(
		match_ctrl.audio_manager._drop_stream != null and match_ctrl.audio_manager._drop_stream.data.size() > 1000,
		"Platform/background dropping sound effect stream is generated and ready"
	)

	# 2. Test Mobile Touchscreen Controls (Left Virtual Joystick & Right Aiming Pad)
	var mc := match_ctrl.hud.mobile_controls
	var left_center := mc._get_left_center()
	var right_center := mc._get_right_center()

	var touch_left := InputEventScreenTouch.new()
	touch_left.index = 0
	touch_left.pressed = true
	touch_left.position = left_center + Vector2(65.0, 0.0) # Drag right (+X)
	mc._input(touch_left)
	_assert(mc.current_move_vector.x > 0.4, "Bottom-left virtual joystick outputs responsive movement vector on touch")
	_assert(match_ctrl.human_character.move_input.x > 0.4, "Human character receives movement input from virtual joystick")

	var touch_right := InputEventScreenTouch.new()
	touch_right.index = 1
	touch_right.pressed = true
	touch_right.position = right_center + Vector2(0.0, -70.0) # Aim North (-Z)
	mc._input(touch_right)
	_assert(mc.current_aim_vector.y < -0.9, "Bottom-right touch aim control updates aim vector via multi-touch")
	_assert(match_ctrl.human_character.aim_direction.z < -0.9, "Human character rotates attack line to match right aim pad")

	# Release both fingers; verify aim direction persists while movement stops
	touch_left.pressed = false
	mc._input(touch_left)
	touch_right.pressed = false
	mc._input(touch_right)
	_assert(match_ctrl.human_character.move_input.length() < 0.001, "Releasing left joystick stops movement")
	_assert(match_ctrl.human_character.aim_direction.z < -0.9, "Releasing right aim pad preserves last aimed attack direction")

	# 3. Test Obstacle Blocking of Aiming Line
	var p0 := match_ctrl.characters[0]
	var p1 := match_ctrl.characters[1]
	# Place p0 at (0, 0.05, 6.0) aiming North (0, 0, -1); obstacle is at (0, 0, 3.9)
	p0.global_position = Vector3(0.0, 0.05, 6.0)
	p0.set_aim_direction_3d(Vector3(0.0, 0.0, -1.0))
	p1.global_position = Vector3(0.0, 0.05, 1.5) # Directly behind obstacle at (0, 0, 3.9)
	var obs_aabbs := match_ctrl.arena.get_active_obstacle_aabbs()
	var blocked_seg := p0.get_attack_segment_snapshot(obs_aabbs)
	_assert(blocked_seg["blocked"] == true, "Aiming line is blocked by solid obstacle at (0, 0, 3.9)")
	var hits_behind_wall := AimLine.does_segment_hit_target(
		blocked_seg["origin"],
		blocked_seg["end"],
		p1.global_position,
		p1.hit_radius
	)
	_assert(hits_behind_wall == false, "Target standing behind solid obstacle is protected from attack line")

	# 4. Test Simultaneous Elimination Resolution (Mutual Hit + Spectator Mode)
	# Place p0 (Human) and p1 (VEX) facing each other in clear line of sight along X=-2.2
	p0.global_position = Vector3(-2.2, 0.05, 2.0)
	p0.set_aim_direction_3d(Vector3(0.0, 0.0, -1.0))
	p1.global_position = Vector3(-2.2, 0.05, -2.0)
	p1.set_aim_direction_3d(Vector3(0.0, 0.0, 1.0))
	# Keep p2, p3, p4 safe and aiming away
	match_ctrl.characters[2].global_position = Vector3(7.5, 0.05, 2.0)
	match_ctrl.characters[2].set_aim_direction_3d(Vector3(1.0, 0.0, 0.0))
	match_ctrl.characters[3].global_position = Vector3(-7.5, 0.05, 2.0)
	match_ctrl.characters[3].set_aim_direction_3d(Vector3(-1.0, 0.0, 0.0))
	match_ctrl.characters[4].global_position = Vector3(7.5, 0.05, -5.0)
	match_ctrl.characters[4].set_aim_direction_3d(Vector3(1.0, 0.0, 0.0))

	# Trigger countdown = 0 resolution
	match_ctrl._trigger_simultaneous_resolution()
	var survivors_revealed_on_fire := true
	for c in match_ctrl.get_living_players():
		if c.is_stealth_hidden or not c.visuals.visible or not c.aim_line.visible:
			survivors_revealed_on_fire = false
	_assert(survivors_revealed_on_fire, "All players and their laser lines are revealed when the laser fires at 0s")
	_assert(not p0.is_alive() and not p1.is_alive(), "Mutual line-of-sight attack eliminates BOTH players simultaneously")
	_assert(match_ctrl.get_living_players().size() == 3, "Living player count updates from 5 to 3")
	_assert(p0.current_state == CharacterController.State.SPECTATING, "Eliminated human player automatically transitions to SPECTATING state")
	_assert(match_ctrl.hud._spectator_panel.visible == true, "Spectator HUD panel becomes visible when human is eliminated")

	# Test cycling spectator targets and visibility during next preparation phase
	match_ctrl._begin_next_preparation_round()
	var all_survivors_visible_when_spectating := true
	for c in match_ctrl.get_living_players():
		if c.is_stealth_hidden or not c.visuals.visible or not c.aim_line.visible:
			all_survivors_visible_when_spectating = false
	_assert(
		all_survivors_visible_when_spectating,
		"Once human player dies and spectates, all surviving AI players and lines are visible during prep phase"
	)

	var first_spec_target := match_ctrl.camera_rig.target_node
	match_ctrl.cycle_spectator_target(1)
	var second_spec_target := match_ctrl.camera_rig.target_node
	_assert(first_spec_target != second_spec_target, "Spectator < PREV / NEXT > cycling switches camera follow target")

	# Test Menu Sound Settings & Return to Lobby button
	match_ctrl.hud.set_menu_open(true)
	_assert(match_ctrl.hud.is_menu_open() == true, "Menu opens cleanly via MENU button")
	match_ctrl.hud._music_slider.value = 45.0
	match_ctrl.hud._sfx_slider.value = 60.0
	_assert(is_equal_approx(match_ctrl.audio_manager.music_volume, 0.45), "Menu Music slider updates AudioManager music volume")
	_assert(is_equal_approx(match_ctrl.audio_manager.sfx_volume, 0.60), "Menu SFX slider updates AudioManager SFX volume")
	match_ctrl.hud._mute_check.button_pressed = true
	_assert(match_ctrl.audio_manager.sound_muted == true, "Menu Mute toggle mutes AudioManager")
	match_ctrl.hud._mute_check.button_pressed = false
	match_ctrl.hud.set_menu_open(false)

	# 5. Test Staged Arena Shrinking & Fall Elimination
	match_ctrl.arena.start_shrink_warning(2, 4.0)
	_assert(match_ctrl.arena.is_warning_active == true, "Shrink warning activates and highlights danger boundary")
	match_ctrl.arena.execute_shrink_to_stage(2)
	_assert(match_ctrl.arena.current_stage == 2, "Arena shrinks to Stage 2 (72%)")
	_assert(is_equal_approx(match_ctrl.arena.get_current_safe_width(), 24.0 * 0.72), "Stage 2 playable width is 72% of original")

	# Simulate a character falling below platform
	var p2 := match_ctrl.characters[2]
	p2.controls_frozen = false
	p2.global_position = Vector3(11.0, -3.0, 11.0) # Below fall_elimination_y (-2.2)
	p2._physics_process(0.016)
	_assert(p2.current_state == CharacterController.State.ELIMINATED, "Character falling below platform is detected and eliminated")
	_assert(match_ctrl.get_living_players().size() == 2, "Living player count updates to 2 after fall elimination")

	# 6. Test Winner State & Prevent Shrinking After Match Ends
	var p3 := match_ctrl.characters[3]
	var p4 := match_ctrl.characters[4]
	p3.eliminate("LASER")
	_assert(p4.current_state == CharacterController.State.WINNER, "Last surviving player transitions to WINNER state")
	_assert(match_ctrl.current_phase == MatchController.MatchPhase.MATCH_OVER, "Match phase transitions to MATCH_OVER")
	_assert(match_ctrl.hud._result_overlay.visible == true, "Winner screen overlay is displayed")

	var stage_at_end := match_ctrl.arena.current_stage
	match_ctrl._update_arena_shrinking(25.0)
	_assert(match_ctrl.arena.current_stage == stage_at_end, "Arena does not shrink after match ends")

	# 7. Test Replay Button Reset & Simultaneous Draw Condition
	match_ctrl.start_new_match()
	_assert(match_ctrl.get_living_players().size() == 5, "Replay resets all 5 players to ALIVE")
	_assert(match_ctrl.arena.current_stage == 1, "Replay resets arena to Stage 1 (100%)")

	# Eliminate 3 players, then have the final 2 eliminate each other simultaneously for DRAW
	match_ctrl.characters[2].eliminate("LASER")
	match_ctrl.characters[3].eliminate("LASER")
	match_ctrl.characters[4].eliminate("LASER")
	p0.global_position = Vector3(-2.2, 0.05, 2.0)
	p0.set_aim_direction_3d(Vector3(0.0, 0.0, -1.0))
	p1.global_position = Vector3(-2.2, 0.05, -2.0)
	p1.set_aim_direction_3d(Vector3(0.0, 0.0, 1.0))
	match_ctrl._trigger_simultaneous_resolution()
	_assert(match_ctrl.get_living_players().size() == 0, "Simultaneous elimination of last 2 players leaves 0 survivors")
	_assert(match_ctrl.current_phase == MatchController.MatchPhase.MATCH_OVER, "Match ends on simultaneous elimination draw")
	_assert(match_ctrl.hud._result_title_label.text.begins_with("DRAW"), "Draw screen is displayed when all players are eliminated simultaneously")

	# 8. Test returning from Match to Main Menu Lobby
	match_ctrl.return_to_lobby()
	_assert(match_ctrl.current_phase == MatchController.MatchPhase.MAIN_MENU, "Return to Main Menu transitions back to 3D Lobby")
	_assert(match_ctrl.hud.is_in_main_menu() == true, "Main Menu UI is restored after returning from match")

	match_ctrl.queue_free()
	await process_frame
	await process_frame

	print("=== TEST SUMMARY: %d PASSED, %d FAILED ===" % [_passes, _failures])
	quit(1 if _failures > 0 else 0)
