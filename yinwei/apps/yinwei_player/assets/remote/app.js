"use strict";
import { BrowserAudio } from "/remote/audio-client.js";
let state,
  csrf,
  lease,
  socket,
  pending = false,
  connected = false,
  sequence = 0,
  entryLink,
  connectionGeneration = 0;
const $ = (id) => document.getElementById(id);
const message = (text) => {
  $("message").textContent = text;
};
let audioPresentation;
const browserAudio = new BrowserAudio({
  request: (path, body) => request(path, body),
  status: (text) => {
    $("audio-status").textContent = text;
    $("stop-listening").disabled = !browserAudio.active;
    updateListenButton();
  },
  pose: (packet) => {
    audioPresentation = packet;
    sendScene();
  },
});
const time = (ms) =>
  `${Math.floor(ms / 60000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, "0")}`;
async function request(path, body) {
  const response = await fetch(`/remote/api/${path}`, {
    method: body === undefined ? "GET" : "POST",
    credentials: "same-origin",
    headers:
      body === undefined
        ? {}
        : { "Content-Type": "application/json", "X-CSRF-Token": csrf },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await response.json();
  if (!response.ok) {
    if (response.status === 401) location.assign("/remote/signin");
    throw new Error(data.error || "request_failed");
  }
  return data;
}
function sendScene() {
  if (state) {
    const displayState =
      browserAudio.active && audioPresentation
        ? {
            ...state,
            telemetry: {
              ...state.telemetry,
              azimuthDeg: audioPresentation.azimuth,
              elevationDeg: audioPresentation.elevation,
              playhead:
                audioPresentation.positionMs /
                Math.max(1, state.track.durationMs),
            },
          }
        : state;
    $("scene").contentWindow.postMessage(
      { yinweiRemote: "snapshot", snapshot: displayState },
      location.origin,
    );
  }
}
function render(snapshot) {
  const sourceChanged = state?.audioSource !== snapshot.audioSource;
  state = snapshot;
  const live = !!state.liveRunning;
  const liveReady = state.audioSource === 'live';
  browserAudio.updateTransport(state.transport, state.track.durationMs, { live });
  updateListenButton();
  $("stop-listening").disabled = !browserAudio.active;
  if (!connected) {
    $("audio-status").textContent = 'Laptop disconnected · browser audio stopped';
  } else if (state.audioSource === 'remote_ipad') {
    $("audio-status").textContent = 'An iPad input session is active on the laptop. End it there before listening to laptop sources.';
  } else if (live && !liveReady) {
    $("audio-status").textContent = 'Live Transfer is starting · waiting for the laptop';
  } else if (live && !state.capabilities.browserLiveAudio) {
    $("audio-status").textContent = "Live listening is unavailable in this laptop build.";
  } else if (!live && !state.capabilities.browserAudio) {
    $("audio-status").textContent =
      "Browser listening is unavailable on this laptop session.";
  } else if (!live && !state.capabilities.pointControl) {
    $("audio-status").textContent = 'File array playback is not available in the browser. Select point playback on the laptop to listen here.';
  } else if (!live && !state.track.hasFile) {
    $("audio-status").textContent = 'Open a file or start Live Transfer on the laptop, then press Listen.';
  } else if (!browserAudio.active && (sourceChanged ||
      /^(Laptop disconnected|Waiting for|Open a file|Live Transfer is starting)/.test($("audio-status").textContent))) {
    $("audio-status").textContent = 'Press Listen to hear laptop stereo through this device’s speakers or headphones.';
  }
  if (!state.controlOwned) lease = null;
  $("title").textContent = live ? state.live?.title || 'Live Transfer' : state.track.hasFile
    ? state.track.title
    : "Open a file on the laptop";
  $("artist").textContent = live ? state.live?.source || 'Windows source audio' : state.track.artist;
  $("live-hint").hidden = !live && !state.capabilities.browserLiveAudio;
  $("live-hint").textContent = !live
    ? 'For live sound, start Live Transfer on the laptop, then listen here. No imported file is needed.'
    : !liveReady
    ? 'Start Live Transfer on the laptop. Listening will become available here.'
    : state.live?.captureHealthy
      ? browserAudio.active
        ? 'Live Transfer is running on the laptop.'
        : 'Live Transfer is running on the laptop. Press Listen here.'
      : 'Live Transfer is running. Waiting for source audio on the laptop.';
  $("play").disabled = !connected || !lease || pending || !state.track.hasFile;
  // During Live Transfer only position and Original/Spatial are remote;
  // start/stop, source and file transport stay on the laptop.
  const liveControl = live && !!state.capabilities.liveControl;
  const liveMedia = live && !!state.capabilities.liveMedia;
  document.querySelectorAll("[data-control]").forEach((element) => {
    element.disabled =
      !connected ||
      !lease ||
      pending ||
      (state.liveRunning &&
        !(liveControl && element.hasAttribute("data-live-control")) &&
        !(liveMedia && element.hasAttribute("data-live-media"))) ||
      state.transport.busy;
  });
  // Previous/Next only exist for a Live source app (no file playlist).
  $("previous").hidden = !liveMedia;
  $("next").hidden = !liveMedia;
  if (liveMedia) {
    $("play").disabled ||= !!state.live?.playing;
    $("pause").disabled ||= !state.live?.playing;
  } else {
    $("play").disabled ||= !state.track.hasFile;
  }
  $("seek").disabled ||= !state.track.hasFile;
  $("seek").max = state.track.durationMs;
  if (document.activeElement !== $("seek"))
  $("seek").value = live ? 0 : state.transport.positionMs;
  $("time").textContent = live ? 'LIVE' : time(state.transport.positionMs);
  $("original").setAttribute(
    "aria-pressed",
    String(state.transport.mode === "original"),
  );
  $("spatial").setAttribute(
    "aria-pressed",
    String(state.transport.mode === "spatial"),
  );
  for (const [id, property, suffix] of [
    ["az", "azimuthDeg", "°"],
    ["el", "elevationDeg", "°"],
    ["distance", "distanceM", " m"],
  ]) {
    $(id).disabled ||= !state.capabilities.pointControl;
    if (document.activeElement !== $(id) && !pending)
      $(id).value = state.pose[property];
    $(`${id}-value`).textContent =
      `${Number($(id).value).toFixed(id === "distance" ? 1 : 0)}${suffix}`;
  }
  $("apply").disabled ||= !state.capabilities.pointControl;
  const selected = $("media").value;
  $("media").replaceChildren();
  for (const item of state.media) {
    const option = document.createElement("option");
    option.value = item.id;
    option.textContent = item.title;
    $("media").append(option);
  }
  if (state.media.some((item) => item.id === selected))
    $("media").value = selected;
  $("open").disabled ||= state.media.length === 0;
  $("ownership").textContent = live
    ? liveControl
      ? lease
        ? 'You control the music, position and mode. Live start/stop stays on the laptop.'
        : 'Take control to change the music, position and mode. Live start/stop stays on the laptop.'
      : 'Live controls are on the laptop. Listening does not require control.'
    : lease
    ? "You control this session. Local controls take priority."
    : "Viewing only. Take control to make changes.";
  $("control").disabled =
    !connected ||
    pending ||
    (state.liveRunning && !liveControl) ||
    state.transport.busy;
  sendScene();
}
function updateListenButton() {
  const available = state && state.audioSource !== 'remote_ipad' && (state.liveRunning
    ? state.audioSource === 'live' && state.capabilities.browserLiveAudio
    : state.track.hasFile && state.capabilities.browserAudio && state.capabilities.pointControl);
  $("listen").disabled = !connected || browserAudio.active || !available;
}
async function command(type, payload = {}) {
  if (!lease || !connected || pending) return;
  pending = true;
  const previousAudioEpoch = browserAudio.epoch;
  const previousMode = state.transport.mode;
  render(state);
  try {
    const result = await request("commands", {
      protocolVersion: 1,
      commandId: crypto.randomUUID(),
      hostSessionId: state.hostSessionId,
      controlLeaseId: lease,
      expectedStateVersion: state.stateVersion,
      expectedSceneRevision: state.sceneRevision,
      type,
      payload,
    });
    render(result.snapshot);
    if (
      type === "seek" ||
      type === "open" ||
      (type === "mode" && previousMode !== payload.mode)
    ) {
      browserAudio.flush(true, previousAudioEpoch);
      audioPresentation = null;
    }
    message(
      result.status === "native_applied"
        ? "Applied on the laptop."
        : "Local controls superseded this change.",
    );
  } catch (error) {
    lease = null;
    message(
      `Change not applied: ${error.message.replaceAll("_", " ")}. Take control again.`,
    );
    try {
      render((await request("session")).snapshot);
    } catch (_) {}
  } finally {
    pending = false;
    if (state) render(state);
  }
}
async function connect() {
  const generation = ++connectionGeneration;
  if (browserAudio.active) {
    await browserAudio.stop("Reconnecting · press Listen again when connected");
    if (generation !== connectionGeneration) return;
  }
  if (socket) {
    socket.onclose = null;
    socket.close();
  }
  connected = false;
  sequence = 0;
  lease = null;
  $("connection").textContent = "Connecting…";
  try {
    const session = await request("session");
    if (generation !== connectionGeneration) return;
    entryLink = session.entryLink;
    $("entry").hidden = !entryLink;
    csrf = session.csrf;
    render(session.snapshot);
    const { ticket } = await request("ws-ticket", { purpose: "events" });
    if (generation !== connectionGeneration) return;
    socket = new WebSocket(
      `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/remote/ws/events`,
    );
    socket.onopen = () => {
      if (generation === connectionGeneration)
        socket.send(JSON.stringify({ ticket }));
    };
    socket.onmessage = (event) => {
      if (generation !== connectionGeneration) return;
      const data = JSON.parse(event.data);
      if (data.type !== "snapshot" || data.sequence <= sequence) return;
      sequence = data.sequence;
      connected = true;
      $("connection").textContent = "Connected to laptop";
      render(data.snapshot);
      socket.send(JSON.stringify({ ack: data.sequence }));
    };
    socket.onclose = (event) => {
      if (generation !== connectionGeneration) return;
      console.info('Yinwei control stream closed', event.code, event.wasClean);
      connected = false;
      lease = null;
      browserAudio.stop("Connection lost · browser audio stopped");
      $("connection").textContent = "Connection lost · controls unavailable";
      if (state) render(state);
      $("scene").contentWindow.postMessage(
        { yinweiRemote: "suspended" },
        location.origin,
      );
    };
    socket.onerror = () =>
      message(
        "Could not connect to laptop. Use Reconnect when it is available.",
      );
  } catch (error) {
    if (generation !== connectionGeneration) return;
    $("connection").textContent = "Laptop unavailable";
    message(error.message.replaceAll("_", " "));
  }
}
$("control").addEventListener("click", async () => {
  try {
    lease = (await request("control/lease", {})).controlLeaseId;
    render((await request("session")).snapshot);
    message("Control acquired.");
  } catch (e) {
    message(e.message.replaceAll("_", " "));
  }
});
// During Live these drive the laptop's music app, not a Yinwei file.
const liveMediaActive = () => !!state?.liveRunning && !!state.capabilities.liveMedia;
$("play").addEventListener("click", () =>
  command(liveMediaActive() ? "media.play" : "play"));
$("pause").addEventListener("click", () =>
  command(liveMediaActive() ? "media.pause" : "pause"));
$("previous").addEventListener("click", () => command("media.previous"));
$("next").addEventListener("click", () => command("media.next"));
$("original").addEventListener("click", () =>
  command("mode", { mode: "original" }),
);
$("spatial").addEventListener("click", () =>
  command("mode", { mode: "spatial" }),
);
$("seek").addEventListener("change", () =>
  command("seek", { positionMs: Number($("seek").value) }),
);
$("open").addEventListener("click", () =>
  command("open", { mediaId: $("media").value }),
);
$("apply").addEventListener("click", () =>
  command("point.set", {
    azimuthDeg: Number($("az").value),
    elevationDeg: Number($("el").value),
    distanceM: Number($("distance").value),
  }),
);
for (const id of ["az", "el", "distance"])
  $(id).addEventListener("input", () => {
    $(`${id}-value`).textContent =
      `${Number($(id).value).toFixed(id === "distance" ? 1 : 0)}${id === "distance" ? " m" : "°"}`;
  });
$("signout").addEventListener("click", async () => {
  await browserAudio.stop();
  try {
    await request("auth/signout", {});
    location.assign("/remote/signin");
  } catch (e) {
    message(e.message);
  }
});
$("reconnect").addEventListener("click", () => {
  sequence = 0;
  connect();
});
$("entry").addEventListener("click", () => {
  if (entryLink) location.assign(entryLink);
});
$("scene").addEventListener("load", sendScene);
window.addEventListener("message", (event) => {
  if (
    event.origin !== location.origin ||
    event.source !== $("scene").contentWindow ||
    event.data?.yinweiRemote !== "intent"
  )
    return;
  if (event.data.payload.type === "ready") sendScene();
  if (event.data.payload.type === "sourcePoseCommit") {
    if (!lease || !connected || pending) {
      sendScene();
      message("Take control before moving the source.");
      return;
    }
    command("scene.commit", event.data.payload);
  }
});
setInterval(async () => {
  if (!lease || !connected || pending) return;
  try {
    lease = (await request("control/lease", {})).controlLeaseId;
  } catch (_) {
    lease = null;
    if (state) render(state);
  }
}, 10000);
connect();

$("listen").addEventListener("click", () => browserAudio.start({
  source: state?.liveRunning ? 'live' : 'file',
}));
$("stop-listening").addEventListener("click", () => browserAudio.stop());
$("browser-volume").addEventListener("input", () =>
  browserAudio.setVolume(Number($("browser-volume").value)),
);
