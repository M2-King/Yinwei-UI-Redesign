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
///
/// Coordinate space: Flutter logical pixels. Native Windows converts to
/// physical pixels with `GetDpiForWindow` (dpi / 96). Do not apply extra
/// scale constants in Dart.
abstract final class IslandGeometry {
  static const double width = 420;
  static const double collapsedHeight = 64;
  static const double expandedHeight = 120;
  static const double topInset = 10;

  /// Logical padding from the HWND edge to the visible pill (IslandBar).
  static const double pillInsetX = 8;
  static const double pillInsetY = 6;

  /// Visible pill corner radius. Must match the IslandBar decoration.
  static const double pillRadius = 22;

  static Size sizeFor(WindowMode mode) {
    switch (mode) {
      case WindowMode.full:
        return const Size(1440, 900);
      case WindowMode.islandCollapsed:
        return const Size(width, collapsedHeight);
      case WindowMode.islandExpanded:
        return const Size(width, expandedHeight);
    }
  }

  static Size pillSizeFor(WindowMode mode) {
    final size = sizeFor(mode);
    return Size(
      size.width - pillInsetX * 2,
      size.height - pillInsetY * 2,
    );
  }

  /// Top-center of [workArea] (logical pixels), with [topInset] from the top.
  static Offset topCenterIn(Rect workArea, Size islandSize) {
    final x = workArea.left + (workArea.width - islandSize.width) / 2;
    final y = workArea.top + topInset;
    return Offset(x, y);
  }
}
