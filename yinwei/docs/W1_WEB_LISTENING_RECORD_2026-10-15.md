# W1 browser listening — 2026-10-15

Status: implemented and activated after explicit owner restart approval on 2026-10-15. Actual iPad acceptance is pending. Follow [the approved plan](IMPLEMENTATION_LAPTOP_WEB_LISTENING.md).

## Changes

- Reuse the laptop file/Windows Live Transfer output taps, authenticated gateway, stereo AudioWorklet and shared spatial scene. The native engine, HRTF/DSP and Windows routing code were not changed.
- The browser now distinguishes received packets/buffering from worklet rendering. Presentation reports carry the source epoch and processing mode; stale presentation cannot override seek buffering, and original-audio fallback remains visible.
- Listen/Stop availability updates immediately, including when setup fails. Reconnection resets the event sequence baseline. Unsupported browser APIs, paused playback, Live starting, file-array limits and native iPad-input conflicts have explicit messages.
- A second audio listener receives an authenticated `audio_busy` response before attempting its stream; the existing listener continues. Existing connection/ticket/backpressure limits are retained.
- Remove the deferred iPad capture-test link from the listening room. Explain that received stereo follows the receiving device's OS-selected speakers/headphones. Local laptop output remains independent.

## W0 runtime baseline

The network-enabled check found the existing verified R2 player running as PID 5364. Native readiness and fixed-entry availability passed; public health/sign-in returned 200; anonymous session and transform stream access returned 401. No detected unhandled Flutter runtime errors. A restricted-shell probe falsely reported offline; the network-enabled check corrected it. No production player was restarted.

Fixed bookmark: [Open Yinwei](https://yinwei-remote-entry-01a12de8.yinwei-01a12de8.workers.dev/). It now reaches the activated W1 release. It is still a discovery/redirect bookmark, not a stable PWA application origin.

## Automated verification

| Check | Result and limits |
|---|---|
| Node browser PCM/client regression | Passed: packet validation, distinct stereo channels, bounded buffer, SRC, flush, underrun, rendering status, stale epochs, ACK, live/file selection, busy response, unsupported APIs and shutdown. No physical output proof. |
| Sign-in regressions | Six passed, including stale CSRF/cookie recovery and offline handling. Fixture credentials only. |
| Flutter gateway/coordinator/origin/tap suite | 36 reported passed. Optional native-DLL tests were initially not enabled; see the separate ABI check below. |
| Updated gateway suite | 21 passed after adding `audio_busy`; covers auth, tickets, PCM, Live source/stop/start, stalled subscriber, sign-out and local playback preservation. |
| Exact retained DLL ABI | Explicitly supplied the verified R2 DLL: file/live tap ABI and no-device/no-capture checks passed. Older-DLL compatibility cases without supplied old DLLs are not new evidence. |
| Browser interaction/runtime | Isolated synthetic Edge/Chromium fixture passed authentication, rendering, stop/restart, source change, network-style socket disconnect/reconnect, Live stop/start and sign-out. Zero page errors. Portrait and landscape screenshots inspected; no horizontal page overflow. Not Safari/iPad/audio-hardware acceptance. |
| Connector/relay configuration tests | 13 passed. No Cloudflare or other-project resource changed. |
| Windows release | `flutter build windows --release` succeeded. JavaScript syntax, targeted Dart analysis and scoped diff checks passed. |
| Packaged executable smoke test | Passed after approved shutdown of the original player: fixture authentication, 24 non-silent native DSP packets, stop/start, fresh epoch and zero detected Flutter errors. The earlier simultaneous-player attempt was refused by single-instance protection; that guard remains intact. This generated-input test is not actual Windows-source/iPad listening. |
| Activated public backend | W1 PID 39680, native engine ready, file/live browser-audio capabilities true, checker and fixed entry online. Public health/sign-in 200; anonymous session/app/audio/transform access 401; zero detected runtime errors. Personal sign-in and actual iPad hearing remain pending. |

Reproducible browser QA: start `test/remote/browser_preview_test.dart` with `YINWEI_REMOTE_UI_QA` pointing to an isolated fixture directory and `YINWEI_REMOTE_UI_QA_LIVE=1`; then run `node tool/remote/verify_web_listening.mjs <fixture-directory>`. Supply `PLAYWRIGHT_MODULE` as a module URL when Playwright is not locally installed. This tool uses synthetic fixture credentials and refuses non-loopback origins.

## Staged release and activation

Bundle: `outputs/w1/windows/`; SHA-256 manifest: `outputs/w1/windows-manifest.json`. The fresh Flutter release retains the verified native `spatial_core.dll` from `outputs/r2/463b88b/windows/`; the pre-existing modified source-tree DLL was not overwritten. Four changed remote assets were copied from the final working tree into the stage. No owner account or private configuration is included.

| File | SHA-256 |
|---|---|
| `yinwei_player.exe` | `a6eccf9909d802dd05b1c3285c833952b75c5e65a73c85597e7d58a2ac966e1a` |
| `spatial_core.dll` | `eb764148534b6f0df3d0de60c7b6f184fcbf5164ed7298d53a3de95bb6e8c036` |
| `data/app.so` | `964616bbb923b412f924dd08f11184422a9e41d3b6201526b2261c807a57e2c4` |

Activation completed after explicit owner approval. The original PID 5364 was sent a graceful close; it took longer than the initial ten-second wait and then exited without forced termination. The isolated packaged test passed and cleaned up its own process. Only the Yinwei bundle paths/hashes were updated in the existing private deployment configuration, and the existing launcher started W1 as PID 39680. Owner credentials, connector/account resources and disabled Windows startup were retained. The old bundle remains available; its public path/hash rollback metadata is in `outputs/w1/previous-bundle.json`. All 37 staged file hashes and the four changed source assets were verified. Public endpoint readiness/security passed; authenticated production browser acceptance still requires the owner's device. Evidence: `outputs/w1/active-backend-check.json` and `outputs/w1/logs/packaged-activation-test.log`.

## Remaining device gate

### Owner-reported silence investigation

On 2026-10-15 the owner reported no iPad sound while the page showed a connected stream, "Playing laptop stereo", and unhealthy Windows capture. Read-only health checks still passed. Native stderr contained default-output changes between ToDesk Virtual Audio and Steam Streaming Speakers with output-device retries; these are observations, not a proven cause of the reported silence.

Direct window inspection found SodaMusic paused at 02:42 and Yinwei showing silent loopback. Resuming that same track (without changing source/routing or restarting Yinwei) changed Yinwei to HRTF LIVE with nonzero capture energy. Actual iPad hearing after this action is not yet confirmed. Do not convert this capture observation into a passed device test.

The working-tree browser sink now reports whether rendered samples contain signal, with a one-second silence hold and a 0.00001 sample threshold. Client status distinguishes received silence and zero browser volume from rendered non-silent audio. Regression tests for silence, signal recovery, unchanged stereo rendering and muted browser volume pass. **These two additional asset changes are not in the active W1 bundle yet**; preserve current playback and deploy them at an approved restart or idle activation. The active bundle/manifest above remains unchanged.

After activation, open the fixed bookmark in Safari, sign in and tap Listen. Start files or Windows Live Transfer on the laptop. Verify first the built-in iPad speakers, then one available headphone route. Check that stopping browser listening leaves laptop playback intact. Record actual audible file/live playback, source changes, stop/start and reconnection separately from these automated results.

W1 is not fully accepted until those physical tests pass. Protected remote Live controls remain gated behind actual live hearing. Stable-origin PWA work, additional accessories and 30-minute/background acceptance remain later phases; no native iPad signing is required for this route.
