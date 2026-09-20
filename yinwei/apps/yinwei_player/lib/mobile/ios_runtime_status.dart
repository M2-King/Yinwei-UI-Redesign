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
  });

  final EngineBackend backend;
  final EngineController controller;
  final String? loadError;

  static String engineLabel(EngineBackend backend) =>
      backend == EngineBackend.native ? 'READY' : 'FAILED';

  static String nativeLabel(EngineBackend backend) =>
      backend == EngineBackend.native ? 'CONNECTED' : 'ERROR';

  static String audioLabel({
    required EngineBackend backend,
    required bool playing,
    required String? lastError,
  }) {
    if (backend != EngineBackend.native || !playing || lastError != null) {
      return 'STOPPED';
    }
    return 'RUNNING';
  }

  static String? visibleDetail({
    required bool hasOpenedFile,
    String? lastError,
    String? loadError,
  }) {
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
    final engine = engineLabel(backend);
    final native = nativeLabel(backend);
    final audio = audioLabel(
      backend: backend,
      playing: controller.playing,
      lastError: controller.lastError,
    );
    final detail = visibleDetail(
      hasOpenedFile: controller.hasOpenedFile,
      lastError: controller.lastError,
      loadError: loadError,
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
