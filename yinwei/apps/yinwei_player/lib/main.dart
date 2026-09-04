import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
