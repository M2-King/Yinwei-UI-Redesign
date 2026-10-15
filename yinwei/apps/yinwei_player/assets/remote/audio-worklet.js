// Playback sink only. HRTF/EQ/DSP already ran on the laptop.
class YinweiPcmSink extends AudioWorkletProcessor {
  constructor() {
    super();
    this.capacity = 48000;
    this.pcm = new Float32Array(this.capacity * 2);
    this.readFrame = 0;
    this.count = 0;
    this.phase = 0;
    this.inputRate = sampleRate;
    this.ready = false;
    this.underruns = 0;
    this.presentationFrame = 0;
    this.metadata = [];
    this.ticks = 0;
    this.signalPresent = false;
    this.silentFrames = 0;
    this.port.onmessage = ({ data }) => {
      if (data.type === "flush") {
        this.signalPresent = false;
        this.silentFrames = 0;
        this.count = 0;
        this.phase = 0;
        this.ready = false;
        this.metadata = [];
        return;
      }
      if (data.type !== "pcm") return;
      const input = new Float32Array(data.buffer);
      const frames = input.length / 2;
      if (
        frames < 1 ||
        frames > 512 ||
        data.sampleRate < 8000 ||
        data.sampleRate > 192000
      )
        return;
      if (this.inputRate !== data.sampleRate) {
        this.signalPresent = false;
        this.silentFrames = 0;
        this.count = 0;
        this.phase = 0;
        this.ready = false;
        this.metadata = [];
      }
      this.inputRate = data.sampleRate;
      // Half-second hard ceiling. Resync to current audio instead of growing
      // latency/memory if the browser stalls; surface the discontinuity.
      const maximum = Math.min(
        this.capacity - 2,
        Math.floor(this.inputRate * 0.5),
      );
      if (this.count + frames > maximum) {
        this.signalPresent = false;
        this.silentFrames = 0;
        this.count = 0;
        this.phase = 0;
        this.ready = false;
        this.metadata = [];
        this.port.postMessage({ type: "resync" });
      }
      if (this.count === 0) this.presentationFrame = data.firstFrame;
      this.metadata.push({
        ...data,
        buffer: null,
        end: data.firstFrame + frames,
      });
      if (this.metadata.length > 128) this.metadata.shift();
      for (let i = 0; i < frames; ++i) {
        const at = ((this.readFrame + this.count + i) % this.capacity) * 2;
        this.pcm[at] = Number.isFinite(input[i * 2]) ? input[i * 2] : 0;
        this.pcm[at + 1] = Number.isFinite(input[i * 2 + 1])
          ? input[i * 2 + 1]
          : 0;
      }
      this.count += frames;
      this.port.postMessage({ type: "accepted", sequence: data.sequence });
    };
  }
  process(inputs, outputs) {
    const out = outputs[0];
    if (!out?.[0]) return true;
    if (!this.ready && this.count >= this.inputRate * 0.08) this.ready = true;
    const step = this.inputRate / sampleRate;
    for (let i = 0; i < out[0].length; ++i) {
      if (!this.ready || this.count < Math.ceil(step) + 1) {
        out[0][i] = 0;
        if (out[1]) out[1][i] = 0;
        if (this.ready) {
          this.ready = false;
          this.signalPresent = false;
          ++this.underruns;
          this.port.postMessage({ type: "underrun", count: this.underruns });
        }
        continue;
      }
      const a = this.readFrame * 2,
        b = ((this.readFrame + 1) % this.capacity) * 2;
      out[0][i] = this.pcm[a] + (this.pcm[b] - this.pcm[a]) * this.phase;
      if (out[1])
        out[1][i] =
          this.pcm[a + 1] + (this.pcm[b + 1] - this.pcm[a + 1]) * this.phase;
      // Transport/rendering can be healthy while every sample is silent.
      // Inspect the rendered stereo only; never alter the received samples.
      if (Math.max(Math.abs(out[0][i]), Math.abs(out[1]?.[i] ?? 0)) >= 0.00001) {
        this.signalPresent = true;
        this.silentFrames = 0;
      } else if (++this.silentFrames >= sampleRate) {
        this.signalPresent = false;
      }
      this.phase += step;
      const advance = Math.floor(this.phase);
      this.phase -= advance;
      this.readFrame = (this.readFrame + advance) % this.capacity;
      this.count -= advance;
      this.presentationFrame += advance;
    }
    if (++this.ticks % 12 === 0 && this.ready) {
      while (
        this.metadata.length > 1 &&
        this.metadata[0].end <= this.presentationFrame
      )
        this.metadata.shift();
      const pose = this.metadata[0];
      if (pose)
        this.port.postMessage({
          type: "presentation",
          epoch: pose.epoch,
          mode: pose.mode,
          signalPresent: this.signalPresent,
          azimuth: pose.azimuth,
          elevation: pose.elevation,
          positionMs: (this.presentationFrame * 1000) / this.inputRate,
        });
    }
    return true;
  }
}
registerProcessor("yinwei-pcm-sink", YinweiPcmSink);
