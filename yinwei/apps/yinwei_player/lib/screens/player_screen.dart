import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yinwei_player/bridge/app_audio_route.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/bridge/live_capture_health.dart';
import 'package:yinwei_player/bridge/live_source_follow.dart';
import 'package:yinwei_player/bridge/live_transfer.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/bridge/yinwei_bindings.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/runtime/island_spatial_controls.dart';
import 'package:yinwei_player/runtime/orbit_pose_math.dart';
import 'package:yinwei_player/runtime/island_runtime_probe.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/widgets/island_spatial_controller.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/state/island_now_playing.dart';
import 'package:yinwei_player/state/window_chrome.dart';
import 'package:yinwei_player/state/window_mode.dart';
import 'package:yinwei_player/state/window_mode_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/eq_mixer_window.dart';
import 'package:yinwei_player/widgets/app_rail.dart';
import 'package:yinwei_player/widgets/app_top_bar.dart';
import 'package:yinwei_player/widgets/island_bar.dart';
import 'package:yinwei_player/widgets/now_playing_panel.dart';
import 'package:yinwei_player/widgets/spatial_workspace.dart';
import 'package:yinwei_player/widgets/position_sidebar.dart';
import 'package:yinwei_player/mobile/mobile_player_screen.dart';
import 'package:yinwei_player/platform/audio_session_coordinator.dart';
import 'package:yinwei_player/platform/live_activity_bridge.dart';
import 'package:yinwei_player/platform/live_activity_coordinator.dart';
import 'package:yinwei_player/platform/media_file_acquisition.dart';
import 'package:yinwei_player/mobile/mobile_visual_pose.dart';
import 'package:yinwei_player/presentation/yinwei_live_presentation.dart';

/// Main window — Dual-Mode Full / Floating Island (Yinwei + Windows SMTC).
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    this.controller,
    this.windowMode,
    this.systemMedia,
    this.liveTransfer,
    this.capabilities,
    this.liveActivity,
    this.mediaFiles,
    this.audioSession,
    this.pickPlaybackFile,
  });

  final EngineController? controller;
  final WindowModeController? windowMode;
  final SystemMediaService? systemMedia;
  final LiveTransferController? liveTransfer;
  final PlatformCapabilities? capabilities;
  final LiveActivityBridge? liveActivity;
  final MediaFileAcquisition? mediaFiles;
  final AudioSessionCoordinator? audioSession;

  /// Test seam for iOS Open. Production uses FilePicker.
  final Future<String?> Function()? pickPlaybackFile;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WindowListener {
  bool _closing = false;
  late final PlatformCapabilities _caps;
  bool get _nativeWindow =>
      _caps.desktopWindow &&
      _caps.nativeWindowChrome &&
      !Platform.environment.containsKey('FLUTTER_TEST');
  late final EngineController _ctrl;
  late final SpatialRuntimeAdapter _spatial;
  late final SpatialSceneBridge _sceneBridge;
  late final LiveActivityCoordinator _liveActivity;
  late final MediaFileAcquisition _mediaFiles;
  late final AudioSessionCoordinator _audioSession;
  SphericalV1? _liveActivityFrozenPose;
  var _audioSessionArmed = false;
  late final WindowModeController _window;
  late final SystemMediaService _smtc;
  late final LiveTransferController _live;
  late final EngineBackend _backend;
  late final Listenable _transportTicks;
  late final Listenable _islandTicks;
  late final Listenable _sessionTicks;
  final ValueNotifier<PlaybackTelemetryV1> _telemetry =
      ValueNotifier(const PlaybackTelemetryV1());
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
  String? _lastShellEpoch;

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
    _caps = widget.capabilities ?? PlatformCapabilities.detect();
    final startIsland = _caps.floatingIsland &&
        _nativeWindow &&
        Platform.environment['YINWEI_START_FULL'] != '1' &&
        !Platform.environment.containsKey('YINWEI_OPEN');
    _window = widget.windowMode ??
        WindowModeController(
          chrome: _caps.nativeWindowChrome
              ? WindowManagerChrome()
              : InactiveWindowChrome(),
          mode: startIsland ? WindowMode.islandCollapsed : WindowMode.full,
        );
    _smtc = widget.systemMedia ?? SystemMediaService();
    _live = widget.liveTransfer ??
        LiveTransferController(capabilities: _caps);
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
    _mediaFiles =
        widget.mediaFiles ?? MediaFileAcquisition.create(capabilities: _caps);
    _audioSession = widget.audioSession ??
        AudioSessionCoordinator.create(capabilities: _caps);
    _liveActivity = LiveActivityCoordinator(
      bridge: widget.liveActivity ??
          LiveActivityBridge.create(capabilities: _caps),
    );
    if (_nativeWindow) registerIslandRuntimeProbe(_islandProbe);
    if (_nativeWindow) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    _observeIslandActivity();
    _transportTicks = Listenable.merge([_ctrl, _smtc, _live]);
    _islandTicks = Listenable.merge([_ctrl, _window, _smtc, _live]);
    _sessionTicks = Listenable.merge([_smtc, _live]);
    _publishTelemetry();
    _ctrl.addListener(_onChange);
    _window.addListener(_onWindowMode);
    _smtc.addListener(_onSmtcChange);
    _live.addListener(_onChange);
    if (_caps.systemMedia) unawaited(_smtc.start());
    if (_caps.liveTransfer) {
      unawaited(_audioRoute.recoverIfDirty());
      _live.refreshDevices();
    }
    final smoke = Platform.environment.containsKey('FLUTTER_TEST')
        ? null
        : Platform.environment['YINWEI_OPEN'];
    if (smoke != null && smoke.isNotEmpty) {
      debugPrint('[Player] YINWEI_OPEN=$smoke');
      unawaited(
          _openMediaPath(smoke).then((_) => _maybeRunPhase3EngineSmoke()));
    } else {
      unawaited(_maybeRunPhase3EngineSmoke());
    }
    unawaited(_maybeRunPhase5bTransportSmoke());
    unawaited(_maybeRunPhase6Smoke());
    unawaited(_maybeRunPhase65Smoke());
    if (_caps.floatingIsland &&
        !Platform.environment.containsKey('FLUTTER_TEST') &&
        Platform.environment['YINWEI_START_FULL'] != '1' &&
        !Platform.environment.containsKey('YINWEI_OPEN')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_window.enterIsland());
      });
    }
    _islandAnim = Timer.periodic(const Duration(milliseconds: 80), (_) {
      final wasRunning = _live.running;
      if (wasRunning) {
        // Keep native health sampling at 80 ms, but only notify live UI at
        // 320 ms so Live mode does not rebuild the workstation at 12.5 fps.
        _liveUiTick = (_liveUiTick + 1) % 4;
        _live.refreshTelemetry(notify: _liveUiTick == 0);
        _publishTelemetry();
      } else {
        _liveUiTick = 0;
      }
      if (wasRunning && !_live.running) {
        unawaited(_audioRoute.restore());
      }
    });
  }

  bool get _orbitOverlayActive => OrbitOverlay.active(
        mode: _ctrl.mode,
        motion: _ctrl.params.motion,
        playing: _ctrl.playing,
        arrayEnabled: _ctrl.array.enabled,
      );

  void _publishTelemetry() {
    final next = PlaybackTelemetryV1(
      playhead: _ctrl.playhead,
      playing: _ctrl.playing,
      orbiting: _orbitOverlayActive,
      envelopment: _ctrl.params.envelopment,
      active: _live.running || _ctrl.mode == PlaybackMode.spatial,
      azimuthDeg: _live.running ? _live.azimuthDeg() : _ctrl.azimuthDeg,
      elevationDeg: _live.running ? _live.elevationDeg() : _ctrl.elevationDeg,
    );
    _sceneBridge.observePlaybackTelemetry(
      playhead: next.playhead,
      playing: next.playing,
      orbiting: next.orbiting,
      envelopment: next.envelopment,
      active: next.active,
      azimuthDeg: next.azimuthDeg,
      elevationDeg: next.elevationDeg,
    );
    if (_telemetry.value != next) {
      _telemetry.value = next;
    }
    _publishLiveActivity();
    _syncAudioSession();
  }

  void _publishLiveActivity() {
    final telemetry = _telemetry.value;
    final presentationKind = workspacePresentationOf(
      playbackMode: _ctrl.mode,
      arrayMode: _ctrl.array.mode,
    );
    final scene = _spatial.snapshot();
    final scenePose = scene != null && scene['sources'] is List
        ? IslandPointIntent.pose(scene)
        : SphericalV1(
            azimuthDeg: _ctrl.params.azimuthDeg,
            elevationDeg: _ctrl.params.elevationDeg,
            distanceM: _ctrl.params.distanceM,
          );
    final overlay = presentationKind == WorkspacePresentation.point &&
        OrbitOverlay.ofTelemetry(telemetry);
    if (overlay) {
      _liveActivityFrozenPose = SphericalV1(
        azimuthDeg: telemetry.azimuthDeg,
        elevationDeg: telemetry.elevationDeg,
        distanceM: scenePose.distanceM,
      );
    }
    unawaited(
      _liveActivity.publish(
        YinweiLivePresentation.read(
          controller: _ctrl,
          telemetry: telemetry,
          visualPose: MobileVisualPose.resolve(
            scenePose: scenePose,
            telemetry: telemetry,
            motion: _ctrl.params.motion,
            presentation: presentationKind,
            lastLivePose: _liveActivityFrozenPose,
          ),
        ),
      ),
    );
  }

  void _syncAudioSession() {
    if (!_audioSession.available) return;
    if (_ctrl.playing && !_audioSessionArmed) {
      _audioSessionArmed = true;
      unawaited(_audioSession.activateForPlayback());
    }
  }

  Future<void> _onIosTogglePlay() async {
    print(
      '[YINWEI_IOS] PLAY_BUTTON_PRESSED playing=${_ctrl.playing} '
      'hasFile=${_ctrl.hasOpenedFile} backend=$_backend '
      'loadError=${YinweiBindings.loadError} lastError=${_ctrl.lastError}',
    );
    if (!_ctrl.hasOpenedFile) {
      print('[YINWEI_IOS] PLAY_SKIP no track loaded');
      return;
    }
    if (!_ctrl.playing && _audioSession.available) {
      print('[YINWEI_IOS] IOS_CHANNEL_PLAY_RECEIVED');
      try {
        await _audioSession.activateForPlayback();
        _audioSessionArmed = true;
        print('[YINWEI_IOS] IOS_CHANNEL_PLAY_OK');
      } catch (e) {
        print('[YINWEI_IOS] IOS_CHANNEL_PLAY_FAIL $e');
      }
    } else if (!_ctrl.playing) {
      print('[YINWEI_IOS] IOS_CHANNEL_PLAY_SKIP session unavailable');
    }
    await _ctrl.togglePlay();
    if (!_ctrl.playing && _ctrl.lastError != null && _audioSession.available) {
      print('[YINWEI_IOS] PLAY_FAIL release session lastError=${_ctrl.lastError}');
      try {
        await _audioSession.deactivate();
      } catch (e) {
        print('[YINWEI_IOS] IOS_CHANNEL_DEACTIVATE_FAIL $e');
      }
      _audioSessionArmed = false;
    }
    print(
      '[YINWEI_IOS] PLAY_BUTTON_DONE playing=${_ctrl.playing} '
      'lastError=${_ctrl.lastError}',
    );
  }

  String _shellEpoch() {
    final p = _ctrl.params;
    final a = _ctrl.array;
    final speakers = a.speakers
        .map((s) =>
            '${s.azimuthDeg}|${s.elevationDeg}|${s.distanceM}|${s.gainDb}|${s.mute}')
        .join(';');
    return '${_window.mode}|${_ctrl.mode}|${a.enabled}|${a.mode}|${a.selectedIndex}|'
        '${a.matrixLinked}|${a.speakers.length}|$speakers|${_ctrl.track.title}|${_ctrl.hasOpenedFile}|'
        '${_ctrl.busy}|${_ctrl.lastError}|${p.azimuthDeg}|${p.elevationDeg}|${p.distanceM}|'
        '${p.motion}|${p.orbitHz}|${p.envelopment}|${p.reverbMix}|${p.selectedPreset}|'
        '${p.selectedEq}|${p.eqDb}|${_spatial.appliedRevision}|${_sceneBridge.selectedObjectId}|'
        '${_live.running}|${_live.lastError}|$_eqOpen|$_dragging|${_smtc.state.hasTrack}|'
        '${_smtc.state.title}|${_smtc.state.artist}';
  }

  void _onChange() {
    _observeIslandActivity();
    _publishTelemetry();
    final epoch = _shellEpoch();
    if (epoch == _lastShellEpoch) return;
    _lastShellEpoch = epoch;
    if (mounted) setState(() {});
  }

  void _observeIslandActivity() {
    _window.observeMediaActivity(
      (_ctrl.hasOpenedFile && _ctrl.playing) ||
          (_smtc.state.hasTrack && _smtc.state.playing) ||
          _live.captureHealthy,
    );
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
    final previousSelection = _sceneBridge.selectedObjectId;
    final rewritten = OrbitPoseMath.rewritePointIntent(
      raw: raw,
      scene: _spatial.snapshot() ?? const <String, dynamic>{},
      elapsed: _ctrl.position,
      orbitHz: _ctrl.params.orbitHz,
      overlayActive: _orbitOverlayActive,
    );
    final result = _sceneBridge.handleMessage(rewritten);
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
    } else if (_sceneBridge.selectedObjectId != previousSelection) {
      if (mounted) setState(() {});
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
    final refuse = LiveSourceFollow.refuseStartReason(_smtc.state);
    if (refuse != null) {
      _live.fail(refuse);
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
      final startFuture =
          _live.start(processId: pid, params: params, array: array);
      if (split != null) {
        splitNote = await _routeSplit(pid, routeGen);
      }
      await startFuture;
      if (holdArmed) _live.setOutputHold(false);
    }
    if (!_live.running) {
      _routeGen++;
      await _audioRoute.restore();
      _live.fail(LiveCaptureHealth.explainStartFailure(
        nativeError: _live.lastError,
        sourcePlaying: _smtc.state.playing,
        sourceTitle: _smtc.state.title,
        sourcePid: pid,
      ));
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

  void _onPlaybackMode(PlaybackMode mode) {
    if (_live.running) {
      _live.applyLiveMode(mode);
    }
    unawaited(_ctrl.setMode(mode));
  }

  void _onArrayMode(ArrayMode mode) {
    unawaited(() async {
      await _ctrl.applyArrayMode(mode);
      if (_live.running) {
        _live.applyLiveArray(_ctrl.array);
      }
      debugPrint('[Player] arrayMode=$mode diag=${_ctrl.runtimeAudioDiag()}');
    }());
  }

  Future<void> _stopLiveHrtf() async {
    _followDebounce?.cancel();
    _routeGen++;
    await _live.stop();
    await _audioRoute.restore();
  }

  @override
  void onWindowClose() {
    if (_closing) return;
    _closing = true;
    _window.dispose();
    _islandAnim?.cancel();
    _followDebounce?.cancel();
    unawaited(() async {
      try {
        await _stopLiveHrtf();
      } finally {
        await windowManager.destroy();
      }
    }());
  }

  @override
  void dispose() {
    if (_nativeWindow) windowManager.removeListener(this);
    _followDebounce?.cancel();
    _islandAnim?.cancel();
    _ctrl.removeListener(_onChange);
    _window.removeListener(_onWindowMode);
    _smtc.removeListener(_onSmtcChange);
    _live.removeListener(_onChange);
    _sceneBridge.dispose();
    unawaited(_liveActivity.end());
    unawaited(_audioSession.deactivate());
    _telemetry.dispose();
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
    if (_caps == PlatformCapabilities.ios) {
      return MobilePlayerScreen(
        controller: _ctrl,
        backend: _backend,
        loadError: YinweiBindings.loadError,
        capabilities: _caps,
        sceneSnapshot: () => _spatial.snapshot() ?? const <String, dynamic>{},
        telemetry: _telemetry,
        onSceneIntent: _onSceneIntent,
        onOpen: () => unawaited(_onOpen()),
        onTogglePlay: () => unawaited(_onIosTogglePlay()),
        onPlaybackMode: _onPlaybackMode,
        onMotionChanged: (motion) {
          final next = _ctrl.params.copy()..motion = motion;
          _applySpatialFromUi(next);
        },
      );
    }
    final island = _window.isIsland;
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
    return Scaffold(
      backgroundColor:
          island ? const Color(0x00000000) : YinweiColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (!island)
            _maybeDesktopDrop(
              child: Scaffold(
                body: Stack(
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final compactRail = constraints.maxWidth <
                            YinweiLayout.compactRailBreakpoint;
                        final presentation = workspacePresentationOf(
                          playbackMode: c.mode,
                          arrayMode: c.array.mode,
                        );
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AppRail(
                              compact: compactRail,
                              onOpen: _onOpen,
                              onOpenEq: () => setState(() => _eqOpen = true),
                              onExport: _onExport,
                              onEnterIsland: () => _window.enterIsland(),
                              buildId: '$kYinweiUiBuild · $kYinweiBridgeBuild',
                              native: _backend == EngineBackend.native,
                              backend: c.backendLabel,
                            ),
                            Expanded(
                              child: Column(
                                children: [
                                  ListenableBuilder(
                                    listenable: _sessionTicks,
                                    builder: (context, _) => AppTopBar(
                                      systemMedia: _smtc,
                                      liveTransfer: _live,
                                      onToggleLiveHrtf: () =>
                                          unawaited(_toggleLiveHrtf()),
                                      onTogglePlayPause: () =>
                                          unawaited(_smtc.togglePlayPause()),
                                      onSelectOutput: (name) =>
                                          unawaited(_selectWetOutput(name)),
                                      playbackMode: c.mode,
                                      arrayEnabled: c.array.enabled,
                                    ),
                                  ),
                                  Expanded(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Expanded(
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              YinweiLayout.shellGutter,
                                              10,
                                              8,
                                              8,
                                            ),
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
                                              suspended: island,
                                              capabilities: _caps,
                                              playbackMode: c.mode,
                                              arrayMode: c.array.mode,
                                              playbackTelemetry: _telemetry,
                                              sceneSnapshot:
                                                  _spatial.snapshot(),
                                              selectedObjectId:
                                                  _sceneBridge.selectedObjectId,
                                              onSceneIntent: presentation ==
                                                      WorkspacePresentation
                                                          .point
                                                  ? _onSceneIntent
                                                  : null,
                                              arraySpeakers: c.array.speakers,
                                              selectedSpeakerIndex:
                                                  c.array.selectedIndex,
                                              matrixLinked:
                                                  c.array.matrixLinked,
                                              orbiting: _orbitOverlayActive,
                                              active: _live.running ||
                                                  c.mode ==
                                                      PlaybackMode.spatial,
                                              onPoseChanged: presentation ==
                                                      WorkspacePresentation
                                                          .point
                                                  ? (az, el) {
                                                      final visualAz =
                                                          _orbitOverlayActive
                                                              ? _ctrl.params
                                                                  .originAzimuthFromVisual(
                                                                  az,
                                                                  _ctrl.position,
                                                                )
                                                              : az;
                                                      final next = c.params
                                                          .copy()
                                                        ..azimuthDeg = visualAz
                                                        ..elevationDeg = el
                                                        ..selectedPreset = null;
                                                      _applySpatialFromUi(next);
                                                    }
                                                  : null,
                                              onDistanceChanged: presentation ==
                                                      WorkspacePresentation
                                                          .point
                                                  ? (d) {
                                                      final next = c.params
                                                          .copy()
                                                        ..distanceM = d
                                                        ..selectedPreset = null;
                                                      _applySpatialFromUi(next);
                                                    }
                                                  : null,
                                              onSpeakerSelected: presentation ==
                                                      WorkspacePresentation
                                                          .stereo2
                                                  ? (i) =>
                                                      c.selectArraySpeaker(i)
                                                  : null,
                                              onSpeakerPoseChanged:
                                                  presentation ==
                                                          WorkspacePresentation
                                                              .stereo2
                                                      ? (i, az, el) {
                                                          final next =
                                                              c.array.copy();
                                                          if (i < 0 ||
                                                              i >=
                                                                  next.speakers
                                                                      .length) {
                                                            return;
                                                          }
                                                          next.selectedIndex =
                                                              i;
                                                          if (next
                                                              .matrixLinked) {
                                                            next.moveSelectedInGroup(
                                                              azimuthDeg: az,
                                                              elevationDeg: el,
                                                            );
                                                          } else {
                                                            next.speakers[i]
                                                                .azimuthDeg = az;
                                                            next.speakers[i]
                                                                .elevationDeg = el;
                                                          }
                                                          _applyArrayFromUi(
                                                              next);
                                                        }
                                                      : null,
                                              onSpeakerDistanceChanged:
                                                  presentation ==
                                                          WorkspacePresentation
                                                              .stereo2
                                                      ? (i, d) {
                                                          final next =
                                                              c.array.copy();
                                                          if (i < 0 ||
                                                              i >=
                                                                  next.speakers
                                                                      .length) {
                                                            return;
                                                          }
                                                          next.selectedIndex =
                                                              i;
                                                          if (next
                                                              .matrixLinked) {
                                                            next.setAllDistance(
                                                                d);
                                                          } else {
                                                            next.speakers[i]
                                                                .distanceM = d;
                                                          }
                                                          _applyArrayFromUi(
                                                              next);
                                                        }
                                                      : null,
                                              onSpeakerAdd: presentation ==
                                                      WorkspacePresentation
                                                          .stereo2
                                                  ? (az, el, dist) {
                                                      if (!c.array
                                                          .canAddSpeaker) {
                                                        return;
                                                      }
                                                      final next =
                                                          c.array.copy()
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
                                        PositionSidebar(
                                          params: c.params,
                                          array: c.array,
                                          arraySupported: c.arraySupported,
                                          selectedObjectId:
                                              _sceneBridge.selectedObjectId,
                                          sceneSnapshot: _spatial.snapshot(),
                                          onChanged: (p) =>
                                              _applySpatialFromUi(p),
                                          onArrayChanged: _applyArrayFromUi,
                                          onArrayMode: _onArrayMode,
                                          onPresetSelected: (p) {
                                            final next = c.params.copy()
                                              ..applyPreset(p);
                                            _applySpatialFromUi(next);
                                          },
                                          onOpenEq: () =>
                                              setState(() => _eqOpen = true),
                                          onExport: _onExport,
                                          onSavePreset: () {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                    'Save Preset — local JSON in a later slice'),
                                                behavior:
                                                    SnackBarBehavior.floating,
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                  ListenableBuilder(
                                    listenable: _transportTicks,
                                    builder: (context, _) {
                                      final transport =
                                          IslandNowPlaying.resolve(
                                        engine: c,
                                        system: _smtc.state,
                                        now: DateTime.now(),
                                        liveHrtfRunning: _live.running,
                                        liveHrtfHealthy: _live.captureHealthy,
                                        liveAzimuthDeg: _live.running
                                            ? _live.azimuthDeg()
                                            : 0,
                                        liveElevationDeg: _live.running
                                            ? _live.elevationDeg()
                                            : 0,
                                      );
                                      return NowPlayingPanel(
                                        track: transport.asTrack,
                                        position: transport.position,
                                        isPlaying: transport.playing,
                                        playbackMode: c.mode,
                                        arrayMode: c.array.mode,
                                        arraySupported: c.arraySupported,
                                        onSeek: transport.usesSystemMedia
                                            ? null
                                            : (d) => c.seek(d),
                                        onPlayPause: () {
                                          if (transport.usesSystemMedia) {
                                            unawaited(_smtc.togglePlayPause());
                                          } else {
                                            unawaited(c.togglePlay());
                                          }
                                        },
                                        onModeChanged: _onPlaybackMode,
                                        onArrayMode: _onArrayMode,
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
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
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
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
            ),
          if (island)
            ListenableBuilder(
              listenable: _islandTicks,
              builder: (context, _) => IslandBar(
                controller: _ctrl,
                windowMode: _window,
                systemMedia: _smtc,
                liveTransfer: _live,
                onToggleLiveHrtf: () => unawaited(_toggleLiveHrtf()),
                onPlaybackMode: _onPlaybackMode,
                onArrayMode: _onArrayMode,
                pointReadout: _islandPointReadout(),
                miniController: IslandSpatialController(
                  sceneSnapshot: () => _spatial.snapshot()!,
                  playbackTelemetry: _telemetry.value,
                  onSceneIntent: _onSceneIntent,
                  arrayLayout: () => _ctrl.array,
                  onArrayChanged: _applyArrayFromUi,
                  onSpeakerSelected: (index) => _ctrl.selectArraySpeaker(index),
                  onClose: () => _window.setMiniOpen(false),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _maybeDesktopDrop({required Widget child}) {
    if (!_caps.desktopDrop) return child;
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
              content: Text(
                  '请拖入音频或视频文件（wav/mp3/flac/ogg/m4a/aac/mp4/m4v/mov）'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        await _openMediaPath(path);
      },
      child: child,
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

  String _islandPointReadout() {
    final pose = OrbitVisualPose.resolve(
      scenePose: IslandPointIntent.pose(_spatial.snapshot()!),
      telemetry: _telemetry.value,
    );
    return '${pose.azimuthDeg.round()}° · ${pose.elevationDeg.round()}° · ${pose.distanceM.toStringAsFixed(2)} m';
  }

  Future<Map<String, Object?>> _islandProbe(Map<String, String> p) async {
    switch (p['action']) {
      case 'full':
        await _window.enterFull();
      case 'island':
        await _window.enterIsland();
      case 'expand':
        await _window.expandIsland();
      case 'collapse':
        await _window.collapseIsland();
      case 'mini':
        _window.setMiniOpen(p['open'] != 'false');
      case 'hover':
        await _window.setPillHovered(p['hover'] != 'false');
      case 'open':
        await _openMediaPath(p['path']!);
      case 'play':
        await _ctrl.togglePlay();
      case 'stop':
        if (_ctrl.playing) await _ctrl.togglePlay();
        if (_smtc.state.playing) _smtc.togglePlayPause();
      case 'mode':
        _onPlaybackMode(p['mode'] == 'original'
            ? PlaybackMode.original
            : PlaybackMode.spatial);
        await _ctrl.applyArrayMode(
            p['mode'] == 'stereo2' ? ArrayMode.stereo2 : ArrayMode.off);
        if (_live.running) {
          _live.applyLiveArray(_ctrl.array);
        }
      case 'point':
        _onSceneIntent(IslandPointIntent.commit(
            _spatial.snapshot()!,
            SphericalV1(
                azimuthDeg: double.parse(p['az']!),
                elevationDeg: double.parse(p['el']!),
                distanceM: double.parse(p['distance']!))));
      case 'speaker':
        await _ctrl.selectArraySpeaker(int.parse(p['index'] ?? '0'));
      case 'arrayPose':
        final next = _ctrl.array.copy();
        if (p['index'] != null) {
          next.selectedIndex = int.parse(p['index']!);
        }
        final speaker = next.selected;
        if (p['az'] != null) speaker.azimuthDeg = double.parse(p['az']!);
        if (p['el'] != null) speaker.elevationDeg = double.parse(p['el']!);
        if (p['distance'] != null)
          speaker.distanceM = double.parse(p['distance']!);
        _applyArrayFromUi(next);
      case 'live':
        await _toggleLiveHrtf();
      case 'shutdown':
        onWindowClose();
    }
    Map<String, dynamic>? native;
    try {
      native = await const MethodChannel('yinwei/window_chrome')
          .invokeMapMethod<String, dynamic>('getWindowDiagnostics', {
        'x': double.tryParse(p['x'] ?? '') ?? 0,
        'y': double.tryParse(p['y'] ?? '') ?? 0,
      });
    } catch (e) {
      native = {'error': '$e'};
    }
    return {
      'window': _window.mode.name,
      'interaction': _window.interaction.name,
      'dormant': _window.dormant,
      'miniOpen': _window.miniOpen,
      'busy': _window.busy,
      'error': _window.lastError,
      'native': native,
      'scene': _spatial.snapshot(),
      'audio': _ctrl.runtimeAudioDiag(),
      'playing': _ctrl.playing,
      'hasFile': _ctrl.hasOpenedFile,
      'liveRunning': _live.running,
      'liveHealthy': _live.captureHealthy,
      'systemTitle': _smtc.state.title,
      'systemPlaying': _smtc.state.playing,
    };
  }

  Future<void> _onOpen() async {
    try {
      final path = await _pickPlaybackPath();
      if (path == null || path.isEmpty) return;
      await _openMediaPath(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<String?> _pickPlaybackPath() async {
    if (widget.pickPlaybackFile != null) {
      return widget.pickPlaybackFile!();
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _mediaExts.toList()..sort(),
      dialogTitle: '打开音频或视频（自动提取音轨）',
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null || path.isEmpty) {
      throw StateError('无法读取文件路径');
    }
    return path;
  }

  Future<void> _openMediaPath(String path) async {
    try {
      final readable = await _mediaFiles.prepareReadablePath(path);
      await _ctrl.openPath(readable);
      debugPrint('[Player] opened path=$readable backend=$_backend');
      if (Platform.isIOS) {
        print(
          '[YINWEI_IOS] yinwei_open OK path=$readable backend=$_backend '
          'title=${_ctrl.track.title}',
        );
      }
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
      if (Platform.isIOS) {
        print('[YINWEI_IOS] yinwei_open FAIL $e');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _maybeRunPhase6Smoke() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.environment['YINWEI_PHASE6_SMOKE'] != '1') return;
    for (var i = 0; i < 40 && !_ctrl.hasOpenedFile; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!_ctrl.hasOpenedFile) {
      debugPrint('[Phase6] skip — no opened file');
      return;
    }
    void mark(String label) {
      debugPrint(
        '[Phase6] MARK $label playing=${_ctrl.playing} mode=${_ctrl.mode} '
        'array=${_ctrl.array.mode} sceneRev=${_spatial.appliedRevision} '
        'nativeWrites=${_ctrl.nativeSpatialWrites} '
        'paramCalls=${_ctrl.spatialSetParamsCalls} '
        'pos=${_ctrl.position} island=${_window.mode} '
        'diag=${_ctrl.runtimeAudioDiag()}',
      );
      try {
        File('${Directory.systemTemp.path}${Platform.pathSeparator}yinwei_phase6_mark.txt')
            .writeAsStringSync(label);
      } catch (_) {}
    }

    try {
      final rev0 = _spatial.appliedRevision;
      final writes0 = _ctrl.nativeSpatialWrites;
      _onPlaybackMode(PlaybackMode.spatial);
      await _ctrl.play();
      mark('spatial-idle-start');
      await Future<void>.delayed(const Duration(seconds: 2));
      mark('spatial-idle-2s');
      debugPrint(
        '[Phase6] idleDeltaRev=${_spatial.appliedRevision - rev0} '
        'idleDeltaWrites=${_ctrl.nativeSpatialWrites - writes0}',
      );

      await Future<void>.delayed(const Duration(seconds: 8));
      mark('after-drag-window');
      debugPrint(
        '[Phase6] afterDrag rev=${_spatial.appliedRevision} '
        'writes=${_ctrl.nativeSpatialWrites} paramCalls=${_ctrl.spatialSetParamsCalls}',
      );

      await _ctrl.seek(const Duration(seconds: 1));
      await _ctrl.seek(const Duration(seconds: 3));
      await _ctrl.seek(const Duration(milliseconds: 500));
      mark('seek');
      debugPrint(
        '[Phase6] seekDeltaRev=${_spatial.appliedRevision - rev0}',
      );

      await _ctrl.pause();
      mark('paused');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _ctrl.play();
      mark('resumed');

      _onPlaybackMode(PlaybackMode.original);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _onPlaybackMode(PlaybackMode.spatial);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _onPlaybackMode(PlaybackMode.original);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _onPlaybackMode(PlaybackMode.spatial);
      mark('mode-toggle');
      debugPrint(
        '[Phase6] modeToggleDeltaRev=${_spatial.appliedRevision - rev0}',
      );

      _onArrayMode(ArrayMode.stereo2);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      mark('array-2.0');
      _onArrayMode(ArrayMode.off);
      await Future<void>.delayed(const Duration(seconds: 1));
      mark('point-spatial');

      await Future<void>.delayed(const Duration(seconds: 1));
      await _window.enterIsland();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      mark('island');
      await _ctrl.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _ctrl.play();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _window.enterFull();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      mark('full-restored');
      debugPrint(
        '[Phase6] final rev=${_spatial.appliedRevision} deltaRev=${_spatial.appliedRevision - rev0} '
        'writes=${_ctrl.nativeSpatialWrites} paramCalls=${_ctrl.spatialSetParamsCalls}',
      );
    } catch (e) {
      debugPrint('[Phase6] failed $e');
    }
    debugPrint('[Phase6] engine done');
  }

  Future<void> _maybeRunPhase65Smoke() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.environment['YINWEI_PHASE65_SMOKE'] != '1') return;
    for (var i = 0; i < 40 && !_ctrl.hasOpenedFile; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!_ctrl.hasOpenedFile) {
      debugPrint('[Phase65] skip — no opened file');
      return;
    }
    void mark(String label) {
      final presentation = workspacePresentationOf(
        playbackMode: _ctrl.mode,
        arrayMode: _ctrl.array.mode,
      );
      final visuals = arraySpeakerVisuals(
        speakers: _ctrl.array.speakers,
        selectedIndex: _ctrl.array.selectedIndex,
      );
      debugPrint(
        '[Phase65] MARK $label presentation=${presentation.name} '
        'mode=${_ctrl.mode} array=${_ctrl.array.mode} '
        'sceneRev=${_spatial.appliedRevision} '
        'pointAz=${_ctrl.params.azimuthDeg} pointEl=${_ctrl.params.elevationDeg} '
        'pointDist=${_ctrl.params.distanceM} '
        'L=${_ctrl.array.speakers.isNotEmpty ? _ctrl.array.speakers.first.azimuthDeg : null} '
        'R=${_ctrl.array.speakers.length > 1 ? _ctrl.array.speakers[1].azimuthDeg : null} '
        'visuals=${visuals.map((v) => '${v.label}:${v.world.x.toStringAsFixed(2)},${v.world.z.toStringAsFixed(2)}').toList()}',
      );
      try {
        File('${Directory.systemTemp.path}${Platform.pathSeparator}yinwei_phase65_mark.txt')
            .writeAsStringSync(label);
      } catch (_) {}
    }

    try {
      final rev0 = _spatial.appliedRevision;
      final pointAz0 = _ctrl.params.azimuthDeg;
      final pointEl0 = _ctrl.params.elevationDeg;
      final pointDist0 = _ctrl.params.distanceM;
      await _ctrl.play();

      _onPlaybackMode(PlaybackMode.original);
      _onArrayMode(ArrayMode.off);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      mark('idle');
      await Future<void>.delayed(const Duration(seconds: 3));

      _onPlaybackMode(PlaybackMode.spatial);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      mark('point');
      await Future<void>.delayed(const Duration(seconds: 3));

      _onArrayMode(ArrayMode.stereo2);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      mark('stereo2');
      await Future<void>.delayed(const Duration(seconds: 3));

      final mutated = _ctrl.array.copy();
      mutated.speakers[0].azimuthDeg = -50;
      mutated.speakers[0].distanceM = 2.4;
      mutated.speakers[1].azimuthDeg = 40;
      mutated.selectedIndex = 0;
      _applyArrayFromUi(mutated);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      mark('stereo2-moved');
      await Future<void>.delayed(const Duration(seconds: 3));

      _onArrayMode(ArrayMode.off);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      mark('point-return');
      await Future<void>.delayed(const Duration(seconds: 3));
      debugPrint(
        '[Phase65] pointPreserved az=${_ctrl.params.azimuthDeg == pointAz0} '
        'el=${_ctrl.params.elevationDeg == pointEl0} '
        'dist=${_ctrl.params.distanceM == pointDist0} '
        'revDelta=${_spatial.appliedRevision - rev0}',
      );

      _onArrayMode(ArrayMode.stereo2);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      mark('stereo2-return');
      await Future<void>.delayed(const Duration(seconds: 3));
      debugPrint(
        '[Phase65] arrayPreserved L=${_ctrl.array.speakers.first.azimuthDeg} '
        'R=${_ctrl.array.speakers[1].azimuthDeg} '
        'Ldist=${_ctrl.array.speakers.first.distanceM}',
      );

      _onPlaybackMode(PlaybackMode.original);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      mark('idle-return');
      await Future<void>.delayed(const Duration(seconds: 3));
      debugPrint(
        '[Phase65] final rev=${_spatial.appliedRevision} deltaRev=${_spatial.appliedRevision - rev0}',
      );
    } catch (e) {
      debugPrint('[Phase65] failed $e');
    }
    debugPrint('[Phase65] engine done');
  }

  Future<void> _maybeRunPhase5bTransportSmoke() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.environment['YINWEI_PHASE5B_SMOKE'] != '1') return;
    for (var i = 0; i < 40 && !_ctrl.hasOpenedFile; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!_ctrl.hasOpenedFile) {
      debugPrint('[Phase5B] skip — no opened file');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    void mark(String label) {
      debugPrint(
        '[Phase5B] MARK $label playing=${_ctrl.playing} mode=${_ctrl.mode} '
        'array=${_ctrl.array.mode} sel=${_ctrl.array.selectedIndex} '
        'matrix=${_ctrl.array.matrixLinked} pos=${_ctrl.position} '
        'sceneRev=${_spatial.appliedRevision} island=${_window.mode}',
      );
      try {
        File('${Directory.systemTemp.path}${Platform.pathSeparator}yinwei_phase5b_mark.txt')
            .writeAsStringSync(label);
      } catch (_) {}
    }

    try {
      _onPlaybackMode(PlaybackMode.original);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      mark('original-paused');
      await Future<void>.delayed(const Duration(seconds: 2));

      await _ctrl.play();
      mark('original-playing');
      await Future<void>.delayed(const Duration(seconds: 2));

      await _ctrl.pause();
      mark('original-paused-after');
      await Future<void>.delayed(const Duration(seconds: 1));

      await _ctrl.seek(const Duration(seconds: 4));
      mark('original-seek');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _ctrl.play();
      mark('original-resume');
      await Future<void>.delayed(const Duration(seconds: 2));

      _onPlaybackMode(PlaybackMode.spatial);
      mark('spatial-playing');
      await Future<void>.delayed(const Duration(seconds: 2));

      final beforeArray = _ctrl.array.copy();
      _onArrayMode(ArrayMode.stereo2);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      mark('array-2.0');
      debugPrint(
        '[Phase5B] array-before mode=${beforeArray.mode} '
        'sel=${beforeArray.selectedIndex} matrix=${beforeArray.matrixLinked} '
        'speakers=${beforeArray.speakers.length}',
      );
      await Future<void>.delayed(const Duration(seconds: 2));

      await _window.enterIsland();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      mark('island-playing');
      await Future<void>.delayed(const Duration(seconds: 2));

      await _ctrl.pause();
      mark('island-paused');
      await Future<void>.delayed(const Duration(seconds: 1));
      await _ctrl.play();
      mark('island-resumed');
      await Future<void>.delayed(const Duration(seconds: 1));

      await _window.enterFull();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      mark('full-restored');
      debugPrint(
        '[Phase5B] continuity playing=${_ctrl.playing} mode=${_ctrl.mode} '
        'array=${_ctrl.array.mode} sel=${_ctrl.array.selectedIndex} '
        'matrix=${_ctrl.array.matrixLinked} pos=${_ctrl.position} '
        'sceneRev=${_spatial.appliedRevision}',
      );
    } catch (e) {
      debugPrint('[Phase5B] failed $e');
    }
    debugPrint('[Phase5B] done');
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
      final dir =
          await getDownloadsDirectory() ?? await getTemporaryDirectory();
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
