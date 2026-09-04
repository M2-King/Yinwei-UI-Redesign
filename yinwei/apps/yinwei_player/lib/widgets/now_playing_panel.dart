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
  final ValueChanged<Duration> onSeek;
  final VoidCallback onPlayPause;
  final ValueChanged<PlaybackMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 220,
          height: 220,
          decoration: BoxDecoration(
            color: YinweiColors.panelElevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: YinweiColors.hairline),
            image: track.coverPath != null
                ? DecorationImage(
                    image: AssetImage(track.coverPath!),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: track.coverPath == null
              ? const Icon(CupertinoIcons.music_note_2,
                  size: 64, color: YinweiColors.textSecondary)
              : null,
        ),
        const SizedBox(height: 28),
        Text(track.title, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 6),
        Text(track.artist, style: theme.textTheme.bodySmall),
        if (track.album.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(track.album, style: theme.textTheme.labelSmall),
        ],
        const SizedBox(height: 28),
        _Scrubber(
          position: position,
          duration: track.duration,
          onSeek: onSeek,
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: () {},
              icon: const Icon(CupertinoIcons.backward_fill, size: 22),
              color: YinweiColors.textPrimary,
            ),
            const SizedBox(width: 12),
            IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: YinweiColors.panelElevated,
                foregroundColor: YinweiColors.textPrimary,
                minimumSize: const Size(56, 56),
              ),
              onPressed: onPlayPause,
              icon: Icon(
                isPlaying ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              onPressed: () {},
              icon: const Icon(CupertinoIcons.forward_fill, size: 22),
              color: YinweiColors.textPrimary,
            ),
          ],
        ),
        const SizedBox(height: 22),
        _ModeSegmented(
          mode: playbackMode,
          onChanged: onModeChanged,
        ),
      ],
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
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final maxMs = duration.inMilliseconds.toDouble().clamp(1, double.infinity);
    final value = position.inMilliseconds.clamp(0, duration.inMilliseconds);

    return Column(
      children: [
        Slider(
          value: value.toDouble(),
          max: maxMs,
          onChanged: (v) => onSeek(Duration(milliseconds: v.round())),
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
      thumbColor: YinweiColors.accent,
      children: {
        PlaybackMode.original: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            'Original',
            style: TextStyle(
              color: mode == PlaybackMode.original
                  ? Colors.white
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
                  ? Colors.white
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
