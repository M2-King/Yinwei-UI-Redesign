# 音围 / Yinwei Spatial Player

Offline HRTF spatial audio **player** (Windows-first): open a local file → preview with position presets / orbit → export WAV.

## Layout

```
yinwei/
  docs/IMPLEMENTATION.md   # UI ↔ engine contract (from approved mockup)
  assets/ui-mockup.jpg     # Approved Apple-design reference
  crates/spatial_core/     # Rust engine API (DSP next)
  apps/yinwei_player/      # Flutter Windows UI shell
```

## Spec

See [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md).

## Develop

### Rust engine

```bash
cd yinwei
cargo test -p spatial_core
```

### Flutter UI

Requires Flutter SDK (Windows host for desktop target):

```bash
cd yinwei/apps/yinwei_player
flutter pub get
flutter run -d windows
```

## Status

- [x] Implementation spec + mockup
- [x] `spatial_core` public API + presets + tests
- [x] Flutter UI shell matching mockup (demo track / mock transport)
- [ ] Artezon HRTF + Mid/Side DSP
- [ ] cpal realtime + FRB wire-up
- [ ] Export WAV end-to-end
- [ ] Windows installer
