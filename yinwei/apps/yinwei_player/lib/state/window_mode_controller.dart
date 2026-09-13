import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:yinwei_player/state/window_chrome.dart';
import 'package:yinwei_player/state/window_mode.dart';

/// Owns Full ↔ Island transitions and fixed two-step island sizing.
///
/// Click-through must NOT be left on permanently — Flutter never receives
/// MouseRegion events while the HWND ignores input. Collapsed mode uses a
/// global cursor probe (screen_retriever) to toggle ignore only when the
/// pointer is outside the pill hitbox.
class WindowModeController extends ChangeNotifier {
  WindowModeController({WindowChrome? chrome})
      : _chrome = chrome ?? WindowManagerChrome();

  final WindowChrome _chrome;

  WindowMode mode = WindowMode.full;
  Size _savedFullSize = const Size(1280, 720);
  Offset _savedFullPosition = const Offset(80, 80);
  bool _busy = false;
  bool _clickThrough = false;
  bool _pillHot = true;
  Timer? _hitProbe;

  bool get isIsland => mode.isIsland;
  bool get isExpandedIsland => mode.isExpandedIsland;
  bool get busy => _busy;
  bool get clickThrough => _clickThrough;

  Future<void> enterIsland() async {
    if (mode.isIsland || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      _savedFullSize = await _chrome.currentSize();
      _savedFullPosition = await _chrome.currentPosition();
      mode = WindowMode.islandCollapsed;
      final size = IslandGeometry.sizeFor(mode);
      final work = await _chrome.primaryWorkArea();
      final pos = IslandGeometry.topCenterIn(work, size);
      await _chrome.applyIsland(size: size, position: pos);
      // Interactive first — probe enables pass-through only off-pill.
      await _setClickThrough(false);
      _pillHot = true;
      _startHitProbe();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> expandIsland() async {
    if (mode != WindowMode.islandCollapsed || _busy) return;
    _stopHitProbe();
    await _setIslandStep(WindowMode.islandExpanded);
  }

  Future<void> collapseIsland() async {
    if (mode != WindowMode.islandExpanded || _busy) return;
    await _setIslandStep(WindowMode.islandCollapsed);
    _pillHot = true;
    await _setClickThrough(false);
    _startHitProbe();
  }

  Future<void> enterFull() async {
    if (mode == WindowMode.full || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      _stopHitProbe();
      mode = WindowMode.full;
      await _setClickThrough(false);
      await _chrome.applyFull(
        size: _savedFullSize,
        position: _savedFullPosition,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Kept for IslandBar MouseRegion — probe is authoritative on Windows.
  Future<void> setPillHovered(bool hovered) async {
    if (mode != WindowMode.islandCollapsed) {
      await _setClickThrough(false);
      return;
    }
    _pillHot = hovered;
    await _setClickThrough(!hovered);
  }

  Future<void> _setIslandStep(WindowMode next) async {
    _busy = true;
    notifyListeners();
    try {
      mode = next;
      final size = IslandGeometry.sizeFor(mode);
      final work = await _chrome.primaryWorkArea();
      final pos = IslandGeometry.topCenterIn(work, size);
      await _chrome.applyIsland(size: size, position: pos);
      await _setClickThrough(false);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _startHitProbe() {
    _hitProbe?.cancel();
    _hitProbe = Timer.periodic(const Duration(milliseconds: 40), (_) {
      unawaited(_probeCursor());
    });
  }

  void _stopHitProbe() {
    _hitProbe?.cancel();
    _hitProbe = null;
  }

  Future<void> _probeCursor() async {
    if (mode != WindowMode.islandCollapsed || _busy) return;
    try {
      final cursor = await _chrome.cursorScreenPoint();
      final origin = await _chrome.currentPosition();
      final size = await _chrome.currentSize();
      // Match IslandBar padding (~8 logical px inset).
      final pill = Rect.fromLTWH(
        origin.dx + 8,
        origin.dy + 6,
        size.width - 16,
        size.height - 12,
      ).inflate(4);
      final over = pill.contains(cursor);
      if (over == _pillHot && _clickThrough == !over) return;
      _pillHot = over;
      await _setClickThrough(!over);
    } catch (_) {
      // Fail open: keep receiving clicks.
      await _setClickThrough(false);
    }
  }

  Future<void> _setClickThrough(bool ignore) async {
    if (_clickThrough == ignore) return;
    _clickThrough = ignore;
    await _chrome.setClickThrough(ignore);
  }

  @override
  void dispose() {
    _stopHitProbe();
    super.dispose();
  }
}
