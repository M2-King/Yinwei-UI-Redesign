import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/position_sidebar.dart';

void main() {
  testWidgets('Point|2.0 switch is hidden when array is unsupported',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            arraySupported: false,
            onChanged: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('点源'), findsNothing);
    expect(find.text('2.0'), findsNothing);
    expect(find.text('5.1'), findsNothing);
  });

  testWidgets('2.0 mode shows L/R chips and pose sliders, not 5.1',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            array: ArrayLayout.stereo2(),
            arraySupported: true,
            onChanged: (_) {},
            onArrayChanged: (_) {},
            onArrayMode: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('点源'), findsOneWidget);
    expect(find.text('2.0'), findsOneWidget);
    expect(find.text('5.1'), findsNothing);
    expect(find.text('L'), findsOneWidget);
    expect(find.text('R'), findsOneWidget);
    expect(find.text('Azimuth'), findsOneWidget);
    expect(find.text('Center'), findsNothing);
    expect(find.text('Surround'), findsNothing);
    expect(find.text('LFE'), findsNothing);
    expect(find.text('+'), findsOneWidget);
    expect(find.text('矩阵'), findsOneWidget);
    expect(find.text('Spread'), findsNothing);
  });

  testWidgets('Point mode hides extra-speaker chips', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            array: ArrayLayout(),
            arraySupported: true,
            onChanged: (_) {},
            onArrayChanged: (_) {},
            onArrayMode: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('+'), findsNothing);
    expect(find.text('移除点位'), findsNothing);
    expect(find.text('矩阵'), findsNothing);
  });

  testWidgets('extra Mid chip can be removed, L/R cannot', (tester) async {
    final layout = ArrayLayout.stereo2()..addSpeaker(azimuthDeg: 0);
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            array: layout,
            arraySupported: true,
            onChanged: (_) {},
            onArrayChanged: (_) {},
            onArrayMode: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('3'), findsOneWidget);
    expect(find.text('移除点位'), findsOneWidget);
  });

  testWidgets('matrix chip shows spread slider', (tester) async {
    final layout = ArrayLayout.stereo2()..setMatrixLinked(true);
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            array: layout,
            arraySupported: true,
            onChanged: (_) {},
            onArrayChanged: (_) {},
            onArrayMode: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('矩阵'), findsOneWidget);
    expect(find.text('Spread'), findsOneWidget);
    expect(find.textContaining('合并'), findsOneWidget);
  });

  testWidgets('default inspector shows source identity and grouped sections',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            arraySupported: false,
            onChanged: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('Point Source'), findsOneWidget);
    expect(find.text('SOURCE'), findsOneWidget);
    expect(find.textContaining('source-main'), findsOneWidget);
    expect(find.textContaining('Audio object'), findsNothing);
    expect(find.textContaining('HRTF'), findsNothing);
    expect(find.text('INSPECTOR'), findsNothing);
    expect(find.text('POSITION'), findsNothing);
    expect(find.text('QUICK PLACE'), findsNothing);
    expect(find.text('Quick Controls'), findsOneWidget);
    expect(find.text('ADVANCED'), findsNothing);
    expect(find.text('Azimuth'), findsOneWidget);
    expect(find.text('Elevation'), findsOneWidget);
    expect(find.text('Distance'), findsOneWidget);
    expect(find.text('MOTION'), findsOneWidget);
    expect(find.text('SPACE'), findsOneWidget);
    expect(find.text('Envelopment'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    expect(find.text('Y'), findsOneWidget);
    expect(find.text('Z'), findsOneWidget);
  });

  testWidgets('listener selection is read-only and keeps source controls',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            selectedObjectId: 'listener-0',
            sceneSnapshot: {
              'listener': {
                'id': 'listener-0',
                'worldPosition': {'x': 0, 'y': 0, 'z': 0},
              },
            },
            onChanged: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('Listener'), findsOneWidget);
    expect(find.text('LISTENER'), findsOneWidget);
    expect(find.textContaining('Read only'), findsOneWidget);
    expect(find.text('SPATIAL SOURCE'), findsOneWidget);
    expect(find.text('Front'), findsOneWidget);
  });

  testWidgets('emitter selection is labeled as visual layout only',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            selectedObjectId: 'emitter-L',
            onChanged: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('Monitor L'), findsOneWidget);
    expect(find.textContaining('not an audio channel'), findsOneWidget);
    expect(find.text('SPATIAL SOURCE'), findsOneWidget);
  });

  testWidgets('array inspector uses selected speaker identity', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YinweiTheme.dark(),
        home: Scaffold(
          body: PositionSidebar(
            params: SpatialParams(),
            array: ArrayLayout.stereo2(),
            arraySupported: true,
            onChanged: (_) {},
            onArrayChanged: (_) {},
            onArrayMode: (_) {},
            onExport: () {},
            onSavePreset: () {},
            onOpenEq: () {},
          ),
        ),
      ),
    );
    expect(find.text('Speaker L'), findsOneWidget);
    expect(find.text('SPEAKER'), findsOneWidget);
    expect(find.text('ARRAY'), findsOneWidget);
    expect(find.text('QUICK PLACE'), findsNothing);
    expect(find.text('Quick Controls'), findsNothing);
  });
}
