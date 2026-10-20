import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/saved_sign_in.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('round trip, and anything malformed reads as nothing saved', () {
    const value = SavedSignIn(
        entry: 'https://entry.example/', username: 'owner', password: r'p"w\x');
    final back = SavedSignIn.decode(value.encode())!;
    expect([back.entry, back.username, back.password],
        ['https://entry.example/', 'owner', r'p"w\x']);
    for (final bad in [
      null,
      '',
      'not json',
      '[]',
      '{"v":2,"entry":"e","username":"u","password":"p"}',
      '{"v":1,"entry":"","username":"u","password":"p"}',
      '{"v":1,"entry":"e","username":"u","password":""}',
      '{"v":1,"entry":"e","username":3,"password":"p"}',
    ]) {
      expect(SavedSignIn.decode(bad), isNull, reason: '$bad');
    }
  });

  test('the Keychain store speaks the native channel', () async {
    const channel = MethodChannel(KeychainSignInStore.name);
    String? kept;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'save':
          kept = call.arguments as String;
        case 'clear':
          kept = null;
        case 'load':
          return kept;
      }
      return null;
    });
    final store = KeychainSignInStore();
    expect(await store.load(), isNull);
    await store.save(const SavedSignIn(
        entry: 'https://entry.example/', username: 'owner', password: 'pw'));
    expect((await store.load())!.password, 'pw');
    await store.clear();
    expect(await store.load(), isNull);
    expect(calls, ['load', 'save', 'load', 'clear', 'load']);
  });
}
