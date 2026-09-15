import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class NowPlayingPanel extends StatelessWidget {
  const NowPlayingPanel({
    super.key,
    required this.track,
    required this.position,
    required this.isPlaying,
    required this.playbackMode,
    required this.onSeek,
    required this.onPlayPause,
    required this.onModeChanged,
  });

  final TrackMeta track;
  final Duration position;
  final bool isPlaying;
  final PlaybackMode playbackMode;
  final ValueChanged<Duration>? onSeek;
  final VoidCallback onPlayPause;
  final ValueChanged<PlaybackMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final art = constraints.maxHeight < 560
            ? (constraints.maxHeight < 480 ? 140.0 : 170.0)
            : 200.0;
        final gap = constraints.maxHeight < 560 ? 16.0 : 26.0;

        return Center(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: art,
                      height: art,
                      decoration: BoxDecoration(
                        color: YinweiColors.panelElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: YinweiColors.hairline),
                        image: track.coverPath != null
                            ? DecorationImage(
                                image: AssetImage(track.coverPath!),
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      child: track.coverPath == null
                          ? Icon(CupertinoIcons.music_note_2,
                              size: art * 0.26,
                              color: YinweiColors.textSecondary)
                          : null,
                    ),
                    SizedBox(height: gap),
                    Text(
                      track.title,
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(letterSpacing: -0.4),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(track.artist, style: theme.textTheme.bodySmall),
                    if (track.album.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(track.album, style: theme.textTheme.labelSmall),
                    ],
                    SizedBox(height: gap),
                    _Scrubber(
                      position: position,
                      duration: track.duration,
                      onSeek: onSeek,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          onPressed: () {},
                          icon: const Icon(CupertinoIcons.backward_fill, size: 20),
                          color: YinweiColors.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        IconButton.filled(
                          style: IconButton.styleFrom(
                            backgroundColor: YinweiColors.panelElevated,
                            foregroundColor: YinweiColors.textPrimary,
                            minimumSize: const Size(52, 52),
                          ),
                          onPressed: onPlayPause,
                          icon: Icon(
                            isPlaying
                                ? CupertinoIcons.pause_fill
                                : CupertinoIcons.play_fill,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          onPressed: () {},
                          icon: const Icon(CupertinoIcons.forward_fill, size: 20),
                          color: YinweiColors.textSecondary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _ModeSegmented(
                      mode: playbackMode,
                      onChanged: onModeChanged,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Scrubber extends StatelessWidget {
  const _Scrubber({
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration>? onSeek;

  @override
  Widget build(BuildContext context) {
    final maxMs =
        duration.inMilliseconds.toDouble().clamp(1.0, double.infinity).toDouble();
    final value = position.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toDouble();

    return Column(
      children: [
        Slider(
          value: value,
          max: maxMs,
          onChanged: onSeek == null
              ? null
              : (v) => onSeek!(Duration(milliseconds: v.round())),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmt(position), style: Theme.of(context).textTheme.labelSmall),
              Text(_fmt(duration), style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _ModeSegmented extends StatelessWidget {
  const _ModeSegmented({required this.mode, required this.onChanged});

  final PlaybackMode mode;
  final ValueChanged<PlaybackMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return CupertinoSlidingSegmentedControl<PlaybackMode>(
      groupValue: mode,
      backgroundColor: YinweiColors.panelElevated,
      thumbColor: const Color(0xFF2C2C2E),
      children: {
        PlaybackMode.original: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            'Original',
            style: TextStyle(
              color: mode == PlaybackMode.original
                  ? YinweiColors.textPrimary
                  : YinweiColors.textSecondary,
              fontWeight: FontWeight.w500,
              fontSize: 13,
            ),
          ),
        ),
        PlaybackMode.spatial: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            'Spatial',
            style: TextStyle(
              color: mode == PlaybackMode.spatial
                  ? YinweiColors.textPrimary
                  : YinweiColors.textSecondary,
              fontWeight: FontWeight.w500,
              fontSize: 13,
            ),
          ),
        ),
      },
      onValueChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}
