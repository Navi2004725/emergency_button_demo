package com.example.twilio_demo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import org.tensorflow.lite.Interpreter
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import kotlin.math.max

class SafetyMonitorService : Service() {
    companion object {
        private const val TAG = "SafetyMonitorService"
        private const val ACTION_START = "com.example.twilio_demo.START_MONITORING"
        private const val ACTION_STOP_MONITORING = "com.example.twilio_demo.STOP_MONITORING"
        private const val ACTION_RESTORE_WHILE_VISIBLE = "com.example.twilio_demo.RESTORE_WHILE_VISIBLE"
        private const val MONITOR_CHANNEL_ID = "usafe_monitor"
        private const val ONGOING_NOTIFICATION_ID = 1001
        private const val EXTRA_RESTORE_LISTENING = "restore_listening"

        private const val THRESHOLD = 0.9
        private const val HIGH_THRESHOLD = 0.95
        private const val PEAK_THRESHOLD = 1.0
        private const val INFERENCE_INTERVAL_MS = 1000L
        private const val STAGNANT_AUDIO_MS = 3000L
        private const val STARTUP_GRACE_MS = 5000L
        private const val RECOVERY_CONFIRM_MS = 1500L
        private const val RECOVERY_DISTINCT_FINGERPRINTS = 3
        private const val MAX_AUTO_RECOVERY_ATTEMPTS = 3
        private const val MIN_MEAN_ABS_AMPLITUDE = 0.0035
        private const val MIN_STALE_MEAN_ABS_AMPLITUDE = 0.008

        fun startService(context: Context) {
            val intent = Intent(context, SafetyMonitorService::class.java).apply {
                action = ACTION_START
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stopService(context: Context) {
            val intent = Intent(context, SafetyMonitorService::class.java).apply {
                action = ACTION_STOP_MONITORING
            }
            context.startService(intent)
        }

        fun restoreListeningWhenVisible(context: Context) {
            val intent = Intent(context, SafetyMonitorService::class.java).apply {
                action = ACTION_RESTORE_WHILE_VISIBLE
            }
            context.startService(intent)
        }
    }

    private enum class CaptureState {
        NORMAL,
        RECOVERING,
        STUCK,
    }

    private enum class StuckReason {
        NONE,
        BACKGROUND_RESTORE_REQUIRED,
        WHILE_APP_VISIBLE,
    }

    private val preprocessor = ScreamPreprocessor()
    private val lifecycleLock = Any()
    private var interpreter: Interpreter? = null
    private var audioRecord: AudioRecord? = null
    private var workerThread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null

    @Volatile
    private var isRunning = false

    @Volatile
    private var isStartingOrRestarting = false

    private var captureState = CaptureState.NORMAL
    private var stuckReason = StuckReason.NONE
    private var needsForegroundRestore = false
    private var pendingNotificationRestoreRequest = false
    private var isManualRestartInProgress = false
    private var autoRecoveryAttempts = 0
    private val recoveryBackoffMs = longArrayOf(1000L, 3000L, 5000L)
    private var recoveryCandidateStartedAt = 0L
    private var recoveryFingerprintCount = 0
    private var lastRecoveryMeanAbs = 0.0
    private var isInitialStartup = true

    private val ring = FloatArray(ScreamPreprocessor.WINDOW_SAMPLES)
    private var ringIndex = 0
    private var samplesSeen = 0
    private val wavBuffer = FloatArray(ScreamPreprocessor.WINDOW_SAMPLES)
    private val logMelBuffer = FloatArray(ScreamPreprocessor.FRAMES * ScreamPreprocessor.N_MELS)
    private val inputBuffer: ByteBuffer = ByteBuffer
        .allocateDirect(4 * ScreamPreprocessor.FRAMES * ScreamPreprocessor.N_MELS)
        .order(ByteOrder.nativeOrder())
    private val outputBuffer = Array(1) { FloatArray(1) }

    private val hits90 = ArrayDeque<Long>()
    private val hits95 = ArrayDeque<Long>()
    private val hits100 = ArrayDeque<Long>()
    private val audioSources = intArrayOf(
        MediaRecorder.AudioSource.MIC,
    )
    private var audioSourceIndex = 0
    private var lastDanger = false

    @Volatile
    private var lastAudioAtMs: Long = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_MONITORING -> {
                Log.d(TAG, "Received STOP action")
                shutdownMonitoring()
            }
            ACTION_RESTORE_WHILE_VISIBLE -> {
                Log.d(TAG, "Received RESTORE_WHILE_VISIBLE action")
                restoreListeningWhenVisible()
            }
            ACTION_START -> {
                Log.d(TAG, "Received START action")
                startMonitoring()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        shutdownMonitoring(removeNotification = false, stopService = false)
        interpreter?.close()
        interpreter = null
        super.onDestroy()
    }

    private fun startMonitoring() {
        synchronized(lifecycleLock) {
            if (isRunning || isStartingOrRestarting) {
                Log.d(TAG, "startMonitoring ignored isRunning=$isRunning isStartingOrRestarting=$isStartingOrRestarting")
                return
            }
            isStartingOrRestarting = true
        }

        try {
            resetState()
            ensureInterpreter()
            acquireWakeLock()
            isRunning = true
            startInForeground()
            publishCurrentStatus(0.0, false)
            startWorkerThread()
        } finally {
            isStartingOrRestarting = false
        }
    }

    private fun startInForeground() {
        val notification = buildForegroundNotification()
        ServiceCompat.startForeground(
            this,
            ONGOING_NOTIFICATION_ID,
            notification,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                0
            },
        )
    }

    private fun shutdownMonitoring(
        removeNotification: Boolean = true,
        stopService: Boolean = true,
    ) {
        synchronized(lifecycleLock) {
            isStartingOrRestarting = true
        }
        try {
            isRunning = false
            stopWorkerThread(joinTimeoutMs = 1200L)
            releaseRecorder()
            releaseWakeLock()
            resetState()
            SafetyMonitorBridge.publish(MonitorStatus())

            if (removeNotification) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
            }
            if (stopService) {
                stopSelf()
            }
        } finally {
            isStartingOrRestarting = false
        }
    }

    private fun restoreListeningWhenVisible() {
        if (!isRunning || isManualRestartInProgress) return
        logStateTransition("Visible restore requested")
        hardRestartMonitoringSession()
    }

    private fun processAudioLoop() {
        var lastInferenceAt = 0L
        Log.d(TAG, "workerThread started name=${Thread.currentThread().name}")

        while (isRunning && !Thread.currentThread().isInterrupted) {
            if (captureState == CaptureState.STUCK && !isManualRestartInProgress) {
                sleepQuietly(500L)
                continue
            }

            resetAudioWindow()
            lastInferenceAt = 0L

            val recorder = createAndStartRecorder()
            if (recorder == null) {
                val continueTrying = handleCaptureInterrupted()
                if (!continueTrying) {
                    continue
                }
                sleepQuietly(currentRecoveryBackoff())
                continue
            }

            audioRecord = recorder
            val buffer = ShortArray(2048)
            var lastFingerprint: AudioFingerprint? = null
            var lastDistinctAudioAtMs = System.currentTimeMillis()
            val recorderStartedAt = System.currentTimeMillis()
            var startupInferenceReady = false

            try {
                while (isRunning && !Thread.currentThread().isInterrupted) {
                    val read = try {
                        recorder.read(buffer, 0, buffer.size)
                    } catch (e: Exception) {
                        Log.e(TAG, "AudioRecord.read() failed", e)
                        break
                    }
                    val now = System.currentTimeMillis()

                    if (read > 0) {
                        Log.d(TAG, "AudioRecord.read() -> $read")
                        lastAudioAtMs = now
                        val meanAbsAmplitude = meanAbsoluteAmplitude(buffer, read)
                        val fingerprint = fingerprint(buffer, read, meanAbsAmplitude)
                        val inStartupGrace = isInitialStartup && now - recorderStartedAt < STARTUP_GRACE_MS
                        if (lastFingerprint == null || lastFingerprint != fingerprint) {
                            lastFingerprint = fingerprint
                            lastDistinctAudioAtMs = now
                            if (captureState != CaptureState.NORMAL || isManualRestartInProgress) {
                                recoveryFingerprintCount += 1
                            }
                        } else if (now - lastDistinctAudioAtMs > STAGNANT_AUDIO_MS) {
                            val loudEnoughForStale = meanAbsAmplitude >= MIN_STALE_MEAN_ABS_AMPLITUDE
                            when {
                                inStartupGrace -> {
                                    Log.d(
                                        TAG,
                                        "Startup grace active; skipping stale detection elapsed=${now - recorderStartedAt} meanAbs=$meanAbsAmplitude fingerprint=$fingerprint",
                                    )
                                }
                                !loudEnoughForStale -> {
                                    Log.d(
                                        TAG,
                                        "Stale-audio false positive blocked due to low amplitude meanAbs=$meanAbsAmplitude elapsed=${now - lastDistinctAudioAtMs}",
                                    )
                                }
                                else -> {
                                    Log.w(
                                        TAG,
                                        "Audio fingerprint unchanged for ${now - lastDistinctAudioAtMs}ms meanAbs=$meanAbsAmplitude fingerprint=$fingerprint",
                                    )
                                    break
                                }
                            }
                        }
                        if (captureState != CaptureState.NORMAL || isManualRestartInProgress) {
                            lastRecoveryMeanAbs = meanAbsAmplitude
                            Log.d(
                                TAG,
                                "Recovery validation meanAbs=$meanAbsAmplitude distinctFingerprintCount=$recoveryFingerprintCount",
                            )
                        }

                        for (i in 0 until read) {
                            ring[ringIndex] = buffer[i] / 32768.0f
                            ringIndex = (ringIndex + 1) % ScreamPreprocessor.WINDOW_SAMPLES
                            samplesSeen += 1
                        }

                        if (!startupInferenceReady && samplesSeen >= ScreamPreprocessor.WINDOW_SAMPLES) {
                            startupInferenceReady = true
                            Log.d(TAG, "Initial startup now has a full inference window")
                        }

                        if (
                            (captureState == CaptureState.RECOVERING || isManualRestartInProgress) &&
                            samplesSeen >= ScreamPreprocessor.WINDOW_SAMPLES &&
                            recoveryFingerprintCount >= RECOVERY_DISTINCT_FINGERPRINTS &&
                            now - recoveryCandidateStartedAt >= RECOVERY_CONFIRM_MS &&
                            meanAbsAmplitude >= MIN_MEAN_ABS_AMPLITUDE &&
                            now - lastDistinctAudioAtMs < STAGNANT_AUDIO_MS
                        ) {
                            Log.d(
                                TAG,
                                "Recovery accepted after ${now - recorderStartedAt}ms meanAbs=$meanAbsAmplitude fingerprints=$recoveryFingerprintCount",
                            )
                            captureState = CaptureState.NORMAL
                            stuckReason = StuckReason.NONE
                            needsForegroundRestore = false
                            pendingNotificationRestoreRequest = false
                            isManualRestartInProgress = false
                            autoRecoveryAttempts = 0
                            recoveryCandidateStartedAt = 0L
                            recoveryFingerprintCount = 0
                            lastRecoveryMeanAbs = 0.0
                            logStateTransition("Foreground restore flags cleared after success")
                            updateForegroundNotification()
                            publishCurrentStatus(0.0, false)
                        } else if (captureState != CaptureState.NORMAL || isManualRestartInProgress) {
                            Log.d(
                                TAG,
                                "Recovery pending accepted=false meanAbs=$meanAbsAmplitude fingerprints=$recoveryFingerprintCount elapsed=${now - recorderStartedAt}",
                            )
                        }

                        if (
                            samplesSeen >= ScreamPreprocessor.WINDOW_SAMPLES &&
                            captureState == CaptureState.NORMAL &&
                            !isManualRestartInProgress &&
                            now - lastInferenceAt >= INFERENCE_INTERVAL_MS
                        ) {
                            if (isInitialStartup && now - recorderStartedAt < STARTUP_GRACE_MS) {
                                Log.d(TAG, "Initial startup grace phase active during inference elapsed=${now - recorderStartedAt}")
                            }
                            lastInferenceAt = now
                            val probability = try {
                                runInference()
                            } catch (e: Exception) {
                                Log.e(TAG, "Inference failed", e)
                                continue
                            }
                            if (isInitialStartup && startupInferenceReady && now - recorderStartedAt >= STARTUP_GRACE_MS) {
                                isInitialStartup = false
                                Log.d(TAG, "Initial startup grace phase complete; switching to steady-state monitoring")
                            }
                            updateRules(probability, now)
                        }
                    } else if (now - lastAudioAtMs > STAGNANT_AUDIO_MS) {
                        Log.w(TAG, "No audio samples for ${STAGNANT_AUDIO_MS}ms")
                        break
                    }
                }
            } finally {
                releaseRecorder()
            }

            if (!isRunning || Thread.currentThread().isInterrupted) {
                break
            }
            val continueTrying = handleCaptureInterrupted()
            if (continueTrying) {
                sleepQuietly(currentRecoveryBackoff())
            }
        }
        Log.d(TAG, "workerThread exiting name=${Thread.currentThread().name} isRunning=$isRunning interrupted=${Thread.currentThread().isInterrupted}")
    }

    private fun handleCaptureInterrupted(): Boolean {
        clearDetectionState()
        recoveryCandidateStartedAt = 0L
        recoveryFingerprintCount = 0
        lastRecoveryMeanAbs = 0.0

        return if (isManualRestartInProgress) {
            isManualRestartInProgress = false
            enterStuckState(fromManualRestart = true)
            false
        } else {
            autoRecoveryAttempts += 1
            if (autoRecoveryAttempts >= MAX_AUTO_RECOVERY_ATTEMPTS) {
                enterStuckState(fromManualRestart = false)
                false
            } else {
                captureState = CaptureState.RECOVERING
                stuckReason = StuckReason.NONE
                needsForegroundRestore = false
                pendingNotificationRestoreRequest = false
                if (!isInitialStartup) {
                    rotateAudioSource()
                } else {
                    Log.d(TAG, "Initial startup interruption path hit; keeping MIC source before any rotation")
                }
                recoveryCandidateStartedAt = System.currentTimeMillis()
                logStateTransition("Entering RECOVERING autoRecoveryAttempts=$autoRecoveryAttempts")
                updateForegroundNotification()
                publishCurrentStatus(0.0, false)
                true
            }
        }
    }

    private fun currentRecoveryBackoff(): Long {
        val index = (autoRecoveryAttempts - 1).coerceIn(0, recoveryBackoffMs.lastIndex)
        return recoveryBackoffMs[index]
    }

    private fun createAndStartRecorder(): AudioRecord? {
        val minBufferSize = AudioRecord.getMinBufferSize(
            ScreamPreprocessor.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufferSize = max(minBufferSize, 4096)

        for (offset in audioSources.indices) {
            val index = (audioSourceIndex + offset) % audioSources.size
            val source = audioSources[index]
            Log.d(TAG, "Trying audio source=$source index=$index")
            val recorder = try {
                AudioRecord(
                    source,
                    ScreamPreprocessor.SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufferSize,
                )
            } catch (e: Exception) {
                Log.e(TAG, "AudioRecord creation failed for source=$source", e)
                null
            } ?: continue

            Log.d(TAG, "AudioRecord.state=${recorder.state} source=$source")
            if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                recorder.release()
                continue
            }

            try {
                recorder.startRecording()
                Log.d(TAG, "AudioRecord.recordingState=${recorder.recordingState} source=$source")
                if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                    Log.w(TAG, "AudioRecord rejected because recordingState=${recorder.recordingState} source=$source")
                    recorder.release()
                    continue
                }
                audioSourceIndex = index
                lastAudioAtMs = System.currentTimeMillis()
                recoveryCandidateStartedAt = lastAudioAtMs
                recoveryFingerprintCount = 0
                lastRecoveryMeanAbs = 0.0
                Log.d(TAG, "SafetyMonitorService mic owner started source=$source")
                return recorder
            } catch (e: Exception) {
                Log.e(TAG, "AudioRecord start failed for source=$source", e)
                recorder.release()
            }
        }
        return null
    }

    private fun releaseRecorder() {
        try {
            if (audioRecord != null) {
                Log.d(TAG, "SafetyMonitorService mic owner stopping")
            }
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        audioRecord?.release()
        if (audioRecord != null) {
            Log.d(TAG, "SafetyMonitorService mic owner released")
        }
        audioRecord = null
    }

    private fun runInference(): Double {
        val localInterpreter = interpreter ?: return 0.0
        copyLatestWindow()
        preprocessor.computeLogMel(wavBuffer, logMelBuffer)
        inputBuffer.clear()
        for (value in logMelBuffer) {
            inputBuffer.putFloat(value)
        }
        inputBuffer.rewind()
        outputBuffer[0][0] = 0f
        localInterpreter.run(inputBuffer, outputBuffer)
        return outputBuffer[0][0].toDouble().coerceIn(0.0, 1.0)
    }

    private fun copyLatestWindow() {
        var idx = ringIndex
        for (i in wavBuffer.indices) {
            wavBuffer[i] = ring[idx]
            idx = (idx + 1) % ring.size
        }
    }

    private fun updateRules(probability: Double, nowMs: Long) {
        if (probability >= THRESHOLD) hits90.addLast(nowMs)
        if (probability >= HIGH_THRESHOLD) hits95.addLast(nowMs)
        if (probability >= PEAK_THRESHOLD) hits100.addLast(nowMs)

        pruneHits(hits90, nowMs, 4000L)
        pruneHits(hits95, nowMs, 2000L)
        pruneHits(hits100, nowMs, 1000L)

        val danger = hits90.size >= 4 || hits95.size >= 2 || hits100.isNotEmpty()
        publishCurrentStatus(probability, danger)

        if (danger && !lastDanger) {
            handleDangerDetected()
            return
        }
        lastDanger = danger
    }

    private fun handleDangerDetected() {
        SafetyMonitorBridge.publish(
            MonitorStatus(
                running = false,
                probability = 0.0,
                danger = true,
                degraded = false,
                stuck = false,
                needsForegroundRestore = false,
                hits90In4s = hits90.size,
                hits95In2s = hits95.size,
                hits100In1s = hits100.size,
            ),
        )
        shutdownMonitoring()
        // TODO: hand off to the emergency flow here.
    }

    private fun publishCurrentStatus(probability: Double, danger: Boolean) {
        SafetyMonitorBridge.publish(
            MonitorStatus(
                running = true,
                probability = probability,
                danger = danger,
                degraded = captureState != CaptureState.NORMAL,
                stuck = captureState == CaptureState.STUCK,
                needsForegroundRestore = needsForegroundRestore,
                hits90In4s = hits90.size,
                hits95In2s = hits95.size,
                hits100In1s = hits100.size,
            ),
        )
    }

    private fun clearDetectionState() {
        hits90.clear()
        hits95.clear()
        hits100.clear()
        lastDanger = false
    }

    private fun resetState() {
        clearDetectionState()
        resetAudioWindow()
        captureState = CaptureState.NORMAL
        stuckReason = StuckReason.NONE
        needsForegroundRestore = false
        pendingNotificationRestoreRequest = false
        isManualRestartInProgress = false
        autoRecoveryAttempts = 0
        audioSourceIndex = 0
        recoveryCandidateStartedAt = 0L
        recoveryFingerprintCount = 0
        lastRecoveryMeanAbs = 0.0
        lastAudioAtMs = System.currentTimeMillis()
        isInitialStartup = true
    }

    private fun pruneHits(queue: ArrayDeque<Long>, nowMs: Long, windowMs: Long) {
        while (queue.isNotEmpty() && nowMs - queue.first() > windowMs) {
            queue.removeFirst()
        }
    }

    private fun resetAudioWindow() {
        ring.fill(0f)
        wavBuffer.fill(0f)
        logMelBuffer.fill(0f)
        ringIndex = 0
        samplesSeen = 0
        lastAudioAtMs = 0L
    }

    private data class AudioFingerprint(
        val coarseHash: Int,
        val energyBucket: Int,
        val zeroCrossingBucket: Int,
    )

    private fun fingerprint(buffer: ShortArray, read: Int, meanAbsAmplitude: Double): AudioFingerprint {
        var result = 17
        var zeroCrossings = 0
        var previousSign = 0
        for (i in 0 until read step 32) {
            val sample = buffer[i].toInt()
            result = 31 * result + sample
            val sign = sample.compareTo(0)
            if (previousSign != 0 && sign != 0 && sign != previousSign) {
                zeroCrossings += 1
            }
            if (sign != 0) {
                previousSign = sign
            }
        }
        result = 31 * result + read
        val energyBucket = (meanAbsAmplitude * 1000).toInt()
        val zeroCrossingBucket = zeroCrossings / 2
        return AudioFingerprint(result, energyBucket, zeroCrossingBucket)
    }

    private fun rotateAudioSource() {
        audioSourceIndex = (audioSourceIndex + 1) % audioSources.size
        Log.d(TAG, "Rotated audio source to index=$audioSourceIndex source=${audioSources[audioSourceIndex]}")
    }

    private fun sleepQuietly(durationMs: Long) {
        try {
            Thread.sleep(durationMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun ensureInterpreter() {
        if (interpreter != null) return
        FlutterInjector.instance().flutterLoader().ensureInitializationComplete(applicationContext, null)
        interpreter = Interpreter(loadModelFile())
    }

    private fun loadModelFile(): ByteBuffer {
        val assetPath = "flutter_assets/assets/models/scream_logmel_best.tflite"
        return try {
            assets.openFd(assetPath).use { afd ->
                FileInputStream(afd.fileDescriptor).channel.use { channel ->
                    channel.map(
                        FileChannel.MapMode.READ_ONLY,
                        afd.startOffset,
                        afd.declaredLength,
                    )
                }
            }
        } catch (_: Exception) {
            val outFile = File(cacheDir, "scream_logmel_best.tflite")
            if (!outFile.exists()) {
                assets.open(assetPath).use { input ->
                    FileOutputStream(outFile).use { output ->
                        input.copyTo(output)
                    }
                }
            }
            FileInputStream(outFile).channel.use { channel ->
                channel.map(
                    FileChannel.MapMode.READ_ONLY,
                    0,
                    outFile.length(),
                )
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(
            NotificationChannel(
                MONITOR_CHANNEL_ID,
                "USafe Monitoring",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "twilio_demo:SafetyMonitorWakeLock",
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    private fun buildForegroundNotification(): Notification {
        val title = when (captureState) {
            CaptureState.NORMAL -> "USafe is listening in the background"
            CaptureState.RECOVERING -> "Listening paused"
            CaptureState.STUCK -> "Listening paused"
        }
        val text = when (captureState) {
            CaptureState.NORMAL -> "Surrounding audio monitoring is active."
            CaptureState.RECOVERING -> "Trying to recover audio access in the background."
            CaptureState.STUCK -> when (stuckReason) {
                StuckReason.WHILE_APP_VISIBLE -> "Audio access was interrupted. Restore listening from the app."
                else -> "Audio access was interrupted. Open USafe to restore listening."
            }
        }

        return NotificationCompat.Builder(this, MONITOR_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .apply {
                if (captureState == CaptureState.STUCK && needsForegroundRestore) {
                    addAction(
                        android.R.drawable.ic_menu_view,
                        "Open USafe",
                        buildOpenAppPendingIntent(),
                    )
                }
                addAction(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Stop",
                    buildStopPendingIntent(),
                )
            }
            .build()
    }

    private fun updateForegroundNotification() {
        if (!isRunning) return
        NotificationManagerCompat.from(this)
            .notify(ONGOING_NOTIFICATION_ID, buildForegroundNotification())
    }

    private fun stopWorkerThread(joinTimeoutMs: Long) {
        val thread = workerThread ?: return
        Log.d(TAG, "Stopping worker thread name=${thread.name}")
        thread.interrupt()
        try {
            thread.join(joinTimeoutMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        Log.d(TAG, "Worker thread joined alive=${thread.isAlive} name=${thread.name}")
        if (workerThread === thread) {
            workerThread = null
        }
    }

    private fun hardRestartMonitoringSession() {
        synchronized(lifecycleLock) {
            if (isStartingOrRestarting) {
                Log.d(TAG, "hardRestartMonitoringSession ignored because another start/restart is in progress")
                return
            }
            isStartingOrRestarting = true
        }
        Log.d(TAG, "hardRestartMonitoringSession begin")
        try {
            isRunning = false
            stopWorkerThread(joinTimeoutMs = 1500L)
            releaseRecorder()

            captureState = CaptureState.NORMAL
            stuckReason = StuckReason.NONE
            needsForegroundRestore = false
            pendingNotificationRestoreRequest = false
            isManualRestartInProgress = false
            autoRecoveryAttempts = 0
            lastDanger = false
            clearDetectionState()
            resetAudioWindow()
            audioSourceIndex = 0
            recoveryCandidateStartedAt = 0L
            recoveryFingerprintCount = 0
            lastRecoveryMeanAbs = 0.0
            lastAudioAtMs = System.currentTimeMillis()
            SafetyMonitorBridge.publish(MonitorStatus(running = false))

            isRunning = true
            captureState = CaptureState.RECOVERING
            isManualRestartInProgress = true
            updateForegroundNotification()
            publishCurrentStatus(0.0, false)
            startWorkerThread()
            logStateTransition("hardRestartMonitoringSession end")
        } finally {
            isStartingOrRestarting = false
        }
    }

    private fun startWorkerThread() {
        val thread = Thread {
            processAudioLoop()
        }.apply {
            name = "USafeAudioMonitor-${System.currentTimeMillis()}"
        }
        workerThread = thread
        Log.d(TAG, "Starting worker thread name=${thread.name}")
        thread.start()
    }

    private fun meanAbsoluteAmplitude(buffer: ShortArray, read: Int): Double {
        if (read <= 0) return 0.0
        var sum = 0.0
        for (i in 0 until read) {
            sum += kotlin.math.abs(buffer[i].toInt()) / 32768.0
        }
        return sum / read
    }

    private fun enterStuckState(fromManualRestart: Boolean) {
        captureState = CaptureState.STUCK
        if (AppVisibilityTracker.isAppInForeground) {
            stuckReason = StuckReason.WHILE_APP_VISIBLE
            needsForegroundRestore = false
            pendingNotificationRestoreRequest = false
            logStateTransition(
                "App foreground=true, audio interrupted, entering STUCK_WHILE_APP_VISIBLE fromManualRestart=$fromManualRestart",
            )
        } else {
            stuckReason = StuckReason.BACKGROUND_RESTORE_REQUIRED
            needsForegroundRestore = true
            logStateTransition(
                "App foreground=false, audio interrupted, entering STUCK_BACKGROUND_RESTORE_REQUIRED fromManualRestart=$fromManualRestart",
            )
        }
        updateForegroundNotification()
        publishCurrentStatus(0.0, false)
    }

    private fun logStateTransition(message: String) {
        Log.d(
            TAG,
            "$message foreground=${AppVisibilityTracker.isAppInForeground} " +
                "needsForegroundRestore=$needsForegroundRestore " +
                "pendingNotificationRestoreRequest=$pendingNotificationRestoreRequest " +
                "isStuck=${captureState == CaptureState.STUCK} " +
                "stuckReason=$stuckReason",
        )
    }

    private fun buildOpenAppPendingIntent(): PendingIntent {
        pendingNotificationRestoreRequest = true
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_RESTORE_LISTENING, true)
        }
        return PendingIntent.getActivity(
            this,
            1,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildStopPendingIntent(): PendingIntent {
        val intent = Intent(this, SafetyMonitorService::class.java).apply {
            action = ACTION_STOP_MONITORING
        }
        return PendingIntent.getService(
            this,
            2,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
