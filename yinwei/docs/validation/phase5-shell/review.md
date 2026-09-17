# Phase 5 — Global Product Composition Pass

Visual composition only. Scene Store, Runtime Adapter, Three.js, engine writers, and the audio pipeline were not changed.

## Before → after

The previous full window was a three-column music player: Spatial Workspace | Now Playing | Inspector, with a title bar, live banner, and status bar stacked around it.

The shell is now a workstation:

- Left product rail (identity + Spatial / Open / EQ / Export / Island)
- Spatial workspace as the primary surface
- Phase 4 inspector on the right
- Bottom transport for playback (no competing album-art column)

## Corrections vs the current runtime baseline

1. **Hierarchy** — workspace occupies the center; playback is a transport, not a sibling panel.
2. **Shell** — `音围 Yinwei` identity lives in the rail; top bar is a quiet session strip (`系统媒体待机` / SMTC + Transfer + `Spatial (Point)`).
3. **Player** — artwork, title, transport, scrubber, and Original/Spatial sit in one 80px bar.
4. **Spacing** — shared `YinweiLayout` metrics; default window 1440×900.

## Intentional remaining differences from the golden

The golden is visual direction, not a new product spec. This pass did not add Music Library, Presets, Settings, Position/Audio tabs, Studio A, or a volume slider. Those would be new surfaces or engine writers. Open / EQ / Export / Island / Live Transfer remain because they already exist.

## Frozen systems

| System | Touched |
|---|---|
| SpatialSceneStore | No |
| SpatialRuntimeAdapter | No |
| Three.js `scene.js` / `index.html` | No |
| Engine / HRTF / DSP writers | No |
| Inspector internals | No |

`SpatialWorkspace` Flutter chrome only dropped the duplicate `SPATIAL WORKSPACE` label so the Three.js HUD remains the scene title.

## Validation

| Check | Result |
|---|---|
| `flutter test` | 224 passed |
| Windows runtime | `ui-50-shell` · `p2.4.32-matrix`; WebView ready; scene revision 1 |
| Workspace viewport | `915×716` (was a side panel beside Now Playing) |
| Console | Pre-existing AXTree warning only |

## Artifacts

- [Golden reference](supplied-reference.png)
- [Supplied before](supplied-before.png)
- [Windows runtime](windows-runtime.jpg)
