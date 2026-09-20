import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stable unsigned IPA workflow stays on Xcode 16.4', () {
    final yaml = File(_codemagicPath).readAsStringSync();
    final stable = _workflow(yaml, 'ios-unsigned-ipa');
    final experimental = _workflow(yaml, 'ios-27-live-transfer');

    expect(stable, isNotEmpty);
    expect(experimental, isNotEmpty);
    expect(stable, contains('xcode: 16.4'));
    expect(RegExp(r'^\s+xcode:\s+edge\s*$', multiLine: true).hasMatch(stable), isFalse);
    expect(stable, contains('Yinwei-unsigned.ipa'));
    expect(stable, isNot(contains('yinwei-ios27-live-transfer')));
  });

  test('ios-27-live-transfer requests edge Xcode and fails below 27', () {
    final yaml = File(_codemagicPath).readAsStringSync();
    final experimental = _workflow(yaml, 'ios-27-live-transfer');

    expect(experimental, contains('xcode: edge'));
    expect(experimental, isNot(contains('xcode: 16.4')));
    expect(experimental, contains('verify_ios27_toolchain.sh'));
    expect(experimental, contains('yinwei-ios27-live-transfer-'));
    expect(experimental, contains('environment.txt'));
    expect(experimental, contains('source-diagnostics-manifest'));
    expect(experimental, contains('YINWEI_PHASE=7D1'));
    expect(experimental, isNot(contains('Yinwei-unsigned.ipa')));
    expect(experimental.toLowerCase(), isNot(contains('xcode 16.4')));
  });

  test('toolchain gate script refuses Xcode or SDK major below 27', () {
    final script = File(_toolchainPath).readAsStringSync();
    expect(script, contains('sw_vers'));
    expect(script, contains('xcodebuild -version'));
    expect(script, contains('xcodebuild -showsdks'));
    expect(script, contains('swift --version'));
    expect(script, contains('flutter --version'));
    expect(script, contains('rustc --version'));
    expect(script, contains('-lt 27'));
    expect(script, contains('Refusing to fall back to Xcode 16.4'));
    expect(script, isNot(contains('DEVELOPER_DIR=/Applications/Xcode-16.4.app')));
  });
}

final _codemagicPath = _repoFile('codemagic.yaml');
final _toolchainPath = _repoFile('yinwei/tools/verify_ios27_toolchain.sh');

String _repoFile(String relative) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = File('${dir.path}${Platform.pathSeparator}$relative');
    if (candidate.existsSync()) return candidate.path;
    dir = dir.parent;
  }
  return File(relative).absolute.path;
}

String _workflow(String yaml, String id) {
  final pattern = RegExp('^  $id:\\s*\$', multiLine: true);
  final match = pattern.firstMatch(yaml);
  if (match == null) return '';
  final start = match.start;
  final rest = yaml.substring(start + 2);
  final next = RegExp(r'^  [A-Za-z0-9_-]+:\s*$', multiLine: true).firstMatch(rest);
  if (next == null) return yaml.substring(start);
  return yaml.substring(start, start + 2 + next.start);
}
