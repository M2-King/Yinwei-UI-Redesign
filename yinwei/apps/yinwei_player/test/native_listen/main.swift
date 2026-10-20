import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), message)
  checks += 1
}

for rate in [44_100.0, 48_000.0, 96_000.0] {
  var buffer = YinweiListenBuffer()
  buffer.reset(sampleRate: rate)
  let target = Int(buffer.frames(milliseconds: 120))
  check(buffer.enqueue(frames: target - 1) == 0, "First packet starts at zero")
  check(!buffer.canStart, "A sub-target buffer must wait at every sample rate")
  check(buffer.enqueue(frames: 1) == Int64(target - 1), "Contiguous scheduling")
  check(buffer.canStart && buffer.queuedMs == 120, "Time-based startup at every rate")
  buffer.start(now: 0)
  check(!buffer.observe(renderedFrame: -100, now: 0), "Ignore negative startup clock")
  check(buffer.observe(renderedFrame: Int64(target), now: 0.12), "Render exhaustion triggers refill")
  check(buffer.targetMs == 170 && buffer.underruns == 1, "Grow once per underrun")
  check(!buffer.observe(renderedFrame: Int64(target + 1000), now: 1), "Do not count empty paused ticks")
  buffer.freeze(renderedFrame: Int64(target + 50))
  check(buffer.enqueue(frames: 512) == Int64(target + 50), "Refill never schedules behind paused clock")
  check(!buffer.canStart, "A single late packet cannot resume immediately")
}

// Delayed Bluetooth completions do not enter this policy at all. At 180 ms,
// a 128 ms render reserve has run dry even if played callbacks trail by 200 ms.
var bluetooth = YinweiListenBuffer()
check(bluetooth.enqueue(frames: 6144) == 0, "128 ms startup")
bluetooth.start(now: 0)
check(bluetooth.observe(renderedFrame: 8640, now: 0.18), "Detect starvation before played callbacks")
check(bluetooth.queuedMs == 0, "No imaginary Bluetooth reserve")
check(bluetooth.enqueue(frames: 8160) == 8640, "Refill starts at current timeline")
check(bluetooth.canStart, "170 ms refill resumes")
bluetooth.start(now: 0.3)
_ = bluetooth.observe(renderedFrame: 9000, now: 1)
check(bluetooth.enqueue(frames: 4800) != nil, "Unplayed downstream buffers do not consume capacity")
check(bluetooth.enqueue(frames: 28800) == nil, "Usable audio still has a hard 600 ms bound")

var stable = YinweiListenBuffer()
for n in 0..<10 {
  _ = stable.enqueue(frames: Int(stable.frames(milliseconds: stable.targetMs)))
  stable.start(now: Double(n))
  _ = stable.observe(renderedFrame: stable.scheduledEnd, now: Double(n) + 0.5)
}
check(stable.targetMs == 400, "Repeated starvation stays bounded")
stable.reset(sampleRate: 44_100)
check(stable.targetMs == 400 && stable.underruns == 10, "Route/epoch reset preserves session learning")
check(stable.scheduledEnd == 0 && !stable.playing, "Reset drops old timeline")
_ = stable.enqueue(frames: 17640)
stable.start(now: 20)
_ = stable.observe(renderedFrame: 1, now: 49)
check(stable.targetMs == 400, "No premature decay")
_ = stable.observe(renderedFrame: 2, now: 50)
check(stable.targetMs == 375, "Slow decay after 30 stable seconds")
check(stable.queuedFrames == 17638, "Decay does not drop or pad PCM")
stable = YinweiListenBuffer()
check(stable.targetMs == 120 && stable.underruns == 0, "New listening session resets learning")
print("PASS: \(checks) Listen buffer policy checks (not AVAudioEngine/device tests)")
