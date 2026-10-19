# Remote start: the laptop opens your music app — implementation plan

Status (2026-10-19): **live on the laptop (w14); IPA built; iPad test pending.** With your OK:
commit `e9b388d` pushed and built (IPA SHA-256 `71d5c81e…6589ec`, all workflow steps passed); the laptop
was switched from w13 to w14 (w13 closed normally, saved as `deployment.w13-before-w14.json`, started
by the launcher, backend online). Rollback: restore that file, close w14, run the launcher.

**Seen on the laptop after the switch:** 汽水音乐 was open but Windows listed no media session at all.
Electron apps like 汽水 may only report to Windows once a song plays. If so, opening it is not enough
and the iPad says "no song ready"; the fix would be a w15 that presses the keyboard Play key after
opening it (not built; your test decides).

Results: `flutter test` 684 passed, 6 skipped; Node page tests 22/22; web page tests pass;
`flutter analyze` unchanged (117, no new issues). The room's new state was rendered and checked in a
browser (Opens 汽水音乐 on the laptop), and the no-music-app state is unchanged.

**w14** (`outputs/w14/windows`, built next to w13, which keeps running): `yinwei_player.exe` and
`spatial_core.dll` are byte-identical to w13 (`a2de3030…`, `eb764148…`). The build's own DLL
(`0d150def…`, from `windows/runner`) was replaced. Changed: `data/app.so` (`964c76f9…`), the web page's
`app.js`, the asset list, the icon font, plus the new Listen Room files. Full list and hashes:
`outputs/w14/w14-report.json`, `windows-manifest.json`.

## w15: press play in the app (2026-10-19, your choice: "open by path, then Space")

Your iPad test on w14 showed the gap: a freshly opened 汽水 is silent and not in Windows media controls,
so the laptop could open it but not start it. Checked on the laptop:
- the keyboard media Play key: 汽水 ignores it;
- 汽水's accessibility tree: no buttons exposed;
- Space sent to 汽水's window: **works, but only while 汽水 is in front**.

w15 therefore, when Start finds no song:
1. finds the music app (remembered, or now also an open-but-silent one found by its process, so no
   "play once first" step);
2. if no copy of it runs, opens it through its **Start Menu shortcut** (your suggestion: it survives
   汽水 updates, unlike `D:\soda music.1.2\…`), else by its `.exe` path. Only a shortcut in your or
   all users' Start Menu Programs folder, with no arguments, pointing at an allow-listed player or its
   launcher. Any running copy of the same player counts (your laptop has two 汽水 installs: 3.1.2 on
   D:, 3.5.1 behind the shortcut), so no second copy is started. A copy hidden in the tray is opened
   again from its own path, which brings its window back;
3. brings its window to the front for about 2 s, sends Space **to that window only**, then puts the
   previous window back in front. Nothing is sent unless the app is confirmed in front;
4. presses at most 3 times, 8 s apart (Space toggles), until Windows reports a song, within 30 s.
   Then the existing steps play it if paused and start Live Transfer.

Checked live on the laptop through w15's own code: 汽水 went from paused to playing in about 2 s, and the
previous window came back in front (paused again after the check). Not yet checked live: a cold start
(汽水 not running at all) and a window hidden in the tray; both are covered by unit tests.

**Trade-off:** for about 2 s the laptop's screen shows 汽水 in front. If someone is typing on the laptop
at that moment, their keys go to 汽水 instead. If 汽水's search box has focus, Space types a space
instead of playing.

**w15** (`outputs/w15/windows`, built next to w14): only `data/app.so` differs from w14
(`cfe98ffb…`); `yinwei_player.exe` and `spatial_core.dll` are byte-identical (`a2de3030…`, `eb764148…`).
Tests: `flutter test` 696 passed, 6 skipped; Node 22/22; `flutter analyze` unchanged (117). Live and
read-only on the laptop: w15's own code finds `汽水音乐.lnk` (→ `SodaMusicLauncher.exe`).

## w16: a closed app's old song no longer counts (2026-10-19)

Your first w15 test (汽水 quit, then Start) ended with "The laptop music app did not start playing".
Cause: the laptop's media reader keeps the last song when Windows reports "no session" (on purpose, so a
short blip doesn't stop Live). After 汽水 was quit, w15 still saw its paused song, skipped opening 汽水 and
asked Windows to press play on a session that no longer existed. Fix: remote start counts a song only
if Windows reported it in the last 6 s (the reader's existing `sessionFresh`); otherwise it opens the
app and presses play. The reader itself is unchanged.

Known leftover: the room's label can still say "汽水音乐 is paused on the laptop" after 汽水 is closed (the
same stale report); the button works either way.

**w16** (`outputs/w16/windows`, next to w15): only `data/app.so` differs (`28aafdfd…`); exe and engine
byte-identical (`a2de3030…`, `eb764148…`). `flutter test` 696 passed, 6 skipped; analyze unchanged.

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
