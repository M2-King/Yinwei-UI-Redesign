import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// OS window chrome ops — injectable so unit tests skip real HWND calls.
abstract class WindowChrome {
  Future<Size> currentSize();
  Future<Offset> currentPosition();
  Future<Offset> cursorScreenPoint();
  Future<Rect> primaryWorkArea();
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
}

/// Production chrome via [window_manager] + thin `yinwei/window_chrome` channel.
class WindowManagerChrome implements WindowChrome {
  static const _channel = MethodChannel('yinwei/window_chrome');

  @override
  Future<Size> currentSize() => windowManager.getSize();

  @override
  Future<Offset> currentPosition() => windowManager.getPosition();

  @override
  Future<Offset> cursorScreenPoint() =>
      screenRetriever.getCursorScreenPoint();

  @override
  Future<Rect> primaryWorkArea() async {
    final display = await screenRetriever.getPrimaryDisplay();
    final va = display.visibleSize;
    final vo = display.visiblePosition;
    if (va != null && vo != null) {
      return Rect.fromLTWH(vo.dx, vo.dy, va.width, va.height);
    }
    final size = display.size;
    return Rect.fromLTWH(0, 0, size.width, size.height);
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
    await windowManager.setMinimumSize(const Size(800, 500));
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
    // Always accept clicks while applying chrome — hit-probe may re-enable
    // click-through only when the cursor is outside the pill.
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
}
