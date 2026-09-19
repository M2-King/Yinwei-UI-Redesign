import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/live_transfer.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/state/island_now_playing.dart';
import 'package:yinwei_player/state/window_mode_controller.dart';
import 'package:yinwei_player/widgets/island_bar.dart';
import 'fake_window_chrome.dart';

void main() {
  test('idle resolver never exposes demo metadata, time or progress', () {
    final engine = EngineController();
    final now = IslandNowPlaying.resolve(engine: engine, system: SystemMediaState.empty, now: DateTime.now());
    expect(now.source, IslandMediaSource.idle);
    expect(now.title, '音围 Yinwei');
    expect(now.artist, isEmpty);
    expect(now.album, isEmpty);
    expect(now.playhead, 0);
    expect(now.duration, Duration.zero);
    engine.dispose();
  });
  test('healthy live capture without SMTC metadata is meaningful system audio', () {
    final engine = EngineController();
    final now = IslandNowPlaying.resolve(engine: engine, system: SystemMediaState.empty,
      now: DateTime.now(), liveHrtfHealthy: true, liveHrtfRunning: true);
    expect(now.liveTransfer, isTrue);
    expect(now.title, 'System Audio');
    engine.dispose();
  });
  testWidgets('Dormant, activity, hover, expand and delayed return preserve media', (tester) async {
    final window = WindowModeController(chrome: FakeWindowChrome());
    final engine = EngineController();
    final system = SystemMediaService();
    final live = LiveTransferController();
    addTearDown(() {window.dispose(); engine.dispose(); system.dispose(); live.dispose();});
    await tester.binding.setSurfaceSize(const Size(576, 488));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await window.enterIsland();
    await tester.pumpWidget(MaterialApp(home: AnimatedBuilder(animation: window,
      builder: (_, __) => IslandBar(controller: engine, windowMode: window, systemMedia: system, liveTransfer: live))));
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byKey(const ValueKey('island-play')), findsNothing);
    engine.hasOpenedFile = true;
    engine.playing = true;
    window.observeMediaActivity(true);
    await tester.pump();
    expect(window.interaction, IslandInteraction.collapsed);
    expect(find.byKey(const ValueKey('island-play')), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await mouse.moveTo(const Offset(260, 32));
    await tester.pump();
    expect(window.interaction, IslandInteraction.hover);
    await mouse.moveTo(const Offset(10, 10));
    await tester.pump();
    expect(window.interaction, IslandInteraction.collapsed);
    await tester.tap(find.byKey(const ValueKey('island-capsule')));
    await tester.pump();
    expect(window.interaction, IslandInteraction.expanded);
    expect(find.text('OUTPUT'), findsOneWidget);
    window.observeMediaActivity(false);
    await tester.pump(const Duration(seconds: 3));
    expect(window.dormant, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(window.interaction, IslandInteraction.dormant);
    expect(engine.hasOpenedFile, isTrue);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
  });
}
