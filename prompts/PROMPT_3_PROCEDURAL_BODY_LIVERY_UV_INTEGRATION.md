# TASK: Procedural Car Body UV Mapping & Direct Rem Itasha Livery Baking for Godot 4.3

## 1. PROJECT CONTEXT & ARCHITECTURE
We are developing "RACING", an arcade-sim touge racing simulator in Godot 4.3.
- The car fleet (AE86 Trueno, RX-7 FD3S, Skyline R34) is modeled purely procedurally via GDScript `SurfaceTool` in `AE86TruenoModeler.gd`, `FD3SRx7Modeler.gd`, and `R34SkylineModeler.gd`.
- External 3D `Decal` nodes and detached floating mesh plates fail to wrap properly around curved fenders and clip during load transfers.
- Currently, when `st_hood` and door panels generate quads, `SurfaceTool.set_uv()` is never called, leaving the procedural meshes with zero UV coordinates.
- We have the high-resolution Rem (Re:Zero) livery texture ready at `"res://textures/itasha_rem.png"`.

## 2. GOAL
Inject proper UV coordinate generation into the procedural mesh generation scripts (`AE86TruenoModeler.gd` and `FD3SRx7Modeler.gd`) so that the Rem anime itasha texture is baked directly onto the hood and door body materials seamlessly.

## 3. REQUIREMENTS & IMPLEMENTATION SPECIFICATIONS

### Part A: Hood UV Generation & Material Integration in `AE86TruenoModeler.gd`
In `_build_body_sculpture()` under `# --- 1C. SCULPTED CARBON FIBER (OR FUJI WHITE) HOOD ---`:
1. Calculate normalized UV coordinates for each quad vertex:
   ```gdscript
   # u is -1.0 to +1.0 (lateral width), z is hz_start (-1.72) to hz_end (-0.68)
   var v0: float = (z0 - hz_start) / (hz_end - hz_start)
   var v1: float = (z1 - hz_start) / (hz_end - hz_start)
   var u0_norm: float = (u0 + 1.0) * 0.5
   var u1_norm: float = (u1 + 1.0) * 0.5

   var uv00 := Vector2(u0_norm, v0)
   var uv01 := Vector2(u1_norm, v0)
   var uv10 := Vector2(u0_norm, v1)
   var uv11 := Vector2(u1_norm, v1)
   ```
2. When calling `_st_add_quad(st_hood, p00, p10, p11, p01)`, ensure `st_hood.set_uv()` is called before each vertex is committed (or update `_st_add_quad_with_uv(st, p00, p10, p11, p01, uv00, uv10, uv11, uv01)`).
3. In `_build_materials()`:
   - Provide an export toggle `@export var itasha_livery_enabled: bool = true`.
   - When enabled, load `"res://textures/itasha_rem.png"` and bind it to the hood shader uniform `uniform sampler2D livery_texture : filter_linear_mipmap;` or assign it directly as `_mat_carbon_hood.set_shader_parameter("livery_texture", rem_tex)`.
   - Update the cel-shading paint shader to blend the livery texture smoothly over the body color with an adjustable opacity factor (`livery_mix = 1.0`).

### Part B: Door / Side Flank UV Generation
1. In the side body panels (doors and front/rear fenders), generate longitudinal `U` mapping along the wheelbase (`Z = -1.2 to +1.4`) and vertical `V` mapping (`Y = 0.25 to 0.85`).
2. Map the side Rem profile texture cleanly across the driver and passenger door panels without stretching.

Provide the exact, drop-in replacement methods and helper functions with full GDScript 2.0 syntax.
