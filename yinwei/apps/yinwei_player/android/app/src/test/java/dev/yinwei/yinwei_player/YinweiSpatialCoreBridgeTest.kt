package dev.yinwei.yinwei_player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class YinweiSpatialCoreBridgeTest {
    @Test
    fun jvmUnitTestsDoNotLoadTheRealRustLibrary() {
        assertFalse(YinweiSpatialCoreBridge.libraryLoaded)
        assertNotNull(YinweiSpatialCoreBridge.loadError)
    }

    @Test
    fun missingLibraryReturnsDiagnosableErrorWithoutThrowing() {
        assertEquals(
            YinweiSpatialCoreBridge.ERR_NOT_LOADED,
            YinweiSpatialCoreBridge.start(48000, 2),
        )
        assertEquals(
            YinweiSpatialCoreBridge.ERR_NOT_LOADED,
            YinweiSpatialCoreBridge.pushFloat(FloatArray(8), 8),
        )
        assertEquals(
            YinweiSpatialCoreBridge.ERR_NOT_LOADED,
            YinweiSpatialCoreBridge.pushPcm16(ShortArray(8), 8),
        )
        assertEquals(
            YinweiSpatialCoreBridge.ERR_NOT_LOADED,
            YinweiSpatialCoreBridge.stop(),
        )
        val snap = YinweiSpatialCoreBridge.snapshot()
        assertEquals(false, snap["dspLibraryLoaded"])
        assertEquals("Error", snap["dspState"])
        assertTrue(snap["nativeLastError"].toString().isNotEmpty())
    }

    @Test
    fun emptyPushIsANoOpWhenLibraryIsMissing() {
        assertEquals(
            YinweiSpatialCoreBridge.ERR_NOT_LOADED,
            YinweiSpatialCoreBridge.pushFloat(FloatArray(0), 0),
        )
    }
}
