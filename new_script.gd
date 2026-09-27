extends CharacterBody3D

const SPEED = 3.5
const SPRINT_MULT = 1.6   # во сколько раз быстрее при зажатом Shift
const JUMP_VELOCITY = 4.5
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var head = $Head
@onready var camera = $Head/Camera3D
@export var nickname: String = ""   # ник игрока (синхронизируется по сети)
var nameplate: Label3D
var input_locked = false   # открыто меню паузы: игрок не двигается и не копает
var snow_sync: Node   # общий узел синхронизации снега (SnowSync в главной сцене)
var mouse_sensitivity = 0.002

# --- покачивание камеры при ходьбе ---
const BOB_FREQ = 9.0        # шагов в секунду (скорость покачивания)
const BOB_AMP_Y = 0.06      # вертикальный "подпрыг" камеры
const BOB_AMP_X = 0.035     # боковое покачивание
const BOB_ROLL = 0.012      # лёгкий наклон камеры (радианы)
const BOB_SMOOTH = 12.0     # плавность возврата в покой
var bob_time = 0.0

# --- хозяйство: тепло, здоровье, дрова ---
@export var hp: float = 100.0
@export var warmth: float = 100.0
var fireplace_node: Node3D

# --- квестовый NPC Петя: стоит у дома, G рядом с ним открывает меню квестов,
# G с бревном в руках на красном коврике у него - сдаёт бревно в счёт квеста ---
var petya_node: Node3D
var quest_menu: Node
var petya_voice: Node   # см. petya_voice.gd - голосовой чат/проактивные реплики Пети
const QUEST_INTERACT_RADIUS = 2.4
const QUEST_DROPZONE_RADIUS = 1.0

# --- награда за квесты: цвет перчаток (тон поверх текстуры рук), разблокируется
# выполнением соответствующего квеста у Пети (snow_sync.quest_completed). Выбирается
# в меню паузы ("Кастомизация", см. pause_menu_3d.gd); id 0 - обычные, без тона,
# доступны всегда. Не сохраняется между запусками - выбор сбрасывается заново
# на старте, зато сама разблокировка (квест выполнен) сохраняется (см. snow_sync.gd) ---
const HAND_COLORS = [
	{"name": "Обычные", "unlock_quest": ""},
	{"name": "Красные перчатки", "color": Color(0.75, 0.15, 0.1), "unlock_quest": "petya_wood"},
	{"name": "Синие перчатки", "color": Color(0.15, 0.4, 0.85), "unlock_quest": "petya_chickens"},
]
@export var hand_color_id: int = 0   # синхронизируется по сети, как ник - видно у всех
var hands_model: Node       # ссылка на загруженную модель рук - для перекраски (см. _apply_hand_color)
var _last_hand_color_id = -1   # чтобы перекрашивать только при реальном изменении, не каждый кадр

func set_hand_color(id: int):
	hand_color_id = clamp(id, 0, HAND_COLORS.size() - 1)

# --- факел: снимается со стены клавишей G (та же клавиша у Пети/коврика для квеста -
# см. _update_survival), парит перед камерой, пока в руках, как удерживаемая курица
# (get_chicken_hold_position), только сам факел - личный визуал, по сети не отображается
# другим игрокам (как топор/бревно), а не настоящий сетевой объект вроде курицы.
# Убрать его можно только обратно на стену, не бросить на землю ---
var torch_node: Node3D
var has_torch: bool = false
var held_torch_rig: Node3D    # общий узел для модели факела + пламени + света в руке
var held_torch_light: OmniLight3D
var held_torch_flame: GPUParticles3D    # пиксельное пламя - обдувается "ветром" при ходьбе, см. _update_torch_walk_fx
var held_torch_sparks: GPUParticles3D   # разовый всплеск искр на каждый шаг, см. _update_torch_walk_fx
var held_torch_base_xform: Transform3D  # исходная поза руки без покачивания - на неё накручивается sway
var torch_flicker_time: float = 0.0
var torch_step_sign: float = 0.0        # знак sin(bob_time) на прошлом кадре - смена знака = шаг
const TORCH_PICKUP_RADIUS = 1.8
const TORCH_DROP_FORWARD = 0.5     # откуда начинает падать брошенный факел - чуть впереди игрока
const TORCH_DROP_UP = 1.0          # ...и на высоте руки, чтобы падение было видно, а не из-под ног
const TORCH_DROP_IMPULSE = 1.3     # лёгкий толчок вперёд/вверх, чтобы выглядело как бросок
const TORCH_HOLD_POSITION = Vector3(0.18, -0.18, -0.6)   # перед камерой, чуть вбок и вниз - как будто держим на вытянутой руке
const TORCH_HOLD_DIR = Vector3(0.05, 1.0, -0.25)   # куда смотрит "верх" факела в руке - в основном вверх, чуть вперёд
const TORCH_HELD_HEIGHT = 0.4
const TORCH_MODEL_SCENE = preload("res://assets/fbx_dungeon_asset_pack/individuals files/torch.fbx")
const TorchScript = preload("res://torch.gd")   # даёт build_pixel_flame/build_step_sparks - те же частицы, что и у факела на стене
const TORCH_BASE_ENERGY = 1.3
const TORCH_BASE_RANGE = 4.0
const TORCH_SWAY_AMP_X = 0.025    # покачивание факела в руке при ходьбе - без этого он
const TORCH_SWAY_AMP_Y = 0.055    # висит намертво перед камерой, хотя сама камера уже
const TORCH_SWAY_AMP_ROT = 5.0    # покачивается (BOB_*) - тут нужно доп. движение поверх неё
								   # (Y - основной "приспускается/поднимается" эффект по шагам)
const TORCH_FLAME_LIFT = 0.4      # базовая тяга пламени вверх (как у build_pixel_flame)
const TORCH_TRAIL_WIND = 1.6      # чем больше, тем сильнее уже вылетевшие частицы относит
								   # назад относительно направления ходьбы
const TORCH_WIND_SCALE = 3.5      # насколько сильно настоящий ветер (snow_sync.wind_vector) сносит пламя

# где сейчас можно подобрать факел - null, если его нельзя взять (уже у кого-то
# в руках). Раньше проверялась только стена, теперь факел может физически лежать
# на земле там, куда его бросили (см. drop_to_ground в torch.gd)
func _torch_pickup_pos():
	if snow_sync.torch_on_ground:
		return snow_sync.torch_ground_pos
	if not snow_sync.torch_taken and torch_node:
		return torch_node.global_position
	return null

# AABB модели в её собственном локальном пространстве - та же логика, что и у
# настенного факела (см. _combined_aabb/_place_model в torch.gd), нужна тут отдельно,
# т.к. держатель в руке крепится не к Torch-узлу на стене, а к камере игрока
func _torch_model_aabb(node: Node, xform: Transform3D) -> AABB:
	var result := AABB()
	var has_any := false
	if node is MeshInstance3D and node.mesh:
		result = xform * node.mesh.get_aabb()
		has_any = true
	for child in node.get_children():
		if child is Node3D:
			var child_xform = xform * child.transform
			var child_aabb = _torch_model_aabb(child, child_xform)
			if has_any:
				result = result.merge(child_aabb)
			else:
				result = child_aabb
				has_any = true
	return result

func _equip_torch():
	if held_torch_rig:
		return
	var dir = TORCH_HOLD_DIR.normalized()
	var up = Vector3(0, 1, 0)
	var rot_basis = Basis.IDENTITY
	var axis = up.cross(dir)
	if axis.length() > 0.001:
		rot_basis = Basis(axis.normalized(), up.angle_to(dir))

	held_torch_rig = Node3D.new()
	held_torch_rig.transform = Transform3D(rot_basis, TORCH_HOLD_POSITION)
	held_torch_base_xform = held_torch_rig.transform
	camera.add_child(held_torch_rig)

	var model = TORCH_MODEL_SCENE.instantiate()
	held_torch_rig.add_child(model)
	var aabb = _torch_model_aabb(model, Transform3D.IDENTITY)
	var s = TORCH_HELD_HEIGHT / max(aabb.size.y, 0.001)
	model.scale = Vector3.ONE * s
	# модель экспортирована со смещённым от нуля пивотом (см. _place_model в torch.gd) -
	# центрируем по X/Z, иначе после масштабирования её относит далеко в сторону от руки
	model.position.x = -(aabb.position.x + aabb.size.x * 0.5) * s
	model.position.z = -(aabb.position.z + aabb.size.z * 0.5) * s
	model.position.y = -aabb.position.y * s
	var tip_local = Vector3(0, (aabb.position.y + aabb.size.y) * s + model.position.y, 0)

	held_torch_flame = TorchScript.build_pixel_flame(tip_local, true)
	held_torch_rig.add_child(held_torch_flame)

	held_torch_sparks = TorchScript.build_step_sparks(tip_local)
	held_torch_sparks.emitting = false
	held_torch_rig.add_child(held_torch_sparks)

	held_torch_light = OmniLight3D.new()
	held_torch_light.position = tip_local
	held_torch_light.light_color = Color(1, 0.6, 0.25)
	held_torch_light.omni_range = TORCH_BASE_RANGE
	held_torch_light.shadow_enabled = true
	held_torch_rig.add_child(held_torch_light)
	_update_hud()

func _unequip_torch():
	if held_torch_rig:
		held_torch_rig.queue_free()
		held_torch_rig = null
		held_torch_light = null
		held_torch_flame = null
		held_torch_sparks = null
	torch_step_sign = 0.0
	_update_hud()

# факел в руке - ребёнок камеры, а камера уже покачивается сама при ходьбе
# (_update_bob), поэтому 1:1 движение с ней на экране выглядит как будто факел
# висит неподвижно (сдвиг компенсируется общим движением камеры). Тут добавляется
# независимое от камеры покачивание поверх базовой позы (held_torch_base_xform),
# всплеск искр на каждый шаг и "ветер", относящий уже вылетевшие частицы пламени
# назад относительно направления ходьбы - они симулируются в мировых координатах
# (см. build_pixel_flame(.., trailing=true) в torch.gd), поэтому реально остаются
# висеть в воздухе позади, а не тащатся вместе с рукой.
#
# Вертикальное покачивание синхронизировано с самой рукой: TORCH_HOLD_POSITION.x
# положительный (факел справа), а правую руку на шаге опускает dip_r (см.
# _update_arms/hand_walk_modifier.gd) - используем то же значение, а не свою
# независимую синусоиду, иначе факел и рука дёргались бы каждый в своём такте
func _update_torch_walk_fx(delta):
	if not held_torch_rig:
		return
	var horiz_vel = Vector3(velocity.x, 0, velocity.z)
	if held_torch_flame and held_torch_flame.process_material:
		var wind = Vector3.ZERO
		if snow_sync and not _is_indoors(global_position):
			wind = snow_sync.wind_vector() * TORCH_WIND_SCALE
		held_torch_flame.process_material.gravity = Vector3(0, TORCH_FLAME_LIFT, 0) - horiz_vel * TORCH_TRAIL_WIND + wind

	var speed = horiz_vel.length()
	var w = clamp(speed / SPEED, 0.0, 1.0)
	var moving = is_on_floor() and w > 0.05
	if not moving:
		held_torch_rig.transform = held_torch_base_xform
		torch_step_sign = 0.0
		return

	# dip_r уже само по себе умножено на w (см. _update_arms) - второй раз не масштабируем
	var sway_pos = Vector3(sin(bob_time * 0.5) * TORCH_SWAY_AMP_X * w, -dip_r * TORCH_SWAY_AMP_Y, 0)
	var sway_rot = deg_to_rad(sin(bob_time) * TORCH_SWAY_AMP_ROT * w)
	held_torch_rig.transform = held_torch_base_xform * Transform3D(Basis(Vector3(0, 0, 1), sway_rot), sway_pos)

	var s = sign(sin(bob_time))
	if s != 0.0 and s != torch_step_sign:
		torch_step_sign = s
		if held_torch_sparks:
			held_torch_sparks.restart()

func _update_torch_flicker(delta: float):
	if not held_torch_light:
		return
	torch_flicker_time += delta
	var n = sin(torch_flicker_time * 11.0) * 0.5 + sin(torch_flicker_time * 6.1 + 1.2) * 0.3 + sin(torch_flicker_time * 19.0 + 0.6) * 0.2
	var flicker_mult = 1.0 + n * 0.2
	held_torch_light.light_energy = TORCH_BASE_ENERGY * flicker_mult
	held_torch_light.omni_range = TORCH_BASE_RANGE * (0.97 + 0.03 * flicker_mult)

# --- бревно от срубленного дерева: лежит на земле у дерева, поднимается и бросается
# клавишей F (как топор), в инвентарь не попадает - висит перед руками, пока несём,
# и кладётся в камин клавишей "положить дрова" (Q) рядом с ним ---
var held_log_id: String = ""   # ключ бревна в snow_sync.logs, "" если руки без бревна
var held_log_mesh: MeshInstance3D
const LOG_PICKUP_RADIUS = 1.6
const LOG_DROP_FORWARD = 1.0
const LOG_DROP_UP = 0.8       # бревно тоже роняем физикой (см. drop_log в snow_sync.gd),
const LOG_DROP_IMPULSE = 1.0  # а не кладём мгновенно - с высоты руки и с лёгким толчком
const HELD_LOG_POSITION = Vector3(0.05, -0.3, -0.55)

# --- топор у дома: лежит на земле, поднимается клавишей F рядом с ним;
# уже в руках - той же клавишей F выбрасывается обратно на землю перед игроком ---
var axe_node: Node3D          # декоративный топор из main.tscn (сам узел никогда не удаляется -
							   # при поднятии/броске его просто прячут/показывают и двигают по сети)
var has_axe: bool = false     # личный признак, по сети не передаётся (как и дрова)
var held_axe: MeshInstance3D  # маленькая копия перед руками, пока топор поднят
const AXE_PICKUP_RADIUS = 1.6
const AXE_DROP_FORWARD = 1.0  # на сколько метров вперёд бросаем топор при выбрасывании
const AXE_DROP_UP = 0.8       # топор роняем физикой (см. drop_axe в snow_sync.gd) с высоты
const AXE_DROP_IMPULSE = 1.2  # руки, а не кладём мгновенно на землю - с лёгким толчком
const HELD_AXE_MESH = preload("res://models/axe/12351_Axe_v3_l3.obj")
const HELD_AXE_SCALE = 0.05
const HELD_AXE_POSITION = Vector3(0.0, -0.16, -0.55)   # по центру, перед руками (см. _build_arms)
# исходная модель топора лежит плашмя, её "длинная ось" в локальных
# координатах направлена вот так - используем, чтобы поставить топор вертикально в руке
const AXE_MODEL_AXIS = Vector3(-0.8648, 0.0, 0.5022)

# --- курица в руках: ЛКМ рядом с курицей берёт её в руки (сама курица - реальный
# сетевой объект, при удержании/броске её просто ведёт хост, см. chicken.gd), ПКМ
# зажимается для силы броска и отпускается, чтобы кинуть ---
var held_chicken_path: String = ""   # путь до курицы в руках, "" если руки пустые
var chicken_throw_charge_t: float = 0.0
var chicken_rmb_was_down: bool = false
const CHICKEN_PICKUP_RADIUS = 2.2
const CHICKEN_HOLD_FORWARD = 0.55    # где висит курица перед игроком, пока он её держит
const CHICKEN_HOLD_DOWN = 0.35
const CHICKEN_THROW_CHARGE_TIME = 1.2     # секунд зажатия ПКМ до максимальной силы
const CHICKEN_THROW_MIN_FORCE = 4.0
const CHICKEN_THROW_MAX_FORCE = 13.0

# --- снежки: ЛКМ на снежной земле со свободными руками лепит снежок, ЛКМ ещё раз -
# кидает его вперёд. Сам снежок в полёте - лёгкий локальный визуальный эффект
# (см. snow_sync.gd), а не сетевой объект вроде курицы - точность не критична ---
var has_snowball: bool = false
var held_snowball: MeshInstance3D
const SNOWBALL_MIN_DEPTH = 0.15   # столько снега минимум нужно под ногами/на земле, чтобы слепить
const SNOWBALL_THROW_FORCE = 15.0
const HELD_SNOWBALL_POSITION = Vector3(0.1, -0.22, -0.42)   # перед руками, см. _build_arms
var splat_overlay: ColorRect   # белая вспышка на экране при попадании снежком (см. _on_snowball_hit)
var splat_alpha: float = 0.0
const SPLAT_FADE_SPEED = 1.4   # альфа/сек - за сколько вспышка гаснет

const HP_MAX = 100.0
const WARMTH_MAX = 100.0
const WARM_RADIUS = 2.6          # на каком расстоянии от камина греет
const WARM_RATE = 22.0           # скорость нагрева у огня, ед/сек
const INDOOR_DECAY = 0.7         # тепло в доме без огня, ед/сек
const OUTDOOR_DECAY = 1.6        # тепло на улице, ед/сек
const SNOW_EXTRA_DECAY = 3.0     # дополнительная потеря тепла в глубоком снегу, ед/сек
const CHICKEN_COLD_PENALTY = 0.9 # доп. потеря тепла в доме за каждую курицу внутри (без огня рядом), ед/сек
const CHICKEN_FIRE_PENALTY = 5.0 # на столько меньше греет камин за каждую курицу в доме (может уйти в минус - тогда камин уже не спасает)
const HP_DECAY_COLD = 6.0        # потеря HP, когда тепло кончилось, ед/сек
const HP_REGEN_WARM = 3.0        # восстановление HP, когда тепло выше WARM_SAFE
const WARM_SAFE = 55.0
const SNOW_SLOW_MIN = 0.55       # во сколько раз замедляет глубокий снег (1.0 = не мешает)
const BLIZZARD_COLD_PENALTY = 6.0  # доп. потеря тепла на улице во время метели, ед/сек (на полную силу)
const BLIZZARD_WIND_PUSH = 1.8      # м/с, насколько метель сносит при ходьбе на улице
const BLIZZARD_WIND_DIR = Vector3(0.6, 0.0, 0.8)   # общее направление ветра метели, одно на всю карту

# --- падающий снег вокруг игрока: лёгкий фон в обычную погоду, густой снегопад
# во время метели (см. snow_sync.blizzard_intensity) ---
var snowfall_particles: GPUParticles3D
const SNOWFALL_BASE_RATIO = 0.15
const SNOWFALL_MAX_RATIO = 1.0

# дом: прямоугольная область, где тепло тратится медленнее (без камина - всё равно холодно)
const HOUSE_MIN = Vector3(-3.0, -1.0, -9.0)
const HOUSE_MAX = Vector3(3.0, 6.0, -3.0)

var hud: CanvasLayer
var frost_overlay: ColorRect
var hud_label: Label
var hint_panel: Panel
var hint_label: Label
const HINT_BASE_LEFT = -170.0
const HINT_BASE_RIGHT = 170.0
const HINT_BASE_TOP = 42.0      # чуть ниже прицела, который в самом центре экрана
const HINT_BASE_BOTTOM = 80.0
const HINT_SWAY_AMP = 4.0       # лёгкое покачивание панели, как у меню паузы (пикселей)
const HINT_SWAY_FREQ = 1.7
const HINT_FADE_AFTER = 4.0     # через сколько секунд у одного и того же предмета подсказка гаснет
const HINT_FADE_DURATION = 1.2  # за сколько секунд гаснет полностью
var hint_sway_time = 0.0
var hint_last_text = ""
var hint_show_time = 0.0

# --- пар изо рта на морозе: чем меньше тепла, тем гуще; выходит волнами, как при
# настоящем дыхании - вдох (пара нет), пауза, выдох (облачко нарастает и спадает).
# Звук вдоха/выдоха слышит только сам игрок (личный локальный звук, не по сети) ---
const SoundBank = preload("res://sound_bank.gd")
var breath_particles: GPUParticles3D
var breath_audio: AudioStreamPlayer
var breath_inhale_stream: AudioStreamWAV
var breath_exhale_stream: AudioStreamWAV
var breath_cycle_time = 0.0
var breath_inhale_done = false   # звук вдоха/выдоха уже сыгран в этом цикле
var breath_exhale_done = false
const BREATH_MAX_RATIO = 1.0        # почти замёрз - пар на выдохе густой
const BREATH_CYCLE = 3.2            # длительность одного цикла вдох-выдох, сек
const BREATH_INHALE_START = 0.02    # с какой доли цикла начинается звук вдоха
const BREATH_EXHALE_START = 0.55    # с какой доли цикла начинается выдох
const BREATH_EXHALE_END = 0.85      # где выдох заканчивается (дальше снова вдох)
const BREATH_LIFT = 0.1             # базовая тяга пара вверх (см. _build_breath_fog)
const BREATH_TRAIL_WIND = 1.0       # пар тоже сдувает при ходьбе - легче факела, поэтому
									 # слабее TORCH_TRAIL_WIND, но идея та же (_update_torch_walk_fx)
const BREATH_WIND_SCALE = 2.5       # насколько сильно настоящий ветер (snow_sync.wind_vector) сносит пар

# Имя узла игрока = id участника сети. Им управляет только его владелец.
func _enter_tree():
	if str(name).is_valid_int():
		set_multiplayer_authority(str(name).to_int())

func _ready():
	add_to_group("players")
	snow_sync = get_tree().current_scene.get_node("SnowSync")
	if is_multiplayer_authority():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		camera.make_current()
		var pause_menu = preload("res://pause_menu_3d.gd").new()
		pause_menu.name = "PauseMenu"
		pause_menu.player = self
		add_child(pause_menu)
		nickname = str(get_tree().current_scene.local_nickname)
		# игроки появляются вокруг маркера PlayerSpawn, каждый в своей точке круга
		var spawn = get_tree().current_scene.get_node("PlayerSpawn").global_position
		var angle = float(get_multiplayer_authority() % 8) * TAU / 8.0
		global_position = spawn + Vector3(cos(angle), 0.0, sin(angle)) * 1.2
		fireplace_node = get_tree().current_scene.get_node_or_null("Fireplace")
		axe_node = get_tree().current_scene.get_node_or_null("Axe")
		petya_node = get_tree().current_scene.get_node_or_null("Petya")
		torch_node = get_tree().current_scene.get_node_or_null("Torch")
		quest_menu = preload("res://quest_menu.gd").new()
		quest_menu.name = "QuestMenu"
		quest_menu.player = self
		add_child(quest_menu)
		_build_hud()
		if petya_node:
			petya_voice = preload("res://petya_voice.gd").new()
			petya_voice.name = "PetyaVoice"
			add_child(petya_voice)
			petya_voice.setup(self, petya_node)
		_build_interact_hint()
		_build_breath_fog()
		_build_snowfall()
	else:
		camera.current = false
		_build_nameplate()
	# руки строятся у всех: свои видны от первого лица, чужие видят остальные игроки
	_build_arms()

func _build_hud():
	hud = CanvasLayer.new()
	add_child(hud)
	_build_vignette()
	_build_frost_overlay()
	_build_splat_overlay()
	hud_label = Label.new()
	hud_label.position = Vector2(16, 16)
	hud_label.add_theme_font_size_override("font_size", 20)
	hud_label.add_theme_color_override("font_outline_color", Color.BLACK)
	hud_label.add_theme_constant_override("outline_size", 4)
	hud.add_child(hud_label)

# лёгкая виньетка по краям экрана - чисто оформление (пост-процессинг), статичная,
# без параметров и обновления каждый кадр; рисуется первой, под инеем и остальным HUD
func _build_vignette():
	var vignette = ColorRect.new()
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vignette.color = Color(1, 1, 1, 1)
	var mat = ShaderMaterial.new()
	mat.shader = load("res://vignette.gdshader")
	vignette.material = mat
	hud.add_child(vignette)

# иней на экране при низком тепле - добавляется первым, поэтому рисуется под
# остальным HUD (текст здоровья, подсказки и т.д. остаются поверх и читаемы)
func _build_frost_overlay():
	frost_overlay = ColorRect.new()
	frost_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	frost_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frost_overlay.color = Color(1, 1, 1, 1)   # цвет не важен - весь вид даёт шейдер
	var shader = load("res://frost_overlay.gdshader")
	var mat = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("intensity", 0.0)
	frost_overlay.material = mat
	hud.add_child(frost_overlay)

# иней наползает, только когда тепло заметно ниже безопасного порога (WARM_SAFE) -
# лёгкий холод не должен покрывать весь экран льдом, только настоящее замерзание
func _update_frost_overlay():
	if not frost_overlay:
		return
	var frost_amount = clamp(1.0 - warmth / WARM_SAFE, 0.0, 1.0)
	frost_overlay.material.set_shader_parameter("intensity", frost_amount)

# белая вспышка на весь экран при попадании снежком - поверх инея, но под текстом HUD
func _build_splat_overlay():
	splat_overlay = ColorRect.new()
	splat_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	splat_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	splat_overlay.color = Color(1, 1, 1, 0.0)
	splat_overlay.visible = false
	hud.add_child(splat_overlay)

# вызывает snow_sync.gd, когда чужой снежок попал именно в этого игрока
func _on_snowball_hit():
	splat_alpha = 0.8

func _update_splat_overlay(delta: float):
	if not splat_overlay or splat_alpha <= 0.0:
		return
	splat_alpha = max(0.0, splat_alpha - SPLAT_FADE_SPEED * delta)
	splat_overlay.color.a = splat_alpha
	splat_overlay.visible = splat_alpha > 0.001

func _update_hud():
	if hud_label:
		var t = "Здоровье: %d\nТепло: %d" % [int(round(hp)), int(round(warmth))]
		if has_axe:
			t += "\nТопор: есть"
		if held_log_id != "":
			t += "\nБревно: несу"
		if has_torch:
			t += "\nФакел: в руках"
		hud_label.text = t

# облачко пара перед камерой (на уровне рта), плывёт вперёд и вверх и тает;
# густота меняется каждый кадр в _update_breath_fog() в зависимости от тепла
func _build_breath_fog():
	breath_particles = GPUParticles3D.new()
	breath_particles.position = Vector3(0.0, -0.13, -0.35)
	breath_particles.amount = 20   # несколько мелких частиц вместо одной крупной - облачко из отдельных "пикселей"
	# lifetime короче паузы между выдохом и следующим вдохом (см. BREATH_INHALE_START/
	# BREATH_EXHALE_END) - раньше было 1.1с, а пауза между ними всего ~0.54с, поэтому
	# частицы, вылетевшие под конец выдоха, ещё не успевали погаснуть и продолжали
	# быть видны прямо во время звука вдоха - выглядело так, будто пар идёт на вдохе
	breath_particles.lifetime = 0.45
	breath_particles.explosiveness = 0.0
	breath_particles.randomness = 0.3
	# local_coords = false: пар симулируется в мировых координатах, как и пиксельное
	# пламя факела в руке (см. build_pixel_flame(.., trailing=true) в torch.gd) -
	# раньше было true, и уже вылетевшее облачко было rigidно приклеено к камере:
	# при повороте камеры оно крутилось вместе с ней, будто нарисовано на экране,
	# а не висело в воздухе. Новые частицы всё равно вылетают оттуда, где сейчас
	# камера (сам узел - её ребёнок), просто уже вылетевшие живут в мире сами по себе
	breath_particles.local_coords = false
	breath_particles.amount_ratio = 0.0

	var pm = ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, 0.3, -1.0)
	pm.spread = 14.0
	pm.initial_velocity_min = 0.35
	pm.initial_velocity_max = 0.6
	pm.gravity = Vector3(0.0, BREATH_LIFT, 0.0)   # пар слегка поднимается, пролетая вперёд -
	# фактическое значение каждый кадр пересчитывается в _update_breath_fog (добавляется
	# "ветер" от ходьбы, та же идея, что и TORCH_TRAIL_WIND у факела в руке)
	# слабое торможение - пар должен весь свой век заметно улетать от рта,
	# а не гасить скорость почти сразу и зависать на месте
	pm.damping_min = 0.15
	pm.damping_max = 0.3
	pm.scale_min = 0.5
	pm.scale_max = 1.1

	var gradient = Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 0.0))
	gradient.add_point(0.15, Color(1, 1, 1, 0.4))
	gradient.add_point(0.7, Color(1, 1, 1, 0.22))
	gradient.set_color(gradient.get_point_count() - 1, Color(1, 1, 1, 0.0))
	var grad_tex = GradientTexture1D.new()
	grad_tex.gradient = gradient
	pm.color_ramp = grad_tex
	breath_particles.process_material = pm

	# сам "пиксель" пара - маленький жёсткий квадрат без мягкого растекания краёв,
	# чтобы много частиц читалось как крупинки, а не сливалось в одно пятно
	var mesh = QuadMesh.new()
	mesh.size = Vector2(0.045, 0.045)
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1, 1, 1, 1)
	mesh.material = mat
	breath_particles.draw_pass_1 = mesh
	breath_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	breath_particles.emitting = true

	camera.add_child(breath_particles)

	# личный звук дыхания - обычный (не позиционный) плеер рядом с камерой,
	# его слышит только сам игрок; громкость зависит от холода (см. _update_breath_fog)
	breath_inhale_stream = SoundBank.make_breath_inhale(501)
	breath_exhale_stream = SoundBank.make_breath_exhale(502)
	breath_audio = AudioStreamPlayer.new()
	breath_audio.bus = "Master"
	camera.add_child(breath_audio)

# пар виден, только когда тепло уже заметно просело (не с любого лёгкого похолодания -
# иначе кажется, что игрок дышит паром постоянно), и густеет по мере замерзания.
# Внутри самого холодного состояния пар всё равно не льётся сплошным потоком, а
# выходит волнами по циклу вдох-выдох: большую часть цикла - тишина (вдох), затем
# облачко плавно нарастает и спадает (выдох) - см. BREATH_CYCLE/BREATH_EXHALE_*
func _update_breath_fog(delta: float):
	if not breath_particles:
		return
	var coldness = 1.0 - clamp(warmth / WARMTH_MAX, 0.0, 1.0)
	var visible_ratio = smoothstep(0.25, 0.75, coldness)

	var prev_phase = breath_cycle_time / BREATH_CYCLE
	breath_cycle_time = fmod(breath_cycle_time + delta, BREATH_CYCLE)
	var phase = breath_cycle_time / BREATH_CYCLE
	if phase < prev_phase:   # цикл провернулся - начинаем новый вдох-выдох
		breath_inhale_done = false
		breath_exhale_done = false

	var exhale = 0.0
	if phase >= BREATH_EXHALE_START and phase <= BREATH_EXHALE_END:
		var t = (phase - BREATH_EXHALE_START) / (BREATH_EXHALE_END - BREATH_EXHALE_START)
		exhale = sin(t * PI)   # плавный подъём и спад за окно выдоха

	breath_particles.amount_ratio = visible_ratio * exhale * BREATH_MAX_RATIO
	_update_breath_audio(visible_ratio, phase)

	# "ветер" от ходьбы относит уже вылетевший пар назад - работает только потому,
	# что частицы теперь в мировых координатах (local_coords = false), иначе они бы
	# просто двигались вместе с игроком и импульс было бы не видно
	if breath_particles.process_material:
		var horiz_vel = Vector3(velocity.x, 0, velocity.z)
		var wind = Vector3.ZERO
		if snow_sync and not _is_indoors(global_position):
			wind = snow_sync.wind_vector() * BREATH_WIND_SCALE
		breath_particles.process_material.gravity = Vector3(0, BREATH_LIFT, 0) - horiz_vel * BREATH_TRAIL_WIND + wind

# звук вдоха/выдоха слышен, только если пар вообще заметен (visible_ratio > 0);
# каждый включается один раз за цикл ровно там, где начинается его фаза,
# поэтому звук и облачко пара всегда идут в такт друг другу
const BREATH_EXHALE_VOLUME_DB = -20.0   # громкость выдоха на самом сильном морозе (visible_ratio=1)
const BREATH_INHALE_VOLUME_DB = -26.0   # вдох тише выдоха
const BREATH_VOLUME_FLOOR_DB = -40.0    # почти не слышно, когда пар едва начал появляться

func _update_breath_audio(visible_ratio: float, phase: float):
	if not breath_audio or visible_ratio <= 0.01:
		return
	if not breath_inhale_done and phase >= BREATH_INHALE_START:
		breath_inhale_done = true
		breath_audio.stream = breath_inhale_stream
		breath_audio.volume_db = lerp(BREATH_VOLUME_FLOOR_DB, BREATH_INHALE_VOLUME_DB, visible_ratio)
		breath_audio.pitch_scale = randf_range(0.96, 1.04)
		breath_audio.play()
	elif not breath_exhale_done and phase >= BREATH_EXHALE_START:
		breath_exhale_done = true
		breath_audio.stream = breath_exhale_stream
		breath_audio.volume_db = lerp(BREATH_VOLUME_FLOOR_DB, BREATH_EXHALE_VOLUME_DB, visible_ratio)
		breath_audio.pitch_scale = randf_range(0.96, 1.04)
		breath_audio.play()

# подсказка по клавише - маленькая панель под прицелом, появляется рядом
# с деревом, кучей снега или камином (см. _update_interact_hint)
func _build_interact_hint():
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.05, 0.65)
	style.border_color = Color(1.0, 1.0, 1.0, 0.3)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	hint_panel = Panel.new()
	hint_panel.add_theme_stylebox_override("panel", style)
	hint_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_panel.anchor_left = 0.5
	hint_panel.anchor_right = 0.5
	hint_panel.anchor_top = 0.5
	hint_panel.anchor_bottom = 0.5
	hint_panel.offset_left = HINT_BASE_LEFT
	hint_panel.offset_right = HINT_BASE_RIGHT
	hint_panel.offset_top = HINT_BASE_TOP
	hint_panel.offset_bottom = HINT_BASE_BOTTOM
	hint_panel.visible = false
	hud.add_child(hint_panel)
	hint_label = Label.new()
	hint_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint_label.add_theme_font_size_override("font_size", 18)
	hint_panel.add_child(hint_label)

# смотрим ли на что-то, с чем можно взаимодействовать - подсказка показывается,
# только пока актуальна (не открыто меню, объект ещё в дальности луча/камина),
# слегка покачивается (как панели в меню паузы) и гаснет, если стоять на месте
# и смотреть на один и тот же предмет слишком долго - он уже и так виден
func _update_interact_hint(delta: float):
	if not hint_panel:
		return
	if input_locked:
		hint_panel.visible = false
		hint_last_text = ""
		hint_show_time = 0.0
		return

	if has_torch:
		hint_label.text = "[G]   Убрать факел"
		hint_panel.modulate.a = 1.0
		hint_panel.visible = true
		hint_last_text = ""
		hint_show_time = 0.0
		return
	# курица или снежок в руках - подсказка о броске важнее любой другой и не
	# зависит от взгляда (руки заняты - остальные действия всё равно недоступны)
	if held_chicken_path != "":
		if chicken_throw_charge_t > 0.0:
			var ratio = int(clamp(chicken_throw_charge_t / CHICKEN_THROW_CHARGE_TIME, 0.0, 1.0) * 100.0)
			hint_label.text = "Сила броска: %d%%" % ratio
		else:
			hint_label.text = "[ПКМ]   Кинуть курицу"
		hint_panel.modulate.a = 1.0
		hint_panel.visible = true
		hint_last_text = ""
		hint_show_time = 0.0
		return
	if has_snowball:
		hint_label.text = "[ЛКМ]   Кинуть снежок"
		hint_panel.modulate.a = 1.0
		hint_panel.visible = true
		hint_last_text = ""
		hint_show_time = 0.0
		return
	if held_log_id != "":
		if petya_node and petya_node.has_node("DropZone") and global_position.distance_to(petya_node.get_node("DropZone").global_position) <= QUEST_DROPZONE_RADIUS:
			hint_label.text = "[G]   Отдать бревно Пете"
		elif fireplace_node and global_position.distance_to(fireplace_node.global_position) <= WARM_RADIUS:
			hint_label.text = "[Q]   Положить бревно в камин"
		else:
			hint_label.text = "[F]   Бросить бревно"
		hint_panel.modulate.a = 1.0
		hint_panel.visible = true
		hint_last_text = ""
		hint_show_time = 0.0
		return

	var space_state = get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from + (-camera.global_transform.basis.z) * 3.0
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)
	var text = ""
	if result and result.collider.is_in_group("tree"):
		var tree_path = str(get_tree().current_scene.get_path_to(result.collider.get_parent()))
		if snow_sync.tree_cooldowns.has(tree_path):
			text = "Вырастет через %d с" % int(ceil(snow_sync.tree_cooldowns[tree_path]))
		elif not has_axe:
			text = "Нужен топор"
		else:
			text = "[E]   Рубить дерево"
	elif result and result.collider.is_in_group("tower"):
		var tower_path = str(get_tree().current_scene.get_path_to(result.collider))
		if snow_sync.tower_broken.get(tower_path, false):
			text = "[T]   Починить вышку"
		else:
			text = "Вышка исправна"
	elif result and result.collider.is_in_group("snow"):
		text = "[ЛКМ]   Убрать кучу снега"
	elif result and result.collider.is_in_group("chicken") and global_position.distance_to(result.collider.global_position) <= CHICKEN_PICKUP_RADIUS:
		text = "[ЛКМ]   Взять курицу"
	elif petya_node and global_position.distance_to(petya_node.global_position) <= QUEST_INTERACT_RADIUS:
		text = "[G]   Задания у Пети   |   [зажать V]   Поговорить"
	elif _torch_pickup_pos() != null and global_position.distance_to(_torch_pickup_pos()) <= TORCH_PICKUP_RADIUS:
		text = "[G]   Взять факел"
	elif held_chicken_path == "" and not has_snowball and not has_axe:
		# топор и бревно оба поднимаются клавишей F - подсказка должна называть
		# тот предмет, который реально ближе, а не всегда топор (см. interact)
		var axe_in_range = axe_node and is_instance_valid(axe_node) and axe_node.visible and global_position.distance_to(axe_node.global_position) <= AXE_PICKUP_RADIUS
		var axe_dist = global_position.distance_to(axe_node.global_position) if axe_in_range else INF
		var found_log = snow_sync.nearest_log_in_range(global_position, LOG_PICKUP_RADIUS)
		var log_dist = global_position.distance_to(snow_sync.logs[found_log]["pos"]) if found_log != "" else INF
		if axe_in_range and axe_dist <= log_dist:
			text = "[F]   Поднять топор"
		elif found_log != "":
			text = "[F]   Поднять бревно"
	elif result and not has_axe and snow_sync and snow_sync.snow_depth_at(result.position) >= SNOWBALL_MIN_DEPTH:
		text = "[ЛКМ]   Слепить снежок"

	if text == "":
		hint_panel.visible = false
		hint_last_text = ""
		hint_show_time = 0.0
		return

	if text != hint_last_text:
		hint_last_text = text
		hint_show_time = 0.0
	else:
		hint_show_time += delta
	hint_label.text = text

	var fade = clamp((hint_show_time - HINT_FADE_AFTER) / HINT_FADE_DURATION, 0.0, 1.0)
	hint_panel.modulate.a = 1.0 - fade
	hint_panel.visible = fade < 1.0

	hint_sway_time += delta
	var sway_y = sin(hint_sway_time * HINT_SWAY_FREQ) * HINT_SWAY_AMP
	var sway_x = sin(hint_sway_time * HINT_SWAY_FREQ * 0.7 + 1.0) * (HINT_SWAY_AMP * 0.5)
	hint_panel.offset_left = HINT_BASE_LEFT + sway_x
	hint_panel.offset_right = HINT_BASE_RIGHT + sway_x
	hint_panel.offset_top = HINT_BASE_TOP + sway_y
	hint_panel.offset_bottom = HINT_BASE_BOTTOM + sway_y

func _is_indoors(pos: Vector3) -> bool:
	return pos.x > HOUSE_MIN.x and pos.x < HOUSE_MAX.x and pos.z > HOUSE_MIN.z and pos.z < HOUSE_MAX.z and pos.y > HOUSE_MIN.y and pos.y < HOUSE_MAX.y

# где висит курица, пока игрок её держит в руках - сюда её каждый кадр ставит
# хост (см. State.HELD в chicken.gd); используется по имени через has_method,
# поэтому сигнатура не должна меняться без правки chicken.gd
func get_chicken_hold_position() -> Vector3:
	return camera.global_position + (-camera.global_transform.basis.z) * CHICKEN_HOLD_FORWARD - Vector3(0, CHICKEN_HOLD_DOWN, 0)

# ПКМ зажата - копим силу броска; отпустили - кидаем курицу вперёд по дуге
func _update_chicken_hold(delta: float):
	if held_chicken_path == "":
		chicken_throw_charge_t = 0.0
		chicken_rmb_was_down = false
		return
	var rmb_down = not input_locked and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if rmb_down:
		chicken_throw_charge_t = min(chicken_throw_charge_t + delta, CHICKEN_THROW_CHARGE_TIME)
	elif chicken_rmb_was_down:
		var ratio = chicken_throw_charge_t / CHICKEN_THROW_CHARGE_TIME
		var force = lerp(CHICKEN_THROW_MIN_FORCE, CHICKEN_THROW_MAX_FORCE, ratio)
		var vel = (-camera.global_transform.basis.z) * force
		vel.y += force * 0.28   # лёгкая дуга вверх, чтобы не кидать в землю под ногами
		snow_sync.throw_chicken.rpc(held_chicken_path, vel)
		held_chicken_path = ""
		chicken_throw_charge_t = 0.0
	chicken_rmb_was_down = rmb_down

func _update_tower_repair():
	if input_locked or not Input.is_action_just_pressed("repair_tower"):
		return
	var space_state = get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from + (-camera.global_transform.basis.z) * 3.0
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)
	if result and result.collider.is_in_group("tower"):
		var path = str(get_tree().current_scene.get_path_to(result.collider))
		if snow_sync.tower_broken.get(path, false):
			snow_sync.repair_tower.rpc(path)

# снег вокруг игрока, падающий сверху вниз; привязан к телу игрока (не к камере),
# чтобы не наклонялся вместе со взглядом при движении головой вверх/вниз
func _build_snowfall():
	snowfall_particles = GPUParticles3D.new()
	snowfall_particles.position = Vector3(0, 3.0, 0)
	snowfall_particles.amount = 140
	snowfall_particles.lifetime = 3.0
	snowfall_particles.explosiveness = 0.0
	snowfall_particles.randomness = 0.4
	snowfall_particles.local_coords = true
	snowfall_particles.amount_ratio = SNOWFALL_BASE_RATIO

	var pm = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(7.0, 0.3, 7.0)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 12.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 1.8
	pm.gravity = Vector3(0, -0.4, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.2

	var mesh = QuadMesh.new()
	mesh.size = Vector2(0.035, 0.035)
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(1, 1, 1, 0.85)
	mesh.material = mat
	snowfall_particles.draw_pass_1 = mesh
	snowfall_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	snowfall_particles.emitting = true
	add_child(snowfall_particles)

# гуще во время метели, тише в обычную погоду; в доме снегу падать неоткуда
func _update_snowfall():
	if not snowfall_particles:
		return
	var indoor = _is_indoors(global_position)
	var target_ratio = SNOWFALL_BASE_RATIO
	if snow_sync:
		target_ratio = lerp(SNOWFALL_BASE_RATIO, SNOWFALL_MAX_RATIO, snow_sync.blizzard_intensity)
	snowfall_particles.amount_ratio = 0.0 if indoor else target_ratio

# тепло, здоровье и эффект снега под ногами - только у своего игрока
func _update_survival(delta: float, snow_depth: float):
	var near_fire = false
	if fireplace_node and snow_sync and snow_sync.fireplace_lit:
		near_fire = global_position.distance_to(fireplace_node.global_position) <= WARM_RADIUS
	# куриц считаем, только если вообще в доме - на улице они ни на что не влияют
	var chickens_indoors = 0
	if _is_indoors(global_position):
		for c in get_tree().get_nodes_in_group("chicken"):
			if is_instance_valid(c) and c.is_inside_tree() and _is_indoors(c.global_position):
				chickens_indoors += 1
	if near_fire:
		# чем больше куриц в доме, тем слабее греет камин; при полном доме куриц
		# может выйти в минус - тогда камин уже не спасает от холода
		warmth += (WARM_RATE - chickens_indoors * CHICKEN_FIRE_PENALTY) * delta
	elif _is_indoors(global_position):
		warmth -= (INDOOR_DECAY + chickens_indoors * CHICKEN_COLD_PENALTY) * delta
	else:
		var blizzard_penalty = 0.0
		if snow_sync:
			blizzard_penalty = snow_sync.blizzard_intensity * BLIZZARD_COLD_PENALTY
		warmth -= (OUTDOOR_DECAY + snow_depth * SNOW_EXTRA_DECAY + blizzard_penalty) * delta
	warmth = clamp(warmth, 0.0, WARMTH_MAX)

	if warmth <= 0.0:
		hp -= HP_DECAY_COLD * delta
	elif warmth >= WARM_SAFE:
		hp += HP_REGEN_WARM * delta
	hp = clamp(hp, 0.0, HP_MAX)

	if hp <= 0.0:
		_respawn()

	if not input_locked and Input.is_action_just_pressed("interact"):
		if has_axe:
			has_axe = false
			var forward = -camera.global_transform.basis.z
			var drop_pos = global_position + Vector3(0, AXE_DROP_UP, 0) + forward * AXE_DROP_FORWARD
			var impulse = forward * AXE_DROP_IMPULSE + Vector3(0, 0.4, 0)
			snow_sync.drop_axe.rpc(get_multiplayer_authority(), drop_pos, impulse)
		elif held_log_id != "":
			# кидаем бревно на землю перед собой - тоже физикой (падает и катится),
			# а не мгновенным телепортом
			var forward2 = -camera.global_transform.basis.z
			var drop_pos2 = global_position + Vector3(0, LOG_DROP_UP, 0) + forward2 * LOG_DROP_FORWARD
			var impulse2 = forward2 * LOG_DROP_IMPULSE + Vector3(0, 0.4, 0)
			snow_sync.drop_log.rpc(held_log_id, drop_pos2, impulse2)
			held_log_id = ""
			_unequip_log()
		elif held_chicken_path == "" and not has_snowball:
			# топор и бревно оба поднимаются клавишей F - если оба рядом,
			# нужно поднять тот, что реально ближе, а не всегда топор
			var axe_in_range = axe_node and is_instance_valid(axe_node) and axe_node.visible and global_position.distance_to(axe_node.global_position) <= AXE_PICKUP_RADIUS
			var axe_dist = global_position.distance_to(axe_node.global_position) if axe_in_range else INF
			var found_log = snow_sync.nearest_log_in_range(global_position, LOG_PICKUP_RADIUS)
			var log_dist = global_position.distance_to(snow_sync.logs[found_log]["pos"]) if found_log != "" else INF
			if axe_in_range and axe_dist <= log_dist:
				has_axe = true
				snow_sync.pickup_axe.rpc(get_multiplayer_authority())
			elif found_log != "":
				held_log_id = found_log
				snow_sync.pickup_log.rpc(found_log, get_multiplayer_authority())
				_equip_log()

	if not input_locked and Input.is_action_just_pressed("feed_fire") and held_log_id != "" and fireplace_node:
		if global_position.distance_to(fireplace_node.global_position) <= WARM_RADIUS:
			if snow_sync.fireplace_lit:
				snow_sync._flash_toast("Камин уже полон")
			else:
				snow_sync.feed_log_to_fire.rpc(held_log_id)
				held_log_id = ""
				_unequip_log()

	if not input_locked and Input.is_action_just_pressed("quest_interact"):
		var dropzone = petya_node.get_node_or_null("DropZone") if petya_node else null
		if has_torch:
			# бросаем факел на землю перед собой с настоящей физикой (падает,
			# кувыркается, укладывается сам - см. drop_to_ground в torch.gd),
			# а не телепортом обратно на стену
			has_torch = false
			var forward = -camera.global_transform.basis.z
			var drop_pos = global_position + Vector3(0, TORCH_DROP_UP, 0) + forward * TORCH_DROP_FORWARD
			var impulse = forward * TORCH_DROP_IMPULSE + Vector3(0, 0.4, 0)
			snow_sync.drop_torch.rpc(get_multiplayer_authority(), drop_pos, impulse)
		elif held_log_id != "" and dropzone and global_position.distance_to(dropzone.global_position) <= QUEST_DROPZONE_RADIUS:
			snow_sync.deliver_log_to_quest.rpc("petya_wood", held_log_id)
			held_log_id = ""
			_unequip_log()
			if petya_voice:
				petya_voice.trigger_proactive("(игрок только что принёс тебе бревно и положил на коврик)")
		elif petya_node and global_position.distance_to(petya_node.global_position) <= QUEST_INTERACT_RADIUS:
			quest_menu.open()
		elif _torch_pickup_pos() != null and global_position.distance_to(_torch_pickup_pos()) <= TORCH_PICKUP_RADIUS:
			has_torch = true
			snow_sync.pickup_torch.rpc(get_multiplayer_authority())

	_update_hud()
	_update_frost_overlay()
	_update_splat_overlay(delta)

func _respawn():
	var spawn = get_tree().current_scene.get_node("PlayerSpawn").global_position
	global_position = spawn
	velocity = Vector3.ZERO
	hp = 40.0
	warmth = 40.0

# Вместо тела у других игроков виден только их ник над головой.
func _build_nameplate():
	nameplate = Label3D.new()
	nameplate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	nameplate.font_size = 64
	nameplate.pixel_size = 0.004
	nameplate.outline_size = 14
	nameplate.outline_modulate = Color(0, 0, 0, 1)
	nameplate.modulate = Color.from_hsv(fmod(float(get_multiplayer_authority()) * 0.137, 1.0), 0.35, 1.0)
	nameplate.position = Vector3(0, 1.1, 0)
	nameplate.text = nickname
	add_child(nameplate)

# --- отставание рук от поворота камеры (небольшая "пружинка" при резких поворотах) ---
const ARM_LOOK_LAG = 0.6       # доля скачка камеры, на которую руки временно не успевают
const ARM_LAG_MAX = 0.6        # предел отставания, радианы
const ARM_LAG_RECOVER = 9.0    # скорость возврата рук к камере (выше = быстрее)
var arm_lag_pitch = 0.0
var arm_lag_yaw = 0.0

func _input(event):
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseMotion:
		var dy = -event.relative.x * mouse_sensitivity
		var dx = -event.relative.y * mouse_sensitivity
		rotate_y(dy)
		head.rotate_x(dx)
		head.rotation.x = clamp(head.rotation.x, -1.5, 1.5)
		arm_lag_yaw = clamp(arm_lag_yaw - dy * ARM_LOOK_LAG, -ARM_LAG_MAX, ARM_LAG_MAX)
		arm_lag_pitch = clamp(arm_lag_pitch - dx * ARM_LOOK_LAG, -ARM_LAG_MAX, ARM_LAG_MAX)

func _physics_process(delta):
	if not is_multiplayer_authority():
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
	if not input_locked and Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir = Vector2.ZERO if input_locked else Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	var speed = SPEED
	if snow_sync and is_on_floor():
		speed = SPEED * lerp(1.0, SNOW_SLOW_MIN, snow_sync.snow_depth_at(global_position))
	if not input_locked and Input.is_action_pressed("sprint"):
		speed *= SPRINT_MULT
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	# метель сносит в сторону при ходьбе на улице - в доме стены защищают
	if snow_sync and snow_sync.blizzard_intensity > 0.0 and is_on_floor() and not _is_indoors(global_position):
		var push = BLIZZARD_WIND_DIR * (snow_sync.blizzard_intensity * BLIZZARD_WIND_PUSH)
		velocity.x += push.x
		velocity.z += push.z

	move_and_slide()
	_update_bob(delta)
	_update_torch_walk_fx(delta)
	if is_multiplayer_authority():
		var snow_depth = 0.0
		if snow_sync and is_on_floor():
			snow_depth = snow_sync.snow_depth_at(global_position)
		_update_survival(delta, snow_depth)
		_update_breath_fog(delta)
		_update_snowfall()
		if snow_sync:
			snow_sync.update_wind_indoor(_is_indoors(global_position), delta)
		_update_tower_repair()
		_update_chicken_hold(delta)
		_update_torch_flicker(delta)
		_update_interact_hint(delta)

func _unhandled_input(event):
	if not is_multiplayer_authority() or input_locked:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var space_state = get_world_3d().direct_space_state
		var from = camera.global_position
		var to = from + (-camera.global_transform.basis.z) * 3.0
		var query = PhysicsRayQueryParameters3D.create(from, to)
		var result = space_state.intersect_ray(query)
		if has_snowball:
			# снежок уже в руках - ЛКМ теперь всегда кидает его, невзирая на цель
			has_snowball = false
			_unequip_snowball()
			var vel = (-camera.global_transform.basis.z) * SNOWBALL_THROW_FORCE
			vel.y += SNOWBALL_THROW_FORCE * 0.12
			snow_sync.throw_snowball.rpc(camera.global_position, vel, get_multiplayer_authority())
		elif result and result.collider.is_in_group("snow"):
			# куча снега исчезает у всех игроков
			snow_sync.remove_pile.rpc(str(result.collider.name))
		elif result and held_chicken_path == "" and result.collider.is_in_group("chicken") and global_position.distance_to(result.collider.global_position) <= CHICKEN_PICKUP_RADIUS:
			# берём курицу в руки (кинуть её потом можно, зажав и отпустив ПКМ)
			var chicken_path = str(get_tree().current_scene.get_path_to(result.collider))
			held_chicken_path = chicken_path
			snow_sync.pickup_chicken.rpc(chicken_path, get_multiplayer_authority())
		elif result and held_chicken_path == "" and not has_axe and snow_sync and snow_sync.snow_depth_at(result.position) >= SNOWBALL_MIN_DEPTH:
			# лепим снежок из снега на земле, куда смотрим
			has_snowball = true
			_equip_snowball()

func _update_bob(delta):
	var horizontal_speed = Vector2(velocity.x, velocity.z).length()
	var target_pos = Vector3.ZERO
	var target_roll = 0.0
	if is_on_floor() and horizontal_speed > 0.1:
		bob_time += delta * BOB_FREQ * (horizontal_speed / SPEED)
		# |sin| даёт "прыжок" на каждый шаг, sin(t/2) - покачивание вправо-влево
		target_pos.y = abs(sin(bob_time)) * BOB_AMP_Y
		target_pos.x = sin(bob_time * 0.5) * BOB_AMP_X
		target_roll = sin(bob_time * 0.5) * BOB_ROLL
	else:
		# при остановке фаза плавно сбрасывается, чтобы не дёргалось
		bob_time = 0.0
	if digging:
		# при ударе камера чуть "клюёт" вниз
		target_pos.y -= sin(PI * clamp((dig_t - 0.35) / 0.4, 0.0, 1.0)) * 0.02
	var t = clamp(delta * BOB_SMOOTH, 0.0, 1.0)
	camera.position = camera.position.lerp(target_pos, t)
	camera.rotation.z = lerp(camera.rotation.z, target_roll, t)

# --- копка: одно нажатие E = один взмах руками (зажатие не копает) ---
const DIG_TIME = 0.55          # длительность взмаха, сек (заодно пауза между взмахами)
const DIG_STRIKE_AT = 0.5      # в какой момент взмаха снег реально убирается (0..1)
@export var digging = false
@export var dig_t = 0.0                # прогресс взмаха 0..1
var dig_stamped = false        # удар по снегу в этом взмахе уже был

# --- руки от первого лица (строятся кодом, без правок сцены) ---
const ARM_IDLE_PITCH = -12.0   # поза покоя: руки чуть опущены (градусы)
const ARM_IDLE_YAW = 9.0       # руки чуть сведены к центру
const ARM_RAISE_PITCH = 42.0   # замах
const ARM_STRIKE_PITCH = -48.0 # удар вниз
var arms: Node3D
var arm_pivots: Array = []     # [левая, правая]

# --- готовая 3D-модель рук: файл hands.glb в папке проекта (модель смотрит в +Z, поэтому поворот Y=180) ---
const HANDS_MODEL_PATHS = ["res://hands.glb", "res://hands.gltf", "res://hands.tscn"]
const HANDS_PIVOT = Vector3(0.0, -0.35, 0.15)         # "плечо": вокруг этой точки руки машут при копке
const HANDS_POSITION = Vector3(-0.015, -0.364, -0.275) # где стоит модель относительно камеры
const HANDS_ROTATION_DEG = Vector3(0.0, 180.0, 0.0)   # пальцы вперёд от камеры
const HANDS_SCALE = Vector3(0.9, 0.9, 0.9)            # размер модели
var hands_pivot: Node3D

# --- анимация копки руками: поочерёдно тянутся к снегу и сгребают его (единицы - см модели) ---
const REACH_FWD = 34.0      # насколько рука тянется вперёд
const REACH_DOWN = 30.0     # насколько опускается к снегу
const REACH_IN = 14.0       # смещение к центру экрана (к прицелу)
const REACH_TILT_DEG = 38.0 # наклон кисти вниз при протягивании
var skel: Skeleton3D
var hand_bones = {}         # 0 = левая, 1 = правая: {arm, arm_pos, arm_rot, fingers}
var anim_player: AnimationPlayer   # встроенная анимация покоя (покачивание рук)
var hands_dirty = false             # кости сейчас выставлены нашим кодом, а не анимацией
@export var active_hand = 0         # какая рука копает в текущем взмахе
var next_hand = 0
var walk_mod: Node
var dip_l = 0.0                 # текущее опускание левой/правой руки (0..1)
var dip_r = 0.0
const HAND_DIP_SPEED = 14.0     # как быстро рука опускается и возвращается
const HAND_DIP_SAME_SIDE = true # true: левая нога - левая рука вниз; false: наоборот

# маленькая копия поднятого топора по центру перед руками; ставим его вертикально,
# поворачивая исходную "лежащую" модель по её собственной длинной оси (AXE_MODEL_AXIS)
func _equip_axe():
	if held_axe:
		return
	held_axe = MeshInstance3D.new()
	held_axe.mesh = HELD_AXE_MESH
	var target_up = Vector3(0, 1, 0)
	var axis = AXE_MODEL_AXIS.cross(target_up)
	var rot_basis = Basis.IDENTITY
	if axis.length() > 0.001:
		rot_basis = Basis(axis.normalized(), AXE_MODEL_AXIS.angle_to(target_up))
	held_axe.transform = Transform3D(rot_basis.scaled(Vector3.ONE * HELD_AXE_SCALE), HELD_AXE_POSITION)
	arms.add_child(held_axe)
	_update_hud()

# выбросили топор - убираем копию из рук (сам топор на земле показывает/двигает snow_sync)
func _unequip_axe():
	if held_axe:
		held_axe.queue_free()
		held_axe = null
	_update_hud()

# слепленный снежок перед руками - простой белый шарик, без сети (в отличие от
# курицы или топора, никто другой его "в руке" не видит - это чисто личный визуал)
func _equip_snowball():
	if held_snowball:
		return
	held_snowball = MeshInstance3D.new()
	var mesh = SphereMesh.new()
	mesh.radius = 0.055
	mesh.height = 0.11
	held_snowball.mesh = mesh
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.97, 1.0)
	mat.roughness = 0.7
	held_snowball.material_override = mat
	held_snowball.position = HELD_SNOWBALL_POSITION
	arms.add_child(held_snowball)

func _unequip_snowball():
	if held_snowball:
		held_snowball.queue_free()
		held_snowball = null

# бревно перед руками, пока несём - та же модель-цилиндр, что и на земле у дерева,
# только чуть меньше, чтобы не перекрывать вид
func _equip_log():
	if held_log_mesh:
		return
	held_log_mesh = snow_sync.make_log_mesh()
	held_log_mesh.scale = Vector3.ONE * 0.6
	held_log_mesh.position = HELD_LOG_POSITION
	arms.add_child(held_log_mesh)
	_update_hud()

func _unequip_log():
	if held_log_mesh:
		held_log_mesh.queue_free()
		held_log_mesh = null
	_update_hud()

func _build_arms():
	arms = Node3D.new()
	arms.name = "Arms"
	camera.add_child(arms)
	if _try_load_hands_model():
		return
	var sleeve = StandardMaterial3D.new()
	sleeve.albedo_color = Color(0.16, 0.24, 0.42)
	sleeve.roughness = 0.9
	var glove = StandardMaterial3D.new()
	glove.albedo_color = Color(0.85, 0.45, 0.12)
	glove.roughness = 0.8
	for side in [-1.0, 1.0]:
		var pivot = Node3D.new()
		pivot.position = Vector3(side * 0.27, -0.32, -0.15)   # "плечо" ниже камеры
		arms.add_child(pivot)
		var forearm = MeshInstance3D.new()
		var cap = CapsuleMesh.new()
		cap.radius = 0.05
		cap.height = 0.5
		forearm.mesh = cap
		forearm.material_override = sleeve
		forearm.rotation_degrees = Vector3(90, 0, 0)          # капсула вдоль -Z
		forearm.position = Vector3(0, 0, -0.25)
		pivot.add_child(forearm)
		var hand = MeshInstance3D.new()
		var sph = SphereMesh.new()
		sph.radius = 0.065
		sph.height = 0.13
		hand.mesh = sph
		hand.material_override = glove
		hand.position = Vector3(0, 0, -0.52)
		hand.scale = Vector3(1.0, 0.8, 1.2)
		pivot.add_child(hand)
		arm_pivots.append(pivot)
	_pose_arms(ARM_IDLE_PITCH, ARM_IDLE_YAW)

func _try_load_hands_model() -> bool:
	for path in HANDS_MODEL_PATHS:
		if ResourceLoader.exists(path):
			var scene = load(path)
			if scene is PackedScene:
				hands_pivot = Node3D.new()
				hands_pivot.position = HANDS_PIVOT
				arms.add_child(hands_pivot)
				var model = scene.instantiate()
				model.position = HANDS_POSITION - HANDS_PIVOT
				model.rotation_degrees = HANDS_ROTATION_DEG
				model.scale = HANDS_SCALE
				hands_pivot.add_child(model)
				hands_model = model
				# встроенная анимация покоя (покачивание рук) играет по кругу;
				# на время копки она отключается, и кости рук двигаем сами (см. _update_hand_bones)
				_setup_hand_bones(model)
				var found = model.find_child("AnimationPlayer", true, false)
				if found is AnimationPlayer:
					anim_player = found
					var anim_name = "Idle"
					if not anim_player.has_animation(anim_name):
						var list = anim_player.get_animation_list()
						anim_name = list[0] if list.size() > 0 else ""
					if anim_name != "":
						anim_player.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
						anim_player.play(anim_name)
				return true
	return false

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var r = _find_skeleton(c)
		if r:
			return r
	return null

func _setup_hand_bones(model: Node):
	skel = _find_skeleton(model)
	if skel == null:
		push_warning("В модели рук нет Skeleton3D - копка будет без движения пальцев")
		return
	var sides = ["Left", "Right"]
	for si in range(2):
		var side = sides[si]
		var d = {"arm": -1, "arm_pos": Vector3.ZERO, "arm_rot": Quaternion.IDENTITY, "fingers": []}
		for i in range(skel.get_bone_count()):
			var bname = skel.get_bone_name(i)
			var rest = skel.get_bone_rest(i)
			# корень руки: J_Left_02 / J_Right_023 (без слова Hand в названии)
			if bname.begins_with("J_%s_" % side) and not bname.contains("Hand"):
				d["arm"] = i
				d["arm_pos"] = rest.origin
				d["arm_rot"] = rest.basis.get_rotation_quaternion()
			elif bname.contains("J_%s_Hand" % side):
				for f in ["Index", "Middle", "Ring", "Pinky"]:
					for k in [1, 2, 3]:
						if bname.contains("Hand%s%d_" % [f, k]):
							var deg = [35.0, 50.0, 35.0][k - 1]
							d["fingers"].append({"idx": i, "rest": rest.basis.get_rotation_quaternion(), "deg": deg})
				for k in [2, 3]:
					if bname.contains("HandThumb%d_" % k):
						d["fingers"].append({"idx": i, "rest": rest.basis.get_rotation_quaternion(), "deg": 22.0})
		hand_bones[si] = d
		if d["arm"] < 0:
			push_warning("Не найдена кость руки для стороны " + side)
	# опускание руки на шаге (см. hand_walk_modifier.gd)
	walk_mod = preload("res://hand_walk_modifier.gd").new()
	skel.add_child(walk_mod)
	walk_mod.bones = [hand_bones[0]["arm"], hand_bones[1]["arm"]]

# e: насколько рука вытянута (0..1), c: насколько сжаты пальцы (0..1)
func _hand_curves(t: float) -> Vector2:
	var e = 0.0
	if t < 0.45:
		e = smoothstep(0.0, 1.0, t / 0.45)
	elif t < 0.5:
		e = 1.0
	else:
		e = 1.0 - smoothstep(0.0, 1.0, (t - 0.5) / 0.5)
	var c = smoothstep(0.0, 1.0, (t - 0.35) / 0.15) * (1.0 - smoothstep(0.0, 1.0, (t - 0.8) / 0.2))
	return Vector2(e, c)

func _update_hand_bones():
	if skel == null:
		return
	# пока идёт копка, анимация покоя выключена, иначе она перезаписывает кости
	if anim_player:
		anim_player.active = not digging
	if not digging and not hands_dirty:
		return
	hands_dirty = digging
	for si in range(2):
		if not hand_bones.has(si):
			continue
		var d = hand_bones[si]
		if d["arm"] < 0:
			continue
		var e = 0.0
		var c = 0.0
		if digging and si == active_hand:
			var v = _hand_curves(dig_t)
			e = v.x
			c = v.y
		var inward = -REACH_IN if si == 0 else REACH_IN   # левая рука в модели справа по X
		var offset = Vector3(inward, -REACH_DOWN, REACH_FWD) * e
		skel.set_bone_pose_position(d["arm"], d["arm_pos"] + offset)
		var tilt = Quaternion(Vector3.RIGHT, deg_to_rad(REACH_TILT_DEG * e))
		skel.set_bone_pose_rotation(d["arm"], tilt * d["arm_rot"])
		for f in d["fingers"]:
			var curl = Quaternion(Vector3.RIGHT, deg_to_rad(f["deg"] * c))
			skel.set_bone_pose_rotation(f["idx"], f["rest"] * curl)

func _pose_arms(pitch: float, yaw_in: float):
	if hands_pivot:
		# модель рук: двигаются отдельные кости (см. _update_hand_bones)
		_update_hand_bones()
		return
	arm_pivots[0].rotation_degrees = Vector3(pitch, -yaw_in, 0)
	arm_pivots[1].rotation_degrees = Vector3(pitch, yaw_in, 0)

# перебирает все MeshInstance3D внутри модели рук - у скелетной модели их обычно
# несколько (кисти/предплечья отдельными сетками), тон нужно наложить на каждую
func _find_mesh_instances(node: Node) -> Array:
	var result = []
	if node is MeshInstance3D:
		result.append(node)
	for c in node.get_children():
		result.append_array(_find_mesh_instances(c))
	return result

# перекраска перчаток: albedo_color поверх albedo_texture в StandardMaterial3D
# просто умножает цвет текстуры (сама текстура не портится), поэтому это тон, а не
# замена материала; "Обычные" (без color в HAND_COLORS) - возврат к исходному материалу
func _apply_hand_color():
	if not hands_model:
		return
	var opt = HAND_COLORS[clamp(hand_color_id, 0, HAND_COLORS.size() - 1)]
	var color = opt.get("color")
	for mi in _find_mesh_instances(hands_model):
		if color == null:
			mi.material_override = null
			continue
		var mat = mi.get_active_material(0)
		if mat is StandardMaterial3D:
			var dup: StandardMaterial3D = mat.duplicate()
			dup.albedo_color = color
			mi.material_override = dup

func _update_arms(delta):
	if hand_color_id != _last_hand_color_id:
		_last_hand_color_id = hand_color_id
		_apply_hand_color()
	var lag_t = clamp(delta * ARM_LAG_RECOVER, 0.0, 1.0)
	arm_lag_pitch = lerp(arm_lag_pitch, 0.0, lag_t)
	arm_lag_yaw = lerp(arm_lag_yaw, 0.0, lag_t)
	if arms:
		arms.rotation = Vector3(arm_lag_pitch, arm_lag_yaw, 0)
	var pitch = ARM_IDLE_PITCH
	var yaw_in = ARM_IDLE_YAW
	if digging:
		var t = dig_t
		if t < 0.35:        # замах: руки поднимаются
			var k = smoothstep(0.0, 1.0, t / 0.35)
			pitch = lerp(ARM_IDLE_PITCH, ARM_RAISE_PITCH, k)
			yaw_in = lerp(ARM_IDLE_YAW, 16.0, k)
		elif t < 0.65:      # удар: быстро вниз и вперёд
			var k = (t - 0.35) / 0.3
			pitch = lerp(ARM_RAISE_PITCH, ARM_STRIKE_PITCH, k * k)
			yaw_in = lerp(16.0, 22.0, k)
		else:               # возврат в позу покоя
			var k = smoothstep(0.0, 1.0, (t - 0.65) / 0.35)
			pitch = lerp(ARM_STRIKE_PITCH, ARM_IDLE_PITCH, k)
			yaw_in = lerp(22.0, ARM_IDLE_YAW, k)
	else:
		# лёгкое "дыхание" рук при ходьбе
		if is_on_floor() and Vector2(velocity.x, velocity.z).length() > 0.1:
			pitch += sin(bob_time) * 1.5
	# рука на стороне шагающей ноги чуть опускается в момент касания земли
	var target_l = 0.0
	var target_r = 0.0
	if is_multiplayer_authority() and not digging and is_on_floor():
		var spd = Vector2(velocity.x, velocity.z).length()
		if spd > 0.1:
			var contact = pow(1.0 - abs(sin(bob_time)), 1.5)
			var side = cos(bob_time) * (1.0 if HAND_DIP_SAME_SIDE else -1.0)
			var w = clamp(spd / SPEED, 0.0, 1.0)
			target_l = max(0.0, contact * side) * w
			target_r = max(0.0, -contact * side) * w
	var dip_t = clamp(delta * HAND_DIP_SPEED, 0.0, 1.0)
	dip_l = lerp(dip_l, target_l, dip_t)
	dip_r = lerp(dip_r, target_r, dip_t)
	if walk_mod:
		walk_mod.amount = [dip_l, dip_r]
	_pose_arms(pitch, yaw_in)

func _try_dig_hit():
	var space_state = get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from + (-camera.global_transform.basis.z) * 3.0
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)
	if result:
		if result.collider.is_in_group("tree"):
			if not has_axe:
				return   # без топора дерево не срубить
			# рубка дерева: попали в его коллизию (узел "Collision" внутри модели),
			# а убрать нужно всё дерево целиком - его родителя; путь одинаков у всех
			var tree_root = result.collider.get_parent()
			var tree_path = str(get_tree().current_scene.get_path_to(tree_root))
			# бревно кладём в точку самого попадания луча (result.position), а НЕ
			# в tree_root.global_position: у моделей леса (Elka/Tree_2Snow) реальная
			# коллизия смещена от узла-корня на несколько метров из-за трансформации
			# родительского узла "Forest" - из-за этого бревно вылетало далеко от дерева
			var log_pos = result.position
			log_pos.y = snow_sync.LOG_RADIUS
			log_pos.x += randf_range(-0.4, 0.4)
			log_pos.z += randf_range(-0.4, 0.4)
			snow_sync.chop_tree.rpc(tree_path, get_multiplayer_authority(), log_pos)
		else:
			# копка видна всем: событие уходит всем игрокам и запоминается на хосте
			snow_sync.dig.rpc(result.position)

func _process(delta):
	if is_multiplayer_authority():
		if not digging and not input_locked and Input.is_action_just_pressed("clear_snow"):
			digging = true
			dig_t = 0.0
			dig_stamped = false
			active_hand = next_hand
			snow_sync.dig_swish.rpc(camera.global_position - camera.global_transform.basis.z * 0.8)
			next_hand = 1 - next_hand
		if digging:
			dig_t += delta / DIG_TIME
			if not dig_stamped and dig_t >= DIG_STRIKE_AT:
				dig_stamped = true
				_try_dig_hit()
			if dig_t >= 1.0:
				digging = false
				dig_t = 0.0
	elif nameplate:
		nameplate.text = nickname
	# у чужих игроков digging / dig_t / active_hand приходят по сети - руки двигаются так же
	_update_arms(delta)
