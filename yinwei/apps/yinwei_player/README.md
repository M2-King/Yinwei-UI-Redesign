# yinwei_player

Flutter desktop shell for 音围 / Yinwei Spatial.

## Live Transfer (Windows Full window)

Code in-tree is **not** listen-accepted. Overlay on the same output device is preview-grade: WASAPI process loopback **copies** PCM; the music app still plays dry on its device.

### Device split (required to hear wet Spatial)

1. In **Windows Volume Mixer** (or per-app output), route 汽水 / 网易云 / Spotify / QQ 音乐 to **speakers**.
2. In Yinwei Full, pick **headphones** as wet output (headphones icon on the SMTC strip). Empty = default device.
3. Start Transfer. A/B Spatial vs Original on the visualizer / mode chip.
4. If the room must be quiet, **mute the speaker device**. Never mute the music **app** session (`setSourceMuted` is a no-op — 汽水 / Spotify auto-pause).

Do not treat SMTC title, LIVE labels, or captured-frame counters as proof of wet audio. Pass = wet sound can be heard, toggled, and compared in Full.

Island shows SMTC metadata and Yinwei file Spatial. Island Transfer is not product-ready.

### Rebuild native DLL

```powershell
# Quit yinwei_player fully (not Flutter hot restart) so spatial_core.dll is not locked.
powershell -ExecutionPolicy Bypass -File yinwei/tools/build_native_windows.ps1
cd yinwei/apps/yinwei_player
flutter run -d windows
```

Hot restart will keep a stale DLL. Fully quit, rebuild, start again.
