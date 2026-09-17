import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1440, 900),
    minimumSize: Size(1024, 640),
    center: true,
    backgroundColor: YinweiColors.background,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
    title: '音围 Yinwei',
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const YinweiApp());
}

class YinweiApp extends StatelessWidget {
  const YinweiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '音围 Yinwei',
      debugShowCheckedModeBanner: false,
      theme: YinweiTheme.dark(),
      // Flutter 3.47's Windows AXTree bridge can crash while dynamic UI and
      // tooltip overlays update under an active accessibility client. Keep the
      // visual/interactive UI intact while containing that engine defect.
      home: TooltipVisibility(
        visible: !Platform.isWindows,
        child: ExcludeSemantics(
          excluding: Platform.isWindows,
          child: const PlayerScreen(),
        ),
      ),
    );
  }
}
