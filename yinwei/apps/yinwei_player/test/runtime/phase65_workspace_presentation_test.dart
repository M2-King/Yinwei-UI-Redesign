import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/now_playing_panel.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/spatial_workspace.dart';

void main() {
  const trig = 1e-9;

  SpatialSceneBridge boot() {
    return SpatialSceneBridge(
      adapter: SpatialRuntimeAdapter()..bootstrap(SpatialParams()),
    );
  }

  test('Original maps to idle, Spatial+Point to point, Spatial+2.0 to stereo2', () {
    expect(
      workspacePresentationOf(
        playbackMode: PlaybackMode.original,
        arrayMode: ArrayMode.off,
      ),
      WorkspacePresentation.idle,
    );
    expect(
      workspacePresentationOf(
        playbackMode: PlaybackMode.original,
        arrayMode: ArrayMode.stereo2,
      ),
      WorkspacePresentation.idle,
    );
    expect(
      workspacePresentationOf(
        playbackMode: PlaybackMode.spatial,
        arrayMode: ArrayMode.off,
      ),
      WorkspacePresentation.point,
    );
    expect(
      workspacePresentationOf(
        playbackMode: PlaybackMode.spatial,
        arrayMode: ArrayMode.stereo2,
      ),
      WorkspacePresentation.stereo2,
    );
  });

  test('Array L/R visuals use CoordinateFrameV1 around the listener', () {
    final visuals = arraySpeakerVisuals(
      speakers: ArrayLayout.stereo2Speakers(),
      selectedIndex: 0,
    );
    expect(visuals, hasLength(2));
    expect(visuals.first.id, 'array-0');
    expect(visuals.last.id, 'array-1');
    expect(visuals.first.label, 'L');
    expect(visuals.last.label, 'R');

    final left = sphericalToLocal(
      const SphericalV1(azimuthDeg: -30, elevationDeg: 0, distanceM: 1.8),
    );
    final right = sphericalToLocal(
      const SphericalV1(azimuthDeg: 30, elevationDeg: 0, distanceM: 1.8),
    );
    expect(visuals.first.world.x, closeTo(left.x, trig));
    expect(visuals.first.world.y, closeTo(left.y, trig));
    expect(visuals.first.world.z, closeTo(left.z, trig));
    expect(visuals.last.world.x, closeTo(right.x, trig));
    expect(visuals.last.world.z, closeTo(right.z, trig));
    expect(visuals.first.world.x, closeTo(-0.9, 1e-6));
    expect(visuals.first.world.z, closeTo(-1.8 * 0.8660254037844386, 1e-6));
  });

  test('moved Array azimuth updates visual world without SceneContract', () {
    final speakers = ArrayLayout.stereo2Speakers();
    speakers.first.azimuthDeg = -50;
    speakers.first.distanceM = 2.4;
    final visuals = arraySpeakerVisuals(speakers: speakers, selectedIndex: 0);
    final expected = sphericalToLocal(
      const SphericalV1(azimuthDeg: -50, elevationDeg: 0, distanceM: 2.4),
    );
    expect(visuals.first.world.x, closeTo(expected.x, trig));
    expect(visuals.first.world.z, closeTo(expected.z, trig));
  });

  test('Array mode switch does not bump Point scene revision or pose', () async {
    final engine = MockEngine();
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final sceneBridge = SpatialSceneBridge(adapter: adapter);
    final layoutCtrl = EngineController(engine: engine);
    final rev = adapter.appliedRevision;
    final source = (adapter.snapshot()!['sources'] as List).first as Map;
    final x = (source['worldPosition'] as Map)['x'];

    await layoutCtrl.applyArrayMode(ArrayMode.stereo2);
    expect(adapter.appliedRevision, rev);
    expect(
      ((adapter.snapshot()!['sources'] as List).first as Map)['worldPosition']['x'],
      x,
    );
    expect(layoutCtrl.array.mode, ArrayMode.stereo2);
    expect(layoutCtrl.array.speakers.first.azimuthDeg, closeTo(-30, trig));

    await layoutCtrl.applyArrayMode(ArrayMode.off);
    expect(adapter.appliedRevision, rev);
    expect(layoutCtrl.array.speakers.first.azimuthDeg, closeTo(-30, trig));
    expect(sceneBridge.adapter.config.emitterBindings, isEmpty);
    layoutCtrl.dispose();
  });

  test('Point pose survives 2.0 enter/leave; Array pose survives Point enter/leave', () async {
    final ctrl = EngineController(engine: MockEngine());
    ctrl.params.azimuthDeg = 81;
    ctrl.params.elevationDeg = -1;
    ctrl.params.distanceM = 2.65;
    await ctrl.applyArrayMode(ArrayMode.stereo2);
    final mutated = ctrl.array.copy();
    mutated.speakers.first.azimuthDeg = -50;
    mutated.speakers.last.azimuthDeg = 40;
    await ctrl.setArray(mutated);

    await ctrl.applyArrayMode(ArrayMode.off);
    expect(ctrl.params.azimuthDeg, 81);
    expect(ctrl.params.elevationDeg, -1);
    expect(ctrl.params.distanceM, 2.65);
    expect(ctrl.array.speakers.first.azimuthDeg, closeTo(-50, trig));
    expect(ctrl.array.speakers.last.azimuthDeg, closeTo(40, trig));

    await ctrl.applyArrayMode(ArrayMode.stereo2);
    expect(ctrl.array.speakers.first.azimuthDeg, closeTo(-50, trig));
    expect(ctrl.array.speakers.last.azimuthDeg, closeTo(40, trig));
    expect(ctrl.params.azimuthDeg, 81);
    ctrl.dispose();
  });

  test('Array remains outside SceneContract emitters', () {
    final bridge = boot();
    final emitters = bridge.adapter.snapshot()!['emitters'] as List;
    expect(emitters.every((e) => (e as Map)['id'].toString().startsWith('emitter-')), isTrue);
    expect(emitters.any((e) => (e as Map)['id'].toString().startsWith('array-')), isFalse);
    expect(arraySpeakerObjectId(0), 'array-0');
    expect(arraySpeakerIndexFromId('array-1'), 1);
    expect(arraySpeakerIndexFromId('source-main'), isNull);
  });

  test('scene.js keeps one studio and presents Array speakers as overlay', () async {
    final js = await File('assets/spatial_workspace/scene.js').readAsString();
    expect(js.contains('applyPresentation'), isTrue);
    expect(js.contains("presentation === 'stereo2'"), isTrue);
    expect(js.contains("presentation === 'point'"), isTrue);
    expect(js.contains("presentation !== 'idle'"), isTrue);
    expect(js.contains("kind === 'arraySpeaker'"), isTrue);
    expect(js.contains('arraySpeakerPosePreview'), isTrue);
    expect(js.contains('yinwei_set_params'), isFalse);
    expect(js.contains('EngineApi'), isFalse);
    expect(js.contains('if (isArraySpeakerId(id)) return;'), isTrue);
    expect(js.contains('else if (kind === \'emitter\') mesh.visible = false'), isTrue);
  });

  test('SpatialWorkspace no longer swaps the Windows studio for Array', () async {
    final dart = await File('lib/widgets/spatial_workspace.dart').readAsString();
    expect(dart.contains('if (_arrayOn) return false'), isFalse);
    expect(dart.contains('applyPresentation'), isTrue);
    expect(dart.contains('workspacePresentationOf'), isTrue);
    expect(dart.contains('OrbitVisualizer'), isTrue);
  });

  testWidgets('PlayerScreen keeps SpatialWorkspace across Original/Point/2.0',
      (tester) async {
    final ctrl = EngineController(engine: MockEngine());
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      ctrl.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(controller: ctrl),
      ),
    );
    await tester.pump();

    SpatialWorkspace workspace() =>
        tester.widget<SpatialWorkspace>(find.byType(SpatialWorkspace));

    expect(find.byType(SpatialWorkspace), findsOneWidget);
    expect(workspace().presentation, WorkspacePresentation.point);
    final rev0 = ctrl.params.azimuthDeg;

    await tester.tap(
      find.descendant(
        of: find.byType(NowPlayingPanel),
        matching: find.text('Original'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(ctrl.mode, PlaybackMode.original);
    expect(workspace().presentation, WorkspacePresentation.idle);
    expect(find.byType(SpatialWorkspace), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(NowPlayingPanel),
        matching: find.text('Spatial'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(workspace().presentation, WorkspacePresentation.point);

    await tester.tap(
      find.descendant(
        of: find.byType(NowPlayingPanel),
        matching: find.text('2.0'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(ctrl.array.mode, ArrayMode.stereo2);
    expect(workspace().presentation, WorkspacePresentation.stereo2);
    expect(workspace().arraySpeakers, isNotNull);
    expect(workspace().arraySpeakers, hasLength(2));
    expect(find.byType(SpatialWorkspace), findsOneWidget);
    expect(ctrl.params.azimuthDeg, rev0);

    await tester.tap(
      find.descendant(
        of: find.byType(NowPlayingPanel),
        matching: find.text('Point'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(workspace().presentation, WorkspacePresentation.point);
    expect(ctrl.array.speakers.first.azimuthDeg, closeTo(-30, trig));
  });

  testWidgets('Array pose edits rebuild Inspector and workspace presentation',
      (tester) async {
    final ctrl = EngineController(engine: MockEngine());
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      ctrl.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(controller: ctrl),
      ),
    );
    await tester.pump();
    await ctrl.applyArrayMode(ArrayMode.stereo2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final mutated = ctrl.array.copy();
    mutated.speakers.first.azimuthDeg = -50;
    mutated.speakers.first.distanceM = 2.4;
    await ctrl.setArray(mutated);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final workspace =
        tester.widget<SpatialWorkspace>(find.byType(SpatialWorkspace));
    expect(workspace.presentation, WorkspacePresentation.stereo2);
    expect(workspace.arraySpeakers!.first.azimuthDeg, closeTo(-50, trig));
    expect(workspace.arraySpeakers!.first.distanceM, closeTo(2.4, trig));
    expect(find.text('-50°'), findsWidgets);
    expect(find.text('2.40 m'), findsWidgets);
  });

  testWidgets('test fallback still uses OrbitVisualizer without replacing PlayerScreen workspace',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: const Scaffold(
          body: SizedBox.square(
            dimension: 420,
            child: SpatialWorkspace(
              playhead: 0,
              azimuthDeg: 0,
              elevationDeg: 0,
              distanceM: 1.8,
              envelopment: 0.4,
              playbackMode: PlaybackMode.spatial,
              arrayMode: ArrayMode.stereo2,
              arraySpeakers: null,
              forceFallback: true,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(SpatialWorkspace), findsOneWidget);
    expect(find.byType(OrbitVisualizer), findsOneWidget);
    expect(
      tester.widget<SpatialWorkspace>(find.byType(SpatialWorkspace)).presentation,
      WorkspacePresentation.stereo2,
    );
  });

  test('array visual intents do not look like Point scene commits', () {
    const preview = {
      'type': 'arraySpeakerPosePreview',
      'index': 0,
      'azimuthDeg': -50,
      'elevationDeg': 0,
      'distanceM': 2.4,
    };
    expect(jsonEncode(preview).contains('sourcePoseCommit'), isFalse);
    expect(jsonEncode(preview).contains('basedOnRevision'), isFalse);
  });
}
