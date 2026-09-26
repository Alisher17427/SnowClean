extends Node3D

# Квестовый NPC "Петя": стоит на месте у дома, выглядит как обычный чужой игрок -
# те же руки (модель hands.glb) и ник над головой, только неподвижный и без сети
# (это не CharacterBody3D и не сетевой узел - у него нет authority, он просто стоит
# одинаково у всех игроков). Подойти и нажать G - открывается меню квестов
# (см. quest_menu.gd, открывает new_script.gd рядом с ним).

const HANDS_MODEL_PATHS = ["res://hands.glb", "res://hands.gltf", "res://hands.tscn"]
# те же смещения, что и HANDS_POSITION/ROTATION/SCALE у игрока (new_script.gd),
# только относительно корня NPC, стоящего на земле, а не относительно камеры
const HANDS_POSITION = Vector3(-0.015, 1.44, -0.1)
const HANDS_ROTATION_DEG = Vector3(0.0, 180.0, 0.0)
const HANDS_SCALE = Vector3(0.9, 0.9, 0.9)

func _ready():
	add_to_group("quest_npc")
	_build_nameplate()
	_build_hands()

func _build_nameplate():
	var nameplate = Label3D.new()
	nameplate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	nameplate.font_size = 64
	nameplate.pixel_size = 0.004
	nameplate.outline_size = 14
	nameplate.outline_modulate = Color(0, 0, 0, 1)
	nameplate.modulate = Color(0.95, 0.85, 0.3)   # золотистый - чтобы отличался от ников игроков
	nameplate.position = Vector3(0, 2.0, 0)
	nameplate.text = "Петя"
	add_child(nameplate)

func _build_hands():
	for path in HANDS_MODEL_PATHS:
		if ResourceLoader.exists(path):
			var scene = load(path)
			if scene is PackedScene:
				var model = scene.instantiate()
				model.position = HANDS_POSITION
				model.rotation_degrees = HANDS_ROTATION_DEG
				model.scale = HANDS_SCALE
				add_child(model)
				var anim_player = model.find_child("AnimationPlayer", true, false)
				if anim_player is AnimationPlayer:
					var anim_name = "Idle"
					if not anim_player.has_animation(anim_name):
						var list = anim_player.get_animation_list()
						anim_name = list[0] if list.size() > 0 else ""
					if anim_name != "":
						anim_player.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
						anim_player.play(anim_name)
			return
