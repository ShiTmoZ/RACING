class_name JDMVehicleFleetManager
extends Node3D
## Production JDM Fleet Modeler, Spec Preset Registry, and Live Vehicle Switcher
## Project: "ShiTmoZ/RACING" (Mount Akina Touge) - Godot 4.3 (Vulkan Forward+)

signal vehicle_applied(vehicle_id: int, spec_data: Dictionary)
signal headlights_toggled(is_open: bool)

enum VehicleID {
	AE86_TRUENO = 0,
	RX7_FD3S = 1,
	R34_SKYLINE = 2
}

@export_group("Target Physics Host")
@export var target_player_vehicle: Node3D
@export var default_vehicle_id: VehicleID = VehicleID.AE86_TRUENO
@export var enable_ui_hotkey: bool = true

# Active Runtime State
var current_vehicle_id: int = VehicleID.AE86_TRUENO
var active_visual_root: Node3D = null
var headlights_up: bool = true
var _headlight_hinges: Array[Node3D] = []
var _headlight_spotlights: Array[SpotLight3D] = []
var _preview_headlight_hinges: Array[Node3D] = []
var _preview_headlight_spotlights: Array[SpotLight3D] = []

# UI & 3D Turntable Studio Nodes
var _ui_layer: CanvasLayer
var _main_overlay: Control
var _preview_viewport: SubViewport
var _preview_turntable: Node3D
var _preview_car_root: Node3D
var _selected_carousel_idx: int = 0
var _is_ui_open: bool = false

# UI Dynamic Labels & Bars
var _lbl_title: Label
var _lbl_subtitle: Label
var _lbl_engine: Label
var _lbl_weight: Label
var _lbl_power: Label
var _lbl_redline: Label
var _lbl_drivetrain: Label
var _lbl_desc: Label
var _bar_power: ProgressBar
var _bar_lightness: ProgressBar
var _bar_response: ProgressBar
var _tab_buttons: Array[Button] = []

# Immutable JDM Touge Vehicle Spec Database
const VEHICLE_SPECS: Dictionary = {
	VehicleID.AE86_TRUENO: {
		"id": VehicleID.AE86_TRUENO,
		"code": "AE86",
		"name": "Toyota Sprinter Trueno GT-APEX (AE86)",
		"subtitle": "Akina Downhill Specialist • High-agility Featherweight",
		"engine_code": "1.6L 4A-GE 16V DOHC N/A",
		"curb_mass": 960.0,
		"horsepower": 175,
		"engine_peak_torque": 192.0,
		"redline_rpm": 8200.0,
		"idle_rpm": 950.0,
		"drivetrain": "FR",
		"gear_ratios": [3.587, 2.022, 1.384, 1.000, 0.861],
		"reverse_ratio": -3.484,
		"final_drive": 4.778,
		"steering_speed_scale": 1.24,
		"cg_height_offset": -0.05,
		"wheelbase": 2.40,
		"track_width": 1.46,
		"wheel_radius": 0.30,
		"wheel_width": 0.20,
		"stat_power": 52.0,
		"stat_lightness": 96.0,
		"stat_response": 98.0,
		"description": "Featherweight 960 kg chassis paired with a screaming 8,200 RPM naturally aspirated 4A-GE. Built to carry relentless corner entry speed and rotate effortlessly through tight Mount Akina hairpins."
	},
	VehicleID.RX7_FD3S: {
		"id": VehicleID.RX7_FD3S,
		"code": "FD3S",
		"name": "Mazda Efini RX-7 Type R (FD3S)",
		"subtitle": "Akagi RedSuns Spec • Twin-Turbo Rotary Aero Coupe",
		"engine_code": "1.3L 13B-REW Sequential Twin-Turbo Rotary",
		"curb_mass": 1280.0,
		"horsepower": 280,
		"engine_peak_torque": 345.0,
		"redline_rpm": 8000.0,
		"idle_rpm": 850.0,
		"drivetrain": "FR",
		"gear_ratios": [3.483, 2.015, 1.391, 1.000, 0.762],
		"reverse_ratio": -3.288,
		"final_drive": 4.100,
		"steering_speed_scale": 1.12,
		"cg_height_offset": -0.09,
		"wheelbase": 2.44,
		"track_width": 1.52,
		"wheel_radius": 0.315,
		"wheel_width": 0.235,
		"stat_power": 82.0,
		"stat_lightness": 78.0,
		"stat_response": 91.0,
		"description": "Front-midship 50:50 weight distribution powered by a smooth, explosive 13B-REW Twin-Turbo rotary. Exceptional high-speed downforce and progressive mid-corner boost slip control."
	},
	VehicleID.R34_SKYLINE: {
		"id": VehicleID.R34_SKYLINE,
		"code": "BNR34",
		"name": "Nissan Skyline GT-R V-Spec II (BNR34)",
		"subtitle": "Godzilla Touge Spec • ATTESA E-TS Pro Power Grip",
		"engine_code": "2.6L RB26DETT Twin-Turbo I6",
		"curb_mass": 1560.0,
		"horsepower": 330,
		"engine_peak_torque": 425.0,
		"redline_rpm": 8000.0,
		"idle_rpm": 900.0,
		"drivetrain": "4WD",
		"gear_ratios": [3.827, 2.360, 1.685, 1.312, 1.000, 0.793],
		"reverse_ratio": -3.280,
		"final_drive": 3.545,
		"steering_speed_scale": 1.00,
		"cg_height_offset": -0.04,
		"wheelbase": 2.66,
		"track_width": 1.54,
		"wheel_radius": 0.33,
		"wheel_width": 0.255,
		"stat_power": 98.0,
		"stat_lightness": 54.0,
		"stat_response": 80.0,
		"description": "Heavyweight Twin-Turbo RB26 powerhouse with unmatched corner-exit traction. Uses massive torque and all-wheel grip to rocket out of uphill corners and dominate high-speed straights."
	}
}


func _ready() -> void:
	_build_selection_ui()
	_refresh_carousel_view(default_vehicle_id)
	if is_instance_valid(target_player_vehicle):
		apply_vehicle_to_player(target_player_vehicle, default_vehicle_id)
	else:
		var fallback_player: Node3D = _locate_arcade_sim_vehicle()
		if is_instance_valid(fallback_player):
			target_player_vehicle = fallback_player
			apply_vehicle_to_player(target_player_vehicle, default_vehicle_id)


func _process(delta: float) -> void:
	# Rotate the 3D preview turntable smoothly when UI is visible
	if _is_ui_open and is_instance_valid(_preview_turntable):
		_preview_turntable.rotate_y(delta * 0.55)

	# Smoothly interpolate pop-up headlight hinges on both active player car and UI preview
	var target_pitch_deg: float = 0.0 if headlights_up else -58.0
	var target_pitch_rad: float = deg_to_rad(target_pitch_deg)

	for hinge in _headlight_hinges:
		if is_instance_valid(hinge):
			hinge.rotation.x = lerp_angle(hinge.rotation.x, target_pitch_rad, delta * 12.0)

	for spot in _headlight_spotlights:
		if is_instance_valid(spot):
			spot.visible = headlights_up

	for p_hinge in _preview_headlight_hinges:
		if is_instance_valid(p_hinge):
			p_hinge.rotation.x = lerp_angle(p_hinge.rotation.x, target_pitch_rad, delta * 12.0)

	for p_spot in _preview_headlight_spotlights:
		if is_instance_valid(p_spot):
			p_spot.visible = headlights_up


func _unhandled_input(event: InputEvent) -> void:
	if not enable_ui_hotkey:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event: InputEventKey = event as InputEventKey
		if key_event.keycode == KEY_C:
			toggle_selection_ui()
			get_viewport().set_input_as_handled()
		elif key_event.keycode == KEY_H:
			toggle_popup_headlights()
			get_viewport().set_input_as_handled()
		elif _is_ui_open:
			if key_event.keycode == KEY_LEFT or key_event.keycode == KEY_A:
				_cycle_carousel(-1)
				get_viewport().set_input_as_handled()
			elif key_event.keycode == KEY_RIGHT or key_event.keycode == KEY_D:
				_cycle_carousel(1)
				get_viewport().set_input_as_handled()
			elif key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER:
				_on_confirm_drive_pressed()
				get_viewport().set_input_as_handled()
			elif key_event.keycode == KEY_ESCAPE:
				set_selection_ui_visible(false)
				get_viewport().set_input_as_handled()


# ==============================================================================
# PUBLIC API: HOT-SWAP VEHICLE & PHYSICS PROFILE WITHOUT REGRESSION
# ==============================================================================

func apply_vehicle_to_player(vehicle_node: Node3D, vehicle_id: int) -> void:
	if not is_instance_valid(vehicle_node):
		push_warning("JDMVehicleFleetManager: Invalid vehicle_node passed to apply_vehicle_to_player().")
		return

	if not VEHICLE_SPECS.has(vehicle_id):
		push_warning("JDMVehicleFleetManager: Unknown vehicle_id %d, defaulting to AE86." % vehicle_id)
		vehicle_id = VehicleID.AE86_TRUENO

	current_vehicle_id = vehicle_id
	target_player_vehicle = vehicle_node
	var spec: Dictionary = VEHICLE_SPECS[vehicle_id]

	# 1. Remove previous visual mesh root while preserving all raycasts, audio, and physics children
	var existing_visual: Node = vehicle_node.get_node_or_null("VisualChassisRoot")
	if is_instance_valid(existing_visual):
		vehicle_node.remove_child(existing_visual)
		existing_visual.queue_free()

	_headlight_hinges.clear()
	_headlight_spotlights.clear()

	# 2. Build the new procedural 3D model and attach to vehicle_node
	var new_visual_root: Node3D = build_vehicle_model(vehicle_id, false)
	new_visual_root.name = "VisualChassisRoot"
	vehicle_node.add_child(new_visual_root)
	active_visual_root = new_visual_root

	# 3. Extract procedural Wheel Node3D references (WheelFL, WheelFR, WheelRL, WheelRR)
	var wheel_fl: Node3D = new_visual_root.get_node_or_null("WheelFL") as Node3D
	var wheel_fr: Node3D = new_visual_root.get_node_or_null("WheelFR") as Node3D
	var wheel_rl: Node3D = new_visual_root.get_node_or_null("WheelRL") as Node3D
	var wheel_rr: Node3D = new_visual_root.get_node_or_null("WheelRR") as Node3D

	# 4. Safely bind wheel references & metadata to ArcadeSimVehicle without mutating physics solvers
	_rebind_vehicle_wheel_nodes(vehicle_node, wheel_fl, wheel_fr, wheel_rl, wheel_rr)
	_apply_safe_vehicle_metadata(vehicle_node, spec)

	vehicle_applied.emit(vehicle_id, spec)


func toggle_popup_headlights() -> void:
	headlights_up = not headlights_up
	headlights_toggled.emit(headlights_up)


func build_vehicle_model(vehicle_id: int, is_preview: bool = false) -> Node3D:
	var model_root: Node3D
	match vehicle_id:
		VehicleID.AE86_TRUENO:
			model_root = _build_ae86_trueno_mesh(is_preview)
		VehicleID.RX7_FD3S:
			model_root = _build_rx7_fd3s_mesh(is_preview)
		VehicleID.R34_SKYLINE:
			model_root = _build_r34_skyline_compatible_mesh(is_preview)
		_:
			model_root = _build_ae86_trueno_mesh(is_preview)

	if is_preview:
		_set_render_layer_recursive(model_root, 1 << 19) # Layer 20 isolated studio
	return model_root


# ==============================================================================
# SAFE METADATA & WHEEL RE-BINDING FOR ARCADESIMVEHICLE.GD
# ==============================================================================

func _rebind_vehicle_wheel_nodes(
	vehicle_node: Node3D,
	w_fl: Node3D,
	w_fr: Node3D,
	w_rl: Node3D,
	w_rr: Node3D
) -> void:
	# Support direct property names commonly used in ArcadeSimVehicle.gd
	var wheel_map: Dictionary = {
		"wheel_fl": w_fl, "wheel_fr": w_fr, "wheel_rl": w_rl, "wheel_rr": w_rr,
		"WheelFL": w_fl, "WheelFR": w_fr, "WheelRL": w_rl, "WheelRR": w_rr,
		"front_left_wheel": w_fl, "front_right_wheel": w_fr,
		"rear_left_wheel": w_rl, "rear_right_wheel": w_rr,
		"mesh_wheel_fl": w_fl, "mesh_wheel_fr": w_fr,
		"mesh_wheel_rl": w_rl, "mesh_wheel_rr": w_rr
	}

	var prop_list: Array[Dictionary] = vehicle_node.get_property_list()
	var existing_props: Dictionary = {}
	for prop in prop_list:
		existing_props[prop["name"]] = prop["type"]

	for prop_name in wheel_map.keys():
		if existing_props.has(prop_name):
			var target_wheel: Node3D = wheel_map[prop_name]
			if existing_props[prop_name] == TYPE_NODE_PATH:
				vehicle_node.set(prop_name, vehicle_node.get_path_to(target_wheel))
			else:
				vehicle_node.set(prop_name, target_wheel)

	# Support Array[Node3D] wheel arrays if ArcadeSimVehicle stores wheels in an indexed array
	var array_names: Array[String] = ["wheel_meshes", "wheel_nodes", "visual_wheels"]
	for arr_name in array_names:
		if existing_props.has(arr_name):
			var wheel_arr: Array[Node3D] = [w_fl, w_fr, w_rl, w_rr]
			vehicle_node.set(arr_name, wheel_arr)

	# If RayCast3D wheel nodes exist directly on vehicle_node (e.g., RayFL / WheelRayFL), align their visual targets
	var ray_aliases: Array[Array] = [
		["RayFL", "WheelRayFL", "RayCastFL", "SuspensionFL", w_fl],
		["RayFR", "WheelRayFR", "RayCastFR", "SuspensionFR", w_fr],
		["RayRL", "WheelRayRL", "RayCastRL", "SuspensionRL", w_rl],
		["RayRR", "WheelRayRR", "RayCastRR", "SuspensionRR", w_rr]
	]
	for group in ray_aliases:
		var target_w: Node3D = group[4]
		for i in range(4):
			var ray_name: String = group[i]
			var ray_node: Node = vehicle_node.get_node_or_null(ray_name)
			if is_instance_valid(ray_node):
				if "wheel_mesh" in ray_node:
					ray_node.set("wheel_mesh", target_w)
				elif "visual_wheel" in ray_node:
					ray_node.set("visual_wheel", target_w)


func _apply_safe_vehicle_metadata(vehicle_node: Node3D, spec: Dictionary) -> void:
	# Strictly update only vehicle profile metadata (mass, torque, gear ratios, redline, drive layout)
	# Never alter Kamm's circle friction solver, suspension stiffness, anti-roll bars, or drift logic.
	if vehicle_node is RigidBody3D:
		(vehicle_node as RigidBody3D).mass = float(spec["curb_mass"])

	var prop_list: Array[Dictionary] = vehicle_node.get_property_list()
	var existing_props: Dictionary = {}
	for prop in prop_list:
		existing_props[prop["name"]] = true

	var metadata_bindings: Dictionary = {
		"curb_mass": spec["curb_mass"],
		"vehicle_mass": spec["curb_mass"],
		"engine_peak_torque": spec["engine_peak_torque"],
		"peak_torque": spec["engine_peak_torque"],
		"max_torque": spec["engine_peak_torque"],
		"engine_torque": spec["engine_peak_torque"],
		"horsepower": spec["horsepower"],
		"redline_rpm": spec["redline_rpm"],
		"max_rpm": spec["redline_rpm"],
		"idle_rpm": spec["idle_rpm"],
		"gear_ratios": spec["gear_ratios"],
		"forward_gear_ratios": spec["gear_ratios"],
		"reverse_ratio": spec["reverse_ratio"],
		"final_drive": spec["final_drive"],
		"final_drive_ratio": spec["final_drive"],
		"drivetrain": spec["drivetrain"],
		"drive_layout": spec["drivetrain"],
		"steering_speed_scale": spec["steering_speed_scale"],
		"vehicle_name": spec["name"],
		"vehicle_code": spec["code"]
	}

	for key in metadata_bindings.keys():
		if existing_props.has(key):
			vehicle_node.set(key, metadata_bindings[key])

	# Also store full spec dictionary inside node metadata for HUD/Telemetry gauges
	vehicle_node.set_meta("jdm_vehicle_spec", spec)
	vehicle_node.set_meta("jdm_vehicle_id", spec["id"])


# ==============================================================================
# 1. PROCEDURAL 3D MODELER: TOYOTA SPRINTER TRUENO GT-APEX (AE86)
# ==============================================================================

func _build_ae86_trueno_mesh(is_preview: bool) -> Node3D:
	var modeler_script = preload("res://AE86TruenoModeler.gd")
	var modeler = modeler_script.new()
	var root: Node3D = modeler.build_vehicle_mesh()
	if not is_preview:
		var h_l = root.get_node_or_null("HeadlightHingeL")
		var h_r = root.get_node_or_null("HeadlightHingeR")
		if h_l != null and h_r != null:
			_headlight_hinges.append(h_l)
			_headlight_hinges.append(h_r)
	return root

	# Materials (All CULL_DISABLED per architectural specification)
	var mat_panda_white: StandardMaterial3D = _create_material(Color(0.95, 0.95, 0.93), 0.15, 0.22)
	var mat_panda_black: StandardMaterial3D = _create_material(Color(0.09, 0.09, 0.10), 0.05, 0.68)
	var mat_carbon_hood: StandardMaterial3D = _create_material(Color(0.93, 0.93, 0.91), 0.18, 0.24)
	var mat_glass_tint: StandardMaterial3D = _create_glass_material(Color(0.08, 0.11, 0.15, 0.72))
	var mat_interior: StandardMaterial3D = _create_material(Color(0.12, 0.11, 0.13), 0.0, 0.85)
	var mat_halogen_on: StandardMaterial3D = _create_emissive_material(Color(1.0, 0.92, 0.65), 4.2)
	var mat_amber_signal: StandardMaterial3D = _create_emissive_material(Color(1.0, 0.48, 0.05), 2.2)
	var mat_tail_red: StandardMaterial3D = _create_emissive_material(Color(0.95, 0.08, 0.08), 3.2)
	var mat_chrome_exhaust: StandardMaterial3D = _create_material(Color(0.82, 0.84, 0.88), 0.92, 0.18)

	var body_group: Node3D = Node3D.new()
	body_group.name = "ChassisBody"
	root.add_child(body_group)

	# 1. Lower Panda Black Rocker Panel & Underbody Tub (Length: 4.20m, Width: 1.62m)
	var lower_trim: MeshInstance3D = _create_lofted_profile_mesh(
		[
			Vector2(-2.08, 0.22), Vector2(2.06, 0.20),
			Vector2(2.10, 0.44), Vector2(-2.12, 0.46)
		],
		1.62,
		mat_panda_black,
		"LowerPandaTrim"
	)
	body_group.add_child(lower_trim)

	# 2. Upper Panda White Beltline Body & Squared 80s Fastback Quarter Panels
	var upper_body: MeshInstance3D = _create_tapered_car_section(
		# Rear face (-Z is forward in Godot, so Z > 0 is Rear, Z < 0 is Front)
		# Note: Standard Godot Vehicle conventions use -Z as forward.
		# Let's build symmetrically with -Z = Front, +Z = Rear!
		1.60, 1.56, 0.34, 4.16,
		mat_panda_white,
		"UpperPandaBody"
	)
	upper_body.position = Vector3(0.0, 0.61, 0.0)
	body_group.add_child(upper_body)

	# 3. Signature Panda Black Door Side Molding Strips
	for side_sign in [-1.0, 1.0]:
		var side_strip: MeshInstance3D = _make_box(Vector3(0.025, 0.065, 4.18), mat_panda_black, "RubStrip")
		side_strip.position = Vector3(side_sign * 0.805, 0.50, 0.0)
		body_group.add_child(side_strip)

		# Fender arches (Front & Rear squared flares)
		for z_pos in [-1.20, 1.20]:
			var flare_top: MeshInstance3D = _make_box(Vector3(0.055, 0.07, 0.74), mat_panda_black, "FenderArchTop")
			flare_top.position = Vector3(side_sign * 0.81, 0.59, z_pos)
			body_group.add_child(flare_top)

	# 4. Sloped 80s Wedge Hood (-Z front)
	var hood_mesh: MeshInstance3D = _make_box(Vector3(1.50, 0.05, 1.32), mat_carbon_hood, "HoodPanel")
	hood_mesh.position = Vector3(0.0, 0.78, -1.32)
	hood_mesh.rotation.x = deg_to_rad(-4.5)
	body_group.add_child(hood_mesh)

	# 5. Squared Fastback Greenhouse Cabin & Pillars
	var cabin_glass: MeshInstance3D = _create_greenhouse_mesh(
		1.42, 1.24, # bottom width, top width
		2.12, 1.18, # bottom length, top roof length
		0.45,       # height
		0.18,       # rear fastback shift (+Z)
		mat_glass_tint,
		"GreenhouseGlass"
	)
	cabin_glass.position = Vector3(0.0, 0.99, 0.25)
	body_group.add_child(cabin_glass)

	var roof_cap: MeshInstance3D = _make_box(Vector3(1.25, 0.035, 1.16), mat_panda_white, "RoofCap")
	roof_cap.position = Vector3(0.0, 1.22, 0.08)
	body_group.add_child(roof_cap)

	# Interior Bucket Seats & Steering Wheel visible through tinted glass
	var cabin_tub: MeshInstance3D = _make_box(Vector3(1.32, 0.28, 1.55), mat_interior, "InteriorTub")
	cabin_tub.position = Vector3(0.0, 0.76, 0.15)
	body_group.add_child(cabin_tub)

	for seat_x in [-0.34, 0.34]:
		var seat_back: MeshInstance3D = _make_box(Vector3(0.42, 0.52, 0.10), mat_interior, "BucketSeat")
		seat_back.position = Vector3(seat_x, 0.92, 0.32)
		seat_back.rotation.x = deg_to_rad(12.0)
		body_group.add_child(seat_back)

	# 6. Front Bumper (Matte Black Kouki Lip, Grille & Amber Turn Signals)
	var front_bumper: MeshInstance3D = _make_box(Vector3(1.64, 0.28, 0.22), mat_panda_black, "FrontBumper")
	front_bumper.position = Vector3(0.0, 0.35, -2.06)
	body_group.add_child(front_bumper)

	var front_lip: MeshInstance3D = _make_box(Vector3(1.62, 0.08, 0.16), mat_panda_black, "FrontChinLip")
	front_lip.position = Vector3(0.0, 0.19, -2.11)
	body_group.add_child(front_lip)

	for side_sign in [-1.0, 1.0]:
		var amber_lamp: MeshInstance3D = _make_box(Vector3(0.28, 0.075, 0.04), mat_amber_signal, "FrontTurnSignal")
		amber_lamp.position = Vector3(side_sign * 0.56, 0.41, -2.17)
		body_group.add_child(amber_lamp)

		# Side Kouki Vintage Mirrors
		var mirror_arm: MeshInstance3D = _make_box(Vector3(0.16, 0.11, 0.08), mat_panda_black, "SideMirror")
		mirror_arm.position = Vector3(side_sign * 0.86, 0.86, -0.52)
		body_group.add_child(mirror_arm)

	# "藤原とうふ店 (自家用)" Style Right-Door Decal Accent Stripe
	var tofu_plaque: MeshInstance3D = _make_box(Vector3(0.01, 0.11, 0.78), mat_panda_black, "SideDecalStripe")
	tofu_plaque.position = Vector3(0.812, 0.66, -0.05)
	body_group.add_child(tofu_plaque)

	# 7. Functional Pop-Up Retractable Headlights (Trueno Signature)
	for side_sign in [-1.0, 1.0]:
		var hinge: Node3D = Node3D.new()
		hinge.name = "PopUpHeadlightHinge_L" if side_sign < 0.0 else "PopUpHeadlightHinge_R"
		hinge.position = Vector3(side_sign * 0.54, 0.75, -1.94)
		body_group.add_child(hinge)

		var housing: MeshInstance3D = _make_box(Vector3(0.30, 0.17, 0.24), mat_panda_black, "HeadlightHousing")
		housing.position = Vector3(0.0, 0.08, -0.04)
		hinge.add_child(housing)

		var cover_lid: MeshInstance3D = _make_box(Vector3(0.31, 0.03, 0.25), mat_panda_white, "HeadlightLid")
		cover_lid.position = Vector3(0.0, 0.17, -0.04)
		hinge.add_child(cover_lid)

		var lens: MeshInstance3D = _make_box(Vector3(0.24, 0.12, 0.02), mat_halogen_on, "HalogenLens")
		lens.position = Vector3(0.0, 0.08, -0.165)
		hinge.add_child(lens)

		var beam: SpotLight3D = SpotLight3D.new()
		beam.name = "HalogenBeam"
		beam.light_color = Color(1.0, 0.93, 0.72)
		beam.light_energy = 4.5 if not is_preview else 1.5
		beam.spot_range = 38.0
		beam.spot_angle = 32.0
		beam.position = Vector3(0.0, 0.08, -0.18)
		hinge.add_child(beam)

		if is_preview:
			_preview_headlight_hinges.append(hinge)
			_preview_headlight_spotlights.append(beam)
		else:
			_headlight_hinges.append(hinge)
			_headlight_spotlights.append(beam)

	# 8. Rear Ducktail Spoiler, Vintage Rectangular Taillights & Single Under-Axle Exhaust
	var ducktail: MeshInstance3D = _make_box(Vector3(1.52, 0.13, 0.16), mat_panda_black, "RearDucktailSpoiler")
	ducktail.position = Vector3(0.0, 0.85, 2.02)
	ducktail.rotation.x = deg_to_rad(22.0)
	body_group.add_child(ducktail)

	var rear_bumper: MeshInstance3D = _make_box(Vector3(1.64, 0.26, 0.20), mat_panda_black, "RearBumper")
	rear_bumper.position = Vector3(0.0, 0.36, 2.06)
	body_group.add_child(rear_bumper)

	var rear_garnish: MeshInstance3D = _make_box(Vector3(1.48, 0.16, 0.04), mat_panda_black, "RearCenterGarnish")
	rear_garnish.position = Vector3(0.0, 0.63, 2.08)
	body_group.add_child(rear_garnish)

	for side_sign in [-1.0, 1.0]:
		var tail_red: MeshInstance3D = _make_box(Vector3(0.42, 0.13, 0.05), mat_tail_red, "VintageTailLamp")
		tail_red.position = Vector3(side_sign * 0.50, 0.61, 2.085)
		body_group.add_child(tail_red)

		var tail_amber: MeshInstance3D = _make_box(Vector3(0.42, 0.055, 0.05), mat_amber_signal, "VintageTurnBar")
		tail_amber.position = Vector3(side_sign * 0.50, 0.69, 2.085)
		body_group.add_child(tail_amber)

	var exhaust_pipe: MeshInstance3D = _make_cylinder(0.045, 0.34, mat_chrome_exhaust, "SingleExhaustTip")
	exhaust_pipe.rotation.x = deg_to_rad(90.0)
	exhaust_pipe.position = Vector3(-0.48, 0.21, 2.08)
	body_group.add_child(exhaust_pipe)

	# 9. Four Exposed Wheel Nodes (Deep-Dish 8-Spoke RS Watanabe Bronze/Gunmetal Rims)
	var spec: Dictionary = VEHICLE_SPECS[VehicleID.AE86_TRUENO]
	var half_track: float = float(spec["track_width"]) * 0.5
	var half_wb: float = float(spec["wheelbase"]) * 0.5
	var w_rad: float = float(spec["wheel_radius"])
	var w_width: float = float(spec["wheel_width"])

	var wheel_positions: Dictionary = {
		"WheelFL": Vector3(-half_track, w_rad, -half_wb),
		"WheelFR": Vector3(half_track, w_rad, -half_wb),
		"WheelRL": Vector3(-half_track, w_rad, half_wb),
		"WheelRR": Vector3(half_track, w_rad, half_wb)
	}

	for w_name in wheel_positions.keys():
		var is_left: bool = w_name.ends_with("L")
		var w_node: Node3D = _build_watanabe_8spoke_wheel(w_name, w_rad, w_width, is_left)
		w_node.position = wheel_positions[w_name]
		root.add_child(w_node)

	return root


# ==============================================================================
# 2. PROCEDURAL 3D MODELER: MAZDA RX-7 TYPE R (FD3S)
# ==============================================================================

func _build_rx7_fd3s_mesh(is_preview: bool) -> Node3D:
	var root: Node3D = Node3D.new()
	root.name = "RX7_FD3S_Visual"

	# Materials (Sunburst Mica Yellow & Aero Carbon)
	var mat_sunburst_yellow: StandardMaterial3D = _create_material(Color(0.98, 0.78, 0.04), 0.38, 0.16)
	var mat_carbon_black: StandardMaterial3D = _create_material(Color(0.08, 0.08, 0.09), 0.20, 0.45)
	var mat_smoked_lens: StandardMaterial3D = _create_material(Color(0.04, 0.04, 0.05), 0.65, 0.12)
	var mat_glass_tint: StandardMaterial3D = _create_glass_material(Color(0.06, 0.09, 0.13, 0.74))
	var mat_interior: StandardMaterial3D = _create_material(Color(0.10, 0.10, 0.12), 0.0, 0.85)
	var mat_halogen_white: StandardMaterial3D = _create_emissive_material(Color(0.92, 0.96, 1.0), 4.6)
	var mat_tail_glow: StandardMaterial3D = _create_emissive_material(Color(1.0, 0.06, 0.04), 3.8)
	var mat_amber_glow: StandardMaterial3D = _create_emissive_material(Color(1.0, 0.45, 0.02), 2.5)
	var mat_titanium_exhaust: StandardMaterial3D = _create_material(Color(0.76, 0.78, 0.86), 0.95, 0.14)

	var body_group: Node3D = Node3D.new()
	body_group.name = "ChassisBody"
	root.add_child(body_group)

	# 1. Low-Slung Curvaceous 90s Aero Core Hull
	var aero_hull: MeshInstance3D = _create_tapered_car_section(
		1.68, 1.60, 0.36, 4.24,
		mat_sunburst_yellow,
		"MainAeroBody"
	)
	aero_hull.position = Vector3(0.0, 0.49, 0.0)
	body_group.add_child(aero_hull)

	# 2. Sculpted Organic Pontoon Fenders & Side Aero Skirts
	for side_sign in [-1.0, 1.0]:
		var front_swell: MeshInstance3D = _make_capsule_fender(0.24, 1.28, mat_sunburst_yellow, "FrontFenderSwell")
		front_swell.rotation.x = deg_to_rad(90.0)
		front_swell.position = Vector3(side_sign * 0.74, 0.56, -1.16)
		body_group.add_child(front_swell)

		var rear_haunch: MeshInstance3D = _make_capsule_fender(0.26, 1.42, mat_sunburst_yellow, "RearHaunchSwell")
		rear_haunch.rotation.x = deg_to_rad(90.0)
		rear_haunch.position = Vector3(side_sign * 0.76, 0.59, 1.14)
		body_group.add_child(rear_haunch)

		var side_skirt: MeshInstance3D = _make_box(Vector3(0.10, 0.10, 2.30), mat_carbon_black, "AeroSideSkirt")
		side_skirt.position = Vector3(side_sign * 0.83, 0.24, 0.0)
		body_group.add_child(side_skirt)

		# Sleek Aerodynamic Teardrop Side Mirrors
		var aero_mirror: MeshInstance3D = _make_box(Vector3(0.18, 0.08, 0.12), mat_sunburst_yellow, "AeroMirror")
		aero_mirror.position = Vector3(side_sign * 0.89, 0.78, -0.48)
		aero_mirror.rotation.y = deg_to_rad(side_sign * -18.0)
		body_group.add_child(aero_mirror)

	# 3. Sloped Rotary Front Nose Cone & Wide Intercooler Mouth
	var nose_hood: MeshInstance3D = _make_box(Vector3(1.52, 0.06, 1.48), mat_sunburst_yellow, "SlopedRotaryHood")
	nose_hood.position = Vector3(0.0, 0.67, -1.32)
	nose_hood.rotation.x = deg_to_rad(-6.5)
	body_group.add_child(nose_hood)

	var front_splitter: MeshInstance3D = _make_box(Vector3(1.72, 0.065, 0.34), mat_carbon_black, "FrontAeroSplitter")
	front_splitter.position = Vector3(0.0, 0.18, -2.06)
	body_group.add_child(front_splitter)

	var intercooler_duct: MeshInstance3D = _make_box(Vector3(0.92, 0.18, 0.12), mat_carbon_black, "FrontAirDam")
	intercooler_duct.position = Vector3(0.0, 0.30, -2.11)
	body_group.add_child(intercooler_duct)

	for side_sign in [-1.0, 1.0]:
		var brake_duct: MeshInstance3D = _make_box(Vector3(0.28, 0.09, 0.08), mat_amber_glow, "FogTurnCombo")
		brake_duct.position = Vector3(side_sign * 0.62, 0.34, -2.12)
		body_group.add_child(brake_duct)

	# 4. Sleek Pop-Up / Integrated Aerodynamic Headlights
	for side_sign in [-1.0, 1.0]:
		var hinge: Node3D = Node3D.new()
		hinge.name = "FD_PopUpHinge_L" if side_sign < 0.0 else "FD_PopUpHinge_R"
		hinge.position = Vector3(side_sign * 0.56, 0.64, -1.92)
		body_group.add_child(hinge)

		var housing: MeshInstance3D = _make_box(Vector3(0.32, 0.14, 0.24), mat_carbon_black, "FD_HeadlightPod")
		housing.position = Vector3(0.0, 0.06, -0.04)
		hinge.add_child(housing)

		var lid: MeshInstance3D = _make_box(Vector3(0.33, 0.03, 0.26), mat_sunburst_yellow, "FD_HeadlightCover")
		lid.position = Vector3(0.0, 0.135, -0.04)
		hinge.add_child(lid)

		var lens: MeshInstance3D = _make_box(Vector3(0.26, 0.09, 0.02), mat_halogen_white, "FD_ProjectorLens")
		lens.position = Vector3(0.0, 0.06, -0.165)
		hinge.add_child(lens)

		var beam: SpotLight3D = SpotLight3D.new()
		beam.light_color = Color(0.95, 0.97, 1.0)
		beam.light_energy = 4.8 if not is_preview else 1.5
		beam.spot_range = 42.0
		beam.spot_angle = 30.0
		beam.position = Vector3(0.0, 0.06, -0.18)
		hinge.add_child(beam)

		if is_preview:
			_preview_headlight_hinges.append(hinge)
			_preview_headlight_spotlights.append(beam)
		else:
			_headlight_hinges.append(hinge)
			_headlight_spotlights.append(beam)

	# 5. Teardrop Fastback Canopy & Double-Bubble Roof
	var canopy: MeshInstance3D = _create_greenhouse_mesh(
		1.42, 1.14,
		2.08, 0.98,
		0.40,
		0.24,
		mat_glass_tint,
		"TeardropCanopy"
	)
	canopy.position = Vector3(0.0, 0.87, 0.22)
	body_group.add_child(canopy)

	# Iconic FD3S Double-Bubble Roof Domes
	for side_sign in [-1.0, 1.0]:
		var bubble: MeshInstance3D = _make_capsule_fender(0.25, 0.88, mat_sunburst_yellow, "DoubleBubbleRoof")
		bubble.rotation.x = deg_to_rad(90.0)
		bubble.scale = Vector3(1.0, 0.28, 1.0)
		bubble.position = Vector3(side_sign * 0.24, 1.06, 0.10)
		body_group.add_child(bubble)

	var interior_tub: MeshInstance3D = _make_box(Vector3(1.30, 0.25, 1.45), mat_interior, "CockpitTub")
	interior_tub.position = Vector3(0.0, 0.68, 0.14)
	body_group.add_child(interior_tub)

	# 6. Smoked Black Oval Rear Taillight Bar & Dual Round Iconic Lamps
	var smoked_bar: MeshInstance3D = _make_box(Vector3(1.56, 0.15, 0.06), mat_smoked_lens, "SmokedTaillightVisor")
	smoked_bar.position = Vector3(0.0, 0.59, 2.11)
	body_group.add_child(smoked_bar)

	for side_sign in [-1.0, 1.0]:
		for ring_idx in range(2):
			var lamp_x: float = side_sign * (0.44 + float(ring_idx) * 0.16)
			var round_tail: MeshInstance3D = _make_cylinder(0.052, 0.07, mat_tail_glow, "RoundTailLamp")
			round_tail.rotation.x = deg_to_rad(90.0)
			round_tail.position = Vector3(lamp_x, 0.59, 2.115)
			body_group.add_child(round_tail)

	# Rear Carbon Diffuser & Large Single Titanium Rotary Exhaust Cannon
	var diffuser: MeshInstance3D = _make_box(Vector3(1.52, 0.16, 0.22), mat_carbon_black, "RearAeroDiffuser")
	diffuser.position = Vector3(0.0, 0.24, 2.06)
	body_group.add_child(diffuser)

	var rotary_cannon: MeshInstance3D = _make_cylinder(0.068, 0.36, mat_titanium_exhaust, "RotaryExhaustCannon")
	rotary_cannon.rotation.x = deg_to_rad(90.0)
	rotary_cannon.position = Vector3(0.52, 0.25, 2.12)
	body_group.add_child(rotary_cannon)

	# 7. High-Mount Carbon GT-Wing Rear Spoiler with Endplates
	var gt_wing_blade: MeshInstance3D = _make_box(Vector3(1.66, 0.035, 0.26), mat_carbon_black, "GTWingAirfoil")
	gt_wing_blade.position = Vector3(0.0, 0.98, 1.98)
	gt_wing_blade.rotation.x = deg_to_rad(9.0)
	body_group.add_child(gt_wing_blade)

	for side_sign in [-1.0, 1.0]:
		var stanchion: MeshInstance3D = _make_box(Vector3(0.03, 0.26, 0.16), mat_carbon_black, "GTWingStanchion")
		stanchion.position = Vector3(side_sign * 0.44, 0.84, 1.96)
		stanchion.rotation.x = deg_to_rad(-12.0)
		body_group.add_child(stanchion)

		var endplate: MeshInstance3D = _make_box(Vector3(0.02, 0.16, 0.32), mat_carbon_black, "GTWingEndplate")
		endplate.position = Vector3(side_sign * 0.835, 0.98, 1.98)
		body_group.add_child(endplate)

	# 8. Four Exposed Wheel Nodes (Silver/Chrome Multi-Spoke Racing Rims)
	var spec: Dictionary = VEHICLE_SPECS[VehicleID.RX7_FD3S]
	var half_track: float = float(spec["track_width"]) * 0.5
	var half_wb: float = float(spec["wheelbase"]) * 0.5
	var w_rad: float = float(spec["wheel_radius"])
	var w_width: float = float(spec["wheel_width"])

	var wheel_positions: Dictionary = {
		"WheelFL": Vector3(-half_track, w_rad, -half_wb),
		"WheelFR": Vector3(half_track, w_rad, -half_wb),
		"WheelRL": Vector3(-half_track, w_rad, half_wb),
		"WheelRR": Vector3(half_track, w_rad, half_wb)
	}

	for w_name in wheel_positions.keys():
		var is_left: bool = w_name.ends_with("L")
		var w_node: Node3D = _build_chrome_multispoke_wheel(w_name, w_rad, w_width, is_left)
		w_node.position = wheel_positions[w_name]
		root.add_child(w_node)

	return root


# ==============================================================================
# 3. NISSAN SKYLINE GT-R R34 PRESET COMPATIBILITY & PROCEDURAL FALLBACK
# ==============================================================================

func _build_r34_skyline_compatible_mesh(is_preview: bool) -> Node3D:
	# 1. Check if external R34SkylineModeler.gd exists in the project and delegate seamlessly
	if ResourceLoader.exists("res://R34SkylineModeler.gd"):
		var r34_script: Script = load("res://R34SkylineModeler.gd") as Script
		if r34_script != null and r34_script.can_instantiate():
			var instance: Object = r34_script.new()
			if instance is Node3D:
				var node_r34: Node3D = instance as Node3D
				if node_r34.has_method("build_vehicle_mesh"):
					return node_r34.call("build_vehicle_mesh") as Node3D
				if node_r34.get_node_or_null("WheelFL") != null:
					return node_r34

	# 2. Built-in Procedural Bayside Blue BNR34 Skyline GT-R V-Spec II (Zero External Dependency Guarantee)
	var root: Node3D = Node3D.new()
	root.name = "R34_Skyline_Visual"

	var mat_bayside_blue: StandardMaterial3D = _create_material(Color(0.06, 0.34, 0.88), 0.55, 0.16)
	var mat_carbon_trim: StandardMaterial3D = _create_material(Color(0.09, 0.09, 0.11), 0.25, 0.42)
	var mat_glass_tint: StandardMaterial3D = _create_glass_material(Color(0.07, 0.10, 0.14, 0.74))
	var mat_xenon_headlight: StandardMaterial3D = _create_emissive_material(Color(0.85, 0.94, 1.0), 4.8)
	var mat_tail_afterburner: StandardMaterial3D = _create_emissive_material(Color(1.0, 0.05, 0.05), 4.0)
	var mat_intercooler_core: StandardMaterial3D = _create_material(Color(0.74, 0.77, 0.82), 0.85, 0.25)

	var body_group: Node3D = Node3D.new()
	body_group.name = "ChassisBody"
	root.add_child(body_group)

	# Muscular Boxy GT-R Widebody Core
	var main_hull: MeshInstance3D = _create_tapered_car_section(
		1.74, 1.70, 0.42, 4.52,
		mat_bayside_blue,
		"BNR34_MainBody"
	)
	main_hull.position = Vector3(0.0, 0.55, 0.0)
	body_group.add_child(main_hull)

	# Aggressive Boxed Overfenders & NACA Hood Duct
	for side_sign in [-1.0, 1.0]:
		var front_fender: MeshInstance3D = _make_box(Vector3(0.08, 0.34, 1.18), mat_bayside_blue, "R34_FrontBoxFender")
		front_fender.position = Vector3(side_sign * 0.86, 0.53, -1.28)
		body_group.add_child(front_fender)

		var rear_fender: MeshInstance3D = _make_box(Vector3(0.09, 0.36, 1.28), mat_bayside_blue, "R34_RearBoxFender")
		rear_fender.position = Vector3(side_sign * 0.87, 0.55, 1.26)
		body_group.add_child(rear_fender)

	var front_bumper: MeshInstance3D = _make_box(Vector3(1.76, 0.34, 0.26), mat_bayside_blue, "R34_FrontFascia")
	front_bumper.position = Vector3(0.0, 0.37, -2.20)
	body_group.add_child(front_bumper)

	var fmic_core: MeshInstance3D = _make_box(Vector3(0.86, 0.20, 0.06), mat_intercooler_core, "RB26_FrontIntercooler")
	fmic_core.position = Vector3(0.0, 0.32, -2.32)
	body_group.add_child(fmic_core)

	var lower_splitter: MeshInstance3D = _make_box(Vector3(1.78, 0.07, 0.34), mat_carbon_trim, "VSpec_CarbonDiffuser")
	lower_splitter.position = Vector3(0.0, 0.18, -2.22)
	body_group.add_child(lower_splitter)

	# Fixed Xenon Slash Headlights
	for side_sign in [-1.0, 1.0]:
		var xenon_lamp: MeshInstance3D = _make_box(Vector3(0.38, 0.13, 0.08), mat_xenon_headlight, "XenonHeadlamp")
		xenon_lamp.position = Vector3(side_sign * 0.58, 0.65, -2.24)
		body_group.add_child(xenon_lamp)

		var spot: SpotLight3D = SpotLight3D.new()
		spot.light_color = Color(0.86, 0.94, 1.0)
		spot.light_energy = 4.8 if not is_preview else 1.5
		spot.spot_range = 45.0
		spot.spot_angle = 32.0
		spot.position = Vector3(side_sign * 0.58, 0.65, -2.28)
		body_group.add_child(spot)
		if is_preview:
			_preview_headlight_spotlights.append(spot)
		else:
			_headlight_spotlights.append(spot)

	# Upright Coupe Cabin
	var cabin: MeshInstance3D = _create_greenhouse_mesh(
		1.48, 1.28,
		2.16, 1.24,
		0.44,
		0.12,
		mat_glass_tint,
		"R34_Greenhouse"
	)
	cabin.position = Vector3(0.0, 0.97, 0.12)
	body_group.add_child(cabin)

	var roof_panel: MeshInstance3D = _make_box(Vector3(1.29, 0.035, 1.22), mat_bayside_blue, "R34_Roof")
	roof_panel.position = Vector3(0.0, 1.20, 0.0)
	body_group.add_child(roof_panel)

	# Dual-Element Adjustable Rear Wing & Signature Stove-Pipe Quad Round Taillights
	var rear_wing_upper: MeshInstance3D = _make_box(Vector3(1.62, 0.04, 0.24), mat_carbon_trim, "R34_RearWingBlade")
	rear_wing_upper.position = Vector3(0.0, 1.04, 2.12)
	rear_wing_upper.rotation.x = deg_to_rad(8.0)
	body_group.add_child(rear_wing_upper)

	for side_sign in [-1.0, 1.0]:
		var wing_pillar: MeshInstance3D = _make_box(Vector3(0.05, 0.26, 0.20), mat_bayside_blue, "R34_WingPillar")
		wing_pillar.position = Vector3(side_sign * 0.58, 0.89, 2.10)
		body_group.add_child(wing_pillar)

		var outer_ring: MeshInstance3D = _make_cylinder(0.075, 0.06, mat_tail_afterburner, "OuterAfterburnerTail")
		outer_ring.rotation.x = deg_to_rad(90.0)
		outer_ring.position = Vector3(side_sign * 0.62, 0.66, 2.26)
		body_group.add_child(outer_ring)

		var inner_ring: MeshInstance3D = _make_cylinder(0.055, 0.06, mat_tail_afterburner, "InnerAfterburnerTail")
		inner_ring.rotation.x = deg_to_rad(90.0)
		inner_ring.position = Vector3(side_sign * 0.44, 0.64, 2.26)
		body_group.add_child(inner_ring)

	var spec: Dictionary = VEHICLE_SPECS[VehicleID.R34_SKYLINE]
	var half_track: float = float(spec["track_width"]) * 0.5
	var half_wb: float = float(spec["wheelbase"]) * 0.5
	var w_rad: float = float(spec["wheel_radius"])
	var w_width: float = float(spec["wheel_width"])

	var wheel_positions: Dictionary = {
		"WheelFL": Vector3(-half_track, w_rad, -half_wb),
		"WheelFR": Vector3(half_track, w_rad, -half_wb),
		"WheelRL": Vector3(-half_track, w_rad, half_wb),
		"WheelRR": Vector3(half_track, w_rad, half_wb)
	}

	for w_name in wheel_positions.keys():
		var is_left: bool = w_name.ends_with("L")
		var w_node: Node3D = _build_chrome_multispoke_wheel(w_name, w_rad, w_width, is_left)
		w_node.position = wheel_positions[w_name]
		root.add_child(w_node)

	return root


# ==============================================================================
# PROCEDURAL WHEEL BUILDERS (EXPOSED WheelFL, WheelFR, WheelRL, WheelRR)
# ==============================================================================

func _build_watanabe_8spoke_wheel(wheel_name: String, radius: float, width: float, is_left: bool) -> Node3D:
	var wheel_root: Node3D = Node3D.new()
	wheel_root.name = wheel_name

	var mat_tire: StandardMaterial3D = _create_material(Color(0.08, 0.08, 0.09), 0.05, 0.82)
	var mat_watanabe_gunmetal: StandardMaterial3D = _create_material(Color(0.26, 0.23, 0.19), 0.72, 0.34)
	var mat_machined_lip: StandardMaterial3D = _create_material(Color(0.75, 0.76, 0.78), 0.88, 0.20)
	var mat_brake_rotor: StandardMaterial3D = _create_material(Color(0.45, 0.46, 0.48), 0.85, 0.30)

	# Tire Carcass & Sidewall
	var tire_cyl: MeshInstance3D = _make_cylinder(radius, width, mat_tire, "TireSidewall")
	tire_cyl.rotation.z = deg_to_rad(90.0)
	wheel_root.add_child(tire_cyl)

	# Deep-Dish Outer Machined Barrel Lip
	var rim_radius: float = radius * 0.64
	var dish_sign: float = -1.0 if is_left else 1.0
	var rim_barrel: MeshInstance3D = _make_cylinder(rim_radius, width * 1.02, mat_machined_lip, "DeepDishLip")
	rim_barrel.rotation.z = deg_to_rad(90.0)
	wheel_root.add_child(rim_barrel)

	# Recessed Gunmetal Core & Brake Rotor
	var inner_recess: MeshInstance3D = _make_cylinder(rim_radius * 0.86, width * 0.78, mat_brake_rotor, "BrakeDisc")
	inner_recess.rotation.z = deg_to_rad(90.0)
	inner_recess.position.x = dish_sign * (-0.015)
	wheel_root.add_child(inner_recess)

	# 8-Spoke RS Watanabe Banana Spokes
	var spoke_len: float = rim_radius * 1.65
	for i in range(8):
		var angle_rad: float = deg_to_rad(float(i) * 45.0)
		var spoke: MeshInstance3D = _make_box(
			Vector3(0.022, 0.030, spoke_len),
			mat_watanabe_gunmetal,
			"WatanabeSpoke_%d" % i
		)
		spoke.position.x = dish_sign * (width * 0.34)
		spoke.rotation.x = angle_rad
		wheel_root.add_child(spoke)

	var center_cap: MeshInstance3D = _make_cylinder(0.048, width * 0.88, mat_watanabe_gunmetal, "CenterHub")
	center_cap.rotation.z = deg_to_rad(90.0)
	wheel_root.add_child(center_cap)

	return wheel_root


func _build_chrome_multispoke_wheel(wheel_name: String, radius: float, width: float, is_left: bool) -> Node3D:
	var wheel_root: Node3D = Node3D.new()
	wheel_root.name = wheel_name

	var mat_tire: StandardMaterial3D = _create_material(Color(0.07, 0.07, 0.08), 0.08, 0.78)
	var mat_chrome_silver: StandardMaterial3D = _create_material(Color(0.84, 0.87, 0.91), 0.94, 0.14)
	var mat_caliper_red: StandardMaterial3D = _create_material(Color(0.85, 0.12, 0.10), 0.45, 0.30)
	var mat_rotor: StandardMaterial3D = _create_material(Color(0.42, 0.44, 0.47), 0.85, 0.28)

	var tire_cyl: MeshInstance3D = _make_cylinder(radius, width, mat_tire, "RacingTire")
	tire_cyl.rotation.z = deg_to_rad(90.0)
	wheel_root.add_child(tire_cyl)

	var rim_radius: float = radius * 0.68
	var dish_sign: float = -1.0 if is_left else 1.0

	var rotor_mesh: MeshInstance3D = _make_cylinder(rim_radius * 0.88, width * 0.70, mat_rotor, "VentilatedRotor")
	rotor_mesh.rotation.z = deg_to_rad(90.0)
	wheel_root.add_child(rotor_mesh)

	var caliper: MeshInstance3D = _make_box(Vector3(width * 0.76, 0.11, 0.07), mat_caliper_red, "BrakeCaliper")
	caliper.position = Vector3(0.0, rim_radius * 0.48, -rim_radius * 0.45)
	wheel_root.add_child(caliper)

	# 10-Spoke Twin-Split Silver/Chrome Racing Rim
	var spoke_span: float = rim_radius * 1.78
	for i in range(5):
		var angle_rad: float = deg_to_rad(float(i) * 36.0)
		var spoke: MeshInstance3D = _make_box(
			Vector3(0.024, 0.024, spoke_span),
			mat_chrome_silver,
			"TwinSpoke_%d" % i
		)
		spoke.position.x = dish_sign * (width * 0.42)
		spoke.rotation.x = angle_rad
		wheel_root.add_child(spoke)

	var center_nut: MeshInstance3D = _make_cylinder(0.052, width * 0.92, mat_chrome_silver, "CenterLockHub")
	center_nut.rotation.z = deg_to_rad(90.0)
	wheel_root.add_child(center_nut)

	return wheel_root


# ==============================================================================
# 4. MINIMALIST JDM VEHICLE SELECTION UI & 3D TURNTABLE OVERLAY
# ==============================================================================

func toggle_selection_ui() -> void:
	set_selection_ui_visible(not _is_ui_open)


func set_selection_ui_visible(visible_state: bool) -> void:
	_is_ui_open = visible_state
	if is_instance_valid(_main_overlay):
		_main_overlay.visible = visible_state
	if visible_state:
		_refresh_carousel_view(current_vehicle_id)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _build_selection_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "JDMFleetSelectorLayer"
	_ui_layer.layer = 28
	add_child(_ui_layer)

	_main_overlay = Control.new()
	_main_overlay.name = "CarbonOverlayRoot"
	_main_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_main_overlay.visible = false
	_ui_layer.add_child(_main_overlay)

	# Backdrop Dimmer
	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color(0.03, 0.04, 0.06, 0.82)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_main_overlay.add_child(backdrop)

	# Center Carbon Modal Card
	var center_wrap: CenterContainer = CenterContainer.new()
	center_wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	_main_overlay.add_child(center_wrap)

	var card_panel: PanelContainer = PanelContainer.new()
	card_panel.custom_minimum_size = Vector2(1040.0, 610.0)
	var card_style: StyleBoxFlat = StyleBoxFlat.new()
	card_style.bg_color = Color(0.07, 0.08, 0.11, 0.96)
	card_style.border_color = Color(0.95, 0.72, 0.12, 0.85)
	card_style.set_border_width_all(2)
	card_style.set_corner_radius_all(10)
	card_style.set_content_margin_all(22)
	card_panel.add_theme_stylebox_override("panel", card_style)
	center_wrap.add_child(card_panel)

	var root_vbox: VBoxContainer = VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 16)
	card_panel.add_child(root_vbox)

	# Top Header Bar + Tabbed Vehicle Switcher
	var header_hbox: HBoxContainer = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 12)
	root_vbox.add_child(header_hbox)

	var brand_label: Label = Label.new()
	brand_label.text = "MOUNT AKINA TOUGE // GARAGE FLEET SELECTOR"
	brand_label.add_theme_font_size_override("font_size", 18)
	brand_label.add_theme_color_override("font_color", Color(0.96, 0.76, 0.15))
	brand_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(brand_label)

	_tab_buttons.clear()
	var tab_titles: Array[String] = ["[1] AE86 TRUENO", "[2] RX-7 FD3S", "[3] R34 GT-R"]
	for idx in range(tab_titles.size()):
		var tab_btn: Button = Button.new()
		tab_btn.text = tab_titles[idx]
		tab_btn.custom_minimum_size = Vector2(150.0, 36.0)
		var captured_id: int = idx
		tab_btn.pressed.connect(func() -> void: _refresh_carousel_view(captured_id))
		header_hbox.add_child(tab_btn)
		_tab_buttons.append(tab_btn)

	var btn_lights: Button = Button.new()
	btn_lights.text = "POP-UPS [H]"
	btn_lights.custom_minimum_size = Vector2(120.0, 36.0)
	btn_lights.pressed.connect(toggle_popup_headlights)
	header_hbox.add_child(btn_lights)

	# Main Split Content: Left 3D Rotating Preview + Right Specs Card
	var split_hbox: HBoxContainer = HBoxContainer.new()
	split_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split_hbox.add_theme_constant_override("separation", 22)
	root_vbox.add_child(split_hbox)

	# Left Column: 3D SubViewport Container + Carousel Arrows
	var preview_vbox: VBoxContainer = VBoxContainer.new()
	preview_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_vbox.size_flags_stretch_ratio = 1.25
	preview_vbox.add_theme_constant_override("separation", 10)
	split_hbox.add_child(preview_vbox)

	var vp_frame: PanelContainer = PanelContainer.new()
	vp_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var vp_style: StyleBoxFlat = StyleBoxFlat.new()
	vp_style.bg_color = Color(0.04, 0.05, 0.07, 1.0)
	vp_style.border_color = Color(0.22, 0.25, 0.32, 1.0)
	vp_style.set_border_width_all(1)
	vp_style.set_corner_radius_all(8)
	vp_frame.add_theme_stylebox_override("panel", vp_style)
	preview_vbox.add_child(vp_frame)

	var vp_container: SubViewportContainer = SubViewportContainer.new()
	vp_container.stretch = true
	vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_frame.add_child(vp_container)

	_preview_viewport = SubViewport.new()
	_preview_viewport.size = Vector2i(540, 380)
	_preview_viewport.own_world_3d = true
	_preview_viewport.transparent_bg = true
	_preview_viewport.msaa_3d = Viewport.MSAA_4X
	vp_container.add_child(_preview_viewport)

	_build_preview_studio_scene(_preview_viewport)

	var nav_hbox: HBoxContainer = HBoxContainer.new()
	nav_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	nav_hbox.add_theme_constant_override("separation", 18)
	preview_vbox.add_child(nav_hbox)

	var btn_prev: Button = Button.new()
	btn_prev.text = "◀ PREV CHASSIS"
	btn_prev.custom_minimum_size = Vector2(160.0, 38.0)
	btn_prev.pressed.connect(func() -> void: _cycle_carousel(-1))
	nav_hbox.add_child(btn_prev)

	var btn_next: Button = Button.new()
	btn_next.text = "NEXT CHASSIS ▶"
	btn_next.custom_minimum_size = Vector2(160.0, 38.0)
	btn_next.pressed.connect(func() -> void: _cycle_carousel(1))
	nav_hbox.add_child(btn_next)

	# Right Column: Technical Specs Card & CONFIRM & DRIVE CTA
	var specs_vbox: VBoxContainer = VBoxContainer.new()
	specs_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	specs_vbox.size_flags_stretch_ratio = 1.0
	specs_vbox.add_theme_constant_override("separation", 10)
	split_hbox.add_child(specs_vbox)

	_lbl_title = Label.new()
	_lbl_title.add_theme_font_size_override("font_size", 22)
	_lbl_title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_lbl_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	specs_vbox.add_child(_lbl_title)

	_lbl_subtitle = Label.new()
	_lbl_subtitle.add_theme_font_size_override("font_size", 13)
	_lbl_subtitle.add_theme_color_override("font_color", Color(0.95, 0.75, 0.18))
	specs_vbox.add_child(_lbl_subtitle)

	var sep_top: HSeparator = HSeparator.new()
	specs_vbox.add_child(sep_top)

	# Key-Value Spec Grid
	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 6)
	specs_vbox.add_child(grid)

	_lbl_engine = _add_spec_row(grid, "ENGINE UNIT:")
	_lbl_weight = _add_spec_row(grid, "CURB WEIGHT:")
	_lbl_power = _add_spec_row(grid, "PEAK OUTPUT:")
	_lbl_redline = _add_spec_row(grid, "REDLINE LIMIT:")
	_lbl_drivetrain = _add_spec_row(grid, "DRIVE LAYOUT:")

	var sep_mid: HSeparator = HSeparator.new()
	specs_vbox.add_child(sep_mid)

	_bar_power = _add_stat_bar(specs_vbox, "POWER & BOOST ACCELERATION")
	_bar_lightness = _add_stat_bar(specs_vbox, "TOUGE HAIRPIN AGILITY (LIGHTNESS)")
	_bar_response = _add_stat_bar(specs_vbox, "STEERING & SLIP ANGLE RESPONSE")

	_lbl_desc = Label.new()
	_lbl_desc.add_theme_font_size_override("font_size", 13)
	_lbl_desc.add_theme_color_override("font_color", Color(0.76, 0.80, 0.86))
	_lbl_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	specs_vbox.add_child(_lbl_desc)

	# Big Responsive CONFIRM & DRIVE Button
	var confirm_btn: Button = Button.new()
	confirm_btn.text = "CONFIRM & DRIVE  [ENTER]"
	confirm_btn.custom_minimum_size = Vector2(0.0, 54.0)
	confirm_btn.add_theme_font_size_override("font_size", 18)
	var btn_style: StyleBoxFlat = StyleBoxFlat.new()
	btn_style.bg_color = Color(0.92, 0.65, 0.08, 1.0)
	btn_style.set_corner_radius_all(6)
	confirm_btn.add_theme_stylebox_override("normal", btn_style)
	var btn_hover: StyleBoxFlat = btn_style.duplicate() as StyleBoxFlat
	btn_hover.bg_color = Color(1.0, 0.76, 0.16, 1.0)
	confirm_btn.add_theme_stylebox_override("hover", btn_hover)
	confirm_btn.add_theme_color_override("font_color", Color(0.05, 0.05, 0.07))
	confirm_btn.pressed.connect(_on_confirm_drive_pressed)
	specs_vbox.add_child(confirm_btn)


func _build_preview_studio_scene(vp: SubViewport) -> void:
	var studio_root: Node3D = Node3D.new()
	studio_root.name = "PreviewStudio3D"
	vp.add_child(studio_root)

	var cam: Camera3D = Camera3D.new()
	cam.cull_mask = 1 << 19 # Render Layer 20 only
	cam.fov = 38.0
	cam.position = Vector3(3.35, 1.55, -3.85)
	studio_root.add_child(cam)
	cam.look_at(Vector3(0.0, 0.55, 0.0), Vector3.UP)

	var key_light: DirectionalLight3D = DirectionalLight3D.new()
	key_light.layers = 1 << 19
	key_light.light_energy = 2.1
	key_light.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	studio_root.add_child(key_light)

	var rim_light: DirectionalLight3D = DirectionalLight3D.new()
	rim_light.layers = 1 << 19
	rim_light.light_color = Color(0.55, 0.75, 1.0)
	rim_light.light_energy = 1.15
	rim_light.rotation_degrees = Vector3(-28.0, -140.0, 0.0)
	studio_root.add_child(rim_light)

	_preview_turntable = Node3D.new()
	_preview_turntable.name = "Turntable"
	studio_root.add_child(_preview_turntable)

	# Turntable Pedestal Disc
	var mat_podium: StandardMaterial3D = _create_material(Color(0.11, 0.12, 0.15), 0.45, 0.35)
	var podium: MeshInstance3D = _make_cylinder(2.55, 0.08, mat_podium, "TurntablePodium")
	podium.layers = 1 << 19
	podium.position = Vector3(0.0, -0.04, 0.0)
	_preview_turntable.add_child(podium)

	_preview_car_root = Node3D.new()
	_preview_car_root.name = "PreviewCarHolder"
	_preview_turntable.add_child(_preview_car_root)


func _refresh_carousel_view(vehicle_id: int) -> void:
	if not VEHICLE_SPECS.has(vehicle_id):
		vehicle_id = VehicleID.AE86_TRUENO

	_selected_carousel_idx = vehicle_id
	var spec: Dictionary = VEHICLE_SPECS[vehicle_id]

	# Rebuild 3D rotating preview car
	if is_instance_valid(_preview_car_root):
		for child in _preview_car_root.get_children():
			_preview_car_root.remove_child(child)
			child.queue_free()

		_preview_headlight_hinges.clear()
		_preview_headlight_spotlights.clear()
		var preview_mesh: Node3D = build_vehicle_model(vehicle_id, true)
		_preview_car_root.add_child(preview_mesh)

	# Update Specs Labels & Bars
	if is_instance_valid(_lbl_title):
		_lbl_title.text = str(spec["name"])
		_lbl_subtitle.text = str(spec["subtitle"])
		_lbl_engine.text = str(spec["engine_code"])
		_lbl_weight.text = "%d kg" % int(spec["curb_mass"])
		_lbl_power.text = "%d HP / %d Nm" % [int(spec["horsepower"]), int(spec["engine_peak_torque"])]
		_lbl_redline.text = "%d RPM" % int(spec["redline_rpm"])
		_lbl_drivetrain.text = str(spec["drivetrain"])
		_lbl_desc.text = str(spec["description"])

		_bar_power.value = float(spec["stat_power"])
		_bar_lightness.value = float(spec["stat_lightness"])
		_bar_response.value = float(spec["stat_response"])

	for i in range(_tab_buttons.size()):
		if is_instance_valid(_tab_buttons[i]):
			_tab_buttons[i].modulate = Color(1.0, 0.85, 0.25) if i == vehicle_id else Color(0.82, 0.82, 0.82)


func _cycle_carousel(step: int) -> void:
	var count: int = VEHICLE_SPECS.size()
	var next_id: int = (_selected_carousel_idx + step + count) % count
	_refresh_carousel_view(next_id)


func _on_confirm_drive_pressed() -> void:
	if not is_instance_valid(target_player_vehicle):
		target_player_vehicle = _locate_arcade_sim_vehicle()
	if is_instance_valid(target_player_vehicle):
		apply_vehicle_to_player(target_player_vehicle, _selected_carousel_idx)
	set_selection_ui_visible(false)


# ==============================================================================
# PROCEDURAL GEOMETRY & SURFACETOOL HELPERS (CULL_DISABLED ENFORCED)
# ==============================================================================

func _create_material(albedo: Color, metallic_val: float, roughness_val: float) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.metallic = metallic_val
	mat.roughness = roughness_val
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _create_glass_material(albedo: Color) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = albedo
	mat.metallic = 0.35
	mat.roughness = 0.08
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _create_emissive_material(glow_color: Color, energy: float) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = glow_color
	mat.emission_enabled = true
	mat.emission = glow_color
	mat.emission_energy_multiplier = energy
	mat.roughness = 0.2
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _make_box(size_vec: Vector3, mat: StandardMaterial3D, node_name: String) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = node_name
	var box: BoxMesh = BoxMesh.new()
	box.size = size_vec
	box.material = mat
	mi.mesh = box
	return mi


func _make_cylinder(radius: float, height: float, mat: StandardMaterial3D, node_name: String) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = node_name
	var cyl: CylinderMesh = CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.radial_segments = 24
	cyl.material = mat
	mi.mesh = cyl
	return mi


func _make_capsule_fender(radius: float, height: float, mat: StandardMaterial3D, node_name: String) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = node_name
	var cap: CapsuleMesh = CapsuleMesh.new()
	cap.radius = radius
	cap.height = height
	cap.radial_segments = 20
	cap.rings = 6
	cap.material = mat
	mi.mesh = cap
	return mi


func _create_tapered_car_section(
	bottom_width: float,
	top_width: float,
	height: float,
	length: float,
	mat: StandardMaterial3D,
	node_name: String
) -> MeshInstance3D:
	var bw: float = bottom_width * 0.5
	var tw: float = top_width * 0.5
	var hh: float = height * 0.5
	var hl: float = length * 0.5

	var v0: Vector3 = Vector3(-bw, -hh, -hl)
	var v1: Vector3 = Vector3(bw, -hh, -hl)
	var v2: Vector3 = Vector3(tw, hh, -hl)
	var v3: Vector3 = Vector3(-tw, hh, -hl)

	var v4: Vector3 = Vector3(-bw, -hh, hl)
	var v5: Vector3 = Vector3(bw, -hh, hl)
	var v6: Vector3 = Vector3(tw, hh, hl)
	var v7: Vector3 = Vector3(-tw, hh, hl)

	return _build_hexahedron_mesh([v0, v1, v2, v3, v4, v5, v6, v7], mat, node_name)


func _create_greenhouse_mesh(
	bottom_width: float,
	top_width: float,
	bottom_length: float,
	top_length: float,
	height: float,
	rear_shift_z: float,
	mat: StandardMaterial3D,
	node_name: String
) -> MeshInstance3D:
	var bw: float = bottom_width * 0.5
	var tw: float = top_width * 0.5
	var bl: float = bottom_length * 0.5
	var tl: float = top_length * 0.5
	var hh: float = height * 0.5

	var v0: Vector3 = Vector3(-bw, -hh, -bl)
	var v1: Vector3 = Vector3(bw, -hh, -bl)
	var v2: Vector3 = Vector3(tw, hh, -tl + rear_shift_z)
	var v3: Vector3 = Vector3(-tw, hh, -tl + rear_shift_z)

	var v4: Vector3 = Vector3(-bw, -hh, bl)
	var v5: Vector3 = Vector3(bw, -hh, bl)
	var v6: Vector3 = Vector3(tw, hh, tl + rear_shift_z)
	var v7: Vector3 = Vector3(-tw, hh, tl + rear_shift_z)

	return _build_hexahedron_mesh([v0, v1, v2, v3, v4, v5, v6, v7], mat, node_name)


func _create_lofted_profile_mesh(
	profile_yz: Array[Vector2],
	width: float,
	mat: StandardMaterial3D,
	node_name: String
) -> MeshInstance3D:
	# profile_yz contains 4 points (z, y): front-bottom, rear-bottom, rear-top, front-top
	var hw: float = width * 0.5
	var p0: Vector2 = profile_yz[0]
	var p1: Vector2 = profile_yz[1]
	var p2: Vector2 = profile_yz[2]
	var p3: Vector2 = profile_yz[3]

	var v0: Vector3 = Vector3(-hw, p0.y, p0.x)
	var v1: Vector3 = Vector3(hw, p0.y, p0.x)
	var v2: Vector3 = Vector3(hw, p3.y, p3.x)
	var v3: Vector3 = Vector3(-hw, p3.y, p3.x)

	var v4: Vector3 = Vector3(-hw, p1.y, p1.x)
	var v5: Vector3 = Vector3(hw, p1.y, p1.x)
	var v6: Vector3 = Vector3(hw, p2.y, p2.x)
	var v7: Vector3 = Vector3(-hw, p2.y, p2.x)

	return _build_hexahedron_mesh([v0, v1, v2, v3, v4, v5, v6, v7], mat, node_name)


func _build_hexahedron_mesh(verts: Array[Vector3], mat: StandardMaterial3D, node_name: String) -> MeshInstance3D:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)

	var faces: Array[Array] = [
		[0, 1, 2, 3], # Front (-Z)
		[5, 4, 7, 6], # Rear (+Z)
		[4, 0, 3, 7], # Left (-X)
		[1, 5, 6, 2], # Right (+X)
		[3, 2, 6, 7], # Top (+Y)
		[4, 5, 1, 0]  # Bottom (-Y)
	]

	for q in faces:
		var a: Vector3 = verts[q[0]]
		var b: Vector3 = verts[q[1]]
		var c: Vector3 = verts[q[2]]
		var d: Vector3 = verts[q[3]]
		var normal: Vector3 = (b - a).cross(c - a).normalized()

		st.set_normal(normal)
		st.add_vertex(a)
		st.set_normal(normal)
		st.add_vertex(b)
		st.set_normal(normal)
		st.add_vertex(c)

		st.set_normal(normal)
		st.add_vertex(a)
		st.set_normal(normal)
		st.add_vertex(c)
		st.set_normal(normal)
		st.add_vertex(d)

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = st.commit()
	return mi


func _add_spec_row(grid: GridContainer, label_title: String) -> Label:
	var key_lbl: Label = Label.new()
	key_lbl.text = label_title
	key_lbl.add_theme_font_size_override("font_size", 13)
	key_lbl.add_theme_color_override("font_color", Color(0.62, 0.66, 0.74))
	grid.add_child(key_lbl)

	var val_lbl: Label = Label.new()
	val_lbl.add_theme_font_size_override("font_size", 14)
	val_lbl.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	grid.add_child(val_lbl)
	return val_lbl


func _add_stat_bar(parent_box: VBoxContainer, caption: String) -> ProgressBar:
	var lbl: Label = Label.new()
	lbl.text = caption
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.68, 0.72, 0.78))
	parent_box.add_child(lbl)

	var bar: ProgressBar = ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0.0, 10.0)
	var fill_style: StyleBoxFlat = StyleBoxFlat.new()
	fill_style.bg_color = Color(0.95, 0.72, 0.12)
	fill_style.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("fill", fill_style)
	parent_box.add_child(bar)
	return bar


func _set_render_layer_recursive(node: Node, layer_mask: int) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = layer_mask
	for child in node.get_children():
		_set_render_layer_recursive(child, layer_mask)


func _locate_arcade_sim_vehicle() -> Node3D:
	var root_vp: Window = get_tree().root
	if not is_instance_valid(root_vp):
		return null
	for node in get_tree().get_nodes_in_group("player_vehicle"):
		if node is Node3D:
			return node as Node3D
	var by_name: Node = root_vp.find_child("ArcadeSimVehicle*", true, false)
	if by_name is Node3D:
		return by_name as Node3D
	return null