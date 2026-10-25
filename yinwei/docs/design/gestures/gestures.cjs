// Review only (inlined by tools/listen_room_review.py, never part of the app): hand-gesture control
// through the laptop webcam, to try gestures before an iPad version is built.
// Off until you turn it on with the hand button (top right) and allow the camera. Frames are analysed
// in this browser by MediaPipe's gesture recogniser and never stored or sent; turning it off stops
// the camera. The recogniser (script, WASM and model, ~10 MB) loads from the public CDNs on first use.
//
// Gestures -> the page's own actions (no new paths into playback):
//   open palm, held      album -> quick menu
//   fist, held           quick menu -> album; window mode -> quick menu
//   victory (V), held    quick menu -> window mode
//   thumb up, held       play / pause
//   swipe left / right   next / previous song
//   swipe up / down      browse the quick menu
// Tuning: GESTURE below. The core (createGestureCore) is pure, so it is tested with recorded-style data.
(function () {
  const GESTURE = {
    hold: { Open_Palm: 500, Closed_Fist: 400, Victory: 450, Thumb_Up: 500 }, // ms a pose must be held still
    minScore: 0.6,     // recogniser confidence for a pose
    still: 0.45,       // a held pose may drift this many hand-sizes before the hold restarts
    // Swipes are judged one stroke at a time: a stroke starts when the hand speeds up and ends when it
    // stops, turns back, or leaves. Distances and speeds are in hand-sizes (wrist to middle knuckle),
    // so they hold at any distance from the camera. Tuned from the owner's measured swipes (2026-10-24):
    // natural swipes travel 0.45-0.8 hand-sizes at a peak of 3.5-8 hand-sizes/s; fidgets peak below 3.
    swipeHands: 0.45,  // a left/right stroke must travel this many hand-sizes...
    swipeHandsV: 0.4,  // ...an up/down stroke this many
    swipeMin: 0.045,   // ...and at least this fraction of the frame (so finger twitches never count)
    swipeSpeed: 3,     // ...reaching this peak speed (hand-sizes per second)
    swipeRatio: 1.2,   // ...mostly along one axis
    strokeMs: 900,     // ...within this time from its start
    startSpeed: 1.5,   // a stroke starts above this speed...
    stopSpeed: 0.8,    // ...and ends after two frames below this one
    turnBack: 0.15,    // ...or once the hand has come back this many hand-sizes from its farthest point
    fastSpeed: 2.4,    // a flick whose average speed (hand-sizes/s) beats this may be shorter: distance x fastSpeed / speed...
    fastPart: 0.65,    // ...down to this share of it (very fast flicks)
    straight: 0.6,     // a stroke must be this straight (start-to-farthest / path walked): jitter never is
    minMoving: 2,      // ...and move over at least this many frames (a one-frame jump is a tracking glitch, not a flick)
    returnMs: 600,     // the stroke back the other way right after a real flick is ignored (the return)
    exitSpeed: 4,      // a hand moving this fast that blurs out or leaves the frame...
    exitPart: 0.7,     // ...after this share of the distance still counts
    lostMs: 250,       // the hand may vanish this long (motion blur) without ending the stroke
    cooldown: 400,     // ms after an action before the next one (the return stroke is handled separately)
    fps: 30,           // frames analysed per second
  };

  // One frame in: { t (ms), hand (bool), g (gesture name or null), score, x, y, s } with x, y the palm
  // centre in the user's own view (frame-width units, x to the user's right, y down) and s the hand
  // size. Out: { event, hold, motion, stroke } - motion: progress towards a swipe (0..1, for the
  // preview); stroke: when a stroke ends, what it was and why it did or did not count (the panel).
  function createGestureCore(cfg) {
    const c = cfg || GESTURE;
    let hold = null, lastFire = -1e9, lastSeen = -1e9, prev = null, st = null, last = null, prevEnd = null;
    const sizes = [];
    const size = () => (sizes.length ? Math.max(0.04, sizes.reduce((a, b) => a + b, 0) / sizes.length) : 0.1);
    // A stroke's direction and how it measures against the rules.
    function judge(k) {
      const s = k.sSum / k.sN, dx = k.x1 - k.x0, dy = k.y1 - k.y0, horiz = Math.abs(dx) >= Math.abs(dy);
      const main = horiz ? Math.abs(dx) : Math.abs(dy), cross = horiz ? Math.abs(dy) : Math.abs(dx);
      const avg = k.far / s / Math.max(0.033, (k.tFar - k.t0) / 1000); // average speed to the farthest point
      const fast = Math.min(1, Math.max(c.fastPart, c.fastSpeed / Math.max(1e-3, avg))); // 1 for ordinary speeds
      const need = Math.max((horiz ? c.swipeHands : c.swipeHandsV) * s * fast, c.swipeMin * (horiz ? 1 : 0.8));
      return { event: horiz ? (dx < 0 ? "swipeLeft" : "swipeRight") : (dy < 0 ? "swipeUp" : "swipeDown"), horiz, sign: Math.sign(horiz ? dx : dy), main, need, ratio: main / Math.max(1e-6, cross), s, eff: k.path > 0 ? Math.min(1, k.far / k.path) : 1 };
    }
    // Straight back along the same axis right after a real flick: the return of that flick.
    const isReturn = (j) => !!last && last.real && last.horiz === j.horiz && last.sign === -j.sign && st.t0 - last.tEnd < c.returnMs;
    // Can the stroke in progress fire now (part: share of the distance needed)?
    function check(t, part) {
      const j = judge(st);
      if (j.main < j.need * part || j.ratio < c.swipeRatio || st.peak < c.swipeSpeed || j.eff < c.straight || st.moving < c.minMoving || st.tl - st.t0 > c.strokeMs) return null;
      if (isReturn(j)) { st.why = "回程忽略"; return null; }
      if (t - lastFire < c.cooldown) { st.why = "冷却中"; return null; }
      return j;
    }
    function endStroke(end) {
      const j = judge(st), DIR = { swipeLeft: "←", swipeRight: "→", swipeUp: "↑", swipeDown: "↓" };
      // Every rule the stroke missed, so the panel shows the whole story (e.g. "距离不够 · 速度不够").
      const miss = [st.lost * 3 >= st.frames && st.lost >= 2 && "手丢失太多", j.main < j.need && "距离不够", st.peak < c.swipeSpeed && "速度不够",
        j.ratio < c.swipeRatio && "方向太斜", j.eff < c.straight && "轨迹抖动", st.tl - st.t0 > c.strokeMs && "动作太慢"].filter(Boolean);
      const why = st.fired ? "已触发" : miss.length ? miss.join(" · ") : st.why || "未触发";
      const sum = { dir: DIR[j.event], travel: +(j.main / j.s).toFixed(2), need: +(j.need / j.s).toFixed(2), ratio: +Math.min(99, j.ratio).toFixed(1),
        ms: Math.round(st.tl - st.t0), peak: +st.peak.toFixed(1), frames: st.frames, lost: st.lost, handSize: +j.s.toFixed(3), straight: +j.eff.toFixed(2), fired: st.fired, end, why,
        t: Math.round(st.t0), gap: prevEnd === null ? null : Math.max(0, Math.round(st.t0 - prevEnd)) }; // start, and the pause since the previous stroke ended (ms)
      prevEnd = st.tl;
      // A real flick (fast, and most of the way) makes the stroke straight back a "return" for a moment;
      // a stroke that was itself ignored as a return does not, so left-left-left still works.
      last = { horiz: j.horiz, sign: j.sign, tEnd: st.tl, real: !st.fired && isReturn(j) ? false : st.peak >= c.swipeSpeed && j.main >= j.need * 0.5 };
      st = null;
      return sum;
    }
    const progress = () => { if (!st || st.fired) return 0; const j = judge(st); return Math.min(1, j.main / j.need) * Math.min(1, st.peak / c.swipeSpeed); };
    return function feed(f) {
      if (!f.hand) {
        hold = null;
        if (!st) { if (f.t - lastSeen > c.lostMs) prev = null; return { event: null, hold: null, motion: 0, stroke: null }; }
        st.frames++; st.lost++;
        if (f.t - lastSeen > c.lostMs) { prev = null; return { event: null, hold: null, motion: 0, stroke: endStroke("手离开画面") }; }
        // Blurred out or left the frame while moving fast and most of the way there: that was the swipe.
        if (!st.fired && Math.max(...st.recent) >= c.exitSpeed) { // (fastest of the last 3 frames: a hand often looks slower just before it is lost)
          const j = check(f.t, c.exitPart);
          if (j) { st.fired = j.event; lastFire = f.t; return { event: j.event, hold: null, motion: 1, stroke: endStroke("手离开画面") }; }
        }
        return { event: null, hold: null, motion: 0, stroke: null };
      }
      if (f.t - lastSeen > c.lostMs) prev = null; // a new appearance starts fresh
      lastSeen = f.t;
      sizes.push(f.s || 0.1); if (sizes.length > 15) sizes.shift();
      const s = size();
      let v = 0, fx = 0, fy = 0, stroke = null, event = null;
      if (prev) { fx = f.x - prev.x; fy = f.y - prev.y; v = Math.hypot(fx, fy) / s / Math.max(0.001, (f.t - prev.t) / 1000); }
      // A stroke is judged from its start to its farthest point (x1, y1). It ends as a turn-back only
      // once the hand has really come back (turnBack hand-sizes) while moving back: one noisy frame at
      // speed no longer splits a fast flick in two. The way back is a stroke of its own.
      const begin = (a, b, va) => ({ t0: a.t, x0: a.x, y0: a.y, x1: b.x, y1: b.y, far: Math.hypot(b.x - a.x, b.y - a.y), path: Math.hypot(b.x - a.x, b.y - a.y), tFar: b.t, tl: b.t, peak: va, recent: [va], slow: 0, moving: 1,
        sSum: (a.s || s) + (b.s || s), sN: 2, frames: 2, lost: 0, fired: null, why: null });
      if (st) {
        st.tl = f.t; st.peak = Math.max(st.peak, v); st.recent.push(v); if (st.recent.length > 3) st.recent.shift();
        st.sSum += f.s || s; st.sN++; st.frames++; st.slow = v < c.stopSpeed ? st.slow + 1 : 0; if (v >= c.stopSpeed) st.moving++; st.path += Math.hypot(fx, fy);
        const d = Math.hypot(f.x - st.x0, f.y - st.y0);
        if (d >= st.far) { st.far = d; st.x1 = f.x; st.y1 = f.y; st.tFar = f.t; }
        else if (st.far - d >= c.turnBack * s && v >= c.startSpeed && fx * (st.x1 - st.x0) + fy * (st.y1 - st.y0) < 0) {
          const from = { t: st.tFar, x: st.x1, y: st.y1, s: f.s };
          st.tl = st.tFar; stroke = endStroke("折返");
          st = begin(from, f, v);
        }
      } else if (prev && v >= c.startSpeed) st = begin(prev, f, v);
      prev = f;
      const g = f.g && f.score >= c.minScore ? f.g : null;
      if (hold && hold.g !== g) hold = null; // you let go of the pose (noticed even during the cooldown)
      if (st && !st.fired) { const j = check(f.t, 1); if (j) { st.fired = j.event; lastFire = f.t; hold = null; event = j.event; } }
      const motion = event ? 1 : progress();
      if (st && (st.slow >= 2 || st.tl - st.t0 > 1500)) stroke = endStroke(st.slow >= 2 ? "停下" : "超时");
      if (event) return { event, hold: null, motion, stroke };
      if (f.t - lastFire < c.cooldown) return { event: null, hold: null, motion, stroke }; // (a pose still shown stays fired)
      const need = g ? c.hold[g] : 0;
      if (!need) { hold = null; return { event: null, hold: null, motion, stroke }; }
      if (!hold || hold.g !== g || Math.hypot(f.x - hold.x, f.y - hold.y) > c.still * s) {
        if (hold && hold.g === g && hold.fired) return { event: null, hold: null, motion, stroke }; // still showing a pose that already fired
        hold = { g, t0: f.t, x: f.x, y: f.y, fired: false };
      }
      if (hold.fired) return { event: null, hold: null, motion, stroke }; // let go of the pose before it fires again
      const p = Math.min(1, (f.t - hold.t0) / need);
      if (p >= 1) { hold.fired = true; lastFire = f.t; return { event: g, hold: { g, p: 1 }, motion: 0, stroke }; }
      return { event: null, hold: { g, p }, motion, stroke };
    };
  }
  // The measurement panel's log: the detector's own strokes (out.stroke), newest first.
  function createSwipeLog() {
    const log = [];
    return { log, feed(f, out) { if (!out || !out.stroke) return null; log.unshift(out.stroke); if (log.length > 30) log.pop(); return out.stroke; } };
  }
  // Calibration: the guided test records, per prompt, the strokes made while it asked for one
  // direction (and the strokes in the short "get ready" pause before it, where the hand comes back
  // from the previous one), plus an up-down-up-down run. From that: a hit-rate report per direction,
  // and settings tuned to this person (about 70% of their own typical swipe), each kept in a sane range.
  // rec = { prompts: [{ dir, strokes, fired, prep, back }], alt: { strokes, fired } }; cfg = the current settings;
  // caps = the defaults: calibration only ever makes swipes easier than these (people swipe bigger when prompted
  // than in everyday use, so raising a threshold from a test would make everyday swipes miss).
  function analyseCalibration(rec, cfg, caps) {
    const cap = caps || cfg;
    const NAME = { "←": "swipeLeft", "→": "swipeRight", "↑": "swipeUp", "↓": "swipeDown" }, OPP = { "←": "→", "→": "←", "↑": "↓", "↓": "↑" };
    const med = (a) => { if (!a.length) return null; const s = [...a].sort((x, y) => x - y), m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
    const lim = (v, lo, hi) => Math.min(hi, Math.max(lo, v)), r2 = (v) => Math.round(v * 100) / 100;
    const rows = [], TH = [], TV = [], P = [], R = [];
    for (const dir of ["←", "→", "↑", "↓"]) {
      const ps = rec.prompts.filter((p) => p.dir === dir), travel = [], peak = [];
      let hit = 0, wrong = 0, none = 0;
      for (const p of ps) {
        if (p.fired.includes(NAME[dir])) hit++;
        wrong += p.fired.filter((e) => e !== NAME[dir]).length;
        const best = p.strokes.filter((s) => s.dir === dir).sort((a, b) => b.travel - a.travel)[0];
        if (!best) { none++; continue; }
        travel.push(best.travel); peak.push(best.peak); R.push(best.ratio); P.push(best.peak);
        (dir === "←" || dir === "→" ? TH : TV).push(best.travel);
      }
      rows.push({ dir, tries: ps.length, hit, wrong, noStroke: none, travel: med(travel), peak: med(peak) });
    }
    // The bring-back after each prompt: strokes in the next prompt's "get ready" pause, opposite to it.
    const retGaps = [];
    rec.prompts.forEach((p, i) => {
      for (const s of p.back || []) if (s.dir === OPP[p.dir] && s.gap !== null) retGaps.push(s.gap); // right after the swipe
      const before = i ? rec.prompts[i - 1].dir : null;
      for (const s of p.prep || []) if (before && s.dir === OPP[before] && s.gap !== null) retGaps.push(s.gap); // or in the next "get ready"
    });
    // The deliberate up-down-up-down: every clear stroke there was meant to count.
    const alt = rec.alt ? rec.alt.strokes.filter((s) => s.travel >= 0.25 && s.peak >= 2) : [];
    const altGaps = alt.slice(1).map((s) => s.gap).filter((g) => g !== null);
    const altHit = rec.alt ? rec.alt.fired.length : 0;
    const tuned = {
      swipeHands: TH.length ? r2(lim(0.7 * med(TH), 0.25, cap.swipeHands)) : cfg.swipeHands,
      swipeHandsV: TV.length ? r2(lim(0.7 * med(TV), 0.25, cap.swipeHandsV)) : cfg.swipeHandsV,
      swipeSpeed: P.length ? Math.round(lim(0.7 * med(P), 2.2, cap.swipeSpeed) * 10) / 10 : cfg.swipeSpeed,
      swipeRatio: R.length ? r2(lim(0.85 * Math.min(...R), 1.05, cap.swipeRatio)) : cfg.swipeRatio,
      returnMs: cfg.returnMs,
    };
    const notes = [];
    // Return vs deliberate reverse swipe: only the pause can tell them apart.
    if (retGaps.length && altGaps.length) {
      const maxRet = Math.max(...retGaps), minAlt = Math.min(...altGaps);
      if (minAlt > maxRet + 60) { tuned.returnMs = Math.round((maxRet + minAlt) / 2); notes.push(`回程间隔 ≤ ${maxRet} ms，连续反向挥动间隔 ≥ ${minAlt} ms：可以区分，回程过滤设为 ${tuned.returnMs} ms`); }
      else notes.push(`回程（${Math.min(...retGaps)}–${maxRet} ms）和连续反向挥动（${minAlt}–${Math.max(...altGaps)} ms）的间隔重叠，无法区分：保持回程过滤（不会误触发反方向）。如果更想要连续上下挥动，可以关掉回程过滤`);
    } else notes.push("记录不足，回程过滤保持不变");
    for (const r of rows) if (r.noStroke) notes.push(`${r.dir}：有 ${r.noStroke} 次没有检测到明显的挥动（手可能出了画面或太慢）`);
    return { rows, tuned, notes, alt: { strokes: alt.length, fired: altHit, gaps: altGaps }, returnGaps: retGaps };
  }
  if (typeof module !== "undefined" && module.exports) { module.exports = { createGestureCore, createSwipeLog, analyseCalibration, GESTURE }; return; }
  if (typeof document === "undefined") return;

  // ------------------------------------------------------------ the page side
  const VISION = "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14";
  const MODEL = "https://storage.googleapis.com/mediapipe-models/gesture_recognizer/gesture_recognizer/float16/1/gesture_recognizer.task";
  const LABEL = { Open_Palm: "张开手掌", Closed_Fist: "握拳", Victory: "剪刀手", Thumb_Up: "竖拇指", Pointing_Up: "食指", Thumb_Down: "拇指向下", ILoveYou: "ILY" };
  const ACTION_TEXT = { Open_Palm: "打开快捷歌单", Closed_Fist: "收起", Victory: "在窗上展开", Thumb_Up: "播放 / 暂停", swipeLeft: "下一首", swipeRight: "上一首", swipeUp: "歌单 ↓", swipeDown: "歌单 ↑" };
  const $id = (id) => document.getElementById(id);
  const DEFAULTS = JSON.parse(JSON.stringify(GESTURE)), CAL_KEY = "yinwei.gestureCal";
  let calApplied = null; // { tuned, when } once a calibration is applied (kept in this browser)
  try { const saved = JSON.parse(localStorage.getItem(CAL_KEY) || "null"); if (saved && saved.tuned) { Object.assign(GESTURE, saved.tuned); calApplied = saved; } } catch (e) { /* storage blocked: defaults */ }
  let on = false, stream = null, recognizer = null, loading = null, lastRun = 0, lastFrameTime = -1, core = createGestureCore(GESTURE), raf = 0;
  // Measurement (the readout under the preview): counted per second, nothing here changes what fires.
  const D = { settings: null, cam: 0, ana: 0, anaMs: 0, page: 0, hand: 0, frames: 0, drops: 0, wasHand: false, light: null,
    perSec: { cam: 0, ana: 0, anaMs: 0, page: 0, handPct: 0 }, dropsWin: [], tSec: 0, tShow: 0, swipes: createSwipeLog() };
  const lumaCv = document.createElement("canvas"); lumaCv.width = 32; lumaCv.height = 24;

  // The page's own actions. Returns what it did (for the label), or "" when the gesture does nothing here.
  function act(ev) {
    const mode = typeof browseMode === "string" ? browseMode : "album";
    switch (ev) {
      case "Open_Palm": if (mode === "album") { setBrowseMode("compact"); return ACTION_TEXT.Open_Palm; } return "";
      case "Closed_Fist": if (mode === "window") { setBrowseMode("compact"); return "收起到快捷歌单"; } if (mode === "compact") { setBrowseMode("album"); return "关闭快捷歌单"; } return "";
      case "Victory": if (mode === "compact") { setBrowseMode("window"); return ACTION_TEXT.Victory; } return "";
      case "Thumb_Up": // confirm: the focused song in the quick menu, the browsed one on the windows; else play / pause
        if (mode === "compact") { const i = pkFocus; if (S.queue && i !== S.queue.playing) { pkSelect(i); return `播放：${S.queue.songs[i].title}`; } return "已在播放这首"; }
        if (mode === "window") { const i = winOffset; if (S.queue && i !== S.queue.playing) { winTap(i); return `播放：${S.queue.songs[i].title}`; } return "已在播放这首"; }
        $id("play").click(); return ACTION_TEXT.Thumb_Up;
      case "swipeLeft": $id("next").click(); return ACTION_TEXT.swipeLeft;
      case "swipeRight": $id("prev").click(); return ACTION_TEXT.swipeRight;
      case "swipeUp": if (mode === "compact") { pkBrowse(1); return ACTION_TEXT.swipeUp; } return "";
      case "swipeDown": if (mode === "compact") { pkBrowse(-1); return ACTION_TEXT.swipeDown; } return "";
    }
    return "";
  }

  // UI: a hand button in the top bar, a consent card, and a small mirrored preview with the pose, the
  // hold ring and the last action.
  const style = document.createElement("style");
  style.textContent = `
  #gesture-btn svg { width: 22px; height: 22px; } #gesture-btn[aria-pressed="true"] { background: rgba(120, 150, 255, 0.28); border-color: rgba(190, 205, 255, 0.5); }
  .gs-card { position: absolute; z-index: 9; right: 16px; top: 80px; width: 300px; padding: 18px; border-radius: 20px; color: var(--text); font-size: 14px; line-height: 1.5;
    background: rgba(14, 17, 26, 0.92); border: 1px solid rgba(255, 255, 255, 0.1); box-shadow: 0 20px 50px rgba(0, 0, 0, 0.45); }
  .gs-card p { margin: 0 0 12px; color: var(--text-2); } .gs-card b { display: block; margin-bottom: 8px; font-size: 16px; font-weight: 500; }
  .gs-card .row { display: flex; gap: 10px; justify-content: flex-end; } .gs-card button { min-height: 40px; padding: 0 16px; border-radius: 999px; color: var(--text); background: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.12); }
  .gs-card button.go { background: rgba(120, 150, 255, 0.35); }
  .gs-view { position: absolute; z-index: 8; right: 16px; bottom: 120px; width: 232px; border-radius: 18px; overflow: hidden; color: var(--text);
    background: rgba(10, 12, 18, 0.88); border: 1px solid rgba(255, 255, 255, 0.1); box-shadow: 0 16px 40px rgba(0, 0, 0, 0.45); font-size: 12px; }
  .gs-view .cam { position: relative; height: 174px; } .gs-view video, .gs-view canvas { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
  .gs-view video { transform: scaleX(-1); opacity: 0.85; }
  .gs-view .info { display: flex; align-items: center; gap: 10px; padding: 10px 12px; min-height: 44px; }
  .gs-view .meter { display: block; height: 3px; background: linear-gradient(90deg, rgba(200, 214, 255, 0.9) calc(var(--m, 0) * 100%), rgba(255, 255, 255, 0.08) 0); transition: background 0.06s linear; }
  .gs-view .ring { flex: none; width: 26px; height: 26px; border-radius: 50%; background: conic-gradient(rgba(200, 214, 255, 0.95) calc(var(--p, 0) * 1turn), rgba(255, 255, 255, 0.1) 0); -webkit-mask: radial-gradient(circle, transparent 8px, #000 9px); mask: radial-gradient(circle, transparent 8px, #000 9px); }
  .gs-view .txt { min-width: 0; } .gs-view .pose { font-size: 13px; } .gs-view .did { color: var(--text-2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .gs-view details { border-top: 1px solid rgba(255, 255, 255, 0.07); padding: 8px 12px 10px; color: var(--text-2); } .gs-view summary { cursor: pointer; color: var(--text); }
  .gs-view ul { margin: 6px 0 0; padding-left: 16px; line-height: 1.6; }
  .gs-view.flash .did { color: var(--text); }
  .gs-view .diag { padding: 0 12px 4px; font: 11px/1.55 ui-monospace, "SF Mono", Consolas, monospace; color: var(--text-2); white-space: pre-wrap; }
  .gs-view .diag b { color: var(--text); font-weight: 500; } .gs-view .diag .bad { color: #ffb4a8; } .gs-view .diag .ok { color: #b8f0c8; }
  .gs-view .tools { display: flex; gap: 8px; padding: 2px 12px 10px; } .gs-view .tools button { min-height: 30px; padding: 0 12px; border-radius: 999px; font-size: 12px; color: var(--text); background: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.12); }
  .gs-view { width: 300px; max-height: calc(100% - 140px); overflow-y: auto; }
  .gs-cal { position: absolute; z-index: 10; left: 50%; top: 50%; transform: translate(-50%, -50%); width: min(600px, calc(100% - 32px)); max-height: calc(100% - 40px); overflow-y: auto;
    padding: 26px 28px; border-radius: 24px; text-align: center; color: var(--text); background: rgba(10, 12, 18, 0.94); border: 1px solid rgba(255, 255, 255, 0.1); box-shadow: 0 30px 80px rgba(0, 0, 0, 0.55); }
  .gs-cal .arrow { font-size: 104px; line-height: 1.05; transition: opacity 0.2s ease, transform 0.2s ease; } .gs-cal.prep .arrow { opacity: 0.3; transform: scale(0.9); } .gs-cal.after .arrow { opacity: 0.55; }
  .gs-cal .title { font-size: 24px; margin-top: 6px; } .gs-cal .sub { margin-top: 6px; font-size: 14px; color: var(--text-2); min-height: 20px; }
  .gs-cal .bar { height: 4px; margin-top: 18px; border-radius: 2px; overflow: hidden; background: rgba(255, 255, 255, 0.1); } .gs-cal .bar i { display: block; height: 100%; width: var(--w, 0%); background: rgba(200, 214, 255, 0.9); }
  .gs-cal .step { margin-top: 8px; font-size: 12px; color: var(--text-3); }
  .gs-cal table { width: 100%; margin: 14px 0 6px; border-collapse: collapse; font-size: 13px; } .gs-cal th, .gs-cal td { padding: 6px 8px; text-align: left; border-bottom: 1px solid rgba(255, 255, 255, 0.08); }
  .gs-cal th { color: var(--text-2); font-weight: 500; } .gs-cal .good { color: #b8f0c8; } .gs-cal .poor { color: #ffb4a8; }
  .gs-cal ul { text-align: left; margin: 8px 0 0; padding-left: 18px; font-size: 13px; color: var(--text-2); line-height: 1.55; }
  .gs-cal .row { display: flex; flex-wrap: wrap; gap: 10px; justify-content: center; margin-top: 18px; }
  .gs-cal button { min-height: 40px; padding: 0 16px; border-radius: 999px; color: var(--text); background: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.12); } .gs-cal button.go { background: rgba(120, 150, 255, 0.35); }
  .gs-cal label { display: inline-flex; gap: 8px; align-items: center; margin-top: 10px; font-size: 13px; color: var(--text-2); }`;
  document.head.append(style);
  const btn = document.createElement("button");
  btn.className = "round"; btn.id = "gesture-btn"; btn.type = "button"; btn.setAttribute("aria-pressed", "false"); btn.setAttribute("aria-label", "Gesture control (camera)");
  btn.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 11V6.5a1.5 1.5 0 0 1 3 0V11M10 10V4.5a1.5 1.5 0 0 1 3 0V10M13 10V5.5a1.5 1.5 0 0 1 3 0V11M16 11V8.5a1.5 1.5 0 0 1 3 0V14a7 7 0 0 1-7 7h-.6a6 6 0 0 1-4.6-2.2L4.3 15.6a1.6 1.6 0 0 1 2.4-2.1L7 13.8V11" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const more = $id("more"); more.parentNode.insertBefore(btn, more);
  const app = $id("app");
  const card = document.createElement("div"); card.className = "gs-card"; card.hidden = true; card.setAttribute("role", "dialog"); card.setAttribute("aria-label", "Gesture control");
  card.innerHTML = '<b>手势控制（预览）</b><p>需要使用电脑摄像头。画面只在这个浏览器里分析，不会保存或发送；关闭后摄像头立即停止。首次使用会从网络加载识别模型（约 10 MB）。</p><div class="row"><button type="button" class="no">取消</button><button type="button" class="go">允许并开始</button></div>';
  const view = document.createElement("div"); view.className = "gs-view"; view.hidden = true; view.setAttribute("aria-live", "polite");
  view.innerHTML = '<div class="cam"><video playsinline muted></video><canvas></canvas></div><i class="meter" title="挥动进度"></i><div class="info"><i class="ring"></i><div class="txt"><div class="pose">正在启动…</div><div class="did"></div></div></div>'
    + '<details class="measure" open><summary>测量数据</summary><div class="diag">等待摄像头…</div><div class="tools"><button type="button" class="calib">校准</button><button type="button" class="copy">复制数据</button><button type="button" class="clear">清空记录</button><button type="button" class="reset">恢复默认</button></div></details>'
    + '<details><summary>手势说明</summary><ul><li>✋ 张开手掌停住：打开快捷歌单</li><li>✊ 握拳停住：收起</li><li>✌️ 剪刀手停住：在窗上展开</li><li>👍 竖拇指停住：歌单 / 窗景中＝播放选中的歌；其他时候＝播放 / 暂停</li><li>👈 向左挥：下一首 · 👉 向右挥：上一首</li><li>☝️ 上下挥（歌单打开时）：浏览，然后 👍 确认</li></ul></details>';
  app.append(card, view);
  const video = view.querySelector("video"), canvas = view.querySelector("canvas"), pose = view.querySelector(".pose"), did = view.querySelector(".did"), ring = view.querySelector(".ring"), meter = view.querySelector(".meter");
  const diagEl = view.querySelector(".diag");
  view.querySelector(".copy").onclick = async (e) => {
    const text = JSON.stringify(diagSnapshot(), null, 1);
    try { await navigator.clipboard.writeText(text); e.target.textContent = "已复制"; } catch (err) { console.log(text); e.target.textContent = "已输出到控制台"; }
    setTimeout(() => (e.target.textContent = "复制数据"), 1500);
  };
  view.querySelector(".clear").onclick = () => { D.swipes.log.length = 0; D.dropsWin.length = 0; renderDiag(); };
  function diagSnapshot() {
    return { when: new Date().toISOString(), settings: D.settings, perSecond: D.perSec, light: D.light, dropsLast10s: D.dropsWin.reduce((a, b) => a + b, 0),
      config: Object.fromEntries(Object.entries(GESTURE).filter(([k]) => k !== "hold")),
      calibration: { applied: calApplied, lastReport: CAL.last }, attempts: D.swipes.log.slice(0, 20) };
  }
  // Counted once a second: camera frames delivered, frames analysed (and ms each), page frames, the
  // share of analysed frames with a hand, and hand dropouts (a hand that vanishes) over the last 10 s.
  function diagSecond(now) {
    if (now - D.tSec < 1000) return;
    const k = 1000 / (now - D.tSec || 1000);
    D.perSec = { cam: Math.round(D.cam * k), ana: Math.round(D.ana * k), anaMs: D.ana ? +(D.anaMs / D.ana).toFixed(1) : 0, page: Math.round(D.page * k), handPct: D.frames ? Math.round((100 * D.hand) / D.frames) : 0 };
    D.dropsWin.push(D.drops); if (D.dropsWin.length > 10) D.dropsWin.shift();
    Object.assign(D, { cam: 0, ana: 0, anaMs: 0, page: 0, hand: 0, frames: 0, drops: 0, tSec: now });
    try { // average brightness of the camera picture (0 dark .. 255 bright): dim rooms slow webcams down
      const g = lumaCv.getContext("2d", { willReadFrequently: true }); g.drawImage(video, 0, 0, 32, 24);
      const px = g.getImageData(0, 0, 32, 24).data; let sum = 0;
      for (let i = 0; i < px.length; i += 4) sum += 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
      D.light = Math.round(sum / (px.length / 4));
    } catch (e) { /* not ready */ }
  }
  function renderDiag() {
    const p = D.perSec, st = D.settings || {}, drops = D.dropsWin.reduce((a, b) => a + b, 0);
    const warn = (bad, s) => (bad ? `<span class="bad">${s}</span>` : s);
    const lines = [
      `摄像头 ${warn(p.cam && p.cam < 24, `<b>${p.cam}</b> fps`)}（设定 ${st.frameRate ? Math.round(st.frameRate) : "?"}） ${st.width || "?"}×${st.height || "?"}`,
      `亮度 ${warn(D.light !== null && D.light < 60, `<b>${D.light === null ? "?" : D.light}</b>`)}/255 · 页面 <b>${p.page}</b> fps`,
      `分析 ${warn(p.ana && p.ana < 20, `<b>${p.ana}</b> fps`)} · 每帧 <b>${p.anaMs}</b> ms`,
      `手在画面 <b>${p.handPct}%</b> · 10 秒内丢手 ${warn(drops > 3, `<b>${drops}</b> 次`)}`,
      `校准 ${calApplied ? `<span class="ok">已应用</span>（左右 ${GESTURE.swipeHands} · 上下 ${GESTURE.swipeHandsV} · 速度 ${GESTURE.swipeSpeed}${GESTURE.returnMs ? "" : " · 连续反向"}）` : "未校准（默认设置）"}`,
    ];
    const log = D.swipes.log;
    lines.push(log.length ? "— 最近的挥动 —" : "— 挥一下手，这里会记录每次挥动 —");
    for (const r of log.slice(0, 5)) {
      lines.push(`${r.dir} ${r.fired ? '<span class="ok">已触发</span>' : `<span class="bad">${r.why}</span>`} 距离 <b>${r.travel}</b>/${r.need} 手 · 斜度 ${r.ratio} · ${r.ms} ms · 峰速 ${r.peak} · 丢 ${r.lost}/${r.frames} 帧${r.gap === null || r.gap === undefined ? "" : ` · 间隔 ${r.gap} ms`}`);
    }
    diagEl.innerHTML = lines.join("\n");
  }
  // ------------------------------------------------------------ guided calibration (校准)
  // ←×3, →×3, ↑×3, ↓×3, then a free up-down-up-down run. Each prompt: "get ready" (1.1 s; the hand comes
  // back), then "now" (up to 2.6 s; moves on 0.7 s after a clear stroke in that direction, recording
  // the bring-back in that moment too). Nothing plays while it runs. Then a report, and settings tuned
  // to you that you can apply (kept in this browser) or reset with 恢复默认.
  const CAL = { run: false, steps: [], i: -1, phase: "", t: 0, cur: null, rec: null, last: null };
  const PREP_MS = 1100, GO_MS = 2600, ALT_MS = 5200, AFTER_MS = 700;
  const DIR_TEXT = { "←": "向左挥", "→": "向右挥", "↑": "向上挥", "↓": "向下挥" };
  const calEl = document.createElement("div"); calEl.className = "gs-cal"; calEl.hidden = true; calEl.setAttribute("role", "dialog"); calEl.setAttribute("aria-label", "手势校准");
  app.append(calEl);
  view.querySelector(".calib").onclick = () => calStart();
  view.querySelector(".reset").onclick = () => {
    Object.assign(GESTURE, JSON.parse(JSON.stringify(DEFAULTS))); calApplied = null;
    try { localStorage.removeItem(CAL_KEY); } catch (e) { /* storage blocked */ }
    say("已恢复默认设置"); renderDiag();
  };
  function calStart() {
    if (!on || !recognizer) { say("先打开手势控制，再开始校准"); return; }
    Object.assign(CAL, { run: true, i: -1, last: null, rec: { prompts: [], alt: null },
      steps: [...["←", "→", "↑", "↓"].flatMap((d) => [d, d, d]).map((dir) => ({ dir })), { alt: true }] });
    calEl.hidden = false; calNext(performance.now());
  }
  function calStop() { CAL.run = false; calEl.hidden = true; }
  function calNext(now) {
    CAL.i++;
    if (CAL.i >= CAL.steps.length) { calFinish(); return; }
    const s = CAL.steps[CAL.i];
    CAL.cur = s.alt ? { strokes: [], fired: [] } : { dir: s.dir, strokes: [], fired: [], prep: [], back: [] };
    CAL.phase = "prep"; CAL.t = now; calRender(now);
  }
  function calCommit() { if (CAL.steps[CAL.i].alt) CAL.rec.alt = CAL.cur; else CAL.rec.prompts.push(CAL.cur); }
  // Every analysed frame while it runs.
  function calFrame(now, out) {
    const s = CAL.steps[CAL.i];
    if (!s || !CAL.run) return;
    if (out.stroke) {
      if (CAL.phase === "prep") { if (!s.alt) CAL.cur.prep.push(out.stroke); }
      else if (CAL.phase === "after") CAL.cur.back.push(out.stroke);
      else CAL.cur.strokes.push(out.stroke);
    }
    if (out.event && CAL.phase !== "prep") CAL.cur.fired.push(out.event);
    if (CAL.phase === "prep" && now - CAL.t >= PREP_MS) { CAL.phase = "go"; CAL.t = now; }
    else if (CAL.phase === "go") {
      if (!s.alt && out.stroke && out.stroke.dir === s.dir && out.stroke.travel >= 0.2) { CAL.phase = "after"; CAL.t = now; }
      else if (now - CAL.t >= (s.alt ? ALT_MS : GO_MS)) { calCommit(); calNext(now); return; }
    } else if (CAL.phase === "after" && now - CAL.t >= AFTER_MS) { calCommit(); calNext(now); return; }
    calRender(now);
  }
  function calRender(now) {
    const s = CAL.steps[CAL.i], n = CAL.steps.length, k = s.alt ? 0 : CAL.steps.slice(0, CAL.i + 1).filter((x) => x.dir === s.dir).length;
    calEl.className = `gs-cal ${CAL.phase}`;
    const arrow = s.alt ? "↕" : s.dir;
    const title = s.alt ? (CAL.phase === "prep" ? "准备：连续上下挥动" : "现在连续 上、下、上、下（每一下都算）") : CAL.phase === "prep" ? `准备：${DIR_TEXT[s.dir]}` : CAL.phase === "go" ? `现在${DIR_TEXT[s.dir]}！` : "✓ 记下了";
    const sub = s.alt ? "按你平时的节奏，四下" : CAL.phase === "prep" ? "先把手放回中间" : CAL.phase === "go" ? `第 ${k} / 3 次 · 按你平时的习惯挥` : CAL.cur.fired.includes({ "←": "swipeLeft", "→": "swipeRight", "↑": "swipeUp", "↓": "swipeDown" }[s.dir]) ? "已识别" : "未识别（没关系，正是要测这个）";
    const limit = CAL.phase === "prep" ? PREP_MS : CAL.phase === "after" ? AFTER_MS : s.alt ? ALT_MS : GO_MS, left = Math.max(0, 1 - (now - CAL.t) / limit);
    calEl.innerHTML = `<div class="arrow" aria-hidden="true">${arrow}</div><div class="title">${title}</div><div class="sub">${sub}</div>`
      + `<div class="bar"><i style="--w:${(left * 100).toFixed(1)}%"></i></div><div class="step">第 ${CAL.i + 1} / ${n} 步</div><div class="row"><button type="button" class="stop">取消校准</button></div>`;
    calEl.querySelector(".stop").onclick = calStop;
  }
  function calFinish() {
    CAL.run = false;
    const r = analyseCalibration(CAL.rec, GESTURE, DEFAULTS);
    CAL.last = r;
    const pct = (x) => (x.tries ? Math.round((100 * x.hit) / x.tries) : 0);
    const rows = r.rows.map((x) => `<tr><td>${x.dir}</td><td class="${x.hit === x.tries ? "good" : x.hit ? "" : "poor"}">${x.hit}/${x.tries}（${pct(x)}%）</td><td class="${x.wrong ? "poor" : ""}">${x.wrong}</td><td>${x.travel === null ? "—" : x.travel}</td><td>${x.peak === null ? "—" : x.peak}</td></tr>`).join("");
    const keys = [["swipeHands", "左右距离（手）"], ["swipeHandsV", "上下距离（手）"], ["swipeSpeed", "速度（手/秒）"], ["swipeRatio", "方向比"], ["returnMs", "回程过滤（ms）"]];
    const tune = keys.map(([k, name]) => `<tr><td>${name}</td><td>${GESTURE[k]}</td><td><b>${r.tuned[k]}</b></td></tr>`).join("");
    calEl.className = "gs-cal report";
    calEl.innerHTML = `<div class="title">校准结果</div>`
      + `<table><tr><th>方向</th><th>识别</th><th>误触</th><th>你的距离</th><th>你的峰速</th></tr>${rows}</table>`
      + `<div class="sub">连续上下：${r.alt.strokes} 下清楚的挥动，触发了 ${r.alt.fired} 次</div>`
      + `<table><tr><th>设置</th><th>现在</th><th>建议（按你的习惯）</th></tr>${tune}</table>`
      + `<ul>${r.notes.map((n) => `<li>${n}</li>`).join("")}</ul>`
      + `<label><input type="checkbox" class="alt"> 允许连续反向挥动（关闭回程过滤：上下来回每一下都算）</label>`
      + `<div class="row"><button type="button" class="go">应用这些设置</button><button type="button" class="again">重新校准</button><button type="button" class="close">关闭</button></div>`;
    calEl.querySelector(".go").onclick = () => {
      const tuned = { ...r.tuned };
      if (calEl.querySelector(".alt").checked) tuned.returnMs = 0;
      Object.assign(GESTURE, tuned); calApplied = { tuned, when: new Date().toISOString() };
      try { localStorage.setItem(CAL_KEY, JSON.stringify(calApplied)); } catch (e) { /* storage blocked: applies until reload */ }
      calStop(); say("已应用你的校准设置"); renderDiag();
    };
    calEl.querySelector(".again").onclick = () => calStart();
    calEl.querySelector(".close").onclick = calStop;
  }
  const say = (t) => { did.textContent = t; view.classList.add("flash"); setTimeout(() => view.classList.remove("flash"), 600); };

  btn.onclick = () => { if (on) stop(); else card.hidden = !card.hidden; };
  card.querySelector(".no").onclick = () => { card.hidden = true; };
  card.querySelector(".go").onclick = () => { card.hidden = true; start(); };

  async function loadRecognizer() {
    const vision = await import(`${VISION}/vision_bundle.mjs`);
    const files = await vision.FilesetResolver.forVisionTasks(`${VISION}/wasm`);
    const make = (delegate) => vision.GestureRecognizer.createFromOptions(files, { baseOptions: { modelAssetPath: MODEL, delegate }, runningMode: "VIDEO", numHands: 1 });
    try { return await make("GPU"); } catch (e) { return make("CPU"); }
  }
  async function start() {
    on = true; btn.setAttribute("aria-pressed", "true"); view.hidden = false; pose.textContent = "正在打开摄像头…"; did.textContent = "";
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 480, frameRate: { ideal: 30 }, facingMode: "user" }, audio: false });
    } catch (e) { pose.textContent = "无法使用摄像头"; did.textContent = e && e.name === "NotAllowedError" ? "此浏览器不允许摄像头：请用 Chrome 打开 http://localhost:8791" : e && e.name === "NotFoundError" ? "没有找到摄像头" : String((e && e.message) || e);
      did.title = did.textContent; did.style.whiteSpace = "normal"; on = false; btn.setAttribute("aria-pressed", "false"); return; }
    if (!on) { stop(); return; }
    video.srcObject = stream; await video.play().catch(() => {});
    const track = stream.getVideoTracks()[0];
    D.settings = track && track.getSettings ? (({ width, height, frameRate, deviceId }) => ({ width, height, frameRate, camera: track.label || deviceId }))(track.getSettings()) : null;
    D.tSec = performance.now();
    if (video.requestVideoFrameCallback) { const count = () => { if (!on) return; D.cam++; video.requestVideoFrameCallback(count); }; video.requestVideoFrameCallback(count); }
    pose.textContent = "正在加载识别模型…";
    try { recognizer = recognizer || (await (loading = loading || loadRecognizer())); }
    catch (e) { pose.textContent = "识别模型加载失败"; did.textContent = String((e && e.message) || e); loading = null; return; }
    if (!on) return;
    core = createGestureCore(GESTURE); pose.textContent = "把手放到镜头前"; loop();
  }
  function stop() {
    on = false; btn.setAttribute("aria-pressed", "false"); view.hidden = true; cancelAnimationFrame(raf);
    if (stream) stream.getTracks().forEach((t) => t.stop());
    stream = null; video.srcObject = null;
  }
  function draw(lm) {
    const w = (canvas.width = canvas.clientWidth), h = (canvas.height = canvas.clientHeight), g = canvas.getContext("2d");
    g.clearRect(0, 0, w, h);
    if (!lm) return;
    // object-fit: cover crops the 4:3 frame to the preview box; map the landmarks the same way.
    const vw = video.videoWidth || 640, vh = video.videoHeight || 480, k = Math.max(w / vw, h / vh), ox = (w - vw * k) / 2, oy = (h - vh * k) / 2;
    g.fillStyle = "rgba(205, 218, 255, 0.95)";
    for (const p of lm) { g.beginPath(); g.arc(w - (ox + p.x * vw * k), oy + p.y * vh * k, 2.4, 0, Math.PI * 2); g.fill(); }
  }
  function loop() {
    raf = requestAnimationFrame(loop);
    if (!on || !recognizer || video.readyState < 2 || document.hidden) return;
    const now = performance.now();
    D.page++; diagSecond(now);
    if (now - D.tShow > 500) { D.tShow = now; renderDiag(); }
    if (!video.requestVideoFrameCallback && video.currentTime !== lastFrameTime) D.cam++; // (fallback count)
    if (now - lastRun < 1000 / GESTURE.fps - 2 || video.currentTime === lastFrameTime) return; // only new camera frames
    lastRun = now; lastFrameTime = video.currentTime;
    let res;
    const a0 = performance.now();
    try { res = recognizer.recognizeForVideo(video, now); } catch (e) { return; }
    D.ana++; D.anaMs += performance.now() - a0;
    const lm = res.landmarks && res.landmarks[0], top = res.gestures && res.gestures[0] && res.gestures[0][0];
    draw(lm);
    let frame = { t: now, hand: !!lm };
    if (lm) {
      // Everything in frame-width units (y scaled by the frame's aspect), so up/down and left/right
      // compare fairly; s = hand size (wrist to middle knuckle).
      const ar = (video.videoHeight || 480) / (video.videoWidth || 640);
      const ids = [0, 5, 9, 13, 17], cx = ids.reduce((s, i) => s + lm[i].x, 0) / ids.length, cy = ids.reduce((s, i) => s + lm[i].y, 0) / ids.length;
      const s = Math.hypot(lm[9].x - lm[0].x, (lm[9].y - lm[0].y) * ar);
      frame = { t: now, hand: true, g: top && top.categoryName !== "None" ? top.categoryName : null, score: top ? top.score : 0, x: 1 - cx, y: cy * ar, s }; // x mirrored: the user's own right
    }
    const out = core(frame);
    D.frames++; if (frame.hand) D.hand++; if (D.wasHand && !frame.hand) D.drops++; D.wasHand = frame.hand;
    if (D.swipes.feed(frame, out)) renderDiag();
    ring.style.setProperty("--p", out.hold ? out.hold.p.toFixed(3) : "0");
    meter.style.setProperty("--m", (out.motion || 0).toFixed(3));
    pose.textContent = !lm ? "未检测到手" : frame.g ? `${LABEL[frame.g] || frame.g} ${Math.round(frame.score * 100)}%` : "手";
    if (CAL.run) calFrame(now, out); // calibrating: record only, nothing plays
    else if (out.event) { const text = act(out.event); say(text || `${ACTION_TEXT[out.event] || out.event}（此处不可用）`); }
  }
  addEventListener("pagehide", stop);
  window.YinweiGestures = { GESTURE, createGestureCore, createSwipeLog, analyseCalibration, calStart, calFrame: (now, out) => calFrame(now, out), cal: CAL, diag: () => diagSnapshot(), act, start, stop, load: () => recognizer || (loading = loading || loadRecognizer()) };
})();
