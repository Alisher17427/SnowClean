extends Node3D

# Заснеженные горы на горизонте - чисто фоновая декорация, без коллизий: у каждой
# горы конус скалы (сероватый) и поменьше конус-шапка сверху (белый, снег), по кругу
# далеко за пределами игровой зоны (поле 64x64 м, лес и так стоит максимум до ~28 м
# от центра - горы должны быть заметно дальше, чтобы не соперничать с ним на глаз)

const MOUNTAIN_COUNT = 14
const RING_RADIUS_MIN = 140.0
const RING_RADIUS_MAX = 220.0
const HEIGHT_MIN = 55.0
const HEIGHT_MAX = 100.0
const BASE_RADIUS_MIN = 30.0
const BASE_RADIUS_MAX = 55.0
const SNOW_CAP_RATIO = 0.32   # доля высоты горы (сверху), покрытая "снегом"

func _ready():
	var rock_mat = StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.42, 0.4, 0.43)
	rock_mat.roughness = 1.0

	var snow_mat = StandardMaterial3D.new()
	snow_mat.albedo_color = Color(0.96, 0.97, 1.0)
	snow_mat.roughness = 0.9

	for i in range(MOUNTAIN_COUNT):
		# по кругу примерно равномерно, с небольшим случайным сдвигом угла и радиуса,
		# чтобы не выглядело как идеально ровное кольцо одинаковых конусов
		var angle = (float(i) / MOUNTAIN_COUNT) * TAU + randf_range(-0.12, 0.12)
		var radius = randf_range(RING_RADIUS_MIN, RING_RADIUS_MAX)
		var height = randf_range(HEIGHT_MIN, HEIGHT_MAX)
		var base_r = randf_range(BASE_RADIUS_MIN, BASE_RADIUS_MAX)

		var peak = Node3D.new()
		peak.position = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		peak.rotation.y = randf_range(0.0, TAU)
		add_child(peak)

		var rock = MeshInstance3D.new()
		var rock_mesh = CylinderMesh.new()
		rock_mesh.top_radius = base_r * 0.04   # не в самую точку - иначе на срезе виден жёсткий пятиугольник
		rock_mesh.bottom_radius = base_r
		rock_mesh.height = height
		rock_mesh.radial_segments = 7          # намеренно немного гранёный силуэт - горы, не купол
		rock.mesh = rock_mesh
		rock.material_override = rock_mat
		rock.position.y = height * 0.5
		rock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		peak.add_child(rock)

		# снежная шапка - такой же конус меньшего размера, надет на верхушку скалы;
		# радиус его основания подобран по подобию треугольников (радиус скалы на той
		# высоте), с небольшим нахлёстом, чтобы не было щели между шапкой и скалой
		var snow_height = height * SNOW_CAP_RATIO
		var snow = MeshInstance3D.new()
		var snow_mesh = CylinderMesh.new()
		snow_mesh.top_radius = base_r * 0.04
		snow_mesh.bottom_radius = base_r * (snow_height / height) * 1.15
		snow_mesh.height = snow_height
		snow_mesh.radial_segments = 7
		snow.mesh = snow_mesh
		snow.material_override = snow_mat
		snow.position.y = height - snow_height * 0.5
		snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		peak.add_child(snow)
