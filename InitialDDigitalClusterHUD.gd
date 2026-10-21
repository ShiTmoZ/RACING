class_name InitialDDigitalClusterHUD
extends CanvasLayer

# ==============================================================================
# INITIAL D DIGITAL CLUSTER HUD (AE86 / ARCADE STAGE STYLE)
# Target: Godot 4.3 | Zero-Allocation 144+ FPS Procedural Vector HUD
# ==============================================================================

@export var hud_scale: float = 1.0:
	set(value):
		hud_scale = clampf(value, 0.5, 2.5)
		if is_instance_valid(_canvas):
			_canvas.hud_scale = hud_scale
			_canvas.recompute_geometry()
			_canvas.queue_redraw()

@export var anchor_offset: Vector2 = Vector2(-420.0, -250.0):
	set(value):
		anchor_offset = value
		if is_instance_valid(_canvas):
			_canvas.anchor_offset = anchor_offset
			_canvas.recompute_geometry()
			_canvas.queue_redraw()

@export var shift_light_rpm: float = 7800.0:
	set(value):
		shift_light_rpm = value
		if is_instance_valid(_canvas):
			_canvas.shift_light_rpm = shift_light_rpm

var _canvas: _ClusterCanvas


func _init() -> void:
	layer = 10


func _ready() -> void:
	_canvas = _ClusterCanvas.new()
	_canvas.name = "ClusterCanvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.hud_scale = hud_scale
	_canvas.anchor_offset = anchor_offset
	_canvas.shift_light_rpm = shift_light_rpm
	add_child(_canvas)


## Primary Telemetry Entry Point called by MountAkinaTouge
func update_telemetry(
	speed_kmh: float,
	rpm: float,
	max_rpm: float,
	gear: int,
	throttle: float,
	brake: float,
	drift_angle_deg: float,
	in_gutter: bool
) -> void:
	if is_instance_valid(_canvas):
		_canvas.ingest_telemetry(
			speed_kmh, rpm, max_rpm, gear, throttle, brake, drift_angle_deg, in_gutter
		)


# ==============================================================================
# INTERNAL ZERO-ALLOCATION RENDERING CONTROL
# ==============================================================================
class _ClusterCanvas extends Control:
	# --- Configuration ---
	var hud_scale: float = 1.0
	var anchor_offset: Vector2 = Vector2(-420.0, -250.0)
	var shift_light_rpm: float = 7800.0

	# --- Telemetry State ---
	var _speed_kmh: float = 0.0
	var _rpm: float = 0.0
	var _max_rpm: float = 9000.0
	var _gear: int = 1
	var _throttle: float = 0.0
	var _brake: float = 0.0
	var _drift_angle_deg: float = 0.0
	var _in_gutter: bool = false

	# --- Computed G-Force / Dynamics State ---
	var _prev_speed_mps: float = 0.0
	var _g_force_vec: Vector2 = Vector2.ZERO
	var _smoothed_g_vec: Vector2 = Vector2.ZERO
	var _smoothed_rpm: float = 0.0
	var _strobe_accum: float = 0.0
	var _chime_strobe: bool = false

	# --- Cached Fonts & Colors ---
	var _font: Font
	
	const COL_BG_DARK := Color(0.04, 0.05, 0.06, 0.92)
	const COL_BG_BEZEL := Color(0.12, 0.14, 0.17, 0.95)
	const COL_PANEL_LINE := Color(0.22, 0.26, 0.30, 1.0)
	const COL_TEXT_LABEL := Color(0.65, 0.75, 0.80, 0.90)
	
	const COL_SEG_ON := Color(0.10, 1.00, 0.78, 1.0)      # Authentic VFD Cyan-Green
	const COL_SEG_GLOW := Color(0.10, 1.00, 0.78, 0.22)
	const COL_SEG_OFF := Color(0.06, 0.15, 0.14, 0.45)
	
	const COL_GEAR_ON := Color(1.00, 0.72, 0.10, 1.0)     # JDM Amber
	const COL_GEAR_OFF := Color(0.18, 0.13, 0.04, 0.45)
	
	const COL_RPM_GREEN := Color(0.15, 0.95, 0.35, 1.0)
	const COL_RPM_YELLOW := Color(1.00, 0.82, 0.10, 1.0)
	const COL_RPM_RED := Color(1.00, 0.15, 0.20, 1.0)
	const COL_RPM_OFF := Color(0.10, 0.13, 0.15, 0.65)
	
	const COL_GUTTER_ON := Color(0.15, 0.85, 1.00, 1.0)
	const COL_GUTTER_OFF := Color(0.08, 0.14, 0.18, 0.5)
	
	const COL_DRIFT_GOOD := Color(1.00, 0.65, 0.00, 1.0)
	const COL_DRIFT_EXTREME := Color(1.00, 0.15, 0.25, 1.0)

	# --- 7-Segment Bitmasks ---
	# Bit order: 0:Top, 1:TopRight, 2:BotRight, 3:Bot, 4:BotLeft, 5:TopLeft, 6:Mid
	const DIGIT_MASKS: PackedInt32Array = [
		0b0111111, # 0
		0b0000110, # 1
		0b1011011, # 2
		0b1001111, # 3
		0b1100110, # 4
		0b1101101, # 5
		0b1111101, # 6
		0b0000111, # 7
		0b1111111, # 8
		0b1101111, # 9
		0b0000000, # 10: Blank
		0b0110111, # 11: 'N' (approx 7-seg or custom)
		0b1010000  # 12: 'r'
	]

	# --- Pre-allocated Geometry Buffers (Zero per-frame allocations) ---
	const RPM_BAR_COUNT: int = 45
	var _rpm_polys: Array[PackedVector2Array] = []
	var _rpm_colors_on: PackedColorArray = PackedColorArray()
	
	# 3 Speed Digits x 7 Segments
	var _speed_seg_polys: Array[PackedVector2Array] = []
	# 1 Gear Digit x 7 Segments + Custom R/N overlays
	var _gear_seg_polys: Array[PackedVector2Array] = []
	var _gear_diag_poly: PackedVector2Array = PackedVector2Array()
	
	# Static Panel Polygons
	var _bg_outer_poly: PackedVector2Array = PackedVector2Array()
	var _bg_inner_poly: PackedVector2Array = PackedVector2Array()
	var _bg_border_line: PackedVector2Array = PackedVector2Array()
	var _gear_box_rect: Rect2 = Rect2()
	var _speed_box_rect: Rect2 = Rect2()
	var _gutter_box_rect: Rect2 = Rect2()
	
	# Telemetry Sub-gauges
	var _g_meter_center: Vector2 = Vector2.ZERO
	var _g_meter_radius: float = 42.0
	var _drift_arc_center: Vector2 = Vector2.ZERO
	var _drift_arc_radius: float = 54.0
	var _shift_lamp_center: Vector2 = Vector2.ZERO
	var _throttle_bar_rect: Rect2 = Rect2()
	var _brake_bar_rect: Rect2 = Rect2()
	
	# Dynamic Reusable Scratch Polygons (Mutated in-place)
	var _scratch_quad: PackedVector2Array = PackedVector2Array()
	var _drift_needle_poly: PackedVector2Array = PackedVector2Array()
	
	# Pre-cached Positions for Text
	var _pos_kmh_label: Vector2 = Vector2.ZERO
	var _pos_gear_label: Vector2 = Vector2.ZERO
	var _pos_rpm_label: Vector2 = Vector2.ZERO
	var _pos_g_label: Vector2 = Vector2.ZERO
	var _pos_drift_label: Vector2 = Vector2.ZERO
	var _pos_gutter_label: Vector2 = Vector2.ZERO
	var _pos_shift_label: Vector2 = Vector2.ZERO
	var _pos_thr_label: Vector2 = Vector2.ZERO
	var _pos_brk_label: Vector2 = Vector2.ZERO
	var _rpm_tick_positions: PackedVector2Array = PackedVector2Array()
	const RPM_TICK_STRINGS: PackedStringArray = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]


	func _ready() -> void:
		_font = ThemeDB.fallback_font
		_allocate_buffers()
		recompute_geometry()
		resized.connect(recompute_geometry)


	func _allocate_buffers() -> void:
		# RPM Polygons
		_rpm_polys.resize(RPM_BAR_COUNT)
		_rpm_colors_on.resize(RPM_BAR_COUNT)
		for i in range(RPM_BAR_COUNT):
			var poly := PackedVector2Array()
			poly.resize(4)
			_rpm_polys[i] = poly
			
			var ratio := float(i) / float(RPM_BAR_COUNT)
			if ratio < 0.68:
				_rpm_colors_on[i] = COL_RPM_GREEN
			elif ratio < 0.84:
				_rpm_colors_on[i] = COL_RPM_YELLOW
			else:
				_rpm_colors_on[i] = COL_RPM_RED

		# Speed 7-Segment Polygons (3 digits * 7 segments = 21)
		_speed_seg_polys.resize(21)
		for i in range(21):
			var poly := PackedVector2Array()
			poly.resize(6)
			_speed_seg_polys[i] = poly

		# Gear 7-Segment Polygons (7 segments)
		_gear_seg_polys.resize(7)
		for i in range(7):
			var poly := PackedVector2Array()
			poly.resize(6)
			_gear_seg_polys[i] = poly

		_gear_diag_poly.resize(4)
		_scratch_quad.resize(4)
		_drift_needle_poly.resize(3)
		_bg_outer_poly.resize(7)
		_bg_inner_poly.resize(7)
		_bg_border_line.resize(8)
		_rpm_tick_positions.resize(10)


	func ingest_telemetry(
		speed_kmh: float,
		rpm: float,
		max_rpm: float,
		gear: int,
		throttle: float,
		brake: float,
		drift_angle_deg: float,
		in_gutter: bool
	) -> void:
		_speed_kmh = maxf(0.0, speed_kmh)
		_rpm = clampf(rpm, 0.0, 12000.0)
		_max_rpm = maxf(1000.0, max_rpm)
		_gear = clampi(gear, -1, 6)
		_throttle = clampf(throttle, 0.0, 1.0)
		_brake = clampf(brake, 0.0, 1.0)
		_drift_angle_deg = clampf(drift_angle_deg, -90.0, 90.0)
		_in_gutter = in_gutter


	func _process(delta: float) -> void:
		if delta <= 0.0:
			return

		# Smooth RPM slightly for ultra-fluid 144Hz bar motion
		_smoothed_rpm = lerpf(_smoothed_rpm, _rpm, minf(1.0, delta * 35.0))

		# Compute Longitudinal & Lateral G-Forces from available telemetry
		var speed_mps := _speed_kmh / 3.6
		var accel_mps2 := (speed_mps - _prev_speed_mps) / delta
		_prev_speed_mps = speed_mps

		var long_g := clampf(accel_mps2 / 9.81, -1.8, 1.8)
		# Centripetal lateral G estimation from speed and slip/drift angle
		var lat_g := clampf(
			(speed_mps / 22.0) * sin(deg_to_rad(_drift_angle_deg * 1.6)),
			-1.8,
			1.8
		)
		_g_force_vec.x = lat_g
		_g_force_vec.y = -long_g # Braking pitches forward (up), Accel pitches back (down)
		if _g_force_vec.length_squared() > 1.96: # Clamp to 1.4G circle
			_g_force_vec = _g_force_vec.normalized() * 1.4

		_smoothed_g_vec = _smoothed_g_vec.lerp(_g_force_vec, minf(1.0, delta * 14.0))

		# High-frequency shift light & AE86 speed chime strobe (16 Hz)
		_strobe_accum += delta * 16.0
		_chime_strobe = (int(_strobe_accum) & 1) == 0

		queue_redraw()


	func recompute_geometry() -> void:
		if _rpm_polys.is_empty():
			return

		var vp_size := get_viewport_rect().size
		if vp_size.x <= 0.0 or vp_size.y <= 0.0:
			vp_size = Vector2(1920.0, 1080.0)

		var origin := vp_size + (anchor_offset * hud_scale)
		var s := hud_scale

		# 1. Main Cluster Chassis Polygons
		var p0 := origin + Vector2(-10.0, 10.0) * s
		var p1 := origin + Vector2(30.0, -20.0) * s
		var p2 := origin + Vector2(395.0, -20.0) * s
		var p3 := origin + Vector2(405.0, 15.0) * s
		var p4 := origin + Vector2(405.0, 215.0) * s
		var p5 := origin + Vector2(-85.0, 215.0) * s
		var p6 := origin + Vector2(-85.0, 55.0) * s

		_bg_outer_poly[0] = p0
		_bg_outer_poly[1] = p1
		_bg_outer_poly[2] = p2
		_bg_outer_poly[3] = p3
		_bg_outer_poly[4] = p4
		_bg_outer_poly[5] = p5
		_bg_outer_poly[6] = p6

		var inset := 5.0 * s
		_bg_inner_poly[0] = p0 + Vector2(inset, 0.0)
		_bg_inner_poly[1] = p1 + Vector2(inset * 0.5, inset)
		_bg_inner_poly[2] = p2 + Vector2(-inset, inset)
		_bg_inner_poly[3] = p3 + Vector2(-inset, inset * 0.5)
		_bg_inner_poly[4] = p4 + Vector2(-inset, -inset)
		_bg_inner_poly[5] = p5 + Vector2(inset, -inset)
		_bg_inner_poly[6] = p6 + Vector2(inset, inset * 0.5)

		for i in range(7):
			_bg_border_line[i] = _bg_inner_poly[i]
		_bg_border_line[7] = _bg_inner_poly[0]

		# 2. Curved Horizontal RPM Bar (AE86 Digital Curve: sweep up-right then flat)
		var rpm_start := origin + Vector2(15.0, 58.0) * s
		var bar_pitch := 8.1 * s
		var bar_w := 5.4 * s
		var bar_h := 25.0 * s

		for i in range(RPM_BAR_COUNT):
			var t := float(i) / float(RPM_BAR_COUNT - 1)
			# Classic Initial D / AE86 curve: rises steeply for first 35%, then levels out
			var curve_y := -pow(1.0 - clampf(t / 0.42, 0.0, 1.0), 2.2) * 32.0 * s
			var bx := rpm_start.x + float(i) * bar_pitch
			var by := rpm_start.y - curve_y

			# Slight slant on early segments
			var slant := lerpf(6.5 * s, 2.0 * s, clampf(t * 2.2, 0.0, 1.0))

			var poly := _rpm_polys[i]
			poly[0] = Vector2(bx + slant, by - bar_h)
			poly[1] = Vector2(bx + slant + bar_w, by - bar_h)
			poly[2] = Vector2(bx + bar_w, by)
			poly[3] = Vector2(bx, by)

			# Tick labels every 5 bars (0..9 x1000 RPM)
			if i % 5 == 0:
				var tick_idx: int = i / 5
				if tick_idx < 10:
					_rpm_tick_positions[tick_idx] = Vector2(bx - 2.0 * s, by + 15.0 * s)

		# Last tick (9)
		_rpm_tick_positions[9] = Vector2(
			rpm_start.x + float(RPM_BAR_COUNT - 1) * bar_pitch + 2.0 * s,
			rpm_start.y + 15.0 * s
		)

		# 3. 7-Segment Speedometer (3 Digits: Hundreds, Tens, Ones)
		_speed_box_rect = Rect2(origin + Vector2(138.0, 82.0) * s, Vector2(198.0, 96.0) * s)
		var spd_origin := origin + Vector2(152.0, 94.0) * s
		var dig_w := 42.0 * s
		var dig_h := 72.0 * s
		var dig_thick := 9.2 * s
		var dig_slant := 8.0 * s
		var dig_spacing := 54.0 * s

		for d in range(3):
			var d_pos := spd_origin + Vector2(float(d) * dig_spacing, 0.0)
			_build_7seg_digit(_speed_seg_polys, d * 7, d_pos, dig_w, dig_h, dig_thick, dig_slant)

		# 4. Gear Indicator Box & 7-Segment
		_gear_box_rect = Rect2(origin + Vector2(56.0, 82.0) * s, Vector2(72.0, 96.0) * s)
		var gear_pos := origin + Vector2(73.0, 102.0) * s
		var gw := 36.0 * s
		var gh := 62.0 * s
		var gt := 8.0 * s
		var gs := 6.0 * s
		_build_7seg_digit(_gear_seg_polys, 0, gear_pos, gw, gh, gt, gs)

		# Diagonal leg for 'R' and 'N' inside gear box
		_gear_diag_poly[0] = gear_pos + Vector2(gw * 0.45, gh * 0.52)
		_gear_diag_poly[1] = gear_pos + Vector2(gw * 0.45 + gt, gh * 0.52)
		_gear_diag_poly[2] = gear_pos + Vector2(gw - gt * 0.2, gh - gt * 0.3)
		_gear_diag_poly[3] = gear_pos + Vector2(gw - gt * 1.2, gh - gt * 0.3)

		# 5. Shift Indicator Lamp
		_shift_lamp_center = origin + Vector2(368.0, 114.0) * s

		# 6. G-Force Ball Meter & Drift Angle Gauge (Left Wing)
		_g_meter_center = origin + Vector2(-26.0, 115.0) * s
		_g_meter_radius = 40.0 * s

		_drift_arc_center = origin + Vector2(-26.0, 172.0) * s
		_drift_arc_radius = 42.0 * s

		# 7. Throttle / Brake Bars & Gutter Indicator
		_throttle_bar_rect = Rect2(origin + Vector2(346.0, 150.0) * s, Vector2(14.0, 52.0) * s)
		_brake_bar_rect = Rect2(origin + Vector2(368.0, 150.0) * s, Vector2(14.0, 52.0) * s)
		_gutter_box_rect = Rect2(origin + Vector2(56.0, 184.0) * s, Vector2(115.0, 20.0) * s)

		# 8. Cached Text Positions
		_pos_kmh_label = origin + Vector2(288.0, 198.0) * s
		_pos_gear_label = origin + Vector2(72.0, 96.0) * s
		_pos_rpm_label = origin + Vector2(180.0, 74.0) * s
		_pos_g_label = origin + Vector2(-52.0, 68.0) * s
		_pos_drift_label = origin + Vector2(-58.0, 204.0) * s
		_pos_gutter_label = origin + Vector2(65.0, 199.0) * s
		_pos_shift_label = origin + Vector2(348.0, 92.0) * s
		_pos_thr_label = origin + Vector2(346.0, 146.0) * s
		_pos_brk_label = origin + Vector2(368.0, 146.0) * s


	func _build_7seg_digit(
		target_array: Array[PackedVector2Array],
		base_idx: int,
		pos: Vector2,
		w: float,
		h: float,
		t: float,
		slant: float
	) -> void:
		var half_h := h * 0.5
		var ht := t * 0.5
		var g := t * 0.18 # Segment bevel gap

		# Helper lambda-free inline calculations for slanted coordinates
		# x_slant(y) = slant * (1.0 - y / h)
		# Segment 0: Top Horizontal
		_set_hex_h(target_array[base_idx + 0], pos, 0.0, w, 0.0, t, h, slant, g)
		# Segment 6: Middle Horizontal
		_set_hex_h(target_array[base_idx + 6], pos, 0.0, w, half_h - ht, t, h, slant, g)
		# Segment 3: Bottom Horizontal
		_set_hex_h(target_array[base_idx + 3], pos, 0.0, w, h - t, t, h, slant, g)

		# Segment 5: Top-Left Vertical
		_set_hex_v(target_array[base_idx + 5], pos, 0.0, t, 0.0, half_h, h, slant, g)
		# Segment 1: Top-Right Vertical
		_set_hex_v(target_array[base_idx + 1], pos, w - t, t, 0.0, half_h, h, slant, g)
		# Segment 4: Bottom-Left Vertical
		_set_hex_v(target_array[base_idx + 4], pos, 0.0, t, half_h, half_h, h, slant, g)
		# Segment 2: Bottom-Right Vertical
		_set_hex_v(target_array[base_idx + 2], pos, w - t, t, half_h, half_h, h, slant, g)


	func _set_hex_h(
		poly: PackedVector2Array,
		origin: Vector2,
		x: float,
		w: float,
		y: float,
		t: float,
		total_h: float,
		slant: float,
		gap: float
	) -> void:
		var ht := t * 0.5
		var y_top := y
		var y_mid := y + ht
		var y_bot := y + t

		var s_top := slant * (1.0 - y_top / total_h)
		var s_mid := slant * (1.0 - y_mid / total_h)
		var s_bot := slant * (1.0 - y_bot / total_h)

		var x_left := x + ht + gap
		var x_right := x + w - ht - gap

		poly[0] = origin + Vector2(x + gap + s_mid, y_mid)
		poly[1] = origin + Vector2(x_left + s_top, y_top)
		poly[2] = origin + Vector2(x_right + s_top, y_top)
		poly[3] = origin + Vector2(x + w - gap + s_mid, y_mid)
		poly[4] = origin + Vector2(x_right + s_bot, y_bot)
		poly[5] = origin + Vector2(x_left + s_bot, y_bot)


	func _set_hex_v(
		poly: PackedVector2Array,
		origin: Vector2,
		x: float,
		t: float,
		y: float,
		seg_h: float,
		total_h: float,
		slant: float,
		gap: float
	) -> void:
		var ht := t * 0.5
		var y_top := y + ht + gap
		var y_tip_t := y + gap
		var y_bot := y + seg_h - ht - gap
		var y_tip_b := y + seg_h - gap

		var s_tip_t := slant * (1.0 - y_tip_t / total_h)
		var s_top := slant * (1.0 - y_top / total_h)
		var s_bot := slant * (1.0 - y_bot / total_h)
		var s_tip_b := slant * (1.0 - y_tip_b / total_h)

		poly[0] = origin + Vector2(x + ht + s_tip_t, y_tip_t)
		poly[1] = origin + Vector2(x + t + s_top, y_top)
		poly[2] = origin + Vector2(x + t + s_bot, y_bot)
		poly[3] = origin + Vector2(x + ht + s_tip_b, y_tip_b)
		poly[4] = origin + Vector2(x + s_bot, y_bot)
		poly[5] = origin + Vector2(x + s_top, y_top)


	func _draw() -> void:
		var s := hud_scale
		var font_sz_sm := int(11.0 * s)
		var font_sz_md := int(13.0 * s)

		# 1. Draw Main Cluster Housing
		draw_colored_polygon(_bg_outer_poly, COL_BG_BEZEL)
		draw_colored_polygon(_bg_inner_poly, COL_BG_DARK)
		draw_polyline(_bg_border_line, COL_PANEL_LINE, 2.0 * s, true)

		# Sub-panel recesses
		draw_rect(_speed_box_rect, Color(0.02, 0.04, 0.04, 0.95), true)
		draw_rect(_speed_box_rect, COL_PANEL_LINE, false, 1.5 * s)
		draw_rect(_gear_box_rect, Color(0.04, 0.03, 0.02, 0.95), true)
		draw_rect(_gear_box_rect, COL_PANEL_LINE, false, 1.5 * s)

		# 2. Draw Curved LED RPM Bar (0 to 9,000 RPM)
		var rpm_norm := clampf(_smoothed_rpm / _max_rpm, 0.0, 1.0)
		var active_bars := int(roundf(rpm_norm * float(RPM_BAR_COUNT)))
		var is_redline_strobe := (_rpm >= shift_light_rpm) and _chime_strobe

		for i in range(RPM_BAR_COUNT):
			if i < active_bars:
				var c := _rpm_colors_on[i]
				if is_redline_strobe and i >= int(RPM_BAR_COUNT * 0.82):
					c = Color(1.0, 1.0, 0.85, 1.0)
				draw_colored_polygon(_rpm_polys[i], c)
			else:
				draw_colored_polygon(_rpm_polys[i], COL_RPM_OFF)

		# RPM Scale Numbers
		for i in range(10):
			var tick_col := COL_RPM_RED if i >= 8 else COL_TEXT_LABEL
			draw_string(
				_font,
				_rpm_tick_positions[i],
				RPM_TICK_STRINGS[i],
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				font_sz_md,
				tick_col
			)
		draw_string(
			_font,
			_pos_rpm_label,
			"x1000 r/min",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_sz_sm,
			COL_TEXT_LABEL
		)

		# 3. Draw 7-Segment Digital Speedometer (km/h)
		var spd_int := clampi(int(roundf(_speed_kmh)), 0, 999)
		var d_hund: int = (spd_int / 100) if spd_int >= 100 else 10
		var d_tens: int = ((spd_int / 10) % 10) if spd_int >= 10 else 10
		var d_ones: int = spd_int % 10

		_draw_7seg_digit(_speed_seg_polys, 0, DIGIT_MASKS[d_hund], COL_SEG_ON, COL_SEG_OFF)
		_draw_7seg_digit(_speed_seg_polys, 7, DIGIT_MASKS[d_tens], COL_SEG_ON, COL_SEG_OFF)
		_draw_7seg_digit(_speed_seg_polys, 14, DIGIT_MASKS[d_ones], COL_SEG_ON, COL_SEG_OFF)

		draw_string(
			_font,
			_pos_kmh_label,
			"km/h",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_sz_md,
			COL_SEG_ON
		)

		# 4. Draw Digital Gear Indicator (R, N, 1, 2, 3, 4, 5, 6)
		draw_string(
			_font,
			_pos_gear_label,
			"GEAR",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_sz_sm,
			COL_TEXT_LABEL
		)

		var gear_mask: int = 0
		var draw_diag: bool = false
		if _gear < 0:
			# 'R' representation (Top, TopRight, Mid, BotLeft, TopLeft + Diagonal leg)
			gear_mask = 0b1110011
			draw_diag = true
		elif _gear == 0:
			# 'N' representation (Left & Right verticals + Diagonal)
			gear_mask = 0b0110110
			draw_diag = true
		else:
			var g_idx := clampi(_gear, 1, 9)
			gear_mask = DIGIT_MASKS[g_idx]

		_draw_7seg_digit(_gear_seg_polys, 0, gear_mask, COL_GEAR_ON, COL_GEAR_OFF)
		if draw_diag:
			draw_colored_polygon(_gear_diag_poly, COL_GEAR_ON)

		# 5. Draw Shift Indicator Lamp (Aggressive Red/Yellow Strobe > 7,800 RPM)
		draw_string(
			_font,
			_pos_shift_label,
			"SHIFT",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_sz_sm,
			COL_TEXT_LABEL
		)
		var lamp_r := 13.0 * s
		draw_circle(_shift_lamp_center, lamp_r + 2.0 * s, COL_PANEL_LINE)
		if _rpm >= shift_light_rpm:
			var shift_col := COL_RPM_RED if _chime_strobe else COL_RPM_YELLOW
			var glow_col := Color(shift_col.r, shift_col.g, shift_col.b, 0.38)
			draw_circle(_shift_lamp_center, lamp_r * 1.65, glow_col)
			draw_circle(_shift_lamp_center, lamp_r, shift_col)
			draw_circle(_shift_lamp_center, lamp_r * 0.45, Color.WHITE)
		else:
			draw_circle(_shift_lamp_center, lamp_r, Color(0.20, 0.05, 0.06, 0.9))

		# 6. Draw Fujiwara Telemetry: G-Force Ball Meter
		draw_string(
			_font,
			_pos_g_label,
			"G-SENSOR",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_sz_sm,
			COL_TEXT_LABEL
		)
		draw_circle(_g_meter_center, _g_meter_radius, Color(0.02, 0.04, 0.05, 0.95))
		draw_arc(_g_meter_center, _g_meter_radius, 0.0, TAU, 32, COL_PANEL_LINE, 1.5 * s, true)
		draw_arc(_g_meter_center, _g_meter_radius * 0.5, 0.0, TAU, 24, Color(0.2, 0.3, 0.35, 0.5), 1.0 * s, true)
		# Crosshairs
		draw_line(
			_g_meter_center - Vector2(_g_meter_radius, 0.0),
			_g_meter_center + Vector2(_g_meter_radius, 0.0),
			Color(0.2, 0.3, 0.35, 0.6),
			1.0 * s
		)
		draw_line(
			_g_meter_center - Vector2(0.0, _g_meter_radius),
			_g_meter_center + Vector2(0.0, _g_meter_radius),
			Color(0.2, 0.3, 0.35, 0.6),
			1.0 * s
		)
		var ball_pos := _g_meter_center + (_smoothed_g_vec / 1.4) * (_g_meter_radius * 0.82)
		draw_circle(ball_pos, 6.5 * s, Color(1.0, 0.35, 0.1, 0.35))
		draw_circle(ball_pos, 4.2 * s, COL_GEAR_ON)

		# 7. Draw Drift Angle Indicator Arc & Needle
		var arc_start := deg_to_rad(-150.0)
		var arc_end := deg_to_rad(-30.0)
		draw_arc(_drift_arc_center, _drift_arc_radius, arc_start, arc_end, 24, COL_RPM_OFF, 6.0 * s, true)

		var abs_drift := absf(_drift_angle_deg)
		var drift_col := COL_SEG_ON
		if abs_drift > 35.0:
			drift_col = COL_DRIFT_EXTREME
		elif abs_drift > 10.0:
			drift_col = COL_DRIFT_GOOD

		var center_ang := deg_to_rad(-90.0)
		var drift_ang := deg_to_rad(-90.0 + clampf(_drift_angle_deg, -60.0, 60.0))
		if abs_drift > 1.0:
			var a_min := minf(center_ang, drift_ang)
			var a_max := maxf(center_ang, drift_ang)
			draw_arc(_drift_arc_center, _drift_arc_radius, a_min, a_max, 12, drift_col, 6.0 * s, true)

		# Needle triangle (mutated in-place)
		var dir := Vector2.from_angle(drift_ang)
		var perp := Vector2(-dir.y, dir.x)
		_drift_needle_poly[0] = _drift_arc_center + dir * (_drift_arc_radius + 4.0 * s)
		_drift_needle_poly[1] = _drift_arc_center + dir * (_drift_arc_radius - 10.0 * s) + perp * (3.5 * s)
		_drift_needle_poly[2] = _drift_arc_center + dir * (_drift_arc_radius - 10.0 * s) - perp * (3.5 * s)
		draw_colored_polygon(_drift_needle_poly, Color.WHITE)

		draw_string(
			_font,
			_pos_drift_label,
			"DRIFT %02d°" % int(roundf(abs_drift)),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_sz_sm,
			drift_col
		)

		# 8. Draw Gutter Hook Indicator (Akina Touge Special)
		var gutter_bg := Color(0.05, 0.25, 0.32, 0.9) if _in_gutter else COL_GUTTER_OFF
		var gutter_fg := COL_GUTTER_ON if _in_gutter else Color(0.25, 0.32, 0.36, 0.5)
		draw_rect(_gutter_box_rect, gutter_bg, true)
		draw_rect(_gutter_box_rect, gutter_fg, false, 1.5 * s)
		draw_string(
			_font,
			_pos_gutter_label,
			"GUTTER HOOK",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_sz_sm,
			gutter_fg
		)

		# 9. Draw Throttle & Brake Vertical Telemetry Bars
		draw_string(_font, _pos_thr_label, "T", HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_sm, COL_TEXT_LABEL)
		draw_string(_font, _pos_brk_label, "B", HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_sm, COL_TEXT_LABEL)

		draw_rect(_throttle_bar_rect, COL_RPM_OFF, true)
		if _throttle > 0.01:
			var th_h := _throttle_bar_rect.size.y * _throttle
			var th_rect := Rect2(
				_throttle_bar_rect.position.x,
				_throttle_bar_rect.position.y + (_throttle_bar_rect.size.y - th_h),
				_throttle_bar_rect.size.x,
				th_h
			)
			draw_rect(th_rect, COL_SEG_ON, true)

		draw_rect(_brake_bar_rect, COL_RPM_OFF, true)
		if _brake > 0.01:
			var br_h := _brake_bar_rect.size.y * _brake
			var br_rect := Rect2(
				_brake_bar_rect.position.x,
				_brake_bar_rect.position.y + (_brake_bar_rect.size.y - br_h),
				_brake_bar_rect.size.x,
				br_h
			)
			draw_rect(br_rect, COL_RPM_RED, true)


	func _draw_7seg_digit(
		polys: Array[PackedVector2Array],
		base_idx: int,
		mask: int,
		col_on: Color,
		col_off: Color
	) -> void:
		for s_idx in range(7):
			var is_lit: bool = (mask & (1 << s_idx)) != 0
			draw_colored_polygon(polys[base_idx + s_idx], col_on if is_lit else col_off)