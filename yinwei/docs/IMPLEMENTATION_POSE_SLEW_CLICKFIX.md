# Execution — click-free pose slew (dual HRTF crossfade)

> Follows [`REPORT_POSE_SLEW_BUZZ.md`](./REPORT_POSE_SLEW_BUZZ.md).  
> Supersedes the `STREAM_INTERP=4` attempt in pose-slew click mitigation.

## Goal

Keep angular slew (Back→Front ~1 s) **without** stepped clicks or continuous buzz.

## Approach

1. **Revert** streamer to `STREAM_BLOCK=512`, `STREAM_INTERP=1` (chunk = 512).
2. **Remove** wet block-boundary xfade (insufficient; interacts poorly with INTERP>1).
3. When Mid (and Side) render pose moves beyond epsilon:
   - Clone Mid/Side convolution histories
   - `process_samples` once with `prev=new=old_pos`
   - Restore histories
   - `process_samples` once with `prev=new=new_pos`
   - Equal-power crossfade the two stereo buffers over the full chunk
   - Keep history from the **new** path
4. When pose static: single `process_samples` (`prev=new=pos`).
5. Leave slew rates as-is unless ears still demand slower motion.

```text
input chunk
    ├─ HRTF(old_pos) ─┐
    │                 ├─ eq-power xfade ─→ mid_out
    └─ HRTF(new_pos) ─┘   (history continues on new)
```

## Files

| File | Change |
|------|--------|
| `crates/spatial_core/src/hrtf_render.rs` | Revert INTERP; dual-render helper; drop wet xfade state |
| `docs/REPORT_POSE_SLEW_BUZZ.md` | Cause analysis (done) |
| `docs/IMPLEMENTATION_POSE_SLEW.md` | Point to this fix |
| `apps/.../engine_controller.dart` | Bump bridge id |

## Pass criteria

1. Headphones: Back→Front — smooth orbit, **no** continuous buzz, **no** hard zipper
2. Static preset — clean (single HRTF path)
3. Drag small angles — still chase-smoothed, no new artifacts
4. `cargo test -p spatial_core --features realtime` green
5. Rebuild DLL; status `p2.4.13-dual-xfade`

## Non-goals

- Dual full `HrirSphere` residency
- Changing offline `HrtfRenderer` export path
- Exposing slew UI knobs
