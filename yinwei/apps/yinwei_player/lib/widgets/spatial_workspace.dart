import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/spatial_workspace_html.dart';

/// Left-pane Spatial Audio Workspace.
///
/// Windows Point mode: local Three.js scene in WebView2.
/// Tests / Array / non-Windows: [OrbitVisualizer].
///
/// Three.js proposes world-XYZ intents. Flutter Scene Store is authoritative.
/// Array speakers keep the native OrbitVisualizer path.
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
  });

  final double playhead;
  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
  final double envelopment;
  final bool active;
  final bool orbiting;
  final bool playing;
  final List<ArraySpeaker>? arraySpeakers;
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

  @override
  State<SpatialWorkspace> createState() => _SpatialWorkspaceState();
}

class _SpatialWorkspaceState extends State<SpatialWorkspace> {
  WebviewController? _web;
  final _subs = <StreamSubscription>[];
  var _pageReady = false;
  var _failed = false;
  int? _lastSceneRevision;
  String? _lastTelemetry;
  String? _lastUi;
  var _phase3SmokeStarted = false;

  bool get _arrayOn =>
      widget.arraySpeakers != null && widget.arraySpeakers!.isNotEmpty;

  bool get _useWebView {
    if (widget.forceFallback) return false;
    if (_arrayOn) return false;
    if (_failed) return false;
    if (kIsWeb) return false;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
    return Platform.isWindows;
  }

  @override
  void initState() {
    super.initState();
    debugPrint(
      '[SpatialWorkspace] windows=${Platform.isWindows} '
      'flutterTest=${Platform.environment.containsKey('FLUTTER_TEST')} '
      'array=$_arrayOn forceFallback=${widget.forceFallback} '
      'useWebView=$_useWebView',
    );
    if (_useWebView) {
      unawaited(_bootWebView());
    }
  }

  Future<void> _bootWebView() async {
    try {
      final version = await WebviewController.getWebViewVersion();
      debugPrint('[SpatialWorkspace] WebView2 runtime=$version');
      if (version == null) {
        throw StateError('WebView2 runtime missing');
      }
      final html = await SpatialWorkspaceHtml.load();
      final controller = WebviewController();
      await controller.initialize();
      _subs.add(controller.webMessage.listen(_onWinMessage));
      _subs.add(
        controller.loadingState.listen((state) {
          if (state == LoadingState.navigationCompleted) {
            _pageReady = true;
            _pushAll(force: true);
          }
        }),
      );
      _subs.add(
        controller.onLoadError.listen((status) {
          debugPrint('[SpatialWorkspace] load error $status');
        }),
      );
      await controller.setBackgroundColor(YinweiColors.background);
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await controller.addScriptToExecuteOnDocumentCreated('''
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
''');
      await controller.loadStringContent(html);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      debugPrint('[SpatialWorkspace] WebView2 controller ready');
      setState(() => _web = controller);
      _maybeStartPhase3Smoke();
    } catch (e) {
      debugPrint('[SpatialWorkspace] WebView2 boot failed: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onWinMessage(dynamic message) {
    final raw = message is String ? message : jsonEncode(message);
    debugPrint(
      '[SpatialWorkspace] js ${raw.length > 240 ? raw.substring(0, 240) : raw}',
    );
    final handler = widget.onSceneIntent;
    if (handler != null) {
      SceneBridgeResult result;
      try {
        result = handler(raw);
      } catch (_) {
        return;
      }
      _sendOutgoing(result.outgoing);
      _maybeStartPhase3Smoke();
      return;
    }
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (_) {
      return;
    }
    if (data == null) return;
    if ((data['type'] as String? ?? '') == 'ready') {
      _pageReady = true;
      _pushAll(force: true);
      _maybeStartPhase3Smoke();
    }
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

  Map<String, dynamic> _telemetryMessage() => {
        'type': 'playbackTelemetry',
        'playhead': widget.playhead,
        'playing': widget.playing,
        'orbiting': widget.orbiting,
        'envelopment': widget.envelopment,
        'active': widget.active,
      };

  Map<String, dynamic> _uiMessage() => {
        'type': 'uiState',
        'selectedObjectId': widget.selectedObjectId,
      };

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
      }
    }
  }

  void _run(String fn, Map<String, dynamic> msg) {
    _runRaw(fn, jsonEncode(msg));
  }

  void _runRaw(String fn, String payload) {
    final web = _web;
    if (web == null || !_pageReady) return;
    unawaited(
      web.executeScript(
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

  void _pushAll({bool force = false}) {
    _pushScene(force: force);
    _pushTelemetry(force: force);
    _pushUi(force: force);
    _maybeStartPhase3Smoke();
  }

  void _maybeStartPhase3Smoke() {
    if (_phase3SmokeStarted) return;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.environment['YINWEI_PHASE3_SMOKE'] != '1') return;
    if (!_pageReady || _web == null) return;
    _phase3SmokeStarted = true;
    unawaited(_runPhase3Smoke());
  }

  Future<dynamic> _js(String expr) async {
    final web = _web;
    if (web == null || !_pageReady) return null;
    return web.executeScript(expr);
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
    if (_useWebView) _pushAll();
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    final web = _web;
    if (web != null) {
      unawaited(web.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget viewport;
    if (!_useWebView) {
      viewport = OrbitVisualizer(
        playhead: widget.playhead,
        azimuthDeg: widget.azimuthDeg,
        elevationDeg: widget.elevationDeg,
        distanceM: widget.distanceM,
        envelopment: widget.envelopment,
        active: widget.active,
        orbiting: widget.orbiting,
        arraySpeakers: widget.arraySpeakers,
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
      final web = _web;
      viewport = web == null
          ? const ColoredBox(
              color: YinweiColors.background,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              ),
            )
          : ColoredBox(
              color: YinweiColors.background,
              child: Webview(web),
            );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(6, 0, 6, 8),
          child: Text(
            'SPATIAL WORKSPACE',
            style: TextStyle(
              color: YinweiColors.textSecondary,
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: viewport,
          ),
        ),
      ],
    );
  }
}
