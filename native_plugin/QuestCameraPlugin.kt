package com.godot.game

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.Image
import android.media.ImageReader
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.util.Log
import android.util.Size
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

class QuestCameraPlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val TAG = "QuestCameraPlugin"
        private const val REQ_MEDIA_PERMS = 4201
        private const val PERM_HEADSET_CAMERA = "horizonos.permission.HEADSET_CAMERA"
        private const val SAMPLE_RATE_HZ = 24000
        private const val VISION_W = 320
        private const val VISION_H = 240
        private const val VISION_INTERVAL_MS = 125L
        private const val CENTER_ROI_RADIUS = 0.22f
        private const val INTEREST_THRESHOLD = 65.0f
    }

    private data class RawDetection(
        val label: String,
        val score: Float,
        val xmin: Float,
        val ymin: Float,
        val xmax: Float,
        val ymax: Float
    )

    private class TrackState(
        val id: Int,
        var label: String,
        var detScore: Float,
        var xmin: Float,
        var ymin: Float,
        var xmax: Float,
        var ymax: Float,
        val firstSeenMs: Long
    ) {
        var lastSeenMs: Long = firstSeenMs
        var firstEnterRoiMs: Long = -1L
        var timeToCenterSec: Float = -1f
        var centerDwellSec: Float = 0f
        var continuousDwellSec: Float = 0f
        var minCenterDist: Float = 1.0f
        var centerDist: Float = 1.0f
        var inCenterRoi: Boolean = false
        var wasInCenterRoi: Boolean = false
        var reentryCount: Int = 0
        var interestScore: Float = 0f
        var promoted: Boolean = false
        var colorToneKo: String = "중성 톤"
        var brightnessKo: String = "자연광"
        var rgbSig24: FloatArray = FloatArray(24)
        var bestCropCenterDist: Float = 9f
        var bestCropBytes: ByteArray? = null
    }

    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null
    private var visionThread: HandlerThread? = null
    private var visionHandler: Handler? = null

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null

    private var objectDetector: ObjectDetector? = null
    private var handLandmarker: HandLandmarker? = null
    @Volatile private var mpObjectReady: Boolean = false
    @Volatile private var mpHandReady: Boolean = false
    private val visionBusy = AtomicBoolean(false)
    @Volatile private var lastVisionDispatchMs: Long = 0L
    @Volatile private var lastVisionTickMs: Long = 0L
    @Volatile private var visionFramesProcessed: Int = 0
    @Volatile private var visionFps: Float = 0f

    private var nextTrackId: Int = 1
    private val activeTracks = LinkedHashMap<Int, TrackState>()
    private val promotedQueue = ConcurrentLinkedQueue<String>()
    private val latestVisionJson = AtomicReference<String>("{}")
    @Volatile private var discardedCount: Int = 0
    @Volatile private var promotedCount: Int = 0

    // Camera calibration metadata for 3D overlay alignment
    @Volatile private var camFovTanX: Float = 0.76f
    @Volatile private var camFovTanY: Float = 0.57f
    @Volatile private var camOffsetX: Float = -0.032f
    @Volatile private var camOffsetY: Float = 0.0f

    private val latestJpeg = AtomicReference<ByteArray>(ByteArray(0))
    @Volatile private var camStatus: String = "idle"
    @Volatile private var frameCount: Int = 0
    @Volatile private var activeCameraId: String = ""
    @Volatile private var activeSize: String = ""
    @Volatile private var lastJpegSaveMs: Long = 0L
    @Volatile private var camOpening: Boolean = false

    // Microphone (AudioRecord 24kHz PCM16 with VOICE_COMMUNICATION AEC)
    private val micRunning = AtomicBoolean(false)
    private var micThread: Thread? = null
    @Volatile private var micStatus: String = "idle"
    @Volatile private var micDevicesSummary: String = ""
    @Volatile private var micRmsLevel: Double = 0.0
    @Volatile private var micPeakAbs: Int = 0
    @Volatile private var micReadChunks: Int = 0
    @Volatile private var voiceSpeakingRecentMs: Long = 0L

    // Speaker & Android Korean TTS
    @Volatile private var speakerStatus: String = "idle"
    @Volatile private var speakerDevicesSummary: String = ""
    @Volatile private var chimePlayCount: Int = 0
    private var ttsEngine: TextToSpeech? = null
    @Volatile private var ttsReadyKo: Boolean = false

    @Volatile private var xrSessionReady: Boolean = false

    private val wispRuntime = WispStandaloneRuntime(
        contextProvider = { context },
        activityStarter = { intent ->
            val act = activity
            if (act != null) {
                act.startActivity(intent)
                true
            } else {
                val ctx = context
                if (ctx != null) {
                    ctx.startActivity(intent)
                    true
                } else {
                    false
                }
            }
        },
        latestFrameProvider = { latestJpeg.get() },
        onLiveMicExclusiveChanged = { liveOwnsMic ->
            if (liveOwnsMic) {
                stopMicLoop()
                micStatus = "gpt_live_webrtc"
            } else {
                stopMicLoop()
                micRmsLevel = 0.0
                micStatus = "muted"
            }
            writeHardwareStatusJson()
        }
    )

    override fun getPluginName(): String = "QuestCameraPlugin"

    override fun onGodotMainLoopStarted() {
        super.onGodotMainLoopStarted()
        startBackgroundThreads()
        wispRuntime.start()
        initVisionModelsAsync()
        initTtsSafe()
        probeSpeakerAndPlayBootChime()
        requestPermsOnlyIfMissing()
    }

    override fun onMainPause() {
        // Horizon OS Seamless Multitasking: focusing a 2D window alongside the MR app
        // triggers Activity.onPause() while OpenXR stays in XR_SESSION_STATE_VISIBLE.
        // Keep camera, vision, mic, and Realtime voice alive while xrSessionReady is true!
        if (!xrSessionReady) {
            stopMicLoop()
            closeCamera()
        } else {
            Log.i(TAG, "onMainPause with active XR session: keeping camera & voice alive for Seamless Multitasking")
        }
        super.onMainPause()
    }

    override fun onMainResume() {
        super.onMainResume()
        requestPermsOnlyIfMissing()
        if (xrSessionReady && cameraDevice == null) {
            ensurePermissionsAndStartAsync()
        }
    }

    override fun onMainDestroy() {
        xrSessionReady = false
        wispRuntime.stop()
        stopMicLoop()
        closeCamera()
        try {
            ttsEngine?.stop()
            ttsEngine?.shutdown()
        } catch (_: Throwable) {
        }
        ttsEngine = null
        try { objectDetector?.close() } catch (_: Throwable) {}
        objectDetector = null
        try { handLandmarker?.close() } catch (_: Throwable) {}
        handLandmarker = null
        stopBackgroundThreads()
        super.onMainDestroy()
    }

    override fun onMainRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onMainRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_MEDIA_PERMS) {
            Log.i(TAG, "Permission result: ${permissions.joinToString()} -> ${grantResults.joinToString()}")
            if (xrSessionReady) {
                ensurePermissionsAndStartAsync()
            }
        }
    }

    @UsedByGodot
    fun setXrActive(active: Boolean): String {
        xrSessionReady = active
        if (active) {
            ensurePermissionsAndStartAsync()
        } else {
            wispRuntime.setVoiceLiveActive(false)
            stopMicLoop()
            closeCamera()
        }
        return getStatus()
    }

    @UsedByGodot
    fun toggleVoiceLive(): Boolean {
        return wispRuntime.toggleVoiceLive()
    }

    @UsedByGodot
    fun setVoiceLiveActive(active: Boolean): String {
        wispRuntime.setVoiceLiveActive(active)
        return if (wispRuntime.isVoiceLiveEnabled()) "on" else "off"
    }

    @UsedByGodot
    fun startCamera(): String {
        probeSpeakerOutput(playChime = false)
        requestPermsOnlyIfMissing()
        return getStatus()
    }

    @UsedByGodot
    fun openSetupBrowser(): String {
        return wispRuntime.openUrlIn2dBrowser(WispStandaloneRuntime.SETUP_URL)
    }

    @UsedByGodot
    fun open2dBrowserUrl(url: String): String {
        return wispRuntime.openUrlIn2dBrowser(url)
    }

    @UsedByGodot
    fun getAuthAndVoiceStateJson(): String {
        return wispRuntime.getStateJson()
    }

    @UsedByGodot
    fun popRuntimeEventsJson(): String {
        return wispRuntime.popRuntimeEventsJson()
    }

    @UsedByGodot
    fun runCompanionTurnAsync(turnId: String, payloadJson: String): String {
        return wispRuntime.runCompanionTurnAsync(turnId, payloadJson)
    }

    @UsedByGodot
    fun popCompanionTurnResultsJson(): String {
        return wispRuntime.popTurnResultsJson()
    }

    @UsedByGodot
    fun completeLiveHandoff(handoffId: String, answerText: String, backendLabel: String): String {
        return wispRuntime.completeLiveHandoff(handoffId, answerText, backendLabel)
    }

    @UsedByGodot
    fun appendConversationHistory(role: String, badge: String, text: String): String {
        wispRuntime.appendConversationHistory(role, badge, text)
        return "ok"
    }

    @UsedByGodot
    fun clearConversationHistory(): String {
        wispRuntime.clearConversationHistory()
        return "ok"
    }

    @UsedByGodot
    fun injectRealtimeSensoryEvent(contextText: String, triggerVoiceResponse: Boolean): String {
        return wispRuntime.injectRealtimeSensoryEvent(contextText, triggerVoiceResponse)
    }

    @UsedByGodot
    fun runVisionAnnotateAndEmbedAsync(memId: String, cropPath: String, fallbackHint: String): String {
        return wispRuntime.runVisionAnnotateAndEmbedAsync(memId, cropPath, fallbackHint)
    }

    @UsedByGodot
    fun popVisionUpgradesJson(): String {
        return wispRuntime.popVisionUpgradesJson()
    }

    @UsedByGodot
    fun readCropBase64(cropPath: String): String {
        if (cropPath.isBlank()) return ""
        return try {
            val f = File(cropPath)
            if (!f.exists() || !f.isFile) return ""
            val bytes = f.readBytes()
            if (bytes.size <= 32) return ""
            android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
        } catch (t: Throwable) {
            Log.w(TAG, "readCropBase64 failed ($cropPath): ${t.message}")
            ""
        }
    }

    @UsedByGodot
    fun captureLiveGazeSnapshotJson(): String {
        val out = JSONObject()
        try {
            val extDir = context?.getExternalFilesDir(null)
            val frameBytes = latestJpeg.get()
            if (extDir != null && frameBytes.size > 64) {
                val fullBmp = BitmapFactory.decodeByteArray(frameBytes, 0, frameBytes.size)
                if (fullBmp != null) {
                    // Crop Center-Gaze ROI (middle 56% of passthrough camera)
                    val w = fullBmp.width
                    val h = fullBmp.height
                    val x0 = (w * 0.22f).toInt().coerceIn(0, w - 2)
                    val y0 = (h * 0.22f).toInt().coerceIn(0, h - 2)
                    val cw = (w * 0.56f).toInt().coerceIn(2, w - x0)
                    val ch = (h * 0.56f).toInt().coerceIn(2, h - y0)
                    val cropBmp = Bitmap.createBitmap(fullBmp, x0, y0, cw, ch)
                    val jpgOut = ByteArrayOutputStream()
                    cropBmp.compress(Bitmap.CompressFormat.JPEG, 85, jpgOut)
                    val cropBytes = jpgOut.toByteArray()
                    val cropsDir = File(extDir, "crops").apply { mkdirs() }
                    val f = File(cropsDir, "gaze_live_${System.currentTimeMillis()}.jpg")
                    f.writeBytes(cropBytes)
                    out.put("ok", true)
                    out.put("cropPath", f.absolutePath)
                    out.put("cropB64", android.util.Base64.encodeToString(cropBytes, android.util.Base64.NO_WRAP))
                }
            }
        } catch (t: Throwable) {
            out.put("ok", false)
            out.put("error", t.message ?: "snapshot_err")
        }
        return out.toString()
    }

    @UsedByGodot
    fun playTestChime(): String {
        playMoodChimeAsync("recommend")
        return speakerStatus
    }

    @UsedByGodot
    fun speakOrChime(text: String, mood: String): String {
        playMoodChimeAsync(mood)
        if (text.isNotBlank()) {
            if (wispRuntime.speakLineViaRealtime(text)) {
                return "realtime_spoken"
            }
            if (ttsReadyKo) {
                try {
                    val approxMs = (text.length * 145L + 900L).coerceIn(1200L, 16000L)
                    wispRuntime.markExternalTtsSpeaking(approxMs)
                    ttsEngine?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "utt_${System.currentTimeMillis()}")
                    return "tts_spoken"
                } catch (t: Throwable) {
                    Log.w(TAG, "TTS speak fallback: ${t.message}")
                }
            }
        }
        return "chime_played"
    }

    @UsedByGodot
    fun resetVisionSession(): String {
        visionHandler?.post {
            activeTracks.clear()
            promotedQueue.clear()
            discardedCount = 0
            promotedCount = 0
        }
        return "reset_ok"
    }

    @UsedByGodot
    fun getStatus(): String {
        return "CAM:$camStatus($activeCameraId $activeSize #$frameCount) | VISION:obj=$mpObjectReady,hand=$mpHandReady(${String.format("%.1f", visionFps)}fps) | MIC:$micStatus(rms=${"%.3f".format(micRmsLevel)}) | SPK:$speakerStatus"
    }

    @UsedByGodot
    fun getUiSummary(): String {
        val barCount = (micRmsLevel * 40.0).toInt().coerceIn(0, 10)
        val meter = "#".repeat(barCount) + "-".repeat(10 - barCount)
        return "카메라: $camStatus (ID $activeCameraId $activeSize) | 비전: ${"%.1f".format(visionFps)}Hz (객체=${if (mpObjectReady) "OK" else ".."}, 손=${if (mpHandReady) "OK" else ".."})\n" +
            "마이크: $micStatus [$meter] | 스피커: $speakerStatus${if (ttsReadyKo) "+TTS" else ""}"
    }

    @UsedByGodot
    fun getVisionStateJson(): String {
        return latestVisionJson.get()
    }

    @UsedByGodot
    fun popPromotedCandidatesJson(): String {
        if (promotedQueue.isEmpty()) return "[]"
        val arr = JSONArray()
        while (true) {
            val item = promotedQueue.poll() ?: break
            try {
                arr.put(JSONObject(item))
            } catch (_: Throwable) {
            }
        }
        return arr.toString()
    }

    @UsedByGodot
    fun getMicStateJson(): String {
        val now = System.currentTimeMillis()
        val liveActive = wispRuntime.isVoiceLiveEnabled()
        val rmsVal = if (liveActive) wispRuntime.getLiveMicRms() else micRmsLevel
        val obj = JSONObject()
        obj.put("status", if (liveActive) "gpt_live_webrtc" else micStatus)
        obj.put("rms", rmsVal)
        obj.put("peak", micPeakAbs)
        obj.put("voiceRecent", liveActive && rmsVal > 0.018 || (now - voiceSpeakingRecentMs) < 2200L)
        return obj.toString()
    }

    @UsedByGodot
    fun getLatestFrameJpeg(): ByteArray {
        return latestJpeg.get()
    }

    private fun startBackgroundThreads() {
        if (cameraThread == null) {
            cameraThread = HandlerThread("QuestPassthroughCam").also {
                it.uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, e ->
                    Log.w(TAG, "QuestPassthroughCam caught exception: ${e.message}")
                }
                it.start()
                cameraHandler = Handler(it.looper)
            }
        }
        if (visionThread == null) {
            visionThread = HandlerThread("QuestVisionWorker").also {
                it.uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, e ->
                    Log.w(TAG, "QuestVisionWorker caught exception: ${e.message}")
                }
                it.start()
                visionHandler = Handler(it.looper)
            }
        }
    }

    private fun stopBackgroundThreads() {
        cameraThread?.quitSafely()
        visionThread?.quitSafely()
        try { cameraThread?.join(400) } catch (_: InterruptedException) {}
        try { visionThread?.join(400) } catch (_: InterruptedException) {}
        cameraThread = null
        cameraHandler = null
        visionThread = null
        visionHandler = null
    }

    private fun loadAssetDirectBuffer(assetPath: String): ByteBuffer {
        val ctx = context ?: throw IllegalStateException("No Android context")
        val bytes = ctx.assets.open(assetPath).use { it.readBytes() }
        return ByteBuffer.allocateDirect(bytes.size).apply {
            order(ByteOrder.nativeOrder())
            put(bytes)
            rewind()
        }
    }

    private fun initVisionModelsAsync() {
        startBackgroundThreads()
        visionHandler?.post {
            val ctx = context ?: return@post
            try {
                val objBuf = loadAssetDirectBuffer("models/efficientdet_lite0.tflite")
                val objBase = BaseOptions.builder().setModelAssetBuffer(objBuf).build()
                val objOpts = ObjectDetector.ObjectDetectorOptions.builder()
                    .setBaseOptions(objBase)
                    .setRunningMode(RunningMode.IMAGE)
                    .setMaxResults(6)
                    .setScoreThreshold(0.28f)
                    .build()
                objectDetector = ObjectDetector.createFromOptions(ctx, objOpts)
                mpObjectReady = true
                Log.i(TAG, "MediaPipe ObjectDetector (efficientdet_lite0) ready!")
            } catch (t: Throwable) {
                mpObjectReady = false
                Log.e(TAG, "MediaPipe ObjectDetector init failed (salient tracker still active)", t)
            }

            try {
                val handBuf = loadAssetDirectBuffer("models/hand_landmarker.task")
                val handBase = BaseOptions.builder().setModelAssetBuffer(handBuf).build()
                val handOpts = HandLandmarker.HandLandmarkerOptions.builder()
                    .setBaseOptions(handBase)
                    .setRunningMode(RunningMode.IMAGE)
                    .setNumHands(2)
                    .setMinHandDetectionConfidence(0.35f)
                    .setMinHandPresenceConfidence(0.35f)
                    .build()
                handLandmarker = HandLandmarker.createFromOptions(ctx, handOpts)
                mpHandReady = true
                Log.i(TAG, "MediaPipe HandLandmarker (21-keypoint RGB hand recognition) ready!")
            } catch (t: Throwable) {
                mpHandReady = false
                Log.e(TAG, "MediaPipe HandLandmarker init failed (skin fallback active)", t)
            }
            writeHardwareStatusJson()
        }
    }

    private fun initTtsSafe() {
        val ctx = context ?: return
        try {
            ttsEngine = TextToSpeech(ctx) { status ->
                if (status == TextToSpeech.SUCCESS) {
                    try {
                        val res = ttsEngine?.setLanguage(Locale.KOREAN) ?: TextToSpeech.LANG_NOT_SUPPORTED
                        ttsReadyKo = (res != TextToSpeech.LANG_MISSING_DATA && res != TextToSpeech.LANG_NOT_SUPPORTED)
                        ttsEngine?.setSpeechRate(1.06f)
                        Log.i(TAG, "Android TextToSpeech init status=$status, koReady=$ttsReadyKo")
                    } catch (t: Throwable) {
                        ttsReadyKo = false
                    }
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "TTS unavailable on this ROM: ${t.message}")
        }
    }

    private fun requestPermsOnlyIfMissing() {
        val act = activity ?: return
        val stdCam = ContextCompat.checkSelfPermission(act, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        val headsetCam = ContextCompat.checkSelfPermission(act, PERM_HEADSET_CAMERA) == PackageManager.PERMISSION_GRANTED
        val recAudio = ContextCompat.checkSelfPermission(act, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

        val missing = mutableListOf<String>()
        if (!stdCam) missing.add(Manifest.permission.CAMERA)
        if (!headsetCam) missing.add(PERM_HEADSET_CAMERA)
        if (!recAudio) missing.add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val btConnect = ContextCompat.checkSelfPermission(act, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            if (!btConnect) missing.add(Manifest.permission.BLUETOOTH_CONNECT)
        }

        if (missing.isNotEmpty()) {
            if (!stdCam && !headsetCam) camStatus = "perm_pending"
            if (!recAudio) micStatus = "perm_pending"
            writeHardwareStatusJson()
            ActivityCompat.requestPermissions(act, missing.toTypedArray(), REQ_MEDIA_PERMS)
        }
    }

    private fun ensurePermissionsAndStartAsync() {
        val act = activity ?: return
        val stdCam = ContextCompat.checkSelfPermission(act, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        val headsetCam = ContextCompat.checkSelfPermission(act, PERM_HEADSET_CAMERA) == PackageManager.PERMISSION_GRANTED
        val recAudio = ContextCompat.checkSelfPermission(act, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        Log.i(TAG, "Perms (XR active=$xrSessionReady): CAMERA=$stdCam, HEADSET_CAMERA=$headsetCam, RECORD_AUDIO=$recAudio")

        if (recAudio) {
            micStatus = if (wispRuntime.isVoiceLiveEnabled()) "gpt_live_webrtc" else "muted"
            writeHardwareStatusJson()
        }
        if ((stdCam || headsetCam) && xrSessionReady) {
            startBackgroundThreads()
            cameraHandler?.post {
                if (xrSessionReady) {
                    openPassthroughCamera()
                }
            }
        }
    }

    private fun probeSpeakerAndPlayBootChime() {
        Thread {
            probeSpeakerOutput(playChime = true, mood = "boot")
        }.start()
    }

    private fun playMoodChimeAsync(mood: String) {
        Thread {
            probeSpeakerOutput(playChime = true, mood = mood)
        }.start()
    }

    private fun probeSpeakerOutput(playChime: Boolean, mood: String = "recommend") {
        val ctx = context ?: return
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val names = outs.map { dev -> "${typeName(dev.type)}(${dev.productName})" }.distinct()
            speakerDevicesSummary = if (names.isEmpty()) "none" else names.joinToString(",")
            val musicVol = am.getStreamVolume(AudioManager.STREAM_MUSIC)
            val musicMax = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)

            if (!playChime) {
                if (speakerStatus == "idle") {
                    speakerStatus = if (outs.isNotEmpty()) "ready($musicVol/$musicMax)" else "no_output_device"
                }
                writeHardwareStatusJson()
                return
            }

            val notes: DoubleArray = when (mood) {
                "capture" -> doubleArrayOf(587.33, 880.00)              // D5 -> A5 (clean capture)
                "promote" -> doubleArrayOf(523.25, 659.25, 1046.50)     // C5 -> E5 -> C6 (long-term star)
                "mode" -> doubleArrayOf(440.00, 554.37)                 // A4 -> C#5
                "pinch", "touch" -> doubleArrayOf(659.25, 783.99)       // E5 -> G5
                "boot" -> doubleArrayOf(523.25, 659.25)                 // C5 -> E5
                else -> doubleArrayOf(523.25, 659.25, 783.99)           // C5 -> E5 -> G5
            }
            val totalSec = if (notes.size >= 3) 0.36 else 0.24
            val durationSamples = (SAMPLE_RATE_HZ * totalSec).toInt()
            val pcm = ShortArray(durationSamples)
            val segLen = max(1, durationSamples / notes.size)
            for (i in 0 until durationSamples) {
                val noteIdx = min(notes.size - 1, i / segLen)
                val freq = notes[noteIdx]
                val localPos = (i % segLen).toDouble() / segLen.toDouble()
                val env = (1.0 - localPos * 0.55) * (if (localPos < 0.06) localPos / 0.06 else 1.0)
                val sample = sin(2.0 * PI * freq * i.toDouble() / SAMPLE_RATE_HZ) * 0.20 * env
                pcm[i] = (sample * Short.MAX_VALUE).toInt().toShort()
            }

            val useVoiceComm = wispRuntime.isUsingVoiceCommStream()
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(
                            if (useVoiceComm) AudioAttributes.USAGE_VOICE_COMMUNICATION
                            else AudioAttributes.USAGE_MEDIA
                        )
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
                .setBufferSizeInBytes(pcm.size * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()

            track.write(pcm, 0, pcm.size)
            track.play()
            chimePlayCount += 1
            speakerStatus = "playing_ok(vol=$musicVol/$musicMax)"
            writeHardwareStatusJson()
            Thread.sleep((totalSec * 1000).toLong() + 70L)
            track.stop()
            track.release()
        } catch (t: Throwable) {
            speakerStatus = "err:${t.javaClass.simpleName}"
            Log.e(TAG, "Speaker probe/chime failed", t)
            writeHardwareStatusJson()
        }
    }

    @SuppressLint("MissingPermission")
    private fun startMicLoopIfNeeded() {
        if (micRunning.get()) return
        val ctx = context ?: return
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val ins = am.getDevices(AudioManager.GET_DEVICES_INPUTS)
        micDevicesSummary = ins.map { "${typeName(it.type)}(${it.productName})" }.distinct().joinToString(",")

        micRunning.set(true)
        micThread = Thread({
            var recorder: AudioRecord? = null
            var aec: AcousticEchoCanceler? = null
            var ns: NoiseSuppressor? = null
            try {
                val minBuf = AudioRecord.getMinBufferSize(
                    SAMPLE_RATE_HZ,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                )
                val bufBytes = maxOf(minBuf, SAMPLE_RATE_HZ / 5 * 2)
                recorder = try {
                    AudioRecord(
                        MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                        SAMPLE_RATE_HZ,
                        AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT,
                        bufBytes
                    ).takeIf { it.state == AudioRecord.STATE_INITIALIZED }
                } catch (_: Throwable) {
                    null
                } ?: AudioRecord(
                    MediaRecorder.AudioSource.MIC,
                    SAMPLE_RATE_HZ,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufBytes
                )

                if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                    micStatus = "init_failed"
                    micRunning.set(false)
                    writeHardwareStatusJson()
                    return@Thread
                }

                try {
                    if (AcousticEchoCanceler.isAvailable()) {
                        aec = AcousticEchoCanceler.create(recorder.audioSessionId)?.apply { enabled = true }
                    }
                    if (NoiseSuppressor.isAvailable()) {
                        ns = NoiseSuppressor.create(recorder.audioSessionId)?.apply { enabled = true }
                    }
                } catch (_: Throwable) {}

                recorder.startRecording()
                micStatus = "recording_ok"
                writeHardwareStatusJson()

                val shortBuf = ShortArray(SAMPLE_RATE_HZ / 10)
                while (micRunning.get()) {
                    val n = recorder.read(shortBuf, 0, shortBuf.size)
                    if (n > 0) {
                        var sumSq = 0.0
                        var localPeak = 0
                        for (i in 0 until n) {
                            val v = abs(shortBuf[i].toInt())
                            if (v > localPeak) localPeak = v
                            val norm = shortBuf[i].toDouble() / 32768.0
                            sumSq += norm * norm
                        }
                        val rms = sqrt(sumSq / n.toDouble())
                        micRmsLevel = rms
                        if (rms > 0.020) {
                            voiceSpeakingRecentMs = System.currentTimeMillis()
                        }
                        if (localPeak > micPeakAbs) micPeakAbs = localPeak
                        micReadChunks += 1
                        if (micReadChunks == 1 || micReadChunks % 25 == 0) {
                            writeHardwareStatusJson()
                        }
                    } else {
                        Thread.sleep(50)
                    }
                }
            } catch (t: Throwable) {
                micStatus = "err:${t.javaClass.simpleName}"
                Log.e(TAG, "Mic capture loop failed", t)
                writeHardwareStatusJson()
            } finally {
                try { aec?.release() } catch (_: Throwable) {}
                try { ns?.release() } catch (_: Throwable) {}
                try { recorder?.stop() } catch (_: Throwable) {}
                try { recorder?.release() } catch (_: Throwable) {}
                micRunning.set(false)
            }
        }, "QuestMicMonitor").also { it.start() }
    }

    private fun stopMicLoop() {
        micRunning.set(false)
        try { micThread?.join(400) } catch (_: InterruptedException) {}
        micThread = null
    }

    private fun typeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "BUILTIN_MIC"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "BUILTIN_SPEAKER"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "BLUETOOTH"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "USB_AUDIO"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "WIRED_HEADSET"
        AudioDeviceInfo.TYPE_TELEPHONY -> "TELEPHONY"
        else -> "TYPE_$type"
    }

    @SuppressLint("MissingPermission")
    private fun openPassthroughCamera() {
        if (cameraDevice != null || camOpening) return
        val ctx = context ?: return

        startBackgroundThreads()
        val manager = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        try {
            val ids = manager.cameraIdList
            if (ids.isEmpty()) {
                camStatus = "no_camera_ids_exposed"
                writeHardwareStatusJson()
                return
            }

            val candidates = mutableListOf<Pair<String, Size>>()
            val discoveredArr = JSONArray()

            for (id in ids) {
                val chars = manager.getCameraCharacteristics(id)
                val facing = chars.get(CameraCharacteristics.LENS_FACING)
                val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                val sizes = map?.getOutputSizes(ImageFormat.YUV_420_888) ?: emptyArray()
                val info = JSONObject()
                info.put("id", id)
                info.put("lensFacing", facing ?: -1)
                info.put("yuv_sizes", sizes.joinToString { "${it.width}x${it.height}" })
                discoveredArr.put(info)

                if (sizes.isNotEmpty()) {
                    candidates.add(id to pickBestSize(sizes))
                }
            }

            val sortedCandidates = candidates.sortedBy { (id, _) ->
                val facing = manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
                when {
                    id == "50" -> 0
                    id == "51" -> 1
                    facing == CameraCharacteristics.LENS_FACING_BACK -> 2
                    else -> 9
                }
            }

            if (sortedCandidates.isEmpty()) {
                camStatus = "no_yuv420_camera_found"
                writeHardwareStatusJson(discoveredArr)
                return
            }

            var openedAny = false
            var lastErr = ""
            for ((candId, candSize) in sortedCandidates) {
                try {
                    camOpening = true
                    activeCameraId = candId
                    activeSize = "${candSize.width}x${candSize.height}"
                    camStatus = "opening_$candId"

                    // Read intrinsics & pose for 3D bounding box calibration
                    val chars = manager.getCameraCharacteristics(candId)
                    val intr = chars.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)
                    val pixelArray = chars.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
                    if (intr != null && intr.size >= 4 && intr[0] > 10f && intr[1] > 10f) {
                        val refW = (pixelArray?.width ?: candSize.width).toFloat()
                        val refH = (pixelArray?.height ?: candSize.height).toFloat()
                        val tx = (refW * 0.5f) / intr[0]
                        val ty = (refH * 0.5f) / intr[1]
                        if (tx in 0.35f..1.35f && ty in 0.30f..1.25f) {
                            camFovTanX = tx
                            camFovTanY = ty
                        }
                    }
                    val poseT = chars.get(CameraCharacteristics.LENS_POSE_TRANSLATION)
                    if (poseT != null && poseT.size >= 2) {
                        camOffsetX = poseT[0].coerceIn(-0.08f, 0.08f)
                        camOffsetY = poseT[1].coerceIn(-0.08f, 0.08f)
                    }

                    writeHardwareStatusJson(discoveredArr)

                    imageReader?.close()
                    imageReader = ImageReader.newInstance(
                        candSize.width,
                        candSize.height,
                        ImageFormat.YUV_420_888,
                        2
                    ).apply {
                        setOnImageAvailableListener({ reader ->
                            val img = try { reader.acquireLatestImage() } catch (_: Throwable) { null }
                            if (img != null) {
                                try {
                                    handleCameraFrame(img)
                                } catch (t: Throwable) {
                                    Log.e(TAG, "Frame handle error", t)
                                } finally {
                                    img.close()
                                }
                            }
                        }, cameraHandler)
                    }

                    manager.openCamera(candId, object : CameraDevice.StateCallback() {
                        override fun onOpened(camera: CameraDevice) {
                            camOpening = false
                            cameraDevice = camera
                            camStatus = "camera_opened"
                            Log.i(TAG, "Camera $candId opened ($activeSize) fovTan=(${camFovTanX}, ${camFovTanY})")
                            createCaptureSession(camera)
                        }

                        override fun onDisconnected(camera: CameraDevice) {
                            camOpening = false
                            camStatus = "camera_disconnected"
                            camera.close()
                            cameraDevice = null
                            writeHardwareStatusJson()
                        }

                        override fun onError(camera: CameraDevice, error: Int) {
                            camOpening = false
                            camStatus = "camera_error_$error"
                            Log.e(TAG, "Camera $candId error: $error")
                            camera.close()
                            cameraDevice = null
                            writeHardwareStatusJson()
                        }
                    }, cameraHandler)

                    openedAny = true
                    break
                } catch (sec: SecurityException) {
                    camOpening = false
                    lastErr = "cam_${candId}_SecurityException"
                    Log.w(TAG, "Skipping restricted camera ID $candId: ${sec.message}")
                }
            }

            if (!openedAny) {
                camStatus = "err_all_cameras_blocked:$lastErr"
                writeHardwareStatusJson(discoveredArr)
            }
        } catch (t: Throwable) {
            camOpening = false
            camStatus = "err_${t.javaClass.simpleName}:${t.message}"
            Log.e(TAG, "Failed to open passthrough camera", t)
            writeHardwareStatusJson()
        }
    }

    private fun pickBestSize(sizes: Array<Size>): Size {
        val preferred = sizes.firstOrNull { it.width == 640 && it.height == 480 }
            ?: sizes.firstOrNull { it.width in 600..1280 && it.height in 480..960 }
        return preferred ?: sizes.minByOrNull { abs(it.width * it.height - 640 * 480) } ?: sizes[0]
    }

    private fun createCaptureSession(camera: CameraDevice) {
        val surface = imageReader?.surface ?: return
        try {
            camera.createCaptureSession(
                listOf(surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        try {
                            val req = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                                addTarget(surface)
                            }
                            session.setRepeatingRequest(req.build(), null, cameraHandler)
                            camStatus = "streaming_ok"
                            Log.i(TAG, "Passthrough Camera streaming active! ($activeCameraId $activeSize)")
                            writeHardwareStatusJson()
                        } catch (t: Throwable) {
                            camStatus = "session_req_err:${t.message}"
                            writeHardwareStatusJson()
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        camStatus = "session_configure_failed"
                        writeHardwareStatusJson()
                    }
                },
                cameraHandler
            )
        } catch (t: Throwable) {
            camStatus = "create_session_err:${t.message}"
            writeHardwareStatusJson()
        }
    }

    private fun handleCameraFrame(image: Image) {
        val now = System.currentTimeMillis()

        // 1) Dispatch downscaled RGB Bitmap to Vision Worker at ~8Hz without blocking camera thread
        if (now - lastVisionDispatchMs >= VISION_INTERVAL_MS && visionBusy.compareAndSet(false, true)) {
            lastVisionDispatchMs = now
            val bmp = yuv420ToScaledBitmap(image, VISION_W, VISION_H)
            visionHandler?.post {
                try {
                    runVisionPipeline(bmp, now)
                } catch (t: Throwable) {
                    Log.e(TAG, "Vision worker error", t)
                } finally {
                    visionBusy.set(false)
                }
            }
        }

        // 2) Save diagnostic JPEG preview every ~750ms
        if (now - lastJpegSaveMs >= 750L) {
            lastJpegSaveMs = now
            val nv21 = yuv420888ToNv21(image)
            val out = ByteArrayOutputStream()
            val yuvImage = YuvImage(nv21, ImageFormat.NV21, image.width, image.height, null)
            yuvImage.compressToJpeg(Rect(0, 0, image.width, image.height), 80, out)
            val jpegBytes = out.toByteArray()
            latestJpeg.set(jpegBytes)
            frameCount += 1

            if (frameCount == 1 || frameCount % 6 == 0) {
                val extDir = context?.getExternalFilesDir(null)
                if (extDir != null) {
                    val tmpFile = File(extDir, "latest_camera.tmp")
                    val finalFile = File(extDir, "latest_camera.jpg")
                    tmpFile.writeBytes(jpegBytes)
                    tmpFile.renameTo(finalFile)
                    writeHardwareStatusJson()
                }
            }
        }
    }

    private fun yuv420ToScaledBitmap(image: Image, dstW: Int, dstH: Int): Bitmap {
        val srcW = image.width
        val srcH = image.height
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]

        val yBuf = yPlane.buffer
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer

        val yRowStride = yPlane.rowStride
        val yPixStride = yPlane.pixelStride
        val uRowStride = uPlane.rowStride
        val uPixStride = uPlane.pixelStride
        val vRowStride = vPlane.rowStride
        val vPixStride = vPlane.pixelStride

        val pixels = IntArray(dstW * dstH)
        var idx = 0
        for (dy in 0 until dstH) {
            val sy = (dy * srcH) / dstH
            val yRow = sy * yRowStride
            val uvY = sy shr 1
            val uRow = uvY * uRowStride
            val vRow = uvY * vRowStride
            for (dx in 0 until dstW) {
                val sx = (dx * srcW) / dstW
                val uvX = sx shr 1
                val yVal = (yBuf.get(yRow + sx * yPixStride).toInt() and 0xFF)
                val uVal = (uBuf.get(uRow + uvX * uPixStride).toInt() and 0xFF) - 128
                val vVal = (vBuf.get(vRow + uvX * vPixStride).toInt() and 0xFF) - 128

                val r = (yVal + ((1436 * vVal) shr 10)).coerceIn(0, 255)
                val g = (yVal - ((352 * uVal + 731 * vVal) shr 10)).coerceIn(0, 255)
                val b = (yVal + ((1815 * uVal) shr 10)).coerceIn(0, 255)
                pixels[idx++] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        return Bitmap.createBitmap(pixels, dstW, dstH, Bitmap.Config.ARGB_8888)
    }

    private fun runVisionPipeline(bmp: Bitmap, nowMs: Long) {
        val dtSec: Float = if (lastVisionTickMs > 0L) {
            ((nowMs - lastVisionTickMs).toFloat() / 1000f).coerceIn(0.04f, 0.50f)
        } else {
            0.125f
        }
        lastVisionTickMs = nowMs
        visionFramesProcessed += 1
        visionFps = if (visionFps <= 0.1f) (1f / dtSec) else (visionFps * 0.8f + (1f / dtSec) * 0.2f)

        val mpImg = BitmapImageBuilder(bmp).build()

        // A. RGB Hand Detection (MediaPipe 21-keypoint HandLandmarker + skin fallback)
        val handsJsonArr = JSONArray()
        val handBoxes = mutableListOf<FloatArray>()
        val hl = handLandmarker
        if (hl != null && mpHandReady) {
            try {
                val handRes = hl.detect(mpImg)
                val landmarksList = handRes.landmarks()
                for (hIdx in landmarksList.indices) {
                    val lms = landmarksList[hIdx]
                    if (lms.size >= 21) {
                        var minX = 1f
                        var minY = 1f
                        var maxX = 0f
                        var maxY = 0f
                        for (lm in lms) {
                            val lx = lm.x().coerceIn(0f, 1f)
                            val ly = lm.y().coerceIn(0f, 1f)
                            if (lx < minX) minX = lx
                            if (ly < minY) minY = ly
                            if (lx > maxX) maxX = lx
                            if (ly > maxY) maxY = ly
                        }
                        val wrist = lms[0]
                        val thumbTip = lms[4]
                        val indexMcp = lms[5]
                        val indexTip = lms[8]
                        val middleMcp = lms[9]
                        val pinkyMcp = lms[17]

                        val palmX = ((wrist.x() + indexMcp.x() + middleMcp.x() + pinkyMcp.x()) * 0.25f).coerceIn(0f, 1f)
                        val palmY = ((wrist.y() + indexMcp.y() + middleMcp.y() + pinkyMcp.y()) * 0.25f).coerceIn(0f, 1f)
                        val pinchDist = hypot(thumbTip.x() - indexTip.x(), thumbTip.y() - indexTip.y())
                        val palmSpan = hypot(wrist.x() - middleMcp.x(), wrist.y() - middleMcp.y()).coerceAtLeast(0.04f)
                        val approxDepthM = (0.095f / palmSpan).coerceIn(0.24f, 0.92f)
                        val isPinching = pinchDist < (palmSpan * 0.34f).coerceIn(0.032f, 0.072f)

                        handBoxes.add(floatArrayOf(minX, minY, maxX, maxY))
                        val hObj = JSONObject().apply {
                            put("source", "mediapipe_rgb")
                            put("xmin", minX)
                            put("ymin", minY)
                            put("xmax", maxX)
                            put("ymax", maxY)
                            put("ix", indexTip.x().coerceIn(0f, 1f))
                            put("iy", indexTip.y().coerceIn(0f, 1f))
                            put("tx", thumbTip.x().coerceIn(0f, 1f))
                            put("ty", thumbTip.y().coerceIn(0f, 1f))
                            put("px", palmX)
                            put("py", palmY)
                            put("pinchDist", pinchDist)
                            put("isPinching", isPinching)
                            put("approxDepthM", approxDepthM)
                        }
                        handsJsonArr.put(hObj)
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "HandLandmarker frame err: ${t.message}")
            }
        }

        // B. Object Detection (MediaPipe EfficientDet-Lite0 + Salient Center Object Proposal)
        val detections = mutableListOf<RawDetection>()
        val od = objectDetector
        if (od != null && mpObjectReady) {
            try {
                val detRes = od.detect(mpImg)
                val bw = bmp.width.toFloat()
                val bh = bmp.height.toFloat()
                for (det in detRes.detections()) {
                    val cats = det.categories()
                    if (cats.isEmpty()) continue
                    val top = cats[0]
                    val rawLabel = top.categoryName()?.lowercase(Locale.US)?.trim() ?: "object"
                    val score = top.score()
                    val rect = det.boundingBox()
                    val xmin = (rect.left / bw).coerceIn(0f, 1f)
                    val ymin = (rect.top / bh).coerceIn(0f, 1f)
                    val xmax = (rect.right / bw).coerceIn(0f, 1f)
                    val ymax = (rect.bottom / bh).coerceIn(0f, 1f)
                    val area = (xmax - xmin) * (ymax - ymin)
                    if (area < 0.006f || area > 0.72f) continue

                    // Do not index humans/hands as inanimate object memories; remap indoor false-positive 'toilet'
                    if (rawLabel == "person") continue
                    val normalizedLabel = if (rawLabel == "toilet") "desk_object" else rawLabel
                    detections.add(RawDetection(normalizedLabel, score, xmin, ymin, xmax, ymax))
                }
            } catch (t: Throwable) {
                Log.w(TAG, "ObjectDetector frame err: ${t.message}")
            }
        }

        // Open-vocabulary Center Salient Object Proposal (catches non-COCO desk props in gaze center!)
        val hasCenteredDet = detections.any {
            val cx = (it.xmin + it.xmax) * 0.5f
            val cy = (it.ymin + it.ymax) * 0.5f
            hypot(cx - 0.5f, cy - 0.5f) <= 0.21f
        }
        if (!hasCenteredDet) {
            val salient = detectSalientCenterObject(bmp, handBoxes)
            if (salient != null) {
                detections.add(salient)
            }
        }

        // C. Multi-Object Tracking + Center-Gaze Interest Scoring + Sensory Crop Promotion
        updateTracksAndInterest(bmp, detections, dtSec, nowMs)

        // D. Publish live Vision JSON for Godot 3D overlays & companion state
        val tracksArr = JSONArray()
        val sortedTracks = activeTracks.values.sortedByDescending { it.interestScore }
        for (tr in sortedTracks.take(5)) {
            val tObj = JSONObject().apply {
                put("trackId", tr.id)
                put("label", tr.label)
                put("detScore", tr.detScore)
                put("xmin", tr.xmin)
                put("ymin", tr.ymin)
                put("xmax", tr.xmax)
                put("ymax", tr.ymax)
                put("centerDist", tr.centerDist)
                put("inCenterRoi", tr.inCenterRoi)
                put("timeToCenterSec", tr.timeToCenterSec)
                put("dwellSec", tr.centerDwellSec)
                put("interestScore", tr.interestScore)
                put("promoted", tr.promoted)
                put("colorToneKo", tr.colorToneKo)
            }
            tracksArr.put(tObj)
        }

        val root = JSONObject().apply {
            put("timestampMs", nowMs)
            put("visionFps", visionFps)
            put("mpObjectReady", mpObjectReady)
            put("mpHandReady", mpHandReady)
            put("fovTanX", camFovTanX)
            put("fovTanY", camFovTanY)
            put("camOffsetX", camOffsetX)
            put("camOffsetY", camOffsetY)
            put("centerRoiRadius", CENTER_ROI_RADIUS)
            put("interestThreshold", INTEREST_THRESHOLD)
            put("discardedCount", discardedCount)
            put("promotedCount", promotedCount)
            put("hands", handsJsonArr)
            put("tracks", tracksArr)
        }
        latestVisionJson.set(root.toString())
    }

    private fun detectSalientCenterObject(bmp: Bitmap, handBoxes: List<FloatArray>): RawDetection? {
        val w = bmp.width
        val h = bmp.height
        val ix0 = (w * 0.37f).toInt()
        val ix1 = (w * 0.63f).toInt()
        val iy0 = (h * 0.37f).toInt()
        val iy1 = (h * 0.63f).toInt()

        val ox0 = (w * 0.18f).toInt()
        val ox1 = (w * 0.82f).toInt()
        val oy0 = (h * 0.18f).toInt()
        val oy1 = (h * 0.82f).toInt()

        var inR = 0L; var inG = 0L; var inB = 0L; var inCnt = 0
        var outR = 0L; var outG = 0L; var outB = 0L; var outCnt = 0
        var inEdge = 0L

        var y = oy0
        while (y < oy1) {
            var x = ox0
            while (x < ox1) {
                val c = bmp.getPixel(x, y)
                val r = (c shr 16) and 0xFF
                val g = (c shr 8) and 0xFF
                val b = c and 0xFF
                if (x in ix0 until ix1 && y in iy0 until iy1) {
                    inR += r; inG += g; inB += b; inCnt++
                    if (x + 2 < ix1 && y + 2 < iy1) {
                        val c2 = bmp.getPixel(x + 2, y + 2)
                        val dr = abs(r - ((c2 shr 16) and 0xFF))
                        val dg = abs(g - ((c2 shr 8) and 0xFF))
                        val db = abs(b - (c2 and 0xFF))
                        inEdge += (dr + dg + db)
                    }
                } else {
                    outR += r; outG += g; outB += b; outCnt++
                }
                x += 3
            }
            y += 3
        }
        if (inCnt < 20 || outCnt < 20) return null

        val mInR = (inR / inCnt).toFloat()
        val mInG = (inG / inCnt).toFloat()
        val mInB = (inB / inCnt).toFloat()
        val mOutR = (outR / outCnt).toFloat()
        val mOutG = (outG / outCnt).toFloat()
        val mOutB = (outB / outCnt).toFloat()

        val colorContrast = sqrt(
            (mInR - mOutR) * (mInR - mOutR) +
            (mInG - mOutG) * (mInG - mOutG) +
            (mInB - mOutB) * (mInB - mOutB)
        )
        val meanEdge = inEdge.toFloat() / inCnt.toFloat()
        val salience = colorContrast * 0.75f + meanEdge * 0.55f
        if (salience < 28.0f) return null

        // Tighten bounding box around pixels matching the foreground object vs outer background
        var bx0 = w; var by0 = h; var bx1 = 0; var by1 = 0; var fgHits = 0
        var py = (h * 0.26f).toInt()
        val pyEnd = (h * 0.74f).toInt()
        val pxStart = (w * 0.26f).toInt()
        val pxEnd = (w * 0.74f).toInt()
        while (py < pyEnd) {
            var px = pxStart
            while (px < pxEnd) {
                val c = bmp.getPixel(px, py)
                val r = ((c shr 16) and 0xFF).toFloat()
                val g = ((c shr 8) and 0xFF).toFloat()
                val b = (c and 0xFF).toFloat()
                val dIn = abs(r - mInR) + abs(g - mInG) + abs(b - mInB)
                val dOut = abs(r - mOutR) + abs(g - mOutG) + abs(b - mOutB)
                if (dIn + 18f < dOut) {
                    if (px < bx0) bx0 = px
                    if (py < by0) by0 = py
                    if (px > bx1) bx1 = px
                    if (py > by1) by1 = py
                    fgHits++
                }
                px += 4
            }
            py += 4
        }

        val xmin: Float
        val ymin: Float
        val xmax: Float
        val ymax: Float
        if (fgHits >= 12 && bx1 > bx0 + 16 && by1 > by0 + 16) {
            xmin = (bx0.toFloat() / w.toFloat()).coerceIn(0.24f, 0.46f)
            ymin = (by0.toFloat() / h.toFloat()).coerceIn(0.24f, 0.46f)
            xmax = (bx1.toFloat() / w.toFloat()).coerceIn(0.54f, 0.76f)
            ymax = (by1.toFloat() / h.toFloat()).coerceIn(0.54f, 0.76f)
        } else {
            xmin = 0.36f; ymin = 0.36f; xmax = 0.64f; ymax = 0.64f
        }

        for (hb in handBoxes) {
            val hcx = (hb[0] + hb[2]) * 0.5f
            val hcy = (hb[1] + hb[3]) * 0.5f
            if (hypot(hcx - 0.5f, hcy - 0.5f) < 0.27f || boxIoU(xmin, ymin, xmax, ymax, hb[0], hb[1], hb[2], hb[3]) > 0.22f) {
                return null
            }
        }
        val conf = ((salience - 20f) / 65f).coerceIn(0.35f, 0.86f)
        return RawDetection("desk_object", conf, xmin, ymin, xmax, ymax)
    }

    private fun updateTracksAndInterest(
        bmp: Bitmap,
        detections: List<RawDetection>,
        dtSec: Float,
        nowMs: Long
    ) {
        val matchedTrackIds = HashSet<Int>()

        for (det in detections) {
            val dcx = (det.xmin + det.xmax) * 0.5f
            val dcy = (det.ymin + det.ymax) * 0.5f

            var bestTrack: TrackState? = null
            var bestScore = 0f

            for (tr in activeTracks.values) {
                if (tr.id in matchedTrackIds) continue
                val tcx = (tr.xmin + tr.xmax) * 0.5f
                val tcy = (tr.ymin + tr.ymax) * 0.5f
                val iou = boxIoU(det.xmin, det.ymin, det.xmax, det.ymax, tr.xmin, tr.ymin, tr.xmax, tr.ymax)
                val dist = hypot(dcx - tcx, dcy - tcy)
                val sameCat = (tr.label == det.label) || (tr.label == "desk_object" || det.label == "desk_object")
                val assoc = iou + (if (sameCat && dist < 0.18f) (0.18f - dist) * 2.2f else 0f)
                if (assoc > 0.22f && assoc > bestScore) {
                    bestScore = assoc
                    bestTrack = tr
                }
            }

            val tr = if (bestTrack != null) {
                matchedTrackIds.add(bestTrack.id)
                if (bestTrack.label == "desk_object" && det.label != "desk_object") {
                    bestTrack.label = det.label
                }
                bestTrack.detScore = max(bestTrack.detScore * 0.85f, det.score)
                bestTrack.xmin = bestTrack.xmin * 0.42f + det.xmin * 0.58f
                bestTrack.ymin = bestTrack.ymin * 0.42f + det.ymin * 0.58f
                bestTrack.xmax = bestTrack.xmax * 0.42f + det.xmax * 0.58f
                bestTrack.ymax = bestTrack.ymax * 0.42f + det.ymax * 0.58f
                bestTrack.lastSeenMs = nowMs
                bestTrack
            } else {
                val created = TrackState(
                    id = nextTrackId++,
                    label = det.label,
                    detScore = det.score,
                    xmin = det.xmin,
                    ymin = det.ymin,
                    xmax = det.xmax,
                    ymax = det.ymax,
                    firstSeenMs = nowMs
                )
                activeTracks[created.id] = created
                matchedTrackIds.add(created.id)
                created
            }

            val cx = (tr.xmin + tr.xmax) * 0.5f
            val cy = (tr.ymin + tr.ymax) * 0.5f
            val cDist = hypot(cx - 0.5f, cy - 0.5f)
            tr.centerDist = cDist
            if (cDist < tr.minCenterDist) tr.minCenterDist = cDist

            val inRoi = cDist <= CENTER_ROI_RADIUS
            if (inRoi) {
                if (tr.firstEnterRoiMs < 0L) {
                    tr.firstEnterRoiMs = nowMs
                    tr.timeToCenterSec = ((nowMs - tr.firstSeenMs).toFloat() / 1000f).coerceAtLeast(0.05f)
                } else if (!tr.wasInCenterRoi) {
                    tr.reentryCount += 1
                }
                tr.centerDwellSec += dtSec
                tr.continuousDwellSec += dtSec
            } else {
                tr.continuousDwellSec = 0f
            }
            tr.inCenterRoi = inRoi
            tr.wasInCenterRoi = inRoi

            // Compute Center-Gaze Interest Score (0..100)
            val ttcPts = if (tr.firstEnterRoiMs >= 0L) {
                30f * (1f - ((tr.timeToCenterSec - 0.12f) / 3.2f).coerceIn(0f, 1f))
            } else {
                0f
            }
            val dwellPts = (tr.centerDwellSec / 1.65f).coerceIn(0f, 1f) * 42f +
                (tr.continuousDwellSec / 1.35f).coerceIn(0f, 1f) * 6f
            val proxPts = (1f - (tr.minCenterDist / 0.28f).coerceIn(0f, 1f)) * 18f +
                (tr.reentryCount.coerceAtMost(2) * 2f)
            tr.interestScore = (ttcPts + dwellPts + proxPts).coerceIn(0f, 100f)

            // Cache sharpest centered crop in Sensory Buffer
            if (inRoi && (tr.bestCropBytes == null || cDist <= tr.bestCropCenterDist + 0.015f)) {
                captureCropAndVisualSignature(bmp, tr)
                tr.bestCropCenterDist = min(tr.bestCropCenterDist, cDist)
            }

            // Promote to Mid-Term Memory once threshold reached!
            if (!tr.promoted && tr.interestScore >= INTEREST_THRESHOLD && tr.centerDwellSec >= 0.85f) {
                if (tr.bestCropBytes == null) {
                    captureCropAndVisualSignature(bmp, tr)
                }
                tr.promoted = true
                promotedCount += 1
                emitPromotedCandidate(tr, nowMs)
            }
        }

        // Prune stale tracks: immediately discard below-threshold sensory buffers!
        val iter = activeTracks.entries.iterator()
        while (iter.hasNext()) {
            val entry = iter.next()
            val tr = entry.value
            if (nowMs - tr.lastSeenMs > 1150L) {
                if (!tr.promoted) {
                    tr.bestCropBytes = null
                    discardedCount += 1
                }
                iter.remove()
            }
        }
    }

    private fun captureCropAndVisualSignature(bmp: Bitmap, tr: TrackState) {
        val w = bmp.width
        val h = bmp.height
        val padX = (tr.xmax - tr.xmin) * 0.16f
        val padY = (tr.ymax - tr.ymin) * 0.16f
        val x0 = ((tr.xmin - padX) * w).toInt().coerceIn(0, w - 2)
        val y0 = ((tr.ymin - padY) * h).toInt().coerceIn(0, h - 2)
        val x1 = ((tr.xmax + padX) * w).toInt().coerceIn(x0 + 2, w)
        val y1 = ((tr.ymax + padY) * h).toInt().coerceIn(y0 + 2, h)

        val cropBmp = Bitmap.createBitmap(bmp, x0, y0, x1 - x0, y1 - y0)

        // Hi-res full-frame decode per crop update starved the CPU (10fps, broken tracking); keep the cheap crop path.
        val out = ByteArrayOutputStream()
        cropBmp.compress(Bitmap.CompressFormat.JPEG, 88, out)
        tr.bestCropBytes = out.toByteArray()

        // Extract genuine pixel color tone + 24-bin RGB/spatial visual signature for multimodal embedding
        var sumR = 0f; var sumG = 0f; var sumB = 0f; var cnt = 0
        val hist = FloatArray(24)
        val cw = cropBmp.width
        val ch = cropBmp.height
        var cy = 0
        while (cy < ch) {
            var cx = 0
            while (cx < cw) {
                val p = cropBmp.getPixel(cx, cy)
                val r = ((p shr 16) and 0xFF) / 255f
                val g = ((p shr 8) and 0xFF) / 255f
                val b = (p and 0xFF) / 255f
                sumR += r; sumG += g; sumB += b; cnt++

                val rBin = (r * 5.99f).toInt().coerceIn(0, 5)
                val gBin = (g * 5.99f).toInt().coerceIn(0, 5)
                val bBin = (b * 5.99f).toInt().coerceIn(0, 5)
                hist[rBin] += 1f
                hist[6 + gBin] += 1f
                hist[12 + bBin] += 1f
                val quad = (if (cy >= ch / 2) 2 else 0) + (if (cx >= cw / 2) 1 else 0)
                hist[18 + quad] += (r + g + b) / 3f
                cx += 2
            }
            cy += 2
        }
        if (cnt > 0) {
            val mr = sumR / cnt
            val mg = sumG / cnt
            val mb = sumB / cnt
            val lum = 0.299f * mr + 0.587f * mg + 0.114f * mb
            val maxC = max(mr, max(mg, mb))
            val minC = min(mr, min(mg, mb))
            val sat = if (maxC > 0.01f) (maxC - minC) / maxC else 0f

            tr.brightnessKo = when {
                lum > 0.72f -> "밝은 하이키"
                lum < 0.28f -> "차분한 다크"
                sat > 0.42f -> "선명한 컬러"
                else -> "무광 내추럴"
            }
            tr.colorToneKo = when {
                lum > 0.76f && sat < 0.20f -> "오프화이트/크림 톤"
                lum < 0.24f && sat < 0.26f -> "매트 블랙/차콜 톤"
                sat < 0.16f -> "모던 실버/그레이 톤"
                mr > mg * 1.18f && mg > mb * 1.12f -> "웜 우드/베이지 브라운 톤"
                mr > mg * 1.28f && mr > mb * 1.28f -> "코랄/테라코타 레드 톤"
                mb > mr * 1.20f && mb >= mg -> "코발트/네이비 블루 톤"
                mg > mr * 1.12f && mg >= mb -> "세이지/민트 그린 톤"
                else -> "내추럴 웜 톤"
            }
            hist[22] = (cw.toFloat() / max(1f, ch.toFloat())).coerceIn(0.2f, 3.0f) / 3.0f
            hist[23] = sat
            var norm = 0f
            for (v in hist) norm += v * v
            norm = sqrt(norm).coerceAtLeast(1e-5f)
            for (i in hist.indices) hist[i] /= norm
            tr.rgbSig24 = hist
        }
    }

    private fun emitPromotedCandidate(tr: TrackState, nowMs: Long) {
        val extDir = context?.getExternalFilesDir(null)
        var cropPath = ""
        val bytes = tr.bestCropBytes
        if (extDir != null && bytes != null && bytes.isNotEmpty()) {
            val cropsDir = File(extDir, "crops").apply { mkdirs() }
            val f = File(cropsDir, "crop_track_${tr.id}_${nowMs}.jpg")
            try {
                f.writeBytes(bytes)
                cropPath = f.absolutePath
            } catch (_: Throwable) {
            }
        }
        val sigArr = JSONArray()
        for (v in tr.rgbSig24) sigArr.put(v.toDouble())

        val obj = JSONObject().apply {
            put("trackId", tr.id)
            put("label", tr.label)
            put("detScore", tr.detScore)
            put("colorToneKo", tr.colorToneKo)
            put("brightnessKo", tr.brightnessKo)
            put("timeToCenterSec", if (tr.timeToCenterSec >= 0f) tr.timeToCenterSec else 0.25f)
            put("dwellSec", tr.centerDwellSec)
            put("interestScore", tr.interestScore)
            put("minCenterDist", tr.minCenterDist)
            put("reentryCount", tr.reentryCount)
            put("cropPath", cropPath)
            put("rgbSig24", sigArr)
            put("timestampMs", nowMs)
        }
        promotedQueue.add(obj.toString())
        Log.i(TAG, "Promoted Track #${tr.id} (${tr.label}, ${tr.colorToneKo}) score=${tr.interestScore} to Mid-Term Memory!")
    }

    private fun boxIoU(
        ax0: Float, ay0: Float, ax1: Float, ay1: Float,
        bx0: Float, by0: Float, bx1: Float, by1: Float
    ): Float {
        val ix0 = max(ax0, bx0)
        val iy0 = max(ay0, by0)
        val ix1 = min(ax1, bx1)
        val iy1 = min(ay1, by1)
        val iw = (ix1 - ix0).coerceAtLeast(0f)
        val ih = (iy1 - iy0).coerceAtLeast(0f)
        val inter = iw * ih
        if (inter <= 0f) return 0f
        val areaA = (ax1 - ax0).coerceAtLeast(0f) * (ay1 - ay0).coerceAtLeast(0f)
        val areaB = (bx1 - bx0).coerceAtLeast(0f) * (by1 - by0).coerceAtLeast(0f)
        return inter / (areaA + areaB - inter + 1e-6f)
    }

    private fun yuv420888ToNv21(image: Image): ByteArray {
        val width = image.width
        val height = image.height
        val ySize = width * height
        val uvSize = (width / 2) * (height / 2) * 2
        val nv21 = ByteArray(ySize + uvSize)

        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]

        val yBuf = yPlane.buffer
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer

        val yRowStride = yPlane.rowStride
        val yPixStride = yPlane.pixelStride

        var pos = 0
        for (r in 0 until height) {
            val rowStart = r * yRowStride
            for (c in 0 until width) {
                nv21[pos++] = yBuf.get(rowStart + c * yPixStride)
            }
        }

        val uRowStride = uPlane.rowStride
        val uPixStride = uPlane.pixelStride
        val vRowStride = vPlane.rowStride
        val vPixStride = vPlane.pixelStride

        val chromaH = height / 2
        val chromaW = width / 2
        for (r in 0 until chromaH) {
            val vRow = r * vRowStride
            val uRow = r * uRowStride
            for (c in 0 until chromaW) {
                nv21[pos++] = vBuf.get(vRow + c * vPixStride)
                nv21[pos++] = uBuf.get(uRow + c * uPixStride)
            }
        }
        return nv21
    }

    private fun writeHardwareStatusJson(discovered: JSONArray? = null) {
        try {
            val extDir = context?.getExternalFilesDir(null) ?: return
            val obj = JSONObject()
            val camObj = JSONObject().apply {
                put("status", camStatus)
                put("activeCameraId", activeCameraId)
                put("activeSize", activeSize)
                put("frameCount", frameCount)
                put("visionFps", visionFps)
                put("mpObjectReady", mpObjectReady)
                put("mpHandReady", mpHandReady)
                put("discardedCount", discardedCount)
                put("promotedCount", promotedCount)
                if (discovered != null) put("discoveredCameras", discovered)
            }
            val micObj = JSONObject().apply {
                put("status", micStatus)
                put("sampleRateHz", SAMPLE_RATE_HZ)
                put("devices", micDevicesSummary)
                put("rmsLevel", micRmsLevel)
                put("peakAbsPcm16", micPeakAbs)
                put("readChunks", micReadChunks)
            }
            val spkObj = JSONObject().apply {
                put("status", speakerStatus)
                put("sampleRateHz", SAMPLE_RATE_HZ)
                put("devices", speakerDevicesSummary)
                put("chimePlayCount", chimePlayCount)
                put("ttsReadyKo", ttsReadyKo)
            }
            obj.put("camera", camObj)
            obj.put("microphone", micObj)
            obj.put("speaker", spkObj)
            obj.put("timestampMs", System.currentTimeMillis())
            File(extDir, "hardware_status.json").writeText(obj.toString(2))
        } catch (_: Throwable) {
        }
    }

    private fun closeCamera() {
        camOpening = false
        try { captureSession?.close() } catch (_: Throwable) {}
        captureSession = null
        try { cameraDevice?.close() } catch (_: Throwable) {}
        cameraDevice = null
        try { imageReader?.close() } catch (_: Throwable) {}
        imageReader = null
        if (camStatus.startsWith("streaming") || camStatus.startsWith("opening") || camStatus == "camera_opened") {
            camStatus = "paused"
            writeHardwareStatusJson()
        }
    }
}
