# PROMPT 8: ENGINE AUDIO ATTENUATION & DUPLICATE SYNTHESIZER MUTE
**Target Files:** `VehicleVFXAndAudio.gd`, `FD3SRx7Modeler.gd`
**Engine:** Godot 4.3 (GDScript 2.0)

---

### PROBLEM STATEMENT:
The engine audio in the game is excessively loud, distorted, and fatiguing to listen to ("صدای موتور ماشین هم خیلی زیاده").
- Causes:
  1. In `VehicleVFXAndAudio.gd`:
     - `_engine_player.unit_size = 12.0` and `_engine_player.volume_db = 0.0 dB`. A unit_size of 12.0 meters prevents standard 3D distance attenuation from kicking in for third-person chase cameras, blasting 100% full-scale synthesizer output.
     - `master_engine_gain` is set to `0.85`, which together with harmonic overtones causes digital clipping.
  2. In `FD3SRx7Modeler.gd`:
     - It instantiates a **second duplicate procedural audio generator** (`Rotary_13B_REW_Synthesizer`, `unit_size = 8.0`, `max_db = 3.0`).
     - When driving the RX-7, both `VehicleVFXAndAudio` and `FD3SRx7Modeler` play their synthesizers concurrently, doubling the acoustic power and creating harsh comb filtering and excessive volume!

---

### EXACT ARCHITECTURAL FIXES REQUIRED:

#### 1. In `VehicleVFXAndAudio.gd`:
- Balance Master Gains:
  ```gdscript
  @export_range(0.0, 2.0) var master_engine_gain: float = 0.42  # Reduced from 0.85
  @export_range(0.0, 2.0) var turbo_whine_gain: float = 0.22    # Balanced whine
  @export_range(0.0, 2.0) var bov_flutter_gain: float = 0.65    # Balanced BOV
  @export_range(0.0, 2.0) var backfire_gain: float = 0.75       # Crisp pop without clipping
  @export_range(0.0, 2.0) var tire_screech_gain: float = 0.45   # Natural tire friction
  ```
- Configure `_engine_player` (AudioStreamPlayer3D):
  ```gdscript
  _engine_player.unit_size = 4.0        # Realistic exhaust acoustic radius
  _engine_player.volume_db = -7.5       # Pleasant, balanced dynamic range
  _engine_player.max_db = 1.0           # Hard ceiling to prevent speaker blowouts
  _engine_player.max_distance = 180.0
  _engine_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
  ```
- Soften sample synthesis output:
  In `_synthesize_engine_audio_buffer()`, clamp output frame samples to `[-0.75, 0.75]` before pushing to the audio buffer to prevent hard digital clipping.

#### 2. In `FD3SRx7Modeler.gd`:
- Prevent duplicate synthesizer playback:
  ```gdscript
  @export var enable_audio_synthesis: bool = false # Muted by default so VehicleVFXAndAudio handles master audio
  ```
  If `enable_audio_synthesis` is ever toggled, check if a sibling or parent `VehicleVFXAndAudio` exists. If one exists, do not start `_engine_audio_player`.
  If standalone, set `_engine_audio_player.volume_db = -8.0` and `_engine_audio_player.unit_size = 4.0`.

---

### OUTPUT FORMAT:
Provide the updated audio configuration blocks for `VehicleVFXAndAudio.gd` and `FD3SRx7Modeler.gd`.
