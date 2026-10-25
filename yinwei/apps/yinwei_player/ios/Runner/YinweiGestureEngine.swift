import Foundation

/// All geometry stays on the Vision queue. Units: mirrored frame-width positions,
/// wrist-to-middle-MCP hand sizes, milliseconds on the capture host clock.
struct YinweiGestureConfig {
  static let version = 2
  var commitHands = 0.34, commitHandsV = 0.34, swipeSpeed = 2.4
  var swipeRatio = 1.2, rearmMs = 250.0, returnMs = 600.0
  let startSpeed = 1.5, stopSpeed = 0.8, straight = 0.6
  let stillSpeed = 0.45, minimumPoseMs = 150.0, poseEvidence = 150.0

  init(_ values: [String: Any] = [:]) {
    guard (values["version"] as? Int) == Self.version else { return }
    func easier(_ key: String, _ normal: Double, _ floor: Double) -> Double {
      guard let n = values[key] as? NSNumber, n.doubleValue.isFinite else { return normal }
      return min(normal, max(floor, n.doubleValue))
    }
    commitHands = easier("commitHands", commitHands, 0.25)
    commitHandsV = easier("commitHandsV", commitHandsV, 0.25)
    swipeSpeed = easier("swipeSpeed", swipeSpeed, 2.2)
    swipeRatio = easier("swipeRatio", swipeRatio, 1.05)
    rearmMs = easier("rearmMs", rearmMs, 100)
    returnMs = easier("returnMs", returnMs, 0)
  }
}

/// Casiez/Roussel/Vogel (CHI 2012): derivative low pass, then speed-adaptive
/// position low pass. The derivative is taken from successive RAW samples.
struct YinweiOneEuro {
  private var raw: Double?, filtered = 0.0
  private(set) var derivative = 0.0
  mutating func sample(_ x: Double, dt: Double, scale: Double = 1) -> Double {
    guard let previous = raw else { raw = x; filtered = x; return x }
    func alpha(_ cutoff: Double) -> Double { 1 / (1 + 1 / (2 * .pi * cutoff * dt)) }
    let a = alpha(1)
    derivative += a * ((x - previous) / dt - derivative)
    let cutoff = 1.2 + 400 * abs(derivative) / max(0.04, scale)
    filtered += alpha(cutoff) * (x - filtered)
    raw = x
    return filtered
  }
}

struct YinweiGestureStroke {
  let event: String
  let t: Double, travel: Double, peak: Double, ratio: Double, gap: Double?
  let fired: Bool
  var values: [String: Any] {
    ["event": event, "t": t, "travel": travel, "peak": peak,
     "ratio": min(99, ratio), "gap": gap.map { $0 as Any } ?? NSNull(), "fired": fired]
  }
}

struct YinweiGestureDecision {
  var event: String? = nil
  var t = 0.0, latencyMs = 0.0
  var pose: String? = nil
  var progress = 0.0
  var stroke: YinweiGestureStroke? = nil
}

final class YinweiGestureEngine {
  private struct Point { var t: Double, x: Double, y: Double, s: Double }
  private struct Stroke {
    var start: Point, farthest: Point
    var armedT: Double
    var path: Double, far: Double, peak: Double
    var moving = 1, high = 0, consecutiveHigh = 0, slow = 0
    var gapMs = 0.0
    var fired = false, ignoredReturn = false
    var recent: [Double] = []
    var points: [Point]
  }
  private struct PoseEvidence { var value = 0.0, first: Double?, fired = false }
  var config: YinweiGestureConfig
  private var fx = YinweiOneEuro(), fy = YinweiOneEuro(), fs = YinweiOneEuro()
  private var previous: Point?, rawPrevious: Point?, stroke: Stroke?
  private var lastT = -Double.infinity, lastSeen = -Double.infinity
  private var lastCommit = -Double.infinity, lastEnd: Double?
  private var rearmed = true
  private var returnedWithoutRest = false
  private var restMs = 0.0
  private var settled = true
  private var history: [Point] = []
  private var missing = false
  private var lastReal: (horizontal: Bool, sign: Double, end: Double)?
  private var evidence: [String: PoseEvidence] = [:]
  private let poses = ["Open_Palm", "Closed_Fist", "Victory", "Thumb_Up"]

  init(config: YinweiGestureConfig = YinweiGestureConfig()) { self.config = config }
  func reset() {
    fx = YinweiOneEuro(); fy = YinweiOneEuro(); fs = YinweiOneEuro()
    previous = nil; rawPrevious = nil; stroke = nil; evidence = [:]
    lastT = -.infinity; lastSeen = -.infinity; lastCommit = -.infinity
    lastEnd = nil; lastReal = nil; rearmed = true; returnedWithoutRest = false; history = []
    restMs = 0; settled = true; missing = false
  }

  private func measure(_ k: Stroke) -> (event: String, horizontal: Bool, sign: Double, main: Double, ratio: Double, need: Double, straight: Double) {
    let dx = k.farthest.x - k.start.x, dy = k.farthest.y - k.start.y
    let horizontal = abs(dx) >= abs(dy), main = max(abs(dx), abs(dy)), cross = min(abs(dx), abs(dy))
    // Fast flicks can commit at 65% distance (the owner's original safety floor).
    // Account for cross-axis speed only on clearly slanted, still-dominant paths;
    // an ordinary short straight fidget retains the full distance requirement.
    let ratio = main / max(0.000001, cross)
    let part = k.peak >= 6 ? 0.65 : k.peak >= 5 || (ratio <= 2 && k.peak >= 4) ? 0.85 : 1
    let need = max((horizontal ? config.commitHands : config.commitHandsV) * k.start.s * part,
                   horizontal ? 0.045 : 0.036)
    return (horizontal ? (dx < 0 ? "swipeLeft" : "swipeRight") : (dy < 0 ? "swipeUp" : "swipeDown"),
            horizontal, (horizontal ? dx : dy) < 0 ? -1 : 1, main, main / max(0.000001, cross),
            need, min(1, k.far / max(0.000001, k.path)))
  }

  private func isReturn(_ k: Stroke) -> Bool {
    let m = measure(k)
    guard let last = lastReal else { return false }
    return last.horizontal == m.horizontal && last.sign == -m.sign && k.start.t - last.end < config.returnMs
  }

  private func finish(_ k: Stroke) -> YinweiGestureStroke {
    let m = measure(k)
    let summary = YinweiGestureStroke(event: m.event, t: k.start.t, travel: m.main / k.start.s,
      peak: k.peak, ratio: m.ratio, gap: lastEnd.map { max(0, k.start.t - $0) }, fired: k.fired)
    lastEnd = k.farthest.t
    // An ignored return must never replace the real flick (left/back/left stays left/left).
    if !isReturn(k), k.peak >= 3, m.main >= m.need * 0.5 {
      lastReal = (m.horizontal, m.sign, k.farthest.t)
    }
    return summary
  }

  private func commit(_ k: inout Stroke, t: Double, exiting: Bool = false) -> Bool {
    guard !k.fired, !k.ignoredReturn else { return false }
    let m = measure(k)
    guard m.main >= m.need * (exiting ? 0.7 : 1), m.ratio >= config.swipeRatio,
          m.straight >= config.straight, k.moving >= 2, k.peak >= 3,
          (exiting ? (k.recent.max() ?? 0) >= 4 : k.high >= 2),
          t - k.start.t <= 900 else { return false }
    if let a = k.points.first, let b = k.points.last {
      let windowMain = max(abs(b.x - a.x), abs(b.y - a.y))
      var path = 0.0
      for i in 1..<k.points.count { path += hypot(k.points[i].x - k.points[i-1].x, k.points[i].y - k.points[i-1].y) }
      guard windowMain >= m.need * (exiting ? 0.7 : 1),
            hypot(b.x - a.x, b.y - a.y) / max(0.000001, path) >= config.straight else { return false }
    }
    if isReturn(k) { k.ignoredReturn = true; returnedWithoutRest = !settled; return false }
    // Distinct strokes re-arm after one slow frame; otherwise a new stroke must wait 250 ms.
    if t - lastCommit < config.rearmMs && !rearmed { return false }
    // An uninterrupted oscillating wave has no rest between its flick/recoil cycles.
    // Keep the old anti-wave bound for that case; a real slow frame immediately
    // re-arms a deliberate second same-direction flick, including at 300 ms.
    if returnedWithoutRest && !settled && t - lastCommit < 400 { return false }
    k.fired = true; lastCommit = t; rearmed = false; returnedWithoutRest = false; settled = false; restMs = 0
    return true
  }

  func feed(t: Double, pose: YinweiHandPose?) -> YinweiGestureDecision {
    var out = YinweiGestureDecision(t: t)
    guard t.isFinite, t > lastT else { return out }
    let dtMs = lastT.isFinite ? min(100, t - lastT) : 0
    lastT = t
    guard let p = pose, p.x.isFinite, p.y.isFinite, p.size.isFinite, p.size > 0 else {
      missing = true
      evidence = [:] // A dropout never carries pose evidence across the gap.
      if var k = stroke {
        if commit(&k, t: t, exiting: true) {
          out.event = measure(k).event; out.latencyMs = t - k.armedT
          out.stroke = finish(k); stroke = nil
        } else if t - lastSeen > 150 { out.stroke = finish(k); stroke = nil }
        else { stroke = k }
      }
      if t - lastSeen > 150 {
        previous = nil; rawPrevious = nil; history = []
        fx = YinweiOneEuro(); fy = YinweiOneEuro(); fs = YinweiOneEuro()
      }
      return out
    }
    if t - lastSeen > 150 {
      previous = nil; rawPrevious = nil; stroke = nil; history = []; evidence = [:]
      fx = YinweiOneEuro(); fy = YinweiOneEuro(); fs = YinweiOneEuro()
    }
    if missing, var k = stroke { k.gapMs = min(150, k.gapMs + t - lastSeen); stroke = k }
    missing = false; lastSeen = t
    let dt = max(0.001, (t - (previous?.t ?? t - 33)) / 1000)
    let s = max(0.04, fs.sample(p.size, dt: dt))
    let q = Point(t: t, x: fx.sample(p.x, dt: dt, scale: s), y: fy.sample(p.y, dt: dt, scale: s), s: s)
    history.append(q)
    while history.count > 2 && t - history[1].t > 150 { history.removeFirst() }
    var speed = 0.0, rawSpeed = 0.0, dx = 0.0, dy = 0.0
    if let prev = previous {
      dx = q.x - prev.x; dy = q.y - prev.y
      speed = hypot(dx, dy) / s / dt
    }
    if let raw = rawPrevious { rawSpeed = hypot(p.x - raw.x, p.y - raw.y) / s / dt }
    if speed < config.stopSpeed && rawSpeed < config.stopSpeed {
      rearmed = true; restMs += dt * 1000
      if restMs >= 60 { settled = true }
    } else { restMs = 0 }
    func begin(_ a: Point, _ b: Point) -> Stroke {
      let d = hypot(b.x - a.x, b.y - a.y)
      return Stroke(start: a, farthest: b, armedT: b.t, path: d, far: d, peak: speed,
                    high: speed >= config.swipeSpeed && rawSpeed >= config.stopSpeed ? 1 : 0,
                    consecutiveHigh: speed >= config.swipeSpeed && rawSpeed >= config.stopSpeed ? 1 : 0,
                    recent: [speed], points: [a, b])
    }
    if var k = stroke {
      k.peak = max(k.peak, speed); k.recent.append(speed)
      if k.recent.count > 3 { k.recent.removeFirst() }
      k.slow = speed < config.stopSpeed || rawSpeed < config.stopSpeed ? k.slow + 1 : 0
      // The raw-motion guard prevents a single bad jump followed by a filter tail
      // from inventing two consecutive moving camera frames.
      k.consecutiveHigh = speed >= config.swipeSpeed && rawSpeed >= config.stopSpeed ? k.consecutiveHigh + 1 : 0
      k.high = max(k.high, k.consecutiveHigh)
      if rawSpeed >= config.stopSpeed { k.moving += 1 }
      k.path += hypot(dx, dy); k.points.append(q)
      // Preserve up to 150 ms of missing tracking in the active-motion window.
      // A 100 ms dropout must not erase the first half of the same swipe.
      while k.points.count > 2 && t - k.points[1].t > 150 + k.gapMs { k.points.removeFirst() }
      let d = hypot(q.x - k.start.x, q.y - k.start.y)
      if d >= k.far { k.far = d; k.farthest = q }
      else if k.far - d >= 0.15 * s && speed >= config.startSpeed &&
                dx * (k.farthest.x - k.start.x) + dy * (k.farthest.y - k.start.y) < 0 {
        out.stroke = finish(k); k = begin(k.farthest, q)
      }
      if commit(&k, t: t) { out.event = measure(k).event; out.latencyMs = t - k.armedT }
      if k.slow >= 2 || t - k.start.t > 1500 {
        out.stroke = finish(k); stroke = nil
      } else { stroke = k }
    } else if let prev = previous, speed >= config.startSpeed, rawSpeed >= config.startSpeed {
      // Displacement includes the pre-arm part of this natural stroke in the
      // 150 ms window; latency starts at the actual speed-crossing frame.
      let a = history.first ?? prev
      stroke = begin(a, q)
      stroke?.points = history
    }
    previous = q; rawPrevious = Point(t: t, x: p.x, y: p.y, s: s)
    let validPose = p.score >= 0.6 && p.margin.isFinite && poses.contains(p.gesture ?? "") ? p.gesture : nil
    out.pose = validPose
    for name in poses {
      var e = evidence[name] ?? PoseEvidence()
      if p.score < 0.6 || validPose == nil {
        e = PoseEvidence()
      } else if validPose != name {
        e.value = max(0, e.value - dtMs * 4); e.first = nil
        if e.value < 30 { e.fired = false }
      } else if hypot(fx.derivative, fy.derivative) / s > config.stillSpeed || out.event != nil {
        e.value = 0; e.first = nil // Movement clears evidence, but cannot unlatch a held pose.
      } else {
        if e.first == nil { e.first = t }
        e.value += min(1, max(0, p.margin)) * (e.first == t ? 0 : dtMs)
        out.progress = min(1, e.value / config.poseEvidence)
        // The low-pass velocity rejects sustained motion. A single noisy or first
        // moving frame also defers commitment until a quiet frame confirms it;
        // otherwise a pose at 149 ms could fire just as a swipe starts.
        if !e.fired, speed <= config.stillSpeed, e.value >= config.poseEvidence,
           t - (e.first ?? t) >= config.minimumPoseMs {
          e.fired = true; out.event = name; out.latencyMs = t - (e.first ?? t)
        }
      }
      evidence[name] = e
    }
    return out
  }
}
