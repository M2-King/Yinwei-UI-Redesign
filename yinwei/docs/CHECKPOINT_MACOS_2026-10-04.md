# macOS checkpoint — 2026-10-04

## User intent and current authorization

Finish the macOS port and prepare a build for a friend to test. The user has no
Mac locally and authorized continuing implementation before hardware acceptance.
The user requested a checkpoint because usage is close to its limit; resume
from this file after usage resets. Do not restart the architecture audit.

## Repository and scope

- Workspace: `C:\Users\Tim-King.Kings-laptop\Documents\yinwei-repo`.
- Branch: `codex/macos-m1`.
- GitHub project: `M2-King/Yinwei-UI-Redesign`; remote `yinwei-ui-redesign`;
  base branch `release/github-integration`. The older `origin` repository is
  `M2-King/-`; do not send this release build there.
- Engineering plan: `yinwei/docs/IMPLEMENTATION_MACOS.md`.
- Friend instructions: `yinwei/docs/MACOS_FRIEND_TEST.md`.
- Main app: `yinwei/apps/yinwei_player` (Flutter); audio in Rust `spatial_core`.
- Do not rewrite audio/DSP, FFI contracts, coordinates or spatial state ownership.

The repository has unrelated uncommitted website, Windows update/route and
installer changes from earlier work. Preserve them. Commit only the macOS work;
stage shared screen/rail changes against HEAD without including those unrelated
edits. Baseline status is in `.tmp/macos-baseline-status.txt`; current inspection
is in `.tmp/macos-2026-10-04/status-before-checkpoint.txt`.

## Implemented source

- macOS runner; reliable `.app/Contents/Frameworks` FFI path.
- Rust architecture build, install-name fix, dylib signing/embedding and bundle
  architecture/signature checks.
- WKWebView host using the existing `webview_flutter` dependency, no new engine
  or duplicate Three.js scene. Early bridge injection, JSON transport, readiness
  timeout, navigation guard, scene errors and lifecycle/disposal handling.
- Renderer suspension/resumption stops animation frames while hidden.
- macOS file/Point/array/3D/drop capabilities; Windows-only integrations hidden.
- Universal app ZIP/DMG packaging, hashes and build metadata. Optional Developer
  ID/notary profile support exists, but no credentials are configured or stored.
- Mac CI workflow: `.github/workflows/macos-test-build.yml` (Flutter 3.47.2).
- Friend checklist and native FFI/export smoke test.

## Verification and remaining gates

M1 Windows results: 451 Flutter tests and 82 Rust tests passed, Windows debug
build/golden passed. The M2 focused adapter/bridge checks passed 53 tests.
Current final verification and Mac CI results must be recorded below before
claiming a finished build.

Full analysis previously reported 118 warning/information findings, no errors.
Flutter tests log an audio-route disposal warning in the existing dirty Windows
route code. Do not claim a clean console or silently alter protected route work.

Hardware playback/HRTF, actual WKWebView rendering, sandboxed import/export,
Retina layout, performance and clean-Mac install remain for the friend. No public
release is approved or claimed. Public Developer ID/notarization is optional
infrastructure until credentials/distribution requirements are provided.

## Resume sequence

1. Read this checkpoint and `git status`; preserve dirty user work.
2. Check the latest **Yinwei macOS Test Build** run on `codex/macos-m1`:
   `gh run list --repo M2-King/Yinwei-UI-Redesign --branch codex/macos-m1 --limit 3`.
   GitHub credentials only work outside the restricted sandbox; use the normal
   escalation mechanism for network/credential access. Never print the token.
3. If CI fails, inspect the failing job log, repair the macOS boundary/build
   issue, test the change and commit only its files. Keep Rust DSP unchanged.
4. If CI passes, download the test-kit artifact and give the user its link and
   `MACOS_FRIEND_TEST.md`. A CI build is not audible hardware acceptance.
5. Incorporate the friend's evidence, then close the remaining runtime/visual/
   performance gates. Select final bundle identity, icon, deployment support and
   public distribution/signing only with product authority.

## Final checkpoint results

Implementation checkpoint commit: `e3c586e` (follow-up checkpoint commits may
exist; inspect branch HEAD). Working-tree regression suite: 455 passed, one
Mac-only test skipped. The isolated committed-source platform/contract/runtime
suite passed 221 tests, proving it does not depend on unrelated local changes.
Shell syntax checks passed. Analysis had one new unnecessary import, removed
before upload; existing warnings/information findings remain.

Mac CI build verification passed in run `37186188824` (details below).
The friend test app is ready. Hardware acceptance remains pending.

The user explicitly approved pushing `codex/macos-m1` to
`M2-King/Yinwei-UI-Redesign` and running the test workflow. Upload succeeded.
The initial Mac run `37185611068` passed Rust regression tests, then failed
dependency resolution because the lockfile used a different package host from
CI. Package URLs are now normalized to `https://pub.dev`, with all versions and
hashes preserved. Isolated `flutter pub get --enforce-lockfile` passed against
that host. Check the latest run for the remaining build stages.

Final Windows debug build passed after the WKWebView changes; log:
`.tmp/macos-final-windows-build.log`. Test logs:
`.tmp/macos-final-tests.log` and `.tmp/macos-isolated-tests.log`.
The local committed-source ZIP is in
`outputs/macos-checkpoint-2026-10-04/Yinwei-macos-source-checkpoint.zip`.
This ZIP contains source, not a compiled macOS app. Resume by checking the latest
Mac workflow and inspecting its artifacts; upload authorization is already given.

## Approved CI verification — successful build

- Tested source: `606bbc433c2836a63f4dddd9377c3f26ab890d02`.
- Run: https://github.com/M2-King/Yinwei-UI-Redesign/actions/runs/37186188824.
- Artifact: https://github.com/M2-King/Yinwei-UI-Redesign/actions/runs/37186188824/artifacts/11296513565.
- Artifact name: `Yinwei-macos-test-3`; expires 2026-10-18 07:41 UTC.
- Mac Rust regression tests: 70 passed (platform-specific test counts differ
  from the Windows suite).
- Mac platform/contract/scene/UI suite: all 221 tests passed.
- Native Mac Rust dylib FFI smoke test: passed (real PCM open, Original/Spatial
  mode switching, WAV export).
- Universal release packaging: passed. Both app and embedded dylib contain
  arm64 + x86_64; bundle signature inspection passed. ZIP and DMG uploaded.
- Signing: ad-hoc test build, not notarized; no public release is claimed.
- Successful CI log: `.tmp/macos-ci-37186188824-success.log`.
- Downloaded kit: `outputs/macos-test-37186188824/`. Both ZIP and DMG SHA256
  values match `SHA256SUMS`. Independent ZIP inspection confirms the app and
  dylib contain arm64 + x86_64, and the offline Three.js scene is bundled.
- Earlier run `37185891366` passed 220 tests and exposed one Windows-only
  host-selection test assumption. The test now explicitly selects Windows and
  its seven focused host tests passed locally before upload.
- Hardware audible playback/HRTF and WKWebView visual acceptance still pending.

Next mission: share the test kit and `MACOS_FRIEND_TEST.md` with the friend.
Collect native-backend, playback/HRTF, sandbox file access, real 3D interaction,
Retina/minimize and 10-minute stability evidence. Repair reported issues before
closing Mac acceptance. Public bundle identity/icon/signing remain product and
distribution decisions.
