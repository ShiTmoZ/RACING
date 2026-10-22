class_name ArcadeChaseCamera extends Camera3D
# ==============================================================================
# ARCADE CHASE CAMERA - FORZA MOTORSPORT 6 / HORIZON 5 COMMANDING EDITION
# Engine: Godot 4.3 Forward+
# Architecture: Frame-Rate Independent Exponential Damping + Apex Look-Ahead
# ==============================================================================

enum CameraMode {
	FORZA_FAR_CHASE = 0,
	FORZA_CLOSE_CHASE = 1,
	HOOD_ROOF_CAM = 2
}

# --- Exported Target & Forza Commanding Viewpoint Parameters ---
@export var target: Node3D = null
@export var distance: float = 6.8        # Dynamic range: 6.6m to 8.4m at top speed
@export var height: float = 2.45         # Elevated well above roofline & tire smoke
@export var base_fov: float = 64.0
@export var max_fov: float = 78.0

# --- Look-At & Apex Tracking Parameters ---
@export var target_height_offset: float = 1.25 # Keeps smoke in lower 1/3 of screen
@export var apex_look_ahead_dist: float = 4.2  # Shifts gaze into corner apex during drift
@export var max_drift_yaw_deg: float = 24.0    # Maximum camera orbit into slip vector

# --- Exponential Damping Constants (1.0 - exp(-k * dt)) ---
@export var horizontal_damping: float = 11.5
@export var vertical_pitch_damping: float = 5.2 # Soft curb/jump shock absorption
@export var rotation_yaw_damping: float = 8.5
@export var apex_offset_damping: float = 7.0
@export var fov_damping: float = 6.0

# --- Camera Mode State ---
var current_mode: CameraMode = CameraMode.FORZA_FAR_CHASE

# --- Internal Smoothed State ---
var _initialized: bool = false
var _smoothed_pivot_pos: Vector3 = Vector3.ZERO
var _smoothed_yaw_dir: Vector3 = Vector3.FORWARD
var _smoothed_look_ahead: Vector3 = Vector3.ZERO
var _smoothed_roll_rad: float = 0.0
var _hud_mode_label: Label = null
var _hud_fade_timer: float = 0.0

# ==============================================================================
# INITIALIZATION & INPUT
# ==============================================================================
func _ready() -> void:
	top_level = true
	fov = base_fov
	_create_camera_mode_hud()
	if is_instance_valid(target):
		_snap_to_target()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_V or event.keycode == KEY_C:
			cycle_camera_mode()
			get_viewport().set_input_as_handled()

func cycle_camera_mode() -> void:
	var next_idx: int = (int(current_mode) + 1) % 3
	current_mode = next_idx as CameraMode
	_show_mode_banner()

func set_target(new_target: Node3D) -> void:
	target = new_target
	if is_instance_valid(target):
		_snap_to_target()

func snap_to_target(new_target: Node3D = null) -> void:
	if is_instance_valid(new_target):
		target = new_target
	_snap_to_target()

func reset_camera_interpolation() -> void:
	_snap_to_target()

func _snap_to_target() -> void:
	if not is_instance_valid(target):
		return
	_smoothed_pivot_pos = target.global_position
	var fwd: Vector3 = -target.global_transform.basis.z
	fwd.y = 0.0
	_smoothed_yaw_dir = fwd.normalized() if fwd.length_squared() > 0.001 else Vector3.FORWARD
	_smoothed_look_ahead = Vector3.ZERO
	_initialized = true

# ==============================================================================
# FRAME-RATE INDEPENDENT CAMERA SOLVER
# ==============================================================================
func _physics_process(delta: float) -> void:
	_update_camera_transform(delta)

func _process(delta: float) -> void:
	if _hud_fade_timer > 0.0:
		_hud_fade_timer = maxf(_hud_fade_timer - delta, 0.0)
		if is_instance_valid(_hud_mode_label):
			_hud_mode_label.modulate.a = clampf(_hud_fade_timer / 0.6, 0.0, 1.0)

func _update_camera_transform(delta: float) -> void:
	if not is_instance_valid(target):
		return

	if not _initialized:
		_snap_to_target()

	var dt: float = clampf(delta, 0.0001, 0.1)

	# 1. Extract Vehicle Kinematics (Velocity, Slip Vector, Angular Rate)
	var car_pos: Vector3 = target.global_position
	var car_basis: Basis = target.global_transform.basis
	var car_fwd: Vector3 = -car_basis.z
	var car_right: Vector3 = car_basis.x
	var car_up: Vector3 = car_basis.y

	var lin_vel: Vector3 = Vector3.ZERO
	var ang_vel: Vector3 = Vector3.ZERO
	if target is RigidBody3D:
		var rb := target as RigidBody3D
		lin_vel = rb.linear_velocity
		ang_vel = rb.angular_velocity

	var speed_mps: float = lin_vel.length()
	var forward_speed: float = lin_vel.dot(car_fwd)
	var is_reversing: bool = forward_speed < -2.2

	# 2. Mode 3: HOOD / ROOF CAM (Zero Smoke Occlusion, Pure Apex Sensation)
	if current_mode == CameraMode.HOOD_ROOF_CAM:
		var hood_offset: Vector3 = (car_up * 1.38) + (car_fwd * 0.42)
		var desired_hood_pos: Vector3 = car_pos + hood_offset
		var alpha_hood: float = 1.0 - exp(-28.0 * dt)
		global_position = global_position.lerp(desired_hood_pos, alpha_hood)

		var yaw_peek: float = clampf(-ang_vel.y * 0.18, -0.25, 0.25)
		var look_dir: Vector3 = (car_fwd + car_right * yaw_peek).normalized()
		var target_basis: Basis = Basis.looking_at(look_dir, car_up)
		global_transform.basis = global_transform.basis.slerp(target_basis, 1.0 - exp(-20.0 * dt)).orthonormalized()

		var speed_t_hood: float = clampf(speed_mps / 62.0, 0.0, 1.0)
		fov = lerpf(fov, lerpf(base_fov + 2.0, max_fov + 4.0, speed_t_hood), 1.0 - exp(-fov_damping * dt))
		return

	# 3. Determine Chase Mode Parameters (FAR vs CLOSE)
	var mode_base_dist: float = distance if current_mode == CameraMode.FORZA_FAR_CHASE else (distance * 0.78)
	var mode_max_dist: float = 8.4 if current_mode == CameraMode.FORZA_FAR_CHASE else 6.6
	var mode_height: float = height if current_mode == CameraMode.FORZA_FAR_CHASE else 1.98
	var mode_target_y: float = target_height_offset if current_mode == CameraMode.FORZA_FAR_CHASE else 1.08

	# Dynamic Speed Pull-Back (6.6m .. 8.4m range)
	var speed_norm: float = clampf(speed_mps / 58.0, 0.0, 1.0)
	var dynamic_dist: float = lerpf(maxf(mode_base_dist, 6.6 if current_mode == CameraMode.FORZA_FAR_CHASE else 5.3), mode_max_dist, speed_norm * speed_norm)

	# 4. Separate Horizontal & Vertical Pivot Damping (Absorbs Curbs & Elevation Drops Smoothly)
	var alpha_horiz: float = 1.0 - exp(-horizontal_damping * dt)
	var alpha_vert: float = 1.0 - exp(-vertical_pitch_damping * dt)

	_smoothed_pivot_pos.x = lerpf(_smoothed_pivot_pos.x, car_pos.x, alpha_horiz)
	_smoothed_pivot_pos.z = lerpf(_smoothed_pivot_pos.z, car_pos.z, alpha_horiz)
	_smoothed_pivot_pos.y = lerpf(_smoothed_pivot_pos.y, car_pos.y, alpha_vert)

	# 5. Compute Horizon-Aligned Vehicle Heading & Velocity Slip Blending
	var flat_car_fwd: Vector3 = Vector3(car_fwd.x, 0.0, car_fwd.z).normalized()
	if flat_car_fwd.length_squared() < 0.001:
		flat_car_fwd = _smoothed_yaw_dir

	var desired_yaw_dir: Vector3 = flat_car_fwd
	var flat_vel: Vector3 = Vector3(lin_vel.x, 0.0, lin_vel.z)

	if speed_mps > 3.5 and not is_reversing:
		var flat_vel_dir: Vector3 = flat_vel.normalized()
		# Blend between car nose and actual velocity vector so camera orbits smoothly outside the drift
		var slip_angle: float = flat_car_fwd.signed_angle_to(flat_vel_dir, Vector3.UP)
		var clamped_slip: float = clampf(slip_angle, -deg_to_rad(max_drift_yaw_deg), deg_to_rad(max_drift_yaw_deg))
		var drift_blend: float = clampf((speed_mps - 3.5) / 14.0, 0.0, 0.68)
		desired_yaw_dir = flat_car_fwd.rotated(Vector3.UP, clamped_slip * drift_blend).normalized()
	elif is_reversing:
		# Keep chase camera stable behind the car or gently angled during reverse maneuvers
		desired_yaw_dir = flat_car_fwd

	var alpha_yaw: float = 1.0 - exp(-rotation_yaw_damping * dt)
	_smoothed_yaw_dir = _smoothed_yaw_dir.slerp(desired_yaw_dir, alpha_yaw).normalized()

	# 6. Compute Elevated Camera Position (Keeps Tire Smoke in Lower Third)
	# Follow subtle road pitch so steep downhill passes (Akina/Irohazaka) show the road ahead clearly
	var road_pitch_drop: float = clampf(-car_fwd.y * 1.35, -0.45, 0.85)
	var final_cam_height: float = mode_height + road_pitch_drop

	var desired_cam_pos: Vector3 = _smoothed_pivot_pos - (_smoothed_yaw_dir * dynamic_dist) + Vector3(0.0, final_cam_height, 0.0)
	global_position = desired_cam_pos

	# 7. Dynamic Apex Look-Ahead Offset
	var lateral_slip_speed: float = lin_vel.dot(car_right)
	var yaw_apex_shift: float = clampf(-ang_vel.y * 0.45, -1.0, 1.0)
	var slip_apex_shift: float = clampf(lateral_slip_speed / 16.0, -1.0, 1.0)
	var combined_apex_signal: float = clampf(yaw_apex_shift * 0.6 + slip_apex_shift * 0.4, -1.0, 1.0)

	var desired_look_ahead: Vector3 = (
		(_smoothed_yaw_dir * (1.8 + speed_norm * 2.4))
		+ (car_right * combined_apex_signal * apex_look_ahead_dist)
	)

	var alpha_apex: float = 1.0 - exp(-apex_offset_damping * dt)
	_smoothed_look_ahead = _smoothed_look_ahead.lerp(desired_look_ahead, alpha_apex)

	# 8. Final Look-At Target (Vehicle Center + 1.25m Vertical Elevation + Apex Vector)
	var look_at_point: Vector3 = _smoothed_pivot_pos + Vector3(0.0, mode_target_y, 0.0) + _smoothed_look_ahead
	var look_vec: Vector3 = (look_at_point - global_position).normalized()

	if look_vec.length_squared() > 0.001:
		# Subtle horizon roll into high-G corners for Forza sense of weight
		var target_roll: float = clampf(-combined_apex_signal * deg_to_rad(2.2), -deg_to_rad(2.5), deg_to_rad(2.5))
		_smoothed_roll_rad = lerpf(_smoothed_roll_rad, target_roll, 1.0 - exp(-8.0 * dt))
		var tilted_up: Vector3 = Vector3.UP.rotated(look_vec, _smoothed_roll_rad)
		global_transform.basis = Basis.looking_at(look_vec, tilted_up).orthonormalized()

	# 9. Dynamic Speed FOV Scaling
	var target_fov: float = lerpf(base_fov, max_fov, speed_norm * 0.85)
	fov = lerpf(fov, target_fov, 1.0 - exp(-fov_damping * dt))

# ==============================================================================
# CAMERA MODE HUD INDICATOR
# ==============================================================================
func _create_camera_mode_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 90
	add_child(canvas)

	_hud_mode_label = Label.new()
	_hud_mode_label.position = Vector2(24, 48)
	_hud_mode_label.add_theme_font_size_override("font_size", 15)
	_hud_mode_label.add_theme_color_override("font_color", Color(0.0, 0.95, 1.0, 1.0))
	_hud_mode_label.modulate.a = 0.0
	canvas.add_child(_hud_mode_label)

func _show_mode_banner() -> void:
	if not is_instance_valid(_hud_mode_label):
		return
	match current_mode:
		CameraMode.FORZA_FAR_CHASE:
			_hud_mode_label.text = "CAMERA [C]: FORZA COMMANDING FAR CHASE"
		CameraMode.FORZA_CLOSE_CHASE:
			_hud_mode_label.text = "CAMERA [C]: FORZA ACTION CLOSE CHASE"
		CameraMode.HOOD_ROOF_CAM:
			_hud_mode_label.text = "CAMERA [C]: JDM TIME-ATTACK HOOD CAM"
	_hud_mode_label.modulate.a = 1.0
	_hud_fade_timer = 2.4