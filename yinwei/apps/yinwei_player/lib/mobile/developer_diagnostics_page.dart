import 'package:flutter/material.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/platform/android_playback_capture.dart';
import 'package:yinwei_player/platform/developer_diagnostics.dart';
import 'package:yinwei_player/platform/screen_audio_probe.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Persistent developer diagnostics. No Xcode console required.
class DeveloperDiagnosticsPage extends StatefulWidget {
  const DeveloperDiagnosticsPage({
    super.key,
    this.controller,
    this.backend,
    this.probe,
    this.androidProbe,
    this.diagnostics,
  });

  final EngineController? controller;
  final EngineBackend? backend;
  final ScreenAudioProbe? probe;
  final AndroidPlaybackCapture? androidProbe;
  final DeveloperDiagnostics? diagnostics;

  @override
  State<DeveloperDiagnosticsPage> createState() =>
      _DeveloperDiagnosticsPageState();
}

class _DeveloperDiagnosticsPageState extends State<DeveloperDiagnosticsPage> {
  late final ScreenAudioProbe _probe;
  late final AndroidPlaybackCapture? _androidProbe;
  late final DeveloperDiagnostics _diagnostics;
  DeveloperDiagnosticsReport? _report;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _probe = widget.probe ?? ScreenAudioProbe.create();
    _androidProbe = widget.androidProbe;
    _diagnostics = widget.diagnostics ?? DeveloperDiagnostics();
    _refresh();
  }

  Future<void> _refresh() async {
    final capture = await _probe.getStatus();
    final android = await _androidProbe?.getStatus();
    final report = await _diagnostics.collect(
      controller: widget.controller,
      backend: widget.backend,
      capture: capture,
      androidCapture: android,
    );
    if (!mounted) return;
    setState(() => _report = report);
  }

  Future<void> _copy() async {
    final report = _report;
    if (report == null) return;
    await _diagnostics.copy(report);
    if (!mounted) return;
    setState(() => _statusMessage = 'Copied diagnostics');
  }

  Future<void> _export() async {
    final report = _report;
    if (report == null) return;
    final exported = await _diagnostics.export(report);
    if (!mounted) return;
    setState(() {
      if (!exported.ok) {
        _statusMessage = exported.error ?? 'Export failed';
      } else if (exported.shared) {
        _statusMessage = 'Share sheet opened';
      } else if (exported.path != null) {
        _statusMessage = 'Wrote ${exported.path}';
      } else {
        _statusMessage = 'Export JSON ready';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: YinweiColors.textSecondary,
          height: 1.35,
          fontFamily: 'Menlo',
          fontSize: 11,
        );
    return Scaffold(
      key: const Key('developer-diagnostics-page'),
      backgroundColor: YinweiColors.background,
      appBar: AppBar(
        backgroundColor: YinweiColors.panel,
        foregroundColor: YinweiColors.textPrimary,
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            key: const Key('developer-diagnostics-refresh'),
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('developer-diagnostics-copy'),
                      onPressed: report == null ? null : _copy,
                      child: const Text('Copy Diagnostics'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('developer-diagnostics-export'),
                      onPressed: report == null ? null : _export,
                      child: const Text('Export Diagnostics'),
                    ),
                  ),
                ],
              ),
            ),
            if (_statusMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _statusMessage!,
                  key: const Key('developer-diagnostics-status'),
                  style: style?.copyWith(color: YinweiColors.success),
                ),
              ),
            Expanded(
              child: report == null
                  ? const Center(child: CircularProgressIndicator())
                  : SelectionArea(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        child: Text(
                          report.asText(),
                          key: const Key('developer-diagnostics-report'),
                          style: style?.copyWith(color: YinweiColors.textPrimary),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
