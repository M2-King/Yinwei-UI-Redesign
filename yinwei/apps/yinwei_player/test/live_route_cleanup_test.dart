import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/live_route_cleanup.dart';

void main() {
  test('cleanup waits for routing, stops live, then restores the route',
      () async {
    final pending = Completer<void>();
    final events = <String>[];
    final cleanup = cleanupLiveRoute(
      pendingRoute: pending.future,
      stop: () async => events.add('stop'),
      restore: () async => events.add('restore'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    pending.complete();
    await cleanup;
    expect(events, ['stop', 'restore']);
  });

  test('stop failure cannot skip restoration', () async {
    var restored = false;
    final cleanup = cleanupLiveRoute(
      pendingRoute: Future<void>.value(),
      stop: () async => throw StateError('stop failed'),
      restore: () async => restored = true,
    );
    await expectLater(cleanup, throwsStateError);
    expect(restored, isTrue);
  });

  test('failed pending route cannot skip stopping or restoration', () async {
    final events = <String>[];
    await expectLater(
      cleanupLiveRoute(
        pendingRoute: Future<void>.error(StateError('route failed')),
        stop: () async => events.add('stop'),
        restore: () async => events.add('restore'),
      ),
      throwsStateError,
    );
    expect(events, ['stop', 'restore']);
  });
}
