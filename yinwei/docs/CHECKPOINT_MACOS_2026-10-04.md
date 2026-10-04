# macOS checkpoint — 2026-10-04

## User intent and current authorization

Finish the macOS port and prepare a build for a friend to test. The user has no
Mac locally and authorized continuing implementation before hardware acceptance.
The user requested a checkpoint because usage is close to its limit; resume
from this file after usage resets. Do not restart the architecture audit.

## Repository and scope

- Workspace: `C:\Users\Tim-King.Kings-laptop\Documents\yinwei-repo`.
- Branch: `codex/macos-m1`.
- GitHub origin: `M2-King/-`; base branch `main`.
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
   `gh run list --repo M2-King/- --branch codex/macos-m1 --limit 3`.
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

Pending final test/commit/CI result; this section is updated at handoff.
