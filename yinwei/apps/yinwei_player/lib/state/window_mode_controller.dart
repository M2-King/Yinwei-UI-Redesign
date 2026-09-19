import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:yinwei_player/state/window_chrome.dart';
import 'package:yinwei_player/state/window_mode.dart';

enum IslandInteraction { dormant, collapsed, hover, expanded, mini }

/// Presentation only: owns no media, Point, or Array state.
/// A serialized queue owns native operations; disposal invalidates continuations.
class WindowModeController extends ChangeNotifier {
  WindowModeController({
    WindowChrome? chrome,
    this.mode = WindowMode.full,
  }) : _chrome = chrome ?? WindowManagerChrome();

  final WindowChrome _chrome;
  WindowMode mode;
  Size _savedFullSize = const Size(1440, 900);
  Offset _savedFullPosition = const Offset(80, 80);
  bool _busy = false;
  bool _disposed = false;
  bool _hitShapeEnabled = false;
  bool _nativeIsland = false;
  bool _hovered = false;
  bool _dormant = true;
  bool _mediaActive = false;
  bool _mini = false;
  bool _dirtyRegion = false;
  double _scale = 1;
  WindowMode? _queued;
  Completer<void>? _idle;
  Timer? _dormantTimer;
  String? lastError;

  bool get isIsland => mode.isIsland;
  bool get isExpandedIsland => mode.isExpandedIsland;
  bool get busy => _busy;
  bool get clickThrough => false;
  bool get hitShapeEnabled => _hitShapeEnabled;
  bool get miniOpen => _mini;
  bool get dormant => _dormant;
  double get contentScale => _scale;
  IslandInteraction get interaction => _mini && isExpandedIsland
      ? IslandInteraction.mini
      : isExpandedIsland
          ? IslandInteraction.expanded
          : _dormant
              ? IslandInteraction.dormant
              : _hovered
                  ? IslandInteraction.hover
                  : IslandInteraction.collapsed;

  /// Paused media remains available in Expanded, but settles to a quiet capsule.
  void observeMediaActivity(bool active) {
    if (_disposed) return;
    _mediaActive = active;
    if (active) {
      _dormantTimer?.cancel();
      _dormantTimer = null;
      if (!_dormant) return;
      _dormant = false;
      _presentationChanged();
    } else if (!_dormant && !isIsland) {
      _dormant = true;
    } else if (!_dormant && _dormantTimer == null) {
      _dormantTimer = Timer(const Duration(seconds: 4), () {
        _dormantTimer = null;
        if (_disposed) return;
        _dormant = true;
        _presentationChanged();
        if (isIsland) unawaited(collapseIsland());
      });
    }
  }

  Future<void> enterIsland() => _enqueue(WindowMode.islandCollapsed);
  Future<void> expandIsland() async {
    if (mode == WindowMode.full && !_busy) return;
    await _enqueue(WindowMode.islandExpanded);
  }

  Future<void> collapseIsland() async {
    if (mode == WindowMode.full && !_busy) return;
    _mini = false;
    await _enqueue(WindowMode.islandCollapsed);
  }

  Future<void> enterFull() => _enqueue(WindowMode.full);

  void setMiniOpen(bool open) {
    if (_disposed || !isExpandedIsland || _mini == open) return;
    _mini = open;
    _presentationChanged();
  }

  Future<void> setPillHovered(bool hovered) async {
    if (_disposed || _hovered == hovered) return;
    _hovered = hovered;
    // Hover only changes paint, never HWND geometry or region.
    notifyListeners();
  }

  void _presentationChanged() {
    if (_disposed) return;
    _dirtyRegion = true;
    notifyListeners();
    if (!_busy && isIsland) unawaited(_drain());
  }

  Future<void> _enqueue(WindowMode target) async {
    if (_disposed) return;
    if (mode == target && !_busy && !_dirtyRegion) {
      if (!target.isIsland || _nativeIsland) return;
    }
    _queued = target;
    _idle ??= Completer<void>();
    final wait = _idle!.future;
    if (!_busy) unawaited(_drain());
    await wait;
  }

  Future<void> _frame() async {
    if (_chrome is WindowManagerChrome) {
      // Wait for Flutter to lay out the hidden workstation / new capsule.
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  List<RRect> get visibleRegions => [
        RRect.fromRectAndRadius(
          IslandGeometry.capsule(expanded: isExpandedIsland, dormant: _dormant),
          const Radius.circular(IslandGeometry.pillRadius),
        ),
        if (_mini && isExpandedIsland)
          RRect.fromRectAndRadius(
              IslandGeometry.miniRect, const Radius.circular(24)),
      ];

  Future<void> _shape() async {
    if (_disposed || !isIsland) return;
    await _chrome.setIslandHitShape(
      enabled: true,
      windowSize: IslandGeometry.sizeFor(mode) * _scale,
      insetX: IslandGeometry.pillInsetX,
      insetY: IslandGeometry.pillInsetY,
      radius: IslandGeometry.pillRadius,
      regions: visibleRegions
          .map((r) => RRect.fromRectAndRadius(
                Rect.fromLTRB(r.left * _scale, r.top * _scale, r.right * _scale,
                    r.bottom * _scale),
                Radius.circular(r.tlRadiusX * _scale),
              ))
          .toList(),
    );
    if (!_disposed) _hitShapeEnabled = true;
  }

  Future<void> _drain() async {
    if (_busy || _disposed) return;
    _busy = true;
    notifyListeners();
    try {
      while (!_disposed && (_queued != null || _dirtyRegion)) {
        final target = _queued;
        _queued = null;
        _dirtyRegion = false;
        if (target != null &&
            (target != mode || (target.isIsland && !_nativeIsland))) {
          await _apply(target);
        }
        if (_disposed) break;
        if (isIsland) {
          await _frame();
          if (_disposed) break;
          await _shape();
        }
      }
    } catch (e, st) {
      lastError = '$e';
      debugPrint('[WindowMode] transition failed: $e\n$st');
      if (!_disposed) {
        _queued = null;
        _dirtyRegion = false;
        try {
          await _chrome.setIslandHitShape(enabled: false);
          if (!_disposed) {
            await _chrome.applyFull(
                size: _savedFullSize, position: _savedFullPosition);
          }
          if (!_disposed) {
            mode = WindowMode.full;
            _nativeIsland = false;
            _hitShapeEnabled = false;
          }
        } catch (restoreError) {
          lastError = '$e; restore failed: $restoreError';
        }
      }
    } finally {
      _busy = false;
      final done = _idle;
      _idle = null;
      if (done != null && !done.isCompleted) done.complete();
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _apply(WindowMode target) async {
    if (target == WindowMode.full) {
      await _chrome.setIslandHitShape(enabled: false);
      if (_disposed) return;
      _hitShapeEnabled = false;
      await _chrome.applyFull(
          size: _savedFullSize, position: _savedFullPosition);
      if (_disposed) return;
      _nativeIsland = false;
      _dormantTimer?.cancel();
      _dormantTimer = null;
      _dormant = !_mediaActive;
      _mini = false;
      mode = target;
      notifyListeners();
      return;
    }
    if (!_nativeIsland) {
      _savedFullSize = await _chrome.currentSize();
      if (_disposed) return;
      _savedFullPosition = await _chrome.currentPosition();
      if (_disposed) return;
      final work = await _chrome.workAreaForCurrentWindow();
      if (_disposed) return;
      final base = IslandGeometry.sizeFor(target);
      _scale = (work.width / base.width).clamp(0.1, 1.0);
      _scale = ((work.height - IslandGeometry.topInset) / base.height)
          .clamp(0.1, _scale);
      mode = target;
      notifyListeners();
      await _frame();
      if (_disposed) return;
      // Install the region before changing bounds; native DPI/size messages
      // refresh it. There is no frame with a transparent blocking rectangle.
      await _shape();
      if (_disposed) return;
      final size = base * _scale;
      await _chrome.applyIsland(
          size: size, position: IslandGeometry.topCenterIn(work, size));
      if (_disposed) return;
      _nativeIsland = true;
    } else {
      mode = target;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _queued = null;
    _dormantTimer?.cancel();
    _chrome.cancelPendingOperations();
    final done = _idle;
    _idle = null;
    if (done != null && !done.isCompleted) done.complete();
    super.dispose();
  }
}
