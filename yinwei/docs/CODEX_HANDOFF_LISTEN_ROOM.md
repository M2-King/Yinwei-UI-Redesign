# Codex handoff: iPad Listen Room (Stage 1, after P2)

Written 2026-10-19 by Claude, to continue the work in Codex.

## Read first

1. `AGENTS.md` (repository root): roles and engineering rules.
2. `yinwei/docs/IMPLEMENTATION_IPAD_LISTEN_ROOM.md`: **the plan to follow strictly**. Sections 2–4
   (architecture, coordinates, bridge protocol), 6 (phases, with P1 and P2 status), 7 (tests),
   10 (order and approvals) and 11 (the builds to install).
3. `yinwei/apps/yinwei_player/assets/listen_room/README.md`: the page, its bridge and its rules.
4. Background only: `yinwei/docs/IMPLEMENTATION_LISTEN_ROOM_PROTOTYPE.md` (how the approved
   prototype was made and signed off) and the approved page `yinwei/docs/design/listen-room-v10.2.html`.

## The owner's standing rules (do not break)

1. **Order:** Stage 1 iPad only (phones skipped), then Stage 2 Windows (UI only), then Stage 3 Mac.
   Each stage starts only with the owner's OK.
2. **Ask before** any push, any workflow run, any install, and any change on the laptop. Pushing to
   `yinwei-ui-redesign` triggers the IPA build, so it needs the owner's OK every time.
3. **Protected:** `spatial_core` (Rust), HRTF/DSP, Live Transfer, the laptop gateway and its protocol,
   the capture route. The page is a view; the Dart session stays the only source of truth.
4. **Do not stage or commit** `yinwei/apps/yinwei_player/windows/runner/spatial_core.dll`. It was
   already modified in the working tree before this work. Also leave the other unrelated changes on
   this branch (`website/…`, `outputs/`, `.tmp/` and so on) out of any commit.
5. If product direction is unclear, stop and ask the owner; do not invent it.

## Where things stand

Branch: `codex/ios-capture-ci`. **P1 and P2 are done locally; nothing is committed, pushed or
installed, and nothing has run on an iPad yet.**

New files:
- `apps/yinwei_player/assets/listen_room/`: `index.html`, `ui.css`, `room-math.js`, `bridge.js`,
  `ui.js`, `room.js`, `room-still.jpg`, `README.md`; `vendor/` (three.js r128 and 10 add-ons, pinned);
  `fonts/` (Outfit and a 23-icon Material Symbols subset, pinned); `dev/dev-host.js` (review only,
  never bundled).
- `apps/yinwei_player/lib/remote/listen_room_html.dart`, `lib/remote/listen_room_bridge.dart`,
  `lib/mobile/ios_listen_room_screen.dart`, `lib/mobile/listen_room_sign_in.dart`.
- Tests: `apps/yinwei_player/test/listen_room/*.mjs`, `test/remote/listen_room_bridge_test.dart`,
  `test/remote/listen_room_html_test.dart`, `test/mobile/ios_listen_room_screen_test.dart`.
- `yinwei/tools/listen_room_review.py` (single-file review copy) and
  `yinwei/docs/design/listen-room-v10.2.html` (approved reference).

Changed files:
- `apps/yinwei_player/pubspec.yaml`: the `assets/listen_room/…` folders (not `dev/`).
- `lib/mobile/ios_laptop_listen_screen.dart`: `openLaptopListen` now opens the room. The classic screen
  is unchanged and is the room's fallback.
- `lib/mobile/developer_diagnostics_page.dart`: "Listen Room FPS meter" switch.
- Docs: the two plan files above.

## How to check it

From `yinwei/apps/yinwei_player`:

```bash
node --test test/listen_room/room_math_test.mjs test/listen_room/bridge_test.mjs test/listen_room/offline_contract_test.mjs
```

```bash
flutter test test/remote/listen_room_bridge_test.dart test/remote/listen_room_html_test.dart test/mobile/ios_listen_room_screen_test.dart
```

Results on 2026-10-19: Node 21/21; the three Dart files 25/25; the full `flutter test` 658 passed,
6 skipped; `flutter analyze` 0 errors (its 6 warnings are in older files).

To look at the page in a browser: serve `assets/listen_room/` with any static server and open
`index.html?dev` (the stand-in plays the app's side and logs every intent), or run
`python yinwei/tools/listen_room_review.py OUT.html` from the repository root.

## Next: P3 — native additions (plan §6, P3)

1. **Volume.** The page sends `volume {v}`; `ListenRoomBridge.volume` holds it. Add a
   `setRemoteReturnVolume` method on the `dev.yinwei/replaykit_audio_probe` channel
   (`ios/Runner/YinweiReplayKitProbe.swift`) that sets the listen-mode player's volume, and call it
   from the bridge (for example through `IosLaptopListenOutput`, reached as `session.output`). The
   capture route ignores it. Prefer not to change the `LaptopListenOutput` interface; if it must change,
   update `FakeListenOutput` in `test/remote/laptop_listen_controller_test.dart`.
2. **AirPlay.** The page reports its AirPlay button with `rects {airplay: [x, y, w, h]}` (page points,
   equal to Flutter logical pixels because the WebView fills the screen); the bridge keeps it in
   `airplayRect`. Put a `UiKitView` wrapping `AVRoutePickerView` exactly there, above the WebView, in
   `IosListenRoomScreen`. The N0 contract test forbids opening the picker from code
   (`sendActions(for:)`), so it must be the real view the user taps.
3. **Level meter.** The page draws `state.level` (0–1); the bridge sends `ListenRoomBridge.level`,
   which is 0 today. Compute a smoothed peak from about every 4th audio packet (plan §6 P3.3) and set
   it, then let the bridge send it (it already throttles to 10 a second).
4. **Swift rule:** only edit Swift files that are already in the Xcode project; no `project.pbxproj`
   edits (as in earlier iOS work).
5. Add Dart tests for each, run the full suite, update the P3 status in the plan.

## Then: P4 and P5 (need the owner's OK to push)

- **P4:** extend `.github/workflows/ios-unsigned-ipa.yml` to also run the three Node tests, and make the
  IPA verification (`yinwei/tools/verify_unsigned_ipa.py`) check that `assets/listen_room/`
  (page, vendor, fonts) is inside the app. **Ask the owner before pushing** to
  `yinwei-ui-redesign`. The owner re-signs the unsigned IPA with their usual route and installs it.
- **P5:** a `listenRoomV6` flag (default on) and a "Classic view" entry for one release (plan §6 P5).

## Things only the iPad can tell (check with the owner)

- **Texture worker:** the page builds textures in a Web Worker from a Blob URL. Inside `loadHtmlString`
  (opaque origin) WebKit may refuse it; the page then builds them on the main thread (slower start, no
  error). If the speed report says "main thread", consider `loadHtmlString` with a `baseUrl`, allowed in
  `WKWebViewDriver`'s navigation delegate.
- **Ready in time:** the page sends `ready` after its first frame; the screen falls back to the classic
  screen after 5 s.
- **Background:** after a long time in the background iPadOS may end the web process; on return the
  screen reloads the page and re-sends the state (tested with a fake WebView only).
- **Safe areas and Stage Manager** sizes, the native sign-in look, VoiceOver.
- The developer FPS meter (Diagnostics → "Listen Room FPS meter") and `YinweiListen.speedReport()`
  give comparable numbers to the prototype's reports.

## Small things decided during P2 (tell the owner if questioned)

- The laptop snapshot has no laptop name, and the protocol stays unchanged, so the page says
  "your laptop". In Live mode the snapshot has no artist, so the music app's name takes that line.
- A "Back to the player" item was added to the room's ••• menu (intent `close`; listening carries on),
  because the full-screen room had no way back. Its arrow icon was added to the icon subset (re-pinned).
- The native sign-in uses the system font (Flutter can't use the page's woff2 fonts).
