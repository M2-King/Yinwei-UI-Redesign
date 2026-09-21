import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/mobile/developer_diagnostics_page.dart';
import 'package:yinwei_player/platform/android_playback_capture.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Development-only Android AudioPlaybackCapture probe.
/// Does not replace Open file playback and does not spatialize.
class AndroidPlaybackCapturePanel extends StatefulWidget {
  const AndroidPlaybackCapturePanel({
    super.key,
    this.probe,
    this.controller,
    this.backend,
  });

  final AndroidPlaybackCapture? probe;
  final EngineController? controller;
  final EngineBackend? backend;

  @override
  State<AndroidPlaybackCapturePanel> createState() =>
      _AndroidPlaybackCapturePanelState();
}

class _AndroidPlaybackCapturePanelState
    extends State<AndroidPlaybackCapturePanel> {
  late final AndroidPlaybackCapture _probe;
  AndroidPlaybackCaptureStatus _status = AndroidPlaybackCaptureStatus.unavailable;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _probe = widget.probe ?? AndroidPlaybackCapture.create();
    _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _setPolling(bool enabled) {
    _poll?.cancel();
    _poll = null;
    if (!enabled) return;
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _refresh();
    });
  }

  Future<void> _refresh() async {
    final status = await _probe.getStatus();
    if (!mounted) return;
    setState(() => _status = status);
    final live = status.permissionPending || status.captureActive;
    if (live && _poll == null) {
      _setPolling(true);
    } else if (!live && _poll != null) {
      _setPolling(false);
    }
  }

  Future<void> _start() async {
    await _probe.requestAndStartCapture();
    await _refresh();
    _setPolling(true);
  }

  Future<void> _stop() async {
    await _probe.stopCapture();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: YinweiColors.textSecondary,
          height: 1.2,
          fontSize: 11,
        );
    final format = [
      if (_status.sampleRate != null) '${_status.sampleRate} Hz',
      if (_status.channelCount != null) '${_status.channelCount} ch',
      if (_status.encoding != null) _status.encoding!,
    ].join(' / ');
    final rms = _status.silent && _status.rmsDb == null
        ? '-inf/silent'
        : _status.rmsDb == null
            ? '—'
            : '${_status.rmsDb!.toStringAsFixed(1)} dB';
    final peak = _status.peakDb == null
        ? '—'
        : '${_status.peakDb!.toStringAsFixed(1)} dB';
    return Semantics(
      container: true,
      label: 'Android playback capture probe ${_status.phaseLabel}',
      child: Container(
        key: const Key('android-playback-capture'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: BoxDecoration(
          color: YinweiColors.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: YinweiColors.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Live Transfer — Android PoC',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontSize: 12),
                  ),
                ),
                Text(
                  _status.phaseLabel,
                  key: const Key('android-playback-capture-phase'),
                  style: style?.copyWith(color: YinweiColors.textPrimary),
                ),
              ],
            ),
            Text(
              'Captures other apps’ playback. Does not spatialize. Use Start Capture, not Play.',
              style: style,
            ),
            Text(
              [
                'Buffers / reads: ${_status.readCount}',
                'Frames: ${_status.capturedFrames}',
                if (format.isNotEmpty) format,
                'RMS: $rms',
                'Peak: $peak',
              ].join('   '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
            if (_status.captureHint != null)
              Text(
                _status.captureHint!,
                style: style,
              ),
            if (_status.lastError != null)
              Text(
                _status.lastError!,
                style: style,
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: OutlinedButton(
                      key: const Key('android-playback-capture-start'),
                      onPressed: _status.supported ? _start : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: YinweiColors.textPrimary,
                        visualDensity: VisualDensity.compact,
                        side: const BorderSide(color: YinweiColors.hairlineStrong),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Start Capture'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: OutlinedButton(
                      key: const Key('android-playback-capture-stop'),
                      onPressed: _status.supported || _status.captureActive
                          ? _stop
                          : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: YinweiColors.textPrimary,
                        visualDensity: VisualDensity.compact,
                        side: const BorderSide(color: YinweiColors.hairlineStrong),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Stop Capture'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              height: 32,
              child: OutlinedButton(
                key: const Key('android-developer-diagnostics-open'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DeveloperDiagnosticsPage(
                        controller: widget.controller,
                        backend: widget.backend,
                        androidProbe: _probe,
                      ),
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: YinweiColors.textPrimary,
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(color: YinweiColors.hairlineStrong),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Diagnostics'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
