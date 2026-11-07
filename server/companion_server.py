#!/usr/bin/env python3
"""
Optional MacBook Companion AI Bridge (Port 8765)
Connects to Quest 3 via `adb reverse tcp:8765 tcp:8765`.
- Uses GEMINI_API_KEY (low-cost VLM + 768d embedding) or local `google/embeddinggemma-2` if available.
- Quest APK runs 100% standalone on-device even when this server is not running.
"""

import base64
import hashlib
import json
import math
import os
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import List, Optional

PORT = int(os.environ.get("COMPANION_PORT", "8765"))
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "").strip()

_LOCAL_EMBEDDER = None
try:
    from sentence_transformers import SentenceTransformer  # type: ignore

    _model_id = os.environ.get("EMBEDDING_GEMMA_MODEL", "google/embeddinggemma-2")
    _LOCAL_EMBEDDER = SentenceTransformer(_model_id, truncate_dim=768)
    print(f"[Bridge] Loaded local SentenceTransformer: {_model_id}")
except Exception:
    _LOCAL_EMBEDDER = None


def _gemini_vlm_annotate(crop_b64: Optional[str], label: str, color_tone: str, fallback: str) -> str:
    if not GEMINI_API_KEY or not crop_b64:
        return fallback
    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key={GEMINI_API_KEY}"
    prompt = (
        "사진 속 중심 사물의 품목명, 색상·재질 시각 속성, 추정 용도를 한국어 한 줄(60자 이내)로 간결히 작성해줘."
    )
    body = {
        "contents": [
            {
                "parts": [
                    {"text": prompt},
                    {"inline_data": {"mime_type": "image/jpeg", "data": crop_b64}},
                ]
            }
        ]
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=3.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            txt = data["candidates"][0]["content"]["parts"][0]["text"].strip()
            return txt if txt else fallback
    except Exception:
        return fallback


def _embed_768(text: str) -> tuple[List[float], str]:
    if _LOCAL_EMBEDDER is not None:
        vec = _LOCAL_EMBEDDER.encode(text, normalize_embeddings=True).tolist()
        if len(vec) == 768:
            return [float(x) for x in vec], "google/embeddinggemma-2 (local-768d)"

    if GEMINI_API_KEY:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/text-embedding-004:embedContent?key={GEMINI_API_KEY}"
        body = {
            "model": "models/text-embedding-004",
            "content": {"parts": [{"text": text}]},
            "outputDimensionality": 768,
        }
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                vals = data["embedding"]["values"]
                if len(vals) == 768:
                    norm = math.sqrt(sum(v * v for v in vals)) or 1.0
                    return [float(v / norm) for v in vals], "gemini-768d"
        except Exception:
            pass

    # Deterministic 768d L2-normalized projection fallback
    vec = [0.0] * 768
    words = text.lower().split()
    for w in words:
        digest = hashlib.sha256(w.encode("utf-8")).digest()
        for k in range(0, 24, 2):
            idx = ((digest[k] << 8) | digest[k + 1]) % 768
            vec[idx] += 1.0 if (digest[k] % 2 == 0) else -1.0
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [v / norm for v in vec], "bridge-hash-768d"


class BridgeHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        return

    def _send_json(self, status: int, payload: dict) -> None:
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json(
                200,
                {
                    "ok": True,
                    "local_embeddinggemma2": _LOCAL_EMBEDDER is not None,
                    "gemini_configured": bool(GEMINI_API_KEY),
                },
            )
            return
        self._send_json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.path != "/annotate_and_embed":
            self._send_json(404, {"error": "not_found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        fallback = str(body.get("fallback_annotation", ""))
        label = str(body.get("label", "object"))
        color_tone = str(body.get("color_tone", ""))
        crop_b64 = body.get("crop_b64")

        annot = _gemini_vlm_annotate(crop_b64, label, color_tone, fallback)
        emb, emb_model = _embed_768(f"{annot} {label} {color_tone}")
        self._send_json(
            200,
            {
                "annotation": annot,
                "vlm_model": "gemini-2.5-flash-lite" if (GEMINI_API_KEY and crop_b64) else "LowCost-VLM-Lite",
                "embedding_768": emb,
                "embed_model": emb_model,
            },
        )


if __name__ == "__main__":
    print(f"[Bridge] Companion AI Bridge listening on http://127.0.0.1:{PORT}")
    HTTPServer(("127.0.0.1", PORT), BridgeHandler).serve_forever()
