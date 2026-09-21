package dev.yinwei.yinwei_player

/**
 * JNI load of libspatial_core.so for Android A2 live ingress.
 *
 * Independent of Flutter's file-engine NativeLibraryLocator (which stays
 * androidUnavailable / MockEngine). Raw PCM never crosses MethodChannel.
 */
object YinweiSpatialCoreBridge {
    const val OK = 0
    const val ERR_NOT_LOADED = -1
    const val ERR_INVALID = -2
    const val ERR_NOT_STARTED = -3
    const val ERR_FAILED = -4

    @Volatile
    var libraryLoaded: Boolean = false
        private set

    @Volatile
    var loadError: String? = null
        private set

    init {
        try {
            System.loadLibrary("spatial_core")
            libraryLoaded = true
            loadError = null
        } catch (e: UnsatisfiedLinkError) {
            libraryLoaded = false
            loadError = e.message ?: "libspatial_core.so not found"
        } catch (e: SecurityException) {
            libraryLoaded = false
            loadError = e.message ?: "libspatial_core.so blocked"
        }
    }

    fun start(sampleRate: Int, channelCount: Int): Int {
        if (!libraryLoaded) return ERR_NOT_LOADED
        return try {
            nativeStart(sampleRate, channelCount)
        } catch (e: Throwable) {
            loadError = e.message ?: "nativeStart failed"
            ERR_FAILED
        }
    }

    fun stop(): Int {
        if (!libraryLoaded) return ERR_NOT_LOADED
        return try {
            nativeStop()
        } catch (e: Throwable) {
            ERR_FAILED
        }
    }

    fun pushFloat(samples: FloatArray, count: Int): Int {
        if (!libraryLoaded) return ERR_NOT_LOADED
        val n = count.coerceAtMost(samples.size)
        if (n <= 0) return OK
        return try {
            nativePushFloat(samples, n)
        } catch (_: Throwable) {
            ERR_FAILED
        }
    }

    fun pushPcm16(samples: ShortArray, count: Int): Int {
        if (!libraryLoaded) return ERR_NOT_LOADED
        val n = count.coerceAtMost(samples.size)
        if (n <= 0) return OK
        return try {
            nativePushPcm16(samples, n)
        } catch (_: Throwable) {
            ERR_FAILED
        }
    }

    fun snapshot(): Map<String, Any?> {
        if (!libraryLoaded) {
            return mapOf(
                "dspLibraryLoaded" to false,
                "dspState" to "Error",
                "nativeInputFrames" to 0L,
                "nativeConsumedFrames" to 0L,
                "nativeDspChunks" to 0L,
                "nativeWetFrames" to 0L,
                "nativeDroppedFrames" to 0L,
                "nativeOverruns" to 0L,
                "nativeQueueDepthFrames" to 0L,
                "nativeQueueHighWaterFrames" to 0L,
                "nativeLastError" to (loadError ?: "libspatial_core.so not loaded"),
                "nativeWetRmsDb" to null,
                "nativeWetPeakDb" to null,
                "nativeEffectiveAzimuthDeg" to null,
                "nativeEffectiveElevationDeg" to null,
            )
        }
        return try {
            val state = nativeDspState()
            val err = nativeLastError().ifEmpty { null }
            val chunks = nativeDspChunks()
            val wetRms = nativeWetRmsDb()
            val wetPeak = nativeWetPeakDb()
            mapOf(
                "dspLibraryLoaded" to true,
                "dspState" to state,
                "nativeInputFrames" to nativeInputFrames(),
                "nativeConsumedFrames" to nativeConsumedFrames(),
                "nativeDspChunks" to chunks,
                "nativeWetFrames" to nativeWetFrames(),
                "nativeDroppedFrames" to nativeDroppedFrames(),
                "nativeOverruns" to nativeOverruns(),
                "nativeQueueDepthFrames" to nativeQueueDepthFrames(),
                "nativeQueueHighWaterFrames" to nativeQueueHighWaterFrames(),
                "nativeLastError" to err,
                "nativeWetRmsDb" to if (chunks > 0 && wetRms.isFinite()) wetRms else null,
                "nativeWetPeakDb" to if (chunks > 0 && wetPeak.isFinite()) wetPeak else null,
                "nativeEffectiveAzimuthDeg" to nativeEffectiveAzimuthDeg(),
                "nativeEffectiveElevationDeg" to nativeEffectiveElevationDeg(),
            )
        } catch (e: Throwable) {
            mapOf(
                "dspLibraryLoaded" to true,
                "dspState" to "Error",
                "nativeLastError" to (e.message ?: "native diagnostics failed"),
            )
        }
    }

    private external fun nativeStart(sampleRate: Int, channelCount: Int): Int
    private external fun nativeStop(): Int
    private external fun nativePushFloat(samples: FloatArray, count: Int): Int
    private external fun nativePushPcm16(samples: ShortArray, count: Int): Int
    private external fun nativeDspState(): String
    private external fun nativeLastError(): String
    private external fun nativeInputFrames(): Long
    private external fun nativeConsumedFrames(): Long
    private external fun nativeDspChunks(): Long
    private external fun nativeWetFrames(): Long
    private external fun nativeDroppedFrames(): Long
    private external fun nativeOverruns(): Long
    private external fun nativeQueueDepthFrames(): Long
    private external fun nativeQueueHighWaterFrames(): Long
    private external fun nativeWetRmsDb(): Double
    private external fun nativeWetPeakDb(): Double
    private external fun nativeEffectiveAzimuthDeg(): Double
    private external fun nativeEffectiveElevationDeg(): Double
}
