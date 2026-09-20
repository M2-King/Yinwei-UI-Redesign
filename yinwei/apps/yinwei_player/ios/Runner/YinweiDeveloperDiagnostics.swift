import AVFoundation
import Flutter
import Foundation
import UIKit

/// On-device diagnostics for Codemagic/iPhone testing without an Xcode console.
/// Never stores raw captured PCM.
enum YinweiDeveloperDiagnosticsChannel {
  static let name = "dev.yinwei/developer_diagnostics"

  static func register(messenger: FlutterBinaryMessenger) {
    YinweiDeveloperDiagnostics.shared.start()
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      YinweiDeveloperDiagnostics.shared.handle(call: call, result: result)
    }
  }
}

struct YinweiDiagnosticEntry {
  let timestamp: TimeInterval
  let category: String
  let message: String

  func asMap() -> [String: Any] {
    [
      "ts": timestamp,
      "iso": YinweiDeveloperDiagnostics.iso(timestamp),
      "category": category,
      "message": message,
    ]
  }
}

final class YinweiDeveloperDiagnostics {
  static let shared = YinweiDeveloperDiagnostics()
  static let logCapacity = 300

  private let lock = NSLock()
  private var entries: [YinweiDiagnosticEntry] = []
  private var observers: [NSObjectProtocol] = []
  private var started = false
  private var appForeground = true
  private var captureStreamStarted = false
  private var lastInterruption: String?
  private var lastRouteChange: String?
  private var lastCaptureError: String?

  func start() {
    lock.lock()
    if started {
      lock.unlock()
      return
    }
    started = true
    lock.unlock()
    observeLifecycle()
    log("LIFECYCLE", "diagnostics started")
  }

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getSnapshot":
      result(snapshot())
    case "exportReport":
      let args = call.arguments as? [String: Any]
      let text = args?["text"] as? String ?? ""
      let filename = args?["filename"] as? String ?? "yinwei-diagnostics.json"
      export(text: text, filename: filename, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func log(_ category: String, _ message: String) {
    let entry = YinweiDiagnosticEntry(
      timestamp: Date().timeIntervalSince1970,
      category: category,
      message: message
    )
    lock.lock()
    entries.append(entry)
    if entries.count > Self.logCapacity {
      entries.removeFirst(entries.count - Self.logCapacity)
    }
    lock.unlock()
    print("[YINWEI_\(category)] \(message)")
  }

  func markCaptureStream(started: Bool, error: String? = nil) {
    lock.lock()
    captureStreamStarted = started
    if let error, !error.isEmpty {
      lastCaptureError = error
    } else if started {
      lastCaptureError = nil
    }
    lock.unlock()
    if let error, !error.isEmpty {
      log("LIFECYCLE", "capture error \(error)")
    } else {
      log("LIFECYCLE", started ? "ScreenCaptureKit stream started" : "ScreenCaptureKit stream stopped")
    }
  }

  func snapshot() -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    let outputs = session.currentRoute.outputs.map { port -> [String: Any] in
      [
        "name": port.portName,
        "type": port.portType.rawValue,
        "kind": Self.routeKind(port.portType),
      ]
    }
    let kinds = Set(outputs.compactMap { $0["kind"] as? String })
    lock.lock()
    let logMaps = entries.map { $0.asMap() }
    let foreground = appForeground
    let streamStarted = captureStreamStarted
    let interruption = lastInterruption
    let routeChange = lastRouteChange
    let captureError = lastCaptureError
    lock.unlock()

    var lifecycle: [String: Any] = [
      "appForeground": foreground,
      "appState": foreground ? "foreground" : "background",
      "captureStreamStarted": streamStarted,
    ]
    if let interruption { lifecycle["lastInterruption"] = interruption }
    if let routeChange { lifecycle["lastRouteChange"] = routeChange }
    if let captureError { lifecycle["lastCaptureError"] = captureError }

    var output: [String: Any] = [
      "category": session.category.rawValue,
      "mode": session.mode.rawValue,
      "active": session.sampleRate > 0,
      "sampleRate": session.sampleRate,
      "outputCount": outputs.count,
      "outputs": outputs,
      "otherAudioPlaying": session.isOtherAudioPlaying,
      "routeKind": kinds.sorted().joined(separator: ","),
      "headphones": kinds.contains("headphones"),
      "speaker": kinds.contains("speaker"),
      "bluetooth": kinds.contains("bluetooth"),
    ]
    if let first = outputs.first {
      output["currentOutputRoute"] = first["name"] ?? ""
      output["currentOutputType"] = first["type"] ?? ""
    }

    return [
      "runningIosVersion": UIDevice.current.systemVersion,
      "bundleVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
      "bundleShortVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
      "output": output,
      "lifecycle": lifecycle,
      "log": logMaps,
      "pcmSamplesIncluded": false,
    ]
  }

  private func export(text: String, filename: String, result: @escaping FlutterResult) {
    let safeName = filename.replacingOccurrences(of: "/", with: "-")
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(safeName)
    do {
      try text.data(using: .utf8)?.write(to: url, options: .atomic)
    } catch {
      result(
        FlutterError(code: "export", message: String(describing: error), details: nil)
      )
      return
    }
    DispatchQueue.main.async {
      guard let root = Self.presenter() else {
        result(["ok": true, "path": url.path, "shared": false])
        return
      }
      let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      av.completionWithItemsHandler = { _, _, _, _ in }
      if let pop = av.popoverPresentationController {
        pop.sourceView = root.view
        pop.sourceRect = CGRect(
          x: root.view.bounds.midX,
          y: root.view.bounds.midY,
          width: 1,
          height: 1
        )
      }
      root.present(av, animated: true)
      result(["ok": true, "path": url.path, "shared": true])
    }
  }

  private func observeLifecycle() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.lock.lock()
        self?.appForeground = true
        self?.lock.unlock()
        self?.log("LIFECYCLE", "app foreground")
      }
    )
    observers.append(
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.lock.lock()
        self?.appForeground = false
        self?.lock.unlock()
        self?.log("LIFECYCLE", "app background")
      }
    )
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
      ) { [weak self] note in
        let type = note.userInfo?[AVAudioSessionInterruptionTypeKey]
        let label = String(describing: type ?? "interruption")
        self?.lock.lock()
        self?.lastInterruption = label
        self?.lock.unlock()
        self?.log("LIFECYCLE", "interruption \(label)")
      }
    )
    observers.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
      ) { [weak self] note in
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey]
        let session = AVAudioSession.sharedInstance()
        let routes = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let label = "reason=\(String(describing: reason ?? "unknown")) route=\(routes)"
        self?.lock.lock()
        self?.lastRouteChange = label
        self?.lock.unlock()
        self?.log("LIFECYCLE", "route change \(label)")
      }
    )
  }

  static func iso(_ timestamp: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: timestamp))
  }

  static func routeKind(_ type: AVAudioSession.Port) -> String {
    switch type {
    case .headphones, .headsetMic:
      return "headphones"
    case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
      return "bluetooth"
    case .builtInSpeaker:
      return "speaker"
    default:
      return type.rawValue
    }
  }

  private static func presenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var root = window?.rootViewController
    while let presented = root?.presentedViewController {
      root = presented
    }
    return root
  }
}
