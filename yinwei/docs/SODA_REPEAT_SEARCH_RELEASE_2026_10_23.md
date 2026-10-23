# Repeated Soda search reliability

Repeated typing previously started a provider request after 300 ms and aborted the
active connection on each new query. A reply could also appear for an old query
during the next debounce interval. The installed iPad's failure after two or three
searches has not been reproduced end to end; provider throttling is not proven.

The adapter now finishes its bounded active request and runs only the newest
waiting search, without automatic retries. The sheet waits 600 ms after typing,
invalidates old replies immediately, and prevents duplicate Enter submissions.
Editing away and back to a pending query still creates a valid new request.
HTTP 429 backs off for a bounded Retry-After (default 30 seconds); cached pages
remain usable. An allowlist maps timeout, throttling, refusal and schema failures
to fixed messages without exposing provider errors, credentials or identifiers.

## Scoped files

- assets/listen_room/music.js
- lib/remote/soda_online.dart
- lib/remote/listen_room_bridge.dart
- test/listen_room/music_search_test.mjs
- test/remote/soda_online_test.dart
- test/remote/listen_room_bridge_test.dart
- This document.

App paths above are relative to yinwei/apps/yinwei_player. There are no changes to
login, playback enablement, engine, HRTF, DSP, Live capture, DLL source or routes.
The laptop package must use the existing pinned engine DLL and retain the current
Tailscale/online-browsing configuration.

## Verification before release

- Full Flutter: 937 passed, 6 skipped. Initial run had an unrelated Windows
  PathAccessException renaming the private-route fixture's pairs.json; that test
  passed alone, and the full rerun passed. No private-route code was changed.
- Full Node: 62 passed across test/listen_room/*.mjs and test/remote/*.mjs.
- Dart analysis: no errors; unchanged six warnings and 111 infos.
- Five bounded live anonymous searches passed before and after the patch: four
  provider responses with 20 rows each and one cached response. Post-patch reads
  took 2,417 / 1,404 / 864 / 1,009 ms. Temporary local IDs only; no account cookies.
- Regressions cover rapid replacement, ten successive sheet searches, failure
  recovery, stale replies, duplicate Enter, edit-away/back, and error privacy.
- Review HTML was generated. Browser policy blocked its local file URL, so no
  browser screenshot or real Safari/device verification is claimed. No policy
  workaround was attempted. UI interaction tests use a Node DOM fixture.

Release outcomes, IPA hashes and laptop health will be recorded in the local
.tmp/soda-release-63/RELEASE_REPORT.md after packaging and deployment.

## Device check and rollback

After installing the new iPad build, search ten distinct songs, then rapidly edit,
backspace and press Enter. The latest query should win, with no endless loading.
If the problem persists, record the fixed error message and whether cached search
still works. Do not infer provider throttling solely from the symptom.

Rollback uses the saved w28 deployment and its verified app.so. Close the new
player gracefully and use the existing launcher; do not replace or rebuild the
engine DLL. Existing audio playback and device listening still need an ear check.
