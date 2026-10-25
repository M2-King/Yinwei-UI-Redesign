import Flutter
import UIKit
import Network

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    YinweiLiveActivityChannel.register(messenger: messenger)
    YinweiAudioSessionChannel.register(messenger: messenger)
    YinweiHandGestures.register(messenger: messenger)
    YinweiScreenAudioProbeChannel.register(messenger: messenger)
    YinweiReplayKitProbeChannel.register(messenger: messenger)
    engineBridge.applicationRegistrar.register(
      YinweiListenRoomRoutePickerFactory(), withId: YinweiListenRoomRoutePickerFactory.viewType)
    YinweiDeveloperDiagnosticsChannel.register(messenger: messenger)
    YinweiSignInKeychainChannel.register(messenger: messenger)
    YinweiListenNetworkChannel.register(messenger: messenger)
    print("[YINWEI_IOS] native channels registered")
  }

}

/// Listen-only recovery signal. The monitor is off until pairing succeeds;
/// it observes OS path changes and never starts/configures a VPN or a socket.
private enum YinweiListenNetworkChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dev.yinwei/listen_network",
      binaryMessenger: messenger)
    var monitor: NWPathMonitor?
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "watch":
        if monitor == nil {
          let next = NWPathMonitor()
          next.pathUpdateHandler = { _ in
            DispatchQueue.main.async { channel.invokeMethod("changed", arguments: nil) }
          }
          monitor = next
          next.start(queue: DispatchQueue(label: "dev.yinwei.listen-network"))
        }
        result(nil)
      case "unwatch":
        monitor?.cancel()
        monitor = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
