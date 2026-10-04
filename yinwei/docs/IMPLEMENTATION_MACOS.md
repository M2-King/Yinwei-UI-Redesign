# Yinwei macOS Implementation Plan

Date: 2026-10-02

Status: implementation specification; macOS code, builds and runtime behavior are not yet verified.

## Objective and scope

Port the existing Flutter spatial player to macOS while preserving Rust playback, HRTF and DSP. Deliver a native app with local file playback, spatial controls and the existing interactive Three.js workspace.

Proposed first validation target: Apple Silicon. Intel/universal distribution follows after the native playback proof. Minimum macOS version must be selected after checking Flutter, plugin and Xcode requirements; do not invent a deployment target.

Windows Floating Island, WASAPI Live Transfer, per-application audio routing and Windows system media integration do not have macOS implementations. Keep these capabilities unavailable until separately specified and verified. Product decisions about macOS equivalents require product/architecture review.

## Existing architecture and constraints

- Application: `apps/yinwei_player`, Flutter/Dart; entry point `lib/main.dart`.
- Audio: `crates/spatial_core`, Rust, exposed through Dart FFI.
- Playback: CPAL realtime output, session and playback modules.
- HRTF/DSP: existing HRTF renderer with embedded IRCAM HRIR data, EQ, crossover, reverb, resampling and distance processing.
- Spatial authority: `SpatialRuntimeAdapter` owns `SpatialSceneStore`; `SpatialSceneBridge` handles renderer intents and snapshots.
- Rendering: bundled `assets/spatial_workspace/scene.js` and Three.js hosted through `SpatialWorkspaceHost`.
- Current native workspace factory creates Windows WebView2.
- Current macOS library loader opens `libspatial_core.dylib` by bare filename.
- Current platform detection gives macOS the `none` capability profile.
- No macOS runner or macOS release pipeline is present in the inspected project.
- Engine bootstrap falls back to MockEngine if native loading fails. A visible UI is not proof of working audio.

Target flow:

```text
Flutter UI -> spatial runtime/store -> existing engine controller/FFI -> Rust audio
                       |
                       +-> scene snapshots -> macOS WebView -> existing Three.js scene
                       <- validated intents <- macOS WebView
```

Preserve the established engine projection path. JavaScript must not become an independent spatial authority or send audio commands directly.

Protected modules: Rust audio engine, playback, HRTF/DSP, existing FFI semantics and spatial contracts. Extend platform boundaries and packaging instead of rewriting audio for macOS or visual reasons.

## Phase M1: macOS runner and native audio proof

1. Establish a clean baseline and record current uncommitted work before implementation. Use a dedicated branch and incremental commits.
2. On a Mac, install/configure Flutter, full Xcode and its command-line tools, Rust, and native-plugin dependency tooling. Existing Apple CI pins Flutter 3.47.2; evaluate that version first and record the tested toolchain.
3. Add only the macOS runner from `apps/yinwei_player`:

   ```bash
   flutter create --platforms=macos .
   flutter pub get
   flutter doctor -v
   flutter devices
   ```

4. Review generated changes and plugin registration. Do not replace existing Windows/iOS/Android runners.
5. Add `tools/build_native_macos.sh` to build `spatial_core` with its default realtime feature. Build on macOS; Windows alone cannot produce or validate this Flutter/Xcode app.

   ```bash
   # From yinwei/
   rustup target add aarch64-apple-darwin
   cargo build -p spatial_core --release --target aarch64-apple-darwin
   ```

   Expected library: `target/aarch64-apple-darwin/release/libspatial_core.dylib`.

6. Embed the library in the generated app's `Contents/Frameworks` through an Xcode build phase or equivalent reproducible build integration. Ensure ordering/dependencies produce the library before embedding and signing. Do not require users to copy a library manually or set a shell search path.
7. Change the macOS branch in `lib/bridge/yinwei_bindings.dart` to resolve an absolute bundle-relative library path from `Platform.resolvedExecutable`. Inspect Mach-O dependencies/install names with `otool -L` and architecture with `file`/`lipo -info`. Resolve any non-system dependencies before release signing.
8. Add a macOS profile in `lib/platform/platform_capabilities.dart`. Enable verified file playback, spatial functionality and desktop window behavior incrementally. Keep Windows native chrome/island/system media/capture off. Audit callers before enabling array mode or desktop drop.
9. Review sandbox entitlements for user-selected file import/export and required networking. Verify release access to paths passed into Rust; use security-scoped access if required by the chosen sandbox/plugin integration. Local output playback is not microphone capture.
10. Confirm native engine selection and audible playback before implementing the WebView.

Acceptance: native backend, valid FFI symbols, local file open, audible play/pause/seek, Original/Spatial comparison and directional HRTF through headphones. A mock fallback fails acceptance.

## Phase M2: desktop UI and interactive spatial workspace

1. Audit file picker, desktop drop, window manager and screen retriever behavior on macOS. Confirm native plugin support for the resolved dependency versions.
2. Implement a macOS `SpatialWorkspaceHost` using a macOS-compatible WebView/WKWebView integration. Choose its dependency after verifying JavaScript channels, local assets, WebGL, script execution and disposal support.
3. Dispatch the host by operating system in `lib/platform/three_js_host_bind.dart`; retain the Windows host.
4. Reuse the bundled scene, existing HTML generation and `SpatialSceneBridge` protocol. Inspect any Windows-specific transport assumptions and adapt the host boundary.
5. Support boot/readiness/errors, JS-to-Dart messages, Dart-to-JS execution, suspend/resume and disposal. Respect current intent validation, revisions and stale-message handling.
6. Enable `threeJsWebView` only once the host works. Verify real 3D speaker geometry, listener/source, camera controls and inspector synchronization.
7. Verify resizing, minimum window dimensions, Retina scaling, focus, keyboard behavior and title-bar layout while retaining the current professional dark UI.

Acceptance: interactive 3D view; UI/renderer/audio pose synchronization; no competing spatial state; no Dart, native or JavaScript console errors; correct renderer recovery/disposal.

## Coordinate contract

Use `docs/contracts/COORDINATE_FRAME_V1.md` and `AUDIO_PROJECTION_V1.md` as authoritative references.

- Right-handed world: +X right, +Y up, -Z forward, +Z rear; metres.
- Identity listener faces -Z; acoustic origin is the ear midpoint.
- Azimuth: front 0 degrees, right +90, left -90, rear +180; canonical range (-180, 180]. Elevation is positive upward.
- For listener-local `(x,y,z)`: distance `r = sqrt(x*x+y*y+z*z)`, azimuth `atan2(x,-z)`, elevation `asin(clamp(y/r,-1,1))`, converted to degrees with documented zero/pole handling.
- World to listener-local: `R(inverse(q)) * (worldPosition - listenerPosition)`.
- Three.js uses the same world axes. Contract quaternion order `(w,x,y,z)` maps to Three.js `(x,y,z,w)` by reordering.
- Project listener-local pose into existing audio parameters. Keep HRTF unit direction independent of DSP distance, smoothing and quantization.
- Preserve existing documented zero-distance differences and fixed-listener engine assumptions; do not silently modify them during the port.

## Phase M3: release and architecture coverage

1. Add a macOS CI workflow, separate from existing iOS jobs. Record git SHA, Flutter/Rust/Xcode versions, architecture and build configuration.
2. Build Intel Rust libraries with `x86_64-apple-darwin` if Intel distribution is approved. For a universal app, combine the two native slices with `lipo` and verify every embedded executable/library supports the app's architectures.
3. Run tests and build:

   ```bash
   # From yinwei/
   cargo test -p spatial_core
   cargo test -p spatial_scene_contract
   cd apps/yinwei_player
   flutter analyze
   flutter test
   flutter run -d macos
   flutter build macos --release
   ```

4. Expected Flutter output directory: `build/macos/Build/Products/Release/`. App filename depends on the runner product configuration.
5. Configure the bundle identifier, product name, version, icon and selected deployment target.
6. For direct public distribution, sign embedded native components and app with Developer ID, configure hardened runtime as required, notarize and staple the distributable. Package as ZIP or DMG. Credentials remain in the release environment, never source.
7. Do not publish a mock-backed, unsigned or unverified build as a completed release. Keep development builds clearly identified.
8. Review macOS update/download behavior; do not reuse Windows installer contracts without a macOS implementation.

## Verification and risks

| Risk | Required evidence |
|---|---|
| Library missing, wrong architecture or stripped ABI | Bundle inspection, symbol inspection, native backend assertion and FFI smoke test |
| Build succeeds but app has no audio | Audible release-app playback on Mac hardware; no mock fallback |
| File picker works but Rust cannot access file | Sandboxed release import/export checks, including paths with spaces and Unicode |
| Incorrect spatial projection | Existing contract tests plus front/right/left/rear/up headphone checks and renderer comparison |
| WebView/plugin incompatibility | Local asset load, JS round-trip, WebGL scene, resizing, focus and console checks |
| Audio interruption/performance regression | Long-file playback, rapid pose changes, orbit/array, resize/minimize; CPU/memory and underrun observation |
| Platform capability exposes unsupported feature | Capability/caller tests and macOS interaction checks |
| Other platforms regress | Existing relevant Windows/iOS tests and native smoke checks after shared-code changes |
| Release signature or packaging invalid | Launch a packaged app outside the checkout on a clean Mac; signature/Gatekeeper validation |

Add focused tests for macOS capability detection, bundle path resolution, host selection and bridge lifecycle. Reuse existing spatial contract/runtime tests. Record screenshots and interaction results for the main workspace and error states; do not declare visual acceptance from screenshots alone.

Initial audit status: source inspection only. The implementation and verification
record below tracks subsequent work; Mac acceptance remains pending.

### M1 implementation record — 2026-10-02

Branch: `codex/macos-m1`. Existing working-tree status recorded in
`.tmp/macos-baseline-status.txt` at the repository root. Existing user changes
remain in place; audio/DSP sources and spatial coordinate contracts were not modified.

Source prepared:

- Generated `apps/yinwei_player/macos` runner from an isolated Flutter scaffold,
  preserving other runners and the existing pubspec.
- `tools/build_native_macos.sh`: builds requested Rust architecture slices,
  checks key exports, sets the library install name, embeds and signs the dylib
  from an Xcode Runner build phase.
- `tools/verify_macos_bundle.sh`: checks bundle library presence, architecture
  coverage and signature integrity.
- macOS bundle-relative FFI path, reused by isolates; no cwd library fallback.
- Development capability profile and caller gates for unported controls.
- User-selected read/write sandbox entitlements.
- Focused path/capability/UI tests and an explicit Mac-only FFI/export smoke test.
- Mac build and hardware acceptance instructions in
  `apps/yinwei_player/macos/README.md`.

Windows-host verification: 82 Rust core/contract tests passed; 451 Flutter tests
passed with one Mac-only native test skipped; Windows debug build and the
existing UI golden check passed. Shell syntax, runner phase wiring and XML
checks passed. Final Flutter analysis reported 118 warning/information findings
and no errors; it is not a clean-analysis pass.
The mocked macOS-capability layout/Point interaction is checked; its screenshot
uses Flutter test fonts and is not a Mac runtime or final 3D rendering proof.

Open verification gates:

- macOS Xcode/plugin build, native FFI smoke execution, bundle signatures and
  sandboxed file access have not run on a Mac.
- Audible playback, output-device behavior, HRTF direction and performance on
  Mac hardware remain pending.
- Flutter analysis has existing warnings/information findings; a clean analyzer
  result is not claimed. The regression suite logs an audio-route disposal
  warning, so a clean-console result is not claimed.
- M1 remains **awaiting Mac acceptance**. M2 WebView implementation and M3
  public release work have not started.
- User confirmed no Mac is available yet. Hardware acceptance cannot be
  performed in the current Windows environment; do not advance past this gate.

## Rollback

### Continuation authorization and source progress — 2026-10-04

The user authorized finishing the implementation for a friend to test without
waiting for a local Mac. This supersedes the implementation pause above;
hardware audio/visual/performance acceptance remains pending.

M2 source now includes WKWebView host selection, the existing offline scene and
intent/snapshot protocol, JSON result normalization, readiness/error handling,
late-callback/disposal guards and lifecycle-based render suspension. The macOS
profile exposes file/Point/array/3D/drop functionality for testing; Windows-only
adapters remain off. No new spatial authority or audio/DSP implementation exists.

M3 test-delivery infrastructure includes universal ZIP/DMG packaging, hashes,
build metadata, friend instructions and a dedicated GitHub Mac CI workflow.
Optional Developer ID/notary environment inputs are supported without storing
credentials. Public release credentials and final deployment/branding choices
remain outstanding. Current resume state is in `CHECKPOINT_MACOS_2026-10-04.md`.

Keep runner/scaffolding, native packaging, capability profile, renderer host and release pipeline in separate reviewable commits. Revert macOS changes without disturbing current user work or existing platform runners. Avoid persistent engine/API changes; if any become necessary, stop for architecture review and isolate them from the port.

## Product decisions before final release

- Apple Silicon only or universal distribution.
- Minimum supported macOS version and direct download versus Mac App Store.
- Whether macOS equivalents of Floating Island, system media and Live Transfer are in scope.

These do not block the native playback proof. They must be resolved before enabling corresponding features or publishing the final product.

## Toolchain references

- Flutter macOS setup: https://docs.flutter.dev/platform-integration/macos/setup
- Flutter desktop runner/build commands: https://docs.flutter.dev/platform-integration/desktop
- Apple Developer ID distribution: https://developer.apple.com/developer-id/
