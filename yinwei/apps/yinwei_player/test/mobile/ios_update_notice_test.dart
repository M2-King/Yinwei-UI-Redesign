import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/mobile/ios_update_notice.dart';
import 'package:yinwei_player/update/app_version.dart';
import 'package:yinwei_player/update/release_manifest.dart';
import 'package:yinwei_player/update/update_channel.dart';
import 'package:yinwei_player/update/update_check_service.dart';
import 'package:yinwei_player/update/update_policy.dart';

const base = 'https://49.235.107.48/yinwei/updates';

ReleaseArtifact release({int build = 43, String? url}) => ReleaseArtifact(
      version: AppVersion.parse('$kYinweiAppVersion-dev.$build'),
      channel: UpdateChannel.developer,
      platform: kIosArm64Platform,
      fileName: 'Yinwei-iOS-$kYinweiAppVersion-dev.$build.ipa',
      sha256: 'a' * 64,
      sizeBytes: 10798750,
      uri: Uri.parse(url ??
          '$base/packages/ios-arm64/Yinwei-iOS-$kYinweiAppVersion-dev.$build.ipa'),
    );

/// The update channel's answer, without the network.
class FakeService extends UpdateCheckService {
  FakeService(this.answer);
  final Future<UpdateDecision> Function(InstalledApp) answer;
  final asked = <InstalledApp>[];

  @override
  Future<UpdateDecision> check(InstalledApp installed) {
    asked.add(installed);
    return answer(installed);
  }
}

UpdateDecision offer(ReleaseArtifact r) => UpdateDecision(
    action: UpdateAction.offerManualInstall, reason: 'newer', candidate: r);

void main() {
  late List<Uri> opened;
  Future<bool> open(Uri url) async {
    opened.add(url);
    return true;
  }

  setUp(() => opened = []);

  test('each CI build is <app version>-dev.<run> on the developer channel', () {
    final ci = InstalledApp.currentIos(build: 42);
    expect(ci.version.toString(), '$kYinweiAppVersion-dev.42');
    expect(ci.channel, UpdateChannel.developer);
    expect(ci.platform, 'ios-arm64');
    expect(InstalledApp.currentIos(build: 0).version.toString(),
        kYinweiAppVersion);
    expect(AppVersion.parse('0.1.3-dev.100') > AppVersion.parse('0.1.3-dev.99'),
        isTrue,
        reason: 'run numbers compare as numbers');
  });

  test('a local build never asks the channel', () async {
    final service = FakeService((_) async => offer(release()));
    final notice = IosUpdateNotice(
        service: service, installed: InstalledApp.currentIos(build: 0));
    expect(notice.enabled, isFalse);
    expect(await notice.check(), isNull);
    expect(service.asked, isEmpty);
  });

  test('a newer build is offered; none, or an unreachable channel, is quiet',
      () async {
    var answer = offer(release());
    final service = FakeService((_) async => answer);
    final notice = IosUpdateNotice(
        service: service, installed: InstalledApp.currentIos(build: 42));
    expect((await notice.check())!.version.toString(), '0.1.3-dev.43');
    answer = const UpdateDecision(action: UpdateAction.none, reason: 'current');
    expect(await notice.check(), isNull);
    final offline = IosUpdateNotice(
        service: FakeService((_) async => throw const HttpExceptionStub()),
        installed: InstalledApp.currentIos(build: 42));
    expect(await offline.check(), isNull);
  });

  test('Download opens only a package published by the channel', () async {
    final notice = IosUpdateNotice(
        service: UpdateCheckService(),
        installed: InstalledApp.currentIos(build: 42),
        open: open);
    expect(await notice.download(release()), isTrue);
    expect(opened.single.toString(),
        '$base/packages/ios-arm64/Yinwei-iOS-0.1.3-dev.43.ipa');
    expect(await notice.download(release(url: 'https://evil.example/x.ipa')),
        isFalse);
    expect(opened.length, 1, reason: 'a foreign link is never opened');
  });

  testWidgets('the banner offers Download and Later', (tester) async {
    final notice = IosUpdateNotice(
        service: UpdateCheckService(),
        installed: InstalledApp.currentIos(build: 42),
        open: open);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => notice.showBanner(context, release()),
            child: const Text('show'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ios-update-banner')), findsOneWidget);
    expect(find.textContaining('Yinwei build 43 is ready'), findsOneWidget);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(find.byKey(const Key('ios-update-banner')), findsNothing);
  });
}

class HttpExceptionStub implements Exception {
  const HttpExceptionStub();
}
