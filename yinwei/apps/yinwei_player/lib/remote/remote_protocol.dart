import 'dart:math';
import 'dart:convert';

String remoteSecret([int bytes = 32]) => base64UrlEncode(
      List<int>.generate(bytes, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');

class RemoteFailure implements Exception {
  const RemoteFailure(this.code, {this.httpStatus = 409});
  final String code;
  final int httpStatus;
  @override
  String toString() => code;
}

num remoteNumber(Map<String, dynamic> data, String key, num min, num max) {
  final value = data[key];
  if (value is! num || !value.isFinite || value < min || value > max) {
    throw const RemoteFailure('invalid_payload', httpStatus: 400);
  }
  return value;
}
