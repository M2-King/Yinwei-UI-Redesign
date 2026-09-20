import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/update/app_version.dart';
import 'package:yinwei_player/update/package_checksum.dart';
import 'package:yinwei_player/update/release_manifest.dart';
import 'package:yinwei_player/update/update_channel.dart';
import 'package:yinwei_player/update/update_coordinator.dart';

/// Explicit packaging/update integration. Missing dist artifacts fail.
void main() {
  const zipName = 'yinwei_player-0.1.1-windows-x64.zip';
  final zip = File('dist/windows/$zipName');
  final manifestFile = File('dist/windows/local-release-manifest.json');

  test(
    'Windows update-test zip exists with spatial_core.dll and matching SHA-256',
    () async {
    expect(
      zip.existsSync(),
      isTrue,
      reason:
          'Expected $zipName. Run flutter build windows --release then tool/package_windows_release.ps1',
    );
    expect(
      manifestFile.existsSync(),
      isTrue,
      reason: 'Expected dist/windows/local-release-manifest.json',
    );
    final listed = await Process.run('tar', ['-tf', zip.path]);
    expect(listed.exitCode, 0, reason: listed.stderr.toString());
    final names = listed.stdout.toString();
    expect(names.contains('yinwei_player.exe'), isTrue);
    expect(names.contains('spatial_core.dll'), isTrue);
    expect(names.contains('flutter_windows.dll'), isTrue);

    final manifest = ReleaseManifest.fromJson(
      jsonDecode(await manifestFile.readAsString()) as Map,
    );
    final stable = manifest.forChannel(UpdateChannel.stable).single;
    expect(stable.fileName, zipName);
    final digest = await PackageChecksum.sha256File(zip);
    expect(digest, stable.sha256);

    final coordinator = UpdateCoordinator();
    await coordinator.verifyBeforeInstall(
      package: zip,
      expectedSha256: stable.sha256,
    );
    final offer = coordinator.check(
      installed: InstalledApp.currentWindows(),
      manifest: manifest,
    );
    expect(offer.updateAvailable, isTrue);
    expect(offer.candidate!.version > AppVersion.parse(kYinweiAppVersion), isTrue);
    expect(coordinator.autoInstallEnabled, isFalse);
    expect(
      () => coordinator.installSilently(zip),
      throwsA(isA<UnsupportedError>()),
    );
    },
    skip: !Platform.isWindows,
  );
}
