extends Node3D

const MemoryEngineScript = preload("res://scripts/memory_engine.gd")
const SmokeSpiritScript = preload("res://scripts/smoke_spirit_actor.gd")
const CompanionAgentScript = preload("res://scripts/companion_agent.gd")

const BBOX_PLANE_Z: float = -0.95
const RUNE_COOLDOWN_SEC: float = 0.55

var xr_interface: OpenXRInterface
var has_input_focus: bool = true
var desktop_mode: bool = false
var cam_plugin: Object = null
var kr_font: Font = null

var memory_engine = null
var companion_agent = null
var spirit = null

@onready var xr_origin: XROrigin3D = $XROrigin3D
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var left_hand: XRController3D = $XROrigin3D/LeftHand
@onready var right_hand: XRController3D = $XROrigin3D/RightHand

var home_pos: Vector3 = Vector3(0.30, 1.44, -0.92)
var initialized_anchor: bool = false
var time_sec: float = 0.0

# 맨손(OpenXR 26관절 XRHandTracker + RGB 카메라 MediaPipe 손 인식 + 컨트롤러) 시각화·입력
var bare_hand_joints_left: Array[MeshInstance3D] = []
var bare_hand_joints_right: Array[MeshInstance3D] = []
var rgb_hand_orb: MeshInstance3D
var ctrl_left_dot: MeshInstance3D
var ctrl_right_dot: MeshInstance3D
var pointer_beam_left: MeshInstance3D
var pointer_beam_right: MeshInstance3D

var left_pinch_prev: bool = false
var right_pinch_prev: bool = false
var rgb_pinch_prev: bool = false
var openxr_bare_left_active: bool = false
var openxr_bare_right_active: bool = false
var rgb_hand_active: bool = false
var y_hold_timer: float = -1.0

# 공간 룬 독 (A 시선 / B 기억 / X 모드 / Y 대화 / ⚙ 설정) — 홈 기준 고정으로 도망 중에도 터치 안정성 확보
var spirit_runes_root: Node3D
var rune_items: Array[Dictionary] = []
var rune_cooldown: float = 0.0

# 모드 전환·안내 토스트
var toast_root: Node3D
var toast_label: Label3D
var toast_timer: float = 0.0

# 공간 대화 요약 카드 (show_dialogue_card 툴 전용)
var dialogue_card_root: Node3D
var dialogue_title_label: Label3D
var dialogue_body_label: Label3D
var dialogue_close_btn: Node3D

# 대조형 딱 2선 상품 추천 카드 (show_recommendation_card 툴 전용 + 2D 브라우저 검색 연동)
var rec_card_root: Node3D
var rec_header_label: Label3D
var rec_talk_label: Label3D
var rec_prod1_label: Label3D
var rec_prod2_label: Label3D
var rec_crop_mesh: MeshInstance3D
var rec_crop_mat: StandardMaterial3D
var rec_buttons: Array[Dictionary] = []
var rec_item1_query: String = ""
var rec_item2_query: String = ""

# 디버그 오버레이: A(시선 중심 ROI + 실시간 BBox), B(메모리 & 하이브리드 검색 & 세션 X-Ray)
var show_vision_bbox: bool = false
var show_memory_xray: bool = false
var proactive_mode: bool = true

var debug_vision_overlay: Node3D
var roi_ring_mesh: MeshInstance3D
var obj_bbox_slots: Array[Dictionary] = []
var hand_bbox_slots: Array[Dictionary] = []

var debug_memory_panel: Node3D
var xray_text_label: Label3D
var xray_crop_mesh: MeshInstance3D
var xray_crop_mat: StandardMaterial3D

var vision_poll_timer: float = 0.0
var latest_vision_state: Dictionary = {}
var latest_auth_voice_state: Dictionary = {}
var last_crop_loaded_path: String = ""

const JOINT_INDICES: Array[int] = [
	XRHandTracker.HAND_JOINT_PALM,
	XRHandTracker.HAND_JOINT_THUMB_TIP,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
	XRHandTracker.HAND_JOINT_RING_FINGER_TIP,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP
]


func _load_korean_font() -> void:
	var candidates: Array[String] = [
		"/system/fonts/NotoSansCJK-Regular.ttc",
		"/System/Library/Fonts/Supplemental/AppleGothic.ttf"
	]
	for p: String in candidates:
		if FileAccess.file_exists(p):
			var f := FontFile.new()
			if f.load_dynamic_font(p) == OK:
				kr_font = f
				print("[Wisp] Loaded Korean font: ", p)
				return
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Noto Sans CJK KR", "Apple SD Gothic Neo", "sans-serif"])
	kr_font = sf


func _ready() -> void:
	_load_korean_font()

	memory_engine = MemoryEngineScript.new()
	memory_engine.name = "CompanionMemoryEngine"
	add_child(memory_engine)
	memory_engine.memory_indexed.connect(_on_memory_indexed)
	memory_engine.memory_upgraded.connect(_on_memory_upgraded)
	memory_engine.hybrid_search_completed.connect(_on_hybrid_search_completed)

	companion_agent = CompanionAgentScript.new()
	companion_agent.name = "CompanionAgentRuntime"
	add_child(companion_agent)
	companion_agent.dialogue_card_requested.connect(_on_dialogue_card_requested)
	companion_agent.recommendation_card_requested.connect(_on_recommendation_card_requested)
	companion_agent.spirit_action_requested.connect(_on_spirit_action_requested)
	companion_agent.assistant_replied.connect(_on_assistant_replied)
	companion_agent.agent_status_changed.connect(_on_agent_status_changed)
	companion_agent.auth_required_prompt.connect(_on_auth_required_prompt)

	_setup_environment()
	_build_smoke_spirit()
	_build_spirit_spatial_runes()
	_build_toast_ui()
	_build_dialogue_card()
	_build_recommendation_card()
	_build_debug_overlays()
	_build_hand_and_pointer_visualizers()
	_init_openxr()
	_init_camera_plugin()
	companion_agent.setup(memory_engine, cam_plugin, func() -> Dictionary: return latest_vision_state)
	_wire_controller_buttons()
	_refresh_xray_panel()


func _make_label(font_sz: int, px_size: float = 0.00105, prio: int = 3) -> Label3D:
	var lbl := Label3D.new()
	if kr_font != null:
		lbl.font = kr_font
	lbl.font_size = font_sz
	lbl.pixel_size = px_size
	lbl.outline_size = 5
	lbl.render_priority = prio
	return lbl


func _make_panel_bg(w: float, h: float, col: Color, prio: int = -4) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(w, h)
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = prio
	mi.material_override = m
	return mi


func _make_wire_box_2d(w: float, h: float, thickness: float, col: Color, prio: int = 1) -> Dictionary:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = prio

	var top := MeshInstance3D.new()
	var bottom := MeshInstance3D.new()
	var left_bar := MeshInstance3D.new()
	var right_bar := MeshInstance3D.new()
	for bar: MeshInstance3D in [top, bottom, left_bar, right_bar]:
		var q := QuadMesh.new()
		q.size = Vector2(1.0, 1.0)
		bar.mesh = q
		bar.material_override = mat
		root.add_child(bar)

	var lbl := _make_label(18, 0.0010, prio + 2)
	lbl.modulate = col.lightened(0.25)
	lbl.position = Vector3(0.0, h * 0.5 + 0.025, 0.005)
	root.add_child(lbl)

	var slot: Dictionary = {
		"root": root,
		"mat": mat,
		"top": top,
		"bottom": bottom,
		"left": left_bar,
		"right": right_bar,
		"label": lbl,
		"thickness": thickness
	}
	_resize_wire_box(slot, w, h)
	return slot


func _resize_wire_box(slot: Dictionary, w: float, h: float) -> void:
	var t: float = float(slot["thickness"])
	var top: MeshInstance3D = slot["top"]
	var bottom: MeshInstance3D = slot["bottom"]
	var left_bar: MeshInstance3D = slot["left"]
	var right_bar: MeshInstance3D = slot["right"]
	var lbl: Label3D = slot["label"]

	top.scale = Vector3(w, t, 1.0)
	top.position = Vector3(0.0, h * 0.5, 0.0)
	bottom.scale = Vector3(w, t, 1.0)
	bottom.position = Vector3(0.0, -h * 0.5, 0.0)
	left_bar.scale = Vector3(t, h, 1.0)
	left_bar.position = Vector3(-w * 0.5, 0.0, 0.0)
	right_bar.scale = Vector3(t, h, 1.0)
	right_bar.position = Vector3(w * 0.5, 0.0, 0.0)
	lbl.position = Vector3(0.0, h * 0.5 + 0.028, 0.006)


func _wire_controller_buttons() -> void:
	right_hand.button_pressed.connect(_on_right_button_pressed)
	left_hand.button_pressed.connect(_on_left_button_pressed)
	left_hand.button_released.connect(_on_left_button_released)


func _on_right_button_pressed(btn_name: String) -> void:
	if btn_name == "ax_button":
		_action_toggle_vision_bbox()
	elif btn_name == "by_button":
		_action_toggle_memory_xray()


func _on_left_button_pressed(btn_name: String) -> void:
	if btn_name == "ax_button":
		_action_toggle_demo_mode()
	elif btn_name == "by_button":
		y_hold_timer = 0.0
	elif btn_name == "menu_button":
		_action_open_setup_browser()


func _on_left_button_released(btn_name: String) -> void:
	if btn_name == "by_button":
		if y_hold_timer >= 0.0 and y_hold_timer < 1.1:
			_action_trigger_query("컨트롤러 Y")
		y_hold_timer = -1.0


func _action_toggle_vision_bbox() -> void:
	show_vision_bbox = not show_vision_bbox
	debug_vision_overlay.visible = show_vision_bbox
	_speak_or_chime("", "pinch")
	_show_toast("시선 중심 & BBox 오버레이: " + ("ON" if show_vision_bbox else "OFF"), 1.5)
	_update_rune_highlights()


func _action_toggle_memory_xray() -> void:
	show_memory_xray = not show_memory_xray
	debug_memory_panel.visible = show_memory_xray
	_refresh_xray_panel()
	_speak_or_chime("", "pinch")
	_show_toast("메모리 & 하이브리드 검색 X-Ray: " + ("ON" if show_memory_xray else "OFF"), 1.5)
	_update_rune_highlights()


func _action_toggle_demo_mode() -> void:
	proactive_mode = not proactive_mode
	var txt: String = "모드 1: 시선 포착 즉시 능동 제안" if proactive_mode else "모드 2: 물어봤을 때만 기억 검색 후 제안"
	_speak_or_chime("", "mode")
	_show_toast(txt, 1.9)
	_refresh_xray_panel()
	_update_rune_highlights()


func _action_open_setup_browser() -> void:
	_speak_or_chime("", "pinch")
	if cam_plugin != null:
		cam_plugin.call("openSetupBrowser")
		_show_toast("2D 브라우저에서 Wisp 로그인·설정 창을 열었어!", 2.2)
	else:
		_show_toast("퀘스트 기기에서 http://localhost:1455/setup 창이 열려", 2.0)


func _action_trigger_query(source_tag: String) -> void:
	spirit.notify_user_or_agent_activity()
	spirit.trigger_named_action("nod", "warm")
	_speak_or_chime("", "pinch")

	if not companion_agent.has_configured_auth():
		_show_toast("먼저 ⚙ 설정 룬을 눌러 로그인/API 키를 연결해줘!", 2.4)
		_action_open_setup_browser()
		return

	if memory_engine.memories.size() > 0:
		var latest: Dictionary = memory_engine.memories[0]
		var crop_p: String = str(latest.get("crop_path", ""))
		companion_agent.request_user_turn(
			"[%s 요청] 내가 지금까지 유심히 본 사물 기억들을 vector_search와 keyword_search로 둘 다 찾아보고, 가장 잘 맞는 대조형 추천 딱 2가지를 show_recommendation_card로 띄워 설명해줘." % source_tag,
			crop_p
		)
	else:
		companion_agent.request_user_turn(
			"[%s 요청] inspect_current_gaze로 지금 내 눈앞 시선 중심에 무엇이 보이는지 확인하고, 상황에 맞는 이야기나 추천을 들려줘." % source_tag
		)


func _action_reset_demo() -> void:
	memory_engine.reset_live_memories()
	companion_agent.reset_conversation()
	if cam_plugin != null:
		cam_plugin.call("resetVisionSession")
	rec_card_root.visible = false
	dialogue_card_root.visible = false
	_reanchor_near_user()
	_speak_or_chime("", "mode")
	_show_toast("실시간 기억과 대화 세션을 초기화했어", 1.8)
	_refresh_xray_panel()


func _speak_or_chime(tts_line: String, mood: String) -> void:
	if cam_plugin != null:
		cam_plugin.call("speakOrChime", tts_line, mood)


func _show_toast(msg: String, duration: float = 1.6) -> void:
	if toast_label == null:
		return
	toast_label.text = msg
	toast_root.visible = true
	toast_timer = duration


func _init_camera_plugin() -> void:
	if Engine.has_singleton("QuestCameraPlugin"):
		cam_plugin = Engine.get_singleton("QuestCameraPlugin")
		var init_state: String = str(cam_plugin.call("startCamera"))
		print("[Wisp] QuestCameraPlugin connected: ", init_state)
	else:
		print("[Wisp] QuestCameraPlugin singleton not present (desktop preview).")


func _setup_environment() -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.86, 0.92, 1.0)
	env.ambient_light_energy = 0.88
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
	sun.light_energy = 1.15
	add_child(sun)


func _init_openxr() -> void:
	xr_interface = XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr_interface and xr_interface.is_initialized():
		var vp: Viewport = get_viewport()
		vp.use_xr = true
		vp.transparent_bg = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

		var modes: Array = xr_interface.get_supported_environment_blend_modes()
		if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes:
			xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND

		xr_interface.session_begun.connect(_on_session_begun)
		xr_interface.session_stopping.connect(_on_session_stopping)
		xr_interface.session_focussed.connect(_on_session_focussed)
		xr_interface.session_visible.connect(_on_session_visible)
		xr_interface.pose_recentered.connect(_reanchor_near_user)
	else:
		desktop_mode = true
		get_viewport().transparent_bg = false


func _on_session_begun() -> void:
	var rate: float = xr_interface.get_display_refresh_rate()
	if rate > 0.0:
		Engine.physics_ticks_per_second = int(roundf(rate))
	_reanchor_near_user()
	get_tree().create_timer(0.6).timeout.connect(func() -> void:
		if cam_plugin != null:
			cam_plugin.call("setXrActive", true)
	)


func _on_session_stopping() -> void:
	if cam_plugin != null:
		cam_plugin.call("setXrActive", false)


func _on_session_focussed() -> void:
	has_input_focus = true
	if spirit != null and not companion_agent.is_busy:
		spirit.status_label.text = "함께 보고 있어"


func _on_session_visible() -> void:
	# Horizon OS Seamless Multitasking: 2D 앱 창을 조작 중일 때도 정령은 옆에서 살아서 공존!
	has_input_focus = false
	if spirit != null and not companion_agent.is_busy:
		spirit.status_label.text = "2D 창 옆에서 함께 보는 중"


func _reanchor_near_user() -> void:
	var cam_tf: Transform3D = xr_camera.global_transform
	var forward: Vector3 = -cam_tf.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() >= 0.001 else Vector3.FORWARD
	var right: Vector3 = forward.cross(Vector3.UP).normalized()

	home_pos = cam_tf.origin + forward * 0.90 + right * 0.30 + Vector3(0.0, -0.05, 0.0)
	if spirit != null:
		spirit.home_pos = home_pos
		spirit.active_goal_pos = home_pos
		spirit.global_position = home_pos

	spirit_runes_root.global_position = home_pos + Vector3(0.0, -0.23, 0.03)
	_face_horizontal(spirit_runes_root, cam_tf.origin)

	dialogue_card_root.global_position = cam_tf.origin + forward * 0.92 + right * 0.02 + Vector3(0.0, 0.16, 0.0)
	_face_horizontal(dialogue_card_root, cam_tf.origin)

	rec_card_root.global_position = cam_tf.origin + forward * 0.96 - right * 0.22 + Vector3(0.0, -0.05, 0.0)
	_face_horizontal(rec_card_root, cam_tf.origin)

	debug_memory_panel.global_position = cam_tf.origin + forward * 1.04 - right * 0.24 + Vector3(0.0, 0.28, 0.0)
	_face_horizontal(debug_memory_panel, cam_tf.origin)

	initialized_anchor = true


func _face_horizontal(node: Node3D, target_world: Vector3) -> void:
	var dir: Vector3 = target_world - node.global_position
	dir.y = 0.0
	if dir.length_squared() > 0.001:
		node.global_transform.basis = Basis.looking_at(-dir.normalized(), Vector3.UP)


func _build_smoke_spirit() -> void:
	spirit = SmokeSpiritScript.new()
	spirit.name = "SmokeSpiritActor"
	add_child(spirit)
	spirit.setup(kr_font, home_pos)
	spirit.spirit_dispersed.connect(_on_spirit_dispersed)
	spirit.spirit_chased_by_pointer.connect(_on_spirit_chased_by_pointer)


func _on_spirit_dispersed(hand_tag: String, speed_mps: float, zone_ko: String) -> void:
	_speak_or_chime("", "touch")
	if not companion_agent.is_busy:
		spirit.status_label.text = "%s 연기가 손결 따라 흩어졌어" % zone_ko
	companion_agent.inject_sensory_event(
		"hand_smoke_dispersal",
		"사용자가 맨손(%s, 속도 %.2fm/s)으로 너의 %s를 스쳐 지나가며 연기가 결대로 흩어졌다가 다시 모였어." % [hand_tag, speed_mps, zone_ko],
		"",
		false,
		true
	)


func _on_spirit_chased_by_pointer(pointer_source: String) -> void:
	_speak_or_chime("", "pinch")
	if not companion_agent.is_busy:
		spirit.status_label.text = "포인터 광선 피하는 중!"
	companion_agent.inject_sensory_event(
		"pointer_ray_chase",
		"사용자가 %s 포인터 광선을 네 쪽으로 비추며 쫓아와서, 네가 눈동자로 광선을 따라보며 통통 피해 도망쳤어." % pointer_source,
		"",
		false,
		true
	)


func _build_spirit_spatial_runes() -> void:
	spirit_runes_root = Node3D.new()
	spirit_runes_root.name = "SpiritSpatialRunes"
	spirit_runes_root.position = home_pos + Vector3(0.0, -0.23, 0.03)
	add_child(spirit_runes_root)

	var defs: Array[Dictionary] = [
		{"key": "A", "label": "A 시선", "offset": Vector3(-0.172, 0.0, 0.0), "col": Color(0.20, 0.78, 0.55, 0.44)},
		{"key": "B", "label": "B 기억", "offset": Vector3(-0.086, 0.0, 0.0), "col": Color(0.52, 0.42, 0.92, 0.44)},
		{"key": "X", "label": "X 모드", "offset": Vector3(0.0, 0.0, 0.0), "col": Color(0.22, 0.62, 0.92, 0.44)},
		{"key": "Y", "label": "Y 대화", "offset": Vector3(0.086, 0.0, 0.0), "col": Color(0.95, 0.55, 0.32, 0.50)},
		{"key": "S", "label": "⚙ 설정", "offset": Vector3(0.172, 0.0, 0.0), "col": Color(0.24, 0.82, 0.88, 0.52)}
	]
	for d: Dictionary in defs:
		var holder := Node3D.new()
		holder.position = d["offset"]
		spirit_runes_root.add_child(holder)

		var pill := _make_panel_bg(0.076, 0.036, d["col"], -1)
		holder.add_child(pill)

		var lbl := _make_label(14, 0.00092, 4)
		lbl.text = str(d["label"])
		lbl.position = Vector3(0.0, 0.0, 0.008)
		holder.add_child(lbl)

		rune_items.append({
			"key": str(d["key"]),
			"holder": holder,
			"pill": pill,
			"mat": pill.material_override as StandardMaterial3D,
			"base_col": d["col"]
		})


func _update_rune_highlights(hand_near: bool = false) -> void:
	var authed: bool = companion_agent.has_configured_auth() if companion_agent != null else false
	for r: Dictionary in rune_items:
		var key: String = str(r["key"])
		var mat: StandardMaterial3D = r["mat"]
		var base_col: Color = r["base_col"]
		var active_on: bool = (
			(key == "A" and show_vision_bbox)
			or (key == "B" and show_memory_xray)
			or (key == "X" and proactive_mode)
			or (key == "S" and authed)
		)
		var alpha: float = 0.88 if hand_near else (0.64 if active_on else 0.32)
		var c: Color = base_col.lightened(0.22 if active_on else 0.0)
		c.a = alpha
		mat.albedo_color = c


func _build_toast_ui() -> void:
	toast_root = Node3D.new()
	toast_root.visible = false
	toast_root.position = Vector3(0.0, -0.22, -0.82)
	xr_camera.add_child(toast_root)

	var bg := _make_panel_bg(0.48, 0.058, Color(0.05, 0.09, 0.16, 0.88), 2)
	toast_root.add_child(bg)

	toast_label = _make_label(17, 0.00098, 5)
	toast_label.position = Vector3(0.0, 0.0, 0.008)
	toast_root.add_child(toast_label)


func _build_dialogue_card() -> void:
	dialogue_card_root = Node3D.new()
	dialogue_card_root.name = "DialogueCard"
	dialogue_card_root.visible = false
	dialogue_card_root.position = Vector3(0.02, 1.56, -0.92)
	add_child(dialogue_card_root)

	var bg := _make_panel_bg(0.42, 0.19, Color(0.05, 0.09, 0.16, 0.86), -4)
	dialogue_card_root.add_child(bg)

	var hdr := _make_panel_bg(0.42, 0.038, Color(0.16, 0.56, 0.68, 0.92), -2)
	hdr.position = Vector3(0.0, 0.076, 0.006)
	dialogue_card_root.add_child(hdr)

	dialogue_title_label = _make_label(16, 0.00094, 3)
	dialogue_title_label.text = "위습의 공간 메모"
	dialogue_title_label.position = Vector3(-0.02, 0.076, 0.012)
	dialogue_card_root.add_child(dialogue_title_label)

	dialogue_body_label = _make_label(15, 0.00092, 3)
	dialogue_body_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	dialogue_body_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	dialogue_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialogue_body_label.width = 410.0
	dialogue_body_label.position = Vector3(-0.19, 0.044, 0.012)
	dialogue_card_root.add_child(dialogue_body_label)

	dialogue_close_btn = Node3D.new()
	dialogue_close_btn.position = Vector3(0.165, 0.076, 0.012)
	dialogue_card_root.add_child(dialogue_close_btn)
	var cbg := _make_panel_bg(0.058, 0.028, Color(0.38, 0.22, 0.30, 0.90), -1)
	dialogue_close_btn.add_child(cbg)
	var clbl := _make_label(13, 0.00088, 4)
	clbl.text = "닫기"
	clbl.position = Vector3(0.0, 0.0, 0.005)
	dialogue_close_btn.add_child(clbl)


func _build_recommendation_card() -> void:
	rec_card_root = Node3D.new()
	rec_card_root.name = "RecommendationCard2"
	rec_card_root.visible = false
	rec_card_root.position = Vector3(-0.22, 1.38, -0.96)
	add_child(rec_card_root)

	var bg := _make_panel_bg(0.50, 0.35, Color(0.05, 0.08, 0.14, 0.88), -4)
	rec_card_root.add_child(bg)

	var header := _make_panel_bg(0.50, 0.044, Color(0.14, 0.48, 0.68, 0.92), -2)
	header.position = Vector3(0.0, 0.153, 0.006)
	rec_card_root.add_child(header)

	rec_header_label = _make_label(17, 0.00096, 3)
	rec_header_label.text = "시선 기억 기반 대조 추천 (딱 2선)"
	rec_header_label.position = Vector3(0.0, 0.153, 0.012)
	rec_card_root.add_child(rec_header_label)

	rec_crop_mesh = MeshInstance3D.new()
	var cq := QuadMesh.new()
	cq.size = Vector2(0.082, 0.068)
	rec_crop_mesh.mesh = cq
	rec_crop_mat = StandardMaterial3D.new()
	rec_crop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rec_crop_mat.albedo_color = Color(0.22, 0.28, 0.36)
	rec_crop_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	rec_crop_mat.render_priority = -1
	rec_crop_mesh.material_override = rec_crop_mat
	rec_crop_mesh.position = Vector3(-0.190, 0.086, 0.010)
	rec_card_root.add_child(rec_crop_mesh)

	rec_talk_label = _make_label(14, 0.00090, 3)
	rec_talk_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	rec_talk_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	rec_talk_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rec_talk_label.width = 365.0
	rec_talk_label.position = Vector3(-0.136, 0.118, 0.012)
	rec_card_root.add_child(rec_talk_label)

	var slot1_bg := _make_panel_bg(0.46, 0.068, Color(0.10, 0.18, 0.28, 0.88), -2)
	slot1_bg.position = Vector3(0.0, 0.004, 0.006)
	rec_card_root.add_child(slot1_bg)

	rec_prod1_label = _make_label(14, 0.00090, 3)
	rec_prod1_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	rec_prod1_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	rec_prod1_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rec_prod1_label.width = 470.0
	rec_prod1_label.position = Vector3(-0.215, 0.032, 0.012)
	rec_card_root.add_child(rec_prod1_label)

	var slot2_bg := _make_panel_bg(0.46, 0.068, Color(0.10, 0.16, 0.24, 0.88), -2)
	slot2_bg.position = Vector3(0.0, -0.074, 0.006)
	rec_card_root.add_child(slot2_bg)

	rec_prod2_label = _make_label(14, 0.00090, 3)
	rec_prod2_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	rec_prod2_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	rec_prod2_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rec_prod2_label.width = 470.0
	rec_prod2_label.position = Vector3(-0.215, -0.046, 0.012)
	rec_card_root.add_child(rec_prod2_label)

	var btn_defs: Array[Dictionary] = [
		{"id": "web1", "txt": "1번 2D웹검색", "x": -0.145, "col": Color(0.16, 0.58, 0.50, 0.90)},
		{"id": "web2", "txt": "2번 2D웹검색", "x": 0.0, "col": Color(0.18, 0.48, 0.74, 0.90)},
		{"id": "close", "txt": "닫기", "x": 0.145, "col": Color(0.38, 0.25, 0.32, 0.90)}
	]
	for bd: Dictionary in btn_defs:
		var b_node := Node3D.new()
		b_node.position = Vector3(float(bd["x"]), -0.140, 0.010)
		rec_card_root.add_child(b_node)
		var b_bg := _make_panel_bg(0.122, 0.034, bd["col"], -1)
		b_node.add_child(b_bg)
		var b_lbl := _make_label(14, 0.00088, 4)
		b_lbl.text = str(bd["txt"])
		b_lbl.position = Vector3(0.0, 0.0, 0.006)
		b_node.add_child(b_lbl)
		rec_buttons.append({"id": str(bd["id"]), "node": b_node})


func _build_debug_overlays() -> void:
	debug_vision_overlay = Node3D.new()
	debug_vision_overlay.name = "DebugVisionOverlay"
	debug_vision_overlay.visible = false
	xr_camera.add_child(debug_vision_overlay)

	roi_ring_mesh = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.285
	torus.outer_radius = 0.294
	roi_ring_mesh.mesh = torus
	roi_ring_mesh.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	roi_ring_mesh.position = Vector3(-0.025, 0.0, BBOX_PLANE_Z)
	var roi_mat := StandardMaterial3D.new()
	roi_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	roi_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	roi_mat.albedo_color = Color(0.28, 1.0, 0.68, 0.58)
	roi_ring_mesh.material_override = roi_mat
	debug_vision_overlay.add_child(roi_ring_mesh)

	var roi_caption := _make_label(15, 0.00095, 3)
	roi_caption.text = "Center ROI (무안구추적 시선 중심 영역)"
	roi_caption.modulate = Color(0.45, 1.0, 0.78, 0.85)
	roi_caption.position = Vector3(-0.025, -0.32, BBOX_PLANE_Z)
	debug_vision_overlay.add_child(roi_caption)

	for i in range(4):
		var slot: Dictionary = _make_wire_box_2d(0.20, 0.16, 0.006, Color(0.25, 0.95, 0.62, 0.88), 2)
		(slot["root"] as Node3D).visible = false
		debug_vision_overlay.add_child(slot["root"] as Node3D)
		obj_bbox_slots.append(slot)

	for i in range(2):
		var hslot: Dictionary = _make_wire_box_2d(0.18, 0.18, 0.006, Color(0.35, 0.82, 1.0, 0.90), 3)
		(hslot["root"] as Node3D).visible = false
		debug_vision_overlay.add_child(hslot["root"] as Node3D)
		hand_bbox_slots.append(hslot)

	debug_memory_panel = Node3D.new()
	debug_memory_panel.name = "DebugMemoryXRayPanel"
	debug_memory_panel.visible = false
	debug_memory_panel.position = Vector3(-0.24, 1.70, -1.04)
	add_child(debug_memory_panel)

	var mem_bg := _make_panel_bg(0.66, 0.39, Color(0.06, 0.05, 0.14, 0.90), -4)
	debug_memory_panel.add_child(mem_bg)

	var mem_hdr := _make_panel_bg(0.66, 0.042, Color(0.36, 0.24, 0.68, 0.92), -2)
	mem_hdr.position = Vector3(0.0, 0.174, 0.006)
	debug_memory_panel.add_child(mem_hdr)

	var mem_title := _make_label(16, 0.00094, 3)
	mem_title.text = "[X-RAY] 실시간 기억 승격 · 하이브리드 검색 · 단독 세션 상태"
	mem_title.position = Vector3(0.0, 0.174, 0.012)
	debug_memory_panel.add_child(mem_title)

	xray_crop_mesh = MeshInstance3D.new()
	var xq := QuadMesh.new()
	xq.size = Vector2(0.095, 0.078)
	xray_crop_mesh.mesh = xq
	xray_crop_mat = StandardMaterial3D.new()
	xray_crop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	xray_crop_mat.albedo_color = Color(0.20, 0.22, 0.30)
	xray_crop_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	xray_crop_mat.render_priority = -1
	xray_crop_mesh.material_override = xray_crop_mat
	xray_crop_mesh.position = Vector3(-0.265, 0.098, 0.010)
	debug_memory_panel.add_child(xray_crop_mesh)

	xray_text_label = _make_label(14, 0.00088, 3)
	xray_text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	xray_text_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	xray_text_label.position = Vector3(-0.205, 0.140, 0.012)
	debug_memory_panel.add_child(xray_text_label)


func _build_hand_and_pointer_visualizers() -> void:
	for i in range(JOINT_INDICES.size()):
		var radius: float = 0.015 if i == 0 else 0.0095
		var jl := _make_joint_orb(radius, Color(0.35, 1.0, 0.85, 0.68))
		jl.visible = false
		add_child(jl)
		bare_hand_joints_left.append(jl)

		var jr := _make_joint_orb(radius, Color(0.35, 1.0, 0.85, 0.68))
		jr.visible = false
		add_child(jr)
		bare_hand_joints_right.append(jr)

	rgb_hand_orb = _make_joint_orb(0.016, Color(0.72, 0.52, 1.0, 0.72))
	rgb_hand_orb.visible = false
	add_child(rgb_hand_orb)

	ctrl_left_dot = _make_joint_orb(0.012, Color(0.5, 0.9, 1.0, 0.45))
	left_hand.add_child(ctrl_left_dot)
	ctrl_right_dot = _make_joint_orb(0.012, Color(0.5, 0.9, 1.0, 0.45))
	right_hand.add_child(ctrl_right_dot)

	pointer_beam_left = _make_pointer_beam_mesh()
	add_child(pointer_beam_left)
	pointer_beam_right = _make_pointer_beam_mesh()
	add_child(pointer_beam_right)


func _make_pointer_beam_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.0022
	cyl.bottom_radius = 0.0032
	cyl.height = 1.0
	cyl.radial_segments = 8
	mi.mesh = cyl
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.42, 0.94, 1.0, 0.46)
	m.render_priority = 3
	mi.material_override = m
	mi.visible = false
	return mi


func _update_beam_visual(beam: MeshInstance3D, origin: Vector3, dir: Vector3, length_m: float) -> void:
	var n_dir: Vector3 = dir.normalized()
	if n_dir.length_squared() < 0.001:
		beam.visible = false
		return
	var mid: Vector3 = origin + n_dir * (length_m * 0.5)
	var up_ref: Vector3 = Vector3.FORWARD if absf(n_dir.dot(Vector3.UP)) > 0.96 else Vector3.UP
	var z_axis: Vector3 = n_dir.cross(up_ref).normalized()
	var x_axis: Vector3 = n_dir.cross(z_axis).normalized()
	beam.global_transform = Transform3D(Basis(x_axis, n_dir * length_m, z_axis), mid)
	beam.visible = true


func _make_joint_orb(radius: float, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0
	mi.mesh = s
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.render_priority = 4
	mi.material_override = m
	return mi


func _on_memory_indexed(record: Dictionary) -> void:
	spirit.indexed_pulse_timer = 1.3
	var crop_p: String = str(record.get("crop_path", ""))
	if crop_p != "":
		_update_crop_textures(crop_p)

	var label_ko: String = str(record.get("label_ko", "관심 사물"))
	var tone_ko: String = str(record.get("color_tone", ""))
	var mem_id: String = str(record.get("id", ""))

	if proactive_mode:
		_speak_or_chime("", "capture")
		if companion_agent.has_configured_auth():
			companion_agent.inject_sensory_event(
				"gaze_interest_promoted",
				"사용자가 시선 중심에 두고 유심히 바라본 %s(%s) 사물이 중기 기억(%s)에 저장됐어. vector_search와 keyword_search로 관련 기억을 조회하고, 어울리는 대조형 추천 딱 2가지를 show_recommendation_card로 띄워 짧게 이야기해줘." % [label_ko, tone_ko, mem_id],
				crop_p,
				true,
				false
			)
		else:
			spirit.status_label.text = "중기 기억 저장됨 (%s · %s)" % [mem_id, label_ko]
			_show_toast("시선 기억(%s) 저장 완료 · ⚙ 설정에서 세션 연결 가능" % mem_id, 2.2)
	else:
		_speak_or_chime("", "capture")
		spirit.status_label.text = "기억해 뒀어 (%s %s)" % [mem_id, label_ko]
		companion_agent.inject_sensory_event(
			"gaze_interest_promoted_quiet",
			"사용자가 %s(%s) 사물을 유심히 바라봐서 중기 기억(%s)에 조용히 기록됐어." % [label_ko, tone_ko, mem_id],
			crop_p,
			false,
			false
		)
	_refresh_xray_panel()


func _on_memory_upgraded(_record: Dictionary) -> void:
	_refresh_xray_panel()


func _on_hybrid_search_completed(_res: Dictionary) -> void:
	_refresh_xray_panel()


func _on_dialogue_card_requested(title: String, body: String, _mood: String) -> void:
	dialogue_title_label.text = title
	dialogue_body_label.text = body
	var cam_tf: Transform3D = xr_camera.global_transform
	var forward: Vector3 = -cam_tf.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() >= 0.001 else Vector3.FORWARD
	var right: Vector3 = forward.cross(Vector3.UP).normalized()
	dialogue_card_root.global_position = cam_tf.origin + forward * 0.90 + right * 0.02 + Vector3(0.0, 0.16, 0.0)
	_face_horizontal(dialogue_card_root, cam_tf.origin)
	dialogue_card_root.visible = true
	_speak_or_chime("", "pinch")


func _on_recommendation_card_requested(payload: Dictionary) -> void:
	rec_header_label.text = str(payload.get("title", "시선 기억 기반 대조 추천 (딱 2선)"))
	rec_talk_label.text = str(payload.get("summary", ""))
	var prods: Array = payload.get("products", [])
	if prods.size() >= 1 and prods[0] is Dictionary:
		var p1: Dictionary = prods[0]
		rec_prod1_label.text = "[%s] %s\n%s" % [str(p1.get("badge", "1")), str(p1.get("title", "")), str(p1.get("desc", ""))]
		rec_item1_query = str(p1.get("query", p1.get("title", "")))
	if prods.size() >= 2 and prods[1] is Dictionary:
		var p2: Dictionary = prods[1]
		rec_prod2_label.text = "[%s] %s\n%s" % [str(p2.get("badge", "2")), str(p2.get("title", "")), str(p2.get("desc", ""))]
		rec_item2_query = str(p2.get("query", p2.get("title", "")))

	if memory_engine.memories.size() > 0:
		var cp: String = str(memory_engine.memories[0].get("crop_path", ""))
		if cp != "":
			_update_crop_textures(cp)

	var cam_tf: Transform3D = xr_camera.global_transform
	var forward: Vector3 = -cam_tf.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() >= 0.001 else Vector3.FORWARD
	var right: Vector3 = forward.cross(Vector3.UP).normalized()
	rec_card_root.global_position = cam_tf.origin + forward * 0.94 - right * 0.22 + Vector3(0.0, -0.05, 0.0)
	_face_horizontal(rec_card_root, cam_tf.origin)
	rec_card_root.visible = true
	spirit.trigger_named_action("happy_spin", "warm")
	_refresh_xray_panel()


func _on_spirit_action_requested(action: String, mood: String) -> void:
	if spirit != null:
		spirit.trigger_named_action(action, mood)


func _on_assistant_replied(text: String, _backend: String, from_realtime_delegate: bool) -> void:
	if text.strip_edges() != "":
		spirit.status_label.text = text.substr(0, 44) + ("..." if text.length() > 44 else "")
		# Realtime 대리 호출일 때는 gpt-realtime이 직접 말하므로 중복 TTS 생략
		if not from_realtime_delegate:
			_speak_or_chime(text, "recommend")
	_refresh_xray_panel()


func _on_agent_status_changed(busy: bool, summary: String) -> void:
	if spirit != null and summary != "":
		if busy:
			spirit.status_label.text = summary
	_update_rune_highlights()
	_refresh_xray_panel()


func _on_auth_required_prompt(reason: String) -> void:
	_show_toast(reason, 2.4)


func _update_crop_textures(crop_path: String) -> void:
	if crop_path == "" or crop_path == last_crop_loaded_path:
		return
	if not FileAccess.file_exists(crop_path):
		return
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(crop_path)
	if bytes.size() < 64:
		return
	var img := Image.new()
	if img.load_jpg_from_buffer(bytes) == OK:
		var tex := ImageTexture.create_from_image(img)
		rec_crop_mat.albedo_color = Color.WHITE
		rec_crop_mat.albedo_texture = tex
		xray_crop_mat.albedo_color = Color.WHITE
		xray_crop_mat.albedo_texture = tex
		last_crop_loaded_path = crop_path


func _poll_vision_and_promotions() -> void:
	if cam_plugin == null:
		return

	var prom_raw: String = str(cam_plugin.call("popPromotedCandidatesJson"))
	if prom_raw != "[]" and prom_raw.length() > 2:
		var prom_arr: Variant = JSON.parse_string(prom_raw)
		if prom_arr is Array:
			for item: Variant in (prom_arr as Array):
				if item is Dictionary:
					memory_engine.ingest_promoted_candidate(item as Dictionary, cam_plugin)

	var vis_raw: String = str(cam_plugin.call("getVisionStateJson"))
	if vis_raw.length() > 4:
		var parsed: Variant = JSON.parse_string(vis_raw)
		if parsed is Dictionary:
			latest_vision_state = parsed as Dictionary
			_apply_vision_state_to_scene(latest_vision_state)

	latest_auth_voice_state = companion_agent.get_auth_voice_state()
	if spirit != null:
		spirit.speaking_energy = 0.85 if bool(latest_auth_voice_state.get("assistantSpeaking", false)) else 0.0


func _apply_vision_state_to_scene(vstate: Dictionary) -> void:
	var tracks: Array = vstate.get("tracks", []) if vstate.get("tracks") is Array else []
	var hands: Array = vstate.get("hands", []) if vstate.get("hands") is Array else []
	var fov_x: float = float(vstate.get("fovTanX", 0.76))
	var fov_y: float = float(vstate.get("fovTanY", 0.57))
	var off_x: float = float(vstate.get("camOffsetX", -0.032))
	var off_y: float = float(vstate.get("camOffsetY", 0.0))

	var max_roi_progress: float = 0.0
	var top_roi_name: String = ""
	for t_var: Variant in tracks:
		if t_var is Dictionary:
			var td: Dictionary = t_var as Dictionary
			if bool(td.get("inCenterRoi", false)):
				var sc: float = float(td.get("interestScore", 0.0))
				var ratio: float = clampf(sc / 65.0, 0.0, 1.0)
				if ratio > max_roi_progress:
					max_roi_progress = ratio
					var raw_lbl: String = str(td.get("label", "desk_object"))
					var cat_entry: Dictionary = MemoryEngineScript.CATEGORY_MAP.get(raw_lbl, {"ko": "관심 사물"})
					top_roi_name = str(cat_entry.get("ko", raw_lbl))

	if spirit != null:
		spirit.gaze_focus_strength = max_roi_progress
		if max_roi_progress > 0.25 and spirit.excited_timer <= 0.05 and not companion_agent.is_busy and has_input_focus:
			spirit.status_label.text = "시선 집중: %s (%d%%)" % [top_roi_name, int(roundf(max_roi_progress * 100.0))]

	if show_vision_bbox:
		var plane_dist: float = absf(BBOX_PLANE_Z)
		var roi_r_world: float = float(vstate.get("centerRoiRadius", 0.22)) * 2.0 * fov_x * plane_dist
		var torus := roi_ring_mesh.mesh as TorusMesh
		if torus != null and absf(torus.inner_radius - roi_r_world) > 0.004:
			torus.inner_radius = maxf(0.08, roi_r_world - 0.005)
			torus.outer_radius = maxf(0.09, roi_r_world + 0.005)
		roi_ring_mesh.position = Vector3(off_x, off_y, BBOX_PLANE_Z)

		for i in range(obj_bbox_slots.size()):
			var slot: Dictionary = obj_bbox_slots[i]
			var root_n: Node3D = slot["root"]
			if i < tracks.size() and tracks[i] is Dictionary:
				var tr: Dictionary = tracks[i]
				var xmin: float = float(tr.get("xmin", 0.4))
				var ymin: float = float(tr.get("ymin", 0.4))
				var xmax: float = float(tr.get("xmax", 0.6))
				var ymax: float = float(tr.get("ymax", 0.6))
				var cx: float = ((xmin + xmax) * 0.5 - 0.5) * 2.0 * fov_x * plane_dist + off_x
				var cy: float = (0.5 - (ymin + ymax) * 0.5) * 2.0 * fov_y * plane_dist + off_y
				var bw: float = maxf(0.06, (xmax - xmin) * 2.0 * fov_x * plane_dist)
				var bh: float = maxf(0.06, (ymax - ymin) * 2.0 * fov_y * plane_dist)

				root_n.position = Vector3(cx, cy, BBOX_PLANE_Z + 0.01)
				_resize_wire_box(slot, bw, bh)

				var promoted: bool = bool(tr.get("promoted", false))
				var in_roi: bool = bool(tr.get("inCenterRoi", false))
				var col: Color = (
					Color(1.0, 0.84, 0.25, 0.95) if promoted
					else (Color(0.25, 1.0, 0.65, 0.90) if in_roi else Color(0.55, 0.78, 0.95, 0.68))
				)
				(slot["mat"] as StandardMaterial3D).albedo_color = col
				var lbl: Label3D = slot["label"]
				lbl.modulate = col.lightened(0.2)
				var raw_l: String = str(tr.get("label", "obj"))
				var ko_l: String = str(MemoryEngineScript.CATEGORY_MAP.get(raw_l, {"ko": raw_l})["ko"])
				var ttc_v: float = float(tr.get("timeToCenterSec", -1.0))
				var ttc_str: String = ("%.2fs" % ttc_v) if ttc_v >= 0.0 else "-"
				lbl.text = "[#%d %s] 진입:%s | 체류:%.1fs | 관심:%d/100%s" % [
					int(tr.get("trackId", 0)),
					ko_l,
					ttc_str,
					float(tr.get("dwellSec", 0.0)),
					int(roundf(float(tr.get("interestScore", 0.0)))),
					" [중기저장★]" if promoted else ""
				]
				root_n.visible = true
			else:
				root_n.visible = false

		for i in range(hand_bbox_slots.size()):
			var hslot: Dictionary = hand_bbox_slots[i]
			var hroot: Node3D = hslot["root"]
			if i < hands.size() and hands[i] is Dictionary:
				var hd: Dictionary = hands[i]
				var hxmin: float = float(hd.get("xmin", 0.4))
				var hymin: float = float(hd.get("ymin", 0.4))
				var hxmax: float = float(hd.get("xmax", 0.6))
				var hymax: float = float(hd.get("ymax", 0.6))
				var hcx: float = ((hxmin + hxmax) * 0.5 - 0.5) * 2.0 * fov_x * plane_dist + off_x
				var hcy: float = (0.5 - (hymin + hymax) * 0.5) * 2.0 * fov_y * plane_dist + off_y
				var hbw: float = maxf(0.07, (hxmax - hxmin) * 2.0 * fov_x * plane_dist)
				var hbh: float = maxf(0.07, (hymax - hymin) * 2.0 * fov_y * plane_dist)
				hroot.position = Vector3(hcx, hcy, BBOX_PLANE_Z + 0.02)
				_resize_wire_box(hslot, hbw, hbh)
				var pinching: bool = bool(hd.get("isPinching", false))
				var hcol: Color = Color(1.0, 0.48, 0.92, 0.95) if pinching else Color(0.35, 0.85, 1.0, 0.90)
				(hslot["mat"] as StandardMaterial3D).albedo_color = hcol
				(hslot["label"] as Label3D).text = "[RGB 카메라 손 인식] " + ("PINCH!" if pinching else "OPEN")
				hroot.visible = true
			else:
				hroot.visible = false

	if show_memory_xray:
		_refresh_xray_panel()


func _refresh_xray_panel() -> void:
	if xray_text_label == null:
		return
	var counts: Dictionary = memory_engine.get_tier_counts()
	var discarded_n: int = int(latest_vision_state.get("discardedCount", 0))
	var hand_summary: String = "OpenXR맨손=%s | RGB카메라손=%s" % [
		("인식중" if (openxr_bare_left_active or openxr_bare_right_active) else "대기"),
		("인식중" if rgb_hand_active else "대기")
	]

	var auth_txt: String = "미연결 (⚙ 설정 눌러 localhost:1455 연결)"
	if not latest_auth_voice_state.is_empty():
		var parts: Array[String] = []
		if bool(latest_auth_voice_state.get("oauthReady", false)):
			parts.append("OAuth(%s)" % str(latest_auth_voice_state.get("codexModel", "gpt-5.4")))
		if bool(latest_auth_voice_state.get("apiKeyReady", false)):
			parts.append("Realtime(%s)" % str(latest_auth_voice_state.get("realtimeState", "idle")))
		if bool(latest_auth_voice_state.get("sktAxReady", false)):
			parts.append("SKT-A.X-K2")
		if parts.size() > 0:
			auth_txt = " + ".join(PackedStringArray(parts))

	var latest_annot: String = "실제 시선 중심에서 포착된 사물 대기 중 (가짜 시드 0건)"
	var latest_model_badge: String = "-"
	if memory_engine.memories.size() > 0:
		var m0: Dictionary = memory_engine.memories[0]
		var tier_s: String = "★장기승격" if str(m0.get("tier", "")) == "long_term" else "중단기"
		latest_annot = "[%s|%s] %s" % [str(m0.get("id", "")), tier_s, str(m0.get("annotation", ""))]
		latest_model_badge = "%s + %s" % [str(m0.get("vlm_model", "")), str(m0.get("embed_model", ""))]
		var cp: String = str(m0.get("crop_path", ""))
		if cp != "":
			_update_crop_textures(cp)

	var sr: Dictionary = memory_engine.last_search_result
	var vec_lines: Array[String] = []
	var lex_lines: Array[String] = []
	if not sr.is_empty():
		for item_v: Variant in sr.get("vector_top3", []):
			if item_v is Dictionary:
				var d: Dictionary = item_v as Dictionary
				var star: String = "★장기" if str(d.get("tier", "")) == "long_term" else "중기"
				vec_lines.append("%s %s(%.2f,%s)" % [str(d["id"]), str(d["label_ko"]), float(d["score"]), star])
		for item_l: Variant in sr.get("lexical_top3", []):
			if item_l is Dictionary:
				var dl: Dictionary = item_l as Dictionary
				var star2: String = "★장기" if str(dl.get("tier", "")) == "long_term" else "중기"
				lex_lines.append("%s %s(BM25 %.1f,%s)" % [str(dl["id"]), str(dl["label_ko"]), float(dl["score"]), star2])

	var vec_txt: String = " | ".join(PackedStringArray(vec_lines)) if vec_lines.size() > 0 else "(검색 시 표시)"
	var lex_txt: String = " | ".join(PackedStringArray(lex_lines)) if lex_lines.size() > 0 else "(검색 시 표시)"
	var mode_str: String = "1.능동제안" if proactive_mode else "2.온디맨드"

	xray_text_label.text = (
		"세션: %s | 공존포커스=%s\n" % [auth_txt, ("MR포커스" if has_input_focus else "2D앱공존중")]
		+ "기억: 감각폐기 %d건 | 중기 %d건 | ★장기승격 %d건 | 모드=%s\n" % [
			discarded_n, int(counts["mid_term"]), int(counts["long_term"]), mode_str
		]
		+ "손인식: %s | 인덱서: %s\n" % [hand_summary, latest_model_badge]
		+ "최근기억: %s\n" % latest_annot
		+ "벡터Top3: %s\n" % vec_txt
		+ "단어Top3: %s" % lex_txt
	)


func _update_bare_hand_tracker(
	tracker_path: StringName,
	joint_meshes: Array[MeshInstance3D],
	is_right: bool
) -> Dictionary:
	var out: Dictionary = {
		"active": false,
		"palm": Vector3.ZERO,
		"index_tip": Vector3.ZERO,
		"all_points": [],
		"pinching": false,
		"pinch_just_pressed": false,
		"is_pointing_ray": false,
		"ray_origin": Vector3.ZERO,
		"ray_dir": Vector3.FORWARD
	}
	var ht := XRServer.get_tracker(tracker_path) as XRHandTracker
	if ht == null or not ht.get_has_tracking_data():
		for jm: MeshInstance3D in joint_meshes:
			jm.visible = false
		if is_right:
			right_pinch_prev = false
		else:
			left_pinch_prev = false
		return out

	var palm_flags: int = ht.get_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM)
	if (palm_flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) == 0:
		for jm: MeshInstance3D in joint_meshes:
			jm.visible = false
		return out

	var origin_tf: Transform3D = xr_origin.global_transform
	var positions: Array[Vector3] = []
	for idx in range(JOINT_INDICES.size()):
		var j_enum: int = JOINT_INDICES[idx]
		var j_tf: Transform3D = origin_tf * ht.get_hand_joint_transform(j_enum)
		positions.append(j_tf.origin)
		joint_meshes[idx].global_position = j_tf.origin
		joint_meshes[idx].visible = true

	var palm_pos: Vector3 = positions[0]
	var thumb_pos: Vector3 = positions[1]
	var index_pos: Vector3 = positions[2]
	var middle_pos: Vector3 = positions[3]
	var ring_pos: Vector3 = positions[4]
	var pinky_pos: Vector3 = positions[5]

	var pinch_dist: float = thumb_pos.distance_to(index_pos)
	var prev_p: bool = right_pinch_prev if is_right else left_pinch_prev
	var now_p: bool = (pinch_dist < 0.021) if not prev_p else (pinch_dist < 0.032)
	var just_p: bool = now_p and not prev_p
	if is_right:
		right_pinch_prev = now_p
	else:
		left_pinch_prev = now_p

	# 검지만 펴고 중지·약지·소지를 접은 맨손 포인팅 제스처 판별 -> 무컨트롤러 포인터 광선 발사!
	var idx_ext: float = palm_pos.distance_to(index_pos)
	var curled_avg: float = (
		palm_pos.distance_to(middle_pos)
		+ palm_pos.distance_to(ring_pos)
		+ palm_pos.distance_to(pinky_pos)
	) / 3.0
	var is_pointing: bool = (not now_p) and idx_ext > 0.125 and curled_avg < idx_ext * 0.78

	var orb_col: Color = (
		Color(1.0, 0.58, 0.90, 0.92) if now_p
		else (Color(0.45, 0.94, 1.0, 0.88) if is_pointing else Color(0.35, 1.0, 0.85, 0.68))
	)
	for jm: MeshInstance3D in joint_meshes:
		(jm.material_override as StandardMaterial3D).albedo_color = orb_col

	out["active"] = true
	out["palm"] = palm_pos
	out["index_tip"] = index_pos
	out["all_points"] = positions
	out["pinching"] = now_p
	out["pinch_just_pressed"] = just_p
	out["is_pointing_ray"] = is_pointing
	out["ray_origin"] = index_pos
	out["ray_dir"] = (index_pos - palm_pos).normalized()
	return out


func _process_hands_and_pointers(delta: float) -> Variant:
	if rune_cooldown > 0.0:
		rune_cooldown = maxf(0.0, rune_cooldown - delta)

	if y_hold_timer >= 0.0:
		y_hold_timer += delta
		if y_hold_timer >= 1.15:
			y_hold_timer = -1.0
			_action_reset_demo()

	var left_info: Dictionary = _update_bare_hand_tracker(&"/user/hand_tracker/left", bare_hand_joints_left, false)
	var right_info: Dictionary = _update_bare_hand_tracker(&"/user/hand_tracker/right", bare_hand_joints_right, true)
	openxr_bare_left_active = bool(left_info["active"])
	openxr_bare_right_active = bool(right_info["active"])

	ctrl_left_dot.visible = left_hand.get_is_active() and not openxr_bare_left_active
	ctrl_right_dot.visible = right_hand.get_is_active() and not openxr_bare_right_active

	var poke_points: Array[Vector3] = []
	var named_hand_points: Dictionary = {}
	var active_rays: Array[Dictionary] = []

	pointer_beam_left.visible = false
	pointer_beam_right.visible = false

	# 왼손 입력 & 포인터 광선
	if openxr_bare_left_active:
		var l_pts: Array = left_info["all_points"]
		poke_points.append(left_info["index_tip"] as Vector3)
		named_hand_points["left_palm"] = l_pts[0]
		named_hand_points["left_index"] = l_pts[2]
		named_hand_points["left_middle"] = l_pts[3]
		if bool(left_info["is_pointing_ray"]):
			var lo: Vector3 = left_info["ray_origin"]
			var ld: Vector3 = left_info["ray_dir"]
			active_rays.append({"origin": lo, "dir": ld, "source": "왼손 검지 포인터"})
			_update_beam_visual(pointer_beam_left, lo, ld, 1.15)
	elif left_hand.get_is_active():
		poke_points.append(left_hand.global_position)
		named_hand_points["left_ctrl"] = left_hand.global_position
		var l_dir: Vector3 = -left_hand.global_transform.basis.z.normalized()
		active_rays.append({"origin": left_hand.global_position, "dir": l_dir, "source": "왼손 컨트롤러 포인터"})
		_update_beam_visual(pointer_beam_left, left_hand.global_position, l_dir, 1.25)

	# 오른손 입력 & 포인터 광선
	if openxr_bare_right_active:
		var r_pts: Array = right_info["all_points"]
		poke_points.append(right_info["index_tip"] as Vector3)
		named_hand_points["right_palm"] = r_pts[0]
		named_hand_points["right_index"] = r_pts[2]
		named_hand_points["right_middle"] = r_pts[3]
		if bool(right_info["is_pointing_ray"]):
			var ro: Vector3 = right_info["ray_origin"]
			var rd: Vector3 = right_info["ray_dir"]
			active_rays.append({"origin": ro, "dir": rd, "source": "오른손 검지 포인터"})
			_update_beam_visual(pointer_beam_right, ro, rd, 1.15)
	elif right_hand.get_is_active():
		poke_points.append(right_hand.global_position)
		named_hand_points["right_ctrl"] = right_hand.global_position
		var r_dir: Vector3 = -right_hand.global_transform.basis.z.normalized()
		active_rays.append({"origin": right_hand.global_position, "dir": r_dir, "source": "오른손 컨트롤러 포인터"})
		_update_beam_visual(pointer_beam_right, right_hand.global_position, r_dir, 1.25)

	# RGB 카메라 기반 MediaPipe 손 인식 3D 투영 (보조/백업 손 추적)
	rgb_hand_active = false
	var rgb_hands: Variant = latest_vision_state.get("hands", [])
	if rgb_hands is Array and (rgb_hands as Array).size() > 0:
		var h0: Variant = (rgb_hands as Array)[0]
		if h0 is Dictionary:
			rgb_hand_active = true
			var hd: Dictionary = h0 as Dictionary
			var ix: float = float(hd.get("ix", 0.5))
			var iy: float = float(hd.get("iy", 0.5))
			var depth_m: float = float(hd.get("approxDepthM", 0.55))
			var fov_x: float = float(latest_vision_state.get("fovTanX", 0.76))
			var fov_y: float = float(latest_vision_state.get("fovTanY", 0.57))
			var local_pt := Vector3(
				(ix - 0.5) * 2.0 * fov_x * depth_m,
				(0.5 - iy) * 2.0 * fov_y * depth_m,
				-depth_m
			)
			var world_rgb_hand: Vector3 = xr_camera.global_transform * local_pt
			var rgb_pinch: bool = bool(hd.get("isPinching", false))
			var rgb_just_pinched: bool = rgb_pinch and not rgb_pinch_prev
			rgb_pinch_prev = rgb_pinch

			if not openxr_bare_left_active and not openxr_bare_right_active:
				rgb_hand_orb.global_position = world_rgb_hand
				rgb_hand_orb.visible = true
				poke_points.append(world_rgb_hand)
				named_hand_points["rgb_hand"] = world_rgb_hand
				if rgb_just_pinched and world_rgb_hand.distance_to(spirit.global_position) < 0.36 and rune_cooldown <= 0.0:
					rune_cooldown = RUNE_COOLDOWN_SEC
					_action_trigger_query("RGB손핀치")
			else:
				rgb_hand_orb.visible = false
	else:
		rgb_hand_orb.visible = false
		rgb_pinch_prev = false

	# 포인터 광선 회피 & 손 궤적 국소 연기 흩어짐 주입
	spirit.ingest_pointer_rays(active_rays, xr_camera.global_transform, delta)
	spirit.ingest_hand_points(named_hand_points, delta)

	# 오른손 맨손 핀치 -> 정령 근처에서 대화/추천 즉시 실행
	if bool(right_info["pinch_just_pressed"]) and rune_cooldown <= 0.0:
		var r_tip: Vector3 = right_info["index_tip"]
		if r_tip.distance_to(spirit.global_position) < 0.32:
			rune_cooldown = RUNE_COOLDOWN_SEC
			_action_trigger_query("맨손핀치")

	var any_near_runes: bool = false
	var closest_hand_pt: Variant = null
	var closest_d: float = 999.0

	for pt: Vector3 in poke_points:
		var ds: float = pt.distance_to(spirit.global_position)
		if ds < closest_d:
			closest_d = ds
			closest_hand_pt = pt

		if pt.distance_to(spirit_runes_root.global_position) < 0.36:
			any_near_runes = true

		if rune_cooldown <= 0.0:
			for r: Dictionary in rune_items:
				var holder: Node3D = r["holder"]
				if pt.distance_to(holder.global_position) < 0.038:
					rune_cooldown = RUNE_COOLDOWN_SEC
					var k: String = str(r["key"])
					if k == "A":
						_action_toggle_vision_bbox()
					elif k == "B":
						_action_toggle_memory_xray()
					elif k == "X":
						_action_toggle_demo_mode()
					elif k == "Y":
						_action_trigger_query("맨손룬Y")
					elif k == "S":
						_action_open_setup_browser()
					return closest_hand_pt

		if dialogue_card_root.visible and rune_cooldown <= 0.0:
			if pt.distance_to(dialogue_close_btn.global_position) < 0.042:
				rune_cooldown = RUNE_COOLDOWN_SEC
				dialogue_card_root.visible = false
				_speak_or_chime("", "pinch")
				return closest_hand_pt

		if rec_card_root.visible and rune_cooldown <= 0.0:
			for rb: Dictionary in rec_buttons:
				var bnode: Node3D = rb["node"]
				if pt.distance_to(bnode.global_position) < 0.046:
					rune_cooldown = RUNE_COOLDOWN_SEC
					var bid: String = str(rb["id"])
					if bid == "close":
						rec_card_root.visible = false
						_speak_or_chime("", "pinch")
					elif bid == "web1":
						_open_product_search_2d(rec_item1_query, 1)
					elif bid == "web2":
						_open_product_search_2d(rec_item2_query, 2)
					return closest_hand_pt

	_update_rune_highlights(any_near_runes)
	return closest_hand_pt


func _open_product_search_2d(query_str: String, slot_num: int) -> void:
	var q: String = query_str.strip_edges()
	if q == "":
		return
	var url: String = "https://www.google.com/search?q=" + q.uri_encode()
	_speak_or_chime("", "promote")
	_show_toast("%d번 후보를 옆 2D 브라우저 창에서 검색했어!" % slot_num, 2.0)
	if cam_plugin != null:
		cam_plugin.call("open2dBrowserUrl", url)


func _process(delta: float) -> void:
	time_sec += delta
	vision_poll_timer += delta
	if vision_poll_timer >= 0.12:
		vision_poll_timer = 0.0
		_poll_vision_and_promotions()

	companion_agent.poll(delta)

	if toast_timer > 0.0:
		toast_timer = maxf(0.0, toast_timer - delta)
		if toast_timer == 0.0:
			toast_root.visible = false

	if not desktop_mode and not initialized_anchor and xr_camera.global_position.length_squared() > 0.01:
		_reanchor_near_user()

	if initialized_anchor and xr_camera.global_position.distance_to(home_pos) > 1.95:
		_reanchor_near_user()

	var closest_hand: Variant = _process_hands_and_pointers(delta)
	spirit.tick_spirit(delta, xr_camera.global_transform, closest_hand, has_input_focus)

	# 룬 바는 홈 기준점 아래에 차분히 유지하여 포인터 도망 중에도 버튼이 흔들리지 않게 함
	spirit_runes_root.global_position = spirit_runes_root.global_position.lerp(
		home_pos + Vector3(0.0, -0.23, 0.03),
		clampf(delta * 6.0, 0.0, 1.0)
	)
	_face_horizontal(spirit_runes_root, xr_camera.global_position)
