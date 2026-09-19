import 'package:yinwei_player/update/app_version.dart';
import 'package:yinwei_player/update/release_manifest.dart';
import 'package:yinwei_player/update/update_channel.dart';

enum UpdateAction { none, offerManualInstall }

/// Channel + version selection. Never starts an installer.
class UpdateDecision {
  const UpdateDecision({
    required this.action,
    required this.reason,
    this.candidate,
  });

  final UpdateAction action;
  final String reason;
  final ReleaseArtifact? candidate;

  bool get updateAvailable =>
      action == UpdateAction.offerManualInstall && candidate != null;
}

abstract final class UpdatePolicy {
  static const autoInstallEnabled = false;

  static UpdateDecision select({
    required InstalledApp installed,
    required ReleaseManifest manifest,
  }) {
    if (manifest.schemaVersion != kReleaseManifestSchema) {
      return const UpdateDecision(
        action: UpdateAction.none,
        reason: 'unsupported_manifest_schema',
      );
    }
    if (manifest.platform != installed.platform) {
      return const UpdateDecision(
        action: UpdateAction.none,
        reason: 'platform_mismatch',
      );
    }

    final visible = installed.channel.visibleChannels;
    ReleaseArtifact? best;
    for (final release in manifest.releases) {
      if (!visible.contains(release.channel)) continue;
      if (release.platform != installed.platform) continue;
      if (release.version <= installed.version) continue;
      if (best == null || release.version > best.version) {
        best = release;
      }
    }
    if (best == null) {
      return const UpdateDecision(
        action: UpdateAction.none,
        reason: 'already_current',
      );
    }
    return UpdateDecision(
      action: UpdateAction.offerManualInstall,
      reason: 'newer_build_available',
      candidate: best,
    );
  }
}
