import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Left-panel ring + blue source dot (Apple mockup).
///
/// Sized with [LayoutBuilder] (not AspectRatio) so a tall square never
/// overflows the row and paints over the sidebar ("穿层").
class OrbitVisualizer extends StatelessWidget {
  const OrbitVisualizer({
    super.key,
    required this.azimuthDeg,
    this.elevationDeg = 0,
    this.playhead = 0,
    this.active = true,
    this.orbiting = false,
  });

  /// 0° = front (top of ring), positive = clockwise toward right.
  final double azimuthDeg;
  final double elevationDeg;

  /// 0..1 track playhead — draws a faint progress arc so the left panel
  /// visibly tracks scrubbing / playback even in Fixed mode.
  final double playhead;
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
                azimuthDeg: azimuthDeg,
                elevationDeg: elevationDeg,
                playhead: playhead.clamp(0.0, 1.0),
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
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.playhead,
    required this.active,
    required this.orbiting,
  });

  final double azimuthDeg;
  final double elevationDeg;
  final double playhead;
  final bool active;
  final bool orbiting;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final baseR = size.shortestSide * 0.38;
    final elevNorm = (elevationDeg.clamp(-90, 90) / 90.0);
    final r = baseR * (1.0 - elevNorm * 0.18);

    // Track ring.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = orbiting ? 1.6 : 1.2
        ..color = Colors.white.withOpacity(orbiting ? 0.16 : 0.08),
    );

    // Playhead progress (full ring) — always moves with scrubber / play.
    if (playhead > 0.001) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        -math.pi / 2,
        playhead * 2 * math.pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withOpacity(0.22),
      );
    }

    final rad = _toCanvasAngle(azimuthDeg);
    final trailLen = orbiting ? 1.6 : 1.1;

    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      rad - trailLen,
      trailLen,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = orbiting ? 4 : 3
        ..strokeCap = StrokeCap.round
        ..color = YinweiColors.accent.withOpacity(active ? 0.45 : 0.18),
    );

    final dot = Offset(c.dx + r * math.cos(rad), c.dy + r * math.sin(rad));

    canvas.drawCircle(
      dot,
      orbiting ? 14 : 11,
      Paint()..color = YinweiColors.accent.withOpacity(0.28),
    );
    canvas.drawCircle(
      dot,
      orbiting ? 7 : 6,
      Paint()..color = YinweiColors.accent,
    );

    // Listener at center.
    canvas.drawCircle(
      c,
      3.5,
      Paint()..color = Colors.white.withOpacity(0.4),
    );
  }

  double _toCanvasAngle(double azimuthDeg) {
    // 0° front = top; positive azimuth → right.
    return (azimuthDeg - 90) * math.pi / 180.0;
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.azimuthDeg != azimuthDeg ||
      old.elevationDeg != elevationDeg ||
      old.playhead != playhead ||
      old.active != active ||
      old.orbiting != orbiting;
}
