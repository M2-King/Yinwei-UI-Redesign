import Foundation

/// Listen-only scheduling policy. Frames use the AVAudioPlayerNode timeline,
/// not .dataPlayedBack (which includes Bluetooth/device presentation latency).
/// No PCM, DSP, audio-session ownership or capture behavior lives here.
struct YinweiListenBuffer {
  static let minimumMs = 120
  static let maximumMs = 400
  static let capacityMs = 600
  static let stableSeconds: TimeInterval = 30

  private(set) var sampleRate: Double = 48_000
  private(set) var targetMs = minimumMs
  private(set) var underruns = 0
  private(set) var scheduledEnd: Int64 = 0
  private(set) var rendered: Int64 = 0
  private(set) var playing = false
  private var stableSince: TimeInterval?
  private(set) var routeMinimumMs = minimumMs
  private(set) var playbackRate: Float = 1
  private(set) var silenceTrimmedFrames: Int64 = 0
  private var excessSince: TimeInterval?

  mutating func configure(privateRoute: Bool) {
    let next = privateRoute ? 80 : Self.minimumMs
    let penalty = max(0, targetMs - routeMinimumMs)
    routeMinimumMs = next
    targetMs = min(Self.maximumMs, next + penalty)
    playbackRate = 1
    excessSince = nil
  }

  /// Pitch-preserving receiver catch-up only, never source or spatial DSP.
  mutating func updateRate(now: TimeInterval) {
    guard playing, let stableSince, now - stableSince >= 2 else {
      playbackRate = 1; excessSince = nil; return
    }
    if queuedMs <= targetMs + 15 {
      playbackRate = 1; excessSince = nil
    } else if queuedMs > targetMs + 30 {
      if excessSince == nil { excessSince = now }
      if now - (excessSince ?? now) >= 2 { playbackRate = 1.01 }
    }
  }

  /// Default catch-up never changes audible samples: at most 1% of a whole
  /// decoded packet verified below -100 dBFS in both channels may be omitted.
  /// This is opportunistic, not a promise of convergence on continuous music.
  mutating func silenceTrim(count: Int, peak: Float, now: TimeInterval) -> Int {
    updateRate(now: now)
    guard playbackRate > 1, peak.isFinite, peak <= 0.00001, count >= 100 else { return 0 }
    let trim = max(1, count / 100)
    silenceTrimmedFrames += Int64(trim)
    return trim
  }

  var queuedFrames: Int64 { max(0, scheduledEnd - rendered) }
  var queuedMs: Int { Int(Double(queuedFrames) * 1000 / sampleRate) }
  var canStart: Bool { !playing && queuedFrames >= frames(milliseconds: targetMs) }

  func frames(milliseconds: Int) -> Int64 {
    Int64(ceil(Double(milliseconds) * sampleRate / 1000))
  }

  mutating func reset(sampleRate: Double) {
    self.sampleRate = sampleRate
    scheduledEnd = 0
    rendered = 0
    playing = false
    stableSince = nil
    playbackRate = 1
    excessSince = nil
    // A seek/route change resets the timeline, not the session's learned target.
  }

  /// True once per starvation episode. The caller pauses the node, then freezes
  /// its final clock before scheduling any refill. Negative startup times and
  /// a missing render clock must never fabricate consumed frames.
  mutating func observe(renderedFrame: Int64, now: TimeInterval, expectedSilence: Bool = false) -> Bool {
    guard playing, renderedFrame >= 0 else { return false }
    rendered = max(rendered, renderedFrame)
    if rendered >= scheduledEnd {
      playing = false
      if !expectedSilence {
        underruns += 1
        targetMs = min(Self.maximumMs, targetMs + 50)
      }
      stableSince = nil
      playbackRate = 1
      excessSince = nil
      return true
    }
    if let stableSince, now - stableSince >= Self.stableSeconds {
      targetMs = max(routeMinimumMs, targetMs - 25)
      self.stableSince = now
    }
    return false
  }

  mutating func freeze(renderedFrame: Int64) {
    rendered = max(rendered, renderedFrame)
  }

  /// Returns the explicit player sample time for this buffer. After starvation
  /// the player clock may have passed the old tail; never schedule in the past.
  mutating func enqueue(frames count: Int) -> Int64? {
    guard count > 0,
          queuedFrames + Int64(count) <= frames(milliseconds: Self.capacityMs)
    else { return nil }
    let start = max(scheduledEnd, rendered)
    scheduledEnd = start + Int64(count)
    return start
  }

  mutating func start(now: TimeInterval) {
    playing = true
    stableSince = now
  }
}
