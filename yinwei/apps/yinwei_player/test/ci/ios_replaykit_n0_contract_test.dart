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
      project.indexOf(
          'D8A000010000000000000301 /* YinweiBroadcastUpload */ = {'),
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

  test('host and extension share a deterministic provisioned App Group', () {
    final host = _read('ios/Runner/YinweiReplayKitProbe.swift');
    final extension = _read('ios/YinweiBroadcastUpload/SampleHandler.swift');

    for (final source in [host, extension]) {
      expect(source, contains('embedded'));
      expect(
        source,
        contains('<key>com.apple.security.application-groups</key>'),
      );
      expect(source, contains('groups.sorted().first(where: canOpen)'));
      expect(source, contains('forSecurityApplicationGroupIdentifier'));
      expect(source, contains('group.dev.yinwei.remote.capture'));
    }
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
