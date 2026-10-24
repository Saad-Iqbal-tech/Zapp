extends SceneTree
## Standalone OS-process client worker for multi-process stress and soak testing.
## Launch via:
##   Godot_v4.7.2-stable_win64_console.exe --headless --path . -s res://tests/stress_client_worker.gd -- --port=17790 --id=1 --duration=15 --seed=20261024

var _port: int = 17790
var _worker_id: int = 1
var _duration_sec: float = 12.0
var _seed: int = 20261024
var _rng := RandomNumberGenerator.new()
var _client: MultiplayerClient


func _init() -> void:
	call_deferred("_run_worker")


func _wait_ms(duration_ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) < duration_ms:
		await process_frame
		await physics_frame


func _run_worker() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()

	for arg in args:
		if arg.begins_with("--port="):
			_port = int(arg.trim_prefix("--port="))
		elif arg.begins_with("--id="):
			_worker_id = int(arg.trim_prefix("--id="))
		elif arg.begins_with("--duration="):
			_duration_sec = float(arg.trim_prefix("--duration="))
		elif arg.begins_with("--seed="):
			_seed = int(arg.trim_prefix("--seed="))

	_rng.seed = _seed + (_worker_id * 7919)

	_client = MultiplayerClient.new()
	_client.name = "StressWorkerClient_%d" % _worker_id
	_client.account_token = "stress_os_worker_token_%d_%d" % [_seed, _worker_id]
	root.add_child(_client)

	var p_name := "WK_%d" % _worker_id
	_client.connect_to_server("127.0.0.1", _port, p_name)

	var start_ms := Time.get_ticks_msec()
	var end_ms := start_ms + int(_duration_sec * 1000.0)
	var next_action_ms := start_ms + 400

	while Time.get_ticks_msec() < end_ms:
		var now_ms := Time.get_ticks_msec()
		if not _client.is_connected_to_server() and not _client.is_connecting():
			_client.connect_to_server("127.0.0.1", _port, p_name)
		elif _client.is_connected_to_server() and now_ms >= next_action_ms:
			next_action_ms = now_ms + _rng.randi_range(350, 850)
			if not _client.current_session_id.is_empty():
				var mv := Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
				var aim := Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
				_client.send_player_input_now(mv, aim)
			elif not _client.in_matchmaking_queue and _client.current_room_code.is_empty():
				_client.request_quick_join(2, true)
		await _wait_ms(30)

	_client.disconnect_from_server()
	_client.queue_free()
	await _wait_ms(30)
	quit(0)
