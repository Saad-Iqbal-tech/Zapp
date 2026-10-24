extends SceneTree
## Dedicated headless server entry point.
## Launch via:
##   Godot_v4.7.2-stable_win64_console.exe --headless --path . -s res://scripts/network/dedicated_server_runner.gd -- --port=7777

var server: DedicatedServer


func _init() -> void:
	call_deferred("_start_dedicated_server")


func _start_dedicated_server() -> void:
	var port := NetProtocol.DEFAULT_PORT
	var bind_ip := "0.0.0.0"

	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()

	for arg in args:
		if arg.begins_with("--port="):
			port = int(arg.trim_prefix("--port="))
		elif arg.begins_with("--bind="):
			bind_ip = arg.trim_prefix("--bind=")

	server = DedicatedServer.new()
	server.name = "DedicatedServer"
	root.add_child(server)

	var err := server.start_server(port, bind_ip)
	if err != OK:
		push_error("DedicatedServer failed to bind port %d (error %d)" % [port, err])
		quit(1)
