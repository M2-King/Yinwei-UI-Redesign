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

Mac CI execution is the next build verification step. Check its status and
artifacts before saying the friend has a ready app. Hardware acceptance remains
pending regardless of the CI result.

Automatic approval review rejected pushing the checkpoint branch to
`M2-King/Yinwei-UI-Redesign`: explicit authorization to export this code to that
destination was not established. No upload/CI dispatch took place. Ask the user
to authorize pushing `codex/macos-m1` to that repository and running the test
workflow; do not use a connector or alternative transport to bypass this review.
Local commits/source archives are available while that permission is pending.
