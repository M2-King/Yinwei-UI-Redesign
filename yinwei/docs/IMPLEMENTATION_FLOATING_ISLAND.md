# Floating Island (Dual-Mode) — P2.6

Single-window morph between **Full** desktop player and a top-center **Island** pill.
Audio stays on `EngineController` / `spatial_core`; the island only changes HWND chrome + compact UI.

## Mode machine

```
full ──enterIsland──► islandCollapsed ──expand──► islandExpanded
  ▲                         │                         │
  └──────── enterFull ──────┴────── enterFull ────────┘
                            ▲
                            └── collapse ─────────────┘
```

Fixed sizes (no per-frame HWND animation):

| Mode | Size (logical) |
|------|----------------|
| Full | restored prior bounds (default 1280×720) |
| Island collapsed | 420×64 |
| Island expanded | 420×120 |

## Window chrome

Dart: `WindowModeController` → `WindowManagerChrome` (`window_manager` + `screen_retriever`).

Native channel `yinwei/window_chrome`:

- `setToolWindow(bool)` — toggles `WS_EX_TOOLWINDOW` / `WS_EX_APPWINDOW` so Island skips Alt+Tab / taskbar more cleanly.

Island flags (via window_manager):

- frameless, always-on-top, skip taskbar, transparent background
- **Click-through**: never left permanently on. Collapsed mode runs a ~40 ms global cursor probe; ignore mouse only when the pointer is outside the pill hitbox. Expanded / Full always accept clicks.

## Triggers

| Action | Trigger |
|--------|---------|
| Enter Island | Title-bar landscape icon **or** status-bar「灵动岛」 |
| Expand Island | Tap pill / chevron-down |
| Collapse Island | Chevron-up |
| Back to Full | `open_in_full` on collapsed or expanded |

## Transfer / pose (preview-grade)

**Code landed ≠ listen-accepted.** Island Dual-Mode chrome is in-tree; Island Transfer is **not** product-ready. Do not treat SMTC title, a LIVE label, or a captured-frame counter as proof of wet Spatial. Pass = wet sound can be heard, toggled, and A/B compared in **Full**. Island may later project that proven Full-window capability only.

### Yinwei file session
Island may show **Yinwei Spatial** (file engine pose / envelopment) while an opened file plays. That is **not** loopback Transfer. Do not reuse an HRTF LIVE flag for file Spatial.

### System media (SMTC)
When Yinwei is idle, the island uses a **persistent PowerShell SMTC daemon** (WinRT loaded once; JSON every ~400 ms). First-frame READY is emitted immediately so the UI is not blocked 5–15 s on cold WinRT. SMTC is metadata only.

### Live HRTF (Full is the listen path)
WASAPI **process** loopback → `HrtfStreamer` → cpal (`yinwei_live_*`) is wired from Full. Overlay on the same default device is **preview-grade** until the user splits devices (music app → speakers, Yinwei wet → headphones). **Never mute the source app session** (`ISimpleAudioVolume` / volume 0): 汽水 / Spotify auto-pause. Speaker-**device** mute is OK if the room must be quiet.

| What is true | What to show |
|--------------|--------------|
| Yinwei opened file + Spatial | Yinwei Spatial pose — not HRTF LIVE |
| SMTC playing, Transfer off | Title/artist + prompt to use **Full** Transfer |
| Full Transfer running + healthy capture | Loopback HRTF (still preview until device split is heard) |
| Island Transfer control | Convenience only — not a product-complete Transfer surface |

Listen split (human): music app → speakers via Windows Volume Mixer; Yinwei wet output → headphones. Do not mute the music app session.

## Non-goals (still)

- Second Flutter engine / multi-monitor islands
- System notification hub / Windhawk injection
- Tray-only / autostart (later packaging)

## Known pitfalls avoided

1. Do not leave `WS_EX_TRANSPARENT` permanently on the whole HWND.
2. Do not animate window size every frame (buzz / flicker risk, same class as HRIR thrash).
3. Do not put window policy inside `spatial_core.dll`.
4. Restoring frame after `setAsFrameless` requires `setTitleBarStyle(TitleBarStyle.normal)` (API is one-way).
5. Do not enable click-through before a global cursor probe — Flutter never receives taps otherwise.

## Manual acceptance

- [ ] Full ↔ Island ≥20 times mid-playback without stop/glitch
- [ ] Collapsed: clicks outside pill pass through to desktop apps
- [ ] Hover/click pill expands; Expand button returns Full
- [ ] 100% / 150% / 200% DPI: pill stays top-center
- [ ] Island skips taskbar; Full restores
- [ ] Mock backend can enter Island without DLL
- [ ] Play 汽水音乐 / Spotify: island title matches SMTC; subtitle does **not** claim HRTF LIVE
- [ ] Island file Spatial uses **Yinwei Spatial** wording — never the loopback HRTF LIVE flag
- [ ] Listen-accept Transfer **in Full** with device split (music → speakers, wet → headphones). Overlay-on-one-device is preview only. Island Transfer is not product-ready.
- [ ] Yinwei open+play file: island prefers Yinwei file session over SMTC metadata
- [ ] First Island open no longer freezes 5–15s (SMTC READY immediate)
