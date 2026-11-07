shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec2 pupil_offset = vec2(0.0, 0.0);
uniform float blink_amount : hint_range(0.0, 1.0) = 0.0;
uniform float happy_squint : hint_range(0.0, 1.0) = 0.0;
uniform vec3 sclera_tint : source_color = vec3(0.96, 1.0, 0.99);
uniform vec3 pupil_color : source_color = vec3(0.24, 0.48, 0.48);
uniform vec3 aura_color : source_color = vec3(0.55, 1.0, 0.88);

void fragment() {
	// UV 중심을 (-1..1) 좌표로 변환 (p.y = -1 위쪽, +1 아래쪽)
	vec2 p = (UV - vec2(0.5)) * 2.0;

	// 눈 깜빡임 세로 스케일 압축
	float open_h = max(0.07, 1.0 - blink_amount * 0.93);
	vec2 ep = vec2(p.x * 0.92, p.y / open_h);

	// 레퍼런스처럼 위쪽이 살짝 둥글고 아래쪽이 완만한 아몬드-방울 눈매
	ep.x *= mix(0.88, 1.14, clamp((ep.y + 1.0) * 0.5, 0.0, 1.0));
	float eye_dist = length(ep);

	// 웃을 때(∩ ∩) 아랫눈꺼풀이 초승달 아치형으로 올라와 반달 눈매 형성
	float smile_lid_y = mix(1.28, 0.02, happy_squint) + 0.62 * p.x * p.x;
	float smile_cut = mix(1.0, 1.0 - smoothstep(smile_lid_y - 0.10, smile_lid_y + 0.08, p.y), clamp(happy_squint * 1.25, 0.0, 1.0));

	float outer_glow = (1.0 - smoothstep(0.68, 1.0, eye_dist)) * 0.48 * smile_cut;
	float sclera_mask = (1.0 - smoothstep(0.66, 0.76, eye_dist)) * smile_cut;

	// 눈동자(pupil)가 흰자 안에서 굴러다니도록 오프셋 적용
	vec2 smile_pupil_shift = vec2(0.0, -0.18 * happy_squint);
	vec2 pp = (p - (pupil_offset + smile_pupil_shift) * vec2(0.34, 0.28)) / vec2(0.28, 0.40 * open_h);
	float pupil_mask = (1.0 - smoothstep(0.78, 0.96, length(pp))) * sclera_mask;

	// 작은 하이라이트 반사광
	vec2 hp = (p - (pupil_offset + smile_pupil_shift) * vec2(0.30, 0.24) - vec2(-0.10, -0.14)) / vec2(0.10, 0.11);
	float catchlight = (1.0 - smoothstep(0.6, 1.0, length(hp))) * pupil_mask * 0.88;

	vec3 col = mix(aura_color, sclera_tint * 1.25, sclera_mask);
	col = mix(col, pupil_color, pupil_mask * 0.90);
	col = mix(col, vec3(1.0), catchlight);

	float alpha = clamp(max(sclera_mask * 0.97, outer_glow * (1.0 - blink_amount * 0.6)), 0.0, 1.0);
	ALBEDO = col;
	ALPHA = alpha;
}
