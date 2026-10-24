import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

const base = new URL('../../assets/listen_room/', import.meta.url);
const ui = await readFile(new URL('ui.js', base), 'utf8');
const room = await readFile(new URL('room.js', base), 'utf8');
const html = await readFile(new URL('index.html', base), 'utf8');
const css = await readFile(new URL('ui.css', base), 'utf8');
class Element {
  constructor(doc) {
    this.doc=doc; this.children=[]; this.dataset={}; this.attrs={}; this.listeners={};
    this.style={setProperty(k,v){this[k]=v;}}; this.classes=new Set(); this.hidden=false;
    this.classList={contains:c=>this.classes.has(c),add:(...cs)=>cs.forEach(c=>this.classes.add(c)),
      remove:(...cs)=>cs.forEach(c=>this.classes.delete(c)),toggle:(c,on)=>{on??=!this.classes.has(c);on?this.classes.add(c):this.classes.delete(c);}};
  }
  setAttribute(k,v){this.attrs[k]=v;}
  toggleAttribute(k,on){this[k]=on;}
  append(...ns){for(const n of ns){n.remove();n.parent=this;this.children.push(n);}}
  replaceChildren(...ns){for(const n of this.children)n.parent=null;this.children=[];this.append(...ns);}
  remove(){if(this.parent){this.parent.children.splice(this.parent.children.indexOf(this),1);this.parent=null;}}
  contains(n){return n===this||this.children.some(c=>c.contains(n));}
  focus(){this.doc.activeElement=this;}
  closest(){return null;}
  querySelector(s){if(s==='.pk-cover')return this.children[0];return this.child??=new Element(this.doc);}
  addEventListener(k,f){(this.listeners[k]??=[]).push(f);}
  getBoundingClientRect(){return {left:20,top:100,width:118,height:118};}
  fire(k,e={}){for(const f of this.listeners[k]||[])f({type:k,target:this,preventDefault(){},...e});}
}
function setup(reduced=false, count=12){
  let now=10000, tid=0; const timers=new Map(), intents=[], modes=[], notices=[];
  const doc={listeners:{},createElement(){return new Element(doc);},addEventListener(k,f){(this.listeners[k]??=[]).push(f);}};
  const els=new Map(); const $=id=>{if(!els.has(id))els.set(id,new Element(doc));return els.get(id);};
  $('pk').hidden=$('pk-bar').hidden=true; $('app').clientHeight=820;$('app').clientWidth=1180;
  const state={queue:count?{title:'Queue',playing:3,songs:Array.from({length:count},(_,i)=>({title:`Song ${i}`,artist:`Artist ${i}`}))}:null,playing:true,pending:false,connection:'connected'};
  let cancelled=0, fired=null;
  const ctx=vm.createContext({$,document:doc,performance:{now:()=>now},reduced,
    clamp:(v,a,b)=>Math.max(a,Math.min(b,v)),S:state,ListenBridge:{hueOf:()=>220},paintArt(){},artVariant:()=>0,isCjk:()=>false,
    closePop(){},closeMenus(){},act(){},otherHasControl:()=>state.control==='other',lost:()=>false,
    toast:t=>notices.push(t),send:i=>intents.push(i),browseCamera:m=>modes.push(m),stopFire(){cancelled++;fired=null;},
    fireToWindows(){fired=vm.runInContext('winOffset',ctx);},three:{panes:Array(8)},frontPane:()=>3,panesInView:()=>[1,6],
    getComputedStyle:()=>({getPropertyValue:()=>''}),
    setTimeout(f,ms){timers.set(++tid,{f,at:now+ms});return tid;},clearTimeout:id=>timers.delete(id),
    requestAnimationFrame:f=>f(),addEventListener(){},innerWidth:1180,innerHeight:820,
    isOpen:()=>false,BROWSE_LOOK:{on:false},camMoving:false});
  vm.runInContext(ui.slice(ui.indexOf('const PK ='),ui.indexOf('function placePop()')),ctx);
  const run=c=>vm.runInContext(c,ctx);
  const advance=ms=>{now+=ms;for(const [i,t] of [...timers])if(t.at<=now){timers.delete(i);t.f();}};
  return {run,$,doc,state,intents,modes,notices,advance,cancelled:()=>cancelled,fired:()=>fired};
}

test('only valid adjacent modes are accepted; invalid album/window jumps go through compact',()=>{
  const h=setup(); h.run('setBrowseMode("bogus")');assert.equal(h.run('browseMode'),'album');
  h.run('setBrowseMode("window")');assert.equal(h.run('browseMode'),'compact');
  h.run('setBrowseMode("window");setBrowseMode("album")');assert.equal(h.run('browseMode'),'compact');
  h.run('setBrowseMode("album")');assert.equal(h.run('browseMode'),'album');assert.equal(h.doc.activeElement,h.$('art'));
  assert.deepEqual(h.intents,[]);assert.equal(h.state.playing,true);
});
test('cover tap, 450ms hold, Enter and Space each open once',()=>{
  for(const gesture of ['tap','hold','Enter',' ']){
    const h=setup();h.run('initBrowse()');const art=h.$('art');
    if(['tap','hold'].includes(gesture)){
      art.fire('pointerdown',{clientX:10,clientY:10,button:0});
      h.advance(gesture==='hold'?450:100);art.fire('pointerup');
    }else art.fire('keydown',{key:gesture});
    assert.equal(h.run('browseMode'),'compact',gesture);assert.equal(h.modes.length,1);assert.deepEqual(h.intents,[]);
  }
});
test('cover drag/cancel never opens, even after hold delay',()=>{
  for(const kind of ['pointermove','pointercancel','pointerleave']){
    const h=setup();h.run('initBrowse()');const art=h.$('art');
    art.fire('pointerdown',{clientX:0,clientY:0});art.fire(kind,{clientX:30,clientY:0});h.advance(500);art.fire('pointerup');
    assert.equal(h.run('browseMode'),'album');
  }
});
test('browse and mode changes never play; explicit selection uses queuePlay without changing host state',()=>{
  const h=setup();h.run('setBrowseMode("compact");pkBrowse(2)');assert.deepEqual(h.intents,[]);
  h.run('pkSelect(5)');assert.deepEqual(JSON.parse(JSON.stringify(h.intents)),[{t:'queuePlay',i:5}]);
  assert.equal(h.state.queue.playing,3);
  h.run('setBrowseMode("window")');assert.equal(h.fired(),5,'volley uses the new focused offset before launching');
  h.run('winBrowse(1);winTap(6)');assert.equal(h.state.queue.playing,3);assert.equal(h.intents[1].i,6);
});
test('permissions protect explicit selection and metadata updates repaint same-length queues',()=>{
  const h=setup();h.run('setBrowseMode("compact")');const row=h.run('pkRows.get(3).el');
  h.state.queue.songs[3].title='Changed';h.run('syncBrowse()');assert.notEqual(h.run('pkRows.get(3).el'),row);
  h.state.pending=true;h.run('syncBrowse();pkSelect(4)');assert.equal(h.run('pkRows.get(3).el.attrs["aria-disabled"]'),'true');assert.deepEqual(h.intents,[]);assert.match(h.notices[0],/pending/);
});
test('empty queue stays compact; disappearing queue exits windows without stale hits',()=>{
  const empty=setup(false,0);empty.run('setBrowseMode("compact");setBrowseMode("window")');assert.equal(empty.run('browseMode'),'compact');assert.equal(empty.$('pk-expand').disabled,true);
  const h=setup();h.run('setBrowseMode("compact");setBrowseMode("window")');h.state.queue=null;h.run('syncBrowse()');assert.equal(h.run('browseMode'),'compact');
});
test('100 deterministic random switches and final close clear inert/focus/timers and preserve playback',()=>{
  const h=setup();let seed=17;
  for(let i=0;i<100;i++){seed=(seed*1664525+1013904223)>>>0;h.run(`setBrowseMode("${['album','compact','window'][seed%3]}")`);h.advance(10);}
  h.run('setBrowseMode("album");setBrowseMode("album")');h.advance(1000);
  assert.equal(h.run('browseMode'),'album');assert.equal(h.$('pk').hidden,true);assert.equal(h.$('pk-bar').hidden,true);
  assert.equal(h.$('player').inert,false);assert.equal(h.doc.activeElement,h.$('art'));assert.deepEqual(h.intents,[]);assert.equal(h.state.playing,true);assert.equal(h.fired(),null);
});
test('markup retires stack/list trigger and provides the complete accessible picker group',()=>{
  for(const id of ['pk','pk-group','pk-bg-a','pk-bg-b','pk-expand','pk-bar','pk-bar-btn','win-list'])assert.ok(html.includes(`id="${id}"`),id);
  assert.match(html,/id="art"[^>]*role="button"[^>]*tabindex="0"/);
  for(const old of ['queue-stack.js','cover-trigger','list-btn','q-pedestal'])assert.ok(!html.includes(old));
  assert.ok(!css.includes('.q-pedestal'));assert.match(css,/\.pk-group[^}]*preserve-3d/);
  assert.ok(!/\.pk-row\s*\{[^}]*backdrop-filter/.test(css));
});
test('window/volley wiring preserves camera-space launch, physical occlusion, idle animation and reduced fade',()=>{
  for(const marker of ['panes.push({ mid, w, r:', 'readLight, sky, panes,', 'pkOrient(dt)', 'updateWindowDisplays(dt, now)', 'camera.worldToLocal', 'camera.localToWorld', 'function stopFire()', 'if (reduced || !three', 'Math.abs(a - winAnchor)', 'FIRE.trailW', 'FIRE.flashGain', 'intersectObjects(three.scene.children, true)', 'if (busy || moving) camMoving = true'])assert.ok(room.includes(marker),marker);
  assert.match(ui,/prev === "window"\) stopFire\(\)/);
});

test('pane hit ignores lines/points and invisible materials but respects opaque furniture',()=>{
  const pane={userData:{pane:0}}, blockers=[];
  const ctx=vm.createContext({wd:{hits:[pane],panes:[{cur:4}]},winK:1,ndc:()=>({}),
    three:{camera:{},scene:{children:[]},raycaster:{setFromCamera(){},
      intersectObjects:(objects)=>objects[0]===pane?[{distance:10,object:pane}]:blockers}}});
  vm.runInContext(room.slice(room.indexOf('function windowHitTest('),room.indexOf('// ---------------------------------------------------------------- input')),ctx);
  const hit=()=>vm.runInContext('windowHitTest(10,10)',ctx);
  const mat={depthWrite:true,opacity:1};
  blockers.push({distance:5,object:{visible:true,isMesh:false,material:mat}});
  blockers.push({distance:5,object:{visible:true,isMesh:true,material:{...mat,visible:false}}});
  assert.equal(hit().song,4);
  blockers.push({distance:5,object:{visible:true,isMesh:true,material:mat}});
  assert.equal(hit(),null);
  blockers[2].object.parent={visible:false};assert.equal(hit().song,4);
});
test('reduced-motion volley clears shots and uses the ordinary window fade',()=>{
  const ctx=vm.createContext({reduced:true,three:{},clamp:()=>0});
  vm.runInContext(room.slice(room.indexOf('const WIN ='),room.indexOf('// ---------------------------------------------------------------- input')),ctx);
  vm.runInContext('fire={};fireToWindows(10,10,76)',ctx);
  assert.equal(vm.runInContext('fire',ctx),null);
});

for (const mode of ['compact','window']) test(`ten ${mode} taps each dispatch or explain`,()=>{
  const h=setup();h.run('setBrowseMode("compact")');if(mode==='window')h.run('setBrowseMode("window")');
  for(let i=0;i<10;i++){
    h.state.pending=i%2===1;h.run('syncBrowse()');
    h.run(mode==='compact'?'pkSelect(4)':'winTap(4)');
  }
  assert.equal(h.intents.length,5);assert.equal(h.notices.length,5);
  assert.ok(h.notices.every(t=>t.includes('pending')));
});
test('telemetry and playing-index changes keep queue cards and metadata signature stable',()=>{
  const h=setup(false,500);h.state.queueRevision=1;h.run('setBrowseMode("compact")');
  const songs=h.state.queue.songs, row=h.run('pkRows.get(3).el'), sig=h.run('pkSig()');
  for(let i=0;i<100;i++){
    h.state.queue={...h.state.queue,playing:i%500};h.state.level=i/100;h.run('syncBrowse()');
    assert.equal(h.run('pkSig()'),sig);assert.equal(h.run('pkRows.get(3).el'),row);
  }
  assert.equal(h.state.queue.songs,songs);
});
