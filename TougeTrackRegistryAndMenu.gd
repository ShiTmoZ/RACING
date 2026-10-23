class_name TougeTrackRegistryAndMenu
extends CanvasLayer

# ==============================================================================
# TougeTrackRegistryAndMenu.gd
# Godot 4.3 Forward+ | Track Registry, UI Selector & Safe Physics Spawn
# ==============================================================================

signal track_selected(track_id: String, track_data: Dictionary)

var _env_manager: Node3D = null
var _vehicle: RigidBody3D = null
var _chase_camera: Camera3D = null
var _menu_panel: PanelContainer = null
var _status_label: Label = null
var _hint_panel: PanelContainer = null
var _current_track_id: String = "akina_downhill"

var _track_registry: Dictionary = {}


func _ready() -> void:
	layer = 20
	_initialize_track_registry()
	_build_selector_ui()


func setup_references(env_manager: Node3D, vehicle: RigidBody3D, chase_camera: Camera3D) -> void:
	_env_manager = env_manager
	_vehicle = vehicle
	_chase_camera = chase_camera


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB, KEY_M:
				if is_instance_valid(_menu_panel):
					_menu_panel.visible = not _menu_panel.visible
					if is_instance_valid(_hint_panel):
						_hint_panel.visible = not _menu_panel.visible
			KEY_1:
				select_track("akina_downhill")
			KEY_2:
				select_track("irohazaka_downhill")
			KEY_3:
				select_track("tsukuba_circuit")
			KEY_4:
				select_track("hakone_turnpike")
			KEY_R:
				respawn_current_stage()


# ==============================================================================
# TRACK REGISTRY DEFINITIONS
# ==============================================================================
func _initialize_track_registry() -> void:
	_track_registry = {
		"akina_downhill": {
			"id": "akina_downhill",
			"display_name": "Mount Akina (Downhill — 5 Consecutive Hairpins)",
			"subtitle": "Midnight Touge • Deep Blue Ambient • Golden Streetlights • Valley Fog",
			"road_width": 10.5,
			"banking_angle_deg": 5.5,
			"is_circuit": false,
			"control_points": [
				Vector3(0.0, 0.0, 0.0),
				Vector3(0.0, -3.5, -65.0),
				Vector3(24.0, -9.0, -135.0),
				Vector3(68.0, -16.0, -185.0),
				Vector3(15.0, -24.0, -230.0),
				Vector3(-48.0, -32.0, -265.0),
				Vector3(12.0, -41.0, -310.0),
				Vector3(74.0, -50.0, -355.0),
				Vector3(8.0, -60.0, -405.0),
				Vector3(-56.0, -70.0, -450.0),
				Vector3(18.0, -82.0, -505.0),
				Vector3(65.0, -94.0, -575.0),
				Vector3(20.0, -108.0, -660.0)
			]
		},
		"irohazaka_downhill": {
			"id": "irohazaka_downhill",
			"display_name": "Irohazaka Slope (Nikko — Autumn Hairpin Descent)",
			"subtitle": "Autumn Sunset • Warm Crimson/Orange Horizon • Long Shadows",
			"road_width": 9.8,
			"banking_angle_deg": 6.5,
			"is_circuit": false,
			"control_points": [
				Vector3(0.0, 120.0, 0.0),
				Vector3(0.0, 114.0, -70.0),
				Vector3(58.0, 105.0, -110.0),
				Vector3(0.0, 95.0, -145.0),
				Vector3(-62.0, 84.0, -180.0),
				Vector3(0.0, 73.0, -215.0),
				Vector3(64.0, 62.0, -250.0),
				Vector3(0.0, 50.0, -285.0),
				Vector3(-64.0, 38.0, -320.0),
				Vector3(0.0, 26.0, -360.0),
				Vector3(52.0, 14.0, -410.0),
				Vector3(10.0, 2.0, -485.0)
			]
		},
		"tsukuba_circuit": {
			"id": "tsukuba_circuit",
			"display_name": "Tsukuba Circuit Course 2000 (Time Attack Loop)",
			"subtitle": "Crisp Daylight • Clear Blue Sky • High Contrast Shadows",
			"road_width": 13.0,
			"banking_angle_deg": 4.5,
			"is_circuit": true,
			"control_points": [
				Vector3(0.0, 0.0, 0.0),
				Vector3(0.0, 0.0, -160.0),
				Vector3(48.0, 0.0, -225.0),
				Vector3(105.0, 0.0, -180.0),
				Vector3(95.0, 0.0, -95.0),
				Vector3(145.0, 0.0, -45.0),
				Vector3(215.0, 0.0, -110.0),
				Vector3(245.0, 0.0, -230.0),
				Vector3(185.0, 0.0, -320.0),
				Vector3(75.0, 0.0, -310.0),
				Vector3(-45.0, 0.0, -180.0),
				Vector3(-35.0, 0.0, -55.0)
			]
		},
		"hakone_turnpike": {
			"id": "hakone_turnpike",
			"display_name": "Hakone Turnpike (High-Speed Midnight Fog Sweeper)",
			"subtitle": "Dense Midnight Fog • Reduced Visibility • Moody Headlight Scatter",
			"road_width": 12.2,
			"banking_angle_deg": 7.0,
			"is_circuit": false,
			"control_points": [
				Vector3(0.0, 160.0, 0.0),
				Vector3(15.0, 148.0, -110.0),
				Vector3(65.0, 134.0, -220.0),
				Vector3(135.0, 118.0, -330.0),
				Vector3(95.0, 102.0, -450.0),
				Vector3(10.0, 86.0, -560.0),
				Vector3(-65.0, 68.0, -680.0),
				Vector3(-20.0, 50.0, -810.0),
				Vector3(60.0, 32.0, -940.0),
				Vector3(120.0, 14.0, -1080.0)
			]
		}
	}


# ==============================================================================
# TRACK SELECTION & SAFE VEHICLE SPAWN
# ==============================================================================
func select_track(track_id: String) -> void:
	if not _track_registry.has(track_id):
		push_warning("TougeTrackRegistryAndMenu: Unknown track_id '%s'" % track_id)
		return

	_current_track_id = track_id
	var track_data: Dictionary = _track_registry[track_id]

	# Resolve references if not explicitly passed yet
	if not is_instance_valid(_env_manager) and is_instance_valid(get_parent()):
		_env_manager = get_parent().get_node_or_null("TougeMultiEnvironmentManager") as Node3D
	if not is_instance_valid(_vehicle) and is_instance_valid(get_parent()):
		if "_spawned_vehicle" in get_parent() and is_instance_valid(get_parent().get("_spawned_vehicle")):
			_vehicle = get_parent().get("_spawned_vehicle") as RigidBody3D
		elif "_player_vehicle" in get_parent() and is_instance_valid(get_parent().get("_player_vehicle")):
			_vehicle = get_parent().get("_player_vehicle") as RigidBody3D
	if not is_instance_valid(_chase_camera) and is_instance_valid(get_parent()):
		if "_chase_camera" in get_parent():
			_chase_camera = get_parent().get("_chase_camera") as Camera3D

	var spawn_xform := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, 0.0))

	if is_instance_valid(_env_manager) and _env_manager.has_method("build_track_environment"):
		spawn_xform = _env_manager.call("build_track_environment", track_id, track_data, _vehicle, _chase_camera)

	_place_vehicle_at_spawn(_vehicle, spawn_xform, _chase_camera)

	if is_instance_valid(_status_label):
		_status_label.text = "ACTIVE STAGE: %s\n%s" % [
			track_data.get("display_name", track_id),
			track_data.get("subtitle", "")
		]

	track_selected.emit(track_id, track_data)


func respawn_current_stage() -> void:
	if is_instance_valid(_env_manager) and _env_manager.has_method("get_current_spawn_transform"):
		var spawn_xform: Transform3D = _env_manager.call("get_current_spawn_transform")
		_place_vehicle_at_spawn(_vehicle, spawn_xform, _chase_camera)
	else:
		select_track(_current_track_id)


func _place_vehicle_at_spawn(
	vehicle: RigidBody3D,
	spawn_xform: Transform3D,
	chase_camera: Camera3D = null
) -> void:
	if not is_instance_valid(vehicle):
		return

	# Guarantee zero residual velocity and exact transform in PhysicsServer3D
	var body_rid: RID = vehicle.get_rid()
	PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, spawn_xform)

	vehicle.global_transform = spawn_xform
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle.sleeping = false

	# Reset any transient suspension/wheel state if the vehicle exposes a reset helper
	if vehicle.has_method("reset_vehicle_state"):
		vehicle.call("reset_vehicle_state")

	# Immediately snap chase camera to target to eliminate disorientation
	var cam: Camera3D = chase_camera if is_instance_valid(chase_camera) else _chase_camera
	if is_instance_valid(cam):
		if cam.has_method("snap_to_target"):
			cam.call("snap_to_target", vehicle)
		else:
			var back_dir: Vector3 = spawn_xform.basis.z.normalized()
			cam.global_position = spawn_xform.origin + back_dir * 6.2 + Vector3.UP * 2.1
			cam.look_at(spawn_xform.origin + Vector3.UP * 0.8, Vector3.UP)


# ==============================================================================
# COMPACT STAGE SELECTOR HUD UI
# ==============================================================================
func _build_selector_ui() -> void:
	_menu_panel = PanelContainer.new()
	_menu_panel.name = "StageSelectorPanel"
	_menu_panel.position = Vector2(20.0, 20.0)

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.05, 0.06, 0.10, 0.86)
	panel_style.border_color = Color(0.32, 0.56, 0.92, 0.9)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(6)
	panel_style.set_content_margin_all(12)
	_menu_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_menu_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_menu_panel.add_child(vbox)

	var header := Label.new()
	header.text = "TOUGE STAGE SELECTOR [1-4 | R: Respawn | TAB: Hide]"
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", Color(0.95, 0.82, 0.32))
	vbox.add_child(header)

	_status_label = Label.new()
	_status_label.text = "ACTIVE STAGE: Mount Akina (Downhill)"
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color(0.82, 0.90, 1.0))
	vbox.add_child(_status_label)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(hbox)

	var button_specs := [
		["[1] Akina", "akina_downhill"],
		["[2] Irohazaka", "irohazaka_downhill"],
		["[3] Tsukuba", "tsukuba_circuit"],
		["[4] Hakone", "hakone_turnpike"]
	]

	for spec in button_specs:
		var btn := Button.new()
		btn.text = spec[0]
		btn.focus_mode = Control.FOCUS_NONE
		var tid: String = spec[1]
		btn.pressed.connect(func() -> void: select_track(tid))
		hbox.add_child(btn)

	# Top-Left Persistent HUD Stage Hint Bar
	_hint_panel = PanelContainer.new()
	_hint_panel.name = "HUDStageHintPanel"
	_hint_panel.position = Vector2(24.0, 18.0)
	_hint_panel.custom_minimum_size = Vector2(520.0, 36.0)

	var hint_style := StyleBoxFlat.new()
	hint_style.bg_color = Color(0.04, 0.06, 0.10, 0.78)
	hint_style.border_color = Color(0.25, 0.45, 0.75, 0.6)
	hint_style.set_border_width_all(1)
	hint_style.set_corner_radius_all(6)
	hint_style.content_margin_left = 12
	hint_style.content_margin_right = 12
	_hint_panel.add_theme_stylebox_override("panel", hint_style)
	add_child(_hint_panel)

	var hint_label := Label.new()
	hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint_label.text = "[M / TAB] STAGE SELECT  |  [F1] CONTROLS  |  [F10] GRAPHICS  |  [R] RESTART"
	hint_label.add_theme_font_size_override("font_size", 12)
	hint_label.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0, 0.95))
	_hint_panel.add_child(hint_label)

	_menu_panel.visible = false
	_hint_panel.visible = true
