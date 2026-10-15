import AudioToolbox
import AVFoundation
import Darwin
import CoreMedia
import Foundation
import ReplayKit

/// ReplayKit audio probe and optional host-owned, memory-only live IPC.
/// Video/microphone are discarded; the extension never owns network credentials.
final class SampleHandler: RPBroadcastSampleHandler {
  private let telemetry = YinweiBroadcastTelemetry()
  private let remotePCM = YinweiRemotePCMWriter()

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    telemetry.begin()
    remotePCM.begin()
  }

  override func broadcastPaused() {
    telemetry.setPhase("paused", active: true)
    remotePCM.pause()
  }

  override func broadcastResumed() {
    telemetry.setPhase("broadcasting", active: true)
    remotePCM.begin()
  }

  override func broadcastFinished() {
    telemetry.finish()
    remotePCM.pause()
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    with sampleBufferType: RPSampleBufferType
  ) {
    switch sampleBufferType {
    case .audioApp:
      telemetry.acceptAppAudio(sampleBuffer)
      remotePCM.tryAccept(sampleBuffer)
    case .audioMic:
      telemetry.ignoreMicrophone()
    case .video:
      telemetry.discardVideo()
    @unknown default:
      break
    }
  }
}

/// Kernel-memory IPC only. Never writes audio or a network grant into the
/// App Group container. Signer-managed fallback groups remain numeric-only.
private final class YinweiRemotePCMWriter {
  private let lock = NSLock()
  private let worker = DispatchQueue(label: "dev.yinwei.capture.ipc")
  private var pending: [CMSampleBuffer] = []
  private var scheduled = false
  private var active = false
  private var generation: UInt64 = 0
  private var descriptor: Int32 = -1
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var partial = [Int16](repeating: 0, count: 960)
  private var partialCount = 0
  private var gap = true
  private var lastConnect = Date.distantPast
  private var lastEndPTS: Double?
  private let path: String? = {
    let group = YinweiProvisionedBroadcastAppGroup.resolve(in: .main)
    guard group == "group.dev.yinwei.remote.capture" else { return nil }
    return FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: group
    )?.appendingPathComponent("yw.sock").path
  }()

  func begin() { lock.lock(); active = true; generation &+= 1; lock.unlock() }
  func pause() {
    lock.lock(); active = false; generation &+= 1; pending.removeAll(); lock.unlock()
    worker.async { self.disconnect() }
  }

  func tryAccept(_ sample: CMSampleBuffer) {
    guard path != nil, lock.try() else { return }
    guard active, pending.count < 8,
          CMSampleBufferGetNumSamples(sample) <= 4_800 else {
      // No retained buffer and no waiting on the ReplayKit callback.
      lock.unlock(); return
    }
    pending.append(sample)
    if scheduled { lock.unlock(); return }
    scheduled = true
    lock.unlock()
    worker.async { self.drain() }
  }

  private func drain() {
    while true {
      lock.lock()
      guard active, !pending.isEmpty else {
        scheduled = false; lock.unlock(); return
      }
      let sample = pending.removeFirst()
      let token = generation
      lock.unlock()
      guard connectIfNeeded(), let source = copyAudio(sample) else { continue }
      let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
      if let end = lastEndPTS, pts.isFinite, abs(pts - end) > 0.002 {
        converter?.reset(); partialCount = 0; gap = true
      }
      lastEndPTS = pts.isFinite ? pts + Double(source.frameLength) / source.format.sampleRate : nil
      if inputFormat != source.format {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16,
          sampleRate: 48_000, channels: 2, interleaved: true) else { continue }
        inputFormat = source.format
        converter = AVAudioConverter(from: source.format, to: output)
        partialCount = 0; gap = true
      }
      guard let converter,
            let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
              frameCapacity: AVAudioFrameCount(min(32_000,
                ceil(Double(source.frameLength) * 48_000 / source.format.sampleRate) + 64)))
      else { continue }
      var supplied = false
      var error: NSError?
      let status = converter.convert(to: converted, error: &error) { _, result in
        if supplied { result.pointee = .noDataNow; return nil }
        supplied = true; result.pointee = .haveData; return source
      }
      guard status != .error, error == nil,
            let pcm = converted.int16ChannelData?[0] else { gap = true; continue }
      lock.lock(); let current = active && generation == token; lock.unlock()
      guard current else { disconnect(); continue }
      for i in 0..<(Int(converted.frameLength) * 2) {
        partial[partialCount] = pcm[i]; partialCount += 1
        if partialCount == 960 {
          sendChunk(); partialCount = 0
        }
      }
    }
  }

  private func copyAudio(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard CMSampleBufferDataIsReady(sample),
          let desc = CMSampleBufferGetFormatDescription(sample),
          let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
          basic.pointee.mFormatID == kAudioFormatLinearPCM,
          basic.pointee.mChannelsPerFrame >= 1,
          basic.pointee.mChannelsPerFrame <= 2,
          basic.pointee.mSampleRate >= 8_000,
          basic.pointee.mSampleRate <= 192_000,
          let format = AVAudioFormat(streamDescription: basic),
          let result = AVAudioPCMBuffer(pcmFormat: format,
            frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample)))
    else { return nil }
    var needed = 0
    var retained: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
      bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
      blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0, blockBufferOut: &retained) == noErr,
      needed >= MemoryLayout<AudioBufferList>.size, needed <= 4096 else { return nil }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: needed,
      alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let list = raw.assumingMemoryBound(to: AudioBufferList.self)
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
      bufferListSizeNeededOut: &needed, bufferListOut: list, bufferListSize: needed,
      blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0, blockBufferOut: &retained) == noErr else { return nil }
    result.frameLength = result.frameCapacity
    let source = UnsafeMutableAudioBufferListPointer(list)
    let target = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
    guard source.count == target.count else { return nil }
    for i in 0..<source.count {
      guard let src = source[i].mData, let dst = target[i].mData,
            source[i].mDataByteSize <= target[i].mDataByteSize else { return nil }
      memcpy(dst, src, Int(source[i].mDataByteSize))
    }
    return result
  }

  private func connectIfNeeded() -> Bool {
    if descriptor >= 0 { return true }
    guard let path, Date().timeIntervalSince(lastConnect) > 0.5 else { return false }
    lastConnect = Date()
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { dst in
      bytes.withUnsafeBytes { src in dst.copyBytes(from: src) }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    var bufferSize: Int32 = 16_384
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { Darwin.close(fd); return false }
    descriptor = fd; partialCount = 0; converter?.reset(); gap = true
    return true
  }

  private func sendChunk() {
    guard descriptor >= 0 else { gap = true; return }
    var packet = Data()
    for value in [UInt32(0x31434e59), 48_000, 480, gap ? 1 : 0] {
      var le = value.littleEndian
      withUnsafeBytes(of: &le) { packet.append(contentsOf: $0) }
    }
    partial.withUnsafeBytes { packet.append(contentsOf: $0) }
    let sent = packet.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    if sent == packet.count { gap = false }
    else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { gap = true }
    else { disconnect() } // Partial writes close the stream; never corrupt framing.
  }

  private func disconnect() {
    if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    partialCount = 0; converter?.reset(); gap = true
    lastEndPTS = nil
  }
}

/// Mirrors the host's deterministic profile-aware App Group selection. This
/// keeps numeric-only N0 telemetry working when an owner-side signer replaces
/// the product entitlement with signer-managed App Groups.
private enum YinweiProvisionedBroadcastAppGroup {
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
  private static let appGroup = YinweiProvisionedBroadcastAppGroup.resolve(in: .main)
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
