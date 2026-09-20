import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/platform/screen_audio_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('probe is unavailable off iOS even when iOS capabilities are passed', () {
    final probe = ScreenAudioProbe.create(
      capabilities: PlatformCapabilities.ios,
    );
    expect(probe.supported, isFalse);
  });

  test('Windows profile does not enable the iOS capture probe', () {
    final probe = ScreenAudioProbe.create(
      capabilities: PlatformCapabilities.windows,
    );
    expect(probe.supported, isFalse);
  });

  test('iOS below 27 reports unavailable without treating it as an error', () async {
    const channel = MethodChannel(ScreenAudioProbe.channelName);
    _mock(channel, {
      'isAvailable': {
        'supported': false,
        'osVersion': '18.5',
        'sdkCompiled': false,
      },
      'getStatus': _status(supported: false),
    });

    final probe = MethodChannelScreenAudioProbe(channel: channel);
    expect(await probe.isAvailable(), isFalse);
    await probe.startCapture();
    final status = await probe.getStatus();
    expect(status.supported, isFalse);
    expect(status.phase, ScreenAudioProbePhase.unavailable);
    expect(status.lastError, isNull);
    expect(status.pickerCancelled, isFalse);
  });

  test('status payload conversion maps native keys', () {
    final status = ScreenAudioProbeStatus.fromChannel({
      'supported': true,
      'captureActive': true,
      'pickerActive': false,
      'audioBufferCount': 47,
      'microphoneBufferCount': 0,
      'screenBufferCount': 12,
      'sampleRate': 48000,
      'channelCount': 2,
      'lastRmsDb': -19.2,
      'lastPeakDb': -3.7,
      'receivingSystemAudio': true,
      'receivingMicrophone': false,
      'audioSilent': false,
      'pickerCancelled': false,
      'excludesCurrentProcessAudioSupported': true,
      'excludesCurrentProcessAudio': true,
      'lastError': null,
    });
    expect(status.supported, isTrue);
    expect(status.captureActive, isTrue);
    expect(status.audioBufferCount, 47);
    expect(status.microphoneBufferCount, 0);
    expect(status.screenBufferCount, 12);
    expect(status.sampleRate, 48000);
    expect(status.channelCount, 2);
    expect(status.lastRmsDb, closeTo(-19.2, 0.001));
    expect(status.lastPeakDb, closeTo(-3.7, 0.001));
    expect(status.receivingSystemAudio, isTrue);
    expect(status.receivingMicrophone, isFalse);
    expect(status.phase, ScreenAudioProbePhase.receivingSystemAudio);
    expect(status.lastCallbackOutputType, isNull);
  });

  test('audio output type fields map from native capture status', () {
    final status = ScreenAudioProbeStatus.fromChannel({
      'supported': true,
      'captureActive': true,
      'pickerActive': false,
      'pickerState': 'capturing',
      'selectedCaptureMode': 'full-display',
      'audioBufferCount': 9,
      'microphoneBufferCount': 0,
      'screenBufferCount': 3,
      'lastCallbackOutputType': 'audio',
      'capturesAudio': true,
      'lastFrameCount': 512,
      'interleaved': false,
      'formatDescription': 'rate=48000 channels=2 bits=32 float=true interleaved=false',
      'receivingSystemAudio': true,
      'receivingMicrophone': false,
      'audioSilent': false,
      'excludesCurrentProcessAudioSupported': true,
      'excludesCurrentProcessAudio': true,
    });
    expect(status.lastCallbackOutputType, 'audio');
    expect(status.capturesAudio, isTrue);
    expect(status.selectedCaptureMode, 'full-display');
    expect(status.pickerState, 'capturing');
    expect(status.lastFrameCount, 512);
    expect(status.interleaved, isFalse);
    expect(status.formatDescription, contains('rate=48000'));
  });

  test('start/stop lifecycle: picker waiting then capturing then ready', () async {
    const channel = MethodChannel(ScreenAudioProbe.channelName);
    var captureActive = false;
    var pickerActive = false;
    _mock(channel, {
      'isAvailable': {'supported': true},
      'startCapture': () {
        pickerActive = true;
        captureActive = false;
        return {'ok': true};
      },
      'stopCapture': () {
        pickerActive = false;
        captureActive = false;
        return {'ok': true};
      },
      'getStatus': () => _status(
            supported: true,
            captureActive: captureActive,
            pickerActive: pickerActive,
          ),
    });

    final probe = MethodChannelScreenAudioProbe(channel: channel);
    expect(await probe.isAvailable(), isTrue);
    expect((await probe.getStatus()).phase, ScreenAudioProbePhase.ready);

    await probe.startCapture();
    expect((await probe.getStatus()).phase, ScreenAudioProbePhase.waitingForPicker);

    pickerActive = false;
    captureActive = true;
    expect((await probe.getStatus()).phase, ScreenAudioProbePhase.capturing);

    await probe.stopCapture();
    expect((await probe.getStatus()).phase, ScreenAudioProbePhase.ready);
    expect((await probe.getStatus()).captureActive, isFalse);
  });

  test('picker cancellation is not an error', () async {
    const channel = MethodChannel(ScreenAudioProbe.channelName);
    _mock(channel, {
      'isAvailable': {'supported': true},
      'startCapture': {'ok': true},
      'getStatus': _status(
        supported: true,
        pickerActive: false,
        captureActive: false,
        pickerCancelled: true,
      ),
    });

    final probe = MethodChannelScreenAudioProbe(channel: channel);
    await probe.startCapture();
    final status = await probe.getStatus();
    expect(status.pickerCancelled, isTrue);
    expect(status.lastError, isNull);
    expect(status.phase, ScreenAudioProbePhase.ready);
  });

  test('silent PCM is distinct from no buffers and from non-silent audio', () {
    final none = ScreenAudioProbeStatus.fromChannel(_status(
      supported: true,
      captureActive: true,
      audioBufferCount: 0,
    ));
    final silent = ScreenAudioProbeStatus.fromChannel(_status(
      supported: true,
      captureActive: true,
      audioBufferCount: 51,
      audioSilent: true,
      lastRmsDb: null,
    ));
    final wet = ScreenAudioProbeStatus.fromChannel(_status(
      supported: true,
      captureActive: true,
      audioBufferCount: 47,
      receivingSystemAudio: true,
      lastRmsDb: -19.2,
      lastPeakDb: -3.7,
    ));

    expect(none.phase, ScreenAudioProbePhase.capturing);
    expect(none.hasAudioBuffers, isFalse);
    expect(silent.phase, ScreenAudioProbePhase.silent);
    expect(silent.hasAudioBuffers, isTrue);
    expect(wet.phase, ScreenAudioProbePhase.receivingSystemAudio);
    expect(wet.receivingMicrophone, isFalse);
  });

  test('microphone buffers never count as system-audio success', () {
    final status = ScreenAudioProbeStatus.fromChannel(_status(
      supported: true,
      captureActive: true,
      audioBufferCount: 0,
      microphoneBufferCount: 80,
      receivingMicrophone: true,
    ));
    expect(status.phase, isNot(ScreenAudioProbePhase.receivingSystemAudio));
    expect(status.receivingSystemAudio, isFalse);
    expect(status.receivingMicrophone, isTrue);
  });

  test('native start failure maps to Error without crashing stop', () async {
    const channel = MethodChannel(ScreenAudioProbe.channelName);
    _mock(channel, {
      'isAvailable': {'supported': true},
      'startCapture': PlatformException(
        code: 'capture',
        message: 'picker failed',
      ),
      'stopCapture': {'ok': true},
      'getStatus': _status(
        supported: true,
        lastError: 'picker failed',
      ),
    });

    final probe = MethodChannelScreenAudioProbe(channel: channel);
    await probe.startCapture();
    final status = await probe.getStatus();
    expect(status.phase, ScreenAudioProbePhase.error);
    expect(status.lastError, 'picker failed');
    await probe.stopCapture();
  });
}

Map<String, dynamic> _status({
  bool supported = false,
  bool captureActive = false,
  bool pickerActive = false,
  int audioBufferCount = 0,
  int microphoneBufferCount = 0,
  int screenBufferCount = 0,
  int? sampleRate,
  int? channelCount,
  double? lastRmsDb,
  double? lastPeakDb,
  bool receivingSystemAudio = false,
  bool receivingMicrophone = false,
  bool audioSilent = false,
  bool pickerCancelled = false,
  bool excludesCurrentProcessAudioSupported = false,
  bool excludesCurrentProcessAudio = false,
  String? lastError,
  String pickerState = 'idle',
  String selectedCaptureMode = 'full-display',
  String? lastCallbackOutputType,
  bool capturesAudio = false,
  int? lastFrameCount,
  bool? interleaved,
  String? formatDescription,
}) {
  return {
    'supported': supported,
    'captureActive': captureActive,
    'pickerActive': pickerActive,
    'audioBufferCount': audioBufferCount,
    'microphoneBufferCount': microphoneBufferCount,
    'screenBufferCount': screenBufferCount,
    'sampleRate': sampleRate,
    'channelCount': channelCount,
    'lastRmsDb': lastRmsDb,
    'lastPeakDb': lastPeakDb,
    'receivingSystemAudio': receivingSystemAudio,
    'receivingMicrophone': receivingMicrophone,
    'audioSilent': audioSilent,
    'pickerCancelled': pickerCancelled,
    'excludesCurrentProcessAudioSupported':
        excludesCurrentProcessAudioSupported,
    'excludesCurrentProcessAudio': excludesCurrentProcessAudio,
    'lastError': lastError,
    'pickerState': pickerState,
    'selectedCaptureMode': selectedCaptureMode,
    'lastCallbackOutputType': lastCallbackOutputType,
    'capturesAudio': capturesAudio,
    'lastFrameCount': lastFrameCount,
    'interleaved': interleaved,
    'formatDescription': formatDescription,
  };
}

void _mock(MethodChannel channel, Map<String, Object?> handlers) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    final handler = handlers[call.method];
    if (handler is PlatformException) {
      throw handler;
    }
    if (handler is Function) {
      return (handler as dynamic)();
    }
    return handler;
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
