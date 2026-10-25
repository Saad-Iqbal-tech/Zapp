class_name MainMenuOverlay
extends Control
## Playful, colorful Stumble-Guys-inspired mobile Main Menu, How-To-Play modal,
## and Offline AI Matchmaking transition screen.

signal play_match_confirmed()
signal settings_requested()
signal exit_requested()
signal matchmaking_cancelled()

var play_button: Button
var online_lobby_button: Button
var settings_button: Button
var how_to_play_button: Button
var exit_button: Button
var cancel_matchmaking_button: Button
var close_how_to_button: Button
var online_modal: OnlineLobbyModal

var _lobby_container: Control
var _how_to_modal: Control
var _matchmaking_modal: Control
var _mm_status_label: Label
var _mm_sub_label: Label
var _mm_progress_bar: ProgressBar
var _mm_slot_panels: Array[PanelContainer] = []
var _mm_slot_status_labels: Array[Label] = []

var _wins_label: Label
var _tokens_label: Label
var _wins_count: int = 14
var _tokens_count: int = 850

var _is_matchmaking: bool = false
var _mm_elapsed: float = 0.0
var _mm_duration: float = 1.65
var _pulse_time: float = 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build_main_menu_ui()
	_build_how_to_play_modal()
	_build_matchmaking_modal()
	_build_online_lobby_modal()


func show_main_menu() -> void:
	visible = true
	_is_matchmaking = false
	if _lobby_container:
		_lobby_container.visible = true
	if _how_to_modal:
		_how_to_modal.visible = false
	if _matchmaking_modal:
		_matchmaking_modal.visible = false
	if online_modal:
		online_modal.visible = false


func hide_all() -> void:
	_is_matchmaking = false
	visible = false
	if _how_to_modal:
		_how_to_modal.visible = false
	if _matchmaking_modal:
		_matchmaking_modal.visible = false
	if online_modal:
		online_modal.visible = false


func award_victory_bonus() -> void:
	_wins_count += 1
	_tokens_count += 100
	if _wins_label:
		_wins_label.text = "WINS: %d" % _wins_count
	if _tokens_label:
		_tokens_label.text = "TOKENS: %d" % _tokens_count


func start_matchmaking() -> void:
	visible = true
	_is_matchmaking = true
	_mm_elapsed = 0.0
	if _lobby_container:
		_lobby_container.visible = false
	if _how_to_modal:
		_how_to_modal.visible = false
	if _matchmaking_modal:
		_matchmaking_modal.visible = true
	_update_matchmaking_visuals(0.0)


func cancel_matchmaking() -> void:
	if not _is_matchmaking:
		return
	_is_matchmaking = false
	show_main_menu()
	matchmaking_cancelled.emit()


func is_matchmaking_active() -> bool:
	return _is_matchmaking


func set_how_to_play_open(open: bool) -> void:
	if _how_to_modal:
		_how_to_modal.visible = open


func set_online_lobby_open(open: bool) -> void:
	if online_modal:
		if open:
			online_modal.open_modal()
		else:
			online_modal.close_modal()


func apply_safe_area_margins(safe_left: float, safe_top: float, safe_right: float, safe_bottom: float) -> void:
	if not _lobby_container:
		return
	_lobby_container.add_theme_constant_override("margin_left", int(round(maxf(28.0, 16.0 + safe_left))))
	_lobby_container.add_theme_constant_override("margin_right", int(round(maxf(28.0, 16.0 + safe_right))))
	_lobby_container.add_theme_constant_override("margin_top", int(round(maxf(22.0, 12.0 + safe_top))))
	_lobby_container.add_theme_constant_override("margin_bottom", int(round(maxf(26.0, 14.0 + safe_bottom))))


func _process(delta: float) -> void:
	if not visible:
		return

	_pulse_time += delta
	if play_button and _lobby_container and _lobby_container.visible and not play_button.is_hovered() and not play_button.button_pressed:
		play_button.pivot_offset = play_button.size * 0.5
		var s := 1.0 + 0.028 * sin(_pulse_time * 4.2)
		play_button.scale = Vector2(s, s)

	if _is_matchmaking:
		_mm_elapsed += delta
		var progress := clampf(_mm_elapsed / _mm_duration, 0.0, 1.0)
		_update_matchmaking_visuals(progress)
		if _mm_elapsed >= _mm_duration:
			_is_matchmaking = false
			hide_all()
			play_match_confirmed.emit()


func _update_matchmaking_visuals(progress: float) -> void:
	if _mm_progress_bar:
		_mm_progress_bar.value = progress * 100.0

	var active_bots := clampi(int(floor(progress * 5.0)) + 1, 1, 5)
	var dots := ".".repeat(1 + (int(_pulse_time * 4.0) % 3))

	if _mm_status_label:
		if progress < 0.35:
			_mm_status_label.text = "SETTING UP OFFLINE AI ARENA%s" % dots
		elif progress < 0.82:
			_mm_status_label.text = "SPAWNING AI OPPONENTS (%d/5)%s" % [active_bots, dots]
		else:
			_mm_status_label.text = "ALL 5 PLAYERS READY — ENTERING ARENA!"

	for i in range(_mm_slot_panels.size()):
		var slot_ready := (i < active_bots)
		var panel := _mm_slot_panels[i]
		var status_lbl := _mm_slot_status_labels[i]
		panel.modulate = Color(1, 1, 1, 1) if slot_ready else Color(0.55, 0.62, 0.75, 0.75)
		status_lbl.text = "READY!" if slot_ready else "JOINING..."
		status_lbl.add_theme_color_override(
			"font_color",
			Color(0.25, 1.0, 0.55) if slot_ready else Color(0.85, 0.88, 0.95)
		)


func _build_main_menu_ui() -> void:
	_lobby_container = MarginContainer.new()
	_lobby_container.name = "LobbySafeMargin"
	add_child(_lobby_container)
	_lobby_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lobby_container.add_theme_constant_override("margin_left", 28)
	_lobby_container.add_theme_constant_override("margin_right", 28)
	_lobby_container.add_theme_constant_override("margin_top", 22)
	_lobby_container.add_theme_constant_override("margin_bottom", 26)
	_lobby_container.mouse_filter = Control.MOUSE_FILTER_PASS

	var inner := Control.new()
	inner.mouse_filter = Control.MOUSE_FILTER_PASS
	_lobby_container.add_child(inner)

	# --- TOP-LEFT: Player Profile Card ---
	var profile_card := PanelContainer.new()
	profile_card.name = "ProfileCard"
	profile_card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.08, 0.14, 0.28, 0.94), Color(0.18, 0.82, 1.0), 20, 6, 14, 10)
	)
	inner.add_child(profile_card)
	profile_card.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	profile_card.offset_right = 278.0
	profile_card.offset_bottom = 78.0

	var prof_hbox := HBoxContainer.new()
	prof_hbox.add_theme_constant_override("separation", 12)
	profile_card.add_child(prof_hbox)

	# Colorful Avatar Badge
	var avatar_box := PanelContainer.new()
	avatar_box.custom_minimum_size = Vector2(54.0, 54.0)
	avatar_box.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.0, 0.78, 0.98), Color(1.0, 0.86, 0.2), 14, 4, 6, 6)
	)
	prof_hbox.add_child(avatar_box)

	var avatar_lbl := Label.new()
	avatar_lbl.text = "P1"
	avatar_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	avatar_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	avatar_lbl.add_theme_font_size_override("font_size", 22)
	avatar_lbl.add_theme_color_override("font_color", Color.WHITE)
	avatar_lbl.add_theme_color_override("font_outline_color", Color(0.04, 0.14, 0.32))
	avatar_lbl.add_theme_constant_override("outline_size", 6)
	avatar_box.add_child(avatar_lbl)

	var prof_vbox := VBoxContainer.new()
	prof_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	prof_vbox.add_theme_constant_override("separation", 2)
	prof_hbox.add_child(prof_vbox)

	var name_lbl := Label.new()
	name_lbl.text = "STRIKER_01"
	name_lbl.add_theme_font_size_override("font_size", 19)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.98, 0.90))
	name_lbl.add_theme_color_override("font_outline_color", Color(0.04, 0.08, 0.18))
	name_lbl.add_theme_constant_override("outline_size", 5)
	prof_vbox.add_child(name_lbl)

	var lvl_lbl := Label.new()
	lvl_lbl.text = "LVL 7  •  ARENA CONTENDER"
	lvl_lbl.add_theme_font_size_override("font_size", 12)
	lvl_lbl.add_theme_color_override("font_color", Color(0.45, 0.92, 1.0))
	prof_vbox.add_child(lvl_lbl)

	# --- TOP-RIGHT: Rewards / Trophies Pills ---
	var rewards_hbox := HBoxContainer.new()
	rewards_hbox.name = "RewardsBar"
	rewards_hbox.alignment = BoxContainer.ALIGNMENT_END
	rewards_hbox.add_theme_constant_override("separation", 12)
	inner.add_child(rewards_hbox)
	rewards_hbox.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	rewards_hbox.offset_left = -320.0
	rewards_hbox.offset_bottom = 54.0

	var wins_pill := PanelContainer.new()
	wins_pill.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.14, 0.18, 0.34, 0.94), UIStyleHelper.COLOR_GOLD, 16, 5, 14, 8)
	)
	rewards_hbox.add_child(wins_pill)

	_wins_label = Label.new()
	_wins_label.text = "WINS: %d" % _wins_count
	_wins_label.add_theme_font_size_override("font_size", 16)
	_wins_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.28))
	_wins_label.add_theme_color_override("font_outline_color", Color(0.18, 0.10, 0.02))
	_wins_label.add_theme_constant_override("outline_size", 5)
	wins_pill.add_child(_wins_label)

	var tokens_pill := PanelContainer.new()
	tokens_pill.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.14, 0.18, 0.34, 0.94), UIStyleHelper.COLOR_PURPLE, 16, 5, 14, 8)
	)
	rewards_hbox.add_child(tokens_pill)

	_tokens_label = Label.new()
	_tokens_label.text = "TOKENS: %d" % _tokens_count
	_tokens_label.add_theme_font_size_override("font_size", 16)
	_tokens_label.add_theme_color_override("font_color", Color(0.88, 0.65, 1.0))
	_tokens_label.add_theme_color_override("font_outline_color", Color(0.14, 0.04, 0.25))
	_tokens_label.add_theme_constant_override("outline_size", 5)
	tokens_pill.add_child(_tokens_label)

	# --- TOP-CENTER: Prominent Game Title Emblem ---
	var title_card := PanelContainer.new()
	title_card.name = "GameTitleBanner"
	title_card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.10, 0.18, 0.38, 0.92), UIStyleHelper.COLOR_GOLD, 26, 7, 26, 10)
	)
	inner.add_child(title_card)
	title_card.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	title_card.offset_left = -220.0
	title_card.offset_right = 220.0
	title_card.offset_top = 0.0
	title_card.offset_bottom = 104.0

	var title_vbox := VBoxContainer.new()
	title_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	title_vbox.add_theme_constant_override("separation", 0)
	title_card.add_child(title_vbox)

	var main_title := Label.new()
	main_title.text = "ZAPP ARENA"
	main_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_title.add_theme_font_size_override("font_size", 42)
	main_title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.18))
	main_title.add_theme_color_override("font_outline_color", Color(0.06, 0.10, 0.24))
	main_title.add_theme_constant_override("outline_size", 10)
	title_vbox.add_child(main_title)

	var sub_title := Label.new()
	sub_title.text = "5-PLAYER LASER SURVIVAL ROYALE"
	sub_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_title.add_theme_font_size_override("font_size", 14)
	sub_title.add_theme_color_override("font_color", Color(0.38, 0.96, 1.0))
	sub_title.add_theme_color_override("font_outline_color", Color(0.04, 0.08, 0.20))
	sub_title.add_theme_constant_override("outline_size", 5)
	title_vbox.add_child(sub_title)

	# --- CENTER-BOTTOM PEDESTAL TAG BELOW 3D CHARACTER ---
	var hero_tag := PanelContainer.new()
	hero_tag.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.06, 0.12, 0.24, 0.84), Color(0.0, 0.88, 1.0, 0.85), 16, 4, 16, 6)
	)
	inner.add_child(hero_tag)
	hero_tag.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hero_tag.offset_left = -145.0
	hero_tag.offset_right = 145.0
	hero_tag.offset_bottom = -98.0
	hero_tag.offset_top = -136.0

	var hero_lbl := Label.new()
	hero_lbl.text = "CHAMPION: YOU (CYAN)"
	hero_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hero_lbl.add_theme_font_size_override("font_size", 14)
	hero_lbl.add_theme_color_override("font_color", Color(0.55, 0.98, 1.0))
	hero_tag.add_child(hero_lbl)

	# --- BOTTOM-LEFT: Buttons for Settings, How to Play, Leaderboard, and Exit ---
	var nav_hbox := HBoxContainer.new()
	nav_hbox.name = "SecondaryNavButtons"
	nav_hbox.add_theme_constant_override("separation", 10)
	inner.add_child(nav_hbox)
	nav_hbox.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	nav_hbox.offset_top = -64.0
	nav_hbox.offset_right = 620.0

	settings_button = Button.new()
	settings_button.name = "MainMenuSettingsButton"
	settings_button.text = "SETTINGS"
	settings_button.custom_minimum_size = Vector2(130.0, 56.0)
	UIStyleHelper.apply_chunky_button_style(settings_button, UIStyleHelper.COLOR_SKY_BLUE, UIStyleHelper.COLOR_SKY_BORDER, 16, 14, 5)
	settings_button.pressed.connect(func(): settings_requested.emit())
	nav_hbox.add_child(settings_button)

	how_to_play_button = Button.new()
	how_to_play_button.name = "HowToPlayButton"
	how_to_play_button.text = "HOW TO PLAY"
	how_to_play_button.custom_minimum_size = Vector2(148.0, 56.0)
	UIStyleHelper.apply_chunky_button_style(how_to_play_button, UIStyleHelper.COLOR_PURPLE, UIStyleHelper.COLOR_PURPLE_BORDER, 16, 14, 5)
	how_to_play_button.pressed.connect(func(): set_how_to_play_open(true))
	nav_hbox.add_child(how_to_play_button)

	var leaderboard_button := Button.new()
	leaderboard_button.name = "MainMenuLeaderboardButton"
	leaderboard_button.text = "RANKS"
	leaderboard_button.custom_minimum_size = Vector2(120.0, 56.0)
	UIStyleHelper.apply_chunky_button_style(leaderboard_button, UIStyleHelper.COLOR_GOLD, UIStyleHelper.COLOR_GOLD_BORDER, 16, 14, 5)
	leaderboard_button.pressed.connect(func():
		set_online_lobby_open(true)
		if online_modal:
			if not online_modal._showing_stats:
				online_modal.toggle_stats_view()
	)
	nav_hbox.add_child(leaderboard_button)

	exit_button = Button.new()
	exit_button.name = "ExitGameButton"
	exit_button.text = "EXIT"
	exit_button.custom_minimum_size = Vector2(98.0, 56.0)
	UIStyleHelper.apply_chunky_button_style(exit_button, UIStyleHelper.COLOR_CORAL_RED, UIStyleHelper.COLOR_CORAL_BORDER, 16, 14, 5)
	exit_button.pressed.connect(func():
		exit_requested.emit()
		if get_tree():
			get_tree().quit()
	)
	nav_hbox.add_child(exit_button)

	# --- BOTTOM-RIGHT: Online Lobby + Large Visually Dominant PLAY Button ---
	var play_vbox := VBoxContainer.new()
	play_vbox.alignment = BoxContainer.ALIGNMENT_END
	play_vbox.add_theme_constant_override("separation", 8)
	inner.add_child(play_vbox)
	play_vbox.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	play_vbox.offset_left = -280.0
	play_vbox.offset_top = -176.0

	online_lobby_button = Button.new()
	online_lobby_button.name = "OnlineLobbyButton"
	online_lobby_button.text = "ONLINE LOBBY"
	online_lobby_button.custom_minimum_size = Vector2(268.0, 52.0)
	UIStyleHelper.apply_chunky_button_style(online_lobby_button, UIStyleHelper.COLOR_SKY_BLUE, UIStyleHelper.COLOR_SKY_BORDER, 20, 18, 6)
	online_lobby_button.pressed.connect(func(): set_online_lobby_open(true))
	play_vbox.add_child(online_lobby_button)

	var mode_lbl := Label.new()
	mode_lbl.text = "SOLO VS 4 AI OPPONENTS"
	mode_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mode_lbl.add_theme_font_size_override("font_size", 13)
	mode_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.45))
	mode_lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.08, 0.18))
	mode_lbl.add_theme_constant_override("outline_size", 5)
	play_vbox.add_child(mode_lbl)

	play_button = Button.new()
	play_button.name = "PlayMatchButton"
	play_button.text = "PLAY!"
	play_button.custom_minimum_size = Vector2(268.0, 82.0)
	UIStyleHelper.apply_chunky_button_style(play_button, UIStyleHelper.COLOR_PLAY_GREEN, UIStyleHelper.COLOR_PLAY_BORDER, 32, 24, 9)
	play_button.pressed.connect(func(): start_matchmaking())
	play_vbox.add_child(play_button)


func _build_online_lobby_modal() -> void:
	online_modal = OnlineLobbyModal.new()
	online_modal.name = "OnlineLobbyModal"
	online_modal.visible = false
	add_child(online_modal)


func _build_how_to_play_modal() -> void:
	_how_to_modal = Control.new()
	_how_to_modal.name = "HowToPlayModal"
	_how_to_modal.visible = false
	_how_to_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_how_to_modal)
	_how_to_modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dimmer := ColorRect.new()
	dimmer.color = Color(0.02, 0.05, 0.12, 0.78)
	_how_to_modal.add_child(dimmer)
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.09, 0.15, 0.30, 0.98), UIStyleHelper.COLOR_GOLD, 26, 8, 26, 22)
	)
	_how_to_modal.add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.offset_left = -330.0
	card.offset_right = 330.0
	card.offset_top = -205.0
	card.offset_bottom = 205.0

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	card.add_child(vbox)

	var header := Label.new()
	header.text = "HOW TO PLAY ZAPP ARENA"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 28)
	header.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
	header.add_theme_color_override("font_outline_color", Color(0.04, 0.08, 0.18))
	header.add_theme_constant_override("outline_size", 7)
	vbox.add_child(header)

	var rules: Array[String] = [
		"1. DUAL TOUCH CONTROLS: Drag the bottom-left virtual joystick to MOVE and the bottom-right pad to AIM your laser.",
		"2. 5-SECOND STEALTH PREP: During the 5s countdown, you are invincible and opponents are hidden. Use solid blocks for cover!",
		"3. SIMULTANEOUS LASER BLAST: At 0.0s, everyone is revealed and fires at once! If two players hit each other, both are eliminated.",
		"4. SHRINKING PLATFORM: Watch out for the red danger border! Outer floor tiles collapse in stages (100% -> 72% -> 45% -> 22%)."
	]

	for rule_text in rules:
		var rule_panel := PanelContainer.new()
		rule_panel.add_theme_stylebox_override(
			"panel",
			UIStyleHelper.create_card_style(Color(0.13, 0.21, 0.40, 0.92), Color(0.28, 0.72, 1.0, 0.8), 14, 4, 14, 10)
		)
		vbox.add_child(rule_panel)

		var lbl := Label.new()
		lbl.text = rule_text
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.add_theme_font_size_override("font_size", 15)
		lbl.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
		rule_panel.add_child(lbl)

	var btn_box := HBoxContainer.new()
	btn_box.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_box)

	close_how_to_button = Button.new()
	close_how_to_button.name = "CloseHowToPlayButton"
	close_how_to_button.text = "GOT IT!"
	close_how_to_button.custom_minimum_size = Vector2(200.0, 54.0)
	UIStyleHelper.apply_chunky_button_style(close_how_to_button, UIStyleHelper.COLOR_PLAY_GREEN, UIStyleHelper.COLOR_PLAY_BORDER, 20, 18, 6)
	close_how_to_button.pressed.connect(func(): set_how_to_play_open(false))
	btn_box.add_child(close_how_to_button)


func _build_matchmaking_modal() -> void:
	_matchmaking_modal = Control.new()
	_matchmaking_modal.name = "MatchmakingOverlay"
	_matchmaking_modal.visible = false
	_matchmaking_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_matchmaking_modal)
	_matchmaking_modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dimmer := ColorRect.new()
	dimmer.color = Color(0.03, 0.07, 0.16, 0.84)
	_matchmaking_modal.add_child(dimmer)
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.09, 0.16, 0.32, 0.98), Color(0.22, 0.86, 1.0), 28, 8, 28, 24)
	)
	_matchmaking_modal.add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.offset_left = -335.0
	card.offset_right = 335.0
	card.offset_top = -195.0
	card.offset_bottom = 195.0

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	card.add_child(vbox)

	var mode_badge := Label.new()
	mode_badge.text = "LOCAL AI ARENA MATCH  •  NO INTERNET REQUIRED"
	mode_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mode_badge.add_theme_font_size_override("font_size", 14)
	mode_badge.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
	vbox.add_child(mode_badge)

	_mm_status_label = Label.new()
	_mm_status_label.text = "PREPARING AI MATCH..."
	_mm_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mm_status_label.add_theme_font_size_override("font_size", 26)
	_mm_status_label.add_theme_color_override("font_color", Color.WHITE)
	_mm_status_label.add_theme_color_override("font_outline_color", Color(0.04, 0.08, 0.20))
	_mm_status_label.add_theme_constant_override("outline_size", 7)
	vbox.add_child(_mm_status_label)

	# 5 Player Slot Cards (1 Human + 4 AI)
	var slots_hbox := HBoxContainer.new()
	slots_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	slots_hbox.add_theme_constant_override("separation", 10)
	vbox.add_child(slots_hbox)

	var slot_defs: Array[Dictionary] = [
		{"name": "YOU", "role": "HUMAN", "col": Color(0.0, 0.86, 1.0)},
		{"name": "VEX", "role": "AI BOT", "col": Color(1.0, 0.24, 0.36)},
		{"name": "NOVA", "role": "AI BOT", "col": Color(0.12, 0.90, 0.46)},
		{"name": "SOL", "role": "AI BOT", "col": Color(1.0, 0.80, 0.14)},
		{"name": "NYX", "role": "AI BOT", "col": Color(0.82, 0.28, 1.0)}
	]

	_mm_slot_panels.clear()
	_mm_slot_status_labels.clear()

	for s_def in slot_defs:
		var slot_p := PanelContainer.new()
		slot_p.custom_minimum_size = Vector2(112.0, 96.0)
		var col: Color = s_def["col"]
		slot_p.add_theme_stylebox_override(
			"panel",
			UIStyleHelper.create_card_style(Color(col.r * 0.24, col.g * 0.24, col.b * 0.30, 0.95), col, 16, 5, 10, 8)
		)
		slots_hbox.add_child(slot_p)

		var sv := VBoxContainer.new()
		sv.alignment = BoxContainer.ALIGNMENT_CENTER
		sv.add_theme_constant_override("separation", 4)
		slot_p.add_child(sv)

		var n_lbl := Label.new()
		n_lbl.text = str(s_def["name"])
		n_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		n_lbl.add_theme_font_size_override("font_size", 18)
		n_lbl.add_theme_color_override("font_color", Color.WHITE)
		sv.add_child(n_lbl)

		var r_lbl := Label.new()
		r_lbl.text = str(s_def["role"])
		r_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		r_lbl.add_theme_font_size_override("font_size", 11)
		r_lbl.add_theme_color_override("font_color", col.lightened(0.35))
		sv.add_child(r_lbl)

		var st_lbl := Label.new()
		st_lbl.text = "READY!"
		st_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		st_lbl.add_theme_font_size_override("font_size", 12)
		sv.add_child(st_lbl)

		_mm_slot_panels.append(slot_p)
		_mm_slot_status_labels.append(st_lbl)

	_mm_progress_bar = ProgressBar.new()
	_mm_progress_bar.custom_minimum_size = Vector2(480.0, 18.0)
	_mm_progress_bar.max_value = 100.0
	_mm_progress_bar.value = 20.0
	_mm_progress_bar.show_percentage = false
	vbox.add_child(_mm_progress_bar)

	var cancel_hbox := HBoxContainer.new()
	cancel_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(cancel_hbox)

	cancel_matchmaking_button = Button.new()
	cancel_matchmaking_button.name = "CancelMatchmakingButton"
	cancel_matchmaking_button.text = "CANCEL"
	cancel_matchmaking_button.custom_minimum_size = Vector2(180.0, 52.0)
	UIStyleHelper.apply_chunky_button_style(
		cancel_matchmaking_button,
		UIStyleHelper.COLOR_CORAL_RED,
		UIStyleHelper.COLOR_CORAL_BORDER,
		19,
		18,
		6
	)
	cancel_matchmaking_button.pressed.connect(func(): cancel_matchmaking())
	cancel_hbox.add_child(cancel_matchmaking_button)
