class_name ArcadeChaseCamera3D
extends Camera3D

@export var target_vehicle: Node3D
@export var follow_distance: float = 5.6
@export var follow_height: float = 2.1
@export var look_ahead_distance: float = 4.0
@export var position_stiffness: float = 14.0
@export var rotation_stiffness: float = 12.0

var _smooth_pos: Vector3 = Vector3.ZERO
var _smooth_look: Vector3 = Vector3.ZERO
var _current_yaw: float = 0.0
var _initialized: bool = false


func _ready() -> void:
	top_level = true
	if is_instance_valid(target_vehicle):
		snap_to_target(target_vehicle)


func snap_to_target(new_target: Node3D = null) -> void:
	if is_instance_valid(new_target):
		target_vehicle = new_target
	if not is_instance_valid(target_vehicle):
		return

	var t_xform: Transform3D = target_vehicle.global_transform
	var forward_dir: Vector3 = -t_xform.basis.z.normalized()
	var up_dir: Vector3 = t_xform.basis.y.normalized()

	_current_yaw = atan2(forward_dir.x, forward_dir.z)
	_smooth_pos = t_xform.origin - (forward_dir * follow_distance) + (up_dir * follow_height)
	_smooth_look = t_xform.origin + (forward_dir * look_ahead_distance) + (up_dir * 0.65)

	global_position = _smooth_pos
	if _smooth_pos.distance_squared_to(_smooth_look) > 0.001:
		look_at(_smooth_look, Vector3.UP)

	reset_physics_interpolation()
	_initialized = true


func reset_camera_interpolation() -> void:
	snap_to_target(target_vehicle)


func _physics_process(delta: float) -> void:
	if not is_instance_valid(target_vehicle):
		return

	if not _initialized:
		snap_to_target(target_vehicle)
		return

	var t_xform: Transform3D = target_vehicle.global_transform

	# Automatically detect large teleports (>25m jump in a single frame) and snap immediately
	if _smooth_pos.distance_squared_to(t_xform.origin) > 625.0:
		snap_to_target(target_vehicle)
		return

	var forward_dir: Vector3 = -t_xform.basis.z.normalized()
	var up_dir: Vector3 = t_xform.basis.y.normalized()

	var desired_yaw: float = atan2(forward_dir.x, forward_dir.z)
	_current_yaw = lerp_angle(_current_yaw, desired_yaw, clampf(delta * rotation_stiffness, 0.0, 1.0))

	var yaw_forward := Vector3(sin(_current_yaw), forward_dir.y, cos(_current_yaw)).normalized()
	var ideal_pos: Vector3 = t_xform.origin - (yaw_forward * follow_distance) + (up_dir * follow_height)
	var ideal_look: Vector3 = t_xform.origin + (forward_dir * look_ahead_distance) + (up_dir * 0.65)

	_smooth_pos = _smooth_pos.lerp(ideal_pos, clampf(delta * position_stiffness, 0.0, 1.0))
	_smooth_look = _smooth_look.lerp(ideal_look, clampf(delta * (position_stiffness * 1.25), 0.0, 1.0))

	global_position = _smooth_pos
	if global_position.distance_squared_to(_smooth_look) > 0.001:
		look_at(_smooth_look, Vector3.UP)