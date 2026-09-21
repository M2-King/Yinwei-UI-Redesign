package dev.yinwei.yinwei_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Owns MediaProjection + AudioRecord for the A1 capture-only probe.
 * Does not play, spatialize, or persist captured PCM.
 */
class YinweiPlaybackCaptureService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val running = java.util.concurrent.atomic.AtomicBoolean(false)
    private var projection: MediaProjection? = null
    private var recorder: AudioRecord? = null
    private var captureThread: Thread? = null
    private var chosenEncoding = "PCM_16BIT"
    private var chosenRate = 48000
    private var chosenChannels = 2

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            YinweiPlaybackCaptureStore.update {
                projectionRevoked = true
                lastError = "projection revoked"
                captureActive = false
            }
            YinweiPlaybackCaptureStore.log("LIFECYCLE", "projection revoked")
            stopCaptureInternal(fromRevoke = true)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCaptureInternal(fromRevoke = false)
                return START_NOT_STICKY
            }
            ACTION_START -> startSession(intent)
            else -> startSession(intent)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopCaptureInternal(fromRevoke = false)
        super.onDestroy()
    }

    private fun startSession(intent: Intent?) {
        if (Build.VERSION.SDK_INT < 29) {
            YinweiPlaybackCaptureStore.update {
                supported = false
                lastError = "AudioPlaybackCapture requires Android 10 / API 29+"
            }
            stopSelf()
            return
        }
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, pendingResultCode)
            ?: pendingResultCode
        val data = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java) ?: pendingResultData
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(EXTRA_RESULT_DATA) ?: pendingResultData
        }
        if (resultCode == 0 || data == null) {
            YinweiPlaybackCaptureStore.update {
                lastError = "missing MediaProjection result"
                permissionPending = false
            }
            stopSelf()
            return
        }
        pendingResultCode = 0
        pendingResultData = null
        if (!startCaptureNotification()) {
            return
        }
        try {
            val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val obtained = mgr.getMediaProjection(resultCode, data)
            if (obtained == null) {
                failAndStop("MediaProjection token rejected")
                return
            }
            projection = obtained
            obtained.registerCallback(projectionCallback, mainHandler)
            YinweiPlaybackCaptureStore.update {
                projectionGranted = true
                projectionRevoked = false
                permissionPending = false
                permissionCancelled = false
                permissionDenied = false
                lastError = null
                foregroundServiceRunning = true
            }
            YinweiPlaybackCaptureStore.log("PROJECTION", "MediaProjection granted")
            if (Build.VERSION.SDK_INT >= 29) {
                startAudioRecord(obtained)
            }
        } catch (e: Exception) {
            failAndStop("MediaProjection start failed: ${e.message}")
        }
    }

    private fun startCaptureNotification(): Boolean {
        return try {
            ensureChannel()
            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Yinwei Live Transfer")
                .setContentText("Capturing device playback audio")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .build()
            val type = if (Build.VERSION.SDK_INT >= 29) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            } else {
                0
            }
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
            YinweiPlaybackCaptureStore.update { foregroundServiceRunning = true }
            YinweiPlaybackCaptureStore.log("LIFECYCLE", "foreground service started")
            true
        } catch (e: Exception) {
            failAndStop("foreground service failed: ${e.message}")
            false
        }
    }

    @RequiresApi(29)
    private fun startAudioRecord(mediaProjection: MediaProjection) {
        if (Build.VERSION.SDK_INT < 29) return
        val format = chooseFormat()
        if (format == null) {
            failAndStop("AudioRecord.getMinBufferSize rejected PCM_FLOAT and PCM_16BIT")
            return
        }
        val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val audioFormat = AudioFormat.Builder()
            .setEncoding(format.encoding)
            .setSampleRate(format.sampleRate)
            .setChannelMask(format.channelMask)
            .build()
        val bufferBytes = format.minBuffer * 2
        val record = try {
            AudioRecord.Builder()
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(bufferBytes)
                .setAudioPlaybackCaptureConfig(config)
                .build()
        } catch (e: Exception) {
            failAndStop("AudioRecord.Builder failed: ${e.message}")
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            failAndStop("AudioRecord not initialized")
            return
        }
        recorder = record
        chosenEncoding = encodingName(record.audioFormat)
        chosenRate = record.sampleRate
        chosenChannels = record.channelCount.coerceAtLeast(1)
        YinweiPlaybackCaptureStore.update {
            playbackCaptureConfigured = true
            audioRecordState = "INITIALIZED"
            sampleRate = chosenRate
            channelCount = chosenChannels
            encoding = chosenEncoding
            audioRecordSource = "PLAYBACK_CAPTURE"
            lastError = null
        }
        YinweiPlaybackCaptureStore.log(
            "CAPTURE",
            "AudioRecord initialized source=PLAYBACK_CAPTURE rate=$chosenRate " +
                "channels=$chosenChannels encoding=$chosenEncoding",
        )
        try {
            record.startRecording()
        } catch (e: Exception) {
            failAndStop("AudioRecord.startRecording failed: ${e.message}")
            return
        }
        YinweiPlaybackCaptureStore.update {
            audioRecordState = "RECORDING"
            captureActive = true
        }
        running.set(true)
        val thread = Thread({ captureLoop(record) }, "yinwei-playback-capture")
        captureThread = thread
        thread.start()
    }

    private fun captureLoop(record: AudioRecord) {
        val floatBuf = FloatArray(record.channelCount.coerceAtLeast(1) * 2048)
        val shortBuf = ShortArray(record.channelCount.coerceAtLeast(1) * 2048)
        val useFloat = record.audioFormat == AudioFormat.ENCODING_PCM_FLOAT
        var windowSamples = 0
        var windowSumSq = 0.0
        var windowPeak = 0.0
        var lastLogAt = 0L
        while (running.get()) {
            val n = try {
                if (useFloat) {
                    record.read(floatBuf, 0, floatBuf.size, AudioRecord.READ_BLOCKING)
                } else {
                    record.read(shortBuf, 0, shortBuf.size)
                }
            } catch (e: Exception) {
                YinweiPlaybackCaptureStore.update {
                    lastError = "AudioRecord.read failed: ${e.message}"
                    audioRecordState = "ERROR"
                }
                break
            }
            when {
                n == AudioRecord.ERROR_DEAD_OBJECT ||
                    n == AudioRecord.ERROR_INVALID_OPERATION ||
                    n == AudioRecord.ERROR_BAD_VALUE -> {
                    YinweiPlaybackCaptureStore.update {
                        lastError = "AudioRecord read error $n"
                        audioRecordState = "ERROR"
                    }
                    YinweiPlaybackCaptureStore.log("CAPTURE", "AudioRecord error code=$n")
                    break
                }
                n <= 0 -> {
                    YinweiPlaybackCaptureStore.update { lastReadFrames = 0 }
                }
                else -> {
                    val metrics = if (useFloat) {
                        YinweiPlaybackCaptureMetrics.fromPcmFloat(floatBuf, n)
                    } else {
                        YinweiPlaybackCaptureMetrics.fromPcm16(shortBuf, n)
                    }
                    val frames = n / chosenChannels.coerceAtLeast(1)
                    val now = System.currentTimeMillis()
                    windowSamples += n
                    windowSumSq += metrics.rms * metrics.rms * n
                    if (metrics.peak > windowPeak) windowPeak = metrics.peak
                    YinweiPlaybackCaptureStore.update {
                        readCount += 1
                        capturedFrames += frames
                        capturedSamples += n
                        lastReadFrames = frames
                        if (!metrics.silent) {
                            lastNonSilentAtMs = now
                            sourceCaptureRestricted = false
                        }
                    }
                    if (now - lastLogAt >= 1000L) {
                        val windowRms = if (windowSamples > 0) {
                            kotlin.math.sqrt(windowSumSq / windowSamples)
                        } else {
                            0.0
                        }
                        val window = YinweiPlaybackCaptureMetrics.Result(
                            rms = windowRms,
                            peak = windowPeak,
                            rmsDb = YinweiPlaybackCaptureMetrics.toDbFs(windowRms),
                            peakDb = YinweiPlaybackCaptureMetrics.toDbFs(windowPeak),
                            silent = windowRms < YinweiPlaybackCaptureMetrics.SILENCE_LINEAR,
                        )
                        publishWindow(window, now)
                        windowSamples = 0
                        windowSumSq = 0.0
                        windowPeak = 0.0
                        lastLogAt = now
                    }
                }
            }
        }
        running.set(false)
    }

    private fun publishWindow(metrics: YinweiPlaybackCaptureMetrics.Result, now: Long) {
        val snap = YinweiPlaybackCaptureStore.copy()
        val silentNow = metrics.silent
        val restricted = silentNow &&
            snap.readCount > 0 &&
            (snap.lastNonSilentAtMs == null || now - (snap.lastNonSilentAtMs ?: now) >= 3000L) &&
            (snap.sampleRate ?: 0) > 0 &&
            snap.capturedFrames >= (snap.sampleRate ?: 0) * 3
        val receiving = snap.readCount > 0 && !silentNow
        val state = YinweiPlaybackCaptureMetrics.dataState(snap.readCount, silentNow)
        YinweiPlaybackCaptureStore.update {
            rmsDb = metrics.rmsDb
            peakDb = metrics.peakDb
            silent = silentNow
            receivingPlaybackAudio = receiving
            sourceCaptureRestricted = restricted
        }
        YinweiPlaybackCaptureStore.log(
            "CAPTURE",
            YinweiPlaybackCaptureMetrics.logLine(
                readCount = snap.readCount,
                capturedFrames = snap.capturedFrames,
                sampleRate = snap.sampleRate ?: chosenRate,
                channelCount = snap.channelCount ?: chosenChannels,
                encoding = snap.encoding ?: chosenEncoding,
                rmsDb = metrics.rmsDb,
                peakDb = metrics.peakDb,
                dataState = state,
            ),
        )
    }

    private fun failAndStop(message: String) {
        YinweiPlaybackCaptureStore.update {
            lastError = message
            captureActive = false
            permissionPending = false
        }
        YinweiPlaybackCaptureStore.log("LIFECYCLE", message)
        stopCaptureInternal(fromRevoke = false)
    }

    private fun stopCaptureInternal(fromRevoke: Boolean) {
        running.set(false)
        captureThread?.interrupt()
        captureThread = null
        val rec = recorder
        recorder = null
        if (rec != null) {
            try {
                rec.stop()
            } catch (_: Exception) {
            }
            try {
                rec.release()
            } catch (_: Exception) {
            }
        }
        val proj = projection
        projection = null
        if (proj != null) {
            try {
                proj.unregisterCallback(projectionCallback)
            } catch (_: Exception) {
            }
            try {
                if (!fromRevoke) proj.stop()
            } catch (_: Exception) {
            }
        }
        YinweiPlaybackCaptureStore.update {
            captureActive = false
            audioRecordState = "STOPPED"
            foregroundServiceRunning = false
            playbackCaptureConfigured = false
            receivingPlaybackAudio = false
        }
        YinweiPlaybackCaptureStore.log("LIFECYCLE", "capture service stopped")
        try {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
        stopSelf()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Yinwei Live Transfer",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Shows when Yinwei is capturing device playback audio"
                setShowBadge(false)
            },
        )
    }

    private data class ChosenFormat(
        val sampleRate: Int,
        val channelMask: Int,
        val encoding: Int,
        val minBuffer: Int,
    )

    private fun chooseFormat(): ChosenFormat? {
        val attempts = listOf(
            Triple(48000, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_FLOAT),
            Triple(48000, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT),
            Triple(44100, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT),
        )
        for ((rate, mask, encoding) in attempts) {
            val min = AudioRecord.getMinBufferSize(rate, mask, encoding)
            if (min > 0) {
                return ChosenFormat(rate, mask, encoding, min)
            }
        }
        return null
    }

    private fun encodingName(encoding: Int): String = when (encoding) {
        AudioFormat.ENCODING_PCM_FLOAT -> "PCM_FLOAT"
        AudioFormat.ENCODING_PCM_16BIT -> "PCM_16BIT"
        else -> "UNKNOWN($encoding)"
    }

    companion object {
        const val ACTION_START = "dev.yinwei.action.START_PLAYBACK_CAPTURE"
        const val ACTION_STOP = "dev.yinwei.action.STOP_PLAYBACK_CAPTURE"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val CHANNEL_ID = "yinwei_live_transfer"
        const val NOTIFICATION_ID = 0x594E57

        @Volatile
        var pendingResultCode: Int = 0

        @Volatile
        var pendingResultData: Intent? = null

        fun start(context: Context, resultCode: Int, data: Intent) {
            pendingResultCode = resultCode
            pendingResultData = data
            val intent = Intent(context, YinweiPlaybackCaptureService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, data)
            }
            try {
                androidx.core.content.ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                pendingResultCode = 0
                pendingResultData = null
                val message = "startForegroundService failed: ${e.message}"
                YinweiPlaybackCaptureStore.update {
                    lastError = message
                    permissionPending = false
                    captureActive = false
                    captureHint = message
                }
                YinweiPlaybackCaptureStore.log("LIFECYCLE", message)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, YinweiPlaybackCaptureService::class.java))
        }
    }
}
