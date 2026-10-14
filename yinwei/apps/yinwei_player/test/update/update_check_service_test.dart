import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/update/app_version.dart';
import 'package:yinwei_player/update/release_manifest.dart';
import 'package:yinwei_player/update/update_channel.dart';
import 'package:yinwei_player/update/update_check_service.dart';

void main() {
  test('fetches a Windows stable manifest and offers 0.1.1 to 0.1.0', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = Uri.parse(
      'http://127.0.0.1:${server.port}/yinwei/updates',
    );
    server.listen((request) async {
      expect(request.uri.path, '/yinwei/updates/v1/windows-x64/manifest.json');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'schemaVersion': 1,
        'platform': 'windows-x64',
        'releases': [
          {
            'version': '0.1.1',
            'channel': 'stable',
            'platform': 'windows-x64',
            'fileName': 'yinwei_player-0.1.1-windows-x64.zip',
            'sha256':
                'e68a72898e10d0e142092185ff29b4d7fee7a4a1d414ef6fb2b396a1414539bb',
            'sizeBytes': 14762557,
            'uri':
                '$base/packages/windows-x64/yinwei_player-0.1.1-windows-x64.zip',
          },
        ],
      }));
      await request.response.close();
    });

    final service = UpdateCheckService(baseUri: base);
    final decision = await service.check(const InstalledApp(
      version: AppVersion(0, 1, 0),
      channel: UpdateChannel.stable,
      platform: kWindowsX64Platform,
    ));
    expect(decision.updateAvailable, isTrue);
    expect(decision.candidate!.version, AppVersion.parse('0.1.1'));
    expect(decision.candidate!.channel, UpdateChannel.stable);
    expect(service.packageUriFor(decision.candidate!).host, '127.0.0.1');
  });

  test('rejects a package URL outside the configured update channel', () {
    final service = UpdateCheckService();
    final artifact = ReleaseArtifact(
      version: AppVersion.parse('0.1.1'),
      channel: UpdateChannel.stable,
      platform: kWindowsX64Platform,
      fileName: 'yinwei_player-0.1.1-windows-x64.zip',
      sha256: 'a' * 64,
      sizeBytes: 14762557,
      uri: Uri.parse('https://other.example/package.zip'),
    );
    expect(() => service.packageUriFor(artifact), throwsFormatException);
  });

  test('reports an unavailable manifest instead of offering an update',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    final service = UpdateCheckService(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/yinwei/updates'),
    );
    await expectLater(
      service.check(InstalledApp.currentWindows()),
      throwsA(isA<HttpException>()),
    );
  });
}
