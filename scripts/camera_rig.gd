class_name CameraRig
extends Node3D
## High-angle (~75 degrees) fixed-orientation camera rig for gameplay,
## plus a live 3D Hero Showcase & Arena Background camera mode for the Main Menu.

@export var look_down_angle_deg: float = 75.0
@export var camera_height: float = 22.5
@export var spectator_camera_height: float = 15.0
@export var fov_degrees: float = 52.0
@export var follow_smoothing: float = 7.5

var camera: Camera3D
var target_node: Node3D = null
var is_spectating_mode: bool = false
var is_lobby_mode: bool = false
var camera_sensitivity: float = 1.0

var _current_focus: Vector3 = Vector3.ZERO
var _current_height: float = 22.5
var _current_pitch: float = -75.0
var _lobby_time: float = 0.0
var _shake_intensity: float = 0.0
var _shake_time: float = 0.0
var _spectator_marker: MeshInstance3D
var _marker_mat: StandardMaterial3D
var _marker_time: float = 0.0


func _ready() -> void:
	_current_height = camera_height
	_current_pitch = -look_down_angle_deg
	camera = Camera3D.new()
	camera.name = "ArenaCamera3D"
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = fov_degrees
	camera.current = true
	add_child(camera)

	_build_spectator_marker()
	_apply_camera_transform(Vector3.ZERO)


func get_effective_horizontal_fov_deg(viewport_size: Vector2 = Vector2.ZERO) -> float:
	var vp := viewport_size
	if vp.x <= 1.0 or vp.y <= 1.0:
		vp = get_viewport().get_visible_rect().size if is_inside_tree() and get_viewport() else Vector2(1280.0, 720.0)
	var aspect := maxf(0.1, vp.x / maxf(1.0, vp.y))
	var v_fov_rad := deg_to_rad(camera.fov if camera else fov_degrees)
	var h_fov_rad := 2.0 * atan(tan(v_fov_rad * 0.5) * aspect)
	return rad_to_deg(h_fov_rad)


func set_lobby_mode(active: bool, hero_target: Node3D = null, snap_immediately: bool = false) -> void:
	is_lobby_mode = active
	if hero_target != null:
		target_node = hero_target
	if active:
		is_spectating_mode = false
		if _spectator_marker:
			_spectator_marker.visible = false
	if snap_immediately:
		if active:
			_apply_lobby_camera(0.0, true)
		else:
			_current_focus = _compute_desired_focus()
			_current_height = spectator_camera_height if is_spectating_mode else camera_height
			_current_pitch = -look_down_angle_deg
			_apply_camera_transform(Vector3.ZERO)


func set_follow_target(new_target: Node3D, spectating: bool = false, snap_immediately: bool = false) -> void:
	target_node = new_target
	is_spectating_mode = spectating
	if _spectator_marker:
		_spectator_marker.visible = spectating and (target_node != null) and not is_lobby_mode

	if snap_immediately and not is_lobby_mode:
		_current_focus = _compute_desired_focus()
		_current_height = spectator_camera_height if spectating else camera_height
		_current_pitch = -look_down_angle_deg
		_apply_camera_transform(Vector3.ZERO)


func set_camera_sensitivity(multiplier: float) -> void:
	camera_sensitivity = clampf(multiplier, 0.4, 2.0)


func trigger_screen_shake(intensity: float = 0.28) -> void:
	_shake_intensity = maxf(_shake_intensity, intensity)


func _process(delta: float) -> void:
	if is_lobby_mode:
		_apply_lobby_camera(delta, false)
		return

	var eff_smooth := follow_smoothing * camera_sensitivity
	var desired_focus := _compute_desired_focus()
	_current_focus = _current_focus.lerp(desired_focus, minf(1.0, delta * eff_smooth))

	var desired_h := spectator_camera_height if is_spectating_mode else camera_height
	_current_height = lerpf(_current_height, desired_h, minf(1.0, delta * 5.5))
	_current_pitch = lerpf(_current_pitch, -look_down_angle_deg, minf(1.0, delta * 7.0))

	if _spectator_marker:
		if is_spectating_mode and target_node and is_instance_valid(target_node):
			_spectator_marker.visible = true
			_marker_time += delta * 5.0
			var pulse := 1.0 + 0.14 * sin(_marker_time)
			_spectator_marker.global_position = Vector3(
				target_node.global_position.x,
				0.08,
				target_node.global_position.z
			)
			_spectator_marker.scale = Vector3(pulse, 1.0, pulse)
		else:
			_spectator_marker.visible = false

	var shake_offset := Vector3.ZERO
	if _shake_intensity > 0.005:
		_shake_time += delta * 42.0
		shake_offset = Vector3(
			sin(_shake_time * 1.3) * _shake_intensity,
			0.0,
			cos(_shake_time * 1.7) * _shake_intensity
		)
		_shake_intensity = move_toward(_shake_intensity, 0.0, delta * 1.1)

	_apply_camera_transform(shake_offset)


func _apply_lobby_camera(delta: float, snap: bool) -> void:
	if not camera:
		return
	_lobby_time += delta
	var hero_pos := Vector3(0.0, 0.05, 6.1)
	if target_node and is_instance_valid(target_node):
		hero_pos = target_node.global_position

	var sway_x := sin(_lobby_time * 0.65) * 0.48
	var sway_y := cos(_lobby_time * 0.90) * 0.07
	var desired_cam_pos := Vector3(hero_pos.x + sway_x, hero_pos.y + 1.85 + sway_y, hero_pos.z + 2.85)
	var look_target := Vector3(hero_pos.x * 0.3, hero_pos.y + 0.72, hero_pos.z - 0.8)

	if snap:
		camera.global_position = desired_cam_pos
	else:
		camera.global_position = camera.global_position.lerp(desired_cam_pos, minf(1.0, delta * 6.0))

	camera.look_at(look_target, Vector3.UP)


func _compute_desired_focus() -> Vector3:
	if not target_node or not is_instance_valid(target_node):
		return Vector3.ZERO

	var t_pos := target_node.global_position
	var flat_pos := Vector3(t_pos.x, 0.0, t_pos.z)

	if is_spectating_mode:
		var clamped_x := clampf(flat_pos.x, -10.5, 10.5)
		var clamped_z := clampf(flat_pos.z, -10.5, 10.5)
		return Vector3(clamped_x, 0.0, clamped_z)
	else:
		var clamped_x := clampf(flat_pos.x * 0.42, -4.2, 4.2)
		var clamped_z := clampf(flat_pos.z * 0.42, -4.2, 4.2)
		return Vector3(clamped_x, 0.0, clamped_z)


func _apply_camera_transform(shake_offset: Vector3) -> void:
	if not camera:
		return
	var pitch_rad := deg_to_rad(look_down_angle_deg)
	var z_offset := _current_height / tan(pitch_rad)
	var focus := _current_focus + shake_offset

	camera.global_position = Vector3(focus.x, _current_height, focus.z + z_offset)
	camera.global_rotation_degrees = Vector3(_current_pitch, 0.0, 0.0)


func _build_spectator_marker() -> void:
	_spectator_marker = MeshInstance3D.new()
	_spectator_marker.name = "SpectatorTargetRing"
	_spectator_marker.top_level = true
	var torus := TorusMesh.new()
	torus.inner_radius = 0.72
	torus.outer_radius = 0.88
	torus.rings = 24
	torus.ring_segments = 8
	_spectator_marker.mesh = torus

	_marker_mat = StandardMaterial3D.new()
	_marker_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_mat.albedo_color = Color(0.25, 0.96, 1.0, 0.92)
	_spectator_marker.material_override = _marker_mat
	_spectator_marker.visible = false
	add_child(_spectator_marker)
