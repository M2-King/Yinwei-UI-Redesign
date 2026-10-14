# Yinwei iPad PWA -> laptop -> iPad Live Transform plan

Date: 2026-10-14

Status: **Gate R0 failed on the owner's actual iPad on 2026-10-14. Gate N0 source implementation is ready for a signed macOS build and actual-iPad acceptance.** Safari exposes the screen-share API and returns a screen/video stream, but it supplies no audio track. The pure-PWA iPad-system-audio route is closed on this setup. R1-R4 must not start until the signed native capture-companion gate proves Music-app audio and clean return routing.

## Product outcome

The iPad opens an installable Yinwei PWA and deliberately starts screen/system-audio sharing. The browser sends live PCM to the laptop. The existing Yinwei Rust engine applies its existing HRTF, EQ, reverb, spatial and array processing once. Processed stereo returns to the same PWA and plays through the iPad output.

```text
iPad source application / screen audio
                 |
      iPadOS share picker + PWA capture
                 |
        bounded authenticated PCM WSS uplink
                 |
                 v
       existing laptop Yinwei gateway
                 |
        bounded remote-input adapter
                 |
       existing spatial_core HRTF / DSP
                 |
       optional unchanged laptop monitor
                 |
       bounded authenticated YNW1 downlink
                 |
                 v
      existing iPad AudioWorklet sink
                 |
        iPad speakers / headphones
```

The laptop remains the engine and must be powered on, awake and connected. The PWA performs capture, bounded transport, buffering/resampling and output only. It never applies a second HRTF/EQ/spatial stage.

## Existing Yinwei foundation

Already implemented and reusable:

- separate Yinwei owner login, HttpOnly session, CSRF/Origin enforcement, revocation and one-use WSS tickets;
- loopback-only laptop gateway through Yinwei's isolated Cloudflare connector and fixed Worker entry;
- complete-message HTTPS/WSS relay with bounded browser/native messages and backlogs;
- browser AudioWorklet with bounded queue, 80 ms prefill, resampling, underrun silence and explicit flush;
- YNW1 processed-stereo output from file playback and Windows Live Transfer;
- native `LiveIngress`: bounded nonblocking PCM input, existing `LiveDspProcessor`, spatial parameters, EQ/array state and telemetry;
- native output taps that mirror already-processed PCM without blocking local playback;
- manual `Start-Yinwei-Backend.bat`, private readiness and clear online/offline state.

Missing for this route:

- a proven iPad PWA system-audio capture source;
- a browser capture worklet and uplink packet format;
- an authenticated full-duplex transform socket;
- a laptop gateway adapter into `LiveIngress`;
- a bounded wet-output queue/tap for `LiveIngress` (its worker currently measures and discards wet PCM);
- one source coordinator for Remote iPad / Windows Live Transfer / file playback;
- a stable-origin installable PWA instead of a fixed launcher that redirects to rotating temporary origins.

## Non-negotiable feasibility gate

Do not implement the engine ingress until a tiny capture/routing probe passes on the owner's actual iPad and installed iPadOS.

The probe calls, from a user tap:

```js
navigator.mediaDevices.getDisplayMedia({
  video: true,
  audio: true,
  systemAudio: "include",
  selfBrowserSurface: "exclude",
});
```

It records capabilities and numeric telemetry only: track kinds, settings, sample rate, channels, frames, RMS/peak, discontinuities and lifecycle. It does not record, upload or save media during this gate. Any video track is stopped or ignored after it proves the picker path; Yinwei transmits audio only.

R0 source implementation:

- authenticated `/remote/capture-probe` page linked from the listening room;
- local `AudioWorklet` meter that emits only bounded numeric aggregates;
- local 997/1499 Hz coded-tone heuristic for possible return-audio recapture;
- explicit owner hearing classification for dry-source/return routing;
- strict CSRF-protected report endpoint with an allowlisted schema and a 32-report in-memory cap per signed-in device;
- no microphone fallback, recorder, video consumer, PCM upload, persistent media or Cloudflare change.

R0 automated/deployment record, 2026-10-14:

- 20 focused authenticated-gateway tests passed;
- all browser-script tests passed, including numeric-only worklet output and the recapture classifier;
- 505 Flutter tests passed with one intentional skip;
- targeted analysis of the changed Dart gateway/test files reported no issues; whole-project analysis retained its pre-existing lint backlog and reported no R0-file finding;
- Windows Debug and Release builds passed; deployed browser assets exactly match source hashes;
- the new owner-only `player-r0-bundle` retains the preceding bundle for rollback and keeps the native DSP DLL unchanged;
- private readiness passed with native engine, owner account, file-browser audio and Windows Live Transfer browser audio all ready;
- the fixed Yinwei entry returned online and the anonymous probe route redirected to protected sign-in;
- a synthetic 768x1024 render had no horizontal overflow or console error: [R0 probe screenshot](../../.tmp/r0-probe.png).

Automated evidence alone did not pass Gate R0. The actual-iPad result below closed the gate at audio-track discovery, before energy, lifecycle, feedback or dry-route testing could run.

### Actual-iPad R0 result

The owner's Safari test reached the protected R0 page through the live Yinwei deployment. The browser reported:

- Screen-share API: **Available**;
- picker: **opened and returned a screen**;
- audio track: **Missing**;
- capture level: unavailable because no PCM source existed;
- return-audio feedback test: unavailable because capture had no audio.

Evidence: [actual iPad — screen returned without audio](validation/ipad-r0-no-audio-2026-10-14.jpg).

This fails the second mandatory R0 condition. Browser code, WebSockets, laptop DSP and Cloudflare cannot manufacture the missing system-audio track. Microphone capture remains rejected because it would add room noise, acoustic feedback and dry/processed duplication. A Python environment on iPad is subject to the same operating-system capture restrictions and cannot turn this browser result into system-audio access.

### Proposed N0 — signed native capture companion

This is a replacement input edge, not a standalone Yinwei engine. The laptop remains the only HRTF/DSP processor.

1. Build a minimal Yinwei iPad host app plus a ReplayKit Broadcast Upload Extension. The extension requests the user-controlled system broadcast and inspects only ReplayKit `.audioApp` buffers; microphone and video are disabled or discarded.
2. On the actual iPad, prove the intended source application supplies stable non-silent app-audio buffers while the Yinwei host app remains able to receive and play a generated return signal.
3. Test native ScreenCaptureKit as a second capture adapter only when supported by the installed iPadOS/SDK. Keep it behind the same capture interface and do not assume it can capture the intended third-party app until the device test passes.
4. Measure whether returned Yinwei audio is recaptured and whether the source's dry output can be suppressed. If either creates feedback or dry+wet doubling, stop before networking or DSP integration.
5. Keep all N0 audio in memory. Record numeric format, level, discontinuity and routing telemetry only; no screen frames, recordings or media files.
6. Install a signed build on the owner's iPad. TestFlight is optional: direct Xcode installation or another valid Apple provisioning route can satisfy this gate, but an unsigned IPA/PWA/Python script cannot.

N0 implementation record, 2026-10-14:

- added a dedicated `YinweiBroadcastUpload` ReplayKit Broadcast Upload Extension;
- the extension accepts only `.audioApp` for bounded numeric level/format inspection, ignores `.audioMic`, discards `.video`, and contains no recorder or network path;
- added a shared Yinwei-only App Group for numeric status and a host method channel that opens `RPSystemBroadcastPickerView` without simulating the required user tap;
- added an iPad panel that shows broadcast lifecycle, app-audio buffer count, format and level while retaining the separate iOS 27 ScreenCaptureKit probe;
- added an explicit two-second 997/1499 Hz native return-tone control so the actual-iPad test can expose self-output recapture; it never starts automatically and bypasses the protected spatial engine;
- added resettable numeric status plus an advanced route to retain the iOS 27 ScreenCaptureKit experiment without reducing the spatial workspace;
- 513 Flutter tests passed with one intentional skip, targeted analysis reported no issues, the existing mobile spatial drag/orbit tests passed, the N0 panel golden passed, and the Windows Debug build passed;
- no laptop player restart, startup change, Cloudflare change, Class Interpreter/BAI change, audio upload or media persistence occurred;
- this source implementation does not yet pass Gate N0: the Windows host has no Xcode toolchain or valid Apple signing route, so the ReplayKit extension has not been compiled/signed and the actual-iPad Music-app/routing test remains outstanding.

Apple now deprecates `RPSystemBroadcastPickerView` in favor of ScreenCaptureKit’s picker. Yinwei retains the native iOS 27 ScreenCaptureKit probe behind the panel menu, but the owner’s web ScreenCaptureKit-style experiment supplied no audio. ReplayKit remains an explicit feasibility adapter for this gate and must not be treated as a proven long-term capture path until the signed device test passes.

Actual-iPad N0 acceptance sequence after signing:

Signer-compatibility finding from the first installed N0 build on 2026-10-14:

- the ReplayKit extension installed and Apple started its broadcast, proving the
  extension bundle survived re-signing;
- the host still showed an idle broadcast with zero counters because the
  owner-side signer replaced the product App Group entitlement with its own
  authorized groups;
- N0.1 therefore resolves the preferred Yinwei App Group when authorized and
  otherwise deterministically selects the same signer-authorized group from the
  embedded profiles in both processes;
- this fallback carries numeric telemetry only and adds no media persistence or
  network path;
- the broadcast picker receives a visible blue background and instruction so
  the required Apple-controlled tap target is no longer visually ambiguous.

1. Open Yinwei and tap **Choose Music Audio**. In Apple’s UI, choose **Yinwei Music Audio** and start the broadcast.
2. Switch to the intended Music app and play for at least 15 seconds. Return to Yinwei and require **Receiving App Audio**, increasing app-audio buffers, a valid sample rate/channel count and a non-silent level.
3. Pause Music, reset numeric status from the `…` menu, then tap **Test Return Tone**. If app-audio activity becomes non-silent, Yinwei’s return is being recaptured and Gate N0 fails.
4. Repeat with the intended headphones/output route. Confirm whether the original dry Music signal remains audible beside the test return.
5. Stop Apple’s broadcast, verify **Stopped**, start it again, change tracks/apps and verify capture resumes without stale state.

Automated tests and the Windows build do not count as this actual-iPad acceptance.

Only after N0 passes should the existing R1 transport plan be adapted so the signed capture companion sends bounded raw PCM to the laptop and receives the laptop's once-processed YNW1 audio. The existing Windows file playback and Live Transfer routes remain protected.

Test in normal Safari and the Home Screen PWA with:

1. a locally generated/source test tone;
2. Safari media;
3. the owner's intended music application;
4. source pause/resume and source application changes;
5. PWA foreground, Split View/Stage Manager and source-app foreground;
6. headphones plus any intended speaker/USB/Bluetooth route.

Gate R0 passes only if all conditions hold:

- `getDisplayMedia` exists and opens the iPadOS picker;
- the returned stream contains an audio track, not only video;
- the track produces stable non-silent PCM from the selected source;
- capture and the authenticated socket continue in the required foreground/Split View arrangement;
- the PWA can play a returned test signal while capture continues;
- returned PWA audio is not captured again, so there is no digital feedback loop;
- the source's direct dry audio can be suppressed, leaving only the returned processed audio;
- stop and permission-revocation end capture immediately and visibly.

iPadOS 27 screen sharing is new. Current public device reports establish `getDisplayMedia` and a video track, but not a usable system-audio track. The web specification also allows an implementation to omit audio even when requested. Therefore R0 is evidence gathering, not a claim of support.

If the audio track is missing, silent, background-throttled, recaptures Yinwei output or leaves dry+wet doubling, the pure-PWA route stops. Microphone capture is not an automatic fallback because it degrades music, adds room noise and creates acoustic feedback. The fallback would be the signed native iOS 27 ScreenCaptureKit app, which is outside this PWA approval.

References:

- <https://github.com/mdn/browser-compat-data/issues/30654>
- <https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getDisplayMedia>
- <https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios>

## Phase R1 — protected browser uplink

Starts only after Gate R0 passes.

1. Add a capture `AudioWorklet` that copies PCM into fixed 10 ms chunks. It performs no DSP and never blocks the browser audio callback.
2. Normalize to stereo 48 kHz PCM16 at the browser boundary when required. A 10 ms stereo chunk is 1,920 bytes, leaving room for a small header under the current 2 KiB browser-message limit.
3. Define a versioned `YNI1` binary input frame containing epoch, sequence, source-frame index, sample rate, channels, frame count and flags. Reject malformed sizes, non-finite metadata and stale epochs.
4. Add one-use, purpose-bound transform tickets and `/remote/ws/transform`. The ticket binds owner session, device/session ID and the single current remote-transform lease.
5. Use a full-duplex socket: browser sends YNI1 input and receives existing YNW1 processed output. Control/events remain on the existing event channel.
6. Browser send logic checks `WebSocket.bufferedAmount`; on excess backlog it drops complete newest input chunks and reports overload. It never accumulates unbounded media in JavaScript.
7. The gateway enforces Origin, cookie, ticket, frame schema, rate, bandwidth, idle deadline and one active transform source. Audio remains in memory and is never written to disk.
8. Stop/disconnect/revocation closes input, flushes output and increments the epoch. Reconnection requires a new ticket and a deliberate Start; it never resumes capture automatically.

Gate R1: synthetic PCM crosses the exact public relay, reaches a bounded fake/native input adapter, returns ordered processed packets and handles overload, revocation, rotation and reconnect without replay or unbounded memory.

## Phase R2 — existing laptop engine integration

1. Reuse `LiveIngress` and `LiveDspProcessor`; do not create a Python, Dart or JavaScript DSP engine.
2. Add an epoch-aware input ABI owned by `spatial_core`. Gateway pushes validated PCM with nonblocking `try` semantics. A full/contended input queue drops complete newest chunks so latency does not grow.
3. Add the missing bounded wet-output tap immediately after `LiveDspProcessor::process_chunk`. Reuse the existing eight-chunk `OutputTap` policy and metadata layout where compatible.
4. Preserve exact DSP order, HRTF data, EQ, reverb, Point/array behavior and coordinate projection. The remote UI updates the same existing spatial state used by the engine and renderer.
5. Make source modes mutually exclusive through one coordinator: File, Windows Live Transfer or Remote iPad. Starting Remote iPad never silently stops another active source. Runtime activation that interrupts playback requires owner approval.
6. Default the first accepted remote session to iPad return output. Laptop monitoring remains an explicit option and uses the same wet PCM; it must not create another capture/feedback path.
7. Input discontinuity, source switch, mode switch, stop and reconnect flush both directions and advance one shared epoch. No old iPad audio may return after a transition.
8. Browser disconnect or a slow downlink disables only the remote session. It must not corrupt the engine, routes or later local playback.

Gate R2: native tests prove input/wet-output parity, one DSP invocation, bounded queues, drop/underrun telemetry, epoch flushing, exact Original/Spatial behavior and unchanged Windows/file playback.

## Phase R3 — stable-origin PWA

The current fixed Worker is a launcher that redirects to a rotating `trycloudflare.com` origin. That cannot provide a durable installed PWA scope, cookie jar or service worker after origin rotation.

1. Keep Yinwei resources and account separate from Class Interpreter and BAI.
2. Convert or add a Yinwei-only fixed Worker origin that serves the PWA shell and proxies only the allowlisted gateway HTTP/WSS routes to the current verified Yinwei tunnel origin.
3. The Worker reads fresh validated origin state from Yinwei's existing isolated checker/Durable Object. It fails closed when the lease or probe is stale.
4. Preserve the laptop gateway as authentication authority. The Worker stores no password, session database or audio and performs no DSP. Secure host-only cookies belong to the fixed Worker origin.
5. Proxy only exact methods/routes and complete WebSocket messages with existing size/backlog limits. Block internal readiness, publication and arbitrary destinations.
6. Add manifest, icons and service worker for the UI shell. Audio capture always requires a fresh user action and iPadOS picker permission; the service worker cannot grant or persist it.
7. Show distinct states: laptop offline, sign-in required, source permission required, capturing, transforming, listening, overload, interrupted and disconnected.

This changes the fixed Worker from metadata-only discovery into part of the application/audio data path. Approval of this plan authorizes that Yinwei-only role change, but no Class Interpreter/BAI resources may be reused or modified.

Gate R3: the installed Home Screen PWA retains one fixed origin across tunnel recovery; authenticated HTTP/WSS work; anonymous routes fail closed; stale checker state shows offline; and connector rotation does not require reinstalling the PWA.

## Phase R4 — remote experience and controls

1. One explicit **Start Live Transform** gesture requests capture, resumes output audio and opens the transform socket.
2. The UI shows the selected source/track facts that the browser exposes, input/output meters, measured queue delay, network state and capture indicator.
3. Reuse the existing interactive spatial workspace and control lease. Initial controls: Original/Spatial, Point pose, browser volume and Stop.
4. Add array/EQ/source controls only after the basic route passes actual-device acceptance.
5. Stop ends capture, closes the transform session and flushes both queues. Signing out also revokes capture and output immediately.
6. Never expose arbitrary process IDs, paths, shell commands, output-device scripts or machine power controls.

Gate R4: the owner can deliberately start, hear processed-only audio, change spatial position, stop, restart and recover after connector loss without stale audio, feedback or automatic capture restart.

## Latency and quality budget

This network loop cannot be assumed to equal direct laptop latency. Measure separately:

- iPad capture callback and format conversion;
- uplink queue and public WSS transit;
- gateway queue and Rust DSP;
- downlink transit;
- AudioWorklet prefill/resampling and output presentation.

Start with 10 ms PCM16 input chunks and the existing 80 ms output prefill. Report measured median/p95 end-to-end latency. Do not claim a target before R0/R1 measurements. If TCP head-of-line blocking is audible, evaluate a Yinwei-only WebRTC media transport later; do not switch protocols silently or add lossy Opus before PCM fidelity is established.

## Verification matrix

| Layer | Automated evidence | Required actual-iPad evidence |
|---|---|---|
| Capture | capability parser, frame-size and lifecycle tests | audio track exists, non-silent desired source, permission/stop behavior |
| Routing | generated return tone and loop detector | no dry+wet doubling and no returned-audio recapture/feedback |
| Uplink | YNI1 schema, tickets, limits, backlog/drop, revocation | sustained PCM upload in Safari and installed PWA |
| Engine | DSP parity, queue/epoch tests, file/Windows regressions | audible Original/Spatial and directional changes |
| Downlink | existing YNW1/AudioWorklet tests plus full-duplex ordering | continuous returned audio, stop/start, route changes |
| Recovery | connector rotation, stale status, ticket expiry | fixed PWA recovery without reinstall or automatic capture restart |
| Performance | bounded-memory and stress tests | latency, glitches, battery/thermal and 30-minute run |

Synthetic PCM, Chromium emulation and public echo tests are never reported as real iPad acceptance.

## Deployment and interruption discipline

- Prepare gateway/native/browser builds separately from the active package.
- Do not replace a loaded DLL, stop Windows Live Transfer, change a source or restart Yinwei without checking current playback and obtaining owner approval.
- Do not enable Windows startup in this plan.
- Keep current verified player, DLL hashes, accounts and rollback package intact.
- Connector/Worker-only changes must retain laptop playback, but deployment still uses only Yinwei's account and resources.

## Rollback

- Disable `/remote/ws/transform` and the PWA Start control; existing laptop-to-iPad listening remains available.
- Switch back to the previous matched player/DLL package only after approved shutdown.
- Restore the fixed Worker to discovery-only behavior if stable proxying fails; preserve the existing bookmark/offline page.
- A failed R0 probe changes no engine, player, connector or Cloudflare resource.

## Approval boundary

Approval starts **Gate R0 only**: create and deploy a small Yinwei-only capture/routing probe, then test it on the owner's actual iPad. It does not yet send personal media to the laptop; numeric telemetry and generated test signals are sufficient for the gate. R1-R4 begin only after R0 proves that Safari/PWA supplies usable system audio, remains active in the required arrangement, suppresses the dry path and does not recapture returned PWA audio.
