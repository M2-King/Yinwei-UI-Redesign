import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../../assets/listen_room/music.js', import.meta.url), 'utf8');
// Small DOM surface for the sheet's real event handlers, response fencing and rendering.
class Element {
  children = []; hidden = false; disabled = false; value = ''; className = ''; attrs = {};
  listeners = {}; parent = null; text = '';
  set textContent(v) { this.text = v; this.children = []; }
  get textContent() { return this.text + this.children.map(c => c.textContent).join(''); }
  append(...children) { for (const child of children) {child.parent = this; this.children.push(child);} }
  replaceChildren(...children) { this.text = ''; this.children = []; this.append(...children); }
  setAttribute(k, v) { this.attrs[k] = v; }
  focus() {}
  remove() { this.parent.children = this.parent.children.filter(c => c !== this); }
  addEventListener(k, callback) { this.listeners[k] = callback; }
  querySelectorAll(selector) {
    return this.children.flatMap(c => [ ...(selector.startsWith('.') && c.className.split(' ').includes(selector.slice(1)) ? [c] : []), ...c.querySelectorAll(selector)]);
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
}
function sheet() {
  const elements = new Map(), timers = new Map(), sent = [], notices = [];
  const state = {music:true, musicSearch:true, musicOnline:true, connection:"connected", control:"mine", pending:false};
  let id = 0;
  const el = name => {if (!elements.has(name)) elements.set(name, new Element()); return elements.get(name);};
  const document = {getElementById:el, createElement:() => new Element()};
  const music = vm.runInNewContext(`${source}\nListenMusic`, {document,
    setTimeout:(fn, ms) => {timers.set(++id, {fn, ms}); return id;}, clearTimeout:id => timers.delete(id)});
  const view = music.create({send:v => sent.push(v), state:() => state, toast:t => notices.push(t)});
  el('music-btn').onclick();
  return {el, sent, view, music, timers, state, notices,
    type(value) {el('music-search').value = value; el('music-search').listeners.input({target:el('music-search')});},
    enter() {el('music-search').listeners.keydown({key:'Enter',target:el('music-search'),preventDefault(){}});},
    flush() {const tasks=[...timers.values()]; timers.clear(); for (const task of tasks) task.fn();},
    cached(request, query) {view.receive({request,available:true,revision:'cached',lists:[],search:{query,rows:[],more:false}});},
    online(request, query) {view.receiveOnline({request,kind:'search',query,revision:'online',rows:[{id:'row',title:query,
      artist:'Fixture',durationMs:1000,playable:false}],modes:[],playbackReady:false});}
  };
}
test('fast typing sends one settled search, never shows an old reply during debounce', () => {
  const s=sheet();
  s.type('first'); s.flush();
  const first=s.sent.at(-1);
  for (const query of ['n','ne','new','newe','newest']) s.type(query);
  s.online(first.request,'first');
  assert.equal(s.el('music-body').textContent.includes('first'),false);
  assert.equal(s.timers.size,1);
  assert.equal([...s.timers.values()][0].ms,600);
  s.flush();
  const online=s.sent.at(-1), cached=s.sent.at(-2);
  assert.equal(online.query,'newest');
  assert.equal(s.sent.filter(v => v.t==='musicOnline').length,2);
  // Online may return before the cache; repainting cache must preserve it.
  s.online(online.request,'newest'); s.cached(cached.request,'newest');
  assert.match(s.el('music-body').textContent,/In your lists/);
  assert.match(s.el('music-body').textContent,/newest/);
  assert.doesNotMatch(s.el('music-body').textContent,/Reading 汽水/);
});
test('Enter cancels debounce and repeated Enter does not duplicate an active query', () => {
  const s=sheet(); s.type('rain'); s.enter(); s.enter(); s.flush();
  assert.equal(s.sent.filter(v => v.t==='musicOnline').length,1);
  s.cached(s.sent.at(-2).request,'rain'); s.enter();
  assert.equal(s.sent.filter(v => v.t==='musicOnline').length,1,'online is still active');
});
test('editing away and back to the in-flight query still sends a current request', () => {
  for (const enter of [false,true]) {
    const s=sheet(); s.type('rain'); s.flush(); const old=s.sent.at(-1);
    s.type('rai'); s.type('rain');
    if (enter) s.enter(); else s.flush();
    const latest=s.sent.at(-1);
    assert.equal(latest.query,'rain'); assert.notEqual(latest.request,old.request);
    s.online(old.request,'rain');
    assert.doesNotMatch(s.el('music-body').textContent,/Anonymous results/);
    s.online(latest.request,'rain');
    assert.match(s.el('music-body').textContent,/Anonymous results/);
  }
});
test('ten successive searches and an intervening error never wedge the sheet', () => {
  const s=sheet();
  for (let i=0;i<10;i++) {
    const query=`song${i}`; s.type(query); s.flush();
    const online=s.sent.at(-1), cached=s.sent.at(-2);
    s.cached(cached.request,query);
    if (i===3) s.view.receiveOnline({request:online.request,error:'secret',errorCode:'soda_online_timeout'});
    else s.online(online.request,query);
    assert.equal(s.el('music-refresh').disabled,false);
    assert.doesNotMatch(s.el('music-body').textContent,/Reading 汽水|secret/);
    if (i!==3) assert.match(s.el('music-body').textContent,new RegExp(query));
  }
  s.el('music-close').onclick();
  s.online(s.sent.filter(v=>v.t==='musicOnline').at(-1).request,'late');
  assert.equal(s.el('music-body').textContent,'');
});
test('provider errors use only fixed allowlisted messages, never raw content or automatic retries', () => {
  const s=sheet(); s.type('rain'); s.flush(); const count=s.sent.length;
  s.view.receiveOnline({request:s.sent.at(-1).request,error:'secret',errorCode:'soda_online_rate_limited'});
  assert.match(s.el('music-body').textContent,/limiting searches/);
  assert.doesNotMatch(s.el('music-body').textContent,/secret/);
  assert.equal(s.sent.length,count); assert.equal(s.timers.size,0);
  assert.equal(s.music.cleanOnline({request:1,error:'secret',errorCode:'__proto__'}).error,
    'Online 汽水 is unavailable. Your cached lists still work.');
});

for (const online of [false, true]) test(`ten ${online ? 'online' : 'cached'} sheet taps each send or explain`, () => {
  const s=sheet();
  s.type('rain'); s.flush();
  const request=s.sent.findLast(v=>v.t===(online?'musicOnline':'musicBrowse')).request;
  const row={id:'row',title:'Rain',artist:'Fixture',durationMs:1000,playable:true};
  if (online) s.cached(s.sent.findLast(v=>v.t==='musicBrowse').request,'rain');
  if (online) s.view.receiveOnline({request,kind:'search',query:'rain',revision:'online',rows:[row],modes:[],playbackReady:true});
  else s.view.receive({request,available:true,revision:'cached',lists:[],search:{query:'rain',rows:[{...row,list:'liked',snapshot:'latest'}],more:false}});
  const button=s.el('music-body').querySelector('.music-track'); assert.ok(button);
  const before=s.sent.length;
  for(let i=0;i<10;i++) {
    s.state.pending=i%2===1; s.view.update();
    assert.equal(button.disabled,false,'pending taps can reach the explanation');
    button.onclick();
  }
  assert.equal(s.sent.length-before,5); assert.equal(s.notices.length,5);
  assert.ok(s.notices.every(t=>t.includes('pending')));
});
