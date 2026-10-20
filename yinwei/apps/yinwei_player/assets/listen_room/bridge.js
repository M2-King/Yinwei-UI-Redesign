"use strict";
// The page's side of the app bridge, as pure functions (no DOM, no three.js),
// so the rules can be tested in Node (test/listen_room/bridge_test.mjs).
//
// State, app → page: YinweiListen.apply(state) with the fields in FIELDS (see
// IMPLEMENTATION_IPAD_LISTEN_ROOM.md §4), at most 10 times a second. The app is
// the only source of truth; the page draws what it receives.
//
// One exception keeps the page responsive: when you change something here
// (move the sound, pick a layout, press play), the page shows it at once and
// keeps your value until the app's state confirms it, or until HOLD_MS pass.
// Then the app's value wins again (if the laptop refused, the screen follows
// the laptop).
const ListenBridge = (() => {
  const VERSION = 1, HOLD_MS = 2500;
  const FIELDS = ["laptop", "connection", "source", "live", "playing", "listening", "control", "notice",
    "mode", "motion", "orbitHz", "az", "el", "dist", "track", "volume", "level", "stats", "opens",
    "pending", "progress", "pos", "dur", "seekable", "canClose", "updates", "quality", "stream", "opus"];
  const wrap = (a) => { a = ((a + 180) % 360 + 360) % 360 - 180; return a === -180 ? 180 : a; };
  // Values the app may send, so a bad message can't put the page in a state it can't draw.
  const ENUMS = {
    connection: ["connected", "reconnecting"], listening: ["off", "connecting", "on"], control: ["mine", "other"],
    notice: ["none", "busy", "interrupted", "lost", "taken", "noapp"], mode: ["point", "stereo2"], motion: ["fixed", "orbit"],
    quality: ["high", "max", "lossless"],
  };
  const PROGRESS = ["asking", "opening", "pressing", "starting", "audio"];
  // Song progress, in seconds.
  const SONG = { pos: [0, 86400], dur: [0, 86400] };
  const RANGES = { ...SONG, orbitHz: [0.05, 2], az: [-180, 180], el: [-90, 90], dist: [0.5, 10], volume: [0, 1], level: [0, 1] };
  function clean(k, v) {
    if (ENUMS[k]) return ENUMS[k].includes(v) ? v : undefined;
    if (RANGES[k]) { const n = Number(v); return Number.isFinite(n) ? Math.min(RANGES[k][1], Math.max(RANGES[k][0], n)) : undefined; }
    if (["live", "playing", "pending", "seekable", "canClose", "updates", "opus"].includes(k)) return typeof v === "boolean" ? v : undefined;
    // What the laptop is sending now (Opus high / max, or lossless); null before its audio starts.
    if (k === "stream") return ["high", "max", "lossless"].includes(v) ? v : null;
    // Start progress: asking (this iPad), opening / pressing / starting (the laptop), audio; null when idle.
    if (k === "progress") return PROGRESS.includes(v) ? v : null;
    if (k === "laptop" || k === "source") return typeof v === "string" ? v.slice(0, 80) : undefined;
    // The music app the laptop opens on Start when none is open; null when it can't.
    if (k === "opens") return typeof v === "string" && v ? v.slice(0, 80) : null;
    if (k === "track") return v && typeof v === "object" ? { title: String(v.title || "").slice(0, 200), artist: String(v.artist || "").slice(0, 200) } : null;
    if (k === "stats") return v && typeof v === "object" ? { received: Number(v.received) || 0, bufferMs: Number(v.bufferMs) || 0, underruns: Number(v.underruns) || 0 } : undefined;
    return undefined;
  }
  const same = (k, a, b) => (k === "az" ? Math.abs(wrap(a - b)) < 0.5 : k === "el" ? Math.abs(a - b) < 0.5
    : k === "dist" ? Math.abs(a - b) < 0.051 : k === "pos" ? Math.abs(a - b) < 2.5 : k === "orbitHz" || k === "volume" ? Math.abs(a - b) < 0.011 : a === b);
  // Keep a value the person just set. ok(appValue) says when the app has confirmed it.
  function hold(held, k, v, now, ok, ms = HOLD_MS) { held[k] = { v, until: now + ms, ok: ok || ((x) => same(k, x, v)) }; }
  // Merge one state message into the page state S. Returns the fields that changed.
  // opts.placing: the sound is being dragged, so position fields are not taken from the app.
  // opts.orbiting: the page animates the orbit between messages; small differences are eased in.
  function merge(S, next, held, now, opts = {}) {
    const changed = [];
    if (typeof next === "string") { try { next = JSON.parse(next); } catch (e) { return changed; } }
    if (!next || typeof next !== "object" || next.v !== VERSION) return changed;
    for (const k of FIELDS) {
      if (!(k in next)) continue;
      const v = clean(k, next[k]);
      if (v === undefined) continue;
      if (opts.placing && (k === "az" || k === "el" || k === "dist")) continue;
      const h = held[k];
      if (h) { if (h.ok(v) || now > h.until) delete held[k]; else continue; }
      if (k === "az" && opts.orbiting) { const d = wrap(v - S.az); if (Math.abs(d) < 20) { S.az = wrap(S.az + d * 0.3); changed.push(k); continue; } }
      const before = JSON.stringify(S[k]);
      S[k] = v;
      if (JSON.stringify(v) !== before) changed.push(k);
    }
    return changed;
  }
  // A soft per-song tint for the generated cover (the laptop sends no artwork),
  // within the night blues of the approved prototype (205–240).
  function hueOf(title) { let h = 0; for (const ch of String(title || "")) h = (h * 31 + ch.codePointAt(0)) >>> 0; return 205 + (h % 36); }
  return { VERSION, HOLD_MS, FIELDS, PROGRESS, merge, hold, same, clean, hueOf };
})();
