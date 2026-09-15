import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/eq_mixer_window.dart';

void main() {
  testWidgets('mixer shows six sequences and six faders', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: EqMixerWindow(
            params: SpatialParams(),
            onChanged: (_) {},
            onEqSelected: (_) {},
            onClose: () {},
            onDrag: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('EQ 调音台'), findsOneWidget);
    expect(find.text('人声'), findsOneWidget);
    expect(find.text('Bass'), findsOneWidget);
    expect(find.text('10k'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(6));
  });
}
