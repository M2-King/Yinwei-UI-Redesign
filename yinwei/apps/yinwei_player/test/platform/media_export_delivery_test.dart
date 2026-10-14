import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/media_export_delivery.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.yinwei/test_media_export');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('iOS delivery passes only the completed file path to native share',
      () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <String, Object?>{
        'ok': true,
        'shared': true,
        'path': '/app/tmp/track.wav',
      };
    });
    final delivery = MediaExportDelivery.create(
      capabilities: PlatformCapabilities.ios,
      channel: channel,
      isIOS: true,
    );

    expect(await delivery.shareFile('/app/tmp/track.wav'), isTrue);
    expect(received?.method, 'shareFile');
    expect(received?.arguments, {'path': '/app/tmp/track.wav'});
  });

  test('non-iOS delivery does not expose a share bridge', () async {
    final delivery = MediaExportDelivery.create(
      capabilities: PlatformCapabilities.windows,
      channel: channel,
      isIOS: false,
    );

    expect(delivery.available, isFalse);
    expect(await delivery.shareFile('ignored.wav'), isFalse);
  });
}
