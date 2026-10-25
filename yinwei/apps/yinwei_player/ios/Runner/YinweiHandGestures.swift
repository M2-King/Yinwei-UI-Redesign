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
  private var deliveryPending = false
  private var sink: FlutterEventSink?
  // Session, request and timestamps are confined to queue. Vision runs synchronously there;
  // alwaysDiscardsLateVideoFrames means a busy analysis never queues a backlog of buffers.
  private var session: AVCaptureSession?
  private var videoOutput: AVCaptureVideoDataOutput?
  private let request = VNDetectHumanHandPoseRequest()
  private var lastAnalysis = -Double.infinity
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
            if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
              camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
              camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            camera.unlockForConfiguration()
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: self.queue)
            guard session.canAddOutput(output) else { throw NSError(domain: "hand_gestures", code: 3) }
            session.addOutput(output)
            self.session = session; self.videoOutput = output; self.lastAnalysis = -Double.infinity
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

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    lock.lock(); let token = generation; let enabled = wanted; lock.unlock()
    guard enabled, output === videoOutput, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let t = ProcessInfo.processInfo.systemUptime * 1000
    guard t - lastAnalysis >= 50 else { return }
    lastAnalysis = t
    var frame: [String: Any] = ["t": t, "hand": false]
    do {
      try VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:]).perform([request])
      if let observation = request.results?.first {
        let points = try observation.recognizedPoints(.all)
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
          if let p = points[key] {
            joints[name] = YinweiHandClassifier.userJoint(x: Double(p.location.x), y: Double(p.location.y),
                                                         confidence: Double(p.confidence), aspect: aspect)
          }
        }
        if let pose = YinweiHandClassifier.classify(joints) {
          let gesture: Any = pose.gesture.map { $0 as Any } ?? NSNull()
          frame = ["t": t, "hand": true, "g": gesture,
                   "score": pose.score, "x": pose.x, "y": pose.y, "s": pose.size]
        }
      }
    } catch { /* transient Vision failure behaves exactly like a lost hand */ }
    let values = frame
    lock.lock()
    if deliveryPending { lock.unlock(); return }
    deliveryPending = true
    lock.unlock()
    DispatchQueue.main.async {
      self.lock.lock(); self.deliveryPending = false; self.lock.unlock()
      if self.current(token) { self.sink?(values) }
    }
  }
}
