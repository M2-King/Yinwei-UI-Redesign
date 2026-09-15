# SpeakerSemanticsV1

Honest description of **current** engine loudspeaker semantics for the Spatial Scene Domain.

Schema id: `SpeakerSemanticsV1`  
Schema version: `1`

This document does **not** invent future routing. True discrete multichannel / 7.1 decode is **out of scope** for Phase 1A and is not specified here.

---

## 1. Input

| Fact | Value |
|------|--------|
| File / Live input | **stereo** |
| Channel count | **2** (`L`, `R`) |
| Discrete 5.1 or 7.1 decode of a surround file | **not implemented** |

There is no 7.1 input path in `spatial_core` today.

---

## 2. Acoustic feeds (what actually drives HRTF)

Virtual-speaker **audio** feeds are only:

| Feed | Integer (FFI) | Mono sent into that speaker’s HRTF |
|------|---------------|-------------------------------------|
| `Left` | 0 | left input channel |
| `Right` | 1 | right input channel |
| `Mid` | 2 | \((L+R)/2\) at about −3 dB (`0.5 * 0.707` in the streamer) |

These are `SpeakerFeed` in `spatial_core` `layout.rs` and Dart `ArraySpeaker.feed`.

There is **no** acoustic `Center`, `LFE`, `Surround`, `Side`, or `Rear` feed in the current engine.

---

## 3. Array modes (current)

| Mode | Integer | Meaning |
|------|---------|---------|
| `Off` (Point) | 0 | Default. Single point-source Mid HRTF + envelopment. Array voices are not the Point path. |
| `Stereo2` | 1 | Discrete virtual speakers fed from stereo as in §2. **Not** a 7.1 decoder. |

`ArrayMode::from_i32` rejects any other value. There is no `ArrayMode::Surround51` or `ArrayMode::Surround71` in the engine.

Default layout storage: Point **off**, with a stereo 2.0 pose pair remembered at **±30°**, **1.8 m**, feeds Left / Right.

Extra slots above two, when count is raised toward `MAX_SPEAKERS = 8`, are created as **`Mid`** feeds at 0° — still stereo-derived, not discrete surround channels.

---

## 4. Visual roles must not imply routing

The Spatial Workspace may show **eight** physical 3D emitter objects with ITU-ish labels:

`L`, `R`, `C`, `LFE`, `Ls`, `Rs`, `Lb`, `Rb`

Those labels are **visual / interactive layout** (`VisualSpeaker` in Dart, Three.js `DEFAULT_SPEAKERS`). They do **not** mean:

- a Center channel bus
- an LFE / .1 bass-management decoder
- discrete Rear or Side channel routing
- that the engine is running 7.1

Product copy and Inspector fields must not say “7.1 decode” or “discrete Center/LFE/Rear/Side audio” while SpeakerSemanticsV1 is in force.

Eight emitters **may** exist in SceneContractV1 as `type: emitter` with optional `visualRole`. Acoustic feed, if any, lives in **audio configuration**, not in the scene document.

---

## 5. What Stereo2 actually does (current, not a promise to redesign)

When `ArrayMode::Stereo2` is on, the streamer:

- splits the **same stereo** stream
- optional mild L/R crossfeed on the 2.0 pair
- renders each **unmuted** layout slot through HRTF using that slot’s `SpeakerFeed`
- mixes to headphone stereo
- does **not** decode a 7.1 file into eight discrete channels

This is **virtual speakers on headphones**, not a room of hardware outputs, not Windows 7.1 endpoint routing.

---

## 6. Out of scope for Phase 1A

- True multichannel / 7.1 routing
- New feeds (`Lfe`, `Surround`, …)
- New array modes
- Changing `YinweiParamsC` or `layout.rs`
- Binding eight visual objects to eight discrete buses

Later phases may extend SpeakerSemantics with a new version (`V2`). They must not silently overload V1 labels.
