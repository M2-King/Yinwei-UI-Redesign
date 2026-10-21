# iPad Listen Room matrix link — engineering review

Branch: `codex/ios-capture-ci`. Implementation authorized by the explicit task.
At the implementation-review checkpoint, no application build, commit, staging,
push, deployment or publication had been performed. The owner subsequently
authorized committing and pushing this change and building an IPA for direct
delivery through the existing unsigned iOS workflow. Protected deployment files
and unrelated work, including the modified runner DLL, remain outside this change.

## Architecture audit

1. Stack: Flutter/Dart host and iPad shell; offline HTML/CSS/JavaScript room; vendored Three.js; native spatial backend through FFI.
2. Entry points: `lib/main.dart`, `PlayerScreen`, `ios_listen_room_screen.dart`, and `assets/listen_room/index.html`.
3. Audio engine: existing `EngineController` delegates to the engine API/native bridge. This change only calls its existing acknowledged array route.
4. HRTF/DSP: native protected behavior; no changes.
5. Playback: existing session, playback controller and Live paths; no changes.
6. Spatial state: `ArrayLayout` in `spatial_params.dart` owns speaker poses, matrix link, spread and rest. Its existing methods remain authoritative and unchanged.
7. UI state: the laptop reads that layout; the iPad receives coordinator snapshots. The page keeps a temporary gesture draft only.
8. Rendering: `room.js` creates eight physical cabinet groups once, then updates transforms from `speakerPose()`.
9. Coupling: page intents → ListenRoomBridge → gateway/session commands → AppSessionCoordinator → existing array callback → EngineController. Snapshots return over the same route.
10. Three.js integration: existing `speakerPose()` preview and the fixed cabinet pool. No renderer changes or mesh construction during gestures.
11. Coordinate risk: azimuth wrapping and elevation clamping must match ArrayLayout. X right, Y up, Z negative forward; listener faces −Z at the origin. Azimuth 0 front, +90 right; elevation +90 up; distance 0.5–10 real metres. Room axes match, with ears at Y=1.1 and a display-only logarithmic radius (`ln(1+d)/ln(11)*4.4`). `room-math.js` documents and tests the inverse.
12. Performance risk: rebuilding meshes or the popover during input. The patch does neither. Only labels, slider values and existing cabinet transforms change.
13. Protected: `crates/spatial_core`, HRTF, DSP, Live capture, DLLs, `deployment.json`, `outputs/`; untouched by this task.
14. Change scope: Listen Room UI/bridge/review host, session command adapter, associated tests and review evidence.
15. Architecture: extend the existing route; no second spatial authority. Matrix rest stays on the host and is never reconstructed from browser geometry.
16. Phases: trace existing semantics; add validated commands; expose link/group controls; add regression tests; verify browser and collect evidence.
17. Tests: full Flutter suite, Node bridge/math/gesture tests, Dart analysis, browser controls/console, responsive screenshots and room speed test. Native audible acceptance still requires the laptop/iPad devices.
18. Rollback: revert only this task's eight source/test files. Remove the added matrix review artifacts if desired. Do not reset unrelated working-tree changes or the runner DLL.

## Implemented behavior

- Place in 2.0 exposes **Link speakers**, with **Link / Linked** wording and an accessible pressed state.
- Linked sliders become **Array rotation / Array height / Array distance**. There is no spread or angle control.
- `matrixLink` becomes `array.matrix.link`. It uses `setMatrixLinked` only on a transition, preserving an already-linked laptop spread/rest on repeated requests.
- `matrixAdjust` becomes `array.matrix.set` with an index, axis and value. Rotation/height call `moveSelectedInGroup` only for that axis; distance calls `setAllDistance`. This preserves unequal distances after a laptop speaker addition, exactly like the sidebar.
- Cabinet dragging retains `speakerPlace` / `array.speaker.set`, using the laptop island controller's full-pose semantics.
- Both new commands use existing capabilities, array revision, lease, serialization, native acknowledgement and command-ID deduplication checks, including rejection of obsolete completed retries.
- Unlink uses the existing model semantics: poses stay fixed, matrix rest clears, spread resets to 1. Ordinary linked pose edits leave laptop-set spread untouched.
- Matrix spread is received for synchronization only. JS accepts a finite number in **0.12–2.6**, with no coercion; matrix flags accept booleans only.
- A gesture commits once on release. Immediate edit locking closes the release-to-acknowledgement gap. Laptop revision changes, takeover and connection loss discard the preview.

## Verification

- Full Flutter test suite: **889 passed, 6 skipped**, exit 0.
- Node `test/listen_room/*.mjs`: **39 passed**, exit 0.
- Release preflight, Node `test/listen_room/*.mjs test/remote/*.mjs`: **47 passed**, exit 0.
- Whole-project `dart analyze`: **117 existing findings**, 6 warnings and 111 informational notices, no errors. None are in the four changed Dart files.
- Regression coverage includes link/unlink, rest/pose preservation, linked rotation/height/distance, nonuniform linked distances, spread preservation, stale revisions, duplicate IDs, expired lease/takeover, Point round trip, laptop snapshot updates, numeric/boolean validation, eight-cabinet preview and cancellation.
- Browser review: native-shaped eight-cabinet room, link/unlink, axis controls, portrait 820×1180 and landscape 1180×820. Console warning/error query returned an empty list.
- Actual top-view cabinet hit testing and two drags were exercised. Each drag emitted one `speakerPlace` on release. The first moved the selected cabinet from +20° / 4.0 m to +34° / 3.6 m; all eight rows moved +14° together and retained +18° elevation. The second reached +43° / 3.7 m. Both post-drag reports showed a fixed pool of 8, 218 meshes and 118 GPU geometries, with no growth across the repeated drag. Top-view reports are separate from the camera-turn benchmark below.
- Review generated with `python yinwei/tools/listen_room_review.py yinwei/docs/validation/listen-room-speakers/matrix-review.html`.
- No physical iPad/Safari or audible playback/HRTF listening test was performed. The browser uses the explicit review stand-in; Flutter audio tests use existing mocks/fixtures.

## Speed test

Desktop review browser, Windows, RTX 5070 Laptop GPU / ANGLE D3D11, DPR 1, viewport 1180×820. Eight speakers, identical poses (selected speaker −20° azimuth, +18° elevation, 1.8 m), same tab; linked first, then unlinked without moving the speakers.

| Room speed-test pass | Linked | Unlinked |
| --- | ---: | ---: |
| Full, maximum ratio 1× | 238 fps | 238 fps |
| Full, reduced ratio 1× | 238 fps | 238 fps |
| Light, maximum ratio 1× | 238 fps | 238 fps |
| GPU geometries | 117 | 117 |
| Cabinet pool | 8 | 8 |
| Draw calls / triangles | 200 / 123k | 200 / 123k |

These are the room's median-frame camera-turn benchmark, not an iPad hardware measurement or a group-drag benchmark. At DPR 1 its two Full passes use the same ratio. Full reports are retained in `matrix-speed-linked.txt` and `matrix-speed-unlinked.txt`.

Actual drag intents and diagnostics are in `matrix-drag-verification.txt` and `matrix-drag-repeat.txt`; `matrix-drag-portrait.jpg` shows the resulting group pose.

## Screenshots

| State | Landscape | Portrait |
| --- | --- | --- |
| Eight linked speakers | [Landscape](matrix-linked-landscape.jpg) | [Portrait](matrix-linked-portrait.jpg) |
| Intermediate rotation (−70° → −20° anchor) | [Landscape](matrix-rotation-landscape.jpg) | [Portrait](matrix-rotation-portrait.jpg) |
| Height changed to +18° | [Landscape](matrix-height-landscape.jpg) | [Portrait](matrix-height-portrait.jpg) |

Rotation captures show the intermediate array pose after the release acknowledgement; they are not a frozen pointer-held frame.
