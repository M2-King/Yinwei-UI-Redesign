import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/audio_session_coordinator.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

void main() {
  test('AudioSessionCoordinator is a no-op outside iOS', () async {
    final session = AudioSessionCoordinator.create(
      capabilities: PlatformCapabilities.ios,
    );
    expect(session.available, isFalse);
    await session.activateForPlayback();
    await session.deactivate();
  });

  test('Windows profile does not enable the audio-session seam', () {
    final session = AudioSessionCoordinator.create(
      capabilities: PlatformCapabilities.windows,
    );
    expect(session.available, isFalse);
  });
}
