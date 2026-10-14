import 'package:flutter/material.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class MobileTransport extends StatefulWidget {
  const MobileTransport({
    super.key,
    required this.controller,
    this.onTogglePlay,
    this.onOpen,
    this.onExport,
    this.onSeek,
  });

  final EngineController controller;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onOpen;
  final VoidCallback? onExport;
  final ValueChanged<Duration>? onSeek;

  @override
  State<MobileTransport> createState() => _MobileTransportState();
}

class _MobileTransportState extends State<MobileTransport> {
  double? _dragPositionMs;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final durationMs = controller.track.duration.inMilliseconds;
    final enginePositionMs = controller.position.inMilliseconds
        .clamp(0, durationMs <= 0 ? 0 : durationMs);
    final positionMs = (_dragPositionMs ?? enginePositionMs.toDouble())
        .clamp(0, durationMs <= 0 ? 0 : durationMs)
        .toDouble();
    final canSeek = controller.hasOpenedFile && durationMs > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (controller.hasOpenedFile) ...[
          Row(
            children: [
              Text(
                _time(Duration(milliseconds: positionMs.round())),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Expanded(
                child: Slider(
                  key: const Key('ios-playback-position'),
                  value: durationMs <= 0 ? 0 : positionMs.toDouble(),
                  max: durationMs <= 0 ? 1 : durationMs.toDouble(),
                  onChangeStart: canSeek
                      ? (value) => setState(() => _dragPositionMs = value)
                      : null,
                  onChanged: canSeek
                      ? (value) => setState(() => _dragPositionMs = value)
                      : null,
                  onChangeEnd: canSeek
                      ? (value) {
                          widget.onSeek?.call(
                            Duration(milliseconds: value.round()),
                          );
                          setState(() => _dragPositionMs = null);
                        }
                      : null,
                ),
              ),
              Text(
                _time(controller.track.duration),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
          const SizedBox(height: 2),
        ],
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: FilledButton(
                  key: const Key('ios-play-button'),
                  onPressed: !controller.hasOpenedFile
                      ? null
                      : (widget.onTogglePlay ?? () => controller.togglePlay()),
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
                onPressed: widget.onOpen,
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
            const SizedBox(width: 10),
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton.outlined(
                key: const Key('ios-export-file-button'),
                tooltip: 'Export processed WAV',
                onPressed: controller.hasOpenedFile ? widget.onExport : null,
                icon: const Icon(Icons.ios_share_rounded, size: 20),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _time(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
