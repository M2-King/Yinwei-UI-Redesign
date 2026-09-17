# Phase 5B — Transport / Playback Integration

Visual transport only. Scene Store, Runtime Adapter, Three.js, Island reliability, and the audio pipeline were not changed.

## Before → after

The previous bottom bar still read as a compact music player: 48px artwork, dummy previous/next, stacked seek times, and Original/Spatial only.

It is now a 56px workstation transport:

- Small 28px artwork that yields to the scene
- Track identity is secondary and compresses first
- One restrained play/pause control
- Inline time + seek
- Independent **Original | Spatial** and **Point | 2.0** switches on the existing controller paths

## Corrections vs the current runtime baseline

1. **Hierarchy** — playback no longer competes with the spatial workspace.
2. **Modes** — Original/Spatial still call `setMode`; Point/2.0 call `applyArrayMode`. They are not merged into a fake 3-way DSP mode.
3. **Seek** — Yinwei file seek still goes through `EngineController.seek`. System-media seek stays disabled.
4. **Island** — Full ↔ Island still share one `EngineController`. Phase 5A window logic was not touched.

## Frozen systems

| System | Touched |
|---|---|
| SpatialSceneStore | No |
| SpatialRuntimeAdapter | No |
| Three.js `scene.js` / `index.html` | No |
| Array DSP / `layout.rs` / `hrtf_render.rs` / `playback.rs` / `session.rs` / `ffi.rs` | No |
| `native_engine.dart` / `engine_api.dart` | No |
| `spatial_params.dart` / `spatial_math.dart` array semantics | No |
| EngineController audio methods | No (UI build id only: `ui-51-transport`) |
| WindowModeController / IslandBar | No |

## Validation

| Check | Result |
|---|---|
| `flutter test` | 247 passed |
| Windows runtime | `ui-51-transport` · `p2.4.32-matrix`; native open of `phase5b-tone.wav`; WebView 915×740 |
| Scene revision during transport/mode/array/Island | stayed `1` |
| Original → Spatial | `PlaybackMode` only; array stayed `off` |
| Spatial → 2.0 | `applyArrayMode(stereo2)` only; `PlaybackMode` stayed `spatial`; selected speaker `0`; matrix unlinked |
| Island ↔ Full | same playing/mode/array/position; pill geometry 630×96 collapsed |
| Console | Pre-existing AXTree warning only |

## Artifacts

- [Paused Spatial / Point](windows-paused-spatial-point.jpg)
- [Original](windows-original.jpg)
- [Playing Original](windows-playing-original.jpg)
- [Spatial](windows-spatial.jpg)
- [Array / 2.0](windows-array-2.0.jpg)
- [Wide 2.0 transport](windows-array-wide.jpg)
- [Full restored after Island](windows-full-restored.jpg)
- [Narrow window](windows-narrow.jpg)
