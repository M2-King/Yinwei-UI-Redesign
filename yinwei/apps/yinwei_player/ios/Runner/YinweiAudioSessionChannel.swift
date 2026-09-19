import AVFoundation
import Flutter
import Foundation

/// AVAudioSession seam for the iOS Flutter app. Not WASAPI and not DSP.
enum YinweiAudioSessionChannel {
  static let name = "dev.yinwei/audio_session"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      do {
        let session = AVAudioSession.sharedInstance()
        switch call.method {
        case "activate":
          try session.setCategory(.playback, mode: .default, options: [])
          try session.setActive(true)
          result(nil)
        case "deactivate":
          try session.setActive(false, options: [.notifyOthersOnDeactivation])
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(
          FlutterError(code: "audio_session", message: String(describing: error), details: nil)
        )
      }
    }
  }
}
