import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/island_spatial_controls.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/widgets/island_spatial_controller.dart';

void main() {
  test('Point mini uses canonical axes and leaves geometric metres unclamped', () {
    for (final entry in [const Offset(0,-87), const Offset(87,0), const Offset(0,87), const Offset(-87,0)].asMap().entries) {
      final p = IslandPointIntent.fromPad(dx: entry.value.dx, dy: entry.value.dy, radius: 87, rangeM: 12, elevationDeg: 8);
      expect(p.azimuthDeg, closeTo([0,90,180,-90][entry.key], 1e-8));
      expect(p.distanceM, 12);
    }
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final bridge = SpatialSceneBridge(adapter: adapter);
    final raw = IslandPointIntent.commit(adapter.snapshot()!, const SphericalV1(azimuthDeg: -32, elevationDeg: 8, distanceM: 12));
    final result = bridge.handleMessage(raw);
    expect(result.accepted, isTrue);
    expect(result.engineParams!.distanceM, 10);
    expect(IslandPointIntent.pose(adapter.snapshot()!).distanceM, closeTo(12, 1e-8));
    expect(bridge.handleMessage(raw).reason, 'stale_revision');
    final near = bridge.handleMessage(IslandPointIntent.commit(adapter.snapshot()!, const SphericalV1(azimuthDeg: 90, elevationDeg: 0, distanceM: .2)));
    expect(near.engineParams!.distanceM, .5);
    expect(IslandPointIntent.pose(adapter.snapshot()!).distanceM, closeTo(.2, 1e-8));
  });
  test('mini round trip respects translated and rotated listener', () {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final scene = adapter.snapshot()!;
    scene['listener']['worldPosition'] = {'x': 3.0, 'y': 2.0, 'z': -4.0};
    scene['listener']['orientation'] = {'w': .7071067811865476, 'x': 0.0, 'y': .7071067811865476, 'z': 0.0};
    final intent = jsonDecode(IslandPointIntent.commit(scene, const SphericalV1(azimuthDeg: 90, elevationDeg: 20, distanceM: 2)));
    scene['sources'][0]['worldPosition'] = intent['worldPosition'];
    final pose = IslandPointIntent.pose(scene);
    expect(pose.azimuthDeg, closeTo(90, 1e-8));
    expect(pose.elevationDeg, closeTo(20, 1e-8));
    expect(pose.distanceM, closeTo(2, 1e-8));
  });
  testWidgets('Point pad and elevation submit real bridge intents', (tester) async {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final bridge = SpatialSceneBridge(adapter: adapter);
    final refresh = ValueNotifier(0);
    await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(width: 360, height: 300,
      child: ValueListenableBuilder<int>(valueListenable: refresh, builder: (_, __, ___) => IslandSpatialController(
        sceneSnapshot: () => adapter.snapshot()!,
        onSceneIntent: (raw) {final r = bridge.handleMessage(raw); refresh.value++; return r;}, onClose: () {}))))));
    final rect = tester.getRect(find.byKey(const ValueKey('mini-spatial-pad')));
    await tester.tapAt(rect.topLeft + const Offset(23, 102));
    await tester.pump();
    expect(IslandPointIntent.pose(adapter.snapshot()!).azimuthDeg, closeTo(-90, 1e-8));
    expect(IslandPointIntent.pose(adapter.snapshot()!).distanceM, closeTo(4, 1e-8));
    final slider = tester.widget<Slider>(find.byKey(const ValueKey('mini-elevation')));
    slider.onChanged!(35);
    await tester.pump();
    expect(IslandPointIntent.pose(adapter.snapshot()!).elevationDeg, closeTo(35, 1e-8));
    expect(adapter.appliedRevision, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    refresh.dispose();
  });

  testWidgets('Point mini hides add sounder', (tester) async {
    final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
    final bridge = SpatialSceneBridge(adapter: adapter);
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
                width: 360,
                height: 300,
                child: IslandSpatialController(
                    sceneSnapshot: () => adapter.snapshot()!,
                    onSceneIntent: bridge.handleMessage,
                    onClose: () {})))));
    expect(find.byKey(const ValueKey('mini-add-speaker')), findsNothing);
    expect(find.byKey(const ValueKey('mini-remove-speaker')), findsNothing);
  });

  testWidgets('Stereo mini ignores Point orbit telemetry overlay', (tester) async {
    var layout = ArrayLayout.stereo2();
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 360,
          height: 300,
          child: IslandSpatialController(
            sceneSnapshot: () => <String, dynamic>{},
            playbackTelemetry: const PlaybackTelemetryV1(
              playing: true,
              orbiting: true,
              azimuthDeg: 90,
              elevationDeg: -40,
            ),
            onSceneIntent: (_) => const SceneBridgeResult(),
            arrayLayout: () => layout,
            onArrayChanged: (next) => layout = next,
            onClose: () {},
          ),
        ),
      ),
    ));
    expect(find.text('-30°'), findsWidgets);
    expect(find.text('90°'), findsNothing);
    expect(find.text('-40°'), findsNothing);
  });

  testWidgets('Stereo mini add sounder appends a selectable Mid speaker',
      (tester) async {
    var layout = ArrayLayout.stereo2();
    await tester.pumpWidget(_stereoMini(() => layout, (next) => layout = next));
    expect(find.byKey(const ValueKey('mini-add-speaker')), findsOneWidget);
    expect(find.byKey(const ValueKey('mini-remove-speaker')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mini-add-speaker')));
    await tester.pump();
    expect(layout.speakers.length, 3);
    expect(layout.speakers[2].feed, SpeakerFeed.mid);
    expect(layout.speakers[2].label, '3');
    expect(layout.selectedIndex, 2);
    expect(find.byKey(const ValueKey('mini-speaker-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('mini-speaker-handle-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('mini-remove-speaker')), findsOneWidget);
  });

  testWidgets('Stereo mini cannot remove L/R and hides add at eight speakers',
      (tester) async {
    var layout = ArrayLayout.stereo2()..addSpeaker(azimuthDeg: 0);
    layout.selectedIndex = 0;
    await tester.pumpWidget(_stereoMini(() => layout, (next) => layout = next));
    expect(find.byKey(const ValueKey('mini-remove-speaker')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mini-speaker-2')));
    await tester.pump();
    expect(layout.selectedIndex, 2);
    expect(find.byKey(const ValueKey('mini-remove-speaker')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mini-remove-speaker')));
    await tester.pump();
    expect(layout.speakers.length, 2);
    expect(find.byKey(const ValueKey('mini-speaker-2')), findsNothing);
    expect(find.byKey(const ValueKey('mini-remove-speaker')), findsNothing);

    for (var i = 0; i < 6; i++) {
      layout.addSpeaker();
    }
    await tester.pumpWidget(_stereoMini(() => layout, (_) {}));
    expect(layout.speakers.length, 8);
    expect(find.byKey(const ValueKey('mini-add-speaker')), findsNothing);
  });
}

Widget _stereoMini(
    ArrayLayout Function() layout, ValueChanged<ArrayLayout> onChanged) {
  return MaterialApp(
      home: Center(
          child: SizedBox(
              width: 360,
              height: 300,
              child: StatefulBuilder(
                  builder: (context, setState) => IslandSpatialController(
                      sceneSnapshot: () => <String, dynamic>{},
                      onSceneIntent: (_) => const SceneBridgeResult(),
                      arrayLayout: layout,
                      onArrayChanged: (next) => setState(() => onChanged(next)),
                      onSpeakerSelected: (i) => setState(
                          () => onChanged(layout().copy()..selectedIndex = i)),
                      onClose: () {})))));
}
