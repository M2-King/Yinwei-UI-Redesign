import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/live_transfer.dart';
import 'package:yinwei_player/bridge/system_media.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/system_live_monitor_bar.dart';

void main() {
  test('toggleLabel shows 连接中 while starting', () {
    final c = LiveTransferController();
    expect(c.toggleLabel(idle: '真实Transfer'), '真实Transfer');
    c.starting = true;
    expect(c.toggleLabel(idle: '真实Transfer'), '连接中');
    expect(c.toggleLabel(idle: '全窗Transfer'), '连接中');
    c.starting = false;
    c.running = true;
    expect(c.toggleLabel(idle: '真实Transfer'), 'HRTF ON');
  });

  testWidgets('full-window Transfer button shows 连接中 immediately', (
    tester,
  ) async {
    final smtc = SystemMediaService();
    smtc.state = const SystemMediaState(
      active: true,
      title: 'Song',
      playing: true,
      pid: 4242,
      processName: 'QQMusic.exe',
    );
    final live = LiveTransferController()..starting = true;

    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: SystemLiveMonitorBar(
            systemMedia: smtc,
            liveTransfer: live,
            onToggleLiveHrtf: () {},
          ),
        ),
      ),
    );

    expect(find.text('连接中'), findsWidgets);
    expect(find.textContaining('HRTF ON · 连接中'), findsOneWidget);
    expect(find.text('真实Transfer'), findsNothing);
  });
}
