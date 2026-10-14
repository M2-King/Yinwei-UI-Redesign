import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const coreSource = await readFile(
  "assets/remote/capture-probe-core.js",
  "utf8",
);
const core = await import(
  `data:text/javascript;base64,${Buffer.from(coreSource).toString("base64")}`
);

assert.equal(
  core.classifyRecapture(
    { tone997Db: -70, tone1499Db: -71 },
    { tone997Db: -42, tone1499Db: -62 },
    { tone997Db: -63, tone1499Db: -43 },
  ),
  "possible",
);
assert.equal(
  core.classifyRecapture(
    { tone997Db: -70, tone1499Db: -71 },
    { tone997Db: -68, tone1499Db: -70 },
    { tone997Db: -69, tone1499Db: -68 },
  ),
  "clear",
);
assert.equal(core.classifyRecapture(null, null, null), "inconclusive");

const report = core.buildProbeReport({
  stage: "active",
  supported: true,
  sampleRate: 48_000,
  rmsDb: -12.3456,
  rawSamples: [0.1, 0.2],
  screenFrame: "private",
  errorCode: "none",
});
assert.deepEqual(report, {
  version: 1,
  stage: "active",
  supported: true,
  errorCode: "none",
  sampleRate: 48_000,
  rmsDb: -12.35,
});
assert.equal("rawSamples" in report, false);
assert.equal("screenFrame" in report, false);

const workletSource = await readFile(
  "assets/remote/capture-meter-worklet.js",
  "utf8",
);
let Meter;
const messages = [];
const context = vm.createContext({
  sampleRate: 48_000,
  currentFrame: 0,
  Math,
  AudioWorkletProcessor: class {
    constructor() {
      this.port = { postMessage: (value) => messages.push(value) };
    }
  },
  registerProcessor(name, processor) {
    assert.equal(name, "yinwei-capture-meter");
    Meter = processor;
  },
});
vm.runInContext(workletSource, context);
const meter = new Meter();
for (let block = 0; block < 190; block += 1) {
  const channel = new Float32Array(128);
  for (let i = 0; i < channel.length; i += 1) {
    channel[i] = 0.1 * Math.sin((2 * Math.PI * 997 * (block * 128 + i)) / 48_000);
  }
  context.currentFrame = block * 128;
  assert.equal(meter.process([[channel]]), true);
}
assert.ok(messages.length >= 1);
for (const [key, value] of Object.entries(messages[0])) {
  assert.equal(typeof value, "number", `${key} must be numeric telemetry`);
  assert.equal(Number.isFinite(value), true, `${key} must be finite`);
}
assert.equal("buffer" in messages[0], false);
assert.equal("samples" in messages[0], false);

const pageSource = await readFile("assets/remote/capture-probe.js", "utf8");
assert.doesNotMatch(pageSource, /getUserMedia/);
assert.doesNotMatch(pageSource, /MediaRecorder/);
assert.match(pageSource, /getDisplayMedia/);
assert.doesNotMatch(pageSource, /createImageBitmap|drawImage|srcObject/);

console.log(
  "PASS: R0 report allowlist, feedback classifier, numeric-only meter, and no microphone/recording fallback",
);
