import 'package:flutter/material.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class MobilePointInspector extends StatelessWidget {
  const MobilePointInspector({
    super.key,
    required this.pose,
    required this.presentation,
    required this.overlayActive,
    required this.speakers,
    this.onVisualPose,
  });

  final SphericalV1 pose;
  final WorkspacePresentation presentation;
  final bool overlayActive;
  final List<ArraySpeaker> speakers;
  final ValueChanged<SphericalV1>? onVisualPose;

  @override
  Widget build(BuildContext context) {
    if (presentation == WorkspacePresentation.stereo2) {
      final left = speakers.isNotEmpty ? speakers.first : null;
      final right = speakers.length > 1 ? speakers[1] : null;
      return _Glass(
        child: Text(
          'Stereo 2.0   L ${left?.azimuthDeg.round() ?? -30}°   R ${right?.azimuthDeg.round() ?? 30}°',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      );
    }

    return _Glass(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  overlayActive ? 'Live heading' : 'Point origin',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              Text(
                'Az ${pose.azimuthDeg.round()}°',
                key: const Key('mobile-azimuth-readout'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
          _ValueSlider(
            label: 'Azimuth',
            value: pose.azimuthDeg.clamp(-180, 180),
            min: -180,
            max: 180,
            format: (v) => '${v.round()}°',
            onChanged: (v) => _commit(azimuthDeg: v),
          ),
          _ValueSlider(
            label: 'Elevation',
            value: pose.elevationDeg.clamp(-89, 89),
            min: -89,
            max: 89,
            format: (v) => '${v.round()}°',
            onChanged: (v) => _commit(elevationDeg: v),
          ),
          _ValueSlider(
            label: 'Distance',
            value: pose.distanceM.clamp(0.5, 4),
            min: 0.5,
            max: 4,
            format: (v) => '${v.toStringAsFixed(1)} m',
            onChanged: (v) => _commit(distanceM: v),
          ),
        ],
      ),
    );
  }

  void _commit({double? azimuthDeg, double? elevationDeg, double? distanceM}) {
    onVisualPose?.call(
      SphericalV1(
        azimuthDeg: azimuthDeg ?? pose.azimuthDeg,
        elevationDeg: elevationDeg ?? pose.elevationDeg,
        distanceM: distanceM ?? pose.distanceM,
      ),
    );
  }
}

class _ValueSlider extends StatelessWidget {
  const _ValueSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              format(value),
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: BoxDecoration(
        color: const Color(0xCC161618),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: YinweiColors.hairline),
      ),
      child: child,
    );
  }
}
