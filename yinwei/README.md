# 音围 / Yinwei Spatial Player

Offline HRTF spatial audio **player** (Windows-first): open a local file → preview with position presets / orbit → export WAV.

## Layout

```
yinwei/
  docs/IMPLEMENTATION.md          # UI ↔ engine contract
  docs/IMPLEMENTATION_PHASES.md   # P0–P3 分段计划
  assets/                         # Desktop + mobile mockups
  crates/spatial_core/            # Rust HRTF engine + cpal
  crates/yinwei_cli/              # Export / --play CLI
  apps/yinwei_player/             # Flutter Windows UI shell
  apps/web_preview/               # Mobile UI preview
```

## Spec

- [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)
- [docs/IMPLEMENTATION_PHASES.md](docs/IMPLEMENTATION_PHASES.md)

## Develop

```bash
cd yinwei
cargo test -p spatial_core
cargo run -p yinwei_cli --release -- sample.wav -o out.wav --preset left-rear
cargo run -p yinwei_cli --release -- sample.wav --play --preset right --play-secs 5
```

Flutter (Windows host):

```bash
cd yinwei/apps/yinwei_player
flutter pub get
flutter run -d windows
```

## Status

- [x] UI mockups locked + phased implementation docs
- [x] **P0** offline HRTF + CLI export
- [x] **P1** `render_frames` + cpal `RealtimePlayer` + `--play`
- [ ] **P2** flutter_rust_bridge → Flutter player
- [ ] **P3** Windows installer
