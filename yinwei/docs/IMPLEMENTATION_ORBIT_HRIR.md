# Execution — Orbit HRIR step quantization

> Follows [`REPORT_ORBIT_BUZZ.md`](./REPORT_ORBIT_BUZZ.md).  
> Complements preset slew dual-xfade ([`IMPLEMENTATION_POSE_SLEW_CLICKFIX.md`](./IMPLEMENTATION_POSE_SLEW_CLICKFIX.md)).

## Goal

Orbit mode rotates the image without continuous buzz or DSP underrun hitching.

## Approach

1. Add `ORBIT_HRIR_STEP_DEG = 8.0` and `quantize_azimuth_deg(az, step)`.
2. In `HrtfStreamer::process_chunk`, when `MotionMode::Orbit`:
   - Compute continuous ideal Mid/Side azimuths (unchanged math).
   - **Render** using quantized Mid az and Side az (±110 / orbit side offsets derived from the same quantized mid or independently quantized ideal).
   - Prefer: quantize the shared `orbit_offset` (or mid az), then rebuild Side from that held offset so Mid/Side stay coherent.
3. Leave `effective_mid_azimuth_deg` on **continuous** phase for the visualizer.
4. Fixed / chase / preset slew paths unchanged.
5. Unit test: quantize helper + Orbit over N chunks keeps `prev_mid_pos` stable across adjacent chunks more often than every chunk.

### Preferred geometry

```text
orbit_offset_cont = phase.to_degrees()
mid_az_hrtf = quantize(wrap(smooth_az + orbit_offset_cont), 8°)
# Side Fixed-style offsets around quantized mid:
side_az  = mid_az_hrtf + 110°   (or existing Orbit side formula with quantized offset)
side2_az = mid_az_hrtf - 110°
```

Using one quantized mid keeps the image locked as a rigid frame that steps around the listener.

## Files

| File | Change |
|------|--------|
| `crates/spatial_core/src/hrtf_render.rs` | Step constant, quantize, Orbit render poses |
| `docs/REPORT_ORBIT_BUZZ.md` | Cause analysis |
| `docs/IMPLEMENTATION_ORBIT_HRIR.md` | This plan |
| `apps/.../engine_controller.dart` | Bridge id bump only |

## Pass criteria

1. Ears: Orbit clean at 0.4 Hz with envelopment default  
2. `cargo test -p spatial_core --features realtime` green  
3. Rebuild DLL; status `p2.4.14-orbit-step`  
4. Fixed Back→Front slew still OK  

## Non-goals

- Changing default `orbit_hz`  
- Batch B / product UI  
- Offline export orbit smoothing  
