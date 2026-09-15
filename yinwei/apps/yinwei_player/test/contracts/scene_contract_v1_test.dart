import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/contracts/scene_contract_v1.dart';

import 'fixture_loader.dart';

void main() {
  final fixture = loadContractFixture('scene_fixtures_v1.json');
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('SceneContractV1 fixture metadata', () {
    expect(fixture['schemaId'], 'SceneContractV1');
    expect(fixture['forbiddenTopLevelKeys'], kForbiddenSceneTopLevelKeysV1);
  });

  for (final c in cases) {
    test('SceneContractV1 ${c['id']}', () {
      final kind = c['kind'] as String;
      if (kind == 'validate') {
        final result = validateSceneV1(c['scene'] as Map);
        final expectMap = c['expect'] as Map<String, dynamic>;
        expect(result.valid, expectMap['valid'] as bool);
        if (expectMap['valid'] == false) {
          expect(result.reason, expectMap['reason']);
        }
        return;
      }
      if (kind == 'revision') {
        final verdict = decideRevisionV1(
          appliedRevision: c['appliedRevision'] as int,
          incomingRevision: c['incomingRevision'] as int,
        );
        final expectMap = c['expect'] as Map<String, dynamic>;
        expect(verdict.apply, expectMap['apply'] as bool);
        if (expectMap['apply'] == false) {
          expect(verdict.decision, RevisionDecisionV1.rejectStale);
        }
        if (expectMap['discontinuity'] == true) {
          expect(verdict.discontinuity, isTrue);
        }
        return;
      }
      fail('unknown fixture kind $kind');
    });
  }
}
