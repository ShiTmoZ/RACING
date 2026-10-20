class_name ArcadeSimVehicle
extends RigidBody3D
## Arcade-sim vehicle controller.
##
## Raycast suspension + per-wheel friction-circle tire model + torque-curve driven
## automatic gearbox.  The body is a plain RigidBody3D; all cornering, grip and
## suspension behaviour is produced by forces applied at the four wheel contacts,
## which keeps the car stable at 120 Hz physics without any raycast "glue".
##
## Local axes: -Z = forward, +X = right, +Y = up.

signal gear_changed(new_gear: int)

@export_group("Wheel Nodes")
## RayCast3D nodes whose origin is the suspension mount and whose ray points
## straight down along -Y.  Expected order: FL, FR, RL, RR.
@export var wheel_rays: Array[RayCast3D] = []
## Visual wheel nodes, same order as [member wheel_rays].
@export var wheel_meshes: Array[Node3D] = []
## Index into [member wheel_rays] for the two steered wheels.
@export var front_wheel_indices: Array[int] = [0, 1]
## Index into [member wheel_rays] for the driven wheels (RWD by default).
@export var driven_wheel_indices: Array[int] = [2, 3]
@export var wheel_radius: float = 0.36
## Total ray length from mount to the fully extended wheel contact.
@export var ray_length: float = 0.72

@export_group("Suspension")
@export var suspension_stiffness: float = 45000.0
@export var suspension_damping: float = 4300.0
@export var suspension_max_force: float = 45000.0
@export var anti_roll_stiffness: float = 11000.0

@export_group("Drivetrain")
@export var engine_peak_torque: float = 430.0
@export var idle_rpm: float = 950.0
@export var redline_rpm: float = 7400.0
@export var gear_ratios: Array[float] = [3.55, 2.35, 1.72, 1.30, 1.04, 0.82]
@export var final_drive: float = 3.42
@export var reverse_ratio: float = 3.10
@export var drivetrain_efficiency: float = 0.92
@export var upshift_rpm: float = 6900.0
@export var downshift_rpm: float = 2500.0
@export var shift_duration: float = 0.20
@export var reverse_torque_scale: float = 0.90
@export var max_reverse_speed: float = 18.0

@export_group("Tires")
## Peak friction coefficient of the tire model (1.0 = 1 g).
@export var tire_grip: float = 1.55
@export var rear_grip_multiplier: float = 1.0
@export var handbrake_grip_multiplier: float = 0.28
@export var rolling_resistance: float = 180.0

@export_group("Aero")
## 0.5 * air_density * Cd * frontal_area.  F = coefficient * v^2.
@export var drag_coefficient: float = 0.43
## 0.5 * air_density * Cl * frontal_area.  F = coefficient * v^2.
@export var downforce_coefficient: float = 0.95

@export_group("Steering")
@export var max_steer_angle: float = 0.62
@export var min_steer_angle: float = 0.15
@export var steer_speed_reference: float = 55.0
@export var steer_rate: float = 7.5
@export var steer_centering_rate: float = 11.0

# ----------------------------------------------------------------------------- state
var steer_angle: float = 0.0
var throttle_input: float = 0.0
var brake_input: float = 0.0
var handbrake_input: float = 0.0

var speed_kmh: float = 0.0
var forward_speed: float = 0.0
var engine_rpm: float = 0.0
var gear_number: int = 1
var is_reversing: bool = false

var _gear_index: int = 0
var _shift_timer: float = 0.0
var _engine_force: float = 0.0
var _spawn_transform: Transform3D = Transform3D.IDENTITY
var _flip_timer: float = 0.0

var _is_front: PackedByteArray = PackedByteArray()
var _is_driven: PackedByteArray = PackedByteArray()

var _wheel_spin: PackedFloat32Array = PackedFloat32Array()
var _wheel_steer: PackedFloat32Array = PackedFloat32Array()
var _wheel_compression: PackedFloat32Array = PackedFloat32Array()
var _wheel_distance: PackedFloat32Array = PackedFloat32Array()
var _wheel_force: PackedFloat32Array = PackedFloat32Array()
var _wheel_grounded: PackedByteArray = PackedByteArray()
var _wheel_contact: Array[Vector3] = []
var _wheel_normal: Array[Vector3] = []

# Telemetries exposed for audio and VFX subsystem
var tire_slip_velocities: Array[float] = [0.0, 0.0, 0.0, 0.0]
var wheel_contact_points: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var wheel_contact_normals: Array[Vector3] = [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP]
var wheel_is_grounded: Array[bool] = [false, false, false, false]

var current_gear: int:
	get:
		return -1 if is_reversing else gear_number

var gear_ratio: float:
	get:
		return reverse_ratio if is_reversing else (gear_ratios[mini(_gear_index, gear_ratios.size() - 1)] if not gear_ratios.is_empty() else 3.2)

# ----------------------------------------------------------------------------- lifecycle
func _ready() -> void:
	can_sleep = false
	contact_monitor = false
	_spawn_transform = global_transform
	_resolve_wheel_nodes()
	_build_wheel_flags()
	_allocate_wheel_state()
	gear_number = _gear_index + 1

func _physics_process(delta: float) -> void:
	if delta <= 0.0 or wheel_rays.is_empty():
		return

	_read_input()
	_update_motion_state()
	_update_steering(delta)
	_update_drivetrain(delta)
	_apply_suspension_and_tires(delta)
	_apply_aero()
	_update_wheel_visuals(delta)
	_check_recovery(delta)
	if r34_model != null:
		if "is_braking" in r34_model:
			r34_model.is_braking = (brake_input > 0.05) or (handbrake_input > 0.1)
		if "is_reversing" in r34_model:
			r34_model.is_reversing = is_reversing
		if "headlights_on" in r34_model:
			r34_model.headlights_on = true

# ----------------------------------------------------------------------------- setup
var r34_model: Node3D = null

func on_visual_chassis_rebound(model_root: Node3D, found_wheels: Array[Node3D]) -> void:
	r34_model = model_root
	wheel_meshes.clear()
	for w in found_wheels:
		if is_instance_valid(w):
			wheel_meshes.append(w)

func rebind_wheels(found_wheels: Array[Node3D]) -> void:
	wheel_meshes.clear()
	for w in found_wheels:
		if is_instance_valid(w):
			wheel_meshes.append(w)

func _resolve_wheel_nodes() -> void:
	# The scene wires these through exported node references, but the controller
	# stays usable when it is instanced from code with nothing wired at all.
	var rays_valid := not wheel_rays.is_empty()
	for ray in wheel_rays:
		if ray == null:
			rays_valid = false
	if not rays_valid:
		wheel_rays.clear()
		for child in get_children():
			if child is RayCast3D:
				wheel_rays.append(child as RayCast3D)

	r34_model = get_node_or_null("R34SkylineModeler")
	if r34_model != null and "WheelFL" in r34_model and r34_model.WheelFL != null:
		wheel_meshes = [r34_model.WheelFL, r34_model.WheelFR, r34_model.WheelRL, r34_model.WheelRR]
	else:
		var meshes_valid := not wheel_meshes.is_empty()
		for mesh in wheel_meshes:
			if mesh == null:
				meshes_valid = false
		if not meshes_valid:
			wheel_meshes.clear()
			for child in get_children():
				if child is Node3D and String(child.name).begins_with("Wheel"):
					wheel_meshes.append(child as Node3D)

func _build_wheel_flags() -> void:
	var count := wheel_rays.size()
	_is_front.resize(count)
	_is_driven.resize(count)
	for i in count:
		_is_front[i] = 1 if front_wheel_indices.has(i) else 0
		_is_driven[i] = 1 if driven_wheel_indices.has(i) else 0

func _allocate_wheel_state() -> void:
	var count := wheel_rays.size()
	_wheel_spin.resize(count)
	_wheel_steer.resize(count)
	_wheel_compression.resize(count)
	_wheel_distance.resize(count)
	_wheel_force.resize(count)
	_wheel_grounded.resize(count)
	_wheel_contact.resize(count)
	_wheel_normal.resize(count)
	for i in count:
		_wheel_distance[i] = ray_length
		if wheel_rays[i] != null:
			wheel_rays[i].exclude_parent = true
			wheel_rays[i].collision_mask = 1
			wheel_rays[i].target_position = Vector3(0.0, -ray_length, 0.0)
			wheel_rays[i].force_raycast_update()

# ----------------------------------------------------------------------------- input
func _read_input() -> void:
	throttle_input = Input.get_action_strength("accelerate")
	brake_input = Input.get_action_strength("brake")
	handbrake_input = Input.get_action_strength("handbrake")
	if Input.is_action_just_pressed("reset_vehicle"):
		respawn()

# ----------------------------------------------------------------------------- motion
func flat_forward() -> Vector3:
	var f := -global_transform.basis.z
	f.y = 0.0
	if f.length_squared() < 0.0001:
		return Vector3.FORWARD
	return f.normalized()

func _update_motion_state() -> void:
	forward_speed = linear_velocity.dot(flat_forward())
	speed_kmh = absf(forward_speed) * 3.6

func _update_steering(delta: float) -> void:
	var axis := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	var speed_ratio := clampf(absf(forward_speed) / steer_speed_reference, 0.0, 1.0)
	var limit := lerpf(max_steer_angle, min_steer_angle, speed_ratio)
	var goal := axis * limit
	var rate := steer_rate if absf(goal) > absf(steer_angle) else steer_centering_rate
	steer_angle = move_toward(steer_angle, goal, rate * delta)
	for i in _wheel_steer.size():
		_wheel_steer[i] = steer_angle if _is_front[i] == 1 else 0.0

# ----------------------------------------------------------------------------- drivetrain
func _engine_torque(rpm: float) -> float:
	# Broad, naturally aspirated style curve: strong from idle, peak around 70%
	# of redline, gentle fall-off afterwards.
	var x := clampf(rpm / redline_rpm, 0.0, 1.0)
	var curve := 0.62 + 0.86 * x - 0.60 * x * x
	return engine_peak_torque * curve

func _update_drivetrain(delta: float) -> void:
	var wheel_rpm := absf(forward_speed) / wheel_radius * (60.0 / TAU)

	if forward_speed < 0.8 and brake_input > 0.2 and throttle_input < 0.1:
		is_reversing = true
	if throttle_input > 0.2 and forward_speed < 4.0:
		is_reversing = false

	var ratio := reverse_ratio if is_reversing else gear_ratios[_gear_index]
	engine_rpm = clampf(wheel_rpm * ratio * final_drive, idle_rpm, redline_rpm)

	if _shift_timer > 0.0:
		_shift_timer = maxf(_shift_timer - delta, 0.0)

	if not is_reversing and _shift_timer <= 0.0 and absf(forward_speed) > 2.0:
		if engine_rpm > upshift_rpm and _gear_index < gear_ratios.size() - 1:
			_gear_index += 1
			_shift_timer = shift_duration
			gear_number = _gear_index + 1
			gear_changed.emit(gear_number)
		elif engine_rpm < downshift_rpm and _gear_index > 0:
			_gear_index -= 1
			_shift_timer = shift_duration * 0.7
			gear_number = _gear_index + 1
			gear_changed.emit(gear_number)

	var drive_input := brake_input if is_reversing else throttle_input
	var torque := _engine_torque(engine_rpm) * drive_input
	var force := torque * ratio * final_drive * drivetrain_efficiency / wheel_radius

	if is_reversing:
		force = -absf(force) * reverse_torque_scale
		if forward_speed < -max_reverse_speed:
			force = 0.0
	if _shift_timer > 0.0:
		force = 0.0
	_engine_force = force

# ----------------------------------------------------------------------------- tires
func _point_velocity(point: Vector3) -> Vector3:
	return linear_velocity + angular_velocity.cross(point - global_position)

func _apply_suspension_and_tires(delta: float) -> void:
	var count := wheel_rays.size()
	var forward := flat_forward()
	var body_up := global_transform.basis.y.normalized()
	var corner_mass := mass / float(count)
	var inv_delta := 1.0 / delta

	var driven_total := 0
	for i in count:
		if _is_driven[i] == 1:
			driven_total += 1
	var drive_per_wheel := _engine_force / float(driven_total) if driven_total > 0 else 0.0

	for i in count:
		_wheel_grounded[i] = 0
		_wheel_force[i] = 0.0
		_wheel_compression[i] = 0.0
		_wheel_distance[i] = ray_length
		var ray := wheel_rays[i]
		if ray == null or not ray.is_colliding():
			continue

		var point := ray.get_collision_point()
		var normal := ray.get_collision_normal()
		var distance := ray.global_position.distance_to(point)
		_wheel_distance[i] = distance
		if distance > ray_length:
			continue

		var compression := clampf(ray_length - distance, 0.0, ray_length - wheel_radius)
		var velocity := _point_velocity(point)
		var down := -ray.global_transform.basis.y.normalized()
		var compression_speed := velocity.dot(down)
		var spring := compression * suspension_stiffness + compression_speed * suspension_damping
		spring = clampf(spring, 0.0, suspension_max_force)

		_wheel_compression[i] = compression
		_wheel_force[i] = spring
		_wheel_grounded[i] = 1
		_wheel_contact[i] = point
		_wheel_normal[i] = normal
		apply_force(body_up * spring, point - global_position)

	_apply_anti_roll(body_up, count)

	for i in count:
		if _wheel_grounded[i] == 0:
			if i < tire_slip_velocities.size():
				wheel_is_grounded[i] = false
				tire_slip_velocities[i] = 0.0
			continue

		var point := _wheel_contact[i]
		var velocity := _point_velocity(point)
		var steer := _wheel_steer[i]
		var wheel_forward := forward.rotated(Vector3.UP, steer).normalized()
		var wheel_right := wheel_forward.cross(Vector3.UP).normalized()

		var grip := tire_grip
		var locked := handbrake_input > 0.1 and _is_front[i] == 0
		if _is_front[i] == 0:
			grip *= rear_grip_multiplier
			if locked:
				grip *= handbrake_grip_multiplier

		var load := maxf(_wheel_force[i], 0.0)
		var lateral_speed := velocity.dot(wheel_right)
		var lateral_force := clampf(-lateral_speed * corner_mass * inv_delta * 0.95, -grip * load, grip * load)
		apply_force(wheel_right * lateral_force, point - global_position)

		var longitudinal_speed := velocity.dot(wheel_forward)
		var longitudinal := 0.0
		if _is_driven[i] == 1:
			longitudinal += drive_per_wheel

		var brake_amount := brake_input
		if locked:
			brake_amount = 1.0
		if brake_amount > 0.0:
			var brake_cap := tire_grip * load * brake_amount
			longitudinal += clampf(-longitudinal_speed * corner_mass * inv_delta, -brake_cap, brake_cap)

		if absf(longitudinal_speed) > 0.05:
			longitudinal -= signf(longitudinal_speed) * minf(rolling_resistance, absf(longitudinal_speed) * corner_mass * inv_delta)

		var longitudinal_cap := tire_grip * 1.35 * load
		longitudinal = clampf(longitudinal, -longitudinal_cap, longitudinal_cap)
		apply_force(wheel_forward * longitudinal, point - global_position)

		if i < tire_slip_velocities.size():
			wheel_is_grounded[i] = true
			wheel_contact_points[i] = point
			wheel_contact_normals[i] = _wheel_normal[i]
			var slip := absf(lateral_speed)
			if locked:
				slip += absf(longitudinal_speed) * 0.85
			elif _is_driven[i] == 1 and throttle_input > 0.8 and speed_kmh < 30.0:
				slip += (engine_rpm / redline_rpm) * 12.0
			tire_slip_velocities[i] = slip

func _apply_anti_roll(body_up: Vector3, count: int) -> void:
	var pairs := [[0, 1], [2, 3]]
	for pair in pairs:
		var left: int = pair[0]
		var right: int = pair[1]
		if left >= count or right >= count:
			continue
		if _wheel_grounded[left] == 0 and _wheel_grounded[right] == 0:
			continue
		var difference := _wheel_compression[left] - _wheel_compression[right]
		var force := clampf(difference * anti_roll_stiffness, -suspension_max_force, suspension_max_force)
		if _wheel_grounded[left] == 1:
			apply_force(body_up * force, _wheel_contact[left] - global_position)
			_wheel_force[left] = maxf(_wheel_force[left] + force, 0.0)
		if _wheel_grounded[right] == 1:
			apply_force(body_up * -force, _wheel_contact[right] - global_position)
			_wheel_force[right] = maxf(_wheel_force[right] - force, 0.0)

func _apply_aero() -> void:
	var velocity := linear_velocity
	var speed := velocity.length()
	if speed < 0.5:
		return
	var up := global_transform.basis.y.normalized()
	apply_central_force(-velocity / speed * drag_coefficient * speed * speed)
	apply_central_force(-up * downforce_coefficient * speed * speed)

# ----------------------------------------------------------------------------- visuals
func _update_wheel_visuals(delta: float) -> void:
	var count := mini(wheel_meshes.size(), _wheel_distance.size())
	for i in count:
		var mesh := wheel_meshes[i]
		var ray := wheel_rays[i]
		if mesh == null or ray == null:
			continue

		var wheel_y := -(ray_length - wheel_radius)
		if _wheel_grounded[i] == 1:
			wheel_y = -(_wheel_distance[i] - wheel_radius)
			var wheel_forward := (-ray.global_transform.basis.z).rotated(Vector3.UP, _wheel_steer[i]).normalized()
			var long_speed := _point_velocity(_wheel_contact[i]).dot(wheel_forward)
			if not (handbrake_input > 0.1 and _is_front[i] == 0):
				_wheel_spin[i] -= long_speed / wheel_radius * delta
		else:
			_wheel_spin[i] -= forward_speed / wheel_radius * delta

		if _wheel_spin[i] > TAU or _wheel_spin[i] < -TAU:
			_wheel_spin[i] = fposmod(_wheel_spin[i], TAU)

		var steer_basis := Basis(Vector3.UP, _wheel_steer[i])
		var spin_basis := Basis(Vector3.RIGHT, _wheel_spin[i])
		var wheel_basis: Basis
		if r34_model != null:
			wheel_basis = steer_basis * spin_basis
		else:
			var tip_basis := Basis(Vector3.BACK, PI * 0.5)
			wheel_basis = steer_basis * spin_basis * tip_basis
		mesh.transform = Transform3D(wheel_basis, Vector3(ray.position.x, ray.position.y + wheel_y, ray.position.z))

# ----------------------------------------------------------------------------- recovery
func _check_recovery(delta: float) -> void:
	if global_position.y < -30.0:
		respawn()
		return
	var upright := global_transform.basis.y.dot(Vector3.UP)
	if upright < 0.25 and linear_velocity.length() < 3.0:
		_flip_timer += delta
	else:
		_flip_timer = 0.0
	if _flip_timer > 2.0:
		respawn()

## Teleports the car back to the pose it was spawned with and clears all motion.
func respawn() -> void:
	respawn_at(_spawn_transform)

## Teleports the car to [param target] and clears all motion.
func respawn_at(target: Transform3D) -> void:
	global_transform = target
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	steer_angle = 0.0
	throttle_input = 0.0
	brake_input = 0.0
	handbrake_input = 0.0
	_gear_index = 0
	gear_number = 1
	engine_rpm = idle_rpm
	_shift_timer = 0.0
	_flip_timer = 0.0
	_engine_force = 0.0
	is_reversing = false
	_wheel_spin.fill(0.0)

## Marks [param target] as the pose [method respawn] returns to.
func set_spawn_transform(target: Transform3D) -> void:
	_spawn_transform = target
