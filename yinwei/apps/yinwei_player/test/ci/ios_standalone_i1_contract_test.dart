import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS local playback owns the audio session only when playback starts',
      () {
    final appDelegate = _read('ios/Runner/AppDelegate.swift');
    final audioSession = _read('ios/Runner/YinweiAudioSessionChannel.swift');

    expect(appDelegate, isNot(contains('mixWithOthers')));
    expect(appDelegate, isNot(contains('setActive(true)')));
    expect(audioSession, contains('case "activate"'));
    expect(
      audioSession,
      contains('setCategory(.playback, mode: .default, options: [])'),
    );
    expect(audioSession, contains('notifyOthersOnDeactivation'));
  });

  test('processed export can share only an existing app-container file', () {
    final source = _read('ios/Runner/YinweiDeveloperDiagnostics.swift');

    expect(source, contains('case "shareFile"'));
    expect(source, contains('NSHomeDirectory()'));
    expect(source, contains('fileExists(atPath: url.path)'));
    expect(source, contains('UIActivityViewController'));
  });

  test('Runner remains an iPad-capable native spatial_core target', () {
    final project = _read('ios/Runner.xcodeproj/project.pbxproj');

    expect(project, contains('TARGETED_DEVICE_FAMILY = "1,2";'));
    expect(project, contains('IPHONEOS_DEPLOYMENT_TARGET = 16.2;'));
    expect(project, contains('libspatial_core.xcframework in Frameworks'));
    expect(project, contains('"_yinwei_open"'));
    expect(project, contains('"_yinwei_play"'));
  });
}

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: path);
  return file.readAsStringSync();
}
