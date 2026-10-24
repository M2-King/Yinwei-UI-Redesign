import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_room_bridge.dart';

import 'listen_room_bridge_test.dart' show FakeSession, snapshot;

class _TapSession extends FakeSession {
  final taps = <Object?>[];

  @override
  void recordPageTap(Object? value) {
    taps.add(value);
    super.recordPageTap(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _TapSession session;
  late ListenRoomBridge bridge;
  late List<String> scripts;
  setUp(() async {
    session = _TapSession()
      ..control = true
      ..snapshot = snapshot(liveRunning: true);
    session.snapshot!['capabilities']['liveMedia'] = true;
    session.snapshot!['live'] = {'playing': true};
    scripts = [];
    bridge = ListenRoomBridge(
        session: session, run: (script) async => scripts.add(script));
    bridge.attach();
    await bridge.handle('{"t":"ready"}');
    scripts.clear();
  });
  tearDown(() {
    bridge.dispose();
    session.dispose();
  });

  test('refused media command signals refusal between toast and forced state',
      () async {
    session.commandWorks = false;
    await bridge.handle('{"t":"media","a":"pause","tapMs":123}');
    final notice =
        scripts.indexWhere((s) => s.startsWith('YinweiListen.toast('));
    final refusal =
        scripts.indexOf('YinweiListen.commandRefused("media.pause")');
    final applied =
        scripts.indexWhere((s) => s.startsWith('YinweiListen.apply('));
    expect(notice, greaterThanOrEqualTo(0));
    expect(refusal, greaterThan(notice));
    expect(applied, greaterThan(refusal));
    final state = jsonDecode(scripts[applied]
        .substring('YinweiListen.apply('.length, scripts[applied].length - 1));
    expect(state['playing'], isTrue);
  });

  test('successful media command and ordinary pushes never signal refusal',
      () async {
    await bridge.handle('{"t":"media","a":"pause","tapMs":123}');
    await bridge.push(force: true);
    expect(scripts.where((s) => s.contains('commandRefused')), isEmpty);
    expect(session.taps, [123], reason: 'record each media tap exactly once');
  });

  test('control refusal signals rollback without dispatching a media command',
      () async {
    session.control = false;
    session.takeWorks = false;
    await bridge.handle('{"t":"media","a":"pause"}');
    expect(scripts, contains('YinweiListen.commandRefused("media.pause")'));
    expect(session.calls.where((s) => s.startsWith('media.pause ')), isEmpty);
  });
}
