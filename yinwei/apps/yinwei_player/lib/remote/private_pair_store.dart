import 'dart:convert';

import 'package:flutter/services.dart';

import 'private_route.dart' show privateRouteAddress;

class PrivatePair {
  const PrivatePair(
      {required this.entry,
      required this.hostId,
      required this.origin,
      required this.id,
      required this.key});
  final String entry, hostId, id, key;
  final Uri origin;

  static Uri? parseOrigin(Object? value, {bool loopbackForTesting = false}) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'http' ||
        (uri.host != privateRouteAddress &&
            !(loopbackForTesting && uri.host == '127.0.0.1')) ||
        !uri.hasPort ||
        uri.port < 1024 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.isNotEmpty) {
      return null;
    }
    return uri;
  }

  String encode() => jsonEncode({
        'v': 1,
        'entry': entry,
        'hostId': hostId,
        'origin': origin.toString(),
        'id': id,
        'key': key
      });

  static PrivatePair? decode(String? text, {bool loopbackForTesting = false}) {
    try {
      if (text == null || text.length > 4096) return null;
      final value = jsonDecode(text);
      if (value is! Map ||
          value['v'] != 1 ||
          !['entry', 'hostId', 'id', 'key'].every((k) => value[k] is String)) {
        return null;
      }
      final origin =
          parseOrigin(value['origin'], loopbackForTesting: loopbackForTesting);
      if (origin == null ||
          (value['key'] as String).length != 43 ||
          (value['id'] as String).length > 128) {
        return null;
      }
      return PrivatePair(
          entry: value['entry'] as String,
          hostId: value['hostId'] as String,
          origin: origin,
          id: value['id'] as String,
          key: value['key'] as String);
    } catch (_) {
      return null;
    }
  }
}

abstract class PrivatePairStore {
  Future<PrivatePair?> load();
  Future<void> save(PrivatePair pair);
  Future<void> clear();
}

/// A separate, device-only Keychain item. Never stored in preferences, assets,
/// a WebView, the clipboard, diagnostics, or the saved public-origin cookie jar.
class KeychainPrivatePairStore implements PrivatePairStore {
  static const _channel = MethodChannel('dev.yinwei/sign_in_keychain');
  @override
  Future<PrivatePair?> load() async =>
      PrivatePair.decode(await _channel.invokeMethod<String>('loadPair'));
  @override
  Future<void> save(PrivatePair pair) =>
      _channel.invokeMethod<void>('savePair', pair.encode());
  @override
  Future<void> clear() => _channel.invokeMethod<void>('clearPair');
}
