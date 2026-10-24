class_name UIStyleHelper
extends RefCounted
## Reusable UI styling and animation helper for the playful mobile party-game theme.
## Creates chunky 3D-beveled rounded panels, colorful pill buttons, and springy hover/press animations.

const COLOR_PLAY_GREEN := Color(0.12, 0.86, 0.38)
const COLOR_PLAY_BORDER := Color(0.04, 0.52, 0.20)

const COLOR_GOLD := Color(1.0, 0.78, 0.08)
const COLOR_GOLD_BORDER := Color(0.76, 0.46, 0.02)

const COLOR_SKY_BLUE := Color(0.16, 0.62, 1.0)
const COLOR_SKY_BORDER := Color(0.06, 0.34, 0.72)

const COLOR_CORAL_RED := Color(1.0, 0.26, 0.36)
const COLOR_CORAL_BORDER := Color(0.68, 0.08, 0.18)

const COLOR_PURPLE := Color(0.68, 0.28, 1.0)
const COLOR_PURPLE_BORDER := Color(0.40, 0.10, 0.70)

const COLOR_DARK_CARD := Color(0.08, 0.13, 0.25, 0.95)
const COLOR_DARK_BORDER := Color(0.28, 0.72, 1.0, 0.95)


static func create_card_style(
	bg_color: Color = COLOR_DARK_CARD,
	border_color: Color = COLOR_DARK_BORDER,
	corner_radius: int = 22,
	bottom_bevel: int = 6,
	padding_h: int = 18,
	padding_v: int = 14
) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg_color
	s.border_color = border_color
	s.border_width_left = 3
	s.border_width_top = 3
	s.border_width_right = 3
	s.border_width_bottom = bottom_bevel
	s.set_corner_radius_all(corner_radius)
	s.content_margin_left = padding_h
	s.content_margin_right = padding_h
	s.content_margin_top = padding_v
	s.content_margin_bottom = padding_v
	s.shadow_color = Color(0.0, 0.0, 0.0, 0.38)
	s.shadow_size = 8
	s.shadow_offset = Vector2(0.0, 4.0)
	return s


static func apply_chunky_button_style(
	btn: Button,
	fill_color: Color,
	border_color: Color,
	font_size: int = 20,
	corner_radius: int = 18,
	bevel_depth: int = 7
) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = fill_color
	normal.border_color = border_color
	normal.border_width_left = 3
	normal.border_width_top = 3
	normal.border_width_right = 3
	normal.border_width_bottom = bevel_depth
	normal.set_corner_radius_all(corner_radius)
	normal.content_margin_left = 18
	normal.content_margin_right = 18
	normal.content_margin_top = 10
	normal.content_margin_bottom = 10 + int(bevel_depth * 0.4)
	normal.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
	normal.shadow_size = 6
	normal.shadow_offset = Vector2(0.0, 3.0)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = fill_color.lightened(0.14)
	hover.border_color = border_color.lightened(0.10)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = fill_color.darkened(0.10)
	pressed.border_width_bottom = maxi(2, bevel_depth - 3)
	pressed.content_margin_top = 13
	pressed.content_margin_bottom = 8
	pressed.shadow_size = 2
	pressed.shadow_offset = Vector2(0.0, 1.0)

	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("focus", hover)
	btn.add_theme_stylebox_override("pressed", pressed)

	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 0.92))
	btn.add_theme_color_override("font_pressed_color", Color(0.92, 0.96, 1.0))
	btn.add_theme_color_override("font_outline_color", border_color.darkened(0.45))
	btn.add_theme_constant_override("outline_size", 7)

	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	attach_button_juice(btn)


static func attach_button_juice(btn: BaseButton) -> void:
	btn.resized.connect(func():
		btn.pivot_offset = btn.size * 0.5
	)
	btn.pivot_offset = btn.size * 0.5

	btn.button_down.connect(func():
		btn.pivot_offset = btn.size * 0.5
		var tw := btn.create_tween()
		tw.tween_property(btn, "scale", Vector2(0.93, 0.93), 0.06).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	)
	btn.button_up.connect(func():
		btn.pivot_offset = btn.size * 0.5
		var tw := btn.create_tween()
		tw.tween_property(btn, "scale", Vector2(1.05, 1.05), 0.08).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(btn, "scale", Vector2.ONE, 0.08).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	)
	btn.mouse_entered.connect(func():
		btn.pivot_offset = btn.size * 0.5
		var tw := btn.create_tween()
		tw.tween_property(btn, "scale", Vector2(1.04, 1.04), 0.09).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	)
	btn.mouse_exited.connect(func():
		btn.pivot_offset = btn.size * 0.5
		var tw := btn.create_tween()
		tw.tween_property(btn, "scale", Vector2.ONE, 0.09).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	)
