import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1280, 720),
    minimumSize: Size(800, 500),
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
      title: '音围 Spatial Player',
      debugShowCheckedModeBanner: false,
      theme: YinweiTheme.dark(),
      home: const PlayerScreen(),
    );
  }
}
