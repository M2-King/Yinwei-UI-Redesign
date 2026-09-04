import 'package:flutter/material.dart';

/// Apple-dark tokens locked to the approved UI mockup.
abstract final class YinweiColors {
  static const background = Color(0xFF0B0B0D);
  static const panel = Color(0xFF141416);
  static const panelElevated = Color(0xFF1C1C1E);
  static const hairline = Color(0x1FFFFFFF);
  static const accent = Color(0xFF0A84FF);
  static const textPrimary = Color(0xFFF5F5F7);
  static const textSecondary = Color(0xFF8E8E93);
  static const success = Color(0xFF30D158);
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
        inactiveTrackColor: YinweiColors.hairline,
        thumbColor: Colors.white,
        overlayColor: YinweiColors.accent.withOpacity(0.15),
        trackHeight: 3,
      ),
      dividerColor: YinweiColors.hairline,
    );
  }
}
