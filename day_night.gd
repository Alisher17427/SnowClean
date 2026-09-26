extends Node3D

# Смена дня и ночи: солнце и луна - два маленьких диска на одном "небесном" пивоте,
# который крутится по кругу; диски стоят друг напротив друга, поэтому пока один
# диск над горизонтом - второй ровно настолько же под ним, как и должно быть.
# Пивот наклонён на AXIS_TILT_DEG от вертикали, чтобы ни один из дисков никогда не
# проходил точно через зенит - там Basis.looking_at() с up=(0,1,0) вырождается
# (направление взгляда и "верх" совпадают).
#
# DirectionalLight3D не является ребёнком пивота - его поворот, цвет и яркость
# каждый кадр пересчитываются вручную по текущей позиции того диска, что сейчас
# управляет освещением (солнце днём, луна ночью) - так проще, чем возиться с
# относительными базисами двух вложенных друг в друга поворотов.
#
# Синхронизации по сети НЕТ - день/ночь каждый компьютер считает сам, с момента
# запуска сцены. Это только картинка; на геймплей (сон куриц, см. chicken.gd)
# не влияет - курицами управляет только хост, и он решает по своим часам, а
# остальным игрокам итоговая позиция курицы всё равно приходит по сети как обычно.

const DAY_DURATION = 180.0     # секунд - длительность дня
const NIGHT_DURATION = 180.0   # секунд - длительность ночи
const CYCLE_DURATION = DAY_DURATION + NIGHT_DURATION
const SKY_RADIUS = 400.0
const AXIS_TILT_DEG = 18.0

# ниже -DUSK_ELEVATION солнце уже не просто "садится", а гарантированно глубоко под
# горизонтом - только тогда переключаем, чей диск определяет направление света
# (солнца/луны), чтобы переключение произошло уже в полной темноте и было незаметно
const DUSK_ELEVATION = -0.05    # ниже этого - день уже полностью погас (см. daylight)
const DEEP_NIGHT_ELEVATION = -0.2

var elapsed: float = 0.0
var daylight: float = 1.0   # 0 - глухая ночь, 1 - полный день
var is_night: bool = false

var sun_light: DirectionalLight3D
var pivot: Node3D
var sun_disc: MeshInstance3D
var moon_disc: MeshInstance3D

const DAY_COLOR = Color(1.0, 0.97, 0.9)
const DAWN_COLOR = Color(1.0, 0.55, 0.28)
const NIGHT_COLOR = Color(0.45, 0.55, 0.85)
const DAY_ENERGY = 1.2
const DAWN_ENERGY = 0.55
const NIGHT_ENERGY = 0.18

const SKY_TOP_DAY = Color(0.33, 0.5, 0.78)
const SKY_TOP_NIGHT = Color(0.02, 0.03, 0.08)
const SKY_HORIZON_DAY = Color(0.78, 0.85, 0.92)
const SKY_HORIZON_DAWN = Color(0.9, 0.55, 0.35)
const SKY_HORIZON_NIGHT = Color(0.08, 0.08, 0.16)
const GROUND_BOTTOM_DAY = Color(0.65, 0.67, 0.7)
const GROUND_BOTTOM_NIGHT = Color(0.03, 0.03, 0.05)
const GROUND_HORIZON_NIGHT = Color(0.08, 0.08, 0.16)

func _ready():
	sun_light = get_parent().get_node("DirectionalLight3D")

	pivot = Node3D.new()
	pivot.rotation_degrees.z = AXIS_TILT_DEG
	add_child(pivot)

	sun_disc = _build_disc(Color(1.0, 0.95, 0.75), 1.6, true)
	sun_disc.position = Vector3(0, 0, -SKY_RADIUS)
	pivot.add_child(sun_disc)

	moon_disc = _build_disc(Color(0.85, 0.87, 0.95), 1.1, false)
	moon_disc.position = Vector3(0, 0, SKY_RADIUS)
	pivot.add_child(moon_disc)

	# стартуем не в полночь, а чуть после рассвета - чтобы игра начиналась при свете
	elapsed = DAY_DURATION * 0.1

func _build_disc(color: Color, radius: float, glow: bool) -> MeshInstance3D:
	var mi = MeshInstance3D.new()
	var mesh = SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mi.mesh = mesh
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	if glow:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 2.5
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _process(delta):
	elapsed = fmod(elapsed + delta, CYCLE_DURATION)
	# угол считается по кускам (день/ночь отдельно), а не единым оборотом на весь
	# цикл - иначе при не равных DAY_DURATION/NIGHT_DURATION солнце добиралось бы
	# от восхода до заката не за DAY_DURATION секунд, а за произвольное время
	var angle: float
	if elapsed < DAY_DURATION:
		angle = (elapsed / DAY_DURATION) * PI
	else:
		angle = PI + ((elapsed - DAY_DURATION) / NIGHT_DURATION) * PI
	pivot.rotation.x = angle

	var sun_elevation = sun_disc.global_position.y / SKY_RADIUS
	daylight = smoothstep(DUSK_ELEVATION, 0.15, sun_elevation)
	is_night = daylight < 0.02

	# чей диск определяет направление/цвет света - переключаем только глубоко под
	# горизонтом (см. комментарий у DEEP_NIGHT_ELEVATION), поэтому переключение
	# происходит уже в темноте и незаметно на глаз
	var use_moon = sun_elevation < DEEP_NIGHT_ELEVATION
	var active_pos = moon_disc.global_position if use_moon else sun_disc.global_position
	var dir_to_ground = -active_pos.normalized()
	sun_light.global_transform.basis = Basis.looking_at(dir_to_ground, Vector3.UP)

	sun_light.light_color = _tri_lerp(NIGHT_COLOR, DAWN_COLOR, DAY_COLOR, daylight)
	sun_light.light_energy = _tri_lerp_f(NIGHT_ENERGY, DAWN_ENERGY, DAY_ENERGY, daylight)

	var env = _get_environment()
	if env and env.sky and env.sky.sky_material is ProceduralSkyMaterial:
		var sky_mat: ProceduralSkyMaterial = env.sky.sky_material
		sky_mat.sky_top_color = SKY_TOP_NIGHT.lerp(SKY_TOP_DAY, daylight)
		sky_mat.sky_horizon_color = _tri_lerp(SKY_HORIZON_NIGHT, SKY_HORIZON_DAWN, SKY_HORIZON_DAY, daylight)
		sky_mat.ground_bottom_color = GROUND_BOTTOM_NIGHT.lerp(GROUND_BOTTOM_DAY, daylight)
		sky_mat.ground_horizon_color = _tri_lerp(GROUND_HORIZON_NIGHT, SKY_HORIZON_DAWN, SKY_HORIZON_DAY, daylight)

func _get_environment() -> Environment:
	var we = get_parent().get_node_or_null("WorldEnvironment")
	return we.environment if we else null

# трёхточечная интерполяция: 0..0.5 - от a (ночь) к b (рассвет/закат), 0.5..1 - от b
# к c (день) - тёплый рассвет/закат получается ровно в середине перехода, а не
# просто прямая от холодного к тёплому
func _tri_lerp(a: Color, b: Color, c: Color, t: float) -> Color:
	return a.lerp(b, t / 0.5) if t < 0.5 else b.lerp(c, (t - 0.5) / 0.5)

func _tri_lerp_f(a: float, b: float, c: float, t: float) -> float:
	return lerp(a, b, t / 0.5) if t < 0.5 else lerp(b, c, (t - 0.5) / 0.5)
