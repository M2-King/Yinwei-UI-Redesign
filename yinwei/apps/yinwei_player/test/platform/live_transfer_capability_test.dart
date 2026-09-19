import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/live_transfer.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

void main() {
  test('Transfer is unavailable when liveTransfer capability is off', () {
    final live = LiveTransferController(
      capabilities: PlatformCapabilities.none,
    );
    expect(live.available, isFalse);
  });

  test('Windows profile does not hide Transfer behind a capability veto', () {
    const caps = PlatformCapabilities.windows;
    expect(caps.liveTransfer, isTrue);
    final live = LiveTransferController(capabilities: caps);
    // Availability may still be false if spatial_core.dll is missing in tests.
    // The product gate itself must remain enabled.
    expect(live.capabilityEnabled, isTrue);
  });
}
