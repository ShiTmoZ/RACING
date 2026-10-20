class_name ArcadeChaseCamera
extends Camera3D
## Spring-damped third person chase camera for [ArcadeSimVehicle].
##
## The camera orbits behind the car's heading, blends its look direction toward
## the velocity vector in fast direction changes, widens the FOV with speed and
## smooths both position and rotation with frame-rate independent damping.
## Attach this script to a Camera3D and assign [member target].

@export var target: Node3D

@export_group("Rig")
@export var distance: float = 6.4
## Extra distance added at top speed, sold as a speed sensation.
@export var speed_distance: float = 1.9
@export var height: float = 2.05
@export var look_height: float = 1.15
@export var look_ahead: float = 7.0
## 0 = always look along the car heading, 1 = always look along the velocity.
@export_range(0.0, 1.0, 0.05) var velocity_blend: float = 0.45

@export_group("Damping")
@export var position_smoothing: float = 6.0
@export var rotation_smoothing: float = 7.0

@export_group("Field of View")
@export var base_fov: float = 62.0
@export var max_fov: float = 82.0
@export var fov_speed_reference: float = 70.0
@export var fov_smoothing: float = 3.0

var _snap: bool = true

func _ready() -> void:
	if near > 0.1:
		near = 0.1
	fov = base_fov

func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return

	var speed := _target_speed()
	var speed_ratio := clampf(speed / fov_speed_reference, 0.0, 1.0)

	var origin := target.global_transform.origin
	var back := target.global_transform.basis.z
	back.y = 0.0
	if back.length_squared() < 0.0001:
		back = Vector3.BACK
	back = back.normalized()

	var follow := back * (distance + speed_distance * speed_ratio)
	var desired_position := origin + follow + Vector3.UP * height

	var heading := -back
	var look := origin + heading * look_ahead + Vector3.UP * look_height
	var velocity_dir := _target_velocity()
	if velocity_dir.length_squared() > 9.0:
		var blend := velocity_blend * clampf((speed - 3.0) / 12.0, 0.0, 1.0)
		var velocity_look := origin + velocity_dir.normalized() * look_ahead + Vector3.UP * look_height
		look = look.lerp(velocity_look, blend)

	if _snap:
		_snap = false
		global_position = desired_position
		global_transform = Transform3D(Basis(), desired_position).looking_at(look, Vector3.UP)
	else:
		global_position = global_position.lerp(desired_position, 1.0 - exp(-position_smoothing * delta))
		var goal := Transform3D(Basis(), global_position).looking_at(look, Vector3.UP)
		global_transform = global_transform.interpolate_with(goal, 1.0 - exp(-rotation_smoothing * delta))

	var fov_goal := lerpf(base_fov, max_fov, speed_ratio)
	fov = lerpf(fov, fov_goal, 1.0 - exp(-fov_smoothing * delta))

## Glues the camera to its ideal pose on the next frame instead of easing into it.
func snap_to_target() -> void:
	_snap = true

## Assigns a new follow target and snaps to it immediately.
func set_target(node: Node3D) -> void:
	target = node
	_snap = true

func _target_speed() -> float:
	var body := target as RigidBody3D
	if body != null:
		return body.linear_velocity.length()
	return 0.0

func _target_velocity() -> Vector3:
	var body := target as RigidBody3D
	if body != null:
		return body.linear_velocity
	return Vector3.ZERO
