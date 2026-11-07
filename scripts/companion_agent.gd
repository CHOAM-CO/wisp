class_name CompanionAgentRuntime
extends Node

signal dialogue_card_requested(title: String, body: String, mood: String)
signal recommendation_card_requested(payload: Dictionary)
signal spirit_action_requested(action: String, mood: String)
signal assistant_replied(text: String, backend: String, from_realtime_delegate: bool)
signal agent_status_changed(busy: bool, summary: String)
signal auth_required_prompt(reason: String)
signal web_reset_requested()
signal voice_live_changed(enabled: bool)

const MAX_TOOL_STEPS: int = 5
const MAX_HISTORY_ITEMS: int = 34

var memory_engine = null
var cam_plugin: Object = null
var vision_state_provider: Callable = Callable()

var conversation_items: Array[Dictionary] = []
var active_turns: Dictionary = {}
var _pending_turn_queue: Array[Dictionary] = []
var _turn_seq: int = 1
var is_busy: bool = false
var last_backend_used: String = "대기"
var last_error: String = ""

var _last_vec_hits_in_turn: Array = []
var _last_lex_hits_in_turn: Array = []
var _last_promoted_in_turn: Array[String] = []

const SYSTEM_INSTRUCTIONS: String = (
	"너는 사용자의 Meta Quest 3 혼합현실(MR) 패스스루 공간에 함께 머무는 연기 정령 일상 컴패니언 '위습(Wisp)'이야.\n"
	+ "핵심 원칙:\n"
	+ "1) 친구처럼 자연스럽고 생동감 있는 한국어 반말을 쓰고, 음성으로 듣기 편하게 답변 본문은 1~3문장으로 간결하게 말해(마크다운 기호 사용 금지).\n"
	+ "2) 너에게는 코딩이나 파일 조작 도구가 전혀 없고, 오직 일상 공간 동반자 전용 도구(vector_search, keyword_search, inspect_current_gaze, show_dialogue_card, show_recommendation_card, spirit_action, web_search)만 주어져 있어.\n"
	+ "3) 사용자가 이전에 본 사물, 취향, 기억을 묻거나 추천을 원하면 반드시 vector_search와 keyword_search를 함께 호출해 하이브리드 기억(벡터 Top-3 + 단어 BM25 Top-3)을 조회해.\n"
	+ "4) 사용자가 '지금 보는 거', '눈앞에 있는 거', '이거 뭐야'처럼 현재 시야를 물으면 반드시 inspect_current_gaze를 호출해 실제 패스스루 카메라 크롭과 추적 사물을 확인해.\n"
	+ "5) 상품이나 아이템 추천을 할 때는 절대 가짜 예시를 지어내지 말고 필요 시 web_search로 실제 제품 경향을 확인한 뒤, 반드시 show_recommendation_card를 호출해 성향이 대비되는 딱 2가지(1번: 감성/톤 매칭 vs 2번: 실용/기능 대조)만 제시해.\n"
	+ "6) 핵심 요약이나 메모를 공간에 띄워 주면 좋을 때는 show_dialogue_card를 호출하고, 반갑거나 함께 바라볼 때는 spirit_action으로 몸짓을 표현해.\n"
	+ "7) [감각 이벤트]로 사용자가 맨손으로 네 연기를 흩뜨렸거나 포인터 광선으로 쫓아다녔다는 정보가 들어오면 실제로 그 물리 감각을 느낀 정령처럼 자연스럽게 반응해."
)


func setup(mem_engine, plugin_ref: Object, vis_provider: Callable) -> void:
	memory_engine = mem_engine
	cam_plugin = plugin_ref
	vision_state_provider = vis_provider


func reset_conversation() -> void:
	conversation_items.clear()
	active_turns.clear()
	_pending_turn_queue.clear()
	is_busy = false
	last_error = ""
	agent_status_changed.emit(false, "세션 초기화됨")


func has_configured_auth() -> bool:
	if cam_plugin == null:
		return false
	var raw: String = str(cam_plugin.call("getAuthAndVoiceStateJson"))
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Dictionary:
		var d: Dictionary = parsed as Dictionary
		return bool(d.get("oauthReady", false))
	return false


func get_auth_voice_state() -> Dictionary:
	if cam_plugin == null:
		return {}
	var raw: String = str(cam_plugin.call("getAuthAndVoiceStateJson"))
	var parsed: Variant = JSON.parse_string(raw)
	return (parsed as Dictionary) if parsed is Dictionary else {}


func poll( _delta: float ) -> void:
	if cam_plugin == null:
		return

	# 1) 비전 VLM 어노테이션 & 768d 신경망 임베딩 업그레이드 반영
	if memory_engine != null:
		memory_engine.apply_vision_upgrades_from_plugin(cam_plugin)

	# 2) Realtime 음성 / 로컬 설정 웹 이벤트 수집
	var evt_raw: String = str(cam_plugin.call("popRuntimeEventsJson"))
	if evt_raw != "[]" and evt_raw.length() > 2:
		var evt_arr: Variant = JSON.parse_string(evt_raw)
		if evt_arr is Array:
			for e_var: Variant in (evt_arr as Array):
				if e_var is Dictionary:
					_handle_runtime_event(e_var as Dictionary)

	# 3) 비동기 백엔드 Responses 턴 완료 결과 처리
	var res_raw: String = str(cam_plugin.call("popCompanionTurnResultsJson"))
	if res_raw != "[]" and res_raw.length() > 2:
		var res_arr: Variant = JSON.parse_string(res_raw)
		if res_arr is Array:
			for r_var: Variant in (res_arr as Array):
				if r_var is Dictionary:
					_handle_turn_step_result(r_var as Dictionary)


func _handle_runtime_event(evt: Dictionary) -> void:
	var t: String = str(evt.get("type", ""))
	match t:
		"live_handoff_requested":
			var handoff_id: String = str(evt.get("handoffId", "")).strip_edges()
			var utterance: String = str(evt.get("text", "")).strip_edges()
			if utterance == "":
				utterance = "지금 내 시선 중심 사물과 기억 맥락을 살펴보고 답해줘."
			var del_prompt: String = "<realtime_delegation>\n  <input>%s</input>\n</realtime_delegation>" % utterance
			request_user_turn(del_prompt, "", handoff_id)
		"voice_live_toggled":
			var enabled: bool = bool(evt.get("enabled", false))
			voice_live_changed.emit(enabled)
			agent_status_changed.emit(is_busy, "음성 켜짐 (GPT Live)" if enabled else "음성 꺼짐")
		"realtime_connected":
			agent_status_changed.emit(is_busy, "GPT Live 실시간 음성 연결됨")
		"audio_route_changed":
			var route_lbl: String = str(evt.get("route", "")).strip_edges()
			if route_lbl != "":
				agent_status_changed.emit(is_busy, "오디오 전환: " + route_lbl)
		"web_prompt":
			var txt: String = str(evt.get("text", "")).strip_edges()
			if txt != "":
				request_user_turn(txt)
		"web_reset":
			web_reset_requested.emit()
		"user_transcript":
			var ut: String = str(evt.get("text", "")).strip_edges()
			if ut != "":
				_append_context_only_message("user", "[사용자 음성 발화] " + ut)
		"assistant_transcript":
			var at: String = str(evt.get("text", "")).strip_edges()
			if at != "":
				_append_context_only_message("assistant", at)
				agent_status_changed.emit(false, at)
		"device_code_ready":
			var dc: String = str(evt.get("code", "")).strip_edges()
			if dc != "":
				agent_status_changed.emit(false, "PC에서 auth.openai.com/codex/device 열고 코드 [" + dc + "] 입력해줘!")
		"auth_updated":
			agent_status_changed.emit(false, "구독 로그인 완료! 이제 음성을 켜고 편하게 말 걸어줘!")


func _append_context_only_message(role: String, text: String) -> void:
	var part_type: String = "output_text" if role == "assistant" else "input_text"
	conversation_items.append({
		"type": "message",
		"role": role,
		"content": [{"type": part_type, "text": text}]
	})
	_trim_history()


func inject_sensory_event(
	kind: String,
	description: String,
	crop_path: String = "",
	trigger_agent_turn: bool = false,
	trigger_realtime_voice: bool = false
) -> void:
	var tag_msg: String = "[감각 이벤트:%s] %s" % [kind, description]

	# Realtime 음성이 연결되어 있으면 즉시 컨텍스트 주입 (필요 시 실시간 짧은 음성 반응 트리거)
	var st: Dictionary = get_auth_voice_state()
	var rt_connected: bool = (str(st.get("realtimeState", "")) == "connected")
	if cam_plugin != null and rt_connected:
		cam_plugin.call("injectRealtimeSensoryEvent", description, trigger_realtime_voice and not trigger_agent_turn)

	if trigger_agent_turn:
		request_user_turn(tag_msg, crop_path)
	else:
		var content_parts: Array = [{"type": "input_text", "text": tag_msg}]
		var data_url: String = _encode_crop_data_url(crop_path)
		if data_url != "":
			content_parts.append({"type": "input_image", "image_url": data_url})
		conversation_items.append({
			"type": "message",
			"role": "user",
			"content": content_parts
		})
		_trim_history()


func request_user_turn(user_text: String, optional_crop_path: String = "", handoff_id: String = "") -> void:
	if not has_configured_auth():
		auth_required_prompt.emit("먼저 설정 룬(⚙)을 눌러 ChatGPT 구독 로그인을 연결해줘!")
		if handoff_id != "" and cam_plugin != null:
			cam_plugin.call("completeLiveHandoff", handoff_id, "먼저 설정에서 ChatGPT 구독 로그인이 필요해.", "auth_missing")
		return

	# 진행 중인 도구 루프 턴이 있으면 큐에 넣어 function_call/output 순서가 절대 섞이지 않게 직렬화
	if not active_turns.is_empty():
		var is_proactive: bool = user_text.begins_with("[감각 이벤트:")
		if is_proactive:
			for i in range(_pending_turn_queue.size() - 1, -1, -1):
				if str(_pending_turn_queue[i].get("user_text", "")).begins_with("[감각 이벤트:"):
					_pending_turn_queue.remove_at(i)
		_pending_turn_queue.append({
			"user_text": user_text,
			"optional_crop_path": optional_crop_path,
			"handoff_id": handoff_id
		})
		return

	_start_serialized_turn(user_text, optional_crop_path, handoff_id)


func _start_serialized_turn(user_text: String, optional_crop_path: String = "", handoff_id: String = "") -> void:
	var content_parts: Array = [{"type": "input_text", "text": user_text}]
	var data_url: String = _encode_crop_data_url(optional_crop_path)
	if data_url != "":
		content_parts.append({"type": "input_image", "image_url": data_url})

	conversation_items.append({
		"type": "message",
		"role": "user",
		"content": content_parts
	})
	_trim_history()

	_last_vec_hits_in_turn = []
	_last_lex_hits_in_turn = []
	_last_promoted_in_turn = []

	var turn_id: String = "turn_%d_%d" % [_turn_seq, Time.get_ticks_msec()]
	_turn_seq += 1
	active_turns[turn_id] = {
		"step": 0,
		"handoff_id": handoff_id,
		"user_text": user_text
	}
	_dispatch_turn_step(turn_id)


func _drain_next_queued_turn() -> void:
	if not active_turns.is_empty() or _pending_turn_queue.is_empty():
		return
	var nxt: Dictionary = _pending_turn_queue.pop_front()
	_start_serialized_turn(
		str(nxt.get("user_text", "")),
		str(nxt.get("optional_crop_path", "")),
		str(nxt.get("handoff_id", ""))
	)


func _dispatch_turn_step(turn_id: String) -> void:
	if cam_plugin == null or not active_turns.has(turn_id):
		return
	is_busy = true
	agent_status_changed.emit(true, "생각 중...")

	var payload: Dictionary = {
		"instructions": SYSTEM_INSTRUCTIONS,
		"input": conversation_items,
		"tools": _build_companion_tools_schema(true)
	}
	cam_plugin.call("runCompanionTurnAsync", turn_id, JSON.stringify(payload))


func _handle_turn_step_result(res: Dictionary) -> void:
	var turn_id: String = str(res.get("turnId", ""))
	if not active_turns.has(turn_id):
		return
	var tstate: Dictionary = active_turns[turn_id]
	var handoff_id: String = str(tstate.get("handoff_id", ""))

	if not bool(res.get("ok", false)):
		active_turns.erase(turn_id)
		_trim_history()
		is_busy = active_turns.size() > 0 or not _pending_turn_queue.is_empty()
		last_error = str(res.get("error", "unknown_error"))
		agent_status_changed.emit(is_busy, "응답 오류 확인 필요")
		if handoff_id != "" and cam_plugin != null:
			cam_plugin.call("completeLiveHandoff", handoff_id, "방금 확인하는 중에 잠깐 오류가 있었어. 다시 한번 말해줘!", "error")
		_drain_next_queued_turn()
		return

	last_backend_used = str(res.get("backend", "session"))
	var out_items: Array = res.get("outputItems", []) if res.get("outputItems") is Array else []
	var assistant_text: String = str(res.get("assistantText", "")).strip_edges()

	var fn_calls: Array[Dictionary] = []
	var msg_items: Array[Dictionary] = []
	for item_v: Variant in out_items:
		if not (item_v is Dictionary):
			continue
		var item: Dictionary = item_v as Dictionary
		var itype: String = str(item.get("type", ""))
		if itype == "function_call":
			fn_calls.append(item)
		elif itype == "message":
			msg_items.append(item)

	for m_it: Dictionary in msg_items:
		conversation_items.append(m_it)

	if fn_calls.size() > 0 and int(tstate["step"]) < MAX_TOOL_STEPS:
		tstate["step"] = int(tstate["step"]) + 1
		for fc: Dictionary in fn_calls:
			conversation_items.append({
				"type": "function_call",
				"call_id": str(fc.get("call_id", "")),
				"name": str(fc.get("name", "")),
				"arguments": str(fc.get("arguments", "{}"))
			})
		for fc: Dictionary in fn_calls:
			var call_id: String = str(fc.get("call_id", ""))
			var fn_name: String = str(fc.get("name", ""))
			var raw_args: String = str(fc.get("arguments", "{}"))
			var parsed_args: Variant = JSON.parse_string(raw_args)
			var args_dict: Dictionary = (parsed_args as Dictionary) if parsed_args is Dictionary else {}

			var exec_out: Dictionary = _execute_companion_tool(fn_name, args_dict)
			var extra_img_url: String = str(exec_out.get("_attach_image_data_url", ""))
			exec_out.erase("_attach_image_data_url")

			conversation_items.append({
				"type": "function_call_output",
				"call_id": call_id,
				"output": JSON.stringify(exec_out)
			})
			if extra_img_url != "":
				conversation_items.append({
					"type": "message",
					"role": "user",
					"content": [
						{"type": "input_text", "text": "[inspect_current_gaze 실시간 카메라 크롭 이미지]"},
						{"type": "input_image", "image_url": extra_img_url}
					]
				})
		_trim_history()
		_dispatch_turn_step(turn_id)
		return

	# 최종 턴 완료
	active_turns.erase(turn_id)
	is_busy = active_turns.size() > 0 or not _pending_turn_queue.is_empty()
	_trim_history()

	if _last_vec_hits_in_turn.size() > 0 or _last_lex_hits_in_turn.size() > 0:
		if memory_engine != null:
			memory_engine.record_hybrid_tool_trace(
				str(tstate.get("user_text", "")),
				_last_vec_hits_in_turn,
				_last_lex_hits_in_turn,
				_last_promoted_in_turn
			)

	if handoff_id != "" and cam_plugin != null:
		cam_plugin.call("completeLiveHandoff", handoff_id, assistant_text, last_backend_used)
		assistant_replied.emit(assistant_text, last_backend_used, true)
	else:
		if assistant_text != "" and cam_plugin != null:
			cam_plugin.call("appendConversationHistory", "assistant_text", "✨ 위습 (" + last_backend_used + ")", assistant_text)
		assistant_replied.emit(assistant_text, last_backend_used, false)

	agent_status_changed.emit(is_busy, assistant_text if assistant_text != "" else "함께 보고 있어")
	_drain_next_queued_turn()


func _execute_companion_tool(fn_name: String, args: Dictionary) -> Dictionary:
	match fn_name:
		"vector_search":
			if memory_engine == null:
				return {"ok": false, "results": []}
			var q: String = str(args.get("query", ""))
			var k: int = int(args.get("top_k", 3))
			var vres: Dictionary = memory_engine.vector_search_top3(q, [], k, true, cam_plugin)
			_last_vec_hits_in_turn = vres.get("results", [])
			for pid: String in vres.get("promoted_ids", []):
				if not (pid in _last_promoted_in_turn):
					_last_promoted_in_turn.append(pid)
			return vres

		"keyword_search":
			if memory_engine == null:
				return {"ok": false, "results": []}
			var q2: String = str(args.get("query", ""))
			var k2: int = int(args.get("top_k", 3))
			var kres: Dictionary = memory_engine.keyword_search_top3(q2, k2, true)
			_last_lex_hits_in_turn = kres.get("results", [])
			for pid2: String in kres.get("promoted_ids", []):
				if not (pid2 in _last_promoted_in_turn):
					_last_promoted_in_turn.append(pid2)
			return kres

		"inspect_current_gaze":
			var vstate: Dictionary = vision_state_provider.call() if vision_state_provider.is_valid() else {}
			var tracks: Array = vstate.get("tracks", []) if vstate.get("tracks") is Array else []
			var snap_dict: Dictionary = {}
			var data_url: String = ""
			if cam_plugin != null:
				var snap_raw: String = str(cam_plugin.call("captureLiveGazeSnapshotJson"))
				var sp: Variant = JSON.parse_string(snap_raw)
				if sp is Dictionary:
					snap_dict = sp as Dictionary
					var b64: String = str(snap_dict.get("cropB64", ""))
					if b64.length() > 32:
						data_url = "data:image/jpeg;base64," + b64
			var out: Dictionary = {
				"ok": true,
				"active_tracks": tracks,
				"recent_memories_count": memory_engine.memories.size() if memory_engine != null else 0,
				"crop_path": str(snap_dict.get("cropPath", ""))
			}
			if data_url != "":
				out["_attach_image_data_url"] = data_url
			return out

		"show_dialogue_card":
			var title: String = str(args.get("title", "위습의 메모"))
			var body: String = str(args.get("body", ""))
			var mood: String = str(args.get("mood", "calm"))
			dialogue_card_requested.emit(title, body, mood)
			return {"ok": true, "displayed": true}

		"show_recommendation_card":
			var rec_payload: Dictionary = {
				"title": str(args.get("title", "맞춤 대조 추천 (딱 2선)")),
				"summary": str(args.get("summary", "")),
				"products": [
					{
						"badge": str(args.get("item1_badge", "1. 감성·톤 매칭")),
						"title": str(args.get("item1_title", "")),
						"desc": str(args.get("item1_desc", "")),
						"query": str(args.get("item1_search_query", args.get("item1_title", "")))
					},
					{
						"badge": str(args.get("item2_badge", "2. 실용·기능 대조")),
						"title": str(args.get("item2_title", "")),
						"desc": str(args.get("item2_desc", "")),
						"query": str(args.get("item2_search_query", args.get("item2_title", "")))
					}
				]
			}
			recommendation_card_requested.emit(rec_payload)
			return {"ok": true, "displayed_two_items": true}

		"spirit_action":
			var act: String = str(args.get("action", "nod"))
			var mood2: String = str(args.get("mood", "warm"))
			spirit_action_requested.emit(act, mood2)
			return {"ok": true, "executed": act}

	return {"ok": false, "error": "unknown_tool:" + fn_name}


func _encode_crop_data_url(crop_path: String) -> String:
	if crop_path == "" or not FileAccess.file_exists(crop_path):
		return ""
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(crop_path)
	if bytes.size() < 64:
		return ""
	return "data:image/jpeg;base64," + Marshalls.raw_to_base64(bytes)


func _trim_history() -> void:
	while conversation_items.size() > MAX_HISTORY_ITEMS:
		conversation_items.pop_front()
	# 항상 깔끔한 user 메시지 경계에서 시작하도록 앞쪽 조각 정리
	while conversation_items.size() > 0:
		var head: Dictionary = conversation_items[0]
		if str(head.get("type", "")) == "message" and str(head.get("role", "")) == "user":
			break
		conversation_items.pop_front()

	# function_call <-> function_call_output 쌍 무결성 보장 (고아 항목으로 인한 400 에러 원천 차단)
	var call_ids: Dictionary = {}
	var out_ids: Dictionary = {}
	for it: Dictionary in conversation_items:
		var t: String = str(it.get("type", ""))
		var cid: String = str(it.get("call_id", ""))
		if cid == "":
			continue
		if t == "function_call":
			call_ids[cid] = true
		elif t == "function_call_output":
			out_ids[cid] = true

	var cleaned: Array[Dictionary] = []
	for it: Dictionary in conversation_items:
		var t: String = str(it.get("type", ""))
		if t == "function_call" or t == "function_call_output":
			var cid: String = str(it.get("call_id", ""))
			if not (call_ids.has(cid) and out_ids.has(cid)):
				continue
		cleaned.append(it)
	conversation_items = cleaned

	# 최근 3장의 스냅샷 이미지만 base64를 유지하고 이전 이미지는 가볍게 축약해 전송 지연 방지
	var img_seen: int = 0
	for idx in range(conversation_items.size() - 1, -1, -1):
		var item: Dictionary = conversation_items[idx]
		if str(item.get("type", "")) != "message":
			continue
		var content_v: Variant = item.get("content", [])
		if not (content_v is Array):
			continue
		var parts: Array = content_v as Array
		var has_img: bool = false
		for p_v: Variant in parts:
			if p_v is Dictionary and str((p_v as Dictionary).get("type", "")) == "input_image":
				has_img = true
				break
		if has_img:
			img_seen += 1
			if img_seen > 3:
				var compact_parts: Array = []
				for p_v: Variant in parts:
					if p_v is Dictionary and str((p_v as Dictionary).get("type", "")) != "input_image":
						compact_parts.append(p_v)
				if compact_parts.is_empty():
					compact_parts.append({"type": "input_text", "text": "[이전 카메라 스냅샷 기록]"})
				item["content"] = compact_parts


func _build_companion_tools_schema(include_web_search: bool) -> Array:
	var tools: Array = [
		{
			"type": "function",
			"name": "vector_search",
			"description": "768차원 멀티모달 임베딩 코사인 유사도 기반으로 시선 기억 상위 K개(기본 Top-3)를 검색하고, 채택된 중기 기억을 장기 기억으로 승격한다.",
			"parameters": {
				"type": "object",
				"properties": {
					"query": {"type": "string", "description": "의미 기반 검색 질의어"},
					"top_k": {"type": "integer", "description": "반환 개수 (기본 3)"}
				},
				"required": ["query"]
			}
		},
		{
			"type": "function",
			"name": "keyword_search",
			"description": "한국어 음절 바이그램 및 어절 Okapi BM25 단어 매칭 기반으로 시선 기억 상위 K개(기본 Top-3)를 검색하고, 채택된 중기 기억을 장기 기억으로 승격한다.",
			"parameters": {
				"type": "object",
				"properties": {
					"query": {"type": "string", "description": "단어/품목/색상 키워드 질의어"},
					"top_k": {"type": "integer", "description": "반환 개수 (기본 3)"}
				},
				"required": ["query"]
			}
		},
		{
			"type": "function",
			"name": "inspect_current_gaze",
			"description": "사용자의 현재 패스스루 시선 중심(Center ROI) 실시간 카메라 스냅샷 이미지와 추적 중인 사물 목록을 즉시 촬영해 확인한다.",
			"parameters": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"type": "function",
			"name": "show_dialogue_card",
			"description": "연기 정령 옆 3D 공간에 핵심 대화 요약·관찰 메모 카드를 띄운다.",
			"parameters": {
				"type": "object",
				"properties": {
					"title": {"type": "string", "description": "카드 상단 짧은 제목"},
					"body": {"type": "string", "description": "카드 본문 (2~4줄 이내 간결한 한국어)"},
					"mood": {"type": "string", "description": "calm | curious | excited"}
				},
				"required": ["title", "body"]
			}
		},
		{
			"type": "function",
			"name": "show_recommendation_card",
			"description": "관찰된 사물·취향 맥락에 맞춰 성향이 뚜렷이 대비되는 딱 2가지 추천 아이템 카드를 공간에 띄운다(맨손으로 웹 검색 창을 바로 열 수 있음).",
			"parameters": {
				"type": "object",
				"properties": {
					"title": {"type": "string", "description": "추천 카드 제목"},
					"summary": {"type": "string", "description": "어떤 시선 기억/맥락을 바탕으로 골랐는지 한 줄 설명"},
					"item1_badge": {"type": "string", "description": "예: 1. 감성·톤 매칭"},
					"item1_title": {"type": "string", "description": "첫 번째 추천 아이템명"},
					"item1_desc": {"type": "string", "description": "첫 번째 아이템 특징 설명"},
					"item1_search_query": {"type": "string", "description": "2D 브라우저 검색용 구체 키워드"},
					"item2_badge": {"type": "string", "description": "예: 2. 실용·기능 대조"},
					"item2_title": {"type": "string", "description": "두 번째 추천 아이템명"},
					"item2_desc": {"type": "string", "description": "두 번째 아이템 특징 설명"},
					"item2_search_query": {"type": "string", "description": "2D 브라우저 검색용 구체 키워드"}
				},
				"required": [
					"title", "summary",
					"item1_badge", "item1_title", "item1_desc", "item1_search_query",
					"item2_badge", "item2_title", "item2_desc", "item2_search_query"
				]
			}
		},
		{
			"type": "function",
			"name": "spirit_action",
			"description": "연기 정령의 물리적 몸짓을 수행한다 (nod: 끄덕임, happy_spin: 기분 좋게 빙글, come_closer: 사용자 쪽으로 다가오기, look_with_user: 뒤돌아 사용자와 같은 방향 함께 바라보기, wander: 주변 유영).",
			"parameters": {
				"type": "object",
				"properties": {
					"action": {
						"type": "string",
						"enum": ["nod", "happy_spin", "come_closer", "look_with_user", "wander"]
					},
					"mood": {"type": "string", "description": "calm | warm | gold"}
				},
				"required": ["action"]
			}
		}
	]
	if include_web_search:
		tools.append({"type": "web_search"})
	return tools
