# Debug report — Orbit mode stutter + electrical buzz

**Date:** 2026-09-06  
**Status:** Root cause identified; fix in `IMPLEMENTATION_ORBIT_HRIR.md`

## Symptoms

In **Orbit** motion (Spatial playback):

1. **一卡一卡** — periodic dropouts / hitching while the image rotates  
2. **电流声** — continuous metallic / electrical buzz for the whole orbit  

Fixed-mode preset slew (after dual-xfade fix) is out of scope here; this report is Orbit-only.

## Root cause

### Continuous pose → dual HRTF every chunk

`process_hrtf_path` dual-renders whenever `from ≠ to` (equal-power crossfade of two OLS convolutions). That is correct for **short** preset slews (~1 s).

In Orbit, each chunk advances phase:

```text
Δaz ≈ orbit_hz × 360° × (STREAM_CHUNK / sample_rate)
    ≈ 0.4 × 360 × 0.0107 ≈ 1.5° / chunk @ 48 kHz
```

So **every** chunk Mid (and Side / Side2 when envelopment is up) changes pose → dual-render fires ~93 times/sec, forever.

| Path | Dual when env high | Cost vs static Fixed |
|------|--------------------|----------------------|
| Mid | always in Orbit | 2× |
| Side | env > 0.05 | +2× |
| Side2 | env > 0.35 | +2× |
| **Total** | | **up to 6× HRTF / chunk** |

### Why that sounds like “电流”

Crossfading two different HRIRs every ~10.7 ms continuously mixes incompatible OLS phases (same `hrtf` 0.8 moving-source issue). At ~93 Hz update rate the artifact is perceived as a **sustained buzz**, not discrete clicks.

### Why that also “一卡一卡”

Six FFT convolutions per 10.7 ms routinely overruns the DSP worker. The ring underruns → audible stutter / hitch, on top of the buzz.

```text
Orbit chunk N:
  mid  dual OLS  ─┐
  side dual OLS  ─┼─ CPU spike → ring starved → hitch
  side2 dual OLS ─┘
  + full-chunk IR crossfade → continuous buzz
```

### What is *not* primary

- Raising `STREAM_INTERP` (already rejected; densifies buzz)  
- UI live-az polling  
- Preset snap (Orbit path independent)  
- Offline `HrtfRenderer` export path  

## Correct mitigation

**Quantize** Orbit HRTF azimuth (and matching Side angles) to a coarse step (e.g. **8°**).

- Most chunks: held pose unchanged → `from ≈ to` → **single** stable HRTF  
- When quantized step flips: **one** dual-xfade (~every 50–60 ms at 0.4 Hz)  
- Visualizer keeps **continuous** `effective_mid_azimuth_deg` (UI ball stays smooth)

```text
ideal az (continuous) ──UI──→ orb
        │
        ▼ quantize 8°
held HRTF az ──audio──→ process_hrtf_path (dual only on step)
```

## Pass criteria (ears)

1. Orbit 0.4 Hz, headphones — rotation audible, **no** continuous buzz  
2. No periodic hitch / underrun under default envelopment  
3. Fixed + preset slew still smooth (unchanged path)  
4. Status `p2.4.14-orbit-step`

## References

- `REPORT_POSE_SLEW_BUZZ.md` — why INTERP↑ and perpetual dual-xfade buzz  
- `hrtf` 0.8 — moving-source OLS phase bumps  
