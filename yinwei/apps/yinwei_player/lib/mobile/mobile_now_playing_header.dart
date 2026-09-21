import 'package:flutter/material.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class MobileNowPlayingHeader extends StatelessWidget {
  const MobileNowPlayingHeader({
    super.key,
    required this.controller,
    required this.backend,
    required this.status,
    this.loadError,
    this.androidCaptureOnly = false,
  });

  final EngineController controller;
  final EngineBackend backend;
  final String status;
  final String? loadError;
  final bool androidCaptureOnly;

  @override
  Widget build(BuildContext context) {
    final native = backend == EngineBackend.native;
    final title = controller.hasOpenedFile ? controller.track.title : 'Ready';
    final subtitle = controller.hasOpenedFile
        ? controller.track.artist
        : 'Open a file';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '音围  Yinwei',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 2.2,
                color: YinweiColors.textTertiary,
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 10),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 4),
        Text(
          '$subtitle  ·  $status',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        Text(
          _backendLine(native),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: native ? YinweiColors.success : YinweiColors.textTertiary,
              ),
        ),
      ],
    );
  }

  String _backendLine(bool native) {
    if (androidCaptureOnly) {
      final label = controller.backendLabel;
      if (label.toLowerCase().contains('a1')) return label;
      return 'Android A1 capture-only · spatial_core not connected';
    }
    if (native) return controller.backendLabel;
    return 'Mock · ${loadError ?? 'spatial_core not linked'}';
  }
}
