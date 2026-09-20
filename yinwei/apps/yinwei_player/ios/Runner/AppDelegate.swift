import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    Self.activatePlaybackSession(reason: "launch")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    YinweiLiveActivityChannel.register(messenger: messenger)
    YinweiAudioSessionChannel.register(messenger: messenger)
    print("[YINWEI_IOS] native channels registered")
  }

  static func activatePlaybackSession(reason: String) {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      print("[YINWEI_IOS] AVAudioSession \(reason) OK category=playback mixWithOthers")
    } catch {
      print("[YINWEI_IOS] AVAudioSession \(reason) FAIL \(error)")
    }
  }
}
