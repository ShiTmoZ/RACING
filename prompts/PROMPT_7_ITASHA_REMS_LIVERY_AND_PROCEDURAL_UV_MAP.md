# PROMPT 7: ITA-SHA REM'S ANIME LIVERY PROCEDURAL UV MAPPING & MATERIAL INTEGRATION
**Target Files:** `AE86TruenoModeler.gd`, `FD3SRx7Modeler.gd`, `R34SkylineModeler.gd`, `ItashaAnimeGirlLivery.gd`
**Texture Asset:** `res://textures/itasha_rem.png`
**Engine:** Godot 4.3 (GDScript 2.0)

---

### PROBLEM STATEMENT:
In the game, cars spawn with generic procedural solid colors and have **no anime design or livery visible** on their body panels ("ماشین ها هم هیچ طرح انیمه ایی ندارن").
- Cause:
  1. The procedural car mesh generators (`AE86TruenoModeler.gd`, `FD3SRx7Modeler.gd`, `R34SkylineModeler.gd`) generate car geometry via `SurfaceTool` without specifying normalized texture UV coordinates (`st.set_uv(...)`) on the hood, roof, and door panels. As a result, any texture applied to the car body displays as a solid stretched color streak.
  2. The standalone livery overlay node (`ItashaAnimeGirlLivery.gd`) spawns floating decal quads that either clip inside the chassis mesh due to convex body curvatures or fail to bind `res://textures/itasha_rem.png` properly.

---

### EXACT ARCHITECTURAL FIXES REQUIRED:

#### 1. Procedural UV Coordinates on Hood and Door Panels:
In the `SurfaceTool` methods of `AE86TruenoModeler.gd`, `FD3SRx7Modeler.gd`, and `R34SkylineModeler.gd`:
- Introduce a helper method for quad generation with UV mapping:
  ```gdscript
  func _st_add_quad_uv(st: SurfaceTool, p1: Vector3, p2: Vector3, p3: Vector3, p4: Vector3, uv1: Vector2, uv2: Vector2, uv3: Vector2, uv4: Vector2) -> void:
      var normal: Vector3 = (p2 - p1).cross(p3 - p1).normalized()
      st.set_normal(normal)
      
      st.set_uv(uv1)
      st.add_vertex(p1)
      st.set_uv(uv2)
      st.add_vertex(p2)
      st.set_uv(uv3)
      st.add_vertex(p3)
      
      st.set_uv(uv1)
      st.add_vertex(p1)
      st.set_uv(uv3)
      st.add_vertex(p3)
      st.set_uv(uv4)
      st.add_vertex(p4)
  ```
- For the **Hood (Bonnet)**:
  Map the UVs across the X (width) and Z (length) boundaries normalized from `(0.0, 0.0)` to `(1.0, 1.0)`.
- For the **Doors / Sides**:
  Map the UVs across Z (length) and Y (height) normalized from `(0.0, 0.0)` to `(1.0, 1.0)`.

#### 2. Livery Material Assignment:
- Create a dedicated livery material for the hood and sides (or update the car's primary body material):
  ```gdscript
  var livery_mat := StandardMaterial3D.new()
  livery_mat.albedo_texture = load("res://textures/itasha_rem.png")
  livery_mat.roughness = 0.25
  livery_mat.metallic = 0.15
  livery_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
  ```
- Ensure this material is applied to the SurfaceTool surface representing the hood and side livery panels, or set as `material_override`.

#### 3. ItashaAnimeGirlLivery Overlay Fallback:
In `ItashaAnimeGirlLivery.gd`:
- Ensure that the hood plate mesh is offset slightly above the hood line (Y = +0.76 for R34/FD3S, Y = +0.72 for AE86) with a downward normal, and the side door plates are offset X = ±0.91m so they never clip inside the chassis.
- Verify that `load("res://textures/itasha_rem.png")` is used directly as the material texture.

---

### OUTPUT FORMAT:
Provide the complete UV-mapping quad helper and the updated hood/livery generation blocks for `AE86TruenoModeler.gd`, `FD3SRx7Modeler.gd`, and `ItashaAnimeGirlLivery.gd`.
