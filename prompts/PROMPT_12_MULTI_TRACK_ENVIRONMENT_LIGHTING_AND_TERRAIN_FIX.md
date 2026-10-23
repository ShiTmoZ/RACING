# PROMPT 12: MULTI-TRACK PERSISTENT LIGHTING, TERRAIN SKIRTS & VOID FALL PREVENTION
**Target Files:** `TougeMultiEnvironmentManager.gd`, `MountAkinaTouge.gd`, `TougeTrackRegistryAndMenu.gd`
**Engine:** Godot 4.3 Forward+ (GDScript 2.0)
**Role:** Senior 3D Environment & Physics Pipeline Engineer

---

### ROOT CAUSE ANALYSIS:
When selecting any track other than the initial Akina spawn (such as Irohazaka, Tsukuba, or Hakone):
1. **Destruction of Global Lighting & Sky:**
   - In `TougeMultiEnvironmentManager.gd`, `_cleanup_previous_track_nodes()` executes `queue_free()` on `AkinaDefaultTrack`.
   - In `MountAkinaTouge.gd`, the `WorldEnvironment`, `DirectionalLight3D` (sun), and `valley_fog` were attached as children of `AkinaDefaultTrack`!
   *Result:* Switching tracks destroys the game's sun, skybox, ambient lighting, and environment. The new track loads in complete darkness or an unshaded void.
2. **Floating Void Ribbon with No Terrain:**
   - `TougeMultiEnvironmentManager.gd` generates only a bare, thin `RoadSurfaceMesh` ribbon with no mountain skirts, ground colliders, or surrounding cliffs.
   *Result:* Leaving the road causes the vehicle to fall thousands of meters into empty black space. The track appears to be "underground" or floating disconnected in nothingness.
3. **Collision Penetration at Spawn:**
   - The collision mesh in `TougeMultiEnvironmentManager.gd` is generated using a single-layer `ConcavePolygonShape3D` without collision thickness or safety respawn planes.
   - If the raycast suspension has any delta delay before settling, the car falls through the unthickened collision surface into the void.

---

### REQUIRED ARCHITECTURAL FIXES:

#### 1. In `MountAkinaTouge.gd` (Persistent World Environment & Sun):
- Move `WorldEnvironment`, `DirectionalLight3D` (sun), and `valley_fog` OUT of `_akina_environment_root` (`AkinaDefaultTrack`)!
  Attach them directly to `self` (the root scene `MountAkinaTouge`) so they are **never deleted** when switching track meshes:
  ```gdscript
  # Attach directly to self so track rebuilds never destroy lighting:
  add_child(world_env)
  add_child(sun)
  add_child(rim_light)
  add_child(valley_fog)
  ```
- Store references `_world_env_node` and `_sun_light_node` as class members so `TougeMultiEnvironmentManager` can adjust time of day, fog, and sky dynamically per stage.

#### 2. In `TougeMultiEnvironmentManager.gd` (Atmospheric Control & Thickened Road Deck):
- **Never delete lighting nodes in `_cleanup_previous_track_nodes()`:**
  Only clean up road meshes, guardrails, and track-specific props under `_active_track_root`.
- **Thicken Road Collision Deck:**
  In `_build_road_mesh_and_collision()`:
  - Generate a double-sided solid collision deck with a **0.6m vertical extruded base thickness**:
    For every road segment, generate top faces AND downward extruded skirt faces so raycasts and collision boxes can never penetrate or tunnel through.
  - Add a wide safety collision apron (+8.0m on each side beyond guardrails) and a global catch-plane / kill-plane at `Y = -50.0` that instantly catches falling vehicles and respawns them at the stage summit with zero velocity.
- **Mountain Terrain / Horizon Skirt Generation:**
  For each generated track (Irohazaka, Tsukuba, Hakone, and Akina), generate a low-poly stylized mountain terrain mesh / horizon silhouette along the spline edges so the track feels embedded into a real mountain pass, rather than a ribbon suspended in space.
- **Stage-Specific Lighting Profiles:**
  In `_apply_environment_atmosphere(track_id, track_data)`:
  - Adjust the persistent `WorldEnvironment` and `DirectionalLight3D`:
    * `akina_downhill`: Midnight Touge, Deep Blue/Purple Ambient, Golden Streetlights, Volumetric Valley Fog.
    * `irohazaka_downhill`: Autumn Sunset, Warm Orange/Red Horizon Glow, Long Shadows.
    * `tsukuba_circuit`: Crisp Daylight, Clear Sky, High Contrast Shadows.
    * `hakone_turnpike`: Dense Midnight Fog, Reduced View Distance, Moody Headlight Scattering.

#### 3. In `TougeTrackRegistryAndMenu.gd`:
- Ensure that when returning to `"akina_downhill"`, it either toggles visibility of the full high-detail `AkinaDefaultTrack` or builds the procedural track with identical altitude and landmark fidelity.
- When `_place_vehicle_at_spawn()` executes, guarantee:
  ```gdscript
  PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
  PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
  vehicle.global_transform = spawn_xform
  vehicle.linear_velocity = Vector3.ZERO
  vehicle.angular_velocity = Vector3.ZERO
  ```
  And immediately snap the chase camera `snap_to_target(vehicle)` to eliminate disorientation.

---

### DELIVERABLE REQUIREMENTS:
1. Provide the complete updated methods for `TougeMultiEnvironmentManager.gd` and the lighting initialization changes in `MountAkinaTouge.gd`.
2. Guarantee that switching between all 4 stages preserves full lighting, materials, and volumetric atmosphere.
3. Eliminate falling through the ground, underground spawn traps, and black-void backgrounds.
4. Keep all vehicle handling, raycast suspension constants, and Kamm's circle physics strictly unmodified.
