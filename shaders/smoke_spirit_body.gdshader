shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec3 core_color : source_color = vec3(0.58, 1.0, 0.86);
uniform vec3 mid_color : source_color = vec3(0.26, 0.86, 0.78);
uniform vec3 mist_color : source_color = vec3(0.62, 0.82, 0.85);
uniform float glow_boost : hint_range(0.5, 3.0) = 1.25;
uniform float time_offset = 0.0;
uniform vec2 flight_lean = vec2(0.0, 0.0);

// 손이 지나간 궤적 국소 연기 흩어짐·재응집 버퍼 (정령 로컬 좌표계)
uniform vec4 trail_pos_strength[8];
uniform vec4 trail_push_radius[8];

varying vec3 v_body_pos;
varying float v_carve;
varying float v_height01;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise3(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = hash31(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(i + vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);

	float nxy0 = mix(nx00, nx10, f.y);
	float nxy1 = mix(nx01, nx11, f.y);
	return mix(nxy0, nxy1, f.z);
}

float fbm3(vec3 p) {
	float v = 0.0;
	float a = 0.52;
	for (int i = 0; i < 4; i++) {
		v += a * noise3(p);
		p = p * 2.04 + vec3(1.7, -2.3, 1.1);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	float t = TIME + time_offset;
	vec3 p = VERTEX;

	// 구체가 아닌 비대칭 물방울·불꽃 연기 실루엣으로 조형 (레퍼런스 윗꼬리 컬 + 아랫자락 연기 결)
	float h = clamp((p.y + 0.13) / 0.28, 0.0, 1.0);
	v_height01 = h;

	float upper_taper = mix(1.08, 0.24, smoothstep(0.32, 1.0, h));
	float lower_taper = mix(0.45, 1.0, smoothstep(0.0, 0.26, h));
	float radial_scale = upper_taper * lower_taper;
	p.xz *= radial_scale;
	p.y *= 1.42;

	// 상단 연기 꼬리의 유기적 비대칭 스월 + 비행 방향 관성 기울임
	float curl_phase = h * h;
	p.x += sin(t * 2.1 - h * 4.6) * 0.030 * curl_phase + 0.026 * curl_phase - flight_lean.x * 0.085 * curl_phase;
	p.z += cos(t * 1.7 - h * 3.8) * 0.022 * curl_phase - flight_lean.y * 0.085 * curl_phase;

	// 표면 연기 일렁임 변위
	float surf_n = fbm3(p * 11.5 - vec3(0.0, t * 1.85, t * 0.4));
	p += NORMAL * ((surf_n - 0.48) * 0.032 * (0.45 + 0.85 * h));

	// 손이 지나간 궤적 국소 흩어짐 -> 재응집 물리 변위
	vec3 disp = vec3(0.0);
	float carve_acc = 0.0;
	for (int i = 0; i < 8; i++) {
		float strength = trail_pos_strength[i].w;
		if (strength > 0.002) {
			vec3 tp = trail_pos_strength[i].xyz;
			vec3 push_v = trail_push_radius[i].xyz;
			float rad = max(0.035, trail_push_radius[i].w);
			vec3 diff = p - tp;
			float dist = length(diff);
			float w = exp(-(dist * dist) / (rad * rad));
			float wave = sin(clamp(strength, 0.0, 1.0) * 3.14159265);
			vec3 radial_out = dist > 0.001 ? (diff / dist) : vec3(0.0, 1.0, 0.0);
			disp += (push_v * 0.125 + radial_out * 0.072) * w * wave;
			carve_acc = max(carve_acc, w * strength);
		}
	}

	p += disp;
	VERTEX = p;
	v_body_pos = p;
	v_carve = clamp(carve_acc, 0.0, 1.0);
}

void fragment() {
	float t = TIME + time_offset;
	vec3 flow_p = v_body_pos * 13.5 - vec3(0.0, t * 2.15, t * 0.55);
	float warp = fbm3(flow_p * 0.75 + vec3(2.4, -t * 0.8, 1.3));
	float smoke = fbm3(flow_p + vec3(warp * 1.45, -warp * 1.1, warp * 0.9));

	float ndv = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float fresnel_core = pow(clamp(ndv, 0.0, 1.0), 1.15);

	// 가장자리가 구형으로 끊기지 않고 연기 불꽃 결을 따라 자연스럽게 녹아내리도록 처리
	float silhouette = fresnel_core * (0.62 + 0.78 * smoke) * mix(1.0, 0.68, smoothstep(0.72, 1.0, v_height01));
	float density = smoothstep(0.16, 0.72, silhouette);

	// 손 궤적이 스쳐간 자리만 연기가 실오라기처럼 갈라졌다가 다시 모임
	float shred_noise = fbm3(v_body_pos * 26.0 - vec3(0.0, t * 3.8, 0.0));
	float parted_keep = mix(1.0, smoothstep(0.46, 0.84, shred_noise) * 0.25, clamp(v_carve * 1.25, 0.0, 0.94));
	float final_alpha = clamp(density * parted_keep * 0.92, 0.0, 0.95);

	// 중심부 밝은 민트-아쿠아 발광 -> 중간 청록 불꽃 -> 외곽 은빛 연기 그라데이션
	float inner_hot = smoothstep(0.38, 0.86, silhouette) * (1.0 - 0.35 * v_height01);
	vec3 col = mix(mist_color, mid_color, smoothstep(0.18, 0.58, silhouette));
	col = mix(col, core_color, inner_hot);

	// 손이 가르며 지나간 궤적 테두리에 은은한 발광 잔영 추가
	float wake_rim = v_carve * (1.0 - v_carve * 0.55) * 0.65;
	col += core_color * wake_rim;

	vec3 boosted = col * glow_boost;
	float max_c = max(boosted.r, max(boosted.g, boosted.b));
	if (max_c > 1.0) {
		boosted = mix(boosted / max_c, min(boosted, vec3(1.0)), 0.28);
	}
	ALBEDO = boosted;
	ALPHA = final_alpha;
}
