# Listen Room tap regressions — 2026-10-24

Base: `codex/ios-capture-ci`, `2d1fdd1`. Owner My Lists changes were retained in
the working tree. Only this task's hunks are intended for the local commit.

## Result and limits

Implemented fixes for the reproduced application-side failures. This is **not
device acceptance** of iPad build 65 or laptop w31, and does not establish the
<=3 s tap-to-sound goal. No push, workflow dispatch, iOS build, installer run or
laptop bundle switch was performed. Audio engine, HRTF, DSP, capture, Live
Transfer routing and DLL code were not changed.

## Evidence before fixes

Instrumentation was added before behavior changes. The new Flutter regression
file initially failed all four checks:

1. A 500-song queue was repeated in all 100 telemetry messages.
2. A browse revision change caused the next queue tap to dispatch no command.
3. Live title `B` produced queue index -1 instead of 1.
4. Ten pending queue taps produced zero notices.

The Node baseline confirmed that a completed `pending:false, playing:false`
snapshot could leave an optimistic `playing:true` value visible. It also
confirmed that an unchanged queue already did **not** appear in `merge()`'s
changed-fields list. The identity-comparison theory alone was incorrect.

A read-only probe of this laptop's real Soda metadata cache measured both full
cache reads and account-only reads. It did not launch Soda or change playback,
and used `persistHistory:false` to avoid writing library history.

## Bugs, causes, changes

### 1. Slow sound start and late player bar

Two application-side costs were measured; their contribution to the reported
device symptom cannot be isolated without a new device trace.

- `resolveTrack()` refreshed the full cache twice per selection: once before
  launcher identity preparation and again in the final revalidation callback.
  On the actual laptop these two calls took 615.193 ms and 590.160 ms.
- `push()` rebuilt and encoded all queue metadata on every changing telemetry
  update. The page repeatedly sanitized and compared it; picker signatures also
  serialized the catalogue during rendering.

Fixes: a final revalidation may reuse a fully resolved snapshot younger than one
second, but **always** re-reads the account. Longer handler waits perform another
full refresh. Ordinary selections still fully refresh. Account changes, logout
and failed account reads invalidate old handles. A bounded existing cache read
remains the full-refresh path.

Queue metadata now travels only on a change or explicit resynchronization.
`queueRevision` and `queuePlaying` carry frequent updates. The page compares
queue content, retains unchanged song arrays and caches metadata signatures.
WebView writes are coalesced while one execution is unfinished. Page reload and
host-change clearing are covered by tests.

Files: `lib/remote/soda_library.dart`, `lib/screens/player_screen.dart`,
`lib/remote/listen_room_bridge.dart`, `assets/listen_room/bridge.js`,
`assets/listen_room/ui.js`.

### 2. Paused laptop while iPad shows playing

The reproduced page failure was an optimistic playing hold masking a completed
paused snapshot. The hold can be extended while commands are pending. Completed
snapshots (`pending:false`) now immediately win for `playing`; holds for spatial
gestures remain unchanged.

The bridge already used `live.playing` for transport correctly. Its queue row
lookup instead used file-track metadata during Live playback. It now uses Live
metadata; when Live supplies no artist, only a unique matching title is selected.
Ambiguous titles remain unknown. A command outcome explicitly clears the picker
wait marker, so an unknown index cannot leave the marker stuck indefinitely.

Files: `assets/listen_room/bridge.js`, `assets/listen_room/ui.js`,
`lib/remote/listen_room_bridge.dart`.

The local browser stand-in was paused through the real page controls and showed
the Play button and Paused status. Real Windows media-session latency was not
measured, so persistent incorrect host metadata is neither confirmed nor ruled out.

### 3. Quick-menu and music-sheet taps stop responding

The iPad still rejected old library revisions even though `2d1fdd1` let the
laptop resolve older copies safely. A browse refresh cleared cached queue
metadata, and `_queueCurrent()` then refused active queue taps. Several pending
guards silently returned; disabled DOM controls prevented explanations too.

Fixes: retain bounded browse metadata across revision changes and retain the
active queue as a lookup fallback. Delegate account/catalog/token validity to
the laptop. Host-session/sign-out fences, capability checks, historical-row
restrictions and laptop lease checks remain in place. Pending and unavailable
selections produce fixed notices. Temporarily unavailable playable controls can
receive taps to explain the reason; provider-unplayable rows remain disabled.
Selecting an already-playing row explains that outcome; selecting a paused row
can dispatch playback again. This does not automatically retry external actions.

Files: `lib/remote/listen_room_bridge.dart`, `assets/listen_room/ui.js`,
`assets/listen_room/music.js`.

Ten-tap tests cover compact and window pickers, cached and online sheets, plus
native bridge pending refusals. In the mixed UI fixtures, each sequence gives
five dispatched intents and five pending notices. These are simulated dispatches,
not proof of ten audible song changes.

## Measured timings

Measurements below are local samples, not an iPad benchmark. Times vary with load.

| Measurement | Before | After |
|---|---:|---:|
| Real cache first selection resolution | 615.193 ms | 546.040 ms |
| Real cache final revalidation | 590.160 ms | 5.722 ms |
| Sum of the two resolution calls | 1205.353 ms | 551.762 ms |
| Standalone full cache read samples | 933.034 / 557.859 / 599.094 ms | 936.403 / 573.852 / 618.780 ms |
| Standalone account read samples | 6.910 / 6.072 / 5.795 ms | 8.224 / 5.780 / 5.960 ms |
| Initial 500-song script size | 22,243 bytes | 22,279 bytes |
| Subsequent telemetry script size | Full queue repeated | 948 bytes |
| Queue-containing repeats over 100 telemetry changes | 100 | 0 |
| Dart push fixture p50 / p95 | 1.056 / 2.137 ms | 0.360 / 1.128 ms |
| Node full-queue encode/parse/merge fixture p50 / p95 | 0.556 / 0.910 ms | 0.476 / 0.837 ms |
| Node telemetry-delta encode/parse/merge p50 / p95 | Full-queue path above | 0.0079 / 0.0201 ms |

The Dart push fixture uses a fake `run()` callback, not WKWebView. The Node
fixture includes serialization, parsing and bridge merging, not GPU drawing or
real WebView IPC. Initial full-queue messages are intentionally slightly larger
because they include the new scalar queue fields. Metadata changes still cost a
full message; frequent telemetry does not.

## Tap-stage trace coverage

The following timestamps are now available. **Before/after device durations for
these stages are unavailable** except for the cache and fixture measurements
above. No whole-path timings or audible-completion timings are inferred.

| Stage | Timestamp / measurement |
|---|---|
| Page selection sent | `page.tap`, page monotonic time and wall time; intent carries `tapMs` and `tapEpochMs` |
| Bridge receives queue/sheet/media intent | `bridge.intent` |
| `_playMusic` guards | `bridge.play.guards`, or `bridge.play.refused` |
| Bridge dispatch | `bridge.command` |
| Client command and request | existing `_commandTimings`, `client.command`, `client.request.sent` with command ID |
| Laptop receives `library.play` / `soda.play` | `host.command.received` with the same command ID |
| Resolve and cache/account fence | `host.resolve.start`, `.refresh`, `.end`, including elapsed microseconds and reuse flag |
| Launcher / identity / final fence | `host.launcher.start`, `.identity`, `.revalidated` |
| Soda handoff | `host.handoff.start`, `.submitted` — submission is not audible success |
| Media session changes | `host.media.changed` with playing state |
| Snapshot send / receive | `host.snapshot.sent`, `client.snapshot` |
| Dart state encode / WebView execution future | `bridge.push.encode`, `bridge.push.run` |
| Page apply including synchronous render | `page.apply` with elapsed microseconds and changed-state flags |

Dart traces use `ListenTap` developer logging and a 256-row bounded ring exposed
through `audioDiagnostics()['tapTrace']`. They are active for 30 seconds after a
control intent. Existing command timing/host timing fields remain intact. Page
traces are exposed by `YinweiListen.tapReport()`, also bounded to 256 rows. No song
titles, account/provider identifiers, credentials, addresses or audio are logged.
Wall clocks on different devices are not assumed synchronized; compare local
monotonic durations and match command IDs across hosts.

## Leads ruled out or not reproduced

- **A, identity means queue changed every push:** ruled out by the baseline
  content-comparison test. Repeated transmission/comparison/signature work was real.
- **B, unbounded historical lookup:** not present in the inspected older-copy
  lookup; it performs finite collection searches. Existing cache-reader timeout
  and retention limits remain in place.
- **B, permanently stuck `_musicPlaying`:** not reproduced. It resets in
  `finally`. HTTP commands have 60-second response/body-inactivity deadlines;
  routed recovery is finite. There is no single overall controller deadline.
  The patch explains pending taps rather than assuming a command completed.
- **C, bridge chooses wrong transport field:** ruled out for the inspected
  `live.playing` mapping. Wrong queue metadata and optimistic masking were reproduced.
- **C, sustained Windows media-session lag:** unmeasured; requires device trace.
- **D, duplicate full reads:** measured on the actual cache and addressed while
  retaining an account fence and full refresh after slower preparation.
- Real iPad slowdown, permanent paused-state mismatch and audible ten-tap
  behavior were not reproduced on hardware. Existing binaries were not replaced.

## Verification

- Full `flutter test --no-pub`: **987 passed, 6 skipped, 0 failed**.
- `node --test test/listen_room/*.mjs test/remote/*.mjs` (expanded globs on
  Windows): **89 passed, 0 failed**.
- Isolated HEAD plus staged-source export, excluding owner work: **113 focused
  Flutter tests and 88 Node tests passed**. The working tree's additional Node
  test belongs to the owner and was not staged.
- Windows-target debug Flutter kernel/asset bundle compiled with
  `flutter build bundle --debug --no-pub --target-platform windows-x64`.
  This did not build iOS or install/switch a laptop bundle.
- Browser: compact picker selected a new song; pause converged to Play/Paused;
  screenshots inspected; console warnings/errors: none observed.
- `git diff --check` and `git diff --cached --check`: clean. Repository analysis:
  **0 errors, 104 warning/info findings**; analysis is not a clean lint result.
- The four shared files' unstaged edits were compared against their saved
  pre-task versions: the owner's changes are preserved exactly as line edits.
  No prohibited path is staged.

New tests: `test/remote/listen_room_tap_regression_test.dart`,
`test/remote/soda_revalidation_test.dart`, `test/listen_room/tap_regression_test.mjs`.
Updated tests: `test/remote/listen_room_queue_test.dart`,
`test/listen_room/browse_modes_test.mjs`, `test/listen_room/music_search_test.mjs`.
Read-only timing probe: `tool/listen_room_tap_probe.dart`.

Diagnostics-only changes also touch `lib/remote/listen_tap_trace.dart`,
`lib/remote/laptop_listen_controller.dart`, `lib/remote/remote_owner_client.dart`,
`lib/remote/remote_gateway.dart`, `lib/remote/soda_track_launcher.dart`,
`lib/state/app_session_coordinator.dart` and the media-change observer in
`lib/screens/player_screen.dart`.

The owner approves push, iOS build and bundle switch separately. Next device
validation should capture the new trace on both sides and verify <=3 s audible
startup, timely cover/progress, pause convergence and ten real consecutive taps.
