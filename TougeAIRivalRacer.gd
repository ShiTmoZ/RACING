# ==============================================================================
# File: res://TougeAIRivalRacer.gd
# Engine: Godot Engine 4.3 (Headless / Desktop CI Compatible)
# Architecture: Autonomous Touge Cat & Mouse AI Rival (RigidBody3D)
# ==============================================================================
class_name TougeAIRivalRacer
extends RigidBody3D

# ------------------------------------------------------------------------------
# SIGNALS
# ------------------------------------------------------------------------------
signal sudden_death_finished(winner_is_player: bool, reason: String, final_gap_m: float)
signal overtake_occurred(rival_is_now_leading: bool, spline_offset_m: float)
signal pressure_warning_triggered(gap_meters: float, is_corner_attack: bool)
signal drift_state_changed(is_drifting: bool, slip_angle_deg: float)

# ------------------------------------------------------------------------------
# ENUMS
# ------------------------------------------------------------------------------
enum BattleMode {
	LEAD_CHASE,        ## Rival starts in front, defends line, pulls away (>50m = Rival Win)
	PURSUIT_CHASER,    ## Rival starts behind, flashes beams, dives inside (<3m = Pressure Alert)
	TIME_ATTACK_GHOST  ## Non-colliding translucent pace ghost running optimal apex line
}

enum RivalPreset {
	RX7_FD3S_YELLOW,   ## Competition Yellow Mazda RX-7 Type R (FD3S) - Keisuke Takahashi style
	SKYLINE_R32_GREY,  ## Gunmetal Grey Nissan Skyline GT-R (BNR32) - Takeshi Nakazato style
	TRUENO_AE86_PANDA  ## High-Tech Two-Tone Panda Sprinter Trueno GT-Apex - Fujiwara style
}

enum AIState {
	FULL_THROTTLE,
	TRAIL_BRAKING,
	APEX_CORNERING,
	INERTIA_DRIFT,
	DEFENDING_LINE,
	OVERTAKE_DIVE,
	BATTLE_FINISHED
}

# ------------------------------------------------------------------------------
# EXPORTED CONFIGURATION
# ------------------------------------------------------------------------------
@export_group("Touge Battle Configuration")
@export var battle_mode: BattleMode = BattleMode.LEAD_CHASE:
	set(value):
		battle_mode = value
		if is_inside_tree():
			_apply_battle_mode_settings()

@export var rival_preset: RivalPreset = RivalPreset.RX7_FD3S_YELLOW:
	set(value):
		rival_preset = value
		if is_inside_tree():
			_apply_rival_preset()

@export var battle_active: bool = false
@export var rival_driver_title: String = "REDSUNS KEISUKE // MAZDA RX-7 FD3S"
@export var player_node_path: NodePath
@export var track_path_node: NodePath
@export var sudden_death_gap_limit_m: float = 50.0
@export var pressure_warning_gap_m: float = 3.0
@export var sudden_death_grace_time_s: float = 5.0
@export var loop_track_spline: bool = false
@export var enable_battle_hud: bool = true

@export_group("AI Driving & Physics")
@export var ai_skill_multiplier: float = 1.05       ## 1.0 = Realistic limit, >1.0 = Heroic Touge Plot Armor
@export var tire_friction_mu: float = 1.38          ## Effective tarmac grip coefficient (semi-slicks)
@export var max_engine_force_n: float = 9800.0      ## Peak propulsion force in Newtons
@export var max_brake_force_n: float = 14200.0      ## Peak 4-wheel braking force in Newtons
@export var max_speed_mps: float = 54.0             ## ~194 km/h top gear limit on downhill
@export var max_steer_angle_rad: float = 0.62       ## ~35.5 degrees max front wheel lock
@export var road_half_width_m: float = 4.2          ## Usable half-width of mountain pass
@export var use_virtual_road_if_no_collider: bool = true

@export_group("PID & Drift Dynamics")
@export var steer_kp: float = 2.85
@export var steer_ki: float = 0.08
@export var steer_kd: float = 0.42
@export var drift_slip_threshold_rad: float = 0.14  ## ~8 degrees slip triggers active countersteer
@export var countersteer_gain: float = 1.25         ## Multiplier on slip angle during inertia drift
@export var hairpin_radius_threshold_m: float = 28.0

# ------------------------------------------------------------------------------
# CONSTANTS
# ------------------------------------------------------------------------------
const GRAVITY_ACCEL: float = 9.81
const WHEEL_COUNT: int = 4
const WHEEL_RADIUS: float = 0.33
const SUSPENSION_REST_DIST: float = 0.38
const SUSPENSION_MAX_DIST: float = 0.58
const SUSPENSION_SPRING_STIFFNESS: float = 42000.0
const SUSPENSION_DAMPER_STRENGTH: float = 4800.0
const CHASSIS_COLLISION_SIZE: Vector3 = Vector3(1.74, 0.92, 4.28)
const MIN_SPEED_FOR_DELTA_TIME: float = 4.5

# Wheel indices
const FL: int = 0
const FR: int = 1
const RL: int = 2
const RR: int = 3

# ------------------------------------------------------------------------------
# RUNTIME REFERENCES & STATE (PRE-ALLOCATED FOR ZERO GC ALLOCATIONS)
# ------------------------------------------------------------------------------
var _player_node: Node3D = null
var _track_curve: Curve3D = null
var _track_transform: Transform3D = Transform3D.IDENTITY
var _track_transform_inv: Transform3D = Transform3D.IDENTITY
var _track_total_length: float = 1.0

# Telemetry & AI outputs
var current_ai_state: AIState = AIState.FULL_THROTTLE
var throttle_input: float = 0.0
var brake_input: float = 0.0
var steer_input: float = 0.0
var handbrake_input: float = 0.0

var current_speed_mps: float = 0.0
var current_speed_kmh: float = 0.0
var current_slip_angle_rad: float = 0.0
var is_drifting: bool = false
var upcoming_corner_radius_m: float = 999.0
var target_corner_speed_mps: float = 54.0
var current_lookahead_m: float = 12.0
var target_lateral_offset_m: float = 0.0
var current_lateral_offset_m: float = 0.0

# Cat & Mouse Gap Tracking
var rival_spline_offset_m: float = 0.0
var player_spline_offset_m: float = 0.0
var gap_spline_meters: float = 0.0     ## Positive = Rival is ahead of Player, Negative = Rival is behind
var gap_direct_3d_meters: float = 0.0
var gap_time_seconds: float = 0.0
var rival_is_leading: bool = true
var battle_elapsed_time_s: float = 0.0
var battle_concluded: bool = false
var is_corner_attack_active: bool = false
var is_flashing_headlights: bool = false

# PID controller internal state
var _pid_integral: float = 0.0
var _pid_prev_error: float = 0.0

# Pre-allocated wheel physics arrays (Fixed size = 4)
var _wheel_local_offsets: PackedVector3Array = PackedVector3Array()
var _wheel_is_grounded: PackedByteArray = PackedByteArray()
var _wheel_compression: PackedFloat32Array = PackedFloat32Array()
var _wheel_prev_compression: PackedFloat32Array = PackedFloat32Array()
var _wheel_spin_angles: PackedFloat32Array = PackedFloat32Array()
var _wheel_contact_points: PackedVector3Array = PackedVector3Array()
var _wheel_contact_normals: PackedVector3Array = PackedVector3Array()

# Pre-allocated physics query object
var _ray_query: PhysicsRayQueryParameters3D = null
var _ray_exclude_rids: Array[RID] = []

# Visual Scene Nodes
var _visual_root: Node3D = null
var _chassis_mesh_root: Node3D = null
var _wheel_pivots: Array[Node3D] = []
var _wheel_spin_nodes: Array[Node3D] = []
var _headlight_left: SpotLight3D = null
var _headlight_right: SpotLight3D = null
var _exhaust_flash_light: OmniLight3D = null
var _collision_shape: CollisionShape3D = null

# Materials (stored for zero-alloc state updates)
var _body_paint_mat: StandardMaterial3D = null
var _cabin_glass_mat: StandardMaterial3D = null
var _carbon_aero_mat: StandardMaterial3D = null
var _headlight_emissive_mat: StandardMaterial3D = null
var _taillight_emissive_mat: StandardMaterial3D = null
var _wheel_alloy_mat: StandardMaterial3D = null
var _tire_rubber_mat: StandardMaterial3D = null

# Headlight & Backfire Timers
var _flash_timer_s: float = 0.0
var _backfire_timer_s: float = 0.0
var _hud_refresh_accum_s: float = 0.0
var _warning_blink_accum_s: float = 0.0

# HUD Nodes
var _hud_layer: CanvasLayer = null
var _hud_root_panel: PanelContainer = null
var _hud_header_label: Label = null
var _hud_rival_label: Label = null
var _hud_gap_label: Label = null
var _hud_telemetry_label: Label = null
var _hud_warning_panel: PanelContainer = null
var _hud_warning_label: Label = null
var _hud_banner_panel: PanelContainer = null
var _hud_banner_title: Label = null
var _hud_banner_subtitle: Label = null
var _hud_radar_rival_marker: ColorRect = null
var _hud_radar_player_marker: ColorRect = null
var _hud_radar_bar_bg: Control = null

# Pre-allocated colors for HUD
const COLOR_GAP_NEUTRAL: Color = Color(1.0, 0.88, 0.22, 1.0)
const COLOR_GAP_SAFE: Color = Color(0.25, 0.95, 0.45, 1.0)
const COLOR_GAP_DANGER: Color = Color(1.0, 0.24, 0.24, 1.0)
const COLOR_WARNING_BG_A: Color = Color(0.85, 0.10, 0.10, 0.92)
const COLOR_WARNING_BG_B: Color = Color(0.20, 0.02, 0.02, 0.92)

# ==============================================================================
# LIFECYCLE INITIALIZATION
# ==============================================================================
func _init() -> void:
	# Pre-allocate fixed-size wheel arrays
	_wheel_local_offsets.resize(WHEEL_COUNT)
	_wheel_local_offsets[FL] = Vector3(-0.78, 0.0, -1.32)
	_wheel_local_offsets[FR] = Vector3(0.78, 0.0, -1.32)
	_wheel_local_offsets[RL] = Vector3(-0.78, 0.0, 1.32)
	_wheel_local_offsets[RR] = Vector3(0.78, 0.0, 1.32)

	_wheel_is_grounded.resize(WHEEL_COUNT)
	_wheel_compression.resize(WHEEL_COUNT)
	_wheel_prev_compression.resize(WHEEL_COUNT)
	_wheel_spin_angles.resize(WHEEL_COUNT)
	_wheel_contact_points.resize(WHEEL_COUNT)
	_wheel_contact_normals.resize(WHEEL_COUNT)

	for i: int in range(WHEEL_COUNT):
		_wheel_is_grounded[i] = 0
		_wheel_compression[i] = 0.0
		_wheel_prev_compression[i] = 0.0
		_wheel_spin_angles[i] = 0.0
		_wheel_contact_points[i] = Vector3.ZERO
		_wheel_contact_normals[i] = Vector3.UP


func _ready() -> void:
	_configure_rigidbody_properties()
	_init_shared_materials()
	_build_collision_geometry()
	_build_procedural_jdm_car()
	_apply_rival_preset()
	_apply_battle_mode_settings()

	if enable_battle_hud:
		_build_battle_hud()

	_ray_query = PhysicsRayQueryParameters3D.new()
	_ray_exclude_rids.clear()
	_ray_exclude_rids.append(get_rid())
	_ray_query.exclude = _ray_exclude_rids
	_ray_query.collide_with_areas = false
	_ray_query.collide_with_bodies = true

	_discover_track_and_player()


func _configure_rigidbody_properties() -> void:
	mass = 1260.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, -0.26, 0.04)
	gravity_scale = 1.0
	linear_damp = 0.05
	angular_damp = 2.4
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 4
	can_sleep = false

	var phys_mat: PhysicsMaterial = PhysicsMaterial.new()
	phys_mat.friction = 0.12
	phys_mat.bounce = 0.08
	physics_material_override = phys_mat


# ==============================================================================
# PUBLIC API FOR TRACK REGISTRY & RACE CONTROLLERS
# ==============================================================================
func setup_rival_battle(
	p_track_curve: Curve3D,
	p_player: Node3D,
	p_mode: BattleMode = BattleMode.LEAD_CHASE,
	p_preset: RivalPreset = RivalPreset.RX7_FD3S_YELLOW,
	p_start_offset_m: float = 25.0
) -> void:
	set_track_curve(p_track_curve, Transform3D.IDENTITY)
	set_player_target(p_player)
	battle_mode = p_mode
	rival_preset = p_preset
	reset_to_track_offset(p_start_offset_m)


func set_track_curve(p_curve: Curve3D, p_track_global_transform: Transform3D = Transform3D.IDENTITY) -> void:
	_track_curve = p_curve
	_track_transform = p_track_global_transform
	_track_transform_inv = _track_transform.affine_inverse()
	if _track_curve != null and _track_curve.point_count >= 2:
		_track_total_length = maxf(_track_curve.get_baked_length(), 1.0)
	else:
		_track_total_length = 1.0


func set_player_target(p_player: Node3D) -> void:
	_player_node = p_player


func reset_to_track_offset(spline_offset_m: float, lateral_offset_m: float = 0.0) -> void:
	if _track_curve == null or _track_curve.point_count < 2:
		_build_fallback_touge_curve()

	var clamped_offset: float = clampf(spline_offset_m, 0.0, _track_total_length - 1.0)
	var local_pos: Vector3 = _track_curve.sample_baked(clamped_offset, true)
	var local_ahead: Vector3 = _track_curve.sample_baked(minf(clamped_offset + 4.0, _track_total_length), true)

	var world_pos: Vector3 = _track_transform * local_pos
	var world_ahead: Vector3 = _track_transform * local_ahead
	var forward_dir: Vector3 = (world_ahead - world_pos).normalized()
	if forward_dir.length_squared() < 0.001:
		forward_dir = Vector3.FORWARD

	var right_dir: Vector3 = forward_dir.cross(Vector3.UP).normalized()
	var spawn_pos: Vector3 = world_pos + (right_dir * lateral_offset_m) + Vector3(0.0, 0.65, 0.0)

	var target_basis: Basis = Basis.looking_at(forward_dir, Vector3.UP)
	global_transform = Transform3D(target_basis, spawn_pos)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

	_pid_integral = 0.0
	_pid_prev_error = 0.0
	battle_elapsed_time_s = 0.0
	battle_concluded = false
	rival_spline_offset_m = clamped_offset

	if _hud_banner_panel != null:
		_hud_banner_panel.visible = false


func get_battle_telemetry() -> Dictionary:
	return {
		"rival_name": rival_driver_title,
		"battle_mode": battle_mode,
		"ai_state": current_ai_state,
		"speed_kmh": current_speed_kmh,
		"slip_angle_deg": rad_to_deg(current_slip_angle_rad),
		"is_drifting": is_drifting,
		"gap_meters": gap_spline_meters,
		"gap_seconds": gap_time_seconds,
		"rival_is_leading": rival_is_leading,
		"corner_attack": is_corner_attack_active,
		"battle_concluded": battle_concluded
	}


# ==============================================================================
# AUTO-DISCOVERY & FALLBACK TOUGE SPLINE GENERATOR
# ==============================================================================
func _discover_track_and_player() -> void:
	# 1. Resolve Player Node
	if not player_node_path.is_empty():
		_player_node = get_node_or_null(player_node_path) as Node3D

	if _player_node == null and is_inside_tree():
		var players: Array[Node] = get_tree().get_nodes_in_group("player")
		if not players.is_empty() and players[0] is Node3D:
			_player_node = players[0] as Node3D
		else:
			# Search sibling nodes for common player vehicle names
			var parent_node: Node = get_parent()
			if parent_node != null:
				for child: Node in parent_node.get_children():
					if child != self and child is Node3D:
						var cname: String = child.name.to_lower()
						if cname.contains("player") or cname.contains("ae86") or cname.contains("car"):
							_player_node = child as Node3D
							break

	# 2. Resolve Track Curve3D
	if not track_path_node.is_empty():
		var path_candidate: Node = get_node_or_null(track_path_node)
		_extract_curve_from_node(path_candidate)

	if _track_curve == null and is_inside_tree():
		var tracks: Array[Node] = get_tree().get_nodes_in_group("touge_track")
		if not tracks.is_empty():
			_extract_curve_from_node(tracks[0])
		else:
			var parent_node: Node = get_parent()
			if parent_node != null:
				_extract_curve_from_node(parent_node)
				if _track_curve == null:
					for child: Node in parent_node.get_children():
						_extract_curve_from_node(child)
						if _track_curve != null:
							break

	# 3. Fallback procedural mountain pass curve for headless/standalone testing
	if _track_curve == null or _track_curve.point_count < 2:
		_build_fallback_touge_curve()


func _extract_curve_from_node(node: Node) -> void:
	if node == null:
		return
	if node is Path3D:
		var path3d: Path3D = node as Path3D
		if path3d.curve != null and path3d.curve.point_count >= 2:
			set_track_curve(path3d.curve, path3d.global_transform)
			return
	if node.has_method("get_active_track_curve"):
		var custom_curve: Variant = node.call("get_active_track_curve")
		if custom_curve is Curve3D:
			var t_xform: Transform3D = (node as Node3D).global_transform if node is Node3D else Transform3D.IDENTITY
			set_track_curve(custom_curve as Curve3D, t_xform)
			return
	if "track_curve" in node:
		var prop_curve: Variant = node.get("track_curve")
		if prop_curve is Curve3D:
			var t_xform: Transform3D = (node as Node3D).global_transform if node is Node3D else Transform3D.IDENTITY
			set_track_curve(prop_curve as Curve3D, t_xform)


func _build_fallback_touge_curve() -> void:
	var fallback: Curve3D = Curve3D.new()
	fallback.bake_interval = 2.0

	# Generates a technical 1.4km downhill touge section with 5 consecutive hairpins (Akina style)
	var waypoints: PackedVector3Array = PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.0, -3.5, -110.0),
		Vector3(48.0, -8.0, -175.0),
		Vector3(95.0, -12.5, -120.0),
		Vector3(115.0, -17.0, -210.0),
		Vector3(35.0, -22.5, -285.0),
		Vector3(-45.0, -27.0, -240.0),
		Vector3(-85.0, -32.0, -330.0),
		Vector3(10.0, -38.0, -420.0),
		Vector3(85.0, -44.0, -490.0),
		Vector3(25.0, -50.0, -590.0),
		Vector3(-60.0, -56.0, -680.0)
	])

	for i: int in range(waypoints.size()):
		var pt: Vector3 = waypoints[i]
		var in_vec: Vector3 = Vector3.ZERO
		var out_vec: Vector3 = Vector3.ZERO
		if i > 0 and i < waypoints.size() - 1:
			var tangent: Vector3 = (waypoints[i + 1] - waypoints[i - 1]) * 0.28
			in_vec = -tangent
			out_vec = tangent
		fallback.add_point(pt, in_vec, out_vec)

	set_track_curve(fallback, Transform3D.IDENTITY)


# ==============================================================================
# MAIN PHYSICS & AUTONOMOUS DRIVING LOOP (ZERO ALLOCATION)
# ==============================================================================
func _physics_process(delta: float) -> void:
	if delta <= 0.00001:
		return

	battle_elapsed_time_s += delta

	# 1. Measure current vehicle kinematics
	var current_basis: Basis = global_transform.basis
	var forward_vec: Vector3 = -current_basis.z
	var right_vec: Vector3 = current_basis.x
	var up_vec: Vector3 = current_basis.y

	var vel: Vector3 = linear_velocity
	var forward_speed: float = vel.dot(forward_vec)
	var lateral_speed: float = vel.dot(right_vec)
	current_speed_mps = vel.length()
	current_speed_kmh = current_speed_mps * 3.6

	if absf(forward_speed) > 1.25:
		current_slip_angle_rad = atan2(lateral_speed, absf(forward_speed))
	else:
		current_slip_angle_rad = 0.0

	var prev_drifting: bool = is_drifting
	is_drifting = (current_speed_mps > 9.0) and (absf(current_slip_angle_rad) > drift_slip_threshold_rad)
	if is_drifting != prev_drifting:
		drift_state_changed.emit(is_drifting, rad_to_deg(current_slip_angle_rad))

	# 2. Update Spline Position & Player Gap Tracker
	_update_spline_and_battle_gap(delta)

	# 3. Compute Autonomous Racing Line, Braking, and Steering
	if not battle_concluded:
		_compute_autonomous_driving_controls(delta, forward_vec, right_vec, forward_speed)
	else:
		# Smooth cooldown deceleration after Sudden Death / Finish
		throttle_input = 0.0
		brake_input = 0.65
		steer_input = move_toward(steer_input, 0.0, delta * 2.0)

	# 4. Execute 4-Wheel Raycast Suspension & Tire Forces
	_step_suspension_and_tire_physics(delta, forward_vec, right_vec, up_vec, forward_speed, lateral_speed)

	# 5. Update Visuals (Wheels, Lights, Exhaust Backfire, HUD)
	_update_visual_effects(delta, forward_speed)
	if enable_battle_hud and _hud_layer != null:
		_update_battle_hud(delta)


# ==============================================================================
# GAP TRACKER & CAT-AND-MOUSE SUDDEN DEATH LOGIC
# ==============================================================================
func _update_spline_and_battle_gap(_delta: float) -> void:
	if _track_curve == null or _track_curve.point_count < 2:
		return

	var local_car_pos: Vector3 = _track_transform_inv * global_position
	rival_spline_offset_m = _track_curve.get_closest_offset(local_car_pos)

	# Check if track loops or finishes
	if not loop_track_spline and not battle_concluded:
		if rival_spline_offset_m >= _track_total_length - 4.0 and battle_elapsed_time_s > 2.0:
			_conclude_battle(not rival_is_leading, "FINISH LINE CROSSED")
			return
	elif loop_track_spline and rival_spline_offset_m >= _track_total_length - 1.5:
		reset_to_track_offset(1.0, current_lateral_offset_m)

	if _player_node != null and is_instance_valid(_player_node):
		var player_world_pos: Vector3 = _player_node.global_position
		gap_direct_3d_meters = global_position.distance_to(player_world_pos)

		var local_player_pos: Vector3 = _track_transform_inv * player_world_pos
		player_spline_offset_m = _track_curve.get_closest_offset(local_player_pos)

		var new_gap_m: float = rival_spline_offset_m - player_spline_offset_m
		if loop_track_spline:
			var half_len: float = _track_total_length * 0.5
			if new_gap_m > half_len:
				new_gap_m -= _track_total_length
			elif new_gap_m < -half_len:
				new_gap_m += _track_total_length

		var prev_leading: bool = rival_is_leading
		rival_is_leading = new_gap_m >= 0.0
		if battle_elapsed_time_s > 1.0 and rival_is_leading != prev_leading:
			overtake_occurred.emit(rival_is_leading, rival_spline_offset_m)

		gap_spline_meters = new_gap_m
		var ref_speed: float = maxf(current_speed_mps, MIN_SPEED_FOR_DELTA_TIME)
		gap_time_seconds = gap_spline_meters / ref_speed
	else:
		# Standalone / Headless mode without player node: simulate virtual pace reference
		player_spline_offset_m = maxf(0.0, rival_spline_offset_m - (12.0 if battle_mode == BattleMode.LEAD_CHASE else -8.0))
		gap_spline_meters = rival_spline_offset_m - player_spline_offset_m
		gap_direct_3d_meters = absf(gap_spline_meters)
		gap_time_seconds = gap_spline_meters / maxf(current_speed_mps, MIN_SPEED_FOR_DELTA_TIME)
		rival_is_leading = gap_spline_meters >= 0.0

	# Evaluate Cat & Mouse Battle Rules
	if not battle_active or battle_mode == BattleMode.TIME_ATTACK_GHOST or battle_concluded:
		is_corner_attack_active = false
		is_flashing_headlights = false
		return

	var abs_gap: float = absf(gap_spline_meters)

	# 1. Sudden Death Gap Check (After initial launch grace period)
	if battle_elapsed_time_s >= sudden_death_grace_time_s:
		if battle_mode == BattleMode.LEAD_CHASE:
			if gap_spline_meters > sudden_death_gap_limit_m:
				_conclude_battle(false, "RIVAL PULLED AWAY (>%.0fm GAP)" % sudden_death_gap_limit_m)
				return
			elif gap_spline_meters < -15.0:
				_conclude_battle(true, "OVERTAKE COMPLETE - RIVAL DEFEATED")
				return
		elif battle_mode == BattleMode.PURSUIT_CHASER:
			if gap_spline_meters < -sudden_death_gap_limit_m:
				_conclude_battle(true, "OUTRAN PURSUIT RIVAL (>%.0fm GAP)" % sudden_death_gap_limit_m)
				return
			elif gap_spline_meters > 15.0:
				_conclude_battle(false, "RIVAL OVERTOOK & PULLED AWAY")
				return

	# 2. Chaser Pressure & Headlight Strobe Logic
	if battle_mode == BattleMode.PURSUIT_CHASER or not rival_is_leading:
		var in_corner_zone: bool = upcoming_corner_radius_m < 65.0
		var close_proximity: bool = abs_gap <= pressure_warning_gap_m or gap_direct_3d_meters <= (pressure_warning_gap_m + 2.2)
		is_corner_attack_active = close_proximity and in_corner_zone
		is_flashing_headlights = (abs_gap < 18.0) and not rival_is_leading

		if is_corner_attack_active:
			pressure_warning_triggered.emit(abs_gap, true)
	else:
		is_corner_attack_active = false
		is_flashing_headlights = false


func _conclude_battle(player_won: bool, reason_text: String) -> void:
	if battle_concluded:
		return
	battle_concluded = true
	current_ai_state = AIState.BATTLE_FINISHED
	sudden_death_finished.emit(player_won, reason_text, gap_spline_meters)

	if _hud_banner_panel != null:
		_hud_banner_panel.visible = true
		if player_won:
			_hud_banner_title.text = "SUDDEN DEATH VICTORY"
			_hud_banner_title.modulate = COLOR_GAP_SAFE
		else:
			_hud_banner_title.text = "SUDDEN DEATH DEFEAT"
			_hud_banner_title.modulate = COLOR_GAP_DANGER
		_hud_banner_subtitle.text = "%s  |  FINAL GAP: %+.1f m (%+.2fs)" % [
			reason_text,
			gap_spline_meters,
			gap_time_seconds
		]
		_hud_banner_panel.modulate.a = 1.0
		var tw := create_tween()
		if tw != null:
			tw.tween_interval(3.5)
			tw.tween_property(_hud_banner_panel, "modulate:a", 0.0, 0.8)
			tw.tween_callback(func(): if is_instance_valid(_hud_banner_panel): _hud_banner_panel.visible = false)


# ==============================================================================
# AUTONOMOUS RACING LINE, CURVATURE BRAKING & COUNTERSTEER AI
# ==============================================================================
func _compute_autonomous_driving_controls(
	delta: float,
	forward_vec: Vector3,
	right_vec: Vector3,
	forward_speed: float
) -> void:
	# 1. Dynamic Speed-Scaled Lookahead: clampf(speed * 0.45, 8.0, 32.0)
	current_lookahead_m = clampf(current_speed_mps * 0.45, 8.0, 32.0)

	# 2. Sample Track Curvature at 3 Forward Windows for Dynamic Corner Braking
	var r_near: float = _estimate_curve_radius_at_offset(rival_spline_offset_m + 10.0, 6.0)
	var r_mid: float = _estimate_curve_radius_at_offset(rival_spline_offset_m + 24.0, 9.0)
	var r_far: float = _estimate_curve_radius_at_offset(rival_spline_offset_m + 44.0, 12.0)

	upcoming_corner_radius_m = minf(r_near, minf(r_mid, r_far))

	# Compute corner speed limit: v = sqrt(mu * g * R) * skill_multiplier
	var effective_mu: float = tire_friction_mu * ai_skill_multiplier
	var v_near: float = minf(max_speed_mps, sqrt(effective_mu * GRAVITY_ACCEL * r_near))
	var v_mid: float = minf(max_speed_mps, sqrt(effective_mu * GRAVITY_ACCEL * r_mid))
	var v_far: float = minf(max_speed_mps, sqrt(effective_mu * GRAVITY_ACCEL * r_far))

	# Account for braking distance required to decelerate to v_mid / v_far
	var max_decel_mps2: float = effective_mu * GRAVITY_ACCEL * 0.92
	var allowed_v_mid: float = sqrt(v_mid * v_mid + 2.0 * max_decel_mps2 * 20.0)
	var allowed_v_far: float = sqrt(v_far * v_far + 2.0 * max_decel_mps2 * 40.0)

	target_corner_speed_mps = minf(v_near, minf(allowed_v_mid, allowed_v_far))

	# 3. Compute Optimal Apex & Tactical Cat-and-Mouse Lateral Line Offset
	var corner_sign: float = _compute_upcoming_corner_direction(rival_spline_offset_m + current_lookahead_m)
	var curvature_intensity: float = clampf(45.0 / maxf(upcoming_corner_radius_m, 8.0), 0.0, 1.0)

	# Base racing line: swing slightly wide on entry, hug inside apex strongly through corner
	var apex_offset: float = corner_sign * (road_half_width_m * 0.68) * curvature_intensity
	var tactical_offset: float = apex_offset

	if battle_mode == BattleMode.LEAD_CHASE and _player_node != null and is_instance_valid(_player_node):
		# LEAD MODE: Defend inside line if player is within 16m behind
		if gap_spline_meters > 0.0 and gap_spline_meters < 16.0:
			var player_lat: float = _compute_world_point_lateral_offset(_player_node.global_position, rival_spline_offset_m)
			tactical_offset = lerpf(apex_offset, clampf(player_lat, -road_half_width_m * 0.75, road_half_width_m * 0.75), 0.65)
			current_ai_state = AIState.DEFENDING_LINE
	elif battle_mode == BattleMode.PURSUIT_CHASER and _player_node != null and is_instance_valid(_player_node):
		# CHASER MODE: Hunt inside overtake line when close to player
		if absf(gap_spline_meters) < 14.0:
			var player_lat: float = _compute_world_point_lateral_offset(_player_node.global_position, player_spline_offset_m)
			var inside_target: float = corner_sign * (road_half_width_m * 0.80)
			if absf(player_lat - inside_target) < 1.65:
				# Player is blocking the inside; switch-back to opposite side for exit cutback
				tactical_offset = -inside_target * 0.75
			else:
				tactical_offset = inside_target
			current_ai_state = AIState.OVERTAKE_DIVE

	target_lateral_offset_m = clampf(tactical_offset, -road_half_width_m * 0.82, road_half_width_m * 0.82)
	current_lateral_offset_m = _compute_world_point_lateral_offset(global_position, rival_spline_offset_m)

	# 4. Sample Lookahead Target Point on Curve3D
	var sample_offset: float = rival_spline_offset_m + current_lookahead_m
	if loop_track_spline and sample_offset > _track_total_length:
		sample_offset = fmod(sample_offset, _track_total_length)
	else:
		sample_offset = minf(sample_offset, _track_total_length)

	var local_target: Vector3 = _track_curve.sample_baked(sample_offset, true)
	var local_target_ahead: Vector3 = _track_curve.sample_baked(minf(sample_offset + 3.0, _track_total_length), true)
	var world_target_center: Vector3 = _track_transform * local_target
	var world_target_ahead: Vector3 = _track_transform * local_target_ahead

	var tangent_dir: Vector3 = (world_target_ahead - world_target_center).normalized()
	var track_right_dir: Vector3 = tangent_dir.cross(Vector3.UP).normalized()
	var final_target_world: Vector3 = world_target_center + (track_right_dir * target_lateral_offset_m)

	# 5. Pure Pursuit + PID Steering Angle Calculation
	var to_target: Vector3 = final_target_world - global_position
	var local_x: float = to_target.dot(right_vec)
	var local_z: float = to_target.dot(forward_vec)
	var desired_heading_error: float = atan2(local_x, maxf(local_z, 1.0))

	_pid_integral = clampf(_pid_integral + desired_heading_error * delta, -0.35, 0.35)
	var pid_derivative: float = (desired_heading_error - _pid_prev_error) / delta
	_pid_prev_error = desired_heading_error

	var raw_steer_angle: float = (
		(steer_kp * desired_heading_error) +
		(steer_ki * _pid_integral) +
		(steer_kd * pid_derivative)
	) * 0.42

	# 6. Countersteering & Inertia Drift Recovery (Keisuke / Takumi Hairpin Style)
	if is_drifting:
		var countersteer_angle: float = -current_slip_angle_rad * countersteer_gain
		raw_steer_angle = lerpf(raw_steer_angle, countersteer_angle, 0.58)
		current_ai_state = AIState.INERTIA_DRIFT

	var normalized_steer: float = clampf(raw_steer_angle / max_steer_angle_rad, -1.0, 1.0)
	steer_input = move_toward(steer_input, normalized_steer, delta * 6.5)

	# 7. Progressive Throttle, Trail Braking & Hairpin Rotation Control
	var speed_error: float = current_speed_mps - target_corner_speed_mps
	handbrake_input = 0.0

	if speed_error > 0.65:
		# Progressive braking proportional to speed excess
		brake_input = clampf(speed_error / 10.5, 0.12, 1.0)
		throttle_input = 0.0

		# Trigger rotary/turbo exhaust backfire on initial heavy braking transition
		if brake_input > 0.65 and _backfire_timer_s <= 0.0 and current_speed_mps > 20.0:
			_backfire_timer_s = 0.16

		# Initiate hairpin rotation slip if corner is tight
		if upcoming_corner_radius_m < hairpin_radius_threshold_m and absf(steer_input) > 0.45 and current_speed_mps > 13.0:
			handbrake_input = 0.35

		if current_ai_state != AIState.DEFENDING_LINE and current_ai_state != AIState.OVERTAKE_DIVE:
			current_ai_state = AIState.TRAIL_BRAKING
	else:
		brake_input = 0.0
		var throttle_mod: float = 1.0 - (absf(steer_input) * 0.22)
		if is_drifting:
			# Modulate throttle during drift to sustain angle without spinning out
			throttle_mod = clampf(0.88 - absf(current_slip_angle_rad) * 0.45, 0.35, 0.95)
		elif upcoming_corner_radius_m < 45.0:
			if current_ai_state != AIState.DEFENDING_LINE and current_ai_state != AIState.OVERTAKE_DIVE and current_ai_state != AIState.INERTIA_DRIFT:
				current_ai_state = AIState.APEX_CORNERING
		else:
			if current_ai_state != AIState.DEFENDING_LINE and current_ai_state != AIState.OVERTAKE_DIVE:
				current_ai_state = AIState.FULL_THROTTLE

		# Reverse recovery if stuck
		if forward_speed < -1.0:
			brake_input = 0.0
			throttle_input = 1.0
		else:
			throttle_input = clampf(throttle_mod, 0.15, 1.0)


func _estimate_curve_radius_at_offset(center_offset_m: float,chord_half_m: float) -> float:
	if _track_curve == null or _track_curve.point_count < 2:
		return 999.0

	var o1: float = clampf(center_offset_m - chord_half_m, 0.0, _track_total_length)
	var o2: float = clampf(center_offset_m, 0.0, _track_total_length)
	var o3: float = clampf(center_offset_m + chord_half_m, 0.0, _track_total_length)

	if o3 - o1 < 2.0:
		return 999.0

	var p1: Vector3 = _track_transform * _track_curve.sample_baked(o1, true)
	var p2: Vector3 = _track_transform * _track_curve.sample_baked(o2, true)
	var p3: Vector3 = _track_transform * _track_curve.sample_baked(o3, true)

	# Flatten to XZ plane for horizontal turning radius calculation
	var v1: Vector2 = Vector2(p2.x - p1.x, p2.z - p1.z)
	var v2: Vector2 = Vector2(p3.x - p2.x, p3.z - p2.z)
	var v3: Vector2 = Vector2(p3.x - p1.x, p3.z - p1.z)

	var len1: float = v1.length()
	var len2: float = v2.length()
	var len3: float = v3.length()

	if len1 < 0.1 or len2 < 0.1 or len3 < 0.1:
		return 999.0

	# Twice the signed area of triangle (p1, p2, p3)
	var cross_area_2: float = absf(v1.x * v2.y - v1.y * v2.x)
	if cross_area_2 < 0.001:
		return 999.0

	# Circumcircle radius R = (a * b * c) / (4 * Area) = (len1 * len2 * len3) / (2 * cross_area_2)
	var radius: float = (len1 * len2 * len3) / (2.0 * cross_area_2)
	return clampf(radius, 8.0, 999.0)


func _compute_upcoming_corner_direction(offset_m: float) -> float:
	var o1: float = clampf(offset_m - 6.0, 0.0, _track_total_length)
	var o2: float = clampf(offset_m, 0.0, _track_total_length)
	var o3: float = clampf(offset_m + 6.0, 0.0, _track_total_length)

	var p1: Vector3 = _track_transform * _track_curve.sample_baked(o1, true)
	var p2: Vector3 = _track_transform * _track_curve.sample_baked(o2, true)
	var p3: Vector3 = _track_transform * _track_curve.sample_baked(o3, true)

	var dir1: Vector3 = (p2 - p1).normalized()
	var dir2: Vector3 = (p3 - p2).normalized()
	var cross_y: float = dir1.cross(dir2).y
	# In right-handed coordinates (-Z forward, +X right, +Y up):
	# cross_y < 0 means turning right (+1.0 right offset), cross_y > 0 means turning left (-1.0 left offset)
	if absf(cross_y) < 0.005:
		return 0.0
	return -1.0 if cross_y > 0.0 else 1.0


func _compute_world_point_lateral_offset(world_pt: Vector3, ref_offset_m: float) -> float:
	var c_off: float = clampf(ref_offset_m, 0.0, _track_total_length)
	var c_ahead: float = minf(c_off + 2.5, _track_total_length)
	var center_pt: Vector3 = _track_transform * _track_curve.sample_baked(c_off, true)
	var ahead_pt: Vector3 = _track_transform * _track_curve.sample_baked(c_ahead, true)
	var tangent: Vector3 = (ahead_pt - center_pt).normalized()
	var right_dir: Vector3 = tangent.cross(Vector3.UP).normalized()
	return (world_pt - center_pt).dot(right_dir)


# ==============================================================================
# 4-WHEEL RAYCAST SUSPENSION & PACEJKA-LITE TIRE PHYSICS
# ==============================================================================
func _step_suspension_and_tire_physics(
	delta: float,
	forward_vec: Vector3,
	right_vec: Vector3,
	up_vec: Vector3,
	forward_speed: float,
	_lateral_speed: float
) -> void:
	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var car_xform: Transform3D = global_transform
	var grounded_wheels: int = 0

	var front_wheel_steer_rad: float = -steer_input * max_steer_angle_rad
	var effective_grip: float = tire_friction_mu * ai_skill_multiplier
	var per_wheel_max_load: float = (mass * GRAVITY_ACCEL) * 0.45

	for i: int in range(WHEEL_COUNT):
		var local_mount: Vector3 = _wheel_local_offsets[i]
		var world_mount: Vector3 = car_xform * local_mount
		var ray_end: Vector3 = world_mount - (up_vec * (SUSPENSION_MAX_DIST + WHEEL_RADIUS))

		_ray_query.from = world_mount
		_ray_query.to = ray_end
		var hit: Dictionary = space_state.intersect_ray(_ray_query)

		var has_contact: bool = false
		var contact_point: Vector3 = Vector3.ZERO
		var contact_normal: Vector3 = Vector3.UP
		var hit_distance: float = SUSPENSION_MAX_DIST + WHEEL_RADIUS

		if not hit.is_empty():
			has_contact = true
			contact_point = hit["position"]
			contact_normal = hit["normal"]
			hit_distance = world_mount.distance_to(contact_point)
		elif use_virtual_road_if_no_collider and _track_curve != null:
			# Headless / CI fallback: project wheel onto the procedural Curve3D road ribbon
			var curve_pt: Vector3 = _track_transform * _track_curve.sample_baked(rival_spline_offset_m, true)
			var vertical_dist: float = world_mount.y - curve_pt.y
			if vertical_dist > 0.0 and vertical_dist <= (SUSPENSION_MAX_DIST + WHEEL_RADIUS + 0.25):
				has_contact = true
				hit_distance = clampf(vertical_dist, 0.15, SUSPENSION_MAX_DIST + WHEEL_RADIUS)
				contact_point = world_mount - Vector3(0.0, hit_distance, 0.0)
				contact_normal = Vector3.UP

		if has_contact:
			grounded_wheels += 1
			_wheel_is_grounded[i] = 1
			_wheel_contact_points[i] = contact_point
			_wheel_contact_normals[i] = contact_normal

			var suspension_len: float = clampf(hit_distance - WHEEL_RADIUS, 0.05, SUSPENSION_MAX_DIST)
			var compression: float = SUSPENSION_REST_DIST - suspension_len
			var compression_vel: float = (compression - _wheel_prev_compression[i]) / delta
			_wheel_prev_compression[i] = compression
			_wheel_compression[i] = compression

			# 1. Vertical Suspension Force (Spring + Damper)
			var spring_force: float = maxf(0.0, (compression * SUSPENSION_SPRING_STIFFNESS) + (compression_vel * SUSPENSION_DAMPER_STRENGTH))
			spring_force = minf(spring_force, mass * GRAVITY_ACCEL * 2.2)
			var susp_force_vec: Vector3 = contact_normal * spring_force
			var force_offset: Vector3 = world_mount - global_position
			apply_force(susp_force_vec, force_offset)

			# 2. Wheel Local Coordinate Frame (Steered for Front Wheels)
			var is_front: bool = (i == FL or i == FR)
			var wheel_forward: Vector3 = forward_vec
			var wheel_right: Vector3 = right_vec
			if is_front:
				wheel_forward = forward_vec.rotated(up_vec, front_wheel_steer_rad).normalized()
				wheel_right = right_vec.rotated(up_vec, front_wheel_steer_rad).normalized()

			# Velocity at wheel contact patch
			var point_vel: Vector3 = linear_velocity + angular_velocity.cross(force_offset)
			var wheel_long_vel: float = point_vel.dot(wheel_forward)
			var wheel_lat_vel: float = point_vel.dot(wheel_right)

			# 3. Longitudinal Force (Drive + Braking)
			var long_force: float = 0.0
			if current_speed_mps < max_speed_mps:
				# Rear-biased AWD/RWD propulsion distribution (30% front, 70% rear)
				var drive_share: float = 0.15 if is_front else 0.35
				long_force += throttle_input * max_engine_force_n * drive_share * ai_skill_multiplier

			if brake_input > 0.001:
				var brake_share: float = 0.30 if is_front else 0.20
				var brake_dir: float = -signf(wheel_long_vel) if absf(wheel_long_vel) > 0.2 else 0.0
				long_force += brake_dir * brake_input * max_brake_force_n * brake_share

			# 4. Lateral Cornering Force (Brush Tire Model with Drift Slip Falloff)
			var normal_load: float = clampf(spring_force, 1200.0, per_wheel_max_load)
			var lateral_stiffness: float = 0.52
			var rear_drift_factor: float = 1.0
			if not is_front:
				if handbrake_input > 0.05:
					rear_drift_factor = 0.48
				elif is_drifting:
					rear_drift_factor = 0.78

			var desired_lat_accel: float = -wheel_lat_vel * lateral_stiffness * 11.5
			var max_lat_grip: float = normal_load * effective_grip * rear_drift_factor
			var lat_force: float = clampf(desired_lat_accel * (mass * 0.25), -max_lat_grip, max_lat_grip)

			var total_tire_force: Vector3 = (wheel_forward * long_force) + (wheel_right * lat_force)
			# Apply tire forces slightly closer to COM height to prevent unrealistic roll-over on high-mu tarmac
			var stable_force_offset: Vector3 = Vector3(force_offset.x, center_of_mass.y * 0.5, force_offset.z)
			apply_force(total_tire_force, stable_force_offset)
		else:
			_wheel_is_grounded[i] = 0
			_wheel_prev_compression[i] = 0.0
			_wheel_compression[i] = -0.10

	# Aerodynamic Downforce & Drag
	if current_speed_mps > 5.0:
		var speed_sq: float = current_speed_mps * current_speed_mps
		var aero_drag: Vector3 = -forward_vec * (0.42 * speed_sq)
		var aero_downforce: Vector3 = -up_vec * (0.85 * speed_sq)
		apply_central_force(aero_drag + aero_downforce)

	# Anti-roll / Self-righting stabilization if airborne or clipped a guardrail
	if grounded_wheels == 0 and up_vec.y < 0.35:
		var align_axis: Vector3 = up_vec.cross(Vector3.UP)
		apply_torque(align_axis * mass * 18.0)


# ==============================================================================
# PROCEDURAL JDM RIVAL CAR GEOMETRY (RX-7 FD3S / R32 GT-R / AE86)
# ==============================================================================
func _init_shared_materials() -> void:
	_body_paint_mat = StandardMaterial3D.new()
	_body_paint_mat.metallic = 0.72
	_body_paint_mat.roughness = 0.22
	_body_paint_mat.clearcoat_enabled = true
	_body_paint_mat.clearcoat = 0.85

	_cabin_glass_mat = StandardMaterial3D.new()
	_cabin_glass_mat.albedo_color = Color(0.06, 0.08, 0.12, 1.0)
	_cabin_glass_mat.metallic = 0.90
	_cabin_glass_mat.roughness = 0.08

	_carbon_aero_mat = StandardMaterial3D.new()
	_carbon_aero_mat.albedo_color = Color(0.11, 0.11, 0.13, 1.0)
	_carbon_aero_mat.metallic = 0.35
	_carbon_aero_mat.roughness = 0.45

	_headlight_emissive_mat = StandardMaterial3D.new()
	_headlight_emissive_mat.albedo_color = Color(1.0, 0.98, 0.88, 1.0)
	_headlight_emissive_mat.emission_enabled = true
	_headlight_emissive_mat.emission = Color(1.0, 0.96, 0.82, 1.0)
	_headlight_emissive_mat.emission_energy_multiplier = 3.2

	_taillight_emissive_mat = StandardMaterial3D.new()
	_taillight_emissive_mat.albedo_color = Color(0.95, 0.08, 0.08, 1.0)
	_taillight_emissive_mat.emission_enabled = true
	_taillight_emissive_mat.emission = Color(1.0, 0.05, 0.02, 1.0)
	_taillight_emissive_mat.emission_energy_multiplier = 1.8

	_wheel_alloy_mat = StandardMaterial3D.new()
	_wheel_alloy_mat.albedo_color = Color(0.76, 0.64, 0.38, 1.0)
	_wheel_alloy_mat.metallic = 0.85
	_wheel_alloy_mat.roughness = 0.28

	_tire_rubber_mat = StandardMaterial3D.new()
	_tire_rubber_mat.albedo_color = Color(0.08, 0.08, 0.09, 1.0)
	_tire_rubber_mat.roughness = 0.88


func _build_collision_geometry() -> void:
	_collision_shape = CollisionShape3D.new()
	_collision_shape.name = "ChassisCollisionBox"
	var box: BoxShape3D = BoxShape3D.new()
	box.size = CHASSIS_COLLISION_SIZE
	_collision_shape.shape = box
	_collision_shape.position = Vector3(0.0, 0.24, 0.0)
	add_child(_collision_shape)


func _build_procedural_jdm_car() -> void:
	_visual_root = Node3D.new()
	_visual_root.name = "JDMVisualRoot"
	add_child(_visual_root)

	_chassis_mesh_root = Node3D.new()
	_chassis_mesh_root.name = "ChassisBody"
	_visual_root.add_child(_chassis_mesh_root)

	# 1. Lower Main Body Tub
	var lower_body: MeshInstance3D = MeshInstance3D.new()
	var lower_box: BoxMesh = BoxMesh.new()
	lower_box.size = Vector3(1.72, 0.46, 4.24)
	lower_body.mesh = lower_box
	lower_body.material_override = _body_paint_mat
	lower_body.position = Vector3(0.0, 0.08, 0.0)
	_chassis_mesh_root.add_child(lower_body)

	# 2. Aerodynamic Nose Cone / Hood Slope (-Z is Forward)
	var hood_slope: MeshInstance3D = MeshInstance3D.new()
	var hood_prism: PrismMesh = PrismMesh.new()
	hood_prism.left_to_right = 0.0
	hood_prism.size = Vector3(0.18, 1.35, 1.66)
	hood_slope.mesh = hood_prism
	hood_slope.material_override = _body_paint_mat
	hood_slope.rotation_degrees = Vector3(0.0, 90.0, 90.0)
	hood_slope.position = Vector3(0.0, 0.36, -1.35)
	_chassis_mesh_root.add_child(hood_slope)

	# 3. Sleek Cabin Greenhouse
	var cabin: MeshInstance3D = MeshInstance3D.new()
	var cabin_box: BoxMesh = BoxMesh.new()
	cabin_box.size = Vector3(1.42, 0.42, 1.78)
	cabin.mesh = cabin_box
	cabin.material_override = _cabin_glass_mat
	cabin.position = Vector3(0.0, 0.50, 0.18)
	_chassis_mesh_root.add_child(cabin)

	# Roof Cap
	var roof_cap: MeshInstance3D = MeshInstance3D.new()
	var roof_box: BoxMesh = BoxMesh.new()
	roof_box.size = Vector3(1.36, 0.06, 1.42)
	roof_cap.mesh = roof_box
	roof_cap.material_override = _body_paint_mat
	roof_cap.position = Vector3(0.0, 0.72, 0.20)
	_chassis_mesh_root.add_child(roof_cap)

	# 4. Carbon Front Splitter / Lip
	var splitter: MeshInstance3D = MeshInstance3D.new()
	var splitter_box: BoxMesh = BoxMesh.new()
	splitter_box.size = Vector3(1.78, 0.06, 0.36)
	splitter.mesh = splitter_box
	splitter.material_override = _carbon_aero_mat
	splitter.position = Vector3(0.0, -0.13, -2.02)
	_chassis_mesh_root.add_child(splitter)

	# Side Skirts
	for side_sign: float in [-1.0, 1.0]:
		var skirt: MeshInstance3D = MeshInstance3D.new()
		var skirt_box: BoxMesh = BoxMesh.new()
		skirt_box.size = Vector3(0.08, 0.10, 2.20)
		skirt.mesh = skirt_box
		skirt.material_override = _carbon_aero_mat
		skirt.position = Vector3(side_sign * 0.85, -0.11, 0.0)
		_chassis_mesh_root.add_child(skirt)

	# 5. Rear GT Wing / Spoiler + Uprights
	var wing_blade: MeshInstance3D = MeshInstance3D.new()
	var wing_box: BoxMesh = BoxMesh.new()
	wing_box.size = Vector3(1.66, 0.05, 0.30)
	wing_blade.mesh = wing_box
	wing_blade.material_override = _carbon_aero_mat
	wing_blade.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	wing_blade.position = Vector3(0.0, 0.64, 1.94)
	_chassis_mesh_root.add_child(wing_blade)

	for stand_sign: float in [-1.0, 1.0]:
		var stand: MeshInstance3D = MeshInstance3D.new()
		var stand_box: BoxMesh = BoxMesh.new()
		stand_box.size = Vector3(0.04, 0.32, 0.18)
		stand.mesh = stand_box
		stand.material_override = _carbon_aero_mat
		stand.position = Vector3(stand_sign * 0.56, 0.46, 1.94)
		_chassis_mesh_root.add_child(stand)

	# 6. Pop-up / Sleek Headlights + SpotLight3D Beams
	for hl_sign: float in [-1.0, 1.0]:
		var hl_housing: MeshInstance3D = MeshInstance3D.new()
		var hl_box: BoxMesh = BoxMesh.new()
		hl_box.size = Vector3(0.32, 0.12, 0.22)
		hl_housing.mesh = hl_box
		hl_housing.material_override = _carbon_aero_mat
		hl_housing.position = Vector3(hl_sign * 0.56, 0.28, -2.02)
		_chassis_mesh_root.add_child(hl_housing)

		var hl_lens: MeshInstance3D = MeshInstance3D.new()
		var lens_box: BoxMesh = BoxMesh.new()
		lens_box.size = Vector3(0.28, 0.08, 0.04)
		hl_lens.mesh = lens_box
		hl_lens.material_override = _headlight_emissive_mat
		hl_lens.position = Vector3(hl_sign * 0.56, 0.28, -2.13)
		_chassis_mesh_root.add_child(hl_lens)

	_headlight_left = _create_headlight_beam(Vector3(-0.56, 0.28, -2.15))
	_headlight_right = _create_headlight_beam(Vector3(0.56, 0.28, -2.15))
	_chassis_mesh_root.add_child(_headlight_left)
	_chassis_mesh_root.add_child(_headlight_right)

	# 7. Glowing JDM Taillight Bar & Quad Round Lights
	var tail_panel: MeshInstance3D = MeshInstance3D.new()
	var tail_box: BoxMesh = BoxMesh.new()
	tail_box.size = Vector3(1.58, 0.14, 0.05)
	tail_panel.mesh = tail_box
	tail_panel.material_override = _carbon_aero_mat
	tail_panel.position = Vector3(0.0, 0.20, 2.12)
	_chassis_mesh_root.add_child(tail_panel)

	for tl_x: float in [-0.60, -0.36, 0.36, 0.60]:
		var tl_orb: MeshInstance3D = MeshInstance3D.new()
		var tl_cyl: CylinderMesh = CylinderMesh.new()
		tl_cyl.top_radius = 0.065
		tl_cyl.bottom_radius = 0.065
		tl_cyl.height = 0.04
		tl_orb.mesh = tl_cyl
		tl_orb.material_override = _taillight_emissive_mat
		tl_orb.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		tl_orb.position = Vector3(tl_x, 0.20, 2.14)
		_chassis_mesh_root.add_child(tl_orb)

	# 8. Large Bore Exhaust Cannon & Rotary/Misfire Backfire Light
	var exhaust_pipe: MeshInstance3D = MeshInstance3D.new()
	var exhaust_cyl: CylinderMesh = CylinderMesh.new()
	exhaust_cyl.top_radius = 0.065
	exhaust_cyl.bottom_radius = 0.065
	exhaust_cyl.height = 0.28
	exhaust_pipe.mesh = exhaust_cyl
	exhaust_pipe.material_override = _wheel_alloy_mat
	exhaust_pipe.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	exhaust_pipe.position = Vector3(0.54, -0.10, 2.16)
	_chassis_mesh_root.add_child(exhaust_pipe)

	_exhaust_flash_light = OmniLight3D.new()
	_exhaust_flash_light.light_color = Color(1.0, 0.52, 0.12, 1.0)
	_exhaust_flash_light.light_energy = 0.0
	_exhaust_flash_light.omni_range = 3.5
	_exhaust_flash_light.position = Vector3(0.54, -0.10, 2.34)
	_chassis_mesh_root.add_child(_exhaust_flash_light)

	# 9. Four Spinning & Steering Alloy Wheels
	_wheel_pivots.clear()
	_wheel_spin_nodes.clear()

	for i: int in range(WHEEL_COUNT):
		var steer_pivot: Node3D = Node3D.new()
		steer_pivot.name = "WheelPivot_%d" % i
		steer_pivot.position = _wheel_local_offsets[i] - Vector3(0.0, SUSPENSION_REST_DIST, 0.0)
		_visual_root.add_child(steer_pivot)
		_wheel_pivots.append(steer_pivot)

		var spin_node: Node3D = Node3D.new()
		spin_node.name = "WheelSpin_%d" % i
		steer_pivot.add_child(spin_node)
		_wheel_spin_nodes.append(spin_node)

		# Tire Cylinder
		var tire_mesh_inst: MeshInstance3D = MeshInstance3D.new()
		var tire_cyl: CylinderMesh = CylinderMesh.new()
		tire_cyl.top_radius = WHEEL_RADIUS
		tire_cyl.bottom_radius = WHEEL_RADIUS
		tire_cyl.height = 0.25
		tire_cyl.radial_segments = 20
		tire_mesh_inst.mesh = tire_cyl
		tire_mesh_inst.material_override = _tire_rubber_mat
		tire_mesh_inst.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		spin_node.add_child(tire_mesh_inst)

		# Alloy Rim Hub
		var rim_mesh_inst: MeshInstance3D = MeshInstance3D.new()
		var rim_cyl: CylinderMesh = CylinderMesh.new()
		rim_cyl.top_radius = WHEEL_RADIUS * 0.68
		rim_cyl.bottom_radius = WHEEL_RADIUS * 0.68
		rim_cyl.height = 0.26
		rim_cyl.radial_segments = 16
		rim_mesh_inst.mesh = rim_cyl
		rim_mesh_inst.material_override = _wheel_alloy_mat
		rim_mesh_inst.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		spin_node.add_child(rim_mesh_inst)

		# 6-Spoke Crossbar Detail (makes wheel rotation visibly obvious)
		for spoke_idx: int in range(3):
			var spoke: MeshInstance3D = MeshInstance3D.new()
			var spoke_box: BoxMesh = BoxMesh.new()
			spoke_box.size = Vector3(0.27, WHEEL_RADIUS * 1.28, 0.045)
			spoke.mesh = spoke_box
			spoke.material_override = _carbon_aero_mat
			spoke.rotation_degrees = Vector3(float(spoke_idx) * 60.0, 0.0, 0.0)
			spin_node.add_child(spoke)


func _create_headlight_beam(local_pos: Vector3) -> SpotLight3D:
	var spot: SpotLight3D = SpotLight3D.new()
	spot.position = local_pos
	spot.light_color = Color(1.0, 0.96, 0.84, 1.0)
	spot.light_energy = 4.2
	spot.spot_range = 48.0
	spot.spot_angle = 28.0
	spot.spot_attenuation = 1.15
	spot.rotation_degrees = Vector3(-4.0, 0.0, 0.0)
	return spot


func _apply_rival_preset() -> void:
	if _body_paint_mat == null:
		return

	match rival_preset:
		RivalPreset.RX7_FD3S_YELLOW:
			# Sunburst / Competition Yellow FD3S with Bronze Rays Volk TE37 Rims
			_body_paint_mat.albedo_color = Color(0.98, 0.80, 0.04, 1.0)
			_wheel_alloy_mat.albedo_color = Color(0.76, 0.62, 0.36, 1.0)
			if rival_driver_title.is_empty() or rival_driver_title.contains("NAKAZATO") or rival_driver_title.contains("TAKUMI"):
				rival_driver_title = "REDSUNS KEISUKE // MAZDA RX-7 FD3S"
		RivalPreset.SKYLINE_R32_GREY:
			# Gunmetal Grey Metallic BNR32 GT-R with Dark Silver Rims
			_body_paint_mat.albedo_color = Color(0.24, 0.26, 0.29, 1.0)
			_wheel_alloy_mat.albedo_color = Color(0.62, 0.64, 0.68, 1.0)
			if rival_driver_title.is_empty() or rival_driver_title.contains("KEISUKE") or rival_driver_title.contains("TAKUMI"):
				rival_driver_title = "NIGHT KIDS NAKAZATO // SKYLINE GT-R R32"
		RivalPreset.TRUENO_AE86_PANDA:
			# High-Tech Two-Tone White/Black Sprinter Trueno with Dark Watanabe Rims
			_body_paint_mat.albedo_color = Color(0.94, 0.94, 0.96, 1.0)
			_wheel_alloy_mat.albedo_color = Color(0.18, 0.18, 0.20, 1.0)
			if rival_driver_title.is_empty() or rival_driver_title.contains("KEISUKE") or rival_driver_title.contains("NAKAZATO"):
				rival_driver_title = "PROJECT D TAKUMI // TRUENO AE86 GT-APEX"

	if _hud_rival_label != null:
		_hud_rival_label.text = rival_driver_title


func _apply_battle_mode_settings() -> void:
	if _collision_shape == null or _body_paint_mat == null:
		return

	if battle_mode == BattleMode.TIME_ATTACK_GHOST:
		# Disable chassis-to-player collision and make ghost car semi-transparent
		collision_layer = 0
		_body_paint_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_body_paint_mat.albedo_color.a = 0.48
	else:
		collision_layer = 1
		_body_paint_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		_body_paint_mat.albedo_color.a = 1.0


# ==============================================================================
# VISUAL ANIMATION: WHEELS, BRAKE LIGHTS, HIGH-BEAM FLASH & CHASSIS PITCH/ROLL
# ==============================================================================
func _update_visual_effects(delta: float, forward_speed: float) -> void:
	# 1. Wheel Suspension Travel, Steering Angle & Spin
	var front_steer_rad: float = -steer_input * max_steer_angle_rad
	var angular_spin_step: float = -(forward_speed / WHEEL_RADIUS) * delta

	for i: int in range(WHEEL_COUNT):
		var pivot: Node3D = _wheel_pivots[i]
		var spin_node: Node3D = _wheel_spin_nodes[i]

		var susp_offset_y: float = -SUSPENSION_REST_DIST + clampf(_wheel_compression[i], -0.15, 0.22)
		pivot.position.y = _wheel_local_offsets[i].y + susp_offset_y

		if i == FL or i == FR:
			pivot.rotation.y = front_steer_rad

		_wheel_spin_angles[i] = fmod(_wheel_spin_angles[i] + angular_spin_step, TAU)
		spin_node.rotation.x = _wheel_spin_angles[i]

	# 2. Subtle Chassis Dive / Squat & Roll Animation
	if _chassis_mesh_root != null:
		var target_pitch: float = (brake_input * 0.045) - (throttle_input * 0.025)
		var target_roll: float = -steer_input * clampf(current_speed_mps / 25.0, 0.0, 1.0) * 0.055
		_chassis_mesh_root.rotation.x = lerpf(_chassis_mesh_root.rotation.x, target_pitch, delta * 10.0)
		_chassis_mesh_root.rotation.z = lerpf(_chassis_mesh_root.rotation.z, target_roll, delta * 10.0)

	# 3. Dynamic Taillight Brake Glow
	if _taillight_emissive_mat != null:
		var target_tail_energy: float = 5.5 if brake_input > 0.05 else 1.6
		_taillight_emissive_mat.emission_energy_multiplier = lerpf(
			_taillight_emissive_mat.emission_energy_multiplier,
			target_tail_energy,
			delta * 18.0
		)

	# 4. Pursuit Mode High-Beam Headlight Strobe
	if _headlight_left != null and _headlight_right != null:
		if is_flashing_headlights:
			_flash_timer_s += delta * 18.0
			var beam_high: bool = sin(_flash_timer_s) > 0.0
			var beam_energy: float = 9.5 if beam_high else 2.2
			_headlight_left.light_energy = beam_energy
			_headlight_right.light_energy = beam_energy
			_headlight_emissive_mat.emission_energy_multiplier = 6.5 if beam_high else 2.0
		else:
			_headlight_left.light_energy = 4.2
			_headlight_right.light_energy = 4.2
			_headlight_emissive_mat.emission_energy_multiplier = 3.2

	# 5. Rotary / Anti-Lag Exhaust Backfire Pop
	if _exhaust_flash_light != null:
		if _backfire_timer_s > 0.0:
			_backfire_timer_s -= delta
			_exhaust_flash_light.light_energy = 6.0
		else:
			_exhaust_flash_light.light_energy = 0.0


# ==============================================================================
# REAL-TIME TOUGE BATTLE HUD (CANVASLAYER)
# ==============================================================================
func _build_battle_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "TougeBattleHUDLayer"
	_hud_layer.layer = 15
	add_child(_hud_layer)

	var root_control: Control = Control.new()
	root_control.name = "HUDRootControl"
	root_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(root_control)

	# 1. Top-Right Battle Status & Gap Panel
	_hud_root_panel = PanelContainer.new()
	_hud_root_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hud_root_panel.position = Vector2(-410.0, 18.0)
	_hud_root_panel.custom_minimum_size = Vector2(390.0, 146.0)
	_hud_root_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.05, 0.06, 0.09, 0.88)
	panel_style.border_width_left = 4
	panel_style.border_width_top = 2
	panel_style.border_width_right = 2
	panel_style.border_width_bottom = 2
	panel_style.border_color = Color(0.98, 0.80, 0.08, 0.95)
	panel_style.corner_radius_top_left = 4
	panel_style.corner_radius_bottom_left = 4
	panel_style.content_margin_left = 14.0
	panel_style.content_margin_right = 14.0
	panel_style.content_margin_top = 10.0
	panel_style.content_margin_bottom = 10.0
	_hud_root_panel.add_theme_stylebox_override("panel", panel_style)
	root_control.add_child(_hud_root_panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	_hud_root_panel.add_child(vbox)

	# Battle Status Header
	_hud_header_label = Label.new()
	_hud_header_label.text = "[TOUGE SUDDEN DEATH DUEL]"
	_hud_header_label.add_theme_font_size_override("font_size", 13)
	_hud_header_label.modulate = Color(0.75, 0.82, 0.92, 1.0)
	vbox.add_child(_hud_header_label)

	# Rival Name & Car Tag
	_hud_rival_label = Label.new()
	_hud_rival_label.text = rival_driver_title
	_hud_rival_label.add_theme_font_size_override("font_size", 15)
	_hud_rival_label.modulate = Color(1.0, 0.88, 0.18, 1.0)
	vbox.add_child(_hud_rival_label)

	# Live Gap Meter
	_hud_gap_label = Label.new()
	_hud_gap_label.text = "GAP: +14.2 m  (+0.48s)"
	_hud_gap_label.add_theme_font_size_override("font_size", 20)
	_hud_gap_label.modulate = COLOR_GAP_NEUTRAL
	vbox.add_child(_hud_gap_label)

	# Visual Proximity Radar Bar (-50m to +50m)
	_hud_radar_bar_bg = Control.new()
	_hud_radar_bar_bg.custom_minimum_size = Vector2(358.0, 14.0)
	vbox.add_child(_hud_radar_bar_bg)

	var bar_track: ColorRect = ColorRect.new()
	bar_track.color = Color(0.18, 0.20, 0.25, 1.0)
	bar_track.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud_radar_bar_bg.add_child(bar_track)

	_hud_radar_player_marker = ColorRect.new()
	_hud_radar_player_marker.color = Color(0.25, 0.88, 1.0, 1.0)
	_hud_radar_player_marker.size = Vector2(6.0, 14.0)
	_hud_radar_player_marker.position = Vector2(176.0, 0.0)
	_hud_radar_bar_bg.add_child(_hud_radar_player_marker)

	_hud_radar_rival_marker = ColorRect.new()
	_hud_radar_rival_marker.color = Color(1.0, 0.84, 0.08, 1.0)
	_hud_radar_rival_marker.size = Vector2(8.0, 14.0)
	_hud_radar_rival_marker.position = Vector2(176.0, 0.0)
	_hud_radar_bar_bg.add_child(_hud_radar_rival_marker)

	# AI Telemetry Sub-Line
	_hud_telemetry_label = Label.new()
	_hud_telemetry_label.text = "RIVAL: 118 km/h | STATE: APEX_CORNERING"
	_hud_telemetry_label.add_theme_font_size_override("font_size", 12)
	_hud_telemetry_label.modulate = Color(0.68, 0.72, 0.78, 1.0)
	vbox.add_child(_hud_telemetry_label)

	# 2. Top-Center Rearview Mirror Proximity / Attack Alert
	_hud_warning_panel = PanelContainer.new()
	_hud_warning_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_hud_warning_panel.position = Vector2(-190.0, 22.0)
	_hud_warning_panel.custom_minimum_size = Vector2(380.0, 44.0)
	_hud_warning_panel.visible = false
	_hud_warning_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var warn_style: StyleBoxFlat = StyleBoxFlat.new()
	warn_style.bg_color = COLOR_WARNING_BG_A
	warn_style.border_width_left = 2
	warn_style.border_width_right = 2
	warn_style.border_width_top = 2
	warn_style.border_width_bottom = 2
	warn_style.border_color = Color(1.0, 0.88, 0.20, 1.0)
	warn_style.content_margin_left = 12.0
	warn_style.content_margin_right = 12.0
	warn_style.content_margin_top = 6.0
	warn_style.content_margin_bottom = 6.0
	_hud_warning_panel.add_theme_stylebox_override("panel", warn_style)
	root_control.add_child(_hud_warning_panel)

	_hud_warning_label = Label.new()
	_hud_warning_label.text = "!! RIVAL ATTACKING INSIDE !!"
	_hud_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_warning_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hud_warning_label.add_theme_font_size_override("font_size", 18)
	_hud_warning_label.modulate = Color(1.0, 0.96, 0.85, 1.0)
	_hud_warning_panel.add_child(_hud_warning_label)

	# 3. Center Sudden Death Victory / Defeat Banner
	_hud_banner_panel = PanelContainer.new()
	_hud_banner_panel.set_anchors_preset(Control.PRESET_CENTER)
	_hud_banner_panel.position = Vector2(-280.0, -70.0)
	_hud_banner_panel.custom_minimum_size = Vector2(560.0, 120.0)
	_hud_banner_panel.visible = false
	_hud_banner_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var banner_style: StyleBoxFlat = StyleBoxFlat.new()
	banner_style.bg_color = Color(0.03, 0.04, 0.06, 0.95)
	banner_style.border_width_top = 3
	banner_style.border_width_bottom = 3
	banner_style.border_color = Color(1.0, 0.82, 0.12, 1.0)
	banner_style.content_margin_top = 18.0
	banner_style.content_margin_bottom = 18.0
	_hud_banner_panel.add_theme_stylebox_override("panel", banner_style)
	root_control.add_child(_hud_banner_panel)

	var banner_vbox: VBoxContainer = VBoxContainer.new()
	banner_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	banner_vbox.add_theme_constant_override("separation", 8)
	_hud_banner_panel.add_child(banner_vbox)

	_hud_banner_title = Label.new()
	_hud_banner_title.text = "SUDDEN DEATH VICTORY"
	_hud_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_banner_title.add_theme_font_size_override("font_size", 28)
	banner_vbox.add_child(_hud_banner_title)

	_hud_banner_subtitle = Label.new()
	_hud_banner_subtitle.text = "RIVAL DEFEATED"
	_hud_banner_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_banner_subtitle.add_theme_font_size_override("font_size", 15)
	_hud_banner_subtitle.modulate = Color(0.85, 0.88, 0.92, 1.0)
	banner_vbox.add_child(_hud_banner_subtitle)


func _update_battle_hud(delta: float) -> void:
	_hud_refresh_accum_s += delta
	_warning_blink_accum_s += delta

	# Blink warning banner at 10Hz when under corner attack or high-beam pressure
	if is_corner_attack_active or (is_flashing_headlights and absf(gap_spline_meters) < 8.0):
		_hud_warning_panel.visible = true
		var blink_high: bool = sin(_warning_blink_accum_s * 22.0) > 0.0
		_hud_warning_label.modulate = Color(1.0, 0.98, 0.25, 1.0) if blink_high else Color(1.0, 0.35, 0.35, 1.0)
		if is_corner_attack_active:
			_hud_warning_label.text = "!! RIVAL ATTACKING! (GAP: %.1fm) !!" % absf(gap_spline_meters)
		else:
			_hud_warning_label.text = "!! REARVIEW ALERT: RIVAL CLOSING IN !!"
	else:
		_hud_warning_panel.visible = false

	# Throttle string formatting to 15Hz for minimal UI overhead
	if _hud_refresh_accum_s < 0.066:
		return
	_hud_refresh_accum_s = 0.0

	# Mode Header
	match battle_mode:
		BattleMode.LEAD_CHASE:
			_hud_header_label.text = "[TOUGE SUDDEN DEATH DUEL // CHASE THE LEADER]"
		BattleMode.PURSUIT_CHASER:
			_hud_header_label.text = "[TOUGE SUDDEN DEATH DUEL // OUTRUN THE CHASER]"
		BattleMode.TIME_ATTACK_GHOST:
			_hud_header_label.text = "[TOUGE TIME ATTACK // RIVAL PACE GHOST]"

	# Gap String & Color Coding
	_hud_gap_label.text = "GAP: %+0.1f m  (%+0.2fs)" % [gap_spline_meters, gap_time_seconds]

	var abs_gap: float = absf(gap_spline_meters)
	if abs_gap < 8.0:
		# Close door-to-door battle = Yellow
		_hud_gap_label.modulate = COLOR_GAP_NEUTRAL
	elif rival_is_leading:
		# Rival is ahead: Red if pulling away dangerously, Yellow otherwise
		_hud_gap_label.modulate = COLOR_GAP_DANGER if gap_spline_meters > 22.0 else COLOR_GAP_NEUTRAL
	else:
		# Player is ahead of Rival: Green if pulling away, Red if Rival is right on bumper
		_hud_gap_label.modulate = COLOR_GAP_SAFE if gap_spline_meters < -12.0 else COLOR_GAP_NEUTRAL

	if is_corner_attack_active:
		_hud_gap_label.modulate = COLOR_GAP_DANGER

	# Update Proximity Radar Marker Position
	var radar_half_w: float = 175.0
	var normalized_gap: float = clampf(gap_spline_meters / sudden_death_gap_limit_m, -1.0, 1.0)
	_hud_radar_rival_marker.position.x = radar_half_w + (normalized_gap * (radar_half_w - 8.0))

	# Telemetry String
	var state_str: String = _get_ai_state_label(current_ai_state)
	_hud_telemetry_label.text = "SPD: %3.0f km/h | SLIP: %2.0f° | %s" % [
		current_speed_kmh,
		absf(rad_to_deg(current_slip_angle_rad)),
		state_str
	]


func _get_ai_state_label(state: AIState) -> String:
	match state:
		AIState.FULL_THROTTLE:
			return "FULL ATTACK"
		AIState.TRAIL_BRAKING:
			return "TRAIL BRAKING"
		AIState.APEX_CORNERING:
			return "HUGGING APEX"
		AIState.INERTIA_DRIFT:
			return "FOUR-WHEEL DRIFT"
		AIState.DEFENDING_LINE:
			return "DEFENDING LINE"
		AIState.OVERTAKE_DIVE:
			return "INSIDE OVERTAKE"
		AIState.BATTLE_FINISHED:
			return "DUEL FINISHED"
	return "RACING"