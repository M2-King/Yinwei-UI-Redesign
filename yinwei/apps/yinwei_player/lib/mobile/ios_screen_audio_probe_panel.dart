import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yinwei_player/platform/screen_audio_probe.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Development-only iOS 27 capture probe. Does not replace Open file playback.
class IosScreenAudioProbePanel extends StatefulWidget {
  const IosScreenAudioProbePanel({super.key, this.probe});

  final ScreenAudioProbe? probe;

  @override
  State<IosScreenAudioProbePanel> createState() =>
      _IosScreenAudioProbePanelState();
}

class _IosScreenAudioProbePanelState extends State<IosScreenAudioProbePanel> {
  late final ScreenAudioProbe _probe;
  ScreenAudioProbeStatus _status = ScreenAudioProbeStatus.unavailable;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _probe = widget.probe ?? ScreenAudioProbe.create();
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
    final live = status.pickerActive || status.captureActive;
    if (live && _poll == null) {
      _setPolling(true);
    } else if (!live && _poll != null) {
      _setPolling(false);
    }
  }

  Future<void> _start() async {
    await _probe.startCapture();
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
    ].join(' / ');
    final rms = _status.audioSilent && _status.lastRmsDb == null
        ? '-inf/silent'
        : _status.lastRmsDb == null
            ? '—'
            : '${_status.lastRmsDb!.toStringAsFixed(1)} dB';
    final peak = _status.lastPeakDb == null
        ? '—'
        : '${_status.lastPeakDb!.toStringAsFixed(1)} dB';
    return Semantics(
      container: true,
      label: 'iOS 27 capture probe ${_status.phaseLabel}',
      child: Container(
        key: const Key('ios-screen-audio-probe'),
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
                    'Live Transfer — iOS 27 PoC',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 12),
                  ),
                ),
                Text(
                  _status.phaseLabel,
                  key: const Key('ios-screen-audio-probe-phase'),
                  style: style?.copyWith(color: YinweiColors.textPrimary),
                ),
              ],
            ),
            Text(
              [
                'System Audio Buffers: ${_status.audioBufferCount}',
                'Mic Buffers: ${_status.microphoneBufferCount}',
                if (format.isNotEmpty) format,
                'RMS: $rms',
                'Peak: $peak',
                if (_status.lastError != null) _status.lastError!,
              ].join('   '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: OutlinedButton(
                      key: const Key('ios-screen-audio-probe-start'),
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
                      key: const Key('ios-screen-audio-probe-stop'),
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
          ],
        ),
      ),
    );
  }
}
