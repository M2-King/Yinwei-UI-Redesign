# Option A — play music inside Yinwei on the iPad

Date: 2026-10-18 · Status: **plan, awaiting owner approval** · Owner decision: option A

## Why

Live capture (ReplayKit → laptop → iPad) cannot remove the source app's own
("dry") audio. iPadOS gives Yinwei no public way to mute another app while it
is being captured; `.duckOthers` was tried on device and did not help. The
original and the spatial version therefore always play together, offset by the
internet round trip. ReplayKit can also recapture Yinwei's own output (the
return-tone recapture check was never completed), which matches the reported
sound after pausing.

When Yinwei plays the file itself, only the processed output exists. This
matches the product boundary already in `IMPLEMENTATION_IPAD_STANDALONE.md`:
process exactly once, one audible path, no laptop or network needed.

## What already exists (source complete 2026-10-13, phases P0/I0/I1)

- **Open** button on the iPad player transport (`ios-open-file-button`) →
  `MediaFileAcquisition` copies the chosen file into a bounded app cache
  (8 files / 2 GiB) → `EngineController.openPath` → existing `PlayerSession`.
- `spatial_core` is built for `aarch64-apple-ios` **with** `realtime` (cpal
  output) by `tools/build_native_ios.sh`; `verify_ios_ffi.sh` checks the
  symbols in every CI IPA. So every IPA sent in this session already contains it.
- Exclusive `.playback` session owned by the playback channel; no mixing.
- Processed-WAV export through the share sheet.
- Original/Spatial, Point/array, EQ, azimuth/elevation/distance, orbit use the
  existing controller → spatial store → audio projection path.

Not yet proven: **any of it on the actual iPad** (Gate I1 is open).

## Constraint the owner must know

Only files the owner can put in the Files app work: MP3, AAC/M4A, FLAC, WAV,
OGG (decoder-dependent), or a video's audio track. **Streaming-app downloads
(Apple Music, 汽水音乐 and similar) are DRM-protected and cannot be imported.**
That is a platform rule, not something Yinwei can work around.

## Phases

### A0 — device acceptance of what exists (owner, ~10 min, no code)

With the laptop off and Wi-Fi off:

1. Open Yinwei → **Open** → pick an MP3/FLAC/M4A from Files.
2. Confirm the snackbar says `已打开（真引擎）` (native engine), never Mock.
3. Play, pause, seek, play to the end.
4. Switch Original ↔ Spatial; move the source left/right/front/rear/up.
5. Lock the iPad and switch apps for 1 minute; note whether audio continues.
6. Repeat 3–4 on Bluetooth headphones and on the iPad speakers.
7. Export processed WAV and reopen it.

Report: works / silent / choppy / crashes, per step, plus a screenshot.

### A1 — fix what A0 finds (engineer)

Most likely outcomes and the planned response:

| A0 result | Response |
|---|---|
| All steps pass | Go to A2 |
| Silent or choppy output on iPad | Add the planned iOS output adapter: `AVAudioEngine` source node draining processed PCM from a bounded queue filled by `spatial_core` (no DSP on the audio callback; Rust DSP unchanged). This is new work already specified in the standalone plan |
| Stops in background | Verify `UIBackgroundModes=audio` and session activation order; keep the session active while playing |
| Route change breaks audio | Rebuild output on `AVAudioSession.routeChangeNotification` without resetting spatial state |

### A2 — make it the default iPad experience (engineer, needs approval)

1. Library: keep imported files listed across launches (bounded cache already
   exists); add remove/reorder.
2. Now Playing / lock-screen controls (`MPNowPlayingInfoCenter`,
   `MPRemoteCommandCenter`) once A0/A1 lifecycle is stable.
3. Move the laptop live-capture screen under an "Experimental" label so it is
   not the main way to listen; leave it working for comparison.
4. Optional: "Open in Yinwei" from the Files share sheet
   (`CFBundleDocumentTypes` for audio UTIs).

### A3 — signed delivery

Same route as today (owner re-signs the unsigned IPA) until the Apple
Developer/TestFlight items in `IPAD_P0_BUILD_RECORD.md` are completed.

## Protected / unchanged

Rust decode, HRTF, EQ, reverb, resampling, spatial contract and coordinate
frame; the Windows laptop backend (w2) and Windows Live Transfer; the laptop
live-capture path (kept, demoted in A2).

## Tests

- Existing Flutter suite + iOS contract tests in CI on every IPA.
- A1 output adapter: bounded-queue unit tests in Swift (`test/native_capture`
  style) and a mock-runtime Dart test; no claim of audio correctness without
  the owner hearing it on device.
- A0 checklist repeated on each new IPA.

## Rollback

Each phase is a separate commit on `codex/ios-capture-ci`. The live-capture
path is not removed, so reverting A2 restores today's behaviour. The laptop
backend is untouched by option A.
