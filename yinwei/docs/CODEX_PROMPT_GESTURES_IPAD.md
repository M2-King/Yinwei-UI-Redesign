# Codex prompt: iPad hand-gesture control for the Listen Room

Copy everything below the line into Codex. Written by Claude on 2026-10-25 from the
working browser prototype and the project rules. Claude reviews the result and
handles push, the iPad build and publishing; Codex does not.

---

## Role and rules

You are implementing a feature in the Yinwei repo
(`C:\Users\Tim-King.Kings-laptop\Documents\yinwei-repo`), branch `codex/ios-capture-ci`.
Read `AGENTS.md` first and follow it. In particular:

- **Protected, do not change:** `yinwei/crates/**`, `spatial_core.dll`, HRTF/DSP, Live capture,
  `lib/bridge/app_audio_route.dart` routing, the Listen audio path (`laptop_listen_controller.dart`
  audio loop, `listen_udp_*`, `YinweiReplayKitProbe.swift` audio scheduling), the cover code
  (`soda_cover.dart`, `listen_cover_cache.dart`).
- **The owner has uncommitted work** in `lib/remote/soda_library.dart`, `soda_track_launcher.dart`,
  `lib/screens/player_screen.dart`, `lib/widgets/app_top_bar.dart`, `assets/listen_room/music.js`,
  `test/listen_room/music_test.mjs`, and new `my_lists*` files. Do not modify, stage, format or
  revert any of them. Never run a formatter over whole folders; format only files you changed.
- Commit locally only your files. **Do not push, run CI workflows, build or publish the IPA, or
  switch laptop bundles.** Never stage `windows/runner/spatial_core.dll`, `website/`, `outputs/`,
  `.tmp/`. Commit messages end with your usual co-author line.
- **The camera is privacy-sensitive.** The owner must approve before this reaches anyone. Build it
  **off by default** behind an explicit opt-in (below), and report back. Do not enable it by default.
- If something in this prompt is ambiguous, stop and ask rather than invent product behaviour.

## Goal

On the iPad, hand gestures in front of the front camera control the Listen Room, exactly like the
approved browser prototype. The camera frames are analysed **on the iPad** by Apple Vision
(`VNDetectHumanHandPoseRequest`). Only a handful of numbers per frame reach the page. Nothing is
stored or sent anywhere, and there is no network use at all.

## Reference (approved prototype, measured with the owner)

- `yinwei/docs/design/gestures/gestures.cjs` is the browser prototype (MediaPipe, review only).
  Its pure parts are `createGestureCore`, `createSwipeLog`, `analyseCalibration` and `GESTURE`
  (exported for Node).
- Its tests are in the same folder: `gesture_core_test.mjs` (28), `swipe_log_test.mjs` (5) and
  `calibration_test.mjs` (10). Run them with `node <test> <absolute path to gestures.cjs>`.
  All 43 pass today.
- `.claude/skills/yinwei-gesture-control/SKILL.md` has every tuned rule, the owner's measurements,
  and why each threshold is what it is. **Keep the thresholds and rules exactly**; they come from
  the owner's real swipes.

### Mapping (only the page's existing actions; nothing new reaches playback)

| Gesture | Action |
|---|---|
| Open_Palm held 0.5 s | album → quick menu |
| Closed_Fist held 0.4 s | window → quick menu → album |
| Victory held 0.45 s | quick menu → window |
| Thumb_Up held 0.5 s | confirm: quick menu = `pkSelect(pkFocus)`; window = `winTap(winOffset)`; album = play/pause |
| swipe left / right | next / previous (`#next` / `#prev`) |
| swipe up / down | `pkBrowse(±1)` in the quick menu |

Reuse the prototype's `act()` logic. It must call the same functions the touch UI calls, so all
existing guards (control, pending, connection) apply.

## Design

1. **Native (Swift):** a new `YinweiHandGestures` class plus a method/event channel, following the
   existing one-channel-per-feature pattern (e.g. `YinweiAudioSessionChannel.swift`).
   - **Camera:** `AVCaptureSession`, front camera, about 640×480 at 30 fps, low priority. It must
     never touch the `AVAudioSession` category, mode or options; the Listen audio must not change.
   - **Vision:** `VNDetectHumanHandPoseRequest`, `maximumHandCount = 1`, on its own serial queue.
     If analysis is busy, drop the frame (`alwaysDiscardsLateVideoFrames = true`).
   - **Frame values**, matching the prototype exactly (see `gestures.cjs` around the
     `recognizeForVideo` call):
     - Palm centre: the mean of wrist, indexMCP, middleMCP, ringMCP and littleMCP.
     - **Coordinates:** Vision uses origin bottom-left with y up, so convert to y down. Mirror x for
       the front camera (x to the user's own right). Scale y by the frame's aspect (height / width)
       so both axes are in frame-width units.
     - `s` = distance from wrist to middleMCP, in the same units.
     - Ignore joints with confidence below 0.3. With no usable hand, send `{t, hand: false}`.
   - **Pose class `g`:** a small rule-based classifier from finger extension. A finger counts as
     extended when its tip is farther from the wrist than its PIP joint, by a margin.
     - `Open_Palm`: all 4 fingers extended (thumb not required).
     - `Closed_Fist`: no finger extended and thumb not up.
     - `Victory`: index and middle extended; ring and little curled.
     - `Thumb_Up`: thumb extended and pointing up, with the tip above the IP joint in the user's
       view; all 4 fingers curled.
     - Otherwise `null`.
     - `score` (0–1) comes from the joint confidences. Keep the classifier a **pure function on joint
       coordinates**, in a file the CI Swift tests can compile (see Tests).
   - **Output:** one frame `{t (ms), hand, g, score, x, y, s}` per analysed frame, at most 20 per
     second, to Dart. Only these numbers; never pixels or images.
   - **Lifecycle:** start only when Dart asks. Stop the session and release the camera when:
     - the setting is turned off;
     - the app goes to the background;
     - the room closes;
     - the user signs out;
     - the audio is interrupted.
     Report the camera permission state (not determined, denied, granted).
   - **`Info.plist`:** add `NSCameraUsageDescription`: "Yinwei uses the front camera only while hand
     gestures are on, to see your hand. Video stays on this iPad and is never saved or sent."
   - **New Swift files must be added to the Runner target** in
     `ios/Runner.xcodeproj/project.pbxproj` (PBXBuildFile, PBXFileReference, the group and the
     Sources phase), or the code must live in an existing compiled file. CI is the only compiler
     (there is no Xcode on this Windows laptop): keep Swift simple and check every API's iOS
     availability.
2. **Dart bridge:** in `lib/remote/listen_room_bridge.dart` and/or a small new
   `lib/remote/listen_gestures.dart`:
   - Page intents: `gestures {on: bool}` and `gestureConsent`.
   - Forward frames to the page as `YinweiListen.handFrame(json)`. Validate and clamp every number,
     and send nothing while `background` is set or the page is not ready.
   - Remember the on/off setting and consent locally (the same store as other iPad settings). The
     default is off.
3. **Page (`assets/listen_room/`):**
   - **Pure core:** port the pure parts (`createGestureCore`, `createSwipeLog`, `analyseCalibration`,
     `GESTURE`) into a shipped file. Either add them to `bridge.js`, or create a new file **and add
     it to the files `ListenRoomHtml` inlines** (`lib/remote/listen_room_html.dart`) and to
     `index.html`.
   - **UI:**
     - a hand button in the top bar (as in the prototype);
     - a one-time consent card that says what the camera is used for and that nothing is saved or
       sent;
     - a small status chip while it's on (pose and hold progress ring). No live video preview is
       needed on the iPad; if you add one, it must be native, not a page `<video>`.
     - Show the prototype's spoken-style feedback lines (`say()`) as the existing toasts.
   - **Calibration:** port it (`analyseCalibration`, the guided run, `localStorage`
     `yinwei.gestureCal`), with **thresholds capped at the defaults**, as in the prototype.
   - **Offline contract:** the shipped page must not contain any http(s) address (MediaPipe, CDN or
     model URLs). Do **not** port the MediaPipe loading code. The existing
     `test/listen_room/offline_contract_test.mjs` must pass.

## Tests (must all pass before you report)

- Move the three prototype tests into `test/listen_room/` against the shipped core, with unchanged
  expectations (43 cases).
- **Swift classifier tests:** pure-function cases for all four poses and `null`, built from joint
  coordinates, including mirrored and rotated hands. Add them to `tools/test_ios_capture.sh` like
  the existing `test/native_listen` harness (CI compiles them on macOS).
- **Bridge tests (Dart):**
  - frames are dropped when off, in the background, or not ready;
  - numbers are clamped and malformed frames ignored;
  - the on/off setting persists and defaults to off;
  - turning off stops the native side;
  - no frame data ever reaches the laptop.
- **Page tests:** each mapping row triggers exactly the existing function; nothing fires while
  calibrating; holds and swipes respect `pending`, control and connection like taps do.
- **Regression:** `flutter test` (the only known environment failure is
  `test/update/windows_package_integration_test.dart`, which needs a local `dist` zip), and
  `node --test test/listen_room/*.mjs test/remote/*.mjs`.

## Report back (for Claude's review)

- The files you changed, and confirmation that no protected or owner file was touched (show
  `git status` and the commit's `--stat`).
- Test counts, and any test you could not run (the Swift tests only run in CI).
- The exact `Info.plist` text and the pbxproj entries you added.
- What you could not verify on a device, which is all camera behaviour. Do not claim device
  acceptance.
- Open questions, if any, instead of guesses.
