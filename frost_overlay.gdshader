shader_type canvas_item;

// оверлей изморози на экране: чем ниже тепло игрока, тем сильнее иней наползает
// с краёв экрана к центру. intensity выставляет new_script.gd (_update_frost_overlay)
uniform float intensity : hint_range(0.0, 1.0) = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += amp * value_noise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 uv = UV;
	// расстояние до ближайшего края экрана (компенсируем соотношение сторон,
	// чтобы иней одинаково наползал и по бокам, и сверху/снизу)
	vec2 edge = min(uv, 1.0 - uv);
	float edge_dist = min(edge.x * 1.6, edge.y);
	float spread = mix(0.04, 0.6, intensity);
	float base = 1.0 - smoothstep(0.0, spread, edge_dist);

	// ломаная кристаллическая фактура поверх ровного затемнения краёв -
	// без неё иней выглядел бы как гладкая виньетка, а не как настоящий лёд
	float crystal = fbm(uv * 9.0 + vec2(0.0, intensity * 2.0));
	float branches = smoothstep(0.35, 0.9, crystal + base * 0.6);

	float alpha = clamp(base * 0.85 + branches * base * 0.65, 0.0, 1.0) * intensity;
	vec3 frost_color = vec3(0.86, 0.93, 1.0);
	COLOR = vec4(frost_color, alpha);
}
