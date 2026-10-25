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
const { createActions, createCalibration, create, safeTuning } = load('gesture-ui.js');
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
  const frame = (elapsed, g = 'Open_Palm', hand = true) => { now = 10000 + elapsed; api.frame({ t: 1000000 + elapsed, hand, g, score: 0.9, x: 0.5, y: 0.4, s: 0.12 }); };
  return { ...h, api, sent, said, frame, el: doc.getElementById.bind(doc), storage };
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
test('20 fps holds use normalized native time and fire only once until release', () => {
  const h = page(); h.api.update({on:true, active:true});
  for (let t=0;t<=1000;t+=50) h.frame(t);
  assert.deepEqual(h.calls, [['mode','compact']]); assert.equal(h.said.length,1);
});
test('a paused preference can be switched off without reopening the camera', () => {
  const h = page(); h.api.update({on:true, active:false, consent:true});
  h.el('gesture-off').onclick();
  assert.deepEqual(h.sent, [{t:'gestures',on:false}]);
});
test('off and interrupted pages discard frames and reset partial holds', () => {
  const h=page(); for(let t=0;t<=700;t+=50)h.frame(t); assert.deepEqual(h.calls,[]);
  h.api.update({on:true,active:true}); h.frame(800); h.frame(1000);
  h.api.update({active:false}); h.frame(1400); assert.deepEqual(h.calls,[]);
  h.api.update({active:true}); h.frame(1450); h.frame(1600); assert.deepEqual(h.calls,[]);
});
test('nothing fires during calibration, including held confirm and swipes', () => {
  const h=page(); h.api.update({on:true,active:true}); h.el('gesture-calibrate').onclick();
  for(let t=0;t<1200;t+=50)h.frame(t,'Thumb_Up');
  for(let t=1200;t<1600;t+=50)h.api.frame({t:1000000+t,hand:true,g:null,score:0,x:0.5-(t-1200)/400*0.2,y:0.4,s:0.12});
  assert.deepEqual(h.calls,[]); assert.deepEqual(h.sent,[]);
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
test('saved tuning is finite, whitelisted and capped; restoring defaults clears storage', () => {
  const dirty={swipeHands:99,swipeHandsV:0.2,swipeSpeed:Infinity,returnMs:0,hold:{Thumb_Up:0},fps:500};
  assert.deepEqual(safeTuning(dirty,core.GESTURE),{swipeHands:0.45,swipeHandsV:0.2,returnMs:0});
  const storage=new Map([['yinwei.gestureCal',JSON.stringify({tuned:{swipeHands:99}})]]);
  const h=page(storage);h.el('gesture-cal-reset').onclick();assert.equal(storage.has('yinwei.gestureCal'),false);
});
test('offline inliner discovers both new scripts before ui.js', () => {
  const html=readFileSync(new URL('index.html',base),'utf8');
  assert.ok(html.indexOf('gesture-core.js')<html.indexOf('gesture-ui.js'));
  assert.ok(html.indexOf('gesture-ui.js')<html.indexOf('src="ui.js"'));
  for(const name of ['gesture-core.js','gesture-ui.js'])assert.doesNotMatch(readFileSync(new URL(name,base),'utf8'),/https?:\/\/|getUserMedia|recognizeForVideo/);
});
