import 'package:yinwei_player/update/app_version.dart';
import 'package:yinwei_player/update/update_channel.dart';

/// One packaged build advertised by a release manifest.
class ReleaseArtifact {
  const ReleaseArtifact({
    required this.version,
    required this.channel,
    required this.platform,
    required this.fileName,
    required this.sha256,
    required this.sizeBytes,
    this.uri,
    this.notes = '',
  });

  final AppVersion version;
  final UpdateChannel channel;
  final String platform;
  final String fileName;
  final String sha256;
  final int sizeBytes;
  final Uri? uri;
  final String notes;

  Map<String, Object?> toJson() => {
        'version': version.toString(),
        'channel': channel.wireName,
        'platform': platform,
        'fileName': fileName,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        if (uri != null) 'uri': uri.toString(),
        if (notes.isNotEmpty) 'notes': notes,
      };

  factory ReleaseArtifact.fromJson(Map json) {
    return ReleaseArtifact(
      version: AppVersion.parse('${json['version']}'),
      channel: UpdateChannelWire.parse('${json['channel']}'),
      platform: '${json['platform']}',
      fileName: '${json['fileName']}',
      sha256: '${json['sha256']}'.toLowerCase(),
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      uri: json['uri'] == null ? null : Uri.parse('${json['uri']}'),
      notes: '${json['notes'] ?? ''}',
    );
  }
}

class InstalledApp {
  const InstalledApp({
    required this.version,
    required this.channel,
    required this.platform,
  });

  final AppVersion version;
  final UpdateChannel channel;
  final String platform;

  static InstalledApp currentWindows({
    UpdateChannel channel = UpdateChannel.stable,
  }) {
    return InstalledApp(
      version: AppVersion.parse(kYinweiAppVersion),
      channel: channel,
      platform: kWindowsX64Platform,
    );
  }
}

const String kWindowsX64Platform = 'windows-x64';
const int kReleaseManifestSchema = 1;

/// Local/test (or hosted) catalog of latest builds per channel.
class ReleaseManifest {
  const ReleaseManifest({
    required this.platform,
    required this.releases,
    this.schemaVersion = kReleaseManifestSchema,
    this.generatedAt,
  });

  final int schemaVersion;
  final String platform;
  final DateTime? generatedAt;
  final List<ReleaseArtifact> releases;

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'platform': platform,
        if (generatedAt != null) 'generatedAt': generatedAt!.toIso8601String(),
        'releases': releases.map((r) => r.toJson()).toList(),
      };

  factory ReleaseManifest.fromJson(Map json) {
    final raw = json['releases'];
    if (raw is! List) {
      throw const FormatException('release manifest missing releases[]');
    }
    return ReleaseManifest(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 0,
      platform: '${json['platform']}',
      generatedAt: json['generatedAt'] == null
          ? null
          : DateTime.parse('${json['generatedAt']}'),
      releases: raw
          .whereType<Map>()
          .map(ReleaseArtifact.fromJson)
          .toList(growable: false),
    );
  }

  List<ReleaseArtifact> forChannel(UpdateChannel channel) {
    return releases.where((r) => r.channel == channel).toList(growable: false);
  }
}
