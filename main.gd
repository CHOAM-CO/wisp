extends Node3D

const MemoryEngineScript = preload("res://scripts/memory_engine.gd")
const BBOX_PLANE_Z: float = -0.95
const RUNE_COOLDOWN_SEC: float = 0.55

var xr_interface: OpenXRInterface
var has_input_focus: bool = true
var desktop_mode: bool = false
var cam_plugin: Object = null
var kr_font: Font = null

var memory_engine = null

@onready var xr_origin: XROrigin3D = $XROrigin3D
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var left_hand: XRController3D = $XROrigin3D/LeftHand
@onready var right_hand: XRController3D = $XROrigin3D/RightHand

# 연기 정령 가상 실물
var spirit_root: Node3D
var wisps: Array[MeshInstance3D] = []
var wisp_mats: Array[StandardMaterial3D] = []
var status_label: Label3D

var home_pos: Vector3 = Vector3(0.30, 1.44, -0.92)
var target_pos: Vector3 = Vector3(0.30, 1.44, -0.92)
var velocity: Vector3 = Vector3.ZERO
var initialized_anchor: bool = false
var excited_timer: float = 0.0
var indexed_pulse_timer: float = 0.0
var gaze_focus_strength: float = 0.0
var time_sec: float = 0.0

# 맨손(OpenXR 26관절 XRHandTracker + RGB 카메라 MediaPipe 손 인식 + 컨트롤러) 통합 시각화·입력
var bare_hand_joints_left: Array[MeshInstance3D] = []
var bare_hand_joints_right: Array[MeshInstance3D] = []
var rgb_hand_orb: MeshInstance3D
var ctrl_left_dot: MeshInstance3D
var ctrl_right_dot: MeshInstance3D

var left_pinch_prev: bool = false
var right_pinch_prev: bool = false
var rgb_pinch_prev: bool = false
var openxr_bare_left_active: bool = false
var openxr_bare_right_active: bool = false
var rgb_hand_active: bool = false
var y_hold_timer: float = -1.0

# 정령 하단 원핸드/맨손 공간 룬 버튼 4개 (컨트롤러 없이 A/B/X/Y 모든 기능 수행)
var spirit_runes_root: Node3D
var rune_items: Array[Dictionary] = []
var rune_cooldown: float = 0.0

# 모드 전환 토스트 (잠깐 뜨고 사라짐)
var toast_root: Node3D
var toast_label: Label3D
var toast_timer: float = 0.0

# 상품 추천 딱 2개 제시 팝업 카드 (추천 발생 시에만 표시, 맨손 터치 버튼 포함)
var rec_card_root: Node3D
var rec_talk_label: Label3D
var rec_prod1_label: Label3D
var rec_prod2_label: Label3D
var rec_crop_mesh: MeshInstance3D
var rec_crop_mat: StandardMaterial3D
var rec_buttons: Array[Dictionary] = []

# 데모용 오버레이: A(시선 중심 ROI + 실시간 BBox), B(메모리 & 하이브리드 검색 X-Ray)
var show_vision_bbox: bool = false
var show_memory_xray: bool = false
var proactive_mode: bool = true # true = 모드1(항상 바로바로 추천), false = 모드2(물어봤을 때만 제안)

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
var last_crop_loaded_path: String = ""

const JOINT_INDICES: Array[int] = [
	XRHandTracker.HAND_JOINT_PALM,
	XRHandTracker.HAND_JOINT_THUMB_TIP,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
	XRHandTracker.HAND_JOINT_RING_FINGER_TIP,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP
]

const LINES_TOUCH: Array[String] = [
	"앗 간지러워! 손길 느껴져~",
	"헤헤 맨손으로도 잘 닿네!",
	"살살 건드려줘 ㅋㅋ",
	"요기 떠 있지~"
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
				print("[Companion] Loaded Korean font: ", p)
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
	memory_engine.hybrid_search_completed.connect(_on_hybrid_search_completed)

	_setup_environment()
	_build_smoke_spirit()
	_build_spirit_spatial_runes()
	_build_toast_ui()
	_build_recommendation_card()
	_build_debug_overlays()
	_build_hand_visualizers()
	_init_openxr()
	_init_camera_plugin()
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
	var txt: String = "모드 1: 항상 바로바로 추천" if proactive_mode else "모드 2: 물어봤을 때만 검색 후 제안"
	_speak_or_chime("", "mode")
	_show_toast(txt, 1.9)
	_refresh_xray_panel()
	_update_rune_highlights()


func _action_trigger_query(source_tag: String) -> void:
	excited_timer = 1.4
	var query_txt: String = ""
	var focus_id: String = ""
	var vis_sig: Array = []
	if memory_engine.memories.size() > 0:
		var latest: Dictionary = memory_engine.memories[0]
		focus_id = str(latest.get("id", ""))
		query_txt = "%s %s %s" % [
			str(latest.get("label_ko", "")),
			str(latest.get("color_tone", "")),
			str(latest.get("category_ko", ""))
		]
		var rs: Variant = latest.get("rgb_sig", [])
		if rs is Array:
			vis_sig = rs
	var res: Dictionary = memory_engine.retrieve_hybrid_and_promote(query_txt, vis_sig, focus_id)
	_present_recommendation_bundle(res, source_tag)


func _action_reset_demo() -> void:
	memory_engine.reset_live_memories()
	if cam_plugin != null:
		cam_plugin.call("resetVisionSession")
	rec_card_root.visible = false
	_reanchor_near_user()
	_speak_or_chime("데모 기억과 위치를 초기화했어.", "mode")
	_show_toast("데모 메모리 & 정령 위치 리셋 완료", 1.8)
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
		print("[Companion] QuestCameraPlugin connected: ", init_state)
	else:
		print("[Companion] QuestCameraPlugin singleton not present (desktop preview).")


func _setup_environment() -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.86, 0.92, 1.0)
	env.ambient_light_energy = 0.85
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
	status_label.text = "함께 보고 있어"


func _on_session_visible() -> void:
	has_input_focus = false
	status_label.text = "백그라운드 공존 중"


func _reanchor_near_user() -> void:
	var cam_tf: Transform3D = xr_camera.global_transform
	var forward: Vector3 = -cam_tf.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() >= 0.001 else Vector3.FORWARD
	var right: Vector3 = forward.cross(Vector3.UP).normalized()

	home_pos = cam_tf.origin + forward * 0.90 + right * 0.30 + Vector3(0.0, -0.06, 0.0)
	target_pos = home_pos
	spirit_root.global_position = home_pos

	# 추천 팝업 카드는 정령 왼편에 깔끔하게 배치
	var rec_pos: Vector3 = cam_tf.origin + forward * 0.96 - right * 0.22 + Vector3(0.0, -0.05, 0.0)
	rec_card_root.global_position = rec_pos
	_face_horizontal(rec_card_root, cam_tf.origin)

	# B 버튼 X-Ray 패널은 상단 좌측에 겹치지 않게 배치
	var xray_pos: Vector3 = cam_tf.origin + forward * 1.04 - right * 0.24 + Vector3(0.0, 0.28, 0.0)
	debug_memory_panel.global_position = xray_pos
	_face_horizontal(debug_memory_panel, cam_tf.origin)

	initialized_anchor = true


func _face_horizontal(node: Node3D, target_world: Vector3) -> void:
	var dir: Vector3 = target_world - node.global_position
	dir.y = 0.0
	if dir.length_squared() > 0.001:
		node.global_transform.basis = Basis.looking_at(-dir.normalized(), Vector3.UP)


func _build_smoke_spirit() -> void:
	spirit_root = Node3D.new()
	spirit_root.name = "SmokeSpirit"
	spirit_root.position = home_pos
	add_child(spirit_root)

	var radii: Array[float] = [0.092, 0.078, 0.072, 0.066, 0.060, 0.055, 0.050, 0.045, 0.040]
	for i in range(radii.size()):
		var mi := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = radii[i]
		sphere.height = radii[i] * 2.0
		sphere.radial_segments = 24
		sphere.rings = 16
		mi.mesh = sphere

		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		var alpha: float = 0.88 if i == 0 else lerpf(0.56, 0.25, float(i) / float(radii.size()))
		mat.albedo_color = Color(0.42, 0.86, 1.0, alpha)
		mat.emission_enabled = true
		mat.emission = Color(0.28, 0.72, 1.0)
		mat.emission_energy_multiplier = 1.55 if i == 0 else 0.88
		mat.roughness = 0.85
		mi.material_override = mat

		spirit_root.add_child(mi)
		wisps.append(mi)
		wisp_mats.append(mat)

	for side: float in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = 0.015
		eye_mesh.height = 0.034
		eye.mesh = eye_mesh
		var eye_mat := StandardMaterial3D.new()
		eye_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		eye_mat.albedo_color = Color(1.0, 1.0, 1.0)
		eye.material_override = eye_mat
		eye.position = Vector3(side * 0.033, 0.018, 0.080)
		spirit_root.add_child(eye)

	status_label = _make_label(22, 0.00125, 4)
	status_label.text = "함께 보고 있어"
	status_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	status_label.position = Vector3(0.0, 0.19, 0.0)
	spirit_root.add_child(status_label)


func _build_spirit_spatial_runes() -> void:
	# 컨트롤러 없이 맨손 검지 터치(또는 핀치)만으로도 A/B/X/Y 모든 기능을 한 손 조작 가능한 소형 룬 독
	spirit_runes_root = Node3D.new()
	spirit_runes_root.name = "SpiritSpatialRunes"
	add_child(spirit_runes_root)

	var defs: Array[Dictionary] = [
		{"key": "A", "label": "A 시선", "offset": Vector3(-0.135, 0.0, 0.0), "col": Color(0.20, 0.78, 0.55, 0.42)},
		{"key": "B", "label": "B 기억", "offset": Vector3(-0.045, 0.0, 0.0), "col": Color(0.52, 0.42, 0.92, 0.42)},
		{"key": "X", "label": "X 모드", "offset": Vector3(0.045, 0.0, 0.0), "col": Color(0.22, 0.62, 0.92, 0.42)},
		{"key": "Y", "label": "Y 추천", "offset": Vector3(0.135, 0.0, 0.0), "col": Color(0.95, 0.55, 0.32, 0.48)}
	]
	for d: Dictionary in defs:
		var holder := Node3D.new()
		holder.position = d["offset"]
		spirit_runes_root.add_child(holder)

		var pill := _make_panel_bg(0.078, 0.036, d["col"], -1)
		holder.add_child(pill)

		var lbl := _make_label(15, 0.00095, 4)
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
	for r: Dictionary in rune_items:
		var key: String = str(r["key"])
		var mat: StandardMaterial3D = r["mat"]
		var base_col: Color = r["base_col"]
		var active_on: bool = (
			(key == "A" and show_vision_bbox)
			or (key == "B" and show_memory_xray)
			or (key == "X" and proactive_mode)
		)
		var alpha: float = 0.88 if hand_near else (0.62 if active_on else 0.30)
		var c: Color = base_col.lightened(0.22 if active_on else 0.0)
		c.a = alpha
		mat.albedo_color = c


func _build_toast_ui() -> void:
	toast_root = Node3D.new()
	toast_root.visible = false
	toast_root.position = Vector3(0.0, -0.22, -0.82)
	xr_camera.add_child(toast_root)

	var bg := _make_panel_bg(0.42, 0.056, Color(0.05, 0.09, 0.16, 0.86), 2)
	toast_root.add_child(bg)

	toast_label = _make_label(18, 0.0010, 5)
	toast_label.position = Vector3(0.0, 0.0, 0.008)
	toast_root.add_child(toast_label)


func _build_recommendation_card() -> void:
	# 딱 2가지 상품 추천만 간결하게 제시하는 소형 공간 팝업 카드 (평소 숨김)
	rec_card_root = Node3D.new()
	rec_card_root.name = "RecommendationCard2"
	rec_card_root.visible = false
	rec_card_root.position = Vector3(-0.22, 1.38, -0.96)
	add_child(rec_card_root)

	var bg := _make_panel_bg(0.48, 0.34, Color(0.05, 0.08, 0.14, 0.86), -4)
	rec_card_root.add_child(bg)

	var header := _make_panel_bg(0.48, 0.044, Color(0.14, 0.48, 0.68, 0.92), -2)
	header.position = Vector3(0.0, 0.148, 0.006)
	rec_card_root.add_child(header)

	var h_lbl := _make_label(17, 0.00098, 3)
	h_lbl.text = "시선 관심 기반 맞춤 추천 (딱 2선)"
	h_lbl.position = Vector3(0.0, 0.148, 0.012)
	rec_card_root.add_child(h_lbl)

	# 좌상단: 방금 유심히 본 객체 크롭 썸네일
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
	rec_crop_mesh.position = Vector3(-0.182, 0.082, 0.010)
	rec_card_root.add_child(rec_crop_mesh)

	rec_talk_label = _make_label(15, 0.00092, 3)
	rec_talk_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	rec_talk_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	rec_talk_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rec_talk_label.width = 340.0
	rec_talk_label.position = Vector3(-0.128, 0.114, 0.012)
	rec_card_root.add_child(rec_talk_label)

	# 추천 후보 1 슬롯
	var slot1_bg := _make_panel_bg(0.44, 0.068, Color(0.10, 0.18, 0.28, 0.88), -2)
	slot1_bg.position = Vector3(0.0, 0.002, 0.006)
	rec_card_root.add_child(slot1_bg)

	rec_prod1_label = _make_label(15, 0.00092, 3)
	rec_prod1_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	rec_prod1_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	rec_prod1_label.position = Vector3(-0.205, 0.028, 0.012)
	rec_card_root.add_child(rec_prod1_label)

	# 추천 후보 2 슬롯
	var slot2_bg := _make_panel_bg(0.44, 0.068, Color(0.10, 0.16, 0.24, 0.88), -2)
	slot2_bg.position = Vector3(0.0, -0.076, 0.006)
	rec_card_root.add_child(slot2_bg)

	rec_prod2_label = _make_label(15, 0.00092, 3)
	rec_prod2_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	rec_prod2_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	rec_prod2_label.position = Vector3(-0.205, -0.050, 0.012)
	rec_card_root.add_child(rec_prod2_label)

	# 하단 맨손 터치 버튼 ([1번 관심] [2번 관심] [닫기])
	var btn_defs: Array[Dictionary] = [
		{"id": "pick1", "txt": "1번 찜", "x": -0.13, "col": Color(0.18, 0.58, 0.48, 0.88)},
		{"id": "pick2", "txt": "2번 찜", "x": 0.0, "col": Color(0.20, 0.48, 0.72, 0.88)},
		{"id": "close", "txt": "닫기", "x": 0.13, "col": Color(0.38, 0.25, 0.32, 0.88)}
	]
	for bd: Dictionary in btn_defs:
		var b_node := Node3D.new()
		b_node.position = Vector3(float(bd["x"]), -0.138, 0.010)
		rec_card_root.add_child(b_node)
		var b_bg := _make_panel_bg(0.105, 0.034, bd["col"], -1)
		b_node.add_child(b_bg)
		var b_lbl := _make_label(15, 0.00092, 4)
		b_lbl.text = str(bd["txt"])
		b_lbl.position = Vector3(0.0, 0.0, 0.006)
		b_node.add_child(b_lbl)
		rec_buttons.append({"id": str(bd["id"]), "node": b_node})


func _build_debug_overlays() -> void:
	# 1) A 버튼: 실시간 시야 중심 ROI + 동적 객체/손 3D 바운딩 박스 레이어 (기본 OFF, 녹화 호환)
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

	# 2) B 버튼: 중단기·장기 메모리 승격 & 하이브리드 검색(벡터3 + 단어3) X-Ray 패널 (기본 OFF)
	debug_memory_panel = Node3D.new()
	debug_memory_panel.name = "DebugMemoryXRayPanel"
	debug_memory_panel.visible = false
	debug_memory_panel.position = Vector3(-0.24, 1.70, -1.04)
	add_child(debug_memory_panel)

	var mem_bg := _make_panel_bg(0.62, 0.36, Color(0.06, 0.05, 0.14, 0.88), -4)
	debug_memory_panel.add_child(mem_bg)

	var mem_hdr := _make_panel_bg(0.62, 0.042, Color(0.36, 0.24, 0.68, 0.92), -2)
	mem_hdr.position = Vector3(0.0, 0.159, 0.006)
	debug_memory_panel.add_child(mem_hdr)

	var mem_title := _make_label(17, 0.00096, 3)
	mem_title.text = "[X-RAY] 시선 메모리 승격 & 하이브리드 검색 (벡터 Top-3 + 단어 Top-3)"
	mem_title.position = Vector3(0.0, 0.159, 0.012)
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
	xray_crop_mesh.position = Vector3(-0.245, 0.088, 0.010)
	debug_memory_panel.add_child(xray_crop_mesh)

	xray_text_label = _make_label(15, 0.00090, 3)
	xray_text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	xray_text_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	xray_text_label.position = Vector3(-0.185, 0.128, 0.012)
	debug_memory_panel.add_child(xray_text_label)


func _build_hand_visualizers() -> void:
	# 1) OpenXR 맨손 26관절 중 손바닥 + 다섯 손가락 끝 발광 구체 (컨트롤러 없이 손 인식 시각화)
	for i in range(JOINT_INDICES.size()):
		var radius: float = 0.016 if i == 0 else 0.010
		var jl := _make_joint_orb(radius, Color(0.35, 1.0, 0.85, 0.72))
		jl.visible = false
		add_child(jl)
		bare_hand_joints_left.append(jl)

		var jr := _make_joint_orb(radius, Color(0.35, 1.0, 0.85, 0.72))
		jr.visible = false
		add_child(jr)
		bare_hand_joints_right.append(jr)

	# 2) RGB 카메라 기반 MediaPipe 손 인식 3D 투영 구체 (전용 핸드트래킹 센서/기기 없을 때도 작동)
	rgb_hand_orb = _make_joint_orb(0.018, Color(0.72, 0.52, 1.0, 0.75))
	rgb_hand_orb.visible = false
	add_child(rgb_hand_orb)

	# 3) 컨트롤러 사용 시 소형 포인트 마커
	ctrl_left_dot = _make_joint_orb(0.014, Color(0.5, 0.9, 1.0, 0.48))
	left_hand.add_child(ctrl_left_dot)
	ctrl_right_dot = _make_joint_orb(0.014, Color(0.5, 0.9, 1.0, 0.48))
	right_hand.add_child(ctrl_right_dot)


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
	indexed_pulse_timer = 1.2
	var crop_p: String = str(record.get("crop_path", ""))
	if crop_p != "":
		_update_crop_textures(crop_p)

	if proactive_mode:
		# 모드 1 (항상 바로바로 추천): 임계 돌파 즉시 하이브리드 검색 + 장기기억 승격 + 2가지 추천 제시!
		var q: String = "%s %s %s" % [
			str(record.get("label_ko", "")),
			str(record.get("color_tone", "")),
			str(record.get("category_ko", ""))
		]
		var sig: Array = []
		var rs: Variant = record.get("rgb_sig", [])
		if rs is Array:
			sig = rs
		var res: Dictionary = memory_engine.retrieve_hybrid_and_promote(q, sig, str(record["id"]), false)
		_present_recommendation_bundle(res, "자동포착")
	else:
		# 모드 2 (물어봤을 때만 제안): 조용히 중단기 메모리에만 저장하고 짧은 색 맥동만 표시
		_speak_or_chime("", "capture")
		status_label.text = "기억해 뒀어 (%s)" % str(record.get("label_ko", "관심 사물"))
		excited_timer = 1.1
		_refresh_xray_panel()


func _on_hybrid_search_completed(_res: Dictionary) -> void:
	_refresh_xray_panel()


func _present_recommendation_bundle(res: Dictionary, _trigger_src: String) -> void:
	var primary: Dictionary = res.get("primary_memory", {})
	var crop_p: String = str(primary.get("crop_path", ""))
	if crop_p != "":
		_update_crop_textures(crop_p)

	var talk: String = str(res.get("small_talk", "방금 유심히 본 사물에 맞춰 골라봤어!"))
	var prods: Array = res.get("products", [])

	rec_talk_label.text = talk
	if prods.size() >= 1 and prods[0] is Dictionary:
		var p1: Dictionary = prods[0]
		rec_prod1_label.text = "[%s] %s\n%s" % [str(p1.get("badge", "추천 1")), str(p1.get("title", "")), str(p1.get("desc", ""))]
	if prods.size() >= 2 and prods[1] is Dictionary:
		var p2: Dictionary = prods[1]
		rec_prod2_label.text = "[%s] %s\n%s" % [str(p2.get("badge", "추천 2")), str(p2.get("title", "")), str(p2.get("desc", ""))]

	# 현재 사용자 시야 기준 정령 옆 위치 재정렬 후 표시
	var cam_tf: Transform3D = xr_camera.global_transform
	var forward: Vector3 = -cam_tf.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() >= 0.001 else Vector3.FORWARD
	var right: Vector3 = forward.cross(Vector3.UP).normalized()
	rec_card_root.global_position = cam_tf.origin + forward * 0.94 - right * 0.20 + Vector3(0.0, -0.05, 0.0)
	_face_horizontal(rec_card_root, cam_tf.origin)
	rec_card_root.visible = true

	status_label.text = "딱 2가지만 골라봤어!"
	excited_timer = 2.4
	_speak_or_chime(talk, "recommend")
	_refresh_xray_panel()


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

	# 1) 새로 임계치 돌파해 중단기 메모리로 올라온 후보 수집
	var prom_raw: String = str(cam_plugin.call("popPromotedCandidatesJson"))
	if prom_raw != "[]" and prom_raw.length() > 2:
		var prom_arr: Variant = JSON.parse_string(prom_raw)
		if prom_arr is Array:
			for item: Variant in (prom_arr as Array):
				if item is Dictionary:
					memory_engine.ingest_promoted_candidate(item as Dictionary)

	# 2) 실시간 비전 상태(객체 트랙 + RGB 손 인식 + 폐기/승격 카운터) 갱신
	var vis_raw: String = str(cam_plugin.call("getVisionStateJson"))
	if vis_raw.length() > 4:
		var parsed: Variant = JSON.parse_string(vis_raw)
		if parsed is Dictionary:
			latest_vision_state = parsed as Dictionary
			_apply_vision_state_to_scene(latest_vision_state)


func _apply_vision_state_to_scene(vstate: Dictionary) -> void:
	var tracks: Array = vstate.get("tracks", []) if vstate.get("tracks") is Array else []
	var hands: Array = vstate.get("hands", []) if vstate.get("hands") is Array else []
	var fov_x: float = float(vstate.get("fovTanX", 0.76))
	var fov_y: float = float(vstate.get("fovTanY", 0.57))
	var off_x: float = float(vstate.get("camOffsetX", -0.032))
	var off_y: float = float(vstate.get("camOffsetY", 0.0))

	# 시선 중심 관심 사물 응시 피드백 (오버레이 OFF 상태에서도 정령의 에메랄드 빛 맥동으로 자연스럽게 전달!)
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

	gaze_focus_strength = max_roi_progress
	if max_roi_progress > 0.25 and excited_timer <= 0.05 and has_input_focus:
		status_label.text = "시선 집중: %s (%d%%)" % [top_roi_name, int(roundf(max_roi_progress * 100.0))]
	elif excited_timer <= 0.05:
		status_label.text = "함께 보고 있어" if has_input_focus else "백그라운드 공존 중"

	# A 오버레이가 켜져 있을 때만 3D BBox 메쉬 갱신 (평소 비용 0)
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
					" [중단기저장★]" if promoted else ""
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

	var latest_annot: String = "아직 새로 포착된 사물 없음"
	var latest_tier_badge: String = "-"
	if memory_engine.memories.size() > 0:
		var m0: Dictionary = memory_engine.memories[0]
		latest_annot = "[#%s] %s" % [str(m0.get("id", "")), str(m0.get("annotation", ""))]
		latest_tier_badge = "★장기 메모리(Promoted)" if str(m0.get("tier", "")) == "long_term" else "중단기 메모리(Mid-Term)"
		var cp: String = str(m0.get("crop_path", ""))
		if cp != "":
			_update_crop_textures(cp)

	var sr: Dictionary = memory_engine.last_search_result
	var vec_lines: Array[String] = []
	var lex_lines: Array[String] = []
	if not sr.is_empty():
		var v3: Array = sr.get("vector_top3", [])
		for item_v: Variant in v3:
			if item_v is Dictionary:
				var d: Dictionary = item_v as Dictionary
				var star: String = "★장기" if str(d.get("tier", "")) == "long_term" else "중단기"
				vec_lines.append("#%s %s(%.2f,%s)" % [str(d["id"]), str(d["label_ko"]), float(d["score"]), star])
		var l3: Array = sr.get("lexical_top3", [])
		for item_l: Variant in l3:
			if item_l is Dictionary:
				var dl: Dictionary = item_l as Dictionary
				var star2: String = "★장기" if str(dl.get("tier", "")) == "long_term" else "중단기"
				lex_lines.append("#%s %s(BM25 %.1f,%s)" % [str(dl["id"]), str(dl["label_ko"]), float(dl["score"]), star2])

	var vec_txt: String = " | ".join(PackedStringArray(vec_lines)) if vec_lines.size() > 0 else "(질문/추천 실행 시 Top-3 표시)"
	var lex_txt: String = " | ".join(PackedStringArray(lex_lines)) if lex_lines.size() > 0 else "(질문/추천 실행 시 Top-3 표시)"
	var mode_str: String = "1.항상추천" if proactive_mode else "2.물어볼때만"

	xray_text_label.text = (
		"파이프라인: 임계미달 즉시폐기 %d건 | 중단기 %d건 | ★장기승격 %d건 | 모드=%s\n" % [
			discarded_n, int(counts["mid_term"]), int(counts["long_term"]), mode_str
		]
		+ "손 인식: %s\n" % hand_summary
		+ "어노테이션(저가VLM): %s\n" % latest_annot
		+ "인덱싱: EmbeddingGemma-2 (768d) 완료 -> [%s]\n" % latest_tier_badge
		+ "벡터 Top-3: %s\n" % vec_txt
		+ "단어 Top-3: %s" % lex_txt
	)


func _update_bare_hand_tracker(
	tracker_path: StringName,
	joint_meshes: Array[MeshInstance3D],
	is_right: bool
) -> Dictionary:
	var out: Dictionary = {
		"active": false,
		"index_tip": Vector3.ZERO,
		"palm": Vector3.ZERO,
		"pinching": false,
		"pinch_just_pressed": false
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

	# 컨트롤러가 아닌 실제 맨손(UNOBSTRUCTED) 또는 유효 관절 추적 시 모두 수용
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
	var pinch_dist: float = thumb_pos.distance_to(index_pos)

	var prev_p: bool = right_pinch_prev if is_right else left_pinch_prev
	var now_p: bool = (pinch_dist < 0.021) if not prev_p else (pinch_dist < 0.032)
	var just_p: bool = now_p and not prev_p
	if is_right:
		right_pinch_prev = now_p
	else:
		left_pinch_prev = now_p

	# 핀치 시 손끝 구체 색상 강조
	var orb_col: Color = Color(1.0, 0.58, 0.90, 0.92) if now_p else Color(0.35, 1.0, 0.85, 0.72)
	for jm: MeshInstance3D in joint_meshes:
		(jm.material_override as StandardMaterial3D).albedo_color = orb_col

	out["active"] = true
	out["palm"] = palm_pos
	out["index_tip"] = index_pos
	out["pinching"] = now_p
	out["pinch_just_pressed"] = just_p
	return out


func _process_all_hand_interactions(delta: float) -> void:
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
	if openxr_bare_left_active:
		poke_points.append(left_info["index_tip"] as Vector3)
	elif left_hand.get_is_active():
		poke_points.append(left_hand.global_position)

	if openxr_bare_right_active:
		poke_points.append(right_info["index_tip"] as Vector3)
	elif right_hand.get_is_active():
		poke_points.append(right_hand.global_position)

	# RGB 카메라 기반 MediaPipe 손 인식 3D 투영 (컨트롤러도 없고 OpenXR 핸드트래킹이 비활성일 때도 손 상호작용 보장!)
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

			# OpenXR 맨손 추적이 꺼져 있을 때 RGB 손 포인터를 직접 물리 입력으로 사용
			if not openxr_bare_left_active and not openxr_bare_right_active:
				rgb_hand_orb.global_position = world_rgb_hand
				rgb_hand_orb.visible = true
				poke_points.append(world_rgb_hand)
				if rgb_just_pinched and world_rgb_hand.distance_to(spirit_root.global_position) < 0.36 and rune_cooldown <= 0.0:
					rune_cooldown = RUNE_COOLDOWN_SEC
					_action_trigger_query("RGB손핀치")
			else:
				rgb_hand_orb.visible = false
	else:
		rgb_hand_orb.visible = false
		rgb_pinch_prev = false

	# 오른손 맨손 핀치로 정령 근처에서 바로 질문/추천 실행
	if bool(right_info["pinch_just_pressed"]) and rune_cooldown <= 0.0:
		var r_tip: Vector3 = right_info["index_tip"]
		if r_tip.distance_to(spirit_root.global_position) < 0.30:
			rune_cooldown = RUNE_COOLDOWN_SEC
			_action_trigger_query("맨손핀치")
			return

	# 손 근접 여부 계산 -> 정령 하단 4개 룬 버튼 투명도 조절 및 검지 포크 판정
	var any_near_runes: bool = false
	for pt: Vector3 in poke_points:
		if pt.distance_to(spirit_runes_root.global_position) < 0.32:
			any_near_runes = true

		# 1) 정령 하단 공간 룬 버튼 터치 판정 (A / B / X / Y)
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
						_action_trigger_query("맨손룬터치")
					return

		# 2) 추천 카드가 열려 있을 때 맨손으로 [1번 찜 / 2번 찜 / 닫기] 터치 판정
		if rec_card_root.visible and rune_cooldown <= 0.0:
			for rb: Dictionary in rec_buttons:
				var bnode: Node3D = rb["node"]
				if pt.distance_to(bnode.global_position) < 0.042:
					rune_cooldown = RUNE_COOLDOWN_SEC
					var bid: String = str(rb["id"])
					if bid == "close":
						rec_card_root.visible = false
						_speak_or_chime("", "pinch")
					elif bid == "pick1":
						_show_toast("1번 추천 후보를 관심 목록에 담았어!", 1.8)
						_speak_or_chime("첫 번째 후보를 기억해 둘게.", "promote")
					elif bid == "pick2":
						_show_toast("2번 추천 후보를 관심 목록에 담았어!", 1.8)
						_speak_or_chime("두 번째 후보를 기억해 둘게.", "promote")
					return

		# 3) 연기 정령 본체 맨손/컨트롤러 물리 터치 반응
		var sp_dist: float = pt.distance_to(spirit_root.global_position)
		if sp_dist < 0.19 and excited_timer <= 0.25:
			var push_dir: Vector3 = (spirit_root.global_position - pt).normalized()
			if push_dir.length_squared() < 0.01:
				push_dir = Vector3.UP
			velocity += push_dir * 1.30 + Vector3(0.0, 0.42, 0.0)
			excited_timer = 1.35
			status_label.text = LINES_TOUCH[randi() % LINES_TOUCH.size()]
			_speak_or_chime("", "touch")

	_update_rune_highlights(any_near_runes)


func _process(delta: float) -> void:
	time_sec += delta
	vision_poll_timer += delta
	if vision_poll_timer >= 0.12:
		vision_poll_timer = 0.0
		_poll_vision_and_promotions()

	if toast_timer > 0.0:
		toast_timer = maxf(0.0, toast_timer - delta)
		if toast_timer == 0.0:
			toast_root.visible = false

	if not desktop_mode and not initialized_anchor and xr_camera.global_position.length_squared() > 0.01:
		_reanchor_near_user()

	if initialized_anchor and xr_camera.global_position.distance_to(home_pos) > 1.85:
		_reanchor_near_user()

	_process_all_hand_interactions(delta)

	if excited_timer > 0.0:
		excited_timer = maxf(0.0, excited_timer - delta)
	if indexed_pulse_timer > 0.0:
		indexed_pulse_timer = maxf(0.0, indexed_pulse_timer - delta)

	# 연기 정령 부유 물리 및 시선 응시 회전
	var bob := Vector3(
		sin(time_sec * 1.3) * 0.065,
		sin(time_sec * 2.1) * 0.050,
		cos(time_sec * 1.1) * 0.055
	)
	target_pos = home_pos + bob
	var spring_force: Vector3 = (target_pos - spirit_root.global_position) * 6.5
	velocity = (velocity + spring_force * delta) * exp(-4.2 * delta)
	spirit_root.global_position += velocity * delta

	var look_dir: Vector3 = xr_camera.global_position - spirit_root.global_position
	look_dir.y *= 0.35
	if look_dir.length_squared() > 0.001:
		var target_basis: Basis = Basis.looking_at(-look_dir.normalized(), Vector3.UP)
		spirit_root.global_transform.basis = spirit_root.global_transform.basis.slerp(target_basis, clampf(delta * 5.0, 0.0, 1.0))

	# 정령 하단 룬 바 위치 동기화
	spirit_runes_root.global_position = spirit_root.global_position + Vector3(0.0, -0.19, 0.02)
	_face_horizontal(spirit_runes_root, xr_camera.global_position)

	# 상태별 정령 색온도·맥동 표현 (평온 청록 -> 시선집중 에메랄드 -> 기억인덱싱 골드 -> 터치/발화 코랄핑크)
	var warm_touch: float = clampf(excited_timer / 1.4, 0.0, 1.0)
	var gold_mem: float = clampf(indexed_pulse_timer / 1.2, 0.0, 1.0)
	var gaze_em: float = clampf(gaze_focus_strength, 0.0, 1.0)

	var idle_albedo := Color(0.42, 0.86, 1.0)
	var gaze_albedo := Color(0.30, 1.0, 0.68)
	var gold_albedo := Color(1.0, 0.84, 0.34)
	var touch_albedo := Color(1.0, 0.54, 0.88)

	var blended: Color = idle_albedo.lerp(gaze_albedo, gaze_em * 0.85)
	blended = blended.lerp(gold_albedo, gold_mem * 0.85)
	blended = blended.lerp(touch_albedo, warm_touch * 0.90)

	for i in range(wisps.size()):
		var fi: float = float(i)
		var energy_boost: float = maxf(warm_touch, maxf(gold_mem, gaze_em * 0.6))
		if i > 0:
			var angle: float = time_sec * (1.4 + fi * 0.22) + fi * 1.7
			var orbit: float = 0.044 + 0.013 * fi + energy_boost * 0.032
			wisps[i].position = Vector3(
				cos(angle) * orbit,
				sin(time_sec * 2.4 + fi) * 0.042 + fi * 0.011 - 0.028,
				sin(angle * 0.9) * orbit * 0.75
			)
			var pulse: float = 1.0 + sin(time_sec * (3.2 + energy_boost * 2.0) + fi) * 0.14 + energy_boost * 0.22
			wisps[i].scale = Vector3.ONE * pulse
		var a_val: float = wisp_mats[i].albedo_color.a
		wisp_mats[i].albedo_color = Color(blended.r, blended.g, blended.b, a_val)
		wisp_mats[i].emission = blended.darkened(0.15)
