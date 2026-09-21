import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/android_playback_capture.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AudioPlaybackCapture is gated at Android 10 / API 29', () {
    expect(AndroidPlaybackCapture.isSupportedSdk(28), isFalse);
    expect(AndroidPlaybackCapture.isSupportedSdk(29), isTrue);
    expect(AndroidPlaybackCapture.isSupportedSdk(34), isTrue);
    expect(AndroidPlaybackCapture.isSupportedSdk(36), isTrue);
  });

  test(
      'probe is unavailable off Android even if Android capabilities are passed',
      () {
    final probe = AndroidPlaybackCapture.create(
      capabilities: PlatformCapabilities.android,
      isAndroid: false,
    );
    expect(probe.supported, isFalse);
  });

  test('Windows Live Transfer capability does not enable Android capture', () {
    final probe = AndroidPlaybackCapture.create(
      capabilities: PlatformCapabilities.windows,
      isAndroid: false,
    );
    expect(probe.supported, isFalse);
    expect(PlatformCapabilities.windows.liveTransfer, isTrue);
    expect(PlatformCapabilities.windows.androidPlaybackCapture, isFalse);
    expect(PlatformCapabilities.android.liveTransfer, isFalse);
    expect(PlatformCapabilities.android.androidPlaybackCapture, isTrue);
  });

  test(
      'Android below API 29 reports unavailable without treating it as an error',
      () async {
    const channel = MethodChannel(AndroidPlaybackCapture.channelName);
    _mock(channel, {
      'isAvailable': {
        'supported': false,
        'androidSdk': 28,
      },
      'getStatus': _status(supported: false, androidSdk: 28),
    });

    final probe = MethodChannelAndroidPlaybackCapture(channel: channel);
    expect(await probe.isAvailable(), isFalse);
    await probe.requestAndStartCapture();
    final status = await probe.getStatus();
    expect(status.supported, isFalse);
    expect(status.androidSdk, 28);
    expect(status.phase, AndroidPlaybackCapturePhase.unavailable);
    expect(status.lastError, isNull);
    expect(status.permissionCancelled, isFalse);
  });

  test('status payload conversion maps native keys', () {
    final status = AndroidPlaybackCaptureStatus.fromChannel({
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
      'lastError': null,
      'audioRecordSource': 'PLAYBACK_CAPTURE',
    });
    expect(status.supported, isTrue);
    expect(status.androidSdk, 34);
    expect(status.projectionGranted, isTrue);
    expect(status.captureActive, isTrue);
    expect(status.foregroundServiceRunning, isTrue);
    expect(status.audioRecordState, 'RECORDING');
    expect(status.readCount, 82);
    expect(status.capturedFrames, 49152);
    expect(status.sampleRate, 48000);
    expect(status.channelCount, 2);
    expect(status.encoding, 'PCM_16BIT');
    expect(status.rmsDb, closeTo(-17.8, 0.001));
    expect(status.peakDb, closeTo(-2.1, 0.001));
    expect(status.receivingPlaybackAudio, isTrue);
    expect(status.audioRecordSource, 'PLAYBACK_CAPTURE');
    expect(status.phase, AndroidPlaybackCapturePhase.receivingPlaybackAudio);
    expect(status.dataState, PlaybackCaptureDataState.nonSilent);
  });

  test('status payload maps native DSP counters for A2', () {
    final status = AndroidPlaybackCaptureStatus.fromChannel({
      'supported': true,
      'androidSdk': 34,
      'projectionGranted': true,
      'captureActive': true,
      'foregroundServiceRunning': true,
      'audioRecordState': 'RECORDING',
      'readCount': 404,
      'capturedFrames': 827392,
      'silent': false,
      'receivingPlaybackAudio': true,
      'dspLibraryLoaded': true,
      'dspState': 'Processing',
      'nativeInputFrames': 827392,
      'nativeConsumedFrames': 826880,
      'nativeDspChunks': 1615,
      'nativeWetFrames': 826880,
      'nativeDroppedFrames': 0,
      'nativeQueueDepthFrames': 512,
      'nativeWetRmsDb': -15.2,
      'nativeWetPeakDb': -2.4,
      'nativeLastError': '',
    });
    expect(status.dspLibraryLoaded, isTrue);
    expect(status.dspBridgeLabel, 'Processing');
    expect(status.nativeInputFrames, 827392);
    expect(status.nativeDspChunks, 1615);
    expect(status.nativeWetRmsDb, closeTo(-15.2, 0.001));
    expect(status.nativeLastError, isNull);
    expect(status.phase, AndroidPlaybackCapturePhase.receivingPlaybackAudio);
  });

  test('start/stop lifecycle: permission waiting then capturing then ready',
      () async {
    const channel = MethodChannel(AndroidPlaybackCapture.channelName);
    var captureActive = false;
    var permissionPending = false;
    var projectionGranted = false;
    var serviceRunning = false;
    _mock(channel, {
      'isAvailable': {'supported': true, 'androidSdk': 34},
      'requestAndStartCapture': () {
        permissionPending = true;
        captureActive = false;
        return {'ok': true};
      },
      'stopCapture': () {
        permissionPending = false;
        captureActive = false;
        projectionGranted = false;
        serviceRunning = false;
        return {'ok': true};
      },
      'getStatus': () => _status(
            supported: true,
            androidSdk: 34,
            captureActive: captureActive,
            permissionPending: permissionPending,
            projectionGranted: projectionGranted,
            foregroundServiceRunning: serviceRunning,
          ),
    });

    final probe = MethodChannelAndroidPlaybackCapture(channel: channel);
    expect(await probe.isAvailable(), isTrue);
    expect((await probe.getStatus()).phase, AndroidPlaybackCapturePhase.ready);

    await probe.requestAndStartCapture();
    expect(
      (await probe.getStatus()).phase,
      AndroidPlaybackCapturePhase.waitingForPermission,
    );

    permissionPending = false;
    projectionGranted = true;
    serviceRunning = true;
    captureActive = true;
    expect(
      (await probe.getStatus()).phase,
      AndroidPlaybackCapturePhase.capturing,
    );

    await probe.stopCapture();
    expect((await probe.getStatus()).phase, AndroidPlaybackCapturePhase.ready);
    expect((await probe.getStatus()).captureActive, isFalse);
  });

  test('permission cancellation is not an error', () async {
    const channel = MethodChannel(AndroidPlaybackCapture.channelName);
    _mock(channel, {
      'isAvailable': {'supported': true, 'androidSdk': 34},
      'requestAndStartCapture': {'ok': true},
      'getStatus': _status(
        supported: true,
        androidSdk: 34,
        permissionCancelled: true,
      ),
    });

    final probe = MethodChannelAndroidPlaybackCapture(channel: channel);
    await probe.requestAndStartCapture();
    final status = await probe.getStatus();
    expect(status.permissionCancelled, isTrue);
    expect(status.lastError, isNull);
    expect(status.phase, AndroidPlaybackCapturePhase.ready);
  });

  test('captureHint is mapped from native status without becoming lastError',
      () {
    final status = AndroidPlaybackCaptureStatus.fromChannel({
      'supported': true,
      'androidSdk': 34,
      'permissionCancelled': true,
      'captureHint': 'Screen audio not granted — tap Start Capture',
    });
    expect(status.captureHint, 'Screen audio not granted — tap Start Capture');
    expect(status.lastError, isNull);
    expect(status.phase, AndroidPlaybackCapturePhase.ready);
  });

  test('RECORD_AUDIO denial maps to Error', () async {
    const channel = MethodChannel(AndroidPlaybackCapture.channelName);
    _mock(channel, {
      'isAvailable': {'supported': true, 'androidSdk': 34},
      'requestAndStartCapture': PlatformException(
        code: 'permission',
        message: 'RECORD_AUDIO denied',
      ),
      'getStatus': _status(
        supported: true,
        androidSdk: 34,
        permissionDenied: true,
        lastError: 'RECORD_AUDIO denied',
      ),
    });

    final probe = MethodChannelAndroidPlaybackCapture(channel: channel);
    await probe.requestAndStartCapture();
    final status = await probe.getStatus();
    expect(status.permissionDenied, isTrue);
    expect(status.phase, AndroidPlaybackCapturePhase.error);
    expect(status.lastError, 'RECORD_AUDIO denied');
  });

  test('projection revoked stops capture and maps to Error', () async {
    final status = AndroidPlaybackCaptureStatus.fromChannel(_status(
      supported: true,
      androidSdk: 34,
      projectionRevoked: true,
      lastError: 'projection revoked',
    ));
    expect(status.projectionRevoked, isTrue);
    expect(status.captureActive, isFalse);
    expect(status.phase, AndroidPlaybackCapturePhase.error);
    expect(status.lastError, 'projection revoked');
  });

  test('silent PCM is distinct from no data and from non-silent playback', () {
    final none = AndroidPlaybackCaptureStatus.fromChannel(_status(
      supported: true,
      androidSdk: 34,
      captureActive: true,
      foregroundServiceRunning: true,
      audioRecordState: 'RECORDING',
      readCount: 0,
      capturedFrames: 0,
    ));
    final silent = AndroidPlaybackCaptureStatus.fromChannel(_status(
      supported: true,
      androidSdk: 34,
      captureActive: true,
      foregroundServiceRunning: true,
      audioRecordState: 'RECORDING',
      readCount: 95,
      capturedFrames: 57000,
      sampleRate: 48000,
      channelCount: 2,
      silent: true,
    ));
    final wet = AndroidPlaybackCaptureStatus.fromChannel(_status(
      supported: true,
      androidSdk: 34,
      captureActive: true,
      foregroundServiceRunning: true,
      audioRecordState: 'RECORDING',
      readCount: 82,
      capturedFrames: 49152,
      sampleRate: 48000,
      channelCount: 2,
      receivingPlaybackAudio: true,
      silent: false,
      rmsDb: -17.8,
      peakDb: -2.1,
    ));

    expect(none.phase, AndroidPlaybackCapturePhase.capturing);
    expect(none.dataState, PlaybackCaptureDataState.noData);
    expect(silent.phase, AndroidPlaybackCapturePhase.silent);
    expect(silent.dataState, PlaybackCaptureDataState.silent);
    expect(wet.phase, AndroidPlaybackCapturePhase.receivingPlaybackAudio);
    expect(wet.dataState, PlaybackCaptureDataState.nonSilent);
    expect(wet.audioRecordSource, isNot('MIC'));
  });

  test('sustained silent reads classify as source-app capture restriction', () {
    final status = AndroidPlaybackCaptureStatus.fromChannel(_status(
      supported: true,
      androidSdk: 34,
      captureActive: true,
      foregroundServiceRunning: true,
      audioRecordState: 'RECORDING',
      readCount: 200,
      capturedFrames: 144000,
      sampleRate: 48000,
      channelCount: 2,
      silent: true,
      sourceCaptureRestricted: true,
    ));
    expect(status.phase, AndroidPlaybackCapturePhase.blockedBySourceApp);
    expect(status.dataState, PlaybackCaptureDataState.silent);
    expect(status.receivingPlaybackAudio, isFalse);
  });

  test('read counter and frame counter increase independently of silence', () {
    final first = AndroidPlaybackCaptureStatus.fromChannel(_status(
      supported: true,
      captureActive: true,
      readCount: 10,
      capturedFrames: 4800,
      silent: true,
    ));
    final second = AndroidPlaybackCaptureStatus.fromChannel(_status(
      supported: true,
      captureActive: true,
      readCount: 82,
      capturedFrames: 49152,
      silent: true,
    ));
    expect(second.readCount, greaterThan(first.readCount));
    expect(second.capturedFrames, greaterThan(first.capturedFrames));
    expect(second.dataState, PlaybackCaptureDataState.silent);
  });

  test('native start failure maps to Error without crashing stop', () async {
    const channel = MethodChannel(AndroidPlaybackCapture.channelName);
    _mock(channel, {
      'isAvailable': {'supported': true, 'androidSdk': 34},
      'requestAndStartCapture': PlatformException(
        code: 'capture',
        message: 'AudioRecord init failed',
      ),
      'stopCapture': {'ok': true},
      'getStatus': _status(
        supported: true,
        androidSdk: 34,
        lastError: 'AudioRecord init failed',
      ),
    });

    final probe = MethodChannelAndroidPlaybackCapture(channel: channel);
    await probe.requestAndStartCapture();
    final status = await probe.getStatus();
    expect(status.phase, AndroidPlaybackCapturePhase.error);
    expect(status.lastError, 'AudioRecord init failed');
    await probe.stopCapture();
  });

  test('microphone is never accepted as the Android capture source', () {
    final status = AndroidPlaybackCaptureStatus.fromChannel(_status(
      supported: true,
      captureActive: true,
      audioRecordSource: 'PLAYBACK_CAPTURE',
      receivingPlaybackAudio: true,
      readCount: 4,
    ));
    expect(status.audioRecordSource, 'PLAYBACK_CAPTURE');
    expect(status.usesMicrophoneSource, isFalse);
  });
}

Map<String, dynamic> _status({
  bool supported = false,
  int androidSdk = 0,
  bool projectionGranted = false,
  bool captureActive = false,
  bool foregroundServiceRunning = false,
  String audioRecordState = 'UNINITIALIZED',
  int readCount = 0,
  int capturedFrames = 0,
  int? sampleRate,
  int? channelCount,
  String? encoding,
  double? rmsDb,
  double? peakDb,
  bool silent = false,
  bool receivingPlaybackAudio = false,
  String? lastError,
  bool permissionPending = false,
  bool permissionDenied = false,
  bool permissionCancelled = false,
  bool projectionRevoked = false,
  bool sourceCaptureRestricted = false,
  String audioRecordSource = 'PLAYBACK_CAPTURE',
}) {
  return {
    'supported': supported,
    'androidSdk': androidSdk,
    'projectionGranted': projectionGranted,
    'captureActive': captureActive,
    'foregroundServiceRunning': foregroundServiceRunning,
    'audioRecordState': audioRecordState,
    'readCount': readCount,
    'capturedFrames': capturedFrames,
    'sampleRate': sampleRate,
    'channelCount': channelCount,
    'encoding': encoding,
    'rmsDb': rmsDb,
    'peakDb': peakDb,
    'silent': silent,
    'receivingPlaybackAudio': receivingPlaybackAudio,
    'lastError': lastError,
    'permissionPending': permissionPending,
    'permissionDenied': permissionDenied,
    'permissionCancelled': permissionCancelled,
    'projectionRevoked': projectionRevoked,
    'sourceCaptureRestricted': sourceCaptureRestricted,
    'audioRecordSource': audioRecordSource,
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
