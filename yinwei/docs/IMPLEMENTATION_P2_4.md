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

If you see **No Windows desktop project configured**, pull latest (repo now includes `windows/`), or run once:

```powershell
flutter create --platforms=windows .
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

## P2.4.2 — MP4 / MOV audio extract

Open dialog accepts `mp4` / `m4v` / `mov`. Decoder selects the **audio** track inside the container (skips video), using Symphonia `isomp4` + AAC.

Rebuild native DLL after pull:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_native_windows.ps1
```

Status bar should show `p2.4.2-mp4`.

## P2.4.3 — MP4 pitch / “电子音” fix

Extractor is still **Symphonia** (`isomp4` + AAC), not FFmpeg. Video-only chipmunk / harsh playback came from decode bugs:

1. **Mono AAC treated as stereo** when channel count was taken only from incomplete container params (`unwrap_or(2)`), so adjacent mono samples were paired as L/R → ~2× speed + metallic timbre. Now channel count / rate come from the **decoded** `AudioBuffer` spec.
2. **`SampleBuffer` not grown** when later AAC packets needed more samples than the first packet (capacity is in *samples*, buffer size is in *frames*).
3. Realtime cpal stream no longer always forces the device default rate over content 44.1 kHz.

Rebuild DLL after pull. Status bar: `p2.4.3-mp4-fix`.

## P2.4.4 — Envelopment audible on mono

Earlier Envelopment only scaled Mid/Side **Side** (L−R). Mono / hard-centered tracks → Side≈0 → slider did nothing.

Now: Mid highs also bleed into ±110° ambient HRTF paths, and Mid focus is slightly reduced as envelopment rises. Status: `p2.4.4-envelopment`.

## P2.4.5 — Drag-drop + correct native sample rate

1. **Drag & drop** audio/video onto the player window (`desktop_drop`).
2. **Speed / "phone" tone**: decode no longer forces 44.1 kHz; playback opens the cpal stream at the **content** rate (do not overwrite with the device default). Orbit Mid HRTF is rendered once (was double-processed → metallic noise). Air absorption softened near-field.

Status: `p2.4.5-drop-rate` / `ui-7`.

## Next

**P2.5** — richer export file dialog / progress UX polish (open picker already minimal in P2.4).

## P2.4.1 follow-ups (distance + live 音位)

| Issue | Fix |
|-------|-----|
| Distance felt like volume only | Softer inverse gain + air absorption LP + reverb wet↑ with distance |
| Spatial pose needed pause→play | Debounced live `rebuildPreview` while playing; buffer hot-swap keeps playhead |

Rebuild DLL after pull:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_native_windows.ps1
```

Status bar bridge id should show `p2.4.1-live` (or newer).
