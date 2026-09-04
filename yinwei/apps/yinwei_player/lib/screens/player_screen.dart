import 'package:flutter/material.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/now_playing_panel.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/position_sidebar.dart';

/// Main window — wired to [EngineController] (P2.3).
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, this.controller});

  final EngineController? controller;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final EngineController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = widget.controller ?? EngineController();
    _ctrl.addListener(_onChange);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onChange);
    if (widget.controller == null) {
      _ctrl.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              _TitleBar(onOpen: _onOpen),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 12, 12, 12),
                        child: OrbitVisualizer(
                          azimuthDeg: c.azimuthDeg,
                          elevationDeg: c.params.elevationDeg,
                          orbiting: c.params.motion == MotionMode.orbit &&
                              c.mode == PlaybackMode.spatial,
                          active: c.mode == PlaybackMode.spatial,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 5,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
                        child: NowPlayingPanel(
                          track: c.track,
                          position: c.position,
                          isPlaying: c.playing,
                          playbackMode: c.mode,
                          onSeek: (d) => c.seek(d),
                          onPlayPause: () => c.togglePlay(),
                          onModeChanged: (m) => c.setMode(m),
                        ),
                      ),
                    ),
                    PositionSidebar(
                      params: c.params,
                      onChanged: (p) => c.setParams(p),
                      onExport: _onExport,
                      onSavePreset: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Save Preset — local JSON in a later slice'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const _StatusBar(),
            ],
          ),
          if (c.busy)
            Positioned(
              left: 0,
              right: 0,
              bottom: 36,
              child: LinearProgressIndicator(
                value: c.jobProgress <= 0 ? null : c.jobProgress,
                backgroundColor: Colors.white10,
                color: YinweiColors.accent,
                minHeight: 3,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _onOpen() async {
    // file_picker on Windows host; mock path for structure until wired.
    try {
      await _ctrl.openPath('/mock/Across the Room.wav');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已打开（演示引擎 Mock）— 真 HRTF 需接 NativeEngine'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _onExport() async {
    try {
      await _ctrl.exportWav('/tmp/yinwei-export.wav');
      if (!mounted) return;
      final msg = _ctrl.lastError ?? 'Export finished (MockEngine / native path)';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Spacer(),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '音围',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                ),
                Text('Spatial Player', style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
            const Spacer(),
            IconButton(
              onPressed: onOpen,
              tooltip: 'Open local file',
              icon: const Icon(Icons.folder_open_rounded, color: YinweiColors.accent),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text('·', style: style),
          ),
          Text('Local file', style: style),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text('·', style: style),
          ),
          Text('Headphones recommended', style: style),
        ],
      ),
    );
  }
}
