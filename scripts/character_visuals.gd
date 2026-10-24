class_name CharacterVisuals
extends Node3D
## Builds and animates the articulated low-poly 3D humanoid character model
## with 5 distinct color variants, invincibility aura, and elimination effects.

const LowPolyBuilder = preload("res://assets/low_poly_mesh_builder.gd")

@export var primary_color: Color = Color(0.0, 0.88, 1.0)
@export var accent_color: Color = Color(0.4, 0.96, 1.0)
@export var dark_color: Color = Color(0.14, 0.17, 0.22)

var _pelvis_pivot: Node3D
var _torso_pivot: Node3D
var _head_pivot: Node3D
var _left_shoulder: Node3D
var _right_shoulder: Node3D
var _left_elbow: Node3D
var _right_elbow: Node3D
var _left_hip: Node3D
var _right_hip: Node3D
var _left_knee: Node3D
var _right_knee: Node3D
var _chest_core: MeshInstance3D
var _base_ring: MeshInstance3D
var _ground_shadow: MeshInstance3D
var _invincible_shield: MeshInstance3D
var is_lobby_showcase: bool = false

var _primary_mat: StandardMaterial3D
var _dark_mat: StandardMaterial3D
var _accent_mat: StandardMaterial3D
var _shield_mat: StandardMaterial3D

var _anim_time: float = 0.0
var _walk_blend: float = 0.0
var _is_eliminated: bool = false
var _is_winner: bool = false
var _shards_root: Node3D
var _shard_velocities: Array[Vector3] = []
var _shard_rot_axes: Array[Vector3] = []
var _shockwave_mesh: MeshInstance3D
var _shockwave_mat: StandardMaterial3D
var _elim_timer: float = 0.0


func _ready() -> void:
	_build_materials()
	_build_humanoid_hierarchy()


func configure_palette(primary: Color, accent: Color) -> void:
	primary_color = primary
	accent_color = accent
	if _primary_mat:
		_primary_mat.albedo_color = primary_color
	if _accent_mat:
		_accent_mat.albedo_color = accent_color
		_accent_mat.emission = accent_color


func set_invincible_visual(active: bool, pulse_ratio: float = 0.0) -> void:
	if not _invincible_shield or _is_eliminated:
		return
	_invincible_shield.visible = active
	if active and _shield_mat:
		var pulse := 0.5 + 0.5 * sin(pulse_ratio * TAU * 2.0)
		_shield_mat.albedo_color = Color(accent_color.r, accent_color.g, accent_color.b, lerpf(0.18, 0.36, pulse))
		_shield_mat.emission = accent_color
		_shield_mat.emission_energy_multiplier = lerpf(0.8, 1.8, pulse)


func update_animation(delta: float, horizontal_velocity: Vector3, aim_dir: Vector3, is_winner_state: bool = false) -> void:
	if _is_eliminated:
		_update_elimination_fx(delta)
		return

	_is_winner = is_winner_state
	_anim_time += delta

	# Rotate character smoothly toward aim_dir (+Z local is forward)
	if aim_dir.length_squared() > 0.001:
		var target_yaw := atan2(aim_dir.x, aim_dir.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, minf(1.0, delta * 18.0))

	var speed := Vector2(horizontal_velocity.x, horizontal_velocity.z).length()
	var target_blend := clampf(speed / 5.5, 0.0, 1.0)
	_walk_blend = move_toward(_walk_blend, target_blend, delta * 8.0)

	var cycle := _anim_time * 11.0
	var idle_cycle := _anim_time * 3.2

	if _is_winner:
		# Victory celebration bounce and raised arms
		var jump_y := absf(sin(_anim_time * 7.5)) * 0.22
		_pelvis_pivot.position.y = 0.56 + jump_y
		_torso_pivot.rotation.x = sin(_anim_time * 4.0) * 0.08
		_torso_pivot.rotation.y = sin(_anim_time * 3.5) * 0.18
		_left_shoulder.rotation.x = -2.5 + sin(_anim_time * 9.0) * 0.25
		_right_shoulder.rotation.x = -2.5 - sin(_anim_time * 9.0) * 0.25
		_left_elbow.rotation.x = -0.35
		_right_elbow.rotation.x = -0.35
		_left_hip.rotation.x = sin(_anim_time * 7.5) * 0.3
		_right_hip.rotation.x = -sin(_anim_time * 7.5) * 0.3
		return

	if _base_ring and not _is_eliminated:
		_base_ring.visible = not is_lobby_showcase

	if is_lobby_showcase:
		# Playful expressive hero showcase idle on the Main Menu
		var hero_bob := sin(_anim_time * 3.6) * 0.045
		_pelvis_pivot.position.y = 0.56 + hero_bob
		_torso_pivot.rotation.x = -0.05 + sin(_anim_time * 1.8) * 0.04
		_torso_pivot.rotation.y = sin(_anim_time * 1.5) * 0.16
		_head_pivot.rotation.y = sin(_anim_time * 1.2) * 0.18
		_head_pivot.rotation.x = sin(_anim_time * 2.4) * 0.06
		# Friendly energetic wave on right arm + hip-ready left arm
		_left_shoulder.rotation = Vector3(-0.22, 0.0, 0.26 + sin(_anim_time * 3.6) * 0.05)
		_left_elbow.rotation.x = -0.65
		_right_shoulder.rotation = Vector3(-2.15 + sin(_anim_time * 6.5) * 0.25, 0.0, -0.32 + cos(_anim_time * 6.5) * 0.18)
		_right_elbow.rotation.x = -0.45
		_left_hip.rotation.x = 0.05
		_right_hip.rotation.x = -0.05
		return

	# Pelvis bob & idle breathing
	var bob := absf(sin(cycle)) * 0.065 * _walk_blend + sin(idle_cycle) * 0.015 * (1.0 - _walk_blend)
	_pelvis_pivot.position.y = 0.56 + bob

	# Torso forward lean when moving + subtle twist
	_torso_pivot.rotation.x = lerpf(0.03, 0.16, _walk_blend)
	_torso_pivot.rotation.y = sin(cycle) * 0.12 * _walk_blend

	# Head stabilization
	_head_pivot.rotation.y = -_torso_pivot.rotation.y * 0.6
	_head_pivot.rotation.x = sin(idle_cycle * 0.8) * 0.04

	# Leg stride
	var leg_swing := sin(cycle) * 0.68 * _walk_blend
	_left_hip.rotation.x = -leg_swing
	_right_hip.rotation.x = leg_swing

	_left_knee.rotation.x = maxf(0.0, sin(cycle - 0.7)) * 0.65 * _walk_blend + 0.06
	_right_knee.rotation.x = maxf(0.0, sin(cycle + PI - 0.7)) * 0.65 * _walk_blend + 0.06

	# Arm counter-swing with combat ready bend
	var arm_swing := sin(cycle) * 0.45 * _walk_blend
	_left_shoulder.rotation.x = arm_swing - 0.28
	_right_shoulder.rotation.x = -arm_swing - 0.28
	_left_shoulder.rotation.z = 0.16
	_right_shoulder.rotation.z = -0.16
	_left_elbow.rotation.x = -0.55
	_right_elbow.rotation.x = -0.55


func play_elimination_effect() -> void:
	if _is_eliminated:
		return
	_is_eliminated = true
	_elim_timer = 0.0

	if _pelvis_pivot:
		_pelvis_pivot.visible = false
	if _invincible_shield:
		_invincible_shield.visible = false
	if _base_ring:
		_base_ring.visible = false

	_shards_root = Node3D.new()
	_shards_root.name = "EliminationShards"
	add_child(_shards_root)

	_shard_velocities.clear()
	_shard_rot_axes.clear()

	var shard_mesh := LowPolyBuilder.create_chamfered_box(Vector3(0.18, 0.14, 0.20), 0.03)
	var shard_count := 14
	for i in range(shard_count):
		var mi := MeshInstance3D.new()
		mi.mesh = shard_mesh
		mi.material_override = _primary_mat if (i % 3 != 0) else _accent_mat
		var angle := (float(i) / float(shard_count)) * TAU
		var radial := 0.25 + float(i % 3) * 0.1
		mi.position = Vector3(cos(angle) * radial, 0.45 + float(i % 4) * 0.22, sin(angle) * radial)
		_shards_root.add_child(mi)

		var out_speed := 3.2 + float(i % 4) * 1.15
		var up_speed := 3.6 + float(i % 3) * 1.35
		_shard_velocities.append(Vector3(cos(angle) * out_speed, up_speed, sin(angle) * out_speed))
		_shard_rot_axes.append(Vector3(sin(angle * 2.0), cos(angle), sin(angle)).normalized())

	# Expanding shockwave ring
	_shockwave_mesh = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.42
	torus.outer_radius = 0.56
	torus.rings = 16
	torus.ring_segments = 8
	_shockwave_mesh.mesh = torus
	_shockwave_mesh.position = Vector3(0.0, 0.15, 0.0)

	_shockwave_mat = StandardMaterial3D.new()
	_shockwave_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shockwave_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shockwave_mat.albedo_color = Color(accent_color.r, accent_color.g, accent_color.b, 0.95)
	_shockwave_mesh.material_override = _shockwave_mat
	add_child(_shockwave_mesh)


func reset_visuals() -> void:
	_is_eliminated = false
	_is_winner = false
	_anim_time = 0.0
	_walk_blend = 0.0
	if _shards_root and is_instance_valid(_shards_root):
		_shards_root.queue_free()
		_shards_root = null
	if _shockwave_mesh and is_instance_valid(_shockwave_mesh):
		_shockwave_mesh.queue_free()
		_shockwave_mesh = null
	if _pelvis_pivot:
		_pelvis_pivot.visible = true
		_pelvis_pivot.position = Vector3(0.0, 0.56, 0.0)
	if _base_ring:
		_base_ring.visible = true
	if _left_shoulder:
		_left_shoulder.rotation = Vector3(-0.28, 0.0, 0.16)
	if _right_shoulder:
		_right_shoulder.rotation = Vector3(-0.28, 0.0, -0.16)


func _update_elimination_fx(delta: float) -> void:
	_elim_timer += delta
	if _shards_root and is_instance_valid(_shards_root):
		var children := _shards_root.get_children()
		for i in range(children.size()):
			var shard := children[i] as Node3D
			if not shard:
				continue
			_shard_velocities[i].y -= 12.5 * delta
			shard.position += _shard_velocities[i] * delta
			shard.rotate(_shard_rot_axes[i], delta * 9.0)
			var scale_f := maxf(0.01, 1.0 - (_elim_timer / 1.4))
			shard.scale = Vector3.ONE * scale_f

	if _shockwave_mesh and is_instance_valid(_shockwave_mesh):
		var s := 1.0 + _elim_timer * 5.2
		_shockwave_mesh.scale = Vector3(s, 1.0, s)
		if _shockwave_mat:
			_shockwave_mat.albedo_color.a = maxf(0.0, 1.0 - _elim_timer * 1.6)


func _build_materials() -> void:
	_primary_mat = StandardMaterial3D.new()
	_primary_mat.albedo_color = primary_color
	_primary_mat.metallic = 0.25
	_primary_mat.roughness = 0.38

	_dark_mat = StandardMaterial3D.new()
	_dark_mat.albedo_color = dark_color
	_dark_mat.metallic = 0.45
	_dark_mat.roughness = 0.45

	_accent_mat = StandardMaterial3D.new()
	_accent_mat.albedo_color = accent_color
	_accent_mat.emission_enabled = true
	_accent_mat.emission = accent_color
	_accent_mat.emission_energy_multiplier = 2.0
	_accent_mat.roughness = 0.2

	_shield_mat = StandardMaterial3D.new()
	_shield_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shield_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_shield_mat.albedo_color = Color(accent_color.r, accent_color.g, accent_color.b, 0.24)
	_shield_mat.emission_enabled = true
	_shield_mat.emission = accent_color
	_shield_mat.emission_energy_multiplier = 1.2


func _build_humanoid_hierarchy() -> void:
	# Soft ground shadow disc beneath the character
	_ground_shadow = MeshInstance3D.new()
	_ground_shadow.name = "GroundShadowDisc"
	var shadow_cyl := CylinderMesh.new()
	shadow_cyl.top_radius = 0.58
	shadow_cyl.bottom_radius = 0.62
	shadow_cyl.height = 0.012
	shadow_cyl.radial_segments = 20
	_ground_shadow.mesh = shadow_cyl
	_ground_shadow.position = Vector3(0.0, 0.012, 0.0)
	_ground_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shadow_mat := StandardMaterial3D.new()
	shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow_mat.albedo_color = Color(0.02, 0.04, 0.09, 0.55)
	_ground_shadow.material_override = shadow_mat
	add_child(_ground_shadow)

	# Ground hit-area ring
	_base_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.48
	ring_mesh.outer_radius = 0.56
	ring_mesh.rings = 20
	ring_mesh.ring_segments = 6
	_base_ring.mesh = ring_mesh
	_base_ring.position = Vector3(0.0, 0.03, 0.0)
	_base_ring.material_override = _accent_mat
	add_child(_base_ring)

	# Invincibility shield dome/cylinder during 5s prep phase
	_invincible_shield = MeshInstance3D.new()
	var shield_cyl := CylinderMesh.new()
	shield_cyl.top_radius = 0.62
	shield_cyl.bottom_radius = 0.62
	shield_cyl.height = 0.35
	shield_cyl.radial_segments = 16
	shield_cyl.cap_top = false
	shield_cyl.cap_bottom = false
	_invincible_shield.mesh = shield_cyl
	_invincible_shield.position = Vector3(0.0, 0.20, 0.0)
	_invincible_shield.material_override = _shield_mat
	_invincible_shield.visible = false
	add_child(_invincible_shield)

	# Pelvis root
	_pelvis_pivot = Node3D.new()
	_pelvis_pivot.name = "PelvisPivot"
	_pelvis_pivot.position = Vector3(0.0, 0.56, 0.0)
	_pelvis_pivot.scale = Vector3(1.28, 1.28, 1.28)
	add_child(_pelvis_pivot)

	var pelvis_mi := MeshInstance3D.new()
	pelvis_mi.mesh = LowPolyBuilder.create_pelvis_mesh()
	pelvis_mi.material_override = _dark_mat
	_pelvis_pivot.add_child(pelvis_mi)

	# Torso pivot
	_torso_pivot = Node3D.new()
	_torso_pivot.name = "TorsoPivot"
	_torso_pivot.position = Vector3(0.0, 0.12, 0.0)
	_pelvis_pivot.add_child(_torso_pivot)

	var torso_mi := MeshInstance3D.new()
	torso_mi.mesh = LowPolyBuilder.create_torso_mesh()
	torso_mi.material_override = _primary_mat
	_torso_pivot.add_child(torso_mi)

	var backpack_mi := MeshInstance3D.new()
	backpack_mi.mesh = LowPolyBuilder.create_backpack_mesh()
	backpack_mi.material_override = _dark_mat
	_torso_pivot.add_child(backpack_mi)

	# Glowing chest emitter core (facing +Z at torso center)
	_chest_core = MeshInstance3D.new()
	_chest_core.mesh = LowPolyBuilder.create_chamfered_box(Vector3(0.18, 0.18, 0.12), 0.03, Vector3(0.0, 0.27, 0.21))
	_chest_core.material_override = _accent_mat
	_torso_pivot.add_child(_chest_core)

	# Head pivot & helmet
	_head_pivot = Node3D.new()
	_head_pivot.name = "HeadPivot"
	_head_pivot.position = Vector3(0.0, 0.51, 0.0)
	_torso_pivot.add_child(_head_pivot)

	var helmet_mi := MeshInstance3D.new()
	helmet_mi.mesh = LowPolyBuilder.create_helmet_mesh()
	helmet_mi.material_override = _primary_mat
	_head_pivot.add_child(helmet_mi)

	var visor_mi := MeshInstance3D.new()
	visor_mi.mesh = LowPolyBuilder.create_visor_mesh()
	visor_mi.material_override = _accent_mat
	_head_pivot.add_child(visor_mi)

	var crest_mi := MeshInstance3D.new()
	crest_mi.mesh = LowPolyBuilder.create_crest_mesh()
	crest_mi.material_override = _accent_mat
	_head_pivot.add_child(crest_mi)

	# Left & Right Arms
	_left_shoulder = _build_arm("LeftArm", Vector3(-0.34, 0.43, 0.0), true)
	_right_shoulder = _build_arm("RightArm", Vector3(0.34, 0.43, 0.0), false)

	# Left & Right Legs
	_left_hip = _build_leg("LeftLeg", Vector3(-0.15, 0.02, 0.0), true)
	_right_hip = _build_leg("RightLeg", Vector3(0.15, 0.02, 0.0), false)


func _build_arm(arm_name: String, shoulder_pos: Vector3, is_left: bool) -> Node3D:
	var shoulder := Node3D.new()
	shoulder.name = arm_name
	shoulder.position = shoulder_pos
	_torso_pivot.add_child(shoulder)

	var pauldron := MeshInstance3D.new()
	pauldron.mesh = LowPolyBuilder.create_shoulder_pad_mesh()
	pauldron.material_override = _primary_mat
	shoulder.add_child(pauldron)

	var upper_arm := MeshInstance3D.new()
	upper_arm.mesh = LowPolyBuilder.create_limb_segment_mesh(0.24, 0.085, 0.075, 0.068)
	upper_arm.material_override = _dark_mat
	shoulder.add_child(upper_arm)

	var elbow := Node3D.new()
	elbow.name = "ElbowPivot"
	elbow.position = Vector3(0.0, -0.23, 0.0)
	shoulder.add_child(elbow)

	var forearm := MeshInstance3D.new()
	forearm.mesh = LowPolyBuilder.create_limb_segment_mesh(0.24, 0.075, 0.088, 0.072)
	forearm.material_override = _primary_mat
	elbow.add_child(forearm)

	var hand := MeshInstance3D.new()
	hand.mesh = LowPolyBuilder.create_chamfered_box(Vector3(0.11, 0.11, 0.12), 0.025, Vector3(0.0, -0.26, 0.0))
	hand.material_override = _dark_mat
	elbow.add_child(hand)

	if is_left:
		_left_elbow = elbow
	else:
		_right_elbow = elbow

	return shoulder


func _build_leg(leg_name: String, hip_pos: Vector3, is_left: bool) -> Node3D:
	var hip := Node3D.new()
	hip.name = leg_name
	hip.position = hip_pos
	_pelvis_pivot.add_child(hip)

	var thigh := MeshInstance3D.new()
	thigh.mesh = LowPolyBuilder.create_limb_segment_mesh(0.28, 0.11, 0.098, 0.085)
	thigh.material_override = _dark_mat
	hip.add_child(thigh)

	var knee := Node3D.new()
	knee.name = "KneePivot"
	knee.position = Vector3(0.0, -0.27, 0.0)
	hip.add_child(knee)

	var shin := MeshInstance3D.new()
	shin.mesh = LowPolyBuilder.create_limb_segment_mesh(0.26, 0.09, 0.095, 0.08)
	shin.material_override = _primary_mat
	knee.add_child(shin)

	var boot := MeshInstance3D.new()
	boot.mesh = LowPolyBuilder.create_boot_mesh()
	boot.position = Vector3(0.0, -0.25, 0.0)
	boot.material_override = _dark_mat
	knee.add_child(boot)

	if is_left:
		_left_knee = knee
	else:
		_right_knee = knee

	return hip
