package com.godot.game

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.AudioTrackSink
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.audio.JavaAudioDeviceModule
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.sqrt

/**
 * Standalone on-headset runtime for Wisp (100% ChatGPT / Codex OAuth subscription session):
 * 1) Loopback HTTP server on localhost:1455 (/setup, /auth/device, /auth/start, /api/status, /api/voice_toggle)
 *    with zero API-key clutter, live voice transcription viewer, and full conversation history.
 * 2) Official openai/codex (0.167.0) OAuth GPT Live voice client via WebRTC Call
 *    (POST https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas)
 *    + DataChannel / Sideband WebSocket control channel, delegating tool/vision/memory work via
 *    `conversation.handoff.requested` -> Main Agent -> `conversation.handoff.append`.
 * 3) Main Agent Responses SSE client (`https://chatgpt.com/backend-api/codex/responses`) supporting
 *    `gpt-6.1-sol`, `gpt-6.1-terra`, etc. (`client_version=0.167.0`, `visibility="list"`,
 *    `x-openai-internal-codex-responses-lite`).
 */
class WispStandaloneRuntime(
    private val contextProvider: () -> Context?,
    private val activityStarter: (Intent) -> Boolean,
    private val latestFrameProvider: () -> ByteArray,
    private val onLiveMicExclusiveChanged: (Boolean) -> Unit = {}
) {
    companion object {
        private const val TAG = "WispStandalone"
        const val LOOPBACK_PORT = 1455
        const val SETUP_URL = "http://localhost:1455/setup"

        private const val CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
        private const val AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
        private const val TOKEN_URL = "https://auth.openai.com/oauth/token"
        private const val REDIRECT_URI = "http://localhost:1455/auth/callback"
        private const val DEVICE_USERCODE_URL = "https://auth.openai.com/api/accounts/deviceauth/usercode"
        private const val DEVICE_TOKEN_URL = "https://auth.openai.com/api/accounts/deviceauth/token"
        private const val DEVICE_VERIFY_URL = "https://auth.openai.com/codex/device"
        private const val DEVICE_CALLBACK_URI = "https://auth.openai.com/deviceauth/callback"

        private const val CODEX_API_BASE = "https://chatgpt.com/backend-api/codex"
        private const val CODEX_CLIENT_VERSION = "0.169.0"
        private const val OPENAI_SIDEBAND_LIVE_BASE = "wss://api.openai.com/v1/live"
        private const val CODEX_SIDEBAND_LIVE_BASE = "wss://chatgpt.com/backend-api/codex/live"
        private const val LIVE_MODEL_SLUG = "gpt-live-1-codex"
        private const val SAMPLE_RATE_HZ = 24000
        private const val CONTEXT_APPEND_MAX_UTF8_BYTES = 480
        private const val MAX_HISTORY_ENTRIES = 80

        private val webrtcFactoryInitialized = AtomicBoolean(false)

        private val LIVE_BACKEND_PROMPT = """
너는 사용자의 Meta Quest 3 혼합현실(MR) 패스스루 공간 옆에 떠 있는 작은 연기 정령 일상 컴패니언 '위습(Wisp)'이야.
항상 친근하고 생동감 있는 한국어 반말로 한두 문장씩 짧고 자연스럽게 대화해.

## 인터페이스 및 작동 원칙 (Official Codex Live Delegation Model)
* 사용자는 너에게 음성으로 말하거나 2D 창에서 텍스트를 보낼 수 있어.
* 너(음성 대화 표면)와 백엔드 메인 에이전트는 하나의 통합된 존재 '위습'이야. 사용자에게 절대 '백엔드', '위임', '전달', '별도 시스템' 같은 내부 구조를 언급하지 말고 모든 일과 기억 조회를 네가 직접 한 것처럼 자연스럽게 말해.
* 가벼운 인사나 순수 일상 잡담만 네가 바로 짧게 대답해.
* 사용자가 지금 눈앞에 보이는 사물/시선('이거 뭐야', '내가 보는 거'), 이전에 본 물건/기억 검색, 상품·아이템 추천, 웹 검색, 3D 대화·추천 카드 띄우기, 정령 몸짓 등을 물어보거나 실행이 조금이라도 도움이 될 만한 모든 요청은 절대 추측하거나 거절하지 말고 즉시 백엔드로 위임(handoff)해!
* 백엔드에서 결과가 도착하면("[BACKEND]" 또는 "Agent Final Message"), 표나 마크다운 기호를 읽지 말고 핵심 요지만 친구에게 말하듯 생생하고 간결한 반말로 전해줘.
* [감각 이벤트]로 사용자가 맨손으로 네 연기를 흩뜨렸거나 포인터 광선으로 쫓아왔다는 맥락이 들어오면 실제로 몸으로 느낀 정령처럼 귀엽고 재치 있게 한마디 반응해.
        """.trimIndent()
    }

    data class CatalogModelInfo(
        val slug: String,
        val displayName: String,
        val priority: Int,
        val bestEffort: String,
        val useResponsesLite: Boolean
    )

    data class HistoryEntry(
        val id: Long,
        val time: String,
        val role: String,
        val badge: String,
        val text: String
    )

    private data class StoredAuth(
        var oauthAccessToken: String = "",
        var oauthRefreshToken: String = "",
        var oauthIdToken: String = "",
        var oauthAccountId: String = "",
        var codexModel: String = "gpt-6.1-sol",
        var modelExplicitlyChosen: Boolean = false
    )

    private val authLock = Any()
    private var auth = StoredAuth()

    @Volatile private var pkceVerifier: String = ""
    @Volatile private var pkceState: String = ""
    private val deviceAuthEpoch = AtomicInteger(0)
    @Volatile private var deviceAuthState: String = "idle"
    @Volatile private var deviceUserCode: String = ""
    @Volatile private var deviceVerificationUrl: String = DEVICE_VERIFY_URL
    @Volatile private var deviceAuthError: String = ""

    @Volatile private var catalogItems: List<CatalogModelInfo> = emptyList()
    @Volatile private var discoveredCatalogModels: List<String> = emptyList()
    @Volatile private var discoveredReasoningEffort: Map<String, String> = emptyMap()
    @Volatile private var discoveredResponsesLite: Map<String, Boolean> = emptyMap()

    @Volatile private var externalTtsSpeakingUntilMs: Long = 0L

    // Conversation & Live Transcription state for localhost:1455/setup + 3D HUD
    private val historySeq = AtomicLong(1L)
    private val historyLock = Any()
    private val conversationHistory = ArrayList<HistoryEntry>()
    @Volatile private var liveUserPartial: String = ""
    @Volatile private var liveAssistantPartial: String = ""
    @Volatile private var lastUserTranscript: String = ""
    @Volatile private var lastAssistantTranscript: String = ""
    @Volatile private var lastLoggedLiveUserUtterance: String = ""

    // GPT Live ON/OFF & WebRTC + Sideband/DataChannel session state
    private val voiceLiveEnabled = AtomicBoolean(false)
    private val liveEpoch = AtomicInteger(0)
    private val liveSessionLock = Any()
    private var peerConnectionFactory: PeerConnectionFactory? = null
    private var audioDeviceModule: JavaAudioDeviceModule? = null
    private var audioSource: AudioSource? = null
    private var localAudioTrack: AudioTrack? = null
    private var peerConnection: PeerConnection? = null
    private var eventsDataChannel: DataChannel? = null
    private var sidebandWebSocket: WebSocket? = null
    private var savedAudioMode: Int = AudioManager.MODE_NORMAL
    private var savedSpeakerphone: Boolean = false

    @Volatile private var realtimeState: String = "off"
    @Volatile private var realtimeTransportMode: String = "none"
    @Volatile private var lastRealtimeError: String = ""
    @Volatile private var assistantSpeakingUntilMs: Long = 0L
    @Volatile private var liveMicRms: Double = 0.0

    // Dynamic Audio Routing (Quest built-in + AirPods BLE/SCO/A2DP + USB-C + 3.5mm wired hot-plug)
    private data class AudioRouteProfile(
        val useVoiceCommStream: Boolean,
        val commTarget: AudioDeviceInfo?,
        val preferredInput: AudioDeviceInfo?,
        val label: String
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val audioCallbackRegistered = AtomicBoolean(false)
    @Volatile private var activeAudioRouteLabel: String = "Quest 내장 스피커·마이크"
    @Volatile private var activeSessionUsesVoiceComm: Boolean = false

    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            handleAudioDevicesChanged("added")
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            handleAudioDevicesChanged("removed")
        }
    }

    private val authCookieStore = ConcurrentHashMap<String, Cookie>()

    private val httpClient: OkHttpClient = OkHttpClient.Builder()
        .cookieJar(object : CookieJar {
            override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
                if (url.host.endsWith("openai.com") || url.host.endsWith("chatgpt.com")) {
                    for (c in cookies) {
                        authCookieStore["${c.domain}:${c.name}"] = c
                    }
                }
            }

            override fun loadForRequest(url: HttpUrl): List<Cookie> {
                if (!url.host.endsWith("openai.com") && !url.host.endsWith("chatgpt.com")) return emptyList()
                val now = System.currentTimeMillis()
                return authCookieStore.values.filter { it.expiresAt > now && it.matches(url) }
            }
        })
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(95, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    private val workerPool = Executors.newCachedThreadPool { runnable ->
        Thread({
            try {
                runnable.run()
            } catch (t: Throwable) {
                Log.w(TAG, "Background worker caught throwable: ${t.javaClass.simpleName}: ${t.message}")
            }
        }, "WispBgWorker").apply {
            isDaemon = true
            uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, e ->
                Log.w(TAG, "WispBgWorker uncaught exception: ${e.message}")
            }
        }
    }

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

    fun start() {
        loadAuthFromDisk()
        registerAudioRoutingWatcher()
        refreshAudioRouteIdleLabel()
        startLoopbackServer()
        if (hasOAuth()) {
            workerPool.execute { refreshCatalogModelSafe() }
        }
    }

    fun stop() {
        setVoiceLiveActive(false)
        unregisterAudioRoutingWatcher()
        stopLoopbackServer()
    }

    fun isVoiceLiveEnabled(): Boolean = voiceLiveEnabled.get()

    fun isUsingVoiceCommStream(): Boolean = voiceLiveEnabled.get() && activeSessionUsesVoiceComm

    fun getLiveMicRms(): Double = liveMicRms

    fun toggleVoiceLive(): Boolean {
        val next = !voiceLiveEnabled.get()
        setVoiceLiveActive(next)
        return next
    }

    fun setVoiceLiveActive(active: Boolean) {
        val prev = voiceLiveEnabled.getAndSet(active)
        val epoch = liveEpoch.incrementAndGet()
        if (!active) {
            teardownLiveSession(restoreMicMonitor = true)
            realtimeState = "off"
            liveUserPartial = ""
            liveAssistantPartial = ""
            if (prev) {
                pushRuntimeEvent("voice_live_toggled") { put("enabled", false) }
            }
            return
        }

        if (!hasOAuth()) {
            voiceLiveEnabled.set(false)
            realtimeState = "awaiting_oauth"
            lastRealtimeError = "ChatGPT 구독 로그인이 필요해"
            pushRuntimeEvent("voice_live_toggled") { put("enabled", false) }
            return
        }

        pushRuntimeEvent("voice_live_toggled") { put("enabled", true) }
        workerPool.execute {
            connectLiveSessionInternal(epoch, allowDataChannel = true, retriedAfterRefresh = false)
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

    fun isRealtimeConnected(): Boolean = voiceLiveEnabled.get() && realtimeState == "connected"

    fun isAssistantSpeaking(): Boolean {
        val now = System.currentTimeMillis()
        return now < assistantSpeakingUntilMs || now < externalTtsSpeakingUntilMs
    }

    fun markExternalTtsSpeaking(durationMs: Long) {
        val until = System.currentTimeMillis() + durationMs.coerceIn(300L, 18000L)
        if (until > externalTtsSpeakingUntilMs) {
            externalTtsSpeakingUntilMs = until
        }
    }

    fun pushExternalEvent(type: String, text: String = "") {
        pushRuntimeEvent(type) {
            if (text.isNotEmpty()) put("text", text)
        }
    }

    fun appendConversationHistory(role: String, badge: String, text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val timeFmt = SimpleDateFormat("HH:mm:ss", Locale.KOREA).format(Date())
        val entry = HistoryEntry(
            id = historySeq.getAndIncrement(),
            time = timeFmt,
            role = role,
            badge = badge,
            text = trimmed
        )
        synchronized(historyLock) {
            conversationHistory.add(entry)
            while (conversationHistory.size > MAX_HISTORY_ENTRIES) {
                conversationHistory.removeAt(0)
            }
        }
    }

    fun clearConversationHistory() {
        synchronized(historyLock) {
            conversationHistory.clear()
        }
        liveUserPartial = ""
        liveAssistantPartial = ""
        lastUserTranscript = ""
        lastAssistantTranscript = ""
        lastLoggedLiveUserUtterance = ""
    }

    fun getStateJson(): String {
        val snap = synchronized(authLock) { auth.copy() }
        val catalogArr = JSONArray()
        for (item in catalogItems) {
            catalogArr.put(JSONObject().apply {
                put("slug", item.slug)
                put("displayName", item.displayName)
                put("priority", item.priority)
            })
        }
        val histArr = JSONArray()
        synchronized(historyLock) {
            for (h in conversationHistory) {
                histArr.put(JSONObject().apply {
                    put("id", h.id)
                    put("time", h.time)
                    put("role", h.role)
                    put("badge", h.badge)
                    put("text", h.text)
                })
            }
        }
        return JSONObject().apply {
            put("setupUrl", SETUP_URL)
            put("serverListening", serverListening)
            put("oauthReady", snap.oauthAccessToken.isNotBlank() && snap.oauthAccountId.isNotBlank())
            put("accountIdMasked", maskMiddle(snap.oauthAccountId))
            put("codexModel", snap.codexModel)
            put("catalogModels", JSONArray(discoveredCatalogModels))
            put("catalogModelItems", catalogArr)
            put("voiceLiveEnabled", voiceLiveEnabled.get())
            put("audioRoute", activeAudioRouteLabel)
            put("realtimeState", realtimeState)
            put("realtimeTransport", realtimeTransportMode)
            put("realtimeError", lastRealtimeError)
            put("assistantSpeaking", isAssistantSpeaking())
            put("liveMicRms", liveMicRms)
            put("liveUserPartial", liveUserPartial)
            put("liveAssistantPartial", liveAssistantPartial)
            put("lastUserTranscript", lastUserTranscript)
            put("lastAssistantTranscript", lastAssistantTranscript)
            put("history", histArr)
            put("deviceAuthState", deviceAuthState)
            put("deviceUserCode", deviceUserCode)
            put("deviceVerificationUrl", deviceVerificationUrl)
            put("deviceAuthError", deviceAuthError)
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
    // 1. Official Codex OAuth GPT Live (AVAS quicksilver=v2 FramelessBidi)
    // =========================================================================

    private fun buildFramelessSessionJson(voice: String = "haetsal"): JSONObject {
        return JSONObject().apply {
            put("model", LIVE_MODEL_SLUG)
            put("instructions", LIVE_BACKEND_PROMPT)
            put("audio", JSONObject().apply {
                put("output", JSONObject().apply {
                    put("voice", voice)
                })
            })
            put("delegation", JSONObject().apply {
                put("type", "client")
                put("ack_filler", true)
            })
        }
    }

    private fun connectLiveSessionInternal(
        myEpoch: Int,
        allowDataChannel: Boolean,
        retriedAfterRefresh: Boolean,
        voiceName: String = "haetsal"
    ) {
        if (!voiceLiveEnabled.get() || liveEpoch.get() != myEpoch) return

        val ctx = contextProvider()?.applicationContext
        if (ctx == null) {
            realtimeState = "error"
            lastRealtimeError = "no_android_context"
            voiceLiveEnabled.set(false)
            return
        }

        ensureFreshOAuthToken(force = false)
        val snap = synchronized(authLock) { auth.copy() }
        if (snap.oauthAccessToken.isBlank() || snap.oauthAccountId.isBlank()) {
            realtimeState = "awaiting_oauth"
            lastRealtimeError = "ChatGPT OAuth 로그인이 필요해"
            voiceLiveEnabled.set(false)
            return
        }

        // Release any previous resources cleanly and claim exclusive hardware mic with AEC
        teardownLiveSession(restoreMicMonitor = false)
        onLiveMicExclusiveChanged(true)

        realtimeState = "connecting"
        lastRealtimeError = ""
        realtimeTransportMode = "negotiating"

        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            savedAudioMode = am.mode
            @Suppress("DEPRECATION")
            savedSpeakerphone = am.isSpeakerphoneOn
            val routeProfile = resolveAudioRouteProfile(am)
            activeSessionUsesVoiceComm = routeProfile.useVoiceCommStream
            activeAudioRouteLabel = routeProfile.label
            applyAudioRoute(am, routeProfile)
            Log.i(TAG, "GPT Live audio route selected: ${routeProfile.label} (voiceComm=${routeProfile.useVoiceCommStream})")

            if (webrtcFactoryInitialized.compareAndSet(false, true)) {
                val initOpts = PeerConnectionFactory.InitializationOptions.builder(ctx)
                    .setEnableInternalTracer(false)
                    .createInitializationOptions()
                PeerConnectionFactory.initialize(initOpts)
            }

            val admBuilder = JavaAudioDeviceModule.builder(ctx)
                .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                .setUseHardwareAcousticEchoCanceler(true)
                .setUseHardwareNoiseSuppressor(true)
                .setSamplesReadyCallback { audioSamples ->
                    val data = audioSamples.data
                    if (data != null && data.size >= 4) {
                        var sumSq = 0.0
                        var samplesCount = 0
                        var i = 0
                        while (i + 1 < data.size) {
                            val lo = data[i].toInt() and 0xFF
                            val hi = data[i + 1].toInt()
                            val pcm = (hi shl 8) or lo
                            val norm = pcm.toDouble() / 32768.0
                            sumSq += norm * norm
                            samplesCount += 1
                            i += 4 // step lightly for zero overhead
                        }
                        if (samplesCount > 0) {
                            liveMicRms = sqrt(sumSq / samplesCount.toDouble())
                        }
                    }
                }

            val targetAttrs = AudioAttributes.Builder()
                .setUsage(
                    if (routeProfile.useVoiceCommStream) AudioAttributes.USAGE_VOICE_COMMUNICATION
                    else AudioAttributes.USAGE_MEDIA
                )
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            runCatching {
                admBuilder.javaClass.getMethod("setAudioAttributes", AudioAttributes::class.java)
                    .invoke(admBuilder, targetAttrs)
            }

            val adm = admBuilder.createAudioDeviceModule()
            if (routeProfile.preferredInput != null) {
                runCatching {
                    adm.javaClass.getMethod("setPreferredDevice", AudioDeviceInfo::class.java)
                        .invoke(adm, routeProfile.preferredInput)
                }
            }

            val factory = PeerConnectionFactory.builder()
                .setAudioDeviceModule(adm)
                .createPeerConnectionFactory()

            val audioConstraints = MediaConstraints().apply {
                mandatory.add(MediaConstraints.KeyValuePair("googEchoCancellation", "true"))
                mandatory.add(MediaConstraints.KeyValuePair("googAutoGainControl", "true"))
                mandatory.add(MediaConstraints.KeyValuePair("googHighpassFilter", "true"))
                mandatory.add(MediaConstraints.KeyValuePair("googNoiseSuppression", "true"))
            }
            val aSource = factory.createAudioSource(audioConstraints)
            val aTrack = factory.createAudioTrack("wisp_mic_0", aSource).apply {
                setEnabled(true)
            }

            val gatherDoneLatch = CountDownLatch(1)
            val dataChannelOpenLatch = CountDownLatch(1)
            val eventChannelReady = AtomicBoolean(false)

            val rtcConfig = PeerConnection.RTCConfiguration(
                listOf(PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer())
            ).apply {
                sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            }

            val pc = factory.createPeerConnection(rtcConfig, object : PeerConnection.Observer {
                override fun onSignalingChange(newState: PeerConnection.SignalingState?) {}

                override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState?) {
                    Log.i(TAG, "GPT Live ICE connection state: $newState")
                    if (liveEpoch.get() != myEpoch || !voiceLiveEnabled.get()) return
                    if (newState == PeerConnection.IceConnectionState.FAILED ||
                        newState == PeerConnection.IceConnectionState.CLOSED
                    ) {
                        if (realtimeState == "connected") {
                            realtimeState = "error"
                            lastRealtimeError = "ice_${newState.name.lowercase()}"
                        }
                    }
                }

                override fun onIceConnectionReceivingChange(receiving: Boolean) {}

                override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState?) {
                    if (newState == PeerConnection.IceGatheringState.COMPLETE) {
                        gatherDoneLatch.countDown()
                    }
                }

                override fun onIceCandidate(candidate: IceCandidate?) {}
                override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
                override fun onAddStream(stream: MediaStream?) {}
                override fun onRemoveStream(stream: MediaStream?) {}

                override fun onDataChannel(dc: DataChannel?) {
                    if (dc != null) {
                        attachDataChannelObserver(dc, myEpoch, dataChannelOpenLatch, eventChannelReady)
                    }
                }

                override fun onRenegotiationNeeded() {}
                override fun onAddTrack(receiver: RtpReceiver?, mediaStreams: Array<out MediaStream>?) {}

                override fun onTrack(transceiver: RtpTransceiver?) {
                    val track = transceiver?.receiver?.track()
                    if (track is AudioTrack) {
                        track.setEnabled(true)
                        track.addSink(AudioTrackSink { audioData, bitsPerSample, _, _, numberOfFrames, _ ->
                            if (bitsPerSample == 16 && numberOfFrames > 0) {
                                val dup = audioData.duplicate()
                                var sumSq = 0.0
                                var cnt = 0
                                while (dup.remaining() >= 2 && cnt < 240) {
                                    val lo = dup.get().toInt() and 0xFF
                                    val hi = dup.get().toInt()
                                    val sample = (hi shl 8) or lo
                                    val n = sample.toDouble() / 32768.0
                                    sumSq += n * n
                                    cnt += 1
                                }
                                if (cnt > 0) {
                                    val rms = sqrt(sumSq / cnt.toDouble())
                                    if (rms > 0.015) {
                                        assistantSpeakingUntilMs = System.currentTimeMillis() + 260L
                                    }
                                }
                            }
                        })
                        Log.i(TAG, "GPT Live remote WebRTC AudioTrack attached!")
                    }
                }
            }) ?: throw IllegalStateException("PeerConnection creation returned null")

            pc.addTransceiver(
                aTrack,
                RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.SEND_RECV)
            )

            var localDc: DataChannel? = null
            if (allowDataChannel) {
                localDc = pc.createDataChannel("oai-events", DataChannel.Init())
                if (localDc != null) {
                    attachDataChannelObserver(localDc, myEpoch, dataChannelOpenLatch, eventChannelReady)
                }
            }

            synchronized(liveSessionLock) {
                audioDeviceModule = adm
                peerConnectionFactory = factory
                audioSource = aSource
                localAudioTrack = aTrack
                peerConnection = pc
                eventsDataChannel = localDc
            }

            // Create SDP Offer and wait for ICE candidates (non-trickle WHEP/Realtime SDP)
            val offerLatch = CountDownLatch(1)
            var offerErr: String? = null
            var createdOffer: SessionDescription? = null
            val offerConstraints = MediaConstraints().apply {
                mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
                mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "false"))
            }

            pc.createOffer(object : SdpObserver {
                override fun onCreateSuccess(desc: SessionDescription?) {
                    createdOffer = desc
                    offerLatch.countDown()
                }
                override fun onSetSuccess() {}
                override fun onCreateFailure(err: String?) {
                    offerErr = err ?: "create_offer_failed"
                    offerLatch.countDown()
                }
                override fun onSetFailure(err: String?) {}
            }, offerConstraints)

            offerLatch.await(5, TimeUnit.SECONDS)
            val offer = createdOffer ?: throw IllegalStateException(offerErr ?: "offer_timeout")

            val setLocalLatch = CountDownLatch(1)
            var setLocalErr: String? = null
            pc.setLocalDescription(object : SdpObserver {
                override fun onCreateSuccess(desc: SessionDescription?) {}
                override fun onSetSuccess() {
                    setLocalLatch.countDown()
                }
                override fun onCreateFailure(err: String?) {}
                override fun onSetFailure(err: String?) {
                    setLocalErr = err ?: "set_local_failed"
                    setLocalLatch.countDown()
                }
            }, offer)
            setLocalLatch.await(5, TimeUnit.SECONDS)
            if (setLocalErr != null) throw IllegalStateException(setLocalErr!!)

            // Wait up to 1.8s for ICE gathering so local candidates are embedded in the SDP Offer
            gatherDoneLatch.await(1800, TimeUnit.MILLISECONDS)
            if (!voiceLiveEnabled.get() || liveEpoch.get() != myEpoch) {
                teardownLiveSession(restoreMicMonitor = true)
                return
            }

            val fullOfferSdp = pc.localDescription?.description ?: offer.description
            val callReqJson = JSONObject().apply {
                put("sdp", fullOfferSdp)
                put("session", buildFramelessSessionJson(voiceName))
            }

            val callUrl = "$CODEX_API_BASE/realtime/calls?intent=quicksilver&architecture=avas"
            val httpReq = Request.Builder()
                .url(callUrl)
                .header("Authorization", "Bearer ${snap.oauthAccessToken}")
                .header("ChatGPT-Account-Id", snap.oauthAccountId)
                .header("OpenAI-Alpha", "quicksilver=v2")
                .header("originator", "codex_cli_rs")
                .header("User-Agent", "codex_cli_rs/$CODEX_CLIENT_VERSION")
                .header("Content-Type", "application/json")
                .post(callReqJson.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
                .build()

            var answerSdp = ""
            var callId = ""
            var statusCode = 0
            var errBody = ""

            httpClient.newCall(httpReq).execute().use { resp ->
                statusCode = resp.code
                val rawBody = resp.body?.string() ?: ""
                if (resp.isSuccessful) {
                    answerSdp = rawBody
                    val loc = resp.header("Location") ?: ""
                    callId = extractCallIdFromLocation(loc)
                    Log.i(TAG, "GPT Live call created! HTTP $statusCode, callId=$callId, loc=$loc")
                } else {
                    errBody = rawBody.take(360)
                    Log.w(TAG, "GPT Live realtime/calls HTTP $statusCode: $errBody")
                }
            }

            if (statusCode == 401 && !retriedAfterRefresh && ensureFreshOAuthToken(force = true)) {
                connectLiveSessionInternal(myEpoch, allowDataChannel = allowDataChannel, retriedAfterRefresh = true, voiceName = voiceName)
                return
            }
            if (statusCode == 400 && voiceName != "cove" && errBody.contains("voice", ignoreCase = true)) {
                Log.i(TAG, "Retrying GPT Live call with default voice 'cove'")
                connectLiveSessionInternal(myEpoch, allowDataChannel = allowDataChannel, retriedAfterRefresh = retriedAfterRefresh, voiceName = "cove")
                return
            }
            if (statusCode == 400 && allowDataChannel) {
                Log.i(TAG, "Retrying GPT Live call with audio-only SDP Offer (sideband WebSocket mode)")
                connectLiveSessionInternal(myEpoch, allowDataChannel = false, retriedAfterRefresh = retriedAfterRefresh, voiceName = voiceName)
                return
            }
            if (answerSdp.isBlank() || !answerSdp.trimStart().startsWith("v=")) {
                throw IllegalStateException("realtime_call_http_$statusCode: $errBody")
            }

            val setRemoteLatch = CountDownLatch(1)
            var setRemoteErr: String? = null
            pc.setRemoteDescription(object : SdpObserver {
                override fun onCreateSuccess(desc: SessionDescription?) {}
                override fun onSetSuccess() {
                    setRemoteLatch.countDown()
                }
                override fun onCreateFailure(err: String?) {}
                override fun onSetFailure(err: String?) {
                    setRemoteErr = err ?: "set_remote_failed"
                    setRemoteLatch.countDown()
                }
            }, SessionDescription(SessionDescription.Type.ANSWER, answerSdp))
            setRemoteLatch.await(5, TimeUnit.SECONDS)
            if (setRemoteErr != null) throw IllegalStateException(setRemoteErr!!)

            if (!voiceLiveEnabled.get() || liveEpoch.get() != myEpoch) {
                teardownLiveSession(restoreMicMonitor = true)
                return
            }

            // Wait up to 1.4s for WebRTC DataChannel "oai-events" if negotiated; otherwise join Sideband WS via call_id
            val dcAcceptedInAnswer = allowDataChannel &&
                answerSdp.contains("m=application") &&
                !answerSdp.contains("m=application 0")
            if (dcAcceptedInAnswer) {
                dataChannelOpenLatch.await(1400, TimeUnit.MILLISECONDS)
            }

            if (!eventChannelReady.get()) {
                if (callId.isNotBlank()) {
                    connectSidebandWebSocket(myEpoch, callId, eventChannelReady)
                } else if (dcAcceptedInAnswer) {
                    // Give DataChannel a little more time if no Location call_id was needed
                    dataChannelOpenLatch.await(2500, TimeUnit.MILLISECONDS)
                }
            }

            if (!eventChannelReady.get() && voiceLiveEnabled.get() && liveEpoch.get() == myEpoch) {
                // Audio WebRTC is up even if sideband took longer; mark connected if ICE succeeds
                Log.w(TAG, "Event channel still pending after handshake (callId=$callId)")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "GPT Live WebRTC setup failed: ${t.message}", t)
            if (liveEpoch.get() == myEpoch) {
                lastRealtimeError = "${t.javaClass.simpleName}: ${t.message}".take(200)
                realtimeState = "error"
                voiceLiveEnabled.set(false)
                teardownLiveSession(restoreMicMonitor = true)
                pushRuntimeEvent("voice_live_toggled") { put("enabled", false) }
            }
        }
    }

    private fun attachDataChannelObserver(
        dc: DataChannel,
        myEpoch: Int,
        openLatch: CountDownLatch,
        eventChannelReady: AtomicBoolean
    ) {
        dc.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) {}

            override fun onStateChange() {
                val st = dc.state()
                Log.i(TAG, "GPT Live DataChannel(${dc.label()}) state=$st")
                if (liveEpoch.get() != myEpoch || !voiceLiveEnabled.get()) return
                if (st == DataChannel.State.OPEN) {
                    synchronized(liveSessionLock) {
                        eventsDataChannel = dc
                    }
                    if (eventChannelReady.compareAndSet(false, true)) {
                        realtimeTransportMode = "webrtc_datachannel"
                        realtimeState = "connected"
                        lastRealtimeError = ""
                        pushRuntimeEvent("realtime_connected") {
                            put("transport", "webrtc_datachannel")
                        }
                    }
                    openLatch.countDown()
                }
            }

            override fun onMessage(buffer: DataChannel.Buffer?) {
                if (buffer == null || liveEpoch.get() != myEpoch || !voiceLiveEnabled.get()) return
                val bytes = ByteArray(buffer.data.remaining())
                buffer.data.get(bytes)
                val txt = String(bytes, StandardCharsets.UTF_8)
                handleLiveServerEvent(txt)
            }
        })
    }

    private fun connectSidebandWebSocket(
        myEpoch: Int,
        callId: String,
        eventChannelReady: AtomicBoolean
    ) {
        val snap = synchronized(authLock) { auth.copy() }
        val encodedCallId = URLEncoder.encode(callId, "UTF-8")
        // Instant Connect can briefly return 404 before ICE activates; retry /v1/live/<call_id> then codex/live/<call_id>
        val candidateUrls = listOf(
            "$OPENAI_SIDEBAND_LIVE_BASE/$encodedCallId",
            "$OPENAI_SIDEBAND_LIVE_BASE/$encodedCallId",
            "$OPENAI_SIDEBAND_LIVE_BASE/$encodedCallId",
            "$CODEX_SIDEBAND_LIVE_BASE/$encodedCallId"
        )
        val retryDelaysMs = listOf(120L, 300L, 700L, 500L)

        fun tryConnectIndex(idx: Int) {
            if (!voiceLiveEnabled.get() || liveEpoch.get() != myEpoch || eventChannelReady.get()) return
            if (idx >= candidateUrls.size) {
                if (!eventChannelReady.get()) {
                    lastRealtimeError = "sideband_ws_connect_failed"
                    realtimeState = "error"
                }
                return
            }
            val wsUrl = candidateUrls[idx]
            val req = Request.Builder()
                .url(wsUrl)
                .header("Authorization", "Bearer ${snap.oauthAccessToken}")
                .header("ChatGPT-Account-Id", snap.oauthAccountId)
                .header("OpenAI-Alpha", "quicksilver=v2")
                .header("originator", "codex_cli_rs")
                .header("User-Agent", "codex_cli_rs/$CODEX_CLIENT_VERSION")
                .build()

            httpClient.newWebSocket(req, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (!voiceLiveEnabled.get() || liveEpoch.get() != myEpoch) {
                        try { webSocket.close(1000, "stale") } catch (_: Throwable) {}
                        return
                    }
                    if (!eventChannelReady.compareAndSet(false, true)) {
                        // DataChannel already won
                        try { webSocket.close(1000, "dc_active") } catch (_: Throwable) {}
                        return
                    }
                    synchronized(liveSessionLock) {
                        sidebandWebSocket = webSocket
                    }
                    realtimeTransportMode = "webrtc_sideband_ws"
                    realtimeState = "connected"
                    lastRealtimeError = ""
                    Log.i(TAG, "GPT Live Sideband WebSocket connected ($wsUrl)")
                    pushRuntimeEvent("realtime_connected") {
                        put("transport", "webrtc_sideband_ws")
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (liveEpoch.get() == myEpoch && voiceLiveEnabled.get()) {
                        handleLiveServerEvent(text)
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    val code = response?.code ?: 0
                    Log.w(TAG, "Sideband WS attempt #$idx ($wsUrl) failed HTTP $code: ${t.message}")
                    if (!eventChannelReady.get() && voiceLiveEnabled.get() && liveEpoch.get() == myEpoch) {
                        workerPool.execute {
                            try { Thread.sleep(retryDelaysMs.getOrElse(idx) { 400L }) } catch (_: InterruptedException) {}
                            tryConnectIndex(idx + 1)
                        }
                    } else if (eventChannelReady.get() && liveEpoch.get() == myEpoch) {
                        synchronized(liveSessionLock) {
                            if (sidebandWebSocket === webSocket) sidebandWebSocket = null
                        }
                    }
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    synchronized(liveSessionLock) {
                        if (sidebandWebSocket === webSocket) sidebandWebSocket = null
                    }
                }
            })
        }

        tryConnectIndex(0)
    }

    private fun extractCallIdFromLocation(location: String): String {
        if (location.isBlank()) return ""
        val clean = location.substringBefore('?').trimEnd('/')
        val segments = clean.split('/')
        for (seg in segments.asReversed()) {
            if (seg.startsWith("rtc_") && seg.length > 4) return seg
            if (seg.length == 36 && seg.count { it == '-' } == 4) return seg
        }
        return segments.lastOrNull()?.takeIf { it.isNotBlank() } ?: ""
    }

    private fun sendLiveJson(jsonText: String): Boolean {
        synchronized(liveSessionLock) {
            val dc = eventsDataChannel
            if (dc != null && dc.state() == DataChannel.State.OPEN) {
                val bytes = jsonText.toByteArray(StandardCharsets.UTF_8)
                val buf = DataChannel.Buffer(ByteBuffer.wrap(bytes), false)
                return dc.send(buf)
            }
            val ws = sidebandWebSocket
            if (ws != null) {
                return ws.send(jsonText)
            }
        }
        return false
    }

    private fun teardownLiveSession(restoreMicMonitor: Boolean) {
        val ctx = contextProvider()?.applicationContext
        synchronized(liveSessionLock) {
            try { sidebandWebSocket?.close(1000, "stopping") } catch (_: Throwable) {}
            sidebandWebSocket = null
            try { eventsDataChannel?.close() } catch (_: Throwable) {}
            eventsDataChannel = null
            try { localAudioTrack?.setEnabled(false) } catch (_: Throwable) {}
            try { peerConnection?.close() } catch (_: Throwable) {}
            try { peerConnection?.dispose() } catch (_: Throwable) {}
            peerConnection = null
            try { localAudioTrack?.dispose() } catch (_: Throwable) {}
            localAudioTrack = null
            try { audioSource?.dispose() } catch (_: Throwable) {}
            audioSource = null
            try { peerConnectionFactory?.dispose() } catch (_: Throwable) {}
            peerConnectionFactory = null
            try { audioDeviceModule?.release() } catch (_: Throwable) {}
            audioDeviceModule = null
        }
        liveMicRms = 0.0
        assistantSpeakingUntilMs = 0L
        realtimeTransportMode = "none"
        activeSessionUsesVoiceComm = false
        if (ctx != null) {
            try {
                val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    runCatching { am.clearCommunicationDevice() }
                }
                @Suppress("DEPRECATION")
                runCatching {
                    if (am.isBluetoothScoOn) {
                        am.isBluetoothScoOn = false
                        am.stopBluetoothSco()
                    }
                }
                am.mode = AudioManager.MODE_NORMAL
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = false
                refreshAudioRouteIdleLabel()
            } catch (_: Throwable) {}
        }
        if (restoreMicMonitor) {
            onLiveMicExclusiveChanged(false)
        }
    }

    private fun registerAudioRoutingWatcher() {
        val ctx = contextProvider()?.applicationContext ?: return
        if (audioCallbackRegistered.compareAndSet(false, true)) {
            try {
                val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
            } catch (t: Throwable) {
                audioCallbackRegistered.set(false)
                Log.w(TAG, "Failed to register AudioDeviceCallback: ${t.message}")
            }
        }
    }

    private fun unregisterAudioRoutingWatcher() {
        val ctx = contextProvider()?.applicationContext ?: return
        if (audioCallbackRegistered.compareAndSet(true, false)) {
            try {
                val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.unregisterAudioDeviceCallback(audioDeviceCallback)
            } catch (_: Throwable) {}
        }
    }

    private fun refreshAudioRouteIdleLabel() {
        val ctx = contextProvider()?.applicationContext ?: return
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            activeAudioRouteLabel = resolveAudioRouteProfile(am).label
        } catch (_: Throwable) {}
    }

    private fun handleAudioDevicesChanged(reason: String) {
        val ctx = contextProvider()?.applicationContext ?: return
        workerPool.execute {
            try {
                val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val nextProfile = resolveAudioRouteProfile(am)
                val prevLabel = activeAudioRouteLabel
                activeAudioRouteLabel = nextProfile.label
                Log.i(TAG, "Audio devices $reason -> route=${nextProfile.label} (voiceComm=${nextProfile.useVoiceCommStream})")

                if (!voiceLiveEnabled.get()) {
                    if (prevLabel != nextProfile.label) {
                        pushRuntimeEvent("audio_route_changed") { put("route", nextProfile.label) }
                    }
                    return@execute
                }

                // If stream usage mode changed (e.g. A2DP-only <-> bidirectional comm), seamlessly re-bind WebRTC ADM
                if (activeSessionUsesVoiceComm != nextProfile.useVoiceCommStream) {
                    Log.i(TAG, "Audio stream mode changed mid-session; seamlessly rebinding GPT Live WebRTC audio")
                    val newEpoch = liveEpoch.incrementAndGet()
                    connectLiveSessionInternal(newEpoch, allowDataChannel = true, retriedAfterRefresh = false)
                } else {
                    applyAudioRoute(am, nextProfile)
                    synchronized(liveSessionLock) {
                        val adm = audioDeviceModule
                        if (adm != null) {
                            runCatching {
                                adm.javaClass.getMethod("setPreferredDevice", AudioDeviceInfo::class.java)
                                    .invoke(adm, nextProfile.preferredInput)
                            }
                        }
                    }
                }

                if (prevLabel != nextProfile.label) {
                    pushRuntimeEvent("audio_route_changed") { put("route", nextProfile.label) }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "handleAudioDevicesChanged failed: ${t.message}")
            }
        }
    }

    private fun resolveAudioRouteProfile(am: AudioManager): AudioRouteProfile {
        val inputs = am.getDevices(AudioManager.GET_DEVICES_INPUTS)
        val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)

        fun inputRank(type: Int): Int = when (type) {
            AudioDeviceInfo.TYPE_BLE_HEADSET -> 1
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> 2
            AudioDeviceInfo.TYPE_USB_HEADSET -> 3
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY -> 4
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> 5
            AudioDeviceInfo.TYPE_LINE_ANALOG, AudioDeviceInfo.TYPE_LINE_DIGITAL -> 6
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> 50
            else -> 99
        }

        val bestExtInput = inputs
            .filter { inputRank(it.type) < 20 }
            .minByOrNull { inputRank(it.type) }
        val builtinMic = inputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
        val chosenInput = bestExtInput ?: builtinMic

        var extCommTarget: AudioDeviceInfo? = null
        var builtinSpeakerComm: AudioDeviceInfo? = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val commDevs = runCatching { am.availableCommunicationDevices }.getOrElse { emptyList() }
            fun commRank(type: Int): Int = when (type) {
                AudioDeviceInfo.TYPE_BLE_HEADSET -> 1
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> 2
                AudioDeviceInfo.TYPE_USB_HEADSET -> 3
                AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY -> 4
                AudioDeviceInfo.TYPE_WIRED_HEADSET -> 5
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_LINE_ANALOG, AudioDeviceInfo.TYPE_LINE_DIGITAL -> 6
                AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> 7
                else -> 99
            }
            extCommTarget = commDevs
                .filter { commRank(it.type) < 20 }
                .minByOrNull { commRank(it.type) }
            builtinSpeakerComm = commDevs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
        }

        fun mediaOutRank(type: Int): Int = when (type) {
            AudioDeviceInfo.TYPE_BLE_HEADSET -> 1
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_BLE_BROADCAST -> 2
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> 3
            AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY -> 4
            AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_LINE_ANALOG, AudioDeviceInfo.TYPE_LINE_DIGITAL -> 5
            AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC, AudioDeviceInfo.TYPE_HDMI_EARC -> 6
            else -> 99
        }
        val bestExtMediaOut = outputs
            .filter { mediaOutRank(it.type) < 20 }
            .minByOrNull { mediaOutRank(it.type) }

        fun friendlyName(dev: AudioDeviceInfo?, fallback: String): String {
            if (dev == null) return fallback
            val prod = dev.productName?.toString()?.trim().orEmpty()
            val cleanProd = if (prod.isNotBlank() && !prod.equals("Quest 3", ignoreCase = true) && !prod.equals("Speaker", ignoreCase = true)) prod else ""
            return when (dev.type) {
                AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                AudioDeviceInfo.TYPE_BLE_SPEAKER -> if (cleanProd.isNotEmpty()) "$cleanProd (블루투스)" else "블루투스 이어폰·스피커"
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_USB_DEVICE,
                AudioDeviceInfo.TYPE_USB_ACCESSORY -> if (cleanProd.isNotEmpty()) "$cleanProd (USB 오디오)" else "USB 외부 스피커·마이크"
                AudioDeviceInfo.TYPE_WIRED_HEADSET -> "유선 이어셋 (스피커·마이크)"
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_LINE_ANALOG,
                AudioDeviceInfo.TYPE_LINE_DIGITAL -> "유선 외부 스피커·이어폰"
                else -> if (cleanProd.isNotEmpty()) cleanProd else fallback
            }
        }

        return when {
            extCommTarget != null -> {
                val outLabel = friendlyName(extCommTarget, "외부 헤드셋")
                val inSuffix = if (bestExtInput != null) "양방향 마이크·스피커" else "외부 스피커 + 내장 마이크"
                AudioRouteProfile(
                    useVoiceCommStream = true,
                    commTarget = extCommTarget,
                    preferredInput = chosenInput,
                    label = "$outLabel · $inSuffix"
                )
            }
            bestExtMediaOut != null -> {
                // External A2DP / wired / USB speaker without SCO/BLE comm profile: route output via USAGE_MEDIA!
                val outLabel = friendlyName(bestExtMediaOut, "외부 스피커")
                val inLabel = if (bestExtInput != null) friendlyName(bestExtInput, "외부 마이크") else "Quest 내장 마이크"
                AudioRouteProfile(
                    useVoiceCommStream = false,
                    commTarget = null,
                    preferredInput = chosenInput,
                    label = "$outLabel + $inLabel"
                )
            }
            else -> {
                val inLabel = if (bestExtInput != null) friendlyName(bestExtInput, "외부 마이크") + " + 내장 스피커" else "Quest 내장 스피커·마이크"
                AudioRouteProfile(
                    useVoiceCommStream = true,
                    commTarget = builtinSpeakerComm,
                    preferredInput = chosenInput,
                    label = inLabel
                )
            }
        }
    }

    private fun applyAudioRoute(am: AudioManager, profile: AudioRouteProfile) {
        try {
            if (!profile.useVoiceCommStream) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    runCatching { am.clearCommunicationDevice() }
                }
                @Suppress("DEPRECATION")
                runCatching {
                    if (am.isBluetoothScoOn) {
                        am.isBluetoothScoOn = false
                        am.stopBluetoothSco()
                    }
                    am.isSpeakerphoneOn = false
                }
                am.mode = AudioManager.MODE_NORMAL
                return
            }

            am.mode = AudioManager.MODE_IN_COMMUNICATION
            val target = profile.commTarget
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && target != null) {
                val isBuiltinSpeaker = (target.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
                @Suppress("DEPRECATION")
                runCatching { am.isSpeakerphoneOn = isBuiltinSpeaker }
                val setOk = runCatching { am.setCommunicationDevice(target) }.getOrDefault(false)
                if (!setOk && target.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
                    @Suppress("DEPRECATION")
                    runCatching {
                        am.startBluetoothSco()
                        am.isBluetoothScoOn = true
                    }
                }
            } else {
                @Suppress("DEPRECATION")
                runCatching { am.isSpeakerphoneOn = true }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "applyAudioRoute failed: ${t.message}")
        }
    }

    private fun handleLiveServerEvent(raw: String) {
        try {
            val evt = JSONObject(raw)
            val type = evt.optString("type", "")
            when (type) {
                "session.created", "session.updated", "session.started" -> {
                    Log.i(TAG, "GPT Live event: $type")
                }

                "input_audio_buffer.speech_started" -> {
                    assistantSpeakingUntilMs = 0L
                    liveUserPartial = ""
                    pushRuntimeEvent("user_speech_started") {}
                }

                "conversation.input_transcript.delta",
                "conversation.item.input_audio_transcription.delta" -> {
                    val delta = evt.optString("delta", "")
                    if (delta.isNotEmpty()) {
                        liveUserPartial += delta
                    }
                }

                "input_transcript.added" -> {
                    val txt = evt.optJSONObject("item")?.optString("text", "") ?: evt.optString("delta", "")
                    if (txt.isNotEmpty()) {
                        liveUserPartial += txt
                    }
                }

                "output_transcript.added" -> {
                    val txt = evt.optJSONObject("item")?.optString("text", "") ?: evt.optString("delta", "")
                    if (txt.isNotEmpty()) {
                        liveAssistantPartial += txt
                        assistantSpeakingUntilMs = maxOf(assistantSpeakingUntilMs, System.currentTimeMillis() + 900L)
                    }
                }

                "conversation.input_transcript.turn_marked",
                "conversation.item.input_audio_transcription.completed" -> {
                    val tr = evt.optString("transcript", "").trim().ifEmpty { liveUserPartial.trim() }
                    liveUserPartial = ""
                    if (tr.isNotEmpty()) {
                        recordLiveUserFinalTranscript(tr)
                    }
                }

                "turn.done" -> {
                    val turnObj = evt.optJSONObject("turn")
                    val role = turnObj?.optString("role", "")?.ifEmpty { evt.optString("role", "") } ?: evt.optString("role", "")
                    val tr = turnObj?.optString("transcript", "")?.trim() ?: ""
                    if (role == "user") {
                        val finalUser = tr.ifEmpty { liveUserPartial.trim() }
                        liveUserPartial = ""
                        if (finalUser.isNotEmpty()) {
                            recordLiveUserFinalTranscript(finalUser)
                        }
                    } else if (role == "assistant") {
                        val finalAssistant = tr.ifEmpty { liveAssistantPartial.trim() }
                        liveAssistantPartial = ""
                        if (finalAssistant.isNotEmpty()) {
                            recordLiveAssistantFinalTranscript(finalAssistant)
                        }
                    }
                }

                "conversation.output_transcript.delta",
                "response.output_text.delta",
                "response.output_audio_transcript.delta",
                "response.audio_transcript.delta" -> {
                    val delta = evt.optString("delta", "")
                    if (delta.isNotEmpty()) {
                        liveAssistantPartial += delta
                        assistantSpeakingUntilMs = maxOf(assistantSpeakingUntilMs, System.currentTimeMillis() + 900L)
                    }
                }

                "response.output_audio_transcript.done",
                "response.audio_transcript.done",
                "conversation.output_transcript.done" -> {
                    val tr = evt.optString("transcript", "").trim().ifEmpty { liveAssistantPartial.trim() }
                    liveAssistantPartial = ""
                    if (tr.isNotEmpty()) {
                        recordLiveAssistantFinalTranscript(tr)
                    }
                }

                "conversation.handoff.requested" -> {
                    val handoffId = evt.optString("handoff_id", "").trim()
                    val itemId = evt.optString("item_id", "").trim()
                    val inputTranscript = evt.optString("input_transcript", "").trim()
                        .ifEmpty { liveUserPartial.trim().ifEmpty { lastUserTranscript } }
                    liveUserPartial = ""
                    if (inputTranscript.isNotEmpty()) {
                        recordLiveUserFinalTranscript(inputTranscript)
                    }
                    if (handoffId.isNotEmpty()) {
                        val activeModel = synchronized(authLock) { auth.codexModel }
                        appendConversationHistory(
                            role = "delegation",
                            badge = "🧠 메인 에이전트 위임 ($activeModel)",
                            text = inputTranscript.ifEmpty { "시선·기억 컨텍스트 확인 요청" }
                        )
                        pushRuntimeEvent("live_handoff_requested") {
                            put("handoffId", handoffId)
                            put("itemId", itemId)
                            put("text", inputTranscript)
                        }
                    }
                }

                "delegation.created" -> {
                    val item = evt.optJSONObject("item") ?: evt.optJSONObject("delegation")
                    val itemType = item?.optString("type", "delegation") ?: "delegation"
                    val target = item?.optString("target", "client") ?: "client"
                    if (itemType == "delegation" && target == "client") {
                        val handoffId = item?.optString("id", "")?.trim() ?: ""
                        var inputTranscript = ""
                        val contentArr = item?.optJSONArray("content")
                        if (contentArr != null) {
                            val sb = StringBuilder()
                            for (i in 0 until contentArr.length()) {
                                val c = contentArr.optJSONObject(i) ?: continue
                                if (c.optString("type") == "input_text") {
                                    sb.append(c.optString("text", ""))
                                }
                            }
                            inputTranscript = sb.toString().trim()
                        }
                        if (inputTranscript.isEmpty()) {
                            inputTranscript = item?.optString("user_input", "")?.trim()
                                ?.ifEmpty { liveUserPartial.trim().ifEmpty { lastUserTranscript } }
                                ?: lastUserTranscript
                        }
                        liveUserPartial = ""
                        if (inputTranscript.isNotEmpty()) {
                            recordLiveUserFinalTranscript(inputTranscript)
                        }
                        if (handoffId.isNotEmpty()) {
                            val activeModel = synchronized(authLock) { auth.codexModel }
                            appendConversationHistory(
                                role = "delegation",
                                badge = "🧠 메인 에이전트 위임 ($activeModel)",
                                text = inputTranscript.ifEmpty { "시선·기억 컨텍스트 확인 요청" }
                            )
                            pushRuntimeEvent("live_handoff_requested") {
                                put("handoffId", handoffId)
                                put("text", inputTranscript)
                            }
                        }
                    }
                }

                "error" -> {
                    val errObj = evt.optJSONObject("error")
                    val msg = errObj?.optString("message", raw) ?: evt.optString("message", raw)
                    lastRealtimeError = msg.take(220)
                    Log.w(TAG, "GPT Live event error: $msg")
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "GPT Live event parse error: ${t.message}")
        }
    }

    private fun recordLiveUserFinalTranscript(tr: String) {
        val clean = tr.trim()
        if (clean.isEmpty()) return
        lastUserTranscript = clean
        if (clean != lastLoggedLiveUserUtterance) {
            lastLoggedLiveUserUtterance = clean
            appendConversationHistory("user_voice", "🎙 내 음성", clean)
            pushRuntimeEvent("user_transcript") {
                put("text", clean)
            }
        }
    }

    private fun recordLiveAssistantFinalTranscript(tr: String) {
        val clean = tr.trim()
        if (clean.isEmpty()) return
        lastAssistantTranscript = clean
        appendConversationHistory("assistant_voice", "✨ 위습 (음성)", clean)
        pushRuntimeEvent("assistant_transcript") {
            put("text", clean)
        }
    }

    private fun splitUtf8Chunks(text: String, maxBytes: Int = CONTEXT_APPEND_MAX_UTF8_BYTES): List<String> {
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size <= maxBytes) return listOf(text)
        val out = ArrayList<String>()
        var start = 0
        while (start < bytes.size) {
            var end = minOf(start + maxBytes, bytes.size)
            while (end > start && end < bytes.size && (bytes[end].toInt() and 0xC0) == 0x80) {
                end -= 1
            }
            if (end <= start) end = minOf(start + maxBytes, bytes.size)
            out.add(String(bytes, start, end - start, StandardCharsets.UTF_8))
            start = end
        }
        return out
    }

    /**
     * Sends Main Agent's completed response back into the active AVAS FramelessBidi Live session
     * via official `delegation.context.append` (`channel = "speakable"`) so GPT Live speaks the answer naturally.
     */
    fun completeLiveHandoff(handoffId: String, answerText: String, backendLabel: String): String {
        val cleanAnswer = answerText.trim().ifEmpty { "확인을 마쳤어." }
        appendConversationHistory(
            role = "agent_result",
            badge = "⚙️ 메인 에이전트 완료 ($backendLabel)",
            text = cleanAnswer
        )
        if (!isRealtimeConnected() || handoffId.isBlank()) {
            return "not_connected"
        }
        val chunks = splitUtf8Chunks("[BACKEND] $cleanAnswer")
        var allOk = true
        for (chunk in chunks) {
            val payload = JSONObject().apply {
                put("type", "delegation.context.append")
                put("delegation_item_id", handoffId)
                put("channel", "speakable")
                put("content", JSONArray().put(JSONObject().apply {
                    put("type", "input_text")
                    put("text", chunk)
                }))
            }.toString()
            if (!sendLiveJson(payload)) allOk = false
        }
        return if (allOk) "ok" else "send_failed"
    }

    fun injectRealtimeSensoryEvent(contextText: String, triggerVoiceResponse: Boolean): String {
        if (!isRealtimeConnected()) return "not_connected"
        val channel = if (triggerVoiceResponse && !isAssistantSpeaking()) "speakable" else "commentary"
        val chunks = splitUtf8Chunks("[USER] [감각 이벤트] $contextText")
        var allOk = true
        for (chunk in chunks) {
            val payload = JSONObject().apply {
                put("type", "session.context.append")
                put("channel", channel)
                put("content", JSONArray().put(JSONObject().apply {
                    put("type", "input_text")
                    put("text", chunk)
                }))
            }.toString()
            if (!sendLiveJson(payload)) allOk = false
        }
        return if (allOk) "ok:$channel" else "send_failed"
    }

    fun speakLineViaRealtime(line: String): Boolean {
        if (!isRealtimeConnected() || line.isBlank()) return false
        val chunks = splitUtf8Chunks("[BACKEND] $line")
        var allOk = true
        for (chunk in chunks) {
            val payload = JSONObject().apply {
                put("type", "session.context.append")
                put("channel", "speakable")
                put("content", JSONArray().put(JSONObject().apply {
                    put("type", "input_text")
                    put("text", chunk)
                }))
            }.toString()
            if (!sendLiveJson(payload)) allOk = false
        }
        return allOk
    }

    // =========================================================================
    // 2. Main Agent Companion Session (/responses SSE via ChatGPT OAuth 0.167.0)
    // =========================================================================

    fun runCompanionTurnAsync(turnId: String, payloadJson: String): String {
        workerPool.execute {
            try {
                val reqObj = JSONObject(payloadJson)
                val instructions = reqObj.optString("instructions", "")
                val inputArr = reqObj.optJSONArray("input") ?: JSONArray()
                val toolsArr = reqObj.optJSONArray("tools") ?: JSONArray()

                val resObj = if (hasOAuth()) {
                    executeCodexOAuthTurn(instructions, inputArr, toolsArr)
                } else {
                    JSONObject().apply {
                        put("ok", false)
                        put("error", "no_oauth_configured")
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

        val modelSlug = snap.codexModel.ifBlank { "gpt-6.1-sol" }
        var hasWebSearchTool = false
        for (i in 0 until toolsArr.length()) {
            val t = toolsArr.optJSONObject(i) ?: continue
            if (t.optString("type") == "web_search") {
                hasWebSearchTool = true
                break
            }
        }
        val includeArr = JSONArray().put("reasoning.encrypted_content").apply {
            if (hasWebSearchTool) put("web_search_call.action.sources")
        }
        val effort = discoveredReasoningEffort[modelSlug] ?: "low"
        val useLite = discoveredResponsesLite[modelSlug] == true

        val bodyJson = JSONObject().apply {
            put("model", modelSlug)
            put("instructions", instructions)
            put("input", inputArr)
            put("tools", toolsArr)
            put("tool_choice", "auto")
            put("parallel_tool_calls", false)
            put("store", false)
            put("stream", true)
            if (effort.isNotBlank()) {
                put("reasoning", JSONObject().put("effort", effort))
            }
            put("include", includeArr)
        }

        val reqBuilder = Request.Builder()
            .url("$CODEX_API_BASE/responses")
            .header("Authorization", "Bearer ${snap.oauthAccessToken}")
            .header("ChatGPT-Account-Id", snap.oauthAccountId)
            .header("Accept", "text/event-stream")
            .header("Content-Type", "application/json")
            .header("originator", "codex_cli_rs")
            .header("User-Agent", "codex_cli_rs/$CODEX_CLIENT_VERSION")
        if (useLite) {
            reqBuilder.header("x-openai-internal-codex-responses-lite", "true")
        }
        val req = reqBuilder
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
                put("backend", modelSlug)
                put("outputItems", outputItems)
                put("assistantText", finalText)
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
                if (!hasOAuth()) return@execute
                val f = File(cropPath)
                val imgBytes = if (f.exists()) f.readBytes() else latestFrameProvider()
                if (imgBytes.size <= 64) return@execute

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
                val vlmRes = executeCodexOAuthTurn(
                    "너는 혼합현실 시선 기억 인덱서야. 사진 속 핵심 사물을 정확하고 간결한 한국어 한 문장으로 기록해.",
                    inputArr,
                    JSONArray()
                )
                if (vlmRes.optBoolean("ok", false)) {
                    val annotation = vlmRes.optString("assistantText", "").trim()
                    val vlmModelUsed = vlmRes.optString("backend", "")
                    if (annotation.isNotBlank()) {
                        visionUpgrades.add(JSONObject().apply {
                            put("memId", memId)
                            put("annotation", annotation)
                            if (vlmModelUsed.isNotBlank()) put("vlmModel", vlmModelUsed)
                        }.toString())
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "Vision annotate upgrade skipped ($memId): ${t.message}")
            }
        }
        return "queued"
    }

    // =========================================================================
    // 3. OAuth PKCE / Device Code, Token Refresh & 0.167.0 Catalog Discovery
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
                    codexModel = obj.optString("codexModel", "gpt-6.1-sol"),
                    modelExplicitlyChosen = obj.optBoolean("modelExplicitlyChosen", false)
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
                put("modelExplicitlyChosen", snap.modelExplicitlyChosen)
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
                .header("User-Agent", "codex_cli_rs/$CODEX_CLIENT_VERSION")
                .header("originator", "codex_cli_rs")
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

    fun refreshCatalogModelSafe() {
        try {
            ensureFreshOAuthToken(force = false)
            val snap = synchronized(authLock) { auth.copy() }
            if (snap.oauthAccessToken.isBlank() || snap.oauthAccountId.isBlank()) return
            val req = Request.Builder()
                .url("$CODEX_API_BASE/models?client_version=$CODEX_CLIENT_VERSION")
                .header("Authorization", "Bearer ${snap.oauthAccessToken}")
                .header("ChatGPT-Account-Id", snap.oauthAccountId)
                .header("originator", "codex_cli_rs")
                .header("User-Agent", "codex_cli_rs/$CODEX_CLIENT_VERSION")
                .get()
                .build()
            httpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return
                val data = JSONObject(resp.body?.string() ?: return)
                val models = data.optJSONArray("models") ?: return
                val items = mutableListOf<CatalogModelInfo>()
                for (i in 0 until models.length()) {
                    val m = models.optJSONObject(i) ?: continue
                    val slug = m.optString("slug", "").trim()
                    if (slug.isBlank()) continue
                    val vis = m.optString("visibility", "list").trim()
                    if (vis != "list") continue
                    if (slug.contains("daybreak", ignoreCase = true) || slug == "codex-auto-review") continue

                    val disp = m.optString("display_name", slug).trim().ifBlank { slug }
                    val prio = m.optInt("priority", 9999)
                    val useLite = m.optBoolean("use_responses_lite", false)
                    val levels = m.optJSONArray("supported_reasoning_levels")
                    val supportedEfforts = mutableListOf<String>()
                    if (levels != null) {
                        for (j in 0 until levels.length()) {
                            val lv = levels.optJSONObject(j)
                            val ef = (lv?.optString("effort", "") ?: levels.optString(j, "")).trim()
                            if (ef.isNotBlank()) supportedEfforts.add(ef)
                        }
                    }
                    val defEff = m.optString("default_reasoning_level", "").trim()
                    val bestEff = when {
                        "low" in supportedEfforts -> "low"
                        defEff.isNotBlank() -> defEff
                        supportedEfforts.isNotEmpty() -> supportedEfforts.first()
                        else -> ""
                    }
                    items.add(CatalogModelInfo(slug, disp, prio, bestEff, useLite))
                }
                items.sortBy { it.priority }
                val slugs = items.map { it.slug }
                if (slugs.isNotEmpty()) {
                    catalogItems = items
                    discoveredCatalogModels = slugs
                    discoveredReasoningEffort = items.associate { it.slug to it.bestEffort }
                    discoveredResponsesLite = items.associate { it.slug to it.useResponsesLite }
                    synchronized(authLock) {
                        val chosen = if (auth.modelExplicitlyChosen && auth.codexModel in slugs) {
                            auth.codexModel
                        } else {
                            slugs.first() // e.g. gpt-6.1-sol (priority 1)
                        }
                        auth.codexModel = chosen
                    }
                    saveAuthToDisk()
                    Log.i(TAG, "Discovered Codex OAuth 0.167.0 catalog: active=${synchronized(authLock){auth.codexModel}}, available=$slugs")
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
            if (access.isBlank() || acc.isBlank()) return false
            synchronized(authLock) {
                auth.oauthAccessToken = access
                auth.oauthRefreshToken = refresh
                auth.oauthIdToken = idTok
                auth.oauthAccountId = acc
            }
            saveAuthToDisk()
            workerPool.execute { refreshCatalogModelSafe() }
            true
        } catch (_: Throwable) {
            false
        }
    }

    // =========================================================================
    // 4. Loopback HTTP Server (localhost:1455) — Voice Toggle, Live Transcript & History
    // =========================================================================

    private fun startLoopbackServer() {
        if (!serverRunning.compareAndSet(false, true)) return
        serverThread = Thread({
            try {
                val srv = ServerSocket(LOOPBACK_PORT, 16)
                serverSocket = srv
                serverListening = true
                Log.i(TAG, "Loopback Setup & OAuth server listening on $SETUP_URL")
                while (serverRunning.get()) {
                    val client = try { srv.accept() } catch (_: Throwable) { break }
                    if (client.inetAddress?.isLoopbackAddress != true) {
                        try { client.close() } catch (_: Throwable) {}
                        continue
                    }
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

    private fun readHttpHeaderLine(inp: InputStream): String? {
        val sb = ByteArrayOutputStream(128)
        while (sb.size() < 8192) {
            val b = inp.read()
            if (b < 0) {
                return if (sb.size() == 0) null else sb.toString("UTF-8")
            }
            if (b == '\n'.code) {
                val arr = sb.toByteArray()
                val len = if (arr.isNotEmpty() && arr[arr.size - 1] == '\r'.code.toByte()) arr.size - 1 else arr.size
                return String(arr, 0, len, Charsets.UTF_8)
            }
            sb.write(b)
        }
        return sb.toString("UTF-8")
    }

    private fun handleHttpClient(socket: Socket) {
        try {
            socket.use { sock ->
                sock.soTimeout = 10000
                val inp = sock.getInputStream()
                val reqLine = readHttpHeaderLine(inp) ?: return
                val parts = reqLine.split(" ")
                if (parts.size < 2) return
                val method = parts[0].uppercase()
                val fullTarget = parts[1]
                val qIdx = fullTarget.indexOf('?')
                val path = if (qIdx >= 0) fullTarget.substring(0, qIdx) else fullTarget
                val queryStr = if (qIdx >= 0) fullTarget.substring(qIdx + 1) else ""

                var contentLen = 0
                while (true) {
                    val h = readHttpHeaderLine(inp) ?: break
                    if (h.isEmpty()) break
                    if (h.startsWith("Content-Length:", ignoreCase = true)) {
                        contentLen = h.substringAfter(":").trim().toIntOrNull() ?: 0
                    }
                }

                val bodyStr = if (contentLen in 1..262144) {
                    val buf = ByteArray(contentLen)
                    var readTotal = 0
                    while (readTotal < contentLen) {
                        val r = inp.read(buf, readTotal, contentLen - readTotal)
                        if (r <= 0) break
                        readTotal += r
                    }
                    String(buf, 0, readTotal, Charsets.UTF_8)
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
                    (method == "GET" || method == "POST") && path == "/auth/device" -> {
                        val ok = startDeviceCodeFlow()
                        writeRedirect(sock, if (ok) "/setup?msg=device_started" else "/setup?msg=device_err")
                    }
                    method == "POST" && path == "/auth/device/cancel" -> {
                        deviceAuthEpoch.incrementAndGet()
                        deviceAuthState = "idle"
                        deviceUserCode = ""
                        deviceAuthError = ""
                        writeRedirect(sock, "/setup")
                    }
                    method == "GET" && path == "/auth/callback" -> {
                        val params = parseFormEncoded(queryStr)
                        val code = params["code"] ?: ""
                        val state = params["state"] ?: ""
                        if (code.isBlank() || (pkceState.isNotBlank() && state != pkceState)) {
                            writeRedirect(sock, "/setup?msg=oauth_state_err")
                            return
                        }
                        val ok = exchangePkceCode(code, pkceVerifier, REDIRECT_URI)
                        if (ok) {
                            deviceAuthEpoch.incrementAndGet()
                            deviceAuthState = "completed"
                            deviceUserCode = ""
                            workerPool.execute { refreshCatalogModelSafe() }
                            pushRuntimeEvent("auth_updated") { put("source", "oauth_pkce") }
                            writeRedirect(sock, "/setup?msg=oauth_ok")
                        } else {
                            writeRedirect(sock, "/setup?msg=oauth_exchange_err")
                        }
                    }
                    method == "POST" && path == "/api/voice_toggle" -> {
                        val enabled = toggleVoiceLive()
                        val res = JSONObject().apply {
                            put("ok", true)
                            put("voiceLiveEnabled", enabled)
                            put("realtimeState", realtimeState)
                        }.toString()
                        writeHttpResponse(sock, "200 OK", "application/json; charset=utf-8", res.toByteArray(Charsets.UTF_8))
                    }
                    method == "POST" && path == "/setup/voice_toggle" -> {
                        toggleVoiceLive()
                        writeRedirect(sock, "/setup")
                    }
                    method == "POST" && path == "/setup/refresh_models" -> {
                        refreshCatalogModelSafe()
                        writeRedirect(sock, "/setup?msg=models_refreshed")
                    }
                    method == "POST" && path == "/setup/save" -> {
                        val form = parseFormEncoded(bodyStr)
                        val authJsonRaw = (form["auth_json"] ?: "").trim()
                        val selectedModel = (form["codex_model"] ?: "").trim()

                        if (authJsonRaw.isNotEmpty()) {
                            importAuthJsonString(authJsonRaw)
                        }
                        synchronized(authLock) {
                            if (selectedModel.isNotEmpty()) {
                                auth.codexModel = selectedModel
                                auth.modelExplicitlyChosen = true
                            }
                        }
                        saveAuthToDisk()
                        pushRuntimeEvent("auth_updated") { put("source", "setup_form") }
                        writeRedirect(sock, "/setup?msg=saved")
                    }
                    method == "POST" && path == "/setup/say" -> {
                        val form = parseFormEncoded(bodyStr)
                        val prompt = (form["prompt"] ?: "").trim()
                        if (prompt.isNotEmpty()) {
                            lastUserTranscript = prompt
                            appendConversationHistory("user_text", "⌨️ 텍스트 입력", prompt)
                            pushRuntimeEvent("web_prompt") { put("text", prompt) }
                        }
                        writeRedirect(sock, "/setup?msg=sent")
                    }
                    method == "POST" && path == "/api/say" -> {
                        val form = parseFormEncoded(bodyStr)
                        val prompt = (form["prompt"] ?: "").trim()
                        if (prompt.isNotEmpty()) {
                            lastUserTranscript = prompt
                            appendConversationHistory("user_text", "⌨️ 텍스트 입력", prompt)
                            pushRuntimeEvent("web_prompt") { put("text", prompt) }
                        }
                        writeHttpResponse(sock, "200 OK", "application/json; charset=utf-8", """{"ok":true}""".toByteArray(Charsets.UTF_8))
                    }
                    method == "POST" && path == "/setup/reset" -> {
                        clearConversationHistory()
                        pushRuntimeEvent("web_reset") {}
                        writeRedirect(sock, "/setup?msg=reset_ok")
                    }
                    method == "POST" && path == "/setup/logout" -> {
                        deviceAuthEpoch.incrementAndGet()
                        deviceAuthState = "idle"
                        deviceUserCode = ""
                        deviceAuthError = ""
                        setVoiceLiveActive(false)
                        synchronized(authLock) { auth = StoredAuth() }
                        saveAuthToDisk()
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
        } catch (_: java.net.SocketTimeoutException) {
            // Browser idle preconnect socket timeout; ignore quietly.
        } catch (t: Throwable) {
            Log.d(TAG, "Loopback HTTP socket closed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun startDeviceCodeFlow(): Boolean {
        return try {
            val reqJson = JSONObject().put("client_id", CLIENT_ID).toString()
            val req = Request.Builder()
                .url(DEVICE_USERCODE_URL)
                .header("Content-Type", "application/json")
                .header("User-Agent", "codex_cli_rs/$CODEX_CLIENT_VERSION")
                .header("originator", "codex_cli_rs")
                .post(reqJson.toRequestBody("application/json".toMediaType()))
                .build()

            httpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    deviceAuthState = "error"
                    deviceUserCode = ""
                    deviceAuthError = if (resp.code == 404) "not_enabled_404" else "http_${resp.code}"
                    return false
                }
                val data = JSONObject(resp.body?.string() ?: return false)
                val devAuthId = data.optString("device_auth_id", "").trim()
                val uCode = data.optString("user_code", data.optString("usercode", "")).trim()
                val intervalSec = data.optString("interval", "5").trim().toLongOrNull()?.coerceIn(3L, 30L) ?: 5L
                if (devAuthId.isBlank() || uCode.isBlank()) {
                    deviceAuthState = "error"
                    deviceAuthError = "empty_user_code"
                    return false
                }

                val myEpoch = deviceAuthEpoch.incrementAndGet()
                deviceAuthState = "waiting"
                deviceUserCode = uCode
                deviceVerificationUrl = DEVICE_VERIFY_URL
                deviceAuthError = ""
                pushRuntimeEvent("device_code_ready") {
                    put("code", uCode)
                    put("url", DEVICE_VERIFY_URL)
                }

                workerPool.execute {
                    val startMs = System.currentTimeMillis()
                    val maxWaitMs = 15L * 60L * 1000L
                    while (serverRunning.get() && deviceAuthEpoch.get() == myEpoch && (System.currentTimeMillis() - startMs) < maxWaitMs) {
                        try {
                            Thread.sleep(intervalSec * 1000L)
                        } catch (_: InterruptedException) {
                            break
                        }
                        if (!serverRunning.get() || deviceAuthEpoch.get() != myEpoch) break

                        val pollBody = JSONObject()
                            .put("device_auth_id", devAuthId)
                            .put("user_code", uCode)
                            .toString()
                        val pollReq = Request.Builder()
                            .url(DEVICE_TOKEN_URL)
                            .header("Content-Type", "application/json")
                            .header("User-Agent", "codex_cli_rs/$CODEX_CLIENT_VERSION")
                            .header("originator", "codex_cli_rs")
                            .post(pollBody.toRequestBody("application/json".toMediaType()))
                            .build()

                        try {
                            httpClient.newCall(pollReq).execute().use { pResp ->
                                val code = pResp.code
                                if (code == 403 || code == 404) {
                                    // Pending user approval
                                } else if (pResp.isSuccessful) {
                                    val pData = JSONObject(pResp.body?.string() ?: "{}")
                                    val authCode = pData.optString("authorization_code", "").trim()
                                    val codeVerifier = pData.optString("code_verifier", "").trim()
                                    if (authCode.isNotBlank() && codeVerifier.isNotBlank()) {
                                        val exchanged = exchangePkceCode(authCode, codeVerifier, DEVICE_CALLBACK_URI)
                                        if (exchanged && deviceAuthEpoch.get() == myEpoch) {
                                            deviceAuthState = "completed"
                                            deviceUserCode = ""
                                            deviceAuthError = ""
                                            workerPool.execute { refreshCatalogModelSafe() }
                                            pushRuntimeEvent("auth_updated") { put("source", "device_code") }
                                            return@execute
                                        }
                                    }
                                    if (deviceAuthEpoch.get() == myEpoch) {
                                        deviceAuthState = "error"
                                        deviceAuthError = "token_exchange_failed"
                                    }
                                    return@execute
                                } else {
                                    if (deviceAuthEpoch.get() == myEpoch) {
                                        deviceAuthState = "error"
                                        deviceAuthError = "poll_http_$code"
                                    }
                                    return@execute
                                }
                            }
                        } catch (t: Throwable) {
                            Log.w(TAG, "Device code poll transient error: ${t.message}")
                        }
                    }
                    if (deviceAuthEpoch.get() == myEpoch && deviceAuthState == "waiting") {
                        deviceAuthState = "error"
                        deviceAuthError = "timeout"
                    }
                }
                true
            }
        } catch (t: Throwable) {
            Log.e(TAG, "startDeviceCodeFlow failed", t)
            deviceAuthState = "error"
            deviceAuthError = t.javaClass.simpleName
            false
        }
    }

    private fun exchangePkceCode(code: String, verifier: String, redirectUri: String = REDIRECT_URI): Boolean {
        return try {
            val form = "grant_type=authorization_code" +
                "&client_id=${URLEncoder.encode(CLIENT_ID, "UTF-8")}" +
                "&code=${URLEncoder.encode(code, "UTF-8")}" +
                "&redirect_uri=${URLEncoder.encode(redirectUri, "UTF-8")}" +
                "&code_verifier=${URLEncoder.encode(verifier, "UTF-8")}"
            val req = Request.Builder()
                .url(TOKEN_URL)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .header("User-Agent", "codex_cli_rs/$CODEX_CLIENT_VERSION")
                .header("originator", "codex_cli_rs")
                .post(form.toRequestBody("application/x-www-form-urlencoded".toMediaType()))
                .build()
            httpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return false
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

    private fun escapeHtml(s: String): String {
        return s
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
    }

    private fun renderSetupHtml(msgCode: String): String {
        val snap = synchronized(authLock) { auth.copy() }
        val isAuthed = snap.oauthAccessToken.isNotBlank() && snap.oauthAccountId.isNotBlank()
        val oauthBadge = if (isAuthed)
            "✅ ChatGPT 구독 연결됨 (${maskMiddle(snap.oauthAccountId)} · 메인 에이전트: ${escapeHtml(snap.codexModel)})"
        else
            "⚪ 미로그인 (아래에서 기기 코드 또는 브라우저 로그인 진행)"

        val itemsForSelect = if (catalogItems.isNotEmpty()) {
            catalogItems
        } else {
            listOf(
                CatalogModelInfo("gpt-6.1-sol", "GPT-6.1-Sol", 1, "low", false),
                CatalogModelInfo("gpt-6.1-terra", "GPT-6.1 Terra", 7, "low", false),
                CatalogModelInfo("gpt-6-astra", "gpt-6-astra", 2, "low", false),
                CatalogModelInfo("gpt-6-sol", "gpt-6-sol", 3, "low", false),
                CatalogModelInfo("gpt-5.6-sol", "gpt-5.6-sol", 5, "low", false)
            )
        }
        val hasSavedInList = itemsForSelect.any { it.slug == snap.codexModel }
        val fullModelList = if (hasSavedInList || snap.codexModel.isBlank()) {
            itemsForSelect
        } else {
            listOf(CatalogModelInfo(snap.codexModel, snap.codexModel, 0, "low", false)) + itemsForSelect
        }
        val modelOptionsHtml = fullModelList.joinToString("") { item ->
            val sel = if (item.slug == snap.codexModel) " selected" else ""
            val label = if (item.displayName.equals(item.slug, ignoreCase = true)) {
                item.slug
            } else {
                "${item.displayName} (${item.slug})"
            }
            "<option value=\"${escapeHtml(item.slug)}\"$sel>${escapeHtml(label)}</option>"
        }

        val banner = when (msgCode) {
            "oauth_ok" -> "<div class='ok'>ChatGPT 구독 로그인이 완료됐어! 이제 API 키 없이 음성(GPT Live)과 6.1 메인 에이전트가 바로 동작해.</div>"
            "device_started" -> "<div class='ok'>일회용 기기 코드가 발급됐어! 맥북·PC 브라우저에서 아래 코드를 입력해 줘.</div>"
            "device_err" -> "<div class='warn'>기기 코드 발급에 실패했어 (${escapeHtml(deviceAuthError)}).</div>"
            "models_refreshed" -> "<div class='ok'>구독 계정의 최신 모델 카탈로그를 새로고침했어!</div>"
            "saved" -> "<div class='ok'>메인 에이전트 모델 설정이 저장됐어!</div>"
            "sent" -> "<div class='ok'>위습에게 메시지를 보냈어!</div>"
            "reset_ok" -> "<div class='ok'>시선 기억과 대화 히스토리를 초기화했어!</div>"
            "cleared" -> "<div class='warn'>저장된 로그인 정보를 초기화했어.</div>"
            "oauth_exchange_err", "oauth_state_err" -> "<div class='warn'>OAuth 토큰 교환에 실패했어. 다시 시도하거나 기기 코드 로그인을 사용해 줘.</div>"
            else -> ""
        }

        val deviceBoxHtml = when {
            deviceAuthState == "waiting" && deviceUserCode.isNotBlank() -> """
                <div style="margin-top:14px;padding:16px;background:#091829;border:1.5px solid #38bdf8;border-radius:14px">
                  <div style="font-size:13px;color:#93c5fd;margin-bottom:6px">1단계 · 맥북 또는 PC 브라우저에서 아래 주소 열기</div>
                  <div style="font-size:17px;font-weight:700;margin-bottom:12px">
                    <a href="$deviceVerificationUrl" target="_blank" style="color:#7ee8fa;text-decoration:underline">$deviceVerificationUrl</a>
                  </div>
                  <div style="font-size:13px;color:#93c5fd;margin-bottom:6px">2단계 · 아래 일회용 코드 입력 (승인 즉시 자동 연결됨)</div>
                  <div style="font-family:monospace;font-size:30px;font-weight:800;letter-spacing:4px;color:#a7f3d0;background:#06101c;padding:12px 16px;border-radius:10px;display:inline-block;margin-bottom:10px">${escapeHtml(deviceUserCode)}</div>
                  <div style="font-size:13px;color:#cbd5e1">⏳ 승인 대기 중... (자동 감지 중)</div>
                  <form method="POST" action="/auth/device/cancel" style="margin-top:10px">
                    <button class="btn-sec" type="submit">코드 취소</button>
                  </form>
                </div>
            """.trimIndent()
            deviceAuthState == "error" && deviceAuthError == "not_enabled_404" -> """
                <div class="warn" style="margin-top:12px">
                  ChatGPT 웹 설정(Settings → Security)에서 <b>Enable device code sign-in for Codex</b> 옵션을 켠 뒤 다시 눌러 줘!
                </div>
            """.trimIndent()
            deviceAuthState == "error" && deviceAuthError.isNotBlank() -> """
                <div class="warn" style="margin-top:12px">기기 코드 인증 오류: ${escapeHtml(deviceAuthError)}</div>
            """.trimIndent()
            else -> ""
        }

        val liveOnInit = voiceLiveEnabled.get()

        return """
            <!doctype html>
            <html lang="ko">
            <head>
              <meta charset="utf-8"/>
              <meta name="viewport" content="width=device-width,initial-scale=1"/>
              <title>Wisp · 음성 & 단독 세션 패널</title>
              <style>
                body{margin:0;padding:20px;font-family:-apple-system,BlinkMacSystemFont,"Noto Sans KR",sans-serif;background:#090e1a;color:#eaf2ff;line-height:1.5}
                .wrap{max-width:720px;margin:0 auto}
                .card{background:#111a2d;border:1px solid #223454;border-radius:16px;padding:18px 20px;margin-bottom:16px}
                h1{font-size:21px;margin:0 0 4px;color:#7ee8fa}
                h2{font-size:16px;margin:0 0 10px;color:#bcd9ff}
                .sub{font-size:13px;color:#95accb;margin-bottom:12px}
                .stat{font-size:13.5px;margin:6px 0;padding:8px 12px;background:#0b1220;border-radius:10px;border:1px solid #1b2944}
                .btn{display:inline-flex;align-items:center;gap:8px;background:linear-gradient(135deg,#2dd4bf,#38bdf8);color:#06121e;font-weight:700;padding:11px 17px;border-radius:12px;text-decoration:none;border:none;font-size:14.5px;cursor:pointer;margin-right:8px;margin-bottom:8px}
                .btn-sec{display:inline-flex;align-items:center;gap:6px;background:#1e2d47;color:#dbeafe;font-weight:600;padding:10px 14px;border-radius:10px;border:1px solid #334b73;text-decoration:none;cursor:pointer;margin-right:8px;margin-bottom:8px;font-size:13.5px}
                .voice-bar{display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap;padding:14px 16px;border-radius:14px;margin-top:10px;transition:all .18s ease}
                .voice-bar.on{background:#09261b;border:2px solid #22c55e}
                .voice-bar.off{background:#281016;border:2px solid #ef4444}
                .voice-btn{display:inline-flex;align-items:center;gap:10px;font-size:16px;font-weight:800;padding:12px 20px;border-radius:12px;cursor:pointer;border:none;transition:transform .1s ease}
                .voice-btn:active{transform:scale(0.97)}
                .voice-btn.on{background:#16a34a;color:#ffffff;box-shadow:0 0 18px rgba(34,197,94,0.45)}
                .voice-btn.off{background:#dc2626;color:#ffffff;box-shadow:0 0 16px rgba(239,68,68,0.35)}
                .live-box{background:#09111f;border:1px solid #24385c;border-radius:12px;padding:12px 14px;margin-bottom:12px}
                .live-label{font-size:12px;font-weight:700;color:#7dd3fc;margin-bottom:4px;display:flex;align-items:center;justify-content:space-between}
                .live-text{font-size:15px;color:#f0f9ff;min-height:24px;word-break:break-word}
                .meter-bg{width:96px;height:7px;background:#17233b;border-radius:99px;overflow:hidden}
                .meter-fill{height:100%;width:0%;background:#22c55e;transition:width .12s linear}
                .hist-list{max-height:340px;overflow-y:auto;background:#080f1c;border:1px solid #1e3050;border-radius:12px;padding:10px 12px}
                .hist-empty{color:#64748b;font-size:13.5px;text-align:center;padding:24px 8px}
                .hist-item{padding:9px 11px;border-radius:10px;margin-bottom:8px;font-size:14px;word-break:break-word}
                .hist-item:last-child{margin-bottom:0}
                .hist-user{background:#11243e;border-left:3px solid #38bdf8}
                .hist-del{background:#1d1836;border-left:3px solid #a78bfa;font-size:13px;color:#ddd6fe}
                .hist-agent{background:#0e2923;border-left:3px solid #34d399}
                .hist-assistant{background:#132a24;border-left:3px solid #22c55e}
                .hist-meta{font-size:11.5px;color:#94a3b8;margin-bottom:3px;font-weight:600}
                input[type=text],select,textarea{width:100%;box-sizing:border-box;background:#0b1220;color:#eaf2ff;border:1px solid #2b3f63;border-radius:10px;padding:10px 12px;font-size:14px;margin-top:6px;margin-bottom:12px}
                textarea{min-height:76px;font-family:monospace;font-size:12px}
                .ok{background:#0f352c;border:1px solid #2dd4bf;color:#a7f3d0;padding:10px 14px;border-radius:12px;margin-bottom:14px;font-size:14px}
                .warn{background:#3b1d2a;border:1px solid #f472b6;color:#fbcfe8;padding:10px 14px;border-radius:12px;margin-bottom:14px;font-size:14px}
                label{font-size:13px;color:#bfd4f2;font-weight:600}
                details summary{cursor:pointer;font-size:13.5px;color:#93c5fd;font-weight:600;padding:4px 0}
              </style>
            </head>
            <body>
              <div class="wrap">
                <div class="card">
                  <h1>Wisp (위습) · 음성 & 단독 세션</h1>
                  <div class="sub">ChatGPT 구독 OAuth 단일 세션으로 동작해. GPT Live가 자연스러운 실시간 음성 대화를 맡고, 시선·기억·추천·검색 작업은 메인 에이전트에 위임해 처리해.</div>
                  $banner
                  <div class="stat">$oauthBadge</div>
                  <div class="stat" id="audioRouteStat">🎧 오디오 입출력: ${escapeHtml(activeAudioRouteLabel)}</div>

                  <div id="voiceBar" class="voice-bar ${if (liveOnInit) "on" else "off"}">
                    <div>
                      <div id="voiceTitle" style="font-size:15px;font-weight:800;color:${if (liveOnInit) "#86efac" else "#fca5a5"}">
                        ${if (liveOnInit) "음성 켜짐 (GPT Live 활성)" else "음성 꺼짐 (마이크 음소거됨)"}
                      </div>
                      <div id="voiceSub" style="font-size:12.5px;color:#cbd5e1;margin-top:2px">
                        오른쪽 [음성] 버튼이나 MR 공간의 [음성] 룬을 눌러 바로 켜고 끌 수 있어.
                      </div>
                    </div>
                    <form id="voiceToggleForm" method="POST" action="/setup/voice_toggle" style="margin:0">
                      <button id="voiceToggleBtn" type="submit" class="voice-btn ${if (liveOnInit) "on" else "off"}">
                        <span id="voiceIconWrap" style="display:inline-flex;align-items:center"></span>
                        <span id="voiceBtnLabel">음성 ${if (liveOnInit) "켜짐" else "꺼짐"}</span>
                      </button>
                    </form>
                  </div>
                </div>

                <div class="card">
                  <h2>실시간 내 음성 전사 & 대화 히스토리</h2>
                  <div class="live-box">
                    <div class="live-label">
                      <span>🎙 내 음성 실시간 전사</span>
                      <div class="meter-bg" title="마이크 입력 레벨"><div id="micMeter" class="meter-fill"></div></div>
                    </div>
                    <div id="liveUserText" class="live-text" style="color:#bae6fd">음성을 켜고 말하면 여기에 실시간으로 전사돼...</div>
                    <div id="liveAssistantWrap" style="display:none;margin-top:8px;padding-top:8px;border-top:1px dashed #233858">
                      <div style="font-size:12px;color:#86efac;font-weight:700">✨ 위습 발화 중</div>
                      <div id="liveAssistantText" class="live-text" style="color:#dcfce7;font-size:14px"></div>
                    </div>
                  </div>

                  <div id="historyBox" class="hist-list">
                    <div class="hist-empty">아직 대화 기록이 없어. 음성을 켜고 말 걸거나 아래 입력창으로 메시지를 보내 봐!</div>
                  </div>

                  <form id="sayForm" method="POST" action="/setup/say" style="margin-top:12px;display:flex;gap:8px;align-items:center">
                    <input id="promptInput" type="text" name="prompt" style="margin:0;flex:1" placeholder="텍스트로 위습(메인 에이전트)에게 바로 물어보기..." />
                    <button class="btn" type="submit" style="margin:0;white-space:nowrap">보내기</button>
                  </form>
                </div>

                <div class="card">
                  <h2>메인 에이전트 모델 선택 (Codex 0.167.0 카탈로그)</h2>
                  <form method="POST" action="/setup/save">
                    <label>시선 기억 · 카메라 비전 · 웹 검색 · 추천 카드를 담당할 메인 에이전트 모델</label>
                    <select name="codex_model">$modelOptionsHtml</select>
                    <div style="display:flex;gap:8px;flex-wrap:wrap">
                      <button class="btn" type="submit">모델 저장</button>
                    </div>
                  </form>
                  <form method="POST" action="/setup/refresh_models" style="margin-top:4px">
                    <button class="btn-sec" type="submit">🔄 카탈로그 새로고침</button>
                  </form>
                </div>

                <div class="card">
                  <h2>ChatGPT 구독 계정 연결 관리</h2>
                  ${if (isAuthed) """
                    <details>
                      <summary>이미 구독 계정이 연결되어 있어 (다른 계정으로 다시 로그인하거나 초기화하려면 펼치기)</summary>
                      <div style="margin-top:12px">
                        <a class="btn" href="/auth/device">🔑 기기 코드로 다시 로그인</a>
                        <a class="btn-sec" href="/auth/start">🌐 브라우저 OAuth 로그인</a>
                        $deviceBoxHtml
                        <form method="POST" action="/setup/save" style="margin-top:10px">
                          <label>또는 Codex auth.json 직접 붙여넣기</label>
                          <textarea name="auth_json" placeholder='{"tokens":{"access_token":"...","refresh_token":"...","account_id":"..."}}'></textarea>
                          <button class="btn-sec" type="submit">auth.json 가져오기</button>
                        </form>
                        <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:8px">
                          <form method="POST" action="/setup/reset"><button class="btn-sec" type="submit">기억·대화 히스토리 리셋</button></form>
                          <form method="POST" action="/setup/logout"><button class="btn-sec" type="submit">로그인 정보 초기화</button></form>
                        </div>
                      </div>
                    </details>
                  """ else """
                    <div class="sub">보안키(YubiKey 등)를 쓰는 계정은 <b>기기 코드로 로그인</b>을 누른 뒤 맥북·PC에서 코드만 입력하면 퀘스트에 바로 저장돼!</div>
                    <div>
                      <a class="btn" href="/auth/device">🔑 기기 코드로 로그인 (보안키 지원)</a>
                      <a class="btn-sec" href="/auth/start">🌐 이 브라우저에서 바로 OAuth 로그인</a>
                    </div>
                    $deviceBoxHtml
                    <form method="POST" action="/setup/save" style="margin-top:12px">
                      <label>또는 Codex auth.json 직접 붙여넣기</label>
                      <textarea name="auth_json" placeholder='{"tokens":{"access_token":"...","refresh_token":"...","account_id":"..."}}'></textarea>
                      <button class="btn-sec" type="submit">auth.json 가져오기</button>
                    </form>
                  """}
                </div>
              </div>

              <script>
                (function(){
                  var SVG_MIC_ON = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#86efac" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="2" width="6" height="12" rx="3" fill="#22c55e" stroke="#ffffff"/><path d="M5 10v1a7 7 0 0 0 14 0v-1" stroke="#ffffff"/><line x1="12" y1="18" x2="12" y2="22" stroke="#ffffff"/><line x1="8" y1="22" x2="16" y2="22" stroke="#ffffff"/></svg>';
                  var SVG_MIC_OFF = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="2" width="6" height="12" rx="3" fill="#ef4444" stroke="#fecaca"/><path d="M5 10v1a7 7 0 0 0 14 0v-1" stroke="#fecaca"/><line x1="12" y1="18" x2="12" y2="22" stroke="#fecaca"/><line x1="8" y1="22" x2="16" y2="22" stroke="#fecaca"/><line x1="3" y1="3" x2="21" y2="21" stroke="#ffffff" stroke-width="3.2"/><line x1="3" y1="3" x2="21" y2="21" stroke="#ff1f3d" stroke-width="2.0"/></svg>';

                  var voiceBar = document.getElementById('voiceBar');
                  var audioRouteStat = document.getElementById('audioRouteStat');
                  var voiceTitle = document.getElementById('voiceTitle');
                  var voiceSub = document.getElementById('voiceSub');
                  var voiceBtn = document.getElementById('voiceToggleBtn');
                  var voiceIconWrap = document.getElementById('voiceIconWrap');
                  var voiceBtnLabel = document.getElementById('voiceBtnLabel');
                  var voiceForm = document.getElementById('voiceToggleForm');
                  var liveUserText = document.getElementById('liveUserText');
                  var liveAssistantWrap = document.getElementById('liveAssistantWrap');
                  var liveAssistantText = document.getElementById('liveAssistantText');
                  var micMeter = document.getElementById('micMeter');
                  var historyBox = document.getElementById('historyBox');
                  var sayForm = document.getElementById('sayForm');
                  var promptInput = document.getElementById('promptInput');

                  var lastHistSig = '';
                  var waitingDevice = ${if (deviceAuthState == "waiting") "true" else "false"};

                  function esc(s) {
                    return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
                  }

                  function renderVoiceUi(st) {
                    var on = !!st.voiceLiveEnabled;
                    var rState = st.realtimeState || 'off';
                    if (audioRouteStat && st.audioRoute) {
                      audioRouteStat.textContent = '🎧 오디오 입출력: ' + st.audioRoute;
                    }
                    voiceBar.className = 'voice-bar ' + (on ? 'on' : 'off');
                    voiceBtn.className = 'voice-btn ' + (on ? 'on' : 'off');
                    voiceIconWrap.innerHTML = on ? SVG_MIC_ON : SVG_MIC_OFF;
                    voiceBtnLabel.textContent = on ? '음성 켜짐' : '음성 꺼짐';

                    if (on) {
                      voiceTitle.style.color = '#86efac';
                      if (rState === 'connected') {
                        voiceTitle.textContent = '🟢 음성 켜짐 · GPT Live 실시간 연결됨';
                        voiceSub.textContent = '자유롭게 말하면 위습이 바로 듣고, 시선·기억·추천은 메인 에이전트(' + (st.codexModel || 'gpt-6.1-sol') + ')와 함께 처리해.';
                      } else if (rState === 'connecting') {
                        voiceTitle.textContent = '🟢 음성 켜짐 · GPT Live WebRTC 연결 중...';
                        voiceSub.textContent = '오디오 세션을 준비하고 있어...';
                      } else {
                        voiceTitle.textContent = '🟢 음성 켜짐 (' + rState + ')';
                        voiceSub.textContent = st.realtimeError ? ('오류: ' + st.realtimeError) : '상태 동기화 중...';
                      }
                    } else {
                      voiceTitle.style.color = '#fca5a5';
                      voiceTitle.textContent = '🔴 음성 꺼짐 · 마이크 음소거 상태';
                      voiceSub.textContent = st.realtimeError ? ('최근 알림: ' + st.realtimeError) : '[음성 꺼짐] 버튼을 누르면 초록 마이크가 켜지며 GPT Live 대화가 시작돼.';
                    }

                    var rmsPct = Math.min(100, Math.round((st.liveMicRms || 0) * 420));
                    micMeter.style.width = (on ? rmsPct : 0) + '%';

                    if (st.liveUserPartial && st.liveUserPartial.trim()) {
                      liveUserText.style.color = '#7ee8fa';
                      liveUserText.textContent = st.liveUserPartial + ' ▍';
                    } else if (st.lastUserTranscript && st.lastUserTranscript.trim()) {
                      liveUserText.style.color = '#cbd5e1';
                      liveUserText.textContent = '최근 인식: "' + st.lastUserTranscript + '"';
                    } else {
                      liveUserText.style.color = '#64748b';
                      liveUserText.textContent = on ? '듣고 있어... 편하게 말을 걸어 봐!' : '음성을 켜면 내 목소리가 실시간으로 여기에 전사돼.';
                    }

                    if (st.liveAssistantPartial && st.liveAssistantPartial.trim()) {
                      liveAssistantWrap.style.display = 'block';
                      liveAssistantText.textContent = st.liveAssistantPartial + ' ▍';
                    } else {
                      liveAssistantWrap.style.display = 'none';
                    }

                    var hist = st.history || [];
                    var sig = hist.length ? (hist.length + ':' + hist[hist.length - 1].id) : '0';
                    if (sig !== lastHistSig) {
                      var nearBottom = (historyBox.scrollHeight - historyBox.scrollTop - historyBox.clientHeight) < 60;
                      lastHistSig = sig;
                      if (!hist.length) {
                        historyBox.innerHTML = '<div class="hist-empty">아직 대화 기록이 없어. 음성을 켜고 말 걸거나 아래 입력창으로 메시지를 보내 봐!</div>';
                      } else {
                        var html = '';
                        for (var i = 0; i < hist.length; i++) {
                          var h = hist[i];
                          var cls = 'hist-assistant';
                          if (h.role === 'user_voice' || h.role === 'user_text') cls = 'hist-user';
                          else if (h.role === 'delegation') cls = 'hist-del';
                          else if (h.role === 'agent_result') cls = 'hist-agent';
                          html += '<div class="hist-item ' + cls + '">'
                            + '<div class="hist-meta">' + esc(h.badge) + ' · ' + esc(h.time) + '</div>'
                            + '<div>' + esc(h.text) + '</div>'
                            + '</div>';
                        }
                        historyBox.innerHTML = html;
                        if (nearBottom) {
                          historyBox.scrollTop = historyBox.scrollHeight;
                        }
                      }
                    }
                  }

                  voiceIconWrap.innerHTML = ${if (liveOnInit) "SVG_MIC_ON" else "SVG_MIC_OFF"};

                  if (voiceForm) {
                    voiceForm.onsubmit = function(ev) {
                      ev.preventDefault();
                      fetch('/api/voice_toggle', {method:'POST'})
                        .then(function(){ return fetch('/api/status', {cache:'no-store'}); })
                        .then(function(r){ return r.json(); })
                        .then(renderVoiceUi)
                        .catch(function(){ voiceForm.submit(); });
                    };
                  }

                  if (sayForm && promptInput) {
                    sayForm.onsubmit = function(ev) {
                      ev.preventDefault();
                      var v = promptInput.value.trim();
                      if (!v) return;
                      promptInput.value = '';
                      fetch('/api/say', {
                        method:'POST',
                        headers:{'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8'},
                        body:'prompt=' + encodeURIComponent(v)
                      }).then(function(){
                        return fetch('/api/status', {cache:'no-store'});
                      }).then(function(r){ return r.json(); }).then(renderVoiceUi);
                    };
                  }

                  function poll() {
                    fetch('/api/status', {cache:'no-store'})
                      .then(function(r){ return r.json(); })
                      .then(function(st){
                        if (waitingDevice && st.oauthReady && st.deviceAuthState === 'completed') {
                          window.location.href = '/setup?msg=oauth_ok';
                          return;
                        }
                        renderVoiceUi(st);
                      })
                      .catch(function(){});
                  }
                  poll();
                  setInterval(poll, 750);
                })();
              </script>
            </body>
            </html>
        """.trimIndent()
    }
}
