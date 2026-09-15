# Spatial Scene Domain — Phase 1A contracts

Phase 1A defines versioned contracts only. It does **not** change runtime behaviour.

| Contract | Document |
|----------|----------|
| `CoordinateFrameV1` | [`COORDINATE_FRAME_V1.md`](./COORDINATE_FRAME_V1.md) |
| `SceneContractV1` | [`SCENE_CONTRACT_V1.md`](./SCENE_CONTRACT_V1.md) |
| `SpeakerSemanticsV1` | [`SPEAKER_SEMANTICS_V1.md`](./SPEAKER_SEMANTICS_V1.md) |

Shared fixtures (Dart / Rust / JavaScript): [`../../contracts/v1/`](../../contracts/v1/).

## Scope

In scope:

- Additive documentation
- Pure coordinate / scene / speaker-semantics math in **new isolated files**
- Tests that consume the shared fixtures

Out of scope (do not start):

- Spatial Scene Store
- Audio projection into `spatial_core`
- UI wiring, Inspector, camera
- Three.js / `spatial_workspace.dart`
- HRTF, DSP, playback, C ABI, native DLLs

The Rust crate `spatial_core` remains the Audio/DSP engine. These contracts describe the future **Spatial Scene Domain**. They are not a second Spatial Core.
