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
  /// Audio packets from the laptop, on a background queue (not the main thread).
  static let audioName = "dev.yinwei/remote_return_audio"
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
    // About 100 packets a second: a busy main thread (the room's WebView, the
    // UI) must not hold them up, so they get a background queue of their own.
    let audioChannel = FlutterMethodChannel(
      name: audioName, binaryMessenger: messenger,
      codec: FlutterStandardMethodCodec.sharedInstance(),
      taskQueue: messenger.makeBackgroundTaskQueue?())
    audioChannel.setMethodCallHandler { call, result in
      controller.handleAudio(call: call, result: result)
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
      write(call: call, result: result)
    case "remoteReturnSupportsOpus":
      result(YinweiOpusDecoder() != nil)
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
    case "openUpdatePackage":
      // The iPad update notice's Download: opens a published iPad package in
      // Safari, which hands it to the signing app. Nothing else is opened.
      guard let text = (call.arguments as? [String: Any])?["url"] as? String,
            let url = URL(string: text), url.scheme == "https",
            url.path.contains("/packages/ios-arm64/"), url.pathExtension == "ipa" else {
        result(false); return
      }
      UIApplication.shared.open(url) { opened in result(opened) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The background audio channel: packets only.
  func handleAudio(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "writeRemoteReturn" {
      write(call: call, result: result)
    } else {
      result(FlutterMethodNotImplemented)
    }
  }

  private func write(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let typed = call.arguments as? FlutterStandardTypedData else {
      result(["accepted": false]); return
    }
    guard let written = remoteReturn.write(typed.data) else {
      result(FlutterError(code: "return_output_interrupted",
        message: "iPad audio output interrupted. Start again explicitly.", details: nil))
      return
    }
    // Opus packets carry no PCM the Dart side can meter: send the decoded peak.
    var value: [String: Any] = ["accepted": written.accepted]
    if let peak = written.peak { value["peak"] = Double(peak) }
    result(value)
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
  // Everything below runs on this serial queue, never the main thread: the
  // room's WebView and the UI keep the main thread busy, and audio waiting
  // on it ran dry ("stuck-stuck"). Packets arrive on a background channel.
  private let audio = DispatchQueue(label: "dev.yinwei.remote-return")
  private lazy var observerQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.underlyingQueue = self.audio
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  private var format: AVAudioFormat?
  // The return path crosses the internet twice (iPad → laptop → iPad), so
  // packets arrive in bursts. Buffer by time and grow the start threshold
  // after each underrun so a jittery link settles instead of stuttering.
  // Underruns also happen when the source pauses, so the threshold must come
  // back down: after 10 s without an underrun it shrinks by 25 ms. It starts
  // (and settles) at 120 ms: 40 ms less delay on a steady link, and a jittery
  // one still grows it after its first underrun.
  private static let initialTargetFrames = 5_760  // 120 ms at 48 kHz
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
  private var listenBuffer = YinweiListenBuffer()
  private var renderTimer: DispatchSourceTimer?
  private var capacityDrops = 0
  private var completionBacklogDrops = 0
  private var configurationChanges = 0
  private var lastRenderCheck: TimeInterval?
  private var maxRenderCheckGapMs = 0.0
  // Opus ("High"/"Max" sound quality): decoded here, then played exactly
  // like the uncompressed stream. Listen mode only.
  private var opusDecoder: YinweiOpusDecoder?
  private var opusPackets = 0
  private var opusFailures = 0
  private var opusPeak: Float?
  // Thread-safe entry points (callers are the main and audio channels).
  var isReady: Bool { audio.sync { ready } }
  var status: [String: Any] { audio.sync { currentStatus } }
  func prepare(listen: Bool = false) throws { try audio.sync { try _prepare(listen: listen) } }
  func setVolume(_ volume: Double) { audio.sync { _setVolume(volume) } }
  func newStream(sampleRate: Double) { audio.sync { _newStream(sampleRate: sampleRate) } }
  func reset() { audio.sync { _reset() } }
  func stop() { audio.sync { _stop() } }
  /// A packet from the laptop: nil while the output isn't running. `peak` is
  /// set for a decoded Opus packet.
  func write(_ data: Data) -> (accepted: Bool, peak: Float?)? {
    audio.sync {
      guard ready else { return nil }
      opusPeak = nil
      let accepted = _accept(data)
      return (accepted, opusPeak)
    }
  }

  private var ready: Bool { prepared && engine.isRunning }
  private var currentStatus: [String: Any] {
    if listenMode { updateListenClock() }
    var value: [String: Any] = ["received": counters.received, "accepted": counters.accepted,
     "played": counters.played, "queued": queued, "ready": ready,
     "underruns": underruns, "bufferMs": targetFrames / 48,
     "queuedMs": queuedFrames / 48, "interrupted": interrupted]
    if listenMode {
      let session = AVAudioSession.sharedInstance()
      value.merge([
        "underruns": listenBuffer.underruns, "bufferMs": listenBuffer.targetMs,
        "queuedMs": listenBuffer.queuedMs, "buffering": !listenBuffer.playing,
        "sampleRate": listenBuffer.sampleRate, "hardwareSampleRate": session.sampleRate,
        "ioBufferMs": session.ioBufferDuration * 1000,
        "outputLatencyMs": session.outputLatency * 1000,
        "presentationLatencyMs": player.outputPresentationLatency * 1000,
        "outputRoute": session.currentRoute.outputs.map { $0.portType.rawValue },
        "capacityDrops": capacityDrops, "completionBacklogDrops": completionBacklogDrops,
        "configurationChanges": configurationChanges,
        "maxRenderCheckGapMs": maxRenderCheckGapMs,
        "opusPackets": opusPackets, "opusFailures": opusFailures,
      ]) { _, new in new }
    }
    return value
  }

  private func _prepare(listen: Bool) throws {
    _stop()
    listenMode = listen
    // A previous listening gain must never carry into the capture route.
    player.volume = listen ? listenVolume : 1
    counters.begin()
    targetFrames = Self.initialTargetFrames
    underruns = 0
    stableSince = Date()
    listenBuffer = YinweiListenBuffer()
    capacityDrops = 0; completionBacklogDrops = 0; configurationChanges = 0
    opusPackets = 0; opusFailures = 0; opusDecoder = nil
    lastRenderCheck = nil; maxRenderCheckGapMs = 0
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
    catch { _stop(); throw error }
    if listen {
      let timer = DispatchSource.makeTimerSource(queue: audio)
      timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10),
                     leeway: .milliseconds(2))
      timer.setEventHandler { [weak self] in self?.updateListenClock() }
      renderTimer = timer
      timer.resume()
    }
    // Do not silently restart a changed/interrupted output route with old PCM.
    // Listen mode drops the queued PCM and plays the live stream on.
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: AVAudioSession.interruptionNotification,
        object: nil, queue: observerQueue) { [weak self] note in
        self?.interruption(note)
      },
      center.addObserver(forName: .AVAudioEngineConfigurationChange,
        object: engine, queue: observerQueue) { [weak self] _ in
        guard let self else { return }
        if self.listenMode { self.configurationChanges += 1 }
        if !self.listenMode { self._stop() } else if !self.interrupted { self.restart() }
      },
    ]
  }

  /// Local gain only; the capture route ignores this channel method.
  private func _setVolume(_ volume: Double) {
    guard listenMode, volume.isFinite else { return }
    listenVolume = Float(min(1, max(0, volume)))
    player.volume = listenVolume
  }

  private func interruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    guard listenMode else {
      if type == .began { _stop() }
      return
    }
    switch type {
    case .began:
      // A call, Siri or another app's audio: wait for the end.
      interrupted = true
      _reset()
    case .ended:
      let options = AVAudioSession.InterruptionOptions(
        rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      guard options.contains(.shouldResume),
            (try? AVAudioSession.sharedInstance().setActive(true)) != nil
      else { _stop(); return }
      interrupted = false
      restart()
    @unknown default:
      _stop()
    }
  }

  /// Listen mode: play on from the current route (AirPods connected or
  /// removed, or an interruption ended) without giving up the session.
  private func restart() {
    _reset()
    guard prepared else { return }
    engine.prepare()
    do { try engine.start() } catch { _stop() }
  }

  /// Listen mode: the laptop started a new stream (Live started or stopped,
  /// a seek). Drop queued audio and take its sample rate.
  private func _newStream(sampleRate: Double) {
    _reset()
    epoch = nil
    if listenMode, sampleRate >= 8_000, sampleRate <= 192_000 {
      listenBuffer.reset(sampleRate: sampleRate)
    }
    guard prepared, sampleRate >= 8_000, sampleRate <= 192_000,
          let current = format, current.sampleRate != sampleRate,
          let next = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
    else { return }
    format = next
    opusDecoder = nil // made for the old format
    engine.disconnectNodeOutput(player)
    engine.connect(player, to: engine.mainMixerNode, format: next)
  }

  private func listenRenderedFrame() -> AVAudioFramePosition? {
    guard let nodeTime = player.lastRenderTime,
          let time = player.playerTime(forNodeTime: nodeTime), time.isSampleTimeValid
    else { return nil }
    return time.sampleTime
  }

  /// Observe before every write as well as on a timer: a burst arriving after
  /// starvation must not hide the empty render queue behind fresh packets.
  private func updateListenClock() {
    guard listenMode, ready, !interrupted else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if let previous = lastRenderCheck {
      maxRenderCheckGapMs = max(maxRenderCheckGapMs, (now - previous) * 1000)
    }
    lastRenderCheck = now
    guard let frame = listenRenderedFrame(),
          listenBuffer.observe(renderedFrame: frame, now: now) else { return }
    player.pause()
    // pause preserves the player timeline. Capture any render quantum that
    // finished between the observation and pause before placing the refill.
    if let pausedFrame = listenRenderedFrame() { listenBuffer.freeze(renderedFrame: pausedFrame) }
  }

  private func _accept(_ data: Data) -> Bool {
    counters.receive()
    // A quiet Opus packet can be a few bytes; PCM is checked exactly below.
    guard ready, data.count > 56, data.count <= 4152,
          let format else { return false }
    func u32(_ offset: Int) -> UInt32 {
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
    func u64(_ offset: Int) -> UInt64 {
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
    }
    var frames = Int(u32(36))
    // YNW1: float PCM. YNO1: the same header, then one 20 ms Opus packet.
    let opus = u32(0) == 0x314f4e59
    guard u32(0) == 0x31574e59 || opus, u32(4) == 1, Double(u32(32)) == format.sampleRate
    else { return false }
    if opus {
      guard listenMode, format.sampleRate == 48_000, frames == 960,
            data.count > 56, data.count <= 56 + YinweiOpusDecoder.maxPacketBytes
      else { return false }
    } else {
      guard frames > 0, frames <= 512, data.count == 56 + frames * 8 else { return false }
    }
    if listenMode {
      updateListenClock()
      if listenBuffer.queuedFrames + Int64(frames) > listenBuffer.frames(milliseconds: YinweiListenBuffer.capacityMs) {
        capacityDrops += 1; return false
      }
      // Separate memory bound for unusually delayed/missing played callbacks.
      // This is not the usable jitter-buffer limit (Bluetooth is downstream).
      if queued >= 2048 { completionBacklogDrops += 1; return false }
    } else if queuedFrames + frames > Self.capacityFrames { return false }
    let value = u64(8)
    if let epoch, epoch != value { return false }
    self.epoch = value
    // No packet skipping here: queuedFrames falls only on .dataPlayedBack,
    // which lags by the output route's latency (~150-250 ms on Bluetooth),
    // so it overstates the backlog and skipping on it chopped the audio.
    if !listenMode, player.isPlaying, targetFrames > Self.initialTargetFrames,
       Date().timeIntervalSince(stableSince) >= Self.stablePeriod {
      targetFrames = max(Self.initialTargetFrames, targetFrames - Self.decayStepFrames)
      stableSince = Date()
    }
    let buffer: AVAudioPCMBuffer
    if opus {
      if opusDecoder == nil { opusDecoder = YinweiOpusDecoder(output: format) }
      guard let decoder = opusDecoder,
            let decoded = data.withUnsafeBytes({
              decoder.decode(UnsafeRawBufferPointer(rebasing: $0[56...]))
            })
      else { opusFailures += 1; return false }
      opusPackets += 1
      opusPeak = YinweiOpusDecoder.peak(decoded)
      buffer = decoded
      frames = Int(decoded.frameLength)
    } else {
      guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frames)), let pcm = pcmBuffer.floatChannelData
      else { return false }
      for frame in 0..<frames {
        for channel in 0..<2 {
          let bits = u32(56 + frame * 8 + channel * 4)
          let sample = Float(bitPattern: bits)
          guard sample.isFinite else { return false }
          pcm[channel][frame] = sample
        }
      }
      pcmBuffer.frameLength = AVAudioFrameCount(frames)
      buffer = pcmBuffer
    }
    var when: AVAudioTime?
    if listenMode {
      guard let start = listenBuffer.enqueue(frames: frames) else { return false }
      when = AVAudioTime(sampleTime: start, atRate: format.sampleRate)
    }
    let token = counters.generation
    counters.enqueue()
    queued += 1
    queuedFrames += frames
    player.scheduleBuffer(buffer, at: when, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
      self?.audio.async { [weak self] in
        guard let self, self.counters.generation == token else { return }
        self.counters.complete(token: token)
        self.queued = max(0, self.queued - 1)
        self.queuedFrames = max(0, self.queuedFrames - frames)
        // Ran dry: pause and refill a larger cushion rather than playing
        // each late packet the moment it lands (audible stutter).
        if !self.listenMode && self.queued == 0 && self.player.isPlaying {
          self.player.pause()
          self.underruns += 1
          self.stableSince = Date()
          self.targetFrames = min(Self.maxTargetFrames,
                                  self.targetFrames + Self.targetStepFrames)
        }
      }
    }
    if listenMode {
      if listenBuffer.canStart {
        listenBuffer.start(now: ProcessInfo.processInfo.systemUptime)
        player.play()
      }
    } else if queuedFrames >= targetFrames && !player.isPlaying { player.play() }
    return true
  }

  private func _reset() {
    counters.invalidate()
    queued = 0; queuedFrames = 0
    listenBuffer.reset(sampleRate: format?.sampleRate ?? 48_000)
    opusDecoder?.reset()
    lastRenderCheck = nil
    guard prepared else { return }
    player.stop(); player.reset()
    if listenMode { player.volume = listenVolume }
  }

  private func _stop() {
    renderTimer?.cancel(); renderTimer = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    listenMode = false; interrupted = false
    _reset(); epoch = nil
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
