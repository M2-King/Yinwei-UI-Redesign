import assert from 'node:assert/strict';

// Math.sin in the recorded jitter can differ in its last bits between V8's
// Windows and macOS implementations. Only frame coordinates allow this bound
// (one trillionth of a frame); hashes, timing, confidence and events stay exact.
export function compareFixtures(actual, expected) {
  let maxCoordinateDelta = 0;
  function visit(a, b, path = '') {
    if (/^\/fixtures\/\d+\/frames\/\d+\/(x|y|s)$/.test(path)
        && typeof a === 'number' && typeof b === 'number'
        && Number.isFinite(a) && Number.isFinite(b)) {
      const delta = Math.abs(a - b);
      assert.ok(delta <= 1e-12, `${path}: coordinate difference ${delta} exceeds 1e-12`);
      maxCoordinateDelta = Math.max(maxCoordinateDelta, delta);
    } else if (a && b && typeof a === 'object' && typeof b === 'object') {
      assert.equal(Array.isArray(a), Array.isArray(b), path);
      assert.deepEqual(Object.keys(a), Object.keys(b), `${path}: fields differ`);
      for (const key of Object.keys(a)) visit(a[key], b[key], `${path}/${key}`);
    } else {
      assert.deepEqual(a, b, path);
    }
  }
  visit(actual, expected);
  return maxCoordinateDelta;
}
