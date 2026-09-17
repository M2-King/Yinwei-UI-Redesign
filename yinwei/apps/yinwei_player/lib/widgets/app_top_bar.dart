import 'package:flutter/material.dart';
import 'package:yinwei_player/bridge/live_transfer.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/system_live_monitor_bar.dart';

/// Compact session strip above the spatial workspace.
class AppTopBar extends StatelessWidget {
  const AppTopBar({
    super.key,
    required this.systemMedia,
    required this.liveTransfer,
    required this.onToggleLiveHrtf,
    required this.playbackMode,
    required this.arrayEnabled,
    this.onTogglePlayPause,
    this.onSelectOutput,
  });

  final SystemMediaService systemMedia;
  final LiveTransferController liveTransfer;
  final VoidCallback onToggleLiveHrtf;
  final VoidCallback? onTogglePlayPause;
  final ValueChanged<String>? onSelectOutput;
  final PlaybackMode playbackMode;
  final bool arrayEnabled;

  @override
  Widget build(BuildContext context) {
    final spatial = playbackMode == PlaybackMode.spatial;
    final session = spatial
        ? (arrayEnabled ? 'Spatial (2.0)' : 'Spatial (Point)')
        : 'Original';

    return Container(
      height: YinweiLayout.topBarHeight,
      padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: YinweiColors.hairline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SystemLiveMonitorBar(
              compact: true,
              systemMedia: systemMedia,
              liveTransfer: liveTransfer,
              onToggleLiveHrtf: onToggleLiveHrtf,
              onTogglePlayPause: onTogglePlayPause,
              onSelectOutput: onSelectOutput,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: YinweiColors.panelElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: YinweiColors.hairline),
            ),
            child: Text(
              session,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: YinweiColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
