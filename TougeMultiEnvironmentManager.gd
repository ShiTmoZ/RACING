class_name TougeMultiEnvironmentManager
extends Node3D

signal environment_rebuilt(track_id: String, spawn_transform: Transform3D)

class TrackSample:
	var pos: Vector3 = Vector3.ZERO
	var forward: Vector3 = Vector3.FORWARD
	var right: Vector3 = Vector3.RIGHT
	var banked_up: Vector3 = Vector3.UP
	var width: float = 9.5
	var bank_angle: float = 0.0

var _active_track_root: Node3D = null
var _current_samples: Array[TrackSample] = []
var _last_spawn_transform: Transform3D = Transform3D.IDENTITY


func _ready() -> void:
	name = "TougeMultiEnvironmentManager"



func load_environment(track_id: String, _target_scene_root: Node3D = null, vehicle: RigidBody3D = null) -> void:
	var track_data: Dictionary = {}
	var registry_script = load("res://TougeTrackRegistryAndMenu.gd")
	if registry_script != null and "TRACK_REGISTRY" in registry_script:
		var reg: Dictionary = registry_script.TRACK_REGISTRY
		if reg.has(track_id):
			track_data = reg[track_id]
	load_track_environment(track_id, track_data, vehicle)

func load_track_environment(track_id: String, track_data: Dictionary, vehicle: RigidBody3D = null) -> Transform3D:
	# Freeze vehicle briefly while swapping collision meshes
	if is_instance_valid(vehicle):
		vehicle.sleeping = true

	_cleanup_previous_track_nodes()

	_active_track_root = Node3D.new()
	_active_track_root.name = "GeneratedTrack_" + track_id
	add_child(_active_track_root)

	# Generate spline control points for the requested track (including akina_downhill)
	var control_points: PackedVector3Array = _build_control_points_for_track(track_id)
	var road_width: float = float(track_data.get("road_width", 9.5))

	_current_samples = _sample_spline_with_banking(control_points, road_width, 3.0)
	_build_road_mesh_and_collision(_active_track_root, _current_samples)
	_apply_environment_atmosphere(track_id, track_data)

	# Calculate exact summit spawn transform at Sample 1 (slightly ahead of back wall)
	var s0: TrackSample = _current_samples[1] if _current_samples.size() > 1 else _current_samples[0]

	# Spawn at +0.48m along banked_up so 0.72m suspension raycasts are immediately in contact
	var spawn_pos: Vector3 = s0.pos + s0.banked_up * 0.48
	var forward_dir: Vector3 = s0.forward.normalized()
	var up_dir: Vector3 = s0.banked_up.normalized()
	var right_dir: Vector3 = forward_dir.cross(up_dir).normalized()
	up_dir = right_dir.cross(forward_dir).normalized()

	# Standard Godot vehicle convention: -Z is forward, +Y is up, +X is right
	var spawn_basis := Basis(right_dir, up_dir, -forward_dir).orthonormalized()
	_last_spawn_transform = Transform3D(spawn_basis, spawn_pos)

	if is_instance_valid(vehicle):
		_place_vehicle_at_spawn(vehicle, _last_spawn_transform)

	environment_rebuilt.emit(track_id, _last_spawn_transform)
	return _last_spawn_transform


func _place_vehicle_at_spawn(vehicle: RigidBody3D, spawn_xform: Transform3D) -> void:
	if not is_instance_valid(vehicle):
		return
	PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, spawn_xform)
	PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	vehicle.global_transform = spawn_xform
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle.sleeping = false
	vehicle.reset_physics_interpolation()
	if vehicle.has_method("reset_telemetry"):
		vehicle.call("reset_telemetry")


func _cleanup_previous_track_nodes() -> void:
	if is_instance_valid(_active_track_root):
		_active_track_root.queue_free()
		_active_track_root = null

	var scene_root := get_tree().current_scene
	if not scene_root:
		return

	# Clean up legacy static track nodes if they exist so they don't conflict or leave orphans
	var legacy_names: Array[String] = ["AkinaDefaultTrack", "TougeTrackRoot", "GeneratedTrack"]
	for legacy_name in legacy_names:
		var old_node := scene_root.find_child(legacy_name, true, false)
		if is_instance_valid(old_node) and old_node != self:
			old_node.queue_free()


func _build_control_points_for_track(track_id: String) -> PackedVector3Array:
	var pts := PackedVector3Array()

	match track_id:
		"akina_downhill":
			# Starts at Summit Y = 128.0m and descends through 5 iconic hairpins
			pts.append(Vector3(0.0, 128.0, 0.0))
			pts.append(Vector3(0.0, 126.5, -55.0))
			pts.append(Vector3(18.0, 122.0, -135.0))
			pts.append(Vector3(78.0, 114.0, -170.0))   # Hairpin 1 Entry
			pts.append(Vector3(95.0, 108.0, -120.0))   # Hairpin 1 Exit
			pts.append(Vector3(10.0, 99.0, -85.0))     # Straightaway
			pts.append(Vector3(-55.0, 91.0, -115.0))   # Hairpin 2 Entry
			pts.append(Vector3(-62.0, 84.0, -168.0))   # Hairpin 2 Exit
			pts.append(Vector3(25.0, 74.0, -210.0))    # S-Curve Mid
			pts.append(Vector3(105.0, 64.0, -255.0))   # Hairpin 3 Entry
			pts.append(Vector3(98.0, 56.0, -310.0))    # Hairpin 3 Exit
			pts.append(Vector3(-20.0, 44.0, -340.0))   # Fast Gutter Sweep
			pts.append(Vector3(-88.0, 32.0, -385.0))   # Hairpin 4 Entry
			pts.append(Vector3(-75.0, 23.0, -440.0))   # Hairpin 4 Exit
			pts.append(Vector3(35.0, 12.0, -485.0))    # Final Hairpin 5
			pts.append(Vector3(60.0, 4.0, -560.0))     # Valley Finish Line

		"irohazaka_downhill":
			# Steep switchbacks descending from Y = 165.0m
			var y_alt: float = 165.0
			var z_cursor: float = 0.0
			pts.append(Vector3(0.0, y_alt, 0.0))
			pts.append(Vector3(0.0, y_alt - 2.0, -50.0))
			for i in range(6):
				var side: float = 1.0 if (i % 2 == 0) else -1.0
				z_cursor -= 52.0
				y_alt -= 11.0
				pts.append(Vector3(side * 85.0, y_alt, z_cursor))
				z_cursor -= 38.0
				y_alt -= 9.5
				pts.append(Vector3(side * 92.0, y_alt, z_cursor))

		"tsukuba_circuit":
			# Flatter high-speed technical layout starting at Y = 42.0m
			pts.append(Vector3(0.0, 42.0, 0.0))
			pts.append(Vector3(0.0, 41.8, -90.0))
			pts.append(Vector3(45.0, 40.5, -165.0))
			pts.append(Vector3(110.0, 39.0, -140.0))
			pts.append(Vector3(135.0, 38.0, -40.0))
			pts.append(Vector3(195.0, 36.5, 25.0))
			pts.append(Vector3(240.0, 35.0, -75.0))
			pts.append(Vector3(190.0, 34.5, -220.0))
			pts.append(Vector3(60.0, 36.0, -290.0))
			pts.append(Vector3(-55.0, 38.5, -210.0))
			pts.append(Vector3(-40.0, 40.5, -90.0))

		_: # "hakone_turnpike" or fallback
			pts.append(Vector3(0.0, 190.0, 0.0))
			pts.append(Vector3(0.0, 187.0, -75.0))
			pts.append(Vector3(-65.0, 176.0, -180.0))
			pts.append(Vector3(-15.0, 160.0, -310.0))
			pts.append(Vector3(95.0, 142.0, -420.0))
			pts.append(Vector3(40.0, 124.0, -560.0))
			pts.append(Vector3(-90.0, 104.0, -690.0))
			pts.append(Vector3(-120.0, 82.0, -840.0))

	return pts


func _sample_spline_with_banking(control_pts: PackedVector3Array, road_width: float, bake_interval: float) -> Array[TrackSample]:
	var curve := Curve3D.new()
	curve.bake_interval = bake_interval

	for i in range(control_pts.size()):
		var p: Vector3 = control_pts[i]
		var prev_p: Vector3 = control_pts[max(i - 1, 0)]
		var next_p: Vector3 = control_pts[min(i + 1, control_pts.size() - 1)]
		var tangent: Vector3 = (next_p - prev_p) * 0.28
		curve.add_point(p, -tangent, tangent)

	var baked_pts: PackedVector3Array = curve.get_baked_points()
	var samples: Array[TrackSample] = []

	for i in range(baked_pts.size()):
		var s := TrackSample.new()
		s.pos = baked_pts[i]
		s.width = road_width

		var p_prev: Vector3 = baked_pts[max(i - 1, 0)]
		var p_next: Vector3 = baked_pts[min(i + 1, baked_pts.size() - 1)]
		var fwd: Vector3 = (p_next - p_prev)
		if fwd.length_squared() < 0.0001:
			fwd = Vector3.FORWARD
		s.forward = fwd.normalized()

		# Compute horizontal curvature for banking
		var p_prev2: Vector3 = baked_pts[max(i - 3, 0)]
		var p_next2: Vector3 = baked_pts[min(i + 3, baked_pts.size() - 1)]
		var dir1: Vector3 = (s.pos - p_prev2).normalized()
		var dir2: Vector3 = (p_next2 - s.pos).normalized()
		var turn_cross: float = dir1.cross(dir2).y
		var bank_rad: float = clampf(turn_cross * 0.45, -deg_to_rad(8.0), deg_to_rad(8.0))
		s.bank_angle = bank_rad

		var flat_right: Vector3 = s.forward.cross(Vector3.UP).normalized()
		if flat_right.length_squared() < 0.001:
			flat_right = Vector3.RIGHT
		var base_up: Vector3 = flat_right.cross(s.forward).normalized()

		var bank_rot := Basis(s.forward, bank_rad)
		s.right = (bank_rot * flat_right).normalized()
		s.banked_up = (bank_rot * base_up).normalized()
		samples.append(s)

	return samples


func _build_road_mesh_and_collision(parent: Node3D, samples: Array[TrackSample]) -> void:
	if samples.size() < 2:
		return

	var st_road := SurfaceTool.new()
	st_road.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_guard := SurfaceTool.new()
	st_guard.begin(Mesh.PRIMITIVE_TRIANGLES)

	var col_faces := PackedVector3Array()
	var uv_dist: float = 0.0

	for i in range(samples.size() - 1):
		var s0: TrackSample = samples[i]
		var s1: TrackSample = samples[i + 1]
		var seg_len: float = s0.pos.distance_to(s1.pos)
		var next_uv: float = uv_dist + seg_len * 0.12

		var hw0: float = s0.width * 0.5
		var hw1: float = s1.width * 0.5

		# Road surface corners
		var l0: Vector3 = s0.pos - s0.right * hw0
		var r0: Vector3 = s0.pos + s0.right * hw0
		var l1: Vector3 = s1.pos - s1.right * hw1
		var r1: Vector3 = s1.pos + s1.right * hw1

		# Visual Asphalt Triangles
		st_road.set_normal(s0.banked_up)
		st_road.set_uv(Vector2(0.0, uv_dist))
		st_road.add_vertex(l0)
		st_road.set_normal(s0.banked_up)
		st_road.set_uv(Vector2(1.0, uv_dist))
		st_road.add_vertex(r0)
		st_road.set_normal(s1.banked_up)
		st_road.set_uv(Vector2(1.0, next_uv))
		st_road.add_vertex(r1)

		st_road.set_normal(s0.banked_up)
		st_road.set_uv(Vector2(0.0, uv_dist))
		st_road.add_vertex(l0)
		st_road.set_normal(s1.banked_up)
		st_road.set_uv(Vector2(1.0, next_uv))
		st_road.add_vertex(r1)
		st_road.set_normal(s1.banked_up)
		st_road.set_uv(Vector2(0.0, next_uv))
		st_road.add_vertex(l1)

		# Collision Deck (Top surface + wide shoulders + guard walls)
		var cl0: Vector3 = s0.pos - s0.right * (hw0 + 1.2)
		var cr0: Vector3 = s0.pos + s0.right * (hw0 + 1.2)
		var cl1: Vector3 = s1.pos - s1.right * (hw1 + 1.2)
		var cr1: Vector3 = s1.pos + s1.right * (hw1 + 1.2)

		col_faces.append_array([cl0, cr0, cr1, cl0, cr1, cl1])

		# Guardrail / Curb Walls (Left & Right)
		var wall_h: float = 1.15
		var lw0_top: Vector3 = l0 + s0.banked_up * wall_h
		var lw1_top: Vector3 = l1 + s1.banked_up * wall_h
		var rw0_top: Vector3 = r0 + s0.banked_up * wall_h
		var rw1_top: Vector3 = r1 + s1.banked_up * wall_h

		col_faces.append_array([l0, l1, lw1_top, l0, lw1_top, lw0_top])
		col_faces.append_array([r1, r0, rw0_top, r1, rw0_top, rw1_top])

		# Visual Guardrails
		st_guard.set_normal(s0.right)
		st_guard.add_vertex(l0)
		st_guard.add_vertex(l1)
		st_guard.add_vertex(lw1_top)
		st_guard.add_vertex(l0)
		st_guard.add_vertex(lw1_top)
		st_guard.add_vertex(lw0_top)

		st_guard.set_normal(-s0.right)
		st_guard.add_vertex(r1)
		st_guard.add_vertex(r0)
		st_guard.add_vertex(rw0_top)
		st_guard.add_vertex(r1)
		st_guard.add_vertex(rw0_top)
		st_guard.add_vertex(rw1_top)

		uv_dist = next_uv

	var road_mat := StandardMaterial3D.new()
	road_mat.albedo_color = Color(0.16, 0.17, 0.19)
	road_mat.roughness = 0.86
	road_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var road_mesh_inst := MeshInstance3D.new()
	road_mesh_inst.name = "RoadSurfaceMesh"
	road_mesh_inst.mesh = st_road.commit()
	road_mesh_inst.material_override = road_mat
	parent.add_child(road_mesh_inst)

	var guard_mat := StandardMaterial3D.new()
	guard_mat.albedo_color = Color(0.82, 0.84, 0.88)
	guard_mat.metallic = 0.35
	guard_mat.roughness = 0.45
	guard_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var guard_mesh_inst := MeshInstance3D.new()
	guard_mesh_inst.name = "GuardrailMesh"
	guard_mesh_inst.mesh = st_guard.commit()
	guard_mesh_inst.material_override = guard_mat
	parent.add_child(guard_mesh_inst)

	var static_body := StaticBody3D.new()
	static_body.name = "TrackStaticBody3D"
	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = 1.0
	phys_mat.rough = true
	static_body.physics_material_override = phys_mat

	var col_shape := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.backface_collision = true
	concave.set_faces(col_faces)
	col_shape.shape = concave

	static_body.add_child(col_shape)
	parent.add_child(static_body)


func _apply_environment_atmosphere(_track_id: String, track_data: Dictionary) -> void:
	var scene_root := get_tree().current_scene
	if not scene_root:
		return

	var world_env := scene_root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if not is_instance_valid(world_env) or not is_instance_valid(world_env.environment):
		return

	var env: Environment = world_env.environment
	var tod: String = str(track_data.get("time_of_day", "NIGHT"))

	match tod:
		"SUNSET":
			env.background_color = Color(0.28, 0.14, 0.12)
			env.ambient_light_color = Color(0.55, 0.35, 0.28)
			env.ambient_light_energy = 0.65
			env.fog_enabled = true
			env.fog_light_color = Color(0.38, 0.22, 0.18)
			env.fog_density = 0.0025
		"DAY":
			env.background_color = Color(0.42, 0.62, 0.85)
			env.ambient_light_color = Color(0.78, 0.84, 0.92)
			env.ambient_light_energy = 0.95
			env.fog_enabled = true
			env.fog_light_color = Color(0.65, 0.75, 0.88)
			env.fog_density = 0.001
		"MIDNIGHT_FOG":
			env.background_color = Color(0.03, 0.05, 0.08)
			env.ambient_light_color = Color(0.15, 0.22, 0.30)
			env.ambient_light_energy = 0.35
			env.fog_enabled = true
			env.fog_light_color = Color(0.12, 0.16, 0.22)
			env.fog_density = 0.012
		_: # "NIGHT" (Mount Akina Default)
			env.background_color = Color(0.02, 0.03, 0.06)
			env.ambient_light_color = Color(0.14, 0.18, 0.28)
			env.ambient_light_energy = 0.40
			env.fog_enabled = true
			env.fog_light_color = Color(0.05, 0.07, 0.12)
			env.fog_density = 0.002