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
          print("[YINWEI_IOS] IOS_CHANNEL_PLAY_RECEIVED")
          try session.setCategory(.playback, mode: .default, options: [])
          try session.setActive(true)
          print("[YINWEI_IOS] AVAudioSession activate OK")
          result(nil)
        case "deactivate":
          print("[YINWEI_IOS] IOS_CHANNEL_DEACTIVATE")
          try session.setActive(false, options: [.notifyOthersOnDeactivation])
          print("[YINWEI_IOS] AVAudioSession deactivate OK")
          result(nil)
        default:
          print("[YINWEI_IOS] IOS_CHANNEL_UNHANDLED \(call.method)")
          result(FlutterMethodNotImplemented)
        }
      } catch {
        print("[YINWEI_IOS] IOS_CHANNEL_FAIL \(call.method) \(error)")
        result(
          FlutterError(code: "audio_session", message: String(describing: error), details: nil)
        )
      }
    }
  }
}
