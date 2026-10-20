import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/private_pair_store.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('pair key uses a distinct device-only Keychain item', () async {
    const channel = MethodChannel('dev.yinwei/sign_in_keychain');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    String? value;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'savePair':
          value = call.arguments as String;
        case 'loadPair':
          return value;
        case 'clearPair':
          value = null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final store = KeychainPrivatePairStore();
    final pair = PrivatePair(
        entry: 'https://entry.example/',
        hostId: 'host',
        origin: Uri.parse('http://100.80.104.77:8443'),
        id: 'pair',
        key: remoteSecret());
    expect(await store.load(), isNull);
    await store.save(pair);
    expect((await store.load())!.key, pair.key);
    await store.clear();
    expect(await store.load(), isNull);
    expect(
        calls, ['loadPair', 'savePair', 'loadPair', 'clearPair', 'loadPair']);
    expect(
        PrivatePair.decode(
            pair.encode().replaceFirst('100.80.104.77', '192.168.0.1')),
        isNull);
    expect(PrivatePair.decode(pair.encode().replaceFirst(pair.key, 'short')),
        isNull);
  });
}
