import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/mobile/ios_laptop_listen_screen.dart';
import 'package:yinwei_player/mobile/ios_update_notice.dart';
import 'package:yinwei_player/mobile/listen_room_sign_in.dart';
import 'package:yinwei_player/platform/macos_webview_host.dart';
import 'package:yinwei_player/remote/laptop_listen_controller.dart';
import 'package:yinwei_player/remote/listen_room_bridge.dart';
import 'package:yinwei_player/remote/listen_room_html.dart';
import 'package:yinwei_player/state/engine_controller.dart';

/// Developer diagnostics: shows the room's FPS meter (the switch is on the
/// Diagnostics page).
final listenRoomFpsOverlay = ValueNotifier<bool>(false);

/// "Listen to laptop" as the Moonlight Room: the approved 3D room page in a
/// WKWebView, driven by the listening session through [ListenRoomBridge]
/// (IMPLEMENTATION_IPAD_LISTEN_ROOM.md, P2).
///
/// - Sign-in stays native ([ListenRoomSignIn]); the password never enters the page.
/// - Listening never goes through the WebView, so it carries on in the
///   background, on the lock screen and after this screen closes.
/// - The room renders only while it is on screen: it is suspended when the app
///   goes to the background and resumed on return. If iPadOS ended the page's
///   web process meanwhile, the page is reloaded and the state sent again.
/// - If the page reports an error (no WebGL) or is not ready within
///   [readyTimeout], the classic [IosLaptopListenScreen] is shown instead.
/// iPad: the room is the whole app (no player page behind it). A build with
/// `--dart-define=YINWEI_IOS_ROOM_HOME=false` opens the previous player page
/// instead (rollback; that page and its code are kept).
const bool kIosRoomIsHome =
    bool.fromEnvironment('YINWEI_IOS_ROOM_HOME', defaultValue: true);

class IosListenRoomScreen extends StatefulWidget {
  const IosListenRoomScreen({
    super.key,
    this.player,
    this.session,
    this.driverFactory,
    this.loadHtml,
    this.readyTimeout = const Duration(seconds: 5),
    this.home = false,
    this.updateNotice,
  });

  /// The room is the whole app (iPad): nothing to go back to, and updates
  /// are checked here (automatically once a session, and from the ••• menu).
  final bool home;

  /// Defaults to the update channel when [home] on iOS.
  final IosUpdateNotice? updateNotice;

  /// The iPad's own file player; listening waits until it is paused.
  final EngineController? player;
  final LaptopListenController? session;

  /// The WebView (tests pass a fake).
  final MacOSWebViewDriver Function()? driverFactory;

  /// The page document (tests pass a stub).
  final Future<String> Function()? loadHtml;
  final Duration readyTimeout;

  static const airplayViewType = 'dev.yinwei/listen_room_airplay';

  @override
  State<IosListenRoomScreen> createState() => _IosListenRoomScreenState();
}

class _IosListenRoomScreenState extends State<IosListenRoomScreen>
    with WidgetsBindingObserver {
  late final LaptopListenController _session =
      widget.session ?? sharedLaptopListen();
  MacOSWebViewDriver? _driver;
  ListenRoomBridge? _bridge;
  Widget? _view;
  String? _html;
  Timer? _readyTimer;
  bool _booting = false, _pageReady = false, _classic = false;
  late final IosUpdateNotice? _updates = widget.updateNotice ??
      (widget.home && defaultTargetPlatform == TargetPlatform.iOS
          ? IosUpdateNotice()
          : null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_sessionChanged);
    listenRoomFpsOverlay.addListener(_applyFps);
    _sessionChanged();
    // A newer published build is offered once a session.
    final updates = _updates;
    if (updates != null && updates.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final release = await updates.check();
        if (release != null && mounted) updates.showBanner(context, release);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_sessionChanged);
    listenRoomFpsOverlay.removeListener(_applyFps);
    unawaited(_tearDown());
    super.dispose();
  }

  void _sessionChanged() {
    if (!mounted) return;
    if (_session.signedIn && !_classic && _driver == null && !_booting) {
      unawaited(_boot());
    } else if (!_session.signedIn && _driver != null) {
      // Signed out: release the WebView (and its WebGL) behind the sign-in.
      unawaited(_tearDown());
    }
    setState(() {});
  }

  Future<void> _boot() async {
    _booting = true;
    final driver = (widget.driverFactory ?? WKWebViewDriver.new)();
    final bridge = ListenRoomBridge(
      session: _session,
      run: (script) async {
        await driver.execute(script);
      },
      localPlayerPlaying: () => widget.player?.playing == true,
      canClose: !widget.home,
    )
      ..onReady = _pageIsReady
      ..onAirplayRectChanged = () {
        if (mounted) setState(() {});
      }
      ..onPageError = (reason) {
        _toClassic('the room reported: $reason');
      }
      ..onClose = () {
        unawaited(Navigator.of(context).maybePop());
      }
      ..appBuild = _updates?.build
      ..onCheckUpdates = _updates == null
          ? null
          : () {
              if (mounted) unawaited(_updates.checkAndReport(context));
            };
    _driver = driver;
    _bridge = bridge;
    bool current() => mounted && identical(driver, _driver);
    try {
      await driver.initialize(
        onMessage: (raw) {
          if (current()) unawaited(bridge.handle(raw));
        },
        onError: (error) {
          if (current()) _toClassic('$error');
        },
      );
      final html = _html ??= await (widget.loadHtml ?? ListenRoomHtml.load)();
      if (!current()) return;
      bridge.attach();
      setState(() => _view = driver.view);
      _startReadyTimer();
      await driver.load(html);
    } catch (error) {
      if (current()) _toClassic('$error');
    } finally {
      _booting = false;
    }
  }

  void _startReadyTimer() {
    _readyTimer?.cancel();
    _readyTimer = Timer(widget.readyTimeout, () {
      if (!_pageReady) _toClassic('the room was not ready in time');
    });
  }

  void _pageIsReady() {
    _readyTimer?.cancel();
    if (!mounted) return;
    setState(() => _pageReady = true);
    _applyFps();
  }

  void _applyFps() {
    if (_pageReady) {
      unawaited(_run('YinweiListen.devOverlay(${listenRoomFpsOverlay.value})'));
    }
  }

  Future<void> _run(String script) async {
    try {
      await _driver?.execute(script);
    } catch (_) {
      // The page is gone; resuming reloads it.
    }
  }

  void _toClassic(String reason) {
    if (_classic || !mounted) return;
    debugPrint('[ListenRoom] showing the classic screen: $reason');
    unawaited(_tearDown());
    setState(() => _classic = true);
  }

  Future<void> _tearDown() async {
    _readyTimer?.cancel();
    final driver = _driver, bridge = _bridge;
    _driver = null;
    _bridge = null;
    _view = null;
    _pageReady = false;
    bridge?.dispose();
    await driver?.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _session.resumed();
        _bridge?.background = false;
        unawaited(_resumePage());
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        // Nothing renders while the room can't be seen, and the page gets no
        // updates (they would wait on the frozen WebView and delay audio).
        unawaited(_run('YinweiListen.suspend()'));
        _bridge?.background = true;
      default:
        break;
    }
  }

  /// Back from the background: resume rendering, or reload the page if
  /// iPadOS ended its web process meanwhile (the session owns all state, so
  /// nothing is lost).
  Future<void> _resumePage() async {
    final driver = _driver, bridge = _bridge, html = _html;
    if (driver == null || bridge == null || !_pageReady) return;
    Object? alive;
    try {
      alive = await driver.execute('typeof YinweiListen');
    } catch (_) {
      alive = null;
    }
    if (!identical(driver, _driver)) return;
    if (alive == 'object') {
      await _run('YinweiListen.resume()');
      await bridge.push(force: true);
      return;
    }
    if (html == null) return;
    bridge.pageReloaded();
    setState(() => _pageReady = false);
    _startReadyTimer();
    try {
      await driver.load(html);
    } catch (error) {
      _toClassic('$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_classic) {
      return IosLaptopListenScreen(player: widget.player, session: _session);
    }
    if (!_session.signedIn) {
      return ListenRoomSignIn(
        session: _session,
        onClose: widget.home ? null : () => Navigator.of(context).maybePop(),
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        key: const Key('listen-room'),
        backgroundColor: _night,
        body: LayoutBuilder(builder: (context, constraints) {
          final r = _bridge?.airplayRect;
          // Never put an oversized/stale page rectangle over other controls.
          final showPicker = _pageReady &&
              _session.listening &&
              _session.audioConnected &&
              r != null &&
              r[0] + r[2] <= constraints.maxWidth &&
              r[1] + r[3] <= constraints.maxHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (_view != null) _view!,
              // A calm dark frame until the page draws its first room frame.
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _pageReady ? 0 : 1,
                  duration: const Duration(milliseconds: 300),
                  child: const ColoredBox(color: _night),
                ),
              ),
              if (showPicker)
                Positioned(
                  left: r[0].toDouble(),
                  top: r[1].toDouble(),
                  width: r[2].toDouble(),
                  height: r[3].toDouble(),
                  child: const UiKitView(
                    key: Key('listen-room-airplay'),
                    viewType: IosListenRoomScreen.airplayViewType,
                    layoutDirection: TextDirection.ltr,
                    gestureRecognizers: {
                      Factory<EagerGestureRecognizer>(
                          EagerGestureRecognizer.new),
                    },
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }

  static const _night = Color(0xFF070A12);
}

/// Opens "Listen to laptop" from the iPad player.
Future<void> openListenRoom(BuildContext context, EngineController player) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => IosListenRoomScreen(player: player)));
