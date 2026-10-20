class_name ForzaHUDAndManual
extends CanvasLayer
## Forza-Style Drift Scoring Engine, Sector Lap Timing & Interactive JDM Telemetry Manual
## Production Subsystem for "ShiTmoZ/RACING" (Godot 4.3 Vulkan Forward+)

# ==============================================================================
# SIGNALS
# ==============================================================================
signal drift_started()
signal drift_banked(final_score: int, max_multiplier: float)
signal drift_failed(lost_score: int)
signal sector_completed(sector_index: int, sector_time: float, delta_time: float)
signal lap_completed(lap_time: float, is_new_record: bool)
signal manual_toggled(is_open: bool)

# ==============================================================================
# CONSTANTS & CONFIGURATION
# ==============================================================================
const SAVE_PATH: String = "user://touge_records.cfg"
const SAVE_SECTION: String = "MountAkinaTouge"

const DRIFT_MIN_SPEED_KMH: float = 28.0
const DRIFT_MIN_SLIP_ANGLE: float = 12.0
const DRIFT_GRACE_PERIOD: float = 1.35
const DRIFT_MAX_MULTIPLIER: float = 5.0
const COLLISION_FAIL_G_FORCE: float = 14.5 # Sudden deceleration threshold (m/s^2)
const PROXIMITY_RAY_LENGTH: float = 3.2   # Meters to detect guardrail proximity

const SECTOR_COUNT: int = 4

# ==============================================================================
# TELEMETRY & VEHICLE STATE
# ==============================================================================
var active_vehicle: Node3D = null
var _vehicle_search_timer: float = 0.0

var current_speed_kmh: float = 0.0
var current_slip_angle: float = 0.0
var current_lateral_slip: float = 0.0
var current_rpm: float = 850.0
var current_gear: int = 1
var _previous_velocity: Vector3 = Vector3.ZERO
var _previous_slip_sign: int = 0
var _near_guardrail: bool = false

# ==============================================================================
# DRIFT SCORING STATE
# ==============================================================================
enum DriftState { IDLE, DRIFTING, GRACE, BANKING, FAILED }
var drift_state: DriftState = DriftState.IDLE

var current_drift_points: float = 0.0
var displayed_drift_points: float = 0.0
var current_multiplier: float = 1.0
var session_total_banked: int = 0
var best_single_drift: int = 0

var _drift_duration: float = 0.0
var _grace_timer: float = 0.0
var _transition_cooldown: float = 0.0
var _Transition_bonus_count: int = 0

# ==============================================================================
# LAP & SECTOR TIMING STATE
# ==============================================================================
var lap_active: bool = true
var current_lap_time: float = 0.0
var current_sector_index: int = 0
var current_sector_start_time: float = 0.0

var current_sector_times: Array[float] = [0.0, 0.0, 0.0, 0.0]
var best_lap_time: float = -1.0
var best_sector_times: Array[float] = [-1.0, -1.0, -1.0, -1.0]
var top_leaderboard: Array[Dictionary] = []

# Auto-progression simulation fallback if track triggers aren't present
var _accumulated_distance_m: float = 0.0
const DEFAULT_SECTOR_DISTANCES: Array[float] = [850.0, 1750.0, 2600.0, 3500.0]

# ==============================================================================
# UI NODE REFERENCES
# ==============================================================================
var _root_control: Control

# Top-Center Drift Ticker
var _drift_container: Control
var _drift_rating_label: Label
var _drift_score_label: Label
var _drift_multiplier_label: Label
var _drift_sub_bonus_label: Label
var _drift_grace_bar: ProgressBar
var _drift_shader_mat: ShaderMaterial
var _drift_anim_tween: Tween

# Top-Left Timing & Leaderboard HUD
var _timing_panel: PanelContainer
var _lap_time_label: Label
var _best_lap_label: Label
var _sector_boxes: Array[PanelContainer] = []
var _sector_delta_label: Label
var _banked_score_label: Label
var _best_drift_label: Label

# Bottom-Right Mini Telemetry & Hint
var _telemetry_panel: PanelContainer
var _speed_label: Label
var _slip_label: Label
var _gear_label: Label
var _rpm_bar: ProgressBar
var _f1_prompt_label: Label

# Interactive Manual Overlay (F1)
var _manual_open: bool = false
var _manual_backdrop: ColorRect
var _manual_window: PanelContainer
var _manual_tab_buttons: Array[Button] = []
var _manual_tab_pages: Array[Control] = []
var _manual_tween: Tween
var _power_curve_canvas: Control

# Audio Generator (Procedural UI Synth)
var _audio_player: AudioStreamPlayer
var _audio_playback: AudioStreamGeneratorPlayback

# ==============================================================================
# LIFECYCLE
# ==============================================================================
func _init() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS

func _ready() -> void:
	_load_records()
	_setup_procedural_audio()
	_build_entire_ui()
	_acquire_vehicle()
	_set_manual_open(false, true)

func _process(delta: float) -> void:
	if not is_instance_valid(active_vehicle):
		_vehicle_search_timer -= delta
		if _vehicle_search_timer <= 0.0:
			_vehicle_search_timer = 1.0
			_acquire_vehicle()
	
	if not get_tree().paused:
		_update_timing(delta)
		_update_hud_visuals(delta)

func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	if is_instance_valid(active_vehicle):
		_poll_vehicle_telemetry(delta)
		_evaluate_drift_scoring(delta)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			_set_manual_open(not _manual_open)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _manual_open:
			_set_manual_open(false)
			get_viewport().set_input_as_handled()

# ==============================================================================
# VEHICLE ACQUISITION & REAL-TIME TELEMETRY
# ==============================================================================
func _acquire_vehicle() -> void:
	var group_nodes := get_tree().get_nodes_in_group("player_vehicle")
	if group_nodes.size() > 0 and group_nodes[0] is Node3D:
		active_vehicle = group_nodes[0] as Node3D
		return

	# Search scene tree for ArcadeSimVehicle class or script name
	var root := get_tree().current_scene
	if root:
		active_vehicle = _find_vehicle_recursive(root)

func _find_vehicle_recursive(node: Node) -> Node3D:
	if node is Node3D:
		var script_obj: Script = node.get_script()
		if script_obj and script_obj.get_global_name() == "ArcadeSimVehicle":
			return node
		if node.name.contains("ArcadeSimVehicle") or node.name.contains("BNR34") or node is VehicleBody3D:
			return node
	for child in node.get_children():
		var found := _find_vehicle_recursive(child)
		if found:
			return found
	return null

func _poll_vehicle_telemetry(delta: float) -> void:
	var velocity: Vector3 = Vector3.ZERO
	
	# Extract velocity from RigidBody3D / VehicleBody3D / CharacterBody3D or custom property
	if "linear_velocity" in active_vehicle:
		velocity = active_vehicle.get("linear_velocity")
	elif "velocity" in active_vehicle:
		velocity = active_vehicle.get("velocity")
	
	var speed_mps: float = velocity.length()
	if "speed_kmh" in active_vehicle:
		current_speed_kmh = float(active_vehicle.get("speed_kmh"))
	else:
		current_speed_kmh = speed_mps * 3.6

	# Forward vector (-Z in Godot 3D convention)
	var forward_dir: Vector3 = -active_vehicle.global_transform.basis.z
	forward_dir.y = 0.0
	if forward_dir.length_squared() > 0.0001:
		forward_dir = forward_dir.normalized()
	else:
		forward_dir = Vector3.FORWARD

	var horizontal_vel := Vector3(velocity.x, 0.0, velocity.z)
	
	if "slip_angle" in active_vehicle:
		current_slip_angle = absf(float(active_vehicle.get("slip_angle")))
	elif horizontal_vel.length() > 1.5:
		var vel_dir := horizontal_vel.normalized()
		var angle_rad := forward_dir.signed_angle_to(vel_dir, Vector3.UP)
		current_slip_angle = absf(rad_to_deg(angle_rad))
		var current_sign := signi(int(rad_to_deg(angle_rad)))
		
		# Detect High-Angle Kansei Switch / Manji Transition
		if _transition_cooldown > 0.0:
			_transition_cooldown -= delta
		if drift_state == DriftState.DRIFTING and current_slip_angle > 18.0:
			if _previous_slip_sign != 0 and current_sign != 0 and current_sign != _previous_slip_sign and _transition_cooldown <= 0.0:
				_trigger_transition_bonus()
				_transition_cooldown = 1.1
			_previous_slip_sign = current_sign
	else:
		current_slip_angle = 0.0

	if "lateral_slip" in active_vehicle:
		current_lateral_slip = absf(float(active_vehicle.get("lateral_slip")))
	else:
		var right_dir := active_vehicle.global_transform.basis.x.normalized()
		current_lateral_slip = absf(velocity.dot(right_dir))

	# Engine RPM & Gear polling with realistic fallback calculation
	if "engine_rpm" in active_vehicle:
		current_rpm = float(active_vehicle.get("engine_rpm"))
	elif "rpm" in active_vehicle:
		current_rpm = float(active_vehicle.get("rpm"))
	else:
		current_rpm = clampf(900.0 + fmod(current_speed_kmh * 115.0, 7200.0), 900.0, 8200.0)

	if "current_gear" in active_vehicle:
		current_gear = int(active_vehicle.get("current_gear"))
	elif "gear" in active_vehicle:
		current_gear = int(active_vehicle.get("gear"))
	else:
		current_gear = clampi(1 + int(current_speed_kmh / 42.0), 1, 6)

	# Check hard guardrail impact via sudden deceleration spike
	var accel_vec: Vector3 = (velocity - _previous_velocity) / maxf(delta, 0.001)
	var decel_magnitude: float = -accel_vec.dot(forward_dir)
	_previous_velocity = velocity

	if "is_colliding_hard" in active_vehicle and bool(active_vehicle.get("is_colliding_hard")):
		_on_hard_collision_detected()
	elif decel_magnitude > COLLISION_FAIL_G_FORCE * 9.81 * 0.18 and current_speed_kmh > 20.0:
		_on_hard_collision_detected()

	# Raycast left & right to detect guardrail / cliff shaving proximity
	_check_guardrail_proximity()

	# Distance integration for automatic sector splits if track triggers aren't wired
	_accumulated_distance_m += (current_speed_kmh / 3.6) * delta
	if current_sector_index < DEFAULT_SECTOR_DISTANCES.size():
		if _accumulated_distance_m >= DEFAULT_SECTOR_DISTANCES[current_sector_index]:
			trigger_sector_split(current_sector_index)

func _check_guardrail_proximity() -> void:
	_near_guardrail = false
	if not is_instance_valid(active_vehicle) or not active_vehicle.is_inside_tree():
		return
	var space_state := active_vehicle.get_world_3d().direct_space_state
	if not space_state:
		return

	var origin := active_vehicle.global_position + Vector3(0, 0.6, 0)
	var right_vec := active_vehicle.global_transform.basis.x.normalized()
	
	for side in [-1.0, 1.0]:
		var target := origin + right_vec * (side * PROXIMITY_RAY_LENGTH)
		var query := PhysicsRayQueryParameters3D.create(origin, target)
		if active_vehicle is CollisionObject3D:
			query.exclude = [active_vehicle.get_rid()]
		var result := space_state.intersect_ray(query)
		if not result.is_empty():
			_near_guardrail = true
			break

# ==============================================================================
# 1. FORZA-STYLE DRIFT SCORING & MULTIPLIER ENGINE
# ==============================================================================
func _evaluate_drift_scoring(delta: float) -> void:
	var meets_drift_criteria: bool = (
		current_speed_kmh >= DRIFT_MIN_SPEED_KMH and 
		current_slip_angle >= DRIFT_MIN_SLIP_ANGLE
	)

	match drift_state:
		DriftState.IDLE, DriftState.BANKING, DriftState.FAILED:
			if meets_drift_criteria:
				_start_new_drift()

		DriftState.DRIFTING:
			if meets_drift_criteria:
				_accumulate_drift(delta)
			else:
				drift_state = DriftState.GRACE
				_grace_timer = DRIFT_GRACE_PERIOD

		DriftState.GRACE:
			if meets_drift_criteria:
				drift_state = DriftState.DRIFTING
				_accumulate_drift(delta)
			else:
				_grace_timer -= delta
				if _grace_timer <= 0.0:
					_bank_current_drift()

func _start_new_drift() -> void:
	drift_state = DriftState.DRIFTING
	current_drift_points = 0.0
	displayed_drift_points = 0.0
	current_multiplier = 1.0
	_drift_duration = 0.0
	_Transition_bonus_count = 0
	_grace_timer = DRIFT_GRACE_PERIOD
	_previous_slip_sign = 0

	_drift_container.visible = true
	_drift_container.modulate = Color.WHITE
	_drift_grace_bar.visible = true
	_drift_sub_bonus_label.text = ""
	_play_ui_tone(520.0, 0.07, 0.12)
	drift_started.emit()

func _accumulate_drift(delta: float) -> void:
	_drift_duration += delta
	_grace_timer = DRIFT_GRACE_PERIOD

	# Base points scale with slip angle, speed, and lateral slip
	var angle_factor: float = clampf((current_slip_angle - DRIFT_MIN_SLIP_ANGLE) / 48.0, 0.15, 2.2)
	var speed_factor: float = clampf((current_speed_kmh - DRIFT_MIN_SPEED_KMH) / 110.0, 0.25, 2.5)
	var lat_bonus: float = clampf(current_lateral_slip / 15.0, 0.0, 1.2)
	
	var points_per_sec: float = (185.0 * angle_factor * speed_factor) + (65.0 * lat_bonus)

	# Proximity to guardrail / cliff bonus
	var proximity_mult_rate: float = 0.0
	if _near_guardrail:
		points_per_sec *= 1.45
		proximity_mult_rate = 0.38
		_drift_sub_bonus_label.text = "GUARDRAIL SHAVE +45%"
		_drift_sub_bonus_label.modulate = Color(0.3, 0.95, 1.0)
	elif current_slip_angle > 38.0:
		_drift_sub_bonus_label.text = "EXTREME ANGLE!"
		_drift_sub_bonus_label.modulate = Color(1.0, 0.78, 0.2)

	current_drift_points += points_per_sec * delta

	# Escalate Multiplier (1.0x up to 5.0x)
	var mult_growth: float = 0.24 + (0.14 * angle_factor) + proximity_mult_rate
	var prev_int_mult := int(floor(current_multiplier))
	current_multiplier = minf(DRIFT_MAX_MULTIPLIER, current_multiplier + mult_growth * delta)
	var new_int_mult := int(floor(current_multiplier))

	if new_int_mult > prev_int_mult:
		_pulse_control(_drift_multiplier_label, Vector2(1.45, 1.45), 0.22)
		_play_ui_tone(440.0 + new_int_mult * 110.0, 0.09, 0.16)

func _trigger_transition_bonus() -> void:
	_Transition_bonus_count += 1
	var bonus_pts: float = 450.0 * current_multiplier
	current_drift_points += bonus_pts
	current_multiplier = minf(DRIFT_MAX_MULTIPLIER, current_multiplier + 0.45)

	_drift_sub_bonus_label.text = "KANSEI SWITCH! +%d" % int(bonus_pts)
	_drift_sub_bonus_label.modulate = Color(1.0, 0.4, 0.85)
	_pulse_control(_drift_sub_bonus_label, Vector2(1.3, 1.3), 0.25)
	_play_ui_tone(780.0, 0.08, 0.14)

func _on_hard_collision_detected() -> void:
	if drift_state == DriftState.DRIFTING or drift_state == DriftState.GRACE:
		var lost_total := int(current_drift_points * current_multiplier)
		drift_state = DriftState.FAILED
		_drift_grace_bar.visible = false
		_drift_rating_label.text = "DRIFT FAILED"
		_drift_rating_label.modulate = Color(1.0, 0.18, 0.18)
		_drift_sub_bonus_label.text = "WALL IMPACT - COMBO LOST"
		_drift_sub_bonus_label.modulate = Color(1.0, 0.3, 0.3)
		_drift_shader_mat.set_shader_parameter("intensity", 0.0)
		_drift_score_label.modulate = Color(0.9, 0.2, 0.2)

		_shake_control(_drift_container, 14.0, 0.4)
		_play_ui_tone(155.0, 0.28, 0.22)
		drift_failed.emit(lost_total)

		if _drift_anim_tween and _drift_anim_tween.is_valid():
			_drift_anim_tween.kill()
		_drift_anim_tween = create_tween()
		_drift_anim_tween.tween_interval(1.4)
		_drift_anim_tween.tween_property(_drift_container, "modulate:a", 0.0, 0.4)
		_drift_anim_tween.tween_callback(func():
			if drift_state == DriftState.FAILED:
				_drift_container.visible = false
				drift_state = DriftState.IDLE
		)

func _bank_current_drift() -> void:
	var final_banked := int(round(current_drift_points * current_multiplier))
	if final_banked < 50:
		_drift_container.visible = false
		drift_state = DriftState.IDLE
		return

	drift_state = DriftState.BANKING
	session_total_banked += final_banked
	if final_banked > best_single_drift:
		best_single_drift = final_banked
		_save_records()

	_drift_grace_bar.visible = false
	_drift_rating_label.text = "SCORE BANKED!"
	_drift_rating_label.modulate = Color(0.25, 1.0, 0.55)
	_drift_score_label.text = "+%s PTS" % _format_number_commas(final_banked)
	_drift_sub_bonus_label.text = "ADDED TO TOUGE SESSION BANK"
	_drift_sub_bonus_label.modulate = Color(0.5, 1.0, 0.75)

	_pulse_control(_drift_container, Vector2(1.22, 1.22), 0.32)
	_pulse_control(_banked_score_label, Vector2(1.18, 1.18), 0.3)
	_play_ui_tone(880.0, 0.14, 0.18)
	drift_banked.emit(final_banked, current_multiplier)

	if _drift_anim_tween and _drift_anim_tween.is_valid():
		_drift_anim_tween.kill()
	_drift_anim_tween = create_tween()
	_drift_anim_tween.tween_interval(1.35)
	_drift_anim_tween.tween_property(_drift_container, "modulate:a", 0.0, 0.45)
	_drift_anim_tween.tween_callback(func():
		if drift_state == DriftState.BANKING:
			_drift_container.visible = false
			drift_state = DriftState.IDLE
	)

# ==============================================================================
# 2. SECTOR LAP TIMING & MOUNTAIN TOUGE RECORDS
# ==============================================================================
func _update_timing(delta: float) -> void:
	if not lap_active:
		return
	current_lap_time += delta

## Call this from Track Area3D checkpoints or let distance auto-progression call it
func trigger_sector_split(sector_idx: int) -> void:
	if sector_idx < 0 or sector_idx >= SECTOR_COUNT:
		return

	var sector_duration: float = current_lap_time - current_sector_start_time
	current_sector_times[sector_idx] = sector_duration
	current_sector_start_time = current_lap_time

	var prev_best_sector: float = best_sector_times[sector_idx]
	var delta_time: float = 0.0
	var has_reference: bool = prev_best_sector > 0.0

	if has_reference:
		delta_time = sector_duration - prev_best_sector
		_show_sector_delta(sector_idx, delta_time)
	else:
		_show_sector_delta(sector_idx, 0.0, true)

	if prev_best_sector <= 0.0 or sector_duration < prev_best_sector:
		best_sector_times[sector_idx] = sector_duration

	_color_sector_box(sector_idx, delta_time, has_reference)
	sector_completed.emit(sector_idx, sector_duration, delta_time)

	# Final sector completes the Touge run/lap
	if sector_idx == SECTOR_COUNT - 1:
		_complete_lap()
	else:
		current_sector_index = sector_idx + 1

func _complete_lap() -> void:
	var finished_time: float = current_lap_time
	var is_new_record: bool = (best_lap_time <= 0.0 or finished_time < best_lap_time)

	if is_new_record:
		best_lap_time = finished_time
		_play_ui_tone(1046.5, 0.25, 0.2)

	top_leaderboard.append({
		"time": finished_time,
		"drift_score": session_total_banked,
		"car": "BNR34 Skyline GT-R"
	})
	top_leaderboard.sort_custom(func(a, b): return a["time"] < b["time"])
	if top_leaderboard.size() > 5:
		top_leaderboard.resize(5)

	_save_records()
	lap_completed.emit(finished_time, is_new_record)

	# Reset for next lap/run
	current_lap_time = 0.0
	current_sector_start_time = 0.0
	current_sector_index = 0
	_accumulated_distance_m = 0.0

	# Reset sector boxes after brief delay
	var t := create_tween()
	t.tween_interval(3.0)
	t.tween_callback(_reset_sector_boxes_visual)

func _show_sector_delta(sector_idx: int, delta_sec: float, is_baseline: bool = false) -> void:
	_sector_delta_label.visible = true
	if is_baseline:
		_sector_delta_label.text = "S%d  %s (BASELINE)" % [sector_idx + 1, _format_time_ms(current_sector_times[sector_idx])]
		_sector_delta_label.modulate = Color(0.65, 0.85, 1.0)
	elif delta_sec <= 0.0:
		_sector_delta_label.text = "S%d  -%0.2fs" % [sector_idx + 1, absf(delta_sec)]
		_sector_delta_label.modulate = Color(0.2, 1.0, 0.45) # Green pace
	else:
		_sector_delta_label.text = "S%d  +%0.2fs" % [sector_idx + 1, delta_sec]
		_sector_delta_label.modulate = Color(1.0, 0.28, 0.28) # Red pace

	_pulse_control(_sector_delta_label, Vector2(1.2, 1.2), 0.25)

func _color_sector_box(idx: int, delta_sec: float, has_reference: bool) -> void:
	if idx >= _sector_boxes.size():
		return
	var sb := _sector_boxes[idx].get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	if not has_reference:
		sb.bg_color = Color(0.65, 0.25, 0.95, 0.85) # Purple first set
	elif delta_sec <= 0.0:
		sb.bg_color = Color(0.15, 0.88, 0.42, 0.9)  # Green faster split
	else:
		sb.bg_color = Color(0.95, 0.22, 0.22, 0.9)  # Red slower split
	_sector_boxes[idx].add_theme_stylebox_override("panel", sb)

func _reset_sector_boxes_visual() -> void:
	for box in _sector_boxes:
		var sb := box.get_theme_stylebox("panel").duplicate() as StyleBoxFlat
		sb.bg_color = Color(0.18, 0.2, 0.25, 0.75)
		box.add_theme_stylebox_override("panel", sb)

# ==============================================================================
# PERSISTENCE VIA CONFIGFILE (user://touge_records.cfg)
# ==============================================================================
func _load_records() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SAVE_PATH)
	if err != OK:
		# Seed authentic default Mount Akina benchmark records
		best_lap_time = 198.420 # 03:18.420
		best_sector_times = [48.110, 51.240, 49.850, 49.220]
		best_single_drift = 42500
		top_leaderboard = [
			{"time": 198.420, "drift_score": 148500, "car": "BNR34 Skyline GT-R"},
			{"time": 201.850, "drift_score": 132000, "car": "FD3S RX-7 Spirit R"},
			{"time": 204.115, "drift_score": 165400, "car": "AE86 Sprinter Trueno"}
		]
		_save_records()
		return

	best_lap_time = float(cfg.get_value(SAVE_SECTION, "best_lap_time", 198.420))
	var loaded_sectors: Array = cfg.get_value(SAVE_SECTION, "best_sector_times", [48.110, 51.240, 49.850, 49.220])
	for i in range(min(SECTOR_COUNT, loaded_sectors.size())):
		best_sector_times[i] = float(loaded_sectors[i])
	best_single_drift = int(cfg.get_value(SAVE_SECTION, "best_single_drift", 42500))
	top_leaderboard = cfg.get_value(SAVE_SECTION, "leaderboard", [])

func _save_records() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(SAVE_SECTION, "best_lap_time", best_lap_time)
	cfg.set_value(SAVE_SECTION, "best_sector_times", best_sector_times)
	cfg.set_value(SAVE_SECTION, "best_single_drift", best_single_drift)
	cfg.set_value(SAVE_SECTION, "leaderboard", top_leaderboard)
	cfg.save(SAVE_PATH)

# ==============================================================================
# HUD REAL-TIME VISUAL UPDATES
# ==============================================================================
func _update_hud_visuals(delta: float) -> void:
	# Update Drift Ticker
	if drift_state == DriftState.DRIFTING or drift_state == DriftState.GRACE:
		displayed_drift_points = lerpf(displayed_drift_points, current_drift_points, clampf(delta * 14.0, 0.0, 1.0))
		var total_potential := int(round(displayed_drift_points * current_multiplier))
		_drift_score_label.text = "%s" % _format_number_commas(int(round(displayed_drift_points)))
		_drift_multiplier_label.text = "x%0.1f" % current_multiplier
		_drift_score_label.modulate = Color.WHITE

		# Escalating Forza Drift Rating Tiers & Shader Fire Intensity
		var heat_intensity: float = clampf((total_potential / 18000.0) + ((current_multiplier - 1.0) / 4.0) * 0.5, 0.0, 1.0)
		_drift_shader_mat.set_shader_parameter("intensity", heat_intensity)

		if total_potential >= 15000 or current_multiplier >= 4.2:
			_drift_rating_label.text = "ULTIMATE TOUGE DRIFT!"
			_drift_rating_label.modulate = Color(1.0, 0.38, 0.08)
		elif total_potential >= 5500 or current_multiplier >= 2.5:
			_drift_rating_label.text = "AWESOME DRIFT"
			_drift_rating_label.modulate = Color(1.0, 0.78, 0.15)
		else:
			_drift_rating_label.text = "GREAT DRIFT"
			_drift_rating_label.modulate = Color(0.92, 0.96, 1.0)

		_drift_grace_bar.value = (_grace_timer / DRIFT_GRACE_PERIOD) * 100.0

	# Update Timing & Leaderboard Panel
	_lap_time_label.text = _format_time_ms(current_lap_time)
	_best_lap_label.text = "BEST: %s" % (_format_time_ms(best_lap_time) if best_lap_time > 0.0 else "--:--.---")
	_banked_score_label.text = "SESSION DRIFT: %s PTS" % _format_number_commas(session_total_banked)
	_best_drift_label.text = "RECORD COMBO: %s PTS" % _format_number_commas(best_single_drift)

	# Update Telemetry Readout
	_speed_label.text = "%03d" % int(round(current_speed_kmh))
	_slip_label.text = "SLIP: %04.1f° | LAT: %0.1f m/s" % [current_slip_angle, current_lateral_slip]
	_gear_label.text = "R" if current_gear < 0 else ("N" if current_gear == 0 else str(current_gear))
	_rpm_bar.value = current_rpm

# ==============================================================================
# 3. INTERACTIVE JDM MANUAL & TELEMETRY HANDBOOK (F1 OVERLAY)
# ==============================================================================
func _set_manual_open(open: bool, immediate: bool = false) -> void:
	_manual_open = open
	manual_toggled.emit(_manual_open)
	_play_ui_tone(660.0 if open else 420.0, 0.08, 0.12)

	if _manual_tween and _manual_tween.is_valid():
		_manual_tween.kill()

	if immediate:
		_manual_backdrop.visible = open
		_manual_backdrop.modulate.a = 1.0 if open else 0.0
		_manual_window.scale = Vector2.ONE if open else Vector2(0.94, 0.94)
		return

	_manual_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if open:
		_manual_backdrop.visible = true
		_manual_window.pivot_offset = _manual_window.size * 0.5
		_manual_tween.tween_property(_manual_backdrop, "modulate:a", 1.0, 0.24)
		_manual_tween.tween_property(_manual_window, "scale", Vector2.ONE, 0.26).from(Vector2(0.93, 0.93))
	else:
		_manual_window.pivot_offset = _manual_window.size * 0.5
		_manual_tween.tween_property(_manual_backdrop, "modulate:a", 0.0, 0.2)
		_manual_tween.tween_property(_manual_window, "scale", Vector2(0.94, 0.94), 0.2)
		_manual_tween.chain().tween_callback(func(): _manual_backdrop.visible = false)

func _switch_manual_tab(tab_idx: int) -> void:
	_play_ui_tone(580.0 + tab_idx * 90.0, 0.06, 0.1)
	for i in range(_manual_tab_pages.size()):
		_manual_tab_pages[i].visible = (i == tab_idx)
		var btn := _manual_tab_buttons[i]
		if i == tab_idx:
			btn.modulate = Color(1.0, 0.82, 0.25)
		else:
			btn.modulate = Color(0.75, 0.8, 0.88)
	if tab_idx == 0 and is_instance_valid(_power_curve_canvas):
		_power_curve_canvas.queue_redraw()

# ==============================================================================
# PROCEDURAL UI CONSTRUCTION & SHADERS
# ==============================================================================
func _build_entire_ui() -> void:
	_root_control = Control.new()
	_root_control.name = "ForzaHUDRoot"
	_root_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root_control)

	_build_top_center_drift_ticker()
	_build_top_left_timing_hud()
	_build_bottom_right_telemetry_hud()
	_build_interactive_jdm_manual()

func _build_top_center_drift_ticker() -> void:
	_drift_container = Control.new()
	_drift_container.name = "DriftTickerContainer"
	_drift_container.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_drift_container.position = Vector2(-240, 28)
	_drift_container.size = Vector2(480, 150)
	_drift_container.pivot_offset = Vector2(240, 75)
	_drift_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drift_container.visible = false
	_root_control.add_child(_drift_container)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 2)
	_drift_container.add_child(vbox)

	# Rating Header ("GREAT DRIFT", "AWESOME DRIFT", "ULTIMATE TOUGE DRIFT!")
	_drift_rating_label = Label.new()
	_drift_rating_label.text = "GREAT DRIFT"
	_drift_rating_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_drift_rating_label.add_theme_font_size_override("font_size", 20)
	_drift_rating_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_drift_rating_label.add_theme_constant_override("outline_size", 6)
	vbox.add_child(_drift_rating_label)

	# Main Score & Multiplier Row
	var score_row := HBoxContainer.new()
	score_row.alignment = BoxContainer.ALIGNMENT_CENTER
	score_row.add_theme_constant_override("separation", 14)
	vbox.add_child(score_row)

	# Custom Fire/Gold Glowing Shader for Drift Counter
	var fire_shader := Shader.new()
	fire_shader.code = """
shader_type canvas_item;
uniform float intensity : hint_range(0.0, 1.0) = 0.3;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float wave = sin(UV.y * 6.0 - TIME * 7.0) * 0.5 + 0.5;
	vec3 cold_gold = mix(vec3(1.0, 0.96, 0.85), vec3(1.0, 0.78, 0.2), 1.0 - UV.y);
	vec3 hot_fire = mix(vec3(1.0, 0.22, 0.05), vec3(1.0, 0.92, 0.25), clamp(1.0 - UV.y + wave * 0.25, 0.0, 1.0));
	vec3 final_rgb = mix(cold_gold, hot_fire, intensity);
	COLOR = vec4(final_rgb * tex.rgb, tex.a);
}
"""
	_drift_shader_mat = ShaderMaterial.new()
	_drift_shader_mat.shader = fire_shader

	_drift_score_label = Label.new()
	_drift_score_label.text = "0"
	_drift_score_label.material = _drift_shader_mat
	_drift_score_label.add_theme_font_size_override("font_size", 52)
	_drift_score_label.add_theme_color_override("font_outline_color", Color(0.05, 0.02, 0.0, 0.95))
	_drift_score_label.add_theme_constant_override("outline_size", 10)
	score_row.add_child(_drift_score_label)

	_drift_multiplier_label = Label.new()
	_drift_multiplier_label.text = "x1.0"
	_drift_multiplier_label.add_theme_font_size_override("font_size", 34)
	_drift_multiplier_label.add_theme_color_override("font_color", Color(1.0, 0.65, 0.15))
	_drift_multiplier_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_drift_multiplier_label.add_theme_constant_override("outline_size", 8)
	score_row.add_child(_drift_multiplier_label)

	# Combo Grace Progress Bar
	_drift_grace_bar = ProgressBar.new()
	_drift_grace_bar.custom_minimum_size = Vector2(260, 6)
	_drift_grace_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_drift_grace_bar.show_percentage = false
	_drift_grace_bar.value = 100.0
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.1, 0.1, 0.12, 0.7)
	bar_bg.set_corner_radius_all(3)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(1.0, 0.68, 0.15, 0.95)
	bar_fill.set_corner_radius_all(3)
	_drift_grace_bar.add_theme_stylebox_override("background", bar_bg)
	_drift_grace_bar.add_theme_stylebox_override("fill", bar_fill)
	vbox.add_child(_drift_grace_bar)

	# Sub-bonus feedback ("GUARDRAIL SHAVE +45%", "KANSEI SWITCH!")
	_drift_sub_bonus_label = Label.new()
	_drift_sub_bonus_label.text = ""
	_drift_sub_bonus_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_drift_sub_bonus_label.add_theme_font_size_override("font_size", 14)
	_drift_sub_bonus_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_drift_sub_bonus_label.add_theme_constant_override("outline_size", 4)
	vbox.add_child(_drift_sub_bonus_label)

func _build_top_left_timing_hud() -> void:
	_timing_panel = PanelContainer.new()
	_timing_panel.position = Vector2(24, 24)
	_timing_panel.custom_minimum_size = Vector2(310, 165)
	_timing_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timing_panel.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.06, 0.08, 0.12, 0.78), Color(0.3, 0.6, 1.0, 0.35)))
	_root_control.add_child(_timing_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	_timing_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var header := Label.new()
	header.text = "MOUNT AKINA // TOUGE CHRONO"
	header.add_theme_font_size_override("font_size", 11)
	header.add_theme_color_override("font_color", Color(0.55, 0.78, 1.0))
	vbox.add_child(header)

	_lap_time_label = Label.new()
	_lap_time_label.text = "00:00.000"
	_lap_time_label.add_theme_font_size_override("font_size", 32)
	_lap_time_label.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0))
	vbox.add_child(_lap_time_label)

	var split_row := HBoxContainer.new()
	split_row.add_theme_constant_override("separation", 12)
	vbox.add_child(split_row)

	_best_lap_label = Label.new()
	_best_lap_label.text = "BEST: 03:18.420"
	_best_lap_label.add_theme_font_size_override("font_size", 13)
	_best_lap_label.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	split_row.add_child(_best_lap_label)

	_sector_delta_label = Label.new()
	_sector_delta_label.text = "S1 -0.24s"
	_sector_delta_label.visible = false
	_sector_delta_label.add_theme_font_size_override("font_size", 13)
	split_row.add_child(_sector_delta_label)

	# 4 Sector Split Indicator Boxes
	var sector_bar := HBoxContainer.new()
	sector_bar.add_theme_constant_override("separation", 6)
	vbox.add_child(sector_bar)

	_sector_boxes.clear()
	for i in range(SECTOR_COUNT):
		var sbox := PanelContainer.new()
		sbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sbox.custom_minimum_size = Vector2(0, 18)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.18, 0.2, 0.25, 0.75)
		sb.set_corner_radius_all(3)
		sbox.add_theme_stylebox_override("panel", sb)
		var slbl := Label.new()
		slbl.text = "S%d" % (i + 1)
		slbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slbl.add_theme_font_size_override("font_size", 10)
		sbox.add_child(slbl)
		sector_bar.add_child(sbox)
		_sector_boxes.append(sbox)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	_banked_score_label = Label.new()
	_banked_score_label.text = "SESSION DRIFT: 0 PTS"
	_banked_score_label.add_theme_font_size_override("font_size", 14)
	_banked_score_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.22))
	vbox.add_child(_banked_score_label)

	_best_drift_label = Label.new()
	_best_drift_label.text = "RECORD COMBO: 42,500 PTS"
	_best_drift_label.add_theme_font_size_override("font_size", 11)
	_best_drift_label.add_theme_color_override("font_color", Color(0.65, 0.72, 0.8))
	vbox.add_child(_best_drift_label)

func _build_bottom_right_telemetry_hud() -> void:
	_telemetry_panel = PanelContainer.new()
	_telemetry_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_telemetry_panel.position = Vector2(-304, -158)
	_telemetry_panel.size = Vector2(280, 134)
	_telemetry_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_telemetry_panel.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.06, 0.08, 0.12, 0.78), Color(1.0, 0.55, 0.15, 0.35)))
	_root_control.add_child(_telemetry_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_telemetry_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	var top_row := HBoxContainer.new()
	top_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	vbox.add_child(top_row)

	_speed_label = Label.new()
	_speed_label.text = "000"
	_speed_label.add_theme_font_size_override("font_size", 40)
	_speed_label.add_theme_color_override("font_color", Color(0.98, 0.98, 1.0))
	top_row.add_child(_speed_label)

	var unit_lbl := Label.new()
	unit_lbl.text = " KM/H"
	unit_lbl.size_flags_vertical = Control.SIZE_SHRINK_END
	unit_lbl.add_theme_font_size_override("font_size", 14)
	unit_lbl.add_theme_color_override("font_color", Color(0.6, 0.75, 0.95))
	top_row.add_child(unit_lbl)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(spacer)

	_gear_label = Label.new()
	_gear_label.text = "1"
	_gear_label.add_theme_font_size_override("font_size", 38)
	_gear_label.add_theme_color_override("font_color", Color(1.0, 0.72, 0.18))
	top_row.add_child(_gear_label)

	_rpm_bar = ProgressBar.new()
	_rpm_bar.min_value = 0.0
	_rpm_bar.max_value = 9000.0
	_rpm_bar.value = 1000.0
	_rpm_bar.show_percentage = false
	_rpm_bar.custom_minimum_size = Vector2(0, 8)
	var rpm_bg := StyleBoxFlat.new()
	rpm_bg.bg_color = Color(0.15, 0.16, 0.2, 0.85)
	rpm_bg.set_corner_radius_all(3)
	var rpm_fill := StyleBoxFlat.new()
	rpm_fill.bg_color = Color(0.98, 0.32, 0.18, 0.95)
	rpm_fill.set_corner_radius_all(3)
	_rpm_bar.add_theme_stylebox_override("background", rpm_bg)
	_rpm_bar.add_theme_stylebox_override("fill", rpm_fill)
	vbox.add_child(_rpm_bar)

	_slip_label = Label.new()
	_slip_label.text = "SLIP: 00.0° | LAT: 0.0 m/s"
	_slip_label.add_theme_font_size_override("font_size", 12)
	_slip_label.add_theme_color_override("font_color", Color(0.75, 0.85, 0.96))
	vbox.add_child(_slip_label)

	_f1_prompt_label = Label.new()
	_f1_prompt_label.text = "[F1] JDM TELEMETRY & DRIVER MANUAL"
	_f1_prompt_label.add_theme_font_size_override("font_size", 11)
	_f1_prompt_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	vbox.add_child(_f1_prompt_label)

# ==============================================================================
# 3. INTERACTIVE JDM DRIVER MANUAL & TELEMETRY HANDBOOK BUILDER
# ==============================================================================
func _build_interactive_jdm_manual() -> void:
	_manual_backdrop = ColorRect.new()
	_manual_backdrop.name = "JDMManualBackdrop"
	_manual_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_manual_backdrop.color = Color(0.02, 0.03, 0.05, 0.76)

	# Frosted-glass screen-space blur shader
	var frost_shader := Shader.new()
	frost_shader.code = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur_lod : hint_range(0.0, 5.0) = 2.6;
uniform vec4 tint : source_color = vec4(0.03, 0.05, 0.09, 0.82);

void fragment() {
	vec3 blurred = textureLod(screen_tex, SCREEN_UV, blur_lod).rgb;
	COLOR = vec4(mix(blurred, tint.rgb, tint.a), 1.0);
}
"""
	var frost_mat := ShaderMaterial.new()
	frost_mat.shader = frost_shader
	_manual_backdrop.material = frost_mat
	_root_control.add_child(_manual_backdrop)

	var center_wrap := CenterContainer.new()
	center_wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	_manual_backdrop.add_child(center_wrap)

	_manual_window = PanelContainer.new()
	_manual_window.custom_minimum_size = Vector2(960, 600)
	_manual_window.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.07, 0.09, 0.14, 0.94), Color(0.38, 0.68, 1.0, 0.55)))
	center_wrap.add_child(_manual_window)

	var outer_margin := MarginContainer.new()
	outer_margin.add_theme_constant_override("margin_left", 24)
	outer_margin.add_theme_constant_override("margin_right", 24)
	outer_margin.add_theme_constant_override("margin_top", 20)
	outer_margin.add_theme_constant_override("margin_bottom", 20)
	_manual_window.add_child(outer_margin)

	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 14)
	outer_margin.add_child(main_vbox)

	# Header Bar
	var header_bar := HBoxContainer.new()
	main_vbox.add_child(header_bar)

	var title_vbox := VBoxContainer.new()
	header_bar.add_child(title_vbox)

	var title_lbl := Label.new()
	title_lbl.text = "NISMO // BNR34 SKYLINE GT-R V-SPEC II NUR — TECHNICAL HANDBOOK"
	title_lbl.add_theme_font_size_override("font_size", 20)
	title_lbl.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0))
	title_vbox.add_child(title_lbl)

	var subtitle_lbl := Label.new()
	subtitle_lbl.text = "ShiTmoZ/RACING — MOUNT AKINA TOUGE TELEMETRY & DRIVER'S COMPENDIUM"
	subtitle_lbl.add_theme_font_size_override("font_size", 12)
	subtitle_lbl.add_theme_color_override("font_color", Color(0.55, 0.78, 1.0))
	title_vbox.add_child(subtitle_lbl)

	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_bar.add_child(header_spacer)

	var close_btn := Button.new()
	close_btn.text = " CLOSE [ESC / F1] "
	close_btn.custom_minimum_size = Vector2(150, 36)
	close_btn.pressed.connect(func(): _set_manual_open(false))
	header_bar.add_child(close_btn)

	# Navigation Tabs Row
	var tab_bar := HBoxContainer.new()
	tab_bar.add_theme_constant_override("separation", 10)
	main_vbox.add_child(tab_bar)

	var tab_titles: Array[String] = [
		"  [1] TECH SPECS: BNR34 GT-R  ",
		"  [2] TOUGE TECHNIQUES & DRIFT THEORY  ",
		"  [3] CONTROLS, AUDIO & GRAPHICS  "
	]
	_manual_tab_buttons.clear()
	for i in range(tab_titles.size()):
		var tbtn := Button.new()
		tbtn.text = tab_titles[i]
		tbtn.custom_minimum_size = Vector2(260, 38)
		var idx := i
		tbtn.pressed.connect(func(): _switch_manual_tab(idx))
		tab_bar.add_child(tbtn)
		_manual_tab_buttons.append(tbtn)

	var div := HSeparator.new()
	main_vbox.add_child(div)

	# Content Stack Container
	var content_area := Control.new()
	content_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(content_area)

	_manual_tab_pages.clear()
	var page1 := _build_tab_1_tech_specs()
	var page2 := _build_tab_2_touge_techniques()
	var page3 := _build_tab_3_controls_and_settings()

	for page in [page1, page2, page3]:
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		content_area.add_child(page)
		_manual_tab_pages.append(page)

	_switch_manual_tab(0)

func _build_tab_1_tech_specs() -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 20)

	# Left Column: RB26DETT & Chassis Specs + Gear Ratios
	var left_vbox := VBoxContainer.new()
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.add_theme_constant_override("separation", 10)
	hbox.add_child(left_vbox)

	var spec_card := PanelContainer.new()
	spec_card.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.1, 0.13, 0.19, 0.8), Color(0.3, 0.55, 0.9, 0.3)))
	left_vbox.add_child(spec_card)

	var spec_margin := MarginContainer.new()
	spec_margin.add_theme_constant_override("margin_left", 14)
	spec_margin.add_theme_constant_override("margin_right", 14)
	spec_margin.add_theme_constant_override("margin_top", 12)
	spec_margin.add_theme_constant_override("margin_bottom", 12)
	spec_card.add_child(spec_margin)

	var spec_text := RichTextLabel.new()
	spec_text.bbcode_enabled = true
	spec_text.fit_content = true
	spec_text.text = (
		"[b][color=#ffd147]POWERTRAIN & CHASSIS SPECIFICATION[/color][/b]\n" +
		"• [b]Engine Code:[/b] Nissan RB26DETT — 2,568cc Inline-6 DOHC 24-Valve\n" +
		"• [b]Aspiration:[/b] Parallel Ceramic Twin-Turbochargers (Garrett T28, 1.15 bar)\n" +
		"• [b]Drivetrain:[/b] ATTESA E-TS PRO Active All-Wheel Drive + Active LSD\n" +
		"• [b]Steering:[/b] Super-HICAS Electronically Controlled 4-Wheel Steering\n" +
		"• [b]Max Output:[/b] 330 PS (243 kW) @ 6,800 RPM (Mine's Touge Tune: 460 PS)\n" +
		"• [b]Peak Torque:[/b] 400 Nm (295 lb-ft) @ 4,400 RPM | Redline: 8,200 RPM\n" +
		"• [b]Curb Weight:[/b] 1,560 kg (Front 57% / Rear 43% Distribution)\n\n" +
		"[b][color=#6bc2ff]GETRAG 233 6-SPEED CLOSE-RATIO TRANSMISSION[/color][/b]\n" +
		"1st: 3.827  |  2nd: 2.360  |  3rd: 1.685  |  4th: 1.312\n" +
		"5th: 1.000  |  6th: 0.793  |  Reverse: 3.280  |  Final Drive: 3.545"
	)
	spec_margin.add_child(spec_text)

	# Local Leaderboard Summary in Tab 1
	var lb_card := PanelContainer.new()
	lb_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lb_card.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.1, 0.13, 0.19, 0.8), Color(1.0, 0.7, 0.2, 0.3)))
	left_vbox.add_child(lb_card)

	var lb_margin := MarginContainer.new()
	lb_margin.add_theme_constant_override("margin_left", 14)
	lb_margin.add_theme_constant_override("margin_right", 14)
	lb_margin.add_theme_constant_override("margin_top", 10)
	lb_margin.add_theme_constant_override("margin_bottom", 10)
	lb_card.add_child(lb_margin)

	var lb_vbox := VBoxContainer.new()
	lb_margin.add_child(lb_vbox)

	var lb_title := Label.new()
	lb_title.text = "MOUNT AKINA LOCAL LEADERBOARD (user://touge_records.cfg)"
	lb_title.add_theme_font_size_override("font_size", 13)
	lb_title.add_theme_color_override("font_color", Color(1.0, 0.82, 0.28))
	lb_vbox.add_child(lb_title)

	for i in range(min(3, top_leaderboard.size())):
		var entry: Dictionary = top_leaderboard[i]
		var row := Label.new()
		row.text = "#%d  %s  —  %s  (Drift: %s pts)" % [
			i + 1,
			_format_time_ms(float(entry.get("time", 0.0))),
			str(entry.get("car", "BNR34")),
			_format_number_commas(int(entry.get("drift_score", 0)))
		]
		row.add_theme_font_size_override("font_size", 13)
		lb_vbox.add_child(row)

	# Right Column: Procedural Dyno Power & Torque Curve Graph
	var right_card := PanelContainer.new()
	right_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_card.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.08, 0.1, 0.15, 0.9), Color(0.4, 0.75, 1.0, 0.35)))
	hbox.add_child(right_card)

	_power_curve_canvas = Control.new()
	_power_curve_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_power_curve_canvas.draw.connect(_draw_rb26_dyno_curve)
	right_card.add_child(_power_curve_canvas)

	return hbox

func _draw_rb26_dyno_curve() -> void:
	if not is_instance_valid(_power_curve_canvas):
		return
	var c := _power_curve_canvas
	var rect_size := c.size
	var pad_left := 48.0
	var pad_right := 28.0
	var pad_top := 42.0
	var pad_bottom := 42.0
	var w := rect_size.x - pad_left - pad_right
	var h := rect_size.y - pad_top - pad_bottom
	if w <= 10.0 or h <= 10.0:
		return

	var font := ThemeDB.fallback_font
	c.draw_string(font, Vector2(pad_left, 26), "RB26DETT DYNO TELEMETRY: POWER (PS) & TORQUE (Nm) vs RPM", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.85, 0.92, 1.0))

	# Draw Grid Lines
	for i in range(6):
		var y := pad_top + (h / 5.0) * i
		c.draw_line(Vector2(pad_left, y), Vector2(pad_left + w, y), Color(0.25, 0.32, 0.42, 0.5), 1.0)
		var val_label := "%d" % int(500 - i * 100)
		c.draw_string(font, Vector2(8, y + 4), val_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.7, 0.8))

	for r in range(1, 10):
		var x := pad_left + (w / 8.0) * (r - 1)
		c.draw_line(Vector2(x, pad_top), Vector2(x, pad_top + h), Color(0.25, 0.32, 0.42, 0.4), 1.0)
		c.draw_string(font, Vector2(x - 12, pad_top + h + 22), "%dk" % r, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.7, 0.8))

	# Sample RB26DETT Twin-Turbo Power (PS) & Torque (Nm) curves across 1,000 - 9,000 RPM
	var power_pts := PackedVector2Array()
	var torque_pts := PackedVector2Array()
	var steps := 32
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var rpm := 1000.0 + t * 8000.0
		var x := pad_left + t * w

		# Twin-turbo spool surge around 3,600 RPM
		var spool := clampf((rpm - 2200.0) / 2200.0, 0.0, 1.0)
		var top_fade := clampf((9200.0 - rpm) / 2000.0, 0.2, 1.0)
		var torque_nm := 175.0 + 255.0 * sin(spool * PI * 0.5) * top_fade
		var power_ps := (torque_nm * rpm) / 7023.5

		var y_torque := pad_top + h - clampf(torque_nm / 500.0, 0.0, 1.0) * h
		var y_power := pad_top + h - clampf(power_ps / 500.0, 0.0, 1.0) * h

		torque_pts.append(Vector2(x, y_torque))
		power_pts.append(Vector2(x, y_power))

	c.draw_polyline(torque_pts, Color(0.25, 0.82, 1.0, 0.95), 3.0, true)
	c.draw_polyline(power_pts, Color(1.0, 0.45, 0.2, 0.95), 3.0, true)

	# Legend
	c.draw_rect(Rect2(pad_left + 12, pad_top + 10, 14, 14), Color(1.0, 0.45, 0.2))
	c.draw_string(font, Vector2(pad_left + 32, pad_top + 22), "HORSEPOWER (Peak 460 PS @ 7,200 RPM)", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.65, 0.4))
	c.draw_rect(Rect2(pad_left + 12, pad_top + 30, 14, 14), Color(0.25, 0.82, 1.0))
	c.draw_string(font, Vector2(pad_left + 32, pad_top + 42), "TORQUE (Peak 430 Nm @ 4,400 RPM)", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.45, 0.88, 1.0))

func _build_tab_2_touge_techniques() -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)

	var guides: Array[Dictionary] = [
		{
			"title": "01 // KANSEI DRIFT (INERTIA WEIGHT TRANSFER)",
			"subtitle": "High-Speed Sweeper Entry Technique",
			"color": Color(0.35, 0.82, 1.0),
			"body": (
				"[b]EXECUTION:[/b]\n" +
				"1. Approach a high-speed Touge sweeper in 3rd or 4th gear at >105 km/h.\n" +
				"2. Turn in sharply while [b]lifting off the throttle abruptly[/b] (zero braking).\n" +
				"3. Forward weight transfer loads the front tires while unweighting the rear axle, inducing immediate oversteer slip.\n" +
				"4. Modulate throttle at 60–85% so ATTESA E-TS vectors torque forward and pulls the nose along the apex line."
			)
		},
		{
			"title": "02 // CLUTCH KICK & HANDBRAKE INITIATION",
			"subtitle": "Hairpin Rotation & Tight Switchbacks",
			"color": Color(1.0, 0.75, 0.22),
			"body": (
				"[b]EXECUTION:[/b]\n" +
				"1. Trail-brake deep into the Mount Akina hairpin entry zone to compress the front suspension.\n" +
				"2. Tap [b][SPACE] Handbrake[/b] momentarily to lock the rear axle and break lateral traction.\n" +
				"3. Immediately floor the throttle into the RB26DETT twin-turbo boost zone (>4,400 RPM) to sustain a >25° slip angle.\n" +
				"4. Chain left-to-right switchbacks to trigger the [b]KANSEI SWITCH![/b] multiplier bonus."
			)
		},
		{
			"title": "03 // THE LEGENDARY AKINA GUTTER RUN",
			"subtitle": "Apex Centripetal Hook Technique",
			"color": Color(1.0, 0.38, 0.45),
			"body": (
				"[b]EXECUTION:[/b]\n" +
				"1. Align the inside front and rear tires directly above the concrete drainage channel on the inside apex.\n" +
				"2. Drop the inside wheels into the gutter before corner mid-point.\n" +
				"3. The vertical channel wall acts as a mechanical rail, countering centrifugal force without scrubbing tire speed.\n" +
				"4. Apply full throttle early out of the corner exit to gain -0.35s sector delta advantages."
			)
		}
	]

	for g in guides:
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.09, 0.12, 0.18, 0.86), g["color"]))
		hbox.add_child(card)

		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_left", 16)
		m.add_theme_constant_override("margin_right", 16)
		m.add_theme_constant_override("margin_top", 16)
		m.add_theme_constant_override("margin_bottom", 16)
		card.add_child(m)

		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 8)
		m.add_child(v)

		var t := Label.new()
		t.text = g["title"]
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		t.add_theme_font_size_override("font_size", 15)
		t.add_theme_color_override("font_color", g["color"])
		v.add_child(t)

		var sub := Label.new()
		sub.text = g["subtitle"]
		sub.add_theme_font_size_override("font_size", 12)
		sub.add_theme_color_override("font_color", Color(0.68, 0.76, 0.88))
		v.add_child(sub)

		var sep := HSeparator.new()
		v.add_child(sep)

		var rtl := RichTextLabel.new()
		rtl.bbcode_enabled = true
		rtl.size_flags_vertical = Control.SIZE_EXPAND_FILL
		rtl.text = g["body"]
		v.add_child(rtl)

	return hbox

func _build_tab_3_controls_and_settings() -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 20)

	# Left: Keyboard & Gamepad Bindings
	var bind_card := PanelContainer.new()
	bind_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bind_card.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.09, 0.12, 0.18, 0.86), Color(0.4, 0.7, 1.0, 0.35)))
	hbox.add_child(bind_card)

	var bm := MarginContainer.new()
	bm.add_theme_constant_override("margin_left", 16)
	bm.add_theme_constant_override("margin_right", 16)
	bm.add_theme_constant_override("margin_top", 14)
	bm.add_theme_constant_override("margin_bottom", 14)
	bind_card.add_child(bm)

	var b_rtl := RichTextLabel.new()
	b_rtl.bbcode_enabled = true
	b_rtl.text = (
		"[b][color=#ffd147]KEYBOARD & DUALSENSE / XBOX GAMEPAD BINDINGS[/color][/b]\n\n" +
		"• [b]Throttle / Accelerate:[/b] [W] / [Up Arrow]  |  Gamepad [R2 / RT]\n" +
		"• [b]Brakes / Reverse:[/b] [S] / [Down Arrow]  |  Gamepad [L2 / LT]\n" +
		"• [b]Steering Left / Right:[/b] [A] & [D] / [Arrows]  |  Left Analog Stick\n" +
		"• [b]E-Brake / Drift Initiation:[/b] [SPACEBAR]  |  Gamepad [Cross / A]\n" +
		"• [b]Sequential Shift Up / Down:[/b] [E] / [Q]  |  [R1 / RB] & [L1 / LB]\n" +
		"• [b]Cycle Camera Modes:[/b] [C] (Chase / Hood / Cockpit / Touge Cinematic)\n" +
		"• [b]High-Beam Pop-Up / Xenon Headlights:[/b] [L]  |  D-Pad Up\n" +
		"• [b]Reset Vehicle to Track Centerline:[/b] [R]  |  [Select / Back]\n" +
		"• [b]Toggle JDM Telemetry Manual:[/b] [F1] or [ESC]"
	)
	bm.add_child(b_rtl)

	# Right: Interactive Audio Sliders, Camera Selector & Vulkan Forward+ Presets
	var set_card := PanelContainer.new()
	set_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	set_card.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.09, 0.12, 0.18, 0.86), Color(1.0, 0.65, 0.25, 0.35)))
	hbox.add_child(set_card)

	var sm := MarginContainer.new()
	sm.add_theme_constant_override("margin_left", 18)
	sm.add_theme_constant_override("margin_right", 18)
	sm.add_theme_constant_override("margin_top", 14)
	sm.add_theme_constant_override("margin_bottom", 14)
	set_card.add_child(sm)

	var svbox := VBoxContainer.new()
	svbox.add_theme_constant_override("separation", 12)
	sm.add_child(svbox)

	var stitle := Label.new()
	stitle.text = "LIVE TELEMETRY, AUDIO & VULKAN FORWARD+ SETTINGS"
	stitle.add_theme_font_size_override("font_size", 15)
	stitle.add_theme_color_override("font_color", Color(1.0, 0.82, 0.28))
	svbox.add_child(stitle)

	# Master Volume Slider
	var vol_row := HBoxContainer.new()
	svbox.add_child(vol_row)
	var vol_lbl := Label.new()
	vol_lbl.text = "Master Audio Bus Volume:"
	vol_lbl.custom_minimum_size = Vector2(190, 0)
	vol_row.add_child(vol_lbl)

	var vol_slider := HSlider.new()
	vol_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vol_slider.min_value = -30.0
	vol_slider.max_value = 6.0
	vol_slider.step = 0.5
	vol_slider.value = AudioServer.get_bus_volume_db(0)
	vol_slider.value_changed.connect(func(v: float):
		AudioServer.set_bus_volume_db(0, v)
		AudioServer.set_bus_mute(0, v <= -29.5)
	)
	vol_row.add_child(vol_slider)

	# Camera Mode Selector
	var cam_row := HBoxContainer.new()
	svbox.add_child(cam_row)
	var cam_lbl := Label.new()
	cam_lbl.text = "Active Camera Rig:"
	cam_lbl.custom_minimum_size = Vector2(190, 0)
	cam_row.add_child(cam_lbl)

	var cam_opt := OptionButton.new()
	cam_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cam_opt.add_item("Dynamic Forza Chase Cam")
	cam_opt.add_item("BNR34 Nismo Cockpit View")
	cam_opt.add_item("Carbon Hood Telemetry Cam")
	cam_opt.add_item("Akina Touge Helicopter Rig")
	cam_opt.item_selected.connect(func(idx: int):
		_play_ui_tone(620.0, 0.06, 0.1)
		if is_instance_valid(active_vehicle) and active_vehicle.has_method("set_camera_mode"):
			active_vehicle.call("set_camera_mode", idx)
	)
	cam_row.add_child(cam_opt)

	# Graphical Preset Switch
	var gfx_row := HBoxContainer.new()
	svbox.add_child(gfx_row)
	var gfx_lbl := Label.new()
	gfx_lbl.text = "Vulkan Forward+ Preset:"
	gfx_lbl.custom_minimum_size = Vector2(190, 0)
	gfx_row.add_child(gfx_lbl)

	var gfx_opt := OptionButton.new()
	gfx_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gfx_opt.add_item("ULTRA — MSAA 4x + SDFGI + Volumetric Fog")
	gfx_opt.add_item("HIGH — MSAA 2x + SSR + Glow")
	gfx_opt.add_item("COMPETITIVE 144Hz — FXAA + Low Latency")
	gfx_opt.item_selected.connect(_apply_graphics_preset)
	gfx_row.add_child(gfx_opt)

	# Manual Sector Split Test & Record Reset Buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	svbox.add_child(btn_row)

	var sim_split_btn := Button.new()
	sim_split_btn.text = "Simulate Sector Split"
	sim_split_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sim_split_btn.pressed.connect(func(): trigger_sector_split(current_sector_index))
	btn_row.add_child(sim_split_btn)

	var reset_rec_btn := Button.new()
	reset_rec_btn.text = "Reset Touge Records"
	reset_rec_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_rec_btn.pressed.connect(func():
		best_lap_time = 198.420
		best_sector_times = [48.110, 51.240, 49.850, 49.220]
		_save_records()
		_play_ui_tone(330.0, 0.15, 0.15)
	)
	btn_row.add_child(reset_rec_btn)

	return hbox

func _apply_graphics_preset(preset_idx: int) -> void:
	_play_ui_tone(720.0, 0.08, 0.12)
	var vp := get_viewport()
	if not vp:
		return
	match preset_idx:
		0: # ULTRA
			vp.msaa_3d = Viewport.MSAA_4X
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			vp.scaling_3d_scale = 1.0
		1: # HIGH
			vp.msaa_3d = Viewport.MSAA_2X
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			vp.scaling_3d_scale = 1.0
		2: # COMPETITIVE
			vp.msaa_3d = Viewport.MSAA_DISABLED
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			vp.scaling_3d_scale = 0.9

# ==============================================================================
# PROCEDURAL AUDIO SYNTHESIZER & ANIMATION HELPERS
# ==============================================================================
func _setup_procedural_audio() -> void:
	_audio_player = AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = 22050.0
	gen.buffer_length = 0.35
	_audio_player.stream = gen
	_audio_player.volume_db = -8.0
	add_child(_audio_player)
	_audio_player.play()
	_audio_playback = _audio_player.get_stream_playback() as AudioStreamGeneratorPlayback

func _play_ui_tone(freq_hz: float, duration_sec: float, amplitude: float = 0.15) -> void:
	if not _audio_playback:
		return
	var sample_rate: float = 22050.0
	var total_frames := mini(int(duration_sec * sample_rate), _audio_playback.get_frames_available())
	var phase: float = 0.0
	var increment: float = freq_hz / sample_rate
	for i in range(total_frames):
		var env: float = 1.0 - (float(i) / float(max(total_frames, 1)))
		var sample: float = sin(phase * TAU) * amplitude * env
		_audio_playback.push_frame(Vector2(sample, sample))
		phase = fmod(phase + increment, 1.0)

func _create_glass_stylebox(bg_col: Color, border_col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_col
	sb.border_color = border_col
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.set_corner_radius_all(8)
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 10
	return sb

func _pulse_control(ctrl: Control, peak_scale: Vector2, duration: float) -> void:
	if not is_instance_valid(ctrl):
		return
	ctrl.pivot_offset = ctrl.size * 0.5
	var t := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(ctrl, "scale", peak_scale, duration * 0.4)
	t.tween_property(ctrl, "scale", Vector2.ONE, duration * 0.6)

func _shake_control(ctrl: Control, magnitude: float, duration: float) -> void:
	if not is_instance_valid(ctrl):
		return
	var base_pos := ctrl.position
	var t := create_tween()
	var steps := 8
	for i in range(steps):
		var offset := Vector2(randf_range(-magnitude, magnitude), randf_range(-magnitude * 0.5, magnitude * 0.5))
		t.tween_property(ctrl, "position", base_pos + offset, duration / float(steps))
	t.tween_property(ctrl, "position", base_pos, 0.04)

func _format_time_ms(seconds: float) -> String:
	var total_ms := int(round(maxf(seconds, 0.0) * 1000.0))
	var mins := total_ms / 60000
	var secs := (total_ms / 1000) % 60
	var ms := total_ms % 1000
	return "%02d:%02d.%03d" % [mins, secs, ms]

func _format_number_commas(value: int) -> String:
	var s := str(absi(value))
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			out = "," + out
		out = s[i] + out
		count += 1
	return ("-" + out) if value < 0 else out