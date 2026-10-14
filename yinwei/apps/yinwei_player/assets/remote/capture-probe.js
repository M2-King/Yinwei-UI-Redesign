import { buildProbeReport, classifyRecapture } from "/remote/capture-probe-core.js";

const byId = (id) => document.getElementById(id);
const elements = {
  start: byId("start-probe"),
  tone: byId("tone-test"),
  stop: byId("stop-probe"),
  status: byId("probe-status"),
  save: byId("save-state"),
  api: byId("api-value"),
  audio: byId("audio-value"),
  level: byId("level-value"),
  gap: byId("gap-value"),
  feedback: byId("feedback-value"),
  visibility: byId("visibility-value"),
  technical: byId("technical-result"),
};

const state = {
  csrf: "",
  stream: null,
  context: null,
  meter: null,
  latest: null,
  history: [],
  stage: "capability",
  recaptureHint: "not_tested",
  dryRouting: "not_tested",
  runningTone: false,
};

const supported = Boolean(
  window.isSecureContext && navigator.mediaDevices?.getDisplayMedia,
);
const standalone =
  window.matchMedia?.("(display-mode: standalone)").matches === true ||
  navigator.standalone === true;

function errorCode(error) {
  if (!error) return "unknown";
  if (error.name === "NotAllowedError") return "not_allowed";
  if (error.name === "NotReadableError") return "not_readable";
  if (error.name === "AbortError") return "abort";
  return "unknown";
}

function report(extra = {}) {
  return buildProbeReport({
    stage: state.stage,
    supported,
    secureContext: window.isSecureContext,
    standalone,
    visibility: document.visibilityState,
    recaptureHint: state.recaptureHint,
    dryRouting: state.dryRouting,
    ...trackFacts(),
    ...state.latest,
    ...extra,
  });
}

function render(extra = {}) {
  const value = report(extra);
  elements.api.textContent = supported ? "Available" : "Unavailable";
  elements.audio.textContent = value.audioTrack
    ? value.audioState === "muted"
      ? "Present, muted"
      : "Present"
    : state.stream
      ? "Missing"
      : "Not tested";
  elements.level.textContent = Number.isFinite(value.rmsDb)
    ? `${value.rmsDb.toFixed(1)} dBFS`
    : "—";
  elements.gap.textContent = Number.isFinite(value.maxGapMs)
    ? `${value.maxGapMs.toFixed(0)} ms`
    : "—";
  elements.feedback.textContent = {
    not_tested: "Not tested",
    clear: "No coded-tone match",
    possible: "Possible feedback",
    inconclusive: "Inconclusive",
  }[state.recaptureHint];
  elements.visibility.textContent = document.visibilityState;
  elements.technical.textContent = JSON.stringify(value, null, 2);
}

async function send(extra = {}) {
  if (!state.csrf) return;
  const value = report(extra);
  elements.save.textContent = "Saving numeric result…";
  try {
    const response = await fetch("/remote/api/capture-probe", {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": state.csrf,
      },
      body: JSON.stringify(value),
    });
    if (!response.ok) throw new Error("save_failed");
    elements.save.textContent = "Numeric result saved to laptop";
  } catch (_) {
    elements.save.textContent = "Result stays on this iPad";
  }
}

function trackFacts() {
  const audio = state.stream?.getAudioTracks()[0];
  const settings = audio?.getSettings?.() || {};
  return {
    audioTrack: Boolean(audio),
    videoTrack: Boolean(state.stream?.getVideoTracks().length),
    audioState: !audio
      ? "missing"
      : audio.readyState === "ended"
        ? "ended"
        : audio.muted
          ? "muted"
          : "live",
    sampleRate: Number.isInteger(settings.sampleRate)
      ? settings.sampleRate
      : state.context?.sampleRate || 0,
    channelCount: Number.isInteger(settings.channelCount)
      ? settings.channelCount
      : 0,
  };
}

async function stopProbe(reason = "Stopped. No media was saved.") {
  state.stream?.getTracks().forEach((track) => track.stop());
  state.stream = null;
  state.meter?.disconnect();
  state.meter = null;
  if (state.context && state.context.state !== "closed") await state.context.close();
  state.context = null;
  state.stage = "stopped";
  elements.start.disabled = false;
  elements.tone.disabled = true;
  elements.stop.disabled = true;
  elements.status.textContent = reason;
  render({ audioState: "ended" });
  await send({ audioState: "ended" });
}

async function startProbe() {
  if (!supported) {
    state.stage = "error";
    elements.status.textContent =
      "This iPad browser does not expose screen-share capture to the web page.";
    render({ errorCode: "unsupported", audioState: "missing" });
    await send({ errorCode: "unsupported", audioState: "missing" });
    return;
  }
  state.stage = "requesting";
  elements.start.disabled = true;
  elements.status.textContent = "Choose the app or screen whose audio is playing.";
  render();
  await send();
  try {
    const stream = await navigator.mediaDevices.getDisplayMedia({
      video: true,
      audio: true,
    });
    state.stream = stream;
    const audio = stream.getAudioTracks()[0];
    const video = stream.getVideoTracks()[0];
    for (const track of stream.getTracks()) {
      track.addEventListener("ended", () => {
        if (state.stream) void stopProbe("iPad stopped screen sharing.");
      });
      track.addEventListener("mute", () => {
        state.latest = { ...state.latest, ...trackFacts() };
        render();
        void send();
      });
      track.addEventListener("unmute", () => {
        state.latest = { ...state.latest, ...trackFacts() };
        render();
        void send();
      });
    }
    state.stage = "active";
    state.latest = trackFacts();
    elements.stop.disabled = false;
    if (!audio) {
      elements.status.textContent =
        "The picker returned a screen, but no audio track. This route cannot carry live app audio on this setup.";
      render({ errorCode: "no_audio_track" });
      await send({ errorCode: "no_audio_track" });
      return;
    }
    // Keep the required video track alive for the platform share session, but
    // never attach, inspect, encode, save, or transmit its frames.
    // The platform may require the video track to keep the share session
    // alive. Yinwei leaves it untouched and never creates a video consumer.
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    state.context = new AudioContextClass({ latencyHint: "interactive" });
    await state.context.audioWorklet.addModule("/remote/capture-meter-worklet.js");
    await state.context.resume();
    const source = state.context.createMediaStreamSource(new MediaStream([audio]));
    state.meter = new AudioWorkletNode(state.context, "yinwei-capture-meter");
    const mute = state.context.createGain();
    mute.gain.value = 0;
    source.connect(state.meter).connect(mute).connect(state.context.destination);
    state.meter.port.onmessage = ({ data }) => {
      state.latest = { ...trackFacts(), ...data };
      state.history.push({ ...data });
      if (state.history.length > 12) state.history.shift();
      render();
    };
    elements.tone.disabled = false;
    elements.status.textContent =
      "Audio track found. Keep the source playing and watch the level move.";
    render({ errorCode: "none" });
    await send({ errorCode: "none" });
  } catch (error) {
    const failedAfterCapture = Boolean(state.stream);
    state.stream?.getTracks().forEach((track) => track.stop());
    state.stream = null;
    if (state.context && state.context.state !== "closed") {
      await state.context.close().catch(() => {});
    }
    state.context = null;
    state.meter = null;
    state.stage = "error";
    elements.start.disabled = false;
    elements.status.textContent =
      error?.name === "NotAllowedError"
        ? "Screen sharing was cancelled or denied."
        : "iPad could not start the capture test.";
    const code = failedAfterCapture ? "audio_context" : errorCode(error);
    render({ errorCode: code, audioState: "missing" });
    await send({ errorCode: code, audioState: "missing" });
  }
}

const wait = (milliseconds) =>
  new Promise((resolve) => window.setTimeout(resolve, milliseconds));

async function toneWindow(frequency) {
  const context = state.context;
  const before = state.history.length;
  const oscillator = context.createOscillator();
  const gain = context.createGain();
  oscillator.frequency.value = frequency;
  gain.gain.value = 0.035;
  oscillator.connect(gain).connect(context.destination);
  oscillator.start();
  await wait(1200);
  oscillator.stop();
  await wait(250);
  const samples = state.history.slice(before);
  if (!samples.length) return null;
  return samples.reduce(
    (best, sample) =>
      !best ||
      sample[`tone${frequency}Db`] > best[`tone${frequency}Db`]
        ? sample
        : best,
    null,
  );
}

async function runToneTest() {
  if (!state.context || state.runningTone) return;
  state.runningTone = true;
  state.stage = "tone";
  elements.tone.disabled = true;
  elements.status.textContent = "Measuring baseline, then playing two quiet tones…";
  await state.context.resume();
  await wait(700);
  const baseline = state.history.at(-1) || null;
  const toneA = await toneWindow(997);
  const toneB = await toneWindow(1499);
  state.recaptureHint = classifyRecapture(baseline, toneA, toneB);
  state.stage = "active";
  state.runningTone = false;
  elements.tone.disabled = false;
  elements.status.textContent =
    state.recaptureHint === "possible"
      ? "The coded tones may be re-entering capture. Use the hearing choice below."
      : state.recaptureHint === "clear"
        ? "No coded-tone recapture was detected. Choose what you heard below."
        : "The feedback result was inconclusive. Choose what you heard below.";
  render();
  await send();
}

document.addEventListener("visibilitychange", () => {
  render();
  void send();
});

byId("routing-choice").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-routing]");
  if (!button) return;
  state.dryRouting = button.dataset.routing;
  for (const item of byId("routing-choice").querySelectorAll("button")) {
    item.setAttribute("aria-pressed", String(item === button));
  }
  render();
  void send();
});

elements.start.addEventListener("click", () => void startProbe());
elements.tone.addEventListener("click", () => void runToneTest());
elements.stop.addEventListener("click", () => void stopProbe());

try {
  const session = await fetch("/remote/api/session", {
    credentials: "same-origin",
  }).then((response) => {
    if (!response.ok) throw new Error("session_unavailable");
    return response.json();
  });
  state.csrf = session.csrf;
  elements.save.textContent = "Numeric result will save to laptop";
} catch (_) {
  elements.save.textContent = "Sign in again to save the result";
}

render({
  errorCode: supported ? "none" : "unsupported",
  audioState: "missing",
});
void send({
  errorCode: supported ? "none" : "unsupported",
  audioState: "missing",
});
