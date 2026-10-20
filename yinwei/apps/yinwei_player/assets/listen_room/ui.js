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
  screen: "room", view: "3d", panel: null,
};
const held = {}; // values you just set, kept until the app confirms them
const setLocal = (fields, ok) => { const now = performance.now(); for (const k in fields) { S[k] = fields[k]; ListenBridge.hold(held, k, fields[k], now, ok && ok[k]); } };

// Intents, page → app. In the app the "YinweiNative" channel carries them to
// Dart; in a plain browser they become a "yinwei-intent" event (dev host, tests).
function send(intent) {
  const msg = JSON.stringify(intent);
  try { if (window.YinweiNative && typeof window.YinweiNative.postMessage === "function") { window.YinweiNative.postMessage(msg); return; } } catch (e) { /* fall through */ }
  window.dispatchEvent(new CustomEvent("yinwei-intent", { detail: JSON.parse(msg) }));
}
function apply(next) {
  if (typeof next === "string") { try { next = JSON.parse(next); } catch (e) { return; } }
  const now = performance.now(), heldBefore = Object.keys(held).join();
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
function paintArt(hue, empty) {
  const cv = $("art"), c = cv.getContext("2d"), w = cv.width, h = cv.height;
  if (empty) { // nothing playing: a quiet, empty cover
    const g = c.createLinearGradient(0, 0, 0, h); g.addColorStop(0, "#151b2b"); g.addColorStop(1, "#0b0f19");
    c.fillStyle = g; c.fillRect(0, 0, w, h);
    c.strokeStyle = "rgba(200,215,255,0.18)"; c.lineWidth = 3; c.beginPath(); c.arc(w / 2, h / 2, w * 0.16, 0, Math.PI * 2); c.stroke();
    return;
  }
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
  once("art", [noApp, t.title], () => paintArt(ListenBridge.hueOf(t.title), noApp || !(S.track && S.track.title)));
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
  once("right", [S.listening, S.live, isLost, noApp, S.laptop, S.source, opens, progress], () => {
    if (progress) {
      right.innerHTML = progressHtml(progress);
    } else if (listening) {
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
      right.innerHTML = `<div class="listen-cta"><button class="cta" id="go" type="button" ${isLost || noApp ? "disabled" : ""}>${ms("headphones")}${S.live || noApp ? "Listen here" : "Start on laptop and listen"}</button><small>${noApp ? `Waiting for a music app on ${esc(S.laptop)}` : isLost ? `Waiting for ${esc(S.laptop)}` : S.live ? `${esc(cap(S.laptop))} is playing with spatial sound` : opens ? `Opens ${esc(opens)} on ${esc(S.laptop)}` : `${esc(S.source)} is paused on the laptop`}</small></div>`;
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
  setText($("d-recv"), Number(S.stats.received || 0).toLocaleString());
  setText($("d-buffer"), S.stats.bufferMs ? `${Math.round(S.stats.bufferMs)} ms` : "–");
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
    : S.panel === "place" ? [S.panel, S.mode, S.motion] : [S.panel, S.laptop, S.source, S.live, isLost];
  once("pop", sig, () => {
    if (S.panel === "layout") {
      pop.innerHTML = `<h3>Layout</h3>
        <button class="choice" id="c-point" type="button" aria-pressed="${!stereo}">${ms("radar")}<span><b>Point</b><small>One sound you place anywhere around you</small></span></button>
        <button class="choice" id="c-stereo" type="button" aria-pressed="${stereo}">${ms("speaker")}<span><b>2.0 speakers</b><small>Left and right at ±30°, 1.8 m in front</small></span></button>`;
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
        pop.innerHTML = `<h3>Place</h3><div class="pop-foot" style="font-size:14px">In 2.0 the two speakers sit at ±30°, 1.8 m in front of you. Switch Layout to Point to place the sound yourself.</div>`;
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
        ${S.live ? `<button class="choice needs-control" id="c-stop-live" type="button">${ms("stop_circle")}<span><b>Stop Live on laptop</b><small>The laptop keeps the music app open</small></span></button>` : ""}`;
      if (S.live) $("c-stop-live").onclick = () => { closePop(); send({ t: "liveStop" }); };
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
function renderPlace() {
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

// Start progress: one line for the current step, and a dot per laptop step.
const STEPS = ["opening", "pressing", "starting", "audio"];
function progressHtml(step) {
  const known = S.source && !/^(the Yinwei player|your music app)$/.test(S.source) ? S.source : "";
  const app = esc(S.opens || known || "your music app");
  const text = {
    asking: `Asking ${esc(S.laptop)}…`,
    opening: `Opening ${app} on ${esc(S.laptop)}…`,
    pressing: `Pressing play in ${app}…`,
    starting: "Starting spatial sound…",
    audio: "Connecting audio…",
  }[step];
  const at = STEPS.indexOf(step);
  const dots = STEPS.map((s, i) => `<i class="${i < at ? "done" : i === at ? "now" : ""}"></i>`).join("");
  return `<div class="listen-cta"><div class="progress glass" role="status" aria-live="polite"><span class="spin" aria-hidden="true"></span><span>${text}</span></div><div class="steps" aria-hidden="true">${dots}</div></div>`;
}

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
  if (isOpen(pop) && e.target.isConnected && !pop.contains(e.target) && !e.target.closest(".side-item") && !e.target.closest("#room-btn") && e.target !== $("gl")) closePop();
});
$("m-stop-listen").onclick = () => { closeMenus(); setLocal({ listening: "off" }); send({ t: "stopListening" }); render(); };
$("m-signout").onclick = () => { closeMenus(); send({ t: "signOut" }); };
$("m-close").onclick = () => { closeMenus(); send({ t: "close" }); }; // the app closes the room; listening carries on
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
  version: ListenBridge.VERSION,
  apply,                                        // (state) app → page, at most 10 times a second
  toast: (text, holdMs) => toast(String(text), Number(holdMs) || 1500), // e.g. "Applied on the laptop" after a command succeeds
  suspend: () => { suspended = true; },         // app in the background or off this screen: no rendering
  resume: () => { suspended = false; },
  setQuality: (q) => { if (["auto", "full", "light"].includes(q)) { quality.setting = q; quality.activeTimes.length = 0; if (q === "full") setRatio(quality.maxRatio); applyQuality(q === "light" ? "light" : "full"); } },
  devOverlay: (on) => { $("fps").hidden = !on; renderMeter(); }, // developer diagnostics only
  speedReport: () => speedReport(),
  speedTest: () => runSpeedTest(),
});

// Review only: index.html?dev loads a stand-in for the app (dev/dev-host.js, never bundled).
if (/[?&]dev(=|&|$)/.test(location.search)) { const s = document.createElement("script"); s.src = "dev/dev-host.js"; document.body.appendChild(s); }
