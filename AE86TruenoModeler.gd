@tool
class_name AE86TruenoModeler
extends Node3D
## Complete Procedural Visual Rebuild of the 1986 Toyota AE86 Sprinter Trueno GT-APEX
## Engineered for Godot 4.3 (Vulkan Forward+) — Cyber-Anime / Initial D Touge Aesthetics

# ==============================================================================
# 1. ARCHITECTURAL CONTRACT: EXPOSED NODE REFERENCES FOR PHYSICS CONTROLLER
# ==============================================================================
var WheelFL: Node3D
var WheelFR: Node3D
var WheelRL: Node3D
var WheelRR: Node3D
var HeadlightHingeL: Node3D
var HeadlightHingeR: Node3D

# ==============================================================================
# 2. DIMENSIONAL SPECIFICATIONS (METERS, -Z FORWARD, +Y UP, +X RIGHT)
# ==============================================================================
const LENGTH: float = 4.20
const WIDTH: float = 1.62
const HEIGHT: float = 1.33
const WHEELBASE: float = 2.40
const TRACK_WIDTH: float = 1.44
const WHEEL_RADIUS: float = 0.30
const WHEEL_WIDTH: float = 0.20

const Z_FRONT_AXLE: float = -1.20
const Z_REAR_AXLE: float = 1.20
const X_LEFT: float = -0.72
const X_RIGHT: float = 0.72

# ==============================================================================
# 3. EDITOR & RUNTIME CONFIGURATION EXPORTS
# ==============================================================================
@export_group("Cyber Anime Aesthetics")
@export var rebuild_now: bool = false:
	set(value):
		if value:
			build_vehicle_mesh()
		rebuild_now = false

@export_enum("Ice Cyan:#00F3FF", "Pure Xenon White:#F0F8FF") var halo_color_preset: int = 0:
	set(value):
		halo_color_preset = value
		_update_halo_colors()

var _headlights_open: bool = true
@export var headlights_open: bool:
	get:
		return _headlights_open
	set(value):
		if _headlights_open == value and is_inside_tree():
			return
		_headlights_open = value
		if is_inside_tree():
			toggle_headlights(_headlights_open, Engine.is_editor_hint())

@export_range(0.0, 58.0, 0.5) var sleepy_eye_angle_deg: float = 54.0:
	set(value):
		sleepy_eye_angle_deg = value
		if headlights_open and is_inside_tree():
			toggle_headlights(true, true)

@export_range(-20.0, 20.0, 0.5) var wink_offset_deg: float = 0.0:
	set(value):
		wink_offset_deg = value
		if headlights_open and is_inside_tree():
			toggle_headlights(true, true)

@export var carbon_fiber_hood: bool = false:
	set(value):
		carbon_fiber_hood = value
		if is_inside_tree() and _hood_mesh_instance:
			_hood_mesh_instance.material_override = _mat_carbon_hood if carbon_fiber_hood else _mat_panda_white

@export_group("Interactive VFX Preview")
@export_range(0.0, 1.0, 0.01) var preview_brake_heat: float = 0.0:
	set(value):
		preview_brake_heat = value
		set_brake_heat(value)

@export var preview_drift_smoke: bool = false:
	set(value):
		preview_drift_smoke = value
		set_drift_vfx(value, 110.0 if value else 0.0)

@export var test_backfire_burst: bool = false:
	set(value):
		if value:
			trigger_backfire()
		test_backfire_burst = false

# ==============================================================================
# 4. INTERNAL CACHED MATERIALS & RUNTIME NODES
# ==============================================================================
var _mat_panda_white: Material
var _mat_panda_black: Material
var _mat_carbon_hood: Material
var _mat_manga_outline: ShaderMaterial
var _mat_window_glass: StandardMaterial3D
var _mat_interior_dark: StandardMaterial3D
var _mat_bride_red: StandardMaterial3D
var _mat_cusco_cage: StandardMaterial3D
var _mat_watanabe_spoke: StandardMaterial3D
var _mat_chrome_lip: StandardMaterial3D
var _mat_tire_rubber: StandardMaterial3D
var _mat_halo_neon: StandardMaterial3D
var _mat_projector_lens: StandardMaterial3D
var _mat_taillight_crimson: StandardMaterial3D
var _mat_taillight_amber: StandardMaterial3D
var _mat_taillight_reverse: StandardMaterial3D
var _mat_fog_yellow: StandardMaterial3D
var _mat_exhaust_titanium: StandardMaterial3D
var _mat_caliper_red: StandardMaterial3D
var _mat_tach_glow: StandardMaterial3D

var _rotor_materials: Array[StandardMaterial3D] = []
var _headlight_spots: Array[SpotLight3D] = []
var _taillight_omni: OmniLight3D
var _hood_mesh_instance: MeshInstance3D
var _headlight_tween: Tween

# VFX Nodes
var _smoke_particles_l: GPUParticles3D
var _smoke_particles_r: GPUParticles3D
var _backfire_particles: GPUParticles3D
var _backfire_light: OmniLight3D
var _streamers_nodes: Array[GPUParticles3D] = []

# ==============================================================================
# 5. LIFECYCLE & PUBLIC API
# ==============================================================================
func _ready() -> void:
	build_vehicle_mesh()


## Clears existing children, initializes cached materials, builds the complete
## AE86 Trueno visual hierarchy, binds required physics nodes, and returns self.
func build_vehicle_mesh() -> Node3D:
	# Clean up existing procedural children safely
	for child in get_children():
		remove_child(child)
		child.queue_free()

	_rotor_materials.clear()
	_headlight_spots.clear()
	_streamers_nodes.clear()

	_init_materials()

	var root_visuals := Node3D.new()
	root_visuals.name = "AE86_VisualRoot"
	add_child(root_visuals)

	# 1. Main Cel-Shaded Body Shell (Panda White Upper + Kuro Black Lower + Glass)
	_build_body_shell(root_visuals)

	# 2. Details: Bumpers, Kouki Taillights, Ducktail, Mirrors, Grille, Tofu Decal
	_build_exterior_details(root_visuals)

	# 3. Retractable Pop-Up Headlights with Cyber Anime Angel Eye Halos
	_build_popup_headlights(root_visuals)

	# 4. Visible Cockpit Interior (Bride Seats, Nardi Wheel, TRD Tach, Cusco Cage)
	_build_cockpit_interior(root_visuals)

	# 5. RS Watanabe 8-Spoke Wheels, glowing rotors, and ADVAN tire lettering
	_build_wheels_and_brakes(root_visuals)

	# 6. Stylized Anime VFX (Manga Smoke, Dual-Cone Backfire, Speed Streamers)
	_build_anime_vfx(root_visuals)

	# Apply initial states
	_update_halo_colors()
	toggle_headlights(headlights_open, true)
	set_brake_heat(preview_brake_heat)
	set_drift_vfx(preview_drift_smoke, 110.0 if preview_drift_smoke else 0.0)

	return self


## Smoothly actuates HeadlightHingeL and HeadlightHingeR between 0° and 54°
func toggle_headlights(open: bool, instant: bool = false) -> void:
	_headlights_open = open
	if not is_instance_valid(HeadlightHingeL) or not is_instance_valid(HeadlightHingeR):
		return

	var target_l_deg: float = sleepy_eye_angle_deg if open else 0.0
	var target_r_deg: float = clampf(sleepy_eye_angle_deg + wink_offset_deg, 0.0, 58.0) if open else 0.0

	# Positive X rotation tilts the front-hinged assembly upward so the recessed lens faces -Z
	var rot_l_rad: float = deg_to_rad(target_l_deg)
	var rot_r_rad: float = deg_to_rad(target_r_deg)

	if _headlight_tween and _headlight_tween.is_valid():
		_headlight_tween.kill()

	if instant:
		HeadlightHingeL.rotation.x = rot_l_rad
		HeadlightHingeR.rotation.x = rot_r_rad
		_set_headlight_illumination(open)
	else:
		if open:
			_set_headlight_illumination(true)
		_headlight_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_headlight_tween.tween_property(HeadlightHingeL, "rotation:x", rot_l_rad, 0.28)
		_headlight_tween.tween_property(HeadlightHingeR, "rotation:x", rot_r_rad, 0.28)
		if not open:
			_headlight_tween.chain().tween_callback(func(): _set_headlight_illumination(false))


## Dynamically heats all 4 brake rotors from matte dark iron to glowing cherry-orange
func set_brake_heat(heat: float) -> void:
	var h: float = clampf(heat, 0.0, 1.0)
	var cold_col := Color(0.22, 0.23, 0.25)
	var hot_albedo := Color(0.95, 0.22, 0.05)
	var glow_col := Color(1.0, 0.16, 0.02).lerp(Color(1.0, 0.55, 0.08), h)

	for mat in _rotor_materials:
		if is_instance_valid(mat):
			mat.albedo_color = cold_col.lerp(hot_albedo, h * 0.75)
			mat.emission_enabled = h > 0.02
			mat.emission = glow_col
			mat.emission_energy_multiplier = pow(h, 1.7) * 6.5

	# Also intensify Kouki brake lights when braking hard
	if is_instance_valid(_mat_taillight_crimson):
		_mat_taillight_crimson.emission_energy_multiplier = 2.8 + (h * 4.5)
	if is_instance_valid(_taillight_omni):
		_taillight_omni.light_energy = 0.8 + (h * 2.4)


## Emits a stylized anime dual-cone cyan/magenta afterburner flame burst & flash
func trigger_backfire() -> void:
	if is_instance_valid(_backfire_particles):
		_backfire_particles.restart()
		_backfire_particles.emitting = true

	if is_instance_valid(_backfire_light):
		_backfire_light.light_energy = 7.5
		var tw := create_tween()
		tw.tween_property(_backfire_light, "light_energy", 0.0, 0.16).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)


## Optional helper for ArcadeSimVehicle.gd to drive manga tire smoke and speed streamers
func set_drift_vfx(is_drifting: bool, speed_kmh: float = 100.0) -> void:
	if is_instance_valid(_smoke_particles_l):
		_smoke_particles_l.emitting = is_drifting
	if is_instance_valid(_smoke_particles_r):
		_smoke_particles_r.emitting = is_drifting

	var show_streamers: bool = is_drifting or (speed_kmh >= 90.0)
	for streamer in _streamers_nodes:
		if is_instance_valid(streamer):
			streamer.emitting = show_streamers


# ==============================================================================
# 6. SHADER & PBR MATERIAL INITIALIZATION
# ==============================================================================
func _init_materials() -> void:
	# Manga Inverted-Hull Ink Outline Shader (next_pass for crisp keyframe contours)
	var outline_shader := Shader.new()
	outline_shader.code = """
shader_type spatial;
render_mode cull_front, unshaded, depth_draw_always;

uniform vec4 ink_color : source_color = vec4(0.03, 0.04, 0.06, 1.0);
uniform float outline_width : hint_range(0.0, 0.02) = 0.0042;

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = ink_color.rgb;
}
"""
	_mat_manga_outline = ShaderMaterial.new()
	_mat_manga_outline.shader = outline_shader

	# Stylized Anime Cel-Shaded Car Paint Shader with Cyan Touge Rim Light
	var anime_paint_shader := Shader.new()
	anime_paint_shader.code = """
shader_type spatial;
render_mode diffuse_toon, specular_toon;

uniform vec4 paint_color : source_color = vec4(0.97, 0.98, 1.0, 1.0);
uniform float roughness_val : hint_range(0.0, 1.0) = 0.14;
uniform float metallic_val : hint_range(0.0, 1.0) = 0.15;
uniform vec4 rim_tint : source_color = vec4(0.0, 0.95, 1.0, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.38;

void fragment() {
	ALBEDO = paint_color.rgb;
	ROUGHNESS = roughness_val;
	METALLIC = metallic_val;
	SPECULAR = 0.75;
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	EMISSION = rim_tint.rgb * fresnel * rim_strength;
}
"""
	# 1. High-Gloss Pearl Panda White
	var white_shader_mat := ShaderMaterial.new()
	white_shader_mat.shader = anime_paint_shader
	white_shader_mat.set_shader_parameter("paint_color", Color(0.96, 0.97, 0.99, 1.0))
	white_shader_mat.set_shader_parameter("roughness_val", 0.12)
	white_shader_mat.set_shader_parameter("metallic_val", 0.12)
	white_shader_mat.set_shader_parameter("rim_tint", Color(0.0, 0.95, 1.0, 1.0))
	white_shader_mat.set_shader_parameter("rim_strength", 0.32)
	white_shader_mat.next_pass = _mat_manga_outline
	_mat_panda_white = white_shader_mat

	# 2. Deep Satin Kuro Black (Lower Two-Tone & Bumpers)
	var black_shader_mat := ShaderMaterial.new()
	black_shader_mat.shader = anime_paint_shader
	black_shader_mat.set_shader_parameter("paint_color", Color(0.07, 0.075, 0.09, 1.0))
	black_shader_mat.set_shader_parameter("roughness_val", 0.34)
	black_shader_mat.set_shader_parameter("metallic_val", 0.20)
	black_shader_mat.set_shader_parameter("rim_tint", Color(0.0, 0.85, 1.0, 1.0))
	black_shader_mat.set_shader_parameter("rim_strength", 0.22)
	black_shader_mat.next_pass = _mat_manga_outline
	_mat_panda_black = black_shader_mat

	# 3. Project D Carbon Fiber Hood Material
	var carbon_mat := StandardMaterial3D.new()
	carbon_mat.albedo_color = Color(0.10, 0.11, 0.13)
	carbon_mat.metallic = 0.45
	carbon_mat.roughness = 0.24
	carbon_mat.clearcoat_enabled = true
	carbon_mat.clearcoat = 1.0
	carbon_mat.clearcoat_roughness = 0.08
	carbon_mat.next_pass = _mat_manga_outline
	_mat_carbon_hood = carbon_mat

	# 4. Smoked Semi-Transparent Window Glass (Allows Cockpit Visibility)
	_mat_window_glass = StandardMaterial3D.new()
	_mat_window_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_window_glass.albedo_color = Color(0.06, 0.10, 0.15, 0.42)
	_mat_window_glass.metallic = 0.85
	_mat_window_glass.roughness = 0.06
	_mat_window_glass.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX

	# 5. Cockpit & Exterior Detail Materials
	_mat_interior_dark = StandardMaterial3D.new()
	_mat_interior_dark.albedo_color = Color(0.08, 0.08, 0.10)
	_mat_interior_dark.roughness = 0.78

	_mat_bride_red = StandardMaterial3D.new()
	_mat_bride_red.albedo_color = Color(0.76, 0.07, 0.10)
	_mat_bride_red.roughness = 0.65

	_mat_cusco_cage = StandardMaterial3D.new()
	_mat_cusco_cage.albedo_color = Color(0.0, 0.68, 0.92)
	_mat_cusco_cage.metallic = 0.72
	_mat_cusco_cage.roughness = 0.22

	_mat_watanabe_spoke = StandardMaterial3D.new()
	_mat_watanabe_spoke.albedo_color = Color(0.22, 0.21, 0.20) # Gunmetal / Satin Bronze
	_mat_watanabe_spoke.metallic = 0.78
	_mat_watanabe_spoke.roughness = 0.32

	_mat_chrome_lip = StandardMaterial3D.new()
	_mat_chrome_lip.albedo_color = Color(0.92, 0.95, 0.98)
	_mat_chrome_lip.metallic = 0.98
	_mat_chrome_lip.roughness = 0.08

	_mat_tire_rubber = StandardMaterial3D.new()
	_mat_tire_rubber.albedo_color = Color(0.09, 0.09, 0.10)
	_mat_tire_rubber.roughness = 0.86
	_mat_tire_rubber.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON

	# 6. Cyber Anime Neon Halo & Emissive Optics
	_mat_halo_neon = StandardMaterial3D.new()
	_mat_halo_neon.albedo_color = Color("#00F3FF")
	_mat_halo_neon.emission_enabled = true
	_mat_halo_neon.emission = Color("#00F3FF")
	_mat_halo_neon.emission_energy_multiplier = 5.6

	_mat_projector_lens = StandardMaterial3D.new()
	_mat_projector_lens.albedo_color = Color("#F0F8FF")
	_mat_projector_lens.emission_enabled = true
	_mat_projector_lens.emission = Color("#F0F8FF")
	_mat_projector_lens.emission_energy_multiplier = 3.8

	_mat_taillight_crimson = StandardMaterial3D.new()
	_mat_taillight_crimson.albedo_color = Color(0.9, 0.02, 0.08)
	_mat_taillight_crimson.emission_enabled = true
	_mat_taillight_crimson.emission = Color(1.0, 0.04, 0.12)
	_mat_taillight_crimson.emission_energy_multiplier = 3.2

	_mat_taillight_amber = StandardMaterial3D.new()
	_mat_taillight_amber.albedo_color = Color(1.0, 0.45, 0.0)
	_mat_taillight_amber.emission_enabled = true
	_mat_taillight_amber.emission = Color(1.0, 0.50, 0.02)
	_mat_taillight_amber.emission_energy_multiplier = 1.8

	_mat_taillight_reverse = StandardMaterial3D.new()
	_mat_taillight_reverse.albedo_color = Color(0.78, 0.84, 0.90)
	_mat_taillight_reverse.emission_enabled = true
	_mat_taillight_reverse.emission = Color(0.85, 0.92, 1.0)
	_mat_taillight_reverse.emission_energy_multiplier = 1.1

	_mat_fog_yellow = StandardMaterial3D.new()
	_mat_fog_yellow.albedo_color = Color(1.0, 0.85, 0.05)
	_mat_fog_yellow.emission_enabled = true
	_mat_fog_yellow.emission = Color(1.0, 0.82, 0.0)
	_mat_fog_yellow.emission_energy_multiplier = 3.5

	_mat_exhaust_titanium = StandardMaterial3D.new()
	_mat_exhaust_titanium.albedo_color = Color(0.72, 0.76, 0.85)
	_mat_exhaust_titanium.metallic = 0.92
	_mat_exhaust_titanium.roughness = 0.15

	_mat_caliper_red = StandardMaterial3D.new()
	_mat_caliper_red.albedo_color = Color(0.88, 0.08, 0.08)
	_mat_caliper_red.metallic = 0.4
	_mat_caliper_red.roughness = 0.28

	_mat_tach_glow = StandardMaterial3D.new()
	_mat_tach_glow.albedo_color = Color(0.0, 0.95, 1.0)
	_mat_tach_glow.emission_enabled = true
	_mat_tach_glow.emission = Color(0.0, 0.95, 1.0)
	_mat_tach_glow.emission_energy_multiplier = 4.2


func _update_halo_colors() -> void:
	if not is_instance_valid(_mat_halo_neon):
		return
	var col: Color = Color("#00F3FF") if halo_color_preset == 0 else Color("#F0F8FF")
	_mat_halo_neon.albedo_color = col
	_mat_halo_neon.emission = col
	_mat_halo_neon.emission_energy_multiplier = 5.6 if headlights_open else 0.0


func _set_headlight_illumination(active: bool) -> void:
	_update_halo_colors()
	if is_instance_valid(_mat_projector_lens):
		_mat_projector_lens.emission_energy_multiplier = 4.2 if active else 0.0
	for spot in _headlight_spots:
		if is_instance_valid(spot):
			spot.visible = active


# ==============================================================================
# 7. PROCEDURAL AE86 FASTBACK BODY SHELL GENERATION (SURFACETOOL + ARRAYMESH)
# ==============================================================================
func _build_body_shell(parent: Node3D) -> void:
	var body_node := Node3D.new()
	body_node.name = "BodyShell"
	parent.add_child(body_node)

	# Longitudinal profile stations from front (-Z) to rear (+Z):
	# Each station defines: [z, y_bottom, y_panda_split, y_beltline, y_top, hw_bottom, hw_belt, hw_top]
	var profile: Array = [
		[-2.10, 0.22, 0.43, 0.56, 0.56, 0.72, 0.75, 0.68], # 0: Front Nose Tip
		[-1.92, 0.20, 0.45, 0.61, 0.61, 0.76, 0.78, 0.72], # 1: Pop-up Headlight Rear Line
		[-1.55, 0.19, 0.47, 0.68, 0.68, 0.79, 0.81, 0.75], # 2: Front Fender Arch Fore
		[-1.20, 0.19, 0.48, 0.72, 0.72, 0.80, 0.81, 0.76], # 3: Front Axle Center
		[-0.65, 0.18, 0.48, 0.78, 0.78, 0.79, 0.81, 0.76], # 4: Base of A-Pillar / Cowl
		[-0.18, 0.18, 0.48, 0.80, 1.31, 0.79, 0.81, 0.66], # 5: Windshield Header
		[ 0.48, 0.18, 0.48, 0.81, 1.33, 0.79, 0.81, 0.66], # 6: B-Pillar / Roof Peak
		[ 1.20, 0.19, 0.49, 0.82, 1.12, 0.80, 0.81, 0.65], # 7: C-Pillar / Rear Axle
		[ 1.88, 0.22, 0.50, 0.84, 0.86, 0.77, 0.79, 0.70], # 8: Rear Hatch Deck / Ducktail Base
		[ 2.10, 0.26, 0.50, 0.80, 0.80, 0.73, 0.75, 0.68], # 9: Rear Tail Tailboard
	]

	var st_black := SurfaceTool.new()
	st_black.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_white := SurfaceTool.new()
	st_white.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_hood := SurfaceTool.new()
	st_hood.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_glass := SurfaceTool.new()
	st_glass.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in range(profile.size() - 1):
		var s0: Array = profile[i]
		var s1: Array = profile[i + 1]

		var z0: float = s0[0]
		var z1: float = s1[0]

		# --- A. LOWER KURO BLACK TWO-TONE ROCKER & BUMPER SKIRT ---
		for side in [-1.0, 1.0]:
			var p0_bot := Vector3(s0[5] * side, s0[1], z0)
			var p1_bot := Vector3(s1[5] * side, s1[1], z1)
			var p1_mid := Vector3(s1[6] * side, s1[2], z1)
			var p0_mid := Vector3(s0[6] * side, s0[2], z0)
			if side > 0.0:
				_add_quad(st_black, p0_bot, p1_bot, p1_mid, p0_mid)
			else:
				_add_quad(st_black, p1_bot, p0_bot, p0_mid, p1_mid)

		# Underbody floor pan seal
		var fl_0 := Vector3(-s0[5], s0[1], z0)
		var fr_0 := Vector3( s0[5], s0[1], z0)
		var fr_1 := Vector3( s1[5], s1[1], z1)
		var fl_1 := Vector3(-s1[5], s1[1], z1)
		_add_quad(st_black, fl_0, fr_0, fr_1, fl_1)

		# --- B. UPPER PANDA WHITE QUARTER PANELS & DOORS (Split to beltline) ---
		for side in [-1.0, 1.0]:
			var p0_mid := Vector3(s0[6] * side, s0[2], z0)
			var p1_mid := Vector3(s1[6] * side, s1[2], z1)
			var p1_belt := Vector3(s1[6] * side, s1[3], z1)
			var p0_belt := Vector3(s0[6] * side, s0[3], z0)
			if side > 0.0:
				_add_quad(st_white, p0_mid, p1_mid, p1_belt, p0_belt)
			else:
				_add_quad(st_white, p1_mid, p0_mid, p0_belt, p1_belt)

		# --- C. HOOD, WINDSHIELD, ROOF & FASTBACK HATCH ---
		if i < 4:
			# Front Hood & Upper Fender Crease
			var hood_w0: float = s0[7] * 0.82
			var hood_w1: float = s1[7] * 0.82
			# Outer fender top strips (Panda White)
			for side in [-1.0, 1.0]:
				var f0_out := Vector3(s0[6] * side, s0[3], z0)
				var f1_out := Vector3(s1[6] * side, s1[3], z1)
				var f1_in := Vector3(hood_w1 * side, s1[4] + 0.01, z1)
				var f0_in := Vector3(hood_w0 * side, s0[4] + 0.01, z0)
				if side > 0.0:
					_add_quad(st_white, f0_out, f1_out, f1_in, f0_in)
				else:
					_add_quad(st_white, f1_out, f0_out, f0_in, f1_in)

			# Center Hood Panel (Supports Panda White or Project D Carbon Fiber)
			var h_l0 := Vector3(-hood_w0, s0[4] + 0.012, z0)
			var h_r0 := Vector3( hood_w0, s0[4] + 0.012, z0)
			var h_r1 := Vector3( hood_w1, s1[4] + 0.012, z1)
			var h_l1 := Vector3(-hood_w1, s1[4] + 0.012, z1)
			_add_quad(st_hood, h_l1, h_r1, h_r0, h_l0)

		elif i == 4:
			# Steeply Raked Front Windshield Glass + A-Pillars
			var w_l0 := Vector3(-s0[7] * 0.88, s0[4], z0)
			var w_r0 := Vector3( s0[7] * 0.88, s0[4], z0)
			var w_r1 := Vector3( s1[7] * 0.88, s1[4] - 0.01, z1)
			var w_l1 := Vector3(-s1[7] * 0.88, s1[4] - 0.01, z1)
			_add_quad(st_glass, w_l1, w_r1, w_r0, w_l0)

			# Side Window Glass Frame (Front Triangle / A-Pillar)
			for side in [-1.0, 1.0]:
				var b0 := Vector3(s0[6] * side, s0[3], z0)
				var b1 := Vector3(s1[6] * side, s1[3], z1)
				var t1 := Vector3(s1[7] * side, s1[4], z1)
				var t0 := Vector3(s0[7] * side, s0[4], z0)
				if side > 0.0:
					_add_quad(st_glass, b0, b1, t1, t0)
				else:
					_add_quad(st_glass, b1, b0, t0, t1)

		elif i >= 5 and i <= 7:
			# Cabin Roof Skin (i == 5) or Fastback Rear Glass Hatch (i == 6, 7)
			var r_l0 := Vector3(-s0[7], s0[4], z0)
			var r_r0 := Vector3( s0[7], s0[4], z0)
			var r_r1 := Vector3( s1[7], s1[4], z1)
			var r_l1 := Vector3(-s1[7], s1[4], z1)

			if i == 5:
				_add_quad(st_white, r_l1, r_r1, r_r0, r_l0)
			else:
				# Fastback hatch glass with painted side C-pillar frames
				var g_l0 := Vector3(-s0[7] * 0.84, s0[4] - 0.01, z0)
				var g_r0 := Vector3( s0[7] * 0.84, s0[4] - 0.01, z0)
				var g_r1 := Vector3( s1[7] * 0.84, s1[4] - 0.01, z1)
				var g_l1 := Vector3(-s1[7] * 0.84, s1[4] - 0.01, z1)
				_add_quad(st_glass, g_l1, g_r1, g_r0, g_l0)

				# C-Pillar side hatch rails
				_add_quad(st_white, r_l1, g_l1, g_l0, r_l0)
				_add_quad(st_white, g_r1, r_r1, r_r0, g_r0)

			# Side Door & Rear Quarter Windows
			for side in [-1.0, 1.0]:
				var b0 := Vector3(s0[6] * side, s0[3], z0)
				var b1 := Vector3(s1[6] * side, s1[3], z1)
				var t1 := Vector3(s1[7] * side, s1[4], z1)
				var t0 := Vector3(s0[7] * side, s0[4], z0)
				if side > 0.0:
					_add_quad(st_glass, b0, b1, t1, t0)
				else:
					_add_quad(st_glass, b1, b0, t0, t1)

		else:
			# Rear Deck Lid Tail Top
			var d_l0 := Vector3(-s0[7], s0[4], z0)
			var d_r0 := Vector3( s0[7], s0[4], z0)
			var d_r1 := Vector3( s1[7], s1[4], z1)
			var d_l1 := Vector3(-s1[7], s1[4], z1)
			_add_quad(st_white, d_l1, d_r1, d_r0, d_l0)

	# Cap Front Nose Fascia & Rear Tailgate Panel
	var f_s: Array = profile[0]
	_add_quad(
		st_black,
		Vector3(-f_s[5], f_s[1], f_s[0]),
		Vector3(-f_s[6], f_s[2], f_s[0]),
		Vector3( f_s[6], f_s[2], f_s[0]),
		Vector3( f_s[5], f_s[1], f_s[0])
	)
	_add_quad(
		st_white,
		Vector3(-f_s[6], f_s[2], f_s[0]),
		Vector3(-f_s[7], f_s[4], f_s[0]),
		Vector3( f_s[7], f_s[4], f_s[0]),
		Vector3( f_s[6], f_s[2], f_s[0])
	)

	var r_s: Array = profile[profile.size() - 1]
	_add_quad(
		st_black,
		Vector3( r_s[5], r_s[1], r_s[0]),
		Vector3( r_s[6], r_s[2], r_s[0]),
		Vector3(-r_s[6], r_s[2], r_s[0]),
		Vector3(-r_s[5], r_s[1], r_s[0])
	)
	_add_quad(
		st_white,
		Vector3( r_s[6], r_s[2], r_s[0]),
		Vector3( r_s[7], r_s[4], r_s[0]),
		Vector3(-r_s[7], r_s[4], r_s[0]),
		Vector3(-r_s[6], r_s[2], r_s[0])
	)

	# Commit SurfaceTools to MeshInstances
	st_black.generate_normals()
	var mesh_black := MeshInstance3D.new()
	mesh_black.name = "PandaLowerBlack"
	mesh_black.mesh = st_black.commit()
	mesh_black.material_override = _mat_panda_black
	body_node.add_child(mesh_black)

	st_white.generate_normals()
	var mesh_white := MeshInstance3D.new()
	mesh_white.name = "PandaUpperWhite"
	mesh_white.mesh = st_white.commit()
	mesh_white.material_override = _mat_panda_white
	body_node.add_child(mesh_white)

	st_hood.generate_normals()
	_hood_mesh_instance = MeshInstance3D.new()
	_hood_mesh_instance.name = "TruenoHood"
	_hood_mesh_instance.mesh = st_hood.commit()
	_hood_mesh_instance.material_override = _mat_carbon_hood if carbon_fiber_hood else _mat_panda_white
	body_node.add_child(_hood_mesh_instance)

	st_glass.generate_normals()
	var mesh_glass := MeshInstance3D.new()
	mesh_glass.name = "CabinGlass"
	mesh_glass.mesh = st_glass.commit()
	mesh_glass.material_override = _mat_window_glass
	body_node.add_child(mesh_glass)

	# Crisp Manga Panel Gap Lines & Pillars (A/B/C Pillars + Door Seams + Fender Flares)
	_build_pillars_and_fender_flares(body_node)


func _build_pillars_and_fender_flares(parent: Node3D) -> void:
	for side in [-1.0, 1.0]:
		# A-Pillar Trim
		var a_pillar := _create_box(Vector3(0.04, 0.045, 0.72), _mat_panda_black)
		a_pillar.position = Vector3(0.725 * side, 1.04, -0.42)
		a_pillar.rotation_degrees = Vector3(-48.0, 11.0 * side, 0.0)
		parent.add_child(a_pillar)

		# B-Pillar Trim (Kuro Black Window Frame)
		var b_pillar := _create_box(Vector3(0.035, 0.52, 0.055), _mat_panda_black)
		b_pillar.position = Vector3(0.735 * side, 1.06, 0.45)
		b_pillar.rotation_degrees.z = -14.0 * side
		parent.add_child(b_pillar)

		# C-Pillar Fastback Trim
		var c_pillar := _create_box(Vector3(0.05, 0.06, 0.82), _mat_panda_white)
		c_pillar.position = Vector3(0.69 * side, 1.08, 1.15)
		c_pillar.rotation_degrees = Vector3(24.0, -4.0 * side, 0.0)
		parent.add_child(c_pillar)

		# Manga Ink Door Panel Seam & Side Molding Strip
		var molding := _create_box(Vector3(0.025, 0.032, 3.85), _mat_panda_black)
		molding.position = Vector3(0.808 * side, 0.48, 0.0)
		parent.add_child(molding)

		var door_handle := _create_box(Vector3(0.035, 0.032, 0.12), _mat_panda_black)
		door_handle.position = Vector3(0.812 * side, 0.74, 0.28)
		parent.add_child(door_handle)

		# Sculpted JDM Wheel Arch Fender Flares (Front & Rear)
		for z_axle in [Z_FRONT_AXLE, Z_REAR_AXLE]:
			var flare := MeshInstance3D.new()
			var torus := TorusMesh.new()
			torus.inner_radius = 0.31
			torus.outer_radius = 0.365
			torus.rings = 24
			torus.ring_segments = 12
			flare.mesh = torus
			flare.material_override = _mat_panda_black
			flare.position = Vector3(0.76 * side, 0.32, z_axle)
			flare.rotation_degrees.z = 90.0
			flare.scale = Vector3(1.0, 0.45, 1.06)
			parent.add_child(flare)


# ==============================================================================
# 8. EXTERIOR DETAILS: BUMPERS, KOUKI TAILLIGHTS, DUCKTAIL & FUJIWARA DECAL
# ==============================================================================
func _build_exterior_details(parent: Node3D) -> void:
	var details := Node3D.new()
	details.name = "ExteriorDetails"
	parent.add_child(details)

	# --- 1. FRONT KOUKI AERO BUMPER, CHIN SPLITTER & CIBIE YELLOW FOG LIGHTS ---
	var front_bumper := _create_box(Vector3(1.56, 0.22, 0.16), _mat_panda_black)
	front_bumper.position = Vector3(0.0, 0.32, -2.08)
	details.add_child(front_bumper)

	var chin_lip := _create_box(Vector3(1.58, 0.055, 0.20), _mat_panda_black)
	chin_lip.position = Vector3(0.0, 0.18, -2.11)
	details.add_child(chin_lip)

	var front_grille := _create_box(Vector3(0.72, 0.075, 0.05), _mat_interior_dark)
	front_grille.position = Vector3(0.0, 0.49, -2.09)
	details.add_child(front_grille)

	for side in [-1.0, 1.0]:
		# Amber Front Bumper Turn Signals
		var turn_sig := _create_box(Vector3(0.20, 0.055, 0.06), _mat_taillight_amber)
		turn_sig.position = Vector3(0.56 * side, 0.36, -2.14)
		details.add_child(turn_sig)

		# Yellow JDM Touge Fog Lights recessed into lower grille opening
		var fog_lamp := _create_box(Vector3(0.14, 0.075, 0.06), _mat_fog_yellow)
		fog_lamp.position = Vector3(0.34 * side, 0.26, -2.13)
		details.add_child(fog_lamp)

		# Aerodynamic Side Mirrors
		var mirror_arm := _create_box(Vector3(0.12, 0.03, 0.04), _mat_panda_black)
		mirror_arm.position = Vector3(0.83 * side, 0.82, -0.45)
		details.add_child(mirror_arm)

		var mirror_housing := _create_box(Vector3(0.14, 0.09, 0.08), _mat_panda_black)
		mirror_housing.position = Vector3(0.90 * side, 0.85, -0.45)
		details.add_child(mirror_housing)

	# --- 2. REAR TRUNK DUCKTAIL SPOILER & KOUKI 3-PIECE TAILLIGHT ASSEMBLY ---
	var ducktail := _create_box(Vector3(1.42, 0.09, 0.16), _mat_panda_black)
	ducktail.position = Vector3(0.0, 0.87, 1.98)
	ducktail.rotation_degrees.x = 18.0
	details.add_child(ducktail)

	var rear_bumper := _create_box(Vector3(1.54, 0.22, 0.16), _mat_panda_black)
	rear_bumper.position = Vector3(0.0, 0.34, 2.08)
	details.add_child(rear_bumper)

	# Kouki Center Smoked Garnish Bar ("Sprinter Trueno")
	var center_garnish := _create_box(Vector3(1.38, 0.16, 0.05), _mat_interior_dark)
	center_garnish.position = Vector3(0.0, 0.64, 2.09)
	details.add_child(center_garnish)

	for side in [-1.0, 1.0]:
		# Upper Amber Turn Indicator Strip
		var tail_amber := _create_box(Vector3(0.42, 0.055, 0.065), _mat_taillight_amber)
		tail_amber.position = Vector3(0.46 * side, 0.68, 2.095)
		details.add_child(tail_amber)

		# Lower Deep Crimson Neon Brake Light Bar
		var tail_crimson := _create_box(Vector3(0.42, 0.075, 0.065), _mat_taillight_crimson)
		tail_crimson.position = Vector3(0.46 * side, 0.60, 2.095)
		details.add_child(tail_crimson)

		# Inner Reverse Light Lens
		var tail_rev := _create_box(Vector3(0.12, 0.075, 0.068), _mat_taillight_reverse)
		tail_rev.position = Vector3(0.18 * side, 0.60, 2.095)
		details.add_child(tail_rev)

	_taillight_omni = OmniLight3D.new()
	_taillight_omni.name = "KoukiTailGlow"
	_taillight_omni.light_color = Color(1.0, 0.05, 0.12)
	_taillight_omni.light_energy = 1.2
	_taillight_omni.omni_range = 2.8
	_taillight_omni.position = Vector3(0.0, 0.62, 2.22)
	details.add_child(_taillight_omni)

	# --- 3. STRAIGHT-PIPE FUJITSUBO / KAKIMOTO EXHAUST CANISTER ---
	var muffler := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.058
	cyl.bottom_radius = 0.058
	cyl.height = 0.36
	muffler.mesh = cyl
	muffler.material_override = _mat_exhaust_titanium
	muffler.position = Vector3(-0.46, 0.20, 2.06)
	muffler.rotation_degrees = Vector3(84.0, -10.0, 0.0)
	details.add_child(muffler)

	var exhaust_core := MeshInstance3D.new()
	var core_cyl := CylinderMesh.new()
	core_cyl.top_radius = 0.048
	core_cyl.bottom_radius = 0.048
	core_cyl.height = 0.05
	exhaust_core.mesh = core_cyl
	exhaust_core.material_override = _mat_interior_dark
	exhaust_core.position = Vector3(-0.48, 0.19, 2.22)
	exhaust_core.rotation_degrees = Vector3(84.0, -10.0, 0.0)
	details.add_child(exhaust_core)

	# --- 4. ICONIC FUJIWARA TOFU SHOP KANJI DOOR DECAL (藤原とうふ店（自家用）) ---
	_build_fujiwara_tofu_decal(details)


func _build_fujiwara_tofu_decal(parent: Node3D) -> void:
	# Render high-resolution Kanji texture via SubViewport so it works out-of-the-box without external PNGs
	var sub_vp := SubViewport.new()
	sub_vp.name = "TofuDecalViewport"
	sub_vp.size = Vector2i(1024, 256)
	sub_vp.transparent_bg = true
	sub_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(sub_vp)

	var label := Label.new()
	label.text = "藤原とうふ店 (自家用)"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size = Vector2(1024, 256)
	label.add_theme_color_override("font_color", Color(0.04, 0.04, 0.05, 1.0))
	label.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.02, 1.0))
	label.add_theme_constant_override("outline_size", 6)
	label.add_theme_font_size_override("font_size", 96)
	sub_vp.add_child(label)

	var decal_mat := StandardMaterial3D.new()
	decal_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	decal_mat.albedo_texture = sub_vp.get_texture()
	decal_mat.roughness = 0.2

	# Right-side (JDM Driver Side) & Left-side Door Decal Quads
	for side in [1.0, -1.0]:
		var decal_mesh := MeshInstance3D.new()
		decal_mesh.name = "FujiwaraTofuDecal_" + ("R" if side > 0.0 else "L")
		var qm := QuadMesh.new()
		qm.size = Vector2(0.95, 0.22)
		decal_mesh.mesh = qm
		decal_mesh.material_override = decal_mat
		decal_mesh.position = Vector3(0.814 * side, 0.63, 0.05)
		decal_mesh.rotation_degrees.y = 90.0 * side
		parent.add_child(decal_mesh)


# ==============================================================================
# 9. CYBER/ANIME "NEON EYES" RETRACTABLE POP-UP HEADLIGHTS
# ==============================================================================
func _build_popup_headlights(parent: Node3D) -> void:
	HeadlightHingeL = _create_single_popup_assembly("HeadlightHingeL", -0.50)
	parent.add_child(HeadlightHingeL)

	HeadlightHingeR = _create_single_popup_assembly("HeadlightHingeR", 0.50)
	parent.add_child(HeadlightHingeR)


func _create_single_popup_assembly(node_name: String, x_pos: float) -> Node3D:
	var hinge := Node3D.new()
	hinge.name = node_name
	# Hinge pivot placed at the front edge of the pop-up recess
	hinge.position = Vector3(x_pos, 0.565, -2.02)

	# Upper painted aerodynamic eyelid cover
	var lid := _create_box(Vector3(0.26, 0.03, 0.22), _mat_panda_white)
	lid.position = Vector3(0.0, 0.015, 0.09)
	hinge.add_child(lid)

	# Internal Kuro Black projector bucket housing
	var housing := _create_box(Vector3(0.24, 0.14, 0.18), _mat_panda_black)
	housing.position = Vector3(0.0, -0.055, 0.09)
	hinge.add_child(housing)

	# Recessed Front Face Group (Oriented to face forward -Z when hinge rotates +54° on X)
	var optics_mount := Node3D.new()
	optics_mount.position = Vector3(0.0, -0.055, 0.002)
	optics_mount.rotation_degrees.x = -54.0
	hinge.add_child(optics_mount)

	# High-intensity Xenon/Halogen Projector Pod
	var lens := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.045
	cyl.bottom_radius = 0.045
	cyl.height = 0.02
	lens.mesh = cyl
	lens.material_override = _mat_projector_lens
	lens.rotation_degrees.x = 90.0
	optics_mount.add_child(lens)

	# Glowing Cyber Anime LED Halo Ring ("Angel Eye")
	var halo_ring := MeshInstance3D.new()
	halo_ring.name = "CyberAngelEyeHalo"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.054
	torus.outer_radius = 0.068
	torus.rings = 28
	torus.ring_segments = 16
	halo_ring.mesh = torus
	halo_ring.material_override = _mat_halo_neon
	halo_ring.rotation_degrees.x = 90.0
	halo_ring.position = Vector3(0.0, 0.0, -0.006)
	optics_mount.add_child(halo_ring)

	# Upper Aggressive Cyber-Brow Accent LED Strip
	var brow_bar := _create_box(Vector3(0.21, 0.016, 0.015), _mat_halo_neon)
	brow_bar.position = Vector3(0.0, 0.055, -0.008)
	optics_mount.add_child(brow_bar)

	# Crisp Forward Halogen/Xenon SpotLight3D Beam
	var spot := SpotLight3D.new()
	spot.name = "TougeBeamSpot"
	spot.light_color = Color(0.92, 0.98, 1.0)
	spot.light_energy = 5.5
	spot.light_volumetric_fog_energy = 2.5
	spot.spot_range = 38.0
	spot.spot_angle = 34.0
	spot.spot_attenuation = 1.2
	spot.shadow_enabled = true
	spot.position = Vector3(0.0, 0.0, -0.04)
	spot.rotation_degrees.x = -6.0
	optics_mount.add_child(spot)
	_headlight_spots.append(spot)

	return hinge


# ==============================================================================
# 10. VISIBLE COCKPIT INTERIOR (BRIDE SEATS, NARDI WHEEL, TRD TACH, CUSCO CAGE)
# ==============================================================================
func _build_cockpit_interior(parent: Node3D) -> void:
	var cockpit := Node3D.new()
	cockpit.name = "CockpitInterior"
	parent.add_child(cockpit)

	# Interior Floor Tub & Center Transmission Tunnel
	var tub_floor := _create_box(Vector3(1.36, 0.06, 1.85), _mat_interior_dark)
	tub_floor.position = Vector3(0.0, 0.26, 0.15)
	cockpit.add_child(tub_floor)

	var center_tunnel := _create_box(Vector3(0.22, 0.18, 1.65), _mat_interior_dark)
	center_tunnel.position = Vector3(0.0, 0.36, 0.10)
	cockpit.add_child(center_tunnel)

	# AE86 Boxy JDM Dashboard & Instrument Binnacle
	var dashboard := _create_box(Vector3(1.38, 0.24, 0.38), _mat_interior_dark)
	dashboard.position = Vector3(0.0, 0.72, -0.46)
	cockpit.add_child(dashboard)

	# JDM Right-Hand Drive (RHD) Instrument Cluster + TRD 12,000 RPM Tachometer
	var cluster_hood := _create_box(Vector3(0.42, 0.14, 0.22), _mat_panda_black)
	cluster_hood.position = Vector3(0.36, 0.85, -0.42)
	cockpit.add_child(cluster_hood)

	var trd_tach := MeshInstance3D.new()
	var tach_cyl := CylinderMesh.new()
	tach_cyl.top_radius = 0.052
	tach_cyl.bottom_radius = 0.052
	tach_cyl.height = 0.06
	trd_tach.mesh = tach_cyl
	trd_tach.material_override = _mat_tach_glow
	trd_tach.position = Vector3(0.24, 0.87, -0.35)
	trd_tach.rotation_degrees.x = 78.0
	cockpit.add_child(trd_tach)

	# Nardi Classic Deep-Corn 3-Spoke Steering Wheel (RHD at X = +0.36)
	var steering_col := MeshInstance3D.new()
	var col_cyl := CylinderMesh.new()
	col_cyl.top_radius = 0.025
	col_cyl.bottom_radius = 0.025
	col_cyl.height = 0.26
	steering_col.mesh = col_cyl
	steering_col.material_override = _mat_panda_black
	steering_col.position = Vector3(0.36, 0.76, -0.26)
	steering_col.rotation_degrees.x = 68.0
	cockpit.add_child(steering_col)

	var nardi_rim := MeshInstance3D.new()
	var rim_torus := TorusMesh.new()
	rim_torus.inner_radius = 0.145
	rim_torus.outer_radius = 0.172
	rim_torus.rings = 24
	rim_torus.ring_segments = 12
	nardi_rim.mesh = rim_torus
	nardi_rim.material_override = _mat_panda_black
	nardi_rim.position = Vector3(0.36, 0.80, -0.14)
	nardi_rim.rotation_degrees.x = 68.0
	cockpit.add_child(nardi_rim)

	# Bride / Recaro Low-Max Red Bucket Seats (Driver RHD + Passenger LHD)
	for side in [-1.0, 1.0]:
		var seat_root := Node3D.new()
		seat_root.position = Vector3(0.35 * side, 0.34, 0.16)
		cockpit.add_child(seat_root)

		var cushion := _create_box(Vector3(0.42, 0.09, 0.46), _mat_bride_red)
		seat_root.add_child(cushion)

		var backrest := _create_box(Vector3(0.40, 0.64, 0.09), _mat_bride_red)
		backrest.position = Vector3(0.0, 0.32, 0.20)
		backrest.rotation_degrees.x = -14.0
		seat_root.add_child(backrest)

		# Shoulder bolsters
		var bolster := _create_box(Vector3(0.48, 0.18, 0.11), _mat_bride_red)
		bolster.position = Vector3(0.0, 0.48, 0.22)
		bolster.rotation_degrees.x = -14.0
		seat_root.add_child(bolster)

	# Cusco Metallic Cyan 4-Point Safety Roll Cage
	var main_hoop_top := _create_cylinder(0.022, 1.18, _mat_cusco_cage)
	main_hoop_top.position = Vector3(0.0, 1.22, 0.48)
	main_hoop_top.rotation_degrees.z = 90.0
	cockpit.add_child(main_hoop_top)

	var diag_bar := _create_cylinder(0.020, 1.15, _mat_cusco_cage)
	diag_bar.position = Vector3(0.0, 0.78, 0.48)
	diag_bar.rotation_degrees.z = 48.0
	cockpit.add_child(diag_bar)

	for side in [-1.0, 1.0]:
		var hoop_pillar := _create_cylinder(0.022, 0.88, _mat_cusco_cage)
		hoop_pillar.position = Vector3(0.58 * side, 0.78, 0.48)
		cockpit.add_child(hoop_pillar)

		var rear_stay := _create_cylinder(0.020, 0.96, _mat_cusco_cage)
		rear_stay.position = Vector3(0.54 * side, 0.84, 0.88)
		rear_stay.rotation_degrees.x = -46.0
		cockpit.add_child(rear_stay)


# ==============================================================================
# 11. RS WATANABE 8-SPOKE WHEELS, BRAKE ROTORS & ADVAN TIRE LETTERING
# ==============================================================================
func _build_wheels_and_brakes(parent: Node3D) -> void:
	var sidewall_tex: Texture2D = _create_advan_sidewall_texture(parent)

	WheelFL = _create_watanabe_wheel("WheelFL", Vector3(X_LEFT,  WHEEL_RADIUS, Z_FRONT_AXLE), true, sidewall_tex)
	WheelFR = _create_watanabe_wheel("WheelFR", Vector3(X_RIGHT, WHEEL_RADIUS, Z_FRONT_AXLE), false, sidewall_tex)
	WheelRL = _create_watanabe_wheel("WheelRL", Vector3(X_LEFT,  WHEEL_RADIUS, Z_REAR_AXLE),  true, sidewall_tex)
	WheelRR = _create_watanabe_wheel("WheelRR", Vector3(X_RIGHT, WHEEL_RADIUS, Z_REAR_AXLE),  false, sidewall_tex)

	parent.add_child(WheelFL)
	parent.add_child(WheelFR)
	parent.add_child(WheelRL)
	parent.add_child(WheelRR)


func _create_watanabe_wheel(node_name: String, pos: Vector3, is_left: bool, sidewall_tex: Texture2D) -> Node3D:
	var wheel_root := Node3D.new()
	wheel_root.name = node_name
	wheel_root.position = pos

	var out_sign: float = -1.0 if is_left else 1.0

	# 1. Tire Tread Cylinder
	var tire := _create_cylinder(WHEEL_RADIUS, WHEEL_WIDTH, _mat_tire_rubber, 32)
	tire.rotation_degrees.z = 90.0
	wheel_root.add_child(tire)

	# 2. Polished Chrome Deep-Dish Outer Barrel Lip
	var chrome_lip := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.165
	torus.outer_radius = 0.215
	torus.rings = 28
	torus.ring_segments = 12
	chrome_lip.mesh = torus
	chrome_lip.material_override = _mat_chrome_lip
	chrome_lip.position = Vector3(0.078 * out_sign, 0.0, 0.0)
	chrome_lip.rotation_degrees.z = 90.0
	wheel_root.add_child(chrome_lip)

	# 3. RS Watanabe 8-Spoke Gunmetal/Bronze Banana Spokes
	var hub := _create_cylinder(0.055, 0.12, _mat_watanabe_spoke, 16)
	hub.position = Vector3(0.025 * out_sign, 0.0, 0.0)
	hub.rotation_degrees.z = 90.0
	wheel_root.add_child(hub)

	for s in range(8):
		var angle_rad: float = s * (TAU / 8.0)
		var spoke := _create_box(Vector3(0.022, 0.135, 0.032), _mat_watanabe_spoke)
		var r_mid: float = 0.105
		spoke.position = Vector3(
			0.052 * out_sign,
			cos(angle_rad) * r_mid,
			sin(angle_rad) * r_mid
		)
		spoke.rotation.x = -angle_rad
		spoke.rotation.z = deg_to_rad(-8.0 * out_sign)
		wheel_root.add_child(spoke)

	# 4. Dynamic Glowing Brake Rotor Disc & Red 4-Pot Caliper
	var rotor_mat := StandardMaterial3D.new()
	rotor_mat.albedo_color = Color(0.22, 0.23, 0.25)
	rotor_mat.metallic = 0.82
	rotor_mat.roughness = 0.35
	_rotor_materials.append(rotor_mat)

	var rotor_disc := _create_cylinder(0.145, 0.022, rotor_mat, 24)
	rotor_disc.position = Vector3(-0.015 * out_sign, 0.0, 0.0)
	rotor_disc.rotation_degrees.z = 90.0
	wheel_root.add_child(rotor_disc)

	var caliper := _create_box(Vector3(0.052, 0.095, 0.055), _mat_caliper_red)
	caliper.position = Vector3(-0.015 * out_sign, 0.03, -0.105)
	wheel_root.add_child(caliper)

	# 5. White Sidewall Tire Lettering ("ADVAN NEOVA AD08R")
	var letter_mat := StandardMaterial3D.new()
	letter_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	letter_mat.albedo_texture = sidewall_tex
	letter_mat.roughness = 0.6

	var sidewall_quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(WHEEL_RADIUS * 1.92, WHEEL_RADIUS * 1.92)
	sidewall_quad.mesh = qm
	sidewall_quad.material_override = letter_mat
	sidewall_quad.position = Vector3((WHEEL_WIDTH * 0.505) * out_sign, 0.0, 0.0)
	sidewall_quad.rotation_degrees.y = -90.0 if is_left else 90.0
	wheel_root.add_child(sidewall_quad)

	return wheel_root


func _create_advan_sidewall_texture(parent: Node3D) -> Texture2D:
	var vp := SubViewport.new()
	vp.name = "AdvanSidewallViewport"
	vp.size = Vector2i(512, 512)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(vp)

	var top_lbl := Label.new()
	top_lbl.text = "ADVAN NEOVA"
	top_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top_lbl.size = Vector2(512, 120)
	top_lbl.position = Vector2(0, 18)
	top_lbl.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98, 0.92))
	top_lbl.add_theme_font_size_override("font_size", 34)
	vp.add_child(top_lbl)

	var bot_lbl := Label.new()
	bot_lbl.text = "AD08R  YOKOHAMA"
	bot_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bot_lbl.size = Vector2(512, 120)
	bot_lbl.position = Vector2(0, 442)
	bot_lbl.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98, 0.92))
	bot_lbl.add_theme_font_size_override("font_size", 30)
	vp.add_child(bot_lbl)

	return vp.get_texture()


# ==============================================================================
# 12. AUTHENTIC ANIME VFX: MANGA TIRE SMOKE, BACKFIRE & SPEED STREAMERS
# ==============================================================================
func _build_anime_vfx(parent: Node3D) -> void:
	var vfx_root := Node3D.new()
	vfx_root.name = "AnimeVFX"
	parent.add_child(vfx_root)

	# --- 1. STYLIZED CEL-SHADED MANGA TIRE SMOKE (REAR TIRES) ---
	var smoke_shader := Shader.new()
	smoke_shader.code = """
shader_type spatial;
render_mode diffuse_toon, specular_disabled;

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.95;
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	// Crisp dark manga ink contour on the silhouette of each smoke puff
	ALBEDO = mix(ALBEDO, vec3(0.08, 0.10, 0.14), step(0.58, rim) * 0.65);
}
"""
	var smoke_mat := ShaderMaterial.new()
	smoke_mat.shader = smoke_shader

	var puff_mesh := SphereMesh.new()
	puff_mesh.radius = 0.24
	puff_mesh.height = 0.44
	puff_mesh.radial_segments = 7 # Low-poly geometric comic volumes
	puff_mesh.rings = 5
	puff_mesh.material = smoke_mat

	var smoke_proc := ParticleProcessMaterial.new()
	smoke_proc.direction = Vector3(0.0, 0.35, 1.0)
	smoke_proc.spread = 28.0
	smoke_proc.initial_velocity_min = 2.4
	smoke_proc.initial_velocity_max = 5.2
	smoke_proc.gravity = Vector3(0.0, 1.4, 0.0)
	smoke_proc.damping_min = 1.5
	smoke_proc.damping_max = 3.0
	smoke_proc.scale_min = 0.7
	smoke_proc.scale_max = 2.4
	smoke_proc.color = Color(0.92, 0.95, 1.0, 1.0)

	_smoke_particles_l = GPUParticles3D.new()
	_smoke_particles_l.name = "MangaTireSmokeL"
	_smoke_particles_l.amount = 36
	_smoke_particles_l.lifetime = 0.85
	_smoke_particles_l.explosiveness = 0.15
	_smoke_particles_l.process_material = smoke_proc
	_smoke_particles_l.draw_pass_1 = puff_mesh
	_smoke_particles_l.position = Vector3(X_LEFT, 0.12, Z_REAR_AXLE + 0.18)
	_smoke_particles_l.emitting = false
	vfx_root.add_child(_smoke_particles_l)

	_smoke_particles_r = GPUParticles3D.new()
	_smoke_particles_r.name = "MangaTireSmokeR"
	_smoke_particles_r.amount = 36
	_smoke_particles_r.lifetime = 0.85
	_smoke_particles_r.explosiveness = 0.15
	_smoke_particles_r.process_material = smoke_proc
	_smoke_particles_r.draw_pass_1 = puff_mesh
	_smoke_particles_r.position = Vector3(X_RIGHT, 0.12, Z_REAR_AXLE + 0.18)
	_smoke_particles_r.emitting = false
	vfx_root.add_child(_smoke_particles_r)

	# --- 2. ANIME AFTERBURNER EXHAUST BACKFIRE (CYAN CORE + MAGENTA FRINGE) ---
	var flame_mat := StandardMaterial3D.new()
	flame_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flame_mat.vertex_color_use_as_albedo = true

	var cone_mesh := CylinderMesh.new()
	cone_mesh.top_radius = 0.005
	cone_mesh.bottom_radius = 0.065
	cone_mesh.height = 0.42
	cone_mesh.radial_segments = 8
	cone_mesh.material = flame_mat

	var flame_grad := Gradient.new()
	flame_grad.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	flame_grad.colors = PackedColorArray([
		Color(0.0, 0.98, 1.0, 1.0),  # Intense Cyan Core
		Color(1.0, 0.08, 0.65, 0.9), # Magenta Outer Fringe
		Color(0.4, 0.0, 0.8, 0.0)
	])
	var flame_ramp := GradientTexture1D.new()
	flame_ramp.gradient = flame_grad

	var backfire_proc := ParticleProcessMaterial.new()
	backfire_proc.direction = Vector3(-0.15, 0.05, 1.0)
	backfire_proc.spread = 8.0
	backfire_proc.initial_velocity_min = 6.0
	backfire_proc.initial_velocity_max = 11.0
	backfire_proc.gravity = Vector3.ZERO
	backfire_proc.scale_min = 0.8
	backfire_proc.scale_max = 1.6
	backfire_proc.color_ramp = flame_ramp
	backfire_proc.particle_flag_align_y = true

	_backfire_particles = GPUParticles3D.new()
	_backfire_particles.name = "AfterburnerBackfire"
	_backfire_particles.amount = 14
	_backfire_particles.lifetime = 0.14
	_backfire_particles.one_shot = true
	_backfire_particles.explosiveness = 0.92
	_backfire_particles.process_material = backfire_proc
	_backfire_particles.draw_pass_1 = cone_mesh
	_backfire_particles.position = Vector3(-0.48, 0.19, 2.26)
	_backfire_particles.emitting = false
	vfx_root.add_child(_backfire_particles)

	_backfire_light = OmniLight3D.new()
	_backfire_light.name = "BackfireFlashLight"
	_backfire_light.light_color = Color(0.25, 0.85, 1.0)
	_backfire_light.light_energy = 0.0
	_backfire_light.omni_range = 3.5
	_backfire_light.position = Vector3(-0.48, 0.19, 2.38)
	vfx_root.add_child(_backfire_light)

	# --- 3. MANGA SPEED / DRIFT WIND STREAMERS (DUCKTAIL & SIDE MIRRORS) ---
	var streak_mat := StandardMaterial3D.new()
	streak_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	streak_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	streak_mat.albedo_color = Color(0.55, 0.96, 1.0, 0.55)

	var streak_box := BoxMesh.new()
	streak_box.size = Vector3(0.014, 0.014, 1.35)
	streak_box.material = streak_mat

	var streak_proc := ParticleProcessMaterial.new()
	streak_proc.direction = Vector3(0.0, 0.0, 1.0)
	streak_proc.spread = 1.8
	streak_proc.initial_velocity_min = 14.0
	streak_proc.initial_velocity_max = 18.0
	streak_proc.gravity = Vector3.ZERO

	var streamer_mounts: Array[Vector3] = [
		Vector3(-0.68, 0.90, 2.02), # Left Ducktail Tip
		Vector3( 0.68, 0.90, 2.02), # Right Ducktail Tip
		Vector3(-0.92, 0.85, -0.42), # Left Side Mirror
		Vector3( 0.92, 0.85, -0.42), # Right Side Mirror
	]

	for i in range(streamer_mounts.size()):
		var streamer := GPUParticles3D.new()
		streamer.name = "MangaSpeedStreamer_" + str(i)
		streamer.amount = 10
		streamer.lifetime = 0.25
		streamer.process_material = streak_proc
		streamer.draw_pass_1 = streak_box
		streamer.position = streamer_mounts[i]
		streamer.emitting = false
		vfx_root.add_child(streamer)
		_streamers_nodes.append(streamer)


# ==============================================================================
# 13. GEOMETRY & PRIMITIVE HELPER UTILITIES
# ==============================================================================
func _add_quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(p0)
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(p1)
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(p2)

	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(p0)
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(p2)
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(p3)


func _create_box(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	return mi


func _create_cylinder(radius: float, height: float, mat: Material, radial_segments: int = 16) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = radial_segments
	mi.mesh = cm
	mi.material_override = mat
	return mi