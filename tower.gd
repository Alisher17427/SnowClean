extends Node3D

# Вышка: пока исправна, помогает сдерживать метель (см. _update_blizzard в
# snow_sync.gd - доля сломанных вышек ограничивает силу и частоту метели).
# Сама ломается по случайному таймеру (TOWER_BREAK_MIN/MAX в snow_sync.gd),
# почитить: подойти и зажать [R] на TOWER_REPAIR_TIME секунд (new_script.gd).
# Состояние показывает маленький огонёк на вышке: зелёный - исправна, красный - сломана.

var status_light: OmniLight3D
var break_sound: AudioStreamPlayer3D

func _enter_tree():
	if has_node("Collision"):
		$Collision.add_to_group("tower")

func _ready():
	status_light = OmniLight3D.new()
	status_light.light_color = Color(0.2, 1.0, 0.3)
	status_light.light_energy = 3.0
	status_light.omni_range = 60.0
	status_light.position = Vector3(0, 150, 0)
	add_child(status_light)
	
	break_sound = AudioStreamPlayer3D.new()
	break_sound.stream = preload("res://sounds/tower_break.mp3")
	add_child(break_sound)

func set_broken(broken: bool):
	if broken:
		break_sound.play()
	status_light.light_color = Color(1.0, 0.15, 0.1) if broken else Color(0.2, 1.0, 0.3)
