class_name ArcadeSimVehicle
extends RigidBody3D

## ============================================================================
## ShiTmoZ/RACING - Mount Akina Touge
## ArcadeSimVehicle.gd - Forza 6 Simcade Physics & Drivetrain Core (Godot 4.3)
## ============================================================================

# --- Public Telemetry Properties ---
@export var speed_kmh: float = 0.0
@export var engine_rpm: float = 800.0
@export var gear_number: int = 1 # 0 = Reverse, 1 = Neutral, 2+ = Gears 1-6
@export var is_reversing: bool = false
@export var steer_angle: float = 0.0

# Telemetry & Audio/VFX bindings
var throttle_input: float:
	get: return _throttle_input
	set(v): _throttle_input = v
var brake_input: float:
	get: return _brake_input
	set(v): _brake_input = v
var handbrake_input: float = 0.0

var current_gear: int:
	get: return gear_number

var gear_ratio: float:
	get:
		if specs != null and _current_gear_idx < specs.gear_ratios.size():
			return specs.gear_ratios[_current_gear_idx]
		return 1.0

var tire_slip_velocities: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _wheel_grounded: PackedInt32Array = PackedInt32Array([1, 1, 1, 1])
var _wheel_contact: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]

# --- Vehicle Specification Profiles ---
enum CarType { AE86, R34 }
@export var active_car: CarType = CarType.AE86

class VehicleSpecs:
	var name: String
	var mass: float
	var weight_bias_front: float # e.g. 0.53 = 53% front
	var wheelbase: float
	var track_width: float
	var cg_height: float
	
	# Engine
	var max_hp: float
	var peak_hp_rpm: float
	var max_torque_nm: float
	var peak_torque_rpm: float
	var redline_rpm: float
	var idle_rpm: float
	
	# Transmission & Drivetrain
	var drive_type: String # "FR" or "AWD"
	var gear_ratios: PackedFloat32Array
	var final_drive: float
	
	# Suspension & Tires
	var spring_stiffness: float
	var damping_ratio: float
	var max_suspension_travel: float
	var tire_grip_mult: float
	var weight_transfer_gain: float

var specs: VehicleSpecs

# --- Vehicle Profiles Data Dictionary ---
var specs_ae86 := VehicleSpecs.new()
var specs_r34 := VehicleSpecs.new()

# --- Internal Physics & Control State ---
var _throttle_input: float = 0.0
var _brake_input: float = 0.0
var _raw_steer_input: float = 0.0
var _clutch_delay_timer: float = 0.0
var _current_gear_idx: int = 2 # Default 1st gear (0=R, 1=N, 2=1st)
var _spawn_transform: Transform3D = Transform3D.IDENTITY
var _is_shifting: bool = false
var _flip_timer: float = 0.0

# Suspension Raycast States & Wheel Transforms (FL, FR, RL, RR)
var _wheel_nodes: Array[Node3D] = []
var _suspension_lengths: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _wheel_speeds: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _wheel_slips: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _wheel_spin: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])

# Visual Mesh Nodes
@export var mesh_ae86_path: NodePath
@export var mesh_r34_path: NodePath
var _mesh_ae86: Node3D
var _mesh_r34: Node3D

# Audio / Particle Triggers
var tire_scrub_intensity: float = 0.0


## ============================================================================
## INITIALIZATION & PROFILE SETUP
## ============================================================================

func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 8
	_init_vehicle_specs()
	_setup_wheel_nodes()
	_setup_mesh_nodes()
	apply_vehicle_profile("ae86" if active_car == CarType.AE86 else "r34")
	_spawn_transform = global_transform


func _init_vehicle_specs() -> void:
	# Profile A: Toyota Sprinter Trueno (AE86 GT-APEX)
	specs_ae86.name = "Toyota Sprinter Trueno AE86"
	specs_ae86.mass = 960.0
	specs_ae86.weight_bias_front = 0.53
	specs_ae86.wheelbase = 2.40
	specs_ae86.track_width = 1.35
	specs_ae86.cg_height = 0.46
	specs_ae86.max_hp = 175.0
	specs_ae86.peak_hp_rpm = 7800.0
	specs_ae86.max_torque_nm = 192.0
	specs_ae86.peak_torque_rpm = 5600.0
	specs_ae86.redline_rpm = 8200.0
	specs_ae86.idle_rpm = 950.0
	specs_ae86.drive_type = "FR"
	specs_ae86.gear_ratios = PackedFloat32Array([-3.25, 0.0, 3.58, 2.15, 1.51, 1.19, 1.00, 0.85]) # R, N, 1-6
	specs_ae86.final_drive = 4.30
	specs_ae86.spring_stiffness = 38000.0
	specs_ae86.damping_ratio = 0.65
	specs_ae86.max_suspension_travel = 0.22
	specs_ae86.tire_grip_mult = 1.15
	specs_ae86.weight_transfer_gain = 1.25

	# Profile B: Nissan Skyline GT-R (BNR34 V-Spec II)
	specs_r34.name = "Nissan Skyline GT-R BNR34"
	specs_r34.mass = 1560.0
	specs_r34.weight_bias_front = 0.57
	specs_r34.wheelbase = 2.66
	specs_r34.track_width = 1.48
	specs_r34.cg_height = 0.49
	specs_r34.max_hp = 330.0
	specs_r34.peak_hp_rpm = 6800.0
	specs_r34.max_torque_nm = 425.0
	specs_r34.peak_torque_rpm = 4400.0
	specs_r34.redline_rpm = 8000.0
	specs_r34.idle_rpm = 850.0
	specs_r34.drive_type = "AWD"
	specs_r34.gear_ratios = PackedFloat32Array([-3.01, 0.0, 3.82, 2.20, 1.48, 1.16, 0.97, 0.82]) # R, N, 1-6
	specs_r34.final_drive = 3.541
	specs_r34.spring_stiffness = 52000.0
	specs_r34.damping_ratio = 0.68
	specs_r34.max_suspension_travel = 0.20
	specs_r34.tire_grip_mult = 1.25
	specs_r34.weight_transfer_gain = 1.10


func _setup_wheel_nodes() -> void:
	_wheel_nodes.clear()
	var ray_names := ["RayFL", "RayFR", "RayRL", "RayRR"]
	var wheel_names := ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]
	for i in range(4):
		var node: Node3D = find_child(wheel_names[i], true, false) as Node3D
		if node == null:
			node = get_node_or_null(ray_names[i]) as Node3D
		if node == null:
			var marker := Marker3D.new()
			marker.name = wheel_names[i]
			match i:
				0: marker.position = Vector3(-0.72, -0.2, -1.20)
				1: marker.position = Vector3(0.72, -0.2, -1.20)
				2: marker.position = Vector3(-0.72, -0.2, 1.20)
				3: marker.position = Vector3(0.72, -0.2, 1.20)
			add_child(marker)
			node = marker
		_wheel_nodes.append(node)


func _setup_mesh_nodes() -> void:
	if not mesh_ae86_path.is_empty():
		_mesh_ae86 = get_node_or_null(mesh_ae86_path) as Node3D
	if not mesh_r34_path.is_empty():
		_mesh_r34 = get_node_or_null(mesh_r34_path) as Node3D


## ============================================================================
## PUBLIC VEHICLE SWITCHER & TELEMETRY API
## ============================================================================

func apply_vehicle_profile(car_type_str: String) -> void:
	if car_type_str.to_lower().contains("ae86") or car_type_str == "0":
		active_car = CarType.AE86
		specs = specs_ae86
		if _mesh_ae86: _mesh_ae86.visible = true
		if _mesh_r34: _mesh_r34.visible = false
	else:
		active_car = CarType.R34
		specs = specs_r34
		if _mesh_ae86: _mesh_ae86.visible = false
		if _mesh_r34: _mesh_r34.visible = true
	
	mass = specs.mass
	engine_rpm = specs.idle_rpm
	_current_gear_idx = 2 # 1st gear
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func respawn() -> void:
	global_transform = _spawn_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_current_gear_idx = 2
	engine_rpm = specs.idle_rpm
	sleeping = false
	_flip_timer = 0.0


func set_spawn_transform(t: Transform3D) -> void:
	_spawn_transform = t


## ============================================================================
## INPUT GATHERING & PHYSICS INTEGRATION
## ============================================================================

func _process(delta: float) -> void:
	# Gather Arcade/Sim Player Controls
	_throttle_input = Input.get_action_strength("accelerate")
	_brake_input = Input.get_action_strength("brake")
	handbrake_input = Input.get_action_strength("handbrake")
	
	var steer_left := Input.get_action_strength("steer_left")
	var steer_right := Input.get_action_strength("steer_right")
	_raw_steer_input = steer_left - steer_right # Positive steer turns car
	
	if Input.is_action_just_pressed("reset_vehicle"):
		respawn()
	
	# Automatic / Sequential Shifting
	if InputMap.has_action("gear_up") and Input.is_action_just_pressed("gear_up") and not _is_shifting:
		_shift_gear(1)
	elif InputMap.has_action("gear_down") and Input.is_action_just_pressed("gear_down") and not _is_shifting:
		_shift_gear(-1)
	elif not _is_shifting and _current_gear_idx >= 2:
		# Auto-shift up when hitting redline
		if engine_rpm > specs.redline_rpm - 450.0 and _current_gear_idx < specs.gear_ratios.size() - 1:
			_shift_gear(1)
		# Auto-shift down when speed / RPM drops
		elif engine_rpm < 2400.0 and _current_gear_idx > 2 and speed_kmh < (float(_current_gear_idx) * 22.0):
			_shift_gear(-1)
	
	if _clutch_delay_timer > 0.0:
		_clutch_delay_timer -= delta
	
	# Anti-flip recovery
	if global_position.y < -35.0:
		respawn()
	elif global_transform.basis.y.dot(Vector3.UP) < 0.25 and linear_velocity.length() < 3.0:
		_flip_timer += delta
		if _flip_timer > 2.0:
			respawn()
	else:
		_flip_timer = 0.0


func _shift_gear(dir: int) -> void:
	var max_gear: int = specs.gear_ratios.size() - 1
	var target_gear := clampi(_current_gear_idx + dir, 0, max_gear)
	if target_gear != _current_gear_idx:
		_is_shifting = true
		_clutch_delay_timer = 0.18 # ~180ms shift delay
		_current_gear_idx = target_gear
		get_tree().create_timer(0.18).timeout.connect(func(): _is_shifting = false)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var dt := state.step
	if dt <= 0.0:
		return
	
	# 1. Calculate Velocity & Speed Telemetry
	var local_vel := global_transform.basis.inverse() * linear_velocity
	speed_kmh = absf(local_vel.z) * 3.6
	is_reversing = (_current_gear_idx == 0) or (local_vel.z > 0.5 and _brake_input > 0.1)
	gear_number = 0 if is_reversing else (_current_gear_idx - 1) # 0=R, 1=1st, 2=2nd...
	
	# 2. Steering & Dynamic Speed-Sensitive Steering Angle
	var max_steer_rad := deg_to_rad(34.0)
	var speed_sens_factor := clampf(1.0 - (speed_kmh / 240.0) * 0.45, 0.55, 1.0)
	steer_angle = move_toward(steer_angle, _raw_steer_input * max_steer_rad * speed_sens_factor, dt * 7.5)
	
	# 3. Longitudinal & Lateral Weight Transfer Computation (Forza 6 Dynamics)
	var prev_speed: float = _wheel_speeds[0] if _wheel_speeds.size() > 0 else local_vel.z
	var accel_long := (local_vel.z - prev_speed) / dt
	var accel_lat := local_vel.x * local_vel.z * 0.08 # Centrifugal load
	
	var weight_transfer_long := (accel_long / 9.81) * (specs.cg_height / specs.wheelbase) * specs.mass * specs.weight_transfer_gain
	var weight_transfer_lat := (accel_lat / 9.81) * (specs.cg_height / specs.track_width) * specs.mass * specs.weight_transfer_gain
	
	# Static axle loads
	var total_weight := specs.mass * 9.81
	var static_front_load := total_weight * specs.weight_bias_front * 0.5
	var static_rear_load := total_weight * (1.0 - specs.weight_bias_front) * 0.5
	
	# Dynamic Normal Loads (Fz) per wheel: [FL, FR, RL, RR]
	var fz_fl := clampf(static_front_load - weight_transfer_long * 0.5 - weight_transfer_lat, 80.0, total_weight)
	var fz_fr := clampf(static_front_load - weight_transfer_long * 0.5 + weight_transfer_lat, 80.0, total_weight)
	var fz_rl := clampf(static_rear_load + weight_transfer_long * 0.5 - weight_transfer_lat, 80.0, total_weight)
	var fz_rr := clampf(static_rear_load + weight_transfer_long * 0.5 + weight_transfer_lat, 80.0, total_weight)
	var wheel_loads: PackedFloat32Array = PackedFloat32Array([fz_fl, fz_fr, fz_rl, fz_rr])
	
	# 4. Raycast Suspension & Tire Force Simulation
	var total_scrub := 0.0
	for i in range(4):
		var wheel_node := _wheel_nodes[i] as Node3D
		var wheel_pos := wheel_node.global_position
		
		# Perform raycast downward from wheel anchor
		var ray_origin := wheel_pos + global_transform.basis.y * 0.15
		var ray_dir := -global_transform.basis.y * (specs.max_suspension_travel + 0.45)
		
		var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_dir)
		query.exclude = [self.get_rid()]
		var space_state := state.get_space_state()
		var hit := space_state.intersect_ray(query)
		
		if not hit.is_empty():
			_wheel_grounded[i] = 1
			_wheel_contact[i] = hit.position
			
			var hit_pos: Vector3 = hit.position
			var hit_dist := wheel_pos.distance_to(hit_pos)
			var compression := clampf(specs.max_suspension_travel - hit_dist, 0.0, specs.max_suspension_travel)
			
			# Spring force (Hooke's Law) + Damper force
			var spring_force := compression * specs.spring_stiffness
			var wheel_vel_y := state.get_velocity_at_local_position(wheel_pos - global_transform.origin).dot(global_transform.basis.y)
			var damping_force := -wheel_vel_y * (2.0 * sqrt(specs.spring_stiffness * specs.mass * 0.25) * specs.damping_ratio)
			
			var total_susp_force := maxf(0.0, spring_force + damping_force)
			state.apply_force(global_transform.basis.y * total_susp_force, wheel_pos - global_transform.origin)
			
			# Tire Friction & Slip Forces (Pacejka approximation)
			var surface_vel := state.get_velocity_at_local_position(wheel_pos - global_transform.origin)
			var forward_dir := -global_transform.basis.z
			var right_dir := global_transform.basis.x
			
			if i < 2: # Steered Front Wheels
				forward_dir = (global_transform.basis.rotated(global_transform.basis.y, steer_angle) * Vector3.FORWARD).normalized()
			
			var f_vel := surface_vel.dot(forward_dir)
			var r_vel := surface_vel.dot(right_dir)
			
			# Slip angle & grip limit
			var slip_angle := atan2(r_vel, absf(f_vel) + 1.0)
			var grip_multiplier := specs.tire_grip_mult
			if i >= 2 and handbrake_input > 0.1:
				grip_multiplier *= 0.32 # Handbrake locks rear wheels into drift
			
			var max_friction_force: float = wheel_loads[i] * grip_multiplier
			
			# Lateral cornering grip force
			var lateral_force_mag: float = -slip_angle * 13500.0 * (wheel_loads[i] / static_front_load)
			lateral_force_mag = clampf(lateral_force_mag, -max_friction_force, max_friction_force)
			state.apply_force(right_dir * lateral_force_mag, wheel_pos - global_transform.origin)
			
			tire_slip_velocities[i] = absf(r_vel)
			total_scrub += absf(r_vel)
			_wheel_speeds[i] = f_vel
			
			# Visual Wheel Animation (Spin & Steer)
			var wheel_radius: float = 0.31
			_wheel_spin[i] = fposmod(_wheel_spin[i] - (f_vel / wheel_radius) * dt, TAU)
			var s_angle: float = steer_angle if i < 2 else 0.0
			wheel_node.transform.basis = Basis(Vector3.UP, s_angle) * Basis(Vector3.RIGHT, _wheel_spin[i])
		else:
			_wheel_grounded[i] = 0
			_wheel_speeds[i] = 0.0
			tire_slip_velocities[i] = 0.0
	
	tire_scrub_intensity = clampf(total_scrub / 10.0, 0.0, 1.0)
	
	# 5. Drivetrain Engine & Torque Simulation
	_simulate_drivetrain(dt)
	
	# 6. Apply Engine Propulsion Force to Wheels
	_apply_propulsion_forces(state)


## ============================================================================
## DRIVETRAIN & ENGINE TORQUE CURVE
## ============================================================================

func _simulate_drivetrain(dt: float) -> void:
	if _current_gear_idx == 1 or _is_shifting or _clutch_delay_timer > 0.0:
		var target_idle = specs.idle_rpm if _throttle_input <= 0.01 else specs.idle_rpm + _throttle_input * 4000.0
		engine_rpm = move_toward(engine_rpm, target_idle, dt * 3200.0)
		return
	
	# Calculate wheel-based RPM in gear
	var avg_wheel_speed_mps := (_wheel_speeds[2] + _wheel_speeds[3]) * 0.5
	var gear_ratio_val := specs.gear_ratios[_current_gear_idx]
	var calculated_rpm := absf(avg_wheel_speed_mps) * 30.0 * absf(gear_ratio_val) * specs.final_drive / 3.14159
	
	var target_rpm = maxf(specs.idle_rpm, calculated_rpm)
	if _throttle_input > 0.0 and _current_gear_idx >= 2:
		engine_rpm = move_toward(engine_rpm, target_rpm + _throttle_input * 2000.0, dt * 5000.0)
	else:
		engine_rpm = move_toward(engine_rpm, target_rpm, dt * 3500.0)
	
	engine_rpm = clampf(engine_rpm, specs.idle_rpm, specs.redline_rpm)


func _apply_propulsion_forces(state: PhysicsDirectBodyState3D) -> void:
	if _current_gear_idx == 1 or _is_shifting:
		return
	
	# Torque curve estimation based on peak HP & Torque RPM
	var rpm_ratio := engine_rpm / specs.peak_torque_rpm
	var torque_curve_factor := sin(clampf(rpm_ratio * 1.5, 0.0, 3.14159))
	if engine_rpm > specs.redline_rpm - 300.0:
		torque_curve_factor *= 0.15 # Rev limiter soft cut
	
	var available_torque := (specs.max_torque_nm * maxf(0.35, torque_curve_factor)) * _throttle_input
	var gear_ratio_val := specs.gear_ratios[_current_gear_idx]
	var total_drive_ratio := gear_ratio_val * specs.final_drive
	var wheel_radius := 0.31 # Standard Touge tire radius
	var tractive_force := (available_torque * total_drive_ratio / wheel_radius)
	
	# Brake and Reverse Logic
	if _brake_input > 0.0:
		if speed_kmh < 3.5 and _brake_input > 0.2:
			# Auto-shift to Reverse when holding brake at low speed
			_current_gear_idx = 0
			tractive_force = -specs.max_torque_nm * 0.95 * _brake_input * specs.final_drive / wheel_radius
		else:
			var brake_force_vec = -linear_velocity.normalized() * _brake_input * specs.mass * 9.5
			state.apply_central_force(brake_force_vec)
	elif _current_gear_idx == 0:
		# In Reverse gear, pressing throttle accelerates backwards
		tractive_force = -available_torque * absf(gear_ratio_val) * specs.final_drive / wheel_radius * 0.90
	
	# Distribute Torque according to Drivetrain Type (FR vs ATTESA AWD)
	if specs.drive_type == "FR":
		# Rear-Wheel Drive with Mechanical 2-Way LSD simulation
		var force_vector = -global_transform.basis.z * (tractive_force * 0.5)
		state.apply_force(force_vector, _wheel_nodes[2].global_position - global_transform.origin)
		state.apply_force(force_vector, _wheel_nodes[3].global_position - global_transform.origin)
	elif specs.drive_type == "AWD":
		# Nissan ATTESA E-TS Active Torque Split (Rear biased, dynamically shifts up to 50% front)
		var front_split := clampf(0.15 + _throttle_input * 0.35, 0.15, 0.50)
		var rear_split := 1.0 - front_split
		
		var f_force = -global_transform.basis.z * (tractive_force * front_split * 0.5)
		var r_force = -global_transform.basis.z * (tractive_force * rear_split * 0.5)
		
		state.apply_force(f_force, _wheel_nodes[0].global_position - global_transform.origin)
		state.apply_force(f_force, _wheel_nodes[1].global_position - global_transform.origin)
		state.apply_force(r_force, _wheel_nodes[2].global_position - global_transform.origin)
		state.apply_force(r_force, _wheel_nodes[3].global_position - global_transform.origin)
