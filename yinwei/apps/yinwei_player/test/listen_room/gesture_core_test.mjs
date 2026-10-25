import { fileURLToPath } from "node:url";
// Offline tests for the gesture core in dev/gestures.js (per-stroke swipes), recorded-style frames at 30 fps.
import { readFileSync } from "node:fs";
import assert from "assert/strict";
const require = path => { const module = { exports: {} }; new Function("module", readFileSync(path, "utf8"))(module); return module.exports; };
const { createGestureCore, GESTURE } = require(process.argv[2] || fileURLToPath(new URL("../../assets/listen_room/gesture-core.js", import.meta.url)));

const STEP = 33;
const outs = (frames) => { const feed = createGestureCore(GESTURE); const out = frames.map(feed); globalThis.__yinweiGestureFixtures?.record(frames, out); return out; };
const run = (frames) => outs(frames).filter((o) => o.event).map((o) => o.event);
const seq = (ms, fn, t0 = 0) => { const out = []; for (let t = t0; t <= t0 + ms; t += STEP) out.push({ s: 0.12, ...fn(t, (t - t0) / ms) }); return out; };
const jitter = (k) => (Math.sin(k * 12.9898) * 43758.5453 % 1) * 0.012; // small, deterministic hand tremor
const hand = (t, x, y, s = 0.12) => ({ t, hand: true, g: null, score: 0, x, y, s });
const still = (t0, ms, x, y = 0.5, s = 0.12) => seq(ms, (t) => hand(t, x, y, s), t0);
// A stroke from (x0,y0) to (x1,y1) over ms, with a smooth (ease in-out) speed profile like a real hand.
const stroke = (t0, ms, x0, y0, x1, y1, s = 0.12) => { const o = []; for (let t = t0 + STEP; t <= t0 + ms; t += STEP) { const u = (t - t0) / ms, e = u * u * (3 - 2 * u); o.push(hand(t, x0 + (x1 - x0) * e, y0 + (y1 - y0) * e, s)); } return o; };
let pass = 0;
const test = (name, fn) => { globalThis.__yinweiGestureFixtures?.begin(name); fn(); pass++; console.log("ok -", name); };

// ---- poses (unchanged behaviour)
test("open palm held 0.6 s fires once", () => {
  assert.deepEqual(run(seq(600, (t) => ({ t, hand: true, g: "Open_Palm", score: 0.9, x: 0.5 + jitter(t), y: 0.5 }))), ["Open_Palm"]);
});
test("a flashed palm (0.12 s) does nothing", () => {
  assert.deepEqual(run(seq(120, (t) => ({ t, hand: true, g: "Open_Palm", score: 0.9, x: 0.5, y: 0.5 }))), []);
});
test("holding a pose for 3 s fires only once", () => {
  assert.deepEqual(run(seq(3000, (t) => ({ t, hand: true, g: "Thumb_Up", score: 0.9, x: 0.5 + jitter(t), y: 0.5 }))), ["Thumb_Up"]);
});
test("let go and show it again: fires again", () => {
  const a = seq(700, (t) => ({ t, hand: true, g: "Thumb_Up", score: 0.9, x: 0.5, y: 0.5 }));
  const b = seq(400, (t) => ({ t, hand: true, g: null, score: 0, x: 0.5, y: 0.5 }), 733);
  const c = seq(700, (t) => ({ t, hand: true, g: "Thumb_Up", score: 0.9, x: 0.5, y: 0.5 }), 1166);
  assert.deepEqual(run([...a, ...b, ...c]), ["Thumb_Up", "Thumb_Up"]);
});
test("low confidence never fires", () => {
  assert.deepEqual(run(seq(1500, (t) => ({ t, hand: true, g: "Closed_Fist", score: 0.4, x: 0.5, y: 0.5 }))), []);
});

// ---- the new swipe rules
test("a natural swipe (0.5 hand-sizes, fast) now fires", () => {
  assert.deepEqual(run([...still(0, 200, 0.6), ...stroke(200, 200, 0.6, 0.5, 0.6 - 0.5 * 0.12, 0.5), ...still(400, 300, 0.54)]), ["swipeLeft"]);
});
test("the same distance done slowly (peak under 3 hand-sizes/s) does not", () => {
  assert.deepEqual(run([...still(0, 200, 0.6), ...stroke(200, 600, 0.6, 0.5, 0.6 - 0.5 * 0.12, 0.5), ...still(800, 300, 0.54)]), []);
});
test("a quick but tiny flick (0.3 hand-sizes) does not", () => {
  assert.deepEqual(run([...still(0, 200, 0.6), ...stroke(200, 100, 0.6, 0.5, 0.6 - 0.3 * 0.12, 0.5), ...still(300, 300, 0.564)]), []);
});
test("swipe right, up and down fire in their direction", () => {
  assert.deepEqual(run([...still(0, 200, 0.4), ...stroke(200, 200, 0.4, 0.5, 0.48, 0.5), ...still(400, 300, 0.48)]), ["swipeRight"]);
  assert.deepEqual(run([...still(0, 200, 0.5, 0.6), ...stroke(200, 200, 0.5, 0.6, 0.5, 0.54), ...still(400, 300, 0.5, 0.54)]), ["swipeUp"]);
  assert.deepEqual(run([...still(0, 200, 0.5, 0.4), ...stroke(200, 200, 0.5, 0.4, 0.5, 0.46), ...still(400, 300, 0.5, 0.46)]), ["swipeDown"]);
});
test("ratio 1.2: a slightly slanted swipe counts, a diagonal one does not", () => {
  assert.deepEqual(run([...still(0, 200, 0.6), ...stroke(200, 200, 0.6, 0.5, 0.52, 0.55), ...still(400, 300, 0.52, 0.55)]), ["swipeLeft"]);
  assert.deepEqual(run([...still(0, 200, 0.6), ...stroke(200, 200, 0.6, 0.5, 0.53, 0.565), ...still(400, 300, 0.53, 0.565)]), []);
});
test("flick and bring the hand back: only the flick fires", () => {
  assert.deepEqual(run([...still(0, 200, 0.6), ...stroke(200, 200, 0.6, 0.5, 0.52, 0.5), ...stroke(400, 300, 0.52, 0.5, 0.6, 0.5), ...still(700, 300, 0.6)]), ["swipeLeft"]);
});
test("a flick that falls short, then a quick return: the return is ignored (no wrong direction)", () => {
  assert.deepEqual(run([...still(0, 200, 0.5, 0.5), ...stroke(200, 120, 0.5, 0.5, 0.5, 0.53), ...stroke(320, 200, 0.5, 0.53, 0.5, 0.47), ...still(520, 300, 0.5, 0.47)]), []);
});
test("left, back, left again (after the cooldown): two lefts, no right", () => {
  const f = [...still(0, 200, 0.6), ...stroke(200, 200, 0.6, 0.5, 0.52, 0.5), ...stroke(400, 250, 0.52, 0.5, 0.6, 0.5), ...still(650, 200, 0.6),
    ...stroke(850, 200, 0.6, 0.5, 0.52, 0.5), ...still(1050, 300, 0.52)];
  assert.deepEqual(run(f), ["swipeLeft", "swipeLeft"]);
});
test("left then a deliberate right a second later: both fire", () => {
  const f = [...still(0, 200, 0.6), ...stroke(200, 200, 0.6, 0.5, 0.52, 0.5), ...still(400, 1000, 0.52), ...stroke(1400, 200, 0.52, 0.5, 0.6, 0.5), ...still(1600, 300, 0.6)];
  assert.deepEqual(run(f), ["swipeLeft", "swipeRight"]);
});
test("fast swipe that blurs out mid-way still counts", () => {
  const f = [...still(0, 200, 0.6), ...stroke(200, 100, 0.6, 0.5, 0.56, 0.5), { t: 333, hand: false }, { t: 366, hand: false }];
  assert.deepEqual(run(f), ["swipeLeft"]);
});
test("a one-frame dropout in the middle does not break a swipe", () => {
  const a = [...still(0, 200, 0.6), ...stroke(200, 66, 0.6, 0.5, 0.58, 0.5)];
  const f = [...a, { t: 300, hand: false }, ...stroke(300, 133, 0.58, 0.5, 0.54, 0.5), ...still(433, 300, 0.54)];
  assert.deepEqual(run(f), ["swipeLeft"]);
});
test("a hand that disappears while still does nothing", () => {
  assert.deepEqual(run([...seq(400, (t) => hand(t, 0.5 + jitter(t), 0.5)), { t: 433, hand: false }, { t: 466, hand: false }]), []);
});
test("a slow drift across the frame is not a swipe, and not a hold", () => {
  assert.deepEqual(run(seq(3000, (t, u) => ({ t, hand: true, g: "Open_Palm", score: 0.9, x: 0.3 + 0.4 * u, y: 0.5 }))), []);
});
test("tremor alone never swipes (jitter up to 1.2% of the frame per frame, several times real tracking noise)", () => {
  assert.deepEqual(run(seq(6000, (t) => hand(t, 0.5 + jitter(t), 0.5 + jitter(t + 7)))), []);
});
test("a single-frame jump (tracking glitch) never fires", () => {
  assert.deepEqual(run([...still(0, 300, 0.5), hand(333, 0.44, 0.5), ...still(366, 300, 0.44)]), []);
});
test("a fast back-and-forth wave gives at most two swipes", () => {
  assert.equal(run(seq(1000, (t) => hand(t, 0.5 + 0.1 * Math.sin((t / 1000) * Math.PI * 6), 0.5))).length <= 2, true);
});
test("the hand leaving the frame resets a hold", () => {
  const a = seq(120, (t) => ({ t, hand: true, g: "Victory", score: 0.9, x: 0.5, y: 0.5 }));
  const b = [333, 366, 400, 433, 466, 600].map((t) => ({ t, hand: false }));
  const c = seq(120, (t) => ({ t, hand: true, g: "Victory", score: 0.9, x: 0.5, y: 0.5 }), 633);
  assert.deepEqual(run([...a, ...b, ...c]), []);
});
test("each stroke is reported with its reason (for the panel)", () => {
  const o = outs([...still(0, 200, 0.6), ...stroke(200, 330, 0.6, 0.5, 0.54, 0.5), ...still(530, 300, 0.54)]).filter((x) => x.stroke).map((x) => x.stroke);
  assert.equal(o.length, 1); assert.ok(o[0].why.includes("速度不够"), o[0].why); assert.equal(o[0].dir, "←");
});
test("motion reports progress towards a swipe", () => {
  const o = outs([...still(0, 200, 0.6), ...stroke(200, 200, 0.6, 0.5, 0.57, 0.5)]);
  const m = Math.max(...o.map((x) => x.motion));
  assert.equal(m > 0.15 && m < 1, true, `motion ${m}`);
});

// ---- replay of the owner's 16 measured attempts (2026-10-24), each rebuilt as one stroke from its
// summary (direction, travel, slant, hand size, peak speed). Expected = the rule table agreed with the owner.
const recorded = [
  ["←", 0.64, 1.5, 0.189, 8, true], ["←", 0.47, 7.3, 0.179, 4.9, true], ["↓", 0.14, 1.1, 0.166, 4.6, false], ["↓", 0.46, 1.4, 0.212, 4.6, true],
  ["↑", 0.83, 1.6, 0.208, 4.3, true], ["↓", 0.98, 2.2, 0.203, 5.2, true], ["↑", 0.83, 1.7, 0.2, 5.4, true], ["↓", 0.74, 1.4, 0.207, 3.8, true],
  ["→", 0.11, 3.6, 0.205, 4.5, false], ["↑", 0.54, 1.4, 0.206, 3.5, true], ["↑", 0.06, 2.4, 0.19, 1.6, false], ["←", 0.06, 5.3, 0.198, 1.7, false],
  ["←", 0.3, 20.1, 0.265, 1.9, false], ["→", 0.18, 6.6, 0.253, 2.2, false], ["←", 0.15, 2.2, 0.273, 2.9, false], ["↑", 0.7, 1.0, 0.263, 8.2, false],
];
test("replay of your 16 attempts: 8 fire, each in its own direction, none of the small ones", () => {
  const NAME = { "←": "swipeLeft", "→": "swipeRight", "↑": "swipeUp", "↓": "swipeDown" };
  let fired = 0;
  for (const [dir, travel, ratio, s, peak, expect] of recorded) {
    const d = travel * s, cross = d / ratio, horiz = dir === "←" || dir === "→", sign = dir === "←" || dir === "↑" ? -1 : 1;
    const ms = Math.max(66, (1.5 * travel / peak) * 1000); // smooth profile: peak = 1.5 x average speed
    const dx = horiz ? sign * d : cross, dy = horiz ? cross : sign * d;
    const got = run([...still(0, 200, 0.5, 0.5, s), ...stroke(200, ms, 0.5, 0.5, 0.5 + dx, 0.5 + dy, s), ...still(200 + ms, 400, 0.5 + dx, 0.5 + dy, s)]);
    assert.deepEqual(got, expect ? [NAME[dir]] : [], `${dir} travel ${travel} ratio ${ratio} peak ${peak}`);
    if (expect) fired++;
  }
  assert.equal(fired, 8);
});

// ---- round 2 (owner's second measurement, 2026-10-24)
test("a very fast flick with one noisy backward frame is not split in two (fires once)", () => {
  const f = [...still(0, 200, 0.6), hand(233, 0.585, 0.5), hand(266, 0.56, 0.5), hand(299, 0.563, 0.5), hand(332, 0.53, 0.5), hand(365, 0.52, 0.5), ...still(398, 300, 0.52)];
  assert.deepEqual(run(f), ["swipeLeft"]);
});
test("browsing: down, slow return, down again 0.55 s later: two downs (shorter cooldown)", () => {
  const f = [...still(0, 200, 0.5, 0.45), ...stroke(200, 200, 0.5, 0.45, 0.5, 0.52), ...stroke(400, 450, 0.5, 0.52, 0.5, 0.45),
    ...stroke(850, 200, 0.5, 0.45, 0.5, 0.52), ...still(1050, 300, 0.5, 0.52)];
  assert.deepEqual(run(f), ["swipeDown", "swipeDown"]);
});
const recorded2 = [ // dir, travel, slant, hand size, peak, expected to fire as a single stroke (rule table v4)
  ["←", 0.99, 1.2, 0.184, 7.7, true], ["←", 0.11, 4.7, 0.195, 1.5, false], ["↑", 0.35, 2.4, 0.187, 3.7, true], ["↓", 0.33, 7.7, 0.158, 4.2, false],
  ["←", 0.28, 33.3, 0.177, 3.4, false], ["→", 0.39, 2.6, 0.178, 13, true], ["←", 0.39, 4.9, 0.166, 9.2, true], ["↓", 0.25, 2.3, 0.176, 4.6, false],
  ["↑", 0.17, 28.2, 0.194, 2.2, false], ["↓", 0.66, 4, 0.18, 5.9, true], ["↑", 0.34, 1.4, 0.197, 2.9, false], ["←", 0.1, 5.4, 0.22, 2.6, false],
  ["↓", 0.74, 3, 0.196, 7, true], ["↑", 0.39, 2.9, 0.207, 2, false], ["↓", 0.48, 3.3, 0.201, 4.3, true], ["↑", 0.48, 4.4, 0.203, 2.1, false],
  ["↓", 0.54, 5.3, 0.199, 5.3, true], ["↑", 0.43, 2, 0.202, 3.2, true], ["↓", 0.43, 4.9, 0.2, 3.8, true], ["↑", 0.57, 1.6, 0.205, 2.1, false],
];
test("replay of your second 20 strokes: 10 fire on their own (the slow up-returns never do)", () => {
  const NAME = { "←": "swipeLeft", "→": "swipeRight", "↑": "swipeUp", "↓": "swipeDown" };
  let fired = 0;
  for (const [dir, travel, ratio, s, peak, expect] of recorded2) {
    const d = travel * s, cross = d / ratio, horiz = dir === "←" || dir === "→", sign = dir === "←" || dir === "↑" ? -1 : 1;
    const ms = Math.max(66, (1.5 * travel / peak) * 1000);
    const dx = horiz ? sign * d : cross, dy = horiz ? cross : sign * d;
    const got = run([...still(0, 200, 0.5, 0.5, s), ...stroke(200, ms, 0.5, 0.5, 0.5 + dx, 0.5 + dy, s), ...still(200 + ms, 400, 0.5 + dx, 0.5 + dy, s)]);
    assert.deepEqual(got, expect ? [NAME[dir]] : [], `${dir} travel ${travel} ratio ${ratio} peak ${peak}`);
    if (expect) fired++;
  }
  assert.equal(fired, 10);
});
console.log(`${pass} passed`);
