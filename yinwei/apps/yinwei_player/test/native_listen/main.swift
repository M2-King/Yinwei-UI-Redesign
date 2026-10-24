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

var privateBuffer = YinweiListenBuffer()
privateBuffer.configure(privateRoute: true)
check(privateBuffer.targetMs == 80, "Private route starts at 80ms")
_ = privateBuffer.enqueue(frames: 8640) // 180ms, excess above private floor
privateBuffer.start(now: 0)
privateBuffer.updateRate(now: 1)
check(privateBuffer.playbackRate == 1, "No catch-up during startup")
privateBuffer.updateRate(now: 2)
privateBuffer.updateRate(now: 3.9)
check(privateBuffer.playbackRate == 1, "Persistent excess requires two seconds")
privateBuffer.updateRate(now: 4)
check(privateBuffer.playbackRate == 1.01, "Bounded one-percent catch-up")
check(privateBuffer.silenceTrim(count: 960, peak: 0.01, now: 4) == 0, "Never trim audible music")
check(privateBuffer.silenceTrim(count: 960, peak: 0, now: 4) == 9, "Trim only one percent of silence")
check(privateBuffer.silenceTrim(count: 960, peak: .nan, now: 4) == 0, "Reject nonfinite silence analysis")
_ = privateBuffer.observe(renderedFrame: 4608, now: 4.1)
privateBuffer.updateRate(now: 4.1)
check(privateBuffer.playbackRate == 1, "Catch-up stops inside hysteresis margin")
check(privateBuffer.observe(renderedFrame: 8640, now: 5), "Underrun detected")
check(privateBuffer.targetMs == 130, "Private underrun adds 50ms")
check(privateBuffer.playbackRate == 1, "No catch-up during starvation")
privateBuffer.configure(privateRoute: false)
check(privateBuffer.targetMs == 170, "Public route preserves learned penalty")
privateBuffer.configure(privateRoute: true)
check(privateBuffer.targetMs == 130, "Private migration preserves learned penalty")
privateBuffer.reset(sampleRate: 44100)
check(privateBuffer.playbackRate == 1 && privateBuffer.targetMs == 130, "Reset preserves learning but clears rate")
print("PASS: \(checks) Listen latency policy checks (not AVAudioEngine/device tests)")

var plannedPause = YinweiListenBuffer()
_ = plannedPause.enqueue(frames: 5760)
plannedPause.start(now: 0)
check(plannedPause.observe(renderedFrame: 5760, now: 1, expectedSilence: true), "Planned pause still refills safely")
check(plannedPause.underruns == 0 && plannedPause.targetMs == 120, "Local transport mute does not inflate jitter learning")
print("PASS: \(checks) Listen latency and transport policy checks")

// Deterministic source/render clock simulation; no audio or time-pitch quality claim.
var catchingUp = YinweiListenBuffer()
catchingUp.configure(privateRoute: true)
_ = catchingUp.enqueue(frames: 8640)
catchingUp.start(now: 0)
var renderedFrames: Int64 = 0
for tick in 1...1600 {
  let now = Double(tick) / 100
  catchingUp.updateRate(now: now)
  renderedFrames += Int64(480 * Double(catchingUp.playbackRate))
  _ = catchingUp.observe(renderedFrame: renderedFrames, now: now)
  _ = catchingUp.enqueue(frames: 480)
}
check(catchingUp.underruns == 0, "Catch-up simulation never starves")
check(catchingUp.queuedMs >= 80 && catchingUp.queuedMs <= 105, "Persistent backlog converges near target")
check(catchingUp.playbackRate == 1, "Catch-up exits without hunting")
// Gap concealment (docs/IMPLEMENTATION_LISTEN_UDP_AUDIO.md, phase 2).
do {
  let last = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.5 }
  let gap = YinweiListenGap.conceal(last: last, frames: 960)
  check(gap.count == 960, "Gap fills exactly the lost frames")
  check(abs(gap[0] - last[959]) < 0.01, "Gap starts where the audio stopped (no click)")
  for i in 1..<YinweiListenGap.blendFrames {
    check(abs(gap[i] - gap[i - 1]) < 0.05, "Blend into the repeat is smooth")
  }
  check(abs(gap[959]) < 0.001, "Gap fades to silence")
  check(gap.allSatisfy { $0.isFinite && abs($0) <= 0.5 }, "Never louder than the source")
  check(YinweiListenGap.conceal(last: [], frames: 480) == [Float](repeating: 0, count: 480),
        "Nothing played yet: silence")
  check(YinweiListenGap.conceal(last: last, frames: 0).isEmpty, "Zero frames: nothing")
  var next = [Float](repeating: 0.4, count: 960)
  YinweiListenGap.fadeIn(&next)
  check(next[0] == 0 && abs(next[YinweiListenGap.fadeInFrames] - 0.4) < 1e-6,
        "Next packet fades in from silence, then plays unchanged")
  check(YinweiListenGap.maxFrames == 9_600, "At most 200 ms is concealed")
}
print("PASS: \(checks) Listen scheduling and convergence policy checks")
