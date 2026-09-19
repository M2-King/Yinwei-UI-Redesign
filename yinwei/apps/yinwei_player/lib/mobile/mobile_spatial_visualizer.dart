import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/island_spatial_controls.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Lightweight 2.5D Point stage. Presentation-only — no SceneStore writes.
class MobileSpatialVisualizer extends StatelessWidget {
  const MobileSpatialVisualizer({
    super.key,
    required this.pose,
    required this.presentation,
    required this.overlayActive,
    this.speakers = const [],
    this.onVisualPose,
  });

  static const rangeM = 4.0;

  final SphericalV1 pose;
  final WorkspacePresentation presentation;
  final bool overlayActive;
  final List<ArraySpeaker> speakers;
  final ValueChanged<SphericalV1>? onVisualPose;

  static Offset markerFor(Size size, SphericalV1 pose) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.38;
    final az = pose.azimuthDeg * math.pi / 180;
    final t = (pose.distanceM / rangeM).clamp(0.0, 1.0);
    return center + Offset(math.sin(az), -math.cos(az)) * (t * radius);
  }

  @override
  Widget build(BuildContext context) {
    final stereo = presentation == WorkspacePresentation.stereo2;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final center = Offset(size.width / 2, size.height / 2);
        final radius = math.min(size.width, size.height) * 0.38;
        return GestureDetector(
          key: const Key('mobile-spatial-visualizer'),
          behavior: HitTestBehavior.opaque,
          onTapDown: stereo
              ? null
              : (details) => _commit(details.localPosition, size, radius),
          onPanUpdate: stereo
              ? null
              : (details) => _commit(details.localPosition, size, radius),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: CustomPaint(
              size: size,
              painter: _StagePainter(
                pose: pose,
                overlayActive: overlayActive && !stereo,
                speakers: stereo ? speakers : const [],
                radius: radius,
              ),
              child: Stack(
                children: [
                  const SizedBox.expand(),
                  Positioned(
                    left: center.dx - 7,
                    top: center.dy - 7,
                    child: const SizedBox(
                      key: Key('mobile-listener'),
                      width: 14,
                      height: 14,
                    ),
                  ),
                  if (!stereo)
                    Positioned(
                      left: markerFor(size, pose).dx - 11,
                      top: markerFor(size, pose).dy - 11,
                      child: const SizedBox(
                        key: Key('mobile-source'),
                        width: 22,
                        height: 22,
                      ),
                    ),
                  if (overlayActive && !stereo)
                    const Positioned(
                      left: 0,
                      top: 0,
                      child: SizedBox(
                        key: Key('mobile-orbit-overlay'),
                        width: 1,
                        height: 1,
                      ),
                    ),
                  if (stereo) ..._stereoHits(size),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _stereoHits(Size size) {
    final widgets = <Widget>[];
    for (final speaker in speakers) {
      final mark = markerFor(
        size,
        SphericalV1(
          azimuthDeg: speaker.azimuthDeg,
          elevationDeg: speaker.elevationDeg,
          distanceM: speaker.distanceM,
        ),
      );
      widgets.add(
        Positioned(
          left: mark.dx - 10,
          top: mark.dy - 10,
          child: SizedBox(
            key: Key('mobile-stereo-${speaker.label}'),
            width: 20,
            height: 20,
          ),
        ),
      );
    }
    return widgets;
  }

  void _commit(Offset local, Size size, double radius) {
    if (onVisualPose == null) return;
    final center = Offset(size.width / 2, size.height / 2);
    onVisualPose!(
      IslandPointIntent.fromPad(
        dx: local.dx - center.dx,
        dy: local.dy - center.dy,
        radius: radius,
        rangeM: rangeM,
        elevationDeg: pose.elevationDeg,
        previousAzimuth: pose.azimuthDeg,
      ),
    );
  }
}

class _StagePainter extends CustomPainter {
  _StagePainter({
    required this.pose,
    required this.overlayActive,
    required this.speakers,
    required this.radius,
  });

  final SphericalV1 pose;
  final bool overlayActive;
  final List<ArraySpeaker> speakers;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x22FFFFFF);
    for (final t in [0.35, 0.7, 1.0]) {
      canvas.drawCircle(center, radius * t, ring);
    }

    final axis = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x14FFFFFF);
    canvas.drawLine(center + Offset(0, -radius), center + Offset(0, radius), axis);
    canvas.drawLine(center + Offset(-radius, 0), center + Offset(radius, 0), axis);

    final front = TextPainter(
      text: const TextSpan(
        text: 'FRONT',
        style: TextStyle(
          color: YinweiColors.textTertiary,
          fontSize: 9,
          letterSpacing: 1.4,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    front.paint(canvas, Offset(center.dx - front.width / 2, center.dy - radius - 16));

    canvas.drawCircle(
      center,
      6.5,
      Paint()..color = const Color(0xFFF5F5F7),
    );
    canvas.drawCircle(
      center,
      3.2,
      Paint()..color = const Color(0xFF0B0B0D),
    );

    if (speakers.isNotEmpty) {
      for (final speaker in speakers) {
        final mark = MobileSpatialVisualizer.markerFor(
          size,
          SphericalV1(
            azimuthDeg: speaker.azimuthDeg,
            elevationDeg: speaker.elevationDeg,
            distanceM: speaker.distanceM,
          ),
        );
        canvas.drawCircle(
          mark,
          11,
          Paint()..color = const Color(0x332C2C2E),
        );
        canvas.drawCircle(
          mark,
          7,
          Paint()..color = const Color(0xFFE8E8ED),
        );
        final label = TextPainter(
          text: TextSpan(
            text: speaker.label,
            style: const TextStyle(
              color: Color(0xFF0B0B0D),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, mark + Offset(-label.width / 2, -label.height / 2));
      }
      return;
    }

    final source = MobileSpatialVisualizer.markerFor(size, pose);
    final az = pose.azimuthDeg * math.pi / 180;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = YinweiColors.accent.withValues(alpha: overlayActive ? 0.55 : 0.28);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * 0.22),
      -math.pi / 2,
      az,
      false,
      arc,
    );

    final lift = -math.sin(pose.elevationDeg * math.pi / 180) * 16;
    canvas.drawLine(
      source,
      source + Offset(0, lift),
      Paint()
        ..color = const Color(0x55FFFFFF)
        ..strokeWidth = 1.5,
    );

    if (overlayActive) {
      final heading = Offset(math.cos(az), math.sin(az)) * 16;
      canvas.drawLine(
        source,
        source + heading,
        Paint()
          ..color = YinweiColors.accent.withValues(alpha: 0.7)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }

    canvas.drawCircle(
      source,
      overlayActive ? 16 : 13,
      Paint()..color = YinweiColors.accent.withValues(alpha: 0.16),
    );
    canvas.drawCircle(
      source,
      7,
      Paint()..color = YinweiColors.accent,
    );
    canvas.drawCircle(
      source + const Offset(-2, -2),
      2.2,
      Paint()..color = const Color(0xCCFFFFFF),
    );
  }

  @override
  bool shouldRepaint(covariant _StagePainter old) {
    return old.pose.azimuthDeg != pose.azimuthDeg ||
        old.pose.elevationDeg != pose.elevationDeg ||
        old.pose.distanceM != pose.distanceM ||
        old.overlayActive != overlayActive ||
        old.speakers != speakers ||
        old.radius != radius;
  }
}
