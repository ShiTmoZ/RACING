class_name VehicleVFXAndAudio
extends Node3D
## Principal Audio & VFX Subsystem for Nissan Skyline GT-R R34 (RB26DETT)
## Designed for Godot 4.3 (Vulkan Forward+) - "ShiTmoZ/RACING"
## Attach directly as a child of your ArcadeSimVehicle root node.

# ==============================================================================
# EXPORTED CONFIGURATION
# ==============================================================================
@export_group("Vehicle Node Binding")
@export var vehicle_node_path: NodePath = ^".."
@export var exhaust_tip_offset: Vector3 = Vector3(-0.46, 0.20, 2.33) ## R34 Left-side angled exhaust barrel tip
@export var wheel_names: Array[String] = ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]
@export var fallback_wheel_offsets: Array[Vector3] = [
	Vector3(-0.78, 0.0, 1.35),  # FL
	Vector3(0.78, 0.0, 1.35),   # FR
	Vector3(-0.78, 0.0, -1.32), # RL
	Vector3(0.78, 0.0, -1.32)   # RR
]

@export_group("RB26DETT Acoustic Parameters")
@export var mix_rate: float = 44100.0
@export var buffer_latency: float = 0.045 ## 45ms low-latency buffer for responsive throttle
@export var idle_rpm: float = 950.0
@export var redline_rpm: float = 8500.0
@export var rev_limiter_rpm: float = 8350.0
@export_range(0.0, 2.0) var master_engine_gain: float = 0.42
@export_range(0.0, 2.0) var turbo_whine_gain: float = 0.22
@export_range(0.0, 2.0) var bov_flutter_gain: float = 0.65
@export_range(0.0, 2.0) var backfire_gain: float = 0.75
@export_range(0.0, 2.0) var tire_screech_gain: float = 0.45

@export_group("Tire Skidmark Settings")
@export var slip_threshold: float = 2.2 ## Slip velocity (m/s) required to trigger marks/smoke
@export var max_slip_velocity: float = 22.0 ## Slip velocity (m/s) for 100% opacity/emission
@export var base_skid_width: float = 0.265 ## R34 265/35R18 tire width in meters
@export var max_skid_vertices_per_wheel: int = 2048
@export var skid_ground_offset: float = 0.012 ## 12mm above road to prevent depth-buffer Z-fighting

@export_group("Volumetric Smoke Settings")
@export var smoke_particles_per_wheel: int = 300
@export var smoke_lifetime: float = 3.2
@export var wind_direction_and_speed: Vector3 = Vector3(1.8, 0.6, -0.5)

# ==============================================================================
# TELEMETRY & INTERNAL STATE
# ==============================================================================
var _vehicle: Node3D = null
var _wheel_nodes: Array[Node3D] = [null, null, null, null]

# Live Telemetry Cache
var engine_rpm: float = 950.0
var throttle_input: float = 0.0
var brake_input: float = 0.0
var handbrake_input: float = 0.0
var speed_kmh: float = 0.0
var current_gear: int = 1
var gear_ratio: float = 3.2
var wheel_slip_velocities: Array[float] = [0.0, 0.0, 0.0, 0.0]
var wheel_contact_points: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var wheel_contact_normals: Array[Vector3] = [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP]
var wheel_is_grounded: Array[bool] = [true, true, true, true]

# Smoothed DSP Control State
var _dsp_rpm: float = 950.0
var _dsp_load: float = 0.0
var _boost_pressure: float = 0.0 # Normalized [0.0 .. 1.0] (~1.2 Bar peak)
var _prev_throttle: float = 0.0
var _prev_gear: int = 1
var _overrun_timer: float = 0.0

# Audio Nodes & Playback Interfaces
var _engine_player: AudioStreamPlayer3D
var _engine_playback: AudioStreamGeneratorPlayback
var _tire_player: AudioStreamPlayer3D
var _tire_playback: AudioStreamGeneratorPlayback

# RB26DETT DSP Phase Accumulators & Filter States
var _phase_f0: float = 0.0          # Primary firing frequency (RPM / 60 * 3)
var _phase_sub: float = 0.0         # Half-order intake rumble (0.5 * f0)
var _phase_cam_scream: float = 0.0  # Twin-cam metallic harmonic (3.0 * f0)
var _phase_valvetrain: float = 0.0  # High-RPM mechanical whine (6.0 * f0)
var _phase_turbo: float = 0.0       # Garrett twin-turbo blade pass frequency

# BOV ("Stututu" Flutter) & Backfire DSP Envelopes
var _bov_env: float = 0.0
var _bov_flutter_phase: float = 0.0
var _bov_initial_boost: float = 0.0
var _bov_bp_z1: float = 0.0
var _bov_bp_z2: float = 0.0

var _backfire_env: float = 0.0
var _backfire_lp_state: float = 0.0
var _exhaust_lp_state: float = 0.0
var _intake_lp_state: float = 0.0
var _prng_seed: int = 0x5F3759DF

# Tire Screech DSP State
var _screech_phase_a: float = 0.0
var _screech_phase_b: float = 0.0
var _screech_phase_c: float = 0.0
var _screech_lp_state: float = 0.0

# 3D Exhaust Flame Visuals
var _flame_root: Node3D
var _flame_mesh_outer: MeshInstance3D
var _flame_mesh_core: MeshInstance3D
var _flame_light: OmniLight3D
var _flame_visual_timer: float = 0.0

# Procedural Tire Skidmarks (ImmediateMesh Ribbon Buffers)
class SkidVertex:
	var left_pt: Vector3
	var right_pt: Vector3
	var normal: Vector3
	var alpha: float
	func _init(l: Vector3, r: Vector3, n: Vector3, a: float) -> void:
		left_pt = l
		right_pt = r
		normal = n
		alpha = a

var _skid_container: Node
var _skid_mesh_instances: Array[MeshInstance3D] = []
var _skid_immediate_meshes: Array[ImmediateMesh] = []
var _skid_history: Array[Array] = [[], [], [], []]
var _skid_last_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _skid_was_emitting: Array[bool] = [false, false, false, false]
var _skid_material: StandardMaterial3D

# Volumetric Tire Smoke (GPUParticles3D)
var _smoke_emitters: Array[GPUParticles3D] = []
var _smoke_process_mats: Array[ParticleProcessMaterial] = []


# ==============================================================================
# LIFECYCLE INITIALIZATION
# ==============================================================================
func _ready() -> void:
	_bind_vehicle_and_wheels()
	_setup_procedural_audio_streams()
	_setup_exhaust_flame_vfx()
	_setup_skidmark_ribbons()
	_setup_volumetric_tire_smoke()


func _exit_tree() -> void:
	if is_instance_valid(_skid_container):
		_skid_container.queue_free()


func _process(delta: float) -> void:
	_poll_vehicle_telemetry(delta)
	_update_engine_and_turbo_dynamics(delta)
	_synthesize_engine_audio_buffer()
	_synthesize_tire_screech_buffer()
	_update_exhaust_flame_vfx(delta)
	_update_tire_skidmarks()
	_update_volumetric_tire_smoke(delta)


# ==============================================================================
# 1. TELEMETRY BINDING & POLLING
# ==============================================================================
func _bind_vehicle_and_wheels() -> void:
	if has_node(vehicle_node_path):
		_vehicle = get_node(vehicle_node_path) as Node3D
	else:
		_vehicle = get_parent() as Node3D

	for i in range(4):
		if is_instance_valid(_vehicle) and i < wheel_names.size():
			var w_node := _vehicle.find_child(wheel_names[i], true, false) as Node3D
			if is_instance_valid(w_node):
				_wheel_nodes[i] = w_node


func _poll_vehicle_telemetry(delta: float) -> void:
	if not is_instance_valid(_vehicle):
		return

	# Read primary properties safely via Object.get() with fallback defaults
	var raw_rpm = _vehicle.get("engine_rpm")
	engine_rpm = clampf(float(raw_rpm) if raw_rpm != null else idle_rpm, 600.0, redline_rpm + 300.0)

	var raw_throttle = _vehicle.get("throttle_input")
	throttle_input = clampf(float(raw_throttle) if raw_throttle != null else 0.0, 0.0, 1.0)

	var raw_brake = _vehicle.get("brake_input")
	brake_input = clampf(float(raw_brake) if raw_brake != null else 0.0, 0.0, 1.0)

	var raw_hb = _vehicle.get("handbrake_input")
	handbrake_input = clampf(float(raw_hb) if raw_hb != null else 0.0, 0.0, 1.0)

	var raw_spd = _vehicle.get("speed_kmh")
	speed_kmh = float(raw_spd) if raw_spd != null else 0.0

	var raw_gear = _vehicle.get("current_gear")
	current_gear = int(raw_gear) if raw_gear != null else 1

	var raw_ratio = _vehicle.get("gear_ratio")
	gear_ratio = float(raw_ratio) if raw_ratio != null else 3.2

	# Read tire slip velocities (supports Array or individual properties on ArcadeSimVehicle)
	var slip_array = _vehicle.get("tire_slip_velocities")
	if slip_array == null:
		slip_array = _vehicle.get("wheel_slip_velocities")

	for i in range(4):
		var slip_val: float = 0.0
		if slip_array is Array and i < slip_array.size():
			slip_val = float(slip_array[i])
		elif is_instance_valid(_wheel_nodes[i]):
			var w_node := _wheel_nodes[i]
			if w_node is VehicleWheel3D:
				# Convert Godot VehicleWheel3D skidinfo (0=full slip, 1=full grip) to m/s slip
				var skid_factor: float = 1.0 - clampf(w_node.get_skidinfo(), 0.0, 1.0)
				slip_val = skid_factor * (absf(speed_kmh) / 3.6 + (engine_rpm / redline_rpm) * 18.0 * throttle_input)
			else:
				var custom_slip = w_node.get("slip_velocity")
				if custom_slip != null:
					slip_val = float(custom_slip)

		# Amplify rear slip during handbrake lock or standstill burnout
		if i >= 2:
			if handbrake_input > 0.1 and speed_kmh > 8.0:
				slip_val = maxf(slip_val, (speed_kmh / 3.6) * handbrake_input * 0.85)
			if throttle_input > 0.7 and brake_input > 0.4 and speed_kmh < 15.0:
				slip_val = maxf(slip_val, (engine_rpm / redline_rpm) * 20.0)

		wheel_slip_velocities[i] = maxf(0.0, slip_val)

		# Resolve world-space contact patch position and normal
		if is_instance_valid(_wheel_nodes[i]):
			var w_node := _wheel_nodes[i]
			if w_node is VehicleWheel3D:
				wheel_is_grounded[i] = w_node.is_in_contact()
				var radius: float = w_node.wheel_radius
				wheel_contact_points[i] = w_node.global_position - w_node.global_transform.basis.y * radius
				wheel_contact_normals[i] = w_node.global_transform.basis.y
			else:
				var grounded_prop = w_node.get("is_grounded")
				wheel_is_grounded[i] = bool(grounded_prop) if grounded_prop != null else true
				var radius_prop = w_node.get("wheel_radius")
				var r: float = float(radius_prop) if radius_prop != null else 0.33
				wheel_contact_points[i] = w_node.global_position - global_transform.basis.y * r
				wheel_contact_normals[i] = global_transform.basis.y
		else:
			wheel_is_grounded[i] = true
			wheel_contact_points[i] = to_global(fallback_wheel_offsets[i])
			wheel_contact_normals[i] = global_transform.basis.y

	_dsp_rpm = lerpf(_dsp_rpm, engine_rpm, clampf(delta * 28.0, 0.0, 1.0))
	_dsp_load = lerpf(_dsp_load, throttle_input, clampf(delta * 16.0, 0.0, 1.0))


# ==============================================================================
# 2. PROCEDURAL ENGINE, TURBO BOV & BACKFIRE SYNTHESIS
# ==============================================================================
func _setup_procedural_audio_streams() -> void:
	# Engine + Turbo + BOV + Backfire Generator Player
	_engine_player = AudioStreamPlayer3D.new()
	_engine_player.name = "RB26DETT_SynthPlayer3D"
	_engine_player.position = exhaust_tip_offset * 0.5
	_engine_player.unit_size = 12.0
	_engine_player.max_distance = 250.0
	_engine_player.attenuation_filter_cutoff_hz = 18000.0

	var eng_gen := AudioStreamGenerator.new()
	eng_gen.mix_rate = mix_rate
	eng_gen.buffer_length = buffer_latency
	_engine_player.stream = eng_gen
	add_child(_engine_player)
	_engine_player.play()
	_engine_playback = _engine_player.get_stream_playback() as AudioStreamGeneratorPlayback

	# Tire Screech Generator Player
	_tire_player = AudioStreamPlayer3D.new()
	_tire_player.name = "TireScreech_SynthPlayer3D"
	_tire_player.position = Vector3.ZERO
	_tire_player.unit_size = 10.0
	_tire_player.max_distance = 160.0
	_tire_player.attenuation_filter_cutoff_hz = 14000.0

	var tire_gen := AudioStreamGenerator.new()
	tire_gen.mix_rate = mix_rate
	tire_gen.buffer_length = buffer_latency
	_tire_player.stream = tire_gen
	add_child(_tire_player)
	_tire_player.play()
	_tire_playback = _tire_player.get_stream_playback() as AudioStreamGeneratorPlayback


func _update_engine_and_turbo_dynamics(delta: float) -> void:
	var rpm_norm: float = clampf((engine_rpm - idle_rpm) / (redline_rpm - idle_rpm), 0.0, 1.0)

	# 1. Twin-Turbo Spool Physics
	# RB26DETT parallel twin ceramic turbos spool aggressively past ~3,200 RPM under throttle load
	var spool_efficiency: float = smoothstep(0.18, 0.65, rpm_norm)
	var target_boost: float = throttle_input * spool_efficiency * clampf(absf(gear_ratio) * 0.45, 0.5, 1.2)
	if throttle_input > 0.25 and target_boost > _boost_pressure:
		_boost_pressure = move_toward(_boost_pressure, clampf(target_boost, 0.0, 1.0), delta * 1.45)
	else:
		_boost_pressure = move_toward(_boost_pressure, maxf(0.0, target_boost), delta * 3.8)

	# 2. Atmospheric Blow-Off Valve / Compressor Surge ("Stututu" Flutter) Trigger
	var throttle_drop: float = _prev_throttle - throttle_input
	if throttle_drop > 0.35 and _boost_pressure > 0.28 and _bov_env < 0.25:
		_bov_env = clampf(_boost_pressure * 1.15, 0.4, 1.0)
		_bov_initial_boost = _boost_pressure
		_bov_flutter_phase = 0.0
		_boost_pressure *= 0.15

	# 3. Exhaust Backfire & Overrun Pop-and-Bang Trigger
	# Trigger on aggressive shift or high-RPM deceleration overrun (> 4,500 RPM with closed throttle)
	if current_gear != _prev_gear and engine_rpm > 5200.0:
		_trigger_exhaust_backfire(clampf(rpm_norm * 1.1, 0.65, 1.0))
	elif throttle_input < 0.08 and engine_rpm > 4500.0:
		_overrun_timer -= delta
		if _overrun_timer <= 0.0:
			var pop_chance: float = 0.45 + 0.45 * rpm_norm
			if _fast_rand_float() < pop_chance:
				_trigger_exhaust_backfire(clampf(0.5 + 0.5 * _fast_rand_float(), 0.5, 1.0))
			_overrun_timer = lerpf(0.055, 0.22, _fast_rand_float())
	else:
		_overrun_timer = 0.04

	_prev_throttle = throttle_input
	_prev_gear = current_gear


func _trigger_exhaust_backfire(intensity: float) -> void:
	_backfire_env = maxf(_backfire_env, intensity)
	_flame_visual_timer = lerpf(0.045, 0.095, intensity)
	if is_instance_valid(_flame_root):
		_flame_root.scale = Vector3(
			lerpf(0.85, 1.35, _fast_rand_float()),
			lerpf(0.85, 1.35, _fast_rand_float()),
			lerpf(0.9, 1.85, intensity)
		)
		_flame_root.rotation.z = _fast_rand_float() * TAU


func _synthesize_engine_audio_buffer() -> void:
	if _engine_playback == null:
		return

	var frames_to_fill: int = _engine_playback.get_frames_available()
	if frames_to_fill <= 0:
		return

	var inv_rate: float = 1.0 / mix_rate
	var rpm_norm: float = clampf((_dsp_rpm - idle_rpm) / (redline_rpm - idle_rpm), 0.0, 1.0)

	# Mix weights across RPM bands:
	# - Low (< 3000 RPM): Deep throaty induction rumble dominates
	# - High (4000 -> 8500 RPM): Twin-cam metallic scream & harmonic rasp dominate
	var low_rumble_weight: float = 1.0 - smoothstep(1800.0, 4200.0, _dsp_rpm)
	var high_scream_weight: float = smoothstep(3200.0, 8200.0, _dsp_rpm)
	var load_drive: float = lerpf(1.25, 3.6, _dsp_load)

	# Rev-limiter fuel cut modulation above rev_limiter_rpm (8,350 RPM)
	var fuel_cut: float = 1.0
	if _dsp_rpm >= rev_limiter_rpm:
		fuel_cut = 0.15 if int(Time.get_ticks_msec() / 28) % 2 == 0 else 1.0

	# Inline-6 4-stroke fundamental firing frequency: 3 combustion events per crankshaft revolution
	var f0: float = (_dsp_rpm / 60.0) * 3.0
	var f_sub: float = f0 * 0.5          # Crankshaft rotation order (throaty low-end growl)
	var f_cam: float = f0 * 3.0          # 9th-order twin-cam resonance
	var f_valvetrain: float = f0 * 6.0   # High-order metallic mechanical scream

	# Twin-turbo blade pass frequency (2,200 Hz idle -> 6,800 Hz full boost)
	var f_turbo: float = lerpf(2100.0, 6850.0, pow(_boost_pressure, 0.75))

	# Dynamic one-pole low-pass filter coefficient (opens up with RPM and throttle load)
	var exhaust_cutoff_hz: float = lerpf(420.0, 6400.0, clampf(rpm_norm * 0.72 + _dsp_load * 0.45, 0.0, 1.0))
	var lp_alpha: float = clampf(TAU * exhaust_cutoff_hz * inv_rate, 0.02, 0.96)

	for _i in range(frames_to_fill):
		# Advance oscillator phases
		_phase_f0 = fmod(_phase_f0 + f0 * inv_rate, 1.0)
		_phase_sub = fmod(_phase_sub + f_sub * inv_rate, 1.0)
		_phase_cam_scream = fmod(_phase_cam_scream + f_cam * inv_rate, 1.0)
		_phase_valvetrain = fmod(_phase_valvetrain + f_valvetrain * inv_rate, 1.0)
		_phase_turbo = fmod(_phase_turbo + f_turbo * inv_rate, 1.0)

		var p0: float = _phase_f0 * TAU
		var p_sub: float = _phase_sub * TAU

		# 1. Deep Throaty Intake Rumble (< 3,000 RPM)
		# Combines sub-harmonic pulse with filtered induction air turbulence
		var white: float = _fast_rand_signed()
		_intake_lp_state += 0.08 * (white - _intake_lp_state)
		var intake_rumble: float = (
			sin(p_sub) * 0.65 +
			sin(p_sub * 2.0 + 0.4) * 0.35 +
			_intake_lp_state * 0.45 * _dsp_load
		) * (0.45 + 0.55 * low_rumble_weight)

		# 2. Iconic RB26DETT Inline-6 Harmonic Stack (1st, 2nd, 3rd, 4.5th orders)
		var saw_f0: float = 2.0 * _phase_f0 - 1.0
		var inline6_core: float = (
			sin(p0) * 0.50 +
			sin(p0 * 2.0 + 0.25) * 0.35 +
			saw_f0 * 0.28 * (0.3 + 0.7 * _dsp_load)
		)

		# 3. High-Pitched Metallic Twin-Cam Scream (3,500 -> 8,500 RPM Redline)
		# Ring-modulated harmonic overtones + asymmetrical wavefolding for metallic rasp
		var cam_wave: float = sin(_phase_cam_scream * TAU)
		var valve_wave: float = sin(_phase_valvetrain * TAU)
		var metallic_scream: float = (
			cam_wave * (0.65 + 0.35 * sin(p0 * 1.5)) +
			valve_wave * 0.42
		) * high_scream_weight * (0.45 + 0.55 * _dsp_load)

		# Combine engine layers & apply asymmetric tube/manifold saturation
		var raw_engine: float = (intake_rumble * 0.65 + inline6_core * 0.85 + metallic_scream * 0.80) * fuel_cut
		var saturated_engine: float = tanh(raw_engine * load_drive)
		_exhaust_lp_state += lp_alpha * (saturated_engine - _exhaust_lp_state)
		var engine_out: float = _exhaust_lp_state * master_engine_gain * (0.55 + 0.45 * rpm_norm)

		# 4. Twin-Turbo Boost Spool Whine
		var turbo_whistle: float = (
			sin(_phase_turbo * TAU) * 0.75 +
			white * 0.25
		) * (_boost_pressure * _boost_pressure) * turbo_whine_gain * 0.35

		# 5. Atmospheric BOV / Compressor Surge ("Stututu / Whoosh" Flutter)
		var bov_out: float = 0.0
		if _bov_env > 0.001:
			# Flutter LFO accelerates from 13 Hz to 26 Hz as surge pressure decays
			var flutter_hz: float = lerpf(26.0, 12.5, _bov_env)
			_bov_flutter_phase = fmod(_bov_flutter_phase + flutter_hz * inv_rate, 1.0)
			var flutter_mod: float = pow(0.5 + 0.5 * sin(_bov_flutter_phase * TAU), 1.8)

			# State-variable bandpass filter swept by flutter envelope (950 Hz -> 3,600 Hz)
			var bp_cutoff: float = lerpf(950.0, 3600.0, flutter_mod * _bov_initial_boost)
			var f_coeff: float = 2.0 * sin(PI * minf(bp_cutoff, mix_rate * 0.4) * inv_rate)
			var q_damp: float = 0.14
			var hp: float = white - _bov_bp_z1 * q_damp - _bov_bp_z2
			_bov_bp_z1 += f_coeff * hp
			_bov_bp_z2 += f_coeff * _bov_bp_z1

			bov_out = _bov_bp_z1 * _bov_env * (0.30 + 0.70 * flutter_mod) * bov_flutter_gain
			_bov_env *= exp(-4.8 * inv_rate)

		# 6. Exhaust Backfire & Pop-and-Bang Synthesis
		var backfire_out: float = 0.0
		if _backfire_env > 0.001:
			# Low-passed explosive impulse with hard manifold clipping
			_backfire_lp_state += 0.14 * (white - _backfire_lp_state)
			var pop_wave: float = tanh(_backfire_lp_state * 9.5 * _backfire_env)
			backfire_out = pop_wave * _backfire_env * backfire_gain
			_backfire_env *= exp(-26.0 * inv_rate)

		# Final stereo frame with subtle spatial width between intake/turbo (R) and exhaust (L)
		var left_ch: float = clampf(engine_out * 1.04 + turbo_whistle * 0.85 + bov_out * 0.90 + backfire_out * 1.10, -0.98, 0.98)
		var right_ch: float = clampf(engine_out * 0.96 + turbo_whistle * 1.12 + bov_out * 1.08 + backfire_out * 0.92, -0.98, 0.98)
		_engine_playback.push_frame(Vector2(left_ch, right_ch))


func _synthesize_tire_screech_buffer() -> void:
	if _tire_playback == null:
		return

	var frames_to_fill: int = _tire_playback.get_frames_available()
	if frames_to_fill <= 0:
		return

	# Aggregate peak slip across all 4 grounded tires
	var peak_slip: float = 0.0
	for i in range(4):
		if wheel_is_grounded[i] and wheel_slip_velocities[i] > peak_slip:
			peak_slip = wheel_slip_velocities[i]

	var slip_norm: float = clampf((peak_slip - slip_threshold) / (max_slip_velocity - slip_threshold), 0.0, 1.0)
	if slip_norm <= 0.001:
		for _i in range(frames_to_fill):
			_tire_playback.push_frame(Vector2.ZERO)
		return

	var inv_rate: float = 1.0 / mix_rate
	# Stick-slip rubber resonance frequencies shift upward with slip speed
	var freq_a: float = lerpf(820.0, 1480.0, slip_norm)
	var freq_b: float = lerpf(1310.0, 2240.0, slip_norm)
	var freq_c: float = lerpf(2150.0, 3100.0, slip_norm)
	var amp: float = slip_norm * tire_screech_gain * 0.42

	for _i in range(frames_to_fill):
		var noise: float = _fast_rand_signed()
		_screech_lp_state += 0.18 * (noise - _screech_lp_state)

		# FM-modulated stick-slip oscillators simulating rubber tread block chatter
		var fm_jitter: float = 1.0 + _screech_lp_state * 0.08
		_screech_phase_a = fmod(_screech_phase_a + freq_a * fm_jitter * inv_rate, 1.0)
		_screech_phase_b = fmod(_screech_phase_b + freq_b * fm_jitter * inv_rate, 1.0)
		_screech_phase_c = fmod(_screech_phase_c + freq_c * inv_rate, 1.0)

		var screech_sig: float = (
			sin(_screech_phase_a * TAU) * 0.50 +
			sin(_screech_phase_b * TAU) * 0.32 +
			sin(_screech_phase_c * TAU) * 0.18 +
			_screech_lp_state * 0.35
		)
		var out_sample: float = tanh(screech_sig * 1.8) * amp
		_tire_playback.push_frame(Vector2(out_sample, out_sample))


# ==============================================================================
# 3. 3D EXHAUST BACKFIRE FLAME TONGUE VFX
# ==============================================================================
func _setup_exhaust_flame_vfx() -> void:
	_flame_root = Node3D.new()
	_flame_root.name = "ExhaustFlameTongue3D"
	_flame_root.position = exhaust_tip_offset
	# Orient cone to shoot backward (-Z) out of the R34 tailpipe
	_flame_root.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_flame_root.visible = false
	add_child(_flame_root)

	# Outer Orange/Amber Combustion Plume
	var outer_cone := CylinderMesh.new()
	outer_cone.top_radius = 0.005
	outer_cone.bottom_radius = 0.095
	outer_cone.height = 0.72
	outer_cone.radial_segments = 16
	outer_cone.rings = 2

	var outer_mat := StandardMaterial3D.new()
	outer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	outer_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	outer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outer_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	outer_mat.albedo_color = Color(1.0, 0.42, 0.05, 0.85)
	outer_mat.emission_enabled = true
	outer_mat.emission = Color(1.0, 0.38, 0.02)
	outer_mat.emission_energy_multiplier = 8.5

	_flame_mesh_outer = MeshInstance3D.new()
	_flame_mesh_outer.mesh = outer_cone
	_flame_mesh_outer.material_override = outer_mat
	_flame_mesh_outer.position = Vector3(0.0, 0.36, 0.0)
	_flame_mesh_outer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flame_root.add_child(_flame_mesh_outer)

	# Inner High-Temperature Blue/Cyan Core
	var core_cone := CylinderMesh.new()
	core_cone.top_radius = 0.002
	core_cone.bottom_radius = 0.055
	core_cone.height = 0.38
	core_cone.radial_segments = 12
	core_cone.rings = 1

	var core_mat := StandardMaterial3D.new()
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	core_mat.albedo_color = Color(0.25, 0.68, 1.0, 0.95)
	core_mat.emission_enabled = true
	core_mat.emission = Color(0.35, 0.78, 1.0)
	core_mat.emission_energy_multiplier = 14.0

	_flame_mesh_core = MeshInstance3D.new()
	_flame_mesh_core.mesh = core_cone
	_flame_mesh_core.material_override = core_mat
	_flame_mesh_core.position = Vector3(0.0, 0.19, 0.0)
	_flame_mesh_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flame_root.add_child(_flame_mesh_core)

	# Synchronized Asphalt Flash Light
	_flame_light = OmniLight3D.new()
	_flame_light.light_color = Color(1.0, 0.52, 0.15)
	_flame_light.light_energy = 4.5
	_flame_light.omni_range = 4.2
	_flame_light.shadow_enabled = false
	_flame_light.position = Vector3(0.0, 0.25, 0.0)
	_flame_root.add_child(_flame_light)


func _update_exhaust_flame_vfx(delta: float) -> void:
	if _flame_visual_timer > 0.0:
		_flame_visual_timer -= delta
		_flame_root.visible = true
		var flicker: float = clampf(_flame_visual_timer / 0.08, 0.0, 1.0)
		_flame_light.light_energy = 5.0 * flicker
		_flame_root.scale.y = lerpf(0.6, 1.5, flicker)
	elif _flame_root.visible:
		_flame_root.visible = false


# ==============================================================================
# 4. PROCEDURAL TIRE SKIDMARKS (CONTINUOUS RIBBON MESHES)
# ==============================================================================
func _setup_skidmark_ribbons() -> void:
	# Top-level container ensures baked world-space skidmarks stay anchored on the road
	_skid_container = Node.new()
	_skid_container.name = "SkidmarkWorldContainer_" + str(get_instance_id())
	if get_tree() != null and get_tree().current_scene != null:
		get_tree().current_scene.call_deferred("add_child", _skid_container)
	else:
		call_deferred("add_sibling", _skid_container)

	_skid_material = StandardMaterial3D.new()
	_skid_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_skid_material.vertex_color_use_as_albedo = true
	_skid_material.albedo_color = Color(0.04, 0.04, 0.045, 0.92)
	_skid_material.roughness = 0.42 # Freshly heated rubber sheen on asphalt
	_skid_material.metallic = 0.08
	_skid_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	for i in range(4):
		var imm_mesh := ImmediateMesh.new()
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.name = "TireSkidRibbon_" + wheel_names[i]
		mesh_inst.mesh = imm_mesh
		mesh_inst.material_override = _skid_material
		mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_skid_container.add_child(mesh_inst)

		_skid_immediate_meshes.append(imm_mesh)
		_skid_mesh_instances.append(mesh_inst)
		_skid_history[i] = []


func _update_tire_skidmarks() -> void:
	var forward_dir: Vector3 = -global_transform.basis.z.normalized()

	for i in range(4):
		var slip: float = wheel_slip_velocities[i]
		var grounded: bool = wheel_is_grounded[i]
		var is_skidding: bool = grounded and (slip >= slip_threshold)

		if is_skidding:
			var contact_pt: Vector3 = wheel_contact_points[i]
			var normal: Vector3 = wheel_contact_normals[i].normalized()
			var dist_moved: float = contact_pt.distance_to(_skid_last_pos[i])

			# Only append a new quad cross-section after moving 12cm to preserve vertex budget
			if not _skid_was_emitting[i] or dist_moved >= 0.12:
				var move_dir: Vector3 = (contact_pt - _skid_last_pos[i]).normalized() if (_skid_was_emitting[i] and dist_moved > 0.01) else forward_dir
				var right_vec: Vector3 = move_dir.cross(normal).normalized()
				if right_vec.length_squared() < 0.01:
					right_vec = global_transform.basis.x.normalized()

				var slip_ratio: float = clampf((slip - slip_threshold) / (max_slip_velocity - slip_threshold), 0.0, 1.0)
				# Dynamic width expands up to 35% during high-angle lateral broadslides
				var lateral_factor: float = absf(move_dir.dot(global_transform.basis.x.normalized()))
				var half_width: float = (base_skid_width * 0.5) * lerpf(1.0, 1.35, lateral_factor * slip_ratio)
				var alpha: float = clampf(slip_ratio * 0.90, 0.08, 0.90)

				var center: Vector3 = contact_pt + normal * skid_ground_offset
				var left_pt: Vector3 = center - right_vec * half_width
				var right_pt: Vector3 = center + right_vec * half_width

				# Insert transparent break-vertex when starting a new skid segment
				if not _skid_was_emitting[i] and _skid_history[i].size() > 0:
					var prev_v: SkidVertex = _skid_history[i].back()
					_skid_history[i].append(SkidVertex.new(prev_v.left_pt, prev_v.right_pt, prev_v.normal, 0.0))
					_skid_history[i].append(SkidVertex.new(left_pt, right_pt, normal, 0.0))

				_skid_history[i].append(SkidVertex.new(left_pt, right_pt, normal, alpha))
				_skid_last_pos[i] = contact_pt
				_skid_was_emitting[i] = true

				while _skid_history[i].size() > max_skid_vertices_per_wheel:
					_skid_history[i].pop_front()

				_rebuild_skid_ribbon_mesh(i)
		else:
			if _skid_was_emitting[i] and _skid_history[i].size() > 0:
				var last_v: SkidVertex = _skid_history[i].back()
				_skid_history[i].append(SkidVertex.new(last_v.left_pt, last_v.right_pt, last_v.normal, 0.0))
				_rebuild_skid_ribbon_mesh(i)
			_skid_was_emitting[i] = false


func _rebuild_skid_ribbon_mesh(wheel_idx: int) -> void:
	var imm: ImmediateMesh = _skid_immediate_meshes[wheel_idx]
	var pts: Array = _skid_history[wheel_idx]
	imm.clear_surfaces()
	if pts.size() < 2:
		return

	imm.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for idx in range(pts.size()):
		var v: SkidVertex = pts[idx]
		# Fade oldest 10% of vertices smoothly to zero alpha
		var age_fade: float = clampf(float(idx) / maxf(1.0, float(pts.size()) * 0.10), 0.0, 1.0)
		var c := Color(0.04, 0.04, 0.045, v.alpha * age_fade)

		imm.surface_set_normal(v.normal)
		imm.surface_set_color(c)
		imm.surface_add_vertex(v.left_pt)

		imm.surface_set_normal(v.normal)
		imm.surface_set_color(c)
		imm.surface_add_vertex(v.right_pt)
	imm.surface_end()


# ==============================================================================
# 5. VOLUMETRIC TIRE SMOKE (VULKAN FORWARD+ GPUPARTICLES3D)
# ==============================================================================
func _setup_volumetric_tire_smoke() -> void:
	# Shared Volumetric Smoke Material (Lit for Vulkan Forward+ Headlights/Streetlights + Soft Particles)
	var smoke_draw_mat := StandardMaterial3D.new()
	smoke_draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_draw_mat.vertex_color_use_as_albedo = true
	smoke_draw_mat.albedo_color = Color(0.92, 0.93, 0.95, 0.58)
	smoke_draw_mat.roughness = 0.96
	smoke_draw_mat.metallic = 0.0
	smoke_draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smoke_draw_mat.billboard_keep_scale = true
	smoke_draw_mat.proximity_fade_enabled = true
	smoke_draw_mat.proximity_fade_distance = 0.65 # Eliminates hard clipping intersections with asphalt/fenders
	smoke_draw_mat.backlight_enabled = true
	smoke_draw_mat.backlight = Color(0.45, 0.45, 0.50) # Subsurface scattering look under taillights

	# Procedural radial soft-cloud texture so no external PNG asset is required
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.45, 0.78, 1.0])
	grad.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.85),
		Color(0.95, 0.95, 0.95, 0.55),
		Color(0.88, 0.88, 0.90, 0.18),
		Color(0.85, 0.85, 0.88, 0.0)
	])
	var radial_tex := GradientTexture2D.new()
	radial_tex.gradient = grad
	radial_tex.fill = GradientTexture2D.FILL_RADIAL
	radial_tex.fill_from = Vector2(0.5, 0.5)
	radial_tex.fill_to = Vector2(0.5, 0.0)
	radial_tex.width = 128
	radial_tex.height = 128
	smoke_draw_mat.albedo_texture = radial_tex

	var quad_mesh := QuadMesh.new()
	quad_mesh.size = Vector2(1.15, 1.15)
	quad_mesh.material = smoke_draw_mat

	# Scale curve: tight puff at tire contact patch -> billowing volumetric cloud
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.32))
	scale_curve.add_point(Vector2(0.25, 1.35))
	scale_curve.add_point(Vector2(1.0, 3.85))
	var scale_curve_tex := CurveTexture.new()
	scale_curve_tex.curve = scale_curve

	# Alpha dissipation ramp over particle lifetime
	var alpha_grad := Gradient.new()
	alpha_grad.offsets = PackedFloat32Array([0.0, 0.12, 0.55, 1.0])
	alpha_grad.colors = PackedColorArray([
		Color(0.85, 0.86, 0.88, 0.0),
		Color(0.92, 0.93, 0.95, 0.65),
		Color(0.86, 0.87, 0.90, 0.32),
		Color(0.80, 0.82, 0.85, 0.0)
	])
	var color_ramp_tex := GradientTexture1D.new()
	color_ramp_tex.gradient = alpha_grad

	for i in range(4):
		var p_mat := ParticleProcessMaterial.new()
		p_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		p_mat.emission_sphere_radius = 0.18
		p_mat.direction = Vector3(0.0, 0.65, 0.75)
		p_mat.spread = 42.0
		p_mat.initial_velocity_min = 0.8
		p_mat.initial_velocity_max = 2.6
		p_mat.angular_velocity_min = -65.0
		p_mat.angular_velocity_max = 65.0
		p_mat.angle_min = -180.0
		p_mat.angle_max = 180.0
		p_mat.gravity = wind_direction_and_speed # Buoyant thermal lift + ambient wind dissipation
		p_mat.damping_min = 1.2
		p_mat.damping_max = 2.5
		p_mat.scale_min = 0.85
		p_mat.scale_max = 1.45
		p_mat.scale_curve = scale_curve_tex
		p_mat.color_ramp = color_ramp_tex
		p_mat.turbulence_enabled = true
		p_mat.turbulence_noise_strength = 1.65
		p_mat.turbulence_noise_scale = 2.4
		p_mat.turbulence_noise_speed = Vector3(0.5, 0.8, 0.5)

		var emitter := GPUParticles3D.new()
		emitter.name = "VolumetricSmoke_" + wheel_names[i]
		emitter.amount = smoke_particles_per_wheel
		emitter.lifetime = smoke_lifetime
		emitter.explosiveness = 0.0
		emitter.randomness = 0.35
		emitter.fixed_fps = 60
		emitter.interpolate = true
		emitter.local_coords = false # Emit in world space for realistic trailing Touge drift clouds
		emitter.process_material = p_mat
		emitter.draw_pass_1 = quad_mesh
		emitter.emitting = false
		emitter.visibility_aabb = AABB(Vector3(-25.0, -5.0, -25.0), Vector3(50.0, 20.0, 50.0))

		add_child(emitter)
		_smoke_emitters.append(emitter)
		_smoke_process_mats.append(p_mat)


func _update_volumetric_tire_smoke(_delta: float) -> void:
	for i in range(4):
		var emitter: GPUParticles3D = _smoke_emitters[i]
		var p_mat: ParticleProcessMaterial = _smoke_process_mats[i]
		emitter.global_position = wheel_contact_points[i] + wheel_contact_normals[i] * 0.08

		var slip: float = wheel_slip_velocities[i]
		if wheel_is_grounded[i] and slip > slip_threshold:
			var intensity: float = clampf((slip - slip_threshold) / (max_slip_velocity - slip_threshold), 0.05, 1.0)
			emitter.emitting = true
			emitter.amount_ratio = intensity
			# Kick smoke outward faster during high-RPM burnouts and donuts
			p_mat.initial_velocity_min = lerpf(0.8, 2.4, intensity)
			p_mat.initial_velocity_max = lerpf(2.2, 6.5, intensity)
			p_mat.gravity = wind_direction_and_speed + Vector3(0.0, lerpf(0.3, 1.4, intensity), 0.0)
		else:
			emitter.emitting = false
			emitter.amount_ratio = 0.0


# ==============================================================================
# FAST REAL-TIME AUDIO PRNG HELPERS (ZERO ALLOCATION)
# ==============================================================================
func _fast_rand_signed() -> float:
	_prng_seed = (_prng_seed * 1664525 + 1013904223) & 0x7FFFFFFF
	return (float(_prng_seed) / float(0x3FFFFFFF)) - 1.0


func _fast_rand_float() -> float:
	_prng_seed = (_prng_seed * 1664525 + 1013904223) & 0x7FFFFFFF
	return float(_prng_seed) / float(0x7FFFFFFF)