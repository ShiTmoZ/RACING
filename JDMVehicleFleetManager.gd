class_name JDMVehicleFleetManager
extends Node

## Mount Akina Touge - Production Vehicle Fleet & 3D Showroom Manager
## Manages dynamic hot-swapping, wheel rigging rebinding, drivetrain parameter injection,
## and the interactive 3D glassmorphism showroom turntable for the AE86 and BNR34.

signal vehicle_swapped(car_index: int, car_data: Dictionary)
signal showroom_toggled(is_open: bool)

enum CarID {
	AE86_TRUENO = 0,
	BNR34_GTR = 1
}

const AE86ModelerScript = preload("res://AE86TruenoModeler.gd")
const R34ModelerScript = preload("res://R34SkylineModeler.gd")

const LEGACY_VISUAL_NAMES: Array[String] = [
	"VisualChassisRoot",
	"R34SkylineModeler",
	"AE86TruenoModeler",
	"ChassisVisuals",
	"ProceduralModelRoot",
	"CarMeshRoot"
]

const FLEET_DATABASE: Dictionary = {
	CarID.AE86_TRUENO: {
		"id": CarID.AE86_TRUENO,
		"name": "Toyota Sprinter Trueno AE86 GT-APEX",
		"short_name": "TRUENO AE86",
		"jp_badge": "藤原とうふ店 (自家用) | AE86",
		"drivetrain": "FR LAYOUT",
		"engine_code": "4A-GE 1.6L 20V Silvertop",
		"hp": 175,
		"mass": 960.0,
		"engine_peak_torque": 205.0,
		"redline_rpm": 8200.0,
		"final_drive": 4.300,
		"reverse_ratio": -3.484,
		"gear_ratios": [3.587, 2.022, 1.384, 1.000, 0.861],
		"has_popups": true,
		"accent_color": Color(0.96, 0.88, 0.72, 1.0), # Warm Tofu Ivory / Amber
		"badge_bg": Color(0.18, 0.14, 0.08, 0.85),
		"description": "Ultralight downhill specialist. Razor-sharp turn-in, high-revving naturally aspirated 4A-GE, and retractable popup headlights."
	},
	CarID.BNR34_GTR: {
		"id": CarID.BNR34_GTR,
		"name": "Nissan Skyline GT-R BNR34 V-Spec II",
		"short_name": "SKYLINE BNR34",
		"jp_badge": "RB26DETT ニスモ | BNR34",
		"drivetrain": "ATTESA E-TS PRO AWD",
		"engine_code": "RB26DETT 2.6L Twin-Turbo I6",
		"hp": 330,
		"mass": 1560.0,
		"engine_peak_torque": 445.0,
		"redline_rpm": 8000.0,
		"final_drive": 3.545,
		"reverse_ratio": -3.626,
		"gear_ratios": [3.827, 2.360, 1.685, 1.312, 1.000, 0.793],
		"has_popups": false,
		"accent_color": Color(0.15, 0.68, 1.0, 1.0), # Bayside Blue / Cyber Cyan
		"badge_bg": Color(0.05, 0.16, 0.28, 0.85),
		"description": "All-wheel-drive touge monster. Relentless mid-corner traction and twin-turbocharged straight-line brutality."
	}
}

@export var player_vehicle: Node3D
var target_player_vehicle: Node3D:
	get:
		return player_vehicle
	set(val):
		player_vehicle = val

@export var default_car: CarID = CarID.AE86_TRUENO

var current_car_id: CarID = CarID.AE86_TRUENO
var active_visual_root: Node3D = null
var popups_open: bool = true

# Showroom UI & 3D Turntable State
var is_showroom_open: bool = false
var showroom_index: int = 0
var _ui_layer: CanvasLayer
var _main_panel: Control
var _turntable_pivot: Node3D
var _preview_car_holder: Node3D
var _turntable_camera: Camera3D

# UI Widget References
var _lbl_jp_sub: Label
var _lbl_car_title: Label
var _lbl_engine_sub: Label
var _lbl_desc: Label
var _badge_drivetrain: PanelContainer
var _lbl_drivetrain: Label
var _lbl_hp_val: Label
var _lbl_mass_val: Label
var _lbl_rpm_val: Label
var _lbl_popup_hint: Label
var _bar_power: ProgressBar
var _bar_agility: ProgressBar
var _bar_traction: ProgressBar
var _tab_buttons: Array[Button] = []
var _panel_style: StyleBoxFlat

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_resolve_player_vehicle()
	_build_showroom_interface()
	
	# Defer initial vehicle injection by one frame to ensure physics and scene tree are initialized
	call_deferred("apply_vehicle_to_player", default_car)


func _process(delta: float) -> void:
	if is_showroom_open and is_instance_valid(_turntable_pivot):
		_turntable_pivot.rotate_y(delta * 0.55)
		
		# Subtle camera float in showroom
		if is_instance_valid(_turntable_camera):
			var t: float = Time.get_ticks_msec() * 0.0012
			_turntable_camera.position.y = 1.35 + sin(t) * 0.08


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	
	var key_event := event as InputEventKey
	
	# [C] Toggle Showroom
	if key_event.keycode == KEY_C or key_event.physical_keycode == KEY_C:
		toggle_showroom()
		get_viewport().set_input_as_handled()
		return
	
	# Showroom Navigation Controls
	if is_showroom_open:
		if key_event.keycode in [KEY_LEFT, KEY_A] or key_event.physical_keycode == KEY_A:
			_cycle_showroom_selection(-1)
			get_viewport().set_input_as_handled()
		elif key_event.keycode in [KEY_RIGHT, KEY_D] or key_event.physical_keycode == KEY_D:
			_cycle_showroom_selection(1)
			get_viewport().set_input_as_handled()
		elif key_event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
			_confirm_showroom_selection()
			get_viewport().set_input_as_handled()
		elif key_event.keycode == KEY_ESCAPE:
			toggle_showroom(false)
			get_viewport().set_input_as_handled()
		return
	
	# In-Game Live Controls: [H] Popup Headlight Toggle for AE86
	if key_event.keycode == KEY_H or key_event.physical_keycode == KEY_H:
		if current_car_id == CarID.AE86_TRUENO:
			_toggle_ae86_popups()
			get_viewport().set_input_as_handled()


# ==============================================================================
# VEHICLE FLEET SWAPPING & RIGGING ENGINE
# ==============================================================================

func _resolve_player_vehicle() -> Node3D:
	if is_instance_valid(player_vehicle):
		return player_vehicle
	
	# 1. Check Parent if attached directly to vehicle
	var p := get_parent()
	if p is VehicleBody3D or (p is Node3D and ("wheel_meshes" in p or "engine_peak_torque" in p)):
		player_vehicle = p
		return player_vehicle
	
	# 2. Check Groups
	var grouped := get_tree().get_first_node_in_group("player_vehicle")
	if not grouped:
		grouped = get_tree().get_first_node_in_group("player")
	if grouped is Node3D:
		player_vehicle = grouped
		return player_vehicle
	
	# 3. Search Scene Tree for ArcadeSimVehicle / VehicleBody3D
	var root := get_tree().current_scene
	if root:
		for child in root.find_children("*", "Node3D", true, false):
			if "wheel_meshes" in child or "engine_peak_torque" in child or child is VehicleBody3D:
				player_vehicle = child as Node3D
				return player_vehicle
	
	return null


func apply_vehicle_to_player(car_id: CarID) -> void:
	if not FLEET_DATABASE.has(car_id):
		push_warning("JDMVehicleFleetManager: Invalid CarID requested (%d). Defaulting to AE86." % car_id)
		car_id = CarID.AE86_TRUENO
	
	current_car_id = car_id
	showroom_index = int(car_id)
	var specs: Dictionary = FLEET_DATABASE[car_id]
	
	var target_car := _resolve_player_vehicle()
	if not is_instance_valid(target_car):
		push_warning("JDMVehicleFleetManager: Player vehicle node not found in scene tree.")
		return
	
	# 1. Purge ALL Stale Visual Chassis Nodes
	_purge_stale_visual_nodes(target_car)
	
	# 2. Instantiate Fresh Procedural Model Root
	var new_model := _instantiate_procedural_car(car_id)
	new_model.name = "VisualChassisRoot"
	target_car.add_child(new_model)
	active_visual_root = new_model
	
	# 3. Locate 4 Wheel Meshes & Rebind to ArcadeSimVehicle Controller
	_rebind_vehicle_wheels(target_car, new_model)
	
	# 4. Inject Authentic Physics & Drivetrain Telemetry
	_inject_vehicle_parameters(target_car, specs)
	
	# 5. Configure AE86 Popup Headlights State
	if car_id == CarID.AE86_TRUENO:
		popups_open = true
		_apply_popup_state_to_model(new_model, popups_open)
	
	vehicle_swapped.emit(int(car_id), specs)


func _purge_stale_visual_nodes(target_car: Node3D) -> void:
	var nodes_to_remove: Array[Node] = []
	
	for child in target_car.get_children():
		var c_name: String = child.name
		var c_script: Script = child.get_script()
		
		var is_legacy_named := false
		for legacy_str in LEGACY_VISUAL_NAMES:
			if c_name == legacy_str or c_name.begins_with(legacy_str):
				is_legacy_named = true
				break
		
		var is_modeler_script := (c_script == AE86ModelerScript or c_script == R34ModelerScript)
		var has_model_meta := child.has_meta("is_jdm_visual_chassis")
		
		# Also catch stray unlabeled Node3Ds that contain WheelFL/WheelFR meshes directly
		var has_stray_wheels := (
			not (child is VehicleWheel3D)
			and child.find_child("WheelFL", true, false) != null
			and child.find_child("WheelFR", true, false) != null
		)
		
		if is_legacy_named or is_modeler_script or has_model_meta or has_stray_wheels:
			nodes_to_remove.append(child)
	
	for stale_node in nodes_to_remove:
		# Immediately detach from parent BEFORE queue_free so name "VisualChassisRoot" is free
		# and find_child() searches don't hit queued-for-deletion wheel meshes!
		target_car.remove_child(stale_node)
		stale_node.queue_free()


func _instantiate_procedural_car(car_id: CarID) -> Node3D:
	var instance: Node3D = null
	if car_id == CarID.AE86_TRUENO:
		instance = AE86ModelerScript.new()
	else:
		instance = R34ModelerScript.new()
	
	instance.set_meta("is_jdm_visual_chassis", true)
	return instance


func _rebind_vehicle_wheels(target_car: Node3D, model_root: Node3D) -> void:
	var wheel_names: Array[String] = ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]
	var found_wheels: Array[Node3D] = []
	
	for w_name in wheel_names:
		var w_node := _find_wheel_node_recursive(model_root, w_name)
		found_wheels.append(w_node)
	
	var w_fl: Node3D = found_wheels[0]
	var w_fr: Node3D = found_wheels[1]
	var w_rl: Node3D = found_wheels[2]
	var w_rr: Node3D = found_wheels[3]
	
	# Bind Array Property (`wheel_meshes`) safely with type compatibility
	if "wheel_meshes" in target_car:
		var current_arr = target_car.get("wheel_meshes")
		if current_arr is Array:
			current_arr.clear()
			for w in found_wheels:
				if is_instance_valid(w):
					current_arr.append(w)
		else:
			target_car.set("wheel_meshes", [w_fl, w_fr, w_rl, w_rr])
	
	# Bind Direct Wheel Reference Properties across common naming conventions in ArcadeSimVehicle.gd
	var prop_map: Dictionary = {
		"wheel_fl": w_fl, "wheel_fr": w_fr, "wheel_rl": w_rl, "wheel_rr": w_rr,
		"wheel_mesh_fl": w_fl, "wheel_mesh_fr": w_fr, "wheel_mesh_rl": w_rl, "wheel_mesh_rr": w_rr,
		"fl_wheel_mesh": w_fl, "fr_wheel_mesh": w_fr, "rl_wheel_mesh": w_rl, "rr_wheel_mesh": w_rr,
		"mesh_fl": w_fl, "mesh_fr": w_fr, "mesh_rl": w_rl, "mesh_rr": w_rr,
		"visual_wheel_fl": w_fl, "visual_wheel_fr": w_fr, "visual_wheel_rl": w_rl, "visual_wheel_rr": w_rr
	}
	
	for prop_name in prop_map.keys():
		if prop_name in target_car and is_instance_valid(prop_map[prop_name]):
			target_car.set(prop_name, prop_map[prop_name])
	
	# Cache rest/base positions if controller uses rest offset arrays for suspension travel
	if "wheel_base_positions" in target_car or "wheel_rest_positions" in target_car:
		var base_positions: Array[Vector3] = []
		for w in found_wheels:
			base_positions.append(w.position if is_instance_valid(w) else Vector3.ZERO)
		if "wheel_base_positions" in target_car:
			target_car.set("wheel_base_positions", base_positions)
		if "wheel_rest_positions" in target_car:
			target_car.set("wheel_rest_positions", base_positions)
	
	# Notify vehicle controller if it implements a rebind hook
	if target_car.has_method("on_visual_chassis_rebound"):
		target_car.call("on_visual_chassis_rebound", model_root, found_wheels)
	elif target_car.has_method("rebind_wheels"):
		target_car.call("rebind_wheels", found_wheels)
	elif target_car.has_method("_cache_wheel_references"):
		target_car.call("_cache_wheel_references")


func _find_wheel_node_recursive(root: Node, wheel_name: String) -> Node3D:
	# 1. Exact Name Match
	var exact := root.find_child(wheel_name, true, false)
	if exact is Node3D:
		return exact as Node3D
	
	# 2. Case-Insensitive or Substring Match
	var target_lower := wheel_name.to_lower()
	for child in root.find_children("*", "Node3D", true, false):
		if child.name.to_lower() == target_lower or child.name.to_lower().ends_with(target_lower):
			return child as Node3D
	
	return null


func _inject_vehicle_parameters(target_car: Node3D, specs: Dictionary) -> void:
	# Core Physics & Drivetrain Properties required by ArcadeSimVehicle.gd
	if "mass" in target_car:
		target_car.set("mass", float(specs["mass"]))
	if "base_peak_torque_nm" in target_car and "engine_peak_torque" in specs:
		target_car.set("base_peak_torque_nm", float(specs["engine_peak_torque"]))
	if "engine_peak_torque" in target_car:
		target_car.set("engine_peak_torque", float(specs["engine_peak_torque"]))
	if "reverse_ratio" in target_car:
		target_car.set("reverse_ratio", absf(float(specs["reverse_ratio"])))
	if "final_drive" in target_car:
		target_car.set("final_drive", float(specs["final_drive"]))
	if "redline_rpm" in target_car:
		target_car.set("redline_rpm", float(specs["redline_rpm"]))
	
	# Gear Ratios safely typed
	if "gear_ratios" in target_car:
		var source_gears: Array = specs["gear_ratios"]
		var current_gears = target_car.get("gear_ratios")
		if current_gears is Array:
			current_gears.clear()
			for ratio in source_gears:
				current_gears.append(float(ratio))
		elif current_gears is PackedFloat32Array:
			var packed := PackedFloat32Array()
			for ratio in source_gears:
				packed.append(float(ratio))
			target_car.set("gear_ratios", packed)
		else:
			target_car.set("gear_ratios", source_gears.duplicate())
	
	# Optional Drivetrain Split / AWD Balance if supported by controller
	var is_awd: bool = (specs["id"] == CarID.BNR34_GTR)
	if "is_awd" in target_car:
		target_car.set("is_awd", is_awd)
	if "drivetrain_type" in target_car:
		var dt_val = target_car.get("drivetrain_type")
		if typeof(dt_val) == TYPE_STRING:
			target_car.set("drivetrain_type", "AWD" if is_awd else "FR")
		elif typeof(dt_val) == TYPE_INT:
			target_car.set("drivetrain_type", 1 if is_awd else 0)
	if "front_torque_split" in target_car:
		target_car.set("front_torque_split", 0.35 if is_awd else 0.0)


# ==============================================================================
# AE86 POPUP HEADLIGHT CONTROLLER ([H] KEY)
# ==============================================================================

func _toggle_ae86_popups() -> void:
	if not is_instance_valid(active_visual_root):
		return
	popups_open = not popups_open
	_apply_popup_state_to_model(active_visual_root, popups_open)


func _apply_popup_state_to_model(model: Node3D, open_state: bool) -> void:
	if not is_instance_valid(model):
		return
	
	# 1. Invoke direct methods on AE86TruenoModeler.gd if implemented
	if model.has_method("toggle_popups"):
		model.call("toggle_popups")
		return
	elif model.has_method("set_popups_open"):
		model.call("set_popups_open", open_state)
		return
	elif model.has_method("set_headlights_open"):
		model.call("set_headlights_open", open_state)
		return
	elif "popups_open" in model:
		model.set("popups_open", open_state)
		return
	
	# 2. Fallback: Animate popup hinge nodes directly if named in hierarchy
	var target_pitch_deg: float = 0.0 if open_state else -55.0
	for child in model.find_children("*", "Node3D", true, false):
		var c_lower := child.name.to_lower()
		if "popup" in c_lower or "retract" in c_lower or "headlight_hinge" in c_lower or "headlightpivot" in c_lower:
			var tw := create_tween()
			tw.tween_property(child, "rotation_degrees:x", target_pitch_deg, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		elif child is Light3D and ("headlight" in c_lower or "beam" in c_lower):
			child.visible = open_state


# ==============================================================================
# 3D TURNTABLE SHOWROOM & MODERN GLASSMORPHISM UI
# ==============================================================================

func toggle_showroom(force_state: Variant = null) -> void:
	if typeof(force_state) == TYPE_BOOL:
		is_showroom_open = force_state
	else:
		is_showroom_open = not is_showroom_open
	
	_main_panel.visible = is_showroom_open
	
	if is_showroom_open:
		showroom_index = int(current_car_id)
		_refresh_showroom_display(showroom_index)
		_main_panel.modulate.a = 0.0
		var tw := create_tween()
		tw.tween_property(_main_panel, "modulate:a", 1.0, 0.2)
	
	showroom_toggled.emit(is_showroom_open)


func _cycle_showroom_selection(direction: int) -> void:
	var total_cars: int = FLEET_DATABASE.size()
	showroom_index = posmod(showroom_index + direction, total_cars)
	_refresh_showroom_display(showroom_index)


func _confirm_showroom_selection() -> void:
	var chosen_id: CarID = showroom_index as CarID
	apply_vehicle_to_player(chosen_id)
	toggle_showroom(false)


func _refresh_showroom_display(car_idx: int) -> void:
	var car_id: CarID = car_idx as CarID
	var specs: Dictionary = FLEET_DATABASE[car_id]
	var accent: Color = specs["accent_color"]
	
	# 1. Rebuild 3D Turntable Vehicle Preview
	for child in _preview_car_holder.get_children():
		_preview_car_holder.remove_child(child)
		child.queue_free()
	
	var preview_model := _instantiate_procedural_car(car_id)
	preview_model.name = "ShowroomPreviewModel"
	_preview_car_holder.add_child(preview_model)
	
	# Subtle entry scale animation on turntable
	_preview_car_holder.scale = Vector3(0.92, 0.92, 0.92)
	var tw := create_tween()
	tw.tween_property(_preview_car_holder, "scale", Vector3.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	
	# 2. Update Typography & Telemetry Cards
	_lbl_jp_sub.text = specs["jp_badge"]
	_lbl_jp_sub.add_theme_color_override("font_color", accent)
	
	_lbl_car_title.text = specs["name"]
	_lbl_engine_sub.text = "ENGINE:  " + specs["engine_code"]
	_lbl_desc.text = specs["description"]
	
	_lbl_drivetrain.text = "  " + specs["drivetrain"] + "  "
	_lbl_drivetrain.add_theme_color_override("font_color", accent)
	
	var badge_style := _badge_drivetrain.get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	badge_style.bg_color = specs["badge_bg"]
	badge_style.border_color = accent
	_badge_drivetrain.add_theme_stylebox_override("panel", badge_style)
	
	_lbl_hp_val.text = "%d HP" % int(specs["hp"])
	_lbl_mass_val.text = "%d KG" % int(specs["mass"])
	_lbl_rpm_val.text = "%d RPM" % int(specs["redline_rpm"])
	
	if specs["has_popups"]:
		_lbl_popup_hint.text = "★ EQUIPPED: Retractable Popup Headlights (Press [H] while driving)"
		_lbl_popup_hint.add_theme_color_override("font_color", Color(1.0, 0.86, 0.45, 0.95))
	else:
		_lbl_popup_hint.text = "★ EQUIPPED: Active ATTESA E-TS PRO Torque Split + 6-Speed Getrag"
		_lbl_popup_hint.add_theme_color_override("font_color", Color(0.45, 0.82, 1.0, 0.95))
	
	# Update border glow accent
	if _panel_style:
		_panel_style.border_color = Color(accent.r, accent.g, accent.b, 0.55)
	
	# Animate Telemetry Bars
	var pwr_norm: float = clampf(float(specs["hp"]) / 400.0 * 100.0, 10.0, 100.0)
	var agi_norm: float = clampf((1800.0 - float(specs["mass"])) / 1000.0 * 100.0, 10.0, 100.0)
	var trc_norm: float = 96.0 if car_id == CarID.BNR34_GTR else 76.0
	
	var bar_tw := create_tween().set_parallel(true)
	bar_tw.tween_property(_bar_power, "value", pwr_norm, 0.28).set_trans(Tween.TRANS_CUBIC)
	bar_tw.tween_property(_bar_agility, "value", agi_norm, 0.28).set_trans(Tween.TRANS_CUBIC)
	bar_tw.tween_property(_bar_traction, "value", trc_norm, 0.28).set_trans(Tween.TRANS_CUBIC)
	
	# Highlight active tab button
	for i in range(_tab_buttons.size()):
		var btn := _tab_buttons[i]
		var is_sel := (i == car_idx)
		btn.modulate = Color(1, 1, 1, 1) if is_sel else Color(0.65, 0.7, 0.78, 0.75)


func _build_showroom_interface() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "JDMShowroomLayer"
	_ui_layer.layer = 90
	add_child(_ui_layer)
	
	# Root Overlay Container
	_main_panel = Control.new()
	_main_panel.name = "ShowroomOverlay"
	_main_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_main_panel.visible = false
	_ui_layer.add_child(_main_panel)
	
	# Dark Backdrop Dimmer
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.02, 0.03, 0.05, 0.78)
	_main_panel.add_child(backdrop)
	
	# Center Glassmorphism Card
	var center_wrap := CenterContainer.new()
	center_wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	_main_panel.add_child(center_wrap)
	
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(1060, 600)
	_panel_style = StyleBoxFlat.new()
	_panel_style.bg_color = Color(0.06, 0.08, 0.12, 0.90)
	_panel_style.border_width_left = 2
	_panel_style.border_width_top = 2
	_panel_style.border_width_right = 2
	_panel_style.border_width_bottom = 2
	_panel_style.border_color = Color(0.25, 0.75, 1.0, 0.55)
	_panel_style.corner_radius_top_left = 16
	_panel_style.corner_radius_top_right = 16
	_panel_style.corner_radius_bottom_left = 16
	_panel_style.corner_radius_bottom_right = 16
	_panel_style.shadow_color = Color(0.0, 0.0, 0.0, 0.65)
	_panel_style.shadow_size = 28
	card.add_theme_stylebox_override("panel", _panel_style)
	center_wrap.add_child(card)
	
	var root_margin := MarginContainer.new()
	root_margin.add_theme_constant_override("margin_left", 28)
	root_margin.add_theme_constant_override("margin_right", 28)
	root_margin.add_theme_constant_override("margin_top", 22)
	root_margin.add_theme_constant_override("margin_bottom", 22)
	card.add_child(root_margin)
	
	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 16)
	root_margin.add_child(main_vbox)
	
	# --- TOP HEADER BAR ---
	var header_hbox := HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 16)
	main_vbox.add_child(header_hbox)
	
	var title_lbl := Label.new()
	title_lbl.text = "MOUNT AKINA // TOUGE GARAGE & SHOWROOM"
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", Color(0.62, 0.74, 0.88, 0.9))
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(title_lbl)
	
	# Car Selection Tabs (AE86 vs BNR34 Only)
	_tab_buttons.clear()
	for car_key in [CarID.AE86_TRUENO, CarID.BNR34_GTR]:
		var c_data: Dictionary = FLEET_DATABASE[car_key]
		var tab_btn := Button.new()
		tab_btn.text = "  [%d] %s  " % [int(car_key) + 1, c_data["short_name"]]
		tab_btn.custom_minimum_size = Vector2(165, 34)
		tab_btn.focus_mode = Control.FOCUS_NONE
		var idx_capture: int = int(car_key)
		tab_btn.pressed.connect(func():
			showroom_index = idx_capture
			_refresh_showroom_display(showroom_index)
		)
		header_hbox.add_child(tab_btn)
		_tab_buttons.append(tab_btn)
	
	var header_sep := HSeparator.new()
	header_sep.modulate = Color(1, 1, 1, 0.18)
	main_vbox.add_child(header_sep)
	
	# --- CENTER BODY: 3D TURNTABLE (LEFT) + TELEMETRY CARD (RIGHT) ---
	var content_hbox := HBoxContainer.new()
	content_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_hbox.add_theme_constant_override("separation", 26)
	main_vbox.add_child(content_hbox)
	
	# LEFT: 3D SubViewport Showroom Turntable
	var vp_frame := PanelContainer.new()
	vp_frame.custom_minimum_size = Vector2(540, 420)
	vp_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var vp_style := StyleBoxFlat.new()
	vp_style.bg_color = Color(0.03, 0.04, 0.07, 0.95)
	vp_style.border_width_left = 1
	vp_style.border_width_top = 1
	vp_style.border_width_right = 1
	vp_style.border_width_bottom = 1
	vp_style.border_color = Color(0.22, 0.30, 0.42, 0.45)
	vp_style.corner_radius_top_left = 12
	vp_style.corner_radius_top_right = 12
	vp_style.corner_radius_bottom_left = 12
	vp_style.corner_radius_bottom_right = 12
	vp_frame.add_theme_stylebox_override("panel", vp_style)
	content_hbox.add_child(vp_frame)
	
	var sub_vp_container := SubViewportContainer.new()
	sub_vp_container.stretch = true
	sub_vp_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp_frame.add_child(sub_vp_container)
	
	var sub_vp := SubViewport.new()
	sub_vp.own_world_3d = true
	sub_vp.transparent_bg = false
	sub_vp.msaa_3d = Viewport.MSAA_4X
	sub_vp.size = Vector2i(540, 420)
	sub_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	sub_vp_container.add_child(sub_vp)
	
	_build_3d_turntable_stage(sub_vp)
	
	# RIGHT: Vehicle Telemetry & Specs Card
	var specs_vbox := VBoxContainer.new()
	specs_vbox.custom_minimum_size = Vector2(430, 0)
	specs_vbox.add_theme_constant_override("separation", 12)
	content_hbox.add_child(specs_vbox)
	
	_lbl_jp_sub = Label.new()
	_lbl_jp_sub.add_theme_font_size_override("font_size", 18)
	specs_vbox.add_child(_lbl_jp_sub)
	
	_lbl_car_title = Label.new()
	_lbl_car_title.add_theme_font_size_override("font_size", 24)
	_lbl_car_title.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0))
	_lbl_car_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	specs_vbox.add_child(_lbl_car_title)
	
	# Drivetrain Badge Row
	var badge_row := HBoxContainer.new()
	badge_row.add_theme_constant_override("separation", 12)
	specs_vbox.add_child(badge_row)
	
	_badge_drivetrain = PanelContainer.new()
	var b_style := StyleBoxFlat.new()
	b_style.bg_color = Color(0.1, 0.2, 0.3, 0.85)
	b_style.border_width_left = 1
	b_style.border_width_top = 1
	b_style.border_width_right = 1
	b_style.border_width_bottom = 1
	b_style.corner_radius_top_left = 6
	b_style.corner_radius_top_right = 6
	b_style.corner_radius_bottom_left = 6
	b_style.corner_radius_bottom_right = 6
	_badge_drivetrain.add_theme_stylebox_override("panel", b_style)
	badge_row.add_child(_badge_drivetrain)
	
	_lbl_drivetrain = Label.new()
	_lbl_drivetrain.add_theme_font_size_override("font_size", 13)
	_badge_drivetrain.add_child(_lbl_drivetrain)
	
	_lbl_engine_sub = Label.new()
	_lbl_engine_sub.add_theme_font_size_override("font_size", 13)
	_lbl_engine_sub.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	badge_row.add_child(_lbl_engine_sub)
	
	_lbl_desc = Label.new()
	_lbl_desc.add_theme_font_size_override("font_size", 13)
	_lbl_desc.add_theme_color_override("font_color", Color(0.68, 0.74, 0.82))
	_lbl_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	specs_vbox.add_child(_lbl_desc)
	
	# 3-Column Telemetry Stat Boxes (HP, Curb Mass, Redline)
	var metrics_grid := HBoxContainer.new()
	metrics_grid.add_theme_constant_override("separation", 10)
	specs_vbox.add_child(metrics_grid)
	
	_lbl_hp_val = _create_metric_box(metrics_grid, "HORSEPOWER")
	_lbl_mass_val = _create_metric_box(metrics_grid, "CURB MASS")
	_lbl_rpm_val = _create_metric_box(metrics_grid, "REDLINE")
	
	# Performance Rating Bars
	var bars_vbox := VBoxContainer.new()
	bars_vbox.add_theme_constant_override("separation", 8)
	specs_vbox.add_child(bars_vbox)
	
	_bar_power = _create_telemetry_bar(bars_vbox, "OUTPUT / TOP END")
	_bar_agility = _create_telemetry_bar(bars_vbox, "HAIRPIN AGILITY")
	_bar_traction = _create_telemetry_bar(bars_vbox, "EXIT TRACTION")
	
	_lbl_popup_hint = Label.new()
	_lbl_popup_hint.add_theme_font_size_override("font_size", 13)
	_lbl_popup_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	specs_vbox.add_child(_lbl_popup_hint)
	
	# --- BOTTOM CONTROLS FOOTER ---
	var footer_sep := HSeparator.new()
	footer_sep.modulate = Color(1, 1, 1, 0.18)
	main_vbox.add_child(footer_sep)
	
	var footer_hbox := HBoxContainer.new()
	main_vbox.add_child(footer_hbox)
	
	var controls_lbl := Label.new()
	controls_lbl.text = "[A / D] or [LEFT / RIGHT] Cycle Hero Cars     •     [SPACE / ENTER] Deploy to Touge     •     [C] Close Showroom"
	controls_lbl.add_theme_font_size_override("font_size", 14)
	controls_lbl.add_theme_color_override("font_color", Color(0.75, 0.84, 0.96))
	controls_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_hbox.add_child(controls_lbl)
	
	var drive_btn := Button.new()
	drive_btn.text = "  DEPLOY TO AKINA [ENTER]  "
	drive_btn.custom_minimum_size = Vector2(210, 36)
	drive_btn.pressed.connect(_confirm_showroom_selection)
	footer_hbox.add_child(drive_btn)


func _create_metric_box(parent: Container, caption: String) -> Label:
	var box := PanelContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.09, 0.12, 0.18, 0.85)
	st.border_width_bottom = 2
	st.border_color = Color(0.28, 0.45, 0.65, 0.6)
	st.corner_radius_top_left = 8
	st.corner_radius_top_right = 8
	st.corner_radius_bottom_left = 8
	st.corner_radius_bottom_right = 8
	st.content_margin_left = 10
	st.content_margin_right = 10
	st.content_margin_top = 8
	st.content_margin_bottom = 8
	box.add_theme_stylebox_override("panel", st)
	parent.add_child(box)
	
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	box.add_child(vb)
	
	var cap_lbl := Label.new()
	cap_lbl.text = caption
	cap_lbl.add_theme_font_size_override("font_size", 11)
	cap_lbl.add_theme_color_override("font_color", Color(0.55, 0.65, 0.78))
	vb.add_child(cap_lbl)
	
	var val_lbl := Label.new()
	val_lbl.text = "---"
	val_lbl.add_theme_font_size_override("font_size", 20)
	val_lbl.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
	vb.add_child(val_lbl)
	
	return val_lbl


func _create_telemetry_bar(parent: Container, label_text: String) -> ProgressBar:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	parent.add_child(hb)
	
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(145, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.68, 0.76, 0.86))
	hb.add_child(lbl)
	
	var bar := ProgressBar.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.custom_minimum_size = Vector2(0, 14)
	bar.max_value = 100.0
	bar.show_percentage = false
	
	var bg_st := StyleBoxFlat.new()
	bg_st.bg_color = Color(0.08, 0.11, 0.16, 0.9)
	bg_st.corner_radius_top_left = 4
	bg_st.corner_radius_top_right = 4
	bg_st.corner_radius_bottom_left = 4
	bg_st.corner_radius_bottom_right = 4
	
	var fill_st := StyleBoxFlat.new()
	fill_st.bg_color = Color(0.22, 0.72, 1.0, 0.95)
	fill_st.corner_radius_top_left = 4
	fill_st.corner_radius_top_right = 4
	fill_st.corner_radius_bottom_left = 4
	fill_st.corner_radius_bottom_right = 4
	
	bar.add_theme_stylebox_override("background", bg_st)
	bar.add_theme_stylebox_override("fill", fill_st)
	hb.add_child(bar)
	return bar


func _build_3d_turntable_stage(sub_vp: SubViewport) -> void:
	var stage_root := Node3D.new()
	stage_root.name = "ShowroomStage3D"
	sub_vp.add_child(stage_root)
	
	# Dedicated Studio Environment
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.04, 0.07, 1.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.18, 0.22, 0.32, 1.0)
	env.ambient_light_energy = 1.15
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_intensity = 0.65
	env.glow_bloom = 0.15
	
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	stage_root.add_child(world_env)
	
	# Turntable Pedestal Pivot
	_turntable_pivot = Node3D.new()
	_turntable_pivot.name = "TurntablePivot"
	stage_root.add_child(_turntable_pivot)
	
	# Sleek Showroom Cylinder Pad
	var pad_mesh := CylinderMesh.new()
	pad_mesh.top_radius = 2.75
	pad_mesh.bottom_radius = 2.95
	pad_mesh.height = 0.12
	pad_mesh.radial_segments = 48
	
	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color = Color(0.07, 0.09, 0.13, 1.0)
	pad_mat.metallic = 0.75
	pad_mat.roughness = 0.22
	pad_mesh.material = pad_mat
	
	var pad_inst := MeshInstance3D.new()
	pad_inst.mesh = pad_mesh
	pad_inst.position = Vector3(0, -0.06, 0)
	_turntable_pivot.add_child(pad_inst)
	
	# Glowing Outer Rim Ring on Pedestal
	var rim_mesh := TorusMesh.new()
	rim_mesh.inner_radius = 2.72
	rim_mesh.outer_radius = 2.78
	rim_mesh.rings = 48
	rim_mesh.ring_segments = 16
	
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.2, 0.75, 1.0, 1.0)
	rim_mat.emission_enabled = true
	rim_mat.emission = Color(0.15, 0.65, 1.0, 1.0)
	rim_mat.emission_energy_multiplier = 2.4
	rim_mesh.material = rim_mat
	
	var rim_inst := MeshInstance3D.new()
	rim_inst.mesh = rim_mesh
	rim_inst.position = Vector3(0, 0.01, 0)
	_turntable_pivot.add_child(rim_inst)
	
	# Vehicle Preview Holder
	_preview_car_holder = Node3D.new()
	_preview_car_holder.name = "PreviewCarHolder"
	_turntable_pivot.add_child(_preview_car_holder)
	
	# 3-Point Studio Lighting Rig
	var key_light := DirectionalLight3D.new()
	key_light.light_color = Color(0.98, 0.96, 1.0)
	key_light.light_energy = 1.65
	key_light.shadow_enabled = true
	key_light.rotation_degrees = Vector3(-38.0, 35.0, 0.0)
	stage_root.add_child(key_light)
	
	var fill_light := OmniLight3D.new()
	fill_light.light_color = Color(0.25, 0.62, 1.0)
	fill_light.light_energy = 1.85
	fill_light.omni_range = 9.0
	fill_light.position = Vector3(-3.2, 2.2, 2.5)
	stage_root.add_child(fill_light)
	
	var rim_light := OmniLight3D.new()
	rim_light.light_color = Color(1.0, 0.68, 0.35)
	rim_light.light_energy = 1.55
	rim_light.omni_range = 9.0
	rim_light.position = Vector3(3.0, 2.0, -3.0)
	stage_root.add_child(rim_light)
	
	# Showroom Camera
	_turntable_camera = Camera3D.new()
	_turntable_camera.fov = 38.0
	_turntable_camera.position = Vector3(0.0, 1.35, 4.95)
	_turntable_camera.look_at_from_position(_turntable_camera.position, Vector3(0.0, 0.55, 0.0), Vector3.UP)
	stage_root.add_child(_turntable_camera)