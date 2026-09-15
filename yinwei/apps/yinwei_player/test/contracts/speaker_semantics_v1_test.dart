import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/speaker_semantics_v1.dart';

import 'fixture_loader.dart';

void main() {
  final fixture = loadContractFixture('speaker_semantics_v1.json');
  final engine = fixture['currentEngine'] as Map<String, dynamic>;

  test('SpeakerSemanticsV1 fixture metadata', () {
    expect(fixture['schemaId'], 'SpeakerSemanticsV1');
  });

  test('SpeakerSemanticsV1 matches current stereo engine facts', () {
    expect(SpeakerSemanticsV1.input, engine['input']);
    expect(SpeakerSemanticsV1.inputChannelCount, engine['inputChannelCount']);
    expect(SpeakerSemanticsV1.acousticFeeds, engine['acousticFeeds']);
    expect(SpeakerSemanticsV1.arrayModes, engine['arrayModes']);
    expect(
      SpeakerSemanticsV1.isDiscreteSurroundDecoder,
      engine['isDiscreteSurroundDecoder'],
    );
    expect(SpeakerSemanticsV1.isDiscrete71, engine['isDiscrete71']);
    expect(SpeakerSemanticsV1.maxVisualEmitters, engine['maxVisualEmitters']);
    expect(
      SpeakerSemanticsV1.trueMultichannelRoutingInScope,
      engine['trueMultichannelRoutingInScope'],
    );
    expect(SpeakerSemanticsV1.extraSlotFeed, fixture['extraSlotFeed']);
    expect(
      SpeakerSemanticsV1.visualRolesDoNotImplyRouting,
      fixture['visualRolesDoNotImplyRouting'],
    );
  });

  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
  for (final c in cases) {
    test('SpeakerSemanticsV1 ${c['id']}', () {
      final expectMap = c['expect'] as Map<String, dynamic>;
      if (expectMap.containsKey('input')) {
        expect(SpeakerSemanticsV1.input, expectMap['input']);
        expect(SpeakerSemanticsV1.inputChannelCount, expectMap['inputChannelCount']);
      }
      if (expectMap.containsKey('acousticFeeds')) {
        expect(SpeakerSemanticsV1.acousticFeeds, expectMap['acousticFeeds']);
      }
      if (expectMap.containsKey('isDiscrete71')) {
        expect(SpeakerSemanticsV1.isDiscrete71, isFalse);
        expect(SpeakerSemanticsV1.isDiscreteSurroundDecoder, isFalse);
        expect(SpeakerSemanticsV1.trueMultichannelRoutingInScope, isFalse);
      }
      if (expectMap.containsKey('visualRolesDoNotImplyRouting')) {
        expect(
          SpeakerSemanticsV1.visualRolesDoNotImplyRouting,
          expectMap['visualRolesDoNotImplyRouting'],
        );
        expect(SpeakerSemanticsV1.maxVisualEmitters, 8);
      }
      if (expectMap.containsKey('unknownFeeds')) {
        for (final name in (expectMap['unknownFeeds'] as List).cast<String>()) {
          expect(SpeakerSemanticsV1.isAcousticFeed(name), isFalse);
        }
      }
    });
  }
}
