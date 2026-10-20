import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';
import 'package:yinwei_player/update/release_manifest.dart';
import 'package:yinwei_player/update/update_check_service.dart';

/// iPad updates: asks the Yinwei update channel (developer, `ios-arm64`)
/// whether a newer iPad build was published, and offers it. Download opens
/// the package in Safari, which hands it to the signing app (AllInSign);
/// iPadOS doesn't let the app install it itself.
class IosUpdateNotice {
  IosUpdateNotice({
    UpdateCheckService? service,
    InstalledApp? installed,
    Future<bool> Function(Uri url)? open,
  })  : service = service ?? UpdateCheckService(),
        installed = installed ?? InstalledApp.currentIos(),
        _open = open ?? _openInSafari;

  final UpdateCheckService service;
  final InstalledApp installed;
  final Future<bool> Function(Uri url) _open;

  /// A local build (no CI run number) never looks for developer builds.
  bool get enabled => installed.version.prerelease != null;

  /// This build's number as people see it ("50"), or the plain version.
  String get build => _buildOf(installed.version.prerelease, installed.version);

  /// The automatic check: the newer published build, or null (none, or the
  /// channel unreachable: it never bothers you with errors).
  Future<ReleaseArtifact?> check() async {
    final result = await checkNow();
    return result.outcome == IosUpdateOutcome.available ? result.release : null;
  }

  /// The manual check ("Check for updates"): every outcome is reported.
  Future<IosUpdateResult> checkNow() async {
    if (!enabled) return const IosUpdateResult(IosUpdateOutcome.localBuild);
    try {
      final decision = await service.check(installed);
      return decision.updateAvailable
          ? IosUpdateResult(IosUpdateOutcome.available, decision.candidate)
          : const IosUpdateResult(IosUpdateOutcome.upToDate);
    } catch (_) {
      return const IosUpdateResult(IosUpdateOutcome.unreachable);
    }
  }

  /// Runs [checkNow] and tells you the result on [context]'s screen.
  Future<void> checkAndReport(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(
        content: Text('Checking for updates…'),
        duration: Duration(seconds: 8)));
    final result = await checkNow();
    messenger.hideCurrentSnackBar();
    if (!context.mounted) return;
    final release = result.release;
    if (release != null) {
      showBanner(context, release);
      return;
    }
    messenger.showSnackBar(SnackBar(
      key: const Key('ios-update-result'),
      content: Text(switch (result.outcome) {
        IosUpdateOutcome.upToDate => 'You have the newest build ($build).',
        IosUpdateOutcome.unreachable =>
          'Could not reach the update server. Check the internet and try again.',
        _ =>
          'This is a local build ($build); updates come to builds from GitHub.',
      }),
    ));
  }

  Future<bool> download(ReleaseArtifact release) async {
    try {
      return await _open(service.packageUriFor(release));
    } catch (_) {
      return false;
    }
  }

  /// Shows a banner at the top of [context]'s screen for [release].
  void showBanner(BuildContext context, ReleaseArtifact release) {
    final messenger = ScaffoldMessenger.of(context);
    final build = _buildOf(release.version.prerelease, release.version);
    messenger.showMaterialBanner(MaterialBanner(
      key: const Key('ios-update-banner'),
      leading: const Icon(Icons.system_update_alt),
      content: Text(release.notes.isEmpty
          ? 'Yinwei build $build is ready. Download it, then install it with your signing app.'
          : 'Yinwei build $build is ready: ${release.notes}'),
      actions: [
        TextButton(
          onPressed: messenger.hideCurrentMaterialBanner,
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () async {
            messenger.hideCurrentMaterialBanner();
            if (!await download(release)) {
              messenger.showSnackBar(const SnackBar(
                  content:
                      Text('Could not open the download. Try again later.')));
            }
          },
          child: const Text('Download'),
        ),
      ],
    ));
  }

  // 0.1.3-dev.42 → "42"; a plain version shows as it is.
  static String _buildOf(String? prerelease, Object version) =>
      prerelease?.split('.').last ?? version.toString();

  static Future<bool> _openInSafari(Uri url) async =>
      await const MethodChannel(ReplayKitAudioProbe.channelName)
          .invokeMethod<bool>('openUpdatePackage', {'url': url.toString()}) ==
      true;
}

enum IosUpdateOutcome { available, upToDate, unreachable, localBuild }

class IosUpdateResult {
  const IosUpdateResult(this.outcome, [this.release]);
  final IosUpdateOutcome outcome;

  /// The newer build when [outcome] is available.
  final ReleaseArtifact? release;
}
