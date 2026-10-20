"use strict";
// Review stand-in for the app. NOT part of the app: pubspec lists
// assets/listen_room/ without this dev/ folder, and the app never adds "?dev".
//
// It plays the app's side of the bridge in a plain browser: it keeps a pretend
// laptop's state, sends it with YinweiListen.apply() 10 times a second, answers
// the page's intents the way the app will (after a short delay, like a real
// round trip), and shows a panel to switch situations plus a log of every
// intent the page sends.
(() => {
  const tracks = [
    { title: "晴天", artist: "周杰伦" }, { title: "富士山下", artist: "陈奕迅" }, { title: "红豆", artist: "王菲" },
    { title: "夜曲", artist: "周杰伦" }, { title: "Vienna", artist: "Billy Joel" },
  ];
  let ti = 0;
  const M = {
    v: 1, laptop: "TIM-LAPTOP", connection: "connected", source: "汽水音乐", live: true, playing: true,
    listening: "on", control: "mine", notice: "none", mode: "point", motion: "fixed", orbitHz: 0.4,
    az: 35, el: 20, dist: 3.2, track: { ...tracks[0] }, volume: 0.72, level: 0,
    stats: { received: 18240, bufferMs: 160, underruns: 0 }, opens: null, pending: false, progress: null,
    pos: 42, dur: 245, seekable: true, quality: "high", stream: "high", opus: true,
    speakers: [], selectedSpeakerIndex: 0, arrayRevision: 1, maxSpeakers: 8, speakerControl: true, matrixLinked: false,
  };
  function seedSpeakers(count) {
    M.speakers = Array.from({ length: count }, (_, index) => ({ index,
      label: index === 0 ? "L" : index === 1 ? "R" : String(index + 1),
      az: [-30, 30, -70, 70, -110, 110, -150, 150][index], el: 0, dist: 1.8,
      gainDb: 0, mute: false, feed: index === 0 ? "left" : index === 1 ? "right" : "mid" }));
    M.selectedSpeakerIndex = count > 2 ? 2 : 0; M.arrayRevision++;
  }
  seedSpeakers(2);
  const later = (ms, f) => setTimeout(f, ms);
  const say = (t) => YinweiListen.toast(t);
  const applied = () => say("Applied on the laptop");
  const log = [];

  function handle(i) {
    log.unshift(JSON.stringify(i)); log.length = Math.min(log.length, 8); renderLog();
    switch (i.t) {
      case "listen":
        M.listening = "connecting";
        if (i.startLive) { // the laptop's steps, as the app reports them
          const steps = M.opens ? ["asking", "opening", "pressing", "starting", "audio"] : ["asking", "pressing", "starting", "audio"];
          M.pending = true;
          steps.forEach((s, n) => later(n * 1400, () => { M.progress = s; if (s === "audio") M.pending = false; }));
          later(steps.length * 1400, () => { Object.assign(M, { live: true, playing: true, listening: "on", source: "汽水音乐", track: M.track || { ...tracks[ti] }, opens: null, progress: null }); say(`Playing ${M.track.title} from ${M.laptop}`); });
          break;
        }
        later(900, () => { Object.assign(M, { live: true, playing: true, listening: "on", source: "汽水音乐", track: M.track || { ...tracks[ti] }, opens: null }); say(i.startLive ? `Playing ${M.track.title} from ${M.laptop}` : "Listening on this iPad"); });
        break;
      case "stopListening": later(150, () => { M.listening = "off"; say("Stopped listening · the laptop keeps playing"); }); break;
      case "take": later(150, () => { M.control = "mine"; if (M.notice === "taken") M.notice = "none"; say("You're in control"); }); break;
      case "media":
        later(150, () => {
          if (i.a === "next" || i.a === "prev") { ti = (ti + (i.a === "next" ? 1 : tracks.length - 1)) % tracks.length; M.track = { ...tracks[ti] }; M.playing = true; }
          else M.playing = i.a === "play";
        });
        break;
      case "liveStop": later(300, () => { Object.assign(M, { live: false, listening: "off", playing: false }); say("Live stopped on the laptop"); }); break;
      case "layout": later(200, () => { M.mode = i.mode; if (i.mode === "stereo2") M.motion = "fixed"; applied(); }); break;
      case "motion": later(200, () => { M.motion = i.motion; M.orbitHz = i.orbitHz; applied(); }); break;
      case "place": later(200, () => { Object.assign(M, { az: i.az, el: i.el, dist: i.dist }); applied(); }); break;
      case "speakerAdd":
      case "speakerRemove":
      case "speakerSelect":
      case "speakerPlace":
        M.pending = true;
        later(200, () => {
          M.pending = false;
          if (i.arrayRevision !== M.arrayRevision) { say("The speakers changed. Select the speaker again."); return; }
          if (i.t === "speakerAdd" && M.speakers.length < 8) {
            const index = M.speakers.length;
            M.speakers.push({ index, label: String(index + 1), az: 0, el: 0, dist: 1.8, gainDb: 0, mute: false, feed: "mid" });
            M.selectedSpeakerIndex = index;
          } else if (i.t === "speakerRemove" && i.index >= 2 && M.speakers[i.index]) {
            M.speakers.splice(i.index, 1); M.speakers.forEach((s, index) => s.index = index);
            M.selectedSpeakerIndex = Math.min(i.index, M.speakers.length - 1);
          } else if (M.speakers[i.index]) {
            M.selectedSpeakerIndex = i.index;
            if (i.t === "speakerPlace") Object.assign(M.speakers[i.index], { az: i.az, el: i.el, dist: i.dist });
          }
          M.arrayRevision++; applied();
        }); break;
      case "volume": M.volume = i.v; break;
      case "seek": later(400, () => { M.pos = Math.min(M.dur, Math.max(0, i.sec)); }); break;
      case "signOut": say("The app goes back to its own sign-in screen"); break;
      case "airplay": say("In the app, iPadOS's AirPlay picker opens here"); break;
      case "close": say("In the app, the room closes and listening carries on"); break;
      case "quality": later(250, () => { M.quality = M.stream = i.quality; say({ high: "Sound: Opus 320 kbps", max: "Sound: Opus 510 kbps", lossless: "Sound: uncompressed" }[i.quality]); }); break;
      default: break; // ready, error, rects
    }
  }
  addEventListener("yinwei-intent", (e) => handle(e.detail));

  // The laptop's side, 10 times a second like the app's bridge.
  setInterval(() => {
    const dt = 0.1, lost = M.notice === "lost";
    if (M.mode === "point" && M.motion === "orbit" && !lost) M.az = wrap(M.az + 360 * M.orbitHz * dt);
    const sounding = M.live && M.playing && !lost && M.notice !== "noapp";
    // The music app reports its position about once a second, like the laptop.
    if (M.live && M.playing && !lost) { M.clock = (M.clock || 0) + dt; if (M.clock >= 1) { M.clock = 0; M.pos = (M.pos + 1) % M.dur; } }
    M.level = sounding && M.listening === "on" ? 0.35 + Math.random() * 0.6 : 0;
    if (sounding && M.listening === "on") M.stats.received += 9;
    YinweiListen.apply(JSON.parse(JSON.stringify(M)));
  }, 100);

  // ---------------------------------------------------------------- the review panel
  const css = `
.dev-pill { border-style: dashed !important; border-color: rgba(200,215,255,0.3) !important; color: var(--text-3); font-size: var(--t-cap); background: transparent !important; backdrop-filter: none !important; }
.dev { position: absolute; z-index: 41; width: min(340px, calc(100vw - 48px)); max-height: calc(100% - 120px); overflow: auto; padding: 16px; border-radius: 22px; outline: 1.5px dashed rgba(200,215,255,0.25); outline-offset: -7px; display: flex; flex-direction: column; gap: 12px; font-size: 13px; }
.dev h2 { margin: 0; font-size: 14px; font-weight: 500; } .dev p { margin: 0; color: var(--text-3); font-size: 12px; }
.dev .grp { display: flex; flex-direction: column; gap: 7px; } .dev .grp > span { font-size: 11px; letter-spacing: 0.1em; text-transform: uppercase; color: var(--text-3); }
.dev .opts { display: flex; flex-wrap: wrap; gap: 7px; } .dev .opts button { padding: 7px 11px; border-radius: 10px; background: rgba(255,255,255,0.06); font-size: 12px; }
.dev .opts button[aria-pressed="true"] { background: var(--blue); color: #fff; }
.dev .report { width: 100%; height: 42px; font-size: 14px; justify-content: center; }
.dev pre, .dev textarea { margin: 0; width: 100%; font: 11px/1.45 ui-monospace, "SF Mono", Menlo, monospace; color: var(--text-2); background: rgba(0,0,0,0.3); border: 1px solid var(--rim); border-radius: 12px; padding: 8px; white-space: pre-wrap; word-break: break-all; }
.dev textarea { height: 150px; resize: vertical; }`;
  const style = document.createElement("style"); style.textContent = css; document.head.appendChild(style);
  const pill = document.createElement("button");
  pill.className = "pill dev-pill"; pill.type = "button"; pill.textContent = "Review P1"; pill.setAttribute("aria-expanded", "false");
  document.querySelector(".top-right").prepend(pill);
  const panel = document.createElement("div");
  panel.className = "dev glass"; panel.hidden = true;
  const group = (label, key, opts) => `<div class="grp"><span>${label}</span><div class="opts" data-key="${key}">${opts.map(([v, t]) => `<button type="button" data-v="${v}">${t}</button>`).join("")}</div></div>`;
  panel.innerHTML = `<div><h2>Listen Room · P1 review</h2><p>A stand-in for the app: it plays the laptop and answers the page's intents. Not part of the app.</p></div>
    ${group("Laptop", "live", [["on", "Live on"], ["off", "Live off"]])}
    ${group("This iPad", "listening", [["on", "Listening"], ["off", "Not listening"]])}
    ${group("Control", "control", [["mine", "I have control"], ["other", "Laptop took control"]])}
    ${group("Situation", "notice", [["none", "All good"], ["busy", "Safari is listening"], ["interrupted", "Phone call"], ["lost", "Connection lost"], ["noapp", "No music app"], ["opens", "Laptop opens app"]])}
    ${group("Start progress", "progress", [["none", "Idle"], ["asking", "Asking"], ["opening", "Opening app"], ["pressing", "Pressing play"], ["starting", "Starting"], ["audio", "Audio"]])}
    ${group("Room quality", "quality", [["auto", "Auto"], ["full", "Full"], ["light", "Light"]])}
    ${group("Developer overlay", "fps", [["off", "Off"], ["on", "FPS meter"]])}
    ${group("2.0 speakers", "speakers", [["2", "2 speakers"], ["3", "3 speakers"], ["8", "8 speakers"]])}
    <div class="grp"><span>Intents the page sent (newest first)</span><pre id="dev-log">–</pre></div>
    <div class="grp"><button class="cta report" id="dev-replay" type="button">Replay opening (with sound)</button></div>
    <div class="grp"><button class="cta report" id="dev-bench" type="button">Run speed test (8 s)</button><button class="cta report" id="dev-copy" type="button">Copy speed report</button><textarea id="dev-report" aria-label="Speed report" readonly hidden></textarea></div>`;
  document.body.appendChild(panel);
  panel.querySelector("#dev-replay").onclick = () => YinweiListen.replayOpening(); // a tap, so its sound plays
  const local = { quality: "auto", fps: "off" };
  function renderLog() { const el = document.getElementById("dev-log"); if (el) el.textContent = log.join("\n") || "–"; }
  function sync() {
    const vals = { live: M.live ? "on" : "off", listening: M.listening === "off" ? "off" : "on", control: M.control, notice: M.opens ? "opens" : M.notice, progress: M.progress || "none", speakers: String(M.speakers.length), ...local };
    panel.querySelectorAll(".opts").forEach((g) => g.querySelectorAll("button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.v === vals[g.dataset.key]))));
  }
  panel.querySelectorAll(".opts").forEach((g) => g.addEventListener("click", (e) => {
    e.stopPropagation();
    const b = e.target.closest("button"); if (!b) return;
    const k = g.dataset.key, v = b.dataset.v;
    if (k === "live") { M.live = v === "on"; M.playing = M.live; if (!M.live) M.listening = "off"; else if (M.notice === "noapp") M.notice = "none"; }
    if (k === "listening") { M.listening = v; if (v === "on") { M.live = true; M.playing = true; } }
    if (k === "control") M.control = v;
    if (k === "speakers") { seedSpeakers(Number(v)); M.mode = "stereo2"; M.motion = "fixed"; }
    if (k === "notice") {
      // "Laptop opens app": no music app open, but the laptop opens 汽水音乐 on Start.
      M.notice = v === "opens" ? "none" : v;
      Object.assign(M, v === "opens" ? { live: false, playing: false, listening: "off", source: "", track: null, opens: "汽水音乐" }
        : { source: "汽水音乐", track: M.track || { ...tracks[ti] }, opens: null });
      if (v === "noapp") Object.assign(M, { live: false, playing: false, listening: "off" });
    }
    if (k === "progress") { M.progress = v === "none" ? null : v; if (M.progress) Object.assign(M, { live: false, playing: false, listening: "connecting" }); }
    if (k === "quality") { local.quality = v; YinweiListen.setQuality(v); }
    if (k === "fps") { local.fps = v; YinweiListen.devOverlay(v === "on"); }
    sync();
  }));
  const place = () => { const b = pill.getBoundingClientRect(); panel.style.top = `${b.bottom + 12}px`; panel.style.right = `${Math.max(16, innerWidth - b.right)}px`; };
  pill.addEventListener("click", (e) => { e.stopPropagation(); panel.hidden = !panel.hidden; pill.setAttribute("aria-expanded", String(!panel.hidden)); if (!panel.hidden) { place(); sync(); renderLog(); } });
  document.addEventListener("click", (e) => { if (!panel.hidden && !panel.contains(e.target) && e.target !== pill) { panel.hidden = true; pill.setAttribute("aria-expanded", "false"); } });
  document.getElementById("dev-bench").addEventListener("click", async (e) => {
    e.stopPropagation(); panel.hidden = true; say("Speed test: 8 seconds, please don't touch the screen");
    await YinweiListen.speedTest(); say("Speed test done · now copy the speed report");
  });
  document.getElementById("dev-copy").addEventListener("click", (e) => {
    e.stopPropagation();
    const text = YinweiListen.speedReport(), box = document.getElementById("dev-report");
    box.hidden = false; box.value = text;
    const select = () => { box.focus(); box.select(); say("Select the report and copy it"); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(() => say("Report copied · paste it to Claude"), select);
    else select();
  });
})();
