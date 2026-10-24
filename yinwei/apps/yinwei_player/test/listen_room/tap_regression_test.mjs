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

test('completed laptop pause snapshot wins over a held optimistic play', () => {
  const S={playing:true,pending:true}, held={};
  B.hold(held,'playing',true,0);
  let renders=0, now=100;
  const context=vm.createContext({S,held,ListenBridge:B,performance:{now:()=>now},speakerDraft:null,posAt:0,render(){renders++;}});
  vm.runInContext(ui.slice(ui.indexOf('function apply(next)'),ui.indexOf('const isCjk')),context);
  vm.runInContext('apply({v:1,pending:false,playing:false})',context);
  assert.equal(S.playing,false);
  assert.equal(renders,1);
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
