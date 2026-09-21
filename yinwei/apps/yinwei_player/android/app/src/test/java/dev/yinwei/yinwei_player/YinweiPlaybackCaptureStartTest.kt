package dev.yinwei.yinwei_player

import org.junit.Assert.assertEquals
import org.junit.Test

class YinweiPlaybackCaptureStartTest {
    @Test
    fun belowApi29IsUnsupportedEvenIfRecordAudioIsGranted() {
        assertEquals(
            YinweiPlaybackCaptureStart.Action.Unsupported,
            YinweiPlaybackCaptureStart.nextAction(
                sdkInt = 28,
                recordAudioGranted = true,
            ),
        )
    }

    @Test
    fun missingRecordAudioRequestsPermissionBeforeProjection() {
        assertEquals(
            YinweiPlaybackCaptureStart.Action.RequestRecordAudio,
            YinweiPlaybackCaptureStart.nextAction(
                sdkInt = 34,
                recordAudioGranted = false,
            ),
        )
    }

    @Test
    fun grantedRecordAudioLaunchesProjectionWithoutNotificationGate() {
        assertEquals(
            YinweiPlaybackCaptureStart.Action.LaunchProjection,
            YinweiPlaybackCaptureStart.nextAction(
                sdkInt = 34,
                recordAudioGranted = true,
            ),
        )
        assertEquals(
            YinweiPlaybackCaptureStart.Action.LaunchProjection,
            YinweiPlaybackCaptureStart.nextAction(
                sdkInt = 36,
                recordAudioGranted = true,
            ),
        )
    }

    @Test
    fun api34AndAboveUseDefaultDisplayProjectionConfig() {
        assertEquals(false, YinweiPlaybackCaptureStart.usesDefaultDisplayProjectionConfig(33))
        assertEquals(true, YinweiPlaybackCaptureStart.usesDefaultDisplayProjectionConfig(34))
        assertEquals(true, YinweiPlaybackCaptureStart.usesDefaultDisplayProjectionConfig(36))
    }
