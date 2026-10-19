# Listen Room web prototype: quality plan (before shipping)

Status: **done. You approved all prototype results on 2026-10-19 (v10.2).** The approved page is saved
as [design/listen-room-v10.2.html](design/listen-room-v10.2.html). Next is the shipping plan, which starts
only with your go. Covers only the test web page, not the iPad app.

**Order of work:**
1. **This plan:** raise the quality of the test web page (the "Moonlight Room" prototype) until
   it passes the **ship line** in section 5.
2. **Then:** start [IMPLEMENTATION_IPAD_LISTEN_ROOM.md](IMPLEMENTATION_IPAD_LISTEN_ROOM.md), the
   shipping plan that builds the approved page into the iPad app.

Nothing in this plan touches app code, the audio engine, the laptop or the gateway.

- **Live prototype:** https://claude.ai/artifact/LLuwfYaC2qSgurG2ESkWUm. Every new version is
  published to this same link.
- **Baseline:** v6, saved in the repo as [design/listen-room-v6.html](design/listen-room-v6.html).
- **How you test:** open the link on your iPad, in Safari or the Claude app. Both use WebKit, the
  same engine the app's WKWebView will use, so speed and look there are a good preview of the app.

---

## 1. Where v6 stands

**Good already**
- Real 3D room with:
  - floor reflections, glow and reflective materials;
  - detailed textures (leather, walnut, stone, wool, plaster, brushed metal, ceramics);
  - furniture, speakers, plant, art, lamps and candle.
- Glass header, side panel (Layout / Motion / Place), popovers and player bar, matching your
  reference picture.
- All connection states can be shown from the prototype panel.

**Known issues (from the v4–v6 screenshots)**

| # | Issue | Where |
|---|---|---|
| K1 | The moon is hidden behind the ceiling edge; only its path on the lake shows | room |
| K2 | The chair seen from behind is a flat dark shape | room |
| K3 | The lake, mist and stars are completely still | room |
| K4 | Ceiling downlights read as small dashes at the top of the landscape view | room |
| K5 | Landscape shows a wide dark ceiling band at the top; portrait shows a large skylight | camera |
| K6 | Faint repeated glare from the glass panes | room |
| K7 | Final rug / walnut / ceiling tuning was never screenshotted | textures |
| K8 | No speed data from a real iPad at all | speed |
| K9 | Textures are generated on the main thread (about 1–2 s of work on an iPad) | speed |
| K10 | About 250 separate meshes, full-resolution reflection and glow, 60 fps even when idle | speed |
| K11 | Phone width and Stage Manager window sizes not checked since v3 | layout |
| K12 | Tapping the floor moves the sound only while Place is open; this isn't explained anywhere | interaction |
| K13 | VoiceOver labels, text contrast and reduced-motion behaviour not checked | access |
| K14 | No handling if WebGL is lost (for example after the app sits in the background) | robustness |

---

## 2. Workstreams

### A. Speed (do this first: everything else is judged on a smooth room)

1. **FPS meter.** Add a small frame-time / fps / draw-call readout, switched on from the prototype
   panel. Add a **"Copy report"** button that copies the device model, screen size, fps (idle and
   dragging) and load time, so you can paste the numbers to me.
2. **Render on demand.**
   - Up to 60 fps while touching, dragging, with Orbit on, or while the camera moves.
   - 30 fps while idle and listening.
   - Stop rendering when the page is hidden.
3. **Shadows.** Draw them once, and again only when something that casts them moves
   (`shadowMap.autoUpdate = false`).
4. **Merge static geometry.** Window frames, rails, sill light, ceiling and furniture become a few
   meshes. Target: under 60 draw calls per pass (main view and reflection).
5. **Half-resolution reflection and glow.** Also skip the reflection every other frame while idle.
6. **Textures off the main thread.** Generate them in a Web Worker as raw pixels and upload them as
   `DataTexture`, so the room never freezes while they build. This fixes K9.
7. **Adaptive resolution.** If frames take longer than 20 ms, step the pixel ratio down
   (1.75 → 1.25 → 1.0).
8. **"Light room" mode.** No reflection and no glow, chosen automatically if the iPad still can't keep
   up, and selectable in the prototype panel for comparison.

### B. Room visuals

1. **K1 moon.** Place the moon where it is visible through the upper window. Add a soft halo, and
   match its path on the water.
2. **K2 chair.** Shape the back shell, add a stitched seam and piping on the back cushion, and a
   soft rim light so the silhouette reads.
3. **K3 life outside.**
   - A slow shimmer on the lake: a small animated shader on a water plane, with no particles.
   - Mist drifting very slowly.
   - A few stars gently twinkling.
   - All of it off under reduced motion.
4. **K4 / K5 camera and ceiling.**
   - Re-frame landscape and portrait so the window and room fill the view.
   - Downlights become proper round recessed fittings.
   - Size the skylight for portrait.
5. **K6 glass.** Tune the glass reflection so it shows the interior lamps faintly, without the
   repeated glare.
6. **Grounding.** Soft shading where floor meets wall and furniture (painted ambient-occlusion
   decals), and a thin warm edge glow under the sideboard.
7. **K7 textures.** Review every material at close and normal distance, and fix anything that reads
   as noise.
8. **Entrance.** A slow, short camera move into the room when it first appears. Off under reduced
   motion.

### C. Interaction

1. **K12 placing.**
   - Dragging the sound always works.
   - Tapping the floor moves the sound whenever Place is open; a one-line hint says so the first time.
   - Distance rings and a value tag appear while you drag.
2. **Feel.**
   - The camera eases to a stop after a drag.
   - Double-tap resets the view; pinch zoom stays within limits.
   - Direction snaps gently to 0°, ±30°, ±90° and 180° when you release close to them.
3. **Popovers.** Short open and close animations, closing on outside tap, and they never cover the
   sound you're placing.
4. **Feedback.** Every control acknowledges the tap at once. "Applied on the laptop" toasts stay
   short and never stack.

### D. Screen design and layout

1. **One type scale and spacing scale** for header, side panel, popovers and player bar, with one
   icon weight. Check every piece against your reference picture.
2. **Sign-in screen** in the v6 style (it still uses the v4 card).
3. **K11 layouts:**
   - iPad landscape and portrait;
   - Stage Manager window sizes (half and third);
   - iPad mini;
   - phone width.
   Nothing clips or overlaps.
4. **Loading.** Show a calm first frame (room silhouette) while textures sharpen, never a blank screen.

### E. States

Review every state for wording, icon and layout, plus three missing ones:
- sign-in;
- connecting;
- Live off;
- listening;
- laptop took control;
- Safari listening on another device;
- phone call;
- connection lost;
- 2.0 mode;
- Orbit;
- placing.

New: **wrong password**, **laptop offline at sign-in**, and **no music app open on the laptop**.

**Design only here.** In the prototype these states are faked from the prototype panel; this
section decides how each one looks and what it says. The app already detects every one of them in
its real listening code (`LaptopListenController`, `resolveRemoteEntry`). The shipping plan connects
them to this design:
- the room states arrive through the bridge's `notice` and state fields;
- the two sign-in states are rebuilt natively, because sign-in stays a native Flutter screen and the
  password never enters the web page.

### F. Accessibility and robustness

1. **K13:**
   - every control has a spoken label;
   - text meets WCAG AA contrast on the glass;
   - reduced motion turns off the entrance move, ripples, shimmer and twinkle;
   - the side panel and player bar work with a keyboard.
2. **K14:** handle WebGL context loss by rebuilding the scene, keeping all state. If WebGL is
   unavailable, show the controls over a still image of the room.
3. **No console errors** in any state.

---

## 3. Versions

Each version is published to the same link; you test it on your iPad and reply with feedback (and
the "Copy report" numbers).

| Version | Contents | You check |
|---|---|---|
| v7 | A: speed pass, FPS meter, "Copy report", light-room mode | Paste the report: fps idle / dragging, load time |
| v8 | B: room visuals (moon, chair, lake life, camera, ceiling, glass, grounding, textures, entrance) | Look and feel of the room |
| v9 | C + D: interaction, design consistency, v6 sign-in, layouts, loading | Controls, sizes, rotation |
| v10 | E + F: all states (including the three new ones), accessibility, robustness | Every state, VoiceOver basics |
| Gate review | Go through the ship line together | Sign-off |

Extra rounds are added as needed. Each round lists what changed and what wasn't checked.

---

## 4. How I check each version before you see it

- Script parses, and there are no console errors in the browser pane.
- Headless screenshots at 1180×820 (iPad landscape) and 820×1180 (portrait). Phone width uses a
  real narrow window, not an iframe; headless screenshots are blind to WebGL inside iframes.
- Every state switched once through the prototype panel.
- What I cannot check here, and say each time:
  - real iPad GPU speed and heat;
  - the exact look on the iPad's GPU (screenshots use software rendering);
  - VoiceOver.

---

## 5. The ship line (when the web prototype is "good enough to ship")

All of these must be true. Then the shipping plan starts.

| Area | Pass when |
|---|---|
| **Your sign-off** | You approve the room and the controls on your own iPad, in landscape and portrait |
| **Known issues** | K1–K14 fixed, or each one you choose to leave is written down as accepted |
| **Speed on your iPad** | ≥ 50 fps while dragging or orbiting; idle holds its 30 fps cap; first room frame < 1 s; no freeze while textures load. (Heat and battery are tested only in the real app, with real music playing: see the shipping plan's tests) |
| **States** | Every state in E reviewed and approved |
| **Layouts** | iPad landscape, portrait, Stage Manager half, iPad mini and phone width: nothing clipped or overlapping |
| **Accessibility** | All controls labelled; text contrast AA; reduced motion honoured |
| **Robustness** | No console errors in any state; WebGL loss recovers |
| **Ready to split** | Room maths (coordinates, distance scale, drag inverse) and formatters are pure functions, in one place, ready to become `room-math.js` in the shipping plan |

Coordinates stay exactly as documented in the shipping plan (section 3): the engine frame, with
the room's log distance scale for display only.

---

## 6. Rules while iterating

- **Prototype only.** No app, engine, laptop or gateway changes. Your installed IPA and laptop w13
  are untouched.
- Every version keeps every earlier feature working. Earlier versions stay in the artifact's history
  and on disk.
- Ideas that need app or laptop features go into a "later" list, not into the prototype: real
  cover art, song progress, room themes. The prototype must not show things the app can't deliver.

---

## 7. Changelog

| Version | Date | Summary |
|---|---|---|
| v1 | 2026-10-19 | First Listen to laptop prototype (two columns, 2.5D room) |
| v2 | 2026-10-19 | 3D oak listening room, hi-fi console, VU meters |
| v3 | 2026-10-19 | Soft-gray neumorphism |
| v4 | 2026-10-19 | Moonlight Room from your reference picture |
| v5 | 2026-10-19 | Floor reflections, glow, reflective materials, new models |
| v6 | 2026-10-19 | Detailed textures, finishing details, film grade |
| Sign-off | 2026-10-19 | You approved all prototype results (v10.2): the room, the controls and all 15 states. Measured on your iPad before sign-off: the v9.3 speed test (125 fps at full quality) and the start breakdown. Not measured separately on the iPad and included in your approval: v10.2 drag response, VoiceOver, and the first-frame rule (room build plus first draw was about 0.2 s; the rest was the page download, which the app doesn't have). |
| v10.2 | 2026-10-19 | Drag response, from your feedback "a little slow and intermittent when I drag" (current).<br>• the finger position is applied once per frame and the camera follows it closely (about 20 ms) at the screen's own rate: fingers report about 60 times a second while the screen draws up to 120, so before, the room moved only on every other frame (tested: 0 of 112 frames without movement with finger updates every 33 ms)<br>• soft limits: past the edge of turning or tilting, the room gives a little with growing resistance and springs back on release, instead of stopping dead (tilting has only 20° of room, so this was easy to hit)<br>• dragging the sound fixed: it used a level plane at the sound's height, which sits above eye level by default, so the sound could jump to 10 m; it now drags by its floor point and glides steadily at any height<br>• less page work during drags: the canvas position is measured once per touch, the level line's size only when it changes, and hidden labels are not rewritten every frame<br>• the speed report shows touch response (finger move to frame) and how often the finger reports<br>• room math unchanged: 2,386 checks still pass |
| v10.1 | 2026-10-19 | Ship line "Ready to split". Prototype only, no integration.<br>• all room math now lives in one block, marked ROOM MATH BEGIN / END, of pure functions (no DOM, three.js or app state): the distance scale, engine → room position, the drag inverse, the distance-slider mapping, direction snapping, the 2.0 speaker placement, and the on-screen and spoken text formats<br>• the block documents both coordinate frames (X, Y, Z, azimuth, elevation, distance, listener orientation) and the conversion between them; it matches section 3 of the shipping plan exactly<br>• tested on its own, pulled out of the page and run in Node: 2,386 checks pass (axes, exact round trips, slider ends, snapping edges, text); the old v10 math gives identical results on the same checks<br>• the page looks and behaves the same: sound positions, slider values, tap-to-place results, speaker positions and spoken values are identical to v10; no console errors |
| v10 | 2026-10-19 | Workstreams E and F. Design only: every state is faked from the prototype panel.<br>• E, new states: **wrong password** (red outline on the fields, a plain message, the account kept, the password field ready to retype), **laptop offline at sign-in** (an amber note "Can't reach your laptop right now…", the button becomes Try again), **no music app on the laptop** ("Nothing playing", an empty cover, transport and Listen here disabled, a note to open a player)<br>• E, review: all 15 states screenshotted and checked (listening, not listening, connecting, Live off, laptop took control, Safari elsewhere, phone call, connection lost, no music app, 2.0, Orbit, placing, sign-in, wrong password, laptop offline); disabled round buttons now look disabled<br>• F / K13: spoken labels for the room, the Place and Orbit sliders (with spoken values such as "35° right", "3.2 metres") and every panel; text contrast raised to about 5:1 on the glass (AA, by calculation; denser glass, brighter secondary text, clearer floor labels); Reduce Motion also stops the glide after a swipe, the direction animation and the candle flicker (the opening move, ripples, shimmer and twinkle were already off); keyboard: a panel opened from the keyboard focuses its first control, Escape closes it and returns focus<br>• F / K14: if the GPU drops the 3D view, the calm veil says "Restoring the room…" and the room rebuilds when it returns, keeping the sound position, layout, camera and settings (tested with a forced loss); without WebGL the controls sit over a still picture of the room<br>• no console errors through every prototype state, a forced 3D loss and recovery, and the keyboard checks (PC) |
| v9.4 | 2026-10-19 | Smooth opening. Your iPad on v9.3 (cool): speed test 125 fps in all three setups (full quality at 1.75x and 1.25x, Light room), so the GPU has headroom; first frame 1003 ms (page and three.js 781 ms, room build 74 ms, first draw 148 ms). The slow part was only the opening move (typical 33 ms frames, worst second 23 fps, one resolution step-down), which started while the GPU was still preparing the newly textured materials.<br>• after the textures arrive, one off-screen render of everything (hidden parts included) prepares every drawing setup; the move starts a few full-rate frames later<br>• no auto-resolution changes during the opening move or in the 1.5 s after the textures arrive<br>• the report labels opening-move frames separately |
| v9.3 | 2026-10-19 | Fixed speed test. Your iPad on v9.2: frosted and solid glass equal (117 vs 118 fps, Orbit with a panel open), so the blur is not the cost; turning the room ran at a typical 33 ms per frame, which stepped the resolution down twice and switched to the Light room. Moving speed has fallen a little in every version since v8.2 (120 → 91 fps), which may be the iPad warming up over the session.<br>• prototype button "Run speed test (8 s)": turns the room the same way every run in three setups (full quality at full and lower sharpness, then the Light room) and adds the typical fps of each to the report, so runs compare cleanly<br>• the faded start screen now leaves the page instead of staying as an invisible layer over the room |
| v9.2 | 2026-10-19 | Speed diagnosis. Your iPad on v9.1: page and three.js 1539 ms (network), room build 81 ms, first draw 195 ms; one freeze (156 ms, while the camera waits for the textures); moving 90.7 fps but worst second 29 fps and one resolution step-down, so a sustained slowdown remains.<br>• prototype switch "Glass blur: Frosted / Solid (test)" to measure what the frosted panels cost on iPad<br>• the speed report splits moving fps by situation (Point / Orbit / 2.0, dragging, which panel is open, top view, solid glass) and says what was on screen when the resolution stepped down<br>• fixed: choosing an option in Layout or Motion closed the panel at once, so the Orbit speed slider could never be reached |
| v9.1 | 2026-10-19 | Freeze fix from your v9 report. Your iPad on v9: first frame 655 ms (page and three.js 431 ms, room build 72 ms, first draw 152 ms), textures 0.75 s, moving 98 fps but worst second 23 fps and two resolution step-downs.<br>• cause: switching Layout hid one light and showed two, so the light count changed and every material rebuilt its shader (a long freeze on iPad)<br>• one blue light that is never hidden: it follows the sound, or sits between the two speakers in 2.0<br>• every shader, hidden parts included, is built once while the camera waits at the opening pose (25–40 ms on the PC); shader count now stays flat through Layout, Motion, Place and top view<br>• auto resolution uses the typical (median) frame, so a one-off freeze no longer lowers the resolution<br>• the speed report lists freezes over 100 ms and what each one followed<br>• fixed a v9 console error when a panel closed during its fade |
| v9 | 2026-10-19 | Workstreams C and D:<br>• start: a calm veil with the wordmark until the first frame, then a fade into the room; the opening move holds until the detailed surfaces are in, so their shader rebuild no longer stutters the move (your v8.4 report: worst second 31 fps); the chair builds 3× faster and the boulders share one merged sphere; the speed report now splits the start into page load, room build and first draw<br>• K12 placing: a first-time tip "tap the floor to move the sound there"; the Place panel says so too; rings and the value tag while dragging were already there<br>• feel: the camera glides to a stop after a swipe; double-tap the room to reset the view; the direction settles onto 0°, ±30°, ±90° or 180° when released within 4°<br>• panels: popovers, the More menu and the prototype panel fade and rise in and out; a tap on the room closes Layout, Motion and the room card; while placing, the panel moves aside if it would cover the sound<br>• feedback: every button, choice and panel item reacts on press; toasts never stack<br>• design: one type scale (12/13/15/17/22/32), one spacing scale, one radius scale and one icon weight across header, side panel, popovers, player bar and sign-in<br>• sign-in in the room's style: header line, icon fields, the room showing through<br>• K11 layouts checked at iPad 11" and 12.9" landscape, iPad 11" and mini portrait, iPad mini landscape, a Stage Manager half window and phone width: nothing clips; the room name shortens before anything is cut; the page can no longer be pinch-zoomed or double-tap-zoomed (the likely cause of the clipped header in your v8 screenshot)<br><br>On the PC: first frame drawn 512 ms (page 54 ms, room built 257 ms, first draw 256 ms), no console errors. |
| v8.4 | 2026-10-19 | Rest of workstream B:<br>• K2 chair: two curved walnut shells (back and head) joined by aluminium spines, padded leather cushions with piping that roll over the shell edges, a padded seat, and a faint cool rim on leather and walnut so the silhouette reads against the window (no extra shaders)<br>• opening move: the camera glides in from higher, further back and to the left over 2.4 s when the room first appears; a touch takes over at once; off under reduced motion<br>• grounding: soft shading along the base of the wall and its pillar (furniture shadows and the warm glow under the sideboard were already there)<br>• K5 portrait: narrower vertical view, camera a step back, skylight 20% smaller<br>• K7 texture review: floor, deck, walnut and ceiling read clean up close; the only fix needed was the chair rim, toned down<br><br>On the PC: first frame 320 ms, textures 0.9 s, idle 30 fps, no console errors. Workstream B is done.<br>Your iPad: first frame 1262 ms, textures 1.9 s, moving 104 fps but worst second 31 fps (resolution stepped down once); fixed in v9. |
| v8.3 | 2026-10-19 | K4: ceiling downlights are round recessed fittings (aluminium trim, dark baffle, lamp) with a soft warm wash on the ceiling.<br><br>Still open in workstream B: chair (K2), grounding, texture review (K7), entrance. |
| v8.2 | 2026-10-19 | Interior, first part:<br>• K6: window glass reflects faintly and softly, with no repeated glare on every pane<br>• K5: camera tilt limited to 8°–28° and zoom-in to 0.82×, so the dark ceiling band and skylight never fill the view<br><br>Still open in workstream B: chair (K2), downlights (K4), grounding, texture review (K7), entrance. |
| v8.1 | 2026-10-19 | Fix round from your iPad screenshot of v8:<br>• shoreline lights gathered into a few small towns, with short, broken reflections instead of a row of long straight streaks<br>• the 3D water reflects only what stands above the far shore (sky, mountains, the town lights), so painted reflections no longer appear twice<br>• ripples fade before they can turn into jagged steps; reflections slightly softened<br>• the grainy mist band removed; a smooth haze over the far water instead<br>• the moon's glitter breaks into sparkles up close and is less blown out<br>• grey blocks near the ceiling and sky removed: glow now uses half-float buffers where the GPU allows it (shown in the speed report)<br><br>On the PC: first frame 273 ms, idle 30 fps, no console errors. |
| v8 | 2026-10-19 | Workstream B, outside only. Fixes K1 (moon) and K3 (life outside):<br>• real 3D lake with moving ripples that reflects the sky, mountains and moon, with a moonlight glitter path, blending into the painted far lake<br>• round moon sprite with glow, rising over the lowest valley in view<br>• gently twinkling stars and shimmering shoreline lights<br>• faint drifting mist low over the water<br>• stone deck with path lights<br>• smooth natural boulders on the deck and in the water<br><br>Motion pauses under reduced motion. On the PC: first frame 410 ms, about 50 draw calls per pass. |
| v7 | 2026-10-19 | Workstream A, speed:<br>• FPS meter and copyable speed report<br>• renders on demand (full rate while moving, 30 fps idle, none when hidden)<br>• static shadows<br>• 314 → 92 meshes merged<br>• reflection at about half resolution (15 fps while idle) and glow at quarter resolution<br>• textures built in a Web Worker<br>• adaptive resolution<br>• Auto / Full / Light room quality<br><br>On the PC: first frame 500 ms, textures 1.9 s, idle 30 fps, about 35–45 draw calls per pass.<br>Your iPad (11-inch, 120 Hz, measured on v8.2): first frame 948 ms, textures 1.2 s in the worker, idle 29.3 fps, moving 120 fps (worst second 120), full 1.75× resolution never stepped down, glow in half-float. Speed line passed. On v8.3: first frame 1117 ms (just over the 1 s line, to fix in v9), moving 110.6 fps. Heat moved to the shipping plan's real-app test. |
