# JDMDriftVFXSystem.gd
# Godot 4.3 Forward+ | Self-Contained Procedural Drift, Skidmark & Anti-Lag VFX System
class_name JDMDriftVFXSystem
extends Node3D

# ==============================================================================
# EXPORTED CONFIGURATION & NODE BINDINGS
# ==============================================================================
@export_group("Vehicle Bindings")
## Target physics vehicle. Auto-resolves to parent if left unassigned.
@export var vehicle: Node3D
## Assign 4 wheel nodes (VehicleWheel3D or standard Node3D/Marker3D). Auto-discovers VehicleWheel3D children if empty.
@export var wheel_nodes: Array[Node3D] = []
## Assign 1 or more exhaust tip markers (dual/quad exhaust support). Auto-discovers nodes with "exhaust" in name if empty.
@export var exhaust_tips: Array[Node3D] = []

@export_group("Drift & Slip Thresholds")
## Lateral slip angle in degrees required to trigger tire smoke and skidmarks.
@export_range(5.0, 45.0, 0.5) var slip_angle_threshold_deg: float = 12.0
## Slip angle at which smoke opacity and skidmark darkness reach 100%.
@export_range(15.0, 90.0, 1.0) var max_slip_angle_deg: float = 42.0
## Minimum vehicle velocity (m/s) required to emit drift VFX.
@export var min_speed_mps: float = 3.5
## Wheel radius (meters) used for contact patch offset if non-VehicleWheel3D nodes are used.
@export var fallback_wheel_radius: float = 0.33

@export_group("Stylized Tire Smoke (GPUParticles3D)")
## Maximum GPU particles per wheel emitter.
@export var smoke_particles_per_wheel: int = 160
@export var smoke_lifetime: float = 2.4
## Base albedo color for Initial D anime/stylized thick white-gray smoke.
@export var smoke_albedo: Color = Color(0.92, 0.94, 0.98, 0.65)

@export_group("Dynamic Asphalt Skidmarks")
@export var skidmark_width: float = 0.26
## Distance (meters) the wheel must travel before committing a new ribbon quad.
@export var skidmark_min_segment_dist: float = 0.28
## Total fade-out duration in seconds (handled entirely on the GPU via TIME shader uniform).
@export var skidmark_fade_time: float = 15.0
## Maximum active segments per wheel in the circular ring buffer (Zero GC allocations).
@export var max_skid_segments_per_wheel: int = 384
## Normal bias above the road surface to prevent depth buffer Z-fighting.
@export var ground_offset: float = 0.018

@export_group("Exhaust Anti-Lag & Backfire")
@export var backfire_rpm_threshold: float = 6000.0
@export var max_engine_rpm: float = 8500.0
## Minimum time between pop-and-bang bursts during sustained high-RPM overrun.
@export var backfire_cooldown: float = 0.085

# ==============================================================================
# INTERNAL RUNTIME STATE (ZERO-MUTATION TELEMETRY)
# ==============================================================================
class WheelVFXChannel:
	var wheel_node: Node3D
	var is_vehicle_wheel: bool = false
	var wheel_radius: float = 0.33
	var smoke_emitter: GPUParticles3D
	var smoke_material: ShaderMaterial
	
	# Skidmark Ring Buffer State
	var skid_mesh_instance: MeshInstance3D
	var skid_immediate_mesh: ImmediateMesh
	var segment_buffer: Array[Dictionary] = []
	var buffer_head: int = 0
	var buffer_count: int = 0
	var was_skidding: bool = false
	var mesh_dirty: bool = false
	var last_cleanup_time: float = 0.0
	var last_left_vtx: Vector3 = Vector3.ZERO
	var last_right_vtx: Vector3 = Vector3.ZERO
	var last_contact_pos: Vector3 = Vector3.ZERO
	var current_intensity: float = 0.0

class ExhaustVFXChannel:
	var tip_node: Node3D
	var flame_emitter: GPUParticles3D
	var omni_light: OmniLight3D
	var light_energy_current: float = 0.0
	var flash_color_target: Color = Color(1.0, 0.55, 0.1)

var _wheel_channels: Array[WheelVFXChannel] = []
var _exhaust_channels: Array[ExhaustVFXChannel] = []
var _skidmark_container: Node3D
var _shared_skidmark_material: ShaderMaterial

# Passive Physics Differentiation State
var _prev_global_pos: Vector3 = Vector3.ZERO
var _computed_velocity: Vector3 = Vector3.ZERO
var _prev_throttle: float = 0.0
var _prev_gear: int = 1
var _simulated_rpm: float = 1000.0
var _simulated_gear: int = 1
var _backfire_timer: float = 0.0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# ==============================================================================
# LIFECYCLE & INITIALIZATION
# ==============================================================================
func _ready() -> void:
	_rng.randomize()
	_resolve_vehicle_bindings()
	
	if not is_instance_valid(vehicle):
		push_warning("JDMDriftVFXSystem: No valid vehicle Node3D found. Disabling VFX tick.")
		set_physics_process(false)
		set_process(false)
		return
		
	_prev_global_pos = vehicle.global_position
	_build_shared_materials()
	_initialize_wheel_channels()
	_initialize_exhaust_channels()


func _exit_tree() -> void:
	if is_instance_valid(_skidmark_container):
		_skidmark_container.queue_free()


func _resolve_vehicle_bindings() -> void:
	if not is_instance_valid(vehicle):
		var parent := get_parent()
		if parent is Node3D:
			vehicle = parent

	if not is_instance_valid(vehicle):
		return

	# Auto-discover wheels if not manually assigned in Inspector
	if wheel_nodes.is_empty():
		for child in vehicle.find_children("*", "VehicleWheel3D", true, false):
			wheel_nodes.append(child as Node3D)
		# Fallback: search by naming convention if custom RayCast car is used
		if wheel_nodes.is_empty():
			for child in vehicle.find_children("*", "Node3D", true, false):
				var n_low := child.name.to_lower()
				if ("wheel" in n_low or "tire" in n_low or "fl" == n_low or "fr" == n_low or "rl" == n_low or "rr" == n_low) and child != self:
					wheel_nodes.append(child as Node3D)

	# Auto-discover exhaust tips if not manually assigned
	if exhaust_tips.is_empty():
		for child in vehicle.find_children("*", "Node3D", true, false):
			var n_low := child.name.to_lower()
			if ("exhaust" in n_low or "muffler" in n_low or "tailpipe" in n_low) and child != self:
				exhaust_tips.append(child as Node3D)
		
		# Create a fallback rear-right JDM exhaust marker if none exists on the model
		if exhaust_tips.is_empty():
			var fallback_tip := Marker3D.new()
			fallback_tip.name = "ProceduralJDMExhaustTip"
			fallback_tip.position = Vector3(0.55, 0.28, -2.15)
			add_child(fallback_tip)
			exhaust_tips.append(fallback_tip)

# ==============================================================================
# PROCEDURAL SHADER & MATERIAL GENERATION (FORWARD+ OPTIMIZED)
# ==============================================================================
func _build_shared_materials() -> void:
	# Top-level world container for skidmarks so ribbons stay locked to world space
	_skidmark_container = Node3D.new()
	_skidmark_container.name = "JDM_WorldSkidmarkPool_" + str(get_instance_id())
	_skidmark_container.top_level = true
	add_child(_skidmark_container)
	_skidmark_container.global_transform = Transform3D.IDENTITY

	# GPU-driven 15-second fade shader using vertex COLOR.g + COLOR.b as a 16-bit spawn timestamp
	var skid_shader := Shader.new()
	skid_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform float fade_duration = 15.0;
uniform vec4 rubber_color : source_color = vec4(0.04, 0.04, 0.045, 0.88);
uniform float roughness_val = 0.82;

varying float v_age_alpha;
varying float v_intensity;

void vertex() {
	// Unpack spawn time encoded across G (integral modulo 256s) and B (fractional)
	// Or direct float passed via UV2.x for exact precision
	float spawn_time = UV2.x;
	float age = max(0.0, TIME - spawn_time);
	v_age_alpha = clamp(1.0 - (age / fade_duration), 0.0, 1.0);
	// Smooth cubic fade-out curve over 15 seconds
	v_age_alpha = v_age_alpha * v_age_alpha * (3.0 - 2.0 * v_age_alpha);
	v_intensity = COLOR.r;
}

void fragment() {
	// Soft procedural tire tread grooves & feathered edges along UV.x
	float edge_dist = abs(UV.x - 0.5) * 2.0;
	float edge_mask = 1.0 - smoothstep(0.68, 1.0, edge_dist);
	
	// Dual-rib JDM semi-slick tread pattern
	float tread_groove = smoothstep(0.06, 0.14, abs(edge_dist - 0.35));
	
	float final_alpha = rubber_color.a * v_intensity * v_age_alpha * edge_mask * (0.75 + 0.25 * tread_groove);
	if (final_alpha <= 0.004) {
		discard;
	}
	ALBEDO = rubber_color.rgb;
	ALPHA = final_alpha;
	ROUGHNESS = roughness_val;
	SPECULAR = 0.15;
}
"""
	_shared_skidmark_material = ShaderMaterial.new()
	_shared_skidmark_material.shader = skid_shader
	_shared_skidmark_material.set_shader_parameter("fade_duration", skidmark_fade_time)


func _create_smoke_shader_material() -> ShaderMaterial:
	var smoke_shader := Shader.new()
	smoke_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_toon, specular_disabled;

uniform vec4 base_smoke_color : source_color = vec4(0.92, 0.94, 0.98, 0.65);
uniform float master_opacity : hint_range(0.0, 1.5) = 1.0;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

varying float v_lifetime_ratio;
varying float v_seed;

// Fast 3D hash noise for anime billow distortion
float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(i + vec3(0,0,0)), hash(i + vec3(1,0,0)), f.x),
			mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
		mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
			mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}

void vertex() {
	v_lifetime_ratio = INSTANCE_CUSTOM.y;
	v_seed = INSTANCE_CUSTOM.x;
	
	// Turbulent volumetric vertex displacement
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float n = noise(world_pos * 1.8 + vec3(TIME * 2.2, v_seed * 10.0, 0.0));
	VERTEX += NORMAL * (n - 0.35) * (0.35 + v_lifetime_ratio * 0.85);
}

void fragment() {
	// Stylized cel-shaded rim + soft volumetric proximity fade
	float ndotv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float sphere_mask = smoothstep(0.05, 0.65, ndotv);
	
	// Depth proximity fade against asphalt and car bodywork
	float depth_raw = texture(depth_texture, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth_raw);
	vec4 view_depth = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_depth.xyz /= view_depth.w;
	float linear_scene_depth = -view_depth.z;
	float fragment_depth = -VERTEX.z;
	float proximity_fade = clamp((linear_scene_depth - fragment_depth) / 0.45, 0.0, 1.0);
	
	// Initial D stepped anime shading highlight
	ALBEDO = base_smoke_color.rgb * mix(0.78, 1.08, step(0.45, ndotv));
	
	float life_fade = sin(clamp(v_lifetime_ratio, 0.0, 1.0) * 3.14159);
	life_fade = clamp( (1.0 - pow(v_lifetime_ratio, 1.6)) * smoothstep(0.0, 0.12, v_lifetime_ratio), 0.0, 1.0 );
	
	ALPHA = clamp(base_smoke_color.a * COLOR.a * master_opacity * sphere_mask * proximity_fade * life_fade, 0.0, 0.95);
	ROUGHNESS = 1.0;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = smoke_shader
	mat.set_shader_parameter("base_smoke_color", smoke_albedo)
	mat.set_shader_parameter("master_opacity", 0.0)
	return mat


# ==============================================================================
# WHEEL SMOKE & SKIDMARK CHANNEL SETUP
# ==============================================================================
func _initialize_wheel_channels() -> void:
	# Shared low-poly displaced sphere mesh for volumetric puff clusters
	var puff_mesh := SphereMesh.new()
	puff_mesh.radius = 0.36
	puff_mesh.height = 0.68
	puff_mesh.radial_segments = 12
	puff_mesh.rings = 6

	# Shared Scale Curve for expanding tire smoke plumes
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.25), 0.0, 2.8)
	scale_curve.add_point(Vector2(0.25, 1.15), 1.4, 1.4)
	scale_curve.add_point(Vector2(1.0, 2.85), 0.5, 0.0)
	var scale_curve_tex := CurveTexture.new()
	scale_curve_tex.curve = scale_curve

	# Shared Alpha Gradient
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.12, 0.65, 1.0])
	grad.colors = PackedColorArray([
		Color(1, 1, 1, 0.0),
		Color(1, 1, 1, 0.95),
		Color(0.92, 0.92, 0.95, 0.55),
		Color(0.85, 0.85, 0.9, 0.0)
	])
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = grad

	for w_node in wheel_nodes:
		if not is_instance_valid(w_node):
			continue
		var channel := WheelVFXChannel.new()
		channel.wheel_node = w_node
		channel.is_vehicle_wheel = w_node is VehicleWheel3D
		if channel.is_vehicle_wheel:
			channel.wheel_radius = (w_node as VehicleWheel3D).wheel_radius
		else:
			channel.wheel_radius = fallback_wheel_radius

		# 1. Configure GPUParticles3D Tire Smoke Emitter
		var emitter := GPUParticles3D.new()
		emitter.name = "SmokeEmitter_" + w_node.name
		emitter.amount = smoke_particles_per_wheel
		emitter.lifetime = smoke_lifetime
		emitter.explosiveness = 0.0
		emitter.randomness = 0.35
		emitter.fixed_fps = 0 # Interpolate smoothly at 144Hz+
		emitter.interpolate = true
		emitter.local_coords = false
		emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		emitter.visibility_aabb = AABB(Vector3(-25, -5, -25), Vector3(50, 20, 50))

		var proc_mat := ParticleProcessMaterial.new()
		proc_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		proc_mat.emission_box_extents = Vector3(skidmark_width * 0.5, 0.05, 0.16)
		proc_mat.direction = Vector3(0.0, 0.42, -1.0)
		proc_mat.spread = 28.0
		proc_mat.initial_velocity_min = 1.4
		proc_mat.initial_velocity_max = 3.8
		proc_mat.gravity = Vector3(0.0, 1.35, 0.0) # Thermal buoyancy rise
		proc_mat.damping_min = 1.8
		proc_mat.damping_max = 3.2
		proc_mat.scale_min = 0.85
		proc_mat.scale_max = 1.45
		proc_mat.scale_curve = scale_curve_tex
		proc_mat.color_ramp = grad_tex
		proc_mat.turbulence_enabled = true
		proc_mat.turbulence_noise_strength = 1.85
		proc_mat.turbulence_noise_scale = 2.5
		proc_mat.turbulence_noise_speed = Vector3(0.5, 1.2, 0.5)

		channel.smoke_material = _create_smoke_shader_material()
		puff_mesh.material = channel.smoke_material
		
		# Give each wheel its own Mesh duplicate so per-wheel opacity shader uniforms don't collide
		var wheel_puff_mesh := puff_mesh.duplicate() as SphereMesh
		wheel_puff_mesh.material = channel.smoke_material

		emitter.process_material = proc_mat
		emitter.draw_pass_1 = wheel_puff_mesh
		emitter.emitting = false
		emitter.amount_ratio = 0.0
		add_child(emitter)
		channel.smoke_emitter = emitter

		# 2. Configure Pre-Allocated Skidmark ImmediateMesh Ring Buffer
		var skid_mi := MeshInstance3D.new()
		skid_mi.name = "SkidRibbon_" + w_node.name
		skid_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		skid_mi.material_override = _shared_skidmark_material
		skid_mi.extra_cull_margin = 500.0
		
		var imm_mesh := ImmediateMesh.new()
		skid_mi.mesh = imm_mesh
		_skidmark_container.add_child(skid_mi)
		
		channel.skid_mesh_instance = skid_mi
		channel.skid_immediate_mesh = imm_mesh
		channel.segment_buffer.resize(max_skid_segments_per_wheel)
		for i in range(max_skid_segments_per_wheel):
			channel.segment_buffer[i] = {
				"v0": Vector3.ZERO,
				"v1": Vector3.ZERO,
				"v2": Vector3.ZERO,
				"v3": Vector3.ZERO,
				"normal": Vector3.UP,
				"intensity": 0.0,
				"spawn_time": -999.0
			}

		_wheel_channels.append(channel)


# ==============================================================================
# EXHAUST BACKFIRE & ANTI-LAG FLAME SETUP
# ==============================================================================
func _initialize_exhaust_channels() -> void:
	# Additive HDR shader for afterburner core + outer orange flame cone
	var flame_shader := Shader.new()
	flame_shader.code = """
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded;

void vertex() {
	// Align billboard quad stretched along velocity vector or view
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0)
	);
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float radial = length(centered_uv);
	float core_mask = exp(-radial * radial * 4.5);
	float outer_glow = max(0.0, 1.0 - radial);
	
	// High-energy HDR emission multiplier for Forward+ Glow/Bloom
	ALBEDO = COLOR.rgb * (core_mask * 6.5 + outer_glow * 2.2);
	ALPHA = COLOR.a * outer_glow;
}
"""
	var flame_mat := ShaderMaterial.new()
	flame_mat.shader = flame_shader

	var flame_quad := QuadMesh.new()
	flame_quad.size = Vector2(0.28, 0.28)
	flame_quad.material = flame_mat

	# Color ramp: Intense hydrocarbon blue core -> violent orange-yellow combustion -> dark ember fade
	var flame_grad := Gradient.new()
	flame_grad.offsets = PackedFloat32Array([0.0, 0.22, 0.58, 1.0])
	flame_grad.colors = PackedColorArray([
		Color(0.25, 0.65, 1.0, 1.0),   # Hot blue lean/rich ignition flash
		Color(1.0, 0.78, 0.22, 0.95),  # Bright yellow-orange fireball
		Color(1.0, 0.28, 0.02, 0.65),  # Deep orange afterburn
		Color(0.2, 0.02, 0.0, 0.0)     # Dissolve
	])
	var flame_grad_tex := GradientTexture1D.new()
	flame_grad_tex.gradient = flame_grad

	var flame_scale_curve := Curve.new()
	flame_scale_curve.add_point(Vector2(0.0, 0.45))
	flame_scale_curve.add_point(Vector2(0.3, 1.35))
	flame_scale_curve.add_point(Vector2(1.0, 0.15))
	var flame_scale_tex := CurveTexture.new()
	flame_scale_tex.curve = flame_scale_curve

	var flame_proc := ParticleProcessMaterial.new()
	flame_proc.direction = Vector3(0.0, 0.0, -1.0) # Shoots backward out of tailpipe
	flame_proc.spread = 9.5
	flame_proc.initial_velocity_min = 6.5
	flame_proc.initial_velocity_max = 13.5
	flame_proc.damping_min = 18.0
	flame_proc.damping_max = 28.0
	flame_proc.scale_min = 0.75
	flame_proc.scale_max = 1.45
	flame_proc.scale_curve = flame_scale_tex
	flame_proc.color_ramp = flame_grad_tex

	for tip in exhaust_tips:
		if not is_instance_valid(tip):
			continue
		var ex_chan := ExhaustVFXChannel.new()
		ex_chan.tip_node = tip

		var particles := GPUParticles3D.new()
		particles.name = "BackfireParticles_" + tip.name
		particles.amount = 18
		particles.lifetime = 0.095
		particles.one_shot = true
		particles.explosiveness = 0.92
		particles.local_coords = true
		particles.interpolate = true
		particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		particles.process_material = flame_proc
		particles.draw_pass_1 = flame_quad
		particles.emitting = false
		tip.add_child(particles)
		ex_chan.flame_emitter = particles

		# Dynamic Point Light for realistic rear bumper & asphalt illumination
		var light := OmniLight3D.new()
		light.name = "BackfireLight_" + tip.name
		light.light_color = Color(1.0, 0.48, 0.12)
		light.light_energy = 0.0
		light.omni_range = 3.6
		light.omni_attenuation = 1.6
		light.shadow_enabled = false # Zero shadow-map overhead for 144 FPS target
		light.position = Vector3(0.0, 0.0, -0.18)
		tip.add_child(light)
		ex_chan.omni_light = light

		_exhaust_channels.append(ex_chan)


# ==============================================================================
# MAIN PHYSICS & RENDER LOOPS (ZERO PHYSICS MUTATION)
# ==============================================================================
func _physics_process(delta: float) -> void:
	if not is_instance_valid(vehicle) or delta <= 0.00001:
		return

	# 1. Read-Only Vehicle Kinematics
	var current_pos := vehicle.global_position
	if "linear_velocity" in vehicle:
		_computed_velocity = vehicle.get("linear_velocity")
	elif "velocity" in vehicle:
		_computed_velocity = vehicle.get("velocity")
	else:
		_computed_velocity = (current_pos - _prev_global_pos) / delta
	_prev_global_pos = current_pos

	var speed_mps := _computed_velocity.length()
	var car_basis := vehicle.global_transform.basis
	# Support both Godot standard (-Z forward) and VehicleBody3D (+Z or -Z depending on rig)
	var forward_dir := -car_basis.z.normalized()
	var horiz_vel := Vector3(_computed_velocity.x, 0.0, _computed_velocity.z)
	var horiz_forward := Vector3(forward_dir.x, 0.0, forward_dir.z).normalized()

	# Calculate signed lateral drift slip angle in degrees
	var slip_angle_deg: float = 0.0
	if horiz_vel.length_squared() > 1.2:
		var vel_dir := horiz_vel.normalized()
		# Handle vehicles rigged with +Z forward seamlessly
		var dot_f := clampf( absf(horiz_forward.dot(vel_dir)), 0.0, 1.0 )
		slip_angle_deg = rad_to_deg(acos(dot_f))

	# 2. Read-Only Powertrain Telemetry for Wheelspin, Brake Lock & Backfire
	var telemetry := _read_powertrain_telemetry(speed_mps, delta)

	# 3. Update Per-Wheel Smoke & Skidmarks
	_update_wheels_vfx(speed_mps, slip_angle_deg, telemetry, delta)

	# 4. Evaluate Exhaust Pop-and-Bang Triggers
	_evaluate_exhaust_backfire(telemetry, delta)


func _process(delta: float) -> void:
	# Smooth high-refresh-rate decay for exhaust dynamic point lights
	for ex in _exhaust_channels:
		if not is_instance_valid(ex.omni_light):
			continue
		if ex.light_energy_current > 0.01:
			ex.light_energy_current = move_toward(ex.light_energy_current, 0.0, delta * 58.0)
			# High-frequency flicker during combustion flash
			var flicker := _rng.randf_range(0.82, 1.18)
			ex.omni_light.light_energy = ex.light_energy_current * flicker
			ex.omni_light.light_color = ex.omni_light.light_color.lerp(Color(1.0, 0.35, 0.05), delta * 22.0)
		else:
			ex.light_energy_current = 0.0
			ex.omni_light.light_energy = 0.0


# ==============================================================================
# TELEMETRY EXTRACTION (COMPATIBLE WITH ANY VEHICLE CONTROLLER)
# ==============================================================================
func _read_powertrain_telemetry(speed_mps: float, delta: float) -> Dictionary:
	var rpm: float = -1.0
	var throttle: float = 0.0
	var brake: float = 0.0
	var handbrake: float = 0.0
	var gear: int = _simulated_gear

	# Duck-type common vehicle properties without modifying anything
	for prop in ["rpm", "engine_rpm", "current_rpm"]:
		if prop in vehicle:
			rpm = float(vehicle.get(prop))
			break

	for prop in ["throttle", "throttle_input", "accel_input"]:
		if prop in vehicle:
			throttle = float(vehicle.get(prop))
			break
	if is_zero_approx(throttle) and "engine_force" in vehicle:
		throttle = clampf(float(vehicle.get("engine_force")) / 200.0, 0.0, 1.0)

	for prop in ["brake_input", "brake"]:
		if prop in vehicle:
			brake = clampf(float(vehicle.get(prop)), 0.0, 1.0)
			break

	for prop in ["handbrake", "ebrake", "handbrake_input"]:
		if prop in vehicle:
			handbrake = float(vehicle.get(prop))
			break

	for prop in ["gear", "current_gear"]:
		if prop in vehicle:
			gear = int(vehicle.get(prop))
			break

	# Synthesize realistic JDM close-ratio 6-speed RPM if the car doesn't expose RPM directly
	if rpm < 0.0:
		var gear_speed_spans := [0.0, 13.5, 22.0, 31.5, 42.0, 54.0, 68.0]
		var target_gear: int = 1
		for g in range(1, gear_speed_spans.size()):
			if speed_mps > gear_speed_spans[g] * 0.88:
				target_gear = g
		gear = target_gear
		_simulated_gear = gear
		var min_g_speed: float = gear_speed_spans[gear - 1] * 0.65
		var max_g_speed: float = gear_speed_spans[gear]
		var gear_ratio_norm := inverse_lerp(min_g_speed, max_g_speed, speed_mps)
		var target_rpm := lerpf(2200.0, max_engine_rpm, clampf(gear_ratio_norm, 0.0, 1.0))
		if throttle > 0.2:
			target_rpm += 650.0 * throttle
		_simulated_rpm = lerpf(_simulated_rpm, target_rpm, delta * 12.0)
		rpm = _simulated_rpm

	return {
		"rpm": rpm,
		"throttle": throttle,
		"brake": brake,
		"handbrake": handbrake,
		"gear": gear
	}


# ==============================================================================
# WHEEL DRIFT SMOKE & SKIDMARK RIBBON GENERATION
# ==============================================================================
func _update_wheels_vfx(speed_mps: float, slip_angle_deg: float, telemetry: Dictionary, delta: float) -> void:
	var space_state := get_world_3d().direct_space_state
	var now_sec: float = float(Time.get_ticks_msec()) * 0.001

	# Normalize speed factor (ramps up from min_speed_mps to 28 m/s ~ 100 km/h)
	var speed_factor := clampf(inverse_lerp(min_speed_mps, 28.0, speed_mps), 0.0, 1.0)
	
	# Lateral slip intensity (> 12 deg triggers drift VFX)
	var lateral_slip_intensity: float = 0.0
	if speed_mps >= min_speed_mps and slip_angle_deg >= slip_angle_threshold_deg:
		lateral_slip_intensity = clampf(
			inverse_lerp(slip_angle_threshold_deg, max_slip_angle_deg, slip_angle_deg),
			0.08, 1.0
		)

	for ch in _wheel_channels:
		if not is_instance_valid(ch.wheel_node):
			continue

		var is_grounded: bool = false
		var contact_point: Vector3 = Vector3.ZERO
		var contact_normal: Vector3 = Vector3.UP
		var wheel_spin_or_lock_intensity: float = 0.0

		if ch.is_vehicle_wheel:
			var vw := ch.wheel_node as VehicleWheel3D
			is_grounded = vw.is_in_contact()
			if is_grounded:
				contact_point = vw.get_contact_point()
				contact_normal = vw.get_contact_normal()
				#VehicleWheel3D.get_skidinfo() returns 0.0 on full traction loss, 1.0 on full grip
				var skid_grip: float = vw.get_skidinfo()
				if skid_grip < 0.82 and (speed_mps > 1.5 or absf(vw.get_rpm()) > 140.0):
					wheel_spin_or_lock_intensity = clampf(1.0 - skid_grip, 0.0, 1.0)
				
				# Check longitudinal wheel spin / brake lock via rotational vs linear speed mismatch
				var circumferential_speed := absf(vw.get_rpm() / 60.0) * TAU * ch.wheel_radius
				var long_diff := absf(circumferential_speed - speed_mps)
				if long_diff > 4.2:
					wheel_spin_or_lock_intensity = maxf(
						wheel_spin_or_lock_intensity,
						clampf((long_diff - 4.2) / 14.0, 0.0, 1.0)
					)
		else:
			# Raycast ground probe for custom vehicle controllers (excludes vehicle collision)
			var w_pos := ch.wheel_node.global_position
			var up_dir := vehicle.global_transform.basis.y.normalized()
			var ray_from := w_pos + up_dir * 0.25
			var ray_to := w_pos - up_dir * (ch.wheel_radius + 0.18)
			var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
			if vehicle is CollisionObject3D:
				query.exclude = [(vehicle as CollisionObject3D).get_rid()]
			var hit := space_state.intersect_ray(query)
			if not hit.is_empty():
				is_grounded = true
				contact_point = hit["position"]
				contact_normal = hit["normal"]
			
			# Detect brake lock or handbrake slide
			if telemetry["handbrake"] > 0.5 and speed_mps > min_speed_mps:
				wheel_spin_or_lock_intensity = 0.85
			elif telemetry["brake"] > 0.85 and speed_mps > 8.0:
				wheel_spin_or_lock_intensity = 0.65

		# Combine lateral drift slip + longitudinal wheelspin/lock
		var target_intensity: float = 0.0
		if is_grounded:
			var combined_slip := maxf(lateral_slip_intensity * (0.45 + 0.55 * speed_factor), wheel_spin_or_lock_intensity)
			target_intensity = clampf(combined_slip, 0.0, 1.0)

		ch.current_intensity = move_toward(ch.current_intensity, target_intensity, delta * 8.5)

		# Position smoke emitter directly at the tire contact patch
		if is_grounded:
			ch.smoke_emitter.global_position = contact_point + contact_normal * 0.05

		if ch.current_intensity > 0.02 and is_grounded:
			ch.smoke_emitter.emitting = true
			ch.smoke_emitter.amount_ratio = clampf(ch.current_intensity, 0.08, 1.0)
			# Scale opacity smoothly with both drift intensity and vehicle velocity
			var dynamic_opacity := clampf(ch.current_intensity * (0.4 + 0.6 * speed_factor) * 1.15, 0.05, 1.0)
			ch.smoke_material.set_shader_parameter("master_opacity", dynamic_opacity)
			_commit_skidmark_point(ch, contact_point, contact_normal, ch.current_intensity, now_sec)
		else:
			ch.smoke_emitter.emitting = false
			ch.smoke_emitter.amount_ratio = 0.0
			ch.was_skidding = false

		# Rebuild ImmediateMesh only when new quads were committed or periodically to evict expired quads
		if ch.mesh_dirty or (ch.buffer_count > 0 and (now_sec - ch.last_cleanup_time) > 2.0):
			_rebuild_wheel_skid_mesh(ch, now_sec)


func _commit_skidmark_point(ch: WheelVFXChannel, contact_pos: Vector3, normal: Vector3, intensity: float, now_sec: float) -> void:
	var elevated_pos := contact_pos + normal * ground_offset
	var move_dir := _computed_velocity.normalized()
	if move_dir.length_squared() < 0.01:
		move_dir = -vehicle.global_transform.basis.z.normalized()

	var right_vec := move_dir.cross(normal).normalized() * (skidmark_width * 0.5)
	var cur_left := elevated_pos - right_vec
	var cur_right := elevated_pos + right_vec

	if not ch.was_skidding:
		ch.was_skidding = true
		ch.last_contact_pos = elevated_pos
		ch.last_left_vtx = cur_left
		ch.last_right_vtx = cur_right
		return

	var dist_sq := elevated_pos.distance_squared_to(ch.last_contact_pos)
	if dist_sq < (skidmark_min_segment_dist * skidmark_min_segment_dist):
		return

	# Guard against teleportation or physics reset creating giant stretched quads
	if dist_sq > 9.0:
		ch.last_contact_pos = elevated_pos
		ch.last_left_vtx = cur_left
		ch.last_right_vtx = cur_right
		return

	# Write quad into pre-allocated circular ring buffer
	var seg: Dictionary = ch.segment_buffer[ch.buffer_head]
	seg["v0"] = ch.last_left_vtx
	seg["v1"] = ch.last_right_vtx
	seg["v2"] = cur_right
	seg["v3"] = cur_left
	seg["normal"] = normal
	seg["intensity"] = clampf(intensity, 0.15, 1.0)
	seg["spawn_time"] = now_sec

	ch.buffer_head = (ch.buffer_head + 1) % max_skid_segments_per_wheel
	ch.buffer_count = mini(ch.buffer_count + 1, max_skid_segments_per_wheel)
	ch.mesh_dirty = true

	ch.last_contact_pos = elevated_pos
	ch.last_left_vtx = cur_left
	ch.last_right_vtx = cur_right


func _rebuild_wheel_skid_mesh(ch: WheelVFXChannel, now_sec: float) -> void:
	ch.mesh_dirty = false
	ch.last_cleanup_time = now_sec

	if ch.buffer_count == 0:
		ch.skid_immediate_mesh.clear_surfaces()
		return

	var imm := ch.skid_immediate_mesh
	imm.clear_surfaces()

	var valid_quads: int = 0
	for i in range(ch.buffer_count):
		var seg: Dictionary = ch.segment_buffer[i]
		if (now_sec - float(seg["spawn_time"])) < skidmark_fade_time:
			valid_quads += 1

	if valid_quads == 0:
		ch.buffer_count = 0
		ch.buffer_head = 0
		return

	imm.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(ch.buffer_count):
		var seg: Dictionary = ch.segment_buffer[i]
		var spawn_t: float = float(seg["spawn_time"])
		if (now_sec - spawn_t) >= skidmark_fade_time:
			continue

		var v0: Vector3 = seg["v0"]
		var v1: Vector3 = seg["v1"]
		var v2: Vector3 = seg["v2"]
		var v3: Vector3 = seg["v3"]
		var n: Vector3 = seg["normal"]
		var col := Color(float(seg["intensity"]), 1.0, 1.0, 1.0)
		var uv2_time := Vector2(spawn_t, 0.0)

		# Triangle 1 (v0 -> v1 -> v2)
		imm.surface_set_normal(n)
		imm.surface_set_color(col)
		imm.surface_set_uv2(uv2_time)
		imm.surface_set_uv(Vector2(0.0, 0.0))
		imm.surface_add_vertex(v0)

		imm.surface_set_normal(n)
		imm.surface_set_color(col)
		imm.surface_set_uv2(uv2_time)
		imm.surface_set_uv(Vector2(1.0, 0.0))
		imm.surface_add_vertex(v1)

		imm.surface_set_normal(n)
		imm.surface_set_color(col)
		imm.surface_set_uv2(uv2_time)
		imm.surface_set_uv(Vector2(1.0, 1.0))
		imm.surface_add_vertex(v2)

		# Triangle 2 (v0 -> v2 -> v3)
		imm.surface_set_normal(n)
		imm.surface_set_color(col)
		imm.surface_set_uv2(uv2_time)
		imm.surface_set_uv(Vector2(0.0, 0.0))
		imm.surface_add_vertex(v0)

		imm.surface_set_normal(n)
		imm.surface_set_color(col)
		imm.surface_set_uv2(uv2_time)
		imm.surface_set_uv(Vector2(1.0, 1.0))
		imm.surface_add_vertex(v2)

		imm.surface_set_normal(n)
		imm.surface_set_color(col)
		imm.surface_set_uv2(uv2_time)
		imm.surface_set_uv(Vector2(0.0, 1.0))
		imm.surface_add_vertex(v3)

	imm.surface_end()


# ==============================================================================
# EXHAUST ANTI-LAG & POP-AND-BANG TRIGGER LOGIC
# ==============================================================================
func _evaluate_exhaust_backfire(telemetry: Dictionary, delta: float) -> void:
	_backfire_timer = maxf(0.0, _backfire_timer - delta)

	var rpm: float = telemetry["rpm"]
	var throttle: float = telemetry["throttle"]
	var gear: int = telemetry["gear"]

	var throttle_drop: float = _prev_throttle - throttle
	var did_downshift: bool = (gear < _prev_gear and gear > 0)
	var is_high_rpm: bool = rpm >= backfire_rpm_threshold

	# Trigger 1: High-RPM throttle lift-off (>6000 RPM overrun fuel cut / unburnt fuel ignition)
	var triggered_liftoff: bool = is_high_rpm and (throttle_drop > 0.25 and throttle < 0.35)
	
	# Trigger 2: Aggressive downshift blip
	var triggered_downshift: bool = did_downshift and (rpm >= backfire_rpm_threshold * 0.78)
	
	# Trigger 3: Secondary anti-lag crackles while coasting off-throttle above 6000 RPM
	var triggered_overrun_crackle: bool = is_high_rpm and (throttle < 0.08) and (_rng.randf() < delta * 5.5)

	if _backfire_timer <= 0.0 and (triggered_liftoff or triggered_downshift or triggered_overrun_crackle):
		var burst_intensity := clampf(inverse_lerp(backfire_rpm_threshold * 0.8, max_engine_rpm, rpm), 0.5, 1.0)
		trigger_exhaust_backfire(burst_intensity)
		_backfire_timer = backfire_cooldown * _rng.randf_range(0.85, 1.45)

	_prev_throttle = throttle
	_prev_gear = gear


## Public API: Can also be called manually from an external gearshift or rev-limiter signal.
func trigger_exhaust_backfire(intensity: float = 1.0) -> void:
	for ex in _exhaust_channels:
		if not is_instance_valid(ex.flame_emitter) or not is_instance_valid(ex.omni_light):
			continue
		ex.flame_emitter.restart()
		ex.flame_emitter.emitting = true
		
		# Alternate between rich hydrocarbon blue flash and bright orange fireball
		var is_blue_pop := _rng.randf() < 0.42
		if is_blue_pop:
			ex.omni_light.light_color = Color(0.38, 0.68, 1.0)
		else:
			ex.omni_light.light_color = Color(1.0, 0.52, 0.12)
			
		ex.light_energy_current = _rng.randf_range(4.5, 7.8) * intensity
		ex.omni_light.light_energy = ex.light_energy_current