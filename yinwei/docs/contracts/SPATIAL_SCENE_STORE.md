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

Empty store: `appliedRevision = 0`, `hasScene = false`, no snapshot.

That reported `0` is **not** an accepted revision. An empty store has no authoritative previous revision, so the first valid scene — including `revision = 0` — is `applied`. After a scene exists, the table above applies (`revision 0` again is `rejectedStale`; `revision 1` after `0` is `applied`).

`SceneContractV1` still allows `revision >= 0`. The store does not use a sentinel such as `-1`.

The snapshot is a deep copy. Consumers must not treat it as engine state or UI state.

Phase 1B does **not** wire the store into `PlayerScreen` or `EngineController`.
