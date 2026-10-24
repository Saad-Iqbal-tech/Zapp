class_name ArenaGenerator
extends Node3D
## Generates the modular square survival arena from individual floor tiles and solid obstacles.
## Manages staged shrinking (100% -> 72% -> 45% -> 22%), danger boundary highlights,
## falling outer tile animations, and safe collision updates.

signal shrink_warning_started(target_stage: int, next_safe_width_ratio: float, duration: float)
signal stage_shrunk(new_stage: int, safe_width_ratio: float, safe_half_width: float)

const LowPolyBuilder = preload("res://assets/low_poly_mesh_builder.gd")

const LAYER_PLATFORM: int = 1 << 0
const LAYER_OBSTACLES: int = 1 << 1

## Exact stage width percentages requested:
## Stage 1: 100%, Stage 2: 72%, Stage 3: 45%, Stage 4: 22%
const STAGE_WIDTH_RATIOS: Dictionary = {
	1: 1.00,
	2: 0.72,
	3: 0.45,
	4: 0.22
}

@export var base_arena_width: float = 24.0
@export var tile_thickness: float = 0.65

var current_stage: int = 1
var is_warning_active: bool = false
var warning_target_stage: int = 2
var warning_elapsed: float = 0.0

var _tiles_root: Node3D
var _obstacles_root: Node3D
var _boundary_root: Node3D

var _mat_even: StandardMaterial3D
var _mat_odd: StandardMaterial3D
var _mat_warning: StandardMaterial3D
var _mat_obstacle: StandardMaterial3D
var _mat_obstacle_trim: StandardMaterial3D
var _mat_boundary: StandardMaterial3D

# Tile data dictionaries: { node, mesh_instance, collision_shape, stage_group, base_pos, is_Odd, falling, fall_vel, rot_axis, fall_delay }
var _tiles: Array[Dictionary] = []
# Obstacle data dictionaries: { node, collision_shape, stage_group, base_pos, aabb, active, falling, fall_vel, rot_axis }
var _obstacles: Array[Dictionary] = []
var _boundary_bars: Array[MeshInstance3D] = []


func _ready() -> void:
	_load_or_create_materials()
	_tiles_root = Node3D.new()
	_tiles_root.name = "ModularTiles"
	add_child(_tiles_root)

	_obstacles_root = Node3D.new()
	_obstacles_root.name = "Obstacles"
	add_child(_obstacles_root)

	_boundary_root = Node3D.new()
	_boundary_root.name = "DangerBoundary"
	add_child(_boundary_root)
	_build_boundary_indicator()

	generate_arena()


func generate_arena() -> void:
	_clear_existing()
	current_stage = 1
	is_warning_active = false
	_boundary_root.visible = false

	var half_w: float = base_arena_width * 0.5 # 12.0
	# Coordinate breakpoints aligned with 22% (0.11*W), 45% (0.225*W), 72% (0.36*W), 100% (0.50*W)
	var b4: float = base_arena_width * (float(STAGE_WIDTH_RATIOS[4]) * 0.5) # 2.64
	var b3: float = base_arena_width * (float(STAGE_WIDTH_RATIOS[3]) * 0.5) # 5.40
	var b2: float = base_arena_width * (float(STAGE_WIDTH_RATIOS[2]) * 0.5) # 8.64
	var b1: float = half_w # 12.00

	var coords := PackedFloat32Array([
		-b1, -(b1 + b2) * 0.5, -b2, -(b2 + b3) * 0.5, -b3, -(b3 + b4) * 0.5, -b4, -b4 * 0.5,
		0.0,
		b4 * 0.5, b4, (b3 + b4) * 0.5, b3, (b2 + b3) * 0.5, b2, (b1 + b2) * 0.5, b1
	])

	var grid_count := coords.size() - 1 # 16x16 = 256 modular floor tiles
	for ix in range(grid_count):
		var x0 := coords[ix]
		var x1 := coords[ix + 1]
		var cx := (x0 + x1) * 0.5
		var sx := x1 - x0

		for iz in range(grid_count):
			var z0 := coords[iz]
			var z1 := coords[iz + 1]
			var cz := (z0 + z1) * 0.5
			var sz := z1 - z0

			var stage_grp := _determine_tile_stage_group(cx, cz, b4, b3, b2)
			var is_odd := ((ix + iz) % 2) == 1
			_create_floor_tile(Vector3(cx, -tile_thickness * 0.5, cz), Vector3(sx, tile_thickness, sz), stage_grp, is_odd)

	_create_arena_obstacles()


func get_spawn_positions() -> Array[Vector3]:
	return [
		Vector3(0.0, 0.05, 6.8),     # Player 0 (Human - South)
		Vector3(-6.8, 0.05, 0.0),    # AI 1 (West)
		Vector3(6.8, 0.05, 0.0),     # AI 2 (East)
		Vector3(-4.4, 0.05, -6.8),   # AI 3 (North-West)
		Vector3(4.4, 0.05, -6.8)     # AI 4 (North-East)
	]


func get_current_safe_width() -> float:
	return base_arena_width * STAGE_WIDTH_RATIOS.get(current_stage, 1.0)


func get_current_safe_half_width() -> float:
	return get_current_safe_width() * 0.5


func get_stage_width_ratio(stage: int) -> float:
	return STAGE_WIDTH_RATIOS.get(stage, 1.0)


func get_next_safe_half_width() -> float:
	if is_warning_active and STAGE_WIDTH_RATIOS.has(warning_target_stage):
		return base_arena_width * STAGE_WIDTH_RATIOS[warning_target_stage] * 0.5
	return get_current_safe_half_width()


func get_active_obstacle_aabbs() -> Array[AABB]:
	var result: Array[AABB] = []
	for obs in _obstacles:
		if obs["active"] and not obs["falling"]:
			result.append(obs["aabb"])
	return result


func start_shrink_warning(target_stage: int, duration: float) -> void:
	if not STAGE_WIDTH_RATIOS.has(target_stage) or target_stage <= current_stage:
		return
	is_warning_active = true
	warning_target_stage = target_stage
	warning_elapsed = 0.0

	var next_ratio: float = STAGE_WIDTH_RATIOS[target_stage]
	var next_half_w: float = base_arena_width * next_ratio * 0.5
	_position_boundary_indicator(next_half_w)
	_boundary_root.visible = true

	var collapsing_group := target_stage - 1
	for tile in _tiles:
		if tile["stage_group"] == collapsing_group and not tile["falling"]:
			var mi: MeshInstance3D = tile["mesh_instance"]
			mi.material_override = _mat_warning

	shrink_warning_started.emit(target_stage, next_ratio, duration)


func execute_shrink_to_stage(target_stage: int) -> void:
	if not STAGE_WIDTH_RATIOS.has(target_stage) or target_stage <= current_stage:
		return

	is_warning_active = false
	_boundary_root.visible = false

	# Collapse all outer stage rings up to target_stage - 1
	for tile in _tiles:
		var grp: int = tile["stage_group"]
		if grp < target_stage and not tile["falling"]:
			tile["falling"] = true
			var col: CollisionShape3D = tile["collision_shape"]
			if col:
				col.set_deferred("disabled", true)
			var pos: Vector3 = tile["base_pos"]
			var radial := Vector3(pos.x, 0.0, pos.z).normalized()
			tile["fall_vel"] = radial * 1.4 + Vector3(0.0, -1.2, 0.0)
			tile["rot_axis"] = Vector3(-radial.z, 0.0, radial.x).normalized()

	for obs in _obstacles:
		var grp: int = obs["stage_group"]
		if grp < target_stage and obs["active"] and not obs["falling"]:
			obs["active"] = false
			obs["falling"] = true
			var col: CollisionShape3D = obs["collision_shape"]
			if col:
				col.set_deferred("disabled", true)
			var pos: Vector3 = obs["base_pos"]
			var radial := Vector3(pos.x, 0.0, pos.z).normalized()
			obs["fall_vel"] = radial * 1.1 + Vector3(0.0, -1.5, 0.0)
			obs["rot_axis"] = Vector3(-radial.z, 0.0, radial.x).normalized()

	current_stage = target_stage
	var ratio: float = STAGE_WIDTH_RATIOS[current_stage]
	stage_shrunk.emit(current_stage, ratio, base_arena_width * ratio * 0.5)


func stop_all_shrinking() -> void:
	is_warning_active = false
	if _boundary_root:
		_boundary_root.visible = false
	# Restore normal tile material for any non-falling tiles
	for tile in _tiles:
		if not tile["falling"]:
			var mi: MeshInstance3D = tile["mesh_instance"]
			mi.material_override = _mat_odd if tile["is_odd"] else _mat_even


func _process(delta: float) -> void:
	if is_warning_active:
		warning_elapsed += delta
		var pulse := 0.5 + 0.5 * sin(warning_elapsed * 14.0)
		if _mat_warning:
			_mat_warning.emission_energy_multiplier = lerpf(0.7, 2.4, pulse)
		if _mat_boundary:
			_mat_boundary.albedo_color = Color(1.0, lerpf(0.15, 0.55, pulse), 0.1, lerpf(0.65, 0.98, pulse))

		var collapsing_group := warning_target_stage - 1
		for tile in _tiles:
			if tile["stage_group"] == collapsing_group and not tile["falling"]:
				var node: Node3D = tile["node"]
				var base_pos: Vector3 = tile["base_pos"]
				var shake := sin(warning_elapsed * 32.0 + base_pos.x * 1.7 + base_pos.z * 2.3) * 0.035
				node.position = base_pos + Vector3(0.0, shake, 0.0)

	# Animate falling tiles & obstacles
	for tile in _tiles:
		if tile["falling"]:
			var node: Node3D = tile["node"]
			if not node.visible:
				continue
			if tile["fall_delay"] > 0.0:
				tile["fall_delay"] -= delta
				continue
			tile["fall_vel"].y -= 22.0 * delta
			node.position += tile["fall_vel"] * delta
			node.rotate(tile["rot_axis"], delta * 1.9)
			if node.position.y < -32.0:
				node.visible = false

	for obs in _obstacles:
		if obs["falling"]:
			var node: Node3D = obs["node"]
			if not node.visible:
				continue
			obs["fall_vel"].y -= 22.0 * delta
			node.position += obs["fall_vel"] * delta
			node.rotate(obs["rot_axis"], delta * 1.5)
			if node.position.y < -32.0:
				node.visible = false


func _determine_tile_stage_group(cx: float, cz: float, b4: float, b3: float, b2: float) -> int:
	var chebyshev := maxf(absf(cx), absf(cz))
	if chebyshev < b4 - 0.01:
		return 4
	elif chebyshev < b3 - 0.01:
		return 3
	elif chebyshev < b2 - 0.01:
		return 2
	return 1


func _create_floor_tile(pos: Vector3, size: Vector3, stage_grp: int, is_odd: bool) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_PLATFORM
	body.collision_mask = 0
	body.position = pos
	_tiles_root.add_child(body)

	var col := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	col.shape = box_shape
	body.add_child(col)

	# Slightly inset visual mesh for crisp low-poly tile grid lines
	var visual_size := Vector3(size.x - 0.04, size.y, size.z - 0.04)
	var mi := MeshInstance3D.new()
	mi.mesh = LowPolyBuilder.create_chamfered_box(visual_size, 0.04)
	mi.material_override = _mat_odd if is_odd else _mat_even
	body.add_child(mi)

	var dist_ratio := clampf((maxf(absf(pos.x), absf(pos.z)) / (base_arena_width * 0.5)), 0.0, 1.0)
	var delay := (1.0 - dist_ratio) * 0.18

	_tiles.append({
		"node": body,
		"mesh_instance": mi,
		"collision_shape": col,
		"stage_group": stage_grp,
		"base_pos": pos,
		"is_odd": is_odd,
		"falling": false,
		"fall_vel": Vector3.ZERO,
		"rot_axis": Vector3.RIGHT,
		"fall_delay": delay
	})


func _create_arena_obstacles() -> void:
	# Obstacles grouped by which stage ring supports them:
	# Stage 4 core (always stays): 2 small tactical cover pillars
	_spawn_obstacle(Vector3(-1.35, 0.0, -1.35), Vector3(0.85, 1.65, 0.85), 4)
	_spawn_obstacle(Vector3(1.35, 0.0, 1.35), Vector3(0.85, 1.65, 0.85), 4)

	# Stage 3 ring (collapses when shrinking 3 -> 4): 4 cardinal walls
	_spawn_obstacle(Vector3(-3.9, 0.0, 0.0), Vector3(1.05, 1.70, 2.05), 3)
	_spawn_obstacle(Vector3(3.9, 0.0, 0.0), Vector3(1.05, 1.70, 2.05), 3)
	_spawn_obstacle(Vector3(0.0, 0.0, -3.9), Vector3(2.05, 1.70, 1.05), 3)
	_spawn_obstacle(Vector3(0.0, 0.0, 3.9), Vector3(2.05, 1.70, 1.05), 3)

	# Stage 2 ring (collapses when shrinking 2 -> 3): 4 diagonal bunkers
	_spawn_obstacle(Vector3(-6.8, 0.0, -6.8), Vector3(1.55, 1.75, 1.55), 2)
	_spawn_obstacle(Vector3(6.8, 0.0, -6.8), Vector3(1.55, 1.75, 1.55), 2)
	_spawn_obstacle(Vector3(-6.8, 0.0, 6.8), Vector3(1.55, 1.75, 1.55), 2)
	_spawn_obstacle(Vector3(6.8, 0.0, 6.8), Vector3(1.55, 1.75, 1.55), 2)

	# Stage 1 outer ring (collapses when shrinking 1 -> 2): 4 outer perimeter shields
	_spawn_obstacle(Vector3(-10.1, 0.0, 0.0), Vector3(1.30, 1.75, 2.30), 1)
	_spawn_obstacle(Vector3(10.1, 0.0, 0.0), Vector3(1.30, 1.75, 2.30), 1)
	_spawn_obstacle(Vector3(0.0, 0.0, -10.1), Vector3(2.30, 1.75, 1.30), 1)
	_spawn_obstacle(Vector3(0.0, 0.0, 10.1), Vector3(2.30, 1.75, 1.30), 1)


func _spawn_obstacle(ground_pos: Vector3, size: Vector3, stage_grp: int) -> void:
	var center_pos := ground_pos + Vector3(0.0, size.y * 0.5, 0.0)
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_OBSTACLES
	body.collision_mask = 0
	body.position = center_pos
	_obstacles_root.add_child(body)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	var mi := MeshInstance3D.new()
	mi.mesh = LowPolyBuilder.create_chamfered_box(size, 0.11)
	mi.material_override = _mat_obstacle
	body.add_child(mi)

	# Glowing top cap accent
	var cap_mi := MeshInstance3D.new()
	var cap_size := Vector3(size.x * 0.78, 0.08, size.z * 0.78)
	cap_mi.mesh = LowPolyBuilder.create_chamfered_box(cap_size, 0.02, Vector3(0.0, size.y * 0.5 + 0.02, 0.0))
	cap_mi.material_override = _mat_obstacle_trim
	body.add_child(cap_mi)

	var aabb := AABB(center_pos - size * 0.5, size)
	_obstacles.append({
		"node": body,
		"collision_shape": col,
		"stage_group": stage_grp,
		"base_pos": center_pos,
		"aabb": aabb,
		"active": true,
		"falling": false,
		"fall_vel": Vector3.ZERO,
		"rot_axis": Vector3.RIGHT
	})


func _build_boundary_indicator() -> void:
	_boundary_bars.clear()
	for i in range(4):
		var bar := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.0, 0.14, 0.18)
		bar.mesh = box
		bar.material_override = _mat_boundary
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_boundary_root.add_child(bar)
		_boundary_bars.append(bar)
	_boundary_root.visible = false


func _position_boundary_indicator(half_w: float) -> void:
	if _boundary_bars.size() < 4:
		return
	var full_w := half_w * 2.0
	var y := 0.08
	var thickness := 0.22

	# North, South, West, East glowing danger boundary lines
	var n_box := _boundary_bars[0].mesh as BoxMesh
	n_box.size = Vector3(full_w + thickness, 0.12, thickness)
	_boundary_bars[0].position = Vector3(0.0, y, -half_w)

	var s_box := _boundary_bars[1].mesh as BoxMesh
	s_box.size = Vector3(full_w + thickness, 0.12, thickness)
	_boundary_bars[1].position = Vector3(0.0, y, half_w)

	var w_box := _boundary_bars[2].mesh as BoxMesh
	w_box.size = Vector3(thickness, 0.12, full_w + thickness)
	_boundary_bars[2].position = Vector3(-half_w, y, 0.0)

	var e_box := _boundary_bars[3].mesh as BoxMesh
	e_box.size = Vector3(thickness, 0.12, full_w + thickness)
	_boundary_bars[3].position = Vector3(half_w, y, 0.0)


func _load_or_create_materials() -> void:
	_mat_even = load("res://materials/floor_tile_even.tres") as StandardMaterial3D
	if not _mat_even:
		_mat_even = StandardMaterial3D.new()
		_mat_even.albedo_color = Color(0.14, 0.17, 0.23)

	_mat_odd = load("res://materials/floor_tile_odd.tres") as StandardMaterial3D
	if not _mat_odd:
		_mat_odd = StandardMaterial3D.new()
		_mat_odd.albedo_color = Color(0.18, 0.22, 0.29)

	var warn_base := load("res://materials/floor_tile_warning.tres") as StandardMaterial3D
	_mat_warning = warn_base.duplicate() if warn_base else StandardMaterial3D.new()

	_mat_obstacle = load("res://materials/obstacle_material.tres") as StandardMaterial3D
	if not _mat_obstacle:
		_mat_obstacle = StandardMaterial3D.new()
		_mat_obstacle.albedo_color = Color(0.26, 0.31, 0.39)

	_mat_obstacle_trim = StandardMaterial3D.new()
	_mat_obstacle_trim.albedo_color = Color(0.22, 0.58, 0.78)
	_mat_obstacle_trim.emission_enabled = true
	_mat_obstacle_trim.emission = Color(0.12, 0.48, 0.72)
	_mat_obstacle_trim.emission_energy_multiplier = 0.55

	var bound_base := load("res://materials/danger_boundary_material.tres") as StandardMaterial3D
	_mat_boundary = bound_base.duplicate() if bound_base else StandardMaterial3D.new()


func _clear_existing() -> void:
	for tile in _tiles:
		var n: Node = tile["node"]
		if is_instance_valid(n):
			n.queue_free()
	_tiles.clear()

	for obs in _obstacles:
		var n: Node = obs["node"]
		if is_instance_valid(n):
			n.queue_free()
	_obstacles.clear()
