# Yinwei — laptop engine, browser control and stereo listening

Date: 2026-10-15

Status: **Approved 2026-10-15. W0 baseline and W1 initial fixes are implemented, tested and activated after owner-approved restart. Actual iPad acceptance is pending; W2–W5 are not complete.** See [the W1 verification record](W1_WEB_LISTENING_RECORD_2026-10-15.md).

This becomes the proposed active direction following the owner's request: all source audio and processing stay on the laptop; the iPad is a browser client. The native iPad capture/uplink and standalone-engine tracks are deferred, with their existing code and verification records preserved. Their signing and capture gates are not dependencies of this browser-listening route.

Reference: `D:\class-interpret\LAPTOP_BACKEND_MOBILE_REUSE_GUIDE.md`. Reuse its laptop ownership, protected gateway, fixed discovery link, isolation and recovery principles. Do not reuse its credentials/resources or introduce its Python/model stack into Yinwei.

## 1. Intended experience

1. Run the existing Yinwei backend launcher on the Windows laptop. Keep it awake and connected.
2. Play a file in Yinwei **or** play sound in a supported Windows app and start Yinwei's existing Live Transfer on the laptop. Live Transfer requires no file import.
3. On iPad, open the fixed Yinwei HTTPS bookmark in Safari and sign in with the existing Yinwei account.
4. See the real laptop source, playback state and interactive spatial workspace. Tap **Listen** to hear the laptop's processed stereo.
5. Use iPad volume and its selected output: built-in speakers, connected headphones or connected speakers. Changing browser volume/ending browser listening does not change laptop volume, stop its engine or change its routing.
6. File control reuses the existing protected control lease. Start with laptop-side Live Transfer source/start/stop controls; enable protected remote Live controls only after live browser listening passes acceptance.

No IPA, Apple signing, ReplayKit, screen sharing, iPad Music-app capture, microphone permission or browser-side HRTF is needed for this route. “Visitor” means an authenticated browser client, not anonymous public access. Additional accounts/public sharing are outside this plan.

## 2. Architecture

```text
LAPTOP SOURCES                         EXISTING LAPTOP ENGINE
Yinwei file playback ----------------> file playback / HRTF / DSP
Supported Windows source app --------> WASAPI Live Transfer / HRTF / DSP
                                                |
                                  final processed stereo PCM
                                         /              \
                             existing local output     bounded copy tap
                             and routing preserved           |
                                                     protected gateway
                                                            |
                                            authenticated HTTPS / WSS
                                                            |
                                            Safari browser / optional PWA
                                              stereo buffer + output
                                                            |
                                             iPadOS-selected audio route
                                      speakers / wired / USB-C / Bluetooth

Browser controls -> gateway -> existing coordinator/spatial state -> engine
Browser 3D view  <- authoritative state/telemetry <- existing engine session
```

Only the selected file or Live source supplies the audio stream. Read rendered PCM after existing processing; do not capture the laptop's physical speaker output, loop the processed sound through DSP again or drain its local output queue. This preserves output even when laptop hardware changes and avoids a feedback loop.

The browser performs framing validation, bounded buffering, necessary sample-rate conversion, volume and output. No second HRTF, EQ, reverb, speaker simulation or independently authoritative spatial state is added. Preserve the existing renderer/engine coordinate conversion; audit it before changing any spatial command adapter rather than guessing new axes.

Cloudflare carries/discovers the connection; it does not render audio. The laptop remains necessary, including when the PWA shell can open offline.

The web frontend reuses the real interactive Three.js workspace: room/stage, eight physical speaker geometries, listener/source, camera and inspector/playback controls where the current renderer supports them. Extend missing interactions incrementally through the same spatial state and command authority. Do not replace the scene with a static image, invent a browser-owned spatial model or change audio code for visual reasons. Live/source/buffering status must remain visible alongside the workspace.

## 3. What already exists and what remains

These are source observations on 2026-10-15, not renewed real-iPad acceptance.

| Area | Reuse | Remaining work / limit |
|---|---|---|
| File output | `spatial_core` file output tap; `NativeOutputTap`; `RemoteGateway` | Revalidate the exact active DLL/player combination. File-array browser listening is currently disabled; do not advertise support or silently substitute dry audio. |
| Windows live output | Existing Live Transfer DSP and optional live wet tap | Revalidate actual Windows source audio reaching Safari, including local stop/start and source changes. |
| Browser stereo | `assets/remote/audio-client.js` and `audio-worklet.js` | Real Safari output-route, resampling, interruption and reconnect acceptance. |
| UI/state | `assets/remote/app.*`, `workspace.js`, existing Three.js scene and `AppSessionCoordinator` | Make source and listening status unambiguous. Existing file controls work through a lease; current Live controls remain on laptop. |
| Security | Owner login, CSRF, one-use purpose-bound WSS tickets, session revocation | Preserve and regression-test; no anonymous audio endpoint. |
| Discovery/recovery | Yinwei-only fixed Worker bookmark, checker and connector | Check current health/recovery. It redirects to a temporary origin and is not yet a stable PWA application origin. |
| Native iPad R2 | Separate capture/uplink/return path exists | Deferred. Do not remove/rewrite it or allow it to contend with this laptop-source route. |

Principal files: `crates/spatial_core/src/output_tap.rs`, `live_transfer.rs`, `live_dsp.rs`, `playback.rs`, `session.rs`; `apps/yinwei_player/lib/remote/{native_output_tap,remote_gateway,remote_auth,remote_deployment}.dart`; `lib/state/app_session_coordinator.dart`; `assets/remote/{app.js,app.html,audio-client.js,audio-worklet.js,workspace.js}`; existing `tools/remote/` launcher/connector/checker.

Existing records include successful generated-audio transport/native tests and earlier owner-confirmed browser file listening. They do not prove the new complete device/output matrix, sustained Windows-live listening or every recovery condition. Start by checking the existing route, not rebuilding the engine.

## 4. Output compatibility contract

“Any device” means a compatible output that the receiving device's OS/browser can actually use. The release must play ordinary two-channel audio and must not depend on a headphone-only output path. It cannot guarantee an unsupported accessory, identical spatial perception on every output, eight discrete hardware channels or simultaneous synchronization of laptop/iPad/speakers.

| Output | Planned behavior | Required acceptance |
|---|---|---|
| iPad built-in speakers | Render the received stereo through the OS default route | Audible file and Windows-live output, correct volume, no headphones required. |
| Wired headphones / USB-C adapter or DAC | Use the connected OS route, retain left/right stereo when supported | Actual available adapter/headphones; connect/disconnect and restart listening without stale audio. |
| Bluetooth headphones / AirPods | Standard OS-routed stereo playback | Actual accessory, route switch, reconnection, channel check and additional latency observation. No microphone capture. |
| Bluetooth speaker / wired external speaker | Same received stereo using the selected OS route | Actual speaker, speaker/headphone switching and no laptop routing changes. Mono hardware may downmix. |
| AirPlay / HDMI / dock / specialist interfaces | Capability to investigate separately | Do not claim support merely because Safari/another media app supports the route. Validate this Web Audio path on the actual setup; otherwise clearly mark unverified. |
| Other receiving browsers/devices | Same HTTPS client and stereo protocol where required APIs exist | Safari first; then smoke-test available phone/desktop browsers. Unsupported browsers show a capability message. |

Use system output selection as the baseline. Do not require browser `setSinkId()`, enumerate inaccessible device names, promise a web device picker everywhere or claim a known route when the browser cannot report it. Provide a short “Choose output in Control Center” instruction; optional platform device-selection APIs must be feature-detected.

Original and Spatial remain laptop processing modes. HRTF binaural output is intended for headphone listening; it is still stereo that speakers can play, but equivalent speaker spatial localization is not promised. Users can choose the existing Original mode for conventional stereo. No automatic mode change or new speaker-compensation DSP is introduced when an accessory changes. Device/OS post-processing and mono settings may affect the sound; the app must not claim bit-identical acoustic output.

Apple documents iPad Bluetooth output through headphones/speakers in its [iPad guide](https://support.apple.com/en-il/guide/ipad/ipad913af4df/ipados). Web Audio delivers rendered audio to its [audio destination](https://www.w3.org/TR/webaudio-1.0/#AudioDestinationNode); this does not guarantee every physical route. Route availability and reliable recovery are actual-device gates.

## 5. Transport, buffering and lifecycle

- Reuse authenticated `YNW1` stereo downlink over WSS. Preserve sample rate, mode, source epoch and sequence metadata. Both channels must reach the output; verify asymmetric left/right fixture signals.
- Start with the existing PCM implementation. At 48 kHz stereo float32, 512-frame packets plus the 56-byte header are about **3.11 Mbit/s before WebSocket/TLS overhead**. Measure actual throughput/latency; do not silently introduce lossy encoding or promise Bluetooth/network latency.
- Existing native tap capacity is eight chunks with nonblocking publication. Existing browser behavior uses roughly 80 ms prefill and a 500 ms queued-input ceiling. These are code settings, not measured total latency. Include all gateway/relay/browser queues in the latency/backpressure review.
- A slow/disconnected listener drops/resynchronizes or stops its stream; it never blocks DSP, grows an unbounded queue or pauses the laptop. Preserve existing tap policies unless evidence justifies a targeted change.
- Pause, seek, source switch, Live stop, sign-out and reconnect flush old queued audio. A fresh authorized stream cannot replay audio from a previous source/session.
- User taps Listen to start/resume output. After network or audio interruption, show the correct state and require an explicit gesture when Safari needs it. A connected WebSocket alone must not produce an “audible” success claim.
- Foreground Safari listening is the first acceptance target. Test tab changes, screen lock and Home Screen mode separately. Background/lock-screen continuity is not promised without a passed device test. WebKit has documented AudioContext suspension cases ([issue record](https://bugs.webkit.org/show_bug.cgi?id=261554)); this motivates testing, not a claim that a historical bug affects this iPad.
- Initially retain one active browser audio listener, matching the gateway's current ownership limit. Other devices can be supported sequentially; this is not a multi-listener broadcast commitment. A second listener sees busy rather than disconnecting the first. Audit total control/audio/viewer socket limits together.

## 6. Implementation phases and gates

| Phase | Work | Gate |
|---|---|---|
| W0 — baseline | Inspect current package, file/live capabilities, gateway/relay, fixed entry, browser APIs and existing tests. Record exact revisions and present playback/routing state. | Clear reuse map and defect list; no active playback interrupted. This document supplies the initial source review; live runtime checks follow approval. |
| W1 — browser listening first | Repair demonstrated authenticated WSS/audio defects. Make the page clearly say file, Live starting, Live ready, buffering, suspended, source changed or laptop offline. Reuse the final processed taps and Stereo AudioWorklet. Show output guidance. | Automated protocol/output/lifecycle tests plus actual iPad speakers and one available headphone route for a file and a live Windows source. No IPA dependency. |
| W2 — source and controls | Revalidate existing protected file transport/spatial controls and local priority. Start Live Transfer on laptop initially. After W1 real live hearing passes, add only needed protected remote Live start/stop/source/position controls through the existing authority, with source-conflict and routing guards. | Real track/source switches, Original/Spatial, source changes, stop/start and lease revocation; no change to the protected engine/routing contract. |
| W3 — stable web/PWA entry | Establish one Yinwei-owned, stable application origin for UI/login/API/WSS; then add manifest/icons/Home Screen support and controlled shell caching. Reuse the current separate account and resources. Validate allowlisted proxy paths, current-origin leases, WSS framing/backpressure and available Cloudflare limits before deployment. | Installed PWA survives tunnel rotation at the same origin; private APIs/audio/credentials never enter caches. App clearly reports offline laptop. |
| W4 — output/recovery hardening | Complete available wired/USB/Bluetooth speaker/headphone switches; pause/resume, network loss, connector recovery, sign-out and 30-minute use. Investigate background/AirPlay only as separate capability gates. | Device matrix records passed, failed, unavailable and untested separately. Existing laptop playback/routing still passes after browser teardown. |
| W5 — release/handoff | Build matched backend if source changed, stage with hashes and rollback, activate while idle or after approved interruption. Deliver one working web link and short instructions. | Build/test/runtime/console evidence plus actual iPad acceptance; no unsupported output or PWA claim. |

W1 can use the existing fixed bookmark and temporary application origin. Do not delay initial audible Safari acceptance for a PWA migration. W3 is required before calling the result a durable installed PWA: the current redirecting launcher alone cannot preserve one application origin across tunnel rotation. Keep the present launcher usable during migration; do not repurpose Class Interpreter or BAI resources.

Do not introduce a new codec, WebRTC stack, public account system, browser-only laptop mute/routing feature or second engine as a routine implementation choice. If PCM bandwidth or browser lifecycle fails a gate, document the measured blocker and propose a separate reviewed change. File-array downlink is an explicit later gate; preserve desktop array playback and clearly show its current browser limitation.

## 7. Verification and release acceptance

Automated: native tap copies the same processed samples without consuming local playback; stereo fidelity and one-DSP behavior; file/live capability selection; auth/tickets/CSRF/revocation; actual public relay message/credit/backlog behavior; source epochs/flushing; browser volume isolation; unsupported API handling; UI portrait/landscape/touch; build and runtime/console checks. Reuse existing tests and add tests for demonstrated changes rather than reproducing implementation details.

Actual device results, initially **pending**:

| Test | Pass observation |
|---|---|
| Entry/login | Fixed link reaches the real laptop; correct online/offline display; owner signs in. |
| File | iPad speakers and an available headphone route hear the laptop's file output; channel-specific fixture is correct. |
| Live without imports | A supported Windows music/source app is heard after laptop Live Transfer; no iPad capture. |
| Processing | Original/Spatial and position changes follow laptop authority; browser applies no spatial processor. |
| Outputs | Available built-in/wired/USB/Bluetooth routes work; disconnect/switch either continues correctly or stops visibly and resumes explicitly. |
| Local preservation | Ending browser audio, signing out or losing network leaves laptop playback, live capture, HRTF and routing intact. |
| Recovery | Network/tunnel/source stop/start clears old PCM and reconnects with fresh authorization; no immediate WSS disconnect. |
| PWA | After W3 only: Home Screen launch, origin rotation, update and offline behavior tested independently of Safari. |
| Sustained | 30 minutes on the intended network/output; record audible glitches, buffering/drops, latency observations and interruptions. |

Record iPad/browser/OS versions, source app, output accessory, network and measured outcomes during acceptance. A generated-PCM test, screenshot, nonzero energy counter or successful HTTP/WSS handshake does not prove actual listening. Unavailable accessories stay untested, not silently passed.

## 8. Protection, deployment and rollback

Keep current audio engine, HRIR data, DSP order, array authority, coordinate projection, local playback and Windows routing protected. Keep Yinwei ports, accounts, Cloudflare Workers/storage, supervisor identities and state isolated from Class Interpreter/BAI. Never print/copy personal passwords, session/tunnel tokens, SSH keys or account databases.

Use the existing `Start-Yinwei-Backend.bat` and verified deployment configuration. No duplicate production host/supervisor. Ask before interrupting active playback or changing its source/routing; Windows startup remains disabled without separate approval. Planning this route does not itself stop an active native/uplink session.

Retain previous matched executable/DLL/assets and public hash metadata. On regression, disable only the new browser feature or restore the previous matched bundle through the existing launcher after any required playback approval. Preserve owner accounts and existing Cloudflare metadata. Do not delete the deferred native iPad code or globally reset the working tree.

Completion means a usable authenticated web link, preserved laptop engine/playback and proven laptop-source audio on the actual iPad's tested outputs. Further device routes and background/AirPlay behavior are claimed only after their own acceptance. Next implementation scope after approval: **W0 runtime baseline and W1 browser listening**.
