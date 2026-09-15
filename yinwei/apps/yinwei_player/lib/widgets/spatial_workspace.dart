import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:yinwei_player/models/spatial_math.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';
import 'package:yinwei_player/widgets/spatial_workspace_html.dart';

/// Left-pane Spatial Audio Workspace.
///
/// Windows: local Three.js scene in WebView2 (true XYZ meshes).
/// Tests / non-Windows: existing [OrbitVisualizer] so CI and audio wiring stay intact.
///
/// Audio: Point mode posts Source az/el/dist to Dart. Discrete 2.0 speakers
/// use [OrbitVisualizer] so extra points / matrix stay on the native HRTF path.
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
  WebViewController? _web;
  var _pageReady = false;
  var _failed = false;
  String? _lastJs;

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
    if (_useWebView) {
      unawaited(_bootWebView());
    }
  }

  Future<void> _bootWebView() async {
    try {
      final html = await SpatialWorkspaceHtml.load();
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(YinweiColors.background)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              _pageReady = true;
              _pushState(force: true);
            },
            onWebResourceError: (_) {
              if (mounted) setState(() => _failed = true);
            },
          ),
        )
        ..addJavaScriptChannel(
          'YinweiPose',
          onMessageReceived: _onJsMessage,
        );
      await controller.loadHtmlString(html);
      if (!mounted) return;
      setState(() => _web = controller);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onJsMessage(JavaScriptMessage message) {
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (_) {
      return;
    }
    if (data == null) return;
    final type = data['type'] as String? ?? '';
    if (type == 'ready') {
      _pageReady = true;
      _pushState(force: true);
      return;
    }
    if (type == 'source') {
      final az = (data['azimuth'] as num?)?.toDouble();
      final el = (data['elevation'] as num?)?.toDouble();
      final dist = (data['distance'] as num?)?.toDouble();
      if (az != null && el != null) {
        widget.onPoseChanged?.call(az, el);
      }
      if (dist != null) {
        // Scene V1 keeps unclamped geometric metres. DSP clamp happens in
        // AudioProjectionV1 after SpatialSceneStore accepts the snapshot.
        widget.onDistanceChanged?.call(dist);
      }
    }
    // speaker messages: visual HUD only — do not call the engine.
  }

  Map<String, Object?> _statePayload() => {
        'azimuth': widget.azimuthDeg,
        'elevation': widget.elevationDeg,
        'distance': widget.distanceM,
        'envelopment': widget.envelopment,
        'playhead': widget.playhead,
        'playing': widget.playing,
        'active': widget.active,
        'orbiting': widget.orbiting,
        'speakers': VisualSpeaker.itu8.map((s) => s.toJson()).toList(),
      };

  void _pushState({bool force = false}) {
    final web = _web;
    if (web == null || !_pageReady) return;
    final payload = jsonEncode(_statePayload());
    if (!force && payload == _lastJs) return;
    _lastJs = payload;
    unawaited(
      web.runJavaScript(
        'window.YinweiWorkspace&&YinweiWorkspace.applyState($payload)',
      ),
    );
  }

  @override
  void didUpdateWidget(covariant SpatialWorkspace old) {
    super.didUpdateWidget(old);
    if (_useWebView) _pushState();
  }

  @override
  Widget build(BuildContext context) {
    if (!_useWebView) {
      return OrbitVisualizer(
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
    }
    final web = _web;
    if (web == null) {
      return const ColoredBox(
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
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: YinweiColors.background,
        child: WebViewWidget(controller: web),
      ),
    );
  }
}
