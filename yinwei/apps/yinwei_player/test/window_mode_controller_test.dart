import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/window_mode.dart';
import 'package:yinwei_player/state/window_mode_controller.dart';

import 'fake_window_chrome.dart';

void main() {
  group('IslandGeometry', () {
    test('fixed two-step heights', () {
      expect(
        IslandGeometry.sizeFor(WindowMode.islandCollapsed),
        const Size(IslandGeometry.width, IslandGeometry.collapsedHeight),
      );
      expect(
        IslandGeometry.sizeFor(WindowMode.islandExpanded),
        const Size(IslandGeometry.width, IslandGeometry.expandedHeight),
      );
      expect(
        IslandGeometry.sizeFor(WindowMode.full).width,
        1440,
      );
    });

    test('pill size matches explicit logical insets', () {
      final collapsed = IslandGeometry.pillSizeFor(WindowMode.islandCollapsed);
      expect(collapsed.width,
          IslandGeometry.width - IslandGeometry.pillInsetX * 2);
      expect(
        collapsed.height,
        IslandGeometry.collapsedHeight - IslandGeometry.pillInsetY * 2,
      );
    });

    test('topCenterIn centers horizontally with top inset', () {
      const work = Rect.fromLTWH(100, 50, 1000, 800);
      const island = Size(420, 64);
      final pos = IslandGeometry.topCenterIn(work, island);
      expect(pos.dx, 100 + (1000 - 420) / 2);
      expect(pos.dy, 50 + IslandGeometry.topInset);
    });

    test('topCenterIn keeps a secondary-monitor work area on that display', () {
      const work = Rect.fromLTWH(1920, 0, 1920, 1080);
      final pos = IslandGeometry.topCenterIn(
        work,
        IslandGeometry.sizeFor(WindowMode.islandCollapsed),
      );
      expect(pos.dx, greaterThanOrEqualTo(1920));
      expect(pos.dx + IslandGeometry.width, lessThanOrEqualTo(3840));
      expect(pos.dy, IslandGeometry.topInset);
    });
  });

  group('WindowModeController', () {
    late FakeWindowChrome chrome;
    late WindowModeController ctrl;

    setUp(() {
      chrome = FakeWindowChrome();
      ctrl = WindowModeController(chrome: chrome);
    });

    tearDown(() => ctrl.dispose());

    test('enterIsland saves full bounds; stays clickable; shapes the pill',
        () async {
      chrome.size = const Size(1400, 800);
      chrome.position = const Offset(40, 60);

      await ctrl.enterIsland();

      expect(ctrl.mode, WindowMode.islandCollapsed);
      expect(chrome.islandApplied, isTrue);
      expect(chrome.toolWindow, isTrue);
      expect(chrome.clickThrough, isFalse);
      expect(ctrl.clickThrough, isFalse);
      expect(ctrl.hitShapeEnabled, isTrue);
      expect(chrome.hitShapeEnabled, isTrue);
      expect(
        chrome.hitShapeWindowSize,
        IslandGeometry.sizeFor(WindowMode.islandCollapsed),
      );
      expect(chrome.hitShapeInsetX, IslandGeometry.pillInsetX);
      expect(chrome.hitShapeInsetY, IslandGeometry.pillInsetY);
      expect(chrome.hitShapeRadius, IslandGeometry.pillRadius);
      expect(chrome.size, IslandGeometry.sizeFor(WindowMode.islandCollapsed));
      expect(chrome.applyIslandCalls, 1);
    });

    test(
        'enterIsland places on the current window work area, not primary origin',
        () async {
      chrome.size = const Size(1400, 800);
      chrome.position = const Offset(2100, 80);
      chrome.workArea = const Rect.fromLTWH(0, 0, 1920, 1080);
      chrome.windowWorkArea = const Rect.fromLTWH(1920, 0, 1920, 1080);

      await ctrl.enterIsland();

      final expected = IslandGeometry.topCenterIn(
        chrome.windowWorkArea!,
        IslandGeometry.sizeFor(WindowMode.islandCollapsed),
      );
      expect(chrome.position, expected);
      expect(chrome.position.dx, greaterThan(1920));
    });

    test('expand and collapse toggle height; never ignore mouse', () async {
      await ctrl.enterIsland();
      await ctrl.expandIsland();
      expect(ctrl.mode, WindowMode.islandExpanded);
      expect(chrome.size.height, IslandGeometry.expandedHeight);
      expect(chrome.clickThrough, isFalse);
      expect(chrome.hitShapeEnabled, isTrue);
      expect(
        chrome.hitShapeWindowSize,
        IslandGeometry.sizeFor(WindowMode.islandExpanded),
      );

      await ctrl.collapseIsland();
      expect(ctrl.mode, WindowMode.islandCollapsed);
      expect(chrome.size.height, IslandGeometry.collapsedHeight);
      expect(chrome.clickThrough, isFalse);
      expect(chrome.hitShapeEnabled, isTrue);
    });

    test('enterFull restores saved size and clears island chrome', () async {
      chrome.size = const Size(1100, 700);
      chrome.position = const Offset(12, 34);
      await ctrl.enterIsland();
      await ctrl.expandIsland();
      await ctrl.enterFull();

      expect(ctrl.mode, WindowMode.full);
      expect(chrome.fullApplied, isTrue);
      expect(chrome.toolWindow, isFalse);
      expect(chrome.clickThrough, isFalse);
      expect(ctrl.hitShapeEnabled, isFalse);
      expect(chrome.hitShapeEnabled, isFalse);
      expect(chrome.size, const Size(1100, 700));
      expect(chrome.position, const Offset(12, 34));
    });

    test('setPillHovered never enables click-through', () async {
      await ctrl.enterIsland();
      expect(chrome.clickThrough, isFalse);
      await ctrl.setPillHovered(false);
      expect(chrome.clickThrough, isFalse);
      await ctrl.setPillHovered(true);
      expect(chrome.clickThrough, isFalse);
    });

    test('idempotent enterIsland while already island', () async {
      await ctrl.enterIsland();
      await ctrl.enterIsland();
      expect(chrome.applyIslandCalls, 1);
    });

    test('idempotent expand/collapse/full requests are no-ops', () async {
      await ctrl.enterIsland();
      await ctrl.expandIsland();
      final islandCalls = chrome.applyIslandCalls;
      await ctrl.expandIsland();
      expect(chrome.applyIslandCalls, islandCalls);

      await ctrl.enterFull();
      final fullCalls = chrome.applyFullCalls;
      await ctrl.enterFull();
      expect(chrome.applyFullCalls, fullCalls);
    });

    test('latest request wins when transitions overlap', () async {
      chrome.applyDelay = const Duration(milliseconds: 20);
      final entering = ctrl.enterIsland();
      final expanding = ctrl.expandIsland();
      await entering;
      await expanding;
      expect(ctrl.mode, WindowMode.islandExpanded);
      expect(ctrl.busy, isFalse);
      expect(chrome.clickThrough, isFalse);
      expect(chrome.hitShapeEnabled, isTrue);
    });

    test('full requested during expand restores full bounds', () async {
      chrome.size = const Size(1280, 800);
      chrome.position = const Offset(90, 40);
      chrome.applyDelay = const Duration(milliseconds: 20);
      final entering = ctrl.enterIsland();
      final expanding = ctrl.expandIsland();
      final full = ctrl.enterFull();
      await entering;
      await expanding;
      await full;
      expect(ctrl.mode, WindowMode.full);
      expect(chrome.fullApplied, isTrue);
      expect(chrome.clickThrough, isFalse);
      expect(chrome.hitShapeEnabled, isFalse);
      expect(chrome.size, const Size(1280, 800));
      expect(chrome.position, const Offset(90, 40));
    });

    test('repeated mode switching restores the original full window', () async {
      chrome.size = const Size(1330, 820);
      chrome.position = const Offset(64, 48);
      for (var i = 0; i < 5; i++) {
        await ctrl.enterIsland();
        await ctrl.expandIsland();
        await ctrl.collapseIsland();
        await ctrl.enterFull();
      }
      expect(ctrl.mode, WindowMode.full);
      expect(chrome.size, const Size(1330, 820));
      expect(chrome.position, const Offset(64, 48));
      expect(chrome.toolWindow, isFalse);
      expect(chrome.clickThrough, isFalse);
      expect(chrome.hitShapeEnabled, isFalse);
    });

    test('window mode transitions do not mutate scene revision', () async {
      final adapter = SpatialRuntimeAdapter()..bootstrap(SpatialParams());
      final revision = adapter.appliedRevision;
      await ctrl.enterIsland();
      await ctrl.expandIsland();
      await ctrl.collapseIsland();
      await ctrl.enterFull();
      expect(adapter.appliedRevision, revision);
      expect(adapter.snapshot()?['revision'], revision);
    });
  });
}
