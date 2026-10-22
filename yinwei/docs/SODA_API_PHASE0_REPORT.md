# 汽水 API Phase 0 — anonymous metadata validation

2026-10-22 · `codex/ios-capture-ci` · research/test artifacts only

## Result and gate

**Anonymous online search and the mode catalogue worked from this laptop.** Five provider requests were made, without login, cookies, signatures or desktop account access. One public query was tested twice. Its 20 numeric track IDs, metadata and ordering were stable between those two reads.

**The full Phase 0 gate is not yet passed:** returned IDs meet the existing launcher's decimal-ID contract, but no newly returned online result was played. The earlier supervised cached-track deep-link test does not establish availability or playback correctness for these new results. One owner-supervised result selection/foreground/queue/audio check remains necessary. No playback request was sent in this phase.

This is sufficient evidence to justify further work on anonymous search, not evidence of a complete or durable provider integration. Account access, personal playlists through the API, recommendation content, pagination and official-app mode changes remain unverified.

## Pinned source and licence review

| Source | Exact revision | Licence and treatment |
| --- | --- | --- |
| [guowenye/qishui-api](https://github.com/guowenye/qishui-api/tree/e409c10fe7441a10d370da7da61d62bbc1e5126c) | `e409c10fe7441a10d370da7da61d62bbc1e5126c` | [MIT licence](https://github.com/guowenye/qishui-api/blob/e409c10fe7441a10d370da7da61d62bbc1e5126c/LICENSE), copyright 2026 arrow. Reviewed config, client, HTTP/normalizer helpers and search/mode wrappers. Selected MIT files and the full notice are retained only under `.tmp/soda-phase0/mit-reference/`. No package installation, upstream execution or product-code adaptation. |
| [sodahub-org/libresoda](https://github.com/sodahub-org/libresoda/tree/f13712c7bc1abc6bc4d727575a5f034de1642547) | `f13712c7bc1abc6bc4d727575a5f034de1642547` | AGPL-3.0. Reviewed licence, search/feed sources in memory for endpoint and schema comparison. No implementation copied into Yinwei and no upstream code executed. |
| [guohuiyuan/music-lib](https://github.com/guohuiyuan/music-lib/tree/6353508e84cd357b5bc3acf32d95a16e01bbe20c) | `6353508e84cd357b5bc3acf32d95a16e01bbe20c` | AGPL-3.0. Reviewed licence/search sources in memory for protocol comparison. No implementation copied into Yinwei and no upstream code executed. |
| [qq01-hub/Meting-API](https://github.com/qq01-hub/Meting-API/tree/41705014dff5a9cf28c845a12d45636f66256d35) | `41705014dff5a9cf28c845a12d45636f66256d35` | `package.json` declares MIT, but the pinned tree has no licence file. Not selected for reuse; package declaration alone was not treated as a complete reuse review. |

The MIT client documents PC search and the mobile mode endpoint. The AGPL references additionally identify Android-style search and the PC mode endpoint; endpoint names, parameter names and observed protocol facts were used for an independently written standard-library HTTP probe, not translated implementation code. No signing SDK, decryption/audio resolver, packaged assets, download code or third-party service was used.

References contain fixed IDs in some paths. None were transmitted. The probe generated fresh 16-digit `device_id` and `iid` values with Python `secrets`, plus a UUID `cdid`, locally on this laptop. They are synthetic probe identifiers, **not provider-issued registrations** or extracted official-app identifiers. `fp` used the locally generated device value. Only `.tmp/soda-phase0/local-probe-identity.json` retains them; they are omitted from this report and response logs. No hardware identifier was read.

## Request shapes and bounds

All requests used HTTPS with normal certificate verification, `Accept: application/json`, `Accept-Encoding: identity`, and JSON content type. Redirects were refused. No Cookie, Authorization, X-Helios or X-Medusa headers were sent; response cookies were neither retained nor replayed. Provider identifiers, cookies and account data were not obtained from the desktop application.

The independently written probe enforced a 10-second hard subprocess deadline per read (including network work), 2 MiB response limit, JSON nesting limit 32, fixed allowed hosts and no automatic retry. Reads were sequential with a one-second gap; the sole deliberate repeat checked search stability. No new listener was opened.

Request details:

1. **PC search** — `GET https://api.qishui.com/luna/pc/search/track`
   - Public query `q=晴天`, `cursor=0`, `count=5`, `search_method=input`.
   - Client compatibility fields: `aid=386088`, `app_name=luna_pc`, `version_name=3.0.0`, `version_code=30000000`, `device_platform=windows`, `device_type=Windows`, `os_version=Windows 11`, `channel=official`, `build_mode=master`, `ac=wifi`, `tz_name=Asia/Shanghai`, CN region fields, fresh device/install/cdid/fp values; empty optional search-context fields.
   - User-Agent `LunaPC/3.0.0(290101097)`.
2. **Android-style search** — `GET https://api.qishui.com/luna/search/track`
   - Same public query, `cursor=0`, `count=5`; `aid=386088`, `app_name=luna`, `device_platform=android`, `os=android`, `version_name=19.8.0`, `version_code=100198030`, `channel=official`, `language=zh`, `ac=wifi`, `tz_name=Asia/Shanghai`, `sim_region=cn`, `need_personal_recommend=0`, fresh local identifiers and current `_rticket`.
   - User-Agent `com.luna.music/100198030 (Linux; Android 15; tt-ok/3.12.13.19)`.
   - These Android fields are a compatibility profile sent by a Windows research script, not a claim that this laptop runs Android. No reference person's device model or identifiers were reused.
3. **Mobile-reference catalogue** — `POST https://beta-luna.douyin.com/luna/feed/mode`, body `{}`, no query parameters. The probe used the PC User-Agent above; it did not need the MIT reference's Android User-Agent to obtain the observed catalogue.
4. **PC catalogue** — `POST https://api.qishui.com/luna/pc/feed/mode`, body `{}`, same PC compatibility/region/fresh-identifier fields as request 1, without search terms.
5. Repeat of request 2 with the same probe identity and query, for the stability check.

Version/client compatibility fields are experimental and may age. No claim is made that these are supported official APIs.

## Observed results

Times are this laptop's monotonic request/read/parse durations, not iPad timings or song-play latency. Five requests cannot establish p95 reliability.

| Request | HTTP | Time | Bytes | Outcome |
| --- | --- | ---: | ---: | --- |
| PC search | 200 | 265 ms | 0 | Empty body: failed/unusable; must not be presented as “no matching songs”. |
| Android-style search | 200 | 1,031 ms | 107,429 | 20 unique tracks with decimal IDs and metadata. |
| Mobile-reference catalogue | 200 | 719 ms | 18,090 | 45 unique mode IDs; `status_code=0`. |
| PC catalogue | 200 | 328 ms | 17,937 | 45 unique mode IDs; `status_code=0`. |
| Android-style search repeat | 200 | 1,032 ms | 107,429 | Same 20 IDs and ordering as first read. |

Despite `count=5`, search returned 20 tracks. Client bounds must therefore be enforced independently of requested page size. No pagination follow-up was made, and provider cursor semantics are not verified. One query/two reads do not demonstrate complete catalogue coverage, query quality or long-term ID/order stability.

Search's observed root contains `result_groups`, `status_info`, `extra`; track objects occur at `result_groups[].data[].entity.track`. Observed useful fields are `id`, `name`, `artists[].name`, `duration` and `media_type`. The probe parsed all JSON integers as strings before selecting metadata, avoiding JavaScript precision loss for 19-digit IDs. Duration values have millisecond-like magnitudes (e.g. 281733); native app duration behavior was not independently measured. No audio URLs were fetched or retained.

Two public examples from the returned metadata: **晴天 — 季星白**, **晴天(原版) — 余笙**. Different recordings/versions are distinct IDs; matching titles must never be treated as matching recordings or availability rights.

Catalogue root: `feed_mode_block`, `feed_mode_bar`, `status_code`, `status_info`. Entries contain `entity.feed_scene_mode` with `scene_mode_id` and `sub_queue_type`. Both replies exposed, among others:

| ID | Returned sub-queue identifier |
| --- | --- |
| 37 | `scene_mode_game` |
| 6 | `scene_mode_focus` |
| 48 | `scene_mode_library` |

These are anonymous catalogue entries, not verified personalized recommendations. Localized mode labels were not retained in the normalized probe output. Fetching the catalogue did not change the laptop app's mode or queue.

## Failures and uncertainties

- PC search returned HTTP 200 with no JSON. The cause is not established: signing, client identity/version, server policy or another behavior may be involved. No login/signing workaround was attempted.
- Web-viewer fetches for several pinned raw source URLs failed with cache misses; bounded direct GitHub reads succeeded instead. One raw GitHub fetch for the optional Meting package failed with an SSL unexpected-message error; the pinned package declaration was subsequently read through GitHub's contents API without disabling TLS checks.
- There were no provider read timeouts in this sample. HTTP success alone did not imply a valid response, as PC search demonstrated.
- No playback dispatch, song entitlement check, recommendation-content request, account/profile request, QR transaction or official app interaction occurred. Full deep-link correctness for online results remains unverified.

## Existing work and test-page boundary

The working tree's cached `SodaLibrary` search, `sodaSearch` capability and existing music sheet were preserved. `soda_library.dart` and `music.js` hashes match the start of this phase. No app source or test-page UI was edited. No synthetic online results were inserted or labelled as live functionality.

If the remaining gate is satisfied and integration is approved, preserve the same search box: **In your lists** first, then a separate **On 汽水** section. Local results should remain available when online search fails. Do not replace or delay local search, overload cached-list semantics, or imply that online searching proves a song is playable. That integration belongs to later phases, not this source/metadata validation phase.

## Artifacts and verification

New report: `yinwei/docs/SODA_API_PHASE0_REPORT.md`.

Research-only artifacts under `.tmp/soda-phase0/`:

- `sources.json` and `review_sources.py`: pinned source inventory.
- `read_mit.py`, `read_more.py`, `inspect_shapes.py`, `check_meting.py`: bounded source review scripts; no upstream implementation execution.
- `mit-reference/`: inspected MIT files and complete copyright/licence notice.
- `probe_metadata.py`: independent anonymous metadata probe.
- `probe-results.json`: bounded normalized public metadata and timings; no raw response bodies, provider cookies or account data.
- `local-probe-identity.json`: generated probe identity, deliberately not included in the report/UI or staged.
- `test_probe_metadata.py`: offline harness checks.

**8 offline tests passed:** large numeric IDs preserved, HTTP 200/empty-body classified as failure, response size bound, nesting bound, host restriction, response credential/unrelated-data exclusion, no outgoing authentication headers, redirect rejection.

Full Flutter/Node suites and UI screenshots were not rerun: product source and the test page were not changed. No iPad/Windows build, commit, push, publication, deployment change, bundle switch, backend restart, protected engine/capture/DLL modification or new listener occurred. The existing dirty runner DLL remained unchanged at SHA-256 `0d150deff17c3599c92244775b56c119a120604afed1297e150e2f0a2236305f`; `git diff --name-only -- yinwei/crates` is empty, and nothing was staged.

Stop here after Phase 0. The next missing evidence is a supervised playback check of a current online result; account login and product integration have not begun.
