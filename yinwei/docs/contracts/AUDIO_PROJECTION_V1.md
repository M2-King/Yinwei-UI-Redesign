# AudioProjectionV1 (Phase 1B)

Pure function from a `SceneContractV1` snapshot plus **outside-the-scene** binding config to current-engine-compatible spatial values.

It does **not** call `EngineController`, FFI, WebView, or UI.

```
Scene snapshot + AudioProjectionConfigV1
        → AudioProjectionV1.project
        → point-source azimuth/elevation/distances
        → optional emitter slots (Left / Right / Mid only)
```

## Source binding

The engine has one point source. Config must set `pointSourceId`.

- Lookup is by **stable object id**
- Never `sources.first`
- Missing id → `sourceMissing` (no silent substitute)

## Listener

World source position is converted with CoordinateFrameV1:

world − listener origin → inverse listener quaternion → listener-local → HRTF unit + spherical pose.

The DSP engine is still assumed to hear in listener-local space. Listener motion is **not** moved into `spatial_core` in this phase.

Quaternions stay `(w, x, y, z)` and are normalized before use.

## enabled / active

| Flags | Point-source result |
|-------|---------------------|
| `enabled == false` | `sourceDisabled` — administratively unavailable |
| `enabled == true` and `active == false` | `sourceInactive` — present, not acoustically active |
| both true | projected |

Mute remains outside SceneContractV1.

## Distance

| Quantity | Policy |
|----------|--------|
| `geometricDistanceM` | unclamped scene metres (`0` at coincidence) |
| `dspDistanceM` | clamp to `[0.5, 10.0]` |

Zero-length geometry: HRTF unit is `(0, 0, −1)` (listener-forward). `spatial_core::normalize` still uses `(0, 0, +1)` and is **not** changed.

## Invalid scene

If `validateSceneV1` fails (`pointSourceStatus = invalidScene`):

- `emitterSlots = []`
- the validation `reason` is preserved (`forbidden_key`, `missing_listener`, …)
- emitters are **not** partially projected
- `failedUnknownEmitter` is **not** used merely because the scene was invalid

## Emitters

Bindings are `emitterId → left|right|mid` only.

- No binding → emitter produces **no** acoustic slot
- `visualRole` (`C`, `LFE`, Rear, Side, …) never implies a bus
- List order never implies routing
- Unknown emitter id → `failedUnknownEmitter`
- Invalid feed name → `failedInvalidFeed`

Emitter projection results are returned sorted by `emitterId`.
Result order has no acoustic-routing meaning.

Routing remains exclusively `emitterId → left | right | mid`. Do not infer routing from emitter list order, binding insertion order, visual role, or speaker label.

Not a 7.1 decoder. Not a second array renderer.
