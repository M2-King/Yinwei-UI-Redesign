import 'dart:ui';

import 'package:yinwei_player/state/window_chrome.dart';

/// In-memory chrome for unit tests.
class FakeWindowChrome implements WindowChrome {
  Size size = const Size(1440, 900);
  Offset position = const Offset(80, 80);
  Offset cursor = const Offset(100, 100);
  Rect workArea = const Rect.fromLTWH(0, 0, 1920, 1080);
  Rect? windowWorkArea;
  bool islandApplied = false;
  bool fullApplied = false;
  bool clickThrough = false;
  bool toolWindow = false;
  bool hitShapeEnabled = false;
  Size hitShapeWindowSize = Size.zero;
  double hitShapeInsetX = 0;
  double hitShapeInsetY = 0;
  double hitShapeRadius = 0;
  int applyIslandCalls = 0;
  int applyFullCalls = 0;
  int setClickThroughCalls = 0;
  int setHitShapeCalls = 0;
  Duration applyDelay = Duration.zero;

  @override
  Future<Size> currentSize() async => size;

  @override
  Future<Offset> currentPosition() async => position;

  @override
  Future<Offset> cursorScreenPoint() async => cursor;

  @override
  Future<Rect> primaryWorkArea() async => workArea;

  @override
  Future<Rect> workAreaForCurrentWindow() async => windowWorkArea ?? workArea;

  @override
  Future<void> applyFull({
    required Size size,
    required Offset position,
  }) async {
    if (applyDelay > Duration.zero) {
      await Future<void>.delayed(applyDelay);
    }
    this.size = size;
    this.position = position;
    islandApplied = false;
    fullApplied = true;
    toolWindow = false;
    clickThrough = false;
    applyFullCalls++;
  }

  @override
  Future<void> applyIsland({
    required Size size,
    required Offset position,
  }) async {
    if (applyDelay > Duration.zero) {
      await Future<void>.delayed(applyDelay);
    }
    this.size = size;
    this.position = position;
    islandApplied = true;
    fullApplied = false;
    toolWindow = true;
    clickThrough = false;
    applyIslandCalls++;
  }

  @override
  Future<void> setClickThrough(bool ignore) async {
    clickThrough = ignore;
    setClickThroughCalls++;
  }

  @override
  Future<void> setToolWindow(bool enable) async {
    toolWindow = enable;
  }

  @override
  Future<void> setIslandHitShape({
    required bool enabled,
    Size windowSize = Size.zero,
    double insetX = 0,
    double insetY = 0,
    double radius = 0,
  }) async {
    hitShapeEnabled = enabled;
    hitShapeWindowSize = windowSize;
    hitShapeInsetX = insetX;
    hitShapeInsetY = insetY;
    hitShapeRadius = radius;
    setHitShapeCalls++;
  }
}
