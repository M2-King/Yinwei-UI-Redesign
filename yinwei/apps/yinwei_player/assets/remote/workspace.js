"use strict";
window.YinweiRemoteHost = true;
window.YinweiRemoteTransport = (payload) => {
  window.parent.postMessage(
    { yinweiRemote: "intent", payload },
    location.origin,
  );
};
window.addEventListener("message", (event) => {
  if (
    event.origin !== location.origin ||
    event.source !== window.parent ||
    !event.data?.yinweiRemote
  )
    return;
  const api = window.YinweiWorkspace;
  if (!api) return;
  if (event.data.yinweiRemote === "snapshot") {
    api.setHostSuspended(false);
    const state = event.data.snapshot;
    api.applySceneSnapshot({
      type: "sceneSnapshot",
      schemaVersion: 1,
      revision: state.sceneRevision,
      scene: state.scene,
    });
    api.applyPlaybackTelemetry(state.telemetry);
  }
  if (event.data.yinweiRemote === "suspended") api.setHostSuspended(true);
});
