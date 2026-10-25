import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const base = new URL('../../assets/listen_room/', import.meta.url);
function load(name) {
  const module = { exports: {} };
  new Function('module', readFileSync(new URL(name, base), 'utf8'))(module);
  return module.exports;
}
const core = load('gesture-core.js');
const { createActions, createCalibration, create, safeTuning, DEFAULTS, createLatency } = load('gesture-ui.js');
const ui = readFileSync(new URL('ui.js', base), 'utf8');

function mapping() {
  let mode = 'album';
  const calls = [], state = { playing: true, queue: { playing: 0, songs: [{ title: 'One' }, { title: 'Two' }] } };
  const a = { mode: () => mode, setMode: m => { mode = m; calls.push(['mode', m]); },
    focus: () => 1, offset: () => 0, state: () => state, canSelect: () => true,
    select: i => calls.push(['select', i]), windowTap: i => calls.push(['window', i]),
    browse: i => calls.push(['browse', i]), click: id => calls.push(['click', id]) };
  return { a, calls, state, act: createActions(a), mode: m => { mode = m; } };
}
for (const [event, mode, expected] of [
  ['Open_Palm', 'album', ['mode', 'compact']], ['Closed_Fist', 'window', ['mode', 'compact']],
  ['Closed_Fist', 'compact', ['mode', 'album']], ['Victory', 'compact', ['mode', 'window']],
  ['Thumb_Up', 'compact', ['select', 1]], ['Thumb_Up', 'window', ['window', 0]],
  ['Thumb_Up', 'album', ['click', 'play']], ['swipeLeft', 'album', ['click', 'next']],
  ['swipeRight', 'album', ['click', 'prev']], ['swipeUp', 'compact', ['browse', 1]],
  ['swipeDown', 'compact', ['browse', -1]],
]) {
  test(`${event} in ${mode} calls exactly the existing action`, () => {
    const h = mapping(); h.mode(mode); h.act(event); assert.deepEqual(h.calls, [expected]);
  });
}
test('poses and vertical swipes outside their modes do nothing', () => {
  for (const [event, mode] of [['Open_Palm', 'compact'], ['Closed_Fist', 'album'], ['Victory', 'album'], ['swipeUp', 'window'], ['swipeDown', 'album']]) {
    const h = mapping(); h.mode(mode); h.act(event); assert.deepEqual(h.calls, []);
  }
});
test('paused current song confirmation still calls the touch function', () => {
  const h = mapping(); h.mode('window'); h.state.playing = false;
  assert.equal(h.act('Thumb_Up'), '播放：One'); assert.deepEqual(h.calls, [['window', 0]]);
});
test('real picker guards reject pending, control loss and connection loss just like touch', () => {
  for (const mode of ['compact', 'window']) for (const guard of ['pending', 'control', 'connection']) {
    const state = { playing: true, pending: false, control: 'mine', connection: 'connected', queue: { playing: 0, songs: [{title:'One'},{title:'Two'}] } };
    state[guard] = guard === 'pending' ? true : guard === 'control' ? 'other' : 'reconnecting';
    const intents = [], notices = [];
    const ctx = vm.createContext({ S: state, browseMode: mode, pkSongs: () => state.queue.songs,
      otherHasControl: () => state.control !== 'mine', lost: () => state.connection !== 'connected',
      toast: t => notices.push(t), send: i => intents.push(i), act() {}, pkLayout() {} });
    vm.runInContext(ui.slice(ui.indexOf('function pkSelect('), ui.indexOf('function selectionDone()')), ctx);
    const h = mapping(); h.mode(mode);
    h.a.select = i => ctx.pkSelect(i); h.a.windowTap = i => ctx.winTap(i);
    h.a.canSelect = () => vm.runInContext('pkCanPlay()', ctx);
    h.act('Thumb_Up');
    assert.deepEqual(intents, []); assert.equal(notices.length, 1);
  }
});
test('transport gestures invoke actual button handlers and retain the same intent as taps', () => {
  for (const event of ['Thumb_Up', 'swipeLeft', 'swipeRight']) {
    const intents = [], elements = new Map();
    const $ = id => { if (!elements.has(id)) elements.set(id, { disabled: false, click() { if (!this.disabled) this.onclick(); } }); return elements.get(id); };
    const S = { playing: false, pending: true, connection: 'reconnecting', control: 'other' };
    const ctx = vm.createContext({ $, S, setLocal: v => Object.assign(S, v), send: i => intents.push(i), render() {} });
    for (const id of ['play', 'next', 'prev']) vm.runInContext(ui.split('\n').find(l => l.startsWith(`$("${id}").onclick =`)), ctx);
    const h = mapping(); h.a.click = id => $(id).click(); h.act(event);
    const id = { Thumb_Up: 'play', swipeLeft: 'next', swipeRight: 'prev' }[event];
    const gestureIntent = JSON.stringify(intents[0]); intents.length = 0; S.playing = false; $(id).click();
    assert.equal(JSON.stringify(intents[0]), gestureIntent);
    $(id).disabled = true; intents.length = 0; h.act(event); assert.deepEqual(intents, []);
  }
});

function page(storage = new Map()) {
  const elements = new Map();
  const doc = { getElementById(id) {
    if (!elements.has(id)) elements.set(id, { hidden: true, checked: false, disabled: false, textContent: '', style: { setProperty() {} }, attrs: {}, setAttribute(k,v) { this.attrs[k] = v; }, focus() {} });
    return elements.get(id);
  } };
  const h = mapping(), sent = [], said = [];
  let now = 10000;
  const api = create({ core, actions: h.a, send: x => sent.push(x), say: x => said.push(x), document: doc,
    storage: { getItem: k => storage.get(k), setItem: (k,v) => storage.set(k,v), removeItem: k => storage.delete(k) }, now: () => now });
  const event=(elapsed,event='Open_Palm')=>{now=10000+elapsed;api.result({t:1000000+elapsed,event,latencyMs:198});};
  const ready=()=>{api.update({on:true,active:true});ack();};
  const ack=()=>{const c=sent.filter(x=>x.t==='gestureConfig').at(-1);api.configured({request:c.request,t:999999});api.clock({pageT:now,nativeT:1000000});};
  return {...h,api,sent,said,event,ready,ack,el:doc.getElementById.bind(doc),storage,setNow:t=>{now=t;}};
}
test('camera starts only after opt-in; cancel is silent and consent precedes on', () => {
  const h = page(); assert.equal(h.el('gesture-chip').hidden, true); assert.deepEqual(h.sent, []);
  h.el('gesture-btn').onclick(); assert.equal(h.el('gesture-consent').hidden, false);
  h.el('gesture-decline').onclick(); assert.deepEqual(h.sent, []);
  h.el('gesture-btn').onclick(); h.el('gesture-agree').onclick();
  assert.deepEqual(h.sent, [{t:'gestureConsent'}, {t:'gestures',on:true}]);
  h.api.update({ consent:true, on:true, active:true }); h.el('gesture-btn').onclick();
  assert.deepEqual(h.sent.at(-1), {t:'gestures',on:false});
});
test('the page acts once per validated native decision and never recognizes frames', () => {
  const h=page();h.ready();h.event(200);h.event(200);h.event(199);
  assert.deepEqual(h.calls,[['mode','compact']]);assert.equal(h.said.length,1);
  h.api.result({t:1000300,hand:true,g:'Thumb_Up',score:1,x:0.5,y:0.5,s:0.12});
  assert.equal(h.said.length,1);assert.doesNotMatch(readFileSync(new URL('gesture-ui.js',base),'utf8'),/createGestureCore\(/);
});

test('a paused preference can be switched off without reopening the camera', () => {
  const h = page(); h.api.update({on:true, active:false, consent:true});
  h.el('gesture-off').onclick();
  assert.deepEqual(h.sent, [{t:'gestures',on:false}]);
});
test('off, interrupted and configuring pages discard native decisions', () => {
  const h=page();h.event(200);assert.deepEqual(h.calls,[]);
  h.api.update({on:true,active:true});h.event(400);assert.deepEqual(h.calls,[]);
  h.ack();h.api.update({active:false});h.event(600);assert.deepEqual(h.calls,[]);
  h.api.update({active:true});h.event(800);assert.deepEqual(h.calls,[]);
});

test('nothing acts during calibration; cancelled calibration rejects queued decisions', () => {
  const h=page();h.ready();h.el('gesture-calibrate').onclick();h.ack();
  h.event(200,'Thumb_Up');h.event(300,'swipeLeft');assert.deepEqual(h.calls,[]);
  h.el('gesture-cal-cancel').onclick();h.event(400,'swipeLeft');assert.deepEqual(h.calls,[]);
  const c=h.sent.filter(x=>x.t==='gestureConfig').at(-1);
  h.api.configured({request:c.request-1,t:1000300});h.event(500,'swipeLeft');assert.deepEqual(h.calls,[]);
  h.api.configured({request:c.request,t:1000500});h.event(450,'swipeLeft');assert.deepEqual(h.calls,[]);
  h.event(600,'swipeLeft');assert.deepEqual(h.calls,[['click','next']]);
});

test('native status clamps the hold ring and unknown events never act', () => {
  const h=page();h.ready();h.api.result({t:1000100,pose:'Victory',progress:4,strokes:[]});
  assert.equal(h.el('gesture-pose').textContent,'剪刀手');
  h.api.result({t:1000200,event:'other',latencyMs:1});assert.deepEqual(h.calls,[]);
});

test('clock sync measures delivery independently of the first event and diagnostics are numeric', () => {
  const h=page();h.ready();h.event(200,'swipeLeft');
  const m=h.api.metrics().swipeLeft;
  assert.equal(m.count,1);assert.equal(m.decisionP50,198);assert.equal(m.deliveryP50,0);
  h.setNow(10500);h.api.result({t:1000400,event:'swipeLeft',latencyMs:99});
  assert.equal(h.api.metrics().swipeLeft.deliveryP95,100);
  assert.ok(h.sent.some(x=>x.t==='gestureMetrics'));assert.match(h.el('gesture-latency').textContent,/p50\/p95/);
  for(const v of Object.values(h.api.metrics().swipeLeft))assert.equal(typeof v,'number');
});

test('latency quantiles and counts stay bounded across a long session',()=>{
  const l=createLatency();for(let i=1;i<=600;i++)l.record('swipeLeft',i,i+5,2);
  const row=l.summary().swipeLeft;assert.equal(row.count,600);assert.equal(row.deliveryCount,600);
  assert.equal(row.decisionP95,588);assert.equal(row.deliveryP95,593);
});

test('a decision waits for clock synchronization so its delivery delay is measurable',()=>{
  const h=page();h.api.update({on:true,active:true});
  const c=h.sent.find(x=>x.t==='gestureConfig');h.api.configured({request:c.request,t:999999});
  h.event(200,'swipeLeft');assert.deepEqual(h.calls,[]);
  h.api.clock({pageT:10000,nativeT:1000000});
  assert.deepEqual(h.calls,[['click','next']]);assert.equal(h.api.metrics().swipeLeft.deliveryCount,1);
});

test('guided native summaries complete calibration and save only versioned easier settings',()=>{
  const h=page();h.ready();h.el('gesture-calibrate').onclick();h.ack();
  let elapsed=0;
  const tick=(strokes=[])=>{
    h.setNow(10000+elapsed);h.api.result({t:1000000+elapsed,pose:null,progress:0,strokes});
  };
  for(const event of ['swipeLeft','swipeRight','swipeUp','swipeDown'].flatMap(e=>[e,e,e])) {
    elapsed+=1100;tick();elapsed+=200;h.event(elapsed,event);
    elapsed++;tick([{event,t:1000000+elapsed-150,travel:.6,peak:5,ratio:3,gap:300,fired:true}]);
    elapsed+=700;tick();
  }
  elapsed+=1100;tick();elapsed+=5200;tick();
  assert.equal(h.el('gesture-report').hidden,false);assert.deepEqual(h.calls,[]);
  h.el('gesture-allow-reverse').checked=true;h.el('gesture-cal-apply').onclick();
  const saved=JSON.parse(h.storage.get('yinwei.gestureCal'));
  assert.equal(saved.version,2);assert.equal(saved.tuned.returnMs,0);
  for(const [k,v] of Object.entries(saved.tuned))assert.ok(v<=DEFAULTS[k]);
  assert.deepEqual(h.sent.filter(x=>x.t==='gestureConfig').at(-1).config,{...DEFAULTS,...saved.tuned});
});

test('guided run records prep/back strokes and completes all thirteen phases', () => {
  let now=0, result;
  const c=createCalibration({analyse:core.analyseCalibration,config:core.GESTURE,defaults:core.GESTURE,now:()=>now,changed(){},finished:r=>{result=r;}});
  c.start();
  for(let i=0;i<12;i++) {
    const dir=c.cal.steps[i].dir;
    c.frame(now+500,{stroke:{dir:'→',travel:0.5,peak:4,ratio:3,gap:50}});
    now+=1100;c.frame(now,{});
    now+=200;c.frame(now,{stroke:{dir,travel:0.6,peak:5,ratio:3,gap:300},event:{'←':'swipeLeft','→':'swipeRight','↑':'swipeUp','↓':'swipeDown'}[dir]});
    now+=100;c.frame(now,{stroke:{dir:'←',travel:0.5,peak:4,ratio:3,gap:50}});
    now+=600;c.frame(now,{});
  }
  assert.equal(c.cal.i,12);now+=1100;c.frame(now,{});now+=5200;c.frame(now,{});
  assert.equal(c.cal.run,false);assert.ok(result);assert.equal(c.cal.rec.prompts.length,12);
  assert.equal(c.cal.rec.prompts[0].prep.length,1);assert.equal(c.cal.rec.prompts[0].back.length,1);
});
test('versioned calibration is finite, whitelisted and capped; legacy format is discarded', () => {
  const dirty={commitHands:99,commitHandsV:0.2,swipeSpeed:Infinity,rearmMs:1,returnMs:0,hold:{Thumb_Up:0},fps:500};
  assert.deepEqual(safeTuning(dirty,DEFAULTS),{commitHands:0.34,commitHandsV:0.25,rearmMs:100,returnMs:0});
  const storage=new Map([['yinwei.gestureCal',JSON.stringify({tuned:{swipeHands:0.1}})]]);
  const h=page(storage);assert.equal(storage.has('yinwei.gestureCal'),false);
  const saved=new Map([['yinwei.gestureCal',JSON.stringify({version:2,tuned:{commitHands:0.3}})]]);
  const k=page(saved);k.ready();assert.equal(k.sent.find(x=>x.t==='gestureConfig').config.commitHands,0.3);
  k.el('gesture-cal-reset').onclick();assert.equal(saved.has('yinwei.gestureCal'),false);
});

test('offline inliner discovers both new scripts before ui.js', () => {
  const html=readFileSync(new URL('index.html',base),'utf8');
  assert.ok(html.indexOf('gesture-core.js')<html.indexOf('gesture-ui.js'));
  assert.ok(html.indexOf('gesture-ui.js')<html.indexOf('src="ui.js"'));
  for(const name of ['gesture-core.js','gesture-ui.js'])assert.doesNotMatch(readFileSync(new URL(name,base),'utf8'),/https?:\/\/|getUserMedia|recognizeForVideo/);
});
