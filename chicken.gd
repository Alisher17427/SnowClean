extends CharacterBody3D

# Курица: спавнится на улице, идёт в дом греться, а игрок может взять её в руки
# (ЛКМ) и кинуть обратно на улицу (сила броска - зарядка ПКМ, см. new_script.gd) -
# чем больше куриц скопилось в доме, тем быстрее у игроков внутри падает тепло
# (см. CHICKEN_COLD_PENALTY в new_script.gd). Двигает и решает, куда идти, а также
# ведёт в руках/полёте только хост (see is_server() ниже) - у остальных позиция и
# поворот просто приходят по сети через MultiplayerSynchronizer.

const SPEED = 1.1
const WANDER_RADIUS = 2.912
const KICK_COOLDOWN = 10.0    # сколько секунд после броска курица не подходит к дому
const THROW_GRAVITY = 9.8

# та же прямоугольная область дома, что и в new_script.gd (HOUSE_MIN/HOUSE_MAX) -
# держать значения одинаковыми при правке одного из файлов
const HOUSE_MIN = Vector3(-3.0, -1.0, -9.0)
const HOUSE_MAX = Vector3(3.0, 6.0, -3.0)
const HOUSE_DOOR = Vector3(0.0, 0.0, -3.5)   # проём в бревенчатой избе (см. 2026-09-25 - старое каменное здание снесено)

enum State { APPROACH, WANDER, COOLDOWN, HELD, THROWN, SLEEP }
var state: int = State.APPROACH
var target := Vector3.ZERO
var wander_t := 0.0
var cooldown_t := 0.0
var holder_id: int = -1          # чей id держит курицу в руках (только в состоянии HELD)
var throw_velocity := Vector3.ZERO   # скорость полёта (только в состоянии THROWN)
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

func _enter_tree():
	# курицами всегда управляет хост - его версия и является "правдой"
	set_multiplayer_authority(1)

func _ready():
	add_to_group("chicken")
	if multiplayer.is_server():
		target = HOUSE_DOOR + Vector3(randf_range(-0.3, 0.3), 0.0, 0.0)

func _is_indoors(pos: Vector3) -> bool:
	return pos.x > HOUSE_MIN.x and pos.x < HOUSE_MAX.x and pos.z > HOUSE_MIN.z and pos.z < HOUSE_MAX.z

func _random_outside_point() -> Vector3:
	return Vector3(randf_range(-22.0, 22.0), 0.0, randf_range(4.0, 28.0))

func _pick_wander_target():
	wander_t = randf_range(2.5, 5.0)
	target = Vector3(
		clamp(global_position.x + randf_range(-WANDER_RADIUS, WANDER_RADIUS), HOUSE_MIN.x + 1.0, HOUSE_MAX.x - 1.0),
		0.0,
		clamp(global_position.z + randf_range(-WANDER_RADIUS, WANDER_RADIUS), HOUSE_MIN.z + 1.0, HOUSE_MAX.z - 1.0)
	)

func _move_toward_point(dest: Vector3, delta: float):
	var dir = dest - global_position
	dir.y = 0.0
	if dir.length() < 0.05:
		return
	var step = dir.normalized() * SPEED * delta
	if step.length() > dir.length():
		step = dir
	global_position += step
	# модель курицы "смотрит" в свою локальную +Z, а look_at() по умолчанию
	# направляет локальную -Z узла на цель - поэтому меш Model развёрнут на
	# 180 градусов (см. chicken.tscn), и после этого look_at() ставит курицу верно
	look_at(global_position + dir.normalized(), Vector3.UP)

# игрок взял курицу в руки (см. pickup_chicken в snow_sync.gd) - эта функция
# вызывается у всех, но по-настоящему держит (двигает к руке) курицу только хост.
# Коллизию выключаем сразу у всех - иначе, пока хост ведёт курицу к руке игрока,
# её капсула физически толкает и держащего, и всех остальных рядом
func get_picked_up(picker_id: int):
	state = State.HELD
	holder_id = picker_id
	collision_shape.disabled = true

# игрок кинул курицу (см. throw_chicken в snow_sync.gd) - улетает по параболе и,
# приземлившись, какое-то время не подходит к дому (как раньше после "изгнания").
# Коллизия остаётся выключенной, пока летит - включит её обратно _land() при посадке
func get_thrown(velocity: Vector3):
	state = State.THROWN
	holder_id = -1
	throw_velocity = velocity
	collision_shape.disabled = true

# посадка после броска: включаем коллизию у всех разом (по сети), не только у хоста,
# который её на самом деле обнаруживает - иначе у остальных курица навсегда
# осталась бы "проходимой" после первого же броска. Место посадки передаём
# параметром (а не берём из global_position на клиенте) - так же, как dig()/chop_tree()
# передают позицию явно, чтобы засчитать квест "докинуть до коврика" одинаково у всех
@rpc("authority", "call_local", "reliable")
func _land(pos: Vector3):
	state = State.COOLDOWN
	cooldown_t = KICK_COOLDOWN
	collision_shape.disabled = false
	global_position = pos
	var sync = get_tree().current_scene.get_node_or_null("SnowSync")
	if sync:
		sync.register_chicken_landing(pos)

func _physics_process(delta):
	if not multiplayer.is_server():
		return
	# ночью курицы спят - засыпают на месте (в чём бы ни были заняты, кроме "в руках"
	# или "в полёте" - это прямое действие игрока, сон его не прерывает) и просыпаются
	# с рассветом там же, где стояли; день/ночь считает хост по своим часам (day_night.gd)
	var day_night = get_tree().current_scene.get_node_or_null("DayNight")
	var night = day_night != null and day_night.is_night
	if night and state in [State.APPROACH, State.WANDER, State.COOLDOWN]:
		state = State.SLEEP
	elif not night and state == State.SLEEP:
		state = State.WANDER if _is_indoors(global_position) else State.APPROACH
	match state:
		State.SLEEP:
			pass   # стоит на месте, ждёт рассвета
		State.COOLDOWN:
			cooldown_t -= delta
			if cooldown_t <= 0.0:
				state = State.APPROACH
				target = HOUSE_DOOR + Vector3(randf_range(-0.3, 0.3), 0.0, 0.0)
		State.APPROACH:
			_move_toward_point(target, delta)
			if global_position.distance_to(target) < 0.4:
				state = State.WANDER
				_pick_wander_target()
		State.WANDER:
			wander_t -= delta
			_move_toward_point(target, delta)
			if wander_t <= 0.0 or global_position.distance_to(target) < 0.3:
				_pick_wander_target()
		State.HELD:
			var holder = get_tree().current_scene.get_node_or_null("Players/" + str(holder_id))
			if holder and holder.has_method("get_chicken_hold_position"):
				global_position = holder.get_chicken_hold_position()
			else:
				# хозяин отключился/пропал - отпускаем курицу и обязательно
				# включаем коллизию обратно у всех (см. _land), иначе она
				# останется "проходимой" на клиентах, где её взяли в руки
				_land.rpc(global_position)
		State.THROWN:
			throw_velocity.y -= THROW_GRAVITY * delta
			global_position += throw_velocity * delta
			rotation.x += 10.0 * delta   # кувыркается в полёте
			if global_position.y <= 0.0:
				global_position.y = 0.0
				_land.rpc(global_position)
