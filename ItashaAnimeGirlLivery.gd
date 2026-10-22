extends Node3D
class_name ItashaAnimeGirlLivery

const LIVERY_TEXTURE_PATH: String = "res://textures/itasha_rem.png"

@export var car_model_type: String = "R34" # "AE86", "FD3S", or "R34"

func _ready() -> void:
	apply_itasha_livery()

func apply_itasha_livery(target_car_type: String = "") -> void:
	if not target_car_type.is_empty():
		car_model_type = target_car_type.to_upper()
	else:
		_detect_car_model_type()
	
	# Clear any outdated overlay children
	for child in get_children():
		child.queue_free()
	
	var livery_mat := _build_livery_material()
	
	# Also apply livery material to any procedural UV livery meshes on the parent car
	_bind_to_parent_uv_panels(livery_mat)
	
	# Build non-clipping hood & side door plates
	_create_hood_livery_plate(livery_mat)
	_create_side_door_plates(livery_mat)

func _detect_car_model_type() -> void:
	var parent_node := get_parent()
	if parent_node == null:
		return
	var p_name: String = parent_node.name.to_upper()
	if "AE86" in p_name or "TRUENO" in p_name:
		car_model_type = "AE86"
	elif "FD3S" in p_name or "RX7" in p_name or "RX-7" in p_name:
		car_model_type = "FD3S"
	elif "R34" in p_name or "SKYLINE" in p_name or "GTR" in p_name:
		car_model_type = "R34"

func _build_livery_material() -> StandardMaterial3D:
	var livery_mat := StandardMaterial3D.new()
	livery_mat.albedo_texture = load(LIVERY_TEXTURE_PATH)
	livery_mat.roughness = 0.25
	livery_mat.metallic = 0.15
	livery_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	livery_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	return livery_mat

func _bind_to_parent_uv_panels(livery_mat: StandardMaterial3D) -> void:
	var parent_node := get_parent()
	if parent_node == null:
		return
	for child in parent_node.find_children("*", "MeshInstance3D", true, false):
		var m_inst := child as MeshInstance3D
		if m_inst and ("ItashaLiveryBody" in m_inst.name or "Hood" in m_inst.name or "Body" in m_inst.name):
			m_inst.material_override = livery_mat

func _create_hood_livery_plate(livery_mat: StandardMaterial3D) -> void:
	var hood_y: float = 0.76
	var hood_pitch_deg: float = -4.2
	var hood_size := Vector2(1.42, 1.18)
	var hood_z: float = 1.35
	
	if car_model_type == "AE86":
		hood_y = 0.72
		hood_pitch_deg = -3.8
		hood_size = Vector2(1.36, 1.14)
		hood_z = 1.34
	
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(livery_mat)
	
	var hw: float = hood_size.x * 0.5
	var hl: float = hood_size.y * 0.5
	
	var p1 := Vector3(-hw, 0.0, hl)
	var p2 := Vector3(hw, 0.0, hl)
	var p3 := Vector3(hw, 0.0, -hl)
	var p4 := Vector3(-hw, 0.0, -hl)
	
	# Explicit downward normal as required by architectural specification
	# (with CULL_DISABLED so both top and bottom faces render cleanly)
	st.set_normal(Vector3.DOWN)
	
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(p1)
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(p2)
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(p3)
	
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(p1)
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(p3)
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(p4)
	
	st.generate_tangents()
	
	var hood_plate := MeshInstance3D.new()
	hood_plate.name = "ItashaHoodPlate"
	hood_plate.mesh = st.commit()
	hood_plate.material_override = livery_mat
	hood_plate.position = Vector3(0.0, hood_y, hood_z)
	hood_plate.rotation_degrees = Vector3(hood_pitch_deg, 0.0, 0.0)
	add_child(hood_plate)

func _create_side_door_plates(livery_mat: StandardMaterial3D) -> void:
	var side_x_offset: float = 0.91
	var door_length: float = 1.56
	var door_height: float = 0.48
	var door_y_center: float = 0.48
	var door_z_center: float = -0.08
	
	var half_l: float = door_length * 0.5
	var half_h: float = door_height * 0.5
	
	# Left Door Plate (X = -0.91m)
	var st_left := SurfaceTool.new()
	st_left.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_left.set_material(livery_mat)
	st_left.set_normal(Vector3.LEFT)
	
	st_left.set_uv(Vector2(0.0, 0.0))
	st_left.add_vertex(Vector3(0.0, half_h, half_l))
	st_left.set_uv(Vector2(1.0, 0.0))
	st_left.add_vertex(Vector3(0.0, half_h, -half_l))
	st_left.set_uv(Vector2(1.0, 1.0))
	st_left.add_vertex(Vector3(0.0, -half_h, -half_l))
	
	st_left.set_uv(Vector2(0.0, 0.0))
	st_left.add_vertex(Vector3(0.0, half_h, half_l))
	st_left.set_uv(Vector2(1.0, 1.0))
	st_left.add_vertex(Vector3(0.0, -half_h, -half_l))
	st_left.set_uv(Vector2(0.0, 1.0))
	st_left.add_vertex(Vector3(0.0, -half_h, half_l))
	st_left.generate_tangents()
	
	var left_plate := MeshInstance3D.new()
	left_plate.name = "ItashaDoorPlateLeft"
	left_plate.mesh = st_left.commit()
	left_plate.material_override = livery_mat
	left_plate.position = Vector3(-side_x_offset, door_y_center, door_z_center)
	add_child(left_plate)
	
	# Right Door Plate (X = +0.91m)
	var st_right := SurfaceTool.new()
	st_right.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_right.set_material(livery_mat)
	st_right.set_normal(Vector3.RIGHT)
	
	st_right.set_uv(Vector2(0.0, 0.0))
	st_right.add_vertex(Vector3(0.0, half_h, -half_l))
	st_right.set_uv(Vector2(1.0, 0.0))
	st_right.add_vertex(Vector3(0.0, half_h, half_l))
	st_right.set_uv(Vector2(1.0, 1.0))
	st_right.add_vertex(Vector3(0.0, -half_h, half_l))
	
	st_right.set_uv(Vector2(0.0, 0.0))
	st_right.add_vertex(Vector3(0.0, half_h, -half_l))
	st_right.set_uv(Vector2(1.0, 1.0))
	st_right.add_vertex(Vector3(0.0, -half_h, half_l))
	st_right.set_uv(Vector2(0.0, 1.0))
	st_right.add_vertex(Vector3(0.0, -half_h, -half_l))
	st_right.generate_tangents()
	
	var right_plate := MeshInstance3D.new()
	right_plate.name = "ItashaDoorPlateRight"
	right_plate.mesh = st_right.commit()
	right_plate.material_override = livery_mat
	right_plate.position = Vector3(side_x_offset, door_y_center, door_z_center)
	add_child(right_plate)