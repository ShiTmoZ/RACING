class_name ItashaAnimeGirlLivery
extends Node3D

## Procedural Itasha (痛車) Anime Girl Livery Generator for Godot 4.3 Forward+
## Uses runtime SVG rasterization via Image.load_svg_from_string() and Forward+ Decal nodes.

@export var hood_decal_size: Vector3 = Vector3(1.4, 1.0, 1.4)
@export var hood_decal_offset: Vector3 = Vector3(0.0, 0.85, -1.35)
@export var side_decal_size: Vector3 = Vector3(0.8, 1.15, 2.4)
@export var side_decal_offset: Vector3 = Vector3(0.85, 0.55, 0.05)
@export var emission_energy: float = 0.65
@export var render_scale: float = 2.0 # 2.0 produces crisp 2048x2048 textures from 1024x1024 SVG

static var _cached_hood_tex: ImageTexture = null
static var _cached_left_tex: ImageTexture = null
static var _cached_right_tex: ImageTexture = null


static func attach_to_car(car_root: Node3D) -> void:
	if not is_instance_valid(car_root):
		return

	var existing: Node = car_root.find_child("ItashaAnimeGirlLivery", false, false)
	if existing != null:
		existing.queue_free()

	var livery_script: GDScript = load("res://ItashaAnimeGirlLivery.gd") as GDScript
	var livery = livery_script.new()
	livery.name = "ItashaAnimeGirlLivery"
	car_root.add_child(livery)
	livery.apply_livery(car_root)


func apply_livery(car_root: Node3D) -> void:
	_ensure_textures_generated(render_scale)

	var aabb: AABB = _calculate_chassis_aabb(car_root)
	var computed_hood_pos: Vector3 = hood_decal_offset
	var computed_side_pos: Vector3 = side_decal_offset

	if aabb.size.length_squared() > 0.1:
		var center: Vector3 = aabb.get_center()
		computed_hood_pos = Vector3(
			center.x,
			aabb.position.y + aabb.size.y * 0.68,
			center.z - aabb.size.z * 0.28
		)
		computed_side_pos = Vector3(
			aabb.size.x * 0.48,
			aabb.position.y + aabb.size.y * 0.42,
			center.z + aabb.size.z * 0.02
		)

	# 1. Hood Decal (کاپوت) - Projected downwards onto the hood
	var hood_decal := Decal.new()
	hood_decal.name = "ItashaHoodDecal"
	hood_decal.texture_albedo = _cached_hood_tex
	hood_decal.texture_emission = _cached_hood_tex
	hood_decal.emission_energy = emission_energy
	hood_decal.size = hood_decal_size
	hood_decal.position = computed_hood_pos
	hood_decal.upper_fade = 0.2
	hood_decal.lower_fade = 0.2
	hood_decal.normal_fade = 0.35
	hood_decal.cull_mask = 0xFFFFF
	add_child(hood_decal)

	# 2. Left Door / Quarter Panel Decal - Projected inwards from -X to +X
	# Decal projects along its local -Y axis.
	# Basis: Local +X -> Global +Z (front/rear), Local -Y -> Global +X (inward), Local -Z -> Global +Y (up)
	var left_decal := Decal.new()
	left_decal.name = "ItashaLeftSideDecal"
	left_decal.texture_albedo = _cached_left_tex
	left_decal.texture_emission = _cached_left_tex
	left_decal.emission_energy = emission_energy
	left_decal.size = Vector3(side_decal_size.z, side_decal_size.x, side_decal_size.y)
	left_decal.position = Vector3(-computed_side_pos.x, computed_side_pos.y, computed_side_pos.z)
	left_decal.basis = Basis(
		Vector3(0.0, 0.0, 1.0),
		Vector3(-1.0, 0.0, 0.0),
		Vector3(0.0, -1.0, 0.0)
	)
	left_decal.upper_fade = 0.2
	left_decal.lower_fade = 0.2
	left_decal.normal_fade = 0.45
	left_decal.cull_mask = 0xFFFFF
	add_child(left_decal)

	# 3. Right Door / Quarter Panel Decal - Projected inwards from +X to -X
	# Basis: Local +X -> Global -Z, Local -Y -> Global -X (inward), Local -Z -> Global +Y (up)
	var right_decal := Decal.new()
	right_decal.name = "ItashaRightSideDecal"
	right_decal.texture_albedo = _cached_right_tex
	right_decal.texture_emission = _cached_right_tex
	right_decal.emission_energy = emission_energy
	right_decal.size = Vector3(side_decal_size.z, side_decal_size.x, side_decal_size.y)
	right_decal.position = Vector3(computed_side_pos.x, computed_side_pos.y, computed_side_pos.z)
	right_decal.basis = Basis(
		Vector3(0.0, 0.0, -1.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, -1.0, 0.0)
	)
	right_decal.upper_fade = 0.2
	right_decal.lower_fade = 0.2
	right_decal.normal_fade = 0.45
	right_decal.cull_mask = 0xFFFFF
	add_child(right_decal)


static func _ensure_textures_generated(scale_factor: float) -> void:
	if _cached_hood_tex != null and _cached_left_tex != null and _cached_right_tex != null:
		return

	var svg_hood: String = _build_itasha_svg(false)
	var img_hood := Image.new()
	var err_hood: Error = img_hood.load_svg_from_string(svg_hood, scale_factor)
	if err_hood == OK:
		img_hood.generate_mipmaps()
		_cached_hood_tex = ImageTexture.create_from_image(img_hood)
	else:
		_cached_hood_tex = _create_fallback_texture()

	var svg_side: String = _build_itasha_svg(true)
	var img_left := Image.new()
	var err_left: Error = img_left.load_svg_from_string(svg_side, scale_factor)
	if err_left == OK:
		img_left.generate_mipmaps()
		_cached_left_tex = ImageTexture.create_from_image(img_left)

		# Create a horizontally flipped copy for the opposite side so the anime girl faces forward on both doors
		var img_right := Image.new()
		img_right.copy_from(img_left)
		img_right.flip_x()
		img_right.generate_mipmaps()
		_cached_right_tex = ImageTexture.create_from_image(img_right)
	else:
		_cached_left_tex = _cached_hood_tex
		_cached_right_tex = _cached_hood_tex


static func _create_fallback_texture() -> ImageTexture:
	var img := Image.create_empty(512, 512, true, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 0.0, 0.55, 1.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _calculate_chassis_aabb(root: Node3D) -> AABB:
	var combined := AABB()
	var found_first: bool = false
	var stack: Array[Node] = [root]

	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D:
			var mi := current as MeshInstance3D
			var node_name: String = mi.name.to_lower()
			var is_wheel: bool = node_name.contains("wheel") or node_name.contains("tire") or node_name.contains("rim")
			if not is_wheel and mi.mesh != null:
				var local_aabb: AABB = mi.mesh.get_aabb()
				var rel_xform: Transform3D = root.global_transform.affine_inverse() * mi.global_transform
				var transformed_aabb: AABB = rel_xform * local_aabb
				if not found_first:
					combined = transformed_aabb
					found_first = true
				else:
					combined = combined.merge(transformed_aabb)
		for child in current.get_children():
			stack.push_back(child)

	return combined


static func _build_itasha_svg(is_side_panel: bool) -> String:
	var character_transform: String = "translate(0, 0)"
	var banner_group: String = ""

	if is_side_panel:
		character_transform = "translate(85, 20) scale(0.92)"
		banner_group = """
		<g id="SideRacingGraphic">
			<!-- Diagonal Racing Tear Vinyls -->
			<polygon points="0,320 680,140 620,380 0,560" fill="url(#cyanGrad)" stroke="#0A001A" stroke-width="12"/>
			<polygon points="0,510 740,310 680,530 0,740" fill="url(#magGrad)" stroke="#0A001A" stroke-width="12"/>
			<polygon points="20,680 780,470 740,620 0,830" fill="#FFE600" stroke="#0A001A" stroke-width="10"/>
			<!-- Checkered Racing Flag Accent -->
			<g transform="translate(50, 340) skewX(-25) rotate(-14)">
				<rect x="0" y="0" width="60" height="60" fill="#FFFFFF"/>
				<rect x="60" y="0" width="60" height="60" fill="#0A001A"/>
				<rect x="120" y="0" width="60" height="60" fill="#FFFFFF"/>
				<rect x="180" y="0" width="60" height="60" fill="#0A001A"/>
				<rect x="0" y="60" width="60" height="60" fill="#0A001A"/>
				<rect x="60" y="60" width="60" height="60" fill="#FFFFFF"/>
				<rect x="120" y="60" width="60" height="60" fill="#0A001A"/>
				<rect x="180" y="60" width="60" height="60" fill="#FFFFFF"/>
			</g>
			<!-- Side Kanji & Number Plate -->
			<g transform="translate(45, 580) rotate(-14)">
				<rect x="0" y="0" width="350" height="150" rx="18" fill="#0A001A" stroke="#00F0FF" stroke-width="8"/>
				<rect x="12" y="12" width="326" height="126" rx="10" fill="#FF0055"/>
				<text x="175" y="112" font-family="Impact, Arial Black, sans-serif" font-weight="900" font-size="110" fill="#FFFFFF" stroke="#0A001A" stroke-width="8" text-anchor="middle">86</text>
			</g>
			<text x="55" y="255" transform="rotate(-14, 55, 255)" font-family="Impact, Arial Black, sans-serif" font-weight="900" font-size="95" fill="#FFE600" stroke="#0A001A" stroke-width="14">藤原とうふ店</text>
			<text x="55" y="255" transform="rotate(-14, 55, 255)" font-family="Impact, Arial Black, sans-serif" font-weight="900" font-size="95" fill="#FFFFFF">藤原とうふ店</text>
			<text x="80" y="885" transform="rotate(-14, 80, 885)" font-family="Impact, Arial Black, sans-serif" font-weight="900" font-size="78" fill="#00F0FF" stroke="#0A001A" stroke-width="14">プロジェクトD // 痛車</text>
		</g>
		"""
	else:
		banner_group = """
		<g id="HoodRacingGraphic">
			<!-- Hood V-Shape Cyber Frame -->
			<polygon points="512,995 70,560 155,105 512,240 869,105 954,560" fill="url(#bgShield)" stroke="#00F0FF" stroke-width="14"/>
			<polygon points="512,955 110,545 185,145 512,275 839,145 914,545" fill="none" stroke="#FF007F" stroke-width="8" stroke-dasharray="36,16"/>
			<!-- Top & Bottom Typography Banners -->
			<g transform="translate(512, 115)">
				<polygon points="-410,-55 410,-55 375,35 -375,35" fill="#0A001A" stroke="#FFE600" stroke-width="8"/>
				<text x="0" y="14" font-family="Impact, Arial Black, sans-serif" font-weight="900" font-size="68" fill="#00F0FF" stroke="#0A001A" stroke-width="6" text-anchor="middle" letter-spacing="6">AKINA SPEED STARS // 峠</text>
			</g>
		</g>
		"""

	var svg: String = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
	<defs>
		<linearGradient id="bgShield" x1="0%" y1="0%" x2="100%" y2="100%">
			<stop offset="0%" stop-color="#19002E" stop-opacity="0.96"/>
			<stop offset="50%" stop-color="#090014" stop-opacity="0.96"/>
			<stop offset="100%" stop-color="#28003E" stop-opacity="0.96"/>
		</linearGradient>
		<linearGradient id="magGrad" x1="0%" y1="0%" x2="100%" y2="100%">
			<stop offset="0%" stop-color="#FF007F"/>
			<stop offset="50%" stop-color="#FF0055"/>
			<stop offset="100%" stop-color="#99004D"/>
		</linearGradient>
		<linearGradient id="cyanGrad" x1="0%" y1="0%" x2="100%" y2="100%">
			<stop offset="0%" stop-color="#00FFFF"/>
			<stop offset="60%" stop-color="#00BFFF"/>
			<stop offset="100%" stop-color="#0055FF"/>
		</linearGradient>
		<linearGradient id="hairMain" x1="0%" y1="0%" x2="0%" y2="100%">
			<stop offset="0%" stop-color="#FF55B8"/>
			<stop offset="45%" stop-color="#FF007F"/>
			<stop offset="85%" stop-color="#B8006B"/>
			<stop offset="100%" stop-color="#00F0FF"/>
		</linearGradient>
		<linearGradient id="hairLeft" x1="100%" y1="0%" x2="0%" y2="100%">
			<stop offset="0%" stop-color="#FF2A9D"/>
			<stop offset="60%" stop-color="#C80064"/>
			<stop offset="100%" stop-color="#00FFFF"/>
		</linearGradient>
		<linearGradient id="hairRight" x1="0%" y1="0%" x2="100%" y2="100%">
			<stop offset="0%" stop-color="#FF2A9D"/>
			<stop offset="60%" stop-color="#C80064"/>
			<stop offset="100%" stop-color="#00FFFF"/>
		</linearGradient>
		<linearGradient id="skinGrad" x1="0%" y1="0%" x2="0%" y2="100%">
			<stop offset="0%" stop-color="#FFF2EC"/>
			<stop offset="75%" stop-color="#FFE1D6"/>
			<stop offset="100%" stop-color="#FFC4B2"/>
		</linearGradient>
		<linearGradient id="eyeIris" x1="0%" y1="0%" x2="0%" y2="100%">
			<stop offset="0%" stop-color="#550066"/>
			<stop offset="35%" stop-color="#CC0077"/>
			<stop offset="75%" stop-color="#00F0FF"/>
			<stop offset="100%" stop-color="#AAFFFF"/>
		</linearGradient>
		<linearGradient id="visorGrad" x1="0%" y1="0%" x2="100%" y2="0%">
			<stop offset="0%" stop-color="#00F0FF" stop-opacity="0.88"/>
			<stop offset="50%" stop-color="#FF00AA" stop-opacity="0.88"/>
			<stop offset="100%" stop-color="#FFE600" stop-opacity="0.88"/>
		</linearGradient>
	</defs>

	<!-- Speedlines & Starbursts Background -->
	<g id="DynamicVinylBacking">
		<polygon points="512,512 40,20 150,20" fill="#00F0FF" opacity="0.85"/>
		<polygon points="512,512 980,40 870,20" fill="#FF007F" opacity="0.85"/>
		<polygon points="512,512 20,420 20,510" fill="#FFE600" opacity="0.9"/>
		<polygon points="512,512 1004,380 1004,480" fill="#00F0FF" opacity="0.9"/>
		<polygon points="512,512 30,860 120,940" fill="#FF007F" opacity="0.85"/>
		<polygon points="512,512 990,820 910,930" fill="#FFE600" opacity="0.85"/>
		<!-- Lightning Accents -->
		<polygon points="150,180 280,350 210,370 360,560 180,410 245,390" fill="#FFE600" stroke="#0A001A" stroke-width="8"/>
		<polygon points="880,170 750,340 820,360 670,550 850,400 785,380" fill="#00F0FF" stroke="#0A001A" stroke-width="8"/>
	</g>

	""" + banner_group + """

	<!-- MAIN ANIME GIRL CHARACTER LAYER -->
	<g id="AnimeGirlCharacter" transform=\"""" + character_transform + """\">

		<!-- Giant Flowing Twin-Tails (Back Layer) -->
		<g id="TwinTails" stroke="#0A001A" stroke-width="11" stroke-linejoin="round" stroke-linecap="round">
			<!-- Left Twin-Tail -->
			<path d="M 330,290 C 150,240 40,400 35,640 C 30,780 95,910 155,950 C 125,830 135,710 175,620 C 150,740 190,860 255,915 C 225,790 235,660 285,550 C 265,640 285,730 335,785 C 325,650 350,490 380,360 Z" fill="url(#hairLeft)"/>
			<!-- Left Twin-Tail Cyan Neon Streaks -->
			<path d="M 270,340 C 155,390 95,550 110,760 C 135,630 175,510 265,420 Z" fill="#00F0FF" stroke="none"/>
			<path d="M 310,410 C 230,490 205,640 235,810 C 250,670 280,550 330,460 Z" fill="#FFE600" stroke="none"/>

			<!-- Right Twin-Tail -->
			<path d="M 694,290 C 874,240 984,400 989,640 C 994,780 929,910 869,950 C 899,830 889,710 849,620 C 874,740 834,860 769,915 C 799,790 789,660 739,550 C 759,640 739,730 689,785 C 699,650 674,490 644,360 Z" fill="url(#hairRight)"/>
			<!-- Right Twin-Tail Cyan Neon Streaks -->
			<path d="M 754,340 C 869,390 929,550 914,760 C 889,630 849,510 759,420 Z" fill="#00F0FF" stroke="none"/>
			<path d="M 714,410 C 794,490 819,640 789,810 C 774,670 744,550 694,460 Z" fill="#FFE600" stroke="none"/>
		</g>

		<!-- Cyber-Sailor Racing Jacket & Torso -->
		<g id="TorsoAndJacket" stroke="#0A001A" stroke-width="11" stroke-linejoin="round">
			<!-- Neck & Shoulders -->
			<path d="M 465,610 L 465,715 L 350,750 L 674,750 L 559,715 L 559,610 Z" fill="url(#skinGrad)"/>
			<!-- Neck Anime Cast Shadow -->
			<path d="M 465,625 C 495,665 529,665 559,625 L 559,675 C 525,695 499,695 465,675 Z" fill="#E59888" stroke="none"/>
			<!-- Choker Collar -->
			<path d="M 462,670 Q 512,692 562,670 L 564,695 Q 512,717 460,695 Z" fill="#0A001A" stroke="#00F0FF" stroke-width="4"/>
			<circle cx="512" cy="698" r="14" fill="#FFE600" stroke="#0A001A" stroke-width="5"/>

			<!-- Racing Jacket Outer Body -->
			<path d="M 255,960 L 315,720 L 425,695 L 512,795 L 599,695 L 709,720 L 769,960 Z" fill="#120824"/>
			<!-- Sailor / Cyber Collar Flaps -->
			<path d="M 335,725 L 430,695 L 512,815 L 395,845 Z" fill="url(#cyanGrad)"/>
			<path d="M 689,725 L 594,695 L 512,815 L 629,845 Z" fill="url(#cyanGrad)"/>
			<!-- Center Ribbon Bow -->
			<polygon points="512,805 425,765 440,855" fill="#FF0055"/>
			<polygon points="512,805 599,765 584,855" fill="#FF0055"/>
			<polygon points="512,810 465,945 502,945" fill="#FF0055"/>
			<polygon points="512,810 559,945 522,945" fill="#FF0055"/>
			<circle cx="512" cy="805" r="24" fill="#FFE600"/>
		</g>

		<!-- Rear Head Hair Base -->
		<path d="M 295,430 C 275,230 390,145 512,145 C 634,145 749,230 729,430 C 715,540 665,635 615,675 L 409,675 C 359,635 309,540 295,430 Z" fill="url(#hairMain)" stroke="#0A001A" stroke-width="11" stroke-linejoin="round"/>

		<!-- Mechanical / Neko Twin-Tail Hair Clips -->
		<g id="HairClips" stroke="#0A001A" stroke-width="10" stroke-linejoin="round">
			<polygon points="335,310 235,210 275,355" fill="#0A001A"/>
			<polygon points="325,300 255,230 282,335" fill="#00F0FF" stroke="none"/>
			<polygon points="355,275 305,245 320,335" fill="#FF0055"/>
			<polygon points="689,310 789,210 749,355" fill="#0A001A"/>
			<polygon points="699,300 769,230 742,335" fill="#00F0FF" stroke="none"/>
			<polygon points="669,275 719,245 704,335" fill="#FF0055"/>
		</g>

		<!-- Anime Face & Ears -->
		<g id="FaceBase">
			<!-- Left & Right Ears -->
			<path d="M 325,475 C 285,465 280,535 338,560 Z" fill="url(#skinGrad)" stroke="#0A001A" stroke-width="10" stroke-linejoin="round"/>
			<path d="M 699,475 C 739,465 744,535 686,560 Z" fill="url(#skinGrad)" stroke="#0A001A" stroke-width="10" stroke-linejoin="round"/>
			<!-- Main Chin / Jawline -->
			<path d="M 332,375 C 330,495 348,572 415,622 C 455,650 488,668 512,670 C 536,668 569,650 609,622 C 676,572 694,495 692,375 C 690,265 610,220 512,220 C 414,220 334,265 332,375 Z" fill="url(#skinGrad)" stroke="#0A001A" stroke-width="11" stroke-linejoin="round"/>
		</g>

		<!-- Anime Cheek Blush & Manga Slash Lines -->
		<g id="AnimeBlush">
			<ellipse cx="392" cy="542" rx="44" ry="20" fill="#FF2A85" opacity="0.55"/>
			<ellipse cx="632" cy="542" rx="44" ry="20" fill="#FF2A85" opacity="0.55"/>
			<g stroke="#FF0055" stroke-width="4.5" stroke-linecap="round">
				<line x1="365" y1="534" x2="353" y2="552"/>
				<line x1="385" y1="532" x2="373" y2="554"/>
				<line x1="405" y1="534" x2="393" y2="552"/>
				<line x1="619" y1="534" x2="607" y2="552"/>
				<line x1="639" y1="532" x2="627" y2="554"/>
				<line x1="659" y1="534" x2="647" y2="552"/>
			</g>
			<!-- Stylized Nose Cheek Highlight -->
			<ellipse cx="368" cy="522" rx="10" ry="5" fill="#FFFFFF" opacity="0.85"/>
			<ellipse cx="656" cy="522" rx="10" ry="5" fill="#FFFFFF" opacity="0.85"/>
		</g>

		<!-- Large Expressive Anime Eyes -->
		<g id="AnimeEyes">
			<!-- LEFT EYE (Viewer's Left) -->
			<g id="LeftEye">
				<!-- Sclera (White) -->
				<path d="M 356,455 C 372,412 448,412 468,460 C 464,518 442,536 410,536 C 374,536 356,506 356,455 Z" fill="#FFFFFF" stroke="#0A001A" stroke-width="7"/>
				<!-- Iris Base -->
				<ellipse cx="416" cy="478" rx="41" ry="50" fill="url(#eyeIris)" stroke="#0A001A" stroke-width="5"/>
				<!-- Upper Iris Shadow -->
				<path d="M 376,465 C 390,425 442,425 456,465 C 435,455 395,455 376,465 Z" fill="#2A0044" opacity="0.75"/>
				<!-- Lower Glowing Cyan Crescent -->
				<path d="M 384,492 C 396,526 436,526 448,492 C 436,510 396,510 384,492 Z" fill="#88FFFF"/>
				<!-- Pupil -->
				<ellipse cx="416" cy="480" rx="19" ry="24" fill="#140024"/>
				<ellipse cx="416" cy="480" rx="10" ry="13" fill="#FF007F"/>
				<!-- Star & Specular Catchlights -->
				<circle cx="390" cy="452" r="15" fill="#FFFFFF"/>
				<circle cx="438" cy="504" r="8" fill="#FFFFFF"/>
				<circle cx="392" cy="508" r="4.5" fill="#FFFFFF"/>
				<polygon points="436,452 440,440 444,452 456,456 444,460 440,472 436,460 424,456" fill="#FFE600"/>
				<!-- Heavy Upper Eyelash -->
				<path d="M 342,462 C 362,404 450,404 476,458 L 468,434 C 444,394 366,394 332,442 Z" fill="#0A001A"/>
				<path d="M 348,436 L 326,422 L 342,448 Z" fill="#0A001A"/>
				<!-- Eyelid Fold -->
				<path d="M 358,404 C 392,384 442,388 468,418" fill="none" stroke="#0A001A" stroke-width="5" stroke-linecap="round"/>
			</g>

			<!-- RIGHT EYE (Viewer's Right) -->
			<g id="RightEye">
				<!-- Sclera (White) -->
				<path d="M 668,455 C 652,412 576,412 556,460 C 560,518 582,536 614,536 C 650,536 668,506 668,455 Z" fill="#FFFFFF" stroke="#0A001A" stroke-width="7"/>
				<!-- Iris Base -->
				<ellipse cx="608" cy="478" rx="41" ry="50" fill="url(#eyeIris)" stroke="#0A001A" stroke-width="5"/>
				<!-- Upper Iris Shadow -->
				<path d="M 568,465 C 582,425 634,425 648,465 C 629,455 589,455 568,465 Z" fill="#2A0044" opacity="0.75"/>
				<!-- Lower Glowing Cyan Crescent -->
				<path d="M 576,492 C 588,526 628,526 640,492 C 628,510 588,510 576,492 Z" fill="#88FFFF"/>
				<!-- Pupil -->
				<ellipse cx="608" cy="480" rx="19" ry="24" fill="#140024"/>
				<ellipse cx="608" cy="480" rx="10" ry="13" fill="#FF007F"/>
				<!-- Star & Specular Catchlights -->
				<circle cx="582" cy="452" r="15" fill="#FFFFFF"/>
				<circle cx="630" cy="504" r="8" fill="#FFFFFF"/>
				<circle cx="584" cy="508" r="4.5" fill="#FFFFFF"/>
				<polygon points="628,452 632,440 636,452 648,456 636,460 632,472 628,460 616,456" fill="#FFE600"/>
				<!-- Heavy Upper Eyelash -->
				<path d="M 682,462 C 662,404 574,404 548,458 L 556,434 C 580,394 658,394 692,442 Z" fill="#0A001A"/>
				<path d="M 676,436 L 698,422 L 682,448 Z" fill="#0A001A"/>
				<!-- Eyelid Fold -->
				<path d="M 666,404 C 632,384 582,388 556,418" fill="none" stroke="#0A001A" stroke-width="5" stroke-linecap="round"/>
			</g>
		</g>

		<!-- Nose & Smug Anime Fang Mouth -->
		<g id="NoseAndMouth">
			<!-- Nose -->
			<polygon points="512,516 503,534 516,537" fill="#E59888"/>
			<line x1="512" y1="515" x2="505" y2="534" stroke="#0A001A" stroke-width="5" stroke-linecap="round"/>
			<!-- Smug Open Mouth with Cute Fang -->
			<path d="M 476,578 Q 494,590 512,578 Q 530,590 548,578 C 544,622 528,634 512,634 C 496,634 480,622 476,578 Z" fill="#990033" stroke="#0A001A" stroke-width="6.5" stroke-linejoin="round"/>
			<!-- Tongue -->
			<path d="M 486,604 Q 512,592 538,604 C 534,625 524,632 512,632 C 500,632 490,625 486,604 Z" fill="#FF5588"/>
			<!-- Cute Anime Fang -->
			<polygon points="524,581 531,599 539,581" fill="#FFFFFF" stroke="#0A001A" stroke-width="4" stroke-linejoin="round"/>
		</g>

		<!-- Front Hair Bangs &Side Locks -->
		<g id="FrontHairBangs" stroke="#0A001A" stroke-width="10" stroke-linejoin="round">
			<!-- Left & Right Cheek Framing Locks -->
			<path d="M 332,330 C 300,450 310,590 365,685 C 345,575 352,475 372,395 Z" fill="url(#hairMain)"/>
			<path d="M 692,330 C 724,450 714,590 659,685 C 679,575 672,475 652,395 Z" fill="url(#hairMain)"/>
			<!-- Main Forehead Bangs -->
			<path d="M 335,340 C 350,235 425,185 512,185 C 599,185 674,235 689,340 C 660,395 645,430 632,455 C 625,385 605,345 585,315 C 585,385 572,435 555,465 C 542,395 528,350 512,315 C 496,350 482,395 469,465 C 452,435 439,385 439,315 C 419,345 399,385 392,455 C 379,430 364,395 335,340 Z" fill="url(#hairMain)"/>
			<!-- Anime Hair Angel Halo Highlight -->
			<path d="M 375,305 Q 415,275 445,305 L 435,330 Q 410,305 385,330 Z" fill="#FFFFFF" opacity="0.88" stroke="none"/>
			<path d="M 480,290 Q 512,265 544,290 L 536,318 Q 512,298 488,318 Z" fill="#00F0FF" opacity="0.9" stroke="none"/>
			<path d="M 579,305 Q 609,275 649,305 L 639,330 Q 614,305 589,330 Z" fill="#FFFFFF" opacity="0.88" stroke="none"/>
			<!-- Top Ahoge (Cowlick) -->
			<path d="M 512,190 C 485,110 555,60 615,95 C 565,105 535,140 528,190 Z" fill="url(#hairMain)"/>
		</g>

		<!-- Expressive Eyebrows (Drawn over bangs for authentic anime style) -->
		<path d="M 358,376 Q 412,352 465,388" fill="none" stroke="#0A001A" stroke-width="11" stroke-linecap="round"/>
		<path d="M 358,376 Q 412,352 465,388" fill="none" stroke="#FF007F" stroke-width="5" stroke-linecap="round"/>
		<path d="M 666,376 Q 612,352 559,388" fill="none" stroke="#0A001A" stroke-width="11" stroke-linecap="round"/>
		<path d="M 666,376 Q 612,352 559,388" fill="none" stroke="#FF007F" stroke-width="5" stroke-linecap="round"/>

		<!-- Futuristic Touge Racing Visor / Goggles on Forehead -->
		<g id="CyberVisor" transform="translate(0, -12)">
			<path d="M 326,285 Q 512,215 698,285 L 680,362 Q 512,302 344,362 Z" fill="url(#visorGrad)" stroke="#0A001A" stroke-width="11" stroke-linejoin="round"/>
			<path d="M 360,292 Q 460,255 545,270 L 515,320 Q 435,310 370,335 Z" fill="#FFFFFF" opacity="0.55"/>
			<circle cx="348" cy="322" r="14" fill="#FFE600" stroke="#0A001A" stroke-width="6"/>
			<circle cx="676" cy="322" r="14" fill="#FFE600" stroke="#0A001A" stroke-width="6"/>
			<text x="512" y="312" font-family="Impact, Arial Black, sans-serif" font-weight="900" font-size="34" fill="#FFFFFF" stroke="#0A001A" stroke-width="5" text-anchor="middle" letter-spacing="5">AE86 // TOUGE</text>
		</g>

		<!-- Peace / V-Sign Hand Gesture (Bottom Left Foreground) -->
		<g id="PeaceHand" transform="translate(30, 15)" stroke="#0A001A" stroke-width="10" stroke-linejoin="round" stroke-linecap="round">
			<!-- Index & Middle V-Fingers -->
			<path d="M 245,790 L 185,625 C 175,595 215,580 228,610 L 285,765 Z" fill="url(#skinGrad)"/>
			<path d="M 282,775 L 275,595 C 275,565 318,565 318,598 L 325,775 Z" fill="url(#skinGrad)"/>
			<!-- Palm & Folded Fingers -->
			<ellipse cx="285" cy="835" rx="68" ry="62" fill="url(#skinGrad)"/>
			<ellipse cx="322" cy="795" rx="26" ry="34" fill="url(#skinGrad)"/>
			<ellipse cx="348" cy="818" rx="24" ry="32" fill="url(#skinGrad)"/>
			<path d="M 225,825 Q 275,785 305,815 C 315,835 285,865 235,855 Z" fill="url(#skinGrad)"/>
			<!-- Fingerless Racing Glove -->
			<path d="M 215,835 Q 285,805 352,838 L 342,925 L 225,925 Z" fill="#FF0055"/>
			<path d="M 220,885 L 347,885 L 342,925 L 225,925 Z" fill="#0A001A"/>
			<circle cx="285" cy="862" r="14" fill="#FFE600" stroke-width="6"/>
		</g>
	</g>

	<!-- Foreground Manga Stars, Hearts & Touge Decals -->
	<g id="ForegroundStickers">
		<!-- Star Motifs -->
		<polygon points="145,620 165,565 185,620 240,640 185,660 165,715 145,660 90,640" fill="#FFE600" stroke="#0A001A" stroke-width="9"/>
		<polygon points="865,600 882,550 899,600 950,617 899,634 882,684 865,634 815,617" fill="#00F0FF" stroke="#0A001A" stroke-width="9"/>
		<polygon points="195,155 208,118 221,155 258,168 221,181 208,218 195,181 158,168" fill="#FF007F" stroke="#0A001A" stroke-width="7"/>
		<polygon points="830,155 843,118 856,155 893,168 856,181 843,218 830,181 793,168" fill="#FFE600" stroke="#0A001A" stroke-width="7"/>

		<!-- Bottom Itasha Kanji Plate -->
		<g transform="translate(512, 935)">
			<polygon points="-445,-55 445,-55 415,50 -415,50" fill="#0A001A" stroke="#00F0FF" stroke-width="10"/>
			<polygon points="-430,-42 430,-42 404,38 -404,38" fill="#FF0055"/>
			<text x="0" y="22" font-family="Impact, Arial Black, sans-serif" font-weight="900" font-size="68" fill="#FFE600" stroke="#0A001A" stroke-width="12" text-anchor="middle" letter-spacing="4">藤原とうふ店 // NIGHT KIDS</text>
			<text x="0" y="22" font-family="Impact, Arial Black, sans-serif" font-weight="900" font-size="68" fill="#FFFFFF" text-anchor="middle" letter-spacing="4">藤原とうふ店 // NIGHT KIDS</text>
		</g>
	</g>
</svg>"""
	return svg