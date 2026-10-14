import AudioToolbox
import CoreMedia
import Foundation
import ReplayKit

/// ReplayKit capture-only gate. It measures `.audioApp` and discards every
/// media buffer after bounded inspection. There is no recorder or network path.
final class SampleHandler: RPBroadcastSampleHandler {
  private let telemetry = YinweiBroadcastTelemetry()

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    telemetry.begin()
  }

  override func broadcastPaused() {
    telemetry.setPhase("paused", active: true)
  }

  override func broadcastResumed() {
    telemetry.setPhase("broadcasting", active: true)
  }

  override func broadcastFinished() {
    telemetry.finish()
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    with sampleBufferType: RPSampleBufferType
  ) {
    switch sampleBufferType {
    case .audioApp:
      telemetry.acceptAppAudio(sampleBuffer)
    case .audioMic:
      telemetry.ignoreMicrophone()
    case .video:
      telemetry.discardVideo()
    @unknown default:
      break
    }
  }
}

private struct YinweiAudioMeasurement {
  let sampleRate: Int
  let channelCount: Int
  let frameCount: Int
  let rmsDb: Double?
  let peakDb: Double?
  let silent: Bool
}

private enum YinweiAudioInspector {
  /// Caps work per callback even if ReplayKit supplies an unexpectedly large buffer.
  private static let maximumScalarSamples = 9_600

  static func inspect(_ sampleBuffer: CMSampleBuffer) -> YinweiAudioMeasurement? {
    guard CMSampleBufferDataIsReady(sampleBuffer),
          let description = CMSampleBufferGetFormatDescription(sampleBuffer),
          let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)
    else { return nil }

    let format = basic.pointee
    let frames = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frames > 0,
          format.mFormatID == kAudioFormatLinearPCM,
          format.mBitsPerChannel == 16 || format.mBitsPerChannel == 32
    else { return nil }

    var needed = 0
    var retainedBlock: CMBlockBuffer?
    let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &needed,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &retainedBlock
    )
    guard sizeStatus == noErr, needed >= MemoryLayout<AudioBufferList>.size else {
      return nil
    }

    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: needed,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    let list = raw.assumingMemoryBound(to: AudioBufferList.self)
    let fillStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &needed,
      bufferListOut: list,
      bufferListSize: needed,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &retainedBlock
    )
    guard fillStatus == noErr else { return nil }

    let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isSigned = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
    var sumSquares = 0.0
    var peak = 0.0
    var inspected = 0

    for buffer in UnsafeMutableAudioBufferListPointer(list) {
      guard inspected < maximumScalarSamples, let data = buffer.mData else { continue }
      if isFloat && format.mBitsPerChannel == 32 {
        let count = min(
          Int(buffer.mDataByteSize) / MemoryLayout<Float>.size,
          maximumScalarSamples - inspected
        )
        let values = data.bindMemory(to: Float.self, capacity: count)
        for index in 0..<count {
          let value = Double(values[index])
          guard value.isFinite else { continue }
          sumSquares += value * value
          peak = max(peak, abs(value))
          inspected += 1
        }
      } else if isSigned && format.mBitsPerChannel == 16 {
        let count = min(
          Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size,
          maximumScalarSamples - inspected
        )
        let values = data.bindMemory(to: Int16.self, capacity: count)
        for index in 0..<count {
          let value = Double(values[index]) / Double(Int16.max)
          sumSquares += value * value
          peak = max(peak, abs(value))
          inspected += 1
        }
      } else if isSigned && format.mBitsPerChannel == 32 {
        let count = min(
          Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size,
          maximumScalarSamples - inspected
        )
        let values = data.bindMemory(to: Int32.self, capacity: count)
        for index in 0..<count {
          let value = Double(values[index]) / Double(Int32.max)
          sumSquares += value * value
          peak = max(peak, abs(value))
          inspected += 1
        }
      }
    }

    guard inspected > 0 else { return nil }
    let rms = sqrt(sumSquares / Double(inspected))
    return YinweiAudioMeasurement(
      sampleRate: Int(format.mSampleRate.rounded()),
      channelCount: Int(format.mChannelsPerFrame),
      frameCount: frames,
      rmsDb: decibels(rms),
      peakDb: decibels(peak),
      silent: inspected > 0 && peak <= 0.0001
    )
  }

  private static func decibels(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value > 0 else { return nil }
    return max(-160, 20 * log10(value))
  }
}

private final class YinweiBroadcastTelemetry {
  private static let appGroup = "group.dev.yinwei.remote.capture"
  private static let statusKey = "yinwei.replaykit.numeric-status.v1"
  private static let flushInterval = 0.25

  private let lock = NSLock()
  private let writeQueue = DispatchQueue(label: "dev.yinwei.broadcast.telemetry")
  private var flushScheduled = false
  private var state = YinweiBroadcastState()

  func begin() {
    mutate {
      $0 = YinweiBroadcastState()
      $0.broadcastActive = true
      $0.broadcastPhase = "broadcasting"
    }
  }

  func setPhase(_ phase: String, active: Bool) {
    mutate {
      $0.broadcastActive = active
      $0.broadcastPhase = phase
    }
  }

  func finish() {
    lock.lock()
    state.broadcastActive = false
    state.broadcastPhase = "finished"
    let snapshot = state.dictionary
    lock.unlock()
    writeQueue.sync { Self.save(snapshot) }
  }

  func acceptAppAudio(_ sampleBuffer: CMSampleBuffer) {
    let measurement = YinweiAudioInspector.inspect(sampleBuffer)
    mutate {
      $0.appAudioBufferCount = Self.increment($0.appAudioBufferCount)
      if let measurement {
        $0.sampleRate = measurement.sampleRate
        $0.channelCount = measurement.channelCount
        $0.lastFrameCount = measurement.frameCount
        $0.lastRmsDb = measurement.rmsDb
        $0.lastPeakDb = measurement.peakDb
        $0.audioSilent = measurement.silent
        $0.receivingAppAudio = !measurement.silent
      } else {
        $0.droppedInspectionBufferCount = Self.increment(
          $0.droppedInspectionBufferCount
        )
      }
    }
  }

  func ignoreMicrophone() {
    mutate {
      $0.ignoredMicrophoneBufferCount = Self.increment(
        $0.ignoredMicrophoneBufferCount
      )
    }
  }

  func discardVideo() {
    mutate {
      $0.discardedVideoBufferCount = Self.increment($0.discardedVideoBufferCount)
    }
  }

  private func mutate(_ body: (inout YinweiBroadcastState) -> Void) {
    lock.lock()
    body(&state)
    let shouldSchedule = !flushScheduled
    if shouldSchedule { flushScheduled = true }
    lock.unlock()
    guard shouldSchedule else { return }

    writeQueue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let snapshot = self.state.dictionary
      self.flushScheduled = false
      self.lock.unlock()
      Self.save(snapshot)
    }
  }

  private static func increment(_ value: Int) -> Int {
    value == Int.max ? value : value + 1
  }

  private static func save(_ snapshot: [String: Any]) {
    UserDefaults(suiteName: appGroup)?.set(snapshot, forKey: statusKey)
  }
}

private struct YinweiBroadcastState {
  var broadcastActive = false
  var broadcastPhase = "idle"
  var appAudioBufferCount = 0
  var ignoredMicrophoneBufferCount = 0
  var discardedVideoBufferCount = 0
  var droppedInspectionBufferCount = 0
  var sampleRate: Int?
  var channelCount: Int?
  var lastFrameCount: Int?
  var lastRmsDb: Double?
  var lastPeakDb: Double?
  var receivingAppAudio = false
  var audioSilent = false

  var dictionary: [String: Any] {
    var value: [String: Any] = [
      "supported": true,
      "broadcastActive": broadcastActive,
      "broadcastPhase": broadcastPhase,
      "appAudioBufferCount": appAudioBufferCount,
      "ignoredMicrophoneBufferCount": ignoredMicrophoneBufferCount,
      "discardedVideoBufferCount": discardedVideoBufferCount,
      "droppedInspectionBufferCount": droppedInspectionBufferCount,
      "receivingAppAudio": receivingAppAudio,
      "audioSilent": audioSilent,
    ]
    if let sampleRate { value["sampleRate"] = sampleRate }
    if let channelCount { value["channelCount"] = channelCount }
    if let lastFrameCount { value["lastFrameCount"] = lastFrameCount }
    if let lastRmsDb, lastRmsDb.isFinite { value["lastRmsDb"] = lastRmsDb }
    if let lastPeakDb, lastPeakDb.isFinite { value["lastPeakDb"] = lastPeakDb }
    return value
  }
}
