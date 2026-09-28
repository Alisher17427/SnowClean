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
const CLOUD_SEED = 918273645          # фиксированный - раскладка кластеров одинакова у всех
const SYNC_INTERVAL = 5.0             # раз в столько секунд хост поправляет всех клиентов

# направление и сила сноса теперь берутся из общего ветра (snow_sync.wind_vector) -
# того же, что сносит пар изо рта, пламя факела и дым из трубы: лёгкий бриз в
# ясную погоду, усиливается вместе с blizzard_intensity во время метели.
# CLOUD_WIND_SPEED_SCALE подобран так, чтобы в штиль (|wind_vector| ~= WIND_BASE_STRENGTH
# = 0.6) скорость сноса совпадала со старой константой WIND_SPEED = 0.6 м/с
const CLOUD_WIND_SPEED_SCALE = 1.0
const FALLBACK_WIND = Vector3(0.6, 0.0, 0.8)   # на случай если SnowSync ещё не готов в первом кадре

var snow_sync: Node
var clouds: Array = []          # узлы-кластеры (каждый - несколько сплюснутых сфер)
var base_positions: Array = []  # Vector3 на каждое облако - точка при wind_elapsed = 0
var wind_elapsed: float = 0.0   # накопленное расстояние сноса, м (не время - см. _process)
var _sync_timer: float = 0.0

func _ready():
	snow_sync = get_parent().get_node_or_null("SnowSync")
	var rng = RandomNumberGenerator.new()
	rng.seed = CLOUD_SEED
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1, 0.85)
	# ALPHA_DEPTH_PRE_PASS, а не обычный ALPHA-blend: в Godot 4 (Forward+/Vulkan)
	# объекты с alpha-blend прозрачностью не попадают в shadow pass и никогда не
	# отбрасывают тень, сколько бы cast_shadow ни было включено. Depth pre-pass
	# честно пишет глубину (тень строится по ней), а сам цвет всё равно рисуется
	# обычным альфа-блендом - в отличие от ALPHA_HASH тут нет дизер-шума, потому
	# что альфа облаков постоянная (0.85 везде), а не переменная по текстуре -
	# на такой ровной альфе hash даёт видимую шумную "рябь" вместо мягкого края
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
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
	var wind = snow_sync.wind_vector() if snow_sync else FALLBACK_WIND
	wind_elapsed += wind.length() * CLOUD_WIND_SPEED_SCALE * delta

	# только хост периодически поправляет всех остальных - без этого рассинхрон
	# постепенно накапливался бы даже при одинаковом старте (разная частота
	# кадров/паузы на разных компьютерах, plus blizzard_intensity сглаживается
	# локально у каждого клиента и может чуть разойтись между поправками)
	if multiplayer.is_server():
		_sync_timer += delta
		if _sync_timer >= SYNC_INTERVAL:
			_sync_timer = 0.0
			sync_wind.rpc(wind_elapsed)

	var dir = Vector2(wind.x, wind.z).normalized()
	for i in range(clouds.size()):
		clouds[i].position = _wrapped_pos(base_positions[i], dir, wind_elapsed)

# позиция = база + направление ветра * накопленное расстояние сноса (не мгновенная
# скорость * dt кадр за кадром) - так же, как раньше было "чистой функцией от
# времени", просто теперь накопление учитывает переменную во время метели скорость
func _wrapped_pos(base: Vector3, dir: Vector2, dist: float) -> Vector3:
	var drift = Vector3(dir.x, 0.0, dir.y) * dist
	var p = base + drift
	p.x = wrapf(p.x, -CLOUD_AREA, CLOUD_AREA)
	p.z = wrapf(p.z, -CLOUD_AREA, CLOUD_AREA)
	return p

# authority - RPC можно вызвать только от хоста (id=1 по умолчанию), так что
# подделать время ветра с чужого клиента нельзя
@rpc("authority", "call_remote", "reliable")
func sync_wind(server_elapsed: float):
	wind_elapsed = server_elapsed
