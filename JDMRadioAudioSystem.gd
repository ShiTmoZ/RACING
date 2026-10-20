class_name JDMRadioAudioSystem
extends CanvasLayer
## ShiTmoZ/RACING - Mount Akina Touge
## Retro JDM KRC-990SP Head Unit HUD & Dual-Engine Audio Architecture
## Strictly isolated Audio & UI Layer. Zero Physics/Collision side effects.

# ==============================================================================
# CONSTANTS & TELEMETRY CONFIGURATION
# ==============================================================================
const RADIO_BUS_NAME: String = "JDM_Radio_Bus"
const MIX_RATE: float = 44100.0
const SYNTH_BUFFER_LEN: float = 0.08 # 80ms low-latency buffer for RPM tracking

const COLOR_CHASSIS_BG := Color(0.07, 0.07, 0.09, 0.96)
const COLOR_CHASSIS_TRIM := Color(0.18, 0.19, 0.22, 1.0)
const COLOR_VFD_GLASS := Color(0.02, 0.04, 0.05, 0.98)
const COLOR_VFD_CYAN := Color(0.0, 0.95, 0.88, 1.0)
const COLOR_VFD_CYAN_DIM := Color(0.0, 0.22, 0.24, 0.45)
const COLOR_VFD_AMBER := Color(1.0, 0.58, 0.05, 1.0)
const COLOR_VFD_AMBER_DIM := Color(0.28, 0.14, 0.02, 0.45)
const COLOR_VFD_RED := Color(1.0, 0.18, 0.22, 1.0)

const DECK_WIDTH: float = 390.0
const DECK_HEIGHT: float = 128.0
const MARGIN_TOP: float = 18.0
const MARGIN_RIGHT: float = 18.0

# ==============================================================================
# STATION DEFINITIONS
# ==============================================================================
enum EngineType { LIVE_STREAM, PROCEDURAL_SYNTH }

class RadioStation:
	var freq: String
	var title: String
	var url: String
	var type: EngineType
	
	func _init(p_freq: String, p_title: String, p_url: String, p_type: EngineType) -> void:
		freq = p_freq
		title = p_title
		url = p_url
		type = p_type

var stations: Array[RadioStation] = [
	RadioStation.new("88.6 FM", "SUPER EUROBEAT TOUGE", "http://stream.laut.fm/eurobeat", EngineType.LIVE_STREAM),
	RadioStation.new("92.4 FM", "NIGHTWAVE PLAZA TOKYO", "https://radio.plaza.one/mp3", EngineType.LIVE_STREAM),
	RadioStation.new("96.8 FM", "RAINY TOUGE CHILLHOP", "https://play.streamafrica.net/lofiradio", EngineType.LIVE_STREAM),
	RadioStation.new("102.1 FM", "INITIAL DRIFT SYNTH (OFFLINE)", "", EngineType.PROCEDURAL_SYNTH)
]

# ==============================================================================
# STATE VARIABLES
# ==============================================================================
var current_station_idx: int = 3 # Default to zero-drop synth on boot, or switch freely
var master_volume_linear: float = 0.75
var is_drawer_open: bool = true
var is_handbook_muffled: bool = false
var is_currently_muffled: bool = false

# Read-only Passive Vehicle Telemetry (Normalized)
var _telemetry_rpm_norm: float = 0.25 # 0.0 (Idle) to 1.0 (Redline)
var _telemetry_drift_slip: float = 0.0 # 0.0 (Grip) to 1.0 (Full lock slide)
var _cached_vehicle_node: Node = null
var _telemetry_scan_timer: float = 0.0

# Audio Bus & Effects
var _bus_idx: int = -1
var _spectrum_instance: AudioEffectSpectrumAnalyzerInstance = null
var _lpf_effect: AudioEffectLowPassFilter = null

# Audio Players
var _synth_player: AudioStreamPlayer = null
var _synth_playback: AudioStreamGeneratorPlayback = null
var _stream_player: AudioStreamPlayer = null
var _stream_playback: AudioStreamGeneratorPlayback = null

# Engine A: Non-Blocking HTTP Streamer State
var _http_client: HTTPClient = null
var _stream_host: String = ""
var _stream_port: int = 80
var _stream_path: String = "/"
var _stream_use_tls: bool = false
var _stream_status_text: String = "STANDBY"
var _stream_retry_timer: float = 0.0
var _stream_redirect_hops: int = 0
var _mp3_ring_buffer: PackedByteArray = PackedByteArray()
var _decoded_pcm_queue: PackedVector2Array = PackedVector2Array()
var _pcm_read_head: int = 0
var _is_stream_fallback_active: bool = false

# Engine B: Procedural Synthesizer State
var _synth_phase_kick: float = 0.0
var _synth_phase_kick_env: float = 1.0
var _synth_phase_bass: float = 0.0
var _synth_phase_lead: float = 0.0
var _synth_phase_lfo: float = 0.0
var _synth_noise_seed: int = 1337420
var _synth_step_accumulator: float = 0.0
var _synth_current_step: int = 0
var _synth_bar_count: int = 0

# Musical patterns (MIDI note offsets for Phrygian/Minor Eurobeat drive)
const BASS_SEQUENCE: Array[int] = [33, 45, 33, 45, 36, 48, 38, 50, 40, 52, 40, 52, 39, 51, 40, 52]
const LEAD_ARPEGGIO: Array[int] = [69, 72, 76, 81, 76, 72, 83, 79, 76, 72, 69, 72, 76, 80, 83, 88]

# UI & VFD Canvas Node
var _deck_canvas: Control = null
var _drawer_slide_tween: Tween = null
var _fft_peaks: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
var _fft_holds: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
var _title_scroll_offset: float = 0.0
var _cassette_reel_angle: float = 0.0
var _key_flash_timers: Dictionary = {"prev": 0.0, "next": 0.0, "v_dn": 0.0, "v_up": 0.0, "hide": 0.0}

# ==============================================================================
# LIFECYCLE INITIALIZATION
# ==============================================================================
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 110 # Render cleanly above standard racing gauges
	
	_setup_audio_bus()
	_setup_audio_players()
	_setup_vfd_hud()
	
	_tune_station(0) # Boot into Station 1 (88.6 FM Super Eurobeat)

func _exit_tree() -> void:
	if _http_client != null:
		_http_client.close()
	if _bus_idx != -1 and _bus_idx < AudioServer.bus_count:
		if AudioServer.get_bus_name(_bus_idx) == RADIO_BUS_NAME:
			AudioServer.remove_bus(_bus_idx)

# ==============================================================================
# AUDIO BUS & DSP ARCHITECTURE
# ==============================================================================
func _setup_audio_bus() -> void:
	_bus_idx = AudioServer.get_bus_index(RADIO_BUS_NAME)
	if _bus_idx == -1:
		AudioServer.add_bus()
		_bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_bus_idx, RADIO_BUS_NAME)
		AudioServer.set_bus_send(_bus_idx, "Master")
	
	# Clear existing effects if reloaded
	for i in range(AudioServer.get_bus_effect_count(_bus_idx) - 1, -1, -1):
		AudioServer.remove_bus_effect(_bus_idx, i)
	
	# 1. Live Spectrum Analyzer for 8-Bar VFD Display
	var spectrum_fx := AudioEffectSpectrumAnalyzer.new()
	spectrum_fx.buffer_length = 0.1
	spectrum_fx.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_512
	AudioServer.add_bus_effect(_bus_idx, spectrum_fx, 0)
	_spectrum_instance = AudioServer.get_bus_effect_instance(_bus_idx, 0) as AudioEffectSpectrumAnalyzerInstance
	
	# 2. Cabin Acoustic Muffle Low-Pass Filter (Pause / F1 Handbook)
	_lpf_effect = AudioEffectLowPassFilter.new()
	_lpf_effect.cutoff_hz = 20500.0
	_lpf_effect.resonance = 0.65
	_lpf_effect.db = AudioEffectFilter.FILTER_12DB
	AudioServer.add_bus_effect(_bus_idx, _lpf_effect, 1)
	
	_apply_master_volume()

func _setup_audio_players() -> void:
	# Engine B Player (Procedural Synth + Zero-Drop Fallback)
	_synth_player = AudioStreamPlayer.new()
	_synth_player.name = "EngineB_ProceduralSynth"
	_synth_player.bus = RADIO_BUS_NAME
	var synth_gen := AudioStreamGenerator.new()
	synth_gen.mix_rate = MIX_RATE
	synth_gen.buffer_length = SYNTH_BUFFER_LEN
	_synth_player.stream = synth_gen
	add_child(_synth_player)
	_synth_player.play()
	_synth_playback = _synth_player.get_stream_playback() as AudioStreamGeneratorPlayback
	
	# Engine A Player (Decoded Live HTTP Stream PCM feeder)
	_stream_player = AudioStreamPlayer.new()
	_stream_player.name = "EngineA_LiveStream"
	_stream_player.bus = RADIO_BUS_NAME
	var stream_gen := AudioStreamGenerator.new()
	stream_gen.mix_rate = MIX_RATE
	stream_gen.buffer_length = 0.5 # 500ms jitter buffer for HTTP chunks
	_stream_player.stream = stream_gen
	add_child(_stream_player)
	_stream_player.play()
	_stream_playback = _stream_player.get_stream_playback() as AudioStreamGeneratorPlayback
	
	_http_client = HTTPClient.new()

# ==============================================================================
# HUD CREATION & DRAW DISPATCH
# ==============================================================================
func _setup_vfd_hud() -> void:
	_deck_canvas = Control.new()
	_deck_canvas.name = "Kenwood_KRC990SP_Deck"
	_deck_canvas.custom_minimum_size = Vector2(DECK_WIDTH, DECK_HEIGHT)
	_deck_canvas.size = Vector2(DECK_WIDTH, DECK_HEIGHT)
	_deck_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_deck_canvas)
	
	_reposition_deck(false)
	_deck_canvas.draw.connect(_on_deck_draw)
	get_viewport().size_changed.connect(func(): _reposition_deck(false))

func _reposition_deck(animate: bool = false) -> void:
	if not is_instance_valid(_deck_canvas):
		return
	var vp_width: float = get_viewport().get_visible_rect().size.x
	var open_x: float = vp_width - DECK_WIDTH - MARGIN_RIGHT
	var closed_x: float = vp_width - 28.0 # Leave pull-tab visible on edge
	var target_x: float = open_x if is_drawer_open else closed_x
	
	if animate:
		if _drawer_slide_tween and _drawer_slide_tween.is_running():
			_drawer_slide_tween.kill()
		_drawer_slide_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_drawer_slide_tween.tween_property(_deck_canvas, "position:x", target_x, 0.28)
		_drawer_slide_tween.parallel().tween_property(_deck_canvas, "position:y", MARGIN_TOP, 0.28)
	else:
		_deck_canvas.position = Vector2(target_x, MARGIN_TOP)

# ==============================================================================
# MAIN FRAME LOOP & INPUT HANDLING
# ==============================================================================
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	
	var key_event := event as InputEventKey
	match key_event.keycode:
		KEY_M:
			is_drawer_open = not is_drawer_open
			_key_flash_timers["hide"] = 0.25
			_reposition_deck(true)
			get_viewport().set_input_as_handled()
		KEY_BRACKETLEFT:
			_key_flash_timers["prev"] = 0.25
			_tune_station((current_station_idx - 1 + stations.size()) % stations.size())
			get_viewport().set_input_as_handled()
		KEY_BRACKETRIGHT:
			_key_flash_timers["next"] = 0.25
			_tune_station((current_station_idx + 1) % stations.size())
			get_viewport().set_input_as_handled()
		KEY_MINUS:
			_key_flash_timers["v_dn"] = 0.2
			master_volume_linear = clampf(master_volume_linear - 0.08, 0.0, 1.0)
			_apply_master_volume()
			get_viewport().set_input_as_handled()
		KEY_EQUAL:
			_key_flash_timers["v_up"] = 0.2
			master_volume_linear = clampf(master_volume_linear + 0.08, 0.0, 1.0)
			_apply_master_volume()
			get_viewport().set_input_as_handled()
		KEY_F1:
			# Toggle handbook acoustic muffle state passively (do not consume event so Handbook UI opens)
			is_handbook_muffled = not is_handbook_muffled

func _process(delta: float) -> void:
	_update_cabin_acoustics(delta)
	_poll_passive_vehicle_telemetry(delta)
	
	var active_station: RadioStation = stations[current_station_idx]
	if active_station.type == EngineType.LIVE_STREAM:
		_process_live_http_stream(delta)
		# If live stream buffer runs dry or is connecting, seamlessly run Engine B synth as zero-drop carrier
		if _is_stream_fallback_active:
			_fill_procedural_synth_buffer()
	else:
		_fill_procedural_synth_buffer()
	
	_update_vfd_visuals(delta)
	_deck_canvas.queue_redraw()

# ==============================================================================
# CABIN ACOUSTICS & PASSIVE TELEMETRY
# ==============================================================================
func _update_cabin_acoustics(delta: float) -> void:
	var tree_paused: bool = get_tree().paused if get_tree() else false
	is_currently_muffled = tree_paused or is_handbook_muffled
	
	var target_cutoff: float = 520.0 if is_currently_muffled else 20500.0
	var target_res: float = 1.25 if is_currently_muffled else 0.55
	
	if _lpf_effect:
		_lpf_effect.cutoff_hz = lerpf(_lpf_effect.cutoff_hz, target_cutoff, clampf(delta * 12.0, 0.0, 1.0))
		_lpf_effect.resonance = lerpf(_lpf_effect.resonance, target_res, clampf(delta * 12.0, 0.0, 1.0))

func _poll_passive_vehicle_telemetry(delta: float) -> void:
	# Strictly read-only inspection of vehicle properties or metadata if present in tree
	_telemetry_scan_timer -= delta
	if _telemetry_scan_timer <= 0.0 and not is_instance_valid(_cached_vehicle_node):
		_telemetry_scan_timer = 2.0
		_cached_vehicle_node = _find_player_vehicle_readonly()
	
	var raw_rpm: float = -1.0
	var raw_slip: float = -1.0
	
	if is_instance_valid(_cached_vehicle_node):
		if "rpm" in _cached_vehicle_node:
			raw_rpm = float(_cached_vehicle_node.get("rpm"))
		elif "engine_rpm" in _cached_vehicle_node:
			raw_rpm = float(_cached_vehicle_node.get("engine_rpm"))
		elif _cached_vehicle_node.has_meta("rpm"):
			raw_rpm = float(_cached_vehicle_node.get_meta("rpm"))
			
		if "drift_slip" in _cached_vehicle_node:
			raw_slip = float(_cached_vehicle_node.get("drift_slip"))
		elif "tire_slip" in _cached_vehicle_node:
			raw_slip = float(_cached_vehicle_node.get("tire_slip"))
		elif "lateral_slip" in _cached_vehicle_node:
			raw_slip = float(_cached_vehicle_node.get("lateral_slip"))
	
	if raw_rpm >= 0.0:
		var norm_rpm: float = clampf((raw_rpm - 800.0) / 7700.0, 0.0, 1.0)
		_telemetry_rpm_norm = lerpf(_telemetry_rpm_norm, norm_rpm, delta * 8.0)
	else:
		# Read-only keyboard throttle estimation when standalone
		var throttle_pressed: bool = Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)
		var target_rpm: float = 0.82 if throttle_pressed else 0.18
		_telemetry_rpm_norm = lerpf(_telemetry_rpm_norm, target_rpm, delta * 2.5)
		
	if raw_slip >= 0.0:
		_telemetry_drift_slip = lerpf(_telemetry_drift_slip, clampf(raw_slip, 0.0, 1.0), delta * 10.0)
	else:
		var handbrake_or_steer: bool = Input.is_key_pressed(KEY_SPACE) or (
			(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_RIGHT))
			and _telemetry_rpm_norm > 0.45
		)
		var target_slip: float = 0.75 if handbrake_or_steer else 0.0
		_telemetry_drift_slip = lerpf(_telemetry_drift_slip, target_slip, delta * 4.0)

func _find_player_vehicle_readonly() -> Node:
	if not get_tree():
		return null
	for group_name in ["player_vehicle", "vehicle", "car", "player"]:
		var nodes := get_tree().get_nodes_in_group(group_name)
		if not nodes.is_empty():
			return nodes[0]
	return null

func _apply_master_volume() -> void:
	if _bus_idx == -1:
		return
	var db: float = linear_to_db(maxf(master_volume_linear, 0.0001))
	AudioServer.set_bus_volume_db(_bus_idx, db)
	AudioServer.set_bus_mute(_bus_idx, master_volume_linear <= 0.001)

# ==============================================================================
# STATION TUNING CONTROLLER
# ==============================================================================
func _tune_station(new_idx: int) -> void:
	current_station_idx = clampi(new_idx, 0, stations.size() - 1)
	_title_scroll_offset = 0.0
	
	# Reset buffers
	_mp3_ring_buffer.clear()
	_decoded_pcm_queue.clear()
	_pcm_read_head = 0
	if _stream_playback:
		_stream_playback.clear_buffer()
	
	var st: RadioStation = stations[current_station_idx]
	if st.type == EngineType.LIVE_STREAM:
		_is_stream_fallback_active = true
		_stream_redirect_hops = 0
		_initiate_http_stream(st.url)
	else:
		_http_client.close()
		_is_stream_fallback_active = false
		_stream_status_text = "SYNTH LOCKED"

# ==============================================================================
# ENGINE A: LIVE HTTP ICECAST / MP3 STREAMING ENGINE
# ==============================================================================
func _initiate_http_stream(url: String) -> void:
	_http_client.close()
	_stream_retry_timer = 0.0
	
	var clean_url: String = url.strip_edges()
	_stream_use_tls = clean_url.begins_with("https://")
	var without_proto: String = clean_url.replace("https://", "").replace("http://", "")
	
	var slash_pos: int = without_proto.find("/")
	var host_port: String = without_proto if slash_pos == -1 else without_proto.substr(0, slash_pos)
	_stream_path = "/" if slash_pos == -1 else without_proto.substr(slash_pos)
	
	var colon_pos: int = host_port.find(":")
	if colon_pos != -1:
		_stream_host = host_port.substr(0, colon_pos)
		_stream_port = host_port.substr(colon_pos + 1).to_int()
	else:
		_stream_host = host_port
		_stream_port = 443 if _stream_use_tls else 80
		
	var tls_opts: TLSOptions = TLSOptions.client() if _stream_use_tls else null
	var err: Error = _http_client.connect_to_host(_stream_host, _stream_port, tls_opts)
	if err == OK:
		_stream_status_text = "TUNING..."
	else:
		_stream_status_text = "NET RETRY"
		_stream_retry_timer = 3.5

func _process_live_http_stream(delta: float) -> void:
	if _stream_retry_timer > 0.0:
		_stream_retry_timer -= delta
		if _stream_retry_timer <= 0.0:
			_initiate_http_stream(stations[current_station_idx].url)
		return
		
	_http_client.poll()
	var status: HTTPClient.Status = _http_client.get_status()
	
	match status:
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING:
			_stream_status_text = "TUNING..."
			_is_stream_fallback_active = true
			
		HTTPClient.STATUS_CONNECTED:
			var headers: PackedStringArray = [
				"User-Agent: ShiTmoZ-TougeRadio/4.3",
				"Icy-MetaData: 0",
				"Accept: */*",
				"Connection: keep-alive"
			]
			var err: Error = _http_client.request(HTTPClient.METHOD_GET, _stream_path, headers)
			if err != OK:
				_schedule_stream_retry("REQ ERR")
			else:
				_stream_status_text = "BUFFERING"
				
		HTTPClient.STATUS_REQUESTING:
			_stream_status_text = "HANDSHAKE"
			
		HTTPClient.STATUS_BODY:
			var resp_code: int = _http_client.get_response_code()
			if resp_code in [301, 302, 303, 307, 308]:
				_handle_http_redirect()
				return
			elif resp_code != 200:
				_schedule_stream_retry("HTTP %d" % resp_code)
				return
				
			# Pull available chunks non-blockingly
			for _i in range(4):
				if _http_client.get_status() != HTTPClient.STATUS_BODY:
					break
				var chunk: PackedByteArray = _http_client.read_response_body_chunk()
				if chunk.is_empty():
					break
				_mp3_ring_buffer.append_array(chunk)
				
			# Prevent unbounded memory growth
			if _mp3_ring_buffer.size() > 262144:
				_mp3_ring_buffer = _mp3_ring_buffer.slice(_mp3_ring_buffer.size() - 131072)
				
			# Decode MP3 chunk batch (~24KB per batch for crisp frame lock)
			if _mp3_ring_buffer.size() >= 24576 and (_decoded_pcm_queue.size() - _pcm_read_head) < 32768:
				_decode_mp3_batch_to_pcm()
				
			_feed_stream_generator_buffer()
			
		HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			_schedule_stream_retry("SIGNAL LOST")
			
		HTTPClient.STATUS_DISCONNECTED:
			_schedule_stream_retry("RECONNECT")

func _handle_http_redirect() -> void:
	_stream_redirect_hops += 1
	if _stream_redirect_hops > 4:
		_schedule_stream_retry("MAX REDIR")
		return
	var headers: Dictionary = _http_client.get_response_headers_as_dictionary()
	for k in headers.keys():
		if String(k).to_lower() == "location":
			var new_url: String = String(headers[k])
			_initiate_http_stream(new_url)
			return
	_schedule_stream_retry("REDIR ERR")

func _schedule_stream_retry(reason: String) -> void:
	_http_client.close()
	_stream_status_text = reason + " (SYNTH)"
	_is_stream_fallback_active = true
	_stream_retry_timer = 4.0

func _decode_mp3_batch_to_pcm() -> void:
	# Find MPEG sync word (0xFF followed by 0xE0 mask)
	var sync_offset: int = -1
	var search_limit: int = mini(_mp3_ring_buffer.size() - 4, 4096)
	for i in range(search_limit):
		if _mp3_ring_buffer[i] == 0xFF and (_mp3_ring_buffer[i + 1] & 0xE0) == 0xE0:
			sync_offset = i
			break
			
	if sync_offset == -1:
		_mp3_ring_buffer.clear()
		return
		
	var batch_bytes: PackedByteArray = _mp3_ring_buffer.slice(sync_offset)
	_mp3_ring_buffer.clear()
	
	var mp3_stream := AudioStreamMP3.new()
	mp3_stream.data = batch_bytes
	var playback: AudioStreamPlayback = mp3_stream.instantiate_playback()
	if playback == null:
		return
		
	playback.start(0.0)
	var frames_decoded: PackedVector2Array = playback.mix_audio(1.0, int(MIX_RATE * 1.6))
	if frames_decoded.size() > 64:
		# Compact queue if needed
		if _pcm_read_head > 16384:
			_decoded_pcm_queue = _decoded_pcm_queue.slice(_pcm_read_head)
			_pcm_read_head = 0
		_decoded_pcm_queue.append_array(frames_decoded)

func _feed_stream_generator_buffer() -> void:
	if _stream_playback == null:
		return
	var frames_avail: int = _stream_playback.get_frames_available()
	var queued_frames: int = _decoded_pcm_queue.size() - _pcm_read_head
	
	if queued_frames > 0:
		_is_stream_fallback_active = false
		_stream_status_text = "LIVE STEREO"
		var to_push: int = mini(frames_avail, queued_frames)
		for i in range(to_push):
			_stream_playback.push_frame(_decoded_pcm_queue[_pcm_read_head + i])
		_pcm_read_head += to_push
	else:
		# Stream buffer underrun -> seamlessly engage Engine B procedural synth until HTTP catches up
		_is_stream_fallback_active = true
		if _stream_status_text == "LIVE STEREO":
			_stream_status_text = "BUFFERING"

# ==============================================================================
# ENGINE B: ZERO-DROP PROCEDURAL TOUGE SYNTHESIZER
# ==============================================================================
func _fill_procedural_synth_buffer() -> void:
	if _synth_playback == null:
		return
	var frames_to_fill: int = _synth_playback.get_frames_available()
	if frames_to_fill <= 0:
		return
		
	# Dynamic BPM scaled by Engine RPM (128 BPM at idle -> 166 BPM at redline)
	var dynamic_bpm: float = lerpf(128.0, 166.0, _telemetry_rpm_norm)
	var steps_per_sec: float = (dynamic_bpm / 60.0) * 4.0 # 16th note resolution
	var step_inc: float = steps_per_sec / MIX_RATE
	var inv_mix: float = 1.0 / MIX_RATE
	
	for _i in range(frames_to_fill):
		var prev_step: int = int(_synth_step_accumulator)
		_synth_step_accumulator += step_inc
		var cur_step: int = int(_synth_step_accumulator)
		
		if cur_step != prev_step:
			_synth_current_step = cur_step % 16
			if _synth_current_step == 0:
				_synth_bar_count += 1
			# Trigger 4-on-the-floor punchy kick on quarter notes (0, 4, 8, 12)
			if _synth_current_step % 4 == 0:
				_synth_phase_kick = 0.0
				_synth_phase_kick_env = 0.0
				
		var step_frac: float = fmod(_synth_step_accumulator, 1.0)
		
		# --- VOICE 1: PUNCHY 90s EUROBEAT KICK ---
		_synth_phase_kick_env += inv_mix * 5.5
		var kick_env: float = clampf(1.0 - _synth_phase_kick_env, 0.0, 1.0)
		kick_env = kick_env * kick_env
		var kick_freq: float = 46.0 + 145.0 * pow(kick_env, 3.0)
		_synth_phase_kick = fmod(_synth_phase_kick + kick_freq * inv_mix, 1.0)
		var kick_sig: float = sin(_synth_phase_kick * TAU) * kick_env * 0.72
		
		# --- VOICE 2: ROLLING OCTAVE SAW BASSLINE ---
		var bass_midi: int = BASS_SEQUENCE[_synth_current_step]
		# Transpose up 2 semitones every 4th bar for classic Eurobeat tension
		if (_synth_bar_count % 4) == 3:
			bass_midi += 2
		var bass_freq: float = 440.0 * pow(2.0, (float(bass_midi) - 69.0) / 12.0)
		_synth_phase_bass = fmod(_synth_phase_bass + bass_freq * inv_mix, 1.0)
		var bass_env: float = clampf(1.0 - step_frac * 0.85, 0.1, 1.0)
		# Rich saw + square sub-oscillator
		var bass_saw: float = (_synth_phase_bass * 2.0 - 1.0)
		var bass_sub: float = 1.0 if _synth_phase_bass < 0.5 else -1.0
		var bass_sig: float = (bass_saw * 0.6 + bass_sub * 0.4) * bass_env * 0.36
		
		# --- VOICE 3: DRIFT-MODULATED ARPEGGIO BRASS LEAD ---
		var lead_midi: int = LEAD_ARPEGGIO[_synth_current_step]
		if (_synth_bar_count % 4) == 3:
			lead_midi += 2
		_synth_phase_lfo = fmod(_synth_phase_lfo + (5.5 + _telemetry_drift_slip * 8.0) * inv_mix, 1.0)
		var vibrato: float = sin(_synth_phase_lfo * TAU) * (0.003 + _telemetry_drift_slip * 0.015)
		var lead_freq: float = (440.0 * pow(2.0, (float(lead_midi) - 69.0) / 12.0)) * (1.0 + vibrato)
		_synth_phase_lead = fmod(_synth_phase_lead + lead_freq * inv_mix, 1.0)
		
		var pwm_duty: float = 0.5 + 0.32 * sin(_synth_phase_lfo * TAU * 0.5)
		var lead_pulse: float = 1.0 if _synth_phase_lead < pwm_duty else -1.0
		var lead_env: float = pow(1.0 - step_frac, 1.6)
		var lead_gain: float = 0.22 + _telemetry_drift_slip * 0.18 + _telemetry_rpm_norm * 0.08
		var lead_sig: float = lead_pulse * lead_env * lead_gain
		
		# --- VOICE 4: OFF-BEAT CRISP HI-HAT & SNARE ---
		_synth_noise_seed = (_synth_noise_seed * 1664525 + 1013904223) & 0x7FFFFFFF
		var white_noise: float = (float(_synth_noise_seed) / float(0x3FFFFFFF)) - 1.0
		var hat_sig: float = 0.0
		if (_synth_current_step % 4) == 2:
			# Open off-beat hat
			hat_sig = white_noise * pow(1.0 - step_frac, 2.2) * 0.22
		elif (_synth_current_step % 2) == 1:
			# Closed 16th hat
			hat_sig = white_noise * pow(1.0 - step_frac, 6.0) * 0.10
		if _synth_current_step == 4 or _synth_current_step == 12:
			# Snare clap layer
			hat_sig += white_noise * pow(1.0 - step_frac, 2.8) * 0.28
			
		# Stereo Panning & Soft Clipper
		var center_mix: float = kick_sig + bass_sig
		var stereo_spread: float = sin(float(_synth_current_step) * 0.8) * 0.35
		var left_ch: float = tanh(center_mix + lead_sig * (1.0 - stereo_spread) + hat_sig * 0.9)
		var right_ch: float = tanh(center_mix + lead_sig * (1.0 + stereo_spread) + hat_sig * 1.1)
		
		_synth_playback.push_frame(Vector2(left_ch * 0.85, right_ch * 0.85))

# ==============================================================================
# VFD SPECTRUM & ANIMATION UPDATER
# ==============================================================================
func _update_vfd_visuals(delta: float) -> void:
	_title_scroll_offset += delta * 38.0
	_cassette_reel_angle = fmod(_cassette_reel_angle + delta * (2.2 + _telemetry_rpm_norm * 3.5), TAU)
	
	for k in _key_flash_timers.keys():
		if _key_flash_timers[k] > 0.0:
			_key_flash_timers[k] = maxf(0.0, _key_flash_timers[k] - delta)
			
	# 8-Band logarithmic frequency ranges (Hz)
	const FREQ_BANDS: Array[Vector2] = [
		Vector2(30.0, 85.0),
		Vector2(85.0, 180.0),
		Vector2(180.0, 380.0),
		Vector2(380.0, 800.0),
		Vector2(800.0, 1700.0),
		Vector2(1700.0, 3600.0),
		Vector2(3600.0, 7500.0),
		Vector2(7500.0, 15000.0)
	]
	
	for i in range(8):
		var target_energy: float = 0.0
		if _spectrum_instance != null and master_volume_linear > 0.001:
			var mag: float = _spectrum_instance.get_magnitude_for_frequency_range(FREQ_BANDS[i].x, FREQ_BANDS[i].y).length()
			target_energy = clampf((linear_to_db(mag + 0.0001) + 52.0) / 46.0, 0.0, 1.0)
			
		# Fallback synthetic reactivity if audio server reports near-zero
		if target_energy < 0.05 and master_volume_linear > 0.01:
			var beat_pulse: float = abs(sin(_synth_step_accumulator * PI * 0.5 + float(i) * 0.6))
			target_energy = clampf(beat_pulse * (0.35 + _telemetry_rpm_norm * 0.45) * master_volume_linear, 0.05, 0.95)
			
		if target_energy > _fft_peaks[i]:
			_fft_peaks[i] = lerpf(_fft_peaks[i], target_energy, clampf(delta * 26.0, 0.0, 1.0))
		else:
			_fft_peaks[i] = lerpf(_fft_peaks[i], target_energy, clampf(delta * 9.5, 0.0, 1.0))
			
		if _fft_peaks[i] >= _fft_holds[i]:
			_fft_holds[i] = _fft_peaks[i]
		else:
			_fft_holds[i] = maxf(0.0, _fft_holds[i] - delta * 0.42)

# ==============================================================================
# KENWOOD KRC-990SP VECTOR VFD RENDERER
# ==============================================================================
func _on_deck_draw() -> void:
	var font: Font = ThemeDB.fallback_font
	var c: Control = _deck_canvas
	
	# 1. Outer DIN Chassis & Brushed Faceplate Bezel
	c.draw_rect(Rect2(0, 0, DECK_WIDTH, DECK_HEIGHT), COLOR_CHASSIS_BG, true)
	c.draw_rect(Rect2(2, 2, DECK_WIDTH - 4, DECK_HEIGHT - 4), COLOR_CHASSIS_TRIM, false, 2.0)
	c.draw_rect(Rect2(5, 5, DECK_WIDTH - 10, DECK_HEIGHT - 10), Color(0.04, 0.04, 0.05, 1.0), false, 1.0)
	
	# Left Side Pull-Tab Indicator (Always visible even when tucked)
	c.draw_rect(Rect2(4, 10, 20, DECK_HEIGHT - 20), Color(0.11, 0.12, 0.14, 1.0), true)
	c.draw_string(font, Vector2(9, 45), "M", HORIZONTAL_ALIGNMENT_CENTER, -1, 11, COLOR_VFD_AMBER if _key_flash_timers["hide"] > 0.0 else COLOR_VFD_CYAN)
	c.draw_line(Vector2(14, 54), Vector2(14, 96), COLOR_VFD_AMBER_DIM, 2.0)
	var arrow_txt: String = ">" if is_drawer_open else "<"
	c.draw_string(font, Vector2(9, 112), arrow_txt, HORIZONTAL_ALIGNMENT_CENTER, -1, 11, COLOR_VFD_AMBER)
	
	# 2. Recessed VFD Glass Lens
	var vfd_rect := Rect2(28, 10, DECK_WIDTH - 38, 86)
	c.draw_rect(vfd_rect, COLOR_VFD_GLASS, true)
	c.draw_rect(vfd_rect, Color(0.22, 0.25, 0.28, 0.8), false, 1.5)
	
	# Subtle VFD Phosphor Grid Scanlines
	for y_line in range(int(vfd_rect.position.y) + 2, int(vfd_rect.end.y), 3):
		c.draw_line(Vector2(vfd_rect.position.x + 2, y_line), Vector2(vfd_rect.end.x - 2, y_line), Color(0.0, 0.14, 0.16, 0.22), 1.0)
		
	var st: RadioStation = stations[current_station_idx]
	
	# 3. Top Branding & Mode Badges inside VFD
	c.draw_string(font, Vector2(36, 24), "KENWOOD", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.85, 0.88, 0.92, 0.9))
	c.draw_string(font, Vector2(102, 23), "KRC-990SP // DSP", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, COLOR_VFD_AMBER)
	
	# Status Badges (ST, LOUD, CABIN LPF, MODE)
	_draw_vfd_badge(c, font, Rect2(204, 13, 28, 12), "ST", true, COLOR_VFD_CYAN)
	var is_synth_active: bool = (st.type == EngineType.PROCEDURAL_SYNTH) or _is_stream_fallback_active
	_draw_vfd_badge(c, font, Rect2(236, 13, 46, 12), "SYNTH" if is_synth_active else "NET-FM", true, COLOR_VFD_AMBER if is_synth_active else COLOR_VFD_CYAN)
	_draw_vfd_badge(c, font, Rect2(286, 13, 42, 12), "MUFFLE", is_currently_muffled, COLOR_VFD_RED)
	_draw_vfd_badge(c, font, Rect2(332, 13, 38, 12), "DRIFT", _telemetry_drift_slip > 0.25, COLOR_VFD_AMBER)
	
	# 4. Station Frequency Readout & Motorized Cassette Window
	c.draw_string(font, Vector2(36, 48), st.freq, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, COLOR_VFD_CYAN)
	
	var status_label: String = _stream_status_text if st.type == EngineType.LIVE_STREAM else ("RPM:%d%%" % int(_telemetry_rpm_norm * 100.0))
	c.draw_string(font, Vector2(132, 46), status_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COLOR_VFD_AMBER)
	
	# Mini Motorized Cassette Mechanism Graphic
	_draw_cassette_deck_mechanism(c, Vector2(178, 38))
	
	# 5. Scrolling Dot-Matrix Station Title Marquee
	var marquee_rect := Rect2(36, 55, 174, 18)
	c.draw_rect(marquee_rect, Color(0.01, 0.02, 0.03, 0.9), true)
	c.draw_rect(marquee_rect, COLOR_VFD_CYAN_DIM, false, 1.0)
	
	var full_marquee_str: String = "CH%d: %s   ***   " % [current_station_idx + 1, st.title]
	var char_count: int = full_marquee_str.length()
	var scroll_idx: int = int(_title_scroll_offset * 0.22) % maxi(char_count, 1)
	var doubled_str: String = full_marquee_str + full_marquee_str
	var visible_slice: String = doubled_str.substr(scroll_idx, 23)
	c.draw_string(font, Vector2(40, 68), visible_slice, HORIZONTAL_ALIGNMENT_LEFT, 166, 11, COLOR_VFD_AMBER)
	
	# 6. Volume Matrix Bar (Bottom Left of VFD)
	c.draw_string(font, Vector2(36, 88), "VOL", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COLOR_VFD_CYAN)
	var vol_segments: int = 14
	var active_vol_segs: int = roundi(master_volume_linear * float(vol_segments))
	for v_i in range(vol_segments):
		var seg_rect := Rect2(64 + v_i * 8, 79, 6, 9)
		var seg_col: Color = COLOR_VFD_CYAN_DIM
		if v_i < active_vol_segs:
			seg_col = COLOR_VFD_RED if v_i >= 11 else (COLOR_VFD_AMBER if v_i >= 8 else COLOR_VFD_CYAN)
		c.draw_rect(seg_rect, seg_col, true)
	c.draw_string(font, Vector2(180, 88), "%02d" % int(round(master_volume_linear * 30.0)), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COLOR_VFD_AMBER)
	
	# 7. 8-Band Segmented VFD Spectrum Analyzer (Right side of VFD)
	var spec_origin := Vector2(222, 31)
	var bar_w: float = 15.0
	var bar_gap: float = 4.0
	var num_segs: int = 10
	var seg_h: float = 3.5
	var seg_gap: float = 1.5
	
	for b in range(8):
		var bx: float = spec_origin.x + b * (bar_w + bar_gap)
		var active_segs: int = roundi(_fft_peaks[b] * float(num_segs))
		var hold_seg: int = clampi(roundi(_fft_holds[b] * float(num_segs)) - 1, -1, num_segs - 1)
		
		for s in range(num_segs):
			# Draw bottom-up
			var sy: float = spec_origin.y + (num_segs - 1 - s) * (seg_h + seg_gap)
			var s_rect := Rect2(bx, sy, bar_w, seg_h)
			
			if s < active_segs:
				var lit_col: Color = COLOR_VFD_CYAN
				if s >= 8:
					lit_col = COLOR_VFD_RED
				elif s >= 6:
					lit_col = COLOR_VFD_AMBER
				c.draw_rect(s_rect, lit_col, true)
			elif s == hold_seg and hold_seg > 0:
				c.draw_rect(s_rect, COLOR_VFD_AMBER, true)
			else:
				c.draw_rect(s_rect, COLOR_VFD_CYAN_DIM, true)
				
	# Frequency labels under spectrum bars
	const BAND_LABELS: Array[String] = ["60", "150", "350", "700", "1K", "3K", "6K", "12K"]
	for b in range(8):
		var bx: float = spec_origin.x + b * (bar_w + bar_gap)
		c.draw_string(font, Vector2(bx, 90), BAND_LABELS[b], HORIZONTAL_ALIGNMENT_LEFT, -1, 7, COLOR_VFD_AMBER)
		
	# 8. Bottom Tactile Hardware Key Row
	var btn_y: float = 101.0
	_draw_hardware_button(c, font, Rect2(28, btn_y, 66, 20), "[M] DRAWER", _key_flash_timers["hide"] > 0.0)
	_draw_hardware_button(c, font, Rect2(100, btn_y, 68, 20), "[ [ ] SEEK-", _key_flash_timers["prev"] > 0.0)
	_draw_hardware_button(c, font, Rect2(174, btn_y, 68, 20), "[ ] ] SEEK+", _key_flash_timers["next"] > 0.0)
	_draw_hardware_button(c, font, Rect2(248, btn_y, 62, 20), "[-] VOL-", _key_flash_timers["v_dn"] > 0.0)
	_draw_hardware_button(c, font, Rect2(316, btn_y, 62, 20), "[=] VOL+", _key_flash_timers["v_up"] > 0.0)

func _draw_vfd_badge(c: Control, font: Font, rect: Rect2, text: String, active: bool, active_col: Color) -> void:
	var bg_col: Color = Color(active_col.r * 0.22, active_col.g * 0.22, active_col.b * 0.22, 0.85) if active else COLOR_VFD_AMBER_DIM
	var border_col: Color = active_col if active else COLOR_VFD_CYAN_DIM
	var txt_col: Color = active_col if active else Color(0.2, 0.32, 0.35, 0.5)
	c.draw_rect(rect, bg_col, true)
	c.draw_rect(rect, border_col, false, 1.0)
	c.draw_string(font, Vector2(rect.position.x + 3, rect.position.y + 9), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, txt_col)

func _draw_cassette_deck_mechanism(c: Control, center: Vector2) -> void:
	# Draws animated dual-spindle cassette window inside VFD
	var box := Rect2(center.x - 18, center.y - 8, 36, 16)
	c.draw_rect(box, Color(0.01, 0.03, 0.04, 1.0), true)
	c.draw_rect(box, COLOR_VFD_AMBER_DIM, false, 1.0)
	
	for offset_x in [-9.0, 9.0]:
		var reel_pos := Vector2(center.x + offset_x, center.y)
		c.draw_arc(reel_pos, 4.5, 0.0, TAU, 12, COLOR_VFD_CYAN, 1.2)
		for spoke in range(3):
			var ang: float = _cassette_reel_angle + float(spoke) * (TAU / 3.0)
			var p2: Vector2 = reel_pos + Vector2(cos(ang), sin(ang)) * 4.5
			c.draw_line(reel_pos, p2, COLOR_VFD_AMBER, 1.2)

func _draw_hardware_button(c: Control, font: Font, rect: Rect2, label: String, is_pressed: bool) -> void:
	var bg: Color = Color(0.24, 0.16, 0.05, 1.0) if is_pressed else Color(0.12, 0.13, 0.15, 1.0)
	var rim: Color = COLOR_VFD_AMBER if is_pressed else Color(0.26, 0.28, 0.32, 1.0)
	var txt_col: Color = COLOR_VFD_AMBER if is_pressed else Color(0.78, 0.82, 0.86, 0.95)
	
	c.draw_rect(rect, bg, true)
	c.draw_rect(rect, rim, false, 1.0)
	# Subtle amber LED backlight strip on button top
	c.draw_line(Vector2(rect.position.x + 3, rect.position.y + 2), Vector2(rect.end.x - 3, rect.position.y + 2), COLOR_VFD_AMBER if is_pressed else COLOR_VFD_AMBER_DIM, 1.5)
	c.draw_string(font, Vector2(rect.position.x + 5, rect.position.y + 14), label, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 6, 9, txt_col)