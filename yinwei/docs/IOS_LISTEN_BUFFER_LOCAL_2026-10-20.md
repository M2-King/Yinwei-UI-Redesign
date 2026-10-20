# Local iPad Listen receiver change — 2026-10-20

Status: implemented locally, with Dart and browser verification complete.
Native Swift compilation and iPad playback verification remain pending.
Branch: `codex/ios-capture-ci`; base HEAD: `40a2cdd`.
No commit, push, workflow, iPad publication or laptop bundle switch was performed.

## Evidence and limits

The previous receiver used AVAudioPlayerNode `.dataPlayedBack` completions
to determine queued audio and detect starvation. Those completions include
downstream presentation delay. With Bluetooth, outstanding completions can
therefore remain while the player has already exhausted its playable PCM.
This is a concrete accounting problem, but the reported hostel Wi-Fi incident
has no captured packet/receiver trace proving which stage caused each gap.

The existing buffer was already adaptive: 120 ms initially, growing by 50 ms
on detected starvation up to 400 ms, with a 600 ms capacity at 48 kHz.
The correction focuses on detecting exhaustion independently of delayed played
callbacks and calculating thresholds using the actual stream sample rate.

Source inspection found 512-frame stereo float PCM messages: 4,152 bytes
including the 56-byte header, nominally 93.75 messages/second at 48 kHz.
That is 3.072 Mbit/s of PCM, or 3.114 Mbit/s including application headers.
These are calculated rates, not a measured laptop send-cadence trace.
The sender polls every 10 ms and can drain multiple messages in one tick;
WebSocket/TCP delivery can arrive in bursts.

## Implementation

- Listen playback tracks scheduled frame positions against the player render
  clock. It checks before each write and on the existing audio queue every
  10 ms, pauses on exhaustion and refills before resuming.
- The minimum remains 120 ms; starvation adds 50 ms up to the existing 400 ms
  ceiling. After 30 stable seconds the target decreases by 25 ms. A decrease
  affects subsequent refill thresholds; it does not discard queued PCM.
- A 600 ms limit applies to playable PCM independently of Bluetooth completion
  delay. A separate 2,048-buffer limit bounds outstanding completion bookkeeping.
- Stream/route resets clear the timeline but preserve the session's learned
  target. A new listening session resets the learning.
- Diagnostics record receiver packet inter-arrival and absolute jitter
  p50/p95/max, sequence/frame gaps, duplicate/reordered observations, source
  drop-counter deltas, native write round-trip timing, local rejection counts,
  native underruns, route type, session timing and sample rates.
- Timing windows hold up to 1,024 samples. Buffer history holds 120 status
  samples, approximately one minute at the existing 500 ms poll interval.
- The room menu has **Copy audio diagnostics**, which copies metadata JSON
  locally. It excludes PCM, credentials, media titles and remote addresses.

The behavioral changes are gated to Listen mode. The existing ReplayKit
return path retains its previous scheduling policy. Rust, HRTF, DSP,
Live Transfer, sender transport and laptop deployment were not changed.
No Opus, drift resampling, concealment or Wi-Fi power-setting changes were made.

## Verification

| Check | Result |
| --- | --- |
| Full `flutter test --no-pub --concurrency=2 --reporter expanded` | 723 passed, 6 skipped |
| Node tests in `test/listen_room/*.mjs` | 24 passed |
| Dart analysis of changed Dart implementation/tests | No issues |
| iOS-target `kernel_snapshot_program` | Passed, exit 0 |
| Full `flutter build bundle --target-platform ios` | Blocked by missing `xcrun` in native build hooks on Windows |
| Swift policy tests | Added and wired into `tools/test_ios_capture.sh`; not executed here |
| Native AVAudioEngine integration / IPA | Not compiled here; requires Xcode |
| Local browser menu smoke | Copy intent verified, landscape/portrait bounds checked, no console/page errors |
| Running laptop backend | PID 17284, `outputs/w18/windows/yinwei_player.exe`; health HTTP 200 |

Logs and browser artifacts are under `outputs/local-listen-audio-20261020/`.
Browser tests use a mock native bridge and do not demonstrate iPad audio behavior.
The Dart kernel check does not compile Swift or produce an installable IPA.

## Remaining device validation

After an explicitly approved iPad build/install, test with the same Bluetooth
headphones and Wi-Fi in foreground and background. Copy diagnostics after
reproducing a gap and after a stable interval. Check that render exhaustion
increments underruns once, increases the refill target and resumes contiguous
playback; verify route changes, interruption recovery and source changes.
Check ordinary playback, spatial positioning, HRTF and ReplayKit return behavior.

The new traces measure arrival at the Dart WebSocket boundary, not radio packet
timing. Sequence gaps are application-level discontinuities, not proof of IP
packet loss. Source pauses can count as starvation. Separate sender timing is
still needed if gaps remain or receiver traces point upstream.

No real iPad underrun count, fill trace, jitter percentiles or loss/reorder
measurements have been collected for this patch yet. Do not infer those values
from unit tests or claim that the audible stutter is resolved before device testing.

Rollback is limited to this Listen patch and its new helper/test files; preserve
the three approved local commits and all unrelated working-tree changes.
