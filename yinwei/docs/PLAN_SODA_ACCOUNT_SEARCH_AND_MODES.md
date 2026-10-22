# 汽水 account, search, playlists and listening modes

Date: 2026-10-21 (Asia/Shanghai)
Status: proposal only; writing this document does not authorize implementation.
Repository: Yinwei, branch `codex/ios-capture-ci`.

## Outcome

Let the owner connect a 汽水 account from Yinwei's iPad music sheet, search songs,
browse personal playlists and Liked songs, and choose activity/mood recommendations.
The first version uses the laptop as the provider adapter. It is not a standalone
iPad 汽水 client and does not sign the separate official iPad app into an account.

Selecting a song initially uses the existing laptop deep-link playback path. Account
access alone does not remove its delay. Faster playback is a separate investigation
with a separate approval gate, not a promised result of account integration.

## Boundaries and approvals

- This task changes documentation only. No dependency installation, login attempt,
  provider request using the owner's credentials, app interaction or playback test.
- Preserve engine/Rust code (`crates/spatial_core` and other `crates/`), HRTF, DSP,
  Live Transfer/capture and all DLLs. Never stage `spatial_core.dll`.
- Do not change `deployment.json`, `outputs/`, the active bundle, firewall, Tailscale
  configuration or existing route selection. No new listener or interface exposure.
- No commit, push, build, workflow execution, publication or backend restart under
  this plan-writing authorization. Later implementation and release need approval.
- No foreground keyboard automation, OCR, application injection, debugger attachment
  to 汽水, interception proxy or modification of its installed files.
- Account writes (likes, playlist edits), actual 汽水 queue access and automatic
  continuous playback are outside the first implementation.
- Stop and report if a necessary dependency requires a protected change, new socket,
  account extraction, weakened browser security or a different product direction.

## Existing foundation

The current music sheet and `SodaLibrary` browse snapshots copied from 汽水's cache.
The host owns provider track IDs and returns opaque handles. `library.list` and
`library.play` travel through `POST /remote/api/commands`; the play command checks
revision, control lease/takeover and command-ID deduplication. The host constructs
a numeric-track-only `luna://` URI and reports submission, not confirmed playback.

Keep these paths working for older clients and when account integration is off.
See [the existing implementation report](SODA_MUSIC_PHASE2_REPORT.md) for cache
bounds, snapshot policy and historical verification; its test counts are not
verification of any future account work.

## Research evidence and uncertainty

These are unofficial third-party implementations, inspected as references on
2026-10-21. Their claimed tests have not been reproduced with this owner's account.
Pin and inspect exact revisions before selecting or executing any dependency.

| Reference | Relevant evidence | Limitations |
| --- | --- | --- |
| [libresoda QR guide](https://github.com/sodahub-org/libresoda/blob/main/docs/QR-LOGIN.md) and [login source](https://github.com/sodahub-org/libresoda/blob/main/src/soda/qr_login.rs) | QR creation, confirmation, session collection and additional-verification handling | Detailed guide requires a desktop Chromium signing context; plain HTTP is documented as unreliable. Top-level summaries and detailed documentation disagree about maturity. This is not a ready-made iOS login flow. |
| [qishui-api](https://github.com/guowenye/qishui-api) and [client source](https://github.com/guowenye/qishui-api/blob/main/src/qishuiClient.js) | QR status, account profile, personal playlists and collections | QR confirmation may require the official 抖音 app. Successful session acquisition and current signatures remain unverified here. |
| [music-lib search](https://github.com/guohuiyuan/music-lib/blob/main/soda/search.go) and [track parser](https://github.com/guohuiyuan/music-lib/blob/main/soda/song.go) | Android-style search returning native track identities | Optional-cookie code does not prove anonymous service availability; fixed device/version fields can age. Its README marks 汽水 QR login as not working. |
| [libresoda client guide](https://github.com/sodahub-org/libresoda/blob/main/docs/CLIENT-API.md) and [feed source](https://github.com/sodahub-org/libresoda/blob/main/src/soda/feed.rs) | Personal collections; scene catalogue and recommendation request parameters | Project reports 45 scenes. Gaming/studying availability for this owner is unverified. Fetching scene content is not control of the official app's active mode. |
| [Meting-API](https://github.com/qq01-hub/Meting-API) | Additional QR-login reference and session-expiry behavior | Backend service, not an iOS SDK; do not deploy its bundled server unchanged. |
| [musicdl issue 97](https://github.com/CharlesPikachu/musicdl/issues/97) | Search broke and was later marked fixed | Demonstrates maintenance risk; a repaired upstream issue does not verify our environment. |

Licence screening precedes reuse: music-lib/libresoda declare AGPL, qishui-api and
Meting-API declare MIT, and current musicdl declares PolyForm Noncommercial.
Review exact files, dependencies and any bundled proprietary assets. Do not copy
code from a restricted project into a differently licensed adapter without review.
No public signing service receives session cookies or signed account requests.

## Proposed architecture

```text
iPad Listen Room music sheet
  -> validated Flutter bridge intents
  -> existing authenticated command endpoint and route transport
  -> AppSessionCoordinator / account-scoped provider adapter on laptop
  -> official 汽水 account, search, collection and scene endpoints

Selected current track handle
  -> existing revision + lease + takeover + deduplication guards
  -> host-built luna:// link
  -> official laptop 汽水 -> existing Live/listening path
```

Provider access, normalized data, session lifetime and track identity stay in one
host service. No independent iPad provider state competes with the host. No spatial
coordinates or scene rendering mappings change in this work.

Put future features behind an additive, default-off capability switch. Advertise
account, search and scene availability separately so unsupported actions stay
disabled. Existing `sodaLibrary` cache browsing remains independent and usable.

### Account connection

1. Owner explicitly starts Connect account on the paired iPad. The host creates a
   short-lived, isolated login transaction bound to that owner/session/generation.
2. Display the upstream-issued QR code. Identify which official phone app must scan
   it; do not assume 汽水 and 抖音 scanners are interchangeable. Same-iPad approval
   without another device is unverified and is not promised.
3. Poll with upstream-directed backoff and finite expiry. Accept confirmed server
   state plus a verified account-profile read, never a leftover cookie alone.
4. If additional verification needs a desktop browser, say so and allow cancellation.
   Do not expose the reference project's localhost verification server to the iPad
   or copy browser security-disabling flags. Review a safe adaptation before coding.
5. Store the resulting provider session using Windows-protected storage. Keep raw
   cookies, signature material and device identifiers out of the web bridge, iPad
   responses, logs, diagnostics, repository and ordinary snapshot files.
6. The iPad stores only its existing Yinwei authentication in the established secure
   path. It does not receive a provider bearer cookie in this host-backed design.
7. Disconnect cancels pending work, clears local credentials, invalidates handles
   and isolates retained metadata. Local disconnect must not claim upstream logout
   unless revocation is supported and verified.

Reject expired/replayed transactions and late results after disconnect/account
switch. Account changes require explicit confirmation; an API account must not
silently replace the account inferred from the desktop cache. Before deep-link
play, ensure the desktop account matches, or disable play and explain the mismatch.
Friends/other controllers cannot initiate or replace the owner's provider login.

### Search

- Read-only provider requests; normalize title, artists, duration and optional
  approved artwork metadata. Never resolve/download audio to populate search.
- Proposed initial limits: query 120 Unicode characters; 20 results/page; one
  active search per owner; 350 ms typing debounce; 10-second request deadline;
  2 MiB maximum response and bounded JSON nesting; small account-scoped cache.
  Tune only after measurements, keeping resource use bounded.
- Preserve native IDs as decimal strings on the host, avoiding JavaScript integer
  precision loss. Reject invalid IDs and never infer identity from titles.
- Cancel superseded requests and reject late responses using account, query and
  transport generations. Do not turn authentication/schema failures into 'no results'.
- Return opaque expiring result handles and a revision. Selecting a result performs
  current identity/availability checks through the host; raw URLs/IDs are not client
  playback commands. No query history is retained by default.

### Personal playlists and Liked songs

- Liked songs remains first and labelled **Liked songs**. Read created playlists,
  saved collections and details separately according to verified provider semantics.
- Follow bounded provider cursors, not guessed numeric offsets. Detect repeated
  cursors, duplicate identities, changing totals, missing pages and mixed media.
- Preserve cache provenance: API-fetched snapshots and disk-cache snapshots are
  separate. Fetch time is not the provider's modification time; label it accurately.
- Keep `N of M cached · updated <time>` for cached snapshots; unknown totals stay
  unknown. Partial snapshots show `汽水 only shared part of this list.`
- Keep newest and last-known-good snapshots separately. Never automatically union
  them. A shrink logs counts only and retains the previous snapshot for the session.
  Historical-only tracks remain browsing-only until current membership is verified.
- Treat completion as a verified pagination outcome, not merely `N == M`; retain
  uncertainty if totals, resource types or page boundaries are inconsistent.
- Specifically compare API results for Liked songs and the annual playlist against
  the recorded cache baseline (90/424 and 8/33). Do not claim to recover the older
  31 annual records from counts, or erase existing history on a failed refresh.

### Listening modes

- Fetch the current provider mode catalogue and display its returned labels/IDs.
  Do not hard-code a promise that Gaming or Studying exists for this account.
- Use the selected mode's verified scene parameters to request recommendations;
  guard against stale mode handles and mixed playlist/radio/track response types.
- Explain that this chooses recommendations inside Yinwei. Do not claim it changes
  the official laptop app's mode, spatial processing, EQ or actual current queue.
- First delivery supports browsing mode content and choosing an individual track.
  Continuous mode playback/automatic next-track selection needs a separate design
  and approval; clicking one track through a deep link does not provide that feature.

### Command and UI integration

Extend the existing command endpoint, not the route/listener surface. Proposed
command families are account connect/status/disconnect, library search, API-backed
library browse and mode catalogue/content. Final names and protocol schemas should
be reviewed before implementation. Do not overload old `library.list` semantics in
a way that makes older clients perform new network operations unexpectedly.

All commands retain owner authentication, CSRF, payload bounds and transport
generation checks. Browsing does not seize playback control. Account mutation is
owner-only with explicit intent; playback requires the existing control lease.
Reuse command-ID deduplication, including duplicate taps after reconnect; ambiguous
play submissions must not be automatically repeated. The same login-start command
ID cannot create multiple QR sessions. Disconnect fences in-flight completions.

Extend the existing Apple-like glass music sheet with Connect account, Search,
My playlists (Liked songs first), and Listening modes. Show cached/API provenance,
loading/expiry/partial states and actionable unavailable states. Keep the foreground
and queue-change warning wherever playback still uses the laptop deep link.

## Playback latency: independent gate

Measure with approved supervised playback before changing behavior:

- iPad tap -> host receives -> validation/cache read completes -> launcher dispatch;
- dispatch -> official app reports selected track playing;
- host playback -> first audible selected-track sound on iPad (device/ear check).

Use monotonic local timings and correlated events; do not subtract unsynchronized
device clocks. Compare visible versus minimized 汽水 and repeated cold/warm trials;
report sample counts, median and tail latency with network/listening-buffer context.
Instrument counts/timings only, not song names, IDs or account data.

Check avoidable host reads and launcher handoff costs without weakening account,
revision or lease checks. Account search itself does not speed a deep-link launch.
Direct authenticated audio playback could avoid the official app handoff, but would
introduce a different media-input/output architecture and entitlement/signing work.
It is explicitly excluded here. No engine, Live or streaming-buffer changes follow
from approval of account browsing.

## Implementation phases and gates

| Phase | Work after explicit approval | Gate before proceeding |
| --- | --- | --- |
| 0 — source and metadata validation | Pin/review candidate sources and licences; isolated, bounded anonymous search/scene reads, without running supplied install or smoke scripts blindly | Correct stable track IDs, known schema, no account writes, acceptable timing; otherwise stop/report |
| 1 — supervised account proof | With specific login consent, complete an isolated QR transaction, read profile and small playlist/collection samples, test expiry/disconnect | Correct owner/account, session isolation and safe credential handling; no public signer/new listener/unsafe browser flags |
| 2 — host metadata service | Add normalized account/search/library/mode adapters with offline tests and strict bounds; retain disk cache fallback | Handles, revisions, account fences, pagination and lossy-cache policy pass; no raw secrets/data leak |
| 3 — iPad integration | Extend bridge and music sheet, capability gating and recovery; keep existing deep-link play | Review screenshots, interaction/accessibility checks and old-client compatibility; no queue/mode-sync claims |
| 4 — device acceptance | Owner-approved account and playback checks, latency measurements and regression tests | Explicit report of what works and what still needs verification; release is separately approved |

If account signing requires unsupported infrastructure, stop at the last verified
phase. Anonymous search and local cached filtering can remain independent options;
do not silently collect desktop cookies or substitute a third-party public service.

## Expected change areas, not changes made

Paths below are relative to `yinwei/apps/yinwei_player/`:

- New provider/account-session adapter files under `lib/remote/`, separate from
  protected engine and capture code; `soda_library.dart` for scoped metadata/handles.
- `lib/state/app_session_coordinator.dart` for capability/command integration;
  `lib/remote/remote_owner_client.dart` and `laptop_listen_controller.dart` for
  typed requests and transport/account generation handling.
- `lib/remote/listen_room_bridge.dart` and `assets/listen_room/bridge.js`, `music.js`,
  `index.html`, `ui.css`, plus the synthetic development host, for the music sheet.
- Existing cache-reader and track-launcher interfaces only if an additive change is
  necessary and independently tested. Preserve current behavior when disabled.
- Corresponding Dart/Node fixtures and tests; use synthetic/redacted records.

## Verification before claiming delivery

- Login tests: waiting/scanned/confirmed/cancelled/expired, rate limits, additional
  verification, concurrent sessions, replay, wrong owner, logout/relogin races,
  credential-store failure and session expiry. No automatic SMS or account writes.
- Search tests: Chinese/Latin/emoji, duplicate versions, long input, missing fields,
  invalid or oversized numeric IDs, empty versus blocked responses, timeout,
  cancellation, schema changes and response/decompression bounds.
- Library/mode tests: real cursor semantics, repeated/missing pages, changing totals,
  partial/shrinking lists, retained history, source/account separation, unknown modes
  and mixed content. Fixtures must not contain real session/account details.
- Security/commands: auth/CSRF, opaque handle/revision/expiry, lease/takeover, dedupe,
  route migration/reconnect, late results and privacy in responses/logs/diagnostics.
- Full `flutter test`; `node --test test/listen_room/*.mjs test/remote/*.mjs` (list
  actual files and counts); Dart analysis with existing/new findings separated;
  Windows build only after build approval. Cross-platform tests use valid host paths.
- Synthetic review page via `python yinwei/tools/listen_room_review.py OUT.html`;
  portrait/landscape screenshots for login states, search, partial playlists and
  modes; interaction and console checks. Do not put real login QR/session data in
  screenshots or committed fixtures.
- Owner-supervised iPad/laptop checks: matching account, complete/partial counts,
  chosen-song correctness, foreground/queue effects, measured tap-to-sound delay,
  existing file/Live playback and spatial behavior. No playback manipulation during
  unsupervised metadata tests; report unverified device/audio paths explicitly.
- Check scoped diff/whitespace and protected-file baseline. Never stage the existing
  dirty runner DLL or unrelated website/deployment/output changes.

## Rollback and deliverables

Disable the new capability switch to return to current cached browsing/deep-link
playback. Cancel new requests, clear optional credentials and invalidate new handles
without deleting existing metadata history. No bundle switch is part of rollback
under this authorization.

Each phase report must distinguish inspected source, upstream claims, local tests
and real-device results. Final implementation reporting includes changed files,
exact source revisions/licences used, test/build counts, screenshots, measured
latency, account/data limitations and any remaining owner checks. No release until
the owner explicitly approves it.
