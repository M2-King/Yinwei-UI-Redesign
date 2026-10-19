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

  /// The newer published build, or null (none, or the channel unreachable:
  /// an update check never bothers you with errors).
  Future<ReleaseArtifact?> check() async {
    if (!enabled) return null;
    try {
      final decision = await service.check(installed);
      return decision.updateAvailable ? decision.candidate : null;
    } catch (_) {
      return null;
    }
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
    // 0.1.3-dev.42 → "42"; a plain version shows as it is.
    final build = release.version.prerelease?.split('.').last ??
        release.version.toString();
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

  static Future<bool> _openInSafari(Uri url) async =>
      await const MethodChannel(ReplayKitAudioProbe.channelName)
          .invokeMethod<bool>('openUpdatePackage', {'url': url.toString()}) ==
      true;
}
