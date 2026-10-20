import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const dir = new URL('../../assets/listen_room/', import.meta.url);
const source = await readFile(new URL('bridge.js', dir), 'utf8');
const B = vm.runInNewContext(`${source}\nListenBridge`, {});
const speaker = (index = 0) => ({ index, label: index ? 'R' : 'L', az: index ? 30 : -30,
  el: 0, dist: 1.8, gainDb: 0, mute: false, feed: index ? 'right' : 'left' });

test('speaker records are bounded, finite, indexed and copied from app state', () => {
  const raw = [speaker(), speaker(1)];
  const cleaned = B.clean('speakers', raw);
  assert.equal(cleaned.length, 2);
  raw[0].az = 99; assert.equal(cleaned[0].az, -30);
  for (const patch of [{az:NaN}, {el:Infinity}, {dist:0.1}, {gainDb:20}, {index:4}, {mute:1}, {feed:'other'}]) {
    assert.equal(B.clean('speakers', [{...speaker(), ...patch}]), undefined);
  }
  assert.equal(B.clean('speakers', Array.from({length:9}, (_,i) => speaker(i))), undefined);
  assert.equal(B.clean('arrayRevision', -1), undefined);
  assert.equal(B.clean('arrayRevision', 1.5), undefined);
  assert.equal(B.clean('selectedSpeakerIndex', 8), undefined);
});

test('array state and revisions follow the laptop even while Point pose is held', () => {
  const state = { az:10, speakers:[], selectedSpeakerIndex:0, arrayRevision:1 };
  const held = {}; B.hold(held, 'az', 10, 0);
  B.merge(state, {v:1, az:20, speakers:[speaker(), speaker(1)], selectedSpeakerIndex:1,
    arrayRevision:2, speakerControl:true, matrixLinked:true, maxSpeakers:8}, held, 10, {placing:true});
  assert.equal(state.az, 10); assert.equal(state.speakers.length, 2);
  assert.equal(state.arrayRevision, 2); assert.equal(state.selectedSpeakerIndex, 1);
  assert.equal(state.matrixLinked, true);
});

test('speaker preview keeps its starting revision and linked cluster spherical deltas', async () => {
  const ui = await readFile(new URL('ui.js', dir), 'utf8');
  // Execute the actual gesture helpers, before DOM initialization, with the
  // minimal page dependencies; this checks payloads, not copied algorithms.
  const start = ui.indexOf('const S =');
  const end = ui.indexOf('const held =');
  const emitted = [];
  const context = vm.createContext({ send:i=>emitted.push(i), lost:()=>false,
    performance:{now:()=>100}, wrap:a=>((a+540)%360)-180, clamp:(n,a,b)=>Math.min(b,Math.max(a,n)) });
  vm.runInContext(ui.slice(start,end), context);
  context.raw = [speaker(),speaker(1), {...speaker(2),label:'3',az:0,feed:'mid'}];
  vm.runInContext('Object.assign(S,{mode:"stereo2",speakerControl:true,speakers:raw,arrayRevision:9,matrixLinked:true}); beginSpeaker(2); speakerDraft.az=40; speakerDraft.el=10; speakerDraft.dist=3;',context);
  const pose = vm.runInContext('speakerPose(0)',context);
  assert.equal(pose.az,10); assert.equal(pose.el,10); assert.equal(pose.dist,3);
  vm.runInContext('S.arrayRevision=10; commitSpeaker()',context);
  assert.equal(emitted[0].arrayRevision,9); assert.equal(emitted[0].index,2);
  assert.equal(emitted[0].t,'speakerPlace');
});

test('release after laptop takeover or pointer cancellation discards the speaker gesture', async () => {
  const room = await readFile(new URL('room.js', dir), 'utf8');
  const start = room.indexOf('  const end = (e) => {');
  const end = room.indexOf('  gl.addEventListener("pointerup", end);', start);
  for (const [type, draft] of [['pointerup', null], ['pointercancel', {index:2}]]) {
    const sent = [];
    const context = vm.createContext({ pointers:new Map([[1,[0,0]]]), dragging:'speaker',
      speakerDraft:draft, moved:0, local:()=>[0,0], applyInput:()=>{}, performance:{now:()=>0},
      renderSpeakerPlace:()=>{}, speakerIntent:i=>sent.push(i), commitSpeaker:()=>sent.push('commit'),
      downAt:null, glRect:null, input:null, gl:{classList:{remove:()=>{}}} });
    vm.runInContext(`${room.slice(start,end)}\nend({pointerId:1,type:${JSON.stringify(type)}});`,context);
    assert.equal(context.speakerDraft,null); assert.equal(context.dragging,null);
    assert.deepEqual(sent,[]);
  }
});
