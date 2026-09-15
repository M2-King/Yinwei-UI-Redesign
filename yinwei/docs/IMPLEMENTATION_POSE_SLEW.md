# Pose slew — smooth preset transitions

> Replaces hard-cut HRTF snaps on large azimuth/elevation jumps (e.g. Back → Front)
> with a shortest-path angular slew so the image rotates around the listener.

## Problem

Preset chips write `azimuthDeg` / `elevationDeg` / `distanceM` instantly. Live
`HrtfStreamer` treated `|Δaz| > 35°` (or large el/dist) as a **snap**: copy target
pose and reset `prev_*` HRTF vectors in one block. Back ↔ Front is 180°, so the
image teleports instead of circling.

Small slider/drag moves already chased smoothly (~35% per block). Orbit mode is
continuous motion around a fixed base azimuth — unrelated to preset-to-preset
blending.

## Goals

| Goal | Spec |
|------|------|
| Audible path | Large preset jumps slew along **shortest azimuth arc** (and el/dist rates) |
| No click / underrun | Do **not** flush the audio ring; keep block HRIR `prev→new` blend |
| Drag feel | Sub-threshold moves keep the existing exponential chase |
| UI / ear sync | Visualizer follows **live smoothed** az/el while slewing |
| Offline export | Unchanged — `HrtfRenderer` stays instantaneous per params |
| Init / new track | Snap once so play does not slew from defaults |

Non-goals (this slice): user-selectable CW/CCW preference; export-time path
animation; Dart-only tween that double-interpolates against DSP.

## Design

### Target vs smooth

```
UI / Engine params     = TARGET  (instant on preset tap)
HrtfStreamer.smooth_*  = CURRENT (slews or chases toward target each chunk)
Visualizer             = CURRENT (poll live pose while playing Spatial)
```

### Per-chunk policy (`process_chunk`)

```
daz = shortest_path(target_az − smooth_az)   // wrap to (−180, 180]
del = target_el − smooth_el
ddist = target_dist − smooth_dist
dt = STREAM_CHUNK / sample_rate

if |daz| > 35° OR |del| > 25° OR |ddist| > 1.5 m:
    // Preset / big jump — rate-limited slew (no prev_* reset)
    smooth_az  += clamp(daz,  ±SLEW_AZ·dt)
    smooth_el  += clamp(del,  ±SLEW_EL·dt)
    smooth_dist += clamp(ddist, ±SLEW_DIST·dt)
else:
    // Continuous drag — existing chase
    smooth_* += delta * 0.35

// env / rev always chase (never snap with pose)
```

Default rates (tunable constants in `hrtf_render.rs`):

| Axis | Rate | Back→Front (~180°) |
|------|------|--------------------|
| Azimuth | 180 °/s | ~1.0 s |
| Elevation | 90 °/s | Overhead ~0.8 s |
| Distance | 3 m/s | typical preset Δ ~0 s |

### Snap only when

- DSP worker starts (`HrtfStreamer::new` + `snap_to_params` from live params)
- Track load recreates the worker

Seek / Original↔Spatial soft switch: keep smooth pose (filters may reset).

### Live pose → UI

DSP publishes `live_az` / `live_el` (effective mid azimuth includes orbit offset).
`yinwei_current_azimuth_deg` / `yinwei_current_elevation_deg` read those while
Spatial streaming is active; otherwise fall back to Engine target (+ orbit phase).

Flutter `EngineController` tick polls both and drives `OrbitVisualizer`.

## Files

| Layer | Change |
|-------|--------|
| `docs/IMPLEMENTATION_POSE_SLEW.md` | This plan |
| `crates/spatial_core/src/hrtf_render.rs` | Slew + `snap_to_params`; dual HRTF crossfade (`process_hrtf_path`) |
| `crates/spatial_core/src/playback.rs` | Publish live pose; init snap; comment update |
| `crates/spatial_core/src/session.rs` / `lib.rs` / `ffi.rs` / `frb_api.rs` | Elevation query + prefer live pose |
| `apps/yinwei_player/lib/bridge/*` | Bind elevation; controller poll |
| `apps/yinwei_player/lib/screens/player_screen.dart` | Visualizer uses live elevation |

## Click / buzz during slew

See [`REPORT_POSE_SLEW_BUZZ.md`](./REPORT_POSE_SLEW_BUZZ.md) and
[`IMPLEMENTATION_POSE_SLEW_CLICKFIX.md`](./IMPLEMENTATION_POSE_SLEW_CLICKFIX.md).

**Do not** raise `STREAM_INTERP` to hide motion clicks — that turns zipper into
continuous buzz. Use dual-render equal-power crossfade (`process_hrtf_path`)
with `INTERP=1`.

## Pass criteria

1. Headphones: Fixed mode, Back → Front — image rotates ~1 s, no mute / underrun
2. Adjacent presets (e.g. Left → Left Front) still feel snappy (chase path)
3. Drag on orbit ball remains responsive
4. Orb moves with the audible path during a large preset jump
5. Export WAV still matches target preset instantly (no long path at start of file)
6. `cargo test -p spatial_core` passes (incl. slew unit tests)

## Tune later (optional)

- Expose slew rates on `SpatialParams` / UI
- Forced rotation direction when `|daz| ≈ 180°`
- Match visualizer trail during slew (treat as temporary “orbiting”)
