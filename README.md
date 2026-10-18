# 音围 Yinwei — 听见空间

**Yinwei is a spatial audio player.** It takes ordinary stereo music and places
it in a real 3D space around you: in front, behind, above, moving in orbit. You
hear it through headphones with HRTF (head-related transfer function)
processing, and you see and move the sound in an interactive 3D workspace.

Website: <https://workspace-khz2prs8-qjvhzxns.edgeone.cool/>

## What it does

- **Place sound in 3D.** Drag the source around the listener in the spatial
  workspace, or set azimuth, elevation and distance directly. Presets and
  orbit motion move it for you.
- **Original ↔ Spatial.** Switch between the untouched track and the
  processed version at any time to compare.
- **Speaker layouts.** A single point source, or a stereo/multi-speaker array
  rendered as physical speakers in the room.
- **Studio processing.** HRTF rendering with EQ, reverb, crossover and
  crossfeed in one native engine.
- **Export.** Render the processed result to a WAV file.

## Ways to listen

| Mode | Where the music plays | What you hear |
|---|---|---|
| **Windows player** | Open a local file in Yinwei on the laptop | Spatial audio on the laptop's headphones or speakers |
| **Windows Live Transfer** | Any music app on the laptop (e.g. 汽水音乐) | Yinwei captures that app live, spatializes it, and sends the app's original sound to a silent virtual device, so only the spatial version is heard |
| **Laptop → iPad (browser)** | Music plays on the laptop | Open the protected Yinwei page in Safari, sign in and tap **Listen**. The page also controls the laptop's music (previous/play/pause/next), position and Original/Spatial |
| **iPad app** | Files you open or share to Yinwei on the iPad | The engine runs entirely on the iPad: no laptop, no network |

Live capture of another app on the iPad itself is experimental: iPadOS does
not let one app silence another, so the original stays audible next to the
spatial version.

## How it is built

```text
UI (Flutter: Windows, iPad/iOS, macOS, Android)
        │  intents
        ▼
Spatial state / scene contract ──► Three.js spatial workspace (WebView)
        │  projected parameters
        ▼
spatial_core (Rust): decode → HRTF / EQ / reverb / crossover → output
```

- **One spatial authority.** The UI never writes audio parameters directly;
  every change goes through the shared spatial state, which drives both the
  engine and the 3D view.
- **Coordinates.** +X right, +Y up, −Z front. Azimuth 0° is front, +90° right,
  −90° left, ±180° rear.
- **Remote listening.** The laptop exposes an owner-only HTTPS gateway through
  a Cloudflare tunnel. The browser receives already-processed stereo PCM; no
  second audio engine runs in the browser.

## Repository layout

```text
yinwei/
  crates/spatial_core/     Rust audio engine (HRTF, DSP, playback, live ingress)
  crates/yinwei_cli/       Command-line render/export
  apps/yinwei_player/      Flutter app for every platform
    assets/remote/         Browser listening page (served by the laptop)
    ios/                   iPad app and ReplayKit broadcast extension
  tools/remote/            Laptop backend launcher, tunnel and entry Worker
  docs/                    Architecture, implementation plans and records
website/                   Public product and download site
Start-Yinwei-Backend.bat   Starts the laptop backend for iPad listening
```

## Build and run

Rust engine:

```bash
cd yinwei
cargo test -p spatial_core
cargo run -p yinwei_cli --release -- sample.wav -o out.wav --preset left-rear
```

Windows app:

```bash
cd yinwei/apps/yinwei_player
flutter pub get
flutter test
flutter run -d windows
```

iPad/iOS builds run on macOS through the **Yinwei iOS Unsigned IPA** GitHub
Actions workflow; the IPA must be signed before installing.

Laptop backend for iPad listening: run `Start-Yinwei-Backend.bat`, wait for
**BACKEND READY**, then open the Yinwei bookmark on the iPad. Only one Yinwei
can run on the laptop at a time.

## Status

Active development. Working today: Windows local playback and export,
Windows Live Transfer with silent-device routing, and laptop-to-iPad browser
listening with remote controls. Native iPad file playback is built and
awaiting on-device testing; iPad live capture and lock-screen controls are
still in progress. Detailed plans and verification records are in
[`yinwei/docs`](yinwei/docs).
