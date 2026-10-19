"use strict";
// ==================================================================== ROOM MATH BEGIN
// Pure functions only: no DOM, no three.js, no app state. Coordinates match
// IMPLEMENTATION_IPAD_LISTEN_ROOM.md §3. Tested in test/listen_room/room_math_test.mjs.
//
// ENGINE FRAME (what the audio engine receives, real metres)
//   X: + right · Y: + up · Z: − front (towards the window), + behind.
//   Listener: ears at the origin, facing −Z, upright (+Y). No head tracking:
//   the listener's orientation never changes.
//   Azimuth: 0° front, +90° right, −90° left, ±180° behind; kept in −180…180.
//   Elevation: 0° ear level, +90° straight up, −90° straight down.
//   Distance: 0.5–10 m from the ears.
//
// ROOM FRAME (the three.js scene, display metres)
//   Same axes and orientation as the engine frame; only two things differ:
//   1. the ears sit at (0, EAR, 0), EAR metres above the floor (y = 0);
//   2. distance is drawn on a log scale so 0.5 m and 10 m both fit the room:
//        room radius = ln(1 + d) / ln(11) × R10   (R10 = the radius of 10 m).
//   The log scale is for display only: the engine always gets real metres.
//
// Conversion: engine (az, el, d) → room toRoom(); room point → engine
// fromRoomPoint() (the drag inverse). Both are exact inverses on the
// horizontal plane through the sound (elevation is kept while dragging).
const RoomMath = (() => {
  const DEG = Math.PI / 180, EAR = 1.1, R10 = 4.4, LN11 = Math.log(11);
  const D_MIN = 0.5, D_MAX = 10;
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const wrap = (a) => { a = ((a + 180) % 360 + 360) % 360 - 180; return a === -180 ? 180 : a; };
  const rdOf = (d) => Math.log(1 + d) / LN11;   // metres → 0…1 of R10
  const dOf = (rd) => Math.exp(rd * LN11) - 1;   // inverse of rdOf
  const roomRadius = (d) => rdOf(d) * R10;       // metres → room radius
  // Engine direction and distance → room position [x, y, z].
  function toRoom(az, el, d) {
    const rw = roomRadius(d), a = az * DEG, e = el * DEG;
    return [rw * Math.cos(e) * Math.sin(a), EAR + rw * Math.sin(e), -rw * Math.cos(e) * Math.cos(a)];
  }
  // Drag inverse: the point (x, z) where the finger's ray meets the level
  // plane through the sound → { az, d } at elevation el (kept). Null when
  // the point is outside the room; azimuth in whole degrees, distance to 0.1 m.
  function fromRoomPoint(x, z, el) {
    const hr = Math.hypot(x, z);
    if (hr > R10 * 1.1) return null;
    const rd = clamp(hr / R10 / Math.max(0.2, Math.cos(el * DEG)), rdOf(D_MIN), 1);
    return { az: wrap(Math.round(Math.atan2(x, -z) / DEG)), d: Math.round(dOf(rd) * 10) / 10 };
  }
  // Distance slider 0…1000 ↔ metres, in even steps of the room's log scale.
  const distToSlider = (d) => Math.round(((rdOf(d) - rdOf(D_MIN)) / (1 - rdOf(D_MIN))) * 1000);
  const sliderToDist = (v) => Math.round(dOf(rdOf(D_MIN) + (1 - rdOf(D_MIN)) * (v / 1000)) * 10) / 10;
  // Direction snapping: settle onto 0°, ±30°, ±90° or 180° when within 4°.
  // Returns the target as az − offset (so 178° goes to 180°, −178° to −180°), or null.
  const SNAPS = [0, 30, -30, 90, -90, 180];
  function snapAz(az, within = 4) {
    for (const a of SNAPS) { const off = wrap(az - a); if (off !== 0 && Math.abs(off) <= within) return az - off; }
    return null;
  }
  // 2.0 layout: two speakers at ±30°, 1.8 m in front, at ear height.
  const STEREO_AZ = [-30, 30], STEREO_DIST = 1.8;
  // Text on screen ("35° R · +20° · 3.2 m") and spoken by VoiceOver.
  const fmtAz = (a) => { const r = Math.round(a); if (r === 0) return "Front"; if (Math.abs(r) === 180) return "Rear"; return `${Math.abs(r)}° ${r > 0 ? "R" : "L"}`; };
  const fmtEl = (e) => { const r = Math.round(e); return r === 0 ? "Ear level" : `${r < 0 ? "−" : "+"}${Math.abs(r)}°`; };
  const fmtDist = (d) => `${d < 10 ? d.toFixed(1) : "10"} m`;
  const sayAz = (a) => { const r = Math.round(a); if (r === 0) return "Front"; if (Math.abs(r) === 180) return "Rear"; return `${Math.abs(r)}° ${r > 0 ? "right" : "left"}`; };
  const sayEl = (e) => { const r = Math.round(e); return r === 0 ? "Ear level" : `${r < 0 ? "minus" : "plus"} ${Math.abs(r)}°`; };
  const sayDist = (d) => `${d < 10 ? d.toFixed(1) : "10"} metres`;
  return { DEG, EAR, R10, D_MIN, D_MAX, clamp, wrap, rdOf, dOf, roomRadius, toRoom, fromRoomPoint, distToSlider, sliderToDist,
    SNAPS, snapAz, STEREO_AZ, STEREO_DIST, fmtAz, fmtEl, fmtDist, sayAz, sayEl, sayDist };
})();
// ==================================================================== ROOM MATH END
