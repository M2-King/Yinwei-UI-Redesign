# R2 release record — 2026-10-15

Product source revision: `463b88bf2564e726b5384d614fd8dcf4e8c2d110`.

Route implemented: iPad ReplayKit app audio → bounded memory-only IPC → authenticated WSS → existing laptop Rust LiveIngress/HRTF/DSP once → bounded returned stereo → native iPad playback. Microphone/video are excluded. Spatial configuration remains on the laptop for this phase.

## Automated evidence

| Check | Result | Limit |
|---|---|---|
| Windows Rust regression | 84 passed | Automated; no physical listening |
| Full Windows Flutter regression | 550 passed, four explicit skips | Additional UI lifecycle test passed separately; CI covers the committed suite |
| New-source analysis | No issues in targeted analysis | Does not claim the entire repository is lint-free |
| iPad screen layout/interaction | Portrait golden, landscape at 1.6× text, suspension/explicit restart behavior passed | Desktop Flutter tests, not iPad screenshots |
| Setup cancellation | Late IPC bind and output preparation cannot revive a stopped session | Mock native channel plus real fixture sockets |
| Windows release build | Player and native DLL built successfully; matched bundle activated through existing launcher after confirming no player was active | No current audio interrupted; old bundle retained |
| Exact release DLL | Original sample fidelity; finite different Spatial output; busy/configuration refusal passed | Generated PCM and optional FFI integration |
| Packaged Windows player | Owner fixture authentication, 24 non-silent native DSP return packets, stop/start, fresh epoch and no unhandled Flutter console errors passed | Isolated executable with temporary fixture account; no personal account copied |
| Public HTTPS/WSS relay | 64 packets; exact Original, non-silent Spatial, fresh epoch, local playback untouched | Generated audio through separate temporary quick tunnel; not actual iPad or a latency measurement |
| Native iOS build | CI run `38676072534` succeeded; 69 Rust and 549 Flutter tests passed, six Flutter skips | macOS arm64 / Xcode 16.4 / iOS SDK 18.5; no device provisioning |
| IPA structural inspection | ZIP intact; host and broadcast extension are arm64 device binaries, valid related identifiers, correct SampleHandler and dedicated App Group entitlements in both | Temporary ad-hoc signatures; no embedded provisioning profiles; owner signing still required |
| Activated backend | Fixed bookmark online, native engine ready, public health/sign-in HTTP 200, unauthenticated session/transform WebSocket rejected HTTP 401, zero detected unhandled Flutter errors | Personal owner login and actual iPad audio still require the device |

The package smoke test closes only its own player process and deletes its own temporary fixture. The temporary public relay is closed after verification. No Class Interpreter/BAI account, service, port or Cloudflare resource was changed.

## Artifacts and deployment

Windows staging folder: `outputs/r2/463b88b/windows/`.

Unsigned IPA: `outputs/r2/463b88b/Yinwei-R2-unsigned-463b88b.ipa` (10,368,495 bytes), SHA-256 `9238470bb4dd0ebc1f614c5f400075e0c60ae489d65b7cb8089128a24f8aae0e`.

[Download the IPA directly](https://github.com/M2-King/Yinwei-UI-Redesign/releases/download/yinwei-r2-463b88b/Yinwei-R2-unsigned-463b88b.ipa), or open the [release page](https://github.com/M2-King/Yinwei-UI-Redesign/releases/tag/yinwei-r2-463b88b). This replaces the Actions artifact link that showed a 404 in the owner's signed-out Safari. Anonymous download was verified: HTTP 200, 10,368,495 bytes, matching SHA-256. No GitHub login is needed for this release asset. The original CI artifact expires on 2026-10-29; the release asset and local files are separate copies.

Windows ZIP: `outputs/r2/463b88b/Yinwei-R2-Windows-463b88b.zip`. Full file hashes are in `windows-manifest.json`. The IPA build information and bounded public bundle/capability inspection are in `ios/`. A readable desktop test render is included as `live-screen-desktop-test.png`; it is not a real iPad screenshot.

| File | SHA-256 |
|---|---|
| `yinwei_player.exe` | `a6eccf9909d802dd05b1c3285c833952b75c5e65a73c85597e7d58a2ac966e1a` |
| `spatial_core.dll` | `eb764148534b6f0df3d0de60c7b6f184fcbf5164ed7298d53a3de95bb6e8c036` |
| `data/app.so` | `4e4919ac1e19c6d1c8540a19230ef2e6af125770630061b28971a3b37c7558d8` |

These files belong together. The source-tree Windows runner DLL and prior deployment bundle remain untouched. No owner database is included. The private Yinwei deployment configuration now points to this matched release with validated executable/DLL/snapshot hashes. It was activated through the existing launcher after confirming no player was running. The existing Yinwei connector/checker recovered the fixed bookmark; no competing supervisor was added. Ask before any later interruption of active playback. Windows startup stays disabled. See `active-backend-check.json` for bounded deployment evidence.

Rollback: close only the new player after approval if it is playing; restore the previous executable/library/data paths and recorded hashes in Yinwei's private deployment configuration; use the existing Yinwei launcher. Do not reset account data or edit another project's deployment.

## Owner signing/install gate

1. Sign the new R2 IPA, including its Broadcast Upload Extension. Preserve the host/extension identifier relationship and authorize `group.dev.yinwei.remote.capture` for both bundles.
2. Install the signed app. A generic signer-managed App Group supports the old numeric probe only; it cannot enable this live path. If the signer cannot provision the dedicated group, stop here and report that capability error. Reinstalling the same incompatible profile will not resolve it.
3. The matched laptop backend is now running. Keep the laptop awake and online; after a future shutdown, use `Start-Yinwei-Backend.bat`. In the iPad app, choose **Live Transform on laptop** from the Music audio test panel. The fixed bookmark is [Yinwei](https://yinwei-remote-entry-01a12de8.yinwei-01a12de8.workers.dev/).
4. Keep Yinwei visible beside Music. Sign in with the existing Yinwei owner account. Complete the return-recapture, dry-route and capture restart checks before enabling live upload. Only confirm checks actually observed.
5. Tap **Start live transform**, select Yinwei in Apple's sharing picker, and play Music. Set Original/Spatial and positions on the laptop. Use **Stop live transform** to end the connection/output; Apple's broadcast can also be stopped in Control Center.

This first release deliberately stops listening when the app is suspended or its audio output is interrupted. It never silently resumes a stale stream. Background listening is not accepted yet.

Optional local inspection of a re-signed IPA: `python yinwei/tools/verify_r2_ipa.py <signed-ipa-path>`. This reports only relevant public bundle identifiers and capability booleans; it never extracts/prints provisioning profiles, certificates or account identifiers. A positive metadata check does not cryptographically validate the signature or replace installation on the iPad.

## Actual-device acceptance — pending

The owner previously confirmed non-silent Music-app capture and normal generated-tone playback. Those observations do not prove return exclusion, dry-source suppression or the network/DSP/output round trip.

Still required: compatible signing on the actual iPad; clean headphone routing without dry+wet doubling; return tone not recaptured; actual Music processed by laptop and heard on iPad; track changes; explicit stop/start; network disconnect/reconnect; preserved Windows file/live playback; and a 30-minute sustained test. R2 remains open until these pass. R3 PWA hosting and R4 protected remote controls remain deferred.
