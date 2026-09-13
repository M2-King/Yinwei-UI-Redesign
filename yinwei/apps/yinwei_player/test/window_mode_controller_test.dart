import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
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
        1280,
      );
    });

    test('topCenterIn centers horizontally with top inset', () {
      const work = Rect.fromLTWH(100, 50, 1000, 800);
      const island = Size(420, 64);
      final pos = IslandGeometry.topCenterIn(work, island);
      expect(pos.dx, 100 + (1000 - 420) / 2);
      expect(pos.dy, 50 + IslandGeometry.topInset);
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

    test('enterIsland saves full bounds; stays clickable first', () async {
      chrome.size = const Size(1400, 800);
      chrome.position = const Offset(40, 60);

      await ctrl.enterIsland();

      expect(ctrl.mode, WindowMode.islandCollapsed);
      expect(chrome.islandApplied, isTrue);
      expect(chrome.toolWindow, isTrue);
      // Must NOT start with permanent click-through (that deadlocks Flutter input).
      expect(chrome.clickThrough, isFalse);
      expect(chrome.size, IslandGeometry.sizeFor(WindowMode.islandCollapsed));
      expect(chrome.applyIslandCalls, 1);
    });

    test('expand and collapse toggle height; expanded never ignores mouse',
        () async {
      await ctrl.enterIsland();
      await ctrl.expandIsland();
      expect(ctrl.mode, WindowMode.islandExpanded);
      expect(chrome.size.height, IslandGeometry.expandedHeight);
      expect(chrome.clickThrough, isFalse);

      await ctrl.collapseIsland();
      expect(ctrl.mode, WindowMode.islandCollapsed);
      expect(chrome.size.height, IslandGeometry.collapsedHeight);
      expect(chrome.clickThrough, isFalse);
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
      expect(chrome.size, const Size(1100, 700));
      expect(chrome.position, const Offset(12, 34));
    });

    test('setPillHovered toggles click-through when collapsed', () async {
      await ctrl.enterIsland();
      expect(chrome.clickThrough, isFalse);
      await ctrl.setPillHovered(false);
      expect(chrome.clickThrough, isTrue);
      await ctrl.setPillHovered(true);
      expect(chrome.clickThrough, isFalse);
    });

    test('idempotent enterIsland while already island', () async {
      await ctrl.enterIsland();
      await ctrl.enterIsland();
      expect(chrome.applyIslandCalls, 1);
    });
  });
}
