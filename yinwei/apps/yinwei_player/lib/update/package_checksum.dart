import 'dart:io';

import 'package:crypto/crypto.dart';

/// SHA-256 of a local package. Required before any install is allowed.
abstract final class PackageChecksum {
  static Future<String> sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static Future<bool> matches(File file, String expectedSha256) async {
    final actual = await sha256File(file);
    return actual.toLowerCase() == expectedSha256.trim().toLowerCase();
  }
}

class ChecksumMismatch implements Exception {
  ChecksumMismatch({required this.expected, required this.actual, required this.path});

  final String expected;
  final String actual;
  final String path;

  @override
  String toString() =>
      'checksum mismatch for $path\n  expected: $expected\n  actual:   $actual';
}
