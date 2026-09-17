import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Compact workstation transport. Playback supports the spatial workspace;
/// it is not a competing music-player surface.
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
    this.arrayMode = ArrayMode.off,
    this.arraySupported = false,
    this.onArrayMode,
  });

  final TrackMeta track;
  final Duration position;
  final bool isPlaying;
  final PlaybackMode playbackMode;
  final ArrayMode arrayMode;
  final bool arraySupported;
  final ValueChanged<Duration>? onSeek;
  final VoidCallback onPlayPause;
  final ValueChanged<PlaybackMode> onModeChanged;
  final ValueChanged<ArrayMode>? onArrayMode;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: YinweiLayout.transportHeight,
      padding: const EdgeInsets.fromLTRB(12, 0, 14, 0),
      decoration: const BoxDecoration(
        color: YinweiColors.panel,
        border: Border(top: BorderSide(color: YinweiColors.hairline)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tight = constraints.maxWidth < 760;
          final compact = constraints.maxWidth < 980;
          return Row(
            children: [
              if (!tight) ...[
                _Artwork(track: track),
                const SizedBox(width: 10),
              ],
              Flexible(
                flex: compact ? 2 : 3,
                child: _Identity(
                  track: track,
                  showAlbum: !compact && track.album.isNotEmpty,
                ),
              ),
              const SizedBox(width: 8),
              _PlayButton(
                isPlaying: isPlaying,
                onPressed: onPlayPause,
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 6,
                child: _Scrubber(
                  position: position,
                  duration: track.duration,
                  onSeek: onSeek,
                ),
              ),
              const SizedBox(width: 12),
              _ModeSwitch<PlaybackMode>(
                value: playbackMode,
                labels: const {
                  PlaybackMode.original: 'Original',
                  PlaybackMode.spatial: 'Spatial',
                },
                onChanged: onModeChanged,
              ),
              if (arraySupported && onArrayMode != null) ...[
                const SizedBox(width: 8),
                _ModeSwitch<ArrayMode>(
                  value: arrayMode,
                  labels: const {
                    ArrayMode.off: 'Point',
                    ArrayMode.stereo2: '2.0',
                  },
                  onChanged: onArrayMode!,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.track});

  final TrackMeta track;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('transport-artwork'),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: YinweiColors.well,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: YinweiColors.hairline),
        image: track.coverPath != null
            ? DecorationImage(
                image: AssetImage(track.coverPath!),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: track.coverPath == null
          ? const Icon(
              CupertinoIcons.music_note_2,
              size: 12,
              color: YinweiColors.textTertiary,
            )
          : null,
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({required this.track, required this.showAlbum});

  final TrackMeta track;
  final bool showAlbum;

  @override
  Widget build(BuildContext context) {
    final secondary = showAlbum
        ? '${track.artist}  ·  ${track.album}'
        : track.artist;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.15,
            color: YinweiColors.textPrimary,
          ),
        ),
        if (secondary.isNotEmpty) ...[
          const SizedBox(height: 1),
          Text(
            secondary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10.5,
              color: YinweiColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.isPlaying, required this.onPressed});

  final bool isPlaying;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Play / Pause',
      child: Material(
        color: YinweiColors.well,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: YinweiColors.hairline),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              isPlaying ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
              size: 15,
              color: YinweiColors.textPrimary,
            ),
          ),
        ),
      ),
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
    const timeStyle = TextStyle(
      fontSize: 10.5,
      fontFeatures: [FontFeature.tabularFigures()],
      color: YinweiColors.textTertiary,
    );

    return Row(
      children: [
        Text(_fmt(position), style: timeStyle),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              activeTrackColor: const Color(0x66F5F5F7),
              inactiveTrackColor: const Color(0x18FFFFFF),
              thumbColor: YinweiColors.textPrimary,
              overlayColor: const Color(0x22FFFFFF),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4.5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
            ),
            child: Slider(
              value: value,
              max: maxMs,
              onChanged: onSeek == null
                  ? null
                  : (v) => onSeek!(Duration(milliseconds: v.round())),
            ),
          ),
        ),
        Text(_fmt(duration), style: timeStyle),
      ],
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _ModeSwitch<T> extends StatelessWidget {
  const _ModeSwitch({
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> labels;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: YinweiColors.well,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: YinweiColors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in labels.entries)
            _ModeCell(
              label: entry.value,
              selected: entry.key == value,
              onTap: () => onChanged(entry.key),
            ),
        ],
      ),
    );
  }
}

class _ModeCell extends StatelessWidget {
  const _ModeCell({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2C2C30) : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected
                ? YinweiColors.textPrimary
                : YinweiColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
