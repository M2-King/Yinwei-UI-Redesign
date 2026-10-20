# Listen Room added speakers — verification record

Implemented on `codex/ios-capture-ci`, 2026-10-20 (Asia/Shanghai).
No commit, staging, push, workflow, publication, IPA build, deployment, bundle
switch, native engine build, or running backend restart was performed.

## Result

The 2.0 Place popover lists/selects speakers, adds up to eight, removes only
added speakers, and places speakers by sliders or cabinet drag. Matrix-linked
edits reuse laptop group semantics. Host array state, selection and revisions
synchronize through the existing session/lease route. Every speaker edit carries
its starting revision; stale shifted-index edits and obsolete completed replays
are rejected. The acknowledged remote native path is separate from the local
UI's unchanged 32 ms throttle and reports existing ABI failures.

The room pools eight real cabinets with shared geometry/materials. Extra
cabinets do not cast shadows. No meshes are rebuilt during state ticks/drag.
Coordinate conventions, compatibility behavior, protocol and rollback details
are in [the implementation notes](../../IMPLEMENTATION_LISTEN_ROOM_SPEAKERS.md).

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Full `flutter test --no-pub --reporter expanded` | 752 passed, 6 skipped, exit 0 | [log](flutter-tests.txt) |
| Node Listen Room tests | 29 passed, 0 failed, exit 0 | [log](node-tests.txt) |
| `dart analyze` | 0 errors, 6 existing warnings, 111 existing infos; exit 2 | [log](dart-analysis.txt), [summary](analysis-summary.txt) |
| `flutter build windows --debug --no-pub` | succeeded in 36.2 s; exit 0 | [log](windows-build.txt) |
| Pure Python diagnostic tests | 2 passed; no DLL load/audio device | `python -m unittest discover -s tool/remote -p test_array_file_tap_probe.py` |
| Review generation | self-contained HTML generated; UTF-8 declared | [review page](review.html) |
| Browser runtime | 0 console errors in final review | [console](console-errors.json) |
| UI interactions | add/remove/select, max 8, L protection, drag, takeover/retake, Point round-trip passed | [checks](ui-checks.json) |

Node files (from `yinwei/apps/yinwei_player`):

- `test/listen_room/bridge_test.mjs`
- `test/listen_room/offline_contract_test.mjs`
- `test/listen_room/room_math_test.mjs`
- `test/listen_room/speakers_test.mjs`

No analyzer findings overlap task-added lines. The six warnings concern
pre-existing unused members/imports/parameters in engine_controller,
update_policy, position_sidebar and two older runtime tests. Analysis is not
claimed clean. The Windows build logged `Nuget is not installed` but completed;
its binary was not launched. Output: `apps/yinwei_player/build/windows/x64/runner/Debug/yinwei_player.exe`.

## Screenshots and interactions

- [Landscape, 1366 × 1024](landscape.jpg): Place open, three cabinets, speaker 3 at −70°/0°/1.8 m.
- [Dragged cabinet, 1366 × 1024](dragged-landscape.jpg): speaker 3 moved by real pointer drag to −99°/0°/1.0 m.
- [Portrait, 1024 × 1366](portrait.jpg): Place open with the dragged three-speaker layout.
- [Point regression view](point-regression.jpg): original Point pose remains +35°/+20°/3.2 m.

Add is disabled at 8; L has no Remove control. Removing an added speaker then
adding restores the count. Laptop takeover disables speaker controls; Take
control restores them. The dragged array pose survives Point → 2.0. These are
review stand-in interactions, not a deployed laptop/iPad session.

## Speed test

The room's existing dev-panel speed test, 1366 × 1024, device pixel ratio 1,
Windows in-app Chromium, ANGLE Direct3D11, NVIDIA RTX 5070 Laptop GPU.
Both Full passes use 1× because this display's maximum ratio is 1×.

| Fixture | Full pass 1 | Full pass 2 | Light | Meshes | GPU geometries |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2 speakers | 256 fps | 256 fps | 263 fps | 218 | 116 |
| 8 speakers, first run | 132 fps | 250 fps | 263 fps | 218 | 116 |
| 8 speakers, warmed repeat | 256 fps | 256 fps | 263 fps | 218 | 117 |
| After dragging speaker 3 | — | — | — | 218 | 117 |

Reports: [2](speed-2.txt), [8 initial](speed-8-initial.txt),
[8 warmed](speed-8.txt), [after drag](speed-after-drag.txt).
GPU geometry count rose by one after selection controls were exercised, then
stayed at 117 through dragging. First visibility can upload pooled geometry;
no mesh is rebuilt. Cabinet geometry/materials remain shared. Final-view draw counts were 168 (2 speakers)
and 201 (8); these vary with camera culling and effects. Cold-run variation is
retained rather than hidden. Startup/texture compilation hitches are recorded
in the raw reports. These are desktop GPU results, not iPad performance proof.

## Audio gate and remaining device checks

Pinned DLL hash checked before/after work:
`eb764148534b6f0df3d0de60c7b6f184fcbf5164ed7298d53a3de95bb6e8c036`.

File-array iPad audio remains **blocked by default**. The isolated gateway opt-in
is `YINWEI_ARRAY_FILE_AUDIO_VERIFIED=1` on a future backend launch, after verifying
the pinned tap. Nothing was enabled here. [Separate gateway + tests diff](gateway-file-audio-opt-in.patch)
keeps this routing change reviewable/revertible independently of speaker UI.

From repository root, inspection-only:

```powershell
python yinwei/apps/yinwei_player/tool/remote/check_array_file_tap.py
```

After stopping backend playback, run the explicit audible, isolated-process probe:

```powershell
python yinwei/apps/yinwei_player/tool/remote/check_array_file_tap.py --run --backend-idle
```

The harness checks the full pinned hash, enables Spatial+2.0 with three speakers
on generated WAV audio, isolates the added Mid voice, changes its azimuth/mute,
and compares file-tap L/R RMS and balance. A pre-array tap or silence cannot pass
its checks. The native probe was not run because it opens the default output
device and cannot promise not to interfere with running playback. Source code
was not treated as proof of pinned binary behavior.

Still needed: native diagnostic/ear result; iPad headphone HRTF positioning and
mute behavior in file and Live paths; laptop audio regression on the pinned
engine; actual two-way device session; iPad GPU/touch performance at eight
speakers, including extreme elevations. The existing ABI writes individual
speakers rather than an atomic array transaction; native failures are surfaced
but hardware-level transactional rollback is not claimed.

## Files and protected state

[Complete task source/test/document file list](files-changed.txt) (24 files), plus
this validation directory's HTML, screenshots, logs and isolated gateway patch.
Pre-existing website edits and the already-modified checked-in runner DLL were
left alone. No `crates/`, `outputs/`, `deployment.json`, HRTF, DSP or capture code
was modified. Nothing is staged.
