package dev.yinwei.yinwei_player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class YinweiPlaybackCaptureStoreDspTest {
    @Test
    fun statusMapAlwaysExposesDspKeys() {
        YinweiPlaybackCaptureStore.resetSession()
        val map = YinweiPlaybackCaptureStore.asStatusMap()
        assertTrue(map.containsKey("dspState"))
        assertTrue(map.containsKey("dspLibraryLoaded"))
        assertTrue(map.containsKey("nativeInputFrames"))
        assertEquals(false, map["dspLibraryLoaded"])
        assertEquals("Error", map["dspState"])
        assertTrue(map["nativeLastError"].toString().isNotEmpty())
    }
}
