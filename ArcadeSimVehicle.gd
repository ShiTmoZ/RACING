class_name ArcadeSimVehicle
extends RigidBody3D
## Arcade-sim vehicle controller.
##
## Raycast suspension + per-wheel friction-circle tire model + torque-curve driven
## automatic gearbox.  The body is a plain RigidBody3D; all cornering, grip and
## suspension behaviour is produced by forces applied at the four wheel contacts,
## which keeps the car stable at 120 Hz physics without any raycast "glue".
##
## Local axes: -Z = forward, +X = right, +Y = up.

signal gear_changed(new_gear: int)

@export_group("Wheel Nodes")
## RayCast3D nodes whose origin is the suspension mount and whose ray points
## straight down along -Y.  Expected order: FL, FR, RL, RR.
@export var wheel_rays: Array[RayCast3D] = []
## Visual wheel nodes, same order as [member wheel_rays].
@export var wheel_meshes: Array[Node3D] = []
## Index into [member wheel_rays] for the two steered wheels.
@export var front_wheel_indices: Array[int] = [0, 1]
## Index into [member wheel_rays] for the driven wheels (RWD by default).
@export var driven_wheel_indices: Array[int] = [2, 3]
@export var wheel_radius: float = 0.36
## Total ray length from mount to the fully extended wheel contact.
@export var ray_length: float = 0.72

@export_group("Suspension")
@export var suspension_stiffness: float = 45000.0
@export var suspension_damping: float = 4300.0
@export var suspension_max_force: float = 45000.0
@export var anti_roll_stiffness: float = 11000.0

@export_group("RB26DETT Engine & Turbo")
@export var base_peak_torque_nm: float = 520.0
@export var idle_rpm: float = 950.0
@export var redline_rpm: float = 8200.0
@export var rev_limiter_cutoff_rpm: float = 8350.0
@export var engine_inertia: float = 0.22 ## Controls free-revving responsiveness
@export var engine_braking_coeff: float = 45.0

@export_subgroup("Twin-Turbocharger (Garrett T28 Spec)")
@export var min_vacuum_bar: float = -0.65
@export var max_boost_bar: float = 1.35
@export var boost_threshold_rpm: float = 3200.0
@export var full_spool_rpm: float = 4200.0
@export var spool_up_rate: float = 4.2 ## Bar/sec under full exhaust load
@export var bypass_vent_rate: float = 9.5 ## Blow-off valve decay rate (Bar/sec)
@export var max_boost_torque_multiplier: float = 1.48 ## Peak multiplier at +1.35 bar

@export_group("Close-Ratio 6-Speed Touge Gearbox")
@export var gear_ratios: Array[float] = [3.827, 2.360, 1.685, 1.312, 1.000, 0.793]
@export var reverse_ratio: float = 3.280
@export var final_drive: float = 3.545
@export var drivetrain_efficiency: float = 0.88
@export var upshift_rpm: float = 7100.0
@export var downshift_rpm: float = 3100.0
@export var shift_duration_sec: float = 0.11
@export var auto_transmission: bool = true
@export var max_reverse_speed: float = 18.0

@export_group("Braking & Wheel Specs")
@export var max_brake_torque_nm: float = 3400.0
@export var direction_switch_speed_threshold: float = 1.25 ## m/s (~4.5 km/h)

@export_group("Tires")
## Peak friction coefficient of the tire model (1.0 = 1 g).
@export var tire_grip: float = 1.55
@export var rear_grip_multiplier: float = 1.0
@export var handbrake_grip_multiplier: float = 0.28
@export var rolling_resistance: float = 180.0

@export_group("Aero")
## 0.5 * air_density * Cd * frontal_area.  F = coefficient * v^2.
@export var drag_coefficient: float = 0.43
## 0.5 * air_density * Cl * frontal_area.  F = coefficient * v^2.
@export var downforce_coefficient: float = 0.95

@export_group("Steering")
@export var max_steer_angle: float = 0.62
@export var min_steer_angle: float = 0.15
@export var steer_speed_reference: float = 55.0
@export var steer_rate: float = 7.5
@export var steer_centering_rate: float = 11.0

# ----------------------------------------------------------------------------- state
var steer_angle: float = 0.0
var steer_input: float = 0.0
var throttle_input: float = 0.0
var brake_input: float = 0.0
var handbrake_input: float = 0.0

var speed_kmh: float = 0.0
var forward_speed: float = 0.0
var engine_rpm: float = 950.0
var gear_number: int = 1
var is_reversing: bool = false

# --- Runtime Telemetry (RB26DETT & Touge Transmission) ---
var current_rpm: float = 950.0
var current_boost_bar: float = -0.65
var current_gear: int = 1
var shift_timer: float = 0.0

var active_engine_throttle: float = 0.0
var net_drive_axle_torque_nm: float = 0.0
var net_wheel_brake_torque_nm: float = 0.0

var _engine_force: float = 0.0
var _shift_timer: float:
	get:
		return shift_timer
	set(val):
		shift_timer = val

var _gear_index: int:
	get:
		return maxi(0, current_gear - 1)
	set(val):
		current_gear = val + 1

var turbo_boost_bar: float:
	get:
		return current_boost_bar

var boost_bar: float:
	get:
		return current_boost_bar

var turbo_boost: float:
	get:
		return current_boost_bar

var gear_ratio: float:
	get:
		return absf(get_active_gear_ratio())
var _spawn_transform: Transform3D = Transform3D.IDENTITY
var _flip_timer: float = 0.0

var _is_front: PackedByteArray = PackedByteArray()
var _is_driven: PackedByteArray = PackedByteArray()

var _wheel_spin: PackedFloat32Array = PackedFloat32Array()
var _wheel_steer: PackedFloat32Array = PackedFloat32Array()
var _wheel_compression: PackedFloat32Array = PackedFloat32Array()
var _wheel_distance: PackedFloat32Array = PackedFloat32Array()
var _wheel_force: PackedFloat32Array = PackedFloat32Array()
var _wheel_grounded: PackedByteArray = PackedByteArray()
var _wheel_contact: Array[Vector3] = []
var _wheel_normal: Array[Vector3] = []

# Telemetries exposed for audio and VFX subsystem
var tire_slip_velocities: Array[float] = [0.0, 0.0, 0.0, 0.0]
var wheel_contact_points: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var wheel_contact_normals: Array[Vector3] = [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP]
var wheel_is_grounded: Array[bool] = [false, false, false, false]
const TougeDriftPhysicsSolverScript = preload("res://TougeDriftPhysicsSolver.gd")
var drift_solver: RefCounted = null



# ----------------------------------------------------------------------------- lifecycle
func _ready() -> void:
	can_sleep = false
	contact_monitor = false
	_spawn_transform = global_transform
	if TougeDriftPhysicsSolverScript != null:
		drift_solver = TougeDriftPhysicsSolverScript.new()
	_resolve_wheel_nodes()
	_build_wheel_flags()
	_allocate_wheel_state()
	gear_number = _gear_index + 1

func _physics_process(delta: float) -> void:
	if delta <= 0.0 or wheel_rays.is_empty():
		return

	_read_input()
	_update_motion_state()
	_update_steering(delta)
	_update_drivetrain(delta)
	_apply_suspension_and_tires(delta)
	_apply_aero()
	_apply_chassis_stabilization(delta)
	_update_wheel_visuals(delta)
	_check_recovery(delta)
	if r34_model != null:
		if "is_braking" in r34_model:
			r34_model.is_braking = (brake_input > 0.05) or (handbrake_input > 0.1)
		if "is_reversing" in r34_model:
			r34_model.is_reversing = is_reversing
		if "headlights_on" in r34_model:
			r34_model.headlights_on = true
		if r34_model.has_method("set_brake_heat"):
			var effective_brake: float = clampf(brake_input if not is_reversing else throttle_input, 0.0, 1.0)
			r34_model.set_brake_heat(effective_brake)
		if r34_model.has_method("set_drift_vfx"):
			var lat_slip := absf(linear_velocity.dot(global_transform.basis.x))
			var is_drifting := lat_slip > 2.6 or (handbrake_input > 0.5 and forward_speed > 4.0)
			r34_model.set_drift_vfx(is_drifting, forward_speed * 3.6)

# ----------------------------------------------------------------------------- setup
var r34_model: Node3D = null

func on_visual_chassis_rebound(model_root: Node3D, found_wheels: Array[Node3D]) -> void:
	r34_model = model_root
	wheel_meshes.clear()
	for w in found_wheels:
		if is_instance_valid(w):
			wheel_meshes.append(w)

func rebind_wheels(found_wheels: Array[Node3D]) -> void:
	wheel_meshes.clear()
	for w in found_wheels:
		if is_instance_valid(w):
			wheel_meshes.append(w)

func _resolve_wheel_nodes() -> void:
	# The scene wires these through exported node references, but the controller
	# stays usable when it is instanced from code with nothing wired at all.
	var rays_valid := not wheel_rays.is_empty()
	for ray in wheel_rays:
		if ray == null:
			rays_valid = false
	if not rays_valid:
		wheel_rays.clear()
		for child in get_children():
			if child is RayCast3D:
				wheel_rays.append(child as RayCast3D)

	r34_model = get_node_or_null("R34SkylineModeler")
	if r34_model != null and "WheelFL" in r34_model and r34_model.WheelFL != null:
		wheel_meshes = [r34_model.WheelFL, r34_model.WheelFR, r34_model.WheelRL, r34_model.WheelRR]
	else:
		var meshes_valid := not wheel_meshes.is_empty()
		for mesh in wheel_meshes:
			if mesh == null:
				meshes_valid = false
		if not meshes_valid:
			wheel_meshes.clear()
			for child in get_children():
				if child is Node3D and String(child.name).begins_with("Wheel"):
					wheel_meshes.append(child as Node3D)

func _build_wheel_flags() -> void:
	var count := wheel_rays.size()
	_is_front.resize(count)
	_is_driven.resize(count)
	for i in count:
		_is_front[i] = 1 if front_wheel_indices.has(i) else 0
		_is_driven[i] = 1 if driven_wheel_indices.has(i) else 0

func _allocate_wheel_state() -> void:
	var count := wheel_rays.size()
	_wheel_spin.resize(count)
	_wheel_steer.resize(count)
	_wheel_compression.resize(count)
	_wheel_distance.resize(count)
	_wheel_force.resize(count)
	_wheel_grounded.resize(count)
	_wheel_contact.resize(count)
	_wheel_normal.resize(count)
	for i in count:
		_wheel_distance[i] = ray_length
		if wheel_rays[i] != null:
			wheel_rays[i].exclude_parent = true
			wheel_rays[i].collision_mask = 1
			wheel_rays[i].target_position = Vector3(0.0, -ray_length, 0.0)
			wheel_rays[i].force_raycast_update()

# ----------------------------------------------------------------------------- input
func _read_input() -> void:
	steer_input = Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	throttle_input = Input.get_action_strength("accelerate")
	brake_input = Input.get_action_strength("brake")
	handbrake_input = Input.get_action_strength("handbrake")
	if Input.is_action_just_pressed("reset_vehicle"):
		respawn()

# ----------------------------------------------------------------------------- motion
func flat_forward() -> Vector3:
	var f := -global_transform.basis.z
	f.y = 0.0
	if f.length_squared() < 0.0001:
		return Vector3.FORWARD
	return f.normalized()

func _update_motion_state() -> void:
	forward_speed = linear_velocity.dot(flat_forward())
	speed_kmh = absf(forward_speed) * 3.6

func _update_steering(delta: float) -> void:
	var axis := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	if drift_solver != null:
		steer_angle = drift_solver.compute_assisted_steer(
			delta,
			axis,
			steer_angle,
			forward_speed,
			linear_velocity,
			global_transform.basis
		)
	else:
		var speed_ratio := clampf(absf(forward_speed) / steer_speed_reference, 0.0, 1.0)
		var limit := lerpf(max_steer_angle, min_steer_angle, speed_ratio)
		var goal := axis * limit
		var rate := steer_rate if absf(goal) > absf(steer_angle) else steer_centering_rate
		steer_angle = move_toward(steer_angle, goal, rate * delta)
	for i in _wheel_steer.size():
		_wheel_steer[i] = steer_angle if _is_front[i] == 1 else 0.0

# ----------------------------------------------------------------------------- drivetrain
func _update_drivetrain(delta: float) -> void:
	var avg_omega := forward_speed / maxf(wheel_radius, 0.05)
	var prev_gear := current_gear

	update_drivetrain(delta, forward_speed, avg_omega)

	# Convert net axle drive torque into linear tire propulsion force
	var drive_force := net_drive_axle_torque_nm / maxf(wheel_radius, 0.05)
	if is_reversing and forward_speed < -max_reverse_speed:
		drive_force = 0.0
	_engine_force = drive_force

	engine_rpm = current_rpm
	gear_number = current_gear if current_gear > 0 else 1
	if current_gear != prev_gear:
		gear_changed.emit(current_gear)


## Call inside _physics_process(delta) before executing your Kamm's Circle / Raycast solver.
## @param forward_speed_mps: Vehicle velocity projected onto -global_transform.basis.z
## @param avg_drive_wheel_omega: Average angular velocity (rad/s) of driven wheels
func update_drivetrain(delta: float, forward_speed_mps: float, avg_drive_wheel_omega: float) -> void:
	_resolve_reverse_and_braking_separation(forward_speed_mps)

	if auto_transmission:
		_update_automatic_transmission(delta, forward_speed_mps)
	elif shift_timer > 0.0:
		shift_timer = maxf(0.0, shift_timer - delta)

	_update_rpm_and_turbo_spool(delta, avg_drive_wheel_omega)
	_compute_axle_drive_torque()


# ------------------------------------------------------------------------------
# 1. REVERSE GEAR & BRAKING STATE SEPARATION
# ------------------------------------------------------------------------------
func _resolve_reverse_and_braking_separation(forward_speed_mps: float) -> void:
	# Transition between Forward and Reverse states near standstill
	if not is_reversing:
		if forward_speed_mps < direction_switch_speed_threshold and brake_input > 0.15 and throttle_input < 0.05:
			is_reversing = true
			current_gear = -1
	else:
		if forward_speed_mps > -direction_switch_speed_threshold and throttle_input > 0.15 and brake_input < 0.05:
			is_reversing = false
			current_gear = 1

	# Strictly isolate throttle torque from brake pad clamping
	if is_reversing:
		current_gear = -1
		active_engine_throttle = brake_input
		# Strictly apply brakes ONLY when throttle_input > 0.0 while moving backward
		if throttle_input > 0.0 and forward_speed_mps < -0.05:
			net_wheel_brake_torque_nm = throttle_input * max_brake_torque_nm
		else:
			net_wheel_brake_torque_nm = 0.0
	else:
		if current_gear < 1:
			current_gear = 1
		active_engine_throttle = throttle_input
		net_wheel_brake_torque_nm = brake_input * max_brake_torque_nm


# ------------------------------------------------------------------------------
# 2. CLOSE-RATIO 6-SPEED TOUGE TRANSMISSION
# ------------------------------------------------------------------------------
func _update_automatic_transmission(delta: float, forward_speed_mps: float) -> void:
	if shift_timer > 0.0:
		shift_timer = maxf(0.0, shift_timer - delta)
		return
	if is_reversing:
		return

	# Detect steep Touge incline to hold lower gears under load
	var forward_vec: Vector3 = -global_transform.basis.z
	var incline_sin: float = clampf(forward_vec.y, -1.0, 1.0)
	var uphill_rpm_hold_offset: float = clampf(incline_sin * 1600.0, 0.0, 600.0)

	var effective_upshift_rpm: float = minf(upshift_rpm + uphill_rpm_hold_offset, redline_rpm - 250.0)
	var effective_downshift_rpm: float = downshift_rpm + (uphill_rpm_hold_offset * 0.65)

	if current_rpm >= effective_upshift_rpm and current_gear < gear_ratios.size():
		# Verify wheel speed supports next gear without lugging below boost threshold
		var next_ratio: float = gear_ratios[current_gear] * final_drive
		var projected_rpm: float = (maxf(forward_speed_mps, 0.0) / maxf(wheel_radius, 0.1)) * next_ratio * 9.5492965855
		if projected_rpm > downshift_rpm + 250.0:
			current_gear += 1
			shift_timer = shift_duration_sec
	elif current_rpm <= effective_downshift_rpm and current_gear > 1:
		current_gear -= 1
		shift_timer = shift_duration_sec * 0.75


# ------------------------------------------------------------------------------
# 3. ENGINE RPM & RB26DETT TWIN-TURBO SPOOL MODEL
# ------------------------------------------------------------------------------
func _update_rpm_and_turbo_spool(delta: float, avg_drive_wheel_omega: float) -> void:
	var active_ratio: float = get_active_gear_ratio() * final_drive
	var wheel_coupled_rpm: float = absf(avg_drive_wheel_omega) * absf(active_ratio) * 9.5492965855

	# Slip clutch below 2600 RPM under heavy load so 1st/2nd gear never bog on 15° inclines
	var launch_assist_rpm: float = idle_rpm + (active_engine_throttle * 2650.0)
	var target_rpm: float = maxf(wheel_coupled_rpm, launch_assist_rpm)

	if shift_timer > 0.0:
		# Slight RPM drop during gear engagement
		target_rpm = lerpf(current_rpm, wheel_coupled_rpm, 0.5)

	var rpm_response_rate: float = 20.0 / maxf(engine_inertia, 0.05)
	current_rpm = lerpf(current_rpm, target_rpm, clampf(delta * rpm_response_rate, 0.0, 1.0))
	current_rpm = clampf(current_rpm, idle_rpm, rev_limiter_cutoff_rpm)

	# --- Twin-Turbo Boost Pressure Accumulation (-0.65 bar to +1.35 bar) ---
	var effective_throttle: float = active_engine_throttle if shift_timer <= 0.0 else 0.15
	var target_boost: float = min_vacuum_bar

	if effective_throttle > 0.08:
		# Bring pressure from vacuum to atmospheric (0.0 bar) with throttle opening
		var atmo_transition: float = lerpf(min_vacuum_bar, 0.0, clampf(effective_throttle * 1.4, 0.0, 1.0))

		if current_rpm >= 2600.0:
			# Primary spool ramp above 3200 RPM, full positive pressure by 4200 RPM
			var exhaust_enthalpy: float = clampf(
				(current_rpm - boost_threshold_rpm) / maxf(full_spool_rpm - boost_threshold_rpm, 100.0),
				-0.25,
				1.0
			)
			var spool_curve: float = smoothstep(-0.25, 1.0, exhaust_enthalpy)
			var positive_boost: float = max_boost_bar * spool_curve * pow(effective_throttle, 1.15)
			target_boost = clampf(atmo_transition + positive_boost, min_vacuum_bar, max_boost_bar)
		else:
			target_boost = atmo_transition

	# Asymmetric rate: exhaust builds turbine speed progressively; BOV vents rapidly on lift
	if target_boost > current_boost_bar:
		var rpm_spool_factor: float = clampf(current_rpm / full_spool_rpm, 0.35, 1.35)
		current_boost_bar = move_toward(current_boost_bar, target_boost, spool_up_rate * rpm_spool_factor * delta)
	else:
		current_boost_bar = move_toward(current_boost_bar, target_boost, bypass_vent_rate * delta)


# ------------------------------------------------------------------------------
# 4. TORQUE CURVE & AXLE FORCE OUTPUT
# ------------------------------------------------------------------------------
func _compute_axle_drive_torque() -> void:
	if shift_timer > 0.0 or current_rpm >= rev_limiter_cutoff_rpm:
		net_drive_axle_torque_nm = 0.0
		return

	# Naturally aspirated base volumetric efficiency curve (0.0 to 1.0)
	var na_ve_factor: float = _evaluate_rb26_base_ve(current_rpm)
	var base_torque: float = base_peak_torque_nm * na_ve_factor

	# Turbo multiplier: authentic off-boost lag (<3000 RPM) -> violent surge (3800-6800 RPM)
	var boost_multiplier: float = 1.0
	if is_reversing:
		# Instant crisp reverse torque without turbo vacuum choking
		boost_multiplier = 1.15
	elif current_boost_bar < 0.0:
		# Off-boost low compression ratio (8.5:1) feel in vacuum
		var vac_ratio: float = clampf(current_boost_bar / absf(min_vacuum_bar), -1.0, 0.0)
		boost_multiplier = lerpf(0.82, 1.0, 1.0 + vac_ratio)
	else:
		var norm_boost: float = clampf(current_boost_bar / maxf(max_boost_bar, 0.01), 0.0, 1.0)
		# Non-linear punch as twin T28 turbines hit peak efficiency island
		var surge_band: float = 1.0
		if current_rpm >= 3800.0 and current_rpm <= 6800.0:
			surge_band = 1.08
		boost_multiplier = lerpf(1.0, max_boost_torque_multiplier * surge_band, pow(norm_boost, 0.88))

	var gross_crank_torque: float = base_torque * boost_multiplier * active_engine_throttle

	# Off-throttle engine compression braking
	var rpm_norm: float = clampf((current_rpm - idle_rpm) / (redline_rpm - idle_rpm), 0.0, 1.0)
	var engine_drag_torque: float = (1.0 - active_engine_throttle) * engine_braking_coeff * rpm_norm

	var net_crank_torque: float = gross_crank_torque - engine_drag_torque
	var total_reduction: float = get_active_gear_ratio() * final_drive

	net_drive_axle_torque_nm = net_crank_torque * total_reduction * drivetrain_efficiency


## Analytical RB26DETT volumetric efficiency curve
func _evaluate_rb26_base_ve(rpm: float) -> float:
	if rpm < 2800.0:
		# Low-end torque floor tuned to prevent stalling while retaining turbo lag character
		return lerpf(0.54, 0.68, clampf((rpm - idle_rpm) / (2800.0 - idle_rpm), 0.0, 1.0))
	elif rpm < 3800.0:
		# Camshaft transition ramp
		return lerpf(0.68, 0.90, (rpm - 2800.0) / 1000.0)
	elif rpm <= 6800.0:
		# Broad RB26 powerband plateau (3800 - 6800 RPM)
		var band_t: float = (rpm - 3800.0) / 3000.0
		return 0.90 + (0.10 * sin(band_t * PI))
	else:
		# High-RPM breathability up to 8200 RPM redline
		var top_t: float = clampf((rpm - 6800.0) / (redline_rpm - 6800.0), 0.0, 1.0)
		return lerpf(0.92, 0.81, top_t)


func get_active_gear_ratio() -> float:
	if is_reversing or current_gear == -1:
		return -absf(reverse_ratio)
	var idx: int = clampi(current_gear - 1, 0, gear_ratios.size() - 1)
	return gear_ratios[idx]

# ----------------------------------------------------------------------------- tires
func _point_velocity(point: Vector3) -> Vector3:
	return linear_velocity + angular_velocity.cross(point - global_position)

func _apply_suspension_and_tires(delta: float) -> void:
	var count := wheel_rays.size()
	var forward := flat_forward()
	var body_up := global_transform.basis.y.normalized()
	var corner_mass := mass / float(count)
	var inv_delta := 1.0 / delta

	var driven_total := 0
	for i in count:
		if _is_driven[i] == 1:
			driven_total += 1
	var drive_per_wheel := _engine_force / float(driven_total) if driven_total > 0 else 0.0

	for i in count:
		_wheel_grounded[i] = 0
		_wheel_force[i] = 0.0
		_wheel_compression[i] = 0.0
		_wheel_distance[i] = ray_length
		var ray := wheel_rays[i]
		if ray == null or not ray.is_colliding():
			continue

		var point := ray.get_collision_point()
		var normal := ray.get_collision_normal()
		var distance := ray.global_position.distance_to(point)
		_wheel_distance[i] = distance
		if distance > ray_length:
			continue

		var compression := clampf(ray_length - distance, 0.0, ray_length - wheel_radius)
		var velocity := _point_velocity(point)
		var down := -ray.global_transform.basis.y.normalized()
		var compression_speed := velocity.dot(down)
		var spring := compression * suspension_stiffness + compression_speed * suspension_damping
		spring = clampf(spring, 0.0, suspension_max_force)

		_wheel_compression[i] = compression
		_wheel_force[i] = spring
		_wheel_grounded[i] = 1
		_wheel_contact[i] = point
		_wheel_normal[i] = normal
		apply_force(body_up * spring, point - global_position)

	_apply_anti_roll(body_up, count)

	for i in count:
		if _wheel_grounded[i] == 0:
			if i < tire_slip_velocities.size():
				wheel_is_grounded[i] = false
				tire_slip_velocities[i] = 0.0
			continue

		var point := _wheel_contact[i]
		var velocity := _point_velocity(point)
		var steer := _wheel_steer[i]
		var wheel_forward := forward.rotated(Vector3.UP, steer).normalized()
		var wheel_right := wheel_forward.cross(Vector3.UP).normalized()
		var load := maxf(_wheel_force[i], 0.0)

		if drift_solver != null:
			var forces: Dictionary = drift_solver.compute_tire_forces(
				i,
				_is_front[i] == 1,
				_is_driven[i] == 1,
				load,
				velocity,
				wheel_forward,
				wheel_right,
				throttle_input if not is_reversing else 0.0,
				brake_input if not is_reversing else throttle_input,
				handbrake_input,
				inv_delta
			)
			apply_force(forces.get("lateral_force", Vector3.ZERO), point - global_position)
			apply_force(forces.get("longitudinal_force", Vector3.ZERO), point - global_position)

			if i < tire_slip_velocities.size():
				wheel_is_grounded[i] = true
				wheel_contact_points[i] = point
				wheel_contact_normals[i] = _wheel_normal[i]
				var s_angle: float = absf(forces.get("slip_angle_rad", 0.0))
				var s_ratio: float = absf(forces.get("slip_ratio", 0.0))
				tire_slip_velocities[i] = s_angle * 18.0 + s_ratio * 12.0
		else:
			var grip := tire_grip
			var locked := handbrake_input > 0.1 and _is_front[i] == 0
			if _is_front[i] == 0:
				grip *= rear_grip_multiplier
				if locked:
					grip *= handbrake_grip_multiplier

			var lateral_speed := velocity.dot(wheel_right)
			var lateral_force := clampf(-lateral_speed * corner_mass * inv_delta * 0.95, -grip * load, grip * load)
			apply_force(wheel_right * lateral_force, point - global_position)

			var longitudinal_speed := velocity.dot(wheel_forward)
			var longitudinal := 0.0
			if _is_driven[i] == 1:
				longitudinal += drive_per_wheel

			var brake_amount := throttle_input if is_reversing else brake_input
			if locked:
				brake_amount = 1.0
			if brake_amount > 0.0:
				var brake_cap := tire_grip * load * brake_amount
				longitudinal += clampf(-longitudinal_speed * corner_mass * inv_delta, -brake_cap, brake_cap)

			if absf(longitudinal_speed) > 0.05:
				longitudinal -= signf(longitudinal_speed) * minf(rolling_resistance, absf(longitudinal_speed) * corner_mass * inv_delta)

			var longitudinal_cap := tire_grip * 1.35 * load
			longitudinal = clampf(longitudinal, -longitudinal_cap, longitudinal_cap)
			apply_force(wheel_forward * longitudinal, point - global_position)

			if i < tire_slip_velocities.size():
				wheel_is_grounded[i] = true
				wheel_contact_points[i] = point
				wheel_contact_normals[i] = _wheel_normal[i]
				var slip := absf(lateral_speed)
				if locked:
					slip += absf(longitudinal_speed) * 0.85
				elif _is_driven[i] == 1 and throttle_input > 0.8 and speed_kmh < 30.0:
					slip += (engine_rpm / redline_rpm) * 12.0
				tire_slip_velocities[i] = slip

func _apply_anti_roll(body_up: Vector3, count: int) -> void:
	var pairs := [[0, 1], [2, 3]]
	for pair in pairs:
		var left: int = pair[0]
		var right: int = pair[1]
		if left >= count or right >= count:
			continue
		if _wheel_grounded[left] == 0 and _wheel_grounded[right] == 0:
			continue
		var difference := _wheel_compression[left] - _wheel_compression[right]
		var force := clampf(difference * anti_roll_stiffness, -suspension_max_force, suspension_max_force)
		if _wheel_grounded[left] == 1:
			apply_force(body_up * force, _wheel_contact[left] - global_position)
			_wheel_force[left] = maxf(_wheel_force[left] + force, 0.0)
		if _wheel_grounded[right] == 1:
			apply_force(body_up * -force, _wheel_contact[right] - global_position)
			_wheel_force[right] = maxf(_wheel_force[right] - force, 0.0)

func _apply_aero() -> void:
	var velocity := linear_velocity
	var speed := velocity.length()
	if speed < 0.5:
		return
	var up := global_transform.basis.y.normalized()
	apply_central_force(-velocity / speed * drag_coefficient * speed * speed)
	apply_central_force(-up * downforce_coefficient * speed * speed)

func _apply_chassis_stabilization(_delta: float) -> void:
	if drift_solver != null and drift_solver.has_method("compute_chassis_stabilization_torque"):
		var is_drift: bool = false
		if drift_solver.has_method("get_drift_telemetry"):
			var telem: Dictionary = drift_solver.get_drift_telemetry()
			is_drift = bool(telem.get("is_drifting", false))
		var stab_torque: Vector3 = drift_solver.compute_chassis_stabilization_torque(
			global_transform.basis,
			linear_velocity,
			angular_velocity,
			steer_input,
			is_drift
		)
		apply_torque(stab_torque * (mass * 1.5))

# ----------------------------------------------------------------------------- visuals
func _update_wheel_visuals(delta: float) -> void:
	var count := mini(wheel_meshes.size(), _wheel_distance.size())
	for i in count:
		var mesh := wheel_meshes[i]
		var ray := wheel_rays[i]
		if mesh == null or ray == null:
			continue

		var wheel_y := -(ray_length - wheel_radius)
		if _wheel_grounded[i] == 1:
			wheel_y = -(_wheel_distance[i] - wheel_radius)
			var wheel_forward := (-ray.global_transform.basis.z).rotated(Vector3.UP, _wheel_steer[i]).normalized()
			var long_speed := _point_velocity(_wheel_contact[i]).dot(wheel_forward)
			if not (handbrake_input > 0.1 and _is_front[i] == 0):
				_wheel_spin[i] -= long_speed / wheel_radius * delta
		else:
			_wheel_spin[i] -= forward_speed / wheel_radius * delta

		if _wheel_spin[i] > TAU or _wheel_spin[i] < -TAU:
			_wheel_spin[i] = fposmod(_wheel_spin[i], TAU)

		var steer_basis := Basis(Vector3.UP, _wheel_steer[i])
		var spin_basis := Basis(Vector3.RIGHT, _wheel_spin[i])
		var wheel_basis: Basis
		if r34_model != null:
			wheel_basis = steer_basis * spin_basis
		else:
			var tip_basis := Basis(Vector3.BACK, PI * 0.5)
			wheel_basis = steer_basis * spin_basis * tip_basis
		mesh.transform = Transform3D(wheel_basis, Vector3(ray.position.x, ray.position.y + wheel_y, ray.position.z))

# ----------------------------------------------------------------------------- recovery
func _check_recovery(delta: float) -> void:
	if global_position.y < -30.0:
		respawn()
		return
	var upright := global_transform.basis.y.dot(Vector3.UP)
	if upright < 0.25 and linear_velocity.length() < 3.0:
		_flip_timer += delta
	else:
		_flip_timer = 0.0
	if _flip_timer > 2.0:
		respawn()

## Teleports the car back to the pose it was spawned with and clears all motion.
func respawn() -> void:
	respawn_at(_spawn_transform)

## Teleports the car to [param target] and clears all motion.
func respawn_at(target: Transform3D) -> void:
	global_transform = target
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, target)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	steer_angle = 0.0
	throttle_input = 0.0
	brake_input = 0.0
	handbrake_input = 0.0
	current_gear = 1
	gear_number = 1
	current_rpm = idle_rpm
	engine_rpm = idle_rpm
	current_boost_bar = min_vacuum_bar
	shift_timer = 0.0
	_flip_timer = 0.0
	_engine_force = 0.0
	net_drive_axle_torque_nm = 0.0
	net_wheel_brake_torque_nm = 0.0
	is_reversing = false
	_wheel_spin.fill(0.0)

## Marks [param target] as the pose [method respawn] returns to.
func set_spawn_transform(target: Transform3D) -> void:
	_spawn_transform = target
