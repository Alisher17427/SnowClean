extends Node3D

# Факел на стене дома: зажигается сам с наступлением ночи (DayNight.is_night) и
# гаснет с рассветом - чтобы в доме было видно даже без горящего камина. Не
# требует клавиши/действия игрока, чисто атмосферный источник света.
#
# Геометрия - готовые модели из fbx_dungeon_asset_pack (держатель + сам факел),
# раньше тут были рукоять/пламя из примитивов, собранные в коде, но выглядели
# как случайный узел из фигур, а не факел (см. историю). Модели ставятся в ряд
# вдоль OUT_DIR (держатель у стены, факел на нём) и масштабируются под HOLDER_HEIGHT/
# TORCH_HEIGHT по их собственному AABB - так не важно, в каких единицах и с каким
# пивотом их на самом деле смоделировали.

const TORCH_SCENE = preload("res://assets/fbx_dungeon_asset_pack/individuals files/torch.fbx")
const HOLDER_SCENE = preload("res://assets/fbx_dungeon_asset_pack/individuals files/torchholder.fbx")

const OUT_DIR = Vector3(1.0, 0.5, 0.0)   # прочь от стены (+X, стена слева) и немного вверх
const HOLDER_HEIGHT = 0.16
const TORCH_HEIGHT = 0.45

var glow: OmniLight3D
var flame: GPUParticles3D
var rig: Node3D          # держатель + модель факела + пламя + свет - всё, что видно на стене
var wall_collision: CollisionShape3D
var ground_body: RigidBody3D   # брошенная на землю копия - падает и катится по-настоящему
var day_night: Node
var flicker_time: float = 0.0
const BASE_ENERGY = 1.3
const BASE_RANGE = 3.5
const FLAME_COLOR = Color(1.0, 0.55, 0.2)

# факел можно снять со стены клавишей G (см. TORCH_PICKUP_RADIUS в new_script.gd) -
# пока он в руках у кого-то, версия на стене просто спрятана (mounted = false);
# сама "в руках" копия - личный визуал у поднявшего игрока, см. _equip_torch.
# Раньше здесь прятались только пламя/свет, а сама модель держателя и факела
# оставалась висеть на стене - с тонким цилиндром из кода это было незаметно,
# с настоящей моделью бросается в глаза, поэтому прячем весь rig целиком и
# заодно снимаем коллизию (иначе на месте снятого факела остаётся невидимая стена)
var mounted: bool = true

func set_mounted(m: bool):
	mounted = m
	rig.visible = m
	if wall_collision:
		wall_collision.disabled = not m
	if not mounted:
		glow.visible = false
		flame.visible = false
		flame.emitting = false

# бросить факел на землю с реальной физикой (падает, кувыркается, укладывается) -
# вместо того чтобы телепортом возвращаться на стену. impulse - лёгкий толчок
# вперёд/вверх в момент броска, чтобы выглядело как бросок, а не как "выключили"
func drop_to_ground(pos: Vector3, impulse: Vector3):
	ground_body.global_position = pos
	ground_body.rotation = Vector3.ZERO
	ground_body.linear_velocity = Vector3.ZERO
	ground_body.angular_velocity = Vector3.ZERO
	ground_body.visible = true
	ground_body.freeze = false
	ground_body.apply_central_impulse(impulse)

# подняли факел с земли, где он до этого лежал/падал
func pickup_from_ground():
	ground_body.visible = false
	ground_body.freeze = true

# пиксельное пламя - мелкие кубики вместо гладкого шара, каждый со своим цветом/
# альфой по градиенту (яркая сердцевина -> оранжевый -> гаснущий тёмно-красный),
# чтобы визуально читалось как "огонь даёт свет", хотя реальный свет по-прежнему
# один общий OmniLight3D рядом - настоящий свет на каждую частицу расплавил бы FPS.
# static, чтобы держатель в руке (см. _equip_torch в new_script.gd) мог позвать
# ту же фабрику без дублирования кода.
#
# trailing=true - для факела в руке: частицы симулируются в мировых координатах
# (local_coords=false), поэтому уже вылетевшие не тащатся вместе с рукой как
# приклеенные - "ветер", сдувающий их назад при ходьбе, накручивается снаружи
# через process_material.gravity в _update_torch_walk_fx (new_script.gd), т.к.
# в этой версии Godot у GPUParticles3D нет inherit_velocity_ratio (для
# неподвижного факела на стене мировые координаты не нужны - он и так не двигается)
static func build_pixel_flame(local_pos: Vector3, trailing: bool = false) -> GPUParticles3D:
	var particles = GPUParticles3D.new()
	particles.amount = 28
	particles.lifetime = 0.5
	particles.local_coords = not trailing
	particles.position = local_pos

	var mesh = BoxMesh.new()
	mesh.size = Vector3.ONE * 0.045
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = FLAME_COLOR
	mat.emission_energy_multiplier = 2.5
	mesh.material = mat
	particles.draw_pass_1 = mesh

	var gradient = Gradient.new()
	gradient.colors = PackedColorArray([
		Color(1.0, 0.95, 0.6, 1.0),
		Color(1.0, 0.55, 0.15, 0.9),
		Color(0.6, 0.15, 0.05, 0.4),
		Color(0.3, 0.05, 0.05, 0.0),
	])
	gradient.offsets = PackedFloat32Array([0.0, 0.35, 0.75, 1.0])
	var ramp_tex = GradientTexture1D.new()
	ramp_tex.gradient = gradient

	var pm = ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 16.0
	pm.initial_velocity_min = 0.25
	pm.initial_velocity_max = 0.45
	pm.gravity = Vector3(0, 0.4, 0)
	pm.scale_min = 0.6
	pm.scale_max = 1.15
	pm.angular_velocity_min = -90.0
	pm.angular_velocity_max = 90.0
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.03
	pm.color_ramp = ramp_tex
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.8
	pm.turbulence_noise_scale = 2.5
	particles.process_material = pm

	return particles

# разовый всплеск искр - используется факелом в руке на каждый шаг игрока (см.
# _update_torch_walk_fx в new_script.gd), чтобы пламя реагировало на ходьбу, а не
# просто ровно горело; emitting выключен по умолчанию - запускается через restart()
static func build_step_sparks(local_pos: Vector3) -> GPUParticles3D:
	var particles = GPUParticles3D.new()
	particles.amount = 6
	particles.lifetime = 0.4
	particles.local_coords = true
	particles.one_shot = true
	particles.explosiveness = 0.9
	particles.position = local_pos

	var mesh = BoxMesh.new()
	mesh.size = Vector3.ONE * 0.03
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = FLAME_COLOR
	mat.emission_energy_multiplier = 3.0
	mesh.material = mat
	particles.draw_pass_1 = mesh

	var gradient = Gradient.new()
	gradient.colors = PackedColorArray([
		Color(1.0, 0.9, 0.5, 1.0),
		Color(1.0, 0.4, 0.1, 0.6),
		Color(0.4, 0.1, 0.05, 0.0),
	])
	gradient.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	var ramp_tex = GradientTexture1D.new()
	ramp_tex.gradient = gradient

	var pm = ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 60.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.0
	pm.gravity = Vector3(0, -0.6, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	pm.color_ramp = ramp_tex
	particles.process_material = pm

	return particles

# AABB модели в её собственном локальном пространстве (до масштабирования/сдвига,
# которые накручиваются поверх) - обходит вложенные MeshInstance3D с учётом их
# локальных трансформов, т.к. импортированные FBX-сцены обычно не плоские
func _combined_aabb(node: Node, xform: Transform3D) -> AABB:
	var result := AABB()
	var has_any := false
	if node is MeshInstance3D and node.mesh:
		result = xform * node.mesh.get_aabb()
		has_any = true
	for child in node.get_children():
		if child is Node3D:
			var child_xform = xform * child.transform
			var child_aabb = _combined_aabb(child, child_xform)
			if has_any:
				result = result.merge(child_aabb)
			else:
				result = child_aabb
				has_any = true
	return result

# ставит инстанс сцены модели в rig так, чтобы её низ (по локальному Y) лежал на
# base_y, масштабируя по высоте под target_height; возвращает Y её верхней точки.
# Модели в паке экспортированы прямо из общей сцены со смещённым от нуля пивотом
# (например, у torch.fbx aabb.position.x около -11), поэтому по X/Z модель ещё и
# центрируется - иначе после масштабирования её относит на много метров в сторону
func _place_model(scene: PackedScene, parent: Node3D, base_y: float, target_height: float) -> float:
	var inst = scene.instantiate()
	parent.add_child(inst)
	var aabb = _combined_aabb(inst, Transform3D.IDENTITY)
	var height = max(aabb.size.y, 0.001)
	var s = target_height / height
	inst.scale = Vector3.ONE * s
	inst.position.x = -(aabb.position.x + aabb.size.x * 0.5) * s
	inst.position.z = -(aabb.position.z + aabb.size.z * 0.5) * s
	inst.position.y = base_y - aabb.position.y * s
	return inst.position.y + (aabb.position.y + aabb.size.y) * s

func _ready():
	day_night = get_tree().current_scene.get_node_or_null("DayNight")

	var dir = OUT_DIR.normalized()

	# поворот, переводящий локальную ось +Y в направление dir - тот же приём, что
	# и для топора в руках (см. _equip_axe в new_script.gd); дальше держатель и
	# факел ставятся вдоль локального +Y этого узла, а он сам развёрнут в dir
	var up = Vector3(0, 1, 0)
	var rot_basis = Basis.IDENTITY
	var axis = up.cross(dir)
	if axis.length() > 0.001:
		rot_basis = Basis(axis.normalized(), up.angle_to(dir))

	rig = Node3D.new()
	rig.transform = Transform3D(rot_basis, Vector3.ZERO)
	add_child(rig)

	var holder_top = _place_model(HOLDER_SCENE, rig, 0.0, HOLDER_HEIGHT)
	var torch_top = _place_model(TORCH_SCENE, rig, holder_top, TORCH_HEIGHT)
	var tip_local = Vector3(0, torch_top, 0)

	flame = build_pixel_flame(tip_local)
	flame.visible = false
	flame.emitting = false
	rig.add_child(flame)

	glow = OmniLight3D.new()
	glow.position = tip_local
	glow.visible = false
	glow.light_color = Color(1, 0.6, 0.25)
	glow.shadow_enabled = true
	glow.omni_range = BASE_RANGE
	rig.add_child(glow)

	# коллизия у самого держателя (не декоративная - только чтобы игрок не мог
	# упереться камерой прямо в пламя, подойдя вплотную к стене)
	var body = StaticBody3D.new()
	body.position = Vector3(0, holder_top * 0.5, 0)
	rig.add_child(body)
	var col = CollisionShape3D.new()
	var shape = CapsuleShape3D.new()
	shape.radius = 0.05
	shape.height = max(holder_top, 0.05)
	col.shape = shape
	body.add_child(col)
	wall_collision = col

	ground_body = _build_ground_body()
	get_tree().current_scene.add_child.call_deferred(ground_body)

# копия факела, которую реально роняют на землю физикой (RigidBody3D), вместо
# телепорта обратно на стену. Своя модель и коллизия, не завязана на rig/wall_collision,
# т.к. живёт отдельно от стены и в произвольной точке уровня, куда её бросили
func _build_ground_body() -> RigidBody3D:
	var body = RigidBody3D.new()
	body.name = "TorchGround"
	body.visible = false
	body.freeze = true
	body.gravity_scale = 1.0

	var model = TORCH_SCENE.instantiate()
	body.add_child(model)
	var aabb = _combined_aabb(model, Transform3D.IDENTITY)
	var s = TORCH_HEIGHT / max(aabb.size.y, 0.001)
	model.scale = Vector3.ONE * s
	model.position.x = -(aabb.position.x + aabb.size.x * 0.5) * s
	model.position.z = -(aabb.position.z + aabb.size.z * 0.5) * s
	model.position.y = -aabb.position.y * s

	var col = CollisionShape3D.new()
	var shape = CapsuleShape3D.new()
	shape.radius = 0.05
	shape.height = TORCH_HEIGHT
	col.position.y = TORCH_HEIGHT * 0.5
	col.shape = shape
	body.add_child(col)
	return body

func _process(delta):
	if not mounted:
		return
	var lit = day_night != null and day_night.is_night
	glow.visible = lit
	flame.visible = lit
	flame.emitting = lit
	if not lit:
		return
	# то же неровное мерцание из нескольких несинхронных синусоид, что и у камина
	# (см. fireplace_visual.gd) - совпадать по фазе им не нужно, каждый факел/камин
	# независим
	flicker_time += delta
	var n = sin(flicker_time * 11.0) * 0.5 + sin(flicker_time * 6.1 + 1.2) * 0.3 + sin(flicker_time * 19.0 + 0.6) * 0.2
	var flicker_mult = 1.0 + n * 0.2
	glow.light_energy = BASE_ENERGY * flicker_mult
	glow.omni_range = BASE_RANGE * (0.97 + 0.03 * flicker_mult)
	# ветер на настенный факел не действует - он всегда висит внутри дома
