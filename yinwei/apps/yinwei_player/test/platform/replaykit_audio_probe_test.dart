import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('picker failure reaches the caller instead of being swallowed',
      () async {
    const channel = MethodChannel('test/replaykit-picker-error');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
          code: 'broadcast_extension_missing',
          message: 'Broadcast extension missing');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final probe = MethodChannelReplayKitAudioProbe(channel: channel);
    await expectLater(
        probe.showBroadcastPicker(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'broadcast_extension_missing')));
  });

  test('ReplayKit probe remains unavailable outside iOS', () {
    expect(ReplayKitAudioProbe.create(isIOS: false).supported, isFalse);
  });

  test('numeric extension status maps to receiving app audio', () {
    final status = ReplayKitAudioProbeStatus.fromChannel(const {
      'supported': true,
      'broadcastActive': true,
      'broadcastPhase': 'broadcasting',
      'appAudioBufferCount': 81,
      'ignoredMicrophoneBufferCount': 4,
      'discardedVideoBufferCount': 57,
      'droppedInspectionBufferCount': 0,
      'receivingAppAudio': true,
      'audioSilent': false,
      'returnToneActive': true,
      'sampleRate': 48000,
      'channelCount': 2,
      'lastFrameCount': 1024,
      'lastRmsDb': -21.5,
      'lastPeakDb': -3.25,
    });

    expect(status.phase, ReplayKitAudioProbePhase.receivingAppAudio);
    expect(status.appAudioBufferCount, 81);
    expect(status.ignoredMicrophoneBufferCount, 4);
    expect(status.discardedVideoBufferCount, 57);
    expect(status.sampleRate, 48000);
    expect(status.channelCount, 2);
    expect(status.lastRmsDb, closeTo(-21.5, 0.001));
    expect(status.returnToneActive, isTrue);
  });

  test('method channel opens Apple picker and resets numeric status', () async {
    const channel = MethodChannel('test/replaykit');
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      switch (call.method) {
        case 'isAvailable':
          return {'supported': true};
        case 'showBroadcastPicker':
        case 'resetStatus':
        case 'playReturnTone':
        case 'stopReturnTone':
          return {'ok': true};
        case 'getStatus':
          return {
            'supported': true,
            'broadcastActive': false,
            'broadcastPhase': 'idle',
          };
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final probe = MethodChannelReplayKitAudioProbe(channel: channel);
    expect(await probe.isAvailable(), isTrue);
    await probe.showBroadcastPicker();
    expect((await probe.getStatus()).phase, ReplayKitAudioProbePhase.ready);
    await probe.resetStatus();
    await probe.playReturnTone();
    await probe.stopReturnTone();
    expect(
      methods,
      [
        'isAvailable',
        'showBroadcastPicker',
        'getStatus',
        'resetStatus',
        'playReturnTone',
        'stopReturnTone',
      ],
    );
  });

  test('paused and finished phases are distinct from capture errors', () {
    final paused = ReplayKitAudioProbeStatus.fromChannel(const {
      'supported': true,
      'broadcastActive': true,
      'broadcastPhase': 'paused',
    });
    final finished = ReplayKitAudioProbeStatus.fromChannel(const {
      'supported': true,
      'broadcastActive': false,
      'broadcastPhase': 'finished',
    });
    expect(paused.phase, ReplayKitAudioProbePhase.paused);
    expect(finished.phase, ReplayKitAudioProbePhase.finished);
  });
}
