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

/// One stable Island container. Only its visible native region changes.
///
/// Coordinate space: Flutter logical pixels. Native Windows converts to
/// physical pixels with `GetDpiForWindow` (dpi / 96). Do not apply extra
/// scale constants in Dart.
abstract final class IslandGeometry {
  static const double width = 576;
  static const double collapsedHeight = 488;
  static const double expandedHeight = 488;
  static const double topInset = 10;

  /// Logical padding from the HWND edge to the visible pill (IslandBar).
  static const double pillInsetX = 90;
  static const double pillInsetY = 8;

  /// Visible pill corner radius. Must match the IslandBar decoration.
  static const double pillRadius = 28;

  static Rect capsule({required bool expanded, bool dormant = false}) {
    final w = expanded
        ? 552.0
        : dormant
            ? 300.0
            : 396.0;
    final h = expanded
        ? 156.0
        : dormant
            ? 46.0
            : 54.0;
    return Rect.fromLTWH((width - w) / 2, pillInsetY, w, h);
  }

  static const miniRect = Rect.fromLTWH(108, 176, 360, 300);

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
    return capsule(expanded: mode.isExpandedIsland).size;
  }

  /// Top-center of [workArea] (logical pixels), with [topInset] from the top.
  static Offset topCenterIn(Rect workArea, Size islandSize) {
    final x = workArea.left +
        ((workArea.width - islandSize.width) / 2).clamp(0.0, double.infinity);
    final y = workArea.top +
        topInset.clamp(0.0,
            (workArea.height - islandSize.height).clamp(0.0, double.infinity));
    return Offset(x, y);
  }
}
