// Pure measured gesture rules, copied unchanged from docs/design/gestures/gestures.cjs.
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
  const api = { createGestureCore, createSwipeLog, analyseCalibration, GESTURE };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else globalThis.ListenGestureCore = api;
})();
