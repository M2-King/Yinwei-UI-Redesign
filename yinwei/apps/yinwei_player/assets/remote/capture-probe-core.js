const allowedStages = new Set([
  "capability",
  "requesting",
  "active",
  "tone",
  "stopped",
  "error",
]);

const round = (value, places = 2) => {
  if (!Number.isFinite(value)) return undefined;
  const scale = 10 ** places;
  return Math.round(value * scale) / scale;
};

const boundedInteger = (value, max = 1_000_000_000) =>
  Number.isInteger(value) && value >= 0 && value <= max ? value : undefined;

export function classifyRecapture(baseline, toneA, toneB) {
  if (!baseline || !toneA || !toneB) return "inconclusive";
  const values = [
    baseline.tone997Db,
    baseline.tone1499Db,
    toneA.tone997Db,
    toneA.tone1499Db,
    toneB.tone997Db,
    toneB.tone1499Db,
  ];
  if (!values.every(Number.isFinite)) return "inconclusive";
  const aRise = toneA.tone997Db - baseline.tone997Db;
  const bRise = toneB.tone1499Db - baseline.tone1499Db;
  const aSelectivity = toneA.tone997Db - toneA.tone1499Db;
  const bSelectivity = toneB.tone1499Db - toneB.tone997Db;
  if (aRise >= 10 && bRise >= 10 && aSelectivity >= 5 && bSelectivity >= 5) {
    return "possible";
  }
  if (aRise <= 4 && bRise <= 4) return "clear";
  return "inconclusive";
}

export function buildProbeReport(source = {}) {
  const report = { version: 1 };
  report.stage = allowedStages.has(source.stage) ? source.stage : "capability";
  for (const key of [
    "supported",
    "secureContext",
    "standalone",
    "audioTrack",
    "videoTrack",
  ]) {
    if (typeof source[key] === "boolean") report[key] = source[key];
  }
  const enums = {
    visibility: ["visible", "hidden", "prerender"],
    audioState: ["missing", "live", "muted", "ended"],
    recaptureHint: ["not_tested", "clear", "possible", "inconclusive"],
    dryRouting: [
      "not_tested",
      "source_only",
      "source_plus_return",
      "return_only",
      "silent",
      "unsure",
    ],
    errorCode: [
      "none",
      "unsupported",
      "not_allowed",
      "not_readable",
      "abort",
      "audio_context",
      "no_audio_track",
      "unknown",
    ],
  };
  for (const [key, values] of Object.entries(enums)) {
    if (values.includes(source[key])) report[key] = source[key];
  }
  for (const [key, max] of [
    ["sampleRate", 384_000],
    ["channelCount", 32],
    ["callbacks", 1_000_000_000],
    ["frames", 1_000_000_000],
    ["silentCallbacks", 1_000_000_000],
    ["discontinuities", 1_000_000_000],
  ]) {
    const value = boundedInteger(source[key], max);
    if (value !== undefined) report[key] = value;
  }
  for (const key of [
    "rmsDb",
    "peakDb",
    "maxGapMs",
    "tone997Db",
    "tone1499Db",
  ]) {
    const value = round(source[key]);
    if (value !== undefined) report[key] = value;
  }
  return report;
}
