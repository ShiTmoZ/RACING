class_name AkinaDynamicAtmosphere
extends Node3D

## ============================================================================
## SHI-TMOZ / RACING — AKINA DYNAMIC ATMOSPHERE & WEATHER ENGINE
## Target: Godot 4.3 Forward+ (Vulkan / D3D12)
## Architecture: 100% Procedural, Zero External Dependencies, Headless-Safe
## ============================================================================

signal preset_changed(preset_index: int, preset_name: String, friction_mult: float)
signal blind_attack_toggled(active: bool)
signal volumetric_fog_toggled(enabled: bool)

enum WeatherPreset {
	GOLDEN_HOUR_SUNSET = 0,
	MIDNIGHT_TOUGE = 1,
	DENSE_MOUNTAIN_FOG = 2,
	RAINY_TOUGE_WET = 3
}

# --- Exported Configuration ---
@export_group("Atmospheric State")
@export var initial_preset: WeatherPreset = WeatherPreset.MIDNIGHT_TOUGE
@export var transition_duration: float = 2.5
@export var enable_volumetric_fog: bool = true
@export var enable_streetlamps: bool = true

# --- Public Physics Interface (Queried by TougeDriftPhysicsSolver) ---
var surface_friction_mult: float = 1.0
var is_blind_attack_active: bool = false
var current_preset: WeatherPreset = WeatherPreset.MIDNIGHT_TOUGE

# --- Scene & Environment References ---
var _world_env: WorldEnvironment = null
var _env: Environment = null
var _sky_mat: ShaderMaterial = null
var _sun_light: DirectionalLight3D = null
var _player_vehicle: Node3D = null
var _physics_solver: Node = null
var _referee_system: Node = null

# --- Procedural Weather & Roadside Nodes ---
var _rain_particles: CPUParticles3D = null
var _tire_spray_left: CPUParticles3D = null
var _tire_spray_right: CPUParticles3D = null
var _headlight_left: SpotLight3D = null
var _headlight_right: SpotLight3D = null
var _headlight_mesh_left: MeshInstance3D = null
var _headlight_mesh_right: MeshInstance3D = null
var _streetlamp_root: Node3D = null
var _streetlamps: Array[OmniLight3D] = []
var _vending_machines: Array[MeshInstance3D] = []
var _road_materials: Array[Material] = []

# --- UI Overlay & Manga Callouts ---
var _ui_layer: CanvasLayer = null
var _hud_drawer: Control = null
var _toast_timer: float = 0.0
var _toast_title: String = ""
var _toast_subtitle: String = ""
var _blind_attack_banner_timer: float = 0.0
var _blind_attack_flash: float = 0.0
var _speed_lines_phase: float = 0.0

# --- Interpolation State Dictionary ---
var _is_headless: bool = false
var _lerp_progress: float = 1.0
var _current_state: Dictionary = {}
var _source_state: Dictionary = {}
var _target_state: Dictionary = {}

# --- Preset Definition Table ---
const PRESET_DATA: Dictionary = {
	WeatherPreset.GOLDEN_HOUR_SUNSET: {
		"name": "GOLDEN HOUR SUNSET",
		"toast": "[N] WEATHER: GOLDEN HOUR SUNSET (DRY TARMAC 100% GRIP)",
		"sky_top": Color(0.16, 0.10, 0.28),
		"sky_horizon": Color(1.0, 0.48, 0.20),
		"ground_bottom": Color(0.08, 0.05, 0.06),
		"sun_elevation": 12.0,
		"sun_azimuth": -35.0,
		"sun_color": Color(1.0, 0.68, 0.35),
		"sun_energy": 2.8,
		"ambient_color": Color(1.0, 0.72, 0.45),
		"ambient_energy": 0.65,
		"ambient_sky_contrib": 0.75,
		"fog_enabled": true,
		"fog_density": 0.0085,
		"fog_albedo": Color(1.0, 0.65, 0.42),
		"fog_emission": Color(0.28, 0.14, 0.06),
		"fog_anisotropy": 0.68,
		"ssr_enabled": false,
		"road_roughness": 0.68,
		"road_specular": 0.38,
		"star_intensity": 0.0,
		"streetlamp_energy": 0.0,
		"headlight_energy": 0.0,
		"rain_amount_ratio": 0.0,
		"friction_mult": 1.0,
		"tonemap_exposure": 1.05,
		"glow_intensity": 0.85
	},
	WeatherPreset.MIDNIGHT_TOUGE: {
		"name": "MIDNIGHT TOUGE",
		"toast": "[N] WEATHER: MIDNIGHT TOUGE (PROJECT D NIGHT)",
		"sky_top": Color(0.01, 0.015, 0.035),
		"sky_horizon": Color(0.025, 0.035, 0.07),
		"ground_bottom": Color(0.005, 0.008, 0.015),
		"sun_elevation": 42.0,
		"sun_azimuth": 115.0,
		"sun_color": Color(0.65, 0.78, 1.0),
		"sun_energy": 0.22,
		"ambient_color": Color(0.04, 0.05, 0.09),
		"ambient_energy": 0.18,
		"ambient_sky_contrib": 0.30,
		"fog_enabled": true,
		"fog_density": 0.011,
		"fog_albedo": Color(0.12, 0.16, 0.26),
		"fog_emission": Color(0.01, 0.015, 0.03),
		"fog_anisotropy": 0.55,
		"ssr_enabled": false,
		"road_roughness": 0.64,
		"road_specular": 0.42,
		"star_intensity": 1.0,
		"streetlamp_energy": 3.4,
		"headlight_energy": 6.8,
		"rain_amount_ratio": 0.0,
		"friction_mult": 1.0,
		"tonemap_exposure": 1.12,
		"glow_intensity": 1.15
	},
	WeatherPreset.DENSE_MOUNTAIN_FOG: {
		"name": "DENSE MOUNTAIN FOG",
		"toast": "[N] WEATHER: DENSE MOUNTAIN FOG (LOW VISIBILITY 35M)",
		"sky_top": Color(0.06, 0.08, 0.12),
		"sky_horizon": Color(0.14, 0.18, 0.24),
		"ground_bottom": Color(0.04, 0.05, 0.08),
		"sun_elevation": 26.0,
		"sun_azimuth": 60.0,
		"sun_color": Color(0.62, 0.72, 0.85),
		"sun_energy": 0.35,
		"ambient_color": Color(0.18, 0.22, 0.28),
		"ambient_energy": 0.32,
		"ambient_sky_contrib": 0.45,
		"fog_enabled": true,
		"fog_density": 0.048,
		"fog_albedo": Color(0.72, 0.78, 0.85),
		"fog_emission": Color(0.08, 0.10, 0.14),
		"fog_anisotropy": 0.76,
		"ssr_enabled": false,
		"road_roughness": 0.45,
		"road_specular": 0.52,
		"star_intensity": 0.0,
		"streetlamp_energy": 4.2,
		"headlight_energy": 8.2,
		"rain_amount_ratio": 0.0,
		"friction_mult": 0.94,
		"tonemap_exposure": 1.0,
		"glow_intensity": 1.25
	},
	WeatherPreset.RAINY_TOUGE_WET: {
		"name": "RAINY TOUGE / WET ASPHALT",
		"toast": "[N] WEATHER: RAINY TOUGE (WET ASPHALT -22% GRIP)",
		"sky_top": Color(0.02, 0.03, 0.05),
		"sky_horizon": Color(0.05, 0.07, 0.11),
		"ground_bottom": Color(0.01, 0.015, 0.025),
		"sun_elevation": 35.0,
		"sun_azimuth": 95.0,
		"sun_color": Color(0.50, 0.64, 0.82),
		"sun_energy": 0.28,
		"ambient_color": Color(0.06, 0.08, 0.13),
		"ambient_energy": 0.25,
		"ambient_sky_contrib": 0.40,
		"fog_enabled": true,
		"fog_density": 0.024,
		"fog_albedo": Color(0.28, 0.35, 0.45),
		"fog_emission": Color(0.03, 0.04, 0.07),
		"fog_anisotropy": 0.62,
		"ssr_enabled": true,
		"road_roughness": 0.12,
		"road_specular": 0.85,
		"star_intensity": 0.0,
		"streetlamp_energy": 3.8,
		"headlight_energy": 7.4,
		"rain_amount_ratio": 1.0,
		"friction_mult": 0.78,
		"tonemap_exposure": 1.08,
		"glow_intensity": 1.35
	}
}


## ============================================================================
## LIFECYCLE & INITIALIZATION
## ============================================================================

func _ready() -> void:
	_is_headless = DisplayServer.get_name() == "headless"
	set_process(true)
	set_process_unhandled_key_input(true)

	_discover_or_create_environment()
	_discover_or_create_directional_light()
	_discover_scene_entities()
	_setup_roadside_props()
	_setup_weather_particles()
	_setup_vehicle_headlights_and_spray()
	_setup_arcade_ui()

	# Initialize state immediately to the starting preset
	current_preset = initial_preset
	_current_state = PRESET_DATA[current_preset].duplicate(true)
	_source_state = _current_state.duplicate(true)
	_target_state = _current_state.duplicate(true)
	_lerp_progress = 1.0

	_apply_interpolated_state(1.0)
	_sync_physics_friction()
	_show_toast(_current_state["toast"], "INITIAL D STAGE ATMOSPHERE ENGINE READY")


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	var key_event: InputEventKey = event as InputEventKey
	match key_event.keycode:
		KEY_N:
			cycle_weather_preset()
		KEY_L:
			toggle_blind_attack()
		KEY_F5:
			toggle_volumetric_fog()


func _process(delta: float) -> void:
	# Re-attempt vehicle & solver discovery if spawned dynamically after _ready
	if not is_instance_valid(_player_vehicle) or not is_instance_valid(_physics_solver):
		_discover_scene_entities()

	# Smooth preset interpolation
	if _lerp_progress < 1.0:
		_lerp_progress = minf(1.0, _lerp_progress + (delta / maxf(0.05, transition_duration)))
		var smooth_t: float = smoothstep(0.0, 1.0, _lerp_progress)
		_apply_interpolated_state(smooth_t)

	# Update dynamic particle attachment & vehicle effects
	_update_vehicle_attachments(delta)

	# UI Timers
	if _toast_timer > 0.0:
		_toast_timer = maxf(0.0, _toast_timer - delta)
		if is_instance_valid(_hud_drawer):
			_hud_drawer.queue_redraw()

	if _blind_attack_banner_timer > 0.0:
		_blind_attack_banner_timer = maxf(0.0, _blind_attack_banner_timer - delta)
		if is_instance_valid(_hud_drawer):
			_hud_drawer.queue_redraw()

	if _blind_attack_flash > 0.0:
		_blind_attack_flash = maxf(0.0, _blind_attack_flash - delta * 2.5)
		if is_instance_valid(_hud_drawer):
			_hud_drawer.queue_redraw()

	if is_blind_attack_active and is_instance_valid(_hud_drawer):
		_speed_lines_phase += delta * 18.0
		_hud_drawer.queue_redraw()


## ============================================================================
## PUBLIC API & CONTROLS
## ============================================================================

func cycle_weather_preset() -> void:
	var next_index: int = (int(current_preset) + 1) % PRESET_DATA.size()
	set_weather_preset(next_index as WeatherPreset)


func set_weather_preset(preset: WeatherPreset) -> void:
	if is_blind_attack_active and preset != WeatherPreset.MIDNIGHT_TOUGE:
		_set_blind_attack_internal(false, false)

	current_preset = preset
	_source_state = _current_state.duplicate(true)
	_target_state = PRESET_DATA[preset].duplicate(true)
	_lerp_progress = 0.0

	surface_friction_mult = _target_state["friction_mult"]
	_sync_physics_friction()

	var subtitle: String = "SURFACE GRIP: %d%% | VOLUMETRIC FOG: %s" % [
		int(round(surface_friction_mult * 100.0)),
		"ON" if enable_volumetric_fog else "OFF"
	]
	_show_toast(_target_state["toast"], subtitle)
	preset_changed.emit(int(preset), _target_state["name"], surface_friction_mult)


func toggle_blind_attack() -> void:
	if current_preset != WeatherPreset.MIDNIGHT_TOUGE:
		_show_toast(
			"[L] BLIND ATTACK REQUIRES MIDNIGHT TOUGE!",
			"PRESS [N] TO SELECT PROJECT D NIGHT BATTLE FIRST"
		)
		return

	_set_blind_attack_internal(not is_blind_attack_active, true)


func toggle_volumetric_fog() -> void:
	enable_volumetric_fog = not enable_volumetric_fog
	if is_instance_valid(_env) and not _is_headless:
		_env.volumetric_fog_enabled = enable_volumetric_fog and _current_state.get("fog_enabled", true)

	var status_str: String = "ENABLED (HIGH QUALITY)" if enable_volumetric_fog else "DISABLED (PERFORMANCE MODE)"
	_show_toast("[F5] VOLUMETRIC FOG: " + status_str, "ADAPTIVE AKINA FOG RENDERING")
	volumetric_fog_toggled.emit(enable_volumetric_fog)


func get_surface_friction_multiplier() -> float:
	return surface_friction_mult


## ============================================================================
## BLIND ATTACK IMPLEMENTATION (TAKUMI FUJIWARA STEALTH MODE)
## ============================================================================

func _set_blind_attack_internal(active: bool, show_notification: bool) -> void:
	is_blind_attack_active = active
	_blind_attack_flash = 1.0 if active else 0.4

	if active:
		_blind_attack_banner_timer = 4.2
		if show_notification:
			_show_toast(
				"[L] BLIND ATTACK ENGAGED! (HEADLIGHTS EXTINGUISHED)",
				"消える…！？ ブラインド・アタック！ (STEALTH OVERPASS)"
			)
	else:
		_blind_attack_banner_timer = 0.0
		if show_notification:
			_show_toast(
				"[L] HEADLIGHTS RESTORED (POP-UP HALOGENS ON)",
				"STANDARD NIGHT BATTLE ILLUMINATION"
			)

	_update_headlight_state()
	_apply_blind_attack_grading()
	blind_attack_toggled.emit(is_blind_attack_active)


func _apply_blind_attack_grading() -> void:
	if not is_instance_valid(_env) or _is_headless:
		return

	if is_blind_attack_active:
		# Subtle blue night-vision / moonlit silhouette enhancement so road edge remains visible
		_env.adjustment_enabled = true
		_env.adjustment_contrast = 1.28
		_env.adjustment_brightness = 1.14
		_env.adjustment_saturation = 0.65
		_env.ambient_light_color = Color(0.08, 0.14, 0.28)
		_env.ambient_light_energy = 0.34
	else:
		_env.adjustment_enabled = true
		_env.adjustment_contrast = 1.06
		_env.adjustment_brightness = 1.0
		_env.adjustment_saturation = 1.05
		_env.ambient_light_color = _current_state.get("ambient_color", Color(0.04, 0.05, 0.09))
		_env.ambient_light_energy = _current_state.get("ambient_energy", 0.18)


## ============================================================================
## ENVIRONMENT & SKY SHADER SETUP
## ============================================================================

func _discover_or_create_environment() -> void:
	var root: Node = get_tree().current_scene if get_tree() else get_parent()
	if not is_instance_valid(root):
		root = self

	# Search existing WorldEnvironment without overwriting user nodes
	_world_env = _find_node_of_type(root, "WorldEnvironment") as WorldEnvironment
	if not is_instance_valid(_world_env):
		_world_env = WorldEnvironment.new()
		_world_env.name = "AkinaWorldEnvironment"
		add_child(_world_env)

	if is_instance_valid(_world_env.environment):
		_env = _world_env.environment
	else:
		_env = Environment.new()
		_world_env.environment = _env

	# Build Procedural Celestial & Physical Sky Shader (Supports Sunset, Stars, Moon & Fog)
	var sky_shader := Shader.new()
	sky_shader.code = """
shader_type sky;

uniform vec3 sky_top_color : source_color = vec3(0.015, 0.02, 0.04);
uniform vec3 sky_horizon_color : source_color = vec3(0.04, 0.05, 0.09);
uniform vec3 ground_bottom_color : source_color = vec3(0.01, 0.01, 0.02);
uniform float star_intensity : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sun_tint : source_color = vec3(1.0, 0.7, 0.4);

float hash31(vec3 p) {
	p = fract(p * vec3(443.897, 441.423, 437.195));
	p += dot(p, p.yzx + 19.19);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	float y = EYEDIR.y;
	float horizon_blend = pow(clamp(1.0 - abs(y), 0.0, 1.0), 3.2);
	vec3 col = mix(sky_top_color, sky_horizon_color, horizon_blend);

	if (y < 0.0) {
		col = mix(sky_horizon_color, ground_bottom_color, clamp(-y * 3.5, 0.0, 1.0));
	}

	// Solar / Lunar Disk & Mie Scattering Glow
	if (LIGHT0_ENABLED) {
		float sun_dot = max(dot(EYEDIR, LIGHT0_DIRECTION), 0.0);
		float mie_halo = pow(sun_dot, 8.0) * 0.45 + pow(sun_dot, 64.0) * 0.85;
		float sun_disk = smoothstep(0.9985, 0.9996, sun_dot) * 3.5;
		col += LIGHT0_COLOR * (mie_halo + sun_disk) * clamp(LIGHT0_ENERGY * 0.5, 0.15, 2.5);
	}

	// Procedural Starfield for Midnight Touge
	if (star_intensity > 0.01 && y > 0.02) {
		vec3 star_cell = floor(EYEDIR * 260.0);
		float h = hash31(star_cell);
		if (h > 0.9945) {
			float twinkle = 0.65 + 0.35 * sin(TIME * 3.5 + h * 100.0);
			float star_bright = pow((h - 0.9945) / 0.0055, 2.0) * twinkle;
			col += vec3(0.82, 0.90, 1.0) * star_bright * star_intensity * smoothstep(0.02, 0.25, y);
		}
	}

	// Distant Mt. Akina Silhouette Ridge along the horizon
	float angle = atan(EYEDIR.x, EYEDIR.z);
	float ridge1 = sin(angle * 5.0) * 0.025 + sin(angle * 13.0 + 1.2) * 0.012 + 0.032;
	float ridge2 = sin(angle * 3.0 + 2.5) * 0.035 + cos(angle * 9.0) * 0.015 + 0.055;
	if (y > -0.05 && y < ridge2) {
		vec3 silhouette_col = mix(ground_bottom_color, sky_horizon_color * 0.28, 0.5);
		float mask2 = smoothstep(ridge2, ridge2 - 0.004, y);
		col = mix(col, silhouette_col, mask2 * 0.85);
	}
	if (y > -0.05 && y < ridge1) {
		vec3 near_ridge_col = ground_bottom_color * 0.75;
		float mask1 = smoothstep(ridge1, ridge1 - 0.003, y);
		col = mix(col, near_ridge_col, mask1);
	}

	COLOR = col;
}
"""
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = sky_shader

	var sky_res := Sky.new()
	sky_res.sky_material = _sky_mat
	sky_res.process_mode = Sky.PROCESS_MODE_REALTIME

	_env.background_mode = Environment.BG_SKY
	_env.sky = sky_res
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY

	if not _is_headless:
		_env.tonemap_mode = Environment.TONE_MAPPER_ACES
		_env.glow_enabled = true
		_env.glow_normalized = true
		_env.glow_bloom = 0.15
		_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
		_env.ssao_enabled = true
		_env.ssao_radius = 1.2
		_env.ssao_intensity = 1.8
		_env.ssr_max_steps = 48
		_env.ssr_fade_in = 0.15
		_env.ssr_fade_out = 2.0
		_env.volumetric_fog_enabled = enable_volumetric_fog
		_env.volumetric_fog_length = 110.0
		_env.volumetric_fog_detail_spread = 2.0


func _discover_or_create_directional_light() -> void:
	var root: Node = get_tree().current_scene if get_tree() else get_parent()
	if not is_instance_valid(root):
		root = self

	_sun_light = _find_node_of_type(root, "DirectionalLight3D") as DirectionalLight3D
	if not is_instance_valid(_sun_light):
		_sun_light = DirectionalLight3D.new()
		_sun_light.name = "AkinaDirectionalLight"
		add_child(_sun_light)

	_sun_light.shadow_enabled = not _is_headless
	_sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun_light.directional_shadow_max_distance = 160.0
	_sun_light.light_volumetric_fog_energy = 1.6


## ============================================================================
## SCENE DISCOVERY (VEHICLE, PHYSICS SOLVER, ROAD MATERIALS)
## ============================================================================

func set_target_vehicle(vehicle: Node3D) -> void:
	_player_vehicle = vehicle

func _discover_scene_entities() -> void:
	var root: Node = get_tree().current_scene if get_tree() else get_parent()
	if not is_instance_valid(root):
		return

	# 1. Discover Player Vehicle
	if not is_instance_valid(_player_vehicle):
		var candidates: Array[Node] = []
		_collect_nodes_recursive(root, candidates)
		for node in candidates:
			if node is VehicleBody3D or node is CharacterBody3D or node is RigidBody3D:
				var n_lower: String = node.name.to_lower()
				if node.is_in_group("player") or node.is_in_group("vehicle") or "ae86" in n_lower or "skyline" in n_lower or "r34" in n_lower or "car" in n_lower or "player" in n_lower or "vehicle" in n_lower or "touge" in n_lower:
					_player_vehicle = node as Node3D
					break
		# Fallback to any Node3D with drift physics script
		if not is_instance_valid(_player_vehicle):
			for node in candidates:
				if node is Node3D and ("surface_friction_mult" in node or "drift_angle" in node or "slip_angle" in node):
					_player_vehicle = node as Node3D
					break

	# 2. Discover TougeDriftPhysicsSolver & TougeDriftRefereeSystem
	if not is_instance_valid(_physics_solver) or not is_instance_valid(_referee_system):
		var all_nodes: Array[Node] = []
		_collect_nodes_recursive(root, all_nodes)
		for node in all_nodes:
			var node_name: String = node.name
			var script_obj: Script = node.get_script() as Script
			var global_cname: String = script_obj.get_global_name() if is_instance_valid(script_obj) else ""

			if "TougeDriftPhysicsSolver" in node_name or "TougeDriftPhysicsSolver" in global_cname or "surface_friction_mult" in node:
				_physics_solver = node
			if "TougeDriftRefereeSystem" in node_name or "TougeDriftRefereeSystem" in global_cname:
				_referee_system = node

	# 3. Discover Road / Tarmac Materials for Wet Asphalt SSR Overrides
	if _road_materials.is_empty():
		var all_nodes: Array[Node] = []
		_collect_nodes_recursive(root, all_nodes)
		for node in all_nodes:
			if node is MeshInstance3D or node is CSGShape3D:
				var n_lower: String = node.name.to_lower()
				if "road" in n_lower or "asphalt" in n_lower or "tarmac" in n_lower or "track" in n_lower or "touge" in n_lower or "ground" in n_lower:
					_extract_materials_from_geometry(node)


func _extract_materials_from_geometry(node: Node) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		if is_instance_valid(mi.material_override) and not _road_materials.has(mi.material_override):
			_road_materials.append(mi.material_override)
		if not _is_headless and is_instance_valid(mi.mesh) and mi.mesh.get_rid().is_valid():
			for s in range(mi.mesh.get_surface_count()):
				var mat: Material = mi.get_active_material(s)
				if is_instance_valid(mat) and not _road_materials.has(mat):
					_road_materials.append(mat)
	elif node is CSGShape3D:
		var csg: CSGShape3D = node as CSGShape3D
		if "material" in csg and is_instance_valid(csg.get("material")):
			var mat: Material = csg.get("material")
			if not _road_materials.has(mat):
				_road_materials.append(mat)


func _sync_physics_friction() -> void:
	if is_instance_valid(_physics_solver):
		if "surface_friction_mult" in _physics_solver:
			_physics_solver.set("surface_friction_mult", surface_friction_mult)
		elif _physics_solver.has_method("set_surface_friction_multiplier"):
			_physics_solver.call("set_surface_friction_multiplier", surface_friction_mult)
		elif _physics_solver.has_method("set_surface_friction"):
			_physics_solver.call("set_surface_friction", surface_friction_mult)

	if is_instance_valid(_player_vehicle) and _player_vehicle != _physics_solver:
		if "surface_friction_mult" in _player_vehicle:
			_player_vehicle.set("surface_friction_mult", surface_friction_mult)
		elif _player_vehicle.has_method("set_surface_friction_multiplier"):
			_player_vehicle.call("set_surface_friction_multiplier", surface_friction_mult)


## ============================================================================
## PROCEDURAL ROADSIDE STREETLAMPS, VENDING MACHINES & CAT'S EYE STUDS
## ============================================================================

func _setup_roadside_props() -> void:
	_streetlamp_root = Node3D.new()
	_streetlamp_root.name = "AkinaRoadsideLighting"
	add_child(_streetlamp_root)

	if not enable_streetlamps:
		return

	# Create Sodium-Vapor Streetlamps & Japanese Vending Machines along the Touge Corridor
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.08
	pole_mesh.bottom_radius = 0.12
	pole_mesh.height = 5.5

	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.22, 0.24, 0.27)
	pole_mat.metallic = 0.8
	pole_mat.roughness = 0.4

	var bulb_mesh := BoxMesh.new()
	bulb_mesh.size = Vector3(0.65, 0.14, 0.32)

	var bulb_mat := StandardMaterial3D.new()
	bulb_mat.albedo_color = Color(1.0, 0.72, 0.25)
	bulb_mat.emission_enabled = true
	bulb_mat.emission = Color(1.0, 0.65, 0.20)
	bulb_mat.emission_energy_multiplier = 4.5

	for i in range(6):
		var z_pos: float = -float(i) * 28.0 + 14.0
		var x_side: float = -6.5 if (i % 2 == 0) else 6.5

		var lamp_Rig := Node3D.new()
		lamp_Rig.name = "SodiumStreetlamp_%d" % i
		lamp_Rig.position = Vector3(x_side, 0.0, z_pos)
		_streetlamp_root.add_child(lamp_Rig)

		var pole := MeshInstance3D.new()
		pole.mesh = pole_mesh
		pole.material_override = pole_mat
		pole.position = Vector3(0.0, 2.75, 0.0)
		lamp_Rig.add_child(pole)

		var arm_offset: float = 1.2 if x_side < 0.0 else -1.2
		var bulb := MeshInstance3D.new()
		bulb.mesh = bulb_mesh
		bulb.material_override = bulb_mat
		bulb.position = Vector3(arm_offset, 5.4, 0.0)
		lamp_Rig.add_child(bulb)

		var omni := OmniLight3D.new()
		omni.position = Vector3(arm_offset, 5.1, 0.0)
		omni.light_color = Color(1.0, 0.65, 0.20)
		omni.light_energy = 3.4
		omni.omni_range = 22.0
		omni.omni_attenuation = 1.35
		omni.light_volumetric_fog_energy = 2.4
		lamp_Rig.add_child(omni)
		_streetlamps.append(omni)

	# Create 2 Glowing Roadside Japanese Beverage Vending Machines (Initial D Touge Spot)
	var vm_mesh := BoxMesh.new()
	vm_mesh.size = Vector3(1.15, 1.95, 0.80)

	for v in range(2):
		var vm_mat := StandardMaterial3D.new()
		var is_blue: bool = (v == 0)
		var glow_col: Color = Color(0.25, 0.72, 1.0) if is_blue else Color(1.0, 0.22, 0.28)
		vm_mat.albedo_color = glow_col
		vm_mat.emission_enabled = true
		vm_mat.emission = glow_col
		vm_mat.emission_energy_multiplier = 2.8
		vm_mat.roughness = 0.2

		var vm_inst := MeshInstance3D.new()
		vm_inst.name = "AkinaVendingMachine_%d" % v
		vm_inst.mesh = vm_mesh
		vm_inst.material_override = vm_mat
		vm_inst.position = Vector3(7.2, 0.975, -18.0 - float(v) * 2.2)
		vm_inst.rotation_degrees.y = -90.0
		_streetlamp_root.add_child(vm_inst)
		_vending_machines.append(vm_inst)

		var vm_light := OmniLight3D.new()
		vm_light.position = Vector3(-0.8, 0.2, 0.0)
		vm_light.light_color = glow_col
		vm_light.light_energy = 1.6
		vm_light.omni_range = 9.0
		vm_light.light_volumetric_fog_energy = 1.8
		vm_inst.add_child(vm_light)
		_streetlamps.append(vm_light)

	# Create Reflective Cat's Eye Centerline Road Studs for Dense Fog navigation
	var stud_mesh := BoxMesh.new()
	stud_mesh.size = Vector3(0.14, 0.04, 0.14)
	var stud_mat := StandardMaterial3D.new()
	stud_mat.albedo_color = Color(1.0, 0.78, 0.12)
	stud_mat.emission_enabled = true
	stud_mat.emission = Color(1.0, 0.68, 0.10)
	stud_mat.emission_energy_multiplier = 3.2

	for s in range(20):
		var stud := MeshInstance3D.new()
		stud.name = "CatsEyeStud_%d" % s
		stud.mesh = stud_mesh
		stud.material_override = stud_mat
		stud.position = Vector3(0.0, 0.02, 18.0 - float(s) * 8.0)
		_streetlamp_root.add_child(stud)


## ============================================================================
## PROCEDURAL RAIN STREAKS & TIRE WATER SPRAY MIST
## ============================================================================

func _setup_weather_particles() -> void:
	# 3D Procedural Rain Streaks (CPUParticles3D works universally in Forward+ & Headless)
	_rain_particles = CPUParticles3D.new()
	_rain_particles.name = "AkinaRainStreaks3D"
	_rain_particles.emitting = false
	_rain_particles.amount = 900
	_rain_particles.lifetime = 0.65
	_rain_particles.preprocess = 0.5
	_rain_particles.local_coords = false
	_rain_particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_rain_particles.emission_box_extents = Vector3(22.0, 1.0, 22.0)
	_rain_particles.direction = Vector3(0.12, -1.0, 0.25).normalized()
	_rain_particles.spread = 4.5
	_rain_particles.gravity = Vector3(0.0, -32.0, 0.0)
	_rain_particles.initial_velocity_min = 26.0
	_rain_particles.initial_velocity_max = 34.0

	var rain_mat := StandardMaterial3D.new()
	rain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rain_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	rain_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rain_mat.albedo_color = Color(0.75, 0.85, 0.98, 0.36)
	rain_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES

	var rain_quad := QuadMesh.new()
	rain_quad.size = Vector2(0.025, 0.85)
	rain_quad.material = rain_mat
	_rain_particles.mesh = rain_quad
	_rain_particles.position = Vector3(0.0, 14.0, 0.0)
	add_child(_rain_particles)


func _setup_vehicle_headlights_and_spray() -> void:
	# Pop-up Halogen Headlights (Left & Right High-Beam Cones + Housing Meshes)
	var housing_mesh := BoxMesh.new()
	housing_mesh.size = Vector3(0.24, 0.16, 0.22)
	var lens_mat := StandardMaterial3D.new()
	lens_mat.albedo_color = Color(1.0, 0.95, 0.82)
	lens_mat.emission_enabled = true
	lens_mat.emission = Color(1.0, 0.92, 0.72)
	lens_mat.emission_energy_multiplier = 5.0

	_headlight_left = _create_halogen_spotlight("HeadlightLeft", Vector3(-0.68, 0.68, -1.95))
	_headlight_right = _create_halogen_spotlight("HeadlightRight", Vector3(0.68, 0.68, -1.95))

	_headlight_mesh_left = MeshInstance3D.new()
	_headlight_mesh_left.mesh = housing_mesh
	_headlight_mesh_left.material_override = lens_mat
	_headlight_left.add_child(_headlight_mesh_left)

	_headlight_mesh_right = MeshInstance3D.new()
	_headlight_mesh_right.mesh = housing_mesh
	_headlight_mesh_right.material_override = lens_mat
	_headlight_right.add_child(_headlight_mesh_right)

	# Rear Tire Water Spray Mist (Left & Right Rear Tires)
	_tire_spray_left = _create_tire_spray_emitter("TireWaterSprayLeft", Vector3(-0.78, 0.18, 1.45))
	_tire_spray_right = _create_tire_spray_emitter("TireWaterSprayRight", Vector3(0.78, 0.18, 1.45))


func _create_halogen_spotlight(node_name: String, local_pos: Vector3) -> SpotLight3D:
	var spot := SpotLight3D.new()
	spot.name = node_name
	spot.position = local_pos
	spot.rotation_degrees = Vector3(-4.5, 0.0, 0.0)
	spot.light_color = Color(1.0, 0.93, 0.78)
	spot.light_energy = 6.8
	spot.light_volumetric_fog_energy = 3.6
	spot.spot_range = 62.0
	spot.spot_attenuation = 1.25
	spot.spot_angle = 31.0
	spot.spot_angle_attenuation = 0.65
	spot.shadow_enabled = not _is_headless
	add_child(spot)
	return spot


func _create_tire_spray_emitter(node_name: String, local_pos: Vector3) -> CPUParticles3D:
	var spray := CPUParticles3D.new()
	spray.name = node_name
	spray.position = local_pos
	spray.emitting = false
	spray.amount = 48
	spray.lifetime = 0.55
	spray.local_coords = false
	spray.direction = Vector3(0.0, 0.35, 1.0).normalized()
	spray.spread = 28.0
	spray.gravity = Vector3(0.0, -4.5, 0.0)
	spray.initial_velocity_min = 4.0
	spray.initial_velocity_max = 9.5
	spray.scale_amount_min = 0.6
	spray.scale_amount_max = 1.8

	var mist_mat := StandardMaterial3D.new()
	mist_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mist_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mist_mat.albedo_color = Color(0.76, 0.84, 0.92, 0.24)
	mist_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES

	var mist_quad := QuadMesh.new()
	mist_quad.size = Vector2(0.55, 0.55)
	mist_quad.material = mist_mat
	spray.mesh = mist_quad
	add_child(spray)
	return spray


func _update_vehicle_attachments(delta: float) -> void:
	var anchor_xform: Transform3D = global_transform
	var vehicle_speed: float = 0.0
	var is_drifting: bool = false

	if is_instance_valid(_player_vehicle):
		anchor_xform = _player_vehicle.global_transform
		if "linear_velocity" in _player_vehicle:
			var vel: Vector3 = _player_vehicle.get("linear_velocity")
			vehicle_speed = vel.length()
		elif "velocity" in _player_vehicle:
			var vel2: Vector3 = _player_vehicle.get("velocity")
			vehicle_speed = vel2.length()

		if "is_drifting" in _player_vehicle:
			is_drifting = bool(_player_vehicle.get("is_drifting"))
		elif is_instance_valid(_physics_solver) and "is_drifting" in _physics_solver:
			is_drifting = bool(_physics_solver.get("is_drifting"))
		else:
			is_drifting = vehicle_speed > 8.0
	else:
		# Fallback to active Camera3D if running a camera flythrough
		var vp: Viewport = get_viewport()
		if is_instance_valid(vp) and is_instance_valid(vp.get_camera_3d()):
			anchor_xform = vp.get_camera_3d().global_transform

	# Position rain volume above the vehicle/camera and angle streaks with speed
	if is_instance_valid(_rain_particles):
		_rain_particles.global_position = anchor_xform.origin + Vector3(0.0, 14.0, 0.0)
		var wind_slant: Vector3 = Vector3(0.12, -1.0, clampf(vehicle_speed * 0.015, 0.15, 0.65)).normalized()
		_rain_particles.direction = anchor_xform.basis * wind_slant

	# Position Pop-up Headlights relative to vehicle chassis
	if is_instance_valid(_headlight_left) and is_instance_valid(_headlight_right):
		var target_pitch: float = -65.0 if is_blind_attack_active else -4.5
		_headlight_left.global_transform = anchor_xform * Transform3D(Basis.from_euler(Vector3(deg_to_rad(target_pitch), 0.0, 0.0)), Vector3(-0.68, 0.68, -1.95))
		_headlight_right.global_transform = anchor_xform * Transform3D(Basis.from_euler(Vector3(deg_to_rad(target_pitch), 0.0, 0.0)), Vector3(0.68, 0.68, -1.95))

	# Update Rear Tire Water Spray during Rainy Touge preset
	if is_instance_valid(_tire_spray_left) and is_instance_valid(_tire_spray_right):
		_tire_spray_left.global_position = anchor_xform * Vector3(-0.78, 0.18, 1.45)
		_tire_spray_right.global_position = anchor_xform * Vector3(0.78, 0.18, 1.45)

		var back_dir: Vector3 = (anchor_xform.basis * Vector3(0.0, 0.35, 1.0)).normalized()
		_tire_spray_left.direction = back_dir
		_tire_spray_right.direction = back_dir

		var rain_active: bool = _current_state.get("rain_amount_ratio", 0.0) > 0.35
		var spray_should_emit: bool = rain_active and (vehicle_speed > 3.5 or is_drifting or not is_instance_valid(_player_vehicle))
		_tire_spray_left.emitting = spray_should_emit and not _is_headless
		_tire_spray_right.emitting = spray_should_emit and not _is_headless

		var dynamic_vel: float = clampf(vehicle_speed * 0.45, 5.0, 18.0)
		_tire_spray_left.initial_velocity_max = dynamic_vel
		_tire_spray_right.initial_velocity_max = dynamic_vel

	# Recycle roadside streetlamps endlessly around the player if driving far along the Touge
	if is_instance_valid(_streetlamp_root) and is_instance_valid(_player_vehicle):
		var forward_dist: float = _player_vehicle.global_position.z - _streetlamp_root.global_position.z
		if absf(forward_dist) > 84.0:
			_streetlamp_root.global_position.z = snappedf(_player_vehicle.global_position.z, 28.0)


func _update_headlight_state() -> void:
	var base_energy: float = _current_state.get("headlight_energy", 6.8)
	var effective_energy: float = 0.0 if is_blind_attack_active else base_energy
	var visible_cone: bool = effective_energy > 0.05

	if is_instance_valid(_headlight_left):
		_headlight_left.light_energy = effective_energy
		_headlight_left.visible = visible_cone
	if is_instance_valid(_headlight_right):
		_headlight_right.light_energy = effective_energy
		_headlight_right.visible = visible_cone
	if is_instance_valid(_headlight_mesh_left):
		_headlight_mesh_left.visible = visible_cone
	if is_instance_valid(_headlight_mesh_right):
		_headlight_mesh_right.visible = visible_cone


## ============================================================================
## STATE INTERPOLATION & SHADER PARAMETER UPDATES
## ============================================================================

func _apply_interpolated_state(t: float) -> void:
	if _source_state.is_empty() or _target_state.is_empty():
		return

	# Interpolate numerical & color fields
	_current_state["sky_top"] = (_source_state["sky_top"] as Color).lerp(_target_state["sky_top"], t)
	_current_state["sky_horizon"] = (_source_state["sky_horizon"] as Color).lerp(_target_state["sky_horizon"], t)
	_current_state["ground_bottom"] = (_source_state["ground_bottom"] as Color).lerp(_target_state["ground_bottom"], t)
	_current_state["sun_elevation"] = lerpf(_source_state["sun_elevation"], _target_state["sun_elevation"], t)
	_current_state["sun_azimuth"] = lerpf(_source_state["sun_azimuth"], _target_state["sun_azimuth"], t)
	_current_state["sun_color"] = (_source_state["sun_color"] as Color).lerp(_target_state["sun_color"], t)
	_current_state["sun_energy"] = lerpf(_source_state["sun_energy"], _target_state["sun_energy"], t)
	_current_state["ambient_color"] = (_source_state["ambient_color"] as Color).lerp(_target_state["ambient_color"], t)
	_current_state["ambient_energy"] = lerpf(_source_state["ambient_energy"], _target_state["ambient_energy"], t)
	_current_state["ambient_sky_contrib"] = lerpf(_source_state["ambient_sky_contrib"], _target_state["ambient_sky_contrib"], t)
	_current_state["fog_density"] = lerpf(_source_state["fog_density"], _target_state["fog_density"], t)
	_current_state["fog_albedo"] = (_source_state["fog_albedo"] as Color).lerp(_target_state["fog_albedo"], t)
	_current_state["fog_emission"] = (_source_state["fog_emission"] as Color).lerp(_target_state["fog_emission"], t)
	_current_state["fog_anisotropy"] = lerpf(_source_state["fog_anisotropy"], _target_state["fog_anisotropy"], t)
	_current_state["road_roughness"] = lerpf(_source_state["road_roughness"], _target_state["road_roughness"], t)
	_current_state["road_specular"] = lerpf(_source_state["road_specular"], _target_state["road_specular"], t)
	_current_state["star_intensity"] = lerpf(_source_state["star_intensity"], _target_state["star_intensity"], t)
	_current_state["streetlamp_energy"] = lerpf(_source_state["streetlamp_energy"], _target_state["streetlamp_energy"], t)
	_current_state["headlight_energy"] = lerpf(_source_state["headlight_energy"], _target_state["headlight_energy"], t)
	_current_state["rain_amount_ratio"] = lerpf(_source_state["rain_amount_ratio"], _target_state["rain_amount_ratio"], t)
	_current_state["tonemap_exposure"] = lerpf(_source_state["tonemap_exposure"], _target_state["tonemap_exposure"], t)
	_current_state["glow_intensity"] = lerpf(_source_state["glow_intensity"], _target_state["glow_intensity"], t)
	_current_state["ssr_enabled"] = _target_state["ssr_enabled"]
	_current_state["fog_enabled"] = _target_state["fog_enabled"]

	# 1. Update Sky Shader Parameters
	if is_instance_valid(_sky_mat):
		_sky_mat.set_shader_parameter("sky_top_color", _current_state["sky_top"])
		_sky_mat.set_shader_parameter("sky_horizon_color", _current_state["sky_horizon"])
		_sky_mat.set_shader_parameter("ground_bottom_color", _current_state["ground_bottom"])
		_sky_mat.set_shader_parameter("star_intensity", _current_state["star_intensity"])
		_sky_mat.set_shader_parameter("sun_tint", _current_state["sun_color"])

	# 2. Update DirectionalLight3D (Sun / Moon)
	if is_instance_valid(_sun_light):
		_sun_light.rotation_degrees = Vector3(-_current_state["sun_elevation"], _current_state["sun_azimuth"], 0.0)
		_sun_light.light_color = _current_state["sun_color"]
		_sun_light.light_energy = _current_state["sun_energy"]

	# 3. Update WorldEnvironment
	if is_instance_valid(_env) and not _is_headless:
		if not is_blind_attack_active:
			_env.ambient_light_color = _current_state["ambient_color"]
			_env.ambient_light_energy = _current_state["ambient_energy"]
		_env.ambient_light_sky_contribution = _current_state["ambient_sky_contrib"]
		_env.tonemap_exposure = _current_state["tonemap_exposure"]
		_env.glow_intensity = _current_state["glow_intensity"]
		_env.ssr_enabled = bool(_current_state["ssr_enabled"])

		_env.volumetric_fog_enabled = enable_volumetric_fog and bool(_current_state["fog_enabled"])
		_env.volumetric_fog_density = _current_state["fog_density"]
		_env.volumetric_fog_albedo = _current_state["fog_albedo"]
		_env.volumetric_fog_emission = _current_state["fog_emission"]
		_env.volumetric_fog_anisotropy = _current_state["fog_anisotropy"]

		# Fallback depth fog when volumetric fog is toggled off via [F5]
		_env.fog_enabled = not enable_volumetric_fog and (_current_state["fog_density"] > 0.02)
		_env.fog_light_color = _current_state["fog_albedo"]
		_env.fog_density = _current_state["fog_density"] * 0.45

	# 4. Update Roadside Sodium-Vapor Streetlamps
	var lamp_e: float = _current_state["streetlamp_energy"]
	for lamp in _streetlamps:
		if is_instance_valid(lamp):
			lamp.light_energy = lamp_e
			lamp.visible = lamp_e > 0.05

	# 5. Update Vehicle Headlights
	_update_headlight_state()

	# 6. Update Rain Particle System
	if is_instance_valid(_rain_particles):
		var rain_on: bool = _current_state["rain_amount_ratio"] > 0.25
		_rain_particles.emitting = rain_on and not _is_headless

	# 7. Update Road Asphalt Roughness & Specular (Wet Asphalt SSR Reflections)
	_apply_road_surface_shader_params(_current_state["road_roughness"], _current_state["road_specular"])


func _apply_road_surface_shader_params(roughness_val: float, specular_val: float) -> void:
	for mat in _road_materials:
		if not is_instance_valid(mat):
			continue
		if mat is StandardMaterial3D:
			var smat: StandardMaterial3D = mat as StandardMaterial3D
			smat.roughness = roughness_val
			smat.metallic_specular = specular_val
			smat.anisotropy_enabled = roughness_val > 0.5
			smat.anisotropy = 0.35 if roughness_val > 0.5 else 0.0
		elif mat is ShaderMaterial:
			var shmat: ShaderMaterial = mat as ShaderMaterial
			shmat.set_shader_parameter("roughness", roughness_val)
			shmat.set_shader_parameter("wet_roughness", roughness_val)
			shmat.set_shader_parameter("specular", specular_val)
			shmat.set_shader_parameter("wetness", clampf(1.0 - (roughness_val / 0.68), 0.0, 1.0))


## ============================================================================
## INITIAL D ARCADE TOAST & MANGA BLIND ATTACK HUD
## ============================================================================

func _setup_arcade_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "AkinaAtmosphereHUD"
	_ui_layer.layer = 95
	add_child(_ui_layer)

	_hud_drawer = _AkinaAtmosphereHUDDrawer.new(self)
	_hud_drawer.name = "ArcadeOverlayControl"
	_hud_drawer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud_drawer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(_hud_drawer)


func _show_toast(title: String, subtitle: String = "") -> void:
	_toast_title = title
	_toast_subtitle = subtitle
	_toast_timer = 4.0
	if is_instance_valid(_hud_drawer):
		_hud_drawer.queue_redraw()


## ============================================================================
## INTERNAL HUD CANVAS DRAWER (MANGA CALLOUTS, LENS FLARE & ARCADE TOAST)
## ============================================================================

class _AkinaAtmosphereHUDDrawer extends Control:
	var _owner_sys: AkinaDynamicAtmosphere = null

	func _init(owner_ref: AkinaDynamicAtmosphere) -> void:
		_owner_sys = owner_ref

	func _draw() -> void:
		if not is_instance_valid(_owner_sys) or _owner_sys._is_headless:
			return

		var vp_size: Vector2 = get_viewport_rect().size
		var font: Font = ThemeDB.fallback_font

		# 1. BLIND ATTACK NIGHT-VISION TINT, ANAMORPHIC LENS FLARE & MANGA CALLOUT
		if _owner_sys.is_blind_attack_active or _owner_sys._blind_attack_flash > 0.0:
			_draw_blind_attack_effects(vp_size, font)

		# 2. INITIAL D ARCADE WEATHER TOAST BANNER
		if _owner_sys._toast_timer > 0.0:
			_draw_weather_toast(vp_size, font)

	func _draw_blind_attack_effects(vp_size: Vector2, font: Font) -> void:
		# Subtle high-contrast moonlight blue night-vision vignette
		if _owner_sys.is_blind_attack_active:
			draw_rect(Rect2(Vector2.ZERO, vp_size), Color(0.04, 0.14, 0.34, 0.14), true)

			# Anamorphic Horizontal Blue Stealth Lens Flare Streak
			var flare_y: float = vp_size.y * 0.22
			draw_rect(Rect2(0.0, flare_y - 2.0, vp_size.x, 4.0), Color(0.30, 0.72, 1.0, 0.25), true)
			draw_rect(Rect2(vp_size.x * 0.15, flare_y - 8.0, vp_size.x * 0.70, 16.0), Color(0.20, 0.55, 1.0, 0.08), true)

			# Peripheral Manga Action Speed Lines
			var center: Vector2 = vp_size * 0.5
			var num_lines: int = 36
			for i in range(num_lines):
				var angle: float = (TAU / float(num_lines)) * float(i) + sin(_owner_sys._speed_lines_phase + float(i)) * 0.04
				var dir := Vector2(cos(angle), sin(angle))
				var r_inner: float = vp_size.length() * (0.38 + 0.04 * sin(_owner_sys._speed_lines_phase * 1.7 + float(i) * 2.3))
				var r_outer: float = vp_size.length() * 0.65
				draw_line(center + dir * r_inner, center + dir * r_outer, Color(0.75, 0.90, 1.0, 0.18), 2.0)

		# Activation flash
		if _owner_sys._blind_attack_flash > 0.0:
			draw_rect(Rect2(Vector2.ZERO, vp_size), Color(0.65, 0.88, 1.0, _owner_sys._blind_attack_flash * 0.35), true)

		# Dramatic Manga Callout Banner: "消える…！？ ブラインド・アタック！ (BLIND ATTACK!)"
		if _owner_sys._blind_attack_banner_timer > 0.0 and is_instance_valid(font):
			var alpha: float = clampf(_owner_sys._blind_attack_banner_timer * 1.2, 0.0, 1.0)
			var panel_w: float = 680.0
			var panel_h: float = 84.0
			var panel_pos := Vector2((vp_size.x - panel_w) * 0.5, vp_size.y * 0.14)

			# Skewed Manga Box Polygon
			var skew: float = 24.0
			var pts := PackedVector2Array([
				panel_pos + Vector2(skew, 0.0),
				panel_pos + Vector2(panel_w + skew, 0.0),
				panel_pos + Vector2(panel_w - skew, panel_h),
				panel_pos + Vector2(-skew, panel_h)
			])
			draw_colored_polygon(pts, Color(0.02, 0.03, 0.06, 0.92 * alpha))

			# High-contrast Manga Double Border
			var border_pts: PackedVector2Array = pts.duplicate()
			border_pts.append(pts[0])
			draw_polyline(border_pts, Color(0.32, 0.78, 1.0, alpha), 3.5)

			var main_callout: String = "消える…！？ ブラインド・アタック！ (BLIND ATTACK!)"
			var sub_callout: String = "HEADLIGHTS EXTINGUISHED — STEALTH SLIPSTREAM ENGAGED"
			draw_string(font, panel_pos + Vector2(36.0, 42.0), main_callout, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(1.0, 1.0, 1.0, alpha))
			draw_string(font, panel_pos + Vector2(42.0, 68.0), sub_callout, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.45, 0.85, 1.0, alpha))

	func _draw_weather_toast(vp_size: Vector2, font: Font) -> void:
		if not is_instance_valid(font):
			return

		var alpha: float = clampf(_owner_sys._toast_timer * 1.5, 0.0, 1.0)
		var box_w: float = 590.0
		var box_h: float = 66.0
		var base_pos := Vector2(28.0, 26.0)
		var skew: float = 16.0

		var bg_pts := PackedVector2Array([
			base_pos + Vector2(skew, 0.0),
			base_pos + Vector2(box_w + skew, 0.0),
			base_pos + Vector2(box_w, box_h),
			base_pos + Vector2(0.0, box_h)
		])
		draw_colored_polygon(bg_pts, Color(0.04, 0.05, 0.08, 0.88 * alpha))

		# Amber Initial D Arcade Accent Strip
		var strip_pts := PackedVector2Array([
			base_pos + Vector2(skew, 0.0),
			base_pos + Vector2(skew + 10.0, 0.0),
			base_pos + Vector2(10.0, box_h),
			base_pos + Vector2(0.0, box_h)
		])
		draw_colored_polygon(strip_pts, Color(1.0, 0.68, 0.12, alpha))

		draw_string(font, base_pos + Vector2(32.0, 30.0), _owner_sys._toast_title, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1.0, 0.94, 0.78, alpha))
		draw_string(font, base_pos + Vector2(32.0, 52.0), _owner_sys._toast_subtitle, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.68, 0.78, 0.90, alpha))


## ============================================================================
## UTILITY HELPERS
## ============================================================================

func _find_node_of_type(root: Node, target_class: String) -> Node:
	if not is_instance_valid(root):
		return null
	if root.is_class(target_class):
		return root
	for child in root.get_children():
		var found: Node = _find_node_of_type(child, target_class)
		if is_instance_valid(found):
			return found
	return null


func _collect_nodes_recursive(node: Node, out_list: Array[Node]) -> void:
	if not is_instance_valid(node):
		return
	out_list.append(node)
	for child in node.get_children():
		_collect_nodes_recursive(child, out_list)
