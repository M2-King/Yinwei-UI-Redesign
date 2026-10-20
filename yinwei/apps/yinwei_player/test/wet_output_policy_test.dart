import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/wet_output_policy.dart';

void main() {
  group('classify', () {
    test('Sony WH-1000XM is headphones, not a forced wet lock', () {
      expect(
        WetOutputPolicy.classify('Headphones (WH-1000XM5)'),
        AudioEndpointKind.headphones,
      );
      expect(
        WetOutputPolicy.classify('WH-1000XM4 Stereo'),
        AudioEndpointKind.headphones,
      );
    });

    test('Nahimic sharing devices are nahimic, never ignore/virtual', () {
      expect(
        WetOutputPolicy.classify('Speakers (Nahimic Audio)'),
        AudioEndpointKind.nahimic,
      );
      expect(
        WetOutputPolicy.classify('Nahimic mirroring'),
        AudioEndpointKind.nahimic,
      );
      expect(
        WetOutputPolicy.classify('Headphones (Nahimic Sound Sharing)'),
        AudioEndpointKind.nahimic,
      );
      expect(
        WetOutputPolicy.classify('A-Volute Nahimic'),
        AudioEndpointKind.nahimic,
      );
    });

    test('VB Cable and Steam remain ignore', () {
      expect(
        WetOutputPolicy.classify('CABLE Input (VB-Audio Virtual Cable)'),
        AudioEndpointKind.ignore,
      );
      expect(
        WetOutputPolicy.classify('Steam Streaming Speakers'),
        AudioEndpointKind.ignore,
      );
    });

    test('Realtek speakers classify as speakers', () {
      expect(
        WetOutputPolicy.classify('扬声器 (Realtek High Definition Audio)'),
        AudioEndpointKind.speakers,
      );
      expect(
        WetOutputPolicy.classify('Speakers (Realtek)'),
        AudioEndpointKind.speakers,
      );
    });
  });

  group('default wet routing', () {
    test('default Sony still mutes separate speakers (no dry+wet chaos)', () {
      const sony = 'Headphones (WH-1000XM5)';
      const speakers = 'Speakers (Realtek)';
      final plan = WetOutputPolicy.plan(
        selectedOutput: '',
        detectedHeadphonesName: sony,
        detectedSpeakersName: speakers,
        splitDetected: true,
        defaultDeviceName: sony,
        outputDevices: [
          sony,
          speakers,
          'Speakers (Nahimic Audio)',
        ],
      );
      expect(plan.followSystemDefault, isTrue);
      expect(plan.wetDeviceName, isEmpty);
      expect(plan.pinWetToHeadphones, isFalse);
      expect(plan.splitRoute, isTrue);
      expect(plan.speakersAreWet, isFalse);
    });

    test('whitespace selection is still system default', () {
      final plan = WetOutputPolicy.plan(
        selectedOutput: '  ',
        detectedHeadphonesName: 'WH-1000XM5',
        detectedSpeakersName: 'Speakers',
        splitDetected: true,
        defaultDeviceName: 'WH-1000XM5',
        outputDevices: const ['WH-1000XM5', 'Speakers'],
      );
      expect(plan.followSystemDefault, isTrue);
      expect(plan.splitRoute, isTrue);
      expect(plan.wetDeviceName, isEmpty);
    });

    test('do not mute speakers when they ARE the Windows default wet path', () {
      const speakers = 'Speakers (Realtek)';
      final plan = WetOutputPolicy.plan(
        selectedOutput: '',
        detectedHeadphonesName: 'Headphones (WH-1000XM5)',
        detectedSpeakersName: speakers,
        splitDetected: true,
        defaultDeviceName: speakers,
        outputDevices: const [
          'Headphones (WH-1000XM5)',
          speakers,
        ],
      );
      expect(plan.followSystemDefault, isTrue);
      expect(plan.splitRoute, isFalse);
      expect(plan.speakersAreWet, isTrue);
      expect(plan.wetDeviceName, isEmpty);
    });

    test('Nahimic default speakers stay unmuted so sharing keeps a source', () {
      const nahimic = 'Speakers (Nahimic Audio)';
      final plan = WetOutputPolicy.plan(
        selectedOutput: '',
        detectedHeadphonesName: 'WH-1000XM5',
        detectedSpeakersName: nahimic,
        splitDetected: true,
        defaultDeviceName: nahimic,
        outputDevices: const ['WH-1000XM5', nahimic],
      );
      expect(plan.splitRoute, isFalse);
      expect(plan.speakersAreWet, isTrue);
      expect(plan.nahimicSharing, isTrue);
      expect(plan.wetDeviceName, isEmpty);
    });

    test('explicit Sony pick keeps that device and mutes speakers', () {
      const sony = 'Headphones (WH-1000XM5)';
      final plan = WetOutputPolicy.plan(
        selectedOutput: sony,
        detectedHeadphonesName: sony,
        detectedSpeakersName: 'Speakers (Realtek)',
        splitDetected: true,
        defaultDeviceName: sony,
        outputDevices: [sony, 'Speakers (Realtek)'],
      );
      expect(plan.followSystemDefault, isFalse);
      expect(plan.splitRoute, isTrue);
      expect(plan.wetDeviceName, sony);
      expect(plan.pinWetToHeadphones, isFalse);
    });

    test('explicit Nahimic pick does not mute-split (sharing path)', () {
      const nahimic = 'Speakers (Nahimic Audio)';
      final plan = WetOutputPolicy.plan(
        selectedOutput: nahimic,
        detectedHeadphonesName: 'WH-1000XM5',
        detectedSpeakersName: nahimic,
        splitDetected: true,
        defaultDeviceName: nahimic,
        outputDevices: ['WH-1000XM5', nahimic],
      );
      expect(plan.followSystemDefault, isFalse);
      expect(plan.splitRoute, isFalse);
      expect(plan.wetDeviceName, nahimic);
      expect(plan.nahimicSharing, isTrue);
    });

    test('unknown default still mutes speakers when a headset exists', () {
      final plan = WetOutputPolicy.plan(
        selectedOutput: '',
        detectedHeadphonesName: 'Headphones (WH-1000XM5)',
        detectedSpeakersName: 'Speakers (Realtek)',
        splitDetected: true,
        defaultDeviceName: '',
        outputDevices: const [
          'Headphones (WH-1000XM5)',
          'Speakers (Realtek)',
        ],
      );
      expect(plan.splitRoute, isTrue);
      expect(plan.wetDeviceName, isEmpty);
      expect(plan.pinWetToHeadphones, isFalse);
    });

    test('detected Sony name never replaces default wet selection', () {
      expect(
        WetOutputPolicy.wetNameAfterDetect(
          selectedOutput: '',
          detectedHeadphonesName: 'Headphones (WH-1000XM5)',
        ),
        isEmpty,
      );
      expect(
        WetOutputPolicy.wetNameAfterDetect(
          selectedOutput: 'Speakers (Nahimic Audio)',
          detectedHeadphonesName: 'WH-1000XM5',
        ),
        'Speakers (Nahimic Audio)',
      );
    });

    test('transferNote reports muted speakers vs overlay', () {
      const sony = 'Headphones (WH-1000XM5)';
      const speakers = 'Speakers (Realtek)';
      final muted = WetOutputPolicy.plan(
        selectedOutput: '',
        detectedHeadphonesName: sony,
        detectedSpeakersName: speakers,
        splitDetected: true,
        defaultDeviceName: sony,
        outputDevices: const [sony, speakers],
      );
      expect(WetOutputPolicy.transferNote(muted), contains('已静音'));
      expect(WetOutputPolicy.transferNote(muted), contains('系统默认输出'));

      final overlay = WetOutputPolicy.plan(
        selectedOutput: '',
        detectedHeadphonesName: sony,
        detectedSpeakersName: speakers,
        splitDetected: true,
        defaultDeviceName: speakers,
        outputDevices: const [sony, speakers],
      );
      expect(WetOutputPolicy.transferNote(overlay), contains('未静音'));
    });

    test('sameEndpoint matches cpal vs WinRT speaker names', () {
      expect(
        WetOutputPolicy.sameEndpoint(
          'Speakers (Realtek High Definition Audio)',
          'Speakers (Realtek High Definition Audio)',
        ),
        isTrue,
      );
      expect(
        WetOutputPolicy.sameEndpoint(
          'Headphones (WH-1000XM5)',
          'Speakers (Realtek)',
        ),
        isFalse,
      );
    });
  });
}
