class_name JDMSpeedometerHUD
extends CanvasLayer
## Production JDM Sports Instrument Cluster & Telemetry HUD (Defi / GReddy / Apexi Style)
## Designed for Godot 4.3 (Vulkan Forward+) - 100% Procedural Vector CanvasItem Rendering.
## Zero external texture or font dependencies, zero per-frame GC allocations, 144Hz+ ready.

@export_group("Vehicle Integration")
## Reference to the target vehicle node. Automatically discovers vehicle if left unassigned.
@export var target_vehicle: Node3D = null
## Automatically search parent tree, "vehicle" group, or scene root if target_vehicle is null.
@export var auto_discover_vehicle: bool = true

@export_group("Cluster Calibration")
@export var max_rpm: float = 9000.0
@export var redline_rpm: float = 7200.0
@export var rev_limit_rpm: float = 8500.0
@export var idle_rpm: float = 900.0
@export var min_boost_bar: float = -1.0
@export var max_boost_bar: float = 2.0

@export_group("Needle Stepper Physics")
## Natural frequency (stiffness) of the tachometer stepper motor.
@export var tach_stiffness: float = 34.0
## Damping ratio (< 1.0 = underdamped with slight mechanical overshoot, 1.0 = critically damped).
@export var tach_damping: float = 0.78
@export var boost_stiffness: float = 28.0
@export var boost_damping: float = 0.72

enum ClusterTheme {
	AMBER_TOKYO_DRIFT = 0, ## Classic 90s/00s incandescent/LED deep orange-red & amber
	CYBER_CYAN = 1,        ## Defi Advance BF ice blue / electric cyan with magenta accents
	PURE_WHITE_GLOW = 2    ## Modern Nismo / Blitz high-contrast pure white & crimson
}

@export_group("Visual Aesthetics")
@export var current_theme: ClusterTheme = ClusterTheme.AMBER_TOKYO_DRIFT:
	set(value):
		current_theme = value
		if is_instance_valid(_canvas):
			_canvas.queue_redraw()

@export var hud_scale: float = 1.0
@export var margin_offset: Vector2 = Vector2(42.0, 36.0)
@export var play_startup_ceremony: bool = true

# Internal drawing node
var _canvas: _JDMClusterCanvas = null
var _hud_visible: bool = true

# Telemetry state (raw & derived)
var _raw_speed_kmh: float = 0.0
var _raw_rpm: float = 0.0
var _raw_gear: int = 0
var _raw_boost_bar: float = -0.8
var _raw_lat_g: float = 0.0
var _raw_long_g: float = 0.0
var _raw_slip_factor: float = 0.0

# Smoothed & Physics-Simulated Telemetry State
var _display_speed_kmh: float = 0.0
var _tach_rpm: float = 0.0
var _tach_vel: float = 0.0
var _boost_bar: float = -0.8
var _boost_vel: float = 0.0
var _peak_boost_bar: float = -0.8
var _peak_rpm: float = 0.0
var _smooth_g: Vector2 = Vector2.ZERO
var _smooth_slip: float = 0.0

# Velocity delta tracking for fallback G-force calculation
var _prev_local_vel: Vector3 = Vector3.ZERO
var _has_prev_vel: bool = false

# Timers & Ceremony
var _startup_timer: float = 0.0
const CEREMONY_DURATION: float = 1.45
var _blink_accumulator: float = 0.0
var _gear_flash_timer: float = 0.0
var _last_gear: int = 0

# Theme Palettes
const THEME_PALETTES: Array[Dictionary] = [
	{ # AMBER_TOKYO_DRIFT
		"name": "TOKYO AMBER",
		"bezel_bg": Color(0.035, 0.03, 0.04, 0.92),
		"bezel_rim": Color(0.18, 0.14, 0.12, 0.95),
		"ambient_glow": Color(1.0, 0.28, 0.04, 0.18),
		"primary": Color(1.0, 0.36, 0.06, 1.0),
		"secondary": Color(1.0, 0.62, 0.15, 1.0),
		"tick_major": Color(1.0, 0.42, 0.08, 0.95),
		"tick_minor": Color(0.85, 0.30, 0.06, 0.65),
		"numbers": Color(1.0, 0.48, 0.12, 0.98),
		"redline": Color(1.0, 0.08, 0.08, 0.95),
		"redline_glow": Color(1.0, 0.05, 0.02, 0.28),
		"needle_core": Color(1.0, 0.92, 0.85, 1.0),
		"needle_glow": Color(1.0, 0.22, 0.02, 0.85),
		"lcd_bg": Color(0.06, 0.02, 0.01, 0.92),
		"lcd_ghost": Color(0.22, 0.07, 0.02, 0.35),
		"lcd_lit": Color(1.0, 0.42, 0.08, 1.0),
		"gear_lit": Color(1.0, 0.72, 0.15, 1.0)
	},
	{ # CYBER_CYAN
		"name": "DEFI CYBER CYAN",
		"bezel_bg": Color(0.02, 0.035, 0.055, 0.92),
		"bezel_rim": Color(0.12, 0.22, 0.28, 0.95),
		"ambient_glow": Color(0.0, 0.82, 1.0, 0.18),
		"primary": Color(0.05, 0.88, 1.0, 1.0),
		"secondary": Color(0.45, 0.95, 1.0, 1.0),
		"tick_major": Color(0.15, 0.92, 1.0, 0.95),
		"tick_minor": Color(0.08, 0.65, 0.82, 0.65),
		"numbers": Color(0.75, 0.98, 1.0, 0.98),
		"redline": Color(1.0, 0.12, 0.38, 0.95),
		"redline_glow": Color(1.0, 0.08, 0.32, 0.28),
		"needle_core": Color(1.0, 0.96, 0.98, 1.0),
		"needle_glow": Color(1.0, 0.12, 0.28, 0.88),
		"lcd_bg": Color(0.01, 0.04, 0.07, 0.92),
		"lcd_ghost": Color(0.04, 0.18, 0.24, 0.35),
		"lcd_lit": Color(0.12, 0.94, 1.0, 1.0),
		"gear_lit": Color(1.0, 0.22, 0.45, 1.0)
	},
	{ # PURE_WHITE_GLOW
		"name": "NISMO PURE WHITE",
		"bezel_bg": Color(0.03, 0.032, 0.038, 0.93),
		"bezel_rim": Color(0.22, 0.23, 0.25, 0.95),
		"ambient_glow": Color(0.85, 0.92, 1.0, 0.15),
		"primary": Color(0.95, 0.97, 1.0, 1.0),
		"secondary": Color(0.75, 0.82, 0.92, 1.0),
		"tick_major": Color(0.96, 0.98, 1.0, 0.96),
		"tick_minor": Color(0.62, 0.66, 0.72, 0.68),
		"numbers": Color(0.98, 0.98, 1.0, 0.98),
		"redline": Color(1.0, 0.10, 0.12, 0.96),
		"redline_glow": Color(1.0, 0.06, 0.08, 0.30),
		"needle_core": Color(1.0, 0.95, 0.95, 1.0),
		"needle_glow": Color(1.0, 0.08, 0.10, 0.90),
		"lcd_bg": Color(0.03, 0.035, 0.045, 0.92),
		"lcd_ghost": Color(0.14, 0.15, 0.18, 0.38),
		"lcd_lit": Color(0.96, 0.98, 1.0, 1.0),
		"gear_lit": Color(1.0, 0.16, 0.18, 1.0)
	}
]


func _ready() -> void:
	# Architectural requirement: Layer 15 (above 3D viewport, below pause menus)
	layer = 15

	# Instantiate dedicated full-rect Control node for ultra-fast _draw() batching
	_canvas = _JDMClusterCanvas.new(self)
	_canvas.name = "JDMClusterVectorCanvas"
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_canvas)

	if auto_discover_vehicle and target_vehicle == null:
		_discover_vehicle()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_H or event.physical_keycode == KEY_H:
			_hud_visible = not _hud_visible
			_canvas.visible = _hud_visible
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_C or event.physical_keycode == KEY_C:
			current_theme = ((int(current_theme) + 1) % THEME_PALETTES.size()) as ClusterTheme
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _hud_visible:
		return

	var safe_dt: float = clampf(delta, 0.0001, 0.05)
	_blink_accumulator += safe_dt

	if target_vehicle == null and auto_discover_vehicle:
		_discover_vehicle()

	# 1. Sample or synthesize vehicle telemetry
	_sample_vehicle_telemetry(safe_dt)

	# 2. Handle Defi-style Opening Ceremony (full needle sweep + LED check on startup)
	var target_rpm: float = _raw_rpm
	var target_boost: float = _raw_boost_bar
	var ceremony_active: bool = false

	if play_startup_ceremony and _startup_timer < CEREMONY_DURATION:
		_startup_timer += safe_dt
		ceremony_active = true
		var phase: float = _startup_timer / CEREMONY_DURATION
		if phase < 0.52:
			var sweep_up: float = smoothstep(0.0, 0.48, phase)
			target_rpm = lerpf(0.0, max_rpm, sweep_up)
			target_boost = lerpf(min_boost_bar, max_boost_bar, sweep_up)
			_display_speed_kmh = lerpf(0.0, 299.0, sweep_up)
		else:
			var sweep_down: float = smoothstep(0.52, 0.96, phase)
			target_rpm = lerpf(max_rpm, _raw_rpm, sweep_down)
			target_boost = lerpf(max_boost_bar, _raw_boost_bar, sweep_down)
			_display_speed_kmh = lerpf(299.0, _raw_speed_kmh, sweep_down)
	else:
		# Smooth digital speed readout with exponential decay filter
		_display_speed_kmh = lerpf(_display_speed_kmh, _raw_speed_kmh, 1.0 - exp(-18.0 * safe_dt))

	# 3. Critically / Under-damped Spring Physics for Tachometer Needle
	var tach_accel: float = (
		tach_stiffness * tach_stiffness * (target_rpm - _tach_rpm)
		- 2.0 * tach_damping * tach_stiffness * _tach_vel
	)
	_tach_vel += tach_accel * safe_dt
	_tach_rpm += _tach_vel * safe_dt

	# Micro-rebound & fuel-cut harmonic flutter when bouncing off rev limiter
	if not ceremony_active and _raw_rpm >= rev_limit_rpm - 65.0:
		var limiter_flutter: float = sin(_blink_accumulator * 92.0) * 145.0 + cos(_blink_accumulator * 137.0) * 65.0
		_tach_rpm += limiter_flutter * (1.0 - exp(-25.0 * safe_dt))
		_tach_vel = lerpf(_tach_vel, -absf(_tach_vel) * 0.4, 0.25)

	_tach_rpm = clampf(_tach_rpm, 0.0, max_rpm * 1.025)

	# 4. Spring Physics for Turbo Boost Needle
	var boost_accel: float = (
		boost_stiffness * boost_stiffness * (target_boost - _boost_bar)
		- 2.0 * boost_damping * boost_stiffness * _boost_vel
	)
	_boost_vel += boost_accel * safe_dt
	_boost_bar += _boost_vel * safe_dt
	_boost_bar = clampf(_boost_bar, min_boost_bar - 0.1, max_boost_bar + 0.15)

	# Track Peak Hold Markers (Defi Peak Hold feature)
	if not ceremony_active:
		if _tach_rpm > _peak_rpm:
			_peak_rpm = _tach_rpm
		else:
			_peak_rpm = maxf(_tach_rpm, _peak_rpm - 120.0 * safe_dt)

		if _boost_bar > _peak_boost_bar:
			_peak_boost_bar = _boost_bar
		else:
			_peak_boost_bar = maxf(_boost_bar, _peak_boost_bar - 0.06 * safe_dt)

	# 5. Smooth G-Force & Kamm's Circle Tire Slip Saturation
	var target_g_vec: Vector2 = Vector2(_raw_lat_g, _raw_long_g)
	_smooth_g = _smooth_g.lerp(target_g_vec, 1.0 - exp(-14.0 * safe_dt))
	_smooth_slip = lerpf(_smooth_slip, _raw_slip_factor, 1.0 - exp(-12.0 * safe_dt))

	# 6. Gear shift highlight flash
	if _raw_gear != _last_gear:
		_last_gear = _raw_gear
		_gear_flash_timer = 0.22
	elif _gear_flash_timer > 0.0:
		_gear_flash_timer = maxf(0.0, _gear_flash_timer - safe_dt)

	# Trigger 144Hz vector redraw
	_canvas.queue_redraw()


## Automatically locates `ArcadeSimVehicle` or any vehicle Node3D in the scene tree.
func _discover_vehicle() -> void:
	var parent: Node = get_parent()
	if parent is Node3D and _is_likely_vehicle(parent):
		target_vehicle = parent
		return

	# Check "vehicle" or "player_vehicle" groups
	for grp: StringName in [&"vehicle", &"player_vehicle", &"car", &"player"]:
		var grouped: Node = get_tree().get_first_node_in_group(grp)
		if grouped is Node3D:
			target_vehicle = grouped
			return

	# Search scene root children for ArcadeSimVehicle or VehicleBody3D
	var root: Node = get_tree().current_scene
	if root != null:
		if root is Node3D and _is_likely_vehicle(root):
			target_vehicle = root
			return
		for child: Node in root.find_children("*", "Node3D", true, false):
			if _is_likely_vehicle(child):
				target_vehicle = child as Node3D
				return


func _is_likely_vehicle(node: Node) -> bool:
	if node == null:
		return false
	if node is VehicleBody3D:
		return true
	var script_obj: Variant = node.get_script()
	if script_obj is Script and script_obj.resource_path.contains("ArcadeSimVehicle"):
		return true
	if node.name.contains("Vehicle") or node.name.contains("Car"):
		return true
	return (
		"current_speed_kmh" in node
		or "engine_rpm" in node
		or "current_gear" in node
		or "linear_velocity" in node
	)


## Duck-typed inspection of `target_vehicle` with physics-accurate fallbacks.
func _sample_vehicle_telemetry(dt: float) -> void:
	if not is_instance_valid(target_vehicle):
		# Standalone idle state when no vehicle is present
		_raw_speed_kmh = 0.0
		_raw_rpm = idle_rpm + sin(_blink_accumulator * 9.5) * 18.0
		_raw_gear = 0
		_raw_boost_bar = -0.72
		_raw_lat_g = 0.0
		_raw_long_g = 0.0
		_raw_slip_factor = 0.0
		return

	# 1. Local & World Velocity Extraction
	var world_vel: Vector3 = Vector3.ZERO
	if "linear_velocity" in target_vehicle:
		world_vel = target_vehicle.get("linear_velocity")
	elif "velocity" in target_vehicle:
		world_vel = target_vehicle.get("velocity")

	var local_vel: Vector3 = target_vehicle.global_transform.basis.inverse() * world_vel

	# 2. Speed (KM/H)
	if "current_speed_kmh" in target_vehicle:
		_raw_speed_kmh = absf(float(target_vehicle.get("current_speed_kmh")))
	elif "speed_kmh" in target_vehicle:
		_raw_speed_kmh = absf(float(target_vehicle.get("speed_kmh")))
	else:
		_raw_speed_kmh = world_vel.length() * 3.6

	# 3. Gear (-1 = Reverse, 0 = Neutral, 1..6 = Forward)
	if "current_gear" in target_vehicle:
		_raw_gear = int(target_vehicle.get("current_gear"))
	elif "gear" in target_vehicle:
		_raw_gear = int(target_vehicle.get("gear"))
	else:
		# Fallback automatic gear estimation from speed
		if _raw_speed_kmh < 1.5:
			_raw_gear = 0
		elif local_vel.z > 1.0:
			_raw_gear = -1
		else:
			_raw_gear = clampi(int(_raw_speed_kmh / 42.0) + 1, 1, 6)

	# 4. Engine RPM
	if "engine_rpm" in target_vehicle:
		_raw_rpm = float(target_vehicle.get("engine_rpm"))
	elif "rpm" in target_vehicle:
		_raw_rpm = float(target_vehicle.get("rpm"))
	else:
		# Synthesize realistic RPM curve from speed & gear if property is absent
		if _raw_gear == 0:
			_raw_rpm = idle_rpm
		elif _raw_gear == -1:
			_raw_rpm = clampf(idle_rpm + _raw_speed_kmh * 115.0, idle_rpm, rev_limit_rpm)
		else:
			var gear_top_speeds: Array[float] = [48.0, 86.0, 128.0, 174.0, 225.0, 285.0]
			var g_idx: int = clampi(_raw_gear - 1, 0, 5)
			var ratio_progress: float = _raw_speed_kmh / gear_top_speeds[g_idx]
			_raw_rpm = clampf(lerpf(idle_rpm * 1.35, rev_limit_rpm, ratio_progress), idle_rpm, max_rpm)

	# Add subtle mechanical idle hunt
	if _raw_rpm <= idle_rpm + 120.0:
		_raw_rpm += sin(_blink_accumulator * 14.0) * 16.0 + cos(_blink_accumulator * 23.0) * 9.0

	# 5. Turbo Boost Pressure (BAR: -0.8 vacuum to +1.6 bar positive pressure)
	if "turbo_boost_bar" in target_vehicle:
		_raw_boost_bar = float(target_vehicle.get("turbo_boost_bar"))
	elif "boost_bar" in target_vehicle:
		_raw_boost_bar = float(target_vehicle.get("boost_bar"))
	elif "turbo_boost" in target_vehicle:
		_raw_boost_bar = float(target_vehicle.get("turbo_boost"))
	else:
		var throttle: float = 0.0
		if "throttle_input" in target_vehicle:
			throttle = float(target_vehicle.get("throttle_input"))
		elif "throttle" in target_vehicle:
			throttle = float(target_vehicle.get("throttle"))
		elif "engine_force" in target_vehicle:
			throttle = clampf(float(target_vehicle.get("engine_force")) / 3000.0, 0.0, 1.0)
		else:
			throttle = clampf((_raw_rpm - idle_rpm) / (rev_limit_rpm - idle_rpm), 0.0, 1.0)

		var spool_factor: float = smoothstep(2200.0, 5800.0, _raw_rpm)
		if throttle > 0.15:
			_raw_boost_bar = lerpf(-0.45, 1.55 * spool_factor, throttle)
		else:
			# Engine vacuum on closed throttle / overrun
			var vacuum_depth: float = lerpf(-0.62, -0.84, clampf(_raw_rpm / 7000.0, 0.0, 1.0))
			_raw_boost_bar = vacuum_depth

	# 6. Lateral & Longitudinal G-Force
	if "lateral_g" in target_vehicle:
		_raw_lat_g = float(target_vehicle.get("lateral_g"))
	elif "angular_velocity" in target_vehicle:
		var ang_vel: Vector3 = target_vehicle.get("angular_velocity")
		var steer: float = 0.0
		if "steering" in target_vehicle:
			steer = float(target_vehicle.get("steering"))
		elif "steer_angle" in target_vehicle:
			steer = float(target_vehicle.get("steer_angle"))
		# Centripetal acceleration a_c = v * omega_y + steering influence
		var centripetal_accel: float = (-local_vel.z * ang_vel.y) + (steer * local_vel.length() * 0.35)
		_raw_lat_g = clampf(centripetal_accel / 9.81, -2.5, 2.5)
	elif _has_prev_vel:
		_raw_lat_g = clampf(((local_vel.x - _prev_local_vel.x) / dt) / 9.81, -2.5, 2.5)

	if "longitudinal_g" in target_vehicle:
		_raw_long_g = float(target_vehicle.get("longitudinal_g"))
	elif _has_prev_vel:
		# Forward acceleration in Godot -Z space mapped to longitudinal G
		var accel_z: float = -(local_vel.z - _prev_local_vel.z) / dt
		_raw_long_g = clampf(accel_z / 9.81, -2.5, 2.5)

	_prev_local_vel = local_vel
	_has_prev_vel = true

	# 7. Kamm's Circle Tire Slip Factor (Grip Saturation 0.0 -> 1.0+)
	if "tire_slip_factor" in target_vehicle:
		_raw_slip_factor = clampf(float(target_vehicle.get("tire_slip_factor")), 0.0, 1.0)
	elif "kamm_slip_factor" in target_vehicle:
		_raw_slip_factor = clampf(float(target_vehicle.get("kamm_slip_factor")), 0.0, 1.0)
	elif "slip_ratio" in target_vehicle:
		_raw_slip_factor = clampf(float(target_vehicle.get("slip_ratio")), 0.0, 1.0)
	else:
		# Derive grip saturation from combined G-vector + lateral slip angle
		var g_Load: float = Vector2(_raw_lat_g, _raw_long_g).length() / 1.35
		var slip_angle_ratio: float = 0.0
		if world_vel.length() > 2.5:
			slip_angle_ratio = absf(local_vel.x) / (world_vel.length() * 0.45)
		_raw_slip_factor = clampf(maxf(g_Load, slip_angle_ratio), 0.0, 1.0)


# ==============================================================================
# INTERNAL PROCEDURAL VECTOR RENDERER (144Hz Zero-Allocation CanvasItem)
# ==============================================================================
class _JDMClusterCanvas extends Control:
	var _hud: JDMSpeedometerHUD

	# Pre-allocated polygon buffers to eliminate per-frame GC allocations
	var _needle_poly: PackedVector2Array = PackedVector2Array()
	var _needle_glow_poly: PackedVector2Array = PackedVector2Array()
	var _seg_poly: PackedVector2Array = PackedVector2Array()

	# Tachometer sweep geometry (Angles in radians: 135 deg bottom-left to 405 deg bottom-right)
	const TACH_START_ANGLE: float = deg_to_rad(135.0)
	const TACH_END_ANGLE: float = deg_to_rad(405.0)
	const TACH_SWEEP: float = TACH_END_ANGLE - TACH_START_ANGLE # 270 degrees

	# Turbo Boost Gauge sweep geometry (130 deg to 350 deg)
	const BOOST_START_ANGLE: float = deg_to_rad(135.0)
	const BOOST_END_ANGLE: float = deg_to_rad(365.0)
	const BOOST_SWEEP: float = BOOST_END_ANGLE - BOOST_START_ANGLE

	# 7-Segment Bitmask Table (bits: 0=Top, 1=TopRight, 2=BotRight, 3=Bottom, 4=BotLeft, 5=TopLeft, 6=Middle)
	const DIGIT_MASKS: PackedByteArray = [
		0b0111111, # 0
		0b0000110, # 1
		0b1011011, # 2
		0b1001111, # 3
		0b1100110, # 4
		0b1101101, # 5
		0b1111101, # 6
		0b0000111, # 7
		0b1111111, # 8
		0b1101111  # 9
	]

	func _init(hud_owner: JDMSpeedometerHUD) -> void:
		_hud = hud_owner
		_needle_poly.resize(4)
		_needle_glow_poly.resize(4)
		_seg_poly.resize(6)

	func _draw() -> void:
		var vp_size: Vector2 = get_viewport_rect().size
		var ui_scale: float = clampf(minf(vp_size.x / 1920.0, vp_size.y / 1080.0), 0.65, 1.8) * _hud.hud_scale
		var pal: Dictionary = JDMSpeedometerHUD.THEME_PALETTES[_hud.current_theme]
		var font: Font = ThemeDB.fallback_font

		# Anchor positions in bottom-right JDM cockpit layout
		var tach_radius: float = 148.0 * ui_scale
		var tach_center: Vector2 = Vector2(
			vp_size.x - _hud.margin_offset.x * ui_scale - tach_radius,
			vp_size.y - _hud.margin_offset.y * ui_scale - tach_radius
		)

		var boost_radius: float = 74.0 * ui_scale
		var boost_center: Vector2 = tach_center + Vector2(-tach_radius * 1.54, tach_radius * 0.28)

		var g_radius: float = 56.0 * ui_scale
		var g_center: Vector2 = boost_center + Vector2(-boost_radius * 1.15, -boost_radius * 1.25)

		# Draw Satellite Gauges first so Main Tachometer bezel overlaps cleanly like a real pod
		_draw_g_force_meter(g_center, g_radius, ui_scale, pal, font)
		_draw_boost_gauge(boost_center, boost_radius, ui_scale, pal, font)
		_draw_main_tachometer(tach_center, tach_radius, ui_scale, pal, font)
		_draw_shift_light_bar(tach_center + Vector2(0.0, -tach_radius - 26.0 * ui_scale), tach_radius, ui_scale, pal, font)
		_draw_status_footer(tach_center, tach_radius, boost_center, boost_radius, ui_scale, pal, font)

	# --------------------------------------------------------------------------
	# 1. MAIN DEFI/APEXI TACHOMETER & DIGITAL SPEEDO / GEAR CLUSTER
	# --------------------------------------------------------------------------
	func _draw_main_tachometer(center: Vector2, radius: float, s: float, pal: Dictionary, font: Font) -> void:
		# Outer ambient cockpit glow
		draw_circle(center, radius * 1.07, pal["ambient_glow"])
		# Machined aluminum outer bezel + smoked acrylic lens
		draw_circle(center, radius * 1.03, pal["bezel_rim"])
		draw_circle(center, radius, pal["bezel_bg"])

		# Subtle internal honey-comb/carbon depth rings
		draw_arc(center, radius * 0.96, 0.0, TAU, 96, Color(1, 1, 1, 0.05), 1.5 * s, true)
		draw_arc(center, radius * 0.88, TACH_START_ANGLE, TACH_END_ANGLE, 80, pal["primary"] * Color(1, 1, 1, 0.16), 2.5 * s, true)
		draw_arc(center, radius * 0.62, TACH_START_ANGLE, TACH_END_ANGLE, 64, Color(1, 1, 1, 0.06), 1.2 * s, true)

		# Redline Warning Zone Arc (7200 to 9000 RPM)
		var redline_ratio: float = clampf(_hud.redline_rpm / _hud.max_rpm, 0.0, 1.0)
		var limit_ratio: float = clampf(_hud.rev_limit_rpm / _hud.max_rpm, 0.0, 1.0)
		var red_start_ang: float = TACH_START_ANGLE + TACH_SWEEP * redline_ratio
		var limit_ang: float = TACH_START_ANGLE + TACH_SWEEP * limit_ratio

		# Incandescent Redline Glow Band
		draw_arc(center, radius * 0.895, red_start_ang, TACH_END_ANGLE, 36, pal["redline_glow"], 14.0 * s, true)
		draw_arc(center, radius * 0.935, red_start_ang, limit_ang, 28, pal["redline"] * Color(1, 1, 1, 0.75), 5.0 * s, true)
		draw_arc(center, radius * 0.935, limit_ang, TACH_END_ANGLE, 20, pal["redline"], 7.5 * s, true)

		# Dynamic Illuminated Sweep Trail following the needle
		var current_ratio: float = clampf(_hud._tach_rpm / _hud.max_rpm, 0.0, 1.0)
		var needle_ang: float = TACH_START_ANGLE + TACH_SWEEP * current_ratio
		if current_ratio > 0.01:
			var trail_col: Color = pal["primary"] * Color(1, 1, 1, 0.22)
			if _hud._tach_rpm >= _hud.redline_rpm:
				trail_col = pal["redline"] * Color(1, 1, 1, 0.34)
			draw_arc(center, radius * 0.84, TACH_START_ANGLE, needle_ang, 48, trail_col, 9.0 * s, true)

		# Precision Tick Marks (0 to 9000 RPM in 200 RPM increments)
		var total_k: int = int(_hud.max_rpm / 1000.0)
		var sub_divisions: int = 5 # 200 RPM per sub-tick
		var total_ticks: int = total_k * sub_divisions

		for i: int in range(total_ticks + 1):
			var t_ratio: float = float(i) / float(total_ticks)
			var ang: float = TACH_START_ANGLE + TACH_SWEEP * t_ratio
			var dir: Vector2 = Vector2.from_angle(ang)
			var rpm_val: float = t_ratio * _hud.max_rpm
			var is_in_redline: bool = rpm_val >= _hud.redline_rpm - 10.0

			if i % sub_divisions == 0:
				# Major 1000 RPM Tick
				var p_outer: Vector2 = center + dir * (radius * 0.92)
				var p_inner: Vector2 = center + dir * (radius * 0.79)
				var tick_col: Color = pal["redline"] if is_in_redline else pal["tick_major"]
				draw_line(p_inner, p_outer, tick_col, 3.2 * s, true)

				# Dial Numeral (0..9)
				var num_str: String = str(int(i / sub_divisions))
				var num_pos: Vector2 = center + dir * (radius * 0.685)
				var f_size: int = maxi(10, int(19.0 * s))
				var str_size: Vector2 = font.get_string_size(num_str, HORIZONTAL_ALIGNMENT_CENTER, -1, f_size)
				var draw_pos: Vector2 = num_pos + Vector2(-str_size.x * 0.5, str_size.y * 0.34)
				var num_col: Color = pal["redline"] if is_in_redline else pal["numbers"]
				draw_string(font, draw_pos, num_str, HORIZONTAL_ALIGNMENT_LEFT, -1, f_size, num_col)
			else:
				# Minor 200 RPM Tick (with 500 RPM mid-tick emphasis)
				var is_half: bool = (i % sub_divisions == 2) or (i % sub_divisions == 3)
				var inner_len: float = 0.84 if is_half else 0.865
				var p_outer: Vector2 = center + dir * (radius * 0.92)
				var p_inner: Vector2 = center + dir * (radius * inner_len)
				var tick_col: Color = pal["redline"] * Color(1, 1, 1, 0.85) if is_in_redline else pal["tick_minor"]
				draw_line(p_inner, p_outer, tick_col, 1.6 * s, true)

		# Peak-Hold RPM Memory Marker (Small triangular Defi indicator on inner rim)
		var peak_ratio: float = clampf(_hud._peak_rpm / _hud.max_rpm, 0.0, 1.0)
		if peak_ratio > 0.05:
			var peak_ang: float = TACH_START_ANGLE + TACH_SWEEP * peak_ratio
			var peak_dir: Vector2 = Vector2.from_angle(peak_ang)
			var p_tip: Vector2 = center + peak_dir * (radius * 0.78)
			var p_base: Vector2 = center + peak_dir * (radius * 0.73)
			draw_line(p_base, p_tip, pal["secondary"], 2.5 * s, true)

		# Dial Branding & Unit Labels
		var brand_fsize: int = maxi(8, int(12.0 * s))
		_draw_centered_text(font, center + Vector2(0.0, -radius * 0.38), "DEFI-LINK // STEPMASTER", brand_fsize, pal["secondary"] * Color(1, 1, 1, 0.85))
		_draw_centered_text(font, center + Vector2(0.0, -radius * 0.27), "x1000 r/min", maxi(8, int(10.5 * s)), pal["numbers"] * Color(1, 1, 1, 0.65))

		# Center Digital Gear Indicator Window (Top-Center of inner dial)
		_draw_gear_indicator(center + Vector2(0.0, radius * 0.25), s, pal, font)

		# Bottom-Right Inset Digital 7-Segment Speedometer LCD (KM/H)
		_draw_digital_speedo_panel(center + Vector2(radius * 0.02, radius * 0.64), s, pal, font)

		# Fluorescent Balanced Counter-Weighted Tachometer Needle
		_draw_fluorescent_needle(
			center,
			needle_ang,
			radius * 0.89,
			radius * 0.19,
			5.2 * s,
			1.6 * s,
			pal["needle_core"],
			pal["needle_glow"],
			s
		)

		# Center Brushed Aluminum Hub Cap
		draw_circle(center, 18.0 * s, Color(0.08, 0.08, 0.10, 1.0))
		draw_arc(center, 18.0 * s, 0.0, TAU, 32, pal["bezel_rim"], 2.2 * s, true)
		draw_circle(center, 7.0 * s, pal["primary"] * Color(1, 1, 1, 0.75))
		draw_circle(center, 3.5 * s, Color(0.15, 0.15, 0.18, 1.0))

	# --------------------------------------------------------------------------
	# 2. DIGITAL GEAR INDICATOR & 7-SEGMENT SPEEDOMETER READOUT
	# --------------------------------------------------------------------------
	func _draw_gear_indicator(pos: Vector2, s: float, pal: Dictionary, font: Font) -> void:
		var box_size: Vector2 = Vector2(44.0 * s, 48.0 * s)
		var rect: Rect2 = Rect2(pos - box_size * 0.5, box_size)

		# Recessed LCD bezel
		draw_rect(rect, pal["lcd_bg"], true)
		var border_col: Color = pal["primary"] * Color(1, 1, 1, 0.45)
		if _hud._tach_rpm >= _hud.redline_rpm:
			border_col = pal["redline"]
		draw_rect(rect, border_col, false, 1.8 * s)

		# Gear string ('R', 'N', '1'..'6')
		var gear_str: String = "N"
		if _hud._raw_gear < 0:
			gear_str = "R"
		elif _hud._raw_gear > 0:
			gear_str = str(_hud._raw_gear)

		var gear_col: Color = pal["gear_lit"]
		if _hud._raw_gear == 0:
			gear_col = Color(0.25, 0.95, 0.45, 1.0) # Classic JDM Neutral emerald green
		elif _hud._raw_gear < 0:
			gear_col = pal["redline"]
		elif _hud._tach_rpm >= _hud.redline_rpm:
			gear_col = pal["redline"]

		# Flash bright white briefly on gear shift
		if _hud._gear_flash_timer > 0.0:
			var flash_t: float = _hud._gear_flash_timer / 0.22
			gear_col = gear_col.lerp(Color.WHITE, flash_t * 0.85)

		var g_fsize: int = maxi(14, int(34.0 * s))
		_draw_centered_text(font, pos + Vector2(0.0, 12.0 * s), gear_str, g_fsize, gear_col)
		_draw_centered_text(font, pos + Vector2(0.0, -box_size.y * 0.5 - 5.0 * s), "GEAR", maxi(7, int(9.0 * s)), pal["secondary"] * Color(1, 1, 1, 0.7))

	func _draw_digital_speedo_panel(pos: Vector2, s: float, pal: Dictionary, font: Font) -> void:
		var panel_size: Vector2 = Vector2(132.0 * s, 50.0 * s)
		var rect: Rect2 = Rect2(pos - panel_size * 0.5, panel_size)

		# Smoked LCD cutout frame
		draw_rect(rect, pal["lcd_bg"], true)
		draw_rect(rect, pal["primary"] * Color(1, 1, 1, 0.5), false, 1.6 * s)

		# 3-Digit 7-Segment Vector Speed Readout (0 - 999 KM/H)
		var spd_int: int = clampi(roundi(_hud._display_speed_kmh), 0, 999)
		var hundreds: int = (spd_int / 100) % 10
		var tens: int = (spd_int / 10) % 10
		var ones: int = spd_int % 10

		var seg_size: Vector2 = Vector2(19.0 * s, 32.0 * s)
		var seg_thick: float = 3.8 * s
		var spacing: float = 25.0 * s
		var base_x: float = rect.position.x + 14.0 * s
		var base_y: float = rect.position.y + 9.0 * s

		# Draw ghost 888 segments + active illuminated segments
		_draw_7seg_digit(Vector2(base_x, base_y), seg_size, seg_thick, hundreds if spd_int >= 100 else -1, pal["lcd_lit"], pal["lcd_ghost"])
		_draw_7seg_digit(Vector2(base_x + spacing, base_y), seg_size, seg_thick, tens if spd_int >= 10 else -1, pal["lcd_lit"], pal["lcd_ghost"])
		_draw_7seg_digit(Vector2(base_x + spacing * 2.0, base_y), seg_size, seg_thick, ones, pal["lcd_lit"], pal["lcd_ghost"])

		# KM/H Unit Tag inside LCD window
		var unit_fsize: int = maxi(8, int(11.0 * s))
		draw_string(
			font,
			Vector2(rect.end.x - 36.0 * s, rect.end.y - 8.0 * s),
			"km/h",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			unit_fsize,
			pal["secondary"]
		)

	# --------------------------------------------------------------------------
	# 3. SEQUENTIAL LED SHIFT LIGHT BAR (Green -> Amber -> Blinking Red)
	# --------------------------------------------------------------------------
	func _draw_shift_light_bar(center: Vector2, tach_radius: float, s: float, pal: Dictionary, font: Font) -> void:
		var bar_w: float = tach_radius * 1.32
		var bar_h: float = 20.0 * s
		var rect: Rect2 = Rect2(center - Vector2(bar_w * 0.5, bar_h * 0.5), Vector2(bar_w, bar_h))

		# Shift Light Pod Housing
		draw_rect(rect, pal["bezel_bg"], true)
		draw_rect(rect, pal["bezel_rim"], false, 2.0 * s)

		const LED_COUNT: int = 10
		var shift_start_rpm: float = 4800.0
		var rpm_span: float = maxf(100.0, _hud.rev_limit_rpm - shift_start_rpm)
		var shift_progress: float = clampf((_hud._tach_rpm - shift_start_rpm) / rpm_span, 0.0, 1.0)
		var is_over_rev: bool = _hud._tach_rpm >= _hud.rev_limit_rpm - 80.0
		var blink_on: bool = fmod(_hud._blink_accumulator * 18.0, 1.0) < 0.55

		var pad_x: float = 8.0 * s
		var usable_w: float = bar_w - pad_x * 2.0
		var led_w: float = (usable_w / float(LED_COUNT)) - 4.0 * s
		var led_h: float = bar_h - 8.0 * s

		for i: int in range(LED_COUNT):
			var threshold: float = float(i + 1) / float(LED_COUNT)
			var is_lit: bool = shift_progress >= (threshold - 0.05)

			var led_col: Color
			if i < 4:
				led_col = Color(0.12, 0.96, 0.36, 1.0) # Sequential Green
			elif i < 7:
				led_col = Color(1.0, 0.76, 0.08, 1.0)  # Sequential Yellow/Amber
			else:
				led_col = Color(1.0, 0.08, 0.12, 1.0)  # High-intensity Redline LED

			var led_x: float = rect.position.x + pad_x + float(i) * (led_w + 4.0 * s) + 2.0 * s
			var led_rect: Rect2 = Rect2(Vector2(led_x, rect.position.y + 4.0 * s), Vector2(led_w, led_h))

			if is_over_rev:
				is_lit = blink_on
				led_col = Color(1.0, 0.12, 0.16, 1.0)

			if is_lit:
				# Outer bloom + vivid LED core
				draw_rect(led_rect.grow(2.5 * s), led_col * Color(1, 1, 1, 0.35), true)
				draw_rect(led_rect, led_col, true)
				draw_rect(led_rect.grow(-1.5 * s), Color(1.0, 0.96, 0.92, 0.65), true)
			else:
				draw_rect(led_rect, led_col * Color(0.18, 0.18, 0.18, 0.55), true)

		# "SHIFT" Warning Strobe Badge when at Rev Limiter
		if is_over_rev and blink_on:
			var warn_pos: Vector2 = center + Vector2(0.0, -bar_h * 1.15)
			_draw_centered_text(font, warn_pos, ">> REV LIMIT // SHIFT <<", maxi(9, int(13.0 * s)), Color(1.0, 0.18, 0.18, 1.0))

	# --------------------------------------------------------------------------
	# 4. AUXILIARY MINI-GAUGE: TURBO BOOST (-1.0 to +2.0 BAR)
	# --------------------------------------------------------------------------
	func _draw_boost_gauge(center: Vector2, radius: float, s: float, pal: Dictionary, font: Font) -> void:
		draw_circle(center, radius * 1.06, pal["ambient_glow"] * Color(1, 1, 1, 0.75))
		draw_circle(center, radius * 1.04, pal["bezel_rim"])
		draw_circle(center, radius, pal["bezel_bg"])

		var boost_span: float = _hud.max_boost_bar - _hud.min_boost_bar # 3.0 BAR total (-1.0 to +2.0)
		var zero_ratio: float = clampf((0.0 - _hud.min_boost_bar) / boost_span, 0.0, 1.0)
		var warn_ratio: float = clampf((1.4 - _hud.min_boost_bar) / boost_span, 0.0, 1.0)

		var zero_ang: float = BOOST_START_ANGLE + BOOST_SWEEP * zero_ratio
		var warn_ang: float = BOOST_START_ANGLE + BOOST_SWEEP * warn_ratio

		# Vacuum Zone Arc (-1.0 to 0.0 BAR)
		draw_arc(center, radius * 0.88, BOOST_START_ANGLE, zero_ang, 24, pal["secondary"] * Color(1, 1, 1, 0.35), 3.5 * s, true)
		# Positive Boost Arc (0.0 to +1.4 BAR)
		draw_arc(center, radius * 0.88, zero_ang, warn_ang, 32, pal["primary"] * Color(1, 1, 1, 0.5), 3.5 * s, true)
		# Overboost High-Pressure Zone (+1.4 to +2.0 BAR)
		draw_arc(center, radius * 0.88, warn_ang, BOOST_END_ANGLE, 20, pal["redline"], 5.0 * s, true)

		# Tick Marks (-1.0 to +2.0 BAR in 0.1 BAR steps)
		var total_steps: int = 30
		for i: int in range(total_steps + 1):
			var r: float = float(i) / float(total_steps)
			var ang: float = BOOST_START_ANGLE + BOOST_SWEEP * r
			var dir: Vector2 = Vector2.from_angle(ang)
			var bar_val: float = lerpf(_hud.min_boost_bar, _hud.max_boost_bar, r)
			var is_high_boost: bool = bar_val >= 1.4 - 0.01

			if i % 5 == 0:
				var is_whole_bar: bool = (i % 10 == 0)
				var inner_f: float = 0.74 if is_whole_bar else 0.79
				var t_col: Color = pal["redline"] if is_high_boost else pal["tick_major"]
				draw_line(center + dir * (radius * inner_f), center + dir * (radius * 0.91), t_col, (2.4 if is_whole_bar else 1.8) * s, true)

				if is_whole_bar:
					var lbl: String = str(roundi(bar_val))
					var l_pos: Vector2 = center + dir * (radius * 0.58)
					_draw_centered_text(font, l_pos + Vector2(0.0, 4.0 * s), lbl, maxi(8, int(12.5 * s)), t_col)
			else:
				var t_col: Color = pal["redline"] * Color(1, 1, 1, 0.7) if is_high_boost else pal["tick_minor"]
				draw_line(center + dir * (radius * 0.84), center + dir * (radius * 0.91), t_col, 1.1 * s, true)

		# Peak Boost Hold Marker on rim
		var peak_r: float = clampf((_hud._peak_boost_bar - _hud.min_boost_bar) / boost_span, 0.0, 1.0)
		var peak_ang: float = BOOST_START_ANGLE + BOOST_SWEEP * peak_r
		var peak_dir: Vector2 = Vector2.from_angle(peak_ang)
		draw_line(center + peak_dir * (radius * 0.71), center + peak_dir * (radius * 0.78), pal["secondary"], 2.2 * s, true)

		# Boost Gauge Titles & Digital Sub-Readout
		_draw_centered_text(font, center + Vector2(0.0, -radius * 0.25), "TURBO", maxi(7, int(10.0 * s)), pal["secondary"])
		_draw_centered_text(font, center + Vector2(0.0, radius * 0.38), "x100 kPa / BAR", maxi(7, int(8.5 * s)), pal["numbers"] * Color(1, 1, 1, 0.65))

		var boost_str: String = "%+.2f" % _hud._boost_bar
		var b_col: Color = pal["redline"] if _hud._boost_bar >= 1.4 else pal["lcd_lit"]
		_draw_centered_text(font, center + Vector2(0.0, radius * 0.62), boost_str, maxi(9, int(13.5 * s)), b_col)

		# Dynamic Boost Sweep Needle
		var boost_ratio: float = clampf((_hud._boost_bar - _hud.min_boost_bar) / boost_span, 0.0, 1.0)
		var needle_ang: float = BOOST_START_ANGLE + BOOST_SWEEP * boost_ratio
		_draw_fluorescent_needle(
			center,
			needle_ang,
			radius * 0.86,
			radius * 0.18,
			3.8 * s,
			1.2 * s,
			pal["needle_core"],
			pal["needle_glow"],
			s
		)

		draw_circle(center, 10.5 * s, Color(0.08, 0.08, 0.10, 1.0))
		draw_arc(center, 10.5 * s, 0.0, TAU, 24, pal["bezel_rim"], 1.6 * s, true)
		draw_circle(center, 4.0 * s, pal["primary"])

	# --------------------------------------------------------------------------
	# 5. LATERAL G-FORCE CROSSHAIR & KAMM'S CIRCLE TIRE FRICTION BUBBLE
	# --------------------------------------------------------------------------
	func _draw_g_force_meter(center: Vector2, radius: float, s: float, pal: Dictionary, font: Font) -> void:
		draw_circle(center, radius * 1.05, pal["bezel_rim"])
		draw_circle(center, radius, pal["bezel_bg"])

		# Kamm's Circle Grip Saturation Outer Ring (Green -> Yellow -> Vivid Red on Tire Slip)
		var slip: float = clampf(_hud._smooth_slip, 0.0, 1.0)
		var slip_col: Color
		if slip < 0.55:
			slip_col = Color(0.15, 0.95, 0.45, 0.85).lerp(Color(1.0, 0.82, 0.12, 0.9), slip / 0.55)
		else:
			slip_col = Color(1.0, 0.82, 0.12, 0.9).lerp(Color(1.0, 0.10, 0.15, 1.0), (slip - 0.55) / 0.45)

		# Background grip ring + Dynamic Kamm's saturation arc
		draw_arc(center, radius * 0.91, 0.0, TAU, 48, Color(1, 1, 1, 0.08), 4.2 * s, true)
		var slip_sweep: float = TAU * slip
		if slip_sweep > 0.02:
			draw_arc(center, radius * 0.91, -PI * 0.5, -PI * 0.5 + slip_sweep, 48, slip_col, 4.5 * s, true)

		# Reference 0.5G and 1.0G Friction Rings & Crosshair Axes
		draw_arc(center, radius * 0.72, 0.0, TAU, 36, pal["primary"] * Color(1, 1, 1, 0.32), 1.2 * s, true)
		draw_arc(center, radius * 0.36, 0.0, TAU, 28, pal["primary"] * Color(1, 1, 1, 0.20), 1.0 * s, true)

		var axis_col: Color = pal["primary"] * Color(1, 1, 1, 0.28)
		draw_line(center + Vector2(-radius * 0.78, 0.0), center + Vector2(radius * 0.78, 0.0), axis_col, 1.1 * s)
		draw_line(center + Vector2(0.0, -radius * 0.78), center + Vector2(0.0, radius * 0.78), axis_col, 1.1 * s)

		# Plot Dynamic G-Force Friction Bubble (1.5G full-scale deflection)
		var g_norm: Vector2 = (_hud._smooth_g / 1.5).limit_length(1.0)
		var bubble_pos: Vector2 = center + Vector2(g_norm.x, -g_norm.y) * (radius * 0.72)

		# Vector Line from origin to G-bubble + glowing friction dot
		draw_line(center, bubble_pos, slip_col * Color(1, 1, 1, 0.55), 1.8 * s, true)
		draw_circle(bubble_pos, 7.5 * s, slip_col * Color(1, 1, 1, 0.32))
		draw_circle(bubble_pos, 4.2 * s, slip_col)
		draw_circle(bubble_pos, 1.8 * s, Color.WHITE)

		# Telemetry Labels
		_draw_centered_text(font, center + Vector2(0.0, -radius * 0.52), "G-SENSOR", maxi(7, int(8.5 * s)), pal["secondary"] * Color(1, 1, 1, 0.8))
		var lat_g_str: String = "%.1fG" % absf(_hud._smooth_g.x)
		_draw_centered_text(font, center + Vector2(0.0, radius * 0.55), lat_g_str, maxi(8, int(10.5 * s)), pal["numbers"])
		var slip_pct_str: String = "GRIP %02d%%" % roundi((1.0 - slip * 0.65) * 100.0)
		_draw_centered_text(font, center + Vector2(0.0, radius + 13.0 * s), slip_pct_str, maxi(7, int(9.5 * s)), slip_col)

	# --------------------------------------------------------------------------
	# 6. HOTKEY & THEME TELEMETRY FOOTER
	# --------------------------------------------------------------------------
	func _draw_status_footer(tach_c: Vector2, tach_r: float, boost_c: Vector2, boost_r: float, s: float, pal: Dictionary, font: Font) -> void:
		var footer_pos: Vector2 = Vector2(boost_c.x - boost_r * 0.9, tach_c.y + tach_r - 4.0 * s)
		var info_str: String = "[H] HUD  [C] %s" % pal["name"]
		draw_string(
			font,
			footer_pos,
			info_str,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			maxi(8, int(10.5 * s)),
			pal["secondary"] * Color(1, 1, 1, 0.58)
		)

	# --------------------------------------------------------------------------
	# VECTOR PRIMITIVE HELPERS (Fluorescent Needles & 7-Segment Polygons)
	# --------------------------------------------------------------------------
	func _draw_fluorescent_needle(
		center: Vector2,
		angle: float,
		tip_len: float,
		tail_len: float,
		base_half_w: float,
		tip_half_w: float,
		core_col: Color,
		glow_col: Color,
		s: float
	) -> void:
		var dir: Vector2 = Vector2.from_angle(angle)
		var nrm: Vector2 = Vector2(-dir.y, dir.x)

		var p_tail: Vector2 = center - dir * tail_len
		var p_tip: Vector2 = center + dir * tip_len

		# Outer fluorescent acrylic glow quad
		var glow_expand: float = 3.2 * s
		_needle_glow_poly[0] = p_tail + nrm * (base_half_w + glow_expand)
		_needle_glow_poly[1] = p_tip + nrm * (tip_half_w + glow_expand * 0.7)
		_needle_glow_poly[2] = p_tip - nrm * (tip_half_w + glow_expand * 0.7)
		_needle_glow_poly[3] = p_tail - nrm * (base_half_w + glow_expand)
		draw_colored_polygon(_needle_glow_poly, glow_col * Color(1, 1, 1, 0.42))

		# Crisp illuminated needle body
		_needle_poly[0] = p_tail + nrm * base_half_w
		_needle_poly[1] = p_tip + nrm * tip_half_w
		_needle_poly[2] = p_tip - nrm * tip_half_w
		_needle_poly[3] = p_tail - nrm * base_half_w
		draw_colored_polygon(_needle_poly, glow_col)

		# Hot incandescent center spine
		draw_line(center - dir * (tail_len * 0.45), p_tip, core_col, 1.8 * s, true)

	func _draw_7seg_digit(
		origin: Vector2,
		d_size: Vector2,
		thick: float,
		val: int,
		lit_col: Color,
		ghost_col: Color
	) -> void:
		var mask: int = DIGIT_MASKS[clampi(val, 0, 9)] if val >= 0 else 0
		var w: float = d_size.x
		var h: float = d_size.y
		var half_h: float = h * 0.5
		var gap: float = thick * 0.24

		# Segment 0: Top Horizontal
		_draw_7seg_bar(origin + Vector2(gap, 0.0), origin + Vector2(w - gap, 0.0), thick, (mask & (1 << 0)) != 0, lit_col, ghost_col)
		# Segment 1: Top-Right Vertical
		_draw_7seg_bar(origin + Vector2(w, gap), origin + Vector2(w, half_h - gap), thick, (mask & (1 << 1)) != 0, lit_col, ghost_col)
		# Segment 2: Bottom-Right Vertical
		_draw_7seg_bar(origin + Vector2(w, half_h + gap), origin + Vector2(w, h - gap), thick, (mask & (1 << 2)) != 0, lit_col, ghost_col)
		# Segment 3: Bottom Horizontal
		_draw_7seg_bar(origin + Vector2(gap, h), origin + Vector2(w - gap, h), thick, (mask & (1 << 3)) != 0, lit_col, ghost_col)
		# Segment 4: Bottom-Left Vertical
		_draw_7seg_bar(origin + Vector2(0.0, half_h + gap), origin + Vector2(0.0, h - gap), thick, (mask & (1 << 4)) != 0, lit_col, ghost_col)
		# Segment 5: Top-Left Vertical
		_draw_7seg_bar(origin + Vector2(0.0, gap), origin + Vector2(0.0, half_h - gap), thick, (mask & (1 << 5)) != 0, lit_col, ghost_col)
		# Segment 6: Middle Horizontal
		_draw_7seg_bar(origin + Vector2(gap, half_h), origin + Vector2(w - gap, half_h), thick, (mask & (1 << 6)) != 0, lit_col, ghost_col)

	func _draw_7seg_bar(
		p0: Vector2,
		p1: Vector2,
		thick: float,
		is_lit: bool,
		lit_col: Color,
		ghost_col: Color
	) -> void:
		var dir: Vector2 = (p1 - p0).normalized()
		var nrm: Vector2 = Vector2(-dir.y, dir.x)
		var ht: float = thick * 0.5
		# Slight italic JDM LCD slant (shear X by -12% of Y)
		var p0_s: Vector2 = p0 + Vector2(-p0.y * 0.08, 0.0)
		var p1_s: Vector2 = p1 + Vector2(-p1.y * 0.08, 0.0)

		_seg_poly[0] = p0_s
		_seg_poly[1] = p0_s + dir * ht + nrm * ht
		_seg_poly[2] = p1_s - dir * ht + nrm * ht
		_seg_poly[3] = p1_s
		_seg_poly[4] = p1_s - dir * ht - nrm * ht
		_seg_poly[5] = p0_s + dir * ht - nrm * ht

		draw_colored_polygon(_seg_poly, lit_col if is_lit else ghost_col)

	func _draw_centered_text(font: Font, pos: Vector2, text: String, f_size: int, col: Color) -> void:
		var sz: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, f_size)
		draw_string(font, pos + Vector2(-sz.x * 0.5, sz.y * 0.32), text, HORIZONTAL_ALIGNMENT_LEFT, -1, f_size, col)