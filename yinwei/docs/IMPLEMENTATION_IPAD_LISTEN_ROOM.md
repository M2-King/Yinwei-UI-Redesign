# iPad Listen Room (v6 "Moonlight Room") — implementation plan

Status: **P1–P3 implemented; P4's build checks added. All committed locally on `codex/ios-capture-ci`, not pushed.
The iOS build and the iPad checks are still pending. P5 has not started.**
The web prototype passed its ship line: you approved all its
results on 2026-10-19 (v10.2, see [IMPLEMENTATION_LISTEN_ROOM_PROTOTYPE.md](IMPLEMENTATION_LISTEN_ROOM_PROTOTYPE.md)).
Nothing has been pushed or installed for this work, and no workflow has been run for it.

This plan turns the approved web prototype, v10.2 "Moonlight Room", into the iPad app's
**Listen to laptop** screen, then the phones, a UI-only Windows update, and the same screen on the Mac (section 10). Today the
iPad screen is the simple Flutter form in `lib/mobile/ios_laptop_listen_screen.dart`.
Section 11 covers the builds you install: the **iPad IPA**, the **Windows bundle** (UI only) and the **Mac DMG**.

- Approved prototype (reference only, not shipped): [`docs/design/listen-room-v10.2.html`](design/listen-room-v10.2.html)
- Live prototype link: https://claude.ai/artifact/LLuwfYaC2qSgurG2ESkWUm (version 21 = v10.2)
- Listening logic it sits on (already built and tested): `lib/remote/laptop_listen_controller.dart`,
  `lib/remote/remote_owner_client.dart`, `lib/platform/ios_laptop_listen_output.dart`,
  `ios/Runner/YinweiReplayKitProbe.swift` (listen mode, `dev.yinwei/now_playing`)

---

## 1. Goal and non-goals

**Goal.** The iPad shows the 3D Moonlight Room as the Listen to laptop screen:
- the glass header, side panel (Layout / Motion / Place) and player bar;
- the sound you can drag in the room;
- every connection state the prototype shows.

Listening keeps working in the background and on the lock screen, exactly as it does now.

**Non-goals.**
- No change to the audio engine (`spatial_core`), HRTF/DSP, Live Transfer, or the laptop gateway protocol.
- No change to the capture route (`IosRemoteLiveSession`) or to how the native player behaves for it.
- The laptop's own 3D workspace (`assets/spatial_workspace/`, Three.js r160) is not touched.

---

## 2. Architecture

```
Flutter (iPad)
  IosListenRoomScreen ─────────────── sign-in (Flutter, native fields)
     │  owns
     ▼
  LaptopListenController  ◄── single source of truth (laptop snapshot, lease, listening)
     │                │
     │ state JSON     │ intents (play, place, layout…)
     ▼                │
  WKWebView (webview_flutter)  "assets/listen_room/index.html"
     ├─ room.js   Three.js r128 scene: room, sound pod, speakers, camera
     └─ ui.js     glass header, side panel, popovers, player bar
                         │
  IosLaptopListenOutput  ▼  (unchanged) → YinweiRemoteReturnPlayer (listen mode)
                            → dev.yinwei/now_playing (lock screen)
```

Rules:
- **The page is a view, not a second state store.** It renders what Dart sends and sends intents back.
  The only state it keeps is transient: a drag in progress, which popover is open, and the camera.
  This follows the AGENTS rule of no independent, conflicting spatial state.
- **Dart sends intents through the existing commands.** `LaptopListenController.command(...)` uses the
  same lease rules, retry on `stale_state`/`control_lost`, and `control_taken` handling as today.
- **Sign-in stays in Flutter.** The password never enters the WebView. Native fields keep iOS
  password autofill. The sign-in screen is restyled to match the room (navy glass card); it is not
  the HTML card.
- **The 3D room only renders while it is on screen.** It stops when the app goes to the
  background, the iPad locks, or you leave the screen. Background listening is unaffected, because
  audio never goes through the WebView.

### Why a WebView, not native Flutter

The room uses real-time reflections, bloom, PBR materials and shadows. Flutter's `CustomPainter` (as used by
`MobileSpatialStage`) cannot do this. A Flutter 3D engine would mean rewriting the scene.
The app already ships `webview_flutter` (WKWebView on iOS) and a WebView host for the laptop's
workspace (`WKWebViewDriver` in `lib/platform/macos_webview_host.dart`, `YinweiNative` JS channel),
so this reuses an existing, tested path.

### Why Three.js r128 here, not the app's r160

The approved look was built on r128 and its `examples/js` add-ons (`Reflector`, `EffectComposer`,
`UnrealBloomPass`, `RoundedBoxGeometry`). r160 has no `examples/js`. It also manages colour
automatically (the prototype converts colours by hand) and uses physical light units, so the same
values would render differently. Shipping r128 for this one page keeps the approved image exactly.
**Follow-up (not in this plan):** move the room to r160 modules so the app ships one Three.js.

---

## 3. Coordinates (engine and room)

Both use the engine frame; there is **no axis flip** between Three.js and the audio engine.

| Quantity | Definition |
|---|---|
| X | +X to the listener's right |
| Y | +Y up |
| Z | −Z in front of the listener (the window) |
| Azimuth | 0° front, +90° right, −90° left, ±180° rear (canonical range −180…180) |
| Elevation | 0° ear level, +90° straight up, −90° straight down |
| Distance | 0.5–10 m, sent to the engine unchanged, rounded to 0.1 m |
| Listener | seated at the chair, ears at room point (0, EAR, 0), facing −Z, no head tracking |

**Room display mapping (visual only).** Distance is drawn on a log scale so 0.5 m and 10 m both fit the room:

```
rd(d) = ln(1 + d) / ln(11)            // 0.5 m → 0.169, 1.8 m → 0.429, 10 m → 1.0
rw    = rd(d) × R10                   // R10 = 4.4 room units (10 m reaches near the window)
pos   = ( rw·cos(el)·sin(az),  EAR + rw·sin(el),  −rw·cos(el)·cos(az) )   // EAR = 1.1
```

**Dragging back (inverse).** Intersect the touch ray with the horizontal plane at the sound's height (or the
floor for a tap), giving (x, z):

```
az = atan2(x, −z)                     // degrees, wrapped to −180…180
rw = hypot(x, z) / max(0.2, cos(el))  // elevation is kept while dragging
d  = clamp(exp(rw / R10 · ln 11) − 1, 0.5, 10), rounded to 0.1 m
```

**2.0 layout** (from `ArrayLayout.stereo2Speakers()`): L at −30°, R at +30°, elevation 0°, 1.8 m.
The room draws the speakers there; they are not draggable.

These functions move into `room-math.js` (pure, no WebGL) so they can be unit-tested in Node.

---

## 4. Bridge protocol (Dart ↔ page)

Transport: Dart → page through `runJavaScript("YinweiListen.apply(<json>)")`; page → Dart through
the `YinweiNative` channel (`postMessage(JSON.stringify(intent))`). JSON only, with a version field.

**State (Dart → page)**, sent on every controller change, at most 10 times per second:

```json
{ "v": 1,
  "laptop": "TIM-LAPTOP", "connection": "connected | reconnecting",
  "source": "汽水音乐", "live": true, "playing": true,
  "listening": "off | connecting | on", "control": "mine | other",
  "notice": "none | busy | interrupted | lost | taken | noapp",
  "mode": "point | stereo2", "motion": "fixed | orbit", "orbitHz": 0.4,
  "az": 35, "el": 20, "dist": 3.2,
  "track": { "title": "晴天", "artist": "周杰伦" },
  "volume": 0.72, "level": 0.0,
  "stats": { "received": 18240, "bufferMs": 160, "underruns": 0 } }
```

Each field maps to existing controller data:
- `notice` comes from controller status and `failureText` codes; `noapp` (no music app open on the
  laptop) is the v10 state; the two sign-in states (wrong password, laptop offline) are shown by the
  native Flutter sign-in, not the page;
- `level` is a new, cheap peak meter, computed in Dart from every 4th packet;
- `stats` come from the native player status poll.

**Intents (page → Dart)**, each validated in Dart before acting:

| Intent | Controller call |
|---|---|
| `{"t":"listen","startLive":bool}` | `startListening(startLive:)` |
| `{"t":"stopListening"}` | `stopListening()` |
| `{"t":"take"}` | `takeControl()` |
| `{"t":"media","a":"prev\|play\|pause\|next"}` | `command("media.*")` (falls back to `play`/`pause` without the music-app link) |
| `{"t":"liveStop"}` | `command("live.stop")` |
| `{"t":"layout","mode":"point\|stereo2"}` | `command("array.mode")` |
| `{"t":"motion","motion":"fixed\|orbit","orbitHz":n}` | `command("motion.set")` |
| `{"t":"place","az":n,"el":n,"dist":n}` | `command("point.set")`, **sent on release only** (as today) |
| `{"t":"volume","v":0..1}` | new `IosLaptopListenOutput.setVolume` (local, no laptop call) |
| `{"t":"signOut"}` | `signOut()` |
| `{"t":"ready"}` / `{"t":"error","msg":…}` | boot handshake / fallback |

Dart ignores intents that don't parse or are out of range. Numbers are clamped to the same ranges
as the coordinator (`remoteNumber`): azimuth ±180, elevation ±90, distance 0.5–10, orbit 0.05–2 Hz.

---

## 5. What the prototype shows vs what is real

Decisions already taken with you, and the ones still open:

| Prototype element | In the app | Status |
|---|---|---|
| Header "Yinwei \| Moonlight Room ▾" | room name, with a popover showing laptop / music app / Live status | done in prototype |
| Side panel: Layout, Motion, Place | real commands (`array.mode`, `motion.set`, `point.set`) | done |
| Player bar: transport | `media.*` commands | done |
| Volume slider | **new**: local gain on the iPad player (`AVAudioPlayerNode.volume`) | implemented locally (P3); iPad check pending |
| AirPlay button | **new**: `AVRoutePickerView` as a small native view over the bar | implemented locally (P3); iPad check pending |
| Cover art | generated "moon over water" tile per song; the laptop sends no artwork | **open:** keep, or add artwork to the laptop protocol later |
| Progress bar | replaced by a "Live" line and level meter; the laptop sends no position | **open:** add the music app's timeline to the snapshot later |
| Heart, centre speaker, room picker | left out (no such features) | agreed |
| Prototype panel, speed report, speed test, glass blur switch, on-page FPS meter | removed from the shipped page (a dev-only FPS overlay stays, P1.4) | — |

---

## 6. Phases

Each phase ends with a build, its tests, and a short report. Nothing is pushed or installed without your OK.

### P1 — Room page as an app asset (size: large)

**Status (2026-10-19): done, local only (nothing committed, pushed or installed).**
- `assets/listen_room/` holds `index.html`, `ui.css`, `room-math.js`, `bridge.js` (the bridge rules,
  pure and tested), `ui.js` (state in through `YinweiListen.apply`, intents out), `room.js`,
  `README.md`, `dev/dev-host.js` (a review stand-in for the app; not bundled), and:
  - `vendor/`: three.js r128 and its 10 add-ons, downloaded with your OK, checked (revision 128,
    MIT header, each add-on's class) and pinned by SHA-256 in `vendor/README.md`;
  - `fonts/`: Outfit (Latin, OFL, 32 KB) and a Material Symbols Rounded subset with only the 22 icons
    used (Apache 2.0, 5.6 KB), pinned in `fonts/README.md`.
- Sign-in and the prototype panel are gone from the page.
- Tests: `test/listen_room/` (room math, bridge rules, offline contract, vendor and font pins):
  21 of 21 pass.
- Offline proven: served from the asset folder, every request the page made (19) stayed on the local
  server, nothing reached the internet; both fonts loaded and the room rendered with no console errors.
- Review copy, fully self-contained: https://claude.ai/artifact/VNkYoY6oGDB5KDmSijbscd (built by
  `tools/listen_room_review.py`).
- Moved to P2: the developer FPS switch on the Flutter diagnostics page (the page side,
  `YinweiListen.devOverlay`, is ready); `pubspec.yaml` lists `assets/listen_room/`, `vendor/` and
  `fonts/` when Dart starts loading them.

1. Split `docs/design/listen-room-v10.2.html` into `assets/listen_room/` (the room-math block, marked
   ROOM MATH BEGIN / END, moves out unchanged with its tests):
   - `index.html` — markup only.
   - `ui.css`, `ui.js` — header, side panel, popovers, player bar. The prototype state machine
     becomes a `render(state)` function that is only fed by `YinweiListen.apply`.
   - `room.js` — the Three.js scene: `buildScene`, frame loop, input.
   - `room-math.js` — section 3 maths and the formatters (pure).
2. **Offline, no network.** The app must never fetch from the internet for this screen.
   - Vendor `three.min.js` r128 plus the 9 `examples/js` files the prototype loads into
     `assets/listen_room/vendor/` (MIT; add a README with versions and SHA-256, like the existing
     `spatial_workspace/vendor/README.txt`). Files:
     `shaders/CopyShader.js`, `shaders/LuminosityHighPassShader.js`, `shaders/GammaCorrectionShader.js`,
     `postprocessing/EffectComposer.js`, `postprocessing/RenderPass.js`, `postprocessing/ShaderPass.js`,
     `postprocessing/UnrealBloomPass.js`, `objects/Reflector.js`, `geometries/RoundedBoxGeometry.js`.
   - Bundle the fonts as `woff2`:
     - **Outfit** (OFL);
     - a **Material Symbols Rounded** subset with only the 23 icons used (Apache 2.0);
     - Chinese uses the system PingFang (no bundled CJK font).
   - Remove the Google Fonts links.
3. **Performance pass** (targets in section 8). The prototype already does all of this (v7–v10.2,
   plus the freeze, warm-up and drag fixes); P1 carries it over and measures it again in the app:
   - **Draw calls:** merge static geometry (window frames, rails, sill strip, ceiling, furniture)
     into a few meshes. Today's scene creates roughly 250 meshes; that is estimated from the
     scene code, so measure it with `renderer.info` first. Target: under 60 per pass.
   - **Shadows:** set `renderer.shadowMap.autoUpdate = false` and redraw shadows only when
     something that casts them moves.
   - **Reflection:** render the floor reflection at half resolution and every second frame when
     nothing moves.
   - **Glow:** run bloom at half resolution.
   - **Render on demand:** about 60 fps while touching or with Orbit on; 30 fps when listening and
     idle; 0 fps when hidden.
   - **Adaptive resolution:** drop the pixel ratio from 1.75 to 1.25 or 1.0 if frames take over 20 ms.
   - **Textures:** generate them in a Web Worker as typed arrays and upload with `DataTexture`, so the
     main thread never blocks. This replaces the canvas-based generator.
4. Dev-only FPS / frame-time overlay, switched on from the Flutter developer diagnostics page.

### P2 — Flutter host and bridge (size: medium)

**Status (2026-10-19): done, local only (nothing committed, pushed or installed; not yet run on an iPad).**
- `lib/remote/listen_room_html.dart`: inlines `assets/listen_room/` into one offline document.
- `lib/remote/listen_room_bridge.dart`: controller state → page state (≤ 10 a second, only on change);
  page intents → controller (validated, clamped; takes control on a tap unless the laptop took it).
- `lib/mobile/ios_listen_room_screen.dart`: WKWebView host (reuses `WKWebViewDriver`), suspend/resume,
  reload if the web process died, fallback to `IosLaptopListenScreen` on page error or no `ready` in 5 s.
- `lib/mobile/listen_room_sign_in.dart`: native sign-in in the v10.2 style.
- Entry: `openLaptopListen` opens the room. Diagnostics: "Listen Room FPS meter" switch.
- Additions to the approved page: a "Back to the player" item in the ••• menu (intent `close`; listening
  carries on) and the laptop shown as "your laptop" (the snapshot has no laptop name).
- Tests: 25 new Dart tests (bridge, inlining, screen); full app suite 658 passed, 6 skipped;
  `flutter analyze` 0 errors (the 6 warnings are in older files).
- At the P2 handoff, volume was held only in the bridge and the level line stayed flat. P3 below
  now connects volume, the native AirPlay picker and the level meter.

1. `lib/mobile/ios_listen_room_screen.dart`:
   - hosts `WKWebViewDriver`, building the HTML by inlining `assets/listen_room/*` the way
     `SpatialWorkspaceHtml` does today;
   - turns on `isInspectable` in debug builds;
   - uses a transparent background and turns off scrolling and zoom.
2. `lib/remote/listen_room_bridge.dart`:
   - turns controller state into the state JSON (throttled);
   - parses, validates and routes intents (section 4);
   - is unit-testable with a fake controller.
3. **Lifecycle:**
   - send `suspend` when the app goes to the background or leaves the screen, and `resume` on return;
   - if WKWebView's web process is killed (iOS does this in the background), reload the page and
     re-send state; no state is lost because Dart owns it.
4. **Fallback:** if the page reports `error` (no WebGL, script failure) or isn't `ready` within 5 s,
   show the current `IosLaptopListenScreen`. Listening continues either way.
5. **Sign-in:** a restyled Flutter sign-in (navy glass, same fields and messages as today) before
   the room appears.
6. **Entry point:** the "Listen to laptop" button in the iPad player opens the new screen.

### P3 — Native additions (size: small)

**Status (2026-10-19): implemented and tested locally; native iOS build and iPad checks pending.**
Committed locally together with P4 (see below); no push, workflow run or install. P5 and the Windows/Mac
stages have not started.

- **Volume:** `IosLaptopListenOutput.setVolume` calls `setRemoteReturnVolume` on the existing
  ReplayKit probe channel. The output retains the local gain across room reopen and listening
  restart, and applies it before audio packets are accepted. Swift clamps finite values to 0–1,
  applies them only in listen mode, preserves them through listen-mode resets, and explicitly
  restores unity gain when preparing capture mode. The shared `LaptopListenOutput` interface is unchanged.
- **AirPlay:** `IosListenRoomScreen` positions a real `UiKitView` over the validated page rectangle.
  `AVRoutePickerView` and its factory live in the existing `YinweiReplayKitProbe.swift`, registered
  in `AppDelegate.swift`; no Xcode project edits. The page keeps the button's layout/background
  but hides its duplicate icon and accessibility label in the native host. Invalid, missing or
  out-of-screen bounds hide the overlay; reload, sign-out, stop and fallback remove it. The user
  taps the native picker directly; there is no programmatic picker action.
- **Level:** the iOS Dart output reads every fourth accepted YNW1 packet (56-byte header,
  little-endian stereo Float32, at most 512 frames). It reports the clamped absolute peak of both
  channels with fast attack and smoothed release; a short timer decays it to zero if packets stop.
  This is the incoming processed stereo level **before local volume**, not a hardware-output meter.
  Packets are forwarded unchanged. New streams/stops reset the meter and ignore stale write
  replies. The bridge listens for changes and keeps its existing maximum of 10 state sends/second.
- **Verification:** Node 21/21; the three Listen Room Dart files 32/32; full Flutter suite
  670 passed, 6 skipped (including the output tests and existing N0/I1 contracts). Scoped Dart
  analysis of the changed Dart files: no issues. Tests used installed tools with `--no-pub`;
  nothing was installed. Local logs are in `.tmp/listen-room-p3-*.log` at the repository root.
- **Protected:** no Rust/HRTF/DSP, laptop gateway/protocol, Live Transfer or capture-session edits;
  no workflow/IPA-verifier edits. `spatial_core.dll` remains byte-identical to this task's starting
  working copy (SHA-256 `0d150deff17c3599c92244775b56c119a120604afed1297e150e2f0a2236305f`),
  with its pre-existing modification left alone.
- **Still needs the iPad:** actual volume/mute and retention after restart/route change/interruption;
  direct AirPlay presentation, device selection and uninterrupted playback; picker alignment in
  portrait/landscape/Stage Manager and VoiceOver without duplicate buttons; meter motion with music
  and return to zero on silence/disconnect; unchanged spatial/HRTF, capture, background and
  lock-screen behaviour. Native Swift compilation, device screenshots, runtime/console checks and
  the section 7 performance checks are pending; this Windows checkout cannot verify iOS execution.
- **Rollback:** restore only the P3 edits listed above (including `assets/listen_room/ui.js`) and
  their tests. P1/P2 and the classic fallback remain intact. Local pre-P3 copies are saved under
  `.tmp/listen-room-p3-before/`; do not reset the working tree or restore the DLL.

1. **Volume:** add a `setRemoteReturnVolume` method on `dev.yinwei/replaykit_audio_probe`, setting
   `player.volume`. It applies in listen mode only; the capture route ignores it.
2. **AirPlay:** add a `UiKitView` platform view wrapping `AVRoutePickerView`, which the user taps
   directly. The N0 contract test forbids triggering the picker from code (`sendActions(for:)`), so
   the button must be the real picker.
3. **Level meter:** compute it in Dart (peak of a sampled packet, smoothed) and pass it to the page as
   `level`.
4. Swift changes go only in files already in the Xcode project (no `project.pbxproj` edits), as
   before.

### P4 — Tests and acceptance (size: medium)

See section 7. Build the unsigned IPA through `ios-unsigned-ipa.yml` and check its contents.

**Status (2026-10-19): build checks added and committed locally; not pushed, no workflow run.**
- `ios-unsigned-ipa.yml` installs Node 22 and runs the three Node tests (`room_math`, `bridge`,
  `offline_contract`) before the Swift tests, so a broken page stops the build early. Their counts go into
  `Yinwei-build-info.txt`. The Dart Listen Room tests already run in the workflow's `flutter test`.
- `verify_unsigned_ipa.py` opens `Runner.app/Frameworks/App.framework/flutter_assets/assets/listen_room/` and
  checks that `index.html` and `ui.css` are there, and that every file they reference is present and not
  empty (19 today: the stylesheet, 15 scripts, 2 fonts, the still image). It also checks that the review
  stand-in `dev/` is not bundled. The report gains a `listen_room` entry with the file count and the
  three.js SHA-256.
- Checked locally on fake IPAs: a complete room passes; a missing add-on, font or still image, a bundled
  `dev/` or no room at all each fail with a clear message.
- **Next, with your OK:** push and start the workflow (route in 11.1), then re-sign, install and run the
  iPad checks in section 7.

### P5 — Rollout

- The new screen sits behind a flag (`listenRoomV6`, default **on**). The ••• menu has a
  "Classic view" entry for one release.
- Rollback: turn the flag off, or revert the P1–P3 commits. The assets live in their own folder and
  the old screen stays in the code.

---

## 7. Tests

**Automated (run on Windows and in CI):**
- **Dart unit tests:**
  - bridge encode/decode, clamping, throttling, unknown intents ignored;
  - intent → controller calls, using the existing gateway test fixture;
  - lifecycle: suspend on background, reload after web-process loss, fallback after timeout or error.
- **Node tests** (no WebGL; same style as `test/remote/audio_browser_test.mjs`):
  - `room-math.js` round trips (az/el/dist → position → az/el/dist within 1° / 0.1 m);
  - the 2.0 speaker positions;
  - the formatters;
  - the UI `render(state)` for every state in section 4.
- **Contract tests:**
  - no `http://` or `https://` URLs in `assets/listen_room/**`;
  - vendor files match their SHA-256 in the README;
  - the N0 and I1 iOS contract tests still pass.
- **Visual check:** headless Edge with SwiftShader at 1180×820 and 820×1180. Compare against the
  reference PNGs saved with the design, by eye; no pixel diff gate.

**On your iPad (manual, with the FPS overlay on):**

| Check | Pass when |
|---|---|
| Frame rate, room idle while listening | ≥ 30 fps steady |
| Frame rate, dragging the sound / Orbit on | ≥ 50 fps |
| Heat and battery | In the real app, playing real music from the laptop: 30 min on the room screen without the iPad getting hot, and no audio dropouts. Write down the battery drop and whether frames slowed over time. This is the only heat check; the web prototype doesn't test heat, because it has no real audio |
| Memory | No WebView reloads during 30 min |
| Background | Leave the app and lock the iPad: sound continues, lock-screen buttons work, the room resumes on return |
| Controls | Every intent in section 4 changes the laptop. The laptop's own edits take control away (laptop wins) |
| States | Sign-in, Live off, laptop took control, Safari listening, phone call and lost connection all show as in the prototype |
| Layout | Landscape, portrait and Stage Manager window sizes; nothing clipped |

---

## 8. Performance targets

| Measure | Target (iPad, A14 or newer) |
|---|---|
| First room frame after the screen opens | < 1.0 s (textures sharpen within 2 s afterwards) |
| Interactive frame time | ≤ 20 ms (≥ 50 fps) |
| Idle while listening | 30 fps cap |
| Hidden or background | 0 fps (no rendering) |
| Draw calls | ≤ 60 per pass (main view and floor reflection) |
| WebGL memory | < 200 MB |

If an older iPad misses these, adaptive resolution steps down first. Then a "lighter room" mode
turns off the reflection and the glow; it is chosen automatically and can be overridden in settings.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| Heat and battery from continuous WebGL | Render on demand, 30 fps idle cap, nothing renders when hidden or in the background |
| WKWebView web process killed in the background | Dart owns state; reload and re-send on return |
| Two Three.js versions in the app (r128 here, r160 in the workspace) | Isolated asset folders, about 700 KB extra; follow-up to move this room to r160 |
| Different look on device (iOS GPU vs SwiftShader screenshots) | Check on your iPad in P4 before rollout |
| WebView controls less accessible | Labels and roles already in the markup; VoiceOver check in P4 |
| Password exposure | Sign-in stays native Flutter; the page never sees credentials |
| Product items not real yet (artwork, progress) | Shown honestly (generated cover, "Live" line) until the laptop protocol adds them |

**Protected and unchanged:** `spatial_core` (Rust), HRTF/DSP, the laptop's Live Transfer and gateway,
the capture route, and the native player's capture-mode behaviour. Laptop bundles stay pinned by
SHA-256 as today.

---

## 10. Order of work and approvals

Your order (2026-10-19): **iPad and mobile first, then Windows, Mac last.** Each stage ends with a
build you install and test. The next stage starts only with your OK, and nothing is pushed,
installed or switched on the laptop without it.

**Stage 1: iPad and mobile**
1. P1: the approved page becomes an offline app asset. You see it as an updated prototype.
2. P2 + P3: the iPad host, bridge and native additions → **iPad IPA** (section 11.1) → your iPad test (P4).
3. Phones, depending on your answer in 10.1:
   - **iPhone:** the same iOS app and IPA. The page already has a phone layout (checked at phone width).
   - **Android phones:** Android has no listen mode yet. It needs its own listening player and the
     same page in Android's WebView → APK through the existing Android workflow.
4. P5 rollout on the iPad. The classic screen stays one release for rollback.

Stage 1 changes nothing on the Windows laptop. The iPad app talks to the laptop exactly as today.

**Stage 2: Windows, UI only.** Safety rules in section 11.3.

**Stage 3: Mac.** Section 11.2.

### 10.1 Open decisions

| # | Question | Needed before |
|---|---|---|
| 1 | Section 5: keep the generated cover and the "Live" line? **Answered: keep**, as in the v10.2 prototype you approved | — |
| 2 | "Mobile devices": iPhone only, or Android phones too? **Answered: skip phones for now, iPad only** (2026-10-19). Stage 1, step 3 is postponed | — |
| 3 | Windows: what exactly changes in the Windows UI? (The Windows app *is* the laptop, so "Listen to laptop" doesn't apply there.) | Stage 2 |
| 4 | Mac scope (section 11.5): assumed **A** (Listen Room on the Mac), since you put the Mac in the build order | Stage 3 |

---

## 11. The builds you install: iPad IPA, Windows bundle and Mac DMG

Both are built by GitHub Actions on Apple's build machines, so no Mac is needed on this side. A build
runs only after you OK the push. You install both yourself; nothing is installed or published for you.

### 11.1 iPad: unsigned IPA

**Workflow (exists):** `.github/workflows/ios-unsigned-ipa.yml`. It runs on a push to the branch
`yinwei-ui-redesign`, or by hand. The route used for the 373c8ab build and the ones before it: push
`codex/ios-capture-ci` to the `yinwei-ui-redesign` remote (github.com/M2-King/Yinwei-UI-Redesign), then
start the workflow by hand on that branch. In order, it:
1. runs the Listen Room Node tests, the Swift capture tests, all Flutter tests and the Rust audio tests;
2. builds the native audio library;
3. runs `flutter build ios --release --no-codesign`;
4. checks the binaries and the native audio linkage;
5. packages `Yinwei-unsigned.ipa`, with `Yinwei-build-info.txt` and a verification report.

**Added by this plan (done in P4):**
- the Listen Room tests from section 7 also run in this workflow:
  - Node tests for `room-math.js` and the page's `render(state)`;
  - the offline check: no `http(s)://` URLs in `assets/listen_room/**`;
  - the vendor SHA-256 check;
- the IPA verification also checks that `assets/listen_room/` (page, vendor files, fonts) is inside the app.

**Install:**
1. Download the artifact from the run.
2. Re-sign it with your usual Apple provisioning route, as you did for N0.1 and the 373c8ab build.
3. Install it on the iPad.

The existing verification already checks that the app and its ReplayKit extension survive re-signing.

**Pass:** the iPad checks in section 7.

### 11.2 Mac: DMG

**Today (exists):** `.github/workflows/macos-test-build.yml` with `tools/package_macos.sh` builds the Mac
app. Details:
- one app for Apple Silicon and Intel, macOS 12 or newer;
- it contains the Rust audio engine and the laptop-style 3D workspace;
- it is ad-hoc signed and **not notarized**;
- it comes as a DMG and a ZIP, with `START-HERE.md`, `BUILD-INFO.txt` and `SHA256SUMS`
  (see [MACOS_FRIEND_TEST.md](MACOS_FRIEND_TEST.md)).

It has **no Listen to laptop mode**: the listening audio player exists only on iPad
(`IosLaptopListenOutput` and its iOS Swift player).

**To put the Listen Room on the Mac (scope A, section 11.5):**
- **M1. Mac listening player (size: medium).**
  - Add `MacLaptopListenOutput` in Dart, and a Swift player in `macos/Runner` that does what the iPad's
    listen-mode player does: receive the laptop's stream, buffer it, play it through AVAudioEngine,
    with volume.
  - `LaptopListenController` already takes its output as a parameter, so the controller, the gateway
    protocol and the laptop stay unchanged.
  - Now Playing: the Mac has no lock screen, so the song shows in Control Center and works with the
    media keys (`MPNowPlayingInfoCenter`), through the same `dev.yinwei/now_playing` channel.
- **M2. Mac room host (size: small).**
  - Show the same `assets/listen_room/` page in the Mac app's existing WKWebView host
    (`lib/platform/macos_webview_host.dart`, already used by the 3D workspace).
  - The page already supports mouse and trackpad (drag, wheel zoom, double-click reset), the keyboard
    (Escape, focus) and resizable windows.
  - Add Mac window sizes to the layout check: 1024×640 and 1440×900, as in the Mac friend test.
- **M3. Entry and sign-in (size: small).**
  - A "Listen to laptop" entry in the Mac app.
  - The same native Flutter sign-in as on iPad; the password never enters the page.
- **M4. Build.**
  - `macos-test-build.yml` also runs the Listen Room tests.
  - It packages the DMG as today.

**Install:**
1. Download the artifact and check it with `shasum -a 256 -c SHA256SUMS`.
2. Open the DMG and drag **Yinwei.app** into Applications.
3. Open it the first time through System Settings → Privacy & Security → **Open Anyway**. It is
   ad-hoc signed, not notarized; don't turn Gatekeeper off.

**Pass (on your Mac):**
- 30 minutes of listening to the laptop without dropouts.
- Sleep and wake.
- Minimizing the window stops the rendering.
- Control Center shows the song.
- The room and every state look as approved.
- The checks in [MACOS_FRIEND_TEST.md](MACOS_FRIEND_TEST.md) still pass for the rest of the app.

### 11.3 Windows: UI only, safe alongside iPad testing

The Windows laptop runs the verified player bundle: player EXE, `spatial_core.dll` and the `data`
folder, kept together and checked by hash by the launcher (`tools/remote/README.md`). Your iPad and
phones connect to **that running player** through its remote gateway and connector. Windows work must
never interrupt it.

**Rules:**
1. **The engine stays unchanged.**
   - `spatial_core.dll` in the new bundle must be byte-identical to the running one: same SHA-256,
     checked before any switch.
   - No change to `spatial_core`, HRTF/DSP, Live Transfer, the output tap, the remote gateway protocol
     or the connector. Only Flutter UI code and assets change.
   - If a UI need ever seems to require an engine change: stop and ask. It becomes its own approved
     change, with its own engine handover and rollback, never part of a UI build.
2. **Build side by side, never over the running bundle.**
   - The new UI is built into its own new bundle folder (the next "w" number).
   - The running bundle (w13 today) and its private configuration are not touched.
3. **No second player while you test the iPad.** A second Yinwei player on the laptop could take over
   the gateway's attachment record, the audio device or Live Transfer. So:
   - Windows UI checks use automated tests and headless screenshots; they never launch a player.
   - If the new UI must be seen running on the laptop, it starts only when you say no iPad test is
     running. It starts with remote access off (no `YINWEI_REMOTE_*` settings), without starting
     Live Transfer, and is closed afterwards.
   - The launcher's own guards stay on: it refuses to start while a Yinwei player is active, and it
     never kills one.
4. **Switching the laptop to the new UI is a matched package switch, with your OK, at a time you
   choose.**
   - Never during an iPad or phone test; you are asked before playback stops.
   - First save the current configuration as `deployment.w13-before-w14.json`, as was done for
     w12 → w13.
   - After the switch, check iPad listening again: sign in, controls, sound.
   - Rollback: switch back to the w13 bundle with the saved configuration.
5. **The gateway protocol doesn't change,** so the iPad app works with both the old and the new
   Windows UI. Stage 1 and Stage 2 never depend on each other's timing.

**Build:** a Windows Release build plus the existing Flutter and Rust tests, with a hash comparison of
`spatial_core.dll` against the running bundle in the build report. No installer, Windows startup
entry or update channel changes unless you ask for them.

### 11.4 Not included

- **Developer ID signing and notarization for the Mac, and App Store or TestFlight for either build.**
  These need an Apple Developer account and your decision on public release, as the Mac checkpoint
  already notes.
- **Any change to the laptop, its gateway, Live Transfer or the audio engine.**

### 11.5 Open decision: Mac scope

| Option | The Mac DMG contains | Work |
|---|---|---|
| **A** (what this plan assumes from your request) | the Listen Room on the Mac: listen to the Windows laptop with the same room and controls as the iPad | M1–M4 above |
| **B** | only today's Mac player, rebuilt; no Listen Room on the Mac | M4 only |
