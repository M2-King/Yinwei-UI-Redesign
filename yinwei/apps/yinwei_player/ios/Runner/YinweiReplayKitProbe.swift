import Flutter
import AVFoundation
import AVKit
import MediaPlayer
import ReplayKit
import UIKit

/// Numeric ReplayKit probe plus explicitly started, bounded live IPC/output.
/// Network authorization stays in the host; media is never written to storage.
enum YinweiReplayKitProbeChannel {
  static let name = "dev.yinwei/replaykit_audio_probe"
  static let appGroup = YinweiCaptureGroup.current
  static let statusKey = "yinwei.replaykit.numeric-status.v1"
  static let extensionBundleIdentifier: String? = {
    guard let plugIns = Bundle.main.builtInPlugInsURL,
          let children = try? FileManager.default.contentsOfDirectory(
            at: plugIns, includingPropertiesForKeys: nil) else { return nil }
    return children.filter { $0.pathExtension == "appex" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url -> String? in
        guard let bundle = Bundle(url: url),
              let info = bundle.infoDictionary?["NSExtension"] as? [String: Any],
              info["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload",
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty else { return nil }
        return identifier
      }.first
  }()

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    let controller = YinweiReplayKitProbeController()
    channel.setMethodCallHandler { call, result in
      controller.handle(call: call, result: result)
    }
    let nowPlayingChannel = FlutterMethodChannel(
      name: YinweiNowPlayingController.channelName, binaryMessenger: messenger)
    let nowPlaying = YinweiNowPlayingController(channel: nowPlayingChannel)
    nowPlayingChannel.setMethodCallHandler { call, result in
      nowPlaying.handle(call: call, result: result)
    }
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
      guard let group = YinweiReplayKitProbeChannel.appGroup,
            let container = FileManager.default.containerURL(
              forSecurityApplicationGroupIdentifier: group)
      else {
        result(FlutterError(code: "app_group_unavailable",
          message: YinweiCaptureGroup.unavailable, details: nil))
        return
      }
      result(container.appendingPathComponent("yw.sock").path)
    case "prepareRemoteReturn":
      // listen: "Listen to laptop" (no iPad source app is playing).
      let listen = (call.arguments as? [String: Any])?["listen"] as? Bool == true
      do { returnTone.stop(); try remoteReturn.prepare(listen: listen); result(["ok": true]) }
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
    case "getRemoteReturnStatus":
      result(remoteReturn.status)
    case "setRemoteReturnVolume":
      if let volume = (call.arguments as? [String: Any])?["volume"] as? Double {
        remoteReturn.setVolume(volume)
      }
      result(nil)
    case "resetRemoteReturn":
      let args = call.arguments as? [String: Any]
      if args?["newStream"] as? Bool == true, let rate = args?["sampleRate"] as? Int {
        remoteReturn.newStream(sampleRate: Double(rate))
      } else {
        remoteReturn.reset()
      }
      result(["ok": true])
    case "stopRemoteReturn":
      remoteReturn.stop(); result(["ok": true])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func availability() -> [String: Any] {
    let defaultsAvailable = YinweiReplayKitProbeChannel.appGroup.flatMap {
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
    } != nil
    return [
      "supported": true,
      "replayKitAvailable": true,
      "appGroupAvailable": defaultsAvailable,
      "extensionBundleIdentifier": YinweiReplayKitProbeChannel.extensionBundleIdentifier ?? "",
      "osVersion": UIDevice.current.systemVersion,
    ]
  }

  private func status() -> [String: Any] {
    guard let group = YinweiReplayKitProbeChannel.appGroup,
          let defaults = UserDefaults(suiteName: group) else {
      return emptyStatus(error: YinweiCaptureGroup.unavailable)
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
    guard let group = YinweiReplayKitProbeChannel.appGroup else { return }
    UserDefaults(suiteName: group)?.removeObject(
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
    guard YinweiReplayKitProbeChannel.extensionBundleIdentifier != nil else {
      result(FlutterError(code: "broadcast_extension_missing",
        message: "Broadcast extension missing · reinstall a signed build that includes Yinwei Music Audio.", details: nil))
      return
    }
    guard YinweiReplayKitProbeChannel.appGroup != nil else {
      result(FlutterError(code: "app_group_unavailable",
        message: YinweiCaptureGroup.unavailable, details: nil))
      return
    }
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
  // The return path crosses the internet twice (iPad → laptop → iPad), so
  // packets arrive in bursts. Buffer by time and grow the start threshold
  // after each underrun so a jittery link settles instead of stuttering.
  // Underruns also happen when the source pauses, so the threshold must come
  // back down: after 10 s without an underrun it shrinks by 25 ms.
  private static let initialTargetFrames = 7_680  // 160 ms at 48 kHz
  private static let targetStepFrames = 2_400     // +50 ms per underrun
  private static let decayStepFrames = 1_200      // -25 ms per stable period
  private static let stablePeriod: TimeInterval = 10
  private static let maxTargetFrames = 19_200     // 400 ms
  private static let capacityFrames = 28_800      // 600 ms; newest dropped beyond
  private var queued = 0
  private var queuedFrames = 0
  private var targetFrames = initialTargetFrames
  private var underruns = 0
  private var stableSince = Date()
  private var counters = YinweiReturnCounters()
  private var epoch: UInt64?
  private var prepared = false
  private var observers: [NSObjectProtocol] = []
  // Listen to laptop: Yinwei is the only audio here (no iPad source app), so
  // it holds the session non-mixable, which the lock-screen controls need,
  // and rides through route changes and interruptions instead of stopping.
  private var listenMode = false
  private var listenVolume: Float = 1
  private var interrupted = false
  var isReady: Bool { prepared && engine.isRunning }
  var status: [String: Any] {
    ["received": counters.received, "accepted": counters.accepted,
     "played": counters.played, "queued": queued, "ready": isReady,
     "underruns": underruns, "bufferMs": targetFrames / 48,
     "queuedMs": queuedFrames / 48, "interrupted": interrupted]
  }

  func prepare(listen: Bool = false) throws {
    stop()
    listenMode = listen
    // A previous listening gain must never carry into the capture route.
    player.volume = listen ? listenVolume : 1
    counters.begin()
    targetFrames = Self.initialTargetFrames
    underruns = 0
    stableSince = Date()
    let session = AVAudioSession.sharedInstance()
    // No .duckOthers: on device it did not stop the source app's original
    // audio and may lower the level ReplayKit captures for the laptop.
    try session.setCategory(.playback, mode: .default,
                            options: listen ? [] : [.mixWithOthers])
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
    // Listen mode drops the queued PCM and plays the live stream on.
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: AVAudioSession.interruptionNotification,
        object: nil, queue: .main) { [weak self] note in
        self?.interruption(note)
      },
      center.addObserver(forName: .AVAudioEngineConfigurationChange,
        object: engine, queue: .main) { [weak self] _ in
        guard let self else { return }
        if !self.listenMode { self.stop() } else if !self.interrupted { self.restart() }
      },
    ]
  }

  /// Local gain only; the capture route ignores this channel method.
  func setVolume(_ volume: Double) {
    guard listenMode, volume.isFinite else { return }
    listenVolume = Float(min(1, max(0, volume)))
    player.volume = listenVolume
  }

  private func interruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    guard listenMode else {
      if type == .began { stop() }
      return
    }
    switch type {
    case .began:
      // A call, Siri or another app's audio: wait for the end.
      interrupted = true
      reset()
    case .ended:
      let options = AVAudioSession.InterruptionOptions(
        rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      guard options.contains(.shouldResume),
            (try? AVAudioSession.sharedInstance().setActive(true)) != nil
      else { stop(); return }
      interrupted = false
      restart()
    @unknown default:
      stop()
    }
  }

  /// Listen mode: play on from the current route (AirPods connected or
  /// removed, or an interruption ended) without giving up the session.
  private func restart() {
    reset()
    guard prepared else { return }
    engine.prepare()
    do { try engine.start() } catch { stop() }
  }

  /// Listen mode: the laptop started a new stream (Live started or stopped,
  /// a seek). Drop queued audio and take its sample rate.
  func newStream(sampleRate: Double) {
    reset()
    epoch = nil
    guard prepared, sampleRate >= 8_000, sampleRate <= 192_000,
          let current = format, current.sampleRate != sampleRate,
          let next = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
    else { return }
    format = next
    engine.disconnectNodeOutput(player)
    engine.connect(player, to: engine.mainMixerNode, format: next)
  }

  func accept(_ data: Data) -> Bool {
    counters.receive()
    guard isReady, data.count >= 64, data.count <= 4152,
          let format else { return false }
    func u32(_ offset: Int) -> UInt32 {
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
    func u64(_ offset: Int) -> UInt64 {
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
    }
    let frames = Int(u32(36))
    guard u32(0) == 0x31574e59, u32(4) == 1, Double(u32(32)) == format.sampleRate,
          frames > 0, frames <= 512, data.count == 56 + frames * 8,
          queuedFrames + frames <= Self.capacityFrames else { return false }
    let value = u64(8)
    if let epoch, epoch != value { return false }
    self.epoch = value
    // No packet skipping here: queuedFrames falls only on .dataPlayedBack,
    // which lags by the output route's latency (~150-250 ms on Bluetooth),
    // so it overstates the backlog and skipping on it chopped the audio.
    if player.isPlaying, targetFrames > Self.initialTargetFrames,
       Date().timeIntervalSince(stableSince) >= Self.stablePeriod {
      targetFrames = max(Self.initialTargetFrames, targetFrames - Self.decayStepFrames)
      stableSince = Date()
    }
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
    let token = counters.generation
    counters.enqueue()
    queued += 1
    queuedFrames += frames
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self, self.counters.generation == token else { return }
        self.counters.complete(token: token)
        self.queued = max(0, self.queued - 1)
        self.queuedFrames = max(0, self.queuedFrames - frames)
        // Ran dry: pause and refill a larger cushion rather than playing
        // each late packet the moment it lands (audible stutter).
        if self.queued == 0 && self.player.isPlaying {
          self.player.pause()
          self.underruns += 1
          self.stableSince = Date()
          self.targetFrames = min(Self.maxTargetFrames,
                                  self.targetFrames + Self.targetStepFrames)
        }
      }
    }
    if queuedFrames >= targetFrames && !player.isPlaying { player.play() }
    return true
  }

  func reset() {
    counters.invalidate()
    queued = 0; queuedFrames = 0
    guard prepared else { return }
    player.stop(); player.reset()
    if listenMode { player.volume = listenVolume }
  }

  func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    listenMode = false; interrupted = false
    reset(); epoch = nil
    guard prepared else { return }
    engine.stop(); engine.disconnectNodeOutput(player); engine.detach(player)
    format = nil; prepared = false
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }
}

/// The real system picker is tapped directly above the room's WebView.
/// Keep this in an existing Runner source file (no Xcode project edits).
final class YinweiListenRoomRoutePickerFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "dev.yinwei/listen_room_airplay"

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
              arguments args: Any?) -> FlutterPlatformView {
    YinweiListenRoomRoutePicker(frame: frame)
  }
}

private final class YinweiListenRoomRoutePicker: NSObject, FlutterPlatformView {
  private let picker: AVRoutePickerView

  init(frame: CGRect) {
    picker = AVRoutePickerView(frame: frame)
    super.init()
    picker.backgroundColor = .clear
    picker.tintColor = UIColor(white: 0.85, alpha: 1)
    picker.activeTintColor = UIColor(red: 0.65, green: 0.78, blue: 1, alpha: 1)
    picker.prioritizesVideoDevices = false
  }

  func view() -> UIView { picker }
}

/// Lock screen and Control Center for "Listen to laptop": shows what the
/// laptop plays and forwards its buttons to Dart, which sends them to the
/// laptop. Enabled only while listening.
final class YinweiNowPlayingController {
  static let channelName = "dev.yinwei/now_playing"
  private let channel: FlutterMethodChannel
  private var targets: [(MPRemoteCommand, Any)] = []

  init(channel: FlutterMethodChannel) { self.channel = channel }

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "enable":
      enable(); result(["ok": true])
    case "disable":
      disable(); result(["ok": true])
    case "update":
      let args = call.arguments as? [String: Any] ?? [:]
      let playing = args["playing"] as? Bool == true
      MPNowPlayingInfoCenter.default().nowPlayingInfo = [
        MPMediaItemPropertyTitle: args["title"] as? String ?? "Yinwei",
        MPMediaItemPropertyArtist: args["artist"] as? String ?? "",
        MPNowPlayingInfoPropertyIsLiveStream: true,
        MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
      ]
      result(["ok": true])
    case "clear":
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      result(["ok": true])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func enable() {
    disable()
    let center = MPRemoteCommandCenter.shared()
    let commands: [(MPRemoteCommand, String)] = [
      (center.playCommand, "play"), (center.pauseCommand, "pause"),
      (center.togglePlayPauseCommand, "toggle"),
      (center.nextTrackCommand, "next"), (center.previousTrackCommand, "previous"),
    ]
    for (command, action) in commands {
      command.isEnabled = true
      let target = command.addTarget { [weak self] _ in
        self?.channel.invokeMethod("command", arguments: action)
        return .success
      }
      targets.append((command, target))
    }
    UIApplication.shared.beginReceivingRemoteControlEvents()
  }

  private func disable() {
    for (command, target) in targets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    targets.removeAll()
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

/// RPSystemBroadcastPickerView sizes its private UIButton from the init frame
/// only. Created at .zero and resized by Auto Layout, the button stays tiny and
/// off-centre, so taps on the visible tile never start the broadcast. This tile
/// keeps Apple's button filling the whole tile; the user taps it directly.
private final class YinweiBroadcastPickerTile: UIView {
  private let picker: RPSystemBroadcastPickerView
  private static let side: CGFloat = 72

  init(preferredExtension: String?) {
    let frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
    picker = RPSystemBroadcastPickerView(frame: frame)
    super.init(frame: frame)
    picker.preferredExtension = preferredExtension
    picker.showsMicrophoneButton = false
    picker.tintColor = .white
    picker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(picker)

    backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)
    layer.cornerRadius = 18
    layer.borderWidth = 1
    layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
    layer.masksToBounds = true
    picker.accessibilityLabel = "Start Yinwei app-audio capture"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override var intrinsicContentSize: CGSize {
    CGSize(width: Self.side, height: Self.side)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    picker.frame = bounds
    for button in pickerButtons() {
      button.frame = picker.bounds
      button.imageView?.contentMode = .scaleAspectFit
    }
  }

  private func pickerButtons() -> [UIButton] {
    picker.subviews.compactMap { $0 as? UIButton }
  }
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

    let picker = YinweiBroadcastPickerTile(
      preferredExtension: YinweiReplayKitProbeChannel.extensionBundleIdentifier
    )

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
