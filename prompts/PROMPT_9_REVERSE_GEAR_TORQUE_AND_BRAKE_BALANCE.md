# PROMPT 9: REVERSE GEAR TORQUE & BRAKE-IN-REVERSE BALANCING
**Target Files:** `TougeDriftPhysicsSolver.gd`, `ArcadeSimVehicle.gd`
**Engine:** Godot 4.3 (GDScript 2.0)
**STRICT MANDATE:** Do NOT modify the Kamm's Circle friction circle, normal load transfer, or suspension raycast physics. Only rebalance reverse drive force calculation and brake/throttle input separation.

---

### PROBLEM STATEMENT:
Reverse gear torque is violently overpowered and unbalanced ("گشتاور دنده عقب هم بالانس نیست و زیادی بالاس"):
1. **Excessive Reverse Thrust:**
   In `TougeDriftPhysicsSolver.gd`:
   ```gdscript
   var reverse_mech_force: float = (BASE_ENGINE_TORQUE_NM * REVERSE_GEAR_RATIO * FINAL_DRIVE_RATIO * 0.92) / WHEEL_RADIUS_M
   var drive_share: float = 0.55 if is_driven else 0.25
   var reverse_drive_force: float = rev_Input * reverse_mech_force * drive_share
   ```
   With standard engine parameters (392 Nm, 3.28 reverse ratio, 4.11 final drive), this evaluates to **over 15,100 Newtons per wheel** — more than DOUBLE the forward 1st gear torque! Engaging reverse causes the car to violently burnout backwards and rocket to high speeds like a dragster.
2. **Brake Acting as Reverse Throttle:**
   The code used `var rev_Input: float = maxf(throttle, brake)`.
   When rolling backward, pressing the brake pedal (to stop) was interpreted as 100% reverse throttle, making it impossible to stop smoothly and continuously catapulting the car backward!
3. **Turbo Boost Spool in Reverse:**
   In `ArcadeSimVehicle.gd`, line 473 forced `boost_multiplier = 1.15` in reverse, injecting artificial turbo boost into low-speed reverse maneuvers.

---

### EXACT ARCHITECTURAL FIXES REQUIRED:

#### 1. In `TougeDriftPhysicsSolver.gd`:
- **Correct Reverse Drive Force & Input Separation:**
  Only the active reverse input (holding backward/brake when standstill, or dedicated reverse throttle) should drive the wheels backward.
  If the car is moving backward (`v_long < -0.5 m/s`) and the player presses the **forward** throttle (W / Up Arrow), the car should apply forward braking torque to stop the roll, NOT continue reversing!
  If the player presses **brake** (S / Down Arrow) while already reversing, apply progressive speed-capping and smooth mechanical friction to stop.
- **Calibrate Reverse Torque Magnitude:**
  Reverse gear torque should feel realistic and controllable (approx 3,000 N – 3,500 N per driven wheel at full pedal), NOT 15,000 N:
  ```gdscript
  if is_reversing:
      var rev_throttle: float = brake if forward_speed <= 0.5 else 0.0
      if rev_throttle > 0.01:
          # Realistic calibrated reverse torque (0.42 scale of theoretical peak mechanical lock)
          var calibrated_reverse_force: float = (BASE_ENGINE_TORQUE_NM * 2.20 * FINAL_DRIVE_RATIO * 0.85) / WHEEL_RADIUS_M
          var drive_share: float = 0.50 if is_driven else 0.0
          var reverse_drive_force: float = rev_throttle * calibrated_reverse_force * drive_share * 0.42
          
          # Smooth torque taper approaching reverse speed limit (18 m/s = ~65 km/h)
          var rev_speed_ratio: float = clampf(maxf(-v_long, 0.0) / MAX_REVERSE_SPEED_MPS, 0.0, 1.0)
          var limiter_scale: float = 1.0 - pow(rev_speed_ratio, 3.0)
          
          fx = -absf(reverse_drive_force) * limiter_scale
          slip_ratio = clampf(fx / maxf(max_friction_n, 1.0), -0.55, 0.0)
  ```

#### 2. In `ArcadeSimVehicle.gd`:
- In `_evaluate_engine_torque`:
  ```gdscript
  if is_reversing:
      # Smooth, naturally-aspirated low-compression reverse throttle (no turbo surge)
      boost_multiplier = 0.65
  ```
- Ensure `max_reverse_speed` is maintained at a safe, stable threshold (16.0 to 18.0 m/s).

---

### OUTPUT FORMAT:
Provide the updated reverse force calculation block for `TougeDriftPhysicsSolver.gd` and the reverse torque block for `ArcadeSimVehicle.gd`.
