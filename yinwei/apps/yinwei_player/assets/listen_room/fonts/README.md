# Fonts — bundled for the offline Listen Room page

Downloaded 2026-10-19 from Google Fonts (icon subset refreshed the same day to add arrow_back) (fonts.googleapis.com / fonts.gstatic.com), unmodified.
Chinese text uses the system font (PingFang SC on iPad); no CJK font is bundled.

| File | Font | Licence | What it covers |
|---|---|---|---|
| `outfit.woff2` | Outfit, variable weight 200–600, Latin subset | SIL Open Font License 1.1 | Latin text, digits, °, ·, –, …, − |
| `material-symbols-rounded.woff2` | Material Symbols Rounded, a subset of the 23 icons the page uses (weight 300, fill 0–1, optical size 24, grade 0) | Apache License 2.0 | add, airplay, arrow_back, call, devices, expand_more, graphic_eq, headphones, info, logout, more_horiz, music_off, pause, play_arrow, radar, skip_next, skip_previous, speaker, stop_circle, touch_app, view_in_ar, volume_up, wifi_off |

A new icon in the page needs a new subset: request the same family and axes with the extra name
added to `icon_names`, then update the pin below.

SHA-256 pins (checked by `test/listen_room/offline_contract_test.mjs`):

| SHA-256 | File | Bytes |
|---|---|---|
| `92684e4acde79ef07758cd09380b7e01e9824d8b061eddeda046f78c166d7b12` `outfit.woff2` | | 32228 |
| `632e1fafe3f382903618483c5937e0ca2b700024adf9e01c4f91b61ca4821a61` `material-symbols-rounded.woff2` | | 5928 |
