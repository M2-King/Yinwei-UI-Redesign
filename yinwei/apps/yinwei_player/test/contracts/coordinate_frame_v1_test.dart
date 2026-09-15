import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';

import 'fixture_loader.dart';

void main() {
  final fixture = loadContractFixture('coordinate_fixtures_v1.json');
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
  final tight = asF(fixture['tolerance']);
  final trig = asF(fixture['trigTolerance']);

  Vec3V1 xyz(Map<String, dynamic> m) => Vec3V1(asF(m['x']), asF(m['y']), asF(m['z']));

  QuatV1 parseQuat(Map<String, dynamic> m) =>
      QuatV1(asF(m['w']), asF(m['x']), asF(m['y']), asF(m['z']));

  void expectVec(Vec3V1 got, Map<String, dynamic> want, double eps) {
    expect(got.x, closeTo(asF(want['x']), eps));
    expect(got.y, closeTo(asF(want['y']), eps));
    expect(got.z, closeTo(asF(want['z']), eps));
  }

  test('CoordinateFrameV1 fixture metadata', () {
    expect(fixture['schemaId'], 'CoordinateFrameV1');
    expect(fixture['quaternionStorageOrder'], ['w', 'x', 'y', 'z']);
    expect(fixture['handedness'], 'right');
    expect(fixture['distanceUnit'], 'metre');
  });

  for (final c in cases) {
    test('CoordinateFrameV1 ${c['id']}', () {
      final kind = c['kind'] as String;
      final eps = (c['id'] as String).contains('elevation_near') ? trig : tight;
      if (kind == 'pose_roundtrip') {
        final input = c['input'] as Map<String, dynamic>;
        final expectMap = c['expect'] as Map<String, dynamic>;
        final pose = SphericalV1(
          azimuthDeg: asF(input['azimuthDeg']),
          elevationDeg: asF(input['elevationDeg']),
          distanceM: asF(input['distanceM']),
        );
        final local = sphericalToLocal(pose);
        expectVec(local, expectMap['world'] as Map<String, dynamic>, eps);
        expectVec(local, expectMap['listenerLocal'] as Map<String, dynamic>, eps);
        expectVec(
          hrtfUnitFromLocal(local),
          expectMap['hrtfUnit'] as Map<String, dynamic>,
          eps,
        );
        final back = localToSpherical(local);
        expect(back.azimuthDeg, closeTo(asF(expectMap['azimuthDeg']), trig));
        expect(back.elevationDeg, closeTo(asF(expectMap['elevationDeg']), trig));
        expect(back.distanceM, closeTo(asF(expectMap['distanceM']), eps));
        expect(geometricDistanceM(local), closeTo(asF(expectMap['dspDistanceM']), eps));
        expect(hrtfUnitFromLocal(local).length, closeTo(1, tight));
        return;
      }
      if (kind == 'world_to_listener') {
        final listenerMap = c['listener'] as Map<String, dynamic>;
        final listener = ListenerPoseV1(
          worldPosition: xyz(listenerMap['worldPosition'] as Map<String, dynamic>),
          orientation: parseQuat(listenerMap['orientation'] as Map<String, dynamic>),
        );
        final world = xyz(c['world'] as Map<String, dynamic>);
        final local = worldToListenerLocal(world, listener);
        final expectMap = c['expect'] as Map<String, dynamic>;
        expectVec(local, expectMap['listenerLocal'] as Map<String, dynamic>, trig);
        expectVec(
          hrtfUnitFromLocal(local),
          expectMap['hrtfUnit'] as Map<String, dynamic>,
          trig,
        );
        final sph = localToSpherical(local);
        expect(sph.azimuthDeg, closeTo(asF(expectMap['azimuthDeg']), trig));
        expect(sph.elevationDeg, closeTo(asF(expectMap['elevationDeg']), trig));
        expect(sph.distanceM, closeTo(asF(expectMap['distanceM']), trig));
        expect(geometricDistanceM(local), closeTo(asF(expectMap['dspDistanceM']), trig));
        return;
      }
      if (kind == 'wrap_azimuth') {
        expect(wrapAzimuthDeg(asF(c['inputDeg'])), closeTo(asF(c['expectDeg']), tight));
        return;
      }
      if (kind == 'shortest_arc') {
        expect(
          shortestAzimuthDeltaDeg(asF(c['fromDeg']), asF(c['toDeg'])),
          closeTo(asF(c['expectDeltaDeg']), tight),
        );
        expect(
          lerpAzimuthDeg(asF(c['fromDeg']), asF(c['toDeg']), asF(c['t'])),
          closeTo(asF(c['expectInterpDeg']), tight),
        );
        return;
      }
      if (kind == 'cartesian_to_spherical') {
        final local = xyz(c['listenerLocal'] as Map<String, dynamic>);
        final expectMap = c['expect'] as Map<String, dynamic>;
        final sph = localToSpherical(local);
        expect(sph.azimuthDeg, closeTo(asF(expectMap['azimuthDeg']), trig));
        expect(sph.elevationDeg, closeTo(asF(expectMap['elevationDeg']), trig));
        expect(sph.distanceM, closeTo(asF(expectMap['distanceM']), tight));
        expectVec(
          hrtfUnitFromLocal(local),
          expectMap['hrtfUnit'] as Map<String, dynamic>,
          tight,
        );
        return;
      }
      if (kind == 'zero_distance') {
        final listenerMap = c['listener'] as Map<String, dynamic>;
        final listener = ListenerPoseV1(
          worldPosition: xyz(listenerMap['worldPosition'] as Map<String, dynamic>),
          orientation: parseQuat(listenerMap['orientation'] as Map<String, dynamic>),
        );
        final world = xyz(c['world'] as Map<String, dynamic>);
        final local = worldToListenerLocal(world, listener);
        final expectMap = c['expect'] as Map<String, dynamic>;
        expectVec(local, expectMap['listenerLocal'] as Map<String, dynamic>, tight);
        expectVec(
          hrtfUnitFromLocal(local),
          expectMap['hrtfUnit'] as Map<String, dynamic>,
          tight,
        );
        final sph = localToSpherical(local);
        expect(sph.azimuthDeg, closeTo(asF(expectMap['azimuthDeg']), tight));
        expect(sph.elevationDeg, closeTo(asF(expectMap['elevationDeg']), tight));
        expect(sph.distanceM, closeTo(asF(expectMap['distanceM']), tight));
        expect(expectMap['dspDistanceIndependent'], isTrue);
        expect(hrtfUnitFromLocal(local).length, closeTo(1, tight));
        expect(geometricDistanceM(local), 0);
        return;
      }
      fail('unknown fixture kind $kind');
    });
  }
}
