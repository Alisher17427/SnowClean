extends Node

# Меню квестов Пети: обычный 2D-список поверх экрана (тем же стилем, что и экран
# "Достижения" в snow_sync.gd), а не 3D-панели, как в меню паузы - для списка
# с прогрессом и кнопками это надёжнее. Открывается клавишей G рядом с Петей
# (см. quest_interact в new_script.gd), закрывается кнопкой "Закрыть" или Esc.

var player   # владелец меню (локальный игрок), даёт доступ к player.snow_sync
var layer: CanvasLayer
var dim: ColorRect
var rows: Dictionary = {}   # id -> {"style", "name", "desc", "skip_btn"}
var is_open = false

func _ready():
	layer = CanvasLayer.new()
	layer.layer = 6
	add_child(layer)

	dim = ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.visible = false
	layer.add_child(dim)

	var center = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)

	var list = VBoxContainer.new()
	list.add_theme_constant_override("separation", 10)
	list.custom_minimum_size = Vector2(420, 0)
	center.add_child(list)

	var title = Label.new()
	title.text = "Петя"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	list.add_child(title)

	for id in player.snow_sync.QUESTS.keys():
		var info = player.snow_sync.QUESTS[id]
		var row_style = StyleBoxFlat.new()
		row_style.bg_color = Color(0.05, 0.09, 0.14, 0.85)
		row_style.border_color = Color(0.4, 0.7, 0.95, 0.9)
		row_style.set_border_width_all(2)
		row_style.set_corner_radius_all(8)
		row_style.set_content_margin_all(12)
		var row = PanelContainer.new()
		row.add_theme_stylebox_override("panel", row_style)
		list.add_child(row)

		var vbox = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 4)
		row.add_child(vbox)

		var name_label = Label.new()
		name_label.add_theme_font_size_override("font_size", 16)
		name_label.text = info["name"]
		vbox.add_child(name_label)

		var desc_label = Label.new()
		desc_label.add_theme_font_size_override("font_size", 12)
		desc_label.modulate = Color(1, 1, 1, 0.7)
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(desc_label)

		var skip_btn = Button.new()
		skip_btn.text = "Пропустить"
		skip_btn.pressed.connect(_on_skip_pressed.bind(id))
		vbox.add_child(skip_btn)

		rows[id] = {"style": row_style, "desc": desc_label, "skip_btn": skip_btn}

	var close_btn = Button.new()
	close_btn.text = "Закрыть"
	close_btn.pressed.connect(close)
	list.add_child(close_btn)

func _refresh():
	for id in rows.keys():
		var info = player.snow_sync.QUESTS[id]
		var row = rows[id]
		var completed = player.snow_sync.quest_completed.get(id, false)
		var skipped = player.snow_sync.quest_skipped.get(id, false)
		if completed:
			row["desc"].text = info["desc"] + "\nВыполнено!"
			row["style"].border_color = Color(0.9, 0.75, 0.3, 0.9)
			row["skip_btn"].visible = false
		elif skipped:
			row["desc"].text = info["desc"] + "\nПропущено"
			row["style"].border_color = Color(0.45, 0.45, 0.45, 0.6)
			row["skip_btn"].visible = false
		else:
			var progress = player.snow_sync.quest_progress.get(id, 0)
			row["desc"].text = "%s\nПрогресс: %d/%d" % [info["desc"], progress, info["target"]]
			row["style"].border_color = Color(0.4, 0.7, 0.95, 0.9)
			row["skip_btn"].visible = true

func _on_skip_pressed(id: String):
	player.snow_sync.skip_quest.rpc(id)
	_refresh()

func open():
	_refresh()
	dim.visible = true
	is_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.input_locked = true

func close():
	if not is_open:
		return
	dim.visible = false
	is_open = false
	player.input_locked = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event):
	if is_open and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
