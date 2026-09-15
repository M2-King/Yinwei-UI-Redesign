import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/bridge/live_transfer.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Full-window strip: live SMTC monitor + WASAPI→HRTF Transfer control.
///
/// Labels: file Spatial is never shown here. HRTF LIVE requires healthy
/// capture (energy slope), not a one-shot silent frame count.
class SystemLiveMonitorBar extends StatelessWidget {
  const SystemLiveMonitorBar({
    super.key,
    required this.systemMedia,
    required this.liveTransfer,
    required this.onToggleLiveHrtf,
    this.onTogglePlayPause,
    this.onSelectOutput,
  });

  final SystemMediaService systemMedia;
  final LiveTransferController liveTransfer;
  final VoidCallback onToggleLiveHrtf;
  final VoidCallback? onTogglePlayPause;
  final ValueChanged<String>? onSelectOutput;

  @override
  Widget build(BuildContext context) {
    final s = systemMedia.state;
    final theme = Theme.of(context);
    final warming = systemMedia.warming && !s.hasTrack;
    final running = liveTransfer.running;
    final starting = liveTransfer.starting;
    final healthy = liveTransfer.captureHealthy;
    final err = liveTransfer.lastError;

    String title;
    String subtitle;
    if (warming) {
      title = '连接系统媒体…';
      subtitle = 'SMTC 后台加载中';
    } else if (s.hasTrack) {
      title = s.title;
      final app = s.processName.isNotEmpty
          ? s.processName
          : (s.sourceApp.isEmpty ? 'System' : s.sourceApp);
      if (running) {
        subtitle = healthy
            ? 'HRTF LIVE · $app · pid ${s.pid} · az ${liveTransfer.azimuthDeg().toStringAsFixed(0)}° · energy ${liveTransfer.energyFrames}'
            : 'HRTF ON · 环回静音间隙 · $app · pid ${s.pid}';
      } else if (starting) {
        subtitle = 'HRTF ON · 连接中 · $app · pid ${s.pid}';
      } else {
        subtitle = s.playing
            ? 'SMTC · $app · pid ${s.pid} · 音乐走扬声器，湿声选耳机（勿静音源 App）'
            : 'SMTC · $app paused · pid ${s.pid}';
      }
    } else {
      title = '未检测到系统正在播放的媒体';
      subtitle = err ?? '播放汽水音乐 / Spotify 后会出现在这里';
    }
    if (err != null && !running) {
      subtitle = err;
    }

    final accentLive = running || starting;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: YinweiColors.panelElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: accentLive
              ? YinweiColors.accent.withValues(alpha: 0.7)
              : YinweiColors.hairline,
        ),
      ),
      child: Row(
        children: [
          Icon(
            accentLive
                ? Icons.surround_sound_rounded
                : (s.playing
                    ? Icons.graphic_eq_rounded
                    : Icons.sensors_rounded),
            size: 22,
            color: accentLive
                ? YinweiColors.accent
                : (s.playing
                    ? YinweiColors.success
                    : YinweiColors.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: (err != null && !running)
                        ? const Color(0xFFFF8A80)
                        : (accentLive
                            ? YinweiColors.accent
                            : YinweiColors.textSecondary),
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          if (s.hasTrack) ...[
            _WetOutputPicker(
              liveTransfer: liveTransfer,
              onSelectOutput: onSelectOutput,
            ),
            IconButton(
              tooltip: '系统播放/暂停',
              onPressed: onTogglePlayPause,
              icon: Icon(
                s.playing
                    ? CupertinoIcons.pause_fill
                    : CupertinoIcons.play_fill,
                size: 18,
                color: YinweiColors.textPrimary,
              ),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: onToggleLiveHrtf,
              style: FilledButton.styleFrom(
                backgroundColor: accentLive
                    ? YinweiColors.accent
                    : YinweiColors.panel,
                foregroundColor:
                    accentLive ? Colors.black : YinweiColors.textPrimary,
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              child: Text(
                liveTransfer.toggleLabel(idle: '真实Transfer'),
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WetOutputPicker extends StatelessWidget {
  const _WetOutputPicker({
    required this.liveTransfer,
    this.onSelectOutput,
  });

  final LiveTransferController liveTransfer;
  final ValueChanged<String>? onSelectOutput;

  @override
  Widget build(BuildContext context) {
    final devices = liveTransfer.outputDevices;
    final selected = liveTransfer.selectedOutput;
    final label = selected.isEmpty ? '湿声：默认输出' : '湿声：${_short(selected)}';
    return PopupMenuButton<String>(
      tooltip: 'Yinwei 湿声输出（选耳机）。音乐 App 请在系统音量合成器走扬声器；可静音扬声器设备，勿静音源 App。',
      onSelected: onSelectOutput,
      itemBuilder: (context) {
        return [
          const PopupMenuItem(
            value: '',
            child: Text('默认输出'),
          ),
          ...devices.map(
            (d) => PopupMenuItem(
              value: d,
              child: Text(d, overflow: TextOverflow.ellipsis),
            ),
          ),
        ];
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.headphones_rounded,
              size: 16,
              color: selected.isEmpty
                  ? YinweiColors.textSecondary
                  : YinweiColors.accent,
            ),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _short(String name) {
    if (name.length <= 18) return name;
    return '${name.substring(0, 16)}…';
  }
}
