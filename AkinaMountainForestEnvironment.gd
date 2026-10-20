# ==============================================================================
# AkinaMountainForestEnvironment.gd
# Lead Technical Artist & Procedural World Architect - Godot 4.3 (Vulkan Forward+)
# Project: ShiTmoZ/RACING (Mount Akina Touge)
# ==============================================================================
# Complete procedural mountain environment generator, custom triplanar terrain
# shader, GPU-instanced Cedar & Sakura forests with wind sway, drifting Sakura
# petal particle fields, and calibrated twilight horizon atmosphere.
# ==============================================================================
@tool
class_name AkinaMountainForestEnvironment
extends Node3D

# ------------------------------------------------------------------------------
# EXPORTED CONFIGURATION
# ------------------------------------------------------------------------------
@export_group("Integration & Spline")
## Optional direct reference to a Path3D node. If empty, auto-discovers parent MountAkinaTouge data.
@export var road_path_node: Path3D
## Half-width of the asphalt + shoulder corridor where terrain flattens and trees are excluded.
@export var road_corridor_half_width: float = 11.5
## Width of the smooth hermite blending zone between the road shoulder and steep mountain slope.
@export var shoulder_blend_width: float = 38.0
## Vertical offset underneath the road center to prevent Z-fighting with road meshes.
@export var road_bed_depth_offset: float = -0.35

@export_group("Terrain & Valley Architecture")
@export var world_radius: float = 1050.0
@export var chunk_grid_count: int = 8
@export var chunk_subdivisions: int = 44
@export var mountain_peak_relief: float = 185.0
@export var cliff_cut_intensity: float = 28.0
@export var generate_terrain_collision: bool = true

@export_group("Foliage & MultiMesh Instancing")
@export var pine_instance_count: int = 9500
@export var sakura_instance_count: int = 1600
@export var roadside_guard_bush_count: int = 3200
@export var foliage_visibility_range: float = 950.0

@export_group("Atmosphere & Camera Calibration")
@export var target_camera_far_plane: float = 4000.0
@export var volumetric_fog_density: float = 0.0014
@export var horizon_dusk_intensity: float = 1.18
@export var enable_sakura_petal_particles: bool = true

@export_group("Editor Actions")
@export var rebuild_environment_trigger: bool = false:
	set(val):
		if val:
			rebuild_environment_trigger = false
			if is_inside_tree():
				build_complete_environment()

# ------------------------------------------------------------------------------
# INTERNAL STATE & CACHES
# ------------------------------------------------------------------------------
var _baked_spline_points: PackedVector3Array = PackedVector3Array()
var _baked_spline_tangents: PackedVector3Array = PackedVector3Array()
var _baked_spline_up_vectors: PackedVector3Array = PackedVector3Array()
var _baked_cumulative_distances: PackedFloat32Array = PackedFloat32Array()
var _detected_hairpin_centers: PackedVector3Array = PackedVector3Array()

var _spatial_grid: Dictionary = {}
const SPATIAL_CELL_SIZE: float = 40.0

var _bounds_min: Vector3 = Vector3(-900.0, -250.0, -900.0)
var _bounds_max: Vector3 = Vector3(900.0, 450.0, 900.0)
var _summit_point: Vector3 = Vector3(0.0, 260.0, 0.0)
var _valley_base_point: Vector3 = Vector3(0.0, -40.0, 0.0)

var _macro_noise: FastNoiseLite
var _ridge_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _forest_density_noise: FastNoiseLite

var _terrain_material: ShaderMaterial
var _pine_trunk_material: ShaderMaterial
var _pine_needle_material: ShaderMaterial
var _sakura_trunk_material: ShaderMaterial
var _sakura_blossom_material: ShaderMaterial
var _bush_material: ShaderMaterial

var _generated_root: Node3D
var _camera_sync_timer: float = 0.0

# ------------------------------------------------------------------------------
# LIFECYCLE
# ------------------------------------------------------------------------------
func _ready() -> void:
	_init_noise_generators()
	build_complete_environment()

func _process(delta: float) -> void:
	_camera_sync_timer += delta
	if _camera_sync_timer >= 1.25:
		_camera_sync_timer = 0.0
		_calibrate_active_cameras()

# ------------------------------------------------------------------------------
# MASTER BUILD PIPELINE
# ------------------------------------------------------------------------------
func build_complete_environment() -> void:
	_init_noise_generators()
	_clear_previous_build()

	_generated_root = Node3D.new()
	_generated_root.name = "GeneratedAkinaEnvironment"
	add_child(_generated_root)

	# 1. Extract or synthesize the 3.5km Mount Akina spline
	_extract_or_build_akina_spline()
	_build_spatial_acceleration_grid()
	_analyze_track_landmarks()

	# 2. Compile procedural shaders (Terrain, Wind-Sway Foliage, Sky, Petals)
	_compile_environment_materials()

	# 3. Generate chunked mountain terrain & valley meshes with cliff cuts
	_build_chunked_mountain_terrain()

	# 4. Populate MultiMesh3D Japanese Cedar/Pine & Sakura forests
	_build_foliage_multimeshes()

	# 5. Spawn drifting Sakura petal GPU particle emitters around hairpins & summit
	if enable_sakura_petal_particles:
		_build_sakura_petal_emitters()

	# 6. Configure WorldEnvironment, Distant Ridge Skybox, Directional Twilight & Fog
	_build_atmosphere_and_lighting()

	# 7. Calibrate active Camera3D far plane so distant hairpins & mountains never clip
	_calibrate_active_cameras()

# ------------------------------------------------------------------------------
# NOISE & PROCEDURAL GEOLOGY SETUP
# ------------------------------------------------------------------------------
func _init_noise_generators() -> void:
	_macro_noise = FastNoiseLite.new()
	_macro_noise.seed = 1986086 # Trueno AE86 homage seed
	_macro_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_macro_noise.frequency = 0.00095
	_macro_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_macro_noise.fractal_octaves = 4
	_macro_noise.fractal_lacunarity = 2.05
	_macro_noise.fractal_gain = 0.48

	_ridge_noise = FastNoiseLite.new()
	_ridge_noise.seed = 42086
	_ridge_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	_ridge_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	_ridge_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	_ridge_noise.frequency = 0.0021
	_ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridge_noise.fractal_octaves = 3

	_detail_noise = FastNoiseLite.new()
	_detail_noise.seed = 99123
	_detail_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_detail_noise.frequency = 0.016
	_detail_noise.fractal_octaves = 3

	_forest_density_noise = FastNoiseLite.new()
	_forest_density_noise.seed = 77341
	_forest_density_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_forest_density_noise.frequency = 0.0065

func _clear_previous_build() -> void:
	if is_instance_valid(_generated_root):
		_generated_root.queue_free()
		_generated_root = null
	for child in get_children():
		if child.name.begins_with("GeneratedAkina"):
			child.queue_free()

# ------------------------------------------------------------------------------
# SPLINE EXTRACTION & 3.5KM AKINA FALLBACK GENERATOR
# ------------------------------------------------------------------------------
func _extract_or_build_akina_spline() -> void:
	_baked_spline_points.clear()
	_baked_spline_tangents.clear()
	_baked_spline_up_vectors.clear()
	_baked_cumulative_distances.clear()

	var raw_points: PackedVector3Array = _discover_track_points_from_scene()

	var curve := Curve3D.new()
	curve.bake_interval = 3.5

	if raw_points.size() >= 4:
		for i in range(raw_points.size()):
			var pt: Vector3 = raw_points[i]
			var prev_pt: Vector3 = raw_points[max(0, i - 1)]
			var next_pt: Vector3 = raw_points[min(raw_points.size() - 1, i + 1)]
			var tangent_dir: Vector3 = (next_pt - prev_pt) * 0.22
			curve.add_point(pt, -tangent_dir, tangent_dir)
	else:
		# Fallback: Procedural 3.5km Mount Akina Downhill Touge with 5 Iconic Hairpins
		var total_segments: int = 180
		var cur_pos := Vector3(0.0, 285.0, 0.0)
		var heading: float = 0.0
		var step_length: float = 19.5 # ~3,510 meters total

		for i in range(total_segments):
			var t: float = float(i) / float(total_segments - 1)
			# Iconic 5 consecutive hairpins between 32% and 78% of the run
			var hairpin_zone: float = smoothstep(0.22, 0.28, t) * (1.0 - smoothstep(0.78, 0.84, t))
			var freq: float = lerp(4.2, 5.0 * PI, hairpin_zone)
			var turn_rate: float = sin(t * freq * 2.0) * lerp(0.32, 1.35, hairpin_zone)
			turn_rate += cos(t * 7.5) * 0.18
			heading += turn_rate * 0.35

			var forward := Vector3(sin(heading), 0.0, cos(heading))
			var slope_drop: float = lerp(1.65, 2.15, hairpin_zone)
			cur_pos += forward * step_length
			cur_pos.y -= slope_drop
			curve.add_point(cur_pos)

	var baked: PackedVector3Array = curve.get_baked_points()
	var total_dist: float = 0.0

	for i in range(baked.size()):
		var p: Vector3 = baked[i]
		if i > 0:
			var dist_step: float = p.distance_to(baked[i - 1])
			if dist_step < 0.05:
				continue
			total_dist += dist_step

		_baked_spline_points.append(p)
		_baked_cumulative_distances.append(total_dist)

	var count: int = _baked_spline_points.size()
	for i in range(count):
		var p_prev: Vector3 = _baked_spline_points[max(0, i - 1)]
		var p_next: Vector3 = _baked_spline_points[min(count - 1, i + 1)]
		var tangent: Vector3 = (p_next - p_prev).normalized()
		if tangent.length_squared() < 0.01:
			tangent = Vector3.FORWARD
		_baked_spline_tangents.append(tangent)
		_baked_spline_up_vectors.append(Vector3.UP)

func _discover_track_points_from_scene() -> PackedVector3Array:
	# 1. Explicit Path3D export
	if is_instance_valid(road_path_node) and is_instance_valid(road_path_node.curve):
		if road_path_node.curve.point_count >= 2:
			var pts: PackedVector3Array = road_path_node.curve.get_baked_points()
			var xformed := PackedVector3Array()
			for p in pts:
				xformed.append(road_path_node.to_global(p) - global_position)
			return xformed

	# 2. Inspect parent or sibling (MountAkinaTouge.gd compatibility)
	var candidates: Array[Node] = []
	if get_parent():
		candidates.append(get_parent())
		for sibling in get_parent().get_children():
			if sibling != self:
				candidates.append(sibling)

	var property_names: Array[String] = [
		"track_points", "waypoints", "spline_points", "road_points",
		"curve_points", "centerline", "baked_points", "path_points"
	]

	for node in candidates:
		if not is_instance_valid(node):
			continue
		if node is Path3D and is_instance_valid(node.curve) and node.curve.point_count >= 2:
			return node.curve.get_baked_points()
		if "curve" in node and node.get("curve") is Curve3D:
			var c: Curve3D = node.get("curve")
			if c.point_count >= 2:
				return c.get_baked_points()

		for prop in property_names:
			if prop in node:
				var val = node.get(prop)
				if val is PackedVector3Array and val.size() >= 4:
					return val
				elif val is Array and val.size() >= 4 and val[0] is Vector3:
					var converted := PackedVector3Array()
					for v in val:
						converted.append(v)
					return converted

		if node.has_method("get_road_points"):
			var res = node.call("get_road_points")
			if res is PackedVector3Array and res.size() >= 4:
				return res
		if node.has_method("get_waypoints"):
			var res = node.call("get_waypoints")
			if res is PackedVector3Array and res.size() >= 4:
				return res

	return PackedVector3Array()

# ------------------------------------------------------------------------------
# SPATIAL HASH GRID & LANDMARK ANALYSIS
# ------------------------------------------------------------------------------
func _build_spatial_acceleration_grid() -> void:
	_spatial_grid.clear()
	if _baked_spline_points.is_empty():
		return

	_bounds_min = _baked_spline_points[0]
	_bounds_max = _baked_spline_points[0]

	for i in range(_baked_spline_points.size()):
		var pt: Vector3 = _baked_spline_points[i]
		_bounds_min = _bounds_min.min(pt)
		_bounds_max = _bounds_max.max(pt)

		var cell := Vector2i(
			int(floor(pt.x / SPATIAL_CELL_SIZE)),
			int(floor(pt.z / SPATIAL_CELL_SIZE))
		)
		if not _spatial_grid.has(cell):
			_spatial_grid[cell] = PackedInt32Array()
		_spatial_grid[cell].append(i)

	_summit_point = _baked_spline_points[0]
	_valley_base_point = _baked_spline_points[_baked_spline_points.size() - 1]

	# Expand bounding box by world_radius to guarantee zero empty horizon voids
	_bounds_min -= Vector3(world_radius, 320.0, world_radius)
	_bounds_max += Vector3(world_radius, 350.0, world_radius)

func _analyze_track_landmarks() -> void:
	_detected_hairpin_centers.clear()
	var count: int = _baked_spline_points.size()
	if count < 12:
		return

	var last_hairpin_idx: int = -20
	for i in range(5, count - 5):
		var t_before: Vector3 = _baked_spline_tangents[i - 4]
		var t_after: Vector3 = _baked_spline_tangents[i + 4]
		var flat_before := Vector2(t_before.x, t_before.z).normalized()
		var flat_after := Vector2(t_after.x, t_after.z).normalized()
		var dot_val: float = flat_before.dot(flat_after)

		# Sharp curvature inflection indicates a Touge hairpin apex
		if dot_val < 0.35 and (i - last_hairpin_idx) > 14:
			_detected_hairpin_centers.append(_baked_spline_points[i])
			last_hairpin_idx = i

	# Guarantee at least several scenic Sakura spots along the course
	if _detected_hairpin_centers.size() < 3:
		var step: int = max(1, count / 6)
		for idx in range(step, count - step, step):
			_detected_hairpin_centers.append(_baked_spline_points[idx])

## Queries the closest point on the 3.5km Touge spline in 2D (XZ) using the spatial hash grid.
## Returns Dictionary: { "index": int, "dist_xz": float, "point": Vector3, "side_sign": float, "t_progress": float }
func _query_closest_road_point(wx: float, wz: float) -> Dictionary:
	var base_cell := Vector2i(
		int(floor(wx / SPATIAL_CELL_SIZE)),
		int(floor(wz / SPATIAL_CELL_SIZE))
	)

	var best_idx: int = 0
	var best_dist_sq: float = INF

	# Search local 5x5 cell neighborhood first (200m x 200m window)
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			var check_cell := Vector2i(base_cell.x + dx, base_cell.y + dz)
			if _spatial_grid.has(check_cell):
				var indices: PackedInt32Array = _spatial_grid[check_cell]
				for idx in indices:
					var sp: Vector3 = _baked_spline_points[idx]
					var d_sq: float = (wx - sp.x) * (wx - sp.x) + (wz - sp.z) * (wz - sp.z)
					if d_sq < best_dist_sq:
						best_dist_sq = d_sq
						best_idx = idx

	# If outside local neighborhood, stride-sample the spline and refine locally
	if best_dist_sq == INF:
		var count: int = _baked_spline_points.size()
		var stride: int = 8
		for i in range(0, count, stride):
			var sp: Vector3 = _baked_spline_points[i]
			var d_sq: float = (wx - sp.x) * (wx - sp.x) + (wz - sp.z) * (wz - sp.z)
			if d_sq < best_dist_sq:
				best_dist_sq = d_sq
				best_idx = i

		var refine_start: int = max(0, best_idx - stride)
		var refine_end: int = min(count - 1, best_idx + stride)
		for i in range(refine_start, refine_end + 1):
			var sp: Vector3 = _baked_spline_points[i]
			var d_sq: float = (wx - sp.x) * (wx - sp.x) + (wz - sp.z) * (wz - sp.z)
			if d_sq < best_dist_sq:
				best_dist_sq = d_sq
				best_idx = i

	# Sub-segment linear projection for smooth road corridor carving
	var p_best: Vector3 = _baked_spline_points[best_idx]
	var tangent: Vector3 = _baked_spline_tangents[best_idx]
	var flat_tan := Vector2(tangent.x, tangent.z).normalized()
	var to_pos := Vector2(wx - p_best.x, wz - p_best.z)

	var proj_along: float = to_pos.dot(flat_tan)
	var interp_y: float = p_best.y + tangent.y * clamp(proj_along, -3.5, 3.5)
	var interp_pos := Vector3(
		p_best.x + flat_tan.x * clamp(proj_along, -3.5, 3.5),
		interp_y,
		p_best.z + flat_tan.y * clamp(proj_along, -3.5, 3.5)
	)

	var right_vec := Vector2(-flat_tan.y, flat_tan.x)
	var lateral_offset: float = to_pos.dot(right_vec)
	var side_sign: float = 1.0 if lateral_offset >= 0.0 else -1.0
	var exact_dist_xz: float = Vector2(wx - interp_pos.x, wz - interp_pos.z).length()
	var total_len: float = max(1.0, _baked_cumulative_distances[_baked_cumulative_distances.size() - 1])
	var t_prog: float = _baked_cumulative_distances[best_idx] / total_len

	return {
		"index": best_idx,
		"dist_xz": exact_dist_xz,
		"point": interp_pos,
		"side_sign": side_sign,
		"t_progress": t_prog
	}

# ------------------------------------------------------------------------------
# PROCEDURAL MOUNTAIN HEIGHT & CLIFF/VALLEY SCULPTING
# ------------------------------------------------------------------------------
## Returns Vector2(height_y, road_distance_xz)
func _evaluate_mountain_surface(wx: float, wz: float) -> Vector2:
	var road_info: Dictionary = _query_closest_road_point(wx, wz)
	var road_pt: Vector3 = road_info["point"]
	var dist_xz: float = road_info["dist_xz"]
	var side_sign: float = road_info["side_sign"]
	var t_prog: float = road_info["t_progress"]

	# 1. Macro Mountain Mass & Distant Horizon Peaks
	var macro_n: float = _macro_noise.get_noise_2d(wx, wz)
	var ridge_n: float = abs(_ridge_noise.get_noise_2d(wx, wz))
	var detail_n: float = _detail_noise.get_noise_2d(wx, wz)

	# Determine which side of the road is the inner rock cliff vs outer deep valley
	# Alternate gently with low-frequency mountain massif orientation while keeping consistent gorge walls
	var massif_polarity: float = sign(sin(t_prog * PI * 1.5 + 0.4))
	if massif_polarity == 0.0:
		massif_polarity = 1.0
	var is_upslope_cliff_side: float = side_sign * massif_polarity

	# Base elevation anchored to the nearest road spine elevation so switchbacks sit in carved benches
	var base_spine_y: float = road_pt.y

	# Roadside geological cut: Upslope rises steeply into basalt cliff; Downslope drops into pine ravine
	var near_slope_profile: float = 0.0
	var road_edge_dist: float = max(0.0, dist_xz - road_corridor_half_width)

	if is_upslope_cliff_side > 0.0:
		# Steep cliff wall rising beside the touge inner lane
		var cliff_rise: float = pow(clamp(road_edge_dist / 95.0, 0.0, 2.5), 0.82) * cliff_cut_intensity * 3.1
		near_slope_profile = cliff_rise + ridge_n * 38.0
	else:
		# Steep ravine drop-off outside the guardrail, transitioning into a deep valley floor
		var valley_drop: float = -pow(clamp(road_edge_dist / 120.0, 0.0, 2.2), 0.9) * cliff_cut_intensity * 2.7
		near_slope_profile = valley_drop - (1.0 - ridge_n) * 24.0

	# Far mountain range envelope (200m to 1100m+ out): surrounds the entire valley with high Gunma peaks
	var far_range_blend: float = smoothstep(85.0, 520.0, dist_xz)
	var outer_ring_boost: float = smoothstep(420.0, 980.0, dist_xz) * 145.0
	var natural_mountain_y: float = (
		base_spine_y
		+ near_slope_profile
		+ (macro_n * mountain_peak_relief + ridge_n * 95.0) * far_range_blend
		+ outer_ring_boost
		+ detail_n * 5.5
	)

	# Smooth Hermite road-corridor carving:
	# Directly underneath the road (dist_xz <= road_corridor_half_width), terrain locks smoothly
	# just beneath the asphalt bed so there is zero floating road and zero Z-fighting.
	var road_bed_y: float = road_pt.y + road_bed_depth_offset
	var shoulder_factor: float = smoothstep(
		road_corridor_half_width,
		road_corridor_half_width + shoulder_blend_width,
		dist_xz
	)
	# Apply an extra ease-in curve near the guardrail so the shoulder meets the asphalt level cleanly
	var carved_y: float = lerp(road_bed_y, natural_mountain_y, shoulder_factor * shoulder_factor * (3.0 - 2.0 * shoulder_factor))

	return Vector2(carved_y, dist_xz)

func _calculate_surface_normal(wx: float, wz: float) -> Vector3:
	var eps: float = 1.75
	var h_L: float = _evaluate_mountain_surface(wx - eps, wz).x
	var h_R: float = _evaluate_mountain_surface(wx + eps, wz).x
	var h_D: float = _evaluate_mountain_surface(wx, wz - eps).x
	var h_U: float = _evaluate_mountain_surface(wx, wz + eps).x
	return Vector3(h_L - h_R, 2.0 * eps, h_D - h_U).normalized()

# ------------------------------------------------------------------------------
# 1. CHUNKED MOUNTAIN TERRAIN & VALLEY MESH GENERATION
# ------------------------------------------------------------------------------
func _build_chunked_mountain_terrain() -> void:
	var terrain_root := Node3D.new()
	terrain_root.name = "MountainTerrainChunks"
	_generated_root.add_child(terrain_root)

	var total_span_x: float = _bounds_max.x - _bounds_min.x
	var total_span_z: float = _bounds_max.z - _bounds_min.z
	var chunk_size_x: float = total_span_x / float(chunk_grid_count)
	var chunk_size_z: float = total_span_z / float(chunk_grid_count)

	for cx in range(chunk_grid_count):
		for cz in range(chunk_grid_count):
			var origin_x: float = _bounds_min.x + float(cx) * chunk_size_x
			var origin_z: float = _bounds_min.z + float(cz) * chunk_size_z
			var chunk_mesh_inst: MeshInstance3D = _generate_single_terrain_chunk(
				origin_x, origin_z, chunk_size_x, chunk_size_z, cx, cz
			)
			terrain_root.add_child(chunk_mesh_inst)

func _generate_single_terrain_chunk(
	origin_x: float,
	origin_z: float,
	size_x: float,
	size_z: float,
	cx: int,
	cz: int
) -> MeshInstance3D:
	var verts_per_side: int = chunk_subdivisions + 1
	var total_verts: int = verts_per_side * verts_per_side

	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	positions.resize(total_verts)
	normals.resize(total_verts)
	uvs.resize(total_verts)
	colors.resize(total_verts)

	var step_x: float = size_x / float(chunk_subdivisions)
	var step_z: float = size_z / float(chunk_subdivisions)

	# Sample heightfield grid
	for gz in range(verts_per_side):
		var wz: float = origin_z + float(gz) * step_z
		for gx in range(verts_per_side):
			var wx: float = origin_x + float(gx) * step_x
			var idx: int = gz * verts_per_side + gx

			var eval: Vector2 = _evaluate_mountain_surface(wx, wz)
			var wy: float = eval.x
			var road_dist: float = eval.y

			positions[idx] = Vector3(wx, wy, wz)
			uvs[idx] = Vector2(wx * 0.05, wz * 0.05)

			# Vertex Color encoding for the Triplanar Shader:
			# R = Road Shoulder Proximity (gravel/retaining concrete blend)
			# G = High-Altitude Mist/Moisture factor
			# B = Valley Floor / Ravine wetness
			var road_shoulder_mask: float = 1.0 - smoothstep(
				road_corridor_half_width - 1.5,
				road_corridor_half_width + 7.5,
				road_dist
			)
			var altitude_factor: float = clamp((wy - _valley_base_point.y) / 320.0, 0.0, 1.0)
			var ravine_wetness: float = 1.0 - altitude_factor
			colors[idx] = Color(road_shoulder_mask, altitude_factor, ravine_wetness, 1.0)

	# Compute smooth analytical & grid normals
	for gz in range(verts_per_side):
		for gx in range(verts_per_side):
			var idx: int = gz * verts_per_side + gx
			var x_prev: int = max(0, gx - 1)
			var x_next: int = min(chunk_subdivisions, gx + 1)
			var z_prev: int = max(0, gz - 1)
			var z_next: int = min(chunk_subdivisions, gz + 1)

			var p_L: Vector3 = positions[gz * verts_per_side + x_prev]
			var p_R: Vector3 = positions[gz * verts_per_side + x_next]
			var p_D: Vector3 = positions[z_prev * verts_per_side + gx]
			var p_U: Vector3 = positions[z_next * verts_per_side + gx]

			var dx_vec: Vector3 = p_R - p_L
			var dz_vec: Vector3 = p_U - p_D
			var n: Vector3 = dz_vec.cross(dx_vec).normalized()
			if n.y < 0.0:
				n = -n
			normals[idx] = n

	# Build triangle index buffer
	indices.resize(chunk_subdivisions * chunk_subdivisions * 6)
	var ptr: int = 0
	for gz in range(chunk_subdivisions):
		for gx in range(chunk_subdivisions):
			var i00: int = gz * verts_per_side + gx
			var i10: int = i00 + 1
			var i01: int = (gz + 1) * verts_per_side + gx
			var i11: int = i01 + 1

			indices[ptr] = i00
			indices[ptr + 1] = i10
			indices[ptr + 2] = i01

			indices[ptr + 3] = i10
			indices[ptr + 4] = i11
			indices[ptr + 5] = i01
			ptr += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	arr_mesh.surface_set_material(0, _terrain_material)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "AkinaChunk_%d_%d" % [cx, cz]
	mesh_inst.mesh = arr_mesh
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mesh_inst.gi_mode = GeometryInstance3D.GI_MODE_STATIC

	if generate_terrain_collision:
		var static_body := StaticBody3D.new()
		static_body.name = "ChunkCollider"
		var col_shape := CollisionShape3D.new()
		col_shape.shape = arr_mesh.create_trimesh_shape()
		static_body.add_child(col_shape)
		mesh_inst.add_child(static_body)

	return mesh_inst

# ------------------------------------------------------------------------------
# 2. CUSTOM SHADERS (TRIPLANAR MOUNTAIN, WIND-SWAY FOLIAGE, SKY)
# ------------------------------------------------------------------------------
func _compile_environment_materials() -> void:
	# --- A. Triplanar Mountain Terrain Shader (Steep >45 deg Wet Basalt vs <45 deg Forest Moss) ---
	var terrain_shader := Shader.new()
	terrain_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

varying vec3 v_world_pos;
varying vec3 v_world_normal;
varying vec4 v_vert_color;

// Procedural 3D hash & value noise for zero-texture-dependency triplanar synthesis
float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise3d(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash31(i + vec3(0,0,0)), hash31(i + vec3(1,0,0)), f.x),
			mix(hash31(i + vec3(0,1,0)), hash31(i + vec3(1,1,0)), f.x), f.y),
		mix(mix(hash31(i + vec3(0,0,1)), hash31(i + vec3(1,0,1)), f.x),
			mix(hash31(i + vec3(0,1,1)), hash31(i + vec3(1,1,1)), f.x), f.y),
		f.z
	);
}

float fbm3d(vec3 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += amp * noise3d(p);
		p = p * 2.07 + vec3(13.7, 9.2, 17.4);
		amp *= 0.5;
	}
	return v;
}

// Triplanar rock fracture & strata sampler
float sample_triplanar_strata(vec3 wpos, vec3 wnorm, float scale) {
	vec3 blend = pow(abs(wnorm), vec3(4.0));
	blend /= max(dot(blend, vec3(1.0)), 0.0001);

	float xy = fbm3d(vec3(wpos.xy * scale, wpos.y * scale * 2.4));
	float yz = fbm3d(vec3(wpos.yz * scale, wpos.y * scale * 2.4));
	float xz = fbm3d(vec3(wpos.xz * scale, 0.0));
	return xy * blend.z + yz * blend.x + xz * blend.y;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_NORMAL_MATRIX * NORMAL));
	v_vert_color = COLOR;
}

void fragment() {
	vec3 wpos = v_world_pos;
	vec3 wnorm = normalize(v_world_normal);

	// 45-degree slope threshold: cos(45 deg) = 0.70710678
	// Steep angles (> 45 deg => wnorm.y < 0.7071) blend into dark wet basalt/granite cliff rock
	// Gentle slopes (< 45 deg => wnorm.y > 0.7071) blend into dark forest moss, pine needles & alpine soil
	float slope_cos = clamp(wnorm.y, 0.0, 1.0);
	float steep_cliff_mask = 1.0 - smoothstep(0.61, 0.77, slope_cos);

	// Multi-scale triplanar detail
	float macro_var = fbm3d(wpos * 0.015);
	float rock_strata = sample_triplanar_strata(wpos, wnorm, 0.14);
	float micro_grain = noise3d(wpos * 1.35);

	// 1. Gentle Slope Palette: Alpine Forest Moss, Cedar Needle Litter, Dark Humus Soil
	vec3 deep_moss = vec3(0.045, 0.095, 0.048);
	vec3 pine_needle_floor = vec3(0.085, 0.072, 0.045);
	vec3 alpine_soil = vec3(0.055, 0.048, 0.042);

	float moss_patch = smoothstep(0.36, 0.68, macro_var + micro_grain * 0.25);
	vec3 forest_floor_col = mix(pine_needle_floor, deep_moss, moss_patch);
	forest_floor_col = mix(alpine_soil, forest_floor_col, smoothstep(0.25, 0.6, rock_strata));

	// 2. Steep Cliff Palette: Dark Wet Basalt & Fractured Gunma Granite
	vec3 dark_basalt = vec3(0.052, 0.058, 0.068);
	vec3 granite_vein = vec3(0.115, 0.122, 0.135);
	vec3 wet_seepage = vec3(0.025, 0.029, 0.036);

	vec3 cliff_col = mix(dark_basalt, granite_vein, smoothstep(0.35, 0.78, rock_strata));
	// Vertical water seepage streaks on steep basalt faces
	float seepage_streak = smoothstep(0.48, 0.75, fbm3d(vec3(wpos.x * 0.22, wpos.y * 0.04, wpos.z * 0.22)));
	cliff_col = mix(cliff_col, wet_seepage, seepage_streak * 0.65);

	// Road shoulder crushed gravel & retaining margin
	vec3 shoulder_gravel = vec3(0.09, 0.092, 0.098) * (0.85 + 0.3 * micro_grain);

	// Combine slope materials
	vec3 final_albedo = mix(forest_floor_col, cliff_col, steep_cliff_mask);
	final_albedo = mix(final_albedo, shoulder_gravel, v_vert_color.r * 0.75);

	// Subtle distance aerial perspective harmonization
	ALBEDO = final_albedo;

	// Wet roughness calibration:
	// Forest floor is matte (0.86), steep basalt cliff rock has wet mineral sheen (0.28 - 0.46)
	float forest_roughness = 0.88 - moss_patch * 0.08;
	float cliff_roughness = mix(0.46, 0.24, seepage_streak);
	ROUGHNESS = mix(forest_roughness, cliff_roughness, steep_cliff_mask);
	SPECULAR = mix(0.22, 0.62, steep_cliff_mask);
	METALLIC = 0.04 * steep_cliff_mask;

	// Procedural micro-normal perturbation for crisp rock crevices under headlights
	vec3 d_pos_x = dFdx(wpos);
	vec3 d_pos_y = dFdy(wpos);
	float h_center = rock_strata * 0.6 + micro_grain * 0.4;
	float dh_x = dFdx(h_center);
	float dh_y = dFdy(h_center);
	vec3 bumped_norm = normalize(NORMAL - (dh_x * normalize(d_pos_x) + dh_y * normalize(d_pos_y)) * mix(0.35, 1.15, steep_cliff_mask));
	NORMAL = bumped_norm;
}
"""
	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = terrain_shader

	# --- B. Wind-Sway Foliage Shaders (144Hz GPU Vertex Animation) ---
	var foliage_canopy_shader := Shader.new()
	foliage_canopy_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec3 canopy_color_primary : source_color = vec3(0.05, 0.13, 0.06);
uniform vec3 canopy_color_secondary : source_color = vec3(0.09, 0.19, 0.08);
uniform float wind_strength = 0.38;
uniform float wind_speed = 1.65;
uniform float sub_surface_scatter = 0.15;
uniform float roughness_val = 0.78;

varying float v_height_norm;
varying float v_instance_seed;
varying vec3 v_local_pos;

void vertex() {
	v_local_pos = VERTEX;
	v_height_norm = clamp(VERTEX.y / 14.0, 0.0, 1.0);
	vec3 world_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_instance_seed = fract(sin(dot(world_origin.xz, vec2(12.9898, 78.233))) * 43758.5453);

	// Primary mountain wind wave + secondary branch flutter
	float phase = TIME * wind_speed + (world_origin.x + world_origin.z) * 0.045 + v_instance_seed * 6.2831;
	float sway_factor = pow(v_height_norm, 1.65) * wind_strength;
	VERTEX.x += sin(phase) * sway_factor;
	VERTEX.z += cos(phase * 0.83) * sway_factor * 0.75;

	// High-frequency needle/blossom rustle at branch tips
	float radial_dist = length(VERTEX.xz);
	float flutter = sin(TIME * 4.2 + VERTEX.y * 2.3 + v_instance_seed * 12.0) * 0.07 * clamp(radial_dist, 0.0, 2.5);
	VERTEX.xyz += NORMAL * flutter;
}

void fragment() {
	float branch_grad = clamp(v_height_norm * 0.75 + v_instance_seed * 0.25, 0.0, 1.0);
	vec3 base_col = mix(canopy_color_primary, canopy_color_secondary, branch_grad);

	// Procedural foliage cluster micro-variation
	float leaf_pattern = fract(sin(dot(floor(v_local_pos * 7.5), vec3(19.1, 73.7, 41.3))) * 9182.3);
	base_col *= mix(0.84, 1.16, leaf_pattern);

	ALBEDO = base_col;
	ROUGHNESS = roughness_val;
	SPECULAR = 0.25;
	BACKLIGHT = base_col * sub_surface_scatter;
}
"""

	var trunk_shader := Shader.new()
	trunk_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 bark_color : source_color = vec3(0.11, 0.075, 0.055);
uniform float wind_strength = 0.38;
uniform float wind_speed = 1.65;

void vertex() {
	float h_norm = clamp(VERTEX.y / 14.0, 0.0, 1.0);
	vec3 world_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float seed = fract(sin(dot(world_origin.xz, vec2(12.9898, 78.233))) * 43758.5453);
	float phase = TIME * wind_speed + (world_origin.x + world_origin.z) * 0.045 + seed * 6.2831;
	float sway_factor = pow(h_norm, 1.65) * wind_strength;
	VERTEX.x += sin(phase) * sway_factor;
	VERTEX.z += cos(phase * 0.83) * sway_factor * 0.75;
}

void fragment() {
	ALBEDO = bark_color;
	ROUGHNESS = 0.92;
	SPECULAR = 0.12;
}
"""

	# Cedar / Alpine Pine Materials
	_pine_trunk_material = ShaderMaterial.new()
	_pine_trunk_material.shader = trunk_shader
	_pine_trunk_material.set_shader_parameter("bark_color", Color(0.11, 0.072, 0.052))

	_pine_needle_material = ShaderMaterial.new()
	_pine_needle_material.shader = foliage_canopy_shader
	_pine_needle_material.set_shader_parameter("canopy_color_primary", Color(0.038, 0.098, 0.048))
	_pine_needle_material.set_shader_parameter("canopy_color_secondary", Color(0.075, 0.165, 0.082))
	_pine_needle_material.set_shader_parameter("wind_strength", 0.36)
	_pine_needle_material.set_shader_parameter("sub_surface_scatter", 0.14)

	# Japanese Sakura (Cherry Blossom) Materials
	_sakura_trunk_material = ShaderMaterial.new()
	_sakura_trunk_material.shader = trunk_shader
	_sakura_trunk_material.set_shader_parameter("bark_color", Color(0.14, 0.095, 0.09))
	_sakura_trunk_material.set_shader_parameter("wind_strength", 0.28)

	_sakura_blossom_material = ShaderMaterial.new()
	_sakura_blossom_material.shader = foliage_canopy_shader
	_sakura_blossom_material.set_shader_parameter("canopy_color_primary", Color(0.88, 0.56, 0.68))
	_sakura_blossom_material.set_shader_parameter("canopy_color_secondary", Color(0.98, 0.82, 0.88))
	_sakura_blossom_material.set_shader_parameter("wind_strength", 0.30)
	_sakura_blossom_material.set_shader_parameter("sub_surface_scatter", 0.45)
	_sakura_blossom_material.set_shader_parameter("roughness_val", 0.65)

	# Roadside Mountain Scrub / Bamboo Grass Bushes
	_bush_material = ShaderMaterial.new()
	_bush_material.shader = foliage_canopy_shader
	_bush_material.set_shader_parameter("canopy_color_primary", Color(0.048, 0.115, 0.052))
	_bush_material.set_shader_parameter("canopy_color_secondary", Color(0.095, 0.18, 0.075))
	_bush_material.set_shader_parameter("wind_strength", 0.22)
	_bush_material.set_shader_parameter("wind_speed", 2.2)

# ------------------------------------------------------------------------------
# 3. PROCEDURAL TREE MESHES & MULTIMESH3D FOREST INSTANCING
# ------------------------------------------------------------------------------
func _build_foliage_multimeshes() -> void:
	var foliage_root := Node3D.new()
	foliage_root.name = "InstancedMountainForests"
	_generated_root.add_child(foliage_root)

	var pine_mesh: ArrayMesh = _create_japanese_cedar_mesh()
	var sakura_mesh: ArrayMesh = _create_japanese_sakura_mesh()
	var bush_mesh: ArrayMesh = _create_mountain_scrub_bush_mesh()

	var rng := RandomNumberGenerator.new()
	rng.seed = 868686

	# --- A. Japanese Alpine Cedar / Pine (Sugi) MultiMesh ---
	var pine_transforms: Array[Transform3D] = []
	var track_count: int = _baked_spline_points.size()
	var attempts: int = pine_instance_count * 2

	for i in range(attempts):
		if pine_transforms.size() >= pine_instance_count:
			break

		var wx: float = 0.0
		var wz: float = 0.0

		# 68% flanking the Touge corridor & switchback slopes; 32% covering wide valley & ridges
		if rng.randf() < 0.68 and track_count > 0:
			var t_idx: int = rng.randi_range(0, track_count - 1)
			var anchor: Vector3 = _baked_spline_points[t_idx]
			var tangent: Vector3 = _baked_spline_tangents[t_idx]
			var right := Vector3(-tangent.z, 0.0, tangent.x).normalized()
			var side: float = 1.0 if rng.randf() < 0.5 else -1.0
			var lateral_dist: float = road_corridor_half_width + 3.8 + pow(rng.randf(), 1.45) * 260.0
			var forward_jitter: float = rng.randf_range(-16.0, 16.0)
			var sample_pt: Vector3 = anchor + right * (side * lateral_dist) + tangent * forward_jitter
			wx = sample_pt.x
			wz = sample_pt.z
		else:
			wx = rng.randf_range(_bounds_min.x + 60.0, _bounds_max.x - 60.0)
			wz = rng.randf_range(_bounds_min.z + 60.0, _bounds_max.z - 60.0)

		var surf: Vector2 = _evaluate_mountain_surface(wx, wz)
		var wy: float = surf.x
		var road_dist: float = surf.y

		# Strictly keep trees off the asphalt & immediate guardrail shoulder
		if road_dist < (road_corridor_half_width + 2.8):
			continue

		# Natural forest grove clumping
		if _forest_density_noise.get_noise_2d(wx, wz) < -0.38:
			continue

		var norm: Vector3 = _calculate_surface_normal(wx, wz)
		# Avoid vertical sheer basalt faces (> 58 degrees)
		if norm.y < 0.53:
			continue

		var scale_y: float = rng.randf_range(0.82, 1.55)
		var scale_xz: float = scale_y * rng.randf_range(0.85, 1.15)
		var rot_y: float = rng.randf_range(0.0, TAU)

		var basis := Basis.from_euler(Vector3(0.0, rot_y, 0.0)).scaled(Vector3(scale_xz, scale_y, scale_xz))
		pine_transforms.append(Transform3D(basis, Vector3(wx, wy - 0.25, wz)))

	var pine_mmi := _create_multimesh_instance("JapaneseCedarMultiMesh", pine_mesh, pine_transforms, foliage_visibility_range)
	foliage_root.add_child(pine_mmi)

	# --- B. Blooming Japanese Sakura Groves (Summit Shrine, Observation Plateau & Hairpins) ---
	var sakura_transforms: Array[Transform3D] = []
	var sakura_anchors: PackedVector3Array = PackedVector3Array()
	sakura_anchors.append(_summit_point)
	if track_count > 6:
		sakura_anchors.append(_baked_spline_points[min(8, track_count - 1)]) # Summit observation plateau
		sakura_anchors.append(_baked_spline_points[max(0, track_count - 8)]) # Valley finish gate
	for hp in _detected_hairpin_centers:
		sakura_anchors.append(hp)

	var sakura_attempts: int = sakura_instance_count * 3
	for i in range(sakura_attempts):
		if sakura_transforms.size() >= sakura_instance_count or sakura_anchors.is_empty():
			break

		var center: Vector3 = sakura_anchors[rng.randi_range(0, sakura_anchors.size() - 1)]
		var angle: float = rng.randf_range(0.0, TAU)
		var radius: float = rng.randf_range(road_corridor_half_width + 3.2, 88.0)
		var wx: float = center.x + cos(angle) * radius
		var wz: float = center.z + sin(angle) * radius

		var surf: Vector2 = _evaluate_mountain_surface(wx, wz)
		var wy: float = surf.x
		var road_dist: float = surf.y

		if road_dist < (road_corridor_half_width + 2.5):
			continue

		var norm: Vector3 = _calculate_surface_normal(wx, wz)
		if norm.y < 0.60:
			continue

		var scale_factor: float = rng.randf_range(0.85, 1.42)
		var rot_y: float = rng.randf_range(0.0, TAU)
		var tilt_x: float = rng.randf_range(-0.08, 0.08)
		var tilt_z: float = rng.randf_range(-0.08, 0.08)

		var basis := Basis.from_euler(Vector3(tilt_x, rot_y, tilt_z)).scaled(Vector3.ONE * scale_factor)
		sakura_transforms.append(Transform3D(basis, Vector3(wx, wy - 0.2, wz)))

	var sakura_mmi := _create_multimesh_instance("SakuraGrovesMultiMesh", sakura_mesh, sakura_transforms, foliage_visibility_range * 0.9)
	foliage_root.add_child(sakura_mmi)

	# --- C. Roadside Undergrowth & Sasa Bamboo Scrub ---
	var bush_transforms: Array[Transform3D] = []
	for i in range(roadside_guard_bush_count * 2):
		if bush_transforms.size() >= roadside_guard_bush_count or track_count == 0:
			break

		var t_idx: int = rng.randi_range(0, track_count - 1)
		var anchor: Vector3 = _baked_spline_points[t_idx]
		var tangent: Vector3 = _baked_spline_tangents[t_idx]
		var right := Vector3(-tangent.z, 0.0, tangent.x).normalized()
		var side: float = 1.0 if rng.randf() < 0.5 else -1.0
		var lateral_dist: float = road_corridor_half_width + rng.randf_range(1.6, 26.0)
		var sample_pt: Vector3 = anchor + right * (side * lateral_dist) + tangent * rng.randf_range(-8.0, 8.0)

		var surf: Vector2 = _evaluate_mountain_surface(sample_pt.x, sample_pt.z)
		if surf.y < (road_corridor_half_width + 1.4):
			continue

		var s_xz: float = rng.randf_range(0.9, 1.85)
		var s_y: float = rng.randf_range(0.75, 1.45)
		var basis := Basis.from_euler(Vector3(0.0, rng.randf_range(0.0, TAU), 0.0)).scaled(Vector3(s_xz, s_y, s_xz))
		bush_transforms.append(Transform3D(basis, Vector3(sample_pt.x, surf.x - 0.15, sample_pt.z)))

	var bush_mmi := _create_multimesh_instance("RoadsideScrubMultiMesh", bush_mesh, bush_transforms, 420.0)
	foliage_root.add_child(bush_mmi)

func _create_multimesh_instance(
	node_name: String,
	mesh_res: Mesh,
	xforms: Array[Transform3D],
	vis_end: float
) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.mesh = mesh_res
	mm.instance_count = xforms.size()

	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mmi.visibility_range_end = vis_end
	mmi.visibility_range_end_margin = 65.0
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return mmi

## Builds a multi-tiered Japanese Cedar (Cryptomeria japonica / Sugi) with separate Bark & Needle surfaces.
func _create_japanese_cedar_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()

	# Surface 0: Tapered Cedar Trunk
	var st_trunk := SurfaceTool.new()
	st_trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_tapered_cylinder(st_trunk, Vector3.ZERO, 0.42, 0.08, 12.5, 6)
	st_trunk.generate_normals()
	st_trunk.set_material(_pine_trunk_material)
	st_trunk.commit(mesh)

	# Surface 1: 5 Layered Conical Bough Tiers
	var st_canopy := SurfaceTool.new()
	st_canopy.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tier_heights: Array[float] = [2.6, 4.8, 7.0, 9.2, 11.2]
	var tier_radii: Array[float] = [3.3, 2.85, 2.35, 1.80, 1.20]
	var tier_lengths: Array[float] = [3.6, 3.4, 3.1, 2.8, 2.6]

	for t in range(tier_heights.size()):
		_append_scalloped_cone(
			st_canopy,
			Vector3(0.0, tier_heights[t], 0.0),
			tier_radii[t],
			tier_lengths[t],
			7,
			float(t) * 0.45
		)

	st_canopy.generate_normals()
	st_canopy.set_material(_pine_needle_material)
	st_canopy.commit(mesh)
	return mesh

## Builds a spreading Japanese Sakura tree with gnarled fork branches and dense blossom cloud domes.
func _create_japanese_sakura_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()

	# Surface 0: Trunk & Main Forked Boughs
	var st_trunk := SurfaceTool.new()
	st_trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_tapered_cylinder(st_trunk, Vector3.ZERO, 0.48, 0.24, 3.6, 6)

	var branch_dirs: Array[Vector3] = [
		Vector3(1.8, 2.8, 0.9),
		Vector3(-1.9, 2.6, 1.1),
		Vector3(0.4, 3.0, -2.0),
		Vector3(-1.1, 2.9, -1.5)
	]
	for bdir in branch_dirs:
		_append_angled_branch(st_trunk, Vector3(0.0, 2.8, 0.0), Vector3(0.0, 2.8, 0.0) + bdir, 0.20, 0.08, 5)

	st_trunk.generate_normals()
	st_trunk.set_material(_sakura_trunk_material)
	st_trunk.commit(mesh)

	# Surface 1: Lush Cherry Blossom Canopy Clusters
	var st_blossom := SurfaceTool.new()
	st_blossom.begin(Mesh.PRIMITIVE_TRIANGLES)

	var canopy_centers: Array[Vector3] = [
		Vector3(0.0, 6.2, 0.0),
		Vector3(2.1, 5.4, 1.0),
		Vector3(-2.2, 5.2, 1.2),
		Vector3(0.5, 5.6, -2.1),
		Vector3(-1.4, 5.5, -1.6),
		Vector3(1.4, 6.0, -1.1)
	]
	var canopy_radii: Array[Vector3] = [
		Vector3(2.9, 1.75, 2.9),
		Vector3(2.2, 1.45, 2.2),
		Vector3(2.3, 1.45, 2.1),
		Vector3(2.1, 1.40, 2.2),
		Vector3(2.0, 1.35, 2.0),
		Vector3(1.9, 1.35, 1.9)
	]

	for c in range(canopy_centers.size()):
		_append_canopy_ellipsoid(st_blossom, canopy_centers[c], canopy_radii[c], 7, 5)

	st_blossom.generate_normals()
	st_blossom.set_material(_sakura_blossom_material)
	st_blossom.commit(mesh)
	return mesh

func _create_mountain_scrub_bush_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_canopy_ellipsoid(st, Vector3(0.0, 0.55, 0.0), Vector3(1.15, 0.72, 1.15), 6, 4)
	_append_canopy_ellipsoid(st, Vector3(0.55, 0.45, 0.35), Vector3(0.85, 0.55, 0.85), 6, 4)
	st.generate_normals()
	st.set_material(_bush_material)
	st.commit(mesh)
	return mesh

# --- Low-Level Geometry Builders for Trees ---
func _append_tapered_cylinder(
	st: SurfaceTool,
	base_pos: Vector3,
	r_bottom: float,
	r_top: float,
	height: float,
	radial_segments: int
) -> void:
	for i in range(radial_segments):
		var a0: float = float(i) / float(radial_segments) * TAU
		var a1: float = float(i + 1) / float(radial_segments) * TAU

		var p00 := base_pos + Vector3(cos(a0) * r_bottom, 0.0, sin(a0) * r_bottom)
		var p10 := base_pos + Vector3(cos(a1) * r_bottom, 0.0, sin(a1) * r_bottom)
		var p01 := base_pos + Vector3(cos(a0) * r_top, height, sin(a0) * r_top)
		var p11 := base_pos + Vector3(cos(a1) * r_top, height, sin(a1) * r_top)

		st.add_vertex(p00)
		st.add_vertex(p10)
		st.add_vertex(p01)

		st.add_vertex(p10)
		st.add_vertex(p11)
		st.add_vertex(p01)

func _append_angled_branch(
	st: SurfaceTool,
	p_start: Vector3,
	p_end: Vector3,
	r_start: float,
	r_end: float,
	segments: int
) -> void:
	var dir: Vector3 = (p_end - p_start).normalized()
	var up_ref: Vector3 = Vector3.FORWARD if abs(dir.dot(Vector3.UP)) > 0.9 else Vector3.UP
	var right: Vector3 = dir.cross(up_ref).normalized()
	var forward: Vector3 = right.cross(dir).normalized()

	for i in range(segments):
		var a0: float = float(i) / float(segments) * TAU
		var a1: float = float(i + 1) / float(segments) * TAU

		var off0_s: Vector3 = (right * cos(a0) + forward * sin(a0)) * r_start
		var off1_s: Vector3 = (right * cos(a1) + forward * sin(a1)) * r_start
		var off0_e: Vector3 = (right * cos(a0) + forward * sin(a0)) * r_end
		var off1_e: Vector3 = (right * cos(a1) + forward * sin(a1)) * r_end

		st.add_vertex(p_start + off0_s)
		st.add_vertex(p_start + off1_s)
		st.add_vertex(p_end + off0_e)

		st.add_vertex(p_start + off1_s)
		st.add_vertex(p_end + off1_e)
		st.add_vertex(p_end + off0_e)

func _append_scalloped_cone(
	st: SurfaceTool,
	base_center: Vector3,
	radius: float,
	height: float,
	segments: int,
	angle_offset: float
) -> void:
	var apex: Vector3 = base_center + Vector3(0.0, height, 0.0)
	for i in range(segments):
		var a0: float = angle_offset + float(i) / float(segments) * TAU
		var a1: float = angle_offset + float(i + 1) / float(segments) * TAU
		var r0: float = radius * (0.92 + 0.14 * sin(float(i) * 3.0))
		var r1: float = radius * (0.92 + 0.14 * sin(float(i + 1) * 3.0))
		var y_droop0: float = -0.22 * cos(float(i) * 2.0)
		var y_droop1: float = -0.22 * cos(float(i + 1) * 2.0)

		var p0 := base_center + Vector3(cos(a0) * r0, y_droop0, sin(a0) * r0)
		var p1 := base_center + Vector3(cos(a1) * r1, y_droop1, sin(a1) * r1)

		st.add_vertex(p0)
		st.add_vertex(p1)
		st.add_vertex(apex)

		# Underside skirt closure so cones look dense from below on uphill hairpins
		var inner0 := base_center + Vector3(cos(a0) * r0 * 0.25, 0.35, sin(a0) * r0 * 0.25)
		var inner1 := base_center + Vector3(cos(a1) * r1 * 0.25, 0.35, sin(a1) * r1 * 0.25)
		st.add_vertex(p1)
		st.add_vertex(p0)
		st.add_vertex(inner0)
		st.add_vertex(p1)
		st.add_vertex(inner0)
		st.add_vertex(inner1)

func _append_canopy_ellipsoid(
	st: SurfaceTool,
	center: Vector3,
	radii: Vector3,
	lon_segments: int,
	lat_segments: int
) -> void:
	for lat in range(lat_segments):
		var theta0: float = PI * float(lat) / float(lat_segments)
		var theta1: float = PI * float(lat + 1) / float(lat_segments)

		for lon in range(lon_segments):
			var phi0: float = TAU * float(lon) / float(lon_segments)
			var phi1: float = TAU * float(lon + 1) / float(lon_segments)

			var v00 := _ellipsoid_point(center, radii, theta0, phi0)
			var v10 := _ellipsoid_point(center, radii, theta0, phi1)
			var v01 := _ellipsoid_point(center, radii, theta1, phi0)
			var v11 := _ellipsoid_point(center, radii, theta1, phi1)

			st.add_vertex(v00)
			st.add_vertex(v10)
			st.add_vertex(v01)

			st.add_vertex(v10)
			st.add_vertex(v11)
			st.add_vertex(v01)

func _ellipsoid_point(center: Vector3, radii: Vector3, theta: float, phi: float) -> Vector3:
	var puff: float = 1.0 + 0.12 * sin(theta * 3.0 + phi * 2.0)
	return center + Vector3(
		sin(theta) * cos(phi) * radii.x * puff,
		cos(theta) * radii.y * puff,
		sin(theta) * sin(phi) * radii.z * puff
	)

# ------------------------------------------------------------------------------
# 4. DYNAMIC SAKURA PETAL DRIFTING PARTICLES ACROSS THE ASPHALT
# ------------------------------------------------------------------------------
func _build_sakura_petal_emitters() -> void:
	var particles_root := Node3D.new()
	particles_root.name = "SakuraPetalDriftEmitters"
	_generated_root.add_child(particles_root)

	# Petal Quad Mesh with soft alpha-clipped blossom shader
	var petal_shader := Shader.new()
	petal_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, unshaded;

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	// Heart-notched cherry blossom petal SDF
	uv.y += 0.15;
	float r = length(vec2(uv.x * 1.25, uv.y));
	float notch = smoothstep(0.0, 0.35, uv.y) * max(0.0, 0.28 - abs(uv.x) * 1.6);
	float mask = 1.0 - smoothstep(0.68, 0.85, r + notch);
	if (mask < 0.35) {
		discard;
	}
	vec3 petal_pink = mix(vec3(0.98, 0.76, 0.84), vec3(1.0, 0.93, 0.96), clamp(uv.y + 0.5, 0.0, 1.0));
	ALBEDO = petal_pink;
}
"""
	var petal_mat := ShaderMaterial.new()
	petal_mat.shader = petal_shader

	var petal_quad := QuadMesh.new()
	petal_quad.size = Vector2(0.16, 0.22)
	petal_quad.material = petal_mat

	var proc_mat := ParticleProcessMaterial.new()
	proc_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc_mat.emission_box_extents = Vector3(42.0, 14.0, 42.0)
	proc_mat.direction = Vector3(1.0, -0.32, 0.45).normalized()
	proc_mat.spread = 28.0
	proc_mat.gravity = Vector3(0.85, -1.15, 0.35)
	proc_mat.initial_velocity_min = 2.4
	proc_mat.initial_velocity_max = 5.2
	proc_mat.angular_velocity_min = -140.0
	proc_mat.angular_velocity_max = 140.0
	proc_mat.tangential_accel_min = -1.8
	proc_mat.tangential_accel_max = 1.8
	proc_mat.turbulence_enabled = true
	proc_mat.turbulence_noise_strength = 2.2
	proc_mat.turbulence_noise_scale = 4.5
	proc_mat.scale_min = 0.75
	proc_mat.scale_max = 1.45

	# Place emitters at Summit Shrine, Observation Start, and up to 5 Iconic Hairpins
	var emitter_locations: Array[Vector3] = [_summit_point]
	for i in range(min(5, _detected_hairpin_centers.size())):
		emitter_locations.append(_detected_hairpin_centers[i])

	for i in range(emitter_locations.size()):
		var emitter := GPUParticles3D.new()
		emitter.name = "SakuraPetalField_%d" % i
		emitter.position = emitter_locations[i] + Vector3(0.0, 9.5, 0.0)
		emitter.amount = 420
		emitter.lifetime = 9.0
		emitter.preprocess = 3.0
		emitter.visibility_aabb = AABB(Vector3(-85.0, -45.0, -85.0), Vector3(170.0, 90.0, 170.0))
		emitter.process_material = proc_mat
		emitter.draw_pass_1 = petal_quad
		emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		particles_root.add_child(emitter)

# ------------------------------------------------------------------------------
# 5. ATMOSPHERIC HORIZON, LAYERED SILHOUETTE SKYBOX & DISTANCE LIGHTING
# ------------------------------------------------------------------------------
func _build_atmosphere_and_lighting() -> void:
	# Custom Panorama Sky Shader with Distant Layered Gunma Mountain Silhouettes & Dusk Glow
	var sky_shader := Shader.new()
	sky_shader.code = """
shader_type sky;

uniform float dusk_intensity = 1.18;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

float ridge_noise_1d(float x) {
	float i = floor(x);
	float f = fract(x);
	float u = f * f * (3.0 - 2.0 * f);
	return mix(hash11(i), hash11(i + 1.0), u);
}

float mountain_profile(float angle, float freq, float seed_offset) {
	float v = 0.0;
	float amp = 0.55;
	float p = angle * freq + seed_offset;
	for (int i = 0; i < 4; i++) {
		v += (1.0 - abs(ridge_noise_1d(p) * 2.0 - 1.0)) * amp;
		p = p * 2.12 + 7.13;
		amp *= 0.48;
	}
	return v;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float elev = dir.y;
	float azim = atan(dir.x, dir.z);

	// 1. Twilight Zenith to Horizon Dusk Gradient
	vec3 zenith_col = vec3(0.032, 0.052, 0.125);
	vec3 mid_sky_col = vec3(0.095, 0.135, 0.245);
	vec3 horizon_dusk_col = vec3(0.46, 0.25, 0.28) * dusk_intensity;
	vec3 sun_azimuth_dir = normalize(vec3(-0.62, 0.11, -0.77));

	float sun_alignment = max(0.0, dot( normalize(vec3(dir.x, 0.0, dir.z)), normalize(vec3(sun_azimuth_dir.x, 0.0, sun_azimuth_dir.z)) ));
	vec3 warm_afterglow = vec3(0.88, 0.42, 0.22) * pow(sun_alignment, 3.2) * dusk_intensity;

	float sky_t = clamp(elev, 0.0, 1.0);
	vec3 sky_col = mix(horizon_dusk_col + warm_afterglow * 0.65, mid_sky_col, pow(sky_t, 0.42));
	sky_col = mix(sky_col, zenith_col, pow(sky_t, 0.88));

	// Subtle solar corona near horizon
	float sun_dot = max(0.0, dot(dir, sun_azimuth_dir));
	sky_col += vec3(1.0, 0.55, 0.28) * pow(sun_dot, 28.0) * 0.55;

	// 2. Three Distant Layered Mountain Range Silhouettes (Eliminates black horizon drop-off)
	float far_ridge_h = 0.055 + mountain_profile(azim, 2.8, 1.2) * 0.095;
	float mid_ridge_h = 0.025 + mountain_profile(azim, 3.6, 8.7) * 0.078;
	float near_ridge_h = -0.005 + mountain_profile(azim, 4.5, 19.4) * 0.062;

	vec3 far_ridge_col = mix(vec3(0.14, 0.15, 0.24), horizon_dusk_col * 0.72, 0.45);
	vec3 mid_ridge_col = vec3(0.082, 0.098, 0.165);
	vec3 near_ridge_col = vec3(0.045, 0.058, 0.095);

	if (elev < far_ridge_h) {
		float haze = clamp((far_ridge_h - elev) * 18.0, 0.0, 1.0);
		sky_col = mix(sky_col, far_ridge_col, smoothstep(0.0, 0.008, far_ridge_h - elev));
		sky_col = mix(sky_col, mid_ridge_col, haze * 0.35);
	}
	if (elev < mid_ridge_h) {
		sky_col = mix(sky_col, mid_ridge_col, smoothstep(0.0, 0.006, mid_ridge_h - elev));
	}
	if (elev < near_ridge_h) {
		sky_col = mix(sky_col, near_ridge_col, smoothstep(0.0, 0.005, near_ridge_h - elev));
	}

	// Below-horizon valley floor fill (prevents any dark void if seen from extreme altitude)
	if (elev < -0.01) {
		float nadir_t = clamp(-elev * 4.5, 0.0, 1.0);
		sky_col = mix(near_ridge_col, vec3(0.028, 0.036, 0.055), nadir_t);
	}

	COLOR = sky_col;
}
"""
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = sky_shader
	sky_mat.set_shader_parameter("dusk_intensity", horizon_dusk_intensity)

	var sky_res := Sky.new()
	sky_res.sky_material = sky_mat
	sky_res.process_mode = Sky.PROCESS_MODE_QUALITY
	sky_res.radiance_size = Sky.RADIANCE_SIZE_256

	# Discover existing WorldEnvironment or create one
	var world_env: WorldEnvironment = _find_existing_world_environment()
	if not is_instance_valid(world_env):
		world_env = WorldEnvironment.new()
		world_env.name = "AkinaWorldEnvironment"
		_generated_root.add_child(world_env)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky_res

	# Ambient & Reflected Sky Illumination so distant mountains and hairpins stay legible
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color(0.18, 0.22, 0.34)
	env.ambient_light_sky_contribution = 0.78
	env.ambient_light_energy = 1.15
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# ACES Tonemapping & Forward+ Visual Polish
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.08
	env.tonemap_white = 6.0

	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.65

	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.08
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	# Calibrated Aerial Perspective Depth Fog (Never clips to black)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = Color(0.22, 0.21, 0.31)
	env.fog_light_energy = 0.92
	env.fog_sun_scatter = 0.28
	env.fog_density = 0.00045
	env.fog_aerial_perspective = 0.68
	env.fog_sky_affect = 0.22
	env.fog_height = _valley_base_point.y + 25.0
	env.fog_height_density = 0.0035

	# Calibrated Volumetric Fog for Mountain Headlight Beams & Valley Mist
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = volumetric_fog_density
	env.volumetric_fog_albedo = Color(0.68, 0.72, 0.86)
	env.volumetric_fog_emission = Color(0.05, 0.06, 0.10)
	env.volumetric_fog_emission_energy = 0.65
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 280.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_ambient_inject = 0.45
	env.volumetric_fog_sky_affect = 0.35

	world_env.environment = env

	# Directional Twilight Sun / Alpenglow Rim Light + Cool Mountain Fill Light
	var sun_light := DirectionalLight3D.new()
	sun_light.name = "AkinaDuskSunLight"
	sun_light.rotation_degrees = Vector3(-16.5, -142.0, 0.0)
	sun_light.light_color = Color(1.0, 0.74, 0.58)
	sun_light.light_energy = 1.45
	sun_light.light_indirect_energy = 1.2
	sun_light.light_volumetric_fog_energy = 1.35
	sun_light.shadow_enabled = true
	sun_light.shadow_bias = 0.04
	sun_light.shadow_normal_bias = 1.8
	sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun_light.directional_shadow_max_distance = 450.0
	sun_light.directional_shadow_fade_start = 0.82
	_generated_root.add_child(sun_light)

	var sky_fill_light := DirectionalLight3D.new()
	sky_fill_light.name = "AkinaAlpineZenithFill"
	sky_fill_light.rotation_degrees = Vector3(-68.0, 38.0, 0.0)
	sky_fill_light.light_color = Color(0.42, 0.56, 0.85)
	sky_fill_light.light_energy = 0.42
	sky_fill_light.shadow_enabled = false
	_generated_root.add_child(sky_fill_light)

func _find_existing_world_environment() -> WorldEnvironment:
	if not is_inside_tree():
		return null
	var root_node: Node = get_tree().current_scene if get_tree().current_scene else get_parent()
	if not is_instance_valid(root_node):
		return null
	var envs: Array[Node] = root_node.find_children("*", "WorldEnvironment", true, false)
	for e in envs:
		if e is WorldEnvironment and not is_ancestor_of(e):
			return e
	return null

# ------------------------------------------------------------------------------
# 6. CAMERA3D FAR-PLANE CALIBRATION (ELIMINATES DISTANT BLACK CLIPPING)
# ------------------------------------------------------------------------------
func _calibrate_active_cameras() -> void:
	if not is_inside_tree():
		return

	var viewport := get_viewport()
	if is_instance_valid(viewport):
		var active_cam: Camera3D = viewport.get_camera_3d()
		if is_instance_valid(active_cam) and active_cam.far < target_camera_far_plane:
			active_cam.far = target_camera_far_plane

	var scene_root: Node = get_tree().current_scene if get_tree().current_scene else get_parent()
	if is_instance_valid(scene_root):
		var all_cameras: Array[Node] = scene_root.find_children("*", "Camera3D", true, false)
		for cam_node in all_cameras:
			if cam_node is Camera3D and cam_node.far < target_camera_far_plane:
				cam_node.far = target_camera_far_plane