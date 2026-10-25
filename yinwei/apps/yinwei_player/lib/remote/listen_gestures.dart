import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class GestureSettingsStore {
  Future<Map<String, bool>> load();
  Future<void> save(Map<String, bool> value);
}

/// Same application-support storage as listen_sound_quality; never a laptop setting.
class FileGestureSettingsStore implements GestureSettingsStore {
  FileGestureSettingsStore({required this.directoryProvider});
  final Future<Directory> Function() directoryProvider;

  Future<File> _file() async => File(
      '${(await directoryProvider()).path}${Platform.pathSeparator}listen_gestures.json');

  @override
  Future<Map<String, bool>> load() async {
    try {
      final value = jsonDecode(await (await _file()).readAsString());
      if (value is Map) {
        return {'on': value['on'] == true, 'consent': value['consent'] == true};
      }
    } catch (_) {
      // Missing, corrupt or inaccessible settings always default to camera off.
    }
    return {'on': false, 'consent': false};
  }

  @override
  Future<void> save(Map<String, bool> value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(value), flush: true);
  }
}

/// Owns camera permission, local preference and the camera lifetime, never playback.
/// Remembered "on" is a preference, not permission to reopen the camera after a pause.
class ListenGestures extends ChangeNotifier {
  ListenGestures({
    required this.store,
    MethodChannel? methods,
    Stream<Object?>? events,
  })  : _methods = methods ?? const MethodChannel(channelName),
        _events = events ??
            const EventChannel('$channelName/frames').receiveBroadcastStream();

  static const channelName = 'dev.yinwei/hand_gestures';
  final GestureSettingsStore store;
  final MethodChannel _methods;
  final Stream<Object?> _events;
  StreamSubscription<Object?>? _subscription;
  void Function(Map<String, Object?> frame)? onFrame;
  VoidCallback? onReset;
  bool enabled = false, consent = false, active = false, starting = false;
  bool _ready = false,
      _foreground = true,
      _disposed = false,
      _initialized = false;
  bool _available = true;
  String permission = 'notDetermined';
  String? error;
  int _generation = 0;
  double _lastTime = -1;
  Future<void> _writes = Future<void>.value();

  Map<String, Object?> get state => {
        'on': enabled,
        'consent': consent,
        'active': active,
        'starting': starting,
        'permission': permission,
        'error': error,
      };

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final token = _generation;
    final saved = await store.load();
    if (_disposed || token != _generation) return;
    enabled = saved['on'] == true;
    consent = saved['consent'] == true;
    try {
      _setPermission(await _methods.invokeMethod<Object?>('permission'));
    } catch (_) {
      error = 'Hand gestures are available on the iPad only.';
    }
    _notify(); // No start: every room opening requires an explicit hand-button tap.
  }

  void setContext(
      {required bool ready,
      required bool foreground,
      required bool available}) {
    _ready = ready;
    _foreground = foreground;
    _available = available;
    if ((!ready || !foreground || !available) && (active || starting)) {
      suspend();
    }
  }

  Future<void> acceptConsent() async {
    if (_disposed) return;
    ++_generation;
    consent = true;
    await _persist();
    _notify();
  }

  Future<void> setEnabled(bool value) async {
    if (_disposed) return;
    if (!value) {
      enabled = false;
      error = null;
      suspend(); // Stop before disk I/O, including when permission is still pending.
      await _persist();
      return;
    }
    if (!consent ||
        !_ready ||
        !_foreground ||
        !_available ||
        active ||
        starting) {
      return;
    }
    enabled = true;
    starting = true;
    error = null;
    final token = ++_generation;
    _lastTime = -1;
    _subscription ??= _events.listen(_event, onError: (Object _) {
      error = 'The camera is unavailable. Tap the hand button to try again.';
      suspend();
    });
    _notify();
    await _persist();
    if (!_current(token)) return;
    try {
      final result = await _methods.invokeMapMethod<String, Object?>('start');
      if (!_current(token)) {
        return; // A later native start/stop owns the camera now.
      }
      _setPermission(result?['permission']);
      active = result?['active'] == true;
      if (!active) {
        error = permission == 'denied'
            ? 'Camera access is off. Allow it in iPad Settings to use hand gestures.'
            : 'The camera is unavailable. Tap the hand button to try again.';
      }
    } catch (_) {
      if (!_current(token)) return;
      active = false;
      error = 'The camera is unavailable. Tap the hand button to try again.';
    } finally {
      if (_current(token)) {
        starting = false;
        _notify();
      }
    }
  }

  bool _current(int token) =>
      !_disposed && token == _generation && _ready && _foreground && _available;

  void suspend() {
    if (_disposed) return;
    final wasRunning = active || starting;
    ++_generation;
    active = false;
    starting = false;
    _lastTime = -1;
    if (wasRunning) unawaited(_stopNative());
    onReset?.call();
    _notify();
  }

  Future<void> _stopNative() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (_) {
      // Unsupported hosts never own a camera.
    }
  }

  Future<void> _persist() {
    final value = {'on': enabled, 'consent': consent};
    _writes = _writes.then((_) async {
      try {
        await store.save(value);
      } catch (_) {
        if (!_disposed) error = 'Could not save the hand-gesture setting.';
      }
    });
    return _writes;
  }

  void _setPermission(Object? value) {
    if (const ['notDetermined', 'denied', 'granted'].contains(value)) {
      permission = value as String;
    }
  }

  void _event(Object? raw) {
    if (_disposed || raw is! Map) return;
    if (raw['state'] == 'stopped') {
      _setPermission(raw['permission']);
      suspend();
      return;
    }
    if (raw['state'] == 'reset') {
      onReset?.call();
      _lastTime = -1;
      return;
    }
    if (!enabled || !active || !_ready || !_foreground || !_available) return;
    final frame = sanitize(raw);
    if (frame == null) return;
    final t = (frame['t'] as num).toDouble();
    if (t <= _lastTime || t - _lastTime < 50) return;
    _lastTime = t;
    onFrame?.call(frame);
  }

  /// Strict whitelist: the page receives only this schema, never joints/pixels/diagnostics.
  static Map<String, Object?>? sanitize(Object? raw) {
    if (raw is! Map || raw['hand'] is! bool) return null;
    double? number(String key, double low, double high) {
      final value = raw[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(low, high)
          : null;
    }

    final t = number('t', 0, 1e12);
    if (t == null) return null;
    if (raw['hand'] == false) return {'t': t, 'hand': false};
    // Upright VGA is 640x480 or 480x640; all lengths use frame-width units.
    const maxAspect = 4 / 3;
    final x = number('x', 0, 1), y = number('y', 0, maxAspect);
    final s = number('s', 0.0001, math.sqrt(1 + maxAspect * maxAspect));
    final score = number('score', 0, 1);
    final g = raw['g'];
    if (x == null ||
        y == null ||
        s == null ||
        score == null ||
        (g != null &&
            !const ['Open_Palm', 'Closed_Fist', 'Victory', 'Thumb_Up']
                .contains(g))) {
      return null;
    }
    return {
      't': t,
      'hand': true,
      'g': g,
      'score': score,
      'x': x,
      'y': y,
      's': s
    };
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    active = false;
    starting = false;
    onFrame = null;
    onReset = null;
    unawaited(_subscription?.cancel());
    unawaited(_stopNative());
    super.dispose();
  }
}
