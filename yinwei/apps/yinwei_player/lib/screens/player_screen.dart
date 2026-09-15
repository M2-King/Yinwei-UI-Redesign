import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yinwei_player/bridge/app_audio_route.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/bridge/live_source_follow.dart';
import 'package:yinwei_player/bridge/live_transfer.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/state/island_now_playing.dart';
import 'package:yinwei_player/state/window_mode_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/eq_mixer_window.dart';
import 'package:yinwei_player/widgets/island_bar.dart';
import 'package:yinwei_player/widgets/now_playing_panel.dart';
import 'package:yinwei_player/widgets/spatial_workspace.dart';
import 'package:yinwei_player/widgets/position_sidebar.dart';
import 'package:yinwei_player/widgets/system_live_monitor_bar.dart';

/// Main window — Dual-Mode Full / Floating Island (Yinwei + Windows SMTC).
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    this.controller,
    this.windowMode,
    this.systemMedia,
    this.liveTransfer,
  });

  final EngineController? controller;
  final WindowModeController? windowMode;
  final SystemMediaService? systemMedia;
  final LiveTransferController? liveTransfer;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final EngineController _ctrl;
  late final SpatialRuntimeAdapter _spatial;
  late final SpatialSceneBridge _sceneBridge;
  late final WindowModeController _window;
  late final SystemMediaService _smtc;
  late final LiveTransferController _live;
  late final EngineBackend _backend;
  final AppAudioRouter _audioRoute = AppAudioRouter();
  bool _dragging = false;
  bool _eqOpen = false;
  Offset _eqPos = const Offset(140, 72);
  Timer? _islandAnim;
  int _liveUiTick = 0;
  Timer? _followDebounce;
  AppAudioSplit? _split;
  int _routeGen = 0;
  bool _followBusy = false;
  Future<void> _routeChain = Future<void>.value();

  static const _mediaExts = {
    'wav',
    'mp3',
    'flac',
    'ogg',
    'm4a',
    'aac',
    'mp4',
    'm4v',
    'mov',
  };

  @override
  void initState() {
    super.initState();
    _window = widget.windowMode ?? WindowModeController();
    _smtc = widget.systemMedia ?? SystemMediaService();
    _live = widget.liveTransfer ?? LiveTransferController();
    if (widget.controller != null) {
      _ctrl = widget.controller!;
      _backend = EngineBackend.mock;
    } else {
      final boot = EngineBootstrap.create();
      _backend = boot.backend;
      _ctrl = EngineController(engine: boot.api, backendLabel: boot.detail);
    }
    _spatial = SpatialRuntimeAdapter();
    _spatial.bootstrap(_ctrl.params);
    _sceneBridge = SpatialSceneBridge(adapter: _spatial);
    _ctrl.addListener(_onChange);
    _window.addListener(_onWindowMode);
    _smtc.addListener(_onSmtcChange);
    _live.addListener(_onChange);
    unawaited(_smtc.start());
    unawaited(_audioRoute.recoverIfDirty());
    _live.refreshDevices();
    final smoke = Platform.environment.containsKey('FLUTTER_TEST')
        ? null
        : Platform.environment['YINWEI_OPEN'];
    if (smoke != null && smoke.isNotEmpty) {
      debugPrint('[Player] YINWEI_OPEN=$smoke');
      unawaited(_openMediaPath(smoke).then((_) => _maybeRunPhase3EngineSmoke()));
    } else {
      unawaited(_maybeRunPhase3EngineSmoke());
    }
    _islandAnim = Timer.periodic(const Duration(milliseconds: 80), (_) {
      final wasRunning = _live.running;
      if (wasRunning) {
        // Keep native health sampling at 80 ms, but only repaint telemetry at
        // 320 ms so Live mode does not rebuild the whole player at 12.5 fps.
        _live.refreshTelemetry(notify: false);
        _liveUiTick = (_liveUiTick + 1) % 4;
        if (_liveUiTick == 0) _onChange();
      } else {
        _liveUiTick = 0;
      }
      if (wasRunning && !_live.running) {
        unawaited(_audioRoute.restore());
      }
    });
  }

  void _onChange() {
    _sceneBridge.observePlaybackTelemetry(
      playhead: _ctrl.playhead,
      playing: _ctrl.playing,
      orbiting: _ctrl.params.motion == MotionMode.orbit &&
          _ctrl.mode == PlaybackMode.spatial &&
          _ctrl.playing,
      envelopment: _ctrl.params.envelopment,
      active: _live.running || _ctrl.mode == PlaybackMode.spatial,
    );
    if (mounted) setState(() {});
  }

  void _commitEnginePose(SpatialParams projected) {
    final next = _ctrl.params.copy()
      ..azimuthDeg = projected.azimuthDeg
      ..elevationDeg = projected.elevationDeg
      ..distanceM = projected.distanceM
      ..selectedPreset = null;
    if (_live.running) {
      _live.applyLiveParams(next);
    }
    _ctrl.setParams(next);
  }

  SceneBridgeResult _onSceneIntent(String raw) {
    final result = _sceneBridge.handleMessage(raw);
    debugPrint(
      '[SceneBridge] accepted=${result.accepted} mutated=${result.sceneMutated} '
      'write=${result.shouldWriteEngine} rev=${_spatial.appliedRevision} '
      'reason=${result.reason} sel=${result.selectedObjectId}',
    );
    if (result.shouldWriteEngine) {
      final p = result.engineParams!;
      debugPrint(
        '[SceneBridge] engineWrite az=${p.azimuthDeg.toStringAsFixed(2)} '
        'el=${p.elevationDeg.toStringAsFixed(2)} d=${p.distanceM.toStringAsFixed(2)}',
      );
      _commitEnginePose(p);
    }
    return result;
  }

  void _onSmtcChange() {
    _onChange();
    _scheduleLiveFollow();
  }

  void _scheduleLiveFollow() {
    final transferOn = _live.running || _live.starting;
    final smtc = _smtc.state;
    final needCapture = LiveSourceFollow.shouldRetargetCapture(
      transferOn: transferOn,
      capturePid: _live.lastPid,
      smtc: smtc,
      captureHealthy: _live.captureHealthy,
    );
    final needRoute = LiveSourceFollow.shouldRetargetRoute(
      transferOn: transferOn,
      splitActive: _audioRoute.isRouted || _split != null,
      routedPid: _audioRoute.routedRootPid,
      smtc: smtc,
      captureHealthy: _live.captureHealthy,
    );
    if (!needCapture && !needRoute) {
      _followDebounce?.cancel();
      return;
    }
    _followDebounce?.cancel();
    _followDebounce = Timer(LiveSourceFollow.debounce, () {
      unawaited(_followLiveSource());
    });
  }

  Future<void> _followLiveSource() async {
    if (_followBusy) {
      _scheduleLiveFollow();
      return;
    }
    _followBusy = true;
    try {
      final transferOn = _live.running || _live.starting;
      if (!transferOn) return;
      final smtc = _smtc.state;
      final needCapture = LiveSourceFollow.shouldRetargetCapture(
        transferOn: true,
        capturePid: _live.lastPid,
        smtc: smtc,
        captureHealthy: _live.captureHealthy,
      );
      final needRoute = LiveSourceFollow.shouldRetargetRoute(
        transferOn: true,
        splitActive: _audioRoute.isRouted || _split != null,
        routedPid: _audioRoute.routedRootPid,
        smtc: smtc,
        captureHealthy: _live.captureHealthy,
      );
      if (needRoute) {
        _live.setOutputHold(true);
        _routeGen++;
        final gen = _routeGen;
        await _routeSplit(
          smtc.pid,
          gen,
          keepSpeakerMute: _audioRoute.isRouted,
        );
      }
      if (needCapture) {
        await _live.retarget(
          processId: smtc.pid,
          params: _ctrl.params.copy(),
        );
      }
      if (needRoute) {
        _live.setOutputHold(false);
      }
    } finally {
      _followBusy = false;
    }
  }

  void _onWindowMode() {
    if (_window.isIsland) {
      _eqOpen = false;
    }
    _onChange();
  }

  Future<void> _toggleLiveHrtf() async {
    if (_live.running || _live.starting) {
      await _stopLiveHrtf();
      return;
    }
    await _startLiveHrtf();
  }

  Future<void> _startLiveHrtf() async {
    var pid = _smtc.state.pid;
    var proc = _smtc.state.processName;
    if (!_smtc.state.hasTrack) {
      _live.fail('没有检测到系统正在播放的媒体');
      return;
    }
    if (!_live.available) {
      _live.fail('spatial_core.dll 缺少 live API — 请运行 build_native_windows.ps1');
      return;
    }
    // pid>0 is enough; processName may be empty. Probe if the daemon
    // still has pid=0 (CJK AUMID 汽水音乐 ≠ SodaMusic.exe).
    if (pid <= 0) {
      final probed = await _smtc.resolveLoopbackPid(_smtc.state.sourceApp);
      if (probed != null && probed.pid > 0) {
        pid = probed.pid;
        if (proc.isEmpty) proc = probed.name;
      }
    }
    if (pid <= 0) {
      _live.fail('无法解析音乐进程 PID（process=$proc）。请确认汽水音乐正在播放。');
      return;
    }
    final procL = proc.toLowerCase();
    if (procL.contains('yinwei') || procL.contains('flutter')) {
      _live.fail('PID 指向音围自身，拒绝环回（会啸叫）');
      return;
    }
    // Never mute/duck source apps — SetMute/volume0 makes 汽水/Spotify auto-pause.
    // Never pause Yinwei unless it was actually playing a local file.
    if (_ctrl.playing) {
      await _ctrl.pause();
    }
    // Same SpatialParams as Full-window file playback.
    final params = _ctrl.params.copy();
    final array = _ctrl.array.copy();
    _routeGen++;
    final routeGen = _routeGen;
    _live.markStarting();

    var splitNote = '同一输出上仍可能干+湿叠听';
    final split = _split ?? await _audioRoute.detectSplit();
    final holdWet =
        LiveSourceFollow.holdWetUntilPinned(splitDetected: split != null);
    var holdArmed = false;
    if (split != null) {
      _split = split;
      _live.setOutputDevice(split.headphonesName);
      holdArmed = holdWet && _live.setOutputHold(true);
    }
    if (split != null && !holdArmed) {
      // Old DLL without hold: pin first so wet never opens on shared headphones.
      splitNote = await _routeSplit(pid, routeGen);
      await _live.start(processId: pid, params: params, array: array);
    } else {
      // Capture may start during the pin, but wet stays silent until speakers
      // are muted (hold). No-split overlay-preview starts immediately.
      final startFuture = _live.start(processId: pid, params: params, array: array);
      if (split != null) {
        splitNote = await _routeSplit(pid, routeGen);
      }
      await startFuture;
      if (holdArmed) _live.setOutputHold(false);
    }
    if (!_live.running) {
      _routeGen++;
      await _audioRoute.restore();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_live.lastError ?? 'Live HRTF 启动失败'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('HRTF ON · $proc pid=$pid · $splitNote'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// PowerShell COM routing. Wet output is held silent until this returns
  /// when a headphones/speakers split exists (see [LiveSourceFollow.holdWetUntilPinned]).
  Future<String> _routeSplit(
    int pid,
    int gen, {
    bool keepSpeakerMute = false,
  }) {
    final done = Completer<String>();
    _routeChain = _routeChain.catchError((_) {}).then((_) async {
      try {
        done.complete(await _routeSplitUnlocked(
          pid,
          gen,
          keepSpeakerMute: keepSpeakerMute,
        ));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<String> _routeSplitUnlocked(
    int pid,
    int gen, {
    required bool keepSpeakerMute,
  }) async {
    var splitNote = '同一输出上仍可能干+湿叠听';
    if (gen != _routeGen) return splitNote;
    final split = _split ?? await _audioRoute.detectSplit();
    if (gen != _routeGen) return splitNote;
    if (split == null) return splitNote;
    _split = split;
    _live.setOutputDevice(split.headphonesName);
    if (gen != _routeGen) return splitNote;
    final routed = await _audioRoute.routeToSpeakers(
      rootPid: pid,
      speakersId: split.speakersId,
      restoreId: split.headphonesId,
      keepSpeakerMute: keepSpeakerMute,
    );
    if (gen != _routeGen) return splitNote;
    if (routed) {
      splitNote = '汽水→扬声器（已静音），湿声→${split.headphonesName}';
    }
    return splitNote;
  }

  Future<void> _selectWetOutput(String name) async {
    _live.setOutputDevice(name);
    if (_live.running) {
      await _stopLiveHrtf();
      await _startLiveHrtf();
    }
  }

  void _applySpatialFromUi(SpatialParams next) {
    final adopted = _spatial.adoptPointParams(next);
    if (!adopted.shouldWriteEngine) return;
    final engineParams = adopted.engineParams!;
    if (_live.running) {
      _live.applyLiveParams(engineParams);
    }
    _ctrl.setParams(engineParams);
  }

  void _applyArrayFromUi(ArrayLayout next) {
    if (_live.running) {
      _live.applyLiveArray(next);
    }
    _ctrl.setArray(next);
  }

  Future<void> _stopLiveHrtf() async {
    _followDebounce?.cancel();
    _routeGen++;
    await _live.stop();
    await _audioRoute.restore();
  }

  @override
  void dispose() {
    _followDebounce?.cancel();
    _islandAnim?.cancel();
    _ctrl.removeListener(_onChange);
    _window.removeListener(_onWindowMode);
    _smtc.removeListener(_onSmtcChange);
    _live.removeListener(_onChange);
    _sceneBridge.dispose();
    unawaited(_live.stop());
    unawaited(_audioRoute.restore());
    if (widget.controller == null) {
      _ctrl.dispose();
    }
    if (widget.windowMode == null) {
      _window.dispose();
    }
    if (widget.systemMedia == null) {
      _smtc.dispose();
    }
    if (widget.liveTransfer == null) {
      _live.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_window.isIsland) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: IslandBar(
          controller: _ctrl,
          windowMode: _window,
          systemMedia: _smtc,
          liveTransfer: _live,
          onToggleLiveHrtf: () => unawaited(_toggleLiveHrtf()),
        ),
      );
    }

    final c = _ctrl;
    final now = IslandNowPlaying.resolve(
      engine: c,
      system: _smtc.state,
      now: DateTime.now(),
      liveHrtfRunning: _live.running,
      liveHrtfHealthy: _live.captureHealthy,
      liveAzimuthDeg: _live.running ? _live.azimuthDeg() : 0,
      liveElevationDeg: _live.running ? _live.elevationDeg() : 0,
    );
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) async {
        setState(() => _dragging = false);
        final path = _firstSupportedDrop(detail);
        if (path == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('请拖入音频或视频文件（wav/mp3/flac/ogg/m4a/aac/mp4/m4v/mov）'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        await _openMediaPath(path);
      },
      child: Scaffold(
        body: Stack(
          children: [
            Column(
              children: [
                _TitleBar(
                  onOpen: _onOpen,
                  onEnterIsland: () => _window.enterIsland(),
                  onOpenEq: () => setState(() => _eqOpen = true),
                ),
                SystemLiveMonitorBar(
                  systemMedia: _smtc,
                  liveTransfer: _live,
                  onToggleLiveHrtf: () => unawaited(_toggleLiveHrtf()),
                  onTogglePlayPause: () => unawaited(_smtc.togglePlayPause()),
                  onSelectOutput: (name) => unawaited(_selectWetOutput(name)),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 1100;
                      return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: wide ? 7 : 5,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(22, 8, 10, 16),
                          child: SpatialWorkspace(
                            playhead: now.playhead,
                            azimuthDeg: _live.running
                                ? _live.azimuthDeg()
                                : c.azimuthDeg,
                            elevationDeg: _live.running
                                ? _live.elevationDeg()
                                : c.elevationDeg,
                            distanceM: c.params.distanceM,
                            envelopment: c.params.envelopment,
                            playing: now.playing,
                            sceneSnapshot: _spatial.snapshot(),
                            selectedObjectId: _sceneBridge.selectedObjectId,
                            onSceneIntent:
                                c.array.enabled ? null : _onSceneIntent,
                            arraySpeakers:
                                c.array.enabled ? c.array.speakers : null,
                            selectedSpeakerIndex: c.array.selectedIndex,
                            matrixLinked: c.array.matrixLinked,
                            orbiting: !c.array.enabled &&
                                (_live.running ||
                                    (c.params.motion == MotionMode.orbit &&
                                        c.mode == PlaybackMode.spatial &&
                                        c.playing)),
                            active: _live.running ||
                                c.mode == PlaybackMode.spatial,
                            onPoseChanged: c.array.enabled
                                ? null
                                : (az, el) {
                                    final next = c.params.copy()
                                      ..azimuthDeg = az
                                      ..elevationDeg = el
                                      ..selectedPreset = null;
                                    _applySpatialFromUi(next);
                                  },
                            onDistanceChanged: c.array.enabled
                                ? null
                                : (d) {
                                    final next = c.params.copy()
                                      ..distanceM = d
                                      ..selectedPreset = null;
                                    _applySpatialFromUi(next);
                                  },
                            onSpeakerSelected: c.array.enabled
                                ? (i) => c.selectArraySpeaker(i)
                                : null,
                            onSpeakerPoseChanged: c.array.enabled
                                    ? (i, az, el) {
                                        final next = c.array.copy();
                                        if (i < 0 ||
                                            i >= next.speakers.length) {
                                          return;
                                        }
                                        next.selectedIndex = i;
                                        if (next.matrixLinked) {
                                          next.moveSelectedInGroup(
                                            azimuthDeg: az,
                                            elevationDeg: el,
                                          );
                                        } else {
                                          next.speakers[i].azimuthDeg = az;
                                          next.speakers[i].elevationDeg = el;
                                        }
                                        _applyArrayFromUi(next);
                                      }
                                    : null,
                            onSpeakerDistanceChanged: c.array.enabled
                                    ? (i, d) {
                                        final next = c.array.copy();
                                        if (i < 0 ||
                                            i >= next.speakers.length) {
                                          return;
                                        }
                                        next.selectedIndex = i;
                                        if (next.matrixLinked) {
                                          next.setAllDistance(d);
                                        } else {
                                          next.speakers[i].distanceM = d;
                                        }
                                        _applyArrayFromUi(next);
                                      }
                                    : null,
                            onSpeakerAdd: c.array.enabled
                                ? (az, el, dist) {
                                    if (!c.array.canAddSpeaker) return;
                                    final next = c.array.copy()
                                      ..addSpeaker(
                                        azimuthDeg: az,
                                        elevationDeg: el,
                                        distanceM: dist,
                                      );
                                    _applyArrayFromUi(next);
                                  }
                                : null,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: wide ? 4 : 5,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 24),
                          child: NowPlayingPanel(
                            track: now.asTrack,
                            position: now.position,
                            isPlaying: now.playing,
                            playbackMode: c.mode,
                            onSeek: now.usesSystemMedia
                                ? null
                                : (d) => c.seek(d),
                            onPlayPause: () {
                              if (now.usesSystemMedia) {
                                unawaited(_smtc.togglePlayPause());
                              } else {
                                unawaited(c.togglePlay());
                              }
                            },
                            onModeChanged: (m) {
                              if (_live.running) {
                                _live.applyLiveMode(m);
                              }
                              c.setMode(m);
                            },
                          ),
                        ),
                      ),
                      PositionSidebar(
                        params: c.params,
                        array: c.array,
                        arraySupported: c.arraySupported,
                        onChanged: (p) => _applySpatialFromUi(p),
                        onArrayChanged: _applyArrayFromUi,
                        onArrayMode: (m) {
                          debugPrint('[Player] arrayMode=$m');
                          unawaited(() async {
                            await c.applyArrayMode(m);
                            if (_live.running) {
                              _live.applyLiveArray(c.array);
                            }
                          }());
                        },
                        onPresetSelected: (p) {
                          final next = c.params.copy()..applyPreset(p);
                          _applySpatialFromUi(next);
                        },
                        onOpenEq: () => setState(() => _eqOpen = true),
                        onExport: _onExport,
                        onSavePreset: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'Save Preset — local JSON in a later slice'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      ),
                    ],
                  );
                    },
                  ),
                ),
                _StatusBar(
                  buildId: '$kYinweiUiBuild · $kYinweiBridgeBuild',
                  backend: c.backendLabel,
                  native: _backend == EngineBackend.native,
                  smtcTitle: _smtc.state.hasTrack ? _smtc.state.title : null,
                  smtcPlaying: _smtc.state.playing,
                  liveHrtf: _live.running,
                  liveHrtfHealthy: _live.captureHealthy,
                  onEnterIsland: () => _window.enterIsland(),
                ),
              ],
            ),
            if (_eqOpen)
              Positioned(
                left: _eqPos.dx,
                top: _eqPos.dy,
                child: EqMixerWindow(
                  params: c.params,
                  onChanged: (p) => _applySpatialFromUi(p),
                  onEqSelected: (t) {
                    if (_live.running) {
                      final next = c.params.copy()..applyEq(t);
                      _live.applyLiveParams(next);
                    }
                    c.applyEq(t);
                  },
                  onClose: () => setState(() => _eqOpen = false),
                  onDrag: (delta) {
                    setState(() {
                      _eqPos = Offset(
                        (_eqPos.dx + delta.dx).clamp(8, 2000),
                        (_eqPos.dy + delta.dy).clamp(8, 1200),
                      );
                    });
                  },
                ),
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
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: YinweiColors.accent.withOpacity(0.12),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 28, vertical: 18),
                        decoration: BoxDecoration(
                          color: YinweiColors.panel,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: YinweiColors.accent, width: 1.5),
                        ),
                        child: Text(
                          '拖放以打开音频 / 视频',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: YinweiColors.accent,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String? _firstSupportedDrop(DropDoneDetails detail) {
    for (final f in detail.files) {
      final path = f.path;
      if (path.isEmpty) continue;
      final ext = path.split('.').last.toLowerCase();
      if (_mediaExts.contains(ext)) return path;
    }
    return null;
  }

  Future<void> _onOpen() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _mediaExts.toList()..sort(),
        dialogTitle: '打开音频或视频（自动提取音轨）',
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null || path.isEmpty) {
        throw StateError('无法读取文件路径');
      }
      await _openMediaPath(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _openMediaPath(String path) async {
    try {
      await _ctrl.openPath(path);
      debugPrint('[Player] opened path=$path backend=$_backend');
      if (!mounted) return;
      final label = _backend == EngineBackend.native ? '真引擎' : '演示引擎 Mock';
      final name = path.split(RegExp(r'[\\/]')).last.toLowerCase();
      final isVideo = name.endsWith('.mp4') ||
          name.endsWith('.m4v') ||
          name.endsWith('.mov');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isVideo
                ? '已从视频提取音轨（$label）'
                : (_backend == EngineBackend.native
                    ? '已打开（$label）'
                    : '已打开（$label）— 左下角仍是 Mock：先跑 build_native_windows.ps1 再完全重启'),
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

  Future<void> _maybeRunPhase3EngineSmoke() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.environment['YINWEI_PHASE3_SMOKE'] != '1') return;
    await Future<void>.delayed(const Duration(seconds: 14));
    debugPrint(
      '[Phase3Smoke] engine start backend=$_backend playing=${_ctrl.playing} '
      'opened=${_ctrl.hasOpenedFile}',
    );
    try {
      await _ctrl.play();
      debugPrint(
        '[Phase3Smoke] play playing=${_ctrl.playing} err=${_ctrl.lastError}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await _ctrl.seek(const Duration(seconds: 1));
      debugPrint('[Phase3Smoke] seek pos=${_ctrl.position}');
      await _ctrl.setMode(PlaybackMode.original);
      debugPrint('[Phase3Smoke] original mode=${_ctrl.mode}');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _ctrl.setMode(PlaybackMode.spatial);
      debugPrint('[Phase3Smoke] spatial mode=${_ctrl.mode}');
      for (final preset in [
        PositionPreset.front,
        PositionPreset.right,
        PositionPreset.left,
        PositionPreset.leftRear,
        PositionPreset.overhead,
      ]) {
        final next = _ctrl.params.copy()..applyPreset(preset);
        _applySpatialFromUi(next);
        debugPrint(
          '[Phase3Smoke] preset=${preset.name} az=${_ctrl.params.azimuthDeg} '
          'el=${_ctrl.params.elevationDeg} d=${_ctrl.params.distanceM} '
          'sceneRev=${_spatial.appliedRevision}',
        );
        await Future<void>.delayed(const Duration(milliseconds: 220));
      }
      final out =
          '${Directory.systemTemp.path}${Platform.pathSeparator}yinwei_phase3_export.wav';
      await _ctrl.exportWav(out);
      final exported = File(out);
      debugPrint(
        '[Phase3Smoke] export path=$out exists=${exported.existsSync()} '
        'bytes=${exported.existsSync() ? exported.lengthSync() : 0} '
        'err=${_ctrl.lastError}',
      );
      await _ctrl.applyArrayMode(ArrayMode.stereo2);
      debugPrint(
        '[Phase3Smoke] arrayOn=${_ctrl.array.enabled} '
        'speakers=${_ctrl.array.speakers.length} mode=${_ctrl.array.mode}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _ctrl.applyArrayMode(ArrayMode.off);
      debugPrint(
        '[Phase3Smoke] arrayOff enabled=${_ctrl.array.enabled} '
        'mode=${_ctrl.array.mode}',
      );
      await _ctrl.pause();
      debugPrint('[Phase3Smoke] pause playing=${_ctrl.playing}');
    } catch (e) {
      debugPrint('[Phase3Smoke] engine failed $e');
    }
    debugPrint('[Phase3Smoke] engine done');
  }

  Future<void> _onExport() async {
    try {
      final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
      final name =
          _ctrl.track.title.isEmpty ? 'yinwei-export' : _ctrl.track.title;
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
  const _TitleBar({
    required this.onOpen,
    required this.onEnterIsland,
    required this.onOpenEq,
  });

  final VoidCallback onOpen;
  final VoidCallback onEnterIsland;
  final VoidCallback onOpenEq;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            IconButton(
              onPressed: onEnterIsland,
              tooltip: '进入灵动岛（悬浮窗）',
              icon: const Icon(Icons.crop_landscape_rounded,
                  color: YinweiColors.accent),
            ),
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
                Text('Spatial Player',
                    style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
            const Spacer(),
            IconButton(
              onPressed: onOpenEq,
              tooltip: 'EQ 调音台',
              icon: const Icon(Icons.graphic_eq_rounded,
                  color: YinweiColors.accent),
            ),
            IconButton(
              onPressed: onOpen,
              tooltip: '打开文件（也可拖放音频/视频到窗口）',
              icon: const Icon(Icons.folder_open_rounded,
                  color: YinweiColors.accent),
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
    required this.onEnterIsland,
    this.smtcTitle,
    this.smtcPlaying = false,
    this.liveHrtf = false,
    this.liveHrtfHealthy = false,
  });

  final String buildId;
  final String backend;
  final bool native;
  final VoidCallback onEnterIsland;
  final String? smtcTitle;
  final bool smtcPlaying;
  final bool liveHrtf;
  final bool liveHrtfHealthy;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
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
              color: liveHrtfHealthy
                  ? YinweiColors.accent
                  : (liveHrtf
                      ? YinweiColors.textSecondary
                      : (native
                          ? YinweiColors.success
                          : YinweiColors.textSecondary)),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              liveHrtfHealthy
                  ? 'HRTF LIVE · $backend'
                  : (liveHrtf ? 'HRTF capturing · $backend' : backend),
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (smtcTitle != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('·', style: style),
            ),
            Icon(
              smtcPlaying
                  ? Icons.graphic_eq_rounded
                  : Icons.music_note_rounded,
              size: 14,
              color: smtcPlaying
                  ? YinweiColors.accent
                  : YinweiColors.textSecondary,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                smtcTitle!,
                style: style?.copyWith(
                  color: smtcPlaying
                      ? YinweiColors.accent
                      : YinweiColors.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const Spacer(),
          TextButton.icon(
            onPressed: onEnterIsland,
            icon: const Icon(Icons.crop_landscape_rounded, size: 16),
            label: const Text('灵动岛'),
            style: TextButton.styleFrom(
              foregroundColor: YinweiColors.accent,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
          const SizedBox(width: 8),
          Text(buildId, style: style?.copyWith(color: YinweiColors.accent)),
        ],
      ),
    );
  }
}
