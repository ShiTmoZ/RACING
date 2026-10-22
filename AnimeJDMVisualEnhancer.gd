class_name AnimeJDMVisualEnhancer
extends Node3D

# ==============================================================================
# ANIME CEL-SHADING, NEON UNDERGLOW, LIVERIES, TAILLIGHT RIBBONS & MANGA VFX
# Target Engine: Godot 4.3+ (Headless & Desktop CI Compatible)
# Architecture: 100% Self-Contained Procedural Anime Visual Enhancer Module
# ==============================================================================

enum NeonPreset {
	CYBERPUNK_CYAN,
	MIDNIGHT_MAGENTA,
	ACID_GREEN,
	INITIAL_D_AMBER,
	RPM_PULSE_CYCLE
}

enum LiveryPreset {
	NONE,
	FUJIWARA_TOFU_AE86,
	PROJECT_D_CARBON_AE86,
	AKAGI_REDSUNS_FD3S
}

@export_group("Anime & JDM Visual Configuration")
@export var neon_enabled: bool = true
@export var neon_preset: NeonPreset = NeonPreset.CYBERPUNK_CYAN
@export var livery_preset: LiveryPreset = LiveryPreset.AKAGI_REDSUNS_FD3S
@export var enable_cel_shading: bool = true
@export var enable_taillight_ribbons: bool = true
@export var enable_manga_sfx_popups: bool = true
@export var enable_screen_speedlines: bool = true

# Color Constants
const COLOR_CYAN := Color("#00F3FF")
const COLOR_MAGENTA := Color("#D900FF")
const COLOR_GREEN := Color("#39FF14")
const COLOR_AMBER := Color("#FFB703")
const COLOR_TAILLIGHT_RED := Color(1.0, 0.06, 0.02, 0.92)

# Internal Bindings
var _vehicle_body: RigidBody3D
var _visual_chassis: Node3D
var _active_neon_color: Color = COLOR_CYAN
var _neon_root: Node3D
var _neon_lights: Array[OmniLight3D] = []
var _neon_tube_mat: StandardMaterial3D
var _livery_root: Node3D

# Cel-Shading & Outline Shaders
var _cel_outline_mat: ShaderMaterial
var _cel_shader: Shader

# Taillight Drift Ribbon Trail Buffers
const MAX_TRAIL_POINTS: int = 36
var _trail_mesh_instance: MeshInstance3D
var _trail_immediate_mesh: ImmediateMesh
var _trail_material: StandardMaterial3D
var _left_tail_history: Array[Vector3] = []
var _right_tail_history: Array[Vector3] = []
var _trail_sample_timer: float = 0.0

# 3D Floating Manga Onomatopoeia (Kanji SFX) Pool
var _manga_popup_pool: Array[Label3D] = []
var _manga_spawn_timer: float = 0.0
var _sfx_phase: float = 0.0

# 2D Screen-Space Anime Action Speedlines Overlay
var _speedline_canvas: CanvasLayer
var _speedline_rect: ColorRect
var _speedline_mat: ShaderMaterial


func _ready() -> void:
	_active_neon_color = _resolve_preset_color(neon_preset)
	_build_neon_underglow_system()
	_build_taillight_ribbon_system()
	_build_manga_kanji_popup_pool()
	_build_screen_speedlines_overlay()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_L:
			toggle_neon_underglow(not neon_enabled)


# ==============================================================================
# PUBLIC API & VEHICLE ATTACHMENT BINDINGS
# ==============================================================================

func attach_to_car(vehicle_body: RigidBody3D, visual_chassis_root: Node3D) -> void:
	_vehicle_body = vehicle_body
	_visual_chassis = visual_chassis_root

	if is_instance_valid(_vehicle_body):
		if get_parent() != null:
			get_parent().remove_child(self)
		_vehicle_body.add_child(self)
		transform = Transform3D.IDENTITY

	# Auto-detect AE86 vs FD3S from node names if livery is set
	if is_instance_valid(_visual_chassis):
		var c_name: String = _visual_chassis.name.to_upper()
		if c_name.contains("AE86") or c_name.contains("TRUENO"):
			if livery_preset == LiveryPreset.AKAGI_REDSUNS_FD3S:
				livery_preset = LiveryPreset.FUJIWARA_TOFU_AE86

		if enable_cel_shading:
			_apply_cel_shader_and_ink_outlines(_visual_chassis)

		_build_initial_d_livery_decals(_visual_chassis)


func set_neon_color(color: Color) -> void:
	_active_neon_color = color
	_update_neon_materials_and_lights(1.0)


func toggle_neon_underglow(enabled: bool) -> void:
	neon_enabled = enabled
	if is_instance_valid(_neon_root):
		_neon_root.visible = neon_enabled


func update_enhancer(
	delta: float,
	speed_kmh: float,
	drift_angle_deg: float,
	is_drifting: bool,
	rpm: float
) -> void:
	_sfx_phase += delta
	var abs_drift: float = absf(drift_angle_deg)
	var rpm_norm: float = clampf((rpm - 900.0) / 7300.0, 0.0, 1.0)

	# 1. Update Neon Underglow Breathing / RPM Pulse
	if neon_enabled:
		var pulse_intensity: float = 1.0 + 0.28 * sin(_sfx_phase * (6.0 + rpm_norm * 14.0))
		if is_drifting and abs_drift > 15.0:
			pulse_intensity += 0.45
		if neon_preset == NeonPreset.RPM_PULSE_CYCLE:
			var hue: float = fmod(_sfx_phase * 0.25 + rpm_norm * 0.4, 1.0)
			_active_neon_color = Color.from_hsv(hue, 0.92, 1.0)
		_update_neon_materials_and_lights(pulse_intensity)

	# 2. Update Taillight Laser Ribbon Trails during High-Speed Drifts
	var emit_ribbons: bool = enable_taillight_ribbons and (
		(is_drifting and abs_drift > 15.0 and speed_kmh > 45.0) or speed_kmh > 135.0
	)
	_update_taillight_ribbons(delta, emit_ribbons)

	# 3. Update 3D Floating Manga Kanji Onomatopoeia Popups
	if enable_manga_sfx_popups:
		_update_manga_sfx_popups(delta, speed_kmh, abs_drift, is_drifting, rpm)

	# 4. Update 2D Screen-Space Manga Action Speedlines
	if enable_screen_speedlines and is_instance_valid(_speedline_mat):
		var speed_factor: float = clampf((speed_kmh - 95.0) / 95.0, 0.0, 1.0)
		var drift_factor: float = clampf((abs_drift - 15.0) / 30.0, 0.0, 1.0) if is_drifting else 0.0
		var line_alpha: float = maxf(speed_factor * 0.75, drift_factor * 0.95)
		_speedline_mat.set_shader_parameter("intensity", line_alpha)
		_speedline_mat.set_shader_parameter("time_seed", _sfx_phase)


# ==============================================================================
# 1. DYNAMIC NEON UNDERGLOW LED TUBES & GROUND ILLUMINATION
# ==============================================================================

func _build_neon_underglow_system() -> void:
	_neon_root = Node3D.new()
	_neon_root.name = "Neon_Underglow_Rig"
	_neon_root.visible = neon_enabled
	add_child(_neon_root)

	_neon_tube_mat = StandardMaterial3D.new()
	_neon_tube_mat.albedo_color = _active_neon_color
	_neon_tube_mat.emission_enabled = true
	_neon_tube_mat.emission = _active_neon_color
	_neon_tube_mat.emission_energy_multiplier = 4.8

	# 4 Underbody Sill Neon Tubes: [Pos, Length, Rotation]
	var tube_configs: Array = [
		[Vector3(-0.78, 0.14, 0.0), 1.95, Vector3(deg_to_rad(90.0), 0.0, 0.0)], # Left Skirt Tube
		[Vector3( 0.78, 0.14, 0.0), 1.95, Vector3(deg_to_rad(90.0), 0.0, 0.0)], # Right Skirt Tube
		[Vector3( 0.0,  0.15, -1.85), 1.25, Vector3(0.0, 0.0, deg_to_rad(90.0))], # Front Bumper Tube
		[Vector3( 0.0,  0.17,  1.85), 1.25, Vector3(0.0, 0.0, deg_to_rad(90.0))]  # Rear Diffuser Tube
	]

	_neon_lights.clear()
	for i in range(tube_configs.size()):
		var cfg: Array = tube_configs[i]
		var tube_inst := MeshInstance3D.new()
		tube_inst.name = "Neon_LED_Tube_" + str(i)
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.018
		cyl.bottom_radius = 0.018
		cyl.height = cfg[1]
		cyl.radial_segments = 12
		tube_inst.mesh = cyl
		tube_inst.position = cfg[0]
		tube_inst.rotation = cfg[2]
		tube_inst.material_override = _neon_tube_mat
		_neon_root.add_child(tube_inst)

		# Ground-Illuminating OmniLight3D (Shadowless for High FPS)
		var omni := OmniLight3D.new()
		omni.name = "Neon_Ground_Light_" + str(i)
		omni.position = cfg[0] + Vector3(0.0, -0.04, 0.0)
		omni.light_color = _active_neon_color
		omni.light_energy = 2.6
		omni.omni_range = 2.65
		omni.omni_attenuation = 1.35
		omni.shadow_enabled = false
		_neon_root.add_child(omni)
		_neon_lights.append(omni)


func _update_neon_materials_and_lights(pulse_mult: float) -> void:
	if is_instance_valid(_neon_tube_mat):
		_neon_tube_mat.albedo_color = _active_neon_color
		_neon_tube_mat.emission = _active_neon_color
		_neon_tube_mat.emission_energy_multiplier = 4.5 * pulse_mult

	for omni in _neon_lights:
		if is_instance_valid(omni):
			omni.light_color = _active_neon_color
			omni.light_energy = 2.4 * pulse_mult


func _resolve_preset_color(preset: NeonPreset) -> Color:
	match preset:
		NeonPreset.CYBERPUNK_CYAN:
			return COLOR_CYAN
		NeonPreset.MIDNIGHT_MAGENTA:
			return COLOR_MAGENTA
		NeonPreset.ACID_GREEN:
			return COLOR_GREEN
		NeonPreset.INITIAL_D_AMBER:
			return COLOR_AMBER
		_:
			return COLOR_CYAN


# ==============================================================================
# 2. ANIME CEL-SHADING & INVERTED-HULL BLACK INK OUTLINES
# ==============================================================================

func _apply_cel_shader_and_ink_outlines(root_node: Node3D) -> void:
	if _cel_outline_mat == null:
		var outline_shader := Shader.new()
		outline_shader.code = """
shader_type spatial;
render_mode cull_front, unshaded;

uniform float outline_thickness : hint_range(0.0, 0.05) = 0.014;
uniform vec4 outline_color : source_color = vec4(0.03, 0.03, 0.05, 1.0);

void vertex() {
	VERTEX += NORMAL * outline_thickness;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
"""
		_cel_outline_mat = ShaderMaterial.new()
		_cel_outline_mat.shader = outline_shader

	if _cel_shader == null:
		_cel_shader = Shader.new()
		_cel_shader.code = """
shader_type spatial;
render_mode diffuse_toon, specular_toon;

uniform vec4 base_albedo : source_color = vec4(1.0, 0.78, 0.05, 1.0);
uniform float specular_strength : hint_range(0.0, 1.0) = 0.65;
uniform float rim_power : hint_range(0.5, 8.0) = 3.2;

void fragment() {
	ALBEDO = base_albedo.rgb;
	ROUGHNESS = 0.18;
	SPECULAR = specular_strength;
}

void light() {
	float ndotl = dot(NORMAL, LIGHT);
	// 3-Band Stepped Anime Cel-Shading
	float stepped_diffuse = 0.22;
	if (ndotl > 0.55) {
		stepped_diffuse = 1.0;
	} else if (ndotl > 0.05) {
		stepped_diffuse = 0.62;
	}
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * stepped_diffuse;

	// Crisp Anime Specular Highlight Band
	vec3 half_vec = normalize(VIEW + LIGHT);
	float ndoth = max(dot(NORMAL, half_vec), 0.0);
	float spec_step = step(0.92, pow(ndoth, 24.0)) * specular_strength;
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * spec_step;
}
"""

	_traverse_and_inject_toon_shading(root_node)


func _traverse_and_inject_toon_shading(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mat: Material = mi.material_override
		if mat == null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			mat = mi.mesh.surface_get_material(0)

		if mat is StandardMaterial3D:
			var std_mat := mat as StandardMaterial3D
			# Only convert opaque non-emissive body/wheel panels; preserve glass & glowing lamps
			if std_mat.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED and not std_mat.emission_enabled:
				var n_lower: String = mi.name.to_lower()
				if n_lower.contains("shell") or n_lower.contains("body") or n_lower.contains("lid") or n_lower.contains("caliper"):
					var toon_mat := ShaderMaterial.new()
					toon_mat.shader = _cel_shader
					toon_mat.set_shader_parameter("base_albedo", std_mat.albedo_color)
					toon_mat.next_pass = _cel_outline_mat
					mi.material_override = toon_mat
				else:
					# Add crisp black ink outline next_pass to carbon/trim parts
					var cloned_mat := std_mat.duplicate() as StandardMaterial3D
					cloned_mat.next_pass = _cel_outline_mat
					mi.material_override = cloned_mat

	for child in node.get_children():
		_traverse_and_inject_toon_shading(child)


# ==============================================================================
# 3. INITIAL D ANIME LIVERIES & KANJI DOOR DECALS
# ==============================================================================

func _build_initial_d_livery_decals(chassis_root: Node3D) -> void:
	if is_instance_valid(_livery_root):
		_livery_root.queue_free()

	if livery_preset == LiveryPreset.NONE:
		return

	_livery_root = Node3D.new()
	_livery_root.name = "Initial_D_Livery_Decals"
	chassis_root.add_child(_livery_root)

	if livery_preset == LiveryPreset.FUJIWARA_TOFU_AE86 or livery_preset == LiveryPreset.PROJECT_D_CARBON_AE86:
		_build_ae86_panda_and_tofu_decal(_livery_root, livery_preset == LiveryPreset.PROJECT_D_CARBON_AE86)
	elif livery_preset == LiveryPreset.AKAGI_REDSUNS_FD3S:
		_build_fd3s_redsuns_livery(_livery_root)


func _build_ae86_panda_and_tofu_decal(parent: Node3D, carbon_hood: bool) -> void:
	var panda_black_mat := StandardMaterial3D.new()
	panda_black_mat.albedo_color = Color(0.05, 0.05, 0.06)
	panda_black_mat.roughness = 0.35

	# Panda Two-Tone Lower Rocker Panels (Left & Right)
	for side in [-1.0, 1.0]:
		var stripe := MeshInstance3D.new()
		stripe.name = "Panda_Rocker_Stripe"
		var bm := BoxMesh.new()
		bm.size = Vector3(0.02, 0.24, 3.85)
		stripe.mesh = bm
		stripe.position = Vector3(side * 0.845, 0.32, 0.0)
		stripe.material_override = panda_black_mat
		parent.add_child(stripe)

	# Authentic Right-Hand-Drive Door Decal: 藤原とうふ店(自家用)
	for side in [-1.0, 1.0]:
		var kanji_label := Label3D.new()
		kanji_label.name = "Fujiwara_Tofu_Shop_Kanji"
		kanji_label.text = "藤原とうふ店 (自家用)"
		kanji_label.font_size = 42
		kanji_label.pixel_size = 0.0028
		kanji_label.modulate = Color(0.04, 0.04, 0.04)
		kanji_label.outline_size = 2
		kanji_label.outline_modulate = Color(0.95, 0.95, 0.95)
		kanji_label.position = Vector3(side * 0.865, 0.56, -0.05)
		kanji_label.rotation = Vector3(0.0, deg_to_rad(90.0 * side), 0.0)
		parent.add_child(kanji_label)

	# Project D Carbon Fiber Hood Overlay
	if carbon_hood:
		var cf_mat := StandardMaterial3D.new()
		cf_mat.albedo_color = Color(0.09, 0.10, 0.11)
		cf_mat.metallic = 0.40
		cf_mat.roughness = 0.18
		var hood_panel := MeshInstance3D.new()
		hood_panel.name = "Project_D_Carbon_Hood"
		var h_box := BoxMesh.new()
		h_box.size = Vector3(1.36, 0.018, 1.15)
		hood_panel.mesh = h_box
		hood_panel.position = Vector3(0.0, 0.745, -1.25)
		hood_panel.rotation = Vector3(deg_to_rad(6.5), 0.0, 0.0)
		hood_panel.material_override = cf_mat
		parent.add_child(hood_panel)


func _build_fd3s_redsuns_livery(parent: Node3D) -> void:
	for side in [-1.0, 1.0]:
		var redsuns_label := Label3D.new()
		redsuns_label.name = "Akagi_RedSuns_Decal"
		redsuns_label.text = "AKAGI RedSuns\nPROJECT D"
		redsuns_label.font_size = 38
		redsuns_label.pixel_size = 0.0028
		redsuns_label.modulate = Color(0.92, 0.08, 0.05)
		redsuns_label.outline_size = 6
		redsuns_label.outline_modulate = Color(1.0, 1.0, 1.0)
		redsuns_label.position = Vector3(side * 0.865, 0.55, 0.35)
		redsuns_label.rotation = Vector3(0.0, deg_to_rad(90.0 * side), deg_to_rad(-6.0 * side))
		parent.add_child(redsuns_label)


# ==============================================================================
# 4. DRIFT TAILLIGHT NEON LASER RIBBONS (IMMEDIATEMESH)
# ==============================================================================

func _build_taillight_ribbon_system() -> void:
	_trail_immediate_mesh = ImmediateMesh.new()
	_trail_material = StandardMaterial3D.new()
	_trail_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_trail_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_trail_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_trail_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_trail_material.vertex_color_use_as_albedo = true
	_trail_material.albedo_color = COLOR_TAILLIGHT_RED

	_trail_mesh_instance = MeshInstance3D.new()
	_trail_mesh_instance.name = "Initial_D_Taillight_Ribbons"
	_trail_mesh_instance.mesh = _trail_immediate_mesh
	_trail_mesh_instance.material_override = _trail_material
	_trail_mesh_instance.top_level = true
	add_child(_trail_mesh_instance)


func _update_taillight_ribbons(delta: float, should_emit: bool) -> void:
	if not is_inside_tree() or not is_instance_valid(_trail_immediate_mesh):
		return

	_trail_sample_timer += delta
	if _trail_sample_timer >= 0.022:
		_trail_sample_timer = 0.0
		if should_emit:
			var left_world: Vector3 = to_global(Vector3(-0.56, 0.72, 2.15))
			var right_world: Vector3 = to_global(Vector3(0.56, 0.72, 2.15))
			_left_tail_history.push_front(left_world)
			_right_tail_history.push_front(right_world)

			if _left_tail_history.size() > MAX_TRAIL_POINTS:
				_left_tail_history.pop_back()
			if _right_tail_history.size() > MAX_TRAIL_POINTS:
				_right_tail_history.pop_back()
		else:
			if _left_tail_history.size() > 0:
				_left_tail_history.pop_back()
			if _right_tail_history.size() > 0:
				_right_tail_history.pop_back()

	if _left_tail_history.size() < 2:
		if is_instance_valid(_trail_mesh_instance):
			_trail_mesh_instance.visible = false
		return
	if is_instance_valid(_trail_mesh_instance):
		_trail_mesh_instance.visible = true
	_trail_immediate_mesh.clear_surfaces()

	_trail_immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var count: int = _left_tail_history.size()
	for i in range(count):
		var alpha: float = (1.0 - float(i) / float(count)) * 0.88
		var col := Color(1.0, 0.08, 0.03, alpha)
		var pt: Vector3 = _left_tail_history[i]
		_trail_immediate_mesh.surface_set_color(col)
		_trail_immediate_mesh.surface_add_vertex(pt + Vector3(0.0, 0.055, 0.0))
		_trail_immediate_mesh.surface_set_color(col)
		_trail_immediate_mesh.surface_add_vertex(pt + Vector3(0.0, -0.055, 0.0))
	_trail_immediate_mesh.surface_end()

	_trail_immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in range(count):
		var alpha: float = (1.0 - float(i) / float(count)) * 0.88
		var col := Color(1.0, 0.08, 0.03, alpha)
		var pt: Vector3 = _right_tail_history[i]
		_trail_immediate_mesh.surface_set_color(col)
		_trail_immediate_mesh.surface_add_vertex(pt + Vector3(0.0, 0.055, 0.0))
		_trail_immediate_mesh.surface_set_color(col)
		_trail_immediate_mesh.surface_add_vertex(pt + Vector3(0.0, -0.055, 0.0))
	_trail_immediate_mesh.surface_end()


# ==============================================================================
# 5. FLOATING 3D MANGA ONOMATOPOEIA KANJI POPUPS & 2D ACTION SPEEDLINES
# ==============================================================================

func _build_manga_kanji_popup_pool() -> void:
	_manga_popup_pool.clear()
	var pool_root := Node3D.new()
	pool_root.name = "Manga_Kanji_SFX_Pool"
	add_child(pool_root)

	for i in range(4):
		var lbl := Label3D.new()
		lbl.name = "Manga_SFX_Popup_" + str(i)
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.font_size = 64
		lbl.pixel_size = 0.0045
		lbl.modulate = Color(1.0, 0.92, 0.15, 0.0)
		lbl.outline_size = 10
		lbl.outline_modulate = Color(0.05, 0.02, 0.02, 0.0)
		lbl.visible = false
		pool_root.add_child(lbl)
		_manga_popup_pool.append(lbl)


func _update_manga_sfx_popups(
	delta: float,
	speed_kmh: float,
	abs_drift_deg: float,
	is_drifting: bool,
	rpm: float
) -> void:
	# Animate active floating popups
	for lbl in _manga_popup_pool:
		if lbl.visible:
			lbl.position.y += delta * 1.15
			var current_a: float = lbl.modulate.a - delta * 1.45
			if current_a <= 0.0:
				lbl.visible = false
			else:
				lbl.modulate.a = current_a
				lbl.outline_modulate.a = current_a

	_manga_spawn_timer -= delta
	if _manga_spawn_timer > 0.0:
		return

	var should_spawn: bool = (is_drifting and abs_drift_deg > 15.0 and speed_kmh > 45.0) or (rpm > 6800.0 and speed_kmh > 90.0)
	if not should_spawn:
		return

	_manga_spawn_timer = 0.45
	for lbl in _manga_popup_pool:
		if not lbl.visible:
			lbl.visible = true
			if is_drifting and abs_drift_deg > 15.0:
				lbl.text = "ギャギャギャ!!" # GYAGYAGYA (Tire Screaming)
				lbl.modulate = Color(1.0, 0.25, 0.10, 1.0)
			else:
				lbl.text = "ドドドドド!!" # DODODODO (Rotary / Twin-Cam Roar)
				lbl.modulate = Color(1.0, 0.88, 0.10, 1.0)
			lbl.outline_modulate = Color(0.04, 0.04, 0.04, 1.0)
			lbl.position = Vector3(
				randf_range(-1.15, 1.15),
				randf_range(0.85, 1.35),
				randf_range(0.8, 2.1)
			)
			break


func _build_screen_speedlines_overlay() -> void:
	_speedline_canvas = CanvasLayer.new()
	_speedline_canvas.name = "Manga_Speedlines_Overlay"
	_speedline_canvas.layer = 5
	add_child(_speedline_canvas)

	_speedline_rect = ColorRect.new()
	_speedline_rect.name = "Speedline_Shader_Rect"
	_speedline_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_speedline_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sp_shader := Shader.new()
	sp_shader.code = """
shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float time_seed = 0.0;

float hash(float n) {
	return fract(sin(n) * 43758.5453123);
}

void fragment() {
	vec2 centered = UV - vec2(0.5);
	float dist = length(centered);
	float angle = atan(centered.y, centered.x);

	float ray_index = floor((angle + 3.14159265) * 42.0);
	float noise = hash(ray_index + floor(time_seed * 18.0));

	float outer_mask = smoothstep(0.52 - intensity * 0.14, 0.72, dist);
	float spike = step(0.82 - intensity * 0.12, noise) * outer_mask;

	COLOR = vec4(1.0, 1.0, 1.0, spike * intensity * 0.65);
}
"""
	_speedline_mat = ShaderMaterial.new()
	_speedline_mat.shader = sp_shader
	_speedline_rect.material = _speedline_mat
	_speedline_canvas.add_child(_speedline_rect)