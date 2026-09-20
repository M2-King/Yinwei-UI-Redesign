import Flutter
import Foundation
import UIKit

/// Isolated ScreenCaptureKit capture-only probe. Not spatial_core / HRTF / wet output.
enum YinweiScreenAudioProbeChannel {
  static let name = "dev.yinwei/screen_audio_probe"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    let controller = YinweiScreenAudioProbeController()
    channel.setMethodCallHandler { call, result in
      controller.handle(call: call, result: result)
    }
  }
}

protocol YinweiScreenAudioCapturing: AnyObject {
  func isAvailable() -> [String: Any]
  func startCapture(result: @escaping FlutterResult)
  func stopCapture(result: @escaping FlutterResult)
  func status() -> [String: Any]
}

final class YinweiScreenAudioProbeController {
  private let capture: YinweiScreenAudioCapturing

  init(capture: YinweiScreenAudioCapturing = YinweiScreenAudioProbeFactory.make()) {
    self.capture = capture
  }

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(capture.isAvailable())
    case "startCapture":
      capture.startCapture(result: result)
    case "stopCapture":
      capture.stopCapture(result: result)
    case "getStatus":
      result(capture.status())
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

enum YinweiScreenAudioProbeFactory {
  static func make() -> YinweiScreenAudioCapturing {
    #if canImport(ScreenCaptureKit)
    if #available(iOS 27.0, *) {
      return YinweiIOS27ScreenAudioCapture()
    }
    #endif
    return YinweiUnavailableScreenAudioCapture(
      reason: "ScreenCaptureKit system-audio probe requires iOS 27 and the iOS 27 SDK"
    )
  }
}

final class YinweiUnavailableScreenAudioCapture: YinweiScreenAudioCapturing {
  init(reason: String) {
    self.reason = reason
  }

  private let reason: String

  func isAvailable() -> [String: Any] {
    [
      "supported": false,
      "sdkCompiled": sdkCompiled,
      "reason": reason,
      "osVersion": UIDevice.current.systemVersion,
    ]
  }

  func startCapture(result: @escaping FlutterResult) {
    result([
      "ok": false,
      "supported": false,
      "reason": reason,
    ])
  }

  func stopCapture(result: @escaping FlutterResult) {
    result(["ok": true, "supported": false])
  }

  func status() -> [String: Any] {
    YinweiScreenAudioProbeStatus.empty(supported: false).asMap()
  }

  private var sdkCompiled: Bool {
    #if canImport(ScreenCaptureKit)
    return true
    #else
    return false
    #endif
  }
}

struct YinweiScreenAudioProbeStatus {
  var supported = false
  var captureActive = false
  var pickerActive = false
  var pickerState = "idle"
  var selectedCaptureMode = "full-display"
  var audioBufferCount = 0
  var microphoneBufferCount = 0
  var screenBufferCount = 0
  var sampleRate: Int?
  var channelCount: Int?
  var lastFrameCount: Int?
  var interleaved: Bool?
  var formatDescription: String?
  var lastCallbackOutputType: String?
  var capturesAudio = false
  var lastRmsDb: Double?
  var lastPeakDb: Double?
  var receivingSystemAudio = false
  var receivingMicrophone = false
  var audioSilent = false
  var pickerCancelled = false
  var excludesCurrentProcessAudioSupported = false
  var excludesCurrentProcessAudio = false
  var lastError: String?

  static func empty(supported: Bool) -> YinweiScreenAudioProbeStatus {
    var status = YinweiScreenAudioProbeStatus()
    status.supported = supported
    return status
  }

  func asMap() -> [String: Any] {
    var map: [String: Any] = [
      "supported": supported,
      "captureActive": captureActive,
      "pickerActive": pickerActive,
      "pickerState": pickerState,
      "selectedCaptureMode": selectedCaptureMode,
      "audioBufferCount": audioBufferCount,
      "microphoneBufferCount": microphoneBufferCount,
      "screenBufferCount": screenBufferCount,
      "capturesAudio": capturesAudio,
      "receivingSystemAudio": receivingSystemAudio,
      "receivingMicrophone": receivingMicrophone,
      "audioSilent": audioSilent,
      "pickerCancelled": pickerCancelled,
      "excludesCurrentProcessAudioSupported": excludesCurrentProcessAudioSupported,
      "excludesCurrentProcessAudio": excludesCurrentProcessAudio,
      "osVersion": UIDevice.current.systemVersion,
    ]
    if let sampleRate { map["sampleRate"] = sampleRate }
    if let channelCount { map["channelCount"] = channelCount }
    if let lastFrameCount { map["lastFrameCount"] = lastFrameCount }
    if let interleaved { map["interleaved"] = interleaved }
    if let formatDescription { map["formatDescription"] = formatDescription }
    if let lastCallbackOutputType { map["lastCallbackOutputType"] = lastCallbackOutputType }
    if let lastRmsDb, lastRmsDb.isFinite { map["lastRmsDb"] = lastRmsDb }
    if let lastPeakDb, lastPeakDb.isFinite { map["lastPeakDb"] = lastPeakDb }
    if let lastError, !lastError.isEmpty { map["lastError"] = lastError }
    return map
  }
}

#if canImport(ScreenCaptureKit)
import AudioToolbox
import CoreAudio
import CoreMedia
import ScreenCaptureKit

@available(iOS 27.0, *)
final class YinweiIOS27ScreenAudioCapture: NSObject, YinweiScreenAudioCapturing, SCStreamOutput,
  SCStreamDelegate, SCContentSharingPickerObserver
{
  private let lock = NSLock()
  private let sampleQueue = DispatchQueue(label: "dev.yinwei.screen-audio-probe")
  private var stream: SCStream?
  private var observerRegistered = false
  private var loggedOutputTypes = Set<String>()
  private var lastAudioLog: TimeInterval = 0
  private var lastNoAudioLog: TimeInterval = 0
  private var snapshot = YinweiScreenAudioProbeStatus.empty(supported: true)

  func isAvailable() -> [String: Any] {
    [
      "supported": true,
      "sdkCompiled": true,
      "pickerAvailable": SCContentSharingPicker.shared.isAvailable,
      "osVersion": UIDevice.current.systemVersion,
    ]
  }

  func startCapture(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      self.presentPicker(result: result)
    }
  }

  func stopCapture(result: @escaping FlutterResult) {
    Task {
      await self.teardown(error: nil, cancelled: false)
      await MainActor.run {
        result(["ok": true])
      }
    }
  }

  func status() -> [String: Any] {
    lock.lock()
    let current = snapshot
    lock.unlock()
    return current.asMap()
  }

  private func presentPicker(result: @escaping FlutterResult) {
    update { status in
      status.supported = true
      status.pickerCancelled = false
      status.lastError = nil
      status.pickerActive = true
      status.pickerState = "presenting"
      status.selectedCaptureMode = "full-display"
    }
    YinweiDeveloperDiagnostics.shared.log("CAPTURE", "picker opened isAvailable=\(SCContentSharingPicker.shared.isAvailable)")
    let picker = SCContentSharingPicker.shared
    if !observerRegistered {
      picker.add(self)
      observerRegistered = true
    }
    var pickerConfig = SCContentSharingPickerConfiguration()
    pickerConfig.showsMicrophoneControl = false
    pickerConfig.showsCameraControl = false
    picker.defaultConfiguration = pickerConfig
    picker.isActive = true
    print("[YINWEI_CAPTURE] picker opened isAvailable=\(picker.isAvailable)")
    if let scene = Self.windowScene() {
      picker.present(from: scene) { _ in }
    } else {
      picker.present()
    }
    result(["ok": true])
  }

  func contentSharingPicker(
    _ picker: SCContentSharingPicker,
    didCancelFor stream: SCStream?
  ) {
    print("[YINWEI_CAPTURE] picker cancelled")
    YinweiDeveloperDiagnostics.shared.log("CAPTURE", "picker cancelled")
    update { status in
      status.pickerActive = false
      status.pickerState = "cancelled"
      status.pickerCancelled = true
      status.lastError = nil
    }
  }

  func contentSharingPicker(
    _ picker: SCContentSharingPicker,
    didUpdateWith filter: SCContentFilter,
    for stream: SCStream?
  ) {
    print("[YINWEI_CAPTURE] picker selected micEnabled=\(filter.isMicrophoneEnabled)")
    YinweiDeveloperDiagnostics.shared.log(
      "CAPTURE",
      "picker selected mode=full-display micEnabled=\(filter.isMicrophoneEnabled) filter=\(String(describing: filter))"
    )
    update { status in
      status.pickerActive = false
      status.pickerState = "selected"
      status.pickerCancelled = false
      status.selectedCaptureMode = "full-display"
      status.lastError = nil
    }
    Task {
      await self.startStream(filter: filter)
    }
  }

  func contentSharingPickerStartDidFailWithError(_ error: any Error) {
    print("[YINWEI_CAPTURE] picker failed \(error)")
    YinweiDeveloperDiagnostics.shared.markCaptureStream(started: false, error: String(describing: error))
    update { status in
      status.pickerActive = false
      status.pickerState = "error"
      status.lastError = String(describing: error)
    }
  }

  private func startStream(filter: SCContentFilter) async {
    await teardown(error: nil, cancelled: false)
    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.sampleRate = 48000
    config.channelCount = 2
    config.excludesCurrentProcessAudio = true
    config.mixesAudioWithMicrophone = false
    print(
      "[YINWEI_CAPTURE] excludesCurrentProcessAudio supported=true selected=\(config.excludesCurrentProcessAudio)"
    )
    if filter.isMicrophoneEnabled {
      print("[YINWEI_CAPTURE] filter requested microphone; probe will not attach microphone output")
    }
    let newStream = SCStream(filter: filter, configuration: config, delegate: self)
    do {
      try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
      try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
      try await newStream.startCapture()
      stream = newStream
      YinweiDeveloperDiagnostics.shared.markCaptureStream(started: true)
      YinweiDeveloperDiagnostics.shared.log(
        "CAPTURE",
        "SCStream started capturesAudio=true microphone=false sampleRate=48000 channelCount=2 excludesCurrentProcessAudio=\(config.excludesCurrentProcessAudio)"
      )
      update { status in
        status.captureActive = true
        status.pickerActive = false
        status.pickerState = "capturing"
        status.selectedCaptureMode = "full-display"
        status.capturesAudio = true
        status.excludesCurrentProcessAudioSupported = true
        status.excludesCurrentProcessAudio = true
        status.audioBufferCount = 0
        status.microphoneBufferCount = 0
        status.screenBufferCount = 0
        status.receivingSystemAudio = false
        status.receivingMicrophone = false
        status.audioSilent = false
        status.lastCallbackOutputType = nil
        status.lastError = nil
      }
      print("[YINWEI_CAPTURE] SCStream started capturesAudio=true sampleRate=48000 channelCount=2")
    } catch {
      print("[YINWEI_CAPTURE] SCStream start failed \(error)")
      YinweiDeveloperDiagnostics.shared.markCaptureStream(
        started: false,
        error: String(describing: error)
      )
      update { status in
        status.captureActive = false
        status.capturesAudio = false
        status.pickerState = "error"
        status.lastError = String(describing: error)
      }
    }
  }

  private func teardown(error: String?, cancelled: Bool) async {
    let current = stream
    stream = nil
    if let current {
      do {
        try await current.stopCapture()
      } catch {
        print("[YINWEI_CAPTURE] stopCapture \(error)")
      }
    }
    let picker = SCContentSharingPicker.shared
    picker.isActive = false
    loggedOutputTypes.removeAll()
    lastAudioLog = 0
    lastNoAudioLog = 0
    if current != nil || error != nil {
      YinweiDeveloperDiagnostics.shared.markCaptureStream(started: false, error: error)
    }
    update { status in
      status.captureActive = false
      status.pickerActive = false
      status.pickerState = cancelled ? "cancelled" : (error == nil ? "idle" : "error")
      status.capturesAudio = false
      if cancelled {
        status.pickerCancelled = true
        status.lastError = nil
      } else if let error {
        status.lastError = error
      }
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    print("[YINWEI_CAPTURE] stream stopped \(error)")
    YinweiDeveloperDiagnostics.shared.markCaptureStream(
      started: false,
      error: String(describing: error)
    )
    update { status in
      status.captureActive = false
      status.capturesAudio = false
      status.pickerState = "error"
      status.lastError = String(describing: error)
    }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    let label: String
    switch type {
    case .screen:
      label = "screen"
    case .audio:
      label = "audio"
    case .microphone:
      label = "microphone"
    @unknown default:
      label = "other(\(type.rawValue))"
    }
    if loggedOutputTypes.insert(label).inserted {
      print("[YINWEI_CAPTURE] outputType=\(label)")
      YinweiDeveloperDiagnostics.shared.log("CAPTURE", "first callback outputType=\(label)")
    }
    update { status in
      status.lastCallbackOutputType = label
    }

    switch type {
    case .screen:
      update { $0.screenBufferCount += 1 }
    case .microphone:
      update { status in
        status.microphoneBufferCount += 1
        status.receivingMicrophone = true
      }
    case .audio:
      inspectAudio(sampleBuffer)
    @unknown default:
      break
    }
  }

  private func inspectAudio(_ sampleBuffer: CMSampleBuffer) {
    let inspection = YinweiAudioBufferInspector.inspect(sampleBuffer)
    let now = Date().timeIntervalSince1970
    update { status in
      status.audioBufferCount += 1
      status.lastCallbackOutputType = "audio"
      if let inspection {
        status.sampleRate = Int(inspection.sampleRate.rounded())
        status.channelCount = inspection.channels
        status.lastFrameCount = inspection.frames
        status.interleaved = inspection.interleaved
        status.formatDescription = inspection.formatSummary
        status.audioSilent = inspection.silent
        if inspection.silent {
          status.lastRmsDb = nil
          status.lastPeakDb = nil
        } else {
          status.lastRmsDb = inspection.rmsDb
          status.lastPeakDb = inspection.peakDb
          status.receivingSystemAudio = true
        }
      }
    }
    lock.lock()
    let count = snapshot.audioBufferCount
    let silent = snapshot.audioSilent
    let rms = snapshot.lastRmsDb
    let peak = snapshot.lastPeakDb
    let rate = snapshot.sampleRate ?? 0
    let channels = snapshot.channelCount ?? 0
    let frames = snapshot.lastFrameCount ?? 0
    let interleaved = snapshot.interleaved
    lock.unlock()

    if count == 1, let inspection {
      print("[YINWEI_CAPTURE] audio format \(inspection.formatSummary) pts=\(inspection.pts)")
      YinweiDeveloperDiagnostics.shared.log(
        "AUDIO",
        "format \(inspection.formatSummary) frames=\(inspection.frames) pts=\(inspection.pts)"
      )
    }
    if now - lastAudioLog >= 1.0 {
      lastAudioLog = now
      if silent || rms == nil {
        print("[YINWEI_CAPTURE] type=audio buffers=\(count) rms=-inf/silent")
        YinweiDeveloperDiagnostics.shared.log(
          "AUDIO",
          "type=audio buffers=\(count) rate=\(rate) channels=\(channels) frames=\(frames) interleaved=\(interleaved.map(String.init) ?? "?") rms=-inf/silent"
        )
      } else if let rms, let peak {
        print(
          String(
            format:
              "[YINWEI_CAPTURE] type=audio buffers=%d rate=%d channels=%d frames=%d rms=%.1fdB peak=%.1fdB",
            count,
            rate,
            channels,
            frames,
            rms,
            peak
          )
        )
        YinweiDeveloperDiagnostics.shared.log(
          "AUDIO",
          String(
            format:
              "type=audio buffers=%d rate=%d channels=%d frames=%d interleaved=%@ rms=%.1fdB peak=%.1fdB",
            count,
            rate,
            channels,
            frames,
            (interleaved ?? false) ? "true" : "false",
            rms,
            peak
          )
        )
      }
    }
  }

  private func update(_ body: (inout YinweiScreenAudioProbeStatus) -> Void) {
    lock.lock()
    body(&snapshot)
    let captureActive = snapshot.captureActive
    let audioCount = snapshot.audioBufferCount
    lock.unlock()
    let now = Date().timeIntervalSince1970
    if captureActive && audioCount == 0 && now - lastNoAudioLog >= 1.0 {
      lastNoAudioLog = now
      print("[YINWEI_CAPTURE] no system-audio buffers received")
      YinweiDeveloperDiagnostics.shared.log("CAPTURE", "no system-audio buffers received")
    }
  }

  private static func windowScene() -> UIWindowScene? {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
  }
}

enum YinweiAudioBufferInspector {
  struct Result {
    var sampleRate: Double
    var channels: Int
    var frames: Int
    var rmsDb: Double
    var peakDb: Double
    var silent: Bool
    var interleaved: Bool
    var pts: String
    var formatSummary: String
  }

  static func inspect(_ sampleBuffer: CMSampleBuffer) -> Result? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format)
    else {
      return nil
    }
    let asbd = asbdPointer.pointee
    let pts = String(format: "%.3f", CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let channels = Int(asbd.mChannelsPerFrame)
    let sampleRate = asbd.mSampleRate
    let bits = Int(asbd.mBitsPerChannel)
    let formatSummary =
      "rate=\(Int(sampleRate)) channels=\(channels) bits=\(bits) float=\(isFloat) interleaved=\(!isNonInterleaved)"

    let flags = UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment)
    var needed = 0
    _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &needed,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: flags,
      blockBufferOut: nil
    )
    guard needed > 0 else { return nil }

    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: needed,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: needed)
    defer { raw.deallocate() }
    let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    var blockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: abl,
      bufferListSize: needed,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: flags,
      blockBufferOut: &blockBuffer
    )
    defer { blockBuffer = nil }
    guard status == noErr else { return nil }

    var peak: Double = 0
    var sumSq: Double = 0
    var n = 0
    let buffers = UnsafeMutableAudioBufferListPointer(abl)
    for buffer in buffers {
      guard let data = buffer.mData else { continue }
      let byteCount = Int(buffer.mDataByteSize)
      if isFloat && bits == 32 {
        let count = byteCount / MemoryLayout<Float>.stride
        let samples = data.bindMemory(to: Float.self, capacity: count)
        for i in 0..<count {
          let value = Double(samples[i])
          peak = max(peak, abs(value))
          sumSq += value * value
        }
        n += count
      } else if isFloat && bits == 64 {
        let count = byteCount / MemoryLayout<Double>.stride
        let samples = data.bindMemory(to: Double.self, capacity: count)
        for i in 0..<count {
          let value = samples[i]
          peak = max(peak, abs(value))
          sumSq += value * value
        }
        n += count
      } else if !isFloat && bits == 16 {
        let count = byteCount / MemoryLayout<Int16>.stride
        let samples = data.bindMemory(to: Int16.self, capacity: count)
        for i in 0..<count {
          let value = Double(samples[i]) / 32768.0
          peak = max(peak, abs(value))
          sumSq += value * value
        }
        n += count
      } else if !isFloat && bits == 32 {
        let count = byteCount / MemoryLayout<Int32>.stride
        let samples = data.bindMemory(to: Int32.self, capacity: count)
        for i in 0..<count {
          let value = Double(samples[i]) / 2147483648.0
          peak = max(peak, abs(value))
          sumSq += value * value
        }
        n += count
      }
    }

    let frames = n == 0 ? Int(CMSampleBufferGetNumSamples(sampleBuffer)) : (isNonInterleaved ? n : n / max(channels, 1))
    let rms = n > 0 ? sqrt(sumSq / Double(n)) : 0
    let silent = n == 0 || peak < 1.0e-7
    let rmsDb = silent || rms <= 0 ? -Double.infinity : 20.0 * log10(rms)
    let peakDb = silent || peak <= 0 ? -Double.infinity : 20.0 * log10(peak)
    return Result(
      sampleRate: sampleRate,
      channels: max(channels, 1),
      frames: frames,
      rmsDb: rmsDb,
      peakDb: peakDb,
      silent: silent,
      interleaved: !isNonInterleaved,
      pts: pts,
      formatSummary: formatSummary
    )
  }
}
#endif
