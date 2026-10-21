@tool
class_name R34SkylineModeler
extends Node3D
## Procedural 3D Modeler for Nissan Skyline GT-R (BNR34) - Godot 4.3 Vulkan Forward+
## Builds an authentic, multi-material procedural mesh hierarchy with reactive lighting
## and separated wheel/caliper assemblies ready for VehicleBody3D or custom raycast physics.

# ==============================================================================
# EXPORTED CONFIGURATION & REACTIVE CONTROLS
# ==============================================================================
@export_group("Modeler Controls")
@export var rebuild_model: bool = false:
	set(value):
		if value:
			generate_vehicle()
		rebuild_model = false

@export_group("Paint & Aesthetics")
@export var body_color: Color = Color(0.04, 0.18, 0.65, 1.0): # Iconic TV2 Bayside Blue
	set(value):
		body_color = value
		if _mat_body:
			_mat_body.albedo_color = body_color

@export var rim_color: Color = Color(0.18, 0.16, 0.14, 1.0): # Nismo Bronze / Gunmetal
	set(value):
		rim_color = value
		if _mat_rim:
			_mat_rim.albedo_color = rim_color

@export_group("Lighting State (Vulkan Bloom)")
@export var is_braking: bool = false:
	set(value):
		is_braking = value
		_update_lighting_state()

@export var headlights_on: bool = true:
	set(value):
		headlights_on = value
		_update_lighting_state()

var _spot_l: SpotLight3D = null
var _spot_r: SpotLight3D = null

@export var is_reversing: bool = false:
	set(value):
		is_reversing = value
		_update_lighting_state()

@export var hazard_lights: bool = false:
	set(value):
		hazard_lights = value
		_update_lighting_state()

# ==============================================================================
# SPECIFICATIONS (BNR34 Exact Proportions in Meters)
# ==============================================================================
const LENGTH: float = 4.600
const WIDTH: float = 1.785
const HEIGHT: float = 1.360
const WHEELBASE: float = 2.665
const TRACK_WIDTH: float = 1.480

# Coordinate system: -Z is Forward, +Z is Rear, +Y is Up, +X is Right
const FRONT_AXLE_Z: float = -WHEELBASE * 0.5 # -1.3325m
const REAR_AXLE_Z: float = WHEELBASE * 0.5   # +1.3325m
const WHEEL_RADIUS: float = 0.335
const TIRE_WIDTH: float = 0.265
const RIM_RADIUS: float = 0.235

# ==============================================================================
# NODE ANCHORS (Exposed for Physics Controller Integration)
# ==============================================================================
var WheelFL: Node3D
var WheelFR: Node3D
var WheelRL: Node3D
var WheelRR: Node3D
var ChassisRoot: Node3D

# ==============================================================================
# INTERNAL MATERIALS
# ==============================================================================
var _mat_body: StandardMaterial3D
var _mat_carbon_matte: StandardMaterial3D
var _mat_glass: StandardMaterial3D
var _mat_headlight_glass: StandardMaterial3D
var _mat_chrome: StandardMaterial3D
var _mat_intercooler: StandardMaterial3D
var _mat_rim: StandardMaterial3D
var _mat_tire: StandardMaterial3D
var _mat_rotor: StandardMaterial3D
var _mat_caliper: StandardMaterial3D
var _mat_taillight_halo: StandardMaterial3D
var _mat_headlight_xenon: StandardMaterial3D
var _mat_reverse_light: StandardMaterial3D
var _mat_indicator_light: StandardMaterial3D
var _mat_underglow_well: StandardMaterial3D

var _blink_timer: float = 0.0

# ==============================================================================
# LIFECYCLE
# ==============================================================================
func _ready() -> void:
	generate_vehicle()

func _process(delta: float) -> void:
	if hazard_lights and _mat_indicator_light:
		_blink_timer += delta * 6.0
		var blink_on: bool = sin(_blink_timer) > 0.0
		_mat_indicator_light.emission_energy_multiplier = 5.5 if blink_on else 0.0

# ==============================================================================
# MASTER GENERATION PIPELINE
# ==============================================================================
func generate_vehicle() -> void:
	_clear_existing_children()
	_init_materials()

	ChassisRoot = Node3D.new()
	ChassisRoot.name = "ChassisRoot"
	add_child(ChassisRoot)
	_set_owner_safe(ChassisRoot)

	# 1. Build Main Sculpted Body & Glasshouse
	_build_chassis_body(ChassisRoot)

	# 2. Build Aero Trim, Splitter, Skirts, Diffuser & Intercooler
	_build_aero_and_trim(ChassisRoot)

	# 3. Build Trunk Double-Blade GT Wing & Mirrors
	_build_gt_wing(ChassisRoot)
	_build_side_mirrors(ChassisRoot)

	# 4. Build Exhaust Cannon
	_build_exhaust_system(ChassisRoot)

	# 5. Build Signature R34 Lighting (Quad Halos + Projectors)
	_build_lighting_assemblies(ChassisRoot)

	# 6. Build 4 Corner Wheels & Running Gear
	WheelFL = _create_wheel_anchor("WheelFL", Vector3(-TRACK_WIDTH * 0.5, WHEEL_RADIUS, FRONT_AXLE_Z), true, true)
	WheelFR = _create_wheel_anchor("WheelFR", Vector3(TRACK_WIDTH * 0.5, WHEEL_RADIUS, FRONT_AXLE_Z), false, true)
	WheelRL = _create_wheel_anchor("WheelRL", Vector3(-TRACK_WIDTH * 0.5, WHEEL_RADIUS, REAR_AXLE_Z), true, false)
	WheelRR = _create_wheel_anchor("WheelRR", Vector3(TRACK_WIDTH * 0.5, WHEEL_RADIUS, REAR_AXLE_Z), false, false)

	_update_lighting_state()

func _clear_existing_children() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

func _set_owner_safe(node: Node) -> void:
	if Engine.is_editor_hint() and is_inside_tree() and get_tree().edited_scene_root:
		node.owner = get_tree().edited_scene_root

# ==============================================================================
# 4. MULTI-LAYER REALISTIC JDM CAR PAINT & PBR MATERIALS
# ==============================================================================
func _init_materials() -> void:
	# Bayside Blue Metallic Clearcoat Paint
	_mat_body = StandardMaterial3D.new()
	_mat_body.name = "BaysideBlue_Paint"
	_mat_body.albedo_color = body_color
	_mat_body.metallic = 0.90
	_mat_body.metallic_specular = 0.75
	_mat_body.roughness = 0.18
	_mat_body.clearcoat_enabled = true
	_mat_body.clearcoat = 1.0
	_mat_body.clearcoat_roughness = 0.05
	_mat_body.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Matte Black Trim (Splitter, Diffuser, Pillars, Wiper Cowl)
	_mat_carbon_matte = StandardMaterial3D.new()
	_mat_carbon_matte.name = "MatteBlack_Trim"
	_mat_carbon_matte.albedo_color = Color(0.06, 0.06, 0.07, 1.0)
	_mat_carbon_matte.metallic = 0.15
	_mat_carbon_matte.roughness = 0.78
	_mat_carbon_matte.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Tinted Tempered Glass
	_mat_glass = StandardMaterial3D.new()
	_mat_glass.name = "Tempered_Glass"
	_mat_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_glass.albedo_color = Color(0.05, 0.08, 0.11, 0.25)
	_mat_glass.metallic = 0.85
	_mat_glass.roughness = 0.06
	_mat_glass.clearcoat_enabled = true
	_mat_glass.clearcoat = 1.0
	_mat_glass.clearcoat_roughness = 0.02
	_mat_glass.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Clear Polycarbonate Headlight Lens
	_mat_headlight_glass = StandardMaterial3D.new()
	_mat_headlight_glass.name = "Headlight_Lens"
	_mat_headlight_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_headlight_glass.albedo_color = Color(0.85, 0.92, 1.0, 0.18)
	_mat_headlight_glass.metallic = 0.9
	_mat_headlight_glass.roughness = 0.03

	# Chrome Exhaust & Projector Bezel
	_mat_chrome = StandardMaterial3D.new()
	_mat_chrome.name = "JDM_Chrome"
	_mat_chrome.albedo_color = Color(0.92, 0.94, 0.98, 1.0)
	_mat_chrome.metallic = 1.0
	_mat_chrome.roughness = 0.06

	# Front-Mount Intercooler Core (Brushed Aluminum Fins)
	_mat_intercooler = StandardMaterial3D.new()
	_mat_intercooler.name = "Aluminum_Intercooler"
	_mat_intercooler.albedo_color = Color(0.68, 0.72, 0.76, 1.0)
	_mat_intercooler.metallic = 0.85
	_mat_intercooler.roughness = 0.35

	# Nismo Alloy Rims
	_mat_rim = StandardMaterial3D.new()
	_mat_rim.name = "Nismo_Alloy"
	_mat_rim.albedo_color = rim_color
	_mat_rim.metallic = 0.88
	_mat_rim.roughness = 0.22
	_mat_rim.clearcoat_enabled = true
	_mat_rim.clearcoat = 0.6

	# High-Performance Rubber Tire
	_mat_tire = StandardMaterial3D.new()
	_mat_tire.name = "Potenza_Rubber"
	_mat_tire.albedo_color = Color(0.08, 0.08, 0.09, 1.0)
	_mat_tire.metallic = 0.05
	_mat_tire.roughness = 0.86

	# Drilled Steel Brake Rotor
	_mat_rotor = StandardMaterial3D.new()
	_mat_rotor.name = "Drilled_Steel_Rotor"
	_mat_rotor.albedo_color = Color(0.55, 0.57, 0.60, 1.0)
	_mat_rotor.metallic = 0.92
	_mat_rotor.roughness = 0.28

	# Golden Brembo Brake Caliper
	_mat_caliper = StandardMaterial3D.new()
	_mat_caliper.name = "Brembo_Gold"
	_mat_caliper.albedo_color = Color(0.85, 0.58, 0.08, 1.0)
	_mat_caliper.metallic = 0.85
	_mat_caliper.roughness = 0.20
	_mat_caliper.clearcoat_enabled = true
	_mat_caliper.clearcoat = 0.9

	# Wheel Arch Blackout Lining
	_mat_underglow_well = StandardMaterial3D.new()
	_mat_underglow_well.name = "WheelWell_Liner"
	_mat_underglow_well.albedo_color = Color(0.02, 0.02, 0.02, 1.0)
	_mat_underglow_well.roughness = 0.95

	# Emissive Taillight Halo (Vulkan Glow > 4.0)
	_mat_taillight_halo = StandardMaterial3D.new()
	_mat_taillight_halo.name = "Taillight_Halo_Emissive"
	_mat_taillight_halo.albedo_color = Color(0.9, 0.05, 0.05, 1.0)
	_mat_taillight_halo.emission_enabled = true
	_mat_taillight_halo.emission = Color(1.0, 0.04, 0.02, 1.0)
	_mat_taillight_halo.emission_energy_multiplier = 4.5

	# Emissive Xenon Headlight & DRL
	_mat_headlight_xenon = StandardMaterial3D.new()
	_mat_headlight_xenon.name = "Headlight_Xenon_Emissive"
	_mat_headlight_xenon.albedo_color = Color(0.9, 0.96, 1.0, 1.0)
	_mat_headlight_xenon.emission_enabled = true
	_mat_headlight_xenon.emission = Color(0.78, 0.90, 1.0, 1.0)
	_mat_headlight_xenon.emission_energy_multiplier = 5.2

	# Emissive Reverse Lights
	_mat_reverse_light = StandardMaterial3D.new()
	_mat_reverse_light.name = "Reverse_Emissive"
	_mat_reverse_light.albedo_color = Color(0.85, 0.85, 0.9, 1.0)
	_mat_reverse_light.emission_enabled = true
	_mat_reverse_light.emission = Color(0.95, 0.95, 1.0, 1.0)
	_mat_reverse_light.emission_energy_multiplier = 0.0

	# Emissive Amber Turn Indicators
	_mat_indicator_light = StandardMaterial3D.new()
	_mat_indicator_light.name = "Indicator_Amber"
	_mat_indicator_light.albedo_color = Color(0.95, 0.45, 0.02, 1.0)
	_mat_indicator_light.emission_enabled = true
	_mat_indicator_light.emission = Color(1.0, 0.42, 0.0, 1.0)
	_mat_indicator_light.emission_energy_multiplier = 0.8

func _update_lighting_state() -> void:
	if _mat_taillight_halo:
		if is_braking:
			_mat_taillight_halo.emission = Color(1.0, 0.08, 0.04, 1.0)
			_mat_taillight_halo.emission_energy_multiplier = 9.5 # Intense stoplight red
		else:
			_mat_taillight_halo.emission = Color(1.0, 0.03, 0.01, 1.0)
			_mat_taillight_halo.emission_energy_multiplier = 4.5 # Running halo glow

	if _mat_headlight_xenon:
		_mat_headlight_xenon.emission_energy_multiplier = 5.5 if headlights_on else 0.4
	if _spot_l:
		_spot_l.visible = headlights_on
	if _spot_r:
		_spot_r.visible = headlights_on

	if _mat_reverse_light:
		_mat_reverse_light.emission_energy_multiplier = 4.5 if is_reversing else 0.0

	if _mat_indicator_light and not hazard_lights:
		_mat_indicator_light.emission_energy_multiplier = 0.8

# ==============================================================================
# 1. GEOMETRIC SILHOUETTE: LOFTED WIDEBODY CHASSIS & GLASSHOUSE
# ==============================================================================
# Cross-section stations along the Z axis (-2.30m Front to +2.30m Rear)
# Each station defines:
# [z, bottom_y, belt_y, deck_y, cabin_top_y, half_width_bottom, half_width_fender, half_width_deck, half_width_cabin, is_glass]
func _get_body_stations() -> Array:
	return [
		# Front Bumper Nose & Lip
		[-2.30, 0.14, 0.46, 0.62, 0.62, 0.76, 0.81, 0.72, 0.56, false],
		[-2.18, 0.13, 0.50, 0.69, 0.69, 0.82, 0.86, 0.78, 0.64, false],
		# Front Wheel Arch & Widebody Blister Fender (-1.70 to -0.95)
		[-1.72, 0.15, 0.56, 0.74, 0.74, 0.85, 0.892, 0.81, 0.68, false],
		[-1.33, 0.22, 0.62, 0.78, 0.78, 0.86, 0.892, 0.82, 0.70, false],
		[-0.94, 0.14, 0.60, 0.81, 0.81, 0.85, 0.892, 0.81, 0.71, false],
		# Base of Windshield / Wiper Cowl
		[-0.78, 0.14, 0.60, 0.84, 0.84, 0.84, 0.865, 0.80, 0.72, false],
		# A-Pillar Rise to Front Roof Header (Glasshouse active)
		[-0.22, 0.14, 0.62, 0.87, 1.33, 0.84, 0.860, 0.79, 0.63, true],
		# Mid-Cabin / B-Pillar Peak (Height: 1.36m)
		[ 0.35, 0.14, 0.64, 0.89, 1.36, 0.84, 0.865, 0.80, 0.63, true],
		# Rear Roof Header / C-Pillar Top
		[ 0.82, 0.14, 0.66, 0.91, 1.32, 0.85, 0.885, 0.82, 0.61, true],
		# Base of Rear Window / Rear Quarter Widebody Swell Begins
		[ 0.98, 0.15, 0.67, 0.92, 1.24, 0.86, 0.892, 0.83, 0.64, true],
		# Rear Widebody Fender Arch (+0.98 to +1.70)
		[ 1.33, 0.22, 0.68, 0.94, 0.94, 0.86, 0.892, 0.83, 0.72, false],
		[ 1.72, 0.16, 0.66, 0.93, 0.93, 0.85, 0.892, 0.81, 0.70, false],
		# Trunk Deck & Muscular Rear Haunches
		[ 2.15, 0.20, 0.62, 0.90, 0.90, 0.81, 0.855, 0.77, 0.66, false],
		# Flat Iconic R34 Tailgate Fascia
		[ 2.30, 0.24, 0.60, 0.88, 0.88, 0.76, 0.810, 0.74, 0.62, false]
	]

func _build_chassis_body(parent: Node3D) -> void:
	var stations: Array = _get_body_stations()
	var st_paint := SurfaceTool.new()
	st_paint.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_glass := SurfaceTool.new()
	st_glass.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_trim := SurfaceTool.new()
	st_trim.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Generate perimeter ring points for each station
	# Profile points per station (8 points from bottom-center out to roof-center):
	# 0: Bottom Center (x=0)
	# 1: Rocker Bottom Edge
	# 2: Widebody Fender Bulge / Mid-Waist
	# 3: Shoulder / Beltline Deck Edge
	# 4: Hood/Trunk Inner Step or Glass Base
	# 5: Cabin Roof Rail / Hood Power Bulge
	# 6: Top Center (x=0)
	var rings_right: Array = []
	var rings_left: Array = []

	for i in range(stations.size()):
		var s: Array = stations[i]
		var z: float = s[0]
		var bot_y: float = s[1]
		var belt_y: float = s[2]
		var deck_y: float = s[3]
		var top_y: float = s[4]
		var hw_bot: float = s[5]
		var hw_fend: float = s[6]
		var hw_deck: float = s[7]
		var hw_cab: float = s[8]

		# Add subtle NACA/Hood line contour on front hood
		var center_top_y: float = top_y
		if z < -0.75 and z > -2.15:
			center_top_y += 0.018 # Subtle RB26 hood bulge
		elif z >= -0.22 and z <= 0.82:
			center_top_y += 0.015 # Roof crown

		var pts_r: Array[Vector3] = [
			Vector3(0.0, bot_y, z),
			Vector3(hw_bot, bot_y, z),
			Vector3(hw_fend, belt_y, z),
			Vector3(hw_deck, deck_y, z),
			Vector3(hw_cab, top_y, z),
			Vector3(0.0, center_top_y, z)
		]
		var pts_l: Array[Vector3] = [
			Vector3(0.0, bot_y, z),
			Vector3(-hw_bot, bot_y, z),
			Vector3(-hw_fend, belt_y, z),
			Vector3(-hw_deck, deck_y, z),
			Vector3(-hw_cab, top_y, z),
			Vector3(0.0, center_top_y, z)
		]
		rings_right.append(pts_r)
		rings_left.append(pts_l)

	# Loft adjacent stations
	for i in range(stations.size() - 1):
		var r0: Array[Vector3] = rings_right[i]
		var r1: Array[Vector3] = rings_right[i + 1]
		var l0: Array[Vector3] = rings_left[i]
		var l1: Array[Vector3] = rings_left[i + 1]

		var seg_is_glass: bool = stations[i][9] and stations[i + 1][9]
		# Windshield is between station 5 (-0.78) and 6 (-0.22)
		var is_windshield: bool = (i == 5)
		# Rear window is between station 8 (0.82) and 10 (1.33)
		var is_rear_glass: bool = (i == 8 or i == 9)

		for j in range(5):
			# Determine which SurfaceTool receives this quad strip
			var target_st: SurfaceTool = st_paint
			if j == 3: # Greenhouse / Window slope segment (between deck_y and top_y)
				if seg_is_glass or is_windshield or is_rear_glass:
					target_st = st_glass
			elif j == 0: # Underbody floor pan
				target_st = st_trim

			# Right side quad (r0[j], r1[j], r1[j+1], r0[j+1])
			_add_quad(target_st, r0[j], r0[j + 1], r1[j + 1], r1[j])
			# Left side quad (mirrored winding)
			_add_quad(target_st, l0[j + 1], l0[j], l1[j], l1[j + 1])

	# Close Front Fascia Nose Cap (Station 0)
	var f_r: Array[Vector3] = rings_right[0]
	var f_l: Array[Vector3] = rings_left[0]
	for j in range(5):
		var st_target: SurfaceTool = st_trim if j <= 1 else st_paint
		_add_quad(st_target, f_l[j], f_r[j], f_r[j + 1], f_l[j + 1])

	# Close Rear Tailgate Fascia Cap (Last Station)
	var b_idx: int = stations.size() - 1
	var b_r: Array[Vector3] = rings_right[b_idx]
	var b_l: Array[Vector3] = rings_left[b_idx]
	for j in range(5):
		var st_target: SurfaceTool = st_trim if j == 0 else st_paint
		_add_quad(st_target, b_r[j], b_l[j], b_l[j + 1], b_r[j + 1])

	# Add Sculpted A, B, and C Roof Pillars in Matte/Body Paint over Glass Edges
	_build_pillars_and_frames(st_paint, st_trim, rings_right, rings_left)

	# Commit Meshes
	_commit_surface_to_node(st_paint, "BodyShell_BaysideBlue", _mat_body, parent)
	_commit_surface_to_node(st_glass, "CabinGlasshouse", _mat_glass, parent)
	_commit_surface_to_node(st_trim, "UnderbodyAndPillars", _mat_carbon_matte, parent)

	# Add Wheel Arch Blackout Cavities so gaps behind wheels look deep and realistic
	_build_wheel_wells(parent)

func _build_pillars_and_frames(st_paint: SurfaceTool, st_trim: SurfaceTool, rings_r: Array, rings_l: Array) -> void:
	# A-Pillars (Station 5 to 6)
	_add_pillar_beam(st_paint, rings_r[5][3], rings_r[6][4], 0.045, 0.025)
	_add_pillar_beam(st_paint, rings_l[5][3], rings_l[6][4], 0.045, 0.025)

	# B-Pillars (Station 7 vertical door post in matte black)
	_add_pillar_beam(st_trim, rings_r[7][3], rings_r[7][4], 0.055, 0.015)
	_add_pillar_beam(st_trim, rings_l[7][3], rings_l[7][4], 0.055, 0.015)

	# C-Pillars (Thick iconic R34 Hofmeister-style rear quarter pillar: Station 8 to 10)
	_add_pillar_beam(st_paint, rings_r[8][4], rings_r[10][3], 0.095, 0.030)
	_add_pillar_beam(st_paint, rings_l[8][4], rings_l[10][3], 0.095, 0.030)

	# Wiper Cowl Panel at base of windshield
	_add_box_to_st(st_trim, Vector3(0.0, 0.835, -0.78), Vector3(1.42, 0.03, 0.14))

func _build_wheel_wells(parent: Node3D) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var positions: Array[Vector3] = [
		Vector3(-0.70, WHEEL_RADIUS, FRONT_AXLE_Z),
		Vector3( 0.70, WHEEL_RADIUS, FRONT_AXLE_Z),
		Vector3(-0.70, WHEEL_RADIUS, REAR_AXLE_Z),
		Vector3( 0.70, WHEEL_RADIUS, REAR_AXLE_Z)
	]
	for pos in positions:
		_add_cylinder_to_st(st, pos, 0.37, 0.34, 16, Vector3.RIGHT)
	_commit_surface_to_node(st, "WheelWells", _mat_underglow_well, parent)

# ==============================================================================
# 2. FRONT SPLITTER, INTERCOOLER MOUTH, SIDE SKIRTS & REAR DIFFUSER
# ==============================================================================
func _build_aero_and_trim(parent: Node3D) -> void:
	var st_trim := SurfaceTool.new()
	st_trim.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_ic := SurfaceTool.new()
	st_ic.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_paint := SurfaceTool.new()
	st_paint.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Aggressive Lower Front Splitter Lip (protruding forward at -2.35m)
	_add_box_to_st(st_trim, Vector3(0.0, 0.115, -2.26), Vector3(1.74, 0.040, 0.26))
	# Splitter Side Canards / End Fences
	_add_box_to_st(st_trim, Vector3(-0.87, 0.16, -2.24), Vector3(0.025, 0.11, 0.22))
	_add_box_to_st(st_trim, Vector3( 0.87, 0.16, -2.24), Vector3(0.025, 0.11, 0.22))

	# Iconic R34 Lower Intercooler Intake Mouth Housing (Recessed Black Surround)
	_add_box_to_st(st_trim, Vector3(0.0, 0.28, -2.285), Vector3(0.96, 0.25, 0.08))

	# Front-Mount Aluminum Intercooler Core + Horizontal Cooling Fin Louvers
	_add_box_to_st(st_ic, Vector3(0.0, 0.28, -2.295), Vector3(0.86, 0.21, 0.07))
	for fin in range(6):
		var fin_y: float = 0.20 + float(fin) * 0.032
		_add_box_to_st(st_trim, Vector3(0.0, fin_y, -2.332), Vector3(0.86, 0.006, 0.01))

	# Flanking Brake Duct Intakes on Front Bumper
	_add_box_to_st(st_trim, Vector3(-0.66, 0.27, -2.27), Vector3(0.26, 0.16, 0.08))
	_add_box_to_st(st_trim, Vector3( 0.66, 0.27, -2.27), Vector3(0.26, 0.16, 0.08))

	# Upper Grille Mesh Slot & GT-R Badge Plinth between Headlights
	_add_box_to_st(st_trim, Vector3(0.0, 0.55, -2.28), Vector3(0.74, 0.085, 0.08))
	_add_box_to_st(st_ic, Vector3(0.0, 0.55, -2.325), Vector3(0.07, 0.045, 0.02)) # GT-R Emblem

	# Muscular Nismo-Style Sculpted Side Skirts (between Front & Rear arches)
	_add_box_to_st(st_paint, Vector3(-0.875, 0.165, 0.0), Vector3(0.07, 0.09, 1.88))
	_add_box_to_st(st_paint, Vector3( 0.875, 0.165, 0.0), Vector3(0.07, 0.09, 1.88))
	# Side Skirt Lower Matte Carbon Blades
	_add_box_to_st(st_trim, Vector3(-0.895, 0.115, 0.0), Vector3(0.06, 0.025, 1.92))
	_add_box_to_st(st_trim, Vector3( 0.895, 0.115, 0.0), Vector3(0.06, 0.025, 1.92))

	# V-Spec Carbon Rear Underbody Diffuser & Vertical Vortex Strakes
	_add_box_to_st(st_trim, Vector3(0.0, 0.20, 2.24), Vector3(1.46, 0.11, 0.22))
	for strake_x in [-0.52, -0.18, 0.18, 0.52]:
		_add_box_to_st(st_trim, Vector3(strake_x, 0.16, 2.25), Vector3(0.02, 0.13, 0.26))

	# Recessed Rear License Plate Pocket
	_add_box_to_st(st_trim, Vector3(0.0, 0.42, 2.29), Vector3(0.42, 0.18, 0.04))

	_commit_surface_to_node(st_trim, "AeroTrimAndDiffuser", _mat_carbon_matte, parent)
	_commit_surface_to_node(st_ic, "FrontMountIntercooler", _mat_intercooler, parent)
	_commit_surface_to_node(st_paint, "SideSkirts", _mat_body, parent)

# ==============================================================================
# 3. TRUNK DOUBLE-BLADE GT RACING SPOILER & DUAL AERO MIRRORS
# ==============================================================================
func _build_gt_wing(parent: Node3D) -> void:
	var st_paint := SurfaceTool.new()
	st_paint.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_carbon := SurfaceTool.new()
	st_carbon.begin(Mesh.PRIMITIVE_TRIANGLES)

	var wing_z: float = 2.14
	var base_y: float = 0.89
	var top_y: float = 1.15
	var span: float = 1.44

	# Left & Right Sculpted Uprights / Stanchions
	for side in [-1.0, 1.0]:
		var ux: float = side * 0.52
		_add_box_to_st(st_paint, Vector3(ux, (base_y + top_y) * 0.5, wing_z), Vector3(0.035, top_y - base_y, 0.20))

		# Vertical Aerodynamic End-Plates (Body Color outer face, sharp GT silhouette)
		var ep_x: float = side * (span * 0.5)
		_add_box_to_st(st_paint, Vector3(ep_x, top_y - 0.02, wing_z + 0.01), Vector3(0.018, 0.19, 0.30))

	# Primary Lower Airfoil Blade (Bayside Blue)
	_add_box_to_st(st_paint, Vector3(0.0, top_y - 0.04, wing_z), Vector3(span, 0.024, 0.23))

	# Secondary Upper Adjustable Gurney Carbon Blade (Double-Blade Spec)
	_add_box_to_st(st_carbon, Vector3(0.0, top_y + 0.035, wing_z + 0.03), Vector3(span - 0.02, 0.020, 0.16))

	# Center Blade Support Turnbuckles
	_add_box_to_st(st_carbon, Vector3(-0.22, top_y, wing_z + 0.02), Vector3(0.012, 0.075, 0.04))
	_add_box_to_st(st_carbon, Vector3( 0.22, top_y, wing_z + 0.02), Vector3(0.012, 0.075, 0.04))

	_commit_surface_to_node(st_paint, "GTWing_Structure", _mat_body, parent)
	_commit_surface_to_node(st_carbon, "GTWing_CarbonElement", _mat_carbon_matte, parent)

func _build_side_mirrors(parent: Node3D) -> void:
	var st_paint := SurfaceTool.new()
	st_paint.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_trim := SurfaceTool.new()
	st_trim.begin(Mesh.PRIMITIVE_TRIANGLES)

	for side in [-1.0, 1.0]:
		# Mirror Base Gusset on Door Corner
		var base_pos := Vector3(side * 0.78, 0.87, -0.52)
		_add_box_to_st(st_trim, base_pos, Vector3(0.08, 0.05, 0.12))

		# Dual-Strut Aero Stalk
		var stalk_pos := Vector3(side * 0.84, 0.89, -0.50)
		_add_box_to_st(st_paint, stalk_pos, Vector3(0.10, 0.03, 0.06))

		# Sculpted Aerodynamic Mirror Housing
		var housing_pos := Vector3(side * 0.91, 0.91, -0.49)
		_add_box_to_st(st_paint, housing_pos, Vector3(0.13, 0.085, 0.10))

		# Reflective Mirror Glass Insert (Rear-facing)
		var glass_pos := Vector3(side * 0.91, 0.91, -0.438)
		_add_box_to_st(st_trim, glass_pos, Vector3(0.11, 0.065, 0.01))

	_commit_surface_to_node(st_paint, "AeroSideMirrors", _mat_body, parent)
	_commit_surface_to_node(st_trim, "MirrorBases", _mat_carbon_matte, parent)

# ==============================================================================
# 4. CHROME EXHAUST CANNON (SINGLE 4-INCH JDM BARREL)
# ==============================================================================
func _build_exhaust_system(parent: Node3D) -> void:
	var st_chrome := SurfaceTool.new()
	st_chrome.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_inner := SurfaceTool.new()
	st_inner.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Left-side exited Nismo / HKS Hi-Power 4-inch (0.105m diameter) angled cannon
	var muffler_pos := Vector3(-0.46, 0.20, 2.15)
	_add_cylinder_to_st(st_chrome, muffler_pos, 0.085, 0.32, 20, Vector3.BACK)

	# Polished Rolled Lip Tip protruding past rear diffuser
	var tip_pos := Vector3(-0.46, 0.195, 2.33)
	_add_ring_extrusion_to_st(st_chrome, tip_pos, 0.046, 0.056, 0.14, 24, Vector3.BACK)

	# Dark Soot Core inside Exhaust Barrel
	_add_cylinder_to_st(st_inner, Vector3(-0.46, 0.195, 2.31), 0.045, 0.12, 16, Vector3.BACK)

	_commit_surface_to_node(st_chrome, "JDM_ExhaustCannon", _mat_chrome, parent)
	_commit_surface_to_node(st_inner, "ExhaustCore", _mat_underglow_well, parent)

# ==============================================================================
# 2. SIGNATURE LIGHTING & EMISSIVE SHADERS (QUAD HALOS & XENON PROJECTORS)
# ==============================================================================
func _build_lighting_assemblies(parent: Node3D) -> void:
	var st_halo := SurfaceTool.new()
	st_halo.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_xenon := SurfaceTool.new()
	st_xenon.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_reverse := SurfaceTool.new()
	st_reverse.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_indicator := SurfaceTool.new()
	st_indicator.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_chrome := SurfaceTool.new()
	st_chrome.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_lens := SurfaceTool.new()
	st_lens.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_housing := SurfaceTool.new()
	st_housing.begin(Mesh.PRIMITIVE_TRIANGLES)

	# --------------------------------------------------------------------------
	# A. REAR QUAD CIRCULAR LED HALO TAILLIGHTS (Iconic Outer Large + Inner Small)
	# --------------------------------------------------------------------------
	var tail_z: float = 2.302
	for side in [-1.0, 1.0]:
		# Dark recessed bezel housing
		_add_box_to_st(st_housing, Vector3(side * 0.53, 0.72, tail_z - 0.015), Vector3(0.38, 0.17, 0.03))

		# Outer Large Halo Ring (Radius: 0.068m outer, 0.042m inner)
		var outer_halo_pos := Vector3(side * 0.61, 0.725, tail_z)
		_add_ring_extrusion_to_st(st_halo, outer_halo_pos, 0.040, 0.068, 0.022, 28, Vector3.BACK)
		# Dark center core of outer ring + Amber turn signal dot inside
		_add_cylinder_to_st(st_housing, outer_halo_pos, 0.039, 0.018, 20, Vector3.BACK)
		_add_cylinder_to_st(st_indicator, outer_halo_pos + Vector3(0.0, 0.0, 0.004), 0.020, 0.020, 16, Vector3.BACK)

		# Inner Smaller Halo Ring (Radius: 0.052m outer, 0.032m inner)
		var inner_halo_pos := Vector3(side * 0.44, 0.715, tail_z)
		_add_ring_extrusion_to_st(st_halo, inner_halo_pos, 0.030, 0.052, 0.022, 28, Vector3.BACK)
		_add_cylinder_to_st(st_housing, inner_halo_pos, 0.029, 0.018, 20, Vector3.BACK)

		# Reverse Lights flanking the Rear License Plate
		var rev_pos := Vector3(side * 0.28, 0.43, tail_z)
		_add_box_to_st(st_reverse, rev_pos, Vector3(0.09, 0.055, 0.02))

	# High-Mount Center LED Third Brake Strip on Trunk Lip
	_add_box_to_st(st_halo, Vector3(0.0, 0.885, tail_z - 0.005), Vector3(0.28, 0.018, 0.02))

	# --------------------------------------------------------------------------
	# B. FRONT SHARP MULTI-PROJECTOR XENONS + LED DRL STRIPS
	# --------------------------------------------------------------------------
	var head_z: float = -2.275
	for side in [-1.0, 1.0]:
		# Aggressive Angled Black Headlight Housing Bucket
		var h_pos := Vector3(side * 0.56, 0.57, head_z + 0.02)
		_add_box_to_st(st_housing, h_pos, Vector3(0.38, 0.13, 0.10))

		# Dual Chrome Projector Bowls (Outer Low-Beam Xenon + Inner High-Beam)
		var p_outer := Vector3(side * 0.62, 0.575, head_z - 0.01)
		var p_inner := Vector3(side * 0.48, 0.565, head_z - 0.015)

		_add_ring_extrusion_to_st(st_chrome, p_outer, 0.036, 0.048, 0.03, 20, Vector3.BACK)
		_add_cylinder_to_st(st_xenon, p_outer, 0.035, 0.025, 20, Vector3.BACK)

		_add_ring_extrusion_to_st(st_chrome, p_inner, 0.030, 0.042, 0.03, 20, Vector3.BACK)
		_add_cylinder_to_st(st_xenon, p_inner, 0.029, 0.025, 20, Vector3.BACK)

		# Sharp Lower & Inner LED Daytime Running Light (DRL) Signature Blade
		_add_box_to_st(st_xenon, Vector3(side * 0.55, 0.515, head_z - 0.02), Vector3(0.34, 0.016, 0.02))

		# Outer Corner Amber Indicator Marker
		_add_box_to_st(st_indicator, Vector3(side * 0.73, 0.575, head_z), Vector3(0.045, 0.09, 0.03))

		# Clear Glass Polycarbonate Aero Cover Lens over the entire projector assembly
		_add_box_to_st(st_lens, Vector3(side * 0.56, 0.57, head_z - 0.025), Vector3(0.39, 0.135, 0.018))

		# Active Forward Projector SpotLight3D Beam (5500K Crisp Xenon)
		var beam := SpotLight3D.new()
		beam.name = "XenonBeam_" + ("L" if side < 0.0 else "R")
		beam.position = Vector3(side * 0.58, 0.57, head_z - 0.06)
		beam.rotation_degrees = Vector3(-4.0, -2.5 * side, 0.0)
		beam.light_color = Color(0.86, 0.93, 1.0)
		beam.light_energy = 6.0
		beam.spot_range = 65.0
		beam.spot_angle = 38.0
		beam.spot_attenuation = 0.85
		beam.shadow_enabled = true
		parent.add_child(beam)
		if side < 0.0:
			_spot_l = beam
		else:
			_spot_r = beam

	_commit_surface_to_node(st_halo, "Taillights_QuadHalos", _mat_taillight_halo, parent)
	_commit_surface_to_node(st_xenon, "Headlights_XenonProjectors", _mat_headlight_xenon, parent)
	_commit_surface_to_node(st_reverse, "ReverseLights", _mat_reverse_light, parent)
	_commit_surface_to_node(st_indicator, "IndicatorLights", _mat_indicator_light, parent)
	_commit_surface_to_node(st_chrome, "ProjectorBezels", _mat_chrome, parent)
	_commit_surface_to_node(st_lens, "HeadlightClearLens", _mat_headlight_glass, parent)
	_commit_surface_to_node(st_housing, "LightHousings", _mat_carbon_matte, parent)

# ==============================================================================
# 3. DETAILED WHEELS & RUNNING GEAR (6-SPOKE NISMO RIMS, TIRES, ROTORS, BREMBO)
# ==============================================================================
func _create_wheel_anchor(node_name: String, pos: Vector3, is_left: bool, is_front: bool) -> Node3D:
	var wheel_anchor := Node3D.new()
	wheel_anchor.name = node_name
	wheel_anchor.position = pos
	add_child(wheel_anchor)
	_set_owner_safe(wheel_anchor)

	var out_sign: float = -1.0 if is_left else 1.0

	# 1. Build Tire with Curved Sidewall & Circumferential Tread Grooves
	var st_tire := SurfaceTool.new()
	st_tire.begin(Mesh.PRIMITIVE_TRIANGLES)
	_build_tire_geometry(st_tire, WHEEL_RADIUS, RIM_RADIUS, TIRE_WIDTH, 36)
	_commit_surface_to_node(st_tire, "Tire_Mesh", _mat_tire, wheel_anchor)

	# 2. Build Nismo 6-Spoke Deep-Dish Alloy Rim
	var st_rim := SurfaceTool.new()
	st_rim.begin(Mesh.PRIMITIVE_TRIANGLES)
	_build_nismo_rim_geometry(st_rim, RIM_RADIUS, TIRE_WIDTH * 0.92, out_sign, 36)
	_commit_surface_to_node(st_rim, "Nismo6Spoke_Rim", _mat_rim, wheel_anchor)

	# 3. Build Drilled Steel Brake Rotor (Cross-drilled ventilated disc)
	var st_rotor := SurfaceTool.new()
	st_rotor.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rotor_radius: float = 0.175 if is_front else 0.165
	var rotor_x: float = -out_sign * 0.025 # Tucked behind deep-dish spokes
	_add_ring_extrusion_to_st(st_rotor, Vector3(rotor_x, 0.0, 0.0), 0.065, rotor_radius, 0.026, 28, Vector3.RIGHT)
	_commit_surface_to_node(st_rotor, "DrilledBrakeRotor", _mat_rotor, wheel_anchor)

	# Cross-drilled cooling slot accents on rotor face
	var st_holes := SurfaceTool.new()
	st_holes.begin(Mesh.PRIMITIVE_TRIANGLES)
	var num_drill_patterns: int = 12
	for i in range(num_drill_patterns):
		var ang: float = (TAU / float(num_drill_patterns)) * float(i)
		var r_mid: float = (0.075 + rotor_radius) * 0.52
		var hp := Vector3(rotor_x, cos(ang) * r_mid, sin(ang) * r_mid)
		_add_cylinder_to_st(st_holes, hp, 0.007, 0.030, 8, Vector3.RIGHT)
	_commit_surface_to_node(st_holes, "RotorDrillHoles", _mat_underglow_well, wheel_anchor)

	# 4. Build Golden Brembo 6-Pot / 4-Pot Brake Caliper
	var st_caliper := SurfaceTool.new()
	st_caliper.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Mount Front Calipers toward rear of axle (+Z), Rear Calipers toward front (-Z)
	var cal_z_dir: float = 1.0 if is_front else -1.0
	var cal_r: float = rotor_radius * 0.78
	var cal_pos := Vector3(rotor_x + out_sign * 0.008, 0.03, cal_z_dir * cal_r)
	var cal_size := Vector3(0.075, 0.135 if is_front else 0.105, 0.075)
	_add_box_to_st(st_caliper, cal_pos, cal_size)
	_commit_surface_to_node(st_caliper, "BremboGold_Caliper", _mat_caliper, wheel_anchor)

	return wheel_anchor

func _build_tire_geometry(st: SurfaceTool, outer_r: float, inner_r: float, width: float, segments: int) -> void:
	var hw: float = width * 0.5
	var bulge_w: float = hw * 1.05
	var mid_r: float = lerpf(inner_r, outer_r, 0.55)
	var shoulder_r: float = outer_r * 0.985
	var groove_r: float = outer_r * 0.972

	# Symmetric 1D profile across tire width (X) and radius (R):
	# Bead Left -> Sidewall Bulge Left -> Shoulder Left -> 3 Tread Ribs with 2 Grooves -> Shoulder Right -> Bulge Right -> Bead Right
	var prof_x: Array[float] = [
		-hw * 0.94, -bulge_w, -hw * 0.90, -hw * 0.35, -hw * 0.25, -hw * 0.18,
		 hw * 0.18,  hw * 0.25,  hw * 0.35,  hw * 0.90,  bulge_w,  hw * 0.94
	]
	var prof_r: Array[float] = [
		inner_r, mid_r, shoulder_r, outer_r, groove_r, outer_r,
		outer_r, groove_r, outer_r, shoulder_r, mid_r, inner_r
	]

	for i in range(segments):
		var a0: float = (TAU * float(i)) / float(segments)
		var a1: float = (TAU * float(i + 1)) / float(segments)
		var c0: float = cos(a0)
		var s0: float = sin(a0)
		var c1: float = cos(a1)
		var s1: float = sin(a1)

		for p in range(prof_x.size() - 1):
			var p00 := Vector3(prof_x[p], c0 * prof_r[p], s0 * prof_r[p])
			var p01 := Vector3(prof_x[p + 1], c0 * prof_r[p + 1], s0 * prof_r[p + 1])
			var p11 := Vector3(prof_x[p + 1], c1 * prof_r[p + 1], s1 * prof_r[p + 1])
			var p10 := Vector3(prof_x[p], c1 * prof_r[p], s1 * prof_r[p])
			_add_quad(st, p00, p01, p11, p10)

func _build_nismo_rim_geometry(st: SurfaceTool, rim_r: float, width: float, out_sign: float, segments: int) -> void:
	var hw: float = width * 0.5
	var outer_x: float = out_sign * hw
	var dish_x: float = out_sign * (hw - 0.048) # Deep-dish stepped lip offset
	var hub_x: float = out_sign * (hw - 0.072)  # Concave central hub bowl

	# 1. Outer Rim Barrel & Stepped Deep-Dish Lip
	_add_ring_extrusion_to_st(st, Vector3(0.0, 0.0, 0.0), rim_r - 0.016, rim_r, width, segments, Vector3.RIGHT)
	_add_ring_extrusion_to_st(st, Vector3( outer_x - out_sign * 0.022, 0.0, 0.0), rim_r - 0.032, rim_r - 0.014, 0.044, segments, Vector3.RIGHT)

	# 2. Central Hub Cylinder & Center Cap
	var hub_r: float = 0.062
	_add_cylinder_to_st(st, Vector3(hub_x, 0.0, 0.0), hub_r, 0.045, 18, Vector3.RIGHT)

	# 3. 6 Iconic Nismo / Volk TE37 Concave Spokes (connecting Hub to Deep-Dish Lip)
	var num_spokes: int = 6
	var spoke_len: float = (rim_r - 0.022) - (hub_r * 0.75)
	var spoke_mid_r: float = (hub_r * 0.75) + spoke_len * 0.5

	for s in range(num_spokes):
		var angle: float = (TAU / float(num_spokes)) * float(s)
		var basis := Basis(Vector3.RIGHT, angle)

		# Spoke pitches outward from concave hub_x to dish_x
		var p_center := Vector3((hub_x + dish_x) * 0.5, 0.0, 0.0) + basis * Vector3(0.0, spoke_mid_r, 0.0)
		var spoke_tilt_angle: float = atan2(dish_x - hub_x, spoke_len) * 0.55
		var spoke_basis: Basis = basis * Basis(Vector3.BACK, spoke_tilt_angle)

		_add_oriented_box_to_st(st, p_center, spoke_basis, Vector3(0.020, spoke_len, 0.048))

# ==============================================================================
# LOW-LEVEL GEOMETRY PRIMITIVES & SURFACETOOL HELPERS
# ==============================================================================
func _commit_surface_to_node(st: SurfaceTool, mesh_name: String, material: Material, parent: Node3D) -> MeshInstance3D:
	st.generate_normals()
	st.generate_tangents()
	var mesh: ArrayMesh = st.commit()
	mesh.resource_name = mesh_name

	var mi := MeshInstance3D.new()
	mi.name = mesh_name
	mi.mesh = mesh
	mi.material_override = material
	parent.add_child(mi)
	_set_owner_safe(mi)
	return mi

func _add_quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	var n: Vector3 = (p1 - p0).cross(p3 - p0).normalized()
	st.set_normal(n)
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(p0)
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(p1)
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(p2)

	st.set_normal(n)
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(p0)
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(p2)
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(p3)

func _add_box_to_st(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	_add_oriented_box_to_st(st, center, Basis.IDENTITY, size)

func _add_oriented_box_to_st(st: SurfaceTool, center: Vector3, b: Basis, size: Vector3) -> void:
	var hs: Vector3 = size * 0.5
	var v: Array[Vector3] = [
		center + b * Vector3(-hs.x, -hs.y, -hs.z),
		center + b * Vector3( hs.x, -hs.y, -hs.z),
		center + b * Vector3( hs.x,  hs.y, -hs.z),
		center + b * Vector3(-hs.x,  hs.y, -hs.z),
		center + b * Vector3(-hs.x, -hs.y,  hs.z),
		center + b * Vector3( hs.x, -hs.y,  hs.z),
		center + b * Vector3( hs.x,  hs.y,  hs.z),
		center + b * Vector3(-hs.x,  hs.y,  hs.z)
	]
	_add_quad(st, v[0], v[1], v[2], v[3]) # Front (-Z)
	_add_quad(st, v[5], v[4], v[7], v[6]) # Back (+Z)
	_add_quad(st, v[4], v[0], v[3], v[7]) # Left (-X)
	_add_quad(st, v[1], v[5], v[6], v[2]) # Right (+X)
	_add_quad(st, v[3], v[2], v[6], v[7]) # Top (+Y)
	_add_quad(st, v[4], v[5], v[1], v[0]) # Bottom (-Y)

func _add_pillar_beam(st: SurfaceTool, p_start: Vector3, p_end: Vector3, width: float, thickness: float) -> void:
	var dir: Vector3 = p_end - p_start
	var length: float = dir.length()
	if length < 0.001:
		return
	var mid: Vector3 = (p_start + p_end) * 0.5
	var up_dir: Vector3 = dir.normalized()
	var right_dir: Vector3 = up_dir.cross(Vector3.BACK).normalized()
	if right_dir.length_squared() < 0.01:
		right_dir = Vector3.RIGHT
	var fwd_dir: Vector3 = right_dir.cross(up_dir).normalized()
	var b := Basis(right_dir, up_dir, fwd_dir)
	_add_oriented_box_to_st(st, mid, b, Vector3(thickness, length, width))

func _add_cylinder_to_st(st: SurfaceTool, center: Vector3, radius: float, depth: float, segments: int, axis: Vector3) -> void:
	_add_ring_extrusion_to_st(st, center, 0.0, radius, depth, segments, axis)

func _add_ring_extrusion_to_st(st: SurfaceTool, center: Vector3, inner_r: float, outer_r: float, depth: float, segments: int, axis: Vector3) -> void:
	var n_axis: Vector3 = axis.normalized()
	var tangent: Vector3 = Vector3.UP if absf(n_axis.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u_axis: Vector3 = n_axis.cross(tangent).normalized()
	var v_axis: Vector3 = n_axis.cross(u_axis).normalized()
	var half_d: float = depth * 0.5

	for i in range(segments):
		var a0: float = (TAU * float(i)) / float(segments)
		var a1: float = (TAU * float(i + 1)) / float(segments)
		var dir0: Vector3 = u_axis * cos(a0) + v_axis * sin(a0)
		var dir1: Vector3 = u_axis * cos(a1) + v_axis * sin(a1)

		var f_out0: Vector3 = center + n_axis * half_d + dir0 * outer_r
		var f_out1: Vector3 = center + n_axis * half_d + dir1 * outer_r
		var b_out0: Vector3 = center - n_axis * half_d + dir0 * outer_r
		var b_out1: Vector3 = center - n_axis * half_d + dir1 * outer_r

		# Outer Wall
		_add_quad(st, f_out0, b_out0, b_out1, f_out1)

		if inner_r > 0.0005:
			var f_in0: Vector3 = center + n_axis * half_d + dir0 * inner_r
			var f_in1: Vector3 = center + n_axis * half_d + dir1 * inner_r
			var b_in0: Vector3 = center - n_axis * half_d + dir0 * inner_r
			var b_in1: Vector3 = center - n_axis * half_d + dir1 * inner_r

			# Inner Wall
			_add_quad(st, b_in0, f_in0, f_in1, b_in1)
			# Front Annulus Face (+axis)
			_add_quad(st, f_in0, f_out0, f_out1, f_in1)
			# Back Annulus Face (-axis)
			_add_quad(st, b_out0, b_in0, b_in1, b_out1)
		else:
			# Solid Cylinder Caps
			var f_c: Vector3 = center + n_axis * half_d
			var b_c: Vector3 = center - n_axis * half_d
			_add_quad(st, f_c, f_out0, f_out1, f_c)
			_add_quad(st, b_out0, b_c, b_c, b_out1)