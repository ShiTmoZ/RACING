# PROMPT 11: COMPLETE HUD DE-OVERLAP & CLEAN JDM VECTOR UI ARCHITECTURE
**Target Files:** `TougeSectorSplitAndRankHUD.gd`, `TougeDriftRefereeSystem.gd`, `MountAkinaTouge.gd`, `TougeTrackRegistryAndMenu.gd`
**Engine:** Godot 4.3 Forward+ (GDScript 2.0)
**Role:** Senior JDM UI/UX & CanvasLayer Graphics Engineer

---

### ROOT CAUSE OF OVERLAP:
Multiple subsystems independently register canvas elements and custom `_draw()` routines on the exact same pixel coordinates:
1. **Top-Left Collision (Y = 22):**
   - `TougeTrackRegistryAndMenu.gd` places `HUDStageHintPanel` at `Vector2(24, 22)`.
   - `TougeSectorSplitAndRankHUD.gd` draws `_draw_sector_split_panel` at `Vector2(24, 22)`.
   *Result:* Text and boxes render directly on top of each other.
2. **Top-Right Triple Collision (X = Right - 360, Y = 16 to 240):**
   - `MountAkinaTouge.gd` places `TopRightDesktopBar` (F11 & Close X) at `offset_left = -260, offset_top = 16`.
   - `TougeSectorSplitAndRankHUD.gd` draws `_draw_drift_rank_panel` at `Vector2(vp_size.x - 364, 22)`.
   - `TougeDriftRefereeSystem.gd` draws `_draw_top_right_score_panel` at `Vector2(vp_size.x - 320, 24)`.
   *Result:* 3 distinct panels and buttons overlap into an unreadable mess.
3. **Bottom-Left Clutter:**
   - `MountAkinaTouge.gd` creates `ControlsGuidePanel` ("JDM CONTROLS MANUAL") at `PRESET_BOTTOM_LEFT` and leaves it permanently visible.
   - `TougeDriftRefereeSystem.gd` draws `_draw_bottom_left_water_cup_widget` at the same bottom-left corner.
4. **Bottom-Right Collision:**
   - `InitialDDigitalClusterHUD.gd` sits at `PRESET_BOTTOM_RIGHT`.
   - `TougeSectorSplitAndRankHUD.gd` draws `_draw_speed_trap_cluster` at `Vector2(vp_size.x - 320, vp_size.y - 128)`.

---

### UNIFIED HUD ZONING SPECIFICATION:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ [TOP-LEFT]                          [TOP-CENTER]               [TOP-RIGHT]  │
│ Stage & Keys Hint (Y=18)      Drift Score & Combo (Y=24)   [F11][X] (Y=16)  │
│ Sector Splits (Y=64)            (Fades when idle)       Sector Times (Y=60) │
│                                                                             │
│                                                                             │
│                                                                             │
│                                                                             │
│ [BOTTOM-LEFT]                                                [BOTTOM-RIGHT] │
│ Water Cup / Tofu Widget                           Initial D Digital Cluster │
│ (Controls Manual: F1 / Auto-fade)                           (Speed/Gear/RPM)│
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### REQUIRED ARCHITECTURAL IMPLEMENTATION:

#### 1. In `MountAkinaTouge.gd` (Controls Manual Auto-Fade / Toggle):
- Modify `_setup_desktop_ui()`:
  - Add `[F1] Manual` toggle support.
  - Automatically fade out `guide_panel` ("JDM CONTROLS MANUAL") 5.0 seconds after spawning or once the vehicle exceeds 15 km/h:
    ```gdscript
    # In _physics_process or vehicle speed watcher:
    if is_instance_valid(guide_panel) and guide_panel.visible:
        if current_speed_kmh > 15.0 or _guide_timer > 5.0:
            var tween := create_tween()
            tween.tween_property(guide_panel, "modulate:a", 0.0, 0.5)
            tween.tween_callback(func(): guide_panel.visible = false)
    ```
  - Pressing `KEY_F1` toggles `guide_panel.visible` and sets `modulate.a = 1.0`.

#### 2. In `TougeSectorSplitAndRankHUD.gd`:
- **Relocate Sector Splits:**
  - Shift `_draw_sector_split_panel` to `Vector2(24.0, 68.0)` so it sits cleanly *below* the Stage Hint panel.
- **De-duplicate Drift Rank:**
  - `TougeDriftRefereeSystem.gd` already provides the authoritative Drift Score and Rank.
  - Remove `_draw_drift_rank_panel` from `_on_hud_canvas_draw()` so it no longer collides with Top-Right controls.
- **Relocate Speed Trap Cluster:**
  - Move `_draw_speed_trap_cluster` away from the bottom-right cluster to Top-Center-Right or make it a brief floating banner that fades after 2.5 seconds.

#### 3. In `TougeDriftRefereeSystem.gd`:
- **Top-Center Drift Scoreboard:**
  - Anchor `_draw_top_right_score_panel` to **Top-Center** (`Vector2(vp_size.x * 0.5 - 150.0, 24.0)`).
  - Dynamically fade opacity (`modulate.a` or alpha blend) to `0.2` or `0.0` when total drift points are 0 and no drift is active, cleanly revealing the center when just cruising.
- **Bottom-Left Alignment:**
  - Ensure `_draw_bottom_left_water_cup_widget` is positioned at `Vector2(28.0, vp_size.y - 120.0)` with a subtle glass styling.

#### 4. In `TougeTrackRegistryAndMenu.gd`:
- Keep `HUDStageHintPanel` anchored at `PRESET_TOP_LEFT` (`Vector2(24.0, 18.0)`), height 36px.
- Update text to: `[M / TAB] STAGE SELECT  |  [F1] CONTROLS  |  [F10] GRAPHICS  |  [R] RESTART`.

---

### DELIVERABLE REQUIREMENTS:
1. Provide the exact GDScript methods and coordinate changes for `TougeSectorSplitAndRankHUD.gd`, `TougeDriftRefereeSystem.gd`, `MountAkinaTouge.gd`, and `TougeTrackRegistryAndMenu.gd`.
2. Guarantee that in 1080p, 1440p, and 4K resolutions, no two HUD elements have overlapping bounding rectangles.
3. Keep all vehicle physics and telemetry bindings untouched.
