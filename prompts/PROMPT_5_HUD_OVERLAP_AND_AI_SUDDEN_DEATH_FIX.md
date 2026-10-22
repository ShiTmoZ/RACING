# PROMPT 5: HUD LAYOUT OVERLAP & AI RIVAL SUDDEN DEATH BUG FIX
**Target Files:** `TougeAIRivalRacer.gd`, `TougeSectorSplitAndRankHUD.gd`
**Engine:** Godot 4.3 (GDScript 2.0)

---

### PROBLEM STATEMENT:
1. **HUD Overlap:**
   - At the top-right of the screen, the Drift Grade Panel (`TougeSectorSplitAndRankHUD.gd`, height 212px, Y=22 to 234) and the AI Rival Cat-and-Mouse telemetry card (`TougeAIRivalRacer.gd`, `_hud_root_panel` anchored at `PRESET_TOP_RIGHT`, `position.y = 160`) directly collide and overlap each other by 74 pixels.
   - Furthermore, `_hud_root_panel` is displayed even when no rival race is active (casual free roam / hot lap).
   - The Sudden Death banner (`_hud_banner_panel`) and corner attack warning panel (`_hud_warning_panel`) appear in the middle of other UI elements or remain visible indefinitely.

2. **AI Sudden Death Trigger Bug:**
   - In `TougeAIRivalRacer.gd`, `_conclude_battle()` triggers spuriously during casual driving, track looping, or map change.
   - Line 518-519 checks track completion without verifying `battle_active`:
     ```gdscript
     if rival_spline_offset_m >= _track_total_length - 4.0 and battle_elapsed_time_s > 2.0:
         _conclude_battle(not rival_is_leading, "FINISH LINE CROSSED")
     ```
   - When `battle_active` is `false`, `battle_elapsed_time_s` still accumulates, causing spontaneous "SUDDEN DEATH DEFEAT" popups when simply driving on the track or switching maps.

---

### EXACT ARCHITECTURAL FIXES REQUIRED:

#### 1. In `TougeAIRivalRacer.gd`:
- **Hide Rival HUD when not in battle:**
  In `_hud_root_panel`, ensure `_hud_root_panel.visible = false` by default, and only set `_hud_root_panel.visible = battle_active and battle_mode != BattleMode.TIME_ATTACK_GHOST and not battle_concluded`.
- **Relocate Rival HUD below Drift Grade Panel:**
  Change `_hud_root_panel.position = Vector2(-360.0, 246.0)` so that when battle is active, it docks cleanly *underneath* the Drift Grade panel (which ends at Y=234) without any overlap.
- **Strict Guard on `_conclude_battle`:**
  At the beginning of `_conclude_battle(player_won: bool, reason_text: String)`:
  ```gdscript
  if not battle_active or battle_concluded:
      return
  ```
  And in line 518:
  ```gdscript
  if battle_active and not loop_track_spline and not battle_concluded:
      if rival_spline_offset_m >= _track_total_length - 4.0 and battle_elapsed_time_s > 2.0:
          _conclude_battle(not rival_is_leading, "FINISH LINE CROSSED")
          return
  ```
- **Banner Dismissal:**
  When a battle concludes or when the track resets, ensure `_hud_banner_panel` fades out via tween and explicitly sets `visible = false`. If `battle_active` is false, `_hud_banner_panel.visible = false` immediately.

#### 2. In `TougeSectorSplitAndRankHUD.gd`:
- Verify the Drift Grade Panel origin is clamped and responsive to viewport width:
  `var drift_origin := Vector2(vp_size.x - 364.0, 22.0)`
- Ensure all text within the slanted glass boxes respects text boundary limits so it doesn't bleed out of the containers.

---

### OUTPUT FORMAT:
Provide the updated and patched methods for `TougeAIRivalRacer.gd` (`_setup_battle_hud`, `_update_spline_and_battle_gap`, `_conclude_battle`, and `_process`/`_physics_process`) ready to be applied.
