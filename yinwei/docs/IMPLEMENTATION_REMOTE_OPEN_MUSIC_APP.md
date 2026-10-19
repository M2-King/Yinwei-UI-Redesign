# Remote start: the laptop opens your music app — implementation plan

Status (2026-10-19): **chosen by you (option B); built and tested locally, nothing live.** The laptop
build (w14) and the IPA wait for your OK. Nothing has been switched, pushed or installed.

Results: `flutter test` 684 passed, 6 skipped; Node page tests 22/22; web page tests pass;
`flutter analyze` unchanged (117, no new issues). The room's new state was rendered and checked in a
browser (Opens 汽水音乐 on the laptop), and the no-music-app state is unchanged.

**w14** (`outputs/w14/windows`, built next to w13, which keeps running): `yinwei_player.exe` and
`spatial_core.dll` are byte-identical to w13 (`a2de3030…`, `eb764148…`). The build's own DLL
(`0d150def…`, from `windows/runner`) was replaced. Changed: `data/app.so` (`964c76f9…`), the web page's
`app.js`, the asset list, the icon font, plus the new Listen Room files. Full list and hashes:
`outputs/w14/w14-report.json`, `windows-manifest.json`.

## 1. What you get

On the iPad (Moonlight Room) and the laptop's web page, **Start on laptop** now also works when no
music app is open on the laptop:

1. The laptop opens the music app it last saw playing (for example 汽水音乐).
2. It waits up to 20 s for Windows to report that app with a song.
3. From here the existing steps run unchanged: press play if paused, wait until it plays, start Live
   Transfer, and the iPad (or browser) listens.

The room shows the button as **Start on laptop and listen**, with "Opens 汽水音乐 on your laptop" under
it. Until the laptop has seen a music app play once, the room keeps today's "No music app is open"
note, and the button stays off.

## 2. Which app opens

- **The laptop decides, never the iPad.** When Windows media controls report a song from an
  allow-listed music player (the same list Live Transfer already uses: SodaMusic/汽水, cloudmusic/
  NetEase, Spotify, QQMusic, Kugou, Kuwo, lyrica), the laptop reads that process's `.exe` path from its
  own process table and remembers it in `remote_music_app.json` (app support folder). It survives a
  restart.
- Browsers, Yinwei itself, PowerShell and terminals are never remembered. Store apps under
  `WindowsApps` are skipped (Windows doesn't let them be started by path).
- The remote request carries no path, name or arguments: `live.start` is the same command as today.
- The app starts with no arguments, in its own folder, without Yinwei's `YINWEI_*` settings in its
  environment.
- Only the signed-in owner can send `live.start`. Guests have their own route without commands.
- **Off switch:** `YINWEI_REMOTE_OPEN_MUSIC_APP=0` in the player's environment turns it off; the
  laptop then behaves exactly as w13.

## 3. Protected systems

Unchanged: `spatial_core` (Rust), HRTF/DSP, Live Transfer (`_startLiveHrtf` and everything after it),
the capture route, the SMTC daemon script, the output tap and the gateway's commands. The new step
runs before the existing remote-start code, only when Windows reports no song.

The w14 bundle's `spatial_core.dll` is w13's file, byte-identical
(SHA-256 `eb764148534b6f0df3d0de60c7b6f184fcbf5164ed7298d53a3de95bb6e8c036`). The Windows build
copies `windows/runner/spatial_core.dll` (a different, pre-modified file), so the bundle's copy is
replaced with w13's after the build and checked.

## 4. Protocol: one additive field

The laptop's snapshot gains `live.openApp` (the app's name, or `""`). Old iPad apps and old pages ignore
it. A new iPad app on the old laptop sees no field and keeps today's behaviour. New failure codes for
`live.start`: `music_app_open_failed`, `music_app_no_song`. They keep control, like `no_music_app`.

## 5. Files

Laptop:
- `lib/remote/remote_music_app.dart` (new): remembers the app, opens it, waits for a song.
- `lib/screens/player_screen.dart`: creates it, feeds it Windows media changes, calls it in
  `_startLiveFromRemote` when there is no song, reports `openApp`.
- `lib/state/app_session_coordinator.dart`: passes `live.openApp` through.
- `assets/remote/app.js`: the web page's hint names the app; failure texts.

iPad:
- `lib/remote/laptop_listen_controller.dart`: failure texts; new codes keep control.
- `lib/remote/listen_room_bridge.dart`: page field `opens`; "no music app" only while the laptop
  reports none (fixes a stuck note after a failed start).
- `assets/listen_room/bridge.js`, `ui.js`: the `opens` field and its wording.

## 6. Tests

- Dart: remembering (allow list, browsers and Store apps refused, saved and reloaded, a missing
  `.exe` forgotten), opening (no app, launch failure, no song in time, song in time), environment
  without `YINWEI_*`; bridge `opens` and the noapp fix; coordinator passes `openApp`.
- Node: `opens` is a cleaned page field.
- Full `flutter test`, the Node tests, `flutter analyze`.

## 7. Builds and going live (each step needs your OK)

1. **w14 laptop bundle**, built next to w13 (`outputs/w14/windows`), w13's engine DLL, a hash report.
   No player is started while you test the iPad.
2. **Switch the laptop to w14** at a time you choose: save `deployment.w13-before-w14.json`, point the
   deployment at w14, start it with the launcher. Rollback: put the saved file back and start w13.
3. **IPA** with the room's new wording (push and workflow run with your OK).
4. **Check on the laptop + iPad:** close the music app, tap Start on laptop on the iPad: the app opens,
   plays, Live Transfer starts, the iPad plays it. Also from the web page.

## 8. Only the laptop can tell

- Whether your music app, when opened, comes back with its last song (Windows then reports it, and the
  laptop presses play). If it opens with no song, the iPad says so; choose a song on the laptop once.
- How long the app takes to start; the wait is 20 s.
