# PROMPT 6: TRACK SWITCHING UNDERGROUND SPAWN & CAMERA REALIGNMENT FIX
**Target Files:** `TougeTrackRegistryAndMenu.gd`, `TougeMultiEnvironmentManager.gd`, `ArcadeChaseCamera3D.gd`
**Engine:** Godot 4.3 (GDScript 2.0)

---

### PROBLEM STATEMENT:
When switching tracks in the Track Selection Menu (e.g. from Mount Akina to Tsukuba or Irohazaka, or returning back to Mount Akina):
1. **The car spawns underground or falls through the world into the void:**
   - In `TougeTrackRegistryAndMenu.gd`:
     When switching back to `"akina_downhill"`, it executes:
     ```gdscript
     var summit_spawn := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.4, 0.0))
     _teleport_vehicle_to_start(_vehicle, summit_spawn)
     ```
     This teleports the car to `Y = 0.4`, but the Mount Akina road summit is at `Y = 128.0`! The car is placed 127.6 meters underground in empty air.
     Furthermore, because the previous biome manager deleted `AkinaDefaultTrack`, the Akina road mesh no longer exists when returning!
   - In `TougeMultiEnvironmentManager.gd`:
     The spawn calculation at line 81:
     `var spawn_pos: Vector3 = s0.pos + s0.banked_up * 1.5`
     drops the car from 1.5 meters in the air. Because `ArcadeSimVehicle.gd` has a suspension raycast length of only 0.72m, the wheels have zero contact with the ground at spawn. The rigid body drops with high gravity acceleration, clips through the 1-sided collision polygon, and falls into infinity.
2. **The Chase Camera gets lost in the old map:**
   - The chase camera is not reset or snapped to the new spawn position, leaving the viewport pointed at the coordinates of the previous map.

---

### EXACT ARCHITECTURAL FIXES REQUIRED:

#### 1. In `TougeTrackRegistryAndMenu.gd`:
- Use `TougeMultiEnvironmentManager` uniformly for **all** tracks, including `"akina_downhill"`!
  When `"akina_downhill"` is selected, do not just teleport to a hardcoded `(0, 0.4, 0)`. Instead, allow `TougeMultiEnvironmentManager` to rebuild the Akina downhill spline and collision surface cleanly.
- After teleporting/spawning the vehicle, locate the scene's active `Camera3D` / `ArcadeChaseCamera3D` and instantly snap its transform behind the vehicle, clearing any interpolation or smoothing history so the camera doesn't fly across the world.

#### 2. In `TougeMultiEnvironmentManager.gd`:
- **Correct Spawn Height:**
  Change spawn offset from `1.5m` to `0.48m`:
  ```gdscript
  var spawn_pos: Vector3 = s0.pos + s0.banked_up * 0.48
  ```
  This places the tire contact patches directly on the road surface, ensuring the raycast suspension instantly engages without physics penetration.
- **Robust Spawn Placement (`_place_vehicle_at_spawn`):**
  Reset both PhysicsServer3D state and Vehicle properties:
  ```gdscript
  func _place_vehicle_at_spawn(vehicle: RigidBody3D, spawn_xform: Transform3D) -> void:
      if not is_instance_valid(vehicle):
          return
      PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, spawn_xform)
      PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
      PhysicsServer3D.body_set_state(vehicle.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
      vehicle.global_transform = spawn_xform
      vehicle.linear_velocity = Vector3.ZERO
      vehicle.angular_velocity = Vector3.ZERO
      vehicle.sleeping = false
      if vehicle.has_method("reset_telemetry"):
          vehicle.call("reset_telemetry")
  ```

---

### OUTPUT FORMAT:
Provide the updated code for `TougeTrackRegistryAndMenu.gd` and `TougeMultiEnvironmentManager.gd` handling clean track transitions, correct spawn altitudes, and camera snaps.
