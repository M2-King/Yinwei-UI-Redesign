import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/platform/spatial_workspace_host.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/spatial_workspace_html.dart';

/// Injected into the Three.js document so JS can post intents without
/// `chrome.webview`. Windows WebView2 still uses chrome.webview first.
const kYinweiPoseBridgeScript = '''
window.YinweiPose = {
  postMessage: function (msg) {
    if (window.chrome && window.chrome.webview) {
      try {
        window.chrome.webview.postMessage(
          typeof msg === 'string' ? JSON.parse(msg) : msg
        );
      } catch (e) {
        window.chrome.webview.postMessage(msg);
      }
    }
  }
};
''';

/// Left-pane Spatial Audio Workspace.
///
/// Windows: one persistent Three.js studio in WebView2.
/// Presentation idle / point / stereo2 is derived from playback + Array state.
/// Tests / non-Windows / missing WebView2: [OrbitVisualizer] fallback.
///
/// Three.js proposes world-XYZ intents. Flutter Scene Store is the Point
/// authority. Array speakers are a visual overlay, not SceneContract objects.
class SpatialWorkspace extends StatefulWidget {
  const SpatialWorkspace({
    super.key,
    required this.playhead,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
    required this.envelopment,
    this.active = true,
    this.orbiting = false,
    this.playing = false,
    this.playbackMode = PlaybackMode.spatial,
    this.arrayMode = ArrayMode.off,
    this.playbackTelemetry,
    this.arraySpeakers,
    this.selectedSpeakerIndex = 0,
    this.sceneSnapshot,
    this.selectedObjectId,
    this.onSceneIntent,
    this.onPoseChanged,
    this.onDistanceChanged,
    this.onSpeakerSelected,
    this.onSpeakerPoseChanged,
    this.onSpeakerDistanceChanged,
    this.onSpeakerAdd,
    this.matrixLinked = false,
    this.forceFallback = false,
    this.suspended = false,
    this.capabilities,
  });

  final double playhead;
  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
  final double envelopment;
  final bool active;
  final bool orbiting;
  final bool playing;
  final PlaybackMode playbackMode;
  final ArrayMode arrayMode;
  final ValueListenable<PlaybackTelemetryV1>? playbackTelemetry;
  final List<ArraySpeaker>? arraySpeakers;

  WorkspacePresentation get presentation => workspacePresentationOf(
        playbackMode: playbackMode,
        arrayMode: arrayMode,
      );
  final int selectedSpeakerIndex;
  final Map<String, dynamic>? sceneSnapshot;
  final String? selectedObjectId;
  final SceneBridgeResult Function(String message)? onSceneIntent;
  final void Function(double azimuthDeg, double elevationDeg)? onPoseChanged;
  final ValueChanged<double>? onDistanceChanged;
  final ValueChanged<int>? onSpeakerSelected;
  final void Function(int index, double azimuthDeg, double elevationDeg)?
      onSpeakerPoseChanged;
  final void Function(int index, double distanceM)? onSpeakerDistanceChanged;
  final void Function(double azimuthDeg, double elevationDeg, double distanceM)?
      onSpeakerAdd;
  final bool matrixLinked;
  final bool forceFallback;
  final bool suspended;
  final PlatformCapabilities? capabilities;

  @override
  State<SpatialWorkspace> createState() => _SpatialWorkspaceState();
}

class _SpatialWorkspaceState extends State<SpatialWorkspace> {
  late SpatialWorkspaceHost _host;
  var _pageReady = false;
  var _failed = false;
  int? _lastSceneRevision;
  String? _lastTelemetry;
  String? _lastUi;
  String? _lastPresentation;
  var _phase3SmokeStarted = false;
  var _phase6SmokeStarted = false;
  var _bootStarted = false;
  Future<void> _visibilityWork = Future<void>.value();

  void _syncVisibility() {
    _visibilityWork = _visibilityWork.then((_) async {
      if (!mounted || !_host.usesWebView) return;
      await _host.setSuspended(widget.suspended);
      if (!widget.suspended && mounted) _pushAll();
    }).catchError((Object e) {
      debugPrint('[SpatialWorkspace] visibility: $e');
    });
  }

  bool get _useWebView {
    if (widget.forceFallback) return false;
    if (_failed) return false;
    return _host.usesWebView;
  }

  @override
  void initState() {
    super.initState();
    final inTest = Platform.environment.containsKey('FLUTTER_TEST');
    _host = createSpatialWorkspaceHost(
      capabilities: widget.capabilities ?? PlatformCapabilities.detect(),
      forceFallback: widget.forceFallback || inTest,
    );
    debugPrint(
      '[SpatialWorkspace] windows=${Platform.isWindows} '
      'flutterTest=$inTest '
      'presentation=${widget.presentation.name} '
      'array=${widget.arrayMode.name} forceFallback=${widget.forceFallback} '
      'useWebView=$_useWebView',
    );
    if (_useWebView) {
      _bootStarted = true;
      unawaited(_bootHost());
    }
    widget.playbackTelemetry?.addListener(_onTelemetry);
  }

  PlaybackTelemetryV1 get _tel =>
      widget.playbackTelemetry?.value ??
      PlaybackTelemetryV1(
        playhead: widget.playhead,
        playing: widget.playing,
        orbiting: widget.orbiting,
        envelopment: widget.envelopment,
        active: widget.active,
        azimuthDeg: widget.azimuthDeg,
        elevationDeg: widget.elevationDeg,
      );

  void _onTelemetry() {
    if (!mounted) return;
    if (_useWebView) {
      if (!TickerMode.of(context)) return;
      _pushTelemetry();
      return;
    }
    setState(() {});
  }

  Future<void> _bootHost() async {
    if (_host.view != null) return;
    try {
      final html = await SpatialWorkspaceHtml.load();
      if (!mounted) return;
      await _host.boot(
        html: html,
        poseBridgeScript: kYinweiPoseBridgeScript,
        onMessage: _onWinMessage,
        onReady: () {
          _pageReady = true;
          _pushAll(force: true);
        },
        onLoadError: (error) {
          debugPrint('[SpatialWorkspace] load error $error');
        },
      );
      if (!mounted) {
        await _host.dispose();
        return;
      }
      debugPrint('[SpatialWorkspace] WebView2 controller ready');
      setState(() {});
      _syncVisibility();
      _maybeStartPhase3Smoke();
    } catch (e) {
      debugPrint('[SpatialWorkspace] WebView2 boot failed: $e');
      if (mounted) {
        setState(() {
          _failed = true;
          _host = FallbackWorkspaceHost();
        });
      }
    }
  }

  void _onWinMessage(dynamic message) {
    final raw = message is String ? message : jsonEncode(message);
    debugPrint(
      '[SpatialWorkspace] js ${raw.length > 240 ? raw.substring(0, 240) : raw}',
    );
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      data = null;
    }
    if (data != null && _handleArrayVisualIntent(data)) {
      return;
    }
    final handler = widget.onSceneIntent;
    if (handler != null) {
      SceneBridgeResult result;
      try {
        result = handler(raw);
      } catch (_) {
        return;
      }
      _sendOutgoing(result.outgoing);
      if ((data?['type'] as String? ?? '') == 'ready') {
        _pageReady = true;
        _pushPresentation(force: true);
      }
      _maybeStartPhase3Smoke();
      return;
    }
    if (data == null) return;
    if ((data['type'] as String? ?? '') == 'ready') {
      _pageReady = true;
      _pushAll(force: true);
      _maybeStartPhase3Smoke();
    }
  }

  bool _handleArrayVisualIntent(Map<String, dynamic> data) {
    final type = data['type'] as String? ?? '';
    if (type == 'arraySpeakerSelect' || type == 'selectObject') {
      final index = data['index'] is num
          ? (data['index'] as num).toInt()
          : arraySpeakerIndexFromId(data['objectId'] as String?);
      if (index == null) {
        return type == 'arraySpeakerSelect';
      }
      widget.onSpeakerSelected?.call(index);
      return true;
    }
    if (type == 'arraySpeakerPosePreview' || type == 'arraySpeakerPoseCommit') {
      final index = data['index'] is num
          ? (data['index'] as num).toInt()
          : arraySpeakerIndexFromId(data['objectId'] as String?);
      if (index == null) return true;
      final az = (data['azimuthDeg'] as num?)?.toDouble();
      final el = (data['elevationDeg'] as num?)?.toDouble();
      final dist = (data['distanceM'] as num?)?.toDouble();
      if (az != null && el != null) {
        widget.onSpeakerPoseChanged?.call(index, az, el);
      }
      if (dist != null) {
        widget.onSpeakerDistanceChanged?.call(index, dist);
      }
      return true;
    }
    return false;
  }

  Map<String, dynamic> _sceneMessage() {
    final scene = widget.sceneSnapshot ?? const <String, dynamic>{};
    return {
      'type': 'sceneSnapshot',
      'schemaVersion': scene['schemaVersion'] ?? 1,
      'revision': scene['revision'] ?? 0,
      'scene': scene,
    };
  }

  Map<String, dynamic> _telemetryMessage() => _tel.toHostMessage();

  Map<String, dynamic> _uiMessage() {
    final selected = widget.presentation == WorkspacePresentation.stereo2
        ? arraySpeakerObjectId(widget.selectedSpeakerIndex)
        : widget.selectedObjectId;
    return {
      'type': 'uiState',
      'selectedObjectId': selected,
    };
  }

  Map<String, dynamic> _presentationMessage() {
    final presentation = widget.presentation;
    final speakers = presentation == WorkspacePresentation.stereo2
        ? arraySpeakerVisuals(
            speakers: widget.arraySpeakers ?? const [],
            selectedIndex: widget.selectedSpeakerIndex,
          )
        : const <ArraySpeakerVisual>[];
    return {
      'type': 'presentationState',
      'presentation': presentation.name,
      'selectedSpeakerIndex': widget.selectedSpeakerIndex,
      'arraySpeakers': speakers.map((s) => s.toJson()).toList(),
    };
  }

  void _sendOutgoing(List<Map<String, dynamic>> messages) {
    for (final msg in messages) {
      final type = msg['type'];
      if (type == 'sceneSnapshot') {
        _run('applySceneSnapshot', msg);
        _lastSceneRevision = msg['revision'] as int?;
      } else if (type == 'playbackTelemetry') {
        final payload = jsonEncode(msg);
        _lastTelemetry = payload;
        _runRaw('applyPlaybackTelemetry', payload);
      } else if (type == 'uiState') {
        final payload = jsonEncode(msg);
        _lastUi = payload;
        _runRaw('applyUiState', payload);
      } else if (type == 'presentationState') {
        final payload = jsonEncode(msg);
        _lastPresentation = payload;
        _runRaw('applyPresentation', payload);
      }
    }
  }

  void _run(String fn, Map<String, dynamic> msg) {
    _runRaw(fn, jsonEncode(msg));
  }

  void _runRaw(String fn, String payload) {
    if (!_host.usesWebView || !_pageReady || !mounted) return;
    if (!TickerMode.of(context)) return;
    unawaited(
      _host.executeScript(
        'window.YinweiWorkspace&&YinweiWorkspace.$fn($payload)',
      ),
    );
  }

  void _pushScene({bool force = false}) {
    final scene = widget.sceneSnapshot;
    if (scene == null) return;
    final revision = scene['revision'];
    if (!force && revision == _lastSceneRevision) return;
    debugPrint('[SpatialWorkspace] applySceneSnapshot revision=$revision');
    _lastSceneRevision = revision is int ? revision : null;
    _run('applySceneSnapshot', _sceneMessage());
  }

  void _pushTelemetry({bool force = false}) {
    final payload = jsonEncode(_telemetryMessage());
    if (!force && payload == _lastTelemetry) return;
    _lastTelemetry = payload;
    _runRaw('applyPlaybackTelemetry', payload);
  }

  void _pushUi({bool force = false}) {
    final payload = jsonEncode(_uiMessage());
    if (!force && payload == _lastUi) return;
    _lastUi = payload;
    _runRaw('applyUiState', payload);
  }

  void _pushPresentation({bool force = false}) {
    final payload = jsonEncode(_presentationMessage());
    if (!force && payload == _lastPresentation) return;
    _lastPresentation = payload;
    _runRaw('applyPresentation', payload);
  }

  void _pushAll({bool force = false}) {
    _pushScene(force: force);
    _pushTelemetry(force: force);
    _pushUi(force: force);
    _pushPresentation(force: force);
    _maybeStartPhase3Smoke();
    _maybeStartPhase6Smoke();
  }

  void _maybeStartPhase6Smoke() {
    if (_phase6SmokeStarted) return;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.environment['YINWEI_PHASE6_SMOKE'] != '1') return;
    if (!_pageReady || !_host.usesWebView) return;
    _phase6SmokeStarted = true;
    unawaited(_runPhase6Smoke());
  }

  Future<void> _runPhase6Smoke() async {
    debugPrint('[Phase6] workspace start');
    Map<String, dynamic>? inspect;
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final raw = await _js(
        'window.YinweiWorkspace&&YinweiWorkspace.debug.inspect()',
      );
      if (raw is Map) {
        inspect = Map<String, dynamic>.from(raw);
        final ids = inspect['ids'];
        if (ids is List &&
            ids.contains('source-main') &&
            ids.contains('listener-0')) {
          break;
        }
      }
    }
    debugPrint('[Phase6] inspect-before=$inspect');
    await Future<void>.delayed(const Duration(seconds: 3));
    Future<void> step(String name, String expr) async {
      final result = await _js(expr);
      debugPrint('[Phase6] $name $result');
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }

    await step('click-listener', 'YinweiWorkspace.debug.click("listener-0")');
    await step('click-source', 'YinweiWorkspace.debug.click("source-main")');
    await step('click-emitter', 'YinweiWorkspace.debug.click("emitter-L")');
    for (var i = 0; i < 10; i++) {
      await step(
        'nudge-xz-$i',
        'YinweiWorkspace.debug.nudgeSource(0.08, 0, -0.04, false)',
      );
    }
    await step('nudge-xz-commit',
        'YinweiWorkspace.debug.nudgeSource(0.05, 0, 0, true)');
    for (var i = 0; i < 4; i++) {
      await step(
          'nudge-y-$i', 'YinweiWorkspace.debug.nudgeSource(0, 0.06, 0, false)');
    }
    await step('nudge-y-commit',
        'YinweiWorkspace.debug.nudgeSource(0, 0.04, 0, true)');
    await step('set-free', 'YinweiWorkspace.debug.setView("free")');
    await step('orbit', 'YinweiWorkspace.debug.orbit()');
    await step('pan', 'YinweiWorkspace.debug.pan()');
    await step('zoom', 'YinweiWorkspace.debug.zoom()');
    await step('top', 'YinweiWorkspace.debug.setView("top")');
    await step('front', 'YinweiWorkspace.debug.setView("front")');
    await step('listener-view', 'YinweiWorkspace.debug.setView("listener")');
    await step('fit', 'YinweiWorkspace.debug.setView("fit")');
    await step('inspect-final', 'YinweiWorkspace.debug.inspect()');
    debugPrint('[Phase6] workspace done');
  }

  void _maybeStartPhase3Smoke() {
    if (_phase3SmokeStarted) return;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.environment['YINWEI_PHASE3_SMOKE'] != '1') return;
    if (!_pageReady || !_host.usesWebView) return;
    _phase3SmokeStarted = true;
    unawaited(_runPhase3Smoke());
  }

  Future<dynamic> _js(String expr) async {
    if (!_host.usesWebView || !_pageReady) return null;
    return _host.executeScript(expr);
  }

  Future<void> _runPhase3Smoke() async {
    debugPrint('[Phase3Smoke] workspace start');
    Map<String, dynamic>? inspect;
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final raw = await _js(
        'window.YinweiWorkspace&&YinweiWorkspace.debug.inspect()',
      );
      if (raw is Map) {
        inspect = Map<String, dynamic>.from(raw);
        final ids = inspect['ids'];
        if (ids is List &&
            ids.contains('source-main') &&
            ids.contains('listener-0')) {
          break;
        }
      }
    }
    debugPrint('[Phase3Smoke] inspect=$inspect');

    Future<void> step(String name, String expr) async {
      final result = await _js(expr);
      debugPrint('[Phase3Smoke] $name $result');
      await Future<void>.delayed(const Duration(milliseconds: 280));
    }

    await step('click-listener', 'YinweiWorkspace.debug.click("listener-0")');
    await step('click-emitter', 'YinweiWorkspace.debug.click("emitter-L")');
    await step('click-source', 'YinweiWorkspace.debug.click("source-main")');
    await step('drag-xz', 'YinweiWorkspace.debug.dragSource("xz", 80)');
    await step('drag-y', 'YinweiWorkspace.debug.dragSource("y", 55)');
    await step('set-free', 'YinweiWorkspace.debug.setView("free")');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await step('orbit', 'YinweiWorkspace.debug.orbit()');
    await step('pan', 'YinweiWorkspace.debug.pan()');
    await step('zoom', 'YinweiWorkspace.debug.zoom()');
    await step('top', 'YinweiWorkspace.debug.setView("top")');
    await step('front', 'YinweiWorkspace.debug.setView("front")');
    await step('listener-view', 'YinweiWorkspace.debug.setView("listener")');
    await step('fit', 'YinweiWorkspace.debug.setView("fit")');
    await step('inspect-final', 'YinweiWorkspace.debug.inspect()');
    try {
      final png = await _js('YinweiWorkspace.debug.capture()');
      if (png is String && png.startsWith('data:image/png;base64,')) {
        final bytes = base64Decode(png.split(',').last);
        final out = File('test/goldens/phase3_functional_runtime.png');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(bytes);
        debugPrint(
          '[Phase3Smoke] captured ${out.absolute.path} bytes=${bytes.length}',
        );
      } else {
        debugPrint('[Phase3Smoke] capture type=${png.runtimeType}');
      }
    } catch (e) {
      debugPrint('[Phase3Smoke] capture failed $e');
    }
    debugPrint('[Phase3Smoke] workspace done');
  }

  @override
  void didUpdateWidget(covariant SpatialWorkspace old) {
    super.didUpdateWidget(old);
    if (old.suspended != widget.suspended) _syncVisibility();
    if (old.playbackTelemetry != widget.playbackTelemetry) {
      old.playbackTelemetry?.removeListener(_onTelemetry);
      widget.playbackTelemetry?.addListener(_onTelemetry);
    }
    if (_useWebView) {
      if (_host.view == null && !_failed && !_bootStarted) {
        _bootStarted = true;
        unawaited(_bootHost());
      } else if (!widget.suspended) {
        _pushAll();
      }
    }
  }

  @override
  void dispose() {
    widget.playbackTelemetry?.removeListener(_onTelemetry);
    unawaited(_host.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget viewport;
    if (!_useWebView) {
      viewport = OrbitVisualizer(
        playhead: _tel.playhead,
        azimuthDeg: _tel.azimuthDeg,
        elevationDeg: _tel.elevationDeg,
        distanceM: widget.distanceM,
        envelopment: _tel.envelopment,
        active: _tel.active,
        orbiting: _tel.orbiting,
        arraySpeakers: widget.presentation == WorkspacePresentation.stereo2
            ? widget.arraySpeakers
            : null,
        selectedSpeakerIndex: widget.selectedSpeakerIndex,
        onPoseChanged: widget.onPoseChanged,
        onDistanceChanged: widget.onDistanceChanged,
        onSpeakerSelected: widget.onSpeakerSelected,
        onSpeakerPoseChanged: widget.onSpeakerPoseChanged,
        onSpeakerDistanceChanged: widget.onSpeakerDistanceChanged,
        onSpeakerAdd: widget.onSpeakerAdd,
        matrixLinked: widget.matrixLinked,
      );
    } else {
      final view = _host.view;
      viewport = view ??
          const ColoredBox(
            color: YinweiColors.background,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
            ),
          );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(YinweiLayout.workspaceRadius),
      child: SizedBox.expand(child: viewport),
    );
  }
}
