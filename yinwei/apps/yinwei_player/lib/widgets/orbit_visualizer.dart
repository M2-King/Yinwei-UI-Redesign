import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Pseudo-3D spatial field: listener at origin, source on a sphere by
/// azimuth / elevation / distance. Equator ring carries the playhead.
class OrbitVisualizer extends StatelessWidget {
  const OrbitVisualizer({
    super.key,
    required this.playhead,
    required this.azimuthDeg,
    this.elevationDeg = 0,
    this.distanceM = 1.5,
    this.active = true,
    this.orbiting = false,
  });

  /// 0..1 track playhead on the equatorial ring.
  final double playhead;

  /// Source azimuth: 0° = front (−Z), + = right (+X).
  final double azimuthDeg;
  final double elevationDeg;

  /// Distance in meters (mapped into sphere radius scale).
  final double distanceM;
  final bool active;
  final bool orbiting;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, constraints.maxHeight);
        if (side <= 0 || !side.isFinite) return const SizedBox.shrink();
        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: CustomPaint(
              painter: _SpatialSpherePainter(
                playhead: playhead.clamp(0.0, 1.0),
                azimuthDeg: azimuthDeg,
                elevationDeg: elevationDeg,
                distanceM: distanceM.clamp(0.5, 10.0),
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

class _SpatialSpherePainter extends CustomPainter {
  _SpatialSpherePainter({
    required this.playhead,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
    required this.active,
    required this.orbiting,
  });

  final double playhead;
  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
  final bool active;
  final bool orbiting;

  // Camera: slight elevation + yaw so the sphere reads as 3D.
  static const double _pitch = 0.42; // look-down angle (rad)
  static const double _yaw = -0.35;

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height / 2 + size.height * 0.02);
    final R = size.shortestSide * 0.36;

    // Soft floor ellipse (depth cue).
    final floor = R * 0.92;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(origin.dx, origin.dy + R * 0.55),
        width: floor * 1.55,
        height: floor * 0.42,
      ),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(origin.dx, origin.dy + R * 0.55),
          floor,
          [
            Colors.white.withOpacity(0.06),
            Colors.transparent,
          ],
        ),
    );

    // Sphere wireframe: meridians + parallels.
    _drawSphereWire(canvas, origin, R);

    // Equatorial playhead ring (flat ellipse in view).
    _drawPlayheadRing(canvas, origin, R);

    // Listener at center.
    canvas.drawCircle(
      origin,
      5,
      Paint()..color = Colors.white.withOpacity(0.55),
    );
    canvas.drawCircle(
      origin,
      2.2,
      Paint()..color = YinweiColors.background,
    );

    // Source in 3D → projected.
    final src = _projectSource(origin, R);
    _drawSource(canvas, src);
  }

  void _drawSphereWire(Canvas canvas, Offset origin, double R) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withOpacity(0.07);

    // Longitude meridians.
    for (var i = 0; i < 8; i++) {
      final lon = i * math.pi / 4;
      final path = Path();
      var first = true;
      for (var j = 0; j <= 48; j++) {
        final lat = -math.pi / 2 + j * math.pi / 48;
        final p = _project(
          origin,
          R,
          math.cos(lat) * math.sin(lon),
          math.sin(lat),
          math.cos(lat) * math.cos(lon),
        );
        if (first) {
          path.moveTo(p.dx, p.dy);
          first = false;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, stroke);
    }

    // Latitude parallels.
    for (final latDeg in [-60.0, -30.0, 0.0, 30.0, 60.0]) {
      final lat = latDeg * math.pi / 180;
      final path = Path();
      var first = true;
      for (var j = 0; j <= 64; j++) {
        final lon = j * 2 * math.pi / 64;
        final p = _project(
          origin,
          R,
          math.cos(lat) * math.sin(lon),
          math.sin(lat),
          math.cos(lat) * math.cos(lon),
        );
        if (first) {
          path.moveTo(p.dx, p.dy);
          first = false;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = latDeg == 0 ? 1.3 : 1
          ..color = Colors.white.withOpacity(latDeg == 0 ? 0.14 : 0.06),
      );
    }

    // Front label cue (small tick at front of equator).
    final front = _project(origin, R, 0, 0, 1);
    canvas.drawCircle(front, 2, Paint()..color = Colors.white.withOpacity(0.25));
  }

  void _drawPlayheadRing(Canvas canvas, Offset origin, double R) {
    // Sample equator arc 0..playhead (from front, clockwise toward right).
    if (playhead <= 0.001) return;

    final path = Path();
    final steps = math.max(2, (playhead * 64).round());
    for (var i = 0; i <= steps; i++) {
      final t = playhead * i / steps;
      // Azimuth from front, clockwise = positive in our convention.
      final az = t * 2 * math.pi;
      final p = _project(
        origin,
        R,
        math.sin(az),
        0,
        math.cos(az),
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = YinweiColors.accent.withOpacity(active ? 0.75 : 0.3),
    );

    // Blue playhead bead on equator.
    final az = playhead * 2 * math.pi;
    final bead = _project(origin, R, math.sin(az), 0, math.cos(az));
    canvas.drawCircle(
      bead,
      10,
      Paint()..color = YinweiColors.accent.withOpacity(0.25),
    );
    canvas.drawCircle(bead, 5, Paint()..color = YinweiColors.accent);
  }

  ({Offset pos, double depth, double scale}) _projectSource(
    Offset origin,
    double R,
  ) {
    final az = azimuthDeg * math.pi / 180;
    final el = elevationDeg * math.pi / 180;
    // Map distance 0.5..10m → 0.35..1.0 of sphere radius.
    final distNorm = ((distanceM - 0.5) / 9.5).clamp(0.0, 1.0);
    final rad = 0.35 + distNorm * 0.65;

    final x = rad * math.cos(el) * math.sin(az);
    final y = rad * math.sin(el);
    final z = rad * math.cos(el) * math.cos(az);

    final p = _projectRaw(x, y, z);
    final screen = Offset(origin.dx + p.x * R, origin.dy + p.y * R);
    // depth: larger z' → closer to camera after rotate
    return (pos: screen, depth: p.z, scale: rad);
  }

  void _drawSource(Canvas canvas, ({Offset pos, double depth, double scale}) src) {
    // Closer sources (higher depth after cam) draw larger / brighter.
    final near = ((src.depth + 1) / 2).clamp(0.0, 1.0);
    final radius = (6.5 + near * 5 + (orbiting ? 1.5 : 0)) * (0.85 + src.scale * 0.2);
    final alpha = active ? (0.55 + near * 0.4) : 0.25;

    // Depth shadow on floor.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(src.pos.dx, src.pos.dy + radius * 1.8),
        width: radius * 2.2,
        height: radius * 0.7,
      ),
      Paint()..color = Colors.black.withOpacity(0.35 * near),
    );

    canvas.drawCircle(
      src.pos,
      radius * 1.7,
      Paint()..color = YinweiColors.accent.withOpacity(0.18 * alpha),
    );
    canvas.drawCircle(
      src.pos,
      radius,
      Paint()
        ..shader = ui.Gradient.radial(
          src.pos.translate(-radius * 0.25, -radius * 0.25),
          radius,
          [
            Color.lerp(Colors.white, YinweiColors.accent, 0.35)!,
            YinweiColors.accent,
          ],
        ),
    );

    // Orbit trail hint.
    if (orbiting) {
      canvas.drawCircle(
        src.pos,
        radius + 4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = YinweiColors.accent.withOpacity(0.45),
      );
    }
  }

  /// Unit sphere point (x,y,z) → screen offset relative to origin, scaled later by R.
  /// Convention: +X right, +Y up, +Z front (toward viewer before cam).
  Offset _project(Offset origin, double R, double x, double y, double z) {
    final p = _projectRaw(x, y, z);
    return Offset(origin.dx + p.x * R, origin.dy + p.y * R);
  }

  ({double x, double y, double z}) _projectRaw(double x, double y, double z) {
    // Yaw around Y, then pitch around X (look down).
    final cy = math.cos(_yaw);
    final sy = math.sin(_yaw);
    final x1 = x * cy + z * sy;
    final z1 = -x * sy + z * cy;

    final cp = math.cos(_pitch);
    final sp = math.sin(_pitch);
    final y2 = y * cp - z1 * sp;
    final z2 = y * sp + z1 * cp;

    // Simple perspective.
    final persp = 1.0 / (2.4 - z2);
    return (x: x1 * persp, y: -y2 * persp, z: z2);
  }

  @override
  bool shouldRepaint(covariant _SpatialSpherePainter old) =>
      old.playhead != playhead ||
      old.azimuthDeg != azimuthDeg ||
      old.elevationDeg != elevationDeg ||
      old.distanceM != distanceM ||
      old.active != active ||
      old.orbiting != orbiting;
}
