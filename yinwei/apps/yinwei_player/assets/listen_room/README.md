# Listen Room page (iPad "Listen to laptop" screen)

The approved Moonlight Room prototype (v10.2, `docs/design/listen-room-v10.2.html`) as an
offline page for the app's WebView. Plan: `docs/IMPLEMENTATION_IPAD_LISTEN_ROOM.md` (P1).

| File | What it holds |
|---|---|
| `index.html` | Markup only. The app inlines every file below into one document, like `SpatialWorkspaceHtml`. |
| `ui.css` | All styles, the bundled fonts (`fonts/`) and the still picture shown when 3D can't run. |
| `room-math.js` | Pure room maths: engine ↔ room coordinates, the drag inverse, slider mapping, snapping, text. |
| `bridge.js` | Pure bridge rules: which state fields the page accepts, their ranges, and how a value you just set is kept until the app confirms it. |
| `ui.js` | Header, side panel, popovers, player bar, menu, toasts; `window.YinweiListen`. |
| `sound.js` | The opening's sound effects, synthesized with Web Audio (no audio files); silent while this iPad is already listening. |
| `room.js` | The 3D room (three.js r128), the 3D opening, frame loop, touch input, developer speed meter, GPU-loss recovery. |
| `vendor/` | three.js r128 and its 10 add-ons, pinned by SHA-256 in `vendor/README.md`. |
| `fonts/` | Outfit (OFL) and a Material Symbols Rounded subset (Apache 2.0). Chinese uses the system font. |
| `dev/` | Review only, **never bundled**: `dev-host.js` stands in for the app in a browser. |

## The bridge

The page is a view. The app (Dart) owns all state.

- **App → page:** `YinweiListen.apply(state)` with the version-1 fields in `bridge.js` (`FIELDS`),
  at most 10 times a second. Also `toast(text)`, `suspend()` / `resume()`, `setQuality("auto" | "full" | "light")`,
  and, for developer diagnostics only, `devOverlay(on)`, `speedReport()` and `speedTest()`.
- **Page → app:** JSON intents through the `YinweiNative` JavaScript channel:
  `ready`, `error`, `listen {startLive}`, `stopListening`, `take`, `media {a}`, `liveStop`,
  `layout {mode}`, `motion {motion, orbitHz}`, `place {az, el, dist}` (on release only),
  `volume {v}`, `signOut`, `close` (back to the player; listening carries on), `rects {airplay}` (where the AirPlay button is, so the app can put the
  real picker over it), and `airplay` (browser only).
- Sign-in is native in the app. The password never enters this page.

## Rules

- **Offline:** no web address (http or https) anywhere in the shipped files. Checked by
  `test/listen_room/offline_contract_test.mjs`, together with the vendor SHA-256 pins.
- `dev/` stays out of `pubspec.yaml`. The page loads `dev/dev-host.js` only when opened with `?dev`.
- Coordinates are documented in `room-math.js` and must match the plan's section 3.

## Tests and review

- Tests: `node --test test/listen_room/room_math_test.mjs test/listen_room/bridge_test.mjs test/listen_room/offline_contract_test.mjs`
  (run from `apps/yinwei_player`).
- Review copy (one file, with the stand-in): `python tools/listen_room_review.py OUT.html` (run from `yinwei`).
- In a browser: serve this folder and open `index.html?dev`.
