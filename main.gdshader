shader_type spatial;

// snow_mask   - накопленная очистка (растёт, пока игрок копает; 16-бит HDR viewport)
// snow_trample - отпечатки ботинок
uniform sampler2D snow_mask : hint_default_black, filter_linear;
uniform sampler2D snow_trample : hint_default_black, filter_linear;

uniform float ground_depth = 0.9;     // на сколько опускается поверхность при полной очистке (высота сугробов "по пояс")
uniform float min_thickness = 0.4;    // толщина самого тонкого слоя снега (0..1)
uniform float noise_scale = 12.0;      // размер сугробов: больше = мельче
uniform float clear_max = 0.85;       // значение маски, при котором копка "дошла" до предела
uniform float press_depth = 0.2;      // на сколько отпечаток приминает снег

uniform vec4 snow_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 thin_snow_color : source_color = vec4(0.82, 0.87, 0.93, 1.0);
uniform vec4 trampled_color : source_color = vec4(0.75, 0.8, 0.85, 1.0);
uniform vec4 ground_color : source_color = vec4(0.35, 0.25, 0.15, 1.0);
uniform vec4 ground_print_color : source_color = vec4(0.18, 0.12, 0.07, 1.0); // след на голой земле
uniform float ground_press = 0.05;  // вмятина следа на голой земле

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Исходная толщина снега в точке: плавные сугробы и тонкие участки.
float snow_thickness(vec2 uv) {
	float n = value_noise(uv * noise_scale) * 0.65 + value_noise(uv * noise_scale * 2.3 + 7.7) * 0.35;
	return mix(min_thickness, 1.0, smoothstep(0.2, 0.8, n));
}

// Сколько снега осталось (0 = голая земля, 1 = максимальный слой).
float snow_remaining(vec2 uv, float clear_val, float trample_val) {
	float dug = clamp(clear_val / clear_max, 0.0, 1.0);
	float rem = max(snow_thickness(uv) - dug, 0.0);
	return clamp(rem - trample_val * press_depth * step(0.001, rem), 0.0, 1.0);
}

// Размытые значения масок для геометрии (x = очистка, y = следы):
// усредняем 5x5 точек, чтобы стенки были пологими, без зубцов.
vec2 masks_blurred(vec2 uv) {
	float texel = 1.0 / 1024.0;
	vec2 sum = vec2(0.0);
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			vec2 o = uv + vec2(float(x), float(y)) * texel * 2.0;
			sum += vec2(texture(snow_mask, o).r, texture(snow_trample, o).r);
		}
	}
	return sum / 25.0;
}

void vertex() {
	vec2 m = masks_blurred(UV);
	float rem = snow_remaining(UV, m.x, m.y);
	VERTEX.y -= ground_depth * (1.0 - rem);
}

void fragment() {
	float clear_val = texture(snow_mask, UV).r;
	float trample_val = texture(snow_trample, UV).r;
	float rem = snow_remaining(UV, clear_val, trample_val);

	// глубокий снег белее, тонкий слой - серовато-голубой
	vec3 color = mix(thin_snow_color.rgb, snow_color.rgb, smoothstep(0.2, 1.0, rem));
	color = mix(color, trampled_color.rgb, clamp(trample_val, 0.0, 1.0) * 0.8);
	// на голой земле недавний след виден как светлое пятно (занесённый снег/слякоть) -
	// сама текстура следов постепенно затухает со временем, так что он не навечно
	vec3 ground = mix(ground_color.rgb, vec3(0.95, 0.96, 0.98), clamp(trample_val * 1.3, 0.0, 1.0));
	color = mix(ground, color, smoothstep(0.0, 0.12, rem));
	ALBEDO = color;
	ROUGHNESS = 0.9;
}
