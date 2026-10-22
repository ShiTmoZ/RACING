class_name FD3SRx7Modeler
extends Node3D

# ==============================================================================
# MAZDA RX-7 FD3S (TYPE RS) PROCEDURAL 3D MODELER & 13B-REW ROTARY SYNTHESIZER
# Target Engine: Godot 4.3+
# Architecture: 100% Self-Contained Procedural Mesh & Audio Generator
# ==============================================================================

@export_group("FD3S Customization")
@export var body_color: Color = Color(1.0, 0.78, 0.05) # Competition Sunburst Yellow
@export var wheel_finish: Color = Color(0.82, 0.84, 0.88) # Forged Silver/Titanium
@export var caliper_color: Color = Color(0.85, 0.08, 0.08) # Brembo Red
@export var headlight_pop_angle: float = 0.0 # 0.0 = Sleek Fixed/Closed, 1.0 = Popped Up
@export var enable_audio_synthesis: bool = true

# Exact FD3S Proportions (in meters)
const CAR_LENGTH: float = 4.285
const CAR_WIDTH: float = 1.760
const CAR_HEIGHT: float = 1.230
const WHEELBASE: float = 2.425
const FRONT_TRACK: float = 1.460
const REAR_TRACK: float = 1.460
const WHEEL_RADIUS: float = 0.318

# 13B-REW Sequential Twin-Turbo Specifications
const IDLE_RPM: float = 950.0
const REDLINE_RPM: float = 8200.0
const SECONDARY_TURBO_RPM: float = 4500.0
const PRIMARY_MAX_BOOST_BAR: float = 0.75
const SECONDARY_MAX_BOOST_BAR: float = 0.95

# Dynamic Telemetry State
var current_boost_bar: float = 0.0
var is_secondary_turbo_online: bool = false
var rotor_thermal_load: float = 0.0
var _previous_throttle: float = 0.0
var _bov_flutter_timer: float = 0.0
var _backfire_cooldown: float = 0.0
var _wheel_spin_angle: float = 0.0

# Internal Material Library
var _mat_body_paint: StandardMaterial3D
var _mat_carbon_fiber: StandardMaterial3D
var _mat_glass_tinted: StandardMaterial3D
var _mat_dark_trim: StandardMaterial3D
var _mat_chrome_exhaust: StandardMaterial3D
var _mat_alloy_wheel: StandardMaterial3D
var _mat_tire_rubber: StandardMaterial3D
var _mat_brake_rotor: StandardMaterial3D
var _mat_brembo_caliper: StandardMaterial3D
var _mat_taillight_smoked_housing: StandardMaterial3D
var _mat_taillight_halo: StandardMaterial3D
var _mat_reverse_lamp: StandardMaterial3D
var _mat_headlight_beam: StandardMaterial3D
var _mat_amber_signal: StandardMaterial3D
var _mat_intercooler: StandardMaterial3D

# Node Hierarchy References
var _body_root: Node3D
var _wheel_pivots: Array[Node3D] = [] # [FL, FR, RL, RR]
var _wheel_spinners: Array[Node3D] = []
var _brake_rotors: Array[MeshInstance3D] = []
var _pop_up_Left: Node3D
var _pop_up_Right: Node3D
var _exhaust_particles: GPUParticles3D
var _exhaust_omni_light: OmniLight3D

# Audio Synthesis State
var _engine_audio_player: AudioStreamPlayer3D
var _engine_playback: AudioStreamGeneratorPlayback
var _rotary_phase_primary: float = 0.0
var _rotary_phase_secondary: float = 0.0
var _turbo_whine_phase: float = 0.0
var _bov_phase: float = 0.0
var _current_synth_rpm: float = IDLE_RPM
var _active_backfire_pop: float = 0.0


func _ready() -> void:
	_init_materials()
	_build_entire_fd3s_car()
	if enable_audio_synthesis:
		_setup_13b_rotary_audio()


func _physics_process(delta: float) -> void:
	if enable_audio_synthesis and is_instance_valid(_engine_audio_player):
		_synthesize_rotary_audio_buffer(delta)


# ==============================================================================
# PUBLIC API FOR RIGIDBODY3D VEHICLE BINDING
# ==============================================================================

func attach_to_vehicle(vehicle: RigidBody3D) -> void:
	if not is_instance_valid(vehicle):
		return
	if get_parent() != null:
		get_parent().remove_child(self)
	vehicle.add_child(self)
	transform = Transform3D.IDENTITY


func update_visuals(
	delta: float,
	steer_angle: float,
	throttle: float,
	brake: float,
	rpm: float,
	speed_kmh: float,
	is_reversing: bool
) -> void:
	_current_synth_rpm = clampf(rpm, IDLE_RPM, REDLINE_RPM + 300.0)
	
	# 1. Sequential Twin-Turbo Boost Calculation
	var target_boost: float = 0.0
	if throttle > 0.15 and _current_synth_rpm > 1800.0:
		if _current_synth_rpm < SECONDARY_TURBO_RPM:
			is_secondary_turbo_online = false
			var spool_factor: float = inverse_lerp(1800.0, 3200.0, _current_synth_rpm)
			target_boost = clampf(spool_factor, 0.0, 1.0) * PRIMARY_MAX_BOOST_BAR * throttle
		else:
			is_secondary_turbo_online = true
			var sec_spool: float = inverse_lerp(SECONDARY_TURBO_RPM, 5400.0, _current_synth_rpm)
			var max_b: float = lerpf(PRIMARY_MAX_BOOST_BAR, SECONDARY_MAX_BOOST_BAR, clampf(sec_spool, 0.0, 1.0))
			target_boost = max_b * throttle
	else:
		is_secondary_turbo_online = false
		target_boost = -0.45 * (1.0 - throttle) # Manifold vacuum

	# Trigger Sequential BOV Flutter on abrupt throttle lift under high positive boost
	if _previous_throttle - throttle > 0.38 and current_boost_bar > 0.42:
		_bov_flutter_timer = 0.55
	
	# Trigger Overrun Rotary Backfire Pops above 5800 RPM
	if _backfire_cooldown > 0.0:
		_backfire_cooldown -= delta
	if throttle < 0.08 and _previous_throttle > 0.55 and _current_synth_rpm > 5800.0 and _backfire_cooldown <= 0.0:
		_trigger_rotary_backfire()
		_backfire_cooldown = 0.35

	_previous_throttle = throttle
	current_boost_bar = lerpf(current_boost_bar, target_boost, delta * 9.5)
	if _bov_flutter_timer > 0.0:
		_bov_flutter_timer = maxf(0.0, _bov_flutter_timer - delta)

	# 2. Wheel Rotation & Front Steering Geometry
	var linear_mps: float = speed_kmh / 3.6
	var angular_vel: float = linear_mps / WHEEL_RADIUS
	var direction_sign: float = -1.0 if is_reversing else 1.0
	_wheel_spin_angle = fmod(_wheel_spin_angle + angular_vel * delta * direction_sign, TAU)

	if _wheel_pivots.size() == 4 and _wheel_spinners.size() == 4:
		# Ackermann slight toe difference
		_wheel_pivots[0].rotation.y = steer_angle * 1.04
		_wheel_pivots[1].rotation.y = steer_angle * 0.96
		for i in range(4):
			_wheel_spinners[i].rotation.x = _wheel_spin_angle

	# 3. Brake Rotor Thermal Glow & Taillight Halo Intensity
	var heat_gain: float = brake * clampf( absf(speed_kmh) / 110.0, 0.0, 1.5 ) * delta * 1.8
	var heat_cooling: float = (0.28 + clampf(absf(speed_kmh) / 160.0, 0.0, 0.8)) * delta
	rotor_thermal_load = clampf(rotor_thermal_load + heat_gain - heat_cooling, 0.0, 1.0)

	if is_instance_valid(_mat_brake_rotor):
		_mat_brake_rotor.emission_energy_multiplier = rotor_thermal_load * 4.2

	if is_instance_valid(_mat_taillight_halo):
		_mat_taillight_halo.emission_energy_multiplier = 6.5 if brake > 0.08 else 3.2

	if is_instance_valid(_mat_reverse_lamp):
		_mat_reverse_lamp.emission_enabled = is_reversing
		_mat_reverse_lamp.emission_energy_multiplier = 3.5 if is_reversing else 0.0

	# 4. Subtle Chassis Pitch & Roll Reaction
	if is_instance_valid(_body_root):
		var target_pitch: float = (brake * 0.025) - (throttle * 0.018 * clampf(current_boost_bar, 0.0, 1.0))
		var target_roll: float = -steer_angle * clampf(absf(speed_kmh) / 90.0, 0.0, 1.0) * 0.045
		_body_root.rotation.x = lerpf(_body_root.rotation.x, target_pitch, delta * 8.0)
		_body_root.rotation.z = lerpf(_body_root.rotation.z, target_roll, delta * 8.0)

	# 5. Pop-Up Headlight Actuation
	if is_instance_valid(_pop_up_Left) and is_instance_valid(_pop_up_Right):
		var pop_rad: float = deg_to_rad(-36.0 * clampf(headlight_pop_angle, 0.0, 1.0))
		_pop_up_Left.rotation.x = lerpf(_pop_up_Left.rotation.x, pop_rad, delta * 10.0)
		_pop_up_Right.rotation.x = lerpf(_pop_up_Right.rotation.x, pop_rad, delta * 10.0)

	# Decay exhaust backfire flash
	if is_instance_valid(_exhaust_omni_light) and _exhaust_omni_light.light_energy > 0.0:
		_exhaust_omni_light.light_energy = maxf(0.0, _exhaust_omni_light.light_energy - delta * 28.0)


# ==============================================================================
# MATERIAL INITIALIZATION
# ==============================================================================

func _init_materials() -> void:
	# 1. Competition Sunburst Yellow Multi-Layer Lacquer
	_mat_body_paint = StandardMaterial3D.new()
	_mat_body_paint.albedo_color = body_color
	_mat_body_paint.metallic = 0.15
	_mat_body_paint.roughness = 0.22
	_mat_body_paint.clearcoat_enabled = true
	_mat_body_paint.clearcoat = 0.45
	_mat_body_paint.clearcoat_roughness = 0.08

	# 2. High-Gloss Twill Carbon Fiber
	_mat_carbon_fiber = StandardMaterial3D.new()
	_mat_carbon_fiber.albedo_color = Color(0.11, 0.12, 0.13)
	_mat_carbon_fiber.metallic = 0.35
	_mat_carbon_fiber.roughness = 0.18
	_mat_carbon_fiber.clearcoat_enabled = true
	_mat_carbon_fiber.clearcoat = 0.65
	_mat_carbon_fiber.clearcoat_roughness = 0.12

	# 3. Flush Dark-Tinted Canopy Glass
	_mat_glass_tinted = StandardMaterial3D.new()
	_mat_glass_tinted.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_glass_tinted.albedo_color = Color(0.05, 0.07, 0.09, 0.78)
	_mat_glass_tinted.metallic = 0.85
	_mat_glass_tinted.roughness = 0.06

	# 4. Matte Black Aero & Underbody Trim
	_mat_dark_trim = StandardMaterial3D.new()
	_mat_dark_trim.albedo_color = Color(0.06, 0.06, 0.07)
	_mat_dark_trim.metallic = 0.10
	_mat_dark_trim.roughness = 0.72

	# 5. Polished Stainless Cannon Exhaust
	_mat_chrome_exhaust = StandardMaterial3D.new()
	_mat_chrome_exhaust.albedo_color = Color(0.92, 0.90, 0.86)
	_mat_chrome_exhaust.metallic = 0.96
	_mat_chrome_exhaust.roughness = 0.12

	# 6. Forged 17-Inch Alloy Wheel
	_mat_alloy_wheel = StandardMaterial3D.new()
	_mat_alloy_wheel.albedo_color = wheel_finish
	_mat_alloy_wheel.metallic = 0.82
	_mat_alloy_wheel.roughness = 0.24

	# 7. Potenza Semi-Slick Tire Rubber
	_mat_tire_rubber = StandardMaterial3D.new()
	_mat_tire_rubber.albedo_color = Color(0.08, 0.08, 0.09)
	_mat_tire_rubber.metallic = 0.05
	_mat_tire_rubber.roughness = 0.85

	# 8. Cross-Drilled Cast Iron Brake Rotor (with Thermal Glow Emission)
	_mat_brake_rotor = StandardMaterial3D.new()
	_mat_brake_rotor.albedo_color = Color(0.55, 0.56, 0.58)
	_mat_brake_rotor.metallic = 0.88
	_mat_brake_rotor.roughness = 0.32
	_mat_brake_rotor.emission_enabled = true
	_mat_brake_rotor.emission = Color(1.0, 0.18, 0.02)
	_mat_brake_rotor.emission_energy_multiplier = 0.0

	# 9. Brembo Red Multi-Piston Caliper
	_mat_brembo_caliper = StandardMaterial3D.new()
	_mat_brembo_caliper.albedo_color = caliper_color
	_mat_brembo_caliper.metallic = 0.25
	_mat_brembo_caliper.roughness = 0.25
	_mat_brembo_caliper.clearcoat_enabled = true
	_mat_brembo_caliper.clearcoat = 0.5

	# 10. Smoked Rear Center Taillight Garnish
	_mat_taillight_smoked_housing = StandardMaterial3D.new()
	_mat_taillight_smoked_housing.albedo_color = Color(0.04, 0.02, 0.02)
	_mat_taillight_smoked_housing.metallic = 0.45
	_mat_taillight_smoked_housing.roughness = 0.14

	# 11. 99-Spec Circular Halo LED Taillight Rings
	_mat_taillight_halo = StandardMaterial3D.new()
	_mat_taillight_halo.albedo_color = Color(1.0, 0.05, 0.02)
	_mat_taillight_halo.emission_enabled = true
	_mat_taillight_halo.emission = Color(1.0, 0.08, 0.02)
	_mat_taillight_halo.emission_energy_multiplier = 3.5

	# 12. Reverse Backup Lamps
	_mat_reverse_lamp = StandardMaterial3D.new()
	_mat_reverse_lamp.albedo_color = Color(0.85, 0.90, 0.95)
	_mat_reverse_lamp.roughness = 0.2
	_mat_reverse_lamp.emission_enabled = false
	_mat_reverse_lamp.emission = Color(0.95, 0.98, 1.0)

	# 13. Projector Headlight Lens
	_mat_headlight_beam = StandardMaterial3D.new()
	_mat_headlight_beam.albedo_color = Color(0.9, 0.95, 1.0)
	_mat_headlight_beam.emission_enabled = true
	_mat_headlight_beam.emission = Color(0.88, 0.94, 1.0)
	_mat_headlight_beam.emission_energy_multiplier = 2.8

	# 14. Amber Front Bumper Turn Signals
	_mat_amber_signal = StandardMaterial3D.new()
	_mat_amber_signal.albedo_color = Color(1.0, 0.48, 0.0)
	_mat_amber_signal.emission_enabled = true
	_mat_amber_signal.emission = Color(1.0, 0.45, 0.0)
	_mat_amber_signal.emission_energy_multiplier = 1.6

	# 15. Front-Mount Intercooler Aluminum Core
	_mat_intercooler = StandardMaterial3D.new()
	_mat_intercooler.albedo_color = Color(0.75, 0.78, 0.82)
	_mat_intercooler.metallic = 0.90
	_mat_intercooler.roughness = 0.38


# ==============================================================================
# MASTER PROCEDURAL ASSEMBLY
# ==============================================================================

func _build_entire_fd3s_car() -> void:
	_body_root = Node3D.new()
	_body_root.name = "FD3S_Bodywork_Root"
	add_child(_body_root)

	# 1. Sculpted Coke-Bottle Body & Double-Bubble Canopy Loft
	var main_body_mesh: ArrayMesh = _generate_coke_bottle_chassis_loft()
	var body_instance := MeshInstance3D.new()
	body_instance.name = "Curved_Monocoque_Shell"
	body_instance.mesh = main_body_mesh
	body_instance.material_override = _mat_body_paint
	_body_root.add_child(body_instance)

	# 2. Flush Tinted Canopy Glasshouse & Pillars
	var glass_mesh: ArrayMesh = _generate_canopy_glass_loft()
	var glass_instance := MeshInstance3D.new()
	glass_instance.name = "Flush_Canopy_Glasshouse"
	glass_instance.mesh = glass_mesh
	glass_instance.material_override = _mat_glass_tinted
	_body_root.add_child(glass_instance)

	# 3. 99-Spec Front Fascia, FMIC Intercooler, Splitter & Pop-Up Headlights
	_build_front_fascia_and_aero(_body_root)

	# 4. Rear Smoked Taillight Bar, RE-Amemiya Diffuser & Cannon Exhaust
	_build_rear_fascia_diffuser_and_exhaust(_body_root)

	# 5. RE-Amemiya Curved High-Mount Carbon GT Wing
	_build_re_amemiya_gt_wing(_body_root)

	# 6. Aero Mirrors, Side Skirts & Fender Vents
	_build_side_aero_and_details(_body_root)

	# 7. 17-Inch Forged Double-Spoke Wheels & Brembo Brake Assemblies
	_build_wheels_and_brakes()


# ==============================================================================
# LOFTED SURFACE GENERATOR: COKE-BOTTLE BODYWORK & DOUBLE-BUBBLE ROOF
# ==============================================================================

func _generate_coke_bottle_chassis_loft() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Cross-sections from Front Nose (-2.14m) to Rear Tail (+2.14m)
	# Format: [z_pos, bottom_y, lower_half_w, fender_crest_y, max_half_w, hood_belt_y, roof_y, roof_half_w, bubble_dip]
	var stations: Array = [
		[-2.14, 0.17, 0.66, 0.42, 0.72, 0.50, 0.50, 0.48, 0.00], # Front Aero Nose Tip
		[-1.95, 0.14, 0.78, 0.54, 0.84, 0.62, 0.62, 0.62, 0.00], # Front Air Dam Shoulder
		[-1.50, 0.14, 0.82, 0.68, 0.88, 0.73, 0.73, 0.70, 0.00], # Front Wheel Arch Swell (Blister)
		[-1.08, 0.13, 0.82, 0.72, 0.87, 0.77, 0.77, 0.71, 0.00], # Front Fender Peak
		[-0.62, 0.13, 0.79, 0.74, 0.83, 0.82, 0.84, 0.70, 0.00], # Base of A-Pillar / Cowl
		[-0.12, 0.13, 0.77, 0.73, 0.81, 0.84, 1.21, 0.57, 0.032], # Mid Door Pinch (Coke-Bottle Narrowing + Double Bubble)
		[ 0.42, 0.13, 0.79, 0.76, 0.85, 0.86, 1.23, 0.55, 0.035], # B-Pillar / Rear Quarter Haunch Rise
		[ 0.98, 0.14, 0.83, 0.80, 0.89, 0.89, 1.08, 0.54, 0.015], # Muscular Rear Fender Flare (1.78m wide)
		[ 1.45, 0.15, 0.83, 0.79, 0.88, 0.88, 0.93, 0.58, 0.00], # Rear Wheel Arch Trailing Swell
		[ 1.88, 0.21, 0.78, 0.74, 0.83, 0.85, 0.86, 0.64, 0.00], # Rear Decklid Taper
		[ 2.13, 0.28, 0.70, 0.68, 0.76, 0.81, 0.82, 0.60, 0.00]  # Integrated Ducktail Kammback Tail
	]

	var rings: Array = []
	for s in stations:
		rings.append(_build_symmetrical_ring(s))

	for r_idx in range(rings.size() - 1):
		var ring_a: Array = rings[r_idx]
		var ring_b: Array = rings[r_idx + 1]
		var pt_count: int = ring_a.size()
		for i in range(pt_count - 1):
			var p00: Vector3 = ring_a[i]
			var p01: Vector3 = ring_a[i + 1]
			var p10: Vector3 = ring_b[i]
			var p11: Vector3 = ring_b[i + 1]

			st.add_vertex(p00)
			st.add_vertex(p10)
			st.add_vertex(p11)

			st.add_vertex(p00)
			st.add_vertex(p11)
			st.add_vertex(p01)

	# Cap front and rear bulkheads
	_cap_ring_polygon(st, rings[0], true)
	_cap_ring_polygon(st, rings[rings.size() - 1], false)

	st.generate_normals()
	return st.commit()


func _build_symmetrical_ring(s: Array) -> Array:
	var z: float = s[0]
	var bot_y: float = s[1]
	var low_w: float = s[2]
	var crest_y: float = s[3]
	var max_w: float = s[4]
	var belt_y: float = s[5]
	var roof_y: float = s[6]
	var roof_w: float = s[7]
	var bubble: float = s[8]

	# Construct points from bottom-center -> right side -> roof double-bubble -> left side -> bottom-center
	var pts: Array = [
		Vector3(0.0, bot_y, z),
		Vector3(low_w * 0.65, bot_y, z),
		Vector3(low_w, bot_y + 0.07, z),
		Vector3(max_w, crest_y, z),
		Vector3(max_w * 0.94, belt_y, z),
		Vector3(roof_w, roof_y - bubble * 0.3, z),
		Vector3(roof_w * 0.52, roof_y + bubble, z), # Right Double-Bubble Crown
		Vector3(0.0, roof_y - bubble * 0.65, z),    # Center Roof Channel Valley
		Vector3(-roof_w * 0.52, roof_y + bubble, z),# Left Double-Bubble Crown
		Vector3(-roof_w, roof_y - bubble * 0.3, z),
		Vector3(-max_w * 0.94, belt_y, z),
		Vector3(-max_w, crest_y, z),
		Vector3(-low_w, bot_y + 0.07, z),
		Vector3(-low_w * 0.65, bot_y, z),
		Vector3(0.0, bot_y, z)
	]
	return pts


func _generate_canopy_glass_loft() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Glasshouse stations covering windshield, side windows, and curved rear fastback hatch glass
	var glass_stations: Array = [
		[-0.66, 0.81, 0.72, 0.83, 0.68], # Windshield Cowl Base
		[-0.14, 0.83, 0.76, 1.19, 0.56], # Windshield Header / A-Pillar Top
		[ 0.44, 0.85, 0.78, 1.21, 0.54], # B-Pillar Canopy Peak
		[ 1.12, 0.87, 0.75, 1.07, 0.53], # C-Pillar Fastback Glass Curve
		[ 1.78, 0.85, 0.65, 0.87, 0.56]  # Rear Hatch Glass Lower Lip
	]

	var rings: Array = []
	for gs in glass_stations:
		var z: float = gs[0]
		var belt_y: float = gs[1]
		var belt_w: float = gs[2]
		var top_y: float = gs[3]
		var top_w: float = gs[4]
		rings.append([
			Vector3(belt_w, belt_y, z),
			Vector3(top_w, top_y, z),
			Vector3(0.0, top_y + 0.015, z),
			Vector3(-top_w, top_y, z),
			Vector3(-belt_w, belt_y, z)
		])

	for r_idx in range(rings.size() - 1):
		var ra: Array = rings[r_idx]
		var rb: Array = rings[r_idx + 1]
		for i in range(ra.size() - 1):
			st.add_vertex(ra[i])
			st.add_vertex(rb[i])
			st.add_vertex(rb[i + 1])

			st.add_vertex(ra[i])
			st.add_vertex(rb[i + 1])
			st.add_vertex(ra[i + 1])

	st.generate_normals()
	return st.commit()


func _cap_ring_polygon(st: SurfaceTool, ring: Array, invert: bool) -> void:
	var center := Vector3.ZERO
	for p in ring:
		center += p
	center /= float(ring.size())

	for i in range(ring.size() - 1):
		if invert:
			st.add_vertex(center)
			st.add_vertex(ring[i + 1])
			st.add_vertex(ring[i])
		else:
			st.add_vertex(center)
			st.add_vertex(ring[i])
			st.add_vertex(ring[i + 1])


# ==============================================================================
# FRONT FASCIA, 99-SPEC AIR DAM, INTERCOOLER & POP-UP HEADLIGHTS
# ==============================================================================

func _build_front_fascia_and_aero(parent: Node3D) -> void:
	var front_group := Node3D.new()
	front_group.name = "Front_Fascia_99Spec"
	parent.add_child(front_group)

	# Carbon Front Lower Lip Spoiler / Splitter
	_create_box_instance(
		front_group, "Carbon_Front_Splitter",
		Vector3(1.66, 0.045, 0.36),
		Vector3(0.0, 0.125, -2.02),
		Vector3.ZERO, _mat_carbon_fiber
	)

	# Deep Central Radiator / FMIC Mouth Cavity
	_create_box_instance(
		front_group, "Front_Air_Dam_Mouth",
		Vector3(0.88, 0.24, 0.14),
		Vector3(0.0, 0.27, -2.09),
		Vector3.ZERO, _mat_dark_trim
	)

	# V-Mount / Front-Mount Intercooler Core & End-Tanks
	_create_box_instance(
		front_group, "FMIC_Aluminum_Core",
		Vector3(0.72, 0.20, 0.08),
		Vector3(0.0, 0.27, -2.05),
		Vector3(deg_to_rad(12.0), 0.0, 0.0), _mat_intercooler
	)

	# Twin Lateral Oil Cooler Ducts (Left & Right)
	for side in [-1.0, 1.0]:
		_create_box_instance(
			front_group, "Oil_Cooler_Duct",
			Vector3(0.28, 0.16, 0.12),
			Vector3(side * 0.61, 0.25, -2.04),
			Vector3(0.0, side * deg_to_rad(-14.0), 0.0), _mat_dark_trim
		)
		# 99-Spec Amber Combination Turn Signal Lamps
		_create_box_instance(
			front_group, "Amber_Turn_Signal",
			Vector3(0.24, 0.075, 0.08),
			Vector3(side * 0.61, 0.41, -2.03),
			Vector3(0.0, side * deg_to_rad(-14.0), 0.0), _mat_amber_signal
		)

	# Vented Carbon Fiber Hood Louver Insert
	_create_box_instance(
		front_group, "Carbon_Hood_Heat_Extractor",
		Vector3(0.64, 0.025, 0.42),
		Vector3(0.0, 0.72, -1.28),
		Vector3(deg_to_rad(8.5), 0.0, 0.0), _mat_carbon_fiber
	)

	# Pop-Up / Sleek Projector Headlight Pods
	_pop_up_Left = _create_popup_headlight_unit(front_group, -1.0)
	_pop_up_Right = _create_popup_headlight_unit(front_group, 1.0)


func _create_popup_headlight_unit(parent: Node3D, side: float) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = "Headlight_Pivot_" + ("L" if side < 0.0 else "R")
	pivot.position = Vector3(side * 0.56, 0.63, -1.68)
	parent.add_child(pivot)

	# Painted Flip Cover Lid
	_create_box_instance(
		pivot, "Popup_Cover_Lid",
		Vector3(0.28, 0.04, 0.30),
		Vector3(0.0, 0.02, -0.12),
		Vector3(deg_to_rad(10.0), 0.0, 0.0), _mat_body_paint
	)
	# Black Projector Housing Bezel
	_create_box_instance(
		pivot, "Projector_Housing",
		Vector3(0.26, 0.11, 0.24),
		Vector3(0.0, -0.04, -0.12),
		Vector3.ZERO, _mat_dark_trim
	)
	# Glowing Dual Projector Lens
	_create_box_instance(
		pivot, "Projector_Lens_Beam",
		Vector3(0.23, 0.08, 0.04),
		Vector3(0.0, -0.04, -0.24),
		Vector3.ZERO, _mat_headlight_beam
	)
	return pivot


# ==============================================================================
# REAR FASCIA, SMOKED HALO TAILLIGHTS, DIFFUSER & CANNON EXHAUST
# ==============================================================================

func _build_rear_fascia_diffuser_and_exhaust(parent: Node3D) -> void:
	var rear_group := Node3D.new()
	rear_group.name = "Rear_Fascia_Group"
	parent.add_child(rear_group)

	# Full-Width Smoked Acrylic Taillight Bar
	_create_box_instance(
		rear_group, "Smoked_Taillight_Bar",
		Vector3(1.52, 0.15, 0.08),
		Vector3(0.0, 0.72, 2.11),
		Vector3(deg_to_rad(-6.0), 0.0, 0.0), _mat_taillight_smoked_housing
	)

	# 99-Spec Circular Glowing LED Halo Rings (Quad Round Signature)
	for side in [-1.0, 1.0]:
		# Outer Brake/Tail Halo Ring
		_create_cylinder_instance(
			rear_group, "Outer_Halo_Ring",
			0.055, 0.055, 0.04, 20,
			Vector3(side * 0.56, 0.72, 2.14),
			Vector3(deg_to_rad(90.0), 0.0, 0.0), _mat_taillight_halo
		)
		# Inner Brake/Tail Halo Ring
		_create_cylinder_instance(
			rear_group, "Inner_Halo_Ring",
			0.050, 0.050, 0.04, 20,
			Vector3(side * 0.41, 0.72, 2.14),
			Vector3(deg_to_rad(90.0), 0.0, 0.0), _mat_taillight_halo
		)
		# Amber Rear Turn Signal Circle
		_create_cylinder_instance(
			rear_group, "Rear_Amber_Signal",
			0.036, 0.036, 0.04, 16,
			Vector3(side * 0.68, 0.72, 2.13),
			Vector3(deg_to_rad(90.0), 0.0, 0.0), _mat_amber_signal
		)
		# White Reverse Backup Lamp
		_create_box_instance(
			rear_group, "Reverse_Backup_Lamp",
			Vector3(0.09, 0.05, 0.04),
			Vector3(side * 0.25, 0.72, 2.14),
			Vector3.ZERO, _mat_reverse_lamp
		)

	# RE-Amemiya Pro Underbody Rear Diffuser & Vortex Strakes
	_create_box_instance(
		rear_group, "Rear_Carbon_Diffuser_Tray",
		Vector3(1.56, 0.06, 0.48),
		Vector3(0.0, 0.22, 1.94),
		Vector3(deg_to_rad(9.0), 0.0, 0.0), _mat_carbon_fiber
	)

	for fin_x in [-0.52, -0.26, 0.26, 0.52]:
		_create_box_instance(
			rear_group, "Diffuser_Vortex_Fin",
			Vector3(0.022, 0.14, 0.42),
			Vector3(fin_x, 0.19, 1.98),
			Vector3.ZERO, _mat_carbon_fiber
		)

	# Large Angled Stainless-Steel Cannon Exhaust Muffler (Right-Side JDM Exit)
	var exhaust_node := Node3D.new()
	exhaust_node.name = "Apexi_N1_Cannon_Exhaust"
	exhaust_node.position = Vector3(0.46, 0.23, 2.02)
	exhaust_node.rotation = Vector3(deg_to_rad(6.0), deg_to_rad(11.0), 0.0)
	rear_group.add_child(exhaust_node)

	# Muffler Canister Silencer
	_create_cylinder_instance(
		exhaust_node, "Muffler_Canister",
		0.105, 0.105, 0.42, 24,
		Vector3(0.0, 0.0, -0.10),
		Vector3(deg_to_rad(90.0), 0.0, 0.0), _mat_chrome_exhaust
	)
	# Polished 115mm Exhaust Tip
	_create_cylinder_instance(
		exhaust_node, "Exhaust_Tip_Lip",
		0.068, 0.068, 0.16, 24,
		Vector3(0.0, 0.0, 0.16),
		Vector3(deg_to_rad(90.0), 0.0, 0.0), _mat_chrome_exhaust
	)
	# Dark Inner Exhaust Bore
	_create_cylinder_instance(
		exhaust_node, "Exhaust_Inner_Bore",
		0.060, 0.060, 0.05, 20,
		Vector3(0.0, 0.0, 0.22),
		Vector3(deg_to_rad(90.0), 0.0, 0.0), _mat_dark_trim
	)

	# Rotary Backfire Flame VFX & OmniLight
	_setup_exhaust_backfire_vfx(exhaust_node)


func _setup_exhaust_backfire_vfx(exhaust_mount: Node3D) -> void:
	_exhaust_particles = GPUParticles3D.new()
	_exhaust_particles.name = "Rotary_Backfire_Flames"
	_exhaust_particles.position = Vector3(0.0, 0.0, 0.26)
	_exhaust_particles.emitting = false
	_exhaust_particles.one_shot = true
	_exhaust_particles.amount = 24
	_exhaust_particles.lifetime = 0.18
	_exhaust_particles.explosiveness = 0.92

	var p_mat := ParticleProcessMaterial.new()
	p_mat.direction = Vector3(0.0, 0.05, 1.0)
	p_mat.spread = 14.0
	p_mat.initial_velocity_min = 6.5
	p_mat.initial_velocity_max = 12.0
	p_mat.gravity = Vector3(0.0, 1.5, 0.0)
	p_mat.scale_min = 0.12
	p_mat.scale_max = 0.28
	p_mat.color = Color(1.0, 0.48, 0.08, 0.95)
	_exhaust_particles.process_material = p_mat

	var quad := SphereMesh.new()
	quad.radius = 0.08
	quad.height = 0.16
	var flame_mat := StandardMaterial3D.new()
	flame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flame_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flame_mat.albedo_color = Color(1.0, 0.45, 0.05, 0.85)
	quad.material = flame_mat
	_exhaust_particles.draw_pass_1 = quad
	exhaust_mount.add_child(_exhaust_particles)

	_exhaust_omni_light = OmniLight3D.new()
	_exhaust_omni_light.name = "Backfire_Flash_Light"
	_exhaust_omni_light.position = Vector3(0.0, 0.0, 0.35)
	_exhaust_omni_light.light_color = Color(1.0, 0.42, 0.05)
	_exhaust_omni_light.light_energy = 0.0
	_exhaust_omni_light.omni_range = 3.2
	exhaust_mount.add_child(_exhaust_omni_light)


func _trigger_rotary_backfire() -> void:
	if is_instance_valid(_exhaust_particles):
		_exhaust_particles.restart()
		_exhaust_particles.emitting = true
	if is_instance_valid(_exhaust_omni_light):
		_exhaust_omni_light.light_energy = 4.5
	_active_backfire_pop = 1.0


# ==============================================================================
# RE-AMEMIYA CURVED CARBON GT WING
# ==============================================================================

func _build_re_amemiya_gt_wing(parent: Node3D) -> void:
	var wing_group := Node3D.new()
	wing_group.name = "RE_Amemiya_GT_Wing"
	wing_group.position = Vector3(0.0, 0.84, 1.92)
	parent.add_child(wing_group)

	# 3D Sculpted Curved Carbon Airfoil Blade
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var span_steps: int = 12
	var half_span: float = 0.78
	for i in range(span_steps):
		var t0: float = float(i) / float(span_steps)
		var t1: float = float(i + 1) / float(span_steps)
		var x0: float = lerpf(-half_span, half_span, t0)
		var x1: float = lerpf(-half_span, half_span, t1)

		# Gull-wing curvature across span
		var y0: float = 0.24 + cos(t0 * PI * 2.0 - PI) * 0.025
		var y1: float = 0.24 + cos(t1 * PI * 2.0 - PI) * 0.025
		var z_sweep0: float = absf(x0) * 0.10
		var z_sweep1: float = absf(x1) * 0.10

		var p0_front := Vector3(x0, y0, -0.12 + z_sweep0)
		var p0_rear := Vector3(x0, y0 + 0.038, 0.14 + z_sweep0)
		var p1_front := Vector3(x1, y1, -0.12 + z_sweep1)
		var p1_rear := Vector3(x1, y1 + 0.038, 0.14 + z_sweep1)

		# Top surface
		st.add_vertex(p0_front)
		st.add_vertex(p1_front)
		st.add_vertex(p1_rear)

		st.add_vertex(p0_front)
		st.add_vertex(p1_rear)
		st.add_vertex(p0_rear)

		# Bottom surface
		var thick := Vector3(0.0, -0.022, 0.0)
		st.add_vertex(p0_front + thick)
		st.add_vertex(p1_rear + thick)
		st.add_vertex(p1_front + thick)

		st.add_vertex(p0_front + thick)
		st.add_vertex(p0_rear + thick)
		st.add_vertex(p1_rear + thick)

	st.generate_normals()
	var airfoil_inst := MeshInstance3D.new()
	airfoil_inst.name = "Carbon_Airfoil_Element"
	airfoil_inst.mesh = st.commit()
	airfoil_inst.material_override = _mat_carbon_fiber
	wing_group.add_child(airfoil_inst)

	# Aluminum Gooseneck Stanchion Uprights & Carbon Endplates
	for side in [-1.0, 1.0]:
		_create_box_instance(
			wing_group, "Aluminum_Wing_Stanchion",
			Vector3(0.018, 0.25, 0.16),
			Vector3(side * 0.44, 0.11, 0.02),
			Vector3(deg_to_rad(-14.0), 0.0, side * deg_to_rad(5.0)), _mat_alloy_wheel
		)
		_create_box_instance(
			wing_group, "Carbon_Wing_Endplate",
			Vector3(0.016, 0.15, 0.32),
			Vector3(side * half_span, 0.23, 0.08),
			Vector3(deg_to_rad(-8.0), 0.0, 0.0), _mat_carbon_fiber
		)


# ==============================================================================
# SIDE SKIRTS, AERO MIRRORS & FENDER VENTS
# ==============================================================================

func _build_side_aero_and_details(parent: Node3D) -> void:
	for side in [-1.0, 1.0]:
		# Feed-Style Carbon Side Skirt Step
		_create_box_instance(
			parent, "Carbon_Side_Skirt",
			Vector3(0.08, 0.055, 1.62),
			Vector3(side * 0.85, 0.14, 0.0),
			Vector3.ZERO, _mat_carbon_fiber
		)
		# Front Fender Brake Heat Extractor Vent
		_create_box_instance(
			parent, "Fender_Extractor_Vent",
			Vector3(0.04, 0.16, 0.22),
			Vector3(side * 0.85, 0.44, -0.88),
			Vector3(0.0, side * deg_to_rad(8.0), 0.0), _mat_dark_trim
		)
		# Ganador-Style Sleek Aero Wing Mirrors
		_create_box_instance(
			parent, "Aero_Side_Mirror",
			Vector3(0.18, 0.075, 0.14),
			Vector3(side * 0.86, 0.86, -0.44),
			Vector3(0.0, side * deg_to_rad(-18.0), side * deg_to_rad(6.0)), _mat_carbon_fiber
		)
		# Flush Vertical Door Handle Integrated in B-Pillar
		_create_box_instance(
			parent, "Flush_Pillar_Door_Handle",
			Vector3(0.02, 0.11, 0.05),
			Vector3(side * 0.77, 0.94, 0.36),
			Vector3.ZERO, _mat_dark_trim
		)


# ==============================================================================
# 17-INCH FORGED 5-DOUBLE-SPOKE WHEELS & BREMBO BRAKE ASSEMBLIES
# ==============================================================================

func _build_wheels_and_brakes() -> void:
	_wheel_pivots.clear()
	_wheel_spinners.clear()
	_brake_rotors.clear()

	var half_wb: float = WHEELBASE * 0.5
	var wheel_coords: Array = [
		Vector3(-FRONT_TRACK * 0.5, WHEEL_RADIUS, -half_wb), # Front Left
		Vector3( FRONT_TRACK * 0.5, WHEEL_RADIUS, -half_wb), # Front Right
		Vector3(-REAR_TRACK * 0.5,  WHEEL_RADIUS,  half_wb), # Rear Left
		Vector3( REAR_TRACK * 0.5,  WHEEL_RADIUS,  half_wb)  # Rear Right
	]

	for idx in range(4):
		var is_left: bool = (idx % 2 == 0)
		var out_sign: float = -1.0 if is_left else 1.0

		# 1. Steering Pivot Node (Caliper stays fixed in rotation X to pivot)
		var pivot := Node3D.new()
		pivot.name = "Wheel_Pivot_" + str(idx)
		pivot.position = wheel_coords[idx]
		add_child(pivot)
		_wheel_pivots.append(pivot)

		# Fixed Red Brembo 4-Piston Caliper
		var caliper_z_offset: float = 0.11 if idx < 2 else -0.11
		_create_box_instance(
			pivot, "Brembo_4Pot_Caliper",
			Vector3(0.075, 0.15, 0.085),
			Vector3(out_sign * 0.04, 0.04, caliper_z_offset),
			Vector3(deg_to_rad(-22.0 * signf(caliper_z_offset)), 0.0, 0.0),
			_mat_brembo_caliper
		)

		# 2. Rotating Wheel & Brake Rotor Spinner Node
		var spinner := Node3D.new()
		spinner.name = "Wheel_Spinner_" + str(idx)
		pivot.add_child(spinner)
		_wheel_spinners.append(spinner)

		# Tire Tread Cylinder
		_create_cylinder_instance(
			spinner, "Potenza_Tire_Tread",
			WHEEL_RADIUS, WHEEL_RADIUS, 0.245, 28,
			Vector3.ZERO,
			Vector3(0.0, 0.0, deg_to_rad(90.0)), _mat_tire_rubber
		)

		# Outer & Inner Alloy Rim Barrel Lips
		_create_cylinder_instance(
			spinner, "Forged_Rim_Barrel",
			0.228, 0.228, 0.252, 28,
			Vector3.ZERO,
			Vector3(0.0, 0.0, deg_to_rad(90.0)), _mat_alloy_wheel
		)

		# Dark Recessed Wheel Well Inner Barrel
		_create_cylinder_instance(
			spinner, "Wheel_Inner_Cavity",
			0.212, 0.212, 0.255, 24,
			Vector3.ZERO,
			Vector3(0.0, 0.0, deg_to_rad(90.0)), _mat_dark_trim
		)

		# Center Forged Hub Cap
		_create_cylinder_instance(
			spinner, "Wheel_Center_Hub",
			0.058, 0.058, 0.05, 16,
			Vector3(out_sign * 0.095, 0.0, 0.0),
			Vector3(0.0, 0.0, deg_to_rad(90.0)), _mat_alloy_wheel
		)

		# 5 Twin-Spokes (10 Spoke Blades Total)
		for s_i in range(5):
			var base_angle: float = float(s_i) * (TAU / 5.0)
			for sub in [-1.0, 1.0]:
				var spoke_angle: float = base_angle + (sub * 0.14)
				var mid_r: float = 0.135
				var pos_y: float = cos(spoke_angle) * mid_r
				var pos_z: float = sin(spoke_angle) * mid_r
				_create_box_instance(
					spinner, "Twin_Spoke_Blade",
					Vector3(0.022, 0.165, 0.018),
					Vector3(out_sign * 0.098, pos_y, pos_z),
					Vector3(spoke_angle, 0.0, 0.0),
					_mat_alloy_wheel
				)

		# Cross-Drilled Ventilated Brake Rotor Disc
		var rotor := _create_cylinder_instance(
			spinner, "Ventilated_Brake_Rotor",
			0.168, 0.168, 0.026, 24,
			Vector3(out_sign * 0.035, 0.0, 0.0),
			Vector3(0.0, 0.0, deg_to_rad(90.0)), _mat_brake_rotor
		)
		_brake_rotors.append(rotor)


# ==============================================================================
# 13B-REW SEQUENTIAL TWIN-TURBO PROCEDURAL AUDIO SYNTHESIZER
# ==============================================================================

func _setup_13b_rotary_audio() -> void:
	_engine_audio_player = AudioStreamPlayer3D.new()
	_engine_audio_player.name = "Rotary_13B_REW_Synthesizer"
	_engine_audio_player.position = Vector3(0.0, 0.45, 1.65)
	_engine_audio_player.unit_size = 8.0
	_engine_audio_player.max_db = 3.0

	var gen_stream := AudioStreamGenerator.new()
	gen_stream.mix_rate = 22050.0
	gen_stream.buffer_length = 0.12
	_engine_audio_player.stream = gen_stream
	add_child(_engine_audio_player)

	if is_inside_tree():
		_engine_audio_player.play()
		_engine_playback = _engine_audio_player.get_stream_playback() as AudioStreamGeneratorPlayback


func _synthesize_rotary_audio_buffer(_delta: float) -> void:
	if not is_instance_valid(_engine_audio_player):
		return
	if not _engine_audio_player.playing:
		if is_inside_tree():
			_engine_audio_player.play()
			_engine_playback = _engine_audio_player.get_stream_playback() as AudioStreamGeneratorPlayback
		return
	if _engine_playback == null:
		_engine_playback = _engine_audio_player.get_stream_playback() as AudioStreamGeneratorPlayback
		if _engine_playback == null:
			return

	var frames_available: int = _engine_playback.get_frames_available()
	if frames_available <= 0:
		return

	var sample_rate: float = 22050.0
	# 13B Wankel dual-rotor fires 3 combustion pulses per output shaft revolution
	var fundamental_hz: float = (_current_synth_rpm / 60.0) * 1.5
	var secondary_hz: float = fundamental_hz * 2.0
	var turbo_whine_hz: float = 1600.0 + clampf(current_boost_bar, 0.0, 1.0) * 3200.0 + (900.0 if is_secondary_turbo_online else 0.0)

	for _i in range(frames_available):
		_rotary_phase_primary = fmod(_rotary_phase_primary + (fundamental_hz / sample_rate), 1.0)
		_rotary_phase_secondary = fmod(_rotary_phase_secondary + (secondary_hz / sample_rate), 1.0)
		_turbo_whine_phase = fmod(_turbo_whine_phase + (turbo_whine_hz / sample_rate), 1.0)

		# Bridge-port / street-port idle brap lope modulation below 1350 RPM
		var brap_mod: float = 1.0
		if _current_synth_rpm < 1350.0:
			brap_mod = 0.65 + 0.35 * sin(Time.get_ticks_msec() * 0.038)

		# Crisp sawtooth + metallic harmonic rasp characteristic of 13B-REW rotary
		var saw_primary: float = (_rotary_phase_primary * 2.0 - 1.0) * 0.40
		var rasp_harmonic: float = sin(_rotary_phase_secondary * TAU) * 0.32 + sin(_rotary_phase_secondary * TAU * 1.5) * 0.18
		var rotary_core: float = tanh((saw_primary + rasp_harmonic) * 1.8) * brap_mod

		# Sequential Twin-Turbo Compressor Whine
		var turbo_amp: float = clampf(current_boost_bar, 0.0, 1.0) * (0.16 if is_secondary_turbo_online else 0.09)
		var turbo_whine: float = sin(_turbo_whine_phase * TAU) * turbo_amp

		# Sequential BOV Compressor Flutter ("utututu" chatter on lift-off)
		var bov_sample: float = 0.0
		if _bov_flutter_timer > 0.0:
			_bov_phase += 1.0 / sample_rate
			var flutter_envelope: float = absf(sin(_bov_phase * 58.0)) * (_bov_flutter_timer / 0.55)
			var hiss_carrier: float = sin(_bov_phase * 2900.0) * 0.5 + sin(_bov_phase * 4300.0) * 0.5
			bov_sample = hiss_carrier * flutter_envelope * 0.38

		# Exhaust Overrun Backfire Pop Impulse
		var pop_sample: float = 0.0
		if _active_backfire_pop > 0.01:
			pop_sample = (randf() * 2.0 - 1.0) * _active_backfire_pop * 0.85
			_active_backfire_pop *= 0.9965

		var final_mono: float = clampf((rotary_core * 0.55) + turbo_whine + bov_sample + pop_sample, -0.95, 0.95)
		_engine_playback.push_frame(Vector2(final_mono, final_mono))


# ==============================================================================
# PRIMITIVE GEOMETRY HELPER BUILDERS
# ==============================================================================

func _create_box_instance(
	parent: Node3D,
	node_name: String,
	size: Vector3,
	pos: Vector3,
	rot: Vector3,
	mat: Material
) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.name = node_name
	var bm := BoxMesh.new()
	bm.size = size
	inst.mesh = bm
	inst.position = pos
	inst.rotation = rot
	inst.material_override = mat
	parent.add_child(inst)
	return inst


func _create_cylinder_instance(
	parent: Node3D,
	node_name: String,
	top_r: float,
	bot_r: float,
	height: float,
	radial_segs: int,
	pos: Vector3,
	rot: Vector3,
	mat: Material
) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.name = node_name
	var cm := CylinderMesh.new()
	cm.top_radius = top_r
	cm.bottom_radius = bot_r
	cm.height = height
	cm.radial_segments = radial_segs
	cm.rings = 1
	inst.mesh = cm
	inst.position = pos
	inst.rotation = rot
	inst.material_override = mat
	parent.add_child(inst)
	return inst