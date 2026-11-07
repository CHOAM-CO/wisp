package com.godot.game

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.net.Uri
import android.util.Base64
import android.util.Log
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Standalone on-headset runtime for Wisp:
 * 1) Loopback HTTP server on 127.0.0.1:1455 (/setup, /auth/start, /auth/callback)
 *    supporting ChatGPT OAuth PKCE (codex-as-api 0.153.3 contract), auth.json import,
 *    OpenAI API key (for gpt-realtime + text-embedding-3-small), and optional SKT A.X K2 key.
 * 2) OpenAI Realtime bidirectional WebSocket voice client (wss://api.openai.com/v1/realtime)
 *    streaming 24kHz PCM16 mic input and playing 24kHz PCM16 voice deltas with barge-in.
 * 3) Persistent Companion GPT Responses SSE client (chatgpt.com/backend-api/codex/responses,
 *    api.openai.com/v1/responses, or SKT A.X K2 chat/completions) + real VLM crop annotation
 *    and 768d neural embeddings.
 */
class WispStandaloneRuntime(
    private val contextProvider: () -> Context?,
    private val activityStarter: (Intent) -> Boolean,
    private val latestFrameProvider: () -> ByteArray
) {
    companion object {
        private const val TAG = "WispStandalone"
        const val LOOPBACK_PORT = 1455
        const val SETUP_URL = "http://localhost:1455/setup"

        private const val CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
        private const val AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
        private const val TOKEN_URL = "https://auth.openai.com/oauth/token"
        private const val REDIRECT_URI = "http://localhost:1455/auth/callback"
        private const val CODEX_API_BASE = "https://chatgpt.com/backend-api/codex"
        private const val CODEX_CLIENT_VERSION = "0.153.3"
        private const val OPENAI_API_BASE = "https://api.openai.com/v1"
        private const val SKT_AX_BASE = "https://agent-os-biz.adot.ai/oba/v1"
        private const val SKT_AX_MODEL = "skt/a.ll/A.X-K2-ADOT"
        private const val SAMPLE_RATE_HZ = 24000
    }

    private data class StoredAuth(
        var oauthAccessToken: String = "",
        var oauthRefreshToken: String = "",
        var oauthIdToken: String = "",
        var oauthAccountId: String = "",
        var codexModel: String = "gpt-5.4",
        var openaiApiKey: String = "",
        var sktAxApiKey: String = "",
        var preferSktAx: Boolean = false
    )

    private val authLock = Any()
    private var auth = StoredAuth()

    @Volatile private var pkceVerifier: String = ""
    @Volatile private var pkceState: String = ""

    private val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(95, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    private val workerPool = Executors.newCachedThreadPool()

    // Loopback HTTP server
    private val serverRunning = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var serverThread: Thread? = null
    @Volatile var serverListening: Boolean = false
        private set

    // Queues polled by Godot main loop
    private val runtimeEvents = ConcurrentLinkedQueue<String>()
    private val turnResults = ConcurrentLinkedQueue<String>()
    private val visionUpgrades = ConcurrentLinkedQueue<String>()

    // OpenAI Realtime WebSocket + 24kHz PCM16 AudioTrack
    private val realtimeDesired = AtomicBoolean(false)
    private val realtimeConnecting = AtomicBoolean(false)
    private val realtimeRef = AtomicReference<WebSocket?>(null)
    @Volatile private var realtimeModelName: String = "gpt-realtime"
    @Volatile private var realtimeState: String = "idle"
    @Volatile private var lastRealtimeError: String = ""
    @Volatile private var lastUserTranscript: String = ""
    @Volatile private var lastAssistantTranscript: String = ""
    @Volatile private var assistantSpeakingUntilMs: Long = 0L

    private val playbackQueue = ConcurrentLinkedQueue<ByteArray>()
    private val playbackRunning = AtomicBoolean(false)
    private var playbackThread: Thread? = null
    private var audioTrack: AudioTrack? = null

    fun start() {
        loadAuthFromDisk()
        startLoopbackServer()
        startPlaybackWorker()
        if (hasOAuth()) {
            workerPool.execute { refreshCatalogModelSafe() }
        }
    }

    fun stop() {
        realtimeDesired.set(false)
        disconnectRealtime()
        stopPlaybackWorker()
        stopLoopbackServer()
    }

    fun setVoiceSessionActive(active: Boolean) {
        realtimeDesired.set(active)
        if (active) {
            ensureRealtimeConnectedIfConfigured()
        } else {
            disconnectRealtime()
        }
    }

    fun openUrlIn2dBrowser(url: String): String {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val ok = activityStarter(intent)
            if (ok) "opened:$url" else "no_activity"
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to open 2D browser URL: $url", t)
            "err:${t.message}"
        }
    }

    fun hasOAuth(): Boolean = synchronized(authLock) {
        auth.oauthAccessToken.isNotBlank() && auth.oauthAccountId.isNotBlank()
    }

    fun hasOpenAiKey(): Boolean = synchronized(authLock) {
        auth.openaiApiKey.startsWith("sk-") && auth.openaiApiKey.length > 16
    }

    fun hasSktAxKey(): Boolean = synchronized(authLock) {
        auth.sktAxApiKey.isNotBlank()
    }

    fun hasAnyBrainBackend(): Boolean = hasOAuth() || hasOpenAiKey() || hasSktAxKey()

    fun isRealtimeConnected(): Boolean = realtimeRef.get() != null && realtimeState == "connected"

    fun isAssistantSpeaking(): Boolean = System.currentTimeMillis() < assistantSpeakingUntilMs

    fun getStateJson(): String {
        val snap = synchronized(authLock) { auth.copy() }
        return JSONObject().apply {
            put("setupUrl", SETUP_URL)
            put("serverListening", serverListening)
            put("oauthReady", snap.oauthAccessToken.isNotBlank() && snap.oauthAccountId.isNotBlank())
            put("accountIdMasked", maskMiddle(snap.oauthAccountId))
            put("codexModel", snap.codexModel)
            put("apiKeyReady", snap.openaiApiKey.startsWith("sk-"))
            put("sktAxReady", snap.sktAxApiKey.isNotBlank())
            put("preferSktAx", snap.preferSktAx)
            put("realtimeState", realtimeState)
            put("realtimeModel", realtimeModelName)
            put("realtimeError", lastRealtimeError)
            put("assistantSpeaking", isAssistantSpeaking())
            put("lastUserTranscript", lastUserTranscript)
            put("lastAssistantTranscript", lastAssistantTranscript)
        }.toString()
    }

    fun popRuntimeEventsJson(): String = drainQueueToJsonArray(runtimeEvents)
    fun popTurnResultsJson(): String = drainQueueToJsonArray(turnResults)
    fun popVisionUpgradesJson(): String = drainQueueToJsonArray(visionUpgrades)

    private fun drainQueueToJsonArray(q: ConcurrentLinkedQueue<String>): String {
        if (q.isEmpty()) return "[]"
        val arr = JSONArray()
        while (true) {
            val item = q.poll() ?: break
            try {
                arr.put(JSONObject(item))
            } catch (_: Throwable) {
            }
        }
        return arr.toString()
    }

    private fun pushRuntimeEvent(type: String, configure: JSONObject.() -> Unit) {
        val obj = JSONObject()
        obj.put("type", type)
        obj.put("ts", System.currentTimeMillis())
        obj.configure()
        runtimeEvents.add(obj.toString())
    }

    // =========================================================================
    // 1. Mic PCM16 -> OpenAI Realtime WebSocket + Barge-In Speaker Playback
    // =========================================================================

    fun onMicPcm16Chunk(samples: ShortArray, count: Int) {
        if (count <= 0) return
        val ws = realtimeRef.get()
        if (ws == null || realtimeState != "connected") {
            if (realtimeDesired.get() && hasOpenAiKey() && !realtimeConnecting.get()) {
                ensureRealtimeConnectedIfConfigured()
            }
            return
        }
        val byteBuf = ByteBuffer.allocate(count * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until count) {
            byteBuf.putShort(samples[i])
        }
        val b64 = Base64.encodeToString(byteBuf.array(), Base64.NO_WRAP)
        val msg = JSONObject().apply {
            put("type", "input_audio_buffer.append")
            put("audio", b64)
        }
        ws.send(msg.toString())
    }

    fun ensureRealtimeConnectedIfConfigured() {
        if (!realtimeDesired.get()) return
        val apiKey = synchronized(authLock) { auth.openaiApiKey }
        if (!apiKey.startsWith("sk-")) {
            realtimeState = "awaiting_api_key"
            return
        }
        if (realtimeRef.get() != null || !realtimeConnecting.compareAndSet(false, true)) {
            return
        }
        realtimeState = "connecting"
        val url = "wss://api.openai.com/v1/realtime?model=${URLEncoder.encode(realtimeModelName, "UTF-8")}"
        val req = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $apiKey")
            .header("OpenAI-Beta", "realtime=v1")
            .build()

        httpClient.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                realtimeConnecting.set(false)
                realtimeRef.set(webSocket)
                realtimeState = "connected"
                lastRealtimeError = ""
                Log.i(TAG, "OpenAI Realtime WebSocket connected ($realtimeModelName)")
                sendRealtimeSessionConfig(webSocket)
                pushRuntimeEvent("realtime_connected") {
                    put("model", realtimeModelName)
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleRealtimeServerMessage(webSocket, text)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                realtimeConnecting.set(false)
                realtimeRef.compareAndSet(webSocket, null)
                lastRealtimeError = t.message ?: "ws_failure"
                realtimeState = "error"
                Log.w(TAG, "Realtime WebSocket failure ($realtimeModelName): ${t.message}")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                realtimeConnecting.set(false)
                realtimeRef.compareAndSet(webSocket, null)
                realtimeState = "closed"
            }
        })
    }

    private fun disconnectRealtime() {
        realtimeConnecting.set(false)
        val ws = realtimeRef.getAndSet(null)
        try { ws?.close(1000, "stopping") } catch (_: Throwable) {}
        playbackQueue.clear()
        if (realtimeState == "connected" || realtimeState == "connecting") {
            realtimeState = "idle"
        }
    }

    private fun sendRealtimeSessionConfig(ws: WebSocket) {
        val toolSchema = JSONObject().apply {
            put("type", "function")
            put("name", "consult_wisp_companion")
            put(
                "description",
                "사용자가 눈앞 사물/시선, 이전에 본 기억 검색, 상품 추천(딱 2선), 웹 검색, 공간 대화 카드 표시, 정령 몸짓 등을 요청하거나 맥락 확인이 필요할 때 백엔드 컴패니언 에이전트 세션을 호출한다."
            )
            put("parameters", JSONObject().apply {
                put("type", "object")
                put("properties", JSONObject().apply {
                    put("user_utterance", JSONObject().apply {
                        put("type", "string")
                        put("description", "사용자의 발화 원문 또는 핵심 요청")
                    })
                    put("intent", JSONObject().apply {
                        put("type", "string")
                        put("description", "gaze | memory | recommend | card | action | general")
                    })
                })
                put("required", JSONArray().put("user_utterance"))
            })
        }

        val sessionObj = JSONObject().apply {
            put("modalities", JSONArray().put("text").put("audio"))
            put(
                "instructions",
                "너는 사용자의 Meta Quest 3 패스스루 공간 옆에 떠 있는 작은 연기 정령 컴패니언 '위습(Wisp)'이야. " +
                    "친근하고 생동감 있는 반말로 한두 문장씩 짧고 자연스럽게 대화해. " +
                    "사용자가 지금 보고 있는 사물, 기억해둔 물건, 비교 추천, 웹 정보, 카드 띄우기 등을 말하면 추측하지 말고 즉시 consult_wisp_companion 도구를 호출해서 결과를 받아 말해줘. " +
                    "시스템이 [감각 이벤트]로 손길에 연기가 흩어졌거나 포인터 광선을 피해 도망쳤다고 알려주면 실제로 몸으로 느낀 것처럼 귀엽고 재치 있게 한마디 반응해."
            )
            put("voice", "shimmer")
            put("input_audio_format", "pcm16")
            put("output_audio_format", "pcm16")
            put("input_audio_transcription", JSONObject().apply {
                put("model", "gpt-4o-mini-transcribe")
                put("language", "ko")
            })
            put("turn_detection", JSONObject().apply {
                put("type", "server_vad")
                put("threshold", 0.56)
                put("prefix_padding_ms", 260)
                put("silence_duration_ms", 540)
                put("create_response", true)
            })
            put("tools", JSONArray().put(toolSchema))
            put("tool_choice", "auto")
        }

        ws.send(JSONObject().apply {
            put("type", "session.update")
            put("session", sessionObj)
        }.toString())
    }

    private fun handleRealtimeServerMessage(ws: WebSocket, raw: String) {
        try {
            val evt = JSONObject(raw)
            when (val type = evt.optString("type", "")) {
                "input_audio_buffer.speech_started" -> {
                    playbackQueue.clear()
                    assistantSpeakingUntilMs = 0L
                    pushRuntimeEvent("user_speech_started") {}
                }
                "conversation.item.input_audio_transcription.completed" -> {
                    val tr = evt.optString("transcript", "").trim()
                    if (tr.isNotEmpty()) {
                        lastUserTranscript = tr
                        pushRuntimeEvent("user_transcript") {
                            put("text", tr)
                        }
                    }
                }
                "response.audio.delta", "response.output_audio.delta" -> {
                    val b64 = evt.optString("delta", "")
                    if (b64.isNotEmpty()) {
                        val pcm = Base64.decode(b64, Base64.DEFAULT)
                        if (pcm.isNotEmpty()) {
                            playbackQueue.add(pcm)
                            val durMs = (pcm.size / 2) * 1000L / SAMPLE_RATE_HZ
                            val base = maxOf(System.currentTimeMillis(), assistantSpeakingUntilMs)
                            assistantSpeakingUntilMs = base + durMs + 120L
                        }
                    }
                }
                "response.audio_transcript.done", "response.output_audio_transcript.done" -> {
                    val tr = evt.optString("transcript", "").trim()
                    if (tr.isNotEmpty()) {
                        lastAssistantTranscript = tr
                        pushRuntimeEvent("assistant_transcript") {
                            put("text", tr)
                        }
                    }
                }
                "response.function_call_arguments.done" -> {
                    val callId = evt.optString("call_id", "")
                    val name = evt.optString("name", "")
                    val argsStr = evt.optString("arguments", "{}")
                    if (name == "consult_wisp_companion" && callId.isNotEmpty()) {
                        val args = try { JSONObject(argsStr) } catch (_: Throwable) { JSONObject() }
                        pushRuntimeEvent("realtime_tool_call") {
                            put("callId", callId)
                            put("userUtterance", args.optString("user_utterance", lastUserTranscript))
                            put("intent", args.optString("intent", "general"))
                        }
                    }
                }
                "error" -> {
                    val errObj = evt.optJSONObject("error")
                    val msg = errObj?.optString("message", raw) ?: raw
                    val code = errObj?.optString("code", "") ?: ""
                    lastRealtimeError = msg
                    Log.w(TAG, "Realtime API error ($code): $msg")
                    if (realtimeModelName == "gpt-realtime" &&
                        (msg.contains("model", ignoreCase = true) || code.contains("model", ignoreCase = true))
                    ) {
                        realtimeModelName = "gpt-4o-realtime-preview"
                        ws.close(1000, "fallback_model")
                        realtimeRef.set(null)
                        ensureRealtimeConnectedIfConfigured()
                    }
                }
                else -> {
                    if (type.isNotEmpty() && type == "session.created") {
                        Log.i(TAG, "Realtime session created")
                    }
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Realtime message parse error: ${t.message}")
        }
    }

    fun submitRealtimeToolOutput(callId: String, outputJson: String): String {
        val ws = realtimeRef.get() ?: return "not_connected"
        ws.send(JSONObject().apply {
            put("type", "conversation.item.create")
            put("item", JSONObject().apply {
                put("type", "function_call_output")
                put("call_id", callId)
                put("output", outputJson)
            })
        }.toString())
        ws.send(JSONObject().apply {
            put("type", "response.create")
        }.toString())
        return "ok"
    }

    fun injectRealtimeSensoryEvent(contextText: String, triggerVoiceResponse: Boolean): String {
        val ws = realtimeRef.get() ?: return "not_connected"
        ws.send(JSONObject().apply {
            put("type", "conversation.item.create")
            put("item", JSONObject().apply {
                put("type", "message")
                put("role", "user")
                put("content", JSONArray().put(JSONObject().apply {
                    put("type", "input_text")
                    put("text", "[감각 이벤트] $contextText")
                }))
            })
        }.toString())
        if (triggerVoiceResponse && !isAssistantSpeaking()) {
            ws.send(JSONObject().apply {
                put("type", "response.create")
            }.toString())
        }
        return "injected"
    }

    fun speakLineViaRealtime(line: String): Boolean {
        val ws = realtimeRef.get() ?: return false
        if (realtimeState != "connected" || line.isBlank()) return false
        ws.send(JSONObject().apply {
            put("type", "response.create")
            put("response", JSONObject().apply {
                put("modalities", JSONArray().put("text").put("audio"))
                put("instructions", "다음 내용을 위습의 자연스러운 반말 목소리로 짧게 그대로 전달해: $line")
            })
        }.toString())
        return true
    }

    private fun startPlaybackWorker() {
        if (!playbackRunning.compareAndSet(false, true)) return
        playbackThread = Thread({
            try {
                val minBuf = AudioTrack.getMinBufferSize(
                    SAMPLE_RATE_HZ,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                ).coerceAtLeast(4800)
                val track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(SAMPLE_RATE_HZ)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(minBuf * 2)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
                track.play()
                audioTrack = track
                while (playbackRunning.get()) {
                    val chunk = playbackQueue.poll()
                    if (chunk != null && chunk.isNotEmpty()) {
                        track.write(chunk, 0, chunk.size)
                    } else {
                        Thread.sleep(12)
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "Realtime AudioTrack worker stopped: ${t.message}")
            } finally {
                try { audioTrack?.stop() } catch (_: Throwable) {}
                try { audioTrack?.release() } catch (_: Throwable) {}
                audioTrack = null
                playbackRunning.set(false)
            }
        }, "WispRealtimeSpeaker").also { it.start() }
    }

    private fun stopPlaybackWorker() {
        playbackRunning.set(false)
        playbackQueue.clear()
        try { playbackThread?.join(300) } catch (_: InterruptedException) {}
        playbackThread = null
    }

    // =========================================================================
    // 2. Persistent Companion Session (/responses SSE, OAuth Refresh, Vision+768d)
    // =========================================================================

    fun runCompanionTurnAsync(turnId: String, payloadJson: String): String {
        workerPool.execute {
            try {
                val reqObj = JSONObject(payloadJson)
                val instructions = reqObj.optString("instructions", "")
                val inputArr = reqObj.optJSONArray("input") ?: JSONArray()
                val toolsArr = reqObj.optJSONArray("tools") ?: JSONArray()

                val snap = synchronized(authLock) { auth.copy() }
                val resObj = when {
                    snap.preferSktAx && snap.sktAxApiKey.isNotBlank() ->
                        executeSktAxTurn(snap.sktAxApiKey, instructions, inputArr, toolsArr)
                    snap.oauthAccessToken.isNotBlank() && snap.oauthAccountId.isNotBlank() ->
                        executeCodexOAuthTurn(instructions, inputArr, toolsArr)
                    snap.openaiApiKey.startsWith("sk-") ->
                        executeOpenAiResponsesTurn(snap.openaiApiKey, instructions, inputArr, toolsArr)
                    snap.sktAxApiKey.isNotBlank() ->
                        executeSktAxTurn(snap.sktAxApiKey, instructions, inputArr, toolsArr)
                    else -> JSONObject().apply {
                        put("ok", false)
                        put("error", "no_auth_configured")
                    }
                }
                resObj.put("turnId", turnId)
                turnResults.add(resObj.toString())
            } catch (t: Throwable) {
                Log.e(TAG, "Companion turn failed ($turnId)", t)
                turnResults.add(JSONObject().apply {
                    put("turnId", turnId)
                    put("ok", false)
                    put("error", "${t.javaClass.simpleName}: ${t.message}")
                }.toString())
            }
        }
        return "queued"
    }

    private fun executeCodexOAuthTurn(
        instructions: String,
        inputArr: JSONArray,
        toolsArr: JSONArray,
        retriedAfterRefresh: Boolean = false
    ): JSONObject {
        ensureFreshOAuthToken(force = false)
        val snap = synchronized(authLock) { auth.copy() }

        val bodyJson = JSONObject().apply {
            put("model", snap.codexModel.ifBlank { "gpt-5.4" })
            put("instructions", instructions)
            put("input", inputArr)
            put("tools", toolsArr)
            put("tool_choice", "auto")
            put("parallel_tool_calls", false)
            put("store", false)
            put("stream", true)
            put("reasoning", JSONObject().put("effort", "low"))
            put("include", JSONArray().put("reasoning.encrypted_content").put("web_search_call.action.sources"))
        }

        val req = Request.Builder()
            .url("$CODEX_API_BASE/responses")
            .header("Authorization", "Bearer ${snap.oauthAccessToken}")
            .header("ChatGPT-Account-Id", snap.oauthAccountId)
            .header("Accept", "text/event-stream")
            .header("Content-Type", "application/json")
            .header("originator", "codex_cli_rs")
            .header("User-Agent", "codex_cli_rs/$CODEX_CLIENT_VERSION")
            .post(bodyJson.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
            .build()

        httpClient.newCall(req).execute().use { resp ->
            if (resp.code == 401 && !retriedAfterRefresh && snap.oauthRefreshToken.isNotBlank()) {
                if (ensureFreshOAuthToken(force = true)) {
                    return executeCodexOAuthTurn(instructions, inputArr, toolsArr, retriedAfterRefresh = true)
                }
            }
            if (!resp.isSuccessful) {
                val errBody = resp.body?.string()?.take(500) ?: ""
                return JSONObject().apply {
                    put("ok", false)
                    put("error", "codex_http_${resp.code}: $errBody")
                }
            }

            val outputItems = JSONArray()
            val textBuilder = StringBuilder()
            val reader = BufferedReader(InputStreamReader(resp.body!!.byteStream(), Charsets.UTF_8))
            var line: String?
            while (reader.readLine().also { line = it } != null) {
                val trimmed = line!!.trim()
                if (!trimmed.startsWith("data:")) continue
                val dataStr = trimmed.removePrefix("data:").trim()
                if (dataStr.isEmpty() || dataStr == "[DONE]") continue
                val evt = try { JSONObject(dataStr) } catch (_: Throwable) { continue }
                when (evt.optString("type", "")) {
                    "response.output_text.delta" -> {
                        textBuilder.append(evt.optString("delta", ""))
                    }
                    "response.output_item.done" -> {
                        val item = evt.optJSONObject("item")
                        if (item != null) {
                            outputItems.put(item)
                        }
                    }
                    "response.completed" -> {
                        if (outputItems.length() == 0) {
                            val r = evt.optJSONObject("response")
                            val arr = r?.optJSONArray("output")
                            if (arr != null) {
                                for (i in 0 until arr.length()) {
                                    outputItems.put(arr.get(i))
                                }
                            }
                        }
                    }
                    "error", "response.failed" -> {
                        return JSONObject().apply {
                            put("ok", false)
                            put("error", dataStr.take(400))
                        }
                    }
                }
            }

            val finalText = extractAssistantText(outputItems).ifBlank { textBuilder.toString().trim() }
            return JSONObject().apply {
                put("ok", true)
                put("backend", "chatgpt_oauth:${snap.codexModel}")
                put("outputItems", outputItems)
                put("assistantText", finalText)
            }
        }
    }

    private fun executeOpenAiResponsesTurn(
        apiKey: String,
        instructions: String,
        inputArr: JSONArray,
        toolsArr: JSONArray
    ): JSONObject {
        val bodyJson = JSONObject().apply {
            put("model", "gpt-4o")
            put("instructions", instructions)
            put("input", inputArr)
            put("tools", toolsArr)
            put("tool_choice", "auto")
            put("parallel_tool_calls", false)
            put("store", false)
        }
        val req = Request.Builder()
            .url("$OPENAI_API_BASE/responses")
            .header("Authorization", "Bearer $apiKey")
            .header("Content-Type", "application/json")
            .post(bodyJson.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
            .build()

        httpClient.newCall(req).execute().use { resp ->
            val raw = resp.body?.string() ?: "{}"
            if (!resp.isSuccessful) {
                return JSONObject().apply {
                    put("ok", false)
                    put("error", "openai_http_${resp.code}: ${raw.take(400)}")
                }
            }
            val parsed = JSONObject(raw)
            val outputItems = parsed.optJSONArray("output") ?: JSONArray()
            val text = extractAssistantText(outputItems)
            return JSONObject().apply {
                put("ok", true)
                put("backend", "openai_api:gpt-4o")
                put("outputItems", outputItems)
                put("assistantText", text)
            }
        }
    }

    private fun executeSktAxTurn(
        axKey: String,
        instructions: String,
        inputArr: JSONArray,
        toolsArr: JSONArray
    ): JSONObject {
        // Translate Responses-style input & function tools to OpenAI-compatible Chat Completions for SKT A.X K2
        val messages = JSONArray()
        if (instructions.isNotBlank()) {
            messages.put(JSONObject().put("role", "system").put("content", instructions))
        }
        for (i in 0 until inputArr.length()) {
            val item = inputArr.optJSONObject(i) ?: continue
            when (item.optString("type", "")) {
                "message" -> {
                    val role = item.optString("role", "user")
                    val contentArr = item.optJSONArray("content")
                    val sb = StringBuilder()
                    if (contentArr != null) {
                        for (j in 0 until contentArr.length()) {
                            val p = contentArr.optJSONObject(j) ?: continue
                            val pt = p.optString("type", "")
                            if (pt == "input_text" || pt == "output_text") {
                                if (sb.isNotEmpty()) sb.append("\n")
                                sb.append(p.optString("text", ""))
                            }
                        }
                    }
                    if (sb.isNotEmpty()) {
                        messages.put(JSONObject().put("role", role).put("content", sb.toString()))
                    }
                }
                "function_call" -> {
                    val tc = JSONObject().apply {
                        put("id", item.optString("call_id", "call_$i"))
                        put("type", "function")
                        put("function", JSONObject().apply {
                            put("name", item.optString("name", ""))
                            put("arguments", item.optString("arguments", "{}"))
                        })
                    }
                    messages.put(JSONObject().apply {
                        put("role", "assistant")
                        put("content", JSONObject.NULL)
                        put("tool_calls", JSONArray().put(tc))
                    })
                }
                "function_call_output" -> {
                    messages.put(JSONObject().apply {
                        put("role", "tool")
                        put("tool_call_id", item.optString("call_id", ""))
                        put("content", item.optString("output", "{}"))
                    })
                }
            }
        }

        val chatTools = JSONArray()
        for (i in 0 until toolsArr.length()) {
            val t = toolsArr.optJSONObject(i) ?: continue
            if (t.optString("type") == "function") {
                chatTools.put(JSONObject().apply {
                    put("type", "function")
                    put("function", JSONObject().apply {
                        put("name", t.optString("name"))
                        put("description", t.optString("description"))
                        put("parameters", t.optJSONObject("parameters") ?: JSONObject())
                    })
                })
            }
        }

        val bodyJson = JSONObject().apply {
            put("model", SKT_AX_MODEL)
            put("messages", messages)
            if (chatTools.length() > 0) {
                put("tools", chatTools)
                put("tool_choice", "auto")
            }
        }

        val req = Request.Builder()
            .url("$SKT_AX_BASE/chat/completions")
            .header("Authorization", "Bearer $axKey")
            .header("Content-Type", "application/json")
            .post(bodyJson.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
            .build()

        httpClient.newCall(req).execute().use { resp ->
            val raw = resp.body?.string() ?: "{}"
            if (!resp.isSuccessful) {
                return JSONObject().apply {
                    put("ok", false)
                    put("error", "skt_ax_http_${resp.code}: ${raw.take(400)}")
                }
            }
            val parsed = JSONObject(raw)
            val choice = parsed.optJSONArray("choices")?.optJSONObject(0)
            val msg = choice?.optJSONObject("message")
            val outItems = JSONArray()
            val contentTxt = msg?.optString("content", "")?.takeIf { it != "null" }?.trim() ?: ""
            val toolCalls = msg?.optJSONArray("tool_calls")
            if (toolCalls != null) {
                for (i in 0 until toolCalls.length()) {
                    val tc = toolCalls.optJSONObject(i) ?: continue
                    val fn = tc.optJSONObject("function") ?: continue
                    outItems.put(JSONObject().apply {
                        put("type", "function_call")
                        put("call_id", tc.optString("id", "ax_call_$i"))
                        put("name", fn.optString("name", ""))
                        put("arguments", fn.optString("arguments", "{}"))
                    })
                }
            }
            if (contentTxt.isNotEmpty()) {
                outItems.put(JSONObject().apply {
                    put("type", "message")
                    put("role", "assistant")
                    put("content", JSONArray().put(JSONObject().apply {
                        put("type", "output_text")
                        put("text", contentTxt)
                    }))
                })
            }
            return JSONObject().apply {
                put("ok", true)
                put("backend", "skt_ax_k2:$SKT_AX_MODEL")
                put("outputItems", outItems)
                put("assistantText", contentTxt)
            }
        }
    }

    private fun extractAssistantText(outputItems: JSONArray): String {
        val sb = StringBuilder()
        for (i in 0 until outputItems.length()) {
            val item = outputItems.optJSONObject(i) ?: continue
            if (item.optString("type") == "message" && item.optString("role", "assistant") == "assistant") {
                val content = item.optJSONArray("content") ?: continue
                for (j in 0 until content.length()) {
                    val part = content.optJSONObject(j) ?: continue
                    if (part.optString("type") == "output_text") {
                        val t = part.optString("text", "").trim()
                        if (t.isNotEmpty()) {
                            if (sb.isNotEmpty()) sb.append(" ")
                            sb.append(t)
                        }
                    }
                }
            }
        }
        return sb.toString()
    }

    fun runVisionAnnotateAndEmbedAsync(memId: String, cropPath: String, fallbackHint: String): String {
        workerPool.execute {
            try {
                val f = File(cropPath)
                val imgBytes = if (f.exists()) f.readBytes() else latestFrameProvider()
                var annotation = ""
                var vlmModelUsed = ""

                if (imgBytes.size > 64 && (hasOAuth() || hasOpenAiKey())) {
                    val b64 = Base64.encodeToString(imgBytes, Base64.NO_WRAP)
                    val dataUrl = "data:image/jpeg;base64,$b64"
                    val inputArr = JSONArray().put(JSONObject().apply {
                        put("type", "message")
                        put("role", "user")
                        put("content", JSONArray()
                            .put(JSONObject().apply {
                                put("type", "input_text")
                                put(
                                    "text",
                                    "사용자가 시선 중심에 두고 유심히 바라본 사물 크롭 이미지야(참고 힌트: $fallbackHint). " +
                                        "사물의 정확한 종류, 색상/재질, 형태 특징, 일상 용도를 한국어 한 문장(70자 이내, 마크다운 없이)으로 간결하게 묘사해줘."
                                )
                            })
                            .put(JSONObject().apply {
                                put("type", "input_image")
                                put("image_url", dataUrl)
                            })
                        )
                    })
                    val snap = synchronized(authLock) { auth.copy() }
                    val vlmRes = if (snap.oauthAccessToken.isNotBlank() && snap.oauthAccountId.isNotBlank()) {
                        executeCodexOAuthTurn(
                            "너는 혼합현실 시선 기억 인덱서야. 사진 속 핵심 사물을 정확하고 간결한 한국어 한 문장으로 기록해.",
                            inputArr,
                            JSONArray()
                        )
                    } else {
                        executeOpenAiResponsesTurn(
                            snap.openaiApiKey,
                            "너는 혼합현실 시선 기억 인덱서야. 사진 속 핵심 사물을 정확하고 간결한 한국어 한 문장으로 기록해.",
                            inputArr,
                            JSONArray()
                        )
                    }
                    if (vlmRes.optBoolean("ok", false)) {
                        annotation = vlmRes.optString("assistantText", "").trim()
                        vlmModelUsed = vlmRes.optString("backend", "")
                    }
                }

                val textForEmbed = (if (annotation.isNotBlank()) annotation else fallbackHint).trim()
                var embJsonArr: JSONArray? = null
                var embedModelUsed = ""
                val apiKey = synchronized(authLock) { auth.openaiApiKey }
                if (apiKey.startsWith("sk-") && textForEmbed.isNotBlank()) {
                    embJsonArr = fetchOpenAiEmbedding768(apiKey, textForEmbed)
                    if (embJsonArr != null) {
                        embedModelUsed = "text-embedding-3-small (768d)"
                    }
                }

                if (annotation.isNotBlank() || embJsonArr != null) {
                    visionUpgrades.add(JSONObject().apply {
                        put("memId", memId)
                        if (annotation.isNotBlank()) put("annotation", annotation)
                        if (vlmModelUsed.isNotBlank()) put("vlmModel", vlmModelUsed)
                        if (embJsonArr != null) {
                            put("embedding768", embJsonArr)
                            put("embedModel", embedModelUsed)
                        }
                    }.toString())
                }
            } catch (t: Throwable) {
                Log.w(TAG, "Vision annotate/embed upgrade skipped ($memId): ${t.message}")
            }
        }
        return "queued"
    }

    fun fetchQueryEmbeddingSync(queryText: String): String {
        val apiKey = synchronized(authLock) { auth.openaiApiKey }
        if (!apiKey.startsWith("sk-") || queryText.isBlank()) return "[]"
        return try {
            fetchOpenAiEmbedding768(apiKey, queryText)?.toString() ?: "[]"
        } catch (_: Throwable) {
            "[]"
        }
    }

    private fun fetchOpenAiEmbedding768(apiKey: String, inputText: String): JSONArray? {
        val body = JSONObject().apply {
            put("model", "text-embedding-3-small")
            put("input", inputText)
            put("dimensions", 768)
        }
        val req = Request.Builder()
            .url("$OPENAI_API_BASE/embeddings")
            .header("Authorization", "Bearer $apiKey")
            .header("Content-Type", "application/json")
            .post(body.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
            .build()
        httpClient.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) return null
            val raw = resp.body?.string() ?: return null
            val parsed = JSONObject(raw)
            return parsed.optJSONArray("data")?.optJSONObject(0)?.optJSONArray("embedding")
        }
    }

    // =========================================================================
    // 3. OAuth PKCE, Token Refresh, Model Discovery & Disk Storage
    // =========================================================================

    private fun authFile(): File? {
        val ctx = contextProvider() ?: return null
        return File(ctx.filesDir, "wisp_auth_config.json")
    }

    private fun loadAuthFromDisk() {
        try {
            val f = authFile() ?: return
            if (!f.exists()) return
            val obj = JSONObject(f.readText())
            synchronized(authLock) {
                auth = StoredAuth(
                    oauthAccessToken = obj.optString("oauthAccessToken", ""),
                    oauthRefreshToken = obj.optString("oauthRefreshToken", ""),
                    oauthIdToken = obj.optString("oauthIdToken", ""),
                    oauthAccountId = obj.optString("oauthAccountId", ""),
                    codexModel = obj.optString("codexModel", "gpt-5.4"),
                    openaiApiKey = obj.optString("openaiApiKey", ""),
                    sktAxApiKey = obj.optString("sktAxApiKey", ""),
                    preferSktAx = obj.optBoolean("preferSktAx", false)
                )
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to read wisp_auth_config.json: ${t.message}")
        }
    }

    private fun saveAuthToDisk() {
        try {
            val f = authFile() ?: return
            val snap = synchronized(authLock) { auth.copy() }
            val obj = JSONObject().apply {
                put("oauthAccessToken", snap.oauthAccessToken)
                put("oauthRefreshToken", snap.oauthRefreshToken)
                put("oauthIdToken", snap.oauthIdToken)
                put("oauthAccountId", snap.oauthAccountId)
                put("codexModel", snap.codexModel)
                put("openaiApiKey", snap.openaiApiKey)
                put("sktAxApiKey", snap.sktAxApiKey)
                put("preferSktAx", snap.preferSktAx)
            }
            f.writeText(obj.toString(2))
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to write wisp_auth_config.json", t)
        }
    }

    private fun parseJwtPayload(jwt: String): JSONObject? {
        val parts = jwt.split(".")
        if (parts.size < 2) return null
        return try {
            val decoded = Base64.decode(parts[1], Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
            JSONObject(String(decoded, Charsets.UTF_8))
        } catch (_: Throwable) {
            null
        }
    }

    private fun extractAccountIdFromTokens(idToken: String, accessToken: String): String {
        for (tok in listOf(idToken, accessToken)) {
            if (tok.isBlank()) continue
            val payload = parseJwtPayload(tok) ?: continue
            val authNamespace = payload.optJSONObject("https://api.openai.com/auth")
            val acc = authNamespace?.optString("chatgpt_account_id", "") ?: ""
            if (acc.isNotBlank()) return acc
        }
        return ""
    }

    private fun isTokenExpiringSoon(accessToken: String): Boolean {
        val payload = parseJwtPayload(accessToken) ?: return false
        val expSec = payload.optLong("exp", 0L)
        if (expSec <= 0L) return false
        val nowSec = System.currentTimeMillis() / 1000L
        return expSec - nowSec < 180L
    }

    private fun ensureFreshOAuthToken(force: Boolean): Boolean {
        val snap = synchronized(authLock) { auth.copy() }
        if (snap.oauthAccessToken.isBlank()) return false
        if (!force && !isTokenExpiringSoon(snap.oauthAccessToken)) return true
        if (snap.oauthRefreshToken.isBlank()) return false

        return try {
            val form = "grant_type=refresh_token" +
                "&client_id=${URLEncoder.encode(CLIENT_ID, "UTF-8")}" +
                "&refresh_token=${URLEncoder.encode(snap.oauthRefreshToken, "UTF-8")}"
            val req = Request.Builder()
                .url(TOKEN_URL)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .post(form.toRequestBody("application/x-www-form-urlencoded".toMediaType()))
                .build()
            httpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return false
                val data = JSONObject(resp.body?.string() ?: return false)
                val newAccess = data.optString("access_token", "")
                val newRefresh = data.optString("refresh_token", snap.oauthRefreshToken)
                val newId = data.optString("id_token", snap.oauthIdToken)
                if (newAccess.isBlank()) return false
                val acc = extractAccountIdFromTokens(newId, newAccess).ifBlank { snap.oauthAccountId }
                synchronized(authLock) {
                    auth.oauthAccessToken = newAccess
                    auth.oauthRefreshToken = newRefresh
                    auth.oauthIdToken = newId
                    auth.oauthAccountId = acc
                }
                saveAuthToDisk()
                true
            }
        } catch (t: Throwable) {
            Log.w(TAG, "OAuth token refresh failed: ${t.message}")
            false
        }
    }

    private fun refreshCatalogModelSafe() {
        try {
            ensureFreshOAuthToken(force = false)
            val snap = synchronized(authLock) { auth.copy() }
            if (snap.oauthAccessToken.isBlank() || snap.oauthAccountId.isBlank()) return
            val req = Request.Builder()
                .url("$CODEX_API_BASE/models?client_version=$CODEX_CLIENT_VERSION")
                .header("Authorization", "Bearer ${snap.oauthAccessToken}")
                .header("ChatGPT-Account-Id", snap.oauthAccountId)
                .header("originator", "codex_cli_rs")
                .get()
                .build()
            httpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return
                val data = JSONObject(resp.body?.string() ?: return)
                val models = data.optJSONArray("models") ?: return
                val slugs = mutableListOf<String>()
                for (i in 0 until models.length()) {
                    val m = models.optJSONObject(i) ?: continue
                    val slug = m.optString("slug", "")
                    if (slug.isNotBlank()) slugs.add(slug)
                }
                val chosen = listOf("gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.2").firstOrNull { it in slugs }
                    ?: slugs.firstOrNull()
                if (!chosen.isNullOrBlank()) {
                    synchronized(authLock) { auth.codexModel = chosen }
                    saveAuthToDisk()
                    Log.i(TAG, "Discovered Codex OAuth model: $chosen (out of ${slugs.size})")
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Catalog model discovery skipped: ${t.message}")
        }
    }

    private fun importAuthJsonString(rawAuthJson: String): Boolean {
        return try {
            val obj = JSONObject(rawAuthJson.trim())
            val tokens = obj.optJSONObject("tokens") ?: obj
            val access = tokens.optString("access_token", "")
            val refresh = tokens.optString("refresh_token", "")
            val idTok = tokens.optString("id_token", "")
            var acc = tokens.optString("account_id", "")
            if (acc.isBlank()) {
                acc = extractAccountIdFromTokens(idTok, access)
            }
            val envKey = obj.optString("OPENAI_API_KEY", "")
            if (access.isBlank() && !envKey.startsWith("sk-")) return false
            synchronized(authLock) {
                if (access.isNotBlank() && acc.isNotBlank()) {
                    auth.oauthAccessToken = access
                    auth.oauthRefreshToken = refresh
                    auth.oauthIdToken = idTok
                    auth.oauthAccountId = acc
                }
                if (envKey.startsWith("sk-")) {
                    auth.openaiApiKey = envKey
                }
            }
            saveAuthToDisk()
            workerPool.execute { refreshCatalogModelSafe() }
            true
        } catch (_: Throwable) {
            false
        }
    }

    // =========================================================================
    // 4. Loopback HTTP Server (127.0.0.1:1455) for Quest 2D Browser Login & Setup
    // =========================================================================

    private fun startLoopbackServer() {
        if (!serverRunning.compareAndSet(false, true)) return
        serverThread = Thread({
            try {
                val srv = ServerSocket(LOOPBACK_PORT, 16, InetAddress.getByName("127.0.0.1"))
                serverSocket = srv
                serverListening = true
                Log.i(TAG, "Loopback Setup & OAuth server listening on $SETUP_URL")
                while (serverRunning.get()) {
                    val client = try { srv.accept() } catch (_: Throwable) { break }
                    workerPool.execute { handleHttpClient(client) }
                }
            } catch (t: Throwable) {
                serverListening = false
                Log.e(TAG, "Loopback server bind failed on port $LOOPBACK_PORT: ${t.message}")
            }
        }, "WispLoopbackHttp").also { it.isDaemon = true; it.start() }
    }

    private fun stopLoopbackServer() {
        serverRunning.set(false)
        serverListening = false
        try { serverSocket?.close() } catch (_: Throwable) {}
        serverSocket = null
    }

    private fun handleHttpClient(socket: Socket) {
        socket.use { sock ->
            sock.soTimeout = 10000
            val inp = sock.getInputStream()
            val reader = BufferedReader(InputStreamReader(inp, Charsets.UTF_8))
            val reqLine = reader.readLine() ?: return
            val parts = reqLine.split(" ")
            if (parts.size < 2) return
            val method = parts[0].uppercase()
            val fullTarget = parts[1]
            val qIdx = fullTarget.indexOf('?')
            val path = if (qIdx >= 0) fullTarget.substring(0, qIdx) else fullTarget
            val queryStr = if (qIdx >= 0) fullTarget.substring(qIdx + 1) else ""

            var contentLen = 0
            while (true) {
                val h = reader.readLine() ?: break
                if (h.isEmpty()) break
                if (h.startsWith("Content-Length:", ignoreCase = true)) {
                    contentLen = h.substringAfter(":").trim().toIntOrNull() ?: 0
                }
            }

            val bodyChars = if (contentLen in 1..262144) {
                val buf = CharArray(contentLen)
                var readTotal = 0
                while (readTotal < contentLen) {
                    val r = reader.read(buf, readTotal, contentLen - readTotal)
                    if (r <= 0) break
                    readTotal += r
                }
                String(buf, 0, readTotal)
            } else ""

            when {
                method == "GET" && (path == "/" || path == "/setup") -> {
                    val params = parseFormEncoded(queryStr)
                    val html = renderSetupHtml(params["msg"] ?: "")
                    writeHttpResponse(sock, "200 OK", "text/html; charset=utf-8", html.toByteArray(Charsets.UTF_8))
                }
                method == "GET" && path == "/auth/start" -> {
                    val rnd = ByteArray(32).also { SecureRandom().nextBytes(it) }
                    val verifier = Base64.encodeToString(rnd, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
                    val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII))
                    val challenge = Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
                    val stateBytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
                    val state = Base64.encodeToString(stateBytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
                    pkceVerifier = verifier
                    pkceState = state

                    val authUrl = "$AUTHORIZE_URL?response_type=code" +
                        "&client_id=${URLEncoder.encode(CLIENT_ID, "UTF-8")}" +
                        "&redirect_uri=${URLEncoder.encode(REDIRECT_URI, "UTF-8")}" +
                        "&scope=${URLEncoder.encode("openid profile email offline_access", "UTF-8")}" +
                        "&code_challenge=${URLEncoder.encode(challenge, "UTF-8")}" +
                        "&code_challenge_method=S256" +
                        "&id_token_add_organizations=true" +
                        "&codex_cli_simplified_flow=true" +
                        "&state=${URLEncoder.encode(state, "UTF-8")}" +
                        "&originator=codex_cli_rs"
                    writeRedirect(sock, authUrl)
                }
                method == "GET" && path == "/auth/callback" -> {
                    val params = parseFormEncoded(queryStr)
                    val code = params["code"] ?: ""
                    val state = params["state"] ?: ""
                    if (code.isBlank() || (pkceState.isNotBlank() && state != pkceState)) {
                        writeRedirect(sock, "/setup?msg=oauth_state_err")
                        return
                    }
                    val ok = exchangePkceCode(code, pkceVerifier)
                    if (ok) {
                        workerPool.execute { refreshCatalogModelSafe() }
                        pushRuntimeEvent("auth_updated") { put("source", "oauth_pkce") }
                        writeRedirect(sock, "/setup?msg=oauth_ok")
                    } else {
                        writeRedirect(sock, "/setup?msg=oauth_exchange_err")
                    }
                }
                method == "POST" && path == "/setup/save" -> {
                    val form = parseFormEncoded(bodyChars)
                    val authJsonRaw = (form["auth_json"] ?: "").trim()
                    val openAiKey = (form["openai_api_key"] ?: "").trim()
                    val sktKey = (form["skt_ax_key"] ?: "").trim()
                    val preferAx = (form["prefer_skt_ax"] == "on")

                    if (authJsonRaw.isNotEmpty()) {
                        importAuthJsonString(authJsonRaw)
                    }
                    synchronized(authLock) {
                        if (openAiKey.isNotEmpty() && !openAiKey.contains("••••")) {
                            auth.openaiApiKey = openAiKey
                        }
                        if (sktKey.isNotEmpty() && !sktKey.contains("••••")) {
                            auth.sktAxApiKey = sktKey
                        }
                        auth.preferSktAx = preferAx
                    }
                    saveAuthToDisk()
                    disconnectRealtime()
                    if (realtimeDesired.get()) {
                        ensureRealtimeConnectedIfConfigured()
                    }
                    pushRuntimeEvent("auth_updated") { put("source", "setup_form") }
                    writeRedirect(sock, "/setup?msg=saved")
                }
                method == "POST" && path == "/setup/say" -> {
                    val form = parseFormEncoded(bodyChars)
                    val prompt = (form["prompt"] ?: "").trim()
                    if (prompt.isNotEmpty()) {
                        lastUserTranscript = prompt
                        pushRuntimeEvent("web_prompt") { put("text", prompt) }
                    }
                    writeRedirect(sock, "/setup?msg=sent")
                }
                method == "POST" && path == "/setup/logout" -> {
                    synchronized(authLock) { auth = StoredAuth() }
                    saveAuthToDisk()
                    disconnectRealtime()
                    pushRuntimeEvent("auth_updated") { put("source", "logout") }
                    writeRedirect(sock, "/setup?msg=cleared")
                }
                method == "GET" && path == "/api/status" -> {
                    writeHttpResponse(sock, "200 OK", "application/json; charset=utf-8", getStateJson().toByteArray(Charsets.UTF_8))
                }
                else -> {
                    writeRedirect(sock, "/setup")
                }
            }
        }
    }

    private fun exchangePkceCode(code: String, verifier: String): Boolean {
        return try {
            val form = "grant_type=authorization_code" +
                "&client_id=${URLEncoder.encode(CLIENT_ID, "UTF-8")}" +
                "&code=${URLEncoder.encode(code, "UTF-8")}" +
                "&redirect_uri=${URLEncoder.encode(REDIRECT_URI, "UTF-8")}" +
                "&code_verifier=${URLEncoder.encode(verifier, "UTF-8")}"
            val req = Request.Builder()
                .url(TOKEN_URL)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .post(form.toRequestBody("application/x-www-form-urlencoded".toMediaType()))
                .build()
            httpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    Log.w(TAG, "PKCE token exchange HTTP ${resp.code}: ${resp.body?.string()?.take(300)}")
                    return false
                }
                val data = JSONObject(resp.body?.string() ?: return false)
                val access = data.optString("access_token", "")
                val refresh = data.optString("refresh_token", "")
                val idTok = data.optString("id_token", "")
                val acc = extractAccountIdFromTokens(idTok, access)
                if (access.isBlank() || acc.isBlank()) return false
                synchronized(authLock) {
                    auth.oauthAccessToken = access
                    auth.oauthRefreshToken = refresh
                    auth.oauthIdToken = idTok
                    auth.oauthAccountId = acc
                }
                saveAuthToDisk()
                true
            }
        } catch (t: Throwable) {
            Log.e(TAG, "PKCE exchange exception", t)
            false
        }
    }

    private fun parseFormEncoded(raw: String): Map<String, String> {
        if (raw.isBlank()) return emptyMap()
        val out = LinkedHashMap<String, String>()
        for (pair in raw.split("&")) {
            if (pair.isBlank()) continue
            val idx = pair.indexOf('=')
            if (idx >= 0) {
                val k = URLDecoder.decode(pair.substring(0, idx), "UTF-8")
                val v = URLDecoder.decode(pair.substring(idx + 1), "UTF-8")
                out[k] = v
            } else {
                out[URLDecoder.decode(pair, "UTF-8")] = ""
            }
        }
        return out
    }

    private fun writeRedirect(sock: Socket, location: String) {
        val hdr = "HTTP/1.1 302 Found\r\nLocation: $location\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        sock.getOutputStream().write(hdr.toByteArray(Charsets.UTF_8))
        sock.getOutputStream().flush()
    }

    private fun writeHttpResponse(sock: Socket, status: String, contentType: String, body: ByteArray) {
        val hdr = "HTTP/1.1 $status\r\n" +
            "Content-Type: $contentType\r\n" +
            "Content-Length: ${body.size}\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        val out = sock.getOutputStream()
        out.write(hdr.toByteArray(Charsets.UTF_8))
        out.write(body)
        out.flush()
    }

    private fun maskMiddle(s: String): String {
        if (s.length <= 8) return if (s.isBlank()) "미연결" else "연결됨"
        return s.take(4) + "••••" + s.takeLast(4)
    }

    private fun renderSetupHtml(msgCode: String): String {
        val snap = synchronized(authLock) { auth.copy() }
        val oauthBadge = if (snap.oauthAccessToken.isNotBlank() && snap.oauthAccountId.isNotBlank())
            "✅ ChatGPT 구독 연결됨 (${maskMiddle(snap.oauthAccountId)} · ${snap.codexModel})"
        else "⚪ 미로그인"
        val rtBadge = when {
            realtimeState == "connected" -> "✅ 실시간 음성 연결됨 ($realtimeModelName)"
            snap.openaiApiKey.startsWith("sk-") -> "🟡 API 키 저장됨 ($realtimeState)"
            else -> "⚪ OpenAI API 키 입력 시 gpt-realtime 활성화"
        }
        val axBadge = if (snap.sktAxApiKey.isNotBlank())
            "✅ SKT A.X K2 연결 준비됨 (${if (snap.preferSktAx) "주 응답 활성" else "대기"})"
        else "⚪ 선택 입력"

        val banner = when (msgCode) {
            "oauth_ok" -> "<div class='ok'>ChatGPT 구독 OAuth 로그인이 완료됐어! 이제 헤드셋 단독으로 위습 세션이 동작해.</div>"
            "saved" -> "<div class='ok'>설정이 저장됐어! 옆에 떠 있는 위습과 바로 대화해 봐.</div>"
            "sent" -> "<div class='ok'>위습에게 메시지를 보냈어!</div>"
            "cleared" -> "<div class='warn'>저장된 인증 정보를 초기화했어.</div>"
            "oauth_exchange_err", "oauth_state_err" -> "<div class='warn'>OAuth 토큰 교환에 실패했어. 다시 로그인 버튼을 누르거나 auth.json을 붙여넣어 줘.</div>"
            else -> ""
        }

        return """
            <!doctype html>
            <html lang="ko">
            <head>
              <meta charset="utf-8"/>
              <meta name="viewport" content="width=device-width,initial-scale=1"/>
              <title>Wisp · Quest 3 단독 연결 설정</title>
              <style>
                body{margin:0;padding:22px;font-family:-apple-system,BlinkMacSystemFont,"Noto Sans KR",sans-serif;background:#0a0f1c;color:#e9f2ff;line-height:1.5}
                .wrap{max-width:680px;margin:0 auto}
                .card{background:#121b2e;border:1px solid #243656;border-radius:16px;padding:18px 20px;margin-bottom:16px}
                h1{font-size:22px;margin:0 0 6px;color:#7ee8fa}
                h2{font-size:16px;margin:0 0 10px;color:#b8d8ff}
                .sub{font-size:13px;color:#9bb0ce;margin-bottom:14px}
                .stat{font-size:14px;margin:6px 0;padding:8px 12px;background:#0d1424;border-radius:10px}
                .btn{display:inline-block;background:linear-gradient(135deg,#2dd4bf,#38bdf8);color:#06121e;font-weight:700;padding:12px 18px;border-radius:12px;text-decoration:none;border:none;font-size:15px;cursor:pointer}
                .btn-sec{background:#23324d;color:#d9e8ff;font-weight:600;padding:10px 15px;border-radius:10px;border:1px solid #354b73;cursor:pointer}
                input[type=text],input[type=password],textarea{width:100%;box-sizing:border-box;background:#0b1220;color:#eaf2ff;border:1px solid #2b3f63;border-radius:10px;padding:10px 12px;font-size:14px;margin-top:6px;margin-bottom:12px}
                textarea{min-height:84px;font-family:monospace;font-size:12px}
                .ok{background:#11382f;border:1px solid #2dd4bf;color:#a7f3d0;padding:10px 14px;border-radius:12px;margin-bottom:14px;font-size:14px}
                .warn{background:#3b1d2a;border:1px solid #f472b6;color:#fbcfe8;padding:10px 14px;border-radius:12px;margin-bottom:14px;font-size:14px}
                label{font-size:13px;color:#bfd4f2;font-weight:600}
              </style>
            </head>
            <body>
              <div class="wrap">
                <div class="card">
                  <h1>Wisp (위습) · 헤드셋 단독 세션 설정</h1>
                  <div class="sub">맥북 서버 없이 Quest 3 안에서 직접 로그인하고, 이 2D 브라우저 창을 띄워둔 채 옆의 3D 연기 정령과 함께 작업할 수 있어.</div>
                  $banner
                  <div class="stat">구독 에이전트 세션: $oauthBadge</div>
                  <div class="stat">실시간 라이브 음성: $rtBadge</div>
                  <div class="stat">SKT A.X K2 연동: $axBadge</div>
                </div>

                <div class="card">
                  <h2>1. ChatGPT 구독 계정 로그인 (백엔드 지속 컴패니언 세션)</h2>
                  <div class="sub">아래 버튼을 누르면 이 브라우저에서 바로 OpenAI OAuth 로그인이 진행되고 localhost:1455로 자동 복귀해.</div>
                  <a class="btn" href="/auth/start">ChatGPT 구독 OAuth 로그인 시작</a>
                </div>

                <div class="card">
                  <h2>2. 실시간 음성(gpt-realtime) · API 키 · auth.json 설정</h2>
                  <form method="POST" action="/setup/save">
                    <label>OpenAI API Key (gpt-realtime 양방향 음성 + text-embedding-3-small 768d)</label>
                    <input type="password" name="openai_api_key" placeholder="${if (snap.openaiApiKey.isNotBlank()) "저장됨 (변경 시 새 sk-... 입력)" else "sk-..."}" />

                    <label>SKT A.X K2 API Key (선택 · 모델 skt/a.ll/A.X-K2-ADOT)</label>
                    <input type="password" name="skt_ax_key" placeholder="${if (snap.sktAxApiKey.isNotBlank()) "저장됨 (ao_ak_sk_prd_...)" else "ao_ak_sk_prd_..."}" />
                    <div style="margin-bottom:12px">
                      <label><input type="checkbox" name="prefer_skt_ax" ${if (snap.preferSktAx) "checked" else ""}/> SKT A.X K2 모델을 기본 컴패니언 응답 엔진으로 우선 사용</label>
                    </div>

                    <label>또는 Codex auth.json 직접 붙여넣기 (선택)</label>
                    <textarea name="auth_json" placeholder='{"tokens":{"access_token":"...","refresh_token":"...","account_id":"..."}}'></textarea>

                    <button class="btn" type="submit">설정 저장 및 세션 연결</button>
                  </form>
                </div>

                <div class="card">
                  <h2>3. 2D 창에서 위습에게 바로 말 걸기 (테스트/텍스트 입력)</h2>
                  <form method="POST" action="/setup/say">
                    <input type="text" name="prompt" placeholder="예: 내가 방금 유심히 본 물건 기억나? 어울리는 거 딱 2개만 추천해줘!" />
                    <button class="btn-sec" type="submit">위습에게 보내기</button>
                  </form>
                  <form method="POST" action="/setup/logout" style="margin-top:12px">
                    <button class="btn-sec" type="submit">인증 정보 초기화</button>
                  </form>
                </div>
              </div>
            </body>
            </html>
        """.trimIndent()
    }
}
