# Phase 3 spatial object quality pass

Only production file changed in this pass: `apps/yinwei_player/assets/spatial_workspace/scene.js`.

## Presentation

- Monitors: wider rounded enclosures and baffles, larger recessed woofers, elliptical tweeter waveguides, bass-port detail, small machined badges and rear connector wells. Existing cabinet coating, stands and floor contacts retained.
- Listener: replaced the human bust with an abstract acoustic reference instrument. Opposed lateral capsules mark the left/right baseline; a directional inlay faces -Z. A slender support and weighted base replace shoulders and torso. The acoustic origin remains at the same point.
- Source: split satin-metal lens surrounding a narrow luminous equator. Existing elevation handle, field ring, relationship line and selection system retained.

The reference informed material separation and professional instrument identity. This remains procedural real-time geometry, with no image backdrop or added product features. The default source remains partly hidden behind the right monitor; composition and object coordinates were not changed to hide this limitation.

## Runtime evidence

- [Windows runtime](windows-runtime.jpg), original source pose restored.
- [Workspace](workspace.png).
- [Monitor detail](monitor-detail.png), using the existing Listener camera.
- [Unobstructed object review](objects-unobstructed.png): source temporarily placed at (0.9, 0.3, 0.7) through the existing host intent path for inspection, then restored.
- [Final scene state](final-state.json).

The checkout contains newer Flutter shell/inspector edits than the supplied screenshot. Those edits were present before this pass and were preserved; they explain the surrounding UI in the rebuilt runtime. No Flutter source was edited here.

## Validation

- Windows debug build passed: [build.log](build.log). App launched and visually inspected.
- Selection of listener, emitter and source; planar drag; Shift elevation drag; orbit/pan/zoom; Top, Front, Listener, Fit and Free camera checks passed in the Windows WebView: [runtime-validation.json](runtime-validation.json). Eight emitters remain present. No captured JavaScript console/page errors.
- Initial elevation check hit a monitor after dragging the default source behind it. The check was repeated with an unobstructed source position and passed. Occlusion/picking logic was not changed.
- Native audio smoke test passed, covering native engine loading and Point state adoption: [native-smoke.log](native-smoke.log). No perceptual listening claim.
- Flutter suite: 223 passed, one UI-golden failure: [tests.log](tests.log). Repeating that golden with the pre-pass renderer also failed: [baseline-golden.log](baseline-golden.log). Golden was not updated.
- JavaScript syntax and changed-file whitespace checks passed. Repository-wide whitespace check reports an existing trailing blank line in `position_sidebar.dart`; it was left untouched.
- Hash comparison: 91 other source/assets files unchanged from start of pass, including Flutter UI, native/audio and spatial state paths.
- Byte comparison confirms camera setup, environment construction, and all renderer state/interaction code from the contact-shadow setup onward unchanged. IDs, coordinate conversion, selection handling and host intent flow remain intact.
- Existing native Flutter AXTree accessibility errors remain in the runtime log. GPU performance has not been benchmarked.

Local rollback snapshot: repository-root `.tmp/object-pass/scene.before.js`. Preserve unrelated working-tree changes when rolling back.
