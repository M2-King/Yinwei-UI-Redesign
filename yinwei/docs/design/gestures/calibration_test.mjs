// Offline tests for analyseCalibration (dev/gestures.js) and for the stroke timing it relies on.
import { createRequire } from "module";
import assert from "assert/strict";
const require = createRequire(import.meta.url);
const { createGestureCore, analyseCalibration, GESTURE } = require(process.argv[2]);
let pass = 0; const test = (n, fn) => { fn(); pass++; console.log("ok -", n); };
const S = (dir, travel, peak, ratio = 5, gap = 500) => ({ dir, travel, peak, ratio, gap });
const NAME = { "←": "swipeLeft", "→": "swipeRight", "↑": "swipeUp", "↓": "swipeDown" }, OPP = { "←": "→", "→": "←", "↑": "↓", "↓": "↑" };
// A recording like the owner's: short sideways swipes, long up/down ones; the bring-back starts at once (gap ~0-80 ms).
function recording({ h = 0.3, v = 0.9, hitH = false, altGap = 350 } = {}) {
  const prompts = [];
  for (const dir of ["←", "→", "↑", "↓"]) for (let k = 0; k < 3; k++) {
    const horiz = dir === "←" || dir === "→", before = prompts.length ? prompts[prompts.length - 1].dir : null;
    prompts.push({ dir, strokes: [S(dir, horiz ? h + k * 0.02 : v + k * 0.03, horiz ? 4 : 6, 4)], fired: horiz && !hitH ? [] : [NAME[dir]],
      prep: before ? [S(OPP[before], 0.5, 2.5, 4, 20 + k * 30)] : [] });
  }
  const alt = { strokes: [S("↑", 0.9, 6, 5, null), S("↓", 0.9, 6, 5, altGap), S("↑", 0.85, 5.5, 5, altGap + 40), S("↓", 0.88, 6, 5, altGap + 20)], fired: ["swipeUp", "swipeUp"] };
  return { prompts, alt };
}

test("the report counts hits per direction", () => {
  const r = analyseCalibration(recording(), GESTURE);
  const by = Object.fromEntries(r.rows.map((x) => [x.dir, x]));
  assert.equal(by["←"].hit, 0); assert.equal(by["↑"].hit, 3); assert.equal(by["↓"].tries, 3);
});
test("short sideways swipes lower the sideways distance (70% of the person's median)", () => {
  const r = analyseCalibration(recording({ h: 0.3 }), GESTURE);
  assert.equal(r.tuned.swipeHands, 0.25 > 0.7 * 0.32 ? 0.25 : Math.round(0.7 * 0.32 * 100) / 100);
  assert.ok(r.tuned.swipeHands < GESTURE.swipeHands);
});
test("big test swipes never make everyday swipes harder (capped at the defaults)", () => {
  const r = analyseCalibration(recording({ v: 0.9 }), GESTURE, GESTURE);
  assert.equal(r.tuned.swipeHandsV, GESTURE.swipeHandsV); assert.ok(r.tuned.swipeSpeed <= GESTURE.swipeSpeed); assert.ok(r.tuned.swipeRatio <= GESTURE.swipeRatio);
});
test("small up/down test swipes lower the up/down distance", () => {
  const r = analyseCalibration(recording({ v: 0.4 }), GESTURE, GESTURE);
  assert.equal(r.tuned.swipeHandsV, Math.round(0.7 * 0.43 * 100) / 100);
});
test("speed is tuned from the person's peaks and stays in 2.2-4", () => {
  const r = analyseCalibration(recording(), GESTURE);
  assert.ok(r.tuned.swipeSpeed >= 2.2 && r.tuned.swipeSpeed <= 4, String(r.tuned.swipeSpeed));
});
test("returns start at once and deliberate reverses pause: separable, the return window sits between", () => {
  const r = analyseCalibration(recording({ altGap: 350 }), GESTURE);
  assert.ok(r.tuned.returnMs > 80 && r.tuned.returnMs < 350, String(r.tuned.returnMs)); assert.match(r.notes[0], /可以区分/);
});
test("when the pauses overlap, the return filter stays and the report says why", () => {
  const r = analyseCalibration(recording({ altGap: 40 }), GESTURE);
  assert.equal(r.tuned.returnMs, GESTURE.returnMs); assert.match(r.notes[0], /无法区分/);
});
test("a prompt with no stroke is reported, and keeps the old setting when a whole axis is missing", () => {
  const rec = recording(); rec.prompts.filter((p) => p.dir === "←" || p.dir === "→").forEach((p) => (p.strokes = []));
  const r = analyseCalibration(rec, GESTURE);
  assert.equal(r.tuned.swipeHands, GESTURE.swipeHands); assert.ok(r.notes.some((n) => n.startsWith("←")));
});
test("strokes now carry their start time and the pause since the previous stroke", () => {
  const feed = createGestureCore(GESTURE), out = [];
  const hand = (t, x) => ({ t, hand: true, g: null, score: 0, x, y: 0.5, s: 0.12 });
  const f = []; for (let t = 0; t <= 200; t += 33) f.push(hand(t, 0.6));
  for (let t = 233; t <= 400; t += 33) { const u = (t - 200) / 200, e = u * u * (3 - 2 * u); f.push(hand(t, 0.6 - 0.08 * e)); }
  for (let t = 433; t <= 1300; t += 33) f.push(hand(t, 0.52));
  for (let t = 1333; t <= 1500; t += 33) { const u = (t - 1300) / 200, e = u * u * (3 - 2 * u); f.push(hand(t, 0.52 + 0.08 * e)); }
  for (let t = 1533; t <= 1900; t += 33) f.push(hand(t, 0.6));
  for (const x of f) { const o = feed(x); if (o.stroke) out.push(o.stroke); }
  assert.equal(out.length, 2); assert.equal(out[0].gap, null); assert.ok(out[1].gap > 700 && out[1].gap < 1100, String(out[1].gap)); assert.ok(out[1].t > out[0].t);
});
test("bring-backs recorded right after the swipe (back phase) count as returns", () => {
  const rec = recording({ altGap: 350 }); rec.prompts.forEach((p) => { p.back = p.prep; p.prep = []; });
  rec.prompts.forEach((p) => { p.back = [S(OPP[p.dir], 0.5, 2.5, 4, 30)]; });
  const r = analyseCalibration(rec, GESTURE);
  assert.equal(r.returnGaps.length, 12); assert.match(r.notes[0], /可以区分/);
});
console.log(`${pass} passed`);
