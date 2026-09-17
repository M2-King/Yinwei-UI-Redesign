import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:yinwei_player/state/window_chrome.dart';
import 'package:yinwei_player/state/window_mode.dart';

/// Owns Full ↔ Island transitions and fixed two-step island sizing.
///
/// Click targeting is OS hit-testing via a shaped HWND (`SetWindowRgn`),
/// not `WS_EX_TRANSPARENT` polling. Flutter keeps receiving mouse events
/// inside the visible pill; clicks outside the region pass to windows below.
class WindowModeController extends ChangeNotifier {
  WindowModeController({WindowChrome? chrome})
      : _chrome = chrome ?? WindowManagerChrome();

  final WindowChrome _chrome;

  WindowMode mode = WindowMode.full;
  Size _savedFullSize = const Size(1440, 900);
  Offset _savedFullPosition = const Offset(80, 80);
  bool _busy = false;
  bool _clickThrough = false;
  bool _hitShapeEnabled = false;
  WindowMode? _queued;
  Completer<void>? _idle;

  bool get isIsland => mode.isIsland;
  bool get isExpandedIsland => mode.isExpandedIsland;
  bool get busy => _busy;
  bool get clickThrough => _clickThrough;
  bool get hitShapeEnabled => _hitShapeEnabled;

  Future<void> enterIsland() async {
    if (mode.isIsland) return;
    await _enqueue(WindowMode.islandCollapsed);
  }

  Future<void> expandIsland() async {
    if (mode == WindowMode.full && !_busy && _queued == null) return;
    await _enqueue(WindowMode.islandExpanded);
  }

  Future<void> collapseIsland() async {
    if (mode == WindowMode.full && !_busy && _queued == null) return;
    await _enqueue(WindowMode.islandCollapsed);
  }

  Future<void> enterFull() async {
    if (mode == WindowMode.full && !_busy && _queued == null) return;
    await _enqueue(WindowMode.full);
  }

  /// Fail-open helper. Hover must never enable HWND click-through; shaped
  /// hit-testing is authoritative on Windows.
  Future<void> setPillHovered(bool hovered) async {
    if (hovered || mode != WindowMode.islandCollapsed) {
      await _setClickThrough(false);
    }
  }

  Future<void> _enqueue(WindowMode target) async {
    if (mode == target && _queued == null && !_busy) {
      return;
    }
    _queued = target;
    _idle ??= Completer<void>();
    final wait = _idle!.future;
    if (!_busy) {
      await _drain();
    }
    await wait;
  }

  Future<void> _drain() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      while (_queued != null) {
        final target = _queued!;
        _queued = null;
        if (target == mode) {
          continue;
        }
        await _apply(target);
      }
    } finally {
      final done = _idle;
      _idle = null;
      _busy = false;
      notifyListeners();
      if (done != null && !done.isCompleted) {
        done.complete();
      }
    }
    if (_queued != null) {
      await _drain();
    }
  }

  Future<void> _apply(WindowMode target) async {
    if (target == WindowMode.full) {
      // Restore HWND first while Island UI is still showing, then reveal the
      // workstation. Showing SpatialWorkspace inside a 64px HWND crashes
      // WebView2 / flutter_windows.dll.
      await _chrome.setIslandHitShape(enabled: false);
      _hitShapeEnabled = false;
      await _setClickThrough(false);
      await _chrome.applyFull(
        size: _savedFullSize,
        position: _savedFullPosition,
      );
      mode = WindowMode.full;
      notifyListeners();
      return;
    }

    final leavingFull = !mode.isIsland;
    if (leavingFull) {
      _savedFullSize = await _chrome.currentSize();
      _savedFullPosition = await _chrome.currentPosition();
    }

    mode = target;
    notifyListeners();
    if (leavingFull) {
      await _yieldForViewTeardown();
    }

    final size = IslandGeometry.sizeFor(mode);
    try {
      final work = await _chrome.workAreaForCurrentWindow();
      final pos = IslandGeometry.topCenterIn(work, size);
      await _chrome.applyIsland(size: size, position: pos);
      await _setClickThrough(false);
      if (_chrome is WindowManagerChrome) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      await _chrome.setIslandHitShape(
        enabled: true,
        windowSize: size,
        insetX: IslandGeometry.pillInsetX,
        insetY: IslandGeometry.pillInsetY,
        radius: IslandGeometry.pillRadius,
      );
      _hitShapeEnabled = true;
    } catch (e, st) {
      debugPrint('[WindowMode] island apply failed: $e\n$st');
      _hitShapeEnabled = false;
      mode = WindowMode.full;
      notifyListeners();
      await _setClickThrough(false);
      await _chrome.setIslandHitShape(enabled: false);
      await _chrome.applyFull(
        size: _savedFullSize,
        position: _savedFullPosition,
      );
    }
  }

  /// Let Flutter hide/stop the WebView compositor before HWND chrome changes.
  Future<void> _yieldForViewTeardown() async {
    if (_chrome is! WindowManagerChrome) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  Future<void> _setClickThrough(bool ignore) async {
    if (_clickThrough == ignore) return;
    _clickThrough = ignore;
    await _chrome.setClickThrough(ignore);
  }

  @override
  void dispose() {
    final done = _idle;
    _idle = null;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
    super.dispose();
  }
}
