import 'dart:ui';

/// Dual-Mode shell: full desktop player vs floating island pill.
enum WindowMode {
  full,
  islandCollapsed,
  islandExpanded,
}

extension WindowModeX on WindowMode {
  bool get isIsland => this != WindowMode.full;
  bool get isExpandedIsland => this == WindowMode.islandExpanded;
}

/// Fixed island geometry — two height steps only (no per-frame HWND animation).
abstract final class IslandGeometry {
  static const double width = 420;
  static const double collapsedHeight = 64;
  static const double expandedHeight = 120;
  static const double topInset = 10;

  static Size sizeFor(WindowMode mode) {
    switch (mode) {
      case WindowMode.full:
        return const Size(1280, 720);
      case WindowMode.islandCollapsed:
        return const Size(width, collapsedHeight);
      case WindowMode.islandExpanded:
        return const Size(width, expandedHeight);
    }
  }

  /// Top-center of [workArea] (logical pixels), with [topInset] from the top.
  static Offset topCenterIn(Rect workArea, Size islandSize) {
    final x = workArea.left + (workArea.width - islandSize.width) / 2;
    final y = workArea.top + topInset;
    return Offset(x, y);
  }
}
