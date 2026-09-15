import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/spatial_workspace.dart';
import 'package:yinwei_player/widgets/spatial_workspace_html.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fallback keeps OrbitVisualizer pose callbacks', (tester) async {
    (double, double)? pose;
    double? distance;
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: SizedBox.square(
            dimension: 420,
            child: SpatialWorkspace(
              playhead: 0.2,
              azimuthDeg: 0,
              elevationDeg: 0,
              distanceM: 1.5,
              envelopment: 0.5,
              forceFallback: true,
              onPoseChanged: (az, el) => pose = (az, el),
              onDistanceChanged: (d) => distance = d,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(OrbitVisualizer), findsOneWidget);
    await tester.drag(find.byType(OrbitVisualizer), const Offset(74, -46));
    await tester.pump();
    expect(pose, isNotNull);
    expect(distance, isNull);
  });

  test('bundled HTML inlines Three.js and the workspace scene', () async {
    final html = await SpatialWorkspaceHtml.load();
    expect(html.contains('vendor/three.min.js'), isFalse);
    expect(html.contains('src="scene.js"'), isFalse);
    expect(html.contains('YinweiWorkspace'), isTrue);
    expect(html.contains('WebGLRenderer') || html.contains('THREE'), isTrue);
    expect(html.contains('data-view="listener"'), isTrue);
    expect(html.contains('visual layout'), isTrue);
  });
}
