import 'package:flutter/material.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class MobileSpatialModeControl extends StatelessWidget {
  const MobileSpatialModeControl({
    super.key,
    required this.playbackMode,
    required this.motion,
    required this.presentation,
    this.onPlaybackMode,
    this.onMotion,
  });

  final PlaybackMode playbackMode;
  final MotionMode motion;
  final WorkspacePresentation presentation;
  final ValueChanged<PlaybackMode>? onPlaybackMode;
  final ValueChanged<MotionMode>? onMotion;

  @override
  Widget build(BuildContext context) {
    final stereo = presentation == WorkspacePresentation.stereo2;
    return Row(
      children: [
        Expanded(
          child: _Segmented(
            left: 'Spatial',
            right: 'Original',
            leftSelected: playbackMode == PlaybackMode.spatial,
            onLeft: () => onPlaybackMode?.call(PlaybackMode.spatial),
            onRight: () => onPlaybackMode?.call(PlaybackMode.original),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: stereo
              ? const _Locked('Stereo 2.0')
              : _Segmented(
                  left: 'Fixed',
                  right: 'Orbit',
                  leftSelected: motion == MotionMode.fixed,
                  onLeft: () => onMotion?.call(MotionMode.fixed),
                  onRight: () => onMotion?.call(MotionMode.orbit),
                ),
        ),
      ],
    );
  }
}

class _Locked extends StatelessWidget {
  const _Locked(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: YinweiColors.well,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: YinweiColors.hairline),
      ),
      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.left,
    required this.right,
    required this.leftSelected,
    required this.onLeft,
    required this.onRight,
  });

  final String left;
  final String right;
  final bool leftSelected;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: YinweiColors.well,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: YinweiColors.hairline),
      ),
      child: Row(
        children: [
          _Chip(label: left, selected: leftSelected, onTap: onLeft),
          _Chip(label: right, selected: !leftSelected, onTap: onRight),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2A2A2E) : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: selected
                      ? YinweiColors.textPrimary
                      : YinweiColors.textSecondary,
                ),
          ),
        ),
      ),
    );
  }
}
