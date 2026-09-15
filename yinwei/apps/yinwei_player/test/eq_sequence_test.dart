import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/models/spatial_params.dart';

void main() {
  test('flat sequence is the default', () {
    final p = SpatialParams();
    expect(p.selectedEq, EqSequence.flat);
    expect(EqSequence.flat.matches(p.eqDb), isTrue);
  });

  test('vocal sequence boosts 1k and 3.5k', () {
    final p = SpatialParams()..applyEq(EqSequence.vocal);
    expect(p.eqDb[3], 2.5);
    expect(p.eqDb[4], 3.5);
    expect(p.eqDb[1], -2);
    expect(p.azimuthDeg, 90);
  });

  test('moving a band becomes custom', () {
    final p = SpatialParams()..applyEq(EqSequence.vocal);
    p.setEqBand(4, 6);
    expect(p.selectedEq, isNull);
    expect(p.eqDb[4], 6);
  });

  test('six factory sequences are distinct', () {
    final seen = <String>{};
    for (final s in EqSequence.mixerOrder) {
      seen.add(s.gains.map((g) => g.toStringAsFixed(1)).join(','));
    }
    expect(seen.length, 6);
  });
}
