"use strict";
// Yinwei Listen Room: header, side panel, popovers, player bar, menu and toasts.
//
// The page is a view, not a second state store (IMPLEMENTATION_IPAD_LISTEN_ROOM.md §2, §4):
// - the app sends state with YinweiListen.apply(state); render() draws it;
// - every action here becomes an intent sent to the app with send({ t: ... });
//   the app carries it out on the laptop and sends the new state back;
// - the page keeps only transient things: which panel is open, the view, a drag
//   in progress, and (briefly) a value you just set (ListenBridge.hold).
// Sign-in is native in the app; the password never enters this page.
// Loaded after room-math.js and bridge.js, before room.js (the scripts share one page scope).

const $ = (id) => document.getElementById(id);
const DEG = Math.PI / 180;
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
const t0Script = performance.now(); // the page's scripts are loaded and running
const { clamp, wrap, fmtAz, fmtEl, fmtDist, distToSlider, sliderToDist, EAR, R10 } = RoomMath;
const ms = (name, fill) => `<span class="ms${fill ? " fill" : ""}" aria-hidden="true">${name}</span>`;
const esc = (t) => String(t).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const cap = (t) => (t ? t[0].toUpperCase() + t.slice(1) : t); // "your laptop" at the start of a sentence

// ---------------------------------------------------------------- state
// Page state: the app's fields (ListenBridge.FIELDS) plus page-only ones
// (screen, view, panel). Until the app's first message, a quiet empty room.
const S = {
  laptop: "", connection: "connected", source: "", live: false, playing: false, listening: "off",
  control: "mine", notice: "none", mode: "point", motion: "fixed", orbitHz: 0.4,
  az: 0, el: 0, dist: 2, track: null, volume: 1, level: 0, stats: { received: 0, bufferMs: 0, underruns: 0 }, opens: null,
  pending: false, progress: null, pos: 0, dur: 0, seekable: false,
  quality: "high", stream: null, opus: false, // sound quality chosen / sent now / Opus possible
  canClose: true, updates: false, appBuild: null, music: false, queue: null, // the room as the whole app: no way back; updates checked here. queue: the list the current song plays from

  screen: "room", view: "3d", panel: null,
  speakers: [], selectedSpeakerIndex: 0, arrayRevision: 0, maxSpeakers: 8, speakerControl: false, matrixLinked: false, matrixSpread: 1,
};
// A gesture preview, never a second authoritative array. Every commit retains
// the revision at gesture start, even if a laptop edit arrives in the meantime.
let speakerDraft = null;
const activeSpeaker = () => speakerDraft || S.speakers[S.selectedSpeakerIndex];
const canEditSpeakers = () => S.mode === "stereo2" && S.speakerControl && !S.pending &&
  !(speakerDraft && speakerDraft.committed) && !lost() && S.control === "mine";
function beginSpeaker(index) {
  const s = S.speakers[index];
  if (!s || !canEditSpeakers()) return false;
  speakerDraft = { ...s, arrayRevision: S.arrayRevision };
  return true;
}
function speakerIntent(t, extra = {}) {
  send({ t, arrayRevision: S.arrayRevision, ...extra });
}
function commitSpeaker() {
  if (!speakerDraft || speakerDraft.committed) return;
  speakerDraft.committed = performance.now();
  const { index, az, el, dist, arrayRevision } = speakerDraft;
  if (speakerDraft.axis) send({ t: "matrixAdjust", index, axis: speakerDraft.axis,
    value: speakerDraft[speakerDraft.axis], arrayRevision });
  else send({ t: "speakerPlace", index, az, el, dist, arrayRevision });
  renderSpeakerPlace(); // lock the next gesture until this revision is acknowledged
}
function speakerPose(index) {
  const s = S.speakers[index];
  if (!speakerDraft || !s) return s;
  if (index === speakerDraft.index) return speakerDraft;
  if (!S.matrixLinked) return s;
  const base = S.speakers[speakerDraft.index];
  return { ...s, az: wrap(s.az + wrap(speakerDraft.az - base.az)),
    el: clamp(s.el + speakerDraft.el - base.el, -90, 90),
    dist: speakerDraft.axis && speakerDraft.axis !== "dist" ? s.dist : speakerDraft.dist };
}
const held = {}; // values you just set, kept until the app confirms them
const setLocal = (fields, ok) => { const now = performance.now(); for (const k in fields) { S[k] = fields[k]; ListenBridge.hold(held, k, fields[k], now, ok && ok[k]); } };

// Intents, page → app. In the app the "YinweiNative" channel carries them to
// Dart; in a plain browser they become a "yinwei-intent" event (dev host, tests).
function send(intent) {
  if (intent.t === "media") intent.tapMs = performance.now();
  const msg = JSON.stringify(intent);
  try { if (window.YinweiNative && typeof window.YinweiNative.postMessage === "function") { window.YinweiNative.postMessage(msg); return; } } catch (e) { /* fall through */ }
  window.dispatchEvent(new CustomEvent("yinwei-intent", { detail: JSON.parse(msg) }));
}
const musicSheet = ListenMusic.create({ send, state: () => S, toast: (text) => toast(text) });
function apply(next) {
  if (typeof next === "string") { try { next = JSON.parse(next); } catch (e) { return; } }
  const now = performance.now(), heldBefore = Object.keys(held).join();
  const wasPending = S.pending;
  // What you tapped stays while its command is on its way to the laptop (a
  // Start or a cold music app can take many seconds); once answered, the
  // laptop has HOLD_MS to show it, as before.
  if (S.pending || (next && next.pending === true)) {
    for (const k in held) held[k].until = Math.max(held[k].until, now + ListenBridge.HOLD_MS);
  }
  const changed = ListenBridge.merge(S, next, held, now, {
    placing: typeof dragging !== "undefined" && dragging === "source",
    orbiting: S.mode === "point" && S.motion === "orbit",
  });
  if (speakerDraft && (S.mode !== "stereo2" || S.control !== "mine" || lost() ||
      S.arrayRevision !== speakerDraft.arrayRevision ||
      (speakerDraft.committed && ((wasPending && !S.pending) ||
        now - speakerDraft.committed > ListenBridge.HOLD_MS)))) speakerDraft = null;
  if (changed.includes("pos")) posAt = now; // the song clock restarts from each report
  if (changed.length || Object.keys(held).join() !== heldBefore) render();
}

const isCjk = (t) => /[㐀-鿿]/.test(t);
let toastT = 0;
// One toast at a time: a new one replaces the text and restarts the timer, never stacks.
function toast(t, hold = 1500) { const el = $("toast"); el.textContent = t; el.classList.add("show"); clearTimeout(toastT); toastT = setTimeout(() => el.classList.remove("show"), hold); }
const lost = () => S.notice === "lost" || S.connection === "reconnecting";
const otherHasControl = () => S.control !== "mine" || S.notice === "taken";

// ---------------------------------------------------------------- cover art
// No artwork comes from the laptop yet: a calm moon-over-water cover, tinted per song.
// Which generated scene a song's cover uses (the laptop sends no artwork).
const artVariant = (title) => { let h = 7; for (const ch of String(title || "")) h = (h * 33 + ch.codePointAt(0)) >>> 0; return h % 3; };
// Variant 1: crescent over soft clouds. Variant 2: mountains, a lake and shore lights.
function paintArtScene(c, w, h, hue, variant) {
  let seed = hue * 7 + variant * 131 + 1;
  const rnd = () => ((seed = (seed * 9301 + 49297) % 233280) / 233280);
  const stars = (n, maxY) => { for (let i = 0; i < n; i++) { const s = w * (0.004 + rnd() * 0.006); c.fillStyle = `rgba(255,255,255,${(0.2 + rnd() * 0.55).toFixed(2)})`; c.fillRect(rnd() * w, rnd() * h * maxY, s, s); } };
  if (variant === 1) {
    const sky = c.createLinearGradient(0, 0, 0, h);
    sky.addColorStop(0, `hsl(${hue} 50% 8%)`); sky.addColorStop(0.7, `hsl(${hue + 8} 42% 26%)`); sky.addColorStop(1, `hsl(${hue + 14} 38% 36%)`);
    c.fillStyle = sky; c.fillRect(0, 0, w, h);
    stars(30, 0.6);
    const mx = w * 0.56, my = h * 0.36, mr = w * 0.15;
    const glow = c.createRadialGradient(mx, my, 0, mx, my, mr * 3.2);
    glow.addColorStop(0, "rgba(255,240,222,0.32)"); glow.addColorStop(1, "rgba(255,240,222,0)");
    c.fillStyle = glow; c.fillRect(0, 0, w, h);
    const m = document.createElement("canvas"); m.width = m.height = Math.ceil(mr * 2 + 4);
    const mc = m.getContext("2d"), o = m.width / 2;
    mc.fillStyle = "#fff6e8"; mc.beginPath(); mc.arc(o, o, mr, 0, Math.PI * 2); mc.fill();
    mc.globalCompositeOperation = "destination-out"; mc.beginPath(); mc.arc(o + mr * 0.45, o - mr * 0.25, mr * 0.9, 0, Math.PI * 2); mc.fill();
    c.drawImage(m, mx - o, my - o);
    for (let i = 0; i < 9; i++) {
      const cx = rnd() * w, cy = h * (0.7 + rnd() * 0.28), rx = w * (0.2 + rnd() * 0.25), ry = h * (0.07 + rnd() * 0.07);
      const g = c.createRadialGradient(cx, cy, 0, cx, cy, rx);
      g.addColorStop(0, `rgba(222,230,250,${(0.3 + rnd() * 0.25).toFixed(2)})`); g.addColorStop(1, "rgba(222,230,250,0)");
      c.fillStyle = g; c.beginPath(); c.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2); c.fill();
    }
    return true;
  }
  if (variant === 2) {
    const sky = c.createLinearGradient(0, 0, 0, h * 0.6);
    sky.addColorStop(0, `hsl(${hue} 52% 9%)`); sky.addColorStop(0.75, `hsl(${hue + 12} 40% 30%)`); sky.addColorStop(1, "hsl(328 32% 44%)");
    c.fillStyle = sky; c.fillRect(0, 0, w, h * 0.6);
    stars(40, 0.45);
    const ridge = (top, amp, color) => {
      c.fillStyle = color; c.beginPath(); c.moveTo(0, h * 0.6);
      for (let x = 0; x <= w + 1; x += w / 12) c.lineTo(x, h * (top - amp * (0.4 + rnd() * 0.6)));
      c.lineTo(w, h * 0.6); c.closePath(); c.fill();
    };
    ridge(0.5, 0.14, `hsl(${hue} 30% 20%)`); ridge(0.58, 0.1, `hsl(${hue} 35% 11%)`);
    const lake = c.createLinearGradient(0, h * 0.6, 0, h);
    lake.addColorStop(0, `hsl(${hue + 6} 36% 26%)`); lake.addColorStop(1, `hsl(${hue} 50% 6%)`);
    c.fillStyle = lake; c.fillRect(0, h * 0.6, w, h * 0.4);
    for (let i = 0; i < 14; i++) {
      const x = rnd() * w, s = w * 0.008;
      c.fillStyle = "rgba(255,206,150,0.95)"; c.fillRect(x, h * 0.595, s, s);
      c.fillStyle = "rgba(255,206,150,0.25)"; c.fillRect(x, h * 0.61, s, h * (0.04 + rnd() * 0.08));
    }
    return true;
  }
  return false;
}
function paintArt(hue, empty, cv = $("art"), variant = 0) {
  const c = cv.getContext("2d"), w = cv.width, h = cv.height;
  if (empty) { // nothing playing: a quiet, empty cover
    const g = c.createLinearGradient(0, 0, 0, h); g.addColorStop(0, "#151b2b"); g.addColorStop(1, "#0b0f19");
    c.fillStyle = g; c.fillRect(0, 0, w, h);
    c.strokeStyle = "rgba(200,215,255,0.18)"; c.lineWidth = 3; c.beginPath(); c.arc(w / 2, h / 2, w * 0.16, 0, Math.PI * 2); c.stroke();
    return;
  }
  if (variant && paintArtScene(c, w, h, hue, variant)) return;
  const sky = c.createLinearGradient(0, 0, 0, h * 0.62);
  sky.addColorStop(0, `hsl(${hue} 45% 10%)`); sky.addColorStop(1, `hsl(${hue + 12} 42% 42%)`);
  c.fillStyle = sky; c.fillRect(0, 0, w, h * 0.62);
  const sea = c.createLinearGradient(0, h * 0.62, 0, h);
  sea.addColorStop(0, `hsl(${hue} 40% 34%)`); sea.addColorStop(1, `hsl(${hue} 50% 7%)`);
  c.fillStyle = sea; c.fillRect(0, h * 0.62, w, h * 0.38);
  const mx = w * 0.5, my = h * 0.48, mr = w * 0.055;
  const glow = c.createRadialGradient(mx, my, 0, mx, my, mr * 7);
  glow.addColorStop(0, "rgba(255,240,222,0.55)"); glow.addColorStop(1, "rgba(255,240,222,0)");
  c.fillStyle = glow; c.fillRect(0, 0, w, h);
  c.fillStyle = "#fff6e8"; c.beginPath(); c.arc(mx, my, mr, 0, Math.PI * 2); c.fill();
  let seed = hue;
  const rnd = () => ((seed = (seed * 9301 + 49297) % 233280) / 233280);
  for (let i = 0; i < 16; i++) {
    const y = h * 0.635 + i * h * 0.022, ww = mr * (2 - i * 0.09) * (0.6 + rnd() * 0.7);
    c.fillStyle = `rgba(255,240,222,${(0.55 - i * 0.032).toFixed(3)})`;
    c.fillRect(mx - ww / 2, y, ww, h * 0.007);
  }
}

// ---------------------------------------------------------------- DOM render
// State can arrive 10 times a second, so render() only rewrites what changed:
// a panel or slider is never rebuilt under your finger.
const drawn = {};
const once = (key, value, draw) => { const sig = JSON.stringify(value); if (drawn[key] !== sig) { drawn[key] = sig; draw(); } };
const setText = (el, t) => { if (el.textContent !== t) el.textContent = t; };
let volDragging = false;
function render() {
  musicSheet.update();
  const noApp = S.notice === "noapp", isLost = lost(), locked = otherHasControl() || isLost;
  // No music app open, but the laptop opens S.opens on Start.
  const opens = !noApp && !S.live && S.opens ? S.opens : null;
  const t = noApp ? { title: "Nothing playing", artist: `No music app open on ${S.laptop}` }
    : S.track && S.track.title ? S.track : { title: "Nothing playing", artist: opens ? `${opens} opens on ${S.laptop} when you start` : "" };
  $("app").classList.toggle("locked", locked);
  setText($("title"), t.title); $("title").classList.toggle("cjk", isCjk(t.title));
  // Live songs come with a title only: the music app takes the artist line.
  const artist = t.artist || (S.track && S.track.title && !noApp ? S.source : "");
  setText($("artist"), artist); $("artist").classList.toggle("cjk", isCjk(artist));
  once("art", [noApp, t.title], () => paintArt(ListenBridge.hueOf(t.title), noApp || !(S.track && S.track.title), $("art"), artVariant(t.title)));
  const sounding = S.live && S.playing && !isLost && !noApp;
  $("live-dot").classList.toggle("off", !sounding);
  setText($("live-text"), noApp ? "Live off · waiting for a music app" : S.live ? `${S.playing ? "Live" : "Paused"} · ${S.source} on ${S.laptop}` : opens ? "Live off · no music app open yet" : `Live off · ${S.source} on ${S.laptop}`);
  ["prev", "play", "next"].forEach((id) => { $(id).disabled = noApp; });
  setText($("play-icon"), S.playing ? "pause" : "play_arrow");
  $("play").classList.toggle("waiting", !!held.playing); // a ring until the laptop confirms
  drawScrub();
  $("play").setAttribute("aria-label", S.playing ? "Pause" : "Play");

  const listening = S.listening === "on";
  $("listen-btn").classList.toggle("on", listening);
  $("listen-btn").setAttribute("aria-label", listening ? "Listening on this iPad" : "Listen on this iPad");
  $("view-btn").classList.toggle("on", S.view === "top");
  $("take").hidden = !otherHasControl() || isLost;

  const notices = {
    busy: ["devices", false, "<b>Safari is listening on another device.</b> Stop it there and this iPad takes over by itself."],
    interrupted: ["call", true, "<b>Paused for a phone call.</b> Listening resumes when the call ends."],
    lost: ["wifi_off", false, `<b>Lost ${esc(S.laptop)}.</b> Reconnecting… Check that it is awake and online.`],
    noapp: ["music_off", false, `<b>No music app is open on ${esc(S.laptop)}.</b> Open ${esc(S.source || "your music app")} or another player there, then tap Listen here.`],
    taken: ["info", true, "<b>Someone at the laptop changed the sound.</b> Tap Take control to adjust it here."],
  };
  const key = isLost ? "lost" : notices[S.notice] ? S.notice : otherHasControl() ? "taken" : null;
  once("notice", [key, S.laptop, S.source], () => {
    const n = $("notice");
    if (!key) { n.hidden = true; return; }
    const [ic, info, text] = notices[key];
    n.className = `notice glass${info ? " info" : ""}`;
    n.innerHTML = `${ms(ic)}<div>${text}</div>`;
    n.hidden = false;
  });

  const right = $("right");
  const progress = S.progress && !isLost ? S.progress : null;
  once("connect", [progress, S.laptop, S.source, S.opens], () => drawConnect(progress));
  once("right", [S.listening, S.live, isLost, noApp, S.laptop, S.source, opens, progress], () => {
    if (listening) {
      right.innerHTML = `<div class="vol">${ms("volume_up")}<input id="vol" type="range" min="0" max="1" step="0.01" value="${S.volume}" aria-label="Volume on this iPad"></div><button class="round" id="airplay" type="button" aria-label="Choose where this iPad plays">${ms("airplay")}</button>`;
      const vol = $("vol");
      const paint = () => vol.style.setProperty("--p", `${vol.value * 100}%`);
      let sentAt = 0;
      paint();
      vol.addEventListener("pointerdown", () => { volDragging = true; });
      vol.addEventListener("input", () => {
        setLocal({ volume: Number(vol.value) }); paint();
        const now = performance.now(); if (now - sentAt > 100) { sentAt = now; send({ t: "volume", v: S.volume }); } // at most 10 a second while sliding
      });
      vol.addEventListener("change", () => { volDragging = false; send({ t: "volume", v: S.volume }); });
      // In the app, iPadOS's own AirPlay picker sits over this button (P3), so this click is only for the browser.
      $("airplay").onclick = () => send({ t: "airplay" });
      // The native view supplies its own icon and accessibility button. Keep
      // this element only for layout; otherwise both icons/labels overlap.
      if (window.YinweiNative && typeof window.YinweiNative.postMessage === "function") {
        $("airplay").innerHTML = "";
        $("airplay").setAttribute("aria-hidden", "true");
        $("airplay").tabIndex = -1;
      }
    } else if (S.listening === "connecting") {
      right.innerHTML = `<div class="listen-cta"><button class="cta" type="button" disabled><span class="spin"></span>${S.live ? "Connecting" : "Starting on laptop"}</button><small>${S.live ? "Opening the audio stream…" : opens ? `Opening ${esc(opens)} on ${esc(S.laptop)}…` : `Playing ${esc(S.source)} on ${esc(S.laptop)}…`}</small></div>`;
    } else {
      right.innerHTML = `<div class="listen-cta"><button class="cta" id="go" type="button" ${isLost || noApp || progress ? "disabled" : ""}>${ms("headphones")}${S.live || noApp ? "Listen here" : "Start on laptop and listen"}</button><small>${noApp ? `Waiting for a music app on ${esc(S.laptop)}` : isLost ? `Waiting for ${esc(S.laptop)}` : S.live ? `${esc(cap(S.laptop))} is playing with spatial sound` : opens ? `Opens ${esc(opens)} on ${esc(S.laptop)}` : `${esc(S.source)} is paused on the laptop`}</small></div>`;
      $("go").onclick = startListening;
    }
    reportRects();
  });
  const vol = $("vol");
  if (vol && !volDragging && document.activeElement !== vol && Math.abs(vol.value - S.volume) > 0.005) { vol.value = S.volume; vol.style.setProperty("--p", `${S.volume * 100}%`); }

  setText($("sv-layout"), S.mode === "point" ? "Point" : "2.0");
  setText($("sv-motion"), S.mode === "stereo2" ? "Off in 2.0" : S.motion === "orbit" ? `Orbit ${S.orbitHz.toFixed(2)}` : "Fixed");
  setText($("sv-place"), S.mode === "point" ? fmtDist(S.dist) : "Speakers");
  $("m-stop-listen").disabled = !listening;
  $("m-close").hidden = !S.canClose;
  $("m-updates").hidden = !S.updates;
  for (const q of ["high", "max", "lossless"]) {
    const b = $(`q-${q}`);
    b.setAttribute("aria-pressed", String(S.quality === q));
    b.disabled = q !== "lossless" && !S.opus;
  }
  setText($("sq-note"), !S.opus ? "Uncompressed only on this connection"
    : { high: "Opus 320 kbps · steadiest on Wi-Fi and hotspot", max: "Opus 510 kbps · the most detail Opus carries",
      lossless: "Uncompressed · needs a strong network" }[S.quality]);
  setText($("d-stream"), { high: "Opus 320 kbps", max: "Opus 510 kbps", lossless: "48 kHz · lossless" }[S.stream] || "–");
  setText($("d-recv"), Number(S.stats.received || 0).toLocaleString());
  setText($("d-buffer"), S.stats.bufferMs ? `${Math.round(S.stats.bufferMs)} ms` : "–");
  syncBrowse();
  if (S.panel) renderPop();
}

// ---------------------------------------------------------------- popovers
// Panels fade and rise in, and fade out before they hide.
const isOpen = (el) => !!el && !el.hidden && el.classList.contains("open");
function showEl(el) { clearTimeout(el._hide); el.hidden = false; void el.offsetWidth; el.classList.add("open"); }
function hideEl(el) { el.classList.remove("open"); clearTimeout(el._hide); el._hide = setTimeout(() => { if (!el.classList.contains("open")) el.hidden = true; }, 200); }
let placeHinted = false;
const firstPlace = () => { if (placeHinted) return false; placeHinted = true; try { if (localStorage.getItem("yinwei.placeHint")) return false; localStorage.setItem("yinwei.placeHint", "1"); } catch (e) { /* storage off: once per visit */ } return true; };
function closePop() {
  S.panel = null; popSide = "right"; drawn.pop = null; hideEl($("pop"));
  ["si-layout", "si-motion", "si-place", "room-btn"].forEach((id) => $(id).setAttribute("aria-expanded", "false"));
}
function openPop(kind, viaKeyboard = false) {
  if (S.panel === kind) { closePop(); return; }
  act(`open ${kind}`);
  closeMenus();
  S.panel = kind; drawn.pop = null;
  ["layout", "motion", "place"].forEach((k) => $(`si-${k}`).setAttribute("aria-expanded", String(k === kind)));
  $("room-btn").setAttribute("aria-expanded", String(kind === "room"));
  renderPop();
  const pop = $("pop");
  pop.setAttribute("aria-label", { layout: "Layout", motion: "Motion", place: "Place the sound", room: "Moonlight Room" }[kind]);
  showEl(pop);
  placePop();
  if (viaKeyboard) { const first = pop.querySelector("button:not(:disabled), input:not(:disabled)"); if (first) first.focus(); }
  if (kind === "place" && S.mode === "point" && firstPlace()) toast("Tip: tap the floor to move the sound there", 3200);
}
// ---------------------------------------------------------------- music browsing: album · compact · window
// One stable state at a time: "album" (the player bar and its cover), "compact" (a clear floating song
// picker: tap or hold the cover) and "window" (each window pane shows one song,
// room.js). The song data is S.queue (the list the current song plays from). Covers are generated
// (paintArt): the laptop sends no artwork. A mode change never touches playback; only choosing a song
// plays one. Visuals follow the state with CSS transitions (picker) and eased values (room.js), so an
// interrupted transition simply turns round from where it is.
// Tuning: the --pk-* tokens in ui.css, PK / PK_TEXT here, WIN in room.js.
const PK = {
  holdMs: 450,                  // a deliberate long press on the cover
  y: [0, 88, 150, 202],         // the focused row, then rows 1 / 2 / 3 away (px, Cover Flow)
  s: [1, 0.78, 0.68, 0.6],      // their scale
  o: [1, 0.86, 0.5, 0],         // and opacity (3 away: gone)
  tilt: 16,                     // degrees of tilt per row away (2 at most)
  dragStep: 46, wheelStep: 60,  // px per song when dragging / scrolling the picker
  winWheel: 80,                 // wheel px per song along the windows
  ms: reduced ? 0 : 460,        // mode transition length (must match --pk-t)
};
// The picker is one 3D group (#pk-group, preserve-3d inside #pk-list's perspective): the song cards
// at different depths, the focused one forward, the others smaller and further back along the
// curve, and a large dimmed artwork of the focused song well behind them. Looking around the
// close-up room (dragging the room, room.js BROWSE_LOOK) turns the whole group with your view, about
// its centre, so the layers show real perspective and parallax; the cards keep their places in it
// and never turn on their own. Group space: CSS px, x right, y down, z towards you; yaw = rotateY
// (+ turns the right side away, as when you drag right), pitch = rotateX (+ tips the top away).
// Double-tap the room (or close and reopen) for the front view. Tuning: PK3, --pk3-* in ui.css.
const PK3 = {
  focusZ: 70, depth: [0, 70, 130, 180],   // px forward for the focused card / back for cards 1-3 away
  yaw: 70, pitch: 15,                     // degrees at the end of the room's look range (BROWSE_LOOK)
  follow: 6,                              // 1/s: how promptly the group turns after the view (frame-rate independent)
  bgZ: -320,                              // px: the artwork behind the cards
};
let pkYaw = 0, pkPitch = 0, pkBgSong = null, pkBgTimer = 0;
const PK_TEXT = {
  compact: "快捷歌单", window: "窗景歌单", expand: "在窗上展开", collapse: "收起",
  open: "Show the playlist", close: "Close the playlist", collapseLabel: "Collapse to the song picker", expandLabel: "Expand onto the windows",
  empty: "Only the song playing now is visible. Play from a list in Yinwei to see the whole playlist here.",
};
const PK_SVG = {
  close: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 7l10 10M17 7L7 17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>',
  chevron: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 10l5 5 5-5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
};
let browseMode = "album", modeAt = -1e9, pkFocus = 0, pkList = null, pkSync = "", pkWait = -1, pkHide = 0;
let pkArt = null, pkDrag = null, pkSuppress = false, pkWheel = 0, pkK = 1;
// The picker is drawn large: scaled so its rows and button fill most of the room's height (below the
// mode pill), but never wider than about half the screen. Tuning: PK_FIT.
const PK_FIT = { fillH: 0.88, maxW: 0.5, min: 1, max: 2.2, top: 68, bottom: 16, button: 214 + 44 };
function pkFit() {
  const pk = $("pk"), app = $("app"), cs = getComputedStyle(pk);
  const row = parseFloat(cs.getPropertyValue("--pk-row")) || 96, width = parseFloat(cs.getPropertyValue("--pk-width")) || 276;
  const above = PK.y[2] + (row * PK.s[2]) / 2, span = above + PK_FIT.button; // two rows above the focus ... the button below
  const H = app.clientHeight, W = app.clientWidth, room = H - PK_FIT.top - PK_FIT.bottom;
  pkK = clamp(Math.min((PK_FIT.fillH * room) / span, (PK_FIT.maxW * W) / width), PK_FIT.min, PK_FIT.max);
  pk.style.transition = "none"; // the size applies at once (only the rows animate), so covers start exactly on the album cover
  pk.style.setProperty("--pk-k", pkK.toFixed(3));
  pk.style.top = `${(PK_FIT.top + (room - span * pkK) / 2 + above * pkK).toFixed(1)}px`; // the focused row's centre line
  void pk.offsetWidth; pk.style.transition = "";
}
let winOffset = 0, winAnchor = 3, winWheelAcc = 0;
const pkRows = new Map();
const pkSongs = () => (S.queue && S.queue.songs.length ? S.queue.songs : null);
const pkSig = () => { const q = S.queue; return q && q.songs.length ? JSON.stringify([q.title, q.songs]) : ""; };
// Where the album cover sits while the player shows: the picker grows from it and folds back into it.
function measureArt() {
  const r = $("art").getBoundingClientRect();
  if (r.width) pkArt = { x: r.left + r.width / 2, y: r.top + r.height / 2 - ($("app").classList.contains("browse") ? 24 : 0), w: r.width };
}
// The transform that lays a row's cover exactly over the album cover (rows scale around their cover).
function pkCoverTransform() {
  const list = $("pk-list").getBoundingClientRect(), cs = getComputedStyle($("pk"));
  const pad = parseFloat(cs.getPropertyValue("--pk-pad")) || 10, cover = parseFloat(cs.getPropertyValue("--pk-cover")) || 76;
  if (!pkArt || !list.width) return "translateY(0px) scale(0.6)";
  const k = pkK, cx = list.left + (pad + cover / 2) * k, cy = list.top + list.height / 2; // the picker is scaled by k
  return `translate(${((pkArt.x - cx) / k).toFixed(1)}px, ${((pkArt.y - cy) / k).toFixed(1)}px) scale(${(pkArt.w / (cover * k)).toFixed(3)})`;
}
// Cover Flow: d rows from the focused one.
function pkFlow(d) {
  const a = Math.min(Math.abs(d), 3), sg = Math.sign(d), z = d === 0 ? PK3.focusZ : -PK3.depth[a] - Math.max(0, Math.abs(d) - 3) * 40;
  return `translate3d(0px, ${sg * (PK.y[a] + Math.max(0, Math.abs(d) - 3) * 40)}px, ${z}px) rotateX(${-sg * Math.min(a, 2) * PK.tilt}deg) scale(${PK.s[a]})`;
}
// Every frame (room.js): turn the group with the look-around (its target, eased like the camera).
function pkOrient(dt) {
  if (browseMode !== "compact" && !pkYaw && !pkPitch) return false;
  let ty = 0, tp = 0;
  if (browseMode === "compact" && BROWSE_LOOK.on) {
    const pose = browsePose("compact"), lim = lookLimits(); // each side of the look range reaches the full turn
    const side = (v, p, lo, hi) => (v >= p ? (v - p) / Math.max(1e-3, hi - p) : (v - p) / Math.max(1e-3, p - lo));
    ty = clamp(-side(cam.tYaw, pose.yaw, lim.y[0], lim.y[1]), -1.1, 1.1) * PK3.yaw;
    tp = clamp(-side(cam.tLift, pose.lift, lim.l[0], lim.l[1]), -1.1, 1.1) * PK3.pitch;
  }
  const f = reduced ? 1 : 1 - Math.exp(-dt * PK3.follow);
  pkYaw += (ty - pkYaw) * f; pkPitch += (tp - pkPitch) * f;
  const moving = Math.abs(ty - pkYaw) + Math.abs(tp - pkPitch) > 0.01;
  if (!moving) { pkYaw = ty; pkPitch = tp; } // lands exactly: the front view is exact
  $("pk-group").style.transform = `rotateX(${pkPitch.toFixed(3)}deg) rotateY(${pkYaw.toFixed(3)}deg)`;
  return moving;
}
// The large artwork behind the cards: the focused song, crossfading between two canvases.
function pkBackground() {
  const songs = pkSongs();
  if (!songs || pkBgSong === pkFocus) return;
  pkBgSong = pkFocus;
  const a = $("pk-bg-a"), b = $("pk-bg-b"), next = a.classList.contains("on") ? b : a, song = songs[pkFocus];
  paintArt(ListenBridge.hueOf(song.title), false, next, artVariant(song.title));
  next.classList.add("on"); (next === a ? b : a).classList.remove("on");
}
function pkRow(i, song) {
  const el = document.createElement("button");
  el.type = "button"; el.className = "pk-row needs-control"; el.dataset.i = i; el.setAttribute("role", "option");
  el.setAttribute("aria-label", song.artist ? `${song.title}, ${song.artist}` : song.title);
  const cv = document.createElement("canvas"); cv.className = "pk-cover"; cv.width = cv.height = 152; cv.setAttribute("aria-hidden", "true");
  paintArt(ListenBridge.hueOf(song.title), false, cv, artVariant(song.title));
  const meta = document.createElement("span"); meta.className = "pk-meta";
  const b = document.createElement("b"); b.textContent = song.title; if (isCjk(song.title)) b.className = "cjk";
  const sm = document.createElement("small"); sm.textContent = song.artist; if (isCjk(song.artist)) sm.className = "cjk";
  meta.append(b, sm);
  const eq = document.createElement("span"); eq.className = "pk-eq"; eq.setAttribute("aria-hidden", "true"); eq.innerHTML = "<i></i><i></i><i></i><i></i>";
  el.append(cv, meta, eq);
  el.addEventListener("click", () => { if (pkSuppress) { pkSuppress = false; return; } pkSelect(i); });
  return { i, el };
}
// Keep rows for the songs around the focused one; new rows slide in from one step further out.
function pkEnsureRows() {
  const songs = pkSongs(), list = $("pk-list");
  if (!songs) return;
  for (let i = Math.max(0, pkFocus - 4); i <= Math.min(songs.length - 1, pkFocus + 4); i++) {
    if (pkRows.has(i)) continue;
    const row = pkRow(i, songs[i]), d = i - pkFocus;
    row.el.classList.add("snap"); row.el.style.opacity = "0"; row.el.style.transform = pkFlow(d + Math.sign(d));
    $("pk-group").append(row.el); void row.el.offsetWidth; row.el.classList.remove("snap");
    pkRows.set(i, row);
  }
  for (const [i, row] of pkRows) if (Math.abs(i - pkFocus) > 5) { row.el.remove(); pkRows.delete(i); }
}
function pkBuildIfNeeded() {
  const sig = pkSig();
  if (sig === pkList) return;
  pkList = sig; pkSync = ""; pkBgSong = null;
  for (const row of pkRows.values()) row.el.remove();
  pkRows.clear();
  const q = S.queue;
  pkFocus = q && q.playing >= 0 ? q.playing : 0; pkWait = -1;
  $("pk").classList.toggle("empty", !sig); $("pk-expand").disabled = !sig;
}
// phase "flow": the Cover Flow; "fromCover": start with the focused song on the album cover and unfold;
// "toCover": fold the neighbours in and return the focused song to the cover.
function pkLayout(phase = "flow", stagger = false) {
  if (!pkSongs()) return;
  pkEnsureRows();
  const pk = $("pk"), playing = S.queue.playing;
  if (phase === "fromCover") {
    const cover = pkCoverTransform();
    for (const [i, row] of pkRows) {
      row.el.classList.add("snap");
      row.el.style.transform = i === pkFocus ? cover : "translateY(0px) scale(0.92)";
      row.el.style.opacity = i === pkFocus ? "1" : "0";
    }
    pk.classList.add("at-cover"); void pk.offsetWidth;
    for (const row of pkRows.values()) row.el.classList.remove("snap");
    pk.classList.remove("at-cover");
  }
  pk.classList.toggle("at-cover", phase === "toCover");
  const cover = phase === "toCover" ? pkCoverTransform() : "";
  for (const [i, row] of pkRows) {
    const d = i - pkFocus, a = Math.min(Math.abs(d), 3), el = row.el;
    el.style.transitionDelay = !stagger && phase === "flow" ? "0ms"
      : phase === "toCover" ? (d === 0 ? "70ms" : "0ms") : `${d === 0 ? 0 : 110 + (a - 1) * 45}ms`;
    if (phase === "toCover") { el.style.transform = d === 0 ? cover : "translateY(0px) scale(0.92)"; el.style.opacity = d === 0 ? "1" : "0"; }
    else { el.style.transform = pkFlow(d); el.style.opacity = Math.abs(d) > 3 ? "0" : String(PK.o[a]); }
    el.classList.toggle("focus", d === 0);
    el.classList.toggle("playing", i === playing);
    el.classList.toggle("wait", i === pkWait && i !== playing);
    el.classList.toggle("far", Math.abs(d) > 2 || phase === "toCover");
    el.setAttribute("aria-selected", d === 0 ? "true" : "false");
    el.tabIndex = d === 0 ? 0 : -1;
    el.disabled = !pkCanPlay();
    el.setAttribute("aria-current", String(i === playing));
    el.setAttribute("aria-hidden", String(Math.abs(d) > 2));
  }
  clearTimeout(pkBgTimer); pkBgTimer = setTimeout(pkBackground, pkBgSong === null ? 0 : 140);
}
function pkBrowse(step) {
  const songs = pkSongs();
  if (!songs || browseMode !== "compact") return;
  const next = clamp(pkFocus + step, 0, songs.length - 1);
  if (next === pkFocus) return;
  pkFocus = next; pkLayout("flow");
  const row = pkRows.get(next);
  if (row && $("pk").contains(document.activeElement)) row.el.focus({ preventScroll: true });
}
// Choosing a song plays it (browsing alone never does); the picker stays open.
function pkSelect(i) {
  const songs = pkSongs();
  if (!songs || i < 0 || i >= songs.length || browseMode !== "compact" || !pkCanPlay()) return;
  pkFocus = i;
  if (i !== S.queue.playing) { pkWait = i; act(`queue play ${i}`); send({ t: "queuePlay", i }); }
  pkLayout("flow");
}
function winBrowse(step) { const songs = pkSongs(); if (songs) { stopFire(); winOffset = clamp(winOffset + step, 0, songs.length - 1); syncWindowList(); camMoving = true; } }
function winWheel(dy) {
  winWheelAcc += dy;
  while (winWheelAcc >= PK.winWheel) { winBrowse(1); winWheelAcc -= PK.winWheel; }
  while (winWheelAcc <= -PK.winWheel) { winBrowse(-1); winWheelAcc += PK.winWheel; }
}
// A pane tapped in window mode plays its song; window mode stays open.
function winTap(i) {
  const songs = pkSongs();
  if (!songs || i < 0 || i >= songs.length || browseMode !== "window" || !pkCanPlay()) return;
  if (i !== S.queue.playing) { pkWait = i; act(`window play ${i}`); send({ t: "queuePlay", i }); }
}
const pkCanPlay = () => !otherHasControl() && !lost() && !S.pending && S.connection === "connected";
// Window songs also have a keyboard/screen-reader representation; the room draws their faces.
function syncWindowList() {
  const list = $("win-list"), songs = pkSongs() || [];
  const key = JSON.stringify([songs, S.queue && S.queue.playing, winOffset, pkCanPlay()]);
  if (list.dataset.key === key) return;
  const focused = list.contains(document.activeElement);
  list.dataset.key = key; list.replaceChildren();
  songs.forEach((song, i) => {
    const row = document.createElement("button"); row.type = "button";
    row.textContent = song.artist ? `${song.title}, ${song.artist}` : song.title;
    row.setAttribute("role", "option"); row.setAttribute("aria-selected", String(i === winOffset));
    row.setAttribute("aria-current", String(i === S.queue.playing));
    row.tabIndex = i === winOffset ? 0 : -1; row.disabled = !pkCanPlay();
    row.onclick = () => winTap(i); list.append(row);
  });
  if (focused && list.children[winOffset]) list.children[winOffset].focus({ preventScroll: true });
}
function pkRenderBar() {
  const win = browseMode === "window", btn = $("pk-bar-btn");
  $("pk-bar-title").textContent = win ? PK_TEXT.window : PK_TEXT.compact;
  btn.innerHTML = win ? `<span>${PK_TEXT.collapse}</span>${PK_SVG.chevron}` : PK_SVG.close;
  btn.setAttribute("aria-label", win ? PK_TEXT.collapseLabel : PK_TEXT.close);
}
// The only way modes change. Allowed: album <-> compact <-> window (album and window go through compact).
function setBrowseMode(next) {
  if (!["album", "compact", "window"].includes(next)) return;
  const prev = browseMode;
  if (prev === "album" && next === "window") next = "compact";
  if (prev === "window" && next === "album") next = "compact";
  if (next === prev || (next === "window" && !pkSongs())) return;
  const pk = $("pk"), app = $("app"), now = performance.now(), mid = now - modeAt < PK.ms + 60;
  if (prev === "album" && !mid) measureArt();
  closePop(); closeMenus();
  clearTimeout(pkHide);
  if (prev === "window") stopFire();
  pkDrag = null; pkWheel = winWheelAcc = 0;
  browseMode = next; modeAt = now;
  act(`browse ${next}`);
  app.classList.toggle("browse", next !== "album");          // the album page steps aside
  app.classList.toggle("browse-window", next === "window");
  pk.hidden = false; $("pk-bar").hidden = false;
  pk.classList.toggle("away", next === "window");
  pk.toggleAttribute("inert", next !== "compact");
  $("win-list").hidden = next !== "window";
  $("player").inert = false;
  pkRenderBar();
  $("art").setAttribute("aria-expanded", String(next !== "album"));
  browseCamera(next); // the camera frames the picker / windows and holds still (room.js)
  $("view-btn").disabled = next !== "album";
  if (next === "compact") {
    pkFit();
    pkBuildIfNeeded();
    if (prev === "album") {
      if (S.queue && S.queue.playing >= 0) pkFocus = S.queue.playing; // the cover is the playing song
      pkLayout(mid ? "flow" : "fromCover", true);
    } else { pkFocus = clamp(winOffset, 0, pkSongs() ? pkSongs().length - 1 : 0); pkLayout("flow", true); } // back from the windows, where you browsed to
    const row = pkRows.get(pkFocus);
    (row ? row.el : $("pk-bar-btn")).focus({ preventScroll: true });
  } else if (next === "window") {
    // The pane in front of you anchors the song you browsed to; near either end of the list it shifts
    // so the songs still fill every pane (no blank glass while there are songs to show).
    const P = three && three.panes ? three.panes.length : 8, n = pkSongs().length;
    winAnchor = n >= P ? clamp(frontPane(), P - n + pkFocus, pkFocus) : pkFocus + Math.floor((P - n) / 2);
    const seen = panesInView("window"); // ...but always on a pane you can see
    if (seen) winAnchor = clamp(winAnchor, seen[0], seen[1]);
    winOffset = pkFocus;
    syncWindowList();
    const cover = pkRows.get(pkFocus) && pkRows.get(pkFocus).el.querySelector(".pk-cover"), cr = cover && cover.getBoundingClientRect();
    if (cr && cr.width) fireToWindows(cr.left + cr.width / 2, cr.top + cr.height / 2, cr.width); // the songs fly out of the cover (room.js)
    // The song you browsed to anchors there; the playing one stays lit wherever it is.
    $("pk-bar-btn").focus({ preventScroll: true });
  } else {
    pkLayout("toCover", true);
    pkHide = setTimeout(() => { if (browseMode === "album") { pk.hidden = true; $("pk-bar").hidden = true; } }, PK.ms + 180);
    $("art").focus({ preventScroll: true }); // back to the cover it opened from
  }
  $("player").inert = next !== "album";
}
// Called by render(): follow a new list, the playing song and pause, without moving the browse position.
function syncBrowse() {
  if (browseMode === "album") { if (!pkArt && performance.now() - modeAt > PK.ms + 200) measureArt(); return; }
  if (pkSig() !== pkList) { pkBuildIfNeeded(); if (browseMode === "compact") pkLayout("flow"); }
  if (browseMode === "window") {
    if (!pkSongs()) { setBrowseMode("compact"); return; }
    winOffset = clamp(winOffset, 0, pkSongs().length - 1); syncWindowList();
  }
  const q = S.queue, key = `${q ? q.playing : -1}|${S.playing ? 1 : 0}|${pkCanPlay()}`;
  if (key === pkSync) return;
  pkSync = key;
  if (q && pkWait === q.playing) pkWait = -1;
  $("pk").classList.toggle("paused", !S.playing);
  if (browseMode === "compact") pkLayout("flow");
}
function initBrowse() {
  const pk = $("pk"), list = $("pk-list"), art = $("art"), card = $("now-card");
  $("pk-expand").querySelector("span").textContent = PK_TEXT.expand;
  $("pk-expand").setAttribute("aria-label", PK_TEXT.expandLabel);
  pk.querySelector(".pk-empty").textContent = PK_TEXT.empty;
  art.setAttribute("aria-label", PK_TEXT.open);
  $("pk-bar-btn").onclick = () => setBrowseMode(browseMode === "window" ? "compact" : "album");
  $("pk-expand").onclick = () => setBrowseMode("window");
  // The cover opens the quick menu: a tap, or a hold (~450 ms, with a subtle press). A drag off it does not.
  let hold = null, hx = 0, hy = 0;
  const cancel = () => { if (hold) { clearTimeout(hold); hold = null; } card.classList.remove("pressing"); };
  art.addEventListener("pointerup", (e) => { if (hold && e.type === "pointerup") { cancel(); setBrowseMode("compact"); } }); // a tap (before the hold fires)
  art.addEventListener("keydown", (e) => { if ((e.key === "Enter" || e.key === " ") && browseMode === "album") { e.preventDefault(); setBrowseMode("compact"); } });
  art.addEventListener("pointerdown", (e) => {
    if (browseMode !== "album" || (e.button != null && e.button > 0)) return;
    if (e.isPrimary === false) return;
    cancel(); hx = e.clientX; hy = e.clientY; card.classList.add("pressing");
    try { art.setPointerCapture(e.pointerId); } catch (err) { /* synthetic pointer */ }
    hold = setTimeout(() => { hold = null; card.classList.remove("pressing"); setBrowseMode("compact"); }, PK.holdMs);
  });
  art.addEventListener("pointermove", (e) => { if (hold && Math.hypot(e.clientX - hx, e.clientY - hy) > 10) cancel(); });
  ["pointerup", "pointercancel", "pointerleave", "lostpointercapture"].forEach((t) => art.addEventListener(t, cancel));
  art.addEventListener("contextmenu", (e) => e.preventDefault());
  addEventListener("blur", cancel);
  document.addEventListener("visibilitychange", cancel);
  // The picker: drag or scroll to browse (never selects), tap to choose. Gestures stay off the room camera.
  list.addEventListener("pointerdown", (e) => { pkSuppress = false; pkDrag = { y: e.clientY, last: e.clientY, moved: false }; });
  list.addEventListener("pointermove", (e) => {
    if (!pkDrag) return;
    if (!pkDrag.moved && Math.abs(e.clientY - pkDrag.y) > 8) { pkDrag.moved = true; try { list.setPointerCapture(e.pointerId); } catch (err) { /* released */ } }
    if (pkDrag.moved && Math.abs(e.clientY - pkDrag.last) >= PK.dragStep * pkK) { pkBrowse(e.clientY < pkDrag.last ? 1 : -1); pkDrag.last = e.clientY; }
  });
  const end = () => { if (pkDrag && pkDrag.moved) pkSuppress = true; pkDrag = null; };
  list.addEventListener("pointerup", end); list.addEventListener("pointercancel", end);
  list.addEventListener("wheel", (e) => {
    e.preventDefault(); pkWheel += e.deltaY;
    while (pkWheel >= PK.wheelStep) { pkBrowse(1); pkWheel -= PK.wheelStep; }
    while (pkWheel <= -PK.wheelStep) { pkBrowse(-1); pkWheel += PK.wheelStep; }
  }, { passive: false });
  document.addEventListener("keydown", (e) => {
    if (browseMode === "album" || (e.target.closest && e.target.closest("input, textarea")) || isOpen($("pop")) || isOpen($("menu"))) return;
    if (browseMode === "compact") {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); pkBrowse(e.key === "ArrowDown" ? 1 : -1); }
      else if (e.key === "Escape") setBrowseMode("album");
    } else {
      if (e.key === "ArrowRight" || e.key === "ArrowLeft") { e.preventDefault(); winBrowse(e.key === "ArrowRight" ? 1 : -1); }
      else if (e.key === "Enter" && e.target === document.body) winTap(winOffset);
      else if (e.key === "Escape") setBrowseMode("compact");
    }
  });
  addEventListener("resize", () => {
    if (browseMode === "album") { measureArt(); return; }
    browseCamera(browseMode); // rotated: the framing for the new shape
    pkFit();
    if (browseMode === "compact") pkLayout("flow");
  });
  requestAnimationFrame(measureArt);
}
function placePop() {
  const pop = $("pop");
  if (pop.hidden || !S.panel) return; // closed, or fading out
  const app = $("app").getBoundingClientRect();
  if (innerWidth <= 700) {
    const anchor = $("side").getBoundingClientRect();
    pop.style.left = `${Math.max(16, (app.width - pop.offsetWidth) / 2)}px`;
    pop.style.top = `${anchor.bottom - app.top + 10}px`;
    return;
  }
  if (S.panel === "room") {
    const b = $("room-btn").getBoundingClientRect();
    pop.style.left = `${b.left - app.left}px`;
    pop.style.top = `${b.bottom - app.top + 10}px`;
    return;
  }
  const side = $("side").getBoundingClientRect(), item = $(`si-${S.panel}`).getBoundingClientRect();
  // While placing, the panel moves to the left if it would cover the sound.
  pop.style.left = `${S.panel === "place" && popSide === "left" ? 24 : side.left - app.left - pop.offsetWidth - 14}px`;
  pop.style.top = `${clamp(item.top + item.height / 2 - pop.offsetHeight / 2 - app.top, 90, app.height - pop.offsetHeight - 20)}px`;
}
const sliderPct = (el) => el.style.setProperty("--p", `${((el.value - el.min) / (el.max - el.min)) * 100}%`);
const hzText = () => `${S.orbitHz.toFixed(2)} Hz · ${(1 / S.orbitHz).toFixed(1)} s a turn`;
function renderPop() {
  const pop = $("pop");
  const stereo = S.mode === "stereo2", isLost = lost();
  // Rebuilt only when what the panel shows changes; live values (orbit speed,
  // position) are updated in place so a slider is never replaced mid-drag.
  const sig = S.panel === "layout" ? [S.panel, S.mode] : S.panel === "motion" ? [S.panel, S.mode, S.motion]
    : S.panel === "place" ? [S.panel, S.mode, S.motion, S.speakers.length, S.speakerControl]
    : [S.panel, S.laptop, S.source, S.live, isLost];
  once("pop", sig, () => {
    if (S.panel === "layout") {
      pop.innerHTML = `<h3>Layout</h3>
        <button class="choice" id="c-point" type="button" aria-pressed="${!stereo}">${ms("radar")}<span><b>Point</b><small>One sound you place anywhere around you</small></span></button>
        <button class="choice" id="c-stereo" type="button" aria-pressed="${stereo}">${ms("speaker")}<span><b>2.0 speakers</b><small>Your left, right and added speakers</small></span></button>`;
      $("c-point").onclick = () => { act("Layout Point"); setLocal({ mode: "point" }); send({ t: "layout", mode: "point" }); render(); };
      $("c-stereo").onclick = () => { act("Layout 2.0"); setLocal({ mode: "stereo2", motion: "fixed" }); send({ t: "layout", mode: "stereo2" }); render(); };
    } else if (S.panel === "motion") {
      pop.innerHTML = `<h3>Motion</h3>
        <button class="choice" id="c-fixed" type="button" aria-pressed="${S.motion === "fixed"}" ${stereo ? "disabled" : ""}>${ms("touch_app")}<span><b>Fixed</b><small>The sound stays where you put it</small></span></button>
        <button class="choice" id="c-orbit" type="button" aria-pressed="${S.motion === "orbit"}" ${stereo ? "disabled" : ""}>${ms("radar")}<span><b>Orbit</b><small>The sound circles around you</small></span></button>
        <div class="slider" ${S.motion === "orbit" && !stereo ? "" : "hidden"}><div class="slider-head"><span>Speed</span><output id="o-hz"></output></div><input id="hz" type="range" min="0.05" max="2" step="0.05" aria-label="Orbit speed"></div>
        ${stereo ? '<div class="pop-foot">Orbit moves the single Point sound, so it is off in 2.0.</div>' : ""}`;
      if (!stereo) {
        $("c-fixed").onclick = () => { act("Motion Fixed"); setLocal({ motion: "fixed" }); send({ t: "motion", motion: "fixed", orbitHz: S.orbitHz }); render(); };
        $("c-orbit").onclick = () => { act("Motion Orbit"); setLocal({ motion: "orbit" }); send({ t: "motion", motion: "orbit", orbitHz: S.orbitHz }); render(); };
        const hz = $("hz");
        hz.addEventListener("input", () => { setLocal({ orbitHz: Number(hz.value) }); render(); });
        hz.addEventListener("change", () => send({ t: "motion", motion: "orbit", orbitHz: S.orbitHz }));
      }
    } else if (S.panel === "place") {
      if (stereo) {
        pop.innerHTML = `<h3>Place <span class="speaker-count">${S.speakers.length} / ${S.maxSpeakers}</span></h3>
          <div class="speaker-list" role="group" aria-label="Speakers">${S.speakers.map(s => `<button class="speaker-row" data-speaker="${s.index}" type="button" aria-pressed="false"><span class="speaker-badge">${esc(s.label)}</span><span class="speaker-detail"></span></button>`).join("")}</div>
          <button class="speaker-add" id="speaker-add" type="button">${ms("add")} Add speaker</button>
          <div class="pop-foot"><span>Link speakers</span><button class="link" id="speaker-link" type="button" aria-label="Link speakers" aria-pressed="false">Link</button></div>
          <div id="speaker-editor"><div class="readout" id="speaker-read"></div>
          <div class="slider"><div class="slider-head"><span id="speaker-az-label">Direction</span><output id="speaker-az-value"></output></div><input id="speaker-az" type="range" min="-180" max="180" step="1" aria-label="Speaker direction"></div>
          <div class="slider"><div class="slider-head"><span id="speaker-el-label">Height</span><output id="speaker-el-value"></output></div><input id="speaker-el" type="range" min="-90" max="90" step="1" aria-label="Speaker height"></div>
          <div class="slider"><div class="slider-head"><span id="speaker-dist-label">Distance</span><output id="speaker-dist-value"></output></div><input id="speaker-dist" type="range" min="0" max="1000" step="1" aria-label="Speaker distance"></div></div>
          <div class="pop-foot speaker-foot"><span id="speaker-hint"></span><button class="link" id="speaker-remove" type="button">Remove</button></div>`;
        pop.querySelectorAll("[data-speaker]").forEach(b => { b.onclick = () => {
          speakerDraft = null; speakerIntent("speakerSelect", { index: Number(b.dataset.speaker) });
        }; });
        $("speaker-add").onclick = () => speakerIntent("speakerAdd");
        $("speaker-link").onclick = () => {
          speakerDraft = null; speakerIntent("matrixLink", { linked: !S.matrixLinked });
        };
        $("speaker-remove").onclick = () => speakerIntent("speakerRemove", { index: S.selectedSpeakerIndex });
        for (const k of ["az", "el", "dist"]) {
          const slider = $(`speaker-${k}`);
          slider.oninput = () => {
            if ((!speakerDraft || speakerDraft.committed) && !beginSpeaker(S.selectedSpeakerIndex)) return;
            if (S.matrixLinked) speakerDraft.axis = k;
            speakerDraft[k] = k === "dist" ? sliderToDist(Number(slider.value)) : Number(slider.value);
            renderSpeakerPlace();
          };
          slider.onchange = commitSpeaker;
        }
      } else {
        pop.innerHTML = `<h3>Place the sound</h3>
          <div class="readout" id="p-read"></div>
          <div class="slider"><div class="slider-head"><span>Direction</span><output id="p-az"></output></div><input id="s-az" type="range" min="-180" max="180" step="1" aria-label="Direction" ${S.motion === "orbit" ? "disabled" : ""}></div>
          <div class="slider"><div class="slider-head"><span>Height</span><output id="p-el"></output></div><input id="s-el" type="range" min="-90" max="90" step="1" aria-label="Height"></div>
          <div class="slider"><div class="slider-head"><span>Distance</span><output id="p-dist"></output></div><input id="s-dist" type="range" min="0" max="1000" step="1" aria-label="Distance"></div>
          <div class="pop-foot"><span>Or drag the glowing sound, or tap the floor.</span><button class="link" id="p-done" type="button">Done</button></div>`;
        const sAz = $("s-az"), sEl = $("s-el"), sDist = $("s-dist");
        sAz.addEventListener("input", () => { setLocal({ az: Number(sAz.value) }); renderPlace(); });
        sEl.addEventListener("input", () => { setLocal({ el: Number(sEl.value) }); renderPlace(); });
        sDist.addEventListener("input", () => { setLocal({ dist: sliderToDist(Number(sDist.value)) }); renderPlace(); });
        sAz.addEventListener("change", () => { snapDirection(); commitPlace(); });
        [sEl, sDist].forEach((el) => el.addEventListener("change", commitPlace));
        $("p-done").onclick = closePop;
      }
    } else if (S.panel === "room") {
      pop.innerHTML = `<h3>Moonlight Room</h3>
        <div class="pop-foot" style="font-size:14px;color:var(--text-2)"><span>${isLost ? "Reconnecting to" : "Connected to"} <b style="color:var(--text);font-weight:400">${esc(S.laptop)}</b></span><span>${isLost ? "" : "●"}</span></div>
        <div class="pop-foot" style="font-size:14px;color:var(--text-2)"><span>Music app</span><span style="color:var(--text)">${esc(S.source)}</span></div>
        <div class="pop-foot" style="font-size:14px;color:var(--text-2)"><span>Live Transfer</span><span style="color:var(--text)">${S.live ? "On" : "Off"}</span></div>
        <div class="pop-foot" style="font-size:14px;color:var(--text-2)"><span>Yinwei on this iPad</span><span style="color:var(--text)" id="room-build">${esc(buildText())}</span></div>
        ${S.live ? `<button class="choice needs-control" id="c-stop-live" type="button">${ms("stop_circle")}<span><b>Stop Live on laptop</b><small>The laptop keeps the music app open</small></span></button>` : ""}
        ${S.updates ? `<button class="choice" id="c-updates" type="button">${ms("info")}<span><b>Check for updates</b><small>Looks for a newer iPad build</small></span></button>` : ""}`;
      if (S.live) $("c-stop-live").onclick = () => { closePop(); send({ t: "liveStop" }); };
      if (S.updates) $("c-updates").onclick = () => { closePop(); send({ t: "checkUpdates" }); }; // the app checks and shows the result
    }
    requestAnimationFrame(placePop);
  });
  if (S.panel === "motion" && $("hz")) {
    const hz = $("hz");
    if (document.activeElement !== hz && Math.abs(hz.value - S.orbitHz) > 0.001) hz.value = S.orbitHz;
    sliderPct(hz); setText($("o-hz"), hzText()); hz.setAttribute("aria-valuetext", `${S.orbitHz.toFixed(2)} hertz, ${(1 / S.orbitHz).toFixed(1)} seconds a turn`);
  }
  if (S.panel === "place") renderPlace();
}
// "Build 61" for a published build, the plain version for a local one.
function buildText() { return !S.appBuild ? "Unknown" : /^\d+$/.test(S.appBuild) ? `Build ${S.appBuild}` : `Version ${S.appBuild}`; }
function renderPlace() {
  if (S.panel === "place" && S.mode === "stereo2") { renderSpeakerPlace(); return; }
  if (S.panel !== "place" || !$("p-read")) { const v = $("sv-place"); if (v) setText(v, S.mode === "point" ? fmtDist(S.dist) : "Speakers"); return; }
  setText($("p-read"), `${fmtAz(S.az)} · ${fmtEl(S.el)} · ${fmtDist(S.dist)}`);
  setText($("p-az"), fmtAz(S.az)); setText($("p-el"), fmtEl(S.el)); setText($("p-dist"), fmtDist(S.dist));
  const sAz = $("s-az"), sEl = $("s-el"), sDist = $("s-dist");
  if (document.activeElement !== sAz) sAz.value = Math.round(S.az);
  if (document.activeElement !== sEl) sEl.value = Math.round(S.el);
  if (document.activeElement !== sDist) sDist.value = distToSlider(S.dist);
  [sAz, sEl, sDist].forEach(sliderPct);
  sAz.setAttribute("aria-valuetext", RoomMath.sayAz(S.az)); sEl.setAttribute("aria-valuetext", RoomMath.sayEl(S.el));
  sDist.setAttribute("aria-valuetext", RoomMath.sayDist(S.dist));
  setText($("sv-place"), fmtDist(S.dist));
}
function renderSpeakerPlace() {
  if (!$("speaker-add")) return;
  const s = activeSpeaker(), editable = canEditSpeakers();
  const link = $("speaker-link");
  link.disabled = !editable;
  link.setAttribute("aria-pressed", String(S.matrixLinked));
  setText(link, S.matrixLinked ? "Linked" : "Link");
  $("speaker-add").disabled = !editable || S.speakers.length >= S.maxSpeakers;
  $("speaker-editor").hidden = !s;
  $("speaker-remove").hidden = !s || s.index < 2;
  $("speaker-remove").disabled = !editable;
  setText($("speaker-hint"), !S.speakerControl ? "Speaker editing is unavailable on this laptop." : S.matrixLinked ? "Linked · moving the whole array" : "Drag a speaker, or use the controls.");
  document.querySelectorAll("[data-speaker]").forEach(b => {
    const i = Number(b.dataset.speaker), pose = speakerPose(i);
    b.disabled = !editable;
    b.setAttribute("aria-pressed", String(s && i === s.index));
    setText(b.querySelector(".speaker-detail"), pose ? `${fmtAz(pose.az)} · ${fmtDist(pose.dist)}${pose.mute ? " · Muted" : ""}` : "");
  });
  if (!s) return;
  setText($("speaker-read"), `${S.matrixLinked ? "Array" : `Speaker ${s.label}`} · ${fmtAz(s.az)} · ${fmtEl(s.el)} · ${fmtDist(s.dist)}`);
  for (const k of ["az", "el", "dist"]) {
    const slider = $(`speaker-${k}`), fmt = k === "az" ? fmtAz : k === "el" ? fmtEl : fmtDist;
    const label = S.matrixLinked ? { az: "Array rotation", el: "Array height", dist: "Array distance" }[k]
      : { az: "Direction", el: "Height", dist: "Distance" }[k];
    setText($(`speaker-${k}-label`), label);
    slider.setAttribute("aria-label", S.matrixLinked ? label : `Speaker ${label.toLowerCase()}`);
    slider.disabled = !editable;
    if (document.activeElement !== slider) slider.value = k === "dist" ? distToSlider(s.dist) : Math.round(s[k]);
    sliderPct(slider); setText($(`speaker-${k}-value`), fmt(s[k]));
    slider.setAttribute("aria-valuetext", fmt(s[k]));
  }
}
// Placing is sent once, on release (as the app does today): the snapped direction if it snapped.
function commitPlace() {
  const az = snapAnim ? wrap(snapAnim.to) : S.az;
  setLocal({ az, el: S.el, dist: S.dist });
  if (snapAnim) S.az = snapAnim.from; // the snap animation finishes the move on screen
  send({ t: "place", az, el: S.el, dist: S.dist });
}

// ---------------------------------------------------------------- song progress
// The laptop reports the song's position about once a second (the music app
// may report it less often); between reports the page's own clock moves it.
let posAt = performance.now(), seekDragging = false;
const clock = (s) => { s = Math.max(0, Math.floor(s)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; };
const songPos = () => Math.min(S.dur, Math.max(0, S.pos + (S.playing && !lost() ? (performance.now() - posAt) / 1000 : 0)));
function paintScrub(p) {
  const seek = $("seek");
  seek.style.setProperty("--p", `${S.dur ? (p / S.dur) * 100 : 0}%`);
  setText($("t-pos"), clock(p)); setText($("t-left"), `-${clock(S.dur - p)}`);
}
function drawScrub() {
  const show = S.dur > 0 && S.notice !== "noapp";
  $("scrub").hidden = !show;
  if (!show) return;
  const seek = $("seek");
  seek.disabled = !S.seekable || otherHasControl() || lost();
  if (seekDragging) return; // your finger owns it
  if (Number(seek.max) !== S.dur) seek.max = S.dur;
  const p = songPos();
  seek.value = p;
  paintScrub(p);
}
setInterval(drawScrub, 250);
$("seek").addEventListener("pointerdown", () => { seekDragging = true; });
$("seek").addEventListener("input", () => { seekDragging = true; paintScrub(Number($("seek").value)); });
$("seek").addEventListener("change", () => {
  seekDragging = false;
  const sec = Number($("seek").value);
  setLocal({ pos: sec }); posAt = performance.now();
  send({ t: "seek", sec });
  drawScrub();
});

// ---------------------------------------------------------------- start progress
// A window above the bar while the laptop starts: a row per step (done, now,
// still to come), the seconds so far and a bar. Opening the music app is a step
// only when it wasn't open ("Already open" otherwise).
const STEPS = ["asking", "opening", "pressing", "starting", "audio"];
const CHECK = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
let connectRun = null; // { t0, opened, width }
function drawConnect(step) {
  const el = $("connect");
  if (!step) { if (connectRun) { connectRun = null; hideEl(el); } return; }
  if (!connectRun) connectRun = { t0: performance.now(), opened: false, width: 0 };
  if (step === "opening") connectRun.opened = true;
  const known = S.source && !/^(the Yinwei player|your music app)$/.test(S.source) ? S.source : "";
  const app = esc(S.opens || known || "your music app"), laptop = esc(S.laptop);
  const label = { asking: `Reaching ${laptop}`, opening: `Opening ${app}`, pressing: `Pressing play in ${app}`, starting: "Starting spatial sound", audio: "Connecting audio" };
  const at = STEPS.indexOf(step);
  const rows = STEPS.map((s, i) => {
    const skipped = s === "opening" && i < at && !connectRun.opened;
    const state = skipped ? "skip" : i < at ? "done" : i === at ? "now" : "next";
    const icon = state === "done" ? CHECK : state === "now" ? '<span class="spin"></span>' : '<i class="dot"></i>';
    return `<li class="${state}">${icon}<span>${label[s]}${skipped ? "<small>Already open</small>" : ""}</span></li>`;
  }).join("");
  const width = Math.round(((at + 0.5) / STEPS.length) * 100);
  el.innerHTML = `<div class="connect-head"><b>Connecting to ${laptop}</b><span id="connect-time"></span></div><ol>${rows}</ol><div class="connect-bar"><i style="width:${connectRun.width}%"></i></div>`;
  requestAnimationFrame(() => { const bar = el.querySelector(".connect-bar i"); if (bar) bar.style.width = `${width}%`; });
  connectRun.width = width;
  tickConnect();
  if (!el.classList.contains("open")) showEl(el);
}
function tickConnect() { if (connectRun && $("connect-time")) setText($("connect-time"), `${Math.floor((performance.now() - connectRun.t0) / 1000)} s`); }
setInterval(tickConnect, 500);

// ---------------------------------------------------------------- actions (intents)
function startListening() {
  if (S.listening !== "off" || lost() || S.notice === "noapp") return;
  const startLive = !S.live;
  setLocal({ listening: "connecting" }, { listening: (x) => x !== "off" }); // shown until the app reports connecting or on
  send({ t: "listen", startLive });
  render();
}
$("listen-btn").onclick = () => {
  if (S.listening === "on") { setLocal({ listening: "off" }); send({ t: "stopListening" }); render(); }
  else startListening();
};
$("play").onclick = () => { const playing = !S.playing; setLocal({ playing }); send({ t: "media", a: playing ? "play" : "pause" }); render(); };
$("next").onclick = () => send({ t: "media", a: "next" });
$("prev").onclick = () => send({ t: "media", a: "prev" });
$("take").onclick = () => { setLocal({ control: "mine" }); send({ t: "take" }); render(); };
$("view-btn").onclick = () => { act(S.view === "top" ? "room view" : "top view"); S.view = S.view === "top" ? "3d" : "top"; cam.tK = S.view === "top" ? 1 : 0; cam.tYaw = YAW_3D; cam.tLift = LIFT_3D; cam.tZoom = 1; $("view-btn").setAttribute("aria-label", S.view === "top" ? "Switch to room view" : "Switch to top view"); render(); };
$("si-layout").onclick = (e) => { e.stopPropagation(); openPop("layout", e.detail === 0); };
$("si-motion").onclick = (e) => { e.stopPropagation(); openPop("motion", e.detail === 0); };
$("si-place").onclick = (e) => { e.stopPropagation(); openPop("place", e.detail === 0); };
$("room-btn").onclick = (e) => { e.stopPropagation(); openPop("room", e.detail === 0); };
initBrowse();
// Escape closes the open panel or menu and puts focus back where it came from.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  if (isOpen($("pop"))) { const from = S.panel === "room" ? $("room-btn") : $(`si-${S.panel}`); closePop(); if (from) from.focus(); }
  else if (isOpen(menu)) { closeMenus(); $("more").focus(); }
});

const menu = $("menu");
function closeMenus() { hideEl(menu); $("more").setAttribute("aria-expanded", "false"); }
function dropUnder(el, btn) {
  const b = btn.getBoundingClientRect(), app = $("app").getBoundingClientRect();
  el.style.top = `${b.bottom - app.top + 12}px`;
  el.style.right = `${Math.max(16, app.right - b.right)}px`;
}
$("more").onclick = (e) => { e.stopPropagation(); const open = !isOpen(menu); closeMenus(); closePop(); if (open) { showEl(menu); dropUnder(menu, $("more")); $("more").setAttribute("aria-expanded", "true"); } };
document.addEventListener("click", (e) => {
  if (isOpen(menu) && !menu.contains(e.target)) closeMenus();
  const pop = $("pop");
  // A choice inside the panel re-renders it, so its button is gone by now: that is not an outside tap.
  if (isOpen(pop) && e.target.isConnected && !pop.contains(e.target) && !e.target.closest(".side-item") && !e.target.closest("#room-btn") && !e.target.closest("#now-card") && e.target !== $("gl")) closePop();
});
$("m-stop-listen").onclick = () => { closeMenus(); setLocal({ listening: "off" }); send({ t: "stopListening" }); render(); };
$("m-signout").onclick = () => { closeMenus(); send({ t: "signOut" }); };
$("m-close").onclick = () => { closeMenus(); send({ t: "close" }); }; // the app closes the room; listening carries on
$("m-updates").onclick = () => { closeMenus(); send({ t: "checkUpdates" }); }; // the app checks and shows the result
for (const q of ["high", "max", "lossless"]) {
  $(`q-${q}`).onclick = () => { if (S.quality !== q) { setLocal({ quality: q }); send({ t: "quality", quality: q }); render(); } }; // the menu stays open
}
$("m-audio-diagnostics").onclick = () => { closeMenus(); send({ t: "copyAudioDiagnostics" }); };
document.addEventListener("gesturestart", (e) => e.preventDefault()); // iPad: a pinch never zooms the page (and never shifts the header)

// Where the AirPlay button sits, so the app can put iPadOS's real picker exactly over it (P3).
let lastRects = "";
function reportRects() {
  const b = $("airplay"), r = b && b.getBoundingClientRect();
  const rects = { t: "rects", airplay: r && r.width ? [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)] : null };
  const sig = JSON.stringify(rects);
  if (sig !== lastRects) { lastRects = sig; send(rects); }
}
new ResizeObserver(() => reportRects()).observe($("player"));
addEventListener("resize", reportRects);

// ---------------------------------------------------------------- live level line
const levels = new Array(90).fill(0);
// The level line's size is measured when it changes, not on every redraw
// (a size read 24 times a second forces the page to lay itself out).
let levelBox = null;
new ResizeObserver(() => { levelBox = null; }).observe($("level"));
function drawLevel() {
  const cv = $("level");
  if (!levelBox) { const b = cv.getBoundingClientRect(); levelBox = { width: b.width, height: b.height }; }
  const r = levelBox;
  if (!r.width) return;
  const dpr = Math.min(devicePixelRatio || 1, 2);
  if (cv.width !== Math.round(r.width * dpr)) { cv.width = Math.round(r.width * dpr); cv.height = Math.round(r.height * dpr); }
  const c = cv.getContext("2d");
  c.setTransform(dpr, 0, 0, dpr, 0, 0); c.clearRect(0, 0, r.width, r.height);
  const mid = r.height / 2, bw = r.width / levels.length;
  levels.forEach((v, i) => {
    const hh = Math.max(1, v * (r.height - 2));
    c.fillStyle = `rgba(150,185,255,${(0.25 + 0.6 * (i / levels.length)).toFixed(3)})`;
    c.fillRect(i * bw, mid - hh / 2, Math.max(1, bw - 1.2), hh);
  });
}

// ---------------------------------------------------------------- the app's handle on the page
// Dart calls these with runJavaScript(...). Everything else stays private.
window.YinweiListen = Object.freeze({
  music: (value) => musicSheet.receive(value),
  soda: (value) => musicSheet.receiveOnline(value),
  version: ListenBridge.VERSION,
  apply,                                        // (state) app → page, at most 10 times a second
  toast: (text, holdMs) => toast(String(text), Number(holdMs) || 1500), // e.g. "Applied on the laptop" after a command succeeds
  suspend: () => { suspended = true; },         // app in the background or off this screen: no rendering
  resume: () => { suspended = false; },
  setQuality: (q) => { if (["auto", "full", "light"].includes(q)) { quality.setting = q; quality.activeTimes.length = 0; if (q === "full") setRatio(quality.maxRatio); applyQuality(q === "light" ? "light" : "full"); } },
  devOverlay: (on) => { $("fps").hidden = !on; renderMeter(); }, // developer diagnostics only
  speedReport: () => speedReport(),
  speedTest: () => runSpeedTest(),
  replayOpening: () => replayOpening(),         // review page only; call inside a tap so its sound may play
});

// Review only: index.html?dev loads a stand-in for the app (dev/dev-host.js, never bundled).
if (/[?&]dev(=|&|$)/.test(location.search)) { const s = document.createElement("script"); s.src = "dev/dev-host.js"; document.body.appendChild(s); }
