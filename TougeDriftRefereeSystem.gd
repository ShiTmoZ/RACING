class_name TougeDriftRefereeSystem
extends CanvasLayer
## ============================================================================
## TOUGE DRIFT REFEREE SYSTEM ("ShiTmoZ/RACING" - Godot 4.3 Forward+)
## ============================================================================
## Authentic Initial D Arcade Stage Simcade Drift Scoring Engine,
## Bunta Fujiwara's Tofu Water Cup 2nd-Order G-Force & Jerk Slosh Simulator,
## Procedural Manga Onomatopoeia Renderer, and Retractable Headlight Controller.
##
## Pure self-contained GDScript 2.0. Zero external texture/font dependencies.
## ============================================================================

# ------------------------------------------------------------------------------
# SIGNALS
# ------------------------------------------------------------------------------
signal drift_started(entry_speed_kmh: float, entry_angle_deg: float)
signal drift_banked(points_awarded: int, peak_combo: float, total_score: int)
signal drift_failed(reason: String, points_lost: int)
signal water_spilled(remaining_percent: float, jerk_g_per_sec: float)
signal perfect_weight_transfer_achieved(bonus_multiplier: float)
signal rank_upgraded(new_rank_index: int, rank_title: String)
signal headlights_toggled(is_open: bool)

# ------------------------------------------------------------------------------
# CONSTANTS & TUNING PARAMETERS
# ------------------------------------------------------------------------------
const GRAVITY_ACCEL: float = 9.81

## 1. Fujiwara Water Cup Oscillator & Spill Physics
const CUP_NATURAL_FREQ: float = 6.0          # ~6.0 rad/s natural resonance
const CUP_DAMPING_RATIO: float = 0.45        # ~0.45 underdamped water slosh
const JERK_SPILL_THRESHOLD: float = 1.8      # 1.8 G/s sudden snap/braking threshold
const WATER_SPILL_PENALTY_PCT: float = 15.0  # -15% water level per spill event
const SPILL_COOLDOWN_SEC: float = 1.15       # Debounce between consecutive spills
const SMOOTH_TRANSFER_JERK_MAX: float = 1.38 # Max jerk allowed for Kansei bonus
const SMOOTH_TRANSFER_BONUS: float = 0.25    # +25% score multiplier bonus

## 2. Simcade Drift Scoring Formula (Angle x Speed x Line)
const MIN_DRIFT_ANGLE_DEG: float = 8.0       # Slip Angle Beta > 8 deg
const MIN_DRIFT_SPEED_KMH: float = 25.0      # Vehicle Speed > 25 km/h
const SPINOUT_ANGLE_DEG: float = 70.0        # Angle > 70 deg triggers SPIN OUT!
const SWEET_SPOT_MIN_DEG: float = 25.0       # Sweet spot lower bound
const SWEET_SPOT_MAX_DEG: float = 45.0       # Sweet spot upper bound
const GUTTER_PROXIMITY_DIST: float = 1.8     # < 1.8m grants GUTTER HOOK!
const GUTTER_HOOK_MULTIPLIER: float = 1.50   # +50% multiplier
const COMBO_GRACE_TIME_SEC: float = 1.20     # 1.2s chain window between hairpins
const MAX_COMBO_MULTIPLIER: float = 5.0      # Up to 5.0x combo

## 3. Manga Onomatopoeia Tuning
@export var enable_manga_text_popups: bool = false
const MANGA_POPUP_LIFETIME: float = 0.70     # 0.7s total popup duration
const MANGA_POP_SCALE_START: float = 1.40    # Pops in at 1.4x scale
const MANGA_POP_SCALE_SETTLE: float = 1.00   # Settles to 1.0x scale

## 4. Touge Drift Rank Thresholds
const RANK_TITLES: PackedStringArray = [
	"D",
	"C",
	"B",
	"A",
	"S",
	"SS",
	"TAKUMI LEVEL"
]

const RANK_SUBTITLES: PackedStringArray = [
	"SUNDAY DRIVER",
	"LOCAL ROOKIE",
	"SPEED STAR",
	"NIGHT KIDS ACE",
	"RED SUNS PRODIGY",
	"PROJECT D LEGEND",
	"FUJIWARA ZONE"
]

const RANK_THRESHOLDS: PackedInt32Array = [
	0,
	5000,
	15000,
	35000,
	70000,
	120000,
	200000
]

const RANK_COLORS: Array[Color] = [
	Color(0.62, 0.68, 0.75, 1.0), # D - Steel Silver
	Color(0.30, 0.85, 0.45, 1.0), # C - Meadow Green
	Color(0.20, 0.68, 1.00, 1.0), # B - Cyan Blue
	Color(0.95, 0.55, 0.15, 1.0), # A - Touge Orange
	Color(1.00, 0.84, 0.10, 1.0), # S - Racing Gold
	Color(1.00, 0.22, 0.35, 1.0), # SS - Crimson Redline
	Color(0.85, 0.95, 1.00, 1.0)  # TAKUMI LEVEL - Trueno Panda White/Cyan
]

# ------------------------------------------------------------------------------
# INTERNAL DATA STRUCTURES
# ------------------------------------------------------------------------------
class MangaPopupItem:
	var katakana: String = ""
	var romaji: String = ""
	var screen_pos: Vector2 = Vector2.ZERO
	var velocity: Vector2 = Vector2(0.0, -68.0)
	var age: float = 0.0
	var lifetime: float = MANGA_POPUP_LIFETIME
	var tilt_rad: float = -0.14
	var accent_color: Color = Color(1.0, 0.85, 0.15, 1.0)
	var spike_seed: int = 1

class TechniqueCalloutItem:
	var text: String = ""
	var subtext: String = ""
	var color: Color = Color.WHITE
	var age: float = 0.0
	var lifetime: float = 1.35

class WaterDropletItem:
	var pos: Vector2 = Vector2.ZERO
	var vel: Vector2 = Vector2.ZERO
	var radius: float = 3.5
	var age: float = 0.0
	var lifetime: float = 0.65

# ------------------------------------------------------------------------------
# STATE VARIABLES
# ------------------------------------------------------------------------------
var _headless_mode: bool = false
var _hud_visible: bool = true
var _canvas_drawer: Control = null

## Vehicle & Solver References
var _vehicle: Node3D = null
var _drift_solver: Node = null
var _vehicle_search_timer: float = 0.0
var _vehicle_bind_warmup: float = 0.0

## Kinematics & G-Force State
var _prev_global_pos: Vector3 = Vector3.ZERO
var _prev_velocity: Vector3 = Vector3.ZERO
var _prev_forward_dir: Vector3 = Vector3.FORWARD
var _prev_yaw_rad: float = 0.0
var _has_prev_kinematics: bool = false
var _forward_sign: float = 1.0 # Auto-aligns with vehicle forward axis

var _speed_mps: float = 0.0
var _speed_kmh: float = 0.0
var _slip_angle_deg: float = 0.0
var _signed_slip_deg: float = 0.0
var _yaw_rate_rads: float = 0.0
var _long_accel_mps2: float = 0.0

var _g_lat: float = 0.0
var _g_long: float = 0.0
var _prev_g_lat: float = 0.0
var _prev_g_long: float = 0.0
var _jerk_vec: Vector2 = Vector2.ZERO
var _jerk_mag: float = 0.0
var _peak_recent_jerk: float = 0.0

## 1. Fujiwara Water Cup State (2nd-Order Spring-Damper)
var _cup_angle: Vector2 = Vector2.ZERO       # Simulated surface tilt (x: lat, y: long)
var _cup_angular_vel: Vector2 = Vector2.ZERO # First derivative d(theta)/dt
var _water_level: float = 100.0              # 100% -> 0%
var _spill_cooldown: float = 0.0
var _spill_flash_timer: float = 0.0
var _perfect_transfer_flash: float = 0.0
var _ripple_phase: float = 0.0
var _ripple_amplitude: float = 0.0
var _droplets: Array[WaterDropletItem] = []

## 2. Drift Scoring & Combo State
var _is_drifting: bool = false
var _drift_duration: float = 0.0
var _straight_grace_timer: float = 0.0
var _spinout_lockout_timer: float = 0.0
var _last_drift_sign: int = 0

var _active_drift_points: float = 0.0
var _combo_multiplier: float = 1.0
var _eurobeat_meter: float = 0.0             # 0.0 -> 100.0%
var _total_score: int = 0
var _session_high_score: int = 0
var _current_rank_idx: int = 0
var _rank_up_anim_timer: float = 0.0

var _is_in_sweet_spot: bool = false
var _is_gutter_hooked: bool = false
var _has_weight_transfer_bonus: bool = false
var _weight_transfer_cooldown: float = 0.0
var _gutter_Distance_m: float = 99.0

## 3. Manga Onomatopoeia & Callouts State
var _manga_popups: Array[MangaPopupItem] = []
var _callouts: Array[TechniqueCalloutItem] = []
var _sustained_high_angle_timer: float = 0.0
var _cd_dogyaaa: float = 0.0
var _cd_gyaaaa: float = 0.0
var _cd_gatata: float = 0.0
var _cd_kaaah: float = 0.0
var _prev_gear: int = 1
var _prev_rpm_norm: float = 0.0

## 4. Pop-Up Headlights State ([H] Key)
var _headlights_open: bool = true
var _headlight_anim_ratio: float = 1.0
var _left_headlight_spot: SpotLight3D = null
var _right_headlight_spot: SpotLight3D = null
var _left_popup_pivot: Node3D = null
var _right_popup_pivot: Node3D = null
var _vehicle_headlight_nodes: Array[Node3D] = []

# ==============================================================================
# LIFECYCLE METHODS
# ==============================================================================
func _init() -> void:
	layer = 80 # Below AnimePostProcessEffect (90), above 3D scene
	name = "TougeDriftRefereeSystem"

func _ready() -> void:
	_headless_mode = DisplayServer.get_name() == "headless"
	process_mode = Node.PROCESS_MODE_ALWAYS

	_canvas_drawer = Control.new()
	_canvas_drawer.name = "TougeRefereeHUDCanvas"
	_canvas_drawer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas_drawer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_drawer.draw.connect(_on_canvas_draw)
	add_child(_canvas_drawer)

	_locate_player_vehicle()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event: InputEventKey = event as InputEventKey
		match key_event.keycode:
			KEY_H:
				toggle_popup_headlights()
			KEY_F3:
				_hud_visible = not _hud_visible
				if _canvas_drawer != null:
					_canvas_drawer.visible = _hud_visible
			KEY_F4:
				reset_water_cup()

func _process(_delta: float) -> void:
	if not _headless_mode and _canvas_drawer != null and _hud_visible:
		_canvas_drawer.queue_redraw()

func _physics_process(delta: float) -> void:
	var dt: float = clampf(delta, 0.0005, 0.05)

	# Cooldown timers
	_spill_cooldown = maxf(0.0, _spill_cooldown - dt)
	_spill_flash_timer = maxf(0.0, _spill_flash_timer - dt)
	_perfect_transfer_flash = maxf(0.0, _perfect_transfer_flash - dt)
	_spinout_lockout_timer = maxf(0.0, _spinout_lockout_timer - dt)
	_weight_transfer_cooldown = maxf(0.0, _weight_transfer_cooldown - dt)
	_rank_up_anim_timer = maxf(0.0, _rank_up_anim_timer - dt)
	_cd_dogyaaa = maxf(0.0, _cd_dogyaaa - dt)
	_cd_gyaaaa = maxf(0.0, _cd_gyaaaa - dt)
	_cd_gatata = maxf(0.0, _cd_gatata - dt)
	_cd_kaaah = maxf(0.0, _cd_kaaah - dt)

	# Ensure valid player vehicle reference
	if _vehicle == null or not is_instance_valid(_vehicle):
		_vehicle = null
		_drift_solver = null
		_has_prev_kinematics = false
		_vehicle_search_timer -= dt
		if _vehicle_search_timer <= 0.0:
			_vehicle_search_timer = 0.5
			_locate_player_vehicle()
		_update_visual_effects(dt)
		return

	_vehicle_bind_warmup += dt

	# Step 1: Sample vehicle kinematics, G-forces, and Jerk
	_sample_vehicle_telemetry(dt)

	# Step 2: Evaluate Wall & Gutter proximity
	_evaluate_gutter_and_wall_proximity()

	# Step 3: Evaluate Simcade Drift Scoring, Combos, and Rank
	_update_drift_scoring_engine(dt)

	# Step 4: Check Clutch Kick / Redline Shift triggers for Manga Pop-ups
	_check_clutch_kick_and_shift_triggers()

	# Step 5: Animate Pop-Up Headlights
	_update_headlight_animation(dt)

	# Step 6: Update Manga Onomatopoeia and Callouts
	_update_visual_effects(dt)

# ==============================================================================
# VEHICLE DISCOVERY & HEADLIGHT RIGGING
# ==============================================================================
func set_target_vehicle(target: Node3D) -> void:
	if target != null:
		_bind_vehicle(target)

func _locate_player_vehicle() -> void:
	if not is_inside_tree():
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return

	var candidate: Node3D = null
	var search_groups: PackedStringArray = ["player", "vehicle", "player_vehicle", "car"]
	for grp: String in search_groups:
		var nodes: Array[Node] = tree.get_nodes_in_group(grp)
		for n: Node in nodes:
			if n is Node3D:
				candidate = n as Node3D
				break
		if candidate != null:
			break

	if candidate == null and tree.current_scene != null:
		candidate = _find_vehicle_recursive(tree.current_scene)

	if candidate != null:
		_bind_vehicle(candidate)

func _find_vehicle_recursive(root: Node) -> Node3D:
	if root is VehicleBody3D:
		return root as Node3D
	if root is Node3D:
		var n_lower: String = root.name.to_lower()
		if n_lower.contains("car") or n_lower.contains("ae86") or n_lower.contains("trueno") or n_lower.contains("vehicle") or n_lower.contains("player") or n_lower.contains("drift") or n_lower.contains("skyline") or n_lower.contains("gtr") or n_lower.contains("r34") or "speed_kmh" in root:
			return root as Node3D
	for child: Node in root.get_children():
		if child.name == "TougeDriftPhysicsSolver" and root is Node3D:
			return root as Node3D
		var found: Node3D = _find_vehicle_recursive(child)
		if found != null:
			return found
	return null

func _bind_vehicle(target: Node3D) -> void:
	_vehicle = target
	_has_prev_kinematics = false
	_vehicle_bind_warmup = 0.0
	_drift_solver = _vehicle.find_child("TougeDriftPhysicsSolver", true, false)
	if _drift_solver == null:
		for child: Node in _vehicle.get_children():
			if child.get_script() != null and str(child.name).to_lower().contains("drift"):
				_drift_solver = child
				break
	_setup_popup_headlights_on_vehicle()

func _setup_popup_headlights_on_vehicle() -> void:
	_vehicle_headlight_nodes.clear()
	_left_headlight_spot = null
	_right_headlight_spot = null
	_left_popup_pivot = null
	_right_popup_pivot = null

	if _vehicle == null or not is_instance_valid(_vehicle):
		return

	# Discover any existing headlight nodes on the vehicle
	_collect_existing_headlights(_vehicle)

	# Ensure functional retractable pop-up headlights exist on the vehicle
	var existing_rig: Node3D = _vehicle.get_node_or_null("TougePopupHeadlightRig") as Node3D
	if existing_rig != null:
		_left_popup_pivot = existing_rig.get_node_or_null("LeftPopupPivot") as Node3D
		_right_popup_pivot = existing_rig.get_node_or_null("RightPopupPivot") as Node3D
		if _left_popup_pivot != null:
			_left_headlight_spot = _left_popup_pivot.get_node_or_null("SpotLight3D") as SpotLight3D
		if _right_popup_pivot != null:
			_right_headlight_spot = _right_popup_pivot.get_node_or_null("SpotLight3D") as SpotLight3D
		return

	var rig := Node3D.new()
	rig.name = "TougePopupHeadlightRig"
	_vehicle.add_child(rig)

	_left_popup_pivot = _create_popup_headlight_unit("LeftPopupPivot", Vector3(-0.66, 0.64, -1.95))
	_right_popup_pivot = _create_popup_headlight_unit("RightPopupPivot", Vector3(0.66, 0.64, -1.95))
	rig.add_child(_left_popup_pivot)
	rig.add_child(_right_popup_pivot)

	_left_headlight_spot = _left_popup_pivot.get_node_or_null("SpotLight3D") as SpotLight3D
	_right_headlight_spot = _right_popup_pivot.get_node_or_null("SpotLight3D") as SpotLight3D

func _collect_existing_headlights(node: Node) -> void:
	if node is SpotLight3D and node.get_parent() != _left_popup_pivot and node.get_parent() != _right_popup_pivot:
		_vehicle_headlight_nodes.append(node as Node3D)
	elif node is Node3D:
		var nl: String = node.name.to_lower()
		if nl.contains("headlight") or nl.contains("popup") or nl.contains("pop_up"):
			_vehicle_headlight_nodes.append(node as Node3D)
	for child: Node in node.get_children():
		if child.name != "TougePopupHeadlightRig":
			_collect_existing_headlights(child)

func _create_popup_headlight_unit(unit_name: String, local_offset: Vector3) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = unit_name
	pivot.position = local_offset

	var spot := SpotLight3D.new()
	spot.name = "SpotLight3D"
	spot.light_color = Color(1.0, 0.96, 0.84) # Warm halogen AE86 beam
	spot.light_energy = 4.2
	spot.spot_range = 48.0
	spot.spot_angle = 34.0
	spot.spot_attenuation = 1.15
	spot.rotation_degrees = Vector3(-6.0, 0.0, 0.0)
	pivot.add_child(spot)

	return pivot

func toggle_popup_headlights() -> void:
	_headlights_open = not _headlights_open
	headlights_toggled.emit(_headlights_open)
	if _headlights_open:
		_push_callout("POP-UP HEADLIGHTS: ON", "HIGH BEAMS DEPLOYED [H]", Color(1.0, 0.94, 0.55))
	else:
		_push_callout("BLIND ATTACK MODE!", "HEADLIGHTS RETRACTED [H]", Color(0.45, 0.82, 1.0))

func _update_headlight_animation(dt: float) -> void:
	var target_ratio: float = 1.0 if _headlights_open else 0.0
	_headlight_anim_ratio = move_toward(_headlight_anim_ratio, target_ratio, dt * 5.5)

	var pitch_deg: float = lerpf(-82.0, 0.0, _headlight_anim_ratio)
	var beam_energy: float = lerpf(0.0, 4.2, clampf((_headlight_anim_ratio - 0.25) / 0.75, 0.0, 1.0))
	var is_lit: bool = _headlight_anim_ratio > 0.15

	if _left_popup_pivot != null and is_instance_valid(_left_popup_pivot):
		_left_popup_pivot.rotation_degrees.x = pitch_deg
	if _right_popup_pivot != null and is_instance_valid(_right_popup_pivot):
		_right_popup_pivot.rotation_degrees.x = pitch_deg

	if _left_headlight_spot != null and is_instance_valid(_left_headlight_spot):
		_left_headlight_spot.light_energy = beam_energy
		_left_headlight_spot.visible = is_lit
	if _right_headlight_spot != null and is_instance_valid(_right_headlight_spot):
		_right_headlight_spot.light_energy = beam_energy
		_right_headlight_spot.visible = is_lit

	for node: Node3D in _vehicle_headlight_nodes:
		if is_instance_valid(node):
			if node is Light3D:
				(node as Light3D).visible = is_lit
			else:
				node.rotation_degrees.x = pitch_deg

# ==============================================================================
# TELEMETRY, G-FORCE & JERK CALCULATION
# ==============================================================================
func _sample_vehicle_telemetry(dt: float) -> void:
	var g_xform: Transform3D = _vehicle.global_transform
	var curr_pos: Vector3 = g_xform.origin

	# Obtain world velocity vector from physics body or finite difference
	var raw_vel: Vector3 = Vector3.ZERO
	if "linear_velocity" in _vehicle:
		raw_vel = _vehicle.get("linear_velocity") as Vector3
	elif "velocity" in _vehicle:
		raw_vel = _vehicle.get("velocity") as Vector3
	elif _has_prev_kinematics:
		raw_vel = (curr_pos - _prev_global_pos) / dt

	if raw_vel.length_squared() < 0.001 and _has_prev_kinematics:
		raw_vel = (curr_pos - _prev_global_pos) / dt

	# Determine horizontal basis vectors
	var basis_z: Vector3 = -g_xform.basis.z
	basis_z.y = 0.0
	if basis_z.length_squared() < 0.0001:
		basis_z = Vector3.FORWARD
	else:
		basis_z = basis_z.normalized()

	var basis_x: Vector3 = g_xform.basis.x
	basis_x.y = 0.0
	if basis_x.length_squared() < 0.0001:
		basis_x = Vector3.RIGHT
	else:
		basis_x = basis_x.normalized()

	var horiz_vel: Vector3 = Vector3(raw_vel.x, 0.0, raw_vel.z)
	_speed_mps = horiz_vel.length()
	_speed_kmh = _speed_mps * 3.6

	# Auto-calibrate forward sign if vehicle model faces +Z instead of -Z
	var fwd_dot: float = horiz_vel.dot(basis_z)
	if _speed_kmh > 30.0 and absf(_slip_angle_deg) < 25.0:
		if fwd_dot < -5.0:
			_forward_sign = -1.0
		elif fwd_dot > 5.0:
			_forward_sign = 1.0

	var forward_vec: Vector3 = basis_z * _forward_sign
	var right_vec: Vector3 = basis_x * _forward_sign

	# keep pop-up headlight orientation aligned with actual vehicle front
	if _left_popup_pivot != null and _right_popup_pivot != null:
		var z_pos: float = -1.95 * _forward_sign
		_left_popup_pivot.position.z = z_pos
		_right_popup_pivot.position.z = z_pos
		var y_rot: float = 0.0 if _forward_sign > 0.0 else 180.0
		_left_popup_pivot.rotation_degrees.y = y_rot
		_right_popup_pivot.rotation_degrees.y = y_rot

	# Calculate Yaw Rate (rad/s) and Slip Angle Beta (deg)
	var curr_yaw: float = atan2(forward_vec.x, forward_vec.z)
	if not _has_prev_kinematics:
		_prev_global_pos = curr_pos
		_prev_velocity = horiz_vel
		_prev_forward_dir = forward_vec
		_prev_yaw_rad = curr_yaw
		_has_prev_kinematics = true
		return

	var yaw_delta: float = wrapf(curr_yaw - _prev_yaw_rad, -PI, PI)
	var inst_yaw_rate: float = yaw_delta / dt
	_yaw_rate_rads = lerpf(_yaw_rate_rads, inst_yaw_rate, clampf(dt * 22.0, 0.0, 1.0))

	# Read slip angle from TougeDriftPhysicsSolver if available, else compute directly
	var solver_has_slip: bool = false
	if _drift_solver != null and is_instance_valid(_drift_solver):
		if "slip_angle_deg" in _drift_solver:
			_signed_slip_deg = float(_drift_solver.get("slip_angle_deg"))
			_slip_angle_deg = absf(_signed_slip_deg)
			solver_has_slip = true
		elif "slip_angle" in _drift_solver:
			var raw_sa: float = float(_drift_solver.get("slip_angle"))
			_signed_slip_deg = rad_to_deg(raw_sa) if absf(raw_sa) <= PI else raw_sa
			_slip_angle_deg = absf(_signed_slip_deg)
			solver_has_slip = true

	if not solver_has_slip:
		if _speed_mps > 1.2:
			var v_long: float = horiz_vel.dot(forward_vec)
			var v_lat: float = horiz_vel.dot(right_vec)
			_signed_slip_deg = rad_to_deg(atan2(v_lat, v_long))
			_slip_angle_deg = absf(_signed_slip_deg)
		else:
			_signed_slip_deg = move_toward(_signed_slip_deg, 0.0, dt * 90.0)
			_slip_angle_deg = absf(_signed_slip_deg)

	# Calculate Instantaneous Lateral & Longitudinal G-Force:
	# G_lat = (v * yaw_rate) / 9.81
	# G_long = acceleration / 9.81
	var world_accel: Vector3 = (horiz_vel - _prev_velocity) / dt
	var inst_long_accel: float = world_accel.dot(forward_vec)
	_long_accel_mps2 = lerpf(_long_accel_mps2, inst_long_accel, clampf(dt * 18.0, 0.0, 1.0))

	var target_g_lat: float = (_speed_mps * _yaw_rate_rads) / GRAVITY_ACCEL
	var target_g_long: float = _long_accel_mps2 / GRAVITY_ACCEL

	# Clamp extreme physics teleport spikes
	target_g_lat = clampf(target_g_lat, -3.5, 3.5)
	target_g_long = clampf(target_g_long, -3.5, 3.5)

	# Smooth slightly to filter single-tick collision solver noise while preserving true Jerk
	var filter_alpha: float = clampf(dt * 20.0, 0.0, 1.0)
	var new_g_lat: float = lerpf(_g_lat, target_g_lat, filter_alpha)
	var new_g_long: float = lerpf(_g_long, target_g_long, filter_alpha)

	# Jerk vector dG/dt in G/s
	var j_lat: float = (new_g_lat - _g_lat) / dt
	var j_long: float = (new_g_long - _g_long) / dt
	_jerk_vec = _jerk_vec.lerp(Vector2(j_lat, j_long), clampf(dt * 16.0, 0.0, 1.0))
	_jerk_mag = _jerk_vec.length()
	_peak_recent_jerk = maxf(_jerk_mag, move_toward(_peak_recent_jerk, 0.0, dt * 2.5))

	_prev_g_lat = _g_lat
	_prev_g_long = _g_long
	_g_lat = new_g_lat
	_g_long = new_g_long

	_prev_global_pos = curr_pos
	_prev_velocity = horiz_vel
	_prev_forward_dir = forward_vec
	_prev_yaw_rad = curr_yaw

# ==============================================================================
# 1. THE LEGENDARY FUJIWARA WATER CUP (DISABLED - ZERO LAG)
# ==============================================================================
func _update_water_cup_oscillator(_dt: float) -> void:
	pass

func _trigger_water_spill(_jerk_val: float) -> void:
	pass

func reset_water_cup() -> void:
	_water_level = 100.0
	_cup_angle = Vector2.ZERO
	_cup_angular_vel = Vector2.ZERO
	_spill_flash_timer = 0.0
	_push_callout("TOFU WATER CUP REFILLED", "BUNTA'S CHALLENGE READY (100%)", Color(0.35, 0.85, 1.0))

# ==============================================================================
# 2. GUTTER & WALL PROXIMITY DETECTION (< 1.8m)
# ==============================================================================
func _evaluate_gutter_and_wall_proximity() -> void:
	_is_gutter_hooked = false
	_gutter_Distance_m = 99.0

	if _vehicle == null or not is_instance_valid(_vehicle):
		return

	# Check if TougeDriftPhysicsSolver directly reports gutter hook or wall proximity
	if _drift_solver != null and is_instance_valid(_drift_solver):
		if "is_gutter_hooked" in _drift_solver and bool(_drift_solver.get("is_gutter_hooked")):
			_is_gutter_hooked = true
			_gutter_Distance_m = 0.45
		elif "in_gutter" in _drift_solver and bool(_drift_solver.get("in_gutter")):
			_is_gutter_hooked = true
			_gutter_Distance_m = 0.45

	# Perform 3D raycasts around the car for guardrails, walls, and inner drainage gutters
	var world_3d: World3D = _vehicle.get_world_3d()
	if world_3d == null or world_3d.direct_space_state == null:
		return

	var space_state: PhysicsDirectSpaceState3D = world_3d.direct_space_state
	var g_xform: Transform3D = _vehicle.global_transform
	var origin: Vector3 = g_xform.origin + Vector3(0.0, 0.55, 0.0)
	var right_vec: Vector3 = g_xform.basis.x.normalized()
	var fwd_vec: Vector3 = (-g_xform.basis.z * _forward_sign).normalized()

	var exclude_rids: Array[RID] = []
	if _vehicle is CollisionObject3D:
		exclude_rids.append((_vehicle as CollisionObject3D).get_rid())

	# Side & rear-quarter rays to detect guardrail/wall proximity (< 1.8m from vehicle side)
	var ray_dirs: Array[Vector3] = [
		right_vec,
		-right_vec,
		(right_vec - fwd_vec * 0.45).normalized(),
		(-right_vec - fwd_vec * 0.45).normalized()
	]

	for dir: Vector3 in ray_dirs:
		var start_pt: Vector3 = origin + dir * 0.82
		var end_pt: Vector3 = start_pt + dir * GUTTER_PROXIMITY_DIST
		var query := PhysicsRayQueryParameters3D.create(start_pt, end_pt)
		query.exclude = exclude_rids
		var hit: Dictionary = space_state.intersect_ray(query)
		if not hit.is_empty():
			var hit_pos: Vector3 = hit["position"]
			var dist: float = start_pt.distance_to(hit_pos)
			if dist < _gutter_Distance_m:
				_gutter_Distance_m = dist
			if dist <= GUTTER_PROXIMITY_DIST and _slip_angle_deg >= MIN_DRIFT_ANGLE_DEG:
				_is_gutter_hooked = true

	if _is_gutter_hooked and _is_drifting and _cd_gatata <= 0.0:
		_cd_gatata = 1.9
		_spawn_manga_popup("ガタタッ", "GATATA!", Color(0.35, 1.0, 0.55))
		_push_callout("GUTTER HOOK! +50%", "INNER DRAINAGE CHANNEL LOCKED", Color(0.35, 1.0, 0.55))

# ==============================================================================
# 3. SIMCADE DRIFT SCORING ENGINE (ANGLE x SPEED x LINE)
# ==============================================================================
func _update_drift_scoring_engine(dt: float) -> void:
	if _spinout_lockout_timer > 0.0:
		return

	# Check Spin-Out condition (Slip Angle > 70 deg while moving)
	if _slip_angle_deg > SPINOUT_ANGLE_DEG and _speed_kmh > 18.0:
		_trigger_spin_out("SPIN OUT! ANGLE > 70°")
		return

	var meets_drift_criteria: bool = (_slip_angle_deg > MIN_DRIFT_ANGLE_DEG) and (_speed_kmh > MIN_DRIFT_SPEED_KMH)

	if meets_drift_criteria:
		var current_sign: int = 1 if _signed_slip_deg >= 0.0 else -1

		if not _is_drifting:
			# Entering a new drift or chaining within the 1.2s grace window
			_is_drifting = true
			_drift_duration = 0.0
			_straight_grace_timer = 0.0
			drift_started.emit(_speed_kmh, _slip_angle_deg)

			# Aggressive High-Speed Drift Entry (> 75 km/h) -> "ドギャアア" (DOGYAAA!)
			if _speed_kmh > 75.0 and _cd_dogyaaa <= 0.0:
				_cd_dogyaaa = 2.4
				_spawn_manga_popup("ドギャアア", "DOGYAAA!", Color(1.0, 0.32, 0.18))
				if _g_long < -0.04 and _jerk_mag < SMOOTH_TRANSFER_JERK_MAX:
					_push_callout("KANSEI DRIFT!", "HIGH-SPEED INERTIA ENTRY (%.0f KM/H)" % _speed_kmh, Color(1.0, 0.86, 0.20))
				else:
					_push_callout("INERTIA SLIDE!", "AGGRESSIVE ENTRY (%.0f KM/H)" % _speed_kmh, Color(1.0, 0.62, 0.15))

			# Check Smooth Weight Transfer on entry
			if _jerk_mag < SMOOTH_TRANSFER_JERK_MAX and absf(_g_lat) > 0.28 and _water_level > 0.0 and _weight_transfer_cooldown <= 0.0:
				_award_perfect_weight_transfer("SMOOTH ENTRY WEIGHT TRANSFER")

		elif _last_drift_sign != 0 and current_sign != _last_drift_sign:
			# Chained side-to-side hairpin transition (Furikaeshi / S-curve weight transfer)
			_combo_multiplier = minf(MAX_COMBO_MULTIPLIER, _combo_multiplier + 0.35)
			if _jerk_mag < SMOOTH_TRANSFER_JERK_MAX and _water_level > 0.0 and _weight_transfer_cooldown <= 0.0:
				_award_perfect_weight_transfer("HAIRPIN APEX TRANSITION!")
			else:
				_push_callout("HAIRPIN APEX!", "CHAIN COMBO x%.1f" % _combo_multiplier, Color(0.45, 0.90, 1.0))

		_last_drift_sign = current_sign
		_drift_duration += dt
		_straight_grace_timer = 0.0

		# Build continuous combo multiplier up to 5.0x
		var combo_rate: float = 0.26 if not _is_in_sweet_spot else 0.38
		_combo_multiplier = minf(MAX_COMBO_MULTIPLIER, _combo_multiplier + combo_rate * dt)

		# Base Drift Points per second:
		# Points_sec = (Slip_Angle_Deg * 18.0) * (Vehicle_Speed_KMH / 45.0)
		var base_points_sec: float = (_slip_angle_deg * 18.0) * (_speed_kmh / 45.0)

		# Angle Sweet Spot evaluation (25 deg to 45 deg)
		var angle_mult: float = 1.0
		_is_in_sweet_spot = (_slip_angle_deg >= SWEET_SPOT_MIN_DEG and _slip_angle_deg <= SWEET_SPOT_MAX_DEG)
		if _is_in_sweet_spot:
			var center_closeness: float = 1.0 - (absf(_slip_angle_deg - 35.0) / 10.0)
			angle_mult = lerpf(1.30, 1.50, clampf(center_closeness, 0.0, 1.0))
		elif _slip_angle_deg < SWEET_SPOT_MIN_DEG:
			angle_mult = lerpf(1.0, 1.25, (_slip_angle_deg - MIN_DRIFT_ANGLE_DEG) / (SWEET_SPOT_MIN_DEG - MIN_DRIFT_ANGLE_DEG))
		else:
			angle_mult = lerpf(1.25, 0.85, (_slip_angle_deg - SWEET_SPOT_MAX_DEG) / (SPINOUT_ANGLE_DEG - SWEET_SPOT_MAX_DEG))

		# Line / Gutter Hook Multiplier (+50%)
		var line_mult: float = GUTTER_HOOK_MULTIPLIER if _is_gutter_hooked else 1.0

		# Perfect Weight Transfer Multiplier (+25%)
		var transfer_mult: float = (1.0 + SMOOTH_TRANSFER_BONUS) if _has_weight_transfer_bonus else 1.0

		# Eurobeat Meter fill & bonus
		_eurobeat_meter = minf(100.0, _eurobeat_meter + dt * 9.5 * angle_mult)
		var eurobeat_mult: float = 1.20 if _eurobeat_meter >= 99.5 else 1.0

		var points_this_frame: float = base_points_sec * angle_mult * line_mult * transfer_mult * eurobeat_mult * dt
		_active_drift_points += points_this_frame

		# Sustained High Slip-Angle (> 35 deg) -> "ギャアア" (GYAAAA!)
		if _slip_angle_deg > 35.0:
			_sustained_high_angle_timer += dt
			if _sustained_high_angle_timer >= 0.35 and _cd_gyaaaa <= 0.0:
				_cd_gyaaaa = 2.1
				_spawn_manga_popup("ギャアア", "GYAAAA!", Color(1.0, 0.85, 0.12))
		else:
			_sustained_high_angle_timer = maxf(0.0, _sustained_high_angle_timer - dt * 2.0)

	else:
		_sustained_high_angle_timer = 0.0
		_is_in_sweet_spot = false
		if _is_drifting:
			_straight_grace_timer += dt
			# If straightened out for > 1.2s, bank the accumulated combo score!
			if _straight_grace_timer >= COMBO_GRACE_TIME_SEC:
				_bank_active_drift_score()
		else:
			_eurobeat_meter = maxf(0.0, _eurobeat_meter - dt * 4.5)

	# Update Dynamic Drift Rank Badge
	_update_rank_progression()

func _award_perfect_weight_transfer(reason_subtext: String) -> void:
	_has_weight_transfer_bonus = true
	_weight_transfer_cooldown = 2.6
	_perfect_transfer_flash = 1.1
	_eurobeat_meter = minf(100.0, _eurobeat_meter + 28.0)
	_push_callout("PERFECT WEIGHT TRANSFER! +25%", reason_subtext, Color(0.25, 1.0, 0.88))
	perfect_weight_transfer_achieved.emit(1.0 + SMOOTH_TRANSFER_BONUS)

func _bank_active_drift_score() -> void:
	var banked: int = int(round(_active_drift_points * _combo_multiplier))
	if banked > 0:
		_total_score += banked
		if _total_score > _session_high_score:
			_session_high_score = _total_score
		_push_callout("DRIFT BANKED! +%s PTS" % _format_number(banked), "PEAK COMBO x%.1f" % _combo_multiplier, Color(0.35, 1.0, 0.50))
		drift_banked.emit(banked, _combo_multiplier, _total_score)

	_is_drifting = false
	_drift_duration = 0.0
	_straight_grace_timer = 0.0
	_active_drift_points = 0.0
	_combo_multiplier = 1.0
	_last_drift_sign = 0
	_has_weight_transfer_bonus = false

func _trigger_spin_out(reason: String) -> void:
	var lost_points: int = int(round(_active_drift_points * _combo_multiplier))
	_is_drifting = false
	_drift_duration = 0.0
	_straight_grace_timer = 0.0
	_active_drift_points = 0.0
	_combo_multiplier = 1.0
	_eurobeat_meter = maxf(0.0, _eurobeat_meter - 40.0)
	_last_drift_sign = 0
	_has_weight_transfer_bonus = false
	_spinout_lockout_timer = 1.5

	_push_callout("SPIN OUT!", "%s (-%s UNBANKED PTS)" % [reason, _format_number(lost_points)], Color(1.0, 0.18, 0.25))
	drift_failed.emit(reason, lost_points)

func _update_rank_progression() -> void:
	var effective_score: int = _total_score + int(round(_active_drift_points * _combo_multiplier))
	var new_rank: int = 0
	for i: int in range(RANK_THRESHOLDS.size()):
		if effective_score >= RANK_THRESHOLDS[i]:
			new_rank = i

	if new_rank > _current_rank_idx:
		_current_rank_idx = new_rank
		_rank_up_anim_timer = 1.5
		var r_title: String = RANK_TITLES[_current_rank_idx]
		var r_sub: String = RANK_SUBTITLES[_current_rank_idx]
		_push_callout("RANK UP: %s!" % r_title, r_sub, RANK_COLORS[_current_rank_idx])
		rank_upgraded.emit(_current_rank_idx, r_title)
	elif new_rank < _current_rank_idx and not _is_drifting:
		_current_rank_idx = new_rank

# ==============================================================================
# 4. CLUTCH KICKS, GEAR SHIFTS & MANGA ONOMATOPOEIA SPAWNER
# ==============================================================================
func _check_clutch_kick_and_shift_triggers() -> void:
	if _vehicle == null or _cd_kaaah > 0.0:
		return

	var trigger_kaaah: bool = false

	# Check solver telemetry for redline shift or clutch kick
	if _drift_solver != null and is_instance_valid(_drift_solver):
		if "current_gear" in _drift_solver:
			var curr_gear: int = int(_drift_solver.get("current_gear"))
			if curr_gear != _prev_gear and _speed_kmh > 35.0:
				trigger_kaaah = true
			_prev_gear = curr_gear
		if "is_clutch_kicking" in _drift_solver and bool(_drift_solver.get("is_clutch_kicking")):
			trigger_kaaah = true
		if "rpm_normalized" in _drift_solver:
			var rpm_n: float = float(_drift_solver.get("rpm_normalized"))
			if rpm_n > 0.90 and _prev_rpm_norm <= 0.90 and _speed_kmh > 40.0:
				trigger_kaaah = true
			_prev_rpm_norm = rpm_n

	# Also detect manual clutch kick / handbrake initiation (Spacebar while at speed)
	if Input.is_key_pressed(KEY_SPACE) and _speed_kmh > 42.0 and _slip_angle_deg > 10.0:
		trigger_kaaah = true

	if trigger_kaaah:
		_cd_kaaah = 2.2
		_spawn_manga_popup("カァッ", "KAAAH!", Color(0.35, 0.88, 1.0))

func _spawn_manga_popup(katakana_text: String, romaji_text: String, accent: Color) -> void:
	if not enable_manga_text_popups:
		return
	var item := MangaPopupItem.new()
	item.katakana = katakana_text
	item.romaji = romaji_text
	item.accent_color = accent
	item.lifetime = MANGA_POPUP_LIFETIME
	item.tilt_rad = deg_to_rad(randf_range(-13.0, 13.0))
	if absf(item.tilt_rad) < 0.08:
		item.tilt_rad = -0.14
	item.spike_seed = randi_range(100, 99999)

	var vp_size: Vector2 = _get_viewport_size()
	var base_pos: Vector2 = vp_size * Vector2(0.5, 0.52)

	# Project 3D vehicle position to screen space if active Camera3D exists
	var cam: Camera3D = get_viewport().get_camera_3d() if (is_inside_tree() and get_viewport() != null) else null
	if cam != null and _vehicle != null and is_instance_valid(_vehicle):
		var world_target: Vector3 = _vehicle.global_position + Vector3(0.0, 1.15, 0.0)
		if not cam.is_position_behind(world_target):
			base_pos = cam.unproject_position(world_target)

	var side_dir: float = -1.0 if (_manga_popups.size() % 2 == 0) else 1.0
	var offset := Vector2(side_dir * randf_range(135.0, 225.0), randf_range(-85.0, 25.0))
	item.screen_pos = (base_pos + offset).clamp(
		Vector2(180.0, 140.0),
		Vector2(maxf(200.0, vp_size.x - 180.0), maxf(180.0, vp_size.y - 160.0))
	)
	item.velocity = Vector2(side_dir * 22.0, -78.0)

	_manga_popups.append(item)
	if _manga_popups.size() > 6:
		_manga_popups.pop_front()

func _push_callout(title: String, subtitle: String, col: Color) -> void:
	# Avoid duplicating identical active callouts
	for existing: TechniqueCalloutItem in _callouts:
		if existing.text == title and existing.age < 0.45:
			return

	var c := TechniqueCalloutItem.new()
	c.text = title
	c.subtext = subtitle
	c.color = col
	c.lifetime = 1.45
	_callouts.append(c)
	if _callouts.size() > 3:
		_callouts.pop_front()

func _update_visual_effects(dt: float) -> void:
	# Update Manga Popups
	var i: int = _manga_popups.size() - 1
	while i >= 0:
		var m: MangaPopupItem = _manga_popups[i]
		m.age += dt
		m.screen_pos += m.velocity * dt
		if m.age >= m.lifetime:
			_manga_popups.remove_at(i)
		i -= 1

	# Update Technique Callouts
	var j: int = _callouts.size() - 1
	while j >= 0:
		var c: TechniqueCalloutItem = _callouts[j]
		c.age += dt
		if c.age >= c.lifetime:
			_callouts.remove_at(j)
		j -= 1

	# Update Water Splash Droplets
	var k: int = _droplets.size() - 1
	while k >= 0:
		var d: WaterDropletItem = _droplets[k]
		d.age += dt
		d.vel.y += 420.0 * dt
		d.pos += d.vel * dt
		if d.age >= d.lifetime:
			_droplets.remove_at(k)
		k -= 1

# ==============================================================================
# 5. VECTOR HUD & MANGA ONOMATOPOEIA RENDERING (_draw)
# ==============================================================================
func _on_canvas_draw() -> void:
	if _headless_mode or not _hud_visible or _canvas_drawer == null:
		return

	var font: Font = ThemeDB.fallback_font
	if font == null:
		return

	var vp_size: Vector2 = _get_viewport_size()

	# 1. Draw Manga Onomatopoeia Pop-Ups in screen space around the car
	_draw_manga_popups(font)

	# 2. Draw Top-Center Dynamic Touge Drift Rank Badge
	_draw_top_center_rank_badge(font, vp_size)

	# 3. Draw Top-Right Initial D Arcade Score, Combo & Active Drift Counter
	_draw_top_right_score_panel(font, vp_size)

	# 4. Draw Center-Screen Technique Callouts
	_draw_center_callouts(font, vp_size)

# ------------------------------------------------------------------------------
# MANGA ONOMATOPOEIA DRAWING
# ------------------------------------------------------------------------------
func _draw_manga_popups(font: Font) -> void:
	for m: MangaPopupItem in _manga_popups:
		var progress: float = clampf(m.age / m.lifetime, 0.0, 1.0)

		# Dynamic pop-scale animation: pops in at 1.4, settles to 1.0, fades out over 0.7s
		var scale_val: float = MANGA_POP_SCALE_SETTLE
		if progress < 0.22:
			var t_in: float = progress / 0.22
			scale_val = lerpf(MANGA_POP_SCALE_START, 0.96, ease(t_in, -2.2))
		elif progress < 0.35:
			var t_settle: float = (progress - 0.22) / 0.13
			scale_val = lerpf(0.96, MANGA_POP_SCALE_SETTLE, t_settle)

		var alpha: float = 1.0
		if progress > 0.62:
			alpha = clampf(1.0 - ((progress - 0.62) / 0.38), 0.0, 1.0)

		# Construct bold italic comic transform matrix (rotation + shear + scale)
		var rot: float = m.tilt_rad
		var italic_shear: float = -0.26
		var cos_r: float = cos(rot) * scale_val
		var sin_r: float = sin(rot) * scale_val
		var x_axis := Vector2(cos_r, sin_r)
		var y_axis := Vector2(-sin_r + cos_r * italic_shear, cos_r + sin_r * italic_shear)
		var xform := Transform2D(x_axis, y_axis, m.screen_pos)

		_canvas_drawer.draw_set_transform_matrix(xform)

		# Draw jagged manga speed-burst backing plate
		var burst_outer := PackedVector2Array()
		var burst_inner := PackedVector2Array()
		var num_spikes: int = 16
		for s: int in range(num_spikes * 2):
			var ang: float = (float(s) / float(num_spikes * 2)) * TAU
			var is_tip: bool = (s % 2 == 0)
			var pseudo_rand: float = fposmod(sin(float(s * 37 + m.spike_seed) * 12.9898) * 43758.5453, 1.0)
			var rx: float = (118.0 + pseudo_rand * 28.0) if is_tip else (68.0 + pseudo_rand * 12.0)
			var ry: float = (54.0 + pseudo_rand * 16.0) if is_tip else (32.0 + pseudo_rand * 8.0)
			burst_outer.append(Vector2(cos(ang) * rx, sin(ang) * ry - 8.0))
			burst_inner.append(Vector2(cos(ang) * (rx * 0.88), sin(ang) * (ry * 0.88) - 8.0))

		_canvas_drawer.draw_polygon(burst_outer, [Color(0.03, 0.03, 0.05, 0.92 * alpha)])
		var inner_col := Color(m.accent_color.r, m.accent_color.g, m.accent_color.b, 0.28 * alpha)
		_canvas_drawer.draw_polygon(burst_inner, [inner_col])
		burst_outer.append(burst_outer[0])
		_canvas_drawer.draw_polyline(burst_outer, Color(m.accent_color.r, m.accent_color.g, m.accent_color.b, 0.95 * alpha), 2.5)

		# Heavy black comic ink drop-shadow + outline + crisp white fill
		var font_sz: int = 44
		var text_pos := Vector2(-115.0, 10.0)
		var ink_black := Color(0.0, 0.0, 0.0, alpha)
		var fill_white := Color(1.0, 1.0, 1.0, alpha)
		var accent_mod := Color(m.accent_color.r, m.accent_color.g, m.accent_color.b, alpha)

		# Deep comic ink shadow
		_canvas_drawer.draw_string_outline(font, text_pos + Vector2(5.0, 5.0), m.katakana, HORIZONTAL_ALIGNMENT_CENTER, 230.0, font_sz, 14, ink_black)
		# Accent halo
		_canvas_drawer.draw_string_outline(font, text_pos + Vector2(2.0, 2.0), m.katakana, HORIZONTAL_ALIGNMENT_CENTER, 230.0, font_sz, 10, accent_mod)
		# Primary black comic outline
		_canvas_drawer.draw_string_outline(font, text_pos, m.katakana, HORIZONTAL_ALIGNMENT_CENTER, 230.0, font_sz, 8, ink_black)
		# Crisp white manga character fill
		_canvas_drawer.draw_string(font, text_pos, m.katakana, HORIZONTAL_ALIGNMENT_CENTER, 230.0, font_sz, fill_white)

		# Romaji comic subtitle tag
		var sub_pos := Vector2(-95.0, 32.0)
		_canvas_drawer.draw_string_outline(font, sub_pos, "[ %s ]" % m.romaji, HORIZONTAL_ALIGNMENT_CENTER, 190.0, 14, 5, ink_black)
		_canvas_drawer.draw_string(font, sub_pos, "[ %s ]" % m.romaji, HORIZONTAL_ALIGNMENT_CENTER, 190.0, 14, accent_mod)

	_canvas_drawer.draw_set_transform_matrix(Transform2D.IDENTITY)

# ------------------------------------------------------------------------------
# TOP-CENTER DYNAMIC DRIFT RANK BADGE
# ------------------------------------------------------------------------------
func _draw_top_center_rank_badge(font: Font, vp_size: Vector2) -> void:
	var center_x: float = vp_size.x * 0.5
	var top_y: float = 18.0
	var badge_w: float = 250.0
	var badge_h: float = 68.0

	var pulse_scale: float = 1.0 + sin(_rank_up_anim_timer * 18.0) * 0.12 * clampf(_rank_up_anim_timer, 0.0, 1.0)
	var badge_origin := Vector2(center_x, top_y + badge_h * 0.5)
	_canvas_drawer.draw_set_transform(badge_origin, 0.0, Vector2(pulse_scale, pulse_scale))

	var hw: float = badge_w * 0.5
	var hh: float = badge_h * 0.5
	var rank_col: Color = RANK_COLORS[_current_rank_idx]

	# Sleek angled arcade carbon housing
	var bg_poly := PackedVector2Array([
		Vector2(-hw + 14.0, -hh),
		Vector2(hw - 14.0, -hh),
		Vector2(hw, 0.0),
		Vector2(hw - 18.0, hh),
		Vector2(-hw + 18.0, hh),
		Vector2(-hw, 0.0)
	])
	_canvas_drawer.draw_polygon(bg_poly, [Color(0.05, 0.06, 0.09, 0.90)])
	bg_poly.append(bg_poly[0])
	_canvas_drawer.draw_polyline(bg_poly, rank_col, 2.5)

	# Header label
	_canvas_drawer.draw_string(font, Vector2(-hw, -hh + 15.0), "TOUGE DRIFT RANK", HORIZONTAL_ALIGNMENT_CENTER, badge_w, 11, Color(0.75, 0.82, 0.90, 0.9))

	# Rank Title
	var rank_title: String = RANK_TITLES[_current_rank_idx]
	var title_font_sz: int = 28 if _current_rank_idx < 6 else 22
	_canvas_drawer.draw_string_outline(font, Vector2(-hw, 9.0), rank_title, HORIZONTAL_ALIGNMENT_CENTER, badge_w, title_font_sz, 6, Color(0.0, 0.0, 0.0, 0.95))
	_canvas_drawer.draw_string(font, Vector2(-hw, 9.0), rank_title, HORIZONTAL_ALIGNMENT_CENTER, badge_w, title_font_sz, rank_col)

	# Rank Subtitle & progress bar to next rank
	var rank_sub: String = RANK_SUBTITLES[_current_rank_idx]
	_canvas_drawer.draw_string(font, Vector2(-hw, hh - 7.0), rank_sub, HORIZONTAL_ALIGNMENT_CENTER, badge_w, 10, Color(0.92, 0.95, 1.0, 0.85))

	_canvas_drawer.draw_set_transform_matrix(Transform2D.IDENTITY)

# ------------------------------------------------------------------------------
# TOP-RIGHT SCORE, COMBO & EUROBEAT HUD PANEL
# ------------------------------------------------------------------------------
func _draw_top_right_score_panel(font: Font, vp_size: Vector2) -> void:
	var panel_w: float = 330.0
	var panel_h: float = 168.0
	var panel_x: float = vp_size.x - panel_w - 22.0
	var panel_y: float = 18.0

	# Skewed Arcade Stage panel background
	var poly := PackedVector2Array([
		Vector2(panel_x + 16.0, panel_y),
		Vector2(panel_x + panel_w, panel_y),
		Vector2(panel_x + panel_w - 10.0, panel_y + panel_h),
		Vector2(panel_x, panel_y + panel_h)
	])
	_canvas_drawer.draw_polygon(poly, [Color(0.04, 0.05, 0.08, 0.88)])

	var border_col: Color = Color(1.0, 0.78, 0.15, 0.95) if _is_drifting else Color(0.25, 0.65, 0.95, 0.80)
	poly.append(poly[0])
	_canvas_drawer.draw_polyline(poly, border_col, 2.2)

	# 1. Banked Total Score
	_canvas_drawer.draw_string(font, Vector2(panel_x + 24.0, panel_y + 22.0), "TOTAL DRIFT SCORE", HORIZONTAL_ALIGNMENT_LEFT, 180.0, 12, Color(0.68, 0.76, 0.88))
	var total_str: String = _format_number(_total_score)
	_canvas_drawer.draw_string_outline(font, Vector2(panel_x + 20.0, panel_y + 48.0), total_str, HORIZONTAL_ALIGNMENT_RIGHT, panel_w - 36.0, 26, 5, Color.BLACK)
	_canvas_drawer.draw_string(font, Vector2(panel_x + 20.0, panel_y + 48.0), total_str, HORIZONTAL_ALIGNMENT_RIGHT, panel_w - 36.0, 26, Color(1.0, 0.98, 0.90))

	# 2. Active Drift Points & Combo Multiplier
	var active_pts_int: int = int(round(_active_drift_points))
	var active_col: Color = Color(1.0, 0.86, 0.18) if _is_drifting else Color(0.48, 0.54, 0.62)
	if _is_in_sweet_spot:
		active_col = Color(0.30, 1.0, 0.55)

	_canvas_drawer.draw_string(font, Vector2(panel_x + 24.0, panel_y + 72.0), "ACTIVE DRIFT", HORIZONTAL_ALIGNMENT_LEFT, 140.0, 12, Color(0.68, 0.76, 0.88))
	var active_str: String = "+%s" % _format_number(active_pts_int)
	_canvas_drawer.draw_string_outline(font, Vector2(panel_x + 24.0, panel_y + 98.0), active_str, HORIZONTAL_ALIGNMENT_LEFT, 190.0, 24, 5, Color.BLACK)
	_canvas_drawer.draw_string(font, Vector2(panel_x + 24.0, panel_y + 98.0), active_str, HORIZONTAL_ALIGNMENT_LEFT, 190.0, 24, active_col)

	# Combo Multiplier Badge (e.g., "x3.2")
	var combo_str: String = "x%.1f" % _combo_multiplier
	var combo_col: Color = Color(0.35, 0.88, 1.0)
	if _combo_multiplier >= 4.0:
		combo_col = Color(1.0, 0.25, 0.38)
	elif _combo_multiplier >= 2.5:
		combo_col = Color(1.0, 0.78, 0.15)
	_canvas_drawer.draw_string_outline(font, Vector2(panel_x + 180.0, panel_y + 98.0), combo_str, HORIZONTAL_ALIGNMENT_RIGHT, panel_w - 196.0, 28, 6, Color.BLACK)
	_canvas_drawer.draw_string(font, Vector2(panel_x + 180.0, panel_y + 98.0), combo_str, HORIZONTAL_ALIGNMENT_RIGHT, panel_w - 196.0, 28, combo_col)

	# 3. Live Telemetry Bar (Angle, Speed, Gutter & Headlights)
	var tele_str: String = "ANGLE: %02.0f°   SPD: %03.0f KM/H" % [_slip_angle_deg, _speed_kmh]
	_canvas_drawer.draw_string(font, Vector2(panel_x + 24.0, panel_y + 122.0), tele_str, HORIZONTAL_ALIGNMENT_LEFT, panel_w - 40.0, 13, Color(0.85, 0.92, 1.0))

	# 4. Eurobeat Combo Fever Bar
	var bar_x: float = panel_x + 24.0
	var bar_y: float = panel_y + 132.0
	var bar_w: float = panel_w - 48.0
	var bar_h: float = 10.0
	_canvas_drawer.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.12, 0.15, 0.20, 0.95), true)
	var fill_w: float = bar_w * clampf(_eurobeat_meter / 100.0, 0.0, 1.0)
	var eb_col: Color = Color(1.0, 0.30, 0.55) if _eurobeat_meter >= 99.5 else Color(0.98, 0.62, 0.12)
	if fill_w > 0.5:
		_canvas_drawer.draw_rect(Rect2(bar_x, bar_y, fill_w, bar_h), eb_col, true)
	_canvas_drawer.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.55, 0.65, 0.78, 0.8), false, 1.2)

	# Status Pills (Headlights [H], Gutter Hook, Sweet Spot)
	var hl_text: String = "HEADLIGHTS: OPEN [H]" if _headlights_open else "BLIND ATTACK: OFF [H]"
	var hl_col: Color = Color(1.0, 0.92, 0.45) if _headlights_open else Color(0.45, 0.78, 1.0)
	_canvas_drawer.draw_string(font, Vector2(panel_x + 24.0, panel_y + 158.0), hl_text, HORIZONTAL_ALIGNMENT_LEFT, 180.0, 11, hl_col)

	var mode_tag: String = "EUROBEAT FEVER!" if _eurobeat_meter >= 99.5 else ("GUTTER HOOK!" if _is_gutter_hooked else ("SWEET SPOT!" if _is_in_sweet_spot else "TOUGE RUN"))
	var tag_col: Color = Color(0.35, 1.0, 0.55) if (_is_gutter_hooked or _is_in_sweet_spot) else Color(0.75, 0.80, 0.88)
	_canvas_drawer.draw_string(font, Vector2(panel_x + 160.0, panel_y + 158.0), mode_tag, HORIZONTAL_ALIGNMENT_RIGHT, panel_w - 178.0, 11, tag_col)

# ------------------------------------------------------------------------------
# BOTTOM-LEFT LEGENDARY FUJIWARA WATER CUP WIDGET
# ------------------------------------------------------------------------------
func _get_cup_widget_center(vp_size: Vector2) -> Vector2:
	# Positioned in bottom-left above controls guide
	return Vector2(126.0, vp_size.y - 235.0)

func _draw_bottom_left_water_cup_widget(_font: Font, _vp_size: Vector2) -> void:
	pass

# ------------------------------------------------------------------------------
# CENTER-SCREEN TECHNIQUE CALLOUTS
# ------------------------------------------------------------------------------
func _draw_center_callouts(font: Font, vp_size: Vector2) -> void:
	var base_y: float = vp_size.y * 0.22
	var cx: float = vp_size.x * 0.5

	for idx: int in range(_callouts.size()):
		var c: TechniqueCalloutItem = _callouts[idx]
		var progress: float = clampf(c.age / c.lifetime, 0.0, 1.0)
		var alpha: float = 1.0
		if progress > 0.70:
			alpha = clampf(1.0 - ((progress - 0.70) / 0.30), 0.0, 1.0)

		var pop_scale: float = 1.0
		if progress < 0.14:
			pop_scale = lerpf(1.32, 1.0, progress / 0.14)

		var y_pos: float = base_y + float(idx) * 52.0 - progress * 14.0
		_canvas_drawer.draw_set_transform(Vector2(cx, y_pos), 0.0, Vector2(pop_scale, pop_scale))

		var title_col := Color(c.color.r, c.color.g, c.color.b, alpha)
		var sub_col := Color(0.95, 0.97, 1.0, alpha * 0.92)
		var outline_col := Color(0.0, 0.0, 0.0, alpha * 0.95)

		_canvas_drawer.draw_string_outline(font, Vector2(-260.0, 0.0), c.text, HORIZONTAL_ALIGNMENT_CENTER, 520.0, 24, 6, outline_col)
		_canvas_drawer.draw_string(font, Vector2(-260.0, 0.0), c.text, HORIZONTAL_ALIGNMENT_CENTER, 520.0, 24, title_col)

		if not c.subtext.is_empty():
			_canvas_drawer.draw_string_outline(font, Vector2(-260.0, 18.0), c.subtext, HORIZONTAL_ALIGNMENT_CENTER, 520.0, 13, 4, outline_col)
			_canvas_drawer.draw_string(font, Vector2(-260.0, 18.0), c.subtext, HORIZONTAL_ALIGNMENT_CENTER, 520.0, 13, sub_col)

	_canvas_drawer.draw_set_transform_matrix(Transform2D.IDENTITY)

# ==============================================================================
# UTILITY HELPERS & PUBLIC API
# ==============================================================================
func _get_viewport_size() -> Vector2:
	if is_inside_tree() and get_viewport() != null:
		var rect_size: Vector2 = get_viewport().get_visible_rect().size
		if rect_size.x > 1.0 and rect_size.y > 1.0:
			return rect_size
	return Vector2(1280.0, 720.0)

func _format_number(val: int) -> String:
	var s: String = str(absi(val))
	var res: String = ""
	var count: int = 0
	for i: int in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			res = "," + res
		res = s[i] + res
		count += 1
	return ("-" + res) if val < 0 else res

func get_total_score() -> int:
	return _total_score

func get_active_drift_points() -> int:
	return int(round(_active_drift_points))

func get_combo_multiplier() -> float:
	return _combo_multiplier

func get_water_level_percent() -> float:
	return _water_level

func get_current_rank_title() -> String:
	return RANK_TITLES[_current_rank_idx]