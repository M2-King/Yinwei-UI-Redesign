import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Spatial field — dark Apple instrument, not a white card / neon HUD.
///
/// Drag → azimuth/elevation, scroll → distance, Free / Top view toggle.
enum FieldViewMode { free, top }

class OrbitVisualizer extends StatefulWidget {
  const OrbitVisualizer({
    super.key,
    required this.playhead,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
    required this.envelopment,
    this.active = true,
    this.orbiting = false,
    this.onPoseChanged,
    this.onDistanceChanged,
  });

  final double playhead;
  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
  final double envelopment;
  final bool active;
  final bool orbiting;
  final void Function(double azimuthDeg, double elevationDeg)? onPoseChanged;
  final ValueChanged<double>? onDistanceChanged;

  @override
  State<OrbitVisualizer> createState() => _OrbitVisualizerState();
}

class _OrbitVisualizerState extends State<OrbitVisualizer> {
  FieldViewMode _view = FieldViewMode.free;
  final List<Offset> _trail = [];
  Offset? _orbScreen;
  Size _size = Size.zero;

  @override
  void didUpdateWidget(covariant OrbitVisualizer old) {
    super.didUpdateWidget(old);
    if (widget.orbiting &&
        (old.azimuthDeg != widget.azimuthDeg ||
            old.elevationDeg != widget.elevationDeg)) {
      if (_orbScreen != null) {
        _trail.add(_orbScreen!);
        if (_trail.length > 14) _trail.removeAt(0);
      }
    } else if (!widget.orbiting && _trail.isNotEmpty) {
      _trail.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, constraints.maxHeight);
        if (side <= 0 || !side.isFinite) return const SizedBox.shrink();
        _size = Size(side, side);

        return Stack(
          children: [
            Center(
              child: SizedBox(
                width: side,
                height: side,
                child: Listener(
                  onPointerSignal: _onPointerSignal,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: _onPanUpdate,
                    child: CustomPaint(
                      painter: _FieldPainter(
                        playhead: widget.playhead.clamp(0.0, 1.0),
                        azimuthDeg: widget.azimuthDeg,
                        elevationDeg: widget.elevationDeg,
                        distanceM: widget.distanceM.clamp(0.5, 10.0),
                        envelopment: widget.envelopment.clamp(0.0, 1.0),
                        active: widget.active,
                        orbiting: widget.orbiting,
                        view: _view,
                        trail: List.of(_trail),
                        onOrbProjected: (o) => _orbScreen = o,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 4,
              top: 2,
              child: _ViewToggle(
                mode: _view,
                onChanged: (m) => setState(() {
                  _view = m;
                  _trail.clear();
                }),
              ),
            ),
          ],
        );
      },
    );
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (widget.onPoseChanged == null || _size == Size.zero) return;
    final origin = Offset(_size.width / 2, _size.height / 2);
    final p = d.localPosition - origin;
    final R = _size.shortestSide * 0.38;

    if (_view == FieldViewMode.top) {
      final az = math.atan2(p.dx, -p.dy) * 180 / math.pi;
      final distNorm = (p.distance / R).clamp(0.0, 1.0);
      widget.onPoseChanged!(az, widget.elevationDeg);
      if (widget.onDistanceChanged != null) {
        final dist = (0.5 + distNorm * 9.5).clamp(0.5, 10.0);
        widget.onDistanceChanged!(dist);
      }
    } else {
      final az = math.atan2(p.dx, -p.dy) * 180 / math.pi;
      final distNorm = (p.distance / (R * 1.05)).clamp(0.0, 1.0);
      final elevFromY = (-p.dy / R).clamp(-1.0, 1.0) * 75.0;
      final elevFromRad = (1.0 - distNorm) * 20.0;
      final el = (elevFromY * 0.85 + elevFromRad * 0.15).clamp(-90.0, 90.0);
      widget.onPoseChanged!(az, el.toDouble());
    }
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || widget.onDistanceChanged == null) return;
    final delta = e.scrollDelta.dy;
    final next = (widget.distanceM + delta * 0.01).clamp(0.5, 10.0);
    widget.onDistanceChanged!(next);
  }
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.mode, required this.onChanged});

  final FieldViewMode mode;
  final ValueChanged<FieldViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _item('Free', mode == FieldViewMode.free, () => onChanged(FieldViewMode.free)),
        const SizedBox(width: 18),
        _item('Top', mode == FieldViewMode.top, () => onChanged(FieldViewMode.top)),
      ],
    );
  }

  Widget _item(String label, bool on, VoidCallback tap) {
    return GestureDetector(
      onTap: tap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: on ? FontWeight.w500 : FontWeight.w400,
                letterSpacing: 0.2,
                color: on ? YinweiColors.textPrimary : YinweiColors.textSecondary,
              ),
            ),
            const SizedBox(height: 5),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              height: 1.5,
              width: on ? 22 : 0,
              decoration: BoxDecoration(
                color: YinweiColors.accent.withOpacity(on ? 0.9 : 0),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldPainter extends CustomPainter {
  _FieldPainter({
    required this.playhead,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
    required this.envelopment,
    required this.active,
    required this.orbiting,
    required this.view,
    required this.trail,
    required this.onOrbProjected,
  });

  final double playhead;
  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
  final double envelopment;
  final bool active;
  final bool orbiting;
  final FieldViewMode view;
  final List<Offset> trail;
  final ValueChanged<Offset> onOrbProjected;

  static const double _freePitch = 0.38;
  static const double _freeYaw = -0.28;

  // Cool graphite lines — sit in dark UI without going neon.
  static const _line = Color(0xFF6E727A);
  static const _lineSoft = Color(0xFF3A3D44);

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height / 2 + size.height * 0.02);
    final R = size.shortestSide * 0.38;

    _drawAmbience(canvas, size, origin, R);
    _drawField(canvas, origin, R);
    _drawPlayheadRim(canvas, origin, R);
    _drawListener(canvas, origin, R);

    for (var i = 0; i < trail.length; i++) {
      final t = (i + 1) / (trail.length + 1);
      canvas.drawCircle(
        trail[i],
        2.2 * t,
        Paint()..color = YinweiColors.accent.withOpacity(0.08 * t),
      );
    }

    final orb = _projectSource(origin, R);
    onOrbProjected(orb.pos);
    _drawSource(canvas, orb);
  }

  void _drawAmbience(Canvas canvas, Size size, Offset origin, double R) {
    // Seamless dark — never a light plate.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          origin,
          R * 1.75,
          [
            const Color(0xFF121214),
            YinweiColors.background,
          ],
        ),
    );

    final env = envelopment.clamp(0.0, 1.0);
    final bloom = (active ? 0.055 : 0.025) + env * 0.045;
    canvas.drawCircle(
      origin,
      R * (1.05 + env * 0.12),
      Paint()
        ..shader = ui.Gradient.radial(
          origin,
          R * 1.2,
          [
            YinweiColors.accent.withOpacity(bloom),
            Colors.transparent,
          ],
        ),
    );
  }

  void _drawField(Canvas canvas, Offset origin, double R) {
    if (view == FieldViewMode.top) {
      // Soft fill.
      canvas.drawCircle(
        origin,
        R,
        Paint()
          ..shader = ui.Gradient.radial(
            origin,
            R,
            [
              Colors.white.withOpacity(0.035),
              Colors.transparent,
            ],
          ),
      );
      // Hairline ring.
      canvas.drawCircle(
        origin,
        R,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = _line.withOpacity(0.45),
      );
      // Front marker.
      canvas.drawLine(
        Offset(origin.dx, origin.dy - R + 1),
        Offset(origin.dx, origin.dy - R + 10),
        Paint()
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withOpacity(0.35),
      );
      return;
    }

    // Free: floor ellipse + soft dome silhouette.
    final floor = Rect.fromCenter(
      center: Offset(origin.dx, origin.dy + R * 0.42),
      width: R * 1.7,
      height: R * 0.55,
    );
    canvas.drawOval(
      floor,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(origin.dx, origin.dy + R * 0.42),
          R * 0.95,
          [
            Colors.white.withOpacity(0.04 + envelopment * 0.03),
            Colors.transparent,
          ],
        ),
    );
    canvas.drawOval(
      floor,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _line.withOpacity(0.38),
    );

    // One soft mid ring — depth without CAD mesh.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(origin.dx, origin.dy + R * 0.42),
        width: R * 1.7 * 0.55,
        height: R * 0.55 * 0.55,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = _lineSoft.withOpacity(0.4),
    );

    final domeRect = Rect.fromCircle(center: origin, radius: R * 1.02);
    // Soft dome volume (fill first), then a single hairline arc.
    canvas.drawArc(
      domeRect,
      math.pi,
      math.pi,
      true,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(origin.dx, origin.dy - R),
          Offset(origin.dx, origin.dy + R * 0.15),
          [
            Colors.white.withOpacity(0.045 + envelopment * 0.03),
            Colors.transparent,
          ],
        ),
    );
    canvas.drawArc(
      domeRect,
      math.pi * 1.08,
      math.pi * 0.84,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round
        ..color = _line.withOpacity(0.28),
    );
  }

  void _drawPlayheadRim(Canvas canvas, Offset origin, double R) {
    if (playhead <= 0.001) return;
    final rect = view == FieldViewMode.top
        ? Rect.fromCircle(center: origin, radius: R)
        : Rect.fromCenter(
            center: Offset(origin.dx, origin.dy + R * 0.42),
            width: R * 1.7,
            height: R * 0.55,
          );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      playhead * 2 * math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..color = YinweiColors.accent.withOpacity(0.28),
    );
  }

  void _drawListener(Canvas canvas, Offset origin, double R) {
    // Precision reference: ring + core — no cartoon figure.
    final r = R * 0.045;
    canvas.drawCircle(
      origin,
      r * 2.1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withOpacity(0.28),
    );
    canvas.drawCircle(
      origin,
      r * 0.55,
      Paint()..color = Colors.white.withOpacity(0.72),
    );
  }

  ({Offset pos, double near, double radNorm}) _projectSource(Offset origin, double R) {
    final az = azimuthDeg * math.pi / 180;
    final el = elevationDeg * math.pi / 180;
    final distNorm = ((distanceM - 0.5) / 9.5).clamp(0.0, 1.0);
    final rad = 0.28 + distNorm * 0.72;

    if (view == FieldViewMode.top) {
      final x = rad * math.sin(az) * R;
      final y = -rad * math.cos(az) * R;
      final lift = (el / 90.0).clamp(-1.0, 1.0) * R * 0.08;
      return (
        pos: Offset(origin.dx + x, origin.dy + y + lift),
        near: 0.5 + (el / 180.0 + 0.5) * 0.5,
        radNorm: rad,
      );
    }

    final x = rad * math.cos(el) * math.sin(az);
    final y = rad * math.sin(el);
    final z = rad * math.cos(el) * math.cos(az);
    final p = _cam(x, y, z);
    return (
      pos: Offset(origin.dx + p.x * R, origin.dy + p.y * R),
      near: ((p.z + 1) / 2).clamp(0.0, 1.0),
      radNorm: rad,
    );
  }

  ({double x, double y, double z}) _cam(double x, double y, double z) {
    final cy = math.cos(_freeYaw);
    final sy = math.sin(_freeYaw);
    final x1 = x * cy + z * sy;
    final z1 = -x * sy + z * cy;
    final cp = math.cos(_freePitch);
    final sp = math.sin(_freePitch);
    final y2 = y * cp - z1 * sp;
    final z2 = y * sp + z1 * cp;
    final persp = 1.0 / (2.35 - z2);
    return (x: x1 * persp, y: -y2 * persp, z: z2);
  }

  void _drawSource(Canvas canvas, ({Offset pos, double near, double radNorm}) orb) {
    final core = 5.5 + orb.near * 3.5 + envelopment * 1.5;
    final a = active ? 1.0 : 0.45;

    // One soft bloom — restrained, not neon stack.
    canvas.drawCircle(
      orb.pos,
      core * (2.4 + envelopment * 0.6),
      Paint()
        ..shader = ui.Gradient.radial(
          orb.pos,
          core * 2.6,
          [
            YinweiColors.accent.withOpacity(0.18 * a),
            YinweiColors.accent.withOpacity(0.04 * a),
            Colors.transparent,
          ],
          const [0.0, 0.45, 1.0],
        ),
    );

    canvas.drawCircle(
      orb.pos,
      core,
      Paint()
        ..shader = ui.Gradient.radial(
          orb.pos.translate(-core * 0.28, -core * 0.32),
          core * 1.15,
          [
            Colors.white.withOpacity(0.92 * a),
            YinweiColors.accent.withOpacity(0.95 * a),
            const Color(0xFF0060DF).withOpacity(0.85 * a),
          ],
          const [0.0, 0.4, 1.0],
        ),
    );

    if (orbiting) {
      canvas.drawCircle(
        orb.pos,
        core + 4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = YinweiColors.accent.withOpacity(0.4 * a),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FieldPainter old) =>
      old.playhead != playhead ||
      old.azimuthDeg != azimuthDeg ||
      old.elevationDeg != elevationDeg ||
      old.distanceM != distanceM ||
      old.envelopment != envelopment ||
      old.active != active ||
      old.orbiting != orbiting ||
      old.view != view ||
      old.trail.length != trail.length;
}
