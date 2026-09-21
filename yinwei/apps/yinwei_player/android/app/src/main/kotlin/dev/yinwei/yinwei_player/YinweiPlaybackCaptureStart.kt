package dev.yinwei.yinwei_player

/**
 * Decides the next user-gesture action for Android A1 Start Capture.
 *
 * POST_NOTIFICATIONS must not gate MediaProjection: that extra permission hop
 * launches the screen-audio intent from a callback, which OriginOS / iQOO
 * often drops as a background activity start.
 */
object YinweiPlaybackCaptureStart {
    const val MIN_SDK = 29

    const val HINT_RECORD =
        "Allow Recording (playback capture, not microphone), then tap Start Capture again"

    const val HINT_PROJECTION = "Allow screen audio capture"

    const val HINT_CANCELLED = "Screen audio not granted — tap Start Capture"

    const val HINT_RECORD_DENIED =
        "Recording permission denied. Enable it in Settings, then tap Start Capture."

    enum class Action {
        Unsupported,
        RequestRecordAudio,
        LaunchProjection,
    }

    fun nextAction(sdkInt: Int, recordAudioGranted: Boolean): Action {
        if (sdkInt < MIN_SDK) return Action.Unsupported
        if (!recordAudioGranted) return Action.RequestRecordAudio
        return Action.LaunchProjection
    }
}
