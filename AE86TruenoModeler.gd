@tool
class_name AE86TruenoModeler
extends Node3D

# ==============================================================================
# TOYOTA SPRINTER TRUENO AE86 (GT-APEX KOUKI / PROJECT D SPEC)
# High-Definition Anime Cel-Shaded Procedural Vehicle Generator (Godot 4.3+)
# ==============================================================================

# --- MANDATORY PHYSICS SUSPENSION HOOKS ---
var WheelFL: Node3D
var WheelFR: Node3D
var WheelRL: Node3D
var WheelRR: Node3D
var HeadlightHingeL: Node3D
var HeadlightHingeR: Node3D

# --- EXPORTED CONFIGURATION WITH RECURSION GUARDS ---
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

@export var rebuild_trigger: bool = false:
	set(value):
		if value:
			build_vehicle_mesh()
		rebuild_trigger = false

var _carbon_hood_enabled: bool = true
@export var carbon_hood_enabled: bool:
	get:
		return _carbon_hood_enabled
	set(value):
		if _carbon_hood_enabled == value:
			return
		_carbon_hood_enabled = value
		if is_inside_tree():
			build_vehicle_mesh()

var _outline_thickness: float = 0.019
@export_range(0.005, 0.040, 0.001) var outline_thickness: float = 0.019:
	get:
		return _outline_thickness
	set(value):
		_outline_thickness = value
		if _mat_outline != null:
			_mat_outline.set_shader_parameter("outline_width", _outline_thickness)

# --- INTERNAL RUNTIME REFERENCES ---
var _headlight_tween: Tween = null
var _backfire_tween: Tween = null
var _brake_disc_materials: Array[StandardMaterial3D] = []
var _headlight_spot_l: SpotLight3D = null
var _headlight_spot_r: SpotLight3D = null
var _backfire_cone: MeshInstance3D = null
var _backfire_light: OmniLight3D = null
var _drift_ribbon_l: MeshInstance3D = null
var _drift_ribbon_r: MeshInstance3D = null
var _speed_lines_node: Node3D = null

# --- SHARED ANIME MATERIALS ---
var _mat_outline: ShaderMaterial
var _mat_outline_thin: ShaderMaterial
var _mat_panda_white: ShaderMaterial
var _mat_panda_black: ShaderMaterial
var _mat_carbon_hood: ShaderMaterial
var _mat_glass_tinted: ShaderMaterial
var _mat_watanabe_gunmetal: ShaderMaterial
var _mat_chrome_lip: ShaderMaterial
var _mat_tire_rubber: ShaderMaterial
var _mat_interior_dark: ShaderMaterial
var _mat_bride_red: ShaderMaterial
var _mat_rollcage_yellow: ShaderMaterial
var _mat_taillight_red: StandardMaterial3D
var _mat_taillight_amber: StandardMaterial3D
var _mat_taillight_reverse: StandardMaterial3D
var _mat_headlight_angel: StandardMaterial3D
var _mat_fog_yellow: StandardMaterial3D
var _mat_exhaust_titanium: StandardMaterial3D
var _mat_underbody: StandardMaterial3D

# --- REAL-WORLD AE86 DIMENSIONS (METERS) ---
const WHEELBASE: float = 2.400
const FRONT_AXLE_Z: float = -1.200
const REAR_AXLE_Z: float = 1.200
const TRACK_FRONT_X: float = 0.715
const TRACK_REAR_X: float = 0.720
const WHEEL_RADIUS: float = 0.292
const TIRE_WIDTH: float = 0.205


func _ready() -> void:
	build_vehicle_mesh()


# ==============================================================================
# PUBLIC API
# ==============================================================================

func build_vehicle_mesh() -> Node3D:
	# Clean up previous generated child nodes
	for child in get_children():
		remove_child(child)
		child.free()

	_brake_disc_materials.clear()
	_init_anime_materials()

	var chassis_root := Node3D.new()
	chassis_root.name = "ChassisRoot"
	add_child(chassis_root)

	# 1. Main Smooth-Curved Two-Tone Unibody Shell & Blister Fenders
	_build_smooth_unibody(chassis_root)

	# 2. Kouki Aero Bumpers, Chin Lip, Grille & Yellow Fog Lights
	_build_front_aero_assembly(chassis_root)
	_build_rear_bumper_and_exhaust(chassis_root)

	# 3. Recessed Glazing, Black Window Trim, B/C Pillars & Hatch Spoiler
	_build_glazing_and_trim(chassis_root)

	# 4. Kouki Redline Smoked Rear Taillight Garnish & License Plate
	_build_kouki_taillights(chassis_root)

	# 5. Exterior Details (JDM Aero Mirrors, Wipers, Door Handles, Kanji Decal)
	_build_exterior_details(chassis_root)

	# 6. Detailed RHD Cockpit (Bride Seats, Roll Cage, TRD 12k Tach, Nardi Wheel)
	_build_detailed_cockpit(chassis_root)

	# 7. Retractable Pop-Up Headlight Hinges (HeadlightHingeL / HeadlightHingeR)
	_build_popup_headlights(chassis_root)

	# 8. Four RS Watanabe 8-Spoke Wheels & Brake Assemblies
	_build_all_wheels()

	# 9. Touge Drift Ribbon Trails & Anime Speed Lines
	_build_vfx_nodes(chassis_root)

	toggle_headlights(_headlights_open, true)
	return self


func toggle_headlights(open: bool, instant: bool = false) -> void:
	_headlights_open = open
	var target_pitch_deg: float = -54.0 if open else 0.0

	if _headlight_tween != null and _headlight_tween.is_valid():
		_headlight_tween.kill()

	if instant or not is_inside_tree():
		if HeadlightHingeL != null:
			HeadlightHingeL.rotation_degrees.x = target_pitch_deg
		if HeadlightHingeR != null:
			HeadlightHingeR.rotation_degrees.x = target_pitch_deg
		_update_headlight_beams(open)
		return

	_headlight_tween = create_tween().set_parallel(true)
	_headlight_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if HeadlightHingeL != null:
		_headlight_tween.tween_property(HeadlightHingeL, "rotation_degrees:x", target_pitch_deg, 0.28)
	if HeadlightHingeR != null:
		_headlight_tween.tween_property(HeadlightHingeR, "rotation_degrees:x", target_pitch_deg, 0.28)
	_update_headlight_beams(open)


func _update_headlight_beams(open: bool) -> void:
	if _headlight_spot_l != null:
		_headlight_spot_l.visible = open
	if _headlight_spot_r != null:
		_headlight_spot_r.visible = open
	if _mat_headlight_angel != null:
		_mat_headlight_angel.emission_energy_multiplier = 4.8 if open else 0.0


func set_brake_heat(heat: float) -> void:
	var clamped_heat: float = clampf(heat, 0.0, 1.0)
	var glow_col := Color(1.0, 0.18, 0.02).lerp(Color(1.0, 0.58, 0.12), clamped_heat)
	for mat in _brake_disc_materials:
		if mat != null:
			mat.emission_enabled = clamped_heat > 0.02
			mat.emission = glow_col
			mat.emission_energy_multiplier = clamped_heat * 5.0


func trigger_backfire() -> void:
	if _backfire_cone == null or _backfire_light == null:
		return

	if _backfire_tween != null and _backfire_tween.is_valid():
		_backfire_tween.kill()

	_backfire_cone.visible = true
	_backfire_light.visible = true
	_backfire_cone.scale = Vector3(1.15, 1.15, 1.45)
	_backfire_light.light_energy = 5.5

	if not is_inside_tree():
		_backfire_cone.visible = false
		_backfire_light.visible = false
		return

	_backfire_tween = create_tween().set_parallel(true)
	_backfire_tween.tween_property(_backfire_cone, "scale", Vector3(0.1, 0.1, 0.05), 0.14)
	_backfire_tween.tween_property(_backfire_light, "light_energy", 0.0, 0.14)
	_backfire_tween.chain().tween_callback(func():
		if _backfire_cone != null:
			_backfire_cone.visible = false
		if _backfire_light != null:
			_backfire_light.visible = false
	)


func set_drift_vfx(is_drifting: bool, speed_kmh: float = 100.0) -> void:
	var intensity: float = clampf((speed_kmh - 40.0) / 140.0, 0.0, 1.0)
	var active: bool = is_drifting and speed_kmh > 35.0
	if _drift_ribbon_l != null:
		_drift_ribbon_l.visible = active
		_drift_ribbon_l.scale.z = lerpf(0.4, 1.6, intensity)
	if _drift_ribbon_r != null:
		_drift_ribbon_r.visible = active
		_drift_ribbon_r.scale.z = lerpf(0.4, 1.6, intensity)
	if _speed_lines_node != null:
		_speed_lines_node.visible = active and speed_kmh > 85.0


# ==============================================================================
# CEL-SHADING & INVERTED-HULL OUTLINE SHADER ARCHITECTURE
# ==============================================================================

func _init_anime_materials() -> void:
	# 1. Inverted Hull Manga Outline Shader (Bold, camera-distance compensated)
	var outline_shader := Shader.new()
	outline_shader.code = """
shader_type spatial;
render_mode cull_front, unshaded, depth_draw_opaque;

uniform vec4 outline_color : source_color = vec4(0.03, 0.03, 0.05, 1.0);
uniform float outline_width : hint_range(0.002, 0.05) = 0.019;

void vertex() {
	vec3 view_pos = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float dist = clamp(-view_pos.z, 1.0, 35.0);
	float dist_scale = clamp(dist * 0.24 + 0.55, 0.85, 2.6);
	VERTEX += NORMAL * (outline_width * dist_scale);
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
"""
	_mat_outline = ShaderMaterial.new()
	_mat_outline.shader = outline_shader
	_mat_outline.set_shader_parameter("outline_color", Color(0.03, 0.03, 0.05, 1.0))
	_mat_outline.set_shader_parameter("outline_width", _outline_thickness)

	_mat_outline_thin = ShaderMaterial.new()
	_mat_outline_thin.shader = outline_shader
	_mat_outline_thin.set_shader_parameter("outline_color", Color(0.04, 0.04, 0.06, 1.0))
	_mat_outline_thin.set_shader_parameter("outline_width", _outline_thickness * 0.58)

	# 2. ArcSys / Initial D Legend 3-Band Stepped Cel-Shading Paint Shader
	var cel_paint_shader := Shader.new()
	cel_paint_shader.code = """
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec4 paint_color : source_color = vec4(0.97, 0.98, 0.99, 1.0);
uniform vec4 shadow_tint : source_color = vec4(0.08, 0.12, 0.22, 1.0);
uniform float shadow_mix : hint_range(0.0, 1.0) = 0.55;
uniform float spec_size : hint_range(0.80, 0.99) = 0.90;
uniform float spec_intensity : hint_range(0.0, 2.0) = 0.55;
uniform float rim_power : hint_range(1.0, 8.0) = 4.2;
uniform float rim_intensity : hint_range(0.0, 1.5) = 0.38;
uniform float hatch_density : hint_range(0.0, 300.0) = 0.0;
uniform bool carbon_weave = false;

varying vec3 v_local_pos;

void vertex() {
	v_local_pos = VERTEX;
}

void fragment() {
	vec3 base_col = paint_color.rgb;
	if (carbon_weave) {
		vec2 uv_weave = v_local_pos.xz * 95.0;
		float w1 = sin(uv_weave.x + uv_weave.y) * 0.5 + 0.5;
		float w2 = sin(uv_weave.x - uv_weave.y) * 0.5 + 0.5;
		float weave = smoothstep(0.25, 0.75, w1 * 0.65 + w2 * 0.35);
		base_col = mix(vec3(0.07, 0.075, 0.085), vec3(0.17, 0.18, 0.20), weave);
	}
	ALBEDO = base_col;
	ROUGHNESS = 0.25;
	METALLIC = 0.15;
}

void light() {
	float NdotL = dot(NORMAL, LIGHT);
	float light_band = smoothstep(-0.04, 0.05, NdotL);
	float deep_band = smoothstep(-0.42, -0.32, NdotL);

	vec3 lit_shadow = mix(ALBEDO * 0.42, shadow_tint.rgb, shadow_mix);
	vec3 deep_shadow = mix(ALBEDO * 0.22, shadow_tint.rgb * 0.65, shadow_mix);

	if (hatch_density > 1.0 && light_band < 0.5) {
		float line_pat = sin((v_local_pos.x + v_local_pos.y + v_local_pos.z) * hatch_density);
		if (line_pat > 0.35) {
			lit_shadow *= 0.78;
		}
	}

	vec3 shaded_col = mix(deep_shadow, lit_shadow, deep_band);
	shaded_col = mix(shaded_col, ALBEDO, light_band);

	vec3 H = normalize(LIGHT + VIEW);
	float NdotH = max(dot(NORMAL, H), 0.0);
	float spec_step = smoothstep(spec_size - 0.02, spec_size + 0.02, NdotH) * light_band;
	vec3 spec_col = vec3(1.0, 0.99, 0.96) * spec_step * spec_intensity;

	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	float rim_step = smoothstep(0.42, 0.52, fresnel) * max(light_band, 0.25);
	vec3 rim_col = mix(ALBEDO, vec3(0.82, 0.92, 1.0), 0.6) * rim_step * rim_intensity;

	vec3 light_energy = LIGHT_COLOR / 3.14159;
	DIFFUSE_LIGHT += shaded_col * ATTENUATION * light_energy;
	SPECULAR_LIGHT += (spec_col + rim_col) * ATTENUATION * light_energy;
}
"""

	# Fuji White (High-gloss Anime Cel White with cool blue-violet touge night shadow)
	_mat_panda_white = ShaderMaterial.new()
	_mat_panda_white.shader = cel_paint_shader
	_mat_panda_white.set_shader_parameter("paint_color", Color(0.973, 0.976, 0.985, 1.0))
	_mat_panda_white.set_shader_parameter("shadow_tint", Color(0.12, 0.16, 0.28, 1.0))
	_mat_panda_white.set_shader_parameter("shadow_mix", 0.58)
	_mat_panda_white.set_shader_parameter("spec_size", 0.89)
	_mat_panda_white.set_shader_parameter("spec_intensity", 0.72)
	_mat_panda_white.set_shader_parameter("rim_intensity", 0.45)
	_mat_panda_white.set_shader_parameter("hatch_density", 110.0)
	_mat_panda_white.next_pass = _mat_outline

	# Kuro Black Lower Trim & Bumpers
	_mat_panda_black = ShaderMaterial.new()
	_mat_panda_black.shader = cel_paint_shader
	_mat_panda_black.set_shader_parameter("paint_color", Color(0.11, 0.115, 0.135, 1.0))
	_mat_panda_black.set_shader_parameter("shadow_tint", Color(0.03, 0.04, 0.08, 1.0))
	_mat_panda_black.set_shader_parameter("shadow_mix", 0.65)
	_mat_panda_black.set_shader_parameter("spec_size", 0.91)
	_mat_panda_black.set_shader_parameter("spec_intensity", 0.48)
	_mat_panda_black.set_shader_parameter("rim_intensity", 0.35)
	_mat_panda_black.next_pass = _mat_outline

	# Project D Carbon Fiber Hood (or Fuji White when toggled off)
	_mat_carbon_hood = ShaderMaterial.new()
	_mat_carbon_hood.shader = cel_paint_shader
	_mat_carbon_hood.set_shader_parameter("paint_color", Color(0.973, 0.976, 0.985, 1.0))
	_mat_carbon_hood.set_shader_parameter("shadow_tint", Color(0.05, 0.07, 0.12, 1.0))
	_mat_carbon_hood.set_shader_parameter("shadow_mix", 0.55)
	_mat_carbon_hood.set_shader_parameter("spec_size", 0.88)
	_mat_carbon_hood.set_shader_parameter("spec_intensity", 0.68)
	_mat_carbon_hood.set_shader_parameter("rim_intensity", 0.40)
	_mat_carbon_hood.set_shader_parameter("carbon_weave", _carbon_hood_enabled)
	_mat_carbon_hood.next_pass = _mat_outline

	# 3. Anime Glass Shader with Diagonal Sky Glare Slash
	var glass_shader := Shader.new()
	glass_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back;

uniform vec4 glass_tint : source_color = vec4(0.07, 0.11, 0.18, 0.72);
uniform vec4 reflection_tint : source_color = vec4(0.65, 0.85, 1.0, 0.90);

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	float slash1 = smoothstep(0.08, 0.09, abs( fract((v_world_pos.x * 1.35 + v_world_pos.y * 1.9 + v_world_pos.z * 0.45)) - 0.5 ));
	float glare_band = 1.0 - slash1;
	vec3 col = mix(glass_tint.rgb, reflection_tint.rgb, clamp(fresnel * 0.75 + glare_band * 0.45, 0.0, 1.0));
	ALBEDO = col;
	ALPHA = clamp(glass_tint.a + glare_band * 0.18 + fresnel * 0.2, 0.0, 0.95);
	ROUGHNESS = 0.05;
}
"""
	_mat_glass_tinted = ShaderMaterial.new()
	_mat_glass_tinted.shader = glass_shader

	# 4. RS Watanabe Gunmetal / Dark Bronze Wheel Shader
	_mat_watanabe_gunmetal = ShaderMaterial.new()
	_mat_watanabe_gunmetal.shader = cel_paint_shader
	_mat_watanabe_gunmetal.set_shader_parameter("paint_color", Color(0.22, 0.21, 0.20, 1.0))
	_mat_watanabe_gunmetal.set_shader_parameter("shadow_tint", Color(0.06, 0.06, 0.09, 1.0))
	_mat_watanabe_gunmetal.set_shader_parameter("spec_size", 0.87)
	_mat_watanabe_gunmetal.set_shader_parameter("spec_intensity", 0.75)
	_mat_watanabe_gunmetal.set_shader_parameter("rim_intensity", 0.42)
	_mat_watanabe_gunmetal.next_pass = _mat_outline_thin

	# 5. Polished Machined Aluminum Rim Lip
	_mat_chrome_lip = ShaderMaterial.new()
	_mat_chrome_lip.shader = cel_paint_shader
	_mat_chrome_lip.set_shader_parameter("paint_color", Color(0.84, 0.87, 0.92, 1.0))
	_mat_chrome_lip.set_shader_parameter("shadow_tint", Color(0.22, 0.28, 0.38, 1.0))
	_mat_chrome_lip.set_shader_parameter("spec_size", 0.84)
	_mat_chrome_lip.set_shader_parameter("spec_intensity", 1.15)
	_mat_chrome_lip.set_shader_parameter("rim_intensity", 0.65)
	_mat_chrome_lip.next_pass = _mat_outline_thin

	# 6. Advan Neova Tire Rubber with White Stencil Sidewall
	_mat_tire_rubber = ShaderMaterial.new()
	_mat_tire_rubber.shader = cel_paint_shader
	_mat_tire_rubber.set_shader_parameter("paint_color", Color(0.10, 0.105, 0.12, 1.0))
	_mat_tire_rubber.set_shader_parameter("shadow_tint", Color(0.02, 0.02, 0.04, 1.0))
	_mat_tire_rubber.set_shader_parameter("spec_size", 0.93)
	_mat_tire_rubber.set_shader_parameter("spec_intensity", 0.22)
	_mat_tire_rubber.set_shader_parameter("rim_intensity", 0.20)
	_mat_tire_rubber.next_pass = _mat_outline_thin

	# 7. Interior Cel Materials
	_mat_interior_dark = ShaderMaterial.new()
	_mat_interior_dark.shader = cel_paint_shader
	_mat_interior_dark.set_shader_parameter("paint_color", Color(0.14, 0.15, 0.18, 1.0))
	_mat_interior_dark.set_shader_parameter("shadow_tint", Color(0.04, 0.05, 0.08, 1.0))
	_mat_interior_dark.set_shader_parameter("spec_intensity", 0.18)

	_mat_bride_red = ShaderMaterial.new()
	_mat_bride_red.shader = cel_paint_shader
	_mat_bride_red.set_shader_parameter("paint_color", Color(0.76, 0.11, 0.14, 1.0))
	_mat_bride_red.set_shader_parameter("shadow_tint", Color(0.24, 0.03, 0.08, 1.0))
	_mat_bride_red.set_shader_parameter("spec_intensity", 0.25)

	_mat_rollcage_yellow = ShaderMaterial.new()
	_mat_rollcage_yellow.shader = cel_paint_shader
	_mat_rollcage_yellow.set_shader_parameter("paint_color", Color(0.92, 0.72, 0.12, 1.0))
	_mat_rollcage_yellow.set_shader_parameter("shadow_tint", Color(0.35, 0.22, 0.04, 1.0))

	# 8. Emissive Lighting & Lamp Materials
	_mat_taillight_red = StandardMaterial3D.new()
	_mat_taillight_red.albedo_color = Color(0.88, 0.06, 0.08)
	_mat_taillight_red.emission_enabled = true
	_mat_taillight_red.emission = Color(1.0, 0.08, 0.10)
	_mat_taillight_red.emission_energy_multiplier = 2.6
	_mat_taillight_red.roughness = 0.15

	_mat_taillight_amber = StandardMaterial3D.new()
	_mat_taillight_amber.albedo_color = Color(0.95, 0.48, 0.04)
	_mat_taillight_amber.emission_enabled = true
	_mat_taillight_amber.emission = Color(1.0, 0.52, 0.05)
	_mat_taillight_amber.emission_energy_multiplier = 1.6
	_mat_taillight_amber.roughness = 0.15

	_mat_taillight_reverse = StandardMaterial3D.new()
	_mat_taillight_reverse.albedo_color = Color(0.92, 0.95, 1.0)
	_mat_taillight_reverse.emission_enabled = true
	_mat_taillight_reverse.emission = Color(0.85, 0.90, 1.0)
	_mat_taillight_reverse.emission_energy_multiplier = 0.65
	_mat_taillight_reverse.roughness = 0.15

	_mat_headlight_angel = StandardMaterial3D.new()
	_mat_headlight_angel.albedo_color = Color(0.92, 0.98, 1.0)
	_mat_headlight_angel.emission_enabled = true
	_mat_headlight_angel.emission = Color(0.75, 0.94, 1.0)
	_mat_headlight_angel.emission_energy_multiplier = 4.8

	_mat_fog_yellow = StandardMaterial3D.new()
	_mat_fog_yellow.albedo_color = Color(1.0, 0.85, 0.12)
	_mat_fog_yellow.emission_enabled = true
	_mat_fog_yellow.emission = Color(1.0, 0.82, 0.10)
	_mat_fog_yellow.emission_energy_multiplier = 3.2
	_mat_fog_yellow.roughness = 0.1

	_mat_exhaust_titanium = StandardMaterial3D.new()
	_mat_exhaust_titanium.albedo_color = Color(0.78, 0.80, 0.86)
	_mat_exhaust_titanium.metallic = 0.92
	_mat_exhaust_titanium.roughness = 0.18
	_mat_exhaust_titanium.next_pass = _mat_outline_thin

	_mat_underbody = StandardMaterial3D.new()
	_mat_underbody.albedo_color = Color(0.05, 0.05, 0.06)
	_mat_underbody.roughness = 0.9


# ==============================================================================
# 1. SMOOTH CURVED UNIBODY SHELL & BLISTER FENDERS
# ==============================================================================
# Instead of a 9-station flat cardboard box, we sample a dense 56-station
# longitudinal spline with smooth lateral crowning, wheel arch cutouts,
# JDM blister fender flares, and smooth vertex normals.

func _eval_station(z: float) -> Dictionary:
	# Longitudinal Z spans from -2.06m (front nose tip) to +2.06m (rear bumper valance)
	var half_w_bottom: float = 0.78
	var half_w_fender: float = 0.83
	var half_w_belt: float = 0.77
	var half_w_roof: float = 0.59

	# Planform taper at front nose and rear quarter
	if z < -1.25:
		var t_front: float = clampf((-1.25 - z) / 0.81, 0.0, 1.0)
		var curve_f: float = t_front * t_front
		half_w_bottom = lerpf(0.78, 0.69, curve_f)
		half_w_fender = lerpf(0.83, 0.71, curve_f)
		half_w_belt = lerpf(0.77, 0.67, curve_f)
	elif z > 1.15:
		var t_rear: float = clampf((z - 1.15) / 0.91, 0.0, 1.0)
		var curve_r: float = t_rear * t_rear
		half_w_bottom = lerpf(0.78, 0.71, curve_r)
		half_w_fender = lerpf(0.83, 0.74, curve_r)
		half_w_belt = lerpf(0.77, 0.69, curve_r)

	# Blister Fender Flares around front (Z=-1.20) and rear (Z=+1.20) axles
	var dist_f: float = absf(z - FRONT_AXLE_Z)
	var dist_r: float = absf(z - REAR_AXLE_Z)
	var flare_f: float = exp(-pow(dist_f / 0.38, 2.0)) * 0.042
	var flare_r: float = exp(-pow(dist_r / 0.40, 2.0)) * 0.046
	var total_flare: float = flare_f + flare_r
	half_w_fender += total_flare

	# Wheel Arch Cutout Elevation (Raises lower sill smoothly around wheels)
	var y_bottom: float = 0.175
	if dist_f < 0.365:
		var arch_f: float = sqrt(maxf(0.0, 1.0 - pow(dist_f / 0.365, 2.0)))
		y_bottom = maxf(y_bottom, 0.18 + arch_f * 0.315)
	if dist_r < 0.375:
		var arch_r: float = sqrt(maxf(0.0, 1.0 - pow(dist_r / 0.375, 2.0)))
		y_bottom = maxf(y_bottom, 0.18 + arch_r * 0.315)

	# Panda Two-Tone Paint Split Line (Classic AE86 horizontal crease)
	var y_panda_split: float = 0.455
	var y_shoulder: float = 0.645

	# Beltline & Hood / Cowl / Quarter Window Profile
	var y_belt: float = 0.795
	if z < -0.58:
		var t_hood: float = clampf((-0.58 - z) / 1.48, 0.0, 1.0)
		# Sleek wedge hood curving down to retractable headlight nose
		y_belt = lerpf(0.795, 0.565, pow(t_hood, 1.28))
		y_shoulder = minf(y_shoulder, y_belt - 0.035)
	elif z > 1.25:
		var t_tail: float = clampf((z - 1.25) / 0.81, 0.0, 1.0)
		y_belt = lerpf(0.795, 0.735, t_tail)

	# Greenhouse / Cabin Roof / Liftback Fastback Slope
	var y_roof: float = y_belt
	var w_roof: float = half_w_belt * 0.88
	var is_greenhouse: bool = (z >= -0.62 and z <= 1.78)
	if is_greenhouse:
		if z < -0.08:
			# 33-degree A-pillar / Windshield slope
			var t_ws: float = clampf((z - (-0.62)) / 0.54, 0.0, 1.0)
			var s_ws: float = smoothstep(0.0, 1.0, t_ws)
			y_roof = lerpf(y_belt, 1.265, s_ws)
			w_roof = lerpf(half_w_belt * 0.88, half_w_roof, s_ws)
		elif z <= 0.72:
			# Slightly crowned roof skin
			var crown_z: float = 1.0 - pow((z - 0.32) / 0.40, 2.0)
			y_roof = 1.265 + maxf(0.0, crown_z) * 0.014
			w_roof = half_w_roof
		else:
			# Iconic AE86 3-door Liftback rear hatch slope
			var t_hatch: float = clampf((z - 0.72) / 1.06, 0.0, 1.0)
			var s_hatch: float = pow(t_hatch, 1.15)
			y_roof = lerpf(1.265, y_belt + 0.02, s_hatch)
			w_roof = lerpf(half_w_roof, half_w_belt * 0.84, s_hatch)

	var y_arch_lip: float = maxf(y_bottom + 0.035, y_panda_split)

	return {
		"z": z,
		"w_bottom": half_w_bottom,
		"w_fender": half_w_fender,
		"w_belt": half_w_belt,
		"w_roof": w_roof,
		"y_bottom": y_bottom,
		"y_panda": y_arch_lip,
		"y_shoulder": maxf(y_shoulder, y_arch_lip + 0.04),
		"y_belt": maxf(y_belt, y_arch_lip + 0.08),
		"y_roof": maxf(y_roof, y_belt)
	}


func _build_smooth_unibody(parent: Node3D) -> void:
	var stations: Array[Dictionary] = []
	var num_steps: int = 56
	var z_start: float = -2.02
	var z_end: float = 2.02
	for i in range(num_steps + 1):
		var t: float = float(i) / float(num_steps)
		var z: float = lerpf(z_start, z_end, t)
		stations.append(_eval_station(z))

	# --- 1A. LOWER KURO BLACK ROCKER PANELS & LOWER FENDER FLARES ---
	var st_black := SurfaceTool.new()
	st_black.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in range(num_steps):
		var s0: Dictionary = stations[i]
		var s1: Dictionary = stations[i + 1]
		var z0: float = s0["z"]
		var z1: float = s1["z"]

		for side in [-1.0, 1.0]:
			var p00 := Vector3(side * (s0["w_bottom"] - 0.04), s0["y_bottom"], z0)
			var p01 := Vector3(side * s0["w_fender"], (s0["y_bottom"] + s0["y_panda"]) * 0.5, z0)
			var p02 := Vector3(side * s0["w_fender"], s0["y_panda"], z0)

			var p10 := Vector3(side * (s1["w_bottom"] - 0.04), s1["y_bottom"], z1)
			var p11 := Vector3(side * s1["w_fender"], (s1["y_bottom"] + s1["y_panda"]) * 0.5, z1)
			var p12 := Vector3(side * s1["w_fender"], s1["y_panda"], z1)

			if side > 0.0:
				_st_add_quad(st_black, p00, p10, p11, p01)
				_st_add_quad(st_black, p01, p11, p12, p02)
			else:
				_st_add_quad(st_black, p10, p00, p01, p11)
				_st_add_quad(st_black, p11, p01, p02, p12)

	st_black.generate_normals()
	_spawn_mesh(parent, "UnibodyPandaBlack", st_black.commit(), _mat_panda_black)

	# --- 1B. UPPER FUJI WHITE BODY SIDES, ROOF, A/C PILLARS & REAR HATCH ---
	var st_white := SurfaceTool.new()
	st_white.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in range(num_steps):
		var s0: Dictionary = stations[i]
		var s1: Dictionary = stations[i + 1]
		var z0: float = s0["z"]
		var z1: float = s1["z"]
		var z_mid: float = (z0 + z1) * 0.5

		for side in [-1.0, 1.0]:
			# Smooth 3-tier upper quarter panel & blister shoulder curve
			var a0 := Vector3(side * s0["w_fender"], s0["y_panda"], z0)
			var b0 := Vector3(side * (s0["w_fender"] + 0.008), s0["y_shoulder"], z0)
			var c0 := Vector3(side * s0["w_belt"], s0["y_belt"], z0)

			var a1 := Vector3(side * s1["w_fender"], s1["y_panda"], z1)
			var b1 := Vector3(side * (s1["w_fender"] + 0.008), s1["y_shoulder"], z1)
			var c1 := Vector3(side * s1["w_belt"], s1["y_belt"], z1)

			if side > 0.0:
				_st_add_quad(st_white, a0, a1, b1, b0)
				_st_add_quad(st_white, b0, b1, c1, c0)
			else:
				_st_add_quad(st_white, a1, a0, b0, b1)
				_st_add_quad(st_white, b1, b0, c0, c1)

			# Front Fender Top Crown (alongside the recessed carbon hood)
			if z_mid < -0.58:
				var f_in0 := Vector3(side * (s0["w_belt"] * 0.76), s0["y_belt"] + 0.015, z0)
				var f_in1 := Vector3(side * (s1["w_belt"] * 0.76), s1["y_belt"] + 0.015, z1)
				if side > 0.0:
					_st_add_quad(st_white, c0, c1, f_in1, f_in0)
				else:
					_st_add_quad(st_white, c1, c0, f_in0, f_in1)

		# Roof Skin & Rear Liftback Hatch Frame (Crowned across 6 lateral segments)
		if z_mid >= -0.10 and z_mid <= 0.76:
			_add_crowned_deck_strip(st_white, z0, z1, s0["w_roof"], s1["w_roof"], s0["y_roof"], s1["y_roof"], 0.022, 6)
		elif z_mid > 1.62:
			# Rear hatch lower deck lid below rear window
			_add_crowned_deck_strip(st_white, z0, z1, s0["w_belt"], s1["w_belt"], s0["y_belt"], s1["y_belt"], 0.016, 6)

	# Nose Header Panel between pop-up headlights (Fuji White)
	var s_nose0: Dictionary = _eval_station(-2.02)
	var s_nose1: Dictionary = _eval_station(-1.72)
	_add_crowned_deck_strip(st_white, -2.02, -1.72, s_nose0["w_belt"] * 0.52, s_nose1["w_belt"] * 0.52, s_nose0["y_belt"] + 0.008, s_nose1["y_belt"] + 0.012, 0.012, 4)

	# Windshield Cowl Vents Panel (between hood rear edge and windshield base)
	var s_cowl0: Dictionary = _eval_station(-0.68)
	var s_cowl1: Dictionary = _eval_station(-0.56)
	_add_crowned_deck_strip(st_white, -0.68, -0.56, s_cowl0["w_belt"], s_cowl1["w_belt"], s_cowl0["y_belt"] + 0.012, s_cowl1["y_belt"] + 0.012, 0.016, 6)

	st_white.generate_normals()
	_spawn_mesh(parent, "UnibodyFujiWhite", st_white.commit(), _mat_panda_white)

	# --- 1C. SCULPTED CARBON FIBER (OR FUJI WHITE) HOOD WITH CENTER POWER DOME ---
	var st_hood := SurfaceTool.new()
	st_hood.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hood_steps: int = 18
	var hz_start: float = -1.72
	var hz_end: float = -0.68
	for i in range(hood_steps):
		var z0: float = lerpf(hz_start, hz_end, float(i) / float(hood_steps))
		var z1: float = lerpf(hz_start, hz_end, float(i + 1) / float(hood_steps))
		var hs0: Dictionary = _eval_station(z0)
		var hs1: Dictionary = _eval_station(z1)

		# Cutouts at front corners (-1.72..-1.38) for pop-up headlights
		var w_factor0: float = 0.52 if z0 < -1.36 else 0.76
		var w_factor1: float = 0.52 if z1 < -1.36 else 0.76
		var hw0: float = hs0["w_belt"] * w_factor0
		var hw1: float = hs1["w_belt"] * w_factor1

		var lat_divs: int = 8
		for j in range(lat_divs):
			var u0: float = -1.0 + 2.0 * float(j) / float(lat_divs)
			var u1: float = -1.0 + 2.0 * float(j + 1) / float(lat_divs)

			var dome00: float = (1.0 - u0 * u0) * 0.022 + (0.012 if absf(u0) < 0.42 else 0.0)
			var dome01: float = (1.0 - u1 * u1) * 0.022 + (0.012 if absf(u1) < 0.42 else 0.0)

			var p00 := Vector3(u0 * hw0, hs0["y_belt"] + 0.014 + dome00, z0)
			var p01 := Vector3(u1 * hw0, hs0["y_belt"] + 0.014 + dome01, z0)
			var p10 := Vector3(u0 * hw1, hs1["y_belt"] + 0.014 + dome00, z1)
			var p11 := Vector3(u1 * hw1, hs1["y_belt"] + 0.014 + dome01, z1)
			_st_add_quad(st_hood, p00, p10, p11, p01)

	st_hood.generate_normals()
	_spawn_mesh(parent, "SculptedHood", st_hood.commit(), _mat_carbon_hood)

	# --- 1D. CURVED 3D WHEEL ARCH FLARE LIPS & INNER WELL LINERS ---
	_build_wheel_arches(parent)

	# --- 1E. DARK UNDERBODY CHASSIS FLOOR PAN ---
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(1.42, 0.06, 3.85)
	_spawn_mesh(parent, "UnderbodyPan", floor_mesh, _mat_underbody, Vector3(0.0, 0.19, 0.0))


func _add_crowned_deck_strip(st: SurfaceTool, z0: float, z1: float, w0: float, w1: float, y0: float, y1: float, crown_h: float, divs: int) -> void:
	for j in range(divs):
		var u0: float = -1.0 + 2.0 * float(j) / float(divs)
		var u1: float = -1.0 + 2.0 * float(j + 1) / float(divs)
		var c0: float = (1.0 - u0 * u0) * crown_h
		var c1: float = (1.0 - u1 * u1) * crown_h
		var p00 := Vector3(u0 * w0, y0 + c0, z0)
		var p01 := Vector3(u1 * w0, y0 + c1, z0)
		var p10 := Vector3(u0 * w1, y1 + c0, z1)
		var p11 := Vector3(u1 * w1, y1 + c1, z1)
		_st_add_quad(st, p00, p10, p11, p01)


func _build_wheel_arches(parent: Node3D) -> void:
	var st_arches := SurfaceTool.new()
	st_arches.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_liners := SurfaceTool.new()
	st_liners.begin(Mesh.PRIMITIVE_TRIANGLES)

	var axle_configs: Array[Dictionary] = [
		{"z": FRONT_AXLE_Z, "r": 0.355},
		{"z": REAR_AXLE_Z, "r": 0.365}
	]

	var arch_segs: int = 20
	for cfg in axle_configs:
		var cz: float = cfg["z"]
		var rad: float = cfg["r"]
		for side in [-1.0, 1.0]:
			for s in range(arch_segs):
				var a0: float = lerpf(0.08, PI - 0.08, float(s) / float(arch_segs))
				var a1: float = lerpf(0.08, PI - 0.08, float(s + 1) / float(arch_segs))

				var z0: float = cz - cos(a0) * rad
				var z1: float = cz - cos(a1) * rad
				var y0: float = 0.25 + sin(a0) * (rad * 0.76)
				var y1: float = 0.25 + sin(a1) * (rad * 0.76)

				var st0: Dictionary = _eval_station(z0)
				var st1: Dictionary = _eval_station(z1)
				var x_out0: float = side * (st0["w_fender"] + 0.012)
				var x_out1: float = side * (st1["w_fender"] + 0.012)
				var x_lip0: float = side * (st0["w_fender"] - 0.035)
				var x_lip1: float = side * (st1["w_fender"] - 0.035)
				var x_deep: float = side * 0.50

				var p_out0 := Vector3(x_out0, y0 + 0.025, z0)
				var p_out1 := Vector3(x_out1, y1 + 0.025, z1)
				var p_lip0 := Vector3(x_lip0, y0, z0)
				var p_lip1 := Vector3(x_lip1, y1, z1)
				var p_deep0 := Vector3(x_deep, y0 - 0.02, z0)
				var p_deep1 := Vector3(x_deep, y1 - 0.02, z1)

				if side > 0.0:
					_st_add_quad(st_arches, p_lip0, p_lip1, p_out1, p_out0)
					_st_add_quad(st_liners, p_deep0, p_deep1, p_lip1, p_lip0)
				else:
					_st_add_quad(st_arches, p_lip1, p_lip0, p_out0, p_out1)
					_st_add_quad(st_liners, p_deep1, p_deep0, p_lip0, p_lip1)

	st_arches.generate_normals()
	st_liners.generate_normals()
	_spawn_mesh(parent, "FenderArchLips", st_arches.commit(), _mat_panda_black)
	_spawn_mesh(parent, "WheelWellLiners", st_liners.commit(), _mat_underbody)


# ==============================================================================
# 2. FRONT AERO BUMPER, CHIN SPOILER, FOG LIGHTS & REAR BUMPER/EXHAUST
# ==============================================================================

func _build_front_aero_assembly(parent: Node3D) -> void:
	var front_node := Node3D.new()
	front_node.name = "FrontAeroAssembly"
	parent.add_child(front_node)

	# Wrap-around Kouki Front Bumper Bar (Curved multi-segment mesh)
	var st_bumper := SurfaceTool.new()
	st_bumper.begin(Mesh.PRIMITIVE_TRIANGLES)

	var b_pts: Array[Vector3] = [
		Vector3(-0.79, 0.0, -1.62),
		Vector3(-0.76, 0.0, -1.96),
		Vector3(-0.64, 0.0, -2.09),
		Vector3(-0.32, 0.0, -2.14),
		Vector3(0.00, 0.0, -2.155),
		Vector3(0.32, 0.0, -2.14),
		Vector3(0.64, 0.0, -2.09),
		Vector3(0.76, 0.0, -1.96),
		Vector3(0.79, 0.0, -1.62)
	]

	for i in range(b_pts.size() - 1):
		var c0: Vector3 = b_pts[i]
		var c1: Vector3 = b_pts[i + 1]

		# Upper bumper ledge, main bumper face, lower aero valance, chin lip
		var top_in0 := Vector3(c0.x * 0.94, 0.535, c0.z + 0.05)
		var top_out0 := Vector3(c0.x, 0.515, c0.z)
		var mid_out0 := Vector3(c0.x * 1.01, 0.375, c0.z - 0.015)
		var bot_in0 := Vector3(c0.x * 0.96, 0.215, c0.z + 0.03)
		var lip_out0 := Vector3(c0.x * 0.99, 0.165, c0.z - 0.025)

		var top_in1 := Vector3(c1.x * 0.94, 0.535, c1.z + 0.05)
		var top_out1 := Vector3(c1.x, 0.515, c1.z)
		var mid_out1 := Vector3(c1.x * 1.01, 0.375, c1.z - 0.015)
		var bot_in1 := Vector3(c1.x * 0.96, 0.215, c1.z + 0.03)
		var lip_out1 := Vector3(c1.x * 0.99, 0.165, c1.z - 0.025)

		_st_add_quad(st_bumper, top_in0, top_out0, top_out1, top_in1)
		_st_add_quad(st_bumper, top_out0, mid_out0, mid_out1, top_out1)
		_st_add_quad(st_bumper, mid_out0, bot_in0, bot_in1, mid_out1)
		_st_add_quad(st_bumper, bot_in0, lip_out0, lip_out1, bot_in1)

	st_bumper.generate_normals()
	_spawn_mesh(front_node, "KoukiFrontBumper", st_bumper.commit(), _mat_panda_black)

	# Recessed Radiator Air Dam & "TRUENO" Center Grille Slot
	var grille_box := BoxMesh.new()
	grille_box.size = Vector3(0.68, 0.065, 0.04)
	_spawn_mesh(front_node, "CenterTruenoGrille", grille_box, _mat_underbody, Vector3(0.0, 0.505, -2.11))

	var lower_intake := BoxMesh.new()
	lower_intake.size = Vector3(0.84, 0.11, 0.05)
	_spawn_mesh(front_node, "LowerRadiatorIntake", lower_intake, _mat_underbody, Vector3(0.0, 0.285, -2.11))

	# Kouki Amber Turn Signals (Flush in front bumper) & Yellow Cibie/Kouki Fog Lights
	var turn_mesh := BoxMesh.new()
	turn_mesh.size = Vector3(0.18, 0.052, 0.04)
	_spawn_mesh(front_node, "FrontTurnSignalL", turn_mesh, _mat_taillight_amber, Vector3(-0.52, 0.445, -2.12), Vector3(0.0, 10.0, 0.0))
	_spawn_mesh(front_node, "FrontTurnSignalR", turn_mesh, _mat_taillight_amber, Vector3(0.52, 0.445, -2.12), Vector3(0.0, -10.0, 0.0))

	var fog_housing_mesh := BoxMesh.new()
	fog_housing_mesh.size = Vector3(0.145, 0.078, 0.05)
	var fog_lens_mesh := BoxMesh.new()
	fog_lens_mesh.size = Vector3(0.125, 0.062, 0.055)
	for side in [-1.0, 1.0]:
		_spawn_mesh(front_node, "FogHousing_" + str(side), fog_housing_mesh, _mat_panda_black, Vector3(side * 0.35, 0.31, -2.125))
		_spawn_mesh(front_node, "FogLens_" + str(side), fog_lens_mesh, _mat_fog_yellow, Vector3(side * 0.35, 0.31, -2.13))

	# Front JDM License Plate (Gunma 55 / 13-954)
	var f_plate := BoxMesh.new()
	f_plate.size = Vector3(0.33, 0.165, 0.018)
	_spawn_mesh(front_node, "FrontLicensePlate", f_plate, _mat_panda_white, Vector3(0.0, 0.33, -2.155), Vector3(6.0, 0.0, 0.0))


func _build_rear_bumper_and_exhaust(parent: Node3D) -> void:
	var rear_node := Node3D.new()
	rear_node.name = "RearBumperAssembly"
	parent.add_child(rear_node)

	var st_rbumper := SurfaceTool.new()
	st_rbumper.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rb_pts: Array[Vector3] = [
		Vector3(0.79, 0.0, 1.56),
		Vector3(0.76, 0.0, 1.96),
		Vector3(0.66, 0.0, 2.11),
		Vector3(0.00, 0.0, 2.145),
		Vector3(-0.66, 0.0, 2.11),
		Vector3(-0.76, 0.0, 1.96),
		Vector3(-0.79, 0.0, 1.56)
	]

	for i in range(rb_pts.size() - 1):
		var c0: Vector3 = rb_pts[i]
		var c1: Vector3 = rb_pts[i + 1]

		var top_in0 := Vector3(c0.x * 0.94, 0.54, c0.z - 0.05)
		var top_out0 := Vector3(c0.x, 0.52, c0.z)
		var mid_out0 := Vector3(c0.x * 1.01, 0.38, c0.z + 0.015)
		var bot_in0 := Vector3(c0.x * 0.95, 0.21, c0.z - 0.04)

		var top_in1 := Vector3(c1.x * 0.94, 0.54, c1.z - 0.05)
		var top_out1 := Vector3(c1.x, 0.52, c1.z)
		var mid_out1 := Vector3(c1.x * 1.01, 0.38, c1.z + 0.015)
		var bot_in1 := Vector3(c1.x * 0.95, 0.21, c1.z - 0.04)

		_st_add_quad(st_rbumper, top_in0, top_out0, top_out1, top_in1)
		_st_add_quad(st_rbumper, top_out0, mid_out0, mid_out1, top_out1)
		_st_add_quad(st_rbumper, mid_out0, bot_in0, bot_in1, mid_out1)

	st_rbumper.generate_normals()
	_spawn_mesh(rear_node, "KoukiRearBumper", st_rbumper.commit(), _mat_panda_black)

	# Fujitsubo Legalis R Single-Exit Stainless Exhaust Muffler & Tip (Left Side)
	var muffler_can := CylinderMesh.new()
	muffler_can.top_radius = 0.075
	muffler_can.bottom_radius = 0.075
	muffler_can.height = 0.36
	_spawn_mesh(rear_node, "ExhaustMufflerCanister", muffler_can, _mat_exhaust_titanium, Vector3(-0.42, 0.20, 1.88), Vector3(90.0, 0.0, 0.0))

	var exhaust_tip := CylinderMesh.new()
	exhaust_tip.top_radius = 0.046
	exhaust_tip.bottom_radius = 0.046
	exhaust_tip.height = 0.18
	_spawn_mesh(rear_node, "ExhaustTailpipeTip", exhaust_tip, _mat_exhaust_titanium, Vector3(-0.42, 0.195, 2.11), Vector3(90.0, 0.0, 0.0))

	var exhaust_bore := CylinderMesh.new()
	exhaust_bore.top_radius = 0.039
	exhaust_bore.bottom_radius = 0.039
	exhaust_bore.height = 0.04
	_spawn_mesh(rear_node, "ExhaustInnerBore", exhaust_bore, _mat_underbody, Vector3(-0.42, 0.195, 2.185), Vector3(90.0, 0.0, 0.0))


# ==============================================================================
# 3. RECESSED GLAZING, BLACK WINDOW TRIM, PILLARS & TRUNK DUCKTAIL SPOILER
# ==============================================================================

func _build_glazing_and_trim(parent: Node3D) -> void:
	var glass_node := Node3D.new()
	glass_node.name = "GlazingAndPillars"
	parent.add_child(glass_node)

	# --- 3A. A, B, AND THICK FASTBACK C-PILLARS + WINDOW SEAL FRAMES ---
	var st_pillars := SurfaceTool.new()
	st_pillars.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_white_pillars := SurfaceTool.new()
	st_white_pillars.begin(Mesh.PRIMITIVE_TRIANGLES)

	for side in [-1.0, 1.0]:
		# A-Pillar (Fuji White outer + Black seal)
		var sa0: Dictionary = _eval_station(-0.60)
		var sa1: Dictionary = _eval_station(-0.08)
		var ap_b0 := Vector3(side * sa0["w_belt"], sa0["y_belt"], -0.60)
		var ap_b1 := Vector3(side * (sa0["w_belt"] - 0.055), sa0["y_belt"] + 0.01, -0.60)
		var ap_t0 := Vector3(side * sa1["w_roof"], sa1["y_roof"], -0.08)
		var ap_t1 := Vector3(side * (sa1["w_roof"] - 0.055), sa1["y_roof"] - 0.005, -0.08)
		if side > 0.0:
			_st_add_quad(st_white_pillars, ap_b0, ap_t0, ap_t1, ap_b1)
		else:
			_st_add_quad(st_white_pillars, ap_t0, ap_b0, ap_b1, ap_t1)

		# Roof Rail above side windows (Fuji White)
		var sr0: Dictionary = _eval_station(-0.08)
		var sr1: Dictionary = _eval_station(0.74)
		var rr_00 := Vector3(side * sr0["w_roof"], sr0["y_roof"], -0.08)
		var rr_01 := Vector3(side * (sr0["w_roof"] + 0.035), sr0["y_roof"] - 0.045, -0.08)
		var rr_10 := Vector3(side * sr1["w_roof"], sr1["y_roof"], 0.74)
		var rr_11 := Vector3(side * (sr1["w_roof"] + 0.035), sr1["y_roof"] - 0.045, 0.74)
		if side > 0.0:
			_st_add_quad(st_white_pillars, rr_01, rr_11, rr_10, rr_00)
		else:
			_st_add_quad(st_white_pillars, rr_11, rr_01, rr_00, rr_10)

		# B-Pillar (Matte Black vertical divider at Z = 0.34)
		var sb: Dictionary = _eval_station(0.34)
		var bp_00 := Vector3(side * (sb["w_belt"] - 0.012), sb["y_belt"], 0.30)
		var bp_01 := Vector3(side * (sb["w_belt"] - 0.012), sb["y_belt"], 0.38)
		var bp_10 := Vector3(side * (sb["w_roof"] + 0.025), sb["y_roof"] - 0.04, 0.32)
		var bp_11 := Vector3(side * (sb["w_roof"] + 0.025), sb["y_roof"] - 0.04, 0.39)
		if side > 0.0:
			_st_add_quad(st_pillars, bp_00, bp_01, bp_11, bp_10)
		else:
			_st_add_quad(st_pillars, bp_01, bp_00, bp_10, bp_11)

		# Iconic Thick AE86 3-Door Hatchback C-Pillar (Fuji White diagonal panel)
		var sc0: Dictionary = _eval_station(0.72)
		var sc1: Dictionary = _eval_station(1.62)
		var cp_f_top := Vector3(side * sc0["w_roof"], sc0["y_roof"], 0.72)
		var cp_r_top := Vector3(side * sc0["w_roof"], sc0["y_roof"] - 0.04, 0.90)
		var cp_f_bot := Vector3(side * sc1["w_belt"], sc1["y_belt"], 1.38)
		var cp_r_bot := Vector3(side * sc1["w_belt"], sc1["y_belt"], 1.64)
		if side > 0.0:
			_st_add_quad(st_white_pillars, cp_f_bot, cp_r_bot, cp_r_top, cp_f_top)
		else:
			_st_add_quad(st_white_pillars, cp_r_bot, cp_f_bot, cp_f_top, cp_r_top)

	st_pillars.generate_normals()
	st_white_pillars.generate_normals()
	_spawn_mesh(glass_node, "BlackBPillars", st_pillars.commit(), _mat_panda_black)
	_spawn_mesh(glass_node, "WhiteACPillars", st_white_pillars.commit(), _mat_panda_white)

	# --- 3B. CURVED TINTED WINDSHIELD, SIDE WINDOWS & FASTBACK HATCH GLASS ---
	var st_glass := SurfaceTool.new()
	st_glass.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Curved Front Windshield
	var ws_Bot: Dictionary = _eval_station(-0.58)
	var ws_Top: Dictionary = _eval_station(-0.08)
	_add_crowned_deck_strip(st_glass, -0.58, -0.08, ws_Bot["w_belt"] - 0.05, ws_Top["w_roof"] - 0.05, ws_Bot["y_belt"] + 0.01, ws_Top["y_roof"] - 0.01, 0.018, 6)

	# Fastback Rear Liftback Glass
	var rg_Top: Dictionary = _eval_station(0.76)
	var rg_Bot: Dictionary = _eval_station(1.60)
	_add_crowned_deck_strip(st_glass, 0.76, 1.60, rg_Top["w_roof"] - 0.04, rg_Bot["w_belt"] - 0.05, rg_Top["y_roof"] - 0.01, rg_Bot["y_belt"] + 0.015, 0.014, 6)

	# Recessed Side Door Glass & Rear Quarter Triangle Glass
	for side in [-1.0, 1.0]:
		var s_f: Dictionary = _eval_station(-0.52)
		var s_m: Dictionary = _eval_station(0.32)
		var s_q: Dictionary = _eval_station(1.36)
		var s_t: Dictionary = _eval_station(-0.06)
		var s_r: Dictionary = _eval_station(0.72)

		var inset: float = 0.022
		# Front Door Window
		var dw_b0 := Vector3(side * (s_f["w_belt"] - inset), s_f["y_belt"] + 0.01, -0.52)
		var dw_b1 := Vector3(side * (s_m["w_belt"] - inset), s_m["y_belt"] + 0.01, 0.32)
		var dw_t1 := Vector3(side * (s_m["w_roof"] + inset), s_t["y_roof"] - 0.04, 0.32)
		var dw_t0 := Vector3(side * (s_t["w_roof"] + inset), s_t["y_roof"] - 0.04, -0.06)

		# Rear Quarter Window
		var qw_b0 := Vector3(side * (s_m["w_belt"] - inset), s_m["y_belt"] + 0.01, 0.37)
		var qw_b1 := Vector3(side * (s_q["w_belt"] - inset), s_q["y_belt"] + 0.01, 1.35)
		var qw_t1 := Vector3(side * (s_r["w_roof"] + inset), s_r["y_roof"] - 0.04, 0.72)
		var qw_t0 := Vector3(side * (s_m["w_roof"] + inset), s_t["y_roof"] - 0.04, 0.37)

		if side > 0.0:
			_st_add_quad(st_glass, dw_b0, dw_b1, dw_t1, dw_t0)
			_st_add_quad(st_glass, qw_b0, qw_b1, qw_t1, qw_t0)
		else:
			_st_add_quad(st_glass, dw_b1, dw_b0, dw_t0, dw_t1)
			_st_add_quad(st_glass, qw_b1, qw_b0, qw_t0, qw_t1)

	st_glass.generate_normals()
	_spawn_mesh(glass_node, "TintedCabinGlass", st_glass.commit(), _mat_glass_tinted)

	# --- 3C. GT-APEX REAR HATCH DUCKTAIL / LIP SPOILER (Kuro Black) ---
	var spoiler_blade := BoxMesh.new()
	spoiler_blade.size = Vector3(1.32, 0.055, 0.14)
	_spawn_mesh(glass_node, "RearHatchDucktail", spoiler_blade, _mat_panda_black, Vector3(0.0, 0.805, 1.92), Vector3(14.0, 0.0, 0.0))


# ==============================================================================
# 4. KOUKI REDLINE SMOKED REAR TAILLIGHT CLUSTER & LICENSE GARNISH
# ==============================================================================

func _build_kouki_taillights(parent: Node3D) -> void:
	var tail_node := Node3D.new()
	tail_node.name = "KoukiTaillightCluster"
	parent.add_child(tail_node)

	# Full-width Smoked Center Garnish & Housing
	var garnish_box := BoxMesh.new()
	garnish_box.size = Vector3(1.36, 0.165, 0.045)
	_spawn_mesh(tail_node, "SmokedTaillightHousing", garnish_box, _mat_panda_black, Vector3(0.0, 0.635, 2.025))

	# Kouki Redline Top Accent Strip ("SPRINTER TRUENO")
	var redline_strip := BoxMesh.new()
	redline_strip.size = Vector3(1.34, 0.022, 0.052)
	_spawn_mesh(tail_node, "KoukiRedlineBar", redline_strip, _mat_taillight_red, Vector3(0.0, 0.702, 2.028))

	for side in [-1.0, 1.0]:
		# Outer Crimson Brake / Tail Lamp Squares
		var red_lamp := BoxMesh.new()
		red_lamp.size = Vector3(0.28, 0.088, 0.054)
		_spawn_mesh(tail_node, "BrakeLamp_" + str(side), red_lamp, _mat_taillight_red, Vector3(side * 0.52, 0.642, 2.03))

		# Upper Amber Turn Indicator Strip
		var amber_lamp := BoxMesh.new()
		amber_lamp.size = Vector3(0.22, 0.042, 0.054)
		_spawn_mesh(tail_node, "TurnLamp_" + str(side), amber_lamp, _mat_taillight_amber, Vector3(side * 0.55, 0.578, 2.03))

		# Inner Clear White Reverse Lenses flanking License Plate
		var rev_lamp := BoxMesh.new()
		rev_lamp.size = Vector3(0.11, 0.075, 0.054)
		_spawn_mesh(tail_node, "ReverseLamp_" + str(side), rev_lamp, _mat_taillight_reverse, Vector3(side * 0.30, 0.635, 2.03))

	# Rear Recessed JDM License Plate
	var r_plate := BoxMesh.new()
	r_plate.size = Vector3(0.33, 0.165, 0.02)
	_spawn_mesh(tail_node, "RearLicensePlate", r_plate, _mat_panda_white, Vector3(0.0, 0.615, 2.038))


# ==============================================================================
# 5. EXTERIOR DETAILS (FUJIWARA TOFU SHOP KANJI DECAL, MIRRORS, WIPERS, HANDLES)
# ==============================================================================

func _build_exterior_details(parent: Node3D) -> void:
	var details_node := Node3D.new()
	details_node.name = "ExteriorJDMDetails"
	parent.add_child(details_node)

	# --- 5A. ULTRA-CRISP RIGHT-DOOR "藤原とうふ店 (自家用)" KANJI DECAL ---
	# Rendered onto an unclipped QuadMesh positioned flush against the right door skin (+X = Right side)
	var kanji_shader := Shader.new()
	kanji_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;

void fragment() {
	ALBEDO = vec3(0.05, 0.05, 0.07);
	ROUGHNESS = 0.25;
}
"""
	var mat_kanji_plate := ShaderMaterial.new()
	mat_kanji_plate.shader = kanji_shader

	# Right Door (+X) & Left Door (-X) High-Contrast Crisp 3D Text Decal
	var lbl_right := Label3D.new()
	lbl_right.name = "FujiwaraKanjiRightDoor"
	lbl_right.text = "藤原とうふ店 (自家用)"
	lbl_right.font_size = 76
	lbl_right.pixel_size = 0.00145
	lbl_right.modulate = Color(0.04, 0.04, 0.06, 1.0)
	lbl_right.outline_modulate = Color(0.97, 0.98, 0.99, 1.0)
	lbl_right.outline_size = 4
	lbl_right.shaded = false
	lbl_right.double_sided = false
	lbl_right.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	# Positioned flush along the upper white panel of the right door (+X)
	lbl_right.position = Vector3(0.844, 0.565, -0.05)
	lbl_right.rotation_degrees = Vector3(0.0, 90.0, 0.0)
	details_node.add_child(lbl_right)

	# --- 5B. JDM DOOR MIRRORS, FLUSH HANDLES & WINDSHIELD WIPERS ---
	var mirror_stalk := BoxMesh.new()
	mirror_stalk.size = Vector3(0.09, 0.032, 0.045)
	var mirror_housing := BoxMesh.new()
	mirror_housing.size = Vector3(0.145, 0.095, 0.085)
	var handle_mesh := BoxMesh.new()
	handle_mesh.size = Vector3(0.025, 0.038, 0.135)

	for side in [-1.0, 1.0]:
		_spawn_mesh(details_node, "MirrorStalk_" + str(side), mirror_stalk, _mat_panda_black, Vector3(side * 0.79, 0.81, -0.44))
		_spawn_mesh(details_node, "MirrorHousing_" + str(side), mirror_housing, _mat_panda_black, Vector3(side * 0.86, 0.84, -0.43), Vector3(0.0, side * -12.0, 0.0))
		_spawn_mesh(details_node, "DoorHandle_" + str(side), handle_mesh, _mat_panda_black, Vector3(side * 0.805, 0.68, 0.20))

	# Dual Front Windshield Wipers + Rear Hatch Wiper
	var wiper_blade := BoxMesh.new()
	wiper_blade.size = Vector3(0.46, 0.016, 0.022)
	_spawn_mesh(details_node, "WiperFrontL", wiper_blade, _mat_panda_black, Vector3(-0.22, 0.825, -0.58), Vector3(25.0, -8.0, 6.0))
	_spawn_mesh(details_node, "WiperFrontR", wiper_blade, _mat_panda_black, Vector3(0.24, 0.825, -0.58), Vector3(25.0, -8.0, 6.0))
	_spawn_mesh(details_node, "WiperRearHatch", wiper_blade, _mat_panda_black, Vector3(0.08, 0.94, 1.38), Vector3(-22.0, 72.0, 0.0))


# ==============================================================================
# 6. DETAILED RHD COCKPIT (BRIDE SEATS, ROLL CAGE, 12K RPM TACH, NARDI WHEEL)
# ==============================================================================

func _build_detailed_cockpit(parent: Node3D) -> void:
	var cockpit := Node3D.new()
	cockpit.name = "RHDCockpitInterior"
	parent.add_child(cockpit)

	# Dashboard & Instrument Binnacle (Right-Hand Drive at X = +0.34)
	var dash_main := BoxMesh.new()
	dash_main.size = Vector3(1.36, 0.24, 0.38)
	_spawn_mesh(cockpit, "DashboardMain", dash_main, _mat_interior_dark, Vector3(0.0, 0.68, -0.42))

	var binnacle := BoxMesh.new()
	binnacle.size = Vector3(0.42, 0.14, 0.26)
	_spawn_mesh(cockpit, "GaugeClusterHood", binnacle, _mat_interior_dark, Vector3(0.34, 0.79, -0.38))

	# Glowing 12,000 RPM TRD Group-A Tachometer Dial & Orange Needle
	var tach_dial := CylinderMesh.new()
	tach_dial.top_radius = 0.055
	tach_dial.bottom_radius = 0.055
	tach_dial.height = 0.015
	_spawn_mesh(cockpit, "TRDTachometerDial", tach_dial, _mat_taillight_reverse, Vector3(0.38, 0.785, -0.25), Vector3(78.0, 0.0, 0.0))

	var tach_needle := BoxMesh.new()
	tach_needle.size = Vector3(0.008, 0.045, 0.008)
	_spawn_mesh(cockpit, "TRDTachNeedle", tach_needle, _mat_taillight_amber, Vector3(0.38, 0.795, -0.24), Vector3(-12.0, 0.0, -38.0))

	# Nardi Classic 3-Spoke Deep-Corn Steering Wheel (RHD at X = +0.34)
	var col_mesh := CylinderMesh.new()
	col_mesh.top_radius = 0.032
	col_mesh.bottom_radius = 0.032
	col_mesh.height = 0.26
	_spawn_mesh(cockpit, "SteeringColumn", col_mesh, _mat_interior_dark, Vector3(0.34, 0.73, -0.21), Vector3(68.0, 0.0, 0.0))

	var wheel_rim := TorusMesh.new()
	wheel_rim.inner_radius = 0.145
	wheel_rim.outer_radius = 0.175
	wheel_rim.rings = 24
	wheel_rim.ring_segments = 12
	_spawn_mesh(cockpit, "NardiSteeringWheel", wheel_rim, _mat_panda_black, Vector3(0.34, 0.76, -0.09), Vector3(68.0, 0.0, 0.0))

	# Bride Low-Max Carbon-Kevlar Racing Bucket Seats (Driver RHD + Passenger LHD)
	var seat_cushion := BoxMesh.new()
	seat_cushion.size = Vector3(0.46, 0.09, 0.48)
	var seat_back := BoxMesh.new()
	seat_back.size = Vector3(0.44, 0.62, 0.09)
	var seat_bolster := BoxMesh.new()
	seat_bolster.size = Vector3(0.52, 0.24, 0.12)

	for side_x in [-0.33, 0.33]:
		var mat_seat: ShaderMaterial = _mat_bride_red if side_x > 0.0 else _mat_interior_dark
		_spawn_mesh(cockpit, "BucketCushion_" + str(side_x), seat_cushion, mat_seat, Vector3(side_x, 0.36, 0.14))
		_spawn_mesh(cockpit, "BucketBackrest_" + str(side_x), seat_back, mat_seat, Vector3(side_x, 0.66, 0.34), Vector3(-14.0, 0.0, 0.0))
		_spawn_mesh(cockpit, "BucketShoulders_" + str(side_x), seat_bolster, mat_seat, Vector3(side_x, 0.82, 0.37), Vector3(-14.0, 0.0, 0.0))

	# Project D 6-Point Roll Cage (Main Hoop + Diagonal Rear Struts)
	var cage_bar_top := CylinderMesh.new()
	cage_bar_top.top_radius = 0.022
	cage_bar_top.bottom_radius = 0.022
	cage_bar_top.height = 1.12
	_spawn_mesh(cockpit, "RollCageMainHoopTop", cage_bar_top, _mat_rollcage_yellow, Vector3(0.0, 1.18, 0.48), Vector3(0.0, 0.0, 90.0))

	var cage_diag := CylinderMesh.new()
	cage_diag.top_radius = 0.020
	cage_diag.bottom_radius = 0.020
	cage_diag.height = 0.98
	_spawn_mesh(cockpit, "RollCageDiagBar", cage_diag, _mat_rollcage_yellow, Vector3(0.0, 0.84, 0.50), Vector3(0.0, 0.0, 46.0))
	for side in [-1.0, 1.0]:
		_spawn_mesh(cockpit, "RollCageRearStrut_" + str(side), cage_diag, _mat_rollcage_yellow, Vector3(side * 0.48, 0.88, 0.92), Vector3(52.0, 0.0, 0.0))


# ==============================================================================
# 7. RETRACTABLE POP-UP HEADLIGHTS (HeadlightHingeL / HeadlightHingeR)
# ==============================================================================

func _build_popup_headlights(parent: Node3D) -> void:
	# Recessed Nose Pockets under the headlights
	var pocket_mesh := BoxMesh.new()
	pocket_mesh.size = Vector3(0.32, 0.14, 0.34)
	for side in [-1.0, 1.0]:
		_spawn_mesh(parent, "HeadlightWell_" + str(side), pocket_mesh, _mat_underbody, Vector3(side * 0.51, 0.52, -1.86))

	HeadlightHingeL = _create_single_popup_assembly("HeadlightHingeL", Vector3(-0.51, 0.585, -1.72), true)
	parent.add_child(HeadlightHingeL)

	HeadlightHingeR = _create_single_popup_assembly("HeadlightHingeR", Vector3(0.51, 0.585, -1.72), false)
	parent.add_child(HeadlightHingeR)


func _create_single_popup_assembly(node_name: String, hinge_pos: Vector3, is_left: bool) -> Node3D:
	var hinge := Node3D.new()
	hinge.name = node_name
	hinge.position = hinge_pos

	# Painted Fuji White Top Lid (Flush with nose slope when closed at 0 deg)
	var lid_mesh := BoxMesh.new()
	lid_mesh.size = Vector3(0.30, 0.024, 0.31)
	_spawn_mesh(hinge, "TopLidCover", lid_mesh, _mat_panda_white, Vector3(0.0, 0.01, -0.155), Vector3(8.5, 0.0, 0.0))

	# Black Headlight Bucket Housing
	var bucket_mesh := BoxMesh.new()
	bucket_mesh.size = Vector3(0.28, 0.155, 0.27)
	_spawn_mesh(hinge, "HeadlightBucket", bucket_mesh, _mat_panda_black, Vector3(0.0, -0.075, -0.145), Vector3(8.5, 0.0, 0.0))

	# Raybrig / Cibie Rectangular Crystal Halogen Reflector & Cyber Angel-Eye Halo
	var lens_mesh := BoxMesh.new()
	lens_mesh.size = Vector3(0.235, 0.115, 0.025)
	_spawn_mesh(hinge, "HalogenCrystalLens", lens_mesh, _mat_headlight_angel, Vector3(0.0, -0.075, -0.278), Vector3(8.5, 0.0, 0.0))

	# Dynamic Forward SpotLight3D for Night Touge Driving
	var spot := SpotLight3D.new()
	spot.name = "TougeHeadlightBeam"
	spot.position = Vector3(0.0, -0.075, -0.29)
	spot.rotation_degrees = Vector3(-46.0, 0.0, 0.0) # Points forward when hinge rotates -54 deg
	spot.light_color = Color(0.95, 0.97, 1.0)
	spot.light_energy = 4.2
	spot.spot_range = 38.0
	spot.spot_angle = 34.0
	hinge.add_child(spot)

	if is_left:
		_headlight_spot_l = spot
	else:
		_headlight_spot_r = spot

	return hinge


# ==============================================================================
# 8. RS WATANABE 8-SPOKE DEEP-DISH WHEELS & VENTED BRAKE ASSEMBLIES
# ==============================================================================

func _build_all_wheels() -> void:
	WheelFL = _create_watanabe_wheel("WheelFL", Vector3(-TRACK_FRONT_X, WHEEL_RADIUS, FRONT_AXLE_Z), true)
	add_child(WheelFL)

	WheelFR = _create_watanabe_wheel("WheelFR", Vector3(TRACK_FRONT_X, WHEEL_RADIUS, FRONT_AXLE_Z), false)
	add_child(WheelFR)

	WheelRL = _create_watanabe_wheel("WheelRL", Vector3(-TRACK_REAR_X, WHEEL_RADIUS, REAR_AXLE_Z), true)
	add_child(WheelRL)

	WheelRR = _create_watanabe_wheel("WheelRR", Vector3(TRACK_REAR_X, WHEEL_RADIUS, REAR_AXLE_Z), false)
	add_child(WheelRR)


func _create_watanabe_wheel(wheel_name: String, wheel_pos: Vector3, is_left: bool) -> Node3D:
	var wheel_root := Node3D.new()
	wheel_root.name = wheel_name
	wheel_root.position = wheel_pos

	var out_sign: float = -1.0 if is_left else 1.0

	# 1. Yokohama Advan Neova Tire Tread & Crowned Sidewalls
	var st_tire := SurfaceTool.new()
	st_tire.begin(Mesh.PRIMITIVE_TRIANGLES)
	var radial_segs: int = 32
	var r_outer: float = WHEEL_RADIUS
	var r_shoulder: float = WHEEL_RADIUS - 0.022
	var r_rim: float = 0.192
	var half_w: float = TIRE_WIDTH * 0.5
	var bulge_w: float = half_w + 0.014

	for i in range(radial_segs):
		var a0: float = TAU * float(i) / float(radial_segs)
		var a1: float = TAU * float(i + 1) / float(radial_segs)
		var c0: float = cos(a0)
		var s0: float = sin(a0)
		var c1: float = cos(a1)
		var s1: float = sin(a1)

		var p_rim_l0 := Vector3(-half_w * 0.92, c0 * r_rim, s0 * r_rim)
		var p_bulge_l0 := Vector3(-bulge_w, c0 * ((r_rim + r_shoulder) * 0.5), s0 * ((r_rim + r_shoulder) * 0.5))
		var p_sh_l0 := Vector3(-half_w, c0 * r_shoulder, s0 * r_shoulder)
		var p_tr_l0 := Vector3(-half_w * 0.88, c0 * r_outer, s0 * r_outer)
		var p_tr_r0 := Vector3(half_w * 0.88, c0 * r_outer, s0 * r_outer)
		var p_sh_r0 := Vector3(half_w, c0 * r_shoulder, s0 * r_shoulder)
		var p_bulge_r0 := Vector3(bulge_w, c0 * ((r_rim + r_shoulder) * 0.5), s0 * ((r_rim + r_shoulder) * 0.5))
		var p_rim_r0 := Vector3(half_w * 0.92, c0 * r_rim, s0 * r_rim)

		var p_rim_l1 := Vector3(-half_w * 0.92, c1 * r_rim, s1 * r_rim)
		var p_bulge_l1 := Vector3(-bulge_w, c1 * ((r_rim + r_shoulder) * 0.5), s1 * ((r_rim + r_shoulder) * 0.5))
		var p_sh_l1 := Vector3(-half_w, c1 * r_shoulder, s1 * r_shoulder)
		var p_tr_l1 := Vector3(-half_w * 0.88, c1 * r_outer, s1 * r_outer)
		var p_tr_r1 := Vector3(half_w * 0.88, c1 * r_outer, s1 * r_outer)
		var p_sh_r1 := Vector3(half_w, c1 * r_shoulder, s1 * r_shoulder)
		var p_bulge_r1 := Vector3(bulge_w, c1 * ((r_rim + r_shoulder) * 0.5), s1 * ((r_rim + r_shoulder) * 0.5))
		var p_rim_r1 := Vector3(half_w * 0.92, c1 * r_rim, s1 * r_rim)

		_st_add_quad(st_tire, p_rim_l0, p_rim_l1, p_bulge_l1, p_bulge_l0)
		_st_add_quad(st_tire, p_bulge_l0, p_bulge_l1, p_sh_l1, p_sh_l0)
		_st_add_quad(st_tire, p_sh_l0, p_sh_l1, p_tr_l1, p_tr_l0)
		_st_add_quad(st_tire, p_tr_l0, p_tr_l1, p_tr_r1, p_tr_r0)
		_st_add_quad(st_tire, p_tr_r0, p_tr_r1, p_sh_r1, p_sh_r0)
		_st_add_quad(st_tire, p_sh_r0, p_sh_r1, p_bulge_r1, p_bulge_r0)
		_st_add_quad(st_tire, p_bulge_r0, p_bulge_r1, p_rim_r1, p_rim_r0)

	st_tire.generate_normals()
	_spawn_mesh(wheel_root, "AdvanNeovaTire", st_tire.commit(), _mat_tire_rubber)

	# 2. Polished Stepped Aluminum Deep-Dish Outer Lip
	var st_lip := SurfaceTool.new()
	st_lip.begin(Mesh.PRIMITIVE_TRIANGLES)
	var x_lip_out: float = out_sign * (half_w * 0.92)
	var x_lip_in: float = out_sign * (half_w * 0.35)
	var r_spoke_ring: float = 0.158

	for i in range(radial_segs):
		var a0: float = TAU * float(i) / float(radial_segs)
		var a1: float = TAU * float(i + 1) / float(radial_segs)
		var p_out0 := Vector3(x_lip_out, cos(a0) * r_rim, sin(a0) * r_rim)
		var p_out1 := Vector3(x_lip_out, cos(a1) * r_rim, sin(a1) * r_rim)
		var p_in0 := Vector3(x_lip_in, cos(a0) * r_spoke_ring, sin(a0) * r_spoke_ring)
		var p_in1 := Vector3(x_lip_in, cos(a1) * r_spoke_ring, sin(a1) * r_spoke_ring)

		if is_left:
			_st_add_quad(st_lip, p_out0, p_out1, p_in1, p_in0)
		else:
			_st_add_quad(st_lip, p_out1, p_out0, p_in0, p_in1)

	st_lip.generate_normals()
	_spawn_mesh(wheel_root, "PolishedRimLip", st_lip.commit(), _mat_chrome_lip)

	# 3. RS Watanabe 8-Spoke Concave Gunmetal Center Hub & Rounded Banana Spokes
	var hub_cyl := CylinderMesh.new()
	hub_cyl.top_radius = 0.056
	hub_cyl.bottom_radius = 0.062
	hub_cyl.height = 0.06
	_spawn_mesh(wheel_root, "WatanabeCenterHub", hub_cyl, _mat_watanabe_gunmetal, Vector3(out_sign * 0.032, 0.0, 0.0), Vector3(0.0, 0.0, 90.0))

	var spoke_mesh := BoxMesh.new()
	spoke_mesh.size = Vector3(0.022, 0.118, 0.032)
	for s in range(8):
		var deg: float = float(s) * 45.0
		var rad: float = deg_to_rad(deg)
		var r_mid: float = 0.104
		var spoke_pos := Vector3(out_sign * 0.045, cos(rad) * r_mid, sin(rad) * r_mid)
		var spoke_inst := MeshInstance3D.new()
		spoke_inst.name = "WatanabeSpoke_" + str(s)
		spoke_inst.mesh = spoke_mesh
		spoke_inst.material_override = _mat_watanabe_gunmetal
		spoke_inst.position = spoke_pos
		spoke_inst.rotation_degrees = Vector3(-deg, 0.0, out_sign * -8.0)
		wheel_root.add_child(spoke_inst)

	# 4. Vented Cast-Iron Brake Rotor Disc (Connected to set_brake_heat) & Red TRD Caliper
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = Color(0.55, 0.58, 0.62)
	disc_mat.metallic = 0.85
	disc_mat.roughness = 0.32
	_brake_disc_materials.append(disc_mat)

	var rotor_mesh := CylinderMesh.new()
	rotor_mesh.top_radius = 0.132
	rotor_mesh.bottom_radius = 0.132
	rotor_mesh.height = 0.022
	_spawn_mesh(wheel_root, "VentedBrakeRotor", rotor_mesh, disc_mat, Vector3(out_sign * 0.005, 0.0, 0.0), Vector3(0.0, 0.0, 90.0))

	var caliper_mesh := BoxMesh.new()
	caliper_mesh.size = Vector3(0.048, 0.095, 0.058)
	_spawn_mesh(wheel_root, "TRDBrakeCaliper", caliper_mesh, _mat_bride_red, Vector3(out_sign * 0.012, 0.035, -0.098))

	return wheel_root


# ==============================================================================
# 9. EXHAUST BACKFIRE FLAME CONE, DRIFT RIBBONS & ANIME SPEED LINES
# ==============================================================================

func _build_vfx_nodes(parent: Node3D) -> void:
	# Backfire Flame Cone at Left Exhaust Tip (-0.42, 0.195, 2.20)
	var mat_flame := StandardMaterial3D.new()
	mat_flame.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_flame.albedo_color = Color(0.35, 0.72, 1.0, 0.85)
	mat_flame.emission_enabled = true
	mat_flame.emission = Color(1.0, 0.48, 0.12)
	mat_flame.emission_energy_multiplier = 6.5

	var cone_mesh := CylinderMesh.new()
	cone_mesh.top_radius = 0.008
	cone_mesh.bottom_radius = 0.052
	cone_mesh.height = 0.38

	_backfire_cone = _spawn_mesh(parent, "BackfireFlameCone", cone_mesh, mat_flame, Vector3(-0.42, 0.195, 2.38), Vector3(-90.0, 0.0, 0.0))
	_backfire_cone.visible = false

	_backfire_light = OmniLight3D.new()
	_backfire_light.name = "BackfireOmniLight"
	_backfire_light.position = Vector3(-0.42, 0.195, 2.32)
	_backfire_light.light_color = Color(1.0, 0.52, 0.15)
	_backfire_light.light_energy = 0.0
	_backfire_light.omni_range = 4.5
	_backfire_light.visible = false
	parent.add_child(_backfire_light)

	# Stylized Anime Drift Smoke Ribbons behind Rear Tires
	var mat_ribbon := StandardMaterial3D.new()
	mat_ribbon.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_ribbon.albedo_color = Color(0.92, 0.95, 1.0, 0.42)
	mat_ribbon.emission_enabled = true
	mat_ribbon.emission = Color(0.65, 0.78, 1.0)
	mat_ribbon.emission_energy_multiplier = 0.65
	mat_ribbon.cull_mode = BaseMaterial3D.CULL_DISABLED

	var ribbon_mesh := BoxMesh.new()
	ribbon_mesh.size = Vector3(0.22, 0.015, 1.85)

	_drift_ribbon_l = _spawn_mesh(parent, "DriftRibbonL", ribbon_mesh, mat_ribbon, Vector3(-TRACK_REAR_X, 0.04, REAR_AXLE_Z + 1.05))
	_drift_ribbon_l.visible = false

	_drift_ribbon_r = _spawn_mesh(parent, "DriftRibbonR", ribbon_mesh, mat_ribbon, Vector3(TRACK_REAR_X, 0.04, REAR_AXLE_Z + 1.05))
	_drift_ribbon_r.visible = false

	# Manga Speed Lines Halo around vehicle during high-speed drift
	_speed_lines_node = Node3D.new()
	_speed_lines_node.name = "AnimeSpeedLines"
	_speed_lines_node.visible = false
	parent.add_child(_speed_lines_node)

	var line_mesh := BoxMesh.new()
	line_mesh.size = Vector3(0.012, 0.012, 2.8)
	var line_offsets: Array[Vector3] = [
		Vector3(-1.05, 0.55, 0.2),
		Vector3(1.05, 0.55, 0.2),
		Vector3(-0.92, 1.05, 0.4),
		Vector3(0.92, 1.05, 0.4)
	]
	for i in range(line_offsets.size()):
		_spawn_mesh(_speed_lines_node, "SpeedLine_" + str(i), line_mesh, _mat_headlight_angel, line_offsets[i])


# ==============================================================================
# GEOMETRY HELPER UTILITIES
# ==============================================================================

func _st_add_quad(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3) -> void:
	st.add_vertex(v0)
	st.add_vertex(v1)
	st.add_vertex(v2)

	st.add_vertex(v0)
	st.add_vertex(v2)
	st.add_vertex(v3)


func _spawn_mesh(
	parent: Node3D,
	node_name: String,
	mesh: Mesh,
	mat: Material,
	pos: Vector3 = Vector3.ZERO,
	rot_deg: Vector3 = Vector3.ZERO
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi