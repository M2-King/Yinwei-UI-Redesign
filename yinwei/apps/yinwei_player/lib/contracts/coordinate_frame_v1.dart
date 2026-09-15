/// CoordinateFrameV1 — Spatial Scene Domain axes and conversions.
///
/// Isolated from playback / HRTF / UI. Not wired into runtime in Phase 1A.
library;

import 'dart:math' as math;

const double kQuatDegenerateNorm = 1e-12;
const double kZeroDistanceM = 1e-9;
const double kHorizontalPoleM = 1e-8;

class Vec3V1 {
  const Vec3V1(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double get length => math.sqrt(x * x + y * y + z * z);

  Vec3V1 operator +(Vec3V1 o) => Vec3V1(x + o.x, y + o.y, z + o.z);

  Vec3V1 operator -(Vec3V1 o) => Vec3V1(x - o.x, y - o.y, z - o.z);

  Vec3V1 scaled(double s) => Vec3V1(x * s, y * s, z * s);

  static const zero = Vec3V1(0, 0, 0);
  static const hrtfForwardFallback = Vec3V1(0, 0, -1);
}

/// Hamilton storage order (w, x, y, z).
class QuatV1 {
  const QuatV1(this.w, this.x, this.y, this.z);

  final double w;
  final double x;
  final double y;
  final double z;

  static const identity = QuatV1(1, 0, 0, 0);

  double get norm => math.sqrt(w * w + x * x + y * y + z * z);

  bool get isDegenerate => norm < kQuatDegenerateNorm;

  QuatV1 normalized() {
    final n = norm;
    if (n < kQuatDegenerateNorm) return QuatV1.identity;
    return QuatV1(w / n, x / n, y / n, z / n);
  }

  QuatV1 get conjugate => QuatV1(w, -x, -y, -z);

  /// Inverse of the normalized quaternion (conjugate).
  QuatV1 inverse() => normalized().conjugate;
}

class SphericalV1 {
  const SphericalV1({
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
  });

  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
}

class ListenerPoseV1 {
  const ListenerPoseV1({
    required this.worldPosition,
    this.orientation = QuatV1.identity,
  });

  final Vec3V1 worldPosition;
  final QuatV1 orientation;
}

Vec3V1 _cross(Vec3V1 a, Vec3V1 b) => Vec3V1(
      a.y * b.z - a.z * b.y,
      a.z * b.x - a.x * b.z,
      a.x * b.y - a.y * b.x,
    );

/// Rotate [v] by unit quaternion [q] (listener-local → world when q is listener orientation).
Vec3V1 rotateVec3(QuatV1 q, Vec3V1 v) {
  final n = q.normalized();
  final qvec = Vec3V1(n.x, n.y, n.z);
  final t = _cross(qvec, v).scaled(2);
  return v + t.scaled(n.w) + _cross(qvec, t);
}

double wrapAzimuthDeg(double deg) {
  var az = deg;
  while (az > 180) {
    az -= 360;
  }
  while (az <= -180) {
    az += 360;
  }
  return az;
}

/// Signed shortest arc in [-180, +180] degrees.
double shortestAzimuthDeltaDeg(double fromDeg, double toDeg) {
  var d = toDeg - fromDeg;
  while (d > 180) {
    d -= 360;
  }
  while (d < -180) {
    d += 360;
  }
  return d;
}

double lerpAzimuthDeg(double fromDeg, double toDeg, double t) {
  return wrapAzimuthDeg(fromDeg + shortestAzimuthDeltaDeg(fromDeg, toDeg) * t);
}

Vec3V1 sphericalToLocal(SphericalV1 p) {
  final az = p.azimuthDeg * math.pi / 180.0;
  final el = p.elevationDeg * math.pi / 180.0;
  final d = p.distanceM;
  final ce = math.cos(el);
  return Vec3V1(
    d * math.sin(az) * ce,
    d * math.sin(el),
    -d * math.cos(az) * ce,
  );
}

SphericalV1 localToSpherical(Vec3V1 p) {
  final r = p.length;
  if (r < kZeroDistanceM) {
    return const SphericalV1(azimuthDeg: 0, elevationDeg: 0, distanceM: 0);
  }
  final h = math.sqrt(p.x * p.x + p.z * p.z);
  if (h < kHorizontalPoleM) {
    final el = p.y >= 0 ? 90.0 : -90.0;
    return SphericalV1(azimuthDeg: 0, elevationDeg: el, distanceM: r);
  }
  final el = math.asin((p.y / r).clamp(-1.0, 1.0)) * 180.0 / math.pi;
  final az = wrapAzimuthDeg(math.atan2(p.x, -p.z) * 180.0 / math.pi);
  return SphericalV1(azimuthDeg: az, elevationDeg: el, distanceM: r);
}

Vec3V1 hrtfUnitFromLocal(Vec3V1 local) {
  final r = local.length;
  if (r < kZeroDistanceM) return Vec3V1.hrtfForwardFallback;
  return local.scaled(1.0 / r);
}

Vec3V1 worldToListenerLocal(Vec3V1 world, ListenerPoseV1 listener) {
  final rel = world - listener.worldPosition;
  return rotateVec3(listener.orientation.inverse(), rel);
}

Vec3V1 listenerLocalToWorld(Vec3V1 local, ListenerPoseV1 listener) {
  return listener.worldPosition + rotateVec3(listener.orientation, local);
}

/// Geometric distance is independent of the HRTF unit vector.
double geometricDistanceM(Vec3V1 local) {
  final r = local.length;
  return r < kZeroDistanceM ? 0 : r;
}
