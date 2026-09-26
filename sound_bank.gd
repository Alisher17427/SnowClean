extends RefCounted

# Звуки создаются программой при запуске (файлов и импорта не нужно):
# хруст шагов по снегу, копка и ветер. Всё моно, 16 бит.

const RATE = 22050

static func _to_stream(data: PackedFloat32Array, peak: float) -> AudioStreamWAV:
	var m = 0.0001
	for v in data:
		m = max(m, abs(v))
	var k = peak / m
	var bytes = PackedByteArray()
	bytes.resize(data.size() * 2)
	for i in range(data.size()):
		bytes.encode_s16(i * 2, int(clamp(data[i] * k, -1.0, 1.0) * 32767.0))
	var s = AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = bytes
	return s

# короткие вспышки шума = хруст снежинок под давлением
static func _add_crunch(buf: PackedFloat32Array, rng: RandomNumberGenerator, t0: float, t1: float, count: int, amp: float, bright: float = 0.6):
	for g in range(count):
		var start = int(rng.randf_range(t0, t1) * RATE)
		var glen = int(rng.randf_range(0.003, 0.009) * RATE)
		var a = amp * rng.randf_range(0.3, 1.0)
		var prev = 0.0
		for i in range(glen):
			if start + i >= buf.size():
				break
			var x = rng.randf_range(-1.0, 1.0)
			var hp = x - prev * bright   # bright: 0.6 = резче, 0.0 = сглаженнее
			prev = x
			var env = 1.0 - float(i) / glen
			buf[start + i] += hp * env * env * a

static func _add_thump(buf: PackedFloat32Array, rng: RandomNumberGenerator, t0: float, dur: float, amp: float, lp: float):
	var start = int(t0 * RATE)
	var n = int(dur * RATE)
	var y = 0.0
	for i in range(n):
		if start + i >= buf.size():
			break
		y += lp * (rng.randf_range(-1.0, 1.0) - y)
		buf[start + i] += y * exp(-float(i) / RATE * 22.0) * amp

# шаг по морозному снегу: приглушённый "скрип" (резонансный шум с плывущей частотой)
# и глухой "пуф" под ним
static func make_step(seed_value: int) -> AudioStreamWAV:
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	var buf = PackedFloat32Array()
	buf.resize(int(RATE * 0.3))
	var n = int(RATE * 0.22)
	var f0 = rng.randf_range(1500.0, 2000.0)
	var f1 = f0 * rng.randf_range(0.45, 0.6)
	var low = 0.0
	var band = 0.0
	for i in range(n):
		var t = float(i) / n
		var fc = lerp(f0, f1, t)
		var f = 2.0 * sin(PI * fc / RATE)
		var x = rng.randf_range(-1.0, 1.0)
		low += f * band
		var high = x - low - 0.12 * band
		band += f * high
		var env = smoothstep(0.0, 0.08, t) * pow(1.0 - t, 1.5)
		buf[i] += band * env * 0.25
	_add_thump(buf, rng, 0.0, 0.2, 1.2, 0.05)
	return _to_stream(buf, 0.6)

# звук копки: только мягкий взмах руки (играет в момент нажатия клавиши)
static func make_dig(seed_value: int) -> AudioStreamWAV:
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	var buf = PackedFloat32Array()
	buf.resize(int(RATE * 0.3))
	var y = 0.0
	for i in range(buf.size()):
		var t = float(i) / buf.size()
		y += 0.08 * (rng.randf_range(-1.0, 1.0) - y)
		buf[i] += y * sin(PI * t) * sin(PI * t)
	return _to_stream(buf, 0.65)

# бесшовный ветер: длинный шум с медленными порывами, концы сшиты кроссфейдом
static func make_wind(seconds: float = 8.0) -> AudioStreamWAV:
	var rng = RandomNumberGenerator.new()
	rng.seed = 4242
	var n = int(RATE * seconds)
	var ov = int(RATE * 1.0)
	var raw = PackedFloat32Array()
	raw.resize(n + ov)
	var y = 0.0
	var y2 = 0.0
	for i in range(n + ov):
		var t = float(i) / RATE
		var gust = 0.55 + 0.25 * sin(TAU * t / seconds) + 0.2 * sin(TAU * 3.0 * t / seconds + 1.3)
		y += (0.02 + 0.03 * gust) * (rng.randf_range(-1.0, 1.0) - y)
		y2 += 0.5 * (y - y2)
		raw[i] = y2 * gust
	var out = PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		if i < ov:
			var w = float(i) / ov
			out[i] = raw[i] * w + raw[n + i] * (1.0 - w)
		else:
			out[i] = raw[i]
	var s = _to_stream(out, 0.6)
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = n
	return s

# треск камина: тихое шипение углей + редкие резкие щелчки-хлопки, бесшовный луп
static func make_fire_crackle(seconds: float = 6.0) -> AudioStreamWAV:
	var rng = RandomNumberGenerator.new()
	rng.seed = 777
	var n = int(RATE * seconds)
	var ov = int(RATE * 0.5)
	var raw = PackedFloat32Array()
	raw.resize(n + ov)
	# фоновое шипение - мягкий приглушённый шум
	var low = 0.0
	for i in range(n + ov):
		var x = rng.randf_range(-1.0, 1.0)
		low += 0.06 * (x - low)
		raw[i] = low * 0.35
	# случайные потрескивания углей - короткие резкие щелчки вразнобой
	var t = 0.0
	while t < seconds:
		t += rng.randf_range(0.05, 0.35)
		var start = int(t * RATE)
		var glen = int(rng.randf_range(0.006, 0.02) * RATE)
		var amp = rng.randf_range(0.3, 1.0)
		var prev = 0.0
		for i in range(glen):
			if start + i >= raw.size():
				break
			var x = rng.randf_range(-1.0, 1.0)
			var hp = x - prev * 0.5
			prev = x
			var env = 1.0 - float(i) / glen
			raw[start + i] += hp * env * env * amp
	var out = PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		if i < ov:
			var w = float(i) / ov
			out[i] = raw[i] * w + raw[n + i] * (1.0 - w)
		else:
			out[i] = raw[i]
	var s2 = _to_stream(out, 0.5)
	s2.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s2.loop_begin = 0
	s2.loop_end = n
	return s2

# отфильтрованный шум для дыхания: один "поддон" низких частот делает его мягким,
# высокочастотная часть сверху добавляет лёгкое шипение воздуха
static func _breath_noise(rng: RandomNumberGenerator, n: int, lp_k: float, hp_amt: float) -> PackedFloat32Array:
	var buf = PackedFloat32Array()
	buf.resize(n)
	var low = 0.0
	var prev_low = 0.0
	for i in range(n):
		var x = rng.randf_range(-1.0, 1.0)
		low += lp_k * (x - low)
		buf[i] = low - prev_low * hp_amt
		prev_low = low
	return buf

# выдох: гуще и громче вдоха, нарастает и спадает за время видимого пара изо рта
static func make_breath_exhale(seed_value: int) -> AudioStreamWAV:
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	var n = int(RATE * 1.0)
	var raw = _breath_noise(rng, n, 0.045, 0.25)
	var buf = PackedFloat32Array()
	buf.resize(n)
	for i in range(n):
		var t = float(i) / n
		buf[i] = raw[i] * pow(sin(PI * t), 0.8)
	return _to_stream(buf, 0.5)

# вдох: тише и чуть светлее выдоха (через нос/приоткрытый рот)
static func make_breath_inhale(seed_value: int) -> AudioStreamWAV:
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	var n = int(RATE * 1.05)
	var raw = _breath_noise(rng, n, 0.07, 0.18)
	var buf = PackedFloat32Array()
	buf.resize(n)
	for i in range(n):
		var t = float(i) / n
		buf[i] = raw[i] * pow(sin(PI * t), 1.1)
	return _to_stream(buf, 0.32)

# попадание снежка: мягкий глухой "шлёп" - короткий отфильтрованный шум с резким затуханием
static func make_snowball_hit(seed_value: int) -> AudioStreamWAV:
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	var buf = PackedFloat32Array()
	buf.resize(int(RATE * 0.25))
	_add_thump(buf, rng, 0.0, 0.18, 1.3, 0.09)
	_add_crunch(buf, rng, 0.0, 0.05, 4, 0.5, 0.3)
	return _to_stream(buf, 0.6)
