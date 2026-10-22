# Soda online integration — unreleased work

22 October 2026. Branch `codex/ios-capture-ci`. No commit, push, app build, release,
backend restart, bundle switch or protected-file modification in this work.

## Completed source work

The existing, uncommitted cached-search implementation is preserved. A separate
anonymous laptop adapter now feeds **On 汽水**, below **In your lists**, in the same
music-sheet search box. Cached filtering and playlist/deep-link playback keep their
old protocol and remain independent of network failure. Liked songs stays first.

- `lib/remote/soda_online.dart`: fixed official HTTPS metadata endpoints, generated
  local device/install identities, 10-second total deadline, no redirects, no
  credentials/cookie jar, 2 MiB body limit and depth 32. One active request; a newer
  query cancels the old client and fences its response. Five memory-only cached
  pages, 60-second lifetime, random opaque handles and revisions. Decimal provider
  IDs stay on the host; raw cache/provider objects, audio URLs and IDs are excluded.
- `AppSessionCoordinator`: new `soda.search` and `soda.modes` reads through the
  existing authenticated command endpoint. Reads validate host and payload without
  taking a playback lease. Additive `soda.play` uses the same queued lease,
  takeover, final dispatch guard and command-ID deduplication as `library.play`.
- `player_screen.dart`: optional adapter wiring, default-off process environment
  switch `YINWEI_SODA_ONLINE=1`. This switch has **not** been set. No new listener,
  application route, dependency or helper executable is needed by the Dart adapter.
  Playback capability remains disabled in the actual app until its supervised gate.
- `remote_owner_client.dart`, `laptop_listen_controller.dart`: typed metadata
  requests, existing route transport, host/client/transport-generation response fence.
- `listen_room_bridge.dart`, `bridge.js`, `music.js`, `ui.js`, `index.html`: additive
  capability, validated requests/responses, separate local/online request counters,
  safe text rendering, mode catalogue and unavailable-action states. Cached rows
  still use `library.play`; new online rows cannot supply URLs or native IDs.
- `dev/dev-host.js`: explicitly synthetic review data only; no real launch.
- `soda_cache_reader.dart`: while running the complete suite, a startup race was
  reproduced in the pre-existing 1-microsecond timeout test. A worker could begin
  a cache read after its caller had already timed out, leaving Windows handles
  during test cleanup. Workers now spawn paused and resume only if still wanted.
  The original cache-reader tests and their strict deadline assertions are
  unchanged; all 18 passed after the fix. An attempted teardown-only wait was
  removed because it did not address the race.
- `tool/soda_online_probe.dart`: two bounded anonymous production-adapter reads.
- `tool/soda_online_playback_probe.dart`: interactive Windows-only one-song harness,
  requiring `--supervised` and a final typed PLAY. It uses the existing validated
  launcher, never starts/stops Live, and reports submission rather than sound.
  It has **not been run**. It does not enable production playback.

No API-account cookies, login or account catalogue are added to the production
adapter in this phase. The isolated HTTPS QR prototype remains separate.

## Runtime evidence and checks

The actual Dart adapter returned **20 real anonymous search rows in 1,463 ms** and
**45 real mode labels in 834 ms**. These are two measurements, not a latency SLA.
No audio fetch, selected-song launch, account read or mode change occurred.

The full Flutter suite passed with **921 passed, 6 skipped**. New adapter/command
coverage includes opaque handles/revision/expiry, unavailable tracks, privacy,
Unicode/invalid requests, response/depth limits, redirects/compression, timeout,
supersession, metadata host fencing, lease takeover and duplicate submissions.

All **55 Node tests passed**. Actual test files:

- `test/listen_room/bridge_test.mjs`
- `test/listen_room/music_test.mjs`
- `test/listen_room/offline_contract_test.mjs`
- `test/listen_room/room_math_test.mjs`
- `test/listen_room/speakers_test.mjs`
- `test/remote/audio_browser_test.mjs`
- `test/remote/capture_probe_browser_test.mjs`
- `test/remote/signin_browser_test.mjs`

The new room UI passed **10 browser interaction checks**, zero console errors:
Liked songs, independent cached/online results, section order, unavailable actions,
mode catalogue, back navigation, stale response rejection and close/reopen cleanup.
The review uses current app assets with synthetic metadata. It is not an iPad or
account-login test. Portrait/landscape screenshots were inspected:

- `.tmp/soda-phase0/integration-search-portrait.png`
- `.tmp/soda-phase0/integration-search-landscape.png`
- `.tmp/soda-phase0/integration-modes-landscape.png`

Generated review: `.tmp/soda-phase0/online-integration-review.html`, using
`python yinwei/tools/listen_room_review.py OUT.html`.

Final verification: the normal full Flutter run finished **921 passed, 6 skipped**
after the worker-start fix. Two earlier repeat runs reproduced the same Windows
temporary-folder lock in the unchanged deadline test; a cleanup wait did not fix
it and was removed. The original 18 cache-reader tests now pass without assertion,
deadline or teardown changes. Full run log: `.tmp/soda-phase0/flutter-online-complete.log`.

Final Dart analysis reported **0 errors, 6 existing warnings and 111 information
findings**, exit 2. There are no findings in the new adapter, new tests, either
probe or the cache-reader fix. The warnings are the existing unused declarations
in EngineController, update policy, position sidebar and two runtime test imports;
protected engine declarations were not edited to silence them. Log:
`.tmp/soda-phase0/analysis-online-complete.log`.

The supervised launcher harness was compile-checked using its **no-argument refusal
path**, exit 64 as expected. No provider request, song launch or Live change was
performed by that check. Its interactive playback path remains unexecuted.

Scoped `git diff --check` passed. `git diff --name-only -- yinwei/crates` and the
staging area are empty. The pre-existing dirty runner DLL remains SHA-256
`0d150deff17c3599c92244775b56c119a120604afed1297e150e2f0a2236305f` and was never
staged. Existing cached `soda_library.dart` retains its pre-task hash
`c31abfeb6bf5a549457971c4b183e4378ff6ef56fd1dc1c85d084d3c9f1d046f`.

Windows build is intentionally not run: release/build approval has not been given
for this integration. Existing engine/HRTF/DSP/Live behavior has unit coverage but
has not been rechecked by ear on an iPad in this work.

## Source and licence handling

Protocol request/response facts were independently implemented from the prior
verified probe. MIT reference: `guowenye/qishui-api`, revision
`e409c10fe7441a10d370da7da61d62bbc1e5126c`, copyright 2026 arrow.
Its full MIT notice is retained in `SODA_QISHUI_API_REFERENCE_LICENSE.txt`.
No upstream implementation/dependency was installed or executed.

AGPL reference `sodahub-org/libresoda` at
`f13712c7bc1abc6bc4d727575a5f034de1642547` was inspected for protocol facts and
limitations only. No AGPL implementation was adapted into Yinwei. Its feed client
requires login; this is an upstream claim, not proof that anonymous content can or
cannot work. No scene-content request schema or response is claimed verified here.

## Required gates / Claude continuation

Do not call all six requested product steps complete yet:

1. Online metadata source integration is implemented and tested, default off.
2. An online-result playback proof is still required with the owner listening.
   The interactive harness is ready. Do not launch it unattended or mark dispatch
   as audible playback. Check numeric ID correctness, foreground/queue and delay.
3. The separate Cloudflare prototype creates/checks QR transactions and protects
   them with a one-use owner link and Secure HttpOnly session. **No owner login or
   profile has been verified.** The redacted state remains disconnected. Obtain
   the owner's QR approval and verify a real profile before account data work.
4. Then verify small account playlist/collection samples, match the desktop/cache
   account, inspect cursor semantics, and implement account-scoped adapters/bridge
   UI under the plan's account and lossy-cache rules. Do not extract desktop cookies.
5. Mode **catalogue** is verified; mode **songs** and selecting recommendations are
   not. They remain disabled, and no official laptop mode/queue control is claimed.
6. Test real account/library/mode cases and iPad access before requesting release.
   No app release, production restart or enablement is authorized by this document.

Current temporary owner link/status files live under `.tmp/soda-phase0/`:
`cloudflare-owner-link.txt`, `cloudflare-preview-status.json` and
`cloudflare-account-status.json`. Never copy the link secret, QR, account name/ID,
provider cookies or identity files into a report or commit. The earlier normal-DNS
failure still makes campus/Safari reachability an owner check; HTTPS itself passed
through a verified Cloudflare edge. The complete hosting/proof history is in
`SODA_ACCOUNT_PROOF_PROGRESS.md`.

Rollback is omission of the default-off capability. Disconnect any optional test
account separately. Leave existing cached-search work, snapshots and unrelated
working-tree changes intact. Never stage the pre-existing dirty runner DLL.
