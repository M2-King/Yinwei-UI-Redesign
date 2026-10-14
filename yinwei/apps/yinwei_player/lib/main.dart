import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yinwei_player/remote/remote_host_lock.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/screens/player_screen.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

RemoteHostLock? _hostLock;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    // Refuse older installed builds too: they do not participate in our lock.
    // This only inspects process identity; it never stops another player.
    final other = await Process.run('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      '@(Get-Process -Name yinwei_player -ErrorAction SilentlyContinue | Where-Object { \$_.Id -ne $pid }).Count',
    ]);
    if (other.exitCode != 0 || (int.tryParse('${other.stdout}'.trim()) ?? 1) > 0) {
      stderr.writeln('Yinwei is already running. Close that instance before starting this host.');
      exit(1);
    }
    final support = await getApplicationSupportDirectory();
    _hostLock = await RemoteHostLock.acquire(Directory('${support.path}\\remote'));
    assert(_hostLock != null);
  }
  final caps = PlatformCapabilities.detect();
  if (caps.desktopWindow) {
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
  }

  runApp(const YinweiApp());
}

class YinweiApp extends StatelessWidget {
  const YinweiApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Cover the Navigator and its overlays as well as the screen. Excluding
    // only home still sends snackbar/route semantics to the unstable Windows
    // AXTree bridge. This extends the existing Windows containment policy.
    return ExcludeSemantics(
      excluding: Platform.isWindows,
      child: TooltipVisibility(
        visible: !Platform.isWindows,
        child: MaterialApp(
          title: '音围 Yinwei',
          debugShowCheckedModeBanner: false,
          theme: YinweiTheme.dark(),
          home: const PlayerScreen(),
        ),
      ),
    );
  }
}
