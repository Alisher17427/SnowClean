extends Node3D

# Внешний вид и звук камина: горит или потух, видно и слышно всем игрокам
# одинаково, потому что каждый компьютер сам читает общее состояние из
# SnowSync (fireplace_lit синхронизируется через RPC add_wood_to_fire).
# Треск не рассылается по сети - каждый клиент сам включает/выключает его
# у себя, когда видит, что fireplace_lit поменялся (как и весь внешний вид).

const SoundBank = preload("res://sound_bank.gd")

@onready var hearth: CSGBox3D = $Hearth
@onready var glow: OmniLight3D = $Glow
@onready var chimney: CSGCylinder3D = $Chimney

var mat: StandardMaterial3D
var crackle_player: AudioStreamPlayer3D
var was_lit: bool = false
var flicker_time: float = 0.0
const COLD_COLOR = Color(0.22, 0.2, 0.18)
const LIT_COLOR = Color(0.95, 0.55, 0.15)
const CRACKLE_VOLUME_DB = -12.0
const GLOW_BASE_ENERGY = 2.2      # энергия света в полную силу (см. Glow в main.tscn)
const GLOW_BASE_RANGE = 4.5
const EMISSION_BASE = 1.4

# --- дым из трубы: виден, только пока горит камин (та же переменная fireplace_lit,
# что включает/выключает свет и треск) - густота плавно нарастает/спадает, а не
# щёлкает разом, чтобы не выглядело так, будто дым появляется по команде ---
var smoke: GPUParticles3D
var smoke_material: ParticleProcessMaterial
const SMOKE_MAX_RATIO = 0.55
const SMOKE_FADE_SPEED = 0.35   # ед. amount_ratio в секунду
const SMOKE_BASE_DRIFT = Vector3(0.05, 0.25, 0.03)   # подъём + лёгкий базовый снос без ветра
const SMOKE_WIND_SCALE = 2.0    # насколько сильно настоящий ветер (snow_sync.wind_vector) сносит дым

func _ready():
	mat = StandardMaterial3D.new()
	mat.albedo_color = COLD_COLOR
	hearth.material_override = mat

	crackle_player = AudioStreamPlayer3D.new()
	crackle_player.stream = SoundBank.make_fire_crackle()
	crackle_player.volume_db = CRACKLE_VOLUME_DB
	crackle_player.unit_size = 2.5
	crackle_player.max_distance = 12.0
	crackle_player.position = Vector3(0.0, 0.5, 0.1)
	add_child(crackle_player)

	_build_smoke()

# дым из верхушки трубы - крупные полупрозрачные серые "клубы", поднимаются, слегка
# сносятся ветром в сторону и тают (уменьшается alpha по gradient, растут в размере -
# настоящий дым расширяется, а не остаётся одной и той же точкой)
func _build_smoke():
	smoke = GPUParticles3D.new()
	smoke.position = chimney.position + Vector3(0.0, chimney.height * 0.5 + 0.05, 0.0)
	smoke.amount = 24
	smoke.lifetime = 4.0
	smoke.explosiveness = 0.0
	smoke.randomness = 0.35
	smoke.local_coords = false   # дым остаётся в мировых координатах - труба не двигается, но так честнее
	smoke.amount_ratio = 0.0
	add_child(smoke)

	var pm = ParticleProcessMaterial.new()
	pm.direction = Vector3(0.15, 1.0, 0.1)
	pm.spread = 18.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 0.9
	pm.gravity = SMOKE_BASE_DRIFT   # подъём + снос - переигрывается каждый кадр в _process с учётом реального ветра
	pm.damping_min = 0.05
	pm.damping_max = 0.15
	pm.scale_min = 0.6
	pm.scale_max = 1.1
	# дым разрастается по мере старения - в отличие от пара изо рта, который тает
	# примерно одного размера (см. _build_breath_fog в new_script.gd)
	var scale_curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.4))
	scale_curve.add_point(Vector2(1.0, 2.2))
	var scale_curve_tex = CurveTexture.new()
	scale_curve_tex.curve = scale_curve
	pm.scale_curve = scale_curve_tex

	var gradient = Gradient.new()
	gradient.set_color(0, Color(0.5, 0.5, 0.5, 0.0))
	gradient.add_point(0.2, Color(0.45, 0.45, 0.47, 0.35))
	gradient.add_point(0.7, Color(0.5, 0.5, 0.52, 0.22))
	gradient.set_color(gradient.get_point_count() - 1, Color(0.55, 0.55, 0.57, 0.0))
	var grad_tex = GradientTexture1D.new()
	grad_tex.gradient = gradient
	pm.color_ramp = grad_tex
	smoke.process_material = pm
	smoke_material = pm

	var mesh = QuadMesh.new()
	mesh.size = Vector2(0.5, 0.5)
	var smoke_mat = StandardMaterial3D.new()
	smoke_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	smoke_mat.vertex_color_use_as_albedo = true
	smoke_mat.albedo_color = Color(1, 1, 1, 1)
	mesh.material = smoke_mat
	smoke.draw_pass_1 = mesh
	smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	smoke.emitting = true

func _process(delta):
	var sync = get_parent().get_node_or_null("SnowSync")
	var lit = sync != null and sync.fireplace_lit
	glow.visible = lit
	mat.albedo_color = LIT_COLOR if lit else COLD_COLOR
	mat.emission_enabled = lit
	if lit:
		# мерцание - несколько несинхронных синусоид дают неровное, "живое"
		# колебание вместо ровного мигания одной частотой; плюс огонь тускнеет,
		# когда дрова почти прогорели (fireplace_fuel близко к нулю) - виден
		# "предупреждающий" эффект ещё до того, как камин погаснет совсем
		flicker_time += delta
		var n = sin(flicker_time * 13.0) * 0.5 + sin(flicker_time * 7.3 + 1.7) * 0.3 + sin(flicker_time * 23.0 + 0.4) * 0.2
		var flicker_mult = 1.0 + n * 0.18
		var fuel_ratio = clamp(sync.fireplace_fuel / sync.FIRE_MAX_FUEL, 0.0, 1.0)
		var dim = lerp(0.4, 1.0, smoothstep(0.0, 0.15, fuel_ratio))
		glow.light_energy = GLOW_BASE_ENERGY * dim * flicker_mult
		glow.omni_range = GLOW_BASE_RANGE * (0.96 + 0.04 * flicker_mult)
		mat.emission = LIT_COLOR
		mat.emission_energy_multiplier = EMISSION_BASE * dim * flicker_mult
	if lit != was_lit:
		was_lit = lit
		if lit:
			crackle_player.play()
		else:
			crackle_player.stop()

	var target_ratio = SMOKE_MAX_RATIO if lit else 0.0
	smoke.amount_ratio = move_toward(smoke.amount_ratio, target_ratio, SMOKE_FADE_SPEED * delta)

	# труба всегда снаружи, поэтому настоящий ветер (снос метели/бриз, см.
	# snow_sync.wind_vector) сносит дым точно так же, как пар изо рта и пламя
	# факела в руке (см. _update_breath_fog/_update_torch_walk_fx в new_script.gd)
	if smoke_material and sync != null:
		smoke_material.gravity = SMOKE_BASE_DRIFT + sync.wind_vector() * SMOKE_WIND_SCALE
