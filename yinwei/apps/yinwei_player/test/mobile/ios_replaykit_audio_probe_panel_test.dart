import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/mobile/ios_replaykit_audio_probe_panel.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class _FakeReplayKitProbe implements ReplayKitAudioProbe {
  _FakeReplayKitProbe(this.status);

  ReplayKitAudioProbeStatus status;
  int opens = 0;
  int toneStarts = 0;

  @override
  bool get supported => status.supported;

  @override
  Future<ReplayKitAudioProbeStatus> getStatus() async => status;

  @override
  Future<bool> isAvailable() async => status.supported;

  @override
  Future<void> resetStatus() async {
    status = const ReplayKitAudioProbeStatus(
      supported: true,
      broadcastActive: false,
      broadcastPhase: 'idle',
      appAudioBufferCount: 0,
      ignoredMicrophoneBufferCount: 0,
      discardedVideoBufferCount: 0,
      droppedInspectionBufferCount: 0,
      receivingAppAudio: false,
      audioSilent: false,
      returnToneActive: false,
    );
  }

  @override
  Future<void> showBroadcastPicker() async {
    opens += 1;
  }

  @override
  Future<void> playReturnTone() async {
    toneStarts += 1;
  }

  @override
  Future<void> stopReturnTone() async {}
}

void main() {
  testWidgets('panel exposes user-controlled picker and numeric telemetry',
      (tester) async {
    tester.view.physicalSize = const Size(390, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final probe = _FakeReplayKitProbe(
      const ReplayKitAudioProbeStatus(
        supported: true,
        broadcastActive: true,
        broadcastPhase: 'broadcasting',
        appAudioBufferCount: 23,
        ignoredMicrophoneBufferCount: 0,
        discardedVideoBufferCount: 19,
        droppedInspectionBufferCount: 0,
        receivingAppAudio: true,
        audioSilent: false,
        returnToneActive: false,
        sampleRate: 48000,
        channelCount: 2,
        lastRmsDb: -18.4,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: IosReplayKitAudioProbePanel(probe: probe),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Receiving App Audio'), findsOneWidget);
    expect(find.textContaining('App audio: 23'), findsOneWidget);
    expect(find.textContaining('48000 Hz / 2 ch'), findsOneWidget);
    expect(find.textContaining('saves and uploads no media'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // This golden was captured with Flutter's Windows rasterizer. Keep the
    // behavioral assertions platform-independent and compare pixels only on
    // the rasterizer that produced the checked-in baseline.
    if (Platform.isWindows) {
      await expectLater(
        find.byKey(const Key('ios-replaykit-audio-probe')),
        matchesGoldenFile('../goldens/ios_replaykit_n0_panel.png'),
      );
    }

    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();

    await tester.tap(find.byKey(const Key('ios-replaykit-audio-probe-open')));
    await tester.pump();
    expect(probe.opens, 1);

    await tester.tap(find.byKey(const Key('ios-replaykit-return-tone')));
    await tester.pump();
    expect(probe.toneStarts, 1);

    await tester
        .tap(find.byKey(const Key('ios-screen-audio-probe-open-advanced')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Reset numeric status'), findsOneWidget);
    expect(find.text('iOS 27 screen audio test'), findsOneWidget);
  });
}
