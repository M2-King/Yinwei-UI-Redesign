import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/mobile/ios_laptop_listen_screen.dart';
import 'package:yinwei_player/mobile/ios_listen_room_screen.dart';
import 'package:yinwei_player/platform/macos_webview_host.dart';

import 'package:yinwei_player/mobile/ios_update_notice.dart';
import 'package:yinwei_player/update/release_manifest.dart';

import '../remote/listen_room_bridge_test.dart' show FakeSession, snapshot;
import 'ios_update_notice_test.dart' show FakeService, offer, release;

/// A WebView that records what the screen does with it.
class FakeDriver implements MacOSWebViewDriver {
  ValueChanged<String>? message;
  ValueChanged<Object>? error;
  final loads = <String>[];
  final scripts = <String>[];
  Object? alive = 'object';
  bool disposed = false;

  @override
  Widget get view => const SizedBox.expand(key: Key('fake-webview'));
  @override
  Future<void> initialize(
      {required ValueChanged<String> onMessage,
      required ValueChanged<Object> onError}) async {
    message = onMessage;
    error = onError;
  }

  @override
  Future<void> load(String html) async => loads.add(html);
  @override
  Future<dynamic> execute(String script) async {
    scripts.add(script);
    return script == 'typeof YinweiListen' ? alive : null;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late FakeSession session;
  late FakeDriver driver;
  late List<MethodCall> platformCalls;

  Future<void> show(WidgetTester tester, {Duration? timeout}) async {
    await tester.pumpWidget(MaterialApp(
      home: IosListenRoomScreen(
        session: session,
        driverFactory: () => driver,
        loadHtml: () async => '<html><body>room</body></html>',
        readyTimeout: timeout ?? const Duration(seconds: 5),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  setUp(() {
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      platformCalls.add(call);
      return null;
    });
    session = FakeSession()
      ..snapshot = snapshot()
      ..connected = true;
    driver = FakeDriver();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  test('AirPlay uses an existing native file and a directly tapped system view',
      () {
    final swift =
        File('ios/Runner/YinweiReplayKitProbe.swift').readAsStringSync();
    final app = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(swift, contains('AVRoutePickerView(frame: frame)'));
    expect(swift, contains('FlutterPlatformViewFactory'));
    expect(swift, contains(IosListenRoomScreen.airplayViewType));
    expect(swift, contains('picker.prioritizesVideoDevices = false'));
    expect(swift, isNot(contains('sendActions(for:')));
    expect(
        app, contains('withId: YinweiListenRoomRoutePickerFactory.viewType'));
  });

  testWidgets('AirPlay follows page bounds above the WebView and receives taps',
      (tester) async {
    session
      ..listening = true
      ..audioConnected = true;
    await show(tester);
    driver.message!('{"t":"rects","airplay":[700,500,40,40]}');
    await tester.pump();
    expect(find.byType(UiKitView), findsNothing,
        reason: 'waits for first frame');
    driver.message!('{"t":"ready"}');
    await tester.pumpAndSettle();
    final picker = find.byKey(const Key('listen-room-airplay'));
    expect(tester.getRect(picker), const Rect.fromLTWH(700, 500, 40, 40));
    expect(
        platformCalls
            .where((c) => c.method == 'create')
            .single
            .arguments['viewType'],
        IosListenRoomScreen.airplayViewType);
    await tester.tap(picker);
    await tester.pump();
    expect(platformCalls.any((c) => c.method == 'acceptGesture'), isTrue);
    expect(session.calls, isEmpty);

    driver.message!('{"t":"rects","airplay":[600,450,48,48]}');
    await tester.pump();
    expect(tester.getRect(picker), const Rect.fromLTWH(600, 450, 48, 48));
    expect(platformCalls.where((c) => c.method == 'create').length, 1,
        reason: 'a resize moves the existing picker');
    driver.message!('{"t":"rects","airplay":[790,450,48,48]}');
    await tester.pump();
    expect(picker, findsNothing, reason: 'out-of-viewport bounds are hidden');
    driver.message!('{"t":"rects","airplay":null}');
    await tester.pump();
    expect(picker, findsNothing);
    driver.message!('{"t":"rects","airplay":[600,450,48,48]}');
    await tester.pump();
    await tester.pump();
    session.set((s) => s.listening = false);
    await tester.pump();
    expect(picker, findsNothing,
        reason: 'stopping removes a stale overlay immediately');
  });

  testWidgets('AirPlay is removed on reload, sign-out and fallback',
      (tester) async {
    session
      ..listening = true
      ..audioConnected = true;
    await show(tester);
    driver.message!('{"t":"ready"}');
    driver.message!('{"t":"rects","airplay":[700,500,40,40]}');
    await tester.pump();
    await tester.pump();
    expect(find.byType(UiKitView), findsOneWidget);
    driver.alive = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.byType(UiKitView), findsNothing);
    driver.message!('{"t":"ready"}');
    await tester.pump();
    expect(find.byType(UiKitView), findsNothing,
        reason: 'needs fresh page bounds');
    driver.message!('{"t":"rects","airplay":[700,500,40,40]}');
    await tester.pump();
    session.set((s) => s.signed = false);
    await tester.pump();
    expect(find.byType(UiKitView), findsNothing);

    driver = FakeDriver();
    session.set((s) => s.signed = true);
    await tester.pump();
    await tester.pump();
    driver.message!('{"t":"ready"}');
    driver.message!('{"t":"rects","airplay":[700,500,40,40]}');
    await tester.pump();
    await tester.pump();
    expect(find.byType(UiKitView), findsOneWidget);
    driver.error!(StateError('page lost'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(UiKitView), findsNothing);
    expect(find.byType(IosLaptopListenScreen), findsOneWidget);
    expect(session.calls, isEmpty);
  });

  testWidgets('the whole app: no way back, updates offered and checkable',
      (tester) async {
    final service = FakeService((_) async => offer(release(build: 52)));
    final notice = IosUpdateNotice(
        service: service, installed: InstalledApp.currentIos(build: 51));
    session.signed = false;
    await tester.pumpWidget(MaterialApp(
      home: IosListenRoomScreen(
        session: session,
        driverFactory: () => driver,
        loadHtml: () async => '<html><body>room</body></html>',
        home: true,
        updateNotice: notice,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back to the player'), findsNothing,
        reason: 'the sign-in has nothing to go back to');
    expect(find.byKey(const Key('ios-update-banner')), findsOneWidget,
        reason: 'checked once on start');
    expect(service.asked, hasLength(1));
    ScaffoldMessenger.of(tester.element(find.byType(IosListenRoomScreen)))
        .hideCurrentMaterialBanner();
    await tester.pumpAndSettle();

    session.set((s) => s.signed = true);
    await tester.pump();
    await tester.pump();
    driver.message!('{"t":"ready","v":1}');
    await tester.pump();
    final state =
        driver.scripts.lastWhere((s) => s.startsWith('YinweiListen.apply('));
    expect(state, contains('"canClose":false'));
    expect(state, contains('"updates":true'));
    driver.message!('{"t":"close"}');
    await tester.pump();
    expect(find.byType(IosListenRoomScreen), findsOneWidget,
        reason: 'a close request is ignored');
    driver.message!('{"t":"checkUpdates"}');
    await tester.pumpAndSettle();
    expect(service.asked, hasLength(2), reason: 'the menu checks again');
    expect(find.byKey(const Key('ios-update-banner')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('signed out: the native sign-in, no WebView', (tester) async {
    session.signed = false;
    await show(tester);
    expect(find.byKey(const Key('listen-room-sign-in')), findsOneWidget);
    expect(find.text('Listen to your laptop, anywhere in the house.'),
        findsOneWidget);
    expect(driver.loads, isEmpty);
  });

  testWidgets('signed in: the room page loads; ready sends the state',
      (tester) async {
    await show(tester);
    expect(driver.loads.single, contains('room'));
    expect(find.byKey(const Key('fake-webview')), findsOneWidget);
    driver.message!('{"t":"ready","v":1}');
    await tester.pump();
    expect(
        driver.scripts.any((s) => s.startsWith('YinweiListen.apply(')), isTrue);
    expect(driver.scripts, contains('YinweiListen.devOverlay(false)'));
    await tester.pump(const Duration(seconds: 6));
    expect(find.byType(IosLaptopListenScreen), findsNothing,
        reason: 'ready in time');
  });

  testWidgets('a page error shows the classic screen; listening is not touched',
      (tester) async {
    await show(tester);
    driver.message!('{"t":"error","msg":"webgl"}');
    await tester.pump();
    await tester.pump();
    expect(find.byType(IosLaptopListenScreen), findsOneWidget);
    expect(driver.disposed, isTrue);
    expect(session.calls, isEmpty);
  });

  testWidgets('no ready within the timeout: the classic screen',
      (tester) async {
    await show(tester, timeout: const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.byType(IosLaptopListenScreen), findsOneWidget);
  });

  testWidgets(
      'background: suspended; back: resumed, or reloaded if the page died',
      (tester) async {
    await show(tester);
    driver.message!('{"t":"ready","v":1}');
    await tester.pump();
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(driver.scripts, contains('YinweiListen.suspend()'));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(driver.scripts, contains('YinweiListen.resume()'));
    expect(driver.loads.length, 1);

    // iPadOS ended the web process while the app was away.
    driver.alive = null;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(driver.loads.length, 2, reason: 'the page is loaded again');
    driver.message!('{"t":"ready","v":1}');
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(find.byType(IosLaptopListenScreen), findsNothing);
  });

  testWidgets('background: no page updates while audio keeps flowing',
      (tester) async {
    await show(tester);
    driver.message!('{"t":"ready","v":1}');
    await tester.pump();
    int applies() =>
        driver.scripts.where((s) => s.startsWith('YinweiListen.apply(')).length;
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 200));
    final before = applies();
    for (var i = 0; i < 5; i++) {
      // Packets keep arriving: the state the page would show keeps changing.
      session.set((s) => s.received += 100);
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(applies(), before,
        reason: 'the frozen WebView would hold up the main thread (and audio)');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(applies(), before + 1, reason: 'one full update on return');
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('signing out from the room returns to the sign-in',
      (tester) async {
    await show(tester);
    driver.message!('{"t":"ready","v":1}');
    await tester.pump();
    session.set((s) => s.signed = false);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('listen-room-sign-in')), findsOneWidget);
    expect(driver.disposed, isTrue,
        reason: 'WebGL is released behind the sign-in');
  });
}
