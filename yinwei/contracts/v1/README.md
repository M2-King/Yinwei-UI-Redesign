# Spatial Scene Domain contracts v1 — fixtures

Canonical JSON consumed by Dart, Rust, and JavaScript contract tests.

```
fixtures/coordinate_fixtures_v1.json
fixtures/scene_fixtures_v1.json
fixtures/speaker_semantics_v1.json
```

These files are documentation-backed expected values. They are not an audio engine.

## Run contract tests only

From the repo (no player rebuild, no `spatial_core` rebuild):

```text
cargo test -p spatial_scene_contract --offline
```

If the crate is not yet in the lockfile, omit `--offline` once.

```text
cd yinwei/apps/yinwei_player
flutter test test/contracts
```

```text
node --test yinwei/contracts/v1/js/*.test.mjs
```

Do not run `flutter build`, `tools/build_native_windows.ps1`, or `cargo test -p spatial_core` for Phase 1A.
