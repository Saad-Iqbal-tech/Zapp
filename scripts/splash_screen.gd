class_name SplashScreen
extends CanvasLayer
## High-energy, visually captivating animated Splash Screen for Zapp:
## - Deep cyber-synth backdrop with animated procedural energy particles and shockwave pulses
## - Punchy entrance animation with elastic logo bounce and dynamic flash impact
## - Stylized high-voltage neon emblem with glowing electric lightning bolt
## - Giant glowing "ZAPP" typography with vibrant cyan/magenta neon contrast
## - Dynamic animated laser underline beam with diamond nodes
## - Futuristic charging progress bar with live system status updates
## - Smooth cinematic zoom-through exit transition revealing the 3D main menu
## - Instant tap-to-skip responsiveness for fast startup

signal splash_finished()

const TOTAL_DURATION: float = 2.50
const FAST_FINISH_DURATION: float = 0.28
const NORMAL_FINISH_DURATION: float = 0.45

var _root: Control
var _bg_canvas: Control
var _logo_container: Control
var _flash_rect: ColorRect

var _emblem_rect: Control
var _title_label: Label
var _laser_underline: Control
var _subtitle_pill: PanelContainer
var _subtitle_label: Label
var _mode_label: Label

var _bottom_card: Control
var _status_label: Label
var _progress_bg: PanelContainer
var _progress_fill: Panel
var _prompt_label: Label

var _particles: Array[Dictionary] = []
var _shockwaves: Array[Dictionary] = []

var _elapsed: float = 0.0
var _progress: float = 0.0
var _is_finishing: bool = false
var _underline_width: float = 0.0
var _target_underline_width: float = 380.0
var _audio_manager: AudioManager = null


func _init() -> void:
	layer = 100


func _ready() -> void:
	_init_particles()
	_build_ui()
	set_process(true)


func start_splash(audio_manager: AudioManager = null) -> void:
	_audio_manager = audio_manager
	if _audio_manager:
		_audio_manager.play_splash_powerup()

	# Headless or dedicated server runs complete instantly
	if DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server"):
		call_deferred("_instant_complete")
		return

	_play_entrance_animation()


func _instant_complete() -> void:
	splash_finished.emit()
	queue_free()


func finish_splash(accelerated: bool = false) -> void:
	if _is_finishing:
		return
	_is_finishing = true

	var duration := FAST_FINISH_DURATION if accelerated else NORMAL_FINISH_DURATION

	if DisplayServer.get_name() == "headless":
		splash_finished.emit()
		queue_free()
		return

	# Cinematic zoom & smooth fade-out into the 3D Main Menu
	var vp_size := _root.get_viewport_rect().size if _root else Vector2(1280.0, 720.0)
	_root.pivot_offset = vp_size * 0.5

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_root, "modulate:a", 0.0, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_root, "scale", Vector2(1.08, 1.08), duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.set_parallel(false)
	tween.tween_callback(func():
		splash_finished.emit()
		queue_free()
	)


func _unhandled_input(event: InputEvent) -> void:
	if _is_finishing:
		return
	if event is InputEventScreenTouch and event.is_pressed():
		finish_splash(true)
	elif event is InputEventMouseButton and event.is_pressed():
		finish_splash(true)
	elif event is InputEventKey and event.is_pressed():
		if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER or event.keycode == KEY_ESCAPE:
			finish_splash(true)


func _init_particles() -> void:
	_particles.clear()
	var colors: Array[Color] = [
		Color(0.0, 0.96, 1.0, 0.90),   # Neon Cyan
		Color(1.0, 0.12, 0.55, 0.85),   # Electric Pink
		Color(1.0, 0.84, 0.12, 0.85),   # Golden Sparks
		Color(0.85, 0.95, 1.0, 0.95)    # Arc White
	]

	for i in range(50):
		_particles.append({
			"pos": Vector2(randf_range(0.0, 1280.0), randf_range(0.0, 720.0)),
			"vel": Vector2(randf_range(-18.0, 18.0), randf_range(-40.0, -95.0)),
			"radius": randf_range(1.6, 4.2),
			"color": colors[i % colors.size()],
			"alpha_phase": randf_range(0.0, TAU),
			"twinkle_speed": randf_range(2.0, 5.5)
		})

	for i in range(3):
		_shockwaves.append({
			"radius": float(i) * 140.0,
			"max_radius": 420.0,
			"speed": 160.0
		})


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "SplashRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.is_pressed():
			finish_splash(true)
	)
	add_child(_root)

	# 1. Custom Canvas for dynamic animated background, particles & energy shockwaves
	_bg_canvas = Control.new()
	_bg_canvas.name = "BackgroundCanvas"
	_bg_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_canvas.draw.connect(_on_bg_canvas_draw)
	_root.add_child(_bg_canvas)

	# 2. Central Logo & Brand Stack
	_logo_container = Control.new()
	_logo_container.name = "LogoContainer"
	_logo_container.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_logo_container.offset_left = -260.0
	_logo_container.offset_top = -220.0
	_logo_container.offset_right = 260.0
	_logo_container.offset_bottom = 120.0
	_logo_container.pivot_offset = Vector2(260.0, 170.0)
	_root.add_child(_logo_container)

	# 2A. High-Voltage Neon Emblem Badge
	_emblem_rect = Control.new()
	_emblem_rect.name = "Emblem"
	_emblem_rect.custom_minimum_size = Vector2(100.0, 100.0)
	_emblem_rect.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_emblem_rect.offset_left = -50.0
	_emblem_rect.offset_right = 50.0
	_emblem_rect.offset_top = 0.0
	_emblem_rect.offset_bottom = 100.0
	_emblem_rect.draw.connect(_on_emblem_draw)
	_logo_container.add_child(_emblem_rect)

	# 2B. Giant Stylized "ZAPP" Typography
	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = "ZAPP"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_title_label.offset_left = -260.0
	_title_label.offset_right = 260.0
	_title_label.offset_top = 95.0
	_title_label.offset_bottom = 205.0
	_title_label.add_theme_font_size_override("font_size", 92)
	_title_label.add_theme_color_override("font_color", Color(0.0, 0.98, 1.0))
	_title_label.add_theme_color_override("font_outline_color", Color(0.04, 0.02, 0.12))
	_title_label.add_theme_constant_override("outline_size", 12)
	_title_label.add_theme_color_override("font_shadow_color", Color(1.0, 0.08, 0.52, 0.95))
	_title_label.add_theme_constant_override("shadow_offset_x", 0)
	_title_label.add_theme_constant_override("shadow_offset_y", 7)
	_title_label.add_theme_constant_override("shadow_outline_size", 4)
	_logo_container.add_child(_title_label)

	# 2C. Dynamic Laser Underline Beam
	_laser_underline = Control.new()
	_laser_underline.name = "LaserUnderline"
	_laser_underline.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_laser_underline.offset_left = -200.0
	_laser_underline.offset_right = 200.0
	_laser_underline.offset_top = 205.0
	_laser_underline.offset_bottom = 225.0
	_laser_underline.draw.connect(_on_laser_draw)
	_logo_container.add_child(_laser_underline)

	# 2D. Tagline Pill Container
	_subtitle_pill = PanelContainer.new()
	_subtitle_pill.name = "SubtitlePill"
	_subtitle_pill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_subtitle_pill.offset_left = -175.0
	_subtitle_pill.offset_right = 175.0
	_subtitle_pill.offset_top = 230.0
	_subtitle_pill.offset_bottom = 268.0

	var pill_sb := StyleBoxFlat.new()
	pill_sb.bg_color = Color(0.04, 0.07, 0.16, 0.92)
	pill_sb.border_color = Color(1.0, 0.80, 0.15)
	pill_sb.border_width_left = 2
	pill_sb.border_width_top = 2
	pill_sb.border_width_right = 2
	pill_sb.border_width_bottom = 3
	pill_sb.set_corner_radius_all(14)
	pill_sb.content_margin_left = 16
	pill_sb.content_margin_right = 16
	pill_sb.content_margin_top = 6
	pill_sb.content_margin_bottom = 6
	_subtitle_pill.add_theme_stylebox_override("panel", pill_sb)
	_logo_container.add_child(_subtitle_pill)

	_subtitle_label = Label.new()
	_subtitle_label.text = "⚡ LINE-OF-SIGHT SURVIVAL ARENA ⚡"
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.add_theme_font_size_override("font_size", 14)
	_subtitle_label.add_theme_color_override("font_color", Color(1.0, 0.90, 0.35))
	_subtitle_pill.add_child(_subtitle_label)

	# 2E. Mode Sub-badge
	_mode_label = Label.new()
	_mode_label.name = "ModeLabel"
	_mode_label.text = "★ 5-PLAYER BATTLE ROYALE • ONLINE & OFFLINE ★"
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_mode_label.offset_left = -220.0
	_mode_label.offset_right = 220.0
	_mode_label.offset_top = 278.0
	_mode_label.offset_bottom = 302.0
	_mode_label.add_theme_font_size_override("font_size", 12)
	_mode_label.add_theme_color_override("font_color", Color(0.45, 0.88, 1.0, 0.88))
	_logo_container.add_child(_mode_label)

	# 3. Bottom Card: Futuristic Charging Bar & Dynamic Status Messages
	_bottom_card = Control.new()
	_bottom_card.name = "BottomCard"
	_bottom_card.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_bottom_card.offset_left = -210.0
	_bottom_card.offset_right = 210.0
	_bottom_card.offset_top = -140.0
	_bottom_card.offset_bottom = -20.0
	_root.add_child(_bottom_card)

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = "⚡ INITIALIZING ARENA SYSTEMS..."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_status_label.offset_left = -200.0
	_status_label.offset_right = 200.0
	_status_label.offset_top = 0.0
	_status_label.offset_bottom = 24.0
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", Color(0.55, 0.95, 1.0))
	_bottom_card.add_child(_status_label)

	# Progress Bar Container
	_progress_bg = PanelContainer.new()
	_progress_bg.name = "ProgressBarBG"
	_progress_bg.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_progress_bg.offset_left = -175.0
	_progress_bg.offset_right = 175.0
	_progress_bg.offset_top = 32.0
	_progress_bg.offset_bottom = 46.0

	var p_bg_style := StyleBoxFlat.new()
	p_bg_style.bg_color = Color(0.04, 0.08, 0.18, 0.92)
	p_bg_style.border_color = Color(0.12, 0.32, 0.58, 0.85)
	p_bg_style.border_width_left = 1
	p_bg_style.border_width_top = 1
	p_bg_style.border_width_right = 1
	p_bg_style.border_width_bottom = 2
	p_bg_style.set_corner_radius_all(7)
	_progress_bg.add_theme_stylebox_override("panel", p_bg_style)
	_bottom_card.add_child(_progress_bg)

	_progress_fill = Panel.new()
	_progress_fill.name = "ProgressFill"
	_progress_fill.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_progress_fill.size = Vector2(0.0, 14.0)

	var p_fill_style := StyleBoxFlat.new()
	p_fill_style.bg_color = Color(0.0, 0.95, 0.75)
	p_fill_style.border_color = Color(0.5, 1.0, 0.85)
	p_fill_style.border_width_top = 1
	p_fill_style.border_width_bottom = 1
	p_fill_style.set_corner_radius_all(6)
	_progress_fill.add_theme_stylebox_override("panel", p_fill_style)
	_progress_bg.add_child(_progress_fill)

	# Skip / Continue prompt
	_prompt_label = Label.new()
	_prompt_label.name = "PromptLabel"
	_prompt_label.text = "TAP ANYWHERE TO CONTINUE"
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_prompt_label.offset_left = -160.0
	_prompt_label.offset_right = 160.0
	_prompt_label.offset_top = 58.0
	_prompt_label.offset_bottom = 80.0
	_prompt_label.add_theme_font_size_override("font_size", 11)
	_prompt_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.65))
	_bottom_card.add_child(_prompt_label)

	# 4. Impact Flash Overlay
	_flash_rect = ColorRect.new()
	_flash_rect.name = "FlashRect"
	_flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash_rect.color = Color(1.0, 1.0, 1.0, 0.0)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_flash_rect)


func _play_entrance_animation() -> void:
	# Initial states
	_logo_container.scale = Vector2(0.25, 0.25)
	_logo_container.modulate.a = 0.0
	_bottom_card.modulate.a = 0.0
	_underline_width = 0.0

	var tween := create_tween()

	# Flash impact
	_flash_rect.color = Color(1.0, 1.0, 1.0, 0.65)
	tween.parallel().tween_property(_flash_rect, "color:a", 0.0, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	# Spring pop on Logo
	tween.parallel().tween_property(_logo_container, "scale", Vector2(1.0, 1.0), 0.62).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(_logo_container, "modulate:a", 1.0, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	# Animate laser underline expanding outward
	tween.parallel().tween_method(func(w: float):
		_underline_width = w
		if _laser_underline:
			_laser_underline.queue_redraw()
	, 0.0, _target_underline_width, 0.55).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	# Fade in bottom card
	tween.parallel().tween_property(_bottom_card, "modulate:a", 1.0, 0.45).set_delay(0.20)


func _process(delta: float) -> void:
	_elapsed += delta
	var vp_size := _root.get_viewport_rect().size if _root else Vector2(1280.0, 720.0)

	# Update particles
	for p in _particles:
		p["pos"] += p["vel"] * delta
		p["alpha_phase"] += p["twinkle_speed"] * delta
		if p["pos"].y < -20.0:
			p["pos"].y = vp_size.y + 10.0
			p["pos"].x = randf_range(0.0, vp_size.x)
		if p["pos"].x < -20.0:
			p["pos"].x = vp_size.x + 10.0
		elif p["pos"].x > vp_size.x + 20.0:
			p["pos"].x = -10.0

	# Update shockwaves
	for sw in _shockwaves:
		sw["radius"] += sw["speed"] * delta
		if sw["radius"] > sw["max_radius"]:
			sw["radius"] = 20.0

	# Update loading progress
	_progress = clampf(_elapsed / TOTAL_DURATION, 0.0, 1.0)
	if _progress_fill:
		var max_w := 350.0
		_progress_fill.size.x = max_w * _progress

	# Cycle status messages
	if _status_label and not _is_finishing:
		if _progress < 0.28:
			_status_label.text = "⚡ CHARGING LASER CAPACITORS..."
		elif _progress < 0.58:
			_status_label.text = "⚡ GENERATING DESTRUCTIBLE PLATFORMS..."
		elif _progress < 0.88:
			_status_label.text = "⚡ SYNCHRONIZING COMBAT SYSTEMS..."
		else:
			_status_label.text = "★ ALL SYSTEMS OPTIMAL • GET READY! ★"
			_status_label.add_theme_color_override("font_color", Color(0.25, 1.0, 0.65))

	# Gentle breathing hover animation on logo
	if _logo_container and not _is_finishing and _elapsed > 0.62:
		var float_offset := sin((_elapsed - 0.62) * 2.8) * 4.0
		_logo_container.position.y = (vp_size.y * 0.5 - 220.0) + float_offset

	# Pulsing skip prompt
	if _prompt_label:
		_prompt_label.modulate.a = 0.35 + 0.55 * (sin(_elapsed * 5.0) * 0.5 + 0.5)

	# Redraw dynamic background & custom controls
	if _bg_canvas:
		_bg_canvas.queue_redraw()
	if _emblem_rect:
		_emblem_rect.queue_redraw()

	# Auto-finish when duration elapsed
	if _elapsed >= TOTAL_DURATION and not _is_finishing:
		finish_splash(false)


func _on_bg_canvas_draw() -> void:
	if not _bg_canvas:
		return
	var vp_size := _bg_canvas.get_viewport_rect().size

	# 1. Multi-tone rich cyber synth gradient backdrop
	var top_color := Color(0.03, 0.03, 0.09)     # Deep Midnight
	var mid_color := Color(0.08, 0.04, 0.18)     # Electric Violet
	var bot_color := Color(0.03, 0.08, 0.16)     # Dark Cyber Navy

	_bg_canvas.draw_rect(Rect2(Vector2.ZERO, vp_size), top_color, true)

	var points := PackedVector2Array([
		Vector2(0.0, vp_size.y * 0.35),
		Vector2(vp_size.x, vp_size.y * 0.35),
		Vector2(vp_size.x, vp_size.y),
		Vector2(0.0, vp_size.y)
	])
	var colors := PackedColorArray([
		mid_color,
		mid_color,
		bot_color,
		bot_color
	])
	_bg_canvas.draw_polygon(points, colors)

	# 2. Concentric expanding electric shockwave rings
	var center := vp_size * 0.5
	for sw in _shockwaves:
		var r: float = sw["radius"]
		var max_r: float = sw["max_radius"]
		var alpha := clampf(1.0 - (r / max_r), 0.0, 1.0) * 0.35
		var sw_color := Color(0.0, 0.95, 1.0, alpha)
		_bg_canvas.draw_arc(center, r, 0.0, TAU, 48, sw_color, 2.0, true)

	# 3. Horizon grid lines for retro arcade depth
	var grid_y_start := vp_size.y * 0.68
	for i in range(5):
		var y := grid_y_start + float(i * i) * 6.5
		if y > vp_size.y:
			break
		var alpha := 0.06 + float(i) * 0.03
		_bg_canvas.draw_line(Vector2(0.0, y), Vector2(vp_size.x, y), Color(0.0, 0.9, 1.0, alpha), 1.5)

	# 4. Animated floating neon sparks
	for p in _particles:
		var pos: Vector2 = p["pos"]
		var base_color: Color = p["color"]
		var twinkle: float = (sin(p["alpha_phase"]) * 0.5 + 0.5)
		var col := Color(base_color.r, base_color.g, base_color.b, base_color.a * (0.4 + 0.6 * twinkle))
		_bg_canvas.draw_circle(pos, p["radius"], col)
		# Soft halo around larger particles
		if p["radius"] > 2.8:
			var halo_col := Color(col.r, col.g, col.b, col.a * 0.25)
			_bg_canvas.draw_circle(pos, p["radius"] * 2.2, halo_col)


func _on_emblem_draw() -> void:
	if not _emblem_rect:
		return
	var rect := _emblem_rect.get_rect()
	var center := rect.size * 0.5
	var r := 46.0

	# Glowing neon diamond / circle badge
	var pulse := sin(_elapsed * 4.0) * 0.15 + 0.85
	var border_cyan := Color(0.0, 0.96, 1.0, 0.90 * pulse)
	var fill_dark := Color(0.05, 0.09, 0.20, 0.95)

	_emblem_rect.draw_circle(center, r + 4.0, Color(0.0, 0.96, 1.0, 0.22 * pulse))
	_emblem_rect.draw_circle(center, r, fill_dark)
	_emblem_rect.draw_arc(center, r, 0.0, TAU, 36, border_cyan, 3.5, true)
	_emblem_rect.draw_arc(center, r - 5.0, 0.0, TAU, 36, Color(1.0, 0.10, 0.55, 0.55), 1.5, true)

	# High-voltage lightning bolt vector
	var bolt_points := PackedVector2Array([
		center + Vector2(2.0, -28.0),
		center + Vector2(-16.0, 2.0),
		center + Vector2(0.0, 2.0),
		center + Vector2(-6.0, 28.0),
		center + Vector2(16.0, -4.0),
		center + Vector2(2.0, -4.0),
		center + Vector2(12.0, -28.0)
	])

	# Layer 1: Wide cyan outer glow
	_emblem_rect.draw_polyline(bolt_points, Color(0.0, 0.96, 1.0, 0.45), 8.0, true)
	# Layer 2: Electric Yellow core fill
	_emblem_rect.draw_colored_polygon(bolt_points, Color(1.0, 0.88, 0.10))
	# Layer 3: Hot white center streak
	var streak := PackedVector2Array([
		center + Vector2(4.0, -24.0),
		center + Vector2(-8.0, 0.0),
		center + Vector2(0.0, 0.0),
		center + Vector2(-3.0, 20.0)
	])
	_emblem_rect.draw_polyline(streak, Color(1.0, 1.0, 1.0, 0.90), 2.2, true)


func _on_laser_draw() -> void:
	if not _laser_underline:
		return
	var center := _laser_underline.size * 0.5
	var half_w := _underline_width * 0.5
	if half_w <= 1.0:
		return

	var p_left := center + Vector2(-half_w, 0.0)
	var p_right := center + Vector2(half_w, 0.0)

	# Outer beam glow (Cyan / Pink)
	_laser_underline.draw_line(p_left, p_right, Color(1.0, 0.10, 0.55, 0.45), 7.0)
	_laser_underline.draw_line(p_left, p_right, Color(0.0, 0.98, 1.0, 0.85), 3.0)
	_laser_underline.draw_line(p_left, p_right, Color(1.0, 1.0, 1.0, 0.95), 1.5)

	# Glowing diamond nodes at tips
	var d_size := 5.0
	var left_diamond := PackedVector2Array([
		p_left + Vector2(0.0, -d_size),
		p_left + Vector2(d_size, 0.0),
		p_left + Vector2(0.0, d_size),
		p_left + Vector2(-d_size, 0.0)
	])
	var right_diamond := PackedVector2Array([
		p_right + Vector2(0.0, -d_size),
		p_right + Vector2(d_size, 0.0),
		p_right + Vector2(0.0, d_size),
		p_right + Vector2(-d_size, 0.0)
	])
	_laser_underline.draw_colored_polygon(left_diamond, Color(0.0, 0.98, 1.0))
	_laser_underline.draw_colored_polygon(right_diamond, Color(0.0, 0.98, 1.0))
