import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Left-panel ring:
/// - **Blue ball** = playhead (same clock as the bottom scrubber, real-time)
/// - **Dim tick** = spatial source azimuth (presets / Orbit)
class OrbitVisualizer extends StatelessWidget {
  const OrbitVisualizer({
    super.key,
    required this.playhead,
    required this.azimuthDeg,
    this.elevationDeg = 0,
    this.active = true,
    this.orbiting = false,
  });

  /// 0..1 track playhead — drives the blue ball.
  final double playhead;

  /// Spatial source azimuth in degrees (0 = front/top).
  final double azimuthDeg;
  final double elevationDeg;
  final bool active;
  final bool orbiting;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, constraints.maxHeight);
        if (side <= 0 || !side.isFinite) {
          return const SizedBox.shrink();
        }
        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: CustomPaint(
              painter: _OrbitPainter(
                playhead: playhead.clamp(0.0, 1.0),
                azimuthDeg: azimuthDeg,
                elevationDeg: elevationDeg,
                active: active,
                orbiting: orbiting,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.playhead,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.active,
    required this.orbiting,
  });

  final double playhead;
  final double azimuthDeg;
  final double elevationDeg;
  final bool active;
  final bool orbiting;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final baseR = size.shortestSide * 0.38;
    final elevNorm = (elevationDeg.clamp(-90, 90) / 90.0);
    final r = baseR * (1.0 - elevNorm * 0.18);

    // Base ring.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withOpacity(0.08),
    );

    // --- Playhead (blue): angle from top, clockwise, = scrubber ---
    final playRad = _playheadToCanvas(playhead);
    final playSweep = playhead * 2 * math.pi;

    if (playhead > 0.001) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        -math.pi / 2,
        playSweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..color = YinweiColors.accent.withOpacity(active ? 0.7 : 0.3),
      );
    }

    final playDot = Offset(
      c.dx + r * math.cos(playRad),
      c.dy + r * math.sin(playRad),
    );
    canvas.drawCircle(
      playDot,
      12,
      Paint()..color = YinweiColors.accent.withOpacity(0.28),
    );
    canvas.drawCircle(playDot, 6, Paint()..color = YinweiColors.accent);

    // --- Source azimuth (dim tick): presets / Orbit ---
    final azRad = _azimuthToCanvas(azimuthDeg);
    final azDot = Offset(
      c.dx + r * math.cos(azRad),
      c.dy + r * math.sin(azRad),
    );
    canvas.drawCircle(
      azDot,
      orbiting ? 5 : 4,
      Paint()
        ..color = Colors.white.withOpacity(orbiting ? 0.55 : 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(
      azDot,
      2.2,
      Paint()..color = Colors.white.withOpacity(orbiting ? 0.75 : 0.4),
    );

    // Listener.
    canvas.drawCircle(
      c,
      3.5,
      Paint()..color = Colors.white.withOpacity(0.4),
    );
  }

  /// Playhead 0..1 → canvas radians (0 at top, clockwise).
  double _playheadToCanvas(double p) {
    return -math.pi / 2 + p * 2 * math.pi;
  }

  /// Compass azimuth 0° front/top → canvas radians.
  double _azimuthToCanvas(double azimuthDeg) {
    return (azimuthDeg - 90) * math.pi / 180.0;
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.playhead != playhead ||
      old.azimuthDeg != azimuthDeg ||
      old.elevationDeg != elevationDeg ||
      old.active != active ||
      old.orbiting != orbiting;
}
