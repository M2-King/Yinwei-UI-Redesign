# Debug report — continuous buzz during pose slew

**Date:** 2026-09-06  
**Status:** Root cause identified; fix tracked in `IMPLEMENTATION_POSE_SLEW_CLICKFIX.md`

## Symptoms

| Stage | Audible artifact |
|-------|------------------|
| After pose slew landed (snap → angular slew) | Stepped “一卡一卡” clicks while rotating (Back→Front) |
| After `STREAM_INTERP=4` + 64-sample wet crossfade | **Continuous** electrical buzz for the whole transition |

## Root cause

### Mechanism (hrtf 0.8)

Realtime path uses `HrtfProcessor::process_samples` (overlap-save FFT convolution).  
When the HRIR changes between OLS blocks, each impulse response has a different phase → amplitude “bumps”. The crate documents this as clicks that sound like **buzzing** on moving sources (esp. tonal material).

With `interpolation_steps = N`, each chunk is split into N sub-blocks; sub-step `i` uses:

```text
t = (i+1) / N
sampling_vector = lerp(prev, new, t)
```

So the filter is **replaced N times per chunk**.

### Why INTERP=1 clicked (stepped)

| Setting | Effect |
|---------|--------|
| `STREAM_BLOCK=512`, `INTERP=1` | One HRIR per ~10.7 ms chunk; `t=1.0` → uses **new** pose only |
| Pose slew ~180°/s | ~2° HRIR change every chunk |
| Result | Discrete zipper / click at ~93 Hz block rate → “一卡一卡” |

Wet 64-sample crossfade only softened the **chunk boundary**, not the underlying OLS phase jump enough for all material.

### Why INTERP=4 became continuous buzz

| Setting | Effect |
|---------|--------|
| `STREAM_BLOCK=128`, `INTERP=4` | **Four** HRIR swaps per 10.7 ms (~375 Hz) |
| Same slew | Filter morphs through 4 phase jumps *inside* every chunk |
| 64-sample wet xfade | Only covers samples `0..64`; discontinuities at 128 / 256 / 384 untouched |

So the stepped artifact was densified into a **sustained** buzz for the entire ~1 s Back→Front path. This matches “电流声变成持续性的了”.

```text
Chunk (512 samples)
├── step0 [0..128)   HRIR @ t=0.25  ← phase bump
├── step1 [128..256) HRIR @ t=0.50  ← phase bump
├── step2 [256..384) HRIR @ t=0.75  ← phase bump
└── step3 [384..512) HRIR @ t=1.00  ← phase bump
     ↑
   wet xfade only here (first 64)
```

### What is *not* the primary cause

- Ring underrun / “卡一下” from flushing (already avoided)
- Dart UI polling live az/el
- Reverb / air LP alone (artifacts track HRIR swaps)
- Sharing one `HrtfProcessor` across Mid/Side (histories are per-source `prev_*`; known prior Mid-double-render bug was fixed separately)

## Correct mitigation

Do **not** increase `interpolation_steps` to hide motion clicks. That multiplies OLS IR swaps.

Industry / crate-aligned approach:

1. Keep **stable** HRIR for a given `process_samples` call (`prev_sample_vector == new_sample_vector`).
2. On pose change, render the **same dry block twice** (old pose + new pose) with restored convolution history between passes.
3. **Equal-power crossfade** the two wet HRTF outputs over the chunk (or a long window).
4. Continue convolution history from the **new** pose path only.

Optional: slightly lower slew rate so dual-render runs less often; not required if every moving chunk crossfades.

## Verification plan

1. Unit: dual-render path does not panic; slew still converges.
2. Ears: Back→Front tonal / music — no continuous buzz; no hard mute.
3. Static Fixed pose — CPU/quality unchanged (single process).
4. Status: `p2.4.13-dual-xfade` (or newer).

## References

- `hrtf` 0.8 module docs — “Known problems” (moving-source buzz)
- Csound Journal — HRTF opcodes short crossfade recommendation
- Time-varying FIR / dual-engine IR crossfade (overlap-save)
