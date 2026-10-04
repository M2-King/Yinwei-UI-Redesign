# macOS test runner

This runner is generated with the repository's Flutter SDK (revision
`d3b14c876900e553bc736ca19295fc09e3853e8e`) and extended to build/embed the
existing Rust audio library. M1/M2 source and packaging are prepared; audible
hardware acceptance remains pending. See `../../../docs/IMPLEMENTATION_MACOS.md`.
The user authorized proceeding to a friend test before hardware acceptance.

## Build on a Mac

Install full Xcode, its command-line tools, Rust through rustup, and Flutter.
Start with Flutter 3.47.2, matching the existing Apple CI configuration. Run
`flutter doctor -v` and resolve Mac toolchain issues. Native plugins may require
CocoaPods or Swift Package Manager tooling; verify the resolved graph on the Mac.

From the repository root:

```bash
cd yinwei/apps/yinwei_player
flutter pub get
flutter analyze
flutter test
flutter build macos --debug
```

The Runner build phase invokes `tools/build_native_macos.sh xcode`, uses Xcode's
`ARCHS`, and copies `libspatial_core.dylib` into `Contents/Frameworks`. Rust is
built with the default realtime feature and `--locked`. The phase signs the
embedded library before Xcode signs the app. It requires network access for
uncached Rust targets/dependencies. Run Xcode with a Rust installation available
at `$HOME/.cargo/bin` or in its environment PATH.

The app loads the library by its absolute bundle path. It does not search the
working directory. Do not run the packaged app by copying its executable alone.

## Explicit native smoke test

The Flutter test executable is outside the application bundle, so the smoke
test accepts an explicit library path without changing the shipping loader:

```bash
# From yinwei/apps/yinwei_player, on Apple Silicon:
bash ../../tools/build_native_macos.sh arm64
YINWEI_MACOS_DYLIB="$(cd ../../target/macos/arm64 && pwd)/libspatial_core.dylib" \
  flutter test --no-pub test/runtime/macos_native_smoke_test.dart
```

Use `x86_64` and the corresponding output directory on Intel. This verifies
loading the mandatory FFI bindings, opening a PCM fixture, switching modes and
exporting spatial audio. It does not verify the output device or audible HRTF.

## M1 acceptance on hardware

1. Run `flutter run -d macos`; confirm the backend reads Native rather than Mock.
2. Open WAV, MP3 and FLAC examples, including a filename with spaces/Unicode.
3. Through headphones, confirm play/pause/seek and Original versus Spatial.
4. Compare Front, Right, Left, Back and elevation; record listener-relative
   direction and check the existing coordinate contract.
5. Test exporting WAV to a directory selected by the user.
6. Build release and repeat outside the checkout; the release sandbox must
   permit Rust to read the selected source and write the selected destination.
7. Capture the actual app layout/interactions and inspect Dart/native console
   errors. Monitor long playback and rapid pose changes for glitches.
8. Inspect the app bundle:

   ```bash
   bash ../../tools/verify_macos_bundle.sh \
     "build/macos/Build/Products/Release/Yinwei.app"
   ```

The bundle inspection checks architecture coverage and signatures. It does not
replace playback or clean-Mac release verification.

## Development limits

- The macOS profile enables desktop setup, file/Point/array playback, drag/drop
  and the existing scene in WKWebView. Windows-only integrations remain off.
- WebView errors use the existing Flutter fallback; fallback is not acceptance
  of the actual 3D workspace.
- User-selected read/write entitlements are present in Debug/Profile and
  Release. Actual sandbox access and security-scoped plugin behavior remain
  unverified until the Mac checks pass.
- The generated macOS 12.0 deployment setting is retained for scaffolding. It is
  not a validated minimum support promise.
- `com.example.yinweiPlayer`, the generated product identity and default icon
  are development placeholders. Resolve branding, bundle identity, deployment
  target and distribution method before M3.
- `bash ../../tools/package_macos.sh` builds a universal release configuration
  and produces a test ZIP/DMG, metadata and hashes. The Mac CI workflow runs it.
  Optional `YINWEI_MACOS_SIGN_IDENTITY` and `YINWEI_MACOS_NOTARY_PROFILE` use
  release-environment credentials; the default test build is ad-hoc signed.
  See `../../../docs/MACOS_FRIEND_TEST.md` for installation and acceptance.
- Public signing credentials, final product identity/icon, a validated minimum
  deployment version and macOS update distribution remain release decisions.

Do not claim hardware acceptance or a finished public release from CI alone.
