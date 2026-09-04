# P2.4 — Native bridge (C ABI + dart:ffi)

> UI frozen at ui-6. This slice connects Flutter to `spatial_core` for real HRTF play/export.

## Approach

Cloud agents cannot run `flutter_rust_bridge_codegen`. P2.4 ships a **stable C ABI** (`ffi.rs`) that mirrors `frb_api` / `PlayerSession`, loaded by Dart via `dart:ffi`.

| Layer | Path |
|-------|------|
| Rust session | `crates/spatial_core/src/session.rs` |
| FRB-shaped API | `crates/spatial_core/src/frb_api.rs` |
| C ABI | `crates/spatial_core/src/ffi.rs` → `spatial_core.dll` |
| Dart FFI | `apps/yinwei_player/lib/bridge/yinwei_bindings.dart` |
| Engine | `lib/bridge/native_engine.dart` |
| Boot | `lib/bridge/engine_bootstrap.dart` — Native if DLL loads, else Mock |

`flutter_rust_bridge.yaml` remains for a future optional codegen swap; ABI is the supported Windows path now.

## Windows host steps

```powershell
cd C:\yinwei-src\yinwei
powershell -ExecutionPolicy Bypass -File tools\build_native_windows.ps1

cd apps\yinwei_player
flutter pub get
flutter run -d windows
```

**Pass criteria**

1. Status bar left: green dot + `Native · spatial_core` (not Mock)
2. Open a local WAV/MP3 → Play with headphones → hear Spatial / presets
3. Export WAV writes a real file under Downloads

If status shows Mock: DLL missing — re-run the build script, then restart the app (hot reload will not reload native libs).

## Error codes (C ABI)

| Code | Meaning |
|------|---------|
| 0 | OK |
| 1 | FileNotFound |
| 2 | NoTrackLoaded |
| 3 | InvalidParam |
| 4 | Decode |
| 5 | AudioDevice (preview may still be ready) |
| 6 | Io |
| 7 | Other |

## Next

**P2.5** — richer export file dialog / progress UX polish (open picker already minimal in P2.4).
