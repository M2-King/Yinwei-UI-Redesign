import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {performance} from 'node:perf_hooks';

const base = new URL('../../assets/listen_room/', import.meta.url);
const source = await readFile(new URL('bridge.js', base), 'utf8');
const ui = await readFile(new URL('ui.js', base), 'utf8');
const ctx = vm.createContext({performance});
vm.runInContext(source, ctx);
const B = vm.runInContext('ListenBridge', ctx);

test('unchanged 500-song queue does not count as a queue change', () => {
  const queue = {title:'Queue', playing:0, songs:Array.from({length:500},(_,i)=>({title:`Song ${i}`,artist:`Artist ${i}`}))};
  const S = {}, times = [];
  B.merge(S, {v:1,queue}, {}, 0);
  for (let i=0; i<1000; i++) {
    const start = performance.now();
    assert.equal(B.merge(S, JSON.stringify({v:1,queue}), {}, i).includes('queue'), false);
    times.push((performance.now()-start)*1000);
  }
  times.sort((a,b)=>a-b);
  console.log('TAP_PAGE_BENCH', JSON.stringify({queueBytes:Buffer.byteLength(JSON.stringify(queue)),mergeP50Us:times[500],mergeP95Us:times[950]}));
});

function pausedPage() {
  const S={playing:false,pending:false}, held={};
  B.hold(held,'playing',false,0);
  let now=0;
  const context=vm.createContext({S,held,ListenBridge:B,performance:{now:()=>now},speakerDraft:null,posAt:0,render(){}});
  vm.runInContext(ui.slice(ui.indexOf('function apply(next)'),ui.indexOf('const isCjk')),context);
  return {S,held,
    apply(next,at){now=at;context.next=next;vm.runInContext('apply(next)',context);},
    refused(type){context.type=type;vm.runInContext('commandRefused(type)',context);}};
}

test('tap pause survives completed stale playing snapshot until laptop confirms pause', () => {
  const h=pausedPage();
  h.apply({v:1,pending:true,playing:true},100);
  h.apply({v:1,pending:false,playing:true},1000);
  assert.equal(h.S.playing,false);assert.ok(h.held.playing);
  h.apply({v:1,pending:false,playing:false},1200);
  assert.equal(h.S.playing,false);assert.equal(h.held.playing,undefined);
});

test('unconfirmed pause expires HOLD_MS after the command completes', () => {
  const h=pausedPage();
  h.apply({v:1,pending:true,playing:true},100);
  h.apply({v:1,pending:false,playing:true},5000);
  assert.equal(h.S.playing,false);
  h.apply({v:1,pending:false,playing:true},5000+B.HOLD_MS-1);
  assert.equal(h.S.playing,false);
  h.apply({v:1,pending:false,playing:true},5000+B.HOLD_MS+1);
  assert.equal(h.S.playing,true);assert.equal(h.held.playing,undefined);
});

test('explicit media refusal lets the forced snapshot restore laptop transport immediately', () => {
  const h=pausedPage();
  h.apply({v:1,pending:true,playing:true},100);
  h.refused('media.pause');
  h.apply({v:1,pending:false,playing:true},200);
  assert.equal(h.S.playing,true);assert.equal(h.held.playing,undefined);
});

test('an unrelated command refusal preserves the transport hold', () => {
  const h=pausedPage();h.refused('array.mode');
  h.apply({v:1,pending:false,playing:true},100);
  assert.equal(h.S.playing,false);assert.ok(h.held.playing);
});

test('telemetry deltas retain queue content and row-only deltas retain song identity',()=>{
  const S={};B.merge(S,{v:1,queueRevision:1,queue:{title:'Queue',playing:0,songs:Array.from({length:500},(_,i)=>({title:`Song ${i}`,artist:''}))}},{},0);
  const songs=S.queue.songs, times=[];
  for(let i=0;i<1000;i++){
    const at=performance.now();const changed=B.merge(S,JSON.stringify({v:1,level:i%100/100,queueRevision:1,queuePlaying:i%500}),{},i);
    times.push((performance.now()-at)*1000);assert.equal(S.queue.songs,songs);assert.equal(S.queue.playing,i%500);
    assert.ok(changed.includes('queue')||i===0);
  }
  times.sort((a,b)=>a-b);
  console.log('TAP_DELTA_BENCH',JSON.stringify({mergeP50Us:times[500],mergeP95Us:times[950]}));
  assert.equal(B.merge(S,{v:1,queueRevision:1,queuePlaying:499},{},1001).includes('queue'),false);
  B.merge(S,{v:1,queueRevision:2,queue:null,queuePlaying:-1},{},1002);assert.equal(S.queue,null);
});
