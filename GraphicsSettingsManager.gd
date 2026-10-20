class_name GraphicsSettingsManager
extends CanvasLayer
## Production Graphics & Render-Pipeline Manager for "ShiTmoZ/RACING" (Mount Akina Touge)
## Target: Godot 4.3 (Vulkan Forward+)
## Strictly isolated to UI, DisplayServer, Viewport, and Environment rendering properties.

const CONFIG_PATH: String = "user://graphics_config.json"

# FPS Preset mappings
const FPS_VALUES: Array[int] = [60, 120, 144, 240, 0]
const FPS_LABELS: Array[String] = [
	"60 FPS",
	"120 FPS",
	"144 FPS (Native Target)",
	"240 FPS",
	"Uncapped"
]

# V-Sync Preset mappings (Plain integer matching for DisplayServer.VSyncMode)
const VSYNC_VALUES: Array[int] = [1, 3, 2, 0]
const VSYNC_LABELS: Array[String] = [
	"Enabled (Standard)",
	"Mailbox (Fast Sync)",
	"Adaptive",
	"Disabled"
]

# Shadow Distance mappings
const SHADOW_DIST_VALUES: Array[float] = [150.0, 300.0, 450.0]
const SHADOW_DIST_LABELS: Array[String] = [
	"150m (Performance)",
	"300m (Balanced)",
	"450m (Touge Ultra)"
]

# Default persistent state dictionary
var current_config: Dictionary = {
	"fps_index": 2,            # Default: 144 FPS
	"vsync_index": 1,          # Default: Mailbox
	"render_scale": 100.0,     # Default: 100%
	"fsr_sharpness": 0.2,      # Default: 0.2 (Godot FSR2 sweet spot)
	"shadow_dist_index": 1,    # Default: 300m
	"soft_shadows": true,      # Default: Soft High
	"volumetric_fog": true,    # Default: Enabled
	"fog_density": 0.015,      # Default: Akina Valley mist density
	"show_telemetry": true,    # Default: HUD Visible
	"pause_on_open": true      # Default: Pause tree when tuning
}

# UI Node References
var _menu_overlay: ColorRect
var _telemetry_panel: PanelContainer
var _telemetry_label: RichTextLabel

var _opt_fps: OptionButton
var _opt_vsync: OptionButton
var _slider_scale: HSlider
var _lbl_scale_val: Label
var _slider_fsr: HSlider
var _lbl_fsr_val: Label
var _opt_shadow_dist: OptionButton
var _chk_soft_shadows: CheckButton
var _chk_vol_fog: CheckButton
var _chk_telemetry: CheckButton
var _chk_pause: CheckButton

# Cached Scene Render Nodes
var _directional_lights: Array[DirectionalLight3D] = []
var _world_environments: Array[WorldEnvironment] = []

# Telemetry state
var _telemetry_timer: float = 0.0
const TELEMETRY_UPDATE_INTERVAL: float = 0.15
var _vp_rid: RID


func _init() -> void:
	# Ensure this CanvasLayer renders above standard game HUDs and processes during pause
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_vp_rid = get_viewport().get_viewport_rid()
	# Enable GPU/CPU frame time tracking on the active viewport for accurate telemetry
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)
	
	_build_jdm_ui()
	_cache_render_nodes()
	
	# Re-cache lighting/environment nodes automatically if scenes change dynamically
	get_tree().node_added.connect(_on_scene_node_added)
	get_tree().node_removed.connect(_on_scene_node_removed)
	
	load_settings()
	apply_all_settings()
	
	_menu_overlay.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_O or event.physical_keycode == KEY_O:
			toggle_menu()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not current_config["show_telemetry"]:
		return
		
	_telemetry_timer += delta
	if _telemetry_timer >= TELEMETRY_UPDATE_INTERVAL:
		_telemetry_timer = 0.0
		_update_telemetry_readout()


# ==============================================================================
# PUBLIC API
# ==============================================================================

func toggle_menu() -> void:
	var target_state: bool = not _menu_overlay.visible
	_menu_overlay.visible = target_state
	
	if current_config["pause_on_open"]:
		get_tree().paused = target_state
		
	if target_state:
		_cache_render_nodes()
		_opt_fps.grab_focus()


# ==============================================================================
# SCENE RENDER NODE CACHING (Strictly Visual Nodes Only)
# ==============================================================================

func _cache_render_nodes() -> void:
	_directional_lights.clear()
	_world_environments.clear()
	
	var root: Node = get_tree().root
	if not root:
		return
		
	var lights: Array[Node] = root.find_children("*", "DirectionalLight3D", true, false)
	for light in lights:
		if light is DirectionalLight3D:
			_directional_lights.append(light)
			
	var envs: Array[Node] = root.find_children("*", "WorldEnvironment", true, false)
	for env in envs:
		if env is WorldEnvironment:
			_world_environments.append(env)


func _on_scene_node_added(node: Node) -> void:
	if node is DirectionalLight3D and not _directional_lights.has(node):
		_directional_lights.append(node)
		_apply_shadow_settings()
	elif node is WorldEnvironment and not _world_environments.has(node):
		_world_environments.append(node)
		_apply_fog_settings()


func _on_scene_node_removed(node: Node) -> void:
	if node is DirectionalLight3D:
		_directional_lights.erase(node)
	elif node is WorldEnvironment:
		_world_environments.erase(node)


# ==============================================================================
# RENDER PIPELINE APPLICATION
# ==============================================================================

func apply_all_settings() -> void:
	_apply_fps_and_vsync()
	_apply_viewport_scaling()
	_apply_shadow_settings()
	_apply_fog_settings()
	_telemetry_panel.visible = current_config["show_telemetry"]


func _apply_fps_and_vsync() -> void:
	var fps_idx: int = clampi(int(current_config["fps_index"]), 0, FPS_VALUES.size() - 1)
	Engine.max_fps = FPS_VALUES[fps_idx]
	
	var vsync_idx: int = clampi(int(current_config["vsync_index"]), 0, VSYNC_VALUES.size() - 1)
	var mode_int: int = VSYNC_VALUES[vsync_idx]
	
	# Explicit plain integer match to cast cleanly to DisplayServer.VSyncMode
	match mode_int:
		0:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		1:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
		2:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ADAPTIVE)
		3:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_MAILBOX)
		_:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)


func _apply_viewport_scaling() -> void:
	var vp: Viewport = get_viewport()
	if not vp:
		return
		
	var scale_pct: float = clampf(float(current_config["render_scale"]), 50.0, 100.0)
	var normalized_scale: float = scale_pct / 100.0
	var sharpness: float = clampf(float(current_config["fsr_sharpness"]), 0.0, 1.0)
	
	# Use FSR 2.2 when sub-native scaling is active; switch to Bilinear at 100% native
	# Note: In Godot 4.3 FSR, lower attenuation values (0.0) yield maximum sharpness,
	# so we invert the user-facing 0.0-1.0 sharpness slider mapped to the 0.0-2.0 engine range.
	if normalized_scale < 0.99:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	else:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		
	vp.scaling_3d_scale = normalized_scale
	vp.fsr_sharpness = (1.0 - sharpness) * 2.0


func _apply_shadow_settings() -> void:
	var dist_idx: int = clampi(int(current_config["shadow_dist_index"]), 0, SHADOW_DIST_VALUES.size() - 1)
	var max_dist: float = SHADOW_DIST_VALUES[dist_idx]
	var use_soft: bool = bool(current_config["soft_shadows"])
	
	# Adjust global directional shadow filter quality on RenderingServer
	if use_soft:
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
	else:
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_HARD)
		
	for light in _directional_lights:
		if is_instance_valid(light):
			light.directional_shadow_max_distance = max_dist
			if use_soft:
				light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
				light.directional_shadow_blend_splits = true
			else:
				light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
				light.directional_shadow_blend_splits = false


func _apply_fog_settings() -> void:
	var fog_enabled: bool = bool(current_config["volumetric_fog"])
	var density: float = float(current_config["fog_density"])
	
	for we in _world_environments:
		if is_instance_valid(we) and we.environment != null:
			we.environment.volumetric_fog_enabled = fog_enabled
			if fog_enabled:
				we.environment.volumetric_fog_density = density


# ==============================================================================
# TELEMETRY ENGINE
# ==============================================================================

func _update_telemetry_readout() -> void:
	var fps: float = Engine.get_frames_per_second()
	var cap: int = Engine.max_fps
	var cap_str: String = "UNCAPPED" if cap == 0 else str(cap) + " FPS"
	
	# Measure accurate Vulkan Forward+ CPU and GPU frame timings via RenderingServer
	var cpu_time: float = RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid)
	var gpu_time: float = RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)
	
	# Fallback to standard frame process delta if driver does not report viewport render time
	if cpu_time <= 0.001:
		cpu_time = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		
	var draw_calls: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var vram_bytes: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	var vram_mb: float = vram_bytes / (1024.0 * 1024.0)
	
	var fps_color: String = "#00ff88"
	if fps < 55.0:
		fps_color = "#ff3344"
	elif fps < 100.0:
		fps_color = "#ffcc00"
		
	var text: String = ""
	text += "[b][color=#ff9900]AKINA TELEMETRY // VULKAN FWD+[/color][/b]\n"
	text += "[color=#888899]--------------------------------[/color]\n"
	text += "FPS      : [b][color=%s]%d[/color][/b] [color=#888899]/ %s[/color]\n" % [fps_color, roundi(fps), cap_str]
	text += "CPU TIME : [b][color=#eaeaea]%.2f ms[/color][/b]\n" % cpu_time
	text += "GPU TIME : [b][color=#eaeaea]%.2f ms[/color][/b]\n" % gpu_time
	text += "DRAWS    : [b][color=#00e5ff]%d[/color][/b] calls/f\n" % draw_calls
	text += "VRAM     : [b][color=#ffaa00]%.1f MB[/color][/b]" % vram_mb
	
	_telemetry_label.text = text


# ==============================================================================
# PERSISTENCE (JSON SERIALIZATION)
# ==============================================================================

func save_settings() -> void:
	var file: FileAccess = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[GraphicsSettingsManager] Failed to open config for writing: " + CONFIG_PATH)
		return
	var json_str: String = JSON.stringify(current_config, "\t")
	file.store_string(json_str)
	file.close()


func load_settings() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		_sync_ui_from_config()
		save_settings()
		return
		
	var file: FileAccess = FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if file == null:
		_sync_ui_from_config()
		return
		
	var content: String = file.get_as_text()
	file.close()
	
	var json: JSON = JSON.new()
	var err: Error = json.parse(content)
	if err == OK and typeof(json.data) == TYPE_DICTIONARY:
		var loaded: Dictionary = json.data
		for key in current_config.keys():
			if loaded.has(key):
				current_config[key] = loaded[key]
				
	_sync_ui_from_config()


func _sync_ui_from_config() -> void:
	_opt_fps.selected = clampi(int(current_config["fps_index"]), 0, FPS_VALUES.size() - 1)
	_opt_vsync.selected = clampi(int(current_config["vsync_index"]), 0, VSYNC_VALUES.size() - 1)
	
	_slider_scale.set_value_no_signal(float(current_config["render_scale"]))
	_lbl_scale_val.text = "%d%%" % roundi(float(current_config["render_scale"]))
	
	_slider_fsr.set_value_no_signal(float(current_config["fsr_sharpness"]))
	_lbl_fsr_val.text = "%.2f" % float(current_config["fsr_sharpness"])
	
	_opt_shadow_dist.selected = clampi(int(current_config["shadow_dist_index"]), 0, SHADOW_DIST_VALUES.size() - 1)
	_chk_soft_shadows.set_pressed_no_signal(bool(current_config["soft_shadows"]))
	_chk_vol_fog.set_pressed_no_signal(bool(current_config["volumetric_fog"]))
	_chk_telemetry.set_pressed_no_signal(bool(current_config["show_telemetry"]))
	_chk_pause.set_pressed_no_signal(bool(current_config["pause_on_open"]))


# ==============================================================================
# UI SIGNAL CALLBACKS
# ==============================================================================

func _on_fps_selected(index: int) -> void:
	current_config["fps_index"] = index
	_apply_fps_and_vsync()
	save_settings()


func _on_vsync_selected(index: int) -> void:
	current_config["vsync_index"] = index
	_apply_fps_and_vsync()
	save_settings()


func _on_scale_changed(value: float) -> void:
	current_config["render_scale"] = value
	_lbl_scale_val.text = "%d%%" % roundi(value)
	_apply_viewport_scaling()
	save_settings()


func _on_fsr_changed(value: float) -> void:
	current_config["fsr_sharpness"] = value
	_lbl_fsr_val.text = "%.2f" % value
	_apply_viewport_scaling()
	save_settings()


func _on_shadow_dist_selected(index: int) -> void:
	current_config["shadow_dist_index"] = index
	_apply_shadow_settings()
	save_settings()


func _on_soft_shadows_toggled(toggled_on: bool) -> void:
	current_config["soft_shadows"] = toggled_on
	_apply_shadow_settings()
	save_settings()


func _on_vol_fog_toggled(toggled_on: bool) -> void:
	current_config["volumetric_fog"] = toggled_on
	_apply_fog_settings()
	save_settings()


func _on_telemetry_toggled(toggled_on: bool) -> void:
	current_config["show_telemetry"] = toggled_on
	_telemetry_panel.visible = toggled_on
	save_settings()


func _on_pause_toggled(toggled_on: bool) -> void:
	current_config["pause_on_open"] = toggled_on
	if _menu_overlay.visible:
		get_tree().paused = toggled_on
	save_settings()


func _on_reset_defaults_pressed() -> void:
	current_config = {
		"fps_index": 2,
		"vsync_index": 1,
		"render_scale": 100.0,
		"fsr_sharpness": 0.2,
		"shadow_dist_index": 1,
		"soft_shadows": true,
		"volumetric_fog": true,
		"fog_density": 0.015,
		"show_telemetry": true,
		"pause_on_open": true
	}
	_sync_ui_from_config()
	apply_all_settings()
	save_settings()


# ==============================================================================
# PROCEDURAL JDM DARK CARBON UI BUILDER
# ==============================================================================

func _build_jdm_ui() -> void:
	# 1. Telemetry HUD (Top-Left Corner)
	_telemetry_panel = PanelContainer.new()
	_telemetry_panel.name = "TelemetryHUD"
	_telemetry_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_telemetry_panel.position = Vector2(20, 20)
	
	var hud_style: StyleBoxFlat = StyleBoxFlat.new()
	hud_style.bg_color = Color(0.05, 0.05, 0.07, 0.82)
	hud_style.border_color = Color(1.0, 0.55, 0.0, 0.85)
	hud_style.border_width_left = 4
	hud_style.border_width_top = 1
	hud_style.border_width_right = 1
	hud_style.border_width_bottom = 1
	hud_style.corner_radius_bottom_right = 6
	hud_style.content_margin_left = 14
	hud_style.content_margin_right = 16
	hud_style.content_margin_top = 10
	hud_style.content_margin_bottom = 10
	_telemetry_panel.add_theme_stylebox_override("panel", hud_style)
	
	_telemetry_label = RichTextLabel.new()
	_telemetry_label.bbcode_enabled = true
	_telemetry_label.fit_content = true
	_telemetry_label.scroll_active = false
	_telemetry_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_telemetry_label.custom_minimum_size = Vector2(250, 105)
	_telemetry_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_telemetry_label.add_theme_font_size_override("normal_font_size", 13)
	_telemetry_label.add_theme_font_size_override("bold_font_size", 13)
	_telemetry_panel.add_child(_telemetry_label)
	add_child(_telemetry_panel)
	
	# 2. Fullscreen Dimming Backdrop
	_menu_overlay = ColorRect.new()
	_menu_overlay.name = "JDMMenuOverlay"
	_menu_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_overlay.color = Color(0.02, 0.02, 0.03, 0.76)
	add_child(_menu_overlay)
	
	var center_container: CenterContainer = CenterContainer.new()
	center_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_overlay.add_child(center_container)
	
	# 3. Main Carbon Tuning Chassis Panel
	var main_panel: PanelContainer = PanelContainer.new()
	main_panel.custom_minimum_size = Vector2(680, 520)
	
	var chassis_style: StyleBoxFlat = StyleBoxFlat.new()
	chassis_style.bg_color = Color(0.08, 0.08, 0.10, 0.96)
	chassis_style.border_color = Color(1.0, 0.55, 0.0, 1.0) # 90s Amber Accent
	chassis_style.border_width_left = 6
	chassis_style.border_width_top = 2
	chassis_style.border_width_right = 2
	chassis_style.border_width_bottom = 2
	chassis_style.corner_radius_top_right = 8
	chassis_style.corner_radius_bottom_left = 8
	chassis_style.shadow_color = Color(0.0, 0.0, 0.0, 0.7)
	chassis_style.shadow_size = 18
	chassis_style.content_margin_left = 28
	chassis_style.content_margin_right = 28
	chassis_style.content_margin_top = 24
	chassis_style.content_margin_bottom = 24
	main_panel.add_theme_stylebox_override("panel", chassis_style)
	center_container.add_child(main_panel)
	
	var root_vbox: VBoxContainer = VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 14)
	main_panel.add_child(root_vbox)
	
	# 4. Header Block (Gran Turismo / Touge Spec Styling)
	var header_hbox: HBoxContainer = HBoxContainer.new()
	root_vbox.add_child(header_hbox)
	
	var title_vbox: VBoxContainer = VBoxContainer.new()
	title_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(title_vbox)
	
	var lbl_title: Label = Label.new()
	lbl_title.text = "AKINA TOUGE // RENDERING SPEC-R"
	lbl_title.add_theme_font_size_override("font_size", 22)
	lbl_title.add_theme_color_override("font_color", Color(1.0, 0.6, 0.0))
	title_vbox.add_child(lbl_title)
	
	var lbl_subtitle: Label = Label.new()
	lbl_subtitle.text = "PROJECT: ShiTmoZ/RACING  |  ENGINE: GODOT 4.3 VULKAN FORWARD+"
	lbl_subtitle.add_theme_font_size_override("font_size", 11)
	lbl_subtitle.add_theme_color_override("font_color", Color(0.55, 0.58, 0.65))
	title_vbox.add_child(lbl_subtitle)
	
	var lbl_hotkey: Label = Label.new()
	lbl_hotkey.text = "[O] TOGGLE MENU"
	lbl_hotkey.add_theme_font_size_override("font_size", 12)
	lbl_hotkey.add_theme_color_override("font_color", Color(0.0, 0.9, 1.0))
	header_hbox.add_child(lbl_hotkey)
	
	var sep_top: HSeparator = HSeparator.new()
	sep_top.add_theme_constant_override("separation", 8)
	root_vbox.add_child(sep_top)
	
	# 5. Settings Rows
	_build_section_label(root_vbox, "SYNCHRONIZATION & FRAME TIMING")
	
	_opt_fps = _create_dropdown(FPS_LABELS, _on_fps_selected)
	_add_setting_row(root_vbox, "TARGET FPS LIMITER", "Hard clamp via Engine.max_fps", _opt_fps)
	
	_opt_vsync = _create_dropdown(VSYNC_LABELS, _on_vsync_selected)
	_add_setting_row(root_vbox, "V-SYNC PROTOCOL", "DisplayServer frame pacing mode", _opt_vsync)
	
	_build_section_label(root_vbox, "VIEWPORT SCALING & LIGHTING PIPELINE")
	
	# 3D Scale Slider (50% to 100%, step 5%)
	var scale_hbox: HBoxContainer = HBoxContainer.new()
	scale_hbox.custom_minimum_size = Vector2(260, 0)
	scale_hbox.add_theme_constant_override("separation", 10)
	_slider_scale = HSlider.new()
	_slider_scale.min_value = 50.0
	_slider_scale.max_value = 100.0
	_slider_scale.step = 5.0
	_slider_scale.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_scale.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider_scale.value_changed.connect(_on_scale_changed)
	_lbl_scale_val = Label.new()
	_lbl_scale_val.custom_minimum_size = Vector2(48, 0)
	_lbl_scale_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_lbl_scale_val.add_theme_color_override("font_color", Color(0.0, 0.9, 1.0))
	scale_hbox.add_child(_slider_scale)
	scale_hbox.add_child(_lbl_scale_val)
	_add_setting_row(root_vbox, "3D RESOLUTION SCALE", "Dynamic viewport scaling (50% - 100%)", scale_hbox)
	
	# FSR Sharpness Slider (0.0 to 1.0)
	var fsr_hbox: HBoxContainer = HBoxContainer.new()
	fsr_hbox.custom_minimum_size = Vector2(260, 0)
	fsr_hbox.add_theme_constant_override("separation", 10)
	_slider_fsr = HSlider.new()
	_slider_fsr.min_value = 0.0
	_slider_fsr.max_value = 1.0
	_slider_fsr.step = 0.05
	_slider_fsr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_fsr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider_fsr.value_changed.connect(_on_fsr_changed)
	_lbl_fsr_val = Label.new()
	_lbl_fsr_val.custom_minimum_size = Vector2(48, 0)
	_lbl_fsr_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_lbl_fsr_val.add_theme_color_override("font_color", Color(0.0, 0.9, 1.0))
	fsr_hbox.add_child(_slider_fsr)
	fsr_hbox.add_child(_lbl_fsr_val)
	_add_setting_row(root_vbox, "FSR 2.2 SHARPNESS", "Spatial upscaling edge reconstruction", fsr_hbox)
	
	# Shadow Distance
	_opt_shadow_dist = _create_dropdown(SHADOW_DIST_LABELS, _on_shadow_dist_selected)
	_add_setting_row(root_vbox, "CASCADE SHADOW RANGE", "DirectionalLight3D max draw distance", _opt_shadow_dist)
	
	# Soft Shadows Toggle
	_chk_soft_shadows = CheckButton.new()
	_chk_soft_shadows.text = "PCF 4-Split Soft Filtering"
	_chk_soft_shadows.toggled.connect(_on_soft_shadows_toggled)
	_add_setting_row(root_vbox, "SOFT SHADOW FILTER", "High-grade penumbra blending", _chk_soft_shadows)
	
	# Volumetric Fog Toggle
	_chk_vol_fog = CheckButton.new()
	_chk_vol_fog.text = "Akina Valley Mist"
	_chk_vol_fog.toggled.connect(_on_vol_fog_toggled)
	_add_setting_row(root_vbox, "VOLUMETRIC FOG", " Mountain pass atmospheric scattering", _chk_vol_fog)
	
	_build_section_label(root_vbox, "TELEMETRY & DIAGNOSTICS")
	
	# Telemetry Overlay Toggle
	_chk_telemetry = CheckButton.new()
	_chk_telemetry.text = "Show Real-Time HUD"
	_chk_telemetry.toggled.connect(_on_telemetry_toggled)
	_add_setting_row(root_vbox, "HARDWARE TELEMETRY", "FPS, CPU/GPU ms, Draw Calls & VRAM", _chk_telemetry)
	
	# Pause Integration Toggle
	_chk_pause = CheckButton.new()
	_chk_pause.text = "Suspend Scene Tree"
	_chk_pause.toggled.connect(_on_pause_toggled)
	_add_setting_row(root_vbox, "PAUSE ON TUNING", "Halt game loop while overlay is active", _chk_pause)
	
	var sep_bot: HSeparator = HSeparator.new()
	sep_bot.add_theme_constant_override("separation", 8)
	root_vbox.add_child(sep_bot)
	
	# 6. Footer Action Buttons
	var footer_hbox: HBoxContainer = HBoxContainer.new()
	footer_hbox.alignment = BoxContainer.ALIGNMENT_END
	footer_hbox.add_theme_constant_override("separation", 16)
	root_vbox.add_child(footer_hbox)
	
	var btn_reset: Button = _create_jdm_button("RESTORE DEFAULTS", Color(0.75, 0.25, 0.25))
	btn_reset.pressed.connect(_on_reset_defaults_pressed)
	footer_hbox.add_child(btn_reset)
	
	var btn_close: Button = _create_jdm_button("APPLY & RESUME [O]", Color(1.0, 0.55, 0.0))
	btn_close.pressed.connect(toggle_menu)
	footer_hbox.add_child(btn_close)


func _build_section_label(parent: VBoxContainer, title: String) -> void:
	var lbl: Label = Label.new()
	lbl.text = ":: " + title
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.65, 0.15))
	parent.add_child(lbl)


func _add_setting_row(parent: VBoxContainer, title: String, subtitle: String, control: Control) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 32)
	
	var text_vbox: VBoxContainer = VBoxContainer.new()
	text_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	
	var lbl_main: Label = Label.new()
	lbl_main.text = title
	lbl_main.add_theme_font_size_override("font_size", 14)
	lbl_main.add_theme_color_override("font_color", Color(0.92, 0.92, 0.95))
	text_vbox.add_child(lbl_main)
	
	var lbl_sub: Label = Label.new()
	lbl_sub.text = subtitle
	lbl_sub.add_theme_font_size_override("font_size", 11)
	lbl_sub.add_theme_color_override("font_color", Color(0.5, 0.53, 0.6))
	text_vbox.add_child(lbl_sub)
	
	row.add_child(text_vbox)
	
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(control)
	parent.add_child(row)


func _create_dropdown(items: Array[String], callback: Callable) -> OptionButton:
	var opt: OptionButton = OptionButton.new()
	opt.custom_minimum_size = Vector2(260, 30)
	for i in range(items.size()):
		opt.add_item(items[i], i)
	opt.item_selected.connect(callback)
	return opt


func _create_jdm_button(text_label: String, border_accent: Color) -> Button:
	var btn: Button = Button.new()
	btn.text = text_label
	btn.custom_minimum_size = Vector2(180, 36)
	
	var style_normal: StyleBoxFlat = StyleBoxFlat.new()
	style_normal.bg_color = Color(0.14, 0.14, 0.18, 1.0)
	style_normal.border_color = border_accent
	style_normal.border_width_left = 3
	style_normal.border_width_bottom = 2
	style_normal.content_margin_left = 14
	style_normal.content_margin_right = 14
	
	var style_hover: StyleBoxFlat = style_normal.duplicate()
	style_hover.bg_color = Color(0.22, 0.22, 0.28, 1.0)
	
	btn.add_theme_stylebox_override("normal", style_normal)
	btn.add_theme_stylebox_override("hover", style_hover)
	btn.add_theme_stylebox_override("pressed", style_hover)
	btn.add_theme_font_size_override("font_size", 13)
	return btn