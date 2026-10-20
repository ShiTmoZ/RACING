class_name AkinaRoadsidePropsDecorator
extends Node3D
## Procedural Touge Scenery & Roadside Decorator for "ShiTmoZ/RACING" (Mount Akina).
## Strictly visual decorator (zero physics/collision mutation) optimized for Godot 4.3 Vulkan Forward+.

@export_group("Road Geometry Parameters")
@export var road_half_width: float = 5.2
@export var shoulder_margin: float = 0.85
@export var guardrail_interval: float = 4.0
@export var reflector_interval: float = 8.0
@export var utility_pole_interval: float = 45.0
@export var flora_step_interval: float = 3.2
@export var hairpin_curvature_threshold: float = 0.032

@export_group("LOD & Culling (Meters)")
@export var guardrail_cull_distance: float = 280.0
@export var reflector_cull_distance: float = 220.0
@export var pole_cull_distance: float = 450.0
@export var flora_cull_distance: float = 1200.0
@export var detail_prop_cull_distance: float = 200.0
@export var enable_apex_omni_lights: bool = true
@export var omni_light_cull_distance: float = 135.0

@export_group("Deterministic Generation")
@export var random_seed: int = 861998

# Internal Material Cache
var _mat_galvanized_steel: StandardMaterial3D
var _mat_dark_steel_post: StandardMaterial3D
var _mat_reflector_red: StandardMaterial3D
var _mat_reflector_amber: StandardMaterial3D
var _mat_concrete_pole: StandardMaterial3D
var _mat_timber_pole: StandardMaterial3D
var _mat_porcelain_insulator: StandardMaterial3D
var _mat_power_wire: StandardMaterial3D
var _mat_torii_vermilion: StandardMaterial3D
var _mat_torii_black_base: StandardMaterial3D
var _mat_torii_gold_plaque: StandardMaterial3D
var _mat_pine_bark: StandardMaterial3D
var _mat_pine_needles: StandardMaterial3D
var _mat_sakura_bark: StandardMaterial3D
var _mat_sakura_blossom: StandardMaterial3D
var _mat_sodium_bulb: StandardMaterial3D
var _mat_stone_lantern: StandardMaterial3D
var _mat_paper_glow: StandardMaterial3D
var _mat_chevron_board: StandardMaterial3D
var _mat_chevron_red_emissive: StandardMaterial3D

var _scenery_root: Node3D
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = random_seed
	_initialize_materials()
	
	# Auto-discover parent spline or frames if not explicitly invoked externally
	var parent_node: Node = get_parent()
	if parent_node != null and get_child_count() == 0:
		var discovered_curve: Curve3D = null
		var discovered_frames: Array = []
		
		if "road_curve" in parent_node and parent_node.get("road_curve") is Curve3D:
			discovered_curve = parent_node.get("road_curve")
		elif parent_node is Path3D and (parent_node as Path3D).curve != null:
			discovered_curve = (parent_node as Path3D).curve
			
		if "road_frames" in parent_node and parent_node.get("road_frames") is Array:
			discovered_frames = parent_node.get("road_frames")
			
		if discovered_curve != null or not discovered_frames.is_empty():
			decorate_touge(discovered_curve, discovered_frames)


## Primary entry point invoked by MountAkinaTouge.gd.
## Safely populates roadside MultiMeshes, catenary wires, Torii gates, and hairpin lighting.
func decorate_touge(road_curve: Curve3D, road_frames: Array = []) -> void:
	_rng.seed = random_seed
	if _mat_galvanized_steel == null:
		_initialize_materials()
		
	_clear_existing_scenery()
	_scenery_root = Node3D.new()
	_scenery_root.name = "AkinaProceduralScenery"
	add_child(_scenery_root)
	
	var sampled_frames: Array[Dictionary] = _extract_uniform_frames(road_curve, road_frames, 1.0)
	if sampled_frames.size() < 4:
		push_warning("AkinaRoadsidePropsDecorator: Insufficient spline data to decorate touge.")
		return
		
	_compute_frame_curvatures(sampled_frames)
	
	# Transform Accumulators for MultiMesh batches
	var guardrail_xforms: Array[Transform3D] = []
	var reflector_red_xforms: Array[Transform3D] = []
	var reflector_amber_xforms: Array[Transform3D] = []
	var concrete_pole_xforms: Array[Transform3D] = []
	var timber_pole_xforms: Array[Transform3D] = []
	var pole_anchor_transforms: Array[Transform3D] = []
	var streetlamp_xforms: Array[Transform3D] = []
	var stone_lantern_xforms: Array[Transform3D] = []
	var chevron_sign_xforms: Array[Transform3D] = []
	var cryptomeria_xforms: Array[Transform3D] = []
	var sakura_xforms: Array[Transform3D] = []
	var apex_light_positions: Array[Vector3] = []
	
	var total_length: float = sampled_frames.back()["distance"]
	var guard_Edge_offset: float = road_half_width + shoulder_margin
	var pole_edge_offset: float = guard_Edge_offset + 0.95
	
	# 1. Process Guardrails & Cat's Eye Retro-Reflectors (Every 4m / 8m)
	var dist_cursor: float = 0.0
	var guardrail_step_idx: int = 0
	while dist_cursor < total_length - guardrail_interval:
		var frame_a: Dictionary = _sample_frame_at_distance(sampled_frames, dist_cursor)
		var frame_b: Dictionary = _sample_frame_at_distance(sampled_frames, dist_cursor + guardrail_interval)
		
		var pos_a: Vector3 = frame_a["position"]
		var pos_b: Vector3 = frame_b["position"]
		var right_a: Vector3 = frame_a["right"]
		var up_a: Vector3 = frame_a["up"]
		var curv: float = frame_a["curvature"]
		
		# Outer cliff side always gets continuous double-beam barrier;
		# Inner mountain side gets barriers on high-speed straights and medium corners
		var spawn_left: bool = true
		var spawn_right: bool = true
		
		# Leave occasional mountain drainage gaps on ultra-low curvature inner edges
		if absf(curv) < 0.004 and (guardrail_step_idx % 19 == 0):
			spawn_left = false
			
		# Left Side Barrier (-right)
		if spawn_left:
			var left_pt_a: Vector3 = pos_a - right_a * guard_Edge_offset
			var left_pt_b: Vector3 = pos_b - (frame_b["right"] as Vector3) * guard_Edge_offset
			var seg_vec: Vector3 = left_pt_b - left_pt_a
			var seg_len: float = seg_vec.length()
			if seg_len > 0.1:
				var seg_fwd: Vector3 = seg_vec / seg_len
				var seg_right: Vector3 = up_a.cross(seg_fwd).normalized()
				var seg_up: Vector3 = seg_fwd.cross(seg_right).normalized()
				var mid_pt: Vector3 = (left_pt_a + left_pt_b) * 0.5
				var basis_l: Basis = Basis(seg_right, seg_up, seg_fwd).scaled(Vector3(1.0, 1.0, seg_len / guardrail_interval))
				guardrail_xforms.append(Transform3D(basis_l, mid_pt))
				
				# Retro-reflective Cat's Eye every 8 meters (Red on Left/Outside)
				if guardrail_step_idx % 2 == 0:
					var ref_pos: Vector3 = mid_pt + seg_up * 0.62 + seg_right * 0.11
					var ref_basis: Basis = Basis(seg_right, seg_up, seg_fwd)
					reflector_red_xforms.append(Transform3D(ref_basis, ref_pos))
					
		# Right Side Barrier (+right)
		if spawn_right:
			var right_pt_a: Vector3 = pos_a + right_a * guard_Edge_offset
			var right_pt_b: Vector3 = pos_b + (frame_b["right"] as Vector3) * guard_Edge_offset
			var seg_vec_r: Vector3 = right_pt_b - right_pt_a
			var seg_len_r: float = seg_vec_r.length()
			if seg_len_r > 0.1:
				var seg_fwd_r: Vector3 = seg_vec_r / seg_len_r
				# Invert X so corrugated W-beam profile faces inward toward the asphalt
				var seg_right_r: Vector3 = -up_a.cross(seg_fwd_r).normalized()
				var seg_up_r: Vector3 = seg_fwd_r.cross(-seg_right_r).normalized()
				var mid_pt_r: Vector3 = (right_pt_a + right_pt_b) * 0.5
				var basis_r: Basis = Basis(seg_right_r, seg_up_r, seg_fwd_r).scaled(Vector3(1.0, 1.0, seg_len_r / guardrail_interval))
				guardrail_xforms.append(Transform3D(basis_r, mid_pt_r))
				
				# Retro-reflective Cat's Eye every 8 meters (Amber on Right/Inside)
				if guardrail_step_idx % 2 == 0:
					var ref_pos_r: Vector3 = mid_pt_r + seg_up_r * 0.62 + seg_right_r * 0.11
					var ref_basis_r: Basis = Basis(seg_right_r, seg_up_r, seg_fwd_r)
					reflector_amber_xforms.append(Transform3D(ref_basis_r, ref_pos_r))
					
		dist_cursor += guardrail_interval
		guardrail_step_idx += 1

	# 2. Process 90s Japanese Concrete & Timber Utility Poles (Every 45m along mountain cut)
	var pole_dist: float = 15.0
	var pole_idx: int = 0
	while pole_dist < total_length - 10.0:
		var p_frame: Dictionary = _sample_frame_at_distance(sampled_frames, pole_dist)
		var p_pos: Vector3 = p_frame["position"]
		var p_right: Vector3 = p_frame["right"]
		var p_fwd: Vector3 = p_frame["forward"]
		
		# Place along right-hand mountain cutting edge with strictly vertical Y alignment
		var pole_world_pos: Vector3 = p_pos + p_right * pole_edge_offset
		var flat_fwd: Vector3 = Vector3(p_fwd.x, 0.0, p_fwd.z).normalized()
		if flat_fwd.length_squared() < 0.01:
			flat_fwd = Vector3.FORWARD
		var flat_right: Vector3 = Vector3.UP.cross(flat_fwd).normalized()
		var pole_basis: Basis = Basis(flat_right, Vector3.UP, flat_fwd)
		var pole_xform: Transform3D = Transform3D(pole_basis, pole_world_pos)
		
		if pole_idx % 4 == 3:
			timber_pole_xforms.append(pole_xform)
		else:
			concrete_pole_xforms.append(pole_xform)
			
		pole_anchor_transforms.append(pole_xform)
		pole_dist += utility_pole_interval
		pole_idx += 1

	# 3. Detect Hairpin Apexes (5 Consecutive Hairpins + Critical Touge Corners)
	var hairpin_zones: Array[Dictionary] = _detect_hairpin_apexes(sampled_frames)
	for zone: Dictionary in hairpin_zones:
		var apex_dist: float = zone["apex_distance"]
		var turn_sign: float = zone["turn_sign"] # +1.0 or -1.0
		var outside_dir_mult: float = -turn_sign if absf(turn_sign) > 0.01 else -1.0
		
		# Spawn 3 overhead warm sodium streetlamps per hairpin (Entry, Apex, Exit)
		var lamp_offsets: Array[float] = [-16.0, 0.0, 16.0]
		for l_off: float in lamp_offsets:
			var d_lamp: float = clampf(apex_dist + l_off, 5.0, total_length - 5.0)
			var l_frame: Dictionary = _sample_frame_at_distance(sampled_frames, d_lamp)
			var l_pos: Vector3 = l_frame["position"]
			var l_right: Vector3 = l_frame["right"]
			var l_fwd: Vector3 = l_frame["forward"]
			
			var side_offset: float = (guard_Edge_offset + 0.65) * outside_dir_mult
			var lamp_world_pos: Vector3 = l_pos + l_right * side_offset
			
			# Aim the overhang arm directly over the asphalt center
			var inward_dir: Vector3 = (-l_right * outside_dir_mult)
			inward_dir.y = 0.0
			inward_dir = inward_dir.normalized()
			if inward_dir.length_squared() < 0.01:
				inward_dir = Vector3.RIGHT
			var lamp_fwd: Vector3 = inward_dir.cross(Vector3.UP).normalized()
			var lamp_basis: Basis = Basis(inward_dir, Vector3.UP, lamp_fwd)
			streetlamp_xforms.append(Transform3D(lamp_basis, lamp_world_pos))
			
			# Record only the central apex lamp for actual OmniLight3D emission to save GPU cluster slots
			if is_zero_approx(l_off):
				var bulb_world_pos: Vector3 = lamp_world_pos + Vector3(0.0, 6.65, 0.0) + inward_dir * 2.15
				apex_light_positions.append(bulb_world_pos)
				
		# Spawn 5 retro-reflective Chevron turn signs along the outer hairpin guardrail sweep
		var chevron_offsets: Array[float] = [-20.0, -10.0, 0.0, 10.0, 20.0]
		for c_off: float in chevron_offsets:
			var d_chev: float = clampf(apex_dist + c_off, 5.0, total_length - 5.0)
			var c_frame: Dictionary = _sample_frame_at_distance(sampled_frames, d_chev)
			var c_pos: Vector3 = c_frame["position"]
			var c_right: Vector3 = c_frame["right"]
			var c_fwd: Vector3 = c_frame["forward"]
			
			var chev_world_pos: Vector3 = c_pos + c_right * ((guard_Edge_offset + 0.35) * outside_dir_mult)
			var face_dir: Vector3 = (-c_fwd - c_right * outside_dir_mult * 0.45).normalized()
			face_dir.y = 0.0
			face_dir = face_dir.normalized()
			var chev_right: Vector3 = Vector3.UP.cross(face_dir).normalized()
			var chev_basis: Basis = Basis(chev_right, Vector3.UP, face_dir)
			chevron_sign_xforms.append(Transform3D(chev_basis, chev_world_pos))
			
		# Spawn Traditional Stone Lanterns (Toro) on the inner apex verge
		var inner_mult: float = -outside_dir_mult
		for t_off: float in [-5.5, 5.5]:
			var d_toro: float = clampf(apex_dist + t_off, 5.0, total_length - 5.0)
			var t_frame: Dictionary = _sample_frame_at_distance(sampled_frames, d_toro)
			var toro_pos: Vector3 = (t_frame["position"] as Vector3) + (t_frame["right"] as Vector3) * ((guard_Edge_offset + 1.45) * inner_mult)
			var toro_rot: float = _rng.randf_range(0.0, TAU)
			var toro_basis: Basis = Basis.from_euler(Vector3(0.0, toro_rot, 0.0))
			stone_lantern_xforms.append(Transform3D(toro_basis, toro_pos))

	# 4. Spawn Traditional Red Lacquer Torii Gates (Summit Start Line & Mid-Way Shrine Trail)
	var start_frame: Dictionary = _sample_frame_at_distance(sampled_frames, minf(18.0, total_length * 0.05))
	_spawn_torii_gate_landmark(
		"SummitStartToriiGate",
		start_frame["position"],
		start_frame["forward"],
		start_frame["right"],
		(road_half_width + shoulder_margin + 1.15) * 2.0,
		7.8
	)
	
	var mid_shrine_dist: float = total_length * 0.48
	var shrine_frame: Dictionary = _sample_frame_at_distance(sampled_frames, mid_shrine_dist)
	var shrine_side_pos: Vector3 = (shrine_frame["position"] as Vector3) + (shrine_frame["right"] as Vector3) * (guard_Edge_offset + 5.2)
	var shrine_fwd: Vector3 = (shrine_frame["right"] as Vector3)
	shrine_fwd.y = 0.0
	shrine_fwd = shrine_fwd.normalized()
	var shrine_right: Vector3 = Vector3.UP.cross(shrine_fwd).normalized()
	_spawn_torii_gate_landmark(
		"MidwayShrineTrailToriiGate",
		shrine_side_pos,
		shrine_fwd,
		shrine_right,
		5.4,
		5.8
	)
	
	# Add Flanking Stone Lanterns at the Midway Shrine Trail Entrance
	for s_side: float in [-3.4, 3.4]:
		var s_toro_pos: Vector3 = shrine_side_pos + shrine_right * s_side - shrine_fwd * 1.5
		stone_lantern_xforms.append(Transform3D(Basis.IDENTITY, s_toro_pos))

	# 5. Dense Flora Scatter (Cryptomeria Japanese Pines & Accent Sakura Trees)
	# Strictly populated outside the asphalt + shoulder boundary using MultiMeshInstance3D
	var min_flora_clearance: float = road_half_width + shoulder_margin + 6.0
	var f_dist: float = 90.0
	while f_dist < total_length - 4.0:
		var f_frame: Dictionary = _sample_frame_at_distance(sampled_frames, f_dist)
		var f_pos: Vector3 = f_frame["position"]
		var f_right: Vector3 = f_frame["right"]
		var f_curv: float = absf(f_frame["curvature"])
		
		# Spawn 2 to 4 trees per longitudinal slice across both mountain banks
		for side_sign: float in [-1.0, 1.0]:
			var trees_per_bank: int = 2 if _rng.randf() < 0.65 else 1
			for layer_idx: int in range(trees_per_bank):
				var radial_min: float = min_flora_clearance + float(layer_idx) * 7.5
				var radial_max: float = radial_min + 8.5
				var lateral_dist: float = _rng.randf_range(radial_min, radial_max)
				var jitter_z: float = _rng.randf_range(-1.4, 1.4)
				
				var tree_pos: Vector3 = f_pos + f_right * (lateral_dist * side_sign) + (f_frame["forward"] as Vector3) * jitter_z
				# Natural mountain embankment slope elevation offset:
				# Right bank (+1) rises slightly up the mountain cut; left bank (-1) drops slightly down the ravine
				var bank_slope_y: float = (lateral_dist - min_flora_clearance) * (0.22 if side_sign > 0.0 else -0.18)
				tree_pos.y += bank_slope_y - 0.35
				
				var yaw: float = _rng.randf_range(0.0, TAU)
				var tilt_x: float = _rng.randf_range(-0.035, 0.035)
				var tilt_z: float = _rng.randf_range(-0.035, 0.035)
				
				# Higher Sakura accent probability near hairpin vistas and the mid-way shrine
				var near_shrine: bool = absf(f_dist - mid_shrine_dist) < 95.0
				var sakura_chance: float = 0.28 if (f_curv > hairpin_curvature_threshold * 0.75 or near_shrine) else 0.09
				var is_sakura: bool = (layer_idx == 0) and (_rng.randf() < sakura_chance)
				
				if is_sakura:
					var s_scale_xz: float = _rng.randf_range(0.85, 1.35)
					var s_scale_y: float = _rng.randf_range(0.88, 1.28)
					var s_basis: Basis = Basis.from_euler(Vector3(tilt_x, yaw, tilt_z)).scaled(Vector3(s_scale_xz, s_scale_y, s_scale_xz))
					sakura_xforms.append(Transform3D(s_basis, tree_pos))
				else:
					var p_scale_xz: float = _rng.randf_range(0.82, 1.45)
					var p_scale_y: float = _rng.randf_range(0.85, 1.65)
					var p_basis: Basis = Basis.from_euler(Vector3(tilt_x, yaw, tilt_z)).scaled(Vector3(p_scale_xz, p_scale_y, p_scale_xz))
					cryptomeria_xforms.append(Transform3D(p_basis, tree_pos))
					
		f_dist += flora_step_interval

	# 6. Instantiate & Commit All Hardware-Instanced MultiMesh Batches
	_create_multimesh_batch(
		"MM_Guardrails",
		_build_guardrail_segment_mesh(),
		guardrail_xforms,
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		guardrail_cull_distance
	)
	
	_create_multimesh_batch(
		"MM_ReflectorsRed",
		_build_cats_eye_reflector_mesh(_mat_reflector_red),
		reflector_red_xforms,
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		reflector_cull_distance
	)
	
	_create_multimesh_batch(
		"MM_ReflectorsAmber",
		_build_cats_eye_reflector_mesh(_mat_reflector_amber),
		reflector_amber_xforms,
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		reflector_cull_distance
	)
	
	_create_multimesh_batch(
		"MM_UtilityPolesConcrete",
		_build_utility_pole_mesh(false),
		concrete_pole_xforms,
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		pole_cull_distance
	)
	
	_create_multimesh_batch(
		"MM_UtilityPolesTimber",
		_build_utility_pole_mesh(true),
		timber_pole_xforms,
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		pole_cull_distance
	)
	
	_create_multimesh_batch(
		"MM_SodiumStreetlamps",
		_build_sodium_streetlamp_mesh(),
		streetlamp_xforms,
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		pole_cull_distance
	)
	
	_create_multimesh_batch(
		"MM_StoneLanterns",
		_build_stone_lantern_mesh(),
		stone_lantern_xforms,
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		detail_prop_cull_distance
	)
	
	_create_multimesh_batch(
		"MM_ChevronSigns",
		_build_chevron_sign_mesh(),
		chevron_sign_xforms,
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		detail_prop_cull_distance
	)
	
	_create_multimesh_batch(
		"MM_CryptomeriaPines",
		_build_cryptomeria_pine_mesh(),
		cryptomeria_xforms,
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		flora_cull_distance
	)
	
	_create_multimesh_batch(
		"MM_SakuraBlossoms",
		_build_sakura_tree_mesh(),
		sakura_xforms,
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		flora_cull_distance
	)
	
	# 7. Build Single-Draw Catenary Power Lines Mesh Connecting All Utility Poles
	_build_catenary_power_lines_node(pole_anchor_transforms)
	
	# 8. Spawn Distance-Culled Warm Sodium OmniLights at Hairpin Apexes
	if enable_apex_omni_lights:
		_spawn_hairpin_sodium_lights(apex_light_positions)


# ==============================================================================
# SPLINE INSPECTION & CURVATURE ANALYSIS
# ==============================================================================

func _extract_uniform_frames(road_curve: Curve3D, road_frames: Array, step_meters: float) -> Array[Dictionary]:
	var uniform_frames: Array[Dictionary] = []
	
	# Path A: Use Curve3D directly if provided and valid
	if road_curve != null and road_curve.get_point_count() >= 2:
		var baked_len: float = road_curve.get_baked_length()
		if baked_len > 1.0:
			var d: float = 0.0
			while d <= baked_len:
				var pos: Vector3 = road_curve.sample_baked(d, true)
				var pos_next: Vector3 = road_curve.sample_baked(minf(d + 1.0, baked_len), true)
				var fwd: Vector3 = (pos_next - pos).normalized()
				if fwd.length_squared() < 0.0001:
					fwd = Vector3.FORWARD
				var right: Vector3 = fwd.cross(Vector3.UP).normalized()
				if right.length_squared() < 0.0001:
					right = Vector3.RIGHT
				var up: Vector3 = right.cross(fwd).normalized()
				uniform_frames.append({
					"distance": d,
					"position": pos,
					"forward": fwd,
					"right": right,
					"up": up,
					"curvature": 0.0
				})
				d += step_meters
			return uniform_frames
			
	# Path B: Parse `road_frames` Array (Supports Transform3D, Dictionary, or Vector3 elements)
	var raw_points: Array[Dictionary] = []
	var accum_dist: float = 0.0
	for i: int in range(road_frames.size()):
		var item: Variant = road_frames[i]
		var pos: Vector3 = Vector3.ZERO
		var fwd: Vector3 = Vector3.FORWARD
		var right: Vector3 = Vector3.RIGHT
		var up: Vector3 = Vector3.UP
		var has_basis: bool = false
		
		if item is Transform3D:
			var xf: Transform3D = item as Transform3D
			pos = xf.origin
			fwd = -xf.basis.z.normalized()
			right = xf.basis.x.normalized()
			up = xf.basis.y.normalized()
			has_basis = true
		elif item is Dictionary:
			var dict: Dictionary = item as Dictionary
			if dict.has("transform") and dict["transform"] is Transform3D:
				var xf_d: Transform3D = dict["transform"]
				pos = xf_d.origin
				fwd = -xf_d.basis.z.normalized()
				right = xf_d.basis.x.normalized()
				up = xf_d.basis.y.normalized()
				has_basis = true
			else:
				if dict.has("position"):
					pos = dict["position"]
				elif dict.has("origin"):
					pos = dict["origin"]
				if dict.has("forward"):
					fwd = (dict["forward"] as Vector3).normalized()
					has_basis = true
				if dict.has("right"):
					right = (dict["right"] as Vector3).normalized()
				if dict.has("up"):
					up = (dict["up"] as Vector3).normalized()
		elif item is Vector3:
			pos = item as Vector3
		elif item is Node3D:
			var n3d: Node3D = item as Node3D
			pos = n3d.global_position
			fwd = -n3d.global_transform.basis.z.normalized()
			right = n3d.global_transform.basis.x.normalized()
			up = n3d.global_transform.basis.y.normalized()
			has_basis = true
			
		if i > 0:
			accum_dist += pos.distance_to(raw_points[i - 1]["position"])
			
		raw_points.append({
			"distance": accum_dist,
			"position": pos,
			"forward": fwd,
			"right": right,
			"up": up,
			"has_basis": has_basis,
			"curvature": 0.0
		})
		
	if raw_points.size() < 2:
		return uniform_frames
		
	# Reconstruct orthonormal tangents if input only supplied positions
	for i: int in range(raw_points.size()):
		if not raw_points[i]["has_basis"]:
			var p_prev: Vector3 = raw_points[maxi(0, i - 1)]["position"]
			var p_next: Vector3 = raw_points[mini(raw_points.size() - 1, i + 1)]["position"]
			var f_vec: Vector3 = (p_next - p_prev).normalized()
			if f_vec.length_squared() < 0.001:
				f_vec = Vector3.FORWARD
			var r_vec: Vector3 = f_vec.cross(Vector3.UP).normalized()
			var u_vec: Vector3 = r_vec.cross(f_vec).normalized()
			raw_points[i]["forward"] = f_vec
			raw_points[i]["right"] = r_vec
			raw_points[i]["up"] = u_vec
			
	# Resample raw frames at uniform `step_meters` intervals
	var total_raw_len: float = raw_points.back()["distance"]
	var cursor: float = 0.0
	var seg_idx: int = 0
	while cursor <= total_raw_len:
		while seg_idx < raw_points.size() - 2 and raw_points[seg_idx + 1]["distance"] < cursor:
			seg_idx += 1
		var fa: Dictionary = raw_points[seg_idx]
		var fb: Dictionary = raw_points[seg_idx + 1]
		var span: float = maxf(0.0001, fb["distance"] - fa["distance"])
		var t: float = clampf((cursor - fa["distance"]) / span, 0.0, 1.0)
		
		var interp_pos: Vector3 = (fa["position"] as Vector3).lerp(fb["position"] as Vector3, t)
		var interp_fwd: Vector3 = (fa["forward"] as Vector3).lerp(fb["forward"] as Vector3, t).normalized()
		var interp_up: Vector3 = (fa["up"] as Vector3).lerp(fb["up"] as Vector3, t).normalized()
		var interp_right: Vector3 = interp_fwd.cross(interp_up).normalized()
		interp_up = interp_right.cross(interp_fwd).normalized()
		
		uniform_frames.append({
			"distance": cursor,
			"position": interp_pos,
			"forward": interp_fwd,
			"right": interp_right,
			"up": interp_up,
			"curvature": 0.0
		})
		cursor += step_meters
		
	return uniform_frames


func _compute_frame_curvatures(frames: Array[Dictionary]) -> void:
	var count: int = frames.size()
	var window: int = 4
	for i: int in range(count):
		var idx_prev: int = maxi(0, i - window)
		var idx_next: int = mini(count - 1, i + window)
		var ds: float = frames[idx_next]["distance"] - frames[idx_prev]["distance"]
		if ds < 0.1:
			frames[i]["curvature"] = 0.0
			continue
		var fwd_a: Vector3 = frames[idx_prev]["forward"]
		var fwd_b: Vector3 = frames[idx_next]["forward"]
		var flat_a: Vector2 = Vector2(fwd_a.x, fwd_a.z).normalized()
		var flat_b: Vector2 = Vector2(fwd_b.x, fwd_b.z).normalized()
		var signed_angle: float = flat_a.angle_to(flat_b)
		frames[i]["curvature"] = signed_angle / ds


func _sample_frame_at_distance(frames: Array[Dictionary], target_dist: float) -> Dictionary:
	if frames.is_empty():
		return {
			"distance": 0.0,
			"position": Vector3.ZERO,
			"forward": Vector3.FORWARD,
			"right": Vector3.RIGHT,
			"up": Vector3.UP,
			"curvature": 0.0
		}
	var clamped_d: float = clampf(target_dist, 0.0, frames.back()["distance"])
	var low: int = 0
	var high: int = frames.size() - 1
	while low < high:
		var mid: int = (low + high) >> 1
		if frames[mid]["distance"] < clamped_d:
			low = mid + 1
		else:
			high = mid
	var idx_b: int = low
	var idx_a: int = maxi(0, idx_b - 1)
	if idx_a == idx_b:
		return frames[idx_a]
	var fa: Dictionary = frames[idx_a]
	var fb: Dictionary = frames[idx_b]
	var span: float = maxf(0.0001, fb["distance"] - fa["distance"])
	var t: float = clampf((clamped_d - fa["distance"]) / span, 0.0, 1.0)
	
	var pos: Vector3 = (fa["position"] as Vector3).lerp(fb["position"] as Vector3, t)
	var fwd: Vector3 = (fa["forward"] as Vector3).lerp(fb["forward"] as Vector3, t).normalized()
	var up: Vector3 = (fa["up"] as Vector3).lerp(fb["up"] as Vector3, t).normalized()
	var right: Vector3 = fwd.cross(up).normalized()
	up = right.cross(fwd).normalized()
	var curv: float = lerpf(fa["curvature"], fb["curvature"], t)
	
	return {
		"distance": clamped_d,
		"position": pos,
		"forward": fwd,
		"right": right,
		"up": up,
		"curvature": curv
	}


func _detect_hairpin_apexes(frames: Array[Dictionary]) -> Array[Dictionary]:
	var candidate_peaks: Array[Dictionary] = []
	var min_peak_separation: float = 85.0
	
	for i: int in range(6, frames.size() - 6):
		var c_val: float = absf(frames[i]["curvature"])
		if c_val >= hairpin_curvature_threshold:
			var is_local_max: bool = true
			for k: int in range(-5, 6):
				if k != 0 and absf(frames[i + k]["curvature"]) > c_val:
					is_local_max = false
					break
			if is_local_max:
				var d: float = frames[i]["distance"]
				if candidate_peaks.is_empty() or (d - candidate_peaks.back()["apex_distance"]) >= min_peak_separation:
					candidate_peaks.append({
						"apex_distance": d,
						"curvature_mag": c_val,
						"turn_sign": signf(frames[i]["curvature"])
					})
				elif c_val > candidate_peaks.back()["curvature_mag"]:
					candidate_peaks[candidate_peaks.size() - 1] = {
						"apex_distance": d,
						"curvature_mag": c_val,
						"turn_sign": signf(frames[i]["curvature"])
					}
					
	# Guarantee the iconic 5 consecutive hairpins even if a test spline has gentler curvature
	if candidate_peaks.size() < 5 and not frames.is_empty():
		var total_len: float = frames.back()["distance"]
		candidate_peaks.clear()
		var hairpin_ratios: Array[float] = [0.54, 0.63, 0.72, 0.81, 0.90]
		for idx: int in range(hairpin_ratios.size()):
			var d_fallback: float = total_len * hairpin_ratios[idx]
			var f_sample: Dictionary = _sample_frame_at_distance(frames, d_fallback)
			var sign_val: float = signf(f_sample["curvature"])
			if is_zero_approx(sign_val):
				sign_val = 1.0 if (idx % 2 == 0) else -1.0
			candidate_peaks.append({
				"apex_distance": d_fallback,
				"curvature_mag": maxf(absf(f_sample["curvature"]), hairpin_curvature_threshold),
				"turn_sign": sign_val
			})
			
	return candidate_peaks


# ==============================================================================
# MATERIAL INITIALIZATION (100% PROCEDURAL STANDARDMATERIAL3D)
# ==============================================================================

func _initialize_materials() -> void:
	_mat_galvanized_steel = StandardMaterial3D.new()
	_mat_galvanized_steel.albedo_color = Color(0.68, 0.71, 0.74)
	_mat_galvanized_steel.metallic = 0.82
	_mat_galvanized_steel.roughness = 0.36
	_mat_galvanized_steel.cull_mode = BaseMaterial3D.CULL_DISABLED

	_mat_dark_steel_post = StandardMaterial3D.new()
	_mat_dark_steel_post.albedo_color = Color(0.26, 0.28, 0.30)
	_mat_dark_steel_post.metallic = 0.75
	_mat_dark_steel_post.roughness = 0.48

	_mat_reflector_red = StandardMaterial3D.new()
	_mat_reflector_red.albedo_color = Color(0.95, 0.12, 0.12)
	_mat_reflector_red.roughness = 0.15
	_mat_reflector_red.emission_enabled = true
	_mat_reflector_red.emission = Color(1.0, 0.15, 0.08)
	_mat_reflector_red.emission_energy_multiplier = 3.2

	_mat_reflector_amber = StandardMaterial3D.new()
	_mat_reflector_amber.albedo_color = Color(1.0, 0.65, 0.05)
	_mat_reflector_amber.roughness = 0.15
	_mat_reflector_amber.emission_enabled = true
	_mat_reflector_amber.emission = Color(1.0, 0.60, 0.02)
	_mat_reflector_amber.emission_energy_multiplier = 3.0

	_mat_concrete_pole = StandardMaterial3D.new()
	_mat_concrete_pole.albedo_color = Color(0.56, 0.57, 0.55)
	_mat_concrete_pole.roughness = 0.88
	_mat_concrete_pole.metallic = 0.05

	_mat_timber_pole = StandardMaterial3D.new()
	_mat_timber_pole.albedo_color = Color(0.28, 0.20, 0.14)
	_mat_timber_pole.roughness = 0.90

	_mat_porcelain_insulator = StandardMaterial3D.new()
	_mat_porcelain_insulator.albedo_color = Color(0.88, 0.92, 0.94)
	_mat_porcelain_insulator.roughness = 0.18
	_mat_porcelain_insulator.metallic = 0.10

	_mat_power_wire = StandardMaterial3D.new()
	_mat_power_wire.albedo_color = Color(0.08, 0.09, 0.10)
	_mat_power_wire.roughness = 0.55
	_mat_power_wire.metallic = 0.40

	_mat_torii_vermilion = StandardMaterial3D.new()
	_mat_torii_vermilion.albedo_color = Color(0.82, 0.14, 0.09)
	_mat_torii_vermilion.roughness = 0.28
	_mat_torii_vermilion.metallic = 0.08

	_mat_torii_black_base = StandardMaterial3D.new()
	_mat_torii_black_base.albedo_color = Color(0.09, 0.09, 0.10)
	_mat_torii_black_base.roughness = 0.42

	_mat_torii_gold_plaque = StandardMaterial3D.new()
	_mat_torii_gold_plaque.albedo_color = Color(0.88, 0.72, 0.22)
	_mat_torii_gold_plaque.metallic = 0.90
	_mat_torii_gold_plaque.roughness = 0.24

	_mat_pine_bark = StandardMaterial3D.new()
	_mat_pine_bark.albedo_color = Color(0.27, 0.18, 0.13)
	_mat_pine_bark.roughness = 0.92

	_mat_pine_needles = StandardMaterial3D.new()
	_mat_pine_needles.albedo_color = Color(0.11, 0.24, 0.14)
	_mat_pine_needles.roughness = 0.82

	_mat_sakura_bark = StandardMaterial3D.new()
	_mat_sakura_bark.albedo_color = Color(0.24, 0.19, 0.18)
	_mat_sakura_bark.roughness = 0.86

	_mat_sakura_blossom = StandardMaterial3D.new()
	_mat_sakura_blossom.albedo_color = Color(0.96, 0.73, 0.81)
	_mat_sakura_blossom.roughness = 0.68
	_mat_sakura_blossom.emission_enabled = true
	_mat_sakura_blossom.emission = Color(0.95, 0.65, 0.76)
	_mat_sakura_blossom.emission_energy_multiplier = 0.18

	_mat_sodium_bulb = StandardMaterial3D.new()
	_mat_sodium_bulb.albedo_color = Color(1.0, 0.78, 0.35)
	_mat_sodium_bulb.emission_enabled = true
	_mat_sodium_bulb.emission = Color(1.0, 0.68, 0.18)
	_mat_sodium_bulb.emission_energy_multiplier = 5.5

	_mat_stone_lantern = StandardMaterial3D.new()
	_mat_stone_lantern.albedo_color = Color(0.46, 0.47, 0.44)
	_mat_stone_lantern.roughness = 0.94

	_mat_paper_glow = StandardMaterial3D.new()
	_mat_paper_glow.albedo_color = Color(1.0, 0.85, 0.55)
	_mat_paper_glow.emission_enabled = true
	_mat_paper_glow.emission = Color(1.0, 0.72, 0.32)
	_mat_paper_glow.emission_energy_multiplier = 2.6

	_mat_chevron_board = StandardMaterial3D.new()
	_mat_chevron_board.albedo_color = Color(0.92, 0.93, 0.94)
	_mat_chevron_board.roughness = 0.30

	_mat_chevron_red_emissive = StandardMaterial3D.new()
	_mat_chevron_red_emissive.albedo_color = Color(0.90, 0.12, 0.10)
	_mat_chevron_red_emissive.roughness = 0.25
	_mat_chevron_red_emissive.emission_enabled = true
	_mat_chevron_red_emissive.emission = Color(0.95, 0.15, 0.08)
	_mat_chevron_red_emissive.emission_energy_multiplier = 1.4


# ==============================================================================
# PROCEDURAL ARRAYMESH GENERATORS (ZERO EXTERNAL BINARY ASSETS)
# ==============================================================================

## Builds a 4-meter Japanese Double-Beam Galvanized W-Profile Guardrail with I-Beam support posts.
func _build_guardrail_segment_mesh() -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	
	# Surface 0: Corrugated Double W-Beam Galvanized Rails
	var st_rail: SurfaceTool = SurfaceTool.new()
	st_rail.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_rail.set_material(_mat_galvanized_steel)
	
	var half_len: float = guardrail_interval * 0.5
	# Profile cross-section in XY (X = road-facing offset, Y = height offset)
	var w_profile: Array[Vector2] = [
		Vector2(0.04, 0.13),
		Vector2(0.09, 0.07),
		Vector2(0.03, 0.00),
		Vector2(0.09, -0.07),
		Vector2(0.04, -0.13)
	]
	
	# Double-beam heights: primary upper rail (0.62m) and secondary lower touge rail (0.31m)
	for beam_y: float in [0.62, 0.31]:
		for i: int in range(w_profile.size() - 1):
			var p0: Vector2 = w_profile[i]
			var p1: Vector2 = w_profile[i + 1]
			var v00: Vector3 = Vector3(p0.x, beam_y + p0.y, -half_len)
			var v01: Vector3 = Vector3(p0.x, beam_y + p0.y, half_len)
			var v11: Vector3 = Vector3(p1.x, beam_y + p1.y, half_len)
			var v10: Vector3 = Vector3(p1.x, beam_y + p1.y, -half_len)
			_st_add_quad(st_rail, v00, v01, v11, v10)
			
	st_rail.commit(mesh)
	
	# Surface 1: Galvanized Steel Support Posts at Z = -1.0m and Z = +1.0m
	var st_post: SurfaceTool = SurfaceTool.new()
	st_post.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_post.set_material(_mat_dark_steel_post)
	for post_z: float in [-half_len * 0.5, half_len * 0.5]:
		_st_add_box(st_post, Vector3(-0.04, 0.39, post_z), Vector3(0.10, 0.82, 0.10))
		# Post mounting blockout bracket
		_st_add_box(st_post, Vector3(0.01, 0.62, post_z), Vector3(0.08, 0.14, 0.08))
	st_post.commit(mesh)
	
	return mesh


## Builds a retro-reflective Touge Cat's Eye disc + galvanized mounting bracket.
func _build_cats_eye_reflector_mesh(reflective_mat: StandardMaterial3D) -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	
	# Surface 0: Metal Mounting Bracket
	var st_bracket: SurfaceTool = SurfaceTool.new()
	st_bracket.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_bracket.set_material(_mat_dark_steel_post)
	_st_add_box(st_bracket, Vector3(-0.01, 0.0, 0.0), Vector3(0.04, 0.09, 0.09))
	st_bracket.commit(mesh)
	
	# Surface 1: Emissive Retro-Reflective Disc (Visible from both uphill and downhill directions)
	var st_lens: SurfaceTool = SurfaceTool.new()
	st_lens.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_lens.set_material(reflective_mat)
	_st_add_box(st_lens, Vector3(0.015, 0.0, 0.0), Vector3(0.025, 0.075, 0.075))
	st_lens.commit(mesh)
	
	return mesh


## Builds a 1990s Japanese Utility Pole (Concrete or Timber) with Dual Crossarms,
## Pole-Mounted Cylindrical Transformer Drum, and 6 Porcelain Insulators.
func _build_utility_pole_mesh(is_timber: bool) -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	
	# Surface 0: Tapered 10.5m Main Pole Shaft
	var st_pole: SurfaceTool = SurfaceTool.new()
	st_pole.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_pole.set_material(_mat_timber_pole if is_timber else _mat_concrete_pole)
	_st_add_tapered_cylinder(st_pole, Vector3(0.0, 5.1, 0.0), 0.21, 0.12, 10.6, 10)
	st_pole.commit(mesh)
	
	# Surface 1: Galvanized Steel Crossarms, Diagonal Brace, and Pole-Mounted Transformer Canister
	var st_hardware: SurfaceTool = SurfaceTool.new()
	st_hardware.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_hardware.set_material(_mat_dark_steel_post)
	# Upper 3-Phase Crossarm (Y = 9.6m) & Lower Distribution Crossarm (Y = 8.4m)
	_st_add_box(st_hardware, Vector3(-0.35, 9.60, 0.0), Vector3(2.20, 0.10, 0.10))
	_st_add_box(st_hardware, Vector3(-0.35, 8.40, 0.0), Vector3(1.80, 0.09, 0.09))
	# Steel Mounting Collar Bands
	_st_add_box(st_hardware, Vector3(0.0, 9.60, 0.0), Vector3(0.30, 0.16, 0.30))
	_st_add_box(st_hardware, Vector3(0.0, 8.40, 0.0), Vector3(0.32, 0.16, 0.32))
	_st_add_box(st_hardware, Vector3(0.0, 6.75, 0.0), Vector3(0.35, 0.18, 0.35))
	# Japanese Cylindrical Pole Transformer Drum (Mounted at Y = 6.75m)
	_st_add_tapered_cylinder(st_hardware, Vector3(-0.48, 6.75, 0.0), 0.28, 0.28, 0.92, 10)
	st_hardware.commit(mesh)
	
	# Surface 2: High-Voltage White Porcelain Pin Insulators
	var st_ins: SurfaceTool = SurfaceTool.new()
	st_ins.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_ins.set_material(_mat_porcelain_insulator)
	var insulator_x_offsets: Array[float] = [-1.25, -0.35, 0.55]
	for ix: float in insulator_x_offsets:
		_st_add_tapered_cylinder(st_ins, Vector3(ix, 9.76, 0.0), 0.055, 0.04, 0.22, 8)
		_st_add_tapered_cylinder(st_ins, Vector3(ix * 0.82, 8.54, 0.0), 0.05, 0.035, 0.18, 8)
	st_ins.commit(mesh)
	
	return mesh


## Builds a Japanese Touge Overhead Cobra-Head Streetlamp with Warm Sodium Bulb.
func _build_sodium_streetlamp_mesh() -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	
	# Surface 0: Steel Mast, Curved Overhang Boom, and Cobra Hood
	var st_mast: SurfaceTool = SurfaceTool.new()
	st_mast.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_mast.set_material(_mat_galvanized_steel)
	# Vertical Mast (6.5m tall)
	_st_add_tapered_cylinder(st_mast, Vector3(0.0, 3.25, 0.0), 0.14, 0.09, 6.5, 8)
	# Overhanging Cantilever Arm extending +X over the road
	_st_add_box(st_mast, Vector3(1.05, 6.62, 0.0), Vector3(2.15, 0.08, 0.08))
	# Cobra-Head Housing
	_st_add_box(st_mast, Vector3(2.15, 6.68, 0.0), Vector3(0.62, 0.14, 0.34))
	st_mast.commit(mesh)
	
	# Surface 1: Warm High-Pressure Sodium Emissive Diffuser Lens
	var st_bulb: SurfaceTool = SurfaceTool.new()
	st_bulb.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_bulb.set_material(_mat_sodium_bulb)
	_st_add_box(st_bulb, Vector3(2.15, 6.59, 0.0), Vector3(0.46, 0.06, 0.24))
	st_bulb.commit(mesh)
	
	return mesh


## Builds a Traditional Japanese Tachi-gata Stone Lantern (Toro) with Warm Paper Glow.
func _build_stone_lantern_mesh() -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	
	# Surface 0: Carved Granite Pedestal, Post, and Pagoda Roof (Kasa)
	var st_stone: SurfaceTool = SurfaceTool.new()
	st_stone.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_stone.set_material(_mat_stone_lantern)
	# Base Plinth (Kiso)
	_st_add_box(st_stone, Vector3(0.0, 0.12, 0.0), Vector3(0.68, 0.24, 0.68))
	# Vertical Shaft (Sao)
	_st_add_tapered_cylinder(st_stone, Vector3(0.0, 0.68, 0.0), 0.16, 0.14, 0.88, 6)
	# Middle Platform (Chudai)
	_st_add_box(st_stone, Vector3(0.0, 1.18, 0.0), Vector3(0.56, 0.14, 0.56))
	# Pagoda Canopy Roof (Kasa) + Finial (Hoju)
	_st_add_tapered_cylinder(st_stone, Vector3(0.0, 1.82, 0.0), 0.58, 0.08, 0.36, 6)
	_st_add_tapered_cylinder(st_stone, Vector3(0.0, 2.08, 0.0), 0.10, 0.01, 0.20, 6)
	st_stone.commit(mesh)
	
	# Surface 1: Illuminated Firebox Chamber (Hibukuro)
	var st_glow: SurfaceTool = SurfaceTool.new()
	st_glow.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_glow.set_material(_mat_paper_glow)
	_st_add_box(st_glow, Vector3(0.0, 1.45, 0.0), Vector3(0.34, 0.40, 0.34))
	st_glow.commit(mesh)
	
	return mesh


## Builds a Retro-Reflective Japanese Hairpin Chevron Warning Sign.
func _build_chevron_sign_mesh() -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	
	# Surface 0: Steel Post & White Sign Backing
	var st_base: SurfaceTool = SurfaceTool.new()
	st_base.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_base.set_material(_mat_chevron_board)
	_st_add_tapered_cylinder(st_base, Vector3(0.0, 0.75, 0.0), 0.045, 0.045, 1.50, 6)
	_st_add_box(st_base, Vector3(0.0, 1.35, 0.04), Vector3(0.60, 0.72, 0.04))
	st_base.commit(mesh)
	
	# Surface 1: Emissive Red Warning Stripes
	var st_red: SurfaceTool = SurfaceTool.new()
	st_red.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_red.set_material(_mat_chevron_red_emissive)
	_st_add_box(st_red, Vector3(0.0, 1.52, 0.065), Vector3(0.48, 0.16, 0.02))
	_st_add_box(st_red, Vector3(0.0, 1.18, 0.065), Vector3(0.48, 0.16, 0.02))
	st_red.commit(mesh)
	
	return mesh


## Builds a Low-Poly Japanese Cryptomeria (Sugi) Cedar/Pine Tree (Trunk + 4 Tiered Cones).
func _build_cryptomeria_pine_mesh() -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	
	# Surface 0: Tall Tapered Cedar Trunk
	var st_trunk: SurfaceTool = SurfaceTool.new()
	st_trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_trunk.set_material(_mat_pine_bark)
	_st_add_tapered_cylinder(st_trunk, Vector3(0.0, 2.6, 0.0), 0.34, 0.12, 5.2, 7)
	st_trunk.commit(mesh)
	
	# Surface 1: 4 Stacked Low-Poly Conical Needle Tiers
	var st_foliage: SurfaceTool = SurfaceTool.new()
	st_foliage.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_foliage.set_material(_mat_pine_needles)
	_st_add_tapered_cylinder(st_foliage, Vector3(0.0, 3.8, 0.0), 2.35, 0.45, 3.4, 7)
	_st_add_tapered_cylinder(st_foliage, Vector3(0.0, 6.0, 0.0), 1.95, 0.35, 3.2, 7)
	_st_add_tapered_cylinder(st_foliage, Vector3(0.0, 8.1, 0.0), 1.45, 0.22, 2.9, 7)
	_st_add_tapered_cylinder(st_foliage, Vector3(0.0, 10.1, 0.0), 0.92, 0.02, 2.5, 7)
	st_foliage.commit(mesh)
	
	return mesh


## Builds an Accent Japanese Sakura (Cherry Blossom) Tree (Split Boughs + Pink Canopy Clusters).
func _build_sakura_tree_mesh() -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	
	# Surface 0: Gnarled Trunk & Primary Branches
	var st_trunk: SurfaceTool = SurfaceTool.new()
	st_trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_trunk.set_material(_mat_sakura_bark)
	_st_add_tapered_cylinder(st_trunk, Vector3(0.0, 1.65, 0.0), 0.36, 0.22, 3.3, 7)
	_st_add_box(st_trunk, Vector3(-0.55, 3.1, 0.25), Vector3(1.25, 0.18, 0.18))
	_st_add_box(st_trunk, Vector3(0.55, 3.25, -0.25), Vector3(1.25, 0.18, 0.18))
	st_trunk.commit(mesh)
	
	# Surface 1: Low-Poly Geodesic Blossom Cloud Clusters
	var st_blossom: SurfaceTool = SurfaceTool.new()
	st_blossom.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_blossom.set_material(_mat_sakura_blossom)
	_st_add_lowpoly_sphere(st_blossom, Vector3(0.0, 4.5, 0.0), 2.15, 8, 5)
	_st_add_lowpoly_sphere(st_blossom, Vector3(-1.35, 3.85, 0.55), 1.45, 7, 4)
	_st_add_lowpoly_sphere(st_blossom, Vector3(1.30, 3.95, -0.45), 1.50, 7, 4)
	_st_add_lowpoly_sphere(st_blossom, Vector3(0.25, 4.10, 1.25), 1.35, 7, 4)
	st_blossom.commit(mesh)
	
	return mesh


# ==============================================================================
# CATENARY POWER LINES & LANDMARK SPAWNERS
# ==============================================================================

## Generates a single consolidated ArrayMesh containing all 3-phase catenary sagging power lines
## across the entire 3.5 km downhill course.
func _build_catenary_power_lines_node(pole_transforms: Array[Transform3D]) -> void:
	if pole_transforms.size() < 2:
		return
		
	var st_wires: SurfaceTool = SurfaceTool.new()
	st_wires.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_wires.set_material(_mat_power_wire)
	
	# Local insulator tips on the upper 3-phase crossarm
	var insulator_local_tips: Array[Vector3] = [
		Vector3(-1.25, 9.86, 0.0),
		Vector3(-0.35, 9.86, 0.0),
		Vector3(0.55, 9.86, 0.0)
	]
	var subdivisions_per_span: int = 8
	var wire_half_thickness: float = 0.022
	
	for i: int in range(pole_transforms.size() - 1):
		var xf_a: Transform3D = pole_transforms[i]
		var xf_b: Transform3D = pole_transforms[i + 1]
		var span_dist: float = xf_a.origin.distance_to(xf_b.origin)
		# Skip wire generation if two poles are across a hairpin cut (> 75m apart)
		if span_dist > utility_pole_interval * 1.75:
			continue
			
		var max_sag: float = clampf(span_dist * 0.032, 0.65, 1.85)
		
		for wire_offset: Vector3 in insulator_local_tips:
			var start_pt: Vector3 = xf_a * wire_offset
			var end_pt: Vector3 = xf_b * wire_offset
			
			for s: int in range(subdivisions_per_span):
				var t0: float = float(s) / float(subdivisions_per_span)
				var t1: float = float(s + 1) / float(subdivisions_per_span)
				
				var sag0: float = 4.0 * max_sag * t0 * (1.0 - t0)
				var sag1: float = 4.0 * max_sag * t1 * (1.0 - t1)
				
				var p0: Vector3 = start_pt.lerp(end_pt, t0) - Vector3(0.0, sag0, 0.0)
				var p1: Vector3 = start_pt.lerp(end_pt, t1) - Vector3(0.0, sag1, 0.0)
				
				# Cross-ribbon quad pair for high visibility at low pixel sizes
				var v_up: Vector3 = Vector3(0.0, wire_half_thickness, 0.0)
				_st_add_quad(st_wires, p0 - v_up, p1 - v_up, p1 + v_up, p0 + v_up)
				_st_add_quad(st_wires, p0 + v_up, p1 + v_up, p1 - v_up, p0 - v_up)
				
	var wire_mesh: ArrayMesh = st_wires.commit()
	var wire_instance: MeshInstance3D = MeshInstance3D.new()
	wire_instance.name = "CatenaryPowerLinesMesh"
	wire_instance.mesh = wire_mesh
	wire_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wire_instance.visibility_range_end = pole_cull_distance
	wire_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	_scenery_root.add_child(wire_instance)


## Spawns a Traditional Japanese Red Lacquer Myojin Torii Gate with curved Kasagi lintel and Gakuzuka plaque.
func _spawn_torii_gate_landmark(
	node_name: String,
	center_pos: Vector3,
	forward_dir: Vector3,
	right_dir: Vector3,
	column_span: float,
	gate_height: float
) -> void:
	var torii_mesh: ArrayMesh = ArrayMesh.new()
	var half_span: float = column_span * 0.5
	var col_radius: float = clampf(gate_height * 0.048, 0.24, 0.42)
	
	# Surface 0: Black Basalt Pedestal Shoes (Kamebara / Nemaki)
	var st_black: SurfaceTool = SurfaceTool.new()
	st_black.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_black.set_material(_mat_torii_black_base)
	var base_h: float = gate_height * 0.18
	_st_add_tapered_cylinder(st_black, Vector3(-half_span, base_h * 0.5, 0.0), col_radius * 1.28, col_radius * 1.15, base_h, 12)
	_st_add_tapered_cylinder(st_black, Vector3(half_span, base_h * 0.5, 0.0), col_radius * 1.28, col_radius * 1.15, base_h, 12)
	# Upper black cap liner on Kasagi lintel
	var lintel_span: float = column_span + 3.4
	_st_add_box(st_black, Vector3(0.0, gate_height + 0.34, 0.0), Vector3(lintel_span, 0.16, col_radius * 2.4))
	# Swept-up wing tips (Sorimashi)
	_st_add_box(st_black, Vector3(-lintel_span * 0.52, gate_height + 0.46, 0.0), Vector3(1.15, 0.22, col_radius * 2.45))
	_st_add_box(st_black, Vector3(lintel_span * 0.52, gate_height + 0.46, 0.0), Vector3(1.15, 0.22, col_radius * 2.45))
	st_black.commit(torii_mesh)
	
	# Surface 1: Traditional Vermilion Lacquer Pillars (Hashira), Tie-Beam (Nuki), and Lintel (Shimaki)
	var st_red: SurfaceTool = SurfaceTool.new()
	st_red.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_red.set_material(_mat_torii_vermilion)
	# Left & Right Hashira Pillars
	_st_add_tapered_cylinder(st_red, Vector3(-half_span, gate_height * 0.5, 0.0), col_radius, col_radius * 0.88, gate_height, 12)
	_st_add_tapered_cylinder(st_red, Vector3(half_span, gate_height * 0.5, 0.0), col_radius, col_radius * 0.88, gate_height, 12)
	# Upper Shimaki Lintel Beam
	_st_add_box(st_red, Vector3(0.0, gate_height + 0.08, 0.0), Vector3(lintel_span - 0.3, 0.42, col_radius * 2.1))
	# Lower Nuki Penetrating Tie-Beam
	var nuki_y: float = gate_height * 0.78
	_st_add_box(st_red, Vector3(0.0, nuki_y, 0.0), Vector3(column_span + 1.85, 0.32, col_radius * 1.45))
	# Central Strut (Gakuzuka)
	var strut_h: float = (gate_height - nuki_y)
	_st_add_box(st_red, Vector3(0.0, nuki_y + strut_h * 0.5, 0.0), Vector3(0.38, strut_h, col_radius * 1.3))
	st_red.commit(torii_mesh)
	
	# Surface 2: Gold-Trimmed Shrine Nameplate (Gaku)
	var st_gold: SurfaceTool = SurfaceTool.new()
	st_gold.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_gold.set_material(_mat_torii_gold_plaque)
	_st_add_box(st_gold, Vector3(0.0, nuki_y + strut_h * 0.52, 0.0), Vector3(0.72, strut_h * 0.78, col_radius * 1.55))
	st_gold.commit(torii_mesh)
	
	var gate_inst: MeshInstance3D = MeshInstance3D.new()
	gate_inst.name = node_name
	gate_inst.mesh = torii_mesh
	gate_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	gate_inst.visibility_range_end = flora_cull_distance
	
	var flat_fwd: Vector3 = Vector3(forward_dir.x, 0.0, forward_dir.z).normalized()
	if flat_fwd.length_squared() < 0.01:
		flat_fwd = Vector3.FORWARD
	var flat_right: Vector3 = Vector3(right_dir.x, 0.0, right_dir.z).normalized()
	if flat_right.length_squared() < 0.01:
		flat_right = Vector3.UP.cross(flat_fwd).normalized()
		
	gate_inst.transform = Transform3D(Basis(flat_right, Vector3.UP, flat_fwd), center_pos)
	_scenery_root.add_child(gate_inst)


## Spawns distance-culled, non-shadow-casting Warm Sodium OmniLights at the 5 Hairpin Apexes.
func _spawn_hairpin_sodium_lights(light_positions: Array[Vector3]) -> void:
	var lights_container: Node3D = Node3D.new()
	lights_container.name = "HairpinApexSodiumLights"
	_scenery_root.add_child(lights_container)
	
	for i: int in range(light_positions.size()):
		var omni: OmniLight3D = OmniLight3D.new()
		omni.name = "ApexSodiumLight_%d" % i
		omni.position = light_positions[i]
		omni.light_color = Color(1.0, 0.68, 0.24)
		omni.light_energy = 2.85
		omni.omni_range = 24.0
		omni.omni_attenuation = 1.35
		omni.shadow_enabled = false
		omni.distance_fade_enabled = true
		omni.distance_fade_begin = omni_light_cull_distance * 0.75
		omni.distance_fade_length = omni_light_cull_distance * 0.25
		lights_container.add_child(omni)


# ==============================================================================
# MULTIMESH BATCHING & LOW-LEVEL SURFACETOOL GEOMETRY HELPERS
# ==============================================================================

func _create_multimesh_batch(
	batch_name: String,
	mesh_resource: Mesh,
	transforms: Array[Transform3D],
	shadow_mode: GeometryInstance3D.ShadowCastingSetting,
	cull_distance: float
) -> MultiMeshInstance3D:
	if transforms.is_empty() or mesh_resource == null:
		return null
		
	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = false
	mm.mesh = mesh_resource
	mm.instance_count = transforms.size()
	
	for i: int in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
		
	var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	mmi.name = batch_name
	mmi.multimesh = mm
	mmi.cast_shadow = shadow_mode
	mmi.visibility_range_end = cull_distance
	mmi.visibility_range_end_margin = cull_distance * 0.08
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	_scenery_root.add_child(mmi)
	return mmi


func _clear_existing_scenery() -> void:
	if _scenery_root != null and is_instance_valid(_scenery_root):
		_scenery_root.queue_free()
		_scenery_root = null
	for child: Node in get_children():
		if child.name == "AkinaProceduralScenery":
			child.queue_free()


func _st_add_quad(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3) -> void:
	var n: Vector3 = (v1 - v0).cross(v3 - v0).normalized()
	if n.length_squared() < 0.0001:
		n = Vector3.UP
	st.set_normal(n)
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(v0)
	st.set_normal(n)
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(v1)
	st.set_normal(n)
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(v2)
	
	st.set_normal(n)
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(v0)
	st.set_normal(n)
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(v2)
	st.set_normal(n)
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(v3)


func _st_add_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5
	
	var p000: Vector3 = center + Vector3(-hx, -hy, -hz)
	var p100: Vector3 = center + Vector3(hx, -hy, -hz)
	var p110: Vector3 = center + Vector3(hx, hy, -hz)
	var p010: Vector3 = center + Vector3(-hx, hy, -hz)
	var p001: Vector3 = center + Vector3(-hx, -hy, hz)
	var p101: Vector3 = center + Vector3(hx, -hy, hz)
	var p111: Vector3 = center + Vector3(hx, hy, hz)
	var p011: Vector3 = center + Vector3(-hx, hy, hz)
	
	# Front (+Z), Back (-Z), Right (+X), Left (-X), Top (+Y), Bottom (-Y)
	_st_add_quad(st, p001, p101, p111, p011)
	_st_add_quad(st, p100, p000, p010, p110)
	_st_add_quad(st, p101, p100, p110, p111)
	_st_add_quad(st, p000, p001, p011, p010)
	_st_add_quad(st, p011, p111, p110, p010)
	_st_add_quad(st, p000, p100, p101, p001)


func _st_add_tapered_cylinder(
	st: SurfaceTool,
	center: Vector3,
	bottom_radius: float,
	top_radius: float,
	height: float,
	radial_segments: int
) -> void:
	var half_h: float = height * 0.5
	var y_bot: float = center.y - half_h
	var y_top: float = center.y + half_h
	var segs: int = maxi(3, radial_segments)
	
	for i: int in range(segs):
		var a0: float = (float(i) / float(segs)) * TAU
		var a1: float = (float(i + 1) / float(segs)) * TAU
		
		var c0: float = cos(a0)
		var s0: float = sin(a0)
		var c1: float = cos(a1)
		var s1: float = sin(a1)
		
		var b0: Vector3 = Vector3(center.x + c0 * bottom_radius, y_bot, center.z + s0 * bottom_radius)
		var b1: Vector3 = Vector3(center.x + c1 * bottom_radius, y_bot, center.z + s1 * bottom_radius)
		var t1: Vector3 = Vector3(center.x + c1 * top_radius, y_top, center.z + s1 * top_radius)
		var t0: Vector3 = Vector3(center.x + c0 * top_radius, y_top, center.z + s0 * top_radius)
		
		_st_add_quad(st, b0, b1, t1, t0)
		
		# Top cap
		if top_radius > 0.005:
			var top_center: Vector3 = Vector3(center.x, y_top, center.z)
			st.set_normal(Vector3.UP)
			st.add_vertex(top_center)
			st.set_normal(Vector3.UP)
			st.add_vertex(t1)
			st.set_normal(Vector3.UP)
			st.add_vertex(t0)


func _st_add_lowpoly_sphere(
	st: SurfaceTool,
	center: Vector3,
	radius: float,
	radial_segments: int,
	rings: int
) -> void:
	var r_segs: int = maxi(4, radial_segments)
	var v_rings: int = maxi(3, rings)
	
	for r: int in range(v_rings):
		var phi0: float = PI * (float(r) / float(v_rings) - 0.5)
		var phi1: float = PI * (float(r + 1) / float(v_rings) - 0.5)
		
		var y0: float = sin(phi0) * radius
		var rc0: float = cos(phi0) * radius
		var y1: float = sin(phi1) * radius
		var rc1: float = cos(phi1) * radius
		
		for s: int in range(r_segs):
			var theta0: float = (float(s) / float(r_segs)) * TAU
			var theta1: float = (float(s + 1) / float(r_segs)) * TAU
			
			var v00: Vector3 = center + Vector3(cos(theta0) * rc0, y0, sin(theta0) * rc0)
			var v10: Vector3 = center + Vector3(cos(theta1) * rc0, y0, sin(theta1) * rc0)
			var v11: Vector3 = center + Vector3(cos(theta1) * rc1, y1, sin(theta1) * rc1)
			var v01: Vector3 = center + Vector3(cos(theta0) * rc1, y1, sin(theta0) * rc1)
			
			_st_add_quad(st, v00, v10, v11, v01)