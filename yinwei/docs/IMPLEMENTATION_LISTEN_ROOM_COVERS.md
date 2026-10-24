# Real song covers in the Listen Room (fetch, cache, show)

Status: plan, not started. Written 2026-10-24. The owner approved real covers
on 2026-10-24 and lifted `soda_library`'s "never downloads artwork" rule **for
covers only** (not audio, lyrics or anything else). Implementation needs the
owner's go-ahead per phase.

## 1. Goal

Show each song's real album cover wherever the room shows a cover today, fast
and offline-friendly:

- **Speed:** a cover appears within ~1 s on first view, and instantly after that.
- **Fallback:** the generated moon covers stay the fallback, so nothing is ever blank.
- **Privacy:** the page never sees track IDs, URLs or account data; covers are
  addressed by opaque keys.

Not in scope: room styling (Lakeside is next week), song colours or tinting
(the API's `colors` data is noted in §8 for later), audio, the engine, HRTF,
DSP, Live capture, and playback control.

## 2. What exists today (facts, 2026-10-24)

### Where covers are painted

All four places call `paintArt(hue, empty, canvas, variant)` (`assets/listen_room/ui.js:175`)
with a generated tint (`ListenBridge.hueOf`):

| Where | Code |
|---|---|
| Bottom bar cover `#art` | `ui.js:223` |
| Quick-menu background (focused song) | `ui.js:450` |
| Quick-menu song cards | `ui.js:458` |
| Window-mode panes (three.js texture) | `room.js:1725` (`CanvasTexture`) |

### What the room is told

- `track {title, artist}` for the playing song.
- `queue.songs[{title, artist}]`: the page never gets IDs. "Browse selections
  stay on this iPad. Only queue labels go to the room." (`listen_room_bridge.dart`).
- The iPad bridge keeps each queue song's track ID privately (`_RoomQueueSong.ids`).

### Cover data in 汽水's track objects (checked against the live API, 2026-10-24)

The same `track` object shape is used by:
- 汽水's online search (`api.qishui.com/luna/search/track`, used by `soda_online.dart`);
- 汽水's local cache, which `soda_cache_reader.dart` / `soda_library.dart` already
  parse (`entity.track`, or `entity.track_wrapper.track`).

| Field | Content |
|---|---|
| `track.album.url_cover.urls` | e.g. `https://p3-luna.douyinpic.com/img/`, `https://p6-luna.douyinpic.com/img/` |
| `track.album.url_cover.uri` | e.g. `tos-cn-v-<hex>/<id>` |
| `track.album.url_cover.template_prefix` | e.g. `tplv-b829550vbb` |
| `track.album.url_player_bg` | Large background image, template `background:${width}:${height}:30:90:0` (not used here) |
| `track.colors.background_color`, `cover_gradient_effect_color` | Song colours (for later styling) |

Image address: `urls[i] + uri + "~" + template_prefix + "-<size suffix>"`. The exact
cover size suffix is confirmed with one download in phase C0, not guessed.

### The playing song, from Windows

Windows' media session (SMTC) also offers a **thumbnail** for the playing song
(`TryGetMediaPropertiesAsync().Thumbnail`). It is useful when a song was started
on the laptop rather than from a Yinwei list. Yinwei does not read it today.

### Current rule

`soda_library.dart:20` says it never "downloads artwork/audio". This plan
changes that line to allow cover images only, through the one new class in §3.2.

## 3. Design

### 3.1 Flow

```
iPad page ── coverRequest {key} ──▶ iPad bridge (key → track ID, private)
                                       │ iPad cover cache hit? ──▶ page
                                       ▼
                     laptop read command `soda.cover` {track, size}
                                       │ laptop cover cache hit? ──▶ reply
                                       ▼
          cover descriptor from the cache/online track (uri, urls, template)
                                       ▼
                 HTTPS GET p*-luna.douyinpic.com (allow-listed) ──▶ validate
                                       ▼
                     laptop disk cache ──▶ reply {mime, base64}
iPad bridge ── YinweiListen.cover(key, dataUrl) ──▶ page repaints the 4 places
```

### 3.2 Laptop

- **Cover descriptor.** When `soda_library.dart` and `soda_online.dart` already
  parse a track, they also keep `album.url_cover` (`uri`, the first allow-listed
  `urls` entry, `template_prefix`). It is validated:
  - `uri` must match `^tos-[a-z0-9-]+/[A-Za-z0-9_-]{8,128}$`;
  - `template_prefix` must match `^tplv-[a-z0-9]{4,32}$`;
  - the host must match `^p[0-9]{1,2}-luna\.douyinpic\.com$`.
  Invalid data means no cover, never an error. The descriptor stays on the laptop:
  it is never sent to the iPad. History snapshots store it, which needs a
  snapshot format version bump; older snapshots simply have no cover.
- **`SodaCoverStore`** (`lib/remote/soda_cover_store.dart`, new). This is the only
  code allowed to download artwork.
  - HTTPS only, allow-listed host, path built only from a validated descriptor
    (never from a client).
  - No redirects; 8 s timeout; at most 512 KB.
  - The reply must be `image/jpeg`, `image/png` or `image/webp`, and the bytes must
    match their type's file signature.
  - At most 3 downloads at once; identical requests share one download.
  - A failed cover is not retried for 10 minutes.
  - Disk cache in `%LOCALAPPDATA%\Yinwei\covers\`. Each file is named by
    `sha256(trackId|size)`, so track IDs don't appear in file names. 100 MB cap,
    oldest-used deleted first. Size: one fixed cover size (about 360 px,
    confirmed in C0).
- **Read command `soda.cover`.** It goes through the existing commands endpoint
  like `library.list` (`app_session_coordinator.dart:443`): owner-authenticated,
  no control lease, never changes playback.
  - Payload: `{track: <id>, size: "small"}`; the track ID is validated like
    today's selections.
  - Reply: `{mime, data (base64), etag}`, or `{error: 'cover_unavailable'}`.
  - A new capability `sodaCovers` lets old iPads ignore it and new iPads detect it.
- **Playing-song thumbnail** (phase C4). When the playing title changes, the
  media daemon reads the SMTC thumbnail once: at most 512 KB, validated as above,
  kept in memory for the current song only. A read command `media.cover` returns
  it. It is used only when the playing song is not in the current Yinwei list.

### 3.3 iPad bridge (Dart)

- **Opaque cover keys.** Each queue song and the playing track get a `cover` key in
  the page state: the first 16 hex characters of `HMAC-SHA256(sessionSecret, trackId)`.
  The secret is new for each app run, so keys reveal nothing and can't be reused
  across sessions. The bridge keeps `key → trackId` privately.
  - Live with no matching queue song: the key is `now:<hash of the title>`, served
    from `media.cover`.
- **Page intent `coverRequest {key}`.** It is validated against the known keys.
  At most 6 requests are in flight; unknown keys are ignored.
- **iPad cover cache:**
  - in memory, the 64 most recent covers;
  - on disk in the app's caches folder (`covers/`, 50 MB, oldest-used deleted
    first). iOS may clear that folder, which is fine.
  A hit answers without contacting the laptop.
- **Delivery:** `YinweiListen.cover(key, "data:image/jpeg;base64,…")`, sent through the
  existing `run` and only while the page is visible (not in the background).
  The 10-per-second state messages never carry images.

### 3.4 Page (assets/listen_room)

- New `ListenCovers` in `bridge.js`. A separate file would also have to be added
  to the files the app inlines into one document (`ListenRoomHtml`).
  - decodes each data URL once (`Image` + `decode()`), keeps the 64 most recent;
  - `drawCover(canvas, song)` draws the real cover (cropped square, the same
    rounded look) or falls back to `paintArt` while loading or on failure;
  - when a cover arrives, it repaints only the places that show that key (bottom
    bar, quick-menu card/background, window pane texture, with `needsUpdate`),
    with a short cross-fade.
- **Requests only covers that are about to show:** the playing song, the
  quick-menu's visible ±3 cards, the visible window panes. No bulk prefetch of
  500-song lists.
- **Offline contract unchanged:** no http(s) address in the shipped files; images
  arrive as `data:` URLs from the app (`test/listen_room/offline_contract_test.mjs`
  must still pass).
- **Layout and style unchanged:** the real cover replaces the generated picture
  inside the same frame.

## 4. Files

| Side | File | Change |
|---|---|---|
| Laptop | `lib/remote/soda_cover_store.dart` (new) | Allow-listed download, validation, disk cache, limits |
| Laptop | `lib/remote/soda_library.dart` | Keep the validated cover descriptor per track; snapshot version bump; header rule changed to "covers only" |
| Laptop | `lib/remote/soda_online.dart` | Keep the descriptor for search rows |
| Laptop | `lib/state/app_session_coordinator.dart` | `soda.cover` (and C4 `media.cover`) read commands; `sodaCovers` capability |
| Laptop | `lib/screens/player_screen.dart` | Wire the store into the coordinator |
| Laptop (C4) | `lib/bridge/system_media.dart` | Thumbnail once per title change |
| iPad | `lib/remote/remote_owner_client.dart`, `laptop_listen_controller.dart` | `soda.cover` / `media.cover` calls |
| iPad | `lib/remote/listen_room_bridge.dart` | Cover keys in state, `coverRequest` intent, iPad cache, delivery |
| iPad | `lib/remote/listen_cover_cache.dart` (new) | Memory + disk cache |
| Page | `assets/listen_room/bridge.js`, `ui.js`, `room.js` | `ListenCovers`, `drawCover` in the 4 places, `YinweiListen.cover` |

Untouched: the engine, `spatial_core.dll`, HRTF, DSP, Live capture, the audio
route, the UDP work, `soda_track_launcher.dart` playback rules, and the room layout.

## 5. Phases and gates

| Phase | Content | Gate |
|---|---|---|
| C0 | One read-only download per source (online search row, one cached row): confirm the size suffix, bytes, type, speed | Suffix and sizes recorded in this file |
| C1 | Laptop: descriptor, `SodaCoverStore`, `soda.cover`, capability | Unit tests and one real download through the command |
| C2 | iPad bridge: keys, intent, cache, delivery | Bridge tests with a fake client; no IDs in page state |
| C3 | Page: `ListenCovers`, `drawCover` in the 4 places | Node tests and a browser check with the dev host; screenshots of each place |
| C4 | Playing-song thumbnail from Windows (`media.cover`) | Song started on the laptop shows its cover |
| Ship | Laptop bundle + iPad build | Owner checks on the iPad |

## 6. Tests

- **Descriptor validation:** good, bad and hostile values (a foreign host, `..`,
  query strings, an over-long uri). The URL must be rebuilt exactly.
- **Store:**
  - type and signature checks, the size cap, redirects refused, timeout;
  - shared identical downloads, the 10-minute failure back-off;
  - cache eviction at the cap, and file names never containing track IDs.
- **Commands:** `soda.cover` needs owner auth, needs no lease and never changes
  playback; unknown or invalid tracks give `cover_unavailable`.
- **Bridge:**
  - keys change between app runs; unknown keys are ignored;
  - the request cap holds;
  - nothing is sent while in the background;
  - page state never contains IDs, URLs or base64 data.
- **Page:**
  - the fallback paints immediately, the real cover replaces it, and the
    cross-fade runs;
  - only visible covers are requested;
  - the offline contract still passes.
- **Real check (laptop):** download covers for 20 cached songs and record the time
  and size of each. On the iPad: open the quick menu and window mode, then
  measure first-view and second-view times.

## 7. Risks

| Risk | Handling |
|---|---|
| 汽水 changes the image address format | The descriptor is validated; on any mismatch the generated cover stays (never an error) |
| Image CDN slow or blocked from the network | 8 s timeout, cached forever after the first success, generated fallback |
| Large data over a slow route | One small size (~360 px, ≈20–40 KB); only visible covers; iPad cache |
| A 500-song list fills caches | Caps (laptop 100 MB, iPad 50 MB) with oldest-used deletion |
| Privacy | Opaque keys only on the page; cache file names hashed; no account data in any request |
| WebView memory | 64 decoded covers at most; textures for off-screen panes released |

## 8. Later (not in this plan)

- `track.colors` (`background_color`, `cover_gradient_effect_color`) for song-matched
  room tint: belongs to the Lakeside style work.
- Prefetching the next song's cover.
- Covers in the music sheet's list rows (currently text-only).

## 9. Owner decisions needed

1. Approve C0–C3 (allow-listed cover downloads on the laptop, new cache folders on
   the laptop and iPad).
2. C4 (Windows media thumbnail): now, or later?
3. The cache size caps: laptop 100 MB, iPad 50 MB.
