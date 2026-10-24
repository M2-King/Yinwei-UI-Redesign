# Listen audio over UDP (laptop → iPad)

Status: plan, not started. Written 2026-10-24 after the owner approved the idea:
"UDP first, TCP stays as the automatic backup". Implementation needs the owner's
go-ahead per phase (protected audio path, a new network listener, a firewall rule).

## 1. Goal

Make iPad listening survive weak or unstable networks: no gaps when a packet is
lost, a smaller delay, and the same sound quality on a good network.

Not in scope, and never changed: the audio engine (`spatial_core.dll`, HRTF, DSP,
Live capture), the laptop's audio route, spatial state, the Listen Room page,
controls (play/pause/song taps stay on today's HTTP + events socket), the Cloudflare
route (it stays TCP), and the 汽水 integration.

## 2. How audio travels today (facts, 2026-10-24)

| Step | Where | What it does |
|---|---|---|
| 1 | engine → native output tap | `lib/remote/native_output_tap.dart`: 8 chunks (~85 ms); drops the oldest when full |
| 2 | `ListenStreamSource` | `lib/remote/listen_stream_source.dart`: 20 ms Opus packets (`YNO1`, 960 frames at 48 kHz) or PCM (`YNW1`, lossless) |
| 3 | `RemoteGateway._pumpAudio` | `lib/remote/remote_gateway.dart:1145`: 10 ms timer, up to 4 packets per tick, at most 64 unacknowledged packets ("credit"), `ListenSenderPacer` (never holds late audio back) |
| 4 | WebSocket `audio` | TCP. One `{"ack": seq}` per packet back from the iPad; the laptop closes the socket if an ack is 5 s late |
| 5 | Routes | Cloudflare quick tunnel (HTTPS/WSS over the internet) or the private Tailscale route (`100.80.104.77:8443`, plain HTTP inside WireGuard, peer checked with `tailscale whois`) |
| 6 | iPad Dart | `LaptopListenController._audioLoop` (`lib/remote/laptop_listen_controller.dart:962`): parses the header, acks, calls `output.write(packet)` |
| 7 | iPad native | `ios/Runner/YinweiReplayKitProbe.swift` `write`: Apple's Opus decoder (`YinweiOpusDecoder`, AudioToolbox), `YinweiListenBuffer.enqueue` gives the sample time, `AVAudioPlayerNode.scheduleBuffer(at:)` |

Packet header (56 bytes, little-endian), unchanged by this plan: magic (0),
version (4), epoch (8), sequence (16), firstFrame (24), sampleRate (32),
frames (36), mode / dropped chunks / azimuth / elevation (40–55), then the payload.

What goes wrong on a weak network (owner's iPad diagnostics, 2026-10-24):
arrival gaps up to 648 ms, 5 underruns, 24 capacity drops, 13 312 missing frames,
a 370–550 ms buffer. TCP stops every later packet until a lost one is resent
(head-of-line blocking), so one loss becomes a gap. The iPad has no gap handling:
a missing packet is simply skipped, so the next one plays early (a click or a jump).

## 3. Design

### 3.1 Where UDP is used

- **Only on the private Tailscale route** (and later a laptop-hotspot route).
  WireGuard encrypts it and Tailscale proves who the peer is.
- **Never on the public internet.** Cloudflare quick tunnels carry HTTP only, and
  a public UDP port on the laptop is not acceptable.
- **Cloudflare stays exactly as today:** no UDP offer is made there.
- Note: when Tailscale has to use a DERP relay instead of a direct path, its
  packets travel over TCP between relays, so UDP gains less there. Direct paths,
  which the owner's home network supports (UPnP, IPv6), get the full benefit.

### 3.2 Setup, over the existing audio WebSocket

1. The iPad connects the `audio` WebSocket as today. Its hello adds
   `"transports": ["udp", "wss"]` (old laptops ignore it).
2. A laptop that supports UDP and is serving this socket over the private route
   answers in `audioReady` with
   `"udp": {"port": 8444, "session": <16 random bytes, base64>, "key": <32 random bytes, base64>}`.
   The key exists only for this audio session and is sent only over the
   authenticated socket.
3. The iPad opens a `RawDatagramSocket` and sends a **hello datagram** to
   `100.80.104.77:8444`: `YNUH`, the session, a nonce, and `HMAC-SHA256(key, session|nonce)`.
4. The laptop accepts the hello only if:
   - the HMAC matches;
   - the source address is the iPad's Tailscale address, checked with the same
     `tailscale whois` rule as the private route (owner login + node ID);
   - the session is current.
   It replies `YNUA` (also signed) and from then on sends audio datagrams to that
   exact address and port.
5. When the iPad receives the first UDP audio datagram, it sends
   `{"transport": "udp"}` on the WebSocket. The laptop then stops sending audio on
   the WebSocket. The WebSocket stays open as control and backup (pings, quality
   changes, fallback).

### 3.3 The audio datagram

`YNU1` wrapper (16 bytes: magic, version, flags, session tag, datagram counter),
then **one unchanged `YNO1` packet** (56-byte header + Opus). Every Listen packet is
sent **twice**: once at once and once ~40 ms later. A short burst of loss then still
leaves one copy. The receiver drops duplicates by the existing packet sequence.

Size check, against Tailscale's MTU (1280, so about 1250 bytes of UDP payload):
- **High (320 kbps):** ~800 bytes of Opus + 56 + 16 = about 870 bytes. Fits.
- **Max (510 kbps):** up to 1275 bytes of Opus. Does not fit, so it is sent in two
  fragments (`flags` = fragment 1/2, 2/2). A packet counts as lost if either
  fragment is lost.
- **Lossless (PCM, up to 4 KB per packet):** stays on the WebSocket in phases 1–3.
  Phase 5 may add fragmentation plus duplication.

Data use doubles: High is about 650 kbps (≈ 290 MB per hour) instead of 320 kbps.
Phase 3 switches the second copy off when the measured loss is zero.

### 3.4 Sending (laptop)

- Same tap, same `ListenStreamSource`, same `ListenSenderPacer`. The pacer rule
  stays: never hold late audio back.
- No credit or acks on UDP: datagrams are sent at media pace. The 64-packet
  credit and the "ack 5 s late → close" rule in `_pumpAudio` apply only to
  WebSocket audio. In UDP mode the receiver reports take over that job, so an
  idle WebSocket is not closed for missing acks.
- The iPad sends a **receiver report** every 200 ms (`YNUR`, signed): highest
  sequence, lost and recovered counts, buffer milliseconds. If no report arrives
  for 3 s, the laptop goes back to WebSocket audio by itself.
- A new class `ListenUdpSender` (`lib/remote/listen_udp_sender.dart`) owns the
  socket, the duplicate queue and the reports. `RemoteGateway` only decides
  between WebSocket and UDP for the current audio session.

### 3.5 Receiving (iPad)

- New `ListenUdpReceiver` (`lib/remote/listen_udp_receiver.dart`):
  - socket and signed hello;
  - fragment reassembly;
  - duplicate drop by sequence;
  - a reorder window of 16 packets.
- **Jitter buffer in Dart, before the native write.** Packets are passed to the
  existing `output.write` in sequence order. If the next packet is missing when
  its play-out deadline passes (current buffer target minus 20 ms), it is
  declared lost and a gap is written instead.
- **Gap handling (new, native):** `writeGap(frames)` in `YinweiReplayKitProbe.swift`
  schedules 20 ms that repeat the last decoded 20 ms with a fade-out, then fades
  the next real packet in. The timeline stays aligned, so there are no jumps.
  Apple's Opus decoder has no built-in concealment, so this replaces it.
  - The same gap handling also improves the WebSocket path, where a skipped
    packet is a jump today.
- The buffer target starts at the route's existing minimum (`routeMinimumMs`). It
  grows when loss or late packets appear and shrinks slowly when the connection is
  clean, reusing `YinweiListenBuffer`'s existing target logic.

### 3.6 Fallback and switching back

- **UDP setup fails** (no `YNUA` within 1.5 s, or a firewall blocks it): stay on
  the WebSocket, exactly as today. Try again after 30 s.
- **UDP audio stops for 500 ms:** the iPad sends `{"transport": "wss"}`, and the
  laptop resumes WebSocket audio from the current tap position. Sequence numbers
  continue (same `ListenStreamSource`), so the receiver's duplicate drop handles
  any overlap.
- **Route changes** (Tailscale ↔ Cloudflare): UDP is torn down with the old route.
  It is offered again only on the private route.

### 3.7 Security

- The laptop's UDP socket binds only to the Tailscale address (`100.80.104.77`),
  never to 0.0.0.0 or a LAN address, like the private route listener.
- Audio is sent only to the address verified with `tailscale whois`. Hello and
  reports must carry a valid HMAC with that session's key, and keys are new for
  each audio session.
- Commands never travel over UDP; it carries audio and receiver reports only.
- Limits: one UDP session at a time, hello rate-limited (5 per minute), datagrams
  over 1400 bytes dropped.
- **Windows Firewall:** inbound UDP 8444 on the Tailscale interface may need a
  rule. The project rule is never to change the firewall without the owner, so
  adding that rule is a separate approval step.

## 4. Files

| Side | File | Change |
|---|---|---|
| Laptop | `lib/remote/listen_udp_sender.dart` (new) | Socket, signed hello/ack, duplicate queue, reports, fallback timer |
| Laptop | `lib/remote/remote_gateway.dart` | `audioReady` UDP offer on the private route; WebSocket ↔ UDP switch in `_pumpAudio` |
| Laptop | `lib/remote/private_route.dart` | Reuse the `whois` peer check for UDP source addresses (no rule change) |
| Shared | `lib/remote/listen_udp_protocol.dart` (new) | Datagram encode/decode, HMAC, fragments: pure functions |
| iPad | `lib/remote/listen_udp_receiver.dart` (new) | Socket, reassembly, duplicate drop, reorder, deadlines |
| iPad | `lib/remote/laptop_listen_controller.dart` | Offer transports; feed packets from WebSocket or UDP into one ordered path |
| iPad | `lib/platform/ios_laptop_listen_output.dart` | `writeGap(frames)` channel method |
| iPad | `ios/Runner/YinweiReplayKitProbe.swift` | Gap buffer: repeat with fade-out, fade-in of the next packet |
| Both | `lib/remote/listen_audio_diagnostics.dart` | `transport`, `udpLost`, `udpRecovered`, `concealed`, `duplicates`, `lateDrops` |
| Laptop (phase 4) | `crates/yinwei_opus/src/lib.rs` | `OPUS_SET_INBAND_FEC 1`, `OPUS_SET_PACKET_LOSS_PERC` |

Protected and untouched: `crates/spatial_core`, `spatial_core.dll`, the Live capture,
`app_audio_route.dart` routing, the tap's size and drop rule, the 56-byte packet header.

## 5. Phases and gates

Each phase ships behind a laptop setting (`YINWEI_LISTEN_UDP=1`, off by default
until the owner accepts phase 2). Turning it off restores today's behaviour.

| Phase | Content | Gate before the next phase |
|---|---|---|
| P0 | Baseline: record diagnostics for 5 minutes on home Wi-Fi and on mobile data (WebSocket only) | Numbers saved in `docs/validation/` |
| P1 | UDP with duplicate copies, Opus High only, fallback to WebSocket | Loss tests pass; on the iPad, 30 min without fallback on home Wi-Fi |
| P2 | Gap concealment on the iPad (UDP and WebSocket) | Owner listening test: no audible gaps at 5 % simulated loss |
| P3 | Adaptive: second copy only when loss is seen; buffer target follows the connection | Delay below 250 ms on a clean connection |
| P4 (optional) | libopus decoder on the iPad (`yinwei_opus` built for iOS, like `spatial_core`), so real Opus FEC and concealment replace duplication; less extra data | Owner A/B: no quality difference |
| P5 (optional) | Lossless over UDP (fragmentation plus duplication) | Owner decision on data use |

## 6. Tests

- Unit: datagram encode/decode, HMAC rejection, fragments, duplicate drop,
  reorder window, deadline decisions, fallback state machine.
- **Loss simulation:** a fake network between `ListenUdpSender` and
  `ListenUdpReceiver`, with random loss (1 %, 5 %, 10 %), bursts (3 packets),
  reordering and 300 ms stalls. Expected:
  - with duplicates, zero unrecovered packets at 1–5 % random loss;
  - every unrecovered packet becomes exactly one concealed 20 ms gap, never a jump.
- Windows integration: a real UDP loopback between the sender and a receiver
  harness, and the whois source check with a fake peer.
- iOS CI: Swift tests for `writeGap` (timeline continuity, fade, no clicks at the
  boundaries), added to `tools/test_ios_capture.sh`.
- Regression: the full Flutter and Node suites; the WebSocket path unchanged with
  `YINWEI_LISTEN_UDP` off.
- Device acceptance (owner): A/B of P0 and P1/P2 diagnostics on home Wi-Fi,
  mobile data, and walking between rooms. Synthetic tests are not device acceptance.

## 7. Risks

| Risk | Handling |
|---|---|
| A network blocks UDP (school Wi-Fi) | Automatic WebSocket fallback; never worse than today |
| MTU too small, fragments lost | High fits one datagram; Max uses 2 fragments; measured in P1 |
| Twice the data | P3 adaptive copies; owner decides the default |
| iOS suspends the app | The audio background mode keeps it alive; UDP is re-armed on resume like today's sockets |
| Firewall | Separate owner approval for the inbound UDP 8444 rule on the Tailscale interface |
| DERP-relayed Tailscale | Works, with a smaller gain; diagnostics show the path |

## 8. Owner decisions needed

1. Approve P0–P2 (protected audio path, new UDP listener on the Tailscale address).
2. The firewall rule for UDP 8444 on the Tailscale interface, if Windows asks.
3. Default after P2: UDP on, or still opt-in.
4. Whether Lossless over UDP (P5) and libopus on the iPad (P4) are wanted.
