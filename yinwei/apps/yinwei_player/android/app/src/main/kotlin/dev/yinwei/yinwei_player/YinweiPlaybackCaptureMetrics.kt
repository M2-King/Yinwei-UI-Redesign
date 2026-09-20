package dev.yinwei.yinwei_player

import kotlin.math.ln
import kotlin.math.sqrt

/** PCM diagnostics for AudioPlaybackCapture. Never stores raw music. */
object YinweiPlaybackCaptureMetrics {
    const val SILENCE_LINEAR = 1e-4

    data class Result(
        val rms: Double,
        val peak: Double,
        val rmsDb: Double?,
        val peakDb: Double?,
        val silent: Boolean,
    )

    fun fromPcm16(samples: ShortArray, count: Int): Result {
        var sumSq = 0.0
        var peak = 0.0
        val n = count.coerceIn(0, samples.size)
        for (i in 0 until n) {
            val v = samples[i].toDouble() / 32768.0
            val abs = kotlin.math.abs(v)
            if (abs > peak) peak = abs
            sumSq += v * v
        }
        return fromRmsPeak(sumSq, peak, n)
    }

    fun fromPcmFloat(samples: FloatArray, count: Int): Result {
        var sumSq = 0.0
        var peak = 0.0
        val n = count.coerceIn(0, samples.size)
        for (i in 0 until n) {
            val v = samples[i].toDouble()
            val abs = kotlin.math.abs(v)
            if (abs > peak) peak = abs
            sumSq += v * v
        }
        return fromRmsPeak(sumSq, peak, n)
    }

    fun toDbFs(linear: Double): Double? {
        if (linear <= 0.0) return null
        return 20.0 * ln(linear) / LN10
    }

    fun dataState(readCount: Long, silent: Boolean): String {
        if (readCount <= 0L) return "NO_AUDIO_DATA"
        return if (silent) "SILENT" else "NON_SILENT"
    }

    fun logLine(
        readCount: Long,
        capturedFrames: Long,
        sampleRate: Int,
        channelCount: Int,
        encoding: String,
        rmsDb: Double?,
        peakDb: Double?,
        dataState: String,
    ): String {
        val prefix = "[YINWEI_ANDROID_CAPTURE]"
        return when (dataState) {
            "NO_AUDIO_DATA" -> "$prefix state=NO_AUDIO_DATA"
            "SILENT" -> "$prefix reads=$readCount frames=$capturedFrames rms=-inf state=SILENT"
            else ->
                "$prefix reads=$readCount frames=$capturedFrames rate=$sampleRate " +
                    "channels=$channelCount encoding=$encoding rms=${formatDb(rmsDb)}dBFS " +
                    "peak=${formatDb(peakDb)}dBFS"
        }
    }

    private fun fromRmsPeak(sumSq: Double, peak: Double, count: Int): Result {
        if (count <= 0) {
            return Result(0.0, 0.0, null, null, true)
        }
        val rms = sqrt(sumSq / count)
        return Result(
            rms = rms,
            peak = peak,
            rmsDb = toDbFs(rms),
            peakDb = toDbFs(peak),
            silent = rms < SILENCE_LINEAR,
        )
    }

    private fun formatDb(db: Double?): String =
        if (db == null) "-inf" else String.format("%.1f", db)

    private val LN10 = ln(10.0)
}
