# TASK: Procedural Rem (Re:Zero) Itasha Livery & Anime Shading Overhaul for Godot 4.3

## 1. PROJECT CONTEXT & ARCHITECTURE
We are developing "RACING", an arcade-sim touge racing simulator built in Godot 4.3 (Forward+ renderer, 120Hz physics).
- The player fleet contains three cars: Toyota AE86 Sprinter Trueno, Mazda RX-7 (FD3S), and Nissan Skyline GT-R (R34).
- Vehicle chassis are generated procedurally at runtime via code (in `ProceduralCarModeler.gd`, `FD3SRx7Modeler.gd`, and `R34SkylineModeler.gd`), mounted under a root Node3D named `VisualChassisRoot`.
- Standard external `Decal` nodes fail on these procedural meshes because procedural arrays lack standard secondary UV unwrapping, and decals clip during vehicle switching.
- A high-resolution PNG texture of character Rem is already saved in the project at `"res://textures/itasha_rem.png"`.

## 2. PART A: REM ITAHSA LIVERY APPLICATOR
Create or update the dedicated livery applicator (`ItashaAnimeGirlLivery.gd` or helper inside `JDMVehicleFleetManager.gd`) that directly attaches textured 3D mesh plates to `VisualChassisRoot`:
1. **Texture Loading & Material Creation**:
   - Safely load the texture from `const REM_TEX_PATH = "res://textures/itasha_rem.png"`.
   - Create a `StandardMaterial3D` with:
     - `albedo_texture = load(REM_TEX_PATH)`
     - `transparency = BaseMaterial3D.TRANSPARENCY_ALPHA`
     - `cull_mode = BaseMaterial3D.CULL_DISABLED`
     - `roughness = 0.3`
     - `metallic = 0.05`
     - `depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS`
2. **Hood Livery Plate (`MeshInstance3D`)**:
   - Mesh: `QuadMesh` with size `Vector2(1.30, 1.25)`.
   - Mount as a direct child of `VisualChassisRoot`.
   - Local Transform: position `Vector3(0.0, 0.64, -1.25)` (just above the front hood), rotation `Vector3(-8.5, 0.0, 0.0)` in degrees (pitched downward to match the slope of the hood).
3. **Door Side Livery Plates (Left & Right)**:
   - Mesh: `QuadMesh` with size `Vector2(2.30, 0.85)`.
   - Left Plate: position `Vector3(-0.84, 0.52, 0.05)`, rotation `Vector3(0.0, -90.0, 0.0)` in degrees.
   - Right Plate: position `Vector3(0.84, 0.52, 0.05)`, rotation `Vector3(0.0, 90.0, 0.0)` in degrees (flip UV or texture scale X if mirroring is desired).
4. **Lifecycle & Vehicle Swap Persistence**:
   - Expose a method `apply_livery(vehicle_root: Node3D)` that binds these plates cleanly. When switching cars (1 = AE86, 2 = R34, 3 = RX-7), it purges old plates and binds fresh ones to the newly active `VisualChassisRoot`.

## 3. PART B: ANIME MANGA MODE SHADER TOGGLE FIX (`AnimePostProcessEffect.gd`)
1. **Default Look**: Set the default visual state to clean, natural golden-hour lighting (`effect_enabled = false` by default, or disable harsh full-screen Sobel edge detection while leaving subtle toon highlights).
2. **Key Conflict**: In `_unhandled_key_input(event)`, remove `KEY_O` (reserve Key 'O' exclusively for the multiplayer lobby). Only `KEY_F2` should toggle Anime Mode.
3. **Accurate Toast Notifications**:
   - When toggled ON (heavy manga outlines): display `"[F2] MANGA INK OUTLINES: ACTIVE"`.
   - When toggled OFF (clean visual state): display `"[F2] TOUGE VISUALS: CLEAN / CRISP"`.

Provide the complete, self-contained, and error-free GDScript files.
