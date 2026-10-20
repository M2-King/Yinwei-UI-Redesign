import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/state/engine_controller.dart';

class _ArrayEngine extends MockEngine {
  Completer<void>? gate;
  final counts = <int>[];
  final indices = <int>[];
  @override
  Future<void> setSpeakerCount(int n) async {
    counts.add(n);
    await gate?.future;
  }

  @override
  Future<void> setSpeaker(
      {required int index,
      required double azimuthDeg,
      required double elevationDeg,
      required double distanceM,
      required double gainDb,
      required bool mute,
      required int feed}) async {
    indices.add(index);
  }
}

void main() {
  testWidgets('local array edits retain their immediate UI and 32ms throttle',
      (tester) async {
    final engine = _ArrayEngine();
    final c = EngineController(engine: engine);
    addTearDown(c.dispose);
    await c.setArray(ArrayLayout.stereo2());
    expect(c.array.enabled, true);
    expect(engine.counts, isEmpty);
    await tester.pump(const Duration(milliseconds: 31));
    expect(engine.counts, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(engine.counts, [2]);
    expect(engine.indices, [0, 1]);
  });

  testWidgets(
      'remote commit waits for all native writes and cancels pending local write',
      (tester) async {
    final engine = _ArrayEngine();
    final c = EngineController(engine: engine);
    addTearDown(c.dispose);
    await c.setArray(ArrayLayout.stereo2());
    engine.gate = Completer<void>();
    var finished = false;
    final next = ArrayLayout.stereo2()..addSpeaker();
    final commit = c.setArrayAcknowledged(next)..then((_) => finished = true);
    await tester.pump();
    expect(finished, false);
    expect(engine.counts, [3]);
    await tester.pump(const Duration(milliseconds: 40));
    expect(engine.counts, [3]);
    engine.gate!.complete();
    await commit;
    expect(finished, true);
    expect(engine.indices, [0, 1, 2]);
  });

  testWidgets(
      'failed remote write propagates and restores the previous UI array',
      (tester) async {
    final engine = _ArrayEngine()..gate = Completer<void>();
    final c = EngineController(engine: engine);
    addTearDown(c.dispose);
    final result = c.setArrayAcknowledged(ArrayLayout.stereo2());
    final failed = expectLater(result, throwsStateError);
    await tester.pump();
    engine.gate!.completeError(StateError('write failed'));
    await failed;
    expect(c.array.enabled, false);
  });
}
