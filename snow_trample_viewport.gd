extends SubViewport

# Следы-отпечатки ботинок. Каждый компьютер сам определяет шаги СВОЕГО игрока и рассылает их
# всем через SnowSync.print_step; рисуются следы очередью (по одному кадру на отпечаток),
# поэтому их можно повторить для игрока, который зашёл позже (история хранится на хосте).

@export var field_size = 256

const STEP_DIST = 1.2         # расстояние между шагами, м
const SIDE_OFFSET = 0.16      # насколько левый/правый след разнесён от центра, м
const PRINT_TINT_MIN = 0.45   # глубина следа (случайно между min и max)
const PRINT_TINT_MAX = 0.6
const MAX_STEP_HEIGHT = 1.15  # выше этого (прыжок) следов нет
const PRINT_SCALE = 0.35       # размер отпечатка (1.0 = исходный размер текстуры, меньше = мельче след)
const POOL_SIZE = 16
const OFFSCREEN = Vector2(-1000, -1000)

const TRAMPLE_FADE_RATE = 0.07 # линейная убыль в секунду (самый тёмный след тает примерно за 15 сек)
const CLEAR_POOL_SIZE = 4
const CLEAR_SCALE = 0.9   # размер кисти, которая мгновенно стирает следы под лопатой при копке

var boot_texture: ImageTexture
var clear_texture: ImageTexture
var pool: Array = []
var queue: Array = []         # {pos: Vector2 (пиксели), rot: float, tint: float}
var clear_pool: Array = []
var clear_queue: Array = []   # Vector2 (пиксели)
var states = {}               # id игрока -> {last_pos, has_last, side}
var snow_sync: Node
var fade_rect: ColorRect

func _ready():
	boot_texture = _make_boot_texture()
	clear_texture = _make_clear_texture()
	snow_sync = get_parent().get_node("SnowSync")
	for i in range(POOL_SIZE):
		var s = Sprite2D.new()
		s.texture = boot_texture
		s.position = OFFSCREEN
		s.scale = Vector2(PRINT_SCALE, PRINT_SCALE)
		add_child(s)
		pool.append(s)
	for i in range(CLEAR_POOL_SIZE):
		var s = Sprite2D.new()
		s.texture = clear_texture
		s.position = OFFSCREEN
		s.scale = Vector2(CLEAR_SCALE, CLEAR_SCALE)
		add_child(s)
		clear_pool.append(s)
	# каждый кадр "вычитаем" небольшую фиксированную величину из накопленной текстуры
	# следов (режим смешивания SUB) - линейная убыль, а не "в разы", чтобы не упереться
	# в застой из-за 8-битной точности текстуры на малых значениях
	fade_rect = ColorRect.new()
	fade_rect.size = Vector2(size)
	var fade_mat = CanvasItemMaterial.new()
	fade_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_SUB
	fade_rect.material = fade_mat
	add_child(fade_rect)

# вызывается SnowSync у всех игроков, когда кто-то сделал шаг
func add_print(world_xz: Vector2, rot: float, tint: float):
	var u = (world_xz.x + field_size / 2.0) / field_size
	var v = (world_xz.y + field_size / 2.0) / field_size
	queue.append({"pos": Vector2(u * size.x, v * size.y), "rot": rot, "tint": tint})

# вызывается SnowSync, когда кто-то копает (clear_snow) - мгновенно стирает
# накопленные следы под лопатой, чтобы расчистка сразу давала чистую землю
func clear_at(world_pos: Vector3):
	var u = (world_pos.x + field_size / 2.0) / field_size
	var v = (world_pos.z + field_size / 2.0) / field_size
	clear_queue.append(Vector2(u * size.x, v * size.y))

const TEXEL_STEP = 1.0 / 255.0  # одно деление 8-битной текстуры - меньшие изменения GPU округляет в ноль
var _fade_pending := 0.0
func _process(delta):
	# копим "долг" на затухание и применяем его, только когда накопится хотя бы
	# один целый шаг текстуры - иначе на медленной скорости каждый кадр округляется
	# обратно в ноль и текстура вообще не меняется
	_fade_pending += TRAMPLE_FADE_RATE * delta
	if _fade_pending >= TEXEL_STEP:
		var steps = floor(_fade_pending / TEXEL_STEP) * TEXEL_STEP
		fade_rect.color = Color(steps, steps, steps, 1.0)
		_fade_pending -= steps
	else:
		fade_rect.color = Color(0, 0, 0, 0)
	# 1) шаги нашего игрока
	var alive = {}
	for p in get_tree().get_nodes_in_group("players"):
		if not p.is_multiplayer_authority():
			continue
		var id = p.get_instance_id()
		alive[id] = true
		if not states.has(id):
			states[id] = {"last_pos": Vector2.ZERO, "has_last": false, "side": 1.0}
		_step_player(p, states[id])
	for id in states.keys():
		if not alive.has(id):
			states.erase(id)
	# 2) рисуем накопившиеся отпечатки: каждый виден ровно один кадр
	for s in pool:
		if queue.size() > 0:
			var e = queue.pop_front()
			s.position = e["pos"]
			s.rotation = e["rot"]
			s.modulate = Color(e["tint"], e["tint"], e["tint"], 1.0)
		else:
			s.position = OFFSCREEN
	# 3) мгновенное стирание следов под лопатой (см. clear_at)
	for s in clear_pool:
		if clear_queue.size() > 0:
			s.position = clear_queue.pop_front()
		else:
			s.position = OFFSCREEN

func _step_player(p: Node3D, st: Dictionary):
	var pos = Vector2(p.global_position.x, p.global_position.z)
	if not st["has_last"]:
		st["last_pos"] = pos
		st["has_last"] = true
		return
	if p.global_position.y > MAX_STEP_HEIGHT:
		return
	var moved = pos - st["last_pos"]
	if moved.length() < STEP_DIST:
		return
	st["last_pos"] = pos
	st["side"] = -st["side"]
	# нога всегда развёрнута туда, куда смотрит игрок (его тело), а не туда,
	# куда он реально едет - при ходьбе задом след должен смотреть вперёд
	var facing = -p.global_transform.basis.z
	var dir = Vector2(facing.x, facing.z).normalized()
	var right = Vector2(-dir.y, dir.x)
	var print_pos = pos + right * st["side"] * SIDE_OFFSET
	# носок текстуры смотрит вверх (-Y), поворачиваем по направлению взгляда
	var rot = atan2(dir.x, -dir.y) + randf_range(-0.12, 0.12)
	var tint = randf_range(PRINT_TINT_MIN, PRINT_TINT_MAX)
	snow_sync.print_step.rpc(print_pos.x, print_pos.y, rot, tint)

# Процедурный отпечаток ботинка: овал подошвы + отдельный каблук.
func _make_boot_texture() -> ImageTexture:
	var w = 14
	var h = 28
	var img = Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var px = x + 0.5
			var py = y + 0.5
			var sole = pow((px - 7.0) / 5.6, 2.0) + pow((py - 10.0) / 10.0, 2.0)
			var heel = pow((px - 7.0) / 4.3, 2.0) + pow((py - 23.5) / 4.2, 2.0)
			var d = min(sole, heel)
			var a = clamp((1.0 - d) * 3.0, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)

# Мягкая круглая чёрная кисть - стирает след под лопатой одним взмахом (см. clear_at).
func _make_clear_texture() -> ImageTexture:
	var d = 64
	var img = Image.create(d, d, false, Image.FORMAT_RGBA8)
	var c = Vector2(d / 2.0, d / 2.0)
	for y in range(d):
		for x in range(d):
			var dist = Vector2(x + 0.5, y + 0.5).distance_to(c) / (d / 2.0)
			var a = clamp(1.0 - dist, 0.0, 1.0)
			img.set_pixel(x, y, Color(0, 0, 0, a))
	return ImageTexture.create_from_image(img)
