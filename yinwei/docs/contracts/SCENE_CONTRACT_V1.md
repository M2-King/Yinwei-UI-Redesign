# SceneContractV1

Minimum versioned **authoritative scene model** for the Spatial Scene Domain.

Schema id: `SceneContractV1`  
Schema version: `1`

This is not `spatial_core`. Audio configuration, UI interaction, camera, and telemetry stay outside this document.

---

## 1. Separation of concerns

| Concern | Lives in | In SceneContractV1? |
|---------|----------|---------------------|
| Authoritative geometry / enablement | Spatial Scene Domain | **yes** |
| HRTF / DSP / playback / EQ / envelopment / reverb | `spatial_core` `SpatialParams` + engine | **no** |
| Array feeds, array mode, gain_db, mute-as-feed | audio configuration (`ArrayLayout`) | **no** |
| Selection, hover, drag, gizmos | UI state | **no** |
| Camera, view mode, orbit controls | UI / renderer | **no** |
| Meters, playhead, FPS, logs | telemetry | **no** |

Forbidden top-level keys on a V1 scene document: `camera`, `selection`, `hover`, `drag`, `telemetry`, `audio`, `spatialParams`, `arrayLayout`.

Camera and selection must never become acoustic state.

---

## 2. Document shape

```text
SceneContractV1
  schemaVersion: 1
  revision: uint64          # monotonic scene generation
  listener: SceneObject     # exactly one
  sources: SceneObject[]    # 0..N acoustic sources (point sources)
  emitters: SceneObject[]   # 0..8 visual/interactive emitters
```

JSON field names are camelCase.

---

## 3. Scene object

```text
SceneObject
  id: string                # stable for the lifetime of the object
  type: listener | source | emitter
  worldPosition: { x, y, z }   # metres, CoordinateFrameV1
  orientation?: { w, x, y, z } # optional; default identity
  enabled: bool             # present in the model
  active: bool              # currently contributing when later projected
```

Optional non-acoustic metadata (ignored by validation except type/string checks):

- `visualRole` on emitters (e.g. `"L"`, `"C"`, `"LFE"`) — layout label only; see SpeakerSemanticsV1
- `label` — display name

Do **not** store UI selection on the object. Do **not** store speaker `feed` on the object.

---

## 4. Stable IDs and types

- `id` is a non-empty string, max 64 characters, unique within the document (listener + sources + emitters).
- Allowed id characters: `A–Z a–z 0–9 _ - : .`
- Type must match the array it lives in (`listener` field is `listener`, items in `sources` are `source`, items in `emitters` are `emitter`).
- IDs must not be recycled to a different `type` within a running session. V1 tests only check uniqueness inside one document.

---

## 5. Validation ranges

| Field | Rule |
|-------|------|
| `schemaVersion` | must equal `1` |
| `revision` | integer \(\ge 0\), finite, no fraction |
| `worldPosition.*` | finite IEEE floats (no NaN / ±Inf) |
| `orientation` | if present: four finite floats, norm \(\ge 10^{-12}\) after which it is normalized for use |
| `enabled`, `active` | booleans |
| listener count | exactly one |
| source count | \(0\ldots 32\) |
| emitter count | \(0\ldots 8\) |

World positions are **not** clamped to the DSP distance range `[0.5, 10]`. That clamp belongs to a later audio projection.

A playable default is one listener at the origin with identity orientation and one source. Empty `sources` is still a valid **document**.

---

## 6. Revision semantics

- `revision` is the authoritative generation counter for this scene document.
- Starts at `0` for a newly constructed empty holder; the first committed scene should use `1` (fixtures use `≥ 1`).
- Every authoritative mutation (object add/remove/move/enable) **must** increment `revision` by exactly `1` in the store (Phase 1B). Phase 1A only defines the rule.
- Derived UI state (hover) must not increment `revision`.

---

## 7. Stale revision rejection

A consumer keeps `appliedRevision` (last successfully applied generation).

| Incoming `revision` | Decision |
|---------------------|----------|
| `incoming > appliedRevision` | **apply** |
| `incoming <= appliedRevision` | **reject** as `stale_revision` |

Gaps (`incoming > appliedRevision + 1`) are **accepted**. V1 does not invent buffering or retransmission. The consumer should record a discontinuity for telemetry (telemetry is not part of the scene document).

Equal revision with different payload is still stale: the scene is identified by revision, not by structural hash.

---

## 8. Mapping notes (not implemented in Phase 1A)

- The existing player has one point-source pose in `SpatialParams` plus an optional stereo array. Projecting SceneContractV1 into that engine is Phase 1B+.
- Emitters are not a 7.1 bus. See SpeakerSemanticsV1.
- Listener orientation in this contract may be non-identity; today’s engine listener is identity at the origin. Projection may ignore listener translation/rotation until a later phase — that is a product decision, not implied here.
