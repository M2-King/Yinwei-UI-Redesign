# iPad live sign-in repair — 2026-10-17

## Confirmed causes

The reported screen failed before capture or return playback started. The fixed
Worker bookmark serves an HTML landing page at `/`, even when the laptop is
online. The iPad client incorrectly expected that page to redirect. The Worker
returns its checked laptop sign-in origin from `/open` instead.

The public `/status` endpoint also reported the laptop offline. The open player
was the installed `C:\Program Files\Yinwei` copy, which was not exposing the
configured remote backend. With explicit owner approval, it was closed and the
existing verified backend player was launched. Local native readiness and public
entry status then both reported online. `/open` returned HTTP 303 to the current
laptop origin, and its `/remote/signin` endpoint returned HTTP 200. No owner
password was read or submitted during this diagnosis.

## Repair

Commit `b3fc638` resolves the fixed bookmark through `/open`. Existing HTTPS,
host, path, credential, query and fragment checks remain in place. Redirects are
not automatically followed; credentials are submitted only after validating the
laptop origin. Direct temporary laptop origins remain supported.

Sign-in messages now distinguish unavailable backend, untrusted redirect,
rejected credentials, rejected/expired session, rate limit, HTTP failure,
timeout, network failure, TLS failure and malformed response. HTTP errors carry
only the endpoint path and status, without response bodies or credentials.

Local verification: 46 regression tests passed across sign-in, capture session
and remote gateway suites; analysis of all changed Dart files passed. The new
tests exercise production requests against a local HTTP fixture, including the
landing-page versus redirect behavior and rejection before credential submission.

The Windows audio DLL remains unchanged, SHA-256:
`0D150DEFF17C3599C92244775B56C119A120604AFED1297E150E2F0A2236305F`.

## CI follow-up

The first macOS run passed all new sign-in tests but exposed an existing
`EngineController` disposal race in the orbit visualization test. Cancelling a
periodic timer did not stop a callback already awaiting engine telemetry. The
callback could continue reading and notify a disposed controller.

The follow-up checks that the originating timer is still active after each
awaited telemetry read and prevents an old tick from clearing a newer tick's
in-flight flag. No DSP algorithm, native library or playback routing changed.
Four deterministic tests suspend each telemetry read, dispose the controller,
and verify no additional reads or notifications occur. All 37 tests across
controller playback, orbit visualization and sign-in passed locally. Analysis
reported only the controller's existing unused `_liveGen` and
`_scheduleLiveRebuild` warnings and its existing final-field suggestion.

## Final build verification

[Actions run 39041010680](https://github.com/M2-King/Yinwei-UI-Redesign/actions/runs/39041010680)
passed for commit `d932c00c322473dbd62af6f46eb6d07a8c0f3c68`:

- 574 Flutter tests passed, 7 skipped; 566 Swift capture checks passed, including
  the unsorted five-group test; 69 Rust tests passed.
- `flutter build ios --release --no-codesign` and native FFI checks passed on
  `macos-latest`, Xcode 26.6 / Flutter 3.47.2.
- The downloaded IPA's verification JSON matches the CI report. Both Runner
  and `PlugIns/YinweiBroadcastUpload.appex` contain arm64 iOS device binaries.
- The extension plist contains
  `NSExtension.NSExtensionAttributes.RPBroadcastProcessMode` with value
  `RPBroadcastProcessModeSampleBuffer`. Runner's plist contains
  `UIBackgroundModes: [audio]`.
- IPA: `outputs/ios-actions/39041010680/Yinwei-unsigned.ipa`, 10,186,604 bytes.
  SHA-256: `af96446e1aaccd4e1039238036dba4f078dd1aefc0a09a52ba8e5ff7bfa745f8`.
  Test and build logs were also downloaded. No signing secrets were added;
  the IPA has no provisioning profiles and requires signing before installation.

Physical iPad sign-in and audible end-to-end capture still require owner testing
after installing a signed copy of the repaired IPA. Automated results do not
establish physical-device playback or background survival.
