class_name JDMGraphicsSettingsManager
extends Node
## Production Graphics Settings, Real-Time Ray Tracing (SDFGI) & Scalability Manager
## Designed for Godot Engine 4.3 (Vulkan Forward+ Renderer).
## Can run as an Autoload Singleton or as a child node inside any 3D World scene.
## Toggle In-Game Settings Overlay anytime via [F10] or [F1].

signal settings_applied(current_settings: Dictionary)
signal preset_applied(preset_index: int)

const SAVE_PATH: String = "user://graphics_settings.json"
const OVERLAY_LAYER: int = 100

enum QualityPreset {
	POTATO_STEAM_DECK = 0, ## 0.70x Bilinear, FXAA, 1024 Shadows, No GI/SSR/SSAO/Volumetrics
	MEDIUM = 1,            ## 1.0x Scale, Low SSR (16), Low SSAO, 2048 Shadows
	HIGH = 2,              ## FSR 2.2 Quality (0.77x) / 1.0x TAA, 1-Cascade SDFGI, High SSR (64), SSAO+SSIL, Vol. Fog
	ULTRA_RAY_TRACING = 3, ## 1.0x TAA, 4-Cascade SDFGI (Initial D Sunset Glow), 128-Step Rough SSR, Ultra SSAO+SSIL, God Rays, 4096 Soft Shadows
	CUSTOM = 4             ## User-modified individual controls
}

enum UpscalerMode {
	BILINEAR = 0,
	FSR_1_0 = 1,
	FSR_2_2 = 2
}

enum WindowDisplayMode {
	BORDERLESS_FULLSCREEN = 0,
	EXCLUSIVE_FULLSCREEN = 1,
	WINDOWED = 2
}

enum VSyncOption {
	DISABLED = 0,
	ENABLED = 1,
	ADAPTIVE = 2,
	FAST_MAILBOX = 3
}

@export_group("Scene Node Binding (Auto-Discovered if Null)")
@export var target_world_environment: WorldEnvironment = null
@export var target_directional_light: DirectionalLight3D = null

@export_group("Startup Defaults")
@export var default_preset: QualityPreset = QualityPreset.HIGH
@export var auto_load_on_ready: bool = true

# Active Settings State Dictionary (Serialized to user://graphics_settings.json)
var settings: Dictionary = {
	"preset": QualityPreset.HIGH,
	"resolution_scale": 1.0,
	"upscaler_mode": UpscalerMode.BILINEAR,
	"window_mode": WindowDisplayMode.BORDERLESS_FULLSCREEN,
	"vsync_mode": VSyncOption.ENABLED,
	"max_fps": 0, # 0 = Unlimited, or 60 / 120 / 144 / 240
	"taa_enabled": true,
	"fxaa_enabled": false,
	"msaa_3d": Viewport.MSAA_DISABLED,
	"sdfgi_enabled": true,
	"sdfgi_quality": 1, # 0 = Off, 1 = High (1 Cascade), 2 = Ultra RT (4 Cascades + Skylight/Bounce)
	"ssr_enabled": true,
	"ssr_quality": 2,   # 0 = Off, 1 = Low (16), 2 = High (64), 3 = Ultra (128 + Roughness)
	"ssao_enabled": true,
	"ssao_quality": 2,  # 0 = Very Low, 1 = Low, 2 = Medium/High, 3 = Ultra
	"ssil_enabled": true,
	"volumetric_fog_enabled": true,
	"god_rays_temporal": true,
	"volumetric_fog_density": 0.015,
	"shadow_size": 2048,
	"shadow_filter_quality": 3, # RenderingServer.ShadowQuality
	"motion_blur_enabled": true,
	"motion_blur_intensity": 0.55
}

# Internal GUI & Post-Process References
var _ui_layer: CanvasLayer = null
var _ui_panel: PanelContainer = null
var _fps_label: Label = null
var _ui_updating: bool = false

# UI Control References for programmatic synchronization
var _ctrl_preset: OptionButton
var _ctrl_res_scale: HSlider
var _lbl_res_scale: Label
var _ctrl_upscaler: OptionButton
var _ctrl_window: OptionButton
var _ctrl_vsync: OptionButton
var _ctrl_fps: OptionButton
var _ctrl_taa: CheckButton
var _ctrl_fxaa: CheckButton
var _ctrl_sdfgi_toggle: CheckButton
var _ctrl_sdfgi_quality: OptionButton
var _ctrl_ssr_toggle: CheckButton
var _ctrl_ssr_quality: OptionButton
var _ctrl_ssao_toggle: CheckButton
var _ctrl_ssao_quality: OptionButton
var _ctrl_ssil_toggle: CheckButton
var _ctrl_vol_fog_toggle: CheckButton
var _ctrl_god_rays_toggle: CheckButton
var _ctrl_mb_toggle: CheckButton
var _ctrl_mb_slider: HSlider
var _lbl_mb_val: Label

# Camera Velocity Shutter Motion Blur System
var _mb_layer: CanvasLayer = null
var _mb_rect: ColorRect = null
var _mb_material: ShaderMaterial = null
var _prev_cam_pos: Vector3 = Vector3.ZERO
var _prev_cam_basis: Basis = Basis.IDENTITY
var _has_prev_cam: bool = false
var _fps_refresh_timer: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_discover_environment_nodes()
	_setup_motion_blur_post_process()
	_build_settings_overlay_ui()

	# Re-bind environment nodes automatically whenever scenes change
	get_tree().node_added.connect(_on_tree_node_added)

	if auto_load_on_ready and FileAccess.file_exists(SAVE_PATH):
		load_settings()
	else:
		apply_preset(default_preset, false)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_F10, KEY_F1, KEY_O] or event.physical_keycode in [KEY_F10, KEY_F1, KEY_O]:
			toggle_settings_menu()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_update_camera_motion_blur(delta)

	if _ui_panel != null and _ui_panel.visible:
		_fps_refresh_timer += delta
		if _fps_refresh_timer >= 0.2:
			_fps_refresh_timer = 0.0
			var fps: int = int(Engine.get_frames_per_second())
			var frame_ms: float = 1000.0 / maxf(1.0, float(fps))
			var vp_size: Vector2i = get_viewport().size
			var internal_size: Vector2i = Vector2i(Vector2(vp_size) * float(settings["resolution_scale"]))
			_fps_label.text = "%d FPS (%.2f ms) | Internal 3D: %dx%d" % [fps, frame_ms, internal_size.x, internal_size.y]


# ==============================================================================
# 1. PRESET CALIBRATION & HARDWARE TIER PROFILES
# ==============================================================================
func apply_preset(preset: QualityPreset, save_to_disk: bool = true) -> void:
	settings["preset"] = preset

	match preset:
		QualityPreset.POTATO_STEAM_DECK:
			settings["resolution_scale"] = 0.70
			settings["upscaler_mode"] = UpscalerMode.BILINEAR
			settings["taa_enabled"] = false
			settings["fxaa_enabled"] = true
			settings["msaa_3d"] = Viewport.MSAA_DISABLED
			settings["sdfgi_enabled"] = false
			settings["sdfgi_quality"] = 0
			settings["ssr_enabled"] = false
			settings["ssr_quality"] = 0
			settings["ssao_enabled"] = false
			settings["ssao_quality"] = 0
			settings["ssil_enabled"] = false
			settings["volumetric_fog_enabled"] = false
			settings["god_rays_temporal"] = false
			settings["shadow_size"] = 1024
			settings["shadow_filter_quality"] = RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW
			settings["motion_blur_enabled"] = false

		QualityPreset.MEDIUM:
			settings["resolution_scale"] = 1.00
			settings["upscaler_mode"] = UpscalerMode.BILINEAR
			settings["taa_enabled"] = false
			settings["fxaa_enabled"] = true
			settings["msaa_3d"] = Viewport.MSAA_DISABLED
			settings["sdfgi_enabled"] = false
			settings["sdfgi_quality"] = 0
			settings["ssr_enabled"] = true
			settings["ssr_quality"] = 1 # Low (16 steps)
			settings["ssao_enabled"] = true
			settings["ssao_quality"] = 1 # Low
			settings["ssil_enabled"] = false
			settings["volumetric_fog_enabled"] = false
			settings["god_rays_temporal"] = false
			settings["shadow_size"] = 2048
			settings["shadow_filter_quality"] = RenderingServer.SHADOW_QUALITY_SOFT_LOW
			settings["motion_blur_enabled"] = false

		QualityPreset.HIGH:
			settings["resolution_scale"] = 0.77
			settings["upscaler_mode"] = UpscalerMode.FSR_2_2 # FSR 2.2 Quality (0.77x) + Temporal AA
			settings["taa_enabled"] = true
			settings["fxaa_enabled"] = false
			settings["msaa_3d"] = Viewport.MSAA_DISABLED
			settings["sdfgi_enabled"] = true
			settings["sdfgi_quality"] = 1 # 1 Cascade, min cell size 0.25
			settings["ssr_enabled"] = true
			settings["ssr_quality"] = 2 # High (64 steps)
			settings["ssao_enabled"] = true
			settings["ssao_quality"] = 2 # High
			settings["ssil_enabled"] = true
			settings["volumetric_fog_enabled"] = true
			settings["god_rays_temporal"] = true
			settings["volumetric_fog_density"] = 0.015
			settings["shadow_size"] = 2048
			settings["shadow_filter_quality"] = RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM
			settings["motion_blur_enabled"] = true
			settings["motion_blur_intensity"] = 0.45

		QualityPreset.ULTRA_RAY_TRACING:
			# Initial D Touge Sunset Glow Profile
			settings["resolution_scale"] = 1.00
			settings["upscaler_mode"] = UpscalerMode.BILINEAR
			settings["taa_enabled"] = true
			settings["fxaa_enabled"] = false
			settings["msaa_3d"] = Viewport.MSAA_DISABLED
			settings["sdfgi_enabled"] = true
			settings["sdfgi_quality"] = 2 # 4 Cascades, Bounce 0.5, Occlusion, Read Skylight
			settings["ssr_enabled"] = true
			settings["ssr_quality"] = 3 # Max 128 steps + Roughness
			settings["ssao_enabled"] = true
			settings["ssao_quality"] = 3 # Ultra + Horizon Angle 0.25
			settings["ssil_enabled"] = true
			settings["volumetric_fog_enabled"] = true
			settings["god_rays_temporal"] = true
			settings["volumetric_fog_density"] = 0.018
			settings["shadow_size"] = 4096
			settings["shadow_filter_quality"] = RenderingServer.SHADOW_QUALITY_SOFT_HIGH
			settings["motion_blur_enabled"] = true
			settings["motion_blur_intensity"] = 0.65

		QualityPreset.CUSTOM:
			pass

	apply_all_settings(save_to_disk)
	preset_applied.emit(int(preset))


# ==============================================================================
# 2. CORE ENGINE & RENDERING SERVER APPLICATION PIPELINE
# ==============================================================================
func apply_all_settings(save_to_disk: bool = true) -> void:
	_discover_environment_nodes()

	_apply_window_and_vsync()
	_apply_viewport_scaling_and_aa()
	_apply_rendering_server_quality()
	_apply_environment_features()
	_apply_directional_light_shadows()
	_sync_ui_from_settings()

	if save_to_disk:
		save_settings()

	settings_applied.emit(settings.duplicate())


func _apply_window_and_vsync() -> void:
	# V-Sync Mode
	match int(settings["vsync_mode"]):
		VSyncOption.DISABLED:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		VSyncOption.ENABLED:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
		VSyncOption.ADAPTIVE:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ADAPTIVE)
		VSyncOption.FAST_MAILBOX:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_MAILBOX)

	# Window Display Mode
	match int(settings["window_mode"]):
		WindowDisplayMode.BORDERLESS_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
		WindowDisplayMode.EXCLUSIVE_FULLSCREEN:
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		WindowDisplayMode.WINDOWED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)

	# Frame Rate Cap
	Engine.max_fps = int(settings["max_fps"])


func _apply_viewport_scaling_and_aa() -> void:
	var vp: Viewport = get_viewport()
	if vp == null:
		return

	var scale_val: float = clampf(float(settings["resolution_scale"]), 0.50, 2.00)
	vp.scaling_3d_scale = scale_val

	var up_mode: int = int(settings["upscaler_mode"])
	match up_mode:
		UpscalerMode.BILINEAR:
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
			vp.use_taa = bool(settings["taa_enabled"])
		UpscalerMode.FSR_1_0:
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
			vp.fsr_sharpness = 0.8
			vp.use_taa = bool(settings["taa_enabled"])
		UpscalerMode.FSR_2_2:
			# Godot 4.3 FSR 2.2 includes built-in temporal accumulation
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
			vp.fsr_sharpness = 0.85
			vp.use_taa = false

	vp.screen_space_aa = (
		Viewport.SCREEN_SPACE_AA_FXAA
		if bool(settings["fxaa_enabled"])
		else Viewport.SCREEN_SPACE_AA_DISABLED
	)
	vp.msaa_3d = int(settings["msaa_3d"]) as Viewport.MSAA


func _apply_rendering_server_quality() -> void:
	# Shadow Map Atlas Size & Filter Quality
	var sh_size: int = int(settings["shadow_size"])
	var sh_filter: int = int(settings["shadow_filter_quality"])
	var is_16bit: bool = sh_size <= 2048
	RenderingServer.directional_shadow_atlas_set_size(sh_size, is_16bit)
	RenderingServer.directional_soft_shadow_filter_set_quality(sh_filter as RenderingServer.ShadowQuality)
	RenderingServer.positional_soft_shadow_filter_set_quality(sh_filter as RenderingServer.ShadowQuality)

	# Screen-Space Ambient Occlusion (SSAO) Quality
	var ssao_q: int = int(settings["ssao_quality"])
	match ssao_q:
		0:
			RenderingServer.environment_set_ssao_quality(
				RenderingServer.ENV_SSAO_QUALITY_VERY_LOW, true, 0.5, 2, 50.0, 300.0
			)
		1:
			RenderingServer.environment_set_ssao_quality(
				RenderingServer.ENV_SSAO_QUALITY_LOW, false, 0.5, 2, 50.0, 300.0
			)
		2:
			RenderingServer.environment_set_ssao_quality(
				RenderingServer.ENV_SSAO_QUALITY_MEDIUM, false, 0.5, 2, 50.0, 300.0
			)
		_:
			RenderingServer.environment_set_ssao_quality(
				RenderingServer.ENV_SSAO_QUALITY_ULTRA, false, 0.85, 2, 50.0, 300.0
			)

	# Screen-Space Indirect Lighting (SSIL) Quality
	var ssil_q: RenderingServer.EnvironmentSSILQuality = (
		RenderingServer.ENV_SSIL_QUALITY_HIGH
		if int(settings["preset"]) == QualityPreset.ULTRA_RAY_TRACING
		else RenderingServer.ENV_SSIL_QUALITY_MEDIUM
	)
	RenderingServer.environment_set_ssil_quality(ssil_q, false, 0.5, 4, 50.0, 300.0)

	# Screen-Space Roughness Limiter for Ultra SSR
	var use_roughness: bool = int(settings["ssr_quality"]) >= 3
	RenderingServer.environment_set_ssr_roughness_quality(
		RenderingServer.ENV_SSR_ROUGHNESS_QUALITY_HIGH
		if use_roughness
		else RenderingServer.ENV_SSR_ROUGHNESS_QUALITY_DISABLED
	)

	# SDFGI Ray Count & Convergence Speed
	if int(settings["sdfgi_quality"]) >= 2:
		RenderingServer.environment_set_sdfgi_ray_count(RenderingServer.ENV_SDFGI_RAY_COUNT_32)
		RenderingServer.environment_set_sdfgi_frames_to_converge(RenderingServer.ENV_SDFGI_CONVERGE_IN_15_FRAMES)
	else:
		RenderingServer.environment_set_sdfgi_ray_count(RenderingServer.ENV_SDFGI_RAY_COUNT_16)
		RenderingServer.environment_set_sdfgi_frames_to_converge(RenderingServer.ENV_SDFGI_CONVERGE_IN_10_FRAMES)


func _apply_environment_features() -> void:
	if not is_instance_valid(target_world_environment) or target_world_environment.environment == null:
		return

	var env: Environment = target_world_environment.environment

	# 1. SDFGI (Real-time Software Ray Traced Global Illumination)
	var sdfgi_on: bool = bool(settings["sdfgi_enabled"]) and int(settings["sdfgi_quality"]) > 0
	env.sdfgi_enabled = sdfgi_on
	if sdfgi_on:
		if int(settings["sdfgi_quality"]) == 1:
			# High Preset: 1 Cascade, 0.25 min cell size
			env.sdfgi_cascades = 1
			env.sdfgi_min_cell_size = 0.25
			env.sdfgi_bounce_feedback = 0.35
			env.sdfgi_use_occlusion = true
			env.sdfgi_read_sky_light = true
		else:
			# Ultra / Ray Tracing (Initial D Touge Sunset Glow): 4 Cascades
			env.sdfgi_cascades = 4
			env.sdfgi_min_cell_size = 0.20
			env.sdfgi_bounce_feedback = 0.50
			env.sdfgi_use_occlusion = true
			env.sdfgi_read_sky_light = true
			env.sdfgi_energy = 1.15

	# 2. Screen-Space Reflections (SSR)
	var ssr_on: bool = bool(settings["ssr_enabled"]) and int(settings["ssr_quality"]) > 0
	env.ssr_enabled = ssr_on
	if ssr_on:
		match int(settings["ssr_quality"]):
			1:
				env.ssr_max_steps = 16
				env.ssr_fade_in = 0.15
				env.ssr_fade_out = 2.0
			2:
				env.ssr_max_steps = 64
				env.ssr_fade_in = 0.15
				env.ssr_fade_out = 2.0
			_:
				env.ssr_max_steps = 128
				env.ssr_fade_in = 0.12
				env.ssr_fade_out = 1.6
				env.ssr_depth_tolerance = 0.25

	# 3. Screen-Space Ambient Occlusion (SSAO) & Indirect Lighting (SSIL)
	env.ssao_enabled = bool(settings["ssao_enabled"])
	if env.ssao_enabled:
		if int(settings["ssao_quality"]) >= 3:
			env.ssao_horizon = 0.25
			env.ssao_intensity = 2.15
			env.ssao_radius = 1.15
		else:
			env.ssao_horizon = 0.06
			env.ssao_intensity = 1.85
			env.ssao_radius = 1.0

	env.ssil_enabled = bool(settings["ssil_enabled"])
	if env.ssil_enabled:
		env.ssil_radius = 5.0
		env.ssil_intensity = 1.05
		env.ssil_sharpness = 0.98

	# 4. Volumetric Fog & God Rays vs. Linear Depth Fog Fallback
	var vol_fog_on: bool = bool(settings["volumetric_fog_enabled"])
	env.volumetric_fog_enabled = vol_fog_on
	if vol_fog_on:
		env.fog_enabled = false
		env.volumetric_fog_density = float(settings["volumetric_fog_density"])
		env.volumetric_fog_anisotropy = 0.68 # Enhances directional sunset light shafts (God Rays)
		env.volumetric_fog_temporal_reprojection_enabled = bool(settings["god_rays_temporal"])
		env.volumetric_fog_temporal_reprojection_amount = 0.90
	else:
		# Standard fast linear depth fog fallback for Potato / Medium tiers
		env.fog_enabled = true
		env.fog_density = 0.0012
		env.fog_aerial_perspective = 0.45


func _apply_directional_light_shadows() -> void:
	if not is_instance_valid(target_directional_light):
		return

	target_directional_light.shadow_enabled = true
	var sh_size: int = int(settings["shadow_size"])
	if sh_size <= 1024:
		target_directional_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		target_directional_light.directional_shadow_blend_splits = false
		target_directional_light.shadow_blur = 0.75
	elif sh_size <= 2048:
		target_directional_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		target_directional_light.directional_shadow_blend_splits = true
		target_directional_light.shadow_blur = 1.0
	else:
		target_directional_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		target_directional_light.directional_shadow_blend_splits = true
		target_directional_light.shadow_blur = 1.45


# ==============================================================================
# 3. PUBLIC API FOR INDIVIDUAL GRAPHICS CONTROLS
# ==============================================================================
func set_resolution_scale(scale: float) -> void:
	settings["resolution_scale"] = clampf(scale, 0.50, 2.00)
	settings["preset"] = QualityPreset.CUSTOM
	apply_all_settings()

func set_upscaler_mode(mode: UpscalerMode) -> void:
	settings["upscaler_mode"] = mode
	settings["preset"] = QualityPreset.CUSTOM
	apply_all_settings()

func set_window_mode(mode: WindowDisplayMode) -> void:
	settings["window_mode"] = mode
	apply_all_settings()

func set_vsync_mode(mode: VSyncOption) -> void:
	settings["vsync_mode"] = mode
	apply_all_settings()

func set_max_fps(fps_cap: int) -> void:
	settings["max_fps"] = maxi(0, fps_cap)
	apply_all_settings()

func set_sdfgi(enabled: bool, quality_tier: int = 1) -> void:
	settings["sdfgi_enabled"] = enabled
	settings["sdfgi_quality"] = clampi(quality_tier, 0, 2)
	settings["preset"] = QualityPreset.CUSTOM
	apply_all_settings()

func set_ssr(enabled: bool, quality_tier: int = 2) -> void:
	settings["ssr_enabled"] = enabled
	settings["ssr_quality"] = clampi(quality_tier, 0, 3)
	settings["preset"] = QualityPreset.CUSTOM
	apply_all_settings()

func set_ssao_and_ssil(ssao_on: bool, ssil_on: bool, ssao_quality_tier: int = 2) -> void:
	settings["ssao_enabled"] = ssao_on
	settings["ssil_enabled"] = ssil_on
	settings["ssao_quality"] = clampi(ssao_quality_tier, 0, 3)
	settings["preset"] = QualityPreset.CUSTOM
	apply_all_settings()

func set_volumetric_fog(enabled: bool, god_rays_reprojection: bool = true, density: float = 0.015) -> void:
	settings["volumetric_fog_enabled"] = enabled
	settings["god_rays_temporal"] = god_rays_reprojection
	settings["volumetric_fog_density"] = clampf(density, 0.001, 0.1)
	settings["preset"] = QualityPreset.CUSTOM
	apply_all_settings()

func set_motion_blur(enabled: bool, intensity: float = 0.55) -> void:
	settings["motion_blur_enabled"] = enabled
	settings["motion_blur_intensity"] = clampf(intensity, 0.0, 1.0)
	apply_all_settings()


# ==============================================================================
# 4. CONFIGURATION PERSISTENCE (JSON SERIALIZATION)
# ==============================================================================
func save_settings() -> void:
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("JDMGraphicsSettingsManager: Could not open %s for writing." % SAVE_PATH)
		return
	var json_str: String = JSON.stringify(settings, "\t")
	file.store_string(json_str)
	file.close()


func load_settings() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		apply_preset(default_preset, true)
		return

	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		apply_preset(default_preset, false)
		return

	var content: String = file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(content)
	if parsed is Dictionary:
		for key: String in parsed.keys():
			if settings.has(key):
				settings[key] = parsed[key]
		apply_all_settings(false)
	else:
		push_warning("JDMGraphicsSettingsManager: Corrupted settings JSON, restoring default preset.")
		apply_preset(default_preset, true)


# ==============================================================================
# 5. CAMERA VELOCITY SHUTTER MOTION BLUR POST-PROCESSOR
# ==============================================================================
func _setup_motion_blur_post_process() -> void:
	_mb_layer = CanvasLayer.new()
	_mb_layer.name = "JDMMotionBlurLayer"
	_mb_layer.layer = 12 # Beneath HUD (Layer 15) and Settings Menu (Layer 100)
	add_child(_mb_layer)

	_mb_rect = ColorRect.new()
	_mb_rect.name = "ShutterBlurQuad"
	_mb_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mb_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var shader: Shader = Shader.new()
	shader.code = """
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform vec2 linear_blur_vec = vec2(0.0);
uniform float radial_zoom_blur = 0.0;
uniform float shutter_strength : hint_range(0.0, 1.0) = 0.55;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 centered = uv - vec2(0.5);
	float edge_mask = smoothstep(0.08, 0.68, length(centered));

	// Combine camera angular pan vector with forward high-speed peripheral tunnel blur
	vec2 velocity_uv = (linear_blur_vec + centered * radial_zoom_blur * edge_mask) * shutter_strength;
	float mag = length(velocity_uv);
	if (mag > 0.032) {
		velocity_uv = (velocity_uv / mag) * 0.032;
	}

	vec3 accum = vec3(0.0);
	const int SAMPLES = 8;
	for (int i = 0; i < SAMPLES; i++) {
		float t = (float(i) / float(SAMPLES - 1)) - 0.5;
		vec2 sample_uv = clamp(uv + velocity_uv * t, vec2(0.001), vec2(0.999));
		accum += texture(screen_tex, sample_uv).rgb;
	}
	COLOR = vec4(accum / float(SAMPLES), 1.0);
}
"""
	_mb_material = ShaderMaterial.new()
	_mb_material.shader = shader
	_mb_rect.material = _mb_material
	_mb_layer.add_child(_mb_rect)


func _update_camera_motion_blur(delta: float) -> void:
	if _mb_rect == null:
		return

	var mb_on: bool = bool(settings["motion_blur_enabled"]) and float(settings["motion_blur_intensity"]) > 0.01
	var cam: Camera3D = get_viewport().get_camera_3d()
	if not mb_on or cam == null or delta <= 0.0001:
		_mb_rect.visible = false
		_has_prev_cam = false
		return

	_mb_rect.visible = true
	var cur_pos: Vector3 = cam.global_position
	var cur_basis: Basis = cam.global_transform.basis

	if not _has_prev_cam:
		_prev_cam_pos = cur_pos
		_prev_cam_basis = cur_basis
		_has_prev_cam = true
		return

	var world_vel: Vector3 = (cur_pos - _prev_cam_pos) / delta
	var local_vel: Vector3 = cur_basis.inverse() * world_vel

	var cur_fwd: Vector3 = -cur_basis.z
	var prev_fwd: Vector3 = -_prev_cam_basis.z
	var cam_right: Vector3 = cur_basis.x
	var cam_up: Vector3 = cur_basis.y

	var yaw_rate: float = (cur_fwd - prev_fwd).dot(cam_right) / delta
	var pitch_rate: float = (cur_fwd - prev_fwd).dot(cam_up) / delta

	var linear_vec: Vector2 = Vector2(
		clampf(-yaw_rate * 0.012 - local_vel.x * 0.0004, -0.025, 0.025),
		clampf(pitch_rate * 0.012 + local_vel.y * 0.0004, -0.025, 0.025)
	)
	var forward_speed: float = maxf(0.0, -local_vel.z)
	var radial_blur: float = clampf((forward_speed - 12.0) * 0.00055, 0.0, 0.028)

	_mb_material.set_shader_parameter("linear_blur_vec", linear_vec)
	_mb_material.set_shader_parameter("radial_zoom_blur", radial_blur)
	_mb_material.set_shader_parameter("shutter_strength", float(settings["motion_blur_intensity"]))

	_prev_cam_pos = cur_pos
	_prev_cam_basis = cur_basis


# ==============================================================================
# 6. AUTOMATIC SCENE ENVIRONMENT & DIRECTIONAL LIGHT DISCOVERY
# ==============================================================================
func _discover_environment_nodes() -> void:
	var root: Node = get_tree().current_scene
	if root == null:
		root = get_tree().root

	if not is_instance_valid(target_world_environment):
		var found_env: Node = root.find_child("*", true, false)
		for node: Node in root.find_children("*", "WorldEnvironment", true, false):
			if node is WorldEnvironment:
				target_world_environment = node
				break

	if not is_instance_valid(target_directional_light):
		for node: Node in root.find_children("*", "DirectionalLight3D", true, false):
			if node is DirectionalLight3D:
				target_directional_light = node
				break


func _on_tree_node_added(node: Node) -> void:
	if node is WorldEnvironment and not is_instance_valid(target_world_environment):
		target_world_environment = node
		_apply_environment_features()
	elif node is DirectionalLight3D and not is_instance_valid(target_directional_light):
		target_directional_light = node
		_apply_directional_light_shadows()


# ==============================================================================
# 7. IN-GAME SLEEK GRAPHICS SETTINGS OVERLAY ([F10] / [F1])
# ==============================================================================
func toggle_settings_menu() -> void:
	if _ui_panel == null:
		return
	_ui_panel.visible = not _ui_panel.visible
	if _ui_panel.visible:
		_sync_ui_from_settings()


func toggle_menu() -> void:
	toggle_settings_menu()


func _build_settings_overlay_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "JDMGraphicsSettingsUI"
	_ui_layer.layer = OVERLAY_LAYER
	add_child(_ui_layer)

	_ui_panel = PanelContainer.new()
	_ui_panel.visible = false
	_ui_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_ui_panel.custom_minimum_size = Vector2(640, 620)
	_ui_panel.offset_left = -320
	_ui_panel.offset_right = 320
	_ui_panel.offset_top = -310
	_ui_panel.offset_bottom = 310

	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.045, 0.06, 0.92)
	style.border_color = Color(1.0, 0.38, 0.08, 0.88)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(18)
	_ui_panel.add_theme_stylebox_override("panel", style)
	_ui_layer.add_child(_ui_panel)

	var main_vbox: VBoxContainer = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	_ui_panel.add_child(main_vbox)

	# Header Row
	var header_hbox: HBoxContainer = HBoxContainer.new()
	main_vbox.add_child(header_hbox)

	var title_lbl: Label = Label.new()
	title_lbl.text = "JDM VULKAN FORWARD+ // GRAPHICS & RAY TRACING (SDFGI)"
	title_lbl.add_theme_color_override("font_color", Color(1.0, 0.45, 0.12))
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(title_lbl)

	var close_btn: Button = Button.new()
	close_btn.text = " [X] F10 "
	close_btn.pressed.connect(toggle_settings_menu)
	header_hbox.add_child(close_btn)

	# Live Telemetry Bar
	_fps_label = Label.new()
	_fps_label.text = "144 FPS (6.94 ms)"
	_fps_label.add_theme_color_override("font_color", Color(0.35, 0.95, 1.0))
	_fps_label.add_theme_font_size_override("font_size", 13)
	main_vbox.add_child(_fps_label)

	var sep: HSeparator = HSeparator.new()
	main_vbox.add_child(sep)

	# Scrollable Controls Grid
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(scroll)

	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 9)
	scroll.add_child(grid)

	# 1. Master Hardware Preset
	_ctrl_preset = _add_dropdown_row(grid, "Hardware Quality Preset", [
		"1. POTATO / STEAM DECK LOW",
		"2. MEDIUM (1080p Balanced)",
		"3. HIGH (FSR 2.2 + SDFGI)",
		"4. ULTRA / RAY TRACING (Initial D Sunset)",
		"5. CUSTOM PROFILE"
	])
	_ctrl_preset.item_selected.connect(func(idx: int) -> void:
		if not _ui_updating:
			apply_preset(idx as QualityPreset, true)
	)

	# 2. 3D Resolution Scale Slider
	_add_label(grid, "3D Resolution Scale")
	var scale_hbox: HBoxContainer = HBoxContainer.new()
	scale_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ctrl_res_scale = HSlider.new()
	_ctrl_res_scale.min_value = 0.50
	_ctrl_res_scale.max_value = 1.50
	_ctrl_res_scale.step = 0.01
	_ctrl_res_scale.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_res_scale = Label.new()
	_lbl_res_scale.custom_minimum_size = Vector2(58, 0)
	scale_hbox.add_child(_ctrl_res_scale)
	scale_hbox.add_child(_lbl_res_scale)
	grid.add_child(scale_hbox)
	_ctrl_res_scale.value_changed.connect(func(val: float) -> void:
		_lbl_res_scale.text = "%d%%" % roundi(val * 100.0)
		if not _ui_updating:
			set_resolution_scale(val)
	)

	# 3. Upscaler Mode
	_ctrl_upscaler = _add_dropdown_row(grid, "3D Upscaler Mode", [
		"Bilinear (Native / Fast)",
		"AMD FSR 1.0 (Spatial)",
		"AMD FSR 2.2 (Temporal Quality)"
	])
	_ctrl_upscaler.item_selected.connect(func(idx: int) -> void:
		if not _ui_updating:
			set_upscaler_mode(idx as UpscalerMode)
	)

	# 4. Window Mode
	_ctrl_window = _add_dropdown_row(grid, "Window Display Mode", [
		"Borderless Fullscreen",
		"Exclusive Fullscreen",
		"Windowed"
	])
	_ctrl_window.item_selected.connect(func(idx: int) -> void:
		if not _ui_updating:
			set_window_mode(idx as WindowDisplayMode)
	)

	# 5. V-Sync Mode
	_ctrl_vsync = _add_dropdown_row(grid, "V-Sync Synchronization", [
		"Disabled (Lowest Latency)",
		"Enabled (Standard V-Sync)",
		"Adaptive V-Sync",
		"Fast Mailbox (Tear-Free Low Latency)"
	])
	_ctrl_vsync.item_selected.connect(func(idx: int) -> void:
		if not _ui_updating:
			set_vsync_mode(idx as VSyncOption)
	)

	# 6. Max FPS Cap
	_ctrl_fps = _add_dropdown_row(grid, "Max Frame Rate Cap", [
		"60 FPS", "120 FPS", "144 FPS", "240 FPS", "Unlimited"
	])
	_ctrl_fps.item_selected.connect(func(idx: int) -> void:
		if not _ui_updating:
			var caps: Array[int] = [60, 120, 144, 240, 0]
			set_max_fps(caps[clampi(idx, 0, 4)])
	)

	# 7. Anti-Aliasing (TAA & FXAA)
	_ctrl_taa = _add_toggle_row(grid, "Temporal Anti-Aliasing (TAA)")
	_ctrl_taa.toggled.connect(func(on: bool) -> void:
		if not _ui_updating:
			settings["taa_enabled"] = on
			settings["preset"] = QualityPreset.CUSTOM
			apply_all_settings()
	)

	_ctrl_fxaa = _add_toggle_row(grid, "Fast Post-Process AA (FXAA)")
	_ctrl_fxaa.toggled.connect(func(on: bool) -> void:
		if not _ui_updating:
			settings["fxaa_enabled"] = on
			settings["preset"] = QualityPreset.CUSTOM
			apply_all_settings()
	)

	# 8. SDFGI Real-Time Ray Tracing
	_ctrl_sdfgi_toggle = _add_toggle_row(grid, "Real-Time Ray Traced GI (SDFGI)")
	_ctrl_sdfgi_toggle.toggled.connect(func(on: bool) -> void:
		if not _ui_updating:
			var q: int = maxi(1, int(settings["sdfgi_quality"])) if on else 0
			set_sdfgi(on, q)
	)

	_ctrl_sdfgi_quality = _add_dropdown_row(grid, "SDFGI Cascade & Bounce Tier", [
		"Disabled",
		"High (1 Cascade, 0.25m Cell)",
		"Ultra Touge Glow (4 Cascades + Skylight)"
	])
	_ctrl_sdfgi_quality.item_selected.connect(func(idx: int) -> void:
		if not _ui_updating:
			set_sdfgi(idx > 0, idx)
	)

	# 9. Screen-Space Reflections (SSR)
	_ctrl_ssr_toggle = _add_toggle_row(grid, "Screen-Space Reflections (SSR)")
	_ctrl_ssr_toggle.toggled.connect(func(on: bool) -> void:
		if not _ui_updating:
			var q: int = maxi(1, int(settings["ssr_quality"])) if on else 0
			set_ssr(on, q)
	)

	_ctrl_ssr_quality = _add_dropdown_row(grid, "SSR Ray Step Quality", [
		"Disabled",
		"Low (16 Steps)",
		"High (64 Steps)",
		"Ultra (128 Steps + Roughness)"
	])
	_ctrl_ssr_quality.item_selected.connect(func(idx: int) -> void:
		if not _ui_updating:
			set_ssr(idx > 0, idx)
	)

	# 10. SSAO & SSIL
	_ctrl_ssao_toggle = _add_toggle_row(grid, "Ambient Occlusion (SSAO)")
	_ctrl_ssao_toggle.toggled.connect(func(on: bool) -> void:
		if not _ui_updating:
			set_ssao_and_ssil(on, bool(settings["ssil_enabled"]), int(settings["ssao_quality"]))
	)

	_ctrl_ssao_quality = _add_dropdown_row(grid, "SSAO Quality Preset", [
		"Very Low (Half-Res)",
		"Low",
		"High",
		"Ultra (0.25 Horizon Angle)"
	])
	_ctrl_ssao_quality.item_selected.connect(func(idx: int) -> void:
		if not _ui_updating:
			set_ssao_and_ssil(bool(settings["ssao_enabled"]), bool(settings["ssil_enabled"]), idx)
	)

	_ctrl_ssil_toggle = _add_toggle_row(grid, "Indirect Bounce Lighting (SSIL)")
	_ctrl_ssil_toggle.toggled.connect(func(on: bool) -> void:
		if not _ui_updating:
			set_ssao_and_ssil(bool(settings["ssao_enabled"]), on, int(settings["ssao_quality"]))
	)

	# 11. Volumetric Fog & God Rays
	_ctrl_vol_fog_toggle = _add_toggle_row(grid, "Volumetric Fog (Touge Atmosphere)")
	_ctrl_vol_fog_toggle.toggled.connect(func(on: bool) -> void:
		if not _ui_updating:
			set_volumetric_fog(on, bool(settings["god_rays_temporal"]), float(settings["volumetric_fog_density"]))
	)

	_ctrl_god_rays_toggle = _add_toggle_row(grid, "Temporal God Rays Reprojection")
	_ctrl_god_rays_toggle.toggled.connect(func(on: bool) -> void:
		if not _ui_updating:
			set_volumetric_fog(bool(settings["volumetric_fog_enabled"]), on, float(settings["volumetric_fog_density"]))
	)

	# 12. Camera Shutter Motion Blur
	_ctrl_mb_toggle = _add_toggle_row(grid, "Camera Velocity Motion Blur")
	_ctrl_mb_toggle.toggled.connect(func(on: bool) -> void:
		if not _ui_updating:
			set_motion_blur(on, float(settings["motion_blur_intensity"]))
	)

	_add_label(grid, "Shutter Blur Intensity")
	var mb_hbox: HBoxContainer = HBoxContainer.new()
	mb_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ctrl_mb_slider = HSlider.new()
	_ctrl_mb_slider.min_value = 0.0
	_ctrl_mb_slider.max_value = 1.0
	_ctrl_mb_slider.step = 0.05
	_ctrl_mb_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_mb_val = Label.new()
	_lbl_mb_val.custom_minimum_size = Vector2(58, 0)
	mb_hbox.add_child(_ctrl_mb_slider)
	mb_hbox.add_child(_lbl_mb_val)
	grid.add_child(mb_hbox)
	_ctrl_mb_slider.value_changed.connect(func(val: float) -> void:
		_lbl_mb_val.text = "%d%%" % roundi(val * 100.0)
		if not _ui_updating:
			set_motion_blur(bool(settings["motion_blur_enabled"]), val)
	)


func _sync_ui_from_settings() -> void:
	if _ui_panel == null:
		return
	_ui_updating = true

	_ctrl_preset.selected = clampi(int(settings["preset"]), 0, 4)
	_ctrl_res_scale.value = float(settings["resolution_scale"])
	_lbl_res_scale.text = "%d%%" % roundi(float(settings["resolution_scale"]) * 100.0)
	_ctrl_upscaler.selected = clampi(int(settings["upscaler_mode"]), 0, 2)
	_ctrl_window.selected = clampi(int(settings["window_mode"]), 0, 2)
	_ctrl_vsync.selected = clampi(int(settings["vsync_mode"]), 0, 3)

	var fps_val: int = int(settings["max_fps"])
	match fps_val:
		60: _ctrl_fps.selected = 0
		120: _ctrl_fps.selected = 1
		144: _ctrl_fps.selected = 2
		240: _ctrl_fps.selected = 3
		_: _ctrl_fps.selected = 4

	_ctrl_taa.button_pressed = bool(settings["taa_enabled"])
	_ctrl_fxaa.button_pressed = bool(settings["fxaa_enabled"])
	_ctrl_sdfgi_toggle.button_pressed = bool(settings["sdfgi_enabled"])
	_ctrl_sdfgi_quality.selected = clampi(int(settings["sdfgi_quality"]), 0, 2)
	_ctrl_ssr_toggle.button_pressed = bool(settings["ssr_enabled"])
	_ctrl_ssr_quality.selected = clampi(int(settings["ssr_quality"]), 0, 3)
	_ctrl_ssao_toggle.button_pressed = bool(settings["ssao_enabled"])
	_ctrl_ssao_quality.selected = clampi(int(settings["ssao_quality"]), 0, 3)
	_ctrl_ssil_toggle.button_pressed = bool(settings["ssil_enabled"])
	_ctrl_vol_fog_toggle.button_pressed = bool(settings["volumetric_fog_enabled"])
	_ctrl_god_rays_toggle.button_pressed = bool(settings["god_rays_temporal"])
	_ctrl_mb_toggle.button_pressed = bool(settings["motion_blur_enabled"])
	_ctrl_mb_slider.value = float(settings["motion_blur_intensity"])
	_lbl_mb_val.text = "%d%%" % roundi(float(settings["motion_blur_intensity"]) * 100.0)

	_ui_updating = false


func _add_label(parent: Control, text_str: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text_str
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(lbl)
	return lbl


func _add_dropdown_row(parent: Control, label_text: String, items: Array[String]) -> OptionButton:
	_add_label(parent, label_text)
	var opt: OptionButton = OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for item: String in items:
		opt.add_item(item)
	parent.add_child(opt)
	return opt


func _add_toggle_row(parent: Control, label_text: String) -> CheckButton:
	_add_label(parent, label_text)
	var chk: CheckButton = CheckButton.new()
	chk.text = "Enabled"
	parent.add_child(chk)
	return chk