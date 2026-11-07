class_name CompanionMemoryEngine
extends Node

const EMBED_DIM: int = 768
const SAVE_PATH: String = "user://wisp_memories_live.json"

signal memory_indexed(record: Dictionary)
signal memory_upgraded(record: Dictionary)
signal hybrid_search_completed(result: Dictionary)

var memories: Array[Dictionary] = []
var last_search_result: Dictionary = {}
var _next_seq: int = 1

# COCO / Salient 라벨 -> 한국어 기본 품목명 · 카테고리 · 개념 태그 매핑 (실시간 카메라 검출용 어휘 메타데이터)
const CATEGORY_MAP: Dictionary = {
	"cup": {
		"ko": "머그/음료컵",
		"cat": "테이블웨어·음료",
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
		"ko": "보울/트레이",
		"cat": "테이블웨어·수납 트레이",
		"concepts": ["tableware", "bowl", "tray", "cozy", "organizer", "보울", "그릇", "트레이", "소품함"]
	},
	"cell phone": {
		"ko": "스마트폰/모바일 기기",
		"cat": "모바일·데스크 디바이스",
		"concepts": ["tech", "mobile", "phone", "desk", "charging", "stand", "스마트폰", "폰", "충전기", "맥세이프", "거치대", "전자기기"]
	},
	"laptop": {
		"ko": "노트북",
		"cat": "워크스페이스·컴퓨팅",
		"concepts": ["tech", "laptop", "work", "desk", "ergonomic", "stand", "노트북", "맥북", "작업", "코딩", "스탠드", "거치대"]
	},
	"keyboard": {
		"ko": "키보드",
		"cat": "워크스페이스·입력기기",
		"concepts": ["tech", "keyboard", "work", "desk", "ergonomic", "typing", "키보드", "타건", "팜레스트", "데스크테리어", "작업"]
	},
	"mouse": {
		"ko": "마우스",
		"cat": "워크스페이스·입력기기",
		"concepts": ["tech", "mouse", "work", "desk", "ergonomic", "마우스", "마우스패드", "손목", "데스크테리어", "작업"]
	},
	"remote": {
		"ko": "컨트롤러/리모트 기기",
		"cat": "디바이스·주변기기",
		"concepts": ["tech", "remote", "organizer", "desk", "리모컨", "컨트롤러", "거치", "정리함"]
	},
	"book": {
		"ko": "도서/노트",
		"cat": "문구·독서/기록",
		"concepts": ["study", "book", "note", "stationery", "cozy", "desk", "책", "노트", "독서", "다이어리", "문구", "기록"]
	},
	"backpack": {
		"ko": "백팩/슬링백",
		"cat": "수납·가방",
		"concepts": ["bag", "carry", "portable", "travel", "tech", "백팩", "가방", "파우치", "수납", "외출"]
	},
	"handbag": {
		"ko": "토트/파우치 백",
		"cat": "잡화·오거나이저",
		"concepts": ["bag", "carry", "fashion", "portable", "가방", "파우치", "토트백", "오거나이저"]
	},
	"chair": {
		"ko": "의자",
		"cat": "가구·착석",
		"concepts": ["ergonomic", "chair", "work", "comfort", "cozy", "의자", "쿠션", "요추", "자세", "방석"]
	},
	"clock": {
		"ko": "시계/타이머",
		"cat": "데스크 오브제·시계",
		"concepts": ["desk", "clock", "focus", "minimal", "시계", "타이머", "뽀모도로", "인테리어", "오브제"]
	},
	"potted plant": {
		"ko": "화분/식물",
		"cat": "플랜테리어",
		"concepts": ["plant", "nature", "cozy", "interior", "desk", "식물", "화분", "플랜테리어", "인테리어", "초록"]
	},
	"scissors": {
		"ko": "문구/가위",
		"cat": "데스크 문구",
		"concepts": ["stationery", "tool", "desk", "organizer", "가위", "문구", "펜꽂이", "데스크테리어"]
	},
	"desk_object": {
		"ko": "시선 중심 사물",
		"cat": "주변 사물·오브제",
		"concepts": ["desk", "interior", "organizer", "minimal", "cozy", "사물", "소품", "오브제", "책상"]
	}
}

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
	_load_persisted_memories()


func _load_persisted_memories() -> void:
	memories.clear()
	_next_seq = 1
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var raw: String = FileAccess.get_file_as_string(SAVE_PATH)
	if raw.strip_edges() == "":
		return
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Array:
		for item: Variant in (parsed as Array):
			if item is Dictionary:
				var d: Dictionary = item as Dictionary
				if bool(d.get("is_seed", false)):
					continue
				memories.append(d)
				var id_str: String = str(d.get("id", ""))
				if id_str.begins_with("M"):
					var num: int = id_str.substr(1).to_int()
					if num >= _next_seq:
						_next_seq = num + 1
	print("[MemoryEngine] Loaded ", memories.size(), " real camera memories (zero mockups).")


func reset_live_memories() -> void:
	memories.clear()
	last_search_result = {}
	_next_seq = 1
	_save_memories()


func _save_memories() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(memories))
		f.close()


func ingest_promoted_candidate(cand: Dictionary, cam_plugin: Object = null) -> Dictionary:
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

	var concepts_arr: Array = info.get("concepts", [])
	var concept_str: String = " ".join(PackedStringArray(concepts_arr))
	var initial_observation: String = (
		"%s (%s, %s) · %s · 시선진입 %.2fs, 중심체류 %.1fs"
		% [label_ko, color_tone, brightness, cat_ko, ttc, dwell]
	)

	var mem_id: String = "M%02d" % _next_seq
	_next_seq += 1

	var local_emb: Array[float] = _compute_multimodal_768d(
		initial_observation + " " + raw_label + " " + concept_str,
		rgb_sig
	)

	var record: Dictionary = {
		"id": mem_id,
		"track_id": track_id,
		"tier": "mid_term",
		"label": raw_label,
		"label_ko": label_ko,
		"category_ko": cat_ko,
		"color_tone": color_tone,
		"brightness": brightness,
		"annotation": initial_observation,
		"local_embedding_768": local_emb,
		"neural_embedding_768": [],
		"embed_model": "OnDevice-Multimodal-768d",
		"vlm_model": "OnDevice-CameraROI",
		"crop_path": crop_path,
		"interest_meta": {
			"time_to_center_sec": snappedf(ttc, 0.01),
			"dwell_sec": snappedf(dwell, 0.1),
			"score": snappedf(score, 0.1)
		},
		"rgb_sig": rgb_sig,
		"created_at": int(Time.get_unix_time_from_system()),
		"retrieve_count": 0
	}

	memories.push_front(record)
	if memories.size() > 32:
		for idx in range(memories.size() - 1, -1, -1):
			if str(memories[idx].get("tier", "mid_term")) == "mid_term" and memories.size() > 32:
				memories.remove_at(idx)

	_save_memories()

	if cam_plugin != null and crop_path != "":
		cam_plugin.call("runVisionAnnotateAndEmbedAsync", mem_id, crop_path, initial_observation)

	memory_indexed.emit(record)
	return record


func apply_vision_upgrades_from_plugin(cam_plugin: Object) -> void:
	if cam_plugin == null:
		return
	var raw: String = str(cam_plugin.call("popVisionUpgradesJson"))
	if raw == "[]" or raw.length() <= 2:
		return
	var arr: Variant = JSON.parse_string(raw)
	if not (arr is Array):
		return
	var changed: bool = false
	for u_var: Variant in (arr as Array):
		if not (u_var is Dictionary):
			continue
		var u: Dictionary = u_var as Dictionary
		var mid: String = str(u.get("memId", ""))
		for m: Dictionary in memories:
			if str(m.get("id", "")) == mid:
				if u.has("annotation") and str(u["annotation"]).strip_edges().length() > 3:
					var new_annot: String = str(u["annotation"]).strip_edges()
					m["annotation"] = new_annot
					var sig: Array = m.get("rgb_sig", []) if m.get("rgb_sig") is Array else []
					m["local_embedding_768"] = _compute_multimodal_768d(
						new_annot + " " + str(m.get("label", "")) + " " + str(m.get("color_tone", "")),
						sig
					)
				if u.has("vlmModel") and str(u["vlmModel"]).length() > 0:
					m["vlm_model"] = str(u["vlmModel"])
				changed = true
				memory_upgraded.emit(m)
				break
	if changed:
		_save_memories()


func vector_search_top3(
	query_text: String,
	visual_sig: Array = [],
	top_k: int = 3,
	promote_hits: bool = true,
	_cam_plugin: Object = null
) -> Dictionary:
	var q: String = query_text.strip_edges()
	if memories.is_empty():
		return {"query": q, "total_memories": 0, "results": [], "promoted_ids": []}

	var local_q_vec: Array[float] = _compute_multimodal_768d(q, visual_sig)

	var scored: Array[Dictionary] = []
	for m: Dictionary in memories:
		var lv: Array = m.get("local_embedding_768", m.get("embedding_768", []))
		var sim: float = _cosine_sim(local_q_vec, lv)
		scored.append({"mem": m, "score": sim})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))

	var hits: Array[Dictionary] = []
	var candidate_promote_ids: Array[String] = []
	var limit_n: int = clampi(top_k, 1, 5)
	for i in range(mini(limit_n, scored.size())):
		var m: Dictionary = scored[i]["mem"]
		var sc: float = float(scored[i]["score"])
		if i == 0 and promote_hits and sc > 0.05:
			candidate_promote_ids.append(str(m["id"]))
		hits.append(_format_hit(m, sc, ""))

	var promoted: Array[String] = _promote_memory_ids(candidate_promote_ids) if promote_hits else []
	_sync_promoted_flags(hits, promoted)
	return {
		"query": q,
		"total_memories": memories.size(),
		"results": hits,
		"promoted_ids": promoted
	}


func keyword_search_top3(
	query_text: String,
	top_k: int = 3,
	promote_hits: bool = true
) -> Dictionary:
	var q: String = query_text.strip_edges()
	if memories.is_empty():
		return {"query": q, "total_memories": 0, "results": [], "promoted_ids": []}

	var bm25_scored: Array[Dictionary] = _score_bm25_all(q)
	var hits: Array[Dictionary] = []
	var candidate_promote_ids: Array[String] = []
	var limit_n: int = clampi(top_k, 1, 5)
	for i in range(mini(limit_n, bm25_scored.size())):
		var m: Dictionary = bm25_scored[i]["mem"]
		var sc: float = float(bm25_scored[i]["score"])
		var matched_str: String = str(bm25_scored[i]["matched"])
		if i == 0 and promote_hits and sc > 0.05:
			candidate_promote_ids.append(str(m["id"]))
		hits.append(_format_hit(m, sc, matched_str))

	var promoted: Array[String] = _promote_memory_ids(candidate_promote_ids) if promote_hits else []
	_sync_promoted_flags(hits, promoted)
	return {
		"query": q,
		"total_memories": memories.size(),
		"results": hits,
		"promoted_ids": promoted
	}


func retrieve_hybrid_and_promote(
	query_text: String,
	visual_sig: Array = [],
	focus_record_id: String = "",
	allow_promote_focus: bool = true,
	cam_plugin: Object = null
) -> Dictionary:
	var effective_query: String = query_text.strip_edges()
	if effective_query == "" and memories.size() > 0:
		effective_query = "%s %s %s" % [
			str(memories[0].get("label_ko", "")),
			str(memories[0].get("color_tone", "")),
			str(memories[0].get("annotation", ""))
		]

	var vec_res: Dictionary = vector_search_top3(effective_query, visual_sig, 3, false, cam_plugin)
	var lex_res: Dictionary = keyword_search_top3(effective_query, 3, false)
	var vector_top3: Array = vec_res.get("results", [])
	var lexical_top3: Array = lex_res.get("results", [])

	var used_ids: Array[String] = []
	if focus_record_id != "" and allow_promote_focus:
		used_ids.append(focus_record_id)
	if vector_top3.size() > 0 and float(vector_top3[0].get("score", 0.0)) > 0.05:
		var vid: String = str(vector_top3[0]["id"])
		if not (vid == focus_record_id and not allow_promote_focus) and not (vid in used_ids):
			used_ids.append(vid)
	if lexical_top3.size() > 0 and float(lexical_top3[0].get("score", 0.0)) > 0.05:
		var lid: String = str(lexical_top3[0]["id"])
		if not (lid == focus_record_id and not allow_promote_focus) and not (lid in used_ids):
			used_ids.append(lid)

	var newly_promoted_ids: Array[String] = _promote_memory_ids(used_ids)
	_sync_promoted_flags(vector_top3, newly_promoted_ids)
	_sync_promoted_flags(lexical_top3, newly_promoted_ids)

	var primary_mem: Dictionary = (
		_find_memory_by_id(focus_record_id) if focus_record_id != ""
		else (_find_memory_by_id(used_ids[0]) if used_ids.size() > 0 else (memories[0] if memories.size() > 0 else {}))
	)

	last_search_result = {
		"query": effective_query,
		"vector_top3": vector_top3,
		"lexical_top3": lexical_top3,
		"promoted_ids": newly_promoted_ids,
		"primary_memory": primary_mem
	}
	hybrid_search_completed.emit(last_search_result)
	return last_search_result


func record_hybrid_tool_trace(query_text: String, vec_hits: Array, lex_hits: Array, promoted: Array[String]) -> void:
	var primary_mem: Dictionary = memories[0] if memories.size() > 0 else {}
	if vec_hits.size() > 0 and vec_hits[0] is Dictionary:
		primary_mem = _find_memory_by_id(str((vec_hits[0] as Dictionary).get("id", "")))
	elif lex_hits.size() > 0 and lex_hits[0] is Dictionary:
		primary_mem = _find_memory_by_id(str((lex_hits[0] as Dictionary).get("id", "")))
	last_search_result = {
		"query": query_text,
		"vector_top3": vec_hits,
		"lexical_top3": lex_hits,
		"promoted_ids": promoted,
		"primary_memory": primary_mem
	}
	hybrid_search_completed.emit(last_search_result)


func _format_hit(m: Dictionary, sc: float, matched_str: String) -> Dictionary:
	var d: Dictionary = {
		"id": str(m.get("id", "")),
		"label": str(m.get("label", "")),
		"label_ko": str(m.get("label_ko", "")),
		"color_tone": str(m.get("color_tone", "")),
		"category_ko": str(m.get("category_ko", "")),
		"annotation": str(m.get("annotation", "")),
		"tier": str(m.get("tier", "mid_term")),
		"crop_path": str(m.get("crop_path", "")),
		"interest_meta": m.get("interest_meta", {}),
		"score": snappedf(sc, 0.01)
	}
	if matched_str != "":
		d["matched"] = matched_str
	return d


func _promote_memory_ids(target_ids: Array[String]) -> Array[String]:
	var newly_promoted: Array[String] = []
	if target_ids.is_empty():
		return newly_promoted
	for m: Dictionary in memories:
		var mid: String = str(m.get("id", ""))
		if mid in target_ids:
			m["retrieve_count"] = int(m.get("retrieve_count", 0)) + 1
			if str(m.get("tier", "mid_term")) == "mid_term":
				m["tier"] = "long_term"
				m["promoted_at"] = int(Time.get_unix_time_from_system())
				newly_promoted.append(mid)
	_save_memories()
	return newly_promoted


func _sync_promoted_flags(items: Array, newly_promoted: Array[String]) -> void:
	for item_v: Variant in items:
		if item_v is Dictionary:
			var item: Dictionary = item_v as Dictionary
			if str(item.get("id", "")) in newly_promoted:
				item["tier"] = "long_term"
				item["just_promoted"] = true


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

	if rgb_sig.size() > 0:
		for i in range(mini(24, rgb_sig.size())):
			var v: float = float(rgb_sig[i])
			vec[i * 4] += v * 1.35
			vec[i * 4 + 1] += v * 0.85
			vec[i * 4 + 2] -= v * 0.45

	var lower: String = text.to_lower()
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

	var toks: Array[String] = _tokenize_ko_en(lower)
	for tok: String in toks:
		var h1: int = absi(tok.hash())
		var h2: int = absi((tok + "#2").hash())
		var idx1: int = 336 + (h1 % (EMBED_DIM - 336))
		var idx2: int = 336 + (h2 % (EMBED_DIM - 336))
		vec[idx1] += 1.0 if (h1 % 2 == 0) else -1.0
		vec[idx2] += 0.65 if (h2 % 2 == 0) else -0.65

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
