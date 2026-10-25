"use strict";
// Native-camera adapter only. No camera, model, external resources or image data in this page.
(function () {
  const LABEL = { Open_Palm: "张开手掌", Closed_Fist: "握拳", Victory: "剪刀手", Thumb_Up: "竖拇指" };
  const ACTION_TEXT = { Open_Palm: "打开快捷歌单", Closed_Fist: "收起", Victory: "在窗上展开", Thumb_Up: "播放 / 暂停", swipeLeft: "下一首", swipeRight: "上一首", swipeUp: "歌单 ↓", swipeDown: "歌单 ↑" };
  const CAL_KEY = "yinwei.gestureCal";
  const DEFAULTS = Object.freeze({version: 2, commitHands: 0.34, commitHandsV: 0.34, swipeSpeed: 2.4,
    swipeRatio: 1.2, rearmMs: 250, returnMs: 600});
  const TUNED_KEYS = ["commitHands", "commitHandsV", "swipeSpeed", "swipeRatio", "rearmMs", "returnMs"];
  const EVENTS = Object.keys(ACTION_TEXT);
  const DIR = {swipeLeft:"←", swipeRight:"→", swipeUp:"↑", swipeDown:"↓"};
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
      const floors = {commitHands:0.25,commitHandsV:0.25,swipeSpeed:2.2,swipeRatio:1.05,rearmMs:100,returnMs:0};
      const v = tuned[key], floor = floors[key];
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

  function createLatency() {
    const rows = {};
    const percentile = (a, p) => a.length ? [...a].sort((x,y)=>x-y)[Math.ceil(a.length*p)-1] : 0;
    function record(event, decision, delivery, uncertainty) {
      const r = rows[event] ||= {count:0, deliveryCount:0, decision:[], delivery:[], uncertainty:0};
      r.count++; r.decision.push(decision); if(r.decision.length>256)r.decision.shift();
      if(delivery !== null) { r.deliveryCount++; r.delivery.push(Math.max(0,delivery)); if(r.delivery.length>256)r.delivery.shift(); }
      r.uncertainty=uncertainty;
    }
    function summary() {
      return Object.fromEntries(Object.entries(rows).map(([name,r])=>[name,{count:r.count,deliveryCount:r.deliveryCount,
        decisionP50:percentile(r.decision,.5),decisionP95:percentile(r.decision,.95),
        deliveryP50:percentile(r.delivery,.5),deliveryP95:percentile(r.delivery,.95),clockUncertaintyMs:r.uncertainty}]));
    }
    return {record,summary};
  }

  function create({ core, actions, send, say, document: doc, storage, now = () => performance.now() }) {
    const defaults = clone(DEFAULTS), config = clone(defaults);
    let applied = false, status = {on:false,active:false,starting:false,consent:false};
    try {
      const saved=JSON.parse(storage?.getItem(CAL_KEY)||"null");
      if(saved?.version===2 && saved.tuned) {Object.assign(config,safeTuning(saved.tuned,defaults));applied=true;}
      else if(saved) storage?.removeItem(CAL_KEY);
    } catch (_) { /* invalid or legacy calibration uses defaults */ }
    let clockOffset=null, uncertainty=0, bestRoundTrip=Infinity, clockSamples=0,pendingEvents=[];
    let lastEvent=-1,lastStatus=-1,ignoreBefore=-1,configPending=true,lastPose=null,progress=0,configRequest=0;
    const act=createActions(actions), byId=id=>doc.getElementById(id), latency=createLatency();
    const btn=byId("gesture-btn"),card=byId("gesture-consent"),chip=byId("gesture-chip"),panel=byId("gesture-panel");
    function analyse(rec) {
      // Reuse only the pure calibration report, never the legacy recognition core.
      const legacy=c=>({swipeHands:c.commitHands,swipeHandsV:c.commitHandsV,swipeSpeed:c.swipeSpeed,swipeRatio:c.swipeRatio,returnMs:c.returnMs});
      const result=core.analyseCalibration(rec,legacy(config),legacy(defaults)), t=result.tuned;
      const gaps=result.alt.gaps.filter(g=>Number.isFinite(g)&&g>0);
      result.tuned=safeTuning({commitHands:t.swipeHands,commitHandsV:t.swipeHandsV,swipeSpeed:t.swipeSpeed,
        swipeRatio:t.swipeRatio,returnMs:t.returnMs,rearmMs:gaps.length?Math.min(config.rearmMs,Math.min(...gaps)*.7):config.rearmMs},defaults);
      return result;
    }
    const calibration=createCalibration({analyse,config,defaults,now,changed:renderCalibration,finished:renderReport});
    function configure() {
      configPending=true;pendingEvents=[];lastEvent=lastStatus=-1;progress=0;
      if(status.active)send({t:"gestureConfig",request:++configRequest,config:{...config,version:2}});
    }
    function configured(value) {
      if(!status.active||!value||value.request!==configRequest||!Number.isFinite(value.t))return;
      ignoreBefore=value.t;configPending=false;
      if(clockOffset===null)send({t:"gestureClock",pageT:now()});
    }
    function clock(value) {
      if(!status.active||!value||!Number.isFinite(value.pageT)||!Number.isFinite(value.nativeT))return;
      const rtt=now()-value.pageT;
      if(rtt<0||rtt>5000)return;
      if(rtt<bestRoundTrip) {bestRoundTrip=rtt;uncertainty=rtt/2;clockOffset=value.pageT+rtt/2-value.nativeT;}
      const queued=pendingEvents;pendingEvents=[];for(const value of queued)result(value);
      if(++clockSamples<3)send({t:"gestureClock",pageT:now()});
    }
    function reset() {
      lastEvent=lastStatus=-1;lastPose=null;progress=0;ignoreBefore=-1;configPending=true;
      pendingEvents=[];clockOffset=null;bestRoundTrip=Infinity;clockSamples=0;calibration.stop();renderStatus();if(status.active)configure();
    }
    function renderStatus() {
      btn.setAttribute("aria-pressed",String(status.active||status.starting));
      btn.setAttribute("aria-label",status.active?"Turn hand gestures off":"Turn hand gestures on");btn.disabled=false;
      chip.hidden=!(status.on||status.active||status.starting||status.error);
      byId("gesture-pose").textContent=status.error||(status.starting?"Opening camera…":!status.active?"Camera paused · tap hand to resume":lastPose?LABEL[lastPose]:"未检测到手");
      byId("gesture-ring").style.setProperty("--hold",progress);
      byId("gesture-calibrate").disabled=!status.active;
      byId("gesture-cal-note").textContent=applied?"已应用校准 · 阈值不高于默认值":"默认手势设置";
    }
    function update(value) {
      const wasActive=status.active;status={...status,...value};
      if(!status.active)reset();else {if(!wasActive)configure();renderStatus();}
      if(status.consent)card.hidden=true;
    }
    function renderLatency() {
      const summary=latency.summary();
      byId("gesture-latency").textContent=Object.entries(summary).map(([event,r])=>
        `${ACTION_TEXT[event]} · n=${r.count} · decision p50/p95 ${r.decisionP50.toFixed(0)}/${r.decisionP95.toFixed(0)} ms · delivery ${r.deliveryCount ? `${r.deliveryP50.toFixed(0)}/${r.deliveryP95.toFixed(0)} ms` : "—"}`).join("\n");
      send({t:"gestureMetrics",metrics:summary});
    }
    function result(value) {
      if(!status.active||!value||!Number.isFinite(value.t)||configPending||value.t<=ignoreBefore)return;
      if(Object.hasOwn(value,"event")) {
        if(!EVENTS.includes(value.event)||!Number.isFinite(value.latencyMs)||value.t<=lastEvent)return;
        if(clockOffset===null) {
          if(pendingEvents.length<16)pendingEvents.push(value);
          else {configPending=true;pendingEvents=[];send({t:"gestures",on:false});}
          return;
        }
        lastEvent=value.t;
        const delay=Math.max(0,Math.min(10000,value.latencyMs));
        if(calibration.cal.run) {
          calibration.frame(now(),{event:value.event});latency.record(value.event,delay,null,uncertainty);
        } else {
          // Mapping is unchanged. Clock sync uses the best of three round trips, not
          // the first event's arrival, so delivery delay is not artificially zero.
          const acted=now(),text=act(value.event);
          latency.record(value.event,delay,clockOffset===null?null:acted-(value.t+clockOffset),uncertainty);
          if(text!==null)say(text||`${ACTION_TEXT[value.event]}（此处不可用）`);
        }
        renderLatency();
      } else {
        if(value.t<=lastStatus||!Number.isFinite(value.progress)||(value.pose!==null&&!Object.hasOwn(LABEL,value.pose)))return;
        lastStatus=value.t;lastPose=value.pose;progress=Math.max(0,Math.min(1,value.progress));
        if(calibration.cal.run) {
          for(const s of (Array.isArray(value.strokes)?value.strokes:[])) {
            if(!DIR[s.event]||![s.t,s.travel,s.peak,s.ratio].every(Number.isFinite))continue;
            calibration.frame(now(),{stroke:{...s,dir:DIR[s.event],t:clockOffset===null?now():s.t+clockOffset}});
          }
          calibration.frame(now(),{});
        }
      }
      renderStatus();
    }
    function renderCalibration(cal,t) {
      const el=byId("gesture-calibration");el.hidden=!cal.run;if(!cal.run)return;
      panel.hidden=false;byId("gesture-report").hidden=true;
      const s=cal.steps[cal.i],name={"←":"向左挥","→":"向右挥","↑":"向上挥","↓":"向下挥"}[s.dir];
      byId("gesture-cal-title").textContent=s.alt?(cal.phase==="prep"?"准备：连续上下挥动":"现在连续 上、下、上、下（每一下都算）"):cal.phase==="prep"?`准备：${name}`:cal.phase==="go"?`现在${name}！`:"✓ 记下了";
      byId("gesture-cal-step").textContent=`第 ${cal.i+1} / ${cal.steps.length} 步 · 按你平时的习惯挥`;
      const limit=cal.phase==="prep"?1100:cal.phase==="after"?700:s.alt?5200:2600;
      byId("gesture-cal-progress").value=Math.max(0,1-(t-cal.t)/limit);
    }
    function renderReport(r) {
      byId("gesture-calibration").hidden=true;byId("gesture-report").hidden=false;
      byId("gesture-cal-result").textContent=r.rows.map(x=>`${x.dir} ${x.hit}/${x.tries} · 误触 ${x.wrong}`).join("\n")+
        `\n连续上下：${r.alt.strokes} 下，触发 ${r.alt.fired} 次\n`+r.notes.join("\n")+"\n"+TUNED_KEYS.map(k=>`${k}: ${config[k]} → ${r.tuned[k]}`).join("\n");
      byId("gesture-allow-reverse").checked=false;configure();
    }
    function stopCalibration() {calibration.stop();configure();}
    btn.onclick=()=>{if(status.active||status.starting)send({t:"gestures",on:false});else if(status.consent)send({t:"gestures",on:true});else card.hidden=!card.hidden;};
    byId("gesture-agree").onclick=()=>{card.hidden=true;send({t:"gestureConsent"});send({t:"gestures",on:true});};
    byId("gesture-decline").onclick=()=>{card.hidden=true;btn.focus();};
    byId("gesture-details").onclick=()=>{panel.hidden=!panel.hidden;};
    byId("gesture-off").onclick=()=>{panel.hidden=true;send({t:"gestures",on:false});};
    byId("gesture-panel-close").onclick=()=>{stopCalibration();panel.hidden=true;};
    byId("gesture-calibrate").onclick=()=>{if(!status.active){say("先打开手势控制，再开始校准");return;}configure();calibration.start();};
    byId("gesture-cal-cancel").onclick=stopCalibration;
    byId("gesture-cal-apply").onclick=()=>{
      if(!calibration.cal.last)return;
      const tuned=safeTuning(calibration.cal.last.tuned,defaults);
      if(byId("gesture-allow-reverse").checked)tuned.returnMs=0;
      Object.assign(config,tuned);applied=true;
      try{storage?.setItem(CAL_KEY,JSON.stringify({version:2,tuned,when:new Date().toISOString()}));}catch(_){}
      byId("gesture-report").hidden=true;configure();renderStatus();say("已应用你的校准设置");
    };
    byId("gesture-cal-reset").onclick=()=>{
      Object.assign(config,clone(defaults));applied=false;
      try{storage?.removeItem(CAL_KEY);}catch(_){}
      byId("gesture-report").hidden=true;stopCalibration();renderStatus();say("已恢复默认设置");
    };
    renderStatus();
    return {result,update,reset,configured,clock,metrics:latency.summary};
  }
  const api={create,createActions,createCalibration,safeTuning,createLatency,DEFAULTS};
  if(typeof module!=="undefined"&&module.exports)module.exports=api;
  else globalThis.ListenGestureUI=api;
})();
