import 'dart:io';

import 'package:yinwei_player/update/package_checksum.dart';
import 'package:yinwei_player/update/release_manifest.dart';
import 'package:yinwei_player/update/update_policy.dart';

/// Local update checks. Completely outside playback and scene authority.
///
/// Silent auto-install is intentionally unimplemented.
class UpdateCoordinator {
  const UpdateCoordinator();

  bool get autoInstallEnabled => UpdatePolicy.autoInstallEnabled;

  UpdateDecision check({
    required InstalledApp installed,
    required ReleaseManifest manifest,
  }) {
    return UpdatePolicy.select(installed: installed, manifest: manifest);
  }

  /// Verify the downloaded/local package before any install step.
  Future<File> verifyBeforeInstall({
    required File package,
    required String expectedSha256,
  }) async {
    if (!await package.exists()) {
      throw FileSystemException('update package missing', package.path);
    }
    final actual = await PackageChecksum.sha256File(package);
    if (actual.toLowerCase() != expectedSha256.trim().toLowerCase()) {
      throw ChecksumMismatch(
        expected: expectedSha256.toLowerCase(),
        actual: actual,
        path: package.path,
      );
    }
    return package;
  }

  /// Explicit user confirmation is required. This never launches an installer.
  Never installSilently(File package) {
    throw UnsupportedError(
      'silent auto-install is disabled; verified package is at ${package.path}',
    );
  }
}
