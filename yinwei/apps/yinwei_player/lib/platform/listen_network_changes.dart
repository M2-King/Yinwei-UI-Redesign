import 'dart:async';

import 'package:flutter/services.dart';

/// Starts observing only once a paired route exists. No VPN configuration,
/// network names, addresses, location permission, or polling are involved.
Stream<void> listenNetworkChanges() {
  const channel = MethodChannel('dev.yinwei/listen_network');
  late StreamController<void> controller;
  controller = StreamController<void>.broadcast(onListen: () {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') controller.add(null);
    });
    unawaited(channel.invokeMethod<void>('watch').catchError((Object _) {}));
  }, onCancel: () {
    channel.setMethodCallHandler(null);
    unawaited(channel.invokeMethod<void>('unwatch').catchError((Object _) {}));
  });
  return controller.stream;
}
