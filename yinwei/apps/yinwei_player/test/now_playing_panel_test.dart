import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/now_playing_panel.dart';

void main() {
  testWidgets('transport is a compact bar, not a music-player card',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 80));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpPanel(tester);

    final bar = tester.getRect(find.byType(NowPlayingPanel));
    expect(bar.height, YinweiLayout.transportHeight);
    expect(bar.height, lessThanOrEqualTo(56));
    expect(find.byTooltip('Previous'), findsNothing);
    expect(find.byTooltip('Next'), findsNothing);
    expect(find.byTooltip('Play / Pause'), findsOneWidget);

    final art = tester.getSize(find.byKey(const Key('transport-artwork')));
    expect(art.width, lessThanOrEqualTo(32));
    expect(art.height, lessThanOrEqualTo(32));
  });

  testWidgets('play/pause and seek use the supplied callbacks', (tester) async {
    var playTaps = 0;
    Duration? seeked;
    await _pumpPanel(
      tester,
      onPlayPause: () => playTaps++,
      onSeek: (d) => seeked = d,
    );

    await tester.tap(find.byTooltip('Play / Pause'));
    await tester.pump();
    expect(playTaps, 1);

    final slider = find.descendant(
      of: find.byType(NowPlayingPanel),
      matching: find.byType(Slider),
    );
    await tester.tap(slider);
    await tester.pump();
    expect(seeked, isNotNull);
  });

  testWidgets('system media leaves seeking disabled', (tester) async {
    await _pumpPanel(tester, disableSeek: true);
    final slider = tester.widget<Slider>(
      find.descendant(
        of: find.byType(NowPlayingPanel),
        matching: find.byType(Slider),
      ),
    );
    expect(slider.onChanged, isNull);
  });

  testWidgets('Original/Spatial calls PlaybackMode path only', (tester) async {
    final modes = <PlaybackMode>[];
    final arrays = <ArrayMode>[];
    await _pumpPanel(
      tester,
      playbackMode: PlaybackMode.spatial,
      arraySupported: true,
      onModeChanged: modes.add,
      onArrayMode: arrays.add,
    );

    await tester.tap(find.text('Original'));
    await tester.pump();
    expect(modes, [PlaybackMode.original]);
    expect(arrays, isEmpty);
  });

  testWidgets('Point/2.0 calls ArrayMode path without changing PlaybackMode',
      (tester) async {
    final modes = <PlaybackMode>[];
    final arrays = <ArrayMode>[];
    await _pumpPanel(
      tester,
      playbackMode: PlaybackMode.spatial,
      arrayMode: ArrayMode.off,
      arraySupported: true,
      onModeChanged: modes.add,
      onArrayMode: arrays.add,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(NowPlayingPanel),
        matching: find.text('2.0'),
      ),
    );
    await tester.pump();
    expect(arrays, [ArrayMode.stereo2]);
    expect(modes, isEmpty);
    expect(find.text('5.1'), findsNothing);
    expect(find.text('7.1'), findsNothing);
  });

  testWidgets('array switch is hidden when array is unsupported',
      (tester) async {
    await _pumpPanel(tester, arraySupported: false);
    expect(
      find.descendant(
        of: find.byType(NowPlayingPanel),
        matching: find.text('Point'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(NowPlayingPanel),
        matching: find.text('2.0'),
      ),
      findsNothing,
    );
  });

  testWidgets('narrow transport compresses metadata instead of overflowing',
      (tester) async {
    FlutterErrorDetails? overflow;
    final old = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) {
        overflow = details;
      }
      old?.call(details);
    };
    addTearDown(() => FlutterError.onError = old);

    await tester.binding.setSurfaceSize(const Size(720, 64));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpPanel(
      tester,
      width: 640,
      arraySupported: true,
      track: const TrackMeta(
        title: 'A Very Long Spatial Session Title That Should Ellipsize',
        artist: 'Long Artist Name Ensemble',
        album: 'A Moment Apart Deluxe Edition',
        duration: Duration(minutes: 12, seconds: 4),
      ),
    );

    expect(overflow, isNull);
    expect(find.byTooltip('Play / Pause'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
    expect(find.byKey(const Key('transport-artwork')), findsNothing);
  });
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  TrackMeta? track,
  Duration position = const Duration(minutes: 1, seconds: 42),
  bool isPlaying = false,
  PlaybackMode playbackMode = PlaybackMode.spatial,
  ArrayMode arrayMode = ArrayMode.off,
  bool arraySupported = false,
  ValueChanged<Duration>? onSeek,
  bool disableSeek = false,
  VoidCallback? onPlayPause,
  ValueChanged<PlaybackMode>? onModeChanged,
  ValueChanged<ArrayMode>? onArrayMode,
  double width = 1280,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: YinweiTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: width,
            child: NowPlayingPanel(
              track: track ?? TrackMeta.demo,
              position: position,
              isPlaying: isPlaying,
              playbackMode: playbackMode,
              arrayMode: arrayMode,
              arraySupported: arraySupported,
              onSeek: disableSeek ? null : (onSeek ?? (_) {}),
              onPlayPause: onPlayPause ?? () {},
              onModeChanged: onModeChanged ?? (_) {},
              onArrayMode: onArrayMode,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
