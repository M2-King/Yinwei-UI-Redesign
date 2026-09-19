import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/update/app_version.dart';
import 'package:yinwei_player/update/package_checksum.dart';
import 'package:yinwei_player/update/release_manifest.dart';
import 'package:yinwei_player/update/update_channel.dart';
import 'package:yinwei_player/update/update_coordinator.dart';
import 'package:yinwei_player/update/update_policy.dart';

void main() {
  test('version comparison treats stable as newer than an equal-core prerelease', () {
    expect(AppVersion.parse('0.1.1') > AppVersion.parse('0.1.0'), isTrue);
    expect(AppVersion.parse('0.1.0') > AppVersion.parse('0.1.0-beta.1'), isTrue);
    expect(AppVersion.parse('0.1.2-beta.1') > AppVersion.parse('0.1.1'), isTrue);
    expect(AppVersion.parse('0.1.2-beta.2') > AppVersion.parse('0.1.2-beta.1'), isTrue);
    expect(AppVersion.parse('0.1.0') == AppVersion.parse(kYinweiAppVersion), isTrue);
  });

  test('Stable does not see Beta; Beta prefers the newest visible build', () {
    final manifest = ReleaseManifest(
      platform: kWindowsX64Platform,
      releases: [
        ReleaseArtifact(
          version: AppVersion.parse('0.1.1'),
          channel: UpdateChannel.stable,
          platform: kWindowsX64Platform,
          fileName: 'yinwei_player-0.1.1-windows-x64.zip',
          sha256: 'aa' * 32,
          sizeBytes: 10,
        ),
        ReleaseArtifact(
          version: AppVersion.parse('0.1.2-beta.1'),
          channel: UpdateChannel.beta,
          platform: kWindowsX64Platform,
          fileName: 'yinwei_player-0.1.2-beta.1-windows-x64.zip',
          sha256: 'bb' * 32,
          sizeBytes: 10,
        ),
        ReleaseArtifact(
          version: AppVersion.parse('0.1.3-dev.1'),
          channel: UpdateChannel.developer,
          platform: kWindowsX64Platform,
          fileName: 'yinwei_player-0.1.3-dev.1-windows-x64.zip',
          sha256: 'cc' * 32,
          sizeBytes: 10,
        ),
      ],
    );
    final old = InstalledApp(
      version: AppVersion.parse('0.1.0'),
      channel: UpdateChannel.stable,
      platform: kWindowsX64Platform,
    );

    final stable = UpdatePolicy.select(installed: old, manifest: manifest);
    expect(stable.updateAvailable, isTrue);
    expect(stable.candidate!.version.toString(), '0.1.1');
    expect(stable.candidate!.channel, UpdateChannel.stable);

    final beta = UpdatePolicy.select(
      installed: InstalledApp(
        version: old.version,
        channel: UpdateChannel.beta,
        platform: kWindowsX64Platform,
      ),
      manifest: manifest,
    );
    expect(beta.candidate!.version.toString(), '0.1.2-beta.1');
    expect(beta.candidate!.channel, UpdateChannel.beta);

    final developer = UpdatePolicy.select(
      installed: InstalledApp(
        version: old.version,
        channel: UpdateChannel.developer,
        platform: kWindowsX64Platform,
      ),
      manifest: manifest,
    );
    expect(developer.candidate!.version.toString(), '0.1.3-dev.1');
  });

  test('Stable old build is not offered Beta or Developer', () {
    final manifest = ReleaseManifest(
      platform: kWindowsX64Platform,
      releases: [
        ReleaseArtifact(
          version: AppVersion.parse('0.1.0'),
          channel: UpdateChannel.stable,
          platform: kWindowsX64Platform,
          fileName: 'yinwei_player-0.1.0-windows-x64.zip',
          sha256: 'aa' * 32,
          sizeBytes: 10,
        ),
        ReleaseArtifact(
          version: AppVersion.parse('0.1.2-beta.1'),
          channel: UpdateChannel.beta,
          platform: kWindowsX64Platform,
          fileName: 'yinwei_player-0.1.2-beta.1-windows-x64.zip',
          sha256: 'bb' * 32,
          sizeBytes: 10,
        ),
        ReleaseArtifact(
          version: AppVersion.parse('0.1.3-dev.1'),
          channel: UpdateChannel.developer,
          platform: kWindowsX64Platform,
          fileName: 'yinwei_player-0.1.3-dev.1-windows-x64.zip',
          sha256: 'cc' * 32,
          sizeBytes: 10,
        ),
      ],
    );
    final stableOld = InstalledApp(
      version: AppVersion.parse('0.1.0'),
      channel: UpdateChannel.stable,
      platform: kWindowsX64Platform,
    );
    final stableDecision = UpdatePolicy.select(
      installed: stableOld,
      manifest: manifest,
    );
    expect(stableDecision.updateAvailable, isFalse);
    expect(stableDecision.candidate, isNull);

    final betaOld = InstalledApp(
      version: AppVersion.parse('0.1.0'),
      channel: UpdateChannel.beta,
      platform: kWindowsX64Platform,
    );
    final betaDecision = UpdatePolicy.select(
      installed: betaOld,
      manifest: manifest,
    );
    expect(betaDecision.updateAvailable, isTrue);
    expect(betaDecision.candidate!.version.toString(), '0.1.2-beta.1');
    expect(betaDecision.candidate!.channel, UpdateChannel.beta);
  });

  test('checksum must match before install is allowed; silent install is refused',
      () async {
    final dir = await Directory.systemTemp.createTemp('yinwei-update-');
    addTearDown(() => dir.delete(recursive: true));
    final package = File('${dir.path}/payload.bin');
    await package.writeAsBytes(utf8.encode('yinwei-update-payload'));
    final digest = await PackageChecksum.sha256File(package);
    expect(digest.length, 64);

    final coordinator = UpdateCoordinator();
    expect(coordinator.autoInstallEnabled, isFalse);
    final verified = await coordinator.verifyBeforeInstall(
      package: package,
      expectedSha256: digest,
    );
    expect(verified.path, package.path);

    await package.writeAsString('tampered');
    expect(
      () => coordinator.verifyBeforeInstall(
        package: package,
        expectedSha256: digest,
      ),
      throwsA(isA<ChecksumMismatch>()),
    );
    expect(
      () => coordinator.installSilently(package),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('local manifest JSON round-trips and offers a newer Windows build', () {
    final json = jsonDecode(_sampleManifest) as Map;
    final manifest = ReleaseManifest.fromJson(json);
    expect(manifest.schemaVersion, kReleaseManifestSchema);
    final decision = UpdateCoordinator().check(
      installed: InstalledApp.currentWindows(),
      manifest: manifest,
    );
    expect(decision.updateAvailable, isTrue);
    expect(decision.candidate!.version.toString(), '0.1.1');
    expect(decision.candidate!.platform, kWindowsX64Platform);
    expect(UpdatePolicy.autoInstallEnabled, isFalse);
  });

  test('updater sources stay outside audio and spatial authority', () async {
    final files = [
      'lib/update/app_version.dart',
      'lib/update/update_channel.dart',
      'lib/update/release_manifest.dart',
      'lib/update/update_policy.dart',
      'lib/update/package_checksum.dart',
      'lib/update/update_coordinator.dart',
    ];
    for (final path in files) {
      final src = await File(path).readAsString();
      expect(src.contains('EngineApi'), isFalse);
      expect(src.contains('SpatialSceneStore'), isFalse);
      expect(src.contains('yinwei_set_params'), isFalse);
      expect(src.contains('PlaybackTelemetryV1'), isFalse);
    }
  });
}

const _sampleManifest = '''
{
  "schemaVersion": 1,
  "platform": "windows-x64",
  "releases": [
    {
      "version": "0.1.1",
      "channel": "stable",
      "platform": "windows-x64",
      "fileName": "yinwei_player-0.1.1-windows-x64.zip",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "sizeBytes": 1
    }
  ]
}
''';
