extends Node3D

# Облака в небе: несколько "пушистых" кластеров из приплюснутых сфер, медленно
# плывут по ветру и отбрасывают настоящую тень от солнца - отдельного шейдера не
# нужно, это обычная тень от DirectionalLight3D (солнце), как у деревьев и игроков
# (см. main.tscn - тени у солнца уже включены). Тень двигается вместе с обликом,
# а направлена всегда так, как реально светит солнце в сцене.

const CLOUD_COUNT = 6
const CLOUD_HEIGHT = 28.0
const CLOUD_AREA = 45.0        # облака блуждают в квадрате -CLOUD_AREA..CLOUD_AREA, потом заходят с другого края
const WIND_DIR = Vector2(0.6, 0.35)   # направление ветра (x, z), нормализуется ниже
const WIND_SPEED = 0.6                # м/с

var clouds: Array = []   # узлы-кластеры (каждый - несколько сплюснутых сфер)

func _ready():
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 1.0
	for i in range(CLOUD_COUNT):
		var cloud = Node3D.new()
		cloud.position = Vector3(
			randf_range(-CLOUD_AREA, CLOUD_AREA),
			CLOUD_HEIGHT + randf_range(-2.0, 2.0),
			randf_range(-CLOUD_AREA, CLOUD_AREA)
		)
		add_child(cloud)
		var puff_count = randi_range(3, 5)
		for p in range(puff_count):
			var mi = MeshInstance3D.new()
			var sphere = SphereMesh.new()
			var r = randf_range(2.2, 4.0)
			sphere.radius = r
			sphere.height = r * 1.3
			mi.mesh = sphere
			mi.material_override = mat
			mi.position = Vector3(randf_range(-3.0, 3.0), randf_range(-0.6, 0.6), randf_range(-2.0, 2.0))
			mi.scale = Vector3(1.0, 0.55, 1.0)   # приплюснуто по высоте - силуэт больше похож на облако
			cloud.add_child(mi)
		clouds.append(cloud)

func _process(delta):
	var drift = Vector3(WIND_DIR.x, 0.0, WIND_DIR.y).normalized() * WIND_SPEED * delta
	for cloud in clouds:
		cloud.position += drift
		if cloud.position.x > CLOUD_AREA:
			cloud.position.x = -CLOUD_AREA
		elif cloud.position.x < -CLOUD_AREA:
			cloud.position.x = CLOUD_AREA
		if cloud.position.z > CLOUD_AREA:
			cloud.position.z = -CLOUD_AREA
		elif cloud.position.z < -CLOUD_AREA:
			cloud.position.z = CLOUD_AREA
