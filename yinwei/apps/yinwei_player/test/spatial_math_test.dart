import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/models/spatial_math.dart';

void main() {
  test('front pose is −Z', () {
    final p = poseToXyz(azimuthDeg: 0, elevationDeg: 0, distanceM: 2);
    expect(p.x, closeTo(0, 1e-9));
    expect(p.y, closeTo(0, 1e-9));
    expect(p.z, closeTo(-2, 1e-9));
  });

  test('right pose is +X', () {
    final p = poseToXyz(azimuthDeg: 90, elevationDeg: 0, distanceM: 1.5);
    expect(p.x, closeTo(1.5, 1e-9));
    expect(p.y, closeTo(0, 1e-9));
    expect(p.z, closeTo(0, 1e-9));
  });

  test('overhead pose is +Y', () {
    final p = poseToXyz(azimuthDeg: 0, elevationDeg: 90, distanceM: 1);
    expect(p.x, closeTo(0, 1e-9));
    expect(p.y, closeTo(1, 1e-9));
    expect(p.z, closeTo(0, 1e-9));
  });

  test('xyz round-trips through spherical pose', () {
    const samples = [
      (45.0, 10.0, 2.1),
      (-90.0, -10.0, 1.5),
      (180.0, 0.0, 3.0),
      (-135.0, 20.0, 2.0),
    ];
    for (final s in samples) {
      final xyz = poseToXyz(
        azimuthDeg: s.$1,
        elevationDeg: s.$2,
        distanceM: s.$3,
      );
      final back = xyzToPose(xyz);
      expect(back.azimuthDeg, closeTo(s.$1, 1e-6));
      expect(back.elevationDeg, closeTo(s.$2, 1e-6));
      expect(back.distanceM, closeTo(s.$3, 1e-6));
    }
  });

  test('ITU-8 visual speakers are layout-only with eight channels', () {
    expect(VisualSpeaker.itu8.length, 8);
    expect(
      VisualSpeaker.itu8.map((s) => s.channel).toList(),
      ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Lb', 'Rb'],
    );
    for (final s in VisualSpeaker.itu8) {
      expect(s.distanceM, inInclusiveRange(0.5, 10));
      expect(s.xyz.length, closeTo(s.distanceM, 1e-6));
    }
  });
}
