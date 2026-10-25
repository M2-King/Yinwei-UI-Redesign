import Foundation
import Dispatch

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

// Geometry margins, including the same mirrored/rotated joint inputs as classification.
for (name, joints) in poses {
  for (suffix, j) in [("", joints), (" mirrored", transformed(joints, mirror: true)),
                       (" rotated", transformed(joints, angle: .pi / 9))] {
    check("\(name)\(suffix) has clear bounded margins") {
      let p = YinweiHandClassifier.classify(j)!
      return p.margin > 0.6 && p.margin <= 1 && p.fingerMargins.count >= 4 &&
        p.fingerMargins.values.allSatisfy { $0.isFinite && abs($0) <= 1 }
    }
  }
}
check("null pose has zero certainty") {
  let p = YinweiHandClassifier.classify(hand([true, false, false, false]))!
  return p.gesture == nil && p.margin == 0
}
for j in [hand([true,false,false,false]), transformed(hand([true,false,false,false]), mirror:true),
          transformed(hand([true,false,false,false]), angle:.pi/9)] {
  check("null geometry remains null after transform") {
    let p=YinweiHandClassifier.classify(j)!
    return p.gesture == nil && p.margin == 0
  }
}
check("half-open geometry has little evidence") {
  var j = poses[0].1
  let wrist = j["wrist"]!, pip = j["indexPIP"]!
  let d = hypot(pip.x-wrist.x, pip.y-wrist.y) + 0.15 * 0.16
  j["indexTip"] = YinweiHandJoint(x: wrist.x, y: wrist.y-d, confidence: 0.9)
  return (YinweiHandClassifier.classify(j)?.margin ?? 0) < 0.15
}

struct ReplayFrame: Decodable {
  var t: Double, hand: Bool
  var g: String?, score: Double?, x: Double?, y: Double?, s: Double?, margin: Double?
  var pose: YinweiHandPose? {
    guard hand else { return nil }
    return YinweiHandPose(gesture: g, score: score ?? 0, x: x ?? 0.5, y: y ?? 0.5,
                          size: s ?? 0.12, margin: margin ?? 1)
  }
}
struct ReplayEvent: Codable, Equatable { var event: String, t: Double }
struct ReplayFixture: Decodable { var name: String, frames: [ReplayFrame], oldEvents: [ReplayEvent] }
struct ReplayFile: Decodable { var schema: Int, fixtures: [ReplayFixture] }
var engineFrameTimes: [Double] = []
var decisionTimes: [String: [Double]] = [:]
func replay(_ frames: [ReplayFrame], config: YinweiGestureConfig = YinweiGestureConfig()) -> [(ReplayEvent, Double)] {
  let engine = YinweiGestureEngine(config: config)
  return frames.compactMap { f in
    let pose = f.pose, start = DispatchTime.now().uptimeNanoseconds
    let out = engine.feed(t: f.t, pose: pose)
    engineFrameTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    if let event = out.event { decisionTimes[event, default: []].append(out.latencyMs) }
    return out.event.map { (ReplayEvent(event: $0, t: f.t), out.latencyMs) }
  }
}
var failures: [String] = [], improvements: [Double] = [], results: [[String: Any]] = []
if CommandLine.arguments.count >= 2 {
  let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
  let oracle = try JSONDecoder().decode(ReplayFile.self, from: data)
  guard oracle.schema == 1 else { fatalError("Unsupported fixtures") }
  print("CASE | OLD event@ms | NEW event@ms | misses/extra | later")
  for fixture in oracle.fixtures {
    let got = replay(fixture.frames).map { $0.0 }
    let same = got.map { $0.event } == fixture.oldEvents.map { $0.event }
    let late = same && zip(got,fixture.oldEvents).contains { $0.t > $1.t + 0.001 }
    if !same || late { failures.append(fixture.name) }
    if same { for (n,o) in zip(got,fixture.oldEvents) { improvements.append(o.t-n.t) } }
    func label(_ events: [ReplayEvent]) -> String { events.map { "\($0.event)@\(Int($0.t))" }.joined(separator:",") }
    print("\(fixture.name) | \(label(fixture.oldEvents)) | \(label(got)) | \(same ? 0 : 1) | \(late)")
    let names = Set(got.map { $0.event } + fixture.oldEvents.map { $0.event })
    let misses = names.reduce(0) { count,name in count + max(0,fixture.oldEvents.filter { $0.event == name }.count - got.filter { $0.event == name }.count) }
    let extras = names.reduce(0) { count,name in count + max(0,got.filter { $0.event == name }.count - fixture.oldEvents.filter { $0.event == name }.count) }
    results.append(["name":fixture.name,"old":fixture.oldEvents.map { ["event":$0.event,"t":$0.t] },
                    "new":got.map { ["event":$0.event,"t":$0.t] },"sameEvents":same,"later":late,"misses":misses,"extras":extras])
  }
}
func makeFrame(_ t: Double, _ x: Double = 0.5, _ y: Double = 0.5, pose: String? = nil,
               margin: Double = 1, score: Double = 0.9, hand: Bool = true) -> ReplayFrame {
  ReplayFrame(t:t, hand:hand, g:pose, score:score, x:x, y:y, s:0.12, margin:margin)
}
func steady(_ start: Double, _ end: Double, _ x: Double = 0.5, _ y: Double = 0.5,
            pose: String? = nil) -> [ReplayFrame] {
  stride(from:start,through:end,by:33).map { makeFrame($0,x,y,pose:pose) }
}
func flick(_ start: Double, _ hands: Double, _ peak: Double, x: Double = 0.6,
           right: Bool = false) -> [ReplayFrame] {
  let duration = 1500 * hands / peak
  return stride(from:33.0,through:duration,by:33).map { dt in
    let u=dt/duration, e=u*u*(3-2*u)
    return makeFrame(start+dt,x+(right ? 1 : -1)*hands*0.12*e)
  }
}
func newCase(_ name: String, _ frames: [ReplayFrame], _ expected: [String], maxDelay: Double? = nil) {
  let got = replay(frames)
  let same = got.map { $0.0.event } == expected
  let timely = maxDelay.map { limit in got.allSatisfy { $0.1 <= limit } } ?? true
  if !same || !timely { failures.append(name) }
  print("NEW \(name): \(got.map { "\($0.0.event)@\(Int($0.0.t)) delay=\(Int($0.1))" }) \(same && timely ? "PASS" : "FAIL")")
}
for travel in [0.4,0.45,0.5] {
  let duration=1500*travel/3.5
  newCase("small natural \(travel) hands", steady(0,198,0.6)+flick(200,travel,3.5)+steady(200+duration,650,0.6-travel*0.12),["swipeLeft"],maxDelay:200)
}
newCase("two same direction 300 ms apart",steady(0,198,0.6)+flick(200,0.5,5)+steady(350,490,0.54)+flick(500,0.5,5,x:0.54)+steady(650,900,0.48),["swipeLeft","swipeLeft"])
newCase("immediate return",steady(0,198,0.6)+flick(200,0.6,5)+flick(380,0.6,5,x:0.528,right:true)+steady(560,900,0.6),["swipeLeft"])
newCase("clear palm <=250ms",steady(0,300,pose:"Open_Palm"),["Open_Palm"],maxDelay:250)
for name in ["Closed_Fist", "Victory", "Thumb_Up"] {
  newCase("clear \(name) <=250ms",steady(0,300,pose:name),[name],maxDelay:250)
}
for (name,joints) in poses {
  for hz in [30.0,60.0] {
    check("classified \(name) at \(Int(hz)) fps needs 150...250ms and fires once") {
      let engine=YinweiGestureEngine(), pose=YinweiHandClassifier.classify(joints)!
      var fired: [YinweiGestureDecision] = []
      for i in 0...Int(hz) {
        let out=engine.feed(t:Double(i)*1000/hz,pose:pose)
        if out.event != nil { fired.append(out) }
      }
      return fired.count == 1 && fired[0].event == name && fired[0].latencyMs >= 150 && fired[0].latencyMs <= 250
    }
  }
}
let small60 = stride(from:0.0,through:600,by:1000/60).map { t -> ReplayFrame in
  let u=max(0,min(1,(t-200)/(1500*0.4/3.5))), e=u*u*(3-2*u)
  return makeFrame(t,0.6-0.4*0.12*e)
}
newCase("small natural swipe at 60fps",small60,["swipeLeft"],maxDelay:200)
newCase("120ms palm flash",steady(0,120,pose:"Open_Palm"),[])
newCase("wobbly half-open",stride(from:0.0,through:1200,by:33).map { makeFrame($0,0.5+sin($0/30)*0.02,pose:"Open_Palm",margin:0.08) },[])
newCase("fist never repeats",steady(0,3000,pose:"Closed_Fist"),["Closed_Fist"])
newCase("100ms dropout mid swipe",steady(0,198,0.6)+[makeFrame(233,0.58),makeFrame(266,hand:false),makeFrame(299,hand:false),makeFrame(332,0.54),makeFrame(365,0.51)]+steady(398,700,0.51),["swipeLeft"])
newCase("low confidence resets pose evidence",steady(0,120,pose:"Victory")+[makeFrame(132,pose:"Victory",score:0.4)]+steady(165,285,pose:"Victory"),[])
newCase("motion resets pose evidence",steady(0,120,pose:"Victory")+[makeFrame(132,0.52,pose:"Victory")]+steady(165,285,0.52,pose:"Victory"),[])
let poseIntoSwipe = steady(0,132,0.6,pose:"Open_Palm") + flick(132,0.6,5).map { f -> ReplayFrame in
  var p=f; p.g="Open_Palm"; p.score=0.9; return p
} + [makeFrame(350,hand:false)]
newCase("a ready pose cannot fire as a swipe starts",poseIntoSwipe,["swipeLeft"])
newCase("departure resets pose evidence",steady(0,120,pose:"Victory")+[makeFrame(132,hand:false)]+steady(165,285,pose:"Victory"),[])
newCase("long camera gap resets evidence",steady(0,120,pose:"Victory")+steady(500,620,pose:"Victory"),[])
newCase("doubtful pose never accumulates passing flashes",stride(from:0.0,through:1600,by:33).map { makeFrame($0,pose:Int($0/100)%2 == 0 ? "Open_Palm" : nil,margin:0.2) },[])
check("legacy calibration is ignored") { YinweiGestureConfig(["swipeSpeed":0]).swipeSpeed == 2.4 }
check("calibration is finite and only easier") {
  let c=YinweiGestureConfig(["version":2,"commitHands":10,"swipeSpeed":Double.nan,"returnMs":0,"rearmMs":1])
  return c.commitHands == 0.34 && c.swipeSpeed == 2.4 && c.returnMs == 0 && c.rearmMs == 100
}
func percentile(_ values: [Double], _ p: Double) -> Double {
  let a=values.sorted(); return a.isEmpty ? 0 : a[max(0,Int(ceil(Double(a.count)*p))-1)]
}
let mean = improvements.isEmpty ? 0 : improvements.reduce(0,+)/Double(improvements.count)
print("Event improvement mean=\(mean) ms, p95=\(percentile(improvements,0.95)) ms")
let metrics = decisionTimes.mapValues { values in
  ["count": Double(values.count), "p50": percentile(values,0.5), "p95":percentile(values,0.95)]
}
for name in metrics.keys.sorted() { print("DECISION \(name): \(metrics[name]!)") }
print("Pure engine per-frame p50=\(percentile(engineFrameTimes,0.5)) ms, p95=\(percentile(engineFrameTimes,0.95)) ms (host harness, not Vision/device)")
if CommandLine.arguments.count >= 3 {
  let report: [String:Any] = ["fixtures":results,"failures":failures,"meanImprovementMs":mean,
                            "p95ImprovementMs":percentile(improvements,0.95),"engineFrameP50Ms":percentile(engineFrameTimes,0.5),
                            "engineFrameP95Ms":percentile(engineFrameTimes,0.95),"decisionMetrics":metrics]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
}
if !failures.isEmpty { print("FAILURES: \(failures)"); exit(1) }
print("All native gesture engine fixtures and new cases passed")
