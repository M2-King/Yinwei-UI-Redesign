import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/state/window_mode.dart';
import 'package:yinwei_player/state/window_mode_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/app_rail.dart';
import 'package:yinwei_player/widgets/app_top_bar.dart';
import 'package:yinwei_player/widgets/island_bar.dart';
import 'package:yinwei_player/widgets/now_playing_panel.dart';
import 'package:yinwei_player/widgets/position_sidebar.dart';
import 'package:yinwei_player/widgets/spatial_workspace.dart';

import 'fake_window_chrome.dart';

void main() {
  testWidgets('full window is a spatial workstation, not a three-column player',
      (tester) async {
    final ctrl = EngineController(
      engine: MockEngine(),
      backendLabel: 'Native · spatial_core',
    );
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      ctrl.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: YinweiTheme.dark(),
        home: PlayerScreen(controller: ctrl),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.byType(AppRail), findsOneWidget);
    expect(find.byType(AppTopBar), findsOneWidget);
    expect(find.byType(SpatialWorkspace), findsOneWidget);
    expect(find.byType(PositionSidebar), findsOneWidget);
    expect(find.byType(NowPlayingPanel), findsOneWidget);
    expect(find.text('Spatial'), findsWidgets);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Island'), findsOneWidget);
    expect(find.text('Spatial (Point)'), findsOneWidget);
    expect(find.text('Spatial Player'), findsNothing);
    expect(find.text('SPATIAL WORKSPACE'), findsNothing);
    expect(find.text('灵动岛'), findsNothing);

    final workspace = tester.getRect(find.byType(SpatialWorkspace));
    final transport = tester.getRect(find.byType(NowPlayingPanel));
    final inspector = tester.getRect(find.byType(PositionSidebar));
    final rail = tester.getRect(find.byType(AppRail));

    expect(rail.left, closeTo(0, 0.5));
    expect(workspace.top, lessThan(transport.top));
    expect(transport.bottom, closeTo(900, 0.5));
    expect(workspace.width, greaterThan(inspector.width));
    expect(workspace.height, greaterThan(transport.height * 4));
    expect(find.text('Across the Room'), findsNothing);
    expect(find.text('音围 Yinwei'), findsWidgets);
    expect(find.text('Point Source'), findsOneWidget);
    expect(find.text('Quick Controls'), findsOneWidget);
  });

  testWidgets('narrow window collapses the product rail', (tester) async {
    final ctrl = EngineController(engine: MockEngine());
    await tester.binding.setSurfaceSize(const Size(960, 720));
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

    final rail = tester.getRect(find.byType(AppRail));
    expect(rail.width, YinweiLayout.railCompactWidth);
    expect(find.text('Open'), findsNothing);
    expect(find.byType(NowPlayingPanel), findsOneWidget);
  });

  testWidgets('Island replaces the workstation shell and restores it',
      (tester) async {
    final ctrl = EngineController(engine: MockEngine());
    final chrome = FakeWindowChrome();
    final window = WindowModeController(chrome: chrome);
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      window.dispose();
      ctrl.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(controller: ctrl, windowMode: window),
      ),
    );
    await tester.pump();

    expect(find.byType(SpatialWorkspace), findsOneWidget);
    expect(find.byType(IslandBar), findsNothing);

    await window.enterIsland();
    await tester.pump();
    expect(window.mode, WindowMode.islandCollapsed);
    expect(find.byType(IslandBar), findsOneWidget);
    expect(find.byType(SpatialWorkspace), findsNothing);
    expect(find.byType(AppRail), findsNothing);

    await window.expandIsland();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(window.mode, WindowMode.islandExpanded);
    expect(find.byType(IslandBar), findsOneWidget);

    await window.enterFull();
    await tester.pump();
    expect(window.mode, WindowMode.full);
    expect(find.byType(SpatialWorkspace), findsOneWidget);
    expect(find.byType(IslandBar), findsNothing);
    expect(find.byType(AppRail), findsOneWidget);
    expect(find.byType(PositionSidebar), findsOneWidget);
  });

  testWidgets('transport Original/Spatial does not mutate Array layout',
      (tester) async {
    final ctrl = EngineController(engine: MockEngine());
    await ctrl.applyArrayMode(ArrayMode.stereo2);
    await ctrl.setArray(
      ctrl.array.copy()
        ..selectedIndex = 1
        ..setMatrixLinked(true),
    );
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

    await tester.tap(
      find.descendant(
        of: find.byType(NowPlayingPanel),
        matching: find.text('Original'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(ctrl.mode, PlaybackMode.original);
    expect(ctrl.array.mode, ArrayMode.stereo2);
    expect(ctrl.array.selectedIndex, 1);
    expect(ctrl.array.matrixLinked, isTrue);
  });

  testWidgets('transport Point/2.0 uses applyArrayMode and keeps PlaybackMode',
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
    expect(ctrl.mode, PlaybackMode.spatial);
    expect(ctrl.array.mode, ArrayMode.off);

    await tester.tap(
      find.descendant(
        of: find.byType(NowPlayingPanel),
        matching: find.text('2.0'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(ctrl.array.mode, ArrayMode.stereo2);
    expect(ctrl.mode, PlaybackMode.spatial);
  });

  testWidgets('Island play/pause uses the same EngineController as full window',
      (tester) async {
    final ctrl = EngineController(engine: MockEngine());
    final chrome = FakeWindowChrome();
    final window = WindowModeController(chrome: chrome);
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      window.dispose();
      ctrl.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: PlayerScreen(controller: ctrl, windowMode: window),
      ),
    );
    await tester.pump();

    ctrl.hasOpenedFile = true;
    ctrl.playing = true;
    ctrl.notifyListeners();
    await tester.pump();
    expect(ctrl.playing, isTrue);
    expect(find.byType(NowPlayingPanel), findsOneWidget);

    await window.enterIsland();
    await tester.pump();
    expect(find.byType(IslandBar), findsOneWidget);
    expect(ctrl.playing, isTrue);

    await tester.tap(find.byKey(const ValueKey('island-play')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(ctrl.playing, isFalse);

    await window.enterFull();
    await tester.pump();
    expect(find.byType(NowPlayingPanel), findsOneWidget);
    expect(find.byType(IslandBar), findsNothing);
    expect(ctrl.playing, isFalse);
  });
}
