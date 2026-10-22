# TASK: UI/HUD Layout Overhaul & Multi-Track Spawn Sinking Fix for Godot 4.3

## 1. PROJECT CONTEXT & ARCHITECTURE
In "RACING" (Godot 4.3):
- Track switching is managed by `TougeTrackRegistryAndMenu.gd` and `TougeMultiEnvironmentManager.gd`, supporting Mount Akina (downhill mountain pass), Irohazaka (30 steep hairpin switchbacks), and Tsukuba Circuit (TC2000 raceway).
- Player vehicle uses custom raycast suspension physics in `ArcadeSimVehicle.gd` with chassis rest height ~1.1m above ground.

## 2. PART A: MULTI-TRACK VEHICLE SPAWN & COLLISION FIX (`TougeMultiEnvironmentManager.gd`)
**Bug**: When switching from Mount Akina to Tsukuba Circuit or Irohazaka, the vehicle falls through the road collision mesh into infinite void.
**Root Cause**: In `_place_vehicle_at_spawn()`, the spawn position is calculated as `s0.pos + s0.banked_up * 0.65`. Because the chassis collision box rest height is ~1.1m, spawning at +0.65m causes the vehicle collider to start intersecting or sitting below the single-sided triangles of the `ConcavePolygonShape3D` road surface. In Godot physics, concave polygon shapes have no internal volume; any body intersecting the backface falls through.

**Requirements**:
1. In `_place_vehicle_at_spawn()` and sample spawn calculation:
   - Increase the spawn elevation offset from `0.65` to `1.5` meters: `var spawn_pos = s0.pos + s0.banked_up * 1.5`.
   - Ensure the car drops naturally onto its 4 suspension springs without penetrating the road.
   - Explicitly ensure `road_body.collision_layer = 1` and `road_body.collision_mask = 1`.
   - Zero out velocities and apply transform via PhysicsServer3D:
     ```gdscript
     PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, spawn_xform)
     PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
     PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
     vehicle.sleeping = false
     ```
   - Add a fall-out-of-bounds safety check in physics process: if `vehicle.global_position.y < min_track_y - 12.0`, instantly respawn the vehicle at `_spawn_transform`.

## 3. PART B: HUD LAYOUT, SCALING & OVERLAP RESOLUTION
**Bugs**:
1. **Left Side Conflict**: In `TougeMultiplayerManager.gd`, the online lobby panel (`_lobby_panel`) starts visible by default at `Vector2(24, 24)`, directly covering the Kenwood KDC-7000 radio overlay.
2. **Right Side Conflict**: The Drift Referee Scoreboard (`TougeDriftRefereeSystem.gd`) and the AI Rival Duel HUD (`TougeAIRivalRacer.gd`) both render at Top-Right, completely overlapping each other.

**Requirements**:
1. **Multiplayer Lobby (`TougeMultiplayerManager.gd`)**:
   - In `_ready()` / `_build_lobby_ui()`, initialize `_lobby_panel.visible = false` by default.
   - When opened via `KEY_O`, center the panel on screen (`set_anchors_preset(Control.PRESET_CENTER)` with offset margins) instead of pinning it to Top-Left.
2. **Drift Referee Panel (`TougeDriftRefereeSystem.gd`)**:
   - Scale down the score panel by ~20% (change width from 330px to 260px, height from 168px to 135px, and proportionally reduce font sizes by 2-3pt) so it is compact and unobtrusive.
   - Keep it anchored at Top-Right (`vp_size.x - panel_w - 20.0`, Y = 16.0).
3. **AI Rival Battle HUD (`TougeAIRivalRacer.gd`)**:
   - Ensure the Rival Gap / Duel panel is hidden (`visible = false`) during casual driving, and only becomes visible when a race duel is actively underway.
   - When active, position it at Top-Center (Y = 18.0) or directly underneath the Drift panel (Y = 160.0) so it never shares pixels with the Drift Scoreboard.

Provide the complete updated methods and code blocks with full GDScript 2.0 syntax.
