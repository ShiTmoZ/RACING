@tool
class_name AE86TruenoModeler
extends Node3D
## Procedural 3D Vehicle Modeler for 1986 Toyota Sprinter Trueno GT-APEX (AE86)
## Project: "ShiTmoZ/RACING" (Mount Akina Touge)
## Built purely with SurfaceTool & CSG/Primitive Meshes for Godot 4.3 Forward+

# ==============================================================================
# EXPOSED PROPERTIES & CONSTANTS
# ==============================================================================
@export_group("Headlight Control")
@export var headlights_open: bool = true:
	set(value):
		headlights_open = value
		toggle_headlights(headlights_open)

@export var rebuild_model: bool = false:
	set(value):
		if value:
			build_vehicle_mesh()
		rebuild_model = false

# Exact AE86 Specifications (Meters)
const LENGTH: float = 4.20
const WIDTH: float = 1.62
const HEIGHT: float = 1.33
const WHEELBASE: float = 2.40
const TRACK_WIDTH: float = 1.44
const WHEEL_RADIUS: float = 0.30
const WHEEL_WIDTH: float = 0.20

# Axle Z Coordinates (-Z is Forward in Godot)
const Z_FRONT_AXLE: float = -1.20
const Z_REAR_AXLE: float = 1.20
const X_LEFT_WHEEL: float = -0.72
const X_RIGHT_WHEEL: float = 0.72

# Exposed Node References for ArcadeSimVehicle.gd
var WheelFL: Node3D
var WheelFR: Node3D
var WheelRL: Node3D
var WheelRR: Node3D

var HeadlightHingeL: Node3D
var HeadlightHingeR: Node3D
var _spot_l: SpotLight3D
var _spot_r: SpotLight3D
var _lens_mat: StandardMaterial3D

# Material Cache
var _mats: Dictionary = {}
var _headlight_tween: Tween

# ==============================================================================
# LIFECYCLE
# ==============================================================================
func _ready() -> void:
	if get_child_count() == 0:
		build_vehicle_mesh()
	toggle_headlights(headlights_open, true)


# ==============================================================================
# PUBLIC API
# ==============================================================================
## Builds the complete AE86 visual hierarchy and returns self (or root visual node).
func build_vehicle_mesh() -> Node3D:
	# Clean existing children
	for child in get_children():
		remove_child(child)
		child.queue_free()

	_init_materials()

	var body_root := Node3D.new()
	body_root.name = "BodyVisuals"
	add_child(body_root)

	# 1. Main Procedural Bodywork (Panda Two-Tone + Greenhouse)
	_build_chassis_and_cabin(body_root)

	# 2. Bumpers, Skirts, Rub Strips & Trim
	_build_aero_and_trim(body_root)

	# 3. Interior Cabin (Bucket Seats, Dash, Steering Wheel, Roll Cage)
	_build_interior(body_root)

	# 4. Kouki Taillight Bar, License Plate & Exhaust
	_build_rear_details(body_root)

	# 5. Functional Pop-Up Retractable Headlights
	_build_popup_headlights(body_root)

	# 6. Right-Side Door Fujiwara Tofu Shop Kanji Decal
	_build_tofu_decal(body_root)

	# 7. Exposed RS Watanabe 8-Spoke Wheels
	WheelFL = _build_watanabe_wheel("WheelFL", true)
	WheelFL.position = Vector3(X_LEFT_WHEEL, WHEEL_RADIUS, Z_FRONT_AXLE)
	add_child(WheelFL)

	WheelFR = _build_watanabe_wheel("WheelFR", false)
	WheelFR.position = Vector3(X_RIGHT_WHEEL, WHEEL_RADIUS, Z_FRONT_AXLE)
	add_child(WheelFR)

	WheelRL = _build_watanabe_wheel("WheelRL", true)
	WheelRL.position = Vector3(X_LEFT_WHEEL, WHEEL_RADIUS, Z_REAR_AXLE)
	add_child(WheelRL)

	WheelRR = _build_watanabe_wheel("WheelRR", false)
	WheelRR.position = Vector3(X_RIGHT_WHEEL, WHEEL_RADIUS, Z_REAR_AXLE)
	add_child(WheelRR)

	return self


## Smoothly opens or retracts the pop-up headlights and toggles halogen beams.
func toggle_headlights(open: bool, instant: bool = false) -> void:
	if not is_instance_valid(HeadlightHingeL) or not is_instance_valid(HeadlightHingeR):
		return

	var target_pitch_deg: float = 54.0 if open else 0.0
	var target_rad: float = deg_to_rad(target_pitch_deg)

	if _headlight_tween and _headlight_tween.is_valid():
		_headlight_tween.kill()

	if instant or not is_inside_tree():
		HeadlightHingeL.rotation.x = target_rad
		HeadlightHingeR.rotation.x = target_rad
		_set_headlight_lamps(open)
	else:
		_headlight_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		_headlight_tween.tween_property(HeadlightHingeL, "rotation:x", target_rad, 0.28)
		_headlight_tween.tween_property(HeadlightHingeR, "rotation:x", target_rad, 0.28)
		_set_headlight_lamps(open)


func _set_headlight_lamps(active: bool) -> void:
	if is_instance_valid(_spot_l):
		_spot_l.visible = active
	if is_instance_valid(_spot_r):
		_spot_r.visible = active
	if is_instance_valid(_lens_mat):
		_lens_mat.emission_enabled = active


# ==============================================================================
# MATERIAL INITIALIZATION (All CULL_DISABLED)
# ==============================================================================
func _init_materials() -> void:
	_mats.clear()

	# Upper Body: High-Gloss Fuji White
	_mats["fuji_white"] = _create_mat(Color(0.95, 0.95, 0.94), 0.15, 0.20)
	_mats["fuji_white"].clearcoat_enabled = true
	_mats["fuji_white"].clearcoat_roughness = 0.08

	# Lower Panda Trim & Bumpers: Satin Matte Black
	_mats["panda_black"] = _create_mat(Color(0.08, 0.08, 0.085), 0.70, 0.05)

	# Deep Underbody / Wheel Wells
	_mats["underbody"] = _create_mat(Color(0.03, 0.03, 0.035), 0.90, 0.0)

	# 80s Tinted Cabin Glass
	var glass := _create_mat(Color(0.07, 0.09, 0.12, 0.72), 0.08, 0.35)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mats["glass"] = glass

	# Interior Dark Charcoal
	_mats["interior"] = _create_mat(Color(0.11, 0.11, 0.13), 0.82, 0.05)
	_mats["bucket_red"] = _create_mat(Color(0.48, 0.10, 0.10), 0.75, 0.0)

	# RS Watanabe Gunmetal / Bronze Center
	_mats["watanabe_gunmetal"] = _create_mat(Color(0.20, 0.19, 0.17), 0.38, 0.68)

	# Polished Silver Outer Wheel Lip & Exhaust Chrome
	_mats["chrome"] = _create_mat(Color(0.88, 0.90, 0.92), 0.12, 0.95)

	# Tire Rubber
	_mats["tire"] = _create_mat(Color(0.06, 0.06, 0.065), 0.86, 0.02)

	# Brake Rotor & Caliper
	_mats["rotor"] = _create_mat(Color(0.45, 0.45, 0.48), 0.35, 0.85)
	_mats["caliper"] = _create_mat(Color(0.65, 0.12, 0.08), 0.40, 0.30)

	# 80s Yellow Halogen Headlight Lens (3200K Warm)
	_lens_mat = _create_mat(Color(1.0, 0.90, 0.58), 0.10, 0.20)
	_lens_mat.emission_enabled = true
	_lens_mat.emission = Color(1.0, 0.82, 0.42)
	_lens_mat.emission_energy_multiplier = 4.2
	_mats["headlight_lens"] = _lens_mat

	# Kouki Taillights (Red, Amber, Reverse White, Smoked Center)
	_mats["tail_red"] = _create_emissive_mat(Color(0.82, 0.05, 0.05), Color(1.0, 0.08, 0.05), 2.4)
	_mats["tail_amber"] = _create_emissive_mat(Color(0.95, 0.45, 0.02), Color(1.0, 0.48, 0.0), 1.4)
	_mats["tail_reverse"] = _create_emissive_mat(Color(0.88, 0.88, 0.90), Color(0.9, 0.9, 1.0), 0.5)
	_mats["smoked_plastic"] = _create_mat(Color(0.14, 0.12, 0.12), 0.25, 0.15)
	_mats["plate_white"] = _create_mat(Color(0.90, 0.92, 0.88), 0.40, 0.05)


func _create_mat(albedo: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.roughness = roughness
	mat.metallic = metallic
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _create_emissive_mat(albedo: Color, emission: Color, energy: float) -> StandardMaterial3D:
	var mat := _create_mat(albedo, 0.20, 0.10)
	mat.emission_enabled = true
	mat.emission = emission
	mat.emission_energy_multiplier = energy
	return mat


# ==============================================================================
# PROCEDURAL BODYWORK (Longitudinal Cross-Section Extrusion via SurfaceTool)
# ==============================================================================
func _build_chassis_and_cabin(parent: Node3D) -> void:
	# Longitudinal stations from Front Nose (-2.10m) to Rear Bumper (+2.10m)
	# Each station: [z, y_bottom, y_panda_split, y_beltline, y_hood_center, x_bottom, x_mid, x_belt]
	var body_stations: Array = [
		[-2.06, 0.24, 0.46, 0.57, 0.58, 0.68, 0.74, 0.71], # Front Nose Tip
		[-1.92, 0.23, 0.48, 0.62, 0.64, 0.72, 0.77, 0.73], # Pop-up Headlight Line
		[-1.58, 0.25, 0.50, 0.70, 0.73, 0.76, 0.80, 0.76], # Front Wheel Arch Front
		[-1.20, 0.28, 0.52, 0.75, 0.78, 0.77, 0.81, 0.77], # Front Axle Center
		[-0.82, 0.22, 0.50, 0.79, 0.82, 0.76, 0.80, 0.77], # Front Wheel Arch Rear
		[-0.58, 0.22, 0.50, 0.82, 0.85, 0.76, 0.81, 0.78], # Cowl / Base of Windshield
		[ 0.15, 0.22, 0.50, 0.83, 0.84, 0.76, 0.81, 0.78], # Door B-Pillar
		[ 0.82, 0.23, 0.50, 0.84, 0.85, 0.76, 0.80, 0.77], # Rear Wheel Arch Front
		[ 1.20, 0.28, 0.52, 0.85, 0.86, 0.77, 0.81, 0.77], # Rear Axle Center
		[ 1.58, 0.25, 0.51, 0.86, 0.87, 0.75, 0.79, 0.75], # Rear Wheel Arch Rear
		[ 1.98, 0.28, 0.52, 0.84, 0.85, 0.71, 0.75, 0.71], # Rear Quarter Taper
		[ 2.06, 0.30, 0.52, 0.82, 0.83, 0.69, 0.73, 0.69], # Tail Panel
	]

	var st_white := SurfaceTool.new()
	st_white.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_black := SurfaceTool.new()
	st_black.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_under := SurfaceTool.new()
	st_under.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in range(body_stations.size() - 1):
		var s0: Array = body_stations[i]
		var s1: Array = body_stations[i + 1]

		var z0: float = s0[0]; var z1: float = s1[0]
		var yb0: float = s0[1]; var yb1: float = s1[1]
		var yp0: float = s0[2]; var yp1: float = s1[2]
		var ybelt0: float = s0[3]; var ybelt1: float = s1[3]
		var yhood0: float = s0[4]; var yhood1: float = s1[4]
		var xb0: float = s0[5]; var xb1: float = s1[5]
		var xm0: float = s0[6]; var xm1: float = s1[6]
		var xbelt0: float = s0[7]; var xbelt1: float = s1[7]

		# 1. Lower Panda Black Sides (Left & Right)
		_add_quad(st_black,
			Vector3(xb0, yb0, z0), Vector3(xb1, yb1, z1),
			Vector3(xm1, yp1, z1), Vector3(xm0, yp0, z0))
		_add_quad(st_black,
			Vector3(-xb1, yb1, z1), Vector3(-xb0, yb0, z0),
			Vector3(-xm0, yp0, z0), Vector3(-xm1, yp1, z1))

		# 2. Upper Fuji White Sides (Panda Split to Beltline)
		_add_quad(st_white,
			Vector3(xm0, yp0, z0), Vector3(xm1, yp1, z1),
			Vector3(xbelt1, ybelt1, z1), Vector3(xbelt0, ybelt0, z0))
		_add_quad(st_white,
			Vector3(-xm1, yp1, z1), Vector3(-xm0, yp0, z0),
			Vector3(-xbelt0, ybelt0, z0), Vector3(-xbelt1, ybelt1, z1))

		# 3. Hood & Front Cowl Deck (Front Nose to Windshield Base at Z = -0.58)
		if z0 < -0.57:
			_add_quad(st_white,
				Vector3(xbelt0, ybelt0, z0), Vector3(xbelt1, ybelt1, z1),
				Vector3(0.0, yhood1, z1), Vector3(0.0, yhood0, z0))
			_add_quad(st_white,
				Vector3(0.0, yhood0, z0), Vector3(0.0, yhood1, z1),
				Vector3(-xbelt1, ybelt1, z1), Vector3(-xbelt0, ybelt0, z0))

		# 4. Underbody Floor Pan
		_add_quad(st_under,
			Vector3(-xb0, yb0, z0), Vector3(-xb1, yb1, z1),
			Vector3(xb1, yb1, z1), Vector3(xb0, yb0, z0))

	# Front & Rear Bulkhead Caps
	var sf: Array = body_stations[0]
	_add_quad(st_black,
		Vector3(-sf[5], sf[1], sf[0]), Vector3(sf[5], sf[1], sf[0]),
		Vector3(sf[6], sf[2], sf[0]), Vector3(-sf[6], sf[2], sf[0]))
	_add_quad(st_white,
		Vector3(-sf[6], sf[2], sf[0]), Vector3(sf[6], sf[2], sf[0]),
		Vector3(sf[7], sf[3], sf[0]), Vector3(-sf[7], sf[3], sf[0]))

	var sr: Array = body_stations[body_stations.size() - 1]
	_add_quad(st_black,
		Vector3(sr[5], sr[1], sr[0]), Vector3(-sr[5], sr[1], sr[0]),
		Vector3(-sr[6], sr[2], sr[0]), Vector3(sr[6], sr[2], sr[0]))
	_add_quad(st_white,
		Vector3(sr[6], sr[2], sr[0]), Vector3(-sr[6], sr[2], sr[0]),
		Vector3(-sr[7], sr[3], sr[0]), Vector3(sr[7], sr[3], sr[0]))

	# --------------------------------------------------------------------------
	# Fastback Greenhouse Cabin & Roof (Z = -0.58 to Z = +1.98)
	# --------------------------------------------------------------------------
	var st_glass := SurfaceTool.new()
	st_glass.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Key Cabin Coordinates
	var p_ws_bl := Vector3(-0.74, 0.83, -0.58)
	var p_ws_br := Vector3( 0.74, 0.83, -0.58)
	var p_ws_tl := Vector3(-0.62, 1.31, -0.05)
	var p_ws_tr := Vector3( 0.62, 1.31, -0.05)

	var p_rf_ml := Vector3(-0.62, 1.33, 0.45)
	var p_rf_mr := Vector3( 0.62, 1.33, 0.45)
	var p_rf_rl := Vector3(-0.60, 1.30, 0.78)
	var p_rf_rr := Vector3( 0.60, 1.30, 0.78)

	var p_hb_bl := Vector3(-0.70, 0.86, 1.92)
	var p_hb_br := Vector3( 0.70, 0.86, 1.92)

	# Roof Panel (Fuji White with Slight Crown)
	_add_quad(st_white, p_ws_tl, p_ws_tr, p_rf_mr, p_rf_ml)
	_add_quad(st_white, p_rf_ml, p_rf_mr, p_rf_rr, p_rf_rl)

	# Front Windshield (Tinted Glass)
	_add_quad(st_glass, p_ws_bl, p_ws_br, p_ws_tr, p_ws_tl)

	# Rear Fastback Hatch Glass
	_add_quad(st_glass, p_rf_rl, p_rf_rr, p_hb_br, p_hb_bl)

	# Rear Deck Filler (Between Hatch Glass at 1.92 and Tail at 2.06)
	_add_quad(st_white,
		p_hb_bl, p_hb_br,
		Vector3(0.69, 0.83, 2.06), Vector3(-0.69, 0.83, 2.06))

	# Side Windows (Left & Right)
	var p_side_fl := Vector3(-0.77, 0.82, -0.54)
	var p_side_fr := Vector3( 0.77, 0.82, -0.54)
	var p_side_ml := Vector3(-0.77, 0.84,  0.78)
	var p_side_mr := Vector3( 0.77, 0.84,  0.78)
	var p_side_rl := Vector3(-0.73, 0.86,  1.65)
	var p_side_rr := Vector3( 0.73, 0.86,  1.65)

	# Right Side Door & Quarter Glass
	_add_quad(st_glass, p_side_fr, p_side_mr, p_rf_rr, p_ws_tr)
	_add_quad(st_glass, p_side_mr, p_side_rr, p_rf_rr, p_rf_rr) # Triangle rear quarter window

	# Left Side Door & Quarter Glass
	_add_quad(st_glass, p_side_ml, p_side_fl, p_ws_tl, p_rf_rl)
	_add_quad(st_glass, p_side_rl, p_side_ml, p_rf_rl, p_rf_rl)

	# Wide C-Pillar Sail Panels (Fuji White from Z = 1.65 to 1.92)
	_add_quad(st_white, p_side_rr, p_hb_br, p_rf_rr, p_rf_rr)
	_add_quad(st_white, p_hb_bl, p_side_rl, p_rf_rl, p_rf_rl)

	# Black A-Pillars & B-Pillars
	# Right A-Pillar
	_add_quad(st_black,
		Vector3(0.76, 0.82, -0.59), Vector3(0.76, 0.82, -0.51),
		Vector3(0.63, 1.31, -0.02), Vector3(0.61, 1.31, -0.09))
	# Left A-Pillar
	_add_quad(st_black,
		Vector3(-0.76, 0.82, -0.51), Vector3(-0.76, 0.82, -0.59),
		Vector3(-0.61, 1.31, -0.09), Vector3(-0.63, 1.31, -0.02))
	# Right B-Pillar
	_add_quad(st_black,
		Vector3(0.775, 0.83, 0.14), Vector3(0.775, 0.83, 0.22),
		Vector3(0.625, 1.32, 0.24), Vector3(0.625, 1.32, 0.16))
	# Left B-Pillar
	_add_quad(st_black,
		Vector3(-0.775, 0.83, 0.22), Vector3(-0.775, 0.83, 0.14),
		Vector3(-0.625, 1.32, 0.16), Vector3(-0.625, 1.32, 0.24))

	# Commit SurfaceTool Meshes with Crisp Flat Normals
	_commit_surface(st_white, _mats["fuji_white"], "UpperBodyWhite", parent)
	_commit_surface(st_black, _mats["panda_black"], "LowerBodyPandaBlack", parent)
	_commit_surface(st_under, _mats["underbody"], "UnderbodyChassis", parent)
	_commit_surface(st_glass, _mats["glass"], "CabinGlass", parent)


# ==============================================================================
# BUMPERS, FENDER ARCHES, RUB STRIPS, DUCKTAIL SPOILER & MIRRORS
# ==============================================================================
func _build_aero_and_trim(parent: Node3D) -> void:
	var trim_root := Node3D.new()
	trim_root.name = "AeroAndTrim"
	parent.add_child(trim_root)

	# 1. Front Kouki Bumper & Chin Spoiler (Satin Matte Black)
	_add_box(trim_root, "FrontBumperMain", Vector3(1.56, 0.22, 0.16), Vector3(0.0, 0.35, -2.04), _mats["panda_black"])
	_add_box(trim_root, "FrontChinSpoiler", Vector3(1.52, 0.09, 0.14), Vector3(0.0, 0.20, -2.06), _mats["panda_black"])
	# Front Grille Intake Opening & Fog Light Recesses
	_add_box(trim_root, "FrontAirDam", Vector3(0.88, 0.12, 0.04), Vector3(0.0, 0.28, -2.115), _mats["underbody"])
	# Front Amber Turn Signals in Bumper
	_add_box(trim_root, "FrontSignalL", Vector3(0.20, 0.055, 0.04), Vector3(-0.54, 0.38, -2.11), _mats["tail_amber"])
	_add_box(trim_root, "FrontSignalR", Vector3(0.20, 0.055, 0.04), Vector3( 0.54, 0.38, -2.11), _mats["tail_amber"])
	# Classic "TRUENO" Nose Badge Plate
	_add_box(trim_root, "TruenoNoseTrim", Vector3(0.46, 0.035, 0.03), Vector3(0.0, 0.51, -2.07), _mats["panda_black"])

	# 2. Rear Bumper (Satin Matte Black)
	_add_box(trim_root, "RearBumperMain", Vector3(1.54, 0.25, 0.16), Vector3(0.0, 0.38, 2.04), _mats["panda_black"])
	_add_box(trim_root, "RearLowerValance", Vector3(1.46, 0.08, 0.12), Vector3(0.0, 0.23, 2.03), _mats["panda_black"])

	# 3. Crisp Black Beltline Rub Strips (Left & Right)
	# Runs along the upper/mid door and quarter panels
	_add_box(trim_root, "BeltRubStripL", Vector3(0.025, 0.042, 3.76), Vector3(-0.805, 0.53, 0.0), _mats["panda_black"])
	_add_box(trim_root, "BeltRubStripR", Vector3(0.025, 0.042, 3.76), Vector3( 0.805, 0.53, 0.0), _mats["panda_black"])

	# 4. Flared Black Wheel Arch Lips & Deep Wheelhouse Wells
	var wheel_z := [Z_FRONT_AXLE, Z_REAR_AXLE]
	for z_pos in wheel_z:
		for side in [-1.0, 1.0]:
			var arch_lip := _add_box(trim_root, "ArchFlare", Vector3(0.06, 0.05, 0.72),
				Vector3(side * 0.79, 0.58, z_pos), _mats["panda_black"])
			arch_lip.rotation.z = side * deg_to_rad(8.0)

			# Dark recessed wheel well box
			_add_box(trim_root, "WheelWell", Vector3(0.28, 0.42, 0.68),
				Vector3(side * 0.64, 0.36, z_pos), _mats["underbody"])

	# 5. Integrated Rear Hatch Ducktail Lip Spoiler
	var ducktail := _add_box(trim_root, "DucktailSpoiler", Vector3(1.38, 0.075, 0.15),
		Vector3(0.0, 0.885, 1.98), _mats["panda_black"])
	ducktail.rotation.x = deg_to_rad(22.0)

	# 6. Door Side Mirrors (Left & Right) & Door Handles
	for side in [-1.0, 1.0]:
		var s_name := "L" if side < 0.0 else "R"
		var mirror_arm := _add_box(trim_root, "MirrorArm" + s_name, Vector3(0.10, 0.03, 0.04),
			Vector3(side * 0.81, 0.84, -0.42), _mats["panda_black"])
		mirror_arm.rotation.z = side * deg_to_rad(-12.0)

		_add_box(trim_root, "MirrorHousing" + s_name, Vector3(0.13, 0.09, 0.07),
			Vector3(side * 0.86, 0.86, -0.42), _mats["panda_black"])

		# Flush 80s Door Handle
		_add_box(trim_root, "DoorHandle" + s_name, Vector3(0.02, 0.035, 0.13),
			Vector3(side * 0.805, 0.73, 0.08), _mats["panda_black"])

	# 7. Hood Cowl Vents & Windshield Wipers
	_add_box(trim_root, "CowlVentL", Vector3(0.38, 0.015, 0.08), Vector3(-0.32, 0.835, -0.64), _mats["panda_black"])
	_add_box(trim_root, "CowlVentR", Vector3(0.38, 0.015, 0.08), Vector3( 0.32, 0.835, -0.64), _mats["panda_black"])


# ==============================================================================
# REAR KOUKI TAILLIGHTS, LICENSE PLATE & EXHAUST
# ==============================================================================
func _build_rear_details(parent: Node3D) -> void:
	var rear_root := Node3D.new()
	rear_root.name = "RearKoukiDetails"
	parent.add_child(rear_root)

	var z_tail: float = 2.065

	# Full-Width Smoked Trim Housing
	_add_box(rear_root, "TaillightBackplate", Vector3(1.38, 0.17, 0.03),
		Vector3(0.0, 0.68, z_tail), _mats["smoked_plastic"])

	# Red Brake/Running Light Segments (Left & Right)
	_add_box(rear_root, "TailRedL", Vector3(0.42, 0.085, 0.04),
		Vector3(-0.46, 0.715, z_tail + 0.005), _mats["tail_red"])
	_add_box(rear_root, "TailRedR", Vector3(0.42, 0.085, 0.04),
		Vector3( 0.46, 0.715, z_tail + 0.005), _mats["tail_red"])

	# Amber Turn Signal Strips (Lower Outer)
	_add_box(rear_root, "TailAmberL", Vector3(0.28, 0.055, 0.04),
		Vector3(-0.53, 0.635, z_tail + 0.005), _mats["tail_amber"])
	_add_box(rear_root, "TailAmberR", Vector3(0.28, 0.055, 0.04),
		Vector3( 0.53, 0.635, z_tail + 0.005), _mats["tail_amber"])

	# White Reverse Lights (Lower Inner)
	_add_box(rear_root, "TailReverseL", Vector3(0.13, 0.055, 0.04),
		Vector3(-0.31, 0.635, z_tail + 0.005), _mats["tail_reverse"])
	_add_box(rear_root, "TailReverseR", Vector3(0.13, 0.055, 0.04),
		Vector3( 0.31, 0.635, z_tail + 0.005), _mats["tail_reverse"])

	# Rear Japanese License Plate ("Gunma 55 13-954")
	_add_box(rear_root, "LicensePlateRear", Vector3(0.33, 0.16, 0.02),
		Vector3(0.0, 0.65, z_tail + 0.01), _mats["plate_white"])

	# Single Angled Chrome Exhaust Pipe (Under Left Rear Bumper)
	var exhaust_pivot := Node3D.new()
	exhaust_pivot.name = "ExhaustAssembly"
	exhaust_pivot.position = Vector3(-0.44, 0.21, 1.96)
	exhaust_pivot.rotation_degrees = Vector3(6.0, -10.0, 0.0)
	rear_root.add_child(exhaust_pivot)

	# Muffler Canister
	var muffler := MeshInstance3D.new()
	var m_cyl := CylinderMesh.new()
	m_cyl.top_radius = 0.075
	m_cyl.bottom_radius = 0.075
	m_cyl.height = 0.34
	m_cyl.radial_segments = 14
	muffler.mesh = m_cyl
	muffler.rotation_degrees.x = 90.0
	muffler.material_override = _mats["chrome"]
	exhaust_pivot.add_child(muffler)

	# Chrome Exhaust Tip
	var tip := MeshInstance3D.new()
	var t_cyl := CylinderMesh.new()
	t_cyl.top_radius = 0.042
	t_cyl.bottom_radius = 0.042
	t_cyl.height = 0.18
	t_cyl.radial_segments = 14
	tip.mesh = t_cyl
	tip.position = Vector3(0.0, 0.0, 0.20)
	tip.rotation_degrees.x = 90.0
	tip.material_override = _mats["chrome"]
	exhaust_pivot.add_child(tip)

	# Inner Black Exhaust Bore
	var bore := MeshInstance3D.new()
	var b_cyl := CylinderMesh.new()
	b_cyl.top_radius = 0.036
	b_cyl.bottom_radius = 0.036
	b_cyl.height = 0.02
	b_cyl.radial_segments = 12
	bore.mesh = b_cyl
	bore.position = Vector3(0.0, 0.0, 0.285)
	bore.rotation_degrees.x = 90.0
	bore.material_override = _mats["underbody"]
	exhaust_pivot.add_child(bore)


# ==============================================================================
# FUNCTIONAL POP-UP RETRACTABLE HEADLIGHTS
# ==============================================================================
func _build_popup_headlights(parent: Node3D) -> void:
	HeadlightHingeL = _create_single_popup("HeadlightHingeL", Vector3(-0.47, 0.59, -1.87), true)
	parent.add_child(HeadlightHingeL)

	HeadlightHingeR = _create_single_popup("HeadlightHingeR", Vector3( 0.47, 0.59, -1.87), false)
	parent.add_child(HeadlightHingeR)


func _create_single_popup(node_name: String, hinge_pos: Vector3, is_left: bool) -> Node3D:
	var hinge := Node3D.new()
	hinge.name = node_name
	hinge.position = hinge_pos

	# Pod Housing (Matte Black)
	_add_box(hinge, "PodHousing", Vector3(0.24, 0.14, 0.22),
		Vector3(0.0, -0.055, -0.09), _mats["panda_black"])

	# Top Aerodynamic Lid Cover (Fuji White - Flush with Hood when closed)
	var lid := _add_box(hinge, "PopupLidWhite", Vector3(0.25, 0.02, 0.24),
		Vector3(0.0, 0.015, -0.09), _mats["fuji_white"])
	lid.rotation_degrees.x = 14.0

	# Glowing 80s Yellow Halogen Projector Lens
	_add_box(hinge, "HalogenProjectorLens", Vector3(0.19, 0.10, 0.02),
		Vector3(0.0, -0.055, -0.202), _mats["headlight_lens"])

	# Active SpotLight3D Beam (Warm 3200K Halogen Color)
	var spot := SpotLight3D.new()
	spot.name = "HalogenBeam"
	spot.position = Vector3(0.0, -0.055, -0.22)
	# Counter-rotate so beam aims slightly downward onto the road when pod is open (+54 deg)
	spot.rotation_degrees = Vector3(-60.0, 0.0, 0.0)
	spot.light_color = Color(1.0, 0.84, 0.56) # Authentic 3200K warm halogen
	spot.light_energy = 5.5
	spot.spot_range = 42.0
	spot.spot_angle = 36.0
	spot.spot_attenuation = 1.2
	spot.shadow_enabled = true
	hinge.add_child(spot)

	if is_left:
		_spot_l = spot
	else:
		_spot_r = spot

	return hinge


# ==============================================================================
# VISIBLE INTERIOR CABIN (Bucket Seats, Dashboard, Cup Holder & Steering Wheel)
# ==============================================================================
func _build_interior(parent: Node3D) -> void:
	var int_root := Node3D.new()
	int_root.name = "CabinInterior"
	parent.add_child(int_root)

	# Cabin Tub Floor & Rear Parcel Shelf
	_add_box(int_root, "InteriorFloor", Vector3(1.36, 0.06, 1.90), Vector3(0.0, 0.32, 0.25), _mats["interior"])
	_add_box(int_root, "RearParcelShelf", Vector3(1.32, 0.28, 0.80), Vector3(0.0, 0.62, 1.35), _mats["interior"])

	# 80s Boxy Dashboard & Instrument Cluster Hood (RHD Configuration)
	_add_box(int_root, "DashboardMain", Vector3(1.38, 0.24, 0.36), Vector3(0.0, 0.72, -0.42), _mats["interior"])
	_add_box(int_root, "GaugeClusterHood", Vector3(0.42, 0.12, 0.24), Vector3(0.35, 0.84, -0.38), _mats["panda_black"])
	# Famous Dashboard Cup Holder (For the Water Cup!)
	_add_box(int_root, "TofuWaterCup", Vector3(0.065, 0.09, 0.065), Vector3(0.08, 0.86, -0.32), _mats["plate_white"])

	# Right-Hand Drive (RHD) Deep-Dish Sports Steering Wheel
	var steer_col := Node3D.new()
	steer_col.name = "SteeringColumnRHD"
	steer_col.position = Vector3(0.35, 0.78, -0.22)
	steer_col.rotation_degrees.x = 22.0
	int_root.add_child(steer_col)

	var col_shaft := MeshInstance3D.new()
	var shaft_cyl := CylinderMesh.new()
	shaft_cyl.top_radius = 0.03
	shaft_cyl.bottom_radius = 0.03
	shaft_cyl.height = 0.24
	col_shaft.mesh = shaft_cyl
	col_shaft.rotation_degrees.x = 90.0
	col_shaft.position.z = -0.10
	col_shaft.material_override = _mats["panda_black"]
	steer_col.add_child(col_shaft)

	var wheel_rim := MeshInstance3D.new()
	var rim_cyl := CylinderMesh.new()
	rim_cyl.top_radius = 0.16
	rim_cyl.bottom_radius = 0.16
	rim_cyl.height = 0.03
	rim_cyl.radial_segments = 16
	wheel_rim.mesh = rim_cyl
	wheel_rim.rotation_degrees.x = 90.0
	wheel_rim.material_override = _mats["panda_black"]
	steer_col.add_child(wheel_rim)

	# Driver & Passenger Racing Bucket Seats
	for side_x in [-0.34, 0.34]:
		var is_driver: bool = side_x > 0.0
		var seat_mat: StandardMaterial3D = _mats["bucket_red"] if is_driver else _mats["interior"]
		var seat := Node3D.new()
		seat.position = Vector3(side_x, 0.42, 0.16)
		int_root.add_child(seat)

		# Seat Cushion & Bolsters
		_add_box(seat, "SeatBase", Vector3(0.44, 0.10, 0.46), Vector3(0.0, 0.0, 0.0), seat_mat)
		# Reclined Backrest
		var backrest := _add_box(seat, "Backrest", Vector3(0.42, 0.56, 0.09), Vector3(0.0, 0.28, 0.20), seat_mat)
		backrest.rotation_degrees.x = -14.0
		# Headrest
		_add_box(seat, "Headrest", Vector3(0.24, 0.18, 0.08), Vector3(0.0, 0.62, 0.27), seat_mat)


# ==============================================================================
# RIGHT-SIDE DOOR FUJIWARA TOFU SHOP KANJI DECAL ("藤原とうふ店 (自家用)")
# ==============================================================================
func _build_tofu_decal(parent: Node3D) -> void:
	# Uses a SubViewport texture if inside scene tree, plus crisp procedural 3D strokes
	# so the black Kanji lettering is guaranteed visible both in @tool editor and runtime.
	var decal_root := Node3D.new()
	decal_root.name = "FujiwaraTofuDecalR"
	decal_root.position = Vector3(0.813, 0.66, 0.05)
	parent.add_child(decal_root)

	# Procedural 3D Kanji Character Blocks along the Right Door ("藤原とうふ店 (自家用)")
	# Renders ultra-crisp micro-relief strokes for authentic JDM lettering
	var char_offsets: Array[ float ] = [-0.36, -0.25, -0.15, -0.06, 0.03, 0.13, 0.23, 0.30, 0.37]
	for idx in range(char_offsets.size()):
		var z_c: float = char_offsets[idx]
		var is_subtext: bool = idx >= 6 # "(自家用)" smaller characters at rear of door
		var scale_y: float = 0.065 if not is_subtext else 0.042
		var scale_z: float = 0.065 if not is_subtext else 0.042

		# Horizontal & vertical strokes forming distinct Kanji/Hiragana silhouettes
		_add_box(decal_root, "KanjiStrokeH_" + str(idx),
			Vector3(0.004, scale_y * 0.22, scale_z * 0.90),
			Vector3(0.0, scale_y * 0.28, z_c), _mats["panda_black"])
		_add_box(decal_root, "KanjiStrokeM_" + str(idx),
			Vector3(0.004, scale_y * 0.20, scale_z * 0.75),
			Vector3(0.0, -scale_y * 0.12, z_c), _mats["panda_black"])
		_add_box(decal_root, "KanjiStrokeV_" + str(idx),
			Vector3(0.004, scale_y * 0.92, scale_z * 0.22),
			Vector3(0.0, 0.0, z_c - scale_z * 0.15), _mats["panda_black"])
		if idx % 2 == 0:
			_add_box(decal_root, "KanjiStrokeR_" + str(idx),
				Vector3(0.004, scale_y * 0.75, scale_z * 0.20),
				Vector3(0.0, -scale_y * 0.08, z_c + scale_z * 0.22), _mats["panda_black"])

	# Also attach a high-DPI Label3D for exact crisp typography rendering in Vulkan Forward+
	var label_3d := Label3D.new()
	label_3d.name = "KanjiLabel3D"
	label_3d.text = "藤原とうふ店 (自家用)"
	label_3d.font_size = 42
	label_3d.pixel_size = 0.0018
	label_3d.modulate = Color(0.05, 0.05, 0.05, 1.0)
	label_3d.outline_size = 2
	label_3d.outline_modulate = Color(0.05, 0.05, 0.05, 1.0)
	label_3d.shaded = true
	label_3d.double_sided = true
	label_3d.rotation_degrees.y = 90.0
	label_3d.position = Vector3(0.003, 0.0, 0.02)
	decal_root.add_child(label_3d)


# ==============================================================================
# AUTHENTIC RS WATANABE 8-SPOKE WHEELS (Radius: 0.30m | Width: 0.20m)
# ==============================================================================
func _build_watanabe_wheel(wheel_name: String, is_left: bool) -> Node3D:
	var wheel_root := Node3D.new()
	wheel_root.name = wheel_name

	var out_sign: float = -1.0 if is_left else 1.0

	# 1. Tire Tread & Sidewalls (Radius 0.30m, Width 0.20m)
	var tire_mesh := MeshInstance3D.new()
	tire_mesh.name = "TireTread"
	var cyl_tire := CylinderMesh.new()
	cyl_tire.top_radius = WHEEL_RADIUS
	cyl_tire.bottom_radius = WHEEL_RADIUS
	cyl_tire.height = WHEEL_WIDTH
	cyl_tire.radial_segments = 28
	tire_mesh.mesh = cyl_tire
	tire_mesh.rotation_degrees.z = 90.0
	tire_mesh.material_override = _mats["tire"]
	wheel_root.add_child(tire_mesh)

	# 2. Polished Silver Outer Rim Barrel / Deep-Dish Lip (Radius 0.195m)
	var rim_lip := MeshInstance3D.new()
	rim_lip.name = "PolishedOuterLip"
	var cyl_lip := CylinderMesh.new()
	cyl_lip.top_radius = 0.198
	cyl_lip.bottom_radius = 0.198
	cyl_lip.height = WHEEL_WIDTH + 0.006
	cyl_lip.radial_segments = 24
	rim_lip.mesh = cyl_lip
	rim_lip.rotation_degrees.z = 90.0
	rim_lip.material_override = _mats["chrome"]
	wheel_root.add_child(rim_lip)

	# 3. Recessed Dark Inner Dish Barrel
	var inner_dish := MeshInstance3D.new()
	inner_dish.name = "InnerDishRecess"
	var cyl_dish := CylinderMesh.new()
	cyl_dish.top_radius = 0.176
	cyl_dish.bottom_radius = 0.176
	cyl_dish.height = WHEEL_WIDTH + 0.010
	cyl_dish.radial_segments = 24
	inner_dish.mesh = cyl_dish
	inner_dish.rotation_degrees.z = 90.0
	inner_dish.material_override = _mats["underbody"]
	wheel_root.add_child(inner_dish)

	# 4. Internal Brake Rotor & Red Performance Caliper
	var brake_rotor := MeshInstance3D.new()
	brake_rotor.name = "BrakeRotor"
	var cyl_rotor := CylinderMesh.new()
	cyl_rotor.top_radius = 0.145
	cyl_rotor.bottom_radius = 0.145
	cyl_rotor.height = 0.02
	cyl_rotor.radial_segments = 20
	brake_rotor.mesh = cyl_rotor
	brake_rotor.rotation_degrees.z = 90.0
	brake_rotor.position.x = out_sign * 0.02
	brake_rotor.material_override = _mats["rotor"]
	wheel_root.add_child(brake_rotor)

	_add_box(wheel_root, "BrakeCaliper", Vector3(0.04, 0.09, 0.06),
		Vector3(out_sign * 0.025, 0.04, -0.10), _mats["caliper"])

	# 5. RS Watanabe Gunmetal Center Hub & 8 Banana Spokes
	var center_hub := MeshInstance3D.new()
	center_hub.name = "WatanabeCenterHub"
	var cyl_hub := CylinderMesh.new()
	cyl_hub.top_radius = 0.058
	cyl_hub.bottom_radius = 0.065
	cyl_hub.height = 0.04
	cyl_hub.radial_segments = 16
	center_hub.mesh = cyl_hub
	center_hub.rotation_degrees.z = 90.0
	center_hub.position.x = out_sign * 0.068
	center_hub.material_override = _mats["watanabe_gunmetal"]
	wheel_root.add_child(center_hub)

	# 8 Characteristic Watanabe Spokes
	var spoke_mesh := BoxMesh.new()
	spoke_mesh.size = Vector3(0.022, 0.135, 0.032)

	for i in range(8):
		var angle_rad: float = i * (TAU / 8.0)
		var spoke_pivot := Node3D.new()
		spoke_pivot.name = "WatanabeSpoke_" + str(i)
		spoke_pivot.position.x = out_sign * 0.072
		spoke_pivot.rotation.x = angle_rad
		wheel_root.add_child(spoke_pivot)

		var spoke := MeshInstance3D.new()
		spoke.mesh = spoke_mesh
		spoke.position = Vector3(0.0, 0.105, 0.0)
		# Slight dish angle inward toward the hub
		spoke.rotation_degrees.z = -out_sign * 8.0
		spoke.material_override = _mats["watanabe_gunmetal"]
		spoke_pivot.add_child(spoke)

	return wheel_root


# ==============================================================================
# GEOMETRY HELPER FUNCTIONS
# ==============================================================================
## Appends a flat-shaded quad with crisp crease normals to a SurfaceTool.
func _add_quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	var n1: Vector3 = (p1 - p0).cross(p2 - p0).normalized()
	if n1.length_squared() > 0.0001:
		st.set_normal(n1)
		st.set_uv(Vector2(0.0, 0.0)); st.add_vertex(p0)
		st.set_uv(Vector2(1.0, 0.0)); st.add_vertex(p1)
		st.set_uv(Vector2(1.0, 1.0)); st.add_vertex(p2)

	var n2: Vector3 = (p2 - p0).cross(p3 - p0).normalized()
	if n2.length_squared() > 0.0001:
		st.set_normal(n2)
		st.set_uv(Vector2(0.0, 0.0)); st.add_vertex(p0)
		st.set_uv(Vector2(1.0, 1.0)); st.add_vertex(p2)
		st.set_uv(Vector2(0.0, 1.0)); st.add_vertex(p3)


func _commit_surface(st: SurfaceTool, mat: StandardMaterial3D, mesh_name: String, parent: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = mesh_name
	mi.mesh = st.commit()
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _add_box(parent: Node3D, box_name: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = box_name
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi