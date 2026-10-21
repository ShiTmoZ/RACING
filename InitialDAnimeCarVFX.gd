class_name InitialDAnimeCarVFX
extends Node3D

## InitialDAnimeCarVFX.gd
## Authentic Initial D / Redline 3D Anime Vehicle Visual Effects System for Godot 4.3 Forward+
## Zero external assets required. All meshes, shaders, ribbons, and decals are generated procedurally.

# ==============================================================================
# EXPORTED CONFIGURATION & TARGET BINDING
# ==============================================================================
@export_group("Vehicle Binding")
@export var target_vehicle: Node3D:
	set(value):
		target_vehicle = value
		if is_inside_tree() and target_vehicle != null:
			_bind_to_vehicle(target_vehicle)

@export var is_ae86_tofu_car: bool = true
@export var auto_apply_toon_shader: bool = true

@export_group("1. Taillight Neon Ribbons")
@export var taillight_left_offset: Vector3 = Vector3(-0.62, 0.72, 1.95)
@export var taillight_right_offset: Vector3 = Vector3(0.62, 0.72, 1.95)
@export var taillight_ribbon_width: float = 0.22
@export var taillight_min_lifetime: float = 0.45
@export var taillight_max_lifetime: float = 0.85

@export_group("2. Cel-Shaded Tire Smoke")
@export var rear_left_wheel_offset: Vector3 = Vector3(-0.74, 0.15, 1.32)
@export var rear_right_wheel_offset: Vector3 = Vector3(0.74, 0.15, 1.32)
@export var max_smoke_puffs: int = 96

@export_group("3. Exhaust Backfire Cones")
@export var exhaust_offset: Vector3 = Vector3(0.46, 0.26, 2.08)
@export var dual_exhaust: bool = false
@export var exhaust_secondary_offset: Vector3 = Vector3(-0.46, 0.26, 2.08)

@export_group("4. Gutter & Guardrail Sparks")
@export var front_left_wheel_offset: Vector3 = Vector3(-0.74, 0.12, -1.35)
@export var front_right_wheel_offset: Vector3 = Vector3(0.74, 0.12, -1.35)
@export var max_manga_sparks: int = 80

@export_group("5. Aero Slipstream Ribbons")
@export var aero_left_mirror_offset: Vector3 = Vector3(-0.86, 0.96, -0.35)
@export var aero_right_mirror_offset: Vector3 = Vector3(0.86, 0.96, -0.35)
@export var aero_left_wing_offset: Vector3 = Vector3(-0.68, 1.08, 1.88)
@export var aero_right_wing_offset: Vector3 = Vector3(0.68, 1.08, 1.88)

# ==============================================================================
# INTERNAL TELEMETRY STATE
# ==============================================================================
var _is_headless: bool = false
var _last_global_pos: Vector3 = Vector3.ZERO
var _velocity_world: Vector3 = Vector3.ZERO
var _speed_kmh: float = 0.0
var _slip_angle_deg: float = 0.0
var _rpm: float = 1000.0
var _prev_rpm: float = 1000.0
var _throttle: float = 0.0
var _prev_throttle: float = 0.0
var _brake: float = 0.0
var _steering: float = 0.0
var _in_gutter: bool = false
var _scraping_guardrail: bool = false
var _rear_wheel_spin_factor: float = 0.0
var _time_accum: float = 0.0

# ==============================================================================
# 1. TAILLIGHT RIBBON RING BUFFERS
# ==============================================================================
const MAX_RIBBON_POINTS: int = 96

class RibbonBuffer:
	var points_pos: PackedVector3Array = PackedVector3Array()
	var points_right: PackedVector3Array = PackedVector3Array()
	var points_age: PackedFloat32Array = PackedFloat32Array()
	var points_max_life: PackedFloat32Array = PackedFloat32Array()
	var head: int = 0
	var count: int = 0
	var mesh: ImmediateMesh
	var mesh_instance: MeshInstance3D
	var last_emit_pos: Vector3 = Vector3.ZERO
	var initialized: bool = false

	func _init(capacity: int) -> void:
		points_pos.resize(capacity)
		points_right.resize(capacity)
		points_age.resize(capacity)
		points_max_life.resize(capacity)

	func push_sample(pos: Vector3, right_vec: Vector3, life: float) -> void:
		var cap: int = points_pos.size()
		points_pos[head] = pos
		points_right[head] = right_vec
		points_age[head] = 0.0
		points_max_life[head] = life
		head = (head + 1) % cap
		if count < cap:
			count += 1
		last_emit_pos = pos
		initialized = true

	func update_ages(dt: float) -> void:
		if count == 0:
			return
		var cap: int = points_pos.size()
		var active_count: int = 0
		for i in range(count):
			var idx: int = (head - 1 - i + cap) % cap
			points_age[idx] += dt
			if points_age[idx] < points_max_life[idx]:
				active_count = i + 1
		count = active_count

var _taillight_ribbons: Array[RibbonBuffer] = []
var _taillight_material: ShaderMaterial

# ==============================================================================
# 2. CEL-SHADED ANIME TIRE SMOKE POOL (MULTIMESH)
# ==============================================================================
class SmokeParticle:
	var active: bool = false
	var pos: Vector3 = Vector3.ZERO
	var vel: Vector3 = Vector3.ZERO
	var rot_axis: Vector3 = Vector3.UP
	var rot_angle: float = 0.0
	var rot_speed: float = 0.0
	var age: float = 0.0
	var max_life: float = 1.0
	var base_scale: float = 1.0

var _smoke_pool: Array[SmokeParticle] = []
var _smoke_multimesh: MultiMesh
var _smoke_mmi: MultiMeshInstance3D
var _smoke_emit_accum: float = 0.0
var _smoke_cursor: int = 0

# ==============================================================================
# 3. EXHAUST BACKFIRE & SPARK CONES
# ==============================================================================
var _backfire_root_primary: Node3D
var _backfire_root_secondary: Node3D
var _backfire_light: OmniLight3D
var _backfire_timer: float = 0.0
var _backfire_cooldown: float = 0.0
var _backfire_shader_mat: ShaderMaterial

# ==============================================================================
# 4. GUTTER HOOK & GUARDRAIL MANGA SPARKS
# ==============================================================================
class MangaSpark:
	var active: bool = false
	var pos: Vector3 = Vector3.ZERO
	var vel: Vector3 = Vector3.ZERO
	var age: float = 0.0
	var max_life: float = 0.35
	var scale: float = 1.0
	var spin_angle: float = 0.0
	var spin_speed: float = 18.0

var _spark_pool: Array[MangaSpark] = []
var _spark_multimesh: MultiMesh
var _spark_mmi: MultiMeshInstance3D
var _spark_cursor: int = 0
var _spark_emit_accum: float = 0.0

# ==============================================================================
# 5. AERODYNAMIC AIR SLIPSTREAM RIBBONS
# ==============================================================================
const MAX_AERO_POINTS: int = 48
var _aero_ribbons: Array[RibbonBuffer] = []
var _aero_material: ShaderMaterial

# ==============================================================================
# 6. ANIME TOON SHADING & PROCEDURAL TOFU DECAL
# ==============================================================================
var _toon_overlay_material: ShaderMaterial
var _outline_pass_material: ShaderMaterial
var _tofu_viewport: SubViewport
var _tofu_decal_mesh: MeshInstance3D
var _bound_meshes: Array[MeshInstance3D] = []

# ==============================================================================
# LIFECYCLE INITIALIZATION
# ==============================================================================
func _ready() -> void:
	_is_headless = (DisplayServer.get_name() == "headless")
	top_level = false

	_build_taillight_ribbon_system()
	_build_cel_smoke_system()
	_build_exhaust_backfire_system()
	_build_manga_spark_system()
	_build_aero_ribbon_system()
	_build_anime_vehicle_materials()

	if target_vehicle == null:
		var p: Node = get_parent()
		if p is Node3D:
			target_vehicle = p

	if target_vehicle != null:
		_bind_to_vehicle(target_vehicle)
		_last_global_pos = target_vehicle.global_position
	else:
		_last_global_pos = global_position

func _bind_to_vehicle(vehicle: Node3D) -> void:
	if vehicle == null:
		return

	# Auto-detect vehicle archetype from name if possible
	var vname: String = vehicle.name.to_upper()
	if "R34" in vname or "SKYLINE" in vname:
		is_ae86_tofu_car = false
		dual_exhaust = false
		exhaust_offset = Vector3(-0.52, 0.25, 2.15)
	elif "RX7" in vname or "FD3S" in vname or "FC3S" in vname:
		is_ae86_tofu_car = false
		dual_exhaust = true
	elif "AE86" in vname or "TRUENO" in vname or "HACHIROKU" in vname:
		is_ae86_tofu_car = true

	if auto_apply_toon_shader:
		_apply_toon_shader_recursively(vehicle)

	if is_ae86_tofu_car:
		_attach_fujiwara_tofu_decal(vehicle)
	elif _tofu_decal_mesh != null:
		_tofu_decal_mesh.visible = false

func _physics_process(delta: float) -> void:
	if delta <= 0.00001:
		return

	_time_accum += delta
	var ref_node: Node3D = target_vehicle if is_instance_valid(target_vehicle) else self

	_sample_vehicle_telemetry(ref_node, delta)
	_update_taillight_ribbons(ref_node, delta)
	_update_cel_smoke(ref_node, delta)
	_update_exhaust_backfire(ref_node, delta)
	_update_manga_sparks(ref_node, delta)
	_update_aero_ribbons(ref_node, delta)

# ==============================================================================
# TELEMETRY SAMPLING & GUTTER DETECTION
# ==============================================================================
func _sample_vehicle_telemetry(ref_node: Node3D, dt: float) -> void:
	var cur_pos: Vector3 = ref_node.global_position
	var raw_vel: Vector3 = (cur_pos - _last_global_pos) / maxf(dt, 0.0001)
	_last_global_pos = cur_pos

	# Read explicit velocity if vehicle exposes it
	if "linear_velocity" in ref_node:
		var lv: Variant = ref_node.get("linear_velocity")
		if lv is Vector3:
			raw_vel = lv
	elif "velocity" in ref_node:
		var v: Variant = ref_node.get("velocity")
		if v is Vector3:
			raw_vel = v

	_velocity_world = _velocity_world.lerp(raw_vel, clampf(dt * 18.0, 0.0, 1.0))

	var speed_ms: float = _velocity_world.length()
	_speed_kmh = speed_ms * 3.6
	if "speed_kmh" in ref_node:
		var sk: Variant = ref_node.get("speed_kmh")
		if sk is float or sk is int:
			_speed_kmh = float(sk)

	# Compute slip angle (Beta) in degrees
	var forward_dir: Vector3 = -ref_node.global_transform.basis.z
	forward_dir.y = 0.0
	if forward_dir.length_squared() > 0.0001:
		forward_dir = forward_dir.normalized()
	else:
		forward_dir = Vector3.FORWARD

	var horiz_vel: Vector3 = Vector3(_velocity_world.x, 0.0, _velocity_world.z)
	if horiz_vel.length() > 1.2:
		var vel_dir: Vector3 = horiz_vel.normalized()
		var unsigned_angle: float = rad_to_deg(acos(clampf(forward_dir.dot(vel_dir), -1.0, 1.0)))
		var cross_y: float = forward_dir.cross(vel_dir).y
		_slip_angle_deg = unsigned_angle * signf(cross_y)
	else:
		_slip_angle_deg = 0.0

	if "slip_angle_deg" in ref_node:
		var sa: Variant = ref_node.get("slip_angle_deg")
		if sa is float or sa is int:
			_slip_angle_deg = float(sa)
	elif "slip_angle" in ref_node:
		var sa_rad: Variant = ref_node.get("slip_angle")
		if sa_rad is float or sa_rad is int:
			var val: float = float(sa_rad)
			# Handle radians vs degrees smoothly
			_slip_angle_deg = rad_to_deg(val) if absf(val) <= PI else val

	# Engine RPM, Throttle, Brake, Steering
	_prev_rpm = _rpm
	_prev_throttle = _throttle

	if "rpm" in ref_node:
		_rpm = float(ref_node.get("rpm"))
	elif "engine_rpm" in ref_node:
		_rpm = float(ref_node.get("engine_rpm"))
	else:
		# Synthesize realistic high-revving 4A-GE RPM profile from speed & slip
		var gear_ratio_mod: float = fmod(_speed_kmh, 38.0) / 38.0
		_rpm = lerpf(2400.0, 8200.0, clampf(gear_ratio_mod + absf(_slip_angle_deg) * 0.012, 0.0, 1.0))

	if "throttle" in ref_node:
		_throttle = float(ref_node.get("throttle"))
	elif "throttle_input" in ref_node:
		_throttle = float(ref_node.get("throttle_input"))
	else:
		var accel: float = (_velocity_world.dot(forward_dir) - speed_ms * 0.95)
		_throttle = 1.0 if accel >= -0.2 and _speed_kmh > 5.0 else 0.0

	if "brake" in ref_node:
		_brake = float(ref_node.get("brake"))
	elif "brake_input" in ref_node:
		_brake = float(ref_node.get("brake_input"))
	else:
		_brake = 0.0

	if "steering" in ref_node:
		_steering = float(ref_node.get("steering"))
	elif "steer_angle" in ref_node:
		_steering = float(ref_node.get("steer_angle"))
	else:
		_steering = clampf(_slip_angle_deg / 30.0, -1.0, 1.0)

	# Rear wheel angular velocity / spin factor
	if "rear_wheel_omega" in ref_node:
		var omega: float = float(ref_node.get("rear_wheel_omega"))
		_rear_wheel_spin_factor = clampf(absf(omega) / 85.0, 0.0, 2.5)
	else:
		_rear_wheel_spin_factor = clampf((_speed_kmh / 90.0) + (absf(_slip_angle_deg) / 22.0), 0.0, 2.5)

	# Gutter Hook & Guardrail detection
	_in_gutter = false
	_scraping_guardrail = false

	if "in_gutter" in ref_node:
		_in_gutter = bool(ref_node.get("in_gutter"))
	if "is_gutter_hooked" in ref_node:
		_in_gutter = _in_gutter or bool(ref_node.get("is_gutter_hooked"))
	if "scraping_guardrail" in ref_node:
		_scraping_guardrail = bool(ref_node.get("scraping_guardrail"))
	if "distance_to_road_edge" in ref_node:
		var dist_edge: float = float(ref_node.get("distance_to_road_edge"))
		if dist_edge < 1.8 and _speed_kmh > 35.0:
			_in_gutter = true

	# Physics space raycast probe for curb/gutter height step or guardrail proximity
	if not _in_gutter and not _scraping_guardrail and _speed_kmh > 40.0 and is_inside_tree():
		var world_3d: World3D = get_world_3d()
		if world_3d != null and world_3d.direct_space_state != null:
			var space: PhysicsDirectSpaceState3D = world_3d.direct_space_state
			var side_sign: float = -1.0 if _slip_angle_deg >= 0.0 else 1.0
			var side_origin: Vector3 = ref_node.global_transform * Vector3(side_sign * 0.85, 0.45, 0.0)
			var side_target: Vector3 = ref_node.global_transform * Vector3(side_sign * 1.65, 0.45, 0.0)
			var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(side_origin, side_target)
			if ref_node is CollisionObject3D:
				query.exclude = [ref_node.get_rid()]
			var hit: Dictionary = space.intersect_ray(query)
			if not hit.is_empty():
				_scraping_guardrail = true

# ==============================================================================
# 1. ICONIC INITIAL D RED NEON TAILLIGHT RIBBON TRAILS
# ==============================================================================
func _build_taillight_ribbon_system() -> void:
	var shader: Shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 core_color : source_color = vec4(1.0, 0.92, 0.72, 1.0);
uniform vec4 crimson_color : source_color = vec4(1.0, 0.03, 0.08, 1.0);
uniform float emission_energy = 6.5;
uniform float scroll_speed = 4.5;

void fragment() {
	float v_center = abs(UV.y * 2.0 - 1.0);
	float core_mask = pow(max(0.0, 1.0 - v_center * 1.85), 2.4);
	float fringe_mask = pow(max(0.0, 1.0 - v_center), 1.15);

	float streak_wave = 0.82 + 0.18 * sin(UV.x * 28.0 - TIME * scroll_speed * 6.28318);
	float tail_fade = pow(clamp(1.0 - UV.x, 0.0, 1.0), 1.35) * smoothstep(0.0, 0.06, UV.x);

	vec3 col = mix(crimson_color.rgb, core_color.rgb, core_mask) * emission_energy * streak_wave;
	float alpha = fringe_mask * tail_fade * COLOR.a;

	ALBEDO = col * alpha;
	ALPHA = alpha;
}
"""
	_taillight_material = ShaderMaterial.new()
	_taillight_material.shader = shader

	_taillight_ribbons.clear()
	for i in range(2):
		var rb: RibbonBuffer = RibbonBuffer.new(MAX_RIBBON_POINTS)
		rb.mesh = ImmediateMesh.new()
		rb.mesh_instance = MeshInstance3D.new()
		rb.mesh_instance.name = "TaillightRibbon_" + ("L" if i == 0 else "R")
		rb.mesh_instance.mesh = rb.mesh
		rb.mesh_instance.material_override = _taillight_material
		rb.mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		rb.mesh_instance.top_level = true
		add_child(rb.mesh_instance)
		_taillight_ribbons.append(rb)

func _update_taillight_ribbons(ref_node: Node3D, dt: float) -> void:
	var emitting: bool = (_speed_kmh > 25.0 and absf(_slip_angle_deg) > 8.0) or (_speed_kmh > 20.0 and _brake > 0.45)

	var slip_ratio: float = clampf((absf(_slip_angle_deg) - 8.0) / 35.0, 0.0, 1.0)
	var dynamic_lifetime: float = lerpf(taillight_min_lifetime, taillight_max_lifetime, slip_ratio)
	var dynamic_width: float = taillight_ribbon_width * lerpf(0.85, 1.45, slip_ratio)

	var offsets: Array[Vector3] = [taillight_left_offset, taillight_right_offset]
	var right_vec: Vector3 = ref_node.global_transform.basis.x.normalized()

	for i in range(2):
		var rb: RibbonBuffer = _taillight_ribbons[i]
		rb.update_ages(dt)

		var world_pos: Vector3 = ref_node.global_transform * offsets[i]
		if emitting:
			if not rb.initialized or world_pos.distance_to(rb.last_emit_pos) > 0.08:
				rb.push_sample(world_pos, right_vec * (dynamic_width * 0.5), dynamic_lifetime)
		else:
			rb.initialized = false

		_render_ribbon_buffer(rb)

func _render_ribbon_buffer(rb: RibbonBuffer) -> void:
	rb.mesh.clear_surfaces()
	if rb.count < 2:
		return

	rb.mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var cap: int = rb.points_pos.size()

	for i in range(rb.count):
		var idx: int = (rb.head - 1 - i + cap) % cap
		var pos: Vector3 = rb.points_pos[idx]
		var r_vec: Vector3 = rb.points_right[idx]
		var age: float = rb.points_age[idx]
		var max_l: float = maxf(rb.points_max_life[idx], 0.001)
		var life_t: float = clampf(age / max_l, 0.0, 1.0)

		# Taper ribbon width along trail
		var width_scale: float = sin((1.0 - life_t) * PI * 0.5)
		var p_left: Vector3 = pos - r_vec * width_scale
		var p_right: Vector3 = pos + r_vec * width_scale

		var u: float = float(i) / float(max(rb.count - 1, 1))
		var col: Color = Color(1.0, 1.0, 1.0, 1.0 - life_t)

		rb.mesh.surface_set_color(col)
		rb.mesh.surface_set_uv(Vector2(u, 0.0))
		rb.mesh.surface_add_vertex(p_left)

		rb.mesh.surface_set_color(col)
		rb.mesh.surface_set_uv(Vector2(u, 1.0))
		rb.mesh.surface_add_vertex(p_right)

	rb.mesh.surface_end()

# ==============================================================================
# 2. CEL-SHADED ANIME TIRE SMOKE (THICK PUFFS WITH INVERTED-HULL INK OUTLINES)
# ==============================================================================
func _build_cel_smoke_system() -> void:
	# Create chunky low-poly stylized anime cloud mesh
	var puff_mesh: ArrayMesh = _generate_stylized_smoke_puff_mesh(0.55)

	# Pass 2: Inverted-Hull Black Ink Outline Shader
	var outline_shader: Shader = Shader.new()
	outline_shader.code = """
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque;

uniform float outline_thickness = 0.048;
uniform vec4 ink_color : source_color = vec4(0.05, 0.05, 0.07, 1.0);

varying float v_custom_x;

void vertex() {
	v_custom_x = INSTANCE_CUSTOM.x;
	float life_ratio = clamp(INSTANCE_CUSTOM.x, 0.0, 1.0);
	float pop_scale = smoothstep(1.0, 0.78, life_ratio);
	VERTEX += NORMAL * (outline_thickness * pop_scale);
}

void fragment() {
	if (v_custom_x >= 0.99) {
		discard;
	}
	ALBEDO = ink_color.rgb;
}
"""
	var smoke_outline_mat: ShaderMaterial = ShaderMaterial.new()
	smoke_outline_mat.shader = outline_shader

	# Pass 1: 2-Band Cel-Shaded Anime Puff Shader
	var cel_smoke_shader: Shader = Shader.new()
	cel_smoke_shader.code = """
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec4 lit_color : source_color = vec4(0.97, 0.97, 0.99, 1.0);
uniform vec4 shadow_color : source_color = vec4(0.36, 0.38, 0.43, 1.0);

varying float v_life;

void vertex() {
	v_life = clamp(INSTANCE_CUSTOM.x, 0.0, 1.0);
	// Stepped comic book wobble
	float quant_time = floor(TIME * 14.0) / 14.0;
	float displacement = sin(VERTEX.x * 5.0 + quant_time * 8.0 + INSTANCE_CUSTOM.y * 6.28) * 0.06;
	VERTEX += NORMAL * displacement;
}

void fragment() {
	if (v_life >= 0.99) {
		discard;
	}
	ALBEDO = lit_color.rgb;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float ndotl = dot(NORMAL, LIGHT);
	float band = step(0.05, ndotl);
	vec3 toon_col = mix(shadow_color.rgb, lit_color.rgb, band);
	DIFFUSE_LIGHT += toon_col * clamp(ATTENUATION + 0.35, 0.0, 1.0);
}
"""
	var smoke_cel_mat: ShaderMaterial = ShaderMaterial.new()
	smoke_cel_mat.shader = cel_smoke_shader
	smoke_cel_mat.next_pass = smoke_outline_mat

	puff_mesh.surface_set_material(0, smoke_cel_mat)

	_smoke_multimesh = MultiMesh.new()
	_smoke_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_smoke_multimesh.use_custom_data = true
	_smoke_multimesh.mesh = puff_mesh
	_smoke_multimesh.instance_count = max_smoke_puffs

	_smoke_mmi = MultiMeshInstance3D.new()
	_smoke_mmi.name = "CelShadedAnimeSmoke"
	_smoke_mmi.multimesh = _smoke_multimesh
	_smoke_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_smoke_mmi.top_level = true
	add_child(_smoke_mmi)

	_smoke_pool.clear()
	for i in range(max_smoke_puffs):
		var p: SmokeParticle = SmokeParticle.new()
		_smoke_pool.append(p)
		_smoke_multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0, -9999, 0)))
		_smoke_multimesh.set_instance_custom_data(i, Color(1.0, 0.0, 0.0, 0.0))

func _generate_stylized_smoke_puff_mesh(radius: float) -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Subdivided octahedral-icosahedral lumpy sphere for crisp cartoon cel-shading planes
	var rings: int = 7
	var radial_segments: int = 10

	for r in range(rings):
		var v0: float = float(r) / float(rings)
		var v1: float = float(r + 1) / float(rings)
		var theta0: float = v0 * PI
		var theta1: float = v1 * PI

		for s in range(radial_segments):
			var u0: float = float(s) / float(radial_segments)
			var u1: float = float(s + 1) / float(radial_segments)
			var phi0: float = u0 * TAU
			var phi1: float = u1 * TAU

			var p00: Vector3 = _puff_sphere_point(theta0, phi0, radius)
			var p10: Vector3 = _puff_sphere_point(theta1, phi0, radius)
			var p11: Vector3 = _puff_sphere_point(theta1, phi1, radius)
			var p01: Vector3 = _puff_sphere_point(theta0, phi1, radius)

			if r > 0:
				st.set_normal(p00.normalized())
				st.add_vertex(p00)
				st.set_normal(p10.normalized())
				st.add_vertex(p10)
				st.set_normal(p11.normalized())
				st.add_vertex(p11)

			if r < rings - 1:
				st.set_normal(p00.normalized())
				st.add_vertex(p00)
				st.set_normal(p11.normalized())
				st.add_vertex(p11)
				st.set_normal(p01.normalized())
				st.add_vertex(p01)

	return st.commit()

func _puff_sphere_point(theta: float, phi: float, rad: float) -> Vector3:
	var dir: Vector3 = Vector3(
		sin(theta) * cos(phi),
		cos(theta),
		sin(theta) * sin(phi)
	)
	# Organic anime cloud bulges
	var bulge: float = 1.0 + 0.16 * sin(theta * 3.0) * cos(phi * 4.0)
	return dir * (rad * bulge)

func _update_cel_smoke(ref_node: Node3D, dt: float) -> void:
	var abs_beta: float = absf(_slip_angle_deg)
	var should_emit: bool = (_speed_kmh > 22.0 and abs_beta > 7.5) or (_rear_wheel_spin_factor > 1.35)

	if should_emit:
		var slip_intensity: float = clampf((abs_beta - 7.0) / 30.0, 0.15, 1.5) * clampf(_rear_wheel_spin_factor, 0.5, 2.0)
		var spawn_rate: float = lerpf(16.0, 68.0, clampf(slip_intensity, 0.0, 1.0))
		_smoke_emit_accum += spawn_rate * dt

		var wheel_offsets: Array[Vector3] = [rear_left_wheel_offset, rear_right_wheel_offset]
		while _smoke_emit_accum >= 1.0:
			_smoke_emit_accum -= 1.0
			for w_idx in range(2):
				var world_wheel_pos: Vector3 = ref_node.global_transform * wheel_offsets[w_idx]
				_spawn_smoke_puff(world_wheel_pos, ref_node.global_transform.basis, slip_intensity)

	# Simulate active smoke puffs with stepped anime scale pop dissipation
	for i in range(max_smoke_puffs):
		var p: SmokeParticle = _smoke_pool[i]
		if not p.active:
			continue

		p.age += dt
		if p.age >= p.max_life:
			p.active = false
			_smoke_multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0, -9999, 0)))
			_smoke_multimesh.set_instance_custom_data(i, Color(1.0, 0.0, 0.0, 0.0))
			continue

		var life_t: float = p.age / p.max_life
		p.pos += p.vel * dt
		p.vel = p.vel.lerp(Vector3(0.0, 1.85, 0.0), clampf(dt * 3.8, 0.0, 1.0))
		p.rot_angle += p.rot_speed * dt

		# Stepped anime expand then rapid shrink-pop
		var quantized_t: float = floor(life_t * 10.0) / 10.0
		var scale_curve: float = 1.0
		if life_t < 0.22:
			scale_curve = lerpf(0.35, 1.35, life_t / 0.22)
		elif life_t < 0.72:
			scale_curve = lerpf(1.35, 1.55, (quantized_t - 0.22) / 0.5)
		else:
			# Rapid comic shrink-pop instead of alpha fade
			var shrink_phase: float = (life_t - 0.72) / 0.28
			scale_curve = maxf(0.01, 1.55 * (1.0 - shrink_phase * shrink_phase))

		var final_scale: float = p.base_scale * scale_curve
		var b: Basis = Basis(p.rot_axis, p.rot_angle).scaled(Vector3.ONE * final_scale)
		_smoke_multimesh.set_instance_transform(i, Transform3D(b, p.pos))
		_smoke_multimesh.set_instance_custom_data(i, Color(life_t, float(i % 7) / 7.0, 0.0, 0.0))

func _spawn_smoke_puff(origin: Vector3, car_basis: Basis, intensity: float) -> void:
	var idx: int = _smoke_cursor
	_smoke_cursor = (_smoke_cursor + 1) % max_smoke_puffs

	var p: SmokeParticle = _smoke_pool[idx]
	p.active = true
	p.age = 0.0
	p.max_life = randf_range(0.42, 0.78)
	p.pos = origin + Vector3(randf_range(-0.18, 0.18), randf_range(0.02, 0.16), randf_range(-0.18, 0.18))

	var backward_kick: Vector3 = car_basis.z.normalized() * randf_range(2.2, 5.5) * intensity
	var lateral_kick: Vector3 = car_basis.x.normalized() * signf(_slip_angle_deg) * randf_range(1.0, 3.4) * intensity
	p.vel = backward_kick + lateral_kick + Vector3(0.0, randf_range(0.8, 2.2), 0.0)

	p.rot_axis = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)).normalized()
	if p.rot_axis.length_squared() < 0.01:
		p.rot_axis = Vector3.UP
	p.rot_angle = randf() * TAU
	p.rot_speed = randf_range(-4.5, 4.5)
	p.base_scale = randf_range(0.55, 1.15) * clampf(intensity, 0.75, 1.45)

# ==============================================================================
# 3. ANIME EXHAUST BACKFIRE & SPARK CONES (POP-AND-BANG)
# ==============================================================================
func _build_exhaust_backfire_system() -> void:
	var cone_shader: Shader = Shader.new()
	cone_shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 core_color : source_color = vec4(1.0, 0.98, 0.9, 1.0);
uniform vec4 mid_cyan_color : source_color = vec4(0.15, 0.85, 1.0, 1.0);
uniform vec4 outer_flame_color : source_color = vec4(1.0, 0.32, 0.02, 1.0);
uniform float energy = 8.0;

void fragment() {
	float radial = COLOR.r;
	float tip_fade = 1.0 - UV.y;
	float jag = step(0.18, sin(UV.x * 37.699 + TIME * 45.0) * 0.5 + 0.5);

	vec3 col = mix(outer_flame_color.rgb, mid_cyan_color.rgb, smoothstep(0.2, 0.65, radial));
	col = mix(col, core_color.rgb, smoothstep(0.65, 0.95, radial));

	float alpha = tip_fade * mix(0.75, 1.0, jag) * COLOR.a;
	ALBEDO = col * energy * alpha;
	ALPHA = alpha;
}
"""
	_backfire_shader_mat = ShaderMaterial.new()
	_backfire_shader_mat.shader = cone_shader

	var spiky_mesh: ArrayMesh = _generate_spiky_backfire_cone_mesh()

	_backfire_root_primary = Node3D.new()
	_backfire_root_primary.name = "ExhaustBackfirePrimary"
	_backfire_root_primary.position = exhaust_offset
	_backfire_root_primary.visible = false
	add_child(_backfire_root_primary)

	var m1: MeshInstance3D = MeshInstance3D.new()
	m1.mesh = spiky_mesh
	m1.material_override = _backfire_shader_mat
	m1.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_backfire_root_primary.add_child(m1)

	_backfire_root_secondary = Node3D.new()
	_backfire_root_secondary.name = "ExhaustBackfireSecondary"
	_backfire_root_secondary.position = exhaust_secondary_offset
	_backfire_root_secondary.visible = false
	add_child(_backfire_root_secondary)

	var m2: MeshInstance3D = MeshInstance3D.new()
	m2.mesh = spiky_mesh
	m2.material_override = _backfire_shader_mat
	m2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_backfire_root_secondary.add_child(m2)

	_backfire_light = OmniLight3D.new()
	_backfire_light.name = "BackfireFlashLight"
	_backfire_light.light_color = Color(1.0, 0.58, 0.18)
	_backfire_light.light_energy = 0.0
	_backfire_light.omni_range = 4.2
	_backfire_light.shadow_enabled = false
	_backfire_light.position = exhaust_offset + Vector3(0.0, 0.05, 0.35)
	add_child(_backfire_light)

func _generate_spiky_backfire_cone_mesh() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# 2 concentric spiky star layers: inner hot core + outer jagged cartoon flame
	for layer in range(2):
		var is_core: bool = (layer == 0)
		var num_spikes: int = 7 if is_core else 11
		var base_rad: float = 0.045 if is_core else 0.085
		var spike_len: float = 0.58 if is_core else 0.92
		var radial_weight: float = 0.95 if is_core else 0.35

		for s in range(num_spikes):
			var a0: float = (float(s) / float(num_spikes)) * TAU
			var a1: float = (float(s + 0.5) / float(num_spikes)) * TAU
			var a2: float = (float(s + 1.0) / float(num_spikes)) * TAU

			var p0: Vector3 = Vector3(cos(a0) * base_rad, sin(a0) * base_rad, 0.0)
			var p2: Vector3 = Vector3(cos(a2) * base_rad, sin(a2) * base_rad, 0.0)

			var flare_rad: float = base_rad * (1.8 if is_core else 2.75)
			var tip_z: float = spike_len * (0.85 + 0.3 * sin(float(s) * 2.3))
			var p_tip: Vector3 = Vector3(cos(a1) * flare_rad, sin(a1) * flare_rad, tip_z)

			var col_base: Color = Color(radial_weight, 1.0, 1.0, 1.0)
			var col_tip: Color = Color(radial_weight * 0.5, 1.0, 1.0, 0.0)

			st.set_color(col_base)
			st.set_uv(Vector2(float(s) / float(num_spikes), 0.0))
			st.add_vertex(p0)

			st.set_color(col_tip)
			st.set_uv(Vector2((float(s) + 0.5) / float(num_spikes), 1.0))
			st.add_vertex(p_tip)

			st.set_color(col_base)
			st.set_uv(Vector2(float(s + 1) / float(num_spikes), 0.0))
			st.add_vertex(p2)

	return st.commit()

func _update_exhaust_backfire(ref_node: Node3D, dt: float) -> void:
	_backfire_root_primary.global_transform = ref_node.global_transform * Transform3D(Basis.IDENTITY, exhaust_offset)
	_backfire_root_secondary.global_transform = ref_node.global_transform * Transform3D(Basis.IDENTITY, exhaust_secondary_offset)
	_backfire_light.global_position = _backfire_root_primary.global_position + ref_node.global_transform.basis.z * 0.35

	if _backfire_cooldown > 0.0:
		_backfire_cooldown -= dt

	# Trigger on high-RPM throttle lift, downshift RPM spike, or aggressive drift overrun
	var throttle_lift: bool = (_prev_throttle > 0.45 and _throttle < 0.15)
	var rpm_spike: bool = (_rpm - _prev_rpm > 450.0)
	var overrun_pop: bool = (_rpm > 6500.0 and _throttle < 0.25 and absf(_slip_angle_deg) > 12.0 and randf() < 0.08)

	if _rpm > 6500.0 and _backfire_cooldown <= 0.0 and (throttle_lift or rpm_spike or overrun_pop):
		_trigger_backfire_pop()

	if _backfire_timer > 0.0:
		_backfire_timer -= dt
		var pulse_scale: float = randf_range(0.82, 1.45)
		var twist_rot: float = randf() * TAU
		_backfire_root_primary.scale = Vector3(pulse_scale, pulse_scale, randf_range(0.9, 1.5))
		_backfire_root_primary.rotation.z = twist_rot
		if dual_exhaust:
			_backfire_root_secondary.scale = Vector3(pulse_scale, pulse_scale, randf_range(0.9, 1.5))
			_backfire_root_secondary.rotation.z = -twist_rot
		_backfire_light.light_energy = randf_range(4.5, 9.0)
	else:
		_backfire_root_primary.visible = false
		_backfire_root_secondary.visible = false
		_backfire_light.light_energy = 0.0

func _trigger_backfire_pop() -> void:
	_backfire_timer = randf_range(0.065, 0.14)
	_backfire_cooldown = randf_range(0.16, 0.38)
	_backfire_root_primary.visible = true
	_backfire_root_secondary.visible = dual_exhaust

# ==============================================================================
# 4. GUTTER HOOK & GUARDRAIL MANGA SPARKS (4-POINT ANIME STAR CROSSES)
# ==============================================================================
func _build_manga_spark_system() -> void:
	var spark_mesh: ArrayMesh = _generate_manga_4point_star_mesh(0.24)

	var spark_shader: Shader = Shader.new()
	spark_shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 core_white : source_color = vec4(1.0, 1.0, 0.92, 1.0);
uniform vec4 spark_amber : source_color = vec4(1.0, 0.58, 0.05, 1.0);
uniform float emission_boost = 7.5;

varying float v_spark_life;

void vertex() {
	v_spark_life = clamp(INSTANCE_CUSTOM.x, 0.0, 1.0);
}

void fragment() {
	if (v_spark_life >= 0.99) {
		discard;
	}
	float center_weight = COLOR.r;
	vec3 col = mix(spark_amber.rgb, core_white.rgb, center_weight) * emission_boost;
	float alpha = (1.0 - v_spark_life) * COLOR.a;
	ALBEDO = col * alpha;
	ALPHA = alpha;
}
"""
	var spark_mat: ShaderMaterial = ShaderMaterial.new()
	spark_mat.shader = spark_shader
	spark_mesh.surface_set_material(0, spark_mat)

	_spark_multimesh = MultiMesh.new()
	_spark_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_spark_multimesh.use_custom_data = true
	_spark_multimesh.mesh = spark_mesh
	_spark_multimesh.instance_count = max_manga_sparks

	_spark_mmi = MultiMeshInstance3D.new()
	_spark_mmi.name = "GutterMangaSparks"
	_spark_mmi.multimesh = _spark_multimesh
	_spark_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spark_mmi.top_level = true
	add_child(_spark_mmi)

	_spark_pool.clear()
	for i in range(max_manga_sparks):
		_spark_pool.append(MangaSpark.new())
		_spark_multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0, -9999, 0)))
		_spark_multimesh.set_instance_custom_data(i, Color(1.0, 0.0, 0.0, 0.0))

func _generate_manga_4point_star_mesh(size: float) -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Orthogonal 3D crossed 4-point manga stars so they are visible from any camera angle
	var planes: Array[Basis] = [
		Basis.IDENTITY,
		Basis(Vector3.UP, PI * 0.5)
	]

	var inner: float = size * 0.16
	for basis in planes:
		for arm in range(4):
			var angle: float = float(arm) * (PI * 0.5)
			var dir: Vector3 = basis * Vector3(cos(angle), sin(angle), 0.0)
			var perp: Vector3 = basis * Vector3(-sin(angle), cos(angle), 0.0)

			var c0: Vector3 = Vector3.ZERO
			var p_left: Vector3 = perp * inner
			var p_right: Vector3 = -perp * inner
			var p_tip: Vector3 = dir * size

			st.set_color(Color(1.0, 1.0, 1.0, 1.0))
			st.add_vertex(c0)
			st.set_color(Color(0.4, 1.0, 1.0, 0.9))
			st.add_vertex(p_left)
			st.set_color(Color(0.0, 1.0, 1.0, 0.0))
			st.add_vertex(p_tip)

			st.set_color(Color(1.0, 1.0, 1.0, 1.0))
			st.add_vertex(c0)
			st.set_color(Color(0.0, 1.0, 1.0, 0.0))
			st.add_vertex(p_tip)
			st.set_color(Color(0.4, 1.0, 1.0, 0.9))
			st.add_vertex(p_right)

	return st.commit()

func _update_manga_sparks(ref_node: Node3D, dt: float) -> void:
	if (_in_gutter or _scraping_guardrail) and _speed_kmh > 30.0:
		_spark_emit_accum += 95.0 * dt
		var use_left: bool = (_slip_angle_deg >= 0.0)
		var spark_local_offset: Vector3 = front_left_wheel_offset if use_left else front_right_wheel_offset
		if _scraping_guardrail:
			spark_local_offset = rear_left_wheel_offset if use_left else rear_right_wheel_offset
			spark_local_offset.y += 0.35

		var emit_world_pos: Vector3 = ref_node.global_transform * spark_local_offset
		while _spark_emit_accum >= 1.0:
			_spark_emit_accum -= 1.0
			_spawn_manga_spark(emit_world_pos, ref_node.global_transform.basis)

	var floor_y: float = ref_node.global_position.y + 0.03
	for i in range(max_manga_sparks):
		var s: MangaSpark = _spark_pool[i]
		if not s.active:
			continue

		s.age += dt
		if s.age >= s.max_life:
			s.active = false
			_spark_multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0, -9999, 0)))
			_spark_multimesh.set_instance_custom_data(i, Color(1.0, 0.0, 0.0, 0.0))
			continue

		s.vel.y -= 16.5 * dt
		s.pos += s.vel * dt

		# Asphalt bounce
		if s.pos.y < floor_y and s.vel.y < 0.0:
			s.pos.y = floor_y
			s.vel.y = -s.vel.y * 0.55

		s.spin_angle += s.spin_speed * dt
		var life_t: float = s.age / s.max_life
		var cur_scale: float = s.scale * (1.0 - life_t * 0.65)
		var b: Basis = Basis(Vector3(0.4, 0.8, 0.4).normalized(), s.spin_angle).scaled(Vector3(cur_scale, cur_scale, cur_scale * 1.6))

		_spark_multimesh.set_instance_transform(i, Transform3D(b, s.pos))
		_spark_multimesh.set_instance_custom_data(i, Color(life_t, 0.0, 0.0, 0.0))

func _spawn_manga_spark(origin: Vector3, car_basis: Basis) -> void:
	var idx: int = _spark_cursor
	_spark_cursor = (_spark_cursor + 1) % max_manga_sparks

	var s: MangaSpark = _spark_pool[idx]
	s.active = true
	s.age = 0.0
	s.max_life = randf_range(0.18, 0.42)
	s.pos = origin + Vector3(randf_range(-0.08, 0.08), randf_range(0.0, 0.12), randf_range(-0.08, 0.08))

	var back_dir: Vector3 = car_basis.z.normalized()
	var out_dir: Vector3 = car_basis.x.normalized() * (-1.0 if _slip_angle_deg >= 0.0 else 1.0)
	s.vel = back_dir * randf_range(5.5, 13.0) + out_dir * randf_range(1.5, 5.5) + Vector3(0.0, randf_range(2.2, 6.2), 0.0)
	s.scale = randf_range(0.65, 1.35)
	s.spin_angle = randf() * TAU
	s.spin_speed = randf_range(14.0, 28.0)

# ==============================================================================
# 5. AERODYNAMIC AIR SLIPSTREAM RIBBONS (SPEED VORTICES)
# ==============================================================================
func _build_aero_ribbon_system() -> void:
	var aero_shader: Shader = Shader.new()
	aero_shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 wind_color : source_color = vec4(0.88, 0.96, 1.0, 0.65);

void fragment() {
	float edge_fade = 1.0 - abs(UV.y * 2.0 - 1.0);
	float tail_fade = pow(1.0 - UV.x, 1.6) * smoothstep(0.0, 0.08, UV.x);
	float alpha = edge_fade * tail_fade * wind_color.a * COLOR.a;
	ALBEDO = wind_color.rgb * 2.2 * alpha;
	ALPHA = alpha;
}
"""
	_aero_material = ShaderMaterial.new()
	_aero_material.shader = aero_shader

	_aero_ribbons.clear()
	for i in range(4):
		var rb: RibbonBuffer = RibbonBuffer.new(MAX_AERO_POINTS)
		rb.mesh = ImmediateMesh.new()
		rb.mesh_instance = MeshInstance3D.new()
		rb.mesh_instance.name = "AeroSlipstream_" + str(i)
		rb.mesh_instance.mesh = rb.mesh
		rb.mesh_instance.material_override = _aero_material
		rb.mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		rb.mesh_instance.top_level = true
		add_child(rb.mesh_instance)
		_aero_ribbons.append(rb)

func _update_aero_ribbons(ref_node: Node3D, dt: float) -> void:
	var emitting: bool = (_speed_kmh > 95.0)
	var aero_offsets: Array[Vector3] = [
		aero_left_mirror_offset,
		aero_right_mirror_offset,
		aero_left_wing_offset,
		aero_right_wing_offset
	]

	var vortex_freq: float = 16.0 + absf(_steering) * 14.0
	var vortex_amp: float = 0.04 + absf(_slip_angle_deg) * 0.004

	for i in range(4):
		var rb: RibbonBuffer = _aero_ribbons[i]
		rb.update_ages(dt)

		if emitting:
			var spiral_angle: float = _time_accum * vortex_freq + float(i) * 1.57
			var swirl_offset: Vector3 = Vector3(cos(spiral_angle), sin(spiral_angle), 0.0) * vortex_amp
			var world_pos: Vector3 = ref_node.global_transform * (aero_offsets[i] + swirl_offset)
			var rot_right: Vector3 = (ref_node.global_transform.basis.x * cos(spiral_angle) + ref_node.global_transform.basis.y * sin(spiral_angle)).normalized()

			if not rb.initialized or world_pos.distance_to(rb.last_emit_pos) > 0.09:
				rb.push_sample(world_pos, rot_right * 0.045, 0.28)
		else:
			rb.initialized = false

		_render_ribbon_buffer(rb)

# ==============================================================================
# 6. VEHICLE ANIME TOON SHADING & PROCEDURAL FUJIWARA TOFU KANJI DECAL
# ==============================================================================
func _build_anime_vehicle_materials() -> void:
	# Inverted-hull manga ink outline pass for vehicle chassis
	var outline_shader: Shader = Shader.new()
	outline_shader.code = """
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque;

uniform float outline_width = 0.014;
uniform vec4 ink_color : source_color = vec4(0.03, 0.03, 0.04, 1.0);

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = ink_color.rgb;
}
"""
	_outline_pass_material = ShaderMaterial.new()
	_outline_pass_material.shader = outline_shader

	# Stepped anime cel-shading + speed-line rim highlight pass
	var toon_shader: Shader = Shader.new()
	toon_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform vec4 rim_color : source_color = vec4(0.88, 0.94, 1.0, 1.0);
uniform float rim_threshold = 0.72;

void fragment() {
	float fresnel = 1.0 - max(0.0, dot(NORMAL, VIEW));
	float anime_rim = step(rim_threshold, fresnel);
	float dark_crease = step(0.86, fresnel);

	ALBEDO = mix(vec3(0.02), rim_color.rgb, anime_rim * (1.0 - dark_crease));
	EMISSION = rim_color.rgb * anime_rim * 0.65;
	ALPHA = max(anime_rim * 0.42, dark_crease * 0.55);
}

void light() {
	float ndotl = dot(NORMAL, LIGHT);
	float cel_step = step(0.0, ndotl);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * cel_step * 0.35;
}
"""
	_toon_overlay_material = ShaderMaterial.new()
	_toon_overlay_material.shader = toon_shader
	_toon_overlay_material.next_pass = _outline_pass_material

func _apply_toon_shader_recursively(root: Node) -> void:
	if _is_headless or root == self:
		return

	if root is MeshInstance3D:
		var mi: MeshInstance3D = root as MeshInstance3D
		if mi.mesh != null and not _bound_meshes.has(mi):
			mi.material_overlay = _toon_overlay_material
			_bound_meshes.append(mi)

	for child in root.get_children():
		_apply_toon_shader_recursively(child)

func _attach_fujiwara_tofu_decal(vehicle: Node3D) -> void:
	if _tofu_decal_mesh != null and is_instance_valid(_tofu_decal_mesh):
		_tofu_decal_mesh.reparent(vehicle, false)
		_tofu_decal_mesh.visible = true
		return

	# Generate crisp "藤原とうふ店（自家用）" decal texture via SubViewport + SystemFont fallback + Vector Kanji Renderer
	_tofu_viewport = SubViewport.new()
	_tofu_viewport.name = "FujiwaraTofuKanjiViewport"
	_tofu_viewport.size = Vector2i(1024, 256)
	_tofu_viewport.transparent_bg = true
	_tofu_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_tofu_viewport)

	var canvas: Control = _create_procedural_tofu_kanji_canvas()
	_tofu_viewport.add_child(canvas)

	# Build a curved door decal quad that conforms cleanly to the AE86 right-hand driver door
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.28, 0.32)

	var decal_shader: Shader = Shader.new()
	decal_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;

uniform sampler2D kanji_tex : source_color, filter_linear_mipmap;

void fragment() {
	vec4 tex = texture(kanji_tex, UV);
	if (tex.a < 0.1) {
		discard;
	}
	ALBEDO = tex.rgb;
	ROUGHNESS = 0.25;
	ALPHA = tex.a;
}
"""
	var decal_mat: ShaderMaterial = ShaderMaterial.new()
	decal_mat.shader = decal_shader
	if not _is_headless:
		decal_mat.set_shader_parameter("kanji_tex", _tofu_viewport.get_texture())

	_tofu_decal_mesh = MeshInstance3D.new()
	_tofu_decal_mesh.name = "FujiwaraTofuDoorDecal"
	_tofu_decal_mesh.mesh = quad
	_tofu_decal_mesh.material_override = decal_mat
	_tofu_decal_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Right-hand drive AE86 driver door placement (+X side, facing +X)
	_tofu_decal_mesh.position = Vector3(0.84, 0.56, -0.05)
	_tofu_decal_mesh.rotation_degrees = Vector3(0.0, 90.0, 0.0)
	vehicle.add_child(_tofu_decal_mesh)

func _create_procedural_tofu_kanji_canvas() -> Control:
	var root_ctrl: Control = Control.new()
	root_ctrl.custom_minimum_size = Vector2(1024, 256)
	root_ctrl.size = Vector2(1024, 256)

	var label: Label = Label.new()
	label.text = "藤原とうふ店（自家用）"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size = Vector2(1024, 256)

	var sys_font: SystemFont = SystemFont.new()
	sys_font.font_names = PackedStringArray([
		"Noto Sans CJK JP",
		"IPAGothic",
		"MS Gothic",
		"Yu Gothic",
		"Hiragino Kaku Gothic ProN",
		"TakaoGothic",
		"VL Gothic",
		"Sans-Serif"
	])
	sys_font.font_weight = 800

	var settings: LabelSettings = LabelSettings.new()
	settings.font = sys_font
	settings.font_size = 92
	settings.font_color = Color(0.04, 0.04, 0.05, 1.0)
	settings.outline_size = 6
	settings.outline_color = Color(0.96, 0.96, 0.96, 1.0)
	label.label_settings = settings

	root_ctrl.add_child(label)
	return root_ctrl
