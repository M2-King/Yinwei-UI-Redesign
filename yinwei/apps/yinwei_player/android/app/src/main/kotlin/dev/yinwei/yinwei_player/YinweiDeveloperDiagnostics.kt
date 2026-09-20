package dev.yinwei.yinwei_player

import android.app.Activity
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** On-device diagnostics. Never includes captured PCM samples. */
object YinweiDeveloperDiagnostics : MethodChannel.MethodCallHandler {
    const val CHANNEL = "dev.yinwei/developer_diagnostics"

    private var activity: Activity? = null

    fun register(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
        YinweiPlaybackCaptureStore.log("LIFECYCLE", "android diagnostics channel registered")
    }

    fun setAppForeground(foreground: Boolean) {
        YinweiPlaybackCaptureStore.update { appForeground = foreground }
        YinweiPlaybackCaptureStore.log(
            "LIFECYCLE",
            if (foreground) "app foreground" else "app background",
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getSnapshot" -> result.success(snapshot())
            "exportReport" -> {
                val args = call.arguments as? Map<*, *>
                val text = args?.get("text") as? String ?: ""
                val filename = args?.get("filename") as? String ?: "yinwei-a1-diagnostics.json"
                export(text, filename, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun snapshot(): Map<String, Any?> {
        val s = YinweiPlaybackCaptureStore.copy()
        val context = activity
        val appVersion = try {
            val pkg = context?.packageName ?: "dev.yinwei.yinwei_player"
            val info = context?.packageManager?.getPackageInfo(pkg, 0)
            info?.versionName ?: ""
        } catch (_: Exception) {
            ""
        }
        return mapOf(
            "runningAndroidVersion" to (Build.VERSION.RELEASE ?: ""),
            "bundleVersion" to appVersion,
            "bundleShortVersion" to appVersion,
            "build" to mapOf(
                "androidSdk" to Build.VERSION.SDK_INT,
                "manufacturer" to (Build.MANUFACTURER ?: "unknown"),
                "model" to (Build.MODEL ?: "unknown"),
                "androidVersion" to (Build.VERSION.RELEASE ?: "unknown"),
                "appVersion" to appVersion,
            ),
            "lifecycle" to mapOf(
                "appForeground" to s.appForeground,
                "appState" to if (s.appForeground) "foreground" else "background",
                "projectionRevoked" to s.projectionRevoked,
                "captureStreamStarted" to s.captureActive,
                "lastCaptureError" to (s.lastError ?: ""),
            ),
            "log" to YinweiPlaybackCaptureStore.logLines(),
        )
    }

    private fun export(text: String, filename: String, result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.success(mapOf("ok" to false, "error" to "no activity"))
            return
        }
        try {
            val safe = filename.replace(Regex("[^A-Za-z0-9._-]"), "_")
            val file = File(act.cacheDir, safe)
            file.writeText(text)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "application/json"
                putExtra(Intent.EXTRA_SUBJECT, "Yinwei Android A1 diagnostics")
                putExtra(Intent.EXTRA_TEXT, text)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            act.startActivity(Intent.createChooser(send, "Export Diagnostics"))
            result.success(
                mapOf(
                    "ok" to true,
                    "shared" to true,
                    "path" to file.absolutePath,
                ),
            )
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "error" to (e.message ?: "export failed")))
        }
    }
}
