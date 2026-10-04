# Yinwei macOS friend test

This is a test build, not a validated public release. It includes the existing
Rust audio engine and interactive Three.js scene in WKWebView. Windows Island,
system media capture/Live Transfer and Windows installers are unavailable.

## Install

1. Download the artifact from the successful **Yinwei macOS Test Build** run.
2. Extract the outer GitHub artifact ZIP. Keep `BUILD-INFO.txt` and `SHA256SUMS`.
3. In Terminal, from that extracted folder: `shasum -a 256 -c SHA256SUMS`.
4. Open the included DMG and drag **Yinwei.app** into Applications. Alternatively,
   extract the inner app ZIP and move the complete app to Applications.
5. Open Yinwei. This test kit is ad-hoc signed and not notarized unless
   `BUILD-INFO.txt` says otherwise. macOS may block it. For a trusted build,
   use System Settings → Privacy & Security → Open Anyway after attempting to
   open it. Follow [Apple's instructions](https://support.apple.com/102445).
   Do not disable Gatekeeper globally.

The binary is intended to contain both Apple Silicon and Intel slices. The
generated deployment floor is macOS 12; real compatibility must be checked on
your Mac. Keep the whole `.app` together; the Rust dylib is inside it.

## Verify

Use headphones and a familiar WAV/MP3/FLAC track. Record your Mac model/chip,
macOS version, output device, commit and build number from `BUILD-INFO.txt`.

| Check | Expected result |
|---|---|
| Native backend | Backend says Native / spatial_core. Mock means failure. |
| Import | Open local audio, including a filename with spaces or Chinese characters. |
| Transport | Play, pause, seek and resume work without losing the track. |
| Original / Spatial | Both produce sound; spatial effect changes with position. |
| Position | Front/right/left/rear/elevation match the listener direction; distance changes remain stable. |
| Array | Existing 2.0 controls work, speakers respond, Point can be restored. |
| 3D scene | Actual speaker geometry, listener and source are visible; camera orbit/pan/zoom and view buttons work. |
| Drag / inspector | Source drag and inspector values stay synchronized; dragging visual emitters does not invent audio channels. |
| Files | Drag/drop import and WAV export work in user-selected locations. |
| Layout | Resize at 1024×640 and 1440×900; check Retina scaling, clipping and keyboard focus. |
| Lifecycle | Minimize/restore and close/reopen; no frozen scene or continued renderer activity after closing. |
| Stability | Play for at least 10 minutes and change position rapidly; note glitches, CPU and memory growth. |

The 8 physical scene speakers are visual emitters. They do not mean 8 discrete
audio output channels. Preserve the documented engine/scene semantics.

## Report

```text
Commit / build:
Mac model / chip:
macOS version:
Headphones / output device:
Native backend shown: yes/no
Audio formats tested:
Playback / seek / export:
HRTF directions / distance:
Array / Point switching:
Camera / source drag / inspector:
Window / Retina / minimize:
CPU / memory / glitches after 10 minutes:
Failure steps and expected result:
Screenshots / recordings:
```

For startup or scene problems, quit the app and launch from Terminal to capture
logs (this path assumes it was installed in Applications):

```bash
/Applications/Yinwei.app/Contents/MacOS/Yinwei 2>&1 | tee ~/Desktop/yinwei-test.log
```

Inspect messages beginning `[SpatialWorkspace]` and `[SpatialWorkspace macOS]`.
Record native library errors, WebGL/JavaScript errors and crashes. A fallback
visualization or mock backend is not acceptance of the real 3D/audio integration.
Review logs before sharing; local filenames can appear in diagnostic output.
