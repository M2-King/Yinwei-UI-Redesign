// Listen Room: the pure room maths (assets/listen_room/room-math.js).
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
const R = await load('room-math.js', 'RoomMath');
const near = (a, b, e = 1e-9) => Math.abs(a - b) <= e;

test('axes and orientation match the engine frame', () => {
  let p = R.toRoom(0, 0, 10);
  assert.ok(near(p[0], 0) && near(p[1], R.EAR) && near(p[2], -R.R10), 'front at 10 m is (0, EAR, -R10)');
  assert.ok(near(R.toRoom(90, 0, 10)[0], R.R10), '+90° is to the right (+X)');
  assert.ok(near(R.toRoom(-90, 0, 10)[0], -R.R10), '-90° is to the left (-X)');
  assert.ok(near(R.toRoom(180, 0, 10)[2], R.R10), '180° is behind (+Z)');
  p = R.toRoom(0, 90, 10);
  assert.ok(near(p[1], R.EAR + R.R10) && near(p[2], 0), '+90° elevation is straight up');
  assert.ok(near(R.roomRadius(10), R.R10), '10 m sits at R10');
});

test('the drag inverse is an exact round trip on the level plane', () => {
  let worst = 0;
  for (let az = -179; az <= 180; az += 7) for (const d of [0.5, 0.8, 1, 1.5, 2, 3.2, 5, 7.5, 10]) for (const el of [0, 20, -30, 60, 75]) {
    const [x, , z] = R.toRoom(az, el, d), at = R.fromRoomPoint(x, z, el);
    assert.equal(at.az, R.wrap(Math.round(az)), `azimuth ${az}° at ${el}°, ${d} m`);
    worst = Math.max(worst, Math.abs(at.d - d));
  }
  assert.ok(worst <= 0.05 + 1e-9, `distance within 0.05 m (worst ${worst.toFixed(3)})`);
  assert.equal(R.fromRoomPoint(R.R10 * 1.2, 0, 0), null, 'outside the room gives null');
});

test('the distance slider covers 0.5–10 m and round-trips', () => {
  assert.equal(R.distToSlider(0.5), 0);
  assert.equal(R.distToSlider(10), 1000);
  for (let d = 0.5; d <= 10.0001; d += 0.1) assert.ok(Math.abs(R.sliderToDist(R.distToSlider(d)) - Math.round(d * 10) / 10) <= 0.05 + 1e-9, `${d.toFixed(1)} m`);
});

test('direction snaps onto 0°, ±30°, ±90° and 180° within 4°', () => {
  for (const [a, want] of [[27, 30], [26, 30], [25, null], [33, 30], [2, 0], [-88, -90], [95, null], [178, 180], [-178, -180], [0, null], [30, null]]) {
    assert.equal(R.snapAz(a), want, `${a}°`);
  }
  assert.equal(R.wrap(-180), 180);
  assert.equal(R.wrap(190), -170);
});

test('on-screen and spoken text', () => {
  for (const [got, want] of [[R.fmtAz(0), 'Front'], [R.fmtAz(35), '35° R'], [R.fmtAz(-90), '90° L'], [R.fmtAz(-180), 'Rear'],
    [R.fmtEl(0), 'Ear level'], [R.fmtEl(20), '+20°'], [R.fmtEl(-15), '−15°'], [R.fmtDist(3.2), '3.2 m'], [R.fmtDist(10), '10 m'],
    [R.sayAz(35), '35° right'], [R.sayAz(-35), '35° left'], [R.sayEl(-15), 'minus 15°'], [R.sayDist(3.2), '3.2 metres']]) assert.equal(got, want);
});

test('2.0 speakers sit at ±30°, 1.8 m (ArrayLayout.stereo2Speakers)', () => {
  assert.deepEqual(JSON.parse(JSON.stringify(R.STEREO_AZ)), [-30, 30]);
  assert.equal(R.STEREO_DIST, 1.8);
});
