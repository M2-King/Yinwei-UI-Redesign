import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/update/app_version.dart';
import 'package:yinwei_player/update/release_manifest.dart';
import 'package:yinwei_player/update/update_channel.dart';
import 'package:yinwei_player/update/update_check_service.dart';
import 'package:yinwei_player/update/update_policy.dart';
import 'package:yinwei_player/widgets/app_rail.dart';
import 'package:yinwei_player/widgets/update_check_dialog.dart';

void main() {
  testWidgets('Windows rail exposes a check for updates action',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppRail(
          onOpen: () {},
          onOpenEq: () {},
          onExport: () {},
          onEnterIsland: () {},
          onCheckForUpdates: () => tapped = true,
          buildId: 'test',
        ),
      ),
    ));
    await tester.tap(find.text('Check updates'));
    expect(tapped, isTrue);
  });

  testWidgets('update dialog shows version and manual package action',
      (tester) async {
    final candidate = ReleaseArtifact(
      version: AppVersion.parse('0.1.1'),
      channel: UpdateChannel.stable,
      platform: kWindowsX64Platform,
      fileName: 'yinwei_player-0.1.1-windows-x64.zip',
      sha256: 'a' * 64,
      sizeBytes: 14762557,
      uri: Uri.parse(
        '$kYinweiUpdateChannelBase/packages/windows-x64/yinwei_player-0.1.1-windows-x64.zip',
      ),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UpdateCheckDialog(
          installed: InstalledApp.currentWindows(),
          check: Future.value(UpdateDecision(
            action: UpdateAction.offerManualInstall,
            reason: 'newer_build_available',
            candidate: candidate,
          )),
          service: UpdateCheckService(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Version 0.1.1 is available'), findsOneWidget);
    expect(find.text('Open download'), findsOneWidget);
    expect(find.textContaining('manually'), findsOneWidget);
  });
}
