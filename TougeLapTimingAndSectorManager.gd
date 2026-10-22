class_name TougeLapTimingAndSectorManager
extends CanvasLayer

## Intelligent Lap & Sector Timing Controller for Godot 4.3
## Adapts automatically between Point-to-Point Touge (Akina/Irohazaka)
## and Closed-Loop Circuit Hot-Lapping (Tsukuba TC2000).

# ==============================================================================
# SIGNALS
# ==============================================================================
signal sector_crossed(sector_index: int, sector_time: float, delta: float)
signal lap_completed(lap_number: int, lap_time: float, is_new_best: bool)
signal touge_run_completed(total_time: float, rank: String)

# ==============================================================================
# ENUMS & CONSTANTS
# ==============================================================================
enum TimingMode {
	POINT_TO_POINT_TOUGE,
	CLOSED_LOOP_CIRCUIT
}

# Tsukuba TC2000 Official 3-Sector Normalized Spline Ratios
const TSUKUBA_SECTORS: Array[float] = [0.32, 0.68, 1.0]
# Standard 4-Sector Normalized Ratios for Akina / Irohazaka
const TOUGE_SECTORS: Array[float] = [0.25, 0.50, 0.75, 1.0]

const COLOR_FASTER := Color(0.15, 1.0, 0.35, 1.0)     # Vibrant Green
const COLOR_SLOWER := Color(1.0, 0.22, 0.22, 1.0)     # Red
const COLOR_NEUTRAL := Color(0.85, 0.9, 0.95, 1.0)    # Crisp White/Silver
const COLOR_OPTIMAL := Color(0.75, 0.35, 1.0, 1.0)    # Purple/Optimal

# ==============================================================================
# EXPORTED REFERENCES
# ==============================================================================
@export_group("Scene References")
@export var vehicle_node: Node3D
@export var track_path_3d: Path3D
@export var is_closed_loop: bool = true

@export_group("Touge Run Rank Thresholds (Seconds)")
@export var rank_s_threshold: float = 175.0
@export var rank_a_threshold: float = 185.0
@export var rank_b_threshold: float = 198.0
@export var rank_c_threshold: float = 215.0

# ==============================================================================
# STATE VARIABLES
# ==============================================================================
var current_mode: TimingMode = TimingMode.CLOSED_LOOP_CIRCUIT
var track_name: String = "TSUKUBA CIRCUIT TC2000"
var track_length: float = 2045.0

var is_timing_active: bool = false
var current_lap_time: float = 0.0
var best_lap_time: float = INF
var last_lap_time: float = 0.0
var lap_count: int = 0

# Sector Tracking
var active_sector_thresholds: Array[float] = TSUKUBA_SECTORS
var current_sector_index: int = 0
var current_sector_start_time: float = 0.0
var current_lap_sector_times: Array[float] = []
var best_lap_sector_times: Array[float] = [] # Splits belonging to the session best lap
var optimal_sector_times: Array[float] = []  # Theoretical best per individual sector

# Spline Progress Tracking (0.0 to 1.0)
var previous_progress_ratio: float = 0.0
var current_progress_ratio: float = 0.0
var max_progress_reached_this_lap: float = 0.0

# UI Nodes (Built Programmatically to ensure zero scene-tree dependencies)
var hud_root: Control
var lap_header_label: Label
var current_time_label: Label
var best_time_label: Label
var delta_label: Label
var split_banner_panel: PanelContainer
var split_banner_label: Label
var banner_tween: Tween

# ==============================================================================
# LIFECYCLE
# ==============================================================================
func _ready() -> void:
	layer = 15 # Render cleanly above 3D viewport, matching other HUD overlays
	_build_clean_hud()
	configure_for_track(track_name, is_closed_loop, track_path_3d)

func _physics_process(delta: float) -> void:
	if not is_instance_valid(vehicle_node) or not is_instance_valid(track_path_3d):
		return

	_update_spline_progression()

	if is_timing_active:
		current_lap_time += delta
		_check_sector_and_lap_gates()
		_update_hud_labels()
	else:
		# Wait for the car to cross the Start Line to begin Out-Lap / Hot-Lap
		_check_initial_start_trigger()

# ==============================================================================
# PUBLIC API: TRACK SWITCHING & CONFIGURATION
# ==============================================================================
## Call this from TougeTrackRegistryAndMenu.gd or TougeMultiEnvironmentManager.gd
func configure_for_track(new_track_name: String, closed_loop: bool, new_path: Path3D, car: Node3D = null) -> void:
	track_name = new_track_name.to_upper()
	is_closed_loop = closed_loop
	track_path_3d = new_path
	if is_instance_valid(car):
		vehicle_node = car

	if is_instance_valid(track_path_3d) and is_instance_valid(track_path_3d.curve):
		track_length = maxf(track_path_3d.curve.get_baked_length(), 1.0)

	if is_closed_loop:
		current_mode = TimingMode.CLOSED_LOOP_CIRCUIT
		active_sector_thresholds = TSUKUBA_SECTORS.duplicate()
	else:
		current_mode = TimingMode.POINT_TO_POINT_TOUGE
		active_sector_thresholds = TOUGE_SECTORS.duplicate()

	reset_session()

func reset_session() -> void:
	is_timing_active = false
	current_lap_time = 0.0
	best_lap_time = INF
	last_lap_time = 0.0
	lap_count = 0
	current_sector_index = 0
	current_sector_start_time = 0.0

	var sector_count: int = active_sector_thresholds.size()
	current_lap_sector_times.resize(sector_count)
	current_lap_sector_times.fill(0.0)

	best_lap_sector_times.resize(sector_count)
	best_lap_sector_times.fill(INF)

	optimal_sector_times.resize(sector_count)
	optimal_sector_times.fill(INF)

	if is_instance_valid(vehicle_node) and is_instance_valid(track_path_3d):
		current_progress_ratio = _compute_normalized_progress(vehicle_node.global_position)
		previous_progress_ratio = current_progress_ratio
	else:
		current_progress_ratio = 0.0
		previous_progress_ratio = 0.0

	max_progress_reached_this_lap = 0.0
	split_banner_panel.modulate.a = 0.0

	# In Point-to-Point Touge, start timing immediately or on movement
	if current_mode == TimingMode.POINT_TO_POINT_TOUGE:
		start_timing_run()
	else:
		# For Tsukuba, start immediately as Lap 1 [HOT LAP]
		start_timing_run()

	_update_hud_labels()

func start_timing_run() -> void:
	is_timing_active = true
	current_lap_time = 0.0
	current_sector_index = 0
	current_sector_start_time = 0.0
	max_progress_reached_this_lap = 0.0
	if current_mode == TimingMode.CLOSED_LOOP_CIRCUIT and lap_count == 0:
		lap_count = 1

# ==============================================================================
# SPLINE PROGRESSION & GATE DETECTION
# ==============================================================================
func _update_spline_progression() -> void:
	previous_progress_ratio = current_progress_ratio
	current_progress_ratio = _compute_normalized_progress(vehicle_node.global_position)

	# Record forward progress to prevent reversing across the start/finish line
	if current_progress_ratio > max_progress_reached_this_lap and (current_progress_ratio - previous_progress_ratio) < 0.4:
		max_progress_reached_this_lap = current_progress_ratio

func _compute_normalized_progress(world_pos: Vector3) -> float:
	var local_pos: Vector3 = track_path_3d.to_local(world_pos)
	var closest_offset: float = track_path_3d.curve.get_closest_offset(local_pos)
	return clampf(closest_offset / track_length, 0.0, 1.0)

func _check_initial_start_trigger() -> void:
	# Trigger start if crossing the 0.0 spline seam going forward
	if previous_progress_ratio > 0.85 and current_progress_ratio < 0.15:
		start_timing_run()

func _check_sector_and_lap_gates() -> void:
	var total_sectors: int = active_sector_thresholds.size()
	if current_sector_index >= total_sectors:
		return

	var target_ratio: float = active_sector_thresholds[current_sector_index]
	var is_final_sector: bool = (current_sector_index == total_sectors - 1)

	if not is_final_sector:
		# Intermediate Sector Gate (e.g., Tsukuba Sector 1 @ 32%, Sector 2 @ 68%)
		if previous_progress_ratio < target_ratio and current_progress_ratio >= target_ratio:
			_on_intermediate_sector_crossed(current_sector_index)
	else:
		# Final Sector / Finish Line Gate
		if current_mode == TimingMode.CLOSED_LOOP_CIRCUIT:
			# Detect wrap-around from >85% to <15% while ensuring intermediate gates were passed
			var wrapped_around: bool = (previous_progress_ratio > 0.85 and current_progress_ratio < 0.15)
			if wrapped_around and max_progress_reached_this_lap > 0.75:
				_on_closed_loop_lap_completed()
		else:
			# Point-to-Point Touge Finish Gate (approx 99% of spline)
			if current_progress_ratio >= 0.99 and max_progress_reached_this_lap > 0.85:
				_on_touge_finish_crossed()

func _on_intermediate_sector_crossed(sector_idx: int) -> void:
	var sector_split_time: float = current_lap_time - current_sector_start_time
	current_lap_sector_times[sector_idx] = sector_split_time
	current_sector_start_time = current_lap_time

	# Compute Cumulative Time up to this sector vs Best Lap's Cumulative Time
	var cumulative_current: float = current_lap_time
	var cumulative_best: float = _get_best_cumulative_time_up_to(sector_idx)
	var delta: float = 0.0
	var has_reference: bool = (cumulative_best < INF)

	if has_reference:
		delta = cumulative_current - cumulative_best

	# Update Optimal Sector Record
	var is_purple_sector: bool = false
	if sector_split_time < optimal_sector_times[sector_idx]:
		optimal_sector_times[sector_idx] = sector_split_time
		is_purple_sector = true

	_show_sector_delta_banner(sector_idx + 1, sector_split_time, delta, has_reference, is_purple_sector)
	_update_live_delta_display(delta, has_reference, is_purple_sector)

	sector_crossed.emit(sector_idx + 1, sector_split_time, delta)
	current_sector_index += 1

func _on_closed_loop_lap_completed() -> void:
	var final_sector_idx: int = active_sector_thresholds.size() - 1
	var final_sector_time: float = current_lap_time - current_sector_start_time
	current_lap_sector_times[final_sector_idx] = final_sector_time

	if final_sector_time < optimal_sector_times[final_sector_idx]:
		optimal_sector_times[final_sector_idx] = final_sector_time

	last_lap_time = current_lap_time
	var has_previous_best: bool = (best_lap_time < INF)
	var lap_delta: float = (last_lap_time - best_lap_time) if has_previous_best else 0.0
	var is_new_best: bool = (last_lap_time < best_lap_time)

	if is_new_best:
		best_lap_time = last_lap_time
		best_lap_sector_times = current_lap_sector_times.duplicate()

	_show_lap_completion_banner(lap_count, last_lap_time, lap_delta, has_previous_best, is_new_best)
	_update_live_delta_display(lap_delta, has_previous_best, is_new_best)
	lap_completed.emit(lap_count, last_lap_time, is_new_best)

	# Seamless Transition to Next Hot-Lap
	lap_count += 1
	current_lap_time = 0.0
	current_sector_index = 0
	current_sector_start_time = 0.0
	max_progress_reached_this_lap = 0.0

func _on_touge_finish_crossed() -> void:
	is_timing_active = false
	last_lap_time = current_lap_time
	if last_lap_time < best_lap_time:
		best_lap_time = last_lap_time

	var rank: String = _calculate_touge_rank(last_lap_time)
	_show_touge_finish_banner(last_lap_time, rank)
	touge_run_completed.emit(last_lap_time, rank)
	_update_hud_labels()

# ==============================================================================
# HELPERS & CALCULATIONS
# ==============================================================================
func _get_best_cumulative_time_up_to(sector_idx: int) -> float:
	if best_lap_time >= INF:
		return INF
	var total: float = 0.0
	for i in range(sector_idx + 1):
		if best_lap_sector_times[i] >= INF:
			return INF
		total += best_lap_sector_times[i]
	return total

func _calculate_touge_rank(total_time: float) -> String:
	if total_time <= rank_s_threshold:
		return "S"
	elif total_time <= rank_a_threshold:
		return "A"
	elif total_time <= rank_b_threshold:
		return "B"
	elif total_time <= rank_c_threshold:
		return "C"
	return "D"

static func format_race_time(time_sec: float) -> String:
	if time_sec >= INF or time_sec <= 0.0:
		return "-'--.--"
	var minutes: int = int(time_sec / 60.0)
	var seconds: int = int(time_sec) % 60
	var hundredths: int = int(fmod(time_sec, 1.0) * 100.0)
	return "%d'%02d.%02d" % [minutes, seconds, hundredths]

static func format_delta_time(delta_sec: float) -> String:
	var sign_str: String = "+" if delta_sec >= 0.0 else "-"
	return "%s%.2fs" % [sign_str, absf(delta_sec)]

# ==============================================================================
# HUD CONSTRUCTION & UPDATES (TOP-CENTER NON-COLLIDING LAYOUT)
# ==============================================================================
func _build_clean_hud() -> void:
	hud_root = Control.new()
	hud_root.name = "CircuitTimingHUD"
	hud_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud_root)

	# Top-Center Main Timing Box (Avoids Top-Left Radio, Top-Right Drift HUD, Bottom-Center Cluster)
	var main_panel := PanelContainer.new()
	main_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	main_panel.offset_left = -145.0
	main_panel.offset_right = 145.0
	main_panel.offset_top = 14.0
	main_panel.offset_bottom = 118.0

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.05, 0.06, 0.08, 0.86)
	panel_style.border_width_left = 2
	panel_style.border_width_top = 2
	panel_style.border_width_right = 2
	panel_style.border_width_bottom = 2
	panel_style.border_color = Color(0.25, 0.75, 1.0, 0.75)
	panel_style.corner_radius_top_left = 4
	panel_style.corner_radius_top_right = 4
	panel_style.corner_radius_bottom_left = 4
	panel_style.corner_radius_bottom_right = 4
	panel_style.content_margin_left = 12.0
	panel_style.content_margin_right = 12.0
	panel_style.content_margin_top = 8.0
	panel_style.content_margin_bottom = 8.0
	main_panel.add_theme_stylebox_override("panel", panel_style)
	hud_root.add_child(main_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	main_panel.add_child(vbox)

	lap_header_label = _create_hud_label("LAP: 01 [HOT LAP]", 14, Color(0.4, 0.85, 1.0))
	current_time_label = _create_hud_label("CURRENT: 0'00.00", 16, COLOR_NEUTRAL)
	best_time_label = _create_hud_label("BEST:    -'--.--", 14, Color(0.75, 0.8, 0.85))
	delta_label = _create_hud_label("DELTA:   --.--s", 14, COLOR_NEUTRAL)

	vbox.add_child(lap_header_label)
	vbox.add_child(current_time_label)
	vbox.add_child(best_time_label)
	vbox.add_child(delta_label)

	# Momentary Sector Split Banner directly underneath Top-Center Panel
	split_banner_panel = PanelContainer.new()
	split_banner_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	split_banner_panel.offset_left = -145.0
	split_banner_panel.offset_right = 145.0
	split_banner_panel.offset_top = 124.0
	split_banner_panel.offset_bottom = 158.0
	split_banner_panel.modulate.a = 0.0

	var banner_style := panel_style.duplicate()
	banner_style.bg_color = Color(0.08, 0.09, 0.12, 0.92)
	split_banner_panel.add_theme_stylebox_override("panel", banner_style)
	hud_root.add_child(split_banner_panel)

	split_banner_label = _create_hud_label("SECTOR 1: 0'18.42 (-0.24s)", 14, COLOR_FASTER)
	split_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	split_banner_panel.add_child(split_banner_label)

func _create_hud_label(initial_text: String, font_size: int, font_color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = initial_text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", font_color)
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	return lbl

func _update_hud_labels() -> void:
	if current_mode == TimingMode.CLOSED_LOOP_CIRCUIT:
		lap_header_label.text = "LAP: %02d [HOT LAP]" % max(lap_count, 1)
	else:
		var sec_num: int = clampi(current_sector_index + 1, 1, active_sector_thresholds.size())
		lap_header_label.text = "TOUGE [SECTOR %d/%d]" % [sec_num, active_sector_thresholds.size()]

	current_time_label.text = "CURRENT: %s" % format_race_time(current_lap_time)
	best_time_label.text = "BEST:    %s" % format_race_time(best_lap_time)

func _update_live_delta_display(delta: float, has_reference: bool, is_optimal: bool) -> void:
	if not has_reference:
		delta_label.text = "DELTA:   --.--s (BASE)"
		delta_label.add_theme_color_override("font_color", COLOR_NEUTRAL)
		return

	var suffix: String = " (OPTIMAL)" if delta <= 0.0 or is_optimal else ""
	delta_label.text = "DELTA:   %s%s" % [format_delta_time(delta), suffix]

	if delta <= 0.0:
		delta_label.add_theme_color_override("font_color", COLOR_FASTER)
	else:
		delta_label.add_theme_color_override("font_color", COLOR_SLOWER)

func _show_sector_delta_banner(sector_num: int, split_time: float, delta: float, has_ref: bool, is_purple: bool) -> void:
	if not has_ref:
		split_banner_label.text = "S%d SPLIT: %s" % [sector_num, format_race_time(split_time)]
		split_banner_label.add_theme_color_override("font_color", COLOR_OPTIMAL if is_purple else COLOR_NEUTRAL)
	else:
		split_banner_label.text = "S%d: %s (%s)" % [sector_num, format_race_time(split_time), format_delta_time(delta)]
		if delta <= 0.0:
			split_banner_label.add_theme_color_override("font_color", COLOR_FASTER)
		else:
			split_banner_label.add_theme_color_override("font_color", COLOR_SLOWER)

	_trigger_banner_fade(3.0)

func _show_lap_completion_banner(lap_num: int, lap_time: float, delta: float, has_ref: bool, is_new_best: bool) -> void:
	if is_new_best:
		var delta_str: String = " (%s)" % format_delta_time(delta) if has_ref else ""
		split_banner_label.text = "BEST LAP %02d: %s%s" % [lap_num, format_race_time(lap_time), delta_str]
		split_banner_label.add_theme_color_override("font_color", COLOR_FASTER)
	else:
		split_banner_label.text = "LAP %02d: %s (%s)" % [lap_num, format_race_time(lap_time), format_delta_time(delta)]
		split_banner_label.add_theme_color_override("font_color", COLOR_SLOWER)

	_trigger_banner_fade(3.0)

func _show_touge_finish_banner(total_time: float, rank: String) -> void:
	split_banner_label.text = "FINISH: %s [RANK %s]" % [format_race_time(total_time), rank]
	split_banner_label.add_theme_color_override("font_color", COLOR_FASTER)
	_trigger_banner_fade(6.0)

func _trigger_banner_fade(hold_duration: float) -> void:
	if is_instance_valid(banner_tween):
		banner_tween.kill()

	split_banner_panel.modulate.a = 1.0
	banner_tween = create_tween()
	banner_tween.tween_interval(hold_duration)
	banner_tween.tween_property(split_banner_panel, "modulate:a", 0.0, 0.45)