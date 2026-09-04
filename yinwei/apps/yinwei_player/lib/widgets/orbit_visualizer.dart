import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Left-panel ring + blue source dot (Apple mockup).
class OrbitVisualizer extends StatelessWidget {
  const OrbitVisualizer({
    super.key,
    required this.azimuthDeg,
    this.active = true,
  });

  /// 0° = front (top of ring), positive = clockwise toward right.
  final double azimuthDeg;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _OrbitPainter(azimuthDeg: azimuthDeg, active: active),
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({required this.azimuthDeg, required this.active});

  final double azimuthDeg;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide * 0.38;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.white.withOpacity(0.08);
    canvas.drawCircle(c, r, ring);

    // Soft trail arc behind the dot.
    final trail = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: _toCanvasAngle(azimuthDeg) - 1.2,
        endAngle: _toCanvasAngle(azimuthDeg),
        colors: [
          YinweiColors.accent.withOpacity(0),
          YinweiColors.accent.withOpacity(active ? 0.55 : 0.2),
        ],
        transform: GradientRotation(_toCanvasAngle(azimuthDeg) - 1.2),
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      _toCanvasAngle(azimuthDeg) - 1.1,
      1.1,
      false,
      trail,
    );

    final rad = _toCanvasAngle(azimuthDeg);
    final dot = Offset(c.dx + r * math.cos(rad), c.dy + r * math.sin(rad));

    canvas.drawCircle(
      dot,
      10,
      Paint()..color = YinweiColors.accent.withOpacity(0.25),
    );
    canvas.drawCircle(dot, 5.5, Paint()..color = YinweiColors.accent);
  }

  /// Map compass azimuth (0=front/up) to canvas radians (0=right, CW positive in math → adjust).
  double _toCanvasAngle(double azimuthDeg) {
    // UI: 0° front = top; positive azimuth → right.
    // Canvas: 0 = east, positive CW from east in standard math is actually CCW in screen Y-down…
    // Screen Y grows down: angle 0 at top = -pi/2 from +X.
    final deg = azimuthDeg;
    return (deg - 90) * math.pi / 180.0;
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.azimuthDeg != azimuthDeg || old.active != active;
}
