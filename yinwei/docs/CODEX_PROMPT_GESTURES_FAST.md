# Codex prompt: faster, more sensitive iPad gestures (replace the recognition logic)

Copy everything below the line into Codex. Written by Claude on 2026-10-25 after reviewing
commit `d22e42e` (Codex's first gesture build). Claude reviews the result and handles push,
the iPad build and publishing; Codex does not.

---

## Role and rules

You are changing the iPad hand-gesture feature in the Yinwei repo
(`C:\Users\Tim-King.Kings-laptop\Documents\yinwei-repo`, branch `codex/ios-capture-ci`).
Your earlier commit `d22e42e` added it. Read `AGENTS.md` and
`yinwei/docs/IMPLEMENTATION_IPAD_HAND_GESTURES.md` first.

- **Same rules as before.**
  - **Protected, do not change:** the engine and crates, Listen audio (`laptop_listen_controller.dart`
    audio loop, `listen_udp_*`, `YinweiReplayKitProbe.swift` audio), the cover code, and
    `app_audio_route.dart`.
  - **The owner's uncommitted files** (`soda_library.dart`, `soda_track_launcher.dart`,
    `player_screen.dart`, `app_top_bar.dart`, `music.js`, `music_test.mjs`, `my_lists*`): do not
    modify, stage or format them.
  - **Local commits only.** No push, CI, IPA, publishing or laptop changes.
- **Camera privacy stays exactly as it is:**
  - off by default, with consent;
  - the camera starts only on a hand-button tap, and stops on background, sign-out, room closure or
    an audio interruption;
  - only numbers leave the camera code, and nothing is stored or sent;
  - the capture session keeps `automaticallyConfiguresApplicationAudioSession = false` and
    `usesApplicationAudioSession = false`.
- **The gesture→action mapping does not change** (palm, fist, victory, thumb-up, and swipes
  left/right/up/down). It still calls only the page's existing actions.
- If a requirement here is ambiguous, stop and ask; do not invent product behaviour.

## Problem (measured in the current code)

The owner finds gestures too slow and not sensitive enough. The current pipeline waits too long
before it decides:

1. **Analysis is throttled to 20 fps twice:**
   - `YinweiHandGestures.swift` skips frames under 50 ms apart;
   - `listen_gestures.dart` drops frames with `t - _lastTime < 50`;
   - main-thread delivery is coalesced, so more frames are lost.
2. **Every frame goes Vision → main thread → Flutter event channel → Dart → JSON →
   `WKWebView` eval → the JS core** before anything is decided.
3. **Poses wait a fixed hold:** Open_Palm 500 ms, Closed_Fist 400, Victory 450, Thumb_Up 500.
   That is before any recognition time.
4. **Swipes need at least 2 moving frames** (at 20 fps, that is 100 ms or more) plus the full
   distance. Then a **fixed 400 ms cooldown** blocks the next swipe.

## Goal

Replace the recognition logic with a low-latency method that **commits as soon as the evidence is
clear**, instead of waiting out fixed timers. It must also be **more sensitive**: smaller, natural
swipes count. False triggers must not increase: tremor, fidgets, one-frame tracking glitches and
the return stroke after a flick.

Targets, measured as in "Latency instrumentation" below:

| | Target |
|---|---|
| Swipe decision | p50 ≤ 120 ms, p95 ≤ 200 ms after the stroke starts |
| Pose decision | p50 ≤ 250 ms, p95 ≤ 350 ms after the pose is first seen |
| A clear second swipe in the same direction | possible ≥ 250 ms after the first |
| False fires on the existing tremor / fidget / glitch cases | zero |

## New method

### 1. Recognize natively, at full camera rate

- New pure-Swift engine `YinweiGestureEngine` (Foundation only, so the macOS test harness can
  compile it). It runs on the Vision queue for **every** analysed frame: 30 fps, or 60 fps where
  the device supports 60 at the chosen preset.
  - Remove both 50 ms throttles.
  - Keep `alwaysDiscardsLateVideoFrames`.
  - Read only the joints you need, not `.all`.
  - A smaller preset is allowed if it measurably cuts latency without losing tracking (for
    example 640×480 → 352×288); measure it and report.
- **Send only results to Dart**, not frames:
  - `{event, t, latencyMs}` when a gesture is decided;
  - a light status at no more than 10 Hz for the hold ring (pose, progress 0–1).
  - The page runs `act()` for events. It no longer runs the JS core on iPad frames.
- Timestamps come from the camera (`CMSampleBufferGetPresentationTimeStamp`, converted to the same
  monotonic clock), not from the delivery time.

### 2. Smoothing without lag

Filter the palm centre (x, y) and hand size `s` with a **One Euro filter** (Casiez et al., 2012).
Use an adaptive cutoff: heavy smoothing when still (kills tremor), little when moving fast (no
lag). Work from the filtered position and the filtered velocity, in hand-sizes per second, the same
units as today. Add a short gap rule: if the hand disappears for ≤ 150 ms, keep the filter state.

### 3. Swipes: early commit on velocity

Replace the per-stroke "wait for it to end" logic with an **armed / committed** state machine.

- **Arm** when the filtered speed crosses the start speed.
- **Commit as soon as all of these hold**, which is typically 2–4 frames into the motion at
  30 fps:
  - the speed has stayed above the swipe speed for ≥ 2 consecutive frames;
  - the displacement over the last ~150 ms along the dominant axis is at least the needed distance;
  - the axis ratio is ≥ the ratio threshold;
  - the path is straight enough (keep the `straight` idea over the window).
- Tune the starting values from the owner's measurements in
  `.claude/skills/yinwei-gesture-control/SKILL.md`:
  - natural swipes travel 0.45–0.8 hand-sizes and peak at 3.5–8 hand-sizes/s; fidgets peak below 3;
  - the hand is about 20% of the frame wide;
  - you may commit at ~60% of a natural swipe's travel once the speed is clearly above fidget level.
- **Re-arm, instead of a fixed cooldown:** after a commit, the next swipe needs the speed to drop
  below the stop speed for ≥ 1 frame, or 250 ms to pass.
- **Return stroke:** keep the rule that the immediate stroke back along the same axis within
  ~600 ms is ignored (`returnMs`, and the calibration's "允许连续反向" setting still turns it off).
  A clear second stroke in the **same** direction must fire.
- **Blur / exit:** keep the prototype's rule. A fast hand that vanishes after most of the distance
  still counts.

### 4. Poses: evidence accumulation, not fixed holds

- Each frame, the classifier gives the current pose and a confidence margin (0–1).
  - Extend `YinweiHandPose.swift` to return margins: how clearly each finger is extended or
    curled, not only booleans.
- A leaky integrator per pose: evidence += margin × dt; it decays quickly for poses not seen,
  and resets when the hand moves faster than the `still` threshold (so swipes never trigger poses).
- **Fire when the evidence crosses the threshold.** A clear, steady pose fires in about 150–250 ms;
  a doubtful one takes longer or never fires.
- **Release:** after firing, the same pose cannot fire again until its evidence falls below a
  re-arm level (hand opened, closed or lowered). Keep today's "a fired pose stays fired until
  released".

### 5. Calibration and settings

Keep the guided calibration and its UI. Re-map what it tunes onto the new parameters: commit
distance, swipe speed, re-arm and return. **Keep the existing safety cap: calibration may only make
gestures easier, never stricter.** Stored calibration from the old format must be ignored safely
(reset to defaults), not misread.

## Latency instrumentation (required)

- For every event, record the decision delay:
  - swipes: event time − the frame where the stroke armed;
  - poses: event time − the first frame the pose was seen.
- Also record the delivery delay: the page's `act()` time − event time.
- Show p50/p95 and counts per event type in the existing gesture detail panel (校准 / details), and
  include them in "Copy audio diagnostics" (numbers only).

## Tests (all must pass before you report)

1. **The owner's recorded cases as the oracle.**
   - Export every frame sequence from the existing JS tests (`yinwei/apps/yinwei_player/test/listen_room/gesture_core_test.mjs`,
     including the two owner data-set replays) to JSON fixtures under `yinwei/apps/yinwei_player/test/native_gestures/fixtures/`.
     Write a small exporter script for this and commit it.
   - Run the new Swift engine on them (macOS harness via `yinwei/tools/test_ios_capture.sh`). For every
     fixture:
     - (a) the same set of events fires, with no misses;
     - (b) no extra event fires on the tremor, fidget, glitch and return cases;
     - (c) each event fires **no later** than the old JS core. Print the mean and p95 improvement.
2. **New cases:**
   - small natural swipes (0.4–0.5 hand-sizes at 3.5 hand-sizes/s) fire;
   - two same-direction swipes 300 ms apart both fire;
   - left then immediately back is one event;
   - a steady clear palm fires within 250 ms, and a wobbly half-open hand does not;
   - holding a fist after it fired does not repeat;
   - a 100 ms tracking dropout mid-swipe still fires.
3. **Classifier margin tests** for all four poses and `null`, including mirrored and rotated hands.
4. **Dart and page tests:**
   - events are validated and clamped;
   - nothing is sent while off, in the background or not ready;
   - `act()` mapping is unchanged;
   - nothing acts during calibration;
   - the existing offline contract still passes.
5. **Regression:** `flutter test`. The only known environment failure is
   `test/update/windows_package_integration_test.dart`. Since `b4aca2c` the gateway test no longer
   depends on `YINWEI_LISTEN_UDP`, so do not override that variable. Also run
   `node --test test/listen_room/*.mjs test/remote/*.mjs`.

The browser prototype in `yinwei/docs/design/gestures/` stays as it is: it is the reference, not
the shipped code.

## Report back (for Claude's review)

- The files changed, `git status`, and `--stat`; confirm no protected or owner file was touched.
- The fixture results table: per case, the old vs new event times and the misses or extra fires
  (expected zero).
- Measured or estimated latency per stage: camera → Vision → engine → Dart → page. Say which
  numbers come from the harness and which need the device.
- Anything you could not verify. All camera behaviour and real latency need the owner's iPad; do
  not claim device acceptance.
- Open questions instead of guesses.
