extends Node

# Голосовой чат с Петей: зажимаешь V рядом с ним - идёт запись с микрофона,
# отпускаешь - аудио уходит на локальный AI-сервер (второй компьютер в сети,
# см. petya_server/petya_server.py в корне проекта), который распознаёт речь
# (Whisper), генерирует ответ Пети (Ollama, локальная LLM) и озвучивает его
# (Piper TTS) - обратно приходит уже готовый звук + текст для субтитров.
#
# Сам ИИ живёт целиком на сервере - эта игра только записывает голос, шлёт его,
# получает ответ и проигрывает. Личный, локальный визуал/звук у каждого игрока -
# по сети (другим игрокам) сейчас НЕ транслируется, как и температура/голод.
#
# Адрес сервера хранится в user://petya_ai_server.cfg - этот файл не в git
# (в отличие от кода игры, у каждого свой сервер/IP). Если файла ещё нет,
# создаётся с адресом по умолчанию 127.0.0.1:8765 - следует поменять на
# реальный IP компьютера, где запущен petya_server.py.

const CONFIG_PATH = "user://petya_ai_server.cfg"
const TALK_RADIUS = 2.4          # то же расстояние, что и QUEST_INTERACT_RADIUS у меню квестов
const RECORD_BUS = "PetyaMic"
const MAX_RECORD_SECONDS = 12.0  # защита от того, что игрок забудет отпустить V
const MIN_RECORDING_BYTES = 4000 # совсем короткая запись (шум/случайное нажатие) не отправляется
const SUBTITLE_DURATION = 6.0

var player: Node          # владелец - локальный игрок, см. new_script.gd _ready()
var petya_node: Node3D

var http: HTTPRequest
var record_effect: AudioEffectRecord
var mic_player: AudioStreamPlayer
var reply_player: AudioStreamPlayer3D

var subtitle_panel: Panel
var subtitle_label: Label
var subtitle_timer: float = 0.0

var is_recording: bool = false
var record_start_time: float = 0.0
var waiting_for_reply: bool = false

var server_host: String = "127.0.0.1"
var server_port: int = 8765

func setup(p: Node, petya: Node3D):
	player = p
	petya_node = petya
	_load_config()
	_build_mic_bus()
	_build_http()
	_build_reply_player()
	_build_subtitles()

func _load_config():
	var cfg = ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		cfg.set_value("server", "host", server_host)
		cfg.set_value("server", "port", server_port)
		cfg.save(CONFIG_PATH)
		return
	server_host = cfg.get_value("server", "host", server_host)
	server_port = cfg.get_value("server", "port", server_port)

# отдельная звуковая шина только для записи с микрофона - замьючена (сам эффект
# записи всё равно продолжает получать сигнал), поэтому свой же голос не слышно
# из колонок, пока говоришь
func _build_mic_bus():
	var idx = AudioServer.get_bus_index(RECORD_BUS)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, RECORD_BUS)
		AudioServer.set_bus_mute(idx, true)
		record_effect = AudioEffectRecord.new()
		AudioServer.add_bus_effect(idx, record_effect)
	else:
		record_effect = AudioServer.get_bus_effect(idx, 0)

	mic_player = AudioStreamPlayer.new()
	mic_player.stream = AudioStreamMicrophone.new()
	mic_player.bus = RECORD_BUS
	add_child(mic_player)
	mic_player.play()

func _build_http():
	http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_request_completed)

func _build_reply_player():
	reply_player = AudioStreamPlayer3D.new()
	reply_player.unit_size = 6.0
	get_tree().current_scene.add_child.call_deferred(reply_player)

func _build_subtitles():
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.05, 0.75)
	style.border_color = Color(1.0, 1.0, 1.0, 0.3)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	subtitle_panel = Panel.new()
	subtitle_panel.add_theme_stylebox_override("panel", style)
	subtitle_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	subtitle_panel.anchor_left = 0.5
	subtitle_panel.anchor_right = 0.5
	subtitle_panel.anchor_top = 1.0
	subtitle_panel.anchor_bottom = 1.0
	subtitle_panel.offset_left = -300
	subtitle_panel.offset_right = 300
	subtitle_panel.offset_top = -150
	subtitle_panel.offset_bottom = -60
	subtitle_panel.visible = false
	player.hud.add_child(subtitle_panel)
	subtitle_label = Label.new()
	subtitle_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	subtitle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	subtitle_label.add_theme_font_size_override("font_size", 16)
	subtitle_label.add_theme_color_override("font_outline_color", Color.BLACK)
	subtitle_label.add_theme_constant_override("outline_size", 3)
	subtitle_panel.add_child(subtitle_label)

func _show_subtitle(text: String):
	subtitle_label.text = text
	subtitle_panel.visible = true
	subtitle_timer = SUBTITLE_DURATION

func _process(delta):
	if not is_instance_valid(player) or not is_instance_valid(petya_node):
		return

	if subtitle_timer > 0.0:
		subtitle_timer -= delta
		if subtitle_timer <= 0.0:
			subtitle_panel.visible = false

	if player.input_locked:
		return
	var near = player.global_position.distance_to(petya_node.global_position) <= TALK_RADIUS

	if Input.is_action_just_pressed("talk_petya") and near and not waiting_for_reply:
		_start_recording()
	if Input.is_action_just_released("talk_petya") and is_recording:
		_stop_recording_and_send()
	if is_recording and (Time.get_ticks_msec() / 1000.0 - record_start_time) > MAX_RECORD_SECONDS:
		_stop_recording_and_send()

func _start_recording():
	is_recording = true
	record_start_time = Time.get_ticks_msec() / 1000.0
	record_effect.set_recording_active(true)
	_show_subtitle("Слушаю...")

func _stop_recording_and_send():
	is_recording = false
	record_effect.set_recording_active(false)
	var recording: AudioStreamWAV = record_effect.get_recording()
	if recording == null or recording.data.size() < MIN_RECORDING_BYTES:
		_show_subtitle("Не расслышал - попробуй ещё раз")
		return

	var wav_bytes = _wav_bytes_from_recording(recording)
	var body = JSON.stringify({
		"audio_b64": Marshalls.raw_to_base64(wav_bytes),
		"quest_context": _build_quest_context(),
	})
	var url = "http://%s:%d/talk" % [server_host, server_port]
	waiting_for_reply = true
	_show_subtitle("Петя думает...")
	var err = http.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		waiting_for_reply = false
		_show_subtitle("Не получилось связаться с сервером Пети (%s:%d)" % [server_host, server_port])

func _on_request_completed(result, response_code, _headers, body):
	waiting_for_reply = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_show_subtitle("Петя не отвечает - проверь, запущен ли сервер")
		return
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		_show_subtitle("Петя ответил что-то непонятное")
		return
	var data = json.data
	var user_text = str(data.get("user_text", ""))
	var reply_text = str(data.get("reply_text", ""))
	var reply_audio_b64 = str(data.get("reply_audio_b64", ""))
	if reply_text == "":
		_show_subtitle("Петя не разобрал, что ты сказал")
		return
	_show_subtitle("Вы: %s\n\nПетя: %s" % [user_text, reply_text])
	if reply_audio_b64 != "":
		var stream = _audio_stream_from_wav(Marshalls.base64_to_raw(reply_audio_b64))
		if stream and is_instance_valid(petya_node):
			reply_player.global_position = petya_node.global_position + Vector3(0, 1.5, 0)
			reply_player.stream = stream
			reply_player.play()

# --- квестовый контекст: чтобы Петя знал, что уже сделано, а что ещё нет,
# и мог сослаться на конкретное задание, а не выдумывать несуществующее ---
func _build_quest_context() -> String:
	var sync = player.snow_sync
	var lines = ["Текущие задания, которые ты (Петя) даёшь игроку:"]
	for id in sync.QUESTS.keys():
		var q = sync.QUESTS[id]
		if sync.quest_completed.get(id, false):
			lines.append("- %s: выполнено" % q["name"])
		elif sync.quest_skipped.get(id, false):
			lines.append("- %s: игрок отказался от этого задания" % q["name"])
		else:
			var cur = sync.quest_progress.get(id, 0)
			lines.append("- %s: %d из %d (%s)" % [q["name"], cur, q["target"], q["desc"]])
	return "\n".join(lines)

# --- WAV: кодируем то, что записал микрофон (для отправки), и декодируем то,
# что прислал сервер (для проигрывания) - обычный канонический 44-байтный
# заголовок RIFF/WAVE поверх сырых PCM-сэмплов ---
func _wav_bytes_from_recording(stream: AudioStreamWAV) -> PackedByteArray:
	var bits = 8 if stream.format == AudioStreamWAV.FORMAT_8_BITS else 16
	var channels = 2 if stream.stereo else 1
	return _build_wav_bytes(stream.data, channels, int(stream.mix_rate), bits)

func _build_wav_bytes(pcm: PackedByteArray, channels: int, sample_rate: int, bits_per_sample: int) -> PackedByteArray:
	var block_align = channels * bits_per_sample / 8
	var byte_rate = sample_rate * block_align
	var header = PackedByteArray()
	header.resize(44)
	header[0] = 0x52; header[1] = 0x49; header[2] = 0x46; header[3] = 0x46          # "RIFF"
	header.encode_u32(4, 36 + pcm.size())
	header[8] = 0x57; header[9] = 0x41; header[10] = 0x56; header[11] = 0x45        # "WAVE"
	header[12] = 0x66; header[13] = 0x6D; header[14] = 0x74; header[15] = 0x20      # "fmt "
	header.encode_u32(16, 16)
	header.encode_u16(20, 1)   # PCM
	header.encode_u16(22, channels)
	header.encode_u32(24, sample_rate)
	header.encode_u32(28, byte_rate)
	header.encode_u16(32, block_align)
	header.encode_u16(34, bits_per_sample)
	header[36] = 0x64; header[37] = 0x61; header[38] = 0x74; header[39] = 0x61      # "data"
	header.encode_u32(40, pcm.size())
	var out = header
	out.append_array(pcm)
	return out

# ищет И "fmt " (частота/каналы/биты), И "data" по всему файлу, а не по
# фиксированным байтовым смещениям - раньше channels/sample_rate/bits читались
# из позиций 22/24/34 в предположении, что "fmt " всегда идёт сразу после "WAVE"
# 16-байтным куском; если у Piper (или конкретной версии/сборки) порядок чанков
# другой или fmt-чанк длиннее (расширенный формат) - в channels/sample_rate
# попадал мусор, из-за чего звук проигрывался на неверной скорости/частоте и
# превращался в нечленораздельную "кашу"
func _audio_stream_from_wav(bytes: PackedByteArray) -> AudioStreamWAV:
	if bytes.size() < 12:
		return null
	var channels = 1
	var sample_rate = 22050
	var bits_per_sample = 16
	var pos = 12
	var data_offset = -1
	var data_size = 0
	while pos + 8 <= bytes.size():
		var chunk_id = bytes.slice(pos, pos + 4).get_string_from_ascii()
		var chunk_size = bytes.decode_u32(pos + 4)
		var body = pos + 8
		if chunk_id == "fmt " and body + 16 <= bytes.size():
			channels = bytes.decode_u16(body + 2)
			sample_rate = bytes.decode_u32(body + 4)
			bits_per_sample = bytes.decode_u16(body + 14)
		elif chunk_id == "data":
			data_offset = body
			data_size = chunk_size
			break
		pos = body + chunk_size + (chunk_size % 2)
	if data_offset == -1 or data_offset + data_size > bytes.size():
		return null
	var stream = AudioStreamWAV.new()
	stream.data = bytes.slice(data_offset, data_offset + data_size)
	stream.format = AudioStreamWAV.FORMAT_16_BITS if bits_per_sample == 16 else AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = sample_rate
	stream.stereo = channels == 2
	return stream
