# iPad Listen Room hand gestures

Implemented locally on `codex/ios-capture-ci`, following the approved architecture audit.
The camera feature is off by default. No build has been published or accepted on a device.

## Boundaries and behaviour

`YinweiHandGestures` owns an independent video-only AVCaptureSession. Apple Vision detects
one hand on its serial utility queue. VGA capture requests 30 fps; analysis and emission
are limited to at most 20 fps, and late frames are discarded. A main-thread delivery slot
and a single in-flight Dart-to-WebView call prevent frame backlogs.

Both `automaticallyConfiguresApplicationAudioSession` and `usesApplicationAudioSession`
are false. There is no microphone input, AVAudioSession category/mode/activation write,
image bridge, image storage, network request, laptop frame message or playback hook.
Listening and audio routing continue through their existing paths.

The native method channel is `dev.yinwei/hand_gestures` (`permission`, `start`, `stop`);
its event channel is `dev.yinwei/hand_gestures/frames`. Native status events report stopped
or orientation-reset state; data frames contain only `{t, hand, g, score, x, y, s}`, or
`{t, hand:false}`. Dart rejects malformed/nonfinite fields, bounds numeric values, rejects
unknown poses and nonincreasing timestamps, and forwards only the whitelisted frame.

`ListenGestures` holds consent and on/off preferences in `listen_gestures.json` in the
application-support directory, the same storage location/pattern as `listen_sound_quality`.
Missing or corrupt preferences default to off. Remembered on is not a camera-start request:
opening the room always requires a hand-button tap. Backgrounding, closing, sign-out,
audio interruption, page reload/loss, and disabling stop the camera. Returning to the
foreground never automatically restarts it. Permission completion cannot undo a later stop.

The one-time explanation precedes the native permission prompt. No video preview is used.
The status chip shows pose/hold progress, pause state or a fixed camera error message.
The hand button remains available while permission is pending so the owner can cancel.
The chip's close button can also turn the preference off while paused, without reopening
the camera first.

The shipped pure core is copied from `docs/design/gestures/gestures.cjs` without changing
its measured hold/swipe rules. Its 43 original assertions are retained; only the loaders
now point at the shipped classic script (the repository root is an ES-module package).
The new script tags are discovered automatically by the existing `ListenRoomHtml` inliner;
no inliner rewrite or dependency is required. Neither new script contains a web address.

| Gesture | Existing touch entry point |
| --- | --- |
| Open_Palm, 500 ms | album -> `setBrowseMode("compact")` |
| Closed_Fist, 400 ms | window -> compact; compact -> album |
| Victory, 450 ms | compact -> `setBrowseMode("window")` |
| Thumb_Up, 500 ms | `pkSelect(pkFocus)`, `winTap(winOffset)`, or `#play.click()` |
| Left / right swipe | `#next.click()` / `#prev.click()` |
| Up / down swipe in compact | `pkBrowse(1)` / `pkBrowse(-1)` |

Confirmation always calls the existing selection function, including when the current song
is paused. This deliberately follows touch's resume behaviour, resolving the discrepancy
identified in the audit. Existing selection refusals retain their own toast. Transport
actions retain touch's existing Dart control-lease, pending/wait and connection behaviour.
Browsing does not play or mutate spatial state.

Calibration preserves the prototype's 1100 ms preparation, up to 2600 ms stroke, 700 ms
return, three repetitions in each direction, and 5200 ms alternating run. It records
stroke summaries in memory and suppresses all gesture actions while running. Apply stores
only `{tuned,when}` in localStorage `yinwei.gestureCal`; finite whitelisted settings are
capped at defaults on both apply and load. The explicit continuous-reverse checkbox sets
returnMs to zero. Restore defaults clears that key. No frames/joints/video are persisted.

## Geometry and classifier choices

The native connection physically rotates video buffers to the current interface orientation
using APIs available at the existing iOS 16.2 minimum. Mirroring is explicitly disabled on
that connection. Vision receives `.up`, with bottom-left origin. The pure adapter then does
exactly one mirror and flip: `x = 1 - visionX`, `y = (1 - visionY) * height / width`.
Palm centre is the mean of wrist and the four MCP joints. `s` is wrist-to-middle-MCP distance
in those same frame-width units. Dart bounds X to [0,1], Y to [0,4/3], and s to
[0.0001,5/3], covering either orientation of VGA. Native monotonic uptime in milliseconds
is rebased once per camera run to the page's performance clock for guided calibration.
Orientation changes reset the detector so a rotated image does not continue an old stroke.

The pure Swift classifier ignores joints below confidence 0.3. A finger is extended when
its tip's wrist distance exceeds its PIP's wrist distance by more than `0.15 * s`.
Tips no farther than their PIP count as curled; the positive dead band is unknown, never
silently curled. All four extended -> Open_Palm; index/middle only -> Victory; all four
curled plus an extended upward thumb -> Thumb_Up, otherwise Closed_Fist. Up requires the
tip at least `0.15 * s` above the IP and vertical movement greater than horizontal movement
in the user's view. Missing thumb information cannot confirm or classify a fist. Open_Palm
and Victory do not require the thumb. Score is the minimum confidence of the required
joints, capped to [0,1], not a calibrated MediaPipe probability. Low-confidence poses still
have to satisfy the unchanged core's minScore 0.6. Vision/MediaPipe recognition equivalence
and these new classifier parameters require device review.

Audio and Three.js coordinates are unchanged: X right, Y up, -Z front; listener facing -Z,
upright +Y. Azimuth 0 is front, +90 right; elevation positive up. Audio uses metres and a
unit direction `(sin(az)*cos(el), sin(el), -cos(az)*cos(el))`. Listen Room displays radius
`ln(1+d)/ln(11)*4.4`, with ear height 1.1; `RoomMath.toRoom`/`fromRoomPoint` remain the only
room conversion. Hand coordinates never feed those spatial conversions.

## Native project wiring

Info.plist now includes the exact requested value:

```xml
<key>NSCameraUsageDescription</key>
<string>Yinwei uses the front camera only while hand gestures are on, to see your hand. Video stays on this iPad and is never saved or sent.</string>
```

Runner pbxproj additions (each build ID also appears in Runner's Sources phase, and each
file ID in the Runner group):

```text
D8A0000B0000000000000201 /* YinweiHandPose.swift in Sources */ = {isa = PBXBuildFile; fileRef = D8A0000B0000000000000010 /* YinweiHandPose.swift */; };
D8A0000B0000000000000202 /* YinweiHandGestures.swift in Sources */ = {isa = PBXBuildFile; fileRef = D8A0000B0000000000000011 /* YinweiHandGestures.swift */; };
D8A0000B0000000000000010 /* YinweiHandPose.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = YinweiHandPose.swift; sourceTree = "<group>"; };
D8A0000B0000000000000011 /* YinweiHandGestures.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = YinweiHandGestures.swift; sourceTree = "<group>"; };
```

AppDelegate registers the channel alongside the existing feature channels.
`tools/test_ios_capture.sh` compiles `YinweiHandPose.swift` with
`test/native_gestures/main.swift` in its own macOS Swift executable. The 26 cases cover all
four poses, null, mirroring, rotated hands, confidence, missing/degenerate joints, centre,
size and coordinate conversion. These Swift tests have NOT been run on this Windows host;
no CI workflow was triggered. Runner compilation is also outstanding.

## Validation and handoff

- Node regression: 118 passing test-runner entries, including the three unchanged prototype
  scripts' 43 individual assertions and 23 new gesture page tests. Offline contract passes.
- Flutter regression: 1053 passed, 7 skipped, zero failures with YINWEI_LISTEN_UDP=0 only in
  the test process. The inherited environment sets it to 1 and breaks the existing test
  asserting UDP is off by default. No application or user environment setting was changed.
- Static analysis of the changed Dart implementation/tests: no issues.
- Windows Dart/asset bundle built in ignored `build/gesture_validation_assets`. Both new
  scripts and kernel_blob.bin are present; review-only dev assets are absent. No desktop
  bundle was replaced or launched.
- iOS-targeted asset bundle attempted but cannot complete native build hooks without xcrun.
  This is not a successful iOS/Swift build. No IPA build, publication, push or CI run occurred.
- Browser checks use `test/listen_room/gesture_browser_fixture.html`, a same-origin iframe
  with synthetic native frames, not a camera. At room viewports 1024x768 and 768x1024:
  consent, palm-to-picker, Victory-to-window, guided calibration through its report/apply,
  and interruption-to-paused were exercised. Screenshots are retained outside the repository.
  A fresh room's console was checked separately from browser-tool locator errors.
- Before committing, compare SHA-256 against the pre-change baseline of the 70 protected
  and owner files, and stage only the hand-gesture files. Existing dirty website, DLL,
  golden, owner library/player/music, my_lists and other untracked work must remain intact.

Device acceptance remains entirely outstanding: permission dialogs/revocation, front-camera
orientation and mirroring on each iPad orientation, Vision accuracy, thermal/battery impact,
release on every lifecycle transition, actual playback continuity/HRTF/audio route and AirPlay,
and localStorage survival across WKWebView/app restarts. The camera remains opt-in and no
distribution is authorized by this implementation commit. The owner/Claude performs the
macOS CI build, device review and any later distribution.

Rollback: disable the hand button; alternatively revert only this feature's commit. No DSP,
audio engine, routing, Listen scheduling, protected cover code or protocol migration is needed.
