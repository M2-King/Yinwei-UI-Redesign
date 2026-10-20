# Listen Room speaker placement

The laptop's `EngineController.array` remains the authority. The room is a view
with temporary gesture previews. Point scene state, Rust, HRTF/DSP, Live capture,
the pinned bundle, and deployment configuration are unchanged.

## Remote contract

`AppSessionCoordinator.snapshot()` adds `arrayState`:

```json
{
  "mode": "stereo2",
  "revision": 12,
  "selectedIndex": 2,
  "matrixLinked": false,
  "matrixSpread": 1.0,
  "maxSpeakers": 8,
  "speakers": [
    {"index": 0, "label": "L", "az": -30, "el": 0, "dist": 1.8,
     "gainDb": 0, "mute": false, "feed": "left"}
  ]
}
```

The sample speaker record is abbreviated; the actual array has 2–8 records.
`capabilities.remoteSpeakers` requires the array-edit callback and existing
file array/count support; while Live runs, it also requires all three existing
Live array/speaker/count symbols. Unsupported/older hosts remain view-only.
Their existing presentation records (or legacy L/R defaults) still draw.

Commands use the existing authenticated, serialized, idempotent command route:

| Host command | Required payload |
| --- | --- |
| `array.speaker.add` | `arrayRevision` |
| `array.speaker.remove` | `arrayRevision`, `index` |
| `array.speaker.select` | `arrayRevision`, `index` |
| `array.speaker.set` | `arrayRevision`, `index`, `az`, `el`, `dist` |

Every edit retains the revision from gesture start, including across client
state/lease refresh and retry. A changed array rejects it with `stale_array`.
The revision covers layout mode, order/count, selection, poses, gain/mute/feed,
and matrix settings. A completed duplicate is returned only while its resulting
array revision is still current; after removal, even that replay is rejected.
Thus index 4 from an older revision never targets a shifted speaker.

Selection and gain/mute changes made at the laptop participate in control
fingerprinting. Laptop edits revoke the remote lease. Remote edits do not revoke
their own lease. Max count is 8, and indices 0/1 cannot be removed. Matrix-linked
pose changes use existing group deltas and shared distance. Feed/gain/mute are
preserved; added speakers use the existing Mid defaults.

The page receives `speakers`, `selectedSpeakerIndex`, `arrayRevision`,
`maxSpeakers`, `speakerControl`, and `matrixLinked` through `ListenRoomBridge`.
Its `speakerAdd`, `speakerRemove`, `speakerSelect`, and `speakerPlace` intents
map to the commands above. `bridge.js` validates bounded finite speaker records.
The page commits a drag/slider once on release. Cancellation or laptop takeover
discards its preview. Direction/elevation/distance controls remain available
for positions unsuitable for a horizontal drag.

## Native acknowledgement

`EngineController.setArrayAcknowledged` is additive and used by remote commits.
It cancels pending throttled writes and waits for the complete existing ABI
sequence. `NativeEngine.setArrayAcknowledged` checks every native return code,
including missing symbols; the old tolerant local setters remain unchanged.
The local UI still publishes immediately and uses its existing 32 ms throttle.
Live uses the existing `applyLiveArray` and checks its result. No capture path
is changed. The existing ABI has no atomic multi-speaker transaction; a native
failure is reported as failed, never `native_applied`.

## Coordinates and rendering

Reuse `assets/listen_room/room-math.js`:

- Engine/listener coordinates: +X right, +Y up, −Z front, +Z rear; ears at origin.
- Listener faces −Z, upright +Y; no head tracking. Camera rotation changes only
  the view, never the listener/audio frame.
- Azimuth: 0° front, +90° right, −90° left, ±180° rear. Elevation: 0° ear level,
  +90° overhead, −90° below. Acoustic distance is real metres, 0.5–10.
- Room axes match; ears are at `(0, 1.1, 0)` above its floor. Display radius is
  `r = 4.4 * ln(1+d)/ln(11)`, not real acoustic distance.
- `toRoom(a,e,d)` yields `(r*cos(e)*sin(a), 1.1+r*sin(e), -r*cos(e)*cos(a))`.
  Angles in this formula are radians. Snapshot real-metre `worldPosition` must
  not be placed directly in the logarithmic room.
- Drag the floor projection and use `fromRoomPoint(x,z,e)` with elevation held.
  Its existing inverse rounds direction to 1° and distance to 0.1 m. At poles
  (`abs(cos(e)) < 0.2`), retain the pose and use sliders instead of distorting
  distance. Acoustic position is never silently clamped to fit the room.

The renderer builds one cabinet/stand template and seven recursive clones at
room initialization. Cabinet geometry/material references are shared. State
ticks and drags change transforms/visibility only; they never rebuild meshes.
Only L/R cast cabinet shadows. Extra cabinets receive lighting and use the
existing floor/ripple effects. Stands follow height and hide below their usable
floor clearance. Extreme below-floor/ceiling positions may be clipped by room
surfaces, as with existing Point positions.

## Pinned file-tap gate and diagnostic

The running laptop uses `outputs/w19/windows/spatial_core.dll`:

`eb764148534b6f0df3d0de60c7b6f184fcbf5164ed7298d53a3de95bb6e8c036`

The hash was checked without loading or modifying the DLL. Source rendering
does not prove this binary's tap is post-array. File-array listening therefore
**remains disabled by default**. The small isolated `RemoteGateway` change
allows a future backend launch to opt in with environment variable
`YINWEI_ARRAY_FILE_AUDIO_VERIFIED=1`. No environment or running backend was
changed here. With the flag absent/zero, the previous file-array gate remains.
Live readiness and remote-transform restrictions are retained with either flag.

From the repository root, inspection only:

```powershell
python yinwei/apps/yinwei_player/tool/remote/check_array_file_tap.py
```

After stopping backend playback, explicitly run the audible native probe:

```powershell
python yinwei/apps/yinwei_player/tool/remote/check_array_file_tap.py --run --backend-idle
```

It validates the complete pinned hash, starts a separate child process with
private DLL globals and temporary working directory, generates a stereo WAV,
enables Spatial+2.0 with three speakers, mutes L/R, and reads the file output tap
with the third Mid voice at −90°, +90°, and muted. It discards buffering/slew and
reverb settling time, then reports L/R RMS, directional balance, mute energy
ratio, and PASS or FAIL_OR_INCONCLUSIVE. A pre-array stream or silence cannot
pass both checks. This is a diagnostic threshold, not a subjective audio test.

The probe opens the default hardware output device, so it was **not run during
backend playback**. Its hash-only mode and pure verdict tests were run. It
cannot promise inaudibility or coexistence with an exclusive output device.
Do not enable the flag on a failed/inconclusive result. Device/ear verification
remains necessary for file and Live added-speaker behavior on iPad headphones.

## Verification and rollback

Run from `yinwei/apps/yinwei_player`:

```powershell
flutter test --no-pub
node --test test/listen_room/bridge_test.mjs test/listen_room/offline_contract_test.mjs test/listen_room/room_math_test.mjs test/listen_room/speakers_test.mjs
dart analyze
flutter build windows --debug --no-pub
python -m unittest discover -s tool/remote -p test_array_file_tap_probe.py
```

Review artifact from repository root:

```powershell
python yinwei/tools/listen_room_review.py yinwei/docs/validation/listen-room-speakers/review.html
```

The review helper declares UTF-8 so legacy browser encoding cannot break
Chinese labels or Unicode script expressions. Its dev panel has 2/3/8-speaker
fixtures and uses the room's unchanged built-in speed test. Desktop GPU results
are not iPad performance measurements. Screenshots, logs and measured numbers
are retained in `docs/validation/listen-room-speakers/`.

Rollback: leave/remove the file-tap flag to retain its prior routing. The gateway
opt-in is isolated from speaker editing. Other task edits are additive Dart/
room/bridge/tests and can be reverted independently of protected audio code,
DLLs, bundles and deployment files. No commits or deployment were performed.
