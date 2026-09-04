import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Consumer Atmos-style spatial field (dome + glow orb).
///
/// Interaction (B): drag orb → azimuth/elevation, scroll → distance,
/// Free / Top view toggle.
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
        if (_trail.length > 18) _trail.removeAt(0);
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
                      painter: _AtmosFieldPainter(
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
              left: 0,
              top: 0,
              child: _ViewToggle(
                mode: _view,
                onChanged: (m) => setState(() {
                  _view = m;
                  _trail.clear();
                }),
              ),
            ),
            Positioned(
              left: 0,
              bottom: 0,
              right: 0,
              child: Text(
                _view == FieldViewMode.top
                    ? '拖动定位 · 滚轮距离 · 俯视'
                    : '拖动定位 · 滚轮距离 · 自由视角',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: YinweiColors.textSecondary.withOpacity(0.7),
                      fontSize: 10,
                    ),
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
    return Material(
      color: YinweiColors.panelElevated.withOpacity(0.85),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _chip('Free', mode == FieldViewMode.free, () => onChanged(FieldViewMode.free)),
          _chip('Top', mode == FieldViewMode.top, () => onChanged(FieldViewMode.top)),
        ],
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) {
    return InkWell(
      onTap: tap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on ? YinweiColors.accent.withOpacity(0.35) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: on ? Colors.white : YinweiColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _AtmosFieldPainter extends CustomPainter {
  _AtmosFieldPainter({
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

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height / 2 + size.height * 0.02);
    final R = size.shortestSide * 0.38;

    _drawAmbience(canvas, size, origin, R);
    _drawDome(canvas, origin, R);
    _drawPlayheadRim(canvas, origin, R);
    _drawListener(canvas, origin, R);

    for (var i = 0; i < trail.length; i++) {
      final t = (i + 1) / (trail.length + 1);
      canvas.drawCircle(
        trail[i],
        3.0 * t,
        Paint()..color = YinweiColors.accent.withOpacity(0.12 * t),
      );
    }

    final orb = _projectSource(origin, R);
    onOrbProjected(orb.pos);
    _drawSource(canvas, orb);
  }

  void _drawAmbience(Canvas canvas, Size size, Offset origin, double R) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          origin,
          R * 1.6,
          [
            const Color(0xFF12141A),
            YinweiColors.background,
          ],
        ),
    );
    // Soft bloom behind field.
    canvas.drawCircle(
      origin,
      R * 1.15,
      Paint()
        ..shader = ui.Gradient.radial(
          origin,
          R * 1.15,
          [
            YinweiColors.accent.withOpacity(active ? 0.07 : 0.03),
            Colors.transparent,
          ],
        ),
    );
  }

  void _drawDome(Canvas canvas, Offset origin, double R) {
    if (view == FieldViewMode.top) {
      // Soft circular room, front marker at top.
      canvas.drawCircle(
        origin,
        R,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = const Color(0xFF3A5A80).withOpacity(0.55),
      );
      canvas.drawCircle(
        origin,
        R,
        Paint()
          ..shader = ui.Gradient.radial(
            origin,
            R,
            [
              Colors.white.withOpacity(0.03),
              Colors.transparent,
            ],
          ),
      );
      // Front cue.
      final front = Offset(origin.dx, origin.dy - R);
      canvas.drawCircle(front, 2.5, Paint()..color = Colors.white.withOpacity(0.35));
      // Crosshair faint.
      canvas.drawLine(
        Offset(origin.dx - R * 0.12, origin.dy),
        Offset(origin.dx + R * 0.12, origin.dy),
        Paint()..color = Colors.white.withOpacity(0.08),
      );
      canvas.drawLine(
        Offset(origin.dx, origin.dy - R * 0.12),
        Offset(origin.dx, origin.dy + R * 0.12),
        Paint()..color = Colors.white.withOpacity(0.08),
      );
      return;
    }

    // Free: soft hemisphere rim + floor ellipse (no wire meridians).
    final floor = Rect.fromCenter(
      center: Offset(origin.dx, origin.dy + R * 0.42),
      width: R * 1.7,
      height: R * 0.55,
    );
    canvas.drawOval(
      floor,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0xFF3A5A80).withOpacity(0.4),
    );
    canvas.drawOval(
      floor,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(origin.dx, origin.dy + R * 0.42),
          R,
          [Colors.white.withOpacity(0.04), Colors.transparent],
        ),
    );

    // Dome arc (upper hemisphere silhouette).
    final domeRect = Rect.fromCircle(center: origin, radius: R * 1.02);
    canvas.drawArc(
      domeRect,
      math.pi * 1.05,
      math.pi * 0.9,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF4A6A90).withOpacity(0.45),
    );

    // Soft dome fill.
    canvas.drawArc(
      domeRect,
      math.pi,
      math.pi,
      true,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(origin.dx, origin.dy - R),
          Offset(origin.dx, origin.dy + R * 0.2),
          [
            Colors.white.withOpacity(0.04),
            Colors.transparent,
          ],
        ),
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
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = YinweiColors.accent.withOpacity(0.35),
    );
  }

  void _drawListener(Canvas canvas, Offset origin, double R) {
    final s = R * 0.07;
    // Minimal head + shoulders (Person mode lite).
    final head = Path()
      ..addOval(Rect.fromCenter(center: origin.translate(0, -s * 0.35), width: s * 1.1, height: s * 1.25));
    canvas.drawPath(
      head,
      Paint()..color = Colors.white.withOpacity(0.55),
    );
    // Ears.
    canvas.drawCircle(origin.translate(-s * 0.7, -s * 0.3), s * 0.22,
        Paint()..color = Colors.white.withOpacity(0.4));
    canvas.drawCircle(origin.translate(s * 0.7, -s * 0.3), s * 0.22,
        Paint()..color = Colors.white.withOpacity(0.4));
    // Shoulders.
    canvas.drawOval(
      Rect.fromCenter(center: origin.translate(0, s * 0.85), width: s * 2.2, height: s * 0.7),
      Paint()..color = Colors.white.withOpacity(0.28),
    );
  }

  ({Offset pos, double near, double radNorm}) _projectSource(Offset origin, double R) {
    final az = azimuthDeg * math.pi / 180;
    final el = elevationDeg * math.pi / 180;
    final distNorm = ((distanceM - 0.5) / 9.5).clamp(0.0, 1.0);
    final rad = 0.28 + distNorm * 0.72;

    if (view == FieldViewMode.top) {
      // Top-down: front = -Y screen.
      final x = rad * math.sin(az) * R;
      final y = -rad * math.cos(az) * R;
      // Elevation lifts toward center slightly + scales orb later.
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
    final base = 10.0 + orb.near * 8 + envelopment * 4;
    final glow = base * (1.6 + envelopment * 1.2);

    // Object-size outline (Atmos Music Panner).
    canvas.drawCircle(
      orb.pos,
      glow * (0.9 + envelopment * 0.8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withOpacity(0.18 + envelopment * 0.25),
    );

    // Soft bloom layers.
    for (final layer in [
      (glow * 2.2, 0.04),
      (glow * 1.5, 0.08),
      (glow * 1.05, 0.14),
    ]) {
      canvas.drawCircle(
        orb.pos,
        layer.$1,
        Paint()
          ..color = YinweiColors.accent
              .withOpacity((active ? layer.$2 : layer.$2 * 0.4) * (0.7 + orb.near * 0.3)),
      );
    }

    // Core orb.
    canvas.drawCircle(
      orb.pos,
      base,
      Paint()
        ..shader = ui.Gradient.radial(
          orb.pos.translate(-base * 0.3, -base * 0.35),
          base * 1.2,
          [
            Colors.white.withOpacity(active ? 0.95 : 0.5),
            YinweiColors.accent.withOpacity(active ? 0.95 : 0.45),
            YinweiColors.accent.withOpacity(active ? 0.55 : 0.25),
          ],
          const [0.0, 0.45, 1.0],
        ),
    );

    if (orbiting) {
      canvas.drawCircle(
        orb.pos,
        base + 5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = YinweiColors.accent.withOpacity(0.55),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AtmosFieldPainter old) =>
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
