import 'package:flutter/material.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/now_playing_panel.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/position_sidebar.dart';

/// Main window layout matching the approved Apple-design mockup.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  late SpatialParams _params;
  final TrackMeta _track = TrackMeta.demo;
  PlaybackMode _mode = PlaybackMode.spatial;
  bool _playing = false;
  Duration _position = const Duration(minutes: 1, seconds: 42);
  late final AnimationController _orbitClock;

  @override
  void initState() {
    super.initState();
    _params = SpatialParams();
    _orbitClock = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(() {
        if (_playing && _params.motion == MotionMode.orbit) {
          setState(() {});
        }
      });
    _orbitClock.repeat();
  }

  @override
  void dispose() {
    _orbitClock.dispose();
    super.dispose();
  }

  double get _visualAzimuth {
    final elapsed = Duration(
      milliseconds: (_orbitClock.lastElapsedDuration?.inMilliseconds ?? 0) +
          DateTime.now().millisecondsSinceEpoch % 1000000,
    );
    // Prefer wall-clock for continuous orbit while playing.
    if (_playing && _params.motion == MotionMode.orbit) {
      final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
      final turns = t * _params.orbitHz;
      var az = _params.azimuthDeg + turns * 360.0;
      az %= 360.0;
      if (az > 180) az -= 360;
      if (az <= -180) az += 360;
      return az;
    }
    return _params.visualAzimuthDeg(elapsed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _TitleBar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 5,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 12, 12, 12),
                    child: OrbitVisualizer(
                      azimuthDeg: _visualAzimuth,
                      active: _playing && _mode == PlaybackMode.spatial,
                    ),
                  ),
                ),
                Expanded(
                  flex: 5,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
                    child: NowPlayingPanel(
                      track: _track,
                      position: _position,
                      isPlaying: _playing,
                      playbackMode: _mode,
                      onSeek: (d) => setState(() => _position = d),
                      onPlayPause: () => setState(() => _playing = !_playing),
                      onModeChanged: (m) => setState(() => _mode = m),
                    ),
                  ),
                ),
                PositionSidebar(
                  params: _params,
                  onChanged: (p) => setState(() => _params = p),
                  onExport: _onExport,
                  onSavePreset: _onSavePreset,
                ),
              ],
            ),
          ),
          const _StatusBar(),
        ],
      ),
    );
  }

  void _onExport() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Export WAV — wire to spatial_core::export_wav next'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _onSavePreset() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Save Preset — local JSON presets coming next'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '音围',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
            ),
            Text(
              'Spatial Player',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: YinweiColors.hairline)),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: YinweiColors.success,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text('Offline', style: style),
          _dot(style),
          Text('Local file', style: style),
          _dot(style),
          Text('Headphones recommended', style: style),
        ],
      ),
    );
  }

  Widget _dot(TextStyle? style) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text('·', style: style),
      );
}
