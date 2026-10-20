class_name TrackArena
extends Node3D
## Procedural high-speed test circuit.
##
## The layout is a closed Catmull-Rom loop through [member control_points].  Every
## sample produces an orthonormal frame; corners bank automatically from the
## curvature of the spline.  Road, curbs and barriers are generated as separate
## [ArrayMesh] surfaces, each with a matching trimesh collider, and the whole
## asphalt is shaded with a runtime-built PBR material (grain, roughness variation
## and a clearcoat sheen for the damp-patch look).
##
## Everything is code driven: no imported textures, no .blend files, no hand placed
## geometry.  Press F5 and drive.

class TrackPath:
	var position := PackedVector3Array()
	var forward := PackedVector3Array()
	var right := PackedVector3Array()
	var up := PackedVector3Array()
	var distance := PackedFloat32Array()
	var total_length: float = 0.0

	func size() -> int:
		return position.size()

@export_group("Layout")
## Closed loop control points.  Y is elevation, the loop is duplicated implicitly.
@export var control_points: Array[Vector3] = [
	Vector3(-140.0, 1.2, 132.0),
	Vector3(-40.0, 1.5, 175.0),
	Vector3(60.0, 1.6, 165.0),
	Vector3(140.0, 1.4, 120.0),
	Vector3(200.0, 1.8, 50.0),
	Vector3(210.0, 2.4, -35.0),
	Vector3(165.0, 2.9, -110.0),
	Vector3(85.0, 3.2, -105.0),
	Vector3(40.0, 3.4, -145.0),
	Vector3(-30.0, 3.5, -160.0),
	Vector3(-120.0, 3.2, -135.0),
	Vector3(-190.0, 2.6, -65.0),
	Vector3(-205.0, 1.9, 25.0),
	Vector3(-185.0, 1.3, 95.0),
]
@export var track_width: float = 18.0
@export var curb_width: float = 1.2
@export var wall_height: float = 0.9
@export var wall_thickness: float = 0.35
## Spline samples per control point segment.  40 gives ~2.4 m spacing on this loop.
@export var steps_per_segment: int = 40
@export var max_bank_degrees: float = 9.0
## Banking angle in radians per radian of smoothed turn.
@export var bank_gain: float = 1.35
@export var ground_size: float = 1600.0

@export_group("Surface")
## World size in metres covered by one texture tile.
@export var texture_tile: float = 4.0
@export var asphalt_roughness: float = 0.38
@export_range(0.0, 1.0, 0.01) var wet_clearcoat: float = 0.45

@export_group("Gameplay")
@export var spawn_vehicle_enabled: bool = true
@export var vehicle_scene: PackedScene = preload("res://Vehicle.tscn")

var _start_transform: Transform3D = Transform3D.IDENTITY
var _vehicle: ArcadeSimVehicle = null
var _hud_label: Label = null
var _generated: Node3D = null

func _ready() -> void:
	_build_track()
	if spawn_vehicle_enabled:
		_spawn_vehicle()
	_build_hud()

func _process(_delta: float) -> void:
	if _hud_label == null or _vehicle == null or not is_instance_valid(_vehicle):
		return
	var gear_text := "R" if _vehicle.is_reversing else str(_vehicle.gear_number)
	_hud_label.text = "%d km/h\n%s  -  %d rpm" % [
		int(round(_vehicle.speed_kmh)),
		gear_text,
		int(_vehicle.engine_rpm),
	]

# ----------------------------------------------------------------------------- path
func _catmull_rom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (p2 - p0) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3
	)

func _sample_path() -> TrackPath:
	var path := TrackPath.new()
	var points := control_points
	var count := points.size()
	if count < 4:
		push_warning("TrackArena needs at least 4 control points.")
		return path

	var steps := maxi(steps_per_segment, 4)
	var raw := PackedVector3Array()
	for i in count:
		var p0 := points[(i - 1 + count) % count]
		var p1 := points[i]
		var p2 := points[(i + 1) % count]
		var p3 := points[(i + 2) % count]
		for s in steps:
			raw.append(_catmull_rom(p0, p1, p2, p3, float(s) / float(steps)))

	var sample_count := raw.size()
	for i in sample_count:
		var prev := raw[(i - 1 + sample_count) % sample_count]
		var next := raw[(i + 1) % sample_count]
		var tangent := next - prev
		if tangent.length_squared() < 0.000001:
			tangent = Vector3.FORWARD
		path.position.append(raw[i])
		path.forward.append(tangent.normalized())

	path.distance.resize(sample_count)
	var accumulated := 0.0
	for i in sample_count:
		path.distance[i] = accumulated
		accumulated += path.position[i].distance_to(path.position[(i + 1) % sample_count])
	path.total_length = accumulated

	# Signed curvature (left turns positive) smoothed over a wide window so the
	# banking ramps in and out instead of stepping at every sample.
	var turn := PackedFloat32Array()
	turn.resize(sample_count)
	for i in sample_count:
		var before := path.forward[(i - 1 + sample_count) % sample_count]
		var after := path.forward[(i + 1) % sample_count]
		turn[i] = before.signed_angle_to(after, Vector3.UP)

	var smoothing := 6
	var smoothed := PackedFloat32Array()
	smoothed.resize(sample_count)
	for i in sample_count:
		var sum := 0.0
		for k in range(-smoothing, smoothing + 1):
			sum += turn[(i + k + sample_count) % sample_count]
		smoothed[i] = sum / float(smoothing * 2 + 1)

	var max_bank := deg_to_rad(max_bank_degrees)
	for i in sample_count:
		var forward := path.forward[i]
		var right := forward.cross(Vector3.UP)
		if right.length_squared() < 0.000001:
			right = Vector3.RIGHT
		right = right.normalized()
		var up := right.cross(forward).normalized()

		var bank := clampf(smoothed[i] * bank_gain, -max_bank, max_bank)
		var banked_right := right * cos(bank) + up * sin(bank)
		var banked_up := up * cos(bank) - right * sin(bank)
		path.right.append(banked_right.normalized())
		path.up.append(banked_up.normalized())

	return path

# ----------------------------------------------------------------------------- build
func _build_track() -> void:
	var path := _sample_path()
	if path.size() < 4:
		return

	_start_transform = Transform3D(
		Basis.looking_at(path.forward[0], path.up[0]),
		path.position[0] + path.up[0] * 0.70
	)

	_generated = Node3D.new()
	_generated.name = "GeneratedTrack"
	add_child(_generated)

	var road := _build_road_mesh(path)
	var curbs := _build_curb_mesh(path)
	var walls := _build_wall_mesh(path)

	_add_mesh_instance(_generated, "Asphalt", road, _asphalt_material())
	_add_mesh_instance(_generated, "Curbs", curbs, _curb_material())
	_add_mesh_instance(_generated, "Barriers", walls, _barrier_material())

	_add_collision(_generated, road, "RoadCollision", 0.9)
	_add_collision(_generated, curbs, "CurbCollision", 0.8)
	_add_collision(_generated, walls, "BarrierCollision", 0.3)

	_build_ground()

func _build_road_mesh(path: TrackPath) -> ArrayMesh:
	var count := path.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := track_width * 0.5

	for i in count:
		var origin := path.position[i]
		var right := path.right[i]
		var up := path.up[i]
		var v := path.distance[i] / texture_tile
		for side in 2:
			var sign_side := -1.0 if side == 0 else 1.0
			st.set_normal(up)
			st.set_tangent(Plane(right.x, right.y, right.z, 1.0))
			st.set_uv(Vector2(0.0 if side == 0 else track_width / texture_tile, v))
			st.add_vertex(origin + right * (half * sign_side))

	for i in count:
		var next := (i + 1) % count
		var a := i * 2
		var b := a + 1
		var c := next * 2
		var d := c + 1
		st.add_index(a)
		st.add_index(b)
		st.add_index(c)
		st.add_index(b)
		st.add_index(d)
		st.add_index(c)

	return st.commit()

func _build_curb_mesh(path: TrackPath) -> ArrayMesh:
	var count := path.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := track_width * 0.5
	var lift := 0.09

	for i in count:
		var origin := path.position[i]
		var right := path.right[i]
		var up := path.up[i]
		var stripe := int(path.distance[i] / 3.0) % 2
		var color := Color(0.78, 0.06, 0.06) if stripe == 0 else Color(0.92, 0.92, 0.9)
		for side in 2:
			var sign_side := -1.0 if side == 0 else 1.0
			var inner := origin + right * (half * sign_side)
			var middle := origin + right * ((half + curb_width * 0.45) * sign_side) + up * lift
			var outer := origin + right * ((half + curb_width) * sign_side) + up * lift
			st.set_color(color)
			st.set_normal(up)
			st.set_tangent(Plane(right.x, right.y, right.z, 1.0))
			st.set_uv(Vector2.ZERO)
			st.add_vertex(inner)
			st.add_vertex(middle)
			st.add_vertex(outer)

	for i in count:
		var next := (i + 1) % count
		for side in 2:
			var b := i * 6 + side * 3
			var n := next * 6 + side * 3
			st.add_index(b)
			st.add_index(b + 1)
			st.add_index(n)
			st.add_index(b + 1)
			st.add_index(n + 1)
			st.add_index(n)
			st.add_index(b + 1)
			st.add_index(b + 2)
			st.add_index(n + 1)
			st.add_index(b + 2)
			st.add_index(n + 2)
			st.add_index(n + 1)

	return st.commit()

func _build_wall_mesh(path: TrackPath) -> ArrayMesh:
	var count := path.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var offset := track_width * 0.5 + curb_width + 0.35

	for i in count:
		var origin := path.position[i]
		var right := path.right[i]
		var up := path.up[i]
		var stripe := int(path.distance[i] / 6.0) % 2
		var color := Color(0.66, 0.08, 0.08) if stripe == 0 else Color(0.86, 0.86, 0.84)
		for side in 2:
			var sign_side := -1.0 if side == 0 else 1.0
			var inward := (-right * sign_side).normalized()
			var inner_base := origin + right * (offset * sign_side)
			var inner_top := inner_base + up * wall_height
			var outer_top := origin + right * ((offset + wall_thickness) * sign_side) + up * wall_height
			st.set_color(color)
			st.set_uv(Vector2.ZERO)
			# 4 vertices per profile so the vertical face and the cap keep a hard
			# lighting edge instead of sharing a smoothed normal.
			st.set_normal(inward)
			st.add_vertex(inner_base)
			st.add_vertex(inner_top)
			st.set_normal(up)
			st.add_vertex(inner_top)
			st.add_vertex(outer_top)

	for i in count:
		var next := (i + 1) % count
		for side in 2:
			var b := i * 8 + side * 4
			var n := next * 8 + side * 4
			st.add_index(b)
			st.add_index(b + 1)
			st.add_index(n)
			st.add_index(b + 1)
			st.add_index(n + 1)
			st.add_index(n)
			st.add_index(b + 2)
			st.add_index(b + 3)
			st.add_index(n + 2)
			st.add_index(b + 3)
			st.add_index(n + 3)
			st.add_index(n + 2)

	return st.commit()

func _add_mesh_instance(parent: Node3D, node_name: String, mesh: ArrayMesh, material: Material) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)

func _add_collision(parent: Node3D, mesh: ArrayMesh, node_name: String, friction: float) -> void:
	if mesh.get_surface_count() == 0:
		return
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = 1
	body.collision_mask = 2

	var physics := PhysicsMaterial.new()
	physics.friction = friction
	physics.bounce = 0.0
	body.physics_material_override = physics

	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var concave := mesh.create_trimesh_shape()
	# Generated strips are single sided; the car must never fall through them.
	concave.backface_collision = true
	shape.shape = concave

	body.add_child(shape)
	parent.add_child(body)

func _build_ground() -> void:
	if get_node_or_null("Ground") != null:
		return
	var plane := PlaneMesh.new()
	plane.size = Vector2(ground_size, ground_size)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.075, 0.095, 0.07)
	material.roughness = 0.95
	material.metallic = 0.0

	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = plane
	ground.material_override = material
	ground.position = Vector3(0.0, -0.02, 0.0)
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)

	var body := StaticBody3D.new()
	body.name = "GroundCollision"
	body.collision_layer = 1
	body.collision_mask = 2
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(ground_size, 1.0, ground_size)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0.0, -0.52, 0.0)
	add_child(body)

# ----------------------------------------------------------------------------- materials
func _noise_texture(frequency: float, size: int, low: Color, high: Color, as_normal: bool) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR if as_normal else FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.fractal_octaves = 4
	noise.seed = 1337

	var ramp := Gradient.new()
	ramp.set_color(0, low)
	ramp.set_color(1, high)

	var texture := NoiseTexture2D.new()
	texture.width = size
	texture.height = size
	texture.seamless = true
	texture.generate_mipmaps = true
	texture.as_normal_map = as_normal
	texture.bump_strength = 4.0
	texture.noise = noise
	texture.color_ramp = ramp
	return texture

func _asphalt_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.15, 0.155, 0.165)
	material.metallic = 0.18
	material.metallic_specular = 0.6
	material.roughness = asphalt_roughness
	material.clearcoat_enabled = true
	material.clearcoat = wet_clearcoat
	material.clearcoat_roughness = 0.14
	# Generated strips are viewed from above only, but keep both faces lit in case
	# a later version adds a jump or a tunnel section.
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	material.albedo_texture = _noise_texture(0.05, 512, Color(0.35, 0.35, 0.36), Color(0.88, 0.88, 0.88), false)
	material.roughness_texture = _noise_texture(0.012, 512, Color(0.2, 0.2, 0.2), Color(0.75, 0.75, 0.75), false)
	material.normal_enabled = true
	material.normal_texture = _noise_texture(0.28, 512, Color(0.0, 0.0, 0.0), Color(1.0, 1.0, 1.0), true)
	material.normal_scale = 0.8
	return material

func _curb_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 1.0, 1.0)
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.55
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _barrier_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 1.0, 1.0)
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.75
	material.metallic = 0.15
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

# ----------------------------------------------------------------------------- spawn
func _spawn_vehicle() -> void:
	if vehicle_scene == null:
		return
	var instance := vehicle_scene.instantiate()
	var node := instance as Node3D
	if node == null:
		push_error("TrackArena: the vehicle scene root must be a Node3D.")
		instance.free()
		return
	add_child(node)
	node.global_transform = _start_transform
	if node is ArcadeSimVehicle:
		_vehicle = node as ArcadeSimVehicle
		_vehicle.set_spawn_transform(_start_transform)

	var camera := get_node_or_null("ChaseCamera")
	if camera is ArcadeChaseCamera:
		var chase := camera as ArcadeChaseCamera
		chase.set_target(node)
		chase.snap_to_target()
		chase.make_current()

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	var label := Label.new()
	label.name = "Speedo"
	label.position = Vector2(42.0, 28.0)
	label.add_theme_font_size_override("font_size", 30)
	label.add_theme_color_override("font_color", Color(0.93, 0.97, 1.0))
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.7))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	layer.add_child(label)
	_hud_label = label

## Rebuilds the circuit from [member control_points].  Useful from a debug key.
func regenerate() -> void:
	if _generated != null and is_instance_valid(_generated):
		remove_child(_generated)
		_generated.queue_free()
	_generated = null
	_build_track()
