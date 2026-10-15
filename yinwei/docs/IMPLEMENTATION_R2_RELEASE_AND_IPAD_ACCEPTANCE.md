# Yinwei — R2 release preparation and actual-iPad acceptance

Date: 2026-10-15

**Priority change:** The owner's latest direction is [laptop-origin audio with browser-only listening](IMPLEMENTATION_LAPTOP_WEB_LISTENING.md). Native capture/uplink acceptance below is deferred, not passed. Its pending signing/device gates no longer prevent planning or approving the browser/PWA downlink route. Existing R2 code and release records remain preserved.

Status: **R2 code is committed and published. The new IPA and matching Windows release are built and verified; the matched backend is active and the fixed link is online. Signing validation and real-iPad round-trip acceptance remain unfinished.** See [release record](R2_RELEASE_RECORD_2026-10-15.md) for artifacts and verification limits.

This is the next section of [IMPLEMENTATION_IPAD_REMOTE_LIVE_TRANSFORM.md](IMPLEMENTATION_IPAD_REMOTE_LIVE_TRANSFORM.md). Finish the approved R2 implementation and release gate before starting R3 fixed-origin PWA work or R4 remote spatial controls.

## Outcome

Deliver a matched laptop backend and unsigned IPA that the owner can sign, install and test. The intended route is:

`iPad Music app → ReplayKit → memory-only native IPC → authenticated WSS → laptop LiveIngress / existing HRTF and DSP once → YNW1 stereo → native iPad output`

The iPad performs capture, format conversion, networking and output. It applies no second spatial processor. Initial acceptance keeps Yinwei visible beside the source app. Background operation is not an accepted capability yet.

## Verified starting point

| Item | Recorded evidence | Remaining limit |
|---|---|---|
| Native capture probe | Owner's actual iPad delivered non-silent 44.1 kHz stereo Music-app buffers | Does not prove the full network/DSP/output loop |
| Native return tone | Owner heard the generated test tone normally | Does not establish exclusion from capture or clean dry-source routing |
| R1 transport | Public HTTPS/WSS, generated PCM, exact sample round trip, fresh reconnect epoch | Synthetic transport evidence only |
| R2 Rust ingress | 84 Rust tests passed; Original/Spatial parity against one existing processor invocation | No physical iPad output acceptance |
| R2 Flutter | Last recorded complete run: 548 passed, 4 skipped | Source/test refinements followed; rerun release checks |
| Actual Rust over public relay | 46 returned packets; exact Original samples, finite non-silent Spatial output, fresh epoch | Generated input, not real Music-app listening |
| iOS compilation | New Swift capture/output code is written | Not compiled by the macOS/iOS build yet |
| Release artifacts | Earlier capture-probe IPA exists; R1 is committed as `688bbee` | R2 changes are uncommitted; no updated R2 IPA has been delivered |

These are prior verification results, not a new test run performed for this document.

### Approved release work — 2026-10-15

The owner approved this section. Release review repaired cancellation during IPC bind/output preparation, guarded stale capture callbacks, stopped unsupported background listening, and made native output interruptions fail closed. The new listening screen distinguishes capture connected/waiting for return from received output.

Verification: 84 Windows Rust tests; 550 Windows Flutter passes with four explicit skips; separate landscape/enlarged-text/suspension and packaged-runtime checks passed. CI run `38676072534` built the IPA successfully with 69 macOS Rust passes and 549 Flutter passes/six skips. The actual release DLL passed native FFI and temporary public-relay checks (64 generated-audio packets). The packaged player passed fixture authentication, native output, stop/start, fresh epoch and console-error checks (24 packets). Archive inspection confirmed both required arm64 bundles and App Group entitlements. The matched backend was activated only after confirming no player was running: fixed bookmark online, native engine ready, public sign-in/health HTTP 200, unauthenticated session/transform HTTP 401, zero detected unhandled Flutter errors. Existing audio was not interrupted; signing compatibility and actual-iPad round-trip acceptance remain pending.

## Constraints

- Preserve Windows file playback, Windows Live Transfer, existing HRTF/DSP order, EQ, reverb, array behavior and the established spatial state/coordinate authority.
- Keep Yinwei services, ports, accounts and Cloudflare resources separate from Class Interpreter and BAI. This section needs no R3 Worker migration.
- Never print or copy passwords, session/tunnel tokens, SSH private keys or account databases into reports, source commits or release artifacts. Use ephemeral fixture credentials for automated network tests.
- Build into a separate staging directory. Do not overwrite a loaded DLL or replace the active bundle.
- Ask before interrupting active playback, changing its routing/source or restarting the player. Windows startup remains disabled unless separately authorized.
- Keep the previous matched player/DLL package available for rollback. Do not reset or clean the existing dirty working tree.

## R2-A — finish the implementation review

Inspect the complete R2 diff and dependencies before packaging. Preserve unrelated website, binary and deployment changes.

| Area | Principal files |
|---|---|
| Existing DSP ingress and wet tap | `crates/spatial_core/src/live_ingress.rs`, `live_dsp.rs`, `output_tap.rs` |
| Separate remote ownership and ABI | `crates/spatial_core/src/remote_ingress.rs`, `ffi.rs`, `session.rs`, `lib.rs` |
| Laptop adapter and source coordination | `apps/yinwei_player/lib/remote/native_remote_transform.dart`, `remote_gateway.dart`, `remote_transform_socket.dart`, `state/app_session_coordinator.dart`, `screens/player_screen.dart` |
| Native capture and conversion | `apps/yinwei_player/ios/YinweiBroadcastUpload/SampleHandler.swift` |
| Native returned-audio output | `apps/yinwei_player/ios/Runner/YinweiReplayKitProbe.swift` |
| iPad IPC, authentication and screen | `apps/yinwei_player/lib/platform/ios_remote_live_session.dart`, `mobile/ios_remote_live_screen.dart`, `mobile/ios_replaykit_audio_probe_panel.dart` |

Verify the following behavior, repairing only demonstrated defects:

1. Capture callback retains at most eight bounded sample buffers and never waits for DSP or network I/O. Video and microphone never enter the PCM path.
2. AVAudioConverter emits stereo 48 kHz PCM16. IPC parsing handles fragmented and coalesced messages without an expanding media queue; partial writes, format changes and timestamp gaps cannot corrupt framing.
3. Native client uses the existing owner login, exact HTTPS/WSS origin, CSRF protection and purpose-bound one-use tickets. Keep credentials in host memory; never put grants in the App Group.
4. Laptop input drops complete newest chunks on a full/contended remote queue. Rebatch 480 input frames into the existing 512-frame DSP chunks and process once.
5. Discontinuities clear old partial input, filter history and pending wet output. Ordered reset events clear iPad output. Reconnect and source/configuration changes cannot replay an old session.
6. Fresh network epochs are required after stop/reconnect. Document how internal discontinuity generations and output reset events relate to network epochs; reconcile the master plan with the verified implementation.
7. File playback or Windows Live Transfer prevents remote startup. A later local source/configuration change ends only the remote session. Existing source and spatial controls retain their original authority.
8. Returned audio uses a bounded native queue and no second HRTF/DSP. Verify prefill, underrun recovery, interruption handling and release of the output session.
9. Stop/dispose/sign-in cancellation during asynchronous IPC setup or WebSocket handshake cannot leave an output engine, socket, endpoint or session running. Old callbacks cannot close a newer session.
10. The listening screen reports waiting, connected, stopped, unavailable signing capability and disconnected states accurately. It must not claim audible playback merely because capture counters increase.

Gate: reviewed diff plus meaningful tests for any repaired defects; no unresolved lifecycle or stale-audio issue before release preparation.

## R2-B — compile and verify the native iOS build

1. Run current Rust and Flutter regression tests and targeted analysis. Keep existing unrelated lint findings separate from new findings; do not claim a clean whole-project analysis without evidence.
2. Check the new Live Listening screen in portrait and landscape, with scrolling/keyboard and enlarged text. Preserve the existing spatial workspace. Label synthetic UI renders separately from actual-device screenshots.
3. Commit only the intended source, tests, visual baselines and documentation. Exclude account files, private deployment state, local logs and unrelated modified binaries.
4. Verify the existing Yinwei build branch and publish the approved code using a normal fast-forward push. Use `.github/workflows/ios-unsigned-ipa.yml` on the existing Yinwei repository; do not reuse another project's CI or signing secrets.
5. Compile Runner and Broadcast Upload Extension against the configured iOS SDK. Inspect Swift compile/link errors and fix them incrementally. Confirm extension-safe API usage and the existing native engine symbols remain linked.
6. Confirm both bundles are packaged, their identifiers/parent-child relationship are valid, and the extension principal class and App Group entitlements are present. A successful unsigned build is not proof of device provisioning.
7. Produce a versioned unsigned IPA with commit/build identifiers, SHA-256 and build-info file. Verify the archive contents before sharing it. Label it clearly as requiring owner signing.

Gate: successful macOS/iOS CI compilation and a verified new R2 IPA. Do not present an older N0 probe IPA as this release.

## R2-C — signing compatibility gate

The current implementation intentionally requires `group.dev.yinwei.remote.capture` for live PCM IPC in both Runner and the Broadcast Upload Extension. The earlier signer-managed fallback supports numeric telemetry only.

1. Give the owner the new unsigned IPA and a short signing checklist. No Apple password, certificate private key or signing-service account is requested in chat.
2. Require a valid provisioning route authorizing the dedicated App Group for both bundles. Merely editing an entitlement string cannot grant a capability absent from the signing profile.
3. Inspect the resulting signed artifact's required capabilities without dumping profiles, certificates, device lists or credentials. Report only the relevant compatibility results and public bundle/group identifiers.
4. If the signer replaces/removes the required group, show the existing clear provisioning message and keep live PCM disabled. Never silently relax group isolation, write media to shared files, or store credentials in a shared signer namespace.
5. If the owner's signing route cannot supply the capability, record this as a deployment blocker and review an alternative authenticated, memory-only handoff before implementing it. Do not promise that repeated re-signing or reinstalling will fix it.

Gate: installed host and extension can open the same authorized live IPC container. Numeric probe success alone cannot satisfy this gate.

## R2-D — package the matching laptop backend

1. Build a new Windows player and native library from the same reviewed revision. Verify the added remote ingress ABI and existing file/live tap ABIs.
2. Put the executable, DLL, Flutter assets/plugins and build information in an isolated versioned bundle. Retain hashes and the existing rollback bundle; do not bundle or copy the owner's account database.
3. Run generated-input integration against this actual package/library: Original fidelity, finite non-silent Spatial output, bounds, revocation, idle timeout, slow peers, source conflicts, disconnect and fresh reconnect.
4. Reuse the existing Yinwei-only backend launcher, ports and connector recovery configuration. Do not create a second production host or competing supervisor.
5. Check playback state before activation. Obtain the owner's approval if switching bundles would interrupt active audio. Keep startup disabled.
6. After an approved switch, verify owner authentication, transform availability while idle, refusal during a conflicting local source, and the fixed bookmark's online/offline reporting.

Gate: a matched verified backend package is ready for, or has completed, an approved switch. Distinguish staging from deployment in the release note.

## R2-E — actual-iPad acceptance

No owner testing is needed until the new IPA is built, signed and installed and the matching backend is ready. Then these device checks form the final acceptance step; automated passes do not replace them.

| Check | Required observation |
|---|---|
| Native capture | Intended Music app supplies non-silent stereo input; video/microphone remain excluded |
| Return exclusion | With Music paused, the generated return-tone test does not appear as non-silent captured app audio |
| Dry-source routing | Intended headphones/output route avoids original dry audio playing together with the delayed processed return |
| Real round trip | Actual Music-app audio reaches the laptop DSP and returned audio is heard on iPad |
| Spatial processing | Set Original/Spatial and positions on the laptop for this phase; verify the expected audible change without an iPad spatial processor |
| Source changes | Track/source changes and source pause/resume do not replay old samples or strand output |
| Stop/start | Explicit Stop ends the transform connection/output; deliberate Start establishes a fresh session and resumes correctly |
| Recovery | Connector/network interruption stops output and shows disconnection; reconnect uses fresh authorization and does not silently restart capture |
| Lifecycle | Leaving the listening screen cleans up; unsupported suspension/interruption reports an interrupted state rather than claiming continued playback |
| Coexistence | Existing Windows/file playback and Windows Live Transfer still work after remote teardown |
| Sustained use | At least 30 minutes on the intended arrangement; record audible glitches, drop/underrun counters, latency observations and thermal/battery behavior |

Stop the live route if return audio is recaptured or the dry path cannot be isolated. Do not pass this gate by increasing buffer sizes, changing labels, checking a UI confirmation box or assuming all Music apps behave alike. Revisit routing feasibility before further feature work.

## Deliverables and completion rule

- New unsigned IPA, SHA-256 and build/commit information.
- Matched Windows backend bundle, hashes and rollback instructions.
- Short signing/install/run instructions using the existing fixed Yinwei entry link.
- A release record separating automated checks, successful builds, deployment state, signing compatibility and actual-device results. Mark every unperformed check as pending.

Call R2 complete only after the signed app and matched backend pass actual-iPad audio/routing/recovery acceptance. R3 fixed-origin PWA hosting and R4 protected remote spatial controls follow as separate implementation sections.
