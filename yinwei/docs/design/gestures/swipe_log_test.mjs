// Offline tests for the measurement panel's log (createSwipeLog), fed with the detector's own strokes.
import { createRequire } from "module";
import assert from "assert/strict";
const require = createRequire(import.meta.url);
const { createGestureCore, createSwipeLog, GESTURE } = require(process.argv[2]);
const STEP = 33;
const hand = (t, x, y = 0.5) => ({ t, hand: true, g: null, score: 0, x, y, s: 0.12 });
const still = (t0, ms, x) => { const o = []; for (let t = t0; t <= t0 + ms; t += STEP) o.push(hand(t, x)); return o; };
const stroke = (t0, ms, x0, x1) => { const o = []; for (let t = t0 + STEP; t <= t0 + ms; t += STEP) { const u = (t - t0) / ms, e = u * u * (3 - 2 * u); o.push(hand(t, x0 + (x1 - x0) * e)); } return o; };
function play(frames) { const core = createGestureCore(GESTURE), log = createSwipeLog(); for (const f of frames) log.feed(f, core(f)); return log.log; }
let pass = 0; const test = (n, fn) => { fn(); pass++; console.log("ok -", n); };

test("a swipe is logged as fired, with direction, travel and need", () => {
  const log = play([...still(0, 200, 0.6), ...stroke(200, 200, 0.6, 0.52), ...still(400, 300, 0.52)]);
  assert.equal(log.length, 1); assert.equal(log[0].fired, "swipeLeft"); assert.equal(log[0].why, "已触发"); assert.ok(log[0].need <= 0.45 && log[0].need >= 0.29, `need ${log[0].need}`);
  assert.ok(log[0].travel >= 0.6, JSON.stringify(log[0]));
});
test("a short flick is logged as 距离不够", () => {
  const log = play([...still(0, 200, 0.6), ...stroke(200, 100, 0.6, 0.57), ...still(300, 300, 0.57)]);
  assert.equal(log.length, 1); assert.ok(log[0].why.includes("距离不够"), log[0].why);
});
test("the return stroke is logged as 回程忽略 or the cooldown, never fired", () => {
  const log = play([...still(0, 200, 0.6), ...stroke(200, 200, 0.6, 0.52), ...stroke(400, 300, 0.52, 0.6), ...still(700, 300, 0.6)]);
  assert.equal(log.length, 2); assert.equal(log[0].fired, null); assert.ok(["回程忽略", "冷却中"].includes(log[0].why), log[0].why); assert.equal(log[1].fired, "swipeLeft");
});
test("holding still logs nothing", () => { assert.equal(play(still(0, 3000, 0.5)).length, 0); });
test("the log never changes what fires", () => {
  const frames = [...still(0, 200, 0.6), ...stroke(200, 200, 0.6, 0.52), ...still(400, 300, 0.52)];
  const a = createGestureCore(GESTURE), b = createGestureCore(GESTURE), log = createSwipeLog();
  const plain = frames.map((f) => a(f).event).filter(Boolean), withLog = frames.map((f) => { const o = b(f); log.feed(f, o); return o.event; }).filter(Boolean);
  assert.deepEqual(withLog, plain);
});
console.log(`${pass} passed`);
