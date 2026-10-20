import AVFoundation
import Foundation

// Apple's Opus decoder (YinweiOpusDecoder) against real packets from the
// laptop's encoder: test/fixtures/listen_opus/signal_320k.bin, written by
// crates/yinwei_opus (`write_fixture`): [u32 count] then [u16 len][bytes]
// per 20 ms packet, one second of the test signal at 320 kbit/s.

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), message)
  checks += 1
}

/// The fixture's signal, the same formula as crates/yinwei_opus.
func signal(_ frame: Int) -> (Float, Float) {
  let t = Float(frame) / 48_000
  let sweep = sin(2 * Float.pi * (200 * t + 400 * t * t))
  return (0.3 * sin(2 * Float.pi * 440 * t) + 0.15 * sweep,
          0.3 * sin(2 * Float.pi * 660 * t) + 0.15 * sweep)
}

let path = CommandLine.arguments[1]
let file = try! Data(contentsOf: URL(fileURLWithPath: path))
func u16(_ at: Int) -> Int { Int(file[at]) | Int(file[at + 1]) << 8 }
let count = Int(file[0]) | Int(file[1]) << 8 | Int(file[2]) << 16 | Int(file[3]) << 24
check(count == 50, "fixture holds 50 packets")

guard let decoder = YinweiOpusDecoder() else {
  fatalError("Apple's Opus decoder is unavailable")
}
check(decoder.output.sampleRate == 48_000 && decoder.output.channelCount == 2, "48 kHz stereo out")

var left = [Float](), right = [Float]()
var offset = 4, decodedPackets = 0
for _ in 0..<count {
  let length = u16(offset)
  offset += 2
  let packet = file.subdata(in: offset..<(offset + length))
  offset += length
  if let pcm = packet.withUnsafeBytes({ decoder.decode($0) }) {
    decodedPackets += 1
    check(pcm.frameLength <= 2_880, "one packet's worth at most")
    let ch = pcm.floatChannelData!
    for i in 0..<Int(pcm.frameLength) {
      left.append(ch[0][i]); right.append(ch[1][i])
    }
  }
}
check(offset == file.count, "fixture fully read")
// The decoder may hold back its first packet while it primes.
check(decodedPackets >= count - 2, "packets decode (\(decodedPackets)/\(count))")
check(left.count >= 48_000 - 2 * 960 && left.count <= 48_000, "about one second out (\(left.count))")

// Align by the codec delay (the encoder's 312-sample lookahead, possibly
// trimmed by the decoder), then compare with the original.
func snr(lag: Int) -> Double {
  var s = 0.0, n = 0.0
  for i in 4_800..<(left.count - 4_800) where i + lag < left.count && i + lag >= 0 {
    let (l, r) = signal(i)
    let dl = Double(left[i + lag]) - Double(l), dr = Double(right[i + lag]) - Double(r)
    s += Double(l * l + r * r)
    n += dl * dl + dr * dr
  }
  return 10 * log10(s / max(n, 1e-20))
}
var best = (lag: 0, db: -Double.infinity)
for lag in -1_000...1_000 {
  let db = snr(lag: lag)
  if db > best.db { best = (lag, db) }
}
check(best.db > 25, "decoded audio matches the original (SNR \(best.db) dB at lag \(best.lag))")

// A bad packet fails cleanly; the decoder keeps working after a reset.
let junk = Data([0xff, 0xff, 0xff])
_ = junk.withUnsafeBytes { decoder.decode($0) }
check(Data().withUnsafeBytes({ decoder.decode($0) }) == nil, "an empty packet is rejected")
decoder.reset()
let first = file.subdata(in: 6..<(6 + u16(4)))
var recovered = false
for _ in 0..<3 where !recovered {
  recovered = first.withUnsafeBytes({ decoder.decode($0) }) != nil
}
check(recovered, "decodes again after a reset")

print("PASS: \(checks) Opus decoder checks (SNR \(String(format: "%.1f", best.db)) dB, lag \(best.lag); not AVAudioEngine/device tests)")
