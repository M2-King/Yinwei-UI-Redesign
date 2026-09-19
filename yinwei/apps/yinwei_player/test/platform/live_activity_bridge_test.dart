import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/platform/live_activity_bridge.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/presentation/yinwei_live_presentation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const presentation = YinweiLivePresentation(
    title: 'Across the Room',
    playing: true,
    spatialMode: PlaybackMode.spatial,
    motionMode: MotionMode.orbit,
    azimuthDeg: 41.4,
    elevationDeg: -8.2,
    distanceM: 1.8,
    orbiting: true,
  );

  test('LiveActivityBridge is unavailable off iOS', () {
    final bridge = LiveActivityBridge.create(
      capabilities: PlatformCapabilities.ios,
    );
    expect(bridge.available, isFalse);
  });

  test('unavailable bridge start/update/end are no-ops', () async {
    final bridge = LiveActivityBridge.create(
      capabilities: PlatformCapabilities.windows,
    );
    await bridge.start(presentation);
    await bridge.update(presentation);
    await bridge.end();
    expect(bridge.available, isFalse);
  });

  test('start/update/end serialize a stable Live Activity payload', () async {
    const channel = MethodChannel(LiveActivityBridge.channelName);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final bridge = MethodChannelLiveActivityBridge();
    expect(bridge.available, isTrue);
    await bridge.start(presentation);
    await bridge.update(presentation);
    await bridge.end();

    expect(calls.map((c) => c.method), ['start', 'update', 'end']);
    final payload = Map<String, dynamic>.from(calls.first.arguments as Map);
    expect(payload.keys, containsAll([
      'title',
      'playing',
      'spatialMode',
      'motionMode',
      'azimuthDeg',
      'elevationDeg',
      'distanceM',
      'orbiting',
    ]));
    expect(payload['title'], 'Across the Room');
    expect(payload['playing'], isTrue);
    expect(payload['spatialMode'], 'spatial');
    expect(payload['motionMode'], 'orbit');
    expect(payload['azimuthDeg'], 41.4);
    expect(payload['elevationDeg'], -8.2);
    expect(payload['distanceM'], 1.8);
    expect(payload['orbiting'], isTrue);
    expect(calls[2].arguments, isNull);
  });
}
