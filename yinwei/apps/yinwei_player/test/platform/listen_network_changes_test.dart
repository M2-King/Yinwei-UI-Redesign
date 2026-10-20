import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/listen_network_changes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('path observation is lazy, wakes recovery, and stops on cancellation',
      () async {
    const channel = MethodChannel('dev.yinwei/listen_network');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final changes = listenNetworkChanges();
    expect(calls, isEmpty);
    final changed = Completer<void>();
    final subscription = changes.listen((_) => changed.complete());
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['watch']);
    await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('changed')),
        (_) {});
    await changed.future;
    await subscription.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['watch', 'unwatch']);
  });
}
