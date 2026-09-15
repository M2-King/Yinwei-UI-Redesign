//! CoordinateFrameV1 — right-handed Y-up, −Z forward, metres.

export const QUAT_DEGENERATE_NORM = 1e-12;
export const ZERO_DISTANCE_M = 1e-9;
export const HORIZONTAL_POLE_M = 1e-8;

export function vec3(x, y, z) {
  return { x, y, z };
}

export function quat(w, x, y, z) {
  return { w, x, y, z };
}

export const IDENTITY_QUAT = quat(1, 0, 0, 0);
export const HRTF_FORWARD_FALLBACK = vec3(0, 0, -1);

export function vecLength(v) {
  return Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

function cross(a, b) {
  return vec3(
    a.y * b.z - a.z * b.y,
    a.z * b.x - a.x * b.z,
    a.x * b.y - a.y * b.x,
  );
}

function add(a, b) {
  return vec3(a.x + b.x, a.y + b.y, a.z + b.z);
}

function sub(a, b) {
  return vec3(a.x - b.x, a.y - b.y, a.z - b.z);
}

function scaled(v, s) {
  return vec3(v.x * s, v.y * s, v.z * s);
}

export function quatNorm(q) {
  return Math.sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z);
}

export function normalizeQuat(q) {
  const n = quatNorm(q);
  if (n < QUAT_DEGENERATE_NORM) return IDENTITY_QUAT;
  return quat(q.w / n, q.x / n, q.y / n, q.z / n);
}

export function inverseQuat(q) {
  const n = normalizeQuat(q);
  return quat(n.w, -n.x, -n.y, -n.z);
}

export function rotateVec3(q, v) {
  const n = normalizeQuat(q);
  const qvec = vec3(n.x, n.y, n.z);
  const t = scaled(cross(qvec, v), 2);
  return add(add(v, scaled(t, n.w)), cross(qvec, t));
}

export function wrapAzimuthDeg(deg) {
  let az = deg;
  while (az > 180) az -= 360;
  while (az <= -180) az += 360;
  return az;
}

export function shortestAzimuthDeltaDeg(fromDeg, toDeg) {
  let d = toDeg - fromDeg;
  while (d > 180) d -= 360;
  while (d < -180) d += 360;
  return d;
}

export function lerpAzimuthDeg(fromDeg, toDeg, t) {
  return wrapAzimuthDeg(fromDeg + shortestAzimuthDeltaDeg(fromDeg, toDeg) * t);
}

export function sphericalToLocal(p) {
  const az = (p.azimuthDeg * Math.PI) / 180;
  const el = (p.elevationDeg * Math.PI) / 180;
  const d = p.distanceM;
  const ce = Math.cos(el);
  return vec3(d * Math.sin(az) * ce, d * Math.sin(el), -d * Math.cos(az) * ce);
}

export function localToSpherical(p) {
  const r = vecLength(p);
  if (r < ZERO_DISTANCE_M) {
    return { azimuthDeg: 0, elevationDeg: 0, distanceM: 0 };
  }
  const h = Math.sqrt(p.x * p.x + p.z * p.z);
  if (h < HORIZONTAL_POLE_M) {
    return {
      azimuthDeg: 0,
      elevationDeg: p.y >= 0 ? 90 : -90,
      distanceM: r,
    };
  }
  const el = (Math.asin(Math.min(1, Math.max(-1, p.y / r))) * 180) / Math.PI;
  const az = wrapAzimuthDeg((Math.atan2(p.x, -p.z) * 180) / Math.PI);
  return { azimuthDeg: az, elevationDeg: el, distanceM: r };
}

export function hrtfUnitFromLocal(local) {
  const r = vecLength(local);
  if (r < ZERO_DISTANCE_M) return HRTF_FORWARD_FALLBACK;
  return scaled(local, 1 / r);
}

export function worldToListenerLocal(world, listener) {
  const rel = sub(world, listener.worldPosition);
  return rotateVec3(inverseQuat(listener.orientation), rel);
}

export function listenerLocalToWorld(local, listener) {
  return add(listener.worldPosition, rotateVec3(listener.orientation, local));
}

export function geometricDistanceM(local) {
  const r = vecLength(local);
  return r < ZERO_DISTANCE_M ? 0 : r;
}
