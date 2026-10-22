# Soda music search release — 22 October 2026

Owner approved app release after the separate browser preview could not establish
its owner session on Safari. The app uses the existing Yinwei authentication and
command transport, not the preview cookie, key or HTTP helper. This does not prove
an upstream Soda account login works.

## Included

- Cached playlist search in the existing Music sheet, preserving list browsing,
  partial-cache counts and historical snapshots. Liked songs is labelled in English
  using the host's liked-list identity, not a title heuristic.
- Optional host-side anonymous search in a separate “On 汽水” section and current
  listening-mode labels, through existing authenticated commands. Generated local
  provider identities, bounded requests, opaque handles and revisions; no cookies,
  account login, audio download or new listening socket.
- Cached-track launch inspection is prefetched when browsing the sheet to avoid
  repeating its slow Windows lookup on an immediate tap. Existing numeric-only
  deep links, running-process validation, selection revalidation, control lease and
  final dispatch guard remain in place. Cache reads retain their strict deadline.
- A metadata dump CLI used only by the private preview; in-memory history, no
  provider credential/account files, playback or disk-history writes.

## Unavailable

Soda account login (upstream QR error 2156), account API collections, actual queue,
mode songs/active Soda mode switching, and online-result playback. Online playback
remains gated until its separate supervised playback test passes. Existing cached
playlist playback remains available. Releasing does not override these gates.

The online adapter remains default off in source (`YINWEI_SODA_ONLINE=1` enables
it on a supported Windows host). The matching laptop bundle/switch and enablement
are being confirmed separately; an iPad release alone cannot enable host features.

## Validation before release

- Full Flutter suite: **933 passed, 6 skipped**.
- Full Listen Room/remote Node suite: **57 passed** after the liked-label test.
- Dart analysis: **0 errors**, 6 existing warnings and 111 information findings
  (same baseline as the integration report). No protected code was edited to
  suppress diagnostics.
- Preview-independent adapter and command tests cover bounds, credentials/privacy,
  handle/revision validation, lease/takeover and deduplication. Real metadata probes
  and prior UI evidence are documented in `SODA_ONLINE_INTEGRATION_PROGRESS.md`.
- Windows release build, macOS CI/Swift checks, IPA verification and publication
  results will be recorded after their actual completion.

No `.tmp/`, website changes, private preview keys, credential/identity files,
deployment files, output bundles or DLLs belong in the release commit. The existing
dirty runner DLL must never be staged. Engine/HRTF/DSP/Live capture are unchanged.

MIT reference attribution is retained in `SODA_QISHUI_API_REFERENCE_LICENSE.txt`;
source revision and provenance are recorded in `SODA_API_PHASE0_REPORT.md`. No AGPL
implementation was copied into the adapter. Roll back to the previous host bundle
and iPad IPA, or leave the host's online switch off; existing cache browsing and
the public/ Tailscale transport configurations remain independent.
