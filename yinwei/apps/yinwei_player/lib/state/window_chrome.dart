import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// OS window chrome ops — injectable so unit tests skip real HWND calls.
///
/// Coordinate policy (Windows):
/// - Dart passes Flutter logical pixels.
/// - `window_manager` converts bounds with the Flutter view devicePixelRatio.
/// - `workAreaForCurrentWindow` / `setIslandHitShape` convert with the HWND
///   DPI (`GetDpiForWindow`, dpi/96) so Island placement and hit-testing use
///   the same scale as the window's current display.
abstract class WindowChrome {
  Future<Size> currentSize();
  Future<Offset> currentPosition();
  Future<Offset> cursorScreenPoint();
  Future<Rect> primaryWorkArea();
  Future<Rect> workAreaForCurrentWindow();
  Future<void> applyFull({
    required Size size,
    required Offset position,
  });
  Future<void> applyIsland({
    required Size size,
    required Offset position,
  });
  Future<void> setClickThrough(bool ignore);
  Future<void> setToolWindow(bool enable);
  Future<void> setIslandHitShape({
    required bool enabled,
    Size windowSize = Size.zero,
    double insetX = 0,
    double insetY = 0,
    double radius = 0,
  });
}

/// Production chrome via [window_manager] + thin `yinwei/window_chrome` channel.
class WindowManagerChrome implements WindowChrome {
  static const _channel = MethodChannel('yinwei/window_chrome');

  @override
  Future<Size> currentSize() => windowManager.getSize();

  @override
  Future<Offset> currentPosition() => windowManager.getPosition();

  @override
  Future<Offset> cursorScreenPoint() => screenRetriever.getCursorScreenPoint();

  @override
  Future<Rect> primaryWorkArea() async {
    final display = await screenRetriever.getPrimaryDisplay();
    return _visibleRectOf(display) ??
        Rect.fromLTWH(0, 0, display.size.width, display.size.height);
  }

  @override
  Future<Rect> workAreaForCurrentWindow() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('getWorkAreaForWindow');
      final rect = _rectFromChannel(raw);
      if (rect != null) {
        return rect;
      }
    } on MissingPluginException {
      // Runner channel absent in tests / non-Windows hosts.
    } catch (_) {
      // Fall through to display matching.
    }
    return _workAreaFromDisplays();
  }

  @override
  Future<void> applyFull({
    required Size size,
    required Offset position,
  }) async {
    await windowManager.setIgnoreMouseEvents(false);
    await setToolWindow(false);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    // Restores frame after setAsFrameless (API is one-way).
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setHasShadow(true);
    await windowManager.setResizable(true);
    await windowManager.setBackgroundColor(const Color(0xFF0B0B0D));
    await windowManager.setMinimumSize(const Size(1024, 640));
    await windowManager.setMaximumSize(const Size(10000, 10000));
    await windowManager.setSize(size);
    await windowManager.setPosition(position);
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> applyIsland({
    required Size size,
    required Offset position,
  }) async {
    // Island click targeting uses SetWindowRgn, not WS_EX_TRANSPARENT.
    await windowManager.setIgnoreMouseEvents(false);
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(false);
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setBackgroundColor(const Color(0x00000000));
    await windowManager.setMinimumSize(size);
    await windowManager.setMaximumSize(size);
    await setToolWindow(true);
    await windowManager.setSize(size);
    await windowManager.setPosition(position);
    await windowManager.show();
  }

  @override
  Future<void> setClickThrough(bool ignore) async {
    await windowManager.setIgnoreMouseEvents(ignore, forward: true);
  }

  @override
  Future<void> setToolWindow(bool enable) async {
    try {
      await _channel.invokeMethod<void>('setToolWindow', enable);
    } on MissingPluginException {
      // Runner channel absent in tests / non-Windows hosts.
    }
  }

  @override
  Future<void> setIslandHitShape({
    required bool enabled,
    Size windowSize = Size.zero,
    double insetX = 0,
    double insetY = 0,
    double radius = 0,
  }) async {
    try {
      await _channel.invokeMethod<void>('setIslandHitShape', <String, dynamic>{
        'enabled': enabled,
        'width': windowSize.width,
        'height': windowSize.height,
        'insetX': insetX,
        'insetY': insetY,
        'radius': radius,
      });
    } on MissingPluginException {
      // Runner channel absent in tests / non-Windows hosts.
    }
  }

  Future<Rect> _workAreaFromDisplays() async {
    try {
      final pos = await currentPosition();
      final size = await currentSize();
      final center = Offset(pos.dx + size.width / 2, pos.dy + size.height / 2);
      final displays = await screenRetriever.getAllDisplays();
      for (final display in displays) {
        final rect = _visibleRectOf(display);
        if (rect != null && rect.contains(center)) {
          return rect;
        }
      }
    } catch (_) {
      // Fall through to primary.
    }
    return primaryWorkArea();
  }

  static Rect? _visibleRectOf(Display display) {
    final va = display.visibleSize;
    final vo = display.visiblePosition;
    if (va == null || vo == null) {
      return null;
    }
    return Rect.fromLTWH(vo.dx, vo.dy, va.width, va.height);
  }

  static Rect? _rectFromChannel(dynamic raw) {
    if (raw is! Map) {
      return null;
    }
    double? n(String key) {
      final value = raw[key];
      if (value is num) {
        return value.toDouble();
      }
      return null;
    }

    final left = n('left');
    final top = n('top');
    final width = n('width');
    final height = n('height');
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    return Rect.fromLTWH(left, top, width, height);
  }
}
