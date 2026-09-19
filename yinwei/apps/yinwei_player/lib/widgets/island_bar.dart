import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/bridge/live_transfer.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/state/island_now_playing.dart';
import 'package:yinwei_player/state/window_mode.dart';
import 'package:yinwei_player/state/window_mode_controller.dart';

const _ink = Color(0xFF101112);
const _line = Color(0xFF292A2D);
const _muted = Color(0xFF8B8C92);
const _blue = Color(0xFF81ADDE);

/// A presentation surface over the existing controllers. No native audio writes.
class IslandBar extends StatelessWidget {
  const IslandBar(
      {super.key,
      required this.controller,
      required this.windowMode,
      required this.systemMedia,
      required this.liveTransfer,
      this.onToggleLiveHrtf,
      this.onPlaybackMode,
      this.onArrayMode,
      this.miniController,
      this.pointReadout});
  final EngineController controller;
  final WindowModeController windowMode;
  final SystemMediaService systemMedia;
  final LiveTransferController liveTransfer;
  final VoidCallback? onToggleLiveHrtf;
  final ValueChanged<PlaybackMode>? onPlaybackMode;
  final ValueChanged<ArrayMode>? onArrayMode;
  final Widget? miniController;
  final String? pointReadout;

  @override
  Widget build(BuildContext context) {
    final now = IslandNowPlaying.resolve(
        engine: controller,
        system: systemMedia.state,
        now: DateTime.now(),
        liveHrtfRunning: liveTransfer.running,
        liveHrtfHealthy: liveTransfer.captureHealthy,
        liveAzimuthDeg: liveTransfer.azimuthDeg(),
        liveElevationDeg: liveTransfer.elevationDeg());
    final expanded = windowMode.isExpandedIsland;
    final dormant = windowMode.dormant && !expanded;
    final hover = windowMode.interaction == IslandInteraction.hover;
    final spatial = controller.mode == PlaybackMode.spatial &&
        (!now.usesSystemMedia || liveTransfer.running);
    final stereo = spatial && controller.array.mode == ArrayMode.stereo2;
    final label = spatial ? (stereo ? 'Stereo 2.0' : 'Point') : 'Original';
    final caption = now.liveTransfer
        ? 'HRTF Live · $label'
        : now.usesSystemMedia
            ? 'System media · $label'
            : spatial
                ? 'HRTF · $label'
                : label;
    final capsule =
        IslandGeometry.capsule(expanded: expanded, dormant: dormant);
    final reduced = MediaQuery.disableAnimationsOf(context);
    Widget button(
            String key, IconData icon, String tooltip, VoidCallback? action,
            {bool filled = false}) =>
        IconButton(
            key: ValueKey(key),
            tooltip: tooltip,
            onPressed: action,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            style: IconButton.styleFrom(
                backgroundColor:
                    filled ? const Color(0xFF292A2C) : Colors.transparent,
                foregroundColor: const Color(0xFFE5E5E8),
                disabledForegroundColor: _muted.withValues(alpha: .3)),
            icon: Icon(icon, size: 15));
    final toggle = now.source == IslandMediaSource.idle
        ? null
        : () {
            if (now.usesSystemMedia) {
              systemMedia.togglePlayPause();
            } else {
              controller.togglePlay();
            }
          };
    final spatialBadge = TextButton(
        key: const ValueKey('island-spatial-badge'),
        onPressed: spatial && miniController != null
            ? () => windowMode.setMiniOpen(!windowMode.miniOpen)
            : null,
        style: TextButton.styleFrom(
            foregroundColor: now.liveTransfer ? _blue : const Color(0xFFB6C7DA),
            backgroundColor:
                spatial ? const Color(0xFF17202A) : const Color(0xFF202123),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
                side: BorderSide(
                    color: spatial ? const Color(0xFF2C3C50) : _line))),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(now.liveTransfer ? 'HRTF LIVE · $label' : label,
                  style: const TextStyle(fontSize: 10, letterSpacing: .8)),
              if (spatial)
                Text(
                    stereo
                        ? 'L / R · ${controller.array.matrixLinked ? 'Linked' : 'Independent'}'
                        : pointReadout ??
                            '${controller.params.azimuthDeg.round()}° · ${controller.params.elevationDeg.round()}° · ${controller.params.distanceM.toStringAsFixed(1)} m',
                    style: const TextStyle(fontSize: 9, height: 1.7)),
            ]));
    final title = Text(dormant ? '音围 Yinwei' : now.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFFE5E5E8)));
    final icon = Container(
        width: expanded ? 44 : 28,
        height: expanded ? 44 : 28,
        decoration: BoxDecoration(
            color: const Color(0xFF232428),
            borderRadius: BorderRadius.circular(expanded ? 12 : 10)),
        child: Icon(
            stereo
                ? CupertinoIcons.hifispeaker_fill
                : dormant
                    ? CupertinoIcons.waveform_path
                    : now.usesSystemMedia
                        ? CupertinoIcons.music_note
                        : CupertinoIcons.music_albums,
            size: expanded ? 21 : 15,
            color: _muted));
    return Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: IslandGeometry.width * windowMode.contentScale,
          height: IslandGeometry.collapsedHeight * windowMode.contentScale,
          child: FittedBox(
            alignment: Alignment.topLeft,
            fit: BoxFit.contain,
            child: SizedBox(
                width: IslandGeometry.width,
                height: IslandGeometry.collapsedHeight,
                child: Stack(children: [
                  Positioned.fromRect(
                      rect: capsule,
                      child: MouseRegion(
                        onEnter: (_) => windowMode.setPillHovered(true),
                        onExit: (_) => windowMode.setPillHovered(false),
                        child: AnimatedContainer(
                          duration: reduced
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          decoration: BoxDecoration(
                              color: hover ? const Color(0xFF161719) : _ink,
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                  color:
                                      hover ? const Color(0xFF414247) : _line),
                              boxShadow: const [
                                BoxShadow(
                                    color: Color(0x65000000),
                                    blurRadius: 18,
                                    offset: Offset(0, 8))
                              ]),
                          child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                key: const ValueKey('island-capsule'),
                                borderRadius: BorderRadius.circular(28),
                                onTap: expanded
                                    ? null
                                    : () => windowMode.expandIsland(),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: expanded ? 16 : 14,
                                      vertical: expanded ? 12 : 6),
                                  child: expanded
                                      ? Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                              Row(children: [
                                                icon,
                                                const SizedBox(width: 12),
                                                Expanded(
                                                    child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                      title,
                                                      const SizedBox(height: 4),
                                                      Text(
                                                          now.source ==
                                                                  IslandMediaSource
                                                                      .idle
                                                              ? 'Ready when you are'
                                                              : now.artist
                                                                      .isEmpty
                                                                  ? (now.usesSystemMedia
                                                                      ? 'System media'
                                                                      : 'Local audio')
                                                                  : now.artist,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style:
                                                              const TextStyle(
                                                                  fontSize: 11,
                                                                  color:
                                                                      _muted)),
                                                    ])),
                                                const SizedBox(width: 12),
                                                SizedBox(
                                                    width: 135,
                                                    child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .end,
                                                        children: [
                                                          const Text('OUTPUT',
                                                              style: TextStyle(
                                                                  fontSize: 8,
                                                                  letterSpacing:
                                                                      1,
                                                                  color:
                                                                      _muted)),
                                                          Text(
                                                              liveTransfer.running &&
                                                                      liveTransfer
                                                                          .selectedOutput
                                                                          .isNotEmpty
                                                                  ? liveTransfer
                                                                      .selectedOutput
                                                                  : 'System default',
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                  fontSize: 10,
                                                                  color:
                                                                      _muted)),
                                                        ])),
                                                button(
                                                    'island-collapse',
                                                    CupertinoIcons.chevron_up,
                                                    'Collapse',
                                                    () => windowMode
                                                        .collapseIsland()),
                                                button(
                                                    'island-full',
                                                    Icons.open_in_full_rounded,
                                                    'Open Yinwei',
                                                    () =>
                                                        windowMode.enterFull()),
                                              ]),
                                              const Padding(
                                                  padding: EdgeInsets.symmetric(
                                                      vertical: 7),
                                                  child: Divider(
                                                      height: 1, color: _line)),
                                              Row(children: [
                                                if (now.source !=
                                                    IslandMediaSource.idle) ...[
                                                  button(
                                                      'island-play',
                                                      now.playing
                                                          ? CupertinoIcons
                                                              .pause_fill
                                                          : CupertinoIcons
                                                              .play_fill,
                                                      'Play / pause',
                                                      toggle,
                                                      filled: true),
                                                  const SizedBox(width: 8),
                                                  Text(_time(now.position),
                                                      style: const TextStyle(
                                                          fontSize: 10,
                                                          color: _muted)),
                                                  Expanded(
                                                      child: SliderTheme(
                                                          data: SliderTheme.of(context).copyWith(
                                                              trackHeight: 2,
                                                              thumbShape:
                                                                  const RoundSliderThumbShape(
                                                                      enabledThumbRadius:
                                                                          3),
                                                              overlayShape:
                                                                  const RoundSliderOverlayShape(
                                                                      overlayRadius:
                                                                          8)),
                                                          child: Slider(
                                                              key: const ValueKey(
                                                                  'island-seek'),
                                                              value: now
                                                                  .playhead
                                                                  .clamp(0, 1),
                                                              activeColor:
                                                                  const Color(
                                                                      0xFFB7B7BC),
                                                              inactiveColor:
                                                                  _line,
                                                              onChanged: now.source == IslandMediaSource.yinwei &&
                                                                      now.duration >
                                                                          Duration.zero
                                                                  ? (v) => controller.seek(Duration(milliseconds: (v * now.duration.inMilliseconds).round()))
                                                                  : null))),
                                                  Text(_time(now.duration),
                                                      style: const TextStyle(
                                                          fontSize: 10,
                                                          color: _muted)),
                                                  const SizedBox(width: 12),
                                                ] else
                                                  const Spacer(),
                                                spatialBadge,
                                              ]),
                                              const Spacer(),
                                              Row(children: [
                                                for (final value in [
                                                  'Original',
                                                  'Point',
                                                  'Stereo 2.0'
                                                ])
                                                  Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              right: 14),
                                                      child: GestureDetector(
                                                        key: ValueKey(
                                                            'island-context-$value'),
                                                        onTap: () {
                                                          windowMode
                                                              .setMiniOpen(
                                                                  false);
                                                          if (value ==
                                                              'Original') {
                                                            onPlaybackMode?.call(
                                                                PlaybackMode
                                                                    .original);
                                                          } else {
                                                            onPlaybackMode?.call(
                                                                PlaybackMode
                                                                    .spatial);
                                                            onArrayMode?.call(
                                                                value == 'Point'
                                                                    ? ArrayMode
                                                                        .off
                                                                    : ArrayMode
                                                                        .stereo2);
                                                          }
                                                        },
                                                        child: Text(value,
                                                            style: TextStyle(
                                                                fontSize: 10,
                                                                color: value ==
                                                                        label
                                                                    ? const Color(
                                                                        0xFFDFE3E9)
                                                                    : _muted)),
                                                      )),
                                                const Spacer(),
                                                if (now.usesSystemMedia)
                                                  GestureDetector(
                                                      key: const ValueKey(
                                                          'island-live-toggle'),
                                                      onTap: onToggleLiveHrtf,
                                                      child: Text(
                                                          liveTransfer.toggleLabel(
                                                              idle:
                                                                  'Enable HRTF'),
                                                          style: TextStyle(
                                                              fontSize: 10,
                                                              color: now
                                                                      .liveTransfer
                                                                  ? _blue
                                                                  : _muted))),
                                              ]),
                                            ])
                                      : Row(children: [
                                          icon,
                                          const SizedBox(width: 10),
                                          Expanded(
                                              child: Column(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                title,
                                                if (!dormant)
                                                  Text(caption,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                          fontSize: 9,
                                                          height: 1.6,
                                                          letterSpacing: .4,
                                                          color:
                                                              now.liveTransfer
                                                                  ? _blue
                                                                  : _muted))
                                              ])),
                                          if (dormant)
                                            const Text('Ready',
                                                style: TextStyle(
                                                    fontSize: 10,
                                                    color: _muted))
                                          else ...[
                                            if (hover)
                                              Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          right: 10),
                                                  child: Text(
                                                      stereo
                                                          ? 'L / R'
                                                          : now.liveTransfer
                                                              ? 'LIVE'
                                                              : 'HRTF',
                                                      style: TextStyle(
                                                          fontSize: 9,
                                                          color: spatial
                                                              ? _blue
                                                              : _muted))),
                                            if (now.playing && !hover)
                                              const Padding(
                                                  padding: EdgeInsets.only(
                                                      right: 14),
                                                  child: Icon(
                                                      CupertinoIcons.waveform,
                                                      size: 17,
                                                      color: _muted)),
                                            button(
                                                'island-play',
                                                now.playing
                                                    ? CupertinoIcons.pause_fill
                                                    : CupertinoIcons.play_fill,
                                                'Play / pause',
                                                toggle,
                                                filled: true),
                                          ],
                                        ]),
                                ),
                              )),
                        ),
                      )),
                  if (windowMode.miniOpen && spatial && miniController != null)
                    Positioned.fromRect(
                        rect: IslandGeometry.miniRect, child: miniController!),
                ])),
          ),
        ));
  }

  static String _time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
