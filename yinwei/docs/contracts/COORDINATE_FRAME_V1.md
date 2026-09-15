# CoordinateFrameV1

Versioned spatial frame for the **Spatial Scene Domain**.

This document is the source of truth for signs, wrapping, quaternions, and pose-layer names. It does not change `spatial_core`, HRTF, DSP, or the Flutter UI.

Schema id: `CoordinateFrameV1`  
Schema version: `1`

---

## 1. World axes (right-handed)

| Axis | Direction | Listener at identity |
|------|-----------|----------------------|
| **+X** | right | listener right |
| **+Y** | up | listener up |
| **−Z** | forward | listener forward |
| **+Z** | rear | listener back |

The frame is **right-handed**: \(X \times Y = Z\).

Distance unit: **metres**.

This matches the existing engine comment in `hrtf_render.rs` (`spherical_to_vec`) and the Three.js workspace pose helper. Three.js world axes are the same Y-up, −Z-forward metre frame. Quaternion **storage order** is not the same (see §4).

---

## 2. Spherical pose (listener-local)

Given a point in **listener-local** metres \((x, y, z)\):

\[
\begin{aligned}
r &= \sqrt{x^2 + y^2 + z^2} \\
\text{azimuth} &= \operatorname{atan2}(x,\ -z) \\
\text{elevation} &= \operatorname{asin}(\operatorname{clamp}(y / r,\ -1,\ 1))
\end{aligned}
\]

Azimuth and elevation are stored in **degrees**.

| Quantity | Value | Cartesian (distance \(d > 0\)) |
|----------|-------|--------------------------------|
| azimuth \(0°\) | front | \((0,\ 0,\ -d)\) |
| azimuth \(+90°\) | right | \((d,\ 0,\ 0)\) |
| azimuth \(-90°\) | left | \((-d,\ 0,\ 0)\) |
| azimuth \(\pm 180°\) | rear | \((0,\ 0,\ +d)\) after wrap (`+180°`) |
| elevation \(+\) | up | \(+Y\) |
| elevation \(-\) | down | \(-Y\) |
| elevation \(+90°\) | overhead pole | \((0,\ +d,\ 0)\) |
| elevation \(-90°\) | below pole | \((0,\ -d,\ 0)\) |

Inverse (pose → listener-local / identity-world):

\[
\begin{aligned}
x &= d \sin(\mathrm{az}) \cos(\mathrm{el}) \\
y &= d \sin(\mathrm{el}) \\
z &= -d \cos(\mathrm{az}) \cos(\mathrm{el})
\end{aligned}
\]

---

## 3. Listener acoustic origin and orientation

- The listener **acoustic origin** is the **ear midpoint** (not a camera, not an eye point).
- Identity orientation: local axes coincide with world axes in §1.
- Orientation is a **unit quaternion** that rotates **listener-local vectors into world**:

\[
\begin{aligned}
\mathbf{f}_\text{world} &= R(q)\,(0,0,-1) && \text{forward} \\
\mathbf{r}_\text{world} &= R(q)\,(1,0,0) && \text{right} \\
\mathbf{u}_\text{world} &= R(q)\,(0,1,0) && \text{up}
\end{aligned}
\]

Right-handed yaw about **+Y**: a positive yaw rotates facing from −Z toward **−X** (world left). Facing world **+X** (product “right”) is yaw **−90°**.

Current `spatial_core` playback assumes a **fixed identity listener at the world origin**. That is an engine projection, not part of this contract’s runtime. Phase 1A does not move the engine listener.

---

## 4. Quaternion component order and normalization

**Storage / JSON / FFI-bound structs** use Hamilton order:

```text
(w, x, y, z)
```

| Index | Component | Meaning |
|-------|-----------|---------|
| 0 | `w` | real / scalar |
| 1 | `x` | i |
| 2 | `y` | j |
| 3 | `z` | k |

Identity: `(1, 0, 0, 0)`.

**Normalization**

1. \(n = \sqrt{w^2+x^2+y^2+z^2}\)
2. If \(n < 10^{-12}\): the quaternion is **degenerate**. Scene validation **rejects** it. Pure math helpers used in tests fall back to identity so conversions remain defined.
3. Otherwise divide `(w,x,y,z)` by \(n\).
4. Do not flip hemisphere (`w < 0`) in V1; interpolation of orientation is out of scope for Phase 1A.

**Three.js:** `THREE.Quaternion` construction order is `(x, y, z, w)`. Mapping is reorder-only, not a different frame:

```text
three.js (x, y, z, w)  ↔  CoordinateFrameV1 (w, x, y, z)
```

---

## 5. World ↔ listener-local

Listener pose: world position \(\mathbf{p}_L\), unit quaternion \(q\).

World point \(\mathbf{p}_W\) → listener-local:

\[
\mathbf{p}_\text{local} = R(q^{-1})\,(\mathbf{p}_W - \mathbf{p}_L)
\]

For a unit quaternion, \(q^{-1} = q^* = (w, -x, -y, -z)\).

Listener-local → world:

\[
\mathbf{p}_W = \mathbf{p}_L + R(q)\,\mathbf{p}_\text{local}
\]

Azimuth / elevation / distance are **always** computed from \(\mathbf{p}_\text{local}\), never from raw world coordinates when the listener is translated or rotated.

---

## 6. Azimuth wrapping

Canonical range: **\((-180^\circ,\ 180^\circ]\)**.

```text
while az > 180:  az -= 360
while az <= -180: az += 360
```

So `+180` is kept and `-180` becomes `+180`. This matches `spatial_core::hrtf_render::wrap_azimuth_deg`. Do not use language `%` operators; JavaScript `%` is signed and disagrees.

---

## 7. Shortest-arc interpolation (azimuth)

```text
delta = wrap_signed(to - from)   # into [-180, +180]
az(t) = wrap(from + t * delta)   # t in [0, 1]
```

`wrap_signed` uses:

```text
while d > 180:  d -= 360
while d < -180: d += 360
```

Crossing ±180° uses the same wrap: `170° → −170°` is **+20°** (through rear), not −340°. A half-turn is \(\lvert \delta \rvert = 180^\circ\). V1 keeps the sign produced by the wrap above (`0° → 180°` yields `+180°`; `180° → 0°` yields `-180°`). Arc length is the same.

Elevation is interpolated linearly in degrees and then clamped to \([-90,\ 90]\). Distance is interpolated linearly in metres (geometric). DSP distance clamps are a later projection step, not this interpolation.

---

## 8. Elevation poles

When the horizontal radius \(h = \sqrt{x^2 + z^2} < 10^{-8}\) metres:

- elevation is \(+90°\) if \(y > 0\), \(-90°\) if \(y < 0\), \(0°\) if \(y = 0\) (zero-distance case)
- azimuth **cannot be recovered** from the vector; cartesian → spherical reports **`0°`**
- spherical → cartesian at \(\lvert el \rvert = 90°\) yields \((0,\ \pm d,\ 0)\) regardless of azimuth
- unit HRTF direction is `(0, ±1, 0)`

Near-pole samples (\(\lvert el \rvert \approx 90°\) but \(h \ge 10^{-8}\)) keep `atan2` azimuth. Do not spin azimuth during interpolation just because \(h\) is small; Phase 1A tests check conversion, not a pole-safe slerp.

---

## 9. Zero-distance behaviour

If \(r < 10^{-9}\) metres:

| Output | Value |
|--------|--------|
| geometric distance | `0` |
| azimuth | `0°` (convention) |
| elevation | `0°` (convention) |
| listener-local / world offset | `(0, 0, 0)` |
| **HRTF unit direction** | **`(0, 0, −1)` listener-forward** — not derived from the zero vector |
| **DSP distance** | **not taken from geometric 0** |

A zero-length direction must never be passed to HRTF. Distance is a separate DSP parameter.

**Engine note (protected, unchanged):** `spatial_core` `normalize()` currently maps length \(< 10^{-6}\) to `(0, 0, +1)` (+Z = rear). CoordinateFrameV1 does **not** adopt that fallback. Do not “fix” the engine in Phase 1A.

**UI helper note:** `spatial_math.dart` `xyzToPose` currently substitutes `distanceM = 0.5` at the origin. That is a UI clamp, not this contract.

---

## 10. HRTF unit direction vs DSP distance

Rust HRTF (`hrtf` crate via `HrtfContext`) consumes a **unit direction vector**. Distance gain / air absorption are **independent DSP**.

| Vector | Unit? | Length meaning |
|--------|-------|----------------|
| world position | no | metres in the scene |
| listener-local position | no | metres relative to the ear midpoint |
| HRTF direction | **yes** | orientation only; length must be 1 |
| DSP distance | scalar | metres after engine clamp, currently `[0.5, 10]` |

```text
hrtfUnit = normalize(listenerLocal)     # except zero-distance → (0, 0, −1)
dspDistanceM = independent scalar       # projection / clamp happens later
```

`spherical_to_vec(az, el)` in `spatial_core` already returns a unit vector (distance is applied separately as `distance_gain`). CoordinateFrameV1 agrees with that split.

---

## 11. Pose layers (do not collapse)

These are different values. Scene contract stores **requested** geometric pose only.

| Layer | Owner | Meaning |
|-------|--------|---------|
| **World position** | Spatial Scene Domain | metres in CoordinateFrameV1 |
| **Listener-local position** | derived | world − listener, then un-rotate |
| **Requested pose** | scene / UI write | the pose the user or preset asked for |
| **Smoothed audible pose** | `spatial_core` slew / chase | what is moving toward the request each audio chunk |
| **Quantized HRTF pose** | `spatial_core` HRIR step | currently 8° azimuth (orbit / array), elevation step in the streamer |
| **HRTF unit direction** | engine HRTF | unit vector from quantized spherical pose |
| **DSP distance** | engine distance / air | scalar, clamped, not the vector length after normalize |

Phase 1A does not implement slew, quantize, or DSP projection. Tests must not call into `HrtfStreamer`.

---

## 12. What this contract is not

- Not a second audio engine
- Not Three.js camera space (camera is UI)
- Not `SpatialParams` (that is audio configuration)
- Not permission to change `spatial_math.dart` or `scene.js` in Phase 1A
