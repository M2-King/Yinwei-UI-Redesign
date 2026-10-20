"use strict";
// Yinwei Listen Room: the 3D room (three.js r128), its frame loop, touch input,
// speed meter (dev overlay) and recovery when the GPU drops the 3D view.
// Loaded after room-math.js and ui.js; the scripts share one page scope.
// Everything shown comes from the app's state (S, filled by YinweiListen.apply
// in ui.js); this file never decides app state on its own.

// ---------------------------------------------------------------- 3D room
// World units are display metres; every coordinate rule is in ROOM MATH above.
// Room view: behind your chair, looking out of the window. Top view: from
// above (k blends between them).
const YAW_3D = -0.14, LIFT_3D = 11 * DEG;
const cam = { yaw: YAW_3D, lift: LIFT_3D, zoom: 1, k: 0, tYaw: YAW_3D, tLift: LIFT_3D, tZoom: 1, tK: 0 };
let three = null;
// The opening move: when the room first appears, the camera glides in from a
// little higher, further and to the left (off under reduced motion).
let entered = false, entrance = null;
// The opening (the lights coming on, the sound igniting, the title, its sound
// effects); see applyOpening. Off under reduced motion.
let opening = null, replaySound = false;
const IGNITE = 1.9, OPENING_END = 3.4, MOVE_MS = 3000;
// Gentle motion after you let go: the camera glides to a stop (fling) and the
// direction settles onto 0°, ±30°, ±90° or 180° when released close to one.
let fling = null, snapAnim = null, popSide = "right", bench = null;
function snapDirection() {
  if (S.motion === "orbit" || S.mode !== "point") return;
  const to = RoomMath.snapAz(S.az);
  if (to === null) return;
  if (reduced) { S.az = wrap(to); renderPlace(); } else snapAnim = { t0: 0, from: S.az, to };
}
function resetView() { fling = null; cam.tYaw = YAW_3D; cam.tLift = LIFT_3D; cam.tZoom = 1; }
// One render of everything, hidden parts included, into an off-screen buffer.
// Building shaders is not all: the GPU also prepares each drawing setup the
// first time it is used. This way that happens while the camera still waits,
// not during the opening move or the first switch to 2.0.
let warmTarget = null;
function warmRender() {
  const { T, renderer, scene, camera, composer } = three;
  const shown = [];
  const reveal = (o) => { if (o && !o.visible) { o.visible = true; shown.push(o); } };
  [three.speakers, three.guides, three.orbit, three.source, three.beam, three.sourceGlow, ...three.sourceRings].forEach(reveal);
  three.speakerFx.forEach((sp) => { reveal(sp.glow); sp.rings.forEach(reveal); });
  const full = composer && quality.effective !== "light";
  const target = full ? composer.renderTarget1 : (warmTarget = warmTarget || new T.WebGLRenderTarget(64, 64));
  three.skipReflection = false;
  renderer.setRenderTarget(target); renderer.render(scene, camera); renderer.setRenderTarget(null);
  shown.forEach((o) => (o.visible = false));
}
function sourcePos(out) {
  return out.set(...RoomMath.toRoom(S.az, S.el, S.dist));
}

// The view through the window: night sky, stars, the moon rising over a
// valley, three ridges of mountains, the far lake with shoreline lights.
// Painted once and wrapped on a far cylinder (front of the room = middle).
// The near lake is real 3D water in front of it (see "outside").
function paintNight() {
  const W = 4096, H = 1024, cv = document.createElement("canvas");
  cv.width = W; cv.height = H;
  const g = cv.getContext("2d");
  let seed = 7;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  const HZ = H * 0.6;
  const sky = g.createLinearGradient(0, 0, 0, HZ);
  sky.addColorStop(0, "#02040a"); sky.addColorStop(0.65, "#0c1430"); sky.addColorStop(1, "#22305c");
  g.fillStyle = sky; g.fillRect(0, 0, W, HZ);
  // a faint band of the Milky Way
  for (let i = 0; i < 1400; i++) {
    const t = rnd(), x = t * W, y = H * (0.08 + 0.3 * t) + (rnd() - 0.5) * H * 0.12;
    g.fillStyle = `rgba(170,190,255,${(rnd() * 0.05).toFixed(3)})`;
    g.beginPath(); g.arc(x, y, 6 + rnd() * 18, 0, Math.PI * 2); g.fill();
  }
  for (let i = 0; i < 2200; i++) {
    const x = rnd() * W, y = rnd() * HZ * 0.92, big = rnd() > 0.985;
    g.fillStyle = `rgba(225,233,255,${((0.25 + rnd() * 0.75) * (1 - y / HZ)).toFixed(3)})`;
    g.fillRect(x, y, big ? 2.4 : 1.1, big ? 2.4 : 1.1);
  }
  // ridges: whole sine cycles across the width so the panorama wraps
  const STEP = 3;
  const ridge = (base, amp, k, color, haze) => {
    const ph = [rnd() * 6.3, rnd() * 6.3, rnd() * 6.3, rnd() * 6.3];
    const top = new Float32Array(Math.floor(W / STEP) + 1);
    for (let i = 0; i < top.length; i++) {
      const u = ((i * STEP) / W) * Math.PI * 2;
      const n = 0.45 * Math.sin(u * k + ph[0]) + 0.3 * Math.sin(u * k * 2.7 + ph[1]) + 0.18 * Math.sin(u * k * 6.1 + ph[2]) + 0.07 * Math.sin(u * k * 13 + ph[3]);
      top[i] = base - amp * (0.55 + n);
    }
    return { top, base, amp, color, haze };
  };
  const ridges = [
    ridge(HZ - H * 0.035, H * 0.17, 3, "#1a2342", "#26335c"),
    ridge(HZ, H * 0.1, 5, "#0f162c", "#18213f"),
    ridge(HZ + H * 0.012, H * 0.045, 9, "#080d1b", "#0d1428"),
  ];
  // the moon rises over the lowest gap in the ridges in front of the room
  let best = Math.round((W * 0.5) / STEP), bestTop = 0;
  for (let i = Math.round((W * 0.43) / STEP); i <= Math.round((W * 0.57) / STEP); i++) {
    const t = Math.min(ridges[0].top[i], ridges[1].top[i]);
    if (t > bestTop) { bestTop = t; best = i; }
  }
  // The cylinder stretches the painting sideways, so the moon itself is a
  // round sprite placed here (see "outside"); only its path is painted.
  const mr = 22, mx = best * STEP, my = Math.min(bestTop - mr * 3.2, H * 0.5);
  for (const r of ridges) {
    g.beginPath(); g.moveTo(0, H);
    for (let i = 0; i < r.top.length; i++) g.lineTo(i * STEP, r.top[i]);
    g.lineTo(W, H); g.closePath();
    const fill = g.createLinearGradient(0, r.base - r.amp * 1.4, 0, r.base);
    fill.addColorStop(0, r.color); fill.addColorStop(1, r.haze);
    g.fillStyle = fill; g.fill();
  }
  // the far lake, the moon's path, shoreline lights and their reflections
  const lake = g.createLinearGradient(0, HZ, 0, H);
  lake.addColorStop(0, "#151f3e"); lake.addColorStop(0.35, "#0a1026"); lake.addColorStop(1, "#03050c");
  g.fillStyle = lake; g.fillRect(0, HZ + H * 0.012, W, H);
  for (let i = 0; i < 70; i++) {
    const y = HZ + H * 0.02 + i * H * 0.0045, w = (14 + rnd() * 50) * (1 + i * 0.03);
    g.fillStyle = `rgba(210,222,255,${(0.32 * (1 - i / 70)).toFixed(3)})`;
    g.fillRect(mx - w / 2 + (rnd() - 0.5) * 30, y, w, 1.6);
  }
  // Shoreline lights gather in a few small towns (never in the moon's path).
  // Each light has a short, broken reflection that wavers on the far lake.
  const gauss = () => Math.sqrt(-2 * Math.log(rnd() + 1e-6)) * Math.cos(rnd() * Math.PI * 2);
  const towns = [[0.355, 0.008, 34], [0.405, 0.005, 18], [0.452, 0.004, 9], [0.565, 0.006, 22], [0.618, 0.011, 46], [0.675, 0.006, 16], [0.15, 0.01, 30], [0.85, 0.01, 30]]
    .filter(([u]) => Math.abs(u - mx / W) > 0.035)
    .map(([u, sd, n]) => ({ u, sd, n }));
  for (const t of towns) {
    const cx = t.u * W, spread = t.sd * W;
    // the town's faint glow on the haze, and its soft reflection
    const halo = g.createRadialGradient(cx, HZ + H * 0.004, 0, cx, HZ + H * 0.004, spread * 2.4);
    halo.addColorStop(0, "rgba(255,196,130,0.07)"); halo.addColorStop(1, "rgba(255,196,130,0)");
    g.fillStyle = halo; g.fillRect(cx - spread * 2.4, HZ - spread * 2.4, spread * 4.8, spread * 4.8);
    for (let i = 0; i < t.n; i++) {
      const x = cx + gauss() * spread, up = Math.pow(rnd(), 2.2);
      const y = HZ + H * 0.013 - up * H * 0.022 - rnd() * H * 0.002;
      const warm = rnd() > 0.18, a = 0.55 + rnd() * 0.45, sz = rnd() > 0.85 ? 2.2 : 1.4;
      g.fillStyle = warm ? `rgba(255,210,150,${a.toFixed(2)})` : `rgba(205,222,255,${(a * 0.9).toFixed(2)})`;
      g.fillRect(x, y, sz, sz);
      if (up > 0.25) continue; // lights up the hill are hidden from the water
      const dashes = 2 + Math.floor(rnd() * 4);
      for (let k = 0; k < dashes; k++) {
        if (rnd() < 0.3) continue;
        const dy = HZ + H * 0.016 + k * H * (0.004 + rnd() * 0.003), dw = 1.2 + rnd() * 3.2;
        g.fillStyle = warm ? `rgba(255,196,128,${(a * 0.3 * (1 - k / dashes)).toFixed(3)})` : `rgba(190,210,255,${(a * 0.24 * (1 - k / dashes)).toFixed(3)})`;
        g.fillRect(x + (rnd() - 0.5) * 3 - dw / 2 + sz / 2, dy, dw, 1 + rnd() * 0.8);
      }
    }
  }
  const mist = g.createLinearGradient(0, HZ - H * 0.04, 0, HZ + H * 0.06);
  mist.addColorStop(0, "rgba(120,140,200,0)"); mist.addColorStop(0.5, "rgba(120,140,200,0.10)"); mist.addColorStop(1, "rgba(120,140,200,0)");
  g.fillStyle = mist; g.fillRect(0, HZ - H * 0.04, W, H * 0.1);
  return { cv, moonU: mx / W, moonV: my / H, towns, shoreV: (HZ + H * 0.0155) / H };
}

// What shiny things reflect: a dark room, the night window in front, warm
// lamps on the left and the skylight above (equirectangular; front = u 0.25).
function paintEnv() {
  const W = 1024, H = 512, cv = document.createElement("canvas");
  cv.width = W; cv.height = H;
  const g = cv.getContext("2d");
  g.fillStyle = "#07090f"; g.fillRect(0, 0, W, H);
  const x0 = W * 0.06, x1 = W * 0.47;
  const sky = g.createLinearGradient(0, H * 0.18, 0, H * 0.5);
  sky.addColorStop(0, "#0b1230"); sky.addColorStop(1, "#2a3a6c");
  g.fillStyle = sky; g.fillRect(x0, H * 0.18, x1 - x0, H * 0.32);
  g.fillStyle = "#0c1328"; g.fillRect(x0, H * 0.5, x1 - x0, H * 0.04);
  g.fillStyle = "rgba(255,205,140,0.9)"; g.fillRect(x0, H * 0.545, x1 - x0, 3);
  const blob = (x, y, r, c) => { const gr = g.createRadialGradient(x, y, 0, x, y, r); gr.addColorStop(0, c); gr.addColorStop(1, "rgba(0,0,0,0)"); g.fillStyle = gr; g.fillRect(x - r, y - r, r * 2, r * 2); };
  blob(W * 0.27, H * 0.22, 40, "rgba(225,232,255,0.9)");   // moon
  blob(W * 0.985, H * 0.56, 60, "rgba(255,205,140,0.95)"); // ball lamp, left wall
  blob(W * 0.015, H * 0.56, 60, "rgba(255,205,140,0.95)");
  blob(W * 0.9, H * 0.6, 42, "rgba(255,210,150,0.8)");     // side table lamp
  blob(W * 0.25, H * 0.02, 120, "rgba(70,95,170,0.55)");   // skylight
  return cv;
}

// ---------------------------------------------------------------- speed meter and quality (developer diagnostics)
const perf = { firstFrame: 0, texturesReady: 0, textureMode: "", meshes: [0, 0], draws: 0, tris: 0, frames: 0,
  prev: 0, recent: [], idle: { n: 0, t: 0 }, active: { n: 0, t: 0 }, sec: { start: 0, n: 0 }, worstActiveFps: Infinity, steps: 0,
  lastAction: "start", hitches: [], hitchCount: 0, longest: 0, byState: {}, stepNotes: [], touch: { n: 0, t: 0 }, touchMoves: 0, touchTime: 0 };
// What is on screen while something moves, so the report can split fps by situation.
const situation = () => [S.mode === "stereo2" ? "2.0" : S.motion === "orbit" ? "Point, Orbit" : "Point",
  dragging === "source" ? "dragging the sound" : dragging === "look" || dragging === "pinch" ? "turning the room" : null,
  isOpen($("pop")) ? `${S.panel} panel open` : null,
  cam.tK > 0.5 ? "top view" : null, entrance ? "opening move" : null, document.body.classList.contains("noblur") ? "solid glass" : null, bench ? "speed test" : null].filter(Boolean).join(" + ");
// What the person did last, so the report can say what each freeze followed.
const act = (label) => { perf.lastAction = label; };
const quality = { setting: "auto", effective: "full", ratio: 1, maxRatio: 1, lastAdapt: 0, activeTimes: [] };
function perfTick(now, active) {
  perf.frames++;
  const gap = perf.prev ? now - perf.prev : 0;
  perf.prev = now;
  if (bench && bench.on && gap) bench.gaps.push(gap);
  if (gap > 100 && perf.firstFrame && perf.frames > perf.firstIndex + 1) { // the first draw is reported on its own
    perf.hitchCount++; perf.longest = Math.max(perf.longest, gap);
    perf.hitches.push(`${Math.round(gap)} ms after ${perf.lastAction}`); if (perf.hitches.length > 6) perf.hitches.shift();
  }
  if (!gap || gap > 250) return;
  perf.recent.push(gap); if (perf.recent.length > 60) perf.recent.shift();
  const bucket = active ? perf.active : perf.idle; bucket.n++; bucket.t += gap;
  if (active) { const k = situation(), b = perf.byState[k] || (perf.byState[k] = { n: 0, t: 0 }); b.n++; b.t += gap; }
  if (active) {
    // the worst one-second stretch while something moves
    if (!perf.sec.start) perf.sec = { start: now, n: 0 };
    perf.sec.n++;
    if (now - perf.sec.start >= 1000) { perf.worstActiveFps = Math.min(perf.worstActiveFps, (perf.sec.n * 1000) / (now - perf.sec.start)); perf.sec = { start: now, n: 0 }; }
    adapt(now, gap);
  } else perf.sec.start = 0;
}
// Adaptive resolution: step the pixel ratio down while frames take > 20 ms,
// back up after a long stretch under 11 ms. Auto falls back to the light room.
const ratioSteps = () => [quality.maxRatio, 1.25, 1].filter((r, i, a) => r <= quality.maxRatio && a.indexOf(r) === i);
function setRatio(r) { if (!three || r === quality.ratio) return; quality.ratio = r; three.renderer.setPixelRatio(r); measure(); }
function adapt(now, gap) {
  if (!three || quality.setting === "full") return;
  // the opening is not the device's pace: no resolution changes during it
  if (entrance || (perf.texturesReady && performance.now() - perf.texturesReady < 1500)) { quality.activeTimes.length = 0; return; }
  const a = quality.activeTimes; a.push(gap); if (a.length > 60) a.shift();
  if (a.length < 45 || now - quality.lastAdapt < 2000) return;
  const avg = [...a].sort((x, y) => x - y)[a.length >> 1]; // the median: a one-off freeze is not a slow device
  const steps = ratioSteps(), i = steps.indexOf(quality.ratio);
  if (avg > 20) {
    if (i >= 0 && i < steps.length - 1) { setRatio(steps[i + 1]); perf.steps++; perf.stepNotes.push(`${avg.toFixed(0)} ms frames during "${situation()}"`); if (perf.stepNotes.length > 3) perf.stepNotes.shift(); }
    else if (quality.setting === "auto" && quality.effective === "full") { applyQuality("light"); perf.stepNotes.push(`switched to Light room during "${situation()}"`); }
    quality.lastAdapt = now; a.length = 0;
  } else if (avg < 11 && i > 0 && now - quality.lastAdapt > 8000) { setRatio(steps[i - 1]); quality.lastAdapt = now; a.length = 0; }
}
// Light room: no floor reflection and no glow pass.
function applyQuality(eff) {
  quality.effective = eff;
  if (three) {
    const light = eff === "light";
    if (three.mirror) three.mirror.visible = !light;
    const fm = three.floorFinish.material;
    fm.transparent = !!three.mirror && !light; fm.needsUpdate = true;
  }
  renderMeter();
}
function renderMeter() {
  const el = $("fps");
  if (!el || el.hidden) return;
  const r = perf.recent, avg = r.length ? r.reduce((t, x) => t + x, 0) / r.length : 0;
  el.textContent = `${avg ? (1000 / avg).toFixed(0) : "–"} fps  ${avg ? avg.toFixed(1) : "–"} ms  ${isActive() ? "moving" : "idle (30 cap)"}\n${perf.draws} draws  ${(perf.tris / 1000).toFixed(0)}k tris  ${quality.ratio}x  ${quality.effective}${quality.setting === "auto" ? " (auto)" : ""}`;
}
setInterval(renderMeter, 500);
function speedReport() {
  const ua = navigator.userAgent;
  const ipad = /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  const os = (ua.match(/OS (\d+[_\d]*) like/) || ua.match(/Version\/([\d.]+)/) || [])[1];
  let gpu = "";
  try { const gl = three.renderer.getContext(), ext = gl.getExtension("WEBGL_debug_renderer_info"); gpu = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER); } catch (e) { gpu = ""; }
  const fps = (b) => (b.n ? (1000 / (b.t / b.n)).toFixed(1) : "–");
  return [
    "Yinwei Listen Room — speed report",
    `Device: ${ipad ? "iPad" : /iPhone/.test(ua) ? "iPhone" : navigator.platform}${os ? " · OS " + os.replace(/_/g, ".") : ""} · screen ${screen.width}×${screen.height} @${devicePixelRatio}x · window ${innerWidth}×${innerHeight}`,
    `GPU: ${gpu || "unknown"}`,
    `First room frame: ${perf.firstDone ? Math.round(perf.firstDone) + " ms" : "–"} after load · detailed textures ready: ${perf.texturesReady ? Math.round(perf.texturesReady) + " ms" : "not yet"} (${perf.textureMode || "–"})`,
    `Start: page and three.js loaded ${Math.round(t0Script)} ms · room built ${perf.built ? Math.round(perf.built) + " ms" : "–"} · first frame drawn ${perf.firstDone && perf.built ? Math.round(perf.firstDone - perf.built) + " ms later" : "–"}`,
    `Idle (30 fps cap): ${fps(perf.idle)} fps over ${perf.idle.n} frames`,
    `Moving (drag, orbit, camera): ${fps(perf.active)} fps over ${perf.active.n} frames · worst second ${isFinite(perf.worstActiveFps) ? perf.worstActiveFps.toFixed(0) : "–"} fps`,
    ...Object.entries(perf.byState).filter(([, b]) => b.n >= 20).sort((a, b) => b[1].n - a[1].n).slice(0, 8).map(([k, b]) => `  · ${k}: ${fps(b)} fps (${b.n} frames)`),
    `Resolution: ${quality.ratio}x of max ${quality.maxRatio}x (stepped down ${perf.steps}×${perf.stepNotes.length ? ": " + perf.stepNotes.join("; ") : ""}) · room ${quality.effective} (${quality.setting})`,
    `Touch response: ${perf.touch.n ? (perf.touch.t / perf.touch.n).toFixed(0) + " ms from finger move to frame" : "–"} · finger updates ${perf.touchTime > 0.5 ? Math.round(perf.touchMoves / perf.touchTime) + " a second" : "–"}`,
    `Freezes over 100 ms: ${perf.hitchCount}${perf.hitchCount ? ` (longest ${Math.round(perf.longest)} ms) · last: ${perf.hitches.join(" · ")}` : ""}`,
    `Speed test: ${perf.bench || "not run (YinweiListen.speedTest())"}`,
    `Shaders and drawing setups prepared up front: ${perf.compiled ? Math.round(perf.compiled) + " ms" : "not yet"}`,
    `Per frame: ${perf.draws} draw calls · ${(perf.tris / 1000).toFixed(0)}k triangles · ${perf.meshes[1]} meshes (${perf.meshes[0]} before merging) · glow buffers ${perf.hdr ? "half-float" : "8-bit"}`,
    `Speakers: ${S.speakers.length} · fixed pool ${three ? three.speakerFx.length : 0} · cabinet shadow casters limited to L/R · GPU geometries ${three ? three.renderer.info.memory.geometries : 0}`,
  ].join("\n");
}

// Developer diagnostics (YinweiListen.speedTest): a fixed speed test. It turns
// the room the same way on every run, in three setups (full quality at full and
// lower sharpness, then the Light room), so runs compare cleanly; a warm device
// shows up as a lower score. Resolves with the result line of the speed report.
async function runSpeedTest() {
  if (!three || bench) return perf.bench || "";
  closeMenus(); closePop();
  const saved = { setting: quality.setting, eff: quality.effective, ratio: quality.ratio, yaw: cam.tYaw, lift: cam.tLift, zoom: cam.tZoom, k: cam.tK };
  Object.assign(cam, { tK: 0, tZoom: 1, tLift: LIFT_3D }); quality.setting = "full"; // no adapting while measuring
  const sleep = (t) => new Promise((r) => setTimeout(r, t));
  const run = async (eff, ratio) => {
    applyQuality(eff); setRatio(ratio);
    bench = { on: false, gaps: [], t0: 0 }; await sleep(400); // settle after the switch
    bench.on = true; bench.t0 = performance.now(); await sleep(2400); bench.on = false;
    const g = bench.gaps.slice().sort((a, b) => a - b);
    return g.length ? Math.round(1000 / g[g.length >> 1]) : 0;
  };
  const maxR = quality.maxRatio, midR = Math.min(1.25, maxR);
  const full = await run("full", maxR), fullMid = await run("full", midR), light = await run("light", maxR);
  bench = null;
  perf.bench = `full ${maxR}x ${full} fps · full ${midR}x ${fullMid} fps · light ${maxR}x ${light} fps (typical frame, turning the room)`;
  quality.setting = saved.setting; applyQuality(saved.eff); setRatio(saved.ratio);
  Object.assign(cam, { tYaw: saved.yaw, tLift: saved.lift, tZoom: saved.zoom, tK: saved.k });
  return perf.bench;
}

// ---------------------------------------------------------------- procedural surfaces
// Colour, roughness, relief (normal) and alpha maps as raw pixels, drawn from
// tileable value noise. Self-contained (Math only), so it runs in a Web
// Worker and the room never freezes while the detailed surfaces build.
function texKit() {
  const noise2 = (seed, P = 64) => {
    let q = seed;
    const r = () => ((q = (q * 16807) % 2147483647) / 2147483647);
    const g = new Float32Array(P * P);
    for (let i = 0; i < g.length; i++) g[i] = r();
    return (x, y) => {
      const xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi;
      const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
      const i0 = ((xi % P) + P) % P, j0 = ((yi % P) + P) % P, i1 = (i0 + 1) % P, j1 = (j0 + 1) % P;
      const a = g[j0 * P + i0], b = g[j0 * P + i1], c = g[j1 * P + i0], d = g[j1 * P + i1];
      return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
    };
  };
  const fbm = (n, x, y, oct) => { let t = 0, a = 0.5, f = 1; for (let o = 0; o < oct; o++) { t += a * n(x * f, y * f); a *= 0.5; f *= 2; } return t / (1 - Math.pow(0.5, oct)); };
  const nA = noise2(3), nB = noise2(17), nC = noise2(29), nD = noise2(41, 128);
  const mixc = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
  const surface = (S, fn, strength, repeat, withAlpha) => {
    const Hh = new Float32Array(S * S);
    const color = new Uint8ClampedArray(S * S * 4), rough = new Uint8ClampedArray(S * S * 4), normal = new Uint8ClampedArray(S * S * 4);
    const alpha = withAlpha ? new Uint8ClampedArray(S * S * 4) : null;
    for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
      const o = fn(x / S, y / S), i = y * S + x, k = i * 4;
      Hh[i] = o.h;
      color[k] = o.c[0]; color[k + 1] = o.c[1]; color[k + 2] = o.c[2]; color[k + 3] = 255;
      rough[k] = rough[k + 1] = rough[k + 2] = o.r * 255; rough[k + 3] = 255;
      if (alpha) { alpha[k] = alpha[k + 1] = alpha[k + 2] = o.a * 255; alpha[k + 3] = 255; }
    }
    for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
      const k = (y * S + x) * 4;
      const hx = Hh[y * S + (x + 1) % S] - Hh[y * S + (x - 1 + S) % S];
      const hy = Hh[((y + 1) % S) * S + x] - Hh[((y - 1 + S) % S) * S + x];
      const nx = -hx * strength, ny = hy * strength, l = Math.hypot(nx, ny, 1);
      normal[k] = (nx / l * 0.5 + 0.5) * 255; normal[k + 1] = (ny / l * 0.5 + 0.5) * 255; normal[k + 2] = (1 / l * 0.5 + 0.5) * 255; normal[k + 3] = 255;
    }
    return { S, repeat, color: color.buffer, rough: rough.buffer, normal: normal.buffer, alpha: alpha ? alpha.buffer : null };
  };
  return {
    // Dark stone floor: large tiles, soft veins, recessed grout. Alpha lets the
    // mirror show through polished stone but not through the grout.
    stone: () => surface(768, (u, v) => {
      const tu = u * 2, tv = v * 2, ti = Math.floor(tu), tj = Math.floor(tv), fu = tu - ti, fv = tv - tj;
      const grout = Math.min(fu, fv, 1 - fu, 1 - fv) < 0.004;
      const tint = [0, 0.07, -0.05, 0.03][(ti + tj * 2) % 4];
      const fine = fbm(nB, u * 512, v * 512, 2);
      const vein = Math.abs(Math.sin((u * 5 + v * 2 + fbm(nC, u * 192, v * 192, 3) * 2.4) * Math.PI * 2));
      let c = [30 + fine * 16, 33 + fine * 16, 40 + fine * 18].map((k) => k * (1 + tint));
      if (vein < 0.04) c = mixc(c, [92, 98, 114], ((0.04 - vein) / 0.04) * 0.45);
      if (grout) c = [11, 12, 15];
      return { h: grout ? 0 : 0.5, c, r: grout ? 0.95 : 0.18 + fine * 0.16, a: grout ? 1 : 0.6 + fine * 0.14 };
    }, 30, [3.2, 3.2], true),
    // Leather: pebbled grain, a groove and a stitched seam inside every panel edge.
    leather: () => surface(512, (u, v) => {
      const cell = 1 - Math.abs(nA(u * 128, v * 128) * 2 - 1);
      const grain = Math.pow(cell, 3) * 0.6 + fbm(nB, u * 256, v * 256, 2) * 0.4;
      const e = Math.min(u, v, 1 - u, 1 - v);
      const along = e === u || e === 1 - u ? v : u;
      const groove = Math.abs(e - 0.05) < 0.004;
      const stitch = Math.abs(e - 0.068) < 0.0035 && Math.floor(along * 110) % 2 === 0;
      let c = [20, 21, 26].map((k) => k * (0.85 + grain * 0.35));
      if (stitch) c = [64, 66, 74];
      return { h: grain * 0.25 - (groove ? 0.5 : 0) + (stitch ? 0.3 : 0), c, r: stitch ? 0.7 : groove ? 0.6 : 0.34 + (1 - grain) * 0.22 };
    }, 9, [1, 1]),
    // Walnut veneer: long grain, wavy figure and open pores.
    walnut: () => surface(512, (u, v) => {
      const figure = 0.5 + 0.5 * Math.sin((v * 22 + fbm(nC, u * 64, v * 128, 3) * 3) * Math.PI);
      const streak = fbm(nA, u * 64, v * 512, 3);
      const pore = nD(u * 128, v * 1024) > 0.84 ? 1 : 0;
      const c = mixc([38, 27, 21], [76, 54, 39], figure * 0.45 + streak * 0.35 + 0.1).map((k) => k * (pore ? 0.82 : 1));
      return { h: streak * 0.3 + figure * 0.1 - pore * 0.25, c, r: 0.36 + (1 - figure) * 0.1 + pore * 0.2 };
    }, 5, [1, 1]),
    // Wool rug: fine fibres, soft heathered colour, a darker woven border.
    rug: () => surface(512, (u, v) => {
      const rr = Math.hypot(u - 0.5, v - 0.5);
      const fib = nD(u * 256, v * 256), heather = fbm(nB, u * 64, v * 64, 3);
      const band = rr > 0.425 && rr < 0.46;
      let c = mixc([82, 85, 93], [122, 124, 132], heather * 0.7 + fib * 0.3);
      if (band) c = c.map((k) => k * 0.6);
      return { h: fib * 0.35 + heather * 0.1 - (band ? 0.05 : 0), c, r: 0.92 + fib * 0.08 };
    }, 3, [1, 1]),
    plaster: () => surface(256, (u, v) => { const f = fbm(nB, u * 128, v * 128, 4); return { h: f, c: [27 + f * 10, 30 + f * 10, 37 + f * 12], r: 0.82 + f * 0.14 }; }, 3, [4, 4]),
    brushed: () => surface(256, (u, v) => { const f = fbm(nA, u * 64, v * 512, 3); return { h: f * 0.2, c: [150 + f * 24, 155 + f * 24, 164 + f * 24], r: 0.14 + f * 0.2 }; }, 2, [1, 3]),
    satin: () => surface(128, (u, v) => { const f = fbm(nB, u * 128, v * 128, 2); return { h: f * 0.08, c: [17 + f * 6, 18 + f * 6, 23 + f * 7], r: 0.26 + f * 0.12 }; }, 1, [3, 3]),
    ceramic: () => surface(128, (u, v) => { const f = fbm(nB, u * 64, v * 64, 2), sp = nD(u * 256, v * 256) > 0.87; return { h: f * 0.1, c: sp ? [126, 118, 106] : [203 + f * 8, 197 + f * 8, 186 + f * 8], r: 0.24 + f * 0.1 }; }, 1, [2, 1]),
    ceramicDark: () => surface(128, (u, v) => { const f = fbm(nB, u * 64, v * 64, 2), sp = nD(u * 256, v * 256) > 0.87; return { h: f * 0.1, c: sp ? [96, 98, 106] : [42 + f * 10, 45 + f * 10, 53 + f * 12], r: 0.22 + f * 0.12 }; }, 1, [2, 1]),
    bark: () => surface(128, (u, v) => { const f = Math.abs(fbm(nC, u * 128, v * 64, 4) * 2 - 1); return { h: f, c: [56 + f * 34, 45 + f * 26, 36 + f * 20], r: 0.9 }; }, 6, [2, 6]),
  };
}

// Build every surface, most visible first, in a Web Worker when possible.
function startSurfaces(apply) {
  const names = ["stone", "leather", "walnut", "rug", "plaster", "brushed", "satin", "ceramic", "ceramicDark", "bark"];
  const done = new Set();
  const finish = (name, px) => {
    if (done.has(name)) return;
    done.add(name);
    act(`texture ${name}`);
    apply(name, px);
    if (done.size === names.length) { perf.texturesReady = performance.now(); perf.texturesFrame = perf.frames; act("textures arrived"); }
  };
  const onMainThread = () => {
    const kit = texKit();
    const next = () => { const name = names.find((n) => !done.has(n)); if (!name) return; finish(name, kit[name]()); setTimeout(next, 30); };
    setTimeout(next, 30);
  };
  let worker = null;
  try {
    const src = `const kit = (${texKit.toString()})();
self.onmessage = (e) => { const px = kit[e.data](); self.postMessage({ name: e.data, px }, [px.color, px.rough, px.normal].concat(px.alpha ? [px.alpha] : [])); };`;
    worker = new Worker(URL.createObjectURL(new Blob([src], { type: "text/javascript" })));
  } catch (e) {
    worker = null;
  }
  if (!worker) { perf.textureMode = "main thread"; onMainThread(); return; }
  perf.textureMode = "worker";
  worker.onmessage = (e) => { finish(e.data.name, e.data.px); if (done.size === names.length) worker.terminate(); };
  worker.onerror = () => { worker.terminate(); perf.textureMode = "main thread (worker failed)"; onMainThread(); };
  names.forEach((n) => worker.postMessage(n));
}

function buildScene() {
  const T = window.THREE;
  if (!T) throw new Error("three.js missing");
  const renderer = new T.WebGLRenderer({ canvas: $("gl"), antialias: true, powerPreference: "high-performance" });
  quality.maxRatio = quality.ratio = Math.min(devicePixelRatio || 1, 1.75);
  renderer.setPixelRatio(quality.ratio);
  renderer.outputEncoding = T.sRGBEncoding;
  renderer.toneMapping = T.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.35;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = T.PCFSoftShadowMap;
  renderer.shadowMap.autoUpdate = false; // drawn once; redrawn only when something that casts shadows changes
  renderer.info.autoReset = false;       // counted per frame, across reflection, scene and glow passes
  const col = (hex) => new T.Color(hex).convertSRGBToLinear();
  const scene = new T.Scene();
  scene.background = col("#05070d");
  scene.fog = new T.FogExp2(col("#070a14"), 0.028);
  const camera = new T.PerspectiveCamera(44, 1, 0.05, 120);

  // Reflections: everything glossy picks up the room and the window.
  const pmrem = new T.PMREMGenerator(renderer);
  const envSrc = new T.CanvasTexture(paintEnv());
  envSrc.mapping = T.EquirectangularReflectionMapping;
  envSrc.encoding = T.sRGBEncoding;
  scene.environment = pmrem.fromEquirectangular(envSrc).texture;
  envSrc.dispose(); pmrem.dispose();

  const canvasTex = (w, h, paint, repeat) => {
    const c = document.createElement("canvas"); c.width = w; c.height = h;
    paint(c.getContext("2d"), w, h);
    const t = new T.CanvasTexture(c);
    t.encoding = T.sRGBEncoding;
    if (repeat) { t.wrapS = t.wrapT = T.RepeatWrapping; t.repeat.set(repeat, repeat); }
    t.anisotropy = renderer.capabilities.getMaxAnisotropy();
    return t;
  };
  let nseed = 11;
  const nr = () => ((nseed = (nseed * 16807) % 2147483647) / 2147483647);
  const skyTex = canvasTex(512, 512, (g, w, h) => {
    const gr = g.createRadialGradient(w / 2, h / 2, 0, w / 2, h / 2, w / 2);
    gr.addColorStop(0, "#1a2754"); gr.addColorStop(1, "#0a1026");
    g.fillStyle = gr; g.fillRect(0, 0, w, h);
    for (let i = 0; i < 500; i++) { g.fillStyle = `rgba(225,233,255,${(0.3 + nr() * 0.7).toFixed(2)})`; const s = nr() > 0.97 ? 2 : 1; g.fillRect(nr() * w, nr() * h, s, s); }
  });

  const std = (o) => new T.MeshStandardMaterial(Object.assign({ envMapIntensity: 0.8 }, o, o.color ? { color: col(o.color) } : {}));
  const glowCache = new Map();
  const glow = (hex, intensity = 1) => {
    const k = `${hex}|${intensity}`;
    if (!glowCache.has(k)) glowCache.set(k, new T.MeshStandardMaterial({ color: col("#000000"), emissive: col(hex), emissiveIntensity: intensity, roughness: 1 }));
    return glowCache.get(k);
  };
  const M = {
    leather: std({ color: "#15161b", roughness: 0.36, envMapIntensity: 1.1 }),
    walnut: std({ color: "#5a3d2b", roughness: 0.42, envMapIntensity: 0.9 }),
    alu: std({ color: "#9aa0aa", roughness: 0.22, metalness: 0.95, envMapIntensity: 1.4 }),
    blackMetal: std({ color: "#15171c", roughness: 0.3, metalness: 0.8, envMapIntensity: 1.2 }),
    brass: std({ color: "#b48d55", roughness: 0.3, metalness: 1, envMapIntensity: 1.4 }),
    satin: std({ color: "#121318", roughness: 0.32, metalness: 0.15, envMapIntensity: 1.2 }),
    cone: std({ color: "#1e2026", roughness: 0.85, side: T.DoubleSide }),
    rubber: std({ color: "#0d0e11", roughness: 0.95 }),
    wall: std({ color: "#1d2028", roughness: 0.92 }),
    ceiling: std({ color: "#0c0f16", roughness: 0.9, side: T.DoubleSide }),
    glossy: std({ color: "#0d0e12", roughness: 0.12, metalness: 0.4, envMapIntensity: 1.6 }),
    ceramic: std({ color: "#c9c3b8", roughness: 0.35, envMapIntensity: 1 }),
    ceramicDark: std({ color: "#2d3038", roughness: 0.3, envMapIntensity: 1.1 }),
    stone: std({ color: "#25231f", roughness: 0.95, flatShading: true }),
    bark: std({ color: "#3b3027", roughness: 0.95 }),
    leaf: std({ color: "#2b3a2c", roughness: 0.6, side: T.DoubleSide, envMapIntensity: 0.5 }),
    book: std({ color: "#6b5a43", roughness: 0.8 }),
    book2: std({ color: "#2f3542", roughness: 0.8 }),
    glass: new T.MeshStandardMaterial({ color: col("#a9bbff"), roughness: 0.22, metalness: 1, transparent: true, opacity: 0.025, depthWrite: false, envMapIntensity: 0.18 }), // faint, soft reflection: no repeated glare per pane
  };
  const add = (geo, mat, pos, rot, opts = {}) => {
    const m = new T.Mesh(geo, mat);
    if (pos) m.position.set(...pos);
    if (rot) m.rotation.set(...rot);
    m.castShadow = opts.cast !== false; m.receiveShadow = opts.receive !== false;
    (opts.to || scene).add(m);
    return m;
  };
  const rbox = (w, h, d, r, seg = 4) => (T.RoundedBoxGeometry ? new T.RoundedBoxGeometry(w, h, d, seg, r) : new T.BoxGeometry(w, h, d));
  const lathe = (pts, seg = 48) => new T.LatheGeometry(pts.map(([r, y]) => new T.Vector2(r, y)), seg);
  // Curve a slab around the vertical axis so its sides wrap forward (-Z).
  const bend = (geo, R) => {
    const p = geo.attributes.position;
    for (let i = 0; i < p.count; i++) {
      const x = p.getX(i), z = p.getZ(i), a = x / R;
      p.setXYZ(i, (R + z) * Math.sin(a), p.getY(i), (R + z) * Math.cos(a) - R);
    }
    geo.computeVertexNormals();
    return geo;
  };
  // A soft slab in the XY plane: a rounded-corner outline whose thickness (Z)
  // rolls off at the edge. High "edge" gives a crisp wooden shell, low "edge"
  // a filled leather cushion. Vertices pack toward the edge so the roll is smooth.
  const outlineHalf = (w, h, rTop, rBot) => (y) => {
    const top = h / 2 - rTop, bot = -h / 2 + rBot;
    let hw = w / 2;
    if (y > top) hw += -rTop + Math.sqrt(Math.max(0, rTop * rTop - (y - top) ** 2));
    else if (y < bot) hw += -rBot + Math.sqrt(Math.max(0, rBot * rBot - (y - bot) ** 2));
    return Math.max(hw, 1e-4);
  };
  const pillow = (w, h, d, { rTop = 0.1, rBot = 0.1, edge = 6, dome = 0, n = 28 } = {}) => {
    const half = outlineHalf(w, h, rTop, rBot);
    const dense = (k) => { const q = (k / n) * 2 - 1; return Math.sign(q) * Math.sin((Math.abs(q) * Math.PI) / 2); };
    const pos = [], uv = [], idx = [], N = n + 1;
    let front = null;
    for (const side of [1, -1]) {
      const at = []; // grid cell -> vertex index; the back face reuses the front's rim vertices
      for (let j = 0; j <= n; j++) {
        const sv = dense(j), y = (sv * h) / 2;
        for (let i = 0; i <= n; i++) {
          const k = j * N + i;
          if (front && (i === 0 || i === n || j === 0 || j === n)) { at[k] = front[k]; continue; }
          const su = dense(i), e = Math.max(Math.abs(su), Math.abs(sv));
          const t = Math.sqrt(Math.max(0, 1 - Math.pow(e, edge))) * (1 - dome * e * e);
          at[k] = pos.length / 3;
          pos.push(su * half(y), y, (side * t * d) / 2);
          uv.push((su + 1) / 2, (sv + 1) / 2);
        }
      }
      for (let j = 0; j < n; j++) for (let i = 0; i < n; i++) {
        const a = at[j * N + i], b = at[j * N + i + 1], c = at[(j + 1) * N + i], dd = at[(j + 1) * N + i + 1];
        if (side > 0) idx.push(a, b, dd, a, dd, c); else idx.push(a, dd, b, a, c, dd);
      }
      front = at;
    }
    const g = new T.BufferGeometry();
    g.setAttribute("position", new T.Float32BufferAttribute(pos, 3));
    g.setAttribute("uv", new T.Float32BufferAttribute(uv, 2));
    g.setIndex(idx);
    g.computeVertexNormals(); // shared rim vertices: smooth across the edge
    return g;
  };
  // The same outline as a closed curve (for piping), bent like the slab when R > 0.
  const outlinePts = (w, h, rTop, rBot, R, count = 120) => {
    const half = outlineHalf(w, h, rTop, rBot), inside = (x, y) => Math.abs(y) <= h / 2 && Math.abs(x) <= half(y);
    const pts = [];
    for (let k = 0; k < count; k++) {
      const th = (k / count) * Math.PI * 2, dx = (Math.cos(th) * w) / 2, dy = (Math.sin(th) * h) / 2;
      let lo = 0, hi = 1.5;
      for (let it = 0; it < 24; it++) { const m = (lo + hi) / 2; if (inside(dx * m, dy * m)) lo = m; else hi = m; }
      const x = dx * lo, y = dy * lo;
      pts.push(R ? new T.Vector3(R * Math.sin(x / R), y, R * Math.cos(x / R) - R) : new T.Vector3(x, y, 0));
    }
    return pts;
  };
  const limb = (a, b, r, mat, to) => {
    const A = new T.Vector3(...a), B = new T.Vector3(...b);
    const m = add(new T.CylinderGeometry(r, r, A.distanceTo(B), 16), mat, null, null, { to });
    m.position.copy(A).add(B).multiplyScalar(0.5);
    m.quaternion.setFromUnitVectors(new T.Vector3(0, 1, 0), B.clone().sub(A).normalize());
    return m;
  };
  const softTex = (inner, outer) => canvasTex(256, 256, (g, w) => { const gr = g.createRadialGradient(w / 2, w / 2, 0, w / 2, w / 2, w / 2); gr.addColorStop(0, inner); gr.addColorStop(1, outer); g.fillStyle = gr; g.fillRect(0, 0, w, w); });
  const blueSoft = softTex("rgba(140,175,255,1)", "rgba(140,175,255,0)");

  // ---------------------------------------------------------------- outside
  const nightPaint = paintNight();
  const night = new T.CanvasTexture(nightPaint.cv);
  night.encoding = T.sRGBEncoding;
  night.anisotropy = renderer.capabilities.getMaxAnisotropy();
  const PANO_R = 46, PANO_Y = 6.6, PANO_H = 30;
  const sky = new T.Mesh(new T.CylinderGeometry(PANO_R, PANO_R, PANO_H, 128, 1, true), new T.MeshBasicMaterial({ map: night, side: T.BackSide, fog: false }));
  sky.position.y = PANO_Y;
  scene.add(sky);
  // Where the painted moon sits (cylinder UV: x = R sin θ, z = R cos θ, θ = u · 2π).
  const moonTheta = nightPaint.moonU * Math.PI * 2;
  const moonDir = new T.Vector3(PANO_R * Math.sin(moonTheta), PANO_Y + PANO_H / 2 - nightPaint.moonV * PANO_H, PANO_R * Math.cos(moonTheta)).normalize();
  const moonTex = canvasTex(128, 128, (g2, w) => {
    const disc = g2.createRadialGradient(w * 0.42, w * 0.42, w * 0.05, w / 2, w / 2, w * 0.46);
    disc.addColorStop(0, "#ffffff"); disc.addColorStop(0.85, "#e3e8f6"); disc.addColorStop(1, "#cfd6ea");
    g2.fillStyle = disc; g2.beginPath(); g2.arc(w / 2, w / 2, w * 0.46, 0, Math.PI * 2); g2.fill();
    g2.fillStyle = "rgba(150,160,190,0.28)";
    for (const [x, y, r] of [[0.4, 0.38, 0.12], [0.62, 0.55, 0.09], [0.47, 0.66, 0.07], [0.66, 0.33, 0.05], [0.3, 0.58, 0.05]]) { g2.beginPath(); g2.arc(x * w, y * w, r * w, 0, Math.PI * 2); g2.fill(); }
  });
  const moonGlowTex = canvasTex(128, 128, (g2, w) => { const gr = g2.createRadialGradient(w / 2, w / 2, 0, w / 2, w / 2, w / 2); gr.addColorStop(0, "rgba(200,215,255,0.55)"); gr.addColorStop(0.25, "rgba(170,190,255,0.16)"); gr.addColorStop(1, "rgba(150,170,255,0)"); g2.fillStyle = gr; g2.fillRect(0, 0, w, w); });
  const moonAt = moonDir.clone().multiplyScalar(PANO_R - 1.5);
  const moonGlow = new T.Sprite(new T.SpriteMaterial({ map: moonGlowTex, transparent: true, depthWrite: false, blending: T.AdditiveBlending, fog: false }));
  moonGlow.position.copy(moonAt); moonGlow.scale.set(14, 14, 1); scene.add(moonGlow);
  const moonDisc = new T.Sprite(new T.SpriteMaterial({ map: moonTex, transparent: true, depthWrite: false, fog: false }));
  moonDisc.position.copy(moonAt); moonDisc.scale.set(1.9, 1.9, 1); scene.add(moonDisc);

  // A stone deck outside the window, stepping down to the lake.
  const DECK_R = 9.6, WATER_Y = -0.55;
  const deck = add(new T.CircleGeometry(DECK_R, 128), std({ color: "#0f1218", roughness: 0.8, envMapIntensity: 0.4 }), [0, -0.02, 0], [-Math.PI / 2, 0, 0], { cast: false });
  add(new T.CylinderGeometry(DECK_R, DECK_R, -WATER_Y, 128, 1, true), std({ color: "#0b0d12", roughness: 0.9, side: T.DoubleSide }), [0, WATER_Y / 2 - 0.01, 0], null, { cast: false });
  // small warm path lights along the deck edge
  for (let a = -48; a <= 62; a += 22) {
    const r = DECK_R - 0.4, x = r * Math.sin(a * DEG), z = -r * Math.cos(a * DEG);
    add(new T.CylinderGeometry(0.035, 0.045, 0.32, 16), M.blackMetal, [x, 0.16, z]);
    add(new T.CylinderGeometry(0.03, 0.03, 0.04, 16), glow("#ffcf8f", 2.6), [x, 0.32, z], null, { cast: false });
  }
  // Smooth natural boulders: a sphere pushed in and out by layered waves.
  const boulderMat = std({ color: "#2c2b2c", roughness: 0.9, envMapIntensity: 0.3 });
  let unitRock = null; // merged once (merging is slow), then copied for each boulder
  const boulder = (k) => {
    if (!unitRock) {
      unitRock = new T.IcosahedronGeometry(1, 4);
      unitRock.deleteAttribute("normal"); unitRock.deleteAttribute("uv"); // merge by position only, for smooth shading
      if (T.BufferGeometryUtils) unitRock = T.BufferGeometryUtils.mergeVertices(unitRock);
    }
    const g = unitRock.clone();
    const p = g.attributes.position;
    for (let i = 0; i < p.count; i++) {
      const x = p.getX(i), y = p.getY(i), z = p.getZ(i);
      const n = 0.16 * Math.sin(x * 1.9 + k) * Math.sin(y * 2.3 + k * 2.1) * Math.sin(z * 1.7 + k * 0.7)
        + 0.07 * Math.sin(x * 4.3 + k * 3) * Math.sin(z * 3.9 - k) + 0.03 * Math.sin(y * 9 + x * 7 + k);
      const f = 1 + n;
      p.setXYZ(i, x * f, y * f * 0.62, z * f);
    }
    g.computeVertexNormals();
    return g;
  };
  [[-3.1, -8.5, 0.55, 0.12], [2.4, -8.8, 0.42, 0.1], [5.7, -7.0, 0.7, 0.15], [-0.9, -11.2, 0.6, WATER_Y + 0.1],
    [5.4, -10.1, 0.85, WATER_Y + 0.12], [-6.4, -9.1, 0.75, WATER_Y + 0.14], [9.2, -6.6, 0.55, WATER_Y + 0.08], [1.8, -13.5, 1.1, WATER_Y + 0.05]]
    .forEach(([x, z, sc, y], i) => { const b = add(boulder(i * 1.37 + 0.4), boulderMat, [x, y, z], [0, x * 1.7, 0]); b.scale.setScalar(sc); });

  // The lake: real water with moving ripples that reflects the painted sky,
  // mountains and moon, with the moon's glitter path. It fades into the
  // painted far lake at the horizon.
  const water = new T.Mesh(new T.RingGeometry(DECK_R - 0.05, PANO_R - 0.5, 192, 12), new T.ShaderMaterial({
    uniforms: { pano: { value: night }, time: { value: 0 }, moonDir: { value: moonDir }, panoBottom: { value: PANO_Y - PANO_H / 2 }, panoHeight: { value: PANO_H }, panoRadius: { value: PANO_R }, shoreY: { value: PANO_Y + PANO_H / 2 - nightPaint.shoreV * PANO_H }, deep: { value: col("#03060f") }, haze: { value: col("#141c36") } },
    extensions: { derivatives: true },
    vertexShader: [
      "varying vec3 vWorld;",
      "void main() { vec4 wp = modelMatrix * vec4(position, 1.0); vWorld = wp.xyz; gl_Position = projectionMatrix * viewMatrix * wp; }",
    ].join("\n"),
    fragmentShader: [
      "uniform sampler2D pano; uniform float time; uniform vec3 moonDir; uniform float panoBottom, panoHeight, panoRadius, shoreY; uniform vec3 deep, haze;",
      "varying vec3 vWorld;",
      // How far a ray from P along R travels to the painted panorama cylinder.
      "float panoDist(vec3 P, vec3 R) {",
      "  float a = max(dot(R.xz, R.xz), 1e-5), b = 2.0 * dot(P.xz, R.xz), c = dot(P.xz, P.xz) - panoRadius * panoRadius;",
      "  return (-b + sqrt(max(b * b - 4.0 * a * c, 0.0))) / (2.0 * a);",
      "}",
      "vec3 panoTex(vec2 xz, float y, float bias) {",
      "  vec2 uv = vec2(fract(atan(xz.x, xz.y) / 6.2831853), clamp((y - panoBottom) / panoHeight, 0.0, 1.0));",
      "  return sRGBToLinear(texture2D(pano, uv, bias)).rgb;",
      "}",
      // What you see straight along V (the painted far lake near the horizon).
      "vec3 panoAt(vec3 P, vec3 R) { float s = panoDist(P, R); vec3 h = P + R * s; return panoTex(h.xz, h.y, 0.0); }",
      // A reflection: the painting's far shore is the water line, so a ray that
      // climbs R.y over its run shows what stands that high above the shore.
      // The painted lake below the shore is never reflected again.
      "vec3 panoUp(vec3 P, vec3 R) { float s = panoDist(P, R); vec3 h = P + R * s; return panoTex(h.xz, shoreY + R.y * s, 1.6); }",
      "void main() {",
      "  vec3 V = normalize(vWorld - cameraPosition);",
      "  vec2 p = vWorld.xz; float t = time;",
      "  vec2 d1 = vec2(0.8, 0.6), d2 = vec2(-0.49, 0.87), d3 = vec2(0.2, -0.98), d4 = vec2(-0.96, -0.28);",
      // each ripple fades out once a pixel covers too much of its wavelength
      "  float fw = max(length(fwidth(p)), 1e-4);",
      "  vec4 lod = 1.0 - smoothstep(0.35, 1.4, fw * vec4(1.4, 2.3, 3.7, 6.1));",
      "  vec2 g = d1 * 0.036 * lod.x * cos(dot(d1, p) * 1.4 + t * 0.8) + d2 * 0.024 * lod.y * cos(dot(d2, p) * 2.3 + t * 1.1)",
      "         + d3 * 0.015 * lod.z * cos(dot(d3, p) * 3.7 + t * 1.5) + d4 * 0.009 * lod.w * cos(dot(d4, p) * 6.1 + t * 2.1);",
      "  float dist = length(p), far = clamp(dist / (panoRadius - 1.0), 0.0, 1.0);",
      "  g *= mix(1.0, 0.4, far);",
      "  vec3 n = normalize(vec3(-g.x, 1.0, -g.y));",
      "  vec3 R = reflect(V, n); R.y = abs(R.y);",
      "  vec3 refl = panoUp(vWorld, R);",
      "  float fres = 0.04 + 0.96 * pow(1.0 - clamp(dot(-V, n), 0.0, 1.0), 5.0);",
      "  vec3 col = mix(deep, refl, clamp(0.22 + fres, 0.0, 1.0));",
      "  vec3 Hh = normalize(moonDir - V);",
      // the moon's glitter: broken into small sparkles up close, a smooth path far away
      "  float sparkle = 0.5 + 0.5 * sin(p.x * 9.0 + t * 1.7) * sin(p.y * 11.0 - t * 1.3);",
      "  sparkle = mix(1.0, smoothstep(0.35, 0.95, sparkle), 1.0 - smoothstep(0.35, 1.4, fw * 11.0));",
      "  col += vec3(0.9, 0.93, 1.0) * pow(clamp(dot(n, Hh), 0.0, 1.0), 1100.0) * 1.5 * sparkle;",
      // a smooth evening haze settles over the far water, then the painted lake takes over
      "  col = mix(col, haze, smoothstep(9.0, 40.0, dist) * 0.22);",
      "  col = mix(col, panoAt(cameraPosition, V), smoothstep(0.66, 1.0, far));",
      "  gl_FragColor = vec4(col, 1.0);",
      "  #include <tonemapping_fragment>",
      "  #include <encodings_fragment>",
      "}",
    ].join("\n"),
  }));
  water.rotation.x = -Math.PI / 2; water.position.y = WATER_Y;
  scene.add(water);

  // A few stars that gently twinkle, and shoreline lights that shimmer.
  const SPARKS = 340, sp = new Float32Array(SPARKS * 3), sPhase = new Float32Array(SPARKS), sSize = new Float32Array(SPARKS), sWarm = new Float32Array(SPARKS);
  for (let i = 0; i < SPARKS; i++) {
    const shore = i >= 250, town = nightPaint.towns[i % nightPaint.towns.length];
    const g1 = Math.sqrt(-2 * Math.log(nr() + 1e-6)) * Math.cos(nr() * Math.PI * 2);
    const th = (shore ? town.u + g1 * town.sd * 0.8 : 0.25 + nr() * 0.5) * Math.PI * 2, r = shore ? PANO_R - 1.2 : PANO_R - 2;
    const y = shore ? PANO_Y + PANO_H / 2 - (0.605 + nr() * 0.006) * PANO_H : 5 + Math.pow(nr(), 0.7) * 15;
    sp.set([r * Math.sin(th), y, r * Math.cos(th)], i * 3);
    sPhase[i] = nr() * 100; sSize[i] = shore ? 1.3 + nr() * 1.1 : nr() > 0.9 ? 2.6 : 1.3 + nr() * 1.1; sWarm[i] = shore && nr() > 0.25 ? 1 : 0;
  }
  const sparkGeo = new T.BufferGeometry();
  sparkGeo.setAttribute("position", new T.BufferAttribute(sp, 3));
  sparkGeo.setAttribute("phase", new T.BufferAttribute(sPhase, 1));
  sparkGeo.setAttribute("size", new T.BufferAttribute(sSize, 1));
  sparkGeo.setAttribute("warm", new T.BufferAttribute(sWarm, 1));
  const sparkles = new T.Points(sparkGeo, new T.ShaderMaterial({
    uniforms: { time: { value: 0 }, dpr: { value: 1 } },
    vertexShader: [
      "attribute float phase; attribute float size; attribute float warm; uniform float time; uniform float dpr;",
      "varying float vA; varying float vWarm;",
      "void main() {",
      "  float tw = warm > 0.5 ? 0.8 + 0.2 * sin(time * 1.9 + phase * 13.0) : 0.45 + 0.55 * pow(0.5 + 0.5 * sin(time * (0.6 + fract(phase) * 1.8) + phase), 2.0);",
      "  vA = tw; vWarm = warm;",
      "  gl_PointSize = size * dpr * (0.85 + 0.3 * tw);",
      "  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);",
      "}",
    ].join("\n"),
    fragmentShader: [
      "varying float vA; varying float vWarm;",
      "void main() {",
      "  float d = length(gl_PointCoord - 0.5);",
      "  float a = smoothstep(0.5, 0.05, d) * vA;",
      "  vec3 c = vWarm > 0.5 ? vec3(1.0, 0.78, 0.5) * 1.3 : vec3(0.86, 0.9, 1.0);",
      "  gl_FragColor = vec4(c * a, a);",
      "  #include <tonemapping_fragment>",
      "  #include <encodings_fragment>",
      "}",
    ].join("\n"),
    transparent: true, depthWrite: false, blending: T.AdditiveBlending,
  }));
  scene.add(sparkles);

  // ---------------------------------------------------------------- floor
  // A dark mirror under a polished-stone finish: real reflections of the
  // lamps, speakers and chair, softened so it reads as stone, not glass.
  let mirror = null;
  if (T.Reflector) {
    const size = Math.min(1024, Math.round(Math.max(innerWidth, innerHeight) * 0.6)); // about half the screen
    mirror = new T.Reflector(new T.CircleGeometry(6.55, 96), { textureWidth: size, textureHeight: size, color: col("#6e7686").getHex(), clipBias: 0.003 });
    mirror.rotation.x = -Math.PI / 2;
    const reflect = mirror.onBeforeRender;
    mirror.onBeforeRender = function (...args) { if (three && three.skipReflection) return; reflect.apply(this, args); };
    scene.add(mirror);
  }
  const floorFinish = add(new T.CircleGeometry(6.55, 96), std({ color: "#1b1f28", roughness: 0.5, metalness: 0.1, transparent: !!mirror, opacity: mirror ? 0.74 : 1, envMapIntensity: 0.5 }), [0, 0.002, 0], [-Math.PI / 2, 0, 0], { cast: false });
  const rug = add(new T.CircleGeometry(2.2, 128), std({ color: "#5d616b", roughness: 1, envMapIntensity: 0.2 }), [0, 0.006, 0.15], [-Math.PI / 2, 0, 0], { cast: false });
  rug.scale.set(1.25, 1, 1);

  // ---------------------------------------------------------------- window wall
  const WR = 6.5, A0 = -62, A1 = 82, STEP = 18;
  for (let a = A0; a <= A1 + 0.01; a += STEP) {
    add(rbox(0.07, 3.5, 0.1, 0.02, 2), M.blackMetal, [WR * Math.sin(a * DEG), 1.75, -WR * Math.cos(a * DEG)], [0, -a * DEG, 0]);
    if (a + STEP <= A1 + 0.01) {
      const mid = a + STEP / 2, w = 2 * (WR - 0.02) * Math.sin((STEP / 2) * DEG);
      add(new T.PlaneGeometry(w, 3.42), M.glass, [(WR - 0.02) * Math.sin(mid * DEG), 1.75, -(WR - 0.02) * Math.cos(mid * DEG)], [0, -mid * DEG, 0], { cast: false, receive: false });
    }
  }
  for (let a = A0; a < A1; a += 3) { // sill, head rail and the warm cove strip
    const mid = a + 1.5, len = 2 * WR * Math.sin(1.5 * DEG) + 0.02;
    for (const y of [0.04, 3.48]) add(new T.BoxGeometry(len, 0.08, 0.14), M.blackMetal, [WR * Math.sin(mid * DEG), y, -WR * Math.cos(mid * DEG)], [0, -mid * DEG, 0]);
    add(new T.BoxGeometry(len, 0.015, 0.03), glow("#ffc98a", 2.2), [(WR - 0.12) * Math.sin(mid * DEG), 0.012, -(WR - 0.12) * Math.cos(mid * DEG)], [0, -mid * DEG, 0], { cast: false });
  }
  const wallX = WR * Math.sin(A0 * DEG), wallZ = -WR * Math.cos(A0 * DEG);
  add(new T.BoxGeometry(0.2, 3.5, 7.5), M.wall, [wallX - 0.1, 1.75, wallZ + 3.75]);
  add(rbox(0.5, 3.5, 0.55, 0.03), M.wall, [wallX + 0.25, 1.75, wallZ + 0.55]);

  // ---------------------------------------------------------------- ceiling and skylight
  const ceiling = add(new T.RingGeometry(1.15, 9, 128, 1), M.ceiling, [0, 3.5, -0.6], [Math.PI / 2, 0, 0], { cast: false });
  ceiling.scale.set(1.9, 1, 1);
  const skylight = add(new T.CircleGeometry(1.15, 96), new T.MeshBasicMaterial({ map: skyTex, fog: false }), [0, 3.62, -0.6], [Math.PI / 2, 0, 0], { cast: false });
  skylight.scale.set(1.9, 1, 1);
  const cove = add(new T.RingGeometry(1.15, 1.19, 128, 1), new T.MeshBasicMaterial({ color: col("#4f5f8f"), side: T.DoubleSide }), [0, 3.49, -0.6], [Math.PI / 2, 0, 0], { cast: false });
  cove.scale.set(1.9, 1, 1);
  // ---------------------------------------------------------------- credenza wall: lamp, books, vase, tree
  const cx = wallX + 0.45, cz = wallZ + 3.2;
  add(rbox(0.5, 0.46, 3.4, 0.03), M.walnut, [cx, 0.33, cz]);
  for (const dz of [-1.1, 0, 1.1]) add(new T.BoxGeometry(0.01, 0.38, 0.004), M.rubber, [cx + 0.255, 0.33, cz + dz + 0.55], [0, 0, 0], { cast: false });
  for (const dz of [-1.5, 1.5]) for (const dx of [-0.18, 0.18]) limb([cx + dx, 0.0, cz + dz], [cx + dx, 0.1, cz + dz], 0.015, M.alu);
  add(new T.BoxGeometry(0.42, 0.012, 3.3), glow("#ffc98a", 2.4), [cx, 0.09, cz], null, { cast: false });
  add(lathe([[0, 0], [0.09, 0], [0.1, 0.01], [0.04, 0.02], [0.03, 0.06], [0, 0.06]]), M.alu, [cx, 0.56, cz + 0.9]);
  add(new T.SphereGeometry(0.17, 40, 24), glow("#ffe2b8", 2.4), [cx, 0.79, cz + 0.9], null, { cast: false });
  const lampL = new T.PointLight(col("#ffcf8f"), 1.7, 5.5, 2); lampL.position.set(cx + 0.15, 0.85, cz + 0.9); scene.add(lampL);
  [[0.3, M.book], [0.28, M.book2], [0.31, M.book]].forEach(([w, m], i) => add(rbox(w, 0.035, 0.22, 0.006, 2), m, [cx, 0.58 + i * 0.037, cz - 0.3], [0, i * 0.18, 0]));
  add(lathe([[0, 0], [0.08, 0], [0.11, 0.1], [0.09, 0.24], [0.04, 0.3], [0.045, 0.34], [0, 0.34]]), M.ceramicDark, [cx, 0.56, cz - 1.25]);
  for (let i = 0; i < 4; i++) limb([cx, 0.85, cz - 1.25], [cx + (nr() - 0.5) * 0.4, 1.25 + nr() * 0.3, cz - 1.25 + (nr() - 0.5) * 0.4], 0.006, M.bark);
  // a potted olive tree
  const px = wallX + 0.95, pz = wallZ + 1.35;
  add(lathe([[0, 0], [0.2, 0], [0.27, 0.05], [0.29, 0.5], [0.27, 0.52], [0, 0.52]]), M.ceramicDark, [px, 0, pz]);
  const trunk = new T.CatmullRomCurve3([[0, 0.45, 0], [0.05, 0.9, -0.03], [-0.03, 1.35, 0.04], [0.06, 1.9, -0.02], [0.02, 2.3, 0.02]].map((q) => new T.Vector3(px + q[0], q[1], pz + q[2])));
  add(new T.TubeGeometry(trunk, 40, 0.035, 10), M.bark);
  const tips = [];
  for (let i = 0; i < 7; i++) {
    const t = 0.35 + (i / 7) * 0.6, base = trunk.getPoint(t), a = i * 2.4;
    const tip = new T.Vector3(base.x + Math.cos(a) * (0.35 + nr() * 0.25), base.y + 0.25 + nr() * 0.3, base.z + Math.sin(a) * (0.35 + nr() * 0.25));
    const mid = base.clone().lerp(tip, 0.5).add(new T.Vector3(0, 0.08, 0));
    add(new T.TubeGeometry(new T.CatmullRomCurve3([base, mid, tip]), 12, 0.012, 6), M.bark);
    tips.push(tip);
  }
  tips.push(trunk.getPoint(1));
  const leafShape = new T.Shape();
  leafShape.moveTo(0, 0); leafShape.quadraticCurveTo(0.025, 0.05, 0, 0.11); leafShape.quadraticCurveTo(-0.025, 0.05, 0, 0);
  const leafGeo = new T.ShapeGeometry(leafShape, 6);
  { // leaf UVs: 0..1 across the leaf, midrib along v
    const uv = leafGeo.attributes.uv, pos = leafGeo.attributes.position;
    for (let i = 0; i < uv.count; i++) uv.setXY(i, pos.getX(i) / 0.05 + 0.5, pos.getY(i) / 0.11);
  }
  M.leaf.map = canvasTex(64, 128, (g, w, h) => {
    const gr = g.createLinearGradient(0, 0, w, 0);
    gr.addColorStop(0, "#9aa392"); gr.addColorStop(0.5, "#c8cfbf"); gr.addColorStop(1, "#9aa392");
    g.fillStyle = gr; g.fillRect(0, 0, w, h);
    g.strokeStyle = "rgba(235,240,225,0.75)"; g.lineWidth = 1.5;
    g.beginPath(); g.moveTo(w / 2, 0); g.lineTo(w / 2, h); g.stroke();
    g.lineWidth = 0.8; g.strokeStyle = "rgba(235,240,225,0.35)";
    for (let y = 10; y < h; y += 12) { g.beginPath(); g.moveTo(w / 2, y); g.lineTo(4, y - 10); g.moveTo(w / 2, y); g.lineTo(w - 4, y - 10); g.stroke(); }
  });
  M.leaf.color.set(0xffffff); M.leaf.needsUpdate = true;
  const leaves = new T.InstancedMesh(leafGeo, M.leaf, 520);
  const tmp = new T.Object3D();
  for (let i = 0; i < 520; i++) {
    const tip = tips[i % tips.length];
    tmp.position.set(tip.x + (nr() - 0.5) * 0.42, tip.y + (nr() - 0.5) * 0.36, tip.z + (nr() - 0.5) * 0.42);
    tmp.rotation.set(nr() * 6.3, nr() * 6.3, nr() * 6.3);
    const s = 0.8 + nr() * 0.5; tmp.scale.set(s, s, s);
    tmp.updateMatrix(); leaves.setMatrixAt(i, tmp.matrix);
  }
  const leafTint = new T.Color();
  for (let i = 0; i < 520; i++) leaves.setColorAt(i, leafTint.setHSL(0.24 + nr() * 0.08, 0.16 + nr() * 0.14, 0.11 + nr() * 0.09).convertSRGBToLinear());
  leaves.castShadow = true; scene.add(leaves);

  // ---------------------------------------------------------------- side table and coffee table
  const pedestalTable = (x, z, r, h) => {
    add(lathe([[0, 0], [r * 0.45, 0], [r * 0.45, 0.02], [r * 0.12, 0.06], [r * 0.1, h - 0.04], [r * 0.2, h - 0.03], [0, h - 0.03]]), M.blackMetal, [x, 0, z]);
    add(new T.CylinderGeometry(r, r, 0.035, 64), M.glossy, [x, h, z]);
  };
  const tx = -1.25, tz = 0.95;
  pedestalTable(tx, tz, 0.42, 0.52);
  add(lathe([[0, 0], [0.07, 0], [0.075, 0.01], [0.02, 0.03], [0.012, 0.08], [0, 0.08]]), M.alu, [tx + 0.12, 0.54, tz - 0.05]);
  add(new T.SphereGeometry(0.12, 40, 20, 0, Math.PI * 2, 0, Math.PI / 2), new T.MeshStandardMaterial({ color: col("#ffffff"), emissive: col("#ffd59a"), emissiveIntensity: 1.8, transparent: true, opacity: 0.9, roughness: 0.08 }), [tx + 0.12, 0.62, tz - 0.05], null, { cast: false });
  const lampS = new T.PointLight(col("#ffcf8f"), 1.15, 3.4, 2); lampS.position.set(tx + 0.12, 0.72, tz - 0.05); scene.add(lampS);
  for (const [dx, dz] of [[-0.18, 0.08], [-0.04, 0.21]]) {
    add(lathe([[0, 0], [0.035, 0], [0.042, 0.01], [0.046, 0.085], [0.04, 0.085], [0.036, 0.012], [0, 0.012]]), M.ceramic, [tx + dx, 0.54, tz + dz]);
    add(new T.TorusGeometry(0.018, 0.005, 8, 20, Math.PI), M.ceramic, [tx + dx + 0.046, 0.585, tz + dz], [0, 0, -Math.PI / 2]);
  }
  pedestalTable(2.6, 1.9, 0.85, 0.36);
  add(rbox(0.34, 0.04, 0.25, 0.006, 2), M.book2, [2.4, 0.4, 1.75], [0, 0.4, 0]);
  add(rbox(0.3, 0.035, 0.22, 0.006, 2), M.book, [2.4, 0.437, 1.75], [0, 0.55, 0]);
  add(lathe([[0, 0], [0.05, 0], [0.08, 0.06], [0.06, 0.18], [0.03, 0.24], [0.035, 0.27], [0, 0.27]]), M.ceramic, [2.85, 0.38, 1.7]);

  // ---------------------------------------------------------------- your lounge chair
  const chair = new T.Group(); chair.position.set(0, 0, 0.12); scene.add(chair);
  for (let i = 0; i < 5; i++) {
    const a = (i / 5) * Math.PI * 2 + 0.3;
    const leg = add(rbox(0.05, 0.035, 0.42, 0.014, 2), M.alu, [Math.sin(a) * 0.2, 0.045, Math.cos(a) * 0.2], [0, a, 0], { to: chair });
    add(new T.SphereGeometry(0.022, 12, 8), M.rubber, [Math.sin(a) * 0.4, 0.022, Math.cos(a) * 0.4], null, { to: chair });
    leg.rotation.x = 0.06;
  }
  add(lathe([[0, 0.04], [0.06, 0.04], [0.045, 0.09], [0.036, 0.32], [0.05, 0.36], [0, 0.36]]), M.alu, null, null, { to: chair });
  // Walnut shells carry soft leather cushions with piping; two aluminium
  // spines join the back and head shells. Leather and walnut get a faint cool
  // rim at grazing angles, so the chair's silhouette reads against the window
  // when you sit behind it (on the existing materials: no extra shaders).
  const rimify = (m) => {
    m.onBeforeCompile = (sh) => {
      sh.fragmentShader = sh.fragmentShader.replace("#include <emissivemap_fragment>",
        "#include <emissivemap_fragment>\n\ttotalEmissiveRadiance += vec3(0.14, 0.18, 0.3) * pow(1.0 - clamp(dot(normal, normalize(vViewPosition)), 0.0, 1.0), 5.0);");
    };
    return m;
  };
  rimify(M.leather); rimify(M.walnut);
  const cushion = (w, h, d, rT, rB, R, pos, to) => {
    const g = pillow(w, h, d, { rTop: rT, rBot: rB, edge: 5, dome: 0.16 });
    add(R ? bend(g, R) : g, M.leather, pos, null, { to });
    add(new T.TubeGeometry(new T.CatmullRomCurve3(outlinePts(w, h, rT, rB, R), true), 120, 0.0065, 5, true), M.leather, pos, null, { to, cast: false });
  };
  add(rbox(0.82, 0.06, 0.76, 0.028, 4), M.walnut, [0, 0.39, 0], [-0.05, 0, 0], { to: chair });
  const seat = new T.Group(); seat.position.set(0, 0.485, -0.02); seat.rotation.x = -Math.PI / 2 - 0.06; chair.add(seat);
  cushion(0.76, 0.7, 0.13, 0.15, 0.15, 0, [0, 0, 0], seat);
  // The back curves around a vertical axis BR in front of the shells; the
  // cushions share that axis, so they sit snugly and wrap a little further.
  const BR = 0.72, back = new T.Group(); back.position.set(0, 0.86, 0.42); back.rotation.x = 0.4; chair.add(back);
  const shell = (w, h, rT, rB, y) => add(bend(pillow(w, h, 0.03, { rTop: rT, rBot: rB, edge: 14 }), BR), M.walnut, [0, y, 0], null, { to: back });
  shell(0.84, 0.6, 0.12, 0.14, -0.15);
  shell(0.74, 0.3, 0.12, 0.08, 0.33);
  cushion(0.86, 0.64, 0.12, 0.13, 0.15, BR - 0.08, [0, -0.15, -0.08], back);
  cushion(0.78, 0.33, 0.11, 0.13, 0.1, BR - 0.08, [0, 0.335, -0.08], back);
  for (const sx of [-1, 1]) {
    const a = (sx * 0.17) / BR, r = BR + 0.024;
    add(rbox(0.045, 0.84, 0.016, 0.006, 2), M.alu, [r * Math.sin(a), 0, r * Math.cos(a) - BR], [0, a, 0], { to: back });
  }
  for (const sx of [-1, 1]) {
    add(rbox(0.045, 0.24, 0.6, 0.02, 3), M.walnut, [sx * 0.43, 0.5, 0.05], null, { to: chair });
    add(rbox(0.11, 0.06, 0.6, 0.028, 4), M.leather, [sx * 0.43, 0.64, 0.05], [0.03, 0, 0], { to: chair });
  }
  // moonlight pooling on the rug
  add(new T.PlaneGeometry(4.2, 4.2), new T.MeshBasicMaterial({ map: softTex("rgba(150,175,230,0.2)", "rgba(150,175,230,0)"), transparent: true, depthWrite: false }), [0, 0.01, 0.1], [-Math.PI / 2, 0, 0], { cast: false, receive: false });


  // ---------------------------------------------------------------- finishing touches
  // Brass pulls on the sideboard drawers.
  for (const dz of [-1.1, 0, 1.1]) add(new T.CylinderGeometry(0.007, 0.007, 0.14, 12), M.brass, [cx + 0.265, 0.47, cz + dz + 0.45], [Math.PI / 2, 0, 0]);
  // A framed print over the sideboard: a quiet night landscape.
  const print = canvasTex(640, 460, (g, w, h) => {
    const sky = g.createLinearGradient(0, 0, 0, h * 0.62);
    sky.addColorStop(0, "#0d1430"); sky.addColorStop(1, "#4b5b90");
    g.fillStyle = sky; g.fillRect(0, 0, w, h);
    g.fillStyle = "#eef0f8"; g.beginPath(); g.arc(w * 0.68, h * 0.28, 20, 0, Math.PI * 2); g.fill();
    ["#2a3561", "#1a2247", "#0d132b"].forEach((c, k) => {
      g.fillStyle = c; g.beginPath(); g.moveTo(0, h);
      for (let x = 0; x <= w; x += 6) g.lineTo(x, h * (0.5 + k * 0.09) - Math.sin(x * 0.012 + k * 2) * 26 - Math.sin(x * 0.031 + k) * 11);
      g.lineTo(w, h); g.fill();
    });
    for (let i = 0; i < 1200; i++) { g.fillStyle = `rgba(255,255,255,${(nr() * 0.05).toFixed(3)})`; g.fillRect(nr() * w, nr() * h, 3 + nr() * 12, 1); }
  });
  const artFrame = new T.Group(); artFrame.position.set(wallX + 0.03, 1.62, cz); artFrame.rotation.y = Math.PI / 2; scene.add(artFrame);
  add(rbox(1.24, 0.94, 0.03, 0.006, 2), M.blackMetal, [0, 0, 0], null, { to: artFrame });
  add(new T.PlaneGeometry(1.18, 0.88), std({ color: "#e9e6df", roughness: 0.92 }), [0, 0, 0.0155], null, { to: artFrame, cast: false });
  add(new T.PlaneGeometry(0.98, 0.7), std({ color: "#ffffff", map: print, roughness: 0.85, envMapIntensity: 0.3 }), [0, 0, 0.017], null, { to: artFrame, cast: false });
  // An arc reading lamp behind your right shoulder.
  const lb = [1.95, 0, 1.25], shadeAt = [1.12, 1.86, 0.62];
  add(lathe([[0, 0], [0.19, 0], [0.2, 0.014], [0.185, 0.04], [0, 0.04]], 64), M.ceramic, lb);
  const arc = new T.CatmullRomCurve3([[1.95, 0.04, 1.25], [1.96, 1.2, 1.28], [1.82, 1.98, 1.12], [1.42, 2.12, 0.86], [1.12, 1.98, 0.62]].map((q) => new T.Vector3(...q)));
  add(new T.TubeGeometry(arc, 80, 0.012, 10), M.alu);
  const shade = add(new T.SphereGeometry(0.21, 48, 20, 0, Math.PI * 2, 0, Math.PI * 0.42), M.alu, shadeAt);
  shade.material = M.alu.clone(); shade.material.side = T.DoubleSide;
  add(new T.CircleGeometry(0.15, 40), glow("#ffdcae", 2.6), [shadeAt[0], shadeAt[1] + 0.06, shadeAt[2]], [Math.PI / 2, 0, 0], { cast: false });
  const readLight = new T.PointLight(col("#ffd29c"), 0.9, 3.8, 2); readLight.position.set(shadeAt[0], shadeAt[1] - 0.12, shadeAt[2]); scene.add(readLight);
  // A candle on the low table, in a glass holder.
  const flameTex = canvasTex(64, 128, (g, w, h) => {
    const gr = g.createRadialGradient(w / 2, h * 0.68, 2, w / 2, h * 0.58, h * 0.5);
    gr.addColorStop(0, "rgba(255,255,235,1)"); gr.addColorStop(0.25, "rgba(255,200,110,0.9)"); gr.addColorStop(1, "rgba(255,120,40,0)");
    g.fillStyle = gr; g.beginPath(); g.ellipse(w / 2, h * 0.6, w * 0.32, h * 0.42, 0, 0, Math.PI * 2); g.fill();
  });
  const cxT = 2.78, czT = 2.08, tyT = 0.378;
  add(new T.CylinderGeometry(0.034, 0.034, 0.07, 28), std({ color: "#efe6d6", roughness: 0.55 }), [cxT, tyT + 0.035, czT]);
  add(lathe([[0.045, 0], [0.05, 0], [0.052, 0.11], [0.048, 0.11], [0.044, 0.004]], 40), new T.MeshStandardMaterial({ color: col("#cfd8ff"), roughness: 0.05, metalness: 0.2, transparent: true, opacity: 0.18, envMapIntensity: 1.5, side: T.DoubleSide, depthWrite: false }), [cxT, tyT, czT], null, { cast: false });
  const flame = new T.Sprite(new T.SpriteMaterial({ map: flameTex, color: col("#ffd090"), transparent: true, depthWrite: false, blending: T.AdditiveBlending }));
  flame.scale.set(0.028, 0.06, 1); flame.position.set(cxT, tyT + 0.1, czT); scene.add(flame);
  const candleLight = new T.PointLight(col("#ffb46a"), 0.5, 2.4, 2); candleLight.position.set(cxT, tyT + 0.16, czT); scene.add(candleLight);
  // Recessed downlights: a slim aluminium trim, a dark baffle with the lamp
  // set in it, and a soft warm wash on the ceiling around each one.
  const washMat = new T.MeshBasicMaterial({ map: softTex("rgba(255,214,160,0.6)", "rgba(255,214,160,0)"), transparent: true, opacity: 0.16, depthWrite: false, blending: T.AdditiveBlending });
  for (let i = 0; i < 8; i++) {
    const a = (i / 8) * Math.PI * 2 + 0.2, x = Math.sin(a) * 4.1, z = -0.6 + Math.cos(a) * 3.0, down = [Math.PI / 2, 0, 0];
    add(new T.PlaneGeometry(0.62, 0.62), washMat, [x, 3.496, z], down, { cast: false, receive: false });
    add(new T.RingGeometry(0.058, 0.078, 40), M.alu, [x, 3.492, z], down, { cast: false });
    add(new T.RingGeometry(0.03, 0.058, 40), M.blackMetal, [x, 3.492, z], down, { cast: false });
    add(new T.CircleGeometry(0.03, 24), glow("#fff0da", 0.9), [x, 3.49, z], down, { cast: false });
  }
  // Soft contact shadows that ground the furniture.
  const aoTex = softTex("rgba(0,0,0,0.9)", "rgba(0,0,0,0)");
  const ao = (x, z, sx, sz, o, y = 0.008, to) => add(new T.PlaneGeometry(sx, sz), new T.MeshBasicMaterial({ map: aoTex, transparent: true, opacity: o, depthWrite: false }), [x, y, z], [-Math.PI / 2, 0, 0], { cast: false, receive: false, to });
  ao(0, 0.14, 1.25, 1.25, 0.6, 0.0095);
  ao(tx, tz, 1.05, 1.05, 0.5);
  ao(2.6, 1.9, 2.0, 2.0, 0.5);
  ao(px, pz, 0.85, 0.85, 0.6);
  ao(cx, cz, 0.85, 3.8, 0.55);
  ao(lb[0], lb[2], 0.6, 0.6, 0.45);
  // where the floor meets the wall and its pillar
  const wallAo = canvasTex(64, 4, (g, w, h) => { const gr = g.createLinearGradient(0, 0, w, 0); gr.addColorStop(0, "rgba(0,0,0,0.85)"); gr.addColorStop(1, "rgba(0,0,0,0)"); g.fillStyle = gr; g.fillRect(0, 0, w, h); });
  add(new T.PlaneGeometry(0.55, 7.5), new T.MeshBasicMaterial({ map: wallAo, transparent: true, opacity: 0.55, depthWrite: false }), [wallX + 0.275, 0.0085, wallZ + 3.75], [-Math.PI / 2, 0, 0], { cast: false, receive: false });
  ao(wallX + 0.25, wallZ + 0.55, 0.95, 1.0, 0.5);

  // ---------------------------------------------------------------- light
  scene.add(new T.HemisphereLight(col("#2c3d6e"), col("#06080e"), 0.36));
  const moon = new T.DirectionalLight(col("#adc0ff"), 0.85);
  moon.position.set(-2.5, 7, -7.5);
  moon.target.position.set(0, 0, 0.5);
  moon.castShadow = true;
  moon.shadow.mapSize.set(2048, 2048);
  Object.assign(moon.shadow.camera, { left: -8, right: 8, top: 8, bottom: -8, near: 1, far: 25 });
  moon.shadow.bias = -0.0005;
  moon.shadow.normalBias = 0.02;
  scene.add(moon, moon.target);
  const skyFill = new T.PointLight(col("#5b77c8"), 0.55, 7, 2); skyFill.position.set(0, 3.2, -0.6); scene.add(skyFill);
  // a soft cool fill from behind you, so the chair's shape reads against the window
  const rim = new T.DirectionalLight(col("#8ea4e6"), 0.28); rim.position.set(2.5, 3.5, 7); scene.add(rim);
  // The opening's title, hung in the night sky over the lake; shown only while
  // the room opens (applyOpening). Redrawn once the page's font has loaded.
  const paintTitle = (g, w, h) => {
    g.clearRect(0, 0, w, h);
    g.font = '200 150px "Outfit", "Helvetica Neue", sans-serif'; g.textBaseline = "middle";
    const word = "Yinwei", track = 26, widths = [...word].map((ch) => g.measureText(ch).width);
    let x = (w - widths.reduce((a, b) => a + b, 0) - track * (word.length - 1)) / 2;
    g.shadowColor = "rgba(160, 190, 255, 0.95)"; g.shadowBlur = 34; g.fillStyle = "rgba(236, 242, 255, 0.96)";
    [...word].forEach((ch, i) => { g.fillText(ch, x, h / 2 + 8); x += widths[i] + track; });
  };
  const titleTex = canvasTex(1024, 256, paintTitle);
  if (document.fonts && document.fonts.load) {
    document.fonts.load('200 150px "Outfit"').then(() => { paintTitle(titleTex.image.getContext("2d"), 1024, 256); titleTex.needsUpdate = true; }).catch(() => {});
  }
  const titleCard = new T.Mesh(new T.PlaneGeometry(5.2, 1.3), new T.MeshBasicMaterial({ map: titleTex, transparent: true, opacity: 0, depthWrite: false, fog: false, blending: T.AdditiveBlending }));
  titleCard.renderOrder = 5; titleCard.visible = false; scene.add(titleCard);
  titleCard.layers.set(1); camera.layers.enable(1); // the floor mirror's camera sees layer 0 only: no backwards title in the floor

  // ---------------------------------------------------------------- sound
  const makeRings = (n = 4) => Array.from({ length: n }, () => {
    const m = new T.Mesh(new T.RingGeometry(0.985, 1, 128), new T.MeshBasicMaterial({ color: col("#9db8ff"), transparent: true, opacity: 0, depthWrite: false, blending: T.AdditiveBlending, side: T.DoubleSide }));
    m.rotation.x = -Math.PI / 2; scene.add(m); return m;
  });
  const floorGlow = () => add(new T.PlaneGeometry(1, 1), new T.MeshBasicMaterial({ map: blueSoft, transparent: true, opacity: 0.5, depthWrite: false, blending: T.AdditiveBlending }), [0, 0.012, 0], [-Math.PI / 2, 0, 0], { cast: false, receive: false });
  // Point: a floating sound pod, a satin disc with a glowing dome and halo ring
  const source = new T.Group(); scene.add(source);
  add(lathe([[0, -0.05], [0.12, -0.045], [0.165, -0.02], [0.17, 0], [0, 0]], 64), M.satin, null, null, { to: source, cast: false });
  const dome = add(new T.SphereGeometry(0.105, 40, 20, 0, Math.PI * 2, 0, Math.PI / 2), new T.MeshStandardMaterial({ color: col("#e3ebff"), emissive: col("#8fb0ff"), emissiveIntensity: 1.8, roughness: 0.15 }), [0, 0, 0], null, { to: source, cast: false });
  add(new T.TorusGeometry(0.2, 0.004, 8, 96), glow("#9db8ff", 2.2), [0, -0.01, 0], [Math.PI / 2, 0, 0], { to: source, cast: false });
  const halo = new T.Sprite(new T.SpriteMaterial({ map: blueSoft, color: col("#8fb0ff"), transparent: true, opacity: 0.45, depthWrite: false, blending: T.AdditiveBlending }));
  halo.scale.set(1.1, 1.1, 1); source.add(halo);
  // The sound's light lives in the scene, not in the sound: hiding a light
  // changes the light count and makes every material rebuild its shader (a
  // long freeze on iPad). It follows the sound, or sits between the two
  // speakers in 2.0, and is never hidden.
  const blue = new T.PointLight(col("#7c9dff"), 1.2, 4.5, 2); scene.add(blue);
  const hit = new T.Mesh(new T.SphereGeometry(0.42, 12, 8), new T.MeshBasicMaterial({ transparent: true, opacity: 0, depthWrite: false })); source.add(hit);
  const sourceRings = makeRings(4);
  const sourceGlow = floorGlow();
  const beamGeo = new T.BufferGeometry().setFromPoints([new T.Vector3(), new T.Vector3()]);
  const beam = new T.Line(beamGeo, new T.LineDashedMaterial({ color: col("#a6c0ff"), dashSize: 0.04, gapSize: 0.05, transparent: true, opacity: 0.6 }));
  scene.add(beam);
  const orbitPts = [];
  for (let i = 0; i < 180; i++) { const a = (i / 180) * Math.PI * 2; orbitPts.push(new T.Vector3(Math.sin(a), 0, -Math.cos(a))); }
  const orbit = new T.LineLoop(new T.BufferGeometry().setFromPoints(orbitPts), new T.LineDashedMaterial({ color: col("#a6c0ff"), dashSize: 0.025, gapSize: 0.035, transparent: true, opacity: 0.45 }));
  orbit.computeLineDistances(); scene.add(orbit);
  const guides = new T.Group(); scene.add(guides);
  for (const d of [1, 2, 5, 10]) {
    const r = RoomMath.roomRadius(d);
    const ring = new T.Mesh(new T.RingGeometry(r - 0.01, r + 0.01, 160), new T.MeshBasicMaterial({ color: col("#9fbaff"), transparent: true, opacity: 0.32, depthWrite: false }));
    ring.rotation.x = -Math.PI / 2; ring.position.y = 0.015; guides.add(ring);
  }

  // Fixed pool: clone one cabinet/stand template; all geometry and materials
  // are shared. No mesh creation on state ticks or gestures. Only L/R cast shadows.
  const speakers = new T.Group(); scene.add(speakers);
  const speakerFx = [];
  for (let i = 0; i < 8; i++) {
    if (i > 0) {
      const group = speakerFx[0].group.clone(true); speakers.add(group);
      const cab = group.getObjectByName("cabinet"), stand = group.getObjectByName("stand");
      cab.userData.speakerIndex = i;
      if (i >= 2) group.traverse(o => { o.castShadow = false; });
      speakerFx.push({ group, cab, stand, selected: group.getObjectByName("selection"), x: 0, y: EAR, z: 0,
        rings: makeRings(3), glow: floorGlow() });
      continue;
    }
    const x = 0, z = 0, group = new T.Group(), stand = new T.Group();
    stand.name = "stand"; group.add(stand); speakers.add(group);
    add(rbox(0.32, 0.025, 0.32, 0.01, 2), M.blackMetal, [x, 0.0125, z], null, { to: stand });
    for (const dx of [-0.06, 0.06]) limb([x + dx, 0.025, z], [x + dx, EAR - 0.235, z], 0.018, M.blackMetal, stand);
    add(rbox(0.22, 0.02, 0.26, 0.008, 2), M.blackMetal, [x, EAR - 0.225, z], null, { to: stand });
    const cab = new T.Group(); cab.position.set(x, EAR, z); cab.name = "cabinet"; cab.userData.speakerIndex = i; group.add(cab);
    add(rbox(0.26, 0.42, 0.32, 0.028, 4), M.satin, [0, 0, 0], null, { to: cab });
    const wz = 0.161, wy = -0.065;
    add(new T.TorusGeometry(0.09, 0.006, 10, 64), M.alu, [0, wy, wz], null, { to: cab });
    add(new T.TorusGeometry(0.079, 0.011, 12, 64), M.rubber, [0, wy, wz + 0.002], null, { to: cab });
    add(lathe([[0.022, -0.016], [0.07, 0.004]], 48), M.cone, [0, wy, wz], [Math.PI / 2, 0, 0], { to: cab, cast: false });
    const cap = add(new T.SphereGeometry(0.024, 24, 12), M.cone, [0, wy, wz - 0.014], null, { to: cab, cast: false }); cap.scale.z = 0.5;
    add(lathe([[0.013, 0], [0.045, 0.01]], 40), M.blackMetal, [0, 0.115, wz - 0.004], [Math.PI / 2, 0, 0], { to: cab, cast: false });
    add(new T.SphereGeometry(0.013, 20, 10, 0, Math.PI * 2, 0, Math.PI / 2), M.alu, [0, 0.115, wz - 0.002], [Math.PI / 2, 0, 0], { to: cab, cast: false });
    add(new T.TorusGeometry(0.093, 0.0045, 8, 64), glow("#7c9dff", 1.6), [0, wy, wz + 0.006], null, { to: cab, cast: false });
    add(new T.CircleGeometry(0.018, 24), M.rubber, [0, -0.17, wz + 0.001], null, { to: cab, cast: false });
    cab.lookAt(0, EAR, 0);
    add(new T.PlaneGeometry(0.62, 0.62), new T.MeshBasicMaterial({ map: softTex("rgba(0,0,0,0.9)", "rgba(0,0,0,0)"), transparent: true, opacity: 0.5, depthWrite: false }), [x, 0.008, z], [-Math.PI / 2, 0, 0], { cast: false, receive: false, to: group });
    const selected = add(new T.RingGeometry(0.23, 0.247, 48), new T.MeshBasicMaterial({ color: col("#d8e4f4"), transparent: true, opacity: 0.7, depthWrite: false }), [0, 0.016, 0], [-Math.PI / 2, 0, 0], { to: group, cast: false });
    selected.name = "selection";
    speakerFx.push({ group, cab, stand, selected, x, y: EAR, z, rings: makeRings(3), glow: floorGlow() });
  }
  const speakerMid = new T.Vector3(0, EAR, 0);

  // ---------------------------------------------------------------- merge the fixed room
  // Everything that never moves is merged by material into a few meshes, so
  // the room draws in tens of calls instead of hundreds.
  scene.updateMatrixWorld(true);
  const countMeshes = () => { let n = 0; scene.traverse((o) => { if (o.isMesh) n++; }); return n; };
  const meshesBefore = countMeshes();
  const keep = new Set([sky, floorFinish, rug, ceiling, skylight, cove]);
  if (mirror) keep.add(mirror);
  const moving = new Set([source, speakers, guides]);
  const groups = new Map();
  scene.traverse((o) => {
    if (!o.isMesh || o.isInstancedMesh || keep.has(o) || Array.isArray(o.material) || !o.visible) return;
    for (let q = o.parent; q; q = q.parent) if (moving.has(q)) return;
    const k = `${o.material.uuid}|${o.castShadow}|${o.receiveShadow}`;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(o);
  });
  if (T.BufferGeometryUtils) {
    for (const list of groups.values()) {
      if (list.length < 2) continue;
      const geos = list.map((o) => {
        let g = o.geometry.clone().applyMatrix4(o.matrixWorld);
        if (g.index) g = g.toNonIndexed();
        for (const name of Object.keys(g.attributes)) if (!["position", "normal", "uv"].includes(name)) g.deleteAttribute(name);
        if (!g.attributes.normal) g.computeVertexNormals();
        if (!g.attributes.uv) g.setAttribute("uv", new T.Float32BufferAttribute(new Float32Array(g.attributes.position.count * 2), 2));
        return g;
      });
      const merged = T.BufferGeometryUtils.mergeBufferGeometries(geos);
      if (!merged) continue;
      const m = new T.Mesh(merged, list[0].material);
      m.castShadow = list[0].castShadow; m.receiveShadow = list[0].receiveShadow;
      scene.add(m);
      list.forEach((o) => o.parent.remove(o));
    }
  }
  perf.meshes = [meshesBefore, countMeshes()];
  renderer.shadowMap.needsUpdate = true;

  // ---------------------------------------------------------------- post: bloom on lamps, rings and lake lights
  let composer = null, grade = null, bloom = null;
  if (T.EffectComposer && T.RenderPass && T.UnrealBloomPass && T.ShaderPass && T.GammaCorrectionShader) {
    // Glow runs in half-float buffers where the GPU allows it: in 8-bit, its
    // faint tails snap to hard grey blocks over the dark ceiling and sky.
    const hdr = renderer.capabilities.isWebGL2 && (renderer.extensions.has("EXT_color_buffer_float") || renderer.extensions.has("EXT_color_buffer_half_float"));
    const rtType = hdr ? T.HalfFloatType : T.UnsignedByteType;
    composer = new T.EffectComposer(renderer, new T.WebGLRenderTarget(512, 512, { minFilter: T.LinearFilter, magFilter: T.LinearFilter, format: T.RGBAFormat, type: rtType }));
    composer.addPass(new T.RenderPass(scene, camera));
    bloom = new T.UnrealBloomPass(new T.Vector2(512, 512), 0.75, 0.55, 0.6);
    [bloom.renderTargetBright, ...bloom.renderTargetsHorizontal, ...bloom.renderTargetsVertical].forEach((rt) => (rt.texture.type = rtType));
    perf.hdr = hdr;
    composer.addPass(bloom);
    // Cool shadows, warm highlights, a soft vignette and fine film grain.
    grade = new T.ShaderPass({
      uniforms: { tDiffuse: { value: null }, time: { value: 0 } },
      vertexShader: "varying vec2 vUv; void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }",
      fragmentShader: [
        "uniform sampler2D tDiffuse; uniform float time; varying vec2 vUv;",
        "float rand(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }",
        "void main() {",
        "  vec4 c = texture2D(tDiffuse, vUv);",
        "  float l = clamp(dot(c.rgb, vec3(0.2126, 0.7152, 0.0722)) * 2.5, 0.0, 1.0);",
        "  c.rgb *= mix(vec3(0.95, 0.99, 1.07), vec3(1.05, 1.01, 0.95), l);",
        "  vec2 d = vUv - 0.5; c.rgb *= 1.0 - dot(d, d) * 0.3;",
        "  c.rgb *= 1.0 + (rand(vUv * 937.0 + fract(time * 7.0)) - 0.5) * 0.07;",
        "  gl_FragColor = c;",
        "}",
      ].join("\n"),
    });
    composer.addPass(grade);
    composer.addPass(new T.ShaderPass(T.GammaCorrectionShader));
  }

  // Detailed surfaces arrive from the generator and are swapped in as they come.
  const upgrade = (mat, surf, extra = {}) => { Object.assign(mat, surf, extra); mat.color.set(0xffffff); mat.needsUpdate = true; };
  const n2 = (k) => new T.Vector2(k, k);
  const dataTex = (buf, S, srgb, repeat) => {
    const t = new T.DataTexture(new Uint8Array(buf), S, S, T.RGBAFormat);
    t.wrapS = t.wrapT = T.RepeatWrapping; t.repeat.set(repeat[0], repeat[1]);
    t.magFilter = T.LinearFilter; t.minFilter = T.LinearMipmapLinearFilter; t.generateMipmaps = true;
    t.anisotropy = renderer.capabilities.getMaxAnisotropy();
    if (srgb) t.encoding = T.sRGBEncoding;
    t.needsUpdate = true;
    return t;
  };
  const maps = (px) => {
    const o = { map: dataTex(px.color, px.S, true, px.repeat), roughnessMap: dataTex(px.rough, px.S, false, px.repeat), normalMap: dataTex(px.normal, px.S, false, px.repeat) };
    if (px.alpha) o.alphaMap = dataTex(px.alpha, px.S, false, px.repeat);
    return o;
  };
  const targets = {
    stone: (sf) => {
      const deckMaps = {};
      for (const k of ["map", "roughnessMap", "normalMap"]) { const t = sf[k].clone(); t.repeat.set(7, 7); t.needsUpdate = true; deckMaps[k] = t; }
      upgrade(deck.material, deckMaps, { roughness: 1, normalScale: n2(0.6) }); deck.material.color.set(0x59606e);
      if (!mirror) delete sf.alphaMap;
      upgrade(floorFinish.material, sf, { roughness: 1, opacity: 1, normalScale: n2(0.5) });
    },
    leather: (sf) => upgrade(M.leather, sf, { roughness: 1, normalScale: n2(0.8) }),
    walnut: (sf) => upgrade(M.walnut, sf, { roughness: 1, normalScale: n2(0.2) }),
    rug: (sf) => upgrade(rug.material, sf, { roughness: 1, normalScale: n2(0.35) }),
    plaster: (sf) => { upgrade(M.wall, sf, { roughness: 1, normalScale: n2(0.5) }); upgrade(M.ceiling, sf, { roughness: 1, normalScale: n2(0.2) }); M.ceiling.color.set(0x3a3e48); },
    brushed: (sf) => upgrade(M.alu, sf, { roughness: 1, normalScale: n2(0.3) }),
    satin: (sf) => upgrade(M.satin, sf, { roughness: 1, normalScale: n2(0.3) }),
    ceramic: (sf) => upgrade(M.ceramic, sf, { roughness: 1, normalScale: n2(0.2) }),
    ceramicDark: (sf) => upgrade(M.ceramicDark, sf, { roughness: 1, normalScale: n2(0.2) }),
    bark: (sf) => upgrade(M.bark, sf, { roughness: 1, normalScale: n2(1) }),
  };
  startSurfaces((name, px) => { try { targets[name](maps(px)); } catch (e) { console.error("Surface", name, e); } });

  three = { T, renderer, composer, grade, bloom, floorFinish, water, sparkles, skipReflection: false, flame, candleLight, mirror, scene, camera, source, dome, halo, blue, speakerMid, hit, sourceRings, sourceGlow, beam, beamGeo, orbit, guides, speakers, speakerFx, raycaster: new T.Raycaster(), v: new T.Vector3(), ceilingParts: [ceiling, skylight, cove], lampL, lampS, readLight, skyFill, cove, titleCard };
  three.base = { exposure: renderer.toneMappingExposure, bloom: bloom ? bloom.strength : 0, lampL: lampL.intensity, lampS: lampS.intensity, read: readLight.intensity, sky: skyFill.intensity, cove: cove.material.color.clone() };
}

// Labels for the placement guides.
const labelDefs = [1, 2, 5, 10].map((d) => { const [x, , z] = RoomMath.toRoom(150, 0, d); return { t: `${d} m`, p: [x, 0.02, z] }; })
  .concat([{ t: "FRONT", p: [0, 0.02, -(R10 + 0.45)] }]);
const labelEls = labelDefs.map((d) => { const s = document.createElement("span"); s.textContent = d.t; $("labels").appendChild(s); return s; });
const tagEl = document.createElement("span"); tagEl.className = "tag"; $("labels").appendChild(tagEl);
let labelsShown = true, tagShown = true;

let W = 0, H = 0;
function measure() {
  const p = $("player").getBoundingClientRect();
  if (p.height) document.documentElement.style.setProperty("--bar-h", `${Math.round(p.height)}px`);
  if (!three) return;
  const sc = $("scene").getBoundingClientRect();
  W = sc.width; H = sc.height;
  if (!W || !H) return;
  three.renderer.setSize(W, H, false);
  if (three.composer) {
    const pr = three.renderer.getPixelRatio();
    three.composer.setPixelRatio(pr); three.composer.setSize(W, H);
    if (three.bloom) three.bloom.setSize(Math.round(W * pr), Math.round(H * pr)); // its blur starts at half of this
    three.sparkles.material.uniforms.dpr.value = pr;
  }
  const over = (el) => { const r = el.getBoundingClientRect(); return el.style.visibility !== "hidden" && r.width && r.top < sc.bottom && r.bottom > sc.top && r.left < sc.right && r.right > sc.left ? r : null; };
  const pr = over($("player")), sr = over($("side"));
  const b = pr ? Math.max(0, sc.bottom - pr.top) : 0;
  const r = sr ? Math.max(0, sc.right - sr.left) : 0;
  const c = three.camera;
  c.aspect = W / H;
  // Keep about 70° across, whatever the screen shape.
  // Portrait caps the vertical view so the skylight and empty floor don't take over.
  c.fov = clamp((2 * Math.atan(Math.tan(35 * DEG) / (W / H))) / DEG, 40, 72);
  c.setViewOffset(W, H, r * 0.35, b * 0.42, W, H);
  // In portrait the skylight sits higher in a taller view: make it a size smaller.
  const sk = 1 - 0.2 * clamp((H / W - 1) / 0.45, 0, 1);
  three.ceilingParts.forEach((m) => m.scale.set(1.9 * sk, sk, 1));
  c.updateProjectionMatrix();
  placePop();
}
const PIVOT = [0, 1.0, -0.4];
function placeCamera() {
  const c = three.camera, sy = Math.sin(cam.yaw), cy = Math.cos(cam.yaw);
  const rad = 4.5 * cam.zoom * (1 + 0.16 * clamp((H / W - 1) / 0.45, 0, 1)); // a step back in portrait
  const along = (dx, dy, dz) => [PIVOT[0] + dx * cy + dz * sy, PIVOT[1] + dy, PIVOT[2] - dx * sy + dz * cy];
  const roomPos = along(0, rad * Math.sin(cam.lift), rad * Math.cos(cam.lift));
  const roomLook = along(0, 0.32, -3.0);
  const topPos = [0, 9.6 * cam.zoom, 0.35], topLook = [0, 0, -0.45];
  const k = cam.k * cam.k * (3 - 2 * cam.k);
  const mix = (a, b) => a.map((v, i) => v + (b[i] - v) * k);
  c.position.set(...mix(roomPos, topPos));
  c.up.set(0, 1, 0);
  c.lookAt(...mix(roomLook, topLook));
  three.ceilingParts.forEach((m) => (m.visible = cam.k < 0.5));
}
const screenOf = (v) => [((v.x + 1) / 2) * W, ((1 - v.y) / 2) * H];

let suspended = false; // YinweiListen.suspend() / resume()
// The dark cover lifts with the first frame; the room itself opens dark (see
// applyOpening) and the controls arrive as the sound ignites.
let revealed = 0;
function revealRoom() {
  if (revealed) return;
  revealed = performance.now();
  const veil = $("veil"); veil.classList.add("gone"); setTimeout(() => { veil.hidden = true; }, 1000);
  if (reduced || S.screen !== "room") releaseChrome();
  setTimeout(releaseChrome, 14000); // never leave the controls away (the opening starts within 6 s)
}
function releaseChrome() {
  const app = $("app");
  if (!app.classList.contains("intro")) return;
  app.classList.add("intro-run"); app.classList.remove("intro");
  setTimeout(() => app.classList.remove("intro-run"), 2200);
}
function finishOpening() {
  if (opening) opening.skip = true;
  entrance = null;
  releaseChrome();
}
// The opening, over OPENING_END seconds: the night outside first (exposure
// low, the title over the lake), the ceiling's cove ring and the lamps coming
// on in turn, then at IGNITE the sound lights up with a flare, a ring of light
// and a bloom flash, and the controls arrive. Values the frame loop eases
// itself are scaled for this frame only (the returned undo puts them back).
function applyOpening(now, point) {
  const o = opening;
  if (!o || !three) return null;
  const B = three.base, t = o.skip ? OPENING_END : o.t0 ? (now - o.t0) / 1000 : 0;
  const ease = (x) => x * x * (3 - 2 * x);
  const ramp = (a, d) => ease(clamp((t - a) / d, 0, 1));
  if (t >= OPENING_END) {
    three.renderer.toneMappingExposure = B.exposure;
    if (three.bloom) three.bloom.strength = B.bloom;
    three.lampL.intensity = B.lampL; three.lampS.intensity = B.lampS; three.readLight.intensity = B.read; three.skyFill.intensity = B.sky;
    three.cove.material.color.copy(B.cove); three.flame.material.opacity = 1; three.titleCard.visible = false;
    opening = null; releaseChrome();
    return null;
  }
  three.renderer.toneMappingExposure = B.exposure * (0.36 + 0.64 * ramp(0.15, 2.7));
  three.skyFill.intensity = B.sky * ramp(0.3, 1.2);
  three.cove.material.color.copy(B.cove).multiplyScalar(ramp(0.45, 0.8));
  three.lampL.intensity = B.lampL * ramp(0.95, 0.6);
  three.lampS.intensity = B.lampS * ramp(1.2, 0.6);
  three.readLight.intensity = B.read * ramp(1.4, 0.6);
  const candle = ramp(1.6, 0.5); three.candleLight.intensity *= candle; three.flame.material.opacity = candle;
  // The title: in over the dark lake, out as the camera comes inside.
  const card = three.titleCard;
  if (!o.titleAt) { // ahead of where the camera starts, out over the lake
    const c = three.camera, d = c.getWorldDirection(new three.T.Vector3()).setY(0).normalize();
    o.titleAt = c.position.clone().addScaledVector(d, 12);
  }
  card.visible = true; card.position.set(o.titleAt.x, 0, o.titleAt.z); card.lookAt(three.camera.position.x, 0, three.camera.position.z);
  card.material.opacity = 0.9 * ramp(0.1, 0.8) * (1 - ramp(1.5, 0.8));
  card.position.y = 2.9 + 0.25 * ramp(0, 2.4);
  // The sound ignites: a quick flare that settles, a ring of light, a bloom flash.
  const s = t - IGNITE, ig = s < 0 ? 0 : s < 0.18 ? (s / 0.18) * 1.8 : 1 + 0.8 * Math.exp(-(s - 0.18) * 4);
  if (three.bloom) three.bloom.strength = B.bloom * (1 + 0.7 * Math.max(0, ig - 1));
  const dome = three.dome.material, blue = three.blue, was = [dome.emissiveIntensity, blue.intensity];
  dome.emissiveIntensity *= ig; blue.intensity *= ig;
  three.halo.material.opacity *= Math.min(1.6, ig); three.sourceGlow.material.opacity *= Math.min(1, ig);
  const ring = three.sourceRings[0], u = s / 1.3;
  if (point && u >= 0 && u < 1) { ring.visible = true; const r = 0.1 + u * 1.5; ring.scale.set(r, r, r); ring.material.opacity = 0.9 * Math.pow(1 - u, 2); }
  if (s >= 0.15 && !o.chrome) { o.chrome = true; releaseChrome(); }
  return () => { dome.emissiveIntensity = was[0]; blue.intensity = was[1]; };
}
/** Plays the opening again (the review page's button; its tap also lets the sound play). */
function replayOpening() {
  if (!three || reduced) return;
  OpeningSound.unlock();
  $("app").classList.add("intro"); $("app").classList.remove("intro-run");
  entered = false; entrance = null; opening = null; replaySound = true; // the next frame starts it again
}
let level = 0, levelTarget = 0, last = performance.now(), slow = 0, levelTick = 0, lastRender = 0, lastMode = null, camMoving = false;
// Something on screen is moving: draw at full rate. Otherwise 30 fps.
const isActive = () => !!bench || !!opening || (!!entrance && !entrance.t0 && perf.texturesFrame > 0) || pointers.size > 0 || !!dragging || camMoving || !!snapAnim || S.listening === "connecting" ||
  (S.screen === "room" && S.mode === "point" && S.motion === "orbit" && S.notice !== "lost");
function frame(now) {
  requestAnimationFrame(frame);
  if (document.hidden || suspended) { last = now; perf.prev = 0; return; }
  const active = isActive();
  if (!active && now - lastRender < 1000 / 30 - 3) return;
  perfTick(now, active);
  lastRender = now;
  const dt = Math.min(0.05, (now - last) / 1000); last = now;
  const lost = S.notice === "lost";
  const sounding = S.live && S.playing && !lost;
  const hearing = sounding && S.listening === "on" && S.notice === "none";
  if (S.screen === "room" && S.mode === "point" && S.motion === "orbit" && !lost) { S.az = wrap(S.az + 360 * S.orbitHz * dt); if ((slow += dt) > 0.2) { slow = 0; renderPlace(); } }
  levelTarget = sounding ? clamp(Number(S.level) || 0, 0, 1) : 0; // the app's level meter (state.level)
  level += (levelTarget - level) * Math.min(1, dt * 9);
  if ((levelTick += dt) > 1 / 24) { levelTick = 0; levels.shift(); levels.push(hearing ? clamp(level * (0.5 + Math.random() * 0.7), 0.04, 1) : 0.04); drawLevel(); }

  if (three && three.lost) return; // waiting for the GPU to come back
  if (perf.restoring && three) { perf.restoring = false; const veil = $("veil"); veil.classList.add("gone"); setTimeout(() => { veil.hidden = true; }, 1000); }
  if (three && W && H) {
    const { source, dome, halo, blue, speakerMid, sourceRings, sourceGlow, beam, beamGeo, orbit, guides, speakers, speakerFx, v } = three;
    if (S.screen === "room" && !entered) {
      entered = true;
      // It holds at its start pose until the detailed surfaces are in, so their
      // one-off shader rebuild never lands in the middle of the move.
      if (!reduced) {
        entrance = { t0: 0, yaw: cam.tYaw - 0.6, lift: Math.min(20 * DEG, cam.tLift + 9 * DEG), zoom: Math.min(1.38, cam.tZoom * 1.38) };
        opening = { t0: 0, chrome: false, sound: replaySound }; replaySound = false;
      } else releaseChrome();
    }
    // a few full-rate frames after the warm-up, then the move
    if (entrance && !entrance.t0 && revealed && ((perf.warmFrame && perf.frames > perf.warmFrame + 6) || now - t0Script > 6000)) {
      entrance.t0 = now; act("opening move");
      if (opening) { opening.t0 = now; OpeningSound.play({ ignite: IGNITE, pan: Math.sin(S.az * DEG), mute: !opening.sound && S.listening !== "off" }); }
    }
    if (entrance && (pointers.size || dragging || (entrance.t0 && now - entrance.t0 >= MOVE_MS))) entrance = null; // a touch takes over at once
    applyInput(now);
    if (dragging) perf.touchTime += dt;
    if (fling && !dragging) {
      const k = Math.exp(-dt / 0.22);
      cam.tYaw = clamp(cam.tYaw + fling.yaw * dt * 1000, YAW_LIM[0], YAW_LIM[1]);
      cam.tLift = clamp(cam.tLift + fling.lift * dt * 1000, LIFT_LIM[0], LIFT_LIM[1]);
      fling.yaw *= k; fling.lift *= k;
      if (Math.abs(fling.yaw) + Math.abs(fling.lift) < 2e-5) fling = null;
    }
    if (snapAnim) {
      if (!snapAnim.t0) snapAnim.t0 = now;
      const u = clamp((now - snapAnim.t0) / 180, 0, 1);
      S.az = snapAnim.from + (snapAnim.to - snapAnim.from) * (1 - Math.pow(1 - u, 3));
      if (u >= 1) { S.az = wrap(snapAnim.to); snapAnim = null; }
      renderPlace();
    }
    if (entrance) {
      const u = entrance.t0 ? Math.min(1, (now - entrance.t0) / MOVE_MS) : 0, e = u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2;
      cam.yaw = entrance.yaw + (cam.tYaw - entrance.yaw) * e;
      cam.lift = entrance.lift + (cam.tLift - entrance.lift) * e;
      cam.zoom = entrance.zoom + (cam.tZoom - entrance.zoom) * e;
    } else if (dragging === "look") {
      // close behind the finger (about 20 ms), smooth at any frame rate
      const f = 1 - Math.exp(-dt / 0.02);
      cam.yaw += (cam.tYaw - cam.yaw) * f; cam.lift += (cam.tLift - cam.lift) * f;
      cam.zoom += (cam.tZoom - cam.zoom) * Math.min(1, dt * 6);
    } else {
      cam.yaw += (cam.tYaw - cam.yaw) * Math.min(1, dt * 5);
      cam.lift += (cam.tLift - cam.lift) * Math.min(1, dt * 5);
      cam.zoom += (cam.tZoom - cam.zoom) * Math.min(1, dt * 6);
    }
    cam.k += (cam.tK - cam.k) * Math.min(1, dt * 3.5);
    camMoving = !!(entrance && entrance.t0) || !!fling || Math.abs(cam.tYaw - cam.yaw) + Math.abs(cam.tLift - cam.lift) + Math.abs(cam.tZoom - cam.zoom) + Math.abs(cam.tK - cam.k) > 0.002;
    if (bench && bench.on) { // the speed test turns the room the same way every time
      const u = ((now - bench.t0) / 2400) % 1;
      cam.yaw = cam.tYaw = -0.6 + 1.2 * (0.5 - 0.5 * Math.cos(u * Math.PI * 2));
    }
    placeCamera();

    const point = S.mode === "point";
    source.visible = beam.visible = sourceGlow.visible = point;
    orbit.visible = point && S.motion === "orbit";
    guides.visible = point && (S.panel === "place" || dragging === "source");
    speakers.visible = !point;
    speakerMid.set(0, 0, 0);
    let shownSpeakers = 0;
    speakerFx.forEach((sp, i) => {
      const pose = speakerPose(i);
      sp.group.visible = !!pose;
      sp.enabled = !!pose;
      if (!pose) return;
      const p = RoomMath.toRoom(pose.az, pose.el, pose.dist);
      if (i < 2 && (sp.x !== p[0] || sp.y !== p[1] || sp.z !== p[2])) three.renderer.shadowMap.needsUpdate = true;
      [sp.x, sp.y, sp.z] = p;
      sp.group.position.set(p[0], 0, p[2]);
      sp.cab.position.y = p[1]; sp.cab.lookAt(0, EAR, 0);
      sp.stand.visible = p[1] > 0.24;
      sp.stand.scale.y = Math.max(0.03, (p[1] - 0.235) / (EAR - 0.235));
      sp.selected.visible = S.panel === "place" && i === (speakerDraft ? speakerDraft.index : S.selectedSpeakerIndex);
      speakerMid.x += p[0]; speakerMid.y += p[1]; speakerMid.z += p[2]; shownSpeakers++;
    });
    if (shownSpeakers) speakerMid.multiplyScalar(1 / shownSpeakers);
    if (lastMode !== S.mode) { lastMode = S.mode; three.renderer.shadowMap.needsUpdate = true; } // the 2.0 speakers cast shadows
    const P = sourcePos(v);
    source.position.copy(P);
    const glowAmt = sounding ? 1 + level * 0.8 : 0.25;
    dome.material.emissiveIntensity += (1.4 * glowAmt - dome.material.emissiveIntensity) * Math.min(1, dt * 6);
    blue.position.copy(point ? P : speakerMid);
    const blueTo = point ? (sounding ? 1.1 + level * 0.9 : 0.15) : (sounding ? 1.0 + level * 0.6 : 0.12);
    blue.intensity += (blueTo - blue.intensity) * Math.min(1, dt * 6);
    halo.material.opacity = 0.18 + 0.4 * Math.min(1, glowAmt);
    beamGeo.attributes.position.setXYZ(0, P.x, P.y - 0.03, P.z);
    beamGeo.attributes.position.setXYZ(1, P.x, 0.01, P.z);
    beamGeo.attributes.position.needsUpdate = true;
    beam.computeLineDistances();
    const hr = Math.hypot(P.x, P.z);
    orbit.scale.set(Math.max(0.01, hr), 1, Math.max(0.01, hr)); orbit.position.y = P.y;
    const footGlow = (m, x, z, s, o) => { m.position.set(x, 0.012, z); m.scale.set(s, s, 1); m.material.opacity = o; };
    footGlow(sourceGlow, P.x, P.z, 1.2 + Math.max(0, 1.6 - P.y) * 0.4, sounding ? 0.35 + level * 0.25 : 0.12);
    const ripple = (rings, x, y, z, on, phase, maxR) => rings.forEach((m, i) => {
      const t = ((now / 3000) + i / rings.length + phase) % 1;
      const r = 0.18 + t * maxR;
      m.visible = on && !reduced;
      m.position.set(x, y, z); m.scale.set(r, r, r);
      m.material.opacity = 0.55 * Math.pow(1 - t, 1.5) * (0.5 + level * 0.7);
    });
    ripple(sourceRings, P.x, P.y - 0.01, P.z, point && hearing, 0, 0.75);
    speakerFx.forEach((s, k) => {
      ripple(s.rings, s.x, s.y, s.z, !point && s.enabled && hearing, k * 0.17, 0.6);
      footGlow(s.glow, s.x, s.z, 1.3, sounding ? 0.3 + level * 0.2 : 0.08);
      s.glow.visible = !point && s.enabled;
    });

    if (three.grade) three.grade.uniforms.time.value = (now / 1000) % 100;
    if (!reduced) {
      const tt = (now / 1000) % 3600;
      three.water.material.uniforms.time.value = tt;
      three.sparkles.material.uniforms.time.value = tt;
    }
    const flick = reduced ? 0.9 : 0.85 + 0.1 * Math.sin(now * 0.021) + 0.06 * Math.sin(now * 0.053 + 1.3) + 0.04 * Math.random();
    three.flame.scale.set(0.028, 0.06 * flick, 1);
    three.candleLight.intensity = 0.5 * flick;
    three.skipReflection = !active && perf.frames % 2 === 1; // reflection at 15 fps while idle
    const undoOpening = applyOpening(now, point);
    three.renderer.info.reset();
    if (three.composer && quality.effective !== "light") three.composer.render(); else three.renderer.render(three.scene, three.camera);
    if (undoOpening) undoOpening();
    perf.draws = three.renderer.info.render.calls; perf.tris = three.renderer.info.render.triangles;
    if (input && input.used) { const lag = performance.now() - input.ts; if (lag > 0 && lag < 500) { perf.touch.n++; perf.touch.t += lag; } input.used = 0; }
    if (perf.texturesFrame && !perf.compiled && perf.frames > perf.texturesFrame) {
      // Build every shader now, hidden parts too (2.0 speakers, guides, orbit
      // ring, ripples), so showing them later never freezes the room.
      const t = performance.now(); three.renderer.compile(three.scene, three.camera); warmRender(); perf.compiled = performance.now() - t;
      perf.warmFrame = perf.frames;
    }
    if (!perf.firstFrame) { perf.firstIndex = perf.frames; perf.firstFrame = now; perf.firstDone = performance.now(); revealRoom(); send({ t: "ready", v: 1 }); }

    if (guides.visible || labelsShown) { // labels are written only while they show (or once to hide them)
      labelsShown = guides.visible;
      labelDefs.forEach((d, i) => {
        const el = labelEls[i];
        if (!guides.visible) { el.style.display = "none"; return; }
        v.set(...d.p).project(three.camera);
        const [x, y] = screenOf(v);
        el.style.display = v.z > 1 ? "none" : "";
        el.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px) translate(-50%, -50%)`;
      });
    }
    if (point && S.screen === "room" && (S.panel === "place" || dragging === "source")) {
      sourcePos(v); v.y += 0.28; v.project(three.camera);
      const [x, y] = screenOf(v);
      tagEl.style.display = v.z > 1 ? "none" : ""; tagShown = true;
      tagEl.textContent = `${fmtAz(S.az)} · ${fmtEl(S.el)} · ${fmtDist(S.dist)}`;
      tagEl.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px) translate(-50%, -100%)`;
      if (S.panel === "place" && innerWidth > 700 && isOpen($("pop"))) {
        // never cover the sound you're placing
        sourcePos(v); v.project(three.camera);
        const [sx, sy] = screenOf(v), sc = $("scene").getBoundingClientRect(), r = $("pop").getBoundingClientRect();
        const px = sc.left + sx, py = sc.top + sy;
        if (px > r.left - 36 && px < r.right + 36 && py > r.top - 36 && py < r.bottom + 36) {
          const want = px > sc.left + sc.width / 2 ? "left" : "right";
          if (want !== popSide) { popSide = want; placePop(); }
        }
      }
    } else if (tagShown) { tagEl.style.display = "none"; tagShown = false; }
  }
}

// ---------------------------------------------------------------- input
let dragging = null, downAt = null, moved = 0, startCam = null, pinch = null, vel = null, lastTap = null;
let input = null, glRect = null, grab = [0, 0]; // the latest finger position, applied once per frame
const pointers = new Map();
const ndc = (x, y) => ({ x: (x / W) * 2 - 1, y: -(y / H) * 2 + 1 });
const local = (e) => { const r = glRect || $("gl").getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
// Past a limit the room still gives a little, with growing resistance, and
// springs back when you let go, instead of stopping dead.
const band = (v, lo, hi, give) => { const r = (o) => give * (1 - 1 / (1 + (o / give) * 0.55)); return v < lo ? lo - r(lo - v) : v > hi ? hi + r(v - hi) : v; };
const YAW_LIM = [-0.8, 0.8], LIFT_LIM = [8 * DEG, 28 * DEG];
// Fingers report about 60 times a second, the screen draws up to 120: the
// latest finger position is applied here, once per frame, and the camera
// follows it smoothly, so the room moves on every frame instead of every other.
function applyInput(now) {
  if (!input || !input.fresh || !three) return;
  input.fresh = false; input.used = performance.now();
  if (dragging === "pinch" && pointers.size === 2) {
    const [a, b] = [...pointers.values()];
    cam.tZoom = clamp((pinch.z * pinch.d) / Math.max(20, Math.hypot(a[0] - b[0], a[1] - b[1])), 0.82, 1.25);
  } else if (dragging === "speaker") moveSpeakerTo(input.x + grab[0], input.y + grab[1]);
  else if (dragging === "source") moveSourceTo(input.x + grab[0], input.y + grab[1], 0);
  else if (dragging === "look" && downAt && moved > 4 && cam.tK === 0) {
    cam.tYaw = band(startCam.yaw - (input.x - downAt[0]) * 0.0042, YAW_LIM[0], YAW_LIM[1], 0.12);
    cam.tLift = band(startCam.lift + (input.y - downAt[1]) * 0.0026, LIFT_LIM[0], LIFT_LIM[1], 0.07);
    // smoothed velocity, for the glide after you let go
    if (vel && now > vel.t) { const k = 1 / (now - vel.t); vel = { t: now, yaw: 0.7 * (cam.tYaw - vel.y0) * k + 0.3 * vel.yaw, lift: 0.7 * (cam.tLift - vel.l0) * k + 0.3 * vel.lift, y0: cam.tYaw, l0: cam.tLift }; }
    else if (!vel) vel = { t: now, yaw: 0, lift: 0, y0: cam.tYaw, l0: cam.tLift };
  }
}
const canMove = () => S.mode === "point" && !$("app").classList.contains("locked") && S.screen === "room";
function moveSourceTo(x, y, planeY) {
  const { T, raycaster, camera } = three;
  raycaster.setFromCamera(ndc(x, y), camera);
  const p = new T.Vector3();
  if (!raycaster.ray.intersectPlane(new T.Plane(new T.Vector3(0, 1, 0), -planeY), p)) return false;
  const at = RoomMath.fromRoomPoint(p.x, p.z, S.el);
  if (!at) return false;
  S.dist = at.d;
  if (S.motion !== "orbit") S.az = at.az;
  renderPlace();
  return true;
}
// Use the same floor-projected drag as Point. Elevation is preserved. Near
// vertical poles use sliders: the existing inverse floors cos(el) at 0.2.
function moveSpeakerTo(x, y) {
  if (!speakerDraft || Math.abs(Math.cos(speakerDraft.el * DEG)) < 0.2) return false;
  const { T, raycaster, camera } = three;
  raycaster.setFromCamera(ndc(x, y), camera);
  const p = new T.Vector3();
  if (!raycaster.ray.intersectPlane(new T.Plane(new T.Vector3(0, 1, 0), 0), p)) return false;
  const at = RoomMath.fromRoomPoint(p.x, p.z, speakerDraft.el);
  if (!at) return false;
  speakerDraft.az = at.az; speakerDraft.dist = at.d;
  renderSpeakerPlace(); return true;
}
function bindInput() {
  const gl = $("gl");
  gl.addEventListener("pointerdown", (e) => {
    revealRoom(); finishOpening(); // a touch skips the opening
    try { gl.setPointerCapture(e.pointerId); } catch (err) { /* pointer already gone */ }
    glRect = gl.getBoundingClientRect(); // measured once per touch, not on every move
    const [x, y] = local(e);
    pointers.set(e.pointerId, [x, y]);
    if (pointers.size === 2) { speakerDraft = null; const [a, b] = [...pointers.values()]; pinch = { d: Math.hypot(a[0] - b[0], a[1] - b[1]), z: cam.tZoom }; dragging = "pinch"; return; }
    downAt = [x, y]; moved = 0; startCam = { yaw: cam.tYaw, lift: cam.tLift }; vel = null; fling = null;
    dragging = "look";
    if (canMove()) { three.raycaster.setFromCamera(ndc(x, y), three.camera); if (three.raycaster.intersectObject(three.hit).length) dragging = "source"; }
    if (canEditSpeakers() && S.screen === "room") {
      three.raycaster.setFromCamera(ndc(x, y), three.camera);
      const hit = three.raycaster.intersectObjects(three.speakerFx.filter(s => s.enabled).map(s => s.cab), true)[0];
      if (hit) {
        let obj = hit.object;
        while (obj && obj.userData.speakerIndex === undefined) obj = obj.parent;
        if (obj && beginSpeaker(obj.userData.speakerIndex)) {
          dragging = "speaker";
          const p = RoomMath.toRoom(speakerDraft.az, speakerDraft.el, speakerDraft.dist);
          const foot = new three.T.Vector3(p[0], 0, p[2]).project(three.camera), [fx, fy] = screenOf(foot);
          grab = [fx - x, fy - y]; renderSpeakerPlace();
        }
      }
    }
    if (dragging === "source") {
      // Drag by the sound's floor point (the foot of its dotted line), kept at the
      // same offset from the finger. The floor is always below the camera, so the
      // drag stays steady even when the sound floats above eye level.
      const foot = sourcePos(new three.T.Vector3()).setY(0).project(three.camera), [fx, fy] = screenOf(foot);
      grab = [fx - x, fy - y];
    }
    act(dragging === "source" ? "drag the sound" : "touch the room");
    gl.classList.add("dragging");
  });
  gl.addEventListener("pointermove", (e) => {
    if (!pointers.has(e.pointerId)) return;
    const [x, y] = local(e);
    pointers.set(e.pointerId, [x, y]);
    if (downAt) moved = Math.max(moved, Math.hypot(x - downAt[0], y - downAt[1]));
    input = { x, y, ts: e.timeStamp, fresh: true };
    if (dragging) perf.touchMoves++;
  });
  const end = (e) => {
    pointers.delete(e.pointerId);
    if (dragging === "pinch") { if (!pointers.size) dragging = null; return; }
    if (!dragging) return;
    const [x, y] = local(e);
    applyInput(performance.now()); // a move that arrived after the last frame still counts
    if (dragging === "look") { cam.tYaw = clamp(cam.tYaw, YAW_LIM[0], YAW_LIM[1]); cam.tLift = clamp(cam.tLift, LIFT_LIM[0], LIFT_LIM[1]); } // spring back inside the limits
    if (dragging === "speaker") {
      if (e.type === "pointercancel" || !speakerDraft) { speakerDraft = null; renderSpeakerPlace(); }
      else if (moved < 5) { const index = speakerDraft.index; speakerDraft = null; speakerIntent("speakerSelect", { index }); }
      else commitSpeaker();
    }
    else if (dragging === "source") { snapDirection(); commitPlace(); }
    else if (moved < 5 && canMove() && S.panel === "place" && moveSourceTo(x, y, 0)) { snapDirection(); commitPlace(); }
    else if (dragging === "look") {
      if (moved < 5) {
        if (S.panel && S.panel !== "place") closePop(); // a tap on the room closes Layout, Motion and the room card
        const t = performance.now();
        if (lastTap && t - lastTap.t < 330 && Math.hypot(x - lastTap.x, y - lastTap.y) < 30 && S.panel !== "place") { resetView(); lastTap = null; } // double-tap: back to the normal view
        else lastTap = { t, x, y };
      } else if (!reduced && vel && performance.now() - vel.t < 90) fling = { yaw: vel.yaw * 0.35, lift: vel.lift * 0.35 };
    }
    dragging = null; downAt = null; glRect = null; input = null;
    gl.classList.remove("dragging");
  };
  gl.addEventListener("pointerup", end);
  gl.addEventListener("pointercancel", end);
  gl.addEventListener("wheel", (e) => { e.preventDefault(); cam.tZoom = clamp(cam.tZoom * Math.exp(e.deltaY * 0.001), 0.82, 1.25); }, { passive: false });
  gl.addEventListener("dblclick", resetView);
}

// ---------------------------------------------------------------- the 3D view lost and back
// iPadOS can take the GPU away (a reset, or the app in the background for a
// long time). The room shows its calm veil, then rebuilds itself when the GPU
// returns. Sound position, layout, camera and every setting live outside the
// 3D scene, so nothing is lost. If it can't come back, the still picture stays.
function roomLost(e) {
  e.preventDefault(); // tell the browser we want the context back
  if (!three) return;
  act("3D view lost");
  three.lost = true;
  try { three.renderer.dispose(); } catch (err) { /* already gone */ }
  const veil = $("veil"); veil.hidden = false; veil.classList.remove("gone"); $("veil-note").textContent = "Restoring the room…";
}
function roomRestored() {
  act("3D view restored");
  try {
    Object.assign(perf, { texturesFrame: 0, compiled: 0, warmFrame: 0, restoring: true });
    three = null; buildScene(); applyQuality(quality.effective); measure();
    $("veil-note").textContent = "";
  } catch (err) {
    console.error("Yinwei 3D room could not come back", err);
    three = null; showStill(); send({ t: "error", msg: "webgl-restore" });
  }
}
function showStill() {
  $("scene").classList.add("still");
  const veil = $("veil"); veil.classList.add("gone"); veil.hidden = true;
  $("app").classList.remove("intro", "intro-run"); revealed = revealed || performance.now(); // controls stay usable
  $("fallback").hidden = false;
}
$("gl").addEventListener("webglcontextlost", roomLost);
$("gl").addEventListener("webglcontextrestored", roomRestored);

// ---------------------------------------------------------------- start
render();
try {
  buildScene(); perf.built = performance.now(); bindInput();
  const ro = new ResizeObserver(() => measure());
  ["scene", "player", "side"].forEach((id) => ro.observe($(id)));
  addEventListener("resize", measure);
  measure();
} catch (err) {
  console.error("Yinwei 3D room could not start", err);
  three = null;
  showStill();
  send({ t: "error", msg: "webgl" });
}
requestAnimationFrame(frame);
