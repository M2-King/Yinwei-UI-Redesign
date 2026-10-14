import 'dart:convert';
import 'dart:io';

import 'package:yinwei_player/update/release_manifest.dart';
import 'package:yinwei_player/update/update_channel.dart';
import 'package:yinwei_player/update/update_coordinator.dart';
import 'package:yinwei_player/update/update_policy.dart';

/// On-demand manifest lookup. It never downloads or installs a package.
class UpdateCheckService {
  UpdateCheckService({Uri? baseUri})
      : baseUri = baseUri ?? Uri.parse(kYinweiUpdateChannelBase);

  final Uri baseUri;

  Uri manifestUriFor(String platform) =>
      baseUri.replace(path: '${baseUri.path}/v1/$platform/manifest.json');

  Future<UpdateDecision> check(InstalledApp installed) async {
    final endpoint = manifestUriFor(installed.platform);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request =
          await client.getUrl(endpoint).timeout(const Duration(seconds: 8));
      final response =
          await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('Update server returned ${response.statusCode}',
            uri: endpoint);
      }
      final chunks = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        chunks.addAll(chunk);
        if (chunks.length > 1024 * 1024) {
          throw const FormatException('update manifest is too large');
        }
      }
      final decoded = jsonDecode(utf8.decode(chunks));
      if (decoded is! Map) {
        throw const FormatException('update manifest must be a JSON object');
      }
      final manifest = ReleaseManifest.fromJson(decoded);
      final decision = const UpdateCoordinator().check(
        installed: installed,
        manifest: manifest,
      );
      if (decision.updateAvailable) {
        packageUriFor(decision.candidate!);
      }
      return decision;
    } finally {
      client.close(force: true);
    }
  }

  /// Only offer a package published by this channel for its stated platform.
  Uri packageUriFor(ReleaseArtifact artifact) {
    final uri = artifact.uri;
    final expectedPrefix = '${baseUri.path}/packages/${artifact.platform}/';
    if (uri == null ||
        uri.scheme != baseUri.scheme ||
        uri.host != baseUri.host ||
        uri.port != baseUri.port ||
        !uri.path.startsWith(expectedPrefix) ||
        uri.pathSegments.last != artifact.fileName ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(artifact.sha256) ||
        artifact.sizeBytes <= 0) {
      throw const FormatException('update package metadata is invalid');
    }
    return uri;
  }
}
