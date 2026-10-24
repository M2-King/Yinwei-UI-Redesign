// Listen Room: the page's side of the app bridge (assets/listen_room/bridge.js).
// Run: node --test test/listen_room/
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

// The page's scripts are plain browser scripts: run them in a sandbox, as the
// other browser-script tests do, and take the global they define.
const load = async (file, name) => vm.runInNewContext(
  `${await readFile(new URL(`../../assets/listen_room/${file}`, import.meta.url), 'utf8')}
${name};`, {});
const B = await load('bridge.js', 'ListenBridge');
const base = () => ({laptop: '', live: false, playing: false, listening: 'off', control: 'mine', notice: 'none', mode: 'point',
  motion: 'fixed', orbitHz: 0.4, az: 0, el: 0, dist: 2, track: null, volume: 1, level: 0, stats: {received: 0, bufferMs: 0, underruns: 0}, panel: null});
const state = (extra = {}) => ({v: 1, laptop: 'TIM-LAPTOP', live: true, playing: true, listening: 'on', mode: 'point', az: 35, el: 20, dist: 3.2, ...extra});

test('applies a state message and reports what changed', () => {
  const S = base(), changed = B.merge(S, state(), {}, 0);
  assert.equal(S.laptop, 'TIM-LAPTOP');
  assert.equal(S.az, 35);
  assert.ok(changed.includes('az') && changed.includes('live'));
  assert.deepEqual(JSON.parse(JSON.stringify(B.merge(S, state(), {}, 1))), [], 'the same message changes nothing');
});

test('accepts the JSON text form too', () => {
  const S = base();
  B.merge(S, JSON.stringify(state({mode: 'stereo2'})), {}, 0);
  assert.equal(S.mode, 'stereo2');
});

test('ignores messages of another version, bad JSON and unknown fields', () => {
  const S = base();
  assert.deepEqual(JSON.parse(JSON.stringify(B.merge(S, {...state(), v: 2}, {}, 0))), []);
  assert.deepEqual(JSON.parse(JSON.stringify(B.merge(S, '{not json', {}, 0))), []);
  B.merge(S, {v: 1, hacked: true, panel: 'layout'}, {}, 0);
  assert.equal(S.hacked, undefined);
  assert.equal(S.panel, null, 'page-only fields never come from the app');
});

test('rejects values the page cannot draw and clamps numbers', () => {
  const S = base();
  B.merge(S, {v: 1, mode: 'surround51', listening: 'maybe', az: 999, dist: 0.1, orbitHz: 50, volume: -2, live: 'yes'}, {}, 0);
  assert.equal(S.mode, 'point');
  assert.equal(S.listening, 'off');
  assert.equal(S.az, 180);
  assert.equal(S.dist, 0.5);
  assert.equal(S.orbitHz, 2);
  assert.equal(S.volume, 0);
  assert.equal(S.live, false, 'booleans must be booleans');
});

test('the playlist queue is cleaned, bounded and its playing row validated', () => {
  const S = base();
  B.merge(S, {v: 1, queue: {title: '我喜欢的音乐', playing: 1, songs: [{title: 'A', artist: 'x'}, {title: 'B', artist: 'y'}]}}, {}, 0);
  assert.equal(S.queue.title, '我喜欢的音乐');
  assert.equal(S.queue.playing, 1);
  assert.equal(S.queue.songs.length, 2);
  assert.equal(S.queue.songs[0].title, 'A');
  assert.equal(S.queue.songs[1].artist, 'y');
  // playing out of range → -1 (none highlighted), not a crash
  B.merge(S, {v: 1, queue: {title: 'x', playing: 9, songs: [{title: 'A', artist: ''}]}}, {}, 0);
  assert.equal(S.queue.playing, -1);
  // title/artist coerced to strings; over-long song list and bad shapes rejected to null
  B.merge(S, {v: 1, queue: {title: 7, playing: 0, songs: [{title: 5, artist: null}]}}, {}, 0);
  assert.equal(S.queue.songs[0].title, '5');
  assert.equal(S.queue.songs[0].artist, '');
  for (const bad of [null, 'nope', {songs: 'no'}, {songs: Array(501).fill({title: 'a', artist: 'b'})}, {songs: [1]}]) {
    B.merge(S, {v: 1, queue: bad}, {}, 0);
    assert.equal(S.queue, null, `queue ${JSON.stringify(bad)} → null`);
  }
});

test('the app build is a short plain label or nothing', () => {
  const S = base();
  B.merge(S, {v: 1, appBuild: '61'}, {}, 0);
  assert.equal(S.appBuild, '61');
  B.merge(S, {v: 1, appBuild: '0.1.3+local'}, {}, 0);
  assert.equal(S.appBuild, '0.1.3+local');
  for (const bad of ['<b>61</b>', 'x'.repeat(25), '', 61]) {
    B.merge(S, {v: 1, appBuild: bad}, {}, 0);
    assert.equal(S.appBuild, null, `refuses ${JSON.stringify(bad)}`);
  }
});

test('queue keeps only the established metadata contract, never provider artwork or identities', () => {
  const S=base();
  const input={title:'Queue',playing:0,owner:'private',songs:[{title:'Moon',artist:'Band',artwork:'untrusted',trackId:'123'}]};
  B.merge(S,{v:1,queue:input},{},0);
  assert.deepEqual(Object.keys(S.queue).sort(),['playing','songs','title']);
  assert.deepEqual(Object.keys(S.queue.songs[0]).sort(),['artist','title']);
  input.songs[0].title='Changed outside the bridge';
  assert.equal(S.queue.songs[0].title,'Moon');
});

test('queue permits the bounded 500-row catalogue and unknown playing position', () => {
  const S=base();
  B.merge(S,{v:1,queue:{title:'Queue',playing:-1,songs:Array.from({length:500},(_,i)=>({title:`Song ${i}`,artist:''}))}},{},0);
  assert.equal(S.queue.songs.length,500);assert.equal(S.queue.playing,-1);
  B.merge(S,{v:1,queue:{title:'Queue',playing:500,songs:[{title:'A',artist:''}]}},{},1);
  assert.equal(S.queue.playing,-1);
});

test('a value you just set is kept until the app confirms it', () => {
  const S = base(), held = {};
  B.merge(S, state(), held, 0);
  S.mode = 'stereo2'; B.hold(held, 'mode', 'stereo2', 0);
  B.merge(S, state({mode: 'point'}), held, 100);
  assert.equal(S.mode, 'stereo2', 'the old laptop value does not undo your tap');
  B.merge(S, state({mode: 'stereo2'}), held, 300);
  assert.equal(held.mode, undefined, 'confirmed: the hold ends');
  B.merge(S, state({mode: 'point'}), held, 400);
  assert.equal(S.mode, 'point', 'after that the laptop wins again');
});

test('a hold ends on its own if the laptop never confirms', () => {
  const S = base(), held = {};
  S.mode = 'stereo2'; B.hold(held, 'mode', 'stereo2', 0);
  B.merge(S, state({mode: 'point'}), held, B.HOLD_MS + 1);
  assert.equal(S.mode, 'point');
});

test('positions are compared with a tolerance, and kept while you drag the sound', () => {
  const S = base(), held = {};
  S.az = 30; B.hold(held, 'az', 30, 0);
  B.merge(S, state({az: 30.2}), held, 10);
  assert.equal(held.az, undefined, '30.2° confirms 30°');
  B.merge(S, state({az: 90}), {}, 20, {placing: true});
  assert.equal(S.az, 30.2, 'no position from the app during a drag');
});

test('listening shows "connecting" until the app reports connecting or on', () => {
  const S = base(), held = {};
  S.listening = 'connecting'; B.hold(held, 'listening', 'connecting', 0, (x) => x !== 'off');
  B.merge(S, state({listening: 'off'}), held, 100);
  assert.equal(S.listening, 'connecting');
  B.merge(S, state({listening: 'on'}), held, 200);
  assert.equal(S.listening, 'on');
});

test('orbit: small differences are eased in, big jumps are taken', () => {
  const S = {...base(), mode: 'point', motion: 'orbit', az: 100};
  B.merge(S, state({az: 110, motion: 'orbit'}), {}, 0, {orbiting: true});
  assert.ok(S.az > 100 && S.az < 110, `eased (${S.az})`);
  B.merge(S, state({az: -60, motion: 'orbit'}), {}, 0, {orbiting: true});
  assert.equal(S.az, -60);
});

test('track text is cut to a safe length and the cover tint is stable', () => {
  const S = base();
  B.merge(S, {v: 1, track: {title: 'x'.repeat(500), artist: '周杰伦'}}, {}, 0);
  assert.equal(S.track.title.length, 200);
  assert.equal(B.hueOf('晴天'), B.hueOf('晴天'));
  for (const title of ['晴天', '富士山下', 'Vienna', '']) assert.ok(B.hueOf(title) >= 205 && B.hueOf(title) <= 240, title);
});

test('opens: the music app the laptop opens on Start, or null', () => {
  const S = base();
  B.merge(S, {v: 1, opens: '汽水音乐'}, {}, 0);
  assert.equal(S.opens, '汽水音乐');
  B.merge(S, {v: 1, opens: ''}, {}, 1);
  assert.equal(S.opens, null, 'empty means it cannot open one');
  B.merge(S, {v: 1, opens: 'x'.repeat(300)}, {}, 2);
  assert.equal(S.opens.length, 80);
  B.merge(S, {v: 1, opens: {path: 'C:\evil.exe'}}, {}, 3);
  assert.equal(S.opens, null, 'only a name, never an object');
});

test('progress and pending: known steps only, booleans only', () => {
  const S = base();
  B.merge(S, {v: 1, progress: 'opening', pending: true}, {}, 0);
  assert.equal(S.progress, 'opening');
  assert.equal(S.pending, true);
  B.merge(S, {v: 1, progress: 'format C:', pending: 'yes'}, {}, 1);
  assert.equal(S.progress, null, 'an unknown step clears the progress');
  assert.equal(S.pending, true, 'a non-boolean is ignored');
  B.merge(S, {v: 1, progress: null, pending: false}, {}, 2);
  assert.equal(S.progress, null);
  assert.equal(S.pending, false);
});

test('song progress: seconds clamped, a jump held until the laptop agrees', () => {
  const S = base(), held = {};
  B.merge(S, {v: 1, pos: 83.4, dur: 269, seekable: true}, held, 0);
  assert.deepEqual([S.pos, S.dur, S.seekable], [83.4, 269, true]);
  B.merge(S, {v: 1, pos: -5, dur: 1e9, seekable: 'yes'}, held, 1);
  assert.deepEqual([S.pos, S.dur, S.seekable], [0, 86400, true], 'clamped; a non-boolean is ignored');
  B.hold(held, 'pos', 120, 2);
  B.merge(S, {v: 1, pos: 83}, held, 3);
  assert.notEqual(S.pos, 83, 'the old position does not snap the bar back');
  B.merge(S, {v: 1, pos: 121.5}, held, 4);
  assert.equal(S.pos, 121.5, 'within 2.5 s of the jump: confirmed');
});

test('sound quality: known choices only; stream null until audio; opus a boolean', () => {
  const S = {...base(), quality: 'high', stream: null, opus: false};
  B.merge(S, {v: 1, quality: 'max', stream: 'max', opus: true}, {}, 0);
  assert.deepEqual([S.quality, S.stream, S.opus], ['max', 'max', true]);
  B.merge(S, {v: 1, quality: 'ultra', stream: 'flac', opus: 'yes'}, {}, 1);
  assert.equal(S.quality, 'max', 'an unknown choice is ignored');
  assert.equal(S.stream, null, 'an unknown stream shows as none');
  assert.equal(S.opus, true, 'a non-boolean is ignored');
});

test('queue enforces text limits and integer-only playing indices including empty lists', () => {
  const S = base();
  B.merge(S, {v: 1, queue: {title: 'T'.repeat(150), playing: 0,
    songs: [{title: 'A'.repeat(250), artist: 'B'.repeat(250),
      list: 'private_list', snapshot: 'private_snapshot', track: 'private_track', revision: 'private_revision'}]}}, {}, 0);
  assert.equal(S.queue.title.length, 120);
  assert.equal(S.queue.songs[0].title.length, 200);
  assert.equal(S.queue.songs[0].artist.length, 200);
  assert.ok(!JSON.stringify(S.queue).includes('private_'));
  for (const playing of [-2, 0.5, '0', true, NaN, 1]) {
    B.merge(S, {v: 1, queue: {title: 'Q', playing, songs: [{title: 'A', artist: 'B'}]}}, {}, 1);
    assert.equal(S.queue.playing, -1);
  }
  B.merge(S, {v: 1, queue: {title: 'Empty', playing: 0, songs: []}}, {}, 2);
  assert.equal(S.queue.playing, -1);
  B.merge(S, {v: 1, queue: null}, {}, 3);
  assert.equal(S.queue, null);
});
