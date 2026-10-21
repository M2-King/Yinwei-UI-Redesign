# Cached 汽水 music — Phase 2

Verified 21 October 2026 on `codex/ios-capture-ci`. Changes remain uncommitted.
Scope: cached playlists and chosen-track playback only. Queue browsing and search
are excluded. No Flutter/Windows/IPA build, commit, push, publish, bundle switch,
deployment change, Tailscale change or restart of the running backend was performed.

## Delivered behavior

- The Listen Room's music-note button opens a glass music sheet. Liked songs
  (catalogue type 1, labelled **Liked songs**) appears first. Lists show
  `N of M cached · updated <time>` using the provider's response time, not the
  inspection time. Unknown or inconsistent totals remain `?`.
- Partial lists show `汽水 only shared part of this list.` Partial results do not
  trigger errors, provider requests, automatic pagination or retry loops.
- Tracks show title, artist and duration. Missing capability, disconnected state,
  pending commands, another controller, historical rows and cached availability
  blockers disable the appropriate actions. Sale/VIP labels alone do not prove
  entitlement; 汽水 decides whether a submitted track can actually play.
- The sheet explicitly says: **Playing brings 汽水 to the front on your laptop
  and changes its queue.** Successful dispatch says **Sent to 汽水**, not a promise
  that its playback or the iPad audio has been confirmed.
- Newest and retained older snapshots are separate. Historical snapshots can be
  selected for browsing and never become an automatic union or playback source.
  Same-session catalogue removals are retained as historical, nonplayable lists.
- A decrease logs only the event name and previous/current/reported counts.
  Neither track names nor provider/account IDs enter this log. Earlier snapshots
  are not deleted to make room for a smaller response.

## Existing command endpoint only

`POST /remote/api/commands` carries both commands. The gateway and private route
allowlist have no production diff; no new endpoint, listener or Tailscale option
was added. Normal owner authentication, CSRF and private-route checks remain.

- `library.list`: command ID, protocol/host identity and bounded query payload;
  returns `library.revision`, list/snapshot handles and a page of rows. Browsing
  does not acquire a playback lease. Read retries recheck the account-bound cache
  instead of returning a command-cache response from an earlier provider account.
- `library.play`: opaque list/snapshot/item handles plus mandatory revision,
  existing control lease, state checks, takeover generation and command-ID dedupe.
  The host resolves a current native numeric track ID. URL/path/argument fields,
  foreign handles, old revisions and historical selections are rejected.
- The launcher validates the exact registered `luna` command template and that its
  executable matches a running SodaMusic process. It constructs the track-only URI
  itself and launches with an argument list, without a shell. Account/catalogue
  selection is revalidated after handler inspection, followed immediately by the
  final lease/takeover guard. Ambiguous launch results are never auto-retried.
- `RemoteOwnerClient.libraryList` calls the existing virtual command method, so
  routed clients retain the existing transport recovery/envelope behavior.

## Cache snapshot and retention limits

The Windows adapter never opens LevelDB as a database or opens its LOCK file.
It reads with ordinary shared file reads, copies the selected live files into
private memory, and parses those copies. CURRENT/MANIFEST determine live files;
obsolete SSTables do not resurrect records. CRC32C, bounded Snappy, tombstones,
complete WAL batches and account/manifest/current/log-set fences are checked.
Incomplete WAL tails are ignored; incompatible/corrupt data fails closed.

- Reader worker: four-second deadline, then immediate isolate termination;
  at most three acquisition attempts for concurrent compaction/rotation.
- Individual source file: 64 MiB; copied live-file snapshot: 128 MiB;
  accumulated decoded blocks: 128 MiB; individual block/JSON: 16 MiB;
  accepted entries: 250,000; WAL files: 16.
- Library: 200 retained lists, fewer than 200 snapshots per list, 1,000 new
  snapshots per session, 10,000 source resources per response, 100 rows per page.
- Private history: 4 MiB per normalized file, 64 MiB total budget, bounded initial
  scan of 5,000 entries. Failed temporary writes also consume the reserved budget.
  Exhaustion refuses new history rather than deleting older snapshots.
- Private history defaults to `%LOCALAPPDATA%\Yinwei\remote\soda-library-v1`.
  Short hash directory names and filenames leave Windows path-length margin;
  full account/list scope hashes are validated inside each file. A custom path
  beyond Windows filesystem limits fails closed rather than changing provider data.
- Only normalized song metadata and provenance are retained; raw provider cache
  responses, credentials, artwork/audio URLs and search/queue history are not
  returned to the iPad. Account markers and native track IDs remain host-side.

The cheap account marker is rechecked even during the two-second browse debounce;
play selections always perform fresh coherent reads. A missing/changed marker
invalidates handles. No external provider API is called by the reader.

## Runtime evidence and limitations

The one approved step-0 URI selected **待我翻过那山**, and Windows media status
reported **Playing** for that title. The chosen track became the current visible
queue entry; the following visible entries remained in order. Full queue identity
and membership were not exhaustively compared. The packaged handler inserts/moves
the requested track near the current item and advances, so this is not a promise
of queue-preserving selection.

Soda remained foreground. It was already foreground for the queue observation,
so focus stealing from another foreground application was not independently
measured; the packaged handler explicitly shows/focuses its window. The UI warning
reflects that behavior. Live/capture controls were not changed. The user accepted
step 0 as passed; no second native playback test was sent.

Final real-reader and real-library smoke checks both returned nine lists with
the surveyed metadata counts: Liked songs **90/424**, annual list **8/33**, and
the other seven **2/2, 9/9, 42/42, 43/43, 19/19, 27/27, 63/63**.
Smoke output contains counts only. Normalized test history stayed in a private
workspace scratch directory; 汽水's files were never written.

The earlier annual-list 31-record response had already been compacted away before
this helper existed. Its native identities cannot be reconstructed from the
retained counts. This implementation preserves snapshots observed going forward;
it does not claim to recover those 31 songs. History screenshots use synthetic
records to demonstrate the retention UI.

## Verification

- Full Flutter suite: **844 passed, 6 skipped**, no failures.
- Node: **43 passed**, no failures/skips, across:
  `bridge_test.mjs`, `music_test.mjs`, `offline_contract_test.mjs`,
  `room_math_test.mjs`, `speakers_test.mjs`, `audio_browser_test.mjs`,
  `capture_probe_browser_test.mjs`, `signin_browser_test.mjs`.
- Dart analysis: **0 errors**, **6 existing warnings**, **111 informational
  notices**; analyzer exits 2 because those repository warnings remain. New Soda
  files have no analyzer diagnostics. Protected engine warnings were not edited.
- Tests cover good/partial/missing/corrupt/schema-unknown cache data, CRC/Snappy
  limits, timeout recovery, tombstones, shrink/overlap without union, retained
  history, account switching, revisions/handles, blocked/invalid selections,
  lease expiry/takeover, command dedupe, auth/CSRF/private routing and bridge
  validation/late-response rejection. Existing audio tests pass.
- An isolated headless Chrome reviewed only the local synthetic page: five
  interaction checks passed, zero browser console errors. It did not attach to
  user browsers, access the provider or invoke the native host.
- Portrait 820×1180 and landscape 1180×820 screenshots were generated and visually
  inspected. Layout, partial notes, foreground warning, duration, historical
  snapshot selection, disabled historical actions and dismissal were verified.
- Scoped `git diff --check` passes. `git diff --name-only -- yinwei/crates` is
  empty. No iOS/Live-capture source changed. The pre-existing dirty runner DLL
  remains byte-identical to the task baseline and was never staged:
  `0d150deff17c3599c92244775b56c119a120604afed1297e150e2f0a2236305f`.

Artifacts (local only):

- [Playlist portrait](<C:/Users/Tim-King.Kings-laptop/.codex/visualizations/2026/10/20/01a15906-6f75-76f2-a26a-56550cd4a467/soda-audit/phase2-step0/music-portrait.png>)
- [Playlist landscape](<C:/Users/Tim-King.Kings-laptop/.codex/visualizations/2026/10/20/01a15906-6f75-76f2-a26a-56550cd4a467/soda-audit/phase2-step0/music-landscape.png>)
- [Tracks portrait](<C:/Users/Tim-King.Kings-laptop/.codex/visualizations/2026/10/20/01a15906-6f75-76f2-a26a-56550cd4a467/soda-audit/phase2-step0/music-tracks-portrait.png>)
- [Tracks landscape](<C:/Users/Tim-King.Kings-laptop/.codex/visualizations/2026/10/20/01a15906-6f75-76f2-a26a-56550cd4a467/soda-audit/phase2-step0/music-tracks-landscape.png>)
- [Historical snapshot landscape](<C:/Users/Tim-King.Kings-laptop/.codex/visualizations/2026/10/20/01a15906-6f75-76f2-a26a-56550cd4a467/soda-audit/phase2-step0/music-history-landscape.png>)

Logs and review harness are beside those images: `final-flutter.log`,
`final-node.log`, `final-analysis.log`, `ui-verification.json`, `review-test.cjs`,
`music-review.html`, and the counts-only `real-library-smoke.json`.

## Files changed

Paths below are relative to `yinwei/apps/yinwei_player/`:

- `lib/remote/soda_cache_reader.dart`, `soda_library.dart`, `soda_track_launcher.dart`
- `lib/remote/remote_owner_client.dart`, `laptop_listen_controller.dart`, `listen_room_bridge.dart`
- `lib/state/app_session_coordinator.dart`, `lib/screens/player_screen.dart`
- `assets/listen_room/bridge.js`, `index.html`, `music.js`, `ui.js`, `ui.css`, `dev/dev-host.js`
- `test/remote/soda_cache_reader_test.dart`, `soda_library_test.dart`,
  `soda_track_launcher_test.dart`, `soda_commands_test.dart`,
  `listen_room_bridge_test.dart`, `remote_gateway_test.dart`, `private_route_test.dart`
- `test/listen_room/music_test.mjs`

This report is `yinwei/docs/SODA_MUSIC_PHASE2_REPORT.md`. Production
`remote_gateway.dart` and `routed_owner_client.dart` have no remaining diff.
Unrelated existing website/output/DLL changes were left alone.

## Remaining device checks

No new app binary was built or deployed, as requested. After a separately
authorized release, verify the new iPad sheet against the laptop: portrait and
landscape touch/scroll, current account change/logout, laptop takeover, real
unavailable/VIP songs, restart-restored history, foreground behavior from another
app, and audible continuity through a selected track while Live is running.
Step 0 passed, but this task does not claim a device/ear check of the newly wired
UI or changed application binary. Provider cache schemas/handler templates may
change with updates; unsupported versions fail closed and require adapter review.
