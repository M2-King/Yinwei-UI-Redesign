import 'dart:io';

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
    expect(html.contains('Studio monitor'), isTrue);
  });

  test('Three.js source poses post intents to Flutter host only', () async {
    final scene = await File('assets/spatial_workspace/scene.js').readAsString();
    expect(scene.contains('YinweiPose.postMessage'), isTrue);
    expect(scene.contains('sourcePosePreview'), isTrue);
    expect(scene.contains('sourcePoseCommit'), isTrue);
    expect(scene.contains('yinwei_set_params'), isFalse);
    expect(scene.contains('EngineApi'), isFalse);
    expect(scene.contains('spatial_core'), isFalse);
  });

  test('Flutter host does not DSP-clamp Three.js distance before Scene Store', () async {
    final dart = await File('lib/widgets/spatial_workspace.dart').readAsString();
    expect(dart.contains('YinweiPose'), isTrue);
    expect(dart.contains('dist.clamp(0.5, 10.0)'), isFalse);
    expect(dart.contains('onSceneIntent'), isTrue);
    expect(dart.contains('applySceneSnapshot'), isTrue);
    expect(dart.contains('applyPlaybackTelemetry'), isTrue);
  });

  test('Phase 3 scene.js is a professional 3D workspace without geometric clamp', () async {
    final scene = await File('assets/spatial_workspace/scene.js').readAsString();
    expect(scene.contains('objectsById'), isTrue);
    expect(scene.contains('sourcePosePreview'), isTrue);
    expect(scene.contains('sourcePoseCommit'), isTrue);
    expect(scene.contains('elevationHandle'), isTrue);
    expect(scene.contains('contactShadow'), isTrue);
    expect(scene.contains('relationLine'), isTrue);
    expect(scene.contains('camDamp'), isTrue);
    expect(scene.contains("makeLabelSprite('FRONT"), isFalse);
    expect(scene.contains("makeLabelSprite('RIGHT"), isFalse);
    expect(scene.contains("makeLabelSprite('LEFT"), isFalse);
    expect(scene.contains("makeLabelSprite('REAR"), isFalse);
    expect(scene.contains('syncObjectLabels'), isTrue);
    expect(scene.contains('ROOM * 0.42'), isFalse);
    expect(scene.contains('yinwei_set_params'), isFalse);
    expect(scene.contains('EngineApi'), isFalse);
    expect(scene.contains('closestVisible'), isTrue);
    expect(
      scene.contains('g.userData.elevationHandle = true'),
      isFalse,
    );
    expect(
      scene.contains("closest.mesh.userData.kind === 'source') return closest"),
      isFalse,
    );
    expect(scene.contains('return closestVisible || closest'), isTrue);
  });

  test('Phase 3 HUD exposes camera fit and elevation affordance', () async {
    final html = await File('assets/spatial_workspace/index.html').readAsString();
    expect(html.contains('data-view="fit"'), isTrue);
    expect(html.contains('data-view="top"'), isTrue);
    expect(html.contains('data-view="front"'), isTrue);
    expect(html.contains('data-view="listener"'), isTrue);
    expect(html.contains('id="sel"'), isTrue);
  });

  test('Phase 3 workspace is more prominent than Now Playing', () async {
    final dart = await File('lib/screens/player_screen.dart').readAsString();
    expect(dart.contains('flex: wide ? 10 : 5'), isTrue);
    expect(dart.contains('flex: wide ? 3 : 5'), isTrue);
    expect(dart.contains('maxWidth >= 1100'), isTrue);
  });
}
