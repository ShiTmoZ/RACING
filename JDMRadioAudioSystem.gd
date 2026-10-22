class_name JDMRadioAudioSystem
extends Node

## Production Internet Radio Live Streaming Engine for Godot 4.3 (Vulkan Forward+)
## Bypasses HTTPClient Content-Length / chunked stream bugs via raw StreamPeerTCP & StreamPeerTLS.
## Features inline Icecast metadata demuxing, MPEG sync-word frame alignment, seamless dual-player
## crossfade queuing, and a procedural 90s Kenwood 1-DIN Vacuum Fluorescent Display (VFD) HUD.

signal station_changed(station_index: int, station_name: String)
signal track_title_updated(title: String)
signal stream_state_changed(state_name: String)
signal radio_power_toggled(is_on: bool)

enum StreamState {
	OFF,
	CONNECTING,
	TLS_HANDSHAKE,
	SENDING_REQUEST,
	READING_HEADERS,
	BUFFERING,
	PLAYING,
	RECONNECTING,
	ERROR
}

enum DemuxState {
	AUDIO_DATA,
	META_LENGTH,
	META_STRING
}

# --- Configuration & Tuning Constants ---
const PREBUFFER_THRESHOLD: int = 98304     # 96 KB initial pre-buffer before playback starts
const SLICE_BYTE_SIZE: int = 65536         # 64 KB per AudioStreamMP3 slice (~4s at 128kbps)
const MAX_AUDIO_BUFFER_SIZE: int = 1048576 # 1 MB cap to prevent runaway memory usage
const CROSSFADE_TIME: float = 0.045        # 45ms overlap to eliminate MP3 boundary clicks
const SOCKET_READ_CAP: int = 32768         # Max bytes read per frame to guarantee 0ms main-thread stall
const CONNECTION_TIMEOUT: float = 8.0      # Seconds before forcing reconnect on dead socket
const MAX_REDIRECTS: int = 4               # Maximum HTTP 301/302 hops

# --- Verified Live Station Presets ---
var stations: Array[Dictionary] = [
	{
		"freq": "94.2 FM",
		"name": "NIGHTWAVE PLAZA",
		"url": "https://radio.plaza.one/mp3",
		"genre": "80s VAPORWAVE"
	},
	{
		"freq": "102.5 FM",
		"name": "JAPAN RADIO LIVE",
		"url": "https://stream.japanradio.de/live",
		"genre": "JPOP / EUROBEAT"
	},
	{
		"freq": "88.6 FM",
		"name": "SOMA VAPORWAVES",
		"url": "https://ice2.somafm.com/vaporwaves-128-mp3",
		"genre": "TOUGE CHILL"
	},
	{
		"freq": "89.4 FM",
		"name": "J-Pop Project Tokyo",
		"url": "http://kathy.torontocast.com:3560/stream",
		"genre": "J-POP / ANIME"
	},
	{
		"freq": "91.8 FM",
		"name": "City Pop One",
		"url": "http://65.21.61.215:8000/citypopone",
		"genre": "80s TOKYO CITY POP"
	},
	{
		"freq": "105.4 FM",
		"name": "Groove Salad Touge",
		"url": "https://ice2.somafm.com/groovesalad-128-mp3",
		"genre": "AMBIENT CHILL"
	}
]

# --- Radio State ---
var is_powered_on: bool = true
var is_hud_visible: bool = true
var current_station_idx: int = 0
var master_volume_linear: float = 0.75
var state: StreamState = StreamState.OFF

# --- Network & Socket State ---
var _tcp: StreamPeerTCP = null
var _tls: StreamPeerTLS = null
var _active_peer: StreamPeer = null
var _use_tls: bool = false
var _parsed_host: String = ""
var _parsed_port: int = 80
var _parsed_path: String = "/"
var _redirect_count: int = 0

var _header_buffer: PackedByteArray = PackedByteArray()
var _audio_ring_buffer: PackedByteArray = PackedByteArray()
var _meta_buffer: PackedByteArray = PackedByteArray()

# --- Icecast Metadata & Protocol Variables ---
var icy_name: String = ""
var icy_genre: String = ""
var icy_bitrate: int = 128
var icy_metaint: int = 0
var current_track_title: String = "WAITING FOR STREAM..."

var _demux_state: DemuxState = DemuxState.AUDIO_DATA
var _bytes_until_meta: int = 0
var _meta_bytes_remaining: int = 0

# --- Reconnection & Watchdog Timers ---
var _state_timer: float = 0.0
var _data_watchdog: float = 0.0
var _reconnect_attempts: int = 0
var _reconnect_wait_time: float = 2.0
var _reconnect_accum: float = 0.0

# --- Audio Engine Nodes & Playback Tracking ---
var _radio_bus_name: String = "JDMRadioBus"
var _radio_bus_idx: int = -1
var _spectrum_instance: AudioEffectSpectrumAnalyzerInstance = null

var _player_a: AudioStreamPlayer = null
var _player_b: AudioStreamPlayer = null
var _active_player: AudioStreamPlayer = null
var _standby_player: AudioStreamPlayer = null

var _active_slice_duration: float = 0.0
var _active_slice_elapsed: float = 0.0
var _is_crossfading: bool = false
var _crossfade_elapsed: float = 0.0

# --- Kenwood VFD UI Layer ---
var _canvas_layer: CanvasLayer = null
var _vfd_control: KenwoodVFDDisplay = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_audio_bus()
	_setup_audio_players()
	_setup_vfd_hud()
	
	if is_powered_on:
		_connect_to_station(current_station_idx, true)


func _exit_tree() -> void:
	_close_sockets()


# ==============================================================================
# 1. INITIALIZATION: AUDIO BUS, PLAYERS, AND VFD HUD
# ==============================================================================

func _setup_audio_bus() -> void:
	_radio_bus_idx = AudioServer.get_bus_index(_radio_bus_name)
	if _radio_bus_idx == -1:
		AudioServer.add_bus()
		_radio_bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_radio_bus_idx, _radio_bus_name)
		AudioServer.set_bus_send(_radio_bus_idx, "Master")
		
		var spec_effect := AudioEffectSpectrumAnalyzer.new()
		spec_effect.buffer_length = 0.1
		spec_effect.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(_radio_bus_idx, spec_effect, 0)
	else:
		var has_spec := false
		for i in range(AudioServer.get_bus_effect_count(_radio_bus_idx)):
			if AudioServer.get_bus_effect(_radio_bus_idx, i) is AudioEffectSpectrumAnalyzer:
				has_spec = true
				break
		if not has_spec:
			var spec_effect := AudioEffectSpectrumAnalyzer.new()
			spec_effect.buffer_length = 0.1
			spec_effect.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
			AudioServer.add_bus_effect(_radio_bus_idx, spec_effect, 0)
	
	_spectrum_instance = AudioServer.get_bus_effect_instance(_radio_bus_idx, 0) as AudioEffectSpectrumAnalyzerInstance
	_apply_master_volume()


func _setup_audio_players() -> void:
	_player_a = AudioStreamPlayer.new()
	_player_a.name = "RadioStreamPlayerA"
	_player_a.bus = _radio_bus_name
	add_child(_player_a)
	
	_player_b = AudioStreamPlayer.new()
	_player_b.name = "RadioStreamPlayerB"
	_player_b.bus = _radio_bus_name
	add_child(_player_b)
	
	_active_player = _player_a
	_standby_player = _player_b


func _setup_vfd_hud() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = 95
	_canvas_layer.name = "KenwoodVFDCanvas"
	add_child(_canvas_layer)
	
	_vfd_control = KenwoodVFDDisplay.new(self)
	_vfd_control.name = "KenwoodVFDControl"
	_vfd_control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_vfd_control.offset_left = 22.0
	_vfd_control.offset_right = 472.0
	_vfd_control.offset_top = 18.0
	_vfd_control.offset_bottom = 153.0
	_vfd_control.size = Vector2(450.0, 135.0)
	_canvas_layer.add_child(_vfd_control)


# ==============================================================================
# 2. INPUT HANDLING (HOTKEYS)
# ==============================================================================

func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	
	var key_event := event as InputEventKey
	var code := key_event.keycode if key_event.keycode != KEY_NONE else key_event.physical_keycode
	
	match code:
		KEY_P:
			toggle_power()
			get_viewport().set_input_as_handled()
		
		KEY_R:
			if key_event.shift_pressed:
				is_hud_visible = not is_hud_visible
				_canvas_layer.visible = is_hud_visible
				get_viewport().set_input_as_handled()
		
		KEY_T, KEY_N:
			if not is_powered_on:
				toggle_power()
			elif key_event.shift_pressed:
				previous_station()
			else:
				next_station()
			get_viewport().set_input_as_handled()
		
		KEY_B:
			if not is_powered_on:
				toggle_power()
			else:
				previous_station()
			get_viewport().set_input_as_handled()
		
		KEY_BRACKETLEFT, KEY_MINUS, KEY_PAGEDOWN:
			set_radio_volume(master_volume_linear - 0.05)
			get_viewport().set_input_as_handled()
		
		KEY_BRACKETRIGHT, KEY_EQUAL, KEY_PAGEUP:
			set_radio_volume(master_volume_linear + 0.05)
			get_viewport().set_input_as_handled()


# ==============================================================================
# 3. PUBLIC CONTROL API
# ==============================================================================

func toggle_power() -> void:
	is_powered_on = not is_powered_on
	radio_power_toggled.emit(is_powered_on)
	if is_powered_on:
		_reconnect_attempts = 0
		_connect_to_station(current_station_idx, true)
	else:
		_close_sockets()
		_stop_players()
		_set_state(StreamState.OFF)
		current_track_title = "UNIT OFF"
		if _vfd_control:
			_vfd_control.queue_redraw()


func next_station() -> void:
	current_station_idx = (current_station_idx + 1) % stations.size()
	_reconnect_attempts = 0
	_connect_to_station(current_station_idx, true)


func previous_station() -> void:
	current_station_idx = (current_station_idx - 1 + stations.size()) % stations.size()
	_reconnect_attempts = 0
	_connect_to_station(current_station_idx, true)


func set_radio_volume(linear_val: float) -> void:
	master_volume_linear = clampf(linear_val, 0.0, 1.0)
	_apply_master_volume()
	if _vfd_control:
		_vfd_control.trigger_volume_overlay()


func _apply_master_volume() -> void:
	if _radio_bus_idx != -1:
		var db := linear_to_db(maxf(master_volume_linear, 0.0001))
		AudioServer.set_bus_volume_db(_radio_bus_idx, db)
		AudioServer.set_bus_mute(_radio_bus_idx, master_volume_linear <= 0.001)


func get_buffering_percentage() -> int:
	if PREBUFFER_THRESHOLD <= 0:
		return 100
	return clampi(int((float(_audio_ring_buffer.size()) / float(PREBUFFER_THRESHOLD)) * 100.0), 0, 100)


# ==============================================================================
# 4. URL PARSER & SOCKET CONNECTION ENGINE
# ==============================================================================

func _parse_url(url: String) -> Dictionary:
	var work := url.strip_edges()
	var is_https := false
	var default_port := 80
	
	if work.begins_with("https://"):
		is_https = true
		default_port = 443
		work = work.substr(8)
	elif work.begins_with("http://"):
		is_https = false
		default_port = 80
		work = work.substr(7)
	
	var slash_pos := work.find("/")
	var host_port := work
	var path := "/"
	if slash_pos != -1:
		host_port = work.substr(0, slash_pos)
		path = work.substr(slash_pos)
	
	var host := host_port
	var port := default_port
	var colon_pos := host_port.find(":")
	if colon_pos != -1:
		host = host_port.substr(0, colon_pos)
		var port_str := host_port.substr(colon_pos + 1)
		if port_str.is_valid_int():
			port = port_str.to_int()
	
	return {
		"https": is_https,
		"host": host,
		"port": port,
		"path": path
	}


func _connect_to_station(index: int, reset_redirects: bool = true) -> void:
	if reset_redirects:
		_redirect_count = 0
	
	var station_data: Dictionary = stations[index]
	icy_name = station_data.get("name", "JDM STREAM")
	icy_genre = station_data.get("genre", "LIVE")
	icy_bitrate = 128
	icy_metaint = 0
	current_track_title = "TUNING: " + icy_name.to_upper() + "..."
	
	station_changed.emit(index, icy_name)
	track_title_updated.emit(current_track_title)
	
	_connect_to_raw_url(station_data["url"])


func _connect_to_raw_url(url: String) -> void:
	_close_sockets()
	_stop_players()
	
	_header_buffer.clear()
	_audio_ring_buffer.clear()
	_meta_buffer.clear()
	_demux_state = DemuxState.AUDIO_DATA
	_bytes_until_meta = 0
	_meta_bytes_remaining = 0
	_state_timer = 0.0
	_data_watchdog = 0.0
	
	var parsed := _parse_url(url)
	_use_tls = parsed["https"]
	_parsed_host = parsed["host"]
	_parsed_port = parsed["port"]
	_parsed_path = parsed["path"]
	
	_tcp = StreamPeerTCP.new()
	
	# Resolve hostname if needed, or connect directly if IPv4/IPv6 literal
	var target_ip := _parsed_host
	if not _parsed_host.is_valid_ip_address():
		target_ip = IP.resolve_hostname(_parsed_host, IP.TYPE_ANY)
	
	if target_ip.is_empty() or not target_ip.is_valid_ip_address():
		_trigger_reconnect("DNS RESOLUTION FAILED")
		return
	
	var err := _tcp.connect_to_host(target_ip, _parsed_port)
	if err != OK:
		_trigger_reconnect("TCP CONNECT ERR: " + str(err))
		return
	
	_tcp.set_no_delay(true)
	_set_state(StreamState.CONNECTING)


func _close_sockets() -> void:
	if _tls != null:
		_tls.disconnect_from_stream()
		_tls = null
	if _tcp != null:
		_tcp.disconnect_from_host()
		_tcp = null
	_active_peer = null


func _stop_players() -> void:
	if _player_a:
		_player_a.stop()
		_player_a.stream = null
	if _player_b:
		_player_b.stop()
		_player_b.stream = null
	_active_slice_duration = 0.0
	_active_slice_elapsed = 0.0
	_is_crossfading = false
	_crossfade_elapsed = 0.0


func _set_state(new_state: StreamState) -> void:
	state = new_state
	_state_timer = 0.0
	stream_state_changed.emit(StreamState.keys()[new_state])


# ==============================================================================
# 5. NON-BLOCKING MAIN LOOP: NETWORK POLLING, DEMUXING & AUDIO FEEDING
# ==============================================================================

func _process(delta: float) -> void:
	if not is_powered_on or state == StreamState.OFF:
		if _vfd_control and is_hud_visible:
			_vfd_control.update_visuals(delta)
		return
	
	_state_timer += delta
	
	match state:
		StreamState.CONNECTING:
			_poll_tcp_connecting()
		StreamState.TLS_HANDSHAKE:
			_poll_tls_handshake()
		StreamState.SENDING_REQUEST:
			_send_icy_http_request()
		StreamState.READING_HEADERS:
			_poll_http_headers()
		StreamState.BUFFERING:
			_poll_audio_stream(delta)
			if _audio_ring_buffer.size() >= PREBUFFER_THRESHOLD:
				if _start_next_audio_slice(false):
					_set_state(StreamState.PLAYING)
		StreamState.PLAYING:
			_poll_audio_stream(delta)
			_update_audio_playback(delta)
		StreamState.RECONNECTING:
			_reconnect_tick(delta)
		StreamState.ERROR:
			pass
	
	if _vfd_control and is_hud_visible:
		_vfd_control.update_visuals(delta)


func _poll_tcp_connecting() -> void:
	_tcp.poll()
	var status := _tcp.get_status()
	
	if status == StreamPeerTCP.STATUS_CONNECTED:
		if _use_tls:
			_tls = StreamPeerTLS.new()
			var tls_opts := TLSOptions.client_unsafe()
			var err := _tls.connect_to_stream(_tcp, _parsed_host, tls_opts)
			if err != OK:
				_trigger_reconnect("TLS INIT FAILED")
				return
			_set_state(StreamState.TLS_HANDSHAKE)
		else:
			_active_peer = _tcp
			_set_state(StreamState.SENDING_REQUEST)
	elif status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		_trigger_reconnect("TCP SOCKET REFUSED")
	elif _state_timer > CONNECTION_TIMEOUT:
		_trigger_reconnect("TCP TIMEOUT")


func _poll_tls_handshake() -> void:
	_tls.poll()
	var status := _tls.get_status()
	
	if status == StreamPeerTLS.STATUS_CONNECTED:
		_active_peer = _tls
		_set_state(StreamState.SENDING_REQUEST)
	elif status == StreamPeerTLS.STATUS_ERROR or status == StreamPeerTLS.STATUS_ERROR_HOSTNAME_MISMATCH:
		_trigger_reconnect("TLS HANDSHAKE ERROR")
	elif _state_timer > CONNECTION_TIMEOUT:
		_trigger_reconnect("TLS TIMEOUT")


func _send_icy_http_request() -> void:
	var host_header := _parsed_host
	if (_use_tls and _parsed_port != 443) or (not _use_tls and _parsed_port != 80):
		host_header += ":" + str(_parsed_port)
	
	var req_lines := PackedStringArray([
		"GET " + _parsed_path + " HTTP/1.0",
		"Host: " + host_header,
		"User-Agent: MountAkinaJDM/4.3 (WinampMPEG)",
		"Accept: */*",
		"Icy-MetaData: 1",
		"Connection: close",
		"",
		""
	])
	var raw_request := "\r\n".join(req_lines).to_utf8_buffer()
	var err := _active_peer.put_data(raw_request)
	if err != OK:
		_trigger_reconnect("REQUEST WRITE FAILED")
		return
	
	_set_state(StreamState.READING_HEADERS)


func _poll_http_headers() -> void:
	if not _poll_active_socket():
		return
	
	var avail := _active_peer.get_available_bytes()
	if avail > 0:
		var res := _active_peer.get_partial_data(mini(avail, 4096))
		if res[0] == OK:
			var chunk: PackedByteArray = res[1]
			_header_buffer.append_array(chunk)
			
			var split_idx := _find_header_terminator(_header_buffer)
			if split_idx != -1:
				var header_bytes := _header_buffer.slice(0, split_idx)
				var leftover_audio := _header_buffer.slice(split_idx + 4)
				_header_buffer.clear()
				
				if _parse_icy_headers(header_bytes.get_string_from_ascii()):
					if icy_metaint > 0:
						_bytes_until_meta = icy_metaint
					_demux_state = DemuxState.AUDIO_DATA
					if leftover_audio.size() > 0:
						_demux_incoming_bytes(leftover_audio)
					_set_state(StreamState.BUFFERING)
					current_track_title = icy_name + " - LIVE"
					track_title_updated.emit(current_track_title)
				return
	
	if _state_timer > CONNECTION_TIMEOUT:
		_trigger_reconnect("HEADER READ TIMEOUT")


func _find_header_terminator(buf: PackedByteArray) -> int:
	var limit := buf.size() - 3
	for i in range(limit):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
	return -1


func _parse_icy_headers(raw_headers: String) -> bool:
	var lines := raw_headers.split("\r\n", false)
	if lines.is_empty():
		_trigger_reconnect("EMPTY HTTP RESPONSE")
		return false
	
	var status_line := lines[0].to_upper()
	if not ("200" in status_line):
		# Handle HTTP 301 / 302 / 307 Redirects gracefully
		if "301" in status_line or "302" in status_line or "307" in status_line or "308" in status_line:
			for i in range(1, lines.size()):
				var l := lines[i]
				if l.to_lower().begins_with("location:"):
					var redirect_url := l.substr(9).strip_edges()
					if _redirect_count < MAX_REDIRECTS:
						_redirect_count += 1
						_connect_to_raw_url(redirect_url)
						return false
		_trigger_reconnect("HTTP STATUS: " + status_line)
		return false
	
	for i in range(1, lines.size()):
		var line := lines[i]
		var colon := line.find(":")
		if colon == -1:
			continue
		var key := line.substr(0, colon).strip_edges().to_lower()
		var val := line.substr(colon + 1).strip_edges()
		
		match key:
			"icy-name":
				if not val.is_empty():
					icy_name = val
			"icy-genre":
				if not val.is_empty():
					icy_genre = val
			"icy-br":
				if val.is_valid_int():
					icy_bitrate = maxi(val.to_int(), 32)
			"icy-metaint":
				if val.is_valid_int():
					icy_metaint = maxi(val.to_int(), 0)
	
	return true


# ==============================================================================
# 6. STREAMING DEMUXER: SEPARATING MPEG AUDIO FRAMES FROM ICY METADATA
# ==============================================================================

func _poll_active_socket() -> bool:
	if _use_tls and _tls != null:
		_tls.poll()
		var st := _tls.get_status()
		if st != StreamPeerTLS.STATUS_CONNECTED:
			_trigger_reconnect("TLS STREAM DROPPED")
			return false
	elif _tcp != null:
		_tcp.poll()
		var st := _tcp.get_status()
		if st != StreamPeerTCP.STATUS_CONNECTED:
			_trigger_reconnect("TCP STREAM DROPPED")
			return false
	else:
		return false
	return true


func _poll_audio_stream(delta: float) -> void:
	if not _poll_active_socket():
		return
	
	var avail := _active_peer.get_available_bytes()
	if avail > 0:
		_data_watchdog = 0.0
		var to_read := mini(avail, SOCKET_READ_CAP)
		var res := _active_peer.get_partial_data(to_read)
		if res[0] == OK:
			var raw_bytes: PackedByteArray = res[1]
			if raw_bytes.size() > 0:
				_demux_incoming_bytes(raw_bytes)
	else:
		_data_watchdog += delta
		if _data_watchdog > CONNECTION_TIMEOUT:
			_trigger_reconnect("STREAM DATA STALLED")


func _demux_incoming_bytes(chunk: PackedByteArray) -> void:
	if icy_metaint <= 0:
		_append_to_audio_ring_buffer(chunk)
		return
	
	var cursor: int = 0
	var total: int = chunk.size()
	
	while cursor < total:
		match _demux_state:
			DemuxState.AUDIO_DATA:
				var take := mini(total - cursor, _bytes_until_meta)
				if take > 0:
					_append_to_audio_ring_buffer(chunk.slice(cursor, cursor + take))
					cursor += take
					_bytes_until_meta -= take
				if _bytes_until_meta == 0:
					_demux_state = DemuxState.META_LENGTH
			
			DemuxState.META_LENGTH:
				var length_multiplier: int = chunk[cursor]
				cursor += 1
				_meta_bytes_remaining = length_multiplier * 16
				_meta_buffer.clear()
				if _meta_bytes_remaining > 0:
					_demux_state = DemuxState.META_STRING
				else:
					_bytes_until_meta = icy_metaint
					_demux_state = DemuxState.AUDIO_DATA
			
			DemuxState.META_STRING:
				var take := mini(total - cursor, _meta_bytes_remaining)
				if take > 0:
					_meta_buffer.append_array(chunk.slice(cursor, cursor + take))
					cursor += take
					_meta_bytes_remaining -= take
				if _meta_bytes_remaining == 0:
					_parse_metadata_payload(_meta_buffer)
					_bytes_until_meta = icy_metaint
					_demux_state = DemuxState.AUDIO_DATA


func _append_to_audio_ring_buffer(bytes: PackedByteArray) -> void:
	_audio_ring_buffer.append_array(bytes)
	if _audio_ring_buffer.size() > MAX_AUDIO_BUFFER_SIZE:
		var excess := _audio_ring_buffer.size() - MAX_AUDIO_BUFFER_SIZE
		_audio_ring_buffer = _audio_ring_buffer.slice(excess)


func _parse_metadata_payload(meta_bytes: PackedByteArray) -> void:
	var clean_len := meta_bytes.size()
	while clean_len > 0 and meta_bytes[clean_len - 1] == 0:
		clean_len -= 1
	if clean_len <= 0:
		return
	
	var meta_str := meta_bytes.slice(0, clean_len).get_string_from_utf8()
	var key_idx := meta_str.find("StreamTitle='")
	if key_idx != -1:
		var start := key_idx + 13
		var end := meta_str.find("';", start)
		if end == -1:
			end = meta_str.rfind("'")
		if end > start:
			var extracted := meta_str.substr(start, end - start).strip_edges()
			if not extracted.is_empty() and extracted != current_track_title:
				current_track_title = extracted
				track_title_updated.emit(current_track_title)


# ==============================================================================
# 7. MPEG SYNC-WORD SLICER & DUAL-PLAYER CROSSFADING ENGINE
# ==============================================================================

func _find_first_mp3_sync(buf: PackedByteArray, start_offset: int = 0) -> int:
	var limit := buf.size() - 3
	for i in range(start_offset, limit):
		if buf[i] == 0xFF and (buf[i + 1] & 0xE0) == 0xE0:
			var version_bits := (buf[i + 1] >> 3) & 0x03
			var layer_bits := (buf[i + 1] >> 1) & 0x03
			var bitrate_idx := (buf[i + 2] >> 4) & 0x0F
			var sample_idx := (buf[i + 2] >> 2) & 0x03
			if version_bits != 1 and layer_bits != 0 and bitrate_idx != 0 and bitrate_idx != 15 and sample_idx != 3:
				return i
	return -1


func _find_last_mp3_sync(buf: PackedByteArray, max_offset: int) -> int:
	var start := mini(max_offset, buf.size() - 4)
	for i in range(start, 2048, -1):
		if buf[i] == 0xFF and (buf[i + 1] & 0xE0) == 0xE0:
			var version_bits := (buf[i + 1] >> 3) & 0x03
			var layer_bits := (buf[i + 1] >> 1) & 0x03
			var bitrate_idx := (buf[i + 2] >> 4) & 0x0F
			var sample_idx := (buf[i + 2] >> 2) & 0x03
			if version_bits != 1 and layer_bits != 0 and bitrate_idx != 0 and bitrate_idx != 15 and sample_idx != 3:
				return i
	return -1


func _start_next_audio_slice(use_crossfade: bool) -> bool:
	if _audio_ring_buffer.size() < SLICE_BYTE_SIZE:
		return false
	
	var first_sync := _find_first_mp3_sync(_audio_ring_buffer, 0)
	if first_sync == -1:
		_audio_ring_buffer.clear()
		return false
	
	if first_sync > 0:
		_audio_ring_buffer = _audio_ring_buffer.slice(first_sync)
	
	if _audio_ring_buffer.size() < SLICE_BYTE_SIZE:
		return false
	
	var cut_point := _find_last_mp3_sync(_audio_ring_buffer, SLICE_BYTE_SIZE)
	if cut_point <= 0:
		cut_point = SLICE_BYTE_SIZE
	
	var overlap_end := mini(cut_point + 512, _audio_ring_buffer.size())
	var slice_bytes := _audio_ring_buffer.slice(0, overlap_end)
	_audio_ring_buffer = _audio_ring_buffer.slice(cut_point)
	
	var mp3_stream := AudioStreamMP3.new()
	mp3_stream.data = slice_bytes
	var duration := mp3_stream.get_length()
	
	if duration <= 0.08:
		return false
	
	if use_crossfade and _active_player.playing:
		var prev_player := _active_player
		_active_player = _standby_player
		_standby_player = prev_player
		
		_active_player.stream = mp3_stream
		_active_player.volume_db = -24.0
		_active_player.play()
		
		_is_crossfading = true
		_crossfade_elapsed = 0.0
	else:
		_active_player.stream = mp3_stream
		_active_player.volume_db = 0.0
		_active_player.play()
		_is_crossfading = false
	
	var bitrate_bytes_per_sec := float(maxi(icy_bitrate, 64) * 1000) / 8.0
	var exact_cut_duration := float(cut_point) / bitrate_bytes_per_sec
	_active_slice_duration = clampf(duration - CROSSFADE_TIME, exact_cut_duration * 0.85, duration - 0.02)
	_active_slice_elapsed = 0.0
	return true


func _update_audio_playback(delta: float) -> void:
	_active_slice_elapsed += delta
	
	if _is_crossfading:
		_crossfade_elapsed += delta
		var t := clampf(_crossfade_elapsed / CROSSFADE_TIME, 0.0, 1.0)
		_active_player.volume_db = linear_to_db(maxf(t, 0.001))
		_standby_player.volume_db = linear_to_db(maxf(1.0 - t, 0.001))
		if t >= 1.0:
			_active_player.volume_db = 0.0
			_standby_player.stop()
			_is_crossfading = false
	
	if _active_slice_elapsed >= _active_slice_duration or not _active_player.playing:
		if not _start_next_audio_slice(true):
			_stop_players()
			_set_state(StreamState.BUFFERING)


# ==============================================================================
# 8. EXPONENTIAL BACKOFF RECONNECTION HANDLER
# ==============================================================================

func _trigger_reconnect(reason: String) -> void:
	_close_sockets()
	_stop_players()
	
	var shift_exp := mini(_reconnect_attempts, 3) # 2s, 4s, 8s, 16s cap
	_reconnect_wait_time = float(2 << shift_exp)
	_reconnect_attempts += 1
	_reconnect_accum = 0.0
	
	current_track_title = reason + " - RETRY IN " + str(int(_reconnect_wait_time)) + "S"
	track_title_updated.emit(current_track_title)
	_set_state(StreamState.RECONNECTING)


func _reconnect_tick(delta: float) -> void:
	_reconnect_accum += delta
	if _reconnect_accum >= _reconnect_wait_time:
		_connect_to_station(current_station_idx, true)


# ==============================================================================
# 9. PROCEDURAL 90s KENWOOD 1-DIN VFD (VACUUM FLUORESCENT DISPLAY) HUD
# ==============================================================================

class KenwoodVFDDisplay extends Control:
	var radio: JDMRadioAudioSystem
	
	# 90s Kenwood / Pioneer VFD Color Palette
	const COL_CHASSIS_OUTER := Color(0.08, 0.08, 0.10, 0.96)
	const COL_CHASSIS_BEVEL := Color(0.18, 0.19, 0.22, 1.0)
	const COL_VFD_GLASS := Color(0.02, 0.05, 0.06, 0.98)
	const COL_VFD_GRID := Color(0.05, 0.14, 0.16, 0.35)
	const COL_VFD_CYAN := Color(0.15, 0.98, 0.88, 1.0)
	const COL_VFD_CYAN_DIM := Color(0.06, 0.32, 0.30, 0.55)
	const COL_VFD_AMBER := Color(1.0, 0.42, 0.12, 1.0)
	const COL_VFD_RED_PEAK := Color(1.0, 0.18, 0.28, 1.0)
	const COL_BTN_BODY := Color(0.13, 0.14, 0.16, 1.0)
	
	const NUM_BANDS: int = 16
	var _band_levels: PackedFloat32Array = PackedFloat32Array()
	var _band_peaks: PackedFloat32Array = PackedFloat32Array()
	var _scroll_offset: float = 0.0
	var _vol_overlay_timer: float = 0.0
	var _blink_accum: float = 0.0
	
	func _init(owner_radio: JDMRadioAudioSystem) -> void:
		radio = owner_radio
		_band_levels.resize(NUM_BANDS)
		_band_peaks.resize(NUM_BANDS)
		_band_levels.fill(0.0)
		_band_peaks.fill(0.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	func trigger_volume_overlay() -> void:
		_vol_overlay_timer = 2.0
		queue_redraw()
	
	func update_visuals(delta: float) -> void:
		_blink_accum += delta
		if _vol_overlay_timer > 0.0:
			_vol_overlay_timer = maxf(0.0, _vol_overlay_timer - delta)
		
		# Scroll marquee text
		_scroll_offset += delta * 48.0
		
		# Sample 16 logarithmic frequency bands from AudioEffectSpectrumAnalyzerInstance
		var is_active_audio := (radio.is_powered_on and radio.state == JDMRadioAudioSystem.StreamState.PLAYING)
		var prev_hz: float = 40.0
		
		for i in range(NUM_BANDS):
			var max_hz := 40.0 * pow(350.0, float(i + 1) / float(NUM_BANDS))
			var target_val: float = 0.0
			
			if is_active_audio and radio._spectrum_instance != null:
				var mag_vec: Vector2 = radio._spectrum_instance.get_magnitude_for_frequency_range(prev_hz, max_hz)
				var energy := clampf(( linear_to_db(mag_vec.length()) + 58.0 ) / 52.0, 0.0, 1.0)
				target_val = energy
			
			prev_hz = max_hz
			
			if target_val > _band_levels[i]:
				_band_levels[i] = move_toward(_band_levels[i], target_val, delta * 9.5)
			else:
				_band_levels[i] = move_toward(_band_levels[i], target_val, delta * 3.2)
			
			if _band_levels[i] >= _band_peaks[i]:
				_band_peaks[i] = _band_levels[i]
			else:
				_band_peaks[i] = maxf(0.0, _band_peaks[i] - delta * 0.65)
		
		queue_redraw()
	
	func _draw() -> void:
		var font: Font = ThemeDB.fallback_font
		var w := size.x
		var h := size.y
		
		# 1. Outer 1-DIN Faceplate & Bevel
		draw_rect(Rect2(0, 0, w, h), COL_CHASSIS_OUTER, true)
		draw_rect(Rect2(0, 0, w, h), COL_CHASSIS_BEVEL, false, 2.0)
		draw_rect(Rect2(4, 4, w - 8, h - 8), Color(0.04, 0.04, 0.05, 1.0), false, 1.5)
		
		# 2. Left-side Kenwood Tactile Control Cluster
		_draw_left_buttons(font)
		
		# 3. Recessed VFD Glass Screen Window
		var screen_rect := Rect2(88, 12, w - 100, h - 34)
		draw_rect(screen_rect, COL_VFD_GLASS, true)
		draw_rect(screen_rect, Color(0.01, 0.25, 0.24, 0.6), false, 1.5)
		
		# Subtle background VFD filament scanlines
		var scan_y := screen_rect.position.y + 4.0
		while scan_y < screen_rect.end.y:
			draw_line(Vector2(screen_rect.position.x + 2, scan_y), Vector2(screen_rect.end.x - 2, scan_y), COL_VFD_GRID, 1.0)
			scan_y += 4.0
		
		# Bottom Bezel Branding & Key Hints
		draw_string(font, Vector2(90, h - 7), "KENWOOD  KDC-7000  DSP-SPECTRUM", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.65, 0.70, 0.75, 0.9))
		draw_string(font, Vector2(w - 200, h - 7), "[M] PWR  [T] CH  [-/=] VOL  [R] RESET", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.48, 0.52, 0.56, 0.85))
		
		if not radio.is_powered_on:
			draw_string(font, screen_rect.position + Vector2(95, 50), "STANDBY // PRESS [P]", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, COL_VFD_CYAN_DIM)
			return
		
		# 4. Top Status Ribbon (Channel Preset, Bitrate, Stereo Indicator, Volume)
		var ch_str := "CH-%02d [%s]" % [radio.current_station_idx + 1, radio.icy_genre.substr(0, 12).to_upper()]
		draw_string(font, screen_rect.position + Vector2(8, 16), ch_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COL_VFD_CYAN)
		
		var br_str := "%d KBPS" % radio.icy_bitrate
		draw_string(font, screen_rect.position + Vector2(165, 16), br_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COL_VFD_AMBER)
		
		var st_badge_col := COL_VFD_RED_PEAK if radio.state == JDMRadioAudioSystem.StreamState.PLAYING else COL_VFD_CYAN_DIM
		draw_string(font, screen_rect.position + Vector2(235, 16), "ST.LIVE", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, st_badge_col)
		
		var vol_pct := int(round(radio.master_volume_linear * 35.0))
		draw_string(font, screen_rect.position + Vector2(292, 16), "VOL %02d" % vol_pct, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COL_VFD_CYAN)
		
		# Divider Line
		draw_line(
			screen_rect.position + Vector2(6, 21),
			Vector2(screen_rect.end.x - 6, screen_rect.position.y + 21),
			COL_VFD_CYAN_DIM,
			1.0
		)
		
		# 5. Middle VFD Marquee (Track Title or Buffering Progress)
		var marquee_text := ""
		if _vol_overlay_timer > 0.0:
			var bars := int(round(radio.master_volume_linear * 20.0))
			marquee_text = "VOLUME LEVEL: [" + "#".repeat(bars) + "-".repeat(20 - bars) + "] " + str(int(radio.master_volume_linear * 100.0)) + "%"
		elif radio.state == JDMRadioAudioSystem.StreamState.BUFFERING:
			var pct := radio.get_buffering_percentage()
			marquee_text = "BUFFERING... [%02d%%]  %s" % [pct, radio.icy_name.to_upper()]
		elif radio.state == JDMRadioAudioSystem.StreamState.CONNECTING or radio.state == JDMRadioAudioSystem.StreamState.TLS_HANDSHAKE or radio.state == JDMRadioAudioSystem.StreamState.READING_HEADERS:
			marquee_text = "CONNECTING TO: " + radio.icy_name.to_upper() + "..."
		else:
			marquee_text = radio.icy_name.to_upper() + "  ::  " + radio.current_track_title.to_upper() + "     ***     "
		
		_draw_scrolling_marquee(font, Rect2(screen_rect.position.x + 8, screen_rect.position.y + 24, screen_rect.size.x - 16, 20), marquee_text)
		
		# 6. 16-Band Vacuum Fluorescent Spectrum Analyzer
		var spec_area := Rect2(screen_rect.position.x + 8, screen_rect.position.y + 46, screen_rect.size.x - 16, 38)
		_draw_spectrum_bars(spec_area)
	
	func _draw_left_buttons(font: Font) -> void:
		# Power Button
		var pwr_rect := Rect2(12, 12, 66, 24)
		draw_rect(pwr_rect, COL_BTN_BODY, true)
		var pwr_led := COL_VFD_RED_PEAK if radio.is_powered_on else Color(0.3, 0.1, 0.1, 1.0)
		draw_rect(Rect2(16, 16, 6, 6), pwr_led, true)
		draw_string(font, Vector2(26, 28), "SRC/PWR", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.85, 0.88, 0.9, 1.0))
		
		# Channel Up / Down Rocker
		var ch_rect := Rect2(12, 42, 66, 28)
		draw_rect(ch_rect, COL_BTN_BODY, true)
		draw_rect(ch_rect, COL_CHASSIS_BEVEL, false, 1.0)
		draw_string(font, Vector2(18, 60), "<< TUNE >>", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COL_VFD_CYAN)
		
		# Volume Control Rocker
		var vol_rect := Rect2(12, 76, 66, 26)
		draw_rect(vol_rect, COL_BTN_BODY, true)
		draw_rect(vol_rect, COL_CHASSIS_BEVEL, false, 1.0)
		draw_string(font, Vector2(20, 93), "- VOL +", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COL_VFD_AMBER)
	
	func _draw_scrolling_marquee(font: Font, clip_rect: Rect2, text: String) -> void:
		var font_size := 13
		if _vol_overlay_timer > 0.0 or radio.state == JDMRadioAudioSystem.StreamState.BUFFERING:
			draw_string(font, Vector2(clip_rect.position.x, clip_rect.position.y + 15), text, HORIZONTAL_ALIGNMENT_LEFT, clip_rect.size.x, font_size, COL_VFD_AMBER)
			return
		
		var text_width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		if text_width <= clip_rect.size.x:
			draw_string(font, Vector2(clip_rect.position.x, clip_rect.position.y + 15), text, HORIZONTAL_ALIGNMENT_LEFT, clip_rect.size.x, font_size, COL_VFD_CYAN)
			return
		
		# Continuous seamless loop via modulo offset and character clipping
		var loop_offset := fmod(_scroll_offset, text_width)
		var combined := text + text
		var approx_char_w := maxf(text_width / float(maxi(text.length(), 1)), 6.0)
		var first_char_idx := int(floor(loop_offset / approx_char_w))
		var visible_chars := int(ceil(clip_rect.size.x / approx_char_w)) + 4
		var sub_text := combined.substr(clampi(first_char_idx, 0, combined.length() - 1), visible_chars)
		var sub_pixel_shift := fmod(loop_offset, approx_char_w)
		
		draw_string(
			font,
			Vector2(clip_rect.position.x - sub_pixel_shift, clip_rect.position.y + 15),
			sub_text,
			HORIZONTAL_ALIGNMENT_LEFT,
			clip_rect.size.x + approx_char_w * 2.0,
			font_size,
			COL_VFD_CYAN
		)
	
	func _draw_spectrum_bars(area: Rect2) -> void:
		var num_segments: int = 8
		var bar_spacing: float = 3.0
		var total_w := area.size.x
		var bar_w := (total_w - (bar_spacing * float(NUM_BANDS - 1))) / float(NUM_BANDS)
		var seg_h := (area.size.y - float(num_segments - 1) * 1.5) / float(num_segments)
		
		for b in range(NUM_BANDS):
			var bx := area.position.x + float(b) * (bar_w + bar_spacing)
			var active_segs := int(round(_band_levels[b] * float(num_segments)))
			var peak_seg := clampi(int(round(_band_peaks[b] * float(num_segments))), 0, num_segments)
			
			for s in range(num_segments):
				var sy := area.end.y - float(s + 1) * (seg_h + 1.5) + 1.5
				var seg_rect := Rect2(bx, sy, bar_w, seg_h)
				
				if s < active_segs:
					var col := COL_VFD_CYAN
					if s >= num_segments - 1:
						col = COL_VFD_RED_PEAK
					elif s >= num_segments - 3:
						col = COL_VFD_AMBER
					draw_rect(seg_rect, col, true)
				elif s == peak_seg - 1 and peak_seg > 0:
					draw_rect(seg_rect, COL_VFD_RED_PEAK, true)
				else:
					draw_rect(seg_rect, COL_VFD_CYAN_DIM, true)
