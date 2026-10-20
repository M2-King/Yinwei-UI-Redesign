import 'dart:convert';

import 'package:flutter/services.dart';

/// The laptop sign-in "Remember me on this iPad" keeps.
class SavedSignIn {
  const SavedSignIn(
      {required this.entry, required this.username, required this.password});
  final String entry, username, password;

  String encode() =>
      jsonEncode({'v': 1, 'entry': entry, 'username': username, 'password': password});

  static SavedSignIn? decode(String? text) {
    if (text == null) return null;
    try {
      final m = jsonDecode(text);
      if (m is! Map || m['v'] != 1) return null;
      final entry = m['entry'], username = m['username'], password = m['password'];
      if (entry is! String || username is! String || password is! String) return null;
      if (entry.isEmpty || password.isEmpty) return null;
      return SavedSignIn(entry: entry, username: username, password: password);
    } catch (_) {
      return null;
    }
  }
}

abstract class SignInStore {
  Future<SavedSignIn?> load();
  Future<void> save(SavedSignIn value);
  Future<void> clear();
}

/// The iPad's Keychain, this device only (YinweiSignInKeychainChannel.swift).
class KeychainSignInStore implements SignInStore {
  KeychainSignInStore({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(name);
  static const name = 'dev.yinwei/sign_in_keychain';
  final MethodChannel _channel;

  @override
  Future<SavedSignIn?> load() async =>
      SavedSignIn.decode(await _channel.invokeMethod<String>('load'));

  @override
  Future<void> save(SavedSignIn value) =>
      _channel.invokeMethod<void>('save', value.encode());

  @override
  Future<void> clear() => _channel.invokeMethod<void>('clear');
}
