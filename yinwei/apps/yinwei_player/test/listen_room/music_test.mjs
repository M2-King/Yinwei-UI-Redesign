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

test('host liked identity gets the English label without renaming regular lists', () => {
  const raw=fixture();raw.lists[0]={...summary,title:'我喜欢的音乐',liked:true};
  raw.list={...raw.list,title:'我喜欢的音乐',liked:true};
  assert.equal(music.clean(raw).lists[0].title,'Liked songs');
  assert.equal(music.clean(raw).list.title,'Liked songs');
  raw.lists[0].liked=false;
  assert.equal(music.clean(raw).lists[0].title,'我喜欢的音乐');
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
const searchFixture = () => ({request:2, available:true, revision:'r1', lists:[summary], list:null, page:null,
  search:{query:'rain', more:false, rows:[{id:'t1', list:'liked_1', snapshot:'new', listTitle:'Liked songs', title:'Soft rain',
    artist:'Night band', durationMs:215000, playable:true}]}});
test('search results keep their own list and snapshot so they play through the normal path', () => {
  const v = music.clean(searchFixture());
  assert.equal(v.search.rows.length, 1);
  assert.deepEqual([v.search.rows[0].list, v.search.rows[0].snapshot, v.search.rows[0].id], ['liked_1', 'new', 't1']);
  assert.equal(v.search.rows[0].listTitle, 'Liked songs');
  assert.equal(v.search.more, false);
});
test('a search row without valid tokens, or too many rows, is rejected', () => {
  const bad = searchFixture(); bad.search.rows[0].list = 'bad token!';
  assert.equal(music.clean(bad), null);
  const many = searchFixture(); many.search.rows = Array.from({length: 51}, (_, n) => ({...searchFixture().search.rows[0], id: `t${n}`}));
  assert.equal(music.clean(many), null);
  const query = searchFixture(); query.search.query = 7;
  assert.equal(music.clean(query), null);
});
test('a search row is playable only when the host says so', () => {
  const raw = searchFixture(); raw.search.rows[0].playable = 'yes';
  assert.equal(music.clean(raw).search.rows[0].playable, false);
});

const onlineFixture = () => ({request:4,kind:'search',query:'rain',revision:'online_revision',
  playbackReady:true,rows:[{id:'opaque_track',title:'Rain',artist:'Fixture',durationMs:200000,playable:true}],modes:[]});
test('online rows preserve only normalized metadata and opaque selection', () => {
  const raw=onlineFixture();raw.cookies='private';raw.rows[0].track_id='7399000000000000001';
  const value=music.cleanOnline(raw);
  assert.equal(value.rows[0].id,'opaque_track');assert.equal(value.rows[0].playable,true);
  assert.equal(JSON.stringify(value).includes('private'),false);
  assert.equal(JSON.stringify(value).includes('7399000000000000001'),false);
});
test('online playback stays disabled until the host proof flag is true', () => {
  const raw=onlineFixture();raw.playbackReady=false;
  assert.equal(music.cleanOnline(raw).rows[0].playable,false);
});
test('online malformed and oversized responses are rejected', () => {
  const many=onlineFixture();many.rows=Array(21).fill(many.rows[0]);assert.equal(music.cleanOnline(many),null);
  const bad=onlineFixture();bad.rows[0].id='luna://bad';assert.equal(music.cleanOnline(bad),null);
  const query=onlineFixture();query.query='😀'.repeat(121);assert.equal(music.cleanOnline(query),null);
  const mode=onlineFixture();mode.kind='unknown';assert.equal(music.cleanOnline(mode),null);
  const duration=onlineFixture();duration.rows[0].durationMs=-1;assert.equal(music.cleanOnline(duration),null);
});
test('online failures have a fixed message and cannot leak provider errors', () => {
  const result=music.cleanOnline({request:4,error:'cookie/path/token'});
  assert.equal(result.error,'Online 汽水 is unavailable. Your cached lists still work.');
});
test('mode catalogue cannot smuggle provider parameters or enable mode selection', () => {
  const raw=onlineFixture();raw.kind='modes';raw.rows=[];
  raw.modes=[{id:'opaque_mode',label:'Focus',scene_mode_id:6,browseable:true}];
  const value=music.cleanOnline(raw);assert.deepEqual(Object.keys(value.modes[0]).sort(),['id','label']);
});
