import Flutter
import AVFoundation
import ReplayKit
import UIKit

/// Numeric ReplayKit probe plus explicitly started, bounded live IPC/output.
/// Network authorization stays in the host; media is never written to storage.
enum YinweiReplayKitProbeChannel {
  static let name = "dev.yinwei/replaykit_audio_probe"
  static let appGroup = YinweiProvisionedAppGroup.resolve(in: .main)
  static let statusKey = "yinwei.replaykit.numeric-status.v1"
  static let extensionBundleIdentifier: String = {
    let preferred = "dev.yinwei.yinweiPlayer.BroadcastUpload"
    guard let plugIns = Bundle.main.builtInPlugInsURL,
          let children = try? FileManager.default.contentsOfDirectory(
            at: plugIns,
            includingPropertiesForKeys: nil
          ),
          let extensionURL = children.first(where: { $0.pathExtension == "appex" }),
          let identifier = Bundle(url: extensionURL)?.bundleIdentifier,
          !identifier.isEmpty
    else { return preferred }
    return identifier
  }()

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    let controller = YinweiReplayKitProbeController()
    channel.setMethodCallHandler { call, result in
      controller.handle(call: call, result: result)
    }
  }
}

/// Uses the product App Group when the signing profile authorizes it. Some
/// owner-side IPA signers replace App Groups with signer-managed identifiers;
/// both the host and extension deterministically select the same authorized
/// fallback from their embedded profiles.
private enum YinweiProvisionedAppGroup {
  private static let preferred = "group.dev.yinwei.remote.capture"

  static func resolve(in bundle: Bundle) -> String {
    let groups = provisionedGroups(in: bundle)
    if groups.contains(preferred), canOpen(preferred) { return preferred }
    return groups.sorted().first(where: canOpen) ?? preferred
  }

  private static func canOpen(_ group: String) -> Bool {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: group
    ) != nil
  }

  private static func provisionedGroups(in bundle: Bundle) -> [String] {
    guard let profileURL = bundle.url(
      forResource: "embedded",
      withExtension: "mobileprovision"
    ),
    let profileData = try? Data(contentsOf: profileURL),
    let profile = String(data: profileData, encoding: .isoLatin1),
    let key = profile.range(
      of: "<key>com.apple.security.application-groups</key>"
    ),
    let end = profile.range(
      of: "</array>",
      range: key.upperBound..<profile.endIndex
    )
    else { return [] }

    let block = String(profile[key.upperBound..<end.lowerBound])
    let expression = try? NSRegularExpression(
      pattern: #"<string>(group\.[^<]+)</string>"#
    )
    let range = NSRange(block.startIndex..<block.endIndex, in: block)
    return expression?.matches(in: block, range: range).compactMap { match in
      guard let valueRange = Range(match.range(at: 1), in: block) else {
        return nil
      }
      return String(block[valueRange])
    } ?? []
  }
}

final class YinweiReplayKitProbeController {
  private weak var pickerController: UIViewController?
  private let returnTone = YinweiReplayKitReturnTonePlayer()
  private let remoteReturn = YinweiRemoteReturnPlayer()
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
    case "getRemoteIPCPath":
      guard YinweiReplayKitProbeChannel.appGroup == "group.dev.yinwei.remote.capture",
            let container = FileManager.default.containerURL(
              forSecurityApplicationGroupIdentifier: YinweiReplayKitProbeChannel.appGroup)
      else {
        result(FlutterError(code: "dedicated_app_group_required",
          message: "Live audio needs a signing profile that authorizes group.dev.yinwei.remote.capture for Yinwei and its broadcast extension. This signer group supports the numeric test only.", details: nil))
        return
      }
      result(container.appendingPathComponent("yw.sock").path)
    case "prepareRemoteReturn":
      do { returnTone.stop(); try remoteReturn.prepare(); result(["ok": true]) }
      catch { result(FlutterError(code: "return_output_failed",
        message: "Could not open iPad audio output", details: nil)) }
    case "writeRemoteReturn":
      guard remoteReturn.isReady else {
        result(FlutterError(code: "return_output_interrupted",
          message: "iPad audio output interrupted. Start again explicitly.", details: nil))
        return
      }
      if let typed = call.arguments as? FlutterStandardTypedData {
        result(["accepted": remoteReturn.accept(typed.data)])
      } else { result(["accepted": false]) }
    case "resetRemoteReturn":
      remoteReturn.reset(); result(["ok": true])
    case "stopRemoteReturn":
      remoteReturn.stop(); result(["ok": true])
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

/// Plays only the laptop's already-processed stereo. No spatial processor,
/// recorder or screen/microphone path exists in this output adapter.
private final class YinweiRemoteReturnPlayer {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var format: AVAudioFormat?
  private var queued = 0
  private var generation: UInt64 = 0
  private var epoch: UInt64?
  private var prepared = false
  private var observers: [NSObjectProtocol] = []
  var isReady: Bool { prepared && engine.isRunning }

  func prepare() throws {
    stop()
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    try session.setActive(true)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
    else { throw YinweiReplayKitToneError.bufferAllocationFailed }
    self.format = format
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    prepared = true
    do { engine.prepare(); try engine.start() }
    catch { stop(); throw error }
    // Do not silently restart a changed/interrupted output route with old PCM.
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: AVAudioSession.interruptionNotification,
        object: nil, queue: .main) { [weak self] note in
        if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
            == AVAudioSession.InterruptionType.began.rawValue { self?.stop() }
      },
      center.addObserver(forName: .AVAudioEngineConfigurationChange,
        object: engine, queue: .main) { [weak self] _ in self?.stop() },
    ]
  }

  func accept(_ data: Data) -> Bool {
    guard isReady, queued < 8, data.count >= 64, data.count <= 4152,
          let format else { return false }
    func u32(_ offset: Int) -> UInt32 {
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
    func u64(_ offset: Int) -> UInt64 {
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
    }
    let frames = Int(u32(36))
    guard u32(0) == 0x31574e59, u32(4) == 1, u32(32) == 48_000,
          frames > 0, frames <= 512, data.count == 56 + frames * 8 else { return false }
    let value = u64(8)
    if let epoch, epoch != value { return false }
    self.epoch = value
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
      frameCapacity: AVAudioFrameCount(frames)), let pcm = buffer.floatChannelData
    else { return false }
    for frame in 0..<frames {
      for channel in 0..<2 {
        let bits = u32(56 + frame * 8 + channel * 4)
        let sample = Float(bitPattern: bits)
        guard sample.isFinite else { return false }
        pcm[channel][frame] = sample
      }
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    let token = generation
    queued += 1
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self, self.generation == token else { return }
        self.queued = max(0, self.queued - 1)
        if self.queued == 0 && self.player.isPlaying { self.player.pause() }
      }
    }
    // Eight 512-frame packets = ~85 ms prefill; no hidden latency growth.
    if queued >= 8 && !player.isPlaying { player.play() }
    return true
  }

  func reset() {
    generation &+= 1
    guard prepared else { queued = 0; return }
    player.stop(); player.reset(); queued = 0
  }

  func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    reset(); epoch = nil
    guard prepared else { return }
    engine.stop(); engine.disconnectNodeOutput(player); engine.detach(player)
    format = nil; prepared = false
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
    picker.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)
    picker.layer.cornerRadius = 18
    picker.layer.borderWidth = 1
    picker.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
    picker.layer.masksToBounds = true
    picker.accessibilityLabel = "Start Yinwei app-audio capture"

    let pickerLabel = UILabel()
    pickerLabel.text = "Tap the blue button to start"
    pickerLabel.textColor = UIColor.white.withAlphaComponent(0.78)
    pickerLabel.font = .systemFont(ofSize: 14, weight: .medium)
    pickerLabel.textAlignment = .center

    let close = UIButton(type: .system)
    close.setTitle("Done", for: .normal)
    close.setTitleColor(.white, for: .normal)
    close.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    close.addTarget(self, action: #selector(closePressed), for: .touchUpInside)

    let stack = UIStackView(
      arrangedSubviews: [titleLabel, explanation, picker, pickerLabel, close]
    )
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
