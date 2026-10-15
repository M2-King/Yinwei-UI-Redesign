import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/mobile/ios_remote_live_screen.dart';
import 'package:yinwei_player/platform/ios_remote_live_session.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class _LiveFixture extends IosRemoteLiveSession {
  int starts = 0;
  int stops = 0;
  @override
  Future<void> stop({String? message}) async {
    ++stops;
    active = false;
  }

  @override
  Future<void> start({required bool routingVerified}) async {
    ++starts;
  }
}

void main() {
  testWidgets('landscape enlarged text scrolls and suspension stops listening',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = _LiveFixture()..active = true;
    await tester.pumpWidget(MaterialApp(
        theme: YinweiTheme.dark(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!),
        home: IosRemoteLiveScreen(session: session)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(
        session.stops, 0); // Apple's picker temporarily makes the app inactive.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(session.stops, 1);
    expect(session.active, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(session.starts, 0);
    await tester.ensureVisible(find.text('Stop live transform'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'signed-in owner cannot start before all three actual-route checks',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 1366));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = _LiveFixture()..signedIn = true;
    final fontFile = Platform.environment['YINWEI_R2_UI_FONT_FILE'];
    if (fontFile != null) {
      await tester.runAsync(() async {
        final bytes = await File(fontFile).readAsBytes();
        final loader = FontLoader('SF Pro Text')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      });
    }
    await tester.pumpWidget(MaterialApp(
        theme: YinweiTheme.dark(),
        home: RepaintBoundary(
            key: const Key('live-screen-capture'),
            child: IosRemoteLiveScreen(session: session))));
    final start = find.widgetWithText(FilledButton, 'Start live transform');
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    final checks = find.byType(CheckboxListTile);
    for (var i = 0; i < 3; ++i) {
      await tester.ensureVisible(checks.at(i));
      await tester.tap(checks.at(i));
      await tester.pump();
      if (i < 2) expect(tester.widget<FilledButton>(start).onPressed, isNull);
    }
    expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
    expect(session.starts, 0);
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    expect(session.starts, 1);
    expect(tester.takeException(), isNull);
    if (fontFile != null) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('live-screen-capture')));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../../.tmp/r2-live-screen-readable.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    } else if (Platform.isWindows) {
      await expectLater(find.byType(IosRemoteLiveScreen),
          matchesGoldenFile('../goldens/ios_remote_live_screen.png'));
    }
    await tester.pumpWidget(const SizedBox());
  });
}
