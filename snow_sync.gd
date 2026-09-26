extends Node

# Общий снег для всех игроков: по сети ходят события (копка, след, исчезновение кучи),
# а каждый компьютер сам рисует их у себя. Хост хранит историю для тех, кто зашёл позже.

@onready var snow_mask = get_parent().get_node("SnowMaskViewport")
@onready var snow_trample = get_parent().get_node("SnowTrampleViewport")
var dig_history: Array = []      # только на хосте: Vector3
var print_history: Array = []    # только на хосте: Vector4(x, z, поворот, глубина)
var removed_piles: Array = []    # только на хосте

# топор у дома: один на всех, либо лежит на земле, либо у кого-то в руках.
# узел "Axe" - RigidBody3D (см. _setup_axe_physics), его прячут/замораживают или
# роняют физикой (drop_axe), а не телепортируют мгновенно
var axe_taken: bool = false             # true = сейчас у кого-то в руках, не на земле
var axe_ground_pos: Vector3 = Vector3(1.3, 0.03, -3.0)   # где топор лежит на земле сейчас
var axe_body: RigidBody3D

# факел в доме: тот же принцип, что и у топора - один на всех, либо висит на стене
# (сам узел Torch не двигается и не удаляется, только прячет свою геометрию, см.
# set_mounted в torch.gd), либо у кого-то в руках, либо брошен на землю физикой
# (torch_on_ground) - в отличие от топора, "на земле" тут не фиксированная точка,
# а место падения RigidBody3D (см. drop_to_ground в torch.gd), поэтому позиция
# нужна только чтобы подсказать новым игрокам, где искать факел
var torch_taken: bool = false
var torch_on_ground: bool = false
var torch_ground_pos: Vector3 = Vector3.ZERO

var fireplace_fuel: float = 0.0   # секунд горения осталось (0..FIRE_MAX_FUEL)
var fireplace_lit: bool = false
const FIRE_WOOD_SECONDS = 60.0    # сколько секунд добавляет одно бревно
const FIRE_MAX_FUEL = 240.0

# срубленное дерево остаётся на месте, просто временно не рубится; tree_cooldowns
# хранит оставшееся время до восстановления для каждого дерева. Само окошко с
# таймером рисует player-скрипт той же 2D-подсказкой, что и для камина/подъёма
# топора (см. _update_interact_hint в new_script.gd) - здесь только общий счётчик
const TREE_RESPAWN_TIME = 60.0   # сек, через сколько срубленное дерево можно рубить снова
var tree_cooldowns: Dictionary = {}   # tree_path -> оставшееся время до восстановления, сек

# бревно от срубленного дерева: физический предмет на земле, не попадает в инвентарь
# сразу - его нужно донести до камина в руках (см. new_script.gd). Один топор -
# один дровосек за раз, поэтому rubка не бесконечна: пока лежит не подобранное
# бревно с этого дерева, рубить его снова нельзя (см. chop_tree)
var logs: Dictionary = {}       # tree_path -> {"pos": Vector3, "holder_id": int (-1 = на земле)}
var log_nodes: Dictionary = {}  # tree_path -> локальный узел-бревно у этого игрока (по сети не синхронизируется, только позиция/владелец выше)
const LOG_RADIUS = 0.11
const LOG_LENGTH = 0.7
var _log_material: StandardMaterial3D

# цилиндр-примитив цвета дерева - используется и для бревна на земле, и для копии в руках
func make_log_mesh() -> MeshInstance3D:
	if _log_material == null:
		_log_material = StandardMaterial3D.new()
		_log_material.albedo_color = Color(0.45, 0.3, 0.15)
		_log_material.roughness = 0.9
	var mesh_node = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = LOG_RADIUS
	cyl.bottom_radius = LOG_RADIUS
	cyl.height = LOG_LENGTH
	mesh_node.mesh = cyl
	mesh_node.material_override = _log_material
	mesh_node.rotation_degrees.z = 90.0   # цилиндр по умолчанию стоит вдоль Y - кладём его на бок
	return mesh_node

# бревно на земле - RigidBody3D (та же идея, что и _build_ground_body в torch.gd/
# _setup_axe_physics выше), чтобы брошенное бревно падало и катилось по-настоящему.
# При появлении из срубленного дерева оно просто кладётся на землю замороженным
# (как и раньше) - настоящая физика включается только при броске, см. _show_log_node
func _spawn_log_node(tree_path: String, pos: Vector3):
	var body = RigidBody3D.new()
	body.freeze = true
	var mesh_node = make_log_mesh()
	body.add_child(mesh_node)
	var col = CollisionShape3D.new()
	var shape = CylinderShape3D.new()
	shape.radius = LOG_RADIUS
	shape.height = LOG_LENGTH
	col.rotation_degrees.z = 90.0   # коллизия на боку, как и сам меш бревна
	col.shape = shape
	body.add_child(col)
	body.position = pos
	body.rotation_degrees.y = randf_range(0.0, 360.0)
	get_parent().add_child(body, true)
	log_nodes[tree_path] = body

func _hide_log_node(tree_path: String):
	if log_nodes.has(tree_path) and is_instance_valid(log_nodes[tree_path]):
		log_nodes[tree_path].visible = false
		log_nodes[tree_path].freeze = true

# кинули бревно физикой - падает и катится само, а не мгновенно ложится на землю;
# impulse - лёгкий толчок в момент броска, как у топора/факела
func _show_log_node(tree_path: String, pos: Vector3, impulse: Vector3 = Vector3.ZERO):
	if log_nodes.has(tree_path) and is_instance_valid(log_nodes[tree_path]):
		var body = log_nodes[tree_path]
		body.global_position = pos
		body.rotation = Vector3.ZERO
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.visible = true
		body.freeze = false
		if impulse != Vector3.ZERO:
			body.apply_central_impulse(impulse)

func _remove_log_node(tree_path: String):
	if log_nodes.has(tree_path) and is_instance_valid(log_nodes[tree_path]):
		log_nodes[tree_path].queue_free()
	log_nodes.erase(tree_path)

# ищет действительно ближайшее бревно на земле в радиусе - используется для
# подсказки и подбора (см. new_script.gd). Если рядом лежит несколько бревен,
# должно выбираться то, что реально ближе, а не первое встреченное в словаре -
# иначе игрок не может подобрать второе бревно, пока не заберёт первое
func nearest_log_in_range(pos: Vector3, radius: float) -> String:
	var best_id = ""
	var best_dist = radius
	for id in logs.keys():
		if logs[id]["holder_id"] == -1:
			var d = pos.distance_to(logs[id]["pos"])
			if d <= best_dist:
				best_dist = d
				best_id = id
	return best_id

@rpc("any_peer", "call_local", "reliable")
func pickup_log(log_id: String, picker_id: int):
	if not logs.has(log_id) or logs[log_id]["holder_id"] != -1:
		return
	logs[log_id]["holder_id"] = picker_id
	_hide_log_node(log_id)
	_bump_achievement("first_log")

@rpc("any_peer", "call_local", "reliable")
func drop_log(log_id: String, drop_pos: Vector3, impulse: Vector3 = Vector3.ZERO):
	if not logs.has(log_id):
		return
	logs[log_id]["holder_id"] = -1
	logs[log_id]["pos"] = drop_pos
	_show_log_node(log_id, drop_pos, impulse)

# донесли бревно до камина и скормили - бревно исчезает, огонь получает топливо
@rpc("any_peer", "call_local", "reliable")
func feed_log_to_fire(log_id: String):
	if not logs.has(log_id):
		return
	logs.erase(log_id)
	_remove_log_node(log_id)
	fireplace_fuel = min(FIRE_MAX_FUEL, fireplace_fuel + FIRE_WOOD_SECONDS)
	fireplace_lit = true
	_bump_achievement("first_fire")
	_bump_achievement("fire_keeper_10")

# сохранение квестов - как ачивки, только своим файлом: тоже только на компьютере
# хоста (_save_quests сама проверяет multiplayer.is_server()), тоже общее на партию,
# а не персональное. Нужно, чтобы награда (кастомизация, см. new_script.gd) не
# терялась при перезапуске - без сохранения quest_completed сбрасывался бы каждый раз
const QUESTS_SAVE_PATH = "user://quests.save"

func _load_quests():
	if not FileAccess.file_exists(QUESTS_SAVE_PATH):
		return
	var f = FileAccess.open(QUESTS_SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) == TYPE_DICTIONARY:
		quest_progress = data.get("progress", {})
		quest_completed = data.get("completed", {})
		quest_skipped = data.get("skipped", {})

func _save_quests():
	if not multiplayer.is_server():
		return
	var f = FileAccess.open(QUESTS_SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"progress": quest_progress, "completed": quest_completed, "skipped": quest_skipped}))
	f.close()

# пропустить квест: коврик у Пети перестаёт принимать по нему бревна, в меню
# квест остаётся виден, но помечен как пропущенный (см. quest_menu.gd)
@rpc("any_peer", "call_local", "reliable")
func skip_quest(id: String):
	if not QUESTS.has(id) or quest_completed.get(id, false):
		return
	quest_skipped[id] = true
	_save_quests()

# донесли бревно до красного коврика у Пети и сдали - технически то же самое, что
# и feed_log_to_fire (бревно исчезает из мира), только прибавляет не топливо
# камину, а прогресс квеста; по завершении - общий тост на весь экран у всех игроков
@rpc("any_peer", "call_local", "reliable")
func deliver_log_to_quest(id: String, log_id: String):
	if not QUESTS.has(id) or not logs.has(log_id):
		return
	if quest_completed.get(id, false) or quest_skipped.get(id, false):
		return
	logs.erase(log_id)
	_remove_log_node(log_id)
	quest_progress[id] = quest_progress.get(id, 0) + 1
	if quest_progress[id] >= QUESTS[id]["target"]:
		quest_completed[id] = true
		_flash_toast("🎁 " + QUESTS[id]["name"] + "\nКвест выполнен!")
	_save_quests()

# курица приземлилась после броска (см. chicken.gd _land) - если это рядом с ковриком
# у Пети, засчитываем её в квест "Курицы для Пети". Вызывается обычным вызовом функции
# изнутри RPC _land (call_local, исполняется у всех одинаково с одной и той же
# переданной позицией) - поэтому отдельным RPC оформлять не нужно, как и _bump_achievement
func register_chicken_landing(pos: Vector3):
	var id = "petya_chickens"
	if not QUESTS.has(id) or quest_completed.get(id, false) or quest_skipped.get(id, false):
		return
	var dropzone = get_parent().get_node_or_null("Petya/DropZone")
	if dropzone == null or pos.distance_to(dropzone.global_position) > QUEST_CHICKEN_DROPZONE_RADIUS:
		return
	quest_progress[id] = quest_progress.get(id, 0) + 1
	if quest_progress[id] >= QUESTS[id]["target"]:
		quest_completed[id] = true
		_flash_toast("🎁 " + QUESTS[id]["name"] + "\nКвест выполнен!")
	_save_quests()

# снежки - чисто локальный визуальный эффект, а не сетевой объект вроде курицы:
# у каждого игрока летит своя копия шарика по одной и той же формуле (позиция и
# скорость при броске совпадают у всех), а попадание в СЕБЯ каждый определяет
# сам на своём компьютере - точность тут не критична, это просто веселье
var active_snowballs: Array = []   # [{node, velocity, life, thrower_id}]
const SNOWBALL_GRAVITY = 9.0
const SNOWBALL_LIFETIME = 2.0
const SNOWBALL_HIT_RADIUS = 0.6
var snowball_hit_sounds: Array = []

# пока камин горит, он понемногу растапливает снег внутри дома (тем же способом,
# что и обычная копка - просто хост сам "копает" несколько точек по всему полу дома)
const HOUSE_CENTER = Vector3(0.0, 0.0, -6.0)   # центр пола избы (не у камина - у камина по стене мало места, растапливаем от середины комнаты)
const HOUSE_MELT_OFFSETS_X = [-0.3, 0.3]
const HOUSE_MELT_OFFSETS_Z = [-0.3, 0.3]
const MELT_INTERVAL = 2.0          # как часто камин подтапливает снег, сек
const MELT_TICKS_MAX = 5           # после стольких подтоплений пол в доме уже голая земля - дальше не нужно
var melt_timer = 0.0
var melt_ticks_done = 0

# --- ачивки ---
# Сохраняются ТОЛЬКО на компьютере хоста (это его файл user://, у клиентов
# его не будет - они просто не пишут на диск, см. проверку multiplayer.is_server()
# в _bump_achievement). Разблокировка общая на игру, а не персональная - не
# трекаем, кто именно срубил дерево или кинул снежок, просто "это уже произошло
# в этой партии". Все события и так проходят через этот скрипт одинаково на
# каждом клиенте (call_local RPC), поэтому хосту не нужен отдельный канал,
# чтобы узнать о действии другого игрока.
const ACHIEVEMENTS_SAVE_PATH = "user://achievements.save"
const ACHIEVEMENTS = {
	"first_axe": {"name": "Хозяин топора", "desc": "Подняли топор впервые", "target": 1},
	"first_tree": {"name": "Первая рубка", "desc": "Срубили первое дерево", "target": 1},
	"lumberjack_10": {"name": "Лесоруб", "desc": "Срубили 10 деревьев", "target": 10},
	"first_log": {"name": "Первое бревно", "desc": "Подобрали первое бревно", "target": 1},
	"first_fire": {"name": "Тепло и уютно", "desc": "Разожгли камин впервые", "target": 1},
	"fire_keeper_10": {"name": "Хранитель огня", "desc": "Скормили камину 10 бревен", "target": 10},
	"first_snowball": {"name": "Первый снежок", "desc": "Кинули первый снежок", "target": 1},
	"first_chicken_throw": {"name": "Куриный десант", "desc": "Кинули курицу", "target": 1},
	"chicken_friend_10": {"name": "Друг куриц", "desc": "Подняли на руки 10 куриц", "target": 10},
	"clear_100": {"name": "Расчистка двора", "desc": "Расчистили снег 100 раз", "target": 100},
	"survived_blizzard": {"name": "Пережили метель", "desc": "Дождались конца метели", "target": 1},
}
var achievement_unlocked: Dictionary = {}   # id -> true
var achievement_progress: Dictionary = {}   # id -> текущий счётчик (int/float из JSON)

# --- квесты у Пети: в отличие от ачивок, не сохраняются между запусками (только
# на партию) и прогресс считает каждый компьютер сам, одинаково - deliver_log_to_quest
# и skip_quest мутируют словари прямо в теле RPC, без разделения хост/клиент, точно
# так же, как chop_tree/feed_log_to_fire уже делают с деревьями и камином ---
const QUESTS = {
	"petya_wood": {"name": "Дрова для Пети", "desc": "Принести 3 бревна на красный коврик у Пети", "target": 3},
	"petya_chickens": {"name": "Курицы для Пети", "desc": "Закинуть 3 курицы на красный коврик у Пети", "target": 3},
}
const QUEST_CHICKEN_DROPZONE_RADIUS = 1.0
var quest_progress: Dictionary = {}    # id -> текущий счётчик
var quest_completed: Dictionary = {}   # id -> true
var quest_skipped: Dictionary = {}     # id -> true (пропущен, коврик больше не принимает бревна)

var toast_layer: CanvasLayer
var toast_panel: Panel
var toast_label: Label
var toast_time_left: float = 0.0
const TOAST_DURATION = 3.5

# экран со списком всех ачивок (главное меню и пауза Esc) - открывается функцией
# open_achievements_screen(), закрывается кнопкой "Закрыть" или снаружи (Esc в
# паузе, см. pause_menu_3d.gd); закрытие сообщает об этом сигналом, чтобы вызвавший
# мог вернуть себе управление (например, вернуть мышь в захват и показать паузу назад)
signal achievements_closed
var achievements_layer: CanvasLayer
var achievements_dim: ColorRect
var achievement_rows: Dictionary = {}   # id -> {"style", "status", "name", "desc"}

func _load_achievements():
	if not FileAccess.file_exists(ACHIEVEMENTS_SAVE_PATH):
		return
	var f = FileAccess.open(ACHIEVEMENTS_SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) == TYPE_DICTIONARY:
		achievement_unlocked = data.get("unlocked", {})
		achievement_progress = data.get("progress", {})

func _save_achievements():
	var f = FileAccess.open(ACHIEVEMENTS_SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"unlocked": achievement_unlocked, "progress": achievement_progress}))
	f.close()

# вызывается из мест, где что-то произошло у любого игрока (см. ниже по файлу);
# пишет на диск только хост - у клиентов multiplayer.is_server() == false, и вызов
# просто ничего не делает, а не создаёт файл на их компьютере
func _bump_achievement(id: String, amount: int = 1):
	if not multiplayer.is_server():
		return
	if achievement_unlocked.get(id, false):
		return
	achievement_progress[id] = achievement_progress.get(id, 0) + amount
	if achievement_progress[id] >= ACHIEVEMENTS[id]["target"]:
		achievement_unlocked[id] = true
		announce_achievement.rpc(id)
	_save_achievements()

func _build_achievement_toast():
	toast_layer = CanvasLayer.new()
	toast_layer.layer = 5
	get_parent().add_child.call_deferred(toast_layer)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.02, 0.85)
	style.border_color = Color(0.9, 0.75, 0.3, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	toast_panel = Panel.new()
	toast_panel.add_theme_stylebox_override("panel", style)
	toast_panel.anchor_left = 0.5
	toast_panel.anchor_right = 0.5
	toast_panel.anchor_top = 0.0
	toast_panel.offset_left = -220
	toast_panel.offset_right = 220
	toast_panel.offset_top = 40
	toast_panel.offset_bottom = 110
	toast_panel.visible = false
	toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_layer.add_child(toast_panel)
	toast_label = Label.new()
	toast_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	toast_label.add_theme_font_size_override("font_size", 16)
	toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_panel.add_child(toast_label)

# разблокировка - общая на партию, поэтому показываем её всем игрокам сразу,
# а не только тому, кто её вызвал; вызывает только хост (см. _bump_achievement).
# У клиентов achievement_unlocked иначе никогда бы не обновлялся (сам _bump_achievement
# у них не пишет в этот словарь - выходит раньше, см. проверку multiplayer.is_server()),
# поэтому список ачивок в открытом экране был бы виден только хосту - выставляем
# флаг тут же, чтобы окно "Достижения" совпадало с реальным состоянием у всех
@rpc("authority", "call_local", "reliable")
func announce_achievement(id: String):
	achievement_unlocked[id] = true
	if achievement_rows.has(id) and achievements_dim and achievements_dim.visible:
		_refresh_achievements_screen()
	if not toast_panel or not ACHIEVEMENTS.has(id):
		return
	var info = ACHIEVEMENTS[id]
	_flash_toast("🏆 " + info["name"] + "\n" + info["desc"])

# общий всплывающий тост - используется и для разблокировки ачивок (выше), и для
# завершения квеста Пети (см. deliver_log_to_quest)
func _flash_toast(text: String):
	if not toast_panel:
		return
	toast_label.text = text
	toast_panel.modulate.a = 1.0
	toast_panel.visible = true
	toast_time_left = TOAST_DURATION

func _update_achievement_toast(delta: float):
	if not toast_panel or not toast_panel.visible:
		return
	toast_time_left -= delta
	if toast_time_left <= 0.0:
		toast_panel.visible = false
	elif toast_time_left < 1.0:
		toast_panel.modulate.a = toast_time_left

# --- экран со списком ачивок: строки сверху вниз, стилизованы под ту же
# золотую панель, что и тост при разблокировке (см. _build_achievement_toast) ---
func _build_achievements_screen():
	achievements_layer = CanvasLayer.new()
	achievements_layer.layer = 6
	get_parent().add_child.call_deferred(achievements_layer)

	achievements_dim = ColorRect.new()
	achievements_dim.color = Color(0.0, 0.0, 0.0, 0.6)
	achievements_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	achievements_dim.visible = false
	achievements_layer.add_child(achievements_dim)

	var center = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	achievements_dim.add_child(center)

	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(480, 600)
	center.add_child(scroll)

	var list = VBoxContainer.new()
	list.add_theme_constant_override("separation", 10)
	list.custom_minimum_size = Vector2(460, 0)
	scroll.add_child(list)

	var title = Label.new()
	title.text = "Достижения"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	list.add_child(title)

	for id in ACHIEVEMENTS.keys():
		var row_style = StyleBoxFlat.new()
		row_style.bg_color = Color(0.08, 0.06, 0.02, 0.85)
		row_style.border_color = Color(0.9, 0.75, 0.3, 0.9)
		row_style.set_border_width_all(2)
		row_style.set_corner_radius_all(8)
		row_style.set_content_margin_all(12)
		var row = PanelContainer.new()
		row.add_theme_stylebox_override("panel", row_style)
		list.add_child(row)

		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 12)
		row.add_child(hbox)

		var status_label = Label.new()
		status_label.custom_minimum_size = Vector2(30, 0)
		status_label.add_theme_font_size_override("font_size", 20)
		hbox.add_child(status_label)

		var text_box = VBoxContainer.new()
		text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(text_box)

		var name_label = Label.new()
		name_label.add_theme_font_size_override("font_size", 16)
		text_box.add_child(name_label)

		var desc_label = Label.new()
		desc_label.add_theme_font_size_override("font_size", 12)
		desc_label.modulate = Color(1, 1, 1, 0.65)
		text_box.add_child(desc_label)

		achievement_rows[id] = {"style": row_style, "status": status_label, "name": name_label, "desc": desc_label}

	var close_btn = Button.new()
	close_btn.text = "Закрыть"
	close_btn.pressed.connect(close_achievements_screen)
	list.add_child(close_btn)

func _refresh_achievements_screen():
	for id in ACHIEVEMENTS.keys():
		var row = achievement_rows.get(id)
		if row == null:
			continue
		var unlocked = achievement_unlocked.get(id, false)
		row["status"].text = "✅" if unlocked else "🔒"
		row["name"].text = ACHIEVEMENTS[id]["name"]
		row["desc"].text = ACHIEVEMENTS[id]["desc"]
		row["name"].modulate = Color(1, 1, 1, 1) if unlocked else Color(1, 1, 1, 0.5)
		row["style"].border_color = Color(0.9, 0.75, 0.3, 0.9) if unlocked else Color(0.45, 0.45, 0.45, 0.6)

func open_achievements_screen():
	if not achievements_dim:
		return
	_refresh_achievements_screen()
	achievements_dim.visible = true

func close_achievements_screen():
	if not achievements_dim:
		return
	achievements_dim.visible = false
	achievements_closed.emit()

const FIELD_SIZE = 64.0
const NOISE_SCALE = 12.0
const MIN_THICKNESS = 0.4
var clear_grid = {}   # Vector2i -> 0..1: сколько снега уже расчищено в этой клетке (1 м)

const SoundBank = preload("res://sound_bank.gd")
const STEP_PITCH = 1.0   # тон шагов: меньше = ниже и глуше (1.0 = исходный)
const DIG_VOLUME_DB = -22.0   # громкость взмаха при копке (было +2; меньше = тише)
const STEP_VOLUME_DB = -14.0   # громкость шагов (было -6; меньше = тише)
var step_sounds: Array = []
var dig_sounds: Array = []

var wind_player: AudioStreamPlayer
const WIND_OUTSIDE_DB = -20.0   # громкость ветра на улице в обычную погоду
const WIND_INDOOR_DB = -34.0    # в доме ветер приглушён
const WIND_FADE_SPEED = 12.0    # дБ/сек, скорость перехода

# метель - периодическое событие погоды: решает и запускает таймер только хост,
# сама вспышка (её начало/конец) рассылается всем через RPC, а дальше каждый
# клиент независимо плавно доводит blizzard_intensity до 0 или 1 - это и мягкая
# анимация нарастания/спада, и не требует ежекадровой сети
var blizzard_active: bool = false
var blizzard_intensity: float = 0.0     # 0..1, куда тянется у каждого клиента локально
var blizzard_timer: float = 0.0         # только на хосте: секунд до следующей смены состояния
const BLIZZARD_INTERVAL_MIN = 100.0     # сек затишья между метелями
const BLIZZARD_INTERVAL_MAX = 200.0
const BLIZZARD_DURATION_MIN = 25.0      # сколько длится сама метель
const BLIZZARD_DURATION_MAX = 45.0
const BLIZZARD_FADE_SPEED = 0.35        # скорость нарастания/спада интенсивности, ед/сек
const BLIZZARD_WIND_BOOST_DB = 9.0      # насколько метель добавляет громкости ветру
const BLIZZARD_FOG_DENSITY = 0.05       # плотность тумана-снегопада в полную силу метели

func _ready():
	step_sounds = preload("res://step_clips.gd").make_streams()   # настоящие записи шагов
	for i in range(3):
		dig_sounds.append(SoundBank.make_dig(200 + i))
	for i in range(2):
		snowball_hit_sounds.append(SoundBank.make_snowball_hit(900 + i))
	# фоновый ветер, тихо - у каждого игрока свой, громкость зависит от того,
	# в доме он сейчас или на улице (см. update_wind_indoor, вызывает new_script.gd)
	wind_player = AudioStreamPlayer.new()
	wind_player.stream = SoundBank.make_wind()
	wind_player.volume_db = WIND_OUTSIDE_DB
	wind_player.autoplay = true
	add_child(wind_player)
	# первая метель - через случайный интервал после старта игры; считает только хост
	blizzard_timer = randf_range(BLIZZARD_INTERVAL_MIN, BLIZZARD_INTERVAL_MAX)
	_load_achievements()
	_build_achievement_toast()
	_build_achievements_screen()
	_load_quests()
	# узел "Axe" в main.tscn уже RigidBody3D (с дочерним AxeMesh) - тут только
	# добавляем коллизию по AABB меша; синхронно, не через call_deferred - если
	# отложить на кадр, игрок может успеть схватить ссылку на "Axe" раньше и
	# не увидеть его снова, если бы узел пересоздавался (как было раньше)
	_setup_axe_physics()

# затихание ветра в доме - чисто локальный слуховой эффект для игрока на этом
# компьютере, по сети не передаётся (у соседа своя погода за окном); во время
# метели ветер громче даже в доме - стены приглушают, но не убирают его целиком
func update_wind_indoor(indoor: bool, delta: float):
	var target = (WIND_INDOOR_DB if indoor else WIND_OUTSIDE_DB) + blizzard_intensity * BLIZZARD_WIND_BOOST_DB
	wind_player.volume_db = move_toward(wind_player.volume_db, target, WIND_FADE_SPEED * delta)

func _process(delta):
	if fireplace_lit:
		# чем больше игроков в игре, тем быстрее прогорают дрова - одно бревно на
		# компанию из четверых расходуется в четыре раза быстрее, чем на одного
		var players_count = max(1, get_tree().get_nodes_in_group("players").size())
		fireplace_fuel = max(0.0, fireplace_fuel - delta * players_count)
		if fireplace_fuel <= 0.0:
			fireplace_lit = false
	# растапливание снега в доме запускает только хост - иначе с несколькими игроками
	# в сети это происходило бы в несколько раз быстрее и раздувало бы историю копок
	if fireplace_lit and melt_ticks_done < MELT_TICKS_MAX and multiplayer.is_server():
		melt_timer += delta
		if melt_timer >= MELT_INTERVAL:
			melt_timer = 0.0
			melt_ticks_done += 1
			_melt_house_snow()
	_update_tree_cooldowns(delta)
	_update_snowballs(delta)
	_update_blizzard(delta)
	_update_achievement_toast(delta)
	_update_ground_logs()

# бревно, брошенное физикой (см. _show_log_node), катится и падает само - его
# позиция в logs[...]["pos"] раньше выставлялась только один раз, в момент броска,
# и больше не обновлялась, поэтому пока бревно катилось, its реальное место на
# земле расходилось с тем, что помнил nearest_log_in_range, и подобрать укатившееся
# бревно было нельзя. Подтягиваем позицию из настоящего RigidBody3D каждый кадр,
# пока оно лежит на земле (holder_id == -1)
func _update_ground_logs():
	for tree_path in logs.keys():
		if logs[tree_path]["holder_id"] == -1 and log_nodes.has(tree_path):
			var body = log_nodes[tree_path]
			if is_instance_valid(body) and body.visible:
				logs[tree_path]["pos"] = body.global_position

func _melt_house_snow():
	for dx in HOUSE_MELT_OFFSETS_X:
		for dz in HOUSE_MELT_OFFSETS_Z:
			dig.rpc(HOUSE_CENTER + Vector3(dx, 0.0, dz))

# только хост считает, когда метель начнётся и когда закончится, и рассылает
# это всем через _set_blizzard; сама интенсивность (для тумана/ветра/холода)
# у каждого клиента потом плавно доводится до 0 или 1 самостоятельно - см. ниже
func _update_blizzard(delta: float):
	if multiplayer.is_server():
		blizzard_timer -= delta
		if blizzard_timer <= 0.0:
			if blizzard_active:
				blizzard_timer = randf_range(BLIZZARD_INTERVAL_MIN, BLIZZARD_INTERVAL_MAX)
			else:
				blizzard_timer = randf_range(BLIZZARD_DURATION_MIN, BLIZZARD_DURATION_MAX)
			_set_blizzard.rpc(not blizzard_active)

	var target = 1.0 if blizzard_active else 0.0
	blizzard_intensity = move_toward(blizzard_intensity, target, BLIZZARD_FADE_SPEED * delta)

	var env = _get_environment()
	if env:
		env.fog_enabled = blizzard_intensity > 0.001
		env.fog_light_color = Color(0.86, 0.9, 0.96)
		env.fog_density = BLIZZARD_FOG_DENSITY * blizzard_intensity
		env.fog_sun_scatter = 0.0

func _get_environment() -> Environment:
	var we = get_parent().get_node_or_null("WorldEnvironment")
	return we.environment if we else null

@rpc("authority", "call_local", "reliable")
func _set_blizzard(active: bool):
	if active and not blizzard_active:
		_resnow_yard()
	if not active and blizzard_active:
		_bump_achievement("survived_blizzard")
	blizzard_active = active

# в момент, когда начинается метель, весь расчищенный до этого двор заново
# заносит снегом - пол внутри избы не трогаем (его протопил камин, а не погода)
const HOUSE_CLEAR_MIN = Vector2(-2.3, -8.3)
const HOUSE_CLEAR_MAX = Vector2(2.3, -3.7)

func _resnow_yard():
	for k in clear_grid.keys():
		var wx = float(k.x) + 0.5
		var wz = float(k.y) + 0.5
		if wx > HOUSE_CLEAR_MIN.x and wx < HOUSE_CLEAR_MAX.x and wz > HOUSE_CLEAR_MIN.y and wz < HOUSE_CLEAR_MAX.y:
			continue
		clear_grid.erase(k)
	snow_mask.reset_all()
	# протопленное камином пятно на полу перерисовываем поверх свежего снега сразу же
	for dx in HOUSE_MELT_OFFSETS_X:
		for dz in HOUSE_MELT_OFFSETS_Z:
			snow_mask.request_dig(HOUSE_CENTER + Vector3(dx, 0.0, dz))

func _mark_clear_cpu(pos: Vector3):
	var gx = int(floor(pos.x))
	var gz = int(floor(pos.z))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var k = Vector2i(gx + dx, gz + dz)
			clear_grid[k] = clamp(clear_grid.get(k, 0.0) + 0.4, 0.0, 1.0)

func _hash2(p: Vector2) -> float:
	var v = sin(p.x * 127.1 + p.y * 311.7) * 43758.5453
	return v - floor(v)

func _value_noise(p: Vector2) -> float:
	var i = Vector2(floor(p.x), floor(p.y))
	var f = p - i
	var u = f * f * (Vector2(3.0, 3.0) - f * 2.0)
	var a = lerp(_hash2(i), _hash2(i + Vector2(1, 0)), u.x)
	var b = lerp(_hash2(i + Vector2(0, 1)), _hash2(i + Vector2(1, 1)), u.x)
	return lerp(a, b, u.y)

# 0 = голая земля, 1 = глубокий снег - использует игрок для замедления и потери тепла;
# та же формула шума, что и в шейдере (main.gdshader), плюс то, что уже раскопано
func snow_depth_at(pos: Vector3) -> float:
	var u = (pos.x + FIELD_SIZE / 2.0) / FIELD_SIZE
	var v = (pos.z + FIELD_SIZE / 2.0) / FIELD_SIZE
	var uv = Vector2(u, v)
	var n = _value_noise(uv * NOISE_SCALE) * 0.65 + _value_noise(uv * NOISE_SCALE * 2.3 + Vector2(7.7, 7.7)) * 0.35
	var thickness = lerp(MIN_THICKNESS, 1.0, smoothstep(0.2, 0.8, n))
	var gx = int(floor(pos.x))
	var gz = int(floor(pos.z))
	var cleared = clear_grid.get(Vector2i(gx, gz), 0.0)
	return clamp(thickness - cleared, 0.0, 1.0)

# игрок кладёт бревно в камин рядом с ним - событие уходит всем, каждый одинаково
# прибавляет топливо и зажигает огонь у себя (сходится само, без отдельной синхронизации)
@rpc("any_peer", "call_local", "reliable")
func add_wood_to_fire():
	fireplace_fuel = min(FIRE_MAX_FUEL, fireplace_fuel + FIRE_WOOD_SECONDS)
	fireplace_lit = true
	_bump_achievement("first_fire")
	_bump_achievement("fire_keeper_10")

# рубка дерева: само дерево остаётся на месте и видно всем как обычно, но пока
# не пройдёт TREE_RESPAWN_TIME секунд, рубить его снова нельзя (обратный отсчёт
# игрок видит той же 2D-подсказкой, что и у камина/топора - см. new_script.gd);
# рубить может только тот, у кого в руках топор (проверяется в new_script.gd);
# в дрова не падает мгновенно - на земле появляется одно бревно (log_pos, посчитан
# рубившим игроком), его нужно донести до камина в руках; пока это бревно не
# подобрано и не сожжено, дерево заново не срубить (см. logs.has ниже)
@rpc("any_peer", "call_local", "reliable")
func chop_tree(tree_path: String, _chopper_id: int, log_pos: Vector3):
	var t = get_parent().get_node_or_null(tree_path)
	if t == null or tree_cooldowns.has(tree_path) or logs.has(tree_path):
		return   # уже срублено кем-то другим и ещё не восстановилось, либо бревно ещё лежит
	tree_cooldowns[tree_path] = TREE_RESPAWN_TIME
	logs[tree_path] = {"pos": log_pos, "holder_id": -1}
	_spawn_log_node(tree_path, log_pos)
	_bump_achievement("first_tree")
	_bump_achievement("lumberjack_10")

# считаем время до восстановления каждого срубленного дерева; когда время
# выходит - дерево снова можно рубить
func _update_tree_cooldowns(delta: float):
	if tree_cooldowns.is_empty():
		return
	var ready_paths = []
	for tree_path in tree_cooldowns.keys():
		var remaining = tree_cooldowns[tree_path] - delta
		if remaining <= 0.0:
			ready_paths.append(tree_path)
		else:
			tree_cooldowns[tree_path] = remaining
	for tree_path in ready_paths:
		tree_cooldowns.erase(tree_path)

# кто-то кинул снежок (см. new_script.gd) - у всех появляется своя копия шарика,
# летящая по одной и той же параболе; в реальный сетевой объект не оформляем -
# для шутки с попаданием хватает и локальной симуляции у каждого игрока
@rpc("any_peer", "call_local", "unreliable")
func throw_snowball(start_pos: Vector3, velocity: Vector3, thrower_id: int):
	var ball = MeshInstance3D.new()
	var mesh = SphereMesh.new()
	mesh.radius = 0.06
	mesh.height = 0.12
	ball.mesh = mesh
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.97, 1.0)
	mat.roughness = 0.7
	ball.material_override = mat
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ball)
	ball.global_position = start_pos
	_bump_achievement("first_snowball")
	active_snowballs.append({
		"node": ball,
		"velocity": velocity,
		"life": SNOWBALL_LIFETIME,
		"thrower_id": thrower_id,
	})

# двигаем все летящие снежки и проверяем, не задел ли какой-нибудь СВОЕГО игрока -
# каждый компьютер отвечает только за попадание в себя самого (см. throw_snowball)
func _update_snowballs(delta: float):
	if active_snowballs.is_empty():
		return
	var local_player = null
	for p in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(p) and p.is_inside_tree() and p.is_multiplayer_authority():
			local_player = p
			break
	var i = active_snowballs.size() - 1
	while i >= 0:
		var b = active_snowballs[i]
		var vel: Vector3 = b.velocity
		vel.y -= SNOWBALL_GRAVITY * delta
		b.velocity = vel
		b.node.global_position += vel * delta
		b.life -= delta
		var hit = false
		if local_player and b.thrower_id != multiplayer.get_unique_id():
			var head_pos = local_player.global_position + Vector3(0, 1.5, 0)
			if b.node.global_position.distance_to(head_pos) <= SNOWBALL_HIT_RADIUS:
				hit = true
				local_player._on_snowball_hit()
				_play_at(snowball_hit_sounds, b.node.global_position, -10.0)
		if hit or b.life <= 0.0 or b.node.global_position.y <= -0.5:
			b.node.queue_free()
			active_snowballs.remove_at(i)
		i -= 1

# звук в точке мира: слышат все игроки, чем дальше - тем тише
func _play_at(sounds: Array, pos: Vector3, volume_db: float, pitch: float = 1.0):
	var p = AudioStreamPlayer3D.new()
	p.stream = sounds[randi() % sounds.size()]
	p.volume_db = volume_db
	p.pitch_scale = pitch * randf_range(0.93, 1.07)
	p.unit_size = 5.0
	p.max_distance = 45.0
	p.finished.connect(p.queue_free)
	add_child(p)
	p.global_position = pos
	p.play()

@rpc("any_peer", "call_local", "reliable")
func dig(pos: Vector3):
	snow_mask.request_dig(pos)
	_mark_clear_cpu(pos)
	if multiplayer.is_server():
		dig_history.append(pos)
		_bump_achievement("clear_100")

# звук взмаха в момент нажатия E (слышат все)
@rpc("any_peer", "call_local", "unreliable")
func dig_swish(pos: Vector3):
	_play_at(dig_sounds, pos, DIG_VOLUME_DB)

@rpc("any_peer", "call_local", "reliable")
func print_step(x: float, z: float, rot: float, tint: float):
	snow_trample.add_print(Vector2(x, z), rot, tint)
	_play_at(step_sounds, Vector3(x, 0.1, z), STEP_VOLUME_DB, STEP_PITCH)
	if multiplayer.is_server():
		print_history.append(Vector4(x, z, rot, tint))

@rpc("any_peer", "call_local", "reliable")
func remove_pile(pile_name: String):
	var pile = get_parent().get_node_or_null(pile_name)
	if pile:
		pile.queue_free()
	if multiplayer.is_server() and not removed_piles.has(pile_name):
		removed_piles.append(pile_name)

# игрок взял курицу в руки (ЛКМ рядом с ней) - сама курица (chicken.gd) решает,
# что делать, по-настоящему её к руке двигает только хост; у остальных это просто
# локальный вызов, который всё равно перезапишется сетевым обновлением позиции
@rpc("any_peer", "call_local", "reliable")
func pickup_chicken(chicken_path: String, picker_id: int):
	var c = get_parent().get_node_or_null(chicken_path)
	if c and c.has_method("get_picked_up"):
		c.get_picked_up(picker_id)
		_bump_achievement("chicken_friend_10")

# игрок кинул курицу, которую держал в руках - улетает по параболе (см. chicken.gd);
# сила и направление броска посчитаны на клиенте бросающего игрока
@rpc("any_peer", "call_local", "reliable")
func throw_chicken(chicken_path: String, velocity: Vector3):
	var c = get_parent().get_node_or_null(chicken_path)
	if c and c.has_method("get_thrown"):
		c.get_thrown(velocity)
		_bump_achievement("first_chicken_throw")

# узел "Axe" в main.tscn уже RigidBody3D с дочерним AxeMesh (см. main.tscn) - тут
# только достраивается коллизия по AABB меша и подставляется реальная стартовая
# позиция. Раньше это пересоздавало узел целиком в рантайме через call_deferred,
# но из-за этого игрок иногда успевал схватить ссылку на СТАРЫЙ (уже удалённый)
# узел раньше, чем подменa происходила, и топор становился неподбираемым навсегда
# (is_instance_valid на мёртвой ссылке = false) - теперь узел один и тот же с самого
# начала, просто дополняется синхронно, без гонки
func _setup_axe_physics():
	axe_body = get_parent().get_node_or_null("Axe")
	if not axe_body or not (axe_body is RigidBody3D):
		return
	var mesh_inst = axe_body.get_node_or_null("AxeMesh")
	if not mesh_inst or not mesh_inst.mesh:
		return

	var aabb = mesh_inst.transform * mesh_inst.mesh.get_aabb()
	var col = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = aabb.size
	col.position = aabb.position + aabb.size * 0.5
	col.shape = shape
	axe_body.add_child(col)

	axe_body.visible = not axe_taken
	if not axe_taken:
		axe_body.global_position = axe_ground_pos

# кто-то поднял топор с земли: у всех он прячется на месте, а в руках появляется
# только у того, кто поднял (picker_id == свой id - так же, как дрова при рубке дерева)
@rpc("any_peer", "call_local", "reliable")
func pickup_axe(picker_id: int):
	axe_taken = true
	_bump_achievement("first_axe")
	if axe_body:
		axe_body.visible = false
		axe_body.freeze = true
	if picker_id == multiplayer.get_unique_id():
		var me = get_parent().get_node_or_null("Players/" + str(picker_id))
		if me:
			me._equip_axe()

# кто-то выбросил топор: у всех он падает физикой на землю в указанном месте
# (не телепортом, как раньше), а из рук того, кто бросил, пропадает
@rpc("any_peer", "call_local", "reliable")
func drop_axe(dropper_id: int, pos: Vector3, impulse: Vector3):
	axe_taken = false
	axe_ground_pos = pos
	if axe_body:
		axe_body.global_position = pos
		axe_body.rotation = Vector3.ZERO
		axe_body.linear_velocity = Vector3.ZERO
		axe_body.angular_velocity = Vector3.ZERO
		axe_body.visible = true
		axe_body.freeze = false
		axe_body.apply_central_impulse(impulse)
	if dropper_id == multiplayer.get_unique_id():
		var me = get_parent().get_node_or_null("Players/" + str(dropper_id))
		if me:
			me._unequip_axe()

# кто-то взял факел - со стены или с земли (куда его до этого бросили). Прячется
# у всех, личная светящаяся копия появляется только у поднявшего (см. _equip_torch)
@rpc("any_peer", "call_local", "reliable")
func pickup_torch(picker_id: int):
	if torch_taken and not torch_on_ground:
		return
	torch_taken = true
	torch_on_ground = false
	var torch_node = get_parent().get_node_or_null("Torch")
	if torch_node:
		torch_node.set_mounted(false)
		torch_node.pickup_from_ground()
	if picker_id == multiplayer.get_unique_id():
		var me = get_parent().get_node_or_null("Players/" + str(picker_id))
		if me:
			me._equip_torch()

# бросить факел на землю - настоящей физикой (падает и укладывается сам, см.
# drop_to_ground в torch.gd), а не телепортом обратно на стену
@rpc("any_peer", "call_local", "reliable")
func drop_torch(dropper_id: int, pos: Vector3, impulse: Vector3):
	if not torch_taken:
		return
	torch_on_ground = true
	torch_ground_pos = pos
	var torch_node = get_parent().get_node_or_null("Torch")
	if torch_node:
		torch_node.drop_to_ground(pos, impulse)
	if dropper_id == multiplayer.get_unique_id():
		var me = get_parent().get_node_or_null("Players/" + str(dropper_id))
		if me:
			me._unequip_torch()

# хост отправляет новому игроку всё, что уже произошло - в том числе уже
# разблокированные ачивки (иначе клиент, подключившийся посреди партии, увидел бы
# в экране "Достижения" пустой список до следующей разблокировки, см. announce_achievement)
func send_history(peer_id: int):
	receive_history.rpc_id(peer_id, PackedVector3Array(dig_history), PackedVector4Array(print_history), removed_piles, fireplace_fuel, fireplace_lit, axe_taken, axe_ground_pos, tree_cooldowns.duplicate(), achievement_unlocked.duplicate(), quest_progress.duplicate(), quest_completed.duplicate(), quest_skipped.duplicate(), torch_taken, torch_on_ground, torch_ground_pos)

@rpc("authority", "reliable")
func receive_history(digs: PackedVector3Array, print_list: PackedVector4Array, piles: Array, fuel: float, lit: bool, axe_gone: bool, axe_pos: Vector3, tree_state: Dictionary, unlocked_state: Dictionary, quest_progress_state: Dictionary, quest_completed_state: Dictionary, quest_skipped_state: Dictionary, torch_gone: bool, torch_ground: bool, torch_pos: Vector3):
	for d in digs:
		snow_mask.request_dig(d)
		_mark_clear_cpu(d)
	for p in print_list:
		snow_trample.add_print(Vector2(p.x, p.y), p.z, p.w)
	for pile_name in piles:
		var pile = get_parent().get_node_or_null(str(pile_name))
		if pile:
			pile.queue_free()
	fireplace_fuel = fuel
	fireplace_lit = lit
	axe_taken = axe_gone
	axe_ground_pos = axe_pos
	if axe_body:
		axe_body.freeze = true    # догоняющему новичку топор всегда приходит уже "улёгшимся", без анимации падения
		axe_body.visible = not axe_gone
		if not axe_gone:
			axe_body.global_position = axe_pos
	# деревья, срубленные до нашего подключения и ещё не выросшие обратно
	for tree_path in tree_state.keys():
		tree_cooldowns[tree_path] = tree_state[tree_path]
	for id in unlocked_state.keys():
		achievement_unlocked[id] = true
	if achievements_dim and achievements_dim.visible:
		_refresh_achievements_screen()
	torch_taken = torch_gone
	torch_on_ground = torch_ground
	torch_ground_pos = torch_pos
	var torch_node = get_parent().get_node_or_null("Torch")
	if torch_node:
		torch_node.set_mounted(not torch_gone)
		if torch_ground:
			torch_node.drop_to_ground(torch_pos, Vector3.ZERO)
		else:
			torch_node.pickup_from_ground()
	quest_progress = quest_progress_state.duplicate()
	quest_completed = quest_completed_state.duplicate()
	quest_skipped = quest_skipped_state.duplicate()
