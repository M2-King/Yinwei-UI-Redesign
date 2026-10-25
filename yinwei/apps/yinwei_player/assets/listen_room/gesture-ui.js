"use strict";
// Native-camera adapter only. No camera, model, external resources or image data in this page.
(function () {
  const LABEL = { Open_Palm: "张开手掌", Closed_Fist: "握拳", Victory: "剪刀手", Thumb_Up: "竖拇指" };
  const ACTION_TEXT = { Open_Palm: "打开快捷歌单", Closed_Fist: "收起", Victory: "在窗上展开", Thumb_Up: "播放 / 暂停", swipeLeft: "下一首", swipeRight: "上一首", swipeUp: "歌单 ↓", swipeDown: "歌单 ↑" };
  const CAL_KEY = "yinwei.gestureCal";
  const TUNED_KEYS = ["swipeHands", "swipeHandsV", "swipeSpeed", "swipeRatio", "returnMs"];
  const clone = value => JSON.parse(JSON.stringify(value));

  // Same entry points as touch. A paused focused song goes through pkSelect/winTap.
  function createActions(a) {
    return function act(ev) {
      const mode = a.mode();
      switch (ev) {
        case "Open_Palm": if (mode === "album") { a.setMode("compact"); return ACTION_TEXT[ev]; } break;
        case "Closed_Fist":
          if (mode === "window") { a.setMode("compact"); return "收起到快捷歌单"; }
          if (mode === "compact") { a.setMode("album"); return "关闭快捷歌单"; } break;
        case "Victory": if (mode === "compact") { a.setMode("window"); return ACTION_TEXT[ev]; } break;
        case "Thumb_Up":
          if (mode === "compact" || mode === "window") {
            const i = mode === "compact" ? a.focus() : a.offset(), allowed = a.canSelect();
            if (mode === "compact") a.select(i); else a.windowTap(i);
            if (!allowed) return null; // the existing action already explained its guard
            const s = a.state();
            return s.queue && s.queue.songs[i] ? (i === s.queue.playing && s.playing ? "已在播放这首" : `播放：${s.queue.songs[i].title}`) : "";
          }
          a.click("play"); return ACTION_TEXT[ev];
        case "swipeLeft": a.click("next"); return ACTION_TEXT[ev];
        case "swipeRight": a.click("prev"); return ACTION_TEXT[ev];
        case "swipeUp": if (mode === "compact") { a.browse(1); return ACTION_TEXT[ev]; } break;
        case "swipeDown": if (mode === "compact") { a.browse(-1); return ACTION_TEXT[ev]; } break;
      }
      return "";
    };
  }

  function safeTuning(tuned, defaults) {
    const out = {};
    if (!tuned || typeof tuned !== "object") return out;
    for (const key of TUNED_KEYS) {
      const v = tuned[key], floor = key === "returnMs" ? 0 : key === "swipeRatio" ? 1 : 0.01;
      if (typeof v === "number" && Number.isFinite(v)) out[key] = Math.min(defaults[key], Math.max(floor, v));
    }
    return out;
  }

  // Guided phases and timing from the prototype: 12 strokes, then a continuous reverse run.
  function createCalibration({ analyse, config, defaults, now, changed, finished }) {
    const cal = { run: false, steps: [], i: -1, phase: "", t: 0, cur: null, rec: null, last: null };
    function commit() { if (cal.steps[cal.i].alt) cal.rec.alt = cal.cur; else cal.rec.prompts.push(cal.cur); }
    function next(t) {
      cal.i++;
      if (cal.i >= cal.steps.length) {
        cal.run = false; cal.last = analyse(cal.rec, config, defaults); finished(cal.last); return;
      }
      cal.cur = cal.steps[cal.i].alt ? { strokes: [], fired: [] } : { dir: cal.steps[cal.i].dir, strokes: [], fired: [], prep: [], back: [] };
      cal.phase = "prep"; cal.t = t; changed(cal, t);
    }
    function start() {
      Object.assign(cal, { run: true, i: -1, last: null, rec: { prompts: [], alt: null },
        steps: [...["←", "→", "↑", "↓"].flatMap(dir => [dir, dir, dir]).map(dir => ({ dir })), { alt: true }] });
      next(now());
    }
    function stop() { cal.run = false; changed(cal, now()); }
    function frame(t, out) {
      const step = cal.steps[cal.i];
      if (!step || !cal.run) return;
      if (out.stroke) {
        if (cal.phase === "prep") { if (!step.alt) cal.cur.prep.push(out.stroke); }
        else if (cal.phase === "after") { if (cal.cur.back) cal.cur.back.push(out.stroke); }
        else cal.cur.strokes.push(out.stroke);
      }
      if (out.event && cal.phase !== "prep") cal.cur.fired.push(out.event);
      if (cal.phase === "prep" && t - cal.t >= 1100) { cal.phase = "go"; cal.t = t; }
      else if (cal.phase === "go") {
        if (!step.alt && out.stroke && out.stroke.dir === step.dir && out.stroke.travel >= 0.2) { cal.phase = "after"; cal.t = t; }
        else if (t - cal.t >= (step.alt ? 5200 : 2600)) { commit(); next(t); return; }
      } else if (cal.phase === "after" && t - cal.t >= 700) { commit(); next(t); return; }
      changed(cal, t);
    }
    return { cal, start, stop, frame };
  }

  function create({ core, actions, send, say, document: doc, storage, now = () => performance.now() }) {
    const defaults = clone(core.GESTURE), config = clone(defaults);
    let applied = false, status = { on: false, active: false, starting: false, consent: false };
    try {
      const saved = JSON.parse(storage.getItem(CAL_KEY) || "null");
      if (saved && saved.tuned) { Object.assign(config, safeTuning(saved.tuned, defaults)); applied = true; }
    } catch (_) { /* defaults when storage is unavailable */ }
    let detector = core.createGestureCore(config), log = core.createSwipeLog(), clockOffset = null, lastNative = -1;
    let lastFrame = null, lastOut = null;
    const act = createActions(actions), byId = id => doc.getElementById(id);
    const btn = byId("gesture-btn"), card = byId("gesture-consent"), chip = byId("gesture-chip"), panel = byId("gesture-panel");
    const calibration = createCalibration({ analyse: core.analyseCalibration, config, defaults, now,
      changed: renderCalibration, finished: renderReport });

    function reset() {
      detector = core.createGestureCore(config); log = core.createSwipeLog(); clockOffset = null; lastNative = -1;
      lastFrame = lastOut = null;
      calibration.stop(); renderStatus();
    }
    function renderStatus() {
      btn.setAttribute("aria-pressed", String(status.active || status.starting));
      btn.setAttribute("aria-label", status.active ? "Turn hand gestures off" : "Turn hand gestures on");
      btn.disabled = false; // permission can still be pending when the owner turns this off
      chip.hidden = !(status.on || status.active || status.starting || status.error);
      const text = status.error || (status.starting ? "Opening camera…" : !status.active ? "Camera paused · tap hand to resume" :
        !lastFrame || !lastFrame.hand ? "未检测到手" : lastFrame.g ? `${LABEL[lastFrame.g] || "手"} ${Math.round(lastFrame.score * 100)}%` : "手");
      byId("gesture-pose").textContent = text;
      byId("gesture-ring").style.setProperty("--hold", lastOut && lastOut.hold ? lastOut.hold.p : 0);
      byId("gesture-calibrate").disabled = !status.active;
      byId("gesture-cal-note").textContent = applied ? "已应用校准 · 阈值不高于默认值" : "默认手势设置";
    }
    function update(value) {
      status = { ...status, ...value };
      if (!status.active) reset(); else renderStatus();
      if (status.consent) card.hidden = true;
    }
    function frame(value) {
      if (!status.active || !value || typeof value.t !== "number" || !Number.isFinite(value.t) || value.t <= lastNative) return;
      lastNative = value.t;
      // Native uptime and performance.now have different origins: one offset per camera run.
      if (clockOffset === null) clockOffset = now() - value.t;
      const f = { ...value, t: value.t + clockOffset }, out = detector(f);
      lastFrame = f; lastOut = out; log.feed(f, out);
      if (calibration.cal.run) calibration.frame(f.t, out);
      else if (out.event) {
        const text = act(out.event);
        if (text !== null) say(text || `${ACTION_TEXT[out.event] || out.event}（此处不可用）`);
      }
      renderStatus();
    }
    function renderCalibration(cal, t) {
      const el = byId("gesture-calibration");
      el.hidden = !cal.run;
      if (!cal.run) return;
      panel.hidden = false; byId("gesture-report").hidden = true;
      const s = cal.steps[cal.i], name = { "←": "向左挥", "→": "向右挥", "↑": "向上挥", "↓": "向下挥" }[s.dir];
      byId("gesture-cal-title").textContent = s.alt ? (cal.phase === "prep" ? "准备：连续上下挥动" : "现在连续 上、下、上、下（每一下都算）") : cal.phase === "prep" ? `准备：${name}` : cal.phase === "go" ? `现在${name}！` : "✓ 记下了";
      byId("gesture-cal-step").textContent = `第 ${cal.i + 1} / ${cal.steps.length} 步 · 按你平时的习惯挥`;
      const limit = cal.phase === "prep" ? 1100 : cal.phase === "after" ? 700 : s.alt ? 5200 : 2600;
      byId("gesture-cal-progress").value = Math.max(0, 1 - (t - cal.t) / limit);
    }
    function renderReport(result) {
      byId("gesture-calibration").hidden = true; byId("gesture-report").hidden = false;
      byId("gesture-cal-result").textContent = result.rows.map(r => `${r.dir} ${r.hit}/${r.tries} · 误触 ${r.wrong}`).join("\n") +
        `\n连续上下：${result.alt.strokes} 下，触发 ${result.alt.fired} 次\n` + result.notes.join("\n") +
        "\n" + TUNED_KEYS.map(k => `${k}: ${config[k]} → ${result.tuned[k]}`).join("\n");
      byId("gesture-allow-reverse").checked = false;
    }
    btn.onclick = () => {
      if (status.active || status.starting) send({ t: "gestures", on: false });
      else if (status.consent) send({ t: "gestures", on: true });
      else card.hidden = !card.hidden;
    };
    byId("gesture-agree").onclick = () => { card.hidden = true; send({ t: "gestureConsent" }); send({ t: "gestures", on: true }); };
    byId("gesture-decline").onclick = () => { card.hidden = true; btn.focus(); };
    byId("gesture-details").onclick = () => { panel.hidden = !panel.hidden; };
    byId("gesture-off").onclick = () => { panel.hidden = true; send({ t: "gestures", on: false }); };
    byId("gesture-panel-close").onclick = () => { calibration.stop(); panel.hidden = true; };
    byId("gesture-calibrate").onclick = () => {
      if (!status.active) { say("先打开手势控制，再开始校准"); return; }
      detector = core.createGestureCore(config); clockOffset = null; calibration.start();
    };
    byId("gesture-cal-cancel").onclick = () => { calibration.stop(); detector = core.createGestureCore(config); };
    byId("gesture-cal-apply").onclick = () => {
      if (!calibration.cal.last) return;
      const tuned = safeTuning(calibration.cal.last.tuned, defaults);
      if (byId("gesture-allow-reverse").checked) tuned.returnMs = 0;
      Object.assign(config, tuned); applied = true;
      try { storage.setItem(CAL_KEY, JSON.stringify({ tuned, when: new Date().toISOString() })); } catch (_) { /* session only */ }
      byId("gesture-report").hidden = true; reset(); say("已应用你的校准设置");
    };
    byId("gesture-cal-reset").onclick = () => {
      Object.assign(config, clone(defaults)); applied = false;
      try { storage.removeItem(CAL_KEY); } catch (_) { /* session only */ }
      byId("gesture-report").hidden = true; reset(); say("已恢复默认设置");
    };
    renderStatus();
    return { frame, update, reset };
  }
  const api = { create, createActions, createCalibration, safeTuning };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else globalThis.ListenGestureUI = api;
})();
