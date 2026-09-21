package dev.yinwei.yinwei_player

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter MethodChannel for Android A1 AudioPlaybackCapture.
 * Channel: dev.yinwei/android_playback_capture
 */
class YinweiPlaybackCaptureChannel(
    private val activity: Activity,
    private val projectionLauncher: ActivityResultLauncher<android.content.Intent>,
    private val recordAudioLauncher: ActivityResultLauncher<String>,
    @Suppress("UnusedPrivateProperty")
    private val notificationsLauncher: ActivityResultLauncher<String>,
) : MethodChannel.MethodCallHandler {
    @Volatile
    private var pendingProjectionLaunch = false

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
        YinweiPlaybackCaptureStore.update {
            supported = Build.VERSION.SDK_INT >= 29
            androidSdk = Build.VERSION.SDK_INT
        }
        YinweiPlaybackCaptureStore.log("LIFECYCLE", "android capture channel registered sdk=${Build.VERSION.SDK_INT}")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isAvailableMap())
            "requestAndStartCapture" -> {
                requestAndStartCapture()
                result.success(mapOf("ok" to true))
            }
            "stopCapture" -> {
                stopCapture()
                result.success(mapOf("ok" to true))
            }
            "getStatus" -> result.success(YinweiPlaybackCaptureStore.asStatusMap())
            else -> result.notImplemented()
        }
    }

    fun onRecordAudioResult(granted: Boolean) {
        if (!granted) {
            pendingProjectionLaunch = false
            YinweiPlaybackCaptureStore.update {
                permissionPending = false
                permissionDenied = true
                lastError = "RECORD_AUDIO denied"
                captureHint = YinweiPlaybackCaptureStart.HINT_RECORD_DENIED
            }
            YinweiPlaybackCaptureStore.log("PROJECTION", "RECORD_AUDIO denied")
            return
        }
        YinweiPlaybackCaptureStore.update {
            permissionDenied = false
            lastError = null
            permissionPending = true
            captureHint = YinweiPlaybackCaptureStart.HINT_PROJECTION
        }
        YinweiPlaybackCaptureStore.log("PROJECTION", "RECORD_AUDIO granted; scheduling screen capture intent")
        scheduleProjectionConsent()
    }

    fun onNotificationsResult(granted: Boolean) {
        YinweiPlaybackCaptureStore.log(
            "PROJECTION",
            if (granted) "POST_NOTIFICATIONS granted" else "POST_NOTIFICATIONS denied (capture continues)",
        )
        // Notifications must not gate MediaProjection. If a leftover request
        // completes, continue the pending screen-audio launch.
        scheduleProjectionConsent()
    }

    fun onHostResumed() {
        launchProjectionConsentIfPending()
    }

    fun onProjectionResult(result: ActivityResult) {
        if (result.resultCode != Activity.RESULT_OK || result.data == null) {
            pendingProjectionLaunch = false
            YinweiPlaybackCaptureStore.update {
                permissionPending = false
                permissionCancelled = true
                lastError = null
                projectionGranted = false
                captureHint = YinweiPlaybackCaptureStart.HINT_CANCELLED
            }
            YinweiPlaybackCaptureStore.log("PROJECTION", "MediaProjection cancelled")
            return
        }
        YinweiPlaybackCaptureStore.update {
            permissionCancelled = false
            permissionDenied = false
            permissionPending = false
            lastError = null
            captureHint = null
        }
        YinweiPlaybackCaptureStore.log("PROJECTION", "MediaProjection approved")
        YinweiPlaybackCaptureService.start(activity, result.resultCode, result.data!!)
    }

    private fun requestAndStartCapture() {
        val action = YinweiPlaybackCaptureStart.nextAction(
            Build.VERSION.SDK_INT,
            recordAudioGranted(),
        )
        if (action == YinweiPlaybackCaptureStart.Action.Unsupported) {
            pendingProjectionLaunch = false
            YinweiPlaybackCaptureStore.update {
                supported = false
                permissionPending = false
                lastError = null
                captureHint = null
            }
            return
        }
        if (YinweiPlaybackCaptureStore.copy().captureActive ||
            YinweiPlaybackCaptureStore.copy().foregroundServiceRunning
        ) {
            YinweiPlaybackCaptureService.stop(activity)
        }
        pendingProjectionLaunch = false
        YinweiPlaybackCaptureStore.resetSession()
        YinweiPlaybackCaptureStore.update {
            supported = true
            permissionPending = true
            permissionDenied = false
            permissionCancelled = false
            lastError = null
        }
        when (action) {
            YinweiPlaybackCaptureStart.Action.RequestRecordAudio -> {
                YinweiPlaybackCaptureStore.update {
                    captureHint = YinweiPlaybackCaptureStart.HINT_RECORD
                }
                YinweiPlaybackCaptureStore.log("PROJECTION", "requesting RECORD_AUDIO")
                recordAudioLauncher.launch(Manifest.permission.RECORD_AUDIO)
            }
            YinweiPlaybackCaptureStart.Action.LaunchProjection -> {
                YinweiPlaybackCaptureStore.update {
                    captureHint = YinweiPlaybackCaptureStart.HINT_PROJECTION
                }
                scheduleProjectionConsent()
            }
            YinweiPlaybackCaptureStart.Action.Unsupported -> {}
        }
    }

    private fun recordAudioGranted(): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun scheduleProjectionConsent() {
        pendingProjectionLaunch = true
        launchProjectionConsentIfPending()
    }

    private fun launchProjectionConsentIfPending() {
        if (!pendingProjectionLaunch) return
        if (!isHostResumed()) {
            YinweiPlaybackCaptureStore.log("PROJECTION", "deferring screen capture intent until resume")
            return
        }
        pendingProjectionLaunch = false
        launchProjectionConsent()
    }

    private fun isHostResumed(): Boolean {
        val host = activity as? ComponentActivity ?: return true
        return host.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
    }

    private fun launchProjectionConsent() {
        try {
            val mgr = activity.getSystemService(Activity.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            YinweiPlaybackCaptureStore.update {
                permissionPending = true
                captureHint = YinweiPlaybackCaptureStart.HINT_PROJECTION
            }
            YinweiPlaybackCaptureStore.log("PROJECTION", "launching screen capture intent")
            projectionLauncher.launch(mgr.createScreenCaptureIntent())
        } catch (e: Exception) {
            pendingProjectionLaunch = true
            val message = "Screen capture intent failed: ${e.message}"
            YinweiPlaybackCaptureStore.update {
                permissionPending = true
                captureHint = "${YinweiPlaybackCaptureStart.HINT_PROJECTION} ($message)"
            }
            YinweiPlaybackCaptureStore.log("PROJECTION", message)
        }
    }

    private fun stopCapture() {
        pendingProjectionLaunch = false
        if (Build.VERSION.SDK_INT >= 29) {
            YinweiPlaybackCaptureService.stop(activity)
        }
        YinweiPlaybackCaptureStore.update {
            permissionPending = false
            captureActive = false
            captureHint = null
        }
    }

    private fun isAvailableMap(): Map<String, Any> =
        mapOf(
            "supported" to (Build.VERSION.SDK_INT >= 29),
            "androidSdk" to Build.VERSION.SDK_INT,
        )

    companion object {
        const val CHANNEL = "dev.yinwei/android_playback_capture"
    }
}
