import 'dart:async';
import 'dart:convert';

import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/runtime/orbit_pose_math.dart';
import 'package:yinwei_player/state/engine_controller.dart';

/// An adapter around the owning app's existing controllers, never a new engine
/// or spatial store. This first remote capability is file/Point control only.
class AppSessionCoordinator {
  AppSessionCoordinator({
    required this.controller,
    required this.spatial,
    required this.nativeBackend,
    required this.liveRunning,
    this.liveAudioReady,
    this.liveSnapshot,
    this.sceneBridge,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final EngineController controller;
  final SpatialRuntimeAdapter spatial;
  final bool nativeBackend;
  final bool Function() liveRunning;
  final bool Function()? liveAudioReady;
  final Map<String, dynamic> Function()? liveSnapshot;
  bool get liveReady => liveAudioReady?.call() ?? liveRunning();
  final SpatialSceneBridge? sceneBridge;
  final DateTime Function() _now;
  final String hostSessionId = remoteSecret();
  final _results = <String, Future<Map<String, dynamic>>>{};
  final _fingerprints = <String, String>{};
  final _media = <String, ({String path, String title})>{};
  Future<void> _commands = Future<void>.value();
  String? _device;
  String? _lease;
  DateTime? _expires;
  int _localGeneration = 0;
  int _stateVersion = 0;
  String? _lastFingerprint;
  bool _closed = false;
  bool _remoteApplying = false;
  String? lastCommandStatus;
  bool browserAudioAvailable = false;
  bool browserLiveAudioAvailable = false;

  void registerLocalMedia(String path, String title) {
    if (_media.values.any((media) => media.path == path)) return;
    if (_media.length >= 32) _media.remove(_media.keys.first);
    _media[remoteSecret(16)] = (path: path, title: title);
  }

  List<Map<String, String>> get media => _media.entries
      .map((entry) => {'id': entry.key, 'title': entry.value.title})
      .toList();

  void takeLocalControl() {
    ++_localGeneration;
    _device = null;
    _lease = null;
    _expires = null;
  }

  void releaseDevice(String device) {
    if (_device == device) takeLocalControl();
  }

  Map<String, dynamic> acquireControl(String device) {
    if (_closed) throw const RemoteFailure('host_closed');
    if (!nativeBackend) throw const RemoteFailure('native_engine_required');
    if (liveRunning() || controller.busy) {
      throw const RemoteFailure('local_busy');
    }
    if (_device != null && _expires!.isAfter(_now()) && _device != device) {
      throw const RemoteFailure('control_busy');
    }
    if (_device != device || !_expires!.isAfter(_now())) {
      _lease = remoteSecret();
    }
    _device = device;
    _expires = _now().add(const Duration(seconds: 30));
    return {'controlLeaseId': _lease, 'expiresInSeconds': 30};
  }

  Map<String, dynamic> snapshot({String? device}) {
    final liveActive = liveRunning();
    final liveInfo = liveSnapshot?.call() ?? const <String, dynamic>{};
    final fingerprint = jsonEncode({
      'sceneRevision': spatial.appliedRevision,
      'params': [
        controller.params.azimuthDeg,
        controller.params.elevationDeg,
        controller.params.distanceM,
        controller.params.motion.name
      ],
      'array': controller.runtimeAudioDiag()['speakers'],
      'arrayMode': controller.array.mode.name,
      'path': controller.track.path,
      'playing': controller.playing,
      'mode': controller.mode.name,
      'busy': controller.busy,
      'liveRunning': liveActive,
      'liveReady': liveReady,
      'liveSource': liveInfo['source'],
    });
    if (fingerprint != _lastFingerprint) {
      if (_lastFingerprint != null && !_remoteApplying) takeLocalControl();
      _lastFingerprint = fingerprint;
      ++_stateVersion;
    }
    return {
      'protocolVersion': 1,
      'hostSessionId': hostSessionId,
      'stateVersion': _stateVersion,
      'sceneRevision': spatial.appliedRevision,
      'scene': spatial.snapshot(),
      'nativeBackend': nativeBackend,
      'capabilities': {
        'pointControl': !controller.array.enabled,
        'browserAudio': browserAudioAvailable,
        'browserLiveAudio': browserLiveAudioAvailable,
        'remoteArray': false
      },
      'track': {
        'title': controller.track.title,
        'artist': controller.track.artist,
        'hasFile': controller.hasOpenedFile,
        'durationMs': controller.track.duration.inMilliseconds
      },
      'transport': {
        'playing': controller.playing,
        'positionMs': controller.position.inMilliseconds,
        'mode': controller.mode.name,
        'busy': controller.busy
      },
      'pose': {
        'azimuthDeg': controller.params.azimuthDeg,
        'elevationDeg': controller.params.elevationDeg,
        'distanceM': controller.params.distanceM
      },
      'telemetry': {
        'type': 'playbackTelemetry',
        'playing': controller.playing,
        'playhead': controller.playhead,
        'azimuthDeg': controller.azimuthDeg,
        'elevationDeg': controller.elevationDeg,
        'orbiting': controller.params.motion == MotionMode.orbit,
        'active': true
      },
      'controlHeld': _device != null && _expires!.isAfter(_now()),
      'controlOwned':
          device != null && device == _device && _expires!.isAfter(_now()),
      'lastCommandStatus': lastCommandStatus,
      'media': media,
      'liveRunning': liveActive,
      'audioSource':
          liveActive ? (liveReady ? 'live' : 'live_starting') : 'file',
      'live': {
        'ready': liveActive && liveReady,
        'source': liveInfo['source'] is String ? liveInfo['source'] : '',
        'title': liveInfo['title'] is String ? liveInfo['title'] : '',
        'captureHealthy': liveInfo['captureHealthy'] == true,
        'remoteControls': false,
      },
    };
  }

  Future<Map<String, dynamic>> command(
      String device, Map<String, dynamic> input) {
    final id = input['commandId'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(id)) {
      throw const RemoteFailure('invalid_command_id', httpStatus: 400);
    }
    final key = '$device:$id';
    final encoded = jsonEncode(input);
    if (_results.containsKey(key)) {
      if (_fingerprints[key] != encoded) {
        throw const RemoteFailure('command_id_reused');
      }
      return _results[key]!;
    }
    if (_results.length >= 128) {
      // Never evict an in-flight operation. Completed entries are removed below.
      throw const RemoteFailure('command_cache_full', httpStatus: 429);
    }
    final localGeneration = _localGeneration;
    final result = _commands.catchError((Object _) {}).then((_) async {
      if (_closed) throw const RemoteFailure('host_closed');
      snapshot();
      if (input['protocolVersion'] != 1 ||
          input['hostSessionId'] != hostSessionId) {
        throw const RemoteFailure('stale_host');
      }
      if (_device != device ||
          _lease != input['controlLeaseId'] ||
          !_expires!.isAfter(_now()) ||
          localGeneration != _localGeneration) {
        throw const RemoteFailure('control_lost');
      }
      if (input['expectedStateVersion'] != _stateVersion ||
          input['expectedSceneRevision'] != spatial.appliedRevision) {
        throw const RemoteFailure('stale_state');
      }
      if (liveRunning() || controller.busy) {
        throw const RemoteFailure('local_busy');
      }
      final payload = input['payload'];
      if (payload is! Map<String, dynamic>) {
        throw const RemoteFailure('invalid_payload', httpStatus: 400);
      }
      _remoteApplying = true;
      try {
        switch (input['type']) {
          case 'open':
            final media = _media[payload['mediaId']];
            if (media == null) {
              throw const RemoteFailure('unknown_media', httpStatus: 404);
            }
            await controller.openPath(media.path);
            if (controller.lastError != null) {
              throw const RemoteFailure('engine_failed');
            }
          case 'play':
            if (!controller.hasOpenedFile) {
              throw const RemoteFailure('no_track');
            }
            await controller.play();
            if (controller.lastError != null) {
              throw const RemoteFailure('engine_failed');
            }
          case 'pause':
            await controller.pause();
          case 'seek':
            if (!controller.hasOpenedFile) {
              throw const RemoteFailure('no_track');
            }
            final ms = remoteNumber(payload, 'positionMs', 0,
                controller.track.duration.inMilliseconds);
            await controller.seek(Duration(milliseconds: ms.round()));
          case 'mode':
            if (!['original', 'spatial'].contains(payload['mode'])) {
              throw const RemoteFailure('invalid_payload', httpStatus: 400);
            }
            await controller.setMode(payload['mode'] == 'original'
                ? PlaybackMode.original
                : PlaybackMode.spatial);
          case 'point.set':
            if (controller.array.enabled) {
              throw const RemoteFailure('array_active');
            }
            final params = controller.params.copy()
              ..azimuthDeg =
                  remoteNumber(payload, 'azimuthDeg', -180, 180).toDouble()
              ..elevationDeg =
                  remoteNumber(payload, 'elevationDeg', -90, 90).toDouble()
              ..distanceM =
                  remoteNumber(payload, 'distanceM', 0.5, 10).toDouble()
              ..motion = MotionMode.fixed
              ..selectedPreset = null;
            final adopted = spatial.adoptPointParams(params);
            if (!adopted.shouldWriteEngine) {
              throw const RemoteFailure('invalid_scene');
            }
            await controller.setParamsAcknowledged(adopted.engineParams!);
          case 'scene.commit':
            if (sceneBridge == null ||
                controller.array.enabled ||
                payload['type'] != 'sourcePoseCommit') {
              throw const RemoteFailure('unsupported_scene_intent',
                  httpStatus: 400);
            }
            final position = payload['worldPosition'];
            if (position is! Map<String, dynamic>) {
              throw const RemoteFailure('invalid_payload', httpStatus: 400);
            }
            for (final axis in ['x', 'y', 'z']) {
              remoteNumber(position, axis, -100, 100);
            }
            final raw = OrbitPoseMath.rewritePointIntent(
                raw: jsonEncode(payload),
                scene: spatial.snapshot()!,
                elapsed: controller.position,
                orbitHz: controller.params.orbitHz,
                overlayActive: controller.playing &&
                    controller.params.motion == MotionMode.orbit);
            final adopted = sceneBridge!.handleMessage(raw);
            if (!adopted.accepted) {
              throw RemoteFailure(adopted.reason ?? 'invalid_scene');
            }
            if (adopted.shouldWriteEngine) {
              final projected = adopted.engineParams!;
              final next = controller.params.copy()
                ..azimuthDeg = projected.azimuthDeg
                ..elevationDeg = projected.elevationDeg
                ..distanceM = projected.distanceM
                ..selectedPreset = null;
              await controller.setParamsAcknowledged(next);
            }
          default:
            throw const RemoteFailure('unsupported_command', httpStatus: 400);
        }
        lastCommandStatus = localGeneration == _localGeneration
            ? 'native_applied'
            : 'superseded';
        return {
          'commandId': id,
          'status': lastCommandStatus,
          'snapshot': snapshot(device: device)
        };
      } catch (_) {
        lastCommandStatus = 'failed';
        snapshot();
        rethrow;
      } finally {
        _remoteApplying = false;
      }
    });
    _commands =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _results[key] = result;
    _fingerprints[key] = encoded;
    // Keep bounded deduplication history for retries, including failures.
    result.then<void>((_) => _trimHistory(),
        onError: (Object _, StackTrace __) => _trimHistory());
    return result;
  }

  void _trimHistory() {
    if (_results.length > 64) {
      final key = _results.keys.first;
      _results.remove(key);
      _fingerprints.remove(key);
    }
  }

  Future<void> close() async {
    _closed = true;
    takeLocalControl();
    await _commands;
  }
}
