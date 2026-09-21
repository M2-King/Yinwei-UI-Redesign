import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/platform/android_playback_capture_metrics.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

export 'package:yinwei_player/platform/android_playback_capture_metrics.dart'
    show PlaybackCaptureDataState, PlaybackCaptureMetrics;

/// Isolated Android 10+ AudioPlaybackCapture probe.
///
/// Capture-only. Not WASAPI, not spatial_core, and not wet output.
abstract class AndroidPlaybackCapture {
  const AndroidPlaybackCapture();

  static const channelName = 'dev.yinwei/android_playback_capture';
  static const minSdk = 29;

  bool get supported;

  Future<bool> isAvailable();

  Future<void> requestAndStartCapture();

  Future<void> stopCapture();

  Future<AndroidPlaybackCaptureStatus> getStatus();

  static bool isSupportedSdk(int sdkInt) => sdkInt >= minSdk;

  factory AndroidPlaybackCapture.create({
    PlatformCapabilities? capabilities,
    MethodChannel? channel,
    bool? isAndroid,
  }) {
    final android = isAndroid ?? (!kIsWeb && Platform.isAndroid);
    if (!android) {
      return const UnavailableAndroidPlaybackCapture();
    }
    return MethodChannelAndroidPlaybackCapture(channel: channel);
  }
}

enum AndroidPlaybackCapturePhase {
  unavailable,
  ready,
  waitingForPermission,
  capturing,
  receivingPlaybackAudio,
  silent,
  blockedBySourceApp,
  error,
}

@immutable
class AndroidPlaybackCaptureStatus {
  const AndroidPlaybackCaptureStatus({
    required this.supported,
    required this.androidSdk,
    required this.projectionGranted,
    required this.captureActive,
    required this.foregroundServiceRunning,
    required this.audioRecordState,
    required this.readCount,
    required this.capturedFrames,
    required this.silent,
    required this.receivingPlaybackAudio,
    this.sampleRate,
    this.channelCount,
    this.encoding,
    this.rmsDb,
    this.peakDb,
    this.lastError,
    this.permissionPending = false,
    this.permissionDenied = false,
    this.permissionCancelled = false,
    this.projectionRevoked = false,
    this.sourceCaptureRestricted = false,
    this.audioRecordSource = 'PLAYBACK_CAPTURE',
    this.capturedSamples = 0,
    this.lastReadFrames = 0,
    this.playbackCaptureConfigured = false,
    this.audioUsages = const ['USAGE_MEDIA', 'USAGE_GAME', 'USAGE_UNKNOWN'],
    this.captureHint,
    this.dspState = 'Disconnected',
    this.dspLibraryLoaded = false,
    this.nativeInputFrames = 0,
    this.nativeConsumedFrames = 0,
    this.nativeDspChunks = 0,
    this.nativeWetFrames = 0,
    this.nativeDroppedFrames = 0,
    this.nativeOverruns = 0,
    this.nativeQueueDepthFrames = 0,
    this.nativeQueueHighWaterFrames = 0,
    this.nativeLastError,
    this.nativeWetRmsDb,
    this.nativeWetPeakDb,
    this.nativeEffectiveAzimuthDeg,
    this.nativeEffectiveElevationDeg,
  });

  final bool supported;
  final int androidSdk;
  final bool projectionGranted;
  final bool captureActive;
  final bool foregroundServiceRunning;
  final String audioRecordState;
  final int readCount;
  final int capturedFrames;
  final int capturedSamples;
  final int lastReadFrames;
  final int? sampleRate;
  final int? channelCount;
  final String? encoding;
  final double? rmsDb;
  final double? peakDb;
  final bool silent;
  final bool receivingPlaybackAudio;
  final String? lastError;
  final bool permissionPending;
  final bool permissionDenied;
  final bool permissionCancelled;
  final bool projectionRevoked;
  final bool sourceCaptureRestricted;
  final String audioRecordSource;
  final bool playbackCaptureConfigured;
  final List<String> audioUsages;
  final String? captureHint;
  final String dspState;
  final bool dspLibraryLoaded;
  final int nativeInputFrames;
  final int nativeConsumedFrames;
  final int nativeDspChunks;
  final int nativeWetFrames;
  final int nativeDroppedFrames;
  final int nativeOverruns;
  final int nativeQueueDepthFrames;
  final int nativeQueueHighWaterFrames;
  final String? nativeLastError;
  final double? nativeWetRmsDb;
  final double? nativeWetPeakDb;
  final double? nativeEffectiveAzimuthDeg;
  final double? nativeEffectiveElevationDeg;

  static const unavailable = AndroidPlaybackCaptureStatus(
    supported: false,
    androidSdk: 0,
    projectionGranted: false,
    captureActive: false,
    foregroundServiceRunning: false,
    audioRecordState: 'UNINITIALIZED',
    readCount: 0,
    capturedFrames: 0,
    silent: false,
    receivingPlaybackAudio: false,
  );

  bool get usesMicrophoneSource =>
      audioRecordSource.toUpperCase().contains('MIC');

  PlaybackCaptureDataState get dataState => PlaybackCaptureMetrics.dataState(
        readCount: readCount,
        silent: silent,
      );

  AndroidPlaybackCapturePhase get phase {
    if (!supported) return AndroidPlaybackCapturePhase.unavailable;
    if (lastError != null && lastError!.isNotEmpty) {
      return AndroidPlaybackCapturePhase.error;
    }
    if (permissionDenied) return AndroidPlaybackCapturePhase.error;
    if (projectionRevoked) return AndroidPlaybackCapturePhase.error;
    if (permissionPending) {
      return AndroidPlaybackCapturePhase.waitingForPermission;
    }
    if (receivingPlaybackAudio) {
      return AndroidPlaybackCapturePhase.receivingPlaybackAudio;
    }
    if (captureActive && sourceCaptureRestricted) {
      return AndroidPlaybackCapturePhase.blockedBySourceApp;
    }
    if (captureActive && silent && readCount > 0) {
      return AndroidPlaybackCapturePhase.silent;
    }
    if (captureActive) return AndroidPlaybackCapturePhase.capturing;
    return AndroidPlaybackCapturePhase.ready;
  }

  String get phaseLabel {
    switch (phase) {
      case AndroidPlaybackCapturePhase.unavailable:
        return 'Unavailable';
      case AndroidPlaybackCapturePhase.ready:
        return 'Ready';
      case AndroidPlaybackCapturePhase.waitingForPermission:
        return 'Waiting for Android permission';
      case AndroidPlaybackCapturePhase.capturing:
        return 'Capturing';
      case AndroidPlaybackCapturePhase.receivingPlaybackAudio:
        return 'Receiving Playback Audio';
      case AndroidPlaybackCapturePhase.silent:
        return 'Silent';
      case AndroidPlaybackCapturePhase.blockedBySourceApp:
        return 'Blocked by Source App';
      case AndroidPlaybackCapturePhase.error:
        return 'Error';
    }
  }

  String get dspBridgeLabel {
    if (nativeLastError != null && nativeLastError!.isNotEmpty) {
      return 'Error';
    }
    switch (dspState) {
      case 'Starting':
        return 'Starting';
      case 'Processing':
        return 'Processing';
      case 'Error':
        return 'Error';
      default:
        if (dspLibraryLoaded && nativeDspChunks > 0) return 'Processing';
        if (dspLibraryLoaded && captureActive) return 'Starting';
        return 'Disconnected';
    }
  }

  factory AndroidPlaybackCaptureStatus.fromChannel(dynamic raw) {
    final map = raw is Map ? Map<Object?, Object?>.from(raw) : const {};
    final error = map['lastError']?.toString();
    final hint = map['captureHint']?.toString();
    final usages = map['audioUsages'];
    return AndroidPlaybackCaptureStatus(
      supported: map['supported'] == true,
      androidSdk: _int(map['androidSdk']),
      projectionGranted: map['projectionGranted'] == true,
      captureActive: map['captureActive'] == true,
      foregroundServiceRunning: map['foregroundServiceRunning'] == true,
      audioRecordState: map['audioRecordState']?.toString() ?? 'UNINITIALIZED',
      readCount: _int(map['readCount']),
      capturedFrames: _int(map['capturedFrames']),
      capturedSamples: _int(map['capturedSamples']),
      lastReadFrames: _int(map['lastReadFrames']),
      sampleRate: _intOrNull(map['sampleRate']),
      channelCount: _intOrNull(map['channelCount']),
      encoding: map['encoding']?.toString(),
      rmsDb: _doubleOrNull(map['rmsDb']),
      peakDb: _doubleOrNull(map['peakDb']),
      silent: map['silent'] == true,
      receivingPlaybackAudio: map['receivingPlaybackAudio'] == true,
      lastError: (error == null || error.isEmpty) ? null : error,
      permissionPending: map['permissionPending'] == true,
      permissionDenied: map['permissionDenied'] == true,
      permissionCancelled: map['permissionCancelled'] == true,
      projectionRevoked: map['projectionRevoked'] == true,
      sourceCaptureRestricted: map['sourceCaptureRestricted'] == true,
      audioRecordSource:
          map['audioRecordSource']?.toString() ?? 'PLAYBACK_CAPTURE',
      playbackCaptureConfigured: map['playbackCaptureConfigured'] == true,
      audioUsages: usages is List
          ? usages.map((item) => item.toString()).toList()
          : const ['USAGE_MEDIA', 'USAGE_GAME', 'USAGE_UNKNOWN'],
      captureHint: (hint == null || hint.isEmpty) ? null : hint,
      dspState: map['dspState']?.toString() ?? 'Disconnected',
      dspLibraryLoaded: map['dspLibraryLoaded'] == true,
      nativeInputFrames: _int(map['nativeInputFrames']),
      nativeConsumedFrames: _int(map['nativeConsumedFrames']),
      nativeDspChunks: _int(map['nativeDspChunks']),
      nativeWetFrames: _int(map['nativeWetFrames']),
      nativeDroppedFrames: _int(map['nativeDroppedFrames']),
      nativeOverruns: _int(map['nativeOverruns']),
      nativeQueueDepthFrames: _int(map['nativeQueueDepthFrames']),
      nativeQueueHighWaterFrames: _int(map['nativeQueueHighWaterFrames']),
      nativeLastError: () {
        final value = map['nativeLastError']?.toString();
        if (value == null || value.isEmpty) return null;
        return value;
      }(),
      nativeWetRmsDb: _doubleOrNull(map['nativeWetRmsDb']),
      nativeWetPeakDb: _doubleOrNull(map['nativeWetPeakDb']),
      nativeEffectiveAzimuthDeg:
          _doubleOrNull(map['nativeEffectiveAzimuthDeg']),
      nativeEffectiveElevationDeg:
          _doubleOrNull(map['nativeEffectiveElevationDeg']),
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

class UnavailableAndroidPlaybackCapture implements AndroidPlaybackCapture {
  const UnavailableAndroidPlaybackCapture();

  @override
  bool get supported => false;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<void> requestAndStartCapture() async {}

  @override
  Future<void> stopCapture() async {}

  @override
  Future<AndroidPlaybackCaptureStatus> getStatus() async {
    return AndroidPlaybackCaptureStatus.unavailable;
  }
}

class MethodChannelAndroidPlaybackCapture implements AndroidPlaybackCapture {
  MethodChannelAndroidPlaybackCapture({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel(AndroidPlaybackCapture.channelName);

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
  Future<void> requestAndStartCapture() async {
    try {
      await _channel.invokeMethod<dynamic>('requestAndStartCapture');
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
  Future<AndroidPlaybackCaptureStatus> getStatus() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('getStatus');
      return AndroidPlaybackCaptureStatus.fromChannel(raw);
    } on PlatformException catch (e) {
      return AndroidPlaybackCaptureStatus(
        supported: true,
        androidSdk: 0,
        projectionGranted: false,
        captureActive: false,
        foregroundServiceRunning: false,
        audioRecordState: 'ERROR',
        readCount: 0,
        capturedFrames: 0,
        silent: false,
        receivingPlaybackAudio: false,
        lastError: e.message ?? e.code,
      );
    }
  }
}
