# ArcadeSim — Nightfall Circuit

Godot **4.3** (Vulkan **Forward+**) drop-in project: a procedurally generated banked
asphalt test circuit with a raycast-suspension arcade car and a spring-damped chase
camera. Nothing is imported — textures, sky, meshes and colliders are all built from code
at load time, so the project itself is six text files.

```
project.godot
Vehicle.tscn        ArcadeSimVehicle.gd     ArcadeChaseCamera.gd
TrackArena.tscn     TrackArena.gd
```

## Run

1. Open the folder in Godot 4.3 (`Project → Import`).
2. F5 (main scene is `res://TrackArena.tscn`).

First launch generates the spline, meshes and noise textures in a frame or two.

## Controls

| Action | Binding |
| --- | --- |
| accelerate | `W` / `↑` |
| brake + reverse (below 0.8 m/s) | `S` / `↓` |
| steer left | `A` / `←` |
| steer right | `D` / `→` |
| handbrake | `Space` |
| respawn at start | `R` |

Bindings are physical key codes, so they hold on AZERTY/QWERTZ layouts.

## Assembly notes

### `Vehicle.tscn`
* `RigidBody3D` (1250 kg, custom centre of mass at −0.15 m, `continuous_cd`, layer
  `vehicle`, mask `world`).
* `CollisionShape3D` → `BoxShape3D` **1.8 × 0.8 × 4.2** (X × Y × Z).
* `RayFL / RayFR / RayRL / RayRR` at `x = ±0.78`, `z = ∓1.32`, ray length `0.72` along
  `−Y`, `exclude_parent` on, mask `world` only. They are wired into the exported
  `wheel_rays` array; the controller also re-resolves them by node scan if the array is
  ever empty (e.g. when instancing from code or after a scene refactor).
* `WheelFL…RR` meshes + `RimFL…RR` children, wired into `wheel_meshes`. The script drives
  their transform every physics tick (steer on Y, roll on X, vertical offset from the
  actual suspension travel), so wheel gap/compression is genuine, not faked.

### `ArcadeSimVehicle.gd`
* Raycast suspension: spring `45 kN/m`, damper `4.3 kN·s/m`, per-wheel force clamp, plus
  front/rear **anti-roll bars**.
* Friction-circle tire model: lateral force is solved as the impulse that would cancel
  slip, then clamped to `μ · Fz` (`μ = 1.55`). Same treatment for braking, which gives
  free ABS-like behaviour and no stepping at 120 Hz.
* Torque-curve engine (peak ~400 Nm), 6-speed automatic gearbox with shift cut, reverse
  gear engagement from the brake key, engine braking, aero drag and downforce.
* Speed-sensitive steering lock (35° → 8.5°), handbrake that drops **rear** grip to 0.28 μ
  and locks the rear wheels for drift entry.
* Auto-respawn when upside down for 2 s or when falling out of the world; `R` respawns
  instantly at the spawn pose.

### `ArcadeChaseCamera.gd`
Frame-rate-independent damping (`1 − e^(−k·dt)`), heading-follow with a velocity blend,
speed-dependent distance and FOV (62° → 82°), and a snap on spawn so frame 1 is already
framed correctly.

### `TrackArena.gd` / `.tscn`
* Closed **Catmull-Rom** loop through `control_points` (editable in the inspector),
  40 samples per segment → ~2.4 m spacing, ~1.15 km lap.
* Orthonormal frames per sample; corners **bank automatically** up to 9° from smoothed
  signed curvature, with ramp-in/ramp-out so there are no steps.
* Generated surfaces: asphalt, sloped red/white curbs, red/white barrier walls, ground
  plane. Each gets its own `StaticBody3D` + trimesh collider with
  `backface_collision = true`.
* Asphalt uses a runtime `StandardMaterial3D`: cellular-noise albedo, low-frequency
  roughness texture for damp patches, noise normal map, `metallic 0.18`, **clearcoat 0.45**
  — reads as wet tarmac under SSR.
* `WorldEnvironment`: procedural sky, sky ambient/reflections, **SDFGI**, SSAO, SSR, glow,
  distance fog, **ACES** tonemap, slight contrast/saturation grade.
* `DirectionalLight3D` sun with PSSM 4-split shadows (4096, 420 m).
* Instantiates `Vehicle.tscn` on the start line, hands it to `ChaseCamera`, adds a minimal
  HUD (speed / gear / rpm).

## Tuning knobs

| Feel | Exported property |
| --- | --- |
| Grip / drift | `tire_grip`, `rear_grip_multiplier`, `handbrake_grip_multiplier` |
| Body roll | `suspension_stiffness`, `suspension_damping`, `anti_roll_stiffness` |
| Accel / top speed | `engine_peak_torque`, `gear_ratios`, `final_drive`, `drag_coefficient` |
| Turn-in | `max_steer_angle`, `min_steer_angle`, `steer_speed_reference` |
| Camera | `distance`, `height`, `position_smoothing`, `max_fov` |
| Circuit | `control_points`, `track_width`, `max_bank_degrees`, `steps_per_segment` |

## Coexistence with an existing vehicle/camera script

If you already have your own `ArcadeSimVehicle.gd` / `ArcadeChaseCamera.gd`, drop them in
over these — the scenes only depend on this public surface:

* Vehicle: `signal gear_changed(int)`, `var is_reversing`, `var gear_number`,
  `var speed_kmh`, `var engine_rpm`, `func respawn()`, `func set_spawn_transform(Transform3D)`,
  and the exported `wheel_rays` / `wheel_meshes` arrays.
* Camera: `@export var target: Node3D`, `func set_target(Node3D)`, `func snap_to_target()`,
  and being a `Camera3D` node named `ChaseCamera` under the arena root.

## Known constraints

* Trimesh road collision is one-sided by default; it is explicitly flipped on. Very high
  speed impacts into barriers can still tunnel — `continuous_cd` is on the car, and you can
  thicken `wall_thickness` if you run >300 km/h builds.
* SDFGI + SSR at 1080p is the heavy part of the frame. Drop `sdfgi_cascades` to 2 or
  disable SSR in the `Environment` for low-end GPUs.
* `regenerate()` rebuilds geometry at runtime but does not respawn the car.
