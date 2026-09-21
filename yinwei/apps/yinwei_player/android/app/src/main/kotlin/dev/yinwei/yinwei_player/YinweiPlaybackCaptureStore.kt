package dev.yinwei.yinwei_player

import android.os.Build
import java.util.ArrayDeque

/**
 * Process-wide capture session snapshot. AudioPlaybackCapture PCM is measured
 * and discarded; raw music samples are never stored.
 */
object YinweiPlaybackCaptureStore {
    const val LOG_CAPACITY = 300

    data class Snapshot(
        var supported: Boolean = Build.VERSION.SDK_INT >= 29,
        var androidSdk: Int = Build.VERSION.SDK_INT,
        var projectionGranted: Boolean = false,
        var captureActive: Boolean = false,
        var foregroundServiceRunning: Boolean = false,
        var audioRecordState: String = "UNINITIALIZED",
        var readCount: Long = 0,
        var capturedFrames: Long = 0,
        var capturedSamples: Long = 0,
        var lastReadFrames: Int = 0,
        var sampleRate: Int? = null,
        var channelCount: Int? = null,
        var encoding: String? = null,
        var rmsDb: Double? = null,
        var peakDb: Double? = null,
        var silent: Boolean = false,
        var receivingPlaybackAudio: Boolean = false,
        var lastError: String? = null,
        var permissionPending: Boolean = false,
        var permissionDenied: Boolean = false,
        var permissionCancelled: Boolean = false,
        var projectionRevoked: Boolean = false,
        var sourceCaptureRestricted: Boolean = false,
        var playbackCaptureConfigured: Boolean = false,
        var audioRecordSource: String = "PLAYBACK_CAPTURE",
        var audioUsages: List<String> = listOf("USAGE_MEDIA", "USAGE_GAME", "USAGE_UNKNOWN"),
        var appForeground: Boolean = true,
        var lastNonSilentAtMs: Long? = null,
        var captureHint: String? = null,
        var manufacturer: String = Build.MANUFACTURER ?: "unknown",
        var model: String = Build.MODEL ?: "unknown",
        var androidVersion: String = Build.VERSION.RELEASE ?: "unknown",
    )

    data class LogEntry(
        val ts: Double,
        val iso: String,
        val category: String,
        val message: String,
    )

    private val lock = Any()
    private val snapshot = Snapshot()
    private val log = ArrayDeque<LogEntry>()

    fun copy(): Snapshot = synchronized(lock) { snapshot.copy() }

    fun update(block: Snapshot.() -> Unit) {
        synchronized(lock) { snapshot.block() }
    }

    fun log(category: String, message: String) {
        val now = System.currentTimeMillis()
        val entry = LogEntry(
            ts = now / 1000.0,
            iso = iso(now),
            category = category,
            message = message,
        )
        synchronized(lock) {
            log.addLast(entry)
            while (log.size > LOG_CAPACITY) {
                log.removeFirst()
            }
        }
        android.util.Log.i("YINWEI_$category", message)
    }

    fun logLines(): List<Map<String, Any>> = synchronized(lock) {
        log.map {
            mapOf(
                "ts" to it.ts,
                "iso" to it.iso,
                "category" to it.category,
                "message" to it.message,
            )
        }
    }

    fun resetSession() {
        update {
            projectionGranted = false
            captureActive = false
            foregroundServiceRunning = false
            audioRecordState = "UNINITIALIZED"
            readCount = 0
            capturedFrames = 0
            capturedSamples = 0
            lastReadFrames = 0
            sampleRate = null
            channelCount = null
            encoding = null
            rmsDb = null
            peakDb = null
            silent = false
            receivingPlaybackAudio = false
            playbackCaptureConfigured = false
            sourceCaptureRestricted = false
            lastNonSilentAtMs = null
            projectionRevoked = false
            captureHint = null
        }
    }

    fun asStatusMap(): Map<String, Any?> {
        val s = copy()
        val map = linkedMapOf<String, Any?>(
            "supported" to s.supported,
            "androidSdk" to s.androidSdk,
            "projectionGranted" to s.projectionGranted,
            "captureActive" to s.captureActive,
            "foregroundServiceRunning" to s.foregroundServiceRunning,
            "audioRecordState" to s.audioRecordState,
            "readCount" to s.readCount,
            "capturedFrames" to s.capturedFrames,
            "capturedSamples" to s.capturedSamples,
            "lastReadFrames" to s.lastReadFrames,
            "silent" to s.silent,
            "receivingPlaybackAudio" to s.receivingPlaybackAudio,
            "permissionPending" to s.permissionPending,
            "permissionDenied" to s.permissionDenied,
            "permissionCancelled" to s.permissionCancelled,
            "projectionRevoked" to s.projectionRevoked,
            "sourceCaptureRestricted" to s.sourceCaptureRestricted,
            "playbackCaptureConfigured" to s.playbackCaptureConfigured,
            "audioRecordSource" to s.audioRecordSource,
            "audioUsages" to s.audioUsages,
            "appForeground" to s.appForeground,
        )
        s.sampleRate?.let { map["sampleRate"] = it }
        s.channelCount?.let { map["channelCount"] = it }
        s.encoding?.let { map["encoding"] = it }
        s.rmsDb?.let { map["rmsDb"] = it }
        s.peakDb?.let { map["peakDb"] = it }
        s.lastError?.let { if (it.isNotEmpty()) map["lastError"] = it }
        s.captureHint?.let { if (it.isNotEmpty()) map["captureHint"] = it }
        s.lastNonSilentAtMs?.let { map["lastNonSilentAtMs"] = it }
        return map
    }

    private fun iso(ms: Long): String {
        val sdf = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US)
        sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return sdf.format(java.util.Date(ms))
    }
}
