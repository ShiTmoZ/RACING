# ==============================================================================
# File: res://TougeSectorSplitAndRankHUD.gd
# Engine: Godot Engine 4.3 (Headless / Desktop CI Compatible)
# Description: Forza Motorsport 6 & Initial D Arcade Stage Zero inspired
#              Touge Sector Split Timer, Speed Trap Radar, and Kanji Drift Rank HUD.
# ==============================================================================
class_name TougeSectorSplitAndRankHUD
extends CanvasLayer

# ==============================================================================
# 1. SIGNALS & CONSTANTS
# ==============================================================================
signal sector_split_recorded(sector_index: int, split_time_sec: float, delta_sec: float, is_sector_pb: bool)
signal personal_best_lap_achieved(new_pb_sec: float, previous_pb_sec: float)
signal drift_combo_banked(points_added: float, multiplier: float, total_score: float)
signal drift_combo_penalized(lost_points: float)
signal arcade_rank_changed(new_rank_index: int, rank_code: String, rank_title: String)
signal speed_trap_recorded(trap_index: int, speed_kmh: float, is_top_speed: bool)

const SECTOR_COUNT: int = 4
const SECTOR_NAMES: Array[String] = [
	"Sector 1: Upper Mountain High-Speed Entry",
	"Sector 2: Technical Hairpin Sequence (5 Consecutive Hairpins)",
	"Sector 3: S-Curve Rhythm & Gutter Hook Section",
	"Sector 4: Final Sprint & Finish Line Straight"
]

const MULTIPLIER_STEPS: Array[float] = [1.0, 1.5, 2.0, 3.5, 5.0]
const MULTIPLIER_TIME_THRESHOLDS: Array[float] = [0.0, 1.25, 2.80, 5.00, 8.00]

const RANK_CODES: Array[String] = ["D", "C", "B", "A", "S", "SS"]
const RANK_TITLES: Array[String] = [
	"Rank D (Novice / 初心者)",
	"Rank C (Touge Runner / 走り屋)",
	"Rank B (Drift Expert / 熟練)",
	"Rank A (Speed Star / 最速)",
	"Rank S (Akina Emperor / 皇帝)",
	"Rank SS (GHOST OF AKINA / 秋名の亡霊)"
]
const RANK_KANJI: Array[String] = ["初心者", "走り屋", "熟練", "最速", "皇帝", "秋名の亡霊"]
const RANK_SCORE_THRESHOLDS: Array[float] = [
	0.0,
	5000.0,
	18000.0,
	45000.0,
	95000.0,
	175000.0
]
const RANK_COLORS: Array[Color] = [
	Color(0.62, 0.68, 0.76, 1.0), # Rank D - Steel Silver
	Color(0.20, 0.86, 1.00, 1.0), # Rank C - Wangan Cyan
	Color(0.25, 0.98, 0.48, 1.0), # Rank B - Touge Emerald
	Color(1.00, 0.58, 0.12, 1.0), # Rank A - Sunset Amber
	Color(1.00, 0.22, 0.34, 1.0), # Rank S - Emperor Crimson
	Color(1.00, 0.86, 0.18, 1.0)  # Rank SS - Ghost of Akina Gold
]

const SPEED_TRAP_NAMES: Array[String] = [
	"UPPER RIDGE ENTRY",
	"5-HAIRPIN EXIT APEX",
	"GUTTER HOOK CHICANE",
	"FINISH STRAIGHT RADAR"
]

# Modern JDM Wangan Frosted Glass Palette
const COL_GLASS_BG: Color = Color(0.035, 0.048, 0.072, 0.80)
const COL_GLASS_HEADER: Color = Color(0.065, 0.095, 0.145, 0.90)
const COL_GLASS_BORDER: Color = Color(0.24, 0.72, 0.98, 0.55)
const COL_DELTA_AHEAD: Color = Color(0.14, 0.96, 0.46, 1.0)
const COL_DELTA_BEHIND: Color = Color(1.00, 0.22, 0.28, 1.0)
const COL_GOLD_PB: Color = Color(1.00, 0.84, 0.16, 1.0)
const COL_TEXT_MAIN: Color = Color(0.95, 0.97, 1.00, 1.0)
const COL_TEXT_DIM: Color = Color(0.58, 0.66, 0.78, 1.0)

const AUDIO_MIX_RATE: float = 22050.0

# ==============================================================================
# 2. EXPORTED PROPERTIES
# ==============================================================================
@export_group("Timing & Track Configuration")
@export var timer_running: bool = true
@export var auto_distance_sectors_enabled: bool = false
@export var virtual_sector_length_m: float = 650.0
@export var default_sector_pb_times: PackedFloat32Array = PackedFloat32Array([
	24.500, 28.200, 25.800, 22.400
])

@export_group("Drift Scoring Calibration")
@export var min_drift_speed_kmh: float = 34.0
@export var min_drift_slip_deg: float = 9.5
@export var base_drift_points_per_sec: float = 850.0
@export var combo_grace_period_sec: float = 1.15
@export var guardrail_impact_decel_threshold: float = 22.0

@export_group("UI & Audio")
@export var sound_cues_enabled: bool = true

# ==============================================================================
# 3. RUNTIME TELEMETRY & HUD STATE (ZERO PER-FRAME ALLOCATIONS)
# ==============================================================================
var current_lap_time_sec: float = 0.0
var current_sector_index: int = 0
var personal_best_lap_sec: float = 0.0

var current_sector_splits: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var pb_sector_splits: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var sector_deltas: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var sector_completed_flags: PackedByteArray = PackedByteArray([0, 0, 0, 0])

# Drift & Rank state
var total_drift_score: float = 0.0
var active_drift_score: float = 0.0
var current_multiplier: float = 1.0
var current_multiplier_tier: int = 0
var continuous_drift_time: float = 0.0
var drift_grace_timer: float = 0.0
var is_drifting: bool = false
var current_rank_index: int = 0
var guardrail_penalty_cooldown: float = 0.0

# Live vehicle telemetry
var current_speed_kmh: float = 0.0
var current_slip_angle_deg: float = 0.0
var top_speed_trap_kmh: float = 0.0
var last_speed_trap_kmh: float = 0.0
var distance_along_lap_m: float = 0.0
var _auto_next_sector_dist_m: float = 650.0
var _auto_next_trap_dist_m: float = 325.0
var _auto_trap_counter: int = 0

# Banner & Animation state
var _split_banner_alpha: float = 0.0
var _split_banner_scale: float = 1.0
var _split_banner_timer: float = 0.0
var _split_banner_title: String = ""
var _split_banner_value: String = ""
var _split_banner_color: Color = COL_DELTA_AHEAD

var _pb_banner_alpha: float = 0.0
var _pb_banner_timer: float = 0.0
var _pb_banner_text: String = "[PERSONAL BEST RECORD!]"

var _trap_banner_alpha: float = 0.0
var _trap_banner_timer: float = 0.0
var _trap_banner_text: String = ""
var _trap_is_record: bool = false

var _rank_scale_bounce: float = 1.0
var _rank_glow_pulse: float = 0.0
var _combo_pop_scale: float = 1.0
var _penalty_flash_alpha: float = 0.0

# Cached String Buffers (Updated only when values change)
var _str_lap_time: String = "00:00.000"
var _str_pb_lap_time: String = "PB --:--.---"
var _str_sector_splits: Array[String] = ["--.--s", "--.--s", "--.--s", "--.--s"]
var _str_sector_deltas: Array[String] = ["", "", "", ""]
var _str_total_score: String = "0"
var _str_active_combo: String = ""
var _str_multiplier: String = "1.0x"
var _str_speed_kmh: String = "000"
var _str_slip_deg: String = "SLIP 0.0°"
var _str_top_trap: String = "TOP TRAP: ---.- KM/H"

var _last_formatted_ms: int = -1
var _last_formatted_score: int = -1
var _last_formatted_active_combo: int = -1
var _last_formatted_speed: int = -1
var _last_formatted_slip_tenths: int = -1

# Bound external nodes
var _bound_vehicle: RigidBody3D = null
var _bound_referee: Node = null
var _prev_vehicle_vel: Vector3 = Vector3.ZERO
var _prev_vehicle_pos: Vector3 = Vector3.ZERO
var _vehicle_tracking_initialized: bool = false

# Drawing & Audio Nodes
var _hud_canvas: Control = null
var _poly_buf_4: PackedVector2Array = PackedVector2Array()
var _poly_buf_5: PackedVector2Array = PackedVector2Array()
var _audio_player: AudioStreamPlayer = null
var _audio_playback: AudioStreamGeneratorPlayback = null
var _chime_freq_a: float = 0.0
var _chime_freq_b: float = 0.0
var _chime_env: float = 0.0
var _chime_time: float = 0.0
var _chime_phase: float = 0.0
var _active_rank_tween: Tween = null
var _active_banner_tween: Tween = null


# ==============================================================================
# 4. LIFECYCLE & INITIALIZATION
# ==============================================================================
func _init() -> void:
	layer = 15
	_poly_buf_4.resize(4)
	_poly_buf_5.resize(5)
	_reset_pb_from_defaults()


func _ready() -> void:
	_setup_hud_canvas()
	_setup_audio_cues()
	_refresh_all_cached_strings()


func _process(delta: float) -> void:
	var dt: float = clampf(delta, 0.0, 0.1)

	if timer_running:
		current_lap_time_sec += dt

	if is_instance_valid(_bound_vehicle):
		_sample_vehicle_telemetry(dt)

	_update_drift_scoring_and_ranks(dt)
	_update_animations_and_banners(dt)
	_update_cached_strings_if_dirty()
	_fill_audio_cues_buffer()

	if _hud_canvas != null:
		_hud_canvas.queue_redraw()


func _reset_pb_from_defaults() -> void:
	var sum_pb: float = 0.0
	for i: int in range(SECTOR_COUNT):
		var s_pb: float = default_sector_pb_times[i] if i < default_sector_pb_times.size() else 25.0
		pb_sector_splits[i] = s_pb
		sum_pb += s_pb
	personal_best_lap_sec = sum_pb
	_str_pb_lap_time = "PB " + _format_time_ms(personal_best_lap_sec)


func _setup_hud_canvas() -> void:
	if _hud_canvas != null:
		return
	_hud_canvas = Control.new()
	_hud_canvas.name = "TougeJDMGlassCanvas"
	_hud_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_canvas.draw.connect(_on_hud_canvas_draw)
	add_child(_hud_canvas)


func _setup_audio_cues() -> void:
	_audio_player = AudioStreamPlayer.new()
	_audio_player.name = "ArcadeHUDChimeSynth"
	_audio_player.volume_db = -9.0

	var gen: AudioStreamGenerator = AudioStreamGenerator.new()
	gen.mix_rate = AUDIO_MIX_RATE
	gen.buffer_length = 0.08
	_audio_player.stream = gen
	add_child(_audio_player)

	if sound_cues_enabled and DisplayServer.get_name() != "headless":
		_audio_player.play()
		_audio_playback = _audio_player.get_stream_playback() as AudioStreamGeneratorPlayback


# ==============================================================================
# 5. PUBLIC TELEMETRY BINDING & CHECKPOINT API
# ==============================================================================
func bind_telemetry(vehicle: RigidBody3D, referee: Node = null) -> void:
	_bound_vehicle = vehicle
	_bound_referee = referee
	_vehicle_tracking_initialized = false

	if is_instance_valid(_bound_vehicle):
		if _bound_vehicle.has_signal("body_entered"):
			if not _bound_vehicle.body_entered.is_connected(_on_vehicle_body_entered):
				_bound_vehicle.body_entered.connect(_on_vehicle_body_entered)

	if is_instance_valid(_bound_referee):
		if _bound_referee.has_signal("sector_checkpoint_crossed"):
			if not _bound_referee.sector_checkpoint_crossed.is_connected(trigger_sector_checkpoint):
				_bound_referee.sector_checkpoint_crossed.connect(trigger_sector_checkpoint)
		if _bound_referee.has_signal("finish_line_crossed"):
			if not _bound_referee.finish_line_crossed.is_connected(trigger_finish_line):
				_bound_referee.finish_line_crossed.connect(trigger_finish_line)
		if _bound_referee.has_signal("speed_trap_crossed"):
			if not _bound_referee.speed_trap_crossed.is_connected(trigger_speed_trap):
				_bound_referee.speed_trap_crossed.connect(trigger_speed_trap)


func trigger_sector_checkpoint(sector_index: int, split_time_sec: float) -> void:
	var idx: int = clampi(sector_index, 0, SECTOR_COUNT - 1)
	var clean_split: float = maxf(0.001, split_time_sec)

	# Calculate individual sector duration if cumulative lap time was passed
	var sector_duration: float = clean_split
	if idx > 0 and clean_split > current_sector_splits[idx - 1] and pb_sector_splits[idx] < clean_split * 0.65:
		var prev_sum: float = 0.0
		for i: int in range(idx):
			prev_sum += current_sector_splits[i]
		if clean_split > prev_sum + 1.0:
			sector_duration = clean_split - prev_sum

	current_sector_splits[idx] = sector_duration
	sector_completed_flags[idx] = 1

	var ref_pb: float = pb_sector_splits[idx]
	var delta_sec: float = sector_duration - ref_pb
	var is_new_sector_pb: bool = false

	if ref_pb <= 0.001 or sector_duration < ref_pb:
		is_new_sector_pb = true
		pb_sector_splits[idx] = sector_duration

	sector_deltas[idx] = delta_sec
	_str_sector_splits[idx] = _format_seconds_short(sector_duration)
	_str_sector_deltas[idx] = _format_delta_string(delta_sec)

	# Advance current active sector
	current_sector_index = min(idx + 1, SECTOR_COUNT - 1)

	# Trigger glowing split time banner
	_split_banner_title = SECTOR_NAMES[idx].to_upper()
	_split_banner_value = "SPLIT " + _str_sector_splits[idx] + "   (" + _str_sector_deltas[idx] + ")"
	_split_banner_color = COL_DELTA_AHEAD if delta_sec <= 0.0 else COL_DELTA_BEHIND
	_split_banner_timer = 3.2
	_split_banner_alpha = 1.0
	_split_banner_scale = 1.22

	if is_inside_tree():
		if _active_banner_tween != null and _active_banner_tween.is_valid():
			_active_banner_tween.kill()
		_active_banner_tween = create_tween()
		_active_banner_tween.tween_property(self, "_split_banner_scale", 1.0, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# Play positive (green) or negative (red) split audio cue
	if delta_sec <= 0.0:
		_trigger_chime(880.0, 1318.5, 0.18)
	else:
		_trigger_chime(370.0, 293.6, 0.20)

	# Automatically record a virtual Speed Trap at the sector boundary
	if current_speed_kmh > 10.0:
		trigger_speed_trap(idx, current_speed_kmh)

	sector_split_recorded.emit(idx, sector_duration, delta_sec, is_new_sector_pb)


func trigger_finish_line(final_lap_time_sec: float) -> void:
	var lap_sec: float = final_lap_time_sec if final_lap_time_sec > 0.001 else current_lap_time_sec

	# Complete Sector 4 if not yet triggered on this lap
	if sector_completed_flags[SECTOR_COUNT - 1] == 0:
		var prev_sectors_sum: float = 0.0
		for i: int in range(SECTOR_COUNT - 1):
			prev_sectors_sum += current_sector_splits[i]
		var s4_time: float = maxf(1.0, lap_sec - prev_sectors_sum)
		trigger_sector_checkpoint(SECTOR_COUNT - 1, s4_time)

	# Bank any active drift combo at the finish line
	if active_drift_score > 0.0:
		_bank_active_drift_combo()

	var prev_pb: float = personal_best_lap_sec
	var is_new_pb: bool = (prev_pb <= 0.001 or lap_sec < prev_pb)

	if is_new_pb:
		personal_best_lap_sec = lap_sec
		_str_pb_lap_time = "PB " + _format_time_ms(personal_best_lap_sec)
		_pb_banner_text = "[PERSONAL BEST RECORD!]  " + _format_time_ms(lap_sec)
		_pb_banner_timer = 4.5
		_pb_banner_alpha = 1.0
		_trigger_chime(1046.5, 1567.98, 0.35)
		personal_best_lap_achieved.emit(lap_sec, prev_pb)
	else:
		var lap_delta: float = lap_sec - prev_pb
		_split_banner_title = "TOUGE STAGE COMPLETE"
		_split_banner_value = _format_time_ms(lap_sec) + "  (" + _format_delta_string(lap_delta) + ")"
		_split_banner_color = COL_DELTA_BEHIND
		_split_banner_timer = 3.6
		_split_banner_alpha = 1.0

	# Reset lap stopwatch for next run while keeping displayed sector splits until Sector 1
	current_lap_time_sec = 0.0
	current_sector_index = 0
	distance_along_lap_m = 0.0
	_auto_next_sector_dist_m = virtual_sector_length_m
	_auto_next_trap_dist_m = virtual_sector_length_m * 0.5
	_auto_trap_counter = 0
	for i: int in range(SECTOR_COUNT):
		sector_completed_flags[i] = 0


func trigger_speed_trap(trap_index: int, speed_kmh: float) -> void:
	var clean_speed: float = maxf(0.0, speed_kmh)
	last_speed_trap_kmh = clean_speed
	var is_record: bool = clean_speed > top_speed_trap_kmh

	if is_record:
		top_speed_trap_kmh = clean_speed
		_str_top_trap = "TOP TRAP: " + String.num(top_speed_trap_kmh, 1) + " KM/H"

	var trap_label: String = SPEED_TRAP_NAMES[clampi(trap_index, 0, SPEED_TRAP_NAMES.size() - 1)]
	if is_record:
		_trap_banner_text = "SPEED TRAP (" + trap_label + "): " + String.num(clean_speed, 1) + " KM/H [TOP SPEED!]"
	else:
		_trap_banner_text = "SPEED TRAP (" + trap_label + "): " + String.num(clean_speed, 1) + " KM/H"

	_trap_is_record = is_record
	_trap_banner_timer = 2.85
	_trap_banner_alpha = 1.0
	speed_trap_recorded.emit(trap_index, clean_speed, is_record)


func register_guardrail_impact(severity: float = 1.0) -> void:
	if guardrail_penalty_cooldown > 0.0:
		return
	guardrail_penalty_cooldown = 0.85
	_penalty_flash_alpha = 1.0

	if active_drift_score > 0.0 or current_multiplier > 1.0:
		var penalty_factor: float = clampf(severity, 0.35, 1.0)
		var lost: float = active_drift_score * penalty_factor
		active_drift_score = maxf(0.0, active_drift_score - lost)
		current_multiplier_tier = maxi(0, current_multiplier_tier - 2)
		current_multiplier = MULTIPLIER_STEPS[current_multiplier_tier]
		continuous_drift_time = MULTIPLIER_TIME_THRESHOLDS[current_multiplier_tier]
		is_drifting = false
		drift_grace_timer = 0.0
		_str_multiplier = String.num(current_multiplier, 1) + "x"
		_trigger_chime(185.0, 130.8, 0.22)
		drift_combo_penalized.emit(lost)


# ==============================================================================
# 6. LIVE VEHICLE TELEMETRY & DRIFT RANKING ENGINE
# ==============================================================================
func _sample_vehicle_telemetry(dt: float) -> void:
	if _bound_vehicle == null or dt <= 0.0001:
		return

	var vel: Vector3 = _bound_vehicle.linear_velocity
	var pos: Vector3 = _bound_vehicle.global_position
	if not _vehicle_tracking_initialized:
		_prev_vehicle_vel = vel
		_prev_vehicle_pos = pos
		_vehicle_tracking_initialized = true

	var step_dist: float = (pos - _prev_vehicle_pos).length()
	if vel.length() < 0.05 and step_dist > 0.001:
		vel = (pos - _prev_vehicle_pos) / dt

	current_speed_kmh = vel.length() * 3.6
	distance_along_lap_m += vel.length() * dt

	# Calculate horizontal slip angle between vehicle forward (-Z) and horizontal velocity
	var horiz_vel: Vector3 = Vector3(vel.x, 0.0, vel.z)
	if horiz_vel.length() > 2.2:
		var fwd: Vector3 = -_bound_vehicle.global_transform.basis.z
		var horiz_fwd: Vector3 = Vector3(fwd.x, 0.0, fwd.z).normalized()
		var dot_val: float = clampf(horiz_fwd.dot(horiz_vel.normalized()), -1.0, 1.0)
		current_slip_angle_deg = rad_to_deg(acos(dot_val))
	else:
		current_slip_angle_deg = 0.0

	# Detect sudden deceleration / guardrail tap
	var decel_m_s2: float = (_prev_vehicle_vel - vel).length() / dt
	if decel_m_s2 >= guardrail_impact_decel_threshold and current_speed_kmh > 25.0:
		register_guardrail_impact(clampf(decel_m_s2 / 40.0, 0.5, 1.0))

	# Optional automatic distance-based sector & speed trap progression
	if auto_distance_sectors_enabled:
		if distance_along_lap_m >= _auto_next_trap_dist_m:
			trigger_speed_trap(_auto_trap_counter % SPEED_TRAP_NAMES.size(), current_speed_kmh)
			_auto_trap_counter += 1
			_auto_next_trap_dist_m += virtual_sector_length_m

		if distance_along_lap_m >= _auto_next_sector_dist_m:
			if current_sector_index < SECTOR_COUNT - 1:
				trigger_sector_checkpoint(current_sector_index, current_lap_time_sec)
				_auto_next_sector_dist_m += virtual_sector_length_m
			else:
				trigger_finish_line(current_lap_time_sec)

	_prev_vehicle_vel = vel
	_prev_vehicle_pos = pos


func _on_vehicle_body_entered(_body: Node) -> void:
	if current_speed_kmh >= 20.0:
		register_guardrail_impact(0.75)


func _update_drift_scoring_and_ranks(dt: float) -> void:
	guardrail_penalty_cooldown = maxf(0.0, guardrail_penalty_cooldown - dt)

	var valid_drift: bool = (
		current_speed_kmh >= min_drift_speed_kmh
		and current_slip_angle_deg >= min_drift_slip_deg
		and current_slip_angle_deg <= 82.0
	)

	if valid_drift:
		is_drifting = true
		drift_grace_timer = combo_grace_period_sec
		continuous_drift_time += dt

		# Ramp multiplier through 1.0x -> 1.5x -> 2.0x -> 3.5x -> 5.0x
		var new_tier: int = 0
		for t_idx: int in range(MULTIPLIER_TIME_THRESHOLDS.size() - 1, -1, -1):
			if continuous_drift_time >= MULTIPLIER_TIME_THRESHOLDS[t_idx]:
				new_tier = t_idx
				break

		if new_tier != current_multiplier_tier:
			current_multiplier_tier = new_tier
			current_multiplier = MULTIPLIER_STEPS[current_multiplier_tier]
			_str_multiplier = String.num(current_multiplier, 1) + "x"
			_combo_pop_scale = 1.32
			_trigger_chime(523.25 + float(new_tier) * 110.0, 659.25 + float(new_tier) * 130.0, 0.09)

		# Calculate points from slip angle & speed
		var angle_factor: float = clampf(current_slip_angle_deg / 38.0, 0.35, 2.2)
		var speed_factor: float = clampf(current_speed_kmh / 110.0, 0.45, 2.0)
		active_drift_score += base_drift_points_per_sec * angle_factor * speed_factor * dt
	else:
		if is_drifting:
			drift_grace_timer -= dt
			if drift_grace_timer <= 0.0:
				_bank_active_drift_combo()

	# Check Kanji Rank Progression based on total + active drift points
	var effective_score: float = total_drift_score + active_drift_score * current_multiplier
	var target_rank: int = 0
	for r_idx: int in range(RANK_SCORE_THRESHOLDS.size() - 1, -1, -1):
		if effective_score >= RANK_SCORE_THRESHOLDS[r_idx]:
			target_rank = r_idx
			break

	if target_rank > current_rank_index:
		current_rank_index = target_rank
		_trigger_rank_up_animation()
		arcade_rank_changed.emit(
			current_rank_index,
			RANK_CODES[current_rank_index],
			RANK_TITLES[current_rank_index]
		)


func _bank_active_drift_combo() -> void:
	var banked: float = active_drift_score * current_multiplier
	if banked >= 25.0:
		total_drift_score += banked
		_combo_pop_scale = 1.28
		_trigger_chime(659.25, 987.77, 0.14)
		drift_combo_banked.emit(banked, current_multiplier, total_drift_score)

	active_drift_score = 0.0
	continuous_drift_time = 0.0
	current_multiplier_tier = 0
	current_multiplier = MULTIPLIER_STEPS[0]
	_str_multiplier = "1.0x"
	is_drifting = false
	drift_grace_timer = 0.0


func _trigger_rank_up_animation() -> void:
	_rank_scale_bounce = 1.65
	_rank_glow_pulse = 1.0
	_trigger_chime(783.99, 1174.66, 0.28)

	if is_inside_tree():
		if _active_rank_tween != null and _active_rank_tween.is_valid():
			_active_rank_tween.kill()
		_active_rank_tween = create_tween()
		_active_rank_tween.tween_property(self, "_rank_scale_bounce", 1.0, 0.38).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _update_animations_and_banners(dt: float) -> void:
	_combo_pop_scale = move_toward(_combo_pop_scale, 1.0, dt * 3.2)
	_rank_scale_bounce = move_toward(_rank_scale_bounce, 1.0, dt * 2.5)
	_rank_glow_pulse = fposmod(_rank_glow_pulse + dt * 2.2, 1.0)
	_penalty_flash_alpha = move_toward(_penalty_flash_alpha, 0.0, dt * 1.8)

	if _split_banner_timer > 0.0:
		_split_banner_timer = maxf(0.0, _split_banner_timer - dt)
		if _split_banner_timer < 0.45:
			_split_banner_alpha = _split_banner_timer / 0.45
	else:
		_split_banner_alpha = 0.0

	if _pb_banner_timer > 0.0:
		_pb_banner_timer = maxf(0.0, _pb_banner_timer - dt)
		if _pb_banner_timer < 0.6:
			_pb_banner_alpha = _pb_banner_timer / 0.6
	else:
		_pb_banner_alpha = 0.0

	if _trap_banner_timer > 0.0:
		_trap_banner_timer = maxf(0.0, _trap_banner_timer - dt)
		if _trap_banner_timer < 0.4:
			_trap_banner_alpha = _trap_banner_timer / 0.4
	else:
		_trap_banner_alpha = 0.0


# ==============================================================================
# 7. STRING FORMATTING CACHE (ZERO UNNECESSARY ALLOCATIONS)
# ==============================================================================
func _refresh_all_cached_strings() -> void:
	_last_formatted_ms = -1
	_last_formatted_score = -1
	_last_formatted_active_combo = -1
	_last_formatted_speed = -1
	_last_formatted_slip_tenths = -1
	_update_cached_strings_if_dirty()


func _update_cached_strings_if_dirty() -> void:
	var cur_ms: int = int(current_lap_time_sec * 1000.0)
	if cur_ms != _last_formatted_ms:
		_last_formatted_ms = cur_ms
		_str_lap_time = _format_time_ms(current_lap_time_sec)

	var cur_score_int: int = int(total_drift_score)
	if cur_score_int != _last_formatted_score:
		_last_formatted_score = cur_score_int
		_str_total_score = _format_score_commas(cur_score_int)

	var cur_combo_int: int = int(active_drift_score)
	if cur_combo_int != _last_formatted_active_combo:
		_last_formatted_active_combo = cur_combo_int
		_str_active_combo = "+" + str(cur_combo_int) if cur_combo_int > 0 else "READY"

	var cur_spd_int: int = int(roundf(current_speed_kmh))
	if cur_spd_int != _last_formatted_speed:
		_last_formatted_speed = cur_spd_int
		_str_speed_kmh = "%03d" % cur_spd_int

	var cur_slip_tenths: int = int(roundf(current_slip_angle_deg * 10.0))
	if cur_slip_tenths != _last_formatted_slip_tenths:
		_last_formatted_slip_tenths = cur_slip_tenths
		_str_slip_deg = "SLIP " + String.num(current_slip_angle_deg, 1) + "°"


func _format_time_ms(sec: float) -> String:
	var total_ms: int = maxi(0, int(roundf(sec * 1000.0)))
	var minutes: int = total_ms / 60000
	var seconds: int = (total_ms / 1000) % 60
	var millis: int = total_ms % 1000
	return "%02d:%02d.%03d" % [minutes, seconds, millis]


func _format_seconds_short(sec: float) -> String:
	return "%05.2fs" % maxf(0.0, sec)


func _format_delta_string(delta_sec: float) -> String:
	if delta_sec <= 0.0:
		return "-%04.2fs" % absf(delta_sec)
	return "+%04.2fs" % delta_sec


func _format_score_commas(score_val: int) -> String:
	var raw: String = str(maxi(0, score_val))
	var len_s: int = raw.length()
	if len_s <= 3:
		return raw
	var out: String = ""
	for i: int in range(len_s):
		if i > 0 and (len_s - i) % 3 == 0:
			out += ","
		out += raw[i]
	return out


# ==============================================================================
# 8. PROCEDURAL ARCADE SOUND CUE SYNTHESIZER
# ==============================================================================
func _trigger_chime(freq_a: float, freq_b: float, duration: float) -> void:
	if not sound_cues_enabled:
		return
	_chime_freq_a = freq_a
	_chime_freq_b = freq_b
	_chime_env = duration
	_chime_time = 0.0


func _fill_audio_cues_buffer() -> void:
	if not sound_cues_enabled or _audio_player == null:
		return
	if DisplayServer.get_name() == "headless":
		return
	if not _audio_player.playing:
		_audio_player.play()
		_audio_playback = _audio_player.get_stream_playback() as AudioStreamGeneratorPlayback
	if _audio_playback == null:
		return

	var frames: int = _audio_playback.get_frames_available()
	if frames <= 0:
		return

	var inv_rate: float = 1.0 / AUDIO_MIX_RATE
	for _i: int in range(frames):
		var sample: float = 0.0
		if _chime_env > 0.001:
			var active_freq: float = _chime_freq_a if _chime_time < 0.075 else _chime_freq_b
			_chime_phase = fposmod(_chime_phase + active_freq * inv_rate, 1.0)
			var wave: float = sin(_chime_phase * TAU) + 0.35 * sin(_chime_phase * TAU * 2.0)
			var amp: float = clampf(_chime_env * 5.0, 0.0, 1.0) * 0.25
			sample = wave * amp
			_chime_time += inv_rate
			_chime_env = maxf(0.0, _chime_env - inv_rate)
		_audio_playback.push_frame(Vector2(sample, sample))


# ==============================================================================
# 9. MODERN JDM GLASS VECTOR RENDERER (_draw)
# ==============================================================================
func _on_hud_canvas_draw() -> void:
	if _hud_canvas == null:
		return
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return

	var vp_size: Vector2 = _hud_canvas.size
	if vp_size.x < 10.0 or vp_size.y < 10.0:
		vp_size = Vector2(1280.0, 720.0)

	_draw_sector_split_panel(font, Vector2(24.0, 68.0))
	# Drift rank panel removed from top right to prevent overlap with window controls and referee
	# _draw_drift_rank_panel(font, Vector2(vp_size.x - 364.0, 22.0))
	if _trap_banner_timer > 0.0:
		_draw_speed_trap_cluster(font, Vector2(vp_size.x * 0.5 + 174.0, 24.0))
	_draw_center_flash_banners(font, vp_size)


func _draw_slanted_glass_box(pos: Vector2, box_size: Vector2, slant: float, bg_col: Color, border_col: Color, accent_width: float = 4.0) -> void:
	_poly_buf_4[0] = Vector2(pos.x + slant, pos.y)
	_poly_buf_4[1] = Vector2(pos.x + box_size.x, pos.y)
	_poly_buf_4[2] = Vector2(pos.x + box_size.x - slant, pos.y + box_size.y)
	_poly_buf_4[3] = Vector2(pos.x, pos.y + box_size.y)
	_hud_canvas.draw_colored_polygon(_poly_buf_4, bg_col)

	# Left neon accent bar
	if accent_width > 0.0:
		_poly_buf_4[0] = Vector2(pos.x + slant, pos.y)
		_poly_buf_4[1] = Vector2(pos.x + slant + accent_width, pos.y)
		_poly_buf_4[2] = Vector2(pos.x + accent_width, pos.y + box_size.y)
		_poly_buf_4[3] = Vector2(pos.x, pos.y + box_size.y)
		_hud_canvas.draw_colored_polygon(_poly_buf_4, border_col)

	# Crisp outer vector border
	_poly_buf_5[0] = Vector2(pos.x + slant, pos.y)
	_poly_buf_5[1] = Vector2(pos.x + box_size.x, pos.y)
	_poly_buf_5[2] = Vector2(pos.x + box_size.x - slant, pos.y + box_size.y)
	_poly_buf_5[3] = Vector2(pos.x, pos.y + box_size.y)
	_poly_buf_5[4] = _poly_buf_5[0]
	_hud_canvas.draw_polyline(_poly_buf_5, border_col, 1.5, true)


func _draw_sector_split_panel(font: Font, origin: Vector2) -> void:
	var panel_w: float = 376.0
	var panel_h: float = 232.0
	_draw_slanted_glass_box(origin, Vector2(panel_w, panel_h), 14.0, COL_GLASS_BG, COL_GLASS_BORDER, 5.0)
	_draw_slanted_glass_box(origin, Vector2(panel_w, 34.0), 6.0, COL_GLASS_HEADER, COL_GLASS_BORDER, 5.0)

	# Header & Main Stopwatch
	_hud_canvas.draw_string(
		font,
		origin + Vector2(18.0, 23.0),
		"TOUGE CHRONO // STAGE TELEMETRY",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		13,
		COL_GLASS_BORDER
	)
	_hud_canvas.draw_string(
		font,
		origin + Vector2(18.0, 68.0),
		_str_lap_time,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		32,
		COL_TEXT_MAIN
	)
	_hud_canvas.draw_string(
		font,
		origin + Vector2(228.0, 64.0),
		_str_pb_lap_time,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		14,
		COL_GOLD_PB
	)

	# Active Sector Title
	var active_sec_name: String = SECTOR_NAMES[clampi(current_sector_index, 0, SECTOR_COUNT - 1)]
	_hud_canvas.draw_string(
		font,
		origin + Vector2(18.0, 90.0),
		active_sec_name,
		HORIZONTAL_ALIGNMENT_LEFT,
		panel_w - 28.0,
		12,
		COL_TEXT_DIM
	)

	# 4 Sequential Sector Rows
	for i: int in range(SECTOR_COUNT):
		var row_y: float = origin.y + 104.0 + float(i) * 30.0
		var is_cur: bool = (i == current_sector_index)
		var row_bg: Color = Color(0.10, 0.16, 0.25, 0.65) if is_cur else Color(0.05, 0.07, 0.11, 0.45)
		var row_border: Color = COL_GLASS_BORDER if is_cur else Color(0.2, 0.3, 0.4, 0.25)

		_draw_slanted_glass_box(Vector2(origin.x + 12.0, row_y), Vector2(panel_w - 26.0, 25.0), 5.0, row_bg, row_border, 3.0 if is_cur else 0.0)

		var sec_short: String = "S" + str(i + 1)
		_hud_canvas.draw_string(font, Vector2(origin.x + 24.0, row_y + 18.0), sec_short, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, COL_TEXT_MAIN)
		_hud_canvas.draw_string(
			font,
			Vector2(origin.x + 54.0, row_y + 17.0),
			SECTOR_NAMES[i].substr(10, 22),
			HORIZONTAL_ALIGNMENT_LEFT,
			145.0,
			11,
			COL_TEXT_DIM
		)
		_hud_canvas.draw_string(
			font,
			Vector2(origin.x + 206.0, row_y + 18.0),
			_str_sector_splits[i],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			13,
			COL_TEXT_MAIN
		)

		# Delta Badge (Green ahead / Red behind)
		if sector_completed_flags[i] == 1:
			var d_col: Color = COL_DELTA_AHEAD if sector_deltas[i] <= 0.0 else COL_DELTA_BEHIND
			_draw_slanted_glass_box(
				Vector2(origin.x + 276.0, row_y + 3.0),
				Vector2(78.0, 19.0),
				4.0,
				Color(d_col.r * 0.22, d_col.g * 0.22, d_col.b * 0.22, 0.90),
				d_col,
				2.0
			)
			_hud_canvas.draw_string(
				font,
				Vector2(origin.x + 284.0, row_y + 17.0),
				_str_sector_deltas[i],
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				12,
				d_col
			)


func _draw_drift_rank_panel(font: Font, origin: Vector2) -> void:
	var vp_size: Vector2 = _hud_canvas.get_viewport_rect().size if is_instance_valid(_hud_canvas) else Vector2(1920.0, 1080.0)
	var clamped_origin := Vector2(
		clampf(origin.x, 24.0, maxf(vp_size.x - 364.0, 24.0)),
		clampf(origin.y, 22.0, 234.0)
	)
	origin = clamped_origin
	var panel_w: float = 340.0
	var panel_h: float = 212.0
	var rank_col: Color = RANK_COLORS[clampi(current_rank_index, 0, RANK_COLORS.size() - 1)]

	_draw_slanted_glass_box(origin, Vector2(panel_w, panel_h), 14.0, COL_GLASS_BG, rank_col, 5.0)
	_draw_slanted_glass_box(origin, Vector2(panel_w, 34.0), 6.0, COL_GLASS_HEADER, rank_col, 5.0)

	_hud_canvas.draw_string(
		font,
		origin + Vector2(18.0, 23.0),
		"INITIAL D // DRIFT GRADE & MULTIPLIER",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		13,
		rank_col
	)

	# Glowing Kanji & Grade Emblem Box with Scale Bounce
	var badge_center: Vector2 = origin + Vector2(62.0, 96.0)
	var b_scale: float = _rank_scale_bounce
	var badge_size: Vector2 = Vector2(84.0 * b_scale, 76.0 * b_scale)
	var glow_alpha: float = 0.25 + 0.20 * sin(_rank_glow_pulse * TAU)
	_draw_slanted_glass_box(
		badge_center - badge_size * 0.5,
		badge_size,
		10.0,
		Color(rank_col.r * 0.22, rank_col.g * 0.22, rank_col.b * 0.22, 0.92),
		Color(rank_col.r, rank_col.g, rank_col.b, 0.65 + glow_alpha),
		4.0
	)

	var r_code: String = RANK_CODES[current_rank_index]
	var r_kanji: String = RANK_KANJI[current_rank_index]
	_hud_canvas.draw_string(
		font,
		badge_center + Vector2(-24.0, 4.0),
		r_code,
		HORIZONTAL_ALIGNMENT_CENTER,
		52.0,
		int(34.0 * b_scale),
		rank_col
	)
	_hud_canvas.draw_string(
		font,
		badge_center + Vector2(-34.0, 26.0),
		r_kanji,
		HORIZONTAL_ALIGNMENT_CENTER,
		70.0,
		13,
		COL_TEXT_MAIN
	)

	# Full Rank Title & Banked Score
	_hud_canvas.draw_string(
		font,
		origin + Vector2(118.0, 62.0),
		RANK_TITLES[current_rank_index],
		HORIZONTAL_ALIGNMENT_LEFT,
		212.0,
		13,
		rank_col
	)
	_hud_canvas.draw_string(
		font,
		origin + Vector2(118.0, 96.0),
		_str_total_score + " PTS",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		24,
		COL_TEXT_MAIN
	)

	# Active Drift Combo & Multiplier Bar (1.0x -> 1.5x -> 2.0x -> 3.5x -> 5.0x)
	var combo_col: Color = COL_DELTA_AHEAD if is_drifting else COL_TEXT_DIM
	_hud_canvas.draw_string(
		font,
		origin + Vector2(118.0, 124.0),
		"COMBO: " + _str_active_combo,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		16,
		combo_col
	)
	_hud_canvas.draw_string(
		font,
		origin + Vector2(252.0, 125.0),
		_str_multiplier,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		int(20.0 * _combo_pop_scale),
		 COL_GOLD_PB if current_multiplier >= 3.5 else rank_col
	)

	# Multiplier Step Pills
	for m_idx: int in range(MULTIPLIER_STEPS.size()):
		var pill_x: float = origin.x + 16.0 + float(m_idx) * 62.0
		var pill_y: float = origin.y + 146.0
		var active_step: bool = (m_idx <= current_multiplier_tier and (is_drifting or current_multiplier_tier > 0))
		var step_col: Color = rank_col if active_step else Color(0.22, 0.28, 0.36, 0.45)
		_draw_slanted_glass_box(
			Vector2(pill_x, pill_y),
			Vector2(56.0, 22.0),
			4.0,
			Color(step_col.r * 0.25, step_col.g * 0.25, step_col.b * 0.25, 0.85),
			step_col,
			0.0
		)
		_hud_canvas.draw_string(
			font,
			Vector2(pill_x + 12.0, pill_y + 16.0),
			String.num(MULTIPLIER_STEPS[m_idx], 1) + "x",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			12,
			COL_TEXT_MAIN if active_step else COL_TEXT_DIM
		)

	# Slip Angle Readout & Guardrail Penalty Flash
	_hud_canvas.draw_string(
		font,
		origin + Vector2(18.0, 194.0),
		_str_slip_deg,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		13,
		COL_TEXT_DIM
	)
	if _penalty_flash_alpha > 0.01:
		var pen_col: Color = Color(1.0, 0.20, 0.24, _penalty_flash_alpha)
		_hud_canvas.draw_string(
			font,
			origin + Vector2(118.0, 194.0),
			"[GUARDRAIL IMPACT - PENALTY!]",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			13,
			pen_col
		)


func _draw_speed_trap_cluster(font: Font, origin: Vector2) -> void:
	var panel_w: float = 296.0
	var panel_h: float = 104.0
	_draw_slanted_glass_box(origin, Vector2(panel_w, panel_h), 12.0, COL_GLASS_BG, COL_GLASS_BORDER, 5.0)

	_hud_canvas.draw_string(
		font,
		origin + Vector2(22.0, 62.0),
		_str_speed_kmh,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		44,
		COL_TEXT_MAIN
	)
	_hud_canvas.draw_string(
		font,
		origin + Vector2(118.0, 42.0),
		"KM/H",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		16,
		COL_GLASS_BORDER
	)
	_hud_canvas.draw_string(
		font,
		origin + Vector2(118.0, 62.0),
		"WANGAN RADAR",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		12,
		COL_TEXT_DIM
	)
	_hud_canvas.draw_string(
		font,
		origin + Vector2(22.0, 90.0),
		_str_top_trap,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		14,
		COL_GOLD_PB
	)


func _draw_center_flash_banners(font: Font, vp_size: Vector2) -> void:
	var center_x: float = vp_size.x * 0.5

	# 1. Sector Split Delta Banner
	if _split_banner_alpha > 0.01:
		var bw: float = 460.0 * _split_banner_scale
		var bh: float = 68.0 * _split_banner_scale
		var b_pos: Vector2 = Vector2(center_x - bw * 0.5, 28.0)
		var bg_c: Color = Color(0.03, 0.05, 0.08, 0.88 * _split_banner_alpha)
		var bd_c: Color = Color(_split_banner_color.r, _split_banner_color.g, _split_banner_color.b, _split_banner_alpha)

		_draw_slanted_glass_box(b_pos, Vector2(bw, bh), 14.0, bg_c, bd_c, 6.0)
		_hud_canvas.draw_string(
			font,
			b_pos + Vector2(24.0, 25.0),
			_split_banner_title,
			HORIZONTAL_ALIGNMENT_LEFT,
			bw - 36.0,
			13,
			Color(COL_TEXT_DIM.r, COL_TEXT_DIM.g, COL_TEXT_DIM.b, _split_banner_alpha)
		)
		_hud_canvas.draw_string(
			font,
			b_pos + Vector2(24.0, 54.0),
			_split_banner_value,
			HORIZONTAL_ALIGNMENT_LEFT,
			bw - 36.0,
			22,
			bd_c
		)

	# 2. Speed Trap Radar Flash Banner
	if _trap_banner_alpha > 0.01:
		var tw: float = 490.0
		var th: float = 44.0
		var t_pos: Vector2 = Vector2(center_x - tw * 0.5, 108.0)
		var t_col: Color = COL_GOLD_PB if _trap_is_record else COL_GLASS_BORDER
		t_col.a = _trap_banner_alpha
		_draw_slanted_glass_box(
			t_pos,
			Vector2(tw, th),
			10.0,
			Color(0.04, 0.06, 0.10, 0.86 * _trap_banner_alpha),
			t_col,
			5.0
		)
		_hud_canvas.draw_string(
			font,
			t_pos + Vector2(20.0, 29.0),
			_trap_banner_text,
			HORIZONTAL_ALIGNMENT_LEFT,
			tw - 30.0,
			15,
			t_col
		)

	# 3. Golden Personal Best Lap Record Flash Banner
	if _pb_banner_alpha > 0.01:
		var pw: float = 520.0
		var ph: float = 54.0
		var p_pos: Vector2 = Vector2(center_x - pw * 0.5, 162.0)
		var g_col: Color = Color(COL_GOLD_PB.r, COL_GOLD_PB.g, COL_GOLD_PB.b, _pb_banner_alpha)
		_draw_slanted_glass_box(
			p_pos,
			Vector2(pw, ph),
			12.0,
			Color(0.14, 0.10, 0.02, 0.92 * _pb_banner_alpha),
			g_col,
			6.0
		)
		_hud_canvas.draw_string(
			font,
			p_pos + Vector2(24.0, 35.0),
			_pb_banner_text,
			HORIZONTAL_ALIGNMENT_LEFT,
			pw - 36.0,
			20,
			g_col
		)