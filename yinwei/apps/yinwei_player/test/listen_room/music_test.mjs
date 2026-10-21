import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const music = vm.runInNewContext(`${await readFile(new URL('../../assets/listen_room/music.js', import.meta.url), 'utf8')}\nListenMusic;`);
const summary = {id:'liked_1', title:'Liked songs', cached:8, total:33, updatedAt:'2026-10-21T02:53:09Z'};
const fixture = () => ({request:1, available:true, revision:'r1', lists:[summary],
  list:{...summary, snapshots:[{...summary,id:'new',historical:false},{...summary,id:'old',cached:31,historical:true}]},
  page:{snapshot:'new',rows:[{id:'track1',title:'<img src=x onerror=alert(1)>',artist:'Artist',durationMs:1000,playable:true}],offset:0,nextOffset:null}});
test('partial cache preserves counts and timestamp; never implies completeness', () => {
  const v=music.clean(fixture());
  assert.equal(v.lists[0].partial,true);
  assert.match(music.note(v.lists[0]),/^8 of 33 cached · updated /);
  assert.equal(v.list.snapshots[1].cached,31);
  assert.equal(v.page.rows.length,1,'older records are not unioned into newest');
});
test('historical snapshot cannot become playable from a host row flag', () => {
  const raw=fixture();raw.page.snapshot='old';
  assert.equal(music.clean(raw).page.rows[0].playable,false);
});
test('unknown total/time stays uncertain and absent pages cannot claim songs', () => {
  const raw=fixture();raw.lists[0]={...summary,total:null,updatedAt:null};raw.list=null;raw.page=null;
  const value=music.clean(raw);
  assert.equal(value.lists[0].partial,true);
  assert.equal(music.note(value.lists[0]),'8 of ? cached · updated unknown');
  assert.equal(value.page,null);
});
test('rejects oversized payloads, foreign snapshot reference and malformed opaque tokens', () => {
  const raw=fixture();raw.page.rows=Array(101).fill(raw.page.rows[0]);assert.equal(music.clean(raw),null);
  const foreign=fixture();foreign.page.snapshot='unlisted';assert.equal(music.clean(foreign),null);
  const uri=fixture();uri.page.rows[0].id='luna://arbitrary';assert.equal(music.clean(uri),null);
  const bad=fixture();bad.lists[0]={...summary,cached:-1};assert.equal(music.clean(bad),null);
});
test('text stays text and private host errors are replaced with a fixed user message', () => {
  assert.equal(music.clean(fixture()).page.rows[0].title,'<img src=x onerror=alert(1)>');
  const value=music.clean({request:2,error:'private path/account/token'});
  assert.equal(value.request,2);assert.ok(!value.error.includes('private path'));
});
test('long track durations remain available, malformed durations stay unknown', () => {
  const raw=fixture();raw.page.rows[0].durationMs=3600000;
  assert.equal(music.clean(raw).page.rows[0].durationMs,3600000);
  raw.page.rows[0].durationMs=86400001;
  assert.equal(music.clean(raw).page.rows[0].durationMs,null);
});
