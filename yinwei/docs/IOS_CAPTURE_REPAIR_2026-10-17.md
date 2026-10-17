# iOS broadcast capture repair — 2026-10-17

## Scope and behavior

The approved change repairs the existing ReplayKit → local Unix socket → Flutter
host → laptop Rust DSP → iPad AVAudioEngine path. It does not change DSP, HRTF,
the spatial coordinate contract, laptop processing, or the Windows audio DLL.

- Runner and BroadcastUpload compile the same `YinweiCaptureSupport.swift`.
  Each reads App Group candidates from its own executable's signed XML
  entitlement slot, removes duplicates, sorts, and picks the first candidate
  for which `containerURL(forSecurityApplicationGroupIdentifier:)` succeeds.
  There is no hard-coded preferred or fallback group. `UserDefaults` allocation
  is no longer used as proof of App Group access.
- Both signed bundles must select the same accessible group. Sorting cannot
  compensate for different authorized group sets. Missing/unreadable groups
  fail with a Group unavailable error; the extension also reports this through
  `finishBroadcastWithError` because unavailable shared storage cannot deliver
  telemetry back to the host.
- The signed-entitlement reader supports thin little-endian 64-bit Mach-O with
  the XML entitlement slot. Unsupported formats, including DER-only signatures
  and universal binaries, fail closed. The actual re-signed iPad artifact still
  needs validation. Profile permissions are not a runtime fallback.
- The picker discovers `com.apple.broadcast-services-upload`, rather than
  choosing whichever `.appex` happens to be listed first. Missing extensions and
  failed presentation propagate to the live session and probe UI.
- The extension declares `NSExtensionAttributes.RPBroadcastProcessMode` as
  `RPBroadcastProcessModeSampleBuffer`.
- Pending socket connections retain their descriptor. Subsequent capture-worker
  passes poll without blocking, check `SO_ERROR`, and enforce a three-second
  timeout. Refused/failed connections close and use the existing retry cadence.
  Partial-write framing protection and bounded queues remain in place.
- Runner declares `UIBackgroundModes = [audio]`. Switching apps no longer
  explicitly stops the live screen's session. Detachment, screen closure,
  explicit Stop and native interruption handling still clean up the session.

## Diagnostics

| Indicator | Meaning |
|---|---|
| `appAudioBufferCount` | ReplayKit app-audio callbacks in the extension |
| `audioSilent` | Inspected peak at or below 0.0001; not a DRM diagnosis |
| Capture received | Complete valid PCM chunks parsed by the host |
| Return received | Processed packets delivered by the laptop client before host output drops |
| Queued | Cumulative buffers accepted by the native player, not current queue depth |
| Played | Native `.dataPlayedBack` completion count, not merely queue acceptance |
| Output drops | Host in-flight limit or native output rejection |

Played counts are fetched every 500 ms during the active session. Native counts
reset at session preparation. Generation tokens reject playback callbacks after
stop/reset and Dart rejects stale status responses after cleanup. A played
callback establishes the audio system's completion, not that the user heard sound
on the intended route.

Startup and runtime errors distinguish group access, missing broadcast extension,
socket binding/endpoint failure, invalid captured packets, capture timeout/stall,
laptop connection/stream failure, and interrupted iPad output.

## Verification

- Rust audio core: 84 tests passed, including HRTF, spatial playback, live ingress
  and remote rebatching regressions.
- Flutter capture, probe, lifecycle, iOS playback mock-runtime and screenshot
  regressions: 34 tests passed.
- Changed Dart source/tests: static analysis passed.
- Dart application bundle: debug build passed for the host `windows-x64` target.
  This compiles Dart/assets only; it is not an iOS native build. The initial
  default-target bundle attempt required an absent Android SDK; explicitly
  selecting the host target resolved that build-tool configuration issue.
- Both plist structures were parsed and their new nested values checked.
- UI: portrait screenshot baseline updated and a readable screenshot inspected;
  landscape at 1.6× text scale and user interactions are covered by widget tests.
  The readable Windows render uses Segoe UI as a test font, not an actual iPad font.
- Windows DLL SHA-256 before/after:
  `0D150DEFF17C3599C92244775B56C119A120604AFED1297E150E2F0A2236305F`.

Native tests are in `test/native_capture/main.swift`. The synthetic unsorted
five-group profile is `test/fixtures/ios_capture/five_groups_profile.plist`.
Cases cover reversed host/extension ordering, inaccessible first candidate,
no accessible group, no legacy preference, signed-entitlement extraction,
truncated/corrupt executable data, pending/error/timeout socket transitions,
and received/accepted/played counter generations.

Run on macOS:

```sh
bash yinwei/tools/test_ios_capture.sh
```

The existing unsigned iOS build script now runs that suite before building.
The subsequent [macOS Actions run 39017399030](https://github.com/M2-King/Yinwei-UI-Redesign/actions/runs/39017399030)
passed for commit `d664be5915d0df87193aa9377d08ec4087251b91` on
`codex/ios-capture-ci`:

- 566 native Swift capture checks passed, including the unsorted five-group
  profile, sorted container validation, denied/missing groups, host/extension
  ordering, signed-entitlement parsing and nonblocking socket transitions.
- Full Flutter suite: 556 passed, 7 skipped; Rust suite on macOS: 69 passed.
- `flutter build ios --release --no-codesign` succeeded on `macos-latest`
  (arm64), using Xcode 26.6 and Flutter 3.47.2. Native FFI verification passed.
- IPA and test/build logs were uploaded and downloaded successfully. The
  log-upload configuration includes hidden files so `.ci-ios-logs` is retained.
- Local verification of the downloaded ZIP matched the CI verification JSON.
  Both Runner and `Payload/Runner.app/PlugIns/YinweiBroadcastUpload.appex`
  contain arm64 iOS device executables. The extension's Info.plist contains
  `NSExtension.NSExtensionAttributes.RPBroadcastProcessMode` set to
  `RPBroadcastProcessModeSampleBuffer`; Runner's Info.plist contains
  `UIBackgroundModes: [audio]`.
- Final IPA: 10,185,942 bytes; SHA-256
  `c892954d28a0fc94181dcc8358a3405eb9d921bedd32606ad5f8b33103ce945c`.
  Local download: `outputs/ios-actions/39017399030/Yinwei-unsigned.ipa`.
- No signing secrets were added. The IPA contains no provisioning profiles
  and requires signing before installation. The Windows audio DLL checksum
  remains unchanged from the value recorded above.

Final re-signed binary validation, physical iPad audio output and device console
verification remain pending. These build and mock-runtime checks do not establish
native iOS audio correctness or background survival on a physical device.

## Device acceptance

1. Inspect the final re-signed Runner and BroadcastUpload entitlements and plist
   values; confirm the same sorted accessible group is selected in both processes.
2. Verify Yinwei Music Audio appears in Apple's broadcast picker. Confirm group
   and missing-extension failures display their distinct messages.
3. Start a broadcast with an unprotected local audio file. Confirm capture
   callbacks, host Capture received, Return received, Queued and Played advance.
4. Switch to the source app, lock/unlock the iPad, and run sustained playback.
   Check device console logs for suspension, App Group, socket and audio-session
   errors. Test startup before the first returned packet as well as steady audio.
5. Stop/restart, change tracks, disconnect/reconnect the laptop, interrupt/change
   the output route, and confirm cleanup and explicit restart behavior.
6. Listen to Original/Spatial playback, left/right/front/back positions and HRTF
   movement against the prior build. Check feedback and double-audio behavior on
   the intended headphone route.

## Separate assessment: 127.0.0.1 fallback

Not implemented or enabled in this repair.

A loopback TCP transport could remove the shared filesystem path requirement
for PCM transport. It would not fix extension signing/loading or host background
suspension. Existing numeric telemetry still depends on the App Group, so simply
changing the socket address would not deliver a group-independent solution.

A separate prototype should bind exclusively to loopback, authenticate the peer
and session before accepting PCM, handle port conflicts/restarts, retain bounded
buffers and framing, and carry diagnostics over its authenticated connection.
Without an App Group, secure session discovery/pairing also needs a design; a
fixed port or magic packet is not authentication. Do not expose the listener on
all network interfaces or place laptop credentials in the extension.

Acceptance would require signed-device testing of initial connection, delayed
connect, background startup, locking, interruptions, malformed input, unexpected
local peers, port collisions and end-to-end latency. Feasibility on this iPad is
unverified; keep this as a separate explicit transport experiment.

## References

- [Apple provisioning profiles and claimed entitlements](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Apple Mach-O load-command definitions](https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h)
- [Apple signature and entitlement slot definitions](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/cs_blobs.h)
- [ReplayKit sample-buffer mode](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler)
- [Audio-session background playback](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback)
- [Native playback completion callback](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/dataplayedback)
