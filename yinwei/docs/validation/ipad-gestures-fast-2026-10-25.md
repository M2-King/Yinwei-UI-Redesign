# Faster iPad gestures: local review, 2026-10-25

Base: `80fdbe3`, branch `codex/ios-capture-ci`. Source changes are local only. Build 71 does not contain this revision.
No push, CI dispatch, IPA, publication, laptop app install, or laptop bundle switch was performed.

## Result

All 65 exported legacy sequences match the exact event order: **zero misses, zero extras, zero later decisions**. The 39 matched legacy events improve by **32.15 ms mean / 363 ms p95** (old capture-frame event time minus new capture-frame event time). The prototype and legacy core are unchanged. Only the two owner-approved pose-show durations changed to <=120 ms.

Native tests also passed 20 new sequences and 53 classifier/configuration assertions, including real joint margins, all four clear poses at both 30/60 fps, a 60 fps small swipe, 300 ms same-direction repetition, short tracking loss, recoil, no-repeat fist, moving/low-confidence/disappearing hands, and pose-to-swipe transition protection.

## Verification

| Check | Result |
|---|---|
| Pure Swift classifier/engine/harness | Compiled and ran locally with official Swift 6.4.1 on Windows |
| Legacy fixtures | 65/65; 0 misses, 0 extras, 0 later |
| New sequences / native assertions | 20 / 53 passed |
| Exporter freshness | `export_fixtures.mjs --check` passed |
| Full Flutter regression | 1,061 passed, 7 skipped, 0 failed; no YINWEI_LISTEN_UDP override |
| Node Listen Room + remote suites | 126 passed, 0 failed |
| Dart analysis | No issues in changed implementation/tests |
| Isolated Dart/asset build | Passed; kernel present; five gesture/page assets match source; dev directory excluded |
| Native capture source | Swift parser passed; iOS SDK semantic/link validation still outstanding |
| macOS shell wrapper | Git Bash syntax check passed; xcrun wrapper itself not run on Windows |
| Browser interaction/layout | Synthetic decisions: consent, palm picker, Victory window, calibration suppression/report/apply, interruption and paused no-op verified |
| Browser console | Standalone room: 0 warnings/errors. Iframe automation produced a MutationObserver error; shipped scripts contain no MutationObserver. Tooling origin is inferred, not a device result. |
| Protected/owner baseline | 70 files checked by SHA-256, unchanged |

The isolated bundle is not a laptop application release. The Swift toolchain was extracted into workspace scratch directories; its installer was never executed. No system SDK or setting was changed.

## Synthetic decision latency

Values below combine the 65 legacy fixtures with the new replay cases. They are algorithmic frame-time measurements, not camera-to-action device measurements. Legacy named poses have margin 1 because the JS oracle has no joints. Separate tests verify real classifier margins and clear-pose timing at 30/60 fps.

| Event | Count | Decision p50 (ms) | Decision p95 (ms) |
|---|---:|---:|---:|
| Closed_Fist | 2 | 165.00 | 165.00 |
| Open_Palm | 2 | 165.00 | 297.00 |
| Thumb_Up | 4 | 165.00 | 297.00 |
| Victory | 1 | 165.00 | 165.00 |
| swipeDown | 11 | 66.00 | 66.00 |
| swipeLeft | 22 | 99.00 | 116.67 |
| swipeRight | 5 | 33.00 | 66.00 |
| swipeUp | 6 | 66.00 | 99.00 |

Pure-engine per-frame host timer: **p50 0.0049 ms / p95 0.0091 ms**, excluding classifier construction and Vision. The test executable was not optimized; this is a host harness measurement, not an iPad performance prediction.

## Stage-by-stage limits

| Stage | Measured here | Device work remaining |
|---|---|---|
| Camera -> Vision queue | No camera measurement; requested intervals are 33.33 ms at 30 fps or 16.67 ms at 60 fps | Actual rate, exposure, capture/queue age, sustainable 60 fps |
| Vision + joint classifier | Geometry correctness tests only; no Vision execution on Windows | Model runtime/confidence, orientation/mirroring, low light, blur, thermal load |
| Pure engine | Host per-frame timer and all fixture event times above | Device CPU timing and real trajectory equivalence |
| Main thread -> Dart -> WKWebView | Validation, lifecycle, ordered bounded delivery and slow-page tests passed | Physical device scheduling/serialization/eval delay under playback load |
| Page act() | Mapping, suppression, sync math and quantiles tested; browser events are synthetic | Real end-to-end delivery distribution and clock-offset uncertainty |

Camera PTS is converted from the capture session clock to CoreMedia host time. Decision latency uses the decision frame PTS minus its arming/evidence-start frame. Delivery latency uses the page act time minus that PTS after best-of-three round-trip clock alignment; it includes processing/delivery of the decision frame and reports half-RTT uncertainty. Do not add these figures to an unmeasured Vision estimate and call it device latency.

## Recognition and calibration notes

- The global 400 ms cooldown is removed. One low-speed frame re-arms; otherwise a distinct stroke can re-arm at 250 ms. A continuous recoil wave retains a conditional 400 ms safety bound until a 60 ms rest, preserving the unchanged anti-wave oracle. The intentional 300 ms repeat passes.
- Two consecutive frames above 2.4 hands/s establish speed evidence; an independent immutable peak >=3 hands/s retains the fidget boundary. Calibration may lower the sustained threshold to 2.2, but cannot remove that peak gate or the geometric noise safeguards.
- The displacement window includes pre-arm motion and at most 150 ms of tracking-gap carry. Raw movement only vetoes a one-frame glitch/filter tail; the trajectory and speed used for recognition are filtered.
- A quiet-frame commitment guard prevents nearly complete pose evidence firing on the first frame of a swipe. Fired same-pose latches survive movement until release.
- The page receives decisions and <=10 Hz status only. Ended numeric stroke summaries preserve guided calibration without sending coordinates, joints or images.
- Calibration schema 2 discards old unversioned settings, maps the existing report to native distance/speed/axis/re-arm/return parameters, and enforces easier-only caps in JS, Dart and Swift. Native reset acknowledgments include request IDs and capture-clock cutoffs to reject old calibration events.
- Per-event rolling p50/p95 (last 256 samples) and total counts appear in details and sanitized Copy audio diagnostics. Calibration counts decisions but never invokes actions or records an act-delivery sample.

## Every legacy fixture: event@camera-ms

Empty event lists are shown as `-`. Times are fixture time coordinates, so their absolute origin is arbitrary. All misses/extras and later flags are zero.

| Case | Old events | Native events | Misses | Extras | Later |
|---|---|---|---:|---:|---:|
| open palm held 0.6 s fires once [1] | Open_Palm@528.00 | Open_Palm@297.00 | 0 | 0 | no |
| a flashed palm (0.12 s) does nothing [1] | - | - | 0 | 0 | no |
| holding a pose for 3 s fires only once [1] | Thumb_Up@528.00 | Thumb_Up@297.00 | 0 | 0 | no |
| let go and show it again: fires again [1] | Thumb_Up@528.00, Thumb_Up@1694.00 | Thumb_Up@165.00, Thumb_Up@1331.00 | 0 | 0 | no |
| low confidence never fires [1] | - | - | 0 | 0 | no |
| a natural swipe (0.5 hand-sizes, fast) now fires [1] | swipeLeft@365.00 | swipeLeft@365.00 | 0 | 0 | no |
| the same distance done slowly (peak under 3 hand-sizes/s) does not [1] | - | - | 0 | 0 | no |
| a quick but tiny flick (0.3 hand-sizes) does not [1] | - | - | 0 | 0 | no |
| swipe right, up and down fire in their direction [1] | swipeRight@332.00 | swipeRight@332.00 | 0 | 0 | no |
| swipe right, up and down fire in their direction [2] | swipeUp@332.00 | swipeUp@332.00 | 0 | 0 | no |
| swipe right, up and down fire in their direction [3] | swipeDown@332.00 | swipeDown@332.00 | 0 | 0 | no |
| ratio 1.2: a slightly slanted swipe counts, a diagonal one does not [1] | swipeLeft@332.00 | swipeLeft@332.00 | 0 | 0 | no |
| ratio 1.2: a slightly slanted swipe counts, a diagonal one does not [2] | - | - | 0 | 0 | no |
| flick and bring the hand back: only the flick fires [1] | swipeLeft@332.00 | swipeLeft@332.00 | 0 | 0 | no |
| a flick that falls short, then a quick return: the return is ignored (no wrong direction) [1] | - | - | 0 | 0 | no |
| left, back, left again (after the cooldown): two lefts, no right [1] | swipeLeft@332.00, swipeLeft@982.00 | swipeLeft@332.00, swipeLeft@982.00 | 0 | 0 | no |
| left then a deliberate right a second later: both fire [1] | swipeLeft@332.00, swipeRight@1532.00 | swipeLeft@332.00, swipeRight@1532.00 | 0 | 0 | no |
| fast swipe that blurs out mid-way still counts [1] | swipeLeft@333.00 | swipeLeft@333.00 | 0 | 0 | no |
| a one-frame dropout in the middle does not break a swipe [1] | swipeLeft@432.00 | swipeLeft@399.00 | 0 | 0 | no |
| a hand that disappears while still does nothing [1] | - | - | 0 | 0 | no |
| a slow drift across the frame is not a swipe, and not a hold [1] | - | - | 0 | 0 | no |
| tremor alone never swipes (jitter up to 1.2% of the frame per frame, several times real tracking noise) [1] | - | - | 0 | 0 | no |
| a single-frame jump (tracking glitch) never fires [1] | - | - | 0 | 0 | no |
| a fast back-and-forth wave gives at most two swipes [1] | swipeRight@66.00, swipeRight@660.00 | swipeRight@66.00, swipeRight@660.00 | 0 | 0 | no |
| the hand leaving the frame resets a hold [1] | - | - | 0 | 0 | no |
| each stroke is reported with its reason (for the panel) [1] | - | - | 0 | 0 | no |
| motion reports progress towards a swipe [1] | - | - | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [1] | swipeLeft@266.00 | swipeLeft@266.00 | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [2] | swipeLeft@299.00 | swipeLeft@299.00 | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [3] | - | - | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [4] | swipeDown@299.00 | swipeDown@299.00 | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [5] | swipeUp@332.00 | swipeUp@332.00 | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [6] | swipeDown@332.00 | swipeDown@332.00 | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [7] | swipeUp@299.00 | swipeUp@299.00 | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [8] | swipeDown@332.00 | swipeDown@332.00 | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [9] | - | - | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [10] | swipeUp@332.00 | swipeUp@332.00 | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [11] | - | - | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [12] | - | - | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [13] | - | - | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [14] | - | - | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [15] | - | - | 0 | 0 | no |
| replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones [16] | - | - | 0 | 0 | no |
| a very fast flick with one noisy backward frame is not split in two (fires once) [1] | swipeLeft@332.00 | swipeLeft@332.00 | 0 | 0 | no |
| browsing: down, slow return, down again 0.55 s later: two downs (shorter cooldown) [1] | swipeDown@332.00, swipeDown@982.00 | swipeDown@332.00, swipeDown@982.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [1] | swipeLeft@299.00 | swipeLeft@266.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [2] | - | - | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [3] | swipeUp@332.00 | swipeUp@332.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [4] | - | - | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [5] | - | - | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [6] | swipeRight@266.00 | swipeRight@266.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [7] | swipeLeft@266.00 | swipeLeft@266.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [8] | - | - | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [9] | - | - | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [10] | swipeDown@299.00 | swipeDown@299.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [11] | - | - | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [12] | - | - | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [13] | swipeDown@266.00 | swipeDown@266.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [14] | - | - | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [15] | swipeDown@332.00 | swipeDown@332.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [16] | - | - | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [17] | swipeDown@299.00 | swipeDown@299.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [18] | swipeUp@365.00 | swipeUp@365.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [19] | swipeDown@332.00 | swipeDown@332.00 | 0 | 0 | no |
| replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do) [20] | - | - | 0 | 0 | no |

## Review boundaries and handoff

No protected/owner file changed: Rust engine/crates, app_audio_route, laptop Listen audio, listen_udp, ReplayKit audio, cover code, soda_library, soda_track_launcher, player_screen, app_top_bar, music.js/music_test and my_lists were preserved. The original dirty website, DLL and golden changes remain the owner's work. Only the explicit gesture file list is staged/committed.

Full working-tree status, final commit stat, logs, fixture JSON results, bundle verification and browser screenshots are retained under `outputs/gesture-fast/` (intentionally untracked). Use `git show --stat HEAD` for the final committed file stat.

Outstanding: the macOS xcrun wrapper, iOS Runner build/link, physical front camera, permission revocation, real Vision accuracy, all iPad orientations, actual p50/p95 end-to-end targets, calibration on natural hand motion, battery/thermal behavior, audio-route continuity, playback/HRTF/AirPlay under camera load, and persistent WKWebView storage on device. No device acceptance is claimed.

No blocking product question remains after the owner's two pose-fixture decisions. Device review should specifically examine natural fast repeats versus the preserved anti-wave guard. Claude/owner reviews this local commit before deciding on CI, signing or distribution.
