class YinweiCaptureMeter extends AudioWorkletProcessor {
  constructor() {
    super();
    this.callbacks = 0;
    this.frames = 0;
    this.silentCallbacks = 0;
    this.discontinuities = 0;
    this.maxGapMs = 0;
    this.sumSquares = 0;
    this.peak = 0;
    this.i997 = 0;
    this.q997 = 0;
    this.i1499 = 0;
    this.q1499 = 0;
    this.windowFrames = 0;
    this.lastFrame = null;
  }

  process(inputs) {
    const channels = inputs[0] || [];
    const frames = channels[0]?.length || 128;
    if (this.lastFrame !== null) {
      const expected = this.lastFrame + frames;
      const gapFrames = Math.max(0, currentFrame - expected);
      if (gapFrames > sampleRate * 0.05) this.discontinuities += 1;
      this.maxGapMs = Math.max(this.maxGapMs, (gapFrames * 1000) / sampleRate);
    }
    this.lastFrame = currentFrame;
    this.callbacks += 1;
    this.frames += frames;
    let callbackPeak = 0;
    for (let i = 0; i < frames; i += 1) {
      let sample = 0;
      for (const channel of channels) sample += channel[i] || 0;
      if (channels.length) sample /= channels.length;
      const absolute = Math.abs(sample);
      callbackPeak = Math.max(callbackPeak, absolute);
      this.peak = Math.max(this.peak, absolute);
      this.sumSquares += sample * sample;
      const index = this.windowFrames + i;
      const phase997 = (2 * Math.PI * 997 * index) / sampleRate;
      const phase1499 = (2 * Math.PI * 1499 * index) / sampleRate;
      this.i997 += sample * Math.cos(phase997);
      this.q997 += sample * Math.sin(phase997);
      this.i1499 += sample * Math.cos(phase1499);
      this.q1499 += sample * Math.sin(phase1499);
    }
    if (callbackPeak < 0.00001) this.silentCallbacks += 1;
    this.windowFrames += frames;
    if (this.windowFrames >= sampleRate / 2) this.report();
    return true;
  }

  report() {
    const db = (value) => 20 * Math.log10(Math.max(value, 1e-9));
    const band = (i, q) => (2 * Math.hypot(i, q)) / this.windowFrames;
    this.port.postMessage({
      callbacks: this.callbacks,
      frames: this.frames,
      silentCallbacks: this.silentCallbacks,
      discontinuities: this.discontinuities,
      maxGapMs: this.maxGapMs,
      rmsDb: db(Math.sqrt(this.sumSquares / this.windowFrames)),
      peakDb: db(this.peak),
      tone997Db: db(band(this.i997, this.q997)),
      tone1499Db: db(band(this.i1499, this.q1499)),
    });
    this.sumSquares = 0;
    this.peak = 0;
    this.i997 = 0;
    this.q997 = 0;
    this.i1499 = 0;
    this.q1499 = 0;
    this.windowFrames = 0;
  }
}

registerProcessor("yinwei-capture-meter", YinweiCaptureMeter);
