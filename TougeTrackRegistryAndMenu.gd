class_name TougeTrackRegistryAndMenu extends CanvasLayer
# ==============================================================================
# TOUGE TRACK REGISTRY & MODERN JDM TRACK SELECTION MENU
# Engine: Godot 4.3 Forward+
# Architecture: Self-Contained Procedural 3D Track Builder + Dark Glass JDM UI
# ==============================================================================

signal track_switched(track_id: String, track_data: Dictionary)
signal menu_toggled(is_open: bool)

const SAVE_FILE_PATH: String = "user://touge_track_records.cfg"

# --- Track Registry Definitions ---
var track_registry: Dictionary = {
	"akina_downhill": {
		"id": "akina_downhill",
		"name_en": "MOUNT AKINA TOUGE",
		"name_jp": "秋名山 下り (Five Hairpins)",
		"type": "Downhill Touge",
		"length_km": 5.4,
		"elevation_m": -120,
		"corners": 24,
		"difficulty": 4,
		"difficulty_str": "★★★★☆",
		"road_width": 10.5,
		"is_closed_loop": false,
		"has_gutters": true,
		"accent_color": Color(0.0, 0.9, 1.0), # Neon Cyan
		"description": "Iconic rhythm-based downhill mountain pass featuring high-speed S-bends, deep drainage gutters for front-wheel hooking, and the legendary 5 consecutive hairpins.",
		"best_time_sec": 0.0
	},
	"irohazaka_slope": {
		"id": "irohazaka_slope",
		"name_en": "IROHAZAKA SLOPE",
		"name_jp": "いろは坂 (Extreme Switchbacks)",
		"type": "Mountain Pass",
		"length_km": 6.8,
		"elevation_m": -215,
		"corners": 32,
		"difficulty": 5,
		"difficulty_str": "★★★★★",
		"road_width": 9.6,
		"is_closed_loop": false,
		"has_gutters": false,
		"accent_color": Color(1.0, 0.55, 0.05), # Touge Amber
		"description": "Relentless cliffside descent with 30+ sequential banked 180° hairpin switchbacks. Demands aggressive trail-braking, rapid weight transfer, and zero hesitation.",
		"best_time_sec": 0.0
	},
	"tsukuba_circuit": {
		"id": "tsukuba_circuit",
		"name_en": "TSUKUBA CIRCUIT TC2000",
		"name_jp": "筑波サーキット (Time Attack)",
		"type": "Technical Grip Circuit",
		"length_km": 2.045,
		"elevation_m": 0,
		"corners": 8,
		"difficulty": 3,
		"difficulty_str": "★★★☆☆",
		"road_width": 13.0,
		"is_closed_loop": true,
		"has_gutters": false,
		"accent_color": Color(0.2, 1.0, 0.45), # Time Attack Green
		"description": "Classic flat JDM Time Attack proving ground. Features high-grip FIA curbs, the Dunlop sweeper, two tight hairpins, and the famous 437m back straight.",
		"best_time_sec": 0.0
	}
}

var track_order: Array[String] = ["akina_downhill", "irohazaka_slope", "tsukuba_circuit"]
var current_track_id: String = "akina_downhill"
var selected_index: int = 0
var is_menu_open: bool = false

# --- External World & Vehicle References ---
var _target_world: Node3D = null
var _vehicle: RigidBody3D = null
var _generated_track_root: Node3D = null
var _spawn_transform: Transform3D = Transform3D.IDENTITY

# --- UI Nodes ---
var _ui_root: Control = null
var _card_panels: Array[PanelContainer] = []
var _card_time_labels: Dictionary = {}
var _detail_title_label: Label = null
var _detail_jp_label: Label = null
var _detail_desc_label: Label = null
var _detail_stats_label: Label = null
var _drive_button: Button = null
var _hud_hint_label: Label = null

# ==============================================================================
# LIFECYCLE & INPUT HANDLING
# ==============================================================================
func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_best_records()
	_build_jdm_ui()
	_update_card_selection_visuals()
	set_menu_open(false)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M or event.keycode == KEY_ESCAPE:
			toggle_menu()
			get_viewport().set_input_as_handled()
			return

		if is_menu_open:
			if event.keycode in [KEY_LEFT, KEY_A, KEY_UP, KEY_W]:
				selected_index = posmod(selected_index - 1, track_order.size())
				_update_card_selection_visuals()
				get_viewport().set_input_as_handled()
			elif event.keycode in [KEY_RIGHT, KEY_D, KEY_DOWN, KEY_S]:
				selected_index = posmod(selected_index + 1, track_order.size())
				_update_card_selection_visuals()
				get_viewport().set_input_as_handled()
			elif event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
				_on_drive_now_pressed()
				get_viewport().set_input_as_handled()

	elif is_menu_open and event is InputEventJoypadButton and event.pressed:
		if event.button_index in [JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_UP]:
			selected_index = posmod(selected_index - 1, track_order.size())
			_update_card_selection_visuals()
			get_viewport().set_input_as_handled()
		elif event.button_index in [JOY_BUTTON_DPAD_RIGHT, JOY_BUTTON_DPAD_DOWN]:
			selected_index = posmod(selected_index + 1, track_order.size())
			_update_card_selection_visuals()
			get_viewport().set_input_as_handled()
		elif event.button_index == JOY_BUTTON_A:
			_on_drive_now_pressed()
			get_viewport().set_input_as_handled()
		elif event.button_index in [JOY_BUTTON_B, JOY_BUTTON_START]:
			set_menu_open(false)
			get_viewport().set_input_as_handled()

func bind_context(target_world: Node3D, vehicle: RigidBody3D) -> void:
	_target_world = target_world
	_vehicle = vehicle

func toggle_menu() -> void:
	set_menu_open(not is_menu_open)

func set_menu_open(open: bool) -> void:
	is_menu_open = open
	if is_instance_valid(_ui_root):
		_ui_root.visible = is_menu_open
	if is_instance_valid(_hud_hint_label):
		_hud_hint_label.visible = not is_menu_open
	if get_tree():
		get_tree().paused = is_menu_open
	if is_menu_open:
		_update_card_selection_visuals()
	menu_toggled.emit(is_menu_open)

# ==============================================================================
# TRACK SWITCHING & PROCEDURAL 3D GEOMETRY ENGINE
# ==============================================================================
func switch_track(track_id: String, target_world: Node3D = null, vehicle: RigidBody3D = null) -> void:
	if target_world != null:
		_target_world = target_world
	if vehicle != null:
		_vehicle = vehicle

	if not track_registry.has(track_id):
		push_warning("TougeTrackRegistryAndMenu: Unknown track_id '%s', defaulting to 'akina_downhill'." % track_id)
		track_id = "akina_downhill"

	current_track_id = track_id
	var track_data: Dictionary = track_registry[track_id]

	# 1. Clear previous procedural track geometry
	if is_instance_valid(_generated_track_root):
		_generated_track_root.queue_free()
		_generated_track_root = null

	if is_instance_valid(_target_world):
		var old_node: Node = _target_world.get_node_or_null("ProceduralTrackRoot")
		if is_instance_valid(old_node):
			old_node.free()

		_generated_track_root = Node3D.new()
		_generated_track_root.name = "ProceduralTrackRoot"
		_target_world.add_child(_generated_track_root)

		# 2. Build spline and 3D road/curb/guardrail meshes
		var curve: Curve3D = _generate_track_curve(track_id)
		_build_procedural_road_meshes(_generated_track_root, curve, track_data)

	# 3. Teleport Vehicle to Starting Grid with Zero Residual Velocity
	if is_instance_valid(_vehicle):
		_teleport_vehicle_to_start(_vehicle, _spawn_transform)

	track_switched.emit(track_id, track_data)

func _teleport_vehicle_to_start(vehicle: RigidBody3D, start_xform: Transform3D) -> void:
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle.global_transform = start_xform
	PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, start_xform)
	PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	vehicle.sleeping = false

# ==============================================================================
# PROCEDURAL SPLINE DEFINITIONS (AKINA, IROHAZAKA, TSUKUBA)
# ==============================================================================
func _generate_track_curve(track_id: String) -> Curve3D:
	var curve := Curve3D.new()
	curve.bake_interval = 2.0
	var raw_points: PackedVector3Array = PackedVector3Array()

	match track_id:
		"akina_downhill":
			# Mount Akina: Entry straight -> rhythm S-curves -> 5 consecutive hairpins -> downhill finish
			var z_cursor: float = 0.0
			var x_cursor: float = 0.0
			var y_cursor: float = 0.0
			raw_points.append(Vector3(0.0, 0.0, 0.0))
			raw_points.append(Vector3(0.0, -2.5, -90.0))
			raw_points.append(Vector3(38.0, -7.0, -180.0))
			raw_points.append(Vector3(-42.0, -13.0, -275.0))
			raw_points.append(Vector3(30.0, -19.0, -370.0))
			
			z_cursor = -440.0
			y_cursor = -24.0
			# 5 Consecutive Hairpins
			for h in range(5):
				var side: float = 1.0 if (h % 2 == 0) else -1.0
				var reach_x: float = side * 95.0
				raw_points.append(Vector3(reach_x * 0.65, y_cursor - 4.0, z_cursor))
				raw_points.append(Vector3(reach_x, y_cursor - 9.0, z_cursor - 36.0))
				raw_points.append(Vector3(reach_x * 0.65, y_cursor - 14.0, z_cursor - 72.0))
				z_cursor -= 115.0
				y_cursor -= 18.0
			
			# Final technical bridge & downhill chute
			raw_points.append(Vector3(0.0, y_cursor - 6.0, z_cursor - 60.0))
			raw_points.append(Vector3(-35.0, y_cursor - 12.0, z_cursor - 150.0))
			raw_points.append(Vector3(-35.0, y_cursor - 16.0, z_cursor - 260.0))

		"irohazaka_slope":
			# Irohazaka Slope: 30+ extreme banked 180-degree switchbacks down a steep cliffside
			raw_points.append(Vector3(0.0, 0.0, 0.0))
			raw_points.append(Vector3(0.0, -3.5, -75.0))
			var z_pos: float = -120.0
			var y_pos: float = -7.0
			var num_hairpins: int = 30
			for i in range(num_hairpins):
				var dir: float = 1.0 if (i % 2 == 0) else -1.0
				var amplitude_x: float = 78.0 + float(i % 3) * 10.0
				raw_points.append(Vector3(dir * amplitude_x * 0.7, y_pos - 2.2, z_pos))
				raw_points.append(Vector3(dir * amplitude_x, y_pos - 4.5, z_pos - 24.0))
				raw_points.append(Vector3(dir * amplitude_x * 0.7, y_pos - 6.8, z_pos - 48.0))
				z_pos -= 72.0
				y_pos -= 7.0
			raw_points.append(Vector3(0.0, y_pos - 4.0, z_pos - 90.0))

		"tsukuba_circuit":
			# Tsukuba Circuit TC2000: Flat closed loop (Start/Finish straight -> Turn 1 Hairpin -> S-Curve -> Hairpin 2 -> Dunlop -> Back Straight -> Final Sweeper)
			raw_points.append(Vector3(0.0, 0.0, 0.0))
			raw_points.append(Vector3(0.0, 0.0, -180.0))     # Main Straight
			raw_points.append(Vector3(28.0, 0.0, -235.0))    # Turn 1 Entry
			raw_points.append(Vector3(68.0, 0.0, -220.0))    # Turn 1 Exit
			raw_points.append(Vector3(82.0, 0.0, -140.0))    # Short Chute
			raw_points.append(Vector3(120.0, 0.0, -90.0))    # Dunlop Curve
			raw_points.append(Vector3(185.0, 0.0, -110.0))   # Inside Sweeper
			raw_points.append(Vector3(235.0, 0.0, -195.0))   # 2nd Hairpin Entry
			raw_points.append(Vector3(285.0, 0.0, -175.0))   # 2nd Hairpin Apex
			raw_points.append(Vector3(270.0, 0.0, -60.0))    # Back Straight Entry
			raw_points.append(Vector3(240.0, 0.0, 210.0))    # 437m Back Straight
			raw_points.append(Vector3(145.0, 0.0, 285.0))    # Final High-Speed Sweeper Apex
			raw_points.append(Vector3(35.0, 0.0, 235.0))     # Final Corner Exit
			raw_points.append(Vector3(0.0, 0.0, 110.0))      # Pit Straight Merge
			raw_points.append(Vector3(0.0, 0.0, 0.0))        # Loop Close

	# Catmull-Rom style tangent calculation for smooth drivable splines
	var count: int = raw_points.size()
	var is_loop: bool = track_registry[track_id]["is_closed_loop"]
	for i in range(count):
		var p_prev: Vector3 = raw_points[(i - 1 + count) % count] if is_loop else raw_points[max(i - 1, 0)]
		var p_curr: Vector3 = raw_points[i]
		var p_next: Vector3 = raw_points[(i + 1) % count] if is_loop else raw_points[min(i + 1, count - 1)]
		var tangent: Vector3 = (p_next - p_prev) * 0.28
		curve.add_point(p_curr, -tangent, tangent)

	return curve

# ==============================================================================
# PROCEDURAL MESH & COLLISION BUILDER
# ==============================================================================
func _build_procedural_road_meshes(parent: Node3D, curve: Curve3D, track_data: Dictionary) -> void:
	var total_len: float = curve.get_baked_length()
	var step: float = 3.5
	var samples: int = maxi(int(total_len / step), 16)
	var half_width: float = float(track_data["road_width"]) * 0.5
	var has_gutters: bool = bool(track_data["has_gutters"])

	var st_road := SurfaceTool.new()
	st_road.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_curb := SurfaceTool.new()
	st_curb.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_guard := SurfaceTool.new()
	st_guard.begin(Mesh.PRIMITIVE_TRIANGLES)

	var collision_faces := PackedVector3Array()

	# Sample Cross-Sections along Curve
	var left_edges: Array[Vector3] = []
	var right_edges: Array[Vector3] = []
	var curb_left_outer: Array[Vector3] = []
	var curb_right_outer: Array[Vector3] = []

	for i in range(samples + 1):
		var dist: float = clampf(float(i) * step, 0.0, total_len)
		var pos: Vector3 = curve.sample_baked(dist, true)
		var next_dist: float = minf(dist + 1.5, total_len)
		var prev_dist: float = maxf(dist - 1.5, 0.0)
		var fwd: Vector3 = (curve.sample_baked(next_dist, true) - curve.sample_baked(prev_dist, true)).normalized()
		if fwd.length_squared() < 0.01:
			fwd = Vector3.FORWARD
		var right: Vector3 = fwd.cross(Vector3.UP).normalized()

		# Record Spawn Transform near start
		if i == 2:
			var spawn_pos: Vector3 = pos + Vector3(0.0, 1.35, 0.0)
			var basis_z: Vector3 = -fwd
			var basis_x: Vector3 = right
			var basis_y: Vector3 = basis_z.cross(basis_x).normalized()
			_spawn_transform = Transform3D(Basis(basis_x, basis_y, basis_z).orthonormalized(), spawn_pos)

		var p_left: Vector3 = pos - right * half_width
		var p_right: Vector3 = pos + right * half_width
		var gutter_drop: float = -0.18 if has_gutters else 0.05
		var c_left: Vector3 = p_left - right * 1.15 + Vector3(0.0, gutter_drop, 0.0)
		var c_right: Vector3 = p_right + right * 1.15 + Vector3(0.0, gutter_drop, 0.0)

		left_edges.append(p_left)
		right_edges.append(p_right)
		curb_left_outer.append(c_left)
		curb_right_outer.append(c_right)

	# Build Triangles for Asphalt, Curbs, Guardrails, and Trimesh Collision
	for i in range(samples):
		var l0: Vector3 = left_edges[i]
		var r0: Vector3 = right_edges[i]
		var l1: Vector3 = left_edges[i + 1]
		var r1: Vector3 = right_edges[i + 1]

		var cl0: Vector3 = curb_left_outer[i]
		var cr0: Vector3 = curb_right_outer[i]
		var cl1: Vector3 = curb_left_outer[i + 1]
		var cr1: Vector3 = curb_right_outer[i + 1]

		# Road Surface
		_add_quad_with_collision(st_road, collision_faces, l0, r0, r1, l1, Vector3.UP)

		# Left & Right Curbs / Gutters
		_add_quad_with_collision(st_curb, collision_faces, cl0, l0, l1, cl1, Vector3.UP)
		_add_quad_with_collision(st_curb, collision_faces, r0, cr0, cr1, r1, Vector3.UP)

		# Guardrail / Safety Barrier Walls (keeps car on mountain cliffside)
		var wall_h: Vector3 = Vector3(0.0, 1.15, 0.0)
		_add_quad_with_collision(st_guard, collision_faces, cl0 + wall_h, cl0, cl1, cl1 + wall_h, (r0 - l0).normalized())
		_add_quad_with_collision(st_guard, collision_faces, cr0, cr0 + wall_h, cr1 + wall_h, cr1, (l0 - r0).normalized())

	st_road.generate_normals()
	st_curb.generate_normals()
	st_guard.generate_normals()

	# Materials
	var mat_asphalt := StandardMaterial3D.new()
	mat_asphalt.albedo_color = Color(0.14, 0.15, 0.17)
	mat_asphalt.roughness = 0.82
	mat_asphalt.metallic = 0.05

	var mat_curb := StandardMaterial3D.new()
	mat_curb.albedo_color = Color(0.78, 0.22, 0.18) if not has_gutters else Color(0.32, 0.34, 0.36)
	mat_curb.roughness = 0.75

	var mat_guard := StandardMaterial3D.new()
	mat_guard.albedo_color = Color(0.75, 0.78, 0.82)
	mat_guard.metallic = 0.65
	mat_guard.roughness = 0.35

	var road_mi := MeshInstance3D.new()
	road_mi.name = "AsphaltMesh"
	road_mi.mesh = st_road.commit()
	road_mi.material_override = mat_asphalt
	parent.add_child(road_mi)

	var curb_mi := MeshInstance3D.new()
	curb_mi.name = "CurbGutterMesh"
	curb_mi.mesh = st_curb.commit()
	curb_mi.material_override = mat_curb
	parent.add_child(curb_mi)

	var guard_mi := MeshInstance3D.new()
	guard_mi.name = "GuardrailMesh"
	guard_mi.mesh = st_guard.commit()
	guard_mi.material_override = mat_guard
	parent.add_child(guard_mi)

	# StaticBody3D ConcavePolygonShape3D Collision
	var static_body := StaticBody3D.new()
	static_body.name = "TrackStaticBody3D"
	var col_shape := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(collision_faces)
	col_shape.shape = concave
	static_body.add_child(col_shape)
	parent.add_child(static_body)

	# Starting Arch Banner
	_build_starting_arch(parent, _spawn_transform, float(track_data["road_width"]), track_data["accent_color"])

func _add_quad_with_collision(
	st: SurfaceTool,
	col_faces: PackedVector3Array,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	normal: Vector3
) -> void:
	st.set_normal(normal)
	st.add_vertex(v0)
	st.add_vertex(v1)
	st.add_vertex(v2)
	st.add_vertex(v0)
	st.add_vertex(v2)
	st.add_vertex(v3)

	col_faces.append(v0)
	col_faces.append(v1)
	col_faces.append(v2)
	col_faces.append(v0)
	col_faces.append(v2)
	col_faces.append(v3)

func _build_starting_arch(parent: Node3D, start_xform: Transform3D, width: float, accent: Color) -> void:
	var arch_root := Node3D.new()
	arch_root.name = "StartingGridArch"
	arch_root.global_transform = start_xform

	var banner_mat := StandardMaterial3D.new()
	banner_mat.albedo_color = accent
	banner_mat.emission_enabled = true
	banner_mat.emission = accent
	banner_mat.emission_energy_multiplier = 2.2

	var top_beam := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width + 2.0, 0.85, 0.85)
	top_beam.mesh = box
	top_beam.position = Vector3(0.0, 4.5, -6.0)
	top_beam.material_override = banner_mat
	arch_root.add_child(top_beam)
	parent.add_child(arch_root)

# ==============================================================================
# MODERN JDM DARK GLASS TRACK SELECTION MENU UI
# ==============================================================================
func _build_jdm_ui() -> void:
	# Always-visible subtle HUD shortcut hint
	_hud_hint_label = Label.new()
	_hud_hint_label.text = "[M / ESC] TRACK SELECT MENU"
	_hud_hint_label.position = Vector2(24, 20)
	_hud_hint_label.add_theme_font_size_override("font_size", 15)
	_hud_hint_label.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0, 0.85))
	add_child(_hud_hint_label)

	# Fullscreen Dark Glass Overlay
	_ui_root = Control.new()
	_ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_ui_root)

	var bg_dim := ColorRect.new()
	bg_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_dim.color = Color(0.03, 0.04, 0.07, 0.88)
	_ui_root.add_child(bg_dim)

	var main_margin := MarginContainer.new()
	main_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_margin.add_theme_constant_override("margin_left", 64)
	main_margin.add_theme_constant_override("margin_right", 64)
	main_margin.add_theme_constant_override("margin_top", 44)
	main_margin.add_theme_constant_override("margin_bottom", 44)
	_ui_root.add_child(main_margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 24)
	main_margin.add_child(vbox)

	# --- Header Bar ---
	var header_hbox := HBoxContainer.new()
	vbox.add_child(header_hbox)

	var title_vbox := VBoxContainer.new()
	title_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(title_vbox)

	var header_title := Label.new()
	header_title.text = "JDM STAGE & CIRCUIT SELECT // 峠・サーキット選択"
	header_title.add_theme_font_size_override("font_size", 28)
	header_title.add_theme_color_override("font_color", Color(0.0, 0.92, 1.0))
	title_vbox.add_child(header_title)

	var header_sub := Label.new()
	header_sub.text = "SELECT STAGE WITH [A/D] OR [UP/DOWN]  •  PRESS [ENTER / SPACE] TO DEPLOY VEHICLE  •  [ESC / M] RESUME"
	header_sub.add_theme_font_size_override("font_size", 13)
	header_sub.add_theme_color_override("font_color", Color(0.65, 0.72, 0.82))
	title_vbox.add_child(header_sub)

	var close_btn := Button.new()
	close_btn.text = "✕ RESUME [ESC]"
	close_btn.custom_minimum_size = Vector2(160, 44)
	close_btn.pressed.connect(func() -> void: set_menu_open(false))
	header_hbox.add_child(close_btn)

	# --- Track Cards Row ---
	var cards_hbox := HBoxContainer.new()
	cards_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cards_hbox.add_theme_constant_override("separation", 22)
	vbox.add_child(cards_hbox)

	_card_panels.clear()
	for i in range(track_order.size()):
		var tid: String = track_order[i]
		var tdata: Dictionary = track_registry[tid]
		var card: PanelContainer = _create_track_card(i, tdata)
		cards_hbox.add_child(card)
		_card_panels.append(card)

	# --- Bottom Detail & Drive Action Bar ---
	var footer_panel := PanelContainer.new()
	var footer_style := StyleBoxFlat.new()
	footer_style.bg_color = Color(0.07, 0.09, 0.13, 0.95)
	footer_style.border_color = Color(0.0, 0.85, 1.0, 0.65)
	footer_style.set_border_width_all(1)
	footer_style.set_corner_radius_all(8)
	footer_style.set_content_margin_all(20)
	footer_panel.add_theme_stylebox_override("panel", footer_style)
	vbox.add_child(footer_panel)

	var footer_hbox := HBoxContainer.new()
	footer_hbox.add_theme_constant_override("separation", 32)
	footer_panel.add_child(footer_hbox)

	var detail_vbox := VBoxContainer.new()
	detail_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_vbox.add_theme_constant_override("separation", 6)
	footer_hbox.add_child(detail_vbox)

	_detail_title_label = Label.new()
	_detail_title_label.add_theme_font_size_override("font_size", 22)
	_detail_title_label.add_theme_color_override("font_color", Color.WHITE)
	detail_vbox.add_child(_detail_title_label)

	_detail_jp_label = Label.new()
	_detail_jp_label.add_theme_font_size_override("font_size", 15)
	_detail_jp_label.add_theme_color_override("font_color", Color(1.0, 0.72, 0.15))
	detail_vbox.add_child(_detail_jp_label)

	_detail_desc_label = Label.new()
	_detail_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_desc_label.add_theme_font_size_override("font_size", 14)
	_detail_desc_label.add_theme_color_override("font_color", Color(0.78, 0.83, 0.9))
	detail_vbox.add_child(_detail_desc_label)

	_detail_stats_label = Label.new()
	_detail_stats_label.add_theme_font_size_override("font_size", 14)
	_detail_stats_label.add_theme_color_override("font_color", Color(0.0, 0.92, 1.0))
	detail_vbox.add_child(_detail_stats_label)

	_drive_button = Button.new()
	_drive_button.text = "DRIVE NOW  ▶"
	_drive_button.custom_minimum_size = Vector2(250, 74)
	_drive_button.add_theme_font_size_override("font_size", 22)
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0.0, 0.72, 0.92, 0.95)
	btn_style.set_corner_radius_all(6)
	_drive_button.add_theme_stylebox_override("normal", btn_style)
	_drive_button.pressed.connect(_on_drive_now_pressed)
	footer_hbox.add_child(_drive_button)

func _create_track_card(idx: int, tdata: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	card.add_child(vbox)

	# Badge Type
	var type_lbl := Label.new()
	type_lbl.text = "[ %s ]" % String(tdata["type"]).to_upper()
	type_lbl.add_theme_font_size_override("font_size", 13)
	type_lbl.add_theme_color_override("font_color", tdata["accent_color"])
	vbox.add_child(type_lbl)

	# English Title
	var name_en := Label.new()
	name_en.text = tdata["name_en"]
	name_en.add_theme_font_size_override("font_size", 22)
	name_en.add_theme_color_override("font_color", Color.WHITE)
	name_en.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(name_en)

	# Kanji Subtitle
	var name_jp := Label.new()
	name_jp.text = tdata["name_jp"]
	name_jp.add_theme_font_size_override("font_size", 16)
	name_jp.add_theme_color_override("font_color", Color(1.0, 0.76, 0.25))
	vbox.add_child(name_jp)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	# Telemetry Specs Grid
	var specs_grid := GridContainer.new()
	specs_grid.columns = 2
	specs_grid.add_theme_constant_override("h_separation", 18)
	specs_grid.add_theme_constant_override("v_separation", 8)
	vbox.add_child(specs_grid)

	_add_spec_row(specs_grid, "LENGTH:", "%.2f km" % float(tdata["length_km"]))
	_add_spec_row(specs_grid, "ELEVATION:", "%d m" % int(tdata["elevation_m"]))
	_add_spec_row(specs_grid, "CORNERS:", "%d Turns" % int(tdata["corners"]))
	_add_spec_row(specs_grid, "DIFFICULTY:", String(tdata["difficulty_str"]))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	# Best Record Display
	var rec_lbl := Label.new()
	rec_lbl.text = "BEST RECORD: %s" % _format_lap_time(float(tdata["best_time_sec"]))
	rec_lbl.add_theme_font_size_override("font_size", 15)
	rec_lbl.add_theme_color_override("font_color", Color(0.4, 1.0, 0.65))
	vbox.add_child(rec_lbl)
	_card_time_labels[tdata["id"]] = rec_lbl

	# Card Select Button
	var select_btn := Button.new()
	select_btn.text = "SELECT STAGE"
	select_btn.custom_minimum_size = Vector2(0, 42)
	select_btn.pressed.connect(func() -> void:
		selected_index = idx
		_update_card_selection_visuals()
		_on_drive_now_pressed()
	)
	vbox.add_child(select_btn)

	return card

func _add_spec_row(grid: GridContainer, key_text: String, val_text: String) -> void:
	var k := Label.new()
	k.text = key_text
	k.add_theme_font_size_override("font_size", 14)
	k.add_theme_color_override("font_color", Color(0.6, 0.68, 0.78))
	grid.add_child(k)

	var v := Label.new()
	v.text = val_text
	v.add_theme_font_size_override("font_size", 14)
	v.add_theme_color_override("font_color", Color.WHITE)
	grid.add_child(v)

func _update_card_selection_visuals() -> void:
	for i in range(_card_panels.size()):
		var tid: String = track_order[i]
		var tdata: Dictionary = track_registry[tid]
		var is_sel: bool = (i == selected_index)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.11, 0.15, 0.22, 0.96) if is_sel else Color(0.06, 0.08, 0.12, 0.85)
		style.border_color = tdata["accent_color"] if is_sel else Color(0.22, 0.26, 0.34, 0.65)
		style.set_border_width_all(3 if is_sel else 1)
		style.set_corner_radius_all(10)
		style.set_content_margin_all(22)
		_card_panels[i].add_theme_stylebox_override("panel", style)

	var sel_id: String = track_order[selected_index]
	var sel_data: Dictionary = track_registry[sel_id]
	if is_instance_valid(_detail_title_label):
		_detail_title_label.text = "%s  —  %s" % [sel_data["name_en"], sel_data["type"]]
		_detail_jp_label.text = sel_data["name_jp"]
		_detail_desc_label.text = sel_data["description"]
		_detail_stats_label.text = "LENGTH: %.2f km   |   ELEVATION DELTA: %d m   |   CORNERS: %d   |   DIFFICULTY: %s" % [
			float(sel_data["length_km"]),
			int(sel_data["elevation_m"]),
			int(sel_data["corners"]),
			String(sel_data["difficulty_str"])
		]

func _on_drive_now_pressed() -> void:
	var target_id: String = track_order[selected_index]
	set_menu_open(false)
	switch_track(target_id, _target_world, _vehicle)

# ==============================================================================
# LAP TIME RECORD PERSISTENCE
# ==============================================================================
func register_lap_time(track_id: String, lap_seconds: float) -> void:
	if not track_registry.has(track_id) or lap_seconds <= 0.0:
		return
	var current_best: float = float(track_registry[track_id]["best_time_sec"])
	if current_best <= 0.0 or lap_seconds < current_best:
		track_registry[track_id]["best_time_sec"] = lap_seconds
		_save_best_records()
		if _card_time_labels.has(track_id):
			var lbl: Label = _card_time_labels[track_id]
			lbl.text = "BEST RECORD: %s" % _format_lap_time(lap_seconds)

func _load_best_records() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_FILE_PATH) == OK:
		for tid in track_order:
			var saved_time: float = float(cfg.get_value("records", tid, 0.0))
			track_registry[tid]["best_time_sec"] = saved_time

func _save_best_records() -> void:
	var cfg := ConfigFile.new()
	for tid in track_order:
		cfg.set_value("records", tid, float(track_registry[tid]["best_time_sec"]))
	cfg.save(SAVE_FILE_PATH)

func _format_lap_time(sec: float) -> String:
	if sec <= 0.0:
		return "--:--.---"
	var mins: int = int(sec / 60.0)
	var rem_sec: float = fmod(sec, 60.0)
	return "%02d:%06.3f" % [mins, rem_sec]