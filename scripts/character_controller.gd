class_name CharacterController
extends CharacterBody3D
## Core character controller for both the human player and the 4 AI opponents.
## Manages movement physics, aiming line, character states (ALIVE, ELIMINATED, SPECTATING, WINNER),
## invincibility during preparation phase, and fall detection.

enum State {
	ALIVE,
	ELIMINATED,
	SPECTATING,
	WINNER
}

signal state_changed(character: CharacterController, new_state: State)
signal character_eliminated(character: CharacterController, reason: String)

const LAYER_PLATFORM: int = 1 << 0
const LAYER_OBSTACLES: int = 1 << 1
const LAYER_CHARACTERS: int = 1 << 2

@export var player_id: int = 0
@export var display_name: String = "YOU"
@export var is_human: bool = false
@export var move_speed: float = 6.2
@export var acceleration: float = 28.0
@export var gravity: float = 28.0
@export var hit_radius: float = 0.55
@export var max_attack_range: float = 14.0
@export var fall_elimination_y: float = -2.2

var current_state: State = State.ALIVE
var is_invincible: bool = true
var controls_frozen: bool = false
var is_stealth_hidden: bool = false

var move_input: Vector2 = Vector2.ZERO
var aim_direction: Vector3 = Vector3(0.0, 0.0, 1.0)
var primary_color: Color = Color(0.0, 0.88, 1.0)
var accent_color: Color = Color(0.45, 0.96, 1.0)

var visuals: CharacterVisuals
var aim_line: AimLine
var _collision_shape: CollisionShape3D
var _name_label: Label3D
var _countdown_urgency: float = 0.0
var _active_obstacle_aabbs: Array[AABB] = []


func _ready() -> void:
	collision_layer = LAYER_CHARACTERS
	collision_mask = LAYER_PLATFORM | LAYER_OBSTACLES
	axis_lock_angular_x = true
	axis_lock_angular_y = true
	axis_lock_angular_z = true

	_setup_components()
	_apply_palette()


func configure_character(
	id: int,
	char_name: String,
	human: bool,
	primary: Color,
	accent: Color,
	attack_range: float = 14.0
) -> void:
	player_id = id
	display_name = char_name
	is_human = human
	primary_color = primary
	accent_color = accent
	max_attack_range = attack_range
	_apply_palette()


func spawn_at(spawn_pos: Vector3, initial_aim: Vector3) -> void:
	global_position = spawn_pos
	velocity = Vector3.ZERO
	move_input = Vector2.ZERO
	if initial_aim.length_squared() > 0.001:
		aim_direction = Vector3(initial_aim.x, 0.0, initial_aim.z).normalized()
	else:
		aim_direction = Vector3(0.0, 0.0, 1.0)

	controls_frozen = false
	is_invincible = true
	is_stealth_hidden = false
	if _collision_shape:
		_collision_shape.disabled = false
	if visuals:
		visuals.visible = true
		visuals.reset_visuals()
		visuals.rotation.y = atan2(aim_direction.x, aim_direction.z)
		visuals.set_invincible_visual(true, 0.0)
	if aim_line:
		aim_line.max_range = max_attack_range
		aim_line.visible = true
		aim_line.set_firing_visual(false)
		aim_line.update_line(global_position, aim_direction, get_world_3d(), 0.0)
	if _name_label:
		_name_label.visible = true

	set_character_state(State.ALIVE)


func set_stealth_hidden(hidden: bool) -> void:
	is_stealth_hidden = hidden
	if current_state != State.ALIVE:
		return
	if visuals:
		visuals.visible = not hidden
	if aim_line:
		aim_line.visible = not hidden
		if not hidden:
			aim_line.update_line(global_position, aim_direction, get_world_3d(), _countdown_urgency)
	if _name_label:
		_name_label.visible = not hidden


func set_character_state(new_state: State) -> void:
	if current_state == new_state:
		return
	current_state = new_state
	state_changed.emit(self, current_state)


func set_move_vector(input_vec: Vector2) -> void:
	if current_state != State.ALIVE or controls_frozen:
		move_input = Vector2.ZERO
		return
	if input_vec.length() > 1.0:
		move_input = input_vec.normalized()
	else:
		move_input = input_vec


func set_aim_vector(aim_vec_2d: Vector2) -> void:
	if current_state != State.ALIVE or controls_frozen:
		return
	if aim_vec_2d.length_squared() > 0.002:
		aim_direction = Vector3(aim_vec_2d.x, 0.0, aim_vec_2d.y).normalized()


func set_aim_direction_3d(dir_3d: Vector3) -> void:
	if current_state != State.ALIVE or controls_frozen:
		return
	var flat := Vector3(dir_3d.x, 0.0, dir_3d.z)
	if flat.length_squared() > 0.0001:
		aim_direction = flat.normalized()


func set_preparation_status(invincible: bool, urgency: float) -> void:
	is_invincible = invincible
	_countdown_urgency = clampf(urgency, 0.0, 1.0)
	if visuals and current_state == State.ALIVE:
		visuals.set_invincible_visual(invincible, _countdown_urgency)


func set_controls_frozen(frozen: bool) -> void:
	controls_frozen = frozen
	if frozen:
		move_input = Vector2.ZERO
		velocity.x = 0.0
		velocity.z = 0.0


func set_firing_burst(firing: bool) -> void:
	if aim_line and current_state == State.ALIVE:
		aim_line.set_firing_visual(firing)


func set_obstacle_aabbs(aabbs: Array[AABB]) -> void:
	_active_obstacle_aabbs = aabbs


func eliminate(reason: String = "LASER") -> void:
	if current_state != State.ALIVE:
		return

	is_stealth_hidden = false
	move_input = Vector2.ZERO
	velocity = Vector3.ZERO
	controls_frozen = true

	if _collision_shape:
		_collision_shape.set_deferred("disabled", true)
	if aim_line:
		aim_line.visible = false
	if _name_label:
		_name_label.visible = false
	if visuals:
		visuals.visible = true
		visuals.play_elimination_effect()

	set_character_state(State.ELIMINATED)
	character_eliminated.emit(self, reason)


func enter_spectating_state() -> void:
	if current_state == State.ELIMINATED:
		set_character_state(State.SPECTATING)


func enter_winner_state() -> void:
	if current_state != State.ALIVE:
		return
	is_stealth_hidden = false
	move_input = Vector2.ZERO
	velocity = Vector3.ZERO
	controls_frozen = true
	if aim_line:
		aim_line.visible = false
	if _name_label:
		_name_label.visible = true
	if visuals:
		visuals.visible = true
		visuals.set_invincible_visual(false, 0.0)
	set_character_state(State.WINNER)


func is_alive() -> bool:
	return current_state == State.ALIVE


func get_state_name() -> String:
	match current_state:
		State.ALIVE:
			return "ALIVE"
		State.ELIMINATED:
			return "ELIMINATED"
		State.SPECTATING:
			return "SPECTATING"
		State.WINNER:
			return "WINNER"
	return "UNKNOWN"


func get_attack_segment_snapshot(obstacle_aabbs: Array[AABB] = []) -> Dictionary:
	var origin := Vector3(global_position.x, global_position.y + 0.90, global_position.z)
	var aabbs := obstacle_aabbs if not obstacle_aabbs.is_empty() else _active_obstacle_aabbs
	return AimLine.compute_unobstructed_segment(
		origin,
		aim_direction,
		max_attack_range,
		get_world_3d(),
		aabbs
	)


func _physics_process(delta: float) -> void:
	if current_state == State.ELIMINATED or current_state == State.SPECTATING:
		if visuals:
			visuals.update_animation(delta, Vector3.ZERO, aim_direction, false)
		return

	if current_state == State.WINNER:
		if visuals:
			visuals.update_animation(delta, Vector3.ZERO, aim_direction, true)
		return

	# Active ALIVE physics
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = -0.1

	if controls_frozen or global_position.y < -0.35:
		# Cannot steer once frozen or already falling off the platform ledge
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)
	else:
		var desired_vel := Vector3(move_input.x, 0.0, move_input.y) * move_speed
		velocity.x = move_toward(velocity.x, desired_vel.x, acceleration * delta)
		velocity.z = move_toward(velocity.z, desired_vel.z, acceleration * delta)

	move_and_slide()

	# Check fall below platform elimination
	if global_position.y < fall_elimination_y:
		eliminate("FALL")
		return

	# Update visuals and aiming line
	if visuals:
		visuals.update_animation(delta, velocity, aim_direction, false)
	if aim_line:
		aim_line.update_line(global_position, aim_direction, get_world_3d(), _countdown_urgency)


func _setup_components() -> void:
	_collision_shape = CollisionShape3D.new()
	_collision_shape.name = "CollisionShape3D"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.44
	capsule.height = 1.45
	_collision_shape.shape = capsule
	_collision_shape.position = Vector3(0.0, 0.73, 0.0)
	add_child(_collision_shape)

	visuals = CharacterVisuals.new()
	visuals.name = "CharacterVisuals"
	add_child(visuals)

	aim_line = AimLine.new()
	aim_line.name = "AimLine"
	aim_line.max_range = max_attack_range
	add_child(aim_line)

	_name_label = Label3D.new()
	_name_label.name = "NameLabel"
	_name_label.position = Vector3(0.0, 1.98, 0.0)
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.no_depth_test = true
	_name_label.font_size = 42
	_name_label.outline_size = 12
	_name_label.outline_modulate = Color(0.05, 0.07, 0.1, 0.95)
	add_child(_name_label)


func _apply_palette() -> void:
	if visuals:
		visuals.configure_palette(primary_color, accent_color)
	if aim_line:
		aim_line.max_range = max_attack_range
		aim_line.set_line_color(primary_color)
	if _name_label:
		_name_label.text = display_name
		_name_label.modulate = accent_color if is_human else Color(0.95, 0.97, 1.0, 0.92)
