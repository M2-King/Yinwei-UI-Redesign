import Foundation

/// Pure geometry, independent of Vision/Flutter so the macOS Swift harness can compile it.
/// Coordinates are the upright user's mirrored view: X right, Y down, in frame-width units.
struct YinweiHandJoint {
  let x: Double
  let y: Double
  let confidence: Double
}

struct YinweiHandPose {
  let gesture: String?
  let score: Double
  let x: Double
  let y: Double
  let size: Double
}

enum YinweiHandClassifier {
  static let minimumConfidence = 0.3
  // A tip must exceed its PIP's wrist distance by 15% of wrist-to-middle-MCP.
  // The dead band is deliberately unknown, rather than interpreting uncertain fingers as curled.
  static let extensionMargin = 0.15

  static func classify(_ joints: [String: YinweiHandJoint]) -> YinweiHandPose? {
    func joint(_ key: String) -> YinweiHandJoint? {
      guard let p = joints[key], p.x.isFinite, p.y.isFinite,
            p.confidence.isFinite, p.confidence >= minimumConfidence else { return nil }
      return p
    }
    func distance(_ a: YinweiHandJoint, _ b: YinweiHandJoint) -> Double {
      hypot(a.x - b.x, a.y - b.y)
    }
    let palmKeys = ["wrist", "indexMCP", "middleMCP", "ringMCP", "littleMCP"]
    let palm = palmKeys.compactMap(joint)
    guard palm.count == palmKeys.count, let wrist = joint("wrist"),
          let middle = joint("middleMCP") else { return nil }
    let size = distance(wrist, middle)
    guard size > 0.0001 else { return nil }
    let x = palm.reduce(0) { $0 + $1.x } / 5
    let y = palm.reduce(0) { $0 + $1.y } / 5
    var required = palm
    var fingers: [Bool] = []
    for finger in ["index", "middle", "ring", "little"] {
      guard let tip = joint(finger + "Tip"), let pip = joint(finger + "PIP") else {
        return YinweiHandPose(gesture: nil, score: 0, x: x, y: y, size: size)
      }
      required += [tip, pip]
      let delta = distance(wrist, tip) - distance(wrist, pip)
      if delta > size * extensionMargin { fingers.append(true) }
      else if delta <= 0 { fingers.append(false) }
      else { return YinweiHandPose(gesture: nil, score: 0, x: x, y: y, size: size) }
    }
    var gesture: String?
    if fingers.allSatisfy({ $0 }) { gesture = "Open_Palm" }
    else if fingers == [true, true, false, false] { gesture = "Victory" }
    else if fingers.allSatisfy({ !$0 }) {
      guard let tip = joint("thumbTip"), let ip = joint("thumbIP") else {
        return YinweiHandPose(gesture: nil, score: 0, x: x, y: y, size: size)
      }
      required += [tip, ip]
      let extended = distance(wrist, tip) - distance(wrist, ip) > size * extensionMargin
      let up = tip.y < ip.y - size * extensionMargin && ip.y - tip.y > abs(tip.x - ip.x)
      gesture = extended && up ? "Thumb_Up" : "Closed_Fist"
    }
    // Minimum confidence of every joint used by this classification, never a model probability.
    let score = gesture == nil ? 0 : min(1, required.map { $0.confidence }.min() ?? 0)
    return YinweiHandPose(gesture: gesture, score: score, x: x, y: y, size: size)
  }

  /// Vision's upright, unmirrored lower-left frame → user's view. Mirror exactly once.
  static func userJoint(x: Double, y: Double, confidence: Double, aspect: Double) -> YinweiHandJoint {
    YinweiHandJoint(x: 1 - x, y: (1 - y) * aspect, confidence: confidence)
  }
}
