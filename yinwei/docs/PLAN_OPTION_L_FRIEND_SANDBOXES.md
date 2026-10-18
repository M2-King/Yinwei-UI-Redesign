# Option L — friends hear their own music, processed on the owner's laptop

Date: 2026-10-18 · Status: **approved (D1 additive worker API, D2 4 friends / 2 GB / 200 MB, D3 one-time 24 h invites, D4 32-bit). L0 built behind `YINWEI_GUEST_ENABLED` (off); stopped at Gate A.**
Scope approved in principle: L0–L3. Owner rule: *the owner's own engine and
Live Transfer stay untouched; stop for approval before any
security-sensitive step goes live.*

## 1. Outcome

- Each friend opens one link, signs in with their **own** account, uploads
  **their own** audio files into a private library, and listens in a
  Listening room with their **own** position, Original/Spatial and
  play/pause/seek.
- Each friend's audio is processed in **their own sandbox process** on the
  laptop and streamed only to them. Friends cannot see, hear or control the
  owner or each other.
- The owner's player, engine (verified `spatial_core.dll`
  `eb764148…8c036`), Live Transfer, routing and iPad listening behave
  exactly as in w8.

## 2. Current system (inspected)

| Area | Today | Consequence |
|---|---|---|
| Accounts (`remote_auth.dart`) | One provisioned `owner`; salted-hash login; max 8 sessions; rate-limited sign-in | Guests need a separate account store; owner login unchanged |
| Gateway (`remote_gateway.dart`) | Owner API under `/remote/api/*`; one browser audio socket (`audio_busy`); control lease via `AppSessionCoordinator` | Guest routes must be separate and role-checked |
| Engine in the player | One global `PlayerSession`, one remote-ingress slot | Friends must **not** use it: separate processes |
| Engine API | `LiveIngress` (no audio device) renders 10 ms blocks with live `set_params` / `set_mode` / `set_eq` / `set_array`, but it is crate-internal; the exported `yinwei_remote_ingress_*` C functions snapshot settings at start | See decision D1 |
| Browser audio | `audio-client.js` + `audio-worklet.js` play YNW1 packets with the adaptive buffer | Reused unchanged for friends |
| Capacity (measured) | ~2% of one core per listener (Ryzen 9 8945HX, 16 cores) | Bandwidth, not CPU, limits friends (~3.1 Mbps each today) |

## 3. Architecture

```text
Friend's browser (guest.html)
   │ HTTPS / WSS through the existing Cloudflare tunnel + entry Worker
   ▼
Owner's Yinwei player process (Dart gateway)
   ├─ owner routes  /remote/api/*        → unchanged (owner engine, Live Transfer)
   └─ guest routes  /remote/guest/*      → GuestStore, GuestLibrary, WorkerPool
                                              │ stdin: JSON commands
                                              │ stdout: framed YNW1 audio packets
                                              ▼
                         yinwei_worker.exe — ONE process per active friend
                           • Job Object: memory cap, CPU-rate cap,
                             kill-on-close, no child processes
                           • reads only that friend's library folder
                           • decode (symphonia) → paced 10 ms blocks →
                             LiveIngress (HRTF/EQ/reverb) → YNW1 packets
```

- **Isolation boundaries:** separate OS process per friend; per-friend
  folder; role checks on every route; per-friend WebSocket tickets bound to
  their session; the owner's process never loads a friend's file.
- **Lifetime:** the worker starts when the friend opens the room and exits
  on disconnect, after 10 minutes idle, when revoked, or when the owner's
  player exits (stdin closes, plus a parent-process check, the same pattern
  that fixed the SMTC daemon leak).
- **Feature flag:** `YINWEI_GUEST_ENABLED` (default off). With it off, the
  bundle behaves exactly like w8.

## 4. Decisions needed from the owner

| # | Decision | Recommended | Alternative |
|---|---|---|---|
| D1 | Engine access for workers | **Additive, worker-only API**: make `LiveIngress` usable from the new `yinwei_worker` crate (expose, no behaviour change). The owner's player keeps the verified DLL `eb764148…`; it is **not** rebuilt | **No engine source change**: workers use the exported C functions and restart processing on each position change (short gap, position applied on release, not while dragging) |
| D2 | Limits | 4 friends at once; 2 GB library per friend; 200 MB per file; MP3/M4A/AAC/FLAC/WAV/OGG only | Your numbers |
| D3 | Invites | Owner creates one-time links, valid 24 h, from the laptop only; owner can revoke any friend | — |
| D4 | Stream format | Keep 32-bit (~5 friends on 20 Mbps up); 16-bit later (L5) | 16-bit now |

## 5. Phases (each ends with tests; none goes live without its gate)

### L0 — guest accounts and invites (local only)
- `GuestStore`: per-friend id, display name, salted password hash (same
  scheme and cost as the owner), created/revoked time, quotas. Stored in
  the private runtime directory; never in Git.
- Invites: one-time token (hashed at rest), 24 h expiry, created by a
  laptop-only command/UI, never via the public API.
- Sign-in: `/remote/guest/signin` with the existing rate limits; separate
  cookie name; sessions carry `role: guest` + guest id.
- Every owner route rejects guest sessions; every guest route rejects owner
  and other guests' resources (central check + tests).
- **Gate A** — owner approves before guest sign-in is reachable through the
  public tunnel.

**L0 status (2026-10-18).** Built and verified locally, not deployed:
`lib/remote/remote_guest.dart` (store, invites, guest sessions, routes),
gateway dispatch for `/remote/guest/*` (404 while the flag is off),
`assets/remote/guest.html` + `guest.js`, and the laptop-only tool
`tool/remote/guest_admin.dart` (`invite`, `list`, `revoke`). Tests: 11 new
(single-use hashed invites, 24 h expiry, unique names, validation, caps,
revocation, owner↔guest separation, CSRF/Origin); full suite 614 passed.
Real browser check on a loopback test server: invite → account → room,
sign out/in, owner API refused to the guest, reused invite refused.

**Still needed to pass Gate A (each needs owner approval):**
1. Launcher: pass `YINWEI_GUEST_ENABLED=1` to the player
   (`Start-YinweiRemote.ps1` sets the player's environment).
2. Stable friend address: today the tunnel address changes on every
   restart, so invite links and friends' bookmarks break. Add a `/friends`
   route to the fixed entry Worker (a Cloudflare deploy) that redirects to
   the current origin's `/remote/guest/…`, keeping the `#token` fragment.
3. Build and switch to a new laptop bundle (w9) with the flag on.

### L1 — sandbox worker (`yinwei_worker.exe`)
- New Rust binary crate; per D1.
- Commands (JSON lines): `open {fileId}`, `play`, `pause`, `seek {ms}`,
  `params {az, el, dist, motion, orbitHz}`, `mode {original|spatial}`,
  `stop`. Replies: status JSON lines; audio: length-prefixed YNW1 packets.
- Real-time pacing with a ~200 ms lead; output credit like the existing
  audio pump, so a slow friend cannot grow memory.
- Path confinement: the worker receives the friend's folder at start and
  refuses any path outside it (canonicalized prefix check), in addition to
  the gateway's own check.
- Job Object: e.g. 512 MB memory, 10% CPU rate, kill-on-close,
  no breakaway; process exits when stdin closes or the parent PID is gone.
- `WorkerPool` (Dart): starts/stops workers, enforces the D2 concurrency
  cap, forwards audio to the friend's socket, restarts a crashed worker.

### L2 — private library
- Upload: streamed to a temp file, size and type checked (header sniff, not
  just extension), quota checked, stored under a random id; original name
  kept as metadata only.
- List / delete / rename for the friend's own files only.
- Storage: `<private runtime>/guests/<guestId>/library/` (outside the repo
  and outside the owner's media).
- **Gate B** — owner approves before uploads are reachable publicly.

### L3 — friend's Listening room
- `guest.html` + `guest.js`, reusing `workspace.js`, `audio-client.js`,
  `audio-worklet.js` and the current styling.
- Library panel, transport (play/pause/seek), position sliders, 3D drag,
  Original/Spatial, Listen/Stop, sign out. No owner controls, no Live
  Transfer, no other friends visible.
- **Gate C** — security review (section 7) passed and owner approves
  issuing the first invite.

## 6. Verification

- **Owner regression:** the full existing suite passes; the owner's
  bundle DLL hash stays `eb764148…`; with the flag off, a w8 smoke check;
  Live Transfer and iPad listening re-tested by the owner.
- **L0:** unit tests for invites (expiry, single use, hashing), sign-in rate
  limits, role separation on every route (owner→guest, guest→owner,
  guest A→guest B).
- **L1:** Rust tests for the protocol, pacing (no drift over 10 min), live
  parameter changes, path confinement, Job Object limits, exit on stdin
  close/parent exit; Dart tests for `WorkerPool` caps and restart.
- **L2:** upload size/type/quota limits, traversal names, partial uploads,
  delete isolation.
- **L3:** browser tests like `audio_browser_test.mjs`; a local end-to-end
  run on `127.0.0.1` with fixture accounts (two guests + owner, three
  different files at once).
- **Real check before Gate C:** one real friend on another network.

## 7. Security review checklist (Gate C)

Password hashing and lockout; invite token entropy and single use; cookie
flags; CSRF on state-changing guest routes; per-session WebSocket tickets;
role checks centralised and tested; path traversal and symlinks; upload
limits and type sniffing; worker resource caps; no secrets or file paths in
logs or error messages; revoke kills sessions and workers immediately;
`YINWEI_GUEST_ENABLED=0` fully disables the guest surface.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Upload bandwidth runs out | Concurrency cap (D2); 16-bit/Opus in L5 |
| Laptop off/asleep → friends offline | Stated limitation; status page shows offline |
| Quick-tunnel address rotates | Existing fixed entry Worker; named tunnel in L5 |
| A friend uploads content they don't own | Terms note on the page; private-only playback, no sharing between people |
| Bugs in the guest surface | Feature flag off by default; gates A–C; separate processes |
| D1 alternative chosen | Position applies on release with a short gap; documented in the UI |

## 9. Rollback

Each phase is its own commit on `codex/ios-capture-ci`. Turning the flag off
removes the guest surface without a rebuild; switching the backend config
back to w8 restores today's bundle exactly. Guest data lives only in the
private runtime directory and can be deleted as one folder.

## 10. What happens after approval

1. Owner answers D1–D4.
2. Build L0 → L3 behind the flag, with tests, committing per phase.
3. Stop at Gate A, Gate B and Gate C for explicit approval; nothing is
   reachable by friends before Gate A.
