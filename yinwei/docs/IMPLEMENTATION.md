# 音围 Spatial Player — Implementation Spec

> Source of truth for UI → state → engine mapping.  
> Mockup: [`../assets/ui-mockup.jpg`](../assets/ui-mockup.jpg)

## 1. Product lock

| Item | Value |
|------|--------|
| Name | 音围 / Spatial Player |
| Form | Local-file **player** → preview → confirm **Export WAV** |
| Platform MVP | Windows desktop (Flutter); architecture ready for macOS later |
| Stack | Flutter UI + Rust `spatial_core` via `flutter_rust_bridge` |
| Backend | None (fully offline) |
| Sources | Local audio only (MP3 / WAV / FLAC / OGG) |

## 2. UI regions (from mockup)

```
┌─ Title: 音围 / Spatial Player ─────────────────────────────┐
│  ┌─ OrbitVisualizer ─┐  ┌─ NowPlaying ──────┐  ┌─ Sidebar ┐ │
│  │  ring + blue dot  │  │  cover / meta     │  │ Position │ │
│  │  = source azimut  │  │  scrubber         │  │ presets  │ │
│  └───────────────────┘  │  transport        │  │ sliders  │ │
│                         │  Original\|Spatial│  │ Fixed\|  │ │
│                         └───────────────────┘  │ Orbit    │ │
│  status: Offline · Local file · Headphones     │ Export   │ │
└────────────────────────────────────────────────┴──────────┘
```

### 2.1 Now Playing (center)

| Control | Type | State field | Engine |
|---------|------|-------------|--------|
| Cover / title / artist / album | display | `TrackMeta` | from tags / filename |
| Scrubber | seek | `positionMs`, `durationMs` | `seek(ms)` |
| Prev / Play-Pause / Next | buttons | `isPlaying` | `play` / `pause` / queue later |
| Original \| Spatial | segmented | `PlaybackMode` | bypass HRTF vs process |

### 2.2 Position sidebar (right)

| Control | Mockup default | State | Engine |
|---------|----------------|-------|--------|
| Preset grid 3×3 | Right selected | `PositionPreset?` | sets az/el/dist |
| Azimuth | 110° | `azimuthDeg` −180…180 | HRTF direction |
| Elevation | −10° | `elevationDeg` −90…90 | HRTF elevation |
| Distance | 2.10 m | `distanceM` 0.5…10 | distance gain |
| Fixed Position \| Orbit | Fixed | `MotionMode` | freeze vs animate |
| Orbit Speed | 0.40 Hz | `orbitHz` | RPM = Hz × 60 |
| Envelopment | 60% | `envelopment` 0…1 | Side ambient amount |
| Reverb | 20% | `reverbMix` 0…1 | Artezon reverb mix |
| Export WAV | primary | — | offline render + save |
| Save Preset | secondary | local JSON | UI only (MVP) |

### 2.3 Orbit visualizer (left)

- Dot angle = current effective azimuth (fixed preset or live orbit).
- Trail opacity follows `isPlaying && mode == Spatial`.
- Click/drag on ring (v1.1): sets azimuth; MVP can be display-only synced to sliders.

### 2.4 Status bar

- `Offline` · `Local file` · `Headphones recommended` — static copy for MVP.

## 3. Position presets

| ID | Label | Azimuth° | Elevation° | Distance m |
|----|-------|----------|------------|------------|
| `front` | Front | 0 | 0 | 1.5 |
| `leftFront` | Left Front | −45 | 0 | 1.5 |
| `rightFront` | Right Front | 45 | 0 | 1.5 |
| `left` | Left | −90 | 0 | 1.5 |
| `right` | Right | 90 | 0 | 1.5 |
| `leftRear` | Left Rear | −135 | 0 | 1.5 |
| `rightRear` | Right Rear | 135 | 0 | 1.5 |
| `back` | Back | 180 | 0 | 1.5 |
| `overhead` | Overhead | 0 | 75 | 1.5 |

Selecting a preset writes az/el/dist; dragging a slider clears preset highlight (`selectedPreset = null`) unless values still match.

## 4. Engine pipeline

```
Local file
  → decode (symphonia)
  → optional Mid/Side split
  → Mid → front HRTF (or fixed preset)
  → Side → envelopment-weighted ambient / orbit HRTF
  → bass crossover passthrough (~80 Hz, Artezon)
  → reverb mix
  → stereo L/R
  → cpal (preview) OR WAV writer (export)
```

**Original mode:** decode → output (no HRTF).  
**Spatial mode:** full pipeline. Params hot-reload between blocks.

## 5. Rust crate API (`spatial_core`)

See [`crates/spatial_core/src/lib.rs`](../crates/spatial_core/src/lib.rs).

Public surface for Flutter bridge:

- `Engine::open(path) -> TrackInfo`
- `Engine::set_params(SpatialParams)`
- `Engine::set_playback_mode(Original|Spatial)`
- `Engine::play()` / `pause()` / `seek(ms)` / `position_ms()`
- `Engine::export_wav(out_path, on_progress) -> Result`
- `Engine::current_azimuth_deg()` — for visualizer (orbit time-aware)

## 6. Flutter module map

| Path | Role |
|------|------|
| `lib/models/spatial_params.dart` | mirrors Rust `SpatialParams` |
| `lib/theme/yinwei_theme.dart` | Apple dark tokens from mockup |
| `lib/widgets/orbit_visualizer.dart` | left ring + blue dot |
| `lib/widgets/now_playing_panel.dart` | cover, scrubber, transport, A/B |
| `lib/widgets/position_sidebar.dart` | presets, sliders, export |
| `lib/screens/player_screen.dart` | composes window layout |
| `lib/bridge/engine_api.dart` | FRB stubs → Rust |

## 7. Theme tokens (mockup)

| Token | Value |
|-------|--------|
| Background | `#0B0B0D` |
| Panel | `#141416` / `#1C1C1E` |
| Hairline | `white @ 8–12%` |
| Accent | `#0A84FF` (system blue) |
| Text primary | `#F5F5F7` |
| Text secondary | `#8E8E93` |
| Corner radius | 10–14 continuous |
| Font | SF Pro / system sans (Inter fallback on Windows) |

## 8. Implementation order

1. `spatial_core` types + stub DSP (passthrough) + tests  
2. Wire Artezon HRTF / M-S (next PR)  
3. Flutter UI pixel-close to mockup (mock engine)  
4. `flutter_rust_bridge` + cpal realtime  
5. Export WAV + Windows packaging  

## 9. Out of scope (MVP)

- Cloud backend, streaming platform sources, LX scripts  
- Custom SOFA import, batch queue  
- iOS / Android / macOS installers (keep API portable)

## 10. Acceptance

- UI matches mockup regions and controls  
- Fixed preset (e.g. Left Rear) audible vs Front under headphones  
- Original ↔ Spatial A/B works  
- Export WAV plays offline with same spatial settings  
- No network required for open → preview → export
