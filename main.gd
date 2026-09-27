extends Node3D

# Главная сцена: меню (создать игру / подключиться) и появление игроков по сети.

const PORT = 9999
const MAX_PLAYERS = 8
const AUTOTEST = false   # отладка: сам создаёт игру, копает, ходит и печатает результат (потом выключить)
const PLAYER_SCENE = "res://player.tscn"

# куры: спавнятся на улице по таймеру, только пока их в доме+на улице меньше CHICKEN_MAX;
# спавнит и двигает их только хост (см. chicken.gd), остальным позиция приходит по сети
const CHICKEN_SCENE = "res://chicken.tscn"
const CHICKEN_MAX = 5
const CHICKEN_SPAWN_INTERVAL = 12.0   # сек между попытками заспавнить новую курицу
var chicken_spawn_timer = 0.0
var chicken_id_counter = 0

@onready var players: Node3D = $Players
@onready var spawner: MultiplayerSpawner = $PlayerSpawner
@onready var chickens: Node3D = $Chickens
@onready var chicken_spawner: MultiplayerSpawner = $ChickenSpawner
@onready var snow_sync: Node = $SnowSync

# деревья из ранее добавленного декоративного леса, которые можно рубить на дрова
# (остальной лес остаётся просто фоном); эти конкретные экземпляры на самом деле
# висели в воздухе на ~2-3 м из-за старой расстановки - опускаем их на землю здесь же
const CHOP_TREES = ["ForestGroup/Forest2", "ForestGroup/Forest6", "ForestGroup/Forest7", "ForestGroup/Tree_2Snow", "ForestGroup/Forest5"]

var menu_layer: CanvasLayer
var mode_box: VBoxContainer         # первый экран: одиночная игра / мультиплеер
var multiplayer_box: VBoxContainer  # форма хоста/подключения, скрыта, пока не выбран мультиплеер
var ip_edit: LineEdit
var nick_edit: LineEdit
var local_nickname = "Игрок"   # ник этого игрока, его читает скрипт персонажа
var status_label: Label
var is_singleplayer: bool = false   # true = сервер держим закрытым, чужих коннектов сразу выгоняем

func _ready():
	spawner.add_spawnable_scene(PLAYER_SCENE)
	chicken_spawner.add_spawnable_scene(CHICKEN_SCENE)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	$UI.visible = false   # прицел показываем только в игре
	_setup_chop_trees()
	_build_camera_and_menu()
	if AUTOTEST:
		_autotest()

func _setup_chop_trees():
	for path in CHOP_TREES:
		var t = get_node_or_null(path)
		if t == null:
			continue
		t.global_position.y = 0.0
		var col = t.get_node_or_null("Collision")
		if col:
			col.add_to_group("tree")

func _build_camera_and_menu():
	# камера для экрана меню: смотрит на дом сверху
	var cam = Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 7, 14)
	cam.look_at(Vector3(0, 1.5, 0))
	cam.current = true

	menu_layer = CanvasLayer.new()
	add_child(menu_layer)
	var center = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_layer.add_child(center)
	var box = VBoxContainer.new()
	box.custom_minimum_size = Vector2(360, 0)
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	var title = Label.new()
	title.text = "Очистить двор от снега"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)

	nick_edit = LineEdit.new()
	nick_edit.placeholder_text = "Ваш ник"
	nick_edit.text = "Игрок"
	nick_edit.max_length = 16
	box.add_child(nick_edit)

	# --- экран выбора режима: одиночная игра стартует сразу, мультиплеер
	# открывает форму хоста/подключения (см. _show_multiplayer_options) ---
	mode_box = VBoxContainer.new()
	mode_box.add_theme_constant_override("separation", 10)
	box.add_child(mode_box)

	var solo_btn = Button.new()
	solo_btn.text = "Одиночная игра"
	solo_btn.pressed.connect(_on_solo_pressed)
	mode_box.add_child(solo_btn)

	var mp_btn = Button.new()
	mp_btn.text = "Мультиплеер"
	mp_btn.pressed.connect(_show_multiplayer_options)
	mode_box.add_child(mp_btn)

	var achievements_btn = Button.new()
	achievements_btn.text = "Достижения"
	achievements_btn.pressed.connect(snow_sync.open_achievements_screen)
	mode_box.add_child(achievements_btn)

	renderer_btn = Button.new()
	renderer_btn.text = "Рендерер: " + RENDERER_NAMES.get(_current_renderer(), "?")
	renderer_btn.pressed.connect(_toggle_renderer_popup)
	mode_box.add_child(renderer_btn)
	_build_renderer_popup()

	multiplayer_box = VBoxContainer.new()
	multiplayer_box.add_theme_constant_override("separation", 10)
	multiplayer_box.visible = false
	box.add_child(multiplayer_box)

	var host_btn = Button.new()
	host_btn.text = "Создать игру (хост)"
	host_btn.pressed.connect(_on_host_pressed)
	multiplayer_box.add_child(host_btn)

	var my_ips = Label.new()
	my_ips.text = "Ваш адрес в сети: " + ", ".join(_local_ips())
	my_ips.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	multiplayer_box.add_child(my_ips)

	ip_edit = LineEdit.new()
	ip_edit.text = "127.0.0.1"
	ip_edit.placeholder_text = "IP-адрес хоста"
	multiplayer_box.add_child(ip_edit)

	var join_btn = Button.new()
	join_btn.text = "Подключиться"
	join_btn.pressed.connect(_on_join_pressed)
	multiplayer_box.add_child(join_btn)

	var back_btn = Button.new()
	back_btn.text = "Назад"
	back_btn.pressed.connect(_hide_multiplayer_options)
	multiplayer_box.add_child(back_btn)

	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(status_label)

# --- выбор рендерера: Godot выбирает видеодрайвер один раз при старте процесса
# и не может сменить его на лету, поэтому "переключение" - это перезапуск того же
# .exe с другим параметром командной строки (--rendering-driver / --rendering-method) ---
const RENDERER_NAMES = {"vulkan": "Vulkan", "d3d12": "DirectX 12", "compatibility": "Compatibility"}
const RENDERER_CFG_PATH = "user://renderer_choice.cfg"
var renderer_btn: Button
var renderer_popup: PopupPanel

# Godot "съедает" --rendering-driver/--rendering-method до того, как скрипт
# успевает их увидеть через OS.get_cmdline_args() - поэтому свой выбор просто
# запоминаем сами в файле, а не пытаемся угадать его из параметров запуска
func _current_renderer() -> String:
	var cfg = ConfigFile.new()
	if cfg.load(RENDERER_CFG_PATH) == OK:
		return cfg.get_value("renderer", "choice", "vulkan")
	return "vulkan"   # значение по умолчанию из project.godot, пока не выбрано иное

func _save_renderer_choice(choice: String):
	var cfg = ConfigFile.new()
	cfg.set_value("renderer", "choice", choice)
	cfg.save(RENDERER_CFG_PATH)

func _build_renderer_popup():
	renderer_popup = PopupPanel.new()
	add_child(renderer_popup)
	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	renderer_popup.add_child(box)
	for key in ["vulkan", "d3d12", "compatibility"]:
		var b = Button.new()
		b.text = RENDERER_NAMES[key]
		b.pressed.connect(_select_renderer.bind(key))
		box.add_child(b)
	var hint = Label.new()
	hint.text = "При смене игра перезапустится"
	hint.add_theme_font_size_override("font_size", 12)
	box.add_child(hint)

func _toggle_renderer_popup():
	renderer_popup.popup_centered()

func _select_renderer(choice: String):
	renderer_popup.hide()
	if choice == _current_renderer():
		return   # уже активен, перезапуск не нужен
	_save_renderer_choice(choice)
	var args = []
	if choice == "compatibility":
		args = ["--rendering-method", "gl_compatibility", "--rendering-driver", "opengl3"]
	else:
		args = ["--rendering-driver", choice]
	OS.create_process(OS.get_executable_path(), args)
	get_tree().quit()

func _show_multiplayer_options():
	mode_box.visible = false
	multiplayer_box.visible = true
	status_label.text = ""

func _hide_multiplayer_options():
	multiplayer_box.visible = false
	mode_box.visible = true
	status_label.text = ""

func _local_ips() -> Array:
	var result = []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and (a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172.")):
			result.append(a)
	if result.is_empty():
		result.append("не найден")
	return result

func _read_nickname():
	var n = nick_edit.text.strip_edges()
	if n == "":
		n = "Игрок"
	local_nickname = n

func _on_solo_pressed():
	# одиночная игра технически тоже локальный хост (иначе не заработают RPC,
	# на которых держится вся геймплейная логика - копка, камин, куры и т.д.).
	# ENet требует max_clients не меньше 1, поэтому полностью закрыть порт
	# нельзя - вместо этого чужой коннект сразу отклоняется в _on_peer_connected
	is_singleplayer = true
	_read_nickname()
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(PORT, 1)
	if err != OK:
		status_label.text = "Не удалось начать одиночную игру"
		return
	multiplayer.multiplayer_peer = peer
	_start_game()
	_spawn_player(1)

func _on_host_pressed():
	is_singleplayer = false
	_read_nickname()
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		status_label.text = "Не удалось создать игру (порт %d занят?)" % PORT
		return
	multiplayer.multiplayer_peer = peer
	_start_game()
	_spawn_player(1)

func _on_join_pressed():
	_read_nickname()
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(ip_edit.text.strip_edges(), PORT)
	if err != OK:
		status_label.text = "Не удалось начать подключение"
		return
	multiplayer.multiplayer_peer = peer
	status_label.text = "Подключение..."

func _start_game():
	menu_layer.hide()
	$UI.visible = true

func _spawn_player(id: int):
	var p = load(PLAYER_SCENE).instantiate()
	p.name = str(id)
	players.add_child(p, true)

# спавнить куриц может только хост - иначе они появлялись бы у каждого игрока отдельно
func _process(delta):
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	if chickens.get_child_count() >= CHICKEN_MAX:
		return
	chicken_spawn_timer += delta
	if chicken_spawn_timer >= CHICKEN_SPAWN_INTERVAL:
		chicken_spawn_timer = 0.0
		_spawn_chicken()

func _spawn_chicken():
	chicken_id_counter += 1
	var c = load(CHICKEN_SCENE).instantiate()
	c.name = "Chicken" + str(chicken_id_counter)
	c.position = Vector3(randf_range(-22.0, 22.0), 0.0, randf_range(4.0, 28.0))
	chickens.add_child(c, true)

# --- события сети ---
func _on_peer_connected(id: int):
	if not multiplayer.is_server():
		return
	if is_singleplayer:
		# одиночная игра - чужой коннект сразу выгоняем, игрока не спавним
		multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	_spawn_player(id)
	snow_sync.send_history(id)

func _on_peer_disconnected(id: int):
	if multiplayer.is_server():
		var p = players.get_node_or_null(str(id))
		if p:
			p.queue_free()

func _on_connected_to_server():
	_start_game()

func _on_connection_failed():
	multiplayer.multiplayer_peer = null
	status_label.text = "Не удалось подключиться. Проверьте адрес и что хост запущен."

func _on_server_disconnected():
	multiplayer.multiplayer_peer = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()

# --- отладочная самопроверка (AUTOTEST) ---
func _autotest():
	await get_tree().create_timer(0.5).timeout
	nick_edit.text = "Тест"
	_on_host_pressed()
	await get_tree().create_timer(1.0).timeout
	var me = players.get_node_or_null("1")
	print("AUTOTEST игроков: ", players.get_child_count(), " локальный: ", me != null, " ник: ", me.nickname if me else "-")
	if me == null:
		pass
		return
	me.head.rotation.x = -1.0   # смотрим вниз, чтобы луч попадал в землю
	Input.action_press("clear_snow")
	await get_tree().create_timer(0.4).timeout
	Input.action_release("clear_snow")
	print("AUTOTEST копка: digging=", me.digging, " dig_stamped=", me.dig_stamped, " pitch=", me.head.rotation.x)
	me._try_dig_hit()
	await get_tree().create_timer(1.0).timeout
	me.global_position += Vector3(2.0, 0, 0)
	await get_tree().create_timer(0.3).timeout
	me.global_position += Vector3(2.0, 0, 0)
	await get_tree().create_timer(0.5).timeout
	print("AUTOTEST копок: ", snow_sync.dig_history.size(), " следов: ", snow_sync.print_history.size(), " куч убрано: ", snow_sync.removed_piles.size())
	pass
