import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/mobile/ios_screen_audio_probe_panel.dart';
import 'package:yinwei_player/mobile/ios_remote_live_screen.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';
import 'package:yinwei_player/platform/screen_audio_probe.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

enum _ProbeMenuAction { reset, screenAudio, liveTransform }

/// Native cross-app audio feasibility gate. Audio never enters Flutter in N0.
class IosReplayKitAudioProbePanel extends StatefulWidget {
  const IosReplayKitAudioProbePanel({
    super.key,
    this.probe,
    this.screenAudioProbe,
    this.controller,
    this.backend,
  });

  final ReplayKitAudioProbe? probe;
  final ScreenAudioProbe? screenAudioProbe;
  final EngineController? controller;
  final EngineBackend? backend;

  @override
  State<IosReplayKitAudioProbePanel> createState() =>
      _IosReplayKitAudioProbePanelState();
}

class _IosReplayKitAudioProbePanelState
    extends State<IosReplayKitAudioProbePanel> {
  late final ReplayKitAudioProbe _probe;
  ReplayKitAudioProbeStatus _status = ReplayKitAudioProbeStatus.unavailable;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _probe = widget.probe ?? ReplayKitAudioProbe.create();
    _refresh();
    _poll =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final status = await _probe.getStatus();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _chooseSource() async {
    try {
      await _probe.showBroadcastPicker();
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(error.message ?? 'Could not open Yinwei Music Audio'),
        ));
      }
    }
    await _refresh();
  }

  Future<void> _toggleReturnTone() async {
    if (_status.returnToneActive) {
      await _probe.stopReturnTone();
    } else {
      await _probe.playReturnTone();
    }
    await _refresh();
  }

  void _showAdvancedProbe() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('iOS 27 Screen Audio Test')),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.topCenter,
                child: IosScreenAudioProbePanel(
                  probe: widget.screenAudioProbe,
                  controller: widget.controller,
                  backend: widget.backend,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: YinweiColors.textSecondary,
          height: 1.2,
          fontSize: 11,
        );
    final format = [
      if (_status.sampleRate != null) '${_status.sampleRate} Hz',
      if (_status.channelCount != null) '${_status.channelCount} ch',
    ].join(' / ');
    final rms = _status.lastRmsDb == null
        ? '—'
        : '${_status.lastRmsDb!.toStringAsFixed(1)} dB';

    return Semantics(
      container: true,
      label: 'Music app capture ${_status.phaseLabel}',
      child: Container(
        key: const Key('ios-replaykit-audio-probe'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
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
                    'Music App Audio — Native Test',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontSize: 12),
                  ),
                ),
                Text(
                  _status.phaseLabel,
                  key: const Key('ios-replaykit-audio-probe-phase'),
                  style: labelStyle?.copyWith(color: YinweiColors.textPrimary),
                ),
                SizedBox(
                  width: 20,
                  height: 20,
                  child: PopupMenuButton<_ProbeMenuAction>(
                    key: const Key('ios-screen-audio-probe-open-advanced'),
                    tooltip: 'Capture test options',
                    padding: EdgeInsets.zero,
                    iconSize: 14,
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (action) async {
                      if (action == _ProbeMenuAction.reset) {
                        await _probe.resetStatus();
                        await _refresh();
                      } else if (action == _ProbeMenuAction.liveTransform) {
                        if (!mounted) return;
                        await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => IosRemoteLiveScreen(
                                    controller: widget.controller,
                                    probe: _probe)));
                      } else {
                        _showAdvancedProbe();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: _ProbeMenuAction.reset,
                        child: Text('Reset numeric status'),
                      ),
                      PopupMenuItem(
                        value: _ProbeMenuAction.liveTransform,
                        child: Text('Live Transform on laptop'),
                      ),
                      PopupMenuItem(
                        value: _ProbeMenuAction.screenAudio,
                        child: Text('iOS 27 screen audio test'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                'App audio: ${_status.appAudioBufferCount}',
                if (format.isNotEmpty) format,
                'RMS: $rms',
                'Screen discarded: ${_status.discardedVideoBufferCount}',
                'Mic ignored: ${_status.ignoredMicrophoneBufferCount}',
                if (_status.lastError != null) _status.lastError!,
              ].join('   '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: OutlinedButton(
                      key: const Key('ios-replaykit-audio-probe-open'),
                      onPressed: _status.supported ? _chooseSource : null,
                      style: _buttonStyle(),
                      child: const Text('Choose Music Audio'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 32,
                  child: OutlinedButton(
                    key: const Key('ios-replaykit-return-tone'),
                    onPressed: _status.supported ? _toggleReturnTone : null,
                    style: _buttonStyle(),
                    child: Text(
                      _status.returnToneActive
                          ? 'Stop Tone'
                          : 'Test Return Tone',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              'Broadcast Music; pause it before Test Return Tone. '
              'N0 saves and uploads no media.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ],
        ),
      ),
    );
  }

  ButtonStyle _buttonStyle() => OutlinedButton.styleFrom(
        foregroundColor: YinweiColors.textPrimary,
        visualDensity: VisualDensity.compact,
        side: const BorderSide(color: YinweiColors.hairlineStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );
}
