extends SceneTree
## AdMob Integration & Landscape Mobile Layout Verification Suite (desktop/headless).
## NOTE: This suite cannot exercise the native Android AdMob SDK. It verifies configuration,
## the ad-placement gating logic (via AdMobManager's simulation mode), failure fallbacks,
## landscape project/export settings, and HUD/joystick layout across aspect ratios & notches.

var _passes: int = 0
var _failures: int = 0


func _init() -> void:
	call_deferred("_run")


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


func _finish_local_match_with_human_winner(mc: MatchController) -> void:
	for i in range(1, mc.characters.size()):
		if mc.characters[i].is_alive():
			mc.characters[i].eliminate("LASER")


func _controls_layout_in_viewport(vp_size: Vector2i, insets: Vector4) -> Dictionary:
	var svp := SubViewport.new()
	svp.size = vp_size
	root.add_child(svp)
	var mcon := MobileControls.new()
	mcon.simulated_safe_insets = insets
	svp.add_child(mcon)
	await _wait_frames(2)
	var res := {
		"left": mcon._get_left_center(),
		"right": mcon._get_right_center(),
		"radius": mcon.pad_radius
	}
	svp.queue_free()
	return res


func _run() -> void:
	print("\n=== STARTING ADMOB & LANDSCAPE VERIFICATION SUITE ===")

	# ---------------- 1. Landscape project & export configuration ----------------
	print("\n--- Section 1: Landscape Configuration ---")
	_assert(int(ProjectSettings.get_setting("display/window/handheld/orientation", -1)) == 4,
		"Handheld orientation is SENSOR_LANDSCAPE (landscape + 180° auto-rotate, portrait disallowed)")
	_assert(str(ProjectSettings.get_setting("display/window/stretch/mode")) == "canvas_items"
		and str(ProjectSettings.get_setting("display/window/stretch/aspect")) == "expand",
		"Stretch mode canvas_items + aspect expand (no distortion; wider phones get more horizontal view)")
	var vw := int(ProjectSettings.get_setting("display/window/size/viewport_width"))
	var vh := int(ProjectSettings.get_setting("display/window/size/viewport_height"))
	_assert(vw > vh, "Base viewport is landscape (%dx%d)" % [vw, vh])

	var presets := ConfigFile.new()
	var perr := presets.load("res://export_presets.cfg")
	_assert(perr == OK and str(presets.get_value("preset.0", "platform", "")) == "Android", "Android export preset exists")
	_assert(bool(presets.get_value("preset.0.options", "gradle_build/use_gradle_build", false)),
		"Android preset uses Gradle build (required for AdMob plugin AARs)")
	_assert(bool(presets.get_value("preset.0.options", "screen/immersive_mode", false)),
		"Android preset uses immersive full-screen mode")
	_assert(str(presets.get_value("preset.0", "exclude_filter", "")).find("tests/") != -1,
		"Test/debug scripts are excluded from the Android export")

	# ---------------- 2. AdMob configuration ----------------
	print("\n--- Section 2: AdMob Configuration ---")
	_assert(str(ProjectSettings.get_setting("admob/general/android/app_id", "")) == "ca-app-pub-2206945025056752~4220096311",
		"AdMob Android App ID configured in Project Settings (written to AndroidManifest by plugin exporter)")
	_assert(FileAccess.file_exists("res://addons/admob/android/bin/ads/libs/poing-godot-admob-ads-release.aar")
		and FileAccess.file_exists("res://addons/admob/android/bin/ads/libs/poing-godot-admob-core-debug.aar"),
		"Poing AdMob v5.1.0 Android AARs for Godot 4.7.2 are installed")

	var adm := AdMobManager.new()
	root.add_child(adm)
	await _wait_frames(2)
	_assert(adm.get_production_interstitial_unit_id() == "ca-app-pub-2206945025056752/7728096486",
		"Production interstitial Ad Unit ID configured")
	_assert(adm.get_active_interstitial_unit_id() == AdMobManager.GOOGLE_TEST_INTERSTITIAL_AD_UNIT_ID,
		"Debug/development builds request Google's official TEST interstitial unit, never the live unit")
	_assert(not adm.has_native_android_admob() and adm.is_initialized,
		"On desktop, AdMob initializes as a safe no-op without Android singletons (no crash)")
	_assert(MobileAds._plugin == null,
		"Plugin's editor mock ad overlay is disabled (no debug/mock UI appears in game)")

	var desktop_continued := {"v": false}
	adm.show_post_match_interstitial_then(MatchController.MatchPhase.MATCH_OVER, false, false, func(): desktop_continued["v"] = true)
	_assert(desktop_continued["v"] and adm.ads_shown_count == 0,
		"Desktop with no ad available: continuation runs immediately and nothing is shown")
	adm.queue_free()

	# ---------------- 3. Placement gating in a real match ----------------
	print("\n--- Section 3: Interstitial Placement Gating (simulated ad SDK) ---")
	var scene: PackedScene = load("res://scenes/main_arena.tscn")
	var mc := scene.instantiate() as MatchController
	root.add_child(mc)
	await _wait_frames(4)
	_assert(mc.ad_manager != null, "MatchController owns an AdMobManager")
	mc.ad_manager.enable_test_simulation(true)
	mc.ad_manager.min_interval_sec = 0.0
	mc.ad_manager.preload_interstitial()
	_assert(mc.ad_manager.is_interstitial_loaded(), "Simulated test interstitial loads")

	# Main menu — no ad on PLAY (pre-match / matchmaking)
	mc.start_new_match()
	await _wait_frames(2)
	_assert(mc.current_phase == MatchController.MatchPhase.PREPARATION and mc.ad_manager.ads_shown_count == 0,
		"Starting a match from the menu shows no ad")

	# During countdown/aiming
	var cont := {"n": 0}
	mc._run_after_post_match_ad(func(): cont["n"] += 1)
	_assert(mc.ad_manager.ads_shown_count == 0 and mc.ad_manager.unsafe_show_attempts_blocked >= 1,
		"Ad request during countdown/aiming (PREPARATION) is blocked")

	# During laser resolution
	mc.current_phase = MatchController.MatchPhase.RESOLUTION_FREEZE
	mc._run_after_post_match_ad(func(): cont["n"] += 1)
	_assert(mc.ad_manager.ads_shown_count == 0, "Ad request during shooting/laser resolution is blocked")
	mc.current_phase = MatchController.MatchPhase.PREPARATION

	# Matchmaking / lobby / room busy
	_assert(not mc.ad_manager.show_post_match_interstitial_then(MatchController.MatchPhase.MATCH_OVER, false, true),
		"Ad request while matchmaking / joining lobby / creating room is blocked")
	mc.multiplayer_client.in_matchmaking_queue = true
	_assert(mc.is_online_or_lobby_busy(), "Matchmaking queue state is detected as busy")
	mc.multiplayer_client.in_matchmaking_queue = false
	mc.multiplayer_client.current_room_code = "ABCDE"
	_assert(mc.is_online_or_lobby_busy(), "Private room membership is detected as busy")
	mc.multiplayer_client.current_room_code = ""

	# Post-match break: PLAY AGAIN -> ad -> next match
	_finish_local_match_with_human_winner(mc)
	await _wait_frames(2)
	_assert(mc.current_phase == MatchController.MatchPhase.MATCH_OVER and mc.hud._result_overlay.visible,
		"Match result screen is displayed before any ad")
	_assert(mc.ad_manager.ads_shown_count == 0, "No ad is shown automatically when the result screen appears")
	mc._on_replay_requested()
	await _wait_frames(2)
	_assert(mc.ad_manager.ads_shown_count == 1, "Interstitial shown after result screen when player taps PLAY AGAIN")
	_assert(mc.current_phase == MatchController.MatchPhase.PREPARATION,
		"Next match starts after the interstitial is dismissed")

	# Frequency cap
	mc.ad_manager.min_interval_sec = 75.0
	_finish_local_match_with_human_winner(mc)
	await _wait_frames(2)
	mc._on_replay_requested()
	await _wait_frames(2)
	_assert(mc.ad_manager.ads_shown_count == 1 and mc.current_phase == MatchController.MatchPhase.PREPARATION,
		"Frequency cap skips a second ad within the cooldown and the game continues")
	mc.ad_manager.min_interval_sec = 0.0

	# Load failure fallback
	mc.ad_manager.destroy_interstitial()
	mc.ad_manager.enable_test_simulation(false)
	mc.ad_manager.min_interval_sec = 0.0
	mc.ad_manager.preload_interstitial()
	_assert(not mc.ad_manager.is_interstitial_loaded() and not mc.ad_manager.last_error_message.is_empty(),
		"Simulated ad load failure is reported without crashing")
	_finish_local_match_with_human_winner(mc)
	await _wait_frames(2)
	var shown_before := mc.ad_manager.ads_shown_count
	mc._on_replay_requested()
	await _wait_frames(2)
	_assert(mc.ad_manager.ads_shown_count == shown_before and mc.current_phase == MatchController.MatchPhase.PREPARATION,
		"When the ad fails to load, PLAY AGAIN still starts the next match normally")

	# MAIN MENU from result screen with a loaded ad
	mc.ad_manager.enable_test_simulation(true)
	mc.ad_manager.preload_interstitial()
	_finish_local_match_with_human_winner(mc)
	await _wait_frames(2)
	mc.return_to_lobby()
	await _wait_frames(2)
	_assert(mc.current_phase == MatchController.MatchPhase.MAIN_MENU and mc.ad_manager.ads_shown_count == shown_before + 1,
		"MAIN MENU from the result screen shows the ad, then returns to the lobby")

	# Mid-match return to lobby (spectator/settings) never shows an ad
	mc.ad_manager.preload_interstitial()
	mc.start_new_match()
	await _wait_frames(2)
	var shown_mid := mc.ad_manager.ads_shown_count
	mc.return_to_lobby()
	await _wait_frames(2)
	_assert(mc.ad_manager.ads_shown_count == shown_mid and mc.current_phase == MatchController.MatchPhase.MAIN_MENU,
		"Leaving mid-match via settings/spectator MAIN MENU shows no ad")

	# Online match end never shows an ad (would stall ENet while Android pauses)
	mc.is_online_match = true
	mc.current_phase = MatchController.MatchPhase.MATCH_OVER
	_assert(mc.is_online_or_lobby_busy(), "Online matches are treated as unsafe for interstitials")
	mc.is_online_match = false
	mc.current_phase = MatchController.MatchPhase.MAIN_MENU

	_assert(mc.ad_manager.ads_shown_during_gameplay_count == 0, "Zero ads were ever shown during active gameplay")

	# ---------------- 4. Landscape HUD / controls layout ----------------
	print("\n--- Section 4: Landscape Layout Across Aspect Ratios & Notches ---")
	var ratios := [
		{"name": "16:9 (1280x720)", "size": Vector2i(1280, 720)},
		{"name": "19.5:9 (1560x720)", "size": Vector2i(1560, 720)},
		{"name": "20:9 (1600x720)", "size": Vector2i(1600, 720)},
		{"name": "21:9 (1680x720)", "size": Vector2i(1680, 720)},
		{"name": "4:3 tablet (960x720)", "size": Vector2i(960, 720)}
	]
	for r in ratios:
		var sz: Vector2i = r["size"]
		var lay: Dictionary = await _controls_layout_in_viewport(sz, Vector4.ZERO)
		var lc: Vector2 = lay["left"]
		var rc: Vector2 = lay["right"]
		var rad: float = lay["radius"]
		var ok := (
			lc.x < sz.x * 0.5 and lc.y > sz.y * 0.5
			and rc.x > sz.x * 0.5 and rc.y > sz.y * 0.5
			and lc.x - rad >= 0.0 and rc.x + rad <= sz.x and lc.y + rad <= sz.y
			and rc.x - lc.x > rad * 2.0
		)
		_assert(ok, "%s: joystick bottom-left, aim pad bottom-right, on-screen and non-overlapping" % r["name"])

	var notch_lay: Dictionary = await _controls_layout_in_viewport(Vector2i(1600, 720), Vector4(90.0, 0.0, 90.0, 24.0))
	var nl: Vector2 = notch_lay["left"]
	var nr: Vector2 = notch_lay["right"]
	_assert(nl.x - float(notch_lay["radius"]) >= 90.0 and (1600.0 - nr.x) - float(notch_lay["radius"]) >= 90.0,
		"Simulated 90px side notches/cutouts: thumb pads stay inside the safe area")

	mc.hud.set_simulated_safe_insets(Vector4(90.0, 30.0, 90.0, 24.0))
	await _wait_frames(1)
	_assert(mc.hud._menu_button.offset_right <= -106.0 and mc.hud._menu_button.offset_top >= 40.0,
		"SETTINGS button shifts inside the right/top safe area")
	_assert(mc.hud._top_card.offset_top >= 36.0, "Top countdown card shifts below the top safe inset")
	mc.hud.set_simulated_safe_insets(Vector4.ZERO)

	var cam := mc.camera_rig
	_assert(cam.camera.keep_aspect == Camera3D.KEEP_HEIGHT,
		"Camera keeps vertical FOV (KEEP_HEIGHT) so wider screens reveal more arena horizontally")
	_assert(cam.get_effective_horizontal_fov_deg(Vector2(1600, 720)) > cam.get_effective_horizontal_fov_deg(Vector2(1280, 720)) + 5.0,
		"20:9 phones get a wider horizontal field of view than 16:9")

	mc.queue_free()
	await _wait_frames(2)
	print("\n=== ADMOB & LANDSCAPE SUMMARY: %d PASSED, %d FAILED ===" % [_passes, _failures])
	quit(1 if _failures > 0 else 0)
