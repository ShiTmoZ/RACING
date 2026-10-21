class_name ItashaAnimeGirlLivery
extends Node3D

## Rem (Re:Zero) Itasha Racing Livery Generator & Decal Projector
## Designed for Godot 4.3 Forward+ (AE86 / JDM Coupes)

const REM_TEXTURE_PATH: String = "res://textures/itasha_rem.png"

# Livery Color Palette (Rem Theme)
const COLOR_SKY_BLUE: String = "#4AB3F4"
const COLOR_DEEP_BLUE: String = "#1B4965"
const COLOR_MIDNIGHT: String = "#0D1B2A"
const COLOR_SAKURA_PINK: String = "#FF70A6"
const COLOR_CRYSTAL_WHITE: String = "#FFFFFF"

## Visual layer mask for the car body mesh so decals do not project onto glass, tires, or the road.
@export_flags_3d_render var car_body_cull_mask: int = 0xFFFFF

static var _cached_hood_tex: Texture2D = null
static var _cached_side_l_tex: Texture2D = null
static var _cached_side_r_tex: Texture2D = null


## Main entry point: Attaches the complete Rem Itasha decal rig to a car root Node3D.
static func attach_to_car(car_root: Node3D) -> Node:
	if not is_instance_valid(car_root):
		push_error("ItashaAnimeGirlLivery: Provided car_root is invalid.")
		return null

	# Remove existing livery node if present to support hot-reloading
	var existing := car_root.get_node_or_null("ItashaAnimeGirlLivery")
	if existing:
		existing.queue_free()

	var livery_script: GDScript = load("res://ItashaAnimeGirlLivery.gd") as GDScript
	var livery = livery_script.new()
	livery.name = "ItashaAnimeGirlLivery"
	car_root.add_child(livery)
	livery.build_livery()
	return livery


func _ready() -> void:
	if get_child_count() == 0:
		build_livery()


## Builds the textures (if not cached) and spawns the 3D Decal projection nodes.
func build_livery() -> void:
	_ensure_textures_generated()

	# Clear any existing decals
	for child in get_children():
		child.queue_free()

	# -------------------------------------------------------------------------
	# 1. HOOD DECAL (Projects straight down -Y onto the front hood)
	# -------------------------------------------------------------------------
	var hood_decal := Decal.new()
	hood_decal.name = "Decal_Hood_Rem"
	hood_decal.texture_albedo = _cached_hood_tex
	# Size: X = width across hood, Y = projection depth, Z = length along hood
	hood_decal.size = Vector3(1.38, 0.55, 1.38)
	# Position: Centered on X, raised slightly above hood on Y, forward on Z (-Z is forward)
	hood_decal.position = Vector3(0.0, 0.82, -1.28)
	# Slight pitch angle to match the sloped AE86 hood profile
	hood_decal.rotation_degrees = Vector3(-6.0, 0.0, 0.0)
	hood_decal.upper_fade = 0.15
	hood_decal.lower_fade = 0.15
	hood_decal.normal_fade = 0.45 # Prevents bleeding onto vertical front bumper edges
	hood_decal.albedo_mix = 1.0
	hood_decal.cull_mask = car_body_cull_mask
	add_child(hood_decal)

	# -------------------------------------------------------------------------
	# 2. LEFT SIDE DECAL (Projects inward along +X onto left doors & quarter panel)
	# -------------------------------------------------------------------------
	var left_decal := Decal.new()
	left_decal.name = "Decal_Side_Left_Rem"
	left_decal.texture_albedo = _cached_side_l_tex
	# Local Decal space: X = horizontal length (car Z), Y = projection depth (car X), Z = height (car Y)
	left_decal.size = Vector3(3.15, 0.50, 0.92)
	left_decal.position = Vector3(-0.78, 0.54, 0.05)
	# Rotate so local -Y points toward +X (into the left side of the car), and local -Z is UP (+Y)
	left_decal.rotation_degrees = Vector3(90.0, -90.0, 0.0)
	left_decal.upper_fade = 0.1
	left_decal.lower_fade = 0.2
	left_decal.normal_fade = 0.55 # Prevents wrapping onto the roof or underbody
	left_decal.albedo_mix = 1.0
	left_decal.cull_mask = car_body_cull_mask
	add_child(left_decal)

	# -------------------------------------------------------------------------
	# 3. RIGHT SIDE DECAL (Projects inward along -X onto right doors & quarter panel)
	# -------------------------------------------------------------------------
	var right_decal := Decal.new()
	right_decal.name = "Decal_Side_Right_Rem"
	right_decal.texture_albedo = _cached_side_r_tex
	right_decal.size = Vector3(3.15, 0.50, 0.92)
	right_decal.position = Vector3(0.78, 0.54, 0.05)
	# Rotate so local -Y points toward -X (into the right side of the car), and local -Z is UP (+Y)
	right_decal.rotation_degrees = Vector3(90.0, 90.0, 0.0)
	right_decal.upper_fade = 0.1
	right_decal.lower_fade = 0.2
	right_decal.normal_fade = 0.55
	right_decal.albedo_mix = 1.0
	right_decal.cull_mask = car_body_cull_mask
	add_child(right_decal)


## Loads `res://textures/itasha_rem.png` and composites it with procedural SVG racing graphics.
static func _ensure_textures_generated() -> void:
	if _cached_hood_tex != null and _cached_side_l_tex != null and _cached_side_r_tex != null:
		return

	var rem_portrait_img: Image = _load_or_generate_rem_portrait()

	_cached_hood_tex = _build_hood_texture(rem_portrait_img)
	_cached_side_l_tex = _build_side_texture(rem_portrait_img, false)
	_cached_side_r_tex = _build_side_texture(rem_portrait_img, true)


## Attempts to load the pre-bundled PNG texture; falls back to an SVG portrait if missing.
static func _load_or_generate_rem_portrait() -> Image:
	if ResourceLoader.exists(REM_TEXTURE_PATH):
		var tex: Texture2D = load(REM_TEXTURE_PATH)
		if tex != null and tex.get_image() != null:
			var img: Image = tex.get_image().duplicate()
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			_apply_circular_feather_mask(img)
			return img

	# Direct Image.load fallback if not yet imported by the editor
	if FileAccess.file_exists(REM_TEXTURE_PATH):
		var raw_img := Image.new()
		if raw_img.load(REM_TEXTURE_PATH) == OK:
			raw_img.convert(Image.FORMAT_RGBA8)
			_apply_circular_feather_mask(raw_img)
			return raw_img

	push_warning("ItashaAnimeGirlLivery: '%s' not found. Generating procedural Rem SVG fallback." % REM_TEXTURE_PATH)
	return _generate_procedural_rem_portrait(768, 768)


## Applies a soft oval vignette and removes green-screen/foliage background edges if the source is opaque.
static func _apply_circular_feather_mask(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var cx := w * 0.5
	var cy := h * 0.5
	var rx := w * 0.48
	var ry := h * 0.48

	for y in range(h):
		var dy := (float(y) - cy) / ry
		for x in range(w):
			var dx := (float(x) - cx) / rx
			var dist := sqrt(dx * dx + dy * dy)
			var col := img.get_pixel(x, y)

			# Soft feather at the oval boundary so rectangular screenshots blend cleanly into the livery
			var radial_alpha := clampf((1.0 - dist) / 0.18, 0.0, 1.0)
			radial_alpha = radial_alpha * radial_alpha * (3.0 - 2.0 * radial_alpha) # Smoothstep

			# Subtle key out of pure foliage greens near the outer edge (for anime screenshot inputs)
			var green_dominance := col.g - maxf(col.r, col.b)
			if green_dominance > 0.08 and dist > 0.45:
				var green_key := clampf(1.0 - (green_dominance - 0.08) * 5.0, 0.0, 1.0)
				radial_alpha *= green_key

			col.a *= radial_alpha
			img.set_pixel(x, y, col)


## Builds the 1024x1024 Hood Livery Texture.
static func _build_hood_texture(rem_img: Image) -> ImageTexture:
	var bg_svg := """
	<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
		<defs>
			<linearGradient id="skyGrad" x1="0%" y1="0%" x2="100%" y2="100%">
				<stop offset="0%" stop-color="#4AB3F4" stop-opacity="0.95"/>
				<stop offset="55%" stop-color="#1B4965" stop-opacity="0.90"/>
				<stop offset="100%" stop-color="#0D1B2A" stop-opacity="0.95"/>
			</linearGradient>
			<linearGradient id="pinkAccent" x1="0%" y1="0%" x2="100%" y2="0%">
				<stop offset="0%" stop-color="#FF70A6" stop-opacity="0.95"/>
				<stop offset="100%" stop-color="#FF99C8" stop-opacity="0.85"/>
			</linearGradient>
		</defs>

		<!-- Outer Shield / Hood Crest -->
		<polygon points="512,960 120,620 180,90 512,150 844,90 904,620" fill="url(#skyGrad)" stroke="#FFFFFF" stroke-width="14"/>
		<polygon points="512,915 160,600 210,125 512,180 814,125 864,600" fill="none" stroke="#FF70A6" stroke-width="6" stroke-dasharray="28,12"/>

		<!-- Dynamic Diagonal Speed Slash -->
		<polygon points="90,340 934,190 910,275 110,425" fill="#FFFFFF" fill-opacity="0.88"/>
		<polygon points="110,445 914,295 895,345 125,495" fill="url(#pinkAccent)"/>

		<!-- Maid Headband Frill Geometric Motifs -->
		<g fill="#FFFFFF" stroke="#0D1B2A" stroke-width="4" opacity="0.9">
			<polygon points="240,140 280,110 310,155 265,175"/>
			<polygon points="325,150 365,120 395,165 350,185"/>
			<polygon points="784,140 744,110 714,155 759,175"/>
			<polygon points="699,150 659,120 629,165 674,185"/>
		</g>
	</svg>
	"""

	var canvas := Image.create(1024, 1024, true, Image.FORMAT_RGBA8)
	canvas.load_svg_from_string(bg_svg)

	# Composite Rem Portrait into the center of the hood crest
	var portrait := rem_img.duplicate()
	portrait.resize(680, 680, Image.INTERPOLATE_LANCZOS)
	canvas.blend_rect(portrait, Rect2i(0, 0, 680, 680), Vector2i(172, 165))

	# Foreground Overlay SVG (Typography, Hairpin Crosses, Racing Number & Framing)
	var fg_svg := """
	<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
		<!-- Rem's Signature Pink Hairpin Crosses (Top Right) -->
		<g stroke="#FF70A6" stroke-width="18" stroke-linecap="round">
			<line x1="690" y1="210" x2="820" y2="290"/>
			<line x1="795" y1="190" x2="715" y2="315"/>
		</g>
		<g stroke="#FFFFFF" stroke-width="5" stroke-linecap="round">
			<line x1="690" y1="210" x2="820" y2="290"/>
			<line x1="795" y1="190" x2="715" y2="315"/>
		</g>

		<!-- Lower Banner Ribbon -->
		<polygon points="210,735 814,735 774,835 250,835" fill="#0D1B2A" stroke="#4AB3F4" stroke-width="8"/>
		<polygon points="235,750 789,750 760,820 264,820" fill="none" stroke="#FFFFFF" stroke-width="3"/>

		<!-- Typography: REM & RE:ZERO -->
		<text x="512" y="808" font-family="sans-serif" font-size="68" font-weight="900" fill="#FFFFFF" stroke="#4AB3F4" stroke-width="2" text-anchor="middle" letter-spacing="10">REM // レム</text>
		<text x="512" y="885" font-family="sans-serif" font-size="34" font-weight="bold" fill="#FFFFFF" stroke="#0D1B2A" stroke-width="6" paint-order="stroke" text-anchor="middle" letter-spacing="6">STARTING LIFE IN ANOTHER WORLD</text>
		<text x="512" y="128" font-family="sans-serif" font-size="36" font-weight="900" fill="#FFFFFF" stroke="#0D1B2A" stroke-width="7" paint-order="stroke" text-anchor="middle" letter-spacing="8">AKINA SPEED STARS // 02</text>
	</svg>
	"""

	var fg_img := Image.create(1024, 1024, true, Image.FORMAT_RGBA8)
	fg_img.load_svg_from_string(fg_svg)
	canvas.blend_rect(fg_img, Rect2i(0, 0, 1024, 1024), Vector2i.ZERO)

	canvas.generate_mipmaps()
	return ImageTexture.create_from_image(canvas)


## Builds the 2048x1024 Side Livery Texture.
## When `is_right_side` is true, graphics and portrait are arranged so Rem always faces the front bumper,
## while keeping all typography readable left-to-right.
static func _build_side_texture(rem_img: Image, is_right_side: bool) -> ImageTexture:
	var bg_svg_left := """
	<svg width="2048" height="1024" viewBox="0 0 2048 1024" xmlns="http://www.w3.org/2000/svg">
		<defs>
			<linearGradient id="sideBlue" x1="0%" y1="0%" x2="100%" y2="0%">
				<stop offset="0%" stop-color="#0D1B2A" stop-opacity="0.95"/>
				<stop offset="45%" stop-color="#4AB3F4" stop-opacity="0.95"/>
				<stop offset="100%" stop-color="#FFFFFF" stop-opacity="0.92"/>
			</linearGradient>
		</defs>

		<!-- Main Sweeping Aerodynamic Vector Stripes (Left Side: Front is Left, Rear is Right) -->
		<polygon points="80,680 1920,160 1980,440 160,860" fill="url(#sideBlue)" stroke="#FFFFFF" stroke-width="10"/>
		<polygon points="140,760 1950,320 1975,410 180,825" fill="#FF70A6" fill-opacity="0.92"/>
		<polygon points="60,560 1640,120 1710,185 95,625" fill="#FFFFFF" fill-opacity="0.90" stroke="#0D1B2A" stroke-width="6"/>

		<!-- Morning Star Chain / Diamond Tech Accents -->
		<g fill="#4AB3F4" stroke="#FFFFFF" stroke-width="5">
			<polygon points="360,520 420,460 480,520 420,580"/>
			<polygon points="510,480 555,435 600,480 555,525"/>
			<polygon points="630,445 665,410 700,445 665,480"/>
		</g>
	</svg>
	"""

	var canvas := Image.create(2048, 1024, true, Image.FORMAT_RGBA8)
	canvas.load_svg_from_string(bg_svg_left)

	# Prepare Rem Portrait (Positioned toward the rear quarter panel, facing forward)
	var portrait := rem_img.duplicate()
	portrait.resize(820, 820, Image.INTERPOLATE_LANCZOS)
	canvas.blend_rect(portrait, Rect2i(0, 0, 820, 820), Vector2i(1060, 90))

	# Mirror the graphic base + portrait horizontally for the right side of the car
	# so Rem and the speed stripes sweep from front-to-rear identically on both sides.
	if is_right_side:
		canvas.flip_x()

	# Overlay readable text & sponsors (drawn unflipped so text is never backwards)
	var text_x_main := 620 if not is_right_side else 1428
	var text_x_sub := 580 if not is_right_side else 1468
	var number_x := 250 if not is_right_side else 1798
	var hairpin_x := 1180 if not is_right_side else 868

	var fg_svg := """
	<svg width="2048" height="1024" viewBox="0 0 2048 1024" xmlns="http://www.w3.org/2000/svg">
		<!-- Racing Number Box near Front Door -->
		<g transform="translate(%d, 630)">
			<polygon points="-140,-110 140,-110 115,110 -165,110" fill="#0D1B2A" stroke="#FFFFFF" stroke-width="10"/>
			<polygon points="-125,-95 125,-95 103,95 -148,95" fill="none" stroke="#FF70A6" stroke-width="4"/>
			<text x="-10" y="55" font-family="sans-serif" font-size="145" font-weight="900" font-style="italic" fill="#4AB3F4" stroke="#FFFFFF" stroke-width="6" text-anchor="middle">02</text>
		</g>

		<!-- Main Character & Team Typography -->
		<text x="%d" y="420" font-family="sans-serif" font-size="135" font-weight="900" font-style="italic" fill="#FFFFFF" stroke="#0D1B2A" stroke-width="18" paint-order="stroke" text-anchor="middle" letter-spacing="6">REM // レム</text>
		<text x="%d" y="515" font-family="sans-serif" font-size="60" font-weight="900" fill="#FF70A6" stroke="#0D1B2A" stroke-width="12" paint-order="stroke" text-anchor="middle" letter-spacing="8">ゼロから始める異世界生活</text>
		<text x="%d" y="790" font-family="sans-serif" font-size="52" font-weight="900" fill="#FFFFFF" stroke="#0D1B2A" stroke-width="10" paint-order="stroke" text-anchor="middle" letter-spacing="10">AKINA SPEED STARS</text>

		<!-- Rem Hairpin Cross Accent -->
		<g transform="translate(%d, 220)" stroke="#FF70A6" stroke-width="16" stroke-linecap="round">
			<line x1="-55" y1="-35" x2="55" y2="35"/>
			<line x1="35" y1="-55" x2="-35" y2="55"/>
		</g>
	</svg>
	""" % [number_x, text_x_main, text_x_sub, text_x_sub, hairpin_x]

	var fg_img := Image.create(2048, 1024, true, Image.FORMAT_RGBA8)
	fg_img.load_svg_from_string(fg_svg)
	canvas.blend_rect(fg_img, Rect2i(0, 0, 2048, 1024), Vector2i.ZERO)

	canvas.generate_mipmaps()
	return ImageTexture.create_from_image(canvas)


## Procedural SVG fallback of Rem (Re:Zero) if `res://textures/itasha_rem.png` is missing on disk.
static func _generate_procedural_rem_portrait(width: int, height: int) -> Image:
	var svg := """
	<svg width="%d" height="%d" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">
		<!-- Soft Glowing Halo Background -->
		<circle cx="256" cy="256" r="235" fill="#4AB3F4" fill-opacity="0.25" stroke="#FFFFFF" stroke-width="8"/>

		<!-- Maid Collar & Shoulders -->
		<path d="M 110,490 Q 256,410 402,490 Z" fill="#1B4965" stroke="#0D1B2A" stroke-width="6"/>
		<path d="M 155,440 Q 256,395 357,440 L 330,495 L 182,495 Z" fill="#FFFFFF" stroke="#B8C6D8" stroke-width="5"/>

		<!-- Back Hair -->
		<circle cx="256" cy="245" r="155" fill="#5BC0BE" stroke="#1B4965" stroke-width="6"/>

		<!-- Face / Skin -->
		<path d="M 150,235 Q 150,375 256,395 Q 362,375 362,235 Z" fill="#FFF0F3" stroke="#E0B1CB" stroke-width="4"/>

		<!-- Left Visible Eye (Rem's Right Eye is covered by bangs) -->
		<ellipse cx="308" cy="282" rx="28" ry="34" fill="#FFFFFF" stroke="#0D1B2A" stroke-width="5"/>
		<ellipse cx="306" cy="285" rx="20" ry="26" fill="#2EC4B6"/>
		<circle cx="306" cy="286" r="11" fill="#0D1B2A"/>
		<circle cx="314" cy="274" r="7" fill="#FFFFFF"/>
		<path d="M 272,256 Q 308,240 342,262" fill="none" stroke="#0D1B2A" stroke-width="7" stroke-linecap="round"/>

		<!-- Soft Blush & Expression -->
		<ellipse cx="200" cy="322" rx="18" ry="9" fill="#FF70A6" fill-opacity="0.45"/>
		<ellipse cx="322" cy="322" rx="18" ry="9" fill="#FF70A6" fill-opacity="0.45"/>
		<circle cx="256" cy="352" r="5" fill="#FF70A6" stroke="#802F4E" stroke-width="2"/>

		<!-- Signature Sky-Blue Bangs Covering Right Eye -->
		<path d="M 105,230 Q 120,100 256,95 Q 390,100 405,240 L 372,330 L 348,215 L 270,215 L 265,335 L 135,335 Z" fill="#6CD4FF" stroke="#1B4965" stroke-width="5"/>

		<!-- Pink X-Hairpin & Ribbon -->
		<g stroke="#FF70A6" stroke-width="9" stroke-linecap="round">
			<line x1="288" y1="165" x2="335" y2="195"/>
			<line x1="325" y1="158" x2="295" y2="202"/>
		</g>
		<path d="M 358,145 L 395,120 L 390,165 L 358,155 L 395,180 L 385,215 L 352,175 Z" fill="#FF70A6" stroke="#802F4E" stroke-width="4"/>

		<!-- Maid Frill Headband -->
		<path d="M 145,125 Q 256,65 367,125" fill="none" stroke="#0D1B2A" stroke-width="22" stroke-linecap="round"/>
		<path d="M 140,122 Q 256,60 372,122" fill="none" stroke="#FFFFFF" stroke-width="14" stroke-dasharray="22,10" stroke-linecap="round"/>
	</svg>
	""" % [width, height]

	var img := Image.create(width, height, true, Image.FORMAT_RGBA8)
	img.load_svg_from_string(svg)
	return img