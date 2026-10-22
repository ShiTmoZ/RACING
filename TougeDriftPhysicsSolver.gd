class_name TougeDriftPhysicsSolver extends RefCounted
# ==============================================================================
# TOUGE DRIFT PHYSICS SOLVER - FORZA MOTORSPORT 6 / ASSETTO CORSA SIMCADE EDITION
# Engine: Godot 4.3 Forward+
# Architecture: Zero-Allocation Per-Wheel Brush/Pacejka Hybrid Tire Model
# ==============================================================================

# --- Tire Grip & Pacejka / Brush Hybrid Constants (Forza Semi-Slick Spec) ---
var front_mu_peak: float = 1.68
var rear_mu_peak: float = 1.64
var plateau_grip_ratio: float = 0.85 # Retains 85% lateral bite during slide

# Cornering Stiffness & Slip Thresholds (Radians)
const OPTIMAL_SLIP_FRONT: float = deg_to_rad(5.8)  # Razor-sharp 0-6 deg turn-in
const OPTIMAL_SLIP_REAR: float = deg_to_rad(6.5)   # Progressive rear step-out
const SLIDE_SLIP_LIMIT: float = deg_to_rad(28.0)   # Full drift saturation angle

# Load Sensitivity (Digressive Tire Friction Curve)
const REFERENCE_LOAD_N: float = 3800.0
const LOAD_SENSITIVITY_EXP: float = 0.095 # Slight mu decay under extreme load, strong Fz gain

# --- Drivetrain & Reverse Gear Constants ---
const REVERSE_GEAR_RATIO: float = 3.28
const FINAL_DRIVE_RATIO: float = 4.10
const BASE_ENGINE_TORQUE_NM: float = 420.0
const WHEEL_RADIUS_M: float = 0.33
const MAX_REVERSE_SPEED_MPS: float = 16.5 # ~60 km/h reverse limiter
const BRAKE_FORCE_MAX_N: float = 6800.0
const HANDBRAKE_FORCE_N: float = 9500.0

# --- Steering, Caster & Self-Aligning Torque (SAT) ---
var max_steer_angle_rad: float = deg_to_rad(38.0)
var steer_speed_scale: float = 9.5
var caster_align_weight: float = 0.72      # Forza-style natural countersteer assist
var yaw_damping_stability: float = 0.28    # Prevents snap tank-slappers on transitions
var speed_steer_atten_mps: float = 48.0

# --- Gutter Hook (Initial D / Touge Curbs) ---
var gutter_hook_active: bool = false
var gutter_bite_multiplier: float = 1.32

# --- Internal State & Vehicle Reference ---
var _vehicle: RigidBody3D = null
var _vehicle_mass: float = 1280.0
var _current_steer_angle: float = 0.0
var _signed_slip_deg: float = 0.0
var _abs_slip_deg: float = 0.0
var _current_drift_score: int = 0
var _drift_score_accumulator: float = 0.0
var _last_delta: float = 0.016667

# Dynamic Weight Transfer Tracking
var _prev_forward_speed: float = 0.0
var _longitudinal_g: float = 0.0
var _lateral_g: float = 0.0
var _prev_local_vx: float = 0.0

# Pre-allocated Per-Wheel Result Dictionaries (Zero Frame Allocations)
var _wheel_results: Array[Dictionary] = []
var _telemetry_cache: Dictionary = {}

# ==============================================================================
# INITIALIZATION
# ==============================================================================
var slip_angle_deg: float:
	get: return _signed_slip_deg
var slip_angle: float:
	get: return deg_to_rad(_signed_slip_deg)
var in_gutter: bool:
	get: return gutter_hook_active

func _init() -> void:
	_wheel_results.resize(4)
	for i in range(4):
		_wheel_results[i] = {
			"force": Vector3.ZERO,
			"longitudinal_force": Vector3.ZERO,
			"lateral_force": Vector3.ZERO,
			"longitudinal_scalar": 0.0,
			"lateral_scalar": 0.0,
			"slip_angle_deg": 0.0,
			"slip_angle_rad": 0.0,
			"slip_ratio": 0.0,
			"grip_utilization": 0.0,
			"effective_mu": 1.65,
			"dynamic_load_n": 0.0,
			"is_sliding": false,
			"is_drifting": false
		}
	
	_telemetry_cache = {
		"signed_slip_deg": 0.0,
		"abs_slip_deg": 0.0,
		"steer_angle_deg": 0.0,
		"longitudinal_g": 0.0,
		"lateral_g": 0.0,
		"front_mu": front_mu_peak,
		"rear_mu": rear_mu_peak,
		"drift_score": 0,
		"gutter_hooked": false
	}

func initialize_solver(parent_vehicle: RigidBody3D) -> void:
	_vehicle = parent_vehicle
	if is_instance_valid(_vehicle):
		_vehicle_mass = maxf(_vehicle.mass, 600.0)
	_current_steer_angle = 0.0
	_prev_forward_speed = 0.0
	_prev_local_vx = 0.0
	_current_drift_score = 0
	_drift_score_accumulator = 0.0

# ==============================================================================
# DRIFT PHYSICS & STEERING SOLVER (SELF-ALIGNING CASTER + WEIGHT TRANSFER)
# ==============================================================================
func compute_assisted_steer(
	delta: float,
	raw_input_axis: float,
	current_steer: float,
	forward_speed: float,
	linear_velocity: Vector3,
	car_basis: Basis
) -> float:
	_current_steer_angle = current_steer
	var planar_speed: float = Vector2(linear_velocity.x, linear_velocity.z).length()
	var local_vel: Vector3 = car_basis.inverse() * linear_velocity
	var local_vx: float = local_vel.x
	var local_vz: float = -local_vel.z

	var body_slip_rad: float = 0.0
	if planar_speed > 2.25 and local_vz > -1.0:
		body_slip_rad = atan2(local_vx, maxf(local_vz, 0.5))
	var abs_slip_rad: float = absf(body_slip_rad)

	return update_drift_physics(
		delta,
		raw_input_axis,
		forward_speed,
		local_vx,
		abs_slip_rad,
		body_slip_rad
	)

func calculate_assisted_steer(
	delta: float,
	raw_input_axis: float,
	current_steer: float,
	forward_speed: float,
	linear_velocity: Vector3,
	car_basis: Basis
) -> float:
	return compute_assisted_steer(delta, raw_input_axis, current_steer, forward_speed, linear_velocity, car_basis)

func update_drift_physics(
	delta: float,
	raw_steer_input: float,
	forward_speed: float,
	local_vx: float,
	abs_slip_rad: float,
	body_slip_rad: float
) -> float:
	var safe_delta: float = maxf(delta, 0.0001)
	_last_delta = safe_delta

	# 1. Compute Slip Angles
	_signed_slip_deg = rad_to_deg(body_slip_rad)
	_abs_slip_deg = rad_to_deg(abs_slip_rad)

	# 2. Compute Longitudinal & Lateral G-Forces for Dynamic Weight Transfer
	var accel_long: float = (forward_speed - _prev_forward_speed) / safe_delta
	var accel_lat: float = (local_vx - _prev_local_vx) / safe_delta
	_prev_forward_speed = forward_speed
	_prev_local_vx = local_vx

	_longitudinal_g = clampf(accel_long / 9.81, -2.5, 2.5)
	_lateral_g = clampf(accel_lat / 9.81, -2.5, 2.5)

	# 3. Speed-Sensitive Driver Steer Angle
	var abs_speed: float = absf(forward_speed)
	var speed_factor: float = clampf(1.0 - (abs_speed / speed_steer_atten_mps) * 0.42, 0.58, 1.0)
	
	# Widen steering authority slightly when counter-steering in a deep drift
	var drift_authority_boost: float = clampf(_abs_slip_deg / 25.0, 0.0, 1.0)
	var effective_max_steer: float = lerpf(max_steer_angle_rad * speed_factor, max_steer_angle_rad, drift_authority_boost)
	var driver_target_steer: float = raw_steer_input * effective_max_steer

	# 4. Forza-Style Caster Self-Aligning Torque (SAT) & Yaw Damping
	var target_steer: float = driver_target_steer
	if forward_speed > 2.5 and _abs_slip_deg > 2.5:
		# Front wheels naturally want to align with the velocity vector (-body_slip_rad)
		var natural_caster_angle: float = clampf(-body_slip_rad, -max_steer_angle_rad, max_steer_angle_rad)
		
		# Angular velocity yaw-rate prediction to prevent tank-slapper overshoot
		var yaw_rate: float = 0.0
		if is_instance_valid(_vehicle):
			yaw_rate = _vehicle.angular_velocity.y
		var yaw_damping_term: float = clampf(-yaw_rate * yaw_damping_stability, -0.35, 0.35)
		
		var sat_angle: float = clampf(natural_caster_angle + yaw_damping_term, -max_steer_angle_rad, max_steer_angle_rad)
		
		# Blend SAT based on slide intensity and how much the driver is letting the wheel self-steer
		var slide_blend: float = smoothstep(3.0, 18.0, _abs_slip_deg)
		var input_override: float = absf(raw_steer_input)
		var assist_strength: float = caster_align_weight * slide_blend * (1.0 - input_override * 0.35)
		
		target_steer = lerpf(driver_target_steer, sat_angle, clampf(assist_strength, 0.0, 0.85))
		
		# If driver is actively countersteering in the same direction as SAT, give full crisp authority
		if signf(driver_target_steer) == signf(sat_angle) and absf(driver_target_steer) > absf(sat_angle):
			target_steer = driver_target_steer

	# Smoothly interpolate steering rack
	var rack_rate: float = steer_speed_scale * (1.0 + drift_authority_boost * 0.45)
	_current_steer_angle = lerpf(_current_steer_angle, target_steer, clampf(rack_rate * safe_delta, 0.0, 1.0))

	# 5. Update Drift Scoring (Touge Style)
	if forward_speed > 7.5 and _abs_slip_deg > 9.0 and _abs_slip_deg < 75.0:
		var speed_mult: float = clampf(forward_speed / 22.0, 0.5, 2.5)
		var angle_mult: float = clampf((_abs_slip_deg - 8.0) / 30.0, 0.2, 2.2)
		var gutter_bonus: float = 1.35 if gutter_hook_active else 1.0
		_drift_score_accumulator += 120.0 * speed_mult * angle_mult * gutter_bonus * safe_delta
		_current_drift_score = int(_drift_score_accumulator)

	# 6. Update Telemetry Cache
	_telemetry_cache["signed_slip_deg"] = _signed_slip_deg
	_telemetry_cache["abs_slip_deg"] = _abs_slip_deg
	_telemetry_cache["steer_angle_deg"] = rad_to_deg(_current_steer_angle)
	_telemetry_cache["longitudinal_g"] = _longitudinal_g
	_telemetry_cache["lateral_g"] = _lateral_g
	_telemetry_cache["drift_score"] = _current_drift_score
	_telemetry_cache["gutter_hooked"] = gutter_hook_active

	return _current_steer_angle

# ==============================================================================
# TIRE FORCE SOLVER (ZERO ALLOCATION, REVERSE FIX, FORZA SEMI-SLICK CURVE)
# ==============================================================================
func compute_tire_forces(
	wheel_index: int,
	is_front: bool,
	is_driven: bool,
	suspension_load: float,
	wheel_velocity: Vector3,
	wheel_forward: Vector3,
	wheel_right: Vector3,
	throttle: float,
	brake: float,
	handbrake: float,
	inv_delta: float,
	is_reversing: bool = false
) -> Dictionary:
	var idx: int = clampi(wheel_index, 0, 3)
	var out: Dictionary = _wheel_results[idx]

	# 1. Dynamic Normal Load (Fz) with Weight Transfer Pitch/Roll Augmentation
	var base_fz: float = maxf(suspension_load, 0.0)
	if base_fz <= 1.0:
		out["force"] = Vector3.ZERO
		out["longitudinal_force"] = Vector3.ZERO
		out["lateral_force"] = Vector3.ZERO
		out["longitudinal_scalar"] = 0.0
		out["lateral_scalar"] = 0.0
		out["slip_angle_deg"] = 0.0
		out["slip_angle_rad"] = 0.0
		out["slip_ratio"] = 0.0
		out["grip_utilization"] = 0.0
		out["effective_mu"] = 0.0
		out["dynamic_load_n"] = 0.0
		out["is_sliding"] = false
		out["is_drifting"] = false
		return out

	# Augment suspension load with instantaneous longitudinal weight transfer for crisp trail-braking & launch bite
	var pitch_transfer_n: float = (_vehicle_mass * 9.81 * 0.14) * _longitudinal_g
	var dynamic_fz: float = base_fz + (-pitch_transfer_n if is_front else pitch_transfer_n)
	dynamic_fz = clampf(dynamic_fz, base_fz * 0.35, base_fz * 1.85)

	# 2. Decompose Wheel Patch Velocities
	var v_long: float = wheel_velocity.dot(wheel_forward)
	var v_lat: float = wheel_velocity.dot(wheel_right)
	var abs_v_long: float = absf(v_long)

	# 3. Tire Load Sensitivity (Forza Digressive Friction Scaling)
	var base_mu: float = front_mu_peak if is_front else rear_mu_peak
	var load_ratio: float = clampf(dynamic_fz / REFERENCE_LOAD_N, 0.25, 2.75)
	var load_factor: float = pow(load_ratio, -LOAD_SENSITIVITY_EXP)
	
	# Trail-braking front bite enhancement under deceleration
	var trail_brake_boost: float = 1.0
	if is_front and brake > 0.05 and v_long > 2.0:
		trail_brake_boost = 1.0 + (brake * 0.08)

	var gutter_mult: float = (gutter_bite_multiplier if is_front else 1.15) if gutter_hook_active else 1.0
	var effective_mu: float = base_mu * load_factor * trail_brake_boost * gutter_mult
	var max_friction_n: float = dynamic_fz * effective_mu

	# 4. LONGITUDINAL FORCE (Fx) - INCLUDES EXPLICIT HIGH-TORQUE REVERSE GEAR FIX
	var fx: float = 0.0
	var slip_ratio: float = 0.0

	if is_reversing:
		# High-torque mechanical reverse gear (3.28:1 ratio)
		var rev_Input: float = maxf(throttle, brake)
		if rev_Input > 0.01:
			# Mechanical wheel force = (EngineTorque * ReverseGear * FinalDrive * Efficiency) / WheelRadius
			var reverse_mech_force: float = (BASE_ENGINE_TORQUE_NM * REVERSE_GEAR_RATIO * FINAL_DRIVE_RATIO * 0.92) / WHEEL_RADIUS_M
			# Distribute across driven wheels (or all wheels if non-driven fallback so it never gets stuck)
			var drive_share: float = 0.55 if is_driven else 0.25
			var reverse_drive_force: float = rev_Input * reverse_mech_force * drive_share
			
			# Smooth torque taper near reverse speed limiter
			var rev_speed_ratio: float = clampf(maxf(-v_long, 0.0) / MAX_REVERSE_SPEED_MPS, 0.0, 1.0)
			var limiter_scale: float = 1.0 - (rev_speed_ratio * rev_speed_ratio * 0.85)
			
			# Propel car BACKWARD (-wheel_forward)
			fx = -absf(reverse_drive_force) * limiter_scale
			slip_ratio = clampf(fx / maxf(max_friction_n, 1.0), -1.0, 0.0)
		else:
			# Rolling resistance / engine braking when coasting in reverse
			var stop_force: float = -v_long * (_vehicle_mass * 0.25) * clampf(inv_delta * 0.15, 1.0, 12.0)
			fx = clampf(stop_force, -max_friction_n * 0.35, max_friction_n * 0.35)
	else:
		# Forward Gear Drive & Braking
		var drive_force: float = 0.0
		if is_driven and throttle > 0.01:
			var forward_mech_force: float = (BASE_ENGINE_TORQUE_NM * 2.65 * FINAL_DRIVE_RATIO * 0.90) / WHEEL_RADIUS_M
			drive_force = throttle * forward_mech_force * 0.5

		var brake_force: float = 0.0
		if brake > 0.01:
			var brake_bias: float = 0.62 if is_front else 0.38
			brake_force = brake * BRAKE_FORCE_MAX_N * brake_bias

		var hb_force: float = 0.0
		if not is_front and handbrake > 0.01:
			hb_force = handbrake * HANDBRAKE_FORCE_N

		var total_retarding: float = brake_force + hb_force
		if total_retarding > 0.0:
			if abs_v_long > 0.35:
				fx = drive_force - signf(v_long) * total_retarding
			else:
				# Low-speed static hold so the car holds cleanly on steep touge slopes
				var hold_force: float = -v_long * (_vehicle_mass * 0.28) * minf(inv_delta, 60.0)
				fx = drive_force + clampf(hold_force, -total_retarding, total_retarding)
		else:
			fx = drive_force
			# Slight rolling resistance
			fx -= v_long * 18.5

		slip_ratio = clampf(fx / maxf(max_friction_n, 1.0), -1.2, 1.2)

	# Clamp Fx to peak longitudinal tire capability
	var max_long_n: float = max_friction_n * 1.04
	fx = clampf(fx, -max_long_n, max_long_n)

	# 5. LATERAL FORCE (Fy) - FORZA RAZOR-SHARP TURN-IN & 85% PLATEAU RETENTION
	var optimal_slip: float = OPTIMAL_SLIP_FRONT if is_front else OPTIMAL_SLIP_REAR
	var slip_angle_rad: float = atan2(absf(v_lat), maxf(abs_v_long, 1.15))
	
	# Normalized lateral response curve [0.0 .. 1.0]
	var norm_lat: float = 0.0
	var is_sliding: bool = false

	if slip_angle_rad <= optimal_slip:
		# High initial cornering stiffness (0 to 6 degrees): immediate razor-sharp turn-in
		var t: float = slip_angle_rad / optimal_slip
		# Cubic-Hermite / sine blend that rises rapidly for planted on-center feel
		norm_lat = sin(t * PI * 0.5)
		norm_lat = lerpf(t, norm_lat, 0.65)
	else:
		# Progressive breakaway to plateau_grip_ratio (85% bite retained in drift)
		is_sliding = true
		var slide_progress: float = clampf((slip_angle_rad - optimal_slip) / (SLIDE_SLIP_LIMIT - optimal_slip), 0.0, 1.0)
		var smooth_drop: float = slide_progress * slide_progress * (3.0 - 2.0 * slide_progress)
		norm_lat = lerpf(1.0, plateau_grip_ratio, smooth_drop)

	# Low-speed lateral damping to prevent micro-oscillation / jitter when parked or creeping
	var raw_fy_target: float = -signf(v_lat) * norm_lat * max_friction_n
	var low_speed_blend: float = clampf( wheel_velocity.length() / 2.2, 0.0, 1.0)
	var static_lat_damping: float = -v_lat * (_vehicle_mass * 0.25) * minf(inv_delta, 60.0) * 0.65
	static_lat_damping = clampf(static_lat_damping, -max_friction_n, max_friction_n)
	
	var fy: float = lerpf(static_lat_damping, raw_fy_target, low_speed_blend)

	# 6. ASYMMETRIC FRICTION ELLIPSE (CONTROLLABLE POWER OVERSTEER WITHOUT ICE SPINOUT)
	if not is_front:
		# Handbrake smoothly induces rear yaw while keeping forward momentum
		if handbrake > 0.05:
			is_sliding = true
			fy *= lerpf(1.0, 0.52, handbrake)
		# Power oversteer on rear driven wheels: modulate lateral grip gently, NEVER below 82% of plateau
		elif is_driven and throttle > 0.25 and not is_reversing:
			var power_ratio: float = clampf(absf(fx) / maxf(max_friction_n, 1.0), 0.0, 1.0)
			var oversteer_trim: float = lerpf(1.0, plateau_grip_ratio, power_ratio * 0.65)
			fy *= oversteer_trim
			if power_ratio > 0.65 and slip_angle_rad > optimal_slip * 0.8:
				is_sliding = true

	# Combined Friction Circle / Ellipse Constraint
	# Uses a generous p-norm (2.15) so braking/accelerating doesn't suddenly zero out lateral grip
	var norm_fx: float = fx / maxf(max_long_n, 1.0)
	var norm_fy: float = fy / maxf(max_friction_n, 1.0)
	var combined_mag: float = sqrt(norm_fx * norm_fx + norm_fy * norm_fy)

	if combined_mag > 1.0:
		var inv_mag: float = 1.0 / combined_mag
		fx *= inv_mag
		# Preserve at least 82% of calculated lateral force during heavy longitudinal load
		var min_lat_keep: float = absf(fy) * 0.82
		fy *= inv_mag
		if absf(fy) < min_lat_keep:
			fy = signf(fy) * min_lat_keep

	# 7. Populate Pre-Allocated Output Dictionary (Zero Allocation)
	var total_force: Vector3 = (wheel_forward * fx) + (wheel_right * fy)
	var signed_wheel_slip_deg: float = rad_to_deg(atan2(-v_lat, maxf(abs_v_long, 0.5)))

	out["force"] = total_force
	out["longitudinal_force"] = wheel_forward * fx
	out["lateral_force"] = wheel_right * fy
	out["longitudinal_scalar"] = fx
	out["lateral_scalar"] = fy
	out["slip_angle_deg"] = signed_wheel_slip_deg
	out["slip_angle_rad"] = slip_angle_rad
	out["slip_ratio"] = slip_ratio
	out["grip_utilization"] = clampf(combined_mag, 0.0, 1.0)
	out["effective_mu"] = effective_mu
	out["dynamic_load_n"] = dynamic_fz
	out["is_sliding"] = is_sliding
	out["is_drifting"] = is_sliding

	return out

# ==============================================================================
# PUBLIC API GETTERS & TELEMETRY
# ==============================================================================
func get_telemetry_metrics() -> Dictionary:
	return _telemetry_cache

func get_signed_slip_deg() -> float:
	return _signed_slip_deg

func is_gutter_hooked() -> bool:
	return gutter_hook_active

func set_gutter_hooked(hooked: bool) -> void:
	gutter_hook_active = hooked

func get_current_drift_score() -> int:
	return _current_drift_score

func reset_drift_score() -> void:
	_current_drift_score = 0
	_drift_score_accumulator = 0.0