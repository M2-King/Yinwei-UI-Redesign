import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/app_audio_route.dart';

void main() {
  test('recovery record preserves the routed device, mute state, and PIDs', () {
    const record = AudioRouteRecoveryState(
      r'\\?\SWD#MMDEVAPI#{speaker}',
      true,
      rootPid: 42,
      routedPids: [42, 43],
    );
    final decoded = AudioRouteRecoveryState.parse(record.encode());
    expect(decoded, isNotNull);
    expect(decoded!.speakersId, record.speakersId);
    expect(decoded.unmute, isTrue);
    expect(decoded.rootPid, 42);
    expect(decoded.routedPids, [42, 43]);
  });

  test('legacy marker and invalid records cannot be mistaken for new state', () {
    expect(AudioRouteRecoveryState.parse('1'), isNull);
    expect(AudioRouteRecoveryState.parse('{"speakersId":"x"}'), isNull);
    expect(
      AudioRouteRecoveryState.parse(
          '{"speakersId":"x","unmute":true,"rootPid":1,"routedPids":[]}'),
      isNull,
    );
  });

  test('existing mute state is retained in recovery record', () {
    const record = AudioRouteRecoveryState(
      'speakers',
      false,
      rootPid: 7,
      routedPids: [7],
    );
    expect(AudioRouteRecoveryState.parse(record.encode())!.unmute, isFalse);
  });
}
