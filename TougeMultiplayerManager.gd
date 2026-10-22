# ==============================================================================
# File: res://TougeMultiplayerManager.gd
# Engine: Godot Engine 4.3 (Headless / Desktop CI Compatible)
# Architecture: High-Rate ENet P2P Touge Cat-and-Mouse Replication & Referee
# ==============================================================================
class_name TougeMultiplayerManager
extends Node

signal duel_connection_changed(status_text: String, is_connected: bool)
signal duel_countdown_tick(step_text: String)
signal duel_started()
signal duel_finished(winner_peer_id: int, reason: String)
signal rival_disconnected()

enum BattleState {
	IDLE = 0,
	LOBBY_WAITING = 1,
	COUNTDOWN = 2,
	RACING = 3,
	FINISHED = 4
}

@export_group("Network Configuration")
@export var default_ip: String = "127.0.0.1"
@export var default_port: int = 7777
@export_range(20.0, 60.0, 5.0) var tick_rate_hz: float = 45.0
@export_range(0.020, 0.100, 0.005) var interpolation_delay_sec: float = 0.045

@export_group("Cat-and-Mouse Battle Rules")
@export var grid_stagger_meters: float = 12.0
@export var sudden_death_gap_meters: float = 50.0
@export var overtake_margin_meters: float = 2.5
@export var finish_distance_fallback: float = 1200.0
@export var grace_period_sec: float = 6.0

# Network & Session State
var _enet_peer: ENetMultiplayerPeer = null
var _battle_state: BattleState = BattleState.IDLE
var _remote_peer_id: int = 0
var _ping_ms: float = 0.0
var _ping_timer: float = 0.0
var _sync_accumulator: float = 0.0
var _local_seq: int = 0
var _last_remote_seq: int = -1

# Scene & Vehicle References
var _scene_root: Node3D = null
var _local_vehicle: RigidBody3D = null
var _remote_proxy: Node3D = null
var _remote_wheel_fl: Node3D = null
var _remote_wheel_fr: Node3D = null
var _remote_brake_mat: StandardMaterial3D = null
var _remote_headlight_mat: StandardMaterial3D = null
var _remote_headlight_spot_l: SpotLight3D = null
var _remote_headlight_spot_r: SpotLight3D = null
var _synchronizer: MultiplayerSynchronizer = null

# Synchronized Exported Properties (for MultiplayerSynchronizer compatibility)
@export var sync_position: Vector3 = Vector3.ZERO
@export var sync_rotation: Quaternion = Quaternion.IDENTITY
@export var sync_velocity: Vector3 = Vector3.ZERO
@export var sync_steer_angle: float = 0.0
@export var sync_drift_angle_deg: float = 0.0
@export var sync_brake_light: bool = false
@export var sync_headlight_flash: bool = false

# Snapshot Interpolation Buffer
class NetworkSnapshot extends RefCounted:
	var timestamp: float = 0.0
	var seq: int = 0
	var position: Vector3 = Vector3.ZERO
	var rotation: Quaternion = Quaternion.IDENTITY
	var velocity: Vector3 = Vector3.ZERO
	var steer_angle: float = 0.0
	var drift_angle_deg: float = 0.0
	var brake_light_on: bool = false
	var headlights_flashing: bool = false

var _snapshot_buffer: Array[NetworkSnapshot] = []
const MAX_SNAPSHOT_BUFFER: int = 32

# Cat-and-Mouse Race Telemetry
var _track_curve: Curve3D = null
var _track_total_length: float = 1200.0
var _pole_spawn_transform: Transform3D = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
var _race_elapsed_sec: float = 0.0
var _countdown_timer: float = 0.0
var _last_countdown_int: int = -1
var _overtake_hold_timer: float = 0.0
var _current_gap_meters: float = 12.0
var _current_gap_seconds: float = 0.5
var _leader_peer_id: int = 1
var _chaser_peer_id: int = 0

# Dark-Glass UI Elements
var _ui_layer: CanvasLayer = null
var _lobby_panel: PanelContainer = null
var _ip_input: LineEdit = null
var _port_input: LineEdit = null
var _status_label: Label = null
var _ping_label: Label = null
var _host_btn: Button = null
var _join_btn: Button = null
var _disconnect_btn: Button = null
var _hud_panel: PanelContainer = null
var _gap_label: Label = null
var _role_label: Label = null
var _drift_telemetry_label: Label = null
var _center_banner_label: Label = null
var _banner_hide_timer: float = 0.0


# ==============================================================================
# INITIALIZATION & LIFECYCLE
# ==============================================================================

func _ready() -> void:
	_scene_root = get_parent() as Node3D
	if _scene_root == null and get_tree().current_scene is Node3D:
		_scene_root = get_tree().current_scene as Node3D

	_setup_multiplayer_signals()
	_setup_synchronizer()
	_build_dark_glass_ui()
	_auto_discover_scene_context()


func _exit_tree() -> void:
	disconnect_session()


## Binds the scene root, local player RigidBody3D, and optional Curve3D / Pole spawn.
func configure_battle_context(
	scene_root: Node3D,
	local_vehicle: RigidBody3D,
	track_curve: Curve3D = null,
	pole_spawn: Transform3D = Transform3D.IDENTITY
) -> void:
	_scene_root = scene_root
	_local_vehicle = local_vehicle
	if is_instance_valid(track_curve) and track_curve.point_count >= 2:
		_track_curve = track_curve
		_track_total_length = maxf(_track_curve.get_baked_length(), 100.0)
	else:
		_track_total_length = finish_distance_fallback

	if pole_spawn != Transform3D.IDENTITY:
		_pole_spawn_transform = pole_spawn
	elif is_instance_valid(_local_vehicle):
		_pole_spawn_transform = _local_vehicle.global_transform


func _auto_discover_scene_context() -> void:
	if not is_instance_valid(_scene_root):
		return
	for child in _scene_root.get_children():
		if _local_vehicle == null and child is RigidBody3D:
			_local_vehicle = child as RigidBody3D
			_pole_spawn_transform = _local_vehicle.global_transform
		elif child.has_method("get_active_curve"):
			var c: Variant = child.call("get_active_curve")
			if c is Curve3D and (c as Curve3D).point_count >= 2:
				_track_curve = c
				_track_total_length = maxf(_track_curve.get_baked_length(), 100.0)
			if child.has_method("get_spawn_transform"):
				var sp: Variant = child.call("get_spawn_transform")
				if sp is Transform3D:
					_pole_spawn_transform = sp


func _setup_multiplayer_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)


func _setup_synchronizer() -> void:
	_synchronizer = MultiplayerSynchronizer.new()
	_synchronizer.name = "TougeStateSynchronizer"
	var config: SceneReplicationConfig = SceneReplicationConfig.new()
	var props: Array[String] = [
		":sync_position",
		":sync_rotation",
		":sync_velocity",
		":sync_steer_angle",
		":sync_drift_angle_deg",
		":sync_brake_light",
		":sync_headlight_flash"
	]
	for p in props:
		var np: NodePath = NodePath(p)
		config.add_property(np)
		config.property_set_spawn(np, true)
		config.property_set_replication_mode(np, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_synchronizer.replication_config = config
	_synchronizer.replication_interval = 1.0 / tick_rate_hz
	add_child(_synchronizer)


# ==============================================================================
# NETWORKING ENGINE (HOST / JOIN / DISCONNECT)
# ==============================================================================

func host_duel(port: int = -1) -> Error:
	disconnect_session()
	var listen_port: int = port if port > 0 else default_port
	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_server(listen_port, 2)
	if err != OK:
		_update_status_ui("HOST FAILED (ERR %d) // PORT %d" % [err, listen_port], false)
		_enet_peer = null
		return err

	multiplayer.multiplayer_peer = _enet_peer
	_battle_state = BattleState.LOBBY_WAITING
	_leader_peer_id = 1
	_update_status_ui("HOSTING ON UDP :%d // AWAITING CHASER..." % listen_port, true)
	return OK


func join_duel(ip_address: String, port: int = -1) -> Error:
	disconnect_session()
	var clean_ip: String = ip_address.strip_edges()
	if clean_ip.is_empty():
		clean_ip = default_ip
	var target_port: int = port if port > 0 else default_port

	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_client(clean_ip, target_port)
	if err != OK:
		_update_status_ui("JOIN FAILED (ERR %d) -> %s:%d" % [err, clean_ip, target_port], false)
		_enet_peer = null
		return err

	multiplayer.multiplayer_peer = _enet_peer
	_battle_state = BattleState.LOBBY_WAITING
	_update_status_ui("CONNECTING TO %s:%d..." % [clean_ip, target_port], false)
	return OK


func disconnect_session() -> void:
	_despawn_remote_vehicle()
	_snapshot_buffer.clear()
	_remote_peer_id = 0
	_ping_ms = 0.0
	_last_remote_seq = -1
	_battle_state = BattleState.IDLE

	if is_instance_valid(_enet_peer):
		_enet_peer.close()
	_enet_peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

	_unlock_local_vehicle()
	_update_status_ui("OFFLINE // READY", false)
	if is_instance_valid(_hud_panel):
		_hud_panel.visible = false


# ==============================================================================
# MULTIPLAYER CONNECTION CALLBACKS
# ==============================================================================

func _on_peer_connected(id: int) -> void:
	_remote_peer_id = id
	_snapshot_buffer.clear()
	_last_remote_seq = -1
	_spawn_remote_vehicle_proxy(id)

	if multiplayer.is_server():
		_leader_peer_id = 1
		_chaser_peer_id = id
		_update_status_ui("PEER #%d CONNECTED // STARTING DUEL" % id, true)
		_rpc_begin_synchronized_duel.rpc(_leader_peer_id, _chaser_peer_id, _pole_spawn_transform)
	else:
		_update_status_ui("CONNECTED TO HOST #%d" % id, true)


func _on_peer_disconnected(id: int) -> void:
	if id == _remote_peer_id or _remote_peer_id != 0:
		_handle_rival_drop("RIVAL DISCONNECTED")


func _on_connected_to_server() -> void:
	_update_status_ui("CONNECTED // AWAITING GRID SYNC...", true)


func _on_connection_failed() -> void:
	disconnect_session()
	_update_status_ui("CONNECTION TIMEOUT // UNREACHABLE", false)


func _on_server_disconnected() -> void:
	_handle_rival_drop("HOST DISCONNECTED")
	disconnect_session()


func _handle_rival_drop(banner_msg: String) -> void:
	_despawn_remote_vehicle()
	_snapshot_buffer.clear()
	_remote_peer_id = 0
	_battle_state = BattleState.IDLE
	_unlock_local_vehicle()
	_show_center_banner(banner_msg, Color(1.0, 0.32, 0.24), 4.0)
	_update_status_ui(banner_msg, false)
	if is_instance_valid(_lobby_panel):
		_lobby_panel.visible = true
	rival_disconnected.emit()


# ==============================================================================
# INPUT & FRAME / PHYSICS PROCESS LOOP
# ==============================================================================

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ke: InputEventKey = event as InputEventKey
		if ke.pressed and not ke.echo and ke.keycode == KEY_O:
			if is_instance_valid(_lobby_panel):
				_lobby_panel.visible = not _lobby_panel.visible
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	# Banner auto-hide timer
	if _banner_hide_timer > 0.0:
		_banner_hide_timer -= delta
		if _banner_hide_timer <= 0.0 and is_instance_valid(_center_banner_label):
			_center_banner_label.visible = false

	# Interpolate remote rival vehicle at full display refresh rate (144Hz+ smooth)
	if _remote_peer_id != 0 and is_instance_valid(_remote_proxy):
		_interpolate_remote_vehicle(delta)

	# Ping / RTT heartbeat every 0.5s
	if _remote_peer_id != 0 and _enet_peer != null:
		_ping_timer += delta
		if _ping_timer >= 0.5:
			_ping_timer = 0.0
			_rpc_ping.rpc_id(_remote_peer_id, Time.get_ticks_usec())
		if is_instance_valid(_ping_label):
			_ping_label.text = "PING: %d ms // CONNECTED" % int(round(_ping_ms))


func _physics_process(delta: float) -> void:
	if _battle_state == BattleState.COUNTDOWN:
		_process_countdown(delta)
	elif _battle_state == BattleState.RACING:
		_process_cat_and_mouse_referee(delta)

	# Broadcast local vehicle state at configured tick_rate_hz (30-60 Hz)
	if _remote_peer_id != 0 and _enet_peer != null:
		_sync_accumulator += delta
		var interval: float = 1.0 / maxf(tick_rate_hz, 10.0)
		if _sync_accumulator >= interval:
			_sync_accumulator = fmod(_sync_accumulator, interval)
			_broadcast_local_vehicle_state()


# ==============================================================================
# VEHICLE SPAWNING, GRID POSITIONING & HIGH-RATE STATE REPLICATION
# ==============================================================================

@rpc("authority", "call_local", "reliable")
func _rpc_begin_synchronized_duel(leader_id: int, chaser_id: int, pole_xform: Transform3D) -> void:
	_auto_discover_scene_context()
	_leader_peer_id = leader_id
	_chaser_peer_id = chaser_id
	_pole_spawn_transform = pole_xform

	var my_id: int = multiplayer.get_unique_id()
	var is_leader: bool = (my_id == _leader_peer_id)

	var lead_xform: Transform3D = _compute_grid_slot_transform(0.0)
	var chase_xform: Transform3D = _compute_grid_slot_transform(-grid_stagger_meters)

	var my_xform: Transform3D = lead_xform if is_leader else chase_xform
	var rival_xform: Transform3D = chase_xform if is_leader else lead_xform

	if is_instance_valid(_local_vehicle):
		PhysicsServer3D.body_set_state(_local_vehicle.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, my_xform)
		PhysicsServer3D.body_set_state(_local_vehicle.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
		PhysicsServer3D.body_set_state(_local_vehicle.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
		_local_vehicle.global_transform = my_xform
		_local_vehicle.linear_velocity = Vector3.ZERO
		_local_vehicle.angular_velocity = Vector3.ZERO
		_lock_local_vehicle()

	if is_instance_valid(_remote_proxy):
		_remote_proxy.global_transform = rival_xform

	_snapshot_buffer.clear()
	_battle_state = BattleState.COUNTDOWN
	_countdown_timer = 3.99
	_last_countdown_int = -1
	_race_elapsed_sec = 0.0
	_overtake_hold_timer = 0.0
	_current_gap_meters = grid_stagger_meters

	if is_instance_valid(_lobby_panel):
		_lobby_panel.visible = false
	if is_instance_valid(_hud_panel):
		_hud_panel.visible = true
	if is_instance_valid(_role_label):
		_role_label.text = "ROLE: LEAD CAR (DEFEND GAP)" if is_leader else "ROLE: CHASER (OVERTAKE OR STAY <50m)"


func _compute_grid_slot_transform(longitudinal_offset: float) -> Transform3D:
	if is_instance_valid(_track_curve) and _track_curve.point_count >= 2:
		var dist: float = clampf(16.0 + longitudinal_offset, 0.0, _track_total_length - 5.0)
		var pos: Vector3 = _track_curve.sample_baked(dist, true) + Vector3(0.0, 0.65, 0.0)
		var pos_ahead: Vector3 = _track_curve.sample_baked(minf(dist + 4.0, _track_total_length), true) + Vector3(0.0, 0.65, 0.0)
		var fwd: Vector3 = (pos_ahead - pos).normalized()
		if fwd.length_squared() < 0.001:
			fwd = Vector3.FORWARD
		return Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)

	var forward_dir: Vector3 = -_pole_spawn_transform.basis.z.normalized()
	var slot_origin: Vector3 = _pole_spawn_transform.origin + forward_dir * longitudinal_offset
	return Transform3D(_pole_spawn_transform.basis, slot_origin)


func _broadcast_local_vehicle_state() -> void:
	if not is_instance_valid(_local_vehicle):
		_auto_discover_scene_context()
		if not is_instance_valid(_local_vehicle):
			return

	var pos: Vector3 = _local_vehicle.global_position
	var rot: Quaternion = _local_vehicle.global_transform.basis.get_rotation_quaternion()
	var vel: Vector3 = _local_vehicle.linear_velocity
	var fwd: Vector3 = -_local_vehicle.global_transform.basis.z.normalized()

	# Extract steering, brake lights, headlight flash, and compute slip/drift angle
	var steer: float = 0.0
	if "steering" in _local_vehicle:
		steer = float(_local_vehicle.get("steering"))
	elif "steer_angle" in _local_vehicle:
		steer = float(_local_vehicle.get("steer_angle"))

	var drift_deg: float = 0.0
	var flat_vel: Vector3 = Vector3(vel.x, 0.0, vel.z)
	var flat_fwd: Vector3 = Vector3(fwd.x, 0.0, fwd.z).normalized()
	if flat_vel.length() > 2.5 and flat_fwd.length_squared() > 0.1:
		drift_deg = rad_to_deg(flat_fwd.signed_angle_to(flat_vel.normalized(), Vector3.UP))

	var braking: bool = Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_SPACE)
	var flashing: bool = Input.is_key_pressed(KEY_H) or Input.is_key_pressed(KEY_F)

	sync_position = pos
	sync_rotation = rot
	sync_velocity = vel
	sync_steer_angle = steer
	sync_drift_angle_deg = drift_deg
	sync_brake_light = braking
	sync_headlight_flash = flashing

	_local_seq += 1
	_rpc_receive_vehicle_state.rpc_id(
		_remote_peer_id,
		_local_seq,
		pos,
		rot,
		vel,
		steer,
		drift_deg,
		braking,
		flashing
	)


@rpc("any_peer", "unreliable_ordered")
func _rpc_receive_vehicle_state(
	seq: int,
	pos: Vector3,
	rot: Quaternion,
	vel: Vector3,
	steer: float,
	drift_deg: float,
	brake_on: bool,
	flash_on: bool
) -> void:
	if seq <= _last_remote_seq:
		return
	_last_remote_seq = seq

	var snap: NetworkSnapshot = NetworkSnapshot.new()
	snap.timestamp = float(Time.get_ticks_usec()) * 0.000001
	snap.seq = seq
	snap.position = pos
	snap.rotation = rot.normalized()
	snap.velocity = vel
	snap.steer_angle = steer
	snap.drift_angle_deg = drift_deg
	snap.brake_light_on = brake_on
	snap.headlights_flashing = flash_on

	_snapshot_buffer.append(snap)
	while _snapshot_buffer.size() > MAX_SNAPSHOT_BUFFER:
		_snapshot_buffer.remove_at(0)


# ==============================================================================
# CLIENT-SIDE HERMITE & SLERP SNAPSHOT INTERPOLATOR
# ==============================================================================

func _interpolate_remote_vehicle(delta: float) -> void:
	var count: int = _snapshot_buffer.size()
	if count == 0:
		return

	var now_sec: float = float(Time.get_ticks_usec()) * 0.000001
	var render_time: float = now_sec - interpolation_delay_sec

	var interp_pos: Vector3
	var interp_rot: Quaternion
	var interp_steer: float
	var interp_drift: float
	var brake_on: bool
	var flash_on: bool

	if count == 1 or render_time <= _snapshot_buffer[0].timestamp:
		var s0: NetworkSnapshot = _snapshot_buffer[0]
		interp_pos = s0.position
		interp_rot = s0.rotation
		interp_steer = s0.steer_angle
		interp_drift = s0.drift_angle_deg
		brake_on = s0.brake_light_on
		flash_on = s0.headlights_flashing
	elif render_time >= _snapshot_buffer[count - 1].timestamp:
		# Dead-reckoning extrapolation capped to 60ms to prevent overshoot
		var latest: NetworkSnapshot = _snapshot_buffer[count - 1]
		var extrap_dt: float = clampf(render_time - latest.timestamp, 0.0, 0.060)
		interp_pos = latest.position + latest.velocity * extrap_dt
		interp_rot = latest.rotation
		interp_steer = latest.steer_angle
		interp_drift = latest.drift_angle_deg
		brake_on = latest.brake_light_on
		flash_on = latest.headlights_flashing
	else:
		# Locate bracketing snapshots [s_a, s_b] for Cubic Hermite interpolation
		var idx_a: int = 0
		for i in range(count - 1):
			if _snapshot_buffer[i].timestamp <= render_time and _snapshot_buffer[i + 1].timestamp >= render_time:
				idx_a = i
				break
		var s_a: NetworkSnapshot = _snapshot_buffer[idx_a]
		var s_b: NetworkSnapshot = _snapshot_buffer[idx_a + 1]
		var span: float = maxf(s_b.timestamp - s_a.timestamp, 0.0001)
		var t: float = clampf((render_time - s_a.timestamp) / span, 0.0, 1.0)

		interp_pos = _cubic_hermite_vector3(s_a.position, s_a.velocity * span, s_b.position, s_b.velocity * span, t)
		interp_rot = s_a.rotation.slerp(s_b.rotation, t)
		interp_steer = lerpf(s_a.steer_angle, s_b.steer_angle, t)
		interp_drift = lerpf(s_a.drift_angle_deg, s_b.drift_angle_deg, t)
		brake_on = s_b.brake_light_on
		flash_on = s_b.headlights_flashing

	_remote_proxy.global_position = interp_pos
	_remote_proxy.global_transform.basis = Basis(interp_rot)

	if is_instance_valid(_remote_wheel_fl):
		_remote_wheel_fl.rotation.y = interp_steer
	if is_instance_valid(_remote_wheel_fr):
		_remote_wheel_fr.rotation.y = interp_steer

	if is_instance_valid(_remote_brake_mat):
		_remote_brake_mat.emission_energy_multiplier = 4.2 if brake_on else 0.4

	if is_instance_valid(_remote_headlight_mat):
		_remote_headlight_mat.emission_energy_multiplier = 5.0 if flash_on else 1.5
	if is_instance_valid(_remote_headlight_spot_l):
		_remote_headlight_spot_l.light_energy = 4.5 if flash_on else 1.8
	if is_instance_valid(_remote_headlight_spot_r):
		_remote_headlight_spot_r.light_energy = 4.5 if flash_on else 1.8

	if is_instance_valid(_drift_telemetry_label):
		_drift_telemetry_label.text = "RIVAL DRIFT ANGLE: %.1f° %s" % [
			absf(interp_drift),
			"[FLASHING PASS!]" if flash_on else ""
		]


func _cubic_hermite_vector3(p0: Vector3, m0: Vector3, p1: Vector3, m1: Vector3, t: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	var h00: float = 2.0 * t3 - 3.0 * t2 + 1.0
	var h10: float = t3 - 2.0 * t2 + t
	var h01: float = -2.0 * t3 + 3.0 * t2
	var h11: float = t3 - t2
	return p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11


# ==============================================================================
# PROCEDURAL RIVAL VEHICLE REPLICA BUILDER
# ==============================================================================

func _spawn_remote_vehicle_proxy(peer_id: int) -> void:
	_despawn_remote_vehicle()
	var host_node: Node = _scene_root if is_instance_valid(_scene_root) else self

	_remote_proxy = Node3D.new()
	_remote_proxy.name = "RemoteRivalCar_%d" % peer_id
	host_node.add_child(_remote_proxy)

	# JDM Coupe Chassis Body
	var chassis_mi: MeshInstance3D = MeshInstance3D.new()
	var chassis_box: BoxMesh = BoxMesh.new()
	chassis_box.size = Vector3(1.76, 0.62, 4.25)
	var body_mat: StandardMaterial3D = StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.95, 0.95, 0.97) if peer_id != 1 else Color(0.95, 0.78, 0.10)
	body_mat.metallic = 0.35
	body_mat.roughness = 0.25
	chassis_box.material = body_mat
	chassis_mi.mesh = chassis_box
	chassis_mi.position = Vector3(0.0, 0.55, 0.0)
	_remote_proxy.add_child(chassis_mi)

	# Cabin Greenhouse
	var cabin_mi: MeshInstance3D = MeshInstance3D.new()
	var cabin_box: BoxMesh = BoxMesh.new()
	cabin_box.size = Vector3(1.48, 0.52, 2.05)
	var cabin_mat: StandardMaterial3D = StandardMaterial3D.new()
	cabin_mat.albedo_color = Color(0.08, 0.10, 0.14)
	cabin_mat.roughness = 0.15
	cabin_box.material = cabin_mat
	cabin_mi.mesh = cabin_box
	cabin_mi.position = Vector3(0.0, 1.08, 0.18)
	_remote_proxy.add_child(cabin_mi)

	# Steerable Front Wheels & Rear Wheels
	var wheel_offsets: Array[Vector3] = [
		Vector3(-0.82, 0.32, -1.32), # FL
		Vector3(0.82, 0.32, -1.32),  # FR
		Vector3(-0.82, 0.32, 1.32),  # RL
		Vector3(0.82, 0.32, 1.32)    # RR
	]
	var w_mesh: CylinderMesh = CylinderMesh.new()
	w_mesh.top_radius = 0.32
	w_mesh.bottom_radius = 0.32
	w_mesh.height = 0.24
	var w_mat: StandardMaterial3D = StandardMaterial3D.new()
	w_mat.albedo_color = Color(0.12, 0.12, 0.13)
	w_mesh.material = w_mat

	for i in range(4):
		var pivot: Node3D = Node3D.new()
		pivot.position = wheel_offsets[i]
		var w_mi: MeshInstance3D = MeshInstance3D.new()
		w_mi.mesh = w_mesh
		w_mi.rotation_degrees.z = 90.0
		pivot.add_child(w_mi)
		_remote_proxy.add_child(pivot)
		if i == 0:
			_remote_wheel_fl = pivot
		elif i == 1:
			_remote_wheel_fr = pivot

	# Rear Brake Light Strip
	var brake_mi: MeshInstance3D = MeshInstance3D.new()
	var brake_box: BoxMesh = BoxMesh.new()
	brake_box.size = Vector3(1.56, 0.16, 0.08)
	_remote_brake_mat = StandardMaterial3D.new()
	_remote_brake_mat.albedo_color = Color(0.95, 0.08, 0.08)
	_remote_brake_mat.emission_enabled = true
	_remote_brake_mat.emission = Color(1.0, 0.10, 0.05)
	_remote_brake_mat.emission_energy_multiplier = 0.4
	brake_box.material = _remote_brake_mat
	brake_mi.mesh = brake_box
	brake_mi.position = Vector3(0.0, 0.62, 2.14)
	_remote_proxy.add_child(brake_mi)

	# Front Pop-Up Headlights & Beams
	var hl_mi: MeshInstance3D = MeshInstance3D.new()
	var hl_box: BoxMesh = BoxMesh.new()
	hl_box.size = Vector3(1.52, 0.16, 0.08)
	_remote_headlight_mat = StandardMaterial3D.new()
	_remote_headlight_mat.albedo_color = Color(1.0, 0.96, 0.85)
	_remote_headlight_mat.emission_enabled = true
	_remote_headlight_mat.emission = Color(1.0, 0.94, 0.78)
	_remote_headlight_mat.emission_energy_multiplier = 1.5
	hl_box.material = _remote_headlight_mat
	hl_mi.mesh = hl_box
	hl_mi.position = Vector3(0.0, 0.62, -2.14)
	_remote_proxy.add_child(hl_mi)

	_remote_headlight_spot_l = SpotLight3D.new()
	_remote_headlight_spot_l.position = Vector3(-0.62, 0.62, -2.18)
	_remote_headlight_spot_l.spot_range = 32.0
	_remote_headlight_spot_l.spot_angle = 28.0
	_remote_headlight_spot_l.light_color = Color(1.0, 0.95, 0.82)
	_remote_proxy.add_child(_remote_headlight_spot_l)

	_remote_headlight_spot_r = SpotLight3D.new()
	_remote_headlight_spot_r.position = Vector3(0.62, 0.62, -2.18)
	_remote_headlight_spot_r.spot_range = 32.0
	_remote_headlight_spot_r.spot_angle = 28.0
	_remote_headlight_spot_r.light_color = Color(1.0, 0.95, 0.82)
	_remote_proxy.add_child(_remote_headlight_spot_r)


func _despawn_remote_vehicle() -> void:
	if is_instance_valid(_remote_proxy):
		var p: Node = _remote_proxy.get_parent()
		if is_instance_valid(p):
			p.remove_child(_remote_proxy)
		_remote_proxy.free()
	_remote_proxy = null
	_remote_wheel_fl = null
	_remote_wheel_fr = null
	_remote_brake_mat = null
	_remote_headlight_mat = null
	_remote_headlight_spot_l = null
	_remote_headlight_spot_r = null


# ==============================================================================
# CAT-AND-MOUSE SYNCHRONIZED RACE REFEREE & COUNTDOWN
# ==============================================================================

func _process_countdown(delta: float) -> void:
	_countdown_timer -= delta
	var ceil_sec: int = int(ceil(_countdown_timer))
	if ceil_sec != _last_countdown_int and ceil_sec >= 1:
		_last_countdown_int = ceil_sec
		var txt: String = "%d..." % ceil_sec
		_show_center_banner(txt, Color(1.0, 0.84, 0.18), 0.95)
		duel_countdown_tick.emit(txt)

	if _countdown_timer <= 0.0:
		_battle_state = BattleState.RACING
		_unlock_local_vehicle()
		_show_center_banner("GO!! TOUGE BATTLE START!", Color(0.18, 1.0, 0.42), 1.6)
		duel_countdown_tick.emit("GO!")
		duel_started.emit()


func _process_cat_and_mouse_referee(delta: float) -> void:
	_race_elapsed_sec += delta
	if not is_instance_valid(_local_vehicle) or not is_instance_valid(_remote_proxy):
		return

	var my_id: int = multiplayer.get_unique_id()
	var my_pos: Vector3 = _local_vehicle.global_position
	var rival_pos: Vector3 = _remote_proxy.global_position

	var my_prog: float = _compute_track_progress(my_pos)
	var rival_prog: float = _compute_track_progress(rival_pos)

	var lead_prog: float = my_prog if (my_id == _leader_peer_id) else rival_prog
	var chase_prog: float = rival_prog if (my_id == _leader_peer_id) else my_prog

	_current_gap_meters = lead_prog - chase_prog
	var avg_speed: float = maxf(_local_vehicle.linear_velocity.length(), 12.0)
	_current_gap_seconds = absf(_current_gap_meters) / avg_speed

	if is_instance_valid(_gap_label):
		var gap_prefix: String = "GAP: +%.1f m (+%.2f s)" if _current_gap_meters >= 0.0 else "OVERTAKE: %.1f m (-%.2f s)"
		_gap_label.text = gap_prefix % [_current_gap_meters, _current_gap_seconds]

	# Authority (Host) arbitrates Sudden Death & Finish Line rules and broadcasts result
	if not multiplayer.is_server():
		return

	# Rule 1: Finish Line Sprint
	if lead_prog >= _track_total_length or chase_prog >= _track_total_length:
		var winner: int = _leader_peer_id if lead_prog >= chase_prog else _chaser_peer_id
		_rpc_broadcast_race_result.rpc(winner, "FINISH LINE SPRINT")
		return

	if _race_elapsed_sec < grace_period_sec:
		return

	# Rule 2: Leader pulls ahead by >50 meters (Sudden Death Escape)
	if _current_gap_meters >= sudden_death_gap_meters:
		_rpc_broadcast_race_result.rpc(_leader_peer_id, "SUDDEN DEATH // LEADER ESCAPED (>50m)")
		return

	# Rule 3: Chaser cleanly overtakes the Leader
	if chase_prog > lead_prog + overtake_margin_meters:
		_overtake_hold_timer += delta
		if _overtake_hold_timer >= 0.35:
			_rpc_broadcast_race_result.rpc(_chaser_peer_id, "SUDDEN DEATH // CHASER OVERTAKE!")
			return
	else:
		_overtake_hold_timer = 0.0


func _compute_track_progress(world_pos: Vector3) -> float:
	if is_instance_valid(_track_curve) and _track_curve.point_count >= 2:
		return _track_curve.get_closest_offset(world_pos)
	var forward_dir: Vector3 = -_pole_spawn_transform.basis.z.normalized()
	return (world_pos - _pole_spawn_transform.origin).dot(forward_dir)


@rpc("authority", "call_local", "reliable")
func _rpc_broadcast_race_result(winner_peer_id: int, reason: String) -> void:
	if _battle_state == BattleState.FINISHED:
		return
	_battle_state = BattleState.FINISHED
	var my_id: int = multiplayer.get_unique_id()
	var won: bool = (my_id == winner_peer_id)
	var banner_text: String = ("VICTORY!! // %s" if won else "DEFEAT // %s") % reason
	var banner_col: Color = Color(0.18, 0.98, 0.42) if won else Color(1.0, 0.24, 0.22)
	_show_center_banner(banner_text, banner_col, 6.0)
	duel_finished.emit(winner_peer_id, reason)


func _lock_local_vehicle() -> void:
	if is_instance_valid(_local_vehicle):
		_local_vehicle.freeze = true


func _unlock_local_vehicle() -> void:
	if is_instance_valid(_local_vehicle):
		_local_vehicle.freeze = false
		_local_vehicle.sleeping = false


# ==============================================================================
# PING / RTT HEARTBEAT RPCS
# ==============================================================================

@rpc("any_peer", "unreliable")
func _rpc_ping(sent_usec: int) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if sender > 0:
		_rpc_pong.rpc_id(sender, sent_usec)


@rpc("any_peer", "unreliable")
func _rpc_pong(sent_usec: int) -> void:
	var rtt_usec: int = Time.get_ticks_usec() - sent_usec
	var sample_ms: float = maxf(float(rtt_usec) * 0.001, 1.0)
	_ping_ms = lerpf(_ping_ms, sample_ms, 0.35) if _ping_ms > 0.0 else sample_ms


# ==============================================================================
# MINIMALIST DARK-GLASS LOBBY & BATTLE HUD UI
# ==============================================================================

func _build_dark_glass_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "TougeMultiplayerUI"
	_ui_layer.layer = 20
	add_child(_ui_layer)

	var glass_style: StyleBoxFlat = StyleBoxFlat.new()
	glass_style.bg_color = Color(0.05, 0.06, 0.09, 0.86)
	glass_style.border_color = Color(0.28, 0.56, 0.96, 0.65)
	glass_style.set_border_width_all(1)
	glass_style.set_corner_radius_all(6)
	glass_style.set_content_margin_all(14)

	# 1. Online Lobby Panel (Toggled with 'O')
	_lobby_panel = PanelContainer.new()
	_lobby_panel.name = "DarkGlassLobbyPanel"
	_lobby_panel.add_theme_stylebox_override("panel", glass_style)
	_lobby_panel.position = Vector2(24.0, 24.0)
	_lobby_panel.custom_minimum_size = Vector2(340.0, 230.0)
	_ui_layer.add_child(_lobby_panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_lobby_panel.add_child(vbox)

	var title_lbl: Label = Label.new()
	title_lbl.text = "ONLINE TOUGE DUEL // ENET P2P [KEY: O]"
	title_lbl.add_theme_color_override("font_color", Color(0.45, 0.78, 1.0))
	vbox.add_child(title_lbl)

	var addr_row: HBoxContainer = HBoxContainer.new()
	vbox.add_child(addr_row)

	_ip_input = LineEdit.new()
	_ip_input.text = default_ip
	_ip_input.placeholder_text = "Host IP (e.g. 127.0.0.1)"
	_ip_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	addr_row.add_child(_ip_input)

	_port_input = LineEdit.new()
	_port_input.text = str(default_port)
	_port_input.custom_minimum_size = Vector2(76.0, 0.0)
	addr_row.add_child(_port_input)

	_host_btn = Button.new()
	_host_btn.text = "[HOST TOUGE DUEL]"
	_host_btn.pressed.connect(func() -> void:
		host_duel(_port_input.text.to_int())
	)
	vbox.add_child(_host_btn)

	_join_btn = Button.new()
	_join_btn.text = "[JOIN BY IP]"
	_join_btn.pressed.connect(func() -> void:
		join_duel(_ip_input.text, _port_input.text.to_int())
	)
	vbox.add_child(_join_btn)

	_disconnect_btn = Button.new()
	_disconnect_btn.text = "[DISCONNECT]"
	_disconnect_btn.pressed.connect(disconnect_session)
	vbox.add_child(_disconnect_btn)

	_status_label = Label.new()
	_status_label.text = "STATUS: OFFLINE // READY"
	_status_label.add_theme_color_override("font_color", Color(0.82, 0.86, 0.92))
	vbox.add_child(_status_label)

	_ping_label = Label.new()
	_ping_label.text = "PING: -- ms // STANDBY"
	_ping_label.add_theme_color_override("font_color", Color(0.42, 0.95, 0.62))
	vbox.add_child(_ping_label)

	# 2. Cat-and-Mouse Telemetry HUD (Top-Right)
	_hud_panel = PanelContainer.new()
	_hud_panel.name = "CatAndMouseHUD"
	_hud_panel.add_theme_stylebox_override("panel", glass_style)
	_hud_panel.anchor_left = 1.0
	_hud_panel.anchor_right = 1.0
	_hud_panel.offset_left = -350.0
	_hud_panel.offset_top = 24.0
	_hud_panel.offset_right = -24.0
	_hud_panel.offset_bottom = 128.0
	_hud_panel.visible = false
	_ui_layer.add_child(_hud_panel)

	var hud_vbox: VBoxContainer = VBoxContainer.new()
	_hud_panel.add_child(hud_vbox)

	_role_label = Label.new()
	_role_label.text = "ROLE: --"
	_role_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.24))
	hud_vbox.add_child(_role_label)

	_gap_label = Label.new()
	_gap_label.text = "GAP: +12.0 m (+0.50 s)"
	_gap_label.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
	hud_vbox.add_child(_gap_label)

	_drift_telemetry_label = Label.new()
	_drift_telemetry_label.text = "RIVAL DRIFT ANGLE: 0.0°"
	_drift_telemetry_label.add_theme_color_override("font_color", Color(0.58, 0.84, 1.0))
	hud_vbox.add_child(_drift_telemetry_label)

	# 3. Center Countdown & Victory/Defeat Banner
	_center_banner_label = Label.new()
	_center_banner_label.name = "CenterBattleBanner"
	_center_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center_banner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_center_banner_label.anchor_left = 0.15
	_center_banner_label.anchor_right = 0.85
	_center_banner_label.anchor_top = 0.22
	_center_banner_label.anchor_bottom = 0.36
	_center_banner_label.add_theme_font_size_override("font_size", 32)
	_center_banner_label.visible = false
	_ui_layer.add_child(_center_banner_label)


func _update_status_ui(text: String, is_online: bool) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = "STATUS: %s" % text
	if is_instance_valid(_ping_label) and not is_online:
		_ping_label.text = "PING: -- ms // OFFLINE"
	duel_connection_changed.emit(text, is_online)


func _show_center_banner(text: String, color: Color, duration: float) -> void:
	if is_instance_valid(_center_banner_label):
		_center_banner_label.text = text
		_center_banner_label.add_theme_color_override("font_color", color)
		_center_banner_label.visible = true
	_banner_hide_timer = duration