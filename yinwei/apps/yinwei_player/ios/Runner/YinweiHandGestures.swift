import AVFoundation
import Flutter
import UIKit
import Vision

/// Camera-only feature. No microphone, audio-session writes, files, images across the bridge or network.
final class YinweiHandGestures: NSObject, FlutterStreamHandler, AVCaptureVideoDataOutputSampleBufferDelegate {
  static let name = "dev.yinwei/hand_gestures"
  private let queue = DispatchQueue(label: "dev.yinwei.hand-gestures", qos: .utility)
  private let lock = NSLock()
  private var generation = 0
  private var wanted = false
  private var sink: FlutterEventSink?
  // Session, request and timestamps are confined to queue. Vision runs synchronously there;
  // alwaysDiscardsLateVideoFrames means a busy analysis never queues a backlog of buffers.
  private var session: AVCaptureSession?
  private var videoOutput: AVCaptureVideoDataOutput?
  private let request = VNDetectHumanHandPoseRequest()
  private let engine = YinweiGestureEngine()
  private var lastStatus = -Double.infinity
  private var summaries: [[String: Any]] = []
  private var observers: [NSObjectProtocol] = []

  static func register(messenger: FlutterBinaryMessenger) {
    let service = YinweiHandGestures()
    let methods = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    let events = FlutterEventChannel(name: name + "/frames", binaryMessenger: messenger)
    events.setStreamHandler(service)
    methods.setMethodCallHandler { call, result in
      switch call.method {
      case "permission": result(service.permission)
      case "start": service.start(result)
      case "stop": service.stop(); result(nil)
      case "clock": result(service.hostTime)
      case "configure":
        let values = call.arguments as? [String: Any] ?? [:]
        service.queue.async {
          service.engine.config = YinweiGestureConfig(values)
          service.engine.reset(); service.summaries = []; service.lastStatus = -.infinity
          let t = service.hostTime
          DispatchQueue.main.async { result(t) }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  override init() {
    super.init()
    request.maximumHandCount = 1
    let center = NotificationCenter.default
    for name in [UIApplication.didEnterBackgroundNotification, AVAudioSession.interruptionNotification,
                 AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        if name == AVAudioSession.interruptionNotification,
           (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue != AVAudioSession.InterruptionType.began.rawValue { return }
        self?.stop()
        self?.sink?(["state": "stopped", "permission": self?.permission ?? "denied"])
      })
    }
    observers.append(center.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
      self?.orient()
    })
  }

  deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

  private var permission: String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .notDetermined: return "notDetermined"
    case .authorized: return "granted"
    default: return "denied"
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    stop()
    return nil
  }

  private func current(_ token: Int) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return wanted && generation == token
  }

  private func start(_ result: @escaping FlutterResult) {
    guard UIApplication.shared.applicationState == .active else {
      result(["permission": permission, "active": false]); return
    }
    lock.lock(); generation += 1; wanted = true; let token = generation; lock.unlock()
    let proceed: (Bool) -> Void = { [weak self] allowed in
      DispatchQueue.main.async {
        guard let self = self else { result(nil); return }
        // The permission alert can still leave UIKit inactive for this callback.
        // A real background transition invalidates token and must never resume capture.
        guard allowed, self.current(token), UIApplication.shared.applicationState != .background else {
          if self.current(token) { self.stop() }
          result(["permission": self.permission, "active": false]); return
        }
        let orientation = self.orientation
        self.queue.async {
          do {
            guard self.current(token) else {
              DispatchQueue.main.async { result(["permission": self.permission, "active": false]) }; return
            }
            self.releaseCamera()
            let session = AVCaptureSession()
            session.automaticallyConfiguresApplicationAudioSession = false
            session.usesApplicationAudioSession = false
            session.sessionPreset = .vga640x480
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
              throw NSError(domain: "hand_gestures", code: 1)
            }
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else { throw NSError(domain: "hand_gestures", code: 2) }
            session.addInput(input)
            try camera.lockForConfiguration()
            let ranges = camera.activeFormat.videoSupportedFrameRateRanges
            let fps: Int32 = ranges.contains(where: { $0.minFrameRate <= 60 && $0.maxFrameRate >= 60 }) ? 60 : 30
            if ranges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }) {
              camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
              camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
            }
            camera.unlockForConfiguration()
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: self.queue)
            guard session.canAddOutput(output) else { throw NSError(domain: "hand_gestures", code: 3) }
            session.addOutput(output)
            self.session = session; self.videoOutput = output
            self.engine.reset(); self.summaries = []; self.lastStatus = -.infinity
            self.applyOrientation(orientation)
            guard self.current(token) else {
              self.releaseCamera()
              DispatchQueue.main.async { result(["permission": self.permission, "active": false]) }; return
            }
            session.startRunning()
            if !self.current(token) { self.releaseCamera() }
            DispatchQueue.main.async {
              result(["permission": self.permission, "active": self.current(token) && session.isRunning])
            }
          } catch {
            self.releaseCamera()
            DispatchQueue.main.async {
              if self.current(token) { self.stop() }
              result(FlutterError(code: "camera_unavailable", message: "The front camera is unavailable.", details: nil))
            }
          }
        }
      }
    }
    if permission == "notDetermined" { AVCaptureDevice.requestAccess(for: .video, completionHandler: proceed) }
    else { proceed(permission == "granted") }
  }

  private func stop() {
    lock.lock(); wanted = false; generation += 1; lock.unlock()
    queue.async { self.releaseCamera() }
  }

  private func releaseCamera() {
    videoOutput?.setSampleBufferDelegate(nil, queue: nil)
    session?.stopRunning()
    if let capture = session {
      capture.inputs.forEach { capture.removeInput($0) }
      capture.outputs.forEach { capture.removeOutput($0) }
    }
    session = nil; videoOutput = nil
    engine.reset(); summaries = []; lastStatus = -.infinity
  }

  private var orientation: AVCaptureVideoOrientation {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
    switch scene?.interfaceOrientation {
    case .landscapeLeft: return .landscapeLeft
    case .landscapeRight: return .landscapeRight
    case .portraitUpsideDown: return .portraitUpsideDown
    default: return .portrait
    }
  }

  private func orient() {
    let value = orientation
    queue.async {
      self.applyOrientation(value)
      self.engine.reset(); self.summaries = []; self.lastStatus = -.infinity
      DispatchQueue.main.async { self.sink?(["state": "reset"]) }
    }
  }

  private func applyOrientation(_ value: AVCaptureVideoOrientation) {
    guard let connection = videoOutput?.connection(with: .video) else { return }
    // AVCaptureVideoDataOutput physically rotates the buffers. Vision therefore receives .up.
    if connection.isVideoOrientationSupported { connection.videoOrientation = value }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = false // userJoint mirrors once, after Vision
    }
  }

  private var hostTime: Double {
    CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1000
  }

  private func deliver(_ values: [String: Any], token: Int) {
    // Decisions are rare and are never coalesced or dropped. Status is capped on queue.
    DispatchQueue.main.async {
      if self.current(token) { self.sink?(values) }
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    lock.lock(); let token = generation; let enabled = wanted; lock.unlock()
    guard enabled, output === videoOutput, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
          let clock = session?.masterClock else { return }
    // Capture output PTS is on the session clock. Convert to the host monotonic clock,
    // also exposed by `clock`; queueing and Vision time never alter the frame timestamp.
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let t = CMTimeGetSeconds(CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())) * 1000
    guard t.isFinite else { return }
    var pose: YinweiHandPose?
    do {
      try VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:]).perform([request])
      if let observation = request.results?.first {
        let aspect = Double(CVPixelBufferGetHeight(pixels)) / Double(CVPixelBufferGetWidth(pixels))
        let names: [(String, VNHumanHandPoseObservation.JointName)] = [
          ("wrist", .wrist), ("indexMCP", .indexMCP), ("middleMCP", .middleMCP),
          ("ringMCP", .ringMCP), ("littleMCP", .littleMCP),
          ("indexPIP", .indexPIP), ("indexTip", .indexTip), ("middlePIP", .middlePIP),
          ("middleTip", .middleTip), ("ringPIP", .ringPIP), ("ringTip", .ringTip),
          ("littlePIP", .littlePIP), ("littleTip", .littleTip), ("thumbIP", .thumbIP), ("thumbTip", .thumbTip)
        ]
        var joints: [String: YinweiHandJoint] = [:]
        for (name, key) in names {
          if let p = try? observation.recognizedPoint(key) {
            joints[name] = YinweiHandClassifier.userJoint(x: Double(p.location.x), y: Double(p.location.y),
                                                         confidence: Double(p.confidence), aspect: aspect)
          }
        }
        pose = YinweiHandClassifier.classify(joints)
      }
    } catch { /* transient Vision failure behaves exactly like a lost hand */ }
    let decision = engine.feed(t: t, pose: pose)
    if let event = decision.event {
      deliver(["event": event, "t": t, "latencyMs": decision.latencyMs], token: token)
    }
    // Ended-stroke calibration results contain no positions, joints or camera frames.
    if let stroke = decision.stroke { summaries.append(stroke.values) }
    if t - lastStatus >= 100 {
      lastStatus = t
      let values: [String: Any] = ["t": t, "pose": decision.pose.map { $0 as Any } ?? NSNull(),
                                   "progress": decision.progress, "strokes": summaries]
      summaries = []
      deliver(values, token: token)
    }
  }
}
