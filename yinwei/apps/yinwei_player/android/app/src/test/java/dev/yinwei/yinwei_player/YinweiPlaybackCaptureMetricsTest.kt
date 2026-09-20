package dev.yinwei.yinwei_player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class YinweiPlaybackCaptureMetricsTest {
    @Test
    fun zeroPcm16IsSilentWithInfDb() {
        val metrics = YinweiPlaybackCaptureMetrics.fromPcm16(ShortArray(2048), 2048)
        assertTrue(metrics.silent)
        assertEquals(0.0, metrics.rms, 0.0)
        assertNull(metrics.rmsDb)
        assertNull(metrics.peakDb)
    }

    @Test
    fun fullScalePcm16IsNonSilent() {
        val samples = ShortArray(1024) { i -> if (i % 2 == 0) 32767 else -32767 }
        val metrics = YinweiPlaybackCaptureMetrics.fromPcm16(samples, samples.size)
        assertFalse(metrics.silent)
        assertTrue(metrics.peakDb != null && metrics.peakDb!! > -1.0)
    }

    @Test
    fun dataStatesStayDistinct() {
        assertEquals("NO_AUDIO_DATA", YinweiPlaybackCaptureMetrics.dataState(0, true))
        assertEquals("SILENT", YinweiPlaybackCaptureMetrics.dataState(12, true))
        assertEquals("NON_SILENT", YinweiPlaybackCaptureMetrics.dataState(12, false))
    }

    @Test
    fun logLineKeepsNoDataSilentAndNonSilentSeparate() {
        assertTrue(
            YinweiPlaybackCaptureMetrics.logLine(
                0, 0, 48000, 2, "PCM_16BIT", null, null, "NO_AUDIO_DATA",
            ).contains("state=NO_AUDIO_DATA"),
        )
        assertTrue(
            YinweiPlaybackCaptureMetrics.logLine(
                95, 57000, 48000, 2, "PCM_16BIT", null, null, "SILENT",
            ).contains("state=SILENT"),
        )
        val wet = YinweiPlaybackCaptureMetrics.logLine(
            82, 49152, 48000, 2, "PCM_16BIT", -17.8, -2.1, "NON_SILENT",
        )
        assertTrue(wet.contains("[YINWEI_ANDROID_CAPTURE]"))
        assertTrue(wet.contains("reads=82"))
        assertTrue(wet.contains("rms=-17.8dBFS"))
    }
}
