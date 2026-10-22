# ==============================================================================
# File: res://TougeMultiEnvironmentManager.gd
# Engine: Godot Engine 4.3 (Headless / Desktop CI Compatible)
# Architecture: Self-Contained Multi-Track Procedural Environment & Road Manager
# ==============================================================================
class_name TougeMultiEnvironmentManager
extends Node3D

signal environment_loaded(track_id: String, biome_type: int)
signal environment_cleared()

enum Biome {
	AKINA = 0,     # Mount Akina Downhill (Midnight Gunma Pass)
	IROHAZAKA = 1, # Irohazaka Slope (Autumn Sunset Switchbacks)
	TSUKUBA = 2    # Tsukuba Circuit (Daytime Official Race Course)
}

const ENV_CONTAINER_NAME: StringName = &"TougeActiveEnvironment"
const META_GENERATED_TAG: StringName = &"touge_generated_env"
const META_CUSTOM_CURVE: StringName = &"touge_custom_curve"

@export var default_track_id: String = "akina"
@export_range(1.5, 8.0, 0.5) var road_step_length: float = 3.0
@export var enable_dynamic_lights: bool = true
@export var purge_legacy_root_scenery: bool = true

var _env_container: Node3D = null
var _last_target_root: Node3D = null
var _active_track_id: String = ""
var _active_biome: Biome = Biome.AKINA
var _active_curve: Curve3D = null
var _spawn_transform: Transform3D = Transform3D.IDENTITY
var _custom_curve_override: Curve3D = null

# Internal road sample structure used during procedural generation
class RoadSample extends RefCounted:
	var pos: Vector3 = Vector3.ZERO
	var forward: Vector3 = Vector3.FORWARD
	var right: Vector3 = Vector3.RIGHT
	var up: Vector3 = Vector3.UP
	var banked_right: Vector3 = Vector3.RIGHT
	var banked_up: Vector3 = Vector3.UP
	var distance: float = 0.0
	var curvature: float = 0.0 # Positive = Right turn, Negative = Left turn
	var bank_angle: float = 0.0


# ==============================================================================
# PUBLIC LIFECYCLE API
# ==============================================================================

## Completely purges any active or leftover environment and generates the requested
## biome's skybox, lighting, procedural road, kerbs/gutters, guardrails, terrain,
## foliage, and trackside structures.
func load_environment(track_id: String, target_scene_root: Node3D, vehicle: RigidBody3D = null) -> void:
	clear_current_environment()

	var host_root: Node3D = target_scene_root if is_instance_valid(target_scene_root) else self
	_last_target_root = host_root
	_active_track_id = track_id.strip_edges().to_lower()
	_active_biome = _resolve_biome(_active_track_id)

	if purge_legacy_root_scenery and is_instance_valid(host_root):
		_purge_legacy_scenery_nodes(host_root, vehicle)

	# Create clean isolated container for all generated nodes
	_env_container = Node3D.new()
	_env_container.name = ENV_CONTAINER_NAME
	_env_container.set_meta(META_GENERATED_TAG, true)
	host_root.add_child(_env_container)

	# 1. Resolve or generate the 3D spline for the selected track
	var is_closed_loop: bool = (_active_biome == Biome.TSUKUBA)
	_active_curve = _resolve_track_curve(host_root, _active_biome)

	# 2. Sample the curve with curvature and camber/banking calculations
	var samples: Array[RoadSample] = _sample_curve(_active_curve, road_step_length, is_closed_loop, _active_biome)

	# Compute spawn transform at the start of the track
	if samples.size() >= 2:
		var s0: RoadSample = samples[0]
		var spawn_pos: Vector3 = s0.pos + s0.banked_up * 1.5
		var look_target: Vector3 = s0.pos + s0.forward * 10.0 + s0.banked_up * 1.5
		_spawn_transform = Transform3D(Basis.looking_at(look_target - spawn_pos, s0.banked_up), spawn_pos)
	else:
		_spawn_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))

	# 3. Configure WorldEnvironment & DirectionalLight3D for the biome
	_build_atmosphere_and_lighting(_env_container, host_root, _active_biome)

	# 4. Generate contiguous road, gutters/kerbs, markings, and guardrail collisions
	_build_road_and_barriers(_env_container, samples, _active_biome, is_closed_loop)

	# 5. Generate non-obstructing procedural terrain, cliffs, and backdrop vista
	_build_terrain_and_vista(_env_container, samples, _active_biome, is_closed_loop)

	# 6. Scatter biome-specific foliage and construct trackside infrastructure
	match _active_biome:
		Biome.AKINA:
			_populate_akina_scenery(_env_container, samples)
		Biome.IROHAZAKA:
			_populate_irohazaka_scenery(_env_container, samples)
		Biome.TSUKUBA:
			_populate_tsukuba_scenery(_env_container, samples)

	# 7. Reposition vehicle safely at the starting line if provided
	if is_instance_valid(vehicle):
		_place_vehicle_at_spawn(vehicle, _spawn_transform)

	environment_loaded.emit(_active_track_id, int(_active_biome))


## Completely removes and frees all previously generated meshes, trees, lights,
## and physics collision bodies so there is zero overlap or memory leak.
func clear_current_environment() -> void:
	if is_instance_valid(_env_container):
		var parent: Node = _env_container.get_parent()
		if is_instance_valid(parent):
			parent.remove_child(_env_container)
		_env_container.free()
	_env_container = null

	if is_instance_valid(_last_target_root):
		var stray_nodes: Array[Node] = []
		for child in _last_target_root.get_children():
			if child != self and (child.name == ENV_CONTAINER_NAME or child.has_meta(META_GENERATED_TAG)):
				stray_nodes.append(child)
		for stray in stray_nodes:
			_last_target_root.remove_child(stray)
			stray.free()

	_active_curve = null
	environment_cleared.emit()


## Optional override to supply an explicit Curve3D before calling load_environment().
func set_custom_curve(curve: Curve3D) -> void:
	_custom_curve_override = curve


func get_spawn_transform() -> Transform3D:
	return _spawn_transform


func get_active_curve() -> Curve3D:
	return _active_curve


func get_active_biome() -> Biome:
	return _active_biome


func _exit_tree() -> void:
	clear_current_environment()


# ==============================================================================
# BIOME RESOLUTION & LEGACY CLEANUP
# ==============================================================================

func _resolve_biome(track_id: String) -> Biome:
	if track_id.contains("iroha") or track_id.contains(" autumn") or track_id == "1" or track_id == "track_2":
		return Biome.IROHAZAKA
	if track_id.contains("tsukuba") or track_id.contains("circuit") or track_id == "2" or track_id == "track_3":
		return Biome.TSUKUBA
	return Biome.AKINA


func _purge_legacy_scenery_nodes(root: Node3D, vehicle: RigidBody3D) -> void:
	var legacy_keywords: PackedStringArray = PackedStringArray([
		"akina", "mountain", "terrain", "tree", "foliage", "forest",
		"scenery", "guardrail", "street_light", "streetlight", "road_mesh",
		"track_mesh", "cliff", "grandstand", "environment_old", "sky"
	])
	var to_remove: Array[Node] = []
	for child in root.get_children():
		if child == self or child == vehicle or child == _env_container:
			continue
		if child is Camera3D or child is CanvasLayer or child is Control or child is AudioStreamPlayer:
			continue
		if is_instance_valid(vehicle) and child.is_ancestor_of(vehicle):
			continue

		var cname: String = child.name.to_lower()
		var should_purge: bool = child.has_meta(META_GENERATED_TAG) or child.name == ENV_CONTAINER_NAME
		if not should_purge:
			for kw in legacy_keywords:
				if cname.contains(kw):
					should_purge = true
					break
		if should_purge:
			to_remove.append(child)

	for node in to_remove:
		root.remove_child(node)
		node.free()


func _place_vehicle_at_spawn(vehicle: RigidBody3D, spawn_xform: Transform3D) -> void:
	PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, spawn_xform)
	PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	vehicle.global_transform = spawn_xform
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle.sleeping = false


# ==============================================================================
# TRACK CURVE RESOLUTION & CANONICAL SPLINE BUILDERS
# ==============================================================================

func _resolve_track_curve(host_root: Node3D, biome: Biome) -> Curve3D:
	if is_instance_valid(_custom_curve_override) and _custom_curve_override.point_count >= 2:
		return _custom_curve_override

	if is_instance_valid(host_root):
		if host_root.has_meta(META_CUSTOM_CURVE):
			var meta_curve: Variant = host_root.get_meta(META_CUSTOM_CURVE)
			if meta_curve is Curve3D and (meta_curve as Curve3D).point_count >= 2:
				return meta_curve
		for child in host_root.get_children():
			if child is Path3D and child.has_meta(META_CUSTOM_CURVE):
				var p3d: Path3D = child as Path3D
				if is_instance_valid(p3d.curve) and p3d.curve.point_count >= 2:
					return p3d.curve

	match biome:
		Biome.AKINA:
			return _build_akina_curve()
		Biome.IROHAZAKA:
			return _build_irohazaka_curve()
		Biome.TSUKUBA:
			return _build_tsukuba_curve()
	return _build_akina_curve()


## Mount Akina Downhill: High-speed entry S-curves followed by the iconic 5 Hairpins
func _build_akina_curve() -> Curve3D:
	var pts: PackedVector3Array = PackedVector3Array([
		Vector3(0.0, 128.0, 0.0),
		Vector3(0.0, 124.0, -75.0),
		Vector3(42.0, 118.0, -155.0),
		Vector3(-25.0, 111.0, -240.0),
		Vector3(-75.0, 103.0, -320.0),
		Vector3(-20.0, 95.0, -405.0),
		# Hairpin 1 (Right-hander)
		Vector3(85.0, 86.0, -445.0),
		Vector3(115.0, 79.0, -490.0),
		Vector3(75.0, 73.0, -525.0),
		# Straight into Hairpin 2 (Left-hander)
		Vector3(-60.0, 64.0, -555.0),
		Vector3(-95.0, 57.0, -598.0),
		Vector3(-55.0, 51.0, -635.0),
		# Straight into Hairpin 3 (Right-hander)
		Vector3(80.0, 43.0, -665.0),
		Vector3(112.0, 36.0, -708.0),
		Vector3(70.0, 30.0, -745.0),
		# Straight into Hairpin 4 (Left-hander)
		Vector3(-55.0, 23.0, -775.0),
		Vector3(-88.0, 17.0, -818.0),
		Vector3(-48.0, 12.0, -855.0),
		# Final Hairpin 5 & Finish Straight
		Vector3(65.0, 7.0, -890.0),
		Vector3(92.0, 3.5, -940.0),
		Vector3(35.0, 1.0, -1005.0),
		Vector3(-60.0, 0.0, -1080.0)
	])
	return _create_catmull_rom_curve(pts, false, 0.34)


## Irohazaka Slope: Steep mountain gorge with dramatic stacked switchbacks
func _build_irohazaka_curve() -> Curve3D:
	var pts: PackedVector3Array = PackedVector3Array([
		Vector3(0.0, 165.0, 0.0),
		Vector3(0.0, 156.0, -80.0),
		# Switchback 1
		Vector3(95.0, 145.0, -140.0),
		Vector3(132.0, 136.0, -182.0),
		Vector3(88.0, 127.0, -218.0),
		# Switchback 2
		Vector3(-85.0, 114.0, -252.0),
		Vector3(-125.0, 105.0, -294.0),
		Vector3(-80.0, 96.0, -330.0),
		# Switchback 3
		Vector3(92.0, 83.0, -365.0),
		Vector3(130.0, 74.0, -408.0),
		Vector3(84.0, 65.0, -445.0),
		# Switchback 4
		Vector3(-80.0, 52.0, -480.0),
		Vector3(-120.0, 43.0, -522.0),
		Vector3(-75.0, 35.0, -560.0),
		# Switchback 5 & Canyon Exit
		Vector3(75.0, 22.0, -600.0),
		Vector3(110.0, 14.0, -645.0),
		Vector3(55.0, 6.0, -700.0),
		Vector3(-50.0, 0.0, -765.0)
	])
	return _create_catmull_rom_curve(pts, false, 0.32)


## Tsukuba Circuit (Course 2000): Flat closed-loop race course
func _build_tsukuba_curve() -> Curve3D:
	var pts: PackedVector3Array = PackedVector3Array([
		# Main Pit Straight
		Vector3(0.0, 0.0, 90.0),
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.0, 0.0, -120.0),
		# Turn 1 (Right Hairpin)
		Vector3(24.0, 0.0, -185.0),
		Vector3(72.0, 0.0, -192.0),
		Vector3(95.0, 0.0, -145.0),
		# S-Curve into First Hairpin
		Vector3(88.0, 0.0, -75.0),
		Vector3(112.0, 0.0, -15.0),
		# First Hairpin (Left-hander)
		Vector3(155.0, 0.0, 22.0),
		Vector3(195.0, 0.0, -12.0),
		# Dunlop Corner (Sweeping Right under Dunlop Bridge)
		Vector3(192.0, 0.0, -90.0),
		Vector3(225.0, 0.0, -165.0),
		Vector3(290.0, 0.0, -210.0),
		# Second Hairpin (Tight Right-hander onto Back Straight)
		Vector3(350.0, 0.0, -195.0),
		Vector3(365.0, 0.0, -135.0),
		Vector3(315.0, 0.0, -65.0),
		# Back Straight
		Vector3(235.0, 0.0, 35.0),
		Vector3(155.0, 0.0, 140.0),
		# Final Sweeper (Long Fast Right-hander back to Pit Straight)
		Vector3(95.0, 0.0, 205.0),
		Vector3(28.0, 0.0, 188.0)
	])
	return _create_catmull_rom_curve(pts, true, 0.35)


func _create_catmull_rom_curve(pts: PackedVector3Array, closed: bool, tension: float) -> Curve3D:
	var curve: Curve3D = Curve3D.new()
	curve.bake_interval = 2.0
	var count: int = pts.size()
	for i in range(count):
		var p_prev: Vector3
		var p_next: Vector3
		if closed:
			p_prev = pts[(i - 1 + count) % count]
			p_next = pts[(i + 1) % count]
		else:
			p_prev = pts[max(i - 1, 0)]
			p_next = pts[min(i + 1, count - 1)]

		var tangent: Vector3 = (p_next - p_prev) * tension
		curve.add_point(pts[i], -tangent * 0.5, tangent * 0.5)

	if closed and count > 0:
		var p_prev: Vector3 = pts[count - 1]
		var p_next: Vector3 = pts[1 % count]
		var tangent: Vector3 = (p_next - p_prev) * tension
		curve.add_point(pts[0], -tangent * 0.5, tangent * 0.5)

	return curve


# ==============================================================================
# CURVE SAMPLING, CURVATURE & BANKING PIPELINE
# ==============================================================================

func _sample_curve(curve: Curve3D, step: float, closed: bool, biome: Biome) -> Array[RoadSample]:
	var samples: Array[RoadSample] = []
	if not is_instance_valid(curve) or curve.point_count < 2:
		return samples

	var total_len: float = curve.get_baked_length()
	if total_len < 5.0:
		return samples

	var num_steps: int = max(int( round(total_len / step) ), 8)
	var actual_step: float = total_len / float(num_steps)
	var limit: int = num_steps if closed else (num_steps + 1)

	for i in range(limit):
		var dist: float = clampf(float(i) * actual_step, 0.0, total_len)
		var s: RoadSample = RoadSample.new()
		s.pos = curve.sample_baked(dist, true)
		s.distance = dist
		samples.append(s)

	var count: int = samples.size()
	# Compute tangents and raw horizontal curvature
	for i in range(count):
		var prev_idx: int = (i - 1 + count) % count if closed else max(i - 1, 0)
		var next_idx: int = (i + 1) % count if closed else min(i + 1, count - 1)

		var delta: Vector3 = samples[next_idx].pos - samples[prev_idx].pos
		if delta.length_squared() < 0.0001:
			delta = Vector3.FORWARD
		var forward: Vector3 = delta.normalized()
		var flat_fwd: Vector3 = Vector3(forward.x, 0.0, forward.z)
		if flat_fwd.length_squared() < 0.0001:
			flat_fwd = Vector3.FORWARD
		else:
			flat_fwd = flat_fwd.normalized()

		var right: Vector3 = flat_fwd.cross(Vector3.UP).normalized()
		var up: Vector3 = right.cross(forward).normalized()

		samples[i].forward = forward
		samples[i].right = right
		samples[i].up = up

	# Compute signed horizontal curvature (positive = turning right, negative = turning left)
	var raw_curvatures: PackedFloat32Array = PackedFloat32Array()
	raw_curvatures.resize(count)
	for i in range(count):
		var prev_idx: int = (i - 1 + count) % count if closed else max(i - 1, 0)
		var next_idx: int = (i + 1) % count if closed else min(i + 1, count - 1)
		var f_prev: Vector3 = Vector3(samples[prev_idx].forward.x, 0.0, samples[prev_idx].forward.z).normalized()
		var f_next: Vector3 = Vector3(samples[next_idx].forward.x, 0.0, samples[next_idx].forward.z).normalized()
		var d_dist: float = max(actual_step * 2.0, 1.0)
		var turn_rate: float = (f_next - f_prev).dot(samples[i].right) / d_dist
		raw_curvatures[i] = clampf(turn_rate, -0.12, 0.12)

	# Smooth curvature across a 7-sample window for smooth camber entry/exit
	var max_bank_rad: float = deg_to_rad(5.5)
	var bank_scale: float = 1.6
	if biome == Biome.IROHAZAKA:
		max_bank_rad = deg_to_rad(10.5) # Steep banking on switchback corners
		bank_scale = 2.6
	elif biome == Biome.TSUKUBA:
		max_bank_rad = deg_to_rad(6.5)
		bank_scale = 2.0

	for i in range(count):
		var accum: float = 0.0
		var weights: float = 0.0
		for offset in range(-3, 4):
			var idx: int
			if closed:
				idx = (i + offset + count) % count
			else:
				idx = clampi(i + offset, 0, count - 1)
			var w: float = 4.0 - float(abs(offset))
			accum += raw_curvatures[idx] * w
			weights += w

		var smooth_k: float = accum / max(weights, 1.0)
		samples[i].curvature = smooth_k
		var bank: float = clampf(smooth_k * bank_scale, -max_bank_rad, max_bank_rad)
		samples[i].bank_angle = bank

		# Positive bank (right turn) lowers the right inside edge and raises the left outside edge
		var b_right: Vector3 = (samples[i].right * cos(bank) - samples[i].up * sin(bank)).normalized()
		var b_up: Vector3 = b_right.cross(samples[i].forward).normalized()
		samples[i].banked_right = b_right
		samples[i].banked_up = b_up

	return samples


# ==============================================================================
# ATMOSPHERE, SKYBOX & LIGHTING CONFIGURATION
# ==============================================================================

func _build_atmosphere_and_lighting(container: Node3D, host_root: Node3D, biome: Biome) -> void:
	var env: Environment = Environment.new()
	var sky: Sky = Sky.new()
	var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	sky.sky_material = sky_mat

	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.ssao_enabled = false
	env.glow_enabled = true

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.name = "BiomeDirectionalLight"
	sun.shadow_enabled = enable_dynamic_lights

	match biome:
		Biome.AKINA:
			# Pitch-black mountain night with deep indigo ambient light & valley fog
			sky_mat.sky_top_color = Color(0.01, 0.015, 0.04)
			sky_mat.sky_horizon_color = Color(0.03, 0.04, 0.10)
			sky_mat.ground_bottom_color = Color(0.005, 0.008, 0.02)
			sky_mat.ground_horizon_color = Color(0.02, 0.03, 0.07)
			sky_mat.sky_curve = 0.12
			sky_mat.sun_angle_max = 8.0

			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.09, 0.12, 0.25) # Deep indigo ambient
			env.ambient_light_energy = 0.65
			env.tonemap_exposure = 1.05
			env.glow_intensity = 1.15
			env.glow_bloom = 0.2

			env.fog_enabled = true
			env.fog_light_color = Color(0.05, 0.07, 0.16)
			env.fog_density = 0.0045
			env.fog_height = 45.0
			env.fog_height_density = 0.035

			env.volumetric_fog_enabled = true
			env.volumetric_fog_density = 0.012
			env.volumetric_fog_albedo = Color(0.10, 0.14, 0.28)
			env.volumetric_fog_emission = Color(0.02, 0.03, 0.08)

			sun.light_color = Color(0.42, 0.52, 0.85) # Cool pale moonlight
			sun.light_energy = 0.32
			sun.rotation_degrees = Vector3(-52.0, -35.0, 0.0)

		Biome.IROHAZAKA:
			# Dramatic golden hour autumn sunset with rich orange-amber sky
			sky_mat.sky_top_color = Color(0.22, 0.10, 0.28)
			sky_mat.sky_horizon_color = Color(0.96, 0.44, 0.14)
			sky_mat.ground_bottom_color = Color(0.12, 0.06, 0.05)
			sky_mat.ground_horizon_color = Color(0.82, 0.34, 0.12)
			sky_mat.sky_curve = 0.22
			sky_mat.sun_angle_max = 35.0
			sky_mat.sun_curve = 0.08

			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.65, 0.36, 0.22)
			env.ambient_light_energy = 0.85
			env.tonemap_exposure = 1.1
			env.glow_intensity = 0.9
			env.glow_bloom = 0.12

			env.fog_enabled = true
			env.fog_light_color = Color(0.92, 0.48, 0.22)
			env.fog_sun_scatter = 0.45
			env.fog_density = 0.0022
			env.fog_aerial_perspective = 0.65

			env.volumetric_fog_enabled = false

			sun.light_color = Color(1.0, 0.62, 0.28) # Warm golden-amber sunset rays
			sun.light_energy = 1.65
			sun.rotation_degrees = Vector3(-16.0, 125.0, 0.0)

		Biome.TSUKUBA:
			# Crisp midday blue sky with high sun position and sharp shadows
			sky_mat.sky_top_color = Color(0.18, 0.45, 0.88)
			sky_mat.sky_horizon_color = Color(0.68, 0.84, 0.98)
			sky_mat.ground_bottom_color = Color(0.18, 0.22, 0.16)
			sky_mat.ground_horizon_color = Color(0.62, 0.76, 0.88)
			sky_mat.sky_curve = 0.10
			sky_mat.sun_angle_max = 18.0

			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.68, 0.76, 0.88)
			env.ambient_light_energy = 0.95
			env.tonemap_exposure = 1.0
			env.glow_intensity = 0.45
			env.glow_bloom = 0.04

			env.fog_enabled = true
			env.fog_light_color = Color(0.74, 0.86, 0.98)
			env.fog_density = 0.0005
			env.fog_aerial_perspective = 0.3

			env.volumetric_fog_enabled = false

			sun.light_color = Color(1.0, 0.98, 0.94)
			sun.light_energy = 1.45
			sun.rotation_degrees = Vector3(-68.0, -40.0, 0.0)

	# Synchronize any pre-existing WorldEnvironment in host_root so Godot's viewport
	# always displays our active biome environment immediately
	if is_instance_valid(host_root):
		for child in host_root.get_children():
			if child is WorldEnvironment:
				(child as WorldEnvironment).environment = env
			elif child is DirectionalLight3D and child != sun:
				(child as DirectionalLight3D).visible = false

	var world_env: WorldEnvironment = WorldEnvironment.new()
	world_env.name = "BiomeWorldEnvironment"
	world_env.environment = env
	container.add_child(world_env)
	container.add_child(sun)


# ==============================================================================
# PROCEDURAL ROAD, GUTTER/KERB, MARKINGS & GUARDRAIL PIPELINE
# ==============================================================================

func _build_road_and_barriers(container: Node3D, samples: Array[RoadSample], biome: Biome, closed: bool) -> void:
	var count: int = samples.size()
	if count < 2:
		return

	var st_road: SurfaceTool = SurfaceTool.new()
	st_road.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_guardrail: SurfaceTool = SurfaceTool.new()
	st_guardrail.begin(Mesh.PRIMITIVE_TRIANGLES)

	var road_collision_faces: PackedVector3Array = PackedVector3Array()
	var rail_collision_faces: PackedVector3Array = PackedVector3Array()

	# Cross-section profile lateral offsets (12 vertices per sample)
	# Indices:
	# 0: Left Outer Rim       | 1: Left Gutter/Kerb Outer | 2: Left Gutter/Kerb Inner | 3: Left Tarmac Edge
	# 4: Left Line Outer      | 5: Left Center Edge       | 6: Right Center Edge      | 7: Right Line Outer
	# 8: Right Tarmac Edge    | 9: Right Gutter/Kerb Inner| 10: Right Gutter/Kerb Outer| 11: Right Outer Rim
	var half_w: float = 5.4
	if biome == Biome.IROHAZAKA:
		half_w = 5.6
	elif biome == Biome.TSUKUBA:
		half_w = 6.5

	var profiles_pos: Array[PackedVector3Array] = []
	var profiles_col: Array[PackedColorArray] = []
	profiles_pos.resize(count)
	profiles_col.resize(count)

	for i in range(count):
		var s: RoadSample = samples[i]
		var k: float = s.curvature
		var abs_k: float = absf(k)
		var is_corner: bool = abs_k > 0.012
		var left_is_inside: bool = k < -0.010
		var right_is_inside: bool = k > 0.010

		var row_pos: PackedVector3Array = PackedVector3Array()
		var row_col: PackedColorArray = PackedColorArray()
		row_pos.resize(12)
		row_col.resize(12)

		var x_coords: PackedFloat32Array
		var y_offsets: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])

		var c_asphalt: Color
		var c_lane: Color
		var c_center: Color
		var c_edge_line: Color
		var c_left_kerb: Color
		var c_right_kerb: Color

		match biome:
			Biome.AKINA:
				x_coords = PackedFloat32Array([
					-half_w - 0.55, -half_w - 0.45, -half_w - 0.08, -half_w,
					-half_w + 0.16, -0.10, 0.10, half_w - 0.16,
					half_w, half_w + 0.08, half_w + 0.45, half_w + 0.55
				])
				# Recessed U-shaped concrete Gutter Hook (deeper on inside apexes)
				var l_depth: float = -0.20 if left_is_inside else -0.14
				var r_depth: float = -0.20 if right_is_inside else -0.14
				y_offsets[1] = l_depth
				y_offsets[2] = l_depth
				y_offsets[9] = r_depth
				y_offsets[10] = r_depth

				c_asphalt = Color(0.14, 0.15, 0.17)
				# Darkened tire skid marks on hairpin corners
				var skid_factor: float = clampf((abs_k - 0.012) * 18.0, 0.0, 0.55)
				c_lane = c_asphalt.darkened(skid_factor)
				c_center = Color(0.86, 0.86, 0.84) if (i % 3 != 0 or is_corner) else c_asphalt
				c_edge_line = Color(0.82, 0.82, 0.80)
				c_left_kerb = Color(0.32, 0.33, 0.35)
				c_right_kerb = Color(0.32, 0.33, 0.35)

			Biome.IROHAZAKA:
				x_coords = PackedFloat32Array([
					-half_w - 0.65, -half_w - 0.50, -half_w - 0.05, -half_w,
					-half_w + 0.18, -0.12, 0.12, half_w - 0.18,
					half_w, half_w + 0.05, half_w + 0.50, half_w + 0.65
				])
				# Raised mountain stone/concrete shoulder curbs
				y_offsets[0] = 0.14
				y_offsets[1] = 0.14
				y_offsets[10] = 0.14
				y_offsets[11] = 0.14

				c_asphalt = Color(0.18, 0.17, 0.19)
				var skid_factor: float = clampf((abs_k - 0.014) * 14.0, 0.0, 0.42)
				c_lane = c_asphalt.darkened(skid_factor)
				# Bright yellow mountain pass center divider line
				c_center = Color(0.98, 0.72, 0.08)
				c_edge_line = Color(0.88, 0.86, 0.82)
				c_left_kerb = Color(0.45, 0.42, 0.38)
				c_right_kerb = Color(0.45, 0.42, 0.38)

			Biome.TSUKUBA:
				x_coords = PackedFloat32Array([
					-half_w - 1.35, -half_w - 1.20, -half_w - 0.05, -half_w,
					-half_w + 0.20, -0.12, 0.12, half_w - 0.20,
					half_w, half_w + 0.05, half_w + 1.20, half_w + 1.35
				])
				# Angled FIA rumble-strip kerbs
				y_offsets[0] = 0.03
				y_offsets[1] = 0.09
				y_offsets[10] = 0.09
				y_offsets[11] = 0.03

				c_asphalt = Color(0.12, 0.13, 0.14)
				var skid_factor: float = clampf((abs_k - 0.010) * 16.0, 0.0, 0.45)
				c_lane = c_asphalt.darkened(skid_factor)
				# Starting grid / finish line markings near start of loop
				if i < 6 and (i % 2 == 0):
					c_center = Color(0.95, 0.95, 0.95)
				else:
					c_center = c_asphalt
				c_edge_line = Color(0.95, 0.95, 0.95)

				# Alternating red-and-white FIA kerbs on corners and exits
				var is_red_slice: bool = (i % 2 == 0)
				var fia_col: Color = Color(0.90, 0.12, 0.12) if is_red_slice else Color(0.96, 0.96, 0.96)
				var grass_verge: Color = Color(0.22, 0.38, 0.16)
				c_left_kerb = fia_col if (is_corner or left_is_inside) else grass_verge
				c_right_kerb = fia_col if (is_corner or right_is_inside) else grass_verge

		for v_idx in range(12):
			row_pos[v_idx] = s.pos + s.banked_right * x_coords[v_idx] + s.banked_up * y_offsets[v_idx]

		row_col[0] = c_left_kerb.darkened(0.15)
		row_col[1] = c_left_kerb
		row_col[2] = c_left_kerb
		row_col[3] = c_edge_line
		row_col[4] = c_edge_line
		row_col[5] = c_center
		row_col[6] = c_center
		row_col[7] = c_edge_line
		row_col[8] = c_edge_line
		row_col[9] = c_right_kerb
		row_col[10] = c_right_kerb
		row_col[11] = c_right_kerb.darkened(0.15)

		profiles_pos[i] = row_pos
		profiles_col[i] = row_col

	# Stitch road cross-section slices
	var seg_count: int = count if closed else (count - 1)
	for i in range(seg_count):
		var next_i: int = (i + 1) % count
		var p0: PackedVector3Array = profiles_pos[i]
		var p1: PackedVector3Array = profiles_pos[next_i]
		var c0: PackedColorArray = profiles_col[i]
		var c1: PackedColorArray = profiles_col[next_i]

		var s_cur: RoadSample = samples[i]
		var abs_k: float = absf(s_cur.curvature)
		var skid_dark: float = clampf((abs_k - 0.010) * 18.0, 0.0, 0.48)
		var lane_base: Color = Color(0.14, 0.15, 0.17)
		if biome == Biome.IROHAZAKA:
			lane_base = Color(0.18, 0.17, 0.19)
		elif biome == Biome.TSUKUBA:
			lane_base = Color(0.12, 0.13, 0.14)
		var lane_col: Color = lane_base.darkened(skid_dark)

		for strip in range(11):
			var sc0: Color = c0[strip]
			var sc1: Color = c0[strip + 1]
			var sc2: Color = c1[strip + 1]
			var sc3: Color = c1[strip]

			# Keep lane interior strips uniformly colored so white edge lines don't bleed across the lane
			if strip == 4 or strip == 6:
				sc0 = lane_col
				sc1 = lane_col
				sc2 = lane_col
				sc3 = lane_col
			elif strip == 5:
				sc0 = c0[5]
				sc1 = c0[6]
				sc2 = c1[6]
				sc3 = c1[5]

			_add_quad_with_collision(
				st_road,
				p0[strip], p0[strip + 1], p1[strip + 1], p1[strip],
				sc0, sc1, sc2, sc3,
				road_collision_faces
			)

		# Generate perimeter guardrails / barriers along road edges
		var rail_offset: float = 0.0
		var rail_height: float = 0.82
		var rail_col_l: Color = Color(0.68, 0.72, 0.76)
		var rail_col_r: Color = Color(0.68, 0.72, 0.76)

		if biome == Biome.IROHAZAKA:
			# Wooden timber rail on left (cliff side), steel/concrete barrier on right (gorge drop-off)
			rail_col_l = Color(0.42, 0.26, 0.14)
			rail_col_r = Color(0.75, 0.74, 0.72)
			rail_height = 0.88
		elif biome == Biome.TSUKUBA:
			# Circuit safety walls pushed back across the grass verge (except pit wall on main straight)
			rail_offset = 4.2
			rail_height = 1.05
			var is_red_wall: bool = (i % 4 < 2)
			rail_col_l = Color(0.86, 0.88, 0.90)
			rail_col_r = Color(0.85, 0.16, 0.16) if is_red_wall else Color(0.92, 0.92, 0.94)

		var l_base0: Vector3 = p0[0] - samples[i].banked_right * rail_offset
		var l_base1: Vector3 = p1[0] - samples[next_i].banked_right * rail_offset
		var l_top0: Vector3 = l_base0 + samples[i].banked_up * rail_height
		var l_top1: Vector3 = l_base1 + samples[next_i].banked_up * rail_height

		var r_base0: Vector3 = p0[11] + samples[i].banked_right * rail_offset
		var r_base1: Vector3 = p1[11] + samples[next_i].banked_right * rail_offset
		var r_top0: Vector3 = r_base0 + samples[i].banked_up * rail_height
		var r_top1: Vector3 = r_base1 + samples[next_i].banked_up * rail_height

		# Left guardrail (front and back faces)
		_add_quad_with_collision(st_guardrail, l_base0, l_top0, l_top1, l_base1, rail_col_l.darkened(0.15), rail_col_l, rail_col_l, rail_col_l.darkened(0.15), rail_collision_faces)
		_add_quad(st_guardrail, l_top0, l_base0, l_base1, l_top1, rail_col_l.darkened(0.3), rail_col_l.darkened(0.3), rail_col_l.darkened(0.3), rail_col_l.darkened(0.3))

		# Right guardrail (front and back faces)
		_add_quad_with_collision(st_guardrail, r_top0, r_base0, r_base1, r_top1, rail_col_r, rail_col_r.darkened(0.15), rail_col_r.darkened(0.15), rail_col_r, rail_collision_faces)
		_add_quad(st_guardrail, r_base0, r_top0, r_top1, r_base1, rail_col_r.darkened(0.3), rail_col_r.darkened(0.3), rail_col_r.darkened(0.3), rail_col_r.darkened(0.3))

	st_road.generate_normals()
	var road_mesh: ArrayMesh = st_road.commit()
	var road_mat: StandardMaterial3D = StandardMaterial3D.new()
	road_mat.vertex_color_use_as_albedo = true
	road_mat.roughness = 0.84 if biome != Biome.TSUKUBA else 0.76
	road_mat.metallic = 0.05
	road_mesh.surface_set_material(0, road_mat)

	var road_mi: MeshInstance3D = MeshInstance3D.new()
	road_mi.name = "ProceduralRoadMesh"
	road_mi.mesh = road_mesh
	container.add_child(road_mi)

	if road_collision_faces.size() >= 3:
		var road_body: StaticBody3D = StaticBody3D.new()
		road_body.name = "RoadStaticBody"
		var road_col: CollisionShape3D = CollisionShape3D.new()
		var road_shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
		road_shape.set_faces(road_collision_faces)
		road_col.shape = road_shape
		road_body.add_child(road_col)
		road_mi.add_child(road_body)

	st_guardrail.generate_normals()
	var rail_mesh: ArrayMesh = st_guardrail.commit()
	var rail_mat: StandardMaterial3D = StandardMaterial3D.new()
	rail_mat.vertex_color_use_as_albedo = true
	rail_mat.roughness = 0.45 if biome == Biome.AKINA else 0.65
	rail_mat.metallic = 0.55 if biome == Biome.AKINA else 0.20
	rail_mesh.surface_set_material(0, rail_mat)

	var rail_mi: MeshInstance3D = MeshInstance3D.new()
	rail_mi.name = "GuardrailMesh"
	rail_mi.mesh = rail_mesh
	container.add_child(rail_mi)

	if rail_collision_faces.size() >= 3:
		var rail_body: StaticBody3D = StaticBody3D.new()
		rail_body.name = "GuardrailStaticBody"
		var rail_col: CollisionShape3D = CollisionShape3D.new()
		var rail_shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
		rail_shape.set_faces(rail_collision_faces)
		rail_col.shape = rail_shape
		rail_body.add_child(rail_col)
		rail_mi.add_child(rail_body)


# ==============================================================================
# PROCEDURAL TERRAIN, CLIFFS & VISTA GENERATION
# ==============================================================================

func _build_terrain_and_vista(container: Node3D, samples: Array[RoadSample], biome: Biome, closed: bool) -> void:
	var count: int = samples.size()
	if count < 2:
		return

	var st_terrain: SurfaceTool = SurfaceTool.new()
	st_terrain.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half_w: float = 6.0 if biome != Biome.TSUKUBA else 7.8
	var left_rows: Array[PackedVector3Array] = []
	var right_rows: Array[PackedVector3Array] = []
	var left_cols: Array[PackedColorArray] = []
	var right_cols: Array[PackedColorArray] = []
	left_rows.resize(count)
	right_rows.resize(count)
	left_cols.resize(count)
	right_cols.resize(count)

	for i in range(count):
		var s: RoadSample = samples[i]
		var l_pts: PackedVector3Array = PackedVector3Array()
		var r_pts: PackedVector3Array = PackedVector3Array()
		var l_col: PackedColorArray = PackedColorArray()
		var r_col: PackedColorArray = PackedColorArray()
		l_pts.resize(4)
		r_pts.resize(4)
		l_col.resize(4)
		r_col.resize(4)

		var n1: float = sin(float(i) * 0.37) * cos(float(i) * 0.19)
		var n2: float = cos(float(i) * 0.53 + 1.4)

		match biome:
			Biome.AKINA:
				# Forested Gunma mountain ridge on left, deep valley slope on right
				l_pts[0] = s.pos - s.banked_right * half_w + Vector3(0.0, -0.1, 0.0)
				l_pts[1] = s.pos - s.right * (half_w + 10.0) + Vector3(0.0, 6.5 + n1 * 2.5, 0.0)
				l_pts[2] = s.pos - s.right * (half_w + 28.0) + Vector3(0.0, 19.0 + n2 * 4.5, 0.0)
				l_pts[3] = s.pos - s.right * (half_w + 60.0) + Vector3(0.0, 38.0 + n1 * 7.0, 0.0)

				r_pts[0] = s.pos + s.banked_right * half_w + Vector3(0.0, -0.1, 0.0)
				r_pts[1] = s.pos + s.right * (half_w + 10.0) + Vector3(0.0, -6.0 + n2 * 1.5, 0.0)
				r_pts[2] = s.pos + s.right * (half_w + 28.0) + Vector3(0.0, -18.0 + n1 * 3.5, 0.0)
				r_pts[3] = s.pos + s.right * (half_w + 60.0) + Vector3(0.0, -36.0 + n2 * 5.0, 0.0)

				var c_pine_floor: Color = Color(0.05, 0.09, 0.06)
				var c_rock_dark: Color = Color(0.08, 0.09, 0.12)
				l_col = PackedColorArray([c_rock_dark, c_pine_floor, c_rock_dark, c_pine_floor.darkened(0.2)])
				r_col = PackedColorArray([c_rock_dark, c_pine_floor, c_pine_floor.darkened(0.25), c_rock_dark.darkened(0.3)])

			Biome.IROHAZAKA:
				# Sheer towering vertical rocky cliffs on left, steep autumn canyon gorge on right
				l_pts[0] = s.pos - s.banked_right * half_w + Vector3(0.0, 0.0, 0.0)
				l_pts[1] = s.pos - s.right * (half_w + 3.2) + Vector3(0.0, 14.0 + n1 * 2.0, 0.0)
				l_pts[2] = s.pos - s.right * (half_w + 8.5) + Vector3(0.0, 32.0 + n2 * 3.5, 0.0)
				l_pts[3] = s.pos - s.right * (half_w + 24.0) + Vector3(0.0, 52.0 + n1 * 5.0, 0.0)

				r_pts[0] = s.pos + s.banked_right * half_w + Vector3(0.0, 0.0, 0.0)
				r_pts[1] = s.pos + s.right * (half_w + 8.0) + Vector3(0.0, -9.0 + n2 * 1.5, 0.0)
				r_pts[2] = s.pos + s.right * (half_w + 22.0) + Vector3(0.0, -24.0 + n1 * 3.0, 0.0)
				r_pts[3] = s.pos + s.right * (half_w + 48.0) + Vector3(0.0, -45.0 + n2 * 4.0, 0.0)

				var c_cliff: Color = Color(0.34, 0.28, 0.24)
				var c_cliff_hi: Color = Color(0.46, 0.36, 0.28)
				var c_autumn_floor: Color = Color(0.42, 0.22, 0.10)
				l_col = PackedColorArray([c_cliff, c_cliff_hi, c_cliff, c_autumn_floor])
				r_col = PackedColorArray([c_cliff, c_autumn_floor, c_cliff.darkened(0.15), c_autumn_floor.darkened(0.2)])

			Biome.TSUKUBA:
				# Flat racing ground with grass infield/outfield and beige gravel traps on corners
				var is_gravel_zone: bool = absf(s.curvature) > 0.014
				l_pts[0] = s.pos - s.banked_right * half_w + Vector3(0.0, -0.02, 0.0)
				l_pts[1] = s.pos - s.right * (half_w + 4.2) + Vector3(0.0, -0.04, 0.0)
				l_pts[2] = s.pos - s.right * (half_w + 18.0) + Vector3(0.0, -0.08, 0.0)
				l_pts[3] = s.pos - s.right * (half_w + 45.0) + Vector3(0.0, -0.15, 0.0)

				r_pts[0] = s.pos + s.banked_right * half_w + Vector3(0.0, -0.02, 0.0)
				r_pts[1] = s.pos + s.right * (half_w + 4.2) + Vector3(0.0, -0.04, 0.0)
				r_pts[2] = s.pos + s.right * (half_w + 18.0) + Vector3(0.0, -0.08, 0.0)
				r_pts[3] = s.pos + s.right * (half_w + 45.0) + Vector3(0.0, -0.15, 0.0)

				var c_grass_a: Color = Color(0.22, 0.42, 0.16)
				var c_grass_b: Color = Color(0.18, 0.36, 0.14)
				var c_gravel: Color = Color(0.76, 0.68, 0.52)
				var c_inner: Color = c_gravel if is_gravel_zone else c_grass_a
				l_col = PackedColorArray([c_grass_a, c_inner, c_grass_b, c_grass_a])
				r_col = PackedColorArray([c_grass_a, c_inner, c_grass_b, c_grass_a])

		# Depress any outer terrain vertex that comes close to another switchback/loop segment
		for k_idx in range(1, 4):
			l_pts[k_idx] = _clamp_terrain_vertex_outside_road(l_pts[k_idx], samples, i, half_w + 3.5)
			r_pts[k_idx] = _clamp_terrain_vertex_outside_road(r_pts[k_idx], samples, i, half_w + 3.5)

		left_rows[i] = l_pts
		right_rows[i] = r_pts
		left_cols[i] = l_col
		right_cols[i] = r_col

	var seg_count: int = count if closed else (count - 1)
	for i in range(seg_count):
		var next_i: int = (i + 1) % count
		var l0: PackedVector3Array = left_rows[i]
		var l1: PackedVector3Array = left_rows[next_i]
		var lc0: PackedColorArray = left_cols[i]
		var lc1: PackedColorArray = left_cols[next_i]

		var r0: PackedVector3Array = right_rows[i]
		var r1: PackedVector3Array = right_rows[next_i]
		var rc0: PackedColorArray = right_cols[i]
		var rc1: PackedColorArray = right_cols[next_i]

		for s_idx in range(3):
			# Left terrain slope
			_add_quad(
				st_terrain,
				l0[s_idx + 1], l0[s_idx], l1[s_idx], l1[s_idx + 1],
				lc0[s_idx + 1], lc0[s_idx], lc1[s_idx], lc1[s_idx + 1]
			)
			# Right terrain slope
			_add_quad(
				st_terrain,
				r0[s_idx], r0[s_idx + 1], r1[s_idx + 1], r1[s_idx],
				rc0[s_idx], rc0[s_idx + 1], rc1[s_idx + 1], rc1[s_idx]
			)

	# Add distant horizon mountains or flat circuit ground plane
	_append_horizon_vista(st_terrain, samples, biome)

	st_terrain.generate_normals()
	var terrain_mesh: ArrayMesh = st_terrain.commit()
	var terrain_mat: StandardMaterial3D = StandardMaterial3D.new()
	terrain_mat.vertex_color_use_as_albedo = true
	terrain_mat.roughness = 0.95
	terrain_mesh.surface_set_material(0, terrain_mat)

	var terrain_mi: MeshInstance3D = MeshInstance3D.new()
	terrain_mi.name = "BiomeTerrainMesh"
	terrain_mi.mesh = terrain_mesh
	container.add_child(terrain_mi)


func _clamp_terrain_vertex_outside_road(pt: Vector3, samples: Array[RoadSample], own_idx: int, min_clearance: float) -> Vector3:
	var min_sq: float = min_clearance * min_clearance
	var adjusted: Vector3 = pt
	var step_stride: int = 2
	for j in range(0, samples.size(), step_stride):
		if absi(j - own_idx) <= 4:
			continue
		var rp: Vector3 = samples[j].pos
		var dx: float = adjusted.x - rp.x
		var dz: float = adjusted.z - rp.z
		var dist_xz_sq: float = dx * dx + dz * dz
		if dist_xz_sq < min_sq and adjusted.y > rp.y - 1.5:
			adjusted.y = minf(adjusted.y, rp.y - 2.2)
	return adjusted


func _append_horizon_vista(st: SurfaceTool, samples: Array[RoadSample], biome: Biome) -> void:
	var center: Vector3 = Vector3.ZERO
	var min_y: float = 99999.0
	for s in samples:
		center += s.pos
		min_y = minf(min_y, s.pos.y)
	center /= float(max(samples.size(), 1))

	if biome == Biome.TSUKUBA:
		# Expansive flat green ground apron around the entire circuit
		var y_base: float = min_y - 0.25
		var sz: float = 650.0
		var c_ground: Color = Color(0.18, 0.34, 0.13)
		_add_quad(
			st,
			Vector3(center.x - sz, y_base, center.z - sz),
			Vector3(center.x + sz, y_base, center.z - sz),
			Vector3(center.x + sz, y_base, center.z + sz),
			Vector3(center.x - sz, y_base, center.z + sz),
			c_ground, c_ground, c_ground, c_ground
		)
		return

	# Ring of distant mountain peaks for Akina and Irohazaka
	var num_peaks: int = 28
	var inner_r: float = 420.0
	var outer_r: float = 780.0
	var c_base: Color = Color(0.03, 0.05, 0.08) if biome == Biome.AKINA else Color(0.28, 0.16, 0.12)
	var c_peak: Color = Color(0.06, 0.09, 0.16) if biome == Biome.AKINA else Color(0.55, 0.26, 0.14)

	for i in range(num_peaks):
		var a0: float = TAU * float(i) / float(num_peaks)
		var a1: float = TAU * float(i + 1) / float(num_peaks)
		var am: float = (a0 + a1) * 0.5

		var p0: Vector3 = Vector3(center.x + cos(a0) * inner_r, min_y - 45.0, center.z + sin(a0) * inner_r)
		var p1: Vector3 = Vector3(center.x + cos(a1) * inner_r, min_y - 45.0, center.z + sin(a1) * inner_r)
		var peak_h: float = 190.0 + sin(float(i) * 2.3) * 65.0
		var pm: Vector3 = Vector3(center.x + cos(am) * outer_r, min_y + peak_h, center.z + sin(am) * outer_r)

		st.set_color(c_base)
		st.add_vertex(p0)
		st.set_color(c_peak)
		st.add_vertex(pm)
		st.set_color(c_base)
		st.add_vertex(p1)


# ==============================================================================
# BIOME A: MOUNT AKINA DOWNHILL SCENERY (CRYPTOMERIA PINES, STREETLIGHTS, MARKERS)
# ==============================================================================

func _populate_akina_scenery(container: Node3D, samples: Array[RoadSample]) -> void:
	# 1. Dense Japanese Cryptomeria (Cedar / Dark Pine) Evergreen Trees
	var pine_mesh: ArrayMesh = _create_cryptomeria_tree_mesh()
	var pine_xforms: Array[Transform3D] = []
	var pine_colors: PackedColorArray = PackedColorArray()

	# 2. Reflective Red/White Guardrail Markers (Delineators)
	var marker_xforms: Array[Transform3D] = []
	var marker_colors: PackedColorArray = PackedColorArray()

	var half_w: float = 5.4
	for i in range(samples.size()):
		var s: RoadSample = samples[i]

		# Reflective guardrail markers every 2 samples
		if i % 2 == 0:
			var l_pos: Vector3 = s.pos - s.banked_right * (half_w + 0.55) + s.banked_up * 0.88
			var r_pos: Vector3 = s.pos + s.banked_right * (half_w + 0.55) + s.banked_up * 0.88
			var basis: Basis = Basis.looking_at(s.forward, s.banked_up)
			marker_xforms.append(Transform3D(basis, l_pos))
			marker_colors.append(Color(1.0, 0.18, 0.12)) # Red left reflector
			marker_xforms.append(Transform3D(basis, r_pos))
			marker_colors.append(Color(0.98, 0.98, 1.0))  # White right reflector

		# Scatter Cryptomeria trees along both sides outside road margins
		for tier in range(3):
			var lat_dist: float = half_w + 5.5 + float(tier) * 8.5 + fmod(float(i * 7 + tier * 13), 4.5)
			var l_elev: float = 3.5 + float(tier) * 5.2
			var r_elev: float = -3.2 - float(tier) * 4.8

			var l_tree_pos: Vector3 = s.pos - s.right * lat_dist + Vector3(0.0, l_elev, 0.0)
			if _is_point_clear_of_road(l_tree_pos, samples, half_w + 3.5):
				var sc: float = 0.85 + fmod(float(i * 3 + tier), 5.0) * 0.14
				var b: Basis = Basis.from_euler(Vector3(0.0, float(i * 1.7 + tier), 0.0)).scaled(Vector3(sc, sc * 1.15, sc))
				pine_xforms.append(Transform3D(b, l_tree_pos))
				pine_colors.append(Color(0.85, 0.92, 0.88).darkened(float(tier) * 0.08))

			var r_tree_pos: Vector3 = s.pos + s.right * lat_dist + Vector3(0.0, r_elev, 0.0)
			if _is_point_clear_of_road(r_tree_pos, samples, half_w + 3.5):
				var sc: float = 0.85 + fmod(float(i * 5 + tier), 5.0) * 0.14
				var b: Basis = Basis.from_euler(Vector3(0.0, float(i * 2.3 + tier), 0.0)).scaled(Vector3(sc, sc * 1.15, sc))
				pine_xforms.append(Transform3D(b, r_tree_pos))
				pine_colors.append(Color(0.82, 0.90, 0.86).darkened(float(tier) * 0.08))

		# Dim Sodium-Vapor Yellow Streetlights at corners and regular pass intervals
		var is_apex: bool = absf(s.curvature) > 0.022 and (i % 7 == 0)
		var is_regular_lamp: bool = (i % 18 == 4)
		if is_apex or is_regular_lamp:
			var side_sign: float = -1.0 if s.curvature >= 0.0 else 1.0
			var pole_pos: Vector3 = s.pos + s.banked_right * (side_sign * (half_w + 0.85))
			_create_akina_streetlight(container, pole_pos, s.forward, -s.banked_right * side_sign)

	_add_multimesh_batch(container, "AkinaCryptomeriaTrees", pine_mesh, pine_xforms, pine_colors)

	var marker_mesh: BoxMesh = BoxMesh.new()
	marker_mesh.size = Vector3(0.14, 0.22, 0.08)
	var marker_mat: StandardMaterial3D = StandardMaterial3D.new()
	marker_mat.vertex_color_use_as_albedo = true
	marker_mat.emission_enabled = true
	marker_mat.emission = Color(0.95, 0.35, 0.20)
	marker_mat.emission_energy_multiplier = 1.6
	marker_mesh.material = marker_mat
	_add_multimesh_batch(container, "AkinaReflectiveMarkers", marker_mesh, marker_xforms, marker_colors)

	# Akina Summit Starting Water Tower & Touge Archway
	if samples.size() >= 2:
		_build_akina_start_landmark(container, samples[0])


func _create_akina_streetlight(container: Node3D, base_pos: Vector3, road_fwd: Vector3, inward_dir: Vector3) -> void:
	var pole_root: Node3D = Node3D.new()
	pole_root.name = "SodiumStreetlight"
	pole_root.position = base_pos
	pole_root.basis = Basis.looking_at(inward_dir, Vector3.UP)
	container.add_child(pole_root)

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c_pole: Color = Color(0.28, 0.30, 0.34)
	_append_box_to_st(st, Vector3(0.0, 2.8, 0.0), Vector3(0.16, 5.6, 0.16), c_pole)
	_append_box_to_st(st, Vector3(0.0, 5.5, -0.9), Vector3(0.12, 0.14, 1.9), c_pole)
	st.generate_normals()
	var pole_mesh: ArrayMesh = st.commit()
	var pole_mat: StandardMaterial3D = StandardMaterial3D.new()
	pole_mat.vertex_color_use_as_albedo = true
	pole_mat.metallic = 0.6
	pole_mat.roughness = 0.45
	pole_mesh.surface_set_material(0, pole_mat)

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = pole_mesh
	pole_root.add_child(mi)

	# Glowing sodium bulb fixture
	var bulb_mi: MeshInstance3D = MeshInstance3D.new()
	var bulb_box: BoxMesh = BoxMesh.new()
	bulb_box.size = Vector3(0.32, 0.12, 0.55)
	var bulb_mat: StandardMaterial3D = StandardMaterial3D.new()
	bulb_mat.albedo_color = Color(1.0, 0.72, 0.22)
	bulb_mat.emission_enabled = true
	bulb_mat.emission = Color(1.0, 0.65, 0.15)
	bulb_mat.emission_energy_multiplier = 3.5
	bulb_box.material = bulb_mat
	bulb_mi.mesh = bulb_box
	bulb_mi.position = Vector3(0.0, 5.4, -1.65)
	pole_root.add_child(bulb_mi)

	if enable_dynamic_lights:
		var omni: OmniLight3D = OmniLight3D.new()
		omni.light_color = Color(1.0, 0.68, 0.22) # Sodium-vapor amber-yellow
		omni.light_energy = 2.6
		omni.omni_range = 24.0
		omni.omni_attenuation = 1.35
		omni.shadow_enabled = false
		omni.distance_fade_enabled = true
		omni.distance_fade_begin = 95.0
		omni.distance_fade_length = 35.0
		omni.position = Vector3(0.0, 5.15, -1.65)
		pole_root.add_child(omni)


func _build_akina_start_landmark(container: Node3D, s0: RoadSample) -> void:
	var arch: Node3D = Node3D.new()
	arch.name = "AkinaSummitLandmark"
	arch.global_transform = Transform3D(Basis.looking_at(s0.forward, Vector3.UP), s0.pos)
	container.add_child(arch)

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Touge summit water tower silhouette on right & starting banner
	_append_box_to_st(st, Vector3(11.5, 5.0, 0.0), Vector3(2.8, 10.0, 2.8), Color(0.24, 0.28, 0.34))
	_append_box_to_st(st, Vector3(11.5, 11.2, 0.0), Vector3(4.6, 3.2, 4.6), Color(0.18, 0.22, 0.28))
	_append_box_to_st(st, Vector3(-6.2, 2.6, 0.0), Vector3(0.35, 5.2, 0.35), Color(0.55, 0.58, 0.62))
	_append_box_to_st(st, Vector3(6.2, 2.6, 0.0), Vector3(0.35, 5.2, 0.35), Color(0.55, 0.58, 0.62))
	_append_box_to_st(st, Vector3(0.0, 4.9, 0.0), Vector3(12.8, 0.75, 0.4), Color(0.12, 0.18, 0.36))
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	arch.add_child(mi)


# ==============================================================================
# BIOME B: IROHAZAKA SLOPE SCENERY (MOMIJI MAPLES, BIRCH, ROCKFALL NETS, POSTS)
# ==============================================================================

func _populate_irohazaka_scenery(container: Node3D, samples: Array[RoadSample]) -> void:
	var maple_mesh: ArrayMesh = _create_autumn_tree_mesh(Color(0.26, 0.16, 0.10), Color(0.92, 0.16, 0.08))
	var birch_mesh: ArrayMesh = _create_autumn_tree_mesh(Color(0.82, 0.78, 0.72), Color(0.98, 0.72, 0.10))
	var shrub_mesh: ArrayMesh = _create_crimson_shrub_mesh()
	var rocknet_mesh: ArrayMesh = _create_rockfall_net_panel_mesh()
	var post_mesh: BoxMesh = BoxMesh.new()
	post_mesh.size = Vector3(0.24, 1.15, 0.24)
	var post_mat: StandardMaterial3D = StandardMaterial3D.new()
	post_mat.vertex_color_use_as_albedo = true
	post_mat.roughness = 0.88
	post_mesh.material = post_mat

	var maple_xforms: Array[Transform3D] = []
	var maple_cols: PackedColorArray = PackedColorArray()
	var birch_xforms: Array[Transform3D] = []
	var birch_cols: PackedColorArray = PackedColorArray()
	var shrub_xforms: Array[Transform3D] = []
	var shrub_cols: PackedColorArray = PackedColorArray()
	var net_xforms: Array[Transform3D] = []
	var net_cols: PackedColorArray = PackedColorArray()
	var post_xforms: Array[Transform3D] = []
	var post_cols: PackedColorArray = PackedColorArray()

	var half_w: float = 5.6
	for i in range(samples.size()):
		var s: RoadSample = samples[i]

		# Traditional Wooden Barrier Posts along the road perimeter
		var l_post: Vector3 = s.pos - s.banked_right * (half_w + 0.62) + s.banked_up * 0.52
		var r_post: Vector3 = s.pos + s.banked_right * (half_w + 0.62) + s.banked_up * 0.52
		var p_basis: Basis = Basis.looking_at(s.forward, s.banked_up)
		post_xforms.append(Transform3D(p_basis, l_post))
		post_cols.append(Color(0.45, 0.28, 0.14))
		post_xforms.append(Transform3D(p_basis, r_post))
		post_cols.append(Color(0.45, 0.28, 0.14))

		# Reinforced Concrete Rockfall Retention Nets on the sheer cliff wall (Left side)
		if i % 3 == 0:
			var cliff_pos: Vector3 = s.pos - s.right * (half_w + 1.8) + Vector3(0.0, 4.2, 0.0)
			if _is_point_clear_of_road(cliff_pos, samples, half_w + 1.0):
				var cliff_basis: Basis = Basis.looking_at(s.forward, Vector3.UP) * Basis.from_euler(Vector3(0.0, 0.0, deg_to_rad(-14.0)))
				net_xforms.append(Transform3D(cliff_basis, cliff_pos))
				net_cols.append(Color(0.76, 0.74, 0.70))

		# Crimson Shrubs along rocky ledges
		var shrub_l: Vector3 = s.pos - s.right * (half_w + 4.5 + fmod(float(i * 3), 4.0)) + Vector3(0.0, 12.0, 0.0)
		if _is_point_clear_of_road(shrub_l, samples, half_w + 3.0):
			shrub_xforms.append(Transform3D(Basis.from_euler(Vector3(0.0, float(i), 0.0)), shrub_l))
			shrub_cols.append(Color(0.95, 0.22, 0.12))

		# Momiji Red Maples and Golden Birch trees carpeting the cliffs and valley slopes
		for tier in range(3):
			var r_dist: float = half_w + 6.5 + float(tier) * 8.0 + fmod(float(i * 5 + tier * 7), 4.0)
			var r_pos: Vector3 = s.pos + s.right * r_dist + Vector3(0.0, -4.5 - float(tier) * 6.5, 0.0)
			if _is_point_clear_of_road(r_pos, samples, half_w + 4.0):
				var sc: float = 0.9 + fmod(float(i + tier), 4.0) * 0.18
				var b: Basis = Basis.from_euler(Vector3(0.0, float(i * 1.9 + tier), 0.0)).scaled(Vector3(sc, sc, sc))
				if (i + tier) % 2 == 0:
					maple_xforms.append(Transform3D(b, r_pos))
					maple_cols.append(Color(1.0, 0.85 + fmod(float(i), 3.0) * 0.05, 0.80))
				else:
					birch_xforms.append(Transform3D(b, r_pos))
					birch_cols.append(Color(1.0, 0.92, 0.78))

			var l_dist: float = half_w + 9.5 + float(tier) * 7.5
			var l_pos: Vector3 = s.pos - s.right * l_dist + Vector3(0.0, 26.0 + float(tier) * 9.5, 0.0)
			if _is_point_clear_of_road(l_pos, samples, half_w + 4.0):
				var sc2: float = 0.85 + fmod(float(i * 2 + tier), 4.0) * 0.16
				var b2: Basis = Basis.from_euler(Vector3(0.0, float(i * 1.3 + tier), 0.0)).scaled(Vector3(sc2, sc2, sc2))
				if (i + tier) % 3 != 0:
					maple_xforms.append(Transform3D(b2, l_pos))
					maple_cols.append(Color(0.98, 0.78, 0.72))
				else:
					birch_xforms.append(Transform3D(b2, l_pos))
					birch_cols.append(Color(1.0, 0.95, 0.82))

	_add_multimesh_batch(container, "IrohazakaMomijiMaples", maple_mesh, maple_xforms, maple_cols)
	_add_multimesh_batch(container, "IrohazakaGoldenBirch", birch_mesh, birch_xforms, birch_cols)
	_add_multimesh_batch(container, "IrohazakaCrimsonShrubs", shrub_mesh, shrub_xforms, shrub_cols)
	_add_multimesh_batch(container, "IrohazakaRockfallNets", rocknet_mesh, net_xforms, net_cols)
	_add_multimesh_batch(container, "IrohazakaWoodenPosts", post_mesh, post_xforms, post_cols)


# ==============================================================================
# BIOME C: TSUKUBA CIRCUIT SCENERY (GRANDSTANDS, PIT GARAGES, GANTRY, BILLBOARDS)
# ==============================================================================

func _populate_tsukuba_scenery(container: Node3D, samples: Array[RoadSample]) -> void:
	if samples.size() < 8:
		return

	var s_start: RoadSample = samples[1]
	# 1. Start/Finish Overhead Timing Gantry with Starting Lights
	_build_tsukuba_timing_gantry(container, s_start)

	# 2. Pit Lane Building with Garages & Race Control Tower along Main Straight
	var s_pit: RoadSample = samples[min(4, samples.size() - 1)]
	_build_tsukuba_pit_complex(container, s_pit)

	# 3. Multi-Tiered Spectator Grandstands with Colorful Seating
	var s_stand1: RoadSample = samples[min(3, samples.size() - 1)]
	_build_tsukuba_grandstand(container, s_stand1.pos - s_stand1.right * 18.5, s_stand1.forward, 48.0)

	var hairpin_idx: int = int(samples.size() * 0.36)
	if hairpin_idx < samples.size():
		var s_stand2: RoadSample = samples[hairpin_idx]
		_build_tsukuba_grandstand(container, s_stand2.pos - s_stand2.right * 20.0, s_stand2.forward, 36.0)

	# 4. Iconic Dunlop Bridge spanning the mid-sector corner
	var dunlop_idx: int = int(samples.size() * 0.52)
	if dunlop_idx < samples.size():
		_build_tsukuba_dunlop_bridge(container, samples[dunlop_idx])

	# 5. Sponsor Billboards (Advan, Bridgestone, HKS, Yokohama colors)
	var billboard_liveries: Array[ Array ] = [
		[Color(0.08, 0.08, 0.09), Color(0.90, 0.10, 0.12)], # Advan Black / Red
		[Color(0.96, 0.96, 0.98), Color(0.88, 0.12, 0.12)], # Bridgestone White / Red
		[Color(0.16, 0.10, 0.28), Color(0.10, 0.78, 0.52)], # HKS Purple / Mint Green
		[Color(0.92, 0.78, 0.08), Color(0.10, 0.10, 0.12)]  # Dunlop Yellow / Black
	]

	# 6. Tire Walls & Safety Catch Fencing around corners
	var tire_mesh: CylinderMesh = CylinderMesh.new()
	tire_mesh.top_radius = 0.48
	tire_mesh.bottom_radius = 0.48
	tire_mesh.height = 1.05
	tire_mesh.radial_segments = 10
	var tire_mat: StandardMaterial3D = StandardMaterial3D.new()
	tire_mat.vertex_color_use_as_albedo = true
	tire_mat.roughness = 0.9
	tire_mesh.material = tire_mat

	var fence_mesh: ArrayMesh = _create_catch_fence_panel_mesh()
	var tire_xforms: Array[Transform3D] = []
	var tire_cols: PackedColorArray = PackedColorArray()
	var fence_xforms: Array[Transform3D] = []
	var fence_cols: PackedColorArray = PackedColorArray()

	var half_w: float = 6.5
	for i in range(samples.size()):
		var s: RoadSample = samples[i]
		var is_corner: bool = absf(s.curvature) > 0.012

		if is_corner or (i % 2 == 0):
			var wall_dist: float = half_w + 5.2
			var l_tire: Vector3 = s.pos - s.right * wall_dist + Vector3(0.0, 0.52, 0.0)
			var r_tire: Vector3 = s.pos + s.right * wall_dist + Vector3(0.0, 0.52, 0.0)
			var t_col: Color = Color(0.14, 0.14, 0.15) if (i % 3 != 0) else Color(0.88, 0.16, 0.16)
			tire_xforms.append(Transform3D(Basis.IDENTITY, l_tire))
			tire_cols.append(t_col)
			tire_xforms.append(Transform3D(Basis.IDENTITY, r_tire))
			tire_cols.append(t_col)

		if is_corner and (i % 2 == 0):
			var fence_dist: float = half_w + 5.8
			var f_basis: Basis = Basis.looking_at(s.forward, Vector3.UP)
			fence_xforms.append(Transform3D(f_basis, s.pos - s.right * fence_dist))
			fence_cols.append(Color(0.72, 0.76, 0.80))
			fence_xforms.append(Transform3D(f_basis, s.pos + s.right * fence_dist))
			fence_cols.append(Color(0.72, 0.76, 0.80))

		if i % 10 == 5:
			var liv_idx: int = (i / 10) % billboard_liveries.size()
			var liv: Array = billboard_liveries[liv_idx]
			var bb_pos: Vector3 = s.pos + s.right * (half_w + 10.5)
			if _is_point_clear_of_road(bb_pos, samples, half_w + 6.0):
				_build_tsukuba_billboard(container, bb_pos, -s.right, liv[0], liv[1])

	_add_multimesh_batch(container, "TsukubaTireWalls", tire_mesh, tire_xforms, tire_cols)
	_add_multimesh_batch(container, "TsukubaCatchFencing", fence_mesh, fence_xforms, fence_cols)


func _build_tsukuba_timing_gantry(container: Node3D, s: RoadSample) -> void:
	var gantry: Node3D = Node3D.new()
	gantry.name = "TsukubaTimingGantry"
	gantry.global_transform = Transform3D(Basis.looking_at(s.forward, Vector3.UP), s.pos)
	container.add_child(gantry)

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var span_x: float = 8.2
	_append_box_to_st(st, Vector3(-span_x, 3.4, 0.0), Vector3(0.55, 6.8, 0.55), Color(0.82, 0.84, 0.88))
	_append_box_to_st(st, Vector3(span_x, 3.4, 0.0), Vector3(0.55, 6.8, 0.55), Color(0.82, 0.84, 0.88))
	_append_box_to_st(st, Vector3(0.0, 6.4, 0.0), Vector3(span_x * 2.1, 1.25, 0.85), Color(0.95, 0.95, 0.97))
	_append_box_to_st(st, Vector3(0.0, 6.4, 0.46), Vector3(span_x * 1.9, 0.85, 0.1), Color(0.86, 0.12, 0.14))
	# Starting signal pods
	for idx in range(-2, 3):
		var px: float = float(idx) * 1.35
		_append_box_to_st(st, Vector3(px, 5.35, 0.35), Vector3(0.45, 0.75, 0.35), Color(0.10, 0.10, 0.12))
		var light_col: Color = Color(0.95, 0.12, 0.12) if idx < 0 else Color(0.12, 0.92, 0.25)
		_append_box_to_st(st, Vector3(px, 5.35, 0.54), Vector3(0.30, 0.30, 0.08), light_col)

	st.generate_normals()
	var mesh: ArrayMesh = st.commit()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	gantry.add_child(mi)


func _build_tsukuba_pit_complex(container: Node3D, s: RoadSample) -> void:
	var pit: Node3D = Node3D.new()
	pit.name = "TsukubaPitBuilding"
	pit.global_transform = Transform3D(Basis.looking_at(s.forward, Vector3.UP), s.pos + s.right * 16.5)
	container.add_child(pit)

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length_z: float = 56.0
	# Main ground floor garage block
	_append_box_to_st(st, Vector3(0.0, 2.6, 0.0), Vector3(9.0, 5.2, length_z), Color(0.88, 0.89, 0.92))
	# Garage bay doors facing the track (-X)
	for b_idx in range(-4, 5):
		var bz: float = float(b_idx) * 5.8
		_append_box_to_st(st, Vector3(-4.52, 1.8, bz), Vector3(0.15, 3.4, 4.2), Color(0.20, 0.24, 0.30))
	# Second floor VIP observation deck & tinted windows
	_append_box_to_st(st, Vector3(0.4, 6.6, 0.0), Vector3(8.2, 2.8, length_z * 0.92), Color(0.94, 0.95, 0.96))
	_append_box_to_st(st, Vector3(-3.75, 6.6, 0.0), Vector3(0.12, 1.6, length_z * 0.88), Color(0.12, 0.22, 0.35))
	# Red/Blue racing stripe fascia along roof
	_append_box_to_st(st, Vector3(-4.1, 5.2, 0.0), Vector3(1.2, 0.55, length_z), Color(0.86, 0.14, 0.14))
	# Race Control Tower
	_append_box_to_st(st, Vector3(0.0, 11.0, -length_z * 0.35), Vector3(7.5, 6.2, 9.5), Color(0.90, 0.92, 0.95))
	_append_box_to_st(st, Vector3(-3.8, 12.2, -length_z * 0.35), Vector3(0.15, 2.4, 8.2), Color(0.10, 0.20, 0.32))

	st.generate_normals()
	var mesh: ArrayMesh = st.commit()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.65
	mesh.surface_set_material(0, mat)

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	pit.add_child(mi)


func _build_tsukuba_grandstand(container: Node3D, pos: Vector3, forward_dir: Vector3, length_z: float) -> void:
	var stand: Node3D = Node3D.new()
	stand.name = "SpectatorGrandstand"
	stand.global_transform = Transform3D(Basis.looking_at(forward_dir, Vector3.UP), pos)
	container.add_child(stand)

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seat_colors: Array[Color] = [
		Color(0.90, 0.16, 0.16),
		Color(0.16, 0.44, 0.88),
		Color(0.96, 0.76, 0.12),
		Color(0.92, 0.94, 0.96)
	]
	for tier in range(6):
		var tx: float = -float(tier) * 1.45
		var ty: float = 0.65 + float(tier) * 0.95
		# Concrete riser
		_append_box_to_st(st, Vector3(tx, ty * 0.5, 0.0), Vector3(1.5, ty, length_z), Color(0.68, 0.70, 0.72))
		# Colorful spectator seating row
		var scol: Color = seat_colors[tier % seat_colors.size()]
		_append_box_to_st(st, Vector3(tx + 0.25, ty + 0.22, 0.0), Vector3(0.85, 0.38, length_z * 0.96), scol)



	# Cantilevered stadium canopy roof
	_append_box_to_st(st, Vector3(0.0, 8.2, 4.5), Vector3(62.0, 0.45, 10.5), Color(0.88, 0.90, 0.92))
	_append_box_to_st(st, Vector3(0.0, 8.5, -0.4), Vector3(62.4, 0.35, 0.8), Color(0.15, 0.35, 0.75))

	# Rear structural steel columns and cantilever beams supporting the canopy
	for col_idx in range(-3, 4):
		var col_x: float = float(col_idx) * 9.5
		_append_box_to_st(st, Vector3(col_x, 4.1, 8.8), Vector3(0.65, 8.2, 0.65), Color(0.32, 0.34, 0.38))
		_append_box_to_st(st, Vector3(col_x, 7.8, 5.2), Vector3(0.45, 0.45, 7.2), Color(0.32, 0.34, 0.38))

	st.generate_normals()
	var stand_mi := MeshInstance3D.new()
	stand_mi.name = "TsukubaGrandstand"
	stand_mi.mesh = st.commit()

	var stand_mat := StandardMaterial3D.new()
	stand_mat.vertex_color_use_as_albedo = true
	stand_mat.roughness = 0.82
	stand_mi.material_override = stand_mat

	var stand_right := forward_dir.cross(Vector3.UP).normalized()
	if stand_right.length_squared() < 0.001:
		stand_right = Vector3.RIGHT
	stand_mi.basis = Basis(forward_dir.normalized(), Vector3.UP, stand_right).orthonormalized()
	stand_mi.position = pos
	container.add_child(stand_mi)


func _build_tsukuba_dunlop_bridge(container: Node3D, s: RoadSample) -> void:
	var bridge_root := Node3D.new()
	bridge_root.name = "TsukubaDunlopBridge"

	var right_dir := s.right.normalized()
	var fwd_dir := s.forward.normalized()
	if right_dir.length_squared() < 0.001:
		right_dir = fwd_dir.cross(Vector3.UP).normalized()

	bridge_root.position = s.pos
	bridge_root.basis = Basis(right_dir, Vector3.UP, fwd_dir).orthonormalized()

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half_span: float = 9.8
	var bridge_height: float = 6.4
	var deck_depth: float = 3.2

	var yellow_col := Color(0.96, 0.78, 0.04)
	var black_col := Color(0.10, 0.10, 0.12)
	var steel_col := Color(0.38, 0.40, 0.44)
	var concrete_col := Color(0.62, 0.63, 0.65)

	# Left & Right reinforced concrete abutment foundations and steel towers
	for side_sign in [-1.0, 1.0]:
		var px: float = side_sign * half_span
		_append_box_to_st(st, Vector3(px, 1.2, 0.0), Vector3(2.2, 2.4, deck_depth + 0.6), concrete_col)
		_append_box_to_st(st, Vector3(px, 4.3, 0.0), Vector3(1.5, 4.2, deck_depth), yellow_col)
		_append_box_to_st(st, Vector3(px, 6.2, 0.0), Vector3(1.6, 0.5, deck_depth + 0.2), black_col)

	# Arched Dunlop tire profile span across the track
	var arch_segments: int = 10
	var total_span: float = half_span * 2.0 + 1.5
	var seg_width: float = total_span / float(arch_segments)

	for i in range(arch_segments):
		var t0: float = float(i) / float(arch_segments)
		var t1: float = float(i + 1) / float(arch_segments)
		var tm: float = (t0 + t1) * 0.5
		var x_center: float = -total_span * 0.5 + (float(i) + 0.5) * seg_width
		var arch_curve: float = sin(tm * PI) * 1.65

		# Lower walkway deck girder
		_append_box_to_st(st, Vector3(x_center, bridge_height, 0.0), Vector3(seg_width + 0.08, 0.55, deck_depth), steel_col)
		# Main yellow billboard arch fascia
		_append_box_to_st(st, Vector3(x_center, bridge_height + 0.95 + arch_curve * 0.5, 0.0), Vector3(seg_width + 0.05, 1.4 + arch_curve, deck_depth + 0.15), yellow_col)
		# Upper black tire tread arch cap
		_append_box_to_st(st, Vector3(x_center, bridge_height + 1.85 + arch_curve, 0.0), Vector3(seg_width + 0.1, 0.42, deck_depth + 0.3), black_col)
		# Lower black trim stripe
		_append_box_to_st(st, Vector3(x_center, bridge_height + 0.28, 0.0), Vector3(seg_width + 0.1, 0.25, deck_depth + 0.25), black_col)

	st.generate_normals()
	var bridge_mi := MeshInstance3D.new()
	bridge_mi.name = "DunlopBridgeMesh"
	bridge_mi.mesh = st.commit()

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.65
	mat.metallic = 0.15
	bridge_mi.material_override = mat
	bridge_root.add_child(bridge_mi)

	# Front & Back 3D "DUNLOP" Motorsport Signage
	for z_dir in [-1.0, 1.0]:
		var lbl := Label3D.new()
		lbl.text = "DUNLOP"
		lbl.font_size = 128
		lbl.pixel_size = 0.014
		lbl.modulate = Color(0.08, 0.08, 0.10)
		lbl.outline_modulate = Color(0.98, 0.98, 0.98)
		lbl.outline_size = 10
		lbl.position = Vector3(0.0, bridge_height + 1.45, z_dir * (deck_depth * 0.5 + 0.15))
		if z_dir < 0.0:
			lbl.rotation.y = PI
		bridge_root.add_child(lbl)

	container.add_child(bridge_root)


func _build_tsukuba_billboard(container: Node3D, pos: Vector3, fwd: Vector3, brand_name: String, custom_bg: Color = Color.WHITE) -> void:
	var bb_root := Node3D.new()
	bb_root.name = "Billboard_" + brand_name

	var right_dir := fwd.cross(Vector3.UP).normalized()
	if right_dir.length_squared() < 0.001:
		right_dir = Vector3.RIGHT

	bb_root.position = pos
	bb_root.basis = Basis(fwd.normalized(), Vector3.UP, right_dir).orthonormalized()

	var bg_col: Color = custom_bg if custom_bg != Color.WHITE else Color(0.92, 0.93, 0.95)
	var border_col: Color = Color(0.15, 0.16, 0.18)
	var text_col: Color = Color(0.10, 0.10, 0.12)

	var upper_brand := brand_name.to_upper()
	if upper_brand.contains("DUNLOP"):
		bg_col = Color(0.95, 0.78, 0.05)
		border_col = Color(0.10, 0.10, 0.12)
		text_col = Color(0.08, 0.08, 0.08)
	elif upper_brand.contains("ADVAN") or upper_brand.contains("YOKOHAMA"):
		bg_col = Color(0.12, 0.12, 0.14)
		border_col = Color(0.85, 0.12, 0.15)
		text_col = Color(0.95, 0.95, 0.95)
	elif upper_brand.contains("BRIDGESTONE") or upper_brand.contains("POTENZA"):
		bg_col = Color(0.86, 0.14, 0.16)
		border_col = Color(0.95, 0.95, 0.95)
		text_col = Color(0.98, 0.98, 0.98)
	elif upper_brand.contains("HKS") or upper_brand.contains("ENDLESS"):
		bg_col = Color(0.10, 0.28, 0.68)
		border_col = Color(0.92, 0.75, 0.10)
		text_col = Color(0.98, 0.98, 0.98)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var board_w: float = 7.6
	var board_h: float = 2.4
	var board_y: float = 3.2

	# Support legs and rear diagonal braces
	for side_x in [-2.6, 2.6]:
		_append_box_to_st(st, Vector3(side_x, 2.1, -0.15), Vector3(0.24, 4.2, 0.24), Color(0.35, 0.37, 0.40))
		_append_box_to_st(st, Vector3(side_x, 1.4, -0.95), Vector3(0.18, 2.8, 1.4), Color(0.30, 0.32, 0.35))

	# Outer frame and main sponsor face
	_append_box_to_st(st, Vector3(0.0, board_y, 0.0), Vector3(board_w + 0.3, board_h + 0.3, 0.22), border_col)
	_append_box_to_st(st, Vector3(0.0, board_y, 0.06), Vector3(board_w, board_h, 0.16), bg_col)

	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.72
	mi.material_override = mat
	bb_root.add_child(mi)

	var lbl := Label3D.new()
	lbl.text = brand_name
	lbl.font_size = 96
	lbl.pixel_size = 0.011
	lbl.modulate = text_col
	lbl.outline_size = 6
	lbl.outline_modulate = border_col
	lbl.position = Vector3(0.0, board_y, 0.18)
	bb_root.add_child(lbl)

	container.add_child(bb_root)


# ==============================================================================
# PROCEDURAL GEOMETRY & SURFACETOOL HELPERS
# ==============================================================================

func _append_box_to_st(st: SurfaceTool, center: Vector3, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	var c000 := center + Vector3(-h.x, -h.y, -h.z)
	var c100 := center + Vector3( h.x, -h.y, -h.z)
	var c110 := center + Vector3( h.x,  h.y, -h.z)
	var c010 := center + Vector3(-h.x,  h.y, -h.z)
	var c001 := center + Vector3(-h.x, -h.y,  h.z)
	var c101 := center + Vector3( h.x, -h.y,  h.z)
	var c111 := center + Vector3( h.x,  h.y,  h.z)
	var c011 := center + Vector3(-h.x,  h.y,  h.z)

	var c_up := color.lightened(0.08)
	var c_dn := color.darkened(0.18)
	var c_bk := color.darkened(0.06)
	var c_side := color.darkened(0.03)

	# Top (+Y)
	_add_quad(st, c010, c110, c111, c011, c_up, c_up, c_up, c_up)
	# Bottom (-Y)
	_add_quad(st, c001, c101, c100, c000, c_dn, c_dn, c_dn, c_dn)
	# Front (+Z)
	_add_quad(st, c011, c111, c101, c001, color, color, color, color)
	# Back (-Z)
	_add_quad(st, c110, c010, c000, c100, c_bk, c_bk, c_bk, c_bk)
	# Right (+X)
	_add_quad(st, c111, c110, c100, c101, c_side, c_side, c_side, c_side)
	# Left (-X)
	_add_quad(st, c010, c011, c001, c000, c_side, c_side, c_side, c_side)


func _add_quad(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, c0: Color, c1: Color, c2: Color, c3: Color) -> void:
	st.set_uv(Vector2(0.0, 0.0))
	st.set_color(c0)
	st.add_vertex(v0)

	st.set_uv(Vector2(1.0, 0.0))
	st.set_color(c1)
	st.add_vertex(v1)

	st.set_uv(Vector2(1.0, 1.0))
	st.set_color(c2)
	st.add_vertex(v2)

	st.set_uv(Vector2(0.0, 0.0))
	st.set_color(c0)
	st.add_vertex(v0)

	st.set_uv(Vector2(1.0, 1.0))
	st.set_color(c2)
	st.add_vertex(v2)

	st.set_uv(Vector2(0.0, 1.0))
	st.set_color(c3)
	st.add_vertex(v3)


func _add_quad_with_collision(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, c0: Color, c1: Color, c2: Color, c3: Color, faces: PackedVector3Array) -> void:
	_add_quad(st, v0, v1, v2, v3, c0, c1, c2, c3)
	faces.append(v0)
	faces.append(v1)
	faces.append(v2)
	faces.append(v0)
	faces.append(v2)
	faces.append(v3)


# ==============================================================================
# PROCEDURAL FOLIAGE & ROADSIDE PROP MESH GENERATORS
# ==============================================================================

func _create_cryptomeria_tree_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var trunk_col := Color(0.26, 0.16, 0.10)
	var radial_steps: int = 7

	# Tapered cedar trunk
	var trunk_h: float = 4.8
	var r_bot: float = 0.36
	var r_top: float = 0.14
	for i in range(radial_steps):
		var a0: float = (float(i) / float(radial_steps)) * TAU
		var a1: float = (float(i + 1) / float(radial_steps)) * TAU
		var p00 := Vector3(cos(a0) * r_bot, 0.0, sin(a0) * r_bot)
		var p10 := Vector3(cos(a1) * r_bot, 0.0, sin(a1) * r_bot)
		var p11 := Vector3(cos(a1) * r_top, trunk_h, sin(a1) * r_top)
		var p01 := Vector3(cos(a0) * r_top, trunk_h, sin(a0) * r_top)
		_add_quad(st, p01, p11, p10, p00, trunk_col, trunk_col, trunk_col, trunk_col)

	# 5 conical tiers of dark Mount Akina Cryptomeria needles
	var tier_bases := [2.2, 4.0, 5.8, 7.5, 9.1]
	var tier_heights := [3.0, 2.8, 2.6, 2.4, 2.3]
	var tier_radii := [2.4, 2.0, 1.6, 1.2, 0.8]

	for t in range(tier_bases.size()):
		var y0: float = float(tier_bases[t])
		var th: float = float(tier_heights[t])
		var rad: float = float(tier_radii[t])
		var apex := Vector3(0.0, y0 + th, 0.0)
		var needle_col: Color = Color(0.07, 0.20, 0.10).lightened(float(t) * 0.03)

		for i in range(radial_steps):
			var a0: float = (float(i) / float(radial_steps)) * TAU + float(t) * 0.4
			var a1: float = (float(i + 1) / float(radial_steps)) * TAU + float(t) * 0.4
			var b0 := Vector3(cos(a0) * rad, y0, sin(a0) * rad)
			var b1 := Vector3(cos(a1) * rad, y0, sin(a1) * rad)

			st.set_color(needle_col)
			st.add_vertex(apex)
			st.add_vertex(b1)
			st.add_vertex(b0)

	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.90
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


func _create_autumn_tree_mesh(bark_col: Color, color: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Main Momiji trunk and secondary branches
	_append_box_to_st(st, Vector3(0.0, 1.8, 0.0), Vector3(0.42, 3.6, 0.42), bark_col)
	_append_box_to_st(st, Vector3(0.65, 3.4, 0.25), Vector3(1.1, 0.24, 0.24), bark_col)
	_append_box_to_st(st, Vector3(-0.6, 3.7, -0.3), Vector3(1.0, 0.22, 0.22), bark_col)

	# Multi-lobe autumn maple foliage clusters
	var cluster_centers := [
		Vector3(0.0, 5.4, 0.0),
		Vector3(1.25, 4.4, 0.45),
		Vector3(-1.15, 4.6, -0.4),
		Vector3(0.45, 4.8, -1.05),
		Vector3(-0.5, 4.3, 1.0)
	]
	var cluster_radii := [2.1, 1.55, 1.6, 1.45, 1.4]

	for c_idx in range(cluster_centers.size()):
		var c_pos: Vector3 = cluster_centers[c_idx]
		var r: float = float(cluster_radii[c_idx])
		var shade: Color = color.lightened(float(c_idx % 3) * 0.06) if c_idx % 2 == 0 else color.darkened(0.08)

		var top_pt := c_pos + Vector3(0.0, r * 0.85, 0.0)
		var bot_pt := c_pos - Vector3(0.0, r * 0.65, 0.0)
		var segs: int = 6

		for i in range(segs):
			var a0: float = (float(i) / float(segs)) * TAU
			var a1: float = (float(i + 1) / float(segs)) * TAU
			var eq0 := c_pos + Vector3(cos(a0) * r, 0.0, sin(a0) * r)
			var eq1 := c_pos + Vector3(cos(a1) * r, 0.0, sin(a1) * r)

			# Upper dome face
			st.set_color(shade.lightened(0.05))
			st.add_vertex(top_pt)
			st.add_vertex(eq1)
			st.add_vertex(eq0)

			# Lower dome face
			st.set_color(shade.darkened(0.12))
			st.add_vertex(bot_pt)
			st.add_vertex(eq0)
			st.add_vertex(eq1)

	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.86
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


func _create_crimson_shrub_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var lobes := [
		Vector3(0.0, 0.55, 0.0),
		Vector3(0.45, 0.42, 0.30),
		Vector3(-0.42, 0.40, -0.25)
	]
	var radii := [0.85, 0.65, 0.62]
	var colors := [
		Color(0.72, 0.12, 0.09),
		Color(0.82, 0.22, 0.10),
		Color(0.60, 0.09, 0.08)
	]

	for l_idx in range(lobes.size()):
		var center: Vector3 = lobes[l_idx]
		var r: float = float(radii[l_idx])
		var col: Color = colors[l_idx]
		var apex := center + Vector3(0.0, r * 0.75, 0.0)
		var base_y: float = 0.0
		var segs: int = 6

		for i in range(segs):
			var a0: float = (float(i) / float(segs)) * TAU
			var a1: float = (float(i + 1) / float(segs)) * TAU
			var p0 := Vector3(center.x + cos(a0) * r, base_y, center.z + sin(a0) * r)
			var p1 := Vector3(center.x + cos(a1) * r, base_y, center.z + sin(a1) * r)

			st.set_color(col)
			st.add_vertex(apex)
			st.add_vertex(p1)
			st.add_vertex(p0)

	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.90
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


func _create_rockfall_net_panel_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var post_col := Color(0.46, 0.49, 0.52)
	var wire_col := Color(0.58, 0.61, 0.65)
	var panel_w: float = 4.0
	var panel_h: float = 3.2

	# Steel H-beam vertical posts and horizontal tension cables
	_append_box_to_st(st, Vector3(-panel_w * 0.5, panel_h * 0.5, 0.0), Vector3(0.14, panel_h, 0.14), post_col)
	_append_box_to_st(st, Vector3( panel_w * 0.5, panel_h * 0.5, 0.0), Vector3(0.14, panel_h, 0.14), post_col)
	_append_box_to_st(st, Vector3(0.0, panel_h - 0.08, 0.0), Vector3(panel_w, 0.07, 0.07), post_col)
	_append_box_to_st(st, Vector3(0.0, 0.35, 0.0), Vector3(panel_w, 0.07, 0.07), post_col)

	# Wire mesh grid bars
	for h_idx in range(1, 5):
		var y_pos: float = float(h_idx) * (panel_h / 5.0)
		_append_box_to_st(st, Vector3(0.0, y_pos, 0.0), Vector3(panel_w, 0.03, 0.03), wire_col)

	for v_idx in range(-3, 4):
		var x_pos: float = float(v_idx) * 0.52
		_append_box_to_st(st, Vector3(x_pos, panel_h * 0.5, 0.0), Vector3(0.03, panel_h - 0.2, 0.03), wire_col)

	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.metallic = 0.55
	mat.roughness = 0.45
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


func _create_catch_fence_panel_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var pole_col := Color(0.52, 0.55, 0.58)
	var mesh_col := Color(0.66, 0.69, 0.72)
	var panel_w: float = 6.0
	var panel_h: float = 2.8

	# End poles + middle support pole + FIA top debris overhang arm
	for px in [-panel_w * 0.5, 0.0, panel_w * 0.5]:
		_append_box_to_st(st, Vector3(px, panel_h * 0.5, 0.0), Vector3(0.11, panel_h, 0.11), pole_col)
		_append_box_to_st(st, Vector3(px, panel_h + 0.25, 0.22), Vector3(0.09, 0.6, 0.45), pole_col)

	# Horizontal high-tensile FIA catch cables
	for row in range(6):
		var ry: float = 0.35 + float(row) * 0.46
		_append_box_to_st(st, Vector3(0.0, ry, 0.0), Vector3(panel_w, 0.035, 0.035), mesh_col)

	# Vertical wire mesh pickets
	for col in range(-5, 6):
		var cx: float = float(col) * 0.52
		_append_box_to_st(st, Vector3(cx, panel_h * 0.5, 0.0), Vector3(0.025, panel_h - 0.15, 0.025), mesh_col)

	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.metallic = 0.50
	mat.roughness = 0.42
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


# ==============================================================================
# SPATIAL CLEARANCE & MULTIMESH BATCHING HELPERS
# ==============================================================================

func _is_point_clear_of_road(pt: Vector3, samples: Array[RoadSample], min_dist: float) -> bool:
	var min_dist_sq: float = min_dist * min_dist
	for s in samples:
		var dx: float = pt.x - s.pos.x
		var dz: float = pt.z - s.pos.z
		if (dx * dx + dz * dz) < min_dist_sq:
			return false
	return true


func _add_multimesh_batch(container: Node3D, batch_name: String, mesh: Mesh, transforms: Array[Transform3D], colors: Array[Color] = []) -> void:
	if transforms.is_empty() or mesh == null:
		return

	var mmi := MultiMeshInstance3D.new()
	mmi.name = batch_name

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	if not colors.is_empty():
		mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = transforms.size()

	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
		if not colors.is_empty() and i < colors.size():
			mm.set_instance_color(i, colors[i])

	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	container.add_child(mmi)
