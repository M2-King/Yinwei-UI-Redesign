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

Phase 1C Point-mode live adoption is owned by `SpatialRuntimeAdapter`: it applies revisioned snapshots here, projects with Dart `AudioProjectionV1`, then feeds the existing `EngineController.setParams` path. Array mode remains on the legacy engine path. This store still does not call FFI or `EngineApi`.
