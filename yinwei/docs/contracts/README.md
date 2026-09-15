# Spatial Scene Domain — contracts

Phase 1A defines versioned contracts. Phase 1B adds a scene store and a **pure** audio projection. Neither changes runtime DSP, Flutter UI, or Three.js.

| Piece | Document |
|-------|----------|
| `CoordinateFrameV1` | [`COORDINATE_FRAME_V1.md`](./COORDINATE_FRAME_V1.md) |
| `SceneContractV1` | [`SCENE_CONTRACT_V1.md`](./SCENE_CONTRACT_V1.md) |
| `SpeakerSemanticsV1` | [`SPEAKER_SEMANTICS_V1.md`](./SPEAKER_SEMANTICS_V1.md) |
| `SpatialSceneStore` | [`SPATIAL_SCENE_STORE.md`](./SPATIAL_SCENE_STORE.md) |
| `AudioProjectionV1` | [`AUDIO_PROJECTION_V1.md`](./AUDIO_PROJECTION_V1.md) |

Shared fixtures (Dart / Rust / JavaScript): [`../../contracts/v1/`](../../contracts/v1/).

## Scope

In scope:

- Authoritative scene snapshot + revision rules
- Pure projection to engine-compatible azimuth / elevation / distances
- Tests that reuse Phase 1A fixtures

Still out of scope:

- PlayerScreen / EngineController wiring
- Three.js / `spatial_workspace.dart` / Inspector
- HRTF, DSP, playback, C ABI, native DLLs

The Rust crate `spatial_core` remains the Audio/DSP engine. The Scene Store is **not** a second Spatial Core.
