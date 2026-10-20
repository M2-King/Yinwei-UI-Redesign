# Private Tailscale Listen route — Stage A

This implements the existing HTTP/WebSocket control, events and stereo-audio
protocol over WireGuard. It does not implement UDP audio, QUIC, a new decoder,
encoder FEC, TLS or certificate pinning. Spatial rendering, DSP, HRTF and Live
Transfer capture are unchanged.

The host feature is **off unless `YINWEI_TAILSCALE_ENABLED=1`**. Nothing in this
change enables it, changes the running backend, adjusts the firewall or tailnet
policy, configures an iPad VPN, publishes binaries, or switches bundles.

## Trust and network boundary

- Public sign-in still resolves the existing approved HTTPS entry link. Owner
  passwords and public cookies are never sent to the private endpoint.
- The private listener can bind only `100.80.104.77`, TCP 8443 by default. The
  port is configurable; its address is not. A failed bind retries after
  1/2/4/8/16/32 seconds, with a 32-second ceiling. It never binds a wildcard,
  a LAN address, or another Tailscale address as a fallback.
- Every private request/upgrade checks the **actual socket source**, the full
  canonical owner login and the enrolled iPad's stable node ID. It uses the
  fixed local Tailscale executable, without a shell. Identity results have a
  two-second cache. Established WebSockets are rechecked every two seconds.
  Missing identity, tagged devices, wrong owners and wrong nodes fail closed.
- A successful owner sign-in can issue a single-use, 30-second enrollment
  ticket. Redemption happens privately after the node check. A random 256-bit
  pairing key is saved in a separate device-only iOS Keychain item first.
  Every subsequent private connection also requires that key.
- The host persists only its pairing-key hash, logical device ID and host ID,
  in `%LOCALAPPDATA%\Yinwei\remote\private-route.json` by default. The record is tied to the
  owner account credentials and configured Tailscale owner/node. Protect its
  directory as you already protect the owner account file.
- Private requests have their own quota. They cannot reach sign-in pages,
  browser assets, guest endpoints, capture/transform endpoints, internal
  readiness or origin rotation. Only session/media, lease/commands, pairing
  resume, sign-out, stream tickets, events and audio are exposed.
- Host/Origin/CSRF and one-time WebSocket-ticket checks remain in force.
  Forwarded identity/address headers are ignored. Pairing is not control
  takeover: the coordinator still enforces the existing lease rules.

HTTP/WS confidentiality relies on Tailscale/WireGuard on the exact virtual
address. Other tailnet devices are not trusted merely because they can connect.
The pairing key adds application authorization. This does not protect against
an administrator or malicious software controlling either paired endpoint.
Public fallback retains its existing HTTPS/Cloudflare trust assumptions.

## Enable on the laptop

These steps require an **updated host executable and updated native iPad app**.
Bundle w20 and iPad build 55 do not acquire this implementation by setting an
environment variable. This task does not deploy either binary or build an IPA.
Use your separately approved deployment/start procedure, with one backend only.

1. In the same Windows account/security context that will run the backend,
   confirm that Tailscale can identify the iPad:

   ```powershell
   $ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
   $peerText = & $ts whois --json 100.78.238.127
   if ($LASTEXITCODE -ne 0) { throw 'Tailscale identity lookup failed; do not enable yet.' }
   $peer = $peerText | ConvertFrom-Json
   $peer.UserProfile.LoginName
   $peer.Node.StableID
   $peer.Node.Name
   ```

   Confirm the device is `ipad171` and that the **full** LoginName is the owner
   starting `26098681@`, not `26071589@`. Do not use a name, prefix, numerical
   user ID or ordinary node key in place of `Node.StableID`.

   The initial sandboxed lookup returned **Access is denied** from the local
   Tailscale named pipe. An authorized read-only lookup outside that sandbox
   succeeded and confirmed the expected owner and `ipad171` stable node.
   Still run this preflight in the actual backend's security context; do not
   weaken the checks to bypass an error. This change does not grant daemon
   permissions or elevate the backend.

2. In the environment inherited by the updated backend, set:

   ```powershell
   if ($peer.UserProfile.LoginName -notmatch '^26098681@[^@\s]+$') {
     throw 'Unexpected owner identity'
   }
   $env:YINWEI_TAILSCALE_OWNER_LOGIN = $peer.UserProfile.LoginName
   $env:YINWEI_TAILSCALE_IPAD_NODE_ID = $peer.Node.StableID
   $env:YINWEI_TAILSCALE_PORT = '8443'
   $env:YINWEI_TAILSCALE_ENABLED = '1'
   ```

   Keep the existing public entry, owner-account and loopback gateway settings.
   Optional `YINWEI_TAILSCALE_EXE` must be an absolute executable path; it defaults
   to the installed Program Files Tailscale executable. Optional
   `YINWEI_TAILSCALE_PAIR_FILE` must be an absolute private data-file path.
   Paths in assets, `outputs/`, or named `deployment.json` are rejected. The
   existing owner-account file is read normally; pairing data never goes beside
   it inside a bundle. Keep the application-data directory private to the host user.

3. If current network policy does not already allow it, the user/administrator
   must allow **TCP from 100.78.238.127 to 100.80.104.77:8443** in the tailnet
   policy and the laptop firewall. Scope the firewall rule to the updated
   executable, exact local Tailscale address/port and paired source address.
   Do not open a LAN/public listener or the entire `100.64.0.0/10` range.
   Tailscale grants are additive: a narrow grant does not remove an existing
   broad grant. App identity/key checks remain necessary regardless of ACLs.
   No firewall, ACL, router or VPN settings were changed by this task.

4. Start the updated backend through the normal approved procedure after
   arranging the changeover yourself. Do not launch a second engine beside the
   current backend. If Tailscale starts later, the private bind retries while
   the loopback/Cloudflare gateway remains available.

5. Check the listener from the laptop:

   ```powershell
   Get-NetTCPConnection -State Listen -LocalPort 8443 |
     Select-Object LocalAddress, LocalPort, OwningProcess
   ```

   The expected address is **100.80.104.77**, never 0.0.0.0, `::` or a LAN IP.
   If no listener appears, check the configured identity, port availability,
   pair-record directory permissions and Tailscale state.

## Pair and test on the iPad

1. Keep the already configured Tailscale VPN connected on `ipad171`. No new VPN
   settings are required. Open the updated Yinwei app and manually sign in with
   the **existing entry link and owner login**, then tap Listen. A manual sign-in
   enrolls only the configured owner/node. Automatic saved-login recovery never
   enrolls an unpaired device silently. If Keychain storage fails, stay public.
2. Use the existing **Copy audio diagnostics** action. Under `network`, expect
   `route: tailscale-websocket`. The report includes transport generation,
   switch/probe counts, last probe/setup duration, first-audio recovery duration
   a sanitized failure code, and a bounded switch history. It contains no pair
   key, cookies or addresses.
3. While playing, disconnect the iPad's Tailscale VPN temporarily using its
   existing controls. Expect automatic `cloudflare-websocket` fallback, one
   audible stream, and working existing control/lease behavior. Do not stop the
   laptop engine to test a route failure.
4. Reconnect Tailscale. Switchback requires at least three successful probes,
   ten seconds of healthy observations, and the failure cooldown. Failed private
   probes back off up to 48 seconds; a foreground/path-change signal wakes a
   probe immediately. Inspect the new generation/history in diagnostics.
5. Switch Wi-Fi/hotspot while listening; also test locked-screen playback,
   Bluetooth/AirPlay and foreground recovery. Check for one stream, no duplicate
   next/previous action and continued control synchronization. A route failure
   does not itself request account/password sign-in. Expired route cookies can
   be renewed using the pairing key, including privately while Cloudflare is down.
6. Test a public tunnel rotation using the existing supervisor procedure while
   private audio is active. Private audio/control must remain connected. Do not
   restart or switch the laptop bundle just to simulate origin rotation.

Stage A retains TCP head-of-line blocking. It removes the Cloudflare hop when
the private path works; it does not promise loss-free audio or a fixed handover
time. A DERP relay can still introduce TCP stalls. Physical device/ear checks,
actual iOS HTTP-over-WireGuard behavior and background/VPN recovery remain
required; no iPad build or deployment was performed here.

## Revoke or roll back

- Signing out in the updated iPad app revokes its host pair and clears its
  Keychain pairing item. Signing back in manually is required to enroll again.
- The existing authenticated owner `revoke-devices` endpoint revokes the pair
  when called from another owner session. The authenticated public POST
  `/remote/api/private/revoke` also revokes it explicitly, using the existing
  owner cookie, exact Origin and X-CSRF-Token. Neither endpoint is exposed
  through the private listener. Old keys cannot resume via either route.
- To turn Stage A off, remove `YINWEI_TAILSCALE_ENABLED` (or set it to `0`) from
  the backend environment and use your approved backend restart procedure.
  The public loopback/Cloudflare path remains the default. No bundle, engine,
  manifest, firewall or VPN change is needed. Disabling preserves the hashed
  pairing record for a later explicit re-enable; use revocation to invalidate it.

## Verification

Automated tests bind only loopback and inject peer identities. They do not
enable the production feature or disturb the running backend. Coverage includes
wrong owner/node, tagged/unpaired peers, missing whois, key checks, ticket expiry
and replay, Host/Origin spoofing, the private endpoint allowlist, persistent
revocation, active-stream revocation/identity failure, bind retry, public-origin
rotation, expiry without Cloudflare, automatic fallback/switchback, single tap
ownership, stale native writes, command deduplication and path-change wakeups.

Final command results are recorded in the accompanying implementation report.
