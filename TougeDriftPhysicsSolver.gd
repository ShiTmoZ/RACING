class_name TougeDriftPhysicsSolver
extends RefCounted

# ==============================================================================
# ShiTmoZ/RACING - Touge Drift & Simcade Vehicle Dynamics Solver (Godot 4.3)
# ==============================================================================
# Engineered for RWD/FR Touge machines (AE86, FD3S, S13).
# Implements:
#   1. Dynamic Slip-Angle Counter-Steer Lock Expansion & Caster Trail Assist
#   2. Anti-Snapback Tank-Slapper Damping (Kansei Flick / Choku-Dori stability)
#   3. Simplified Pacejka "Magic Formula" Non-Linear Lateral Slip Curve
#   4. Kamm's Friction Circle with Throttle-Induced Power-Oversteer
#   5. Progressive Handbrake Lockup & Rear Slip Plateau
# ==============================================================================

# --- STEERING & CASTER ASSIST TUNING ---
var base_max_steer_rad: float = deg_to_rad(28.0)
var high_speed_min_steer_rad: float = deg_to_rad(13.0)
var drift_max_steer_rad: float = deg_to_rad(42.0) # 0.733 rad

var speed_steer_decay_rate: float = 0.022
var drift_angle_threshold_rad: float = deg_to_rad(8.0)
var max_drift_angle_ref_rad: float = deg_to_rad(45.0)

var caster_align_weight: float = 0.72
var steer_response_speed: float = 9.5
var counter_steer_response_speed: float = 16.5
var anti_snapback_damping: float = 0.45

# --- TIRE & PACEJKA SLIP CURVE TUNING ---
var front_mu_peak: float = 1.32
var rear_mu_peak: float = 1.26

var peak_slip_angle_rad: float = deg_to_rad(9.0)
var plateau_slip_angle_rad: float = deg_to_rad(22.0)
var extreme_slip_angle_rad: float = deg_to_rad(55.0)

# Ratio of peak friction retained during deep drift plateau (Forza/Initial D sweet spot)
var front_plateau_grip_ratio: float = 0.88
var rear_plateau_grip_ratio: float = 0.79

# --- POWERTRAIN & KAMM CIRCLE TUNING ---
var max_drive_force_per_wheel: float = 4600.0
var max_brake_force_per_wheel: float = 5200.0
var handbrake_force_per_wheel: float = 6000.0

var power_oversteer_authority: float = 0.42
var handbrake_lateral_retention: float = 0.34
var tire_relaxation_length: float = 0.18

# --- INTERNAL STATE ---
var _prev_slip_angle_rad: float = 0.0
var _body_slip_rate: float = 0.0
var _handbrake_engagement: float = 0.0
var _wheel_smoothed_lat_slip: Array[float] = [0.0, 0.0, 0.0, 0.0]

# --- TELEMETRY STATE ---
var _telemetry_slip_deg: float = 0.0
var _telemetry_speed_kmh: float = 0.0
var _telemetry_drift_quality: float = 0.0
var _telemetry_is_drifting: bool = false


func _init() -> void:
	_wheel_smoothed_lat_slip.resize(8)
	_wheel_smoothed_lat_slip.fill(0.0)


# ==============================================================================
# 1. DYNAMIC COUNTER-STEER LOCK & CASTER TRAIL ASSIST
# ==============================================================================
func compute_assisted_steer(
	delta: float,
	raw_input_axis: float,
	current_steer: float,
	forward_speed: float,
	linear_velocity: Vector3,
	car_basis: Basis
) -> float:
	var clamped_input: float = clampf(raw_input_axis, -1.0, 1.0)
	var planar_speed: float = Vector2(linear_velocity.x, linear_velocity.z).length()
	_telemetry_speed_kmh = planar_speed * 3.6

	# Transform world velocity into vehicle local frame (-Z is forward, +X is right)
	var local_vel: Vector3 = car_basis.inverse() * linear_velocity
	var local_vx: float = local_vel.x
	var local_vz: float = -local_vel.z

	# Calculate vehicle chassis slip angle Beta: atan2(local_vx, -local_vz)
	var body_slip_rad: float = 0.0
	if planar_speed > 2.25 and local_vz > -1.0:
		body_slip_rad = atan2(local_vx, maxf(local_vz, 0.5))

	var abs_slip_rad: float = absf(body_slip_rad)
	_telemetry_slip_deg = rad_to_deg(abs_slip_rad)

	# Compute slip angular velocity for anti-snapback (Choku-Dori / tank-slapper damping)
	var raw_slip_rate: float = (body_slip_rad - _prev_slip_angle_rad) / maxf(delta, 0.0001)
	_body_slip_rate = lerpf(_body_slip_rate, raw_slip_rate, clampf(delta * 15.0, 0.0, 1.0))
	_prev_slip_angle_rad = body_slip_rad

	# Calculate drift transition factor [0.0 = pure grip, 1.0 = full drift mode]
	var drift_blend: float = 0.0
	if planar_speed > 3.5 and abs_slip_rad > drift_angle_threshold_rad:
		drift_blend = clampf(
			(abs_slip_rad - drift_angle_threshold_rad) / (max_drift_angle_ref_rad - drift_angle_threshold_rad),
			0.0,
			1.0
		)
		# Smoothstep for organic feel
		drift_blend = drift_blend * drift_blend * (3.0 - 2.0 * drift_blend)

	_telemetry_is_drifting = drift_blend > 0.08 and planar_speed > 5.0

	# Speed-sensitive grip steering limit vs expanded 42-deg drift lock
	var speed_factor: float = clampf(absf(forward_speed) * speed_steer_decay_rate, 0.0, 1.0)
	var grip_steer_limit: float = lerpf(base_max_steer_rad, high_speed_min_steer_rad, speed_factor)
	var active_max_steer: float = lerpf(grip_steer_limit, drift_max_steer_rad, drift_blend)

	# Driver command target angle
	# Convention: raw_input_axis > 0 is Left/+Steer or Right/+Steer depending on setup;
	# We align caster counter-steer with standard Godot VehicleBody3D where steer_angle
	# opposes local_vx when counter-steering into a slide.
	var player_target_steer: float = clamped_input * active_max_steer

	# Caster Self-Aligning Torque (aligns front wheels with velocity vector)
	# Note: When rear slides right (local_vx < 0), nose points right, velocity vector is to the left
	var caster_target_steer: float = clampf(-body_slip_rad, -drift_max_steer_rad, drift_max_steer_rad)

	# Anti-snapback damping: when slip angle is rapidly collapsing toward zero,
	# lead the steering unwinding to prevent over-correction tank-slappers
	var snapback_damping_angle: float = 0.0
	var is_unwinding: bool = (body_slip_rad * _body_slip_rate) < 0.0
	if is_unwinding and abs_slip_rad > deg_to_rad(4.0):
		snapback_damping_angle = clampf(
			-_body_slip_rate * anti_snapback_damping * 0.12,
			-deg_to_rad(18.0),
			deg_to_rad(18.0)
		)

	caster_target_steer = clampf(
		caster_target_steer + snapback_damping_angle,
		-drift_max_steer_rad,
		drift_max_steer_rad
	)

	# Blend player input with Caster Self-Aligning assist
	# If player pushes strongly into the counter-steer or straightens out, give player full authority;
	# If player feathers or releases stick/keys during slide, caster catches the drift naturally.
	var input_override: float = absf(clamped_input)
	var effective_caster_weight: float = drift_blend * caster_align_weight * (1.0 - 0.55 * input_override)

	var combined_target_steer: float = lerpf(
		player_target_steer,
		caster_target_steer + (player_target_steer * 0.45),
		effective_caster_weight
	)
	combined_target_steer = clampf(combined_target_steer, -active_max_steer, active_max_steer)

	# Dynamic steering rack slew rate (faster when catching a slide or unwinding)
	var active_slew_rate: float = lerpf(steer_response_speed, counter_steer_response_speed, drift_blend)
	var steer_step: float = 1.0 - exp(-active_slew_rate * delta)

	# Update drift quality telemetry (sweet spot between 15° and 38°)
	if _telemetry_is_drifting:
		var sweet_spot_dist: float = absf(_telemetry_slip_deg - 26.0) / 22.0
		var speed_bonus: float = clampf(_telemetry_speed_kmh / 110.0, 0.2, 1.2)
		_telemetry_drift_quality = clampf((1.0 - sweet_spot_dist * 0.65) * speed_bonus * 100.0, 0.0, 100.0)
	else:
		_telemetry_drift_quality = lerpf(_telemetry_drift_quality, 0.0, clampf(delta * 5.0, 0.0, 1.0))

	return lerpf(current_steer, combined_target_steer, steer_step)


# ==============================================================================
# 2. PACEJKA SLIP CURVE, KAMM'S CIRCLE & POWER-OVERSTEER TIRE SOLVER
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
	inv_delta: float
) -> Dictionary:
	var dt: float = 1.0 / maxf(inv_delta, 1.0)
	var safe_idx: int = clampi(wheel_index, 0, _wheel_smoothed_lat_slip.size() - 1)

	# If wheel is airborne or unloaded, return zero forces
	if suspension_load <= 1.0:
		_wheel_smoothed_lat_slip[safe_idx] = 0.0
		return {
			"lateral_force": Vector3.ZERO,
			"longitudinal_force": Vector3.ZERO,
			"slip_ratio": 0.0,
			"slip_angle_rad": 0.0,
			"is_drifting": false
		}

	var fwd_dir: Vector3 = wheel_forward.normalized()
	var right_dir: Vector3 = wheel_right.normalized()

	var v_long: float = wheel_velocity.dot(fwd_dir)
	var v_lat: float = wheel_velocity.dot(right_dir)
	var abs_v_long: float = absf(v_long)
	var planar_speed: float = sqrt(v_long * v_long + v_lat * v_lat)

	# 1. Compute Tire Slip Angle (alpha) with low-speed numerical stabilization
	var raw_slip_angle: float = 0.0
	if planar_speed > 0.4:
		var denom: float = maxf(abs_v_long, 1.35)
		raw_slip_angle = atan2(-v_lat, denom)

	# Tire carcass relaxation smoothing (prevents high-frequency physics jitter at low speed)
	var relax_blend: float = clampf((planar_speed * dt) / maxf(tire_relaxation_length, 0.05), 0.25, 1.0)
	var slip_angle_rad: float = lerpf(_wheel_smoothed_lat_slip[safe_idx], raw_slip_angle, relax_blend)
	_wheel_smoothed_lat_slip[safe_idx] = slip_angle_rad
	var abs_slip_angle: float = absf(slip_angle_rad)

	# 2. Progressive Handbrake State (Rear wheels only)
	var hb_input: float = clampf(handbrake, 0.0, 1.0) if not is_front else 0.0
	var hb_rate: float = 14.0 if hb_input > _handbrake_engagement else 7.5
	if not is_front:
		_handbrake_engagement = move_toward(_handbrake_engagement, hb_input, dt * hb_rate)
	var wheel_hb: float = _handbrake_engagement if not is_front else 0.0

	# 3. Maximum Friction Envelope (Normal Load * Base Friction Coefficient)
	var base_mu: float = front_mu_peak if is_front else rear_mu_peak
	var max_friction_force: float = suspension_load * base_mu

	# 4. Longitudinal Force & Slip Ratio Calculation
	var clamped_throttle: float = clampf(throttle, 0.0, 1.0)
	var clamped_brake: float = clampf(brake, 0.0, 1.0)

	var drive_demand: float = (clamped_throttle * max_drive_force_per_wheel) if is_driven else 0.0
	var brake_demand: float = clamped_brake * max_brake_force_per_wheel
	var hb_drag_demand: float = wheel_hb * handbrake_force_per_wheel

	var net_long_demand: float = 0.0
	var brake_sign: float = -signf(v_long) if abs_v_long > 0.15 else 0.0
	net_long_demand = drive_demand + (brake_demand + hb_drag_demand) * brake_sign

	# Synthetic Longitudinal Slip Ratio (kappa)
	var slip_ratio: float = 0.0
	if max_friction_force > 1.0:
		slip_ratio = clampf(net_long_demand / max_friction_force, -1.5, 1.5)
	if wheel_hb > 0.05 and abs_v_long > 0.5:
		slip_ratio = lerpf(slip_ratio, -signf(v_long) * 1.0, wheel_hb)

	var f_long_mag: float = clampf(net_long_demand, -max_friction_force, max_friction_force)

	# 5. Non-Linear Pacejka-Style Lateral Slip Curve (Grip -> Peak -> Drift Plateau)
	var plateau_ratio: float = front_plateau_grip_ratio if is_front else rear_plateau_grip_ratio
	var normalized_lat_coeff: float = _evaluate_pacejka_plateau_curve(abs_slip_angle, plateau_ratio)
	var desired_f_lat_mag: float = normalized_lat_coeff * max_friction_force

	# Low-speed lateral velocity damping clamp so car can come to a clean stop on slopes
	if planar_speed < 2.0:
		var max_stop_force: float = suspension_load * absf(v_lat) * 0.65
		desired_f_lat_mag = minf(desired_f_lat_mag, max_stop_force)

	# 6. Kamm's Friction Circle & Throttle Power-Oversteer (RWD/FR Dynamics)
	var kamm_lateral_scale: float = 1.0

	if is_driven and clamped_throttle > 0.05:
		# Calculate excess wheelspin & cornering throttle authority
		var cornering_load_factor: float = clampf(abs_slip_angle / deg_to_rad(5.0), 0.25, 1.0)
		var torque_ratio: float = clampf(drive_demand / maxf(max_friction_force, 1.0), 0.0, 1.35)
		var wheelspin_oversteer: float = torque_ratio * torque_ratio * power_oversteer_authority * cornering_load_factor

		# Kamm's circle reduction: F_lat_max = sqrt(F_max^2 - F_long^2)
		var long_usage_sq: float = clampf((f_long_mag / maxf(max_friction_force, 1.0)) ** 2, 0.0, 0.88)
		var kamm_envelope: float = sqrt(1.0 - long_usage_sq)

		# Combine geometric Kamm circle with dynamic power-oversteer breakaway
		kamm_lateral_scale = clampf(kamm_envelope - wheelspin_oversteer, 0.28, 1.0)

		# Boost forward drive bite slightly during sustained drift so throttle can push car through hairpins
		if abs_slip_angle > drift_angle_threshold_rad:
			var drift_push_boost: float = 1.12
			f_long_mag = clampf(f_long_mag * drift_push_boost, -max_friction_force, max_friction_force * 0.95)
	else:
		# Standard Kamm's circle under braking / coasting
		var long_usage_sq: float = clampf((f_long_mag / maxf(max_friction_force, 1.0)) ** 2, 0.0, 0.78)
		kamm_lateral_scale = sqrt(1.0 - long_usage_sq)

	# 7. Progressive Handbrake Lateral Breakaway (smooth transition to sliding friction, never zero ice)
	if not is_front and wheel_hb > 0.001:
		var hb_lat_scale: float = lerpf(1.0, handbrake_lateral_retention, sqrt(wheel_hb))
		kamm_lateral_scale = minf(kamm_lateral_scale, hb_lat_scale)

	var final_f_lat_mag: float = desired_f_lat_mag * kamm_lateral_scale
	var lat_sign: float = signf(slip_angle_rad)

	var lateral_force_vec: Vector3 = right_dir * (final_f_lat_mag * lat_sign)
	var longitudinal_force_vec: Vector3 = fwd_dir * f_long_mag

	var wheel_is_drifting: bool = (
		(abs_slip_angle > drift_angle_threshold_rad and planar_speed > 3.5)
		or (is_driven and absf(slip_ratio) > 0.65 and clamped_throttle > 0.5)
		or (wheel_hb > 0.35 and planar_speed > 3.0)
	)

	return {
		"lateral_force": lateral_force_vec,
		"longitudinal_force": longitudinal_force_vec,
		"slip_ratio": slip_ratio,
		"slip_angle_rad": slip_angle_rad,
		"is_drifting": wheel_is_drifting
	}


# ==============================================================================
# 3. LIVE DRIFT TELEMETRY & SCORING METRICS
# ==============================================================================
func get_drift_telemetry() -> Dictionary:
	return {
		"slip_angle_deg": _telemetry_slip_deg,
		"drift_speed_kmh": _telemetry_speed_kmh,
		"drift_angle_quality": _telemetry_drift_quality,
		"is_drifting": _telemetry_is_drifting
	}


# ==============================================================================
# INTERNAL MATHEMATICAL HELPERS
# ==============================================================================
func _evaluate_pacejka_plateau_curve(abs_alpha_rad: float, plateau_grip_ratio: float) -> float:
	# Region 1: Elastic Build-up to Peak Grip (0° -> ~9°)
	if abs_alpha_rad <= peak_slip_angle_rad:
		var t: float = abs_alpha_rad / maxf(peak_slip_angle_rad, 0.001)
		# Sinusoidal Pacejka-like rise with strong initial cornering stiffness
		return sin(t * PI * 0.5)

	# Region 2: Post-Peak Transition into Dynamic Drift Plateau (~9° -> ~22°)
	elif abs_alpha_rad <= plateau_slip_angle_rad:
		var t: float = (abs_alpha_rad - peak_slip_angle_rad) / maxf(plateau_slip_angle_rad - peak_slip_angle_rad, 0.001)
		var smooth_t: float = t * t * (3.0 - 2.0 * t)
		return lerpf(1.0, plateau_grip_ratio, smooth_t)

	# Region 3: Sustained Touge Drift Sweet Spot Plateau (~22° -> ~55°)
	elif abs_alpha_rad <= extreme_slip_angle_rad:
		var t: float = (abs_alpha_rad - plateau_slip_angle_rad) / maxf(extreme_slip_angle_rad - plateau_slip_angle_rad, 0.001)
		# Gentle, predictable taper across the drift window so the driver can hold deep angles with throttle
		return lerpf(plateau_grip_ratio, plateau_grip_ratio * 0.90, t)

	# Region 4: Extreme Spinout Angles (> 55°)
	else:
		var excess: float = clampf((abs_alpha_rad - extreme_slip_angle_rad) / deg_to_rad(35.0), 0.0, 1.0)
		return lerpf(plateau_grip_ratio * 0.90, plateau_grip_ratio * 0.72, excess)