# Stage A implementation report

Branch: `codex/ios-capture-ci`; base/HEAD: `278aa61`.

Implemented the native iPad Listen client's Tailscale-first route using the
existing WebSocket audio/events protocol and existing command authority.
The host switch remains **off**. No production private listener was started.

## Behavior

- Exact `100.80.104.77` HTTP/WS binding, configurable TCP port (default 8443),
  bounded exponential bind retry and a private endpoint allowlist.
- Actual-peer whois verification, full owner login plus stable enrolled-node ID,
  two-second identity cache, and periodic established-socket verification.
- Short-lived one-use pairing tickets, a separate device-only Keychain item,
  hashed host pairing records in application data, persistent revocation and
  account/node binding. Unrelated JSON and protected output/asset paths are
  rejected as pairing-store destinations.
- Independent public/private route credentials with one logical device ID.
  Public-origin rotation does not revoke a working private route or its lease.
- Automatic fallback and hysteresis-based private switchback, network-change
  wakeups, generation checks, stale-write draining, and one host tap owner.
- Uncertain command retries preserve the exact command envelope/ID. Business
  refusals retain their existing lease/takeover semantics.
- Copy audio diagnostics includes route, switches, generation, bounded switch
  history, probe/setup timings, first-packet recovery timing and a sanitized
  failure code. No pairing keys, cookies, raw addresses or passwords are exported.

No UDP audio, QUIC, libopus integration, encoder FEC or TLS/pinning was added.

## Files

Paths below are relative to `yinwei/apps/yinwei_player/`, except the two docs.

| File | Change |
| --- | --- |
| `lib/remote/private_route.dart` | New host configuration, whois verifier, pairing storage/tickets and private listener |
| `lib/remote/private_pair_store.dart` | New validated paired endpoint and separate Keychain store |
| `lib/remote/routed_owner_client.dart` | New native route selection, recovery, hysteresis and diagnostics |
| `lib/platform/listen_network_changes.dart` | New lazy native path-change notification adapter |
| `lib/remote/remote_gateway.dart` | Shared protocol handlers, scoped origin rotation, authenticated audio handoff and private restrictions |
| `lib/remote/remote_auth.dart` | Additive paired route-session creation preserving logical device identity |
| `lib/remote/remote_owner_client.dart` | Restricted private HTTP client, pairing operations and reusable command envelopes |
| `lib/remote/laptop_listen_controller.dart` | Route integration, socket/write generation checks and diagnostic export |
| `lib/mobile/ios_laptop_listen_screen.dart` | Supply Keychain pairing store and lazy network notifications |
| `lib/screens/player_screen.dart` | Default-off host wiring; private setup failure preserves public access |
| `ios/Runner/AppDelegate.swift` | Lazy NWPathMonitor registration; no VPN configuration |
| `ios/Runner/YinweiSignInKeychainChannel.swift` | Separate pairing Keychain item; existing saved-login item remains separate |
| `test/remote/private_route_test.dart` | Security, persistence, network migration and command-deduplication integration coverage |
| `test/remote/private_pair_store_test.dart` | Keychain separation and saved endpoint validation |
| `test/platform/listen_network_changes_test.dart` | Lazy observer lifecycle and recovery notification |
| `yinwei/docs/TAILSCALE_STAGE_A.md` | Exact enable, device-test, revoke and rollback instructions |
| `yinwei/docs/TAILSCALE_STAGE_A_REPORT.md` | This report |

## Verification

| Check | Result |
| --- | --- |
| Full `flutter test --no-pub --reporter expanded` | **777 passed, 6 skipped, 0 failed** |
| All seven Node test files | **37 passed, 0 failed** |
| Changed transport/auth modules and new tests: Dart analysis | **No issues found** |
| Full `dart analyze` | **0 errors, 6 warnings, 111 infos**; exit 2 from existing findings |
| Windows release build, `--no-pub` | **Succeeded**; application not launched |
| Whitespace/diff check | Passed |

The 13 analysis findings within modified files refer to unchanged source lines;
none refer to newly changed lines. The six full-repository warnings are in
untouched engine-controller, update, widget and existing runtime-test code.
They were left outside this security/networking change.

Node files run:

- `test/listen_room/bridge_test.mjs`
- `test/listen_room/offline_contract_test.mjs`
- `test/listen_room/room_math_test.mjs`
- `test/listen_room/speakers_test.mjs`
- `test/remote/audio_browser_test.mjs`
- `test/remote/capture_probe_browser_test.mjs`
- `test/remote/signin_browser_test.mjs`

The full Flutter run includes wrong-owner, same-owner/wrong-node, tagged-node,
unpaired and wrong-key refusals; expired/replayed/revoked tickets; identity
failure on new and active connections; spoofed headers; forbidden private
endpoints; persistent and concurrent revocation; safe storage/bind retry;
public-origin rotation with private audio and control; private failure with
public playback; private expiry without Cloudflare; switchback hysteresis;
path-change wakeup; one tap owner; stale native writes; and a lost command reply
retried on the fallback route with exactly one `media.next` execution.

The six skipped tests require explicitly configured native libraries, an
isolated deployed bundle/public relay, or a macOS host. No workflow was run to
provision those fixtures.

Raw logs are retained under repository `.tmp/tailscale-stage-a-20261020/`:
`flutter.log`, `node.log`, `analysis-full.log`, `analysis-scoped.log`, and
`windows-build.log`. The successful Windows build printed a nonfatal
"Nuget is not installed" notice.

## Protected state and remaining device checks

No engine/Rust, HRTF, DSP, Live capture, deployment manifest or `outputs/` files
were changed. No commit, staging, push, workflow, IPA build, publishing, bundle
switch, firewall/ACL change or VPN configuration change was performed.

The pre-existing modified `windows/runner/spatial_core.dll` was neither changed
nor staged. Its SHA-256 before and after remains:
`0d150deff17c3599c92244775b56c119a120604afed1297e150e2f0a2236305f`.
Other pre-existing website/untracked changes were left alone.

The initial sandboxed `tailscale whois --json 100.78.238.127` invocation returned
Access is denied for the daemon named pipe. An authorized read-only repeat
outside the sandbox succeeded, confirming the canonical `26098681@` owner and
the stable node for `ipad171`. The user should still run the guide's preflight
in the deployed backend's intended security context. Application tests inject
identities and use loopback sockets; no actual private iPad connection was opened.

No updated iPad binary was built or installed. Native iOS compilation, actual
HTTP/WS over the Tailscale VPN, Keychain persistence on a physical device,
background/locked-screen network changes, audible continuity, Bluetooth/AirPlay,
and battery remain device checks. Stage A still uses TCP and can still stall
under packet loss or DERP transport congestion.

Follow [the enable/test guide](TAILSCALE_STAGE_A.md). Existing w20/build 55 binaries
will continue using their current public route until separately updated.
