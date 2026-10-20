import AVFoundation
import AudioToolbox

/// Decodes the laptop's 20 ms Opus packets (YNO1, "High"/"Max" sound
/// quality) with Apple's own Opus decoder (AudioToolbox, iOS 11+), into the
/// same 48 kHz stereo float format the uncompressed stream plays in. No PCM
/// processing, DSP or audio-session ownership lives here.
final class YinweiOpusDecoder {
  static let maxPacketBytes = 1500
  let output: AVAudioFormat
  private let converter: AVAudioConverter
  private let compressed: AVAudioCompressedBuffer

  /// Nil when this device cannot decode Opus: the app then asks the laptop
  /// for the uncompressed stream.
  init?(output: AVAudioFormat? = nil) {
    var description = AudioStreamBasicDescription(
      mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
      mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
      mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    guard let input = AVAudioFormat(streamDescription: &description),
          let output = output ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
          output.sampleRate == 48_000, output.channelCount == 2,
          let converter = AVAudioConverter(from: input, to: output)
    else { return nil }
    self.output = output
    self.converter = converter
    compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1,
                                         maximumPacketSize: Self.maxPacketBytes)
  }

  /// One Opus packet in, its PCM out (960 frames once the decoder is primed);
  /// nil when nothing decodes.
  func decode(_ packet: UnsafeRawBufferPointer) -> AVAudioPCMBuffer? {
    guard let base = packet.baseAddress, packet.count > 0,
          packet.count <= Self.maxPacketBytes,
          let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 2_880)
    else { return nil }
    compressed.data.copyMemory(from: base, byteCount: packet.count)
    compressed.byteLength = UInt32(packet.count)
    compressed.packetCount = 1
    compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
      mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return self.compressed
    }
    guard status != .error, error == nil, pcm.frameLength > 0 else { return nil }
    return pcm
  }

  /// A new stream (seek, new track, quality change): forget the old audio.
  func reset() { converter.reset() }

  /// Peak of a decoded buffer, for the room's level meter.
  static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData else { return 0 }
    var peak: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
      for frame in 0..<Int(buffer.frameLength) {
        peak = max(peak, abs(channels[channel][frame]))
      }
    }
    return peak.isFinite ? min(peak, 1) : 0
  }
}
