package dev.yinwei.yinwei_player

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.core.content.ContextCompat
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
    private val notificationsLauncher: ActivityResultLauncher<String>,
) : MethodChannel.MethodCallHandler {
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
            YinweiPlaybackCaptureStore.update {
                permissionPending = false
                permissionDenied = true
                lastError = "RECORD_AUDIO denied"
            }
            YinweiPlaybackCaptureStore.log("PROJECTION", "RECORD_AUDIO denied")
            return
        }
        YinweiPlaybackCaptureStore.update {
            permissionDenied = false
            lastError = null
        }
        maybeRequestNotificationsThenProjection()
    }

    fun onNotificationsResult(granted: Boolean) {
        YinweiPlaybackCaptureStore.log(
            "PROJECTION",
            if (granted) "POST_NOTIFICATIONS granted" else "POST_NOTIFICATIONS denied (capture continues)",
        )
        launchProjectionConsent()
    }

    fun onProjectionResult(result: ActivityResult) {
        if (result.resultCode != Activity.RESULT_OK || result.data == null) {
            YinweiPlaybackCaptureStore.update {
                permissionPending = false
                permissionCancelled = true
                lastError = null
                projectionGranted = false
            }
            YinweiPlaybackCaptureStore.log("PROJECTION", "MediaProjection cancelled")
            return
        }
        YinweiPlaybackCaptureStore.update {
            permissionCancelled = false
            permissionDenied = false
            permissionPending = false
            lastError = null
        }
        YinweiPlaybackCaptureStore.log("PROJECTION", "MediaProjection approved")
        YinweiPlaybackCaptureService.start(activity, result.resultCode, result.data!!)
    }

    private fun requestAndStartCapture() {
        if (Build.VERSION.SDK_INT < 29) {
            YinweiPlaybackCaptureStore.update {
                supported = false
                permissionPending = false
                lastError = null
            }
            return
        }
        if (YinweiPlaybackCaptureStore.copy().captureActive ||
            YinweiPlaybackCaptureStore.copy().foregroundServiceRunning
        ) {
            YinweiPlaybackCaptureService.stop(activity)
        }
        YinweiPlaybackCaptureStore.resetSession()
        YinweiPlaybackCaptureStore.update {
            supported = true
            permissionPending = true
            permissionDenied = false
            permissionCancelled = false
            lastError = null
        }
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            recordAudioLauncher.launch(Manifest.permission.RECORD_AUDIO)
            return
        }
        maybeRequestNotificationsThenProjection()
    }

    private fun maybeRequestNotificationsThenProjection() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            notificationsLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        launchProjectionConsent()
    }

    private fun launchProjectionConsent() {
        val mgr = activity.getSystemService(Activity.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        YinweiPlaybackCaptureStore.update { permissionPending = true }
        projectionLauncher.launch(mgr.createScreenCaptureIntent())
    }

    private fun stopCapture() {
        if (Build.VERSION.SDK_INT >= 29) {
            YinweiPlaybackCaptureService.stop(activity)
        }
        YinweiPlaybackCaptureStore.update {
            permissionPending = false
            captureActive = false
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
