extends SceneTree
## Verification test suite for Zapp Splash Screen:
## Tests node hierarchy, visuals, particle generation, progress cycling, audio powerup, and captures visual preview.
## Run via: Godot_v4.7.2-stable_win64_console.exe --path . -s res://tests/test_splash_screen.gd

var _failures: int = 0
var _passes: int = 0


func _initialize() -> void:
	print("=== STARTING ZAPP SPLASH SCREEN VERIFICATION ===")
	call_deferred("_run_tests")


func _assert(condition: bool, message: String) -> void:
	if condition:
		_passes += 1
		print("  [PASS] %s" % message)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % message)


func _run_tests() -> void:
	var audio_mgr := AudioManager.new()
	root.add_child(audio_mgr)
	await process_frame

	# Test 1: Verify audio manager splash sound method
	_assert(audio_mgr.has_method("play_splash_powerup"), "AudioManager has play_splash_powerup() method")
	audio_mgr.play_splash_powerup()
	_assert(audio_mgr._splash_player != null, "AudioManager has _splash_player node")
	_assert(audio_mgr._splash_stream != null, "AudioManager generated valid _splash_stream")

	# Test 2: Instantiate SplashScreen
	var splash := SplashScreen.new()
	root.add_child(splash)
	await process_frame
	await process_frame

	_assert(splash.layer == 100, "SplashScreen renders on topmost CanvasLayer 100")
	_assert(splash._root != null, "SplashScreen root control exists")
	_assert(splash._bg_canvas != null, "Background canvas exists")
	_assert(splash._logo_container != null, "Logo container exists")
	_assert(splash._title_label != null and splash._title_label.text == "ZAPP", "ZAPP title label configured")
	_assert(splash._emblem_rect != null, "High-voltage emblem badge exists")
	_assert(splash._laser_underline != null, "Dynamic laser underline exists")
	_assert(splash._subtitle_pill != null, "Subtitle pill exists")
	_assert(splash._subtitle_label.text.contains("SURVIVAL ARENA"), "Tagline contains SURVIVAL ARENA")
	_assert(splash._status_label != null, "Status message label exists")
	_assert(splash._progress_fill != null, "Charging progress fill exists")
	_assert(splash._prompt_label != null, "Tap anywhere prompt label exists")
	_assert(splash._particles.size() == 50, "50 energy particles generated")
	_assert(splash._shockwaves.size() == 3, "3 concentric shockwave rings active")

	# Test 3: Simulate 1.5 seconds of process animation
	var dt := 0.05
	for step in range(30):
		splash._process(dt)

	_assert(splash._progress > 0.40, "Progress bar accumulated smoothly (current: %.2f)" % splash._progress)
	_assert(splash._status_label.text.contains("PLATFORMS") or splash._status_label.text.contains("COMBAT"), "Status message cycled with progress")

	# Test 4: Capture screenshot if not dummy renderer
	if DisplayServer.get_name() != "headless":
		await process_frame
		await process_frame
		var img := root.get_viewport().get_texture().get_image()
		if img:
			var preview_path := "C:/Users/danis/.gemini/antigravity/brain/68cff3db-9fed-4d89-909c-2a8c0328fe84/splash_screen_preview.png"
			var err := img.save_png(preview_path)
			if err == OK:
				print("  [INFO] Captured visual preview artifact to: %s" % preview_path)

	# Test 5: Test finish_splash and signal emission
	var signal_box := [false]
	splash.splash_finished.connect(func():
		signal_box[0] = true
	)

	splash.finish_splash(true)
	await process_frame

	_assert(signal_box[0] == true, "finish_splash() successfully emitted splash_finished signal")

	# Cleanup
	audio_mgr.queue_free()

	print("\n=== SPLASH SCREEN VERIFICATION SUMMARY ===")
	print("  Passes: %d" % _passes)
	print("  Failures: %d" % _failures)

	if _failures == 0:
		print(">> ALL SPLASH SCREEN TESTS PASSED! <<")
		quit(0)
	else:
		printerr(">> SOME TESTS FAILED! <<")
		quit(1)
