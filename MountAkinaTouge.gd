@tool
class_name MountAkinaTouge
extends Node3D
## Procedural Japanese Mountain Touge Environment & Track Generator for "ShiTmoZ/RACING"
## Designed for Godot 4.3 (Vulkan Forward+)

# ==============================================================================
# EXPORTED CONFIGURATION
# ==============================================================================
@export_group("Scene & Spawn Integration")
@export var spawn_vehicle_enabled: bool = true
@export var vehicle_scene_path: String = "res://Vehicle.tscn"
@export var chase_camera_script_path: String = "res://ArcadeChaseCamera.gd"
@export var regenerate_track: bool = false:
	set(value):
		if value:
			_build_entire_environment()
		regenerate_track = false

@export_group("Touge Spline & Geometry")
@export var spline_bake_interval: float = 2.5 ## Distance in meters between cross-sections
@export var road_width: float = 11.0 ## Total asphalt width (2-lane mountain pass)
@export var shoulder_width: float = 1.0
@export var gutter_width: float = 0.65 ## Iconic Akina inner drainage trench width
@export var gutter_depth: float = 0.24 ## Depth of the gutter for wheel-hook physics
@export var max_bank_angle_deg: float = 11.5 ## Maximum superelevation angle in hairpins
@export var curvature_bank_scale: float = 28.0

@export_group("Props & JDM Infrastructure")
@export var guardrail_post_spacing: float = 5.0
@export var reflector_stud_spacing: float = 10.0
@export var street_light_spacing: float = 45.0
@export var sakura_emitters_count: int = 12

# ==============================================================================
# INTERNAL STATE & CACHED FRAMES
# ==============================================================================
class RoadFrame:
	var position: Vector3
	var tangent: Vector3
	var normal: Vector3
	var binormal: Vector3
	var curvature: float # Signed curvature: + = curving left, - = curving right
	var bank_angle: float # Radians
	var distance: float

const GraphicsSettingsManager = preload("res://JDMGraphicsSettingsManager.gd")
const JDMRadioAudioSystem = preload("res://JDMRadioAudioSystem.gd")
const AkinaRoadsidePropsDecorator = preload("res://AkinaRoadsidePropsDecorator.gd")
const JDMVehicleFleetManager = preload("res://JDMVehicleFleetManager.gd")

var _frames: Array[RoadFrame] = []
var _curve: Curve3D = Curve3D.new()
var _spawn_transform: Transform3D = Transform3D.IDENTITY
var _spawned_vehicle: Node3D = null
var _gfx_manager: Node = null

# Procedural Materials Cache
var _mat_road: ShaderMaterial
var _mat_gutter_wall: StandardMaterial3D
var _mat_guardrail: StandardMaterial3D
var _mat_rock_cliff: StandardMaterial3D
var _mat_torii_red: StandardMaterial3D
var _mat_torii_black: StandardMaterial3D
var _mat_gantry_steel: StandardMaterial3D
var _mat_sakura_petal: StandardMaterial3D
var _mat_lot_asphalt: StandardMaterial3D

# ==============================================================================
# LIFECYCLE
# ==============================================================================
func _ready() -> void:
	_build_entire_environment()
	if not Engine.is_editor_hint() and spawn_vehicle_enabled:
		call_deferred("_spawn_player_vehicle")
		call_deferred("_setup_desktop_ui")
		call_deferred("_setup_radio_audio_system")
		call_deferred("_setup_graphics_settings_manager")
		call_deferred("_setup_vehicle_fleet_manager")
		call_deferred("_setup_multiplayer_network_manager")
		call_deferred("_setup_anime_post_process")
		call_deferred("_setup_drift_referee_system")
		call_deferred("_setup_digital_cluster_hud")
		call_deferred("_setup_atmosphere_and_weather")
		call_deferred("_setup_track_registry_and_menu")


var _referee_mgr: Node = null
var _digital_cluster: CanvasLayer = null
var _atmosphere_mgr: Node = null

var _track_registry_menu: CanvasLayer = null

func _setup_track_registry_and_menu() -> void:
	var menu_script := load("res://TougeTrackRegistryAndMenu.gd")
	if menu_script != null:
		_track_registry_menu = menu_script.new() as CanvasLayer
		if _track_registry_menu != null:
			_track_registry_menu.name = "TougeTrackRegistryAndMenu"
			add_child(_track_registry_menu)
			if _spawned_vehicle != null and _track_registry_menu.has_method("bind_context"):
				_track_registry_menu.call("bind_context", self, _spawned_vehicle as RigidBody3D)

func _setup_digital_cluster_hud() -> void:
	var cluster_script := load("res://InitialDDigitalClusterHUD.gd")
	if cluster_script != null:
		_digital_cluster = cluster_script.new() as CanvasLayer
		if _digital_cluster != null:
			_digital_cluster.name = "InitialDDigitalClusterHUD"
			add_child(_digital_cluster)

func _setup_atmosphere_and_weather() -> void:
	var atmo_script := load("res://AkinaDynamicAtmosphere.gd")
	if atmo_script != null:
		_atmosphere_mgr = atmo_script.new()
		_atmosphere_mgr.name = "AkinaDynamicAtmosphere"
		add_child(_atmosphere_mgr)
		if _spawned_vehicle != null and _atmosphere_mgr.has_method("set_target_vehicle"):
			_atmosphere_mgr.call("set_target_vehicle", _spawned_vehicle)


func _setup_drift_referee_system() -> void:
	var referee_script := load("res://TougeDriftRefereeSystem.gd")
	if referee_script != null:
		_referee_mgr = referee_script.new()
		add_child(_referee_mgr)
		if _spawned_vehicle != null and _referee_mgr.has_method("set_target_vehicle"):
			_referee_mgr.call("set_target_vehicle", _spawned_vehicle)


func _setup_anime_post_process() -> void:
	var anime_script := load("res://AnimePostProcessEffect.gd")
	if anime_script != null:
		var anime_mgr = anime_script.new()
		add_child(anime_mgr)


func _setup_multiplayer_network_manager() -> void:
	var net_script := load("res://TougeMultiplayerManager.gd")
	if net_script != null:
		var net_mgr = net_script.new()
		add_child(net_mgr)


func _setup_vehicle_fleet_manager() -> void:
	var fleet_mgr := JDMVehicleFleetManager.new()
	fleet_mgr.name = "JDMVehicleFleetManager"
	if _spawned_vehicle != null:
		fleet_mgr.target_player_vehicle = _spawned_vehicle
	add_child(fleet_mgr)


func _setup_graphics_settings_manager() -> void:
	_gfx_manager = GraphicsSettingsManager.new()
	_gfx_manager.name = "GraphicsSettingsManager"
	add_child(_gfx_manager)


func _setup_radio_audio_system() -> void:
	var radio := JDMRadioAudioSystem.new()
	radio.name = "JDMRadioAudioSystem"
	add_child(radio)


func _build_entire_environment() -> void:
	# Clean up previous generated children
	for child in get_children():
		remove_child(child)
		child.queue_free()
	
	_frames.clear()
	
	# 1. Initialize Vulkan Forward+ Shaders & Materials
	_init_materials()
	
	# 2. Setup Dusk/Night Atmosphere, Volumetric Fog, SSR & ACES Tonemapping
	_setup_atmosphere_and_lighting()
	
	# 3. Generate Master Looping Mountain Spline & Frenet-Serret Banked Frames
	_generate_touge_curve()
	_sample_road_frames()
	
	# 4. Generate Continuous High-Res Road, Gutters, Retaining Walls & Double-Sided Collision
	_build_road_and_retaining_mesh()
	
	# 5. Generate Continuous W-Beam Guardrails & Collision
	_build_w_beam_guardrails()
	
	# 6. Generate Reflective Road Cat's-Eyes (Center & Edge Studs)
	_build_reflective_cats_eyes()
	
	# 7. Generate Summit Observation Parking Lot & Starting Grid
	_build_summit_parking_lot()
	
	# 8. Populate JDM Landmarks: Neon Kanji Gantries, Torii Gates, Streetlights & Sakura
	_build_landmarks_and_props()
	_build_sakura_particle_systems()
	
	# 9. Populate Procedural Roadside Props (Poles, Catenary Wires, Torii, Pine & Sakura MultiMeshes)
	_build_roadside_props_decorator()


# ==============================================================================
# 1. PROCEDURAL SHADERS & MATERIALS
# ==============================================================================
func _init_materials() -> void:
	# Procedural High-Res Asphalt Shader with Japanese Double-Yellow Center & White Edge Lines
	var road_shader := Shader.new()
	road_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

void fragment() {
	// UV.x: 0.0 (left gutter outer) -> 1.0 (right gutter outer)
	// Asphalt occupies UV.x in [0.10, 0.90], center at 0.50
	vec2 uv = UV;
	
	// Multi-frequency procedural grain for wet/glossy Japanese mountain asphalt
	vec2 p = uv * vec2(24.0, 2.5);
	float n1 = fract(sin(dot(floor(p * 18.0), vec2(12.9898, 78.233))) * 43758.5453);
	float n2 = fract(sin(dot(floor(p * 65.0), vec2(39.346, 11.135))) * 24634.6345);
	float aggregate = mix(n1, n2, 0.5);
	
	vec3 base_asphalt = mix(vec3(0.055, 0.058, 0.065), vec3(0.11, 0.115, 0.125), aggregate);
	
	// Tire polish tracks in left and right lanes
	float left_lane_wear = exp(-pow((uv.x - 0.31) * 14.0, 2.0)) * 0.35;
	float right_lane_wear = exp(-pow((uv.x - 0.69) * 14.0, 2.0)) * 0.35;
	float tire_polish = clamp(left_lane_wear + right_lane_wear, 0.0, 1.0);
	
	vec3 col = base_asphalt * (1.0 - tire_polish * 0.25);
	float rough = mix(0.46, 0.22, tire_polish + aggregate * 0.15);
	float spec = 0.65;
	vec3 emission = vec3(0.0);
	
	// Concrete U-Gutter Zones (UV.x < 0.10 or UV.x > 0.90)
	if (uv.x < 0.10 || uv.x > 0.90) {
		float grate_pattern = step(0.15, fract(uv.y * 1.5));
		col = mix(vec3(0.18, 0.19, 0.20), vec3(0.28, 0.29, 0.31), aggregate * grate_pattern);
		rough = 0.78;
		spec = 0.3;
	}
	
	// Japanese Spec Double Solid Yellow Center Lines (UV.x around 0.50)
	float dist_center = abs(uv.x - 0.50);
	if (dist_center > 0.0045 && dist_center < 0.0135) {
		float paint_wear = smoothstep(0.15, 0.85, n1);
		vec3 yellow_paint = vec3(0.95, 0.62, 0.03);
		col = mix(col, yellow_paint, 0.92 - paint_wear * 0.15);
		rough = 0.32;
		emission = yellow_paint * 0.08;
	}
	
	// Japanese Outer White Shoulder Edge Lines (UV.x around 0.135 and 0.865)
	float dist_edge_l = abs(uv.x - 0.135);
	float dist_edge_r = abs(uv.x - 0.865);
	if (dist_edge_l < 0.008 || dist_edge_r < 0.008) {
		vec3 white_paint = vec3(0.88, 0.90, 0.94);
		col = mix(col, white_paint, 0.9);
		rough = 0.35;
		emission = white_paint * 0.05;
	}
	
	// Subtle procedural normal bump from aggregate
	NORMAL_MAP = normalize(vec3((n1 - 0.5) * 0.08, (n2 - 0.5) * 0.08, 1.0));
	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = spec;
	EMISSION = emission;
}
"""
	_mat_road = ShaderMaterial.new()
	_mat_road.shader = road_shader
	
	# Retaining Wall & Drainage Grooves Material
	_mat_gutter_wall = StandardMaterial3D.new()
	_mat_gutter_wall.albedo_color = Color(0.26, 0.27, 0.29)
	_mat_gutter_wall.roughness = 0.82
	_mat_gutter_wall.cull_mode = BaseMaterial3D.CULL_DISABLED
	
	# Galvanized Steel W-Beam Guardrail Material
	_mat_guardrail = StandardMaterial3D.new()
	_mat_guardrail.albedo_color = Color(0.76, 0.79, 0.83)
	_mat_guardrail.metallic = 0.88
	_mat_guardrail.roughness = 0.28
	_mat_guardrail.cull_mode = BaseMaterial3D.CULL_DISABLED
	
	# Mountain Rock Face Material
	_mat_rock_cliff = StandardMaterial3D.new()
	_mat_rock_cliff.albedo_color = Color(0.14, 0.13, 0.16)
	_mat_rock_cliff.roughness = 0.92
	_mat_rock_cliff.cull_mode = BaseMaterial3D.CULL_DISABLED
	
	# Traditional Vermilion Red Torii Material
	_mat_torii_red = StandardMaterial3D.new()
	_mat_torii_red.albedo_color = Color(0.85, 0.14, 0.08)
	_mat_torii_red.roughness = 0.35
	_mat_torii_red.metallic = 0.05
	
	_mat_torii_black = StandardMaterial3D.new()
	_mat_torii_black.albedo_color = Color(0.08, 0.08, 0.09)
	_mat_torii_black.roughness = 0.4
	
	# Gantry Dark Steel
	_mat_gantry_steel = StandardMaterial3D.new()
	_mat_gantry_steel.albedo_color = Color(0.15, 0.17, 0.20)
	_mat_gantry_steel.metallic = 0.85
	_mat_gantry_steel.roughness = 0.35
	
	# Glowing Pink Sakura Petal Material
	_mat_sakura_petal = StandardMaterial3D.new()
	_mat_sakura_petal.albedo_color = Color(1.0, 0.68, 0.82)
	_mat_sakura_petal.emission_enabled = true
	_mat_sakura_petal.emission = Color(1.0, 0.45, 0.70)
	_mat_sakura_petal.emission_energy_multiplier = 0.65
	_mat_sakura_petal.roughness = 0.4
	_mat_sakura_petal.cull_mode = BaseMaterial3D.CULL_DISABLED
	
	# Summit Parking Lot Asphalt
	_mat_lot_asphalt = StandardMaterial3D.new()
	_mat_lot_asphalt.albedo_color = Color(0.08, 0.085, 0.095)
	_mat_lot_asphalt.roughness = 0.38
	_mat_lot_asphalt.metallic = 0.1


# ==============================================================================
# 2. VULKAN FORWARD+ LIGHTING, VOLUMETRIC FOG & ACES ENVIRONMENT
# ==============================================================================
func _setup_atmosphere_and_lighting() -> void:
	var world_env := WorldEnvironment.new()
	world_env.name = "VulkanForwardPlusEnvironment"
	
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	
	# Procedural Dusk / Golden Hour into Night Sky
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.05, 0.04, 0.14) # Deep twilight indigo
	sky_mat.sky_horizon_color = Color(0.85, 0.28, 0.12) # Burning golden-hour orange/crimson
	sky_mat.sky_curve = 0.09
	sky_mat.ground_bottom_color = Color(0.02, 0.02, 0.04)
	sky_mat.ground_horizon_color = Color(0.42, 0.16, 0.18)
	sky_mat.sun_angle_max = 28.0
	sky_mat.sun_curve = 0.12
	
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	env.sky = sky
	
	# Ambient Rim & Sky Contribution
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color(0.28, 0.18, 0.45)
	env.ambient_light_sky_contribution = 0.65
	env.ambient_light_energy = 1.15
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	
	# ACES Tonemapping calibrated for glossy car paint & neon bloom
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.08
	env.tonemap_white = 6.0
	
	# Screen-Space Reflections (SSR) for glossy R34 paint & wet asphalt reflections
	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.2
	
	# SSAO & SSIL (Forward+ features)
	env.ssao_enabled = true
	env.ssao_radius = 1.5
	env.ssao_intensity = 2.2
	env.ssil_enabled = true
	env.ssil_radius = 4.0
	env.ssil_intensity = 1.0
	
	# Glow / Bloom for Neon Kanji Signs, Headlights, and Cat's-Eyes
	env.glow_enabled = true
	env.glow_normalized = true
	env.glow_intensity = 0.85
	env.glow_strength = 1.05
	env.glow_bloom = 0.18
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.set_glow_level(0, true)
	env.set_glow_level(1, true)
	env.set_glow_level(2, true)
	env.set_glow_level(4, true)
	
	# Volumetric Fog hugging the mountain ravines & valley floor
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.0045
	env.volumetric_fog_albedo = Color(0.22, 0.15, 0.32)
	env.volumetric_fog_emission = Color(0.12, 0.05, 0.14)
	env.volumetric_fog_emission_energy = 0.45
	env.volumetric_fog_anisotropy = 0.62
	env.volumetric_fog_length = 350.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_ambient_inject = 0.35
	
	world_env.environment = env
	add_child(world_env)
	
	# Low-Horizon Golden Hour Sun DirectionalLight3D
	var sun := DirectionalLight3D.new()
	sun.name = "DuskHorizonSun"
	sun.light_color = Color(1.0, 0.48, 0.22)
	sun.light_energy = 2.4
	sun.light_volumetric_fog_energy = 2.8
	sun.shadow_enabled = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.4
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 350.0
	sun.rotation_degrees = Vector3(-9.5, -135.0, 0.0) # Low on the horizon
	add_child(sun)
	
	# Deep Purple/Blue Rim Counter-Light (Moon/Twilight Sky Bounce)
	var rim_light := DirectionalLight3D.new()
	rim_light.name = "TwilightPurpleRimLight"
	rim_light.light_color = Color(0.38, 0.25, 0.85)
	rim_light.light_energy = 0.65
	rim_light.light_volumetric_fog_energy = 0.8
	rim_light.shadow_enabled = false
	rim_light.rotation_degrees = Vector3(-38.0, 45.0, 0.0)
	add_child(rim_light)
	
	# Dense Valley FogVolume at the base of the mountain ravines
	var valley_fog := FogVolume.new()
	valley_fog.name = "RavineHeightFogVolume"
	valley_fog.size = Vector3(2400.0, 110.0, 2400.0)
	valley_fog.position = Vector3(0.0, 35.0, 0.0)
	var fog_mat := FogMaterial.new()
	fog_mat.density = 0.018
	fog_mat.albedo = Color(0.35, 0.20, 0.45)
	fog_mat.emission = Color(0.25, 0.08, 0.20)
	fog_mat.height_falloff = 0.085
	fog_mat.edge_fade = 0.25
	valley_fog.material = fog_mat
	add_child(valley_fog)


# ==============================================================================
# 3. PROCEDURAL CATMULL-ROM / CUBIC BEZIER MOUNTAIN TOUGE SPLINE & BANKING
# ==============================================================================
func _generate_touge_curve() -> void:
	_curve.clear_points()
	_curve.bake_interval = spline_bake_interval
	
	# Multi-kilometer closed mountain touge loop:
	# Summit Starting Straight -> Sweeping S-Curves -> The 5 Consecutive Drift Hairpins (Akina style)
	# -> Valley High-Speed Wangan Blast -> Uphill Technical Switchbacks -> Summit Return
	var waypoints: PackedVector3Array = PackedVector3Array([
		# 0-2: Summit Observation Plateau & Starting Straight (Elevation ~160m)
		Vector3(0.0, 160.0, 0.0),
		Vector3(0.0, 159.0, -140.0),
		Vector3(25.0, 154.0, -280.0),
		
		# 3-6: High-Speed Sweeping S-Curves ("Kansei Drift" Section)
		Vector3(120.0, 144.0, -390.0),
		Vector3(40.0, 132.0, -520.0),
		Vector3(165.0, 120.0, -640.0),
		Vector3(280.0, 108.0, -720.0),
		
		# 7-9: Hairpin #1 (Right-hand Cliffside Overlook Turn)
		Vector3(390.0, 98.0, -680.0),
		Vector3(410.0, 91.0, -580.0),
		Vector3(290.0, 84.0, -530.0),
		
		# 10-12: Hairpin #2 (Left-hand Gutter-Run Switchback)
		Vector3(170.0, 76.0, -490.0),
		Vector3(145.0, 69.0, -395.0),
		Vector3(260.0, 62.0, -355.0),
		
		# 13-15: Hairpin #3 (Right-hand Tight Touge Hairpin)
		Vector3(420.0, 54.0, -320.0),
		Vector3(450.0, 47.0, -225.0),
		Vector3(310.0, 40.0, -185.0),
		
		# 16-18: Hairpin #4 (Left-hand Steep Drop Hairpin)
		Vector3(165.0, 33.0, -150.0),
		Vector3(140.0, 26.0, -55.0),
		Vector3(270.0, 20.0, -10.0),
		
		# 19-21: Hairpin #5 (Final Valley Floor Entry Hairpin)
		Vector3(410.0, 15.0, 35.0),
		Vector3(425.0, 12.0, 140.0),
		Vector3(290.0, 10.0, 210.0),
		
		# 22-25: Ravine Bridge & High-Speed Valley Chicanes
		Vector3(110.0, 12.0, 280.0),
		Vector3(-90.0, 18.0, 340.0),
		Vector3(-270.0, 32.0, 290.0),
		Vector3(-390.0, 52.0, 160.0),
		
		# 26-30: Uphill Return Touge Climb & Ridge S-Bends
		Vector3(-340.0, 76.0, 10.0),
		Vector3(-210.0, 98.0, -80.0),
		Vector3(-330.0, 120.0, -200.0),
		Vector3(-220.0, 140.0, -310.0),
		
		# 31-34: Final Summit Scenic Loop & Pit Entry back to Start Line
		# Generously separated from start straight (X >= -75m) to prevent any mountain clipping
		Vector3(-120.0, 152.0, -180.0),
		Vector3(-75.0, 157.0, -75.0),
		Vector3(-45.0, 159.0, 15.0),
		Vector3(-20.0, 160.0, 25.0)
	])
	
	var count: int = waypoints.size()
	var tension: float = 0.34 # Catmull-Rom handle smoothing factor
	
	for i in range(count):
		var p_prev: Vector3 = waypoints[(i - 1 + count) % count]
		var p_curr: Vector3 = waypoints[i]
		var p_next: Vector3 = waypoints[(i + 1) % count]
		
		var tangent_vec: Vector3 = (p_next - p_prev) * tension
		_curve.add_point(p_curr, -tangent_vec, tangent_vec)
	
	# Close the loop seamlessly back to waypoint 0
	var p_last: Vector3 = waypoints[count - 1]
	var p_first: Vector3 = waypoints[0]
	var p_second: Vector3 = waypoints[1]
	var first_tangent: Vector3 = (p_second - p_last) * tension
	_curve.add_point(p_first, -first_tangent, first_tangent)


func _sample_road_frames() -> void:
	var total_length: float = _curve.get_baked_length()
	var num_steps: int = int(ceil(total_length / spline_bake_interval))
	var step_dist: float = total_length / float(num_steps)
	
	# First pass: sample positions and horizontal tangents
	for i in range(num_steps):
		var d: float = float(i) * step_dist
		var pos: Vector3 = _curve.sample_baked(d, true)
		var d_ahead: float = fmod(d + 1.5, total_length)
		var d_behind: float = fmod(d - 1.5 + total_length, total_length)
		var pos_ahead: Vector3 = _curve.sample_baked(d_ahead, true)
		var pos_behind: Vector3 = _curve.sample_baked(d_behind, true)
		
		var tangent: Vector3 = (pos_ahead - pos_behind).normalized()
		if tangent.length_squared() < 0.001:
			tangent = Vector3.FORWARD
		
		var frame := RoadFrame.new()
		frame.position = pos
		frame.tangent = tangent
		frame.distance = d
		_frames.append(frame)
	
	# Second pass: compute signed horizontal curvature for superelevation (camber)
	var n_frames: int = _frames.size()
	var raw_curvatures: PackedFloat32Array = PackedFloat32Array()
	raw_curvatures.resize(n_frames)
	
	for i in range(n_frames):
		var f_prev: RoadFrame = _frames[(i - 2 + n_frames) % n_frames]
		var f_next: RoadFrame = _frames[(i + 2) % n_frames]
		
		var t1: Vector3 = Vector3(f_prev.tangent.x, 0.0, f_prev.tangent.z).normalized()
		var t2: Vector3 = Vector3(f_next.tangent.x, 0.0, f_next.tangent.z).normalized()
		var dt_vec: Vector3 = t2 - t1
		var cross_y: float = t1.cross(t2).y
		var sign_curv: float = signf(cross_y)
		var ds: float = step_dist * 4.0
		raw_curvatures[i] = sign_curv * (dt_vec.length() / maxf(ds, 0.001))
	
	# Third pass: Gaussian-like smoothing over curvature so banking transitions feel organic
	var max_bank_rad: float = deg_to_rad(max_bank_angle_deg)
	for i in range(n_frames):
		var avg_curv: float = 0.0
		var window: int = 6
		for w in range(-window, window + 1):
			avg_curv += raw_curvatures[(i + w + n_frames) % n_frames]
		avg_curv /= float(window * 2 + 1)
		
		var frame: RoadFrame = _frames[i]
		frame.curvature = avg_curv
		# Tilt road inward proportional to curvature
		frame.bank_angle = clampf(avg_curv * curvature_bank_scale, -max_bank_rad, max_bank_rad)
		
		# Construct orthogonal frame with inward banking rotation around forward tangent
		var flat_right: Vector3 = frame.tangent.cross(Vector3.UP).normalized()
		if flat_right.length_squared() < 0.001:
			flat_right = Vector3.RIGHT
		var base_up: Vector3 = flat_right.cross(frame.tangent).normalized()
		
		var bank_Basis := Basis(frame.tangent, -frame.bank_angle)
		frame.binormal = (bank_Basis * flat_right).normalized() # Points Right across road
		frame.normal = (bank_Basis * base_up).normalized()      # Banked Up vector
	
	# Save Spawn Transform at Summit Starting Grid (Frame 2)
	if n_frames > 4:
		var start_f: RoadFrame = _frames[2]
		var spawn_basis := Basis(start_f.binormal, start_f.normal, -start_f.tangent).orthonormalized()
		_spawn_transform = Transform3D(spawn_basis, start_f.position + start_f.normal * 0.48)


# ==============================================================================
# 4. PROCEDURAL ROAD, GUTTER & MOUNTAIN CLIFF MESH + DOUBLE-SIDED COLLISION
# ==============================================================================
func _build_road_and_retaining_mesh() -> void:
	var st_road := SurfaceTool.new()
	st_road.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var st_cliffs := SurfaceTool.new()
	st_cliffs.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var st_walls := SurfaceTool.new()
	st_walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Cross-section profile offsets (X = lateral from center, Y = vertical from road plane)
	# Includes left & right playable U-gutters for the "gutter run" technique!
	var half_road: float = road_width * 0.5
	var g_inner: float = half_road + shoulder_width
	var g_outer: float = g_inner + gutter_width
	
	var road_profile_x: PackedFloat32Array = PackedFloat32Array([
		-g_outer,          # 0: Left outer gutter lip
		-g_outer,          # 1: Left gutter outer bottom
		-g_inner,          # 2: Left gutter inner bottom
		-g_inner,          # 3: Left shoulder edge
		-half_road * 0.5,  # 4: Left lane center
		0.0,               # 5: Crown center (slight 6cm drainage camber crown)
		half_road * 0.5,   # 6: Right lane center
		g_inner,           # 7: Right shoulder edge
		g_inner,           # 8: Right gutter inner bottom
		g_outer,           # 9: Right gutter outer bottom
		g_outer            # 10: Right outer gutter lip
	])
	
	var road_profile_y: PackedFloat32Array = PackedFloat32Array([
		0.04,              # 0: Left outer curb lip
		-gutter_depth,     # 1: Left gutter bottom
		-gutter_depth,     # 2: Left gutter bottom
		0.0,               # 3: Left shoulder
		0.035,             # 4: Left lane
		0.06,              # 5: Road center crown
		0.035,             # 6: Right lane
		0.0,               # 7: Right shoulder
		-gutter_depth,     # 8: Right gutter bottom
		-gutter_depth,     # 9: Right gutter bottom
		0.04               # 10: Right outer curb lip
	])
	
	var road_profile_u: PackedFloat32Array = PackedFloat32Array([
		0.0, 0.03, 0.07, 0.10, 0.30, 0.50, 0.70, 0.90, 0.93, 0.97, 1.0
	])
	
	var p_count: int = road_profile_x.size()
	var n_frames: int = _frames.size()
	
	# Precompute 3D vertices for each cross-section ring
	var road_rings: Array[PackedVector3Array] = []
	var left_cliff_rings: Array[PackedVector3Array] = []
	var right_cliff_rings: Array[PackedVector3Array] = []
	
	for i in range(n_frames):
		var f: RoadFrame = _frames[i]
		var ring := PackedVector3Array()
		ring.resize(p_count)
		for p in range(p_count):
			ring[p] = f.position + f.binormal * road_profile_x[p] + f.normal * road_profile_y[p]
		road_rings.append(ring)
		
		# Determine which side is mountain wall vs drop-off ravine with smooth continuous blending
		var radial_dir: Vector3 = Vector3(f.position.x, 0.0, f.position.z).normalized()
		var left_dot: float = (-f.binormal).dot(radial_dir)
		# Continuous blend factor to eliminate abrupt 87m vertical tears/spikes across quad seams
		var mountain_on_left: float = clampf(( -left_dot + 0.35 ) / 0.7, 0.0, 1.0)
		var mountain_on_right: float = 1.0 - mountain_on_left

		# Left side continuous terrain profile
		var l_base: Vector3 = ring[0]
		var l_wall_h: float = lerpf(-1.2, 5.0, mountain_on_left)
		var l_rock_h: float = lerpf(-14.0, 15.0, mountain_on_left)
		var l_peak_h: float = lerpf(-38.0, 26.0, mountain_on_left)
		var l_wall_top: Vector3 = l_base - f.binormal * 1.0 + Vector3.UP * l_wall_h
		var l_rock_mid: Vector3 = l_wall_top - f.binormal * 7.0 + Vector3.UP * (l_rock_h - l_wall_h)
		var l_rock_peak: Vector3 = l_rock_mid - f.binormal * 16.0 + Vector3.UP * (l_peak_h - l_rock_h)
		left_cliff_rings.append(PackedVector3Array([l_base, l_wall_top, l_rock_mid, l_rock_peak]))

		# Right side continuous terrain profile
		var r_base: Vector3 = ring[p_count - 1]
		var r_wall_h: float = lerpf(-1.2, 5.0, mountain_on_right)
		var r_rock_h: float = lerpf(-14.0, 15.0, mountain_on_right)
		var r_peak_h: float = lerpf(-38.0, 26.0, mountain_on_right)
		var r_wall_top: Vector3 = r_base + f.binormal * 1.0 + Vector3.UP * r_wall_h
		var r_rock_mid: Vector3 = r_wall_top + f.binormal * 7.0 + Vector3.UP * (r_rock_h - r_wall_h)
		var r_rock_peak: Vector3 = r_rock_mid + f.binormal * 16.0 + Vector3.UP * (r_peak_h - r_rock_h)
		right_cliff_rings.append(PackedVector3Array([r_base, r_wall_top, r_rock_mid, r_rock_peak]))
	
	# Stitch Road & Gutter Quads
	for i in range(n_frames):
		var next_i: int = (i + 1) % n_frames
		var r_curr: PackedVector3Array = road_rings[i]
		var r_next: PackedVector3Array = road_rings[next_i]
		
		var v0: float = _frames[i].distance * 0.2
		var v1: float = (_frames[i].distance + spline_bake_interval) * 0.2
		var n_curr: Vector3 = _frames[i].normal
		var n_next: Vector3 = _frames[next_i].normal
		
		for p in range(p_count - 1):
			var p00: Vector3 = r_curr[p]
			var p10: Vector3 = r_curr[p + 1]
			var p01: Vector3 = r_next[p]
			var p11: Vector3 = r_next[p + 1]
			
			var u0: float = road_profile_u[p]
			var u1: float = road_profile_u[p + 1]
			
			# Triangle 1
			st_road.set_normal(n_curr)
			st_road.set_uv(Vector2(u0, v0))
			st_road.add_vertex(p00)
			
			st_road.set_normal(n_curr)
			st_road.set_uv(Vector2(u1, v0))
			st_road.add_vertex(p10)
			
			st_road.set_normal(n_next)
			st_road.set_uv(Vector2(u1, v1))
			st_road.add_vertex(p11)
			
			# Triangle 2
			st_road.set_normal(n_curr)
			st_road.set_uv(Vector2(u0, v0))
			st_road.add_vertex(p00)
			
			st_road.set_normal(n_next)
			st_road.set_uv(Vector2(u1, v1))
			st_road.add_vertex(p11)
			
			st_road.set_normal(n_next)
			st_road.set_uv(Vector2(u0, v1))
			st_road.add_vertex(p01)
		
		# Stitch Left & Right Retaining Walls (segment 0->1) & Rock Cliffs (segments 1->3)
		var lc_curr: PackedVector3Array = left_cliff_rings[i]
		var lc_next: PackedVector3Array = left_cliff_rings[next_i]
		var rc_curr: PackedVector3Array = right_cliff_rings[i]
		var rc_next: PackedVector3Array = right_cliff_rings[next_i]
		
		_add_quad_to_st(st_walls, lc_curr[1], lc_curr[0], lc_next[0], lc_next[1])
		_add_quad_to_st(st_walls, rc_curr[0], rc_curr[1], rc_next[1], rc_next[0])
		
		for c_idx in range(1, 3):
			_add_quad_to_st(st_cliffs, lc_curr[c_idx + 1], lc_curr[c_idx], lc_next[c_idx], lc_next[c_idx + 1])
			_add_quad_to_st(st_cliffs, rc_curr[c_idx], rc_curr[c_idx + 1], rc_next[c_idx + 1], rc_next[c_idx])
	
	st_road.generate_tangents()
	var road_mesh: ArrayMesh = st_road.commit()
	
	st_walls.generate_normals()
	var walls_mesh: ArrayMesh = st_walls.commit()
	
	st_cliffs.generate_normals()
	var cliffs_mesh: ArrayMesh = st_cliffs.commit()
	
	# Create Road MeshInstance3D + Double-Sided Backface Collision StaticBody3D
	var road_mi := MeshInstance3D.new()
	road_mi.name = "TougeAsphaltAndGutters"
	road_mi.mesh = road_mesh
	road_mi.material_override = _mat_road
	add_child(road_mi)
	
	var road_body := StaticBody3D.new()
	road_body.name = "RoadTrimeshCollider"
	var road_col := CollisionShape3D.new()
	var concave_road := road_mesh.create_trimesh_shape()
	# Critical spec: enable backface collision so wheels never fall through on hard compression
	concave_road.backface_collision = true
	road_col.shape = concave_road
	road_body.add_child(road_col)
	road_mi.add_child(road_body)
	
	# Create Concrete Retaining Walls MeshInstance3D + Collision
	var walls_mi := MeshInstance3D.new()
	walls_mi.name = "RetainingConcreteWalls"
	walls_mi.mesh = walls_mesh
	walls_mi.material_override = _mat_gutter_wall
	add_child(walls_mi)
	
	var walls_body := StaticBody3D.new()
	var walls_col := CollisionShape3D.new()
	var concave_walls := walls_mesh.create_trimesh_shape()
	concave_walls.backface_collision = true
	walls_col.shape = concave_walls
	walls_body.add_child(walls_col)
	walls_mi.add_child(walls_body)
	
	# Create Mountain Rock Cliffs MeshInstance3D
	var cliffs_mi := MeshInstance3D.new()
	cliffs_mi.name = "MountainRockFaces"
	cliffs_mi.mesh = cliffs_mesh
	cliffs_mi.material_override = _mat_rock_cliff
	add_child(cliffs_mi)


func _add_quad_to_st(st: SurfaceTool, p00: Vector3, p10: Vector3, p11: Vector3, p01: Vector3) -> void:
	st.set_uv(Vector2(0, 0))
	st.add_vertex(p00)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(p10)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(p11)
	
	st.set_uv(Vector2(0, 0))
	st.add_vertex(p00)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(p11)
	st.set_uv(Vector2(0, 1))
	st.add_vertex(p01)


# ==============================================================================
# 5. CONTINUOUS 3D GALVANIZED STEEL W-BEAM GUARDRAILS & SUPPORT POSTS
# ==============================================================================
func _build_w_beam_guardrails() -> void:
	var st_rail := SurfaceTool.new()
	st_rail.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var st_collider := SurfaceTool.new()
	st_collider.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var post_transforms: Array[Transform3D] = []
	
	# W-Beam cross-section profile (height: 0.45m to 0.82m above road edge)
	var w_heights: PackedFloat32Array = PackedFloat32Array([0.45, 0.53, 0.635, 0.74, 0.82])
	var w_depths: PackedFloat32Array = PackedFloat32Array([0.0, 0.09, -0.02, 0.09, 0.0])
	var w_count: int = w_heights.size()
	
	var rail_offset_x: float = (road_width * 0.5) + shoulder_width + gutter_width + 0.12
	var n_frames: int = _frames.size()
	var post_accum_dist: float = 0.0
	
	for i in range(n_frames):
		var next_i: int = (i + 1) % n_frames
		var f0: RoadFrame = _frames[i]
		var f1: RoadFrame = _frames[next_i]
		
		# Place guardrails on both outer edges (skip the summit parking lot entrance on left at frames 0..6)
		for side in [-1.0, 1.0]:
			if side < 0.0 and (i < 7 or i > n_frames - 5):
				continue
			
			var base0: Vector3 = f0.position + f0.binormal * (side * rail_offset_x)
			var base1: Vector3 = f1.position + f1.binormal * (side * rail_offset_x)
			var inward0: Vector3 = -f0.binormal * side
			var inward1: Vector3 = -f1.binormal * side
			
			# Extrude W-beam corrugated profile
			for w in range(w_count - 1):
				var p00: Vector3 = base0 + f0.normal * w_heights[w] + inward0 * w_depths[w]
				var p10: Vector3 = base0 + f0.normal * w_heights[w + 1] + inward0 * w_depths[w + 1]
				var p11: Vector3 = base1 + f1.normal * w_heights[w + 1] + inward1 * w_depths[w + 1]
				var p01: Vector3 = base1 + f1.normal * w_heights[w] + inward1 * w_depths[w]
				
				_add_quad_to_st(st_rail, p00, p10, p11, p01)
			
			# Add clean vertical collision wall for smooth vehicle scraping physics
			var col_b0: Vector3 = base0
			var col_t0: Vector3 = base0 + f0.normal * 1.15
			var col_t1: Vector3 = base1 + f1.normal * 1.15
			var col_b1: Vector3 = base1
			_add_quad_to_st(st_collider, col_b0, col_t0, col_t1, col_b1)
			
			# Support posts every `guardrail_post_spacing` meters
			if post_accum_dist >= guardrail_post_spacing:
				var post_pos: Vector3 = base0 - inward0 * 0.06 + f0.normal * 0.42
				var post_basis := Basis(f0.binormal, f0.normal, -f0.tangent).orthonormalized()
				post_transforms.append(Transform3D(post_basis, post_pos))
		
		if post_accum_dist >= guardrail_post_spacing:
			post_accum_dist = 0.0
		post_accum_dist += spline_bake_interval
	
	st_rail.generate_normals()
	var rail_mesh: ArrayMesh = st_rail.commit()
	
	var rail_mi := MeshInstance3D.new()
	rail_mi.name = "WBeamGuardrails"
	rail_mi.mesh = rail_mesh
	rail_mi.material_override = _mat_guardrail
	add_child(rail_mi)
	
	# Guardrail Physics Collider
	var col_mesh: ArrayMesh = st_collider.commit()
	var rail_body := StaticBody3D.new()
	rail_body.name = "GuardrailPhysicsBody"
	var rail_col := CollisionShape3D.new()
	var rail_shape := col_mesh.create_trimesh_shape()
	rail_shape.backface_collision = true
	rail_col.shape = rail_shape
	rail_body.add_child(rail_col)
	rail_mi.add_child(rail_body)
	
	# Instanced Galvanized Support Posts via MultiMeshInstance3D
	var post_mmi := MultiMeshInstance3D.new()
	post_mmi.name = "GuardrailSupportPosts"
	var post_mm := MultiMesh.new()
	post_mm.transform_format = MultiMesh.TRANSFORM_3D
	var post_box := BoxMesh.new()
	post_box.size = Vector3(0.12, 0.88, 0.12)
	post_box.material = _mat_guardrail
	post_mm.mesh = post_box
	post_mm.instance_count = post_transforms.size()
	for idx in range(post_transforms.size()):
		post_mm.set_instance_transform(idx, post_transforms[idx])
	post_mmi.multimesh = post_mm
	add_child(post_mmi)


# ==============================================================================
# 6. REFLECTIVE ROAD CAT'S-EYES STUDS (CENTER AMBER & SHOULDER RED/WHITE)
# ==============================================================================
func _build_reflective_cats_eyes() -> void:
	var center_transforms: Array[Transform3D] = []
	var edge_transforms: Array[Transform3D] = []
	
	var half_road: float = road_width * 0.5
	var accum: float = 0.0
	
	for f in _frames:
		accum += spline_bake_interval
		if accum >= reflector_stud_spacing:
			accum = 0.0
			var basis := Basis(f.binormal, f.normal, -f.tangent).orthonormalized()
			
			# Center line amber cat's-eye stud
			center_transforms.append(Transform3D(basis, f.position + f.normal * 0.07))
			
			# Left & Right white/red outer shoulder studs
			edge_transforms.append(Transform3D(basis, f.position - f.binormal * (half_road + 0.15) + f.normal * 0.02))
			edge_transforms.append(Transform3D(basis, f.position + f.binormal * (half_road + 0.15) + f.normal * 0.02))
	
	var stud_mesh := BoxMesh.new()
	stud_mesh.size = Vector3(0.14, 0.035, 0.14)
	
	# Center Amber Studs MultiMesh
	var mat_amber := StandardMaterial3D.new()
	mat_amber.albedo_color = Color(1.0, 0.65, 0.05)
	mat_amber.emission_enabled = true
	mat_amber.emission = Color(1.0, 0.55, 0.0)
	mat_amber.emission_energy_multiplier = 3.2
	
	var center_mmi := MultiMeshInstance3D.new()
	center_mmi.name = "CenterCatsEyesStuds"
	var center_mm := MultiMesh.new()
	center_mm.transform_format = MultiMesh.TRANSFORM_3D
	center_mm.mesh = stud_mesh
	center_mm.instance_count = center_transforms.size()
	for i in range(center_transforms.size()):
		center_mm.set_instance_transform(i, center_transforms[i])
	center_mmi.multimesh = center_mm
	center_mmi.material_override = mat_amber
	add_child(center_mmi)
	
	# Outer Shoulder Studs MultiMesh
	var mat_edge := StandardMaterial3D.new()
	mat_edge.albedo_color = Color(0.95, 0.25, 0.15)
	mat_edge.emission_enabled = true
	mat_edge.emission = Color(1.0, 0.30, 0.20)
	mat_edge.emission_energy_multiplier = 2.4
	
	var edge_mmi := MultiMeshInstance3D.new()
	edge_mmi.name = "ShoulderCatsEyesStuds"
	var edge_mm := MultiMesh.new()
	edge_mm.transform_format = MultiMesh.TRANSFORM_3D
	edge_mm.mesh = stud_mesh
	edge_mm.instance_count = edge_transforms.size()
	for i in range(edge_transforms.size()):
		edge_mm.set_instance_transform(i, edge_transforms[i])
	edge_mmi.multimesh = edge_mm
	edge_mmi.material_override = mat_edge
	add_child(edge_mmi)


# ==============================================================================
# 7. SUMMIT OBSERVATION PARKING LOT & STARTING GRID
# ==============================================================================
func _build_summit_parking_lot() -> void:
	if _frames.is_empty():
		return
	
	var f_start: RoadFrame = _frames[1]
	var lot_root := Node3D.new()
	lot_root.name = "SummitObservationParkingLot"
	var lot_basis := Basis(f_start.binormal, f_start.normal, -f_start.tangent).orthonormalized()
	lot_root.transform = Transform3D(lot_basis, f_start.position - f_start.binormal * 24.0 - f_start.normal * 0.12)
	add_child(lot_root)
	
	# Paved Observation Deck Slab + Static Collision
	var lot_slab := MeshInstance3D.new()
	var slab_mesh := BoxMesh.new()
	slab_mesh.size = Vector3(34.0, 1.0, 64.0)
	lot_slab.mesh = slab_mesh
	lot_slab.position = Vector3(0.0, -0.5, 0.0)
	lot_slab.material_override = _mat_lot_asphalt
	lot_root.add_child(lot_slab)
	
	var slab_body := StaticBody3D.new()
	var slab_col := CollisionShape3D.new()
	var slab_shape := BoxShape3D.new()
	slab_shape.size = slab_mesh.size
	slab_col.shape = slab_shape
	slab_body.add_child(slab_col)
	lot_slab.add_child(slab_body)
	
	# Glowing Japanese Vending Machines Row (Classic Touge Meet Spot)
	var vending_colors: Array[Color] = [
		Color(0.95, 0.15, 0.18), # Red Boss/Coke style
		Color(0.12, 0.48, 1.0),  # Blue Pocari/Calpis style
		Color(0.95, 0.95, 0.98), # White Green Tea style
		Color(1.0, 0.55, 0.08)   # Warm Hot Coffee style
	]
	
	for v_idx in range(vending_colors.size()):
		var vm := MeshInstance3D.new()
		var vm_box := BoxMesh.new()
		vm_box.size = Vector3(1.15, 2.1, 0.85)
		vm.mesh = vm_box
		vm.position = Vector3(-13.5, 1.05, -12.0 + float(v_idx) * 2.6)
		vm.rotation_degrees = Vector3(0.0, 90.0, 0.0)
		
		var vm_mat := StandardMaterial3D.new()
		vm_mat.albedo_color = vending_colors[v_idx]
		vm_mat.emission_enabled = true
		vm_mat.emission = vending_colors[v_idx]
		vm_mat.emission_energy_multiplier = 2.1
		vm.material_override = vm_mat
		lot_root.add_child(vm)
	
	# Starting Grid Banner & Staging Box on the Main Road
	var grid_marker := Marker3D.new()
	grid_marker.name = "StartingGridSpawnPoint"
	grid_marker.global_transform = _spawn_transform
	add_child(grid_marker)


# ==============================================================================
# 8. CYBERPUNK / JDM INFRASTRUCTURE: NEON KANJI GANTRIES & TORII GATES
# ==============================================================================
func _build_landmarks_and_props() -> void:
	var n_frames: int = _frames.size()
	if n_frames < 20:
		return
	
	# A. Overhead Neon Kanji Highway Gantries at key Touge sectors
	var gantry_configs: Array[Dictionary] = [
		{"frame_idx": 3, "kanji": "秋名山 峠 START", "sub": "MT. AKINA TOUGE SUMMIT", "color": Color(0.0, 0.92, 1.0)},
		{"frame_idx": int(n_frames * 0.28), "kanji": "連続ヘアピン注意", "sub": "DANGER: 5 CONSECUTIVE HAIRPINS", "color": Color(1.0, 0.12, 0.48)},
		{"frame_idx": int(n_frames * 0.58), "kanji": "溝落とし区間", "sub": "GUTTER RUN TECHNICAL SECTOR", "color": Color(1.0, 0.65, 0.05)},
		{"frame_idx": int(n_frames * 0.84), "kanji": "最高速アタック", "sub": "UPHILL HILLCLIMB SECTOR", "color": Color(0.35, 1.0, 0.45)}
	]
	
	for cfg in gantry_configs:
		var idx: int = clampi(cfg["frame_idx"], 0, n_frames - 1)
		_create_neon_kanji_gantry(_frames[idx], cfg["kanji"], cfg["sub"], cfg["color"])
	
	# B. Traditional Japanese Red Torii Gates at High Scenic Hairpins & Overlooks
	for i in range(n_frames):
		var f: RoadFrame = _frames[i]
		# Place Torii arches at sharp curvature peaks and scenic mountain ridges
		if (absf(f.curvature) > 0.032 and i % 16 == 0) or (i % 65 == 25):
			_create_torii_gate(f)
	
	# C. Sodium-Vapor JDM Mountain Streetlights along the Touge
	var light_accum: float = 0.0
	for i in range(n_frames):
		light_accum += spline_bake_interval
		if light_accum >= street_light_spacing:
			light_accum = 0.0
			_create_touge_streetlight(_frames[i])


func _create_neon_kanji_gantry(frame: RoadFrame, kanji_text: String, sub_text: String, neon_color: Color) -> void:
	var gantry := Node3D.new()
	gantry.name = "NeonKanjiGantry"
	var basis := Basis(frame.binormal, frame.normal, -frame.tangent).orthonormalized()
	gantry.transform = Transform3D(basis, frame.position)
	add_child(gantry)
	
	var span_half: float = (road_width * 0.5) + shoulder_width + gutter_width + 0.8
	var height: float = 6.8
	
	# Left & Right Steel Truss Pillars
	for side in [-1.0, 1.0]:
		var pillar := MeshInstance3D.new()
		var p_mesh := CylinderMesh.new()
		p_mesh.top_radius = 0.24
		p_mesh.bottom_radius = 0.28
		p_mesh.height = height
		pillar.mesh = p_mesh
		pillar.position = Vector3(side * span_half, height * 0.5, 0.0)
		pillar.material_override = _mat_gantry_steel
		gantry.add_child(pillar)
	
	# Overhead Cross-Beam
	var beam := MeshInstance3D.new()
	var b_mesh := BoxMesh.new()
	b_mesh.size = Vector3(span_half * 2.0 + 0.8, 0.55, 0.55)
	beam.mesh = b_mesh
	beam.position = Vector3(0.0, height - 0.3, 0.0)
	beam.material_override = _mat_gantry_steel
	gantry.add_child(beam)
	
	# Signboard Backing Plate
	var board := MeshInstance3D.new()
	var board_mesh := BoxMesh.new()
	board_mesh.size = Vector3(road_width * 0.95, 2.1, 0.22)
	board.mesh = board_mesh
	board.position = Vector3(0.0, height - 0.4, 0.25)
	
	var board_mat := StandardMaterial3D.new()
	board_mat.albedo_color = Color(0.03, 0.05, 0.08)
	board_mat.emission_enabled = true
	board_mat.emission = neon_color * 0.25
	board_mat.roughness = 0.2
	board.material_override = board_mat
	gantry.add_child(board)
	
	# Glowing Neon Border Tube
	var border := MeshInstance3D.new()
	var border_mesh := BoxMesh.new()
	border_mesh.size = Vector3(road_width * 0.97, 2.22, 0.14)
	border.mesh = border_mesh
	border.position = Vector3(0.0, height - 0.4, 0.22)
	var neon_mat := StandardMaterial3D.new()
	neon_mat.albedo_color = neon_color
	neon_mat.emission_enabled = true
	neon_mat.emission = neon_color
	neon_mat.emission_energy_multiplier = 4.2
	border.material_override = neon_mat
	gantry.add_child(border)
	
	# 3D Glowing Kanji Lettering (Label3D)
	var label_kanji := Label3D.new()
	label_kanji.text = kanji_text
	label_kanji.font_size = 96
	label_kanji.outline_size = 18
	label_kanji.modulate = neon_color.lightened(0.35)
	label_kanji.outline_modulate = neon_color
	label_kanji.position = Vector3(0.0, height - 0.15, 0.42)
	gantry.add_child(label_kanji)
	
	var label_sub := Label3D.new()
	label_sub.text = sub_text
	label_sub.font_size = 42
	label_sub.modulate = Color(0.95, 0.95, 1.0)
	label_sub.position = Vector3(0.0, height - 0.95, 0.42)
	gantry.add_child(label_sub)
	
	# Neon Spill OmniLight3D onto the wet asphalt below
	var neon_light := OmniLight3D.new()
	neon_light.light_color = neon_color
	neon_light.light_energy = 3.2
	neon_light.light_volumetric_fog_energy = 2.5
	neon_light.omni_range = 22.0
	neon_light.position = Vector3(0.0, height - 1.5, 1.2)
	gantry.add_child(neon_light)


func _create_torii_gate(frame: RoadFrame) -> void:
	var torii := Node3D.new()
	torii.name = "TraditionalToriiGate"
	var basis := Basis(frame.binormal, frame.normal, -frame.tangent).orthonormalized()
	torii.transform = Transform3D(basis, frame.position)
	add_child(torii)
	
	var pillar_x: float = (road_width * 0.5) + shoulder_width + gutter_width + 0.55
	var pillar_h: float = 7.4
	
	# Left & Right Pillars (Hashira) with Black Base Pedestals (Kamebara)
	for side in [-1.0, 1.0]:
		var base_pedestal := MeshInstance3D.new()
		var base_cyl := CylinderMesh.new()
		base_cyl.top_radius = 0.46
		base_cyl.bottom_radius = 0.52
		base_cyl.height = 1.1
		base_pedestal.mesh = base_cyl
		base_pedestal.position = Vector3(side * pillar_x, 0.55, 0.0)
		base_pedestal.material_override = _mat_torii_black
		torii.add_child(base_pedestal)
		
		var pillar := MeshInstance3D.new()
		var p_cyl := CylinderMesh.new()
		p_cyl.top_radius = 0.34
		p_cyl.bottom_radius = 0.38
		p_cyl.height = pillar_h
		pillar.mesh = p_cyl
		pillar.position = Vector3(side * pillar_x, pillar_h * 0.5, 0.0)
		pillar.material_override = _mat_torii_red
		torii.add_child(pillar)
	
	# Top Lintel (Kasagi - Black Cap + Vermilion Shimagi)
	var kasagi_red := MeshInstance3D.new()
	var k_box := BoxMesh.new()
	k_box.size = Vector3(pillar_x * 2.0 + 3.6, 0.52, 0.72)
	kasagi_red.mesh = k_box
	kasagi_red.position = Vector3(0.0, pillar_h + 0.1, 0.0)
	kasagi_red.material_override = _mat_torii_red
	torii.add_child(kasagi_red)
	
	var kasagi_black := MeshInstance3D.new()
	var kb_box := BoxMesh.new()
	kb_box.size = Vector3(pillar_x * 2.0 + 4.1, 0.28, 0.84)
	kasagi_black.mesh = kb_box
	kasagi_black.position = Vector3(0.0, pillar_h + 0.48, 0.0)
	kasagi_black.material_override = _mat_torii_black
	torii.add_child(kasagi_black)
	
	# Lower Tie Beam (Nuki)
	var nuki := MeshInstance3D.new()
	var n_box := BoxMesh.new()
	n_box.size = Vector3(pillar_x * 2.0 + 2.2, 0.38, 0.45)
	nuki.mesh = n_box
	nuki.position = Vector3(0.0, pillar_h - 1.35, 0.0)
	nuki.material_override = _mat_torii_red
	torii.add_child(nuki)
	
	# Center Strut Plaque (Gakuzuka)
	var gakuzuka := MeshInstance3D.new()
	var g_box := BoxMesh.new()
	g_box.size = Vector3(0.65, 1.35, 0.52)
	gakuzuka.mesh = g_box
	gakuzuka.position = Vector3(0.0, pillar_h - 0.6, 0.0)
	gakuzuka.material_override = _mat_torii_black
	torii.add_child(gakuzuka)


func _create_touge_streetlight(frame: RoadFrame) -> void:
	var pole := Node3D.new()
	pole.name = "TougeStreetLight"
	var basis := Basis(frame.binormal, frame.normal, -frame.tangent).orthonormalized()
	var x_offset: float = (road_width * 0.5) + shoulder_width + gutter_width + 0.35
	pole.transform = Transform3D(basis, frame.position + frame.binormal * x_offset)
	add_child(pole)
	
	var post_mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.09
	cyl.bottom_radius = 0.13
	cyl.height = 6.2
	post_mi.mesh = cyl
	post_mi.position = Vector3(0.0, 3.1, 0.0)
	post_mi.material_override = _mat_gantry_steel
	pole.add_child(post_mi)
	
	var arm_mi := MeshInstance3D.new()
	var arm_box := BoxMesh.new()
	arm_box.size = Vector3(2.2, 0.1, 0.1)
	arm_mi.mesh = arm_box
	arm_mi.position = Vector3(-1.0, 6.1, 0.0)
	arm_mi.material_override = _mat_gantry_steel
	pole.add_child(arm_mi)
	
	# Warm Amber Sodium-Vapor SpotLight3D
	var spot := SpotLight3D.new()
	spot.light_color = Color(1.0, 0.68, 0.28)
	spot.light_energy = 4.2
	spot.light_volumetric_fog_energy = 2.0
	spot.spot_range = 24.0
	spot.spot_angle = 58.0
	spot.position = Vector3(-1.95, 5.95, 0.0)
	spot.rotation_degrees = Vector3(-82.0, 0.0, 0.0)
	pole.add_child(spot)


# ==============================================================================
# 9. GPUPARTICLES3D CHERRY BLOSSOM (SAKURA) PETALS WITH VEHICLE TURBULENCE
# ==============================================================================
func _build_sakura_particle_systems() -> void:
	var n_frames: int = _frames.size()
	if n_frames == 0 or sakura_emitters_count <= 0:
		return
	
	# Shared ParticleProcessMaterial with Turbulence enabled for aerodynamic wake
	var proc_mat := ParticleProcessMaterial.new()
	proc_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc_mat.emission_box_extents = Vector3(22.0, 10.0, 28.0)
	proc_mat.direction = Vector3(-0.4, -1.0, 0.3)
	proc_mat.spread = 42.0
	proc_mat.initial_velocity_min = 1.6
	proc_mat.initial_velocity_max = 3.8
	proc_mat.gravity = Vector3(0.6, -1.35, -0.4)
	proc_mat.angular_velocity_min = -140.0
	proc_mat.angular_velocity_max = 140.0
	proc_mat.damping_min = 0.4
	proc_mat.damping_max = 1.2
	
	# Enable GPU Turbulence so petals swirl in the mountain wind & vehicle slipstream
	proc_mat.turbulence_enabled = true
	proc_mat.turbulence_noise_strength = 4.5
	proc_mat.turbulence_noise_scale = 3.2
	proc_mat.turbulence_noise_speed = Vector3(0.8, -0.4, 0.8)
	proc_mat.turbulence_influence_min = 0.25
	proc_mat.turbulence_influence_max = 0.65
	proc_mat.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	
	var petal_quad := QuadMesh.new()
	petal_quad.size = Vector2(0.16, 0.11)
	petal_quad.material = _mat_sakura_petal
	
	var step: int = maxi(1, n_frames / sakura_emitters_count)
	for idx in range(0, n_frames, step):
		var f: RoadFrame = _frames[idx]
		var particles := GPUParticles3D.new()
		particles.name = "SakuraBlossomEmitter_%d" % idx
		particles.position = f.position + Vector3(0.0, 8.5, 0.0)
		particles.amount = 320
		particles.lifetime = 8.0
		particles.preprocess = 2.0
		particles.visibility_aabb = AABB(Vector3(-45, -25, -45), Vector3(90, 50, 90))
		particles.process_material = proc_mat
		particles.draw_pass_1 = petal_quad
		add_child(particles)


func _build_roadside_props_decorator() -> void:
	var decorator := AkinaRoadsidePropsDecorator.new()
	decorator.name = "AkinaRoadsidePropsDecorator"
	add_child(decorator)
	decorator.decorate_touge(_curve, [])


# ==============================================================================
# 10. VEHICLE SPAWN & ARCADE CHASE CAMERA INTEGRATION
# ==============================================================================
func _spawn_player_vehicle() -> void:
	if not ResourceLoader.exists(vehicle_scene_path):
		push_warning("MountAkinaTouge: Vehicle scene not found at '%s'. Creating fallback preview camera." % vehicle_scene_path)
		_create_fallback_overview_camera()
		return
	
	var vehicle_packed: PackedScene = load(vehicle_scene_path) as PackedScene
	if vehicle_packed == null:
		return
	
	_spawned_vehicle = vehicle_packed.instantiate() as Node3D
	if _spawned_vehicle == null:
		return
	
	_spawned_vehicle.name = "AE86_PANDA_TRUENO"
	_spawned_vehicle.add_to_group("player")
	_spawned_vehicle.add_to_group("vehicle")
	add_child(_spawned_vehicle)
	if _referee_mgr != null and _referee_mgr.has_method("set_target_vehicle"):
		_referee_mgr.call("set_target_vehicle", _spawned_vehicle)
	if _atmosphere_mgr != null and _atmosphere_mgr.has_method("set_target_vehicle"):
		_atmosphere_mgr.call("set_target_vehicle", _spawned_vehicle)
	
	# Attach Initial D Anime Car VFX (Taillight ribbons, cel smoke, backfire, sparks)
	var anime_vfx_script := load("res://InitialDAnimeCarVFX.gd")
	if anime_vfx_script != null:
		var vfx_inst = anime_vfx_script.new()
		vfx_inst.name = "InitialDAnimeCarVFX"
		_spawned_vehicle.add_child(vfx_inst)
		if "target_vehicle" in vfx_inst:
			vfx_inst.set("target_vehicle", _spawned_vehicle)

	# Attach Itasha Anime Girl Livery (Hood & Side Door Decals)
	var itasha_script := load("res://ItashaAnimeGirlLivery.gd")
	if itasha_script != null and itasha_script.has_method("attach_to_car"):
		itasha_script.call("attach_to_car", _spawned_vehicle)
	_spawned_vehicle.global_transform = _spawn_transform
	if _spawned_vehicle.has_method("set_spawn_transform"):
		_spawned_vehicle.call("set_spawn_transform", _spawn_transform)
	
	# Attach GPUParticlesAttractorSphere3D to the R34 so falling Sakura petals swirl in its wake
	var wake_attractor := GPUParticlesAttractorSphere3D.new()
	wake_attractor.name = "VehicleAerodynamicWake"
	wake_attractor.radius = 9.5
	wake_attractor.strength = -14.0 # Repels and swirls cherry blossoms as the car blasts through
	wake_attractor.attenuation = 0.6
	_spawned_vehicle.add_child(wake_attractor)
	
	# Hook into existing ArcadeChaseCamera.gd if not already present inside Vehicle.tscn
	var existing_cam: Camera3D = _find_camera_recursive(_spawned_vehicle)
	if existing_cam != null:
		existing_cam.make_current()
	elif ResourceLoader.exists(chase_camera_script_path):
		var cam_script: Script = load(chase_camera_script_path) as Script
		if cam_script != null:
			var chase_cam := Camera3D.new()
			chase_cam.name = "ArcadeChaseCamera"
			chase_cam.set_script(cam_script)
			add_child(chase_cam)
			chase_cam.global_transform = _spawn_transform.translated_local(Vector3(0.0, 2.2, 5.5))
			chase_cam.make_current()
			
			# Bind target property or setter method dynamically
			if "target" in chase_cam:
				chase_cam.set("target", _spawned_vehicle)
			elif "target_node" in chase_cam:
				chase_cam.set("target_node", _spawned_vehicle)
			elif "vehicle" in chase_cam:
				chase_cam.set("vehicle", _spawned_vehicle)
			elif chase_cam.has_method("set_target"):
				chase_cam.call("set_target", _spawned_vehicle)
	
	# Attach JDM Drift VFX System (Tire smoke, skidmarks, exhaust anti-lag)
	var vfx_script: Script = load("res://JDMDriftVFXSystem.gd")
	if vfx_script != null:
		var vfx: Node3D = vfx_script.new() as Node3D
		if vfx != null:
			vfx.name = "JDMDriftVFXSystem"
			vfx.set("vehicle", _spawned_vehicle)
			_spawned_vehicle.add_child(vfx)

	# Legacy analog speedometer removed in favor of Initial D Digital Cluster HUD
	# var hud_script: Script = load("res://JDMSpeedometerHUD.gd")
	# if hud_script != null:
	# 	var hud: CanvasLayer = hud_script.new() as CanvasLayer
	# 	if hud != null:
	# 		hud.name = "JDMSpeedometerHUD"
	# 		hud.set("target_vehicle", _spawned_vehicle)
	# 		add_child(hud)


func _find_camera_recursive(node: Node) -> Camera3D:
	if node is Camera3D:
		return node as Camera3D
	for child in node.get_children():
		var found: Camera3D = _find_camera_recursive(child)
		if found != null:
			return found
	return null


func _create_fallback_overview_camera() -> void:
	var cam := Camera3D.new()
	cam.name = "TougePreviewCamera"
	cam.global_transform = _spawn_transform.translated_local(Vector3(0.0, 3.5, 9.0))
	cam.look_at(_spawn_transform.origin + _spawn_transform.basis.z * -20.0, Vector3.UP)
	add_child(cam)
	cam.make_current()


# ==============================================================================
# 11. DESKTOP WINDOW UI/UX, KEYBOARD CONTROLS GUIDE & PAUSE MENU
# ==============================================================================
var _ui_layer: CanvasLayer = null
var _speed_val_label: Label = null
var _gear_val_label: Label = null
var _rpm_bar: ProgressBar = null
var _pause_panel: Control = null
var _is_paused: bool = false

func _setup_desktop_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "DesktopCanvasLayer"
	_ui_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_ui_layer)

	var root_control := Control.new()
	root_control.name = "UIRoot"
	root_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(root_control)

	# 1. Top-Right Window Controls (Close X & Fullscreen)
	var top_bar := HBoxContainer.new()
	top_bar.name = "TopRightDesktopBar"
	top_bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	top_bar.offset_left = -260
	top_bar.offset_top = 16
	top_bar.offset_right = -16
	top_bar.offset_bottom = 56
	top_bar.alignment = BoxContainer.ALIGNMENT_END
	top_bar.add_theme_constant_override("separation", 10)
	root_control.add_child(top_bar)

	var btn_fs := Button.new()
	btn_fs.text = " [ ⛶ F11 ] "
	btn_fs.custom_minimum_size = Vector2(90, 36)
	btn_fs.pressed.connect(_toggle_fullscreen)
	top_bar.add_child(btn_fs)

	var btn_close := Button.new()
	btn_close.text = "  ✕  "
	btn_close.custom_minimum_size = Vector2(44, 36)
	btn_close.modulate = Color(1.0, 0.4, 0.4)
	btn_close.pressed.connect(func(): get_tree().quit())
	top_bar.add_child(btn_close)

	# 2. Bottom-Left Controls Guide Overlay
	var guide_panel := PanelContainer.new()
	guide_panel.name = "ControlsGuidePanel"
	guide_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	guide_panel.offset_left = 24
	guide_panel.offset_top = -140
	guide_panel.offset_right = 380
	guide_panel.offset_bottom = -24
	var guide_style := StyleBoxFlat.new()
	guide_style.bg_color = Color(0.04, 0.05, 0.08, 0.78)
	guide_style.set_corner_radius_all(8)
	guide_style.border_color = Color(0.18, 0.35, 0.65, 0.5)
	guide_style.set_border_width_all(1)
	guide_style.content_margin_left = 14
	guide_style.content_margin_top = 10
	guide_style.content_margin_right = 14
	guide_style.content_margin_bottom = 10
	guide_panel.add_theme_stylebox_override("panel", guide_style)
	root_control.add_child(guide_panel)

	var guide_vbox := VBoxContainer.new()
	guide_panel.add_child(guide_vbox)

	var guide_title := Label.new()
	guide_title.text = "JDM CONTROLS MANUAL"
	guide_title.add_theme_color_override("font_color", Color(0.2, 0.7, 1.0))
	guide_title.add_theme_font_size_override("font_size", 12)
	guide_vbox.add_child(guide_title)

	var guide_text := Label.new()
	guide_text.text = "[W / ↑] Throttle  [S / ↓] Brake  [A D / ← →] Steer  [SPACE] Drift\n[H] Pop-Up Lights  [F2] Anime  [F3] Referee HUD  [F4] Fill Cup  [TAB] Net"
	guide_text.add_theme_color_override("font_color", Color(0.85, 0.88, 0.94))
	guide_text.add_theme_font_size_override("font_size", 12)
	guide_vbox.add_child(guide_text)

	# 4. Pause Menu (ESC Overlay)
	_pause_panel = PanelContainer.new()
	_pause_panel.name = "PauseMenuOverlay"
	_pause_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var pause_bg := StyleBoxFlat.new()
	pause_bg.bg_color = Color(0.02, 0.03, 0.05, 0.88)
	_pause_panel.add_theme_stylebox_override("panel", pause_bg)
	_pause_panel.visible = false
	root_control.add_child(_pause_panel)

	var pause_center := CenterContainer.new()
	pause_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_panel.add_child(pause_center)

	var pause_box := VBoxContainer.new()
	pause_box.custom_minimum_size = Vector2(340, 300)
	pause_box.add_theme_constant_override("separation", 16)
	pause_center.add_child(pause_box)

	var pause_title := Label.new()
	pause_title.text = "MOUNT AKINA TOUGE"
	pause_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pause_title.add_theme_font_size_override("font_size", 28)
	pause_title.add_theme_color_override("font_color", Color(1.0, 0.4, 0.15))
	pause_box.add_child(pause_title)

	var pause_sub := Label.new()
	pause_sub.text = "GAME PAUSED"
	pause_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pause_sub.add_theme_font_size_override("font_size", 14)
	pause_sub.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	pause_box.add_child(pause_sub)

	var btn_resume := Button.new()
	btn_resume.text = "RESUME"
	btn_resume.custom_minimum_size = Vector2(0, 44)
	btn_resume.pressed.connect(_toggle_pause)
	pause_box.add_child(btn_resume)

	var btn_restart := Button.new()
	btn_restart.text = "RESTART TO START LINE (R)"
	btn_restart.custom_minimum_size = Vector2(0, 44)
	btn_restart.pressed.connect(func():
		_toggle_pause()
		if _spawned_vehicle != null and _spawned_vehicle.has_method("respawn"):
			_spawned_vehicle.call("respawn")
		elif _spawned_vehicle != null:
			_spawned_vehicle.global_transform = _spawn_transform
			if _spawned_vehicle is RigidBody3D:
				(_spawned_vehicle as RigidBody3D).linear_velocity = Vector3.ZERO
				(_spawned_vehicle as RigidBody3D).angular_velocity = Vector3.ZERO
	)
	pause_box.add_child(btn_restart)

	var btn_gfx := Button.new()
	btn_gfx.text = "GRAPHICS & ENGINE SETTINGS (O)"
	btn_gfx.custom_minimum_size = Vector2(0, 44)
	btn_gfx.pressed.connect(func():
		if _gfx_manager != null:
			_gfx_manager.toggle_menu()
	)
	pause_box.add_child(btn_gfx)

	var btn_fs_menu := Button.new()
	btn_fs_menu.text = "TOGGLE FULLSCREEN (F11)"
	btn_fs_menu.custom_minimum_size = Vector2(0, 44)
	btn_fs_menu.pressed.connect(_toggle_fullscreen)
	pause_box.add_child(btn_fs_menu)

	var btn_exit := Button.new()
	btn_exit.text = "EXIT TO DESKTOP"
	btn_exit.custom_minimum_size = Vector2(0, 44)
	btn_exit.modulate = Color(1.0, 0.4, 0.4)
	btn_exit.pressed.connect(func(): get_tree().quit())
	pause_box.add_child(btn_exit)


func _process(_delta: float) -> void:
	if _digital_cluster != null and is_instance_valid(_digital_cluster) and _spawned_vehicle != null and is_instance_valid(_spawned_vehicle):
		var speed: float = 0.0
		var rpm: float = 800.0
		var max_rpm: float = 9000.0
		var gear: int = 1
		var throttle: float = 0.0
		var brake: float = 0.0

		if "speed_kmh" in _spawned_vehicle:
			speed = float(_spawned_vehicle.get("speed_kmh"))
		elif _spawned_vehicle is RigidBody3D:
			speed = (_spawned_vehicle as RigidBody3D).linear_velocity.length() * 3.6

		if "engine_rpm" in _spawned_vehicle:
			rpm = float(_spawned_vehicle.get("engine_rpm"))

		if "redline_rpm" in _spawned_vehicle:
			max_rpm = float(_spawned_vehicle.get("redline_rpm"))

		if "is_reversing" in _spawned_vehicle and bool(_spawned_vehicle.get("is_reversing")):
			gear = -1
		elif "gear_number" in _spawned_vehicle:
			gear = int(_spawned_vehicle.get("gear_number"))

		if "throttle_input" in _spawned_vehicle:
			throttle = float(_spawned_vehicle.get("throttle_input"))
		else:
			throttle = Input.get_action_strength("accelerate")

		if "brake_input" in _spawned_vehicle:
			brake = float(_spawned_vehicle.get("brake_input"))
		else:
			brake = Input.get_action_strength("brake")

		var drift_angle_deg: float = 0.0
		var in_gutter: bool = false
		if _referee_mgr != null and is_instance_valid(_referee_mgr):
			if _referee_mgr.has_method("get_drift_angle_deg"):
				drift_angle_deg = float(_referee_mgr.call("get_drift_angle_deg"))
			if _referee_mgr.has_method("is_gutter_hooked"):
				in_gutter = bool(_referee_mgr.call("is_gutter_hooked"))

		_digital_cluster.update_telemetry(speed, rpm, max_rpm, gear, throttle, brake, drift_angle_deg, in_gutter)

	if _speed_val_label != null and _spawned_vehicle != null and is_instance_valid(_spawned_vehicle):
		var spd_val: float = float(_spawned_vehicle.get("speed_kmh")) if "speed_kmh" in _spawned_vehicle else 0.0
		_speed_val_label.text = str(int(round(spd_val)))


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event := event as InputEventKey
		if key_event.physical_keycode == KEY_F11:
			_toggle_fullscreen()
		elif key_event.physical_keycode == KEY_ESCAPE:
			_toggle_pause()


func _toggle_fullscreen() -> void:
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)


func _toggle_pause() -> void:
	_is_paused = not _is_paused
	get_tree().paused = _is_paused
	if _pause_panel != null:
		_pause_panel.visible = _is_paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _is_paused else Input.MOUSE_MODE_VISIBLE