extends Node3D

# Меню паузы: по Esc перед лицом игрока в воздухе появляются текстовые панели.
# Наведите на панель прицелом и нажмите левую кнопку мыши. Меню быстро следует за взглядом.
# Игра при этом идёт дальше (это кооператив), игрок просто не двигается и не копает.

var player                     # владелец меню (локальный игрок)
var is_open = false
var volume = 1.0              # общая громкость 0..1

const DISTANCE = 1.6          # расстояние от глаз до меню, м
const PANEL_H = 0.2
const COLOR_IDLE = Color(0.05, 0.09, 0.14, 0.78)
const COLOR_HOVER = Color(0.2, 0.42, 0.62, 0.9)
const COLOR_INFO = Color(0.05, 0.09, 0.14, 0.55)

var buttons = []              # {node, mat, half: Vector2, action: String, page: int}
var all_panels = []            # {node, page} - вообще все панели, чтобы скрывать/показывать по страницам
var hovered = -1
var volume_label: Label3D
var current_page: int = 0     # 0 = главная страница паузы, 1 = настройки графики, 2 = кастомизация
var customization_labels: Array = []   # Label3D по одному на каждый HAND_COLORS - для _refresh_customization

# экран "Достижения" - не отдельная страница из 3D-панелей (список из 11 ачивок
# туда не влезет удобно), а тот же 2D-список поверх экрана, что и в главном меню
# (см. snow_sync.gd). Пока он открыт - 3D-панели паузы прячем и перехватываем Esc
# сами (см. _unhandled_input), чтобы он закрывал именно список, а не паузу целиком
var showing_achievements = false

# --- настройки графики: применяются к WorldEnvironment и вьюпорту сразу же,
# а также сохраняются в user:// и подхватываются при следующем запуске игры ---
const GFX_CONFIG_PATH = "user://graphics_settings.cfg"
var gfx_brightness: float = 1.0    # tonemap_exposure, 0.6..1.6
var gfx_glow: float = 0.5          # glow_intensity, 0.0..1.2
var gfx_ao: float = 1.0            # ssao_intensity, 0.0..2.0
var gfx_render_scale: float = 1.0  # разрешение рендера, 0.5..1.0
var gfx_aa: int = 1                # индекс в AA_NAMES, по умолчанию FXAA
const GFX_BRIGHTNESS_STEP = 0.1
const GFX_GLOW_STEP = 0.1
const GFX_AO_STEP = 0.2
const GFX_RENDER_STEP = 0.1
const AA_NAMES = ["Выкл", "FXAA", "MSAA 2x", "MSAA 4x"]
var brightness_label: Label3D
var glow_label: Label3D
var ao_label: Label3D
var render_label: Label3D
var aa_label: Label3D

# разрешение окна и лимит FPS - применяются к DisplayServer/Engine напрямую (не
# через Environment/Viewport, как остальные), обзор (FOV) - к камере игрока.
# Разрешение и оконный/полноэкранный режим взаимосвязаны: DisplayServer.window_set_size
# в полноэкранном режиме ничего не меняет, поэтому список разрешений применяется
# только когда режим "Оконный" (см. _apply_resolution/_apply_fullscreen)
const RES_OPTIONS = [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440)]
const RES_NAMES = ["1280x720", "1600x900", "1920x1080", "2560x1440"]
const FPS_OPTIONS = [30, 60, 120, 144, 0]   # 0 = без лимита
const FPS_NAMES = ["30", "60", "120", "144", "Без лимита"]
const FOV_MIN = 60.0
const FOV_MAX = 110.0
const FOV_STEP = 5.0
var gfx_res_idx: int = 2       # по умолчанию 1920x1080
var gfx_fps_idx: int = 1       # по умолчанию 60 - совпадает с run/max_fps в project.godot
var gfx_fov: float = 75.0      # исходный FOV камеры в player.tscn
var gfx_fullscreen: bool = false
var res_label: Label3D
var fps_label: Label3D
var fov_label: Label3D
var fullscreen_label: Label3D

func _ready():
	top_level = true
	visible = false
	_load_gfx_settings()

	# страница 0 - главное меню паузы
	_add_panel("ПАУЗА", Vector2(0, 0.42), Vector2(1.0, 0.16), "", 0.11, 0)
	_add_panel("Продолжить", Vector2(0, 0.17), Vector2(1.0, PANEL_H), "resume", 0.09, 0)
	_add_panel("–", Vector2(-0.4, -0.1), Vector2(0.2, PANEL_H), "vol_down", 0.16, 0)
	volume_label = _add_panel("", Vector2(0, -0.1), Vector2(0.56, PANEL_H), "", 0.09, 0)
	_add_panel("+", Vector2(0.4, -0.1), Vector2(0.2, PANEL_H), "vol_up", 0.16, 0)
	_add_panel("Настройки графики", Vector2(0, -0.37), Vector2(1.0, PANEL_H), "gfx_open", 0.09, 0)
	_add_panel("Достижения", Vector2(0, -0.64), Vector2(1.0, PANEL_H), "achievements_open", 0.09, 0)
	_add_panel("Кастомизация", Vector2(0, -0.91), Vector2(1.0, PANEL_H), "customization_open", 0.09, 0)
	_add_panel("В главное меню", Vector2(0, -1.18), Vector2(1.0, PANEL_H), "to_menu", 0.09, 0)
	_add_panel("Выйти из игры", Vector2(0, -1.45), Vector2(1.0, PANEL_H), "quit", 0.09, 0)
	_update_volume_text()
	player.snow_sync.achievements_closed.connect(_on_achievements_closed)

	# страница 1 - настройки графики (те же строки "минус / значение / плюс", что и громкость)
	_add_panel("НАСТРОЙКИ ГРАФИКИ", Vector2(0, 0.42), Vector2(1.0, 0.16), "", 0.1, 1)
	_add_panel("–", Vector2(-0.4, 0.17), Vector2(0.2, PANEL_H), "brightness_down", 0.16, 1)
	brightness_label = _add_panel("", Vector2(0, 0.17), Vector2(0.56, PANEL_H), "", 0.09, 1)
	_add_panel("+", Vector2(0.4, 0.17), Vector2(0.2, PANEL_H), "brightness_up", 0.16, 1)
	_add_panel("–", Vector2(-0.4, -0.1), Vector2(0.2, PANEL_H), "glow_down", 0.16, 1)
	glow_label = _add_panel("", Vector2(0, -0.1), Vector2(0.56, PANEL_H), "", 0.09, 1)
	_add_panel("+", Vector2(0.4, -0.1), Vector2(0.2, PANEL_H), "glow_up", 0.16, 1)
	_add_panel("–", Vector2(-0.4, -0.37), Vector2(0.2, PANEL_H), "ao_down", 0.16, 1)
	ao_label = _add_panel("", Vector2(0, -0.37), Vector2(0.56, PANEL_H), "", 0.09, 1)
	_add_panel("+", Vector2(0.4, -0.37), Vector2(0.2, PANEL_H), "ao_up", 0.16, 1)
	_add_panel("–", Vector2(-0.4, -0.64), Vector2(0.2, PANEL_H), "render_down", 0.16, 1)
	render_label = _add_panel("", Vector2(0, -0.64), Vector2(0.56, PANEL_H), "", 0.09, 1)
	_add_panel("+", Vector2(0.4, -0.64), Vector2(0.2, PANEL_H), "render_up", 0.16, 1)
	_add_panel("–", Vector2(-0.4, -0.91), Vector2(0.2, PANEL_H), "aa_down", 0.16, 1)
	aa_label = _add_panel("", Vector2(0, -0.91), Vector2(0.56, PANEL_H), "", 0.09, 1)
	_add_panel("+", Vector2(0.4, -0.91), Vector2(0.2, PANEL_H), "aa_up", 0.16, 1)
	_add_panel("Экран", Vector2(0, -1.18), Vector2(1.0, PANEL_H), "screen_open", 0.09, 1)
	_add_panel("Назад", Vector2(0, -1.45), Vector2(1.0, PANEL_H), "gfx_back", 0.09, 1)

	# страница 2 - кастомизация: цвет перчаток, разблокируется квестами у Пети
	# (см. HAND_COLORS в new_script.gd); ряды строятся по этому же списку, а не
	# зашиты вручную, чтобы новый цвет в списке появился в меню сам
	_add_panel("КАСТОМИЗАЦИЯ", Vector2(0, 0.42), Vector2(1.0, 0.16), "", 0.1, 2)
	var hc_y = 0.17
	for i in range(player.HAND_COLORS.size()):
		var lbl = _add_panel("", Vector2(0, hc_y), Vector2(1.0, PANEL_H), "hand_color_%d" % i, 0.09, 2)
		customization_labels.append(lbl)
		hc_y -= 0.27
	_add_panel("Назад", Vector2(0, hc_y), Vector2(1.0, PANEL_H), "customization_back", 0.09, 2)

	# страница 3 - экран: разрешение/FPS/FOV/полноэкранный режим - отдельно от
	# страницы 1, чтобы оба списка оставались короткими. Раньше все 9 строк были
	# на одной странице, и самые нижние (глубже TILT_ROW_RANGE=1.6 м у _update_row_tilt)
	# задирались на максимальный наклон и налезали друг на друга при взгляде вниз -
	# сложнее было прицелиться, а не только некрасиво
	_add_panel("ЭКРАН", Vector2(0, 0.42), Vector2(1.0, 0.16), "", 0.1, 3)
	_add_panel("–", Vector2(-0.4, 0.17), Vector2(0.2, PANEL_H), "res_down", 0.16, 3)
	res_label = _add_panel("", Vector2(0, 0.17), Vector2(0.56, PANEL_H), "", 0.09, 3)
	_add_panel("+", Vector2(0.4, 0.17), Vector2(0.2, PANEL_H), "res_up", 0.16, 3)
	_add_panel("–", Vector2(-0.4, -0.1), Vector2(0.2, PANEL_H), "fps_down", 0.16, 3)
	fps_label = _add_panel("", Vector2(0, -0.1), Vector2(0.56, PANEL_H), "", 0.09, 3)
	_add_panel("+", Vector2(0.4, -0.1), Vector2(0.2, PANEL_H), "fps_up", 0.16, 3)
	_add_panel("–", Vector2(-0.4, -0.37), Vector2(0.2, PANEL_H), "fov_down", 0.16, 3)
	fov_label = _add_panel("", Vector2(0, -0.37), Vector2(0.56, PANEL_H), "", 0.09, 3)
	_add_panel("+", Vector2(0.4, -0.37), Vector2(0.2, PANEL_H), "fov_up", 0.16, 3)
	fullscreen_label = _add_panel("", Vector2(0, -0.64), Vector2(1.0, PANEL_H), "fullscreen_toggle", 0.09, 3)
	_add_panel("Назад", Vector2(0, -0.91), Vector2(1.0, PANEL_H), "screen_back", 0.09, 3)

	# все страницы с настройками построены - применяем сохранённые/дефолтные
	# значения только теперь: до этого момента лейблы страницы 3 (res_label и
	# т.п.) ещё не существовали, и обращение к ним упало бы с ошибкой (был баг -
	# игра вылетала на старте, т.к. _apply_all_gfx_settings() раньше вызывался
	# сразу после страницы 1, до создания этих Label3D)
	_apply_all_gfx_settings()

	_compute_leash()
	_show_page(0)

# поводок = угол до самой дальней кнопки от центра меню (по всем страницам сразу -
# короткие страницы от этого только выигрывают, а длинная всегда помещается).
# Вверх и вниз считаются раздельно - список уходит далеко вниз, но почти не
# выступает вверх за заголовок, поэтому одним общим числом поводок вверх выходил
# неоправданно широким (см. комментарий у leash_pitch_up/down)
func _compute_leash():
	var max_pitch_up = 0.0
	var max_pitch_down = 0.0
	var max_yaw = 0.0
	for b in buttons:
		var half: Vector2 = b["half"]
		var c: Vector3 = b["node"].position
		var top_edge = c.y + half.y
		var bottom_edge = c.y - half.y
		if top_edge > 0.0:
			max_pitch_up = max(max_pitch_up, atan(top_edge / DISTANCE))
		if bottom_edge < 0.0:
			max_pitch_down = max(max_pitch_down, atan(-bottom_edge / DISTANCE))
		max_yaw = max(max_yaw, atan((abs(c.x) + half.x) / DISTANCE))
	leash_pitch_up = max(LEASH_PITCH_MIN, max_pitch_up + LEASH_MARGIN)
	leash_pitch_down = max(LEASH_PITCH_MIN, max_pitch_down + LEASH_MARGIN)
	leash_yaw = max(LEASH_YAW_MIN, max_yaw + LEASH_MARGIN)

func _add_panel(text: String, pos: Vector2, size: Vector2, action: String, label_size: float = 0.09, page: int = 0) -> Label3D:
	var mi = MeshInstance3D.new()
	var quad = QuadMesh.new()
	quad.size = size
	mi.mesh = quad
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true          # видно и сквозь ёлки, и при приближении к стенам
	mat.render_priority = 10
	mat.albedo_color = COLOR_IDLE if action != "" else COLOR_INFO
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(pos.x, pos.y, 0)
	add_child(mi)
	var label = Label3D.new()
	label.text = text
	label.font_size = 64
	label.pixel_size = label_size / 64.0
	label.no_depth_test = true
	label.render_priority = 11
	label.modulate = Color(1, 1, 1, 1)
	label.outline_size = 0
	label.position = Vector3(0, 0, 0.002)
	mi.add_child(label)
	all_panels.append({"node": mi, "page": page})
	if action != "":
		buttons.append({"node": mi, "mat": mat, "half": size / 2.0, "action": action, "page": page})
	return label

# показываем панели только текущей страницы - остальные прячем, чтобы их
# невозможно было случайно навести/нажать, пока они не видны
func _show_page(page: int):
	current_page = page
	hovered = -1
	for p in all_panels:
		p.node.visible = (p.page == page)
	for b in buttons:
		b.mat.albedo_color = COLOR_IDLE

func _unhandled_input(event):
	if not is_instance_valid(player) or not is_inside_tree():
		return
	# меню квестов Пети (G рядом с ним) тоже слушает Esc для закрытия сама (см.
	# quest_menu.gd) - пока оно открыто, пауза не должна встревать поверх него
	if is_instance_valid(player.quest_menu) and player.quest_menu.is_open:
		return
	if showing_achievements:
		# пока открыт список ачивок, Esc закрывает именно его, а не паузу целиком -
		# иначе получилось бы, что Esc одновременно и закрывает список, и снимает
		# паузу, возвращая игроку управление под открытым списком (см. _on_achievements_closed)
		if event.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
			player.snow_sync.close_achievements_screen()
		return
	if event.is_action_pressed("ui_cancel"):
		if is_open:
			_close()
		else:
			_open()
		get_viewport().set_input_as_handled()
	elif is_open and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# сначала помечаем событие обработанным: действие может убрать меню из дерева сцены
		get_viewport().set_input_as_handled()
		if hovered >= 0:
			_do_action(buttons[hovered]["action"])

# Поводок специально широкий (по факту накрывает почти весь список, см. _compute_leash) -
# пока взгляд внутри него, панель вообще не двигается, и можно свободно навестись на
# любую кнопку. Пробовал делать поводок маленьким (почти постоянное слежение за
# взглядом) - получилось хуже: сама попытка посмотреть на нижнюю кнопку сдвигала
# панель в ту же сторону (она задаётся текущим взглядом), кнопка "убегала" вместе со
# взглядом, и дотянуться до неё было невозможно - классическая петля погони. С широким
# статичным поводком такой петли нет: пока вы наводитесь в пределах списка, панель как
# прибитая, кнопка никуда не уезжает. За читаемость нижних строк отвечает не слежение,
# а наклон каждой строки к камере (см. _update_row_tilt) - панель не должна ради этого
# ещё и физически подъезжать. LEASH_*_MIN - нижняя граница на случай короткого меню
const LEASH_YAW_MIN = 0.3       # рад (~17 градусов)
const LEASH_PITCH_MIN = 0.34    # рад (~19 градусов)
const LEASH_MARGIN = 0.05       # запас поверх границ самой дальней кнопки, рад
var leash_yaw = LEASH_YAW_MIN
var leash_pitch_up = LEASH_PITCH_MIN
var leash_pitch_down = LEASH_PITCH_MIN
const MENU_UP = 0.11        # сдвиг меню вверх, чтобы оно было по центру
var menu_yaw = 0.0          # куда меню "хочет" встать (цель, задаётся поводком)
var menu_pitch = 0.0

# Физика "плавания": меню догоняет цель на пружине с небольшим перелётом и покачивается.
const SPRING_K = 110.0      # жёсткость пружины (больше = быстрее догоняет)
# было 7 (при K=80 это сильно недодемпфировано - пружина перелетает цель и
# раскачивается, отсюда и ощущение "меню убегает"); 2*sqrt(110)=21 - без колебаний,
# берём чуть больше для запаса, чтобы догон был плавным, без единого рывка/перелёта
const SPRING_DAMP = 22.0
const SWAY = 0.012          # амплитуда лёгкого покачивания в покое, рад
var cur_yaw = 0.0           # где меню на самом деле сейчас
var cur_pitch = 0.0
var vel_yaw = 0.0
var vel_pitch = 0.0
var sway_time = 0.0

func _gaze_angles() -> Vector2:
	var f = -player.camera.global_transform.basis.z
	return Vector2(atan2(-f.x, -f.z), asin(clamp(f.y, -1.0, 1.0)))

func _place_menu():
	var cam: Camera3D = player.camera
	var yaw = cur_yaw + sin(sway_time * 1.3) * SWAY
	var pitch = cur_pitch + sin(sway_time * 1.9 + 1.0) * SWAY * 0.7
	var dir = Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
	var bs = Basis.looking_at(dir, Vector3.UP)   # лицевая сторона (+Z) обращена к игроку
	global_transform = Transform3D(bs, cam.global_position + dir * DISTANCE + bs * Vector3(0.0, MENU_UP, 0.0))

func _open():
	var g = _gaze_angles()
	menu_yaw = g.x
	menu_pitch = g.y
	cur_yaw = menu_yaw
	cur_pitch = menu_pitch
	vel_yaw = 0.0
	vel_pitch = 0.0
	_place_menu()
	is_open = true
	visible = true
	player.input_locked = true

func _close():
	is_open = false
	visible = false
	hovered = -1
	player.input_locked = false

# список ачивок мог закрыться и не из паузы (например, из главного меню, где этого
# узла ещё вообще нет) - сигнал общий, поэтому реагируем только если открывали сами
func _on_achievements_closed():
	if not showing_achievements:
		return
	showing_achievements = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if is_open:
		visible = true

func _process(delta):
	if not is_open or not is_instance_valid(player) or not is_inside_tree():
		return
	var cam: Camera3D = player.camera
	# меню следует за взглядом, как только тот выходит за пределы маленькой мёртвой
	# зоны (см. комментарий у LEASH_YAW/LEASH_PITCH выше)
	var g = _gaze_angles()
	var dyaw = wrapf(g.x - menu_yaw, -PI, PI)
	if abs(dyaw) > leash_yaw:
		menu_yaw += dyaw - sign(dyaw) * leash_yaw
	# cur_pitch > 0 - взгляд вверх, < 0 - вниз (см. _place_menu) - поэтому dpitch > 0
	# означает "смотрю выше центра меню" (сверяем с leash_pitch_up), а не наоборот
	var dpitch = g.y - menu_pitch
	if dpitch > leash_pitch_up:
		menu_pitch += dpitch - leash_pitch_up
	elif dpitch < -leash_pitch_down:
		menu_pitch += dpitch + leash_pitch_down
	# пружина: ускорение пропорционально расстоянию до цели, минус трение
	var dt = min(delta, 0.05)
	sway_time += dt
	vel_yaw += (SPRING_K * wrapf(menu_yaw - cur_yaw, -PI, PI) - SPRING_DAMP * vel_yaw) * dt
	vel_pitch += (SPRING_K * (menu_pitch - cur_pitch) - SPRING_DAMP * vel_pitch) * dt
	cur_yaw += vel_yaw * dt
	cur_pitch += vel_pitch * dt
	_place_menu()
	_update_row_tilt()
	var inv = global_transform.affine_inverse()
	var o = inv * cam.global_position
	var d = inv.basis * (-cam.global_transform.basis.z)
	var found = -1
	if abs(d.z) > 0.0001:
		var t = -o.z / d.z
		if t > 0.0:
			var hit = o + d * t
			for i in range(buttons.size()):
				var bt = buttons[i]
				if bt["page"] != current_page:
					continue
				var c: Vector3 = bt["node"].position
				if abs(hit.x - c.x) <= bt["half"].x and abs(hit.y - c.y) <= bt["half"].y:
					found = i
					break
	if found != hovered:
		hovered = found
		for i in range(buttons.size()):
			if buttons[i]["page"] != current_page:
				continue
			buttons[i]["mat"].albedo_color = COLOR_HOVER if i == hovered else COLOR_IDLE

# чем ниже смотрит игрок и чем ниже сама строка - тем сильнее она наклоняется
# верхним краем к камере (как открытая книга/подставка), чтобы длинный список
# оставался читаемым, когда тянешься взглядом к нижним кнопкам, а не уезжал плашмя
const TILT_LOOK_DOWN_RANGE = 0.9    # рад - на таком взгляде вниз наклон уже полный
const TILT_MAX_ANGLE = deg_to_rad(32.0)   # наклон самой нижней строки при полном взгляде вниз
const TILT_ROW_RANGE = 1.6          # метров по Y - на такой глубине списка наклон уже полный
func _update_row_tilt():
	# cur_pitch > 0 - взгляд вверх, < 0 - вниз (см. _place_menu); наклон только при взгляде вниз
	var look_down = clamp(-cur_pitch / TILT_LOOK_DOWN_RANGE, 0.0, 1.0)
	for p in all_panels:
		if p["page"] != current_page:
			continue
		var node: MeshInstance3D = p["node"]
		var row_factor = clamp(-node.position.y / TILT_ROW_RANGE, 0.0, 1.0)
		# если наклон окажется в другую сторону (от камеры, а не к ней) - поменять знак на противоположный
		node.rotation.x = -TILT_MAX_ANGLE * look_down * row_factor

func _do_action(action: String):
	match action:
		"resume":
			_close()
		"vol_down":
			volume = clamp(volume - 0.1, 0.0, 1.0)
			_apply_volume()
		"vol_up":
			volume = clamp(volume + 0.1, 0.0, 1.0)
			_apply_volume()
		"to_menu":
			_close()
			multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_tree().call_deferred("reload_current_scene")
		"quit":
			is_open = false   # меню больше ничего не делает, пока игра закрывается
			get_tree().call_deferred("quit")
		"customization_open":
			_show_page(2)
			_refresh_customization()
		"customization_back":
			_show_page(0)
		"gfx_open":
			_show_page(1)
		"gfx_back":
			_show_page(0)
		"screen_open":
			_show_page(3)
		"screen_back":
			_show_page(1)
		"achievements_open":
			# 2D-список (тот же, что в главном меню) поверх спрятанных 3D-панелей паузы;
			# мышь на время списка отпускаем - у самих 3D-панелей паузы её захват не
			# менялся (там наведение через прицел), а тут нужна обычная кликабельная кнопка
			showing_achievements = true
			visible = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			player.snow_sync.open_achievements_screen()
		"brightness_down":
			gfx_brightness = clamp(gfx_brightness - GFX_BRIGHTNESS_STEP, 0.6, 1.6)
			_apply_brightness()
			_save_gfx_settings()
		"brightness_up":
			gfx_brightness = clamp(gfx_brightness + GFX_BRIGHTNESS_STEP, 0.6, 1.6)
			_apply_brightness()
			_save_gfx_settings()
		"glow_down":
			gfx_glow = clamp(gfx_glow - GFX_GLOW_STEP, 0.0, 1.2)
			_apply_glow()
			_save_gfx_settings()
		"glow_up":
			gfx_glow = clamp(gfx_glow + GFX_GLOW_STEP, 0.0, 1.2)
			_apply_glow()
			_save_gfx_settings()
		"ao_down":
			gfx_ao = clamp(gfx_ao - GFX_AO_STEP, 0.0, 2.0)
			_apply_ao()
			_save_gfx_settings()
		"ao_up":
			gfx_ao = clamp(gfx_ao + GFX_AO_STEP, 0.0, 2.0)
			_apply_ao()
			_save_gfx_settings()
		"render_down":
			gfx_render_scale = clamp(gfx_render_scale - GFX_RENDER_STEP, 0.5, 1.0)
			_apply_render_scale()
			_save_gfx_settings()
		"render_up":
			gfx_render_scale = clamp(gfx_render_scale + GFX_RENDER_STEP, 0.5, 1.0)
			_apply_render_scale()
			_save_gfx_settings()
		"aa_down":
			gfx_aa = (gfx_aa - 1 + AA_NAMES.size()) % AA_NAMES.size()
			_apply_aa()
			_save_gfx_settings()
		"aa_up":
			gfx_aa = (gfx_aa + 1) % AA_NAMES.size()
			_apply_aa()
			_save_gfx_settings()
		"res_down":
			gfx_res_idx = (gfx_res_idx - 1 + RES_OPTIONS.size()) % RES_OPTIONS.size()
			_apply_resolution()
			_save_gfx_settings()
		"res_up":
			gfx_res_idx = (gfx_res_idx + 1) % RES_OPTIONS.size()
			_apply_resolution()
			_save_gfx_settings()
		"fps_down":
			gfx_fps_idx = (gfx_fps_idx - 1 + FPS_OPTIONS.size()) % FPS_OPTIONS.size()
			_apply_fps()
			_save_gfx_settings()
		"fps_up":
			gfx_fps_idx = (gfx_fps_idx + 1) % FPS_OPTIONS.size()
			_apply_fps()
			_save_gfx_settings()
		"fov_down":
			gfx_fov = clamp(gfx_fov - FOV_STEP, FOV_MIN, FOV_MAX)
			_apply_fov()
			_save_gfx_settings()
		"fov_up":
			gfx_fov = clamp(gfx_fov + FOV_STEP, FOV_MIN, FOV_MAX)
			_apply_fov()
			_save_gfx_settings()
		"fullscreen_toggle":
			gfx_fullscreen = not gfx_fullscreen
			_apply_fullscreen()
			_apply_resolution()
			_save_gfx_settings()
		_:
			if action.begins_with("hand_color_"):
				_try_select_hand_color(int(action.trim_prefix("hand_color_")))

# выбор цвета перчаток в меню - доступен, только если соответствующий квест
# у Пети уже выполнен (player.snow_sync.quest_completed); "Обычные" (unlock_quest == "")
# доступны всегда
func _try_select_hand_color(idx: int):
	if idx < 0 or idx >= player.HAND_COLORS.size():
		return
	var unlock_id = player.HAND_COLORS[idx].get("unlock_quest", "")
	if unlock_id != "" and not player.snow_sync.quest_completed.get(unlock_id, false):
		return
	player.set_hand_color(idx)
	_refresh_customization()

func _refresh_customization():
	for i in range(customization_labels.size()):
		var opt = player.HAND_COLORS[i]
		var unlock_id = opt.get("unlock_quest", "")
		var unlocked = unlock_id == "" or player.snow_sync.quest_completed.get(unlock_id, false)
		var text = opt["name"]
		if not unlocked:
			text = "🔒 " + text
		elif player.hand_color_id == i:
			text = "✅ " + text
		customization_labels[i].text = text

func _apply_volume():
	AudioServer.set_bus_volume_db(0, linear_to_db(max(volume, 0.0001)))
	AudioServer.set_bus_mute(0, volume <= 0.001)
	_update_volume_text()

func _update_volume_text():
	volume_label.text = "Громкость %d%%" % int(round(volume * 100.0))

# --- настройки графики: WorldEnvironment один на сцену, поэтому берём его прямо
# у главной сцены; вьюпорт - тот, в котором рисуется сам игрок ---
func _get_environment() -> Environment:
	var we = get_tree().current_scene.get_node_or_null("WorldEnvironment")
	return we.environment if we else null

func _apply_brightness():
	var env = _get_environment()
	if env:
		env.tonemap_exposure = gfx_brightness
	brightness_label.text = "Яркость %d%%" % int(round(gfx_brightness * 100.0))

func _apply_glow():
	var env = _get_environment()
	if env:
		env.glow_enabled = gfx_glow > 0.0
		env.glow_intensity = gfx_glow
	glow_label.text = "Свечение %d%%" % int(round(gfx_glow * 100.0))

func _apply_ao():
	var env = _get_environment()
	if env:
		env.ssao_enabled = gfx_ao > 0.0
		env.ssao_intensity = gfx_ao
	ao_label.text = "Затенение %d%%" % int(round(gfx_ao * 100.0))

func _apply_render_scale():
	if is_instance_valid(player):
		player.get_viewport().scaling_3d_scale = gfx_render_scale
	render_label.text = "Качество рендера %d%%" % int(round(gfx_render_scale * 100.0))

# сглаживание - либо аппаратное MSAA (сглаживает края многоугольников), либо
# постобработкой FXAA (дешевле, но немного смазывает картинку целиком), либо
# выключено вовсе; вместе они не имеют смысла - хватит либо одного, либо другого
func _apply_aa():
	if is_instance_valid(player):
		var vp = player.get_viewport()
		match gfx_aa:
			0:
				vp.msaa_3d = Viewport.MSAA_DISABLED
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			1:
				vp.msaa_3d = Viewport.MSAA_DISABLED
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			2:
				vp.msaa_3d = Viewport.MSAA_2X
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			3:
				vp.msaa_3d = Viewport.MSAA_4X
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	aa_label.text = "Сглаживание: " + AA_NAMES[gfx_aa]

# разрешение окна - только в оконном режиме, в полноэкранном сам размер окна не
# имеет смысла (оно на весь экран), поэтому здесь строка работает как "заготовка
# на будущее" - применится, если потом переключиться обратно в оконный режим.
# get_window(), а не DisplayServer.window_set_size() - тот же приём, что и в
# _apply_fullscreen ниже, см. комментарий там
func _apply_resolution():
	if not gfx_fullscreen:
		get_window().size = RES_OPTIONS[gfx_res_idx]
	res_label.text = "Разрешение: " + RES_NAMES[gfx_res_idx]

func _apply_fps():
	Engine.max_fps = FPS_OPTIONS[gfx_fps_idx]
	fps_label.text = "Лимит FPS: " + FPS_NAMES[gfx_fps_idx]

func _apply_fov():
	if is_instance_valid(player) and player.camera:
		player.camera.fov = gfx_fov
	fov_label.text = "Обзор (FOV): %d°" % int(gfx_fov)

# полноэкранный режим - обычный (не exclusive) MODE_FULLSCREEN: он честно отдаёт
# управление композитору окон, поэтому VSync/лимит FPS (см. project.godot) всё
# ещё работают - в отличие от эксклюзивного полноэкранного режима, из-за которого
# раньше видеокарта грелась на 100% без всякого лимита.
#
# get_window().mode, а не DisplayServer.window_set_mode() напрямую - если игра
# запущена из редактора с включённым "Embed game in editor window", у неё нет
# своего окна ОС и DisplayServer.window_set_mode() по window_id молча ничего не
# делает; get_window() всегда возвращает то окно, которому реально принадлежит
# этот узел, поэтому переключение надёжно работает и там, и в собранном .exe
func _apply_fullscreen():
	get_window().mode = Window.MODE_FULLSCREEN if gfx_fullscreen else Window.MODE_WINDOWED
	fullscreen_label.text = "Режим: " + ("Полноэкранный" if gfx_fullscreen else "Оконный")

func _apply_all_gfx_settings():
	_apply_brightness()
	_apply_glow()
	_apply_ao()
	_apply_render_scale()
	_apply_aa()
	_apply_fullscreen()
	_apply_resolution()
	_apply_fps()
	_apply_fov()

func _load_gfx_settings():
	var cfg = ConfigFile.new()
	if cfg.load(GFX_CONFIG_PATH) != OK:
		return
	gfx_brightness = cfg.get_value("graphics", "brightness", gfx_brightness)
	gfx_glow = cfg.get_value("graphics", "glow", gfx_glow)
	gfx_ao = cfg.get_value("graphics", "ao", gfx_ao)
	gfx_render_scale = cfg.get_value("graphics", "render_scale", gfx_render_scale)
	gfx_aa = clamp(cfg.get_value("graphics", "aa", gfx_aa), 0, AA_NAMES.size() - 1)
	gfx_res_idx = clamp(cfg.get_value("graphics", "res_idx", gfx_res_idx), 0, RES_OPTIONS.size() - 1)
	gfx_fps_idx = clamp(cfg.get_value("graphics", "fps_idx", gfx_fps_idx), 0, FPS_OPTIONS.size() - 1)
	gfx_fov = clamp(cfg.get_value("graphics", "fov", gfx_fov), FOV_MIN, FOV_MAX)
	gfx_fullscreen = cfg.get_value("graphics", "fullscreen", gfx_fullscreen)

func _save_gfx_settings():
	var cfg = ConfigFile.new()
	cfg.set_value("graphics", "brightness", gfx_brightness)
	cfg.set_value("graphics", "glow", gfx_glow)
	cfg.set_value("graphics", "ao", gfx_ao)
	cfg.set_value("graphics", "render_scale", gfx_render_scale)
	cfg.set_value("graphics", "aa", gfx_aa)
	cfg.set_value("graphics", "res_idx", gfx_res_idx)
	cfg.set_value("graphics", "fps_idx", gfx_fps_idx)
	cfg.set_value("graphics", "fov", gfx_fov)
	cfg.set_value("graphics", "fullscreen", gfx_fullscreen)
	cfg.save(GFX_CONFIG_PATH)
