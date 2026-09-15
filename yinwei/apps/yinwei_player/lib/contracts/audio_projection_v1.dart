/// AudioProjectionV1 — pure Scene V1 → current-engine spatial values.
///
/// No FFI, no EngineController, no widgets, no WebView.
library;

import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/contracts/scene_contract_v1.dart';
import 'package:yinwei_player/contracts/speaker_semantics_v1.dart';

const double kDspDistanceMinM = 0.5;
const double kDspDistanceMaxM = 10.0;

enum AcousticFeedV1 { left, right, mid }

AcousticFeedV1? parseAcousticFeedV1(String name) {
  switch (name.toLowerCase()) {
    case 'left':
      return AcousticFeedV1.left;
    case 'right':
      return AcousticFeedV1.right;
    case 'mid':
      return AcousticFeedV1.mid;
    default:
      return null;
  }
}

String acousticFeedNameV1(AcousticFeedV1 feed) {
  switch (feed) {
    case AcousticFeedV1.left:
      return 'left';
    case AcousticFeedV1.right:
      return 'right';
    case AcousticFeedV1.mid:
      return 'mid';
  }
}

double clampDspDistanceM(double geometricDistanceM) {
  if (geometricDistanceM < kDspDistanceMinM) return kDspDistanceMinM;
  if (geometricDistanceM > kDspDistanceMaxM) return kDspDistanceMaxM;
  return geometricDistanceM;
}

/// Outside-the-scene binding. Never inferred from `visualRole` or list order.
class AudioProjectionConfigV1 {
  const AudioProjectionConfigV1({
    required this.pointSourceId,
    this.emitterBindings = const {},
  });

  /// Explicit source id for the current single point-source engine path.
  final String pointSourceId;

  /// `emitterId` → acoustic feed name (`left` / `right` / `mid` only).
  final Map<String, String> emitterBindings;
}

enum PointSourceStatusV1 {
  projected,
  sourceMissing,
  sourceDisabled,
  sourceInactive,
  invalidScene,
}

enum EmitterSlotStatusV1 {
  projected,
  skippedDisabled,
  skippedInactive,
  failedUnknownEmitter,
  failedInvalidFeed,
}

class PointSourceProjectionV1 {
  const PointSourceProjectionV1({
    required this.sourceId,
    required this.listenerLocal,
    required this.hrtfUnit,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.geometricDistanceM,
    required this.dspDistanceM,
    required this.quaternionStorageOrder,
  });

  final String sourceId;
  final Vec3V1 listenerLocal;
  final Vec3V1 hrtfUnit;
  final double azimuthDeg;
  final double elevationDeg;
  final double geometricDistanceM;
  final double dspDistanceM;

  /// Domain order remains Hamilton `(w, x, y, z)`.
  final List<String> quaternionStorageOrder;
}

class EmitterSlotProjectionV1 {
  const EmitterSlotProjectionV1({
    required this.emitterId,
    required this.status,
    this.feed,
    this.listenerLocal,
    this.hrtfUnit,
    this.azimuthDeg,
    this.elevationDeg,
    this.geometricDistanceM,
    this.dspDistanceM,
    this.visualRole,
  });

  final String emitterId;
  final EmitterSlotStatusV1 status;
  final AcousticFeedV1? feed;
  final Vec3V1? listenerLocal;
  final Vec3V1? hrtfUnit;
  final double? azimuthDeg;
  final double? elevationDeg;
  final double? geometricDistanceM;
  final double? dspDistanceM;
  final String? visualRole;
}

class AudioProjectionResultV1 {
  const AudioProjectionResultV1({
    required this.pointSourceStatus,
    this.pointSource,
    this.reason,
    this.emitterSlots = const [],
  });

  final PointSourceStatusV1 pointSourceStatus;
  final PointSourceProjectionV1? pointSource;
  final String? reason;
  final List<EmitterSlotProjectionV1> emitterSlots;

  bool get isSuccess => pointSourceStatus == PointSourceStatusV1.projected;
}

Vec3V1 _vec3(Map<dynamic, dynamic> m) => Vec3V1(
      (m['x'] as num).toDouble(),
      (m['y'] as num).toDouble(),
      (m['z'] as num).toDouble(),
    );

QuatV1 _quat(Map<dynamic, dynamic>? m) {
  if (m == null) return QuatV1.identity;
  return QuatV1(
    (m['w'] as num).toDouble(),
    (m['x'] as num).toDouble(),
    (m['y'] as num).toDouble(),
    (m['z'] as num).toDouble(),
  ).normalized();
}

ListenerPoseV1 _listenerPose(Map<dynamic, dynamic> listener) {
  return ListenerPoseV1(
    worldPosition: _vec3(listener['worldPosition'] as Map),
    orientation: _quat(listener['orientation'] as Map?),
  );
}

Map<dynamic, dynamic>? _objectById(List<dynamic> items, String id) {
  for (final item in items) {
    if (item is Map && item['id'] == id) return item;
  }
  return null;
}

({
  Vec3V1 listenerLocal,
  Vec3V1 hrtfUnit,
  SphericalV1 spherical,
  double geometricDistanceM,
  double dspDistanceM,
}) _projectWorld(Vec3V1 world, ListenerPoseV1 listener) {
  final local = worldToListenerLocal(world, listener);
  final spherical = localToSpherical(local);
  final geometric = geometricDistanceM(local);
  return (
    listenerLocal: local,
    hrtfUnit: hrtfUnitFromLocal(local),
    spherical: spherical,
    geometricDistanceM: geometric,
    dspDistanceM: clampDspDistanceM(geometric),
  );
}

/// Pure projection. Does not mutate the scene or the audio engine.
class AudioProjectionV1 {
  const AudioProjectionV1._();

  static AudioProjectionResultV1 project({
    required Map<dynamic, dynamic> scene,
    required AudioProjectionConfigV1 config,
  }) {
    final validation = validateSceneV1(scene);
    if (!validation.valid) {
      return AudioProjectionResultV1(
        pointSourceStatus: PointSourceStatusV1.invalidScene,
        reason: validation.reason,
        emitterSlots: _projectEmitters(scene, config, null),
      );
    }
    final listener = _listenerPose(scene['listener'] as Map);
    final emitterSlots = _projectEmitters(scene, config, listener);
    final sourceId = config.pointSourceId;
    if (sourceId.isEmpty) {
      return AudioProjectionResultV1(
        pointSourceStatus: PointSourceStatusV1.sourceMissing,
        reason: 'source_missing',
        emitterSlots: emitterSlots,
      );
    }
    final sources = scene['sources'] as List;
    final source = _objectById(sources, sourceId);
    if (source == null) {
      return AudioProjectionResultV1(
        pointSourceStatus: PointSourceStatusV1.sourceMissing,
        reason: 'source_missing',
        emitterSlots: emitterSlots,
      );
    }
    if (source['enabled'] != true) {
      return AudioProjectionResultV1(
        pointSourceStatus: PointSourceStatusV1.sourceDisabled,
        reason: 'source_disabled',
        emitterSlots: emitterSlots,
      );
    }
    if (source['active'] != true) {
      return AudioProjectionResultV1(
        pointSourceStatus: PointSourceStatusV1.sourceInactive,
        reason: 'source_inactive',
        emitterSlots: emitterSlots,
      );
    }
    final posed = _projectWorld(_vec3(source['worldPosition'] as Map), listener);
    return AudioProjectionResultV1(
      pointSourceStatus: PointSourceStatusV1.projected,
      pointSource: PointSourceProjectionV1(
        sourceId: sourceId,
        listenerLocal: posed.listenerLocal,
        hrtfUnit: posed.hrtfUnit,
        azimuthDeg: posed.spherical.azimuthDeg,
        elevationDeg: posed.spherical.elevationDeg,
        geometricDistanceM: posed.geometricDistanceM,
        dspDistanceM: posed.dspDistanceM,
        quaternionStorageOrder: const ['w', 'x', 'y', 'z'],
      ),
      emitterSlots: emitterSlots,
    );
  }

  static List<EmitterSlotProjectionV1> _projectEmitters(
    Map<dynamic, dynamic> scene,
    AudioProjectionConfigV1 config,
    ListenerPoseV1? listener,
  ) {
    final emitters = scene['emitters'];
    final list = emitters is List ? emitters : const [];
    final slots = <EmitterSlotProjectionV1>[];
    for (final entry in config.emitterBindings.entries) {
      final feed = parseAcousticFeedV1(entry.value);
      if (feed == null || !SpeakerSemanticsV1.isAcousticFeed(entry.value)) {
        slots.add(EmitterSlotProjectionV1(
          emitterId: entry.key,
          status: EmitterSlotStatusV1.failedInvalidFeed,
        ));
        continue;
      }
      final obj = _objectById(list, entry.key);
      if (obj == null) {
        slots.add(EmitterSlotProjectionV1(
          emitterId: entry.key,
          status: EmitterSlotStatusV1.failedUnknownEmitter,
          feed: feed,
        ));
        continue;
      }
      final visualRole = obj['visualRole'] is String ? obj['visualRole'] as String : null;
      if (obj['enabled'] != true) {
        slots.add(EmitterSlotProjectionV1(
          emitterId: entry.key,
          status: EmitterSlotStatusV1.skippedDisabled,
          feed: feed,
          visualRole: visualRole,
        ));
        continue;
      }
      if (obj['active'] != true) {
        slots.add(EmitterSlotProjectionV1(
          emitterId: entry.key,
          status: EmitterSlotStatusV1.skippedInactive,
          feed: feed,
          visualRole: visualRole,
        ));
        continue;
      }
      if (listener == null) {
        slots.add(EmitterSlotProjectionV1(
          emitterId: entry.key,
          status: EmitterSlotStatusV1.failedUnknownEmitter,
          feed: feed,
          visualRole: visualRole,
        ));
        continue;
      }
      final posed = _projectWorld(_vec3(obj['worldPosition'] as Map), listener);
      slots.add(EmitterSlotProjectionV1(
        emitterId: entry.key,
        status: EmitterSlotStatusV1.projected,
        feed: feed,
        listenerLocal: posed.listenerLocal,
        hrtfUnit: posed.hrtfUnit,
        azimuthDeg: posed.spherical.azimuthDeg,
        elevationDeg: posed.spherical.elevationDeg,
        geometricDistanceM: posed.geometricDistanceM,
        dspDistanceM: posed.dspDistanceM,
        visualRole: visualRole,
      ));
    }
    return slots;
  }
}
