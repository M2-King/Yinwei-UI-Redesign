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
    test('empty selection follows Windows default and does not pin Sony', () {
      const sony = 'Headphones (WH-1000XM5)';
      final plan = WetOutputPolicy.plan(
        selectedOutput: '',
        detectedHeadphonesName: sony,
        splitDetected: true,
        outputDevices: [
          sony,
          'Speakers (Realtek)',
          'Speakers (Nahimic Audio)',
        ],
      );
      expect(plan.followSystemDefault, isTrue);
      expect(plan.splitRoute, isFalse);
      expect(plan.wetDeviceName, isEmpty);
      expect(plan.pinWetToHeadphones, isFalse);
      expect(plan.nahimicSharing, isTrue);
    });

    test('whitespace selection is still system default', () {
      final plan = WetOutputPolicy.plan(
        selectedOutput: '  ',
        detectedHeadphonesName: 'WH-1000XM5',
        splitDetected: true,
        outputDevices: const ['WH-1000XM5', 'Speakers'],
      );
      expect(plan.followSystemDefault, isTrue);
      expect(plan.splitRoute, isFalse);
      expect(plan.wetDeviceName, isEmpty);
    });

    test('explicit Sony pick keeps that device and may split', () {
      const sony = 'Headphones (WH-1000XM5)';
      final plan = WetOutputPolicy.plan(
        selectedOutput: sony,
        detectedHeadphonesName: sony,
        splitDetected: true,
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
        splitDetected: true,
        outputDevices: ['WH-1000XM5', nahimic],
      );
      expect(plan.followSystemDefault, isFalse);
      expect(plan.splitRoute, isFalse);
      expect(plan.wetDeviceName, nahimic);
      expect(plan.nahimicSharing, isTrue);
    });

    test('Nahimic in the device list does not force a headphone lock', () {
      expect(
        WetOutputPolicy.nahimicPresent(const [
          'Headphones (WH-1000XM5)',
          'Speakers (Nahimic Audio)',
        ]),
        isTrue,
      );
      final plan = WetOutputPolicy.plan(
        selectedOutput: '',
        detectedHeadphonesName: 'Headphones (WH-1000XM5)',
        splitDetected: true,
        outputDevices: const [
          'Headphones (WH-1000XM5)',
          'Speakers (Nahimic Audio)',
        ],
      );
      expect(plan.splitRoute, isFalse);
      expect(plan.wetDeviceName, isEmpty);
      expect(plan.nahimicSharing, isTrue);
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
  });
}
