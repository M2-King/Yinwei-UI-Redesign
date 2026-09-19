import 'package:flutter/material.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/mobile/mobile_spatial_visualizer.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class MobileSpatialStage extends StatelessWidget {
  const MobileSpatialStage({
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xE0121214),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: YinweiColors.hairline),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: MobileSpatialVisualizer(
          pose: pose,
          presentation: presentation,
          overlayActive: overlayActive,
          speakers: speakers,
          onVisualPose: onVisualPose,
        ),
      ),
    );
  }
}
