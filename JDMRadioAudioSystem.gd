class_name JDMRadioAudioSystem
extends Node

## ============================================================================
## ShiTmoZ/RACING - Mount Akina Touge
## JDM FM Radio & Real-Time Procedural Music Synthesizer (Godot 4.3 Forward+)
## ============================================================================
## 100% self-contained, zero-drop procedural synthesis engine & VFD HUD.
## Replaces legacy HTTP socket MP3 decoders with sample-accurate DSP voices.
## ============================================================================

# --- Audio Engine Constants ---
const MIX_RATE: float = 44100.0
const BUFFER_LEN: float = 0.12 # 120ms buffer prevents Vulkan shader compilation stutters
const RADIO_BUS_NAME: String = "JDM_Radio_Bus"
const NUM_VFD_BANDS: int = 12
const SEGMENTS_PER_BAND: int = 14

# --- Station Definitions ---
enum StationID {
	EUROBEAT_AKINA = 0,
	NIGHTWAVE_CITYPOP = 1,
	DRIFT_PHONK = 2
}

const STATIONS: Array[Dictionary] = [
	{
		"freq": "88.6 FM",
		"name": "SUPER EUROBEAT // AKINA SPECIAL",
		"tracks": [
			"DAVE R. - RUNNING IN THE AKINA 90s",
			"MARKO P. - SPACE BOY OVERDRIVE",
			"EDO BOYS - NO ONE SLEEP IN GUNMA"
		],
		"bpm": 155.0,
		"accent_color": Color(1.0, 0.32, 0.12), # Pioneer Amber/Red
		"vfd_color": Color(0.15, 0.95, 0.88)     # Classic VFD Cyan-Green
	},
	{
		"freq": "94.2 FM",
		"name": "NIGHTWAVE VAPOR // CITY POP",
		"tracks": [
			"TATSURO M. - BAYSIDE EXPRESSWAY 1986",
			"MARIYA T. - PLASTIC TOUGE LOVE",
			"OMEGA TRIBE - MIDNIGHT SHUTO WANGAN"
		],
		"bpm": 110.0,
		"accent_color": Color(0.95, 0.25, 0.78), # Neon Magenta
		"vfd_color": Color(0.35, 0.82, 1.0)      # Ice Blue VFD
	},
	{
		"freq": "102.5 FM",
		"name": "DRIFT PHONK // TOUGE BEATS",
		"tracks": [
			"KSLV AKINA - COWBELL DORIFTO",
			"GHOSTFACE TOUGE - 86 REDLINE MURDER",
			"TOKYO PLAYA - GUTTER RUNNER VIP"
		],
		"bpm": 130.0,
		"accent_color": Color(0.65, 0.95, 0.15), # Toxic Lime
		"vfd_color": Color(1.0, 0.68, 0.12)      # Amber Gold VFD
	}
]

# --- Musical Pitch Reference (MIDI Note to Hz) ---
# Standard A4 = 440Hz, MIDI 69
func _midi_to_hz(note: float) -> float:
	return 440.0 * pow(2.0, (note - 69.0) / 12.0)

# --- Sequencer Patterns (16 Steps per Bar, 4 Bars Loop = 64 Steps) ---

# Station 0: Eurobeat (A Minor -> F Major -> G Major -> E Major / A Minor)
# Iconic "Running in the 90s / Space Boy" style high-energy brass riff
const EUROBEAT_LEAD_NOTES: Array[int] = [
	# Bar 1 (Am)
	69, 0, 72, 69, 76, 0, 74, 72, 71, 72, 74, 72, 69, 0, 64, 67,
	# Bar 2 (F)
	69, 0, 72, 69, 77, 0, 76, 74, 72, 74, 76, 72, 69, 0, 65, 67,
	# Bar 3 (G)
	71, 0, 74, 71, 79, 0, 77, 76, 74, 76, 77, 74, 71, 0, 67, 69,
	# Bar 4 (E7 -> Turnaround)
	71, 72, 71, 68, 64, 68, 71, 74, 76, 0, 79, 76, 80, 76, 74, 71
]

const EUROBEAT_BASS_ROOTS: Array[int] = [
	45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 43, 43, # Am
	41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 40, 40, # F
	43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 41, 41, # G
	40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 42, 42, 44, 44, 47, 44  # E7
]

# Station 1: Nightwave / City Pop (Fmaj7 -> Em7 -> Dm7 -> Cmaj7/G13)
const NIGHTWAVE_CHORDS: Array[Array] = [
	[65, 69, 72, 76, 79], # Fmaj9
	[64, 67, 71, 74, 79], # Em9
	[62, 65, 69, 72, 76], # Dm9
	[60, 64, 67, 71, 74]  # Cmaj9
]

const NIGHTWAVE_BASS_NOTES: Array[int] = [
	# Bar 1 (F)
	41, 0, 41, 53, 0, 41, 48, 53, 41, 0, 41, 53, 0, 48, 41, 40,
	# Bar 2 (Em)
	40, 0, 40, 52, 0, 40, 47, 52, 40, 0, 40, 52, 0, 47, 40, 39,
	# Bar 3 (Dm)
	38, 0, 38, 50, 0, 38, 45, 50, 38, 0, 38, 50, 0, 45, 38, 43,
	# Bar 4 (C / G)
	36, 0, 36, 48, 0, 36, 43, 48, 43, 0, 43, 55, 0, 50, 47, 43
]

const NIGHTWAVE_ARP_NOTES: Array[int] = [
	72, 76, 79, 84, 79, 76, 72, 69, 72, 76, 79, 84, 88, 84, 79, 76,
	71, 74, 79, 83, 79, 74, 71, 67, 71, 74, 79, 83, 86, 83, 79, 74,
	69, 72, 76, 81, 76, 72, 69, 65, 69, 72, 76, 81, 84, 81, 76, 72,
	67, 71, 74, 79, 74, 71, 67, 64, 67, 71, 74, 79, 83, 79, 74, 71
]

# Station 2: Drift Phonk (D# Minor Phrygian Cowbell Hook)
const PHONK_COWBELL_NOTES: Array[int] = [
	# Bar 1
	63, 0, 63, 66, 63, 0, 62, 0, 63, 0, 63, 68, 66, 63, 62, 63,
	# Bar 2
	63, 0, 63, 66, 63, 0, 62, 0, 70, 0, 68, 0, 66, 63, 62, 58,
	# Bar 3
	63, 0, 63, 66, 63, 0, 62, 0, 63, 0, 63, 68, 66, 63, 62, 63,
	# Bar 4
	75, 0, 75, 74, 0, 70, 68, 66, 63, 63, 62, 62, 58, 0, 62, 0
]

const PHONK_808_NOTES: Array[int] = [
	39, 39, 39, 39, 39, 39, 38, 38, 39, 39, 39, 44, 42, 39, 38, 39,
	39, 39, 39, 39, 39, 39, 38, 38, 46, 46, 44, 44, 42, 39, 38, 34,
	39, 39, 39, 39, 39, 39, 38, 38, 39, 39, 39, 44, 42, 39, 38, 39,
	39, 39, 39, 38, 38, 34, 34, 34, 39, 39, 38, 38, 34, 34, 38, 38
]

# --- Audio Nodes & DSP References ---
var _player: AudioStreamPlayer
var _generator: AudioStreamGenerator
var _playback: AudioStreamGeneratorPlayback
var _spectrum_analyzer: AudioEffectSpectrumAnalyzerInstance
var _bus_idx: int = -1

# --- Radio State ---
var current_station: int = StationID.EUROBEAT_AKINA
var current_track_idx: int = 0
var radio_powered: bool = true
var master_volume_db: float = -3.0 # Default comfortable loud level
var _tuning_static_timer: float = 0.0 # FM white noise burst when switching stations
var _track_cycle_timer: float = 0.0

# --- Real-Time Synthesizer State ---
var _sample_clock: int = 0
var _step_phase: float = 0.0
var _current_step: int = -1

# Drum Envelopes & Phases
var _kick_env: float = 0.0
var _kick_pitch_env: float = 0.0
var _kick_phase: float = 0.0

var _snare_env: float = 0.0
var _snare_tone_phase: float = 0.0

var _hat_env: float = 0.0
var _hat_decay_rate: float = 18.0

# Bass Voice
var _bass_env: float = 0.0
var _bass_freq: float = 55.0
var _bass_phase1: float = 0.0
var _bass_phase2: float = 0.0
var _bass_lp_state: float = 0.0

# Lead / Cowbell / Arp Voice
var _lead_env: float = 0.0
var _lead_freq: float = 440.0
var _lead_target_freq: float = 440.0
var _lead_phases: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])

# Pad / Chord Voices (5-voice polyphonic for Nightwave / Eurobeat backing)
var _pad_phases: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
var _pad_freqs: PackedFloat64Array = PackedFloat64Array([261.63, 329.63, 392.0, 493.88, 587.33])

# Stereo Delay Ring Buffer (Simple 250ms ping-pong echo for space)
var _delay_buf_l: PackedFloat32Array = PackedFloat32Array()
var _delay_buf_r: PackedFloat32Array = PackedFloat32Array()
var _delay_write_pos: int = 0
var _delay_samples: int = 11025 # 250ms at 44.1kHz

# PRNG for fast deterministic noise (Snare, Hats, FM Static)
var _lfsr_seed: int = 0xACE1

# --- VFD Spectrum Visualizer State ---
var _vfd_bands: PackedFloat32Array = PackedFloat32Array()
var _vfd_peaks: PackedFloat32Array = PackedFloat32Array()
var _vfd_peak_hold_timers: PackedFloat32Array = PackedFloat32Array()
var _ui_canvas: CanvasLayer
var _vfd_control: Control
var _marquee_offset: float = 0.0


## ============================================================================
## LIFECYCLE & INITIALIZATION
## ============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_init_dsp_arrays()
	_setup_audio_bus()
	_setup_audio_player()
	_setup_vfd_ui()
	_apply_station_settings(current_station, false)


func _init_dsp_arrays() -> void:
	_delay_buf_l.resize(_delay_samples)
	_delay_buf_l.fill(0.0)
	_delay_buf_r.resize(_delay_samples)
	_delay_buf_r.fill(0.0)
	
	_vfd_bands.resize(NUM_VFD_BANDS)
	_vfd_bands.fill(0.0)
	_vfd_peaks.resize(NUM_VFD_BANDS)
	_vfd_peaks.fill(0.0)
	_vfd_peak_hold_timers.resize(NUM_VFD_BANDS)
	_vfd_peak_hold_timers.fill(0.0)


func _setup_audio_bus() -> void:
	_bus_idx = AudioServer.get_bus_index(RADIO_BUS_NAME)
	if _bus_idx == -1:
		_bus_idx = AudioServer.bus_count
		AudioServer.add_bus(_bus_idx)
		AudioServer.set_bus_name(_bus_idx, RADIO_BUS_NAME)
		AudioServer.set_bus_send(_bus_idx, "Master")
	
	# Clear any stale effects and attach Spectrum Analyzer + Gentle Compressor
	for i in range(AudioServer.get_bus_effect_count(_bus_idx) - 1, -1, -1):
		AudioServer.remove_bus_effect(_bus_idx, i)
	
	var spectrum_fx := AudioEffectSpectrumAnalyzer.new()
	spectrum_fx.buffer_length = 0.1
	spectrum_fx.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
	AudioServer.add_bus_effect(_bus_idx, spectrum_fx, 0)
	
	_spectrum_analyzer = AudioServer.get_bus_effect_instance(_bus_idx, 0) as AudioEffectSpectrumAnalyzerInstance
	AudioServer.set_bus_volume_db(_bus_idx, master_volume_db)


func _setup_audio_player() -> void:
	_generator = AudioStreamGenerator.new()
	_generator.mix_rate = MIX_RATE
	_generator.buffer_length = BUFFER_LEN
	
	_player = AudioStreamPlayer.new()
	_player.name = "JDMGeneratorPlayer"
	_player.stream = _generator
	_player.bus = RADIO_BUS_NAME
	add_child(_player)
	
	_player.play()
	_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback


## ============================================================================
## INPUT HANDLING (Hotkeys: M, N, B, Vol Up/Down)
## ============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	
	var key_event := event as InputEventKey
	match key_event.keycode:
		KEY_M:
			toggle_radio_power()
		KEY_N:
			next_station()
		KEY_B:
			prev_station()
		KEY_PAGEUP, KEY_BRACKETRIGHT, KEY_EQUAL:
			adjust_volume(2.0)
		KEY_PAGEDOWN, KEY_BRACKETLEFT, KEY_MINUS:
			adjust_volume(-2.0)
		KEY_UP:
			# Allow Shift+Up or Alt+Up if player uses Arrow Up for throttle, or direct Up if unmapped
			if key_event.shift_pressed or key_event.alt_pressed or not InputMap.has_action("ui_up"):
				adjust_volume(2.0)
		KEY_DOWN:
			if key_event.shift_pressed or key_event.alt_pressed or not InputMap.has_action("ui_down"):
				adjust_volume(-2.0)


func toggle_radio_power() -> void:
	radio_powered = not radio_powered
	if _bus_idx != -1:
		AudioServer.set_bus_mute(_bus_idx, not radio_powered)
	if radio_powered:
		_tuning_static_timer = 0.12
	_vfd_control.queue_redraw()


func next_station() -> void:
	if not radio_powered:
		radio_powered = true
		AudioServer.set_bus_mute(_bus_idx, false)
	current_station = (current_station + 1) % STATIONS.size()
	_apply_station_settings(current_station, true)


func prev_station() -> void:
	if not radio_powered:
		radio_powered = true
		AudioServer.set_bus_mute(_bus_idx, false)
	current_station = (current_station - 1 + STATIONS.size()) % STATIONS.size()
	_apply_station_settings(current_station, true)


func adjust_volume(delta_db: float) -> void:
	master_volume_db = clampf(master_volume_db + delta_db, -36.0, 6.0)
	if _bus_idx != -1:
		AudioServer.set_bus_volume_db(_bus_idx, master_volume_db)
	_vfd_control.queue_redraw()


func _apply_station_settings(station_idx: int, play_tuning_burst: bool) -> void:
	current_track_idx = randi() % (STATIONS[station_idx]["tracks"] as Array).size()
	_track_cycle_timer = 0.0
	if play_tuning_burst:
		_tuning_static_timer = 0.18 # Classic FM radio dial static sweep
	
	# Reset delay buffer to avoid cross-station echo bleed
	_delay_buf_l.fill(0.0)
	_delay_buf_r.fill(0.0)
	_vfd_control.queue_redraw()


## ============================================================================
## MAIN PROCESS & AUDIO BUFFER FILLING
## ============================================================================

func _process(delta: float) -> void:
	if not _player.playing:
		_player.play()
		_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback
	
	if radio_powered and _playback != null:
		_fill_audio_buffer()
	
	if _tuning_static_timer > 0.0:
		_tuning_static_timer = maxf(0.0, _tuning_static_timer - delta)
	
	# Rotate track display title every 45 seconds for variety
	_track_cycle_timer += delta
	if _track_cycle_timer > 45.0:
		_track_cycle_timer = 0.0
		var tracks: Array = STATIONS[current_station]["tracks"]
		current_track_idx = (current_track_idx + 1) % tracks.size()
	
	_update_vfd_spectrum(delta)
	_marquee_offset += delta * 38.0
	_vfd_control.queue_redraw()


func _fill_audio_buffer() -> void:
	var frames_available: int = _playback.get_frames_available()
	if frames_available <= 0:
		return
	
	var station_data: Dictionary = STATIONS[current_station]
	var bpm: float = station_data["bpm"]
	# 16th note steps per second = (BPM / 60.0) * 4.0
	var steps_per_sec: float = (bpm / 60.0) * 4.0
	var step_inc: float = steps_per_sec / MIX_RATE
	var inv_mix_rate: float = 1.0 / MIX_RATE
	
	var out_frames := PackedVector2Array()
	out_frames.resize(frames_available)
	
	for i in range(frames_available):
		_step_phase += step_inc
		var step_index: int = int(_step_phase) % 64
		if step_index != _current_step:
			_current_step = step_index
			_trigger_sequencer_step(_current_step, current_station)
		
		var frame_stereo: Vector2
		match current_station:
			StationID.EUROBEAT_AKINA:
				frame_stereo = _synth_step_eurobeat(inv_mix_rate)
			StationID.NIGHTWAVE_CITYPOP:
				frame_stereo = _synth_step_nightwave(inv_mix_rate)
			StationID.DRIFT_PHONK:
				frame_stereo = _synth_step_phonk(inv_mix_rate)
			_:
				frame_stereo = Vector2.ZERO
		
		# Overlay FM tuning static burst if switching stations
		if _tuning_static_timer > 0.0:
			var noise: float = _fast_white_noise() * 0.35
			var sweep: float = sin(float(_sample_clock) * 0.04) * 0.15
			var static_mix: float = clampf(_tuning_static_timer / 0.18, 0.0, 1.0)
			frame_stereo = frame_stereo.lerp(Vector2(noise + sweep, noise - sweep), static_mix * 0.85)
		
		# Master stereo soft-clipper (analog tape saturation)
		frame_stereo.x = tanh(frame_stereo.x * 1.15) * 0.88
		frame_stereo.y = tanh(frame_stereo.y * 1.15) * 0.88
		
		out_frames[i] = frame_stereo
		_sample_clock += 1
	
	_playback.push_buffer(out_frames)


## ============================================================================
## SEQUENCER STEP TRIGGERING (16-Step * 4 Bars = 64 Steps)
## ============================================================================

func _trigger_sequencer_step(step: int, station: int) -> void:
	var step_16: int = step % 16
	var bar_idx: int = (step / 16) % 4
	
	match station:
		StationID.EUROBEAT_AKINA:
			# 4-on-the-floor driving kick (Steps 0, 4, 8, 12) + turnaround fill
			if step_16 % 4 == 0 or (bar_idx == 3 and step_16 == 14):
				_kick_env = 1.0
				_kick_pitch_env = 1.0
				_kick_phase = 0.0
			
			# Snappy 90s Eurobeat snare on 4 and 12 + end-of-phrase roll
			if step_16 == 4 or step_16 == 12 or (bar_idx == 3 and step_16 >= 13):
				_snare_env = 1.0
				_snare_tone_phase = 0.0
			
			# Off-beat open hi-hat (2, 6, 10, 14), closed hi-hat on others
			_hat_env = 0.85 if (step_16 % 4 == 2) else 0.42
			_hat_decay_rate = 11.0 if (step_16 % 4 == 2) else 34.0
			
			# Rolling 16th-note Octave Jumping Bassline
			var root_midi: int = EUROBEAT_BASS_ROOTS[step]
			var octave_jump: int = 12 if (step_16 % 2 == 1) else 0
			_bass_freq = _midi_to_hz(float(root_midi + octave_jump))
			_bass_env = 1.0
			
			# Iconic Eurobeat Brass Lead
			var lead_note: int = EUROBEAT_LEAD_NOTES[step]
			if lead_note > 0:
				_lead_target_freq = _midi_to_hz(float(lead_note))
				if _lead_env < 0.2:
					_lead_freq = _lead_target_freq
				_lead_env = 1.0
			
		StationID.NIGHTWAVE_CITYPOP:
			# Punchy 80s LinnDrum Kick on 0, 6, 8
			if step_16 == 0 or step_16 == 6 or step_16 == 8:
				_kick_env = 1.0
				_kick_pitch_env = 1.0
				_kick_phase = 0.0
			
			# Gated Reverb 80s Snare on 4 and 12
			if step_16 == 4 or step_16 == 12:
				_snare_env = 1.0
				_snare_tone_phase = 0.0
			
			# Crisp 16th shaker/hats
			_hat_env = 0.65 if (step_16 % 4 == 2) else 0.30
			_hat_decay_rate = 18.0 if (step_16 % 4 == 2) else 42.0
			
			# Update Lush 5-Voice Juno-106 Pad Chord every bar
			var chord: Array = NIGHTWAVE_CHORDS[bar_idx]
			for c_idx in range(5):
				_pad_freqs[c_idx] = _midi_to_hz(float(chord[c_idx]))
			
			# Syncopated Slap Synth Bass
			var nw_bass: int = NIGHTWAVE_BASS_NOTES[step]
			if nw_bass > 0:
				_bass_freq = _midi_to_hz(float(nw_bass))
				_bass_env = 1.0
			
			# Dreamy Pluck Arpeggio
			var arp_note: int = NIGHTWAVE_ARP_NOTES[step]
			if arp_note > 0:
				_lead_target_freq = _midi_to_hz(float(arp_note))
				_lead_freq = _lead_target_freq
				_lead_env = 0.85
				
		StationID.DRIFT_PHONK:
			# Hard-hitting Memphis Phonk Kick pattern
			if step_16 == 0 or step_16 == 3 or step_16 == 6 or step_16 == 10 or (bar_idx == 3 and step_16 == 14):
				_kick_env = 1.0
				_kick_pitch_env = 1.0
				_kick_phase = 0.0
			
			# Trap/Phonk Snare on 4 and 12
			if step_16 == 4 or step_16 == 12:
				_snare_env = 1.0
				_snare_tone_phase = 0.0
			
			# Fast trap hi-hat rolls on steps 11, 13, 14, 15
			_hat_env = 0.75 if (step_16 % 2 == 0 or step_16 >= 13) else 0.45
			_hat_decay_rate = 38.0
			
			# Distorted 808 Sub Bass
			var sub_note: int = PHONK_808_NOTES[step]
			if sub_note > 0 and (step_16 == 0 or step_16 == 3 or step_16 == 6 or step_16 == 8 or step_16 == 11 or step_16 == 14):
				_bass_freq = _midi_to_hz(float(sub_note))
				_bass_env = 1.0
			
			# Iconic Roland TR-808 Cowbell Melody
			var cb_note: int = PHONK_COWBELL_NOTES[step]
			if cb_note > 0:
				_lead_target_freq = _midi_to_hz(float(cb_note))
				_lead_freq = _lead_target_freq
				_lead_env = 1.0


## ============================================================================
## STATION DSP SYNTHESIZER ENGINES
## ============================================================================

# --- Station 0: 155 BPM High-Octane Eurobeat ---
func _synth_step_eurobeat(dt: float) -> Vector2:
	# 1. Kick Drum (Punchy 909-style pitch drop)
	var kick_sample: float = 0.0
	if _kick_env > 0.001:
		var k_freq: float = 48.0 + (_kick_pitch_env * _kick_pitch_env) * 145.0
		_kick_phase = fposmod(_kick_phase + k_freq * dt, 1.0)
		kick_sample = sin(_kick_phase * TAU) * _kick_env * 0.95
		_kick_env = maxf(0.0, _kick_env - dt * 6.8)
		_kick_pitch_env = maxf(0.0, _kick_pitch_env - dt * 28.0)
	
	# 2. Snare Drum (Body + Crispy White Noise)
	var snare_sample: float = 0.0
	if _snare_env > 0.001:
		_snare_tone_phase = fposmod(_snare_tone_phase + 185.0 * dt, 1.0)
		var body: float = sin(_snare_tone_phase * TAU) * _snare_env * 0.45
		var noise: float = _fast_white_noise() * (_snare_env * _snare_env) * 0.70
		snare_sample = body + noise
		_snare_env = maxf(0.0, _snare_env - dt * 8.5)
	
	# 3. Hi-Hats (High-passed metallic noise)
	var hat_sample: float = 0.0
	if _hat_env > 0.001:
		var raw_noise: float = _fast_white_noise()
		hat_sample = (raw_noise - _bass_lp_state * 0.2) * _hat_env * 0.28
		_hat_env = maxf(0.0, _hat_env - dt * _hat_decay_rate)
	
	# 4. Rolling Octave Eurobeat Bass (Dual Detuned Saw + Lowpass Filter)
	var bass_sample: float = 0.0
	if _bass_env > 0.001:
		_bass_phase1 = fposmod(_bass_phase1 + _bass_freq * dt, 1.0)
		_bass_phase2 = fposmod(_bass_phase2 + (_bass_freq * 1.006) * dt, 1.0)
		var saw1: float = (_bass_phase1 * 2.0) - 1.0
		var saw2: float = (_bass_phase2 * 2.0) - 1.0
		var raw_bass: float = (saw1 + saw2) * 0.5
		# Resonant envelope filter approximation
		var cutoff: float = clampf(0.14 + _bass_env * 0.45, 0.05, 0.75)
		_bass_lp_state += cutoff * (raw_bass - _bass_lp_state)
		bass_sample = tanh(_bass_lp_state * 1.8) * _bass_env * 0.52
		_bass_env = maxf(0.0, _bass_env - dt * 9.5)
	
	# 5. Unison 5-Voice Detuned Supersaw Brass Lead (Stereo Spread)
	var lead_l: float = 0.0
	var lead_r: float = 0.0
	if _lead_env > 0.001:
		# Smooth portamento glide
		_lead_freq = lerpf(_lead_freq, _lead_target_freq, dt * 45.0)
		var detunes: Array[float] = [0.988, 0.995, 1.0, 1.005, 1.012]
		var pans_l: Array[float] = [0.9, 0.7, 0.5, 0.3, 0.1]
		for v in range(5):
			var p: float = fposmod(_lead_phases[v] + (_lead_freq * detunes[v]) * dt, 1.0)
			_lead_phases[v] = p
			var osc: float = (p * 2.0) - 1.0
			lead_l += osc * pans_l[v]
			lead_r += osc * (1.0 - pans_l[v])
		
		var env_shape: float = _lead_env * 0.18
		lead_l *= env_shape
		lead_r *= env_shape
		_lead_env = maxf(0.0, _lead_env - dt * 3.8)
	
	# Stereo Echo on Lead
	var echoed: Vector2 = _process_stereo_delay(lead_l, lead_r, 0.32)
	var center_mono: float = kick_sample + snare_sample + bass_sample
	return Vector2(
		center_mono + echoed.x + hat_sample * 0.8,
		center_mono + echoed.y + hat_sample * 1.2
	)


# --- Station 1: 110 BPM Nightwave / 80s City Pop ---
func _synth_step_nightwave(dt: float) -> Vector2:
	# 1. Warm 80s Kick
	var kick_sample: float = 0.0
	if _kick_env > 0.001:
		var k_freq: float = 44.0 + (_kick_pitch_env * _kick_pitch_env) * 110.0
		_kick_phase = fposmod(_kick_phase + k_freq * dt, 1.0)
		kick_sample = sin(_kick_phase * TAU) * _kick_env * 0.88
		_kick_env = maxf(0.0, _kick_env - dt * 5.5)
		_kick_pitch_env = maxf(0.0, _kick_pitch_env - dt * 24.0)
	
	# 2. Gated Reverb 80s Snare
	var snare_sample: float = 0.0
	if _snare_env > 0.001:
		_snare_tone_phase = fposmod(_snare_tone_phase + 165.0 * dt, 1.0)
		var body: float = sin(_snare_tone_phase * TAU) * _snare_env * 0.4
		# Gated envelope stays loud then drops sharply
		var gate_env: float = 1.0 if _snare_env > 0.35 else (_snare_env / 0.35)
		var noise: float = _fast_white_noise() * gate_env * 0.45
		snare_sample = body + noise
		_snare_env = maxf(0.0, _snare_env - dt * 4.2)
	
	# 3. Crisp Hats
	var hat_sample: float = 0.0
	if _hat_env > 0.001:
		hat_sample = _fast_white_noise() * _hat_env * 0.20
		_hat_env = maxf(0.0, _hat_env - dt * _hat_decay_rate)
	
	# 4. Lush 5-Voice Chorus Juno Pad (Sidechained by Kick)
	var pad_l: float = 0.0
	var pad_r: float = 0.0
	var sidechain: float = 1.0 - (_kick_env * 0.65)
	var lfo: float = sin(float(_sample_clock) * dt * 2.5) * 0.003
	for c in range(5):
		var freq: float = _pad_freqs[c] * (1.0 + lfo * float(c - 2))
		var p: float = fposmod(_pad_phases[c] + freq * dt, 1.0)
		_pad_phases[c] = p
		# Warm triangle + pulse blend
		var tri: float = 1.0 - 4.0 * absf(p - 0.5)
		var pulse: float = 1.0 if p < 0.35 else -1.0
		var voice: float = (tri * 0.7 + pulse * 0.3) * 0.075 * sidechain
		if c % 2 == 0:
			pad_l += voice * 1.2
			pad_r += voice * 0.6
		else:
			pad_l += voice * 0.6
			pad_r += voice * 1.2
	
	# 5. FM Slap Synth Bass
	var bass_sample: float = 0.0
	if _bass_env > 0.001:
		_bass_phase1 = fposmod(_bass_phase1 + _bass_freq * dt, 1.0)
		_bass_phase2 = fposmod(_bass_phase2 + (_bass_freq * 2.0) * dt, 1.0)
		var mod_index: float = _bass_env * _bass_env * 2.4
		var fm_mod: float = sin(_bass_phase2 * TAU) * mod_index
		bass_sample = sin(_bass_phase1 * TAU + fm_mod) * _bass_env * 0.52
		_bass_env = maxf(0.0, _bass_env - dt * 7.5)
	
	# 6. Crystal Bell Arpeggio
	var arp_l: float = 0.0
	var arp_r: float = 0.0
	if _lead_env > 0.001:
		var p0: float = fposmod(_lead_phases[0] + _lead_freq * dt, 1.0)
		var p1: float = fposmod(_lead_phases[1] + (_lead_freq * 3.0) * dt, 1.0)
		_lead_phases[0] = p0
		_lead_phases[1] = p1
		var bell: float = sin(p0 * TAU + sin(p1 * TAU) * _lead_env * 1.2) * _lead_env * 0.20
		arp_l = bell * 0.7
		arp_r = bell * 1.0
		_lead_env = maxf(0.0, _lead_env - dt * 6.5)
	
	var echoed_arp: Vector2 = _process_stereo_delay(arp_l + pad_l, arp_r + pad_r, 0.42)
	var mono_core: float = kick_sample + snare_sample + bass_sample
	return Vector2(
		mono_core + echoed_arp.x + hat_sample * 0.9,
		mono_core + echoed_arp.y + hat_sample * 0.7
	)


# --- Station 2: 130 BPM Drift Phonk (808 Cowbell & Distorted Sub) ---
func _synth_step_phonk(dt: float) -> Vector2:
	# 1. Hard-Clipping Phonk Kick
	var kick_sample: float = 0.0
	if _kick_env > 0.001:
		var k_freq: float = 52.0 + (_kick_pitch_env * _kick_pitch_env) * 170.0
		_kick_phase = fposmod(_kick_phase + k_freq * dt, 1.0)
		kick_sample = tanh(sin(_kick_phase * TAU) * 2.2) * _kick_env * 0.92
		_kick_env = maxf(0.0, _kick_env - dt * 7.5)
		_kick_pitch_env = maxf(0.0, _kick_pitch_env - dt * 32.0)
	
	# 2. Crispy Memphis Snare / Clap
	var snare_sample: float = 0.0
	if _snare_env > 0.001:
		_snare_tone_phase = fposmod(_snare_tone_phase + 210.0 * dt, 1.0)
		var body: float = sin(_snare_tone_phase * TAU) * _snare_env * 0.5
		var noise: float = _fast_white_noise() * _snare_env * 0.75
		snare_sample = tanh((body + noise) * 1.6) * 0.75
		_snare_env = maxf(0.0, _snare_env - dt * 9.0)
	
	# 3. Trap Metallic Hi-Hat
	var hat_sample: float = 0.0
	if _hat_env > 0.001:
		hat_sample = _fast_white_noise() * _hat_env * 0.26
		_hat_env = maxf(0.0, _hat_env - dt * _hat_decay_rate)
	
	# 4. Saturated 808 Sub-Bass (With Upper Harmonics for Small Speakers)
	var bass_sample: float = 0.0
	if _bass_env > 0.001:
		_bass_phase1 = fposmod(_bass_phase1 + _bass_freq * dt, 1.0)
		var sub_raw: float = sin(_bass_phase1 * TAU) + sin(_bass_phase1 * TAU * 2.0) * 0.35
		# Heavy diode-style saturation
		var sidechain: float = 1.0 - (_kick_env * 0.5)
		bass_sample = tanh(sub_raw * 2.6) * _bass_env * sidechain * 0.62
		_bass_env = maxf(0.0, _bass_env - dt * 3.2)
	
	# 5. Authentic Roland TR-808 Dual-Oscillator Bandpass Cowbell
	var cowbell_l: float = 0.0
	var cowbell_r: float = 0.0
	if _lead_env > 0.001:
		# Classic 808 Cowbell uses two square waves at ratio 1.0 and 1.48148 (540Hz & 800Hz)
		var f1: float = _lead_freq
		var f2: float = _lead_freq * 1.48148
		var p0: float = fposmod(_lead_phases[0] + f1 * dt, 1.0)
		var p1: float = fposmod(_lead_phases[1] + f2 * dt, 1.0)
		_lead_phases[0] = p0
		_lead_phases[1] = p1
		var sq1: float = 1.0 if p0 < 0.5 else -1.0
		var sq2: float = 1.0 if p1 < 0.5 else -1.0
		var cb_raw: float = (sq1 + sq2) * 0.5
		var cb_sat: float = tanh(cb_raw * 1.8) * (_lead_env * _lead_env) * 0.34
		cowbell_l = cb_sat * 0.95
		cowbell_r = cb_sat * 0.80
		_lead_env = maxf(0.0, _lead_env - dt * 5.8)
	
	var echoed_cb: Vector2 = _process_stereo_delay(cowbell_l, cowbell_r, 0.25)
	var mono_core: float = kick_sample + snare_sample + bass_sample
	return Vector2(
		mono_core + echoed_cb.x + hat_sample * 1.1,
		mono_core + echoed_cb.y + hat_sample * 0.85
	)


# --- Utility DSP Helpers ---
func _process_stereo_delay(in_l: float, in_r: float, wet: float) -> Vector2:
	var read_l: float = _delay_buf_l[_delay_write_pos]
	var read_r: float = _delay_buf_r[_delay_write_pos]
	
	# Ping-pong cross-feedback
	_delay_buf_l[_delay_write_pos] = in_l + read_r * 0.36
	_delay_buf_r[_delay_write_pos] = in_r + read_l * 0.36
	_delay_write_pos = (_delay_write_pos + 1) % _delay_samples
	
	return Vector2(in_l + read_l * wet, in_r + read_r * wet)


func _fast_white_noise() -> float:
	# Deterministic Xorshift PRNG for zero-overhead audio thread safety
	_lfsr_seed ^= (_lfsr_seed << 13) & 0xFFFFFFFF
	_lfsr_seed ^= (_lfsr_seed >> 17) & 0xFFFFFFFF
	_lfsr_seed ^= (_lfsr_seed << 5) & 0xFFFFFFFF
	return (float(_lfsr_seed & 0xFFFF) / 32768.0) - 1.0


## ============================================================================
## REAL-TIME 12-BAND VFD SPECTRUM ANALYZER
## ============================================================================

const FREQ_RANGES: Array[Vector2] = [
	Vector2(20.0, 60.0),     # Band 0: Sub Kick / 808
	Vector2(60.0, 110.0),    # Band 1: Kick Thump
	Vector2(110.0, 180.0),   # Band 2: Bass Fundamental
	Vector2(180.0, 300.0),   # Band 3: Snare Body / Warmth
	Vector2(300.0, 500.0),   # Band 4: Low Mids
	Vector2(500.0, 800.0),   # Band 5: Cowbell / Lead Root
	Vector2(800.0, 1300.0),  # Band 6: Supersaw Center
	Vector2(1300.0, 2200.0), # Band 7: Upper Mids / Bite
	Vector2(2200.0, 3600.0), # Band 8: Presence
	Vector2(3600.0, 6000.0), # Band 9: Snare Wire / Synth Fizz
	Vector2(6000.0, 10000.0),# Band 10: Hi-Hat Sizzle
	Vector2(10000.0, 16000.0)# Band 11: Air
]

func _update_vfd_spectrum(delta: float) -> void:
	var vol_scale: float = db_to_linear(master_volume_db)
	
	for b in range(NUM_VFD_BANDS):
		var target_energy: float = 0.0
		
		if radio_powered:
			# Primary source: Real FFT Spectrum Analyzer on JDM_Radio_Bus
			if _spectrum_analyzer != null:
				var range_hz: Vector2 = FREQ_RANGES[b]
				var mag: Vector2 = _spectrum_analyzer.get_magnitude_for_frequency_range(
					range_hz.x, range_hz.y, AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_MAX
				)
				var raw_amp: float = (mag.x + mag.y) * 0.5
				# Convert linear FFT amplitude to perceptual dB range (-52dB to -6dB)
				var db_val: float = linear_to_db(maxf(raw_amp, 0.0001))
				target_energy = clampf(remap(db_val, -52.0, -6.0, 0.0, 1.0), 0.0, 1.0)
			
			# Secondary DSP envelope reinforcement guarantees ultra-snappy visual sync
			var env_boost: float = 0.0
			match b:
				0, 1:
					env_boost = _kick_env * 0.85 + _bass_env * 0.45
				2, 3:
					env_boost = _bass_env * 0.80 + _snare_env * 0.35
				4, 5, 6, 7:
					env_boost = _lead_env * 0.78 + _snare_env * 0.40
				8, 9, 10, 11:
					env_boost = _hat_env * 0.75 + _snare_env * 0.55 + _lead_env * 0.30
			
			target_energy = clampf(maxf(target_energy, env_boost * vol_scale), 0.0, 1.0)
		
		# Smooth attack, classic VFD phosphor decay
		if target_energy > _vfd_bands[b]:
			_vfd_bands[b] = lerpf(_vfd_bands[b], target_energy, minf(1.0, delta * 36.0))
		else:
			_vfd_bands[b] = maxf(0.0, _vfd_bands[b] - delta * 2.4)
		
		# Floating peak-hold cap per band
		if _vfd_bands[b] >= _vfd_peaks[b]:
			_vfd_peaks[b] = _vfd_bands[b]
			_vfd_peak_hold_timers[b] = 0.32
		else:
			if _vfd_peak_hold_timers[b] > 0.0:
				_vfd_peak_hold_timers[b] -= delta
			else:
				_vfd_peaks[b] = maxf(0.0, _vfd_peaks[b] - delta * 0.95)


## ============================================================================
## RETRO KENWOOD / PIONEER VFD FACEPLATE UI (Top-Right Corner)
## ============================================================================

func _setup_vfd_ui() -> void:
	_ui_canvas = CanvasLayer.new()
	_ui_canvas.name = "JDMRadioHUDLayer"
	_ui_canvas.layer = 95
	add_child(_ui_canvas)
	
	_vfd_control = JDMVFDDisplayControl.new(self)
	_vfd_control.name = "KenwoodVFDFaceplate"
	_vfd_control.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_vfd_control.offset_left = -356.0
	_vfd_control.offset_top = 16.0
	_vfd_control.offset_right = -16.0
	_vfd_control.offset_bottom = 164.0
	_vfd_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_canvas.add_child(_vfd_control)


## Inner Class for Zero-Dependency Custom VFD Drawing
class JDMVFDDisplayControl extends Control:
	var radio: JDMRadioAudioSystem
	
	func _init(p_radio: JDMRadioAudioSystem) -> void:
		radio = p_radio
	
	func _draw() -> void:
		if radio == null:
			return
		
		var rect := Rect2(Vector2.ZERO, size)
		var st_data: Dictionary = JDMRadioAudioSystem.STATIONS[radio.current_station]
		var powered: bool = radio.radio_powered
		var accent_col: Color = st_data["accent_color"] if powered else Color(0.28, 0.28, 0.30)
		var vfd_col: Color = st_data["vfd_color"] if powered else Color(0.18, 0.22, 0.22)
		var font: Font = ThemeDB.fallback_font
		
		# 1. Outer Din-Slot Brushed Plastic Chassis
		draw_rect(rect, Color(0.06, 0.065, 0.075, 0.94), true)
		draw_rect(rect, Color(0.22, 0.24, 0.28, 1.0), false, 2.0)
		
		# Inner Recessed VFD Glass Screen
		var screen_rect := Rect2(8.0, 8.0, size.x - 16.0, size.y - 30.0)
		draw_rect(screen_rect, Color(0.02, 0.03, 0.035, 0.98), true)
		draw_rect(screen_rect, accent_col.darkened(0.35), false, 1.5)
		
		# Subtle VFD scanline grid background
		for y_line in range(int(screen_rect.position.y) + 2, int(screen_rect.end.y), 3):
			draw_line(
				Vector2(screen_rect.position.x + 2, y_line),
				Vector2(screen_rect.end.x - 2, y_line),
				Color(0.0, 0.0, 0.0, 0.35), 1.0
			)
		
		# 2. Top Header Bar: Brand Badge, Stereo Indicator & Frequency
		draw_string(
			font, Vector2(16.0, 25.0),
			"KENWOOD // KRC-86 TOUGE DSP",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.65, 0.70, 0.75)
		)
		
		var st_badge_col: Color = Color(1.0, 0.22, 0.22) if powered else Color(0.2, 0.1, 0.1)
		draw_string(
			font, Vector2(size.x - 74.0, 25.0),
			"FM STEREO",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, st_badge_col
		)
		
		# 3. Left Section: Station Frequency, Name & Scrolling Track Marquee
		var freq_str: String = st_data["freq"] if powered else "---.- FM"
		draw_string(
			font, Vector2(16.0, 50.0),
			freq_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 20, vfd_col
		)
		
		var bpm_str: String = "%d BPM" % int(st_data["bpm"]) if powered else "OFFLINE"
		draw_string(
			font, Vector2(118.0, 49.0),
			bpm_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, accent_col
		)
		
		var st_name: String = st_data["name"] if powered else "STANDBY // PRESS [M] POWER"
		draw_string(
			font, Vector2(16.0, 68.0),
			st_name.substr(0, 26),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, vfd_col.lightened(0.25)
		)
		
		# Track Marquee Box (Clipped horizontally)
		var marquee_box := Rect2(16.0, 75.0, 168.0, 18.0)
		draw_rect(marquee_box, Color(0.04, 0.06, 0.07, 0.9), true)
		if powered:
			var tracks: Array = st_data["tracks"]
			var raw_track: String = "  >> " + str(tracks[radio.current_track_idx]) + "   "
			var char_len: int = raw_track.length()
			var start_char: int = int(radio._marquee_offset * 0.18) % char_len
			var cycled_str: String = (raw_track + raw_track).substr(start_char, 22)
			draw_string(
				font, Vector2(20.0, 88.0),
				cycled_str,
				HORIZONTAL_ALIGNMENT_LEFT, 160.0, 11, accent_col.lightened(0.35)
			)
		else:
			draw_string(
				font, Vector2(20.0, 88.0),
				"-- AUDIO MUTED --",
				HORIZONTAL_ALIGNMENT_LEFT, 160.0, 11, Color(0.35, 0.35, 0.38)
			)
		
		# Volume Level Meter Bar
		var vol_norm: float = remap(radio.master_volume_db, -36.0, 6.0, 0.0, 1.0)
		draw_string(
			font, Vector2(16.0, 108.0),
			"VOL",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.6, 0.65, 0.7)
		)
		var vol_segments: int = 12
		for v_idx in range(vol_segments):
			var v_rect := Rect2(44.0 + v_idx * 11.5, 99.0, 9.0, 8.0)
			var active_seg: bool = powered and (float(v_idx) / float(vol_segments) < vol_norm)
			var seg_col: Color = vfd_col if v_idx < 9 else accent_col
			draw_rect(v_rect, seg_col if active_seg else Color(0.08, 0.11, 0.12), true)
		
		# 4. Right Section: 12-Band VFD Equalizer Display
		var eq_origin := Vector2(194.0, 32.0)
		var eq_width: float = 132.0
		var eq_height: float = 76.0
		var band_w: float = eq_width / float(JDMRadioAudioSystem.NUM_VFD_BANDS)
		var seg_h: float = eq_height / float(JDMRadioAudioSystem.SEGMENTS_PER_BAND)
		
		# Unlit VFD segment grid + Active lit phosphor bars
		for b in range(JDMRadioAudioSystem.NUM_VFD_BANDS):
			var band_val: float = radio._vfd_bands[b]
			var peak_val: float = radio._vfd_peaks[b]
			var lit_count: int = int(round(band_val * float(JDMRadioAudioSystem.SEGMENTS_PER_BAND)))
			var peak_seg: int = clampi(
				int(round(peak_val * float(JDMRadioAudioSystem.SEGMENTS_PER_BAND))) - 1,
				-1,
				JDMRadioAudioSystem.SEGMENTS_PER_BAND - 1
			)
			
			for s in range(JDMRadioAudioSystem.SEGMENTS_PER_BAND):
				# Draw bottom-to-top
				var y_pos: float = eq_origin.y + eq_height - float(s + 1) * seg_h
				var seg_rect := Rect2(
					eq_origin.x + float(b) * band_w + 1.0,
					y_pos + 1.0,
					band_w - 2.5,
					seg_h - 1.8
				)
				
				var is_lit: bool = powered and (s < lit_count)
				var is_peak: bool = powered and (s == peak_seg) and (peak_seg > 0)
				
				if is_peak:
					# Red/Amber Peak Hold Cap
					draw_rect(seg_rect, Color(1.0, 0.92, 0.85) if s >= 11 else accent_col.lightened(0.3), true)
				elif is_lit:
					if s >= 11:
						draw_rect(seg_rect, Color(1.0, 0.25, 0.22), true) # Redline Peak Zone
					elif s >= 8:
						draw_rect(seg_rect, accent_col, true)             # Upper Mid Zone
					else:
						draw_rect(seg_rect, vfd_col, true)                # Base VFD Cyan/Amber
				else:
					draw_rect(seg_rect, Color(0.07, 0.09, 0.10, 0.85), true)
		
		# 5. Bottom Faceplate Hotkey Legend
		draw_string(
			font, Vector2(12.0, size.y - 8.0),
			"[M] PWR/MUTE   [B / N] TUNER   [PGUP / PGDN] VOL",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.58, 0.62, 0.68)
		)