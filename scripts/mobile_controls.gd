class_name MobileControls
extends Control
## Touchscreen dual-pad mobile controller:
## - Bottom-Left Virtual Joystick for character movement
## - Bottom-Right Touch Aiming Pad for rotating the character's attack line
## Supports true multi-touch on Android and emulated touch on desktop.

signal move_input_changed(move_vec: Vector2)
signal aim_input_changed(aim_vec: Vector2)

@export var pad_radius: float = 92.0
@export var knob_radius: float = 36.0
@export var deadzone: float = 0.12
@export var desktop_test_keyboard_assist: bool = true

var current_move_vector: Vector2 = Vector2.ZERO
var current_aim_vector: Vector2 = Vector2(0.0, -1.0)
var controls_enabled: bool = true

var _left_pad_rect: Control
var _right_pad_rect: Control

var _move_touch_index: int = -1
var _aim_touch_index: int = -1

var _left_knob_offset: Vector2 = Vector2.ZERO
var _right_knob_offset: Vector2 = Vector2.ZERO
## Optional simulated safe-area insets (left, top, right, bottom) for desktop/automated testing of phone notches.
var simulated_safe_insets: Vector4 = Vector4.ZERO


func _ready() -> void:
	if OS.has_feature("android") or OS.has_feature("mobile"):
		desktop_test_keyboard_assist = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	queue_redraw()


func get_safe_insets() -> Dictionary:
	var vp := get_viewport_rect().size
	if vp.x < 10.0 or vp.y < 10.0:
		vp = Vector2(1280.0, 720.0)

	var left_in := maxf(0.0, simulated_safe_insets.x)
	var top_in := maxf(0.0, simulated_safe_insets.y)
	var right_in := maxf(0.0, simulated_safe_insets.z)
	var bottom_in := maxf(0.0, simulated_safe_insets.w)

	if OS.has_feature("android") or OS.has_feature("mobile"):
		var win_size := Vector2(DisplayServer.window_get_size())
		var safe_rect := Rect2(DisplayServer.get_display_safe_area())
		if win_size.x > 10.0 and win_size.y > 10.0 and safe_rect.size.x > 10.0 and safe_rect.size.y > 10.0:
			var scale_x := vp.x / win_size.x
			var scale_y := vp.y / win_size.y
			left_in = maxf(left_in, safe_rect.position.x * scale_x)
			top_in = maxf(top_in, safe_rect.position.y * scale_y)
			right_in = maxf(right_in, maxf(0.0, win_size.x - (safe_rect.position.x + safe_rect.size.x)) * scale_x)
			bottom_in = maxf(bottom_in, maxf(0.0, win_size.y - (safe_rect.position.y + safe_rect.size.y)) * scale_y)

	return {
		"left": left_in,
		"top": top_in,
		"right": right_in,
		"bottom": bottom_in
	}


func set_controls_active(active: bool) -> void:
	controls_enabled = active
	visible = active
	if not active:
		reset_inputs()


func reset_inputs() -> void:
	_move_touch_index = -1
	_aim_touch_index = -1
	_left_knob_offset = Vector2.ZERO
	_right_knob_offset = Vector2.ZERO
	current_move_vector = Vector2.ZERO
	move_input_changed.emit(Vector2.ZERO)
	queue_redraw()


func set_initial_aim(aim_3d: Vector3) -> void:
	var v := Vector2(aim_3d.x, aim_3d.z)
	if v.length_squared() > 0.001:
		current_aim_vector = v.normalized()
		queue_redraw()


func _input(event: InputEvent) -> void:
	if not controls_enabled or not visible:
		return

	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_handle_touch_pressed(touch.index, touch.position)
		else:
			_handle_touch_released(touch.index)
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_handle_touch_drag(drag.index, drag.position)


func _process(_delta: float) -> void:
	if not controls_enabled or not visible:
		return

	# Optional desktop testing mode convenience when no touch finger is on the left joystick
	if desktop_test_keyboard_assist and _move_touch_index == -1:
		var kb := Vector2.ZERO
		if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
			kb.x -= 1.0
		if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
			kb.x += 1.0
		if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
			kb.y -= 1.0
		if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
			kb.y += 1.0

		if kb.length_squared() > 0.001:
			kb = kb.normalized()
			_left_knob_offset = kb * pad_radius * 0.85
			if current_move_vector != kb:
				current_move_vector = kb
				move_input_changed.emit(current_move_vector)
			queue_redraw()
		elif current_move_vector != Vector2.ZERO:
			_left_knob_offset = Vector2.ZERO
			current_move_vector = Vector2.ZERO
			move_input_changed.emit(Vector2.ZERO)
			queue_redraw()


func _handle_touch_pressed(index: int, screen_pos: Vector2) -> void:
	var left_center := _get_left_center()
	var right_center := _get_right_center()
	var capture_radius := pad_radius * 1.55

	if _move_touch_index == -1 and screen_pos.distance_to(left_center) <= capture_radius:
		_move_touch_index = index
		_update_left_joystick(screen_pos)
		return

	if _aim_touch_index == -1 and screen_pos.distance_to(right_center) <= capture_radius:
		_aim_touch_index = index
		_update_right_aim_pad(screen_pos)
		return

	# Also allow touching anywhere in the bottom-left or bottom-right screen zones
	var vp_size := get_viewport_rect().size
	if screen_pos.y > vp_size.y * 0.38:
		if _move_touch_index == -1 and screen_pos.x < vp_size.x * 0.42:
			_move_touch_index = index
			_update_left_joystick(screen_pos)
		elif _aim_touch_index == -1 and screen_pos.x > vp_size.x * 0.58:
			_aim_touch_index = index
			_update_right_aim_pad(screen_pos)


func _handle_touch_drag(index: int, screen_pos: Vector2) -> void:
	if index == _move_touch_index:
		_update_left_joystick(screen_pos)
	elif index == _aim_touch_index:
		_update_right_aim_pad(screen_pos)


func _handle_touch_released(index: int) -> void:
	if index == _move_touch_index:
		_move_touch_index = -1
		_left_knob_offset = Vector2.ZERO
		current_move_vector = Vector2.ZERO
		move_input_changed.emit(Vector2.ZERO)
		queue_redraw()
	elif index == _aim_touch_index:
		_aim_touch_index = -1
		_right_knob_offset = Vector2.ZERO
		queue_redraw()


func _update_left_joystick(screen_pos: Vector2) -> void:
	var center := _get_left_center()
	var delta_vec := screen_pos - center
	var dist := delta_vec.length()
	var clamped_dist := minf(dist, pad_radius)

	if dist > 0.001:
		_left_knob_offset = (delta_vec / dist) * clamped_dist
	else:
		_left_knob_offset = Vector2.ZERO

	var normalized_mag := clamped_dist / pad_radius
	if normalized_mag < deadzone:
		current_move_vector = Vector2.ZERO
	else:
		var remapped := (normalized_mag - deadzone) / (1.0 - deadzone)
		current_move_vector = (delta_vec / dist) * remapped

	move_input_changed.emit(current_move_vector)
	queue_redraw()


func _update_right_aim_pad(screen_pos: Vector2) -> void:
	var center := _get_right_center()
	var delta_vec := screen_pos - center
	var dist := delta_vec.length()
	var clamped_dist := minf(dist, pad_radius)

	if dist > 0.001:
		_right_knob_offset = (delta_vec / dist) * clamped_dist
	else:
		_right_knob_offset = Vector2.ZERO

	# Update aim direction whenever dragged outside small inner deadzone
	if dist >= pad_radius * 0.10:
		current_aim_vector = (delta_vec / dist).normalized()
		aim_input_changed.emit(current_aim_vector)

	queue_redraw()


func _get_left_center() -> Vector2:
	var vp := get_viewport_rect().size
	if vp.x < 10.0 or vp.y < 10.0:
		vp = Vector2(1280.0, 720.0)
	var insets := get_safe_insets()
	var x_offset := maxf(154.0, 128.0 + float(insets["left"]))
	var y_offset := maxf(146.0, 126.0 + float(insets["bottom"]))
	return Vector2(x_offset, vp.y - y_offset)


func _get_right_center() -> Vector2:
	var vp := get_viewport_rect().size
	if vp.x < 10.0 or vp.y < 10.0:
		vp = Vector2(1280.0, 720.0)
	var insets := get_safe_insets()
	var x_offset := maxf(154.0, 128.0 + float(insets["right"]))
	var y_offset := maxf(146.0, 126.0 + float(insets["bottom"]))
	return Vector2(vp.x - x_offset, vp.y - y_offset)


func _draw() -> void:
	if not controls_enabled:
		return

	var left_c := _get_left_center()
	var right_c := _get_right_center()
	var font := ThemeDB.fallback_font

	# --- Draw Left Virtual Joystick (Movement) ---
	var left_active := (_move_touch_index != -1 or current_move_vector.length_squared() > 0.01)
	var left_bg_col := Color(0.06, 0.10, 0.16, 0.58 if left_active else 0.42)
	var left_ring_col := Color(0.0, 0.88, 1.0, 0.88 if left_active else 0.52)

	draw_circle(left_c, pad_radius, left_bg_col)
	draw_arc(left_c, pad_radius, 0.0, TAU, 48, left_ring_col, 3.5, true)
	draw_arc(left_c, pad_radius * deadzone, 0.0, TAU, 24, Color(1, 1, 1, 0.15), 1.5, true)

	# Directional ticks on left pad
	for i in range(4):
		var a := float(i) * PI * 0.5
		var d := Vector2(cos(a), sin(a))
		draw_line(left_c + d * (pad_radius - 12.0), left_c + d * (pad_radius - 3.0), left_ring_col, 2.5)

	var left_knob_pos := left_c + _left_knob_offset
	if left_active:
		draw_line(left_c, left_knob_pos, Color(0.0, 0.88, 1.0, 0.45), 4.0)
	draw_circle(left_knob_pos, knob_radius, Color(0.0, 0.78, 0.96, 0.85 if left_active else 0.65))
	draw_arc(left_knob_pos, knob_radius, 0.0, TAU, 32, Color(0.7, 0.98, 1.0, 0.95), 2.5, true)

	if font:
		draw_string(
			font,
			left_c + Vector2(-26.0, -pad_radius - 12.0),
			"MOVE",
			HORIZONTAL_ALIGNMENT_CENTER,
			-1,
			15,
			Color(0.75, 0.92, 1.0, 0.85)
		)

	# --- Draw Right Touch Aiming Control ---
	var right_active := (_aim_touch_index != -1)
	var right_bg_col := Color(0.08, 0.08, 0.16, 0.58 if right_active else 0.42)
	var right_ring_col := Color(1.0, 0.45, 0.2, 0.92 if right_active else 0.58)

	draw_circle(right_c, pad_radius, right_bg_col)
	draw_arc(right_c, pad_radius, 0.0, TAU, 48, right_ring_col, 3.5, true)
	draw_arc(right_c, pad_radius * 0.42, 0.0, TAU, 28, Color(1.0, 0.55, 0.25, 0.22), 1.5, true)

	# Current Aim Direction Indicator Arrow on the perimeter of the Right Aim Pad
	var aim_dir := current_aim_vector.normalized()
	var arrow_tip := right_c + aim_dir * (pad_radius + 10.0)
	var perp := Vector2(-aim_dir.y, aim_dir.x)
	var arrow_pts := PackedVector2Array([
		arrow_tip,
		right_c + aim_dir * (pad_radius - 8.0) + perp * 9.0,
		right_c + aim_dir * (pad_radius - 8.0) - perp * 9.0
	])
	draw_colored_polygon(arrow_pts, Color(1.0, 0.65, 0.2, 0.95))
	draw_line(right_c, right_c + aim_dir * (pad_radius - 6.0), Color(1.0, 0.5, 0.2, 0.45), 3.0)

	var right_knob_pos := right_c + (_right_knob_offset if right_active else aim_dir * (pad_radius * 0.45))
	draw_circle(right_knob_pos, knob_radius, Color(1.0, 0.38, 0.18, 0.88 if right_active else 0.68))
	draw_arc(right_knob_pos, knob_radius, 0.0, TAU, 32, Color(1.0, 0.88, 0.65, 0.95), 2.5, true)

	if font:
		draw_string(
			font,
			right_c + Vector2(-18.0, -pad_radius - 12.0),
			"AIM",
			HORIZONTAL_ALIGNMENT_CENTER,
			-1,
			15,
			Color(1.0, 0.82, 0.68, 0.85)
		)
