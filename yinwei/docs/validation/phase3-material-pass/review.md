# Phase 3 — material and environment pass

Continued from the existing local visual refinement on 2026-09-16. The only production file edited in this pass is `apps/yinwei_player/assets/spatial_workspace/scene.js`. Other working-tree changes predate this pass.

## Result

- Acoustic panels have shared, deterministic fabric albedo, roughness and bump maps, subtle tone variation and rounded seams. The initial overly mottled texture was reduced after native runtime review.
- The floor uses a mineral texture, subdued grid and reference rings, lower environment reflection, broader contact shadows and filtered cast shadows.
- Monitors have rounded, beveled enclosures and baffles, a satin graphite coating, recessed woofer cones and shaped tweeter waveguides. Existing speaker anchors and routing are preserved.
- Neutral light colors and restrained floor washes keep the room graphite rather than glossy or neon.

Against the golden reference, this improves acoustic material depth, cabinet construction and reflection restraint. It remains a procedural real-time room: the reference has richer indirect lighting and more nuanced surface detail. Camera, layout, inspector, transport, source and listener design were deliberately retained under the current scope.

## Evidence

- [Windows app, final Free view](windows-runtime.jpg)
- [Workspace capture](workspace.png)
- [Monitor detail using the existing Listener camera](monitor-detail.png)
- [Final restored scene state](final-state.json)
- [Previous pass, default view](../phase3-visual-pass2/windows-runtime-default.jpg)

The Windows app was built, launched, inspected in normal and maximized views, and left running in Free view with the original source position and selection cleared. Screenshots are runtime captures, not mockups.

## Validation

- Windows debug build passed: [build.log](build.log).
- 218 Flutter tests passed: [tests.log](tests.log).
- Windows native engine smoke test passed: [native-smoke.log](native-smoke.log). This is an automated check, not a perceptual audio listening test.
- Actual Windows WebView renderer: listener/source/emitter picking, planar and elevation dragging, orbit/pan/zoom and all existing camera presets passed; eight emitters present. No captured JavaScript console/page errors: [runtime-validation.json](runtime-validation.json).
- JavaScript syntax check and `git diff --check` passed.
- Source comparison against the start-of-pass snapshot confirms unchanged camera defaults/presets, transforms, intent handling, interactions and listener/source construction. HUD hash unchanged. Protected-file hash check: 50 files, zero changed.
- Native runtime still reports the existing Flutter AXTree accessibility warning; the native log is not entirely warning-free.

Textures are generated once at startup and shared across meshes. Filtered variance shadows add blur work; GPU performance has not been benchmarked in this pass.

For a local rollback of this pass only, the renderer snapshot is retained at repository-root `.tmp/material-pass/scene.before.js`. Do not reset unrelated working-tree changes.
