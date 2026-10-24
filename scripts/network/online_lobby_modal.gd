class_name OnlineLobbyModal
extends Control
## Online Multiplayer Hub & Private Room Lobby UI for Phase 2 (and Phase 3 Stats/Leaderboards).
## Provides configurable Server IP/Port connection, honest Public Matchmaking queue,
## Private Room creation/joining by 5-char code, Host human/AI slot configuration, and Ready states.

signal closed_modal()
signal leaderboard_requested()

var client: MultiplayerClient

# Connection bar controls
var host_input: LineEdit
var port_input: LineEdit
var name_input: LineEdit
var connect_button: Button
var stats_button: Button
var close_button: Button
var conn_status_label: Label
var feedback_banner: Label

# Hub view (Public Matchmaking + Create/Join Private Room)
var _hub_container: Control
var public_queue_button: Button
var queue_status_label: Label
var create_room_button: Button
var room_code_input: LineEdit
var join_room_button: Button

# Room lobby view (5 participant slots + Host config + Ready/Start/Leave)
var _room_container: Control
var room_code_label: Label
var room_summary_label: Label
var _slot_panels: Array[PanelContainer] = []
var _slot_title_labels: Array[Label] = []
var _slot_sub_labels: Array[Label] = []
var _slot_state_labels: Array[Label] = []

var host_config_bar: HBoxContainer
var humans_label: Label
var humans_minus_btn: Button
var humans_plus_btn: Button
var ai_toggle_btn: Button
var ai_count_label: Label
var ai_minus_btn: Button
var ai_plus_btn: Button

var ready_button: Button
var start_match_button: Button
var leave_room_button: Button

# Phase 3: Stats, Match History & Leaderboard view
var _stats_container: Control
var _profile_summary_label: Label
var _leaderboard_label: Label
var _history_label: Label
var _showing_stats: bool = false

var _in_public_queue: bool = false
var _local_ready: bool = true


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_refresh_view_state()


func bind_client(mp_client: MultiplayerClient) -> void:
	if client == mp_client:
		return
	client = mp_client
	if not client:
		return

	if host_input:
		host_input.text = client.server_host
	if port_input:
		port_input.text = str(client.server_port)
	if name_input:
		name_input.text = client.player_name

	client.connected_to_game_server.connect(_on_client_connected)
	client.connection_error.connect(_on_client_error)
	client.disconnected_from_game_server.connect(_on_client_disconnected)
	client.queue_status_updated.connect(_on_queue_status_updated)
	client.room_state_updated.connect(_on_room_state_updated)
	client.room_closed.connect(_on_room_closed)
	client.server_error_received.connect(_on_server_error_received)
	client.stats_response_received.connect(_on_stats_response_received)
	client.authoritative_match_started.connect(func(_msg: Dictionary):
		visible = false
	)
	_refresh_view_state()


func open_modal() -> void:
	visible = true
	_refresh_view_state()


func close_modal() -> void:
	visible = false
	closed_modal.emit()


func set_feedback(text: String, is_error: bool = false) -> void:
	if not feedback_banner:
		return
	feedback_banner.text = text
	feedback_banner.add_theme_color_override(
		"font_color",
		Color(1.0, 0.42, 0.42) if is_error else Color(0.45, 0.96, 1.0)
	)


func _on_connect_button_pressed() -> void:
	if not client:
		return
	if client.conn_state != MultiplayerClient.ConnState.DISCONNECTED:
		client.disconnect_from_server()
		_in_public_queue = false
		set_feedback("Disconnected from server.", false)
		_refresh_view_state()
		return

	var host := host_input.text.strip_edges() if host_input else NetProtocol.DEFAULT_HOST
	var port := int(port_input.text.strip_edges()) if port_input else NetProtocol.DEFAULT_PORT
	var p_name := name_input.text.strip_edges() if name_input else "STRIKER_01"
	set_feedback("Connecting to %s:%d..." % [host, port], false)
	client.connect_to_server(host, port, p_name)
	_refresh_view_state()


func _on_public_queue_pressed() -> void:
	if not client or not client.is_connected_to_server():
		set_feedback("PUBLIC MATCHMAKING UNAVAILABLE: Connect to a running Dedicated Server first.", true)
		return
	if _in_public_queue:
		client.cancel_queue()
	else:
		if name_input:
			client.player_name = NetProtocol.sanitize_player_name(name_input.text, client.player_name)
		client.request_quick_join(2, false)


func _on_create_room_pressed() -> void:
	if not client or not client.is_connected_to_server():
		set_feedback("Cannot create room: Connect to the Dedicated Server first.", true)
		return
	if name_input:
		client.player_name = NetProtocol.sanitize_player_name(name_input.text, client.player_name)
	client.create_private_room(2, false, 0)


func _on_join_room_pressed() -> void:
	if not client or not client.is_connected_to_server():
		set_feedback("Cannot join room: Connect to the Dedicated Server first.", true)
		return
	var code := room_code_input.text.strip_edges().to_upper() if room_code_input else ""
	if code.is_empty():
		set_feedback("Enter a 5-character Room Code to join.", true)
		return
	if name_input:
		client.player_name = NetProtocol.sanitize_player_name(name_input.text, client.player_name)
	client.join_private_room(code)


func _adjust_room_config(delta_humans: int, toggle_ai: bool, delta_ai: int) -> void:
	if not client or not client.is_room_host():
		return
	var st := client.latest_room_state
	var cur_humans := int(st.get("target_humans", 2))
	var cur_fill := bool(st.get("fill_ai", false))
	var cur_ai := int(st.get("ai_count", 0))

	var new_humans := clampi(cur_humans + delta_humans, 1, NetProtocol.MAX_PLAYERS_PER_MATCH)
	var new_fill := (not cur_fill) if toggle_ai else cur_fill
	var max_ai := NetProtocol.MAX_PLAYERS_PER_MATCH - new_humans
	var new_ai := cur_ai + delta_ai
	if toggle_ai and new_fill and new_ai <= 0:
		new_ai = maxi(1, max_ai)
	new_ai = clampi(new_ai, 0, max_ai) if new_fill else 0
	if new_ai == 0:
		new_fill = false

	client.configure_private_room(new_humans, new_fill, new_ai)


func _on_ready_pressed() -> void:
	if not client or client.current_room_code.is_empty():
		return
	_local_ready = not _local_ready
	client.set_room_ready(_local_ready)


func _on_start_room_pressed() -> void:
	if not client or not client.is_room_host():
		return
	client.start_private_room_match()


func _on_leave_room_pressed() -> void:
	if not client:
		return
	client.leave_private_room()
	set_feedback("Left private room.", false)
	_refresh_view_state()


func _on_client_connected(peer_id: int, assigned_name: String) -> void:
	if name_input:
		name_input.text = assigned_name
	set_feedback("Connected to Dedicated Server as %s (ID #%d)." % [assigned_name, peer_id], false)
	_refresh_view_state()


func _on_client_error(reason: String) -> void:
	_in_public_queue = false
	set_feedback("SERVER UNAVAILABLE: %s" % reason, true)
	_refresh_view_state()


func _on_client_disconnected(reason: String) -> void:
	_in_public_queue = false
	set_feedback("Disconnected: %s" % reason, true)
	_refresh_view_state()


func _on_queue_status_updated(in_queue: bool, queued_count: int, required_count: int) -> void:
	_in_public_queue = in_queue
	if in_queue:
		set_feedback("Public Matchmaking Queue: %d/%d connected players waiting..." % [queued_count, required_count], false)
	else:
		set_feedback("Left Public Matchmaking Queue.", false)
	_refresh_view_state()


func _on_room_state_updated(room_msg: Dictionary) -> void:
	_in_public_queue = false
	var code := str(room_msg.get("room_code", ""))
	set_feedback("In Private Room %s" % code, false)
	_refresh_view_state()


func _on_room_closed(reason: String) -> void:
	set_feedback("Room closed: %s" % reason, false)
	_refresh_view_state()


func _on_server_error_received(code: String, message: String) -> void:
	set_feedback("[%s] %s" % [code, message], true)
	_refresh_view_state()


func toggle_stats_view() -> void:
	_showing_stats = not _showing_stats
	if _showing_stats and client and client.is_connected_to_server():
		client.request_stats()
	_refresh_view_state()


func _on_stats_response_received(_stats_msg: Dictionary) -> void:
	_refresh_view_state()


func _refresh_view_state() -> void:
	if not is_inside_tree():
		return

	var connected := client != null and client.is_connected_to_server()
	var connecting := client != null and client.conn_state == MultiplayerClient.ConnState.CONNECTING
	var in_room := connected and not client.current_room_code.is_empty()

	if conn_status_label:
		if connected:
			conn_status_label.text = "ONLINE • ID #%d" % client.local_peer_id
			conn_status_label.add_theme_color_override("font_color", Color(0.25, 1.0, 0.55))
		elif connecting:
			conn_status_label.text = "CONNECTING..."
			conn_status_label.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
		else:
			conn_status_label.text = "OFFLINE"
			conn_status_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45))

	if connect_button:
		connect_button.text = "DISCONNECT" if (connected or connecting) else "CONNECT"
	if stats_button:
		stats_button.text = "BACK TO LOBBY" if _showing_stats else "STATS & RANKS"

	if _stats_container:
		_stats_container.visible = _showing_stats
	if _hub_container:
		_hub_container.visible = (not in_room) and (not _showing_stats)
	if _room_container:
		_room_container.visible = in_room and (not _showing_stats)

	if _showing_stats:
		_populate_stats_and_leaderboard_ui()
		return

	if not in_room:
		if public_queue_button:
			public_queue_button.text = "CANCEL QUEUE" if _in_public_queue else "FIND PUBLIC MATCH"
		if queue_status_label:
			if not connected:
				queue_status_label.text = "Connect to a Dedicated Server above to join Public Matchmaking or Private Rooms."
			elif _in_public_queue:
				queue_status_label.text = "Searching for real connected players on server..."
			else:
				queue_status_label.text = "Matches real connected players on the Dedicated Server (no fake bots)."
		return

	# Populate Private Room UI from client.latest_room_state
	var st := client.latest_room_state
	var code := str(st.get("room_code", client.current_room_code))
	var host_id := int(st.get("host_peer_id", -1))
	var is_host := (host_id == client.local_peer_id)
	var target_humans := int(st.get("target_humans", 2))
	var fill_ai := bool(st.get("fill_ai", false))
	var ai_count := int(st.get("ai_count", 0)) if fill_ai else 0
	var can_start := bool(st.get("can_start", false))
	var members: Array = st.get("members", [])

	if room_code_label:
		room_code_label.text = "ROOM CODE: %s" % code
	if room_summary_label:
		var role_txt := "YOU ARE HOST" if is_host else ("HOST ID #%d" % host_id)
		room_summary_label.text = "%s  •  CONFIG: %d HUMANS + %d AI BOTS" % [role_txt, target_humans, ai_count]

	if humans_label:
		humans_label.text = "HUMANS: %d" % target_humans
	if ai_toggle_btn:
		ai_toggle_btn.text = "AI FILL: ON" if fill_ai else "AI FILL: OFF"
		ai_toggle_btn.disabled = not is_host
	if ai_count_label:
		ai_count_label.text = "AI BOTS: %d" % ai_count
	if humans_minus_btn:
		humans_minus_btn.disabled = not is_host
	if humans_plus_btn:
		humans_plus_btn.disabled = not is_host
	if ai_minus_btn:
		ai_minus_btn.disabled = not is_host or not fill_ai
	if ai_plus_btn:
		ai_plus_btn.disabled = not is_host or not fill_ai

	# Update 5 participant slot cards
	var bot_idx := 0
	for i in range(NetProtocol.MAX_PLAYERS_PER_MATCH):
		var title_lbl := _slot_title_labels[i]
		var sub_lbl := _slot_sub_labels[i]
		var state_lbl := _slot_state_labels[i]
		var panel := _slot_panels[i]

		if i < members.size():
			var m: Dictionary = members[i]
			var m_peer := int(m.get("peer_id", 0))
			var m_name := str(m.get("name", "PLAYER"))
			var m_host := bool(m.get("is_host", false))
			var m_ready := bool(m.get("ready", false))
			if m_peer == client.local_peer_id:
				_local_ready = m_ready
			title_lbl.text = m_name
			sub_lbl.text = "HOST" if m_host else "HUMAN"
			state_lbl.text = "READY!" if m_ready else "WAITING"
			state_lbl.add_theme_color_override("font_color", Color(0.25, 1.0, 0.55) if m_ready else UIStyleHelper.COLOR_GOLD)
			panel.modulate = Color(1, 1, 1, 1)
		elif i < target_humans:
			title_lbl.text = "OPEN SLOT"
			sub_lbl.text = "HUMAN SLOT"
			state_lbl.text = "WAITING..."
			state_lbl.add_theme_color_override("font_color", Color(0.65, 0.80, 1.0))
			panel.modulate = Color(0.75, 0.82, 0.92, 0.85)
		elif fill_ai and bot_idx < ai_count:
			title_lbl.text = DedicatedServer.BOT_NAMES[bot_idx % DedicatedServer.BOT_NAMES.size()]
			sub_lbl.text = "SERVER AI"
			state_lbl.text = "AI FILL"
			state_lbl.add_theme_color_override("font_color", Color(0.45, 0.96, 1.0))
			panel.modulate = Color(0.92, 0.96, 1.0, 0.95)
			bot_idx += 1
		else:
			title_lbl.text = "CLOSED"
			sub_lbl.text = "UNUSED"
			state_lbl.text = "---"
			state_lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.65))
			panel.modulate = Color(0.45, 0.48, 0.55, 0.65)

	if ready_button:
		ready_button.text = "UNREADY" if _local_ready else "READY UP!"
	if start_match_button:
		start_match_button.visible = is_host
		start_match_button.disabled = not can_start


func _build_ui() -> void:
	var dimmer := ColorRect.new()
	dimmer.color = Color(0.02, 0.05, 0.12, 0.84)
	add_child(dimmer)
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.08, 0.14, 0.28, 0.98), Color(0.20, 0.86, 1.0), 24, 7, 22, 18)
	)
	add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.offset_left = -460.0
	card.offset_right = 460.0
	card.offset_top = -290.0
	card.offset_bottom = 290.0

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 10)
	card.add_child(root_vbox)

	# --- HEADER & SERVER BAR ---
	var top_hbox := HBoxContainer.new()
	top_hbox.add_theme_constant_override("separation", 10)
	root_vbox.add_child(top_hbox)

	var title_lbl := Label.new()
	title_lbl.text = "ONLINE ARENA LOBBY"
	title_lbl.add_theme_font_size_override("font_size", 24)
	title_lbl.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_hbox.add_child(title_lbl)

	conn_status_label = Label.new()
	conn_status_label.text = "OFFLINE"
	conn_status_label.add_theme_font_size_override("font_size", 15)
	top_hbox.add_child(conn_status_label)

	stats_button = Button.new()
	stats_button.name = "OnlineStatsButton"
	stats_button.text = "STATS & RANKS"
	stats_button.custom_minimum_size = Vector2(148.0, 38.0)
	UIStyleHelper.apply_chunky_button_style(stats_button, UIStyleHelper.COLOR_PURPLE, UIStyleHelper.COLOR_PURPLE_BORDER, 14, 12, 4)
	stats_button.pressed.connect(func():
		toggle_stats_view()
		leaderboard_requested.emit()
	)
	top_hbox.add_child(stats_button)

	close_button = Button.new()
	close_button.name = "CloseOnlineModalButton"
	close_button.text = "BACK"
	close_button.custom_minimum_size = Vector2(92.0, 38.0)
	UIStyleHelper.apply_chunky_button_style(close_button, UIStyleHelper.COLOR_CORAL_RED, UIStyleHelper.COLOR_CORAL_BORDER, 14, 12, 4)
	close_button.pressed.connect(close_modal)
	top_hbox.add_child(close_button)

	# Server Config Row
	var srv_hbox := HBoxContainer.new()
	srv_hbox.add_theme_constant_override("separation", 8)
	root_vbox.add_child(srv_hbox)

	var ip_lbl := Label.new()
	ip_lbl.text = "Server IP:"
	ip_lbl.add_theme_font_size_override("font_size", 14)
	srv_hbox.add_child(ip_lbl)

	host_input = LineEdit.new()
	host_input.name = "ServerHostInput"
	host_input.text = NetProtocol.DEFAULT_HOST
	host_input.custom_minimum_size = Vector2(165.0, 36.0)
	srv_hbox.add_child(host_input)

	var port_lbl := Label.new()
	port_lbl.text = "Port:"
	port_lbl.add_theme_font_size_override("font_size", 14)
	srv_hbox.add_child(port_lbl)

	port_input = LineEdit.new()
	port_input.name = "ServerPortInput"
	port_input.text = str(NetProtocol.DEFAULT_PORT)
	port_input.custom_minimum_size = Vector2(78.0, 36.0)
	srv_hbox.add_child(port_input)

	var name_lbl := Label.new()
	name_lbl.text = "Name:"
	name_lbl.add_theme_font_size_override("font_size", 14)
	srv_hbox.add_child(name_lbl)

	name_input = LineEdit.new()
	name_input.name = "PlayerNameInput"
	name_input.text = "STRIKER_01"
	name_input.max_length = 16
	name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	srv_hbox.add_child(name_input)

	connect_button = Button.new()
	connect_button.name = "ConnectServerButton"
	connect_button.text = "CONNECT"
	connect_button.custom_minimum_size = Vector2(132.0, 38.0)
	UIStyleHelper.apply_chunky_button_style(connect_button, UIStyleHelper.COLOR_SKY_BLUE, UIStyleHelper.COLOR_SKY_BORDER, 15, 12, 4)
	connect_button.pressed.connect(_on_connect_button_pressed)
	srv_hbox.add_child(connect_button)

	feedback_banner = Label.new()
	feedback_banner.text = "Configure server address and tap CONNECT to play online."
	feedback_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	feedback_banner.add_theme_font_size_override("font_size", 14)
	feedback_banner.add_theme_color_override("font_color", Color(0.45, 0.96, 1.0))
	root_vbox.add_child(feedback_banner)

	# --- HUB CONTAINER (Public Matchmaking + Private Rooms) ---
	_hub_container = HBoxContainer.new()
	_hub_container.add_theme_constant_override("separation", 16)
	_hub_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(_hub_container)

	# Left Card: Public Matchmaking
	var pub_card := PanelContainer.new()
	pub_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pub_card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.11, 0.19, 0.36, 0.95), UIStyleHelper.COLOR_PLAY_GREEN, 18, 5, 18, 16)
	)
	_hub_container.add_child(pub_card)

	var pub_vbox := VBoxContainer.new()
	pub_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	pub_vbox.add_theme_constant_override("separation", 14)
	pub_card.add_child(pub_vbox)

	var pub_title := Label.new()
	pub_title.text = "PUBLIC MATCHMAKING"
	pub_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pub_title.add_theme_font_size_override("font_size", 22)
	pub_title.add_theme_color_override("font_color", Color(0.35, 1.0, 0.62))
	pub_vbox.add_child(pub_title)

	queue_status_label = Label.new()
	queue_status_label.text = "Matches real connected players on the Dedicated Server."
	queue_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	queue_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	queue_status_label.add_theme_font_size_override("font_size", 14)
	pub_vbox.add_child(queue_status_label)

	public_queue_button = Button.new()
	public_queue_button.name = "PublicQueueButton"
	public_queue_button.text = "FIND PUBLIC MATCH"
	public_queue_button.custom_minimum_size = Vector2(220.0, 56.0)
	UIStyleHelper.apply_chunky_button_style(public_queue_button, UIStyleHelper.COLOR_PLAY_GREEN, UIStyleHelper.COLOR_PLAY_BORDER, 18, 16, 6)
	public_queue_button.pressed.connect(_on_public_queue_pressed)
	pub_vbox.add_child(public_queue_button)

	# Right Card: Private Room Create / Join
	var priv_card := PanelContainer.new()
	priv_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	priv_card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.11, 0.19, 0.36, 0.95), UIStyleHelper.COLOR_GOLD, 18, 5, 18, 16)
	)
	_hub_container.add_child(priv_card)

	var priv_vbox := VBoxContainer.new()
	priv_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	priv_vbox.add_theme_constant_override("separation", 12)
	priv_card.add_child(priv_vbox)

	var priv_title := Label.new()
	priv_title.text = "PRIVATE ROOMS (UP TO 5P)"
	priv_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	priv_title.add_theme_font_size_override("font_size", 22)
	priv_title.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
	priv_vbox.add_child(priv_title)

	create_room_button = Button.new()
	create_room_button.name = "CreateRoomButton"
	create_room_button.text = "CREATE PRIVATE ROOM"
	create_room_button.custom_minimum_size = Vector2(220.0, 50.0)
	UIStyleHelper.apply_chunky_button_style(create_room_button, UIStyleHelper.COLOR_SKY_BLUE, UIStyleHelper.COLOR_SKY_BORDER, 17, 16, 5)
	create_room_button.pressed.connect(_on_create_room_pressed)
	priv_vbox.add_child(create_room_button)

	var join_hbox := HBoxContainer.new()
	join_hbox.add_theme_constant_override("separation", 8)
	priv_vbox.add_child(join_hbox)

	room_code_input = LineEdit.new()
	room_code_input.name = "RoomCodeInput"
	room_code_input.placeholder_text = "ROOM CODE"
	room_code_input.max_length = 8
	room_code_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_code_input.custom_minimum_size = Vector2(120.0, 46.0)
	join_hbox.add_child(room_code_input)

	join_room_button = Button.new()
	join_room_button.name = "JoinRoomButton"
	join_room_button.text = "JOIN ROOM"
	join_room_button.custom_minimum_size = Vector2(135.0, 46.0)
	UIStyleHelper.apply_chunky_button_style(join_room_button, UIStyleHelper.COLOR_PURPLE, UIStyleHelper.COLOR_PURPLE_BORDER, 16, 14, 5)
	join_room_button.pressed.connect(_on_join_room_pressed)
	join_hbox.add_child(join_room_button)

	# --- PRIVATE ROOM CONTAINER ---
	_room_container = VBoxContainer.new()
	_room_container.visible = false
	_room_container.add_theme_constant_override("separation", 10)
	_room_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(_room_container)

	var rm_top := HBoxContainer.new()
	rm_top.add_theme_constant_override("separation", 14)
	_room_container.add_child(rm_top)

	room_code_label = Label.new()
	room_code_label.text = "ROOM CODE: -----"
	room_code_label.add_theme_font_size_override("font_size", 22)
	room_code_label.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
	rm_top.add_child(room_code_label)

	room_summary_label = Label.new()
	room_summary_label.text = "WAITING FOR PLAYERS"
	room_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	room_summary_label.add_theme_font_size_override("font_size", 15)
	rm_top.add_child(room_summary_label)

	# 5 Participant Cards
	var slots_hbox := HBoxContainer.new()
	slots_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	slots_hbox.add_theme_constant_override("separation", 10)
	_room_container.add_child(slots_hbox)

	_slot_panels.clear()
	_slot_title_labels.clear()
	_slot_sub_labels.clear()
	_slot_state_labels.clear()

	for i in range(NetProtocol.MAX_PLAYERS_PER_MATCH):
		var pal: Dictionary = ServerMatchSession.PALETTES[i % ServerMatchSession.PALETTES.size()]
		var col: Color = pal["primary"]
		var sp := PanelContainer.new()
		sp.custom_minimum_size = Vector2(162.0, 108.0)
		sp.add_theme_stylebox_override(
			"panel",
			UIStyleHelper.create_card_style(Color(col.r * 0.22, col.g * 0.22, col.b * 0.28, 0.95), col, 14, 4, 10, 8)
		)
		slots_hbox.add_child(sp)

		var sv := VBoxContainer.new()
		sv.alignment = BoxContainer.ALIGNMENT_CENTER
		sv.add_theme_constant_override("separation", 4)
		sp.add_child(sv)

		var t_lbl := Label.new()
		t_lbl.text = "OPEN"
		t_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		t_lbl.add_theme_font_size_override("font_size", 17)
		sv.add_child(t_lbl)

		var sb_lbl := Label.new()
		sb_lbl.text = "SLOT %d" % (i + 1)
		sb_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sb_lbl.add_theme_font_size_override("font_size", 12)
		sb_lbl.add_theme_color_override("font_color", col.lightened(0.35))
		sv.add_child(sb_lbl)

		var st_lbl := Label.new()
		st_lbl.text = "WAITING"
		st_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		st_lbl.add_theme_font_size_override("font_size", 13)
		sv.add_child(st_lbl)

		_slot_panels.append(sp)
		_slot_title_labels.append(t_lbl)
		_slot_sub_labels.append(sb_lbl)
		_slot_state_labels.append(st_lbl)

	# Host Configuration Row
	host_config_bar = HBoxContainer.new()
	host_config_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	host_config_bar.add_theme_constant_override("separation", 10)
	_room_container.add_child(host_config_bar)

	humans_minus_btn = Button.new()
	humans_minus_btn.text = "- HUMAN"
	humans_minus_btn.custom_minimum_size = Vector2(96.0, 38.0)
	humans_minus_btn.pressed.connect(func(): _adjust_room_config(-1, false, 0))
	host_config_bar.add_child(humans_minus_btn)

	humans_label = Label.new()
	humans_label.text = "HUMANS: 2"
	humans_label.add_theme_font_size_override("font_size", 15)
	host_config_bar.add_child(humans_label)

	humans_plus_btn = Button.new()
	humans_plus_btn.text = "+ HUMAN"
	humans_plus_btn.custom_minimum_size = Vector2(96.0, 38.0)
	humans_plus_btn.pressed.connect(func(): _adjust_room_config(1, false, 0))
	host_config_bar.add_child(humans_plus_btn)

	ai_toggle_btn = Button.new()
	ai_toggle_btn.text = "AI FILL: OFF"
	ai_toggle_btn.custom_minimum_size = Vector2(128.0, 38.0)
	ai_toggle_btn.pressed.connect(func(): _adjust_room_config(0, true, 0))
	host_config_bar.add_child(ai_toggle_btn)

	ai_minus_btn = Button.new()
	ai_minus_btn.text = "- AI"
	ai_minus_btn.custom_minimum_size = Vector2(68.0, 38.0)
	ai_minus_btn.pressed.connect(func(): _adjust_room_config(0, false, -1))
	host_config_bar.add_child(ai_minus_btn)

	ai_count_label = Label.new()
	ai_count_label.text = "AI BOTS: 0"
	ai_count_label.add_theme_font_size_override("font_size", 15)
	host_config_bar.add_child(ai_count_label)

	ai_plus_btn = Button.new()
	ai_plus_btn.text = "+ AI"
	ai_plus_btn.custom_minimum_size = Vector2(68.0, 38.0)
	ai_plus_btn.pressed.connect(func(): _adjust_room_config(0, false, 1))
	host_config_bar.add_child(ai_plus_btn)

	# Bottom Room Action Buttons
	var act_hbox := HBoxContainer.new()
	act_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	act_hbox.add_theme_constant_override("separation", 16)
	_room_container.add_child(act_hbox)

	leave_room_button = Button.new()
	leave_room_button.name = "LeaveRoomButton"
	leave_room_button.text = "LEAVE ROOM"
	leave_room_button.custom_minimum_size = Vector2(165.0, 50.0)
	UIStyleHelper.apply_chunky_button_style(leave_room_button, UIStyleHelper.COLOR_CORAL_RED, UIStyleHelper.COLOR_CORAL_BORDER, 16, 14, 5)
	leave_room_button.pressed.connect(_on_leave_room_pressed)
	act_hbox.add_child(leave_room_button)

	ready_button = Button.new()
	ready_button.name = "RoomReadyButton"
	ready_button.text = "READY!"
	ready_button.custom_minimum_size = Vector2(175.0, 50.0)
	UIStyleHelper.apply_chunky_button_style(ready_button, UIStyleHelper.COLOR_SKY_BLUE, UIStyleHelper.COLOR_SKY_BORDER, 17, 14, 5)
	ready_button.pressed.connect(_on_ready_pressed)
	act_hbox.add_child(ready_button)

	start_match_button = Button.new()
	start_match_button.name = "StartRoomMatchButton"
	start_match_button.text = "START MATCH!"
	start_match_button.custom_minimum_size = Vector2(210.0, 50.0)
	UIStyleHelper.apply_chunky_button_style(start_match_button, UIStyleHelper.COLOR_PLAY_GREEN, UIStyleHelper.COLOR_PLAY_BORDER, 18, 16, 6)
	start_match_button.pressed.connect(_on_start_room_pressed)
	act_hbox.add_child(start_match_button)

	# --- PHASE 3: STATS, MATCH HISTORY & LEADERBOARD CONTAINER ---
	_stats_container = VBoxContainer.new()
	_stats_container.name = "StatsAndLeaderboardContainer"
	_stats_container.visible = false
	_stats_container.add_theme_constant_override("separation", 10)
	_stats_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(_stats_container)

	var prof_panel := PanelContainer.new()
	prof_panel.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.11, 0.19, 0.36, 0.95), Color(0.25, 0.88, 1.0), 14, 4, 14, 10)
	)
	_stats_container.add_child(prof_panel)

	_profile_summary_label = Label.new()
	_profile_summary_label.text = "Connect to the Dedicated Server to view your server-validated profile statistics."
	_profile_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_profile_summary_label.add_theme_font_size_override("font_size", 15)
	prof_panel.add_child(_profile_summary_label)

	var split_hbox := HBoxContainer.new()
	split_hbox.add_theme_constant_override("separation", 14)
	split_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stats_container.add_child(split_hbox)

	var lb_card := PanelContainer.new()
	lb_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lb_card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.10, 0.17, 0.32, 0.95), UIStyleHelper.COLOR_GOLD, 14, 4, 14, 10)
	)
	split_hbox.add_child(lb_card)

	_leaderboard_label = Label.new()
	_leaderboard_label.text = "GLOBAL LEADERBOARD\n(No matches recorded yet)"
	_leaderboard_label.add_theme_font_size_override("font_size", 13)
	lb_card.add_child(_leaderboard_label)

	var hist_card := PanelContainer.new()
	hist_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hist_card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.10, 0.17, 0.32, 0.95), UIStyleHelper.COLOR_PURPLE, 14, 4, 14, 10)
	)
	split_hbox.add_child(hist_card)

	_history_label = Label.new()
	_history_label.text = "RECENT MATCH HISTORY\n(No matches recorded yet)"
	_history_label.add_theme_font_size_override("font_size", 13)
	hist_card.add_child(_history_label)


func _populate_stats_and_leaderboard_ui() -> void:
	if not client or not client.is_connected_to_server():
		if _profile_summary_label:
			_profile_summary_label.text = "Connect to the Dedicated Server to view server-validated stats & leaderboards."
		return

	var prof := client.latest_profile
	var uname := str(prof.get("username", client.player_name))
	var wins := int(prof.get("wins", 0))
	var losses := int(prof.get("losses", 0))
	var draws := int(prof.get("draws", 0))
	var mp := int(prof.get("matches_played", 0))
	var elims := int(prof.get("eliminations", 0))

	if _profile_summary_label:
		_profile_summary_label.text = "PLAYER: %s   •   WINS: %d   •   LOSSES: %d   •   DRAWS: %d   •   MATCHES: %d   •   ELIMS: %d" % [
			uname, wins, losses, draws, mp, elims
		]

	var lb: Array = client.latest_stats_response.get("leaderboard", [])
	if _leaderboard_label:
		var lines := PackedStringArray(["GLOBAL LEADERBOARD (TOP PLAYERS)"])
		if lb.is_empty():
			lines.append("No players ranked yet.")
		else:
			for i in range(mini(8, lb.size())):
				var row: Dictionary = lb[i]
				lines.append("#%d  %s  —  %dW / %dL  (%d Elims)" % [
					int(row.get("rank", i + 1)),
					str(row.get("username", "PLAYER")),
					int(row.get("wins", 0)),
					int(row.get("losses", 0)),
					int(row.get("eliminations", 0))
				])
		_leaderboard_label.text = "\n".join(lines)

	var hist: Array = prof.get("match_history", [])
	if _history_label:
		var h_lines := PackedStringArray(["YOUR RECENT MATCHES"])
		if hist.is_empty():
			h_lines.append("No matches completed yet.")
		else:
			for i in range(mini(7, hist.size())):
				var h: Dictionary = hist[i]
				h_lines.append("• [%s] Winner: %s  |  %d Elims  |  R%d (Stage %d)" % [
					str(h.get("outcome", "MATCH")),
					str(h.get("winner_name", "NONE")),
					int(h.get("eliminations", 0)),
					int(h.get("rounds", 1)),
					int(h.get("final_stage", 1))
				])
		_history_label.text = "\n".join(h_lines)
