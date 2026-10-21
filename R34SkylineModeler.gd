@tool
class_name R34SkylineModeler
extends Node3D

# ==============================================================================
# R34SkylineModeler.gd - Complete Procedural 1999 Nissan Skyline GT-R BNR34
# Nismo Z-Tune Specification | Cel-Shaded Cyber-Anime & Manga Ink Edition
# Target Engine: Godot 4.3 (Vulkan Forward+)
# ==============================================================================

# --- MANDATORY PHYSICS SUSPENSION ANCHORS ---
var WheelFL: Node3D
var WheelFR: Node3D
var WheelRL: Node3D
var WheelRR: Node3D

# --- EXPORTED CONFIGURATION & STATE PROPERTIES (WITH RECURSION GUARDS) ---
@export_group("Vehicle State")
var _is_braking: bool = false
@export var is_braking: bool:
	get:
		return _is_braking
	set(value):
		if _is_braking == value:
			return
		_is_braking = value
		_update_lighting_state()

var _is_reversing: bool = false
@export var is_reversing: bool:
	get:
		return _is_reversing
	set(value):
		if _is_reversing == value:
			return
		_is_reversing = value
		_update_lighting_state()

var _headlights_on: bool = true
@export var headlights_on: bool = true:
	get:
		return _headlights_on
	set(value):
		if _headlights_on == value:
			return
		_headlights_on = value
		_update_lighting_state()

@export_group("Aesthetic Customization")
var _paint_color: Color = Color(0.02, 0.28, 0.85) # Iconic Bayside Blue (TV2)
@export var paint_color: Color = Color(0.02, 0.28, 0.85):
	get:
		return _paint_color
	set(value):
		if _paint_color == value:
			return
		_paint_color = value
		if _mat_car_paint:
			_mat_car_paint.set_shader_parameter("albedo_color", _paint_color)

var _rim_color: Color = Color(0.18, 0.15, 0.12) # Nismo Satin Bronze / Gunmetal
@export var rim_color: Color = Color(0.18, 0.15, 0.12):
	get:
		return _rim_color
	set(value):
		if _rim_color == value:
			return
		_rim_color = value
		if _mat_wheel_spoke:
			_mat_wheel_spoke.albedo_color = _rim_color

@export var rebuild_trigger: bool = false:
	set(value):
		if value:
			build_vehicle_mesh()
		rebuild_trigger = false

# --- CORE DIMENSIONS (METERS) ---
const WHEELBASE: float = 2.665
const FRONT_AXLE_Z: float = -1.3325
const REAR_AXLE_Z: float = 1.3325
const TRACK_WIDTH: float = 1.510
const HALF_TRACK: float = 0.755
const WHEEL_RADIUS: float = 0.330
const WHEEL_WIDTH: float = 0.250

# --- INTERNAL SHADER & MATERIAL REFERENCES ---
var _mat_car_paint: ShaderMaterial
var _mat_carbon_fiber: ShaderMaterial
var _mat_black_trim: StandardMaterial3D
var _mat_chrome: StandardMaterial3D
var _mat_titanium_burnt: ShaderMaterial
var _mat_glass_smoked: StandardMaterial3D
var _mat_headlight_glass: StandardMaterial3D
var _mat_halo_cyan: StandardMaterial3D
var _mat_headlight_core: StandardMaterial3D
var _mat_taillight_ring_outer: StandardMaterial3D
var _mat_taillight_ring_inner: StandardMaterial3D
var _mat_reverse_light: StandardMaterial3D
var _mat_turn_signal: StandardMaterial3D
var _mat_fmic_core: StandardMaterial3D
var _mat_wheel_spoke: StandardMaterial3D
var _mat_wheel_lip: StandardMaterial3D
var _mat_tire_rubber: StandardMaterial3D
var _mat_tire_sidewall: StandardMaterial3D
var _mat_brembo_caliper: StandardMaterial3D
var _mat_brake_rotor: StandardMaterial3D
var _mat_interior_dark: StandardMaterial3D
var _mat_recaro_red: StandardMaterial3D
var _mat_roll_cage: StandardMaterial3D
var _mat_mfd_screen: StandardMaterial3D
var _mat_gauge_cluster: StandardMaterial3D
var _mat_manga_smoke: ShaderMaterial
var _mat_wind_streamer: ShaderMaterial

# --- DYNAMIC NODE REFERENCES FOR VFX & LIGHTING ---
var _spot_headlight_l: SpotLight3D
var _spot_headlight_r: SpotLight3D
var _omni_taillight_l: OmniLight3D
var _omni_taillight_r: OmniLight3D
var _omni_backfire: OmniLight3D
var _particles_backfire_cyan: GPUParticles3D
var _particles_backfire_magenta: GPUParticles3D
var _particles_smoke_rl: GPUParticles3D
var _particles_smoke_rr: GPUParticles3D
var _particles_streamer_wing_l: GPUParticles3D
var _particles_streamer_wing_r: GPUParticles3D
var _particles_streamer_mirror_l: GPUParticles3D
var _particles_streamer_mirror_r: GPUParticles3D

var _current_brake_heat: float = 0.0
var _backfire_timer: float = 0.0

# ==============================================================================
# LIFECYCLE
# ==============================================================================
func _ready() -> void:
	build_vehicle_mesh()

func _process(delta: float) -> void:
	if _backfire_timer > 0.0:
		_backfire_timer -= delta
		if _omni_backfire:
			_omni_backfire.light_energy = maxf(0.0, (_backfire_timer / 0.16) * 8.5)
		if _backfire_timer <= 0.0 and _omni_backfire:
			_omni_backfire.visible = false

# ==============================================================================
# PUBLIC API
# ==============================================================================
func build_vehicle_mesh() -> Node3D:
	# Clean all existing procedural children safely
	for child in get_children():
		remove_child(child)
		child.queue_free()

	_init_materials_and_shaders()

	var chassis_root := Node3D.new()
	chassis_root.name = "ChassisRoot"
	add_child(chassis_root)

	# 1. Build Lofted Nismo Z-Tune Unibody & Blister Fenders
	_build_body_shell(chassis_root)

	# 2. Build Z-Tune Carbon Aero, Vented Hood, FMIC, Diffuser, & GT Wing
	_build_aero_and_details(chassis_root)

	# 3. Build Cyber Neon "Godzilla Eyes" Headlights & Angel Eye Halos
	_build_headlights(chassis_root)

	# 4. Build Iconic Quad Round "Godzilla" Taillights
	_build_taillights(chassis_root)

	# 5. Build RHD Japanese Spec Cockpit, MFD Telemetry, & Cusco Roll Cage
	_build_rhd_interior(chassis_root)

	# 6. Build 4 Nismo LMGT4 Wheels & Brembo Brake Assemblies
	WheelFL = _build_wheel_assembly("WheelFL", Vector3(-HALF_TRACK, WHEEL_RADIUS, FRONT_AXLE_Z), true, true)
	WheelFR = _build_wheel_assembly("WheelFR", Vector3(HALF_TRACK, WHEEL_RADIUS, FRONT_AXLE_Z), false, true)
	WheelRL = _build_wheel_assembly("WheelRL", Vector3(-HALF_TRACK, WHEEL_RADIUS, REAR_AXLE_Z), true, false)
	WheelRR = _build_wheel_assembly("WheelRR", Vector3(HALF_TRACK, WHEEL_RADIUS, REAR_AXLE_Z), false, false)

	add_child(WheelFL)
	add_child(WheelFR)
	add_child(WheelRL)
	add_child(WheelRR)

	# 7. Build Exhaust & Authentic Anime VFX Systems
	_build_exhaust_and_vfx(chassis_root)

	# Synchronize initial states
	_update_lighting_state()
	set_brake_heat(0.0)
	set_drift_vfx(false, 0.0)

	return self

func set_brake_heat(heat: float) -> void:
	_current_brake_heat = clampf(heat, 0.0, 1.0)
	if _mat_brake_rotor:
		var glow_factor: float = pow(_current_brake_heat, 1.7) * 7.0
		var base_iron := Color(0.24, 0.25, 0.27)
		var hot_cherry := Color(1.0, 0.18, 0.02)
		_mat_brake_rotor.albedo_color = base_iron.lerp(Color(0.55, 0.15, 0.08), _current_brake_heat)
		_mat_brake_rotor.emission_enabled = _current_brake_heat > 0.02
		_mat_brake_rotor.emission = hot_cherry
		_mat_brake_rotor.emission_energy_multiplier = glow_factor
	_update_lighting_state()

func trigger_backfire() -> void:
	if _particles_backfire_cyan:
		_particles_backfire_cyan.restart()
		_particles_backfire_cyan.emitting = true
	if _particles_backfire_magenta:
		_particles_backfire_magenta.restart()
		_particles_backfire_magenta.emitting = true
	if _omni_backfire:
		_omni_backfire.visible = true
		_omni_backfire.light_energy = 8.5
	_backfire_timer = 0.16

func set_drift_vfx(is_drifting: bool, speed_kmh: float = 100.0) -> void:
	if _particles_smoke_rl:
		_particles_smoke_rl.emitting = is_drifting
	if _particles_smoke_rr:
		_particles_smoke_rr.emitting = is_drifting

	var active_streamers: bool = (is_drifting and speed_kmh > 45.0) or (speed_kmh >= 90.0)
	if _particles_streamer_wing_l:
		_particles_streamer_wing_l.emitting = active_streamers
	if _particles_streamer_wing_r:
		_particles_streamer_wing_r.emitting = active_streamers
	if _particles_streamer_mirror_l:
		_particles_streamer_mirror_l.emitting = active_streamers
	if _particles_streamer_mirror_r:
		_particles_streamer_mirror_r.emitting = active_streamers

# ==============================================================================
# LIGHTING STATE UPDATER
# ==============================================================================
func _update_lighting_state() -> void:
	# Headlights & Cyber Angel Eye Halos
	if _mat_halo_cyan:
		_mat_halo_cyan.emission_energy_multiplier = 7.2 if _headlights_on else 1.2
	if _mat_headlight_core:
		_mat_headlight_core.emission_energy_multiplier = 6.0 if _headlights_on else 0.0
	if _spot_headlight_l:
		_spot_headlight_l.visible = _headlights_on
	if _spot_headlight_r:
		_spot_headlight_r.visible = _headlights_on

	# Godzilla Quad Round Taillights
	var brake_active: bool = _is_braking or (_current_brake_heat > 0.35)
	var heat_boost: float = _current_brake_heat * 2.5
	var outer_energy: float = (8.5 + heat_boost) if brake_active else (3.2 if _headlights_on else 1.2)
	var inner_energy: float = (7.5 + heat_boost) if brake_active else (2.6 if _headlights_on else 0.9)

	if _mat_taillight_ring_outer:
		_mat_taillight_ring_outer.emission_energy_multiplier = outer_energy
	if _mat_taillight_ring_inner:
		_mat_taillight_ring_inner.emission_energy_multiplier = inner_energy

	if _omni_taillight_l:
		_omni_taillight_l.light_energy = 2.8 if brake_active else 0.8
	if _omni_taillight_r:
		_omni_taillight_r.light_energy = 2.8 if brake_active else 0.8

	# Kouki Reverse Lights
	if _mat_reverse_light:
		_mat_reverse_light.emission_enabled = _is_reversing
		_mat_reverse_light.emission_energy_multiplier = 5.0 if _is_reversing else 0.0

# ==============================================================================
# SHADERS, MATERIALS & PROCEDURAL SUBVIEWPORT TEXTURES
# ==============================================================================
func _init_materials_and_shaders() -> void:
	# 1. Manga Inverted-Hull Ink Outline Shader (Next Pass)
	var outline_shader := Shader.new()
	outline_shader.code = """
shader_type spatial;
render_mode cull_front, unshaded;

uniform vec4 ink_color : source_color = vec4(0.03, 0.04, 0.07, 1.0);
uniform float outline_width : hint_range(0.0, 0.03) = 0.0085;

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = ink_color.rgb;
}
"""
	var mat_ink_outline := ShaderMaterial.new()
	mat_ink_outline.shader = outline_shader

	# 2. Cel-Shaded Anime Car Paint Shader with Touge Cyan Fresnel Rim
	var paint_shader := Shader.new()
	paint_shader.code = """
shader_type spatial;
render_mode diffuse_toon, specular_toon;

uniform vec4 albedo_color : source_color = vec4(0.02, 0.28, 0.85, 1.0);
uniform vec4 rim_color : source_color = vec4(0.0, 0.92, 1.0, 1.0);
uniform float rim_power : hint_range(0.5, 8.0) = 3.2;
uniform float rim_intensity : hint_range(0.0, 5.0) = 1.65;

void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	float cel_rim = smoothstep(0.42, 0.48, fresnel);
	ALBEDO = albedo_color.rgb;
	METALLIC = 0.72;
	ROUGHNESS = 0.18;
	SPECULAR = 0.85;
	EMISSION = rim_color.rgb * (cel_rim * rim_intensity + fresnel * 0.35);
}
"""
	_mat_car_paint = ShaderMaterial.new()
	_mat_car_paint.shader = paint_shader
	_mat_car_paint.set_shader_parameter("albedo_color", _paint_color)
	_mat_car_paint.next_pass = mat_ink_outline

	# 3. Carbon Fiber Weave Shader (with Subtle Outline)
	var carbon_shader := Shader.new()
	carbon_shader.code = """
shader_type spatial;
render_mode diffuse_toon, specular_toon;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	vec2 uv_weave = (local_pos.xz + local_pos.xy) * 95.0;
	float diag = sin(uv_weave.x + uv_weave.y) * cos(uv_weave.x - uv_weave.y);
	float weave_step = step(0.0, diag);
	vec3 c1 = vec3(0.07, 0.08, 0.10);
	vec3 c2 = vec3(0.14, 0.16, 0.19);
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.8);
	ALBEDO = mix(c1, c2, weave_step);
	METALLIC = 0.45;
	ROUGHNESS = mix(0.22, 0.38, weave_step);
	EMISSION = vec3(0.0, 0.55, 0.75) * smoothstep(0.55, 0.65, fresnel) * 0.4;
}
"""
	_mat_carbon_fiber = ShaderMaterial.new()
	_mat_carbon_fiber.shader = carbon_shader
	_mat_carbon_fiber.next_pass = mat_ink_outline

	# 4. Heat-Burnt Titanium Exhaust Tip Shader
	var ti_shader := Shader.new()
	ti_shader.code = """
shader_type spatial;

varying float z_coord;
void vertex() {
	z_coord = VERTEX.y;
}
void fragment() {
	float t = clamp((z_coord + 0.12) / 0.24, 0.0, 1.0);
	vec3 silver = vec3(0.78, 0.80, 0.84);
	vec3 gold = vec3(0.85, 0.65, 0.20);
	vec3 purple = vec3(0.55, 0.15, 0.75);
	vec3 cyan_blue = vec3(0.05, 0.55, 0.98);
	vec3 col = mix(silver, gold, smoothstep(0.1, 0.4, t));
	col = mix(col, purple, smoothstep(0.4, 0.7, t));
	col = mix(col, cyan_blue, smoothstep(0.7, 0.95, t));
	ALBEDO = col;
	METALLIC = 0.92;
	ROUGHNESS = 0.15;
}
"""
	_mat_titanium_burnt = ShaderMaterial.new()
	_mat_titanium_burnt.shader = ti_shader

	# 5. Standard & Emissive Materials
	_mat_black_trim = StandardMaterial3D.new()
	_mat_black_trim.albedo_color = Color(0.06, 0.065, 0.08)
	_mat_black_trim.roughness = 0.65
	_mat_black_trim.metallic = 0.2

	_mat_chrome = StandardMaterial3D.new()
	_mat_chrome.albedo_color = Color(0.88, 0.91, 0.96)
	_mat_chrome.metallic = 0.95
	_mat_chrome.roughness = 0.12

	_mat_glass_smoked = StandardMaterial3D.new()
	_mat_glass_smoked.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_glass_smoked.albedo_color = Color(0.04, 0.07, 0.12, 0.48)
	_mat_glass_smoked.metallic = 0.85
	_mat_glass_smoked.roughness = 0.06
	_mat_glass_smoked.cull_mode = BaseMaterial3D.CULL_DISABLED

	_mat_headlight_glass = StandardMaterial3D.new()
	_mat_headlight_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_headlight_glass.albedo_color = Color(0.75, 0.92, 1.0, 0.26)
	_mat_headlight_glass.metallic = 0.9
	_mat_headlight_glass.roughness = 0.04

	# Cyber Angel Eye Halos (> 5.5 emission energy)
	_mat_halo_cyan = StandardMaterial3D.new()
	_mat_halo_cyan.albedo_color = Color("#00F3FF")
	_mat_halo_cyan.emission_enabled = true
	_mat_halo_cyan.emission = Color("#00F3FF")
	_mat_halo_cyan.emission_energy_multiplier = 7.2

	_mat_headlight_core = StandardMaterial3D.new()
	_mat_headlight_core.albedo_color = Color("#F0F8FF")
	_mat_headlight_core.emission_enabled = true
	_mat_headlight_core.emission = Color("#F0F8FF")
	_mat_headlight_core.emission_energy_multiplier = 6.0

	# Godzilla Quad Taillight Crimson Halos
	_mat_taillight_ring_outer = StandardMaterial3D.new()
	_mat_taillight_ring_outer.albedo_color = Color(1.0, 0.04, 0.12)
	_mat_taillight_ring_outer.emission_enabled = true
	_mat_taillight_ring_outer.emission = Color(1.0, 0.04, 0.12)
	_mat_taillight_ring_outer.emission_energy_multiplier = 3.5

	_mat_taillight_ring_inner = StandardMaterial3D.new()
	_mat_taillight_ring_inner.albedo_color = Color(1.0, 0.05, 0.14)
	_mat_taillight_ring_inner.emission_enabled = true
	_mat_taillight_ring_inner.emission = Color(1.0, 0.05, 0.14)
	_mat_taillight_ring_inner.emission_energy_multiplier = 2.8

	_mat_reverse_light = StandardMaterial3D.new()
	_mat_reverse_light.albedo_color = Color(0.92, 0.96, 1.0)
	_mat_reverse_light.emission_enabled = false
	_mat_reverse_light.emission = Color(0.95, 0.98, 1.0)

	_mat_turn_signal = StandardMaterial3D.new()
	_mat_turn_signal.albedo_color = Color(1.0, 0.48, 0.0)
	_mat_turn_signal.emission_enabled = true
	_mat_turn_signal.emission = Color(1.0, 0.42, 0.0)
	_mat_turn_signal.emission_energy_multiplier = 1.6

	_mat_fmic_core = StandardMaterial3D.new()
	_mat_fmic_core.albedo_color = Color(0.68, 0.72, 0.78)
	_mat_fmic_core.metallic = 0.88
	_mat_fmic_core.roughness = 0.32

	_mat_wheel_spoke = StandardMaterial3D.new()
	_mat_wheel_spoke.albedo_color = _rim_color
	_mat_wheel_spoke.metallic = 0.78
	_mat_wheel_spoke.roughness = 0.28

	_mat_wheel_lip = StandardMaterial3D.new()
	_mat_wheel_lip.albedo_color = Color(0.90, 0.92, 0.95)
	_mat_wheel_lip.metallic = 0.96
	_mat_wheel_lip.roughness = 0.10

	_mat_tire_rubber = StandardMaterial3D.new()
	_mat_tire_rubber.albedo_color = Color(0.08, 0.085, 0.095)
	_mat_tire_rubber.roughness = 0.86

	_mat_brembo_caliper = StandardMaterial3D.new()
	_mat_brembo_caliper.albedo_color = Color(0.88, 0.62, 0.05) # Nismo Gold Brembo F50
	_mat_brembo_caliper.metallic = 0.65
	_mat_brembo_caliper.roughness = 0.24

	_mat_brake_rotor = StandardMaterial3D.new()
	_mat_brake_rotor.albedo_color = Color(0.24, 0.25, 0.27)
	_mat_brake_rotor.metallic = 0.82
	_mat_brake_rotor.roughness = 0.36

	_mat_interior_dark = StandardMaterial3D.new()
	_mat_interior_dark.albedo_color = Color(0.09, 0.10, 0.12)
	_mat_interior_dark.roughness = 0.78

	_mat_recaro_red = StandardMaterial3D.new()
	_mat_recaro_red.albedo_color = Color(0.68, 0.06, 0.10)
	_mat_recaro_red.roughness = 0.72

	_mat_roll_cage = StandardMaterial3D.new()
	_mat_roll_cage.albedo_color = Color(0.0, 0.72, 0.92) # Cusco Metallic Cyan
	_mat_roll_cage.metallic = 0.75
	_mat_roll_cage.roughness = 0.22

	# 6. Procedural SubViewport Textures (MFD, Gauge Cluster, Tire Stencil)
	_build_procedural_subviewport_materials()

	# 7. Manga Tire Smoke & Wind Streamer Shaders
	var smoke_shader := Shader.new()
	smoke_shader.code = """
shader_type spatial;
render_mode diffuse_toon, specular_disabled;

void fragment() {
	float edge = dot(NORMAL, VIEW);
	float ink = step(0.26, edge);
	vec3 smoke_col = vec3(0.92, 0.95, 1.0);
	vec3 outline_col = vec3(0.08, 0.12, 0.18);
	ALBEDO = mix(outline_col, smoke_col, ink);
	EMISSION = mix(vec3(0.0), vec3(0.12, 0.22, 0.32), ink);
}
"""
	_mat_manga_smoke = ShaderMaterial.new()
	_mat_manga_smoke.shader = smoke_shader

	var streamer_shader := Shader.new()
	streamer_shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add;

void fragment() {
	ALBEDO = vec3(0.0, 0.95, 1.0);
	EMISSION = vec3(0.0, 0.95, 1.0) * 4.5;
	ALPHA = 0.75;
}
"""
	_mat_wind_streamer = ShaderMaterial.new()
	_mat_wind_streamer.shader = streamer_shader

func _build_procedural_subviewport_materials() -> void:
	var vp_holder := Node.new()
	vp_holder.name = "ProceduralViewports"
	add_child(vp_holder)

	# --- A. R34 MFD Telemetry Display SubViewport ---
	var vp_mfd := SubViewport.new()
	vp_mfd.size = Vector2i(256, 160)
	vp_mfd.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp_mfd.transparent_bg = false
	vp_holder.add_child(vp_mfd)

	var mfd_bg := ColorRect.new()
	mfd_bg.color = Color(0.01, 0.06, 0.14)
	mfd_bg.size = Vector2(256, 160)
	vp_mfd.add_child(mfd_bg)

	# Header bar
	var mfd_header := ColorRect.new()
	mfd_header.color = Color(0.0, 0.85, 1.0)
	mfd_header.position = Vector2(8, 8)
	mfd_header.size = Vector2(240, 18)
	vp_mfd.add_child(mfd_header)

	# 3 Telemetry Bar Graphs (BOOST, OIL TEMP, THROTTLE)
	var bar_heights := [95.0, 72.0, 108.0]
	var bar_colors := [Color("#00F3FF"), Color("#00D8FF"), Color("#FF2A6D")]
	for i in range(3):
		var frame := ColorRect.new()
		frame.color = Color(0.05, 0.22, 0.38)
		frame.position = Vector2(20 + i * 76, 36)
		frame.size = Vector2(56, 112)
		vp_mfd.add_child(frame)

		var fill := ColorRect.new()
		fill.color = bar_colors[i]
		fill.position = Vector2(24 + i * 76, 36 + (112 - bar_heights[i]))
		fill.size = Vector2(48, bar_heights[i] - 4)
		vp_mfd.add_child(fill)

	_mat_mfd_screen = StandardMaterial3D.new()
	_mat_mfd_screen.albedo_texture = vp_mfd.get_texture()
	_mat_mfd_screen.emission_enabled = true
	_mat_mfd_screen.emission_texture = vp_mfd.get_texture()
	_mat_mfd_screen.emission_energy_multiplier = 3.2

	# --- B. Nismo 320 km/h White-Face Gauge Cluster SubViewport ---
	var vp_gauge := SubViewport.new()
	vp_gauge.size = Vector2i(256, 128)
	vp_gauge.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp_holder.add_child(vp_gauge)

	var gauge_bg := ColorRect.new()
	gauge_bg.color = Color(0.04, 0.05, 0.08)
	gauge_bg.size = Vector2(256, 128)
	vp_gauge.add_child(gauge_bg)

	for g in range(2):
		var dial := ColorRect.new()
		dial.color = Color(0.92, 0.95, 0.98)
		dial.position = Vector2(22 + g * 116, 18)
		dial.size = Vector2(92, 92)
		vp_gauge.add_child(dial)

		var needle := ColorRect.new()
		needle.color = Color(1.0, 0.12, 0.18)
		needle.position = Vector2(64 + g * 116, 34)
		needle.size = Vector2(6, 46)
		needle.rotation = 0.65 if g == 0 else -0.45
		vp_gauge.add_child(needle)

	_mat_gauge_cluster = StandardMaterial3D.new()
	_mat_gauge_cluster.albedo_texture = vp_gauge.get_texture()
	_mat_gauge_cluster.emission_enabled = true
	_mat_gauge_cluster.emission_texture = vp_gauge.get_texture()
	_mat_gauge_cluster.emission_energy_multiplier = 2.4

	# --- C. Tire Sidewall Stencil ("POTENZA RE-71RS / ADVAN RACING") ---
	var vp_tire := SubViewport.new()
	vp_tire.size = Vector2i(512, 512)
	vp_tire.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp_tire.transparent_bg = true
	vp_holder.add_child(vp_tire)

	var tire_canvas := Control.new()
	tire_canvas.custom_minimum_size = Vector2(512, 512)
	vp_tire.add_child(tire_canvas)

	# Stencil Arc Blocks representing "POTENZA RE-71RS" & "NISMO LMGT4"
	var center := Vector2(256, 256)
	var radius := 208.0
	for s in range(2):
		var base_angle: float = s * PI
		for c in range(14):
			var ang: float = base_angle - 0.65 + float(c) * 0.095
			var pos := center + Vector2(cos(ang), sin(ang)) * radius
			var letter_block := ColorRect.new()
			letter_block.color = Color(0.95, 0.97, 1.0, 0.95) if c != 7 else Color(1.0, 0.15, 0.2, 0.95)
			letter_block.size = Vector2(11, 18)
			letter_block.position = pos - letter_block.size * 0.5
			letter_block.rotation = ang + PI * 0.5
			tire_canvas.add_child(letter_block)

	_mat_tire_sidewall = StandardMaterial3D.new()
	_mat_tire_sidewall.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_tire_sidewall.albedo_texture = vp_tire.get_texture()
	_mat_tire_sidewall.roughness = 0.75
	_mat_tire_sidewall.cull_mode = BaseMaterial3D.CULL_DISABLED

# ==============================================================================
# 1. LOFTED BNR34 BODY SHELL, GREENHOUSE & Z-TUNE BLISTER FENDERS
# ==============================================================================
func _build_body_shell(parent: Node3D) -> void:
	var body_node := Node3D.new()
	body_node.name = "BodyShell"
	parent.add_child(body_node)

	# Cross-sectional stations from Front (-Z) to Rear (+Z)
	# Format: [z, y_bottom, half_w_bottom, y_mid_flare, half_w_mid, y_beltline, half_w_belt, y_roof, half_w_roof]
	var stations: Array = [
		[-2.29, 0.15, 0.76, 0.44, 0.83, 0.69, 0.79, 0.69, 0.79], # 0: Front bumper nose
		[-2.14, 0.15, 0.84, 0.47, 0.88, 0.73, 0.83, 0.73, 0.83], # 1: Headlight housing plane
		[-1.68, 0.14, 0.87, 0.54, 0.92, 0.78, 0.85, 0.78, 0.85], # 2: Front Z-Tune arch lead
		[-1.33, 0.16, 0.88, 0.59, 0.94, 0.81, 0.86, 0.81, 0.86], # 3: Front axle blister peak
		[-0.95, 0.14, 0.87, 0.54, 0.91, 0.83, 0.85, 0.83, 0.85], # 4: Z-Tune fender vent exit
		[-0.78, 0.14, 0.85, 0.51, 0.88, 0.85, 0.84, 0.85, 0.84], # 5: Base of A-pillar / cowl
		[-0.26, 0.14, 0.85, 0.51, 0.88, 0.87, 0.84, 1.34, 0.66], # 6: Windshield header
		[ 0.38, 0.14, 0.85, 0.52, 0.89, 0.88, 0.84, 1.36, 0.65], # 7: B-pillar / roof peak
		[ 0.94, 0.14, 0.87, 0.56, 0.92, 0.90, 0.85, 1.31, 0.63], # 8: Rear C-pillar header
		[ 1.33, 0.17, 0.88, 0.61, 0.94, 0.92, 0.86, 0.92, 0.86], # 9: Rear axle blister peak
		[ 1.72, 0.18, 0.87, 0.56, 0.91, 0.91, 0.84, 0.91, 0.84], # 10: Rear quarter arch trail
		[ 2.18, 0.22, 0.83, 0.53, 0.86, 0.89, 0.80, 0.89, 0.80], # 11: Trunk deck edge
		[ 2.30, 0.25, 0.79, 0.52, 0.82, 0.86, 0.77, 0.86, 0.77]  # 12: Rear taillight panel
	]

	var st_paint := SurfaceTool.new()
	st_paint.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in range(stations.size() - 1):
		var s0: Array = stations[i]
		var s1: Array = stations[i + 1]
		var z0: float = s0[0]
		var z1: float = s1[0]

		# Right side lower body panel (bottom -> mid flare)
		_add_quad(st_paint,
			Vector3(s0[2], s0[1], z0), Vector3(s1[2], s1[1], z1),
			Vector3(s1[4], s1[3], z1), Vector3(s0[4], s0[3], z0))
		# Right side upper blister fender (mid flare -> beltline)
		_add_quad(st_paint,
			Vector3(s0[4], s0[3], z0), Vector3(s1[4], s1[3], z1),
			Vector3(s1[6], s1[5], z1), Vector3(s0[6], s0[5], z0))

		# Left side lower body panel
		_add_quad(st_paint,
			Vector3(-s1[2], s1[1], z1), Vector3(-s0[2], s0[1], z0),
			Vector3(-s0[4], s0[3], z0), Vector3(-s1[4], s1[3], z1))
		# Left side upper blister fender
		_add_quad(st_paint,
			Vector3(-s1[4], s1[3], z1), Vector3(-s0[4], s0[3], z0),
			Vector3(-s0[6], s0[5], z0), Vector3(-s1[6], s1[5], z1))

		# Top surfaces: Trunk deck (stations 9..12) and Roof skin (stations 6..8)
		if i >= 9:
			_add_quad(st_paint,
				Vector3(-s0[6], s0[5], z0), Vector3(s0[6], s0[5], z0),
				Vector3(s1[6], s1[5], z1), Vector3(-s1[6], s1[5], z1))
		elif i >= 6 and i <= 7:
			# Roof top panel
			_add_quad(st_paint,
				Vector3(-s0[8], s0[7], z0), Vector3(s0[8], s0[7], z0),
				Vector3(s1[8], s1[7], z1), Vector3(-s1[8], s1[7], z1))

	# Front & Rear Fascia Caps
	var sf: Array = stations[0]
	_add_quad(st_paint,
		Vector3(-sf[2], sf[1], sf[0]), Vector3(sf[2], sf[1], sf[0]),
		Vector3(sf[4], sf[3], sf[0]), Vector3(-sf[4], sf[3], sf[0]))

	var sr: Array = stations[stations.size() - 1]
	_add_quad(st_paint,
		Vector3(sr[2], sr[1], sr[0]), Vector3(-sr[2], sr[1], sr[0]),
		Vector3(-sr[4], sr[3], sr[0]), Vector3(sr[4], sr[3], sr[0]))
	_add_quad(st_paint,
		Vector3(sr[4], sr[3], sr[0]), Vector3(-sr[4], sr[3], sr[0]),
		Vector3(-sr[6], sr[5], sr[0]), Vector3(sr[6], sr[5], sr[0]))

	# A-Pillars & C-Pillars (Painted Structural Pillars)
	var s5: Array = stations[5]
	var s6: Array = stations[6]
	var s8: Array = stations[8]
	var s9: Array = stations[9]

	# Right & Left A-Pillar
	_add_quad(st_paint,
		Vector3(s5[6] - 0.08, s5[5], s5[0]), Vector3(s5[6], s5[5], s5[0]),
		Vector3(s6[8], s6[7], s6[0]), Vector3(s6[8] - 0.08, s6[7], s6[0]))
	_add_quad(st_paint,
		Vector3(-s5[6], s5[5], s5[0]), Vector3(-s5[6] + 0.08, s5[5], s5[0]),
		Vector3(-s6[8] + 0.08, s6[7], s6[0]), Vector3(-s6[8], s6[7], s6[0]))

	# Right & Left C-Pillar (Iconic R34 Hofmeister-style notch)
	_add_quad(st_paint,
		Vector3(s8[8], s8[7], s8[0]), Vector3(s8[6], s8[5], s8[0]),
		Vector3(s9[6], s9[5], s9[0]), Vector3(s9[6] - 0.14, s9[5], s9[0]))
	_add_quad(st_paint,
		Vector3(-s8[6], s8[5], s8[0]), Vector3(-s8[8], s8[7], s8[0]),
		Vector3(-s9[6] + 0.14, s9[5], s9[0]), Vector3(-s9[6], s9[5], s9[0]))

	st_paint.generate_normals()
	var body_mesh_inst := MeshInstance3D.new()
	body_mesh_inst.name = "PaintedUnibody"
	body_mesh_inst.mesh = st_paint.commit()
	body_mesh_inst.material_override = _mat_car_paint
	body_node.add_child(body_mesh_inst)

	# --- Smoked Cabin Glass (Windshield, Side Windows, Rear Window) ---
	var st_glass := SurfaceTool.new()
	st_glass.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Front Windshield (Station 5 to 6)
	_add_quad(st_glass,
		Vector3(-s5[6] + 0.06, s5[5], s5[0]), Vector3(s5[6] - 0.06, s5[5], s5[0]),
		Vector3(s6[8] - 0.06, s6[7], s6[0]), Vector3(-s6[8] + 0.06, s6[7], s6[0]))

	# Rear Backlight Window (Station 8 to 9)
	_add_quad(st_glass,
		Vector3(s8[8] - 0.05, s8[7], s8[0]), Vector3(-s8[8] + 0.05, s8[7], s8[0]),
		Vector3(-s9[6] + 0.12, s9[5], s9[0]), Vector3(s9[6] - 0.12, s9[5], s9[0]))

	# Side Windows (Stations 5 to 9)
	for i in range(5, 8):
		var sa: Array = stations[i]
		var sb: Array = stations[i + 1]
		var ya_top: float = sa[7] if i >= 6 else sa[5]
		var xa_top: float = sa[8] if i >= 6 else sa[6]
		var yb_top: float = sb[7]
		var xb_top: float = sb[8]

		# Right side glass
		_add_quad(st_glass,
			Vector3(sa[6], sa[5], sa[0]), Vector3(sb[6], sb[5], sb[0]),
			Vector3(xb_top, yb_top, sb[0]), Vector3(xa_top, ya_top, sa[0]))
		# Left side glass
		_add_quad(st_glass,
			Vector3(-sb[6], sb[5], sb[0]), Vector3(-sa[6], sa[5], sa[0]),
			Vector3(-xa_top, ya_top, sa[0]), Vector3(-xb_top, yb_top, sb[0]))

	st_glass.generate_normals()
	var glass_mesh_inst := MeshInstance3D.new()
	glass_mesh_inst.name = "SmokedCabinGlass"
	glass_mesh_inst.mesh = st_glass.commit()
	glass_mesh_inst.material_override = _mat_glass_smoked
	body_node.add_child(glass_mesh_inst)

	# Dark Wheelhouse Liners & Chassis Undertray
	_spawn_box(body_node, "ChassisUndertray", Vector3(1.66, 0.06, 4.42), Vector3(0.0, 0.16, 0.0), Vector3.ZERO, _mat_black_trim)

# ==============================================================================
# 2. NISMO Z-TUNE CARBON AERO, VENTED HOOD, FMIC, DIFFUSER & GT WING
# ==============================================================================
func _build_aero_and_details(parent: Node3D) -> void:
	var aero_root := Node3D.new()
	aero_root.name = "NismoZTuneAero"
	parent.add_child(aero_root)

	# --- A. Carbon Fiber Vented Z-Tune Hood (Station 1 to 5) ---
	var st_hood := SurfaceTool.new()
	st_hood.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_quad(st_hood,
		Vector3(-0.76, 0.735, -2.12), Vector3(0.76, 0.735, -2.12),
		Vector3(0.81, 0.852, -0.78), Vector3(-0.81, 0.852, -0.78))
	st_hood.generate_normals()
	var hood_inst := MeshInstance3D.new()
	hood_inst.name = "ZTuneCarbonHood"
	hood_inst.mesh = st_hood.commit()
	hood_inst.material_override = _mat_carbon_fiber
	aero_root.add_child(hood_inst)

	# Dual Z-Tune Hood Heat Extractor Louvers
	for side in [-1.0, 1.0]:
		for l in range(4):
			var z_louver: float = -1.72 + float(l) * 0.14
			var y_louver: float = lerpf(0.75, 0.82, (z_louver + 2.12) / 1.34)
			_spawn_box(aero_root, "HoodLouver", Vector3(0.24, 0.018, 0.06),
				Vector3(side * 0.34, y_louver, z_louver), Vector3(deg_to_rad(-14.0), 0.0, 0.0), _mat_black_trim)

	# --- B. Massive Front-Mount Intercooler (FMIC) & Bumper Cavity ---
	_spawn_box(aero_root, "BumperIntakeCavity", Vector3(1.06, 0.30, 0.12), Vector3(0.0, 0.30, -2.25), Vector3.ZERO, _mat_black_trim)
	_spawn_box(aero_root, "FMICCore", Vector3(0.92, 0.25, 0.08), Vector3(0.0, 0.30, -2.265), Vector3.ZERO, _mat_fmic_core)

	# Horizontal Fin Detail Bars & "NISMO" Stencil Accent on FMIC
	for f in range(5):
		_spawn_box(aero_root, "FMICFin", Vector3(0.90, 0.008, 0.09),
			Vector3(0.0, 0.21 + float(f) * 0.045, -2.27), Vector3.ZERO, _mat_black_trim)

	# Polished Aluminum Intercooler End-Tanks & Piping
	for side in [-1.0, 1.0]:
		_spawn_cylinder(aero_root, "FMICPipe", 0.042, 0.24,
			Vector3(side * 0.50, 0.28, -2.25), Vector3(0.0, 0.0, deg_to_rad(90.0)), _mat_chrome)

	# --- C. Front Carbon Chin Spoiler & Twin Corner Dive Planes (Canards) ---
	_spawn_box(aero_root, "FrontCarbonSplitter", Vector3(1.78, 0.032, 0.34), Vector3(0.0, 0.135, -2.20), Vector3.ZERO, _mat_carbon_fiber)
	for side in [-1.0, 1.0]:
		# Splitter vertical end-fences
		_spawn_box(aero_root, "SplitterEndFence", Vector3(0.02, 0.11, 0.26),
			Vector3(side * 0.88, 0.18, -2.21), Vector3.ZERO, _mat_carbon_fiber)
		# Upper & Lower Bumper Corner Canards
		_spawn_box(aero_root, "UpperCanard", Vector3(0.14, 0.015, 0.22),
			Vector3(side * 0.87, 0.36, -2.16), Vector3(deg_to_rad(14.0), side * deg_to_rad(-18.0), side * deg_to_rad(12.0)), _mat_carbon_fiber)
		_spawn_box(aero_root, "LowerCanard", Vector3(0.12, 0.015, 0.18),
			Vector3(side * 0.87, 0.26, -2.18), Vector3(deg_to_rad(12.0), side * deg_to_rad(-18.0), side * deg_to_rad(10.0)), _mat_carbon_fiber)

		# Z-Tune Front Fender Air Extractor Vent Fin
		_spawn_box(aero_root, "ZTuneFenderVent", Vector3(0.03, 0.32, 0.10),
			Vector3(side * 0.915, 0.56, -0.96), Vector3(0.0, side * deg_to_rad(8.0), 0.0), _mat_black_trim)

		# Nismo Side Skirts with Carbon Under-Board
		_spawn_box(aero_root, "SideSkirtCarbon", Vector3(0.10, 0.035, 1.92),
			Vector3(side * 0.89, 0.14, 0.0), Vector3.ZERO, _mat_carbon_fiber)

		# Aero Side Mirrors
		var mirror_pos := Vector3(side * 0.91, 0.89, -0.58)
		_spawn_box(aero_root, "AeroMirrorPod", Vector3(0.16, 0.09, 0.12),
			mirror_pos, Vector3(0.0, side * deg_to_rad(-12.0), 0.0), _mat_car_paint)

	# --- D. Front Grille Mesh & Red GT-R Emblem ---
	_spawn_box(aero_root, "UpperGrilleMesh", Vector3(0.76, 0.11, 0.06), Vector3(0.0, 0.61, -2.23), Vector3.ZERO, _mat_black_trim)
	_spawn_box(aero_root, "GTRBadgeBacking", Vector3(0.08, 0.055, 0.02), Vector3(0.0, 0.61, -2.265), Vector3.ZERO, _mat_chrome)
	_spawn_box(aero_root, "GTRBadgeRed", Vector3(0.07, 0.03, 0.025), Vector3(0.0, 0.595, -2.268), Vector3.ZERO, _mat_taillight_ring_outer)

	# --- E. High-Mount Carbon Fiber GT Wing with Aluminum Stanchions & Endplates ---
	var wing_y: float = 1.19
	var wing_z: float = 2.14
	_spawn_box(aero_root, "GTWingMainBlade", Vector3(1.66, 0.026, 0.27),
		Vector3(0.0, wing_y, wing_z), Vector3(deg_to_rad(9.5), 0.0, 0.0), _mat_carbon_fiber)
	_spawn_box(aero_root, "GTWingGurneyFlap", Vector3(1.64, 0.024, 0.04),
		Vector3(0.0, wing_y + 0.025, wing_z + 0.12), Vector3(deg_to_rad(28.0), 0.0, 0.0), _mat_carbon_fiber)

	for side in [-1.0, 1.0]:
		# Dual CNC Aluminum Stanchions
		_spawn_box(aero_root, "GTWingStanchion", Vector3(0.022, 0.30, 0.18),
			Vector3(side * 0.46, 1.03, 2.10), Vector3(deg_to_rad(-12.0), 0.0, 0.0), _mat_black_trim)
		# Carbon Endplates
		_spawn_box(aero_root, "GTWingEndplate", Vector3(0.018, 0.19, 0.36),
			Vector3(side * 0.835, wing_y - 0.01, wing_z + 0.01), Vector3(deg_to_rad(6.0), 0.0, 0.0), _mat_carbon_fiber)

	# --- F. Rear Carbon Fiber Under-Bumper Diffuser with 4 Aero Strakes ---
	_spawn_box(aero_root, "RearCarbonDiffuser", Vector3(1.52, 0.12, 0.38),
		Vector3(0.0, 0.21, 2.16), Vector3(deg_to_rad(-11.0), 0.0, 0.0), _mat_carbon_fiber)
	for strake_x in [-0.52, -0.18, 0.18, 0.52]:
		_spawn_box(aero_root, "DiffuserStrake", Vector3(0.018, 0.14, 0.36),
			Vector3(strake_x, 0.19, 2.18), Vector3(deg_to_rad(-8.0), 0.0, 0.0), _mat_carbon_fiber)

# ==============================================================================
# 3. CYBER NEON "GODZILLA EYES" HEADLIGHTS & ANGEL EYE HALOS
# ==============================================================================
func _build_headlights(parent: Node3D) -> void:
	var hl_root := Node3D.new()
	hl_root.name = "GodzillaHeadlights"
	parent.add_child(hl_root)

	for side in [-1.0, 1.0]:
		var side_name := "L" if side < 0.0 else "R"
		var housing_pos := Vector3(side * 0.61, 0.62, -2.18)

		# Smoked Housing Bucket
		_spawn_box(hl_root, "HeadlightBucket_" + side_name, Vector3(0.38, 0.13, 0.16),
			housing_pos, Vector3(0.0, side * deg_to_rad(-14.0), side * deg_to_rad(-4.0)), _mat_black_trim)

		# Dual Projector Pods + Cyber Angel Eye Neon Halos (Outer & Inner)
		for p in range(2):
			var offset_x: float = side * (0.68 if p == 0 else 0.53)
			var offset_z: float = -2.17 if p == 0 else -2.20
			var pod_pos := Vector3(offset_x, 0.615, offset_z)

			# Xenon Lens Core
			var core_mesh := SphereMesh.new()
			core_mesh.radius = 0.036 if p == 0 else 0.030
			core_mesh.height = core_mesh.radius * 2.0
			var core_inst := MeshInstance3D.new()
			core_inst.name = "ProjectorCore_" + side_name + str(p)
			core_inst.mesh = core_mesh
			core_inst.position = pod_pos
			core_inst.material_override = _mat_headlight_core
			hl_root.add_child(core_inst)

			# Cyber Angel Eye Torus Halo Ring
			var halo_torus := TorusMesh.new()
			halo_torus.outer_radius = 0.052 if p == 0 else 0.044
			halo_torus.inner_radius = 0.038 if p == 0 else 0.032
			halo_torus.rings = 24
			halo_torus.ring_segments = 16
			var halo_inst := MeshInstance3D.new()
			halo_inst.name = "AngelEyeHalo_" + side_name + str(p)
			halo_inst.mesh = halo_torus
			halo_inst.position = pod_pos + Vector3(0.0, 0.0, -0.015)
			halo_inst.rotation = Vector3(deg_to_rad(90.0), side * deg_to_rad(-12.0), 0.0)
			halo_inst.material_override = _mat_halo_cyan
			hl_root.add_child(halo_inst)

		# Slanted Cyber-Brow LED DRL Strip
		_spawn_box(hl_root, "CyberBrowDRL_" + side_name, Vector3(0.36, 0.018, 0.04),
			housing_pos + Vector3(0.0, 0.062, -0.05),
			Vector3(0.0, side * deg_to_rad(-14.0), side * deg_to_rad(-7.0)), _mat_halo_cyan)

		# Smoked Clear Polycarbonate Lens Cover
		_spawn_box(hl_root, "HeadlightLens_" + side_name, Vector3(0.39, 0.135, 0.03),
			housing_pos + Vector3(0.0, 0.0, -0.075),
			Vector3(deg_to_rad(-12.0), side * deg_to_rad(-14.0), side * deg_to_rad(-4.0)), _mat_headlight_glass)

		# Lower Bumper Turn Signals & Cibie Fog Lamps
		_spawn_box(hl_root, "FrontTurnSignal_" + side_name, Vector3(0.14, 0.045, 0.05),
			Vector3(side * 0.72, 0.42, -2.23), Vector3(0.0, side * deg_to_rad(-16.0), 0.0), _mat_turn_signal)
		_spawn_cylinder(hl_root, "CibieFogLamp_" + side_name, 0.042, 0.05,
			Vector3(side * 0.56, 0.30, -2.25), Vector3(deg_to_rad(90.0), 0.0, 0.0), _mat_headlight_core)

		# Forward SpotLight3D Beams
		var spot := SpotLight3D.new()
		spot.name = "HeadlightSpot_" + side_name
		spot.position = housing_pos + Vector3(0.0, 0.0, -0.10)
		spot.light_color = Color(0.82, 0.96, 1.0)
		spot.light_energy = 4.8
		spot.spot_range = 38.0
		spot.spot_angle = 32.0
		hl_root.add_child(spot)
		if side < 0.0:
			_spot_headlight_l = spot
		else:
			_spot_headlight_r = spot

# ==============================================================================
# 4. ICONIC "GODZILLA" QUAD ROUND TAILLIGHTS
# ==============================================================================
func _build_taillights(parent: Node3D) -> void:
	var tl_root := Node3D.new()
	tl_root.name = "GodzillaQuadTaillights"
	parent.add_child(tl_root)

	# Smoked Dark Rear Backing Panel
	_spawn_box(tl_root, "TaillightDarkPanel", Vector3(1.54, 0.24, 0.06),
		Vector3(0.0, 0.68, 2.28), Vector3.ZERO, _mat_black_trim)

	for side in [-1.0, 1.0]:
		var side_name := "L" if side < 0.0 else "R"

		# 1. Outer Larger Crimson Halo Ring (Radius 0.095m)
		var outer_torus := TorusMesh.new()
		outer_torus.outer_radius = 0.095
		outer_torus.inner_radius = 0.062
		outer_torus.rings = 28
		outer_torus.ring_segments = 18
		var outer_inst := MeshInstance3D.new()
		outer_inst.name = "OuterTailRing_" + side_name
		outer_inst.mesh = outer_torus
		outer_inst.position = Vector3(side * 0.62, 0.70, 2.305)
		outer_inst.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
		outer_inst.material_override = _mat_taillight_ring_outer
		tl_root.add_child(outer_inst)

		# Amber Turn Signal Embedded inside Outer Ring Center
		_spawn_cylinder(tl_root, "RearTurnSignal_" + side_name, 0.032, 0.03,
			Vector3(side * 0.62, 0.70, 2.30), Vector3(deg_to_rad(90.0), 0.0, 0.0), _mat_turn_signal)

		# 2. Inner Smaller Crimson Halo Ring (Radius 0.076m)
		var inner_torus := TorusMesh.new()
		inner_torus.outer_radius = 0.076
		inner_torus.inner_radius = 0.048
		inner_torus.rings = 28
		inner_torus.ring_segments = 18
		var inner_inst := MeshInstance3D.new()
		inner_inst.name = "InnerTailRing_" + side_name
		inner_inst.mesh = inner_torus
		inner_inst.position = Vector3(side * 0.41, 0.69, 2.305)
		inner_inst.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
		inner_inst.material_override = _mat_taillight_ring_inner
		tl_root.add_child(inner_inst)

		# Kouki Clear Reverse Light Embedded cleanly next to Inner Ring
		_spawn_cylinder(tl_root, "ReverseLight_" + side_name, 0.030, 0.03,
			Vector3(side * 0.41, 0.69, 2.30), Vector3(deg_to_rad(90.0), 0.0, 0.0), _mat_reverse_light)

		# Taillight Crimson Bloom OmniLight3D
		var omni := OmniLight3D.new()
		omni.name = "TaillightOmni_" + side_name
		omni.position = Vector3(side * 0.52, 0.70, 2.38)
		omni.light_color = Color(1.0, 0.05, 0.14)
		omni.light_energy = 1.0
		omni.omni_range = 3.5
		tl_root.add_child(omni)
		if side < 0.0:
			_omni_taillight_l = omni
		else:
			_omni_taillight_r = omni

# ==============================================================================
# 5. VISIBLE COCKPIT INTERIOR (RHD JAPANESE SPEC, MFD, & CUSCO ROLL CAGE)
# ==============================================================================
func _build_rhd_interior(parent: Node3D) -> void:
	var int_root := Node3D.new()
	int_root.name = "RHDInterior"
	parent.add_child(int_root)

	# Cabin Floorpan, Center Tunnel, & Dashboard Bulkhead
	_spawn_box(int_root, "CabinFloor", Vector3(1.48, 0.05, 1.85), Vector3(0.0, 0.26, 0.05), Vector3.ZERO, _mat_interior_dark)
	_spawn_box(int_root, "TransmissionTunnel", Vector3(0.24, 0.18, 1.75), Vector3(0.0, 0.36, 0.05), Vector3.ZERO, _mat_interior_dark)
	_spawn_box(int_root, "DashboardMain", Vector3(1.46, 0.28, 0.42), Vector3(0.0, 0.72, -0.58), Vector3.ZERO, _mat_interior_dark)

	# --- A. Center Dash R34 MFD Telemetry Screen Pod ---
	_spawn_box(int_root, "MFDPodHood", Vector3(0.24, 0.14, 0.22), Vector3(0.0, 0.88, -0.56), Vector3.ZERO, _mat_interior_dark)
	_spawn_box(int_root, "MFDScreenDisplay", Vector3(0.20, 0.11, 0.02),
		Vector3(0.0, 0.88, -0.45), Vector3(deg_to_rad(-8.0), deg_to_rad(-10.0), 0.0), _mat_mfd_screen)

	# --- B. Right-Hand Drive (RHD, X = +0.36m) Nismo Gauge Cluster & Steering Wheel ---
	var rhd_x: float = 0.36
	_spawn_box(int_root, "NismoGaugeBinnacle", Vector3(0.32, 0.16, 0.20), Vector3(rhd_x, 0.87, -0.54), Vector3.ZERO, _mat_interior_dark)
	_spawn_box(int_root, "NismoGaugeClusterFace", Vector3(0.28, 0.13, 0.02),
		Vector3(rhd_x, 0.87, -0.44), Vector3(deg_to_rad(-12.0), 0.0, 0.0), _mat_gauge_cluster)

	# Steering Column & 3-Spoke Momo/Nismo Sports Wheel
	var wheel_center := Vector3(rhd_x, 0.81, -0.28)
	_spawn_cylinder(int_root, "SteeringColumn", 0.035, 0.28,
		Vector3(rhd_x, 0.80, -0.41), Vector3(deg_to_rad(72.0), 0.0, 0.0), _mat_interior_dark)

	var sw_torus := TorusMesh.new()
	sw_torus.outer_radius = 0.165
	sw_torus.inner_radius = 0.135
	sw_torus.rings = 24
	sw_torus.ring_segments = 12
	var sw_inst := MeshInstance3D.new()
	sw_inst.name = "NismoSteeringWheelRim"
	sw_inst.mesh = sw_torus
	sw_inst.position = wheel_center
	sw_inst.rotation = Vector3(deg_to_rad(72.0), 0.0, 0.0)
	sw_inst.material_override = _mat_interior_dark
	int_root.add_child(sw_inst)

	# Red Top-Center Marker & 3 Spokes
	_spawn_box(int_root, "SteeringCenterMarker", Vector3(0.025, 0.032, 0.032),
		wheel_center + Vector3(0.0, 0.145, -0.045), Vector3(deg_to_rad(-18.0), 0.0, 0.0), _mat_recaro_red)
	for sp_ang in [-90.0, 0.0, 90.0]:
		_spawn_box(int_root, "SteeringSpoke", Vector3(0.028, 0.14, 0.015),
			wheel_center, Vector3(deg_to_rad(-18.0), 0.0, deg_to_rad(sp_ang)), _mat_chrome)

	# Getrag 6-Speed Shifter & Handbrake on Center Tunnel
	_spawn_cylinder(int_root, "ShifterStalk", 0.012, 0.16, Vector3(0.06, 0.52, -0.22), Vector3(deg_to_rad(-10.0), 0.0, 0.0), _mat_chrome)
	var knob_sphere := SphereMesh.new()
	knob_sphere.radius = 0.026
	knob_sphere.height = 0.052
	var knob_inst := MeshInstance3D.new()
	knob_inst.mesh = knob_sphere
	knob_inst.position = Vector3(0.06, 0.60, -0.21)
	knob_inst.material_override = _mat_titanium_burnt
	int_root.add_child(knob_inst)

	# --- C. Dual Recaro / Bride Bucket Seats (Charcoal with Red Bolster Accents) ---
	for side in [-1.0, 1.0]:
		var seat_x: float = side * 0.36
		var seat_z: float = 0.08
		_spawn_box(int_root, "RecaroSeatBase", Vector3(0.46, 0.09, 0.48), Vector3(seat_x, 0.36, seat_z - 0.06), Vector3.ZERO, _mat_interior_dark)
		_spawn_box(int_root, "RecaroSeatBack", Vector3(0.44, 0.62, 0.09),
			Vector3(seat_x, 0.68, seat_z + 0.16), Vector3(deg_to_rad(-14.0), 0.0, 0.0), _mat_interior_dark)
		# Red Contrast Shoulder Bolsters & Cushion Insert
		_spawn_box(int_root, "RecaroRedShoulders", Vector3(0.50, 0.18, 0.10),
			Vector3(seat_x, 0.86, seat_z + 0.20), Vector3(deg_to_rad(-14.0), 0.0, 0.0), _mat_recaro_red)
		_spawn_box(int_root, "RecaroRedCushion", Vector3(0.30, 0.48, 0.10),
			Vector3(seat_x, 0.66, seat_z + 0.155), Vector3(deg_to_rad(-14.0), 0.0, 0.0), _mat_recaro_red)
		_spawn_box(int_root, "RecaroHeadrest", Vector3(0.24, 0.18, 0.08),
			Vector3(seat_x, 1.02, seat_z + 0.24), Vector3(deg_to_rad(-8.0), 0.0, 0.0), _mat_recaro_red)

	# --- D. Cusco Metallic Cyan Bolt-In Roll Cage with X-Brace ---
	var cage_r: float = 0.022
	# Main B-Pillar Hoop
	_spawn_cylinder(int_root, "RollCageTopBar", cage_r, 1.18, Vector3(0.0, 1.24, 0.36), Vector3(0.0, 0.0, deg_to_rad(90.0)), _mat_roll_cage)
	for side in [-1.0, 1.0]:
		_spawn_cylinder(int_root, "RollCageBPillar", cage_r, 0.88, Vector3(side * 0.58, 0.80, 0.36), Vector3.ZERO, _mat_roll_cage)
		_spawn_cylinder(int_root, "RollCageRearStrut", cage_r, 0.92,
			Vector3(side * 0.52, 0.98, 0.72), Vector3(deg_to_rad(48.0), 0.0, 0.0), _mat_roll_cage)
	# X-Brace Diagonal Bars visible through rear window
	_spawn_cylinder(int_root, "RollCageXBrace1", cage_r, 1.32,
		Vector3(0.0, 0.96, 0.68), Vector3(deg_to_rad(36.0), 0.0, deg_to_rad(52.0)), _mat_roll_cage)
	_spawn_cylinder(int_root, "RollCageXBrace2", cage_r, 1.32,
		Vector3(0.0, 0.96, 0.68), Vector3(deg_to_rad(36.0), 0.0, deg_to_rad(-52.0)), _mat_roll_cage)

# ==============================================================================
# 6. NISMO LMGT4 5-SPOKE FORGED WHEELS & BREMBO BRAKE ASSEMBLIES
# ==============================================================================
func _build_wheel_assembly(wheel_name: String, pos: Vector3, is_left: bool, is_front: bool) -> Node3D:
	var wheel_root := Node3D.new()
	wheel_root.name = wheel_name
	wheel_root.position = pos

	var side_sign: float = -1.0 if is_left else 1.0

	# 1. Tire Tread & Sidewall Stencil
	var tire_cyl := CylinderMesh.new()
	tire_cyl.top_radius = WHEEL_RADIUS
	tire_cyl.bottom_radius = WHEEL_RADIUS
	tire_cyl.height = WHEEL_WIDTH
	tire_cyl.radial_segments = 32
	var tire_inst := MeshInstance3D.new()
	tire_inst.name = "PotenzaTire"
	tire_inst.mesh = tire_cyl
	tire_inst.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
	tire_inst.material_override = _mat_tire_rubber
	wheel_root.add_child(tire_inst)

	# Sidewall Stencil Quad (Outer face)
	var stencil_quad := QuadMesh.new()
	stencil_quad.size = Vector2(WHEEL_RADIUS * 1.96, WHEEL_RADIUS * 1.96)
	var stencil_inst := MeshInstance3D.new()
	stencil_inst.name = "TireSidewallStencil"
	stencil_inst.mesh = stencil_quad
	stencil_inst.position = Vector3(side_sign * (WHEEL_WIDTH * 0.5 + 0.003), 0.0, 0.0)
	stencil_inst.rotation = Vector3(0.0, deg_to_rad(-90.0 if is_left else 90.0), 0.0)
	stencil_inst.material_override = _mat_tire_sidewall
	wheel_root.add_child(stencil_inst)

	# 2. Polished Stepped Chrome Outer Barrel Lip
	var lip_torus := TorusMesh.new()
	lip_torus.outer_radius = 0.245
	lip_torus.inner_radius = 0.212
	lip_torus.rings = 28
	lip_torus.ring_segments = 14
	var lip_inst := MeshInstance3D.new()
	lip_inst.name = "LMGT4SteppedLip"
	lip_inst.mesh = lip_torus
	lip_inst.position = Vector3(side_sign * (WHEEL_WIDTH * 0.42), 0.0, 0.0)
	lip_inst.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
	lip_inst.material_override = _mat_wheel_lip
	wheel_root.add_child(lip_inst)

	# 3. Deep Concave Nismo LMGT4 5-Spoke Center & Hub
	var hub_x: float = side_sign * (WHEEL_WIDTH * 0.24)
	_spawn_cylinder(wheel_root, "CenterHub", 0.068, 0.08,
		Vector3(hub_x, 0.0, 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0)), _mat_wheel_spoke)

	for s in range(5):
		var angle_rad: float = float(s) * TAU / 5.0
		var spoke_pivot := Node3D.new()
		spoke_pivot.name = "LMGT4Spoke_" + str(s)
		spoke_pivot.rotation = Vector3(angle_rad, 0.0, 0.0)
		wheel_root.add_child(spoke_pivot)

		# Concave angled spoke from recessed center hub out to stepped rim barrel
		_spawn_box(spoke_pivot, "SpokeArm", Vector3(0.026, 0.165, 0.052),
			Vector3(side_sign * (WHEEL_WIDTH * 0.31), 0.125, 0.0),
			Vector3(0.0, 0.0, side_sign * deg_to_rad(-14.0)), _mat_wheel_spoke)

		# Lug Nut
		_spawn_cylinder(spoke_pivot, "LugNut", 0.009, 0.03,
			Vector3(hub_x + side_sign * 0.03, 0.042, 0.0),
			Vector3(0.0, 0.0, deg_to_rad(90.0)), _mat_chrome)

	# 4. Ventilated Brake Rotor & Multi-Pot Brembo Caliper
	var rotor_radius: float = 0.185 if is_front else 0.172
	var rotor_x: float = side_sign * (WHEEL_WIDTH * 0.08)
	_spawn_cylinder(wheel_root, "VentilatedBrakeDisc", rotor_radius, 0.028,
		Vector3(rotor_x, 0.0, 0.0), Vector3(0.0, 0.0, deg_to_rad(90.0)), _mat_brake_rotor)

	var caliper_z: float = 0.115 if is_front else -0.105
	_spawn_box(wheel_root, "BremboCaliper", Vector3(0.068, 0.135, 0.082),
		Vector3(rotor_x + side_sign * 0.015, 0.04, caliper_z),
		Vector3(deg_to_rad(-18.0 if is_front else 18.0), 0.0, 0.0), _mat_brembo_caliper)

	return wheel_root

# ==============================================================================
# 7. TITANIUM EXHAUST & AUTHENTIC ANIME VFX (BACKFIRE, MANGA SMOKE, STREAMERS)
# ==============================================================================
func _build_exhaust_and_vfx(parent: Node3D) -> void:
	var vfx_root := Node3D.new()
	vfx_root.name = "ExhaustAndAnimeVFX"
	parent.add_child(vfx_root)

	# --- A. Large-Bore Nismo Weldina / Titanium Exhaust Canister (Left Side Exit) ---
	var exhaust_pos := Vector3(-0.48, 0.21, 2.26)
	_spawn_cylinder(vfx_root, "TitaniumMufflerCanister", 0.095, 0.38,
		exhaust_pos + Vector3(0.04, 0.02, -0.18),
		Vector3(deg_to_rad(86.0), deg_to_rad(-10.0), 0.0), _mat_chrome)

	var tip_cyl := CylinderMesh.new()
	tip_cyl.top_radius = 0.068
	tip_cyl.bottom_radius = 0.068
	tip_cyl.height = 0.22
	tip_cyl.radial_segments = 24
	var tip_inst := MeshInstance3D.new()
	tip_inst.name = "BurntTitaniumTip"
	tip_inst.mesh = tip_cyl
	tip_inst.position = exhaust_pos
	tip_inst.rotation = Vector3(deg_to_rad(86.0), deg_to_rad(-10.0), 0.0)
	tip_inst.material_override = _mat_titanium_burnt
	vfx_root.add_child(tip_inst)

	# --- B. Dual-Cone Anime Backfire Particles (Cyan Core #00F8FF + Magenta Fringe #FF1493) ---
	var flame_origin := exhaust_pos + Vector3(-0.02, 0.0, 0.14)

	_particles_backfire_cyan = _create_backfire_particles("BackfireCyanCore", flame_origin, Color("#00F8FF"), 0.055, 0.32, 9.5)
	_particles_backfire_magenta = _create_backfire_particles("BackfireMagentaFringe", flame_origin, Color("#FF1493"), 0.095, 0.44, 6.5)
	vfx_root.add_child(_particles_backfire_cyan)
	vfx_root.add_child(_particles_backfire_magenta)

	_omni_backfire = OmniLight3D.new()
	_omni_backfire.name = "BackfireFlashLight"
	_omni_backfire.position = flame_origin + Vector3(0.0, 0.0, 0.22)
	_omni_backfire.light_color = Color(0.25, 0.85, 1.0)
	_omni_backfire.light_energy = 0.0
	_omni_backfire.omni_range = 4.5
	_omni_backfire.visible = false
	vfx_root.add_child(_omni_backfire)

	# --- C. Cel-Shaded Manga Tire Smoke (7 Radial Segments Low-Poly Toon Spheres) ---
	_particles_smoke_rl = _create_manga_smoke_particles("MangaSmokeRL", Vector3(-HALF_TRACK, 0.12, REAR_AXLE_Z + 0.18))
	_particles_smoke_rr = _create_manga_smoke_particles("MangaSmokeRR", Vector3(HALF_TRACK, 0.12, REAR_AXLE_Z + 0.18))
	vfx_root.add_child(_particles_smoke_rl)
	vfx_root.add_child(_particles_smoke_rr)

	# --- D. Manga Speed Streamers (GT Wing Endplates & Side Mirrors) ---
	_particles_streamer_wing_l = _create_wind_streamer_particles("WingStreamerL", Vector3(-0.835, 1.20, 2.28))
	_particles_streamer_wing_r = _create_wind_streamer_particles("WingStreamerR", Vector3(0.835, 1.20, 2.28))
	_particles_streamer_mirror_l = _create_wind_streamer_particles("MirrorStreamerL", Vector3(-0.95, 0.89, -0.52))
	_particles_streamer_mirror_r = _create_wind_streamer_particles("MirrorStreamerR", Vector3(0.95, 0.89, -0.52))
	vfx_root.add_child(_particles_streamer_wing_l)
	vfx_root.add_child(_particles_streamer_wing_r)
	vfx_root.add_child(_particles_streamer_mirror_l)
	vfx_root.add_child(_particles_streamer_mirror_r)

func _create_backfire_particles(p_name: String, pos: Vector3, col: Color, radius: float, length: float, speed: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = p_name
	p.position = pos
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 0.92
	p.amount = 14
	p.lifetime = 0.14

	var p_mat := ParticleProcessMaterial.new()
	p_mat.direction = Vector3(-0.12, 0.05, 1.0)
	p_mat.spread = 8.5
	p_mat.initial_velocity_min = speed * 0.8
	p_mat.initial_velocity_max = speed * 1.2
	p_mat.gravity = Vector3.ZERO
	p_mat.scale_min = 0.7
	p_mat.scale_max = 1.35
	p.process_material = p_mat

	var cone := CylinderMesh.new()
	cone.top_radius = 0.005
	cone.bottom_radius = radius
	cone.height = length
	cone.radial_segments = 8

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = col
	cone.material = mat

	p.draw_pass_1 = cone
	return p

func _create_manga_smoke_particles(p_name: String, pos: Vector3) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = p_name
	p.position = pos
	p.emitting = false
	p.amount = 28
	p.lifetime = 0.85

	var p_mat := ParticleProcessMaterial.new()
	p_mat.direction = Vector3(0.0, 0.35, 1.0)
	p_mat.spread = 28.0
	p_mat.initial_velocity_min = 2.4
	p_mat.initial_velocity_max = 5.2
	p_mat.gravity = Vector3(0.0, 1.4, 0.0)
	p_mat.damping_min = 2.0
	p_mat.damping_max = 4.0
	p_mat.scale_min = 0.65
	p_mat.scale_max = 1.65
	p.process_material = p_mat

	var puff := SphereMesh.new()
	puff.radius = 0.24
	puff.height = 0.44
	puff.radial_segments = 7
	puff.rings = 5
	puff.material = _mat_manga_smoke

	p.draw_pass_1 = puff
	return p

func _create_wind_streamer_particles(p_name: String, pos: Vector3) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = p_name
	p.position = pos
	p.emitting = false
	p.amount = 16
	p.lifetime = 0.35

	var p_mat := ParticleProcessMaterial.new()
	p_mat.direction = Vector3(0.0, 0.0, 1.0)
	p_mat.spread = 1.8
	p_mat.initial_velocity_min = 12.0
	p_mat.initial_velocity_max = 18.0
	p_mat.gravity = Vector3.ZERO
	p.process_material = p_mat

	var ribbon := BoxMesh.new()
	ribbon.size = Vector3(0.015, 0.015, 0.85)
	ribbon.material = _mat_wind_streamer

	p.draw_pass_1 = ribbon
	return p

# ==============================================================================
# GEOMETRY HELPER UTILITIES
# ==============================================================================
func _add_quad(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3) -> void:
	st.add_vertex(v0)
	st.add_vertex(v1)
	st.add_vertex(v2)
	st.add_vertex(v0)
	st.add_vertex(v2)
	st.add_vertex(v3)

func _spawn_box(parent: Node3D, node_name: String, size: Vector3, pos: Vector3, rot: Vector3, mat: Material) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var inst := MeshInstance3D.new()
	inst.name = node_name
	inst.mesh = bm
	inst.position = pos
	inst.rotation = rot
	inst.material_override = mat
	parent.add_child(inst)
	return inst

func _spawn_cylinder(parent: Node3D, node_name: String, radius: float, height: float, pos: Vector3, rot: Vector3, mat: Material) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 20
	var inst := MeshInstance3D.new()
	inst.name = node_name
	inst.mesh = cm
	inst.position = pos
	inst.rotation = rot
	inst.material_override = mat
	parent.add_child(inst)
	return inst