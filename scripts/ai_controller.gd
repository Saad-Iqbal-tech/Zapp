class_name AIController
extends Node
## Lightweight, configurable AI behavior controller for the 4 local AI opponents.
## Uses the exact same CharacterController movement and aiming interface as the human player.

@export var aim_turn_speed: float = 6.8
@export var target_reselect_interval: float = 0.45
@export var edge_safety_margin: float = 1.25
@export var preferred_min_range: float = 3.8
@export var preferred_max_range: float = 8.8
@export var dodge_weight: float = 2.1

var controlled_character: CharacterController
var arena: ArenaGenerator
var all_characters: Array[CharacterController] = []

var _current_target: CharacterController = null
var _reselect_timer: float = 0.0
var _strafe_sign: float = 1.0
var _strafe_timer: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_strafe_sign = 1.0 if _rng.randf() > 0.5 else -1.0
	_strafe_timer = _rng.randf_range(0.8, 2.0)


func setup_ai(
	character: CharacterController,
	arena_ref: ArenaGenerator,
	roster: Array[CharacterController],
	seed_offset: int = 0
) -> void:
	controlled_character = character
	arena = arena_ref
	all_characters = roster
	_rng.seed = Time.get_ticks_usec() + seed_offset * 9973
	_strafe_sign = 1.0 if (seed_offset % 2 == 0) else -1.0


func _physics_process(delta: float) -> void:
	if not controlled_character or not is_instance_valid(controlled_character):
		return

	# Stop acting immediately when eliminated, spectating, winner, or frozen
	if not controlled_character.is_alive() or controlled_character.controls_frozen:
		controlled_character.set_move_vector(Vector2.ZERO)
		return

	_reselect_timer -= delta
	if _reselect_timer <= 0.0 or not _is_valid_target(_current_target):
		_reselect_timer = target_reselect_interval + _rng.randf_range(-0.08, 0.12)
		_current_target = _select_best_target()

	_strafe_timer -= delta
	if _strafe_timer <= 0.0:
		_strafe_timer = _rng.randf_range(0.9, 2.1)
		if _rng.randf() < 0.45:
			_strafe_sign = -_strafe_sign

	_update_aiming(delta)
	_update_movement(delta)


func _is_valid_target(candidate: CharacterController) -> bool:
	return candidate != null and is_instance_valid(candidate) and candidate != controlled_character and candidate.is_alive()


func _select_best_target() -> CharacterController:
	var my_pos := controlled_character.global_position
	var obs_aabbs := arena.get_active_obstacle_aabbs() if arena else []
	var best_target: CharacterController = null
	var best_score: float = -99999.0

	for other in all_characters:
		if not _is_valid_target(other):
			continue
		var to_other := other.global_position - my_pos
		var dist := Vector2(to_other.x, to_other.z).length()
		if dist < 0.01:
			continue

		var score := -dist * 1.2
		if dist <= controlled_character.max_attack_range:
			score += 12.0

		# Check if line of sight is unobstructed by obstacles
		var dir_to := Vector3(to_other.x, 0.0, to_other.z).normalized()
		var seg := AimLine.compute_unobstructed_segment(
			Vector3(my_pos.x, my_pos.y + 0.9, my_pos.z),
			dir_to,
			minf(dist, controlled_character.max_attack_range),
			controlled_character.get_world_3d(),
			obs_aabbs
		)
		if not seg["blocked"]:
			score += 15.0

		if other == _current_target:
			score += 3.5

		if score > best_score:
			best_score = score
			best_target = other

	return best_target


func _update_aiming(delta: float) -> void:
	if not _is_valid_target(_current_target):
		return

	var my_pos := controlled_character.global_position
	var target_pos := _current_target.global_position + _current_target.velocity * 0.14
	var to_target := Vector3(target_pos.x - my_pos.x, 0.0, target_pos.z - my_pos.z)
	if to_target.length_squared() < 0.001:
		return

	var desired_dir := to_target.normalized()
	var current_dir := controlled_character.aim_direction
	var current_yaw := atan2(current_dir.x, current_dir.z)
	var desired_yaw := atan2(desired_dir.x, desired_dir.z)
	var new_yaw := lerp_angle(current_yaw, desired_yaw, minf(1.0, aim_turn_speed * delta))

	controlled_character.set_aim_direction_3d(Vector3(sin(new_yaw), 0.0, cos(new_yaw)))


func _update_movement(_delta: float) -> void:
	var my_pos := controlled_character.global_position
	var my_xz := Vector2(my_pos.x, my_pos.z)

	var safe_half_w := arena.get_next_safe_half_width() if arena else 10.0
	var inner_safe_limit := maxf(1.05, safe_half_w - edge_safety_margin)

	# 1. Urgent evacuation if outside or near the shrinking/outer danger boundary
	if absf(my_xz.x) > inner_safe_limit or absf(my_xz.y) > inner_safe_limit:
		var to_center := (-my_xz).normalized()
		var tang := Vector2(-to_center.y, to_center.x) * _strafe_sign * 0.28
		controlled_character.set_move_vector((to_center + tang).normalized())
		return

	var steer := Vector2.ZERO
	var obs_aabbs := arena.get_active_obstacle_aabbs() if arena else []

	# 2. Evade incoming opponent aiming lines
	for other in all_characters:
		if not _is_valid_target(other):
			continue
		var other_origin := Vector2(other.global_position.x, other.global_position.z)
		var other_dir := Vector2(other.aim_direction.x, other.aim_direction.z).normalized()
		var other_seg := other.get_attack_segment_snapshot(obs_aabbs)
		var seg_end_3d: Vector3 = other_seg["end"]
		var other_end := Vector2(seg_end_3d.x, seg_end_3d.z)

		var ab := other_end - other_origin
		var ab_len_sq := ab.length_squared()
		if ab_len_sq > 0.01:
			var t := clampf((my_xz - other_origin).dot(ab) / ab_len_sq, 0.0, 1.0)
			if t > 0.02:
				var closest := other_origin + ab * t
				var dist_to_beam := my_xz.distance_to(closest)
				var threat_radius := controlled_character.hit_radius * 2.35
				if dist_to_beam < threat_radius:
					var away := my_xz - closest
					if away.length_squared() < 0.001:
						away = Vector2(-other_dir.y, other_dir.x) * _strafe_sign
					else:
						away = away.normalized()
					var urgency := (1.0 - (dist_to_beam / threat_radius)) * dodge_weight
					steer += away * urgency

	# 3. Tactical spacing & line-of-sight positioning relative to current target
	if _is_valid_target(_current_target):
		var target_xz := Vector2(_current_target.global_position.x, _current_target.global_position.z)
		var to_target := target_xz - my_xz
		var dist := to_target.length()
		var dir_2d := to_target / maxf(0.001, dist)
		var perp_2d := Vector2(-dir_2d.y, dir_2d.x) * _strafe_sign

		# Check if our shot to target is blocked by an obstacle
		var my_seg := controlled_character.get_attack_segment_snapshot(obs_aabbs)
		var shot_blocked: bool = my_seg["blocked"] and (my_seg["distance"] < dist - 0.3)

		var eff_min := minf(preferred_min_range, inner_safe_limit * 0.65)
		var eff_max := minf(preferred_max_range, inner_safe_limit * 1.45)

		if dist < eff_min:
			steer -= dir_2d * 0.95
		elif dist > eff_max or dist > controlled_character.max_attack_range * 0.88:
			steer += dir_2d * 1.05

		if shot_blocked:
			# Strafe faster around cover to acquire line of sight
			steer += perp_2d * 1.15
		else:
			steer += perp_2d * 0.55

	# 4. Obstacle repulsion so AI doesn't get stuck pushing into walls
	for aabb in obs_aabbs:
		var obs_center := Vector2(aabb.position.x + aabb.size.x * 0.5, aabb.position.z + aabb.size.z * 0.5)
		var obs_radius := maxf(aabb.size.x, aabb.size.z) * 0.5 + 0.72
		var diff := my_xz - obs_center
		var d := diff.length()
		if d < obs_radius and d > 0.001:
			steer += (diff / d) * ((obs_radius - d) / obs_radius) * 1.65

	# 5. Soft boundary containment so desired step stays well inside safe zone
	var predicted_xz := my_xz + steer.normalized() * 0.9
	if absf(predicted_xz.x) > inner_safe_limit:
		steer.x = -signf(my_xz.x) * 1.2
	if absf(predicted_xz.y) > inner_safe_limit:
		steer.y = -signf(my_xz.y) * 1.2

	if steer.length_squared() > 0.01:
		controlled_character.set_move_vector(steer.normalized())
	else:
		controlled_character.set_move_vector(Vector2.ZERO)
