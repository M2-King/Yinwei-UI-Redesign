import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/app_audio_route.dart';
import 'package:yinwei_player/bridge/wet_output_policy.dart';

// Row format and device names as printed by the routing script's `list`
// action on the owner's laptop (2026-10-18).
const _speakers = 'speakers|扬声器 (2- Realtek(R) Audio)|id-realtek';
const _steam = 'sink|扬声器 (Steam Streaming Speakers)|id-steam';
const _todesk = 'sink|扬声器 (ToDesk Virtual Audio)|id-todesk';
const _phones = 'headphones|耳机 (WF-1000XM5)|id-buds';

void main() {
  group('parseSplit', () {
    test('speakers only: original goes to the first silent sink', () {
      final split = AppAudioRouter.parseSplit([_speakers, _steam, _todesk],
          wetName: '扬声器 (2- Realtek(R) Audio)');
      expect(split, isNotNull);
      expect(split!.silentSink, isTrue);
      expect(split.speakersId, 'id-steam');
    });

    test('a sink that is the wet device is skipped', () {
      final split = AppAudioRouter.parseSplit([_speakers, _steam, _todesk],
          wetName: '扬声器 (Steam Streaming Speakers)');
      expect(split!.speakersId, 'id-todesk');
    });

    test('earbuds present: still prefer the silent sink over muting speakers',
        () {
      final split = AppAudioRouter.parseSplit([_phones, _speakers, _steam]);
      expect(split!.silentSink, isTrue);
      expect(split.speakersId, 'id-steam');
      expect(split.headphonesName, '耳机 (WF-1000XM5)');
    });

    test('no sink: unchanged headphones + muted speakers split', () {
      final split = AppAudioRouter.parseSplit([_phones, _speakers]);
      expect(split!.silentSink, isFalse);
      expect(split.speakersId, 'id-realtek');
      expect(AppAudioRouter.parseSplit([_speakers]), isNull);
    });
  });

  group('silent sink plan', () {
    WetOutputPlan plan(String defaultDevice, {String selected = ''}) =>
        WetOutputPolicy.plan(
          selectedOutput: selected,
          detectedSpeakersName: '扬声器 (Steam Streaming Speakers)',
          splitDetected: true,
          outputDevices: const [],
          defaultDeviceName: defaultDevice,
          silentSink: true,
        );

    test('wet on laptop speakers: split, no clash', () {
      final p = plan('扬声器 (2- Realtek(R) Audio)');
      expect(p.splitRoute, isTrue);
      expect(p.speakersAreWet, isFalse);
      expect(p.wetIsVirtual, isFalse);
      expect(WetOutputPolicy.transferNote(p), contains('静音虚拟设备'));
    });

    test('wet on earbuds: split as well', () {
      expect(plan('耳机 (WF-1000XM5)').splitRoute, isTrue);
    });

    test('never mute the sink when it is the wet device', () {
      final p = plan('扬声器 (Steam Streaming Speakers)');
      expect(p.splitRoute, isFalse);
      expect(p.wetIsVirtual, isTrue);
      expect(WetOutputPolicy.transferNote(p), contains('虚拟设备，湿声听不到'));
    });

    test('without a sink the old rule still keeps wet speakers unmuted', () {
      final p = WetOutputPolicy.plan(
        selectedOutput: '',
        detectedSpeakersName: '扬声器 (2- Realtek(R) Audio)',
        splitDetected: true,
        outputDevices: const [],
        defaultDeviceName: '扬声器 (2- Realtek(R) Audio)',
      );
      expect(p.splitRoute, isFalse);
      expect(p.speakersAreWet, isTrue);
      expect(p.silentSink, isFalse);
    });
  });
}
