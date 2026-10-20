# yinwei_player

Flutter desktop shell for 音围 / Yinwei Spatial.

## Live Transfer (Windows Full window)

Code in-tree is **not** listen-accepted. Overlay on the same output device is preview-grade: WASAPI process loopback **copies** PCM; the music app still plays dry on its device.

### Device split

Wet output **defaults to the Windows default render device** (empty picker = follow default). Transfer does not auto-lock to a Sony `WH-` headset by name.

If a **separate speaker device** exists and it is **not** the wet destination, Yinwei pins the music app to those speakers and **mutes the speaker device**. That keeps dry out of the room / off the wet mix (process loopback still captures the muted render). Never mute the music **app** session (`setSourceMuted` is a no-op — 汽水 / Spotify auto-pause).

If the Windows default **is** the speakers (or Nahimic speakers), they stay unmuted — muting them would kill wet and any Nahimic Sound Sharing of that mix. Overlay on that device is preview-grade.

Manual isolation:

1. In Yinwei Full, leave wet on **默认输出** or pick **headphones**.
2. Start Transfer. A/B Spatial vs Original on the visualizer / mode chip.

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
