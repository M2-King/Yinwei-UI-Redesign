"use strict";
// Yinwei Listen Room: the opening's sound effects, synthesized with Web Audio
// (no audio files). Quiet and short, timed to the 3D opening in room.js:
//   0 s    a soft swell of air while the night is dark,
//   0.45 s a shimmer as the ceiling's cove ring lights up,
//   0.95 s a warm chord as the lamps come on,
//   ignite a crystal chime from the sound's own direction as it lights up.
// Silent when the page may not play audio yet (a browser before any tap) or
// when this iPad is already listening to the laptop.
const OpeningSound = (() => {
  let ctx = null, master = null, verb = null;

  function context() {
    if (ctx) return ctx;
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return null;
    try { ctx = new Ctx(); } catch (e) { return null; }
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -18; comp.ratio.value = 3;
    master = ctx.createGain(); master.gain.value = 0.55;
    master.connect(comp); comp.connect(ctx.destination);
    // A soft hall: decaying stereo noise as the impulse response.
    const len = Math.floor(ctx.sampleRate * 2.4), ir = ctx.createBuffer(2, len, ctx.sampleRate);
    for (let ch = 0; ch < 2; ch++) {
      const d = ir.getChannelData(ch);
      for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3.2);
    }
    verb = ctx.createConvolver(); verb.buffer = ir;
    const wet = ctx.createGain(); wet.gain.value = 0.32;
    verb.connect(wet); wet.connect(master);
    return ctx;
  }

  /** Call inside a tap: lets a browser play the next opening. */
  function unlock() {
    const c = context();
    if (c && c.state !== "running") c.resume().catch(() => {});
  }

  function noise(c, seconds) {
    const b = c.createBuffer(1, Math.floor(c.sampleRate * seconds), c.sampleRate), d = b.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    const s = c.createBufferSource(); s.buffer = b; return s;
  }
  // A sound's chain: source -> (filter) -> gain -> pan -> master (+ a reverb send).
  function voice(c, node, gain, pan, send) {
    const g = c.createGain(); g.gain.value = 0;
    const p = c.createStereoPanner ? c.createStereoPanner() : null;
    node.connect(g);
    if (p) { p.pan.value = pan; g.connect(p); p.connect(master); if (send) p.connect(verb); }
    else { g.connect(master); if (send) g.connect(verb); }
    return { g: g.gain, p: p && p.pan };
  }

  function air(c, t) {
    const n = noise(c, 3.4), f = c.createBiquadFilter();
    f.type = "lowpass"; f.Q.value = 0.6;
    f.frequency.setValueAtTime(380, t); f.frequency.exponentialRampToValueAtTime(1500, t + 2.6);
    n.connect(f);
    const v = voice(c, f, 0, 0, true);
    v.g.setValueAtTime(0, t); v.g.linearRampToValueAtTime(0.05, t + 0.9); v.g.linearRampToValueAtTime(0, t + 3.3);
    n.start(t); n.stop(t + 3.4);
  }

  function shimmer(c, t) {
    const n = noise(c, 1.3), f = c.createBiquadFilter();
    f.type = "bandpass"; f.Q.value = 7;
    f.frequency.setValueAtTime(1400, t); f.frequency.exponentialRampToValueAtTime(7200, t + 1.0);
    n.connect(f);
    const v = voice(c, f, 0, -0.6, true);
    v.g.setValueAtTime(0, t); v.g.linearRampToValueAtTime(0.05, t + 0.25); v.g.exponentialRampToValueAtTime(0.0005, t + 1.2);
    if (v.p) { v.p.setValueAtTime(-0.6, t); v.p.linearRampToValueAtTime(0.6, t + 1.1); } // round the ring
    n.start(t); n.stop(t + 1.3);
  }

  function warm(c, t) {
    [196, 293.66, 392, 587.33].forEach((hz, i) => {
      const o = c.createOscillator();
      o.type = i === 0 ? "triangle" : "sine"; o.frequency.value = hz; o.detune.value = (i - 1.5) * 4;
      const v = voice(c, o, 0, (i - 1.5) * 0.25, true), peak = [0.03, 0.022, 0.016, 0.008][i];
      v.g.setValueAtTime(0, t); v.g.linearRampToValueAtTime(peak, t + 0.55); v.g.exponentialRampToValueAtTime(0.0003, t + 2.8);
      o.start(t); o.stop(t + 2.9);
    });
  }

  // A small bell: inharmonic partials, each fading at its own rate.
  function chime(c, t, pan) {
    const f0 = 880;
    [[1, 0.07, 2.4], [2.76, 0.032, 1.3], [5.4, 0.016, 0.7], [8.93, 0.008, 0.4]].forEach(([r, peak, decay]) => {
      const o = c.createOscillator(); o.type = "sine"; o.frequency.value = f0 * r;
      const v = voice(c, o, 0, pan, true);
      v.g.setValueAtTime(0, t); v.g.linearRampToValueAtTime(peak, t + 0.004); v.g.exponentialRampToValueAtTime(0.0002, t + decay);
      o.start(t); o.stop(t + decay + 0.05);
    });
    const n = noise(c, 0.08), f = c.createBiquadFilter(); // the strike
    f.type = "highpass"; f.frequency.value = 3000; n.connect(f);
    const v = voice(c, f, 0, pan, false);
    v.g.setValueAtTime(0.02, t); v.g.exponentialRampToValueAtTime(0.0002, t + 0.07);
    n.start(t); n.stop(t + 0.08);
  }

  /** The opening's sounds. ignite: seconds to the chime; pan: -1 left .. 1 right. */
  function play({ ignite = 1.9, pan = 0, mute = false } = {}) {
    if (mute) return;
    const c = context();
    if (!c) return;
    const go = () => {
      const t = c.currentTime + 0.03;
      try { air(c, t); shimmer(c, t + 0.45); warm(c, t + 0.95); chime(c, t + ignite, Math.max(-0.9, Math.min(0.9, pan))); }
      catch (e) { /* no sound is better than a broken opening */ }
    };
    if (c.state === "running") { go(); return; }
    // Not allowed to play yet: try once; if it starts within a moment, play.
    const asked = performance.now();
    c.resume().then(() => { if (c.state === "running" && performance.now() - asked < 300) go(); }).catch(() => {});
  }

  return { unlock, play };
})();
