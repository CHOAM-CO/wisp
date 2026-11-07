shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec2 pupil_offset = vec2(0.0, 0.0);
uniform float blink_amount : hint_range(0.0, 1.0) = 0.0;
uniform float happy_squint : hint_range(0.0, 1.0) = 0.0;
uniform vec3 sclera_tint : source_color = vec3(0.96, 1.0, 0.99);
uniform vec3 pupil_color : source_color = vec3(0.24, 0.48, 0.48);
uniform vec3 aura_color : source_color = vec3(0.55, 1.0, 0.88);

void fragment() {
	// UV 중심을 (-1..1) 좌표로 변환
	vec2 p = (UV - vec2(0.5)) * 2.0;

	// 웃을 때(^ ^) 눈 아랫부분이 부드러운 아치형으로 휘어 올라감
	p.y += happy_squint * (0.42 - 0.52 * p.x * p.x);

	// 눈 깜빡임 세로 스케일 압축
	float open_h = max(0.07, 1.0 - blink_amount * 0.93);
	vec2 ep = vec2(p.x * 0.92, p.y / open_h);

	// 레퍼런스처럼 위쪽이 살짝 둥글고 아래쪽이 완만한 아몬드-방울 눈매
	ep.x *= mix(0.88, 1.14, clamp((ep.y + 1.0) * 0.5, 0.0, 1.0));
	float eye_dist = length(ep);

	float outer_glow = (1.0 - smoothstep(0.68, 1.0, eye_dist)) * 0.48;
	float sclera_mask = 1.0 - smoothstep(0.66, 0.76, eye_dist);

	// 눈동자(pupil)가 흰자 안에서 굴러다니도록 오프셋 적용
	vec2 pp = (p - pupil_offset * vec2(0.34, 0.28)) / vec2(0.28, 0.42 * open_h);
	float pupil_mask = (1.0 - smoothstep(0.78, 0.96, length(pp))) * sclera_mask * (1.0 - happy_squint * 0.82);

	// 작은 하이라이트 반사광
	vec2 hp = (p - pupil_offset * vec2(0.30, 0.24) - vec2(-0.10, -0.14)) / vec2(0.10, 0.11);
	float catchlight = (1.0 - smoothstep(0.6, 1.0, length(hp))) * pupil_mask * 0.85;

	vec3 col = mix(aura_color, sclera_tint * 1.25, sclera_mask);
	col = mix(col, pupil_color, pupil_mask * 0.90);
	col = mix(col, vec3(1.0), catchlight);

	float alpha = clamp(max(sclera_mask * 0.97, outer_glow * (1.0 - blink_amount * 0.6)), 0.0, 1.0);
	ALBEDO = col;
	ALPHA = alpha;
}
