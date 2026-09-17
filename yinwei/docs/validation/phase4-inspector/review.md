# Phase 4 Inspector — final visual refinement

Visual-only pass against the supplied golden. Architecture was not rebuilt. Three.js, SpatialSceneStore, RuntimeAdapter, EngineController writers, the audio pipeline, and existing callbacks were not changed.

## Corrections vs the current runtime baseline

1. **Readouts first** — X / Y / Z and polar values sit in wells; sliders are thin, gray, and secondary.
2. **Less HUD** — removed INSPECTOR / POSITION / ADVANCED / QUICK PLACE banners and separators. SOURCE is tertiary. HRTF / Audio object copy is hidden for the default source.
3. **Quick Controls** — same 9 presets, laid out as two-column spatial tools with a quiet selected state (no blue fill).
4. **Blue only for selection elsewhere** — inspector sliders and chips no longer use accent tracks.
5. **Spacing / type** — calmer identity, metric rows, and footer links so Motion / Space stay in the first maximized viewport.

## Intentional remaining differences from the golden

The golden is a visual direction, not a product spec. This pass did not add Position/Audio tabs, Reset, or a 6-button subset. Array 点源/2.0, nine presets, Motion / Space / Reverb, and EQ / Export / Save remain because they are existing writers.

## Validation

| Check | Result |
|---|---|
| `flutter test test/position_sidebar_test.dart` | 9 passed |
| `flutter test` | 222 passed |
| Windows runtime | `ui-40-inspector` · `p2.4.32-matrix`; WebView ready; scene revision 1 |
| Console | Pre-existing AXTree warning only |

## Artifacts

- [Golden reference](supplied-reference.png)
- [Windows runtime](windows-runtime.jpg)
- [Inspector crop](inspector.jpg)
