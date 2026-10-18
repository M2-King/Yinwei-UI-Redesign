export function decodeAudioPacket(buffer) {
  if (
    !(buffer instanceof ArrayBuffer) ||
    buffer.byteLength < 64 ||
    buffer.byteLength > 4152
  )
    throw new Error("invalid_audio_packet");
  const data = new DataView(buffer);
  const rate = data.getUint32(32, true),
    frames = data.getUint32(36, true);
  if (
    data.getUint32(0, true) !== 0x31574e59 ||
    data.getUint32(4, true) !== 1 ||
    rate < 8000 ||
    rate > 192000 ||
    frames < 1 ||
    frames > 512 ||
    buffer.byteLength !== 56 + frames * 8
  )
    throw new Error("invalid_audio_packet");
  const numeric = (offset) => {
    const value = data.getBigUint64(offset, true);
    if (value > BigInt(Number.MAX_SAFE_INTEGER))
      throw new Error("invalid_audio_counter");
    return Number(value);
  };
  const firstFrame = numeric(24),
    mode = data.getUint32(40, true);
  const azimuth = data.getFloat32(48, true),
    elevation = data.getFloat32(52, true);
  if (
    !Number.isSafeInteger(firstFrame + frames) ||
    mode > 2 ||
    !Number.isFinite(azimuth) ||
    !Number.isFinite(elevation)
  )
    throw new Error("invalid_audio_metadata");
  return {
    epoch: numeric(8),
    sequence: numeric(16),
    firstFrame,
    sampleRate: rate,
    frames,
    mode,
    dropped: data.getUint32(44, true),
    azimuth,
    elevation,
    buffer: buffer.slice(56),
  };
}

export class BrowserAudio {
  constructor({ request, status, pose }) {
    this.request = request;
    this.status = status;
    this.pose = pose;
    this.context = null;
    this.socket = null;
    this.node = null;
    this.pending = new Set();
    this.epoch = null;
    this.nextFrame = null;
    this.lastSequence = 0;
    this.generation = 0;
    this.minimumEpoch = 0;
    this.volume = 1;
    this.paused = true;
  }
  get active() {
    return this.context != null;
  }
  // Create and resume the AudioContext inside a tap, so a later start()
  // (after a slow laptop command) is still allowed to play in Safari.
  prepare() {
    if (this.active || this.prepared ||
        typeof globalThis.AudioContext !== 'function') return;
    this.prepared = new AudioContext();
    this.prepared.resume().catch(() => {});
  }

  async start({ source = 'file' } = {}) {
    if (this.active) return;
    if (typeof globalThis.AudioContext !== 'function' ||
        typeof globalThis.AudioWorkletNode !== 'function') {
      this.status('This browser cannot play the live stereo stream. Open Yinwei in an up-to-date Safari or Chrome browser.');
      return;
    }
    const generation = ++this.generation;
    try {
      const context = this.prepared ?? new AudioContext();
      this.prepared = null;
      this.context = context;
      this.status('Starting browser audio…');
      // Resume directly inside the user gesture, before asynchronous setup.
      await context.resume();
      if (generation !== this.generation) return;
      await context.audioWorklet.addModule("/remote/audio-worklet.js");
      if (generation !== this.generation) return;
      this.node = new AudioWorkletNode(context, "yinwei-pcm-sink", {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [2],
      });
      this.gain = context.createGain();
      this.gain.gain.value = this.volume;
      this.node.connect(this.gain).connect(context.destination);
      this.node.port.onmessage = ({ data }) => {
        if (generation !== this.generation) return;
        if (data.type === "accepted") {
          this.pending.delete(data.sequence);
          if (this.socket?.readyState === WebSocket.OPEN)
            this.socket.send(JSON.stringify({ ack: data.sequence }));
        } else if (data.type === "presentation") {
          if (this.paused || data.epoch !== this.epoch || data.epoch < this.minimumEpoch) return;
          this.pose(data);
          this.status(this.volume === 0
            ? 'Browser volume is muted · raise Browser volume to listen'
            : data.signalPresent === false
              ? 'Receiving silence from laptop · check source playback and laptop processing'
              : data.mode === 2
            ? 'DSP error · rendering original audio'
            : 'Playing laptop stereo · output follows this device’s sound settings');
        } else if (data.type === "underrun" || data.type === "resync") {
          this.status(source === 'live'
            ? "Buffering live audio · waiting for the Windows source"
            : "Browser audio buffering · connection interrupted");
        }
      };
      const { ticket } = await this.request("ws-ticket", { purpose: "audio" });
      if (generation !== this.generation) return;
      const socket = new WebSocket(
        `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/remote/ws/audio`,
      );
      this.socket = socket;
      socket.binaryType = "arraybuffer";
      socket.onopen = () => socket.send(JSON.stringify({ ticket }));
      socket.onmessage = ({ data }) => {
        if (generation !== this.generation) return;
        if (typeof data === "string") {
          this.status(source === 'live'
            ? "Live stream ready · waiting for Windows source audio"
            : "Browser audio ready · start laptop playback");
          return;
        }
        try {
          const packet = decodeAudioPacket(data);
          if (
            this.paused ||
            packet.sequence <= this.lastSequence ||
            packet.epoch < this.minimumEpoch
          ) {
            socket.send(JSON.stringify({ ack: packet.sequence }));
            return;
          }
          if (this.pending.size >= 24 || context.state !== "running")
            throw new Error("browser_audio_stalled");
          if (
            packet.epoch !== this.epoch ||
            packet.firstFrame !== this.nextFrame
          ) {
            this.node.port.postMessage({ type: "flush" });
            this.status('Buffering laptop stereo…');
          }
          this.epoch = packet.epoch;
          this.lastSequence = packet.sequence;
          this.nextFrame = packet.firstFrame + packet.frames;
          this.pending.add(packet.sequence);
          this.node.port.postMessage({ ...packet, type: "pcm" }, [
            packet.buffer,
          ]);
        } catch (_) {
          this.stop("Browser audio interrupted. Press Listen to restart.");
        }
      };
      socket.onclose = (event) => {
        if (generation === this.generation)
          this.stop(event.reason === 'live_stopped'
            ? "Live Transfer stopped on laptop · start it there, then press Listen"
            : event.reason === 'audio_source_changed'
              ? "Audio source changed · press Listen again"
              : event.reason === 'socket_limit'
                ? 'Browser audio is busy · stop listening on the other device, then press Listen'
              : "Browser audio stopped · press Listen to reconnect");
      };
      socket.onerror = () => {
        if (generation === this.generation)
          this.status("Browser audio connection unavailable");
      };
      context.onstatechange = () => {
        if (generation === this.generation && context.state !== "running")
          this.stop("Browser audio suspended · press Listen to resume");
      };
    } catch (error) {
      if (generation === this.generation) {
        await this.stop(
          error.message === 'audio_busy'
            ? 'Browser audio is busy · stop listening on the other device, then press Listen'
            : "Browser audio unavailable. Check the native engine and connection.",
        );
      }
    }
  }
  flush(discontinuity = false, previousEpoch = this.epoch) {
    this.node?.port.postMessage({ type: "flush" });
    this.pose(null);
    if (discontinuity && previousEpoch != null)
      this.minimumEpoch = Math.max(this.minimumEpoch, previousEpoch + 1);
    if (this.active) this.status('Buffering laptop stereo…');
  }
  updateTransport(transport, durationMs, { live = false } = {}) {
    const paused = !live && !transport.playing && transport.positionMs < durationMs;
    if (paused && !this.paused) {
      this.flush();
      if (this.active) this.status('Laptop playback paused · browser audio waiting');
    }
    this.paused = paused;
  }
  setVolume(value) {
    this.volume = Math.max(0, Math.min(1, value));
    if (this.gain) this.gain.gain.value = this.volume;
  }
  async stop(text = "Browser audio stopped · laptop playback unchanged") {
    ++this.generation;
    const context = this.context;
    this.context = null;
    if (this.socket) {
      this.socket.onclose = null;
      this.socket.onmessage = null;
      this.socket.onerror = null;
      this.socket.onopen = null;
      this.socket.close();
      this.socket = null;
    }
    if (this.node) {
      this.node.port.onmessage = null;
      this.node.disconnect();
    }
    this.gain?.disconnect();
    this.gain = null;
    this.node = null;
    this.pending.clear();
    this.epoch = null;
    this.nextFrame = null;
    this.lastSequence = 0;
    this.minimumEpoch = 0;
    this.pose(null);
    this.status(text);
    if (context) {
      context.onstatechange = null;
      if (context.state !== "closed") await context.close();
    }
  }
}
