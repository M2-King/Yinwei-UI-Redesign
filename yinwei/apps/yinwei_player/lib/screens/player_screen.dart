import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/now_playing_panel.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/position_sidebar.dart';

/// Main window — wired to [EngineController] (P2.3 / P2.4 native).
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, this.controller});

  final EngineController? controller;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final EngineController _ctrl;
  late final EngineBackend _backend;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _ctrl = widget.controller!;
      _backend = EngineBackend.mock;
    } else {
      final boot = EngineBootstrap.create();
      _backend = boot.backend;
      _ctrl = EngineController(engine: boot.api, backendLabel: boot.detail);
    }
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
                        padding: const EdgeInsets.fromLTRB(28, 12, 12, 20),
                        child: OrbitVisualizer(
                          playhead: c.playhead,
                          azimuthDeg: c.azimuthDeg,
                          elevationDeg: c.params.elevationDeg,
                          distanceM: c.params.distanceM,
                          envelopment: c.params.envelopment,
                          orbiting: c.params.motion == MotionMode.orbit &&
                              c.mode == PlaybackMode.spatial,
                          active: c.mode == PlaybackMode.spatial,
                          onPoseChanged: (az, el) {
                            final next = c.params.copy()
                              ..azimuthDeg = az
                              ..elevationDeg = el
                              ..selectedPreset = null;
                            c.setParams(next);
                          },
                          onDistanceChanged: (d) {
                            final next = c.params.copy()
                              ..distanceM = d
                              ..selectedPreset = null;
                            c.setParams(next);
                          },
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
              _StatusBar(
                buildId: '$kYinweiUiBuild · $kYinweiBridgeBuild',
                backend: c.backendLabel,
                native: _backend == EngineBackend.native,
              ),
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
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['wav', 'mp3', 'flac', 'ogg', 'm4a', 'aac'],
        dialogTitle: '打开本地音频',
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null || path.isEmpty) {
        throw StateError('无法读取文件路径');
      }
      await _ctrl.openPath(path);
      if (!mounted) return;
      final label = _backend == EngineBackend.native ? '真引擎' : '演示引擎 Mock';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _backend == EngineBackend.native
                ? '已打开（$label）'
                : '已打开（$label）— 左下角仍是 Mock：先跑 build_native_windows.ps1 再完全重启',
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
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
      final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
      final name = _ctrl.track.title.isEmpty ? 'yinwei-export' : _ctrl.track.title;
      final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final out = '${dir.path}${Platform.pathSeparator}${safe}_spatial.wav';
      await _ctrl.exportWav(out);
      if (!mounted) return;
      final msg = _ctrl.lastError ?? '已导出：$out';
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
  const _StatusBar({
    required this.buildId,
    required this.backend,
    required this.native,
  });

  final String buildId;
  final String backend;
  final bool native;

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
            decoration: BoxDecoration(
              color: native ? YinweiColors.success : YinweiColors.textSecondary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              backend,
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text('·', style: style),
          ),
          Text('Headphones recommended', style: style),
          const Spacer(),
          Text(buildId, style: style?.copyWith(color: YinweiColors.accent)),
        ],
      ),
    );
  }
}
