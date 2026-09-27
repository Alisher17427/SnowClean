extends Node3D

# Лёгкое покачивание дерева на ветру - чисто декоративное, без физики. Крутим не
# готовый "rotation" (Euler), а домножаем базовый transform на маленький поворот
# в СОБСТВЕННОМ (локальном) пространстве модели - у части деревьев в этой сцене
# (кластер "Forest") сам узел развёрнут необычной трансформацией под рельеф, и если
# крутить через rotation/global-оси, наклон уедет не в ту сторону. Умножение
# base_transform * поворот применяет наклон ДО этой внешней трансформации, поэтому
# дерево качается вокруг своих же локальных осей независимо от того, как оно
# развёрнуто в мире.
#
# Фаза у каждого дерева своя, посчитана из его позиции - иначе весь лес качался бы
# синхронно, как один твёрдый кусок. Амплитуда чуть растёт во время метели
# (snow_sync.blizzard_intensity), как и звук ветра (см. update_wind_indoor в snow_sync.gd)

const BASE_AMPLITUDE_DEG = 1.2
const BLIZZARD_AMPLITUDE_DEG = 3.0
const SWAY_SPEED = 0.6   # базовая частота, рад/сек

var base_transform: Transform3D
var phase: float
var snow_sync: Node

func _ready():
	base_transform = transform
	phase = fmod(global_position.x * 12.9898 + global_position.z * 78.233, TAU)
	snow_sync = get_tree().current_scene.get_node_or_null("SnowSync")

func _process(_delta):
	pass
	#var t = Time.get_ticks_msec() / 1000.0
	#var blizzard = snow_sync.blizzard_intensity if snow_sync else 0.0
	#var amp = deg_to_rad(BASE_AMPLITUDE_DEG + BLIZZARD_AMPLITUDE_DEG * blizzard)
	#var sway_a = sin(t * SWAY_SPEED + phase) * amp
	#var sway_b = sin(t * SWAY_SPEED * 0.7 + phase * 1.7) * amp * 0.6
	#var sway_basis = Basis(Vector3(1, 0, 0), sway_a) * Basis(Vector3(0, 0, 1), sway_b)
	#transform = base_transform * Transform3D(sway_basis, Vector3.ZERO)
