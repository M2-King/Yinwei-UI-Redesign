import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/mobile/developer_diagnostics_page.dart';
import 'package:yinwei_player/platform/android_playback_capture.dart';
import 'package:yinwei_player/platform/developer_diagnostics.dart';
import 'package:yinwei_player/platform/screen_audio_probe.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class _MemoryClipboard extends ClipboardTransporter {
  String? last;

  @override
  Future<void> write(String text) async {
    last = text;
  }
}

class _FakeProbe implements ScreenAudioProbe {
  _FakeProbe(this.status);
  ScreenAudioProbeStatus status;

  @override
  bool get supported => status.supported;

  @override
  Future<bool> isAvailable() async => status.supported;

  @override
  Future<void> startCapture() async {}

  @override
  Future<void> stopCapture() async {}

  @override
  Future<ScreenAudioProbeStatus> getStatus() async => status;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('7D1 report lists required sections and never includes PCM samples', () {
    final controller = EngineController();
    controller.lastError = 'none-yet';
    final capture = ScreenAudioProbeStatus.fromChannel({
      'supported': true,
      'captureActive': true,
      'pickerActive': false,
      'pickerState': 'capturing',
      'selectedCaptureMode': 'full-display',
      'audioBufferCount': 12,
      'microphoneBufferCount': 0,
      'screenBufferCount': 4,
      'sampleRate': 48000,
      'channelCount': 2,
      'lastFrameCount': 1024,
      'interleaved': false,
      'formatDescription':
          'rate=48000 channels=2 bits=32 float=true interleaved=false',
      'lastCallbackOutputType': 'audio',
      'capturesAudio': true,
      'lastRmsDb': -18.5,
      'lastPeakDb': -4.2,
      'receivingSystemAudio': true,
      'receivingMicrophone': false,
      'audioSilent': false,
      'pickerCancelled': false,
      'excludesCurrentProcessAudioSupported': true,
      'excludesCurrentProcessAudio': true,
    });
    final report = DeveloperDiagnosticsReport.fromParts(
      native: {
        'runningIosVersion': '27.0',
        'bundleVersion': '1',
        'output': {
          'category': 'AVAudioSessionCategoryPlayback',
          'active': true,
          'currentOutputRoute': 'Headphones',
          'headphones': true,
          'speaker': false,
          'bluetooth': false,
          'sampleRate': 48000.0,
          'otherAudioPlaying': true,
        },
        'lifecycle': {
          'appState': 'foreground',
          'captureStreamStarted': true,
        },
        'log': [
          {
            'iso': '2026-09-20T00:00:00Z',
            'category': 'AUDIO',
            'message': 'type=audio buffers=12 rms=-18.5dB',
          },
        ],
      },
      capture: capture,
      controller: controller,
      backend: EngineBackend.mock,
      generatedAt: DateTime.utc(2026, 9, 20, 9),
    );

    final text = report.asText();
    expect(text, contains('== BUILD =='));
    expect(text, contains('== CAPTURE =='));
    expect(text, contains('== AUDIO INPUT =='));
    expect(text, contains('== RUST =='));
    expect(text, contains('== OUTPUT =='));
    expect(text, contains('== LIFECYCLE =='));
    expect(text, contains('== LOG =='));
    expect(text, contains('last callback output type: audio'));
    expect(text, contains('capturesAudio: yes'));
    expect(text, contains('excludesCurrentProcessAudio'));
    expect(text, contains('stream input initialized: no (7D1 capture-only)'));
    expect(
        text, contains('This report does not contain captured PCM samples.'));
    expect(text.toLowerCase(), isNot(contains('pcmSamples')));
    expect(text, isNot(contains('[0.123')));
    expect(report.asMap()['pcmSamplesIncluded'], isFalse);
    expect(report.asJson(), contains('"pcmSamplesIncluded": false'));
    controller.dispose();
  });

  test('copy writes the text report to the clipboard transporter', () async {
    const channel = MethodChannel(DeveloperDiagnostics.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => <String, dynamic>{});
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final clipboard = _MemoryClipboard();
    final diagnostics =
        DeveloperDiagnostics(channel: channel, clipboard: clipboard);
    final report = await diagnostics.collect(
      capture: ScreenAudioProbeStatus.unavailable,
      now: DateTime.utc(2026, 9, 20),
    );
    await diagnostics.copy(report);
    expect(clipboard.last, contains('YINWEI iOS DIAGNOSTICS'));
    expect(clipboard.last, contains('== BUILD =='));
  });

  testWidgets('diagnostics page copy and export actions are reachable',
      (tester) async {
    const channel = MethodChannel(DeveloperDiagnostics.channelName);
    var exported = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'exportReport') {
        exported = true;
        return {'ok': true, 'shared': true, 'path': '/tmp/yinwei.json'};
      }
      return {
        'runningIosVersion': '27.0',
        'output': {'category': 'playback'},
        'lifecycle': {'appState': 'foreground'},
        'log': <Object>[],
      };
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final clipboard = _MemoryClipboard();
    final controller = EngineController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: DeveloperDiagnosticsPage(
          controller: controller,
          backend: EngineBackend.mock,
          probe: _FakeProbe(
            const ScreenAudioProbeStatus(
              supported: true,
              captureActive: true,
              pickerActive: false,
              audioBufferCount: 3,
              microphoneBufferCount: 0,
              screenBufferCount: 1,
              receivingSystemAudio: true,
              receivingMicrophone: false,
              audioSilent: false,
              pickerCancelled: false,
              excludesCurrentProcessAudioSupported: true,
              excludesCurrentProcessAudio: true,
              capturesAudio: true,
              lastCallbackOutputType: 'audio',
              lastRmsDb: -20,
              lastPeakDb: -6,
            ),
          ),
          diagnostics: DeveloperDiagnostics(
            channel: channel,
            clipboard: clipboard,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('developer-diagnostics-page')), findsOneWidget);
    expect(find.text('Copy Diagnostics'), findsOneWidget);
    expect(find.text('Export Diagnostics'), findsOneWidget);
    expect(find.textContaining('== CAPTURE =='), findsOneWidget);

    await tester.tap(find.byKey(const Key('developer-diagnostics-copy')));
    await tester.pump();
    expect(clipboard.last, contains('system audio buffer count: 3'));

    await tester.tap(find.byKey(const Key('developer-diagnostics-export')));
    await tester.pump();
    expect(exported, isTrue);
    expect(find.text('Share sheet opened'), findsOneWidget);
  });

  test(
      'A2 Android report lists capture plus DSP counters and never includes PCM',
      () {
    final capture = AndroidPlaybackCaptureStatus.fromChannel({
      'supported': true,
      'androidSdk': 34,
      'projectionGranted': true,
      'captureActive': true,
      'foregroundServiceRunning': true,
      'audioRecordState': 'RECORDING',
      'readCount': 82,
      'capturedFrames': 49152,
      'sampleRate': 48000,
      'channelCount': 2,
      'encoding': 'PCM_16BIT',
      'rmsDb': -17.8,
      'peakDb': -2.1,
      'silent': false,
      'receivingPlaybackAudio': true,
      'playbackCaptureConfigured': true,
      'audioRecordSource': 'PLAYBACK_CAPTURE',
      'dspLibraryLoaded': true,
      'dspState': 'Processing',
      'nativeInputFrames': 49152,
      'nativeConsumedFrames': 49152,
      'nativeDspChunks': 96,
      'nativeWetFrames': 49152,
      'nativeDroppedFrames': 0,
      'nativeWetRmsDb': -15.2,
      'nativeWetPeakDb': -2.4,
    });
    final report = DeveloperDiagnosticsReport.fromParts(
      native: {
        'build': {
          'androidSdk': 34,
          'manufacturer': 'Google',
          'model': 'Pixel 8',
          'androidVersion': '14',
          'appVersion': '0.1.0',
        },
        'lifecycle': {
          'appState': 'background',
          'projectionRevoked': false,
        },
        'log': [
          {
            'iso': '2026-09-20T00:00:00Z',
            'category': 'CAPTURE',
            'message': 'reads=82 rms=-17.8dBFS',
          },
        ],
      },
      capture: ScreenAudioProbeStatus.unavailable,
      androidCapture: capture,
      generatedAt: DateTime.utc(2026, 9, 20, 9),
    );

    final text = report.asText();
    expect(text, contains('YINWEI ANDROID DIAGNOSTICS'));
    expect(text, contains('phase: A2 capture-only'));
    expect(text, contains('== BUILD =='));
    expect(text, contains('== PROJECTION =='));
    expect(text, contains('== CAPTURE =='));
    expect(text, contains('== LIFECYCLE =='));
    expect(text, contains('manufacturer: Google'));
    expect(text, contains('model: Pixel 8'));
    expect(text, contains('reads: 82'));
    expect(text, contains('frames: 49152'));
    expect(text, contains('stream input initialized: yes'));
    expect(text, contains('PCM frames pushed: 49152'));
    expect(text, contains('playing captured audio: no (A2 no wet output yet)'));
    expect(
        text, contains('This report does not contain captured PCM samples.'));
    expect(text, contains('microphone used as source: no'));
    expect(report.asMap()['pcmSamplesIncluded'], isFalse);
    expect(report.asMap()['phase'], 'A2');
  });
}
