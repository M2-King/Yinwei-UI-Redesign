import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/mobile/mobile_transport.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

void main() {
  testWidgets('processed export is available only after a file is open',
      (tester) async {
    final controller = EngineController();
    addTearDown(controller.dispose);
    var exports = 0;
    Duration? seek;

    Widget app() => MaterialApp(
          theme: YinweiTheme.dark(),
          home: Scaffold(
            body: MobileTransport(
              controller: controller,
              onOpen: () {},
              onExport: () => exports++,
              onSeek: (value) => seek = value,
            ),
          ),
        );

    await tester.pumpWidget(app());
    final export = find.byKey(const Key('ios-export-file-button'));
    expect(export, findsOneWidget);
    expect(tester.widget<IconButton>(export).onPressed, isNull);

    controller.hasOpenedFile = true;
    controller.position = const Duration(seconds: 12);
    await tester.pumpWidget(app());
    await tester.tap(export);
    expect(exports, 1);

    final slider = tester.widget<Slider>(
      find.byKey(const Key('ios-playback-position')),
    );
    expect(slider.value, 12000);
    slider.onChangeEnd?.call(30000);
    expect(seek, const Duration(seconds: 30));
  });
}
