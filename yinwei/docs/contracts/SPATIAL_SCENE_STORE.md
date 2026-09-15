# SpatialSceneStore (Phase 1B)

Authoritative holder for a validated `SceneContractV1` snapshot.

This is **not** `spatial_core`. It does not call FFI, mutate the audio engine, or store camera / selection / audio configuration.

## Behaviour

| Incoming revision | Result |
|-------------------|--------|
| invalid document | `rejectedInvalid` — previous snapshot kept |
| `<=` current | `rejectedStale` — previous snapshot kept |
| `current + 1` | `applied` |
| `> current + 1` | `appliedWithDiscontinuity` |

Empty store: `appliedRevision = 0`, no snapshot.

The snapshot is a deep copy. Consumers must not treat it as engine state or UI state.

Phase 1B does **not** wire the store into `PlayerScreen` or `EngineController`.
