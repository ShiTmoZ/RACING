class_name TougeTrackRegistryAndMenu
extends CanvasLayer

signal track_selected(track_id: String, track_data: Dictionary)
signal menu_visibility_changed(is_visible: bool)

const TRACK_REGISTRY: Dictionary = {
	"akina_downhill": {
		"name": "Mount Akina (Haruna) - Downhill",
		"subtitle": "5 Sequential Hairpins • Skate-Park Gutter Channels • 128m Drop",
		"biome": "AUTUMN_TOUGE",
		"time_of_day": "NIGHT",
		"road_width": 9.5,
		"length_km": 4.2,
		"difficulty": "★★★★☆",
		"summit_altitude": 128.0
	},
	"irohazaka_downhill": {
		"name": "Irohazaka Slope - Second Downhill",
		"subtitle": "Tight 180° Switchbacks • High Cliff Dropoffs • One-Way Descent",
		"biome": "AUTUMN_TOUGE",
		"time_of_day": "SUNSET",
		"road_width": 8.2,
		"length_km": 3.8,
		"difficulty": "★★★★★",
		"summit_altitude": 165.0
	},
	"tsukuba_circuit": {
		"name": "Tsukuba Fruit Line / Circuit Sector",
		"subtitle": "High-Speed Sweeping Camber • Technical Chicane • Time Attack",
		"biome": "CIRCUIT_VALLEY",
		"time_of_day": "DAY",
		"road_width": 11.0,
		"length_km": 2.9,
		"difficulty": "★★★☆☆",
		"summit_altitude": 42.0
	},
	"hakone_turnpike": {
		"name": "Hakone Turnpike - Foggy Summit",
		"subtitle": "High-Speed Elevation Sweeps • Heavy Mountain Fog • Wide Banking",
		"biome": "FOG_MOUNTAIN",
		"time_of_day": "MIDNIGHT_FOG",
		"road_width": 10.5,
		"length_km": 5.1,
		"difficulty": "★★★★☆",
		"summit_altitude": 190.0
	}
}

var _current_track_id: String = "akina_downhill"
var _vehicle: RigidBody3D = null
var _env_manager: Node3D = null

# UI References
var _panel: PanelContainer
var _track_list_vbox: VBoxContainer
var _status_label: Label
var _is_open: bool = false


func _ready() -> void:
	layer = 110
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_menu_ui()
	_panel.visible = false
	call_deferred("_locate_scene_dependencies")


func _locate_scene_dependencies() -> void:
	var root := get_tree().current_scene
	if not root:
		return

	# Locate Vehicle
	_vehicle = _find_vehicle_recursive(root)

	# Locate or Spawn TougeMultiEnvironmentManager
	_env_manager = root.find_child("TougeMultiEnvironmentManager", true, false) as Node3D
	if not is_instance_valid(_env_manager):
		var manager_script := load("res://TougeMultiEnvironmentManager.gd")
		if manager_script:
			_env_manager = manager_script.new()
			_env_manager.name = "TougeMultiEnvironmentManager"
			root.add_child(_env_manager)


func _find_vehicle_recursive(node: Node) -> RigidBody3D:
	if node is RigidBody3D and (node.name.contains("Vehicle") or node.name.contains("AE86") or node.has_method("reset_telemetry")):
		return node as RigidBody3D
	for child in node.get_children():
		var found := _find_vehicle_recursive(child)
		if found:
			return found
	return null


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M or event.keycode == KEY_TAB:
			toggle_menu()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_R and not _is_open:
			# Quick restart on current track
			select_and_load_track(_current_track_id)
			get_viewport().set_input_as_handled()


func toggle_menu() -> void:
	_is_open = not _is_open
	_panel.visible = _is_open
	if _is_open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	menu_visibility_changed.emit(_is_open)


func select_and_load_track(track_id: String) -> void:
	if not TRACK_REGISTRY.has(track_id):
		push_warning("TougeTrackRegistryAndMenu: Unknown track_id '%s'" % track_id)
		return

	_locate_scene_dependencies()
	_current_track_id = track_id
	var track_data: Dictionary = TRACK_REGISTRY[track_id]

	if _status_label:
		_status_label.text = "ACTIVE STAGE: %s" % track_data["name"]

	# Uniformly build all tracks (including akina_downhill) via TougeMultiEnvironmentManager
	if is_instance_valid(_env_manager) and _env_manager.has_method("load_track_environment"):
		var spawn_xform: Transform3D = _env_manager.call("load_track_environment", track_id, track_data, _vehicle)
		_snap_active_cameras_to_vehicle(_vehicle, spawn_xform)
	else:
		push_error("TougeTrackRegistryAndMenu: TougeMultiEnvironmentManager not available to build track!")

	track_selected.emit(track_id, track_data)

	if _is_open:
		toggle_menu()


func _snap_active_cameras_to_vehicle(vehicle: RigidBody3D, spawn_xform: Transform3D) -> void:
	var target_xform: Transform3D = spawn_xform
	if is_instance_valid(vehicle):
		target_xform = vehicle.global_transform

	var forward_dir: Vector3 = -target_xform.basis.z.normalized()
	var up_dir: Vector3 = target_xform.basis.y.normalized()
	var ideal_cam_pos: Vector3 = target_xform.origin - (forward_dir * 5.6) + (up_dir * 2.1)
	var look_target: Vector3 = target_xform.origin + (forward_dir * 4.0) + (up_dir * 0.8)

	var viewport_cam: Camera3D = get_viewport().get_camera_3d()
	if is_instance_valid(viewport_cam):
		_reset_single_camera(viewport_cam, vehicle, ideal_cam_pos, look_target)

	# Also ensure any ArcadeChaseCamera3D in the scene tree is snapped
	var root := get_tree().current_scene
	if root:
		for node in root.find_children("*", "Camera3D", true, false):
			if node is Camera3D and node != viewport_cam:
				_reset_single_camera(node as Camera3D, vehicle, ideal_cam_pos, look_target)


func _reset_single_camera(cam: Camera3D, vehicle: RigidBody3D, cam_pos: Vector3, look_target: Vector3) -> void:
	if cam.has_method("snap_to_target"):
		cam.call("snap_to_target", vehicle)
		return

	if cam.has_method("reset_camera_interpolation"):
		cam.call("reset_camera_interpolation")

	cam.global_position = cam_pos
	if cam_pos.distance_squared_to(look_target) > 0.01:
		cam.look_at(look_target, Vector3.UP)

	# Clear common smoothing velocity/history properties if present on custom camera scripts
	if "_smooth_pos" in cam:
		cam.set("_smooth_pos", cam_pos)
	if "_smooth_look" in cam:
		cam.set("_smooth_look", look_target)
	if "_velocity" in cam:
		cam.set("_velocity", Vector3.ZERO)
	if "_current_yaw" in cam and is_instance_valid(vehicle):
		var forward := -vehicle.global_transform.basis.z
		cam.set("_current_yaw", atan2(forward.x, forward.z))

	cam.reset_physics_interpolation()


func _build_menu_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "TrackSelectorPanel"
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(560, 420)
	_panel.offset_left = -280
	_panel.offset_top = -210
	_panel.offset_right = 280
	_panel.offset_bottom = 210

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.09, 0.94)
	style.border_color = Color(0.95, 0.65, 0.15, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(20)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(main_vbox)

	var title := Label.new()
	title.text = "TOUGE STAGE SELECTOR [M / TAB]"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.98, 0.78, 0.25))
	main_vbox.add_child(title)

	_status_label = Label.new()
	_status_label.text = "ACTIVE STAGE: %s" % TRACK_REGISTRY[_current_track_id]["name"]
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", Color(0.65, 0.85, 1.0))
	main_vbox.add_child(_status_label)

	var sep := HSeparator.new()
	main_vbox.add_child(sep)

	_track_list_vbox = VBoxContainer.new()
	_track_list_vbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(_track_list_vbox)

	for track_id in TRACK_REGISTRY.keys():
		var info: Dictionary = TRACK_REGISTRY[track_id]
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(0, 62)
		btn.text = "%s   [%s]\n%s" % [info["name"], info["difficulty"], info["subtitle"]]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(func(): select_and_load_track(track_id))
		_track_list_vbox.add_child(btn)

	var footer := Label.new()
	footer.text = "Press [R] during gameplay to respawn at stage summit • [M] or [TAB] to close"
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_theme_font_size_override("font_size", 12)
	footer.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	main_vbox.add_child(footer)