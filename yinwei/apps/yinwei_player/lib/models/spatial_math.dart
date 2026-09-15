import 'dart:math' as math;

/// Yinwei pose ↔ world XYZ. Matches `spatial_core` and the Three.js workspace:
/// 0° front (−Z), +90° right (+X), Y up.
class WorldXyz {
  const WorldXyz(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double get length => math.sqrt(x * x + y * y + z * z);
}

class SphericalPose {
  const SphericalPose({
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
  });

  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
}

WorldXyz poseToXyz({
  required double azimuthDeg,
  required double elevationDeg,
  required double distanceM,
}) {
  final az = azimuthDeg * math.pi / 180.0;
  final el = elevationDeg * math.pi / 180.0;
  final dist = distanceM;
  final ce = math.cos(el);
  return WorldXyz(
    dist * math.sin(az) * ce,
    dist * math.sin(el),
    -dist * math.cos(az) * ce,
  );
}

SphericalPose xyzToPose(WorldXyz p) {
  var dist = p.length;
  if (dist < 1e-6) {
    return const SphericalPose(
      azimuthDeg: 0,
      elevationDeg: 0,
      distanceM: 0.5,
    );
  }
  dist = dist.clamp(0.5, 10.0);
  final el = math.asin((p.y / p.length).clamp(-1.0, 1.0)) * 180.0 / math.pi;
  var az = math.atan2(p.x, -p.z) * 180.0 / math.pi;
  if (az > 180) az -= 360;
  if (az <= -180) az += 360;
  return SphericalPose(
    azimuthDeg: az,
    elevationDeg: el.clamp(-90.0, 90.0),
    distanceM: dist,
  );
}

/// Visual-only loudspeaker anchors (ITU-ish 7.1 + LFE). Not an audio Array.
class VisualSpeaker {
  const VisualSpeaker({
    required this.id,
    required this.channel,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
  });

  final String id;
  final String channel;
  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;

  WorldXyz get xyz => poseToXyz(
        azimuthDeg: azimuthDeg,
        elevationDeg: elevationDeg,
        distanceM: distanceM,
      );

  Map<String, Object> toJson() => {
        'id': id,
        'channel': channel,
        'azimuth': azimuthDeg,
        'elevation': elevationDeg,
        'distance': distanceM,
      };

  /// L / R / C / LFE / Ls / Rs / Lb / Rb — layout only.
  static const itu8 = <VisualSpeaker>[
    VisualSpeaker(
        id: 'L', channel: 'L', azimuthDeg: -30, elevationDeg: 0, distanceM: 2.0),
    VisualSpeaker(
        id: 'R', channel: 'R', azimuthDeg: 30, elevationDeg: 0, distanceM: 2.0),
    VisualSpeaker(
        id: 'C', channel: 'C', azimuthDeg: 0, elevationDeg: 0, distanceM: 2.0),
    VisualSpeaker(
        id: 'LFE',
        channel: 'LFE',
        azimuthDeg: 0,
        elevationDeg: -28,
        distanceM: 1.7),
    VisualSpeaker(
        id: 'Ls',
        channel: 'Ls',
        azimuthDeg: -90,
        elevationDeg: 0,
        distanceM: 2.0),
    VisualSpeaker(
        id: 'Rs',
        channel: 'Rs',
        azimuthDeg: 90,
        elevationDeg: 0,
        distanceM: 2.0),
    VisualSpeaker(
        id: 'Lb',
        channel: 'Lb',
        azimuthDeg: -135,
        elevationDeg: 0,
        distanceM: 2.0),
    VisualSpeaker(
        id: 'Rb',
        channel: 'Rb',
        azimuthDeg: 135,
        elevationDeg: 0,
        distanceM: 2.0),
  ];
}
