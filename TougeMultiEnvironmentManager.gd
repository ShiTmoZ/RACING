class_name TougeMultiEnvironmentManager
extends Node3D

# ==============================================================================
# TougeMultiEnvironmentManager.gd
# Godot 4.3 Forward+ | Multi-Track Procedural Builder, Terrain Skirts & Atmosphere
# ==============================================================================

const EXTRUDED_DECK_THICKNESS: float = 0.6
const SAFETY_APRON_WIDTH: float = 8.0
const GLOBAL_KILL_PLANE_Y: float = -50.0
const SPLINE_SUBDIVISIONS_PER_SEGMENT: int = 18

var _parent_scene: Node3D = null
var _active_track_root: Node3D = null
var _safety_plane_root: Node3D = null

var _current_track_id: String = "akina_downhill"
var _current_spawn_transform: Transform3D = Transform3D.IDENTITY
var _tracked_vehicle: RigidBody3D = null
var _tracked_camera: Camera3D = null
var _min_track_elevation: float = -20.0

var _current_spline_points: PackedVector3Array = PackedVector3Array()
var _current_spline_tangents: PackedVector3Array = PackedVector3Array()
var _current_spline_rights: PackedVector3Array = PackedVector3Array()
var _current_spline_ups: PackedVector3Array = PackedVector3Array()


func _ready() -> void:
	_parent_scene = get_parent() as Node3D
	set_physics_process(true)


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(_tracked_vehicle):
		return

	# Continuous void-fall safety net: catch vehicles below Y = -50.0 or 35m below lowest track point
	var dynamic_kill_floor: float = minf(GLOBAL_KILL_PLANE_Y, _min_track_elevation - 35.0)
	if _tracked_vehicle.global_position.y < dynamic_kill_floor:
		respawn_vehicle_at_summit(_tracked_vehicle, _tracked_camera)


# ==============================================================================
# PUBLIC API: BUILD / SWITCH TRACK ENVIRONMENT
# ==============================================================================
func build_track_environment(
	track_id: String,
	track_data: Dictionary,
	vehicle: RigidBody3D = null,
	chase_camera: Camera3D = null
) -> Transform3D:
	_current_track_id = track_id
	if is_instance_valid(vehicle):
		_tracked_vehicle = vehicle
	if is_instance_valid(chase_camera):
		_tracked_camera = chase_camera

	# 1. Clean up ONLY previous procedural track geometry; NEVER delete lighting!
	_cleanup_previous_track_nodes()

	# 2. Apply stage-specific sky, sun, ambient, and volumetric fog profile
	_apply_environment_atmosphere(track_id, track_data)

	# 3. Handle Akina Default High-Detail Track vs Procedural Tracks
	var akina_default: Node3D = _get_akina_default_track_node()
	var control_points: Array = track_data.get("control_points", [])
	var road_width: float = float(track_data.get("road_width", 10.5))
	var banking_mult: float = float(track_data.get("banking_angle_deg", 5.0))
	var is_closed_loop: bool = bool(track_data.get("is_circuit", false))

	_active_track_root = Node3D.new()
	_active_track_root.name = "ActiveProceduralTrack_" + track_id
	add_child(_active_track_root)

	if track_id == "akina_downhill" and is_instance_valid(akina_default) and akina_default.get_child_count() > 0:
		# Restore full high-detail AkinaDefaultTrack visibility and physics
		_set_node_branch_active(akina_default, true)
		_current_spawn_transform = _resolve_akina_default_spawn(track_data)
		_min_track_elevation = -160.0
		_build_global_safety_catch_plane(_min_track_elevation)
		return _current_spawn_transform
	else:
		# Disable AkinaDefaultTrack non-destructively (keep in memory for later return)
		if is_instance_valid(akina_default):
			_set_node_branch_active(akina_default, false)

	# 4. Generate smooth Catmull-Rom spline with banking frames
	_generate_spline_frames(control_points, banking_mult, is_closed_loop)

	# 5. Build thickened 0.6m road deck + 8.0m safety aprons + BoxShape3D under-slabs
	_build_road_mesh_and_collision(road_width, is_closed_loop, track_id, track_data)

	# 6. Build stylized mountain terrain skirts, valley basin & 360° horizon ring
	_build_mountain_terrain_skirts(road_width, is_closed_loop, track_id, track_data)

	# 7. Build physical guardrails, curbs, signage & stage-specific props/lights
	_build_guardrails_and_stage_props(road_width, is_closed_loop, track_id, track_data)

	# 8. Build global catch-plane / kill-plane at Y = -50.0 (and below lowest elevation)
	_build_global_safety_catch_plane(_min_track_elevation)

	# 9. Compute summit spawn transform (lifted +0.85m above thickened road surface)
	_current_spawn_transform = _compute_summit_spawn_transform()

	return _current_spawn_transform


func get_current_spawn_transform() -> Transform3D:
	return _current_spawn_transform


func respawn_vehicle_at_summit(vehicle: RigidBody3D, camera: Camera3D = null) -> void:
	if not is_instance_valid(vehicle):
		return

	var rid: RID = vehicle.get_rid()
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, _current_spawn_transform)

	vehicle.global_transform = _current_spawn_transform
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle.sleeping = false

	var cam_to_snap: Camera3D = camera if is_instance_valid(camera) else _tracked_camera
	if is_instance_valid(cam_to_snap) and cam_to_snap.has_method("snap_to_target"):
		cam_to_snap.call("snap_to_target", vehicle)


# ==============================================================================
# SAFE CLEANUP (NEVER TOUCHES LIGHTING OR WORLD ENVIRONMENT)
# ==============================================================================
func _cleanup_previous_track_nodes() -> void:
	if is_instance_valid(_active_track_root):
		_active_track_root.queue_free()
		_active_track_root = null

	if is_instance_valid(_safety_plane_root):
		_safety_plane_root.queue_free()
		_safety_plane_root = null

	# Clean up any legacy procedural containers under self, while strictly sparing
	# any WorldEnvironment, DirectionalLight3D, or FogVolume nodes
	for child in get_children():
		if child is WorldEnvironment or child is DirectionalLight3D or child is FogVolume:
			continue
		if child.name.begins_with("ActiveProceduralTrack_") or child.name == "GlobalSafetyCatchPlane":
			child.queue_free()


func _get_akina_default_track_node() -> Node3D:
	if not is_instance_valid(_parent_scene):
		_parent_scene = get_parent() as Node3D
	if not is_instance_valid(_parent_scene):
		return null

	if "_akina_environment_root" in _parent_scene and is_instance_valid(_parent_scene.get("_akina_environment_root")):
		return _parent_scene.get("_akina_environment_root") as Node3D

	return _parent_scene.get_node_or_null("AkinaDefaultTrack") as Node3D


func _set_node_branch_active(root_node: Node3D, active: bool) -> void:
	if not is_instance_valid(root_node):
		return
	root_node.visible = active
	root_node.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED

	# Also explicitly toggle CollisionObject3D layers inside the branch so hidden
	# Akina colliders never ghost-collide with other tracks
	var stack: Array[Node] = [root_node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CollisionShape3D:
			(n as CollisionShape3D).disabled = not active
		elif n is Light3D or n is FogVolume:
			(n as Node3D).visible = active
		for c in n.get_children():
			stack.push_back(c)


# ==============================================================================
# STAGE-SPECIFIC ATMOSPHERE & LIGHTING PROFILES
# ==============================================================================
func _apply_environment_atmosphere(track_id: String, _track_data: Dictionary) -> void:
	var world_env: WorldEnvironment = _get_or_create_world_environment()
	var sun: DirectionalLight3D = _get_or_create_sun_light()
	var rim: DirectionalLight3D = _get_or_create_rim_light()
	var valley_fog: FogVolume = _get_or_create_valley_fog()

	var env: Environment = world_env.environment
	var sky_mat: ProceduralSkyMaterial = null
	if env.sky and env.sky.sky_material is ProceduralSkyMaterial:
		sky_mat = env.sky.sky_material as ProceduralSkyMaterial
	else:
		sky_mat = ProceduralSkyMaterial.new()
		var new_sky := Sky.new()
		new_sky.sky_material = sky_mat
		new_sky.process_mode = Sky.PROCESS_MODE_REALTIME
		env.sky = new_sky

	env.background_mode = Environment.BG_SKY

	match track_id:
		"akina_downhill":
			# Midnight Touge, Deep Blue/Purple Ambient, Golden Streetlights, Volumetric Valley Fog
			sky_mat.sky_top_color = Color(0.015, 0.02, 0.055)
			sky_mat.sky_horizon_color = Color(0.05, 0.045, 0.11)
			sky_mat.ground_horizon_color = Color(0.03, 0.03, 0.07)
			sky_mat.ground_bottom_color = Color(0.01, 0.01, 0.025)
			sky_mat.sun_angle_max = 25.0

			sun.light_color = Color(0.45, 0.58, 0.88)
			sun.light_energy = 0.42
			sun.light_volumetric_fog_energy = 1.25
			sun.rotation_degrees = Vector3(-38.0, -35.0, 0.0)
			sun.shadow_enabled = true

			rim.light_color = Color(0.28, 0.34, 0.58)
			rim.light_energy = 0.20

			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.09, 0.08, 0.18)
			env.ambient_light_energy = 0.68
			env.ambient_light_sky_contribution = 0.35
			env.tonemap_exposure = 1.05

			env.fog_enabled = true
			env.fog_light_color = Color(0.05, 0.05, 0.11)
			env.fog_light_energy = 0.85
			env.fog_density = 0.0022
			env.fog_sun_scatter = 0.10

			env.volumetric_fog_enabled = true
			env.volumetric_fog_density = 0.0085
			env.volumetric_fog_albedo = Color(0.07, 0.08, 0.16)
			env.volumetric_fog_emission = Color(0.02, 0.02, 0.05)
			env.volumetric_fog_emission_energy = 0.60
			env.volumetric_fog_anisotropy = 0.55

			if is_instance_valid(valley_fog) and valley_fog.material is FogMaterial:
				valley_fog.visible = true
				var fm := valley_fog.material as FogMaterial
				fm.density = 0.018
				fm.albedo = Color(0.08, 0.10, 0.20)
				fm.emission = Color(0.02, 0.03, 0.08)

		"irohazaka_downhill":
			# Autumn Sunset, Warm Orange/Red Horizon Glow, Long Shadows
			sky_mat.sky_top_color = Color(0.16, 0.10, 0.28)
			sky_mat.sky_horizon_color = Color(0.96, 0.38, 0.14)
			sky_mat.ground_horizon_color = Color(0.58, 0.22, 0.10)
			sky_mat.ground_bottom_color = Color(0.08, 0.04, 0.03)
			sky_mat.sun_angle_max = 42.0

			sun.light_color = Color(1.0, 0.54, 0.24)
			sun.light_energy = 1.85
			sun.light_volumetric_fog_energy = 1.6
			sun.rotation_degrees = Vector3(-15.0, -62.0, 0.0) # Low sun for dramatic long shadows
			sun.shadow_enabled = true

			rim.light_color = Color(0.75, 0.35, 0.22)
			rim.light_energy = 0.35

			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.45, 0.22, 0.16)
			env.ambient_light_energy = 0.78
			env.ambient_light_sky_contribution = 0.55
			env.tonemap_exposure = 1.08

			env.fog_enabled = true
			env.fog_light_color = Color(0.76, 0.34, 0.18)
			env.fog_light_energy = 1.15
			env.fog_density = 0.0018
			env.fog_sun_scatter = 0.65

			env.volumetric_fog_enabled = true
			env.volumetric_fog_density = 0.0045
			env.volumetric_fog_albedo = Color(0.88, 0.44, 0.22)
			env.volumetric_fog_emission = Color(0.18, 0.06, 0.02)
			env.volumetric_fog_emission_energy = 0.75
			env.volumetric_fog_anisotropy = 0.62

			if is_instance_valid(valley_fog) and valley_fog.material is FogMaterial:
				valley_fog.visible = true
				var fm := valley_fog.material as FogMaterial
				fm.density = 0.012
				fm.albedo = Color(0.75, 0.36, 0.20)
				fm.emission = Color(0.16, 0.05, 0.02)

		"tsukuba_circuit":
			# Crisp Daylight, Clear Sky, High Contrast Shadows
			sky_mat.sky_top_color = Color(0.12, 0.42, 0.86)
			sky_mat.sky_horizon_color = Color(0.64, 0.80, 0.96)
			sky_mat.ground_horizon_color = Color(0.44, 0.52, 0.46)
			sky_mat.ground_bottom_color = Color(0.18, 0.22, 0.18)
			sky_mat.sun_angle_max = 18.0

			sun.light_color = Color(1.0, 0.97, 0.91)
			sun.light_energy = 2.35
			sun.light_volumetric_fog_energy = 0.2
			sun.rotation_degrees = Vector3(-52.0, 38.0, 0.0) # High angle for crisp contrast
			sun.shadow_enabled = true

			rim.light_color = Color(0.55, 0.70, 0.88)
			rim.light_energy = 0.42

			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.64, 0.74, 0.88)
			env.ambient_light_energy = 0.88
			env.ambient_light_sky_contribution = 0.75
			env.tonemap_exposure = 1.0

			env.fog_enabled = true
			env.fog_light_color = Color(0.68, 0.82, 0.96)
			env.fog_light_energy = 1.0
			env.fog_density = 0.00035
			env.fog_sun_scatter = 0.15

			env.volumetric_fog_enabled = false

			if is_instance_valid(valley_fog):
				valley_fog.visible = false

		"hakone_turnpike":
			# Dense Midnight Fog, Reduced View Distance, Moody Headlight Scattering
			sky_mat.sky_top_color = Color(0.02, 0.035, 0.048)
			sky_mat.sky_horizon_color = Color(0.08, 0.12, 0.15)
			sky_mat.ground_horizon_color = Color(0.05, 0.08, 0.10)
			sky_mat.ground_bottom_color = Color(0.01, 0.02, 0.03)
			sky_mat.sun_angle_max = 30.0

			sun.light_color = Color(0.52, 0.68, 0.76)
			sun.light_energy = 0.28
			sun.light_volumetric_fog_energy = 2.1
			sun.rotation_degrees = Vector3(-32.0, 20.0, 0.0)
			sun.shadow_enabled = true

			rim.light_color = Color(0.22, 0.34, 0.40)
			rim.light_energy = 0.18

			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.10, 0.15, 0.18)
			env.ambient_light_energy = 0.58
			env.ambient_light_sky_contribution = 0.30
			env.tonemap_exposure = 1.10

			env.fog_enabled = true
			env.fog_light_color = Color(0.10, 0.15, 0.18)
			env.fog_light_energy = 0.95
			env.fog_density = 0.0085
			env.fog_sun_scatter = 0.35

			env.volumetric_fog_enabled = true
			env.volumetric_fog_density = 0.024
			env.volumetric_fog_albedo = Color(0.18, 0.24, 0.28)
			env.volumetric_fog_emission = Color(0.03, 0.05, 0.06)
			env.volumetric_fog_emission_energy = 0.55
			env.volumetric_fog_anisotropy = 0.68 # Strong forward scattering for car headlights

			if is_instance_valid(valley_fog) and valley_fog.material is FogMaterial:
				valley_fog.visible = true
				var fm := valley_fog.material as FogMaterial
				fm.density = 0.032
				fm.albedo = Color(0.14, 0.20, 0.24)
				fm.emission = Color(0.03, 0.05, 0.06)


func _get_or_create_world_environment() -> WorldEnvironment:
	if not is_instance_valid(_parent_scene):
		_parent_scene = get_parent() as Node3D

	if is_instance_valid(_parent_scene):
		if "_world_env_node" in _parent_scene and is_instance_valid(_parent_scene.get("_world_env_node")):
			return _parent_scene.get("_world_env_node") as WorldEnvironment
		var found := _parent_scene.get_node_or_null("PersistentWorldEnvironment") as WorldEnvironment
		if is_instance_valid(found):
			return found

	# Fallback creation if missing
	var world_env := WorldEnvironment.new()
	world_env.name = "PersistentWorldEnvironment"
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	world_env.environment = env
	if is_instance_valid(_parent_scene):
		_parent_scene.add_child(world_env)
		if "_world_env_node" in _parent_scene:
			_parent_scene.set("_world_env_node", world_env)
	else:
		add_child(world_env)
	return world_env


func _get_or_create_sun_light() -> DirectionalLight3D:
	if not is_instance_valid(_parent_scene):
		_parent_scene = get_parent() as Node3D

	if is_instance_valid(_parent_scene):
		if "_sun_light_node" in _parent_scene and is_instance_valid(_parent_scene.get("_sun_light_node")):
			return _parent_scene.get("_sun_light_node") as DirectionalLight3D
		var found := _parent_scene.get_node_or_null("PersistentSunLight") as DirectionalLight3D
		if is_instance_valid(found):
			return found

	var sun := DirectionalLight3D.new()
	sun.name = "PersistentSunLight"
	sun.shadow_enabled = true
	if is_instance_valid(_parent_scene):
		_parent_scene.add_child(sun)
		if "_sun_light_node" in _parent_scene:
			_parent_scene.set("_sun_light_node", sun)
	else:
		add_child(sun)
	return sun


func _get_or_create_rim_light() -> DirectionalLight3D:
	if not is_instance_valid(_parent_scene):
		_parent_scene = get_parent() as Node3D

	if is_instance_valid(_parent_scene):
		if "_rim_light_node" in _parent_scene and is_instance_valid(_parent_scene.get("_rim_light_node")):
			return _parent_scene.get("_rim_light_node") as DirectionalLight3D
		var found := _parent_scene.get_node_or_null("PersistentRimLight") as DirectionalLight3D
		if is_instance_valid(found):
			return found

	var rim := DirectionalLight3D.new()
	rim.name = "PersistentRimLight"
	rim.shadow_enabled = false
	rim.rotation_degrees = Vector3(-22.0, 145.0, 0.0)
	if is_instance_valid(_parent_scene):
		_parent_scene.add_child(rim)
		if "_rim_light_node" in _parent_scene:
			_parent_scene.set("_rim_light_node", rim)
	else:
		add_child(rim)
	return rim


func _get_or_create_valley_fog() -> FogVolume:
	if not is_instance_valid(_parent_scene):
		_parent_scene = get_parent() as Node3D

	if is_instance_valid(_parent_scene):
		if "_valley_fog_node" in _parent_scene and is_instance_valid(_parent_scene.get("_valley_fog_node")):
			return _parent_scene.get("_valley_fog_node") as FogVolume
		var found := _parent_scene.get_node_or_null("PersistentValleyFog") as FogVolume
		if is_instance_valid(found):
			return found

	var valley_fog := FogVolume.new()
	valley_fog.name = "PersistentValleyFog"
	valley_fog.size = Vector3(4500.0, 140.0, 4500.0)
	valley_fog.position = Vector3(0.0, -45.0, 0.0)
	var fm := FogMaterial.new()
	fm.density = 0.015
	valley_fog.material = fm
	if is_instance_valid(_parent_scene):
		_parent_scene.add_child(valley_fog)
		if "_valley_fog_node" in _parent_scene:
			_parent_scene.set("_valley_fog_node", valley_fog)
	else:
		add_child(valley_fog)
	return valley_fog


# ==============================================================================
# CATMULL-ROM SPLINE & BANKING FRAME GENERATION
# ==============================================================================
func _generate_spline_frames(control_points: Array, banking_max_deg: float, is_closed_loop: bool) -> void:
	_current_spline_points.clear()
	_current_spline_tangents.clear()
	_current_spline_rights.clear()
	_current_spline_ups.clear()
	_min_track_elevation = 99999.0

	var pts: Array[Vector3] = []
	for cp in control_points:
		if cp is Vector3:
			pts.append(cp)

	if pts.size() < 2:
		pts = [Vector3(0, 0, 0), Vector3(0, 0, -100), Vector3(50, 0, -200)]

	var count: int = pts.size()
	var seg_limit: int = count if is_closed_loop else count - 1

	for i in range(seg_limit):
		var p0: Vector3 = pts[(i - 1 + count) % count] if is_closed_loop else pts[max(i - 1, 0)]
		var p1: Vector3 = pts[i]
		var p2: Vector3 = pts[(i + 1) % count]
		var p3: Vector3 = pts[(i + 2) % count] if is_closed_loop else pts[min(i + 2, count - 1)]

		for s in range(SPLINE_SUBDIVISIONS_PER_SEGMENT):
			var t: float = float(s) / float(SPLINE_SUBDIVISIONS_PER_SEGMENT)
			var pos: Vector3 = _catmull_rom(p0, p1, p2, p3, t)
			_current_spline_points.append(pos)
			if pos.y < _min_track_elevation:
				_min_track_elevation = pos.y

	if not is_closed_loop:
		var last_p: Vector3 = pts[count - 1]
		_current_spline_points.append(last_p)
		if last_p.y < _min_track_elevation:
			_min_track_elevation = last_p.y

	var n_pts: int = _current_spline_points.size()
	for i in range(n_pts):
		var prev_idx: int = (i - 1 + n_pts) % n_pts if is_closed_loop else max(i - 1, 0)
		var next_idx: int = (i + 1) % n_pts if is_closed_loop else min(i + 1, n_pts - 1)

		var tangent: Vector3 = (_current_spline_points[next_idx] - _current_spline_points[prev_idx]).normalized()
		if tangent.length_squared() < 0.001:
			tangent = Vector3.FORWARD

		var flat_right: Vector3 = tangent.cross(Vector3.UP).normalized()
		if flat_right.length_squared() < 0.001:
			flat_right = Vector3.RIGHT

		# Compute curvature for subtle corner camber/banking
		var prev_tan: Vector3 = (_current_spline_points[i] - _current_spline_points[prev_idx]).normalized()
		var next_tan: Vector3 = (_current_spline_points[next_idx] - _current_spline_points[i]).normalized()
		var curvature: float = clampf(prev_tan.cross(next_tan).y * 4.5, -1.0, 1.0)
		var bank_rad: float = deg_to_rad(banking_max_deg) * curvature

		var banked_right: Vector3 = flat_right.rotated(tangent, bank_rad).normalized()
		var banked_up: Vector3 = banked_right.cross(tangent).normalized()

		_current_spline_tangents.append(tangent)
		_current_spline_rights.append(banked_right)
		_current_spline_ups.append(banked_up)


func _catmull_rom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * (
		(2.0 * p1) +
		(-p0 + p2) * t +
		(2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
		(-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)


# ==============================================================================
# THICKENED ROAD DECK (0.6m EXTRUSION) + 8.0m SAFETY APRONS + BOX COLLIDERS
# ==============================================================================
func _build_road_mesh_and_collision(
	road_width: float,
	is_closed_loop: bool,
	track_id: String,
	_track_data: Dictionary
) -> void:
	var n_pts: int = _current_spline_points.size()
	if n_pts < 2:
		return

	var half_w: float = road_width * 0.5
	var total_col_half_w: float = half_w + SAFETY_APRON_WIDTH
	var seg_count: int = n_pts if is_closed_loop else n_pts - 1

	var st_road := SurfaceTool.new()
	st_road.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_markings := SurfaceTool.new()
	st_markings.begin(Mesh.PRIMITIVE_TRIANGLES)

	var col_faces := PackedVector3Array()

	var road_static_body := StaticBody3D.new()
	road_static_body.name = "ThickenedRoadDeckStaticBody"
	road_static_body.collision_layer = 1
	road_static_body.collision_mask = 1

	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = 1.0
	phys_mat.rough = true
	road_static_body.physics_material_override = phys_mat
	_active_track_root.add_child(road_static_body)

	var running_dist: float = 0.0

	for i in range(seg_count):
		var next_i: int = (i + 1) % n_pts
		var p0: Vector3 = _current_spline_points[i]
		var p1: Vector3 = _current_spline_points[next_i]
		var r0: Vector3 = _current_spline_rights[i]
		var r1: Vector3 = _current_spline_rights[next_i]
		var u0: Vector3 = _current_spline_ups[i]
		var u1: Vector3 = _current_spline_ups[next_i]

		var seg_len: float = p0.distance_to(p1)
		var next_dist: float = running_dist + seg_len

		# Visual Road Top Vertices (+ extruded 0.6m road deck edge walls)
		var v0_l: Vector3 = p0 - r0 * half_w
		var v0_r: Vector3 = p0 + r0 * half_w
		var v1_l: Vector3 = p1 - r1 * half_w
		var v1_r: Vector3 = p1 + r1 * half_w

		var v0_l_bot: Vector3 = v0_l - u0 * EXTRUDED_DECK_THICKNESS
		var v0_r_bot: Vector3 = v0_r - u0 * EXTRUDED_DECK_THICKNESS
		var v1_l_bot: Vector3 = v1_l - u1 * EXTRUDED_DECK_THICKNESS
		var v1_r_bot: Vector3 = v1_r - u1 * EXTRUDED_DECK_THICKNESS

		var uv_y0: float = running_dist * 0.1
		var uv_y1: float = next_dist * 0.1

		# Top Asphalt Triangles
		_add_quad_to_surface_tool(st_road, v0_l, v0_r, v1_r, v1_l, u0, u1, uv_y0, uv_y1)
		# Left & Right 0.6m Extruded Structural Curb/Deck Side Walls
		_add_quad_to_surface_tool(st_road, v0_l_bot, v0_l, v1_l, v1_l_bot, -r0, -r1, uv_y0, uv_y1)
		_add_quad_to_surface_tool(st_road, v0_r, v0_r_bot, v1_r_bot, v1_r, r0, r1, uv_y0, uv_y1)
		# Bottom Deck Visual Underside (prevents seeing through road from below)
		_add_quad_to_surface_tool(st_road, v0_r_bot, v0_l_bot, v1_l_bot, v1_r_bot, -u0, -u1, uv_y0, uv_y1)

		# Center & Edge Lane Markings
		var line_offset: Vector3 = u0 * 0.018
		var edge_w: float = 0.18
		# Left white fog line
		_add_quad_to_surface_tool(
			st_markings,
			p0 - r0 * (half_w - 0.35) + line_offset,
			p0 - r0 * (half_w - 0.35 - edge_w) + line_offset,
			p1 - r1 * (half_w - 0.35 - edge_w) + u1 * 0.018,
			p1 - r1 * (half_w - 0.35) + u1 * 0.018,
			u0, u1, uv_y0, uv_y1
		)
		# Right white fog line
		_add_quad_to_surface_tool(
			st_markings,
			p0 + r0 * (half_w - 0.35 - edge_w) + line_offset,
			p0 + r0 * (half_w - 0.35) + line_offset,
			p1 + r1 * (half_w - 0.35) + u1 * 0.018,
			p1 + r1 * (half_w - 0.35 - edge_w) + u1 * 0.018,
			u0, u1, uv_y0, uv_y1
		)
		# Center dashed line (on touge roads) or start/finish stripes
		if track_id != "tsukuba_circuit" and (i % 3 != 0):
			_add_quad_to_surface_tool(
				st_markings,
				p0 - r0 * 0.10 + line_offset,
				p0 + r0 * 0.10 + line_offset,
				p1 + r1 * 0.10 + u1 * 0.018,
				p1 - r1 * 0.10 + u1 * 0.018,
				u0, u1, uv_y0, uv_y1
			)

		# ======================================================================
		# THICKENED COLLISION DECK (+8.0m SAFETY APRON ON EACH SIDE, 0.6m DEEP)
		# ======================================================================
		var c0_l_top: Vector3 = p0 - r0 * total_col_half_w
		var c0_r_top: Vector3 = p0 + r0 * total_col_half_w
		var c1_l_top: Vector3 = p1 - r1 * total_col_half_w
		var c1_r_top: Vector3 = p1 + r1 * total_col_half_w

		var c0_l_bot: Vector3 = c0_l_top - u0 * EXTRUDED_DECK_THICKNESS
		var c0_r_bot: Vector3 = c0_r_top - u0 * EXTRUDED_DECK_THICKNESS
		var c1_l_bot: Vector3 = c1_l_top - u1 * EXTRUDED_DECK_THICKNESS
		var c1_r_bot: Vector3 = c1_r_top - u1 * EXTRUDED_DECK_THICKNESS

		# 1. Double-sided Top Deck Faces (Road + 8m Left/Right Safety Aprons)
		_append_double_sided_quad_collider(col_faces, c0_l_top, c0_r_top, c1_r_top, c1_l_top)
		# 2. Double-sided Bottom Extruded Deck Faces (-0.6m depth)
		_append_double_sided_quad_collider(col_faces, c0_r_bot, c0_l_bot, c1_l_bot, c1_r_bot)
		# 3. Extruded Left & Right Vertical Skirt Faces
		_append_double_sided_quad_collider(col_faces, c0_l_bot, c0_l_top, c1_l_top, c1_l_bot)
		_append_double_sided_quad_collider(col_faces, c0_r_top, c0_r_bot, c1_r_bot, c1_r_top)
		# 4. Cross-section bulkheads at segment boundaries
		_append_double_sided_quad_collider(col_faces, c0_l_top, c0_r_top, c0_r_bot, c0_l_bot)

		# 5. Volumetric BoxShape3D Slab per segment (guarantees zero raycast/chassis
		# penetration even during first-frame physics spawn settling)
		if seg_len > 0.05:
			var mid_top: Vector3 = (p0 + p1) * 0.5
			var mid_up: Vector3 = ((u0 + u1) * 0.5).normalized()
			var seg_forward: Vector3 = (p1 - p0).normalized()
			var seg_right: Vector3 = seg_forward.cross(mid_up).normalized()
			var ortho_up: Vector3 = seg_right.cross(seg_forward).normalized()

			var box_shape := BoxShape3D.new()
			box_shape.size = Vector3(total_col_half_w * 2.0, EXTRUDED_DECK_THICKNESS, seg_len + 0.45)

			var box_col := CollisionShape3D.new()
			box_col.shape = box_shape
			var slab_basis := Basis(seg_right, ortho_up, -seg_forward)
			var slab_origin: Vector3 = mid_top - ortho_up * (EXTRUDED_DECK_THICKNESS * 0.5)
			box_col.transform = Transform3D(slab_basis, slab_origin)
			road_static_body.add_child(box_col)

		running_dist = next_dist

	# Add the thickened ConcavePolygonShape3D mesh collider
	var concave := ConcavePolygonShape3D.new()
	concave.backface_collision = true
	concave.set_faces(col_faces)

	var mesh_col := CollisionShape3D.new()
	mesh_col.name = "ThickenedRoadConcaveCollider"
	mesh_col.shape = concave
	road_static_body.add_child(mesh_col)

	# Commit Visual Road Mesh
	var road_mat := StandardMaterial3D.new()
	match track_id:
		"irohazaka_downhill":
			road_mat.albedo_color = Color(0.16, 0.15, 0.17)
			road_mat.roughness = 0.82
		"tsukuba_circuit":
			road_mat.albedo_color = Color(0.19, 0.20, 0.22)
			road_mat.roughness = 0.76
		"hakone_turnpike":
			road_mat.albedo_color = Color(0.11, 0.13, 0.15)
			road_mat.roughness = 0.52 # Damp midnight fog sheen
			road_mat.metallic = 0.15
		_:
			road_mat.albedo_color = Color(0.14, 0.15, 0.18)
			road_mat.roughness = 0.78

	var road_mesh_inst := MeshInstance3D.new()
	road_mesh_inst.name = "RoadSurfaceMesh"
	road_mesh_inst.mesh = st_road.commit()
	road_mesh_inst.material_override = road_mat
	_active_track_root.add_child(road_mesh_inst)

	# Commit Lane Markings Mesh
	var markings_mat := StandardMaterial3D.new()
	markings_mat.albedo_color = Color(0.92, 0.78, 0.22) if track_id == "irohazaka_downhill" else Color(0.90, 0.92, 0.95)
	markings_mat.roughness = 0.45
	markings_mat.emission_enabled = true
	markings_mat.emission = markings_mat.albedo_color * 0.22

	var markings_inst := MeshInstance3D.new()
	markings_inst.name = "RoadMarkingsMesh"
	markings_inst.mesh = st_markings.commit()
	markings_inst.material_override = markings_mat
	_active_track_root.add_child(markings_inst)


# ==============================================================================
# PROCEDURAL MOUNTAIN TERRAIN SKIRTS, CLIFFS & 360° HORIZON RING
# ==============================================================================
func _build_mountain_terrain_skirts(
	road_width: float,
	is_closed_loop: bool,
	track_id: String,
	_track_data: Dictionary
) -> void:
	var n_pts: int = _current_spline_points.size()
	if n_pts < 2:
		return

	var half_w: float = road_width * 0.5
	var seg_count: int = n_pts if is_closed_loop else n_pts - 1

	var st_terrain := SurfaceTool.new()
	st_terrain.begin(Mesh.PRIMITIVE_TRIANGLES)

	var is_circuit: bool = (track_id == "tsukuba_circuit")

	for i in range(seg_count):
		var next_i: int = (i + 1) % n_pts
		var p0: Vector3 = _current_spline_points[i]
		var p1: Vector3 = _current_spline_points[next_i]
		var r0: Vector3 = _current_spline_rights[i]
		var r1: Vector3 = _current_spline_rights[next_i]

		# Deterministic rock/ridge undulation along the spline
		var n0: float = sin(float(i) * 0.37) * 4.5 + cos(float(i) * 0.19) * 3.0
		var n1: float = sin(float(next_i) * 0.37) * 4.5 + cos(float(next_i) * 0.19) * 3.0

		var uv0: float = float(i) * 0.25
		var uv1: float = float(i + 1) * 0.25

		if is_circuit:
			# Tsukuba Circuit: Wide flat turf runoff + outer stadium earth berms
			var l_edge0: Vector3 = p0 - r0 * half_w + Vector3(0, -0.05, 0)
			var l_edge1: Vector3 = p1 - r1 * half_w + Vector3(0, -0.05, 0)
			var l_turf0: Vector3 = p0 - r0 * (half_w + 18.0) + Vector3(0, -0.15, 0)
			var l_turf1: Vector3 = p1 - r1 * (half_w + 18.0) + Vector3(0, -0.15, 0)
			var l_berm0: Vector3 = p0 - r0 * (half_w + 48.0) + Vector3(0, 8.5 + n0 * 0.3, 0)
			var l_berm1: Vector3 = p1 - r1 * (half_w + 48.0) + Vector3(0, 8.5 + n1 * 0.3, 0)
			var l_far0: Vector3 = p0 - r0 * (half_w + 150.0) + Vector3(0, -6.0, 0)
			var l_far1: Vector3 = p1 - r1 * (half_w + 150.0) + Vector3(0, -6.0, 0)

			_add_quad_to_surface_tool(st_terrain, l_turf0, l_edge0, l_edge1, l_turf1, Vector3.UP, Vector3.UP, uv0, uv1)
			_add_quad_to_surface_tool(st_terrain, l_berm0, l_turf0, l_turf1, l_berm1, Vector3.UP, Vector3.UP, uv0, uv1)
			_add_quad_to_surface_tool(st_terrain, l_far0, l_berm0, l_berm1, l_far1, Vector3.UP, Vector3.UP, uv0, uv1)

			var r_edge0: Vector3 = p0 + r0 * half_w + Vector3(0, -0.05, 0)
			var r_edge1: Vector3 = p1 + r1 * half_w + Vector3(0, -0.05, 0)
			var r_turf0: Vector3 = p0 + r0 * (half_w + 18.0) + Vector3(0, -0.15, 0)
			var r_turf1: Vector3 = p1 + r1 * (half_w + 18.0) + Vector3(0, -0.15, 0)
			var r_berm0: Vector3 = p0 + r0 * (half_w + 48.0) + Vector3(0, 7.0 - n0 * 0.25, 0)
			var r_berm1: Vector3 = p1 + r1 * (half_w + 48.0) + Vector3(0, 7.0 - n1 * 0.25, 0)
			var r_far0: Vector3 = p0 + r0 * (half_w + 150.0) + Vector3(0, -6.0, 0)
			var r_far1: Vector3 = p1 + r1 * (half_w + 150.0) + Vector3(0, -6.0, 0)

			_add_quad_to_surface_tool(st_terrain, r_edge0, r_turf0, r_turf1, r_edge1, Vector3.UP, Vector3.UP, uv0, uv1)
			_add_quad_to_surface_tool(st_terrain, r_turf0, r_berm0, r_berm1, r_turf1, Vector3.UP, Vector3.UP, uv0, uv1)
			_add_quad_to_surface_tool(st_terrain, r_berm0, r_far0, r_far1, r_berm1, Vector3.UP, Vector3.UP, uv0, uv1)
		else:
			# Mountain Pass Skirts: Left side rises into steep mountain cliffs,
			# Right side drops into a deep forested valley slope
			var l_sh0: Vector3 = p0 - r0 * half_w + Vector3(0, -0.08, 0)
			var l_sh1: Vector3 = p1 - r1 * half_w + Vector3(0, -0.08, 0)
			var l_apron0: Vector3 = p0 - r0 * (half_w + SAFETY_APRON_WIDTH) + Vector3(0, -0.15, 0)
			var l_apron1: Vector3 = p1 - r1 * (half_w + SAFETY_APRON_WIDTH) + Vector3(0, -0.15, 0)
			var l_cliff_mid0: Vector3 = p0 - r0 * (half_w + 16.0) + Vector3(0, 14.0 + n0 * 0.7, 0)
			var l_cliff_mid1: Vector3 = p1 - r1 * (half_w + 16.0) + Vector3(0, 14.0 + n1 * 0.7, 0)
			var l_cliff_top0: Vector3 = p0 - r0 * (half_w + 38.0) + Vector3(0, 34.0 + n0 * 1.4, 0)
			var l_cliff_top1: Vector3 = p1 - r1 * (half_w + 38.0) + Vector3(0, 34.0 + n1 * 1.4, 0)
			var l_outer_base0: Vector3 = p0 - r0 * (half_w + 135.0) + Vector3(0, -58.0, 0)
			var l_outer_base1: Vector3 = p1 - r1 * (half_w + 135.0) + Vector3(0, -58.0, 0)

			var n_cliff0: Vector3 = (r0 + Vector3.UP * 0.65).normalized()
			var n_cliff1: Vector3 = (r1 + Vector3.UP * 0.65).normalized()

			_add_quad_to_surface_tool(st_terrain, l_apron0, l_sh0, l_sh1, l_apron1, Vector3.UP, Vector3.UP, uv0, uv1)
			_add_quad_to_surface_tool(st_terrain, l_cliff_mid0, l_apron0, l_apron1, l_cliff_mid1, n_cliff0, n_cliff1, uv0, uv1)
			_add_quad_to_surface_tool(st_terrain, l_cliff_top0, l_cliff_mid0, l_cliff_mid1, l_cliff_top1, n_cliff0, n_cliff1, uv0, uv1)
			_add_quad_to_surface_tool(st_terrain, l_outer_base0, l_cliff_top0, l_cliff_top1, l_outer_base1, Vector3.UP, Vector3.UP, uv0, uv1)

			# Right side: Safety shoulder + descending mountain valley skirt
			var r_sh0: Vector3 = p0 + r0 * half_w + Vector3(0, -0.08, 0)
			var r_sh1: Vector3 = p1 + r1 * half_w + Vector3(0, -0.08, 0)
			var r_apron0: Vector3 = p0 + r0 * (half_w + SAFETY_APRON_WIDTH) + Vector3(0, -0.22, 0)
			var r_apron1: Vector3 = p1 + r1 * (half_w + SAFETY_APRON_WIDTH) + Vector3(0, -0.22, 0)
			var r_slope0: Vector3 = p0 + r0 * (half_w + 36.0) + Vector3(0, -22.0 + n0 * 0.6, 0)
			var r_slope1: Vector3 = p1 + r1 * (half_w + 36.0) + Vector3(0, -22.0 + n1 * 0.6, 0)
			var r_valley0: Vector3 = p0 + r0 * (half_w + 145.0) + Vector3(0, -72.0, 0)
			var r_valley1: Vector3 = p1 + r1 * (half_w + 145.0) + Vector3(0, -72.0, 0)

			var n_slope0: Vector3 = (r0 * 0.55 + Vector3.UP).normalized()
			var n_slope1: Vector3 = (r1 * 0.55 + Vector3.UP).normalized()

			_add_quad_to_surface_tool(st_terrain, r_sh0, r_apron0, r_apron1, r_sh1, Vector3.UP, Vector3.UP, uv0, uv1)
			_add_quad_to_surface_tool(st_terrain, r_apron0, r_slope0, r_slope1, r_apron1, n_slope0, n_slope1, uv0, uv1)
			_add_quad_to_surface_tool(st_terrain, r_slope0, r_valley0, r_valley1, r_slope1, n_slope0, n_slope1, uv0, uv1)

	var terrain_mat := StandardMaterial3D.new()
	terrain_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	terrain_mat.roughness = 0.94

	match track_id:
		"irohazaka_downhill":
			terrain_mat.albedo_color = Color(0.28, 0.14, 0.08) # Warm autumn mountain earth & maple slopes
		"tsukuba_circuit":
			terrain_mat.albedo_color = Color(0.16, 0.34, 0.14) # Lush circuit infield grass
		"hakone_turnpike":
			terrain_mat.albedo_color = Color(0.08, 0.14, 0.11) # Dark volcanic cedar & moss
		_:
			terrain_mat.albedo_color = Color(0.09, 0.12, 0.16) # Midnight Mount Akina slate & pine

	var terrain_mesh_inst := MeshInstance3D.new()
	terrain_mesh_inst.name = "MountainTerrainSkirtMesh"
	terrain_mesh_inst.mesh = st_terrain.commit()
	terrain_mesh_inst.material_override = terrain_mat
	_active_track_root.add_child(terrain_mesh_inst)

	# Build a continuous valley basin floor & 360-degree distant mountain silhouette ring
	_build_distant_horizon_mountain_ring(track_id, terrain_mat)


func _build_distant_horizon_mountain_ring(track_id: String, base_terrain_mat: StandardMaterial3D) -> void:
	# Compute center of current spline
	var center := Vector3.ZERO
	for pt in _current_spline_points:
		center += pt
	if not _current_spline_points.is_empty():
		center /= float(_current_spline_points.size())

	var floor_y: float = _min_track_elevation - 48.0

	# 1. Vast Valley Floor Basin Mesh (eliminates any black void below the mountain pass)
	var basin_plane := PlaneMesh.new()
	basin_plane.size = Vector2(5200.0, 5200.0)
	var basin_inst := MeshInstance3D.new()
	basin_inst.name = "ValleyBasinFloorMesh"
	basin_inst.mesh = basin_plane
	basin_inst.position = Vector3(center.x, floor_y, center.z)
	basin_inst.material_override = base_terrain_mat
	_active_track_root.add_child(basin_inst)

	# 2. 360-Degree Distant Mountain Range Silhouette
	var st_ring := SurfaceTool.new()
	st_ring.begin(Mesh.PRIMITIVE_TRIANGLES)

	var ring_segments: int = 64
	var inner_radius: float = 1350.0
	var peak_radius: float = 1950.0
	var outer_radius: float = 2500.0
	var peak_scale: float = 45.0 if track_id == "tsukuba_circuit" else 240.0

	for i in range(ring_segments):
		var a0: float = (TAU * float(i)) / float(ring_segments)
		var a1: float = (TAU * float(i + 1)) / float(ring_segments)

		var h0: float = floor_y + peak_scale * (0.65 + 0.35 * sin(a0 * 5.0) * cos(a0 * 3.0))
		var h1: float = floor_y + peak_scale * (0.65 + 0.35 * sin(a1 * 5.0) * cos(a1 * 3.0))

		var b0 := Vector3(center.x + cos(a0) * inner_radius, floor_y - 10.0, center.z + sin(a0) * inner_radius)
		var b1 := Vector3(center.x + cos(a1) * inner_radius, floor_y - 10.0, center.z + sin(a1) * inner_radius)
		var p0 := Vector3(center.x + cos(a0) * peak_radius, h0, center.z + sin(a0) * peak_radius)
		var p1 := Vector3(center.x + cos(a1) * peak_radius, h1, center.z + sin(a1) * peak_radius)
		var o0 := Vector3(center.x + cos(a0) * outer_radius, floor_y - 20.0, center.z + sin(a0) * outer_radius)
		var o1 := Vector3(center.x + cos(a1) * outer_radius, floor_y - 20.0, center.z + sin(a1) * outer_radius)

		var n_in := Vector3(-cos(a0), 0.5, -sin(a0)).normalized()
		_add_quad_to_surface_tool(st_ring, b0, b1, p1, p0, n_in, n_in, 0.0, 1.0)
		_add_quad_to_surface_tool(st_ring, p0, p1, o1, o0, Vector3.UP, Vector3.UP, 0.0, 1.0)

	var ring_inst := MeshInstance3D.new()
	ring_inst.name = "DistantHorizonMountainRing"
	ring_inst.mesh = st_ring.commit()
	ring_inst.material_override = base_terrain_mat
	_active_track_root.add_child(ring_inst)


# ==============================================================================
# GUARDRAILS, CURBS & STAGE-SPECIFIC PROPS
# ==============================================================================
func _build_guardrails_and_stage_props(
	road_width: float,
	is_closed_loop: bool,
	track_id: String,
	_track_data: Dictionary
) -> void:
	var n_pts: int = _current_spline_points.size()
	if n_pts < 2:
		return

	var half_w: float = road_width * 0.5
	var rail_offset: float = half_w + 0.45
	var rail_height: float = 0.85
	var seg_count: int = n_pts if is_closed_loop else n_pts - 1

	var st_rails := SurfaceTool.new()
	st_rails.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rail_body := StaticBody3D.new()
	rail_body.name = "GuardrailStaticBody"
	_active_track_root.add_child(rail_body)

	for i in range(seg_count):
		var next_i: int = (i + 1) % n_pts
		var p0: Vector3 = _current_spline_points[i]
		var p1: Vector3 = _current_spline_points[next_i]
		var r0: Vector3 = _current_spline_rights[i]
		var r1: Vector3 = _current_spline_rights[next_i]
		var u0: Vector3 = _current_spline_ups[i]
		var u1: Vector3 = _current_spline_ups[next_i]

		var l_bot0: Vector3 = p0 - r0 * rail_offset + u0 * 0.25
		var l_top0: Vector3 = p0 - r0 * rail_offset + u0 * rail_height
		var l_bot1: Vector3 = p1 - r1 * rail_offset + u1 * 0.25
		var l_top1: Vector3 = p1 - r1 * rail_offset + u1 * rail_height

		var r_bot0: Vector3 = p0 + r0 * rail_offset + u0 * 0.25
		var r_top0: Vector3 = p0 + r0 * rail_offset + u0 * rail_height
		var r_bot1: Vector3 = p1 + r1 * rail_offset + u1 * 0.25
		var r_top1: Vector3 = p1 + r1 * rail_offset + u1 * rail_height

		_add_quad_to_surface_tool(st_rails, l_bot0, l_top0, l_top1, l_bot1, r0, r1, 0.0, 1.0)
		_add_quad_to_surface_tool(st_rails, r_top0, r_bot0, r_bot1, r_top1, -r0, -r1, 0.0, 1.0)

		# Physical guardrail wall colliders
		var seg_len: float = p0.distance_to(p1)
		if seg_len > 0.1:
			var mid: Vector3 = (p0 + p1) * 0.5
			var mid_r: Vector3 = ((r0 + r1) * 0.5).normalized()
			var mid_u: Vector3 = ((u0 + u1) * 0.5).normalized()
			var fwd: Vector3 = (p1 - p0).normalized()
			var basis := Basis(mid_r, mid_u, -fwd).orthonormalized()

			for side in [-1.0, 1.0]:
				var wall_shape := BoxShape3D.new()
				wall_shape.size = Vector3(0.35, 1.15, seg_len + 0.15)
				var wall_col := CollisionShape3D.new()
				wall_col.shape = wall_shape
				wall_col.transform = Transform3D(basis, mid + mid_r * (side * (rail_offset + 0.15)) + mid_u * 0.55)
				rail_body.add_child(wall_col)

		# Stage-specific roadside lamps / trees / reflectors every 8 spline steps
		if i % 8 == 0:
			_spawn_roadside_feature(p0, r0, u0, half_w, track_id, i)

	var rail_mat := StandardMaterial3D.new()
	rail_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	rail_mat.albedo_color = Color(0.76, 0.79, 0.84) if track_id != "irohazaka_downhill" else Color(0.62, 0.34, 0.20)
	rail_mat.metallic = 0.65
	rail_mat.roughness = 0.38

	var rail_inst := MeshInstance3D.new()
	rail_inst.name = "GuardrailsMesh"
	rail_inst.mesh = st_rails.commit()
	rail_inst.material_override = rail_mat
	_active_track_root.add_child(rail_inst)


func _spawn_roadside_feature(pos: Vector3, right: Vector3, up: Vector3, half_w: float, track_id: String, idx: int) -> void:
	match track_id:
		"akina_downhill", "hakone_turnpike":
			# Golden sodium streetlamp or misty turnpike beacon
			var pole := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.08
			cyl.bottom_radius = 0.11
			cyl.height = 5.5
			pole.mesh = cyl
			pole.position = pos - right * (half_w + 1.2) + up * 2.75
			_active_track_root.add_child(pole)

			if idx % 16 == 0:
				var lamp := OmniLight3D.new()
				lamp.light_color = Color(1.0, 0.72, 0.32) if track_id == "akina_downhill" else Color(0.85, 0.92, 1.0)
				lamp.light_energy = 2.4
				lamp.omni_range = 26.0
				lamp.shadow_enabled = false
				lamp.position = pos - right * (half_w - 0.5) + up * 5.2
				_active_track_root.add_child(lamp)

		"irohazaka_downhill":
			# Stylized Crimson/Gold Autumn Maple Tree
			var tree_root := Node3D.new()
			var side_sign: float = -1.0 if (idx % 16 == 0) else 1.0
			tree_root.position = pos + right * (side_sign * (half_w + 4.2))

			var trunk := MeshInstance3D.new()
			var t_mesh := CylinderMesh.new()
			t_mesh.top_radius = 0.18
			t_mesh.bottom_radius = 0.28
			t_mesh.height = 3.6
			trunk.mesh = t_mesh
			trunk.position = Vector3(0, 1.8, 0)
			tree_root.add_child(trunk)

			var canopy := MeshInstance3D.new()
			var c_mesh := SphereMesh.new()
			c_mesh.radius = 2.6
			c_mesh.height = 4.2
			canopy.mesh = c_mesh
			canopy.position = Vector3(0, 4.6, 0)
			var leaf_mat := StandardMaterial3D.new()
			leaf_mat.albedo_color = Color(0.88, 0.22, 0.08) if (idx % 24 == 0) else Color(0.95, 0.55, 0.10)
			leaf_mat.roughness = 0.85
			canopy.material_override = leaf_mat
			tree_root.add_child(canopy)
			_active_track_root.add_child(tree_root)


# ==============================================================================
# GLOBAL SAFETY CATCH-PLANE / KILL-PLANE AT Y = -50.0
# ==============================================================================
func _build_global_safety_catch_plane(min_track_y: float) -> void:
	_safety_plane_root = Node3D.new()
	_safety_plane_root.name = "GlobalSafetyCatchPlane"
	add_child(_safety_plane_root)

	var catch_y: float = minf(GLOBAL_KILL_PLANE_Y, min_track_y - 35.0)

	# 1. Area3D detector at Y = -50.0 (and relative catch_y) that immediately respawns falling vehicles
	for plane_y in [GLOBAL_KILL_PLANE_Y, catch_y]:
		var catch_area := Area3D.new()
		catch_area.position = Vector3(0.0, plane_y, 0.0)
		catch_area.collision_layer = 0
		catch_area.collision_mask = 0xFFFFFFFF

		var area_shape := BoxShape3D.new()
		area_shape.size = Vector3(12000.0, 6.0, 12000.0)
		var area_col := CollisionShape3D.new()
		area_col.shape = area_shape
		catch_area.add_child(area_col)

		catch_area.body_entered.connect(_on_safety_catch_plane_body_entered)
		_safety_plane_root.add_child(catch_area)

	# 2. Solid StaticBody3D floor just underneath the catch Area3D so nothing can ever fall infinitely
	var backup_floor := StaticBody3D.new()
	backup_floor.position = Vector3(0.0, catch_y - 2.0, 0.0)
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(12000.0, 4.0, 12000.0)
	var floor_col := CollisionShape3D.new()
	floor_col.shape = floor_shape
	backup_floor.add_child(floor_col)
	_safety_plane_root.add_child(backup_floor)


func _on_safety_catch_plane_body_entered(body: Node3D) -> void:
	if body is RigidBody3D:
		respawn_vehicle_at_summit(body as RigidBody3D, _tracked_camera)


# ==============================================================================
# SPAWN TRANSFORM CALCULATION & SURFACE TOOL HELPERS
# ==============================================================================
func _compute_summit_spawn_transform() -> Transform3D:
	if _current_spline_points.size() < 2:
		return Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, 0.0))

	var p0: Vector3 = _current_spline_points[0]
	var p1: Vector3 = _current_spline_points[1]
	var fwd: Vector3 = (p1 - p0).normalized()
	var up: Vector3 = _current_spline_ups[0].normalized()
	var right: Vector3 = fwd.cross(up).normalized()
	var ortho_up: Vector3 = right.cross(fwd).normalized()

	var spawn_basis := Basis(right, ortho_up, -fwd).orthonormalized()
	var spawn_pos: Vector3 = p0 + fwd * 4.0 + ortho_up * 0.85
	return Transform3D(spawn_basis, spawn_pos)


func _resolve_akina_default_spawn(track_data: Dictionary) -> Transform3D:
	if is_instance_valid(_parent_scene) and _parent_scene.has_method("get_summit_spawn_transform"):
		return _parent_scene.call("get_summit_spawn_transform")

	var cps: Array = track_data.get("control_points", [])
	if cps.size() >= 2 and cps[0] is Vector3 and cps[1] is Vector3:
		var p0: Vector3 = cps[0]
		var p1: Vector3 = cps[1]
		var fwd: Vector3 = (p1 - p0).normalized()
		var right: Vector3 = fwd.cross(Vector3.UP).normalized()
		var up: Vector3 = right.cross(fwd).normalized()
		return Transform3D(Basis(right, up, -fwd).orthonormalized(), p0 + Vector3(0.0, 0.85, 0.0))

	return Transform3D(Basis.IDENTITY, Vector3(0.0, 1.2, 0.0))


func _add_quad_to_surface_tool(
	st: SurfaceTool,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	n0: Vector3,
	n1: Vector3,
	uv_y0: float,
	uv_y1: float
) -> void:
	st.set_normal(n0)
	st.set_uv(Vector2(0.0, uv_y0))
	st.add_vertex(v0)

	st.set_normal(n0)
	st.set_uv(Vector2(1.0, uv_y0))
	st.add_vertex(v1)

	st.set_normal(n1)
	st.set_uv(Vector2(1.0, uv_y1))
	st.add_vertex(v2)

	st.set_normal(n0)
	st.set_uv(Vector2(0.0, uv_y0))
	st.add_vertex(v0)

	st.set_normal(n1)
	st.set_uv(Vector2(1.0, uv_y1))
	st.add_vertex(v2)

	st.set_normal(n1)
	st.set_uv(Vector2(0.0, uv_y1))
	st.add_vertex(v3)


func _append_double_sided_quad_collider(
	faces: PackedVector3Array,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3
) -> void:
	# Front winding
	faces.append(v0)
	faces.append(v1)
	faces.append(v2)
	faces.append(v0)
	faces.append(v2)
	faces.append(v3)
	# Back winding (prevents one-way raycast tunneling)
	faces.append(v2)
	faces.append(v1)
	faces.append(v0)
	faces.append(v3)
	faces.append(v2)
	faces.append(v0)
# Backwards compatibility alias
func load_track_environment(track_id: String, track_data: Dictionary, vehicle: RigidBody3D = null, chase_camera: Camera3D = null) -> Transform3D:
	return build_track_environment(track_id, track_data, vehicle, chase_camera)
