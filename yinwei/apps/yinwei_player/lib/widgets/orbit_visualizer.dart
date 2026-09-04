import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Left-panel ring + blue source dot (Apple mockup).
class OrbitVisualizer extends StatelessWidget {
  const OrbitVisualizer({
    super.key,
    required this.azimuthDeg,
    this.elevationDeg = 0,
    this.active = true,
    this.orbiting = false,
  });

  /// 0° = front (top of ring), positive = clockwise toward right.
  final double azimuthDeg;
  final double elevationDeg;
  final bool active;
  final bool orbiting;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _OrbitPainter(
          azimuthDeg: azimuthDeg,
          elevationDeg: elevationDeg,
          active: active,
          orbiting: orbiting,
        ),
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.active,
    required this.orbiting,
  });

  final double azimuthDeg;
  final double elevationDeg;
  final bool active;
  final bool orbiting;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final baseR = size.shortestSide * 0.38;
    // Elevation pulls the ring radius slightly (visual cue only).
    final elevNorm = (elevationDeg.clamp(-90, 90) / 90.0);
    final r = baseR * (1.0 - elevNorm * 0.18);

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = orbiting ? 1.6 : 1.2
      ..color = Colors.white.withValues(alpha: orbiting ? 0.14 : 0.08);
    canvas.drawCircle(c, r, ring);

    // Soft trail arc behind the dot.
    final trailLen = orbiting ? 1.6 : 1.1;
    final trail = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = orbiting ? 4 : 3
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: _toCanvasAngle(azimuthDeg) - trailLen,
        endAngle: _toCanvasAngle(azimuthDeg),
        colors: [
          YinweiColors.accent.withValues(alpha: 0),
          YinweiColors.accent.withValues(alpha: active ? (orbiting ? 0.7 : 0.55) : 0.2),
        ],
        transform: GradientRotation(_toCanvasAngle(azimuthDeg) - trailLen),
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      _toCanvasAngle(azimuthDeg) - trailLen,
      trailLen,
      false,
      trail,
    );

    final rad = _toCanvasAngle(azimuthDeg);
    final dot = Offset(c.dx + r * math.cos(rad), c.dy + r * math.sin(rad));

    canvas.drawCircle(
      dot,
      orbiting ? 12 : 10,
      Paint()..color = YinweiColors.accent.withValues(alpha: 0.25),
    );
    canvas.drawCircle(
      dot,
      orbiting ? 6.5 : 5.5,
      Paint()..color = YinweiColors.accent,
    );

    // Listener mark at center.
    canvas.drawCircle(
      c,
      3.5,
      Paint()..color = Colors.white.withValues(alpha: 0.35),
    );
  }

  /// Map compass azimuth (0=front/up) to canvas radians.
  double _toCanvasAngle(double azimuthDeg) {
    // UI: 0° front = top; positive azimuth → right.
    // Screen Y grows down: angle 0 at top = -pi/2 from +X.
    return (azimuthDeg - 90) * math.pi / 180.0;
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.azimuthDeg != azimuthDeg ||
      old.elevationDeg != elevationDeg ||
      old.active != active ||
      old.orbiting != orbiting;
}
