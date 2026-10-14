import Flutter
import AVFoundation
import ReplayKit
import UIKit

/// Host-side control surface for the ReplayKit feasibility probe.
/// Audio stays inside the broadcast extension; this channel reads telemetry only.
enum YinweiReplayKitProbeChannel {
  static let name = "dev.yinwei/replaykit_audio_probe"
  static let appGroup = "group.dev.yinwei.remote.capture"
  static let statusKey = "yinwei.replaykit.numeric-status.v1"
  static let extensionBundleIdentifier = "dev.yinwei.yinweiPlayer.BroadcastUpload"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    let controller = YinweiReplayKitProbeController()
    channel.setMethodCallHandler { call, result in
      controller.handle(call: call, result: result)
    }
  }
}

final class YinweiReplayKitProbeController {
  private weak var pickerController: UIViewController?
  private let returnTone = YinweiReplayKitReturnTonePlayer()
  private var lastToneError: String?

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(availability())
    case "showBroadcastPicker":
      showBroadcastPicker(result: result)
    case "getStatus":
      result(status())
    case "resetStatus":
      resetStatus()
      result(["ok": true])
    case "playReturnTone":
      playReturnTone(result: result)
    case "stopReturnTone":
      returnTone.stop()
      lastToneError = nil
      result(["ok": true])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func availability() -> [String: Any] {
    let defaultsAvailable = UserDefaults(
      suiteName: YinweiReplayKitProbeChannel.appGroup
    ) != nil
    return [
      "supported": true,
      "replayKitAvailable": true,
      "appGroupAvailable": defaultsAvailable,
      "extensionBundleIdentifier": YinweiReplayKitProbeChannel.extensionBundleIdentifier,
      "osVersion": UIDevice.current.systemVersion,
    ]
  }

  private func status() -> [String: Any] {
    guard let defaults = UserDefaults(
      suiteName: YinweiReplayKitProbeChannel.appGroup
    ) else {
      return emptyStatus(error: "Yinwei capture App Group is unavailable in this signed build")
    }
    guard let saved = defaults.dictionary(
      forKey: YinweiReplayKitProbeChannel.statusKey
    ) else {
      return emptyStatus(error: nil)
    }
    var safe = saved
    safe["supported"] = true
    safe["returnToneActive"] = returnTone.isActive
    if let lastToneError { safe["lastError"] = lastToneError }
    return safe
  }

  private func resetStatus() {
    UserDefaults(suiteName: YinweiReplayKitProbeChannel.appGroup)?.removeObject(
      forKey: YinweiReplayKitProbeChannel.statusKey
    )
  }

  private func emptyStatus(error: String?) -> [String: Any] {
    var value: [String: Any] = [
      "supported": true,
      "broadcastActive": false,
      "broadcastPhase": "idle",
      "appAudioBufferCount": 0,
      "ignoredMicrophoneBufferCount": 0,
      "discardedVideoBufferCount": 0,
      "droppedInspectionBufferCount": 0,
      "receivingAppAudio": false,
      "audioSilent": false,
      "returnToneActive": returnTone.isActive,
    ]
    if let error { value["lastError"] = error }
    if let lastToneError { value["lastError"] = lastToneError }
    return value
  }

  private func playReturnTone(result: @escaping FlutterResult) {
    do {
      try returnTone.play()
      lastToneError = nil
      result(["ok": true])
    } catch {
      lastToneError = String(describing: error)
      result(FlutterError(
        code: "return_tone_failed",
        message: "Yinwei could not play the return-path test tone",
        details: String(describing: error)
      ))
    }
  }

  private func showBroadcastPicker(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard self.pickerController == nil else {
        result(["ok": true, "alreadyPresented": true])
        return
      }
      guard let presenter = Self.presenter() else {
        result(FlutterError(
          code: "no_presenter",
          message: "Yinwei could not present Apple’s broadcast picker",
          details: nil
        ))
        return
      }
      let controller = YinweiBroadcastPickerViewController()
      controller.onDismiss = { [weak self] in self?.pickerController = nil }
      self.pickerController = controller
      presenter.present(controller, animated: true)
      result(["ok": true])
    }
  }

  private static func presenter() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
    var current = window?.rootViewController
    while let presented = current?.presentedViewController {
      current = presented
    }
    return current
  }
}

/// Short, non-spatial two-frequency signal for testing return-audio recapture.
/// It is never started automatically and does not enter spatial_core.
private final class YinweiReplayKitReturnTonePlayer {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private(set) var isActive = false

  func play() throws {
    stop()
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    try session.setActive(true)

    guard let format = AVAudioFormat(
      standardFormatWithSampleRate: 48_000,
      channels: 2
    ), let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(48_000 * 2)
    ), let channels = buffer.floatChannelData
    else {
      try? session.setActive(false, options: [.notifyOthersOnDeactivation])
      throw YinweiReplayKitToneError.bufferAllocationFailed
    }

    buffer.frameLength = buffer.frameCapacity
    let total = Int(buffer.frameLength)
    for frame in 0..<total {
      let time = Double(frame) / format.sampleRate
      let fadeFrames = 960.0
      let edge = min(Double(frame), Double(total - frame - 1))
      let fade = min(1.0, max(0.0, edge / fadeFrames))
      let sample = Float(
        0.08 * fade * (
          sin(2 * Double.pi * 997 * time) +
          sin(2 * Double.pi * 1499 * time)
        )
      )
      channels[0][frame] = sample
      channels[1][frame] = sample
    }

    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.prepare()
    do {
      try engine.start()
    } catch {
      engine.disconnectNodeOutput(player)
      engine.detach(player)
      try? session.setActive(false, options: [.notifyOthersOnDeactivation])
      throw error
    }
    isActive = true
    player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
      DispatchQueue.main.async { self?.stop() }
    }
    player.play()
  }

  func stop() {
    guard isActive || engine.isRunning else { return }
    player.stop()
    engine.stop()
    engine.disconnectNodeOutput(player)
    engine.detach(player)
    isActive = false
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: [.notifyOthersOnDeactivation]
    )
  }
}

private enum YinweiReplayKitToneError: Error {
  case bufferAllocationFailed
}

private final class YinweiBroadcastPickerViewController: UIViewController {
  var onDismiss: (() -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.045, green: 0.05, blue: 0.065, alpha: 1)
    modalPresentationStyle = .pageSheet

    let titleLabel = UILabel()
    titleLabel.text = "Share Music audio with Yinwei"
    titleLabel.textColor = .white
    titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 0

    let explanation = UILabel()
    explanation.text = "Tap the Apple broadcast button below, choose Yinwei, then switch to Music and play. Screen frames and microphone audio are discarded."
    explanation.textColor = UIColor.white.withAlphaComponent(0.68)
    explanation.font = .systemFont(ofSize: 15)
    explanation.textAlignment = .center
    explanation.numberOfLines = 0

    let picker = RPSystemBroadcastPickerView(frame: .zero)
    picker.preferredExtension = YinweiReplayKitProbeChannel.extensionBundleIdentifier
    picker.showsMicrophoneButton = false
    picker.tintColor = .white
    picker.accessibilityLabel = "Start Yinwei app-audio capture"

    let close = UIButton(type: .system)
    close.setTitle("Done", for: .normal)
    close.setTitleColor(.white, for: .normal)
    close.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    close.addTarget(self, action: #selector(closePressed), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [titleLabel, explanation, picker, close])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 22
    stack.translatesAutoresizingMaskIntoConstraints = false
    picker.translatesAutoresizingMaskIntoConstraints = false
    close.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
      stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      picker.widthAnchor.constraint(equalToConstant: 72),
      picker.heightAnchor.constraint(equalToConstant: 72),
      close.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
  }

  @objc private func closePressed() {
    dismiss(animated: true) { [weak self] in self?.onDismiss?() }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    onDismiss?()
    onDismiss = nil
  }
}
