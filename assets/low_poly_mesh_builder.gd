class_name LowPolyMeshBuilder
extends RefCounted
## Generates custom faceted low-poly ArrayMesh geometry using SurfaceTool.
## Used for the articulated 3D humanoid characters, beveled arena tiles, and tactical obstacles.


static func create_tapered_prism(
	radii: PackedFloat32Array,
	heights: PackedFloat32Array,
	sides: int = 8,
	scale_x: float = 1.0,
	scale_z: float = 1.0,
	offset: Vector3 = Vector3.ZERO
) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var ring_count := radii.size()
	if ring_count < 2 or heights.size() != ring_count:
		return ArrayMesh.new()

	var rings: Array[PackedVector3Array] = []
	for r_idx in range(ring_count):
		var ring := PackedVector3Array()
		var radius := radii[r_idx]
		var y := heights[r_idx]
		for s in range(sides):
			var angle := (float(s) / float(sides)) * TAU + (PI / float(sides))
			var vx := cos(angle) * radius * scale_x + offset.x
			var vz := sin(angle) * radius * scale_z + offset.z
			ring.append(Vector3(vx, y + offset.y, vz))
		rings.append(ring)

	# Side faces (flat-shaded per quad for crisp low-poly look)
	for r_idx in range(ring_count - 1):
		var lower := rings[r_idx]
		var upper := rings[r_idx + 1]
		for s in range(sides):
			var next_s := (s + 1) % sides
			var p00 := lower[s]
			var p10 := lower[next_s]
			var p01 := upper[s]
			var p11 := upper[next_s]

			var normal := (p10 - p00).cross(p01 - p00).normalized()
			if normal.length_squared() < 0.0001:
				normal = Vector3.UP

			st.set_normal(normal)
			st.add_vertex(p00)
			st.set_normal(normal)
			st.add_vertex(p10)
			st.set_normal(normal)
			st.add_vertex(p11)

			st.set_normal(normal)
			st.add_vertex(p00)
			st.set_normal(normal)
			st.add_vertex(p11)
			st.set_normal(normal)
			st.add_vertex(p01)

	# Bottom cap
	var bottom_center := Vector3(offset.x, heights[0] + offset.y, offset.z)
	var bottom_ring := rings[0]
	for s in range(sides):
		var next_s := (s + 1) % sides
		st.set_normal(Vector3.DOWN)
		st.add_vertex(bottom_center)
		st.set_normal(Vector3.DOWN)
		st.add_vertex(bottom_ring[next_s])
		st.set_normal(Vector3.DOWN)
		st.add_vertex(bottom_ring[s])

	# Top cap
	var top_center := Vector3(offset.x, heights[ring_count - 1] + offset.y, offset.z)
	var top_ring := rings[ring_count - 1]
	for s in range(sides):
		var next_s := (s + 1) % sides
		st.set_normal(Vector3.UP)
		st.add_vertex(top_center)
		st.set_normal(Vector3.UP)
		st.add_vertex(top_ring[s])
		st.set_normal(Vector3.UP)
		st.add_vertex(top_ring[next_s])

	return st.commit()


static func create_helmet_mesh() -> ArrayMesh:
	# Multi-section low-poly combat helmet with jawline taper and crown dome
	var radii := PackedFloat32Array([0.13, 0.21, 0.23, 0.20, 0.11])
	var heights := PackedFloat32Array([0.0, 0.09, 0.24, 0.36, 0.43])
	return create_tapered_prism(radii, heights, 8, 0.96, 1.08, Vector3.ZERO)


static func create_visor_mesh() -> ArrayMesh:
	# Curved wrap-around front visor plate facing +Z
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var arc_points := 5
	var radius := 0.235
	var y_bot := 0.14
	var y_top := 0.28
	var start_angle := -PI * 0.34
	var end_angle := PI * 0.34

	var bot_verts := PackedVector3Array()
	var top_verts := PackedVector3Array()
	for i in range(arc_points):
		var t := float(i) / float(arc_points - 1)
		var a := lerpf(start_angle, end_angle, t)
		var x := sin(a) * radius * 0.98
		var z := cos(a) * radius * 1.08 + 0.015
		bot_verts.append(Vector3(x, y_bot, z))
		top_verts.append(Vector3(x * 0.96, y_top, z * 0.98))

	for i in range(arc_points - 1):
		var p00 := bot_verts[i]
		var p10 := bot_verts[i + 1]
		var p01 := top_verts[i]
		var p11 := top_verts[i + 1]
		var n := (p01 - p00).cross(p10 - p00).normalized()
		st.set_normal(n)
		st.add_vertex(p00)
		st.set_normal(n)
		st.add_vertex(p01)
		st.set_normal(n)
		st.add_vertex(p11)

		st.set_normal(n)
		st.add_vertex(p00)
		st.set_normal(n)
		st.add_vertex(p11)
		st.set_normal(n)
		st.add_vertex(p10)

	return st.commit()


static func create_crest_mesh() -> ArrayMesh:
	# Sleek Mohawk/crest fin atop helmet
	return create_chamfered_box(Vector3(0.06, 0.12, 0.32), 0.018, Vector3(0.0, 0.41, -0.02))


static func create_torso_mesh() -> ArrayMesh:
	# V-tapered armored chestplate with broad shoulders and defined waist
	var radii := PackedFloat32Array([0.19, 0.23, 0.29, 0.27, 0.16])
	var heights := PackedFloat32Array([0.0, 0.14, 0.38, 0.48, 0.52])
	return create_tapered_prism(radii, heights, 8, 1.18, 0.78, Vector3.ZERO)


static func create_backpack_mesh() -> ArrayMesh:
	# Thruster jetpack module on back (-Z)
	return create_chamfered_box(Vector3(0.28, 0.32, 0.15), 0.03, Vector3(0.0, 0.26, -0.21))


static func create_pelvis_mesh() -> ArrayMesh:
	# Faceted hip armor / tactical belt
	var radii := PackedFloat32Array([0.16, 0.21, 0.19])
	var heights := PackedFloat32Array([0.0, 0.09, 0.16])
	return create_tapered_prism(radii, heights, 8, 1.12, 0.80, Vector3.ZERO)


static func create_shoulder_pad_mesh() -> ArrayMesh:
	# Angled low-poly pauldron
	var radii := PackedFloat32Array([0.11, 0.135, 0.09])
	var heights := PackedFloat32Array([-0.06, 0.03, 0.10])
	return create_tapered_prism(radii, heights, 6, 1.1, 1.0, Vector3.ZERO)


static func create_limb_segment_mesh(length: float, top_r: float, mid_r: float, bot_r: float) -> ArrayMesh:
	# Hanging downward from pivot (0 to -length)
	var radii := PackedFloat32Array([bot_r, mid_r, top_r])
	var heights := PackedFloat32Array([-length, -length * 0.45, 0.0])
	return create_tapered_prism(radii, heights, 6, 1.0, 1.0, Vector3.ZERO)


static func create_boot_mesh() -> ArrayMesh:
	# Faceted low-poly combat boot extending slightly forward (+Z)
	return create_chamfered_box(Vector3(0.15, 0.13, 0.24), 0.025, Vector3(0.0, -0.05, 0.04))


static func create_chamfered_box(size: Vector3, bevel: float, offset: Vector3 = Vector3.ZERO) -> ArrayMesh:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var b := minf(bevel, minf(hx, minf(hy, hz)) * 0.45)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Build a 3-ring prism (bottom bevel, main body, top bevel) with 4-corner chamfered footprint
	var y_levels := PackedFloat32Array([-hy, -hy + b, hy - b, hy])
	var inset_levels := PackedFloat32Array([b, 0.0, 0.0, b])

	var rings: Array[PackedVector3Array] = []
	for r_idx in range(4):
		var ins := inset_levels[r_idx]
		var y := y_levels[r_idx] + offset.y
		var x0 := hx - ins
		var z0 := hz - ins
		var c := b * 0.85
		# 8-point chamfered rectangle in clockwise/CCW order around Y
		var ring := PackedVector3Array([
			Vector3(x0 - c + offset.x, y, z0 + offset.z),
			Vector3(x0 + offset.x, y, z0 - c + offset.z),
			Vector3(x0 + offset.x, y, -z0 + c + offset.z),
			Vector3(x0 - c + offset.x, y, -z0 + offset.z),
			Vector3(-x0 + c + offset.x, y, -z0 + offset.z),
			Vector3(-x0 + offset.x, y, -z0 + c + offset.z),
			Vector3(-x0 + offset.x, y, z0 - c + offset.z),
			Vector3(-x0 + c + offset.x, y, z0 + offset.z),
		])
		rings.append(ring)

	var sides := 8
	for r_idx in range(3):
		var lower := rings[r_idx]
		var upper := rings[r_idx + 1]
		for s in range(sides):
			var next_s := (s + 1) % sides
			var p00 := lower[s]
			var p10 := lower[next_s]
			var p01 := upper[s]
			var p11 := upper[next_s]
			var normal := (p10 - p00).cross(p01 - p00).normalized()
			if normal.length_squared() < 0.0001:
				normal = Vector3.UP

			st.set_normal(normal)
			st.add_vertex(p00)
			st.set_normal(normal)
			st.add_vertex(p10)
			st.set_normal(normal)
			st.add_vertex(p11)

			st.set_normal(normal)
			st.add_vertex(p00)
			st.set_normal(normal)
			st.add_vertex(p11)
			st.set_normal(normal)
			st.add_vertex(p01)

	# Bottom cap
	var bot_center := Vector3(offset.x, -hy + offset.y, offset.z)
	for s in range(sides):
		var next_s := (s + 1) % sides
		st.set_normal(Vector3.DOWN)
		st.add_vertex(bot_center)
		st.set_normal(Vector3.DOWN)
		st.add_vertex(rings[0][next_s])
		st.set_normal(Vector3.DOWN)
		st.add_vertex(rings[0][s])

	# Top cap
	var top_center := Vector3(offset.x, hy + offset.y, offset.z)
	for s in range(sides):
		var next_s := (s + 1) % sides
		st.set_normal(Vector3.UP)
		st.add_vertex(top_center)
		st.set_normal(Vector3.UP)
		st.add_vertex(rings[3][s])
		st.set_normal(Vector3.UP)
		st.add_vertex(rings[3][next_s])

	return st.commit()
