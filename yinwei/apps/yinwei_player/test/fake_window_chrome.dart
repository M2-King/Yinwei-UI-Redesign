import 'dart:ui';

import 'package:yinwei_player/state/window_chrome.dart';

/// In-memory chrome for unit tests.
class FakeWindowChrome implements WindowChrome {
  Size size = const Size(1280, 720);
  Offset position = const Offset(80, 80);
  Offset cursor = const Offset(100, 100);
  Rect workArea = const Rect.fromLTWH(0, 0, 1920, 1080);
  bool islandApplied = false;
  bool fullApplied = false;
  bool clickThrough = false;
  bool toolWindow = false;
  int applyIslandCalls = 0;
  int applyFullCalls = 0;

  @override
  Future<Size> currentSize() async => size;

  @override
  Future<Offset> currentPosition() async => position;

  @override
  Future<Offset> cursorScreenPoint() async => cursor;

  @override
  Future<Rect> primaryWorkArea() async => workArea;

  @override
  Future<void> applyFull({
    required Size size,
    required Offset position,
  }) async {
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
  }

  @override
  Future<void> setToolWindow(bool enable) async {
    toolWindow = enable;
  }
}
