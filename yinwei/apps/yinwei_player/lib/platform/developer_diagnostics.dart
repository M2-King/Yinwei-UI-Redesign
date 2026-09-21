import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/platform/android_playback_capture.dart';
import 'package:yinwei_player/platform/build_stamp.dart';
import 'package:yinwei_player/platform/screen_audio_probe.dart';
import 'package:yinwei_player/state/engine_controller.dart';

/// On-device diagnostics for iPhone testing without an Xcode console.
/// Never includes captured PCM samples.
class DeveloperDiagnostics {
  DeveloperDiagnostics({
    MethodChannel? channel,
    this.clipboard = const ClipboardTransporter(),
  }) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'dev.yinwei/developer_diagnostics';

  final MethodChannel _channel;
  final ClipboardTransporter clipboard;

  Future<DeveloperDiagnosticsReport> collect({
    EngineController? controller,
    EngineBackend? backend,
    ScreenAudioProbeStatus? capture,
    AndroidPlaybackCaptureStatus? androidCapture,
    DateTime? now,
  }) async {
    Map<String, dynamic> native = const {};
    try {
      final raw = await _channel.invokeMethod<dynamic>('getSnapshot');
      if (raw is Map) {
        native = Map<String, dynamic>.from(
          raw.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
    } on PlatformException {
      native = const {};
    } on MissingPluginException {
      native = const {};
    }

    return DeveloperDiagnosticsReport.fromParts(
      native: native,
      capture: capture ?? ScreenAudioProbeStatus.unavailable,
      androidCapture: androidCapture,
      controller: controller,
      backend: backend,
      generatedAt: now ?? DateTime.now().toUtc(),
    );
  }

  Future<void> copy(DeveloperDiagnosticsReport report) {
    return clipboard.write(report.asText());
  }

  Future<DeveloperDiagnosticsExport> export(
    DeveloperDiagnosticsReport report, {
    String? filename,
  }) async {
    final name = filename ??
        'yinwei-7d1-diagnostics-${report.generatedAt.toIso8601String().replaceAll(':', '')}.json';
    final text = report.asJson();
    try {
      final raw = await _channel.invokeMethod<dynamic>('exportReport', {
        'text': text,
        'filename': name,
      });
      final map = raw is Map ? Map<Object?, Object?>.from(raw) : const {};
      return DeveloperDiagnosticsExport(
        ok: map['ok'] == true,
        path: map['path']?.toString(),
        shared: map['shared'] == true,
        json: text,
      );
    } on PlatformException catch (e) {
      return DeveloperDiagnosticsExport(
        ok: false,
        error: e.message ?? e.code,
        json: text,
      );
    } on MissingPluginException {
      return DeveloperDiagnosticsExport(
        ok: true,
        shared: false,
        json: text,
      );
    }
  }
}

@immutable
class DeveloperDiagnosticsExport {
  const DeveloperDiagnosticsExport({
    required this.ok,
    required this.json,
    this.path,
    this.shared = false,
    this.error,
  });

  final bool ok;
  final String json;
  final String? path;
  final bool shared;
  final String? error;
}

class ClipboardTransporter {
  const ClipboardTransporter();

  Future<void> write(String text) {
    return Clipboard.setData(ClipboardData(text: text));
  }
}

@immutable
class DeveloperDiagnosticsReport {
  const DeveloperDiagnosticsReport({
    required this.generatedAt,
    required this.build,
    required this.capture,
    required this.audioInput,
    required this.rust,
    required this.output,
    required this.lifecycle,
    required this.log,
    this.projection = const {},
    this.title = 'YINWEI iOS DIAGNOSTICS',
    this.phaseName = '7D1',
  });

  final DateTime generatedAt;
  final Map<String, String> build;
  final Map<String, String> projection;
  final Map<String, String> capture;
  final Map<String, String> audioInput;
  final Map<String, String> rust;
  final Map<String, String> output;
  final Map<String, String> lifecycle;
  final List<String> log;
  final String title;
  final String phaseName;

  factory DeveloperDiagnosticsReport.fromParts({
    required Map<String, dynamic> native,
    required ScreenAudioProbeStatus capture,
    AndroidPlaybackCaptureStatus? androidCapture,
    EngineController? controller,
    EngineBackend? backend,
    required DateTime generatedAt,
  }) {
    if (androidCapture != null) {
      return _android(
        native: native,
        capture: androidCapture,
        controller: controller,
        backend: backend,
        generatedAt: generatedAt,
      );
    }
    final nativeOutput = _asMap(native['output']);
    final nativeLifecycle = _asMap(native['lifecycle']);
    final runningIos = native['runningIosVersion']?.toString() ??
        (!kIsWeb && Platform.isIOS ? Platform.operatingSystemVersion : 'n/a');
    final connected = backend == EngineBackend.native;
    return DeveloperDiagnosticsReport(
      generatedAt: generatedAt,
      build: {
        'git commit SHA': YinweiBuildStamp.gitSha,
        'build number': YinweiBuildStamp.buildNumber,
        'build timestamp': YinweiBuildStamp.buildTimestamp,
        'Flutter version': YinweiBuildStamp.flutterVersion,
        'Xcode version': YinweiBuildStamp.xcodeVersion,
        'iOS SDK version': YinweiBuildStamp.iosSdkVersion,
        'workflow': YinweiBuildStamp.workflow,
        'phase': YinweiBuildStamp.phase,
        'running iOS version': runningIos,
        'bundle version': native['bundleVersion']?.toString() ?? '',
        'bundle short version': native['bundleShortVersion']?.toString() ?? '',
      },
      capture: {
        'ScreenCaptureKit supported': _yesNo(capture.supported),
        'picker state': capture.pickerState,
        'capture state': capture.phaseLabel,
        'selected capture mode': capture.selectedCaptureMode ?? 'full-display',
        'screen buffer count': '${capture.screenBufferCount}',
        'system audio buffer count': '${capture.audioBufferCount}',
        'microphone buffer count': '${capture.microphoneBufferCount}',
        'last callback output type': capture.lastCallbackOutputType ?? 'none',
        'capturesAudio': _yesNo(capture.capturesAudio),
        'excludesCurrentProcessAudio':
            '${capture.excludesCurrentProcessAudio} (supported=${capture.excludesCurrentProcessAudioSupported})',
        'picker cancelled': _yesNo(capture.pickerCancelled),
        'last capture error': capture.lastError ?? 'none',
      },
      audioInput: {
        'CMSampleBuffer format': capture.formatDescription ?? 'none',
        'sample rate': capture.sampleRate?.toString() ?? 'none',
        'channel count': capture.channelCount?.toString() ?? 'none',
        'frame count': capture.lastFrameCount?.toString() ?? 'none',
        'interleaved': capture.interleaved == null
            ? 'unknown'
            : _yesNo(capture.interleaved!),
        'RMS dBFS': capture.audioSilent && capture.lastRmsDb == null
            ? '-inf/silent'
            : (capture.lastRmsDb?.toStringAsFixed(1) ?? 'none'),
        'peak dBFS': capture.lastPeakDb?.toStringAsFixed(1) ??
            (capture.audioSilent ? '-inf/silent' : 'none'),
        'silence/non-silence': capture.audioBufferCount == 0
            ? 'no-buffers'
            : (capture.audioSilent ? 'silence' : 'non-silence'),
      },
      rust: {
        'spatial_core connected': _yesNo(connected),
        'stream input initialized': 'no (7D1 capture-only)',
        'PCM frames pushed': '0',
        'PCM frames consumed': '0',
        'underrun count': '0',
        'overrun count': '0',
        'DSP state': connected
            ? (controller?.playing == true
                ? 'file-mode playing'
                : 'file-mode idle')
            : 'not connected',
        'current spatial parameters': controller == null
            ? 'n/a'
            : 'mode=${controller.mode.name} motion=${controller.params.motion.name} az=${controller.params.azimuthDeg.toStringAsFixed(1)} el=${controller.params.elevationDeg.toStringAsFixed(1)} dist=${controller.params.distanceM.toStringAsFixed(2)}',
        'last Rust error': controller?.lastError ?? 'none',
      },
      output: {
        'AVAudioSession category':
            nativeOutput['category']?.toString() ?? 'unknown',
        'active state': nativeOutput['active']?.toString() ?? 'unknown',
        'current output route':
            nativeOutput['currentOutputRoute']?.toString() ?? 'unknown',
        'headphones / speaker / Bluetooth':
            'headphones=${nativeOutput['headphones'] == true} speaker=${nativeOutput['speaker'] == true} bluetooth=${nativeOutput['bluetooth'] == true}',
        'output sample rate':
            nativeOutput['sampleRate']?.toString() ?? 'unknown',
        'playing state': controller == null
            ? 'unknown'
            : (controller.playing ? 'playing' : 'not-playing'),
        'other audio playing':
            nativeOutput['otherAudioPlaying']?.toString() ?? 'unknown',
      },
      lifecycle: {
        'app foreground/background':
            nativeLifecycle['appState']?.toString() ?? 'unknown',
        'ScreenCaptureKit stream started/stopped':
            nativeLifecycle['captureStreamStarted'] == true
                ? 'started'
                : 'stopped',
        'interruption':
            nativeLifecycle['lastInterruption']?.toString() ?? 'none',
        'route change':
            nativeLifecycle['lastRouteChange']?.toString() ?? 'none',
        'capture error': nativeLifecycle['lastCaptureError']?.toString() ??
            capture.lastError ??
            'none',
      },
      log: _logLines(native['log']),
    );
  }

  static DeveloperDiagnosticsReport _android({
    required Map<String, dynamic> native,
    required AndroidPlaybackCaptureStatus capture,
    EngineController? controller,
    EngineBackend? backend,
    required DateTime generatedAt,
  }) {
    final nativeLifecycle = _asMap(native['lifecycle']);
    final nativeBuild = _asMap(native['build']);
    final connected = backend == EngineBackend.native;
    return DeveloperDiagnosticsReport(
      generatedAt: generatedAt,
      title: 'YINWEI ANDROID DIAGNOSTICS',
      phaseName: 'A2',
      build: {
        'git commit SHA': YinweiBuildStamp.gitSha,
        'build number': YinweiBuildStamp.buildNumber,
        'build timestamp': YinweiBuildStamp.buildTimestamp,
        'Flutter version': YinweiBuildStamp.flutterVersion,
        'Android SDK version':
            nativeBuild['androidSdk']?.toString() ?? '${capture.androidSdk}',
        'manufacturer': nativeBuild['manufacturer']?.toString() ?? 'unknown',
        'model': nativeBuild['model']?.toString() ?? 'unknown',
        'Android version': nativeBuild['androidVersion']?.toString() ??
            (!kIsWeb && Platform.isAndroid
                ? Platform.operatingSystemVersion
                : 'n/a'),
        'app version': nativeBuild['appVersion']?.toString() ??
            native['bundleShortVersion']?.toString() ??
            '',
        'workflow': YinweiBuildStamp.workflow,
        'phase': 'A2',
      },
      projection: {
        'permission granted': _yesNo(capture.projectionGranted),
        'projection active': _yesNo(
          capture.projectionGranted && !capture.projectionRevoked,
        ),
        'foreground service active': _yesNo(capture.foregroundServiceRunning),
        'permission pending': _yesNo(capture.permissionPending),
        'permission denied': _yesNo(capture.permissionDenied),
        'permission cancelled': _yesNo(capture.permissionCancelled),
        'projection revoked': _yesNo(capture.projectionRevoked),
        'capture hint': capture.captureHint ?? '',
      },
      capture: {
        'AudioPlaybackCapture supported': _yesNo(capture.supported),
        'capture state': capture.phaseLabel,
        'AudioRecord state': capture.audioRecordState,
        'playback capture configured':
            _yesNo(capture.playbackCaptureConfigured),
        'audio usage filters': capture.audioUsages.join(','),
        'audio record source': capture.audioRecordSource,
        'reads': '${capture.readCount}',
        'frames': '${capture.capturedFrames}',
        'sample rate': capture.sampleRate?.toString() ?? 'none',
        'channels': capture.channelCount?.toString() ?? 'none',
        'encoding': capture.encoding ?? 'none',
        'RMS dBFS': capture.silent && capture.rmsDb == null
            ? '-inf/silent'
            : (capture.rmsDb?.toStringAsFixed(1) ?? 'none'),
        'peak dBFS': capture.peakDb?.toStringAsFixed(1) ??
            (capture.silent ? '-inf/silent' : 'none'),
        'silent': _yesNo(capture.silent),
        'data state': capture.dataState.name,
        'source capture restricted': _yesNo(capture.sourceCaptureRestricted),
        'last error': capture.lastError ?? 'none',
      },
      audioInput: {
        'source': 'AudioPlaybackCaptureConfiguration + AudioRecord',
        'microphone used as source': _yesNo(capture.usesMicrophoneSource),
        'sample rate': capture.sampleRate?.toString() ?? 'none',
        'channel count': capture.channelCount?.toString() ?? 'none',
        'encoding': capture.encoding ?? 'none',
        'last read frames': '${capture.lastReadFrames}',
        'captured samples': '${capture.capturedSamples}',
      },
      rust: {
        'spatial_core file engine': _yesNo(connected),
        'JNI live ingress loaded': _yesNo(capture.dspLibraryLoaded),
        'DSP bridge': capture.dspBridgeLabel,
        'stream input initialized': capture.dspLibraryLoaded &&
                (capture.captureActive || capture.nativeInputFrames > 0)
            ? 'yes'
            : 'no',
        'PCM frames pushed': '${capture.nativeInputFrames}',
        'PCM frames consumed': '${capture.nativeConsumedFrames}',
        'DSP chunks': '${capture.nativeDspChunks}',
        'wet frames': '${capture.nativeWetFrames}',
        'queue depth frames': '${capture.nativeQueueDepthFrames}',
        'queue high water frames': '${capture.nativeQueueHighWaterFrames}',
        'dropped frames': '${capture.nativeDroppedFrames}',
        'overrun count': '${capture.nativeOverruns}',
        'wet RMS dBFS': capture.nativeWetRmsDb?.toStringAsFixed(1) ?? 'none',
        'wet peak dBFS': capture.nativeWetPeakDb?.toStringAsFixed(1) ?? 'none',
        'effective azimuth deg':
            capture.nativeEffectiveAzimuthDeg?.toStringAsFixed(1) ?? 'none',
        'effective elevation deg':
            capture.nativeEffectiveElevationDeg?.toStringAsFixed(1) ?? 'none',
        'current spatial parameters': controller == null
            ? 'n/a'
            : 'mode=${controller.mode.name} motion=${controller.params.motion.name} az=${controller.params.azimuthDeg.toStringAsFixed(1)} el=${controller.params.elevationDeg.toStringAsFixed(1)} dist=${controller.params.distanceM.toStringAsFixed(2)}',
        'last Rust error':
            capture.nativeLastError ?? controller?.lastError ?? 'none',
      },
      output: {
        'playing captured audio': 'no (A2 no wet output yet)',
        'saving captured PCM': 'no',
      },
      lifecycle: {
        'app foreground/background':
            nativeLifecycle['appState']?.toString() ?? 'unknown',
        'projection revoked': _yesNo(
          capture.projectionRevoked ||
              nativeLifecycle['projectionRevoked'] == true,
        ),
        'service started/stopped':
            capture.foregroundServiceRunning ? 'started' : 'stopped',
        'capture error': nativeLifecycle['lastCaptureError']?.toString() ??
            capture.lastError ??
            'none',
      },
      log: _logLines(native['log']),
    );
  }

  Map<String, dynamic> asMap() => {
        'generatedAt': generatedAt.toIso8601String(),
        'pcmSamplesIncluded': false,
        'phase': phaseName,
        'title': title,
        'build': build,
        if (projection.isNotEmpty) 'projection': projection,
        'capture': capture,
        'audioInput': audioInput,
        'rust': rust,
        'output': output,
        'lifecycle': lifecycle,
        'log': log,
      };

  String asJson() => const JsonEncoder.withIndent('  ').convert(asMap());

  String asText() {
    final buffer = StringBuffer()
      ..writeln(title)
      ..writeln('phase: $phaseName capture-only')
      ..writeln('generated: ${generatedAt.toIso8601String()}')
      ..writeln('This report does not contain captured PCM samples.')
      ..writeln();
    void section(String heading, Map<String, String> values) {
      if (values.isEmpty) return;
      buffer.writeln('== $heading ==');
      for (final entry in values.entries) {
        buffer.writeln('${entry.key}: ${entry.value}');
      }
      buffer.writeln();
    }

    section('BUILD', build);
    section('PROJECTION', projection);
    section('CAPTURE', capture);
    section('AUDIO INPUT', audioInput);
    section('RUST', rust);
    section('OUTPUT', output);
    section('LIFECYCLE', lifecycle);
    buffer.writeln('== LOG ==');
    if (log.isEmpty) {
      buffer.writeln('(empty)');
    } else {
      for (final line in log) {
        buffer.writeln(line);
      }
    }
    return buffer.toString();
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(
        raw.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    return const {};
  }

  static List<String> _logLines(Object? raw) {
    if (raw is! List) return const [];
    return raw.map((entry) {
      if (entry is Map) {
        final iso = entry['iso']?.toString() ?? '';
        final category = entry['category']?.toString() ?? '';
        final message = entry['message']?.toString() ?? '';
        return '[$iso] $category $message';
      }
      return entry.toString();
    }).toList();
  }

  static String _yesNo(bool value) => value ? 'yes' : 'no';
}
