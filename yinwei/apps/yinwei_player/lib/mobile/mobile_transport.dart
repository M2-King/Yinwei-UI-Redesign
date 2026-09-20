import 'package:flutter/material.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class MobileTransport extends StatelessWidget {
  const MobileTransport({
    super.key,
    required this.controller,
    this.onTogglePlay,
    this.onOpen,
  });

  final EngineController controller;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 48,
            child: FilledButton(
              key: const Key('ios-play-button'),
              onPressed: !controller.hasOpenedFile
                  ? null
                  : (onTogglePlay ?? () => controller.togglePlay()),
              style: FilledButton.styleFrom(
                backgroundColor: YinweiColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(controller.playing ? 'Pause' : 'Play'),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 48,
          child: OutlinedButton(
            key: const Key('ios-open-file-button'),
            onPressed: onOpen,
            style: OutlinedButton.styleFrom(
              foregroundColor: YinweiColors.textPrimary,
              side: const BorderSide(color: YinweiColors.hairlineStrong),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ],
    );
  }
}
