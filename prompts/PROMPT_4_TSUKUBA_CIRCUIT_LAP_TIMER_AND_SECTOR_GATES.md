# TASK: Tsukuba TC2000 Closed-Loop Lap Timing & Multi-Track Sector Gates for Godot 4.3

## 1. PROJECT CONTEXT & ARCHITECTURE
In "RACING" (Godot 4.3):
- The track system in `TougeMultiEnvironmentManager.gd` supports two track archetypes:
  1. Point-to-Point Downhill Touge (Mount Akina & Irohazaka) — start at mountain summit, finish at base.
  2. Closed-Loop Circuit (Tsukuba Circuit TC2000) — continuous racing loop with pit straight, Dunlop bridge, hairpins, and final sweeper.
- We need an intelligent timing controller (`TougeLapTimingAndSectorManager.gd` or expansion to `TougeSectorSplitAndRankHUD.gd`) that automatically adapts its HUD and logic based on whether the current track is a Point-to-Point Touge or a Closed-Loop Circuit.

## 2. REQUIREMENTS & FEATURES

### Part A: Automatic Track Type Detection & Timing Modes
1. When switching tracks via `TougeTrackRegistryAndMenu.gd`:
   - If `is_closed_loop == false` (Akina / Irohazaka):
     - Operate in **Downhill Touge Run Mode** (Single run from Sector 1 to Finish, final ranking S/A/B/C/D, sudden death rival duel support).
   - If `is_closed_loop == true` (Tsukuba Circuit):
     - Automatically switch to **Circuit Hot-Lap Mode**:
       - Continuous lap timing without stopping the car at the end of the spline.
       - Track `current_lap_time`, `best_lap_time`, `last_lap_time`, and `lap_count`.

### Part B: Tsukuba TC2000 3-Sector Split Gates
1. Divide Tsukuba's closed spline into 3 official sectors:
   - Sector 1: Start/Finish straight to First Hairpin exit (~0% to 32% of track length).
   - Sector 2: Dunlop Arch, chicane, to Second Hairpin apex (~32% to 68% of track length).
   - Sector 3: Back straight and sweeping Final Corner (~68% to 100% of track length).
2. Real-Time Delta Split HUD:
   - When crossing each sector line:
     - Compare the sector split time against the session best lap.
     - Display a momentary delta banner (+0.18s in red if slower, -0.24s in vibrant green if faster).
     - Fade the split delta out after 3.0 seconds.

### Part C: Clean Circuit HUD Overlay (Bottom-Right or Top-Center)
1. Display:
   - `LAP: 01 [HOT LAP]`
   - `CURRENT: 0'42.85`
   - `BEST:    0'59.12`
   - `DELTA:   -0.34s (OPTIMAL)`
2. Ensure this overlay never collides with:
   - KENWOOD KDC-7000 radio (Top-Left)
   - Drift Referee Scoreboard (Top-Right)
   - Wangan Cluster & Tachometer (Bottom-Center)

Provide clean, modular, self-contained GDScript 2.0 code ready for integration.
