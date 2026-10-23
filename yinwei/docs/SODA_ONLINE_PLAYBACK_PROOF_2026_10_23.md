# Online result playback proof — 2026-10-23

The owner confirmed Live was running and the iPad was listening, then authorized
one supervised online-result play request using the existing local probe.

## Observed result

- Anonymous search returned "Don't Stop" by 任性, duration 162 seconds.
- The probe selected its opaque handle and current revision, resolved its validated
  numeric track ID on the host, and submitted the existing luna:// track link once
  through SodaTrackLauncher. No external URL or client-supplied numeric ID was used.
- Submission took 2,418 ms, including the cold handler/running-app identity check.
  This is dispatch timing, not end-to-end iPad audio latency. The production cached
  browse already prefetches that identity check when the sheet opens/searches.
- Before dispatch, Soda's Windows media session reported a different track playing.
  After dispatch it reported "Don't Stop" / 任性 / Playing, duration 162 seconds.
- The owner explicitly confirmed: "Yes, I heard that song" on the iPad.
- The foreground process was Explorer at both observation samples. These samples
  do not rule out a brief foreground change during dispatch. Do not promise either
  that Soda always comes forward or that it always stays in the background.
- The current track changed; the full queue was not accessible and its contents
  were not verified. No claim is made that the queue was preserved, appended or
  cleared. Existing UI warns that playback can affect Soda's foreground/queue.
- The probe did not start/stop Live, pause music, restart Soda/Yinwei, alter audio
  routes or read provider account cookies. Playback was submitted exactly once.

## Enablement

The Windows host's existing YINWEI_SODA_ONLINE opt-in now constructs SodaOnline
with playbackVerified=true. The same existing callback advertises sodaOnlinePlay
and accepts soda.play for every eligible result; this is not a per-song whitelist.
The general adapter remains browse-only by default for unverified callers/tests.

Existing safeguards remain: current opaque result handles, revision and 60-second
expiry; provider metadata availability checks; decimal IDs only on the host; exact
installed/running Soda handler validation; existing control lease and last-moment
takeover guard; command-ID deduplication and no retry of ambiguous dispatch.
Provider availability/restrictions still apply. Login and listening-mode contents
are unchanged. No engine, HRTF, DSP, capture or DLL source was modified.

iPad build 63 already handles sodaOnlinePlay and the enabled result buttons.
Only a matching laptop bundle update is needed. No new IPA is required for this
capability. The laptop switch will briefly disconnect Listen; audible playback and
the first actual iPad tap after that switch still require a device check.

Validation and deployment outcomes are recorded locally under
.tmp/soda-online-playback-release/RELEASE_REPORT.md.

Local verification before packaging: full Flutter 937 passed / 6 skipped; full
Node 62 passed; Dart analysis zero errors with the existing six warnings and
111 infos. The prior playback preflight also passed 27 launcher/coordinator tests
covering malformed IDs, revisions, leases, takeover and duplicate dispatch.
