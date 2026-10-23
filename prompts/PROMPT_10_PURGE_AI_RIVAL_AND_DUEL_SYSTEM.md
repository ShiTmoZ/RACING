# PROMPT 10: COMPLETE PURGE OF AI RIVAL RACER & DUEL TELEMETRY
**Target Files:** `MountAkinaTouge.gd`, `TougeTrackRegistryAndMenu.gd`
**Engine:** Godot 4.3 Forward+ (GDScript 2.0)
**Role:** Senior Gameplay Systems & Engine Integration Engineer

---

### CONTEXT & ROOT CAUSE:
The user explicitly wants a pure solo JDM Touge / Free Roam drift experience.
Currently, `MountAkinaTouge.gd` unconditionally spawns an AI rival car via `TougeAIRivalRacer.gd` in `_ready()`:
```gdscript
call_deferred("_setup_ai_rival_racer")
```
This causes multiple game-breaking issues:
1. An unwanted phantom AI car is placed on the road next to the player, which crashes into barriers, falls off cliffs into the void, or triggers physics lag.
2. The AI rival script (`TougeAIRivalRacer.gd`) spawns its own Cat-and-Mouse duel HUD, banner alerts, and distance meters, which clutter and collide with the drift telemetry HUD.
3. Spurious "SUDDEN DEATH DEFEAT" popups trigger when the player is simply cruising or drifting in free roam.
4. When switching tracks in `TougeTrackRegistryAndMenu.gd`, it attempts to reposition `TougeAIRivalRacer`, keeping the unwanted rival alive.

---

### REQUIRED ARCHITECTURAL CHANGES:

#### 1. In `MountAkinaTouge.gd`:
- **Completely remove or bypass the AI rival initialization:**
  In `_ready()`:
  - Remove or comment out `call_deferred("_setup_ai_rival_racer")`.
  - In `_setup_ai_rival_racer()`, wrap the entire method body with an immediate return:
    ```gdscript
    func _setup_ai_rival_racer() -> void:
        # AI Rival disabled: Project RACING is dedicated to pure solo touge & time attack
        return
    ```
  - Ensure `_ai_rival_car` remains `null` and is never added to the scene tree.

#### 2. In `TougeTrackRegistryAndMenu.gd`:
- In `select_and_load_track(track_id: String)`:
  - Remove the code block that searches for and repositions `TougeAIRivalRacer`:
    ```gdscript
    # REMOVE THIS BLOCK COMPLETELY:
    # var rival := root.find_child("TougeAIRivalRacer", true, false) as RigidBody3D
    # if is_instance_valid(rival):
    #     ...
    ```

#### 3. In `MountAkinaTouge.gd` (or any HUD referencing rival):
- In `_setup_sector_split_and_rank_hud()`:
  - Ensure the drift HUD is bound only to `_spawned_vehicle` and `_referee_mgr` without expecting any rival telemetry.

---

### DELIVERABLE REQUIREMENTS:
1. Provide the exact updated GDScript code for the touched sections in `MountAkinaTouge.gd` and `TougeTrackRegistryAndMenu.gd`.
2. Ensure zero instances of `TougeAIRivalRacer` are created in memory or present in the scene tree.
3. Ensure no Sudden Death banners, battle countdowns, or rival telemetry cards appear on screen under any circumstances.
4. Maintain 100% backward compatibility with vehicle physics, track generation, and drift scoring.
