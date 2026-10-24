class_name AimLine
extends Node3D
## Manages the straight forward-facing attack line extending from a character's torso.
## Handles obstacle-blocking raycasts, 3D beam visuals, and segment-vs-circle hit math.

const OBSTACLE_COLLISION_MASK: int = 1 << 1 # Layer 2: Obstacles

@export var max_range: float = 14.0
@export var torso_height: float = 0.90
@export var base_beam_width: float = 0.075
@export var fire_beam_width: float = 0.24

var _outer_beam: MeshInstance3D
var _outer_box: BoxMesh
var _outer_mat: StandardMaterial3D

var _inner_beam: MeshInstance3D
var _inner_box: BoxMesh
var _inner_mat: StandardMaterial3D

var _end_cap: MeshInstance3D
var _end_mat: StandardMaterial3D

var _line_color: Color = Color(0.0, 0.9, 1.0)
var _current_origin: Vector3 = Vector3.ZERO
var _current_end: Vector3 = Vector3.ZERO
var _current_length: float = 14.0
var _is_blocked_by_obstacle: bool = false
var _is_firing: bool = false


func _ready() -> void:
	top_level = true
	_build_beam_visuals()


func set_line_color(color: Color) -> void:
	_line_color = color
	if _outer_mat:
		_outer_mat.albedo_color = Color(color.r, color.g, color.b, 0.72)
		_outer_mat.emission = color
	if _end_mat:
		_end_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.95)
		_end_mat.emission = color


func update_line(
	character_global_pos: Vector3,
	aim_direction: Vector3,
	world_3d: World3D,
	countdown_urgency: float = 0.0
) -> void:
	var dir_xz := Vector3(aim_direction.x, 0.0, aim_direction.z)
	if dir_xz.length_squared() < 0.0001:
		dir_xz = Vector3.BACK
	else:
		dir_xz = dir_xz.normalized()

	var muzzle_offset := 0.28
	_current_origin = Vector3(
		character_global_pos.x + dir_xz.x * muzzle_offset,
		character_global_pos.y + torso_height,
		character_global_pos.z + dir_xz.z * muzzle_offset
	)

	var trace := compute_unobstructed_segment(
		Vector3(character_global_pos.x, _current_origin.y, character_global_pos.z),
		dir_xz,
		max_range,
		world_3d
	)
	_current_end = trace["end"]
	_current_length = _current_origin.distance_to(_current_end)
	_is_blocked_by_obstacle = trace["blocked"]

	_update_visual_transforms(dir_xz, countdown_urgency)


func set_firing_visual(firing: bool) -> void:
	_is_firing = firing
	if not _outer_box or not _inner_box:
		return
	if firing:
		_outer_box.size.x = fire_beam_width
		_outer_box.size.y = fire_beam_width * 0.75
		_inner_box.size.x = fire_beam_width * 0.48
		_inner_box.size.y = fire_beam_width * 0.48
		_outer_mat.albedo_color = Color(_line_color.r, _line_color.g, _line_color.b, 0.96)
		_outer_mat.emission_energy_multiplier = 4.2
		_inner_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	else:
		_outer_box.size.x = base_beam_width
		_outer_box.size.y = base_beam_width * 0.55
		_inner_box.size.x = base_beam_width * 0.38
		_inner_box.size.y = base_beam_width * 0.38
		_outer_mat.albedo_color = Color(_line_color.r, _line_color.g, _line_color.b, 0.72)
		_outer_mat.emission_energy_multiplier = 2.0
		_inner_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.85)


func get_current_origin() -> Vector3:
	return _current_origin


func get_current_end() -> Vector3:
	return _current_end


static func compute_unobstructed_segment(
	origin: Vector3,
	direction: Vector3,
	range_length: float,
	world_3d: World3D,
	obstacle_aabbs: Array[AABB] = []
) -> Dictionary:
	var dir_xz := Vector3(direction.x, 0.0, direction.z).normalized()
	if dir_xz.length_squared() < 0.0001:
		dir_xz = Vector3(0.0, 0.0, 1.0)

	var desired_end := origin + dir_xz * range_length
	var best_end := desired_end
	var best_dist := range_length
	var blocked := false

	# 1. Physics raycast against Layer 2 (Obstacles)
	if world_3d != null and world_3d.direct_space_state != null:
		var query := PhysicsRayQueryParameters3D.create(origin, desired_end, OBSTACLE_COLLISION_MASK)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := world_3d.direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			var hit_pos: Vector3 = hit["position"]
			var d := Vector2(origin.x, origin.z).distance_to(Vector2(hit_pos.x, hit_pos.z))
			if d < best_dist:
				best_dist = d
				best_end = origin + dir_xz * d
				blocked = true

	# 2. Analytical AABB check (ensures exact blocking even before physics server flushes)
	for aabb in obstacle_aabbs:
		var hit_t := _ray_intersects_aabb_xz(origin, dir_xz, range_length, aabb)
		if hit_t >= 0.0 and hit_t < best_dist:
			best_dist = hit_t
			best_end = origin + dir_xz * hit_t
			blocked = true

	return {
		"origin": origin,
		"end": best_end,
		"distance": best_dist,
		"blocked": blocked,
		"direction": dir_xz
	}


static func does_segment_hit_target(
	seg_origin: Vector3,
	seg_end: Vector3,
	target_pos: Vector3,
	target_hit_radius: float
) -> bool:
	var a := Vector2(seg_origin.x, seg_origin.z)
	var b := Vector2(seg_end.x, seg_end.z)
	var c := Vector2(target_pos.x, target_pos.z)

	var ab := b - a
	var ab_len_sq := ab.length_squared()
	if ab_len_sq < 0.00001:
		return false

	# Project target center onto segment AB
	var t := clampf((c - a).dot(ab) / ab_len_sq, 0.0, 1.0)
	var closest := a + ab * t
	var dist_sq := c.distance_squared_to(closest)
	return dist_sq <= (target_hit_radius * target_hit_radius)


static func _ray_intersects_aabb_xz(origin: Vector3, dir_xz: Vector3, max_dist: float, aabb: AABB) -> float:
	# Check if ray height is within obstacle vertical span
	if origin.y < aabb.position.y - 0.1 or origin.y > aabb.position.y + aabb.size.y + 0.1:
		return -1.0

	var min_x := aabb.position.x
	var max_x := aabb.position.x + aabb.size.x
	var min_z := aabb.position.z
	var max_z := aabb.position.z + aabb.size.z

	var tmin := 0.0
	var tmax := max_dist

	if absf(dir_xz.x) < 0.000001:
		if origin.x < min_x or origin.x > max_x:
			return -1.0
	else:
		var inv_x := 1.0 / dir_xz.x
		var t1 := (min_x - origin.x) * inv_x
		var t2 := (max_x - origin.x) * inv_x
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return -1.0

	if absf(dir_xz.z) < 0.000001:
		if origin.z < min_z or origin.z > max_z:
			return -1.0
	else:
		var inv_z := 1.0 / dir_xz.z
		var t1 := (min_z - origin.z) * inv_z
		var t2 := (max_z - origin.z) * inv_z
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return -1.0

	if tmin >= 0.0 and tmin <= max_dist:
		return tmin
	return -1.0


func _build_beam_visuals() -> void:
	_outer_mat = StandardMaterial3D.new()
	_outer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_outer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outer_mat.albedo_color = Color(_line_color.r, _line_color.g, _line_color.b, 0.72)

	_outer_box = BoxMesh.new()
	_outer_box.size = Vector3(base_beam_width, base_beam_width * 0.55, 1.0)

	_outer_beam = MeshInstance3D.new()
	_outer_beam.mesh = _outer_box
	_outer_beam.material_override = _outer_mat
	_outer_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_outer_beam)

	_inner_mat = StandardMaterial3D.new()
	_inner_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_inner_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_inner_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.85)

	_inner_box = BoxMesh.new()
	_inner_box.size = Vector3(base_beam_width * 0.38, base_beam_width * 0.38, 1.0)

	_inner_beam = MeshInstance3D.new()
	_inner_beam.mesh = _inner_box
	_inner_beam.material_override = _inner_mat
	_inner_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_inner_beam)

	_end_mat = StandardMaterial3D.new()
	_end_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_end_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_end_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.95)

	var sphere := SphereMesh.new()
	sphere.radius = 0.13
	sphere.height = 0.26
	sphere.radial_segments = 10
	sphere.rings = 6

	_end_cap = MeshInstance3D.new()
	_end_cap.mesh = sphere
	_end_cap.material_override = _end_mat
	_end_cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_end_cap)


func _update_visual_transforms(dir_xz: Vector3, countdown_urgency: float) -> void:
	var length := maxf(0.1, _current_length)
	var mid_pos := (_current_origin + _current_end) * 0.5
	var yaw := atan2(dir_xz.x, dir_xz.z)

	global_position = mid_pos
	global_rotation = Vector3(0.0, yaw, 0.0)

	_outer_box.size.z = length
	_inner_box.size.z = length

	if not _is_firing:
		var pulse := 1.0 + 0.35 * sin(Time.get_ticks_msec() * 0.018) * countdown_urgency
		var w := base_beam_width * lerpf(1.0, 1.45, countdown_urgency) * pulse
		_outer_box.size.x = w
		_inner_box.size.x = w * 0.42
		_outer_mat.albedo_color = Color(
			_line_color.r,
			_line_color.g,
			_line_color.b,
			lerpf(0.68, 0.92, countdown_urgency)
		)

	_end_cap.global_position = _current_end
	var cap_scale := 1.35 if _is_firing else (1.15 if _is_blocked_by_obstacle else 0.85)
	_end_cap.scale = Vector3.ONE * cap_scale
