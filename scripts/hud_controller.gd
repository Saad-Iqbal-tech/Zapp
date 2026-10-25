class_name HUDController
extends CanvasLayer
## Polished, colorful mobile party-game HUD & UI coordinator:
## - MainMenuOverlay (3D Lobby showcase, Profile, Rewards, How to Play, Offline AI Matchmaking)
## - In-Game HUD (Top-center countdown card, 5-player status dots, animated shrink warning, virtual pads)
## - Settings Modal (Master Volume, Music Volume, SFX Volume, Camera Sensitivity, Mute toggle)
## - Spectator Overlay (< PREV / NEXT > controls + Return to Menu button)
## - Celebratory Winner / Draw Screen (Animated confetti particles, Replay, and Return to Menu buttons)

signal play_match_requested()
signal spectator_prev_requested()
signal spectator_next_requested()
signal replay_requested()
signal return_to_lobby_requested()
signal master_volume_changed(linear_value: float)
signal music_volume_changed(linear_value: float)
signal sfx_volume_changed(linear_value: float)
signal camera_sensitivity_changed(multiplier: float)
signal sound_mute_toggled(muted: bool)

var mobile_controls: MobileControls
var main_menu: MainMenuOverlay

var _root_control: Control
var _in_game_hud_root: Control
var _top_card: PanelContainer
var _countdown_label: Label
var _countdown_bar: ProgressBar
var _status_sub_label: Label
var _player_dots_hbox: HBoxContainer
var _player_dots: Dictionary = {} # player_id -> Panel

var _warning_panel: PanelContainer
var _warning_label: Label
var _toast_panel: PanelContainer
var _toast_label: Label
var _toast_timer: float = 0.0
var _anim_time: float = 0.0

var _alive_count: int = 5
var _total_count: int = 5
var _current_stage: int = 1
var _current_stage_pct: int = 100

var _menu_button: Button
var _menu_overlay: Control
var _master_slider: HSlider
var _master_val_label: Label
var _music_slider: HSlider
var _music_val_label: Label
var _sfx_slider: HSlider
var _sfx_val_label: Label
var _sens_slider: HSlider
var _sens_val_label: Label
var _mute_check: CheckButton
var _menu_lobby_btn: Button
var _menu_resume_btn: Button

var _spectator_panel: PanelContainer
var _spectator_target_label: Label
var _prev_spec_btn: Button
var _next_spec_btn: Button
var _spec_menu_btn: Button

var _result_overlay: Control
var _confetti_canvas: Control
var _result_badge_label: Label
var _result_title_label: Label
var _result_subtitle_label: Label
var _replay_button: Button
var _result_lobby_button: Button

var _confetti_items: Array[Dictionary] = []


func _ready() -> void:
	layer = 10
	_build_ui()
	if get_viewport():
		get_viewport().size_changed.connect(apply_safe_area_layout)
	apply_safe_area_layout()


func set_simulated_safe_insets(insets: Vector4) -> void:
	if mobile_controls:
		mobile_controls.simulated_safe_insets = insets
		mobile_controls.queue_redraw()
	apply_safe_area_layout()


func apply_safe_area_layout() -> void:
	var insets := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	if mobile_controls:
		insets = mobile_controls.get_safe_insets()
	var safe_left := float(insets.get("left", 0.0))
	var safe_top := float(insets.get("top", 0.0))
	var safe_right := float(insets.get("right", 0.0))
	var safe_bottom := float(insets.get("bottom", 0.0))

	if _top_card:
		var top_y := maxf(12.0, 6.0 + safe_top)
		_top_card.offset_top = top_y
		_top_card.offset_bottom = top_y + 86.0

	if _menu_button:
		var right_pad := maxf(24.0, 16.0 + safe_right)
		var top_pad := maxf(18.0, 10.0 + safe_top)
		_menu_button.offset_right = -right_pad
		_menu_button.offset_left = -(right_pad + 128.0)
		_menu_button.offset_top = top_pad
		_menu_button.offset_bottom = top_pad + 48.0

	if _spectator_panel:
		var bot_pad := maxf(22.0, 12.0 + safe_bottom)
		_spectator_panel.offset_bottom = -bot_pad
		_spectator_panel.offset_top = -(bot_pad + 102.0)

	if main_menu:
		main_menu.apply_safe_area_margins(safe_left, safe_top, safe_right, safe_bottom)


func show_main_menu_lobby() -> void:
	if _in_game_hud_root:
		_in_game_hud_root.visible = false
	if mobile_controls:
		mobile_controls.set_controls_active(false)
	if _spectator_panel:
		_spectator_panel.visible = false
	if _result_overlay:
		_result_overlay.visible = false
	if _menu_overlay:
		_menu_overlay.visible = false
	if main_menu:
		main_menu.show_main_menu()


func show_in_game_hud() -> void:
	if main_menu:
		main_menu.hide_all()
	if _in_game_hud_root:
		_in_game_hud_root.visible = true
	if _result_overlay:
		_result_overlay.visible = false
	if _spectator_panel:
		_spectator_panel.visible = false
	if _menu_overlay:
		_menu_overlay.visible = false
	if mobile_controls:
		mobile_controls.set_controls_active(true)


func is_in_main_menu() -> bool:
	return main_menu != null and main_menu.visible


func setup_player_badges(characters: Array[CharacterController]) -> void:
	_total_count = characters.size()
	if _player_dots_hbox:
		for child in _player_dots_hbox.get_children():
			_player_dots_hbox.remove_child(child)
			child.free()
		_player_dots.clear()

		for c in characters:
			var dot := Panel.new()
			dot.custom_minimum_size = Vector2(18.0, 12.0)
			var ds := StyleBoxFlat.new()
			ds.bg_color = c.primary_color
			ds.border_color = Color.WHITE
			ds.set_border_width_all(2)
			ds.set_corner_radius_all(6)
			dot.add_theme_stylebox_override("panel", ds)
			_player_dots_hbox.add_child(dot)
			_player_dots[c.player_id] = dot

	update_player_badges(characters, _total_count)


func update_player_badges(characters: Array[CharacterController], _alive_param: int) -> void:
	var surviving_count := 0
	for c in characters:
		var alive_or_win := c.is_alive() or c.current_state == CharacterController.State.WINNER
		if alive_or_win:
			surviving_count += 1
		if _player_dots.has(c.player_id):
			var dot: Panel = _player_dots[c.player_id]
			dot.modulate = Color(1, 1, 1, 1) if alive_or_win else Color(0.3, 0.32, 0.38, 0.45)

	_alive_count = surviving_count
	_total_count = characters.size()
	_refresh_status_sub_label()


func update_round_timer(_round_num: int, _phase_text: String, time_left: float, max_time: float, is_firing: bool) -> void:
	if _countdown_label:
		if is_firing:
			_countdown_label.text = "LASERS FIRE!"
			_countdown_label.add_theme_color_override("font_color", Color(1.0, 0.30, 0.28))
		else:
			_countdown_label.text = "%.1fs" % maxf(0.0, time_left)
			if time_left <= 1.5:
				_countdown_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.28))
			elif time_left <= 3.0:
				_countdown_label.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
			else:
				_countdown_label.add_theme_color_override("font_color", Color(0.45, 0.98, 1.0))

	if _countdown_bar:
		_countdown_bar.max_value = maxf(0.01, max_time)
		_countdown_bar.value = clampf(time_left, 0.0, max_time)


func update_arena_stage_info(
	stage: int,
	width_ratio: float,
	warning_active: bool,
	_next_stage: int,
	next_ratio: float,
	shrink_countdown: float
) -> void:
	_current_stage = stage
	_current_stage_pct = int(round(width_ratio * 100.0))
	_refresh_status_sub_label()

	if _warning_panel and _warning_label:
		if warning_active and stage < 4:
			var next_pct := int(round(next_ratio * 100.0))
			_warning_panel.visible = true
			_warning_label.text = "DANGER! SHRINKING TO %d%% IN %.1fs" % [next_pct, maxf(0.0, shrink_countdown)]
		else:
			_warning_panel.visible = false


func show_toast(message: String, duration: float = 2.0) -> void:
	if not _toast_panel or not _toast_label:
		return
	_toast_label.text = message
	_toast_panel.visible = true
	_toast_panel.pivot_offset = _toast_panel.size * 0.5
	_toast_panel.scale = Vector2(0.88, 0.88)
	var tw := create_tween()
	tw.tween_property(_toast_panel, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_toast_timer = duration


func set_spectator_mode_ui(active: bool, target_name: String = "") -> void:
	if _spectator_panel:
		_spectator_panel.visible = active
	if _spectator_target_label and active:
		_spectator_target_label.text = "FOLLOWING: %s" % target_name
	if mobile_controls:
		mobile_controls.set_controls_active(not active and not is_menu_open() and not is_in_main_menu())


func set_menu_open(open: bool) -> void:
	if not _menu_overlay:
		return
	_menu_overlay.visible = open
	if _menu_lobby_btn:
		_menu_lobby_btn.visible = not is_in_main_menu()
	if mobile_controls:
		var spec_active := _spectator_panel != null and _spectator_panel.visible
		var res_active := _result_overlay != null and _result_overlay.visible
		mobile_controls.set_controls_active(not open and not spec_active and not res_active and not is_in_main_menu())


func is_menu_open() -> bool:
	return _menu_overlay != null and _menu_overlay.visible


func show_match_result(is_draw: bool, winner: CharacterController, rounds_completed: int, final_stage: int) -> void:
	if mobile_controls:
		mobile_controls.set_controls_active(false)
	if _spectator_panel:
		_spectator_panel.visible = false
	if _warning_panel:
		_warning_panel.visible = false
	if _menu_overlay:
		_menu_overlay.visible = false

	_result_overlay.visible = true
	_spawn_confetti_particles()

	if is_draw or winner == null:
		if _result_badge_label:
			_result_badge_label.text = "SIMULTANEOUS KNOCKOUT"
		_result_title_label.text = "DRAW — NO SURVIVORS!"
		_result_title_label.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
		_result_subtitle_label.text = "Everyone was eliminated on the same blast!  •  Round %d" % rounds_completed
	else:
		if winner.is_human:
			if main_menu:
				main_menu.award_victory_bonus()
			if _result_badge_label:
				_result_badge_label.text = "CROWN CLAIMED!  +100 TOKENS"
			_result_title_label.text = "VICTORY! YOU WON!"
			_result_title_label.add_theme_color_override("font_color", Color(0.25, 1.0, 0.58))
		else:
			if _result_badge_label:
				_result_badge_label.text = "MATCH COMPLETE"
			_result_title_label.text = "%s WINS THE CROWN!" % winner.display_name
			_result_title_label.add_theme_color_override("font_color", winner.accent_color)

		_result_subtitle_label.text = "Champion: %s   •   Round %d   •   Stage %d (%d%%)" % [
			winner.display_name,
			rounds_completed,
			final_stage,
			int(round(ArenaGenerator.STAGE_WIDTH_RATIOS.get(final_stage, 1.0) * 100.0))
		]


func hide_match_result() -> void:
	if _result_overlay:
		_result_overlay.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event := event as InputEventKey
		if key_event.keycode == KEY_ESCAPE:
			set_menu_open(not is_menu_open())
		elif _spectator_panel and _spectator_panel.visible and not is_menu_open():
			if key_event.keycode == KEY_LEFT or key_event.keycode == KEY_A:
				spectator_prev_requested.emit()
			elif key_event.keycode == KEY_RIGHT or key_event.keycode == KEY_D or key_event.keycode == KEY_SPACE:
				spectator_next_requested.emit()
	elif event is InputEventScreenTouch and event.pressed:
		var touch := event as InputEventScreenTouch
		if _spectator_panel and _spectator_panel.visible and not is_menu_open():
			var vp := get_viewport().get_visible_rect().size
			if touch.position.y > 76.0 and touch.position.y < vp.y - 118.0:
				if touch.position.x < vp.x * 0.5:
					spectator_prev_requested.emit()
				else:
					spectator_next_requested.emit()


func _process(delta: float) -> void:
	_anim_time += delta

	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0 and _toast_panel:
			_toast_panel.visible = false

	if _warning_panel and _warning_panel.visible:
		var pulse := 1.0 + 0.04 * sin(_anim_time * 12.0)
		_warning_panel.pivot_offset = _warning_panel.size * 0.5
		_warning_panel.scale = Vector2(pulse, pulse)

	if _result_overlay and _result_overlay.visible and _confetti_canvas:
		_update_confetti_particles(delta)
		_confetti_canvas.queue_redraw()


func _refresh_status_sub_label() -> void:
	if _status_sub_label:
		_status_sub_label.text = "ALIVE: %d/%d   •   STAGE %d (%d%%)" % [
			_alive_count,
			_total_count,
			_current_stage,
			_current_stage_pct
		]


func _build_ui() -> void:
	_root_control = Control.new()
	_root_control.name = "HUDRoot"
	_root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var party_theme := load("res://ui/party_theme.tres") as Theme
	if party_theme:
		_root_control.theme = party_theme
	add_child(_root_control)
	_root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# 1. In-Game HUD Container
	_in_game_hud_root = Control.new()
	_in_game_hud_root.name = "InGameHUD"
	_in_game_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root_control.add_child(_in_game_hud_root)
	_in_game_hud_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Mobile Dual Touch Controls (Bottom-Left Joystick & Bottom-Right Aim Pad)
	mobile_controls = MobileControls.new()
	mobile_controls.name = "MobileControls"
	_in_game_hud_root.add_child(mobile_controls)
	mobile_controls.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Top-Center Party Countdown & Alive Card
	var top_card := PanelContainer.new()
	_top_card = top_card
	top_card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.08, 0.14, 0.28, 0.92), Color(0.25, 0.84, 1.0), 22, 6, 18, 8)
	)
	_in_game_hud_root.add_child(top_card)
	top_card.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	top_card.offset_top = 12.0
	top_card.offset_bottom = 98.0
	top_card.offset_left = -155.0
	top_card.offset_right = 155.0

	var top_vbox := VBoxContainer.new()
	top_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	top_vbox.add_theme_constant_override("separation", 3)
	top_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_card.add_child(top_vbox)

	_countdown_label = Label.new()
	_countdown_label.text = "5.0s"
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.add_theme_font_size_override("font_size", 28)
	_countdown_label.add_theme_color_override("font_color", Color(0.45, 0.98, 1.0))
	_countdown_label.add_theme_color_override("font_outline_color", Color(0.04, 0.08, 0.18))
	_countdown_label.add_theme_constant_override("outline_size", 7)
	top_vbox.add_child(_countdown_label)

	_countdown_bar = ProgressBar.new()
	_countdown_bar.show_percentage = false
	_countdown_bar.custom_minimum_size = Vector2(230.0, 8.0)
	_countdown_bar.max_value = 5.0
	_countdown_bar.value = 5.0
	top_vbox.add_child(_countdown_bar)

	var status_row := HBoxContainer.new()
	status_row.alignment = BoxContainer.ALIGNMENT_CENTER
	status_row.add_theme_constant_override("separation", 10)
	top_vbox.add_child(status_row)

	_status_sub_label = Label.new()
	_status_sub_label.text = "ALIVE: 5/5   •   STAGE 1 (100%)"
	_status_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_sub_label.add_theme_font_size_override("font_size", 12)
	_status_sub_label.add_theme_color_override("font_color", Color(0.90, 0.95, 1.0))
	status_row.add_child(_status_sub_label)

	_player_dots_hbox = HBoxContainer.new()
	_player_dots_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_player_dots_hbox.add_theme_constant_override("separation", 4)
	status_row.add_child(_player_dots_hbox)

	# Top-Right Settings / Pause Button (respecting Android safe area margins)
	_menu_button = Button.new()
	_menu_button.name = "MenuButton"
	_menu_button.text = "SETTINGS"
	_in_game_hud_root.add_child(_menu_button)
	_menu_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_menu_button.offset_right = -24.0
	_menu_button.offset_left = -152.0
	_menu_button.offset_top = 18.0
	_menu_button.offset_bottom = 66.0
	UIStyleHelper.apply_chunky_button_style(_menu_button, UIStyleHelper.COLOR_SKY_BLUE, UIStyleHelper.COLOR_SKY_BORDER, 16, 16, 6)
	_menu_button.pressed.connect(func(): set_menu_open(not is_menu_open()))

	# Animated Shrinking-Arena Warning Pill
	_warning_panel = PanelContainer.new()
	_warning_panel.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.68, 0.10, 0.16, 0.94), UIStyleHelper.COLOR_GOLD, 16, 5, 16, 6)
	)
	_in_game_hud_root.add_child(_warning_panel)
	_warning_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_warning_panel.offset_top = 104.0
	_warning_panel.offset_bottom = 138.0
	_warning_panel.offset_left = -215.0
	_warning_panel.offset_right = 215.0
	_warning_panel.visible = false

	_warning_label = Label.new()
	_warning_label.text = "DANGER! SHRINKING TO 72%"
	_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warning_label.add_theme_font_size_override("font_size", 14)
	_warning_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.65))
	_warning_panel.add_child(_warning_label)

	# Elimination / Event Toast Pill
	_toast_panel = PanelContainer.new()
	_toast_panel.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.12, 0.20, 0.38, 0.92), UIStyleHelper.COLOR_GOLD, 16, 4, 16, 6)
	)
	_in_game_hud_root.add_child(_toast_panel)
	_toast_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast_panel.offset_top = 144.0
	_toast_panel.offset_bottom = 180.0
	_toast_panel.offset_left = -230.0
	_toast_panel.offset_right = 230.0
	_toast_panel.visible = false

	_toast_label = Label.new()
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.add_theme_font_size_override("font_size", 16)
	_toast_label.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
	_toast_panel.add_child(_toast_label)

	# 2. Spectator Mode Bar (Bottom-Center)
	_build_spectator_bar()

	# 3. Main Menu Lobby & Matchmaking Overlay
	var menu_scene := load("res://ui/main_menu_overlay.tscn") as PackedScene
	main_menu = (menu_scene.instantiate() as MainMenuOverlay) if menu_scene else MainMenuOverlay.new()
	main_menu.name = "MainMenuOverlay"
	main_menu.visible = false
	_root_control.add_child(main_menu)
	main_menu.play_match_confirmed.connect(func(): play_match_requested.emit())
	main_menu.settings_requested.connect(func(): set_menu_open(true))

	# 4. Settings Modal (Master Volume, Music, SFX, Camera Sensitivity, Mute, Return to Menu)
	_build_settings_modal()

	# 5. Celebratory Winner / Draw Screen Overlay
	_build_result_modal()


func _build_spectator_bar() -> void:
	_spectator_panel = PanelContainer.new()
	_spectator_panel.name = "SpectatorPanel"
	_spectator_panel.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.08, 0.14, 0.28, 0.95), UIStyleHelper.COLOR_GOLD, 24, 7, 20, 12)
	)
	_in_game_hud_root.add_child(_spectator_panel)
	_spectator_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_spectator_panel.offset_bottom = -22.0
	_spectator_panel.offset_top = -124.0
	_spectator_panel.offset_left = -345.0
	_spectator_panel.offset_right = 345.0
	_spectator_panel.visible = false
	_spectator_panel.mouse_filter = Control.MOUSE_FILTER_PASS

	var spec_vbox := VBoxContainer.new()
	spec_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	spec_vbox.add_theme_constant_override("separation", 6)
	spec_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	_spectator_panel.add_child(spec_vbox)

	var header_lbl := Label.new()
	header_lbl.text = "ELIMINATED  •  SPECTATOR MODE"
	header_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header_lbl.add_theme_font_size_override("font_size", 13)
	header_lbl.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
	spec_vbox.add_child(header_lbl)

	var spec_hbox := HBoxContainer.new()
	spec_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	spec_hbox.add_theme_constant_override("separation", 14)
	spec_hbox.mouse_filter = Control.MOUSE_FILTER_PASS
	spec_vbox.add_child(spec_hbox)

	_prev_spec_btn = Button.new()
	_prev_spec_btn.name = "PrevSpectatorButton"
	_prev_spec_btn.text = "< PREV"
	_prev_spec_btn.custom_minimum_size = Vector2(130.0, 48.0)
	UIStyleHelper.apply_chunky_button_style(_prev_spec_btn, UIStyleHelper.COLOR_SKY_BLUE, UIStyleHelper.COLOR_SKY_BORDER, 17, 16, 6)
	_prev_spec_btn.pressed.connect(func(): spectator_prev_requested.emit())
	spec_hbox.add_child(_prev_spec_btn)

	_spectator_target_label = Label.new()
	_spectator_target_label.text = "FOLLOWING: VEX"
	_spectator_target_label.custom_minimum_size = Vector2(195.0, 40.0)
	_spectator_target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spectator_target_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_spectator_target_label.add_theme_font_size_override("font_size", 18)
	_spectator_target_label.add_theme_color_override("font_color", Color(0.45, 0.98, 1.0))
	spec_hbox.add_child(_spectator_target_label)

	_next_spec_btn = Button.new()
	_next_spec_btn.name = "NextSpectatorButton"
	_next_spec_btn.text = "NEXT >"
	_next_spec_btn.custom_minimum_size = Vector2(130.0, 48.0)
	UIStyleHelper.apply_chunky_button_style(_next_spec_btn, UIStyleHelper.COLOR_SKY_BLUE, UIStyleHelper.COLOR_SKY_BORDER, 17, 16, 6)
	_next_spec_btn.pressed.connect(func(): spectator_next_requested.emit())
	spec_hbox.add_child(_next_spec_btn)

	_spec_menu_btn = Button.new()
	_spec_menu_btn.name = "SpectatorMenuButton"
	_spec_menu_btn.text = "MAIN MENU"
	_spec_menu_btn.custom_minimum_size = Vector2(145.0, 48.0)
	UIStyleHelper.apply_chunky_button_style(_spec_menu_btn, UIStyleHelper.COLOR_CORAL_RED, UIStyleHelper.COLOR_CORAL_BORDER, 16, 16, 6)
	_spec_menu_btn.pressed.connect(func(): return_to_lobby_requested.emit())
	spec_hbox.add_child(_spec_menu_btn)


func _build_settings_modal() -> void:
	_menu_overlay = Control.new()
	_menu_overlay.name = "MenuOverlay"
	_menu_overlay.visible = false
	_menu_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_root_control.add_child(_menu_overlay)
	_menu_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dimmer := ColorRect.new()
	dimmer.color = Color(0.02, 0.05, 0.12, 0.76)
	dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu_overlay.add_child(dimmer)
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.09, 0.15, 0.30, 0.98), Color(0.28, 0.84, 1.0), 26, 8, 26, 22)
	)
	card.mouse_filter = Control.MOUSE_FILTER_PASS
	_menu_overlay.add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.offset_left = -265.0
	card.offset_right = 265.0
	card.offset_top = -215.0
	card.offset_bottom = 215.0

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	card.add_child(vbox)

	var title := Label.new()
	title.text = "GAME SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
	title.add_theme_color_override("font_outline_color", Color(0.04, 0.08, 0.18))
	title.add_theme_constant_override("outline_size", 7)
	vbox.add_child(title)

	# Master Volume Slider
	var master_row := _create_slider_row("Master Vol", 100.0, 0.0, 100.0)
	_master_slider = master_row["slider"]
	_master_val_label = master_row["val_label"]
	vbox.add_child(master_row["row"])
	_master_slider.value_changed.connect(func(val: float):
		_master_val_label.text = "%d%%" % int(round(val))
		master_volume_changed.emit(val / 100.0)
	)

	# Music Volume Slider
	var music_row := _create_slider_row("Music Vol", 80.0, 0.0, 100.0)
	_music_slider = music_row["slider"]
	_music_val_label = music_row["val_label"]
	vbox.add_child(music_row["row"])
	_music_slider.value_changed.connect(func(val: float):
		_music_val_label.text = "%d%%" % int(round(val))
		music_volume_changed.emit(val / 100.0)
	)

	# Sound Effects Volume Slider
	var sfx_row := _create_slider_row("Sound FX", 90.0, 0.0, 100.0)
	_sfx_slider = sfx_row["slider"]
	_sfx_val_label = sfx_row["val_label"]
	vbox.add_child(sfx_row["row"])
	_sfx_slider.value_changed.connect(func(val: float):
		_sfx_val_label.text = "%d%%" % int(round(val))
		sfx_volume_changed.emit(val / 100.0)
	)

	# Camera Sensitivity Slider
	var sens_row := _create_slider_row("Camera Speed", 100.0, 50.0, 150.0)
	_sens_slider = sens_row["slider"]
	_sens_val_label = sens_row["val_label"]
	vbox.add_child(sens_row["row"])
	_sens_slider.value_changed.connect(func(val: float):
		_sens_val_label.text = "%d%%" % int(round(val))
		camera_sensitivity_changed.emit(val / 100.0)
	)

	# Mute Toggle
	_mute_check = CheckButton.new()
	_mute_check.name = "MuteSoundToggle"
	_mute_check.text = "Mute All Audio"
	_mute_check.toggled.connect(func(pressed: bool): sound_mute_toggled.emit(pressed))
	vbox.add_child(_mute_check)

	# Action Buttons: Resume & Main Menu
	var btn_hbox := HBoxContainer.new()
	btn_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_hbox.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_hbox)

	_menu_resume_btn = Button.new()
	_menu_resume_btn.name = "ResumeButton"
	_menu_resume_btn.text = "DONE / RESUME"
	_menu_resume_btn.custom_minimum_size = Vector2(185.0, 52.0)
	UIStyleHelper.apply_chunky_button_style(_menu_resume_btn, UIStyleHelper.COLOR_PLAY_GREEN, UIStyleHelper.COLOR_PLAY_BORDER, 18, 18, 6)
	_menu_resume_btn.pressed.connect(func(): set_menu_open(false))
	btn_hbox.add_child(_menu_resume_btn)

	_menu_lobby_btn = Button.new()
	_menu_lobby_btn.name = "ReturnToLobbyButton"
	_menu_lobby_btn.text = "MAIN MENU"
	_menu_lobby_btn.custom_minimum_size = Vector2(185.0, 52.0)
	UIStyleHelper.apply_chunky_button_style(_menu_lobby_btn, UIStyleHelper.COLOR_CORAL_RED, UIStyleHelper.COLOR_CORAL_BORDER, 18, 18, 6)
	_menu_lobby_btn.pressed.connect(func():
		set_menu_open(false)
		return_to_lobby_requested.emit()
	)
	btn_hbox.add_child(_menu_lobby_btn)


func _create_slider_row(label_text: String, initial_val: float, min_v: float, max_v: float) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(115.0, 0.0)
	lbl.add_theme_font_size_override("font_size", 16)
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = 1.0
	slider.value = initial_val
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(190.0, 28.0)
	row.add_child(slider)

	var val_lbl := Label.new()
	val_lbl.text = "%d%%" % int(round(initial_val))
	val_lbl.custom_minimum_size = Vector2(52.0, 0.0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val_lbl)

	return {"row": row, "slider": slider, "val_label": val_lbl}


func _build_result_modal() -> void:
	_result_overlay = Control.new()
	_result_overlay.name = "ResultOverlay"
	_result_overlay.visible = false
	_result_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_root_control.add_child(_result_overlay)
	_result_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dimmer := ColorRect.new()
	dimmer.color = Color(0.02, 0.05, 0.12, 0.65)
	_result_overlay.add_child(dimmer)
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_confetti_canvas = Control.new()
	_confetti_canvas.name = "ConfettiCanvas"
	_confetti_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_overlay.add_child(_confetti_canvas)
	_confetti_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_confetti_canvas.draw.connect(_draw_confetti_particles)

	var modal := PanelContainer.new()
	modal.add_theme_stylebox_override(
		"panel",
		UIStyleHelper.create_card_style(Color(0.09, 0.15, 0.30, 0.96), UIStyleHelper.COLOR_GOLD, 28, 8, 28, 22)
	)
	modal.mouse_filter = Control.MOUSE_FILTER_PASS
	_result_overlay.add_child(modal)
	modal.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	modal.offset_left = -285.0
	modal.offset_right = 285.0
	modal.offset_top = -155.0
	modal.offset_bottom = 155.0

	var modal_vbox := VBoxContainer.new()
	modal_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	modal_vbox.add_theme_constant_override("separation", 14)
	modal_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	modal.add_child(modal_vbox)

	_result_badge_label = Label.new()
	_result_badge_label.text = "CROWN CLAIMED!"
	_result_badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_badge_label.add_theme_font_size_override("font_size", 15)
	_result_badge_label.add_theme_color_override("font_color", UIStyleHelper.COLOR_GOLD)
	modal_vbox.add_child(_result_badge_label)

	_result_title_label = Label.new()
	_result_title_label.text = "VICTORY! YOU WON!"
	_result_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_title_label.add_theme_font_size_override("font_size", 36)
	_result_title_label.add_theme_color_override("font_outline_color", Color(0.04, 0.08, 0.18))
	_result_title_label.add_theme_constant_override("outline_size", 9)
	modal_vbox.add_child(_result_title_label)

	_result_subtitle_label = Label.new()
	_result_subtitle_label.text = "Match Complete"
	_result_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_subtitle_label.add_theme_font_size_override("font_size", 17)
	_result_subtitle_label.add_theme_color_override("font_color", Color(0.88, 0.94, 1.0))
	modal_vbox.add_child(_result_subtitle_label)

	var btn_center := HBoxContainer.new()
	btn_center.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_center.add_theme_constant_override("separation", 18)
	modal_vbox.add_child(btn_center)

	_replay_button = Button.new()
	_replay_button.name = "ReplayButton"
	_replay_button.text = "PLAY AGAIN"
	_replay_button.custom_minimum_size = Vector2(215.0, 58.0)
	UIStyleHelper.apply_chunky_button_style(_replay_button, UIStyleHelper.COLOR_PLAY_GREEN, UIStyleHelper.COLOR_PLAY_BORDER, 20, 20, 7)
	_replay_button.pressed.connect(func(): replay_requested.emit())
	btn_center.add_child(_replay_button)

	_result_lobby_button = Button.new()
	_result_lobby_button.name = "ResultReturnToLobbyButton"
	_result_lobby_button.text = "MAIN MENU"
	_result_lobby_button.custom_minimum_size = Vector2(205.0, 58.0)
	UIStyleHelper.apply_chunky_button_style(_result_lobby_button, UIStyleHelper.COLOR_SKY_BLUE, UIStyleHelper.COLOR_SKY_BORDER, 20, 20, 7)
	_result_lobby_button.pressed.connect(func(): return_to_lobby_requested.emit())
	btn_center.add_child(_result_lobby_button)


func _spawn_confetti_particles() -> void:
	_confetti_items.clear()
	var vp := get_viewport().get_visible_rect().size
	if vp.x < 10.0:
		vp = Vector2(1280.0, 720.0)
	var colors: Array[Color] = [
		Color(1.0, 0.84, 0.15),
		Color(0.0, 0.90, 1.0),
		Color(0.15, 0.95, 0.48),
		Color(1.0, 0.30, 0.45),
		Color(0.82, 0.35, 1.0)
	]
	for i in range(48):
		_confetti_items.append({
			"pos": Vector2(randf_range(40.0, vp.x - 40.0), randf_range(-220.0, vp.y * 0.45)),
			"vel": Vector2(randf_range(-45.0, 45.0), randf_range(95.0, 210.0)),
			"size": Vector2(randf_range(8.0, 14.0), randf_range(6.0, 11.0)),
			"color": colors[i % colors.size()]
		})


func _update_confetti_particles(delta: float) -> void:
	var vp_h := get_viewport().get_visible_rect().size.y
	if vp_h < 10.0:
		vp_h = 720.0
	for item in _confetti_items:
		item["pos"] += item["vel"] * delta
		if item["pos"].y > vp_h + 20.0:
			item["pos"].y = -20.0


func _draw_confetti_particles() -> void:
	if not _confetti_canvas:
		return
	for item in _confetti_items:
		var p: Vector2 = item["pos"]
		var sz: Vector2 = item["size"]
		var col: Color = item["color"]
		_confetti_canvas.draw_rect(Rect2(p, sz), col, true)
