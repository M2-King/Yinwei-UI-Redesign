import 'package:flutter/material.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Debug-only iPhone readout. Mock must never look like a live native engine.
class IosRuntimeStatusBanner extends StatelessWidget {
  const IosRuntimeStatusBanner({
    super.key,
    required this.backend,
    required this.controller,
    this.loadError,
    this.androidCaptureOnly = false,
  });

  final EngineBackend backend;
  final EngineController controller;
  final String? loadError;
  final bool androidCaptureOnly;

  static String engineLabel(
    EngineBackend backend, {
    bool androidCaptureOnly = false,
  }) {
    if (androidCaptureOnly) return 'CAPTURE-ONLY';
    return backend == EngineBackend.native ? 'READY' : 'FAILED';
  }

  static String nativeLabel(
    EngineBackend backend, {
    bool androidCaptureOnly = false,
  }) {
    if (androidCaptureOnly) return 'A1 (no spatial_core)';
    return backend == EngineBackend.native ? 'CONNECTED' : 'ERROR';
  }

  static String audioLabel({
    required EngineBackend backend,
    required bool playing,
    required String? lastError,
    bool androidCaptureOnly = false,
  }) {
    if (androidCaptureOnly) return 'IDLE';
    if (backend != EngineBackend.native || !playing || lastError != null) {
      return 'STOPPED';
    }
    return 'RUNNING';
  }

  static String? visibleDetail({
    required bool hasOpenedFile,
    String? lastError,
    String? loadError,
    bool androidCaptureOnly = false,
  }) {
    if (androidCaptureOnly) {
      return 'Expected on Android A1. Use Start Capture — Play does not spatialize.';
    }
    if (lastError != null &&
        lastError.contains('NoTrackLoaded') &&
        !hasOpenedFile) {
      if (loadError == null || loadError.isEmpty) return null;
      return loadError;
    }
    return lastError ?? loadError;
  }

  @override
  Widget build(BuildContext context) {
    final engine = engineLabel(
      backend,
      androidCaptureOnly: androidCaptureOnly,
    );
    final native = nativeLabel(
      backend,
      androidCaptureOnly: androidCaptureOnly,
    );
    final audio = audioLabel(
      backend: backend,
      playing: controller.playing,
      lastError: controller.lastError,
      androidCaptureOnly: androidCaptureOnly,
    );
    final detail = visibleDetail(
      hasOpenedFile: controller.hasOpenedFile,
      lastError: controller.lastError,
      loadError: loadError,
      androidCaptureOnly: androidCaptureOnly,
    );
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: YinweiColors.textSecondary,
          height: 1.35,
        );
    return Semantics(
      container: true,
      label: 'Engine $engine Native $native Audio $audio',
      child: Container(
        key: const Key('ios-runtime-status'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: YinweiColors.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: YinweiColors.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Engine: $engine', style: style),
            Text('Native: $native', style: style),
            Text('Audio: $audio', style: style),
            if (detail != null && detail.isNotEmpty)
              Text(detail, style: style),
          ],
        ),
      ),
    );
  }
}
