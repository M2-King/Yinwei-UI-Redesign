import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Runner embeds an isolated ReplayKit upload extension', () {
    final project = _read('ios/Runner.xcodeproj/project.pbxproj');
    final info = _read('ios/YinweiBroadcastUpload/Info.plist');
    final appEntitlements = _read('ios/Runner/Runner.entitlements');
    final extensionEntitlements =
        _read('ios/YinweiBroadcastUpload/YinweiBroadcastUpload.entitlements');

    expect(project,
        contains('YinweiBroadcastUpload.appex in Embed App Extensions'));
    expect(project, contains('com.apple.product-type.app-extension'));
    expect(
      project,
      contains('dev.yinwei.yinweiPlayer.BroadcastUpload'),
    );
    expect(info, contains('com.apple.broadcast-services-upload'));
    expect(info, contains('\$(PRODUCT_MODULE_NAME).SampleHandler'));
    expect(appEntitlements, contains('group.dev.yinwei.remote.capture'));
    expect(extensionEntitlements, contains('group.dev.yinwei.remote.capture'));

    final runnerTarget = project.substring(
      project.indexOf('97C146ED1CF9000F007C117D /* Runner */ = {'),
      project
          .indexOf('D8A000010000000000000301 /* YinweiBroadcastUpload */ = {'),
    );
    expect(
      runnerTarget.indexOf('Embed App Extensions'),
      lessThan(runnerTarget.indexOf('Thin Binary')),
      reason: 'Xcode creates a Runner dependency cycle when Flutter Thin '
          'Binary runs before the ReplayKit extension copy phase.',
    );
  });

  test('N0 extension accepts app audio and rejects media persistence paths',
      () {
    final source = _read('ios/YinweiBroadcastUpload/SampleHandler.swift');

    expect(source, contains('case .audioApp:'));
    expect(source, contains('case .audioMic:'));
    expect(source, contains('telemetry.ignoreMicrophone()'));
    expect(source, contains('case .video:'));
    expect(source, contains('telemetry.discardVideo()'));
    expect(source, contains('maximumScalarSamples = 9_600'));
    expect(source, contains('flushInterval = 0.25'));
    expect(source, isNot(contains('URLSession')));
    expect(source, isNot(contains('FileHandle')));
    expect(source, isNot(contains('AVAssetWriter')));
    expect(source, isNot(contains('write(to:')));
  });

  test('host requires an explicit Apple broadcast-picker tap', () {
    final source = _read('ios/Runner/YinweiReplayKitProbe.swift');

    expect(source, contains('RPSystemBroadcastPickerView'));
    expect(source, contains('showsMicrophoneButton = false'));
    expect(source, contains('preferredExtension'));
    expect(source, contains('builtInPlugInsURL'));
    expect(source, contains('Tap the blue button to start'));
    expect(source, contains('playReturnTone'));
    expect(source, contains('997'));
    expect(source, contains('1499'));
    expect(source, isNot(contains('sendActions(for:')));
    expect(source, isNot(contains('subviews.first')));
  });

  test(
      'both targets compile the same signed and container-validated group resolver',
      () {
    final shared = _read('ios/Shared/YinweiCaptureSupport.swift');
    final project = _read('ios/Runner.xcodeproj/project.pbxproj');
    for (final path in [
      'ios/Runner/YinweiReplayKitProbe.swift',
      'ios/YinweiBroadcastUpload/SampleHandler.swift'
    ]) {
      final source = _read(path);
      expect(source, contains('YinweiCaptureGroup.current'));
      expect(source, isNot(contains('group.dev.yinwei.remote.capture')));
    }
    expect(shared, contains('bundle.executableURL'));
    expect(shared, contains('.sorted().first(where: canOpen)'));
    expect(shared, contains('forSecurityApplicationGroupIdentifier'));
    expect(
        project,
        contains(
            'D8A000020000000000000201 /* YinweiCaptureSupport.swift in Sources */,'));
    expect(
        project,
        contains(
            'D8A000020000000000000202 /* YinweiCaptureSupport.swift in Sources */,'));
  });

  test('sample-buffer capture and background playback are declared', () {
    expect(_read('ios/YinweiBroadcastUpload/Info.plist'),
        contains('<key>RPBroadcastProcessMode</key>'));
    expect(_read('ios/YinweiBroadcastUpload/Info.plist'),
        contains('RPBroadcastProcessModeSampleBuffer'));
    expect(_read('ios/Runner/Info.plist'),
        contains('<key>UIBackgroundModes</key>'));
    expect(_read('ios/Runner/Info.plist'), contains('<string>audio</string>'));
  });

  test('unsigned CI ad-hoc signs both bundles for Xcode validation', () {
    final script = _read('../../tools/xcodebuild_ios_unsigned.sh');

    expect(script, contains('CODE_SIGNING_ALLOWED=YES'));
    expect(script, contains('CODE_SIGNING_REQUIRED=NO'));
    expect(script, contains('CODE_SIGN_IDENTITY=-'));
    expect(script, contains('AD_HOC_CODE_SIGNING_ALLOWED=YES'));
  });
}

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: path);
  return file.readAsStringSync();
}
