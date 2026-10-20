class_name JDMRadioAudioSystem
extends Node

## Mount Akina Touge - Live Internet Radio Streaming Engine & Kenwood VFD HUD
## Features a dedicated background HTTPClient network worker thread, MPEG frame-aligned
## ring buffering, dual-buffered AudioStreamMP3 playback, and a 12-band real-time
## AudioEffectSpectrumAnalyzer fluorescent head-unit display.

signal station_changed(station_index: int, station_data: Dictionary)
signal stream_status_changed(status_text: String)
signal radio_power_toggled(is_powered: bool)

const RADIO_BUS_NAME: String = "JDMRadioBus"
const CHUNK_TARGET_BYTES: int = 36864          # ~2.3 seconds at 128 kbps MP3
const PREBUFFER_THRESHOLD_BYTES: int = 57344   # ~3.5 seconds initial jitter buffer
const MAX_QUEUED_CHUNKS: int = 12
const SPECTRUM_BANDS: int = 12

const STATIONS: Array[Dictionary] = [
	{
		"freq": "88.6 FM",
		"name": "J-POP PROJECT TOKYO",
		"sub": "OFFICIAL JAPANESE HITS & ANIME",
		"url": "http://kathy.torontocast.com:3560/stream"
	},
	{
		"freq": "94.2 FM",
		"name": "CITY POP ONE 1986",
		"sub": "80s TOKYO MIDNIGHT CITY POP",
		"url": "http://65.21.61.215:8000/citypopone"
	},
	{
		"freq": "102.5 FM",
		"name": "JAPAN RADIO LIVE",
		"sub": "J-ROCK & TOUGE EUROBEAT / BEATS",
		"url": "https://stream.japanradio.de/live"
	}
]

const FREQ_RANGES: Array[Vector2] = [
	Vector2(20.0, 45.0),
	Vector2(45.0, 90.0),
	Vector2(90.0, 180.0),
	Vector2(180.0, 320.0),
	Vector2(320.0, 600.0),
	Vector2(600.0, 1100.0),
	Vector2(1100.0, 2000.0),
	Vector2(2000.0, 3600.0),
	Vector2(3600.0, 6200.0),
	Vector2(6200.0, 10000.0),
	Vector2(10000.0, 14500.0),
	Vector2(14500.0, 20000.0)
]

# Playback & Audio Bus State
var current_station_index: int = 0
var master_volume: float = 0.80
var is_powered_on: bool = true

var _radio_bus_idx: int = -1
var _spectrum_instance: AudioEffectSpectrumAnalyzerInstance = null
var _player_a: AudioStreamPlayer
var _player_b: AudioStreamPlayer
var _active_player: AudioStreamPlayer
var _standby_player: AudioStreamPlayer
var _is_prebuffering: bool = true

# Background Streaming Thread & Synchronization Primitives
var _stream_thread: Thread
var _mutex: Mutex
var _semaphore: Semaphore
var _thread_should_exit: bool = false
var _requested_station_idx: int = 0
var _station_switch_requested: bool = false
var _power_state_shared: bool = true

# Thread-Safe Audio Chunk Queue & Telemetry
var _ready_mp3_chunks: Array[AudioStreamMP3] = []
var _queued_byte_estimate: int = 0
var _network_status_shared: String = "BUFFERING // CONNECTING"

# Kenwood VFD UI Nodes & Spectrum State
var _hud_layer: CanvasLayer
var _vfd_canvas: Control
var _band_levels: PackedFloat32Array = PackedFloat32Array()
var _band_peaks: PackedFloat32Array = PackedFloat32Array()
var _band_peak_hold_timers: PackedFloat32Array = PackedFloat32Array()
var _status_cached: String = "BUFFERING // CONNECTING"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	_band_levels.resize(SPECTRUM_BANDS)
	_band_peaks.resize(SPECTRUM_BANDS)
	_band_peak_hold_timers.resize(SPECTRUM_BANDS)
	_band_levels.fill(0.0)
	_band_peaks.fill(0.0)
	_band_peak_hold_timers.fill(0.0)
	
	_setup_audio_bus_and_players()
	_build_kenwood_vfd_hud()
	
	_mutex = Mutex.new()
	_semaphore = Semaphore.new()
	_stream_thread = Thread.new()
	_requested_station_idx = current_station_index
	_station_switch_requested = true
	_stream_thread.start(_network_thread_main)
	_semaphore.post()


func _exit_tree() -> void:
	if _mutex:
		_mutex.lock()
		_thread_should_exit = true
		_mutex.unlock()
	if _semaphore:
		_semaphore.post()
	if _stream_thread and _stream_thread.is_started():
		_stream_thread.wait_to_finish()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	
	var key_event := event as InputEventKey
	var code := key_event.keycode if key_event.keycode != KEY_NONE else key_event.physical_keycode
	
	match code:
		KEY_M:
			toggle_power_mute()
			get_viewport().set_input_as_handled()
		KEY_N:
			next_station()
			get_viewport().set_input_as_handled()
		KEY_B:
			previous_station()
			get_viewport().set_input_as_handled()
		KEY_PAGEUP:
			adjust_volume(0.05)
			get_viewport().set_input_as_handled()
		KEY_PAGEDOWN:
			adjust_volume(-0.05)
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_service_dual_buffer_playback()
	_update_spectrum_analyzer(delta)
	if is_instance_valid(_vfd_canvas):
		_vfd_canvas.queue_redraw()


# ==============================================================================
# PUBLIC RADIO CONTROLS API
# ==============================================================================

func toggle_power_mute() -> void:
	is_powered_on = not is_powered_on
	_apply_volume_to_bus()
	
	_mutex.lock()
	_power_state_shared = is_powered_on
	if not is_powered_on:
		_ready_mp3_chunks.clear()
		_queued_byte_estimate = 0
		_network_status_shared = "STANDBY // MUTED"
	else:
		_station_switch_requested = true
		_requested_station_idx = current_station_index
		_network_status_shared = "TUNING // BUFFERING"
	_mutex.unlock()
	
	if not is_powered_on:
		_player_a.stop()
		_player_b.stop()
		_is_prebuffering = true
	else:
		_semaphore.post()
	
	radio_power_toggled.emit(is_powered_on)


func next_station() -> void:
	var next_idx: int = posmod(current_station_index + 1, STATIONS.size())
	select_station(next_idx)


func previous_station() -> void:
	var prev_idx: int = posmod(current_station_index - 1, STATIONS.size())
	select_station(prev_idx)


func select_station(index: int) -> void:
	current_station_index = posmod(index, STATIONS.size())
	if not is_powered_on:
		is_powered_on = true
		_apply_volume_to_bus()
	
	_player_a.stop()
	_player_b.stop()
	_is_prebuffering = true
	
	_mutex.lock()
	_power_state_shared = true
	_requested_station_idx = current_station_index
	_station_switch_requested = true
	_ready_mp3_chunks.clear()
	_queued_byte_estimate = 0
	_network_status_shared = "TUNING // " + STATIONS[current_station_index]["freq"]
	_mutex.unlock()
	
	_semaphore.post()
	station_changed.emit(current_station_index, STATIONS[current_station_index])


func adjust_volume(delta_step: float) -> void:
	master_volume = clampf(master_volume + delta_step, 0.0, 1.0)
	if master_volume > 0.0 and not is_powered_on:
		is_powered_on = true
		_mutex.lock()
		_power_state_shared = true
		_station_switch_requested = true
		_mutex.unlock()
		_semaphore.post()
	_apply_volume_to_bus()


# ==============================================================================
# AUDIO BUS, SPECTRUM EFFECT & DUAL-BUFFER SWAP ENGINE
# ==============================================================================

func _setup_audio_bus_and_players() -> void:
	_radio_bus_idx = AudioServer.get_bus_index(RADIO_BUS_NAME)
	if _radio_bus_idx == -1:
		_radio_bus_idx = AudioServer.bus_count
		AudioServer.add_bus(_radio_bus_idx)
		AudioServer.set_bus_name(_radio_bus_idx, RADIO_BUS_NAME)
		AudioServer.set_bus_send(_radio_bus_idx, "Master")
	
	# Ensure an AudioEffectSpectrumAnalyzer is bound to our dedicated radio bus
	var found_analyzer := false
	for i in range(AudioServer.get_bus_effect_count(_radio_bus_idx)):
		var eff := AudioServer.get_bus_effect(_radio_bus_idx, i)
		if eff is AudioEffectSpectrumAnalyzer:
			_spectrum_instance = AudioServer.get_bus_effect_instance(_radio_bus_idx, i) as AudioEffectSpectrumAnalyzerInstance
			found_analyzer = true
			break
	
	if not found_analyzer:
		var analyzer := AudioEffectSpectrumAnalyzer.new()
		analyzer.buffer_length = 0.2
		analyzer.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(_radio_bus_idx, analyzer)
		var eff_idx: int = AudioServer.get_bus_effect_count(_radio_bus_idx) - 1
		_spectrum_instance = AudioServer.get_bus_effect_instance(_radio_bus_idx, eff_idx) as AudioEffectSpectrumAnalyzerInstance
	
	_player_a = AudioStreamPlayer.new()
	_player_a.name = "RadioDeckA"
	_player_a.bus = RADIO_BUS_NAME
	_player_a.finished.connect(_on_active_deck_finished.bind(_player_a))
	add_child(_player_a)
	
	_player_b = AudioStreamPlayer.new()
	_player_b.name = "RadioDeckB"
	_player_b.bus = RADIO_BUS_NAME
	_player_b.finished.connect(_on_active_deck_finished.bind(_player_b))
	add_child(_player_b)
	
	_active_player = _player_a
	_standby_player = _player_b
	_apply_volume_to_bus()


func _apply_volume_to_bus() -> void:
	if _radio_bus_idx == -1:
		return
	var is_muted: bool = (not is_powered_on) or (master_volume <= 0.001)
	AudioServer.set_bus_mute(_radio_bus_idx, is_muted)
	if not is_muted:
		var db_val: float = linear_to_db(master_volume)
		AudioServer.set_bus_volume_db(_radio_bus_idx, db_val)


func _service_dual_buffer_playback() -> void:
	_mutex.lock()
	var net_status := _network_status_shared
	var chunk_count := _ready_mp3_chunks.size()
	var buffered_bytes := _queued_byte_estimate
	_mutex.unlock()
	
	if net_status != _status_cached:
		_status_cached = net_status
		stream_status_changed.emit(_status_cached)
	
	if not is_powered_on:
		return
	
	# Wait for 1.5 - 2.5+ seconds of prebuffered audio before starting initial playback
	if _is_prebuffering:
		if buffered_bytes >= PREBUFFER_THRESHOLD_BYTES or chunk_count >= 2:
			var first_stream := _pop_next_mp3_chunk()
			if first_stream != null:
				_is_prebuffering = false
				_active_player.stream = first_stream
				_active_player.play()
		return
	
	# Seamless Dual-Buffer Handoff:
	# If the active deck is within 45 milliseconds of finishing its current MP3 chunk,
	# or if it stopped unexpectedly, immediately swap to the standby deck with the next chunk.
	if _active_player.playing and _active_player.stream != null:
		var stream_len: float = _active_player.stream.get_length()
		var playback_pos: float = _active_player.get_playback_position()
		if stream_len > 0.15 and (stream_len - playback_pos) <= 0.040:
			var next_chunk := _pop_next_mp3_chunk()
			if next_chunk != null:
				_standby_player.stream = next_chunk
				_standby_player.play()
				_active_player.stop()
				var prev := _active_player
				_active_player = _standby_player
				_standby_player = prev
	elif not _active_player.playing:
		var recovery_chunk := _pop_next_mp3_chunk()
		if recovery_chunk != null:
			_active_player.stream = recovery_chunk
			_active_player.play()
		else:
			_is_prebuffering = true


func _on_active_deck_finished(deck: AudioStreamPlayer) -> void:
	if not is_powered_on or deck != _active_player:
		return
	var next_chunk := _pop_next_mp3_chunk()
	if next_chunk != null:
		_standby_player.stream = next_chunk
		_standby_player.play()
		var prev := _active_player
		_active_player = _standby_player
		_standby_player = prev
	else:
		_is_prebuffering = true


func _pop_next_mp3_chunk() -> AudioStreamMP3:
	var stream_out: AudioStreamMP3 = null
	_mutex.lock()
	if not _ready_mp3_chunks.is_empty():
		stream_out = _ready_mp3_chunks.pop_front()
		if stream_out != null:
			_queued_byte_estimate = maxi(0, _queued_byte_estimate - stream_out.data.size())
	_mutex.unlock()
	return stream_out


# ==============================================================================
# MULTI-THREADED HTTP STREAMING ENGINE & MPEG FRAME BOUNDARY SPLICER
# ==============================================================================

func _network_thread_main() -> void:
	var http := HTTPClient.new()
	var accumulation_buffer := PackedByteArray()
	var active_url: String = ""
	
	while true:
		_mutex.lock()
		var should_exit := _thread_should_exit
		var powered := _power_state_shared
		var switch_req := _station_switch_requested
		var target_idx := _requested_station_idx
		_mutex.unlock()
		
		if should_exit:
			http.close()
			break
		
		if not powered:
			http.close()
			accumulation_buffer.clear()
			_semaphore.wait()
			continue
		
		if switch_req:
			http.close()
			accumulation_buffer.clear()
			_mutex.lock()
			_station_switch_requested = false
			active_url = STATIONS[target_idx]["url"]
			_network_status_shared = "CONNECTING // " + STATIONS[target_idx]["freq"]
			_mutex.unlock()
		
		if active_url.is_empty():
			OS.delay_msec(50)
			continue
		
		# Connect & Stream Loop with Automatic Redirect Following & Silent Retry
		var current_url_to_try: String = active_url
		var redirects_followed: int = 0
		var stream_ok: bool = false
		
		while redirects_followed < 4:
			var parsed := _parse_stream_url(current_url_to_try)
			http.close()
			
			var tls_opts: TLSOptions = TLSOptions.client() if parsed["use_tls"] else null
			var err := http.connect_to_host(parsed["host"], parsed["port"], tls_opts)
			if err != OK:
				break
			
			# Poll Connection Phase
			var connect_start_ms: int = Time.get_ticks_msec()
			var connected := false
			while Time.get_ticks_msec() - connect_start_ms < 7500:
				if _check_thread_interrupt():
					break
				http.poll()
				var st := http.get_status()
				if st == HTTPClient.STATUS_CONNECTED:
					connected = true
					break
				elif st == HTTPClient.STATUS_CANT_CONNECT or st == HTTPClient.STATUS_CANT_RESOLVE or st == HTTPClient.STATUS_TLS_HANDSHAKE_ERROR or st == HTTPClient.STATUS_CONNECTION_ERROR:
					break
				OS.delay_msec(15)
			
			if not connected or _check_thread_interrupt():
				break
			
			var headers := PackedStringArray([
				"User-Agent: MountAkinaTougeRadio/4.3 (GodotEngine)",
				"Accept: */*",
				"Icy-MetaData: 0",
				"Connection: keep-alive"
			])
			err = http.request(HTTPClient.METHOD_GET, parsed["path"], headers)
			if err != OK:
				break
			
			# Wait for HTTP Response Headers
			var req_start_ms: int = Time.get_ticks_msec()
			var got_headers := false
			while Time.get_ticks_msec() - req_start_ms < 7500:
				if _check_thread_interrupt():
					break
				http.poll()
				var st := http.get_status()
				if st == HTTPClient.STATUS_BODY or http.has_response():
					got_headers = true
					break
				elif st == HTTPClient.STATUS_CONNECTION_ERROR or st == HTTPClient.STATUS_DISCONNECTED:
					break
				OS.delay_msec(15)
			
			if not got_headers or _check_thread_interrupt():
				break
			
			var response_code: int = http.get_response_code()
			if response_code in [301, 302, 303, 307, 308]:
				var resp_headers: Dictionary = http.get_response_headers_as_dictionary()
				var loc: String = ""
				for k in resp_headers.keys():
					if String(k).to_lower() == "location":
						loc = String(resp_headers[k])
						break
				if not loc.is_empty():
					current_url_to_try = loc
					redirects_followed += 1
					continue
				break
			
			if response_code != 200:
				break
			
			# Live Audio Body Streaming Phase
			stream_ok = true
			_mutex.lock()
			_network_status_shared = "CONNECTED // LIVE"
			_mutex.unlock()
			
			var last_byte_ms: int = Time.get_ticks_msec()
			while not _check_thread_interrupt():
				http.poll()
				var st := http.get_status()
				if st != HTTPClient.STATUS_BODY:
					break
				
				# Throttle socket reads if the main thread already has 12 chunks buffered
				var queue_full := false
				_mutex.lock()
				queue_full = (_ready_mp3_chunks.size() >= MAX_QUEUED_CHUNKS)
				_mutex.unlock()
				
				if queue_full:
					last_byte_ms = Time.get_ticks_msec()
					OS.delay_msec(40)
					continue
				
				var chunk: PackedByteArray = http.read_response_body_chunk()
				if chunk.size() > 0:
					last_byte_ms = Time.get_ticks_msec()
					accumulation_buffer.append_array(chunk)
					
					if accumulation_buffer.size() >= CHUNK_TARGET_BYTES:
						_extract_and_push_mpeg_chunk(accumulation_buffer)
				else:
					if Time.get_ticks_msec() - last_byte_ms > 9000:
						# Stream stalled for >9s; trigger silent background reconnect
						break
					OS.delay_msec(12)
			
			break
		
		# If interrupted by user station switch or mute, loop immediately
		if _check_thread_interrupt():
			continue
		
		# Silent Auto-Retry Backoff on Network Drop
		_mutex.lock()
		if not stream_ok:
			_network_status_shared = "RECONNECTING // RETRY"
		_mutex.unlock()
		
		var retry_wait_ms: int = 0
		while retry_wait_ms < 1600 and not _check_thread_interrupt():
			OS.delay_msec(100)
			retry_wait_ms += 100


func _check_thread_interrupt() -> bool:
	_mutex.lock()
	var interrupted: bool = _thread_should_exit or (not _power_state_shared) or _station_switch_requested
	_mutex.unlock()
	return interrupted


func _extract_and_push_mpeg_chunk(buffer: PackedByteArray) -> void:
	# Align slice to valid 11-bit MPEG frame sync words (0xFF followed by 0xE0..0xFE)
	# so AudioStreamMP3 receives clean frame boundaries without click artifacts.
	var first_sync: int = _find_mpeg_sync_offset(buffer, 0)
	if first_sync > 0:
		var trimmed := buffer.slice(first_sync)
		buffer.clear()
		buffer.append_array(trimmed)
	
	if buffer.size() < CHUNK_TARGET_BYTES:
		return
	
	var end_sync: int = _find_mpeg_sync_offset_reverse(buffer, buffer.size() - 4, CHUNK_TARGET_BYTES - 4096)
	if end_sync <= 0:
		end_sync = buffer.size()
	
	var mp3_bytes: PackedByteArray = buffer.slice(0, end_sync)
	var remainder: PackedByteArray = buffer.slice(end_sync)
	buffer.clear()
	buffer.append_array(remainder)
	
	var mp3_stream := AudioStreamMP3.new()
	mp3_stream.data = mp3_bytes
	
	_mutex.lock()
	if not _station_switch_requested and _power_state_shared:
		_ready_mp3_chunks.append(mp3_stream)
		_queued_byte_estimate += mp3_bytes.size()
	_mutex.unlock()


func _find_mpeg_sync_offset(data: PackedByteArray, start_idx: int) -> int:
	var limit: int = data.size() - 2
	for i in range(maxi(0, start_idx), limit):
		if data[i] == 0xFF and (data[i + 1] & 0xE0) == 0xE0 and (data[i + 1] & 0x18) != 0x08 and (data[i + 1] & 0x06) != 0x00:
			return i
	return 0


func _find_mpeg_sync_offset_reverse(data: PackedByteArray, from_idx: int, min_idx: int) -> int:
	var lower: int = maxi(0, min_idx)
	var i: int = mini(from_idx, data.size() - 2)
	while i >= lower:
		if data[i] == 0xFF and (data[i + 1] & 0xE0) == 0xE0 and (data[i + 1] & 0x18) != 0x08 and (data[i + 1] & 0x06) != 0x00:
			return i
		i -= 1
	return -1


func _parse_stream_url(raw_url: String) -> Dictionary:
	var use_tls: bool = raw_url.begins_with("https://")
	var stripped: String = raw_url.replace("https://", "").replace("http://", "")
	
	var slash_pos: int = stripped.find("/")
	var host_port: String = stripped if slash_pos == -1 else stripped.substr(0, slash_pos)
	var path: String = "/" if slash_pos == -1 else stripped.substr(slash_pos)
	
	var host: String = host_port
	var port: int = 443 if use_tls else 80
	
	var colon_pos: int = host_port.find(":")
	if colon_pos != -1:
		host = host_port.substr(0, colon_pos)
		port = host_port.substr(colon_pos + 1).to_int()
	
	return {
		"host": host,
		"port": port,
		"path": path,
		"use_tls": use_tls
	}


# ==============================================================================
# KENWOOD VFD FLUORESCENT HUD & 12-BAND SPECTRUM ANALYZER
# ==============================================================================

func _update_spectrum_analyzer(delta: float) -> void:
	var is_active_audio: bool = is_powered_on and (_active_player != null and _active_player.playing) and master_volume > 0.001
	
	for i in range(SPECTRUM_BANDS):
		var target_energy: float = 0.0
		if is_active_audio and _spectrum_instance != null:
			var range_hz: Vector2 = FREQ_RANGES[i]
			var mag: Vector2 = _spectrum_instance.get_magnitude_for_frequency_range(range_hz.x, range_hz.y, AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_MAX)
			var linear_mag: float = (mag.x + mag.y) * 0.5
			# Convert linear FFT magnitude to normalized VFD bar height (60 dB dynamic range)
			target_energy = clampf((linear_to_db(linear_mag + 0.00001) + 60.0) / 56.0, 0.0, 1.0)
			# High-frequency visual compensation curve
			target_energy = clampf(target_energy * lerpf(1.0, 1.45, float(i) / float(SPECTRUM_BANDS - 1)), 0.0, 1.0)
		
		if target_energy > _band_levels[i]:
			_band_levels[i] = move_toward(_band_levels[i], target_energy, delta * 9.5)
		else:
			_band_levels[i] = move_toward(_band_levels[i], target_energy, delta * 2.8)
		
		if _band_levels[i] >= _band_peaks[i]:
			_band_peaks[i] = _band_levels[i]
			_band_peak_hold_timers[i] = 0.38
		else:
			if _band_peak_hold_timers[i] > 0.0:
				_band_peak_hold_timers[i] -= delta
			else:
				_band_peaks[i] = move_toward(_band_peaks[i], _band_levels[i], delta * 1.15)


func _build_kenwood_vfd_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "KenwoodVFDRadioHUD"
	_hud_layer.layer = 85
	add_child(_hud_layer)
	
	var anchor_root := Control.new()
	anchor_root.name = "TopRightAnchor"
	anchor_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(anchor_root)
	
	_vfd_canvas = Control.new()
	_vfd_canvas.name = "VFDDisplayUnit"
	_vfd_canvas.anchor_left = 1.0
	_vfd_canvas.anchor_right = 1.0
	_vfd_canvas.anchor_top = 0.0
	_vfd_canvas.anchor_bottom = 0.0
	_vfd_canvas.offset_left = -416.0
	_vfd_canvas.offset_right = -18.0
	_vfd_canvas.offset_top = 18.0
	_vfd_canvas.offset_bottom = 176.0
	_vfd_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vfd_canvas.draw.connect(_draw_kenwood_vfd_unit)
	anchor_root.add_child(_vfd_canvas)


func _draw_kenwood_vfd_unit() -> void:
	var font: Font = ThemeDB.fallback_font
	var rect := Rect2(Vector2.ZERO, _vfd_canvas.size)
	
	# 1. Outer Brushed Dark Faceplate & Fluorescent Glass Bezel
	_vfd_canvas.draw_rect(rect, Color(0.03, 0.04, 0.06, 0.92), true)
	_vfd_canvas.draw_rect(Rect2(3, 3, rect.size.x - 6, rect.size.y - 6), Color(0.015, 0.025, 0.035, 0.96), true)
	
	var vfd_cyan := Color(0.18, 0.95, 0.88, 1.0)
	var vfd_cyan_dim := Color(0.10, 0.42, 0.40, 0.32)
	var vfd_amber := Color(1.0, 0.68, 0.18, 1.0)
	var vfd_red := Color(1.0, 0.24, 0.30, 1.0)
	
	var border_col: Color = vfd_cyan if is_powered_on else Color(0.25, 0.30, 0.35, 0.5)
	_vfd_canvas.draw_rect(rect, Color(border_col.r, border_col.g, border_col.b, 0.65), false, 1.5)
	
	# 2. Top Brand & Status Bar
	_vfd_canvas.draw_string(font, Vector2(12, 20), "KENWOOD // KDC-9000DSP VFD", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.65, 0.78, 0.85, 0.85))
	
	var status_col: Color = vfd_cyan if ("LIVE" in _status_cached and is_powered_on) else vfd_amber
	if not is_powered_on:
		status_col = vfd_red
	_vfd_canvas.draw_string(font, Vector2(rect.size.x - 12, 20), _status_cached, HORIZONTAL_ALIGNMENT_RIGHT, -1, 11, status_col)
	
	# Subtle VFD scanline divider
	_vfd_canvas.draw_line(Vector2(10, 26), Vector2(rect.size.x - 10, 26), Color(0.18, 0.95, 0.88, 0.22), 1.0)
	
	# 3. Left Telemetry Column: Station Frequency, Name, Volume & Controls
	var st_data: Dictionary = STATIONS[current_station_index]
	var freq_text: String = st_data["freq"] if is_powered_on else "---.- FM"
	var name_text: String = st_data["name"] if is_powered_on else "POWER OFF // MUTED"
	var sub_text: String = st_data["sub"] if is_powered_on else "PRESS [M] TO POWER ON"
	
	_vfd_canvas.draw_string(font, Vector2(12, 54), freq_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, vfd_cyan if is_powered_on else vfd_cyan_dim)
	
	# Stereo / Digital Lock Badge
	var st_badge_col: Color = vfd_amber if is_powered_on else vfd_cyan_dim
	_vfd_canvas.draw_string(font, Vector2(128, 44), "[ST]", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, st_badge_col)
	_vfd_canvas.draw_string(font, Vector2(128, 55), "DSP", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, vfd_cyan if is_powered_on else vfd_cyan_dim)
	
	_vfd_canvas.draw_string(font, Vector2(12, 76), name_text, HORIZONTAL_ALIGNMENT_LEFT, 205, 13, Color(0.92, 0.98, 1.0, 0.95) if is_powered_on else vfd_cyan_dim)
	_vfd_canvas.draw_string(font, Vector2(12, 92), sub_text, HORIZONTAL_ALIGNMENT_LEFT, 205, 10, Color(0.55, 0.78, 0.82, 0.80))
	
	# Live Volume Bar & Readout
	var vol_pct: int = int(round(master_volume * 100.0)) if is_powered_on else 0
	_vfd_canvas.draw_string(font, Vector2(12, 116), "VOL %02d%%" % vol_pct, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, vfd_amber if is_powered_on else vfd_cyan_dim)
	
	var vol_segments: int = 14
	var active_vol_segs: int = int(round(master_volume * float(vol_segments))) if is_powered_on else 0
	for s in range(vol_segments):
		var seg_rect := Rect2(76.0 + s * 9.0, 106.0, 6.5, 10.0)
		if s < active_vol_segs:
			var seg_c: Color = vfd_cyan if s < 11 else vfd_amber
			_vfd_canvas.draw_rect(seg_rect, seg_c, true)
		else:
			_vfd_canvas.draw_rect(seg_rect, vfd_cyan_dim, true)
	
	# 4. Right Column: 12-Band VFD Fluorescent Spectrum Analyzer
	var spec_origin := Vector2(222.0, 36.0)
	var spec_size := Vector2(164.0, 84.0)
	var num_segments_y: int = 12
	var band_step_x: float = spec_size.x / float(SPECTRUM_BANDS)
	var bar_w: float = band_step_x - 3.0
	var seg_h: float = (spec_size.y / float(num_segments_y)) - 1.5
	
	for b in range(SPECTRUM_BANDS):
		var bx: float = spec_origin.x + float(b) * band_step_x
		var lit_count: int = int(round(_band_levels[b] * float(num_segments_y)))
		var peak_seg: int = clampi(int(round(_band_peaks[b] * float(num_segments_y))) - 1, -1, num_segments_y - 1)
		
		for s in range(num_segments_y):
			var sy: float = spec_origin.y + spec_size.y - float(s + 1) * (seg_h + 1.5)
			var cell_rect := Rect2(bx, sy, bar_w, seg_h)
			
			if s < lit_count:
				var seg_color: Color = vfd_cyan
				if s >= 10:
					seg_color = vfd_red
				elif s >= 7:
					seg_color = vfd_amber
				_vfd_canvas.draw_rect(cell_rect, seg_color, true)
			elif s == peak_seg and is_powered_on and peak_seg > 0:
				_vfd_canvas.draw_rect(cell_rect, Color(1.0, 0.92, 0.55, 0.95), true)
			else:
				_vfd_canvas.draw_rect(cell_rect, Color(0.08, 0.25, 0.26, 0.24), true)
	
	# Spectrum Frequency Legend
	_vfd_canvas.draw_string(font, Vector2(spec_origin.x, 131), "60Hz", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.5, 0.75, 0.78, 0.75))
	_vfd_canvas.draw_string(font, Vector2(spec_origin.x + 64, 131), "1kHz", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.5, 0.75, 0.78, 0.75))
	_vfd_canvas.draw_string(font, Vector2(spec_origin.x + 132, 131), "16kHz", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.5, 0.75, 0.78, 0.75))
	
	# 5. Bottom Keybind Legend Strip
	_vfd_canvas.draw_line(Vector2(10, 136), Vector2(rect.size.x - 10, 136), Color(0.18, 0.95, 0.88, 0.18), 1.0)
	var controls_str: String = "[M] PWR/MUTE   [B / N] PREV/NEXT CH   [PGUP / PGDN] VOL"
	_vfd_canvas.draw_string(font, Vector2(12, 150), controls_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.62, 0.82, 0.88, 0.85))