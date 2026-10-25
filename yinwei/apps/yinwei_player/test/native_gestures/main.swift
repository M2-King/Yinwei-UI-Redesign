import Foundation

var passed = 0
func check(_ name: String, _ body: () -> Bool) {
  guard body() else { fatalError("FAIL: \(name)") }
  passed += 1
  print("ok - \(name)")
}

func hand(_ fingers: [Bool], thumbUp: Bool = false) -> [String: YinweiHandJoint] {
  func p(_ x: Double, _ y: Double) -> YinweiHandJoint {
    YinweiHandJoint(x: x, y: y, confidence: 0.9)
  }
  var joints = ["wrist": p(0.5, 0.7), "thumbIP": p(0.38, 0.59), "thumbTip": p(0.44, 0.64)]
  for (i, name) in ["index", "middle", "ring", "little"].enumerated() {
    let x = 0.45 + Double(i) * 0.05
    joints[name + "MCP"] = p(x, 0.55)
    joints[name + "PIP"] = p(x, 0.43)
    joints[name + "Tip"] = p(x, fingers[i] ? 0.25 : 0.58)
  }
  if thumbUp { joints["thumbIP"] = p(0.34, 0.5); joints["thumbTip"] = p(0.34, 0.3) }
  return joints
}
func transformed(_ joints: [String: YinweiHandJoint], angle: Double = 0, mirror: Bool = false) -> [String: YinweiHandJoint] {
  joints.mapValues { p in
    let x = p.x - 0.5, y = p.y - 0.7
    let rx = x * cos(angle) - y * sin(angle)
    return YinweiHandJoint(x: 0.5 + (mirror ? -rx : rx), y: 0.7 + x * sin(angle) + y * cos(angle), confidence: p.confidence)
  }
}
let poses: [(String, [String: YinweiHandJoint])] = [
  ("Open_Palm", hand([true, true, true, true])),
  ("Closed_Fist", hand([false, false, false, false])),
  ("Victory", hand([true, true, false, false])),
  ("Thumb_Up", hand([false, false, false, false], thumbUp: true))
]
for (name, joints) in poses {
  check(name) { YinweiHandClassifier.classify(joints)?.gesture == name }
  check("\(name) mirrored") { YinweiHandClassifier.classify(transformed(joints, mirror: true))?.gesture == name }
  check("\(name) rotated 20 degrees") { YinweiHandClassifier.classify(transformed(joints, angle: .pi / 9))?.gesture == name }
}
check("other pose is null") { YinweiHandClassifier.classify(hand([true, false, false, false]))?.gesture == nil }
check("sideways thumb is not up; curled fingers form a fist") {
  YinweiHandClassifier.classify(transformed(poses[3].1, angle: .pi / 2))?.gesture == "Closed_Fist"
}
check("upside-down thumb is not up") {
  YinweiHandClassifier.classify(transformed(poses[3].1, angle: .pi))?.gesture == "Closed_Fist"
}
check("missing palm is no hand") { YinweiHandClassifier.classify([:]) == nil }
check("low confidence wrist is no hand") {
  var joints = poses[0].1; joints["wrist"] = YinweiHandJoint(x: 0.5, y: 0.7, confidence: 0.29)
  return YinweiHandClassifier.classify(joints) == nil
}
check("missing finger never becomes a fist") {
  var joints = poses[1].1; joints.removeValue(forKey: "indexTip")
  return YinweiHandClassifier.classify(joints)?.gesture == nil
}
check("low-confidence thumb cannot confirm") {
  var joints = poses[3].1; joints["thumbTip"] = YinweiHandJoint(x: 0.34, y: 0.3, confidence: 0.29)
  return YinweiHandClassifier.classify(joints)?.gesture == nil
}
check("score is the minimum required confidence") {
  var joints = poses[0].1; joints["ringTip"] = YinweiHandJoint(x: 0.55, y: 0.25, confidence: 0.65)
  return YinweiHandClassifier.classify(joints)?.score == 0.65
}
check("open palm does not require thumb") {
  var joints = poses[0].1; joints.removeValue(forKey: "thumbTip"); joints.removeValue(forKey: "thumbIP")
  return YinweiHandClassifier.classify(joints)?.gesture == "Open_Palm"
}
check("degenerate palm is no hand") {
  var joints = poses[0].1; joints["middleMCP"] = joints["wrist"]
  return YinweiHandClassifier.classify(joints) == nil
}
check("non-finite geometry is no hand") {
  var joints = poses[0].1; joints["wrist"] = YinweiHandJoint(x: .nan, y: 0.7, confidence: 0.9)
  return YinweiHandClassifier.classify(joints) == nil
}
check("size and centre use the five palm joints") {
  let pose = YinweiHandClassifier.classify(poses[0].1)!
  return abs(pose.size - 0.15) < 1e-9 && abs(pose.x - 0.52) < 1e-9 && abs(pose.y - 0.58) < 1e-9
}
check("Vision coordinates mirror x and scale y exactly once") {
  let p = YinweiHandClassifier.userJoint(x: 0.2, y: 0.75, confidence: 0.9, aspect: 0.75)
  return abs(p.x - 0.8) < 1e-9 && abs(p.y - 0.1875) < 1e-9
}
check("portrait aspect uses the upright buffer dimensions") {
  let p = YinweiHandClassifier.userJoint(x: 0.5, y: 0.25, confidence: 0.9, aspect: 4.0 / 3.0)
  return abs(p.y - 1) < 1e-9
}
print("\(passed) hand classifier tests passed")
