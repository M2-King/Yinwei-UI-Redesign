import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';

void main() {
  Widget field({
    required void Function(double azimuth, double elevation) onPoseChanged,
    required ValueChanged<double> onDistanceChanged,
    double azimuth = 0,
    double elevation = 10,
    double distance = 1.5,
    bool orbiting = false,
    double width = 420,
  }) {
    return MaterialApp(
      theme: YinweiTheme.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox.square(
            dimension: width,
            child: OrbitVisualizer(
              playhead: 0.35,
              azimuthDeg: azimuth,
              elevationDeg: elevation,
              distanceM: distance,
              envelopment: 0.6,
              active: false,
              orbiting: orbiting,
              onPoseChanged: onPoseChanged,
              onDistanceChanged: onDistanceChanged,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('Free drag and wheel keep pose and distance callbacks working',
      (tester) async {
    (double, double)? pose;
    double? distance;
    await tester.pumpWidget(
      field(
        onPoseChanged: (azimuth, elevation) => pose = (azimuth, elevation),
        onDistanceChanged: (value) => distance = value,
      ),
    );

    final visualizer = find.byType(OrbitVisualizer);
    await tester.drag(visualizer, const Offset(74, -46));
    await tester.pump();

    expect(pose, isNotNull);
    expect(pose!.$1, isNot(0));
    expect(pose!.$2, inInclusiveRange(-90, 90));

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(visualizer),
        scrollDelta: const Offset(0, 100),
      ),
    );
    await tester.pump();
    expect(distance, closeTo(2.5, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Top view switches projection and maps drag to bearing and range',
      (tester) async {
    (double, double)? pose;
    double? distance;
    await tester.pumpWidget(
      field(
        onPoseChanged: (azimuth, elevation) => pose = (azimuth, elevation),
        onDistanceChanged: (value) => distance = value,
      ),
    );

    await tester.tap(find.text('Top'));
    await tester.pump(const Duration(milliseconds: 450));

    final center = tester.getCenter(find.byType(OrbitVisualizer));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(100, 0));
    await gesture.up();
    await tester.pump();

    expect(pose, isNotNull);
    expect(pose!.$1, closeTo(90, 1));
    expect(pose!.$2, 10);
    expect(distance, isNotNull);
    expect(distance!, inInclusiveRange(0.5, 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Source trail updates, fades, and narrow layout paints cleanly',
      (tester) async {
    void pose(double _, double __) {}
    void distance(double _) {}
    await tester.pumpWidget(
      field(
        onPoseChanged: pose,
        onDistanceChanged: distance,
        orbiting: false,
        width: 220,
      ),
    );
    await tester.pumpWidget(
      field(
        onPoseChanged: pose,
        onDistanceChanged: distance,
        azimuth: 55,
        elevation: 34,
        orbiting: false,
        width: 220,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      field(
        onPoseChanged: pose,
        onDistanceChanged: distance,
        azimuth: 78,
        elevation: 40,
        orbiting: true,
        width: 220,
      ),
    );
    await tester.pump();

    expect(find.text('Free'), findsOneWidget);
    expect(find.text('Top'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
