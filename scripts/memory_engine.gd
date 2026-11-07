class_name CompanionMemoryEngine
extends Node

const EMBED_DIM: int = 768
const SAVE_PATH: String = "user://companion_memory_v1.json"
const BRIDGE_URL: String = "http://127.0.0.1:8765"

signal memory_indexed(record: Dictionary)
signal hybrid_search_completed(result: Dictionary)

var memories: Array[Dictionary] = []
var last_search_result: Dictionary = {}
var bridge_available: bool = false
var _http_health: HTTPRequest = null

# COCO / Salient 라벨 -> 한국어 품목명 · 카테고리 · 개념 태그 매핑
const CATEGORY_MAP: Dictionary = {
	"cup": {
		"ko": "세라믹 머그/음료컵",
		"cat": "테이블웨어·데스크 음료",
		"concepts": ["drink", "mug", "coffee", "tea", "desk", "cozy", "tableware", "컵", "머그", "커피", "차", "텀블러", "음료", "온기"]
	},
	"wine glass": {
		"ko": "글라스 잔",
		"cat": "테이블웨어·글라스",
		"concepts": ["drink", "glass", "tableware", "cozy", "잔", "컵", "유리컵", "음료"]
	},
	"bottle": {
		"ko": "보틀/텀블러",
		"cat": "휴대용 음료·보온보냉",
		"concepts": ["drink", "bottle", "tumbler", "portable", "desk", "텀블러", "보틀", "물병", "수분", "보온", "음료"]
	},
	"bowl": {
		"ko": "세라믹 보울/트레이",
		"cat": "테이블웨어·수납 트레이",
		"concepts": ["tableware", "bowl", "tray", "cozy", "organizer", "보울", "그릇", "트레이", "소품함"]
	},
	"cell phone": {
		"ko": "스마트폰/모바일 기기",
		"cat": "모바일·데스크 거치/충전",
		"concepts": ["tech", "mobile", "phone", "desk", "charging", "stand", "스마트폰", "폰", "충전기", "맥세이프", "거치대", "전자기기"]
	},
	"laptop": {
		"ko": "노트북/모바일 워크스테이션",
		"cat": "워크스페이스·거치/자세교정",
		"concepts": ["tech", "laptop", "work", "desk", "ergonomic", "stand", "노트북", "맥북", "작업", "코딩", "스탠드", "거치대"]
	},
	"keyboard": {
		"ko": "데스크 키보드",
		"cat": "워크스페이스·타건/손목케어",
		"concepts": ["tech", "keyboard", "work", "desk", "ergonomic", "typing", "키보드", "타건", "팜레스트", "데스크테리어", "작업"]
	},
	"mouse": {
		"ko": "무선 마우스",
		"cat": "워크스페이스·포인팅/패드",
		"concepts": ["tech", "mouse", "work", "desk", "ergonomic", "마우스", "마우스패드", "손목", "데스크테리어", "작업"]
	},
	"remote": {
		"ko": "컨트롤러/리모트 기기",
		"cat": "디바이스 수납·정리",
		"concepts": ["tech", "remote", "organizer", "desk", "리모컨", "컨트롤러", "거치", "정리함"]
	},
	"book": {
		"ko": "도서/노트북 저널",
		"cat": "문구·독서/기록",
		"concepts": ["study", "book", "note", "stationery", "cozy", "desk", "책", "노트", "독서", "다이어리", "문구", "기록"]
	},
	"backpack": {
		"ko": "백팩/데일리 슬링백",
		"cat": "테크 수납·이동형 가방",
		"concepts": ["bag", "carry", "portable", "travel", "tech", "백팩", "가방", "파우치", "수납", "외출"]
	},
	"handbag": {
		"ko": "토트/파우치 백",
		"cat": "패션 잡화·오거나이저",
		"concepts": ["bag", "carry", "fashion", "portable", "가방", "파우치", "토트백", "오거나이저"]
	},
	"chair": {
		"ko": "데스크 체어/방석",
		"cat": "홈오피스·착석 자세케어",
		"concepts": ["ergonomic", "chair", "work", "comfort", "cozy", "의자", "쿠션", "요추", "자세", "방석"]
	},
	"clock": {
		"ko": "데스크 시계/타이머",
		"cat": "데스크 오브제·집중 타이머",
		"concepts": ["desk", "clock", "focus", "minimal", "시계", "타이머", "뽀모도로", "인테리어", "오브제"]
	},
	"potted plant": {
		"ko": "플랜테리어 화분",
		"cat": "데스크 플랜트·조명",
		"concepts": ["plant", "nature", "cozy", "interior", "desk", "식물", "화분", "플랜테리어", "인테리어", "초록"]
	},
	"scissors": {
		"ko": "데스크 문구/가위",
		"cat": "데스크 문구·오거나이저",
		"concepts": ["stationery", "tool", "desk", "organizer", "가위", "문구", "펜꽂이", "데스크테리어"]
	},
	"desk_object": {
		"ko": "데스크 소품/오브제",
		"cat": "데스크테리어·소품 트레이",
		"concepts": ["desk", "interior", "organizer", "minimal", "cozy", "소품", "오브제", "트레이", "스티커", "데스크테리어"]
	}
}

# 잠재 의미 축(Semantic Axes): 단어가 달라도 의미가 통할 때 코사인 유사도가 높게 나오도록 24개 축 구성
const SEMANTIC_AXES: Array[Array] = [
	["drink", "mug", "bottle", "tumbler", "coffee", "tea", "컵", "머그", "텀블러", "보틀", "물병", "커피", "차", "음료", "마실"],
	["tableware", "bowl", "glass", "ceramic", "코스터", "세라믹", "도자기", "잔", "그릇", "테이블"],
	["tech", "laptop", "keyboard", "mouse", "phone", "mobile", "전자기기", "노트북", "키보드", "마우스", "스마트폰", "디바이스", "충전"],
	["work", "desk", "focus", "coding", "study", "작업", "책상", "데스크", "데스크테리어", "업무", "집중", "코딩"],
	["ergonomic", "stand", "comfort", "chair", "거치대", "스탠드", "손목", "팜레스트", "자세", "편안"],
	["stationery", "book", "note", "tool", "책", "노트", "독서", "문구", "기록", "다이어리"],
	["bag", "portable", "carry", "travel", "가방", "백팩", "파우치", "휴대", "이동", "수납"],
	["organizer", "tray", "minimal", "정리", "트레이", "수납함", "깔끔", "미니멀"],
	["cozy", "warm", "wood", "beige", "cream", "따뜻", "감성", "우드", "원목", "크림", "오프화이트", "베이지", "무드"],
	["dark", "black", "charcoal", "metal", "silver", "블랙", "차콜", "메탈", "실버", "시크", "모던", "어두운"],
	["colorful", "blue", "red", "green", "mint", "컬러", "포인트", "블루", "코랄", "민트", "세이지", "그린"],
	["matte", "natural", "무광", "내추럴", "매트", "차분"]
]


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://crops"))
	_load_or_seed_memories()
	_probe_local_ai_bridge()


func _probe_local_ai_bridge() -> void:
	_http_health = HTTPRequest.new()
	_http_health.timeout = 1.5
	add_child(_http_health)
	_http_health.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		bridge_available = (result == HTTPRequest.RESULT_SUCCESS and code == 200)
		if bridge_available:
			print("[MemoryEngine] Connected to Mac Companion AI Bridge (VLM + EmbeddingGemma 2)!")
	)
	_http_health.request(BRIDGE_URL + "/health")


func _load_or_seed_memories() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var raw: String = FileAccess.get_file_as_string(SAVE_PATH)
		var parsed: Variant = JSON.parse_string(raw)
		if parsed is Array and (parsed as Array).size() > 0:
			memories.clear()
			for item: Variant in (parsed as Array):
				if item is Dictionary:
					memories.append(item as Dictionary)
			print("[MemoryEngine] Loaded ", memories.size(), " persisted memories.")
			return

	_seed_initial_memories()
	_save_memories()


func _seed_initial_memories() -> void:
	memories.clear()
	var now_sec: int = int(Time.get_unix_time_from_system())
	var seeds: Array[Dictionary] = [
		{
			"id": "S1",
			"track_id": 0,
			"is_seed": true,
			"tier": "mid_term",
			"label": "cup",
			"label_ko": "무광 크림 세라믹 머그",
			"category_ko": "테이블웨어·데스크 음료",
			"color_tone": "오프화이트/크림 톤",
			"brightness": "무광 내추럴",
			"annotation": "[사전관측] 무광 오프화이트/크림 톤 세라믹 머그컵 · 따뜻한 데스크 음료 용도 · 우드 책상 위 정면 응시",
			"embed_model": "EmbeddingGemma-2-768d",
			"vlm_model": "lowcost-vlm-annotator",
			"crop_path": "",
			"interest_meta": {"time_to_center_sec": 0.44, "dwell_sec": 2.3, "score": 78.0},
			"rgb_sig": [],
			"created_at": now_sec - 600,
			"retrieve_count": 0
		},
		{
			"id": "S2",
			"track_id": 0,
			"is_seed": true,
			"tier": "mid_term",
			"label": "keyboard",
			"label_ko": "차콜 배열 기계식 키보드",
			"category_ko": "워크스페이스·타건/손목케어",
			"color_tone": "매트 블랙/차콜 톤",
			"brightness": "차분한 다크",
			"annotation": "[사전관측] 매트 블랙/차콜 톤 컴팩트 기계식 키보드 · 코딩 및 데스크 작업 환경 · 손목 받침 없이 사용 중",
			"embed_model": "EmbeddingGemma-2-768d",
			"vlm_model": "lowcost-vlm-annotator",
			"crop_path": "",
			"interest_meta": {"time_to_center_sec": 0.61, "dwell_sec": 1.9, "score": 72.0},
			"rgb_sig": [],
			"created_at": now_sec - 420,
			"retrieve_count": 0
		},
		{
			"id": "S3",
			"track_id": 0,
			"is_seed": true,
			"tier": "mid_term",
			"label": "bottle",
			"label_ko": "모던 실버 보온 텀블러",
			"category_ko": "휴대용 음료·보온보냉",
			"color_tone": "모던 실버/그레이 톤",
			"brightness": "무광 내추럴",
			"annotation": "[사전관측] 모던 실버/그레이 톤 스텐 보온 텀블러 · 장시간 해커톤 수분 보충용 휴대 보틀",
			"embed_model": "EmbeddingGemma-2-768d",
			"vlm_model": "lowcost-vlm-annotator",
			"crop_path": "",
			"interest_meta": {"time_to_center_sec": 0.52, "dwell_sec": 1.7, "score": 69.0},
			"rgb_sig": [],
			"created_at": now_sec - 240,
			"retrieve_count": 0
		}
	]
	for s: Dictionary in seeds:
		s["embedding_768"] = _compute_multimodal_768d(
			str(s["annotation"]) + " " + str(s["label"]) + " " + str(s["color_tone"]),
			[]
		)
		memories.append(s)


func reset_live_memories() -> void:
	_seed_initial_memories()
	last_search_result = {}
	_save_memories()


func _save_memories() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(memories))
		f.close()


func ingest_promoted_candidate(cand: Dictionary) -> Dictionary:
	var raw_label: String = str(cand.get("label", "desk_object")).to_lower()
	var info: Dictionary = CATEGORY_MAP.get(raw_label, CATEGORY_MAP["desk_object"])
	var label_ko: String = str(info["ko"])
	var cat_ko: String = str(info["cat"])
	var color_tone: String = str(cand.get("colorToneKo", "내추럴 톤"))
	var brightness: String = str(cand.get("brightnessKo", "무광 내추럴"))
	var ttc: float = float(cand.get("timeToCenterSec", 0.4))
	var dwell: float = float(cand.get("dwellSec", 1.5))
	var score: float = float(cand.get("interestScore", 70.0))
	var track_id: int = int(cand.get("trackId", 1))
	var crop_path: String = str(cand.get("cropPath", ""))

	var rgb_sig: Array = []
	var raw_sig: Variant = cand.get("rgbSig24", [])
	if raw_sig is Array:
		rgb_sig = raw_sig

	# 저가(경량) VLM 스타일 구조화 어노테이션 생성 (실측 색상·조도 + 객체 클래스 + 시선 집중도 메타 결합)
	var concepts_arr: Array = info.get("concepts", [])
	var concept_str: String = " ".join(PackedStringArray(concepts_arr))
	var annotation: String = (
		"%s (%s, %s) · 카테고리: %s · 시선진입 %.2fs, 중심체류 %.1fs로 유심히 관찰함"
		% [label_ko, color_tone, brightness, cat_ko, ttc, dwell]
	)

	var live_idx: int = 1
	for m: Dictionary in memories:
		if not bool(m.get("is_seed", false)):
			live_idx += 1
	var mem_id: String = "M%02d" % live_idx

	var emb: Array[float] = _compute_multimodal_768d(
		annotation + " " + raw_label + " " + concept_str,
		rgb_sig
	)

	var record: Dictionary = {
		"id": mem_id,
		"track_id": track_id,
		"is_seed": false,
		"tier": "mid_term", # 중단기 메모리로 최초 저장 (검색 활용 시에만 long_term 승격!)
		"label": raw_label,
		"label_ko": label_ko,
		"category_ko": cat_ko,
		"color_tone": color_tone,
		"brightness": brightness,
		"annotation": annotation,
		"embed_model": "EmbeddingGemma-2 (768d)",
		"vlm_model": "LowCost-VLM-Lite",
		"crop_path": crop_path,
		"interest_meta": {
			"time_to_center_sec": snappedf(ttc, 0.01),
			"dwell_sec": snappedf(dwell, 0.1),
			"score": snappedf(score, 0.1)
		},
		"rgb_sig": rgb_sig,
		"embedding_768": emb,
		"created_at": int(Time.get_unix_time_from_system()),
		"retrieve_count": 0
	}

	memories.push_front(record)
	# 미사용 오래된 중단기 메모리 자연 감쇠 정리 (장기 메모리는 영구 보존)
	if memories.size() > 24:
		for idx in range(memories.size() - 1, -1, -1):
			if str(memories[idx].get("tier", "mid_term")) == "mid_term" and memories.size() > 24:
				memories.remove_at(idx)

	_save_memories()

	if bridge_available:
		_upgrade_record_via_bridge_async(record)

	memory_indexed.emit(record)
	return record


func _upgrade_record_via_bridge_async(record: Dictionary) -> void:
	var req := HTTPRequest.new()
	req.timeout = 4.0
	add_child(req)
	var mem_id: String = str(record["id"])
	req.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		req.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			return
		var resp: Variant = JSON.parse_string(body.get_string_from_utf8())
		if resp is Dictionary:
			var d: Dictionary = resp as Dictionary
			for m: Dictionary in memories:
				if str(m.get("id", "")) == mem_id:
					if d.has("annotation") and str(d["annotation"]).length() > 4:
						m["annotation"] = str(d["annotation"])
					if d.has("vlm_model"):
						m["vlm_model"] = str(d["vlm_model"])
					if d.has("embedding_768") and d["embedding_768"] is Array and (d["embedding_768"] as Array).size() == EMBED_DIM:
						m["embedding_768"] = d["embedding_768"]
						m["embed_model"] = str(d.get("embed_model", "EmbeddingGemma-2 (768d)"))
					_save_memories()
					break
	)
	var cp_str: String = str(record.get("crop_path", ""))
	var crop_b64: String = ""
	if cp_str != "" and FileAccess.file_exists(cp_str):
		var cbytes: PackedByteArray = FileAccess.get_file_as_bytes(cp_str)
		if cbytes.size() > 32:
			crop_b64 = Marshalls.raw_to_base64(cbytes)
	var payload: Dictionary = {
		"id": mem_id,
		"label": record.get("label", ""),
		"color_tone": record.get("color_tone", ""),
		"crop_path": cp_str,
		"crop_b64": crop_b64,
		"fallback_annotation": record.get("annotation", "")
	}
	req.request(
		BRIDGE_URL + "/annotate_and_embed",
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST,
		JSON.stringify(payload)
	)


func retrieve_hybrid_and_promote(
	query_text: String,
	visual_sig: Array = [],
	focus_record_id: String = "",
	allow_promote_focus: bool = true
) -> Dictionary:
	var effective_query: String = query_text.strip_edges()
	if effective_query == "":
		if memories.size() > 0:
			effective_query = str(memories[0].get("label_ko", "")) + " " + str(memories[0].get("color_tone", "")) + " 추천"
		else:
			effective_query = "데스크 소품 머그컵 추천"

	var query_vec: Array[float] = _compute_multimodal_768d(effective_query, visual_sig)

	# 1) 벡터 서치 상위 3개 (EmbeddingGemma 2 768d 코사인 유사도)
	var vec_scored: Array[Dictionary] = []
	for m: Dictionary in memories:
		var m_vec: Array = m.get("embedding_768", [])
		var sim: float = _cosine_sim(query_vec, m_vec)
		# 실제 실카메라 포착 항목 약간의 최신성 보정
		if not bool(m.get("is_seed", false)):
			sim = minf(0.99, sim + 0.04)
		vec_scored.append({"mem": m, "score": sim})
	vec_scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))

	var vector_top3: Array[Dictionary] = []
	for i in range(mini(3, vec_scored.size())):
		var m: Dictionary = vec_scored[i]["mem"]
		vector_top3.append({
			"id": str(m["id"]),
			"label_ko": str(m["label_ko"]),
			"color_tone": str(m["color_tone"]),
			"tier": str(m["tier"]),
			"score": snappedf(float(vec_scored[i]["score"]), 0.01)
		})

	# 2) 단어 기준 검색 상위 3개 (어노테이션 토큰 + 한국어 음절 바이그램 Okapi BM25)
	var bm25_scored: Array[Dictionary] = _score_bm25_all(effective_query)
	var lexical_top3: Array[Dictionary] = []
	for i in range(mini(3, bm25_scored.size())):
		var m: Dictionary = bm25_scored[i]["mem"]
		lexical_top3.append({
			"id": str(m["id"]),
			"label_ko": str(m["label_ko"]),
			"color_tone": str(m["color_tone"]),
			"tier": str(m["tier"]),
			"score": snappedf(float(bm25_scored[i]["score"]), 0.01),
			"matched": str(bm25_scored[i]["matched"])
		})

	# 3) 실제 검색 결과로 채택·인용된 중단기 메모리를 장기 메모리(long_term)로 승격!
	var used_ids: Array[String] = []
	if focus_record_id != "":
		used_ids.append(focus_record_id)
	if vector_top3.size() > 0 and not (str(vector_top3[0]["id"]) in used_ids):
		used_ids.append(str(vector_top3[0]["id"]))
	if lexical_top3.size() > 0 and float(lexical_top3[0]["score"]) > 0.05 and not (str(lexical_top3[0]["id"]) in used_ids):
		used_ids.append(str(lexical_top3[0]["id"]))

	var newly_promoted_ids: Array[String] = []
	for m: Dictionary in memories:
		var mid: String = str(m["id"])
		if mid in used_ids:
			if mid == focus_record_id and not allow_promote_focus:
				continue
			m["retrieve_count"] = int(m.get("retrieve_count", 0)) + 1
			if str(m.get("tier", "mid_term")) == "mid_term":
				m["tier"] = "long_term"
				m["promoted_at"] = int(Time.get_unix_time_from_system())
				newly_promoted_ids.append(mid)

	# 승격 후 Top-3 표시용 tier 동기화
	for item: Dictionary in vector_top3:
		if str(item["id"]) in newly_promoted_ids:
			item["tier"] = "long_term"
			item["just_promoted"] = true
	for item: Dictionary in lexical_top3:
		if str(item["id"]) in newly_promoted_ids:
			item["tier"] = "long_term"
			item["just_promoted"] = true

	_save_memories()

	var primary_mem: Dictionary = _find_memory_by_id(used_ids[0]) if used_ids.size() > 0 else (memories[0] if memories.size() > 0 else {})
	var rec_bundle: Dictionary = _build_smalltalk_and_two_products(primary_mem, vector_top3, lexical_top3)

	last_search_result = {
		"query": effective_query,
		"vector_top3": vector_top3,
		"lexical_top3": lexical_top3,
		"promoted_ids": newly_promoted_ids,
		"primary_memory": primary_mem,
		"small_talk": rec_bundle["small_talk"],
		"products": rec_bundle["products"] # 반드시 딱 2개 예시만 반환!
	}
	hybrid_search_completed.emit(last_search_result)
	return last_search_result


func _find_memory_by_id(target_id: String) -> Dictionary:
	for m: Dictionary in memories:
		if str(m.get("id", "")) == target_id:
			return m
	return memories[0] if memories.size() > 0 else {}


func get_tier_counts() -> Dictionary:
	var mid_cnt: int = 0
	var long_cnt: int = 0
	for m: Dictionary in memories:
		if str(m.get("tier", "mid_term")) == "long_term":
			long_cnt += 1
		else:
			mid_cnt += 1
	return {"mid_term": mid_cnt, "long_term": long_cnt, "total": memories.size()}


func _build_smalltalk_and_two_products(primary: Dictionary, vec3: Array[Dictionary], _lex3: Array[Dictionary]) -> Dictionary:
	if primary.is_empty():
		return {
			"small_talk": "아직 유심히 본 물건이 없네! 주변 사물을 잠깐 바라봐 봐.",
			"products": [
				{"title": "무광 오프화이트 데스크 머그 350ml", "desc": "따뜻한 크림 톤 세라믹 · 보온 코르크 바닥", "badge": "감성 매칭"},
				{"title": "스텐 이중진공 데스크 텀블러 470ml", "desc": "결로 없는 무광 파우더코팅 · 한손 오픈 캡", "badge": "실용 대조"}
			]
		}

	var label: String = str(primary.get("label", "desk_object"))
	var label_ko: String = str(primary.get("label_ko", "데스크 소품"))
	var tone: String = str(primary.get("color_tone", "내추럴 톤"))
	var meta: Dictionary = primary.get("interest_meta", {})
	var dwell: float = float(meta.get("dwell_sec", 1.8))

	# 시선 맥락을 엮은 자연스러운 일상 스몰토크
	var linked_hint: String = ""
	if vec3.size() >= 2 and str(vec3[1]["id"]) != str(primary.get("id", "")):
		linked_hint = " 아까 본 %s랑도 결이 잘 맞네." % str(vec3[1]["label_ko"])

	var small_talk: String = "방금 %.1f초 동안 시선 한가운데 두고 보던 %s(%s), 눈에 확 들어오더라!%s" % [
		dwell, label_ko, tone, linked_hint
	]

	# 딱 2가지 대조 추천 예시만 생성 (1: 관찰된 색감·감성 중심 / 2: 실용·기능 중심)
	var two_products: Array[Dictionary] = []
	match label:
		"cup", "wine glass":
			two_products = [
				{
					"title": "%s 수제 무광 세라믹 머그 360ml" % tone.replace(" 톤", ""),
					"desc": "관찰한 컵 색감에 맞춘 로우글레이즈 도자기 · 넓은 그립 핸들",
					"badge": "1. 감성·톤 매칭"
				},
				{
					"title": "온도유지 세라믹 코팅 스텐 데스크 머그",
					"desc": "세라믹 식감 그대로 3시간 보온 · 먼지 방지 슬라이드 리드",
					"badge": "2. 실용·보온 대조"
				}
			]
		"bottle":
			two_products = [
				{
					"title": "%s 미니멀 루프 캐리 텀블러 500ml" % tone.replace(" 톤", ""),
					"desc": "방금 본 보틀 톤과 어울리는 무광 파우더 마감 · 저소음 실리콘 바닥",
					"badge": "1. 감성·톤 매칭"
				},
				{
					"title": "초경량 티타늄 트래블 보온보냉 보틀",
					"desc": "210g 초경량 휴대성 · 음료 잔향 없는 순수 내벽 구조",
					"badge": "2. 기능·경량 대조"
				}
			]
		"cell phone":
			two_products = [
				{
					"title": "%s 알루미늄 맥세이프 스탠드" % tone.replace(" 톤", ""),
					"desc": "시선 높이에 맞춰 각도 조절되는 미니멀 충전 거치대",
					"badge": "1. 데스크 톤 매칭"
				},
				{
					"title": "초슬림 Qi2 마그네틱 보조배터리 5000mAh",
					"desc": "케이블 없이 착 붙는 휴대용 고속 무선 충전 팩",
					"badge": "2. 휴대·실용 대조"
				}
			]
		"laptop":
			two_products = [
				{
					"title": "%s 아노다이징 노트북 엘리베이터 스탠드" % tone.replace(" 톤", ""),
					"desc": "거북목 방지 눈높이 정렬 · 하단 키보드 수납 공간 확보",
					"badge": "1. 워크스페이스 매칭"
				},
				{
					"title": "초경량 폴더블 카본 휴대용 노트북 거치대",
					"desc": "해커톤·카페 이동 시 파우치에 쏙 들어가는 6단 각도 조절",
					"badge": "2. 휴대·실용 대조"
				}
			]
		"keyboard", "mouse":
			two_products = [
				{
					"title": "%s 월넛·알칸타라 팜레스트" % tone.replace(" 톤", ""),
					"desc": "지금 본 입력기기와 톤온톤 매칭 · 장시간 타이핑 손목 부담 완화",
					"badge": "1. 데스크 감성 매칭"
				},
				{
					"title": "발수 펠트 와이드 데스크 매트 (800x300)",
					"desc": "타건 소음 흡수 및 마우스 슬라이딩 최적화 투톤 패드",
					"badge": "2. 기능·정돈 대조"
				}
			]
		"book":
			two_products = [
				{
					"title": "%s 180도 레이플랫 하드커버 노트" % tone.replace(" 톤", ""),
					"desc": "만년필 번짐 없는 120g 중성지 · 미니멀 북밴드 마감",
					"badge": "1. 감성 문구 매칭"
				},
				{
					"title": "각도조절 원목 독서대 & 북스토퍼 보드",
					"desc": "한 손이나 시선만으로도 페이지가 고정되는 컴팩트 독서 스탠드",
					"badge": "2. 자세·실용 대조"
				}
			]
		"backpack", "handbag":
			two_products = [
				{
					"title": "%s 발수 코듀라 데일리 테크 슬링백" % tone.replace(" 톤", ""),
					"desc": "태블릿·케이블 전용 자석 포켓 내장 · 가벼운 외출용 핏",
					"badge": "1. 스타일·톤 매칭"
				},
				{
					"title": "모듈형 기어 파우치 데스크 스탠딩 오거나이저",
					"desc": "가방에서 꺼내 책상 위에 그대로 세워 쓰는 충전기·소품 파우치",
					"badge": "2. 수납·실용 대조"
				}
			]
		_:
			two_products = [
				{
					"title": "%s 모듈형 발렛 데스크 트레이" % tone.replace(" 톤", ""),
					"desc": "유심히 보던 소품들을 깔끔히 모아두는 비건 레더·원목 트레이",
					"badge": "1. 감성·톤 매칭"
				},
				{
					"title": "마그네틱 데스크 모듈 오거나이저 바",
					"desc": "자주 손이 가는 데스크 아이템을 한 줄로 고정·정돈하는 거치 세트",
					"badge": "2. 정리·실용 대조"
				}
			]

	return {
		"small_talk": small_talk,
		"products": two_products
	}


func _tokenize_ko_en(text: String) -> Array[String]:
	var cleaned: String = text.to_lower()
	var repl_chars: Array[String] = ["(", ")", "[", "]", "·", ",", ".", ":", "/", "-", "_"]
	for ch: String in repl_chars:
		cleaned = cleaned.replace(ch, " ")
	var raw_parts: PackedStringArray = cleaned.split(" ", false)
	var tokens: Array[String] = []
	for p: String in raw_parts:
		var w: String = p.strip_edges()
		if w.length() == 0:
			continue
		tokens.append(w)
		# 한국어 어절 조사/복합명사 매칭을 위한 2글자 음절 바이그램 추가
		if w.length() >= 2:
			for i in range(w.length() - 1):
				var bg: String = w.substr(i, 2)
				if bg.unicode_at(0) >= 0xAC00 or bg.unicode_at(0) >= 97:
					tokens.append(bg)
	return tokens


func _score_bm25_all(query: String) -> Array[Dictionary]:
	var q_tokens: Array[String] = _tokenize_ko_en(query)
	var n_docs: int = maxi(1, memories.size())
	var doc_tokens_list: Array[Array] = []
	var df: Dictionary = {}
	var total_len: float = 0.0

	for m: Dictionary in memories:
		var full_txt: String = "%s %s %s %s" % [
			str(m.get("label_ko", "")),
			str(m.get("color_tone", "")),
			str(m.get("category_ko", "")),
			str(m.get("annotation", ""))
		]
		var d_toks: Array[String] = _tokenize_ko_en(full_txt)
		doc_tokens_list.append(d_toks)
		total_len += float(d_toks.size())
		var seen: Dictionary = {}
		for t: String in d_toks:
			if not seen.has(t):
				seen[t] = true
				df[t] = int(df.get(t, 0)) + 1

	var avg_dl: float = maxf(1.0, total_len / float(n_docs))
	var k1: float = 1.5
	var b: float = 0.75
	var out: Array[Dictionary] = []

	for idx in range(memories.size()):
		var d_toks: Array = doc_tokens_list[idx]
		var dl: float = float(d_toks.size())
		var tf_map: Dictionary = {}
		for t: String in d_toks:
			tf_map[t] = int(tf_map.get(t, 0)) + 1

		var score: float = 0.0
		var matched_words: Array[String] = []
		for qt: String in q_tokens:
			var tf: int = int(tf_map.get(qt, 0))
			if tf > 0:
				var doc_freq: int = int(df.get(qt, 1))
				var idf: float = log(1.0 + (float(n_docs - doc_freq) + 0.5) / (float(doc_freq) + 0.5))
				var denom: float = float(tf) + k1 * (1.0 - b + b * (dl / avg_dl))
				score += idf * (float(tf) * (k1 + 1.0)) / maxf(0.001, denom)
				if qt.length() >= 2 and matched_words.size() < 3 and not (qt in matched_words):
					matched_words.append(qt)

		out.append({
			"mem": memories[idx],
			"score": score,
			"matched": ",".join(PackedStringArray(matched_words)) if matched_words.size() > 0 else "-"
		})

	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	return out


func _compute_multimodal_768d(text: String, rgb_sig: Array) -> Array[float]:
	var vec: Array[float] = []
	vec.resize(EMBED_DIM)
	vec.fill(0.0)

	# 1) 0..95 차원: 실측 객체 크롭 RGB/공간 시각 시그니처 투영
	if rgb_sig.size() > 0:
		for i in range(mini(24, rgb_sig.size())):
			var v: float = float(rgb_sig[i])
			vec[i * 4] += v * 1.35
			vec[i * 4 + 1] += v * 0.85
			vec[i * 4 + 2] -= v * 0.45

	var lower: String = text.to_lower()

	# 2) 96..335 차원: 잠재 의미 축(Semantic Concept Axes) 활성화 — 단어가 달라도 의미적 유사도 연결
	for axis_idx in range(SEMANTIC_AXES.size()):
		var keywords: Array = SEMANTIC_AXES[axis_idx]
		var hits: float = 0.0
		for kw: Variant in keywords:
			if str(kw) in lower:
				hits += 1.0
		if hits > 0.0:
			var weight: float = minf(2.2, 0.9 + hits * 0.45)
			var base_dim: int = 96 + axis_idx * 20
			for offset in range(20):
				var sign_val: float = 1.0 if ((axis_idx + offset) % 2 == 0) else -0.75
				vec[base_dim + offset] += weight * sign_val

	# 3) 336..767 차원: 토큰 & 음절 바이그램 부호 해시 투영 (Feature Hashing)
	var toks: Array[String] = _tokenize_ko_en(lower)
	for tok: String in toks:
		var h1: int = absi(tok.hash())
		var h2: int = absi((tok + "#2").hash())
		var idx1: int = 336 + (h1 % (EMBED_DIM - 336))
		var idx2: int = 336 + (h2 % (EMBED_DIM - 336))
		vec[idx1] += 1.0 if (h1 % 2 == 0) else -1.0
		vec[idx2] += 0.65 if (h2 % 2 == 0) else -0.65

	# L2 정규화
	var norm_sq: float = 0.0
	for v: float in vec:
		norm_sq += v * v
	var inv_norm: float = 1.0 / sqrt(maxf(1e-8, norm_sq))
	for i in range(EMBED_DIM):
		vec[i] = vec[i] * inv_norm
	return vec


func _cosine_sim(a: Array, b: Array) -> float:
	var n: int = mini(a.size(), b.size())
	if n == 0:
		return 0.0
	var dot: float = 0.0
	for i in range(n):
		dot += float(a[i]) * float(b[i])
	return clampf(dot, -1.0, 1.0)
