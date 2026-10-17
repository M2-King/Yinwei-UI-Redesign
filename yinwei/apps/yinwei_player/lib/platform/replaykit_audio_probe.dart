import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Capture-only ReplayKit feasibility probe for audio produced by another app.
///
/// The broadcast extension publishes bounded numeric telemetry through an App
/// Group. It does not persist or transmit audio, microphone, or screen data.
abstract class ReplayKitAudioProbe {
  const ReplayKitAudioProbe();

  static const channelName = 'dev.yinwei/replaykit_audio_probe';

  bool get supported;

  Future<bool> isAvailable();

  Future<void> showBroadcastPicker();

  Future<void> resetStatus();

  Future<void> playReturnTone();

  Future<void> stopReturnTone();

  Future<ReplayKitAudioProbeStatus> getStatus();

  factory ReplayKitAudioProbe.create({
    MethodChannel? channel,
    bool? isIOS,
  }) {
    final ios = isIOS ?? (!kIsWeb && Platform.isIOS);
    if (!ios) return const UnavailableReplayKitAudioProbe();
    return MethodChannelReplayKitAudioProbe(channel: channel);
  }
}

enum ReplayKitAudioProbePhase {
  unavailable,
  ready,
  broadcasting,
  receivingAppAudio,
  silent,
  paused,
  finished,
  error,
}

@immutable
class ReplayKitAudioProbeStatus {
  const ReplayKitAudioProbeStatus({
    required this.supported,
    required this.broadcastActive,
    required this.broadcastPhase,
    required this.appAudioBufferCount,
    required this.ignoredMicrophoneBufferCount,
    required this.discardedVideoBufferCount,
    required this.droppedInspectionBufferCount,
    required this.receivingAppAudio,
    required this.audioSilent,
    required this.returnToneActive,
    this.sampleRate,
    this.channelCount,
    this.lastFrameCount,
    this.lastRmsDb,
    this.lastPeakDb,
    this.lastError,
  });

  static const unavailable = ReplayKitAudioProbeStatus(
    supported: false,
    broadcastActive: false,
    broadcastPhase: 'unavailable',
    appAudioBufferCount: 0,
    ignoredMicrophoneBufferCount: 0,
    discardedVideoBufferCount: 0,
    droppedInspectionBufferCount: 0,
    receivingAppAudio: false,
    audioSilent: false,
    returnToneActive: false,
  );

  final bool supported;
  final bool broadcastActive;
  final String broadcastPhase;
  final int appAudioBufferCount;
  final int ignoredMicrophoneBufferCount;
  final int discardedVideoBufferCount;
  final int droppedInspectionBufferCount;
  final bool receivingAppAudio;
  final bool audioSilent;
  final bool returnToneActive;
  final int? sampleRate;
  final int? channelCount;
  final int? lastFrameCount;
  final double? lastRmsDb;
  final double? lastPeakDb;
  final String? lastError;

  ReplayKitAudioProbePhase get phase {
    if (!supported) return ReplayKitAudioProbePhase.unavailable;
    if (lastError != null && lastError!.isNotEmpty) {
      return ReplayKitAudioProbePhase.error;
    }
    if (receivingAppAudio) return ReplayKitAudioProbePhase.receivingAppAudio;
    if (broadcastActive && audioSilent) return ReplayKitAudioProbePhase.silent;
    if (broadcastPhase == 'paused') return ReplayKitAudioProbePhase.paused;
    if (broadcastActive) return ReplayKitAudioProbePhase.broadcasting;
    if (broadcastPhase == 'finished') return ReplayKitAudioProbePhase.finished;
    return ReplayKitAudioProbePhase.ready;
  }

  String get phaseLabel {
    switch (phase) {
      case ReplayKitAudioProbePhase.unavailable:
        return 'Unavailable';
      case ReplayKitAudioProbePhase.ready:
        return 'Ready';
      case ReplayKitAudioProbePhase.broadcasting:
        return 'Waiting for Music';
      case ReplayKitAudioProbePhase.receivingAppAudio:
        return 'Receiving App Audio';
      case ReplayKitAudioProbePhase.silent:
        return 'Silent';
      case ReplayKitAudioProbePhase.paused:
        return 'Paused';
      case ReplayKitAudioProbePhase.finished:
        return 'Stopped';
      case ReplayKitAudioProbePhase.error:
        return 'Error';
    }
  }

  factory ReplayKitAudioProbeStatus.fromChannel(dynamic raw) {
    final map = raw is Map ? Map<Object?, Object?>.from(raw) : const {};
    final error = map['lastError']?.toString();
    return ReplayKitAudioProbeStatus(
      supported: map['supported'] == true,
      broadcastActive: map['broadcastActive'] == true,
      broadcastPhase: map['broadcastPhase']?.toString() ?? 'idle',
      appAudioBufferCount: _int(map['appAudioBufferCount']),
      ignoredMicrophoneBufferCount: _int(map['ignoredMicrophoneBufferCount']),
      discardedVideoBufferCount: _int(map['discardedVideoBufferCount']),
      droppedInspectionBufferCount: _int(map['droppedInspectionBufferCount']),
      receivingAppAudio: map['receivingAppAudio'] == true,
      audioSilent: map['audioSilent'] == true,
      returnToneActive: map['returnToneActive'] == true,
      sampleRate: _intOrNull(map['sampleRate']),
      channelCount: _intOrNull(map['channelCount']),
      lastFrameCount: _intOrNull(map['lastFrameCount']),
      lastRmsDb: _doubleOrNull(map['lastRmsDb']),
      lastPeakDb: _doubleOrNull(map['lastPeakDb']),
      lastError: (error == null || error.isEmpty) ? null : error,
    );
  }

  static int _int(Object? value) => value is num ? value.toInt() : 0;
  static int? _intOrNull(Object? value) => value is num ? value.toInt() : null;
  static double? _doubleOrNull(Object? value) =>
      value is num ? value.toDouble() : null;
}

class UnavailableReplayKitAudioProbe implements ReplayKitAudioProbe {
  const UnavailableReplayKitAudioProbe();

  @override
  bool get supported => false;

  @override
  Future<ReplayKitAudioProbeStatus> getStatus() async =>
      ReplayKitAudioProbeStatus.unavailable;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<void> resetStatus() async {}

  @override
  Future<void> playReturnTone() async {}

  @override
  Future<void> stopReturnTone() async {}

  @override
  Future<void> showBroadcastPicker() async {}
}

class MethodChannelReplayKitAudioProbe implements ReplayKitAudioProbe {
  MethodChannelReplayKitAudioProbe({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel(ReplayKitAudioProbe.channelName);

  final MethodChannel _channel;

  @override
  bool get supported => true;

  @override
  Future<bool> isAvailable() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('isAvailable');
      return raw is Map ? raw['supported'] == true : raw == true;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> showBroadcastPicker() async {
    // Native startup failures must reach live-session cleanup and the probe UI.
    // Dismissing Apple's picker is a successful presentation, not an exception.
    await _channel.invokeMethod<dynamic>('showBroadcastPicker');
  }

  @override
  Future<void> resetStatus() async {
    try {
      await _channel.invokeMethod<dynamic>('resetStatus');
    } on PlatformException {
      // Reset is best-effort and contains no media state.
    }
  }

  @override
  Future<void> playReturnTone() async {
    try {
      await _channel.invokeMethod<dynamic>('playReturnTone');
    } on PlatformException {
      // getStatus reports any native audio-session failure.
    }
  }

  @override
  Future<void> stopReturnTone() async {
    try {
      await _channel.invokeMethod<dynamic>('stopReturnTone');
    } on PlatformException {
      // Stop is best-effort and must never strand capture state.
    }
  }

  @override
  Future<ReplayKitAudioProbeStatus> getStatus() async {
    try {
      return ReplayKitAudioProbeStatus.fromChannel(
        await _channel.invokeMethod<dynamic>('getStatus'),
      );
    } on PlatformException catch (error) {
      return ReplayKitAudioProbeStatus(
        supported: true,
        broadcastActive: false,
        broadcastPhase: 'error',
        appAudioBufferCount: 0,
        ignoredMicrophoneBufferCount: 0,
        discardedVideoBufferCount: 0,
        droppedInspectionBufferCount: 0,
        receivingAppAudio: false,
        audioSilent: false,
        returnToneActive: false,
        lastError: error.message ?? error.code,
      );
    }
  }
}
