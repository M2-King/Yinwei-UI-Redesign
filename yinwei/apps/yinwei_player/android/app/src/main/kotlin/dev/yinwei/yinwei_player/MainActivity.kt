package dev.yinwei.yinwei_player

import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    private lateinit var captureChannel: YinweiPlaybackCaptureChannel

    private val projectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (::captureChannel.isInitialized) {
            captureChannel.onProjectionResult(result)
        }
    }

    private val recordAudioLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (::captureChannel.isInitialized) {
            captureChannel.onRecordAudioResult(granted)
        }
    }

    private val notificationsLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (::captureChannel.isInitialized) {
            captureChannel.onNotificationsResult(granted)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        captureChannel = YinweiPlaybackCaptureChannel(
            activity = this,
            projectionLauncher = projectionLauncher,
            recordAudioLauncher = recordAudioLauncher,
            notificationsLauncher = notificationsLauncher,
        )
        captureChannel.register(flutterEngine.dartExecutor.binaryMessenger)
        YinweiDeveloperDiagnostics.register(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        YinweiDeveloperDiagnostics.setAppForeground(true)
    }

    override fun onResume() {
        super.onResume()
        YinweiDeveloperDiagnostics.setAppForeground(true)
        if (::captureChannel.isInitialized) {
            captureChannel.onHostResumed()
        }
    }

    override fun onPause() {
        YinweiDeveloperDiagnostics.setAppForeground(false)
        super.onPause()
    }
}
