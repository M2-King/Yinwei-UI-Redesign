# Listen latency and transport feedback — Phase 2

2026-10-21 · branch `codex/ios-capture-ci` · uncommitted

## Implemented behavior

- The receiver uses an 80 ms minimum on `tailscale-websocket` and 120 ms on the public route. Existing underrun learning remains: +50 ms up to 400 ms, then -25 ms after 30 stable seconds. Route changes preserve the learned penalty and use the actual selected transport.
- Sender pacing uses media duration, a 20 ms initial allowance and normally a 40 ms credit cap. It holds at most one already-read packet, retains the existing single tap reader and 64-packet acknowledgement window, and tolerates Windows timer coalescing. Low sample rates can raise the allowance to one packet, bounded to 64 ms. A 2% credit surplus allows bounded backlog recovery.
- Default receiver catch-up only removes up to 1% of a decoded packet whose entire stereo peak is below -100 dBFS, after persistent excess buffering. It leaves nonquiet packets intact. **Continuous music is not guaranteed to converge to the target with this conservative default.**
- A pitch-preserving 1% catch-up processor is implemented as an experiment, default OFF (`bool.fromEnvironment('YINWEI_LISTEN_CATCH_UP')`). No extra audio unit enters the default graph. A future authorized build can enable it with `--dart-define=YINWEI_LISTEN_CATCH_UP=true`. It starts after sustained excess above target +30 ms and stops at target +15 ms. Its processing latency is exposed in diagnostics. Audible quality, CPU use and net latency benefit require an iPad A/B test before enabling it generally.
- Pause/next/previous with a valid control lease request a six-step, 30 ms local Listen gain fade. User volume remains independent. Refusal, control loss, migration, a newer command and a 900 ms watchdog restore gain. Successful commands restore after a bounded 120–500 ms buffer allowance. This allowance is a heuristic, not proof that the new track has arrived. Bluetooth delays the audible fade too; this does not remove Bluetooth latency.
- Planned local silence does not increase the learned underrun target. Capture/source behavior, engine, HRTF, codec and native library are unchanged. Optional 10 ms Opus frames remain deferred.

## Diagnostics and limits

Copy audio diagnostics includes a bounded history of 32 command timing records, receiver route minimum, gain, trim count, catch-up rate and processor latency. It records the page's monotonic tap stamp, request timing, host queue/apply timing, snapshot return and the next received packet after the snapshot. JS and Dart clocks are separate: cross-clock tap latency remains null. Actual first changed/audible audio remains explicitly unavailable; the next packet is not labelled as changed audio.

Host media-helper timings distinguish cold/warm startup and helper acknowledgement. A helper acknowledgement does not prove that 汽水 has reacted or that changed audio is audible. No transport keys were sent to the running app during verification. The earlier read-only helper startup samples (roughly 866–884 ms cold) are not measurements of actual key dispatch or 汽水 reaction.

Expected rather than measured gains: the route minimum decreases by 40 ms; reduced sender bursts should avoid excess startup/catch-up queuing. Existing 170–190 ms queues may still persist during continuous music with default silence-only catch-up. The experimental processor must demonstrate that its own latency does not cancel its benefit. No on-device latency reduction is claimed here.

## Files changed for this task

Paths below are relative to `yinwei/apps/yinwei_player/`.

| Area | Files |
| --- | --- |
| Receiver | `ios/Runner/YinweiListenBuffer.swift`, Listen return-player sections of `ios/Runner/YinweiReplayKitProbe.swift`, `lib/platform/ios_laptop_listen_output.dart` |
| Pacing | new `lib/remote/listen_sender_pacer.dart`, `lib/remote/remote_gateway.dart` |
| Feedback and timings | `lib/remote/laptop_listen_controller.dart`, `lib/remote/listen_room_bridge.dart`, `assets/listen_room/ui.js`, `lib/remote/remote_media_keys.dart`, `lib/state/app_session_coordinator.dart`, callback wiring in `lib/screens/player_screen.dart` |
| Tests | new `test/remote/listen_sender_pacer_test.dart`; `test/native_listen/main.swift`; `test/platform/ios_laptop_listen_output_test.dart`; `test/remote/app_session_coordinator_test.dart`; `test/remote/laptop_listen_controller_test.dart`; `test/remote/private_route_test.dart`; `test/remote/remote_media_keys_test.dart` |

The preceding audio-route recovery fix remains in the working tree separately (`lib/bridge/app_audio_route.dart`, `test/audio_route_recovery_test.dart`, and small controller/player changes). Existing unrelated website and other untracked files were left alone.

## Verification

- Full `flutter test --no-pub --reporter expanded`: **883 passed, 6 skipped**. An intermediate run found an outdated Swift source-contract assertion, which was updated, and a transient unrelated Soda cache temp-directory cleanup lock; the final complete rerun passed.
- `node --test test/listen_room/*.mjs test/remote/*.mjs`: **43 passed, 0 failed** across `bridge_test.mjs`, `music_test.mjs`, `offline_contract_test.mjs`, `room_math_test.mjs`, `speakers_test.mjs`, `audio_browser_test.mjs`, `capture_probe_browser_test.mjs`, `signin_browser_test.mjs`.
- Dart analysis: **0 errors, 6 existing warnings, 111 existing informational lints** (nonzero analyzer exit from existing warnings).
- Review generated with `python yinwei/tools/listen_room_review.py .tmp/listen-latency-review.html`. Isolated browser check: three transport interactions, exactly one intent each, valid tap timestamps, **0 console errors**. Portrait and landscape images were visually inspected. Native audio was not exercised by this page.
- Added tests cover pacing under coalesced timers/stalls/low sample rate; mute-before-ack and refusal recovery; timeout without retry; late acknowledgement after a new play; lease rejection and takeover; bounded diagnostic history; private/public migration and single output ownership. Swift policy tests add route floors, preserved penalty, catch-up hysteresis/convergence, silence eligibility and planned-pause learning.
- Swift policy tests and AVAudioEngine compilation were **not run**: this Windows host has no Swift/Xcode toolchain. Flutter tests include source contracts, which cannot replace an iOS build.
- No Windows/IPA build was run under the user's no-build instruction. No commit, push, publish, bundle switch or backend restart occurred.
- `git diff --check` passed; no `yinwei/crates` diff and no staged files. The pre-existing dirty runner DLL was not touched or staged; SHA-256 remains `0d150deff17c3599c92244775b56c119a120604afed1297e150e2f0a2236305f`. Deployment and outputs were not modified.

Review artifacts, relative to repository root:

- [Portrait](../../.tmp/listen-latency-portrait.png)
- [Landscape](../../.tmp/listen-latency-landscape.png)
- [Browser result](../../.tmp/listen-latency-review-result.json)
- Full test and analysis logs: `.tmp/listen-latency-full-flutter.log`, `.tmp/listen-latency-node.log`, `.tmp/listen-latency-analysis.log`.

## Remaining acceptance checks

1. On macOS, compile the iOS target and execute the Swift policy test harness.
2. On the iPad, compare wired/device output and Bluetooth over Tailscale and Cloudflare. Track target/queued ms, underruns, route migration and long-run jitter; verify fallback and switchback do not create a second reader.
3. A/B the experimental processor on continuous music, quiet passages, transients and spatial stereo. Record actual output latency, pitch/transient quality, CPU and battery. Leave it off if it adds more latency or audible artifacts than it removes.
4. Test pause/next/previous with refusal, lease takeover, rapid taps and a stalled host; confirm gain always returns without altering the user's volume. Old buffered audio can briefly resume if 汽水 reacts later than the bounded feedback window.
5. Measure cold/warm media-key dispatch and 汽水's actual reaction under supervision, without confusing helper acknowledgement, next network packet and changed audible audio.

Rollback is limited to the listed latency changes; preserve the independently approved audio-route recovery fix and unrelated working-tree changes. Nothing has been installed into the running laptop or iPad.
