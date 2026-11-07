class_name SmokeSpiritActor
extends Node3D

signal spirit_dispersed(hand_tag: String, speed_mps: float, zone_ko: String)
signal spirit_chased_by_pointer(pointer_source: String)

const BodyShader = preload("res://shaders/smoke_spirit_body.gdshader")
const VeilShader = preload("res://shaders/smoke_wisp_veil.gdshader")
const EyeShader = preload("res://shaders/smoke_eye.gdshader")

const MAX_TRAIL_SLOTS: int = 8
const WISP_POOL_SIZE: int = 24

enum RoamState {
	ANCHOR_WATCH,
	WANDER_POINT,
	LOOK_WITH_USER,
	COME_CLOSER,
	HAPPY_SPIN
}

var body_pivot: Node3D
var core_mesh: MeshInstance3D
var core_mat: ShaderMaterial
var veil_mats: Array[ShaderMaterial] = []
var eye_left_mat: ShaderMaterial
var eye_right_mat: ShaderMaterial
var status_label: Label3D

var mote_items: Array[Dictionary] = []
var wisp_pool: Array[Dictionary] = []
var wisp_container: Node3D

# 손 궤적 국소 흩어짐 슬롯
var trail_slots: Array[Dictionary] = []
var prev_hand_positions: Dictionary = {}
var disperse_signal_cooldown: float = 0.0
var local_recoil_vel: Vector3 = Vector3.ZERO

# 포인터 레이 도망 기믹 & 눈알 추적 상태
var has_active_pointer: bool = false
var pointer_focal_world: Vector3 = Vector3.ZERO
var flee_offset: Vector3 = Vector3.ZERO
var dodge_side_sign: float = 1.0
var pointer_chase_accum: float = 0.0
var pointer_chase_signal_cooldown: float = 0.0
var fleeing_now: bool = false

# 위치 및 자율 비행 물리
var home_pos: Vector3 = Vector3(0.30, 1.44, -0.92)
var active_goal_pos: Vector3 = Vector3(0.30, 1.44, -0.92)
var velocity: Vector3 = Vector3.ZERO
var time_sec: float = 0.0

var roam_state: int = RoamState.ANCHOR_WATCH
var roam_state_timer: float = 0.0
var quiet_idle_sec: float = 0.0
var next_idle_action_at: float = 6.5
var spin_angle_accum: float = 0.0
var nod_timer: float = 0.0

# 눈알 굴림·깜빡임·감정 상태
var pupil_current: Vector2 = Vector2.ZERO
var pupil_saccade: Vector2 = Vector2.ZERO
var saccade_timer: float = 1.8
var eye_roll_phase: float = -1.0
var blink_timer: float = 2.6
var blink_progress: float = -1.0
var double_blink_pending: bool = false

var mood_override: String = ""
var mood_override_timer: float = 0.0
var excited_timer: float = 0.0
var indexed_pulse_timer: float = 0.0
var gaze_focus_strength: float = 0.0
var speaking_energy: float = 0.0


func setup(kr_font: Font, initial_home: Vector3) -> void:
	home_pos = initial_home
	active_goal_pos = initial_home
	position = initial_home

	body_pivot = Node3D.new()
	body_pivot.name = "BodyPivot"
	add_child(body_pivot)

	# 1) 프로시저럴 불꽃·연기 코어 메쉬
	core_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.105
	sphere.height = 0.210
	sphere.radial_segments = 36
	sphere.rings = 28
	core_mesh.mesh = sphere

	core_mat = ShaderMaterial.new()
	core_mat.shader = BodyShader
	core_mat.render_priority = 0
	core_mesh.material_override = core_mat
	body_pivot.add_child(core_mesh)

	# 2) 3중 교차 볼류메트릭 컬 연기 베일 (어느 각도/뒷모습에서도 유기적인 연기 실루엣 유지)
	var angles_deg: Array[float] = [0.0, 58.0, 122.0]
	for idx in range(angles_deg.size()):
		var vm := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.28, 0.39)
		qm.subdivide_width = 14
		qm.subdivide_depth = 18
		vm.mesh = qm
		var ang_rad: float = deg_to_rad(angles_deg[idx])
		var off := Vector3(0.0, 0.025, 0.0)
		vm.position = off
		vm.rotation.y = ang_rad

		var vmat := ShaderMaterial.new()
		vmat.shader = VeilShader
		vmat.render_priority = 1
		vmat.set_shader_parameter("plane_angle_y", ang_rad)
		vmat.set_shader_parameter("plane_offset", off)
		vmat.set_shader_parameter("seed_offset", float(idx) * 2.17)
		vmat.set_shader_parameter("opacity_scale", 0.50 if idx == 0 else 0.38)
		vm.material_override = vmat
		body_pivot.add_child(vm)
		veil_mats.append(vmat)

	# 3) 눈알을 굴리고 깜빡이며 표정 짓는 두 눈 (+Z 정면 배치: 뒤돌아볼 때는 뒷모습만 보임!)
	for side_idx in range(2):
		var side: float = -1.0 if side_idx == 0 else 1.0
		var eye_mi := MeshInstance3D.new()
		var eq := QuadMesh.new()
		eq.size = Vector2(0.046, 0.052)
		eye_mi.mesh = eq
		var emat := ShaderMaterial.new()
		emat.shader = EyeShader
		emat.render_priority = 2
		eye_mi.material_override = emat
		eye_mi.position = Vector3(side * 0.033, 0.008, 0.094)
		eye_mi.rotation.y = side * deg_to_rad(13.0)
		body_pivot.add_child(eye_mi)
		if side_idx == 0:
			eye_left_mat = emat
		else:
			eye_right_mat = emat

	# 4) 레퍼런스 주변의 반짝이는 미세 연기 불씨 입자 (16개)
	for i in range(16):
		var mote := MeshInstance3D.new()
		var ms := SphereMesh.new()
		var mr: float = randf_range(0.0026, 0.0046)
		ms.radius = mr
		ms.height = mr * 2.0
		ms.radial_segments = 8
		ms.rings = 6
		mote.mesh = ms
		var mmat := StandardMaterial3D.new()
		mmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mmat.albedo_color = Color(0.75, 1.0, 0.92, 0.78)
		mmat.render_priority = 2
		mote.material_override = mmat
		body_pivot.add_child(mote)
		mote_items.append({
			"mesh": mote,
			"mat": mmat,
			"phase": randf() * TAU,
			"speed": randf_range(0.85, 1.65),
			"radius": randf_range(0.085, 0.145),
			"base_y": randf_range(-0.09, 0.16)
		})

	# 5) 손이 지나간 궤적에서 흩어져 나갔다가 다시 정령 몸체로 빨려 들어오는 연기 조각 VFX 풀
	wisp_container = Node3D.new()
	wisp_container.name = "DetachedSmokeWispVFX"
	wisp_container.top_level = true
	add_child(wisp_container)
	for i in range(WISP_POOL_SIZE):
		var wmi := MeshInstance3D.new()
		var wq := QuadMesh.new()
		wq.size = Vector2(0.085, 0.115)
		wmi.mesh = wq
		var wmat := ShaderMaterial.new()
		wmat.shader = VeilShader
		wmat.render_priority = 2
		wmat.set_shader_parameter("seed_offset", float(i) * 1.37 + 5.0)
		wmat.set_shader_parameter("opacity_scale", 0.0)
		wmi.material_override = wmat
		wmi.visible = false
		wisp_container.add_child(wmi)
		wisp_pool.append({
			"mesh": wmi,
			"mat": wmat,
			"active": false,
			"age": 0.0,
			"lifetime": 1.2,
			"world_pos": Vector3.ZERO,
			"scatter_vel": Vector3.ZERO,
			"return_local_offset": Vector3.ZERO
		})

	for i in range(MAX_TRAIL_SLOTS):
		trail_slots.append({
			"local_pos": Vector3.ZERO,
			"strength": 0.0,
			"local_dir": Vector3.UP,
			"radius": 0.08
		})

	status_label = Label3D.new()
	if kr_font != null:
		status_label.font = kr_font
	status_label.font_size = 21
	status_label.pixel_size = 0.00118
	status_label.outline_size = 5
	status_label.render_priority = 4
	status_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	status_label.position = Vector3(0.0, 0.24, 0.0)
	status_label.text = "함께 보고 있어"
	add_child(status_label)

	_sync_trail_uniforms()


func notify_user_or_agent_activity() -> void:
	quiet_idle_sec = 0.0
	if roam_state == RoamState.WANDER_POINT or roam_state == RoamState.LOOK_WITH_USER:
		roam_state = RoamState.ANCHOR_WATCH
		active_goal_pos = home_pos


func trigger_named_action(action_name: String, mood_name: String = "") -> void:
	var act: String = action_name.strip_edges().to_lower()
	if mood_name != "":
		mood_override = mood_name.to_lower()
		mood_override_timer = 4.0

	if act == "look_with_user" or act == "share_gaze":
		roam_state = RoamState.LOOK_WITH_USER
		roam_state_timer = 3.6
	elif act == "come_closer" or act == "peek":
		roam_state = RoamState.COME_CLOSER
		roam_state_timer = 3.4
	elif act == "happy_spin" or act == "spin" or act == "happy_wiggle":
		roam_state = RoamState.HAPPY_SPIN
		roam_state_timer = 1.6
		spin_angle_accum = 0.0
		excited_timer = 1.8
	elif act == "nod":
		nod_timer = 0.9
		excited_timer = 1.0
	elif act == "wander":
		_start_autonomous_roam_step(true)


func ingest_pointer_rays(rays: Array, cam_tf: Transform3D, delta: float) -> void:
	# rays: [{"origin": Vector3, "dir": Vector3, "source": String}]
	if pointer_chase_signal_cooldown > 0.0:
		pointer_chase_signal_cooldown = maxf(0.0, pointer_chase_signal_cooldown - delta)

	has_active_pointer = false
	fleeing_now = false

	if rays.is_empty():
		pointer_chase_accum = maxf(0.0, pointer_chase_accum - delta * 1.5)
		flee_offset = flee_offset.lerp(Vector3.ZERO, clampf(delta * 2.2, 0.0, 1.0))
		return

	var best_perp_dist: float = 999.0
	var best_focal: Vector3 = Vector3.ZERO
	var best_flee_vec: Vector3 = Vector3.ZERO
	var best_src: String = ""
	var best_hand_dist: float = 999.0

	for r in rays:
		var orig: Vector3 = r.get("origin", Vector3.ZERO)
		var dir: Vector3 = (r.get("dir", Vector3.FORWARD) as Vector3).normalized()
		if dir.length_squared() < 0.001:
			continue
		var to_spirit: Vector3 = global_position - orig
		var hand_dist: float = to_spirit.length()
		var t_proj: float = to_spirit.dot(dir)
		if t_proj <= 0.08:
			continue

		var closest_on_ray: Vector3 = orig + dir * t_proj
		var perp: Vector3 = global_position - closest_on_ray
		var p_dist: float = perp.length()
		var focal_depth: float = clampf(t_proj, 0.45, 1.35)
		var focal_pt: Vector3 = orig + dir * focal_depth

		if p_dist < best_perp_dist:
			best_perp_dist = p_dist
			best_focal = focal_pt
			best_hand_dist = hand_dist
			best_src = str(r.get("source", "pointer"))
			if p_dist > 0.004:
				best_flee_vec = perp / p_dist
			else:
				var side_axis: Vector3 = dir.cross(Vector3.UP)
				best_flee_vec = side_axis.normalized() if side_axis.length_squared() > 0.001 else Vector3.UP

	if best_perp_dist < 900.0:
		has_active_pointer = true
		pointer_focal_world = best_focal
		quiet_idle_sec = 0.0
		# 포인터가 켜져 있으면 랜덤 아이들 유영/뒤돌아보기를 즉시 멈추고 정면에서 포인터를 주시!
		if roam_state == RoamState.WANDER_POINT or roam_state == RoamState.LOOK_WITH_USER:
			roam_state = RoamState.ANCHOR_WATCH

		# 손이 직접 닿는 근접 거리(>0.27m) 바깥에서 포인터 선이 정령 근처(0.34m 이내)로 다가오면 도망치듯 회피!
		if best_hand_dist > 0.27 and best_perp_dist < 0.34:
			fleeing_now = true
			var urgency: float = clampf(1.0 - (best_perp_dist / 0.34), 0.0, 1.0)
			var cam_right: Vector3 = cam_tf.basis.x.normalized()
			var juke_vec: Vector3 = (best_flee_vec + cam_right * dodge_side_sign * 0.32 + Vector3(0.0, 0.14 * dodge_side_sign, 0.0)).normalized()

			flee_offset += juke_vec * (1.15 + urgency * 1.95) * delta
			# 너무 멀리 시야 밖으로 사라지지 않도록 홈 반경 0.56m 안쪽에서 통통 튀며 도망
			if flee_offset.length() > 0.56:
				dodge_side_sign = -dodge_side_sign
				flee_offset = flee_offset.limit_length(0.56)
			flee_offset.y = clampf(flee_offset.y, -0.22, 0.30)

			velocity += juke_vec * urgency * 4.6 * delta
			pointer_chase_accum += delta
			if pointer_chase_accum > 0.85 and pointer_chase_signal_cooldown <= 0.0:
				pointer_chase_signal_cooldown = 5.5
				pointer_chase_accum = 0.0
				spirit_chased_by_pointer.emit(best_src)
		else:
			pointer_chase_accum = maxf(0.0, pointer_chase_accum - delta)
			flee_offset = flee_offset.lerp(Vector3.ZERO, clampf(delta * 1.6, 0.0, 1.0))


func ingest_hand_points(named_points: Dictionary, delta: float) -> void:
	# named_points: {"right_index": Vector3, "left_index": Vector3, ...}
	if disperse_signal_cooldown > 0.0:
		disperse_signal_cooldown = maxf(0.0, disperse_signal_cooldown - delta)

	var current_keys: Dictionary = {}
	for key_var: Variant in named_points.keys():
		var k: String = str(key_var)
		current_keys[k] = true
		var pt: Vector3 = named_points[key_var]
		var prev_pt: Vector3 = prev_hand_positions.get(k, pt)
		var seg: Vector3 = pt - prev_pt
		var speed: float = seg.length() / maxf(delta, 0.004)
		prev_hand_positions[k] = pt

		var dist_center: float = pt.distance_to(global_position)
		if dist_center < 0.36:
			quiet_idle_sec = 0.0
			if roam_state == RoamState.WANDER_POINT:
				roam_state = RoamState.ANCHOR_WATCH
				active_goal_pos = home_pos

		# 정령 연기 영역(반경 0.215m) 안을 손이 직접 스쳐 지나갈 때 그 궤적만 갈라지고 흩어졌다가 다시 모임!
		if dist_center < 0.215:
			var move_dir_world: Vector3 = seg.normalized() if seg.length() > 0.002 else (pt - global_position).normalized()
			if move_dir_world.length_squared() < 0.001:
				move_dir_world = Vector3.UP

			var samples: int = clampi(int(ceil(seg.length() / 0.035)), 1, 3)
			for s_i in range(samples):
				var t_lerp: float = float(s_i + 1) / float(samples)
				var sample_world: Vector3 = prev_pt.lerp(pt, t_lerp)
				_inject_local_trail_wake(sample_world, move_dir_world, clampf(speed, 0.25, 2.8))
				if randf() < 0.85:
					_spawn_detached_wisp(sample_world, move_dir_world, clampf(speed, 0.35, 2.6))

			local_recoil_vel += move_dir_world * clampf(speed * 0.08, 0.02, 0.16)
			excited_timer = maxf(excited_timer, 1.15)

			if disperse_signal_cooldown <= 0.0 and speed > 0.10:
				disperse_signal_cooldown = 2.4
				var local_hit: Vector3 = body_pivot.to_local(pt)
				var zone_ko: String = "윗부분 연기 꼬리" if local_hit.y > 0.06 else ("아랫자락 연기" if local_hit.y < -0.05 else "몸통 한가운데")
				spirit_dispersed.emit(k, snappedf(speed, 0.01), zone_ko)

	var stale: Array[String] = []
	for old_k_var: Variant in prev_hand_positions.keys():
		var ok: String = str(old_k_var)
		if not current_keys.has(ok):
			stale.append(ok)
	for sk: String in stale:
		prev_hand_positions.erase(sk)


func _inject_local_trail_wake(world_pt: Vector3, world_dir: Vector3, speed: float) -> void:
	var local_pt: Vector3 = body_pivot.to_local(world_pt)
	var local_dir: Vector3 = (body_pivot.global_transform.basis.inverse() * world_dir).normalized()
	if local_dir.length_squared() < 0.001:
		local_dir = Vector3.UP

	var best_idx: int = 0
	var min_strength: float = 999.0
	for i in range(MAX_TRAIL_SLOTS):
		var slot: Dictionary = trail_slots[i]
		if (slot["local_pos"] as Vector3).distance_to(local_pt) < 0.032 and float(slot["strength"]) > 0.25:
			best_idx = i
			break
		if float(slot["strength"]) < min_strength:
			min_strength = float(slot["strength"])
			best_idx = i

	trail_slots[best_idx] = {
		"local_pos": local_pt,
		"strength": 1.0,
		"local_dir": local_dir,
		"radius": clampf(0.065 + speed * 0.018, 0.065, 0.105)
	}


func _spawn_detached_wisp(world_pt: Vector3, world_dir: Vector3, speed: float) -> void:
	for w: Dictionary in wisp_pool:
		if not bool(w["active"]):
			var radial := Vector3(randf_range(-1.0, 1.0), randf_range(-0.4, 1.1), randf_range(-1.0, 1.0)).normalized()
			var burst_vel: Vector3 = world_dir * clampf(speed * 0.42, 0.18, 0.85) + radial * 0.14 + Vector3(0.0, 0.08, 0.0)
			var mesh: MeshInstance3D = w["mesh"]
			w["active"] = true
			w["age"] = 0.0
			w["lifetime"] = randf_range(0.95, 1.35)
			w["world_pos"] = world_pt
			w["scatter_vel"] = burst_vel
			w["return_local_offset"] = body_pivot.to_local(world_pt) * 0.55
			mesh.global_position = world_pt
			mesh.scale = Vector3.ONE * randf_range(0.75, 1.15)
			mesh.visible = true
			return


func _sync_trail_uniforms() -> void:
	var pos_arr := PackedVector4Array()
	var push_arr := PackedVector4Array()
	pos_arr.resize(MAX_TRAIL_SLOTS)
	push_arr.resize(MAX_TRAIL_SLOTS)

	for i in range(MAX_TRAIL_SLOTS):
		var s: Dictionary = trail_slots[i]
		var lp: Vector3 = s["local_pos"]
		var ld: Vector3 = s["local_dir"]
		pos_arr[i] = Vector4(lp.x, lp.y, lp.z, float(s["strength"]))
		push_arr[i] = Vector4(ld.x, ld.y, ld.z, float(s["radius"]))

	core_mat.set_shader_parameter("trail_pos_strength", pos_arr)
	core_mat.set_shader_parameter("trail_push_radius", push_arr)
	for vm: ShaderMaterial in veil_mats:
		vm.set_shader_parameter("trail_pos_strength", pos_arr)
		vm.set_shader_parameter("trail_push_radius", push_arr)


func tick_spirit(
	delta: float,
	cam_tf: Transform3D,
	closest_hand_world: Variant,
	has_focus: bool
) -> void:
	time_sec += delta
	if excited_timer > 0.0:
		excited_timer = maxf(0.0, excited_timer - delta)
	if indexed_pulse_timer > 0.0:
		indexed_pulse_timer = maxf(0.0, indexed_pulse_timer - delta)
	if mood_override_timer > 0.0:
		mood_override_timer = maxf(0.0, mood_override_timer - delta)
		if mood_override_timer == 0.0:
			mood_override = ""
	if nod_timer > 0.0:
		nod_timer = maxf(0.0, nod_timer - delta)

	# 1) 손 궤적 슬롯 감쇠 -> 흩어진 연기가 원래 자리로 재응집
	for i in range(MAX_TRAIL_SLOTS):
		var st: float = float(trail_slots[i]["strength"])
		if st > 0.0:
			trail_slots[i]["strength"] = maxf(0.0, st - delta * 0.76)
	_sync_trail_uniforms()

	# 2) 포인터가 없을 때만 유휴 랜덤 비행·시선 공유 액션 실행!
	_update_autonomous_roaming(delta, cam_tf, has_focus)

	# 3) 부유 스프링 이동 + 포인터 도망(flee_offset) 결합
	var bob := Vector3(
		sin(time_sec * 1.25) * 0.042,
		sin(time_sec * 2.05) * 0.036,
		cos(time_sec * 1.05) * 0.036
	)
	var desired_pos: Vector3 = active_goal_pos + flee_offset + bob
	var stiffness: float = 8.2 if fleeing_now else (4.2 if roam_state == RoamState.WANDER_POINT else 5.8)
	var spring_acc: Vector3 = (desired_pos - global_position) * stiffness
	velocity = (velocity + spring_acc * delta) * exp(-3.8 * delta)
	local_recoil_vel = local_recoil_vel * exp(-7.5 * delta)
	global_position += (velocity + local_recoil_vel) * delta

	# 4) 정령 몸체 회전
	_update_body_orientation(delta, cam_tf)

	# 5) 눈알: 포인터가 있으면 무조건 포인터를 따라다니고, 포인터가 없을 때만 다른 데 보기/굴리기 랜덤 아이들!
	_update_expressive_eyes(delta, cam_tf, closest_hand_world)

	# 6) 분리된 연기 조각 VFX 파티클 업데이트
	_update_detached_wisps(delta, cam_tf.origin)

	# 7) 불씨 입자 및 감정 색상 그라데이션 업데이트
	_update_motes_and_colors(delta)


func _update_autonomous_roaming(delta: float, cam_tf: Transform3D, has_focus: bool) -> void:
	if has_active_pointer:
		# 포인터가 켜져 있는 동안엔 홈 기준점 + 도망 오프셋만 사용 (랜덤 비행 중단)
		active_goal_pos = home_pos
		quiet_idle_sec = 0.0
		return

	if roam_state != RoamState.ANCHOR_WATCH:
		roam_state_timer -= delta
		if roam_state_timer <= 0.0:
			roam_state = RoamState.ANCHOR_WATCH
			active_goal_pos = home_pos
			next_idle_action_at = randf_range(6.8, 12.0)
			quiet_idle_sec = 0.0
		elif roam_state == RoamState.LOOK_WITH_USER:
			var fwd: Vector3 = -cam_tf.basis.z
			fwd.y = 0.0
			fwd = fwd.normalized() if fwd.length_squared() > 0.001 else Vector3.FORWARD
			var right: Vector3 = fwd.cross(Vector3.UP).normalized()
			active_goal_pos = cam_tf.origin + fwd * 0.88 + right * 0.22 + Vector3(0.0, -0.04, 0.0)
		elif roam_state == RoamState.COME_CLOSER:
			var fwd2: Vector3 = -cam_tf.basis.z
			fwd2.y = 0.0
			fwd2 = fwd2.normalized() if fwd2.length_squared() > 0.001 else Vector3.FORWARD
			var right2: Vector3 = fwd2.cross(Vector3.UP).normalized()
			active_goal_pos = cam_tf.origin + fwd2 * 0.68 + right2 * 0.12 + Vector3(0.0, -0.02, 0.0)
		return

	active_goal_pos = home_pos
	# 2D 다른 앱을 사용 중(has_focus == false)일 때도 정령이 죽지 않고 옆에서 살아서 숨 쉬고 가끔 유영함!
	quiet_idle_sec += delta
	var threshold: float = next_idle_action_at if has_focus else (next_idle_action_at * 1.35)
	if quiet_idle_sec >= threshold and excited_timer <= 0.05 and speaking_energy <= 0.05:
		_start_autonomous_roam_step(false)


func _start_autonomous_roam_step(force_wander: bool) -> void:
	quiet_idle_sec = 0.0
	var roll: float = randf()
	if not force_wander and roll < 0.34:
		roam_state = RoamState.LOOK_WITH_USER
		roam_state_timer = randf_range(3.0, 4.2)
		return

	roam_state = RoamState.WANDER_POINT
	roam_state_timer = randf_range(3.4, 5.0)
	var offset_candidates: Array[Vector3] = [
		Vector3(-0.46, 0.10, -0.05),
		Vector3(0.18, 0.19, 0.08),
		Vector3(-0.28, -0.08, 0.14),
		Vector3(0.24, 0.08, -0.14),
		Vector3(-0.16, 0.22, -0.08)
	]
	active_goal_pos = home_pos + offset_candidates[randi() % offset_candidates.size()]


func _update_body_orientation(delta: float, cam_tf: Transform3D) -> void:
	var forward_target: Vector3 = cam_tf.origin - global_position
	if not has_active_pointer and roam_state == RoamState.LOOK_WITH_USER:
		var user_gaze_dir: Vector3 = -cam_tf.basis.z
		user_gaze_dir.y *= 0.45
		if user_gaze_dir.length_squared() > 0.001:
			forward_target = user_gaze_dir.normalized()
	elif not has_active_pointer and roam_state == RoamState.WANDER_POINT and velocity.length() > 0.14:
		var vel_dir: Vector3 = velocity.normalized()
		var to_user: Vector3 = (cam_tf.origin - global_position).normalized()
		forward_target = vel_dir.lerp(to_user, 0.45)
	else:
		forward_target.y *= 0.35

	if forward_target.length_squared() > 0.001:
		var target_basis: Basis = Basis.looking_at(-forward_target.normalized(), Vector3.UP)
		if fleeing_now:
			# 포인터를 피해 옆으로 휙 도망칠 때 몸체도 살짝 기울며 생동감 연출
			var side_lean: float = clampf(velocity.dot(cam_tf.basis.x) * -22.0, -24.0, 24.0)
			target_basis = target_basis * Basis(Vector3.FORWARD, deg_to_rad(side_lean))
		elif not has_active_pointer and roam_state == RoamState.LOOK_WITH_USER:
			target_basis = target_basis * Basis(Vector3.FORWARD, deg_to_rad(9.5 * sin(time_sec * 1.6)))
		elif nod_timer > 0.0:
			target_basis = target_basis * Basis(Vector3.RIGHT, deg_to_rad(14.0 * sin(nod_timer * 14.0)))

		if roam_state == RoamState.HAPPY_SPIN:
			spin_angle_accum += delta * TAU * 1.25
			target_basis = target_basis * Basis(Vector3.UP, spin_angle_accum)

		body_pivot.global_transform.basis = body_pivot.global_transform.basis.slerp(
			target_basis,
			clampf(delta * (7.2 if fleeing_now else 4.8), 0.0, 1.0)
		)

	var local_vel: Vector3 = body_pivot.global_transform.basis.inverse() * velocity
	var lean := Vector2(clampf(local_vel.x * 1.6, -0.95, 0.95), clampf(local_vel.z * 1.6, -0.95, 0.95))
	core_mat.set_shader_parameter("flight_lean", lean)
	for vm: ShaderMaterial in veil_mats:
		vm.set_shader_parameter("flight_lean", lean)


func _update_expressive_eyes(delta: float, cam_tf: Transform3D, closest_hand_world: Variant) -> void:
	var desired_pupil: Vector2 = Vector2.ZERO

	if has_active_pointer:
		# 포인터가 있을 때: 랜덤 딴청/눈알 굴리기 없이 무조건 포인터 위치를 눈알로 바짝 따라다님!
		eye_roll_phase = -1.0
		pupil_saccade = Vector2.ZERO
		var local_ptr: Vector3 = body_pivot.to_local(pointer_focal_world)
		desired_pupil = Vector2(
			clampf(local_ptr.x / maxf(0.14, absf(local_ptr.z)), -0.82, 0.82),
			clampf(-local_ptr.y / maxf(0.14, absf(local_ptr.z)), -0.72, 0.72)
		).limit_length(0.84)
	else:
		# 포인터가 없을 때만: 다른 데 보기, 눈알 데구르르 굴리기, 사용자 쳐다보기 등 랜덤 아이들 모션!
		saccade_timer -= delta
		if saccade_timer <= 0.0:
			var r: float = randf()
			if r < 0.42:
				pupil_saccade = Vector2.ZERO
				saccade_timer = randf_range(2.2, 4.0)
			elif r < 0.72:
				eye_roll_phase = 0.0
				saccade_timer = randf_range(2.8, 4.5)
			else:
				# 다른 곳 힐끔 보기
				pupil_saccade = Vector2(randf_range(-0.68, 0.68), randf_range(-0.38, 0.56))
				saccade_timer = randf_range(1.0, 2.0)

		if eye_roll_phase >= 0.0:
			eye_roll_phase += delta * 2.3
			if eye_roll_phase >= 1.0:
				eye_roll_phase = -1.0
				pupil_saccade = Vector2.ZERO
			else:
				var ang: float = eye_roll_phase * PI
				pupil_saccade = Vector2(cos(ang) * 0.68, sin(ang) * 0.52)

		var look_world: Vector3 = cam_tf.origin
		if closest_hand_world is Vector3 and (closest_hand_world as Vector3).distance_to(global_position) < 0.36:
			look_world = closest_hand_world as Vector3
		elif roam_state == RoamState.LOOK_WITH_USER:
			look_world = cam_tf.origin - cam_tf.basis.z * 1.6

		var local_target: Vector3 = body_pivot.to_local(look_world)
		var base_pupil := Vector2(
			clampf(local_target.x / maxf(0.18, absf(local_target.z)), -0.65, 0.65),
			clampf(-local_target.y / maxf(0.18, absf(local_target.z)), -0.50, 0.50)
		)
		desired_pupil = (base_pupil + pupil_saccade).limit_length(0.82)

	pupil_current = pupil_current.lerp(desired_pupil, clampf(delta * (14.0 if has_active_pointer else 9.0), 0.0, 1.0))

	# 자연스러운 눈 깜빡임
	blink_timer -= delta
	if blink_timer <= 0.0 and blink_progress < 0.0:
		blink_progress = 0.0
		double_blink_pending = (randf() < 0.24)
		blink_timer = randf_range(2.8, 5.6)

	var blink_val: float = 0.0
	if blink_progress >= 0.0:
		blink_progress += delta * 7.2
		if blink_progress >= 1.0:
			if double_blink_pending:
				double_blink_pending = false
				blink_progress = 0.0
			else:
				blink_progress = -1.0
		else:
			blink_val = sin(blink_progress * PI)

	var squint_val: float = clampf(excited_timer / 1.3, 0.0, 0.85) if not fleeing_now else 0.0
	for emat: ShaderMaterial in [eye_left_mat, eye_right_mat]:
		emat.set_shader_parameter("pupil_offset", pupil_current)
		emat.set_shader_parameter("blink_amount", blink_val)
		emat.set_shader_parameter("happy_squint", squint_val)


func _update_detached_wisps(delta: float, cam_origin: Vector3) -> void:
	for w: Dictionary in wisp_pool:
		if not bool(w["active"]):
			continue
		var age: float = float(w["age"]) + delta
		var life: float = float(w["lifetime"])
		var mesh: MeshInstance3D = w["mesh"]
		var mat: ShaderMaterial = w["mat"]
		if age >= life:
			w["active"] = false
			mesh.visible = false
			continue

		w["age"] = age
		var u: float = age / life
		var wp: Vector3 = w["world_pos"]
		var svel: Vector3 = w["scatter_vel"]
		var home_target: Vector3 = body_pivot.to_global(w["return_local_offset"] as Vector3)

		if u < 0.34:
			wp += svel * delta
			w["scatter_vel"] = svel * exp(-2.8 * delta)
		else:
			var pull_t: float = smoothstep(0.34, 1.0, u)
			wp = wp.lerp(home_target, clampf(delta * (3.5 + pull_t * 9.5), 0.0, 1.0))

		w["world_pos"] = wp
		mesh.global_position = wp

		var to_cam: Vector3 = cam_origin - wp
		to_cam.y = 0.0
		if to_cam.length_squared() > 0.001:
			mesh.global_transform.basis = Basis.looking_at(-to_cam.normalized(), Vector3.UP)

		var alpha_env: float = sin(u * PI) * 0.62
		mat.set_shader_parameter("opacity_scale", alpha_env)


func _update_motes_and_colors(_delta: float) -> void:
	var warm_touch: float = clampf(excited_timer / 1.4, 0.0, 1.0)
	var gold_mem: float = clampf(indexed_pulse_timer / 1.2, 0.0, 1.0)
	var gaze_em: float = clampf(gaze_focus_strength, 0.0, 1.0)
	var speak_boost: float = clampf(speaking_energy, 0.0, 1.0)

	var core_col := Color(0.58, 1.0, 0.86)
	var mid_col := Color(0.26, 0.86, 0.78)
	var mist_col := Color(0.62, 0.82, 0.85)

	if mood_override == "gold" or mood_override == "recommend":
		gold_mem = maxf(gold_mem, 0.85)
	elif mood_override == "playful" or mood_override == "touch":
		warm_touch = maxf(warm_touch, 0.75)
	elif mood_override == "curious":
		gaze_em = maxf(gaze_em, 0.85)

	core_col = core_col.lerp(Color(0.38, 1.0, 0.72), gaze_em * 0.65)
	core_col = core_col.lerp(Color(1.0, 0.90, 0.48), gold_mem * 0.82)
	core_col = core_col.lerp(Color(0.75, 1.0, 0.96), warm_touch * 0.55)

	mid_col = mid_col.lerp(Color(0.95, 0.72, 0.28), gold_mem * 0.75)
	mid_col = mid_col.lerp(Color(0.45, 0.95, 0.92), warm_touch * 0.60)

	var glow: float = 1.22 + speak_boost * 0.42 + warm_touch * 0.25 + gold_mem * 0.28 + (0.22 if fleeing_now else 0.0)
	core_mat.set_shader_parameter("core_color", Vector3(core_col.r, core_col.g, core_col.b))
	core_mat.set_shader_parameter("mid_color", Vector3(mid_col.r, mid_col.g, mid_col.b))
	core_mat.set_shader_parameter("mist_color", Vector3(mist_col.r, mist_col.g, mist_col.b))
	core_mat.set_shader_parameter("glow_boost", glow)

	for vm: ShaderMaterial in veil_mats:
		vm.set_shader_parameter("veil_color", Vector3(mist_col.r, mist_col.g, mist_col.b))
		vm.set_shader_parameter("accent_color", Vector3(core_col.r, core_col.g, core_col.b))

	for m: Dictionary in mote_items:
		var mi: MeshInstance3D = m["mesh"]
		var ph: float = float(m["phase"]) + time_sec * float(m["speed"])
		var rad: float = float(m["radius"])
		var by: float = float(m["base_y"]) + fmod(time_sec * 0.055 + float(m["phase"]) * 0.03, 0.24) - 0.08
		mi.position = Vector3(cos(ph) * rad, by, sin(ph * 1.13) * rad * 0.82)
		var twinkle: float = 0.35 + 0.60 * (0.5 + 0.5 * sin(ph * 2.7))
		(m["mat"] as StandardMaterial3D).albedo_color = Color(core_col.r, core_col.g, core_col.b, twinkle)
