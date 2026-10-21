extends Node

# ==============================================================================
# ShiTmoZ/RACING - REAL-TIME MULTIPLAYER & TOUGE TANDEM BATTLE SYSTEM
# Target Engine: Godot 4.3 Forward+ (GDScript 2.0 / Vulkan)
# Architecture: ENet High-Frequency Dead Reckoning & JDM Puppet Replication
# ==============================================================================

signal lobby_hosted(port: int)
signal lobby_joined(ip: String, port: int)
signal lobby_left()
signal car_choice_changed(car_name: String)
signal tandem_battle_updated(lead_name: String, chase_name: String, gap_meters: float, gap_seconds: float, is_tandem_drift: bool)

const DEFAULT_PORT: int = 7777
const MAX_PEERS: int = 8
const NET_SYNC_RATE: float = 1.0 / 28.0 # 28 Hz High-Frequency State Broadcast
const PING_INTERVAL: float = 1.5

# External Dynamic Script Loading (Safe fallback if missing)
const AE86_SCRIPT_PATH: String = "res://AE86TruenoModeler.gd"
const R34_SCRIPT_PATH: String = "res://R34SkylineModeler.gd"

# Network & Lobby State
var enet_peer: ENetMultiplayerPeer = null
var is_session_active: bool = false
var local_player_name: String = "TAKUMI_86"
var local_car_choice: String = "AE86" # "AE86" or "R34"

# Registered Players: peer_id -> Dictionary { name, car, ping_ms }
var connected_drivers: Dictionary = {}

# Remote Puppet Vehicles: peer_id -> RemoteVehiclePuppet (Internal Node3D Wrapper)
var remote_puppets: Dictionary = {}
var puppets_container: Node3D = null

# Local References
var local_vehicle: Node3D = null
var sync_accumulator: float = 0.0
var ping_accumulator: float = 0.0
var last_local_gear: int = 1

# Tandem Battle Metrics
var current_gap_meters: float = 0.0
var current_gap_seconds: float = 0.0
var is_tandem_drifting: bool = false
var tandem_score_accumulator: float = 0.0

# UI References
var ui_canvas: CanvasLayer = null
var lobby_panel: PanelContainer = null
var hud_tandem_panel: PanelContainer = null
var ip_input: LineEdit = null
var port_input: LineEdit = null
var name_input: LineEdit = null
var status_label: Label = null
var drivers_vbox: VBoxContainer = null
var btn_ae86: Button = null
var btn_r34: Button = null
var btn_host: Button = null
var btn_join: Button = null
var btn_disconnect: Button = null
var btn_toggle_menu: Button = null

# Tandem HUD Labels
var lbl_battle_header: Label = null
var lbl_lead_driver: Label = null
var lbl_chase_driver: Label = null
var lbl_gap_readout: Label = null
var lbl_tandem_badge: Label = null

# ==============================================================================
# LIFECYCLE & INITIALIZATION
# ==============================================================================

func _ready() -> void:
	name = "TougeMultiplayerManager"
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# Create 3D Container for Remote Puppet Cars
	puppets_container = Node3D.new()
	puppets_container.name = "RemoteNetworkPuppets"
	add_child(puppets_container)
	
	# Connect Godot 4 MultiplayerAPI Signals safely
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	
	# Generate random suffix for default driver name
	randomize()
	local_player_name = "AKINA_DRIVER_%02d" % (randi() % 99 + 1)
	
	_build_cyber_jdm_ui()
	_locate_local_vehicle()
	
	# Check for Headless / Dedicated Server CLI Arguments
	var cmd_args: PackedStringArray = OS.get_cmdline_args()
	if DisplayServer.get_name() == "headless" or "--server" in cmd_args:
		print("[TOUGE NET] Headless Dedicated Server mode detected. Auto-hosting on Port %d..." % DEFAULT_PORT)
		host_lobby(DEFAULT_PORT, MAX_PEERS)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB or event.keycode == KEY_F1:
			_toggle_lobby_ui()

func _process(delta: float) -> void:
	if not is_instance_valid(local_vehicle):
		_locate_local_vehicle()
	
	# Offline / Solo Guard: Never call multiplayer methods without an active peer
	if not _is_network_active():
		_update_tandem_hud_visibility(false)
		return
	
	# High-Frequency Vehicle State Broadcast (28 Hz)
	sync_accumulator += delta
	if sync_accumulator >= NET_SYNC_RATE:
		sync_accumulator = 0.0
		_broadcast_local_vehicle_state()
	
	# Ping Measurement Broadcast
	ping_accumulator += delta
	if ping_accumulator >= PING_INTERVAL:
		ping_accumulator = 0.0
		if not multiplayer.is_server():
			_rpc_ping_request.rpc_id(1, Time.get_ticks_msec())
	
	# Interpolate Remote Puppets (Dead Reckoning + 144Hz Visual Smoothing)
	for peer_id in remote_puppets.keys():
		var puppet: RemoteVehiclePuppet = remote_puppets[peer_id]
		if is_instance_valid(puppet):
			puppet.interpolate_state(delta)
	
	# Update Initial D Touge Tandem Battle Calculations
	_evaluate_touge_tandem_battle(delta)

# ==============================================================================
# PUBLIC MULTIPLAYER API
# ==============================================================================

func host_lobby(port: int = DEFAULT_PORT, max_players: int = MAX_PEERS) -> Error:
	leave_lobby()
	
	enet_peer = ENetMultiplayerPeer.new()
	var err: Error = enet_peer.create_server(port, max_players)
	if err != OK:
		_set_status_text("ERROR: FAILED TO HOST ON PORT %d (Code %d)" % [port, err], Color(1.0, 0.3, 0.3))
		enet_peer = null
		return err
	
	enet_peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = enet_peer
	is_session_active = true
	
	if name_input and not name_input.text.strip_edges().is_empty():
		local_player_name = name_input.text.strip_edges()
	
	connected_drivers.clear()
	connected_drivers[1] = {
		"name": local_player_name,
		"car": local_car_choice,
		"ping": 0
	}
	
	_set_status_text("HOSTING TOUGE SERVER ON UDP PORT %d" % port, Color(0.2, 1.0, 0.6))
	_refresh_drivers_list_ui()
	_update_buttons_state()
	lobby_hosted.emit(port)
	return OK

func join_lobby(ip: String = "127.0.0.1", port: int = DEFAULT_PORT) -> Error:
	leave_lobby()
	
	var clean_ip: String = ip.strip_edges()
	if clean_ip.is_empty():
		clean_ip = "127.0.0.1"
	
	enet_peer = ENetMultiplayerPeer.new()
	var err: Error = enet_peer.create_client(clean_ip, port)
	if err != OK:
		_set_status_text("ERROR: CANNOT CONNECT TO %s:%d" % [clean_ip, port], Color(1.0, 0.3, 0.3))
		enet_peer = null
		return err
	
	enet_peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = enet_peer
	is_session_active = true
	
	if name_input and not name_input.text.strip_edges().is_empty():
		local_player_name = name_input.text.strip_edges()
	
	_set_status_text("CONNECTING TO %s:%d..." % [clean_ip, port], Color(1.0, 0.85, 0.2))
	_update_buttons_state()
	lobby_joined.emit(clean_ip, port)
	return OK

func leave_lobby() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = null
	if enet_peer != null:
		enet_peer.close()
		enet_peer = null
	
	is_session_active = false
	connected_drivers.clear()
	
	for peer_id in remote_puppets.keys():
		if is_instance_valid(remote_puppets[peer_id]):
			remote_puppets[peer_id].queue_free()
	remote_puppets.clear()
	
	_set_status_text("OFFLINE // SOLO TOUGE PRACTICE MODE", Color(0.65, 0.75, 0.85))
	_refresh_drivers_list_ui()
	_update_buttons_state()
	_update_tandem_hud_visibility(false)
	lobby_left.emit()

func set_local_car_choice(car_name: String) -> void:
	var normalized: String = "R34" if car_name.to_upper().contains("R34") else "AE86"
	local_car_choice = normalized
	
	# Update visual highlight on car picker buttons
	if btn_ae86 and btn_r34:
		btn_ae86.modulate = Color(0.3, 1.0, 0.9) if local_car_choice == "AE86" else Color(0.6, 0.6, 0.6)
		btn_r34.modulate = Color(0.3, 1.0, 0.9) if local_car_choice == "R34" else Color(0.6, 0.6, 0.6)
	
	# Swap local car visual model if the parent scene or vehicle supports it
	_apply_local_vehicle_model_swap(local_car_choice)
	
	if _is_network_active():
		var my_id: int = multiplayer.get_unique_id()
		if connected_drivers.has(my_id):
			connected_drivers[my_id]["car"] = local_car_choice
		_rpc_register_driver_info.rpc(local_player_name, local_car_choice)
		_refresh_drivers_list_ui()
	
	car_choice_changed.emit(local_car_choice)

# ==============================================================================
# NETWORK SIGNAL CALLBACKS & HANDSHAKES
# ==============================================================================

func _is_network_active() -> bool:
	if not is_session_active:
		return false
	if not multiplayer.has_multiplayer_peer():
		return false
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return false
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func _on_peer_connected(peer_id: int) -> void:
	if not _is_network_active():
		return
	# Send our driver profile to the newly connected peer
	_rpc_register_driver_info.rpc_id(peer_id, local_player_name, local_car_choice)

func _on_peer_disconnected(peer_id: int) -> void:
	if connected_drivers.has(peer_id):
		connected_drivers.erase(peer_id)
	if remote_puppets.has(peer_id):
		if is_instance_valid(remote_puppets[peer_id]):
			remote_puppets[peer_id].queue_free()
		remote_puppets.erase(peer_id)
	_refresh_drivers_list_ui()

func _on_connected_to_server() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var my_id: int = multiplayer.get_unique_id()
	connected_drivers[my_id] = {
		"name": local_player_name,
		"car": local_car_choice,
		"ping": 0
	}
	_set_status_text("CONNECTED TO SERVER (ID: %d)" % my_id, Color(0.2, 1.0, 0.6))
	_rpc_register_driver_info.rpc(local_player_name, local_car_choice)
	_refresh_drivers_list_ui()
	_update_buttons_state()

func _on_connection_failed() -> void:
	leave_lobby()
	_set_status_text("CONNECTION FAILED // SERVER UNREACHABLE", Color(1.0, 0.3, 0.3))

func _on_server_disconnected() -> void:
	leave_lobby()
	_set_status_text("SERVER DISCONNECTED SESSION", Color(1.0, 0.4, 0.2))

# ==============================================================================
# RPC DEFINITIONS (DRIVER REGISTRATION, PING & VEHICLE SYNC)
# ==============================================================================

@rpc("any_peer", "call_local", "reliable")
func _rpc_register_driver_info(driver_name: String, car_model: String) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = multiplayer.get_unique_id()
	
	var existing_ping: int = 0
	if connected_drivers.has(sender_id):
		existing_ping = connected_drivers[sender_id].get("ping", 0)
	
	connected_drivers[sender_id] = {
		"name": driver_name,
		"car": car_model,
		"ping": existing_ping
	}
	
	if sender_id != multiplayer.get_unique_id():
		_ensure_remote_puppet(sender_id, driver_name, car_model)
	
	_refresh_drivers_list_ui()

@rpc("any_peer", "unreliable")
func _rpc_ping_request(client_timestamp_ms: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	_rpc_ping_response.rpc_id(sender_id, client_timestamp_ms)

@rpc("authority", "unreliable")
func _rpc_ping_response(client_timestamp_ms: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var rtt: int = maxi(1, Time.get_ticks_msec() - client_timestamp_ms)
	var my_id: int = multiplayer.get_unique_id()
	if connected_drivers.has(my_id):
		connected_drivers[my_id]["ping"] = rtt
	_rpc_broadcast_ping.rpc(rtt)

@rpc("any_peer", "call_local", "unreliable")
func _rpc_broadcast_ping(rtt_ms: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = multiplayer.get_unique_id()
	if connected_drivers.has(sender_id):
		connected_drivers[sender_id]["ping"] = rtt_ms
		_refresh_drivers_list_ui()

@rpc("any_peer", "unreliable_ordered")
func _rpc_sync_vehicle_state(
	pos: Vector3,
	rot_quat: Quaternion,
	lin_vel: Vector3,
	ang_vel: Vector3,
	steer: float,
	brake_heat: float,
	headlights_on: bool,
	is_drifting: bool,
	car_code: String
) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id == 0 or sender_id == multiplayer.get_unique_id():
		return
	
	var driver_name: String = "DRIVER_%d" % sender_id
	if connected_drivers.has(sender_id):
		driver_name = connected_drivers[sender_id]["name"]
	
	var puppet: RemoteVehiclePuppet = _ensure_remote_puppet(sender_id, driver_name, car_code)
	if is_instance_valid(puppet):
		puppet.receive_network_state(
			pos, rot_quat, lin_vel, ang_vel, steer, brake_heat, headlights_on, is_drifting, car_code
		)

@rpc("any_peer", "unreliable")
func _rpc_trigger_remote_backfire() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if remote_puppets.has(sender_id) and is_instance_valid(remote_puppets[sender_id]):
		remote_puppets[sender_id].trigger_exhaust_backfire()

# ==============================================================================
# LOCAL VEHICLE STATE EXTRACTION & BROADCAST
# ==============================================================================

func _locate_local_vehicle() -> void:
	var root: Node = get_tree().current_scene
	if root == null:
		return
	
	# Search by group or class/node name conventions used in ShiTmoZ/RACING
	var vehicles: Array[Node] = get_tree().get_nodes_in_group("player_vehicle")
	if vehicles.size() > 0 and vehicles[0] is Node3D:
		local_vehicle = vehicles[0] as Node3D
		return
	
	for child in root.find_children("*", "VehicleBody3D", true, false):
		if child is Node3D and not puppets_container.is_ancestor_of(child):
			local_vehicle = child as Node3D
			return
	
	for child in root.find_children("*", "Node3D", true, false):
		if child.name.contains("Vehicle") or child.name.contains("AE86") or child.name.contains("PlayerCar"):
			if not puppets_container.is_ancestor_of(child):
				local_vehicle = child as Node3D
				return

func _broadcast_local_vehicle_state() -> void:
	if not is_instance_valid(local_vehicle) or not _is_network_active():
		return
	
	var pos: Vector3 = local_vehicle.global_position
	var rot_quat: Quaternion = local_vehicle.global_transform.basis.get_rotation_quaternion()
	var lin_vel: Vector3 = Vector3.ZERO
	var ang_vel: Vector3 = Vector3.ZERO
	
	if "linear_velocity" in local_vehicle:
		lin_vel = local_vehicle.get("linear_velocity")
	if "angular_velocity" in local_vehicle:
		ang_vel = local_vehicle.get("angular_velocity")
	
	var steer: float = 0.0
	if "steering" in local_vehicle:
		steer = float(local_vehicle.get("steering"))
	elif "current_steer" in local_vehicle:
		steer = float(local_vehicle.get("current_steer"))
	
	var brake_heat: float = 0.0
	if "brake_heat" in local_vehicle:
		brake_heat = float(local_vehicle.get("brake_heat"))
	elif "brake" in local_vehicle and float(local_vehicle.get("brake")) > 0.1:
		brake_heat = 0.75
	
	var headlights_on: bool = true
	if "headlights_on" in local_vehicle:
		headlights_on = bool(local_vehicle.get("headlights_on"))
	elif "popup_open" in local_vehicle:
		headlights_on = bool(local_vehicle.get("popup_open"))
	
	var is_drifting: bool = false
	if "is_drifting" in local_vehicle:
		is_drifting = bool(local_vehicle.get("is_drifting"))
	elif lin_vel.length() > 8.0:
		var forward_dir: Vector3 = -local_vehicle.global_transform.basis.z
		var vel_dir: Vector3 = lin_vel.normalized()
		var slip_angle: float = rad_to_deg(acos(clampf(forward_dir.dot(vel_dir), -1.0, 1.0)))
		is_drifting = slip_angle > 14.0 and slip_angle < 110.0
	
	# Check gear shift for backfire sync
	if "current_gear" in local_vehicle:
		var gear: int = int(local_vehicle.get("current_gear"))
		if gear != last_local_gear and gear > 1:
			_rpc_trigger_remote_backfire.rpc()
		last_local_gear = gear
	
	_rpc_sync_vehicle_state.rpc(
		pos, rot_quat, lin_vel, ang_vel, steer, brake_heat, headlights_on, is_drifting, local_car_choice
	)

func _apply_local_vehicle_model_swap(car_code: String) -> void:
	if not is_instance_valid(local_vehicle):
		return
	if local_vehicle.has_method("set_car_model"):
		local_vehicle.call("set_car_model", car_code)
	elif get_parent() and get_parent().has_method("set_player_car_model"):
		get_parent().call("set_player_car_model", car_code)

# ==============================================================================
# REMOTE PUPPET SPAWNING & MANAGEMENT
# ==============================================================================

func _ensure_remote_puppet(peer_id: int, driver_name: String, car_code: String) -> RemoteVehiclePuppet:
	if remote_puppets.has(peer_id) and is_instance_valid(remote_puppets[peer_id]):
		var existing: RemoteVehiclePuppet = remote_puppets[peer_id]
		existing.update_driver_profile(driver_name, car_code)
		return existing
	
	var puppet := RemoteVehiclePuppet.new()
	puppet.name = "RemotePuppet_%d" % peer_id
	puppet.peer_id = peer_id
	puppets_container.add_child(puppet)
	puppet.setup_puppet(driver_name, car_code)
	remote_puppets[peer_id] = puppet
	return puppet

# ==============================================================================
# INITIAL D TANDEM TOUGE BATTLE SYSTEM
# ==============================================================================

func _evaluate_touge_tandem_battle(delta: float) -> void:
	if not is_instance_valid(local_vehicle) or remote_puppets.is_empty():
		_update_tandem_hud_visibility(false)
		return
	
	# Find closest active remote opponent on the mountain pass
	var closest_puppet: RemoteVehiclePuppet = null
	var min_dist: float = INF
	var my_pos: Vector3 = local_vehicle.global_position
	
	for peer_id in remote_puppets.keys():
		var p: RemoteVehiclePuppet = remote_puppets[peer_id]
		if is_instance_valid(p) and p.has_received_first_packet:
			var d: float = my_pos.distance_to(p.global_position)
			if d < min_dist:
				min_dist = d
				closest_puppet = p
	
	if closest_puppet == null:
		_update_tandem_hud_visibility(false)
		return
	
	_update_tandem_hud_visibility(true)
	
	var opp_pos: Vector3 = closest_puppet.global_position
	var my_vel: Vector3 = Vector3.ZERO
	if "linear_velocity" in local_vehicle:
		my_vel = local_vehicle.get("linear_velocity")
	var opp_vel: Vector3 = closest_puppet.target_linear_velocity
	
	# Determine average flow direction along the Touge road
	var road_flow_dir: Vector3 = -local_vehicle.global_transform.basis.z
	if (my_vel + opp_vel).length() > 3.0:
		road_flow_dir = (my_vel + opp_vel).normalized()
	
	var delta_vec: Vector3 = opp_pos - my_pos
	var longitudinal_proj: float = delta_vec.dot(road_flow_dir)
	
	var lead_name: String = local_player_name + " [" + local_car_choice + "]"
	var chase_name: String = closest_puppet.driver_name + " [" + closest_puppet.car_code + "]"
	
	# If longitudinal projection > 0, opponent is ahead of local player along travel vector
	if longitudinal_proj > 0.0:
		lead_name = closest_puppet.driver_name + " [" + closest_puppet.car_code + "]"
		chase_name = local_player_name + " [" + local_car_choice + "]"
	
	current_gap_meters = min_dist
	var avg_speed: float = maxf(8.0, (my_vel.length() + opp_vel.length()) * 0.5)
	current_gap_seconds = current_gap_meters / avg_speed
	
	# Check Local Drift + Remote Drift within 20m for Tandem Drift Multiplier
	var local_drifting: bool = false
	if "is_drifting" in local_vehicle:
		local_drifting = bool(local_vehicle.get("is_drifting"))
	elif my_vel.length() > 8.0:
		var slip: float = rad_to_deg(acos(clampf((-local_vehicle.global_transform.basis.z).dot(my_vel.normalized()), -1.0, 1.0)))
		local_drifting = slip > 14.0 and slip < 110.0
	
	is_tandem_drifting = (current_gap_meters <= 20.0) and local_drifting and closest_puppet.remote_is_drifting
	if is_tandem_drifting:
		tandem_score_accumulator += delta * (250.0 * (21.0 - current_gap_meters) / 20.0)
	
	# Update Tandem HUD Labels
	if lbl_lead_driver:
		lbl_lead_driver.text = "LEAD CAR   // " + lead_name
	if lbl_chase_driver:
		lbl_chase_driver.text = "CHASE CAR  // " + chase_name
	if lbl_gap_readout:
		lbl_gap_readout.text = "GAP: %.1fm (+%.2fs)" % [current_gap_meters, current_gap_seconds]
		if current_gap_meters < 12.0:
			lbl_gap_readout.modulate = Color(1.0, 0.35, 0.25) # Intense Pressure Red/Orange
		elif current_gap_meters < 30.0:
			lbl_gap_readout.modulate = Color(1.0, 0.85, 0.25) # Golden Chase
		else:
			lbl_gap_readout.modulate = Color(0.3, 0.95, 1.0) # Cyan
	
	if lbl_tandem_badge:
		lbl_tandem_badge.visible = is_tandem_drifting
		if is_tandem_drifting:
			lbl_tandem_badge.text = "★ TANDEM DRIFT SYNCHRONIZED [x2.5] // %d PTS ★" % int(tandem_score_accumulator)
	
	tandem_battle_updated.emit(lead_name, chase_name, current_gap_meters, current_gap_seconds, is_tandem_drifting)

# ==============================================================================
# CYBER JDM DARK GLASSMORPHISM UI CONSTRUCTION
# ==============================================================================

func _build_cyber_jdm_ui() -> void:
	ui_canvas = CanvasLayer.new()
	ui_canvas.name = "TougeMultiplayerUI"
	ui_canvas.layer = 95
	add_child(ui_canvas)
	
	# Top-Right Quick Toggle Button
	btn_toggle_menu = Button.new()
	btn_toggle_menu.text = " [TAB] NETPLAY & TANDEM LOBBY "
	btn_toggle_menu.position = Vector2(20, 20)
	btn_toggle_menu.custom_minimum_size = Vector2(240, 34)
	btn_toggle_menu.add_theme_stylebox_override("normal", _create_glass_stylebox(Color(0.05, 0.08, 0.12, 0.85), Color(0.0, 0.9, 1.0, 0.7), 1))
	btn_toggle_menu.add_theme_color_override("font_color", Color(0.2, 0.95, 1.0))
	btn_toggle_menu.pressed.connect(_toggle_lobby_ui)
	ui_canvas.add_child(btn_toggle_menu)
	
	# 1. INITIAL D TANDEM BATTLE HUD (Top Center)
	hud_tandem_panel = PanelContainer.new()
	hud_tandem_panel.name = "TandemBattleHUD"
	hud_tandem_panel.visible = false
	hud_tandem_panel.anchors_preset = Control.PRESET_TOP_WIDE
	hud_tandem_panel.offset_left = 360
	hud_tandem_panel.offset_right = -360
	hud_tandem_panel.offset_top = 14
	hud_tandem_panel.offset_bottom = 128
	hud_tandem_panel.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.04, 0.05, 0.08, 0.82), Color(1.0, 0.8, 0.15, 0.85), 2))
	ui_canvas.add_child(hud_tandem_panel)
	
	var tandem_vbox := VBoxContainer.new()
	tandem_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hud_tandem_panel.add_child(tandem_vbox)
	
	lbl_battle_header = Label.new()
	lbl_battle_header.text = "PROJECT D // MOUNT AKINA CAT & MOUSE TANDEM BATTLE"
	lbl_battle_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_battle_header.add_theme_color_override("font_color", Color(1.0, 0.84, 0.2))
	lbl_battle_header.add_theme_font_size_override("font_size", 13)
	tandem_vbox.add_child(lbl_battle_header)
	
	var cars_hbox := HBoxContainer.new()
	cars_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	cars_hbox.add_theme_constant_override("separation", 28)
	tandem_vbox.add_child(cars_hbox)
	
	lbl_lead_driver = Label.new()
	lbl_lead_driver.text = "LEAD CAR // ---"
	lbl_lead_driver.add_theme_color_override("font_color", Color(0.25, 1.0, 0.65))
	lbl_lead_driver.add_theme_font_size_override("font_size", 15)
	cars_hbox.add_child(lbl_lead_driver)
	
	lbl_gap_readout = Label.new()
	lbl_gap_readout.text = "GAP: 0.0m (+0.00s)"
	lbl_gap_readout.add_theme_color_override("font_color", Color(0.3, 0.95, 1.0))
	lbl_gap_readout.add_theme_font_size_override("font_size", 17)
	cars_hbox.add_child(lbl_gap_readout)
	
	lbl_chase_driver = Label.new()
	lbl_chase_driver.text = "CHASE CAR // ---"
	lbl_chase_driver.add_theme_color_override("font_color", Color(1.0, 0.55, 0.25))
	lbl_chase_driver.add_theme_font_size_override("font_size", 15)
	cars_hbox.add_child(lbl_chase_driver)
	
	lbl_tandem_badge = Label.new()
	lbl_tandem_badge.text = "★ TANDEM DRIFT SYNCHRONIZED [x2.5] ★"
	lbl_tandem_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_tandem_badge.add_theme_color_override("font_color", Color(1.0, 0.9, 0.1))
	lbl_tandem_badge.add_theme_font_size_override("font_size", 14)
	lbl_tandem_badge.visible = false
	tandem_vbox.add_child(lbl_tandem_badge)
	
	# 2. MAIN CYBER JDM LOBBY PANEL (Centered Glassmorphism Modal)
	lobby_panel = PanelContainer.new()
	lobby_panel.name = "CyberJDMLobbyPanel"
	lobby_panel.visible = false
	lobby_panel.custom_minimum_size = Vector2(540, 470)
	lobby_panel.anchors_preset = Control.PRESET_CENTER
	lobby_panel.offset_left = -270
	lobby_panel.offset_right = 270
	lobby_panel.offset_top = -235
	lobby_panel.offset_bottom = 235
	lobby_panel.add_theme_stylebox_override("panel", _create_glass_stylebox(Color(0.04, 0.06, 0.10, 0.92), Color(0.0, 0.88, 1.0, 0.9), 2))
	ui_canvas.add_child(lobby_panel)
	
	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	lobby_panel.add_child(main_vbox)
	
	var title_lbl := Label.new()
	title_lbl.text = "⚡ ShiTmoZ/RACING // ONLINE TOUGE NETCODE ⚡"
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_color_override("font_color", Color(0.15, 0.95, 1.0))
	title_lbl.add_theme_font_size_override("font_size", 18)
	main_vbox.add_child(title_lbl)
	
	status_label = Label.new()
	status_label.text = "OFFLINE // SOLO TOUGE PRACTICE MODE"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85))
	status_label.add_theme_font_size_override("font_size", 13)
	main_vbox.add_child(status_label)
	
	# Driver Callsign Row
	var profile_hbox := HBoxContainer.new()
	profile_hbox.add_theme_constant_override("separation", 8)
	main_vbox.add_child(profile_hbox)
	
	var name_lbl := Label.new()
	name_lbl.text = "DRIVER TAG:"
	name_lbl.custom_minimum_size = Vector2(105, 0)
	profile_hbox.add_child(name_lbl)
	
	name_input = LineEdit.new()
	name_input.text = local_player_name
	name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_input.placeholder_text = "Enter Touge Handle..."
	profile_hbox.add_child(name_input)
	
	# Car Selection Picker Row
	var car_hbox := HBoxContainer.new()
	car_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(car_hbox)
	
	btn_ae86 = Button.new()
	btn_ae86.text = "TOYOTA AE86 TRUENO"
	btn_ae86.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_ae86.custom_minimum_size = Vector2(0, 36)
	btn_ae86.pressed.connect(func(): set_local_car_choice("AE86"))
	car_hbox.add_child(btn_ae86)
	
	btn_r34 = Button.new()
	btn_r34.text = "NISSAN SKYLINE R34 GT-R"
	btn_r34.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_r34.custom_minimum_size = Vector2(0, 36)
	btn_r34.pressed.connect(func(): set_local_car_choice("R34"))
	car_hbox.add_child(btn_r34)
	
	# IP & Port Inputs
	var net_hbox := HBoxContainer.new()
	net_hbox.add_theme_constant_override("separation", 8)
	main_vbox.add_child(net_hbox)
	
	var ip_lbl := Label.new()
	ip_lbl.text = "SERVER IP:"
	ip_lbl.custom_minimum_size = Vector2(85, 0)
	net_hbox.add_child(ip_lbl)
	
	ip_input = LineEdit.new()
	ip_input.text = "127.0.0.1"
	ip_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip_input.placeholder_text = "127.0.0.1 or WAN IP"
	net_hbox.add_child(ip_input)
	
	var port_lbl := Label.new()
	port_lbl.text = "PORT:"
	net_hbox.add_child(port_lbl)
	
	port_input = LineEdit.new()
	port_input.text = str(DEFAULT_PORT)
	port_input.custom_minimum_size = Vector2(75, 0)
	net_hbox.add_child(port_input)
	
	# Server Action Buttons
	var actions_hbox := HBoxContainer.new()
	actions_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(actions_hbox)
	
	btn_host = Button.new()
	btn_host.text = "HOST LOBBY"
	btn_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_host.custom_minimum_size = Vector2(0, 38)
	btn_host.pressed.connect(func():
		var p: int = int(port_input.text) if port_input.text.is_valid_int() else DEFAULT_PORT
		host_lobby(p, MAX_PEERS)
	)
	actions_hbox.add_child(btn_host)
	
	btn_join = Button.new()
	btn_join.text = "JOIN SERVER"
	btn_join.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_join.custom_minimum_size = Vector2(0, 38)
	btn_join.pressed.connect(func():
		var p: int = int(port_input.text) if port_input.text.is_valid_int() else DEFAULT_PORT
		join_lobby(ip_input.text, p)
	)
	actions_hbox.add_child(btn_join)
	
	btn_disconnect = Button.new()
	btn_disconnect.text = "DISCONNECT"
	btn_disconnect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_disconnect.custom_minimum_size = Vector2(0, 38)
	btn_disconnect.pressed.connect(leave_lobby)
	actions_hbox.add_child(btn_disconnect)
	
	# Connected Drivers Header
	var list_header := Label.new()
	list_header.text = "CONNECTED TOUGE DRIVERS // LIVE TELEMETRY"
	list_header.add_theme_color_override("font_color", Color(1.0, 0.84, 0.25))
	list_header.add_theme_font_size_override("font_size", 13)
	main_vbox.add_child(list_header)
	
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(scroll)
	
	drivers_vbox = VBoxContainer.new()
	drivers_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drivers_vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(drivers_vbox)
	
	set_local_car_choice("AE86")
	_refresh_drivers_list_ui()
	_update_buttons_state()

func _create_glass_stylebox(bg_col: Color, border_col: Color, border_width: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_col
	sb.border_color = border_col
	sb.set_border_width_all(border_width)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb

func _toggle_lobby_ui() -> void:
	if lobby_panel:
		lobby_panel.visible = not lobby_panel.visible

func _update_tandem_hud_visibility(show_hud: bool) -> void:
	if hud_tandem_panel and hud_tandem_panel.visible != show_hud:
		hud_tandem_panel.visible = show_hud

func _set_status_text(msg: String, col: Color) -> void:
	if status_label:
		status_label.text = msg
		status_label.add_theme_color_override("font_color", col)

func _update_buttons_state() -> void:
	if not btn_host or not btn_join or not btn_disconnect:
		return
	btn_host.disabled = is_session_active
	btn_join.disabled = is_session_active
	btn_disconnect.disabled = not is_session_active

func _refresh_drivers_list_ui() -> void:
	if not drivers_vbox:
		return
	for child in drivers_vbox.get_children():
		child.queue_free()
	
	if connected_drivers.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No active multiplayer session. Running solo practice."
		empty_lbl.add_theme_color_override("font_color", Color(0.55, 0.62, 0.7))
		drivers_vbox.add_child(empty_lbl)
		return
	
	for peer_id in connected_drivers.keys():
		var info: Dictionary = connected_drivers[peer_id]
		var row := HBoxContainer.new()
		
		var name_lbl := Label.new()
		var host_tag: String = " [HOST]" if peer_id == 1 else ""
		name_lbl.text = "• %s%s" % [info.get("name", "DRIVER"), host_tag]
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_color_override("font_color", Color(0.9, 0.96, 1.0))
		row.add_child(name_lbl)
		
		var badge_lbl := Label.new()
		var c_type: String = info.get("car", "AE86")
		badge_lbl.text = "[%s]" % ("AE86 TRUENO" if c_type == "AE86" else "R34 GT-R")
		badge_lbl.custom_minimum_size = Vector2(125, 0)
		badge_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.25) if c_type == "AE86" else Color(0.25, 0.85, 1.0))
		row.add_child(badge_lbl)
		
		var ping_lbl := Label.new()
		var p_ms: int = info.get("ping", 0)
		ping_lbl.text = "%d ms" % p_ms
		ping_lbl.custom_minimum_size = Vector2(65, 0)
		ping_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		ping_lbl.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5) if p_ms < 90 else Color(1.0, 0.6, 0.2))
		row.add_child(ping_lbl)
		
		drivers_vbox.add_child(row)

# ==============================================================================
# INNER CLASS: REMOTE VEHICLE PUPPET (DEAD RECKONING + JDM VISUAL SYNC)
# ==============================================================================

class RemoteVehiclePuppet extends Node3D:
	var peer_id: int = -1
	var driver_name: String = "REMOTE_DRIVER"
	var car_code: String = ""
	var has_received_first_packet: bool = false
	
	# Dead Reckoning Target States
	var target_position: Vector3 = Vector3.ZERO
	var target_rotation: Quaternion = Quaternion.IDENTITY
	var target_linear_velocity: Vector3 = Vector3.ZERO
	var target_angular_velocity: Vector3 = Vector3.ZERO
	var target_steer: float = 0.0
	var target_brake_heat: float = 0.0
	var target_headlights_on: bool = true
	var remote_is_drifting: bool = false
	
	# Smoothed Visual States
	var visual_steer: float = 0.0
	var wheel_spin_angle: float = 0.0
	var backfire_timer: float = 0.0
	
	# Sub-nodes
	var model_root: Node3D = null
	var nametag_3d: Label3D = null
	var wheels: Array[Node3D] = []
	var front_wheel_pivots: Array[Node3D] = []
	var brake_glow_lights: Array[OmniLight3D] = []
	var headlight_spots: Array[SpotLight3D] = []
	var backfire_mesh: MeshInstance3D = null
	var backfire_light: OmniLight3D = null
	
	func setup_puppet(p_driver_name: String, p_car_code: String) -> void:
		driver_name = p_driver_name
		
		# Floating 3D Driver Tag
		nametag_3d = Label3D.new()
		nametag_3d.position = Vector3(0.0, 1.85, 0.0)
		nametag_3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		nametag_3d.font_size = 42
		nametag_3d.outline_size = 10
		nametag_3d.modulate = Color(0.2, 0.95, 1.0)
		add_child(nametag_3d)
		
		_build_effects_rig()
		update_driver_profile(p_driver_name, p_car_code)
	
	func update_driver_profile(p_driver_name: String, p_car_code: String) -> void:
		driver_name = p_driver_name
		var normalized_code: String = "R34" if p_car_code.to_upper().contains("R34") else "AE86"
		
		if nametag_3d:
			nametag_3d.text = "%s [%s]" % [driver_name, normalized_code]
		
		if car_code != normalized_code:
			car_code = normalized_code
			_instantiate_car_visuals(car_code)
	
	func _instantiate_car_visuals(code: String) -> void:
		if is_instance_valid(model_root):
			model_root.queue_free()
		wheels.clear()
		front_wheel_pivots.clear()
		
		model_root = Node3D.new()
		model_root.name = "VisualModel_" + code
		add_child(model_root)
		
		var script_path: String = R34_SCRIPT_PATH if code == "R34" else AE86_SCRIPT_PATH
		var loaded_modeler: Node3D = null
		
		if ResourceLoader.exists(script_path):
			var scr: Script = load(script_path)
			if scr != null:
				var instance = scr.new()
				if instance is Node3D:
					loaded_modeler = instance
					model_root.add_child(loaded_modeler)
		
		# Fallback procedural JDM silhouette if external modeler script isn't present or uses custom build methods
		if loaded_modeler == null or loaded_modeler.get_child_count() == 0:
			_build_fallback_jdm_chassis(model_root, code)
		else:
			# Discover wheels in loaded modeler for steering & rotation sync
			for child in loaded_modeler.find_children("*", "Node3D", true, false):
				var n_lower: String = child.name.to_lower()
				if n_lower.contains("wheel"):
					wheels.append(child)
					if n_lower.contains("fl") or n_lower.contains("fr") or n_lower.contains("front"):
						front_wheel_pivots.append(child)
	
	func _build_fallback_jdm_chassis(parent: Node3D, code: String) -> void:
		var body_mat := StandardMaterial3D.new()
		body_mat.albedo_color = Color(0.95, 0.95, 0.97) if code == "AE86" else Color(0.08, 0.28, 0.88)
		body_mat.metallic = 0.65
		body_mat.roughness = 0.22
		
		var chassis := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.72, 0.68, 4.25)
		chassis.mesh = box
		chassis.position = Vector3(0.0, 0.58, 0.0)
		chassis.material_override = body_mat
		parent.add_child(chassis)
		
		var cabin := MeshInstance3D.new()
		var cab_box := BoxMesh.new()
		cab_box.size = Vector3(1.48, 0.52, 2.05)
		cabin.mesh = cab_box
		cabin.position = Vector3(0.0, 1.12, -0.15)
		var glass_mat := StandardMaterial3D.new()
		glass_mat.albedo_color = Color(0.05, 0.08, 0.12)
		glass_mat.roughness = 0.1
		cabin.material_override = glass_mat
		parent.add_child(cabin)
		
		var wheel_positions: Array[Vector3] = [
			Vector3(-0.82, 0.33, -1.32),
			Vector3(0.82, 0.33, -1.32),
			Vector3(-0.82, 0.33, 1.32),
			Vector3(0.82, 0.33, 1.32)
		]
		var tire_mat := StandardMaterial3D.new()
		tire_mat.albedo_color = Color(0.12, 0.12, 0.14)
		
		for i in range(4):
			var pivot := Node3D.new()
			pivot.position = wheel_positions[i]
			parent.add_child(pivot)
			
			var w_mesh := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.33
			cyl.bottom_radius = 0.33
			cyl.height = 0.24
			w_mesh.mesh = cyl
			w_mesh.rotation_degrees.z = 90.0
			w_mesh.material_override = tire_mat
			pivot.add_child(w_mesh)
			
			wheels.append(w_mesh)
			if i < 2:
				front_wheel_pivots.append(pivot)
	
	func _build_effects_rig() -> void:
		# Headlights
		for x_side in [-0.62, 0.62]:
			var spot := SpotLight3D.new()
			spot.position = Vector3(x_side, 0.68, -2.1)
			spot.light_color = Color(1.0, 0.96, 0.85)
			spot.light_energy = 3.2
			spot.spot_range = 38.0
			spot.spot_angle = 32.0
			add_child(spot)
			headlight_spots.append(spot)
		
		# Glowing Brake Discs / Tail Glow
		for pos in [Vector3(-0.78, 0.35, -1.3), Vector3(0.78, 0.35, -1.3), Vector3(-0.78, 0.35, 1.3), Vector3(0.78, 0.35, 1.3)]:
			var glow := OmniLight3D.new()
			glow.position = pos
			glow.light_color = Color(1.0, 0.22, 0.05)
			glow.light_energy = 0.0
			glow.omni_range = 1.1
			add_child(glow)
			brake_glow_lights.append(glow)
		
		# Exhaust Backfire Flame Mesh & Light
		backfire_mesh = MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.01
		cone.bottom_radius = 0.14
		cone.height = 0.65
		backfire_mesh.mesh = cone
		backfire_mesh.position = Vector3(0.48, 0.32, 2.38)
		backfire_mesh.rotation_degrees.x = -90.0
		var flame_mat := StandardMaterial3D.new()
		flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		flame_mat.albedo_color = Color(0.25, 0.65, 1.0, 0.9)
		flame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		backfire_mesh.material_override = flame_mat
		backfire_mesh.visible = false
		add_child(backfire_mesh)
		
		backfire_light = OmniLight3D.new()
		backfire_light.position = Vector3(0.48, 0.35, 2.45)
		backfire_light.light_color = Color(1.0, 0.55, 0.15)
		backfire_light.light_energy = 0.0
		backfire_light.omni_range = 3.2
		add_child(backfire_light)
	
	func receive_network_state(
		pos: Vector3,
		rot_quat: Quaternion,
		lin_vel: Vector3,
		ang_vel: Vector3,
		steer: float,
		brake_heat: float,
		headlights_on: bool,
		is_drifting: bool,
		p_car_code: String
	) -> void:
		target_position = pos
		target_rotation = rot_quat.normalized()
		target_linear_velocity = lin_vel
		target_angular_velocity = ang_vel
		target_steer = steer
		target_brake_heat = brake_heat
		target_headlights_on = headlights_on
		remote_is_drifting = is_drifting
		
		if p_car_code != car_code:
			update_driver_profile(driver_name, p_car_code)
		
		if not has_received_first_packet:
			has_received_first_packet = true
			global_position = pos
			global_transform.basis = Basis(target_rotation)
	
	func interpolate_state(delta: float) -> void:
		if not has_received_first_packet:
			return
		
		# 1. Dead Reckoning Extrapolation: advance target position along velocity vector
		target_position += target_linear_velocity * delta
		if target_angular_velocity.length_squared() > 0.0001:
			var angle: float = target_angular_velocity.length() * delta
			var axis: Vector3 = target_angular_velocity.normalized()
			target_rotation = (Quaternion(axis, angle) * target_rotation).normalized()
		
		# 2. Exponential Smoothing / Jitter Buffer for 144Hz Butter-Smooth Visuals
		var pos_alpha: float = 1.0 - exp(-15.0 * delta)
		var rot_alpha: float = 1.0 - exp(-18.0 * delta)
		
		if global_position.distance_to(target_position) > 35.0:
			# Teleport safety only if massive desync / respawn occurred
			global_position = target_position
		else:
			global_position = global_position.lerp(target_position, pos_alpha)
		
		var current_quat: Quaternion = global_transform.basis.get_rotation_quaternion().normalized()
		var smooth_quat: Quaternion = current_quat.slerp(target_rotation, rot_alpha).normalized()
		global_transform.basis = Basis(smooth_quat)
		
		# 3. Wheel Rotation & Steering Sync
		visual_steer = lerpf(visual_steer, target_steer, 1.0 - exp(-14.0 * delta))
		var forward_speed: float = target_linear_velocity.dot(-global_transform.basis.z)
		wheel_spin_angle = fmod(wheel_spin_angle + (forward_speed / 0.33) * delta, TAU)
		
		for pivot in front_wheel_pivots:
			if is_instance_valid(pivot):
				pivot.rotation.y = clampf(visual_steer, -0.65, 0.65)
		
		for w in wheels:
			if is_instance_valid(w) and not front_wheel_pivots.has(w):
				w.rotation.x = -wheel_spin_angle
		
		# 4. Headlights, Brake Disc Glow & Backfire Effects Sync
		for spot in headlight_spots:
			if is_instance_valid(spot):
				spot.visible = target_headlights_on
		
		if is_instance_valid(model_root) and model_root.get_child_count() > 0:
			var inner_model = model_root.get_child(0)
			if inner_model.has_method("set_headlights"):
				inner_model.call("set_headlights", target_headlights_on)
			elif "popup_open" in inner_model:
				inner_model.set("popup_open", target_headlights_on)
		
		for glow in brake_glow_lights:
			if is_instance_valid(glow):
				glow.light_energy = clampf(target_brake_heat * 2.2, 0.0, 2.5)
		
		if backfire_timer > 0.0:
			backfire_timer -= delta
			if backfire_mesh:
				backfire_mesh.visible = backfire_timer > 0.0
				backfire_mesh.scale = Vector3.ONE * randf_range(0.85, 1.35)
			if backfire_light:
				backfire_light.light_energy = 4.0 if backfire_timer > 0.0 else 0.0
	
	func trigger_exhaust_backfire() -> void:
		backfire_timer = 0.14