import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/bridge/live_transfer.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/state/island_now_playing.dart';
import 'package:yinwei_player/state/window_mode.dart';
import 'package:yinwei_player/state/window_mode_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Compact Dynamic Island — Yinwei session or Windows SMTC + live HRTF.
class IslandBar extends StatelessWidget {
  const IslandBar({
    super.key,
    required this.controller,
    required this.windowMode,
    required this.systemMedia,
    required this.liveTransfer,
    this.onToggleLiveHrtf,
  });

  final EngineController controller;
  final WindowModeController windowMode;
  final SystemMediaService systemMedia;
  final LiveTransferController liveTransfer;
  final VoidCallback? onToggleLiveHrtf;

  @override
  Widget build(BuildContext context) {
    final expanded = windowMode.isExpandedIsland;
    final now = IslandNowPlaying.resolve(
      engine: controller,
      system: systemMedia.state,
      now: DateTime.now(),
      liveHrtfRunning: liveTransfer.running,
      liveHrtfHealthy: liveTransfer.captureHealthy,
      liveAzimuthDeg: liveTransfer.running ? liveTransfer.azimuthDeg() : 0,
      liveElevationDeg: liveTransfer.running ? liveTransfer.elevationDeg() : 0,
    );
    final warming = systemMedia.warming && !systemMedia.state.hasTrack;
    final displayTitle = warming ? '连接系统媒体…' : now.title;
    final err = liveTransfer.lastError;
    final displaySubtitle = warming
        ? '首次加载 WinRT（后台）'
        : (err != null && !liveTransfer.running ? err : now.subtitle);

    return MouseRegion(
      onEnter: (_) => windowMode.setPillHovered(true),
      onExit: (_) => windowMode.setPillHovered(false),
      child: ColoredBox(
        color: Colors.transparent,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(YinweiColors.islandRadius),
              onTap: expanded
                  ? null
                  : () {
                      windowMode.setPillHovered(true);
                      windowMode.expandIsland();
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: IslandGeometry.width - 16,
                height: expanded
                    ? IslandGeometry.expandedHeight - 12
                    : IslandGeometry.collapsedHeight - 12,
                padding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: expanded ? 8 : 6,
                ),
                decoration: BoxDecoration(
                  color: YinweiColors.islandPill,
                  borderRadius:
                      BorderRadius.circular(YinweiColors.islandRadius),
                  border: Border.all(
                    color: now.liveTransfer
                        ? YinweiColors.accent.withValues(alpha: 0.65)
                        : (now.yinweiSpatial
                            ? YinweiColors.success.withValues(alpha: 0.45)
                            : YinweiColors.islandBorder),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: expanded
                    ? _ExpandedBody(
                        now: now,
                        displayTitle: displayTitle,
                        displaySubtitle: displaySubtitle,
                        controller: controller,
                        windowMode: windowMode,
                        systemMedia: systemMedia,
                        liveTransfer: liveTransfer,
                        onToggleLiveHrtf: onToggleLiveHrtf,
                      )
                    : _CollapsedBody(
                        now: now,
                        displayTitle: displayTitle,
                        displaySubtitle: displaySubtitle,
                        controller: controller,
                        windowMode: windowMode,
                        systemMedia: systemMedia,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _togglePlayback({
  required IslandNowPlaying now,
  required EngineController controller,
  required SystemMediaService systemMedia,
}) async {
  if (now.source == IslandMediaSource.system) {
    await systemMedia.togglePlayPause();
  } else {
    await controller.togglePlay();
  }
}

class _CollapsedBody extends StatelessWidget {
  const _CollapsedBody({
    required this.now,
    required this.displayTitle,
    required this.displaySubtitle,
    required this.controller,
    required this.windowMode,
    required this.systemMedia,
  });

  final IslandNowPlaying now;
  final String displayTitle;
  final String displaySubtitle;
  final EngineController controller;
  final WindowModeController windowMode;
  final SystemMediaService systemMedia;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _MiniPose(
          azimuthDeg: now.azimuthDeg,
          envelopment: now.envelopment,
          orbiting: now.orbiting,
          active: now.liveTransfer || now.yinweiSpatial,
          dimmed: !now.liveTransfer &&
              !now.yinweiSpatial &&
              now.source != IslandMediaSource.yinwei,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              Text(
                displaySubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: now.liveTransfer
                          ? YinweiColors.accent
                          : (now.yinweiSpatial
                              ? YinweiColors.success
                              : YinweiColors.textSecondary),
                      fontSize: 10,
                    ),
              ),
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          tooltip: '播放 / 暂停',
          onPressed: () {
            windowMode.setPillHovered(true);
            _togglePlayback(
              now: now,
              controller: controller,
              systemMedia: systemMedia,
            );
          },
          icon: Icon(
            now.playing
                ? CupertinoIcons.pause_fill
                : CupertinoIcons.play_fill,
            size: 17,
            color: YinweiColors.textPrimary,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          tooltip: '展开岛',
          onPressed: () {
            windowMode.setPillHovered(true);
            windowMode.expandIsland();
          },
          icon: const Icon(CupertinoIcons.chevron_down, size: 14),
          color: YinweiColors.accent,
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          tooltip: '展开全窗',
          onPressed: () => windowMode.enterFull(),
          icon: const Icon(Icons.open_in_full_rounded, size: 15),
          color: YinweiColors.textSecondary,
        ),
      ],
    );
  }
}

class _ExpandedBody extends StatelessWidget {
  const _ExpandedBody({
    required this.now,
    required this.displayTitle,
    required this.displaySubtitle,
    required this.controller,
    required this.windowMode,
    required this.systemMedia,
    required this.liveTransfer,
    this.onToggleLiveHrtf,
  });

  final IslandNowPlaying now;
  final String displayTitle;
  final String displaySubtitle;
  final EngineController controller;
  final WindowModeController windowMode;
  final SystemMediaService systemMedia;
  final LiveTransferController liveTransfer;
  final VoidCallback? onToggleLiveHrtf;

  @override
  Widget build(BuildContext context) {
    final yinwei = now.source == IslandMediaSource.yinwei;
    return Column(
      children: [
        Row(
          children: [
            _MiniPose(
              azimuthDeg: now.azimuthDeg,
              envelopment: now.envelopment,
              orbiting: now.orbiting,
              active: now.liveTransfer || now.yinweiSpatial,
              dimmed: !now.liveTransfer && !now.yinweiSpatial && !yinwei,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  Text(
                    displaySubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: now.liveTransfer
                              ? YinweiColors.accent
                              : (now.yinweiSpatial
                                  ? YinweiColors.success
                                  : YinweiColors.textSecondary),
                        ),
                  ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              tooltip: '收起岛',
              onPressed: () => windowMode.collapseIsland(),
              icon: const Icon(CupertinoIcons.chevron_up, size: 14),
              color: YinweiColors.textSecondary,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              tooltip: '展开全窗',
              onPressed: () => windowMode.enterFull(),
              icon: const Icon(Icons.open_in_full_rounded, size: 15),
              color: YinweiColors.accent,
            ),
          ],
        ),
        const SizedBox(height: 2),
        _EnvelopmentMeter(
          value: now.envelopment,
          active: now.liveTransfer || now.yinweiSpatial,
        ),
        const Spacer(),
        Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
              onPressed: () => _togglePlayback(
                now: now,
                controller: controller,
                systemMedia: systemMedia,
              ),
              icon: Icon(
                now.playing
                    ? CupertinoIcons.pause_fill
                    : CupertinoIcons.play_fill,
                size: 18,
              ),
              color: YinweiColors.textPrimary,
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 10),
                ),
                child: Slider(
                  value: now.playhead.clamp(0.0, 1.0),
                  onChanged: yinwei
                      ? (v) {
                          final ms =
                              (v * controller.track.duration.inMilliseconds)
                                  .round();
                          controller.seek(Duration(milliseconds: ms));
                        }
                      : null,
                ),
              ),
            ),
            if (yinwei)
              _ModeChip(
                mode: controller.mode,
                onChanged: (m) => controller.setMode(m),
              )
            else
              GestureDetector(
                onTap: onToggleLiveHrtf,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: (liveTransfer.running || liveTransfer.starting)
                        ? YinweiColors.accent.withValues(alpha: 0.28)
                        : YinweiColors.panelElevated,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (liveTransfer.running || liveTransfer.starting)
                          ? YinweiColors.accent
                          : YinweiColors.hairline,
                    ),
                  ),
                  child: Text(
                    liveTransfer.toggleLabel(idle: '全窗Transfer'),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: (liveTransfer.running || liveTransfer.starting)
                              ? YinweiColors.accent
                              : YinweiColors.textSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _EnvelopmentMeter extends StatelessWidget {
  const _EnvelopmentMeter({required this.value, required this.active});

  final double value;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 36, right: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          minHeight: 3,
          backgroundColor: const Color(0x22FFFFFF),
          color: active ? YinweiColors.accent : YinweiColors.textSecondary,
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode, required this.onChanged});

  final PlaybackMode mode;
  final ValueChanged<PlaybackMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final spatial = mode == PlaybackMode.spatial;
    return GestureDetector(
      onTap: () => onChanged(
        spatial ? PlaybackMode.original : PlaybackMode.spatial,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: spatial
              ? YinweiColors.accent.withValues(alpha: 0.22)
              : YinweiColors.panelElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: spatial ? YinweiColors.accent : YinweiColors.hairline,
          ),
        ),
        child: Text(
          spatial ? 'Spatial' : 'Original',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color:
                    spatial ? YinweiColors.accent : YinweiColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
    );
  }
}

class _MiniPose extends StatelessWidget {
  const _MiniPose({
    required this.azimuthDeg,
    required this.envelopment,
    required this.orbiting,
    required this.active,
    required this.dimmed,
  });

  final double azimuthDeg;
  final double envelopment;
  final bool orbiting;
  final bool active;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: dimmed ? 0.35 : 1,
      child: CustomPaint(
        size: const Size(30, 30),
        painter: _MiniPosePainter(
          azimuthDeg: azimuthDeg,
          envelopment: envelopment,
          orbiting: orbiting,
          active: active,
        ),
      ),
    );
  }
}

class _MiniPosePainter extends CustomPainter {
  _MiniPosePainter({
    required this.azimuthDeg,
    required this.envelopment,
    required this.orbiting,
    required this.active,
  });

  final double azimuthDeg;
  final double envelopment;
  final bool orbiting;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2 - 1.5;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = YinweiColors.hairline,
    );

    if (envelopment > 0.02) {
      final sweep = envelopment.clamp(0.0, 1.0) * math.pi * 1.6;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        -math.pi / 2,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = (active ? YinweiColors.accent : YinweiColors.textSecondary)
              .withValues(alpha: 0.7),
      );
    }

    final rad = (azimuthDeg - 90) * math.pi / 180;
    final orbitBoost = orbiting ? 0.72 : 0.62;
    final dot = Offset(
      c.dx + r * orbitBoost * math.cos(rad),
      c.dy + r * orbitBoost * math.sin(rad),
    );
    canvas.drawCircle(
      dot,
      active ? 3.4 : 2.6,
      Paint()
        ..color = active ? YinweiColors.accent : YinweiColors.textSecondary,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniPosePainter old) =>
      old.azimuthDeg != azimuthDeg ||
      old.envelopment != envelopment ||
      old.orbiting != orbiting ||
      old.active != active;
}
