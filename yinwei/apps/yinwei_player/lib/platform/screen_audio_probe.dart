import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

/// Isolated iOS 27 ScreenCaptureKit capture-only probe.
///
/// Not WASAPI, not spatial_core, and not wet output. The native side inspects
/// SCStreamOutputType.audio buffers and discards them.
abstract class ScreenAudioProbe {
  const ScreenAudioProbe();

  static const channelName = 'dev.yinwei/screen_audio_probe';

  bool get supported;

  Future<bool> isAvailable();

  Future<void> startCapture();

  Future<void> stopCapture();

  Future<ScreenAudioProbeStatus> getStatus();

  factory ScreenAudioProbe.create({
    PlatformCapabilities? capabilities,
    MethodChannel? channel,
    bool? isIOS,
  }) {
    final ios = isIOS ?? (!kIsWeb && Platform.isIOS);
    // Windows liveTransfer is a different product path and does not enable this
    // iOS ScreenCaptureKit probe.
    if (!ios) {
      return const UnavailableScreenAudioProbe();
    }
    return MethodChannelScreenAudioProbe(channel: channel);
  }
}

enum ScreenAudioProbePhase {
  unavailable,
  ready,
  waitingForPicker,
  capturing,
  receivingSystemAudio,
  silent,
  error,
}

@immutable
class ScreenAudioProbeStatus {
  const ScreenAudioProbeStatus({
    required this.supported,
    required this.captureActive,
    required this.pickerActive,
    required this.audioBufferCount,
    required this.microphoneBufferCount,
    required this.screenBufferCount,
    required this.receivingSystemAudio,
    required this.receivingMicrophone,
    required this.audioSilent,
    required this.pickerCancelled,
    required this.excludesCurrentProcessAudioSupported,
    required this.excludesCurrentProcessAudio,
    this.sampleRate,
    this.channelCount,
    this.lastRmsDb,
    this.lastPeakDb,
    this.lastError,
    this.pickerState = 'idle',
    this.selectedCaptureMode = 'full-display',
    this.lastCallbackOutputType,
    this.capturesAudio = false,
    this.lastFrameCount,
    this.interleaved,
    this.formatDescription,
    this.osVersion,
  });

  final bool supported;
  final bool captureActive;
  final bool pickerActive;
  final int audioBufferCount;
  final int microphoneBufferCount;
  final int screenBufferCount;
  final int? sampleRate;
  final int? channelCount;
  final double? lastRmsDb;
  final double? lastPeakDb;
  final bool receivingSystemAudio;
  final bool receivingMicrophone;
  final bool audioSilent;
  final bool pickerCancelled;
  final bool excludesCurrentProcessAudioSupported;
  final bool excludesCurrentProcessAudio;
  final String? lastError;
  final String pickerState;
  final String? selectedCaptureMode;
  final String? lastCallbackOutputType;
  final bool capturesAudio;
  final int? lastFrameCount;
  final bool? interleaved;
  final String? formatDescription;
  final String? osVersion;

  static const unavailable = ScreenAudioProbeStatus(
    supported: false,
    captureActive: false,
    pickerActive: false,
    audioBufferCount: 0,
    microphoneBufferCount: 0,
    screenBufferCount: 0,
    receivingSystemAudio: false,
    receivingMicrophone: false,
    audioSilent: false,
    pickerCancelled: false,
    excludesCurrentProcessAudioSupported: false,
    excludesCurrentProcessAudio: false,
  );

  bool get hasAudioBuffers => audioBufferCount > 0;

  ScreenAudioProbePhase get phase {
    if (!supported) return ScreenAudioProbePhase.unavailable;
    if (lastError != null && lastError!.isNotEmpty) {
      return ScreenAudioProbePhase.error;
    }
    if (pickerActive) return ScreenAudioProbePhase.waitingForPicker;
    if (receivingSystemAudio) {
      return ScreenAudioProbePhase.receivingSystemAudio;
    }
    if (captureActive && audioSilent) return ScreenAudioProbePhase.silent;
    if (captureActive) return ScreenAudioProbePhase.capturing;
    return ScreenAudioProbePhase.ready;
  }

  String get phaseLabel {
    switch (phase) {
      case ScreenAudioProbePhase.unavailable:
        return 'Unavailable';
      case ScreenAudioProbePhase.ready:
        return 'Ready';
      case ScreenAudioProbePhase.waitingForPicker:
        return 'Waiting for Apple Picker';
      case ScreenAudioProbePhase.capturing:
        return 'Capturing';
      case ScreenAudioProbePhase.receivingSystemAudio:
        return 'Receiving System Audio';
      case ScreenAudioProbePhase.silent:
        return 'Silent';
      case ScreenAudioProbePhase.error:
        return 'Error';
    }
  }

  factory ScreenAudioProbeStatus.fromChannel(dynamic raw) {
    final map = raw is Map ? Map<Object?, Object?>.from(raw) : const {};
    final error = map['lastError']?.toString();
    return ScreenAudioProbeStatus(
      supported: map['supported'] == true,
      captureActive: map['captureActive'] == true,
      pickerActive: map['pickerActive'] == true,
      audioBufferCount: _int(map['audioBufferCount']),
      microphoneBufferCount: _int(map['microphoneBufferCount']),
      screenBufferCount: _int(map['screenBufferCount']),
      sampleRate: _intOrNull(map['sampleRate']),
      channelCount: _intOrNull(map['channelCount']),
      lastRmsDb: _doubleOrNull(map['lastRmsDb']),
      lastPeakDb: _doubleOrNull(map['lastPeakDb']),
      receivingSystemAudio: map['receivingSystemAudio'] == true,
      receivingMicrophone: map['receivingMicrophone'] == true,
      audioSilent: map['audioSilent'] == true,
      pickerCancelled: map['pickerCancelled'] == true,
      excludesCurrentProcessAudioSupported:
          map['excludesCurrentProcessAudioSupported'] == true,
      excludesCurrentProcessAudio: map['excludesCurrentProcessAudio'] == true,
      lastError: (error == null || error.isEmpty) ? null : error,
      pickerState: map['pickerState']?.toString() ??
          (map['pickerActive'] == true
              ? 'presenting'
              : (map['captureActive'] == true ? 'capturing' : 'idle')),
      selectedCaptureMode: map['selectedCaptureMode']?.toString() ??
          'full-display',
      lastCallbackOutputType: map['lastCallbackOutputType']?.toString(),
      capturesAudio: map['capturesAudio'] == true,
      lastFrameCount: _intOrNull(map['lastFrameCount']),
      interleaved: map['interleaved'] is bool ? map['interleaved'] as bool : null,
      formatDescription: map['formatDescription']?.toString(),
      osVersion: map['osVersion']?.toString(),
    );
  }

  static int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  static int? _intOrNull(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  static double? _doubleOrNull(Object? value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return null;
  }
}

class UnavailableScreenAudioProbe implements ScreenAudioProbe {
  const UnavailableScreenAudioProbe();

  @override
  bool get supported => false;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<void> startCapture() async {}

  @override
  Future<void> stopCapture() async {}

  @override
  Future<ScreenAudioProbeStatus> getStatus() async {
    return ScreenAudioProbeStatus.unavailable;
  }
}

class MethodChannelScreenAudioProbe implements ScreenAudioProbe {
  MethodChannelScreenAudioProbe({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(ScreenAudioProbe.channelName);

  final MethodChannel _channel;

  @override
  bool get supported => true;

  @override
  Future<bool> isAvailable() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('isAvailable');
      if (raw is bool) return raw;
      if (raw is Map) return raw['supported'] == true;
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> startCapture() async {
    try {
      await _channel.invokeMethod<dynamic>('startCapture');
    } on PlatformException {
      // lastError is carried by getStatus. Cancellation is not an error.
    }
  }

  @override
  Future<void> stopCapture() async {
    try {
      await _channel.invokeMethod<dynamic>('stopCapture');
    } on PlatformException {
      // Stopping is best-effort.
    }
  }

  @override
  Future<ScreenAudioProbeStatus> getStatus() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('getStatus');
      return ScreenAudioProbeStatus.fromChannel(raw);
    } on PlatformException catch (e) {
      return ScreenAudioProbeStatus(
        supported: true,
        captureActive: false,
        pickerActive: false,
        audioBufferCount: 0,
        microphoneBufferCount: 0,
        screenBufferCount: 0,
        receivingSystemAudio: false,
        receivingMicrophone: false,
        audioSilent: false,
        pickerCancelled: false,
        excludesCurrentProcessAudioSupported: false,
        excludesCurrentProcessAudio: false,
        lastError: e.message ?? e.code,
      );
    }
  }
}
