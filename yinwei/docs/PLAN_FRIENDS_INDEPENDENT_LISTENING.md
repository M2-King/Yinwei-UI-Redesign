# Plan — friends hear their own sound with Yinwei, independently

Date: 2026-10-18 · Status: **proposal, awaiting owner decision**

## Goal

Each friend uses Yinwei on **their own sound** (their files, their music
player), with **their own** position/mode settings, without affecting the
owner, the owner's laptop, or each other. Nobody's audio is shared with
anybody else.

## Why today's laptop backend cannot do it as is

The laptop backend is deliberately single-owner:

- one owner account (`remote_auth.dart`, role `owner` only);
- one remote listener at a time (`audio_busy`);
- one remote engine slot (`remote source already active` in
  `remote_ingress.rs`), sharing the laptop's single engine session.

Friends signing in there would compete for one engine and hear **the
owner's laptop audio**, not their own. Turning the laptop into a
multi-tenant server (per-friend accounts, one isolated engine per friend,
quotas, bandwidth over a free Cloudflare quick tunnel, the laptop always on)
is the most work and needs care. It is designed below as **Option L**.

## Recommendation: the sandbox runs on each friend's own device

"Sandbox" here means each friend's Yinwei runs isolated **on their own
device**, inside the browser's sandbox (web) or the OS app sandbox (native).
The owner only publishes the app; no audio ever passes through the owner.

| Friend's device | What they use | Their sound | Hears only spatial? |
|---|---|---|---|
| Any modern browser (Windows, Mac, Android, iPad, iPhone) | **Yinwei Web** (new, F1) | Files they open | Yes |
| Windows/Mac with Chrome or Edge | **Yinwei Web, Live tab** (F2) | A music website playing in another browser tab | Yes, with `suppressLocalAudioPlayback` |
| Windows PC | **Yinwei for Windows** installer (exists: `YinweiSetup-0.1.3`) | Files, or Live Transfer from any app | Yes, if the PC has a silent virtual output (F3) |
| Android | **Yinwei Android** APK (exists: A2 preview) | Files / playback capture | Capture path: original also audible |
| iPad/iPhone native | **Yinwei iPad** via TestFlight (F3) | Files | Yes |

## Phases

### F0 — feasibility (engineer, small)

Compile `spatial_core` to WebAssembly with `--no-default-features` (no
`cpal`). All engine dependencies are pure Rust (`hrtf`, `biquad`,
`freeverb`, `symphonia`, `hound`, `serde`); the HRTF set is a 773 KB
embedded file. Measure, in Safari (iPad) and Chrome (Windows/Android):
load time, CPU per second of audio, and glitch-free playback in an
`AudioWorklet`.

Gate: real-time stereo with headroom on a mid-range phone. If it fails,
stop and keep friends on native apps (F3).

### F1 — Yinwei Web: files (engineer)

A static, installable web app (PWA). The existing
`IMPLEMENTATION_IPAD_PWA_WASM.md` plan is reused, now for friends:

1. Open a local audio file (never uploaded anywhere).
2. Decode and process **once** in WASM (same HRTF/EQ/reverb as desktop);
   play through an `AudioWorklet`.
3. Reuse the existing Three.js spatial workspace (`workspace.js`) for
   position, Original/Spatial, orbit.
4. Export processed WAV.
5. Settings saved per browser only (local storage); no accounts, no server.
6. Host as static files on the existing website (EdgeOne) and/or GitHub
   Pages. Friends open a link, optionally "Add to Home Screen".

Isolation: each friend's copy runs in their own browser tab. There is no
backend, so friends cannot reach the owner's laptop, files or account.

### F2 — Yinwei Web: live from a browser tab (desktop Chrome/Edge)

1. The friend plays music in a web player tab, presses **Live** in Yinwei
   Web and picks that tab in the browser's share dialog.
2. `getDisplayMedia({ audio: { suppressLocalAudioPlayback: true } })`
   captures the tab and silences its local output, so only Yinwei's spatial
   version is heard: no double sound, no virtual device needed.
3. Process in WASM; play locally.

Limits to state honestly: Chromium desktop only (Safari/iPad cannot share
tab audio); DRM-protected players may deliver silence; streaming-app
**desktop programs** are not tabs (use F3 for those).

### F3 — native apps for friends who want system-wide Live

- **Windows:** publish the current Windows build as a new installer
  (Live Transfer with silent-virtual-device routing, warm routing helper).
  The friend's PC needs a silent virtual output (Steam Streaming Speakers,
  ToDesk Virtual Audio or free VB-Cable) for "only spatial"; otherwise
  original + spatial overlap. Unsigned installers trigger SmartScreen; a
  code-signing certificate removes that.
- **iPad/iPhone:** TestFlight external testing (Apple Developer Program,
  public link, up to 10,000 testers, builds expire after 90 days).
  Sideloaded IPAs with a free Apple ID expire after 7 days and are not
  suitable for friends.
- **Android:** publish the A2 APK as is; note the capture path keeps the
  original audible.

### Option L — everything runs on the owner's laptop (owner request, 2026-10-18)

Each person (owner and every friend) hears **their own music**, processed on
the owner's laptop, streamed to their own browser. Built so the owner's own
engine and Live Transfer are never touched.

**Measured on the owner's laptop** (AMD Ryzen 9 8945HX, 16 cores / 32
threads), `yinwei_cli` release, 60 s stereo file: 0.95–1.2 s per 60 s of
audio including decode = **~2% of one core per listener**. CPU allows
dozens of listeners.

**The limit is upload bandwidth**, through the laptop's home connection and
the Cloudflare tunnel:

| Stream format | Per listener | Friends on 20 Mbps upload |
|---|---|---|
| Today: 32-bit float PCM | ~3.1 Mbps | ~5 |
| 16-bit PCM (L5, no quality loss you can hear) | ~1.6 Mbps | ~11 |
| Opus 160 kbps (L5, needs a codec) | ~0.16 Mbps | 50+ |

**Whose music, legally.** Each friend plays only their own files (uploaded
to their private space) or their own live tab audio. The laptop never streams
the owner's library or the owner's streaming-app account to friends (one
paid account shared to many listeners breaks the services' terms).

**Phases**

- **L0 — guest accounts.** The owner creates one-time invite links; a friend
  sets their own password. Roles `owner` / `guest`. Guests cannot see the
  owner's files, control the owner's player or start Live Transfer.
  Per-guest revoke; a cap on guests. The current owner-only login stays as
  is for the owner.
- **L1 — one sandbox process per friend.** A new headless `yinwei_worker`
  binary uses the existing `spatial_core` API (no engine code change), so
  each friend gets a separate OS process with its own engine state. The
  gateway starts it when the friend connects and ends it on disconnect or
  idle. Each worker runs in a Windows Job Object (CPU and memory caps,
  killed with the backend) and can only read that friend's folder. The
  owner's player process and its global engine session are never used by
  friends.
- **L2 — private library.** Upload own audio files into a per-friend folder
  with a size quota and type checks; list, play, delete. Invisible to
  everyone else.
- **L3 — friend's listening room.** The same web page (3D workspace,
  Listen, position, Original/Spatial, play/pause/seek), bound to that
  friend's worker and spatial state. The owner's page is unchanged.
- **L4 — optional live from a friend's own Chrome/Edge tab.** The tab's
  audio is captured with `suppressLocalAudioPlayback` (no double sound),
  sent up to their worker, processed, and returned. Reuses the transform
  protocol.
- **L5 — capacity.** 16-bit PCM first; Opus later. A named Cloudflare
  tunnel (stable address) instead of the temporary quick tunnel. Concurrent
  friends limited to what the measured upload supports.

**Requirements and risks.** The laptop must stay on, awake and online
whenever any friend listens. Every friend adds load and an internet-facing
account to the owner's machine, so L0/L1 need a security review before
invites go out. Friends hear their music with internet delay (fine for
music, not for lip-sync).

**Comparison with F1 (Yinwei Web on each friend's device):** F1 needs no
laptop, no accounts and no bandwidth from the owner, and isolates friends
completely; Option L lets friends use the laptop's engine from any browser
and keeps their library on the laptop. Both can coexist.

## Privacy, safety and copyright

- Friends' audio never leaves their device in F1–F3.
- Yinwei never shares or relays audio between people.
- Each friend only processes sound they already have the right to play.
- No accounts or analytics are added for F1–F2.

## Verification

- F0: CPU/latency numbers per browser recorded in this doc.
- F1/F2: automated tests for the WASM bridge and worklet (Node, like
  `audio_browser_test.mjs`), plus a real check on one iPad (Safari), one
  Android phone and one Windows PC by a friend.
- F3: install on a friend's clean PC/iPad; confirm "only spatial" with and
  without a virtual output.

## Decisions for the owner

1. Approve F0 → F1 → F2, Option L (laptop-hosted, L0 → L3 first), or both?
2. Hosting: existing EdgeOne site, GitHub Pages, or both?
3. iPad friends: pay for the Apple Developer Program (TestFlight), or rely
   on Yinwei Web?
