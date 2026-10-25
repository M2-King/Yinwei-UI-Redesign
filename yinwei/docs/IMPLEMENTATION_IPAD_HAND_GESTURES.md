# iPad Listen Room hand gestures

The faster native recognition revision is local to `codex/ios-capture-ci` and follows
`CODEX_PROMPT_GESTURES_FAST.md`, including the owner's approved 120 ms flash cases.
Build 71 predates this revision. This revision has not been pushed, built as an IPA,
published, or accepted on an iPad. The owner/Claude handles that review and release.

## Architecture and protected boundaries

`AVCaptureVideoDataOutput -> Vision -> YinweiHandClassifier -> YinweiGestureEngine`
runs on the existing serial utility queue. The pure engine imports Foundation only.
The main thread and Flutter/WKWebView receive results after recognition; the page
calls the same touch actions. It never runs `createGestureCore` on camera frames.
The legacy JS core remains solely for the unchanged oracle and pure calibration
report. The browser design prototype is unchanged.

Capture keeps VGA and discards late buffers. It requests 60 fps when the active
format supports 60, otherwise 30. Every delivered camera buffer is analysed; neither
native nor Dart has the former 50 ms throttle. Actual sustainable analysis fps,
Vision speed, thermal impact and 60 fps format negotiation need the iPad. No smaller
preset was selected because its tracking/latency tradeoff cannot be measured here.
Vision reads only the fifteen joints used by the classifier, not `.all`.

No engine/crate, Listen audio loop, UDP path, ReplayKit audio, cover cache, audio
route, laptop bundle, or owner library/player/music/list files were changed. The
existing spatial state and playback action authority remain unchanged.

## Privacy and lifetime

The camera remains off by default and requires consent and a hand-button tap.
Remembered on never automatically starts capture when a room opens or resumes.
Background, sign-out, room closure, audio interruption, page loss/reload and off all
stop capture. An outstanding permission/configuration/clock reply cannot undo a
later suspension. Permission denial retains the existing explanation.

Both `automaticallyConfiguresApplicationAudioSession` and
`usesApplicationAudioSession` remain false. There is no microphone, audio-session
write, image bridge, recording, image storage, network upload, or laptop frame path.
The existing Info.plist camera explanation is unchanged:

> Yinwei uses the front camera only while hand gestures are on, to see your hand.
> Video stays on this iPad and is never saved or sent.

Only fixed gesture/state labels and bounded numeric results cross the local bridge.
The channel name remains `dev.yinwei/hand_gestures/frames` for registration compatibility;
its payload is now decisions/status, not hand frames:

- Decision: `{event, t, latencyMs}`. No decision is coalesced away.
- Status, at most 10 Hz: `{t, pose, progress, strokes}`. Progress is in [0,1].
- `strokes` contains only ended calibration summaries: direction/event, start time,
  travel in hand sizes, peak speed, ratio, gap, fired. No coordinates or joints.

Dart validates each schema and whitelists every field. Events and status have
independent monotonic checks so an event and status at the same camera time both
arrive. WKWebView delivery is serial: up to 32 decisions wait, status is coalesced
while retaining at most 16 summaries. Overflow stops capture; it does not silently
lose a recognized action. Context generations clear queued work after suspension.

## Recognition and geometry

The connection physically rotates buffers into the current interface orientation.
Connection mirroring is disabled; Vision receives `.up`. The classifier mirrors and
flips once: `x=1-visionX`, `y=(1-visionY)*height/width`. X points right, Y down, in
frame-width units. Palm centre is the mean of wrist and the four MCPs; size is
wrist-to-middle-MCP distance. Orientation changes reset recognition.

The existing 0.3 minimum joint confidence, 0.15-size extension dead band, joint
requirements and four pose names are retained. The classifier additionally returns
signed per-finger margins and minimum pose certainty multiplied by required-joint
confidence. Ambiguous extension, curl or thumb-up geometry cannot become a high
certainty pose. Required-joint confidence below 0.6 resets pose evidence.

The centre and size use a One Euro filter: a low-pass derivative drives an adaptive
cutoff, strong at rest and responsive during motion. Derivative cutoff is 1 Hz,
minimum cutoff 1.2 Hz; position beta is 400 in hand-normalized units. Swipe velocity
uses the filtered position derivative; pose stability uses the filtered velocity.
A quiet-frame check also prevents a nearly-ready pose firing as motion starts.
Filter state survives a tracking gap up to 150 ms; any missing hand immediately
clears pose evidence. Longer gaps reset the filters and stroke history too.

Swipes arm above 1.5 hand sizes/s. They commit after two consecutive frames above
2.4 hand sizes/s, with a separate immutable peak gate of 3 hand sizes/s preserving
the measured fidget protection. The consecutive evidence is retained through
ordinary deceleration. Distance uses the approximately 150 ms motion window,
including the pre-arm displacement. A tracking gap can extend that window by at
most 150 ms without inventing movement frames.

Defaults are 0.34 hand sizes for horizontal/vertical commit distance, with the
original frame floors 0.045 horizontally and 0.036 vertically, axis ratio 1.2,
straightness 0.6 and at least two actual moving frames. Clear fast flicks get a
bounded distance discount down to the original 0.65 floor. A single tracker jump
cannot turn its filter tail into a second moving frame. Blur/exit retains the
original 70% distance / recent speed >=4 exception and movement/straightness gates.

There is no global 400 ms cooldown. A slow frame re-arms, otherwise a distinct stroke
can re-arm after 250 ms. A continuous flick/recoil wave additionally retains the old
400 ms anti-wave bound until it settles for 60 ms; this preserves the existing
at-most-two-wave oracle without blocking the tested deliberate 300 ms repeat.
Immediate opposite-direction returns along the same axis stay ignored for 600 ms.
An ignored return never replaces the real flick or suppresses the next same-direction swipe.

Each pose has a leaky evidence accumulator, rapid decay for other poses, and a
150 margin-ms threshold with an absolute minimum of 150 ms. Clear joint geometry
at confidence 0.9 fires within 250 ms at both 30/60 fps in the harness. Movement,
low confidence, missing hands and long gaps reset evidence. A fired same pose stays
latched through movement until released; a held fist cannot repeatedly close menus.
A clear 300 ms pose intentionally fires; <=120 ms flashes do not.

Hand coordinates never enter spatial coordinates. Three.js/audio remain X right,
Y up, -Z front, with listener facing -Z and upright +Y. Azimuth 0 is front and +90
right; elevation is positive up. Audio's metre direction is
`(sin(az)*cos(el), sin(el), -cos(az)*cos(el))`. Room display distance remains
`ln(1+d)/ln(11)*4.4`, ear height 1.1; RoomMath remains the only room conversion.

## Calibration, actions and instrumentation

The guided 13 phases retain preparation/go/return timings and suppress all actions.
Native ended-stroke summaries feed the existing pure calibration report. Its output
is remapped to `commitHands`, `commitHandsV`, `swipeSpeed`, `swipeRatio`, `rearmMs`,
`returnMs`; Dart and Swift independently enforce floors and default upper caps.
Applying stores `{version:2,tuned,when}` under the existing `yinwei.gestureCal` key.
Older unversioned data is discarded. The explicit continuous-reverse checkbox sets
returnMs=0. Restoring defaults clears storage. Configuration resets the engine
without restarting capture or touching audio. Request IDs and a native timestamp
cutoff reject stale calibration replies and delayed calibration events.

Action mapping remains: palm album->compact, fist window->compact->album, Victory
compact->window, thumb-up through existing pkSelect/winTap/play, left/right through
next/previous buttons, and up/down through existing picker browsing. Existing touch
control leases, connection checks and selection refusals remain authoritative.

Capture PTS is converted from `session.masterClock` to the CoreMedia host clock.
`t` is the decision frame's capture timestamp, not main-thread delivery time.
`latencyMs` is that frame time minus the actual arming frame (swipe) or first frame
of the current steady evidence episode (pose). These algorithmic delays exclude
processing after the decision frame was captured.

The page estimates its clock offset from the best of three request/reply round trips
and reports half-RTT uncertainty. Actions wait for that synchronization. Delivery
is `act()` time minus the mapped event time, including Vision/engine/bridge delivery
of the decision frame. It is an estimate, not a calibrated physical clock probe.
The detail panel and Copy audio diagnostics expose per-event counts and decision /
delivery p50/p95, with the last 256 samples per type and total counts for this page.
Calibration decisions count but have no action-delivery sample. Only bounded numeric
aggregates enter audio diagnostics; camera frames and raw event history do not.

## Build wiring, verification and rollback

Runner Sources includes `YinweiHandPose.swift`, `YinweiGestureEngine.swift` and
`YinweiHandGestures.swift`. AppDelegate registration and camera privacy text remain
unchanged. `tools/test_ios_capture.sh` checks fixture freshness and compiles the pure
engine/classifier harness on macOS alongside the existing audio tests.

See [the dated review report](validation/ipad-gestures-fast-2026-10-25.md) for every
fixture's old/new event time, measured host latency, test results and device limits.
The same pure Swift sources were compiled and run locally on Windows using an
extracted official Swift toolchain, without running an installer or changing
system settings. The macOS wrapper and iOS Runner still need the owner's Mac/CI.
No push, CI run, IPA or publication was performed for this revision.

Rollback is a revert of this revision's local commit, including its versioned
calibration adapter. Alternatively, leave the existing hand switch off. No audio
engine, spatial-state, transport or server migration is required.

References: [One Euro paper](https://gery.casiez.net/publications/CHI2012-casiez.pdf),
[Apple capture clock](https://developer.apple.com/documentation/avfoundation/avcapturesession/masterclock),
[official Windows Swift toolchain](https://www.swift.org/install/windows/).
