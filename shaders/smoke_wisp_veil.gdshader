shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec3 veil_color : source_color = vec3(0.64, 0.88, 0.88);
uniform vec3 accent_color : source_color = vec3(0.52, 1.0, 0.84);
uniform float opacity_scale : hint_range(0.0, 1.5) = 0.52;
uniform float plane_angle_y = 0.0;
uniform vec3 plane_offset = vec3(0.0, 0.02, 0.0);
uniform float seed_offset = 0.0;
uniform vec2 flight_lean = vec2(0.0, 0.0);

uniform vec4 trail_pos_strength[8];
uniform vec4 trail_push_radius[8];

varying vec2 v_uv;
varying float v_carve;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm2(vec2 p) {
	float v = 0.0;
	float amp = 0.54;
	for (int i = 0; i < 4; i++) {
		v += amp * noise2(p);
		p = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6)) * p + vec2(1.9, -2.1);
		amp *= 0.5;
	}
	return v;
}

vec3 rot_y(vec3 v, float ang) {
	float c = cos(ang);
	float s = sin(ang);
	return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

void vertex() {
	v_uv = UV;
	float t = TIME + seed_offset;
	float h = 1.0 - UV.y;

	vec3 local_v = VERTEX;
	// 상단으로 갈수록 굽이치며 휘어지는 연기 베일
	local_v.x += sin(t * 1.9 - h * 5.2 + seed_offset) * 0.028 * h * h + 0.024 * h * h;

	vec3 body_p = rot_y(local_v, plane_angle_y) + plane_offset;
	body_p.x -= flight_lean.x * 0.09 * h * h;
	body_p.z -= flight_lean.y * 0.09 * h * h;

	vec3 disp = vec3(0.0);
	float carve_acc = 0.0;
	for (int i = 0; i < 8; i++) {
		float strength = trail_pos_strength[i].w;
		if (strength > 0.002) {
			vec3 tp = trail_pos_strength[i].xyz;
			vec3 push_v = trail_push_radius[i].xyz;
			float rad = max(0.038, trail_push_radius[i].w);
			vec3 diff = body_p - tp;
			float dist = length(diff);
			float w = exp(-(dist * dist) / (rad * rad));
			float wave = sin(clamp(strength, 0.0, 1.0) * 3.14159265);
			vec3 radial_out = dist > 0.001 ? (diff / dist) : vec3(0.0, 1.0, 0.0);
			disp += (push_v * 0.135 + radial_out * 0.075) * w * wave;
			carve_acc = max(carve_acc, w * strength);
		}
	}

	vec3 inv_disp = rot_y(disp, -plane_angle_y);
	VERTEX = local_v + inv_disp;
	v_carve = clamp(carve_acc, 0.0, 1.0);
}

void fragment() {
	float t = TIME + seed_offset;
	vec2 uv = v_uv;
	float h = 1.0 - uv.y; // 0 = bottom tendrils, 1 = top curling plume

	// 비대칭 물방울·연기 깃털 외곽 마스크 (사각형 테두리가 절대 보이지 않도록 완전히 감쇠)
	float center_curve = sin(h * 4.4 - t * 1.6 + seed_offset) * 0.09 * h + 0.06 * h * h;
	float width_profile = mix(0.20, 0.36, smoothstep(0.02, 0.38, h)) * mix(1.0, 0.14, smoothstep(0.45, 0.98, h));
	float dx = abs((uv.x - 0.5) - center_curve);
	float radial_mask = 1.0 - smoothstep(width_profile * 0.35, max(0.04, width_profile), dx);
	float vertical_mask = smoothstep(0.01, 0.16, h) * (1.0 - smoothstep(0.80, 0.99, h));

	// 도메인 워핑 컬 연기 결
	vec2 q = vec2(
		fbm2(uv * vec2(3.6, 4.8) + vec2(0.0, t * 0.95)),
		fbm2(uv * vec2(3.6, 4.8) + vec2(4.2, t * 1.25))
	);
	float wisps = fbm2(uv * vec2(4.8, 6.4) + q * 1.55 + vec2(0.0, t * 1.45));
	float ribbon = smoothstep(0.34, 0.78, wisps);

	float alpha = radial_mask * vertical_mask * ribbon * opacity_scale;
	// 손이 스쳐간 궤적 자리 연기 갈라짐
	alpha *= mix(1.0, 0.14, clamp(v_carve * 1.2, 0.0, 0.92));

	vec3 col = mix(veil_color, accent_color, smoothstep(0.48, 0.85, wisps) * (1.0 - 0.45 * h));
	ALBEDO = col * 1.15;
	ALPHA = clamp(alpha, 0.0, 0.85);
}
