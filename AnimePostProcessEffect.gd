class_name AnimePostProcessEffect
extends CanvasLayer

## ==============================================================================
## SHiTMoZ/RACING - FULL-SCREEN ANIME / INITIAL D MANGA POST-PROCESSING SYSTEM
## Godot 4.3 Forward+ Vulkan (Screen-Space Depth/Normal Sobel + Stepped Cel-Grade)
## ==============================================================================
## Note: In Godot 4.3 Forward+, screen-space depth (`hint_depth_texture`) and 
## normal-roughness (`hint_normal_roughness_texture`) are strictly bound to 
## `spatial` shaders. To achieve full-screen post-processing inside a self-contained
## `CanvasLayer` while retaining 100% access to the 3D Vulkan depth/normal buffers,
## this controller manages both a full-screen 3D Post-Process Quad parented to 
## the active Camera3D (for 3D G-Buffer Sobel ink lines & cel-shading) AND a 
## full-screen 2D CanvasItem overlay (for procedural Manga Speedlines, Vignette,
## and UI Toast notifications).

@export_group("Anime Master Toggle")
@export var effect_enabled: bool = true:
	set(value):
		effect_enabled = value
		_update_shader_uniforms()

@export_group("Manga Ink Outlines (Sobel Depth & Normal)")
@export var outline_enabled: bool = true:
	set(value):
		outline_enabled = value
		_update_shader_uniforms()

@export_range(0.5, 4.0, 0.05) var outline_thickness: float = 1.6:
	set(value):
		outline_thickness = value
		_update_shader_uniforms()

@export_range(0.01, 2.0, 0.01) var depth_threshold: float = 0.25:
	set(value):
		depth_threshold = value
		_update_shader_uniforms()

@export_range(0.05, 1.5, 0.01) var normal_threshold: float = 0.35:
	set(value):
		normal_threshold = value
		_update_shader_uniforms()

@export var outline_color: Color = Color(0.04, 0.04, 0.08, 1.0):
	set(value):
		outline_color = value
		_update_shader_uniforms()

@export_group("Anime Cel-Shading & Color Grading")
@export var posterize_enabled: bool = true:
	set(value):
		posterize_enabled = value
		_update_shader_uniforms()

@export_range(2.0, 8.0, 1.0) var cel_bands: float = 3.0:
	set(value):
		cel_bands = value
		_update_shader_uniforms()

@export_range(0.8, 1.8, 0.05) var saturation_boost: float = 1.15:
	set(value):
		saturation_boost = value
		_update_shader_uniforms()

@export var shadow_tint: Color = Color(0.16, 0.14, 0.32, 1.0):
	set(value):
		shadow_tint = value
		_update_shader_uniforms()

@export var highlight_tint: Color = Color(1.0, 0.94, 0.86, 1.0):
	set(value):
		highlight_tint = value
		_update_shader_uniforms()

@export_group("Initial D Dynamic Speedlines")
@export_range(0.0, 1.0, 0.01) var speedlines_intensity: float = 0.0:
	set(value):
		speedlines_intensity = clampf(value, 0.0, 1.0)
		_update_shader_uniforms()

@export var auto_detect_vehicle_speed: bool = true
@export var speed_activation_kmh: float = 80.0
@export var max_speed_kmh: float = 190.0

# Internal Runtime Nodes
var _canvas_rect: ColorRect
var _canvas_material: ShaderMaterial
var _spatial_quad: MeshInstance3D
var _spatial_material: ShaderMaterial
var _tracked_camera: Camera3D
var _tracked_vehicle: Node3D
var _last_vehicle_pos: Vector3 = Vector3.ZERO
var _vehicle_pos_initialized: bool = false
var _smoothed_speed_kmh: float = 0.0
var _smoothed_slip_factor: float = 0.0

# Toast Notification UI
var _toast_panel: PanelContainer
var _toast_label: Label
var _toast_timer: float = 0.0
const TOAST_DURATION: float = 2.4

# ==============================================================================
# 1. SPATIAL POST-PROCESS SHADER (G-BUFFER DEPTH/NORMAL SOBEL + CEL SHADING)
# ==============================================================================
const SPATIAL_ANIME_SHADER_CODE: String = """
shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled, cull_disabled, skip_vertex_transform;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D normal_roughness_texture : hint_normal_roughness_texture, repeat_disable, filter_nearest;

uniform bool effect_enabled = true;
uniform bool outline_enabled = true;
uniform float outline_thickness = 1.6;
uniform float depth_threshold = 0.25;
uniform float normal_threshold = 0.35;
uniform vec4 outline_color : source_color = vec4(0.04, 0.04, 0.08, 1.0);

uniform bool posterize_enabled = true;
uniform float cel_bands = 3.0;
uniform float saturation_boost = 1.15;
uniform vec4 shadow_tint : source_color = vec4(0.16, 0.14, 0.32, 1.0);
uniform vec4 highlight_tint : source_color = vec4(1.0, 0.94, 0.86, 1.0);

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Reconstruct linear eye-space depth from Godot 4.3 Vulkan Reverse-Z depth buffer
float get_linear_depth(vec2 uv, mat4 inv_proj) {
	float raw_depth = texture(depth_texture, uv).r;
	vec3 ndc = vec3(uv * 2.0 - 1.0, raw_depth);
	vec4 view_pos = inv_proj * vec4(ndc, 1.0);
	view_pos.xyz /= max(view_pos.w, 0.00001);
	return -view_pos.z;
}

// Unpack view-space normal from Godot 4.3 Forward+ normal_roughness buffer
vec3 get_view_normal(vec2 uv) {
	vec3 packed = texture(normal_roughness_texture, uv).xyz;
	return normalize(packed * 2.0 - 1.0);
}

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec4 raw_screen = texture(screen_texture, uv);
	
	if (!effect_enabled) {
		ALBEDO = raw_screen.rgb;
	} else {
		vec2 texel_size = 1.0 / VIEWPORT_SIZE;
		float center_raw_depth = texture(depth_texture, uv).r;
		// In Godot 4.3 Reverse-Z, skybox is at raw_depth == 0.0
		bool is_sky = (center_raw_depth <= 0.00001);
		float center_depth = get_linear_depth(uv, INV_PROJECTION_MATRIX);
		vec3 center_normal = get_view_normal(uv);

		// ------------------------------------------------------------------
		// 1. ANIME CEL-SHADING & STEPPED COLOR POSTERIZATION
		// ------------------------------------------------------------------
		vec3 final_color = raw_screen.rgb;

		if (posterize_enabled) {
			if (!is_sky) {
				vec3 hsv = rgb2hsv(final_color);
				float lum = dot(final_color, vec3(0.299, 0.587, 0.114));

				// Preserve crisp black/white vehicle liveries (Fujiwara Tofu Panda AE86)
				bool is_high_contrast_livery = (hsv.y < 0.14 && (hsv.z > 0.82 || hsv.z < 0.16));

				// 3-Band Stepped Anime Luminance Quantization with subtle AA ramp
				float bands = max(cel_bands, 2.0);
				float scaled_v = hsv.z * bands;
				float band_idx = floor(scaled_v);
				float band_fract = fract(scaled_v);
				float smooth_edge = smoothstep(0.42, 0.58, band_fract);
				float stepped_v = (band_idx + smooth_edge) / bands;
				stepped_v = clamp(stepped_v + 0.08, 0.08, 1.0);

				if (is_high_contrast_livery) {
					// Keep panda white and carbon black decals razor-sharp
					hsv.z = mix(hsv.z, stepped_v, 0.55);
				} else {
					hsv.z = mix(hsv.z, stepped_v, 0.85);
					hsv.y = clamp(hsv.y * saturation_boost, 0.0, 1.0);
				}

				vec3 cel_rgb = hsv2rgb(hsv);

				// Band 3: Cool Indigo / Akina Dusk Shadow Tint
				float shadow_mask = 1.0 - smoothstep(0.18, 0.45, lum);
				cel_rgb = mix(cel_rgb, mix(cel_rgb, shadow_tint.rgb, 0.42), shadow_mask * 0.75);

				// Band 1: Crisp Anime Highlight & Warm Golden Rim Grading
				float highlight_mask = smoothstep(0.68, 0.92, lum);
				cel_rgb = mix(cel_rgb, cel_rgb * highlight_tint.rgb * 1.12, highlight_mask * 0.65);

				// View-space Fresnel Rim Light on vehicle body & mountain silhouettes
				vec3 view_dir = vec3(0.0, 0.0, 1.0);
				float fresnel = pow(1.0 - clamp( abs(dot(center_normal, view_dir)), 0.0, 1.0 ), 3.2);
				float near_fade = clamp(1.0 - (center_depth / 65.0), 0.0, 1.0);
				cel_rgb += highlight_tint.rgb * smoothstep(0.55, 0.72, fresnel) * 0.16 * near_fade;

				final_color = cel_rgb;
			} else {
				// Subtle Anime Sunset Sky Enhancement
				vec3 sky_hsv = rgb2hsv(final_color);
				sky_hsv.y = clamp(sky_hsv.y * (saturation_boost * 1.05), 0.0, 1.0);
				final_color = hsv2rgb(sky_hsv);
			}
		}

		// ------------------------------------------------------------------
		// 2. DEPTH-AWARE SOBEL DEPTH & NORMAL EDGE DETECTION (MANGA INK)
		// ------------------------------------------------------------------
		if (outline_enabled && !is_sky) {
			// Taper line thickness with distance: bold on foreground car (1.5-2.5px),
			// tapering cleanly on distant mountains to avoid black wireframe clutter
			float depth_taper = clamp(18.0 / max(center_depth, 4.5), 0.35, 1.45);
			float eff_thickness = outline_thickness * depth_taper;
			vec2 offset = texel_size * eff_thickness;

			// 3x3 Sobel Kernel UV Coordinates
			vec2 uv_tl = uv + vec2(-offset.x,  offset.y);
			vec2 uv_tc = uv + vec2( 0.0,       offset.y);
			vec2 uv_tr = uv + vec2( offset.x,  offset.y);
			vec2 uv_ml = uv + vec2(-offset.x,  0.0);
			vec2 uv_mr = uv + vec2( offset.x,  0.0);
			vec2 uv_bl = uv + vec2(-offset.x, -offset.y);
			vec2 uv_bc = uv + vec2( 0.0,      -offset.y);
			vec2 uv_br = uv + vec2( offset.x, -offset.y);

			// Linear Depth Samples
			float d_tl = get_linear_depth(uv_tl, INV_PROJECTION_MATRIX);
			float d_tc = get_linear_depth(uv_tc, INV_PROJECTION_MATRIX);
			float d_tr = get_linear_depth(uv_tr, INV_PROJECTION_MATRIX);
			float d_ml = get_linear_depth(uv_ml, INV_PROJECTION_MATRIX);
			float d_mr = get_linear_depth(uv_mr, INV_PROJECTION_MATRIX);
			float d_bl = get_linear_depth(uv_bl, INV_PROJECTION_MATRIX);
			float d_bc = get_linear_depth(uv_bc, INV_PROJECTION_MATRIX);
			float d_br = get_linear_depth(uv_br, INV_PROJECTION_MATRIX);

			// Sobel Depth Gradient
			float sobel_depth_x = (d_tr + 2.0 * d_mr + d_br) - (d_tl + 2.0 * d_ml + d_bl);
			float sobel_depth_y = (d_tl + 2.0 * d_tc + d_tr) - (d_bl + 2.0 * d_bc + d_br);
			float depth_grad = sqrt(sobel_depth_x * sobel_depth_x + sobel_depth_y * sobel_depth_y);

			// Grazing-angle compensation prevents false depth artifacts on flat roads/hoods
			float view_angle_comp = max(abs(center_normal.z), 0.15);
			float adaptive_depth_thresh = depth_threshold * center_depth * 0.18 / view_angle_comp;
			float depth_edge = smoothstep(adaptive_depth_thresh * 0.75, adaptive_depth_thresh * 1.15, depth_grad);

			// Normal Vector Samples (Captures Car Panel Seams, Hood Lines, Pillars, Curbs)
			vec3 n_tl = get_view_normal(uv_tl);
			vec3 n_tc = get_view_normal(uv_tc);
			vec3 n_tr = get_view_normal(uv_tr);
			vec3 n_ml = get_view_normal(uv_ml);
			vec3 n_mr = get_view_normal(uv_mr);
			vec3 n_bl = get_view_normal(uv_bl);
			vec3 n_bc = get_view_normal(uv_bc);
			vec3 n_br = get_view_normal(uv_br);

			vec3 sobel_norm_x = (n_tr + 2.0 * n_mr + n_br) - (n_tl + 2.0 * n_ml + n_bl);
			vec3 sobel_norm_y = (n_tl + 2.0 * n_tc + n_tr) - (n_bl + 2.0 * n_bc + n_br);
			float norm_grad = sqrt(dot(sobel_norm_x, sobel_norm_x) + dot(sobel_norm_y, sobel_norm_y));

			float normal_distance_fade = clamp(1.0 - (center_depth / 140.0), 0.15, 1.0);
			float norm_thresh_scaled = normal_threshold * 2.4;
			float normal_edge = smoothstep(norm_thresh_scaled * 0.8, norm_thresh_scaled * 1.2, norm_grad) * normal_distance_fade;

			// Luma Differential Edge (Captures Interior Panel Lines & Window Frames on Box Meshes)
			float l_ml = dot(texture(screen_texture, uv_ml).rgb, vec3(0.299, 0.587, 0.114));
			float l_mr = dot(texture(screen_texture, uv_mr).rgb, vec3(0.299, 0.587, 0.114));
			float l_tc = dot(texture(screen_texture, uv_tc).rgb, vec3(0.299, 0.587, 0.114));
			float l_bc = dot(texture(screen_texture, uv_bc).rgb, vec3(0.299, 0.587, 0.114));
			float luma_grad = length(vec2(l_mr - l_ml, l_tc - l_bc));
			float luma_edge = smoothstep(0.22, 0.38, luma_grad) * clamp(1.0 - (center_depth / 45.0), 0.0, 0.65);

			// Combine Silhouette Depth, Crease Normals, and Foreground Luma Seams
			float distance_alpha = clamp(1.0 - (center_depth / 260.0), 0.18, 1.0);
			float ink_strength = max(depth_edge, max(normal_edge, luma_edge)) * distance_alpha * outline_color.a;

			final_color = mix(final_color, outline_color.rgb, clamp(ink_strength, 0.0, 1.0));
		}

		ALBEDO = final_color;
	}
}
"""

# ==============================================================================
# 2. CANVAS_ITEM OVERLAY SHADER (INITIAL D MANGA SPEEDLINES & AKINA VIGNETTE)
# ==============================================================================
const CANVAS_SPEEDLINES_SHADER_CODE: String = """
shader_type canvas_item;

uniform bool effect_enabled = true;
uniform float speedlines_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float drift_bias : hint_range(-1.0, 1.0) = 0.0;
uniform vec4 ink_color : source_color = vec4(0.04, 0.04, 0.08, 1.0);
uniform vec4 accent_color : source_color = vec4(1.0, 0.96, 0.90, 1.0);

float hash12(vec2 p) {
	vec3 p3  = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise1D(float x) {
	float i = floor(x);
	float f = fract(x);
	float u = f * f * (3.0 - 2.0 * f);
	return mix(hash12(vec2(i, 0.0)), hash12(vec2(i + 1.0, 0.0)), u);
}

void fragment() {
	if (!effect_enabled) {
		COLOR = vec4(0.0);
	} else {
		vec2 uv = UV;
		vec2 screen_size = 1.0 / SCREEN_PIXEL_SIZE;
		float aspect = screen_size.x / max(screen_size.y, 1.0);

		// Shift focal center slightly toward drift direction for authentic Initial D framing
		vec2 focal_center = vec2(0.5 + drift_bias * 0.12, 0.52);
		vec2 delta = uv - focal_center;
		delta.x *= aspect;

		float dist = length(delta);
		float angle = atan(delta.y, delta.x);

		// Quantize animation time to 18 FPS (classic Japanese anime on-twos/threes cadence)
		float anime_time = floor(TIME * 18.0);

		// Multi-layered angular spikes for sharp manga pen strokes
		float angular_freq_1 = angle * 58.0 + anime_time * 13.7;
		float angular_freq_2 = angle * 145.0 - anime_time * 29.3;
		float stroke_pattern = noise1D(angular_freq_1) * 0.55 + noise1D(angular_freq_2) * 0.45;

		// Radial streak modulation
		float radial_sweep = fract(dist * 1.8 - TIME * 4.5 + hash12(vec2(floor(angle * 90.0), anime_time)));
		float spike_reach = mix(0.95, 0.36, speedlines_intensity);
		float radial_mask = smoothstep(spike_reach, spike_reach + 0.32, dist + stroke_pattern * 0.28);

		// Threshold into crisp binary manga speedlines
		float line_threshold = mix(0.86, 0.64, speedlines_intensity);
		float raw_line = smoothstep(line_threshold, line_threshold + 0.04, stroke_pattern * (0.75 + 0.25 * radial_sweep));
		float speedline_alpha = raw_line * radial_mask * smoothstep(0.02, 0.25, speedlines_intensity);

		// Alternate between deep manga ink lines and high-speed white action slashes
		float is_white_slash = step(0.82, hash12(vec2(floor(angle * 75.0), anime_time)));
		vec3 line_rgb = mix(ink_color.rgb, accent_color.rgb, is_white_slash * 0.65);

		// Subtle cinematic anime edge vignette
		float vignette = smoothstep(0.58, 1.15, dist) * 0.22;
		float final_alpha = clamp(max(speedline_alpha * 0.85, vignette), 0.0, 1.0);
		vec3 final_rgb = mix(ink_color.rgb, line_rgb, step(0.01, speedline_alpha));

		COLOR = vec4(final_rgb, final_alpha);
	}
}
"""

func _init() -> void:
	layer = 90
	name = "AnimePostProcessEffect"

func _ready() -> void:
	_build_canvas_overlay()
	_build_spatial_post_quad()
	_build_toast_ui()
	_update_shader_uniforms()

func _build_canvas_overlay() -> void:
	_canvas_rect = ColorRect.new()
	_canvas_rect.name = "AnimeMangaSpeedlinesRect"
	_canvas_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var canvas_shader := Shader.new()
	canvas_shader.code = CANVAS_SPEEDLINES_SHADER_CODE

	_canvas_material = ShaderMaterial.new()
	_canvas_material.shader = canvas_shader
	_canvas_rect.material = _canvas_material

	add_child(_canvas_rect)

func _build_spatial_post_quad() -> void:
	_spatial_quad = MeshInstance3D.new()
	_spatial_quad.name = "AnimeSpatialPostQuad"
	_spatial_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spatial_quad.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_spatial_quad.extra_cull_margin = 16384.0

	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	quad.flip_faces = true
	_spatial_quad.mesh = quad

	var spatial_shader := Shader.new()
	spatial_shader.code = SPATIAL_ANIME_SHADER_CODE

	_spatial_material = ShaderMaterial.new()
	_spatial_material.shader = spatial_shader
	_spatial_material.render_priority = 127
	_spatial_quad.material_override = _spatial_material

	_attach_quad_to_active_camera()

func _build_toast_ui() -> void:
	_toast_panel = PanelContainer.new()
	_toast_panel.name = "AnimeModeToast"
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.visible = false

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.08, 0.92)
	style.border_color = Color(0.95, 0.85, 0.25, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.content_margin_left = 18.0
	style.content_margin_right = 18.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	_toast_panel.add_theme_stylebox_override("panel", style)

	_toast_label = Label.new()
	_toast_label.text = "[F2] ANIME MANGA MODE: ON"
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.add_theme_color_override("font_color", Color(1.0, 0.96, 0.88, 1.0))
	_toast_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
	_toast_label.add_theme_constant_override("outline_size", 4)
	_toast_label.add_theme_font_size_override("font_size", 18)

	_toast_panel.add_child(_toast_label)
	add_child(_toast_panel)

	_toast_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_toast_panel.offset_top = 24.0
	_toast_panel.offset_bottom = 68.0
	_toast_panel.offset_left = 320.0
	_toast_panel.offset_right = -320.0

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F2 or event.keycode == KEY_O:
			toggle_anime_mode()
			get_viewport().set_input_as_handled()

func toggle_anime_mode() -> void:
	effect_enabled = not effect_enabled
	var state_str := "ON" if effect_enabled else "OFF"
	_show_toast("[F2] ANIME MANGA MODE: %s" % state_str)

func _show_toast(message: String) -> void:
	if is_instance_valid(_toast_label) and is_instance_valid(_toast_panel):
		_toast_label.text = message
		_toast_panel.visible = true
		_toast_panel.modulate.a = 1.0
		_toast_timer = TOAST_DURATION

func _process(delta: float) -> void:
	_ensure_camera_attachment()

	if auto_detect_vehicle_speed and effect_enabled:
		_update_vehicle_speedlines(delta)

	if _toast_timer > 0.0 and is_instance_valid(_toast_panel):
		_toast_timer -= delta
		if _toast_timer <= 0.5:
			_toast_panel.modulate.a = clampf(_toast_timer / 0.5, 0.0, 1.0)
		if _toast_timer <= 0.0:
			_toast_panel.visible = false

func _ensure_camera_attachment() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var active_cam := vp.get_camera_3d()
	if active_cam != null and active_cam != _tracked_camera:
		_attach_quad_to_active_camera()
	if is_instance_valid(_spatial_quad):
		_spatial_quad.visible = effect_enabled

func _attach_quad_to_active_camera() -> void:
	if not is_instance_valid(_spatial_quad):
		return
	var vp := get_viewport()
	if vp == null:
		return
	var active_cam := vp.get_camera_3d()
	if active_cam != null:
		if _spatial_quad.get_parent() != active_cam:
			if _spatial_quad.get_parent() != null:
				_spatial_quad.get_parent().remove_child(_spatial_quad)
			active_cam.add_child(_spatial_quad)
			_spatial_quad.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -0.5))
		_tracked_camera = active_cam
	elif _spatial_quad.get_parent() == null:
		add_child(_spatial_quad)

func _update_vehicle_speedlines(delta: float) -> void:
	if not is_instance_valid(_tracked_vehicle):
		_tracked_vehicle = _find_player_vehicle()
		_vehicle_pos_initialized = false

	var current_speed_kmh: float = 0.0
	var current_slip: float = 0.0
	var drift_bias: float = 0.0

	if is_instance_valid(_tracked_vehicle):
		var velocity_vec := Vector3.ZERO
		if "linear_velocity" in _tracked_vehicle:
			velocity_vec = _tracked_vehicle.get("linear_velocity")
		elif "velocity" in _tracked_vehicle:
			velocity_vec = _tracked_vehicle.get("velocity")
		elif _vehicle_pos_initialized and delta > 0.0001:
			velocity_vec = (_tracked_vehicle.global_position - _last_vehicle_pos) / delta

		_last_vehicle_pos = _tracked_vehicle.global_position
		_vehicle_pos_initialized = true

		var horizontal_vel := Vector3(velocity_vec.x, 0.0, velocity_vec.z)
		var speed_ms := horizontal_vel.length()
		current_speed_kmh = speed_ms * 3.6

		if "speed_kmh" in _tracked_vehicle:
			current_speed_kmh = absf(float(_tracked_vehicle.get("speed_kmh")))

		# Compute lateral slip / drift angle for Initial D cornering speedlines
		if speed_ms > 4.5:
			var forward_dir := -_tracked_vehicle.global_transform.basis.z
			forward_dir.y = 0.0
			if forward_dir.length_squared() > 0.001:
				forward_dir = forward_dir.normalized()
				var vel_dir := horizontal_vel.normalized()
				var cross_y := forward_dir.cross(vel_dir).y
				current_slip = clampf((absf(cross_y) - 0.18) / 0.55, 0.0, 1.0)
				drift_bias = clampf(cross_y * 1.4, -1.0, 1.0)
	elif is_instance_valid(_tracked_camera):
		# Fallback to camera motion speed if vehicle node is custom-structured
		if _vehicle_pos_initialized and delta > 0.0001:
			var cam_vel := (_tracked_camera.global_position - _last_vehicle_pos) / delta
			current_speed_kmh = Vector3(cam_vel.x, 0.0, cam_vel.z).length() * 3.6
		_last_vehicle_pos = _tracked_camera.global_position
		_vehicle_pos_initialized = true

	_smoothed_speed_kmh = lerpf(_smoothed_speed_kmh, current_speed_kmh, clampf(delta * 6.0, 0.0, 1.0))
	_smoothed_slip_factor = lerpf(_smoothed_slip_factor, current_slip, clampf(delta * 8.0, 0.0, 1.0))

	var speed_factor := clampf(
		(_smoothed_speed_kmh - speed_activation_kmh) / maxf(max_speed_kmh - speed_activation_kmh, 1.0),
		0.0,
		1.0
	)
	var target_intensity := clampf(maxf(speed_factor * 0.85, _smoothed_slip_factor * 0.95), 0.0, 1.0)
	speedlines_intensity = lerpf(speedlines_intensity, target_intensity, clampf(delta * 7.5, 0.0, 1.0))

	if is_instance_valid(_canvas_material):
		_canvas_material.set_shader_parameter("drift_bias", drift_bias)

func _find_player_vehicle() -> Node3D:
	var tree := get_tree()
	if tree == null:
		return null

	for group_name in ["player", "vehicle", "car", "player_car", "ae86"]:
		var grouped := tree.get_first_node_in_group(group_name)
		if grouped is Node3D:
			return grouped as Node3D

	var root := tree.current_scene
	if root == null:
		return null

	return _search_vehicle_recursive(root)

func _search_vehicle_recursive(node: Node) -> Node3D:
	if node is VehicleBody3D or node is CharacterBody3D or node is RigidBody3D:
		var lower_name := node.name.to_lower()
		if "car" in lower_name or "vehicle" in lower_name or "player" in lower_name or "ae86" in lower_name or "trueno" in lower_name:
			return node as Node3D

	if node is Node3D:
		var lower_name := node.name.to_lower()
		if ("car" in lower_name or "vehicle" in lower_name or "ae86" in lower_name) and ("speed_kmh" in node or "velocity" in node or "linear_velocity" in node):
			return node as Node3D

	for child in node.get_children():
		var found := _search_vehicle_recursive(child)
		if found != null:
			return found
	return null

func _update_shader_uniforms() -> void:
	if is_instance_valid(_spatial_material):
		_spatial_material.set_shader_parameter("effect_enabled", effect_enabled)
		_spatial_material.set_shader_parameter("outline_enabled", outline_enabled)
		_spatial_material.set_shader_parameter("outline_thickness", outline_thickness)
		_spatial_material.set_shader_parameter("depth_threshold", depth_threshold)
		_spatial_material.set_shader_parameter("normal_threshold", normal_threshold)
		_spatial_material.set_shader_parameter("outline_color", outline_color)
		_spatial_material.set_shader_parameter("posterize_enabled", posterize_enabled)
		_spatial_material.set_shader_parameter("cel_bands", cel_bands)
		_spatial_material.set_shader_parameter("saturation_boost", saturation_boost)
		_spatial_material.set_shader_parameter("shadow_tint", shadow_tint)
		_spatial_material.set_shader_parameter("highlight_tint", highlight_tint)

	if is_instance_valid(_canvas_material):
		_canvas_material.set_shader_parameter("effect_enabled", effect_enabled)
		_canvas_material.set_shader_parameter("speedlines_intensity", speedlines_intensity)
		_canvas_material.set_shader_parameter("ink_color", outline_color)