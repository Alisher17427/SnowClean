extends Node3D

# Облака в небе: несколько "пушистых" кластеров из приплюснутых сфер, медленно
# плывут по ветру и отбрасывают настоящую тень от солнца - отдельного шейдера не
# нужно, это обычная тень от DirectionalLight3D (солнце), как у деревьев и игроков
# (см. main.tscn - тени у солнца уже включены). Тень двигается вместе с обликом,
# а направлена всегда так, как реально светит солнце в сцене.
#
# Синхронизация по сети: раньше каждый клиент сам кидал кубик при построении
# (случайные стартовые позиции/форма кластеров) и сам крутил дрейф - облака у
# разных игроков были в разных местах неба с самого начала и расходились только
# сильнее. Теперь позиция каждого облака - чистая функция от общего "времени ветра"
# (wind_elapsed) и фиксированного сида (CLOUD_SEED): сама форма/раскладка кластеров
# одинакова у всех без обмена по сети, а wind_elapsed синхронизируется хостом -
# тот же приём, что и elapsed в day_night.gd (периодическая RPC-поправка + сразу
# при подключении нового игрока)

const CLOUD_COUNT = 6
const CLOUD_HEIGHT = 28.0
const CLOUD_AREA = 45.0        # облака блуждают в квадрате -CLOUD_AREA..CLOUD_AREA, потом заходят с другого края
const WIND_DIR = Vector2(0.6, 0.35)   # направление ветра (x, z), нормализуется ниже
const WIND_SPEED = 0.6                # м/с
const CLOUD_SEED = 918273645          # фиксированный - раскладка кластеров одинакова у всех
const SYNC_INTERVAL = 5.0             # раз в столько секунд хост поправляет всех клиентов

var clouds: Array = []          # узлы-кластеры (каждый - несколько сплюснутых сфер)
var base_positions: Array = []  # Vector3 на каждое облако - точка при wind_elapsed = 0
var wind_elapsed: float = 0.0
var _sync_timer: float = 0.0

func _ready():
	var rng = RandomNumberGenerator.new()
	rng.seed = CLOUD_SEED
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 1.0
	for i in range(CLOUD_COUNT):
		var cloud = Node3D.new()
		var base = Vector3(
			rng.randf_range(-CLOUD_AREA, CLOUD_AREA),
			CLOUD_HEIGHT + rng.randf_range(-2.0, 2.0),
			rng.randf_range(-CLOUD_AREA, CLOUD_AREA)
		)
		base_positions.append(base)
		cloud.position = base
		add_child(cloud)
		var puff_count = rng.randi_range(3, 5)
		for p in range(puff_count):
			var mi = MeshInstance3D.new()
			var sphere = SphereMesh.new()
			var r = rng.randf_range(2.2, 4.0)
			sphere.radius = r
			sphere.height = r * 1.3
			mi.mesh = sphere
			mi.material_override = mat
			mi.position = Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(-0.6, 0.6), rng.randf_range(-2.0, 2.0))
			mi.scale = Vector3(1.0, 0.55, 1.0)   # приплюснуто по высоте - силуэт больше похож на облако
			cloud.add_child(mi)
		clouds.append(cloud)

	# вошедшему позже игроку хост сразу присылает текущее время ветра - иначе
	# облака у него начали бы дрейф с нуля, а не с той точки, где они уже сейчас
	# находятся у остальных
	multiplayer.peer_connected.connect(_on_peer_connected)

func _on_peer_connected(id: int):
	if multiplayer.is_server():
		sync_wind.rpc_id(id, wind_elapsed)

func _process(delta):
	wind_elapsed += delta

	# только хост периодически поправляет всех остальных - без этого рассинхрон
	# постепенно накапливался бы даже при одинаковом старте (разная частота
	# кадров/паузы на разных компьютерах)
	if multiplayer.is_server():
		_sync_timer += delta
		if _sync_timer >= SYNC_INTERVAL:
			_sync_timer = 0.0
			sync_wind.rpc(wind_elapsed)

	for i in range(clouds.size()):
		clouds[i].position = _wrapped_pos(base_positions[i], wind_elapsed)

# чистая функция от времени - не накопление дрейфа кадр за кадром, поэтому
# позицию всегда можно посчитать заново без риска расхождения по сети
func _wrapped_pos(base: Vector3, t: float) -> Vector3:
	var drift = Vector3(WIND_DIR.x, 0.0, WIND_DIR.y).normalized() * WIND_SPEED * t
	var p = base + drift
	p.x = wrapf(p.x, -CLOUD_AREA, CLOUD_AREA)
	p.z = wrapf(p.z, -CLOUD_AREA, CLOUD_AREA)
	return p

# authority - RPC можно вызвать только от хоста (id=1 по умолчанию), так что
# подделать время ветра с чужого клиента нельзя
@rpc("authority", "call_remote", "reliable")
func sync_wind(server_elapsed: float):
	wind_elapsed = server_elapsed
