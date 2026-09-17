import 'package:flutter/material.dart';

/// Apple-dark tokens — calm instrument, not neon HUD.
abstract final class YinweiColors {
  static const background = Color(0xFF0B0B0D);
  static const panel = Color(0xFF121214);
  static const panelElevated = Color(0xFF1A1A1C);
  static const well = Color(0xFF161618);
  static const shellRail = Color(0xFF101012);
  static const inspectorRail = Color(0xF0111113);
  static const inspectorCardTop = Color(0xFF1F1F23);
  static const inspectorCard = Color(0xFF17171A);
  static const valueWell = Color(0xFF101012);
  static const hairline = Color(0x18FFFFFF);
  static const hairlineStrong = Color(0x28FFFFFF);
  static const accent = Color(0xFF0A84FF);
  static const textPrimary = Color(0xFFF5F5F7);
  static const textSecondary = Color(0xFF8E8E93);
  static const textTertiary = Color(0xFF636366);
  static const success = Color(0xFF30D158);
  static const islandPill = Color(0xF0141416);
  static const islandBorder = Color(0x28FFFFFF);
  static const islandRadius = 22.0;
}

/// Product-shell metrics. Visual composition only — not engine/scene state.
abstract final class YinweiLayout {
  static const railWidth = 188.0;
  static const railCompactWidth = 64.0;
  static const topBarHeight = 48.0;
  static const transportHeight = 56.0;
  static const workspaceRadius = 12.0;
  static const shellGutter = 14.0;
  static const wideBreakpoint = 1180.0;
  static const compactRailBreakpoint = 980.0;
}

abstract final class YinweiTheme {
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      surface: YinweiColors.background,
      primary: YinweiColors.accent,
      onPrimary: Colors.white,
      secondary: YinweiColors.panelElevated,
      onSurface: YinweiColors.textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: YinweiColors.background,
      fontFamily: 'SF Pro Text',
      fontFamilyFallback: const ['Segoe UI', 'Helvetica Neue', 'Arial'],
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: YinweiColors.textPrimary,
          letterSpacing: -0.3,
        ),
        titleSmall: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: YinweiColors.textPrimary,
          letterSpacing: -0.1,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: YinweiColors.textPrimary,
        ),
        bodyMedium: TextStyle(
          fontSize: 13,
          color: YinweiColors.textPrimary,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          color: YinweiColors.textSecondary,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          color: YinweiColors.textSecondary,
          letterSpacing: 0.2,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: YinweiColors.accent,
        inactiveTrackColor: const Color(0x22FFFFFF),
        thumbColor: const Color(0xFFF5F5F7),
        overlayColor: YinweiColors.accent.withOpacity(0.12),
        trackHeight: 2.5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      dividerColor: YinweiColors.hairline,
    );
  }
}
