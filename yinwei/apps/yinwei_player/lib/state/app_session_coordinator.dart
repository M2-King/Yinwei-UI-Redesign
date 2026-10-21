import 'dart:async';
import 'dart:convert';

import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/runtime/orbit_pose_math.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';
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
    this.applyLiveParams,
    this.applyLiveMode,
    this.liveMedia,
    this.libraryPlay,
    this.libraryList,
    this.liveSeek,
    this.startLive,
    this.stopLive,
    this.applyArrayMode,
    this.applyArrayLayout,
    this.liveArraySpeakersAvailable,
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

  /// Live Transfer hooks. When both are supplied, a remote with the control
  /// lease may change the live source's position and Original/Spatial mode
  /// through the same path as the laptop's own controls. Live start/stop and
  /// source choice stay on the laptop; file transport is unavailable.
  final Future<void> Function(SpatialParams params)? applyLiveParams;
  final Future<void> Function(PlaybackMode mode)? applyLiveMode;
  bool get liveControl => applyLiveParams != null && applyLiveMode != null;
  static const _liveCommands = {
    'mode',
    'point.set',
    'scene.commit',
    'live.start',
    'live.stop',
    'array.mode',
    'array.speaker.add',
    'array.speaker.remove',
    'array.speaker.select',
    'array.speaker.set',
    'motion.set',
    'media.seek',
    'library.play',
  };

  /// Start/stop Live Transfer from the remote, through the same path as the
  /// laptop's Live button (start also plays the music app if it is paused).
  /// Throw [RemoteFailure] for reasons the page should show.
  final Future<void> Function()? startLive;
  final Future<void> Function()? stopLive;
  bool get remoteLive => startLive != null && stopLive != null;

  /// Point / Stereo 2.0, through the same steps as the laptop's mode
  /// switch (file engine, plus Live Transfer while it runs).
  final Future<void> Function(ArrayMode mode)? applyArrayMode;
  final Future<void> Function(ArrayLayout layout)? applyArrayLayout;
  final bool Function()? liveArraySpeakersAvailable;
  int _arrayRevision = 0;
  String? _lastArrayFingerprint;

  Map<String, dynamic> _arrayState() {
    final a = controller.array;
    return {
      'mode': a.mode.name,
      'selectedIndex': a.selectedIndex,
      'matrixLinked': a.matrixLinked,
      'matrixSpread': a.matrixSpread,
      'speakers': [
        for (var i = 0; i < a.speakers.length; i++)
          {
            'index': i,
            'label': a.speakers[i].label,
            'az': a.speakers[i].azimuthDeg,
            'el': a.speakers[i].elevationDeg,
            'dist': a.speakers[i].distanceM,
            'gainDb': a.speakers[i].gainDb,
            'mute': a.speakers[i].mute,
            'feed': a.speakers[i].feed.name,
          },
      ],
    };
  }

  /// Play/pause/next/previous for the Live source app through Windows media
  /// controls. It drives the music app only; the audio engine is untouched.
  final Future<void> Function(String action)? liveMedia;

  /// Cached Soda selection only. The callback resolves catalog/account state,
  /// then calls [beforeDispatch] immediately before its one external launch.
  final Future<void> Function(
          Map<String, dynamic> payload, void Function() beforeDispatch)?
      libraryPlay;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> request)?
      libraryList;
  static const _mediaActions = {
    'media.play': 'play',
    'media.pause': 'pause',
    'media.next': 'next',
    'media.previous': 'previous',
  };

  /// Jump within the Live source app's song (seconds), through Windows
  /// media controls; the music app decides whether it allows it.
  final Future<void> Function(double seconds)? liveSeek;
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
  String? _lastControlFingerprint;
  bool _closed = false;
  bool _remoteApplying = false;
  String? lastCommandStatus;
  bool browserAudioAvailable = false;
  bool browserLiveAudioAvailable = false;
  bool remoteTransformRunning = false;

  void setRemoteTransformRunning(bool value) {
    if (remoteTransformRunning == value) return;
    remoteTransformRunning = value;
    takeLocalControl();
  }

  void registerLocalMedia(String path, String title) {
    if (_media.values.any((media) => media.path == path)) return;
    if (_media.length >= 32) _media.remove(_media.keys.first);
    _media[remoteSecret(16)] = (path: path, title: title);
  }

  List<Map<String, String>> get media => _media.entries
      .map((entry) => {'id': entry.key, 'title': entry.value.title})
      .toList();

  // The device the laptop last took control from. Its page may re-take
  // control on its own after a pause, but not after a laptop takeover;
  // tapping Take control there still works.
  String? _takenFrom;

  void takeLocalControl() {
    ++_localGeneration;
    if (_device != null) _takenFrom = _device;
    _device = null;
    _lease = null;
    _expires = null;
  }

  void releaseDevice(String device) {
    if (_device == device) takeLocalControl();
    if (_takenFrom == device) _takenFrom = null;
  }

  /// [auto]: the page re-taking control it had (after iPad Safari paused
  /// it), refused once the laptop has taken over.
  Map<String, dynamic> acquireControl(String device, {bool auto = false}) {
    if (_closed) throw const RemoteFailure('host_closed');
    if (!nativeBackend) throw const RemoteFailure('native_engine_required');
    if ((liveRunning() && !liveControl) ||
        remoteTransformRunning ||
        controller.busy) {
      throw const RemoteFailure('local_busy');
    }
    if (_device != null && _expires!.isAfter(_now()) && _device != device) {
      throw const RemoteFailure('control_busy');
    }
    if (auto && _takenFrom == device) {
      throw const RemoteFailure('control_taken');
    }
    if (_takenFrom == device) _takenFrom = null;
    if (_device != device || !_expires!.isAfter(_now())) {
      _lease = remoteSecret();
    }
    _device = device;
    _expires = _now().add(const Duration(seconds: 30));
    return {'controlLeaseId': _lease, 'expiresInSeconds': 30};
  }

  Map<String, dynamic> snapshot({String? device}) {
    final arrayState = _arrayState();
    final arrayFingerprint = jsonEncode(arrayState);
    if (arrayFingerprint != _lastArrayFingerprint) {
      _lastArrayFingerprint = arrayFingerprint;
      ++_arrayRevision;
    }
    final liveActive = liveRunning();
    final liveInfo = liveSnapshot?.call() ?? const <String, dynamic>{};
    // Settings a person changes. If one changes at the laptop (not by the
    // remote), the laptop has taken over and the remote loses its lease.
    final controlFingerprint = jsonEncode({
      'sceneRevision': spatial.appliedRevision,
      'params': [
        controller.params.azimuthDeg,
        controller.params.elevationDeg,
        controller.params.distanceM,
        controller.params.motion.name,
        controller.params.orbitHz
      ],
      'array': arrayState,
      'arrayMode': controller.array.mode.name,
      'path': controller.track.path,
      'mode': controller.mode.name,
    });
    // Everything else changes by itself (song change, Live re-attaching to
    // the music app, playback ending): it refreshes the state version but
    // must not take control away from the remote.
    final fingerprint = jsonEncode({
      'control': controlFingerprint,
      'playing': controller.playing,
      'busy': controller.busy,
      'liveRunning': liveActive,
      'remoteTransformRunning': remoteTransformRunning,
      'liveReady': liveReady,
      'liveSource': liveInfo['source'],
    });
    if (controlFingerprint != _lastControlFingerprint) {
      if (_lastControlFingerprint != null && !_remoteApplying) {
        takeLocalControl();
      }
      _lastControlFingerprint = controlFingerprint;
    }
    if (fingerprint != _lastFingerprint) {
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
        'pointControl': !controller.array.enabled && !remoteTransformRunning,
        'browserAudio': browserAudioAvailable,
        'browserLiveAudio': browserLiveAudioAvailable,
        'liveControl': liveControl,
        'liveMedia': liveMedia != null,
        'sodaLibrary': libraryPlay != null && libraryList != null,
        'remoteLive': remoteLive,
        'remoteArray': applyArrayMode != null,
        'remoteSpeakers': applyArrayLayout != null &&
            controller.arraySupported &&
            controller.extraSpeakersSupported &&
            (!liveActive || liveArraySpeakersAvailable?.call() == true),
        'liveSeek': liveSeek != null
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
      // What the laptop's mode and Orbit controls show, plus the 3D view's
      // presentation (Point source, or the 2.0 L/R speakers).
      'spatialMode': {
        'array': controller.array.enabled ? 'stereo2' : 'point',
        'motion': controller.params.motion.name,
        'orbitHz': controller.params.orbitHz,
      },
      'presentation': _presentation(),
      'arrayState': {
        ...arrayState,
        'revision': _arrayRevision,
        'maxSpeakers': ArrayLayout.maxSpeakers
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
      'audioSource': remoteTransformRunning
          ? 'remote_ipad'
          : liveActive
              ? (liveReady ? 'live' : 'live_starting')
              : 'file',
      'live': {
        'ready': liveActive && liveReady,
        'source': liveInfo['source'] is String ? liveInfo['source'] : '',
        'title': liveInfo['title'] is String ? liveInfo['title'] : '',
        'captureHealthy': liveInfo['captureHealthy'] == true,
        'playing': liveInfo['playing'] == true,
        // The music app a remote "Start on laptop" opens when none is open
        // (the laptop picks it); '' when it can't open one.
        'openApp': liveInfo['openApp'] is String ? liveInfo['openApp'] : '',
        // The music app's song position and length (seconds), as Windows
        // media controls report them; 0 when unknown.
        'positionSec': _seconds(liveInfo['positionSec']),
        'durationSec': _seconds(liveInfo['durationSec']),
        // Where the sound is now (Orbit moves it); null while Live is off.
        'azimuthDeg': liveInfo['azimuthDeg'] is num &&
                (liveInfo['azimuthDeg'] as num).isFinite
            ? liveInfo['azimuthDeg']
            : null,
        // Remote start progress: opening / pressing / starting, or ''.
        'startStage': const {'opening', 'pressing', 'starting'}
                .contains(liveInfo['startStage'])
            ? liveInfo['startStage']
            : '',
        'remoteControls': false,
      },
    };
  }

  Future<Map<String, dynamic>> _readLibrary(Map<String, dynamic> input) async {
    if (_closed) throw const RemoteFailure('host_closed');
    if (input['protocolVersion'] != 1 ||
        input['hostSessionId'] != hostSessionId) {
      throw const RemoteFailure('stale_host');
    }
    final browse = libraryList;
    if (browse == null) throw const RemoteFailure('soda_unavailable');
    final payload = input['payload'];
    if (payload is! Map<String, dynamic> ||
        payload.keys.any((k) =>
            !const ['list', 'snapshot', 'offset', 'revision'].contains(k))) {
      throw const RemoteFailure('invalid_payload', httpStatus: 400);
    }
    final library = await browse(payload);
    if (_closed) throw const RemoteFailure('host_closed');
    return {
      'commandId': input['commandId'],
      'status': 'read',
      'library': library
    };
  }

  Future<Map<String, dynamic>> command(
      String device, Map<String, dynamic> input) {
    final id = input['commandId'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(id)) {
      throw const RemoteFailure('invalid_command_id', httpStatus: 400);
    }
    // Browsing is owner-authenticated at the existing command endpoint, but
    // never takes a playback lease. Re-read even on a transport retry so cached
    // command responses cannot cross a provider account change.
    if (input['type'] == 'library.list') return _readLibrary(input);
    final key = '$device:$id';
    final encoded = jsonEncode(input);
    if (_results.containsKey(key)) {
      if (_fingerprints[key] != encoded) {
        throw const RemoteFailure('command_id_reused');
      }
      if ((input['type'] as String?)?.startsWith('array.speaker.') == true) {
        return _results[key]!.then((result) {
          snapshot();
          final applied = (result['snapshot'] as Map)['arrayState'] as Map;
          // An identical retry is idempotent only while its resulting array
          // is still current. Never return an obsolete shifted-index snapshot.
          if (applied['revision'] != _arrayRevision) {
            throw const RemoteFailure('stale_array');
          }
          return result;
        });
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
      final live = liveRunning();
      if ((live && !liveControl) || remoteTransformRunning || controller.busy) {
        throw const RemoteFailure('local_busy');
      }
      final media = _mediaActions[input['type']];
      // Music-app commands also work before Live starts, so the remote can
      // get the laptop playing.
      if (media != null && liveMedia == null) {
        throw const RemoteFailure('live_media_unavailable');
      }
      if (live && media == null && !_liveCommands.contains(input['type'])) {
        throw const RemoteFailure('live_transport_on_laptop');
      }
      final payload = input['payload'];
      if (payload is! Map<String, dynamic>) {
        throw const RemoteFailure('invalid_payload', httpStatus: 400);
      }
      _remoteApplying = true;
      try {
        switch (input['type']) {
          case 'library.play':
            final dispatch = libraryPlay;
            if (dispatch == null) {
              throw const RemoteFailure('soda_unavailable');
            }
            await dispatch(payload, () {
              snapshot();
              if (_closed || input['hostSessionId'] != hostSessionId) {
                throw const RemoteFailure('stale_host');
              }
              if (_device != device ||
                  _lease != input['controlLeaseId'] ||
                  _expires == null ||
                  !_expires!.isAfter(_now()) ||
                  localGeneration != _localGeneration) {
                throw const RemoteFailure('control_lost');
              }
              if (remoteTransformRunning ||
                  controller.busy ||
                  (liveRunning() && !liveControl)) {
                throw const RemoteFailure('local_busy');
              }
            });
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
          case 'live.start':
            if (!remoteLive) {
              throw const RemoteFailure('unsupported_command', httpStatus: 400);
            }
            if (!live) {
              try {
                await startLive!();
              } on RemoteFailure {
                rethrow;
              } catch (_) {
                throw const RemoteFailure('live_start_failed');
              }
            }
          case 'live.stop':
            if (!remoteLive) {
              throw const RemoteFailure('unsupported_command', httpStatus: 400);
            }
            if (live) await stopLive!();
          case 'media.seek':
            if (liveSeek == null) {
              throw const RemoteFailure('unsupported_command', httpStatus: 400);
            }
            final seconds = remoteNumber(payload, 'positionSec', 0, 24 * 3600);
            try {
              await liveSeek!(seconds.toDouble());
            } catch (_) {
              throw const RemoteFailure('media_command_failed');
            }
          case 'media.play':
          case 'media.pause':
          case 'media.next':
          case 'media.previous':
            try {
              await liveMedia!(media!);
            } catch (_) {
              // The music app refused or no session: not an engine failure,
              // and the remote keeps its lease.
              throw const RemoteFailure('media_command_failed');
            }
          case 'mode':
            if (!['original', 'spatial'].contains(payload['mode'])) {
              throw const RemoteFailure('invalid_payload', httpStatus: 400);
            }
            final mode = payload['mode'] == 'original'
                ? PlaybackMode.original
                : PlaybackMode.spatial;
            if (live) {
              await applyLiveMode!(mode);
            } else {
              await controller.setMode(mode);
            }
          case 'array.mode':
            final arrayMode = switch (payload['mode']) {
              'point' => ArrayMode.off,
              'stereo2' => ArrayMode.stereo2,
              _ =>
                throw const RemoteFailure('invalid_payload', httpStatus: 400),
            };
            if (applyArrayMode == null) {
              throw const RemoteFailure('unsupported_command', httpStatus: 400);
            }
            await applyArrayMode!(arrayMode);
          case 'array.speaker.add':
          case 'array.speaker.remove':
          case 'array.speaker.select':
          case 'array.speaker.set':
            if (applyArrayLayout == null ||
                !controller.arraySupported ||
                !controller.extraSpeakersSupported ||
                (live && liveArraySpeakersAvailable?.call() != true)) {
              throw const RemoteFailure('unsupported_command', httpStatus: 400);
            }
            if (!controller.array.enabled) {
              throw const RemoteFailure('array_inactive');
            }
            // Required even when the general state version was refreshed by a
            // retry. Index identities are valid only within this array revision.
            if (payload['arrayRevision'] is! int ||
                payload['arrayRevision'] != _arrayRevision) {
              throw const RemoteFailure('stale_array');
            }
            final next = controller.array.copy();
            final type = input['type'];
            if (type == 'array.speaker.add') {
              if (!next.canAddSpeaker) {
                throw const RemoteFailure('speaker_limit');
              }
              next.addSpeaker();
            } else {
              final index = payload['index'];
              if (index is! int || index < 0 || index >= next.speakers.length) {
                throw const RemoteFailure('invalid_payload', httpStatus: 400);
              }
              next.selectedIndex = index;
              if (type == 'array.speaker.remove') {
                if (!next.canRemoveSelected) {
                  throw const RemoteFailure('speaker_protected');
                }
                next.removeSelected();
              } else if (type == 'array.speaker.set') {
                final az = remoteNumber(payload, 'az', -180, 180).toDouble();
                final el = remoteNumber(payload, 'el', -90, 90).toDouble();
                final dist = remoteNumber(payload, 'dist', 0.5, 10).toDouble();
                if (next.matrixLinked) {
                  next.moveSelectedInGroup(azimuthDeg: az, elevationDeg: el);
                  next.setAllDistance(dist);
                } else {
                  next.selected.azimuthDeg = az;
                  next.selected.elevationDeg = el;
                  next.selected.distanceM = dist;
                }
              }
            }
            if (type == 'array.speaker.select') {
              await controller.selectArraySpeaker(next.selectedIndex);
            } else {
              await applyArrayLayout!(next);
            }
          case 'motion.set':
            // Orbit moves the single Point source; the laptop disables it in
            // 2.0 too.
            if (controller.array.enabled) {
              throw const RemoteFailure('array_active');
            }
            final motion = switch (payload['motion']) {
              'fixed' => MotionMode.fixed,
              'orbit' => MotionMode.orbit,
              _ =>
                throw const RemoteFailure('invalid_payload', httpStatus: 400),
            };
            final next = controller.params.copy()..motion = motion;
            if (payload.containsKey('orbitHz')) {
              next.orbitHz =
                  remoteNumber(payload, 'orbitHz', 0.05, 2).toDouble();
            }
            final adopted = spatial.adoptPointParams(next);
            if (!adopted.shouldWriteEngine) {
              throw const RemoteFailure('invalid_scene');
            }
            await _applyParams(adopted.engineParams!, live: live);
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
            await _applyParams(adopted.engineParams!, live: live);
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
              await _applyParams(next, live: live);
            }
          default:
            throw const RemoteFailure('unsupported_command', httpStatus: 400);
        }
        lastCommandStatus = localGeneration == _localGeneration
            ? (input['type'] == 'library.play' ? 'submitted' : 'native_applied')
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

  Map<String, dynamic> _presentation() {
    final kind = workspacePresentationOf(
      playbackMode: controller.mode,
      arrayMode: controller.array.mode,
    );
    final selected = controller.array.selectedIndex;
    return {
      'type': 'presentationState',
      'presentation': kind.name,
      'selectedSpeakerIndex': selected,
      'arraySpeakers': kind == WorkspacePresentation.stereo2
          ? arraySpeakerVisuals(
              speakers: controller.array.speakers,
              selectedIndex: selected,
            ).map((s) => s.toJson()).toList()
          : const <Map<String, dynamic>>[],
    };
  }

  Future<void> _applyParams(SpatialParams params, {required bool live}) => live
      ? applyLiveParams!(params)
      : controller.setParamsAcknowledged(params);

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

  static double _seconds(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.toDouble() : 0;
}
